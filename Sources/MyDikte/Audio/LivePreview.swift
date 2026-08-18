import AVFoundation
import Foundation
import Speech
import Synchronization
import os

/// A second, throwaway transcription of the same microphone audio, running on device, so the words
/// appear in the indicator while the user is still speaking.
///
/// It has to be a second transcription because the authoritative one cannot stream: Groq has no
/// streaming transcription endpoint at all, and macOS 26's newer `SpeechTranscriber` lists 30
/// locales with Turkish among none of them (`research/verification-log.md`). `SFSpeechRecognizer`
/// does list `tr-TR` with `supportsOnDeviceRecognition == true`, so this runs alongside the real
/// pipeline and its text is thrown away. Nothing here reaches the caret, the clipboard, the cleanup
/// call, the paraphrase guard or the log: the preview emits no punctuation and is not the product.
///
/// `requiresOnDeviceRecognition = true` is a privacy boundary rather than a preference, because this
/// user dictates work content. The framework only honours it when the recogniser reports
/// `supportsOnDeviceRecognition`, so that is checked before a task is created and an unsupported
/// locale leaves the preview off. There is no network fallback in this file by construction.
///
/// **Deliberately not `@MainActor`, for the same reason `AudioCapture` is not.** `accept(_:)` is
/// called from the `AVAudioEngine` tap callback, and a main-actor call from that thread is a SIGTRAP
/// that kills the process rather than an error. So `accept` only memcpys into a ring slot that
/// already exists and wakes a serial queue; every call into the Speech framework happens on that
/// queue, and the only main-actor work is publishing the text through `onPreviewText`.
final class LivePreview: @unchecked Sendable {
    /// Whether a preview can run, and why not when it cannot.
    ///
    /// Every case other than `.ready` is a preview that does not appear, logged, with the dictation
    /// completely unaffected. None of them is an error that propagates: a failed preview must never
    /// be able to cost a dictation.
    enum Readiness: Sendable, Equatable {
        case ready
        case disabledBySetting
        case notAuthorised(SFSpeechRecognizerAuthorizationStatus)
        /// `SFSpeechRecognizer(locale:)` returned nil, so this system cannot recognise `tr-TR`.
        case recognizerMissing
        /// The privacy refusal: without on-device support the audio would go to Apple's servers.
        case onDeviceRecognitionUnavailable
        case recognizerUnavailable
        case audioBufferUnavailable

        var isReady: Bool {
            self == .ready
        }

        /// What the log says when the preview stays off. The user cannot see a missing preview's
        /// cause anywhere else, so each line names the cause and, where there is one, the fix.
        var logMessage: String {
            switch self {
            case .ready:
                return "the live preview is on, on device, tr-TR"
            case .disabledBySetting:
                return "the live preview is off in Settings, so no recogniser was created and no "
                    + "authorisation was requested"
            case .notAuthorised(let status):
                return "the live preview has no speech recognition authorisation (\(status.logName)). "
                    + "Grant it in System Settings, Privacy & Security, Speech Recognition."
            case .recognizerMissing:
                return "this system has no speech recogniser for \(LivePreview.locale.identifier), "
                    + "so there is no live preview"
            case .onDeviceRecognitionUnavailable:
                return "on-device recognition is unavailable for \(LivePreview.locale.identifier), so the "
                    + "live preview stays off rather than sending audio off the machine; the preview "
                    + "only ever runs on device"
            case .recognizerUnavailable:
                return "the speech recogniser reports itself unavailable, so there is no live preview "
                    + "for this dictation"
            case .audioBufferUnavailable:
                return "the live preview could not preallocate its 16 kHz mono buffers, so it stays off"
            }
        }
    }

    /// The one locale this preview exists for. `SFSpeechRecognizer` lists 63 locales on this machine
    /// and `tr-TR` is one of them with on-device support; `SpeechTranscriber` lists 30 and it is not.
    static let locale = Locale(identifier: "tr-TR")

    /// The bound on what the indicator shows. See `displayText(_:limit:)` for why it is a tail.
    static let displayCharacterLimit = 90

    /// 16 slots of 8192 frames, about 1.4 s of backlog at the 85 ms the converter emits per tap
    /// callback. 8192 matches `AudioSpool`'s 32 KB slab, which is what makes a whole converted
    /// buffer fit: the converter is sized for four tap buffers, so it can emit about 5460 frames.
    private static let slotCount = 16
    private static let slotFrameCapacity: AVAudioFrameCount = 8192

    /// Called with the text to show, on the main actor, in the order the partials arrived.
    var onPreviewText: (@MainActor @Sendable (String) -> Void)?

