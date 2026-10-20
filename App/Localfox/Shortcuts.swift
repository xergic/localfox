import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Portfox takes ⌃⌥P, so the two apps never fight over one shortcut.
    static let togglePopover = Self("togglePopover", default: .init(.l, modifiers: [.control, .option]))
}
