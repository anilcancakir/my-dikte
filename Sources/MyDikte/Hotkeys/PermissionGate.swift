import ApplicationServices
import Carbon.HIToolbox
import Foundation
import Speech
import os

/// Reports whether the keyboard surface can actually work, and why not when it cannot.
///
/// Two separate facts, and they fail differently. Accessibility is a grant: without it
/// `CGEvent.tapCreate` returns nil and the push-to-talk chord never exists. Secure event input is a
/// transient session state: while it holds, a tap stops seeing KeyDown and KeyUp (FlagsChanged keeps
/// flowing, which is why the chord is modifier-only), so a keyed shortcut can look broken when it is
/// merely blocked. The menu bar reads both from here rather than guessing.
///
/// Speech Recognition sits here too rather than next to the recogniser, because it is a TCC grant
/// like the other two and this is the one place that asks macOS for one. It gates the live preview
/// only; refusing it costs a preview, never a dictation.
///
/// `@MainActor` because this is the type the UI reads, and because the Accessibility prompt puts a
/// window on screen.
@MainActor
final class PermissionGate {
    enum AccessibilityState: Sendable, Equatable {
        case granted
        case notGranted
    }

    /// How often the grant is polled. macOS sends no notification when Accessibility is granted, and
    /// the grant routinely arrives minutes after launch while the user is in System Settings.
    static let pollInterval: TimeInterval = 1.0

    /// Spelled out rather than read from `kAXTrustedCheckOptionPrompt`: the SDK imports that constant
    /// as a mutable global, which Swift 6 language mode refuses to touch from any context. The value
    /// is this exact string, printed from the constant on this machine.
    private static let trustedCheckOptionPromptKey: String = "AXTrustedCheckOptionPrompt"

    private let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "Permissions")
    private var pollTimer: Timer?
    private var onChange: (@MainActor (AccessibilityState) -> Void)?
    private var hasPromptedThisLaunch = false

    private(set) var accessibilityState: AccessibilityState

    init() {
        accessibilityState = AXIsProcessTrusted() ? .granted : .notGranted
    }

    // Isolated so the timer, which is not `Sendable`, is torn down on the actor that scheduled it.
    isolated deinit {
        pollTimer?.invalidate()
    }

    /// Whether some process in this login session has secure event input on. A password field focused
    /// anywhere counts, foreground or background (Apple TN2150).
    var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }

    /// Re-reads the real state and reports it.
    @discardableResult
    func refresh() -> AccessibilityState {
        let state: AccessibilityState = AXIsProcessTrusted() ? .granted : .notGranted
        guard state != accessibilityState else {
            return state
        }

        accessibilityState = state
        logger.notice("accessibility state changed to \(String(describing: state), privacy: .public)")
        onChange?(state)
        return state
    }

    /// Asks macOS for the Accessibility grant, showing the system prompt.
    ///
    /// The prompt is shown at most once per launch, because `AXIsProcessTrustedWithOptions` will put
    /// the same dialog up on every call and a menu-bar app can be asked for its state repeatedly.
    @discardableResult
    func requestAccessibility() -> AccessibilityState {
        guard accessibilityState == .notGranted else {
            return accessibilityState
        }

        let shouldPrompt: Bool = !hasPromptedThisLaunch
        hasPromptedThisLaunch = true

        let options = [Self.trustedCheckOptionPromptKey: shouldPrompt] as CFDictionary
        let trusted: Bool = AXIsProcessTrustedWithOptions(options)
        accessibilityState = trusted ? .granted : .notGranted
        return accessibilityState
    }

    // MARK: - Speech recognition, for the live preview only

    /// What macOS currently says about Speech Recognition for this app. The framework's own enum
    /// rather than a second one: it already distinguishes denied from restricted from unresolved,
    /// and `LivePreview.readiness` reads exactly these values.
    var speechRecognitionStatus: SFSpeechRecognizerAuthorizationStatus {
        SFSpeechRecognizer.authorizationStatus()
    }

    /// Asks macOS for the Speech Recognition grant, showing the system prompt when the status is
    /// still unresolved, and reports what came back.
    ///
    /// Requested at launch rather than at the first dictation on purpose: the prompt is a window, and
    /// a window appearing while a push-to-talk chord is held would take the focus the dictation is
    /// about to be pasted into.
    ///
    /// Three things about the platform are load-bearing here, and the second one killed this process
    /// once before the annotation went on.
    ///
    /// `requestAuthorization` **crashes** when `NSSpeechRecognitionUsageDescription` is missing from
    /// `Info.plist`, so it is only called when the status is genuinely unresolved and the key is
    /// verified in the signed bundle.
    ///
    /// Its handler is an imported Objective-C block, which is **not** `Sendable`, so a closure written
    /// inside this `@MainActor` type inherits main-actor isolation and Swift 6 inserts a runtime
    /// executor check at its entry. TCC replies on `com.apple.root.default-qos`, that check fails, and
    /// `dispatch_assert_queue_fail` takes the whole app down the moment the user answers the prompt
    /// (measured: `MyDikte-2026-08-18-180545.ips`, SIGTRAP in this closure). `@Sendable` on the
    /// closure is what makes it nonisolated, and the hop back is explicit.
    ///
    /// The hop is `Task { @MainActor in }` rather than `MainActor.assumeIsolated`: this fires once and
    /// needs no ordering, and an assumption about the caller's queue is exactly what just crashed.
    func requestSpeechRecognition(
        completion: @escaping @MainActor @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    ) {
        let status: SFSpeechRecognizerAuthorizationStatus = speechRecognitionStatus
        guard status == .notDetermined else {
            completion(status)
            return
        }

        SFSpeechRecognizer.requestAuthorization { @Sendable granted in
            Task { @MainActor in
                completion(granted)
            }
        }
    }

    /// Starts watching for a grant arriving while the app runs, and calls `onChange` on every
    /// transition. Calling this again replaces the previous observer.
    func startMonitoring(onChange: @escaping @MainActor (AccessibilityState) -> Void) {
        stopMonitoring()
        self.onChange = onChange

        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            // The timer fires on the main run loop, so this is the main actor; the annotation just
            // cannot be expressed on a `Timer` block.
            MainActor.assumeIsolated {
                _ = self?.refresh()
            }
        }
        // Common modes, or the poll stalls for as long as a menu is open, which is exactly when the
        // user is looking at the state it reports.
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stopMonitoring() {
        pollTimer?.invalidate()
        pollTimer = nil
        onChange = nil
    }
}
