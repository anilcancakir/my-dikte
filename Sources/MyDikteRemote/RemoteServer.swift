import Foundation
import MyDikteKit
import Network
import os

/// The app's end of the relay: a unix socket in a private directory, one connection at a time.
///
/// A unix socket rather than a TCP port because the only peer is the `--relay` process sshd starts on
/// this same Mac, and a file under a 0700 directory needs no authentication of its own.
@MainActor
final class RemoteServer {
    enum Event {
        case message(RemoteMessage)
        /// The current connection ended, was replaced, or failed; the session must treat it as gone.
        case disconnected
        case listenerFailed(String)
    }

    enum Failure: Error, LocalizedError {
        case notConnected
        case directoryUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "There is no relay connection to send on."
            case let .directoryUnavailable(reason):
                return "Could not prepare the MyDikteRemote support directory: \(reason)"
            }
        }
    }

    private struct Peer {
        let id: UInt64
        let connection: NWConnection
        var decoder: RemoteFrameDecoder
    }

    nonisolated static let directoryURL: URL = {
        let base: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("MyDikteRemote", isDirectory: true)
    }()

    nonisolated static let socketURL: URL = directoryURL.appendingPathComponent("remote.sock")

    private static let receiveChunkBytes: Int = 64 * 1024

    private let onEvent: (Event) -> Void
    private let logger = Logger(subsystem: "com.anilcan.mydikte.remote", category: "Remote")
    private var listener: NWListener?
    private var peer: Peer?
    private var lastPeerID: UInt64 = 0

    init(onEvent: @escaping (Event) -> Void) {
        self.onEvent = onEvent
    }

    func start() throws {
        // 1. The directory is the access control: the socket file is created with the umask's
        //    permissions and only becomes 0600 after the listener is up.
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: Self.directoryURL, withIntermediateDirectories: true)
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: Self.directoryURL.path)

            // 2. A socket file left by a killed run makes the bind fail with "address in use".
            if manager.fileExists(atPath: Self.socketURL.path) {
                try manager.removeItem(at: Self.socketURL)
            }
        } catch {
            throw Failure.directoryUnavailable(error.localizedDescription)
        }

        // 3. Listen on the unix endpoint.
        let parameters: NWParameters = .tcp
        parameters.requiredLocalEndpoint = .unix(path: Self.socketURL.path)

        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.listenerStateChanged(state)
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection)
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
        peer?.connection.cancel()
        peer = nil

        do {
            try FileManager.default.removeItem(at: Self.socketURL)
        } catch {
            logger.error("removing the socket failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func send(_ message: RemoteMessage) throws {
        guard let peer else {
            throw Failure.notConnected
        }

        let id: UInt64 = peer.id
        peer.connection.send(content: try message.framed(), completion: .contentProcessed { [weak self] error in
            guard error != nil else {
                return
            }
            Task { @MainActor in
                self?.end(id: id)
            }
        })
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            restrictSocketPermissions()
        case let .failed(error):
            logger.error("listener failed: \(error.localizedDescription, privacy: .public)")
            onEvent(.listenerFailed(error.localizedDescription))
        default:
            break
        }
    }

    private func restrictSocketPermissions() {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.socketURL.path)
        } catch {
            // Fail closed: a socket the owner cannot be sure is private must not keep accepting.
            listener?.cancel()
            logger.error("chmod of the socket failed: \(error.localizedDescription, privacy: .public)")
            onEvent(.listenerFailed("Could not restrict the socket to its owner: \(error.localizedDescription)"))
        }
    }

    private func accept(_ connection: NWConnection) {
        // A newer relay means the other Mac reconnected and the older one is a dead ssh session that
        // has not noticed yet, so it is the one to drop.
        if let previous = peer {
            drop(previous)
        }

        lastPeerID += 1
        let id: UInt64 = lastPeerID
        peer = Peer(id: id, connection: connection, decoder: RemoteFrameDecoder())

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in
                    self?.end(id: id)
                }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receiveNext(on: connection, id: id)
        logger.notice("relay connection \(id, privacy: .public) accepted")
    }

    private func receiveNext(on connection: NWConnection, id: UInt64) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.receiveChunkBytes
        ) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                self?.received(data, isComplete: isComplete, error: error, id: id)
            }
        }
    }

    private func received(_ data: Data?, isComplete: Bool, error: NWError?, id: UInt64) {
        guard var current = peer, current.id == id else {
            return
        }

        if let data, !data.isEmpty {
            let messages: [RemoteMessage]
            do {
                messages = try current.decoder.append(data)
            } catch {
                // The decoder dropped its buffer, so the stream cannot be resynchronised.
                logger.error("closing \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                end(id: id)
                return
            }

            peer = current
            for message in messages {
                onEvent(.message(message))
            }
        }

        guard peer?.id == id else {
            return
        }
        if isComplete || error != nil {
            end(id: id)
            return
        }
        receiveNext(on: current.connection, id: id)
    }

    /// Ends the connection `id` if it is still the current one. Handlers of a replaced connection
    /// arrive late and must not report the newer one as gone.
    private func end(id: UInt64) {
        guard let current = peer, current.id == id else {
            return
        }
        drop(current)
    }

    private func drop(_ dropped: Peer) {
        peer = nil
        dropped.connection.cancel()
        logger.notice("relay connection \(dropped.id, privacy: .public) closed")
        onEvent(.disconnected)
    }
}
