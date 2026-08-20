import Foundation
import Testing

@testable import MyDikte

/// The pipeline's transition table, tested with synthetic input because the real gesture, the
/// microphone and the network cannot be driven from a test process. Everything the orchestrator
/// decides rather than performs lives in these three pure types, which is why they are separable
/// from `DictationPipeline` itself.
@Suite("PipelineStateMachine")
struct PipelineStateMachineTests {
    @Test("the chord walks warm-up, recording and working in order")
    func chordWalksTheHappyPath() {
        var machine = PipelineStateMachine()

        #expect(machine.handle(.warmUpRequested) == .warmUpCapture)
        #expect(machine.stage == .idle)
        #expect(machine.handle(.startRequested) == .beginRecording)
        #expect(machine.stage == .recording)
        #expect(machine.handle(.stopRequested) == .stopAndProcess)
        #expect(machine.stage == .working(.encoding))
        #expect(machine.handle(.insertionStarted) == .doNothing)
        #expect(machine.stage == .inserting)
        #expect(machine.handle(.runEnded) == .doNothing)
        #expect(machine.stage == .idle)
    }

    @Test("a second start while working does nothing and queues nothing")
    func secondStartWhileWorkingIsIgnored() {
        var machine = PipelineStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.stopRequested)

        #expect(machine.handle(.startRequested) == .doNothing)
        #expect(machine.handle(.toggleRequested) == .doNothing)
        #expect(machine.handle(.warmUpRequested) == .doNothing)
        #expect(machine.stage == .working(.encoding))
    }

    @Test("the toggle alternates start and stop, because only the pipeline knows which it is")
    func toggleAlternates() {
        var machine = PipelineStateMachine()

        #expect(machine.handle(.toggleRequested) == .beginRecording)
        #expect(machine.stage == .recording)
        #expect(machine.handle(.toggleRequested) == .stopAndProcess)
        #expect(machine.stage == .working(.encoding))
    }

    @Test("cancel discards a recording, aborts work, and is refused during insertion")
    func cancelPerState() {
        var recording = PipelineStateMachine()
        _ = recording.handle(.startRequested)
        #expect(recording.handle(.cancelRequested) == .discardRecording)
        #expect(recording.stage == .idle)

        var working = PipelineStateMachine()
        _ = working.handle(.startRequested)
        _ = working.handle(.stopRequested)
        #expect(working.handle(.cancelRequested) == .abortWork)
        #expect(working.stage == .idle)

        var inserting = PipelineStateMachine()
        _ = inserting.handle(.startRequested)
        _ = inserting.handle(.stopRequested)
        _ = inserting.handle(.insertionStarted)
        #expect(inserting.handle(.cancelRequested) == .doNothing)
        #expect(inserting.stage == .inserting)
    }

    @Test("an abandoned chord closes the warm-up exactly once")
    func abandonedChordClosesTheWarmUp() {
        var machine = PipelineStateMachine()
        _ = machine.handle(.warmUpRequested)

        #expect(machine.handle(.warmUpAbandoned) == .cancelWarmUp)
        #expect(machine.handle(.warmUpAbandoned) == .doNothing)
        #expect(machine.stage == .idle)
    }

    @Test("cancel while idle closes an open warm-up and otherwise does nothing")
    func cancelWhileIdle() {
        var warm = PipelineStateMachine()
        _ = warm.handle(.warmUpRequested)
        #expect(warm.handle(.cancelRequested) == .cancelWarmUp)

        var cold = PipelineStateMachine()
        #expect(cold.handle(.cancelRequested) == .doNothing)
    }

    @Test("an activity only moves the stage while the run is working")
    func activityAppliesOnlyWhileWorking() {
        var machine = PipelineStateMachine()
        _ = machine.handle(.startRequested)
        _ = machine.handle(.activityChanged(.transcribing))
        #expect(machine.stage == .recording)

        _ = machine.handle(.stopRequested)
        _ = machine.handle(.activityChanged(.transcribing))
        #expect(machine.stage == .working(.transcribing))

        // The realistic race: cancel returns the machine to idle while the aborted task is still
        // unwinding and reports one more stage. It must not resurrect the panel.
        _ = machine.handle(.cancelRequested)
        _ = machine.handle(.activityChanged(.cleaning))
        #expect(machine.stage == .idle)
    }
}

