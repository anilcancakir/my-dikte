import Foundation
import ServiceManagement

/// Registers or unregisters MyDikte as a login item through `SMAppService.mainApp`, called
/// directly rather than through a protocol seam: this has exactly one implementation and exactly
/// one caller (`StatusItemController`'s launch-at-login menu action), and this project's
/// convention is that an abstraction earns its keep only at a third concrete caller.
/// `references/pindrop/Pindrop/Services/LaunchAtLoginManager.swift:18-30` is the two calls this
/// takes, without the protocol wrapper around them.
enum LaunchAtLogin {
    /// Failures registering or unregistering with `SMAppService`. The underlying error is
    /// surfaced verbatim rather than guessed at: registration failures are opaque in the wild
    /// (forum reports of "Status Error 78" and exit code 19968 when the app bundle's location is
    /// inconsistent), and a friendly message here would hide the detail a user or a future reader
    /// actually needs to diagnose one. The app must be at a stable path for registration to work
    /// reliably, which is why `dev-run.sh` always installs to `~/Applications/MyDikte.app`.
    enum LaunchAtLoginError: Error, LocalizedError {
        case registrationFailed(underlying: Error)
        case unregistrationFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .registrationFailed(let underlying):
                return "Failed to enable launch at login: \(underlying.localizedDescription)"
            case .unregistrationFailed(let underlying):
                return "Failed to disable launch at login: \(underlying.localizedDescription)"
            }
        }
    }

    /// The current registration state, read fresh from `SMAppService` each time rather than
    /// cached, since the user can flip this from System Settings without going through this app.
    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    /// Registers the app as a login item.
    static func register() throws {
        do {
            try SMAppService.mainApp.register()
        } catch {
            throw LaunchAtLoginError.registrationFailed(underlying: error)
        }
    }

    /// Unregisters the app as a login item.
    static func unregister() throws {
        do {
            try SMAppService.mainApp.unregister()
        } catch {
            throw LaunchAtLoginError.unregistrationFailed(underlying: error)
        }
    }
}
