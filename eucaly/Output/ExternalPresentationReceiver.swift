import Foundation
import Combine

/// App-owned v2 receiver. Pairing never publishes. Explicit validated input
/// enters the same coordinator ownership boundary as local presentation.
@MainActor
final class ExternalPresentationReceiver: ObservableObject {
    let coordinator: OutputCoordinator
    let receiverID: UUID
    private let replySink: (@MainActor (AltViewWireMessage, UUID) -> Void)?
    private let advertise: Bool
    private let credentialStore: HubReceiverCredentialStore
    private var server: HubReceiverServer?
    private var startTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var retryAttempt = 0
    private var generation = UUID()
    private struct Sender { var id: UUID; var name: String; var capabilities: Set<String> }
    private var senders: [UUID: Sender] = [:]
    private var owner: UUID?
    private(set) var wireLease: UUID?
    private var hubLease: OutputLease?
    private var revision: UInt64 = 0
    private var pendingIntent: UUID?
    private var rejectedIntents: [UUID: UUID] = [:]
    private var lastProgramRevision: UInt64 = 0
    private var pendingIsExplicit = false
    private var pendingOrder: UInt64?
    private var formerOwner: (UUID, UInt64)?
    @Published private(set) var port: UInt16?
    @Published private(set) var issue: String?
    @Published private(set) var pairingCode: String?
    struct ConnectedSender: Identifiable { let id: UUID; let name: String }
    @Published private(set) var connectedSenders: [ConnectedSender] = []
    private func updateConnectedSenders() {
        connectedSenders = senders.map { ConnectedSender(id: $0.key, name: $0.value.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    var enabled: Bool { coordinator.profiles.document.receiverEnabled }
    init(coordinator: OutputCoordinator, receiverID: UUID = UUID(), credentialStore: HubReceiverCredentialStore = HubReceiverCredentialStore(), advertise: Bool = true, replySink: (@MainActor (AltViewWireMessage, UUID) -> Void)? = nil) {
        self.coordinator = coordinator; self.receiverID = receiverID; self.credentialStore = credentialStore; self.advertise = advertise; self.replySink = replySink
        lastProgramRevision = coordinator.revision
        coordinator.onReadinessChange = { [weak self] in self?.reportProgramState() }
    }
    func setEnabled(_ enabled: Bool) {
        coordinator.profiles.edit { $0.receiverEnabled = enabled }
        if enabled { startIfEnabled() } else { stop() }
    }
    func startIfEnabled() {
        guard enabled, server == nil, startTask == nil else { return }
        generation = UUID(); let generation = generation, store = credentialStore
        startTask = Task { [weak self] in
            do {
                let key = try await store.loadOrCreate()
                guard !Task.isCancelled, let self, self.generation == generation, self.enabled else { return }
                self.pairingCode = AltViewPairingKey.text(key)
                var name = "eucaly · \(Host.current().localizedName ?? "Presentation Mac")"
                while name.utf8.count > 128 { name.removeLast() }
                let server = HubReceiverServer(receiverID: self.receiverID, key: key, name: name,
                    actionClock: self.coordinator.actionClock, advertise: self.advertise, intent: { [weak self] event in
                        guard self?.generation == generation else { return }; self?.handle(event)
                    }, disconnected: { [weak self] id in
                        guard self?.generation == generation else { return }; self?.disconnected(id)
                    }, status: { [weak self] port, issue, retry in
                        guard let self, self.generation == generation else { return }
                        self.port = port; self.issue = issue
                        if port != nil { self.retryAttempt = 0 }
                        else if retry { self.scheduleRetry(generation: generation) }
                    })
                self.server = server; self.startTask = nil
                self.coordinator.onReadinessChange = { [weak self] in self?.reportProgramState() }
                server.start()
            } catch {
                guard let self, self.generation == generation else { return }
                self.issue = "Receiver pairing could not be loaded from Keychain. \(error.localizedDescription)"
                self.startTask = nil
            }
        }
    }
    private func scheduleRetry(generation: UUID) {
        guard retryTask == nil else { return }
        let delay = min(8, pow(2, Double(min(retryAttempt, 3)))); retryAttempt += 1
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, self.generation == generation, self.enabled else { return }
            self.server?.stop(); self.server = nil; self.retryTask = nil; self.startIfEnabled()
        }
    }
    func stop() {
        generation = UUID(); startTask?.cancel(); startTask = nil; retryTask?.cancel(); retryTask = nil
        server?.stop(); server = nil; port = nil; pairingCode = nil
        for id in senders.keys { coordinator.externalDisconnected(id) }
        senders.removeAll(); connectedSenders = []; owner = nil; wireLease = nil; hubLease = nil; pendingOrder = nil; formerOwner = nil
        coordinator.onReadinessChange = nil
    }
    func handle(_ event: HubReceiverEnvelope) {
        let id = event.connection, message = event.message
        switch message.kind {
        case .hello:
            guard let senderID = message.senderID, senderID != receiverID, let name = message.name else { return }
            senders[id] = .init(id: senderID, name: name, capabilities: Set(message.capabilities ?? []))
            updateConnectedSenders()
            send(.init(kind: .welcome, receiverID: receiverID, outputReadiness: outputReadiness,
                templates: templates, templatePolicy: .sender,
                capabilities: [AltViewProtocol.confidenceText, AltViewProtocol.presentationIntent, AltViewProtocol.textSource]), to: id)
            sendOwnership(to: id)
        case .take, .resume:
            guard let sender = senders[id] else { return }
            if let intent = message.presentationIntent, rejectedIntents[sender.id] == intent {
                sendFeedback(to: id); sendOwnership(to: id); return
            }
            let order: UInt64
            if message.kind == .resume {
                guard coordinator.ownership.source == nil, owner == nil,
                      let formerOwner, formerOwner.0 == sender.id, formerOwner.1 == coordinator.actionClock.current else { sendOwnership(to: id); return }
                order = formerOwner.1
            } else {
                guard let ingress = event.ingressOrder, ingress == coordinator.actionClock.current else {
                    rejectIntent(for: id, intent: message.presentationIntent)
                    sendFeedback(to: id); sendOwnership(to: id); return
                }
                order = ingress
            }
            owner = id; wireLease = UUID(); revision = 0; hubLease = nil; pendingIntent = message.presentationIntent; pendingOrder = order; pendingIsExplicit = message.kind == .take; formerOwner = nil
            send(.init(kind: .granted, lease: wireLease, ownerID: sender.id, ownerName: sender.name), to: id)
            for connection in senders.keys { sendOwnership(to: connection) }
        case .state:
            guard owner == id, wireLease == message.lease, let revision = message.revision, revision > self.revision,
                  let content = message.content, content.isValid, let sender = senders[id] else { sendOwnership(to: id); return }
            // A negotiated new intent overrides the earlier take's ingress order.
            let order = event.ingressOrder ?? pendingOrder
            if let intent = message.presentationIntent { pendingIntent = intent }
            if let order { pendingOrder = order }
            if let order, order != coordinator.actionClock.current {
                rejectIntent(for: id); revoke(); sendFeedback(to: id); return
            }
            do {
                if let order {
                    hubLease = try coordinator.presentReceived(connection: id, sourceID: sender.id, name: sender.name,
                        revision: revision, content: content, ingressOrder: order, explicit: pendingIsExplicit || event.ingressOrder != nil)
                    pendingOrder = nil
                } else if let hubLease {
                    guard coordinator.updateReceived(connection: id, lease: hubLease, revision: revision, content: content) else { revoke(); return }
                } else { revoke(); return }
                self.revision = revision
                sendFeedback(to: id)
            } catch { issue = (error as? ExternalPresentationError)?.detail ?? "Presentation could not be accepted."; rejectIntent(for: id); revoke(); sendFeedback(to: id) }
        case .release:
            guard owner == id, message.lease == wireLease else { return }
            if hubLease != nil { coordinator.externalDisconnected(id) }
            formerOwner = nil; revoke()
        case .heartbeat: break
        default: break
        }
    }
    private func send(_ message: AltViewWireMessage, to id: UUID) {
        if let replySink { replySink(message, id) } else { server?.send(message, to: id) }
    }
    private var templates: [AltViewTemplateDescriptor] { [.init(id: .scripture, name: "Scripture"), .init(id: .lyrics, name: "Lyrics")] }
    private var outputReadiness: AltViewOutputReadiness {
        coordinator.destinationStatuses().contains { $0.readiness == .ready } ? .ready : .closed
    }
    private func sendOwnership(to connection: UUID) {
        let sender = owner.flatMap { senders[$0] }
        send(.init(kind: .ownership, lease: owner == connection ? wireLease : nil,
                          ownerID: sender?.id, ownerName: sender?.name), to: connection)
    }
    private func revoke() {
        owner = nil; wireLease = nil; hubLease = nil; pendingOrder = nil; revision = 0
        for id in senders.keys { sendOwnership(to: id) }
    }
    private func rejectIntent(for id: UUID, intent: UUID? = nil) {
        guard let sender = senders[id], let rejection = intent ?? pendingIntent else { return }
        if rejectedIntents.count >= 64, let first = rejectedIntents.keys.first { rejectedIntents.removeValue(forKey: first) }
        rejectedIntents[sender.id] = rejection
    }
    private func sendFeedback(to id: UUID) {
        var message = AltViewWireMessage(kind: .feedback,
            lease: owner == id && hubLease != nil && revision > 0 ? wireLease : nil,
            revision: owner == id && hubLease != nil && revision > 0 ? revision : nil,
            outputReadiness: outputReadiness, templates: templates, templatePolicy: .sender)
        if let sender = senders[id], sender.capabilities.contains(AltViewProtocol.presentationIntent) {
            message.rejectedPresentationIntent = rejectedIntents[sender.id]
        }
        send(message, to: id)
    }
    private func reportProgramState() {
        // Readiness changes cannot cancel preparation. Only a new coordinator
        // program transaction can supersede the receiver's current or pending action.
        if coordinator.revision != lastProgramRevision {
            lastProgramRevision = coordinator.revision
            if let owner {
                if case .external(let connection, _) = coordinator.ownership.source, connection == owner { }
                else if hubLease != nil || pendingOrder.map({ $0 != coordinator.actionClock.current }) == true {
                    rejectIntent(for: owner); formerOwner = nil; revoke()
                }
            }
        }
        for id in senders.keys { sendFeedback(to: id) }
    }
    private func disconnected(_ id: UUID) {
        if owner == id, let sender = senders[id] {
            pendingIntent = nil // Transport loss permits only passive former-owner resume.
            coordinator.externalDisconnected(id)
            formerOwner = (sender.id, coordinator.actionClock.current)
            revoke()
        }
        senders.removeValue(forKey: id); updateConnectedSenders()
    }
    deinit { startTask?.cancel(); retryTask?.cancel(); server?.stop() }
}

actor HubReceiverCredentialStore {
    private let keychain: any AltViewKeychainAccess
    private let service: String
    private var cached: Data?
    init(service: String = "com.suku.eucaly.hub.pairing", keychain: any AltViewKeychainAccess = SystemAltViewKeychain()) {
        self.service = service; self.keychain = keychain
    }
    func loadOrCreate() throws -> Data {
        if let cached { return cached }
        if let existing = try keychain.read(service: service, account: "receiver", dataProtection: false) {
            guard AltViewPairingKey.isValid(existing) else { throw ExternalPresentationError.invalid("Invalid saved pairing key") }
            cached = existing; return existing
        }
        let key = try AltViewPairingKey.generate()
        try keychain.save(key, service: service, account: "receiver", dataProtection: false)
        cached = key; return key
    }
}
