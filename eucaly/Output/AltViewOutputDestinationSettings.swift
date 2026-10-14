import AppKit
import Combine

/// Connection setup belongs to a destination, not to the Settings selection.
/// Leaving this editor never disconnects its router-owned channel.
@MainActor
final class AltViewOutputDestinationSettings: NSViewController, NSTextFieldDelegate {
    let router: AltViewOutputRouter
    let store: OutputProfileStore
    let destinationID: UUID
    let receiverPicker = NSPopUpButton()
    let codeField = NSSecureTextField()
    let connectButton = NSButton(title: "Connect Only", target: nil, action: nil)
    let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)
    let statusLabel = outputSettingsLabel(secondary: true)
    private let discoveryLabel = outputSettingsLabel(secondary: true)
    private struct ReceiverEntry: Equatable { let id: UUID?; let title: String; let enabled: Bool }
    private var entries: [ReceiverEntry] = []
    private var receiverID: UUID?
    private var wasConnected = false
    private enum AssignmentIssue {
        case unavailable(UUID), rejected(String)
        var message: String {
            switch self {
            case .unavailable: return "This receiver is no longer available. Choose it again when it reconnects, or choose another receiver."
            case .rejected(let message): return message
            }
        }
    }
    private var assignmentIssue: AssignmentIssue?
    private weak var observedChannel: AltViewService?
    private var channelSubscription: AnyCancellable?
    private var subscriptions = Set<AnyCancellable>()
    private var reloadTask: Task<Void, Never>?
    private var isActive = true

    init(router: AltViewOutputRouter, store: OutputProfileStore, destinationID: UUID) {
        self.router = router; self.store = store; self.destinationID = destinationID
        receiverID = store.document.destinations.first { $0.id == destinationID }?.receiver?.receiverID
        super.init(nibName: nil, bundle: nil)
        for publisher in [router.objectWillChange, store.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleRender() }.store(in: &subscriptions)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { reloadTask?.cancel() }

    override func loadView() {
        receiverPicker.target = self; receiverPicker.action = #selector(receiverChanged(_:))
        receiverPicker.autoenablesItems = false
        receiverPicker.setAccessibilityLabel("AltView receiver")
        codeField.delegate = self
        codeField.placeholderString = "8-character code, or saved pairing"
        codeField.setAccessibilityLabel("Pairing code")
        codeField.target = self; codeField.action = #selector(connect(_:))
        connectButton.target = self; connectButton.action = #selector(connect(_:))
        disconnectButton.target = self; disconnectButton.action = #selector(disconnect(_:))
        statusLabel.isSelectable = true
        statusLabel.setAccessibilityLabel("AltView status")
        discoveryLabel.textColor = .systemOrange
        let stack = NSStackView(views: [
            outputSettingsRow("Receiver", receiverPicker),
            outputSettingsRow("Pairing code", codeField),
            outputSettingsActionRow([connectButton, disconnectButton]), statusLabel, discoveryLabel,
            outputSettingsLabel("The next explicit presentation sends the live program. AltView controls fonts, layout and backgrounds. LAN output carries text; same-Mac Confidence can use the native Audience window when supported.", secondary: true)
        ])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        for row in stack.arrangedSubviews { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        view = stack
        render()
    }
    private func scheduleRender() {
        guard isActive, reloadTask == nil else { return }
        reloadTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.reloadTask = nil; self.render()
        }
    }
    /// A cached hidden form retains its draft, while the router alone maintains
    /// its connection. Resume from the latest model when the row is selected.
    func setActive(_ value: Bool) {
        guard isActive != value else { return }
        isActive = value
        if value { render() }
        else { reloadTask?.cancel(); reloadTask = nil }
    }
    func render() {
        guard isActive, isViewLoaded, let destination = store.document.destinations.first(where: { $0.id == destinationID }) else { return }
        if case .unavailable(let id) = assignmentIssue, router.receivers.contains(where: { $0.receiverIdentity == id }) {
            assignmentIssue = nil
        }
        if receiverID != destination.receiver?.receiverID {
            if receiverID != nil { codeField.stringValue = "" }
            receiverID = destination.receiver?.receiverID
            wasConnected = false
        }
        var fresh = [ReceiverEntry(id: nil, title: "None", enabled: true)]
        fresh += router.receivers.compactMap { receiver in
            guard let id = receiver.receiverIdentity else { return nil }
            let conflict = destination.enabled && store.document.destinations.contains { $0.id != destinationID && $0.enabled && $0.receiver?.receiverID == id }
            return ReceiverEntry(id: id, title: receiver.name, enabled: !conflict)
        }
        if let target = destination.receiver, !fresh.contains(where: { $0.id == target.receiverID }) {
            fresh.append(.init(id: target.receiverID, title: target.name + " · Unavailable", enabled: false))
        }
        if fresh != entries {
            entries = fresh
            let menu = NSMenu(); menu.autoenablesItems = false
            for entry in entries {
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.isEnabled = entry.enabled; item.representedObject = entry.id; menu.addItem(item)
            }
            receiverPicker.menu = menu
        }
        receiverPicker.selectItem(at: entries.firstIndex { $0.id == destination.receiver?.receiverID } ?? 0)
        let channel = router.channel(for: destinationID)
        if observedChannel !== channel {
            observedChannel = channel
            channelSubscription = channel?.objectWillChange.sink { [weak self] _ in self?.scheduleRender() }
        }
        let connected = channel?.status.connected == true
        if connected && !wasConnected { codeField.stringValue = "" }
        wasConnected = connected
        let conflict = destination.receiver.flatMap { target in
            store.document.destinations.first { $0.id != destinationID && $0.enabled && $0.receiver?.receiverID == target.receiverID }
        }
        if let assignmentIssue { statusLabel.stringValue = assignmentIssue.message }
        else if !destination.enabled { statusLabel.stringValue = "Enable this output to connect." }
        else if destination.receiver == nil {
            statusLabel.stringValue = "Choose a receiver, enter its pairing code, then choose Connect Only. Open AltView and enable receiving if no receivers appear."
        } else if let conflict {
            statusLabel.stringValue = "This receiver is used by \(conflict.name). Disable that output or choose a different receiver."
        } else if let channel { statusLabel.stringValue = channel.detail }
        else { statusLabel.stringValue = "Waiting to discover this receiver. Open AltView and enable receiving." }
        if assignmentIssue != nil || (destination.enabled && conflict != nil) {
            statusLabel.textColor = .systemOrange
        } else if destination.enabled && connected {
            statusLabel.textColor = .systemGreen
        } else {
            statusLabel.textColor = .secondaryLabelColor
        }
        discoveryLabel.stringValue = router.discoveryNotice ?? ""
        discoveryLabel.isHidden = router.discoveryNotice == nil
        let discovered = router.receivers.contains { $0.receiverIdentity == destination.receiver?.receiverID }
        connectButton.isEnabled = destination.enabled && destination.receiver != nil && conflict == nil && discovered
            && channel?.isConnecting != true && (!connected || !codeField.stringValue.isEmpty)
        disconnectButton.isEnabled = channel?.hasConnection == true
        disconnectButton.title = channel?.isConnecting == true ? "Cancel" : "Disconnect"
    }
    func controlTextDidChange(_ notification: Notification) {
        if let channel = router.channel(for: destinationID), channel.hasConnection && !channel.status.connected {
            router.disconnect(destinationID)
        }
        render()
    }
    @objc private func receiverChanged(_ sender: Any?) {
        guard let item = receiverPicker.selectedItem else { return }
        let target: OutputReceiverTarget?
        if item.representedObject == nil {
            target = nil // Only the explicit None item clears an assignment.
        } else {
            guard let id = item.representedObject as? UUID else { return }
            guard let receiver = router.receivers.first(where: { $0.receiverIdentity == id }) else {
                assignmentIssue = .unavailable(id)
                render()
                return
            }
            target = OutputReceiverTarget(receiverID: id, name: receiver.name)
        }
        assignmentIssue = store.assignReceiver(target, to: destinationID).map(AssignmentIssue.rejected)
        render()
    }
    @objc private func connect(_ sender: Any?) {
        render()
        if connectButton.isEnabled { router.connect(destinationID, code: codeField.stringValue); render() }
    }
    @objc private func disconnect(_ sender: Any?) { router.disconnect(destinationID); render() }
}
