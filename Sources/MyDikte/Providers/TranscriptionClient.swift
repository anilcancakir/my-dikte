import Foundation
import os

/// One provider's transcription request shape.
///
/// **AMENDED, multiple providers selectable.** Groq, OpenAI and OpenRouter each take genuinely
/// incompatible parameters: Groq wants singular `language` plus a 224-token `prompt`, OpenAI's
/// `gpt-4o-transcribe` wants `languages[]` plus structured `keywords[]`, and OpenRouter's model
/// list is not public. So parameters stay per conformance rather than in one shared struct;
/// only multipart assembly, auth, decoding, retry and cancellation are shared, in
/// `TranscriptionClient` below. Three conformances live in this file, alongside the client and
/// its error-parsing and quality-gate helpers, because Step 12's `Files` list is exactly two
/// paths: `TranscriptionClient.swift` and `ProviderError.swift`.
protocol TranscriptionProvider: Sendable {
    /// The provider's transcription endpoint.
    var baseURL: URL { get }

    /// The model id sent in the request's `model` field.
    var modelId: String { get }

    /// The `KeychainStore` account holding this provider's API key.
    var keychainAccount: String { get }

    /// Whether this provider's `verbose_json`-equivalent response carries the per-segment
    /// quality fields the gate reads. `gpt-4o-transcribe` returns plain `json` with no segments,
    /// so a provider that does not offer them answers false and the gate never runs against it.
    var offersQualityFields: Bool { get }

    /// Appends this provider's own request-parameter shape to `body`. Returns whether the
    /// glossary was truncated to fit a provider-documented cap, so the caller can log it without
    /// every conformance owning its own logger.
    func appendParameters(to body: inout MultipartBody, glossaryTerms: [String], language: String) -> Bool
}

/// Groq: `language` singular, `temperature=0`, `response_format=verbose_json`, and the glossary
/// joined into the `prompt` field, truncated to the documented 224-token cap.
struct GroqTranscriptionProvider: TranscriptionProvider {
    let modelId: String

    var baseURL: URL {
        URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
    }

    var keychainAccount: String {
        Settings.TranscriptionProvider.groq.keychainAccount
    }

    var offersQualityFields: Bool { true }

    func appendParameters(to body: inout MultipartBody, glossaryTerms: [String], language: String) -> Bool {
        body.appendField(name: "language", value: language)
        body.appendField(name: "temperature", value: "0")
        body.appendField(name: "response_format", value: "verbose_json")

        let (prompt, wasTruncated) = GlossaryPromptBuilder.truncatedPrompt(fromGlossary: glossaryTerms)
        if !prompt.isEmpty {
            body.appendField(name: "prompt", value: prompt)
        }
        return wasTruncated
    }
}

/// OpenAI's `gpt-4o-transcribe`: `languages[]` rather than singular `language`, and the glossary
/// carried as structured `keywords[]` entries rather than free-text `prompt`. No documented token
/// cap has been measured for this provider, so no truncation is attempted here.
struct OpenAITranscriptionProvider: TranscriptionProvider {
    let modelId: String

    var baseURL: URL {
        URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    }

    var keychainAccount: String {
        Settings.TranscriptionProvider.openAI.keychainAccount
    }

    var offersQualityFields: Bool { false }

    func appendParameters(to body: inout MultipartBody, glossaryTerms: [String], language: String) -> Bool {
        body.appendField(name: "languages[]", value: language)
        body.appendField(name: "response_format", value: "json")
        for term in glossaryTerms where !term.isEmpty {
            body.appendField(name: "keywords[]", value: term)
        }
        return false
    }
}

/// OpenRouter has no published parameter documentation for transcription at plan time ("the
/// model list is not public"), so this conformance falls back to the OpenAI-compatible singular
/// `language` plus free-text `prompt` shape that Groq also uses, on the assumption that an
/// OpenRouter-proxied Whisper endpoint mirrors the upstream API it forwards to. Unverified
/// against a real OpenRouter key; revisit with a failing test the day that key exists.
struct OpenRouterTranscriptionProvider: TranscriptionProvider {
    let modelId: String

