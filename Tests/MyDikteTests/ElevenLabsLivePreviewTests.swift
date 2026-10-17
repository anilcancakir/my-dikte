import Foundation
import Testing

@testable import MyDikte

/// Pure-logic coverage for the realtime preview: the socket URL, the message shape, the PCM
/// conversion and the readiness decision. The live socket (real key, real microphone, partials
/// appearing in the indicator) is verified by hand, because nothing in a test process can read the
/// panel's text: it publishes no accessibility children.
@Suite("ElevenLabsLivePreview")
struct ElevenLabsLivePreviewTests {
    // MARK: Socket URL

    @Test("the socket URL pins the realtime model, 16 kHz PCM, manual commit and the language")
    func socketURLCarriesTheRequiredParameters() {
        let url = ElevenLabsLivePreview.socketURL(glossaryTerms: [], language: "tr")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        #expect(url.scheme == "wss")
        #expect(url.host == "api.elevenlabs.io")
        #expect(url.path == "/v1/speech-to-text/realtime")
        #expect(items.contains(URLQueryItem(name: "model_id", value: "scribe_v2_realtime")))
        #expect(items.contains(URLQueryItem(name: "audio_format", value: "pcm_16000")))
        #expect(items.contains(URLQueryItem(name: "commit_strategy", value: "manual")))
        #expect(items.contains(URLQueryItem(name: "language_code", value: "tr")))
        #expect(items.contains(URLQueryItem(name: "no_verbatim", value: "true")))
    }

    @Test("the socket URL carries one keyterms item per glossary term")
    func socketURLRepeatsKeyterms() {
        let url = ElevenLabsLivePreview.socketURL(
            glossaryTerms: [
                "Kubernetes",
                "PyQt",
            ],
            language: "tr"
        )
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        #expect(items.filter { $0.name == "keyterms" }.count == 2)
        #expect(items.contains(URLQueryItem(name: "keyterms", value: "Kubernetes")))
        #expect(items.contains(URLQueryItem(name: "keyterms", value: "PyQt")))
    }

    @Test("realtime caps keyterms tighter than batch does, at 20 characters and 50 terms")
    func socketURLAppliesTheRealtimeKeytermLimits() {
        // 21 characters: eligible for the batch endpoint's 50-character cap, not for this one.
        let tooLongForRealtime = String(repeating: "a", count: 21)
        #expect(ElevenLabsTranscriptionProvider.isEligibleKeyterm(tooLongForRealtime) == true)
        #expect(ElevenLabsLivePreview.isEligibleKeyterm(tooLongForRealtime) == false)

        let overCap = (0..<(ElevenLabsLivePreview.realtimeKeytermLimit + 10)).map { "t\($0)" }
        let url = ElevenLabsLivePreview.socketURL(glossaryTerms: overCap, language: "tr")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

        #expect(items.filter { $0.name == "keyterms" }.count == ElevenLabsLivePreview.realtimeKeytermLimit)
    }

    // MARK: Message shape

    @Test("an audio chunk message carries the base64 payload, the commit flag and the sample rate")
    func audioChunkMessageMatchesTheProtocol() {
        let message = ElevenLabsLivePreview.audioChunkMessage(base64Audio: "AAAB", commit: false)

        #expect(message.contains("\"message_type\":\"input_audio_chunk\""))
        #expect(message.contains("\"audio_base_64\":\"AAAB\""))
        #expect(message.contains("\"commit\":false"))
        #expect(message.contains("\"sample_rate\":16000"))
        // It has to be valid JSON: it is assembled as a string to keep serialisation off the path
        // that runs once per chunk, which is exactly the shortcut that can produce a broken body.
        let decoded = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        #expect(decoded?["message_type"] as? String == "input_audio_chunk")
    }

