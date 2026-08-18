import AppKit

/// The application a dictation is aimed at, captured when recording starts rather than when the
/// text is ready.
///
/// The gap between those two moments is a full transcription round trip, and the user routinely
/// glances at another window inside it. Pasting into whatever happens to be frontmost when the text
/// arrives is how a dictation lands in the wrong app, so the caller captures the target up front and
/// carries it through the pipeline.
///
/// Holds the process identifier rather than the `NSRunningApplication` itself. That keeps the value
/// `Sendable` for the crossing from the capture site to the insertion site, and it turns an
/// application that quit in the meantime into an explicit failure instead of a stale reference.
struct FocusTarget: Sendable, Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?

    /// The frontmost application right now. Call this when recording starts.
    ///
    /// - Returns: `nil` when the window server reports no frontmost application, which happens
    ///   while the login window or a screen saver owns the display.
    @MainActor
    static func current() -> FocusTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        return FocusTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier,
            localizedName: application.localizedName
        )
    }

    /// What to call this application in a message the user reads.
    var displayName: String {
        localizedName ?? bundleIdentifier ?? "process \(processIdentifier)"
    }

    /// Whether this application currently owns keyboard focus, which is the condition a posted
    /// keystroke is actually delivered under.
    @MainActor
    var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier
    }

    /// Asks the system to bring this application forward.
    ///
    /// - Returns: `false` when the application has quit or is of a type that cannot be activated.
    ///   A `true` result only means the request was accepted; activation is asynchronous, so the
    ///   caller still has to wait for `isFrontmost`.
    @MainActor
    func activate() -> Bool {
        guard let application = NSRunningApplication(processIdentifier: processIdentifier) else {
            return false
        }

        // No `.activateIgnoringOtherApps`: it is deprecated since macOS 14 and documented to have
        // no effect, so passing it would buy a build warning and nothing else. Plain activation is
        // the whole remaining API.
        return application.activate(options: [])
    }
}