@Suite("StageTimings")
struct StageTimingsTests {
    @Test("a stage that never ran is recorded as zero rather than omitted")
    func unrunStagesAreZero() {
        var timings = StageTimings()
        timings.record(.capture, seconds: 0.012)

        let recorded = timings.record(totalSeconds: 0.4)

        #expect(recorded.captureMs == 12.0)
        #expect(recorded.encodeMs == 0)
        #expect(recorded.transcribeMs == 0)
        #expect(recorded.cleanupMs == 0)
        #expect(recorded.insertMs == 0)
        #expect(recorded.totalMs == 400.0)
    }

    @Test("seconds become milliseconds at one decimal place")
    func secondsBecomeMilliseconds() {
        var timings = StageTimings()
        timings.record(.transcribe, seconds: 0.612_34)
        timings.record(.cleanup, seconds: 0.801)

        let recorded = timings.record(totalSeconds: 1.4321)

        #expect(recorded.transcribeMs == 612.3)
        #expect(recorded.cleanupMs == 801.0)
        #expect(recorded.totalMs == 1432.1)
    }

    @Test("a monotonic duration converts to seconds")
    func durationConvertsToSeconds() {
        #expect(abs(StageTimings.seconds(.milliseconds(1500)) - 1.5) < 0.000_001)
        #expect(abs(StageTimings.seconds(.microseconds(250)) - 0.000_25) < 0.000_000_1)
    }
}

@Suite("InsertionChoice")
struct InsertionChoiceTests {
    @Test("a cleanup failure inserts the raw transcript and carries the reason")
    func cleanupFailureInsertsRaw() {
        let choice = InsertionChoice.resolve(
            raw: "bugün servisleri güncelledim",
            cleanup: .failed(reason: "HTTP 401: invalid api key"),
            glossary: [],
            guardPolicy: .strict
        )

        #expect(choice.text == "bugün servisleri güncelledim")
        #expect(choice.message?.contains("HTTP 401") == true)
    }

    @Test("a paraphrase rejection inserts the raw transcript and carries the reason")
    func guardRejectionInsertsRaw() {
        let choice = InsertionChoice.resolve(
            raw: "Kubernetes üzerinde çalışan servisleri güncelledim",
            cleanup: .cleaned("Servisleri güncelledim."),
            glossary: ["Kubernetes"],
            guardPolicy: .strict
        )

        #expect(choice.text == "Kubernetes üzerinde çalışan servisleri güncelledim")
        #expect(choice.message?.contains("Kubernetes") == true)
    }

    @Test("an accepted cleanup inserts the cleaned text with no reason")
    func acceptedCleanupInsertsCleaned() {
        let choice = InsertionChoice.resolve(
            raw: "ıı bugün şey servisleri güncelledim yani",
            cleanup: .cleaned("Bugün servisleri güncelledim."),
            glossary: [],
            guardPolicy: .strict
        )

        #expect(choice.text == "Bugün servisleri güncelledim.")
        #expect(choice.message == nil)
        #expect(choice.concern == nil)
    }

    @Test("the prompt-rewrite mode skips the guard, since an English rewrite shares no words")
    func rewriteSkipsTheGuard() {
        let choice = InsertionChoice.resolve(
            raw: "toplantıyı perşembeye alalım",
            cleanup: .cleaned("Move the meeting to Thursday and confirm the attendees."),
            glossary: [],
            guardPolicy: .skipped
        )

        #expect(choice.text == "Move the meeting to Thursday and confirm the attendees.")
        #expect(choice.message == nil)
        #expect(choice.concern == nil)
    }

