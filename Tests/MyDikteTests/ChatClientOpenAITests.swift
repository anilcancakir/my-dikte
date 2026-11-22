import Foundation
import Testing

@testable import MyDikte

/// What the cleanup client accepts as a reply from an OpenAI-compatible endpoint, and from
/// Anthropic when the reply is blank. Anything that would paste nothing or half an answer must
/// throw, so the pipeline inserts the raw transcript instead.
@Suite("Chat client, reply validation")
struct ChatClientOpenAITests {
    private static func openAIReply(content: String, finishReason: String) -> Data {
        Data(
            #"{"choices":[{"message":{"content":"\#(content)"},"finish_reason":"\#(finishReason)"}]}"#.utf8
        )
    }

    @Test("a normal reply returns its text")
    func normalReplyReturnsText() throws {
        let reply = Self.openAIReply(content: "Temiz metin.", finishReason: "stop")

        #expect(try ChatClient.openAIReplyText(from: reply) == "Temiz metin.")
    }

    @Test("a whitespace-only OpenAI reply is an empty response, not text to paste")
    func blankOpenAIReplyThrowsEmptyResponse() {
        let reply = Self.openAIReply(content: " \\n\\t ", finishReason: "stop")

        #expect {
            try ChatClient.openAIReplyText(from: reply)
        } throws: { error in
            guard case ChatClient.ChatClientError.emptyResponse = error else { return false }
            return true
        }
    }

    @Test("a whitespace-only Anthropic reply is an empty response, not text to paste")
    func blankAnthropicReplyThrowsEmptyResponse() {
        let reply = Data(#"{"content":[{"type":"text","text":" \n "}],"stop_reason":"end_turn"}"#.utf8)

        #expect {
            try ChatClient.anthropicReplyText(from: reply)
        } throws: { error in
            guard case ChatClient.ChatClientError.emptyResponse = error else { return false }
            return true
        }
    }

    @Test("one cleanup attempt is bounded to 15 seconds")
    func requestTimeoutIsFifteenSeconds() {
        #expect(ChatClient.requestTimeoutSeconds == 15)
    }

    /// A provider that took the whole 15 s is a poor bet to answer inside the next 15 s, and the raw
    /// transcript is the better outcome than a 48 s wait for it.
    @Test("a timed-out attempt is not retried, but a dropped connection is")
    func timeoutIsNotRetried() {
        #expect(!ChatClient.isRetryable(.networkError(underlying: URLError(.timedOut))))
        #expect(!ChatClient.isRetryable(.networkError(underlying: URLError(.cancelled))))
        #expect(ChatClient.isRetryable(.networkError(underlying: URLError(.networkConnectionLost))))
        #expect(ChatClient.isRetryable(.serverError(statusCode: 429, body: "")))
        #expect(ChatClient.isRetryable(.serverError(statusCode: 503, body: "")))
        #expect(!ChatClient.isRetryable(.serverError(statusCode: 401, body: "")))
    }

    @Test("a reply cut off or filtered is incomplete, whatever text it carries", arguments: [
        "length",
        "content_filter",
    ])
    func incompleteOpenAIReplyThrows(finishReason: String) {
        let reply = Self.openAIReply(content: "Yarım kalmış bir", finishReason: finishReason)

        #expect {
            try ChatClient.openAIReplyText(from: reply)
        } throws: { error in
            guard case ChatClient.ChatClientError.incompleteReply(let stopReason) = error else { return false }
            return stopReason == finishReason
        }
    }
}
