import Foundation
import Testing

@testable import MyDikteKit

/// The wire protocol between the work Mac and this one: one compact JSON object per line. The exact
/// shapes are what a second implementation (the work Mac app) has to agree on, so they are asserted
/// as literal text rather than as a round trip of whatever the encoder happens to produce.
@Suite("RemoteMessage")
struct RemoteMessageTests {
    struct Example: Sendable {
        let line: String
        let message: RemoteMessage
    }

    static let examples: [Example] = [
        Example(
            line: #"{"type":"trigger","action":"toggle","mode":"dictate"}"#,
            message: .trigger(.toggle(.dictate))
        ),
        Example(
            line: #"{"type":"trigger","action":"toggle","mode":"prompt"}"#,
            message: .trigger(.toggle(.prompt))
        ),
        Example(
            line: #"{"type":"trigger","action":"cancel"}"#,
            message: .trigger(.cancel)
        ),
        Example(
            line: #"""
            {"type":"hello","toggle":{"keyCode":17,"modifiers":2560},\#
            "promptToggle":{"keyCode":16,"modifiers":2560},"cancel":{"keyCode":8,"modifiers":6400}}
            """#.replacingOccurrences(of: "\n", with: ""),
            message: .hello(RemoteShortcuts.default)
        ),
        Example(
            line: #"{"type":"stage","stage":"recording"}"#,
            message: .stage(.recording)
        ),
        Example(
            line: #"{"type":"stage","stage":"processing"}"#,
            message: .stage(.processing)
        ),
        Example(
            line: #"{"type":"stage","stage":"idle"}"#,
            message: .stage(.idle)
        ),
        Example(
            line: #"{"type":"result","text":"hello"}"#,
            message: .result(text: "hello")
        ),
        Example(
            line: #"{"type":"failure","message":"no microphone"}"#,
            message: .failure(message: "no microphone")
        ),
    ]

    private static func jsonObject(_ data: Data) throws -> NSDictionary {
        try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
    }

    // MARK: - Shapes

    @Test("a line decodes to its case", arguments: examples)
    func lineDecodesToItsCase(example: Example) throws {
        let decoded: RemoteMessage = try JSONDecoder().decode(RemoteMessage.self, from: Data(example.line.utf8))

        #expect(decoded == example.message)
    }

    @Test("a case re-encodes to the same JSON, key order aside", arguments: examples)
    func caseReEncodesToTheSameJSON(example: Example) throws {
        let framed: Data = try example.message.framed()

        #expect(try Self.jsonObject(framed) == Self.jsonObject(Data(example.line.utf8)))
    }

    @Test("a framed message is one line ending in a single newline")
    func framedMessageIsOneLine() throws {
        let framed: Data = try RemoteMessage.result(text: "a\nb").framed()

        #expect(framed.last == 0x0A)
        #expect(framed.filter { $0 == 0x0A }.count == 1)
    }

    @Test("the defaults produce the key codes and modifier masks on the wire")
    func defaultsProduceTheWireNumbers() {
        #expect(RemoteShortcuts.default.toggle == CarbonHotkey.Binding(keyCode: 17, modifiers: 2560))
        #expect(RemoteShortcuts.default.promptToggle == CarbonHotkey.Binding(keyCode: 16, modifiers: 2560))
        #expect(RemoteShortcuts.default.cancel == CarbonHotkey.Binding(keyCode: 8, modifiers: 6400))
    }

    // MARK: - Framing

    @Test("a text with a newline, a quote and Turkish letters survives the wire")
    func awkwardTextSurvives() throws {
        let text = "Merhaba\n\"dünya\" ığüşöç İĞÜŞÖÇ"
        var decoder = RemoteFrameDecoder()

        let messages: [RemoteMessage] = try decoder.append(try RemoteMessage.result(text: text).framed())

        #expect(messages == [.result(text: text)])
    }

    @Test("two messages in one append come out in order")
    func twoMessagesInOneAppend() throws {
        var decoder = RemoteFrameDecoder()
        var data: Data = try RemoteMessage.stage(.recording).framed()
        data.append(try RemoteMessage.result(text: "done").framed())

        let messages: [RemoteMessage] = try decoder.append(data)

        #expect(messages == [.stage(.recording), .result(text: "done")])
    }

    @Test("one message split across three appends arrives on the last")
    func oneMessageAcrossThreeAppends() throws {
        var decoder = RemoteFrameDecoder()
        let framed: Data = try RemoteMessage.failure(message: "no microphone").framed()
        let firstCut: Int = framed.count / 3
        let secondCut: Int = framed.count * 2 / 3

        let first: [RemoteMessage] = try decoder.append(framed.prefix(firstCut))
        let second: [RemoteMessage] = try decoder.append(framed[firstCut..<secondCut])
        let third: [RemoteMessage] = try decoder.append(framed.suffix(from: secondCut))

        #expect(first.isEmpty)
        #expect(second.isEmpty)
        #expect(third == [.failure(message: "no microphone")])
    }

    @Test("a line over 64 KiB throws")
    func overlongLineThrows() throws {
        var decoder = RemoteFrameDecoder()
        let framed: Data = try RemoteMessage.result(text: String(repeating: "a", count: 64 * 1024)).framed()

        #expect(throws: RemoteFrameDecoder.Failure.lineTooLong) {
            try decoder.append(framed)
        }
    }

    @Test("a peer that never sends a newline is cut off at 64 KiB")
    func unterminatedLineThrows() {
        var decoder = RemoteFrameDecoder()

        #expect(throws: RemoteFrameDecoder.Failure.lineTooLong) {
            try decoder.append(Data(repeating: 0x61, count: 64 * 1024 + 1))
        }
    }

    @Test("malformed JSON throws")
    func malformedJSONThrows() {
        var decoder = RemoteFrameDecoder()

        #expect(throws: RemoteFrameDecoder.Failure.self) {
            try decoder.append(Data("{not json}\n".utf8))
        }
    }

    @Test("a well-formed object of an unknown type throws")
    func unknownTypeThrows() {
        var decoder = RemoteFrameDecoder()

        #expect(throws: RemoteFrameDecoder.Failure.self) {
            try decoder.append(Data(#"{"type":"preview","text":"x"}"#.utf8 + [0x0A]))
        }
    }
}
