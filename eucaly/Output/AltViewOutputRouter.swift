import Foundation
import AppKit
import Combine

@MainActor
protocol OutputRemoteRouting: AnyObject {
    var isRunning: Bool { get }
    func canPresent(_ destination: OutputDestinationConfiguration) -> Bool
    func readiness(for id: UUID) -> OutputReadiness
    func publish(_ snapshot: OutputContentSnapshot, explicit: Bool)
    func stop()
}

/// One independent sender/lease per configured receiver. The coordinator owns
/// program state; channels own transport and never write local Current/Preview.
@MainActor
final class AltViewOutputRouter: ObservableObject, OutputRemoteRouting {
    @Published private(set) var receivers: [AltViewDestination] = []
    @Published private(set) var discoveryNotice: String?
    @Published private(set) var statusRevision: UInt64 = 0
    private let store: OutputProfileStore
    private let senderID: UUID
    private let defaults: UserDefaults
    private let pairingStore: any AltViewPairingStoring
    private let channelFactory: (() -> AltViewService)?
    private var discoveryVisible = false
    private var discoveryEnabled = true
    private var discoveryRunning = false
    private var observation: UUID?
    // One control channel per receiver, shared by independently enabled outputs.
    private var channels: [UUID: AltViewService] = [:]
    private var paired: [OutputReceiverTarget] = []
    private var setupTargets: [UUID: OutputReceiverTarget] = [:]
    private var publishingReceivers: Set<UUID> = []
    var knownReceivers: [OutputReceiverTarget] {
        var targets = Dictionary(paired.map { ($0.receiverID, $0) }, uniquingKeysWith: { first, _ in first })
        for target in store.document.destinations.compactMap({ row in
            row.receiver ?? row.srt.flatMap { settings in settings.receiverID.map { OutputReceiverTarget(receiverID: $0, name: settings.receiverName ?? "AltView") } }
        }) { targets[target.receiverID] = target }
        for receiver in receivers {
            if let id = receiver.receiverIdentity { targets[id] = .init(receiverID: id, name: receiver.name) }
        }
        return targets.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func receiverChannel(_ id: UUID) -> AltViewService? { channels[id] }
    private weak var coordinator: OutputCoordinator?
    private var sourceID: UUID?
    private var confidence: AltViewConfidenceText?
    private var projection: AltViewProjectionPresentation?
    private var lastContent: AltViewDisplayContent?
    private lazy var discovery = AltViewReceiverDiscovery(excludingReceiverID: senderID) { [weak self] receivers, notice in
        MainActor.assumeIsolated {
            self?.receiveDiscovered(receivers.compactMap(AltViewDestination.init), notice: notice)
        }
    }
    init(store: OutputProfileStore, senderID: UUID? = nil, defaults: UserDefaults = .standard,
         pairingStore: any AltViewPairingStoring = AltViewPairingStore(), channelFactory: (() -> AltViewService)? = nil) {
        self.store = store; self.defaults = defaults
        if let senderID { self.senderID = senderID }
        else {
            // Retain the outgoing identity without retaining a receiver.
            self.senderID = ["altViewSenderID", "hubReceiverID"].compactMap { defaults.string(forKey: $0).flatMap(UUID.init(uuidString:)) }.first ?? UUID()
            defaults.set(self.senderID.uuidString, forKey: "altViewSenderID")
            defaults.removeObject(forKey: "hubReceiverID")
        }
        self.pairingStore = pairingStore; self.channelFactory = channelFactory
        if let data = defaults.data(forKey: "altViewPairedReceiversV3"),
           let targets = try? JSONDecoder().decode([OutputReceiverTarget].self, from: data) {
            paired = Array(targets.prefix(16))
        }
    }
    func start(coordinator: OutputCoordinator, discover: Bool = true) {
        guard observation == nil else { return }
        self.coordinator = coordinator
        coordinator.remoteOutputs = self
        observation = store.observe { [weak self] in self?.synchronize() }
        discoveryEnabled = discover
        refreshDiscovery()
        synchronize()
    }
    func receiveDiscovered(_ receivers: [AltViewDestination], notice: String?) {
        var identities: [UUID: AltViewDestination] = [:]
        for receiver in receivers where receiver.isValid {
            guard let id = receiver.receiverIdentity, id != senderID else { continue }
            if identities[id] == nil || receiver.localReceiverID != nil { identities[id] = receiver }
        }
        self.receivers = identities.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        discoveryNotice = notice
        for channel in channels.values { channel.receiveDiscovered(self.receivers, notice: notice) }
        synchronize()
    }
    private var configurations: [OutputDestinationConfiguration] {
        store.document.destinations.filter {
            $0.enabled && $0.receiver != nil && store.profile($0.profileID)?.kind == .altView
                && !store.conflictingReceiverIDs.contains($0.id) && $0.receiver?.receiverID != senderID
        }
    }
    func startDiscovery() { discoveryVisible = true; refreshDiscovery() }
    func stopDiscovery() { discoveryVisible = false; refreshDiscovery() }
    private func refreshDiscovery() {
        let needed = discoveryEnabled && (discoveryVisible || !channels.isEmpty || !paired.isEmpty || store.document.destinations.contains { $0.receiver != nil || $0.srt?.receiverID != nil })
        guard needed != discoveryRunning else { return }
        discoveryRunning = needed
        if needed { discovery.start() } else { discovery.stop() }
    }
    private func synchronize() {
        var targets = Dictionary(paired.map { ($0.receiverID, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, target) in setupTargets { targets[id] = target }
        for row in store.document.destinations {
            if let target = row.receiver { targets[target.receiverID] = target }
            if let settings = row.srt, let id = settings.receiverID {
                targets[id] = .init(receiverID: id, name: settings.receiverName ?? "AltView")
            }
        }
        let active = Set(configurations.compactMap { $0.receiver?.receiverID })
        for id in publishingReceivers.subtracting(active) { channels[id]?.stopSending() }
        publishingReceivers = active
        for id in Array(channels.keys) where targets[id] == nil {
            channels.removeValue(forKey: id)?.disconnect()
        }
        for (id, target) in targets where id != senderID && channels[id] == nil {
            var waiting = AltViewDestination(name: target.name, host: nil, port: nil,
                serviceType: AltViewProtocol.serviceType, domain: "local.")
            waiting.discoveredReceiverID = id
            let endpoint = receivers.first(where: { $0.receiverIdentity == id }) ?? waiting
            let channel = channelFactory?() ?? AltViewService(defaults: defaults, senderIdentity: senderID, pairingStore: pairingStore)
            channel.onStatusChange = { [weak self] in self?.statusChanged() }
            channels[id] = channel
            channel.receiveDiscovered(receivers, notice: discoveryNotice)
            channel.connect(to: endpoint, code: "")
        }
        refreshDiscovery(); statusChanged()
    }
    func channel(for rowID: UUID) -> AltViewService? {
        guard let row = store.document.destinations.first(where: { $0.id == rowID }),
              let id = row.receiver?.receiverID ?? row.srt?.receiverID else { return nil }
        return channels[id]
    }
    func connectReceiver(_ id: UUID, code: String) {
        guard let endpoint = receivers.first(where: { $0.receiverIdentity == id }) else { return }
        setupTargets[id] = .init(receiverID: id, name: endpoint.name)
        synchronize()
        coordinator?.mediaOutputs.stopReceiver(id)
        channels[id]?.connect(to: endpoint, code: code)
        statusChanged()
    }
    func connect(_ rowID: UUID, code: String) {
        guard let id = store.document.destinations.first(where: { $0.id == rowID })?.receiver?.receiverID else { return }
        connectReceiver(id, code: code)
    }
    func disconnectReceiver(_ id: UUID) { channels[id]?.disconnect(); statusChanged() }
    func disconnect(_ rowID: UUID) {
        guard let id = store.document.destinations.first(where: { $0.id == rowID })?.receiver?.receiverID else { return }
        disconnectReceiver(id)
    }
    var isRunning: Bool { channels.values.contains { $0.isSending && $0.hasConnection } }
    func canPresent(_ destination: OutputDestinationConfiguration) -> Bool {
        configurations.contains { $0.id == destination.id } && channel(for: destination.id)?.hasConnection == true
    }
    func readiness(for id: UUID) -> OutputReadiness {
        guard let channel = channel(for: id) else { return .closed }
        guard channel.status.connected else { return channel.hasConnection ? .unavailable : .closed }
        switch channel.status.feedback.output {
        case .ready: return .ready
        case .closed: return .closed
        case .displayMissing: return .displayMissing
        default: return .unavailable
        }
    }
    private func statusChanged() {
        for (id, channel) in channels { coordinator?.mediaOutputs.controlConnectionChanged(id, channel: channel) }
        for (id, channel) in channels where channel.status.connected && !paired.contains(where: { $0.receiverID == id }) {
            paired.append(.init(receiverID: id, name: channel.destination?.name ?? "AltView"))
            defaults.set(try? JSONEncoder().encode(paired), forKey: "altViewPairedReceiversV3")
        }
        statusRevision &+= 1
        coordinator?.remoteReadinessChanged()
    }
    func publish(_ snapshot: OutputContentSnapshot, explicit: Bool) {
        if explicit {
            guard let id = snapshot.source else { return }
            sourceID = id
        }
        guard let sourceID else { return }
        var content = OutputAltViewAdapter.content(snapshot)
        if explicit || snapshot.kind == .empty {
            confidence = content.confidence ?? .init(title: content.title, body: content.body, footer: content.footer)
        }
        if let slide = snapshot.localMedia {
            if explicit { projection = .init(sessionID: sourceID, mode: AltViewPresentationAdapter.mode(for: slide)) }
            let identity = coordinator?.audienceIdentity
            projection?.windowID = identity?.0; projection?.windowGeneration = identity?.1
        } else if explicit || snapshot.kind == .empty { projection = nil }
        content.projection = projection
        content.confidence = confidence?.hasText == true ? confidence : nil
        // Private passive refresh retains the published template and Confidence.
        if !explicit, !content.body.isEmpty { content.template = lastContent?.template }
        lastContent = content
        for row in configurations {
            if !explicit && (!snapshot.visible || snapshot.kind == .empty) { channel(for: row.id)?.cancelPendingPresentation() }
            channel(for: row.id)?.publishProgram(content, sourceID: sourceID, explicit: explicit)
        }
    }
    func stop() {
        sourceID = nil; confidence = nil; projection = nil; lastContent = nil
        for channel in channels.values { channel.stopSending() }
        statusChanged()
    }
    func shutdown() {
        stop(); discoveryEnabled = false; discoveryVisible = false; refreshDiscovery()
        for channel in channels.values { channel.disconnect() }
        channels.removeAll()
        if let observation { store.removeObserver(observation) }
        observation = nil
    }
}

nonisolated enum OutputAltViewAdapter {
    static func content(_ snapshot: OutputContentSnapshot) -> AltViewDisplayContent {
        let body = snapshot.current.components.filter { $0.role == .primary }.map(\.text).joined(separator: "\n\n")
        return .init(body: body, visible: snapshot.visible && !body.isEmpty, template: body.isEmpty ? nil : .lyrics)
    }
}
