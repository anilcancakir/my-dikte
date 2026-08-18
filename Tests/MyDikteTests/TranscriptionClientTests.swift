import Foundation
import Testing

@testable import MyDikte

/// Pure-logic coverage for Step 12, per the plan's TDD scope: request-parameter construction,
/// error-body parsing, and the quality gate given an already-decoded response. The live call
/// (real key, real clip, connection reuse) is verified by hand per the step's QA field, not here.
@Suite("TranscriptionClient")
struct TranscriptionClientTests {
    // MARK: Provider request-parameter shape

    @Test("Groq appends singular language, temperature, verbose_json and an untruncated prompt")
    func groqAppendsExpectedParameters() {
        var body = MultipartBody(boundary: "B")
        let provider = GroqTranscriptionProvider(modelId: "whisper-large-v3")

        let wasTruncated = provider.appendParameters(
            to: &body,
            glossaryTerms: [
                "Kubernetes",
                "Redis",
            ],
            language: "tr"
        )

        let rendered = String(decoding: body.finalize().body, as: UTF8.self)
        #expect(wasTruncated == false)
        #expect(rendered.contains("name=\"language\"\r\n\r\ntr"))
        #expect(rendered.contains("name=\"temperature\"\r\n\r\n0"))
        #expect(rendered.contains("name=\"response_format\"\r\n\r\nverbose_json"))
        #expect(rendered.contains("name=\"prompt\"\r\n\r\nKubernetes, Redis"))
    }

    @Test("Groq truncates a glossary over the 224-token prompt cap and reports the truncation")
    func groqTruncatesOverCapGlossary() {
        var body = MultipartBody(boundary: "B")
        let provider = GroqTranscriptionProvider(modelId: "whisper-large-v3")
        let hugeGlossary = (0..<300).map { "term\($0)" }

        let wasTruncated = provider.appendParameters(to: &body, glossaryTerms: hugeGlossary, language: "tr")

        #expect(wasTruncated == true)
        let rendered = String(decoding: body.finalize().body, as: UTF8.self)
        #expect(rendered.contains("term299") == false)
    }

    @Test("OpenAI appends languages[] and keywords[] rather than a singular language and prompt")
    func openAIAppendsStructuredParameters() {
        var body = MultipartBody(boundary: "B")
        let provider = OpenAITranscriptionProvider(modelId: "gpt-4o-transcribe")

        let wasTruncated = provider.appendParameters(
            to: &body,
            glossaryTerms: [
                "Kubernetes",
                "Redis",
            ],
            language: "tr"
        )

        let rendered = String(decoding: body.finalize().body, as: UTF8.self)
        #expect(wasTruncated == false)
        #expect(rendered.contains("name=\"languages[]\"\r\n\r\ntr"))
        #expect(rendered.contains("name=\"keywords[]\"\r\n\r\nKubernetes"))
        #expect(rendered.contains("name=\"keywords[]\"\r\n\r\nRedis"))
        #expect(rendered.contains("name=\"prompt\"") == false)
        #expect(rendered.contains("name=\"language\"\r\n") == false)
    }

    @Test("OpenRouter falls back to the OpenAI-compatible singular language plus prompt shape")
    func openRouterAppendsCompatibleParameters() {
        var body = MultipartBody(boundary: "B")
        let provider = OpenRouterTranscriptionProvider(modelId: "openai/whisper-large-v3")

        _ = provider.appendParameters(to: &body, glossaryTerms: ["Kubernetes"], language: "tr")

        let rendered = String(decoding: body.finalize().body, as: UTF8.self)
        #expect(rendered.contains("name=\"language\"\r\n\r\ntr"))
        #expect(rendered.contains("name=\"prompt\"\r\n\r\nKubernetes"))
        #expect(provider.offersQualityFields == false)
    }

    // MARK: Error-body parsing

    @Test("parses the provider's own message out of a JSON error envelope")
    func parsesProviderErrorEnvelope() {
        let body = Data("""
            { "error": { "message": "Invalid API Key" } }
            """.utf8)

        let error = TranscriptionClient.parseError(status: 401, body: body)

        #expect(error == .requestFailed(status: 401, message: "Invalid API Key"))
    }