    private let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "LivePreview")
    private let lock = NSLock()

    /// Immutable, so the tap callback holds it without reading a mutable property of this class and
    /// without ever taking `lock`.
    private let ring: BufferRing
    private let appendQueue = DispatchQueue(label: "com.anilcan.mydikte.live-preview")
    private let appendSource: DispatchSourceUserDataAdd

    /// The tap callback's only read: false is one atomic load and a return, which is the entire cost
    /// of this feature for a dictation that has no preview.
    private let isListening = Atomic<Bool>(false)

    /// Bumped by every `start` **and** every `stop`, and captured by that run's result handler. A
    /// result can arrive after the audio has stopped, and a panel that has moved on must not be
    /// written to by a dictation that ended.
    private let generation = Atomic<UInt64>(0)

    /// Control plane, `lock` only. Never touched from the audio thread.
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var partialCount = 0

    init() {
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
        appendSource = DispatchSource.makeUserDataAddSource(queue: appendQueue)
        appendSource.setEventHandler { [weak self] in
            self?.appendPendingBuffers()
        }
        appendSource.resume()
    }

    deinit {
        appendSource.cancel()
    }

    // MARK: - The pure decisions

    /// Whether a preview may run at all, given what the system reports.
    ///
    /// The setting is checked first so that "off" means nothing is created and nothing is asked. The
    /// on-device check outranks availability because availability flaps with the network while the
    /// privacy boundary does not, and a preview that is refused for privacy must say so rather than
    /// read as a transient glitch.
    static func readiness(
        isEnabledInSettings: Bool,
        authorization: SFSpeechRecognizerAuthorizationStatus,
        hasRecognizer: Bool,
        supportsOnDeviceRecognition: Bool,
        isRecognizerAvailable: Bool,
        hasAudioBuffers: Bool
    ) -> Readiness {
        guard isEnabledInSettings else {
            return .disabledBySetting
        }
        guard authorization == .authorized else {
            return .notAuthorised(authorization)
        }
        guard hasRecognizer else {
            return .recognizerMissing
        }
        guard supportsOnDeviceRecognition else {
            return .onDeviceRecognitionUnavailable
        }
        guard isRecognizerAvailable else {
            return .recognizerUnavailable
        }
        guard hasAudioBuffers else {
            return .audioBufferUnavailable
        }
        return .ready
    }

    /// What the indicator draws for a partial result.
    ///
    /// A tail rather than a head: the panel is 320 points in a screen corner, so the text needs a
    /// hard bound, and while speaking it is the newest words that are being checked. A head
    /// truncation would freeze on the opening words and make the preview useless. Whitespace is
    /// collapsed because a newline in a partial would break the two-line budget the panel is drawn
    /// for and the pill would start covering the corner of the screen.
    static func displayText(_ text: String, limit: Int = LivePreview.displayCharacterLimit) -> String {
        let collapsed: String = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard collapsed.count > limit else {
            return collapsed
        }
        return "…" + String(collapsed.suffix(limit))
    }

    // MARK: - Lifecycle, from the main actor

    /// Starts a preview for one dictation, or reports why there is none. Never throws: the caller is
    /// the dictation path.
    @discardableResult
    func start(isEnabledInSettings: Bool) -> Readiness {
        // A preview still running means the previous dictation's teardown has not finished, so it is
        // finished here before a second task exists. The barrier costs nothing on the normal path,
        // where nothing is running.
        if isListening.load(ordering: .acquiring) {
            logger.warning("a live preview was still running when a new one started")
            stop()
            appendQueue.sync {}
        }

        lock.lock()
        let recognizer: SFSpeechRecognizer? = resolvedRecognizerLocked(isEnabledInSettings: isEnabledInSettings)
        let readiness: Readiness = Self.readiness(
            isEnabledInSettings: isEnabledInSettings,
            authorization: SFSpeechRecognizer.authorizationStatus(),
            hasRecognizer: recognizer != nil,
            supportsOnDeviceRecognition: recognizer?.supportsOnDeviceRecognition ?? false,
            isRecognizerAvailable: recognizer?.isAvailable ?? false,
            hasAudioBuffers: ring.isUsable
        )
        guard readiness.isReady, let recognizer else {
            lock.unlock()
            logger.notice("\(readiness.logMessage, privacy: .public)")
            return readiness
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        // The privacy boundary, honoured because `supportsOnDeviceRecognition` was just checked.
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        // Dictation, and no punctuation: the preview is thrown away, and asking for punctuation the
        // on-device model guesses at would only make it read as a worse version of the real result.
        request.taskHint = .dictation

        let generation: UInt64 = self.generation.wrappingAdd(1, ordering: .acquiringAndReleasing).newValue
        self.request = request
        partialCount = 0
        // `@Sendable` spelled out even though this type is not an actor and the closure is therefore
        // already nonisolated. The result handler is an imported Objective-C block, which is not
        // `Sendable`, so a closure like this one written inside an isolated type inherits that
        // isolation and Swift 6 inserts a runtime executor check that traps when the framework calls
        // back from anywhere else. `PermissionGate.requestSpeechRecognition` documents the crash that
        // taught us; this keyword is what keeps the answer here from depending on this type's
        // annotation staying off.
        task = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            self?.handle(result: result, error: error, generation: generation)
        }
        lock.unlock()

        isListening.store(true, ordering: .releasing)
        logger.notice("\(readiness.logMessage, privacy: .public)")
        return readiness
    }

    /// Ends the preview and releases its task. Idempotent, and safe on every path a dictation can
    /// end on: a normal stop, a cancel and a failure all reach it.
    ///
    /// A leaked task keeps the recogniser busy and costs the *next* dictation its preview, and
    /// `SFSpeechRecognizer` also caps a task at about one minute, so the release is not optional.
    func stop() {
        guard isListening.exchange(false, ordering: .acquiringAndReleasing) else {
            return
        }
        // Measured: `endAudio` is followed by three more results as the task finalises, which arrive
        // while the pipeline is already transcribing and can land after the panel has been cleared or
        // hidden. Bumping the generation here is what makes "the preview writes nothing once the
        // audio has stopped" true, so the panel keeps the last text it had during the run and the
        // final result never repaints a finished dictation.
        generation.wrappingAdd(1, ordering: .acquiringAndReleasing)
        // Teardown runs on the same serial queue as every append, so a buffer already in flight is
        // appended before `endAudio()` rather than after it, and the main actor never waits on the
        // Speech framework in the middle of a dictation.
        appendQueue.async { [self] in
            finishTask()
        }
    }

    /// Called from the audio tap callback. No allocation, no lock, no framework call.
    ///
    /// The buffer belongs to `AudioCapture`'s reused converter output, so it is copied here and
    /// never retained.
    func accept(_ buffer: AVAudioPCMBuffer) {
        guard isListening.load(ordering: .acquiring) else {
            return
        }
        ring.write(buffer)
        // The same wake primitive `AudioSpool` uses from this callback, rather than a
        // `DispatchQueue.async` that would allocate a block on the audio thread.
        appendSource.add(data: 1)
    }

    // MARK: - The serial queue

    /// Hands everything the tap has produced to the recogniser, in capture order.
    private func appendPendingBuffers() {
        lock.lock()
        let request: SFSpeechAudioBufferRecognitionRequest? = self.request
        lock.unlock()

        // The read index advances either way: a preview that has already been torn down drops what
        // is left rather than leaving the ring half full for the next dictation.
        ring.drain { buffer in
            request?.append(buffer)
        }
    }

    /// Ends the audio, finishes the task and releases both. `appendQueue` only.
    private func finishTask() {
        lock.lock()
        let request: SFSpeechAudioBufferRecognitionRequest? = self.request
        let task: SFSpeechRecognitionTask? = self.task
        let partialCount: Int = self.partialCount
        self.request = nil
        self.task = nil
        lock.unlock()

        guard let request else {
            return
        }
        ring.drain { buffer in
            request.append(buffer)
        }
        request.endAudio()
        // `endAudio` alone leaves the task processing what it holds; `finish` is what releases the
        // recogniser for the next dictation.
        task?.finish()

        let dropped: Int = ring.droppedBuffers.load(ordering: .relaxed)
        let rejected: Int = ring.rejectedBuffers.load(ordering: .relaxed)
        logger.notice(
            """
            live preview stopped: \(partialCount, privacy: .public) partial result(s), \
            \(dropped, privacy: .public) buffer(s) dropped, \
            \(rejected, privacy: .public) rejected
            """
        )
    }

    // MARK: - Results

    private func handle(result: SFSpeechRecognitionResult?, error: Error?, generation: UInt64) {
        guard self.generation.load(ordering: .acquiring) == generation else {
            return
        }
        if let error {
            // A task error is a preview that stops, never a dictation that fails. It is logged with
            // what it was rather than swallowed, because a preview that silently never appears is
            // indistinguishable from a preview nobody turned on.
            logger.error("live preview task failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        guard let result else {
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
        let text: String = Self.displayText(result.bestTranscription.formattedString)
        // `DispatchQueue.main` rather than `Task { @MainActor in }`, because partial results are only
        // useful in order and a task hop does not promise one. The recogniser's own handler queue
        // defaults to the main queue, so this is usually a same-queue hop.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                handler(text)
            }
        }
    }

    /// The cached recogniser, created on the first dictation that is allowed one. `lock` only.
    ///
    /// Cached because creating one per dictation is work the preview does not need to repeat, and
    /// never created at all when the setting is off, which is what makes "off" mean off.
    private func resolvedRecognizerLocked(isEnabledInSettings: Bool) -> SFSpeechRecognizer? {
        guard isEnabledInSettings else {
            return nil
        }
        if let recognizer {
            return recognizer
        }
        // The default handler queue is the main queue, which is what `handle` assumes.
        let created = SFSpeechRecognizer(locale: Self.locale)
        recognizer = created
        return created
    }
}

