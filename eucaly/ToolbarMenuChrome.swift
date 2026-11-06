import AppKit

/// Presentation state for an `NSMenuToolbarItem`. Controllers own menus and
/// captions; AppKit owns toolbar sizing through the system item chrome.
@MainActor
struct ToolbarMenuChrome {
    var title = ""
    var image: NSImage?
    var menu: NSMenu?
    var toolTip: String?
    var isEnabled = true
    var accessibilityLabel: String?
    var accessibilityHelp: String?
    var accessibilityValue: String?

    func apply(to item: NSMenuToolbarItem) {
        item.showsIndicator = true
        // Click opens the menu; the indicator is decorative.
        item.target = nil
        item.action = nil
        item.title = title
        item.image = image
        item.menu = menu ?? NSMenu()
        // Toolbar items expose help through toolTip; keep an explicit help
        // string available when callers set it without a separate tooltip.
        item.toolTip = toolTip ?? accessibilityHelp
        item.isEnabled = isEnabled
        let label = accessibilityLabel ?? (title.isEmpty ? item.label : title)
        item.label = label
        item.paletteLabel = label
        // NSMenuToolbarItem has no accessibilityValue API; VoiceOver still
        // announces the image description for icon-only controls.
        if let accessibilityValue {
            item.image?.accessibilityDescription = accessibilityValue
        }
    }
}
