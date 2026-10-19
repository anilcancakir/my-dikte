import Foundation
import MyDikteKit
import os

/// This Mac's side of the link to the work Mac: keeps an `ssh` child running whose far end is the
/// work Mac app's relay, reads its triggers from stdout and writes the run's progress to stdin.
///
/// ssh carries the bytes because it is already authenticated and encrypted between the two Macs, so
/// this app opens no socket and listens on no port. The child is restarted on a back-off for as long
/// as the app runs, since the work Mac sleeps and the network drops and neither is an error.
@MainActor
final class RemoteLink {
    enum State: Equatable {
        case off
        case connected
        case reconnecting
    }

    private struct Child {
        let process: Process
        let stdin: FileHandle
        let stdout: FileHandle
        let stderr: FileHandle
        let launchedAt: ContinuousClock.Instant
    }

    /// Fires on every change, for the status menu.
    var onStateChange: (State) -> Void = { _ in }

    private(set) var state: State = .reconnecting {
        didSet {
            guard state != oldValue else {
                return
            }
            logger.notice("remote link \(String(describing: self.state), privacy: .public)")
            onStateChange(state)
        }
    }

    private let host: String
    private let shortcuts: RemoteShortcuts
    private let pipeline: DictationPipeline
    private let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "RemoteLink")

    private var child: Child?
    private var decoder = RemoteFrameDecoder()
    private var schedule = ReconnectSchedule()
    private var readerTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    /// Bumped on every launch and on `stop()`. The `@Sendable` handlers of a child that has since
    /// been replaced or killed arrive late and compare against it, so they cannot act on its successor.
    private var generation: Int = 0

    init(host: String, shortcuts: RemoteShortcuts, pipeline: DictationPipeline) {
        self.host = host
        self.shortcuts = shortcuts
        self.pipeline = pipeline
    }

    // MARK: - Pure pieces

    /// `--` ends ssh's option parsing, so a host that starts with a dash cannot become an option. The
    /// command is one element and unquoted: ssh joins the words after the host and the remote shell
    /// expands the `~`, so a quote added here would reach the remote shell as part of the path.
    nonisolated static func sshArguments(host: String) -> [String] {
        [
            "-T",
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=5",
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "--",
            host,
            "~/Applications/MyDikteRemote.app/Contents/MacOS/MyDikteRemote --relay",
        ]
    }

    /// The work Mac only distinguishes recording from waiting, so every stage after the microphone,
    /// inserting included, is one `processing`.
    nonisolated static func remoteStage(for stage: PipelineStage) -> RemoteMessage.Stage {
        switch stage {
        case .idle:
            return .idle
        case .recording:
            return .recording
        case .working, .inserting:
            return .processing
        }
    }

    nonisolated static func dictationMode(for mode: RemoteMessage.Mode) -> DictationRecord.Mode {
        switch mode {
        case .dictate:
            return .dictate
        case .prompt:
            return .prompt
        }
    }

    // MARK: - Lifecycle

    func start() {
        // A write to a pipe whose reader died raises SIGPIPE, which kills the app unless it is
        // ignored. With it ignored the write throws instead, and `send` turns that into a reconnect.
        signal(SIGPIPE, SIG_IGN)
        launch()
    }

    /// Kills the child so it does not outlive the app. Its handlers are reset first so that the exit
    /// it causes is not mistaken for a drop and answered with a reconnect.
    func stop() {
        generation += 1
        reconnectTask?.cancel()
        reconnectTask = nil
        readerTask?.cancel()
        readerTask = nil

        guard let child else {
            return
        }
        self.child = nil
        child.stdout.readabilityHandler = nil
        child.stderr.readabilityHandler = nil
        child.process.terminationHandler = nil
        if child.process.isRunning {
            child.process.terminate()
        }
    }

    // MARK: - Pipeline output

    /// Called from the pipeline's `onStageChange`. Only a run this link started is reported: a local
    /// dictation is none of the work Mac's business.
    func pipelineStageChanged(_ stage: PipelineStage) {
        guard pipeline.activeOrigin == .remote else {
            return
        }
        send(.stage(Self.remoteStage(for: stage)))
    }

    func pipelineFailed(message: String) {
        guard pipeline.activeOrigin == .remote else {
            return
        }
        send(.failure(message: message))
    }

    /// Called from the pipeline's `onRemoteResult`, which fires before the stage returns to idle. The
    /// work Mac reads its paste target on this message and drops it on that idle, so the order is the
    /// contract.
    func pipelineProducedResult(_ text: String) {
        send(.result(text: text))
    }

    // MARK: - Child process

    private func launch() {
        generation += 1
        let launchGeneration: Int = generation

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ssh")
        process.arguments = Self.sshArguments(host: host)

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Chunks go through a stream because each handler call is its own `Task` hop otherwise, and
        // two hops are not guaranteed to land in the order the bytes arrived.
        let (chunks, continuation) = AsyncStream<Data>.makeStream()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data: Data = handle.availableData
            guard !data.isEmpty else {
                // End of file. Left in place the handler would fire again in a busy loop.
                handle.readabilityHandler = nil
                continuation.finish()
                return
            }
            continuation.yield(data)
        }
        let diagnostics: Logger = logger
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data: Data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            diagnostics.notice("ssh: \(String(decoding: data, as: UTF8.self), privacy: .public)")
        }
        process.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                self?.processTerminated(generation: launchGeneration)
            }
        }

        do {
            try process.run()
        } catch {
            logger.error("ssh did not launch: \(error.localizedDescription, privacy: .public)")
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            continuation.finish()
            scheduleReconnect(afterSessionLasting: .zero)
            return
        }

        child = Child(
            process: process,
            stdin: stdinPipe.fileHandleForWriting,
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading,
            launchedAt: .now
        )
        decoder = RemoteFrameDecoder()
        readerTask = Task { [weak self] in
            for await data in chunks {
                self?.received(data, generation: launchGeneration)
            }
        }
        state = .connected
        send(.hello(shortcuts))
    }

    private func processTerminated(generation terminatedGeneration: Int) {
        guard terminatedGeneration == generation, let ended = child else {
            return
        }
        child = nil
        readerTask?.cancel()
        readerTask = nil
        ended.stdout.readabilityHandler = nil
        ended.stderr.readabilityHandler = nil

        // A recording is stopped the normal way so its text is not lost; the pipeline reroutes the
        // output, which has nowhere to go while the link is down.
        if pipeline.activeOrigin == .remote {
            pipeline.remotePeerLost()
        }
        scheduleReconnect(afterSessionLasting: ended.launchedAt.duration(to: .now))
    }

    private func scheduleReconnect(afterSessionLasting lifetime: Duration) {
        state = .reconnecting
        let delay: Duration = schedule.nextDelay(afterSessionLasting: lifetime)
        logger.notice("remote link retries in \(delay.components.seconds, privacy: .public) s")

        reconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                // Only `stop()` cancels this, and it means the app is quitting.
                return
            }
            self?.launch()
        }
    }

    private func received(_ data: Data, generation receivedGeneration: Int) {
        guard receivedGeneration == generation else {
            return
        }

        do {
            for message in try decoder.append(data) {
                handle(message)
            }
        } catch {
            // The decoder dropped its buffer and the stream cannot be trusted past this point, so the
            // child is ended and the reconnect path starts a clean one.
            logger.error("remote message rejected: \(error.localizedDescription, privacy: .public)")
            readerTask?.cancel()
            if let process = child?.process, process.isRunning {
                process.terminate()
            }
        }
    }

    private func handle(_ message: RemoteMessage) {
        switch message {
        case let .trigger(.toggle(mode)):
            pipeline.toggleRequested(mode: Self.dictationMode(for: mode), origin: .remote)
        case .trigger(.cancel):
            pipeline.cancelRequested()
        case .hello, .stage, .result, .failure:
            // These travel the other way. A peer sending one is out of step, and there is nothing
            // here that could act on it.
            logger.error("remote peer sent a message that only this Mac sends")
        }
    }

    private func send(_ message: RemoteMessage) {
        guard let child else {
            return
        }

        do {
            try child.stdin.write(contentsOf: try message.framed())
        } catch {
            logger.error("remote write failed: \(error.localizedDescription, privacy: .public)")
            if child.process.isRunning {
                child.process.terminate()
            }
        }
    }
}