    var baseURL: URL {
        URL(string: "https://openrouter.ai/api/v1/audio/transcriptions")!
    }

    var keychainAccount: String {
        Settings.TranscriptionProvider.openRouter.keychainAccount
    }

    var offersQualityFields: Bool { false }

    func appendParameters(to body: inout MultipartBody, glossaryTerms: [String], language: String) -> Bool {
        body.appendField(name: "language", value: language)
        let (prompt, wasTruncated) = GlossaryPromptBuilder.truncatedPrompt(fromGlossary: glossaryTerms)
        if !prompt.isEmpty {
            body.appendField(name: "prompt", value: prompt)
        }
        return wasTruncated
    }
}

/// Builds the transcription `prompt` field from glossary terms, truncated to Groq's documented
/// 224-token cap (`https://console.groq.com/docs/speech-to-text`).
///
/// This project carries zero third-party dependencies, so there is no real BPE tokenizer on
/// hand. Token count is approximated by splitting the joined prompt on whitespace, which
/// over-counts against Whisper's actual tokenizer for any multi-token word and so never risks
/// silently exceeding the real cap; it only ever truncates earlier than strictly necessary.
enum GlossaryPromptBuilder {
    static let tokenCap = 224

    static func truncatedPrompt(fromGlossary terms: [String]) -> (prompt: String, wasTruncated: Bool) {
        let joined = terms.joined(separator: ", ")
        let words = joined.split(separator: " ")
        guard words.count > tokenCap else {
            return (joined, false)
        }
        let truncated = words.prefix(tokenCap).joined(separator: " ")
        return (truncated, true)
    }
}

/// Aggregates Groq's per-segment quality fields into an accept/reject decision.
///
/// Measured fact (`evidence/step-02-groq-seam.txt`, section A2): `verbose_json` carries
/// `no_speech_prob` and `avg_logprob` per segment, not once per response, so there is no single
/// top-level value to threshold against. This averages across every segment that reports each
/// field instead.
enum TranscriptionQualityGate {
    /// Above this aggregate `no_speech_prob`, the model itself is saying the audio was probably
    /// silence or noise.
    static let maxAverageNoSpeechProb = 0.6

    /// Below this aggregate `avg_logprob`, the model was guessing rather than transcribing.
    static let minAverageLogprob = -1.0

    /// Why a response was rejected, carrying the numbers behind the decision.
    ///
    /// The gate used to answer with a bare `Bool` and the caller attached a fixed sentence, so a
    /// real rejection reached the user as "aggregate no_speech_prob or avg_logprob crossed the
    /// reject threshold" with no indication of which one fired, how far past it was, or what the
    /// threshold even is. That is unactionable for the user and untunable for us.
    struct Rejection: Equatable {
        let reason: String
    }

    /// The rejection for `response`, or `nil` when it passes.
    static func rejection(for response: TranscriptionResponse) -> Rejection? {
        guard let segments = response.segments, !segments.isEmpty else {
            // No segments: the provider either does not offer these fields (the client skips
            // the gate entirely in that case) or Groq itself returned none. Either way there is
            // nothing to aggregate, so this passes rather than rejecting on absence.
            return nil
        }

        let noSpeechProbs = segments.compactMap(\.noSpeechProb)
        if !noSpeechProbs.isEmpty {
            let mean = noSpeechProbs.reduce(0, +) / Double(noSpeechProbs.count)
            if mean > maxAverageNoSpeechProb {
                return Rejection(
                    reason: String(
                        format: "mean no_speech_prob %.2f across %d segment(s) is above the %.1f limit",
                        mean,
                        noSpeechProbs.count,
                        maxAverageNoSpeechProb
                    )
                )
            }
        }

        let avgLogprobs = segments.compactMap(\.avgLogprob)
        if !avgLogprobs.isEmpty {
            let mean = avgLogprobs.reduce(0, +) / Double(avgLogprobs.count)
            if mean < minAverageLogprob {
                return Rejection(
                    reason: String(
                        format: "mean avg_logprob %.2f across %d segment(s) is below the %.1f limit",
                        mean,
                        avgLogprobs.count,
                        minAverageLogprob
                    )
                )
            }
        }

        return nil
    }

