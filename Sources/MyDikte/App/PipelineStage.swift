import Foundation

/// Where a dictation is right now. Four states, per the plan: idle, recording, working, inserting.
///
/// `working` carries the activity it is working on rather than being split into four more states,
/// because the distinction is only ever a label on the indicator: every activity behaves
/// identically as far as the transition table is concerned (a shortcut press does nothing, a
/// cancel aborts), and encoding one label as three extra states would put that sameness in three
/// places.
enum PipelineStage: Sendable, Equatable {
    case idle
    case recording
    case working(Activity)
    case inserting
}

extension PipelineStage {
    /// What the pipeline is doing inside `working`.
    enum Activity: String, Sendable, Equatable, CaseIterable {
        case encoding
        case transcribing
        case cleaning
        case rewriting
    }

    /// The line the indicator panel shows. Written for someone glancing at a corner of the screen
    /// mid-sentence, so it is a state rather than a sentence.
    var title: String {
        switch self {
        case .idle:
            return "Idle"
        case .recording:
            return "Recording"
        case .inserting:
            return "Inserting"
        case .working(let activity):
            switch activity {
            case .encoding:
                return "Encoding"
            case .transcribing:
                return "Transcribing"
            case .cleaning:
                return "Cleaning up"
            case .rewriting:
                return "Rewriting"
            }
        }
    }

    /// Whether a dictation is under way at all, which is what decides whether the indicator is on
    /// screen and whether a fresh shortcut press can start anything.
    var isBusy: Bool {
        self != .idle
    }
}

/// The pipeline's transition table, kept apart from `DictationPipeline` so the decisions can be
/// tested without a microphone, a network or a keyboard.
///
/// Time is not read here and nothing is performed here: every input returns the one `Action` the
/// caller must carry out. That is what makes "a second shortcut press while working does nothing
/// and queues nothing" a property of a table rather than of a scattering of `guard` statements.
struct PipelineStateMachine: Sendable {
    /// Everything that can move the pipeline. The first four map onto `ShortcutCoordinator.Event`;
    /// the last three are the pipeline reporting its own progress back into the table.
    enum Input: Sendable, Equatable {
        /// The chord's first modifier went down: the cue to warm the audio engine.
        case warmUpRequested
        /// The gesture ended without becoming a dictation, so an open warm-up has to close.
        case warmUpAbandoned
        /// The chord completed, or the toggle fired while idle.
        case startRequested
        /// The chord was released, or the toggle fired while recording.
        case stopRequested
        /// The keyed toggle fired. Alternation is decided here, because `ShortcutCoordinator` only
        /// knows that the key was pressed, not whether a dictation is running.
        case toggleRequested
        case cancelRequested
        case activityChanged(PipelineStage.Activity)
        case insertionStarted
        /// The run finished, one way or another.
        case runEnded
    }

    /// What the caller must do about an input. `doNothing` is a first-class answer rather than an
    /// absence: it is the answer for every ignored shortcut press.
    enum Action: Sendable, Equatable {
        case doNothing
        case warmUpCapture
        case cancelWarmUp
        case beginRecording
        case stopAndProcess
        case discardRecording
        case abortWork
    }

    private(set) var stage: PipelineStage = .idle

    /// Whether the audio engine was warmed and not yet either used or cancelled. Tracked here
    /// rather than asked of `AudioCapture`, because reading that type's locked state from the main
    /// actor is exactly what its own doc comment forbids.
    private(set) var isEngineWarm: Bool = false

    mutating func handle(_ input: Input) -> Action {
        switch input {
        case .warmUpRequested:
            guard stage == .idle, !isEngineWarm else {
                return .doNothing
            }
            isEngineWarm = true
            return .warmUpCapture

        case .warmUpAbandoned:
            guard stage == .idle, isEngineWarm else {
                return .doNothing
            }
            isEngineWarm = false
            return .cancelWarmUp

        case .startRequested:
            return start()

        case .stopRequested:
            return stop()

        case .toggleRequested:
            switch stage {
            case .idle:
                return start()
            case .recording:
                return stop()
            case .working, .inserting:
                return .doNothing
            }

        case .cancelRequested:
            switch stage {
            case .idle:
                guard isEngineWarm else {
                    return .doNothing
                }
                isEngineWarm = false
                return .cancelWarmUp
            case .recording:
                stage = .idle
                isEngineWarm = false
                return .discardRecording
            case .working:
                stage = .idle
                return .abortWork
            case .inserting:
                // The paste sequence is four posted events about 30 ms apart. Aborting inside it
                // buys nothing and is the one way to leave a modifier held, so insertion is the
                // one state cancel does not interrupt.
                return .doNothing
            }

        case .activityChanged(let activity):
            // Guarded rather than assigned: a cancelled run keeps unwinding and can report one
            // more activity after the machine is back at idle, which must not put the indicator
            // back on screen.
            guard case .working = stage else {
                return .doNothing
            }
            stage = .working(activity)
            return .doNothing

        case .insertionStarted:
            guard case .working = stage else {
                return .doNothing
            }
            stage = .inserting
            return .doNothing

        case .runEnded:
            stage = .idle
            isEngineWarm = false
            return .doNothing
        }
    }

    private mutating func start() -> Action {
        guard stage == .idle else {
            return .doNothing
        }
        stage = .recording
        return .beginRecording
    }

    private mutating func stop() -> Action {
        guard stage == .recording else {
            return .doNothing
        }
        stage = .working(.encoding)
        // The engine is being stopped by the same action, so a later warm-up starts from cold.
        isEngineWarm = false
        return .stopAndProcess
    }
}

/// Per-stage durations, measured with a monotonic clock by the caller and converted here into the
/// record `DictationLog` writes.
///
/// A stage that never ran stays absent from the dictionary and comes out as `0`, which is the
/// contract Step 14 asked for: an offline reader must be able to tell "not run" from "not
/// measured", and a room-tone recording is exactly the case that matters (no `transcribeMs`, so no
/// API call was made).
struct StageTimings: Sendable, Equatable {
    enum Stage: Sendable, Hashable, CaseIterable {
        case capture
        case encode
        case transcribe
        case cleanup
        case insert
    }

    private var secondsByStage: [Stage: Double] = [:]

    mutating func record(_ stage: Stage, seconds: Double) {
        secondsByStage[stage] = seconds
    }

    /// `totalSeconds` is measured from shortcut release to insertion complete, because that is the
    /// number the user actually experiences and the one the Definition of Done asserts against
    /// 1.5 s. It is passed in rather than summed from the stages, so a gap between two stages
    /// cannot hide inside the total.
    func record(totalSeconds: Double) -> DictationRecord.Timings {
        DictationRecord.Timings(
            captureMs: milliseconds(.capture),
            encodeMs: milliseconds(.encode),
            transcribeMs: milliseconds(.transcribe),
            cleanupMs: milliseconds(.cleanup),
            insertMs: milliseconds(.insert),
            totalMs: Self.milliseconds(fromSeconds: totalSeconds)
        )
    }

    /// `Duration` to seconds. `ContinuousClock` is the monotonic source the pipeline measures with,
    /// and its `Duration` carries attoseconds, so this is the one place the conversion happens.
    static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private func milliseconds(_ stage: Stage) -> Double {
        Self.milliseconds(fromSeconds: secondsByStage[stage] ?? 0)
    }

    /// One decimal place: enough to read a 30 ms stage, short enough that a log line stays legible.
    private static func milliseconds(fromSeconds seconds: Double) -> Double {
        (seconds * 10_000).rounded() / 10
    }
}
