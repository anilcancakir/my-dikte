/// What the work Mac app does in answer to a press.
package enum RemoteSessionAction: Sendable, Equatable {
    /// Send `message`. `capture` is the target this press fixed for the run, `nil` when the press
    /// started no run or the run already has one.
    case send(RemoteMessage, capture: FocusTarget?)
    /// Nothing to send: there is no connection, so the press is told apart from a working one.
    case beep
    /// Nothing to send and nothing to say: a stop key pressed when no recording runs.
    case ignore
}