    /// A rejection reason quotes two word counts and nothing else, so without the candidate itself
    /// there is no way to tell a guard that is too strict from a model that is paraphrasing. That
    /// ambiguity let a wrong diagnosis survive a whole wave and four user-visible rejections, which
    /// is why the candidate is kept rather than discarded.
    @Test("a paraphrase rejection keeps the cleanup it rejected, so the guard can be tuned later")
    func guardRejectionKeepsTheRejectedCleanup() {
        let choice = InsertionChoice.resolve(
            raw: "Kubernetes üzerinde çalışan servisleri güncelledim",
            cleanup: .cleaned("Servisleri güncelledim."),
            glossary: ["Kubernetes"],
            guardPolicy: .strict
        )

        #expect(choice.rejectedCleanup == "Servisleri güncelledim.")
    }

    @Test("a cleanup failure has no candidate to keep, so it reports none")
    func cleanupFailureHasNoRejectedCandidate() {
        let choice = InsertionChoice.resolve(
            raw: "bugün servisleri güncelledim",
            cleanup: .failed(reason: "HTTP 401: invalid api key"),
            glossary: [],
            guardPolicy: .strict
        )

        #expect(choice.rejectedCleanup == nil)
    }

    @Test("an accepted cleanup reports no rejected candidate")
    func acceptedCleanupHasNoRejectedCandidate() {
        let choice = InsertionChoice.resolve(
            raw: "ıı bugün şey servisleri güncelledim yani",
            cleanup: .cleaned("Bugün servisleri güncelledim."),
            glossary: [],
            guardPolicy: .strict
        )

        #expect(choice.rejectedCleanup == nil)
    }

    /// Every concern goes into the record as data, whichever policy is in force, so the ledger counts
    /// the same terms in both modes and switching mode does not blind the counting.
    @Test("a strict rejection also carries the concern structurally, not only as a sentence")
    func strictRejectionCarriesTheConcern() {
        let choice = InsertionChoice.resolve(
            raw: "Kubernetes üzerinde çalışan servisleri güncelledim",
            cleanup: .cleaned("Servisleri güncelledim."),
            glossary: ["Kubernetes"],
            guardPolicy: .strict
        )

        #expect(choice.concern?.kind == .droppedGlossaryTerm)
        #expect(choice.concern?.term == "Kubernetes")
        #expect(choice.insertedRawInstead == true)
    }
}

/// Advisory mode, and the measurement behind it: over one day of real use this guard rejected three
/// correct cleanups and caught no genuine paraphrase, and each rejected cleanup was lost to the user.
/// So a concern now travels with the cleanup instead of replacing it, and strict mode stays reachable.
@Suite("InsertionChoice advisory mode")
struct InsertionChoiceAdvisoryTests {
    /// The measured `optimize` case, verbatim from the user's own log: Whisper heard "optimizir",
    /// the model repaired it, and the guard threw the whole cleanup away.
    @Test("an advisory concern inserts the cleanup rather than the raw transcript")
    func advisoryInsertsTheCleanup() {
        let choice = InsertionChoice.resolve(
            raw: "toplantıyı perşembeye alalım ve notları herkese gönderelim",
            cleanup: .cleaned("Toplantıyı perşembeye alalım ve faturaları herkese gönderelim."),
            glossary: [],
            guardPolicy: .advisory
        )

        #expect(choice.text == "Toplantıyı perşembeye alalım ve faturaları herkese gönderelim.")
        #expect(choice.insertedRawInstead == false)
    }

    @Test("an advisory concern is still detected, carried as data and surfaced as a sentence")
    func advisoryConcernIsSurfaced() {
        let choice = InsertionChoice.resolve(
            raw: "toplantıyı perşembeye alalım ve notları herkese gönderelim",
            cleanup: .cleaned("Toplantıyı perşembeye alalım ve faturaları herkese gönderelim."),
            glossary: [],
            guardPolicy: .advisory
        )

        #expect(choice.concern?.kind == .introducedWord)
        #expect(choice.concern?.term == "faturaları")
        #expect(choice.message?.contains("faturaları") == true)
    }

