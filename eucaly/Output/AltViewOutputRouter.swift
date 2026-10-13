import Foundation
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
    private let receiverID: UUID
    private let defaults: UserDefaults
    private let pairingStore: any AltViewPairingStoring
    private let channelFactory: (() -> AltViewService)?
    private var discoveryVisible = false
    private var discoveryEnabled = true
    private var discoveryRunning = false
    private var observation: UUID?
    private var channels: [UUID: AltViewService] = [:]
    private weak var coordinator: OutputCoordinator?
    private var sourceID: UUID?
    private var localProgram = false
    private var confidence: AltViewConfidenceText?
    private var projection: AltViewProjectionPresentation?
    private var lastContent: AltViewDisplayContent?
    private lazy var discovery = AltViewReceiverDiscovery(excludingReceiverID: receiverID) { [weak self] receivers, notice in
        MainActor.assumeIsolated {
            self?.receiveDiscovered(receivers.compactMap(AltViewDestination.init), notice: notice)
        }
    }
    init(store: OutputProfileStore, receiverID: UUID, defaults: UserDefaults = .standard,
         pairingStore: any AltViewPairingStoring = AltViewPairingStore(), channelFactory: (() -> AltViewService)? = nil) {
        self.store = store; self.receiverID = receiverID; self.defaults = defaults
        self.pairingStore = pairingStore; self.channelFactory = channelFactory
    }
    func start(coordinator: OutputCoordinator, discover: Bool = true) {
        guard observation == nil else { return }
        self.coordinator = coordinator
        coordinator.remoteOutputs = self
        observation = store.observe { [weak self] in self?.synchronize() }
        discoveryEnabled = discover
        refreshDiscovery()
        migrateLegacyConnection()
        synchronize()
    }
    private func migrateLegacyConnection() {
        guard store.document.destinations.count < 16, !store.document.destinations.contains(where: { store.profile($0.profileID)?.kind == .altView }),
              let data = defaults.data(forKey: "altViewDestination"),
              let saved = try? JSONDecoder().decode(AltViewDestination.self, from: data), saved.isValid else { return }
        pairingStore.read(saved) { [weak self] credentials, _ in
            MainActor.assumeIsolated {
                guard let self, let credentials, !self.store.document.destinations.contains(where: { self.store.profile($0.profileID)?.kind == .altView }) else { return }
                var stable = saved; stable.discoveredReceiverID = credentials.receiverID
                self.pairingStore.save(credentials, for: stable) { _ in }
                self.store.edit { doc in
                    var row = OutputDestinationConfiguration(name: "AltView", profileID: OutputProfile.altViewID, monitor: nil)
                    row.savedReceiver = .init(receiverID: credentials.receiverID, name: saved.name)
                    row.destination = .altView(row.savedReceiver!)
                    doc.destinations.append(row)
                }
            }
        }
    }
    func receiveDiscovered(_ receivers: [AltViewDestination], notice: String?) {
        var identities: [UUID: AltViewDestination] = [:]
        for receiver in receivers where receiver.isValid {
            guard let id = receiver.receiverIdentity, id != receiverID else { continue }
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
                && !store.conflictingReceiverIDs.contains($0.id) && $0.receiver?.receiverID != receiverID
        }
    }
    func startDiscovery() { discoveryVisible = true; refreshDiscovery() }
    func stopDiscovery() { discoveryVisible = false; refreshDiscovery() }
    private func refreshDiscovery() {
        let needed = discoveryEnabled && (discoveryVisible || store.document.destinations.contains { $0.enabled && $0.receiver != nil })
        guard needed != discoveryRunning else { return }
        discoveryRunning = needed
        if needed { discovery.start() } else { discovery.stop() }
    }
    private func synchronize() {
        refreshDiscovery()
        let rows = configurations
        let valid = Set(rows.map(\.id))
        for id in Array(channels.keys) where !valid.contains(id) {
            channels.removeValue(forKey: id)?.disconnect()
        }
        for row in rows {
            guard let target = row.receiver else { continue }
            if let old = channels[row.id], old.destination?.receiverIdentity != target.receiverID {
                old.disconnect(); channels.removeValue(forKey: row.id)
            }
            guard channels[row.id] == nil else { continue }
            // A stable identity can wait for discovery without dialing a stale
            // service name/port. Saved Keychain pairing and explicit actions are
            // retained independently of live Bonjour availability.
            var waiting = AltViewDestination(name: target.name, host: nil, port: nil,
                serviceType: AltViewProtocol.serviceType, domain: "local.")
            waiting.discoveredReceiverID = target.receiverID
            let endpoint = receivers.first(where: { $0.receiverIdentity == target.receiverID }) ?? waiting
            let channel = channelFactory?() ?? AltViewService(defaults: defaults,
                senderIdentity: receiverID, pairingStore: pairingStore)
            channel.onStatusChange = { [weak self] in self?.statusChanged() }
            channels[row.id] = channel
            channel.receiveDiscovered(receivers, notice: discoveryNotice)
            channel.connect(to: endpoint, code: "") // Connect-only restoration.
        }
        statusChanged()
    }
    func channel(for id: UUID) -> AltViewService? { channels[id] }
    func connect(_ id: UUID, code: String) {
        guard let row = configurations.first(where: { $0.id == id }), let target = row.receiver,
              let endpoint = receivers.first(where: { $0.receiverIdentity == target.receiverID }) else { return }
        if channels[id] == nil { synchronize() }
        channels[id]?.connect(to: endpoint, code: code)
        statusChanged()
    }
    func disconnect(_ id: UUID) { channels[id]?.disconnect(); statusChanged() }
    var isRunning: Bool { channels.values.contains { $0.isSending && $0.hasConnection } }
    func canPresent(_ destination: OutputDestinationConfiguration) -> Bool {
        configurations.contains { $0.id == destination.id } && channels[destination.id]?.hasConnection == true
    }
    func readiness(for id: UUID) -> OutputReadiness {
        guard let channel = channels[id] else { return .closed }
        guard channel.status.connected else { return channel.hasConnection ? .unavailable : .closed }
        switch channel.status.feedback.output {
        case .ready: return .ready
        case .closed: return .closed
        case .displayMissing: return .displayMissing
        default: return .unavailable
        }
    }
    private func statusChanged() {
        statusRevision &+= 1
        coordinator?.remoteReadinessChanged()
    }
    func publish(_ snapshot: OutputContentSnapshot, explicit: Bool) {
        if explicit {
            switch snapshot.source {
            case .local(let id): sourceID = id; localProgram = true
            case .external(_, let id): sourceID = id; localProgram = false
            case nil: return
            }
        }
        guard let sourceID else { return }
        var content = OutputAltViewAdapter.content(snapshot)
        if explicit || snapshot.kind == .empty || snapshot.remoteContent != nil {
            confidence = content.confidence ?? .init(title: content.title, body: content.body, footer: content.footer)
        }
        if localProgram, let slide = snapshot.localMedia {
            if explicit { projection = .init(sessionID: sourceID, mode: AltViewPresentationAdapter.mode(for: slide)) }
            let identity = coordinator?.audienceIdentity
            projection?.windowID = identity?.0; projection?.windowGeneration = identity?.1
        } else if explicit || snapshot.kind == .empty || snapshot.remoteContent != nil { projection = nil }
        content.projection = projection
        content.confidence = confidence?.hasText == true ? confidence : nil
        // Private passive refresh retains the published template and Confidence.
        if !explicit, !content.body.isEmpty { content.template = lastContent?.template }
        lastContent = content
        for row in configurations {
            if !explicit && (!snapshot.visible || snapshot.kind == .empty) { channels[row.id]?.cancelPendingPresentation() }
            channels[row.id]?.publishProgram(content, sourceID: sourceID, explicit: explicit)
        }
    }
    func stop() {
        sourceID = nil; localProgram = false; confidence = nil; projection = nil; lastContent = nil
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
        if var received = snapshot.remoteContent {
            received.visible = snapshot.visible
            received.projection = nil // Never relay a different process's capture identity.
            return received
        }
        let current = snapshot.current
        func text(_ roles: Set<OutputComponentRole>) -> String {
            current.components.filter { roles.contains($0.role) }.map(\.text).joined(separator: "\n\n")
        }
        let body = text([.primary])
        let title = current.kind == .lyrics ? "" : text([.heading, .reference])
        let footer = current.kind == .lyrics ? "" : text([.footer])
        return .init(title: title, body: body, footer: footer, visible: snapshot.visible && !body.isEmpty,
                     template: body.isEmpty ? nil : current.kind == .scripture ? .scripture : current.kind == .lyrics ? .lyrics : nil,
                     sourceKind: body.isEmpty ? nil : current.kind == .scripture ? .scripture : current.kind == .lyrics ? .lyrics : .text)
    }
    static func text(_ content: AltViewDisplayContent) -> OutputTextContent {
        var components: [OutputTextComponent] = []
        if !content.title.isEmpty { components.append(.init(role: .reference, text: content.title)) }
        if !content.body.isEmpty { components.append(.init(role: .primary, text: content.body)) }
        if !content.footer.isEmpty { components.append(.init(role: .footer, text: content.footer)) }
        if let secondary = content.confidence?.secondary, !secondary.body.isEmpty {
            components.append(.init(role: .secondary, text: secondary.body))
            if !secondary.footer.isEmpty { components.append(.init(role: .footer, text: secondary.footer)) }
        }
        let kind: OutputTextContent.Kind
        switch content.sourceKind {
        case .scripture: kind = .scripture
        case .lyrics: kind = .lyrics
        case .text: kind = .text
        case nil: kind = content.template == .scripture ? .scripture : content.template == .lyrics ? .lyrics : .text
        }
        return .init(kind: kind, components: components)
    }
}