    /// Kept because the existing tests read the gate as a yes or no, which is still the question the
    /// client asks; the reason is what the user and the log need.
    static func evaluate(_ response: TranscriptionResponse) -> Bool {
        rejection(for: response) == nil
    }
}

/// The provider's own error envelope, when it sends one. Not every failure arrives this way: a
/// bad `User-Agent` got an HTTP 403 from Groq's edge with no body at all
/// (`evidence/step-02-groq-seam.txt`, section A4), so `TranscriptionClient.parseError` must
/// survive a body this fails to decode.
private struct ProviderErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}

/// Collects `URLSessionTaskMetrics` for one request so the caller can read whether the
/// connection was reused, without the client itself becoming a session-wide delegate.
///
/// `URLSessionTaskDelegate` inherits `NSObjectProtocol`, hence the `NSObject` base. The
/// delivered-on-a-background-queue callback is guarded with `NSLock` rather than assumed to land
/// on any particular thread, following this codebase's convention for callback-owned state.
private final class TaskMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var reusedConnection: Bool?

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        reusedConnection = metrics.transactionMetrics.last?.isReusedConnection
        lock.unlock()
    }

    var isReusedConnection: Bool? {
        lock.lock()
        defer { lock.unlock() }
        return reusedConnection
    }
}

/// Transcribes audio through one `TranscriptionProvider`, sharing one long-lived `URLSession` so
/// a second dictation reuses the connection: measured at about 200 ms against 238 ms fresh, a
/// roughly 37 ms saving (`evidence/step-02-groq-seam.txt`, section D).
///
/// The API key is resolved through `readKey`, called once per request rather than captured at
/// init: a key entered in Settings takes effect on the very next dictation with no restart, and
/// the secret is never held in memory longer than one request needs it.
final class TranscriptionClient: @unchecked Sendable {
    /// Three attempts total, delay doubling from `initialBackoffSeconds`, per this codebase's
    /// reuse of `references/VoiceInk/.../AIEnhancementService.swift:403-476`'s retry shape.
    private static let maxAttempts = 3
    private static let initialBackoffSeconds: TimeInterval = 0.5
    private static let requestTimeoutSeconds: TimeInterval = 30

