import ApplicationServices
import CoreGraphics
import Foundation
import os

/// Owns the `CGEventTap` that carries the push-to-talk chord, including the three ways it dies.
///
/// Not `@MainActor`: the tap callback arrives on this listener's own run-loop thread, and the state
/// it reads there has to be reachable from that thread. State is guarded with `NSLock` instead, per
/// this project's concurrency convention for callback-owning types.
final class EventTapListener: @unchecked Sendable {
    /// What the tap saw. Deliberately a plain value: the callback identifies the event and hands
    /// this on, and does no work of its own, because slow callbacks are what get a tap killed.
    struct KeyEvent: Sendable, Equatable {
        enum Kind: Sendable {
            case keyDown
            case keyUp
            case flagsChanged
        }

        let kind: Kind
        let keyCode: Int64
        let flags: CGEventFlags
    }

    /// Whether the event reaches the focused app. Only an active (`.defaultTap`) tap may delete an
    /// event, which is one of the two reasons this tap is not `.listenOnly`.
    enum Disposition: Sendable {
        case pass
        case swallow
    }

    enum Failure: Error, LocalizedError, Equatable {
        case accessibilityNotGranted
        case tapCreationFailed
        case runLoopSourceUnavailable

        var errorDescription: String? {
            switch self {
            case .accessibilityNotGranted:
                return "MyDikte needs Accessibility access to see the push-to-talk chord."
            case .tapCreationFailed:
                return "macOS refused to create the keyboard event tap."
            case .runLoopSourceUnavailable:
                return "The keyboard event tap could not be attached to its run loop."
            }
        }
    }

    /// How often `tapIsEnabled()` is polled. A non-nil tap is not a healthy tap: after a re-signed
    /// binary is launched through Finder, `tapCreate` can hand back a port that never fires, and this
    /// poll is the only thing that notices. See `research/librarian-apple-apis.md`.
    static let healthCheckInterval: TimeInterval = 2.0

