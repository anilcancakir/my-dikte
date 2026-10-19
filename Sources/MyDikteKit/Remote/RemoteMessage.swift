import Foundation

/// One message of the remote protocol, a compact JSON object on its own line.
///
/// The cases are hand-coded rather than synthesized because the wire shape is the contract with the
/// work Mac app and is flat: `trigger` carries its action and mode beside `type`, and `hello` carries
/// the three shortcuts beside it, so a synthesized enum's nested payload objects would not match.
package enum RemoteMessage: Codable, Equatable, Sendable {
    /// Work Mac to this Mac.
    case trigger(Trigger)
    /// This Mac to the work Mac, first on every connection.
    case hello(RemoteShortcuts)
    /// This Mac to the work Mac, whenever the pipeline changes stage.
    case stage(Stage)
    /// This Mac to the work Mac: the finished text, to paste at the captured target.
    case result(text: String)
    /// This Mac to the work Mac: the run ended without text, `message` is for the user.
    case failure(message: String)

    package enum Mode: String, Codable, Sendable {
        case dictate
        case prompt
    }

    package enum Trigger: Equatable, Sendable {
        case toggle(Mode)
        case cancel
    }

    package enum Stage: String, Codable, Sendable {
        case recording
        case processing
        case idle
    }

    private enum Kind: String, Codable {
        case trigger
        case hello
        case stage
        case result
        case failure
    }

    private enum Action: String, Codable {
        case toggle
        case cancel
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case action
        case mode
        case stage
        case text
        case message
    }

    package init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)

        switch try container.decode(Kind.self, forKey: .type) {
        case .trigger:
            switch try container.decode(Action.self, forKey: .action) {
            case .toggle:
                self = .trigger(.toggle(try container.decode(Mode.self, forKey: .mode)))
            case .cancel:
                self = .trigger(.cancel)
            }
        case .hello:
            self = .hello(try RemoteShortcuts(from: decoder))
        case .stage:
            self = .stage(try container.decode(Stage.self, forKey: .stage))
        case .result:
            self = .result(text: try container.decode(String.self, forKey: .text))
        case .failure:
            self = .failure(message: try container.decode(String.self, forKey: .message))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .trigger(trigger):
            try container.encode(Kind.trigger, forKey: .type)
            switch trigger {
            case let .toggle(mode):
                try container.encode(Action.toggle, forKey: .action)
                try container.encode(mode, forKey: .mode)
            case .cancel:
                try container.encode(Action.cancel, forKey: .action)
            }
        case let .hello(shortcuts):
            try container.encode(Kind.hello, forKey: .type)
            try shortcuts.encode(to: encoder)
        case let .stage(stage):
            try container.encode(Kind.stage, forKey: .type)
            try container.encode(stage, forKey: .stage)
        case let .result(text):
            try container.encode(Kind.result, forKey: .type)
            try container.encode(text, forKey: .text)
        case let .failure(message):
            try container.encode(Kind.failure, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }

    /// The bytes to put on the wire. `JSONEncoder` escapes a newline inside a string, so the single
    /// trailing newline is the only one on the line and `RemoteFrameDecoder` can split on it.
    package func framed() throws -> Data {
        var data: Data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }
}
