import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Portfox takes ⌃⌥P, so the two apps never fight over one shortcut.
    static let togglePopover = Self("togglePopover", initial: .init(.l, modifiers: [.control, .option]))
}
