// Shares ViewTheWord’s native AltView settings layout and interaction model.
import AppKit
import Combine

@MainActor
final class AltViewSettingsController: NSViewController, NSTextFieldDelegate {
    let receiverPicker = NSPopUpButton()
    let templatePicker = NSPopUpButton()
    let templateHint = NSTextField(wrappingLabelWithString: "")
    private var templateMenuEntries: [AltViewTemplateDescriptor]?
    private var unavailableTemplate: AltViewContentTemplate?
    let hostField = NSTextField()
    let portField = NSTextField(string: "49721")
    let codeField = NSSecureTextField()
    let connectButton = NSButton(title: "Connect Only", target: nil, action: nil)
    let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    let statusBadge = AltViewStatusBadge()
    let statusLabel = NSTextField(wrappingLabelWithString: "Not connected")
    private let service: AltViewService
    private var receivers: [AltViewDestination] = []
    private var selected: AltViewDestination?
    private var subscription: AnyCancellable?
    private var renderScheduled = false
    private var receiverMenuEntries: [AltViewDestination]?
    var discoveryEnabled = true
    init(service: AltViewService) {
        self.service = service
        self.selected = service.destination?.host == nil ? service.destination : nil
        super.init(nibName: nil, bundle: nil)
        hostField.stringValue = service.destination?.host ?? ""
        portField.stringValue = String(service.destination?.port ?? 49721)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = NSView()
        let explanation = NSTextField(wrappingLabelWithString: "Send the main lyrics to AltView on another Mac. Meaning, translation and transliteration stay in eucaly.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = .secondaryLabelColor
        receiverPicker.target = self; receiverPicker.action = #selector(destinationChanged(_:))
        receiverPicker.setAccessibilityLabel("AltView receiver")
        templatePicker.target = self; templatePicker.action = #selector(templateChanged(_:))
        templatePicker.setAccessibilityLabel("AltView template")
        templatePicker.menu?.autoenablesItems = false
        templateHint.font = .systemFont(ofSize: 11); templateHint.textColor = .secondaryLabelColor
        templateHint.maximumNumberOfLines = 0
        hostField.placeholderString = "Receiving Mac name or IP address"
        hostField.setAccessibilityLabel("AltView host")
        portField.setAccessibilityLabel("AltView port")
        portField.widthAnchor.constraint(equalToConstant: 70).isActive = true
        codeField.placeholderString = "8-character code, or leave empty to use saved pairing"
        codeField.setAccessibilityLabel("AltView pairing code")
        for field in [hostField, portField, codeField] { field.delegate = self }
        for button in [connectButton, disconnectButton] { button.target = self; button.bezelStyle = .rounded }
        connectButton.action = #selector(connect(_:)); disconnectButton.action = #selector(disconnect(_:))
        connectButton.keyEquivalent = "\r"
        let hint = NSTextField(wrappingLabelWithString: "The last receiver connects automatically at startup and reconnects after a network drop. Show Slides to send Current; Hide, Clear and Stop follow eucaly. Appearance and display are set in AltView.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 0
        statusLabel.setAccessibilityLabel("AltView status")
        let actions = horizontalStack([connectButton, disconnectButton, NSView(), statusBadge])
        let stack = NSStackView(views: [explanation, row("Receiver", receiverPicker),
                                      row("Address", horizontalStack([hostField, portField])),
                                      row("Pairing code", codeField), actions, row("Template", templatePicker), templateHint, statusLabel, hint])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -16)
        ])
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        refreshReceivers()
        subscription = service.objectWillChange.sink { [weak self] _ in
            // ObservableObject fires before mutation; coalesce outside that boundary.
            guard let self, !self.renderScheduled else { return }
            self.renderScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.renderScheduled = false
                self?.render()
            }
        }
        render()
    }
    private func row(_ title: String, _ control: NSView) -> NSView {
        let label = nativeLabel(title)
        label.widthAnchor.constraint(equalToConstant: 84).isActive = true
        return horizontalStack([label, control], spacing: 12)
    }
    override func viewWillAppear() { super.viewWillAppear(); startDiscovery(); render() }
    override func viewWillDisappear() { super.viewWillDisappear(); stopDiscovery() }
    func startDiscovery() { if discoveryEnabled { service.startDiscovery() } }
    func stopDiscovery() { if discoveryEnabled { service.stopDiscovery() } }
    private func refreshReceivers() {
        receivers = service.receivers
        if let selected, !receivers.contains(selected) { receivers.insert(selected, at: 0) }
        guard receiverMenuEntries != receivers else { return }
        receiverMenuEntries = receivers
        receiverPicker.removeAllItems()
        receiverPicker.addItem(withTitle: "Manual address")
        for (index, receiver) in receivers.enumerated() {
            let item = NSMenuItem(title: receiver.name, action: nil, keyEquivalent: "")
            item.tag = index + 1
            receiverPicker.menu?.addItem(item)
        }
        receiverPicker.selectItem(at: selected.flatMap { receivers.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
    }
    private func render() {
        guard isViewLoaded else { return }
        refreshReceivers()
        hostField.isEnabled = selected == nil; portField.isEnabled = selected == nil
        let connecting = service.hasConnection && !service.status.connected
            && (service.status.failureReason == nil || service.status.waitingToRetry)
        disconnectButton.isEnabled = service.status.connected || connecting
        disconnectButton.title = connecting ? "Cancel" : "Disconnect"
        connectButton.isEnabled = !service.hasConnection || (!connecting && service.status.failureReason != nil)
        refreshTemplatePicker()
        statusBadge.render(service)
        statusLabel.stringValue = service.detail + (service.discoveryNotice.map { "\n\($0)" } ?? "")
        statusLabel.toolTip = statusLabel.stringValue
        if service.status.connected { codeField.stringValue = "" }
    }
    private func refreshTemplatePicker() {
        let capabilities = service.status.templateCapabilities
        let entries = capabilities.templates ?? []
        let unavailable = service.selectedTemplate.flatMap { capabilities.supports($0) ? nil : $0 }
        // Routine acknowledgement/policy updates must not replace an open menu.
        if templateMenuEntries != entries || unavailableTemplate != unavailable {
            templateMenuEntries = entries; unavailableTemplate = unavailable
            templatePicker.removeAllItems()
            templatePicker.addItem(withTitle: "Receiver’s layout")
            for descriptor in entries {
                let item = NSMenuItem(title: descriptor.name, action: nil, keyEquivalent: "")
                item.representedObject = descriptor.id.rawValue
                templatePicker.menu?.addItem(item)
            }
            if let unavailable {
                let item = NSMenuItem(title: "\(unavailable.rawValue) · Unavailable", action: nil, keyEquivalent: "")
                item.representedObject = unavailable.rawValue
                item.isEnabled = false
                templatePicker.menu?.addItem(item)
            }
        }
        if let requested = service.selectedTemplate,
           let item = templatePicker.itemArray.first(where: { $0.representedObject as? String == requested.rawValue }) {
            templatePicker.select(item)
        } else { templatePicker.selectItem(at: 0) }
        templatePicker.isEnabled = service.status.connected
        let detail = service.status.connected ? capabilities.requestDetail(service.selectedTemplate)
            : "Connect to discover the receiver’s templates."
        templateHint.stringValue = "\(detail) Changes apply when you next show a slide."
        templateHint.toolTip = templateHint.stringValue
    }
    @objc private func templateChanged(_ sender: Any?) {
        service.selectTemplate((templatePicker.selectedItem?.representedObject as? String).map(AltViewContentTemplate.init(rawValue:)))
        refreshTemplatePicker()
    }
    @objc private func destinationChanged(_ sender: Any?) {
        let index = receiverPicker.indexOfSelectedItem - 1
        selected = receivers.indices.contains(index) ? receivers[index] : nil
        service.disconnect(); codeField.stringValue = ""
        render()
    }
    func controlTextDidChange(_ obj: Notification) {
        // Changing destination/code cancels setup and invalidates delayed callbacks.
        if service.hasConnection { service.disconnect() }
        render()
    }
    @objc private func connect(_ sender: Any?) {
        let destination: AltViewDestination
        if let selected { destination = selected }
        else {
            guard let manual = AltViewDestination.manual(host: hostField.stringValue, port: portField.stringValue) else {
                statusLabel.stringValue = "Enter a receiving Mac name or IP address and a port from 1 to 65535."
                return
            }
            destination = manual
        }
        service.connect(to: destination, code: codeField.stringValue)
        render()
    }
    @objc private func disconnect(_ sender: Any?) { service.disconnect(); render() }
}

private func nativeLabel(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 13)
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return label
}

private func horizontalStack(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = spacing
    return stack
}
