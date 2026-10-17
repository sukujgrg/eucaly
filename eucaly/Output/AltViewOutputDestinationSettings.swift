import AppKit
import Combine

/// Assignment and pairing share one Settings form. Credentials remain receiver-level.
@MainActor
final class AltViewOutputDestinationSettings: NSViewController {
    let router: AltViewOutputRouter
    let store: OutputProfileStore
    let destinationID: UUID
    let receiverPicker = NSPopUpButton()
    let statusLabel = outputSettingsLabel(secondary: true)
    let pairing: AltViewReceiverPairingView
    private var targets: [OutputReceiverTarget] = []
    private var subscriptions = Set<AnyCancellable>()
    private var reloadTask: Task<Void, Never>?
    private var isActive = true
    private var notice: String?
    private var unavailableID: UUID?
    init(router: AltViewOutputRouter, store: OutputProfileStore, destinationID: UUID) {
        self.router = router; self.store = store; self.destinationID = destinationID
        pairing = AltViewReceiverPairingView(router: router)
        super.init(nibName: nil, bundle: nil)
        for publisher in [router.objectWillChange, store.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleRender() }.store(in: &subscriptions)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { reloadTask?.cancel() }
    override func loadView() {
        receiverPicker.target = self; receiverPicker.action = #selector(receiverChanged)
        receiverPicker.setAccessibilityLabel("AltView Lyrics receiver")
        let stack = NSStackView(views: [outputSettingsRow("Receiver", receiverPicker), pairing, statusLabel,
            outputSettingsLabel("Show Slides sends Lyrics when this output is enabled. Appearance and displays are set in AltView.", secondary: true)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        for row in stack.arrangedSubviews { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        view = stack; render()
    }
    private func scheduleRender() {
        guard isActive, reloadTask == nil else { return }
        reloadTask = Task { @MainActor [weak self] in
            await Task.yield(); guard let self, !Task.isCancelled else { return }
            self.reloadTask = nil; self.render()
        }
    }
    func setActive(_ value: Bool) {
        isActive = value
        if value { render() } else { pairing.clearCode() }
    }
    func render() {
        guard isActive, isViewLoaded, let row = store.document.destinations.first(where: { $0.id == destinationID }) else { return }
        if let unavailableID, router.receivers.contains(where: { $0.receiverIdentity == unavailableID }) {
            notice = nil; self.unavailableID = nil
        }
        targets = router.knownReceivers
        let titles = ["None"] + altViewReceiverTitles(targets)
        if receiverPicker.itemTitles != titles {
            receiverPicker.removeAllItems(); receiverPicker.addItems(withTitles: titles)
        }
        for (index, target) in targets.enumerated() {
            receiverPicker.item(at: index + 1)?.representedObject = target.receiverID
            receiverPicker.item(at: index + 1)?.toolTip = target.receiverID.uuidString
        }
        receiverPicker.selectItem(at: targets.firstIndex { $0.receiverID == row.receiver?.receiverID }.map { $0 + 1 } ?? 0)
        pairing.render(receiverID: row.receiver?.receiverID)
        let channel = router.channel(for: destinationID)
        statusLabel.stringValue = notice ?? (row.receiver == nil ? "Choose an AltView receiver for this output." : channel?.status.connected == true ? channel?.deliveryDetail ?? "" : "")
        statusLabel.isHidden = statusLabel.stringValue.isEmpty
    }
    @objc private func receiverChanged() {
        let id = receiverPicker.selectedItem?.representedObject as? UUID
        guard id == nil || router.knownReceivers.contains(where: { $0.receiverID == id }) else {
            unavailableID = id
            notice = "This receiver is no longer available. Choose it again after it reconnects."; render(); return
        }
        let target = router.knownReceivers.first { $0.receiverID == id }
        notice = store.assignReceiver(target, to: destinationID); render()
    }
}

@MainActor
func altViewReceiverTitles(_ targets: [OutputReceiverTarget]) -> [String] {
    let names = Dictionary(grouping: targets, by: \.name)
    return targets.map { target in
        target.name + ((names[target.name]?.count ?? 0) > 1 || target.name == "None" ? " · \(target.receiverID.uuidString.prefix(8))" : "")
    }
}

/// The same compact form is embedded below each output's receiver picker.
/// Lyrics and Media use the router's single control connection and Keychain record.
@MainActor
final class AltViewReceiverPairingView: NSStackView {
    private weak var router: AltViewOutputRouter?
    private var selected: UUID?
    let codeField = NSSecureTextField()
    let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    let statusLabel = outputSettingsLabel(secondary: true)
    private var codeRow: NSView!
    private var hintRow: NSView!
    private var connectionRow: NSView!
    init(router: AltViewOutputRouter?) {
        self.router = router
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 8
        codeField.placeholderString = "8-character code"
        codeField.setAccessibilityLabel("Receiver pairing code")
        codeField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        codeField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        codeField.toolTip = "Leave empty to use the saved receiver pairing. AltView automatically generates and shares the separate 32-character SRT secret."
        codeField.target = self; codeField.action = #selector(connect)
        connectButton.target = self; connectButton.action = #selector(connect)
        disconnectButton.target = self; disconnectButton.action = #selector(disconnect)
        for button in [connectButton, disconnectButton] {
            button.bezelStyle = .rounded; button.controlSize = .small
            button.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        codeRow = outputSettingsRow("Pairing code", outputSettingsHorizontal([codeField, connectButton, NSView()]))
        hintRow = outputSettingsRow("", outputSettingsLabel("Code from AltView → Connections. Media encryption is automatic.", secondary: true))
        statusLabel.maximumNumberOfLines = 3
        connectionRow = outputSettingsRow("Connection", outputSettingsHorizontal([statusLabel, NSView(), disconnectButton]))
        for row in [codeRow!, hintRow!, connectionRow!] {
            addArrangedSubview(row); row.widthAnchor.constraint(equalTo: widthAnchor).isActive = true
        }
        render(receiverID: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func clearCode() { codeField.stringValue = "" }
    func render(receiverID: UUID?) {
        if selected != receiverID { clearCode(); selected = receiverID }
        isHidden = receiverID == nil
        guard let receiverID else { return }
        let channel = router?.receiverChannel(receiverID)
        let connected = channel?.status.connected == true
        let connecting = channel?.isConnecting == true || channel?.status.waitingToRetry == true
            || (channel?.hasConnection == true && !connected && channel?.status.failureReason == nil)
        let available = router?.receivers.contains { $0.receiverIdentity == receiverID } == true
        if connected { clearCode() }
        codeRow.isHidden = connected; hintRow.isHidden = connected
        codeField.isEnabled = available && !connecting
        connectButton.isEnabled = available && !connecting
        disconnectButton.title = connecting ? "Cancel" : "Disconnect"
        disconnectButton.isHidden = channel?.hasConnection != true
        disconnectButton.isEnabled = channel?.hasConnection == true
        let issue = channel?.persistenceNotice ?? (channel?.requiresPairingCode == true ? nil : channel?.connectionNotice)
        connectionRow.isHidden = available && !connected && !connecting && issue == nil && channel?.status.failureReason == nil
        if let issue { statusLabel.stringValue = issue }
        else if connected { statusLabel.stringValue = "Connected · shared by Lyrics and Media" }
        else if connecting { statusLabel.stringValue = "Connecting…" }
        else if channel?.status.failureReason != nil { statusLabel.stringValue = channel?.status.message ?? "Connection failed" }
        else { statusLabel.stringValue = available ? "Not connected" : "Receiver unavailable" }
        statusLabel.textColor = issue != nil || channel?.status.failureReason != nil ? .systemOrange : .secondaryLabelColor
        statusLabel.toolTip = channel?.detail ?? router?.discoveryNotice
    }
    @objc private func connect() {
        guard let selected, connectButton.isEnabled else { return }
        router?.connectReceiver(selected, code: codeField.stringValue)
        if let channel = router?.receiverChannel(selected), channel.isConnecting || channel.status.connected { clearCode() }
        render(receiverID: selected)
    }
    @objc private func disconnect() {
        guard let selected else { return }
        router?.disconnectReceiver(selected); render(receiverID: selected)
    }
}
