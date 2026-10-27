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
