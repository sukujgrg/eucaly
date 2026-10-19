import AppKit

@MainActor
func finishOutputSettingsFieldEditing(in view: NSView) {
    guard let window = view.window, let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else { return }
    window.makeFirstResponder(nil)
}

@MainActor
func outputSettingsLabel(_ text: String = "", secondary: Bool = false, heading: Bool = false) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: secondary ? 12 : 13, weight: heading ? .semibold : .regular)
    label.textColor = secondary ? .secondaryLabelColor : .labelColor
    return label
}

@MainActor
func outputSettingsHorizontal(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}

@MainActor
func outputSettingsRow(_ title: String, _ control: NSView) -> NSStackView {
    let label = outputSettingsLabel(title)
    label.widthAnchor.constraint(equalToConstant: 112).isActive = true
    return outputSettingsHorizontal([label, control], spacing: 12)
}

@MainActor
func outputSettingsActionRow(_ buttons: [NSButton]) -> NSStackView {
    for button in buttons {
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }
    return outputSettingsRow("", outputSettingsHorizontal(buttons + [NSView()]))
}

/// Related actions sit beneath their field, sharing the form's control column.
@MainActor
func outputSettingsFieldGroup(_ title: String, _ control: NSView, actions: [NSButton]) -> NSStackView {
    let stack = NSStackView(views: [outputSettingsRow(title, control), outputSettingsActionRow(actions)])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    for row in stack.arrangedSubviews { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return stack
}

@MainActor
func outputSettingsPin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
    child.translatesAutoresizingMaskIntoConstraints = false
    parent.addSubview(child)
    NSLayoutConstraint.activate([
        child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
        child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
        child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
        child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
    ])
}

@MainActor
final class OutputSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A section can be hidden as a unit while its controls keep their own state.
@MainActor
final class OutputSettingsGroup: NSStackView {
    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 12
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func add(_ row: NSView) {
        addArrangedSubview(row); row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
    }
    func section(_ title: String) {
        if !arrangedSubviews.isEmpty { let separator = NSBox(); separator.boxType = .separator; add(separator) }
        add(outputSettingsLabel(title, heading: true))
    }
}

/// Explicit widths keep native form rows aligned as the Settings window resizes.
@MainActor
final class OutputSettingsForm: NSScrollView {
    let stack = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        let document = OutputSettingsDocumentView()
        document.translatesAutoresizingMaskIntoConstraints = false
        documentView = document
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -20)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func add(_ row: NSView) {
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    func section(_ title: String) {
        if !stack.arrangedSubviews.isEmpty {
            let separator = NSBox(); separator.boxType = .separator; add(separator)
        }
        add(outputSettingsLabel(title, heading: true))
    }
}

/// Every point across the header is a native button, including its trailing space.
@MainActor
final class OutputSettingsDisclosure: NSStackView {
    let header = NSButton()
    let content = NSStackView()
    private let heading: String
    private var buildContent: ((OutputSettingsDisclosure) -> Void)?

    init(_ title: String, buildContent: ((OutputSettingsDisclosure) -> Void)? = nil) {
        heading = title
        self.buildContent = buildContent
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        header.isBordered = false
        header.alignment = .left
        header.font = .systemFont(ofSize: 13, weight: .medium)
        header.target = self
        header.action = #selector(toggle(_:))
        header.setAccessibilityLabel(title)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        content.isHidden = true
        addArrangedSubview(header)
        addArrangedSubview(content)
        header.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        content.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        renderHeader()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func add(_ row: NSView) {
        content.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
    }
    @objc func toggle(_ sender: Any?) {
        setExpanded(content.isHidden)
    }
    func setExpanded(_ expanded: Bool) {
        if expanded, let buildContent {
            self.buildContent = nil
            buildContent(self)
        }
        content.isHidden = !expanded
        renderHeader()
    }
    private func renderHeader() {
        header.title = "\(content.isHidden ? "▸" : "▾") \(heading)"
        header.setAccessibilityValue(content.isHidden ? "Collapsed" : "Expanded")
    }
}

@MainActor
final class OutputSettingsSlider: NSSlider {
    private(set) var isTrackingMouse = false
    var onTrackingEnded: () -> Void = {}
    override func mouseDown(with event: NSEvent) {
        isTrackingMouse = true
        super.mouseDown(with: event)
        isTrackingMouse = false
        onTrackingEnded()
    }
}

/// Native tracking stays stable. Coalesce live edits, then flush the final value.
@MainActor
final class OutputSettingsNumberRow: NSView, NSTextFieldDelegate {
    let slider = OutputSettingsSlider()
    let field = NSTextField()
    private let range: ClosedRange<Double>
    private let step: Double
    private let scale: Double
    // Return the stored value, including when validation rejects the proposal.
    private let changed: (Double) -> Double
    private let invalid: () -> Void
    private var acceptedValue: Double = 0
    private var displayedReadout = ""
    private var didEditText = false
    private var pending: Double?
    private var commitTask: Task<Void, Never>?

