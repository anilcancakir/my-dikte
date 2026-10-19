/// The three shortcuts the work Mac app registers, sent in the hello so that a rebinding in
/// `settings.json` on this Mac needs no matching edit on the other one.
package struct RemoteShortcuts: Sendable, Equatable, Codable {
    package let toggle: CarbonHotkey.Binding
    package let promptToggle: CarbonHotkey.Binding
    package let cancel: CarbonHotkey.Binding

    package init(
        toggle: CarbonHotkey.Binding,
        promptToggle: CarbonHotkey.Binding,
        cancel: CarbonHotkey.Binding
    ) {
        self.toggle = toggle
        self.promptToggle = promptToggle
        self.cancel = cancel
    }

    /// The same bindings local dictation defaults to, read from where they are defined so the two
    /// machines cannot drift apart.
    package static let `default` = RemoteShortcuts(
        toggle: .defaultToggle,
        promptToggle: .defaultPromptToggle,
        cancel: .defaultCancel
    )
}
