import Foundation
import Network

/// The `--relay` mode: copies stdin to the app's socket and the socket to stdout, so that an `ssh`
/// session from the other Mac becomes the transport without any listening TCP port.
///
/// Exit 0 when either side closes, 1 when the socket cannot be reached, which tells the other Mac
/// to try again later. Foundation and Network only: this runs under sshd with no GUI session.
enum RelayBridge {
    private static let chunkBytes: Int = 64 * 1024

    static func run(socketPath: String) -> Never {
        // Without this a closed stdout kills the process by signal instead of failing the write.
        signal(SIGPIPE, SIG_IGN)

        let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                pumpSocketToStandardOutput(connection)
                pumpStandardInputToSocket(connection)
            case let .waiting(error), let .failed(error):
                // A missing socket file parks the connection in `waiting` forever rather than failing.
                report("MyDikteRemote relay: cannot reach \(socketPath): \(error)\n")
                exit(1)
            case .cancelled:
                exit(0)
            default:
                break
            }
        }
        connection.start(queue: .global())
        dispatchMain()
    }

    private static func pumpSocketToStandardOutput(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: chunkBytes) { data, _, isComplete, error in
            if let data, !data.isEmpty, !writeToStandardOutput(data) {
                exit(0)
            }
            if isComplete || error != nil {
                exit(0)
            }
            pumpSocketToStandardOutput(connection)
        }
    }

    private static func pumpStandardInputToSocket(_ connection: NWConnection) {
        // A blocking `read` on its own thread: stdin has no readiness callback that works for a pipe
        // and a terminal alike, and the main thread has to stay parked in `dispatchMain`.
        Thread.detachNewThread {
            var buffer: [UInt8] = [UInt8](repeating: 0, count: chunkBytes)

            while true {
                let count: Int = read(STDIN_FILENO, &buffer, buffer.count)
                if count < 0 && errno == EINTR {
                    continue
                }
                guard count > 0 else {
                    break
                }

                connection.send(content: Data(buffer[0..<count]), completion: .contentProcessed { error in
                    if error != nil {
                        exit(0)
                    }
                })
            }

            // The final message queues behind the data above, so exiting from its completion cannot
            // drop the last lines of a short-lived stdin.
            connection.send(
                content: nil,
                contentContext: .finalMessage,
                isComplete: true,
                completion: .contentProcessed { _ in
                    exit(0)
                }
            )
        }
    }

    private static func writeToStandardOutput(_ data: Data) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            guard let base = bytes.baseAddress else {
                return true
            }

            var offset: Int = 0
            while offset < bytes.count {
                let written: Int = write(STDOUT_FILENO, base + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR {
                        continue
                    }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    private static func report(_ line: String) {
        FileHandle.standardError.write(Data(line.utf8))
    }
}
