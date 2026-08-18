import Foundation
import Testing

@testable import MyDikte

/// The pure half of the cleanup connection pre-warm: which host gets warmed, and what the request
/// that warms it may contain.
///
/// The handshake itself is verified by measurement inside the signed bundle (the pre-warm logs the
/// host and the milliseconds it took, and `cleanupMs` in `log.jsonl` is the number it exists to
/// move), because a mocked `URLSession` would prove the code ran and nothing about a connection
/// being open.
@Suite("Chat connection pre-warm")
struct ChatClientPrewarmTests {
    private static let openRouter = "https://openrouter.ai/api/v1/chat/completions"
    private static let groq = "https://api.groq.com/openai/v1/chat/completions"

    @Test("the host is read from the endpoint, so the log names what was actually warmed")
    func hostComesFromTheEndpoint() {
        #expect(ChatClient.host(forEndpoint: Self.openRouter) == "openrouter.ai")
        #expect(ChatClient.host(forEndpoint: Self.groq) == "api.groq.com")
    }

    @Test("an endpoint that names no host is skipped rather than warmed")
    func endpointWithoutAHostIsSkipped() {
        #expect(ChatClient.host(forEndpoint: "") == nil)
        #expect(ChatClient.host(forEndpoint: "not a url at all") == nil)
        // No scheme, so this parses as a path and there is no host to open a connection to.
        #expect(ChatClient.host(forEndpoint: "openrouter.ai/api/v1/chat/completions") == nil)
        #expect(ChatClient.prewarmRequest(forEndpoint: "not a url at all") == nil)
    }

    /// The connection pool is keyed by scheme, host and port, so the pre-warm goes to the exact URL
    /// the real POST will use. Anything else risks warming a connection the request cannot reuse.
    @Test("the pre-warm goes to the same URL the real request will")
    func prewarmTargetsTheSameOrigin() throws {
        let request = try #require(ChatClient.prewarmRequest(forEndpoint: Self.openRouter))

        #expect(request.url?.absoluteString == Self.openRouter)
        #expect(request.url?.host == "openrouter.ai")
        #expect(request.url?.scheme == "https")
    }

    /// A handshake is the point. A completion would cost tokens against a rate limit the user is
    /// already close to and would put a reply nowhere useful, and a key is not needed to open a
    /// connection, so the request carries neither.
    @Test("the pre-warm carries no API key, no body and no method that could produce a completion")
    func prewarmRequestIsAHeadWithNoCredential() throws {
        let request = try #require(ChatClient.prewarmRequest(forEndpoint: Self.groq))

        #expect(request.httpMethod == "HEAD")
        #expect(request.httpBody == nil)
        #expect(request.httpBodyStream == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(request.allHTTPHeaderFields?.isEmpty != false)
    }

    /// Without this the URL cache could answer the pre-warm from disk and no connection would be
    /// opened at all, which is a pre-warm that measures fast and warms nothing.
    @Test("the pre-warm never comes from the cache, or it would open no connection")
    func prewarmIgnoresTheCache() throws {
        let request = try #require(ChatClient.prewarmRequest(forEndpoint: Self.groq))

        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        // Bounded, because a hanging warm-up must not outlive the dictation it was opened for.
        #expect(request.timeoutInterval == ChatClient.prewarmTimeoutSeconds)
    }
}
