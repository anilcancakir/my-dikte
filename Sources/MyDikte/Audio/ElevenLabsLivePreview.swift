import AVFoundation
import Foundation
import Synchronization
import os

/// The live preview, streamed to ElevenLabs Scribe v2 realtime instead of transcribed on device.
///
/// Same job and same surface as `LivePreview`: words in the indicator while the user is still
/// speaking, thrown away afterwards, never reaching the caret, the clipboard, the cleanup call, the
/// paraphrase guard or the log. The authoritative text still comes from the batch transcription
/// call, and that is a measured decision rather than a conservative one.
///
/// **Why the realtime model is not the final text.** Measured on nine real Turkish recordings
/// (`evidence/elevenlabs-scribe-comparison.md`), `scribe_v2_realtime` reads short speech about as
/// well as the batch model and materially worse as the clip grows: on one 27 s recording it heard
/// "socket" as "fakat" four times, and on a 12 s one it dropped "Kubernetes" entirely and turned
/// "PyQt" into "File create", both of which were in the glossary it was given. The reason is
/// structural: a streaming model commits to words with limited lookahead, while the batch model sees
/// the whole recording. So realtime feeds the preview, where being early beats being right, and
/// batch produces the text that gets pasted, where the opposite holds.
///
/// **This one costs money**, unlike the on-device preview: $0.39 per audio hour, about $1.70 a month
/// at 50 dictations a day, and it sends microphone audio off the machine. Both of those are why
/// `Settings.livePreviewProvider` exists and defaults to `.apple`.
///
/// **Deliberately not `@MainActor`,** for the same reason `AudioCapture` and `LivePreview` are not:
/// `accept(_:)` is called from the `AVAudioEngine` tap callback, and a main-actor call from that
/// thread is a SIGTRAP that kills the process rather than an error. So `accept` only memcpys into a
/// ring slot that already exists and wakes a serial queue. Every `URLSessionWebSocketTask` call
/// happens on that queue, and the only main-actor work is publishing text through `onPreviewText`.
final class ElevenLabsLivePreview: @unchecked Sendable {
    /// Whether a preview can run, and why not when it cannot.
    ///
    /// Every case other than `.ready` is a preview that does not appear, logged, with the dictation
    /// completely unaffected. None of them is an error that propagates: a failed preview must never
    /// be able to cost a dictation.
    enum Readiness: Sendable, Equatable {
        case ready
        case disabledBySetting
        /// The provider is selected but no key is stored, which is the one failure the user can fix.
        case missingAPIKey(account: String)
        case audioBufferUnavailable

        var isReady: Bool {
            self == .ready
        }

        /// What the log says when the preview stays off. The user cannot see a missing preview's
        /// cause anywhere else, so each line names the cause and, where there is one, the fix.
        var logMessage: String {
            switch self {
            case .ready:
                return "the live preview is on, streaming to ElevenLabs \(ElevenLabsLivePreview.modelId)"
            case .disabledBySetting:
                return "the live preview is off in Settings, so no socket was opened"
            case .missingAPIKey(let account):
                return "the live preview is set to ElevenLabs but the Keychain account \(account) holds "
                    + "no key, so no socket was opened. Add the key on the Keys pane in Settings."
            case .audioBufferUnavailable:
                return "the live preview could not preallocate its 16 kHz mono buffers, so it stays off"
            }
        }
    }

    /// The realtime model. Not a setting: the two other realtime ids ElevenLabs publishes, `_turbo`
    /// and `_lite`, are smaller models than this one, and a preview that reads Turkish worse than
    /// Apple's free on-device recogniser would have no reason to exist.
    static let modelId = "scribe_v2_realtime"

    /// 16 slots of 8192 frames, matching `LivePreview` for the same reason: 8192 is what makes a
    /// whole converted buffer from `AudioCapture` fit in one slot.
    private static let slotCount = 16
    private static let slotFrameCapacity: AVAudioFrameCount = 8192