    @Test("falls back to the localised status string for a body with no JSON envelope")
    func fallsBackToLocalisedStatusForEmptyBody() {
        let error = TranscriptionClient.parseError(status: 403, body: Data())

        guard case .requestFailed(let status, let message) = error else {
            Issue.record("expected .requestFailed")
            return
        }
        #expect(status == 403)
        #expect(message == HTTPURLResponse.localizedString(forStatusCode: 403))
    }

    // MARK: Quality gate

    @Test("accepts a response with no segments, since the gate has nothing to aggregate")
    func acceptsResponseWithoutSegments() {
        let response = TranscriptionResponse(text: "merhaba", segments: nil)
        #expect(TranscriptionQualityGate.evaluate(response) == true)
    }

    @Test("accepts a response whose segments carry good quality signals")
    func acceptsGoodSegments() {
        let response = TranscriptionResponse(
            text: "merhaba dunya",
            segments: [
                TranscriptionResponse.Segment(noSpeechProb: 0.02, avgLogprob: -0.2, compressionRatio: 1.1),
                TranscriptionResponse.Segment(noSpeechProb: 0.03, avgLogprob: -0.3, compressionRatio: 1.2),
            ]
        )
        #expect(TranscriptionQualityGate.evaluate(response) == true)
    }

    @Test("rejects a response whose segments average a high no_speech_prob")
    func rejectsHighAggregateNoSpeechProb() {
        let response = TranscriptionResponse(
            text: "...",
            segments: [
                TranscriptionResponse.Segment(noSpeechProb: 0.95, avgLogprob: -0.1, compressionRatio: 1.0),
                TranscriptionResponse.Segment(noSpeechProb: 0.9, avgLogprob: -0.1, compressionRatio: 1.0),
            ]
        )
        #expect(TranscriptionQualityGate.evaluate(response) == false)
    }

    @Test("rejects a response whose segments average a sharply negative avg_logprob")
    func rejectsSharplyNegativeAggregateLogprob() {
        let response = TranscriptionResponse(
            text: "...",
            segments: [
                TranscriptionResponse.Segment(noSpeechProb: 0.05, avgLogprob: -1.8, compressionRatio: 1.0),
                TranscriptionResponse.Segment(noSpeechProb: 0.05, avgLogprob: -1.6, compressionRatio: 1.0),
            ]
        )
        #expect(TranscriptionQualityGate.evaluate(response) == false)
    }

    /// A rejection that only says "a threshold was crossed" cannot be acted on or tuned: which of
    /// the two fired, and how far past it was, is the whole content of the finding. A real rejection
    /// on this machine reached the user as a bare sentence with no numbers, and the dictation behind
    /// it was never logged, so there was nothing left to check the threshold against.
    @Test("a rejection names the field that fired and the value it measured")
    func rejectionNamesTheFieldAndTheValue() {
        let response = TranscriptionResponse(
            text: "...",
            segments: [
                TranscriptionResponse.Segment(noSpeechProb: 0.95, avgLogprob: -0.1, compressionRatio: 1.0),
                TranscriptionResponse.Segment(noSpeechProb: 0.9, avgLogprob: -0.1, compressionRatio: 1.0),
            ]
        )

        let rejection = TranscriptionQualityGate.rejection(for: response)
        #expect(rejection != nil)
        #expect(rejection?.reason.contains("no_speech_prob") == true)
        #expect(rejection?.reason.contains("0.93") == true)
        #expect(rejection?.reason.contains("0.6") == true)
    }

    @Test("the logprob rejection reports its own average and its own threshold")
    func logprobRejectionReportsItsValue() {
        let response = TranscriptionResponse(
            text: "...",
            segments: [
                TranscriptionResponse.Segment(noSpeechProb: 0.05, avgLogprob: -1.8, compressionRatio: 1.0),
                TranscriptionResponse.Segment(noSpeechProb: 0.05, avgLogprob: -1.6, compressionRatio: 1.0),
            ]
        )

        let rejection = TranscriptionQualityGate.rejection(for: response)
        #expect(rejection?.reason.contains("avg_logprob") == true)
        #expect(rejection?.reason.contains("-1.70") == true)
    }