    @Test("the commit message is an empty chunk with the flag set")
    func commitMessageIsAnEmptyChunk() {
        let message = ElevenLabsLivePreview.audioChunkMessage(base64Audio: "", commit: true)

        #expect(message.contains("\"audio_base_64\":\"\""))
        #expect(message.contains("\"commit\":true"))
        let decoded = try? JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any]
        #expect(decoded?["commit"] as? Bool == true)
    }

    // MARK: PCM conversion

    @Test("float samples become little-endian 16-bit PCM")
    func convertsToLittleEndianPCM16() {
        let data = ElevenLabsLivePreview.pcm16Data(from: [0.0, 1.0, -1.0])

        #expect(data.count == 6)
        // 0.0 -> 0
        #expect(data[0] == 0 && data[1] == 0)
        // 1.0 -> Int16.max, little-endian
        #expect(data[2] == 0xFF && data[3] == 0x7F)
        // -1.0 -> -Int16.max, which is 0x8001 rather than 0x8000
        #expect(data[4] == 0x01 && data[5] == 0x80)
    }

    @Test("a sample past full scale is clamped rather than allowed to wrap into a click")
    func clampsSamplesBeyondFullScale() {
        let data = ElevenLabsLivePreview.pcm16Data(from: [2.5, -2.5])

        #expect(data.count == 4)
        #expect(data[0] == 0xFF && data[1] == 0x7F)
        #expect(data[2] == 0x01 && data[3] == 0x80)
    }

    @Test("no samples means no bytes, so a wake with an empty ring sends nothing")
    func emptyFramesProduceNoData() {
        #expect(ElevenLabsLivePreview.pcm16Data(from: []).isEmpty)
    }

    // MARK: Readiness

    @Test("the setting is checked before the key, so off means nothing is read")
    func disabledOutranksAMissingKey() {
        let readiness = ElevenLabsLivePreview.readiness(
            isEnabledInSettings: false,
            hasAPIKey: false,
            keychainAccount: "transcription-elevenlabs",
            hasAudioBuffers: true
        )

        #expect(readiness == .disabledBySetting)
        #expect(readiness.isReady == false)
    }

    @Test("a missing key names the account, which is the one thing the user can act on")
    func missingKeyNamesTheAccount() {
        let readiness = ElevenLabsLivePreview.readiness(
            isEnabledInSettings: true,
            hasAPIKey: false,
            keychainAccount: "transcription-elevenlabs",
            hasAudioBuffers: true
        )

        #expect(readiness == .missingAPIKey(account: "transcription-elevenlabs"))
        #expect(readiness.logMessage.contains("transcription-elevenlabs"))
        #expect(readiness.logMessage.contains("Keys pane"))
    }

    @Test("unusable buffers keep the preview off rather than dividing by an empty ring")
    func unusableBuffersAreNotReady() {
        let readiness = ElevenLabsLivePreview.readiness(
            isEnabledInSettings: true,
            hasAPIKey: true,
            keychainAccount: "transcription-elevenlabs",
            hasAudioBuffers: false
        )

        #expect(readiness == .audioBufferUnavailable)
    }

    @Test("everything present is ready, and says which model it streams to")
    func readyWhenEverythingIsPresent() {
        let readiness = ElevenLabsLivePreview.readiness(
            isEnabledInSettings: true,
            hasAPIKey: true,
            keychainAccount: "transcription-elevenlabs",
            hasAudioBuffers: true
        )

        #expect(readiness == .ready)
        #expect(readiness.logMessage.contains(ElevenLabsLivePreview.modelId))
    }

    // MARK: Display

    @Test("both preview backends truncate identically, so the indicator cannot drift")
    func displayTextMatchesTheOnDeviceBackend() {
        let long = String(repeating: "kelime ", count: 40)

        #expect(ElevenLabsLivePreview.displayText(long) == LivePreview.displayText(long))
        #expect(ElevenLabsLivePreview.displayCharacterLimit == LivePreview.displayCharacterLimit)
    }
}

/// The trailing silence sent before the commit. The user asked to "wait a second before finishing",
/// and this is the shape that request actually takes: the recogniser does not need the caller to
/// wait, it needs the audio not to stop mid-syllable.
@Suite("Realtime trailing silence")
struct RealtimeTrailingSilenceTests {
    @Test("one second of silence at the capture rate, as true digital zero")
    func trailingSilenceIsOneSecondOfZero() {
        let frames = ElevenLabsLivePreview.trailingSilence()

        #expect(frames.count == Int(AudioCapture.sampleRate * ElevenLabsLivePreview.trailingSilenceSeconds))
        #expect(frames.count == 16_000)
        #expect(frames.allSatisfy { $0 == 0 })
    }

    @Test("it encodes to the byte count the protocol expects, and to zeros")
    func trailingSilenceEncodesToPCM16Zeros() {
        let data = ElevenLabsLivePreview.pcm16Data(from: ElevenLabsLivePreview.trailingSilence())

        // 16 kHz, one second, 16-bit mono.
        #expect(data.count == 32_000)
        #expect(data.allSatisfy { $0 == 0 })
    }