    /// ElevenLabs asks for 0.1 to 1 second per chunk, so tap buffers are accumulated to this
    /// threshold rather than sent as they arrive: the converter emits about 85 ms, which is under the
    /// documented floor, and one send per tap callback would be pure overhead on every dictation.
    static let minimumChunkFrames = 1_600

    /// How long `stop()` waits for the committed transcript before closing the socket. The commit
    /// round trip measured 192 to 313 ms across five recordings, so this is roughly three times the
    /// slowest observed case; a preview that has already been superseded by the batch result is not
    /// worth holding a socket open for longer than that.
    static let commitGraceSeconds: TimeInterval = 1.0

    /// Silence appended after the speech and before the commit, so the model has acoustic context
    /// past the final word instead of being cut off mid-syllable.
    ///
    /// This is standard practice for streaming recognisers and it is what the user was really asking
    /// for when they asked to "wait a second before finishing": the recogniser does not need us to
    /// wait, it needs the audio not to stop abruptly. Sending a second of digital silence costs one
    /// message and about $0.0001, and it does **not** cost a second of latency, because the silence
    /// is transmitted immediately rather than in real time. Only the model's own processing of it is
    /// added to the commit round trip.
    ///
    /// One second matches the shortest interval the user asked for and the low end of ElevenLabs'
    /// own VAD silence threshold (1.5 s), which is the window their model treats as an end of speech.
    static let trailingSilenceSeconds: Double = 1.0

    /// The bound on what the indicator shows, and the tail-truncation rule, both borrowed from
    /// `LivePreview` so the two backends cannot drift into drawing differently.
    static let displayCharacterLimit = LivePreview.displayCharacterLimit

    /// Called with the text to show, on the main actor, in the order the partials arrived.
    var onPreviewText: (@MainActor @Sendable (String) -> Void)?

    /// What `finishAndAwaitTranscript` came back with.
    ///
    /// Not a thrown error, because none of these is a dictation that has to fail: the caller can
    /// still upload the audio to the batch endpoint, which is exactly what it does.
    enum TranscriptOutcome: Sendable, Equatable {
        case transcript(String)
        /// The commit was sent and nothing came back inside the deadline.
        case timedOut
        /// No socket was open, so there was nothing to commit. The preview was off, unauthorised,
        /// or the provider was not this one.
        case notRunning
    }

