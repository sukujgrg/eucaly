import Foundation
import Network

nonisolated struct HubReceiverEnvelope: Sendable {
    var connection: UUID
    var message: AltViewWireMessage
    var ingressOrder: UInt64?
}

/// Queue-owned TLS/framing with bounded controls and one latest state per peer.
nonisolated final class HubReceiverServer: @unchecked Sendable {
    private final class Peer {
        let channel: AltViewPeerChannel
        var senderID: UUID?
        var authenticated = false
        var pendingTakeIntent: UUID?
        var awaitingFirstState = false
        var resuming = false
        var explicitIntent: UUID?
        var controls: [HubReceiverEnvelope] = []
        var state: HubReceiverEnvelope?
        var draining = false
        init(_ channel: AltViewPeerChannel) { self.channel = channel }
    }
    private let queue = DispatchQueue(label: "com.suku.eucaly.hub.receiver", qos: .userInitiated)
    private let receiverID: UUID
    private let key: Data
    private let actionClock: OutputActionClock
    private let name: String
    private let advertise: Bool
    private let intent: @MainActor @Sendable (HubReceiverEnvelope) -> Void
    private let disconnected: @MainActor @Sendable (UUID) -> Void
    private let status: @MainActor @Sendable (UInt16?, String?, Bool) -> Void
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]
    private var timer: DispatchSourceTimer?
    init(receiverID: UUID, key: Data, name: String, actionClock: OutputActionClock, advertise: Bool = true,
         intent: @escaping @MainActor @Sendable (HubReceiverEnvelope) -> Void,
         disconnected: @escaping @MainActor @Sendable (UUID) -> Void,
         status: @escaping @MainActor @Sendable (UInt16?, String?, Bool) -> Void) {
        self.receiverID = receiverID; self.key = key; self.name = name; self.actionClock = actionClock
        self.advertise = advertise; self.intent = intent; self.disconnected = disconnected; self.status = status
    }
    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let listener = try NWListener(using: AltViewSecureConnection.parameters(key: key), on: .any)
                self.listener = listener
                if advertise { listener.service = service(port: nil) }
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        let port = listener.port?.rawValue
                        if self.advertise { listener.service = self.service(port: port) }
                        Task { @MainActor in self.status(port, nil, false) }
                    case .waiting(let error):
                        Task { @MainActor in self.status(listener.port?.rawValue, "Waiting for the local network: \(error.localizedDescription)", false) }
                    case .failed(let error):
                        self.stopOnQueue()
                        Task { @MainActor in self.status(nil, "Receiving interrupted: \(error.localizedDescription)", true) }
                    default: break
                    }
                }
                listener.start(queue: queue)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    for peer in Array(self.peers.values) {
                        peer.channel.send(.init(kind: .heartbeat))
                        peer.channel.checkTimeout(now: ProcessInfo.processInfo.systemUptime)
                    }
                }
                self.timer = timer; timer.resume()
            } catch { Task { @MainActor in status(nil, "Receiver could not start: \(error.localizedDescription)", true) } }
        }
    }
    private func service(port: UInt16?) -> NWListener.Service {
        var record = ["receiverID": receiverID.uuidString, "presentationHub": "1"]
        if let port { record["port"] = String(port) }
        record["localMarker"] = AltViewLocalReceiverMarker.current
        return .init(name: name, type: AltViewProtocol.serviceType, txtRecord: NWTXTRecord(record))
    }
    private func accept(_ connection: NWConnection) {
        guard peers.count < AltViewProtocol.maximumClients else { connection.cancel(); return }
        let channel = AltViewPeerChannel(connection: connection, queue: queue)
        let id = channel.id; peers[id] = Peer(channel)
        channel.onMessage = { [weak self] in self?.receive($0, from: id) }
        channel.onClose = { [weak self] _ in
            guard let self, self.peers.removeValue(forKey: id) != nil else { return }
            Task { @MainActor in self.disconnected(id) }
        }
        channel.start()
        queue.asyncAfter(deadline: .now() + 5) { [weak self] in
            if let peer = self?.peers[id], !peer.authenticated { peer.channel.close("Handshake timed out") }
        }
    }
    private func receive(_ message: AltViewWireMessage, from id: UUID) {
        guard let peer = peers[id] else { return }
        if !peer.authenticated {
            guard message.kind == .hello, let sender = message.senderID, sender != receiverID,
                  let name = message.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  name.utf8.count <= 128, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  (message.capabilities?.count ?? 0) <= 32 else { peer.channel.close("Invalid sender identity"); return }
            peer.authenticated = true; peer.senderID = sender
        } else if message.kind == .hello { peer.channel.close("Duplicate handshake"); return }
        if message.kind == .heartbeat { return }
        guard message.content?.isValid ?? true else { peer.channel.close("Invalid text snapshot"); return }
        var order: UInt64?
        if message.kind == .resume { peer.resuming = true }
        if message.kind == .take { peer.resuming = false; peer.awaitingFirstState = true; peer.pendingTakeIntent = message.presentationIntent; order = message.presentationIntent.flatMap { intent in peer.senderID.map { actionClock.record(sender: $0, intent: intent) } } ?? actionClock.next() }
        if message.kind == .state, let explicit = message.presentationIntent, explicit != peer.explicitIntent {
            peer.explicitIntent = explicit
            let followsTake = peer.awaitingFirstState && (peer.pendingTakeIntent == nil || peer.pendingTakeIntent == explicit)
            if !peer.resuming && !followsTake, let sender = peer.senderID { order = actionClock.record(sender: sender, intent: explicit) }
        }
        if message.kind == .state { peer.resuming = false; peer.awaitingFirstState = false; peer.pendingTakeIntent = nil }
        var envelope = HubReceiverEnvelope(connection: id, message: message, ingressOrder: order)
        if message.kind == .state {
            if envelope.ingressOrder == nil { envelope.ingressOrder = peer.state?.ingressOrder }
            peer.state = envelope
        } else {
            if let state = peer.state { peer.controls.append(state); peer.state = nil }
            guard peer.controls.count < 32 else { peer.channel.close("Too many pending controls"); return }
            peer.controls.append(envelope)
        }
        guard !peer.draining else { return }
        peer.draining = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let batch: [HubReceiverEnvelope] = self.queue.sync {
                guard let peer = self.peers[id] else { return [] }
                peer.draining = false
                var batch = peer.controls; peer.controls.removeAll(keepingCapacity: true)
                if let state = peer.state { batch.append(state); peer.state = nil }
                return batch
            }
            for event in batch { self.intent(event) }
        }
    }
    func send(_ message: AltViewWireMessage, to id: UUID) { queue.async { [self] in peers[id]?.channel.send(message) } }
    func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        timer?.cancel(); timer = nil
        for peer in Array(peers.values) { peer.channel.close(nil) }
        peers.removeAll()
    }
}