    @Test("the silence is under the documented one-second-per-chunk ceiling")
    func trailingSilenceFitsOneChunk() {
        // ElevenLabs documents 0.1 to 1 second per chunk. Exactly one second is the ceiling, so this
        // has to stay at or below it or the send has to be split.
        #expect(ElevenLabsLivePreview.trailingSilenceSeconds <= 1.0)
    }
}

/// The transcript of one realtime session, assembled from every committed segment.
///
/// The regression it guards: the server commits on its own after about 36 s of audio, and the first
/// version kept only the segment that answered the final commit, so a 44.6 s dictation pasted its
/// last sentence and nothing else.
@Suite("Realtime transcript assembly")
struct RealtimeTranscriptTests {
    private typealias Transcript = ElevenLabsLivePreview.Transcript

    @Test("every committed segment is kept, in order, and joined with one space")
    func joinsEveryCommittedSegment() {
        var transcript = Transcript()
        transcript.recordCommit(isFinal: false)
        transcript.recordCommitted(" İlk paragraf burada bitiyor. ")
        transcript.recordCommit(isFinal: true)
        transcript.recordCommitted("Son cümle.")

        #expect(transcript.text == "İlk paragraf burada bitiyor. Son cümle.")
    }

    @Test("an empty committed segment answers its commit and adds nothing")
    func emptySegmentAnswersWithoutAddingText() {
        var transcript = Transcript()
        transcript.recordCommit(isFinal: false)
        transcript.recordCommitted("Bir.")
        transcript.recordCommit(isFinal: true)
        transcript.recordCommitted("")

        #expect(transcript.isSettled)
        #expect(transcript.text == "Bir.")
    }

    @Test("it settles only once the final commit is sent and every commit has had its reply")
    func settlesOnTheLastReply() {
        var transcript = Transcript()
        transcript.recordCommit(isFinal: false)
        #expect(!transcript.isSettled)

        transcript.recordCommit(isFinal: true)
        transcript.recordCommitted("Birinci.")
        // The first reply answers the earlier commit; the final one is still in flight.
        #expect(!transcript.isSettled)

        transcript.recordCommitted("İkinci.")
        #expect(transcript.isSettled)
    }

    @Test("a reply that lands before the final commit is sent does not settle the session")
    func intermediateReplyDoesNotSettle() {
        var transcript = Transcript()
        transcript.recordCommit(isFinal: false)
        transcript.recordCommitted("Ara segment.")

        #expect(!transcript.isSettled)
    }

    @Test("a reply nobody counted never settles, so the last segment is waited for rather than lost")
    func overCountDoesNotSettle() {
        var transcript = Transcript()
        // A server commit the client did not send: one reply more than the commits.
        transcript.recordCommitted("Sunucunun kendi segmenti.")
        transcript.recordCommit(isFinal: true)
        transcript.recordCommitted("Son segment.")

        #expect(transcript.repliesReceived > transcript.commitsSent)
        #expect(!transcript.isSettled)
    }

    @Test("a throttled commit counts as answered, so a waiter is not left to time out")
    func throttledCommitCountsAsAReply() {
        var transcript = Transcript()
        transcript.recordCommit(isFinal: false)
        transcript.recordCommitted("Tamamı burada.")
        transcript.recordCommit(isFinal: true)
        transcript.recordThrottled()

        #expect(transcript.isSettled)
        #expect(transcript.text == "Tamamı burada.")
    }

    @Test("the preview shows the committed segments followed by the partial being spoken now")
    func displayTextKeepsEarlierSegments() {
        var transcript = Transcript()
        transcript.recordCommit(isFinal: false)
        transcript.recordCommitted("Önceki kısım.")
        transcript.recordPartial("şu an söylenen")

        #expect(transcript.displayText == "Önceki kısım. şu an söylenen")
    }

    @Test("a commit clears the partial it finalised, so the preview does not repeat it")
    func committedSegmentReplacesItsPartial() {
        var transcript = Transcript()
        transcript.recordPartial("yarım cümle")
        transcript.recordCommit(isFinal: true)
        transcript.recordCommitted("Yarım cümle tamamlandı.")

        #expect(transcript.displayText == "Yarım cümle tamamlandı.")
    }
}

/// When the client commits a segment itself, so the server's own 36 s commit never fires.
@Suite("Realtime commit schedule")
struct RealtimeCommitScheduleTests {
    private typealias Schedule = ElevenLabsLivePreview.CommitSchedule

