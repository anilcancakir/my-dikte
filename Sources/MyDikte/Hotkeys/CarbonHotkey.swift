import Carbon.HIToolbox
import Foundation
import os

/// Registers keyed global shortcuts through Carbon's `RegisterEventHotKey`.
///
/// Carbon is used for the toggle and cancel shortcuts on purpose: they need key-down only, which is
/// exactly what Carbon delivers, and secure event input does not affect it, while it does stop a
/// `CGEventTap` from seeing KeyDown and KeyUp
/// (`references/Handy/src-tauri/src/secure_input.rs:1-20`). Both symbols resolve from plain Swift
/// with no bridging header, verified in `evidence/step-08-11-api-probe.txt`.
///
/// Not `@MainActor`: the Carbon handler is a C function pointer that carries no actor isolation.
/// State is guarded with `NSLock`, and `register` is expected to be called from the main thread,
/// because `GetApplicationEventTarget()` is the app's own event target and the run loop that dispatches
/// to it is the main one.
final class CarbonHotkey: @unchecked Sendable {
    /// A keyed shortcut: a virtual keycode plus Carbon's modifier mask (`cmdKey`, `optionKey`,
    /// `controlKey`, `shiftKey`), which is not the same bit layout as `CGEventFlags`.
    struct Binding: Sendable, Equatable {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    enum Failure: Error, LocalizedError, Equatable {
        case handlerInstallationFailed(OSStatus)
        case registrationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .handlerInstallationFailed(status):
                return "Could not install the Carbon hot-key handler (OSStatus \(status))."
            case let .registrationFailed(status):
                return "Could not register the shortcut; another app may already own it (OSStatus \(status))."
            }
        }
    }

    /// Four-character signature `MYDK`, which scopes our hot-key ids to this app.
    private static let signature: OSType = 0x4D59_444B

    private let onHotkey: @Sendable (UInt32) -> Void
    private let logger = Logger(subsystem: BundleInfo.bundleIdentifier, category: "CarbonHotkey")
    private let stateLock = NSLock()
    private var handlerRef: EventHandlerRef?
    private var registrations: [UInt32: EventHotKeyRef] = [:]

    init(onHotkey: @escaping @Sendable (UInt32) -> Void) {
        self.onHotkey = onHotkey
    }

    deinit {
        unregisterAll()
    }

    /// Registers `binding` under `id`, replacing any previous registration for that id.
    func register(_ binding: Binding, id: UInt32) throws {
        try installHandlerIfNeeded()
        unregister(id: id)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var reference: EventHotKeyRef?
        let status: OSStatus = RegisterEventHotKey(
            binding.keyCode,
            binding.modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &reference
        )

        guard status == noErr, let reference else {
            throw Failure.registrationFailed(status)
        }

        stateLock.lock()
        registrations[id] = reference
        stateLock.unlock()

        logger.notice("registered Carbon hot key \(id, privacy: .public)")
    }

    func unregister(id: UInt32) {
        stateLock.lock()
        let reference: EventHotKeyRef? = registrations.removeValue(forKey: id)
        stateLock.unlock()

        guard let reference else {
            return
        }

        let status: OSStatus = UnregisterEventHotKey(reference)
        if status != noErr {
            logger.error("unregistering hot key \(id, privacy: .public) failed: \(status, privacy: .public)")
        }
    }

    func unregisterAll() {
        stateLock.lock()
        let references: [UInt32: EventHotKeyRef] = registrations
        registrations = [:]
        let handler: EventHandlerRef? = handlerRef
        handlerRef = nil
        stateLock.unlock()

        for (id, reference) in references {
            let status: OSStatus = UnregisterEventHotKey(reference)
            if status != noErr {
                logger.error("unregistering hot key \(id, privacy: .public) failed: \(status, privacy: .public)")
            }
        }

        if let handler {
            RemoveEventHandler(handler)
        }
    }

    private func installHandlerIfNeeded() throws {
        stateLock.lock()
        let alreadyInstalled: Bool = handlerRef != nil
        stateLock.unlock()

        guard !alreadyInstalled else {
            return
        }

        // A C function pointer, so it captures nothing; the instance travels through `userData` the
        // same way the event tap's does.
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else {
                return OSStatus(eventNotHandledErr)
            }

            var hotKeyID = EventHotKeyID()
            let status: OSStatus = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            guard status == noErr else {
                return status
            }

            let hotkey = Unmanaged<CarbonHotkey>.fromOpaque(userData).takeUnretainedValue()
            hotkey.dispatch(id: hotKeyID.id)
            return noErr
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        var installed: EventHandlerRef?
        let status: OSStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &installed
        )

        guard status == noErr, let installed else {
            throw Failure.handlerInstallationFailed(status)
        }

        stateLock.lock()
        handlerRef = installed
        stateLock.unlock()
    }

    private func dispatch(id: UInt32) {
        stateLock.lock()
        let isKnown: Bool = registrations[id] != nil
        stateLock.unlock()

        guard isKnown else {
            return
        }
        onHotkey(id)
    }
}