    /// Nothing was turned down, so there is no rejected candidate: the cleanup is at the caret, which
    /// is the whole point of advisory mode and the reason `rejectedCleanup` stops being the only place
    /// the text survives.
    @Test("an advisory concern rejects nothing, so it keeps no rejected candidate")
    func advisoryKeepsNoRejectedCandidate() {
        let choice = InsertionChoice.resolve(
            raw: "toplantıyı perşembeye alalım ve notları herkese gönderelim",
            cleanup: .cleaned("Toplantıyı perşembeye alalım ve faturaları herkese gönderelim."),
            glossary: [],
            guardPolicy: .advisory
        )

        #expect(choice.rejectedCleanup == nil)
    }

    @Test("an accepted cleanup in advisory mode is silent, exactly as in strict mode")
    func advisoryAcceptIsSilent() {
        let choice = InsertionChoice.resolve(
            raw: "ıı bugün şey servisleri güncelledim yani",
            cleanup: .cleaned("Bugün servisleri güncelledim."),
            glossary: [],
            guardPolicy: .advisory
        )

        #expect(choice.text == "Bugün servisleri güncelledim.")
        #expect(choice.message == nil)
        #expect(choice.concern == nil)
    }

    /// Advisory is only about the guard. A cleanup that genuinely failed still inserts the raw
    /// transcript and still reports the failure, which is the contract every other failure path in
    /// the pipeline depends on.
    @Test("a failed cleanup is unaffected by advisory mode")
    func advisoryLeavesTheFailureContractAlone() {
        let choice = InsertionChoice.resolve(
            raw: "bugün servisleri güncelledim",
            cleanup: .failed(reason: "HTTP 401: invalid api key"),
            glossary: [],
            guardPolicy: .advisory
        )

        #expect(choice.text == "bugün servisleri güncelledim")
        #expect(choice.message?.contains("HTTP 401") == true)
        #expect(choice.insertedRawInstead == true)
        #expect(choice.concern == nil)
    }

    @Test("the same input under both policies differs only in what reaches the caret")
    func policiesDifferOnlyInTheOutcome() {
        let raw = "toplantıyı perşembeye alalım ve notları herkese gönderelim"
        let cleaned = "Toplantıyı perşembeye alalım ve faturaları herkese gönderelim."

        let advisory = InsertionChoice.resolve(raw: raw, cleanup: .cleaned(cleaned), glossary: [], guardPolicy: .advisory)
        let strict = InsertionChoice.resolve(raw: raw, cleanup: .cleaned(cleaned), glossary: [], guardPolicy: .strict)

        #expect(advisory.concern == strict.concern)
        #expect(advisory.text == cleaned)
        #expect(strict.text == raw)
        #expect(strict.rejectedCleanup == cleaned)
    }
}

/// Which policy a dictation runs under is resolved once per run, from the settings the run started
/// with, in the same place every other per-run decision is resolved.
@Suite("Paraphrase guard policy")
struct GuardPolicyTests {
    @Test("the default settings run the guard in advisory mode")
    func defaultIsAdvisory() {
        #expect(PipelineConfiguration(settings: .default).guardPolicy(for: .dictate) == .advisory)
    }

    @Test("turning advisory off restores strict mode, which is the way back the user asked for")
    func advisoryOffIsStrict() {
        var settings = Settings.default
        settings.advisoryParaphraseGuard = false

        #expect(PipelineConfiguration(settings: settings).guardPolicy(for: .dictate) == .strict)
    }

    /// Mode 2 rewrites Turkish into an English prompt, which shares almost no words with its input, so
    /// the guard does not run there at all. That is independent of the advisory setting, in both
    /// positions.
    @Test("Mode 2 skips the guard whatever the advisory setting says")
    func modeTwoSkipsTheGuard() {
        var settings = Settings.default
        #expect(PipelineConfiguration(settings: settings).guardPolicy(for: .prompt) == .skipped)

        settings.advisoryParaphraseGuard = false
        #expect(PipelineConfiguration(settings: settings).guardPolicy(for: .prompt) == .skipped)
    }
}

