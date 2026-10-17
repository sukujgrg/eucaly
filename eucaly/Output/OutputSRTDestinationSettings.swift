import AppKit
import Combine

@MainActor
final class OutputSRTDestinationSettings: NSViewController {
    private let coordinator: OutputCoordinator
    private let destinationID: UUID
    private let source = NSPopUpButton()
    private let receiver = NSPopUpButton()
    private let frameRate = NSPopUpButton()
    private let latency = NSPopUpButton()
    private let backgroundAudio = NSButton(checkboxWithTitle: "Include background music", target: nil, action: nil)
    private let status = outputSettingsLabel(secondary: true)
    private let retry = NSButton(title: "Retry Media", target: nil, action: nil)
    private lazy var pairing = AltViewReceiverPairingView(router: router)
    private var isActive = true
    private var targets: [OutputReceiverTarget] = []
    private var sourceIDs: [UUID?] = []
    private var subscriptions = Set<AnyCancellable>()
    private var rendering = false
    private var notice: String?
    private var router: AltViewOutputRouter? { coordinator.remoteOutputs as? AltViewOutputRouter }
    init(coordinator: OutputCoordinator, destinationID: UUID) {
        self.coordinator = coordinator; self.destinationID = destinationID
        super.init(nibName: nil, bundle: nil)
        var publishers = [coordinator.objectWillChange, coordinator.mediaOutputs.objectWillChange]
        if let router { publishers.append(router.objectWillChange) }
        for publisher in publishers {
            publisher.sink { [weak self] _ in DispatchQueue.main.async { self?.render() } }.store(in: &subscriptions)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        for picker in [source, receiver, frameRate, latency] { picker.target = self; picker.action = #selector(saveOptions) }
        receiver.setAccessibilityLabel("AltView Media receiver")
        frameRate.addItems(withTitles: ["50 fps", "60 fps"])
        latency.addItems(withTitles: ["20 ms · Wired LAN", "40 ms", "80 ms", "120 ms", "200 ms"])
        backgroundAudio.target = self; backgroundAudio.action = #selector(saveOptions)
        retry.target = self; retry.action = #selector(retryMedia)
        let stack = NSStackView(views: [
            outputSettingsRow("Audience output", source), outputSettingsRow("Receiver", receiver), pairing,
            outputSettingsRow("Maximum video rate", frameRate), outputSettingsRow("Recovery buffer", latency),
            outputSettingsRow("", backgroundAudio), outputSettingsActionRow([retry]), status,
            outputSettingsLabel("Sends the selected Audience picture and audio. Video follows Audience motion up to the maximum rate. Start Receiving in AltView, then Show Slides here. Lyrics can remain disabled.", secondary: true)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        for row in stack.arrangedSubviews { row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        view = stack; render()
    }
    func setActive(_ value: Bool) {
        isActive = value
        if value { render() } else { pairing.clearCode() }
    }
    func render() {
        guard isActive, isViewLoaded, let row = coordinator.profiles.document.destinations.first(where: { $0.id == destinationID }) else { return }
        rendering = true; defer { rendering = false }
        targets = router?.knownReceivers ?? []
        if let settings = row.srt, let id = settings.receiverID, !targets.contains(where: { $0.receiverID == id }) {
            targets.append(.init(receiverID: id, name: (settings.receiverName ?? "Previous media receiver") + " · unavailable"))
        }
        let titles = ["None"] + altViewReceiverTitles(targets)
        if receiver.itemTitles != titles { receiver.removeAllItems(); receiver.addItems(withTitles: titles) }
        receiver.selectItem(at: targets.firstIndex { $0.receiverID == row.srt?.receiverID }.map { $0 + 1 } ?? 0)
        pairing.render(receiverID: row.srt?.receiverID)
        let rows = coordinator.profiles.document.destinations.filter { coordinator.profiles.profile($0.profileID)?.kind == .audience }
        sourceIDs = [nil] + rows.map { Optional($0.id) }
        let names = ["None"] + rows.map(\.name)
        if source.itemTitles != names { source.removeAllItems(); source.addItems(withTitles: names) }
        source.selectItem(at: sourceIDs.firstIndex(of: row.sourceAudienceID) ?? 0)
        let settings = row.srt ?? SRTMediaSettings()
        frameRate.selectItem(withTitle: "\(settings.frameRate) fps")
        if settings.latency == 20 { latency.selectItem(at: 0) } else { latency.selectItem(withTitle: "\(settings.latency) ms") }
        backgroundAudio.state = row.includeBackgroundAudio ? .on : .off
        retry.isEnabled = row.enabled && coordinator.isPresenting
        let available = router?.receivers.contains { $0.receiverIdentity == row.srt?.receiverID } == true
        status.stringValue = notice ?? (!available && row.srt != nil
            ? "Receiver unavailable. Open AltView and resume Connections, or choose another receiver above."
            : coordinator.mediaOutputs.detail(for: destinationID))
    }
    @objc private func saveOptions() {
        guard !rendering else { return }
        let index = receiver.indexOfSelectedItem - 1
        let target = targets.indices.contains(index) ? targets[index] : nil
        let sourceID = sourceIDs.indices.contains(source.indexOfSelectedItem) ? sourceIDs[source.indexOfSelectedItem] : nil
        var settings = SRTMediaSettings(); settings.host = "paired.receiver"
        settings.receiverID = target?.receiverID; settings.receiverName = target?.name
        settings.frameRate = Int(frameRate.titleOfSelectedItem?.split(separator: " ").first ?? "60") ?? 60
        settings.latency = Int(latency.titleOfSelectedItem?.split(separator: " ").first ?? "80") ?? 80
        guard var proposed = coordinator.profiles.document.destinations.first(where: { $0.id == destinationID }) else { return }
        proposed.destination = target == nil ? .none : .srt(settings); proposed.sourceAudienceID = sourceID
        if let problem = coordinator.profiles.assignmentProblem(for: proposed) { notice = problem; render(); return }
        notice = nil
        coordinator.profiles.edit { document in
            guard let i = document.destinations.firstIndex(where: { $0.id == destinationID }) else { return }
            document.destinations[i].destination = target == nil ? .none : .srt(settings)
            document.destinations[i].sourceAudienceID = sourceID
            document.destinations[i].includeBackgroundAudio = backgroundAudio.state == .on
        }
    }
    @objc private func retryMedia() { coordinator.mediaOutputs.retry(destinationID); render() }
}
