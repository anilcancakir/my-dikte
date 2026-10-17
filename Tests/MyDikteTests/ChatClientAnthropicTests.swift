import Foundation
import Testing

@testable import MyDikte

/// The native Anthropic Messages request and reply, which the cleanup client speaks when the
/// endpoint is `api.anthropic.com`.
///
/// Anthropic's OpenAI-compatible endpoint is documented as a testing aid, ignores
/// `reasoning_effort` and offers no prompt caching, and Haiku 5.5 thinks by default: the three
/// things a sub-second cleanup call depends on. So these pin the native shape instead.
@Suite("Chat client, Anthropic Messages")
struct ChatClientAnthropicTests {
    private static let messages = PromptAssembly.Messages(system: "Temizle.", user: "<transcript>ham</transcript>")

    private static func body() throws -> [String: Any] {
        let data = try ChatClient.anthropicRequestBody(
            modelId: "claude-haiku-5-5",
            messages: messages,
            maxTokens: 1536
        )
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("only the Anthropic host takes the native path")
    func endpointDetection() {
        #expect(ChatClient.isAnthropicEndpoint("https://api.anthropic.com/v1/messages"))
        #expect(!ChatClient.isAnthropicEndpoint("https://openrouter.ai/api/v1/chat/completions"))
        #expect(!ChatClient.isAnthropicEndpoint("https://api.groq.com/openai/v1/chat/completions"))
    }

    @Test("the system prompt is top-level and cached, the transcript is the one user turn")
    func systemIsCachedAndTopLevel() throws {
        let body = try Self.body()
        let system = try #require(body["system"] as? [[String: Any]])
        let messages = try #require(body["messages"] as? [[String: Any]])

        #expect(system.count == 1)
        #expect(system[0]["text"] as? String == "Temizle.")
        #expect((system[0]["cache_control"] as? [String: String])?["type"] == "ephemeral")
        #expect(messages.count == 1)
        #expect(messages[0]["role"] as? String == "user")
        #expect(messages[0]["content"] as? String == "<transcript>ham</transcript>")
    }

    @Test("thinking is off and effort is low, because a cleanup is a rewrite and not a problem to solve")
    func thinkingIsDisabled() throws {
        let body = try Self.body()

        #expect((body["thinking"] as? [String: String])?["type"] == "disabled")
        #expect((body["output_config"] as? [String: String])?["effort"] == "low")
        #expect(body["max_tokens"] as? Int == 1536)
        #expect(body["model"] as? String == "claude-haiku-5-5")
    }

    @Test("no sampling parameter is sent, which Haiku 5.5 rejects at anything but its default")
    func noTemperature() throws {
        let body = try Self.body()

        #expect(body["temperature"] == nil)
        #expect(body["top_p"] == nil)
    }

    @Test("the reply is the first text block, whatever precedes it")
    func replyIsTheTextBlock() throws {
        let reply = Data(
            """
            {"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Temiz metin."}],
             "stop_reason":"end_turn"}
            """.utf8
        )

        #expect(try ChatClient.anthropicReplyText(from: reply) == "Temiz metin.")
    }

    @Test("a reply with no text block is an empty response, not an empty string")
    func noTextBlockIsEmpty() {
        let reply = Data(#"{"content":[],"stop_reason":"refusal"}"#.utf8)

        #expect(throws: ChatClient.ChatClientError.self) {
            try ChatClient.anthropicReplyText(from: reply)
        }
    }
}

/// A reply that stopped for any reason but finishing is not a cleanup to paste.
@Suite("Chat client, Anthropic stop reasons")
struct ChatClientAnthropicStopReasonTests {
    @Test("a reply cut off at max_tokens is an error, so the raw transcript goes in instead", arguments: [
        "max_tokens",
        "refusal",
    ])
    func incompleteReplyThrows(stopReason: String) {
        let reply = Data(
            #"{"content":[{"type":"text","text":"Yarım kalmış bir"}],"stop_reason":"\#(stopReason)"}"#.utf8
        )

        #expect(throws: ChatClient.ChatClientError.self) {
            try ChatClient.anthropicReplyText(from: reply)
        }
    }

    @Test("only the Messages URL takes the native path; the compatible one keeps the OpenAI body")
    func compatibleURLKeepsTheOpenAIShape() {
        #expect(!ChatClient.isAnthropicEndpoint("https://api.anthropic.com/v1/chat/completions"))
    }
}
