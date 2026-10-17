import AppKit
import Combine

@MainActor
final class OutputSRTDestinationSettings: NSViewController, NSTextFieldDelegate {
    private let coordinator: OutputCoordinator
    private let destinationID: UUID
    private let source = NSPopUpButton()
    private let receiver = NSPopUpButton()
    private let discoveryStatus = outputSettingsLabel(secondary: true)
    private var receiverIDs: [UUID?] = []
    private var selectedReceiverID: UUID?
    private var selectedReceiverName: String?
    private let host = NSTextField()
    private let port = NSTextField(string: "10000")
    private let passphrase = NSSecureTextField()
    private let frameRate = NSPopUpButton()
    private let latency = NSPopUpButton()
    private let backgroundAudio = NSButton(checkboxWithTitle: "Include background music", target: nil, action: nil)
    private let status = outputSettingsLabel(secondary: true)
    private var subscriptions: Set<AnyCancellable> = []
    private var sourceIDs: [UUID?] = []
    private var keychainTask: Task<Void, Never>?
    private var rendering = false
    private var notice: String?
    init(coordinator: OutputCoordinator, destinationID: UUID) {
        self.coordinator = coordinator; self.destinationID = destinationID
        super.init(nibName: nil, bundle: nil)
        coordinator.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }.store(in: &subscriptions)
        coordinator.mediaOutputs.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.render() }
        }.store(in: &subscriptions)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        source.target = self; source.action = #selector(saveOptions)
        receiver.target = self; receiver.action = #selector(receiverChanged)
        receiver.setAccessibilityLabel("AltView Media receiver")
        backgroundAudio.target = self; backgroundAudio.action = #selector(saveOptions)
        host.placeholderString = "AltView Mac’s local address"; host.setAccessibilityLabel("AltView Media address")
        port.setAccessibilityLabel("AltView Media port")
        passphrase.placeholderString = "Passphrase shown in AltView’s eucaly Media"; passphrase.setAccessibilityLabel("AltView Media passphrase")
        for field in [host, port, passphrase] { field.delegate = self }
        frameRate.addItems(withTitles: ["50 fps", "60 fps"]); frameRate.target = self; frameRate.action = #selector(saveSettings)
        latency.addItems(withTitles: ["40 ms", "80 ms", "120 ms", "200 ms"]); latency.target = self; latency.action = #selector(saveSettings)
        if let row = coordinator.profiles.document.destinations.first(where: { $0.id == destinationID }) {
            let settings = row.srt ?? SRTMediaSettings()
            host.stringValue = settings.host; port.integerValue = settings.port
            selectedReceiverID = settings.receiverID; selectedReceiverName = settings.receiverName
            frameRate.selectItem(withTitle: "\(settings.frameRate) fps"); latency.selectItem(withTitle: "\(settings.latency) ms")
        }
        let retry = NSButton(title: "Retry Media", target: self, action: #selector(retryMedia))
        let stack = NSStackView(views: [
            outputSettingsLabel("Sends the existing Audience picture, including images and live video with its audio to AltView on the local network. Ethernet is recommended; Wi-Fi can be tested with a 120–200 ms recovery buffer. Your in-house display keeps its resolution. Audience must be open; this output allocates no extra monitor.", secondary: true),
            outputSettingsRow("Audience output", source), outputSettingsRow("Receiver", receiver), discoveryStatus,
            outputSettingsRow("AltView address", host),
            outputSettingsRow("Port", port), outputSettingsRow("Passphrase", passphrase),
            outputSettingsRow("Video rate", frameRate), outputSettingsRow("Recovery buffer", latency), backgroundAudio, retry, status])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        for row in stack.arrangedSubviews { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        view = stack; render()
        let account = "output-\(destinationID.uuidString)"
        keychainTask = Task { [weak self] in
            do {
                let saved = try await SRTMediaSecrets.shared.read(account)
                guard let self, !Task.isCancelled, self.passphrase.stringValue.isEmpty else { return }
                self.passphrase.stringValue = saved ?? ""
            } catch { self?.notice = error.localizedDescription; self?.render() }
        }
    }
    private var active = false
    func setActive(_ value: Bool) {
        guard active != value else { return }; active = value
        if value { coordinator.mediaOutputs.startDiscovery() } else { coordinator.mediaOutputs.stopDiscovery() }
    }
    private func renderReceivers() {
        let found = coordinator.mediaOutputs.receivers
        receiverIDs = [nil] + found.map { Optional($0.id) }
        var titles = ["Manual address"] + found.map { item in
            let duplicate = found.filter { $0.name == item.name }.count > 1
            return duplicate ? "\(item.name) · \(item.id.uuidString.prefix(8))" : item.name
        }
        if let selectedReceiverID, !receiverIDs.contains(selectedReceiverID) {
            receiverIDs.append(selectedReceiverID); titles.append("\(selectedReceiverName ?? "Saved receiver") · offline")
        }
        if receiver.itemTitles != titles { receiver.removeAllItems(); receiver.addItems(withTitles: titles) }
        receiver.selectItem(at: receiverIDs.firstIndex(of: selectedReceiverID) ?? 0)
        if let selectedReceiverID, let current = found.first(where: { $0.id == selectedReceiverID }) {
            host.stringValue = current.host; port.integerValue = current.port
        }
        host.isEnabled = selectedReceiverID == nil; port.isEnabled = selectedReceiverID == nil
        discoveryStatus.stringValue = coordinator.mediaOutputs.discoveryNotice
            ?? (selectedReceiverID != nil && !found.contains { $0.id == selectedReceiverID }
                ? "Start Receiving in AltView on the selected Mac. Its saved identity is retained."
                : "Start Receiving in AltView to find it here. Enter its passphrase below.")
    }
    @objc private func receiverChanged() {
        guard !rendering, receiverIDs.indices.contains(receiver.indexOfSelectedItem) else { return }
        selectedReceiverID = receiverIDs[receiver.indexOfSelectedItem]
        selectedReceiverName = coordinator.mediaOutputs.receivers.first { $0.id == selectedReceiverID }?.name
        if let found = coordinator.mediaOutputs.receivers.first(where: { $0.id == selectedReceiverID }) {
            host.stringValue = found.host; port.integerValue = found.port
        }
        saveSettings(); render()
    }
    func render() {
        guard isViewLoaded, let row = coordinator.profiles.document.destinations.first(where: { $0.id == destinationID }) else { return }
        rendering = true; defer { rendering = false }
        renderReceivers()
        let rows = coordinator.profiles.document.destinations.filter { coordinator.profiles.profile($0.profileID)?.kind == .audience }
        let ids: [UUID?] = [nil] + rows.map { Optional($0.id) }
        if ids != sourceIDs || source.itemTitles != ["None"] + rows.map(\.name) {
            sourceIDs = ids; source.removeAllItems(); source.addItems(withTitles: ["None"] + rows.map(\.name))
        }
        source.selectItem(at: sourceIDs.firstIndex(of: row.sourceAudienceID) ?? 0)
        backgroundAudio.state = row.includeBackgroundAudio ? .on : .off
        status.stringValue = notice ?? (row.enabled ? coordinator.mediaOutputs.detail(for: destinationID) : "Disabled. Save the address and passphrase, enable this output, then Show Slides.")
    }
    @objc private func saveOptions() {
        guard !rendering else { return }
        let selected = source.indexOfSelectedItem
        let sourceID = sourceIDs.indices.contains(selected) ? sourceIDs[selected] : nil
        let includesMusic = backgroundAudio.state == .on
        coordinator.profiles.edit { document in
            guard let i = document.destinations.firstIndex(where: { $0.id == destinationID }) else { return }
            document.destinations[i].sourceAudienceID = sourceID
            document.destinations[i].includeBackgroundAudio = includesMusic
        }
    }
    func controlTextDidEndEditing(_ obj: Notification) { saveSettings() }
    @objc private func saveSettings() {
        guard !rendering else { return }
        var settings = SRTMediaSettings(); settings.host = host.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.receiverID = selectedReceiverID; settings.receiverName = selectedReceiverName
        settings.port = port.integerValue
        settings.frameRate = Int(frameRate.titleOfSelectedItem?.split(separator: " ").first ?? "60") ?? 60
        settings.latency = Int(latency.titleOfSelectedItem?.split(separator: " ").first ?? "80") ?? 80
        guard settings.isValid else { notice = "Enter a local hostname or IPv4 address and a port from 1 to 65535."; render(); return }
        let selected = source.indexOfSelectedItem
        let sourceID = sourceIDs.indices.contains(selected) ? sourceIDs[selected] : nil
        let key = passphrase.stringValue
        guard SRTMediaSettings.validPassphrase(key) else { notice = "Enter AltView’s passphrase: 10–79 letters, numbers, - or _."; render(); return }
        notice = "Saving passphrase…"; render()
        keychainTask?.cancel()
        let account = "output-\(destinationID.uuidString)"
        keychainTask = Task { [weak self] in
            do {
                try await SRTMediaSecrets.shared.save(key, account: account)
                guard let self, !Task.isCancelled else { return }
                self.coordinator.profiles.edit { document in
                    guard let i = document.destinations.firstIndex(where: { $0.id == self.destinationID }) else { return }
                    document.destinations[i].destination = .srt(settings)
                    document.destinations[i].sourceAudienceID = sourceID
                }
                self.notice = nil; self.render()
            } catch { self?.notice = error.localizedDescription; self?.render() }
        }
    }
    @objc private func retryMedia() { coordinator.mediaOutputs.retry(destinationID); render() }
}