    private let provider: TranscriptionProvider
    private let session: URLSession
    private let readKey: @Sendable (String) -> KeychainStore.ReadResult
    private let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "Transcription")

    /// A successful transcription, with the metrics needed to confirm connection reuse.
    struct Result: Equatable {
        let text: String
        let isReusedConnection: Bool?
    }

    /// - Parameters:
    ///   - provider: which backend and parameter shape to use.
    ///   - readKey: resolves the Keychain value for an account, defaulting to the real store.
    ///     Overridable so a test can inject a fixed key without touching the real Keychain.
    ///   - session: overridable for tests; production always gets one non-ephemeral session held
    ///     for this client's lifetime, never `.ephemeral`, so connection reuse is possible at all.
    init(
        provider: TranscriptionProvider,
        readKey: @escaping @Sendable (String) -> KeychainStore.ReadResult = KeychainStore.read,
        session: URLSession? = nil
    ) {
        self.provider = provider
        self.readKey = readKey
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = Self.requestTimeoutSeconds
            self.session = URLSession(configuration: configuration)
        }
    }

    /// Transcribes `audioData` (an m4a container, from `AudioEncoder` through `MultipartBody`).
    func transcribe(
        audioData: Data,
        filename: String = "audio.m4a",
        glossaryTerms: [String],
        language: String = "tr"
    ) async throws -> Result {
        try Task.checkCancellation()

        // 1. Resolve the key fresh, per request; see the type's own doc comment for why.
        let apiKey = try resolvedAPIKey()

        // 2. Build the request once; every retry attempt reuses the same body.
        var body = MultipartBody()
        body.appendField(name: "model", value: provider.modelId)
        let wasTruncated = provider.appendParameters(to: &body, glossaryTerms: glossaryTerms, language: language)
        if wasTruncated {
            logger.notice("glossary truncated to fit the provider's prompt token cap")
        }
        body.appendFile(name: "file", filename: filename, contentType: "audio/mp4", data: audioData)
        let sealed = body.finalize()

        var request = URLRequest(url: provider.baseURL, timeoutInterval: Self.requestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(sealed.contentTypeHeaderValue, forHTTPHeaderField: "Content-Type")
        request.httpBody = sealed.body

        // 3. Retry transport errors, 5xx and 429 with doubling backoff; never a 4xx other than 429.
        return try await performWithRetry(request)
    }

    private func resolvedAPIKey() throws -> String {
        switch readKey(provider.keychainAccount) {
        case .found(let value):
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ProviderError.missingAPIKey(account: provider.keychainAccount)
            }
            return trimmed
        case .missing, .unavailable:
            throw ProviderError.missingAPIKey(account: provider.keychainAccount)
        }
    }

    private func performWithRetry(_ request: URLRequest) async throws -> Result {
        var attempt = 0
        var delaySeconds = Self.initialBackoffSeconds

        while true {
            attempt += 1
            try Task.checkCancellation()

            do {
                let (data, httpResponse, isReusedConnection) = try await performRequest(request)

                guard (200..<300).contains(httpResponse.statusCode) else {
                    let error = Self.parseError(status: httpResponse.statusCode, body: data)
                    let retryable = httpResponse.statusCode == 429 || httpResponse.statusCode >= 500
                    guard retryable, attempt < Self.maxAttempts else {
                        throw error
                    }
                    logger.warning(
                        "retrying after HTTP \(httpResponse.statusCode, privacy: .public), attempt \(attempt, privacy: .public)"
                    )
                    try await sleepBeforeRetry(&delaySeconds)
                    continue
                }

                guard let decoded = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
                    throw ProviderError.invalidResponse
                }
                if provider.offersQualityFields,
                    let rejection = TranscriptionQualityGate.rejection(for: decoded)
                {
                    throw ProviderError.lowQualityTranscript(
                        reason: rejection.reason,
                        transcript: decoded.text
                    )
                }
                return Result(text: decoded.text, isReusedConnection: isReusedConnection)
            } catch let error as ProviderError {
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                guard attempt < Self.maxAttempts else {
                    throw error
                }
                logger.warning(
                    "retrying after transport error, attempt \(attempt, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                try await sleepBeforeRetry(&delaySeconds)
            }
        }
    }

    private func sleepBeforeRetry(_ delaySeconds: inout TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        delaySeconds *= 2
    }

    private func performRequest(_ request: URLRequest) async throws -> (Data, HTTPURLResponse, Bool?) {
        let collector = TaskMetricsCollector()
        let (data, response) = try await session.data(for: request, delegate: collector)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ProviderError.invalidResponse
        }
        return (data, httpResponse, collector.isReusedConnection)
    }

    /// Parses a non-2xx body into `.requestFailed`, extracting the provider's own message when
    /// the body decodes as `{"error": {"message": ...}}`, falling back to the localised status
    /// string otherwise (including for the no-body-at-all case Groq's edge can return).
    static func parseError(status: Int, body: Data) -> ProviderError {
        let message = (try? JSONDecoder().decode(ProviderErrorEnvelope.self, from: body))?.error.message
            ?? HTTPURLResponse.localizedString(forStatusCode: status)
        return .requestFailed(status: status, message: message)
    }
}
