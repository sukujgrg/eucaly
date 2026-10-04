// Test-only protocol peer from AltView 9918ca19a5ab6480cb58f2d8ea90878e4f5c67cd.
@testable import eucaly
import Foundation
import Network

nonisolated struct ReferenceAltViewReceiverStatus: Equatable {
    var listening = false
    var port: UInt16?
    var connections = 0
    var pendingResumes = 0
    var rejectedSnapshots = 0
    var connectedSenders: [ReferenceAltViewSenderIdentity] = []
    var ownerID: UUID?
    var ownerName: String?
    var content = AltViewDisplayContent.empty
    var revision: UInt64 = 0
    var message = "Receiving is off"
}

nonisolated final class ReferenceAltViewReceiverServer: @unchecked Sendable {
    let receiverID: UUID
    private let queue = DispatchQueue(label: "com.suku.AltView.receiver", qos: .userInitiated)
    private var listener: NWListener?
    private var peers: [UUID: AltViewPeerChannel] = [:]
    private var resumesSuspended = false
    private var pendingResumes: [UUID: AltViewPeerChannel] = [:]
    private var suspendedOwnershipNames = Set<String>()
    private var handshakeDisconnects: Int
    private let grantDelay: TimeInterval
    private var templateCapabilities: AltViewTemplateCapabilities
    private var outputReadiness = AltViewOutputReadiness.closed
    private var state = ReferenceAltViewReceiverState()
    private var status = ReferenceAltViewReceiverStatus()
    private var timer: DispatchSourceTimer?
    private let delivery: AltViewSnapshotMailbox<ReferenceAltViewReceiverStatus>

    init(receiverID: UUID, templateCapabilities: AltViewTemplateCapabilities = .init(), handshakeDisconnects: Int = 0,
         grantDelay: TimeInterval = 0,
         callbackQueue: DispatchQueue = .main, onStatus: @escaping (ReferenceAltViewReceiverStatus) -> Void) {
        self.receiverID = receiverID
        self.templateCapabilities = templateCapabilities
        self.handshakeDisconnects = handshakeDisconnects
        self.grantDelay = grantDelay
        delivery = AltViewSnapshotMailbox(queue: callbackQueue, consume: onStatus)
    }
    func start(name: String, key: Data, port: UInt16 = 0, advertise: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            do {
                let listener = try NWListener(using: AltViewSecureConnection.parameters(key: key), on: NWEndpoint.Port(rawValue: port)!)
                self.listener = listener
                if advertise {
                    // Public identity lets discovery omit this Mac; pairing secrets never leave TLS.
                    listener.service = NWListener.Service(name: name, type: AltViewProtocol.serviceType,
                        txtRecord: NWTXTRecord(["receiverID": self.receiverID.uuidString]))
                }
                listener.stateUpdateHandler = { [weak self, weak listener] newState in
                    guard let self, let listener, self.listener === listener else { return }
                    switch newState {
                    case .ready:
                        self.status.listening = true
                        self.status.port = listener.port?.rawValue
                        self.status.message = "Ready for senders"
                        self.publish()
                    case .failed(let error), .waiting(let error):
                        self.stopOnQueue()
                        self.status.message = "Could not receive: \(error.localizedDescription)"
                        self.publish()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: self.queue)
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    for peer in Array(self.peers.values) {
                        peer.send(AltViewWireMessage(kind: .heartbeat))
                        peer.checkTimeout(now: now)
                    }
                }
                self.timer = timer
                timer.resume()
            } catch {
                self.status.message = "Could not start receiver: \(error.localizedDescription)"
                self.publish()
            }
        }
    }
    func updateTemplateCapabilities(_ capabilities: AltViewTemplateCapabilities) {
        queue.async { [weak self] in
            guard let self else { return }
            self.templateCapabilities = capabilities
            self.broadcastFeedback()
        }
    }
    func updateOutputReadiness(_ readiness: AltViewOutputReadiness) {
        queue.async { [weak self] in
            guard let self, self.outputReadiness != readiness else { return }
            self.outputReadiness = readiness
            self.broadcastFeedback()
        }
    }
    func stop() { queue.async { [weak self] in self?.stopOnQueue(); self?.publish() } }
    // Test controls exercise otherwise timing-dependent wire orderings.
    func setResumesSuspended(_ suspended: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            self.resumesSuspended = suspended
            if !suspended {
                let pending = Array(self.pendingResumes.values)
                self.pendingResumes.removeAll()
                for peer in pending where self.peers[peer.id] != nil {
                    self.handle(.init(kind: .resume), from: peer)
                }
            }
            self.publish()
        }
    }
    func dropConnections(named name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            for peer in Array(self.peers.values) where self.state.senders[peer.id]?.name == name {
                peer.close("Simulated network loss.")
            }
        }
    }
    func setOwnershipReportsSuspended(_ suspended: Bool, for name: String) {
        queue.async { [weak self] in
            guard let self else { return }
            if suspended { self.suspendedOwnershipNames.insert(name) }
            else {
                self.suspendedOwnershipNames.remove(name)
                self.broadcastOwnership()
            }
        }
    }
    func clearOutput() {
        queue.async { [weak self] in
            guard let self else { return }
            self.state.clearOwner()
            self.status.message = "Ready for senders"
            self.broadcastOwnership()
            self.publish()
        }
    }
    private func stopOnQueue() {
        timer?.cancel(); timer = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        let closing = Array(peers.values)
        peers.removeAll()
        pendingResumes.removeAll()
        suspendedOwnershipNames.removeAll()
        for peer in closing { peer.onClose = nil; peer.close(nil) }
        state = ReferenceAltViewReceiverState()
        status = ReferenceAltViewReceiverStatus()
    }
    private func accept(_ connection: NWConnection) {
        guard peers.count < AltViewProtocol.maximumClients else { connection.cancel(); return }
        let peer = AltViewPeerChannel(connection: connection, queue: queue)
        peers[peer.id] = peer
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer else { return }
            self.handle(message, from: peer)
        }
        peer.onClose = { [weak self, weak peer] reason in
            guard let self, let peer, self.peers.removeValue(forKey: peer.id) != nil else { return }
            self.pendingResumes.removeValue(forKey: peer.id)
            let wasOwner = self.state.ownerConnection == peer.id
            self.state.disconnect(peer.id)
            if wasOwner { self.status.message = "Sender disconnected — output cleared" }
            self.broadcastOwnership()
            self.publish()
        }
        peer.start()
        // An authenticated peer must identify itself, even if it sends heartbeats.
        queue.asyncAfter(deadline: .now() + AltViewProtocol.timeout) { [weak self, weak peer] in
            guard let self, let peer, self.peers[peer.id] != nil, self.state.senders[peer.id] == nil else { return }
            peer.close("Sender did not identify itself.")
        }
    }
    private func handle(_ message: AltViewWireMessage, from peer: AltViewPeerChannel) {
        guard message.version == AltViewProtocol.version else { peer.close("Unsupported protocol version."); return }
        if message.kind == .hello {
            if handshakeDisconnects > 0 {
                handshakeDisconnects -= 1
                peer.close("Simulated receiver restart before welcome.")
                return
            }
            guard let id = message.senderID, let name = message.name, state.register(connection: peer.id, senderID: id, name: name) else {
                peer.close("Invalid sender identity."); return
            }
            peer.send(AltViewWireMessage(kind: .welcome, receiverID: receiverID, ownerID: state.owner?.id, ownerName: state.owner?.name, templates: templateCapabilities.templates, templatePolicy: templateCapabilities.policy))
            sendFeedback(to: peer)
            publish()
            return
        }
        guard state.senders[peer.id] != nil else { peer.close("Identify sender first."); return }
        switch message.kind {
        case .take, .resume:
            if message.kind == .resume, resumesSuspended {
                pendingResumes[peer.id] = peer
                publish()
                return
            }
            guard let lease = state.take(connection: peer.id, onlyIfUnowned: message.kind == .resume) else {
                broadcastOwnership(); return
            }
            status.message = "Receiving from \(state.owner!.name)"
            if grantDelay > 0 {
                queue.asyncAfter(deadline: .now() + grantDelay) { [weak self, weak peer] in
                    guard let self, let peer, self.peers[peer.id] != nil else { return }
                    peer.send(AltViewWireMessage(kind: .granted, lease: lease))
                    self.broadcastOwnership()
                }
            } else {
                peer.send(AltViewWireMessage(kind: .granted, lease: lease))
                broadcastOwnership()
            }
            publish()
        case .state:
            guard let lease = message.lease, let revision = message.revision, let content = message.content, content.isValid else {
                peer.close("Invalid content snapshot."); return
            }
            if state.apply(connection: peer.id, lease: lease, revision: revision, content: content) {
                publish()
                sendFeedback(to: peer)
            } else {
                status.rejectedSnapshots += 1
                publish()
            }
        case .release:
            if state.release(connection: peer.id, lease: message.lease) {
                status.message = "Ready for senders"
                broadcastOwnership()
                publish()
            }
        case .heartbeat: break
        default: peer.close("Unexpected sender message.")
        }
    }
    private func broadcastOwnership() {
        let message = AltViewWireMessage(kind: .ownership, lease: state.lease, ownerID: state.owner?.id, ownerName: state.owner?.name)
        for (id, peer) in peers {
            guard let sender = state.senders[id], !suspendedOwnershipNames.contains(sender.name) else { continue }
            peer.send(message)
        }
        broadcastFeedback()
    }
    private func broadcastFeedback() {
        for peer in peers.values { sendFeedback(to: peer) }
    }
    private func sendFeedback(to peer: AltViewPeerChannel) {
        guard state.senders[peer.id] != nil else { return }
        let hasSnapshot = state.ownerConnection == peer.id && state.revision > 0
        peer.send(AltViewWireMessage(kind: .feedback, lease: hasSnapshot ? state.lease : nil,
                              revision: hasSnapshot ? state.revision : nil, outputReadiness: outputReadiness,
                              templates: templateCapabilities.templates, templatePolicy: templateCapabilities.policy))
    }
    private func publish() {
        status.connections = state.senders.count
        status.pendingResumes = pendingResumes.count
        status.connectedSenders = state.senders.values.sorted {
            $0.name == $1.name ? $0.id.uuidString < $1.id.uuidString : $0.name < $1.name
        }
        status.ownerID = state.owner?.id
        status.ownerName = state.owner?.name
        status.content = state.content
        status.revision = state.revision
        delivery.offer(status)
    }
}