    /// One chunk as the send path produces it: about 170 ms.
    private static let chunk: Double = 0.17
    private static let floor: Float = 0.002
    private static let speech: Float = 0.12

    /// Speech until `seconds` of audio are uncommitted, after one floor-level chunk so the schedule
    /// has a noise floor to measure pauses against.
    private static func schedule(speakingFor seconds: Double) -> Schedule {
        var schedule = Schedule()
        _ = feed(&schedule, [floor])
        while schedule.uncommittedSeconds + chunk < seconds {
            _ = feed(&schedule, [speech])
        }
        return schedule
    }

    /// Whether each chunk, in order, committed the segment.
    private static func feed(_ schedule: inout Schedule, _ levels: [Float]) -> [Bool] {
        levels.map { schedule.recordChunk(seconds: chunk, rms: $0) }
    }

    @Test("a pause before the soft threshold does not commit")
    func pauseBeforeTheSoftThresholdDoesNotCommit() {
        var schedule = Self.schedule(speakingFor: ElevenLabsLivePreview.softCommitSeconds - 2)
        let commits = Self.feed(&schedule, [Self.floor, Self.floor])

        #expect(commits == [false, false])
    }

    @Test("past the soft threshold a sustained pause commits")
    func sustainedPauseCommits() {
        var schedule = Self.schedule(speakingFor: ElevenLabsLivePreview.softCommitSeconds)
        let commits = Self.feed(&schedule, [Self.floor, Self.floor])

        #expect(commits == [false, true])
        #expect(schedule.uncommittedSeconds == 0)
    }

    @Test("one quiet chunk between words is not a pause")
    func singleQuietChunkIsNotAPause() {
        var schedule = Self.schedule(speakingFor: ElevenLabsLivePreview.softCommitSeconds)
        let commits = Self.feed(&schedule, [Self.floor, Self.speech, Self.floor])

        #expect(commits == [false, false, false])
    }

    @Test("speech that sits well above the floor is never taken for a pause")
    func quietSpeechIsNotAPause() {
        var schedule = Self.schedule(speakingFor: ElevenLabsLivePreview.softCommitSeconds)
        let quietSpeech: Float = Self.floor * ElevenLabsLivePreview.pauseFloorRatio * 2
        let commits = Self.feed(&schedule, [quietSpeech, quietSpeech])

        #expect(commits == [false, false])
    }

    @Test("at the hard threshold the segment is committed mid-speech")
    func hardThresholdCommitsRegardless() {
        var schedule = Self.schedule(speakingFor: ElevenLabsLivePreview.hardCommitSeconds)
        let commits = Self.feed(&schedule, [Self.speech])

        #expect(commits == [true])
    }

    @Test("digital zeros from a Bluetooth link opening do not become the noise floor")
    func digitalSilenceDoesNotSetTheFloor() {
        var schedule = Schedule()
        _ = Self.feed(&schedule, [0, Self.floor])

        #expect(schedule.noiseFloorRMS == Self.floor)
    }

    @Test("an all-silent session still commits at the hard threshold")
    func silentSessionCommitsAtTheHardThreshold() {
        var schedule = Schedule()
        let chunks = Int((ElevenLabsLivePreview.hardCommitSeconds / Self.chunk).rounded(.up))
        let commits = Self.feed(&schedule, [Float](repeating: 0, count: chunks))

        #expect(commits.contains(true))
    }

    @Test("once closed by the final commit, nothing more is committed")
    func closedScheduleNeverCommits() {
        var schedule = Self.schedule(speakingFor: ElevenLabsLivePreview.hardCommitSeconds)
        schedule.close()
        let commits = Self.feed(&schedule, [Self.speech])

        #expect(commits == [false])
    }

    @Test("the hard threshold stays clear of the server's own commit at about 36 s")
    func hardThresholdIsBelowTheServerCommit() {
        #expect(ElevenLabsLivePreview.hardCommitSeconds <= 30)
        #expect(ElevenLabsLivePreview.softCommitSeconds < ElevenLabsLivePreview.hardCommitSeconds)
    }

    @Test("a chunk's RMS is the root mean square of its samples")
    func rmsOfAChunk() {
        #expect(ElevenLabsLivePreview.rms(of: [0.5, -0.5, 0.5, -0.5]) == 0.5)
        #expect(ElevenLabsLivePreview.rms(of: []) == 0)
    }
}
