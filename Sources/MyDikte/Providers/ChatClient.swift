import Foundation

/// Posts the cleanup and prompt-rewrite requests Step 5's `PromptAssembly` builds to a
/// chat-completions endpoint, and returns the model's reply text.
///
/// This duplicates the retry, error and cancellation shape of the transcription client
/// (`references/VoiceInk/VoiceInk/Services/AIEnhancement/AIEnhancementService.swift:403-476` for
/// the backoff loop) rather than sharing code with it: two callers is not the three concrete
/// callers this project requires before extracting a shared HTTP layer, so the duplication is
/// deliberate and stays until a third caller exists.
struct ChatClient {
    /// Failures this client can raise. Defined here rather than in `Providers/ProviderError.swift`
    /// because that file belongs to the transcription client landing in this same wave.
    enum ChatClientError: Error, LocalizedError {
        /// No Keychain item exists under the account the configured endpoint expects.
        case missingAPIKey(account: String)
        /// The endpoint URL string in `Settings` did not parse as a URL.
        case invalidEndpoint(String)
        /// The transport itself failed (DNS, TCP, TLS, cancellation surfaced by `URLSession`).
        case networkError(underlying: Error)
        /// The server responded with a non-2xx status. The body is carried as text because, per
        /// the measured evidence, a failure can arrive as a non-JSON body (an edge block on a
        /// suspicious User-Agent returned HTTP 403 with no JSON at all).
        case serverError(statusCode: Int, body: String)
        /// The response body did not decode as the expected chat-completions shape.
        case decodingError(underlying: Error)
        /// The response decoded but carried no message content to return.
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .missingAPIKey(let account):
                return "No API key stored in the Keychain under account \"\(account)\"."
            case .invalidEndpoint(let endpoint):
                return "The cleanup endpoint \"\(endpoint)\" is not a valid URL."
            case .networkError(let underlying):
                return "Network error talking to the cleanup endpoint: \(underlying.localizedDescription)"
            case .serverError(let statusCode, let body):
                return "Cleanup endpoint returned HTTP \(statusCode): \(body)"
            case .decodingError(let underlying):
                return "Could not decode the cleanup endpoint's response: \(underlying.localizedDescription)"
            case .emptyResponse:
                return "The cleanup endpoint returned no message content."
            }
        }
    }

    /// The chat-completions request body. `reasoningEffort` and `extraBodyParameters` carry
    /// whatever `ReasoningSuppression` contributes for the configured model; both are optional
    /// because most models need no suppression at all.
    private struct RequestBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        let model: String
        let messages: [Message]
        let temperature: Double
        let maxTokens: Int
        let reasoningEffort: String?
        let extraBodyParameters: [String: Bool]

        enum CodingKeys: String, CodingKey {
            case model
            case messages
            case temperature
            case maxTokens = "max_tokens"
            case reasoningEffort = "reasoning_effort"
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(model, forKey: .model)
            try container.encode(messages, forKey: .messages)
            try container.encode(temperature, forKey: .temperature)
            try container.encode(maxTokens, forKey: .maxTokens)
            try container.encodeIfPresent(reasoningEffort, forKey: .reasoningEffort)

            var extraContainer = encoder.container(keyedBy: DynamicCodingKey.self)
            for (key, value) in extraBodyParameters {
                try extraContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
            }
        }
    }

    /// A `CodingKey` built from a runtime string, needed to encode `extraBodyParameters`'
    /// arbitrary keys (`reasoning_effort`, `include_reasoning`) alongside the fixed fields above.
    private struct DynamicCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int? = nil

        init(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }
    }

    /// The subset of a chat-completions response this client reads. Unknown fields are ignored
    /// by `Decodable`, following the same permissive-decoding rationale as
    /// `Providers/TranscriptionResponse.swift`: a provider is free to add fields this app does
    /// not use.
    private struct ResponseBody: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }
            let message: Message
        }
        let choices: [Choice]
    }

    private let endpoint: String
    private let apiKeyAccount: String
    private let modelId: String
    private let session: URLSession

    /// - Parameters:
    ///   - endpoint: the configured chat-completions URL, `Settings.cleanupEndpoint` by default.
    ///   - apiKeyAccount: the `KeychainStore` account the configured endpoint's key lives under,
    ///     `cleanup-groq` for Groq or `cleanup-openrouter` for OpenRouter.
    ///   - modelId: the fully namespaced model id to send, and to look up in
    ///     `ReasoningSuppression`.
    ///   - session: injected for testability; defaults to `.shared`.
    init(
        endpoint: String,
        apiKeyAccount: String,
        modelId: String,
        session: URLSession = .shared
    ) {
        self.endpoint = endpoint
        self.apiKeyAccount = apiKeyAccount
        self.modelId = modelId
        self.session = session
    }

    /// Sends `messages` to the configured endpoint and returns the model's reply text.
    ///
    /// `maxTokens` is sized to the input by the caller rather than left open, per the step's
    /// description; this client does not compute it. `temperature` is fixed at 0.3, matching the
    /// measured Groq call in `.ac/plans/my-dikte-swift-macos/evidence/step-02-groq-seam.txt`
    /// section C.
    func complete(messages: PromptAssembly.Messages, maxTokens: Int) async throws -> String {
        try await sendWithRetry(messages: messages, maxTokens: maxTokens)
    }

    /// Same retry shape as the transcription client: up to 3 attempts, exponential backoff
    /// starting at 1 second, retrying only on a network failure or a 5xx / 429 server error.
    private func sendWithRetry(
        messages: PromptAssembly.Messages,
        maxTokens: Int,
        maxRetries: Int = 3,
        initialDelay: TimeInterval = 1.0
    ) async throws -> String {
        var attempt = 0
        var delay = initialDelay

        while true {
            do {
                return try await send(messages: messages, maxTokens: maxTokens)
            } catch let error as ChatClientError {
                attempt += 1
                guard attempt < maxRetries, isRetryable(error) else {
                    throw error
                }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay *= 2
            }
        }
    }

    /// A network failure or a 5xx / 429 response is worth retrying; every other error (a missing
    /// key, a bad endpoint, a 4xx that is not rate-limiting, a decoding failure) will not resolve
    /// itself on a second attempt. A cancelled request is deliberately excluded from
    /// `networkError`'s retry, matching
    /// `references/VoiceInk/.../AIEnhancementService.swift:452-471`, which retries only on
    /// `NSURLErrorNotConnectedToInternet`, `NSURLErrorTimedOut` and
    /// `NSURLErrorNetworkConnectionLost`, never on `NSURLErrorCancelled`; without this exclusion a
    /// caller that cancels the request would see it silently retried instead of stopped.
    private func isRetryable(_ error: ChatClientError) -> Bool {
        switch error {
        case .networkError(let underlying):
            if let urlError = underlying as? URLError, urlError.code == .cancelled {
                return false
            }
            return true
        case .serverError(let statusCode, _):
            return statusCode == 429 || (500...599).contains(statusCode)
        case .missingAPIKey, .invalidEndpoint, .decodingError, .emptyResponse:
            return false
        }
    }

    /// One attempt: builds the request, sends it, and decodes the reply.
    private func send(messages: PromptAssembly.Messages, maxTokens: Int) async throws -> String {
        guard let url = URL(string: endpoint) else {
            throw ChatClientError.invalidEndpoint(endpoint)
        }

        let apiKey = try requireAPIKey()
        let suppression = ReasoningSuppression.parameters(for: modelId)

        let body = RequestBody(
            model: modelId,
            messages: [
                RequestBody.Message(role: "system", content: messages.system),
                RequestBody.Message(role: "user", content: messages.user),
            ],
            temperature: 0.3,
            maxTokens: maxTokens,
            reasoningEffort: suppression?.reasoningEffort,
            extraBodyParameters: suppression?.extraBodyParameters ?? [:]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if isOpenRouterEndpoint {
            // OpenRouter attributes traffic by these headers; Groq does not want them.
            request.setValue("https://github.com/anilcan/my-dikte", forHTTPHeaderField: "HTTP-Referer")
            request.setValue("MyDikte", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONEncoder().encode(body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ChatClientError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatClientError.networkError(underlying: URLError(.badServerResponse))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            // The body may not be JSON at all: an edge block on a suspicious User-Agent measured
            // in Step 2's evidence returned HTTP 403 with no JSON body whatsoever.
            let bodyText = String(data: data, encoding: .utf8) ?? "<non-UTF8 body>"
            throw ChatClientError.serverError(statusCode: httpResponse.statusCode, body: bodyText)
        }

        let decoded: ResponseBody
        do {
            decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        } catch {
            throw ChatClientError.decodingError(underlying: error)
        }

        guard let content = decoded.choices.first?.message.content, !content.isEmpty else {
            throw ChatClientError.emptyResponse
        }
        return content
    }

    private var isOpenRouterEndpoint: Bool {
        endpoint.contains("openrouter.ai")
    }

    /// Reads the API key from the Keychain account this client was configured with, failing with
    /// a typed error naming the account rather than silently falling back to a different one.
    private func requireAPIKey() throws -> String {
        switch KeychainStore.read(forAccount: apiKeyAccount) {
        case .found(let value):
            return value
        case .missing, .unavailable:
            throw ChatClientError.missingAPIKey(account: apiKeyAccount)
        }
    }
}
