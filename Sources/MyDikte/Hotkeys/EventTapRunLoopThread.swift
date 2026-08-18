import Foundation

/// A dedicated thread owning its own `CFRunLoop`, which is where the event tap's run-loop source is
/// installed.
///
/// The tap deliberately does not use the main run loop: the window server kills a tap whose callback
/// does not return quickly enough, and this app's main thread also draws menus, panels and settings.
/// A main thread busy for a moment would therefore disable the shortcut that starts a dictation.
/// Ported from `references/pindrop/Pindrop/AppCoordinator.swift:16-130`.
final class EventTapRunLoopThread: Thread {
    private let readiness = DispatchSemaphore(value: 0)
    private let stateLock = NSLock()
    private let exitGroup = DispatchGroup()
    /// A run loop with no input sources returns from `run` immediately instead of blocking, so it
    /// needs one port that never fires just to stay alive between events.
    private let keepAlivePort = Port()
    private var runLoop: CFRunLoop?
    private var hasStarted = false
    private var hasExited = false
    private var stopRequested = false

    init(name: String) {
        super.init()
        self.name = name
        // Key handling is latency-visible: the chord's first modifier starts the audio warm-up.
        qualityOfService = .userInteractive
        exitGroup.enter()
    }

    override func main() {
        let currentRunLoop: CFRunLoop = CFRunLoopGetCurrent()

        stateLock.lock()
        runLoop = currentRunLoop
        stateLock.unlock()

        RunLoop.current.add(keepAlivePort, forMode: .default)
        readiness.signal()

        while !isCancelled {
            autoreleasepool {
                _ = RunLoop.current.run(mode: .default, before: .distantFuture)
            }
        }

        stateLock.lock()
        runLoop = nil
        hasExited = true
        stateLock.unlock()
        exitGroup.leave()
    }

    /// Runs `block` on this thread and waits for it to finish, so a caller installing or tearing
    /// down the tap knows the answer before it returns.
    ///
    /// The caller must not hold a lock that the tap callback also takes: this call blocks until the
    /// tap thread reaches the block, and the tap thread cannot get there while it waits for that
    /// same lock. Every call site in `EventTapListener` copies the state it needs out from under its
    /// lock first, for exactly this reason.
    func performAndWait(_ block: @escaping () -> Void) {
        startIfNeeded()

        guard let runLoop = currentRunLoop, let defaultMode = CFRunLoopMode.defaultMode else {
            return
        }

        let completion = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, defaultMode.rawValue as CFTypeRef) {
            block()
            completion.signal()
        }
        CFRunLoopWakeUp(runLoop)
        completion.wait()
    }

    /// Stops the run loop and waits for the thread to exit. Safe to call more than once, and safe to
    /// call before the thread ever started.
    func stopIfNeeded() {
        var completeWithoutStarting = false

        stateLock.lock()
        if !stopRequested {
            stopRequested = true
            cancel()
        }
        let runLoop: CFRunLoop? = self.runLoop
        if !hasStarted, !hasExited {
            hasExited = true
            completeWithoutStarting = true
        }
        stateLock.unlock()

        if completeWithoutStarting {
            exitGroup.leave()
            return
        }

        if let runLoop {
            // Cancellation is published under the same lock as the run loop, so a starting thread
            // either sees the cancel before its first iteration or publishes a loop this stops.
            // The queued block covers the narrow window where the loop has already been entered.
            if let defaultMode = CFRunLoopMode.defaultMode {
                CFRunLoopPerformBlock(runLoop, defaultMode.rawValue as CFTypeRef) {
                    CFRunLoopStop(CFRunLoopGetCurrent())
                }
            }
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
        }

        guard Thread.current !== self else {
            return
        }
        exitGroup.wait()
    }

    private func startIfNeeded() {
        stateLock.lock()
        guard !stopRequested, !hasStarted else {
            stateLock.unlock()
            return
        }
        hasStarted = true
        stateLock.unlock()

        start()
        readiness.wait()
    }

    private var currentRunLoop: CFRunLoop? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runLoop
    }
}