    private let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "LivePreviewRealtime")
    private let lock = NSLock()

    /// Immutable, so the tap callback holds it without reading a mutable property of this class and
    /// without ever taking `lock`.
    private let ring: BufferRing
    private let sendQueue = DispatchQueue(label: "com.anilcan.mydikte.live-preview-realtime")
    private let sendSource: DispatchSourceUserDataAdd

    /// One session for the app's lifetime, so a second dictation reuses the TLS handshake.
    private let session: URLSession
    private let readKey: @Sendable (String) -> KeychainStore.ReadResult

    /// The tap callback's only read: false is one atomic load and a return, which is the entire cost
    /// of this feature for a dictation that has no preview.
    private let isListening = Atomic<Bool>(false)

    /// Bumped by every `start` **and** every `stop`, and captured by that run's receive loop. A
    /// message can arrive after the audio has stopped, and a panel that has moved on must not be
    /// written to by a dictation that ended.
    private let generation = Atomic<UInt64>(0)

    /// Control plane, `lock` only. Never touched from the audio thread.
    private var socket: URLSessionWebSocketTask?
    private var pending: [Float] = []
    private var partialCount = 0
    /// Resumed by the first committed transcript after a commit, or by the timeout, whichever lands
    /// first. Cleared as it is resumed, because a continuation resumed twice is a crash.
    private var transcriptWaiter: CheckedContinuation<TranscriptOutcome, Never>?

    init(
        readKey: @escaping @Sendable (String) -> KeychainStore.ReadResult = KeychainStore.read,
        session: URLSession? = nil
    ) {
        self.readKey = readKey
        self.session = session ?? URLSession(configuration: .default)
        ring = BufferRing(
            format: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: AudioCapture.sampleRate,
                channels: 1,
                interleaved: false
            ),
            slotCount: Self.slotCount,
            frameCapacity: Self.slotFrameCapacity
        )
        sendSource = DispatchSource.makeUserDataAddSource(queue: sendQueue)
        sendSource.setEventHandler { [weak self] in
            self?.drainAndSend()
        }
        sendSource.resume()
        pending.reserveCapacity(Self.minimumChunkFrames * 2)
    }

    deinit {
        sendSource.cancel()
    }

    // MARK: - The pure decisions

    /// Whether a preview may run at all. The setting is checked first so that "off" means nothing is
    /// created, no key is read and no socket is opened.
    static func readiness(
        isEnabledInSettings: Bool,
        hasAPIKey: Bool,
        keychainAccount: String,
        hasAudioBuffers: Bool
    ) -> Readiness {
        guard isEnabledInSettings else {
            return .disabledBySetting
        }
        guard hasAPIKey else {
            return .missingAPIKey(account: keychainAccount)
        }
        guard hasAudioBuffers else {
            return .audioBufferUnavailable
        }
        return .ready
    }

    /// The socket URL for one dictation.
    ///
    /// `commit_strategy=manual` rather than `vad`: a dictation is one segment that ends when the user
    /// releases the shortcut, and letting the server's silence detector commit would split a single
    /// thought into several transcripts at every pause for breath. ElevenLabs commits on its own
    /// after about 36 seconds of accumulated audio regardless, which is past the longest dictation
    /// this app has recorded (27.3 s) but not unreachable.
    static func socketURL(glossaryTerms: [String], language: String) -> URL {
        var items: [URLQueryItem] = [
            URLQueryItem(name: "model_id", value: modelId),
            URLQueryItem(name: "audio_format", value: "pcm_\(Int(AudioCapture.sampleRate))"),
            URLQueryItem(name: "commit_strategy", value: "manual"),
            URLQueryItem(name: "language_code", value: language),
            // Same reason as the batch provider: disfluency is faithful transcription and wrong for
            // a dictation preview, and audio-event tags would draw "(laughter)" in the indicator.
            URLQueryItem(name: "no_verbatim", value: "true"),
        ]
        // Realtime caps keyterms lower than batch does: 50 terms of at most 20 characters.
        for term in glossaryTerms.filter(isEligibleKeyterm).prefix(realtimeKeytermLimit) {
            items.append(URLQueryItem(name: "keyterms", value: term))
        }

        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        components.queryItems = items
        return components.url!
    }

    static let realtimeKeytermLimit = 50
    static let realtimeKeytermCharacterLimit = 20

    /// Whether a glossary term fits the realtime endpoint's own keyterm limits, which are tighter
    /// than the batch endpoint's.
    static func isEligibleKeyterm(_ term: String) -> Bool {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= realtimeKeytermCharacterLimit
    }

    /// One `input_audio_chunk` message. Built as a string rather than a dictionary so the audio path
    /// never pays for `JSONSerialization` on a per-chunk basis, and so the shape is testable.
    static func audioChunkMessage(base64Audio: String, commit: Bool) -> String {
        """
        {"message_type":"input_audio_chunk","audio_base_64":"\(base64Audio)",\
        "commit":\(commit),"sample_rate":\(Int(AudioCapture.sampleRate))}
        """
    }

    /// Little-endian 16-bit PCM for `frames`, which is the only format the realtime endpoint accepts
    /// at 16 kHz. Values are clamped rather than wrapped: a sample above 1.0 from an aggressive input
    /// gain would otherwise flip sign and arrive as a click.
    static func pcm16Data(from frames: [Float]) -> Data {
        var data = Data(capacity: frames.count * 2)
        for frame in frames {
            let clamped: Float = min(1.0, max(-1.0, frame))
            let scaled = Int16(clamped * Float(Int16.max))
            data.append(UInt8(truncatingIfNeeded: scaled))
            data.append(UInt8(truncatingIfNeeded: scaled >> 8))
        }
        return data
    }

    /// The trailing silence buffer, as float frames at the capture sample rate.
    ///
    /// True digital zero rather than low-level noise: this is a deliberate end-of-speech marker, and
    /// the leading-trim measurements in `LeadingSilence` are about audio the *microphone* reported as
    /// zero, which is a different problem. Nothing trims the tail, so nothing here can be mistaken
    /// for a dead Bluetooth link.
    static func trailingSilence() -> [Float] {
        [Float](repeating: 0, count: Int(AudioCapture.sampleRate * trailingSilenceSeconds))
    }

    /// What the indicator draws, delegated so both backends truncate identically.
    static func displayText(_ text: String, limit: Int = ElevenLabsLivePreview.displayCharacterLimit) -> String {
        LivePreview.displayText(text, limit: limit)
    }

    // MARK: - Lifecycle, from the main actor

    /// Starts a preview for one dictation, or reports why there is none. Never throws: the caller is
    /// the dictation path.
    @discardableResult
    func start(isEnabledInSettings: Bool, glossaryTerms: [String], language: String) -> Readiness {
        // A preview still running means the previous dictation's teardown has not finished, so it is
        // finished here before a second socket exists.
        if isListening.load(ordering: .acquiring) {
            logger.warning("a live preview was still running when a new one started")
            stop()
            sendQueue.sync {}
        }

        let account = Settings.TranscriptionProvider.elevenLabs.keychainAccount
        let apiKey: String? = resolvedAPIKey(forAccount: account)
        let readiness: Readiness = Self.readiness(
            isEnabledInSettings: isEnabledInSettings,
            hasAPIKey: apiKey != nil,
            keychainAccount: account,
            hasAudioBuffers: ring.isUsable
        )
        guard readiness.isReady, let apiKey else {
            logger.notice("\(readiness.logMessage, privacy: .public)")
            return readiness
        }

        var request = URLRequest(url: Self.socketURL(glossaryTerms: glossaryTerms, language: language))
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let socket = session.webSocketTask(with: request)

        let generation: UInt64 = self.generation.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
        lock.lock()
        self.socket = socket
        pending.removeAll(keepingCapacity: true)
        partialCount = 0
        lock.unlock()

        socket.resume()
        receive(on: socket, generation: generation)

        isListening.store(true, ordering: .releasing)
        logger.notice("\(readiness.logMessage, privacy: .public)")
        return readiness
    }

    /// Ends the preview and closes its socket. Idempotent, and safe on every path a dictation can
    /// end on: a normal stop, a cancel and a failure all reach it.
    func stop() {
        guard isListening.exchange(false, ordering: .acquiringAndReleasing) else {
            return
        }
        // Bumped here so a message already in flight cannot repaint a panel that has moved on. The
        // committed transcript this stop asks for is deliberately not exempt: by the time it lands
        // the batch call is already running, and the last partial is what the panel should keep.
        generation.wrappingAdd(1, ordering: .acquiringAndReleasing)
        // Teardown runs on the same serial queue as every send, so audio already in flight is sent
        // before the commit rather than after it, and the main actor never waits on the socket.
        sendQueue.async { [self] in
            flushAndCommit()
            // Closing immediately would cancel the commit that was just sent, so the socket gets the
            // measured round trip plus headroom and is then released whether or not the reply came.
            sendQueue.asyncAfter(deadline: .now() + Self.commitGraceSeconds) { [self] in
                closeSocket()
            }
        }
    }

    /// Ends the audio and waits for the transcript of everything that was streamed, so the socket
    /// that has been feeding the preview produces the authoritative text and no audio is uploaded a
    /// second time.
    ///
    /// This is the mode ElevenLabs' own client examples use: they render `committedTranscripts` as
    /// the result rather than following the stream with a batch request. It is offered as a choice
    /// rather than as the default because the realtime model measured worse than the batch one on
    /// this user's longer recordings; see this type's own documentation.
    ///
    /// Never throws and never fails a dictation. A deadline miss comes back as `.timedOut` and the
    /// caller uploads the audio instead, which is slower but produces text.
    func finishAndAwaitTranscript(timeout: Duration) async -> TranscriptOutcome {
        guard isListening.exchange(false, ordering: .acquiringAndReleasing) else {
            return .notRunning
        }
        // Deliberately no generation bump here, unlike `stop()`. The bump exists to stop a late
        // message repainting a finished dictation, and in this mode the late message *is* the
        // dictation.
        let outcome: TranscriptOutcome = await withCheckedContinuation { continuation in
            lock.lock()
            transcriptWaiter = continuation
            lock.unlock()

            sendQueue.async { [self] in
                flushAndCommit()
            }

            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeWaiter(with: .timedOut)
            }
        }

        if case .timedOut = outcome {
            logger.error("the realtime transcript did not arrive before the deadline")
        }
        closeSocket()
        return outcome
    }

    /// Called from the audio tap callback. No allocation, no lock, no network call.
    func accept(_ buffer: AVAudioPCMBuffer) {
        guard isListening.load(ordering: .acquiring) else {
            return
        }
        ring.write(buffer)
        sendSource.add(data: 1)
    }

    // MARK: - The serial queue

    /// Accumulates whatever the tap has produced and sends it once it reaches the documented minimum
    /// chunk length. `sendQueue` only.
    private func drainAndSend() {
        lock.lock()
        let socket: URLSessionWebSocketTask? = self.socket
        lock.unlock()

        // The read index advances either way: a preview that has already been torn down drops what
        // is left rather than leaving the ring half full for the next dictation.
        var accumulated: [Float] = []
        ring.drain { buffer in
            guard socket != nil, let channel = buffer.floatChannelData else {
                return
            }
            accumulated.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }
        guard let socket, !accumulated.isEmpty else {
            return
        }

        lock.lock()
        pending.append(contentsOf: accumulated)
        let ready: [Float]? = pending.count >= Self.minimumChunkFrames ? pending : nil
        if ready != nil {
            pending.removeAll(keepingCapacity: true)
        }
        lock.unlock()

        guard let ready else {
            return
        }
        send(frames: ready, commit: false, on: socket)
    }

    private func send(frames: [Float], commit: Bool, on socket: URLSessionWebSocketTask) {
        let message = Self.audioChunkMessage(
            base64Audio: Self.pcm16Data(from: frames).base64EncodedString(),
            commit: commit
        )
        socket.send(.string(message)) { [weak self] error in
            guard let error else {
                return
            }
            // A failed send is a preview that falls behind, never a dictation that fails.
            self?.logger.error("live preview send failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Sends whatever audio is left and then the commit, leaving the socket open for the reply.
    /// `sendQueue` only.
    ///
    /// The socket is deliberately not cleared here, unlike in the first version of this file: both
    /// callers still need the reply to arrive, one to draw a last preview and one because that reply
    /// is the dictation. `closeSocket` is what releases it.
    private func flushAndCommit() {
        lock.lock()
        let socket: URLSessionWebSocketTask? = self.socket
        let remaining: [Float] = pending
        let partialCount: Int = self.partialCount
        pending.removeAll(keepingCapacity: true)
        lock.unlock()

        guard let socket else {
            return
        }
        ring.drain { _ in }

        if !remaining.isEmpty {
            send(frames: remaining, commit: false, on: socket)
        }
        // Then silence, so the last word is followed by context rather than by the stream ending
        // mid-syllable. See `trailingSilenceSeconds` for why this is not a delay.
        send(frames: Self.trailingSilence(), commit: false, on: socket)
        // An empty chunk with `commit: true` is how the protocol asks for the final segment; the
        // last words of the dictation are in that transcript and nowhere else.
        socket.send(.string(Self.audioChunkMessage(base64Audio: "", commit: true))) { _ in }

        let dropped: Int = ring.droppedBuffers.load(ordering: .relaxed)
        let rejected: Int = ring.rejectedBuffers.load(ordering: .relaxed)
        logger.notice(
            """
            live preview committed: \(partialCount, privacy: .public) partial result(s), \
            \(dropped, privacy: .public) buffer(s) dropped, \
            \(rejected, privacy: .public) rejected
            """
        )
    }

    /// Releases the socket. Idempotent, and safe to call from either mode's teardown.
    private func closeSocket() {
        lock.lock()
        let socket: URLSessionWebSocketTask? = self.socket
        self.socket = nil
        lock.unlock()
        socket?.cancel(with: .normalClosure, reason: nil)
    }

    /// Hands `outcome` to whoever is waiting on the transcript, exactly once.
    private func resumeWaiter(with outcome: TranscriptOutcome) {
        lock.lock()
        let waiter: CheckedContinuation<TranscriptOutcome, Never>? = transcriptWaiter
        transcriptWaiter = nil
        lock.unlock()
        waiter?.resume(returning: outcome)
    }

    // MARK: - Results

    private func receive(on socket: URLSessionWebSocketTask, generation: UInt64) {
        socket.receive { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .failure(let error):
                // Expected on every normal teardown: closing cancels the socket, and the pending
                // receive fails with it. Only a failure while still listening is worth a line.
                if self.isListening.load(ordering: .acquiring) {
                    self.logger.error("live preview socket failed: \(error.localizedDescription, privacy: .public)")
                }
                // A dead socket will never deliver the transcript, so a caller waiting on one is
                // released now rather than left to sit out the whole deadline.
                self.resumeWaiter(with: .timedOut)
            case .success(let message):
                self.handle(message: message, generation: generation)
                self.receive(on: socket, generation: generation)
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message, generation: UInt64) {
        guard case .string(let json) = message else {
            return
        }
        guard let event = try? JSONDecoder().decode(RealtimeEvent.self, from: Data(json.utf8)) else {
            return
        }

        switch event.messageType {
        case "committed_transcript":
            // The segment the commit asked for. It feeds the panel when a preview is still on screen,
            // and it is the dictation itself when `finishAndAwaitTranscript` is waiting for it.
            if let text = event.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                resumeWaiter(with: .transcript(text))
            }
            publish(event.text, generation: generation)
        case "partial_transcript", "final_transcript":
            publish(event.text, generation: generation)
        case "session_started":
            logger.notice("live preview session started")
        default:
            // Every error the endpoint documents arrives as its own `message_type`, so an unknown
            // type is logged by name rather than silently dropped: a preview that never appears
            // must not be indistinguishable from a preview nobody turned on.
            logger.error("live preview event \(event.messageType ?? "unnamed", privacy: .public)")
        }
    }

    private func publish(_ text: String?, generation: UInt64) {
        guard self.generation.load(ordering: .acquiring) == generation else {
            return
        }
        guard let text, !text.isEmpty else {
            return
        }

        lock.lock()
        partialCount += 1
        let handler: (@MainActor @Sendable (String) -> Void)? = onPreviewText
        lock.unlock()

        guard let handler else {
            return
        }
        // The text itself is never logged: it is the user's speech, and the unified log is not the
        // place for it. Only the count above is.
        let display: String = Self.displayText(text)
        // `DispatchQueue.main` rather than `Task { @MainActor in }`, because partial results are only
        // useful in order and a task hop does not promise one.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handler(display)
            }
        }
    }

    private func resolvedAPIKey(forAccount account: String) -> String? {
        guard case .found(let value) = readKey(account) else {
            return nil
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// One message from the realtime endpoint. Only the two fields this preview reads are decoded;
/// the endpoint sends word arrays, timestamps and entity offsets that nothing here uses.
private struct RealtimeEvent: Decodable {
    let messageType: String?
    let text: String?

    enum CodingKeys: String, CodingKey {
        case messageType = "message_type"
        case text
    }
}