    init(_ title: String, range: ClosedRange<Double>, step: Double = 1, scale: Double = 1,
         unit: String = "pt", changed: @escaping (Double) -> Double, invalid: @escaping () -> Void) {
        self.range = range; self.step = step; self.scale = scale
        self.changed = changed; self.invalid = invalid
        super.init(frame: .zero)
        slider.minValue = range.lowerBound; slider.maxValue = range.upperBound
        slider.altIncrementValue = step; slider.isContinuous = true
        slider.target = self; slider.action = #selector(sliderChanged(_:))
        slider.setAccessibilityLabel(title)
        slider.onTrackingEnded = { [weak self] in self?.flush() }
        field.delegate = self
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.widthAnchor.constraint(equalToConstant: 58).isActive = true
        field.setAccessibilityLabel(title + " value")
        let unitLabel = outputSettingsLabel(unit, secondary: true)
        unitLabel.widthAnchor.constraint(equalToConstant: 24).isActive = true
        outputSettingsPin(outputSettingsRow(title, outputSettingsHorizontal([slider, field, unitLabel])), to: self)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { commitTask?.cancel() }
    func render(_ value: Double, enabled: Bool = true) {
        acceptedValue = value
        slider.isEnabled = enabled; field.isEnabled = enabled
        guard !slider.isTrackingMouse, pending == nil else { return }
        renderAcceptedValue()
    }
    private func renderAcceptedValue(finishingEdit: Bool = false) {
        guard !slider.isTrackingMouse else { return }
        slider.doubleValue = acceptedValue * scale
        if finishingEdit || field.currentEditor() == nil {
            displayedReadout = readout(acceptedValue * scale)
            field.stringValue = displayedReadout
        }
    }
    private func readout(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
    @objc func sliderChanged(_ sender: NSSlider) {
        let value = (sender.doubleValue / step).rounded() * step
        displayedReadout = readout(value)
        field.stringValue = displayedReadout
        pending = value / scale
        if !slider.isTrackingMouse { flush(); return }
        guard commitTask == nil else { return }
        commitTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(30))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }
    func flush() {
        commitTask?.cancel(); commitTask = nil
        if let pending { self.pending = nil; acceptedValue = changed(pending) }
        renderAcceptedValue()
    }
    func controlTextDidBeginEditing(_ notification: Notification) {
        didEditText = false
    }
    func controlTextDidChange(_ notification: Notification) {
        didEditText = true
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        defer { didEditText = false; renderAcceptedValue(finishingEdit: true) }
        // Display rounding is presentation only. Focus changes must not write
        // the rounded readout back over the exact saved preference.
        guard didEditText || field.stringValue != displayedReadout else { return }
        guard let value = Double(field.stringValue), value.isFinite, range.contains(value) else {
            invalid(); return
        }
        pending = value / scale
        flush()
    }
}

@MainActor
extension OutputColour {
    var nativeColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    init(nativeColor: NSColor, opaque: Bool = false) {
        let color = nativeColor.usingColorSpace(.sRGB) ?? .white
        self.init(red: color.redComponent, green: color.greenComponent, blue: color.blueComponent,
                  alpha: opaque ? 1 : color.alphaComponent)
    }
}
