import AppKit
import Combine

nonisolated enum SidebarSectionMetrics {
    static let outerInset: CGFloat = 16
    static let contentInset: CGFloat = 10
}

extension NSControl {
    /// AppKit exposes a single-cell control's cell as its native accessibility
    /// element. Configure that element without replacing its role or actions.
    var sidebarAccessibilityElement: any NSAccessibilityProtocol {
        if let cell { return cell }
        return self
    }
}

enum SidebarSection: String, CaseIterable {
    case library, playlist, audio, windows

    var title: String {
        switch self {
        case .library: "Library"
        case .playlist: "Playlist"
        case .audio: "Audio"
        case .windows: "Window"
        }
    }

    var symbol: String {
        switch self {
        case .library, .playlist: "folder"
        case .audio: "music.note.list"
        case .windows: "macwindow"
        }
    }

    var color: NSColor {
        switch self {
        case .library: .systemTeal
        case .playlist: .systemGreen
        case .audio: .systemPurple
        case .windows: .systemOrange
        }
    }

    var preferenceKey: String { "sidebar.\(rawValue)SectionExpanded" }
    var defaultExpanded: Bool { self == .library || self == .playlist }
}

@MainActor
final class SidebarSectionView: NSStackView {
    let header: SidebarSectionHeaderButton
    let content = NSStackView()
    private(set) var isExpanded = true

    init(section: SidebarSection, target: AnyObject, action: Selector) {
        header = SidebarSectionHeaderButton(section: section)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        detachesHiddenViews = true
        header.target = target
        header.action = action
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.detachesHiddenViews = true
        addArrangedSubview(header)
        addArrangedSubview(content)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
        if !expanded, let responder = window?.firstResponder as? NSView,
           responder.isDescendant(of: content) {
            window?.makeFirstResponder(header)
        }
        content.isHidden = !expanded
        header.updateExpanded(expanded)
    }

    func append(_ view: NSView) {
        content.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
}

/// A native button owns the full header's hit area, keyboard activation and
/// accessibility. Its content has a separate gutter inside the hover surface.
@MainActor
final class SidebarSectionHeaderButton: NSButton {
    let section: SidebarSection
    private let disclosure = NSImageView()
    private var hoverArea: NSTrackingArea?
    private var isHovered = false
    private var keyWindowSubscription: AnyCancellable?

    init(section: SidebarSection) {
        self.section = section
        super.init(frame: .zero)
        title = ""
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .exterior
        sidebarAccessibilityElement.setAccessibilityLabel("\(section.title) section")
        sidebarAccessibilityElement.setAccessibilityIdentifier("sidebar.\(section.rawValue).header")

        let image = NSImageView()
        image.image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: nil)
        image.contentTintColor = section.color
        image.setAccessibilityElement(false)
        let title = NSTextField(labelWithString: section.title)
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.sidebarAccessibilityElement.setAccessibilityElement(false)
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.setAccessibilityElement(false)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [image, title, spacer, disclosure])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarSectionMetrics.contentInset),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarSectionMetrics.contentInset),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 16),
            image.heightAnchor.constraint(equalToConstant: 20),
            disclosure.widthAnchor.constraint(equalToConstant: 16),
            disclosure.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 26) }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill() }
    override func hitTest(_ point: NSPoint) -> NSView? { super.hitTest(point) == nil ? nil : self }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyWindowSubscription = nil
        isHovered = false
        if let window {
            keyWindowSubscription = NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification, object: window)
                .sink { [weak self] _ in self?.isHovered = false; self?.needsDisplay = true }
        }
    }

    func updateExpanded(_ expanded: Bool) {
        disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)
        sidebarAccessibilityElement.setAccessibilityExpanded(expanded)
        sidebarAccessibilityElement.setAccessibilityValueDescription(expanded ? "Expanded" : "Collapsed")
        sidebarAccessibilityElement.setAccessibilityHelp(expanded ? "Collapses the section" : "Expands the section")
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }

    override func keyDown(with event: NSEvent) {
        let modifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if event.keyCode == 49, event.modifierFlags.intersection(modifiers).isEmpty,
           window?.firstResponder === self {
            if !event.isARepeat { performClick(nil) }
            return
        }
        super.keyDown(with: event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if window?.isKeyWindow == true && (isHovered || isHighlighted) {
            NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.10 : 0.055).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
        super.draw(dirtyRect)
    }
}

@MainActor
final class SidebarAudioSlider: NSSlider {
    private(set) var isTracking = false

    override func mouseDown(with event: NSEvent) {
        isTracking = true
        defer { isTracking = false }
        super.mouseDown(with: event)
    }
}