    private static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)

    private let handler: @Sendable (KeyEvent) -> Disposition
    private let onInterruption: @Sendable () -> Void
    private let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "EventTap")
    private let thread = EventTapRunLoopThread(name: "\(BundleInfo.bundleIdentifier).event-tap")
    private let healthQueue = DispatchQueue(label: "\(BundleInfo.bundleIdentifier).event-tap.health")
    private let stateLock = NSLock()
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var healthTimer: DispatchSourceTimer?
    private var isUserDisabled = false
    private var pendingStallSeconds: TimeInterval = 0

    /// - Parameters:
    ///   - handler: called on the tap thread for every keyboard event, and must stay cheap.
    ///   - onInterruption: called when the tap dies, so held shortcuts can be released rather than
    ///     leaving a push-to-talk recording running with no key to end it.
    init(
        handler: @escaping @Sendable (KeyEvent) -> Disposition,
        onInterruption: @escaping @Sendable () -> Void
    ) {
        self.handler = handler
        self.onInterruption = onInterruption
    }

    deinit {
        stop()
    }

    /// True while the tap exists and macOS reports it enabled.
    var isEnabled: Bool {
        stateLock.lock()
        let tap: CFMachPort? = self.tap
        stateLock.unlock()

        guard let tap else {
            return false
        }
        return CGEvent.tapIsEnabled(tap: tap)
    }

    /// True when the user disabled event taps deliberately, which is the one death this listener
    /// does not recover from on its own.
    var wasDisabledByUser: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isUserDisabled
    }

    func start() throws {
        // Without the Accessibility grant `tapCreate` just returns nil, which reads as "macOS
        // refused" rather than "ask the user"; checking first buys the specific message.
        guard AXIsProcessTrusted() else {
            throw Failure.accessibilityNotGranted
        }

        stateLock.lock()
        isUserDisabled = false
        stateLock.unlock()

        try installTap()
        startHealthCheck()
    }

    /// Retires this listener: the run-loop thread does not come back, so listening again needs a
    /// fresh instance. `ShortcutCoordinator` builds one per `start()` for that reason.
    func stop() {
        stopHealthCheck()
        uninstallTap()
        thread.stopIfNeeded()
    }

    /// Makes the next tap callback sleep, which is how the timeout death and its inline recovery are
    /// exercised by hand. Armed only from the debug menu; zero by default.
    func stallNextCallback(by seconds: TimeInterval) {
        stateLock.lock()
        pendingStallSeconds = seconds
        stateLock.unlock()
    }

    // MARK: - Tap lifecycle

    private func installTap() throws {
        // The callback is a C function pointer, so it captures nothing and the listener travels
        // through `userInfo` as an unretained pointer. Verified under Swift 6 language mode in
        // `evidence/step-08-09-17-swift6-probe.txt`.
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let listener = Unmanaged<EventTapListener>.fromOpaque(userInfo).takeUnretainedValue()
            return listener.handle(type: type, event: event)
        }

        var created: CFMachPort?
        var source: CFRunLoopSource?

        // Installed from the tap's own thread so the run-loop source belongs to that loop.
        thread.performAndWait { [self] in
            guard
                let tap = CGEvent.tapCreate(
                    tap: .cgSessionEventTap,
                    place: .headInsertEventTap,
                    // `.defaultTap` twice over: only an active tap can swallow the chord, and it is
                    // what makes Accessibility the grant we need instead of Input Monitoring, so the
                    // user visits one System Settings pane rather than two.
                    options: .defaultTap,
                    eventsOfInterest: Self.eventMask,
                    callback: callback,
                    userInfo: Unmanaged.passUnretained(self).toOpaque()
                )
            else {
                return
            }

            created = tap

            guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                CFMachPortInvalidate(tap)
                created = nil
                return
            }

            source = runLoopSource
            CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        guard let created else {
            throw Failure.tapCreationFailed
        }
        guard let source else {
            throw Failure.runLoopSourceUnavailable
        }

        stateLock.lock()
        tap = created
        runLoopSource = source
        stateLock.unlock()

        logger.notice("event tap installed")
    }

    private func uninstallTap() {
        stateLock.lock()
        let tap: CFMachPort? = self.tap
        let source: CFRunLoopSource? = runLoopSource
        self.tap = nil
        runLoopSource = nil
        stateLock.unlock()

        guard tap != nil || source != nil else {
            return
        }

        // Torn down on the tap thread, matching where it was installed.
        thread.performAndWait {
            if let source {
                CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
            }
            if let tap {
                CFMachPortInvalidate(tap)
            }
        }
    }

    private func reinstallTap() {
        uninstallTap()

        do {
            try installTap()
        } catch {
            // Logged rather than rethrown: this runs on the health-check timer, which has no caller
            // to hand an error to, and losing the tap silently is the failure this poll exists for.
            logger.error("event tap reinstall failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - The callback

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout:
            // Our callback was too slow. The port is still valid, so re-enabling inline recovers
            // without losing the tap; anything held is released first, because the events that would
            // have ended a recording were missed.
            logger.warning("event tap disabled by timeout; re-enabling inline")
            onInterruption()
            reenableInline()
            return Unmanaged.passUnretained(event)

        case .tapDisabledByUserInput:
            // A deliberate user action. Re-enabling here would fight the user, so this one is only
            // recovered by an explicit restart, and the health check stands down while it holds.
            logger.warning("event tap disabled by user input; not re-enabling")
            stateLock.lock()
            isUserDisabled = true
            stateLock.unlock()
            onInterruption()
            return Unmanaged.passUnretained(event)

        default:
            break
        }

        applyPendingStallIfArmed()

        guard let kind = Self.kind(for: type) else {
            return Unmanaged.passUnretained(event)
        }

        let keyEvent = KeyEvent(
            kind: kind,
            keyCode: event.getIntegerValueField(.keyboardEventKeycode),
            flags: event.flags
        )

        return handler(keyEvent) == .swallow ? nil : Unmanaged.passUnretained(event)
    }

    private func reenableInline() {
        stateLock.lock()
        let tap: CFMachPort? = self.tap
        stateLock.unlock()

        guard let tap else {
            return
        }
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func applyPendingStallIfArmed() {
        stateLock.lock()
        let seconds: TimeInterval = pendingStallSeconds
        pendingStallSeconds = 0
        stateLock.unlock()

        guard seconds > 0 else {
            return
        }

        // Debug affordance only, armed from the debug menu: sleeping here is precisely what the
        // window server punishes with `tapDisabledByTimeout`, which is the recovery path this step
        // has to prove by hand.
        logger.notice("stalling the tap callback for \(seconds, privacy: .public)s on purpose")
        Thread.sleep(forTimeInterval: seconds)
    }

    private static func kind(for type: CGEventType) -> KeyEvent.Kind? {
        switch type {
        case .keyDown:
            return .keyDown
        case .keyUp:
            return .keyUp
        case .flagsChanged:
            return .flagsChanged
        default:
            return nil
        }
    }

    // MARK: - Health check

    private func startHealthCheck() {
        stopHealthCheck()

        let timer = DispatchSource.makeTimerSource(queue: healthQueue)
        timer.schedule(deadline: .now() + Self.healthCheckInterval, repeating: Self.healthCheckInterval)
        timer.setEventHandler { [weak self] in
            self?.checkHealth()
        }

        stateLock.lock()
        healthTimer = timer
        stateLock.unlock()

        timer.resume()
    }

    /// Must not be called from `healthQueue`: it drains that queue, and the two callers (`start` and
    /// `stop`) are both on the caller's thread rather than on it.
    private func stopHealthCheck() {
        stateLock.lock()
        let timer: DispatchSourceTimer? = healthTimer
        healthTimer = nil
        stateLock.unlock()

        timer?.cancel()
        // A check already in flight would otherwise reinstall the tap after teardown, leaving a live
        // tap nobody owns that goes on swallowing the chord's second modifier.
        healthQueue.sync {}
    }

    private func checkHealth() {
        stateLock.lock()
        let tap: CFMachPort? = self.tap
        let userDisabled: Bool = isUserDisabled
        stateLock.unlock()

        guard !userDisabled else {
            return
        }
        if let tap, CGEvent.tapIsEnabled(tap: tap) {
            return
        }

        logger.warning("event tap reported disabled; reinstalling")
        onInterruption()
        reinstallTap()
    }
}
