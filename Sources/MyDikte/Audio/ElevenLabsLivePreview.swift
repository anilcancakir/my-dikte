import AVFoundation
import Foundation
import Synchronization
import os

/// The live preview, streamed to ElevenLabs Scribe v2 realtime instead of transcribed on device.
///
/// Two jobs on one socket. It draws words in the indicator while the user is still speaking, like
/// `LivePreview`, and unless `Settings.batchVerification` is on, its committed transcript is also the
/// dictation itself (`finishAndAwaitTranscript`), so the audio is never uploaded a second time.
///
/// **The realtime model reads worse than the batch one**, which is why the upload stays available as
/// a setting. Measured on nine real Turkish recordings (`evidence/elevenlabs-scribe-comparison.md`)
/// and again on 2026-10-17, `scribe_v2_realtime` reads short speech about as well as `scribe_v2` and
/// materially worse as the clip grows: it hears "socket" as "fakat" or "fakültesi", and on a 12 s
/// clip it dropped "Kubernetes" and turned "PyQt" into "File create", both of which were in its
/// glossary. A streaming model commits to words with limited lookahead; the batch model sees the
/// whole recording.
///
/// **A session is several segments, not one.** The server commits on its own after about 36 s of
/// audio whatever the commit strategy (ElevenLabs, "Transcripts and commit strategies"), and the first
/// version of this file kept only the segment that answered the final commit: a 44.6 s dictation
/// pasted its last sentence. So the client now commits a segment itself at a pause past
/// `softCommitSeconds`, or at `hardCommitSeconds` regardless, which is the 20 to 30 s cadence the same
/// page recommends, keeps every segment in a `Transcript`, and treats the session as finished once
/// every commit it sent has been answered.
///
/// **This one costs money**, unlike the on-device preview: $0.39 per audio hour, and it sends
/// microphone audio off the machine. Both of those are why `Settings.livePreviewProvider` exists.
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

    /// Past this much uncommitted audio, the next pause commits the segment.
    ///
    /// The low end of the 20 to 30 s cadence ElevenLabs recommends, and long enough that a normal
    /// dictation (median 9.9 s, longest measured 44.6 s) is one segment or two, since every commit
    /// costs the model the lookahead it would have had across the boundary.
    static let softCommitSeconds: Double = 20

    /// At this much uncommitted audio the segment is committed whether or not the user is pausing.
    ///
    /// Six seconds under the server's own commit at about 36 s, so the server's never fires: a
    /// commit the client did not send would arrive as a reply nobody counted.
    static let hardCommitSeconds: Double = 30

    /// A chunk counts as quiet when its RMS is under this multiple of the session's noise floor, 14 dB.
    ///
    /// Relative to the floor rather than an absolute level, for the reason `VoiceActivity` gives: one
    /// microphone idles at -70 dBFS, another at -35. And the floor rather than the loudest chunk,
    /// because one knock or cough sets a peak that ordinary speech sits 20 dB under. Measured on nine
    /// real recordings: floors sit at -41 to -63 dBFS and median speech at -16 to -20, so 14 dB above
    /// the floor never landed inside a word.
    static let pauseFloorRatio: Float = 5

    /// How long the audio has to stay quiet before it counts as a pause, about two send chunks.
    ///
    /// One chunk is 100 to 170 ms, which is a gap between words as often as it is a pause, and the
    /// last word of a segment deserves some right-context for the same reason `trailingSilenceSeconds`
    /// gives the final one a full second.
    static let minimumPauseSeconds: Double = 0.3

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
        /// Every commit was answered and no segment held a word. The caller uploads, because the
        /// batch model may still hear what the realtime one did not.
        case empty
        /// The commit was sent and nothing came back inside the deadline.
        case timedOut
        /// The socket died during the dictation, so no reply can come and nothing is waited for.
        case socketFailed
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
    /// Every segment of the running session, the commits sent and the replies received.
    private var transcript = Transcript()
    /// When the running session commits a segment on its own.
    private var schedule = CommitSchedule()
    /// Set when the running session's socket fails while it is still being listened to.
    private var socketFailed = false
    /// Resumed once every commit is answered, or by the timeout, whichever lands first. Cleared as it
    /// is resumed, because a continuation resumed twice is a crash.
    private var transcriptWaiter: CheckedContinuation<TranscriptOutcome, Never>?
    /// Identifies the waiter above, so a deadline set for one dictation cannot resume the next one's.
    private var waiterID: UInt64 = 0

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
    /// `commit_strategy=manual` rather than `vad`: letting the server's silence detector commit would
    /// split a single thought at every pause for breath, and every commit it sent would be a reply
    /// the `Transcript` did not count. A long dictation is still split, but by `CommitSchedule`, at
    /// most once every 20 to 30 s.
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

    /// The root mean square of `frames`, or `0` for none.
    static func rms(of frames: [Float]) -> Float {
        guard !frames.isEmpty else {
            return 0
        }
        let sumOfSquares: Float = frames.reduce(0) { $0 + $1 * $1 }
        return (sumOfSquares / Float(frames.count)).squareRoot()
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
        transcript = Transcript()
        schedule = CommitSchedule()
        socketFailed = false
        // A dictation that was cancelled while it waited is still parked on its continuation, and
        // the generation bump above means none of its replies will ever be applied. Released here
        // rather than left to its deadline, which the next dictation's waiter would otherwise
        // overwrite, leaking the continuation and hanging that run for good.
        let abandoned: CheckedContinuation<TranscriptOutcome, Never>? = transcriptWaiter
        transcriptWaiter = nil
        lock.unlock()
        abandoned?.resume(returning: .timedOut)

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
        let socket: URLSessionWebSocketTask? = lock.withLock { self.socket }
        sendQueue.async { [self] in
            flushAndCommit(on: socket)
            // Closing immediately would cancel the commit that was just sent, so the socket gets the
            // measured round trip plus headroom and is then released whether or not the reply came.
            // Only this socket: a dictation started inside that second already holds a new one.
            sendQueue.asyncAfter(deadline: .now() + Self.commitGraceSeconds) { [self] in
                closeSocket(socket)
            }
        }
    }

    /// Ends the audio and waits for the transcript of everything that was streamed, so the socket
    /// that has been feeding the preview produces the authoritative text and no audio is uploaded a
    /// second time.
    ///
    /// This is the mode ElevenLabs' own client examples use: they render `committedTranscripts` as
    /// the result rather than following the stream with a batch request. `Settings.batchVerification`
    /// turns it off, because the realtime model measured worse than the batch one on this user's
    /// longer recordings; see this type's own documentation.
    ///
    /// Never throws and never fails a dictation. A deadline miss or a dead socket comes back as a
    /// value and the caller uploads the audio instead, which is slower but produces text.
    func finishAndAwaitTranscript(timeout: Duration) async -> TranscriptOutcome {
        guard isListening.exchange(false, ordering: .acquiringAndReleasing) else {
            return .notRunning
        }
        // Deliberately no generation bump here, unlike `stop()`. The bump exists to stop a late
        // message repainting a finished dictation, and in this mode the late message *is* the
        // dictation.
        let socket: URLSessionWebSocketTask? = lock.withLock { self.socket }

        let outcome: TranscriptOutcome = await withCheckedContinuation { continuation in
            // 1. A socket that already died will never answer, so its waiter is not installed at all.
            lock.lock()
            if socketFailed {
                lock.unlock()
                continuation.resume(returning: .socketFailed)
                return
            }
            waiterID &+= 1
            let id: UInt64 = waiterID
            transcriptWaiter = continuation
            lock.unlock()

            // 2. The rest of the audio and the final commit, on the queue every send uses.
            sendQueue.async { [self] in
                flushAndCommit(on: socket)
            }

            // 3. The deadline, tagged so it can only ever resume this waiter.
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeWaiter(with: .timedOut, ifWaiterID: id)
            }
        }

        if outcome == .timedOut {
            logger.error("the realtime transcript did not arrive before the deadline")
        }
        closeSocket(socket)
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
        commitSegmentIfDue(after: ready, on: socket)
    }

    /// Commits the running segment when the `CommitSchedule` says so. `sendQueue` only, after the
    /// chunk it decides from has been sent, so the boundary falls after that audio rather than before.
    private func commitSegmentIfDue(after frames: [Float], on socket: URLSessionWebSocketTask) {
        let chunkRMS: Float = Self.rms(of: frames)

        lock.lock()
        let due: Bool = schedule.recordChunk(
            seconds: Double(frames.count) / AudioCapture.sampleRate,
            rms: chunkRMS
        )
        if due {
            transcript.recordCommit(isFinal: false)
        }
        lock.unlock()

        guard due else {
            return
        }
        logger.notice("realtime segment committed mid-dictation")
        socket.send(.string(Self.audioChunkMessage(base64Audio: "", commit: true))) { _ in }
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
    ///
    /// `socket` is the one the caller captured when the dictation ended. When a later dictation has
    /// replaced it by the time this runs, nothing is sent and none of the new session's state is
    /// touched: its schedule, transcript and pending audio belong to it.
    private func flushAndCommit(on socket: URLSessionWebSocketTask?) {
        lock.lock()
        guard let socket, self.socket === socket else {
            lock.unlock()
            return
        }
        var remaining: [Float] = pending
        let partialCount: Int = self.partialCount
        pending.removeAll(keepingCapacity: true)
        // Closed first, so a buffer drained after this point cannot schedule a commit behind the
        // final one, which would leave a reply outstanding that nothing is waiting to count.
        schedule.close()
        lock.unlock()

        // The tap's last buffers are still the dictation: up to one buffer of speech sits here when
        // the shortcut is released, and it is the end of the last word.
        ring.drain { buffer in
            guard let channel = buffer.floatChannelData else {
                return
            }
            remaining.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength)))
        }

        if !remaining.isEmpty {
            send(frames: remaining, commit: false, on: socket)
        }
        // Then silence, so the last word is followed by context rather than by the stream ending
        // mid-syllable. See `trailingSilenceSeconds` for why this is not a delay. It also keeps the
        // final commit above the server's 0.3 s minimum, so it is always answered with a segment.
        send(frames: Self.trailingSilence(), commit: false, on: socket)
        // An empty chunk with `commit: true` is how the protocol asks for the final segment. Counted
        // before it is sent, so the reply cannot land before the session knows to wait for it.
        lock.lock()
        transcript.recordCommit(isFinal: true)
        lock.unlock()
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

    /// Releases `socket`, and clears the stored one only when it is still that socket. Idempotent,
    /// and safe to call from either mode's teardown.
    private func closeSocket(_ socket: URLSessionWebSocketTask?) {
        guard let socket else {
            return
        }
        lock.lock()
        if self.socket === socket {
            self.socket = nil
        }
        lock.unlock()
        socket.cancel(with: .normalClosure, reason: nil)
    }

    /// Hands `outcome` to whoever is waiting on the transcript, exactly once. With an id, only to the
    /// waiter that id was issued to.
    private func resumeWaiter(with outcome: TranscriptOutcome, ifWaiterID id: UInt64? = nil) {
        lock.lock()
        guard id == nil || id == waiterID else {
            lock.unlock()
            return
        }
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
                self.socketDidFail(error, generation: generation)
            case .success(let message):
                self.handle(message: message, generation: generation)
                self.receive(on: socket, generation: generation)
            }
        }
    }

    /// A dead socket will never deliver the transcript, so a caller waiting on one is released now,
    /// and one that has not started waiting yet is told not to.
    ///
    /// Expected on every normal teardown: closing cancels the socket and the pending receive fails
    /// with it. Only a failure while still listening, or one a caller is waiting on, is worth a line,
    /// and only this session's socket counts: a late failure from a socket that has moved on must
    /// not mark the next dictation's.
    private func socketDidFail(_ error: any Error, generation: UInt64) {
        lock.lock()
        guard self.generation.load(ordering: .acquiring) == generation else {
            lock.unlock()
            return
        }
        socketFailed = true
        let waiter: CheckedContinuation<TranscriptOutcome, Never>? = transcriptWaiter
        transcriptWaiter = nil
        lock.unlock()

        if isListening.load(ordering: .acquiring) || waiter != nil {
            logger.error("live preview socket failed: \(error.localizedDescription, privacy: .public)")
        }
        waiter?.resume(returning: .socketFailed)
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
            // One segment, kept with every earlier one. When it answers the last outstanding commit
            // the session is complete, and its joined text is the dictation for a caller waiting in
            // `finishAndAwaitTranscript`.
            update(generation: generation, isReply: true) { $0.recordCommitted(event.text) }
        case "commit_throttled":
            logger.notice("a realtime commit was throttled by the server")
            update(generation: generation, isReply: true) { $0.recordThrottled() }
        case "partial_transcript", "final_transcript":
            update(generation: generation, isReply: false) { $0.recordPartial(event.text) }
        case "session_started":
            logger.notice("live preview session started")
        default:
            // Every error the endpoint documents arrives as its own `message_type`, so an unknown
            // type is logged by name rather than silently dropped: a preview that never appears
            // must not be indistinguishable from a preview nobody turned on.
            logger.error("live preview event \(event.messageType ?? "unnamed", privacy: .public)")
        }
    }

    /// Applies one server event to the running session, hands the finished dictation to a waiting
    /// caller once every commit is answered, and draws what the session now reads.
    ///
    /// Only for the session this receive loop belongs to: `start` and `stop` bump the generation, so
    /// an event from a socket that has moved on can neither repaint the panel nor leak into the next
    /// dictation's transcript. Checked under the lock, so it cannot pass just before `start` resets
    /// the transcript it is about to change.
    ///
    /// Settlement is read only on a reply. A partial changes no count, so letting it settle the
    /// session could only ever end it on a stale reading.
    private func update(generation: UInt64, isReply: Bool, _ apply: (inout Transcript) -> Void) {
        // 1. Mutate under the lock, and read everything the rest needs before releasing it.
        lock.lock()
        guard self.generation.load(ordering: .acquiring) == generation else {
            lock.unlock()
            return
        }
        apply(&transcript)
        let display: String = transcript.displayText
        let settledText: String? = isReply && transcript.isSettled ? transcript.text : nil
        let overCounted: Bool = transcript.repliesReceived > transcript.commitsSent
        lock.unlock()

        if isReply && overCounted {
            // The server committed on its own, which `hardCommitSeconds` exists to prevent. The
            // session will not settle and the caller uploads at the deadline instead of losing text.
            logger.error("a realtime reply arrived for a commit this client did not send")
        }

        // 2. The waiter first, so the dictation is not held behind a main-actor hop for the panel.
        if let settledText {
            resumeWaiter(with: settledText.isEmpty ? .empty : .transcript(settledText))
        }

        // 3. Then the panel.
        publish(display)
    }

    private func publish(_ text: String) {
        guard !text.isEmpty else {
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

extension ElevenLabsLivePreview {
    /// When the client commits a segment itself: at the first sustained pause past
    /// `softCommitSeconds`, or at `hardCommitSeconds` regardless.
    ///
    /// A pause is audio under `pauseFloorRatio` times the session's noise floor for at least
    /// `minimumPauseSeconds`. The floor is the quietest chunk so far, ignoring digital silence: a
    /// Bluetooth link that has not opened reports exact zeros, and a zero floor would make no chunk
    /// quiet relative to it.
    struct CommitSchedule: Sendable, Equatable {
        private(set) var uncommittedSeconds: Double = 0
        private(set) var quietSeconds: Double = 0
        private(set) var noiseFloorRMS: Float?
        private(set) var isClosed: Bool = false

        /// Records one sent chunk and says whether to commit the segment after it.
        mutating func recordChunk(seconds: Double, rms: Float) -> Bool {
            guard !isClosed else {
                return false
            }
            uncommittedSeconds += seconds

            // 1. The floor moves only on real microphone audio.
            if Double(rms) >= LeadingSilence.silenceRMS {
                noiseFloorRMS = min(noiseFloorRMS ?? rms, rms)
            }

            // 2. Quiet is relative to that floor; digital silence mid-dictation is quiet too.
            let isQuiet: Bool = Double(rms) < LeadingSilence.silenceRMS
                || noiseFloorRMS.map { rms < $0 * ElevenLabsLivePreview.pauseFloorRatio } == true
            quietSeconds = isQuiet ? quietSeconds + seconds : 0

            // 3. Commit at a pause past the soft threshold, or at the hard one regardless.
            let isPause: Bool = quietSeconds >= ElevenLabsLivePreview.minimumPauseSeconds
            let due: Bool = uncommittedSeconds >= ElevenLabsLivePreview.hardCommitSeconds
                || (uncommittedSeconds >= ElevenLabsLivePreview.softCommitSeconds && isPause)
            if due {
                uncommittedSeconds = 0
                quietSeconds = 0
            }
            return due
        }

        /// Called with the final commit. Nothing is committed after it.
        mutating func close() {
            isClosed = true
        }
    }

    /// One realtime session's text: every committed segment in order, the partial being spoken now,
    /// and the bookkeeping that says when the last segment is in.
    ///
    /// The server answers every commit in the order it was sent, with a `committed_transcript` (empty
    /// for a segment that held only silence) or a `commit_throttled` when less than 0.3 s was
    /// uncommitted, both measured on 2026-10-17. So once the final commit is sent, the session is
    /// complete exactly when the replies have caught up with the commits.
    struct Transcript: Sendable, Equatable {
        private(set) var segments: [String] = []
        private(set) var partial: String = ""
        private(set) var commitsSent: Int = 0
        private(set) var repliesReceived: Int = 0
        private(set) var finalCommitSent: Bool = false

        /// Every segment, joined: the dictation, once `isSettled`.
        var text: String {
            segments.joined(separator: " ")
        }

        /// What the indicator shows: the finished segments, then the one still being spoken.
        var displayText: String {
            (segments + [partial])
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        /// Exactly caught up, not at least. A reply nobody counted (a server commit this client did
        /// not send) that lands after the client's own replies leaves the session unsettled, so the
        /// caller uploads at the deadline rather than paste a dictation missing its last segment.
        /// Counts cannot tell replies apart, so one that lands earlier still settles the session a
        /// reply early; `hardCommitSeconds` is what keeps such a reply from existing, and a 91 s
        /// recording on 2026-10-17 produced none.
        var isSettled: Bool {
            finalCommitSent && repliesReceived == commitsSent
        }

        /// Call before the commit message is sent, so its reply can never arrive uncounted.
        mutating func recordCommit(isFinal: Bool) {
            commitsSent += 1
            if isFinal {
                finalCommitSent = true
            }
        }

        mutating func recordCommitted(_ text: String?) {
            repliesReceived += 1
            partial = ""
            let trimmed: String = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty {
                segments.append(trimmed)
            }
        }

        /// A commit the server refused because under 0.3 s was uncommitted. It still answers that
        /// commit, and it held no speech: an intermediate commit follows at least `softCommitSeconds`
        /// of audio and the final one follows `trailingSilenceSeconds` of silence, so this is a guard
        /// against a waiter sitting out its deadline rather than a path that loses words.
        mutating func recordThrottled() {
            repliesReceived += 1
        }

        mutating func recordPartial(_ text: String?) {
            partial = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
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