    @Test("a response that passes has no rejection")
    func passingResponseHasNoRejection() {
        let response = TranscriptionResponse(
            text: "merhaba dunya",
            segments: [
                TranscriptionResponse.Segment(noSpeechProb: 0.02, avgLogprob: -0.2, compressionRatio: 1.1)
            ]
        )
        #expect(TranscriptionQualityGate.rejection(for: response) == nil)
    }

    // MARK: Missing key error

    @Test("a missing key produces a typed error naming which account and where to enter it")
    func missingKeyErrorNamesAccountAndSettings() {
        let error = ProviderError.missingAPIKey(account: "transcription-groq")
        #expect(error.errorDescription?.contains("transcription-groq") == true)
        #expect(error.errorDescription?.localizedCaseInsensitiveContains("settings") == true)
    }
}

// QA HARNESS. Real calls against Groq for Step 12's QA scenario; gated behind an env var so
// `swift test` never hits the network by default. Mirrors the pattern in
// `ReasoningSuppressionTests.swift`'s `ChatClientQATests`, which stays in the tree for the same
// reason: a repeatable way to re-run the live scenario without a throwaway script.
@Suite("TranscriptionClient QA", .enabled(if: ProcessInfo.processInfo.environment["MYDIKTE_QA_REAL"] == "1"))
struct TranscriptionClientQATests {
    @Test("three consecutive real transcriptions, the second and third reusing the connection")
    func threeConsecutiveRealTranscriptions() async throws {
        let client = TranscriptionClient(provider: GroqTranscriptionProvider(modelId: "whisper-large-v3"))
        let clipPaths = [
            "/tmp/tr_3s.wav",
            "/tmp/tr_test.wav",
            "/tmp/tr_25s.wav",
        ]

        for (index, path) in clipPaths.enumerated() {
            let audioData = try Data(contentsOf: URL(fileURLWithPath: path))
            let start = Date()
            let result = try await client.transcribe(
                audioData: audioData,
                filename: "audio.wav",
                glossaryTerms: [
                    "Kubernetes",
                    "Grafana",
                    "PyQt",
                ],
                language: "tr"
            )
            let elapsed = Date().timeIntervalSince(start)
            print("QA run \(index + 1) (\(elapsed)s, reused=\(String(describing: result.isReusedConnection))): \(result.text)")
            #expect(!result.text.isEmpty)
            if index > 0 {
                #expect(result.isReusedConnection == true)
            }
        }
    }

    @Test("a bogus key surfaces the provider's own message, not a crash")
    func bogusKeySurfacesProviderMessage() async throws {
        let client = TranscriptionClient(
            provider: GroqTranscriptionProvider(modelId: "whisper-large-v3"),
            readKey: { _ in .found("bogus-key-value") }
        )
        let audioData = try Data(contentsOf: URL(fileURLWithPath: "/tmp/tr_3s.wav"))

        do {
            _ = try await client.transcribe(audioData: audioData, filename: "audio.wav", glossaryTerms: [])
            Issue.record("expected a ProviderError for a bogus key")
        } catch let error as ProviderError {
            print("QA bogus key error: \(error.errorDescription ?? "nil")")
            guard case .requestFailed(let status, let message) = error else {
                Issue.record("expected .requestFailed, got \(error)")
                return
            }
            #expect(status == 401)
            #expect(!message.isEmpty)
        }
    }

    @Test("cancelling mid-request throws CancellationError and leaves the session usable")
    func cancellationWorks() async throws {
        let client = TranscriptionClient(provider: GroqTranscriptionProvider(modelId: "whisper-large-v3"))
        let audioData = try Data(contentsOf: URL(fileURLWithPath: "/tmp/tr_25s.wav"))

        let task = Task {
            try await client.transcribe(audioData: audioData, filename: "audio.wav", glossaryTerms: [])
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation to throw")
        } catch is CancellationError {
            print("QA cancellation: threw CancellationError as expected")
        }

        // The session must still be usable after a cancelled request.
        let audioData2 = try Data(contentsOf: URL(fileURLWithPath: "/tmp/tr_3s.wav"))
        let result = try await client.transcribe(audioData: audioData2, filename: "audio.wav", glossaryTerms: [])
        print("QA post-cancellation request still works: \(result.text)")
        #expect(!result.text.isEmpty)
    }
}
