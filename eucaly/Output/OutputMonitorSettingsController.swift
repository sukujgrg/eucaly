import AppKit
import Combine

/// Monitor names use the same immediate-edit contract as output/profile names.
@MainActor
final class OutputMonitorSettingsController: NSViewController, NSTextFieldDelegate {
    let displays: ProjectionDisplayManager
    private let target: ProjectionMonitorTarget?
    private let form = OutputSettingsForm(frame: .zero)
    private var names: [NSTextField: ProjectionMonitorTarget] = [:]
    private var identifyButtons: [NSButton: ProjectionMonitorTarget] = [:]
    private var labels: [(ProjectionMonitorTarget, NSTextField, NSTextField)] = []
    private let error = outputSettingsLabel(secondary: true)
    private var subscription: AnyCancellable?
    private var renderTask: Task<Void, Never>?
    private var displayedTargets: [ProjectionMonitorTarget] = []
    private var isRebuilding = false

    init(displays: ProjectionDisplayManager, target: ProjectionMonitorTarget? = nil) {
        self.displays = displays; self.target = target
        super.init(nibName: nil, bundle: nil)
        subscription = displays.objectWillChange.sink { [weak self] _ in
            guard self?.renderTask == nil else { return }
            self?.renderTask = Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, !Task.isCancelled else { return }
                self.renderTask = nil; self.render()
            }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { renderTask?.cancel() }
    override func loadView() {
        view = NSView()
        let done = NSButton(title: "Done", target: self, action: #selector(close(_:)))
        done.keyEquivalent = "\r"
        done.translatesAutoresizingMaskIntoConstraints = false
        form.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(form); view.addSubview(done)
        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            form.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            form.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            form.bottomAnchor.constraint(equalTo: done.topAnchor, constant: -12),
            done.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            done.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
        rebuildRows(targets: currentTargets)
        render()
    }
    private var currentTargets: [ProjectionMonitorTarget] {
        let connected = displays.displays.map(\.target)
        return target.map { [$0] } ?? (connected + displays.knownTargets.filter { saved in !connected.contains { $0.identity == saved.identity } })
    }
    private func rebuildRows(targets: [ProjectionMonitorTarget]) {
        isRebuilding = true
        defer { isRebuilding = false }
        displayedTargets = targets
        finishOutputSettingsFieldEditing(in: view)
        for row in form.stack.arrangedSubviews {
            form.stack.removeArrangedSubview(row); row.removeFromSuperview()
        }
        names.removeAll(); identifyButtons.removeAll(); labels.removeAll()
        form.add(outputSettingsLabel("Names apply when editing ends. Use up to 40 characters on one line; leave empty to use the model name.", secondary: true))
        if targets.isEmpty { form.add(outputSettingsLabel("Connect a monitor to name and identify it.", secondary: true)) }
        for target in targets {
            let heading = outputSettingsLabel(heading: true)
            let detail = outputSettingsLabel(secondary: true)
            form.add(heading); form.add(detail); labels.append((target, heading, detail))
            let field = NSTextField(); field.delegate = self; field.placeholderString = "Monitor name"
            field.setAccessibilityLabel("Name for " + displays.label(for: target)); names[field] = target
            let identify = NSButton(title: "Identify", target: self, action: #selector(identifyMonitor(_:)))
            identifyButtons[identify] = target
            form.add(outputSettingsFieldGroup("Name", field, actions: [identify]))
            let disclosure = OutputSettingsDisclosure("Monitor Details")
            disclosure.add(outputSettingsLabel(target.name, secondary: true))
            disclosure.add(outputSettingsLabel("macOS display UUID", secondary: true))
            let uuid = outputSettingsLabel(target.identity, secondary: true)
            uuid.font = .monospacedSystemFont(ofSize: 11, weight: .regular); uuid.isSelectable = true
            disclosure.add(uuid); form.add(disclosure)
        }
        error.textColor = .systemOrange; form.add(error)
        form.add(outputSettingsLabel("Identify briefly labels an idle monitor without changing Current or opening projection. Names and numbers are remembered.", secondary: true))
    }
    func render() {
        guard isViewLoaded, !isRebuilding else { return }
        if currentTargets != displayedTargets { rebuildRows(targets: currentTargets) }
        for (target, heading, detail) in labels {
            heading.stringValue = displays.label(for: target)
            detail.stringValue = displays.resolve(target).map { "\($0.name) · \(Int($0.frame.width)) × \(Int($0.frame.height))" } ?? "Disconnected"
        }
        for (field, target) in names {
            if field.currentEditor() == nil { field.stringValue = displays.nickname(for: target) }
            field.isEnabled = displays.canRename(target)
        }
        for (button, target) in identifyButtons { button.isEnabled = displays.canIdentify(target) }
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let target = names[field] else { return }
        if displays.rename(target, to: field.stringValue) { error.stringValue = "" }
        else {
            error.stringValue = "Use a valid name for a distinguishable monitor."
            field.stringValue = displays.nickname(for: target)
        }
        render()
    }
    @objc private func identifyMonitor(_ sender: NSButton) { if let target = identifyButtons[sender] { displays.identify(target) } }
    @objc private func close(_ sender: Any?) {
        finishOutputSettingsFieldEditing(in: view)
        if let sheet = view.window { sheet.sheetParent?.endSheet(sheet) }
    }
    static func present(displays: ProjectionDisplayManager, target: ProjectionMonitorTarget? = nil, from parent: NSWindow?) {
        guard let parent, parent.attachedSheet == nil else { return }
        let sheet = NSWindow(contentRect: .init(x: 0, y: 0, width: 560, height: target == nil ? 500 : 350),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.title = target == nil ? "Monitors" : "Name Monitor"
        sheet.contentMinSize = .init(width: 480, height: 300)
        sheet.contentViewController = OutputMonitorSettingsController(displays: displays, target: target)
        parent.beginSheet(sheet) { _ in sheet.orderOut(nil) }
    }
}