/// Zero captured buffers and a room full of quiet air are different failures with different fixes,
/// and reporting the first as the second is what sent a real dictation attempt looking for a
/// microphone problem that did not exist. Measured on this machine: a 1.4 s push-to-talk hold with
/// AirPods as the input device produced 0 frames and read "No speech detected (peak -120 dB)", while
/// the same device over a 5 s window captured 5.23 s of audio normally.
@Suite("Empty capture")
struct EmptyCaptureTests {
    @Test("a capture that produced buffers has no empty-capture failure")
    func capturedAudioHasNoFailure() {
        #expect(DictationPipeline.emptyCaptureReason(chunkCount: 12, heldSeconds: 1.4) == nil)
    }

    @Test("zero buffers reports the input device, not the absence of speech")
    func zeroBuffersReportsTheDevice() {
        let reason = DictationPipeline.emptyCaptureReason(chunkCount: 0, heldSeconds: 1.4)
        #expect(reason != nil)
        #expect(reason?.contains("no audio") == true)
        #expect(reason?.lowercased().contains("no speech") == false)
    }

    @Test("the message names the hold that was too short, so the next attempt can be longer")
    func messageNamesTheHold() {
        let reason = DictationPipeline.emptyCaptureReason(chunkCount: 0, heldSeconds: 1.4)
        #expect(reason?.contains("1.4") == true)
    }

    @Test("a short hold is told to hold longer; a long one is not, since that is a real fault")
    func adviceDependsOnTheHold() {
        let short = DictationPipeline.emptyCaptureReason(chunkCount: 0, heldSeconds: 1.0)
        let long = DictationPipeline.emptyCaptureReason(chunkCount: 0, heldSeconds: 8.0)
        #expect(short?.contains("Bluetooth") == true)
        #expect(long?.contains("Bluetooth") == false)
    }
}

@Suite("PipelineConfiguration")
struct PipelineConfigurationTests {
    @Test("an unset model id resolves to the model this plan measured")
    func unsetModelIdsResolveToMeasuredDefaults() {
        let configuration = PipelineConfiguration(settings: .default)

        #expect(configuration.transcriptionModelId == "whisper-large-v3")
        #expect(configuration.cleanupModelId == "openai/gpt-oss-120b")
    }

    @Test("the unedited default chat endpoint resolves to Groq, a chosen one is honoured")
    func chatEndpointResolution() {
        let untouched = PipelineConfiguration(settings: .default)
        #expect(untouched.chatEndpoint(for: .dictate) == PipelineConfiguration.groqChatEndpoint)
        #expect(untouched.chatEndpoint(for: .prompt) == PipelineConfiguration.groqChatEndpoint)

        var chosen = Settings.default
        chosen.cleanupEndpoint = "https://openrouter.ai/api/v1/chat/completions"
        let honoured = PipelineConfiguration(settings: chosen)
        #expect(honoured.chatEndpoint(for: .dictate) == "https://openrouter.ai/api/v1/chat/completions")
    }

    /// The endpoint that used to be the default is now just another endpoint. While OpenAI's URL was
    /// the default value, resolution could not tell "nobody touched this field" from "the user chose
    /// OpenAI", and the untouched reading won: the pane displayed an OpenAI endpoint, every request
    /// went to Groq, and choosing OpenAI on purpose was impossible to express.
    @Test("an explicitly typed OpenAI endpoint is honoured rather than rewritten to Groq")
    func explicitOpenAIEndpointIsHonoured() {
        var chosen = Settings.default
        chosen.cleanupEndpoint = "https://api.openai.com/v1/chat/completions"

        let configuration = PipelineConfiguration(settings: chosen)
        #expect(configuration.chatEndpoint(for: .dictate) == "https://api.openai.com/v1/chat/completions")
    }

    @Test("whitespace alone counts as untouched, so a stray space does not become the endpoint")
    func whitespaceEndpointResolvesToTheDefault() {
        var chosen = Settings.default
        chosen.cleanupEndpoint = "   "

        let configuration = PipelineConfiguration(settings: chosen)
        #expect(configuration.chatEndpoint(for: .dictate) == PipelineConfiguration.groqChatEndpoint)
    }

