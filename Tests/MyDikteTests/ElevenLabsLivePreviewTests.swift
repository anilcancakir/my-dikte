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
