import Foundation

/// Splits a byte stream into newline-delimited messages.
///
/// A TCP-style read returns whatever has arrived, which is rarely one whole line, so the partial tail
/// is kept between calls. The line limit exists because the peer is another process on the network:
/// without it, a stream that never sends a newline grows this buffer until the app is killed.
package struct RemoteFrameDecoder: Sendable {
    package static let maximumLineBytes: Int = 64 * 1024

    package enum Failure: Error, LocalizedError, Equatable {
        case lineTooLong
        case malformedMessage(String)

        package var errorDescription: String? {
            switch self {
            case .lineTooLong:
                return "A remote message exceeded \(RemoteFrameDecoder.maximumLineBytes) bytes without a newline."
            case let .malformedMessage(reason):
                return "A remote message could not be decoded: \(reason)"
            }
        }
    }

    private var buffer = Data()

    package init() {}

    /// Appends `data` and returns every message that is now complete, in order.
    ///
    /// After a throw the connection is not trustworthy, so the buffer is dropped and the caller is
    /// expected to close it rather than keep feeding this decoder.
    package mutating func append(_ data: Data) throws -> [RemoteMessage] {
        buffer.append(data)

        var messages: [RemoteMessage] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[buffer.startIndex..<newline])
            buffer.removeSubrange(buffer.startIndex...newline)

            guard line.count <= Self.maximumLineBytes else {
                buffer.removeAll()
                throw Failure.lineTooLong
            }
            guard !line.isEmpty else {
                continue
            }

            do {
                messages.append(try JSONDecoder().decode(RemoteMessage.self, from: line))
            } catch {
                buffer.removeAll()
                throw Failure.malformedMessage(String(describing: error))
            }
        }

        guard buffer.count <= Self.maximumLineBytes else {
            buffer.removeAll()
            throw Failure.lineTooLong
        }
        return messages
    }
}
