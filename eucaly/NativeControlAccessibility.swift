import AppKit

extension NSControl {
    /// AppKit can expose cells as accessibility elements for native controls.
    /// Keep that native element and the hosting view's metadata in agreement.
    func setControlAccessibility(label: String, value: String? = nil, help: String? = nil) {
        setAccessibilityLabel(label); cell?.setAccessibilityLabel(label)
        if let value { setAccessibilityValue(value); cell?.setAccessibilityValue(value) }
        if let help { setAccessibilityHelp(help); cell?.setAccessibilityHelp(help) }
    }
}

/// Icon-only accessory inside a list/outline row. Owns Space activation and
/// Shift-Tab return without depending on key-window button tracking.
final class EmbeddedAccessoryButton: NSButton {
    var onBackTab: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        isEnabled && !isHiddenOrHasHiddenAncestor
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 49, modifiers.isEmpty,
           isEnabled, window?.firstResponder === self {
            if !event.isARepeat { performClick(nil) }
            return
        }
        if event.keyCode == 48, modifiers == .shift, let onBackTab {
            onBackTab()
            return
        }
        super.keyDown(with: event)
    }
}
