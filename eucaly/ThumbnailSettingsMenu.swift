import AppKit

@MainActor
final class ThumbnailSettingsMenuController: NSObject {
    let button = NSPopUpButton(frame: .zero, pullsDown: true)
    private let defaults: UserDefaults
    private var renderedSize: Double?
    private var renderedFontSize: Double?
    private var isRetired = false

    init(defaults: UserDefaults) {
        self.defaults = defaults
        super.init()
        button.bezelStyle = .toolbar; button.imagePosition = .imageOnly
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.setControlAccessibility(label: "Thumbnails")
        refresh()
    }
    func refresh() {
        guard !isRetired else { return }
        func scale(_ key: String) -> Double {
            defaults.object(forKey: key) == nil ? 1 : defaults.double(forKey: key)
        }
        render(size: scale("thumbnailScale"), fontSize: scale("thumbnailFontScale"))
    }
    func render(size: Double, fontSize: Double) {
        guard !isRetired else { return }
        let size = size.isFinite ? size : 1
        let fontSize = fontSize.isFinite ? fontSize : 1
        guard size != renderedSize || fontSize != renderedFontSize else { return }
        renderedSize = size; renderedFontSize = fontSize
        let menu = NSMenu(); menu.autoenablesItems = false
        let glyph = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        glyph.image = NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)
        menu.addItem(glyph)
        addChoices("Thumbnail Size", key: "thumbnailScale", current: size, presets: Array(stride(from: 60, through: 160, by: 10)), to: menu)
        addChoices("Thumbnail Font Size", key: "thumbnailFontScale", current: fontSize, presets: Array(stride(from: 30, through: 200, by: 10)), to: menu)
        button.menu = menu
        button.toolTip = "Thumbnail size: \(percentage(size)). Font size: \(percentage(fontSize))."
        button.setControlAccessibility(label: "Thumbnails", value: "Size: \(percentage(size)); font size: \(percentage(fontSize))",
                                       help: button.toolTip)
    }
    private func addChoices(_ title: String, key: String, current: Double, presets: [Int], to menu: NSMenu) {
        let choices = NSMenu(); choices.autoenablesItems = false
        // Retain exact preferences saved before these controls moved out of
        // General Settings. Opening the menu never rounds or rewrites them.
        if !presets.contains(where: { Double($0) / 100 == current }) {
            let saved = NSMenuItem(title: percentage(current) + " (Current)", action: nil, keyEquivalent: "")
            saved.state = .on; saved.isEnabled = false; choices.addItem(saved)
        }
        for percent in presets {
            let value = Double(percent) / 100
            let item = NSMenuItem(title: percentage(value), action: #selector(selectPercentage(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = Choice(key: key, value: value)
            item.state = value == current ? .on : .off; choices.addItem(item)
        }
        let item = NSMenuItem(title: title + ": " + percentage(current), action: nil, keyEquivalent: "")
        item.submenu = choices; menu.addItem(item)
    }
    private func percentage(_ value: Double) -> String { value.formatted(.percent.precision(.fractionLength(0...1))) }
    func retire() {
        isRetired = true
        button.isEnabled = false
    }
    @objc private func selectPercentage(_ sender: NSMenuItem) {
        guard !isRetired, let choice = sender.representedObject as? Choice else { return }
        defaults.set(choice.value, forKey: choice.key); refresh()
    }
    private final class Choice {
        let key: String
        let value: Double
        init(key: String, value: Double) { self.key = key; self.value = value }
    }
}
