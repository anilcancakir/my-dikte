/// The shortcuts the work Mac app registers, as the session sees them.
package enum RemoteHotkey: Sendable, Equatable {
    case toggle
    case promptToggle
    case cancel
    /// Space or Return, which the app registers only while a recording runs.
    case stop
}