    @Test("the Keychain account follows the endpoint host, never a silent fallback to the other key")
    func keychainAccountFollowsTheEndpoint() {
        #expect(
            PipelineConfiguration.chatKeychainAccount(forEndpoint: PipelineConfiguration.groqChatEndpoint)
                == "cleanup-groq"
        )
        #expect(
            PipelineConfiguration.chatKeychainAccount(forEndpoint: "https://openrouter.ai/api/v1/chat/completions")
                == "cleanup-openrouter"
        )
    }

    @Test("the reply budget is sized to the transcript rather than left open")
    func maxTokensIsSizedToTheInput() {
        let short = PipelineConfiguration.maxTokens(forTranscript: "iki kelime")
        let long = PipelineConfiguration.maxTokens(forTranscript: String(repeating: "kelime ", count: 400))

        #expect(short == PipelineConfiguration.minimumReplyTokens)
        #expect(long == PipelineConfiguration.maximumReplyTokens)
        #expect(short < long)
    }

    /// The measured failure this headroom exists for: a 22-word transcript sized at six tokens per
    /// word gave the model 132 tokens, it spent them all on reasoning it was told to hide, and the
    /// reply came back HTTP 200 with empty content, which the pipeline can only read as a cleanup
    /// failure.
    @Test("the budget always covers the reasoning tokens the reply never shows")
    func maxTokensCoversHiddenReasoning() {
        let measuredCase = PipelineConfiguration.maxTokens(
            forTranscript: String(repeating: "kelime ", count: 22)
        )

        #expect(measuredCase >= PipelineConfiguration.reasoningHeadroomTokens)
        #expect(measuredCase > 132)
    }

    /// The second measured loss, and the reason the floor moved. A real 23-word Turkish dictation
    /// returned empty content, and the identical request measured directly spent 717, 596 and 580
    /// completion tokens across three runs against the 768 budget in force at the time. The answer is
    /// about 50 tokens of that, so the old floor sat 51 tokens from the ceiling and any run that
    /// reasoned slightly longer produced nothing at all.
    @Test("a real 23-word dictation clears the worst reasoning cost observed for it")
    func budgetClearsMeasuredReasoningForARealDictation() {
        let transcript = String(repeating: "kelime ", count: 23)
        let budget = PipelineConfiguration.maxTokens(forTranscript: transcript)

        let worstObservedCompletion = 717
        #expect(budget > worstObservedCompletion)
        // Not merely past it: past it with room, since 768 failed while sitting 51 tokens clear.
        #expect(budget >= worstObservedCompletion * 2)
    }
}

/// A quality-gate rejection reports a log-probability, which is the right thing to record and the
/// wrong thing to show alone. Measured on a real Mode 2 attempt: a 3.5 s hold, 1.13 s of it a
/// Bluetooth link opening, left 2.4 s of audio and an `avg_logprob` of -1.64 against a -1.0 limit.
/// The number was correct and unactionable; the length was the cause.
@Suite("Short audio advice")
struct ShortAudioAdviceTests {
    @Test("a short clip is told the length and what to do about it")
    func shortClipGetsAdvice() {
        let advice = DictationPipeline.shortAudioAdvice(seconds: 2.4)
        #expect(advice.contains("2.4"))
        #expect(advice.contains("hold for"))
    }

    @Test("a long clip is given its length without being told to hold longer, since that is not the cause")
    func longClipIsNotToldToHoldLonger() {
        let advice = DictationPipeline.shortAudioAdvice(seconds: 18.0)
        #expect(advice.contains("18.0"))
        #expect(advice.contains("hold for") == false)
    }

    @Test("an unknown length adds nothing rather than inventing a number")
    func unknownLengthAddsNothing() {
        #expect(DictationPipeline.shortAudioAdvice(seconds: 0) == "")
    }
}

/// "The cleanup endpoint returned no message content" reads like a provider outage. The measured
/// instance was not one: a 3.3 s hold, 1.6 s of it a Bluetooth link opening, produced the three-word
/// transcript "Ben olacak görelim." and Mode 2 had nothing to rewrite. The same prompt and budget
/// turned a real request into a full English prompt on the first try.
@Suite("Thin transcript advice")
struct ThinTranscriptAdviceTests {
    private static let empty = ChatClient.ChatClientError.emptyResponse