extension SFSpeechRecognizerAuthorizationStatus {
    /// A readable name for the log. `String(describing:)` on an imported `NS_ENUM` prints
    /// "SFSpeechRecognizerAuthorizationStatus(rawValue: 3)", which is not a thing to read at 2am
    /// while working out why a preview did not appear.
    var logName: String {
        switch self {
        case .notDetermined:
            return "not determined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .authorized:
            return "authorised"
        @unknown default:
            return "unknown status \(rawValue)"
        }
    }
}

/// Bounded single-producer, single-consumer handoff from the audio tap to the one queue that talks
/// to the Speech framework.
///
/// Same reasoning as `AudioSpool`, and one deliberate difference: this ring **drops** when it is
/// full and counts the drop, where the spool turns a full spool into a thrown error. The spool's
/// bytes are the dictation and losing one is a corrupt recording; these bytes are a preview that is
/// thrown away, so a dropped buffer is a preview that lags for a moment and must never be able to
/// fail a dictation.
private final class BufferRing: @unchecked Sendable {
    let droppedBuffers = Atomic<Int>(0)
    let rejectedBuffers = Atomic<Int>(0)

    /// Preallocated: the producer runs on the audio thread, where allocating risks a dropout.
    private let slots: [AVAudioPCMBuffer]
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)

    /// Empty when the format or a slot could not be built, which is the one state the caller has to
    /// refuse to start on rather than divide by.
    init(format: AVAudioFormat?, slotCount: Int, frameCapacity: AVAudioFrameCount) {
        guard let format else {
            slots = []
            return
        }
        var allocated: [AVAudioPCMBuffer] = []
        allocated.reserveCapacity(slotCount)
        for _ in 0..<max(1, slotCount) {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
                slots = []
                return
            }
            allocated.append(buffer)
        }
        slots = allocated
    }

    var isUsable: Bool {
        !slots.isEmpty
    }

    /// Audio thread. Copies the buffer into the next free slot, or counts a drop and returns.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard !slots.isEmpty else {
            return
        }
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.channelCount == 1,
              let source = buffer.floatChannelData else {
            rejectedBuffers.wrappingAdd(1, ordering: .relaxed)
            return
        }

        let frames = Int(buffer.frameLength)
        let write: UInt64 = writeIndex.load(ordering: .relaxed)
        // The consumer publishes its progress with a release, so an acquire here is what makes the
        // slot it has finished with safe to overwrite.
        let read: UInt64 = readIndex.load(ordering: .acquiring)
        guard write - read < UInt64(slots.count) else {
            droppedBuffers.wrappingAdd(1, ordering: .relaxed)
            return
        }

        let slot: AVAudioPCMBuffer = slots[Int(write % UInt64(slots.count))]
        guard frames > 0, frames <= Int(slot.frameCapacity), let destination = slot.floatChannelData else {
            rejectedBuffers.wrappingAdd(1, ordering: .relaxed)
            return
        }
        destination[0].update(from: source[0], count: frames)
        slot.frameLength = AVAudioFrameCount(frames)
        writeIndex.store(write &+ 1, ordering: .releasing)
    }

    /// Consumer queue only. Hands every published slot to `body` in capture order.
    func drain(_ body: (AVAudioPCMBuffer) -> Void) {
        while true {
            let read: UInt64 = readIndex.load(ordering: .relaxed)
            guard read < writeIndex.load(ordering: .acquiring) else {
                return
            }
            body(slots[Int(read % UInt64(slots.count))])
            readIndex.store(read &+ 1, ordering: .releasing)
        }
    }
}