    @Test("a three-word Mode 2 transcript is told what Mode 2 needs")
    func thinPromptTranscriptGetsAdvice() {
        let advice = DictationPipeline.thinTranscriptAdvice(
            transcript: "Ben olacak görelim.",
            mode: .prompt,
            error: Self.empty
        )
        #expect(advice.contains("3 word"))
        #expect(advice.contains("Mode 2"))
    }

    @Test("a thin Mode 1 transcript is not told about Mode 2, which it is not using")
    func thinDictateTranscriptGetsItsOwnAdvice() {
        let advice = DictationPipeline.thinTranscriptAdvice(
            transcript: "tamam peki", mode: .dictate, error: Self.empty
        )
        #expect(advice.contains("2 word"))
        #expect(advice.contains("Mode 2") == false)
    }

    @Test("a full transcript gets no length advice, since length is not the cause")
    func fullTranscriptGetsNoAdvice() {
        let transcript = "bugün Kubernetes üzerinde çalışan bütün servisleri güncelledim ve panelleri açtım"
        #expect(DictationPipeline.thinTranscriptAdvice(
            transcript: transcript, mode: .prompt, error: Self.empty) == "")
    }

    /// A network error already says what it is; appending a guess about length would be noise.
    @Test("only an empty response is annotated, not every cleanup failure")
    func onlyEmptyResponseIsAnnotated() {
        let advice = DictationPipeline.thinTranscriptAdvice(
            transcript: "kısa",
            mode: .prompt,
            error: ChatClient.ChatClientError.serverError(statusCode: 503, body: "upstream unavailable")
        )
        #expect(advice == "")
    }
}

/// Which recordings a bare Return or Space may end. The pipeline is the only thing that knows a
/// dictation is in flight and how it was started, so this is its half of the stop-key decision; the
/// coordinator owns the other half (which keys, unmodified, and whether the setting is on).
@Suite("Latched recording")
struct LatchedRecordingTests {
    @Test("a recording started by a keyed shortcut is latched, so a stop key may end it")
    func keyedRecordingIsLatched() {
        #expect(DictationPipeline.isLatchedRecording(stage: .recording, trigger: .latched))
    }

    /// The push-to-talk gesture ends when the keys come up, so it needs nothing else to end it, and
    /// its modifiers are held while it runs: a Space pressed there is a modified press belonging to
    /// the focused application.
    @Test("a push-to-talk recording is not latched, because releasing the chord already ends it")
    func chordRecordingIsNotLatched() {
        #expect(!DictationPipeline.isLatchedRecording(stage: .recording, trigger: .heldChord))
    }

    @Test("no stage other than recording is latched, so the keys are watched for seconds and not longer")
    func onlyTheRecordingStageIsLatched() {
        let stages: [PipelineStage] = [
            .idle,
            .working(.encoding),
            .working(.transcribing),
            .working(.cleaning),
            .working(.rewriting),
            .inserting,
        ]

        for stage in stages {
            #expect(!DictationPipeline.isLatchedRecording(stage: stage, trigger: .latched))
            #expect(!DictationPipeline.isLatchedRecording(stage: stage, trigger: .heldChord))
        }
    }
}

/// The "speak now" cue fires on a level reading rather than on the call that starts the engine,
/// because those are 1.5 s apart on a Bluetooth microphone and the user asked for the later one.
@Suite("Microphone live cue")
struct MicrophoneLiveCueTests {
    @Test("exact zeros are not a live microphone, which is what a Bluetooth link reports before it opens")
    func exactZerosAreNotLive() {
        #expect(DictationPipeline.isMicrophoneLive(level: 0.0) == false)
    }

    @Test("the threshold is the leading-trim silence floor carried through the level gain")
    func thresholdMatchesTheSilenceFloor() {
        let floor = Float(LeadingSilence.silenceRMS) * AudioCapture.levelGain

        #expect(DictationPipeline.isMicrophoneLive(level: floor) == false)
        #expect(DictationPipeline.isMicrophoneLive(level: floor * 1.01) == true)
    }

    @Test("room tone counts as live, so the cue fires on breath rather than waiting for a word")
    func roomToneCountsAsLive() {
        // 0.0008 raw is what a quiet room measured at, against 0.0 for a link that is not open.
        #expect(DictationPipeline.isMicrophoneLive(level: 0.0008 * AudioCapture.levelGain) == true)
    }

    @Test("speech at a normal distance is comfortably live")
    func speechIsLive() {
        // 0.02 raw is the figure the level gain itself was chosen against.
        #expect(DictationPipeline.isMicrophoneLive(level: 0.02 * AudioCapture.levelGain) == true)
    }

    @Test("the two cues are distinct cases, since telling them apart by ear is the whole point")
    func theTwoCuesAreDistinct() {
        #expect(AudioCue.allCases.count == 2)
        #expect(AudioCue.allCases.contains(.micLive))
        #expect(AudioCue.allCases.contains(.insertComplete))
    }
}

/// Where a dictation's text comes from. The realtime socket is already streaming the same audio, so
/// uploading it again is a choice about accuracy against cost, and all three conditions below have
/// to hold before the upload can be skipped.
@Suite("Realtime transcript source")
struct RealtimeTranscriptSourceTests {
    private func configuration(
        previewEnabled: Bool,
        previewProvider: Settings.LivePreviewProvider,
        batchVerification: Bool
    ) -> PipelineConfiguration {
        var settings = Settings.default
        settings.livePreviewEnabled = previewEnabled
        settings.livePreviewProvider = previewProvider
        settings.batchVerification = batchVerification
        return PipelineConfiguration(settings: settings)
    }

    @Test("the realtime stream is the transcript when the ElevenLabs preview runs and verification is off")
    func realtimeIsAuthoritativeByDefault() {
        let configuration = configuration(
            previewEnabled: true,
            previewProvider: .elevenLabs,
            batchVerification: false
        )
        #expect(configuration.usesRealtimeTranscript == true)
    }

    @Test("asking for verification puts the batch upload back")
    func verificationRestoresTheUpload() {
        let configuration = configuration(
            previewEnabled: true,
            previewProvider: .elevenLabs,
            batchVerification: true
        )
        #expect(configuration.usesRealtimeTranscript == false)
    }

    @Test("no socket means no realtime transcript, whichever way it is missing")
    func withoutASocketTheUploadIsTheOnlySource() {
        // Apple's recogniser runs on device so its output can be thrown away; it has never been
        // allowed near the caret and this is where that stays true.
        #expect(
            configuration(previewEnabled: true, previewProvider: .apple, batchVerification: false)
                .usesRealtimeTranscript == false
        )
        #expect(
            configuration(previewEnabled: false, previewProvider: .elevenLabs, batchVerification: false)
                .usesRealtimeTranscript == false
        )
    }

    @Test("the default settings upload, because the preview defaults to on device")
    func defaultsUpload() {
        #expect(PipelineConfiguration(settings: .default).usesRealtimeTranscript == false)
        #expect(Settings.default.batchVerification == false)
    }

    @Test("the realtime deadline is generous against the measured commit round trip")
    func theDeadlineIsGenerous() {
        // 192 to 313 ms measured across five recordings; three seconds is an order of magnitude out,
        // which is deliberate because missing it costs a whole batch call on top of the wait.
        #expect(PipelineConfiguration.realtimeTranscriptTimeout == .seconds(3))
    }

    @Test("a timed-out or absent socket is an outcome, not a thrown error")
    func outcomesAreValues() {
        // Nothing here may fail a dictation: each of these has to leave the upload reachable.
        let outcomes: [ElevenLabsLivePreview.TranscriptOutcome] = [
            .transcript("merhaba"),
            .timedOut,
            .notRunning,
        ]
        #expect(outcomes.count == 3)
        #expect(outcomes.contains(.timedOut))
        #expect(ElevenLabsLivePreview.TranscriptOutcome.transcript("a") != .transcript("b"))
    }
}
