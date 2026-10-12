import Foundation
import Network

/// Queue-confined transport, framing, authentication and bounded mailboxes.
/// Only validated intents cross to the main actor; credentials never do.
nonisolated final class ExternalPresentationServer: @unchecked Sendable {
    private final class Peer {
        let id = UUID()
        let connection: NWConnection
        var authenticated = false
        var name = ""
        var decoder = ExternalFrameDecoder()
        var mailbox = ExternalInboundMailbox()
        var drainScheduled = false
        var controls: [Data] = []
        var latest: [String: Data] = [:]
        var sending = false
        var actionIDs: [UUID] = []
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private let queue = DispatchQueue(label: "com.suku.eucaly.presentation.receiver", qos: .userInitiated)
    private let recordAction: @Sendable () -> UInt64?
    private let credential: String
    private let port: UInt16
    private let intent: @MainActor @Sendable (UUID, String, ExternalPresentationMessage) -> Void
    private let disconnected: @MainActor @Sendable (UUID) -> Void
    private let status: @MainActor @Sendable (UInt16?, String?) -> Void
    private var listener: NWListener?
    private var peers: [UUID: Peer] = [:]

    init(credential: String, port: UInt16 = 49871, recordAction: @escaping @Sendable () -> UInt64? = { nil },
         intent: @escaping @MainActor @Sendable (UUID, String, ExternalPresentationMessage) -> Void,
         disconnected: @escaping @MainActor @Sendable (UUID) -> Void,
         status: @escaping @MainActor @Sendable (UInt16?, String?) -> Void) {
        self.recordAction = recordAction
        self.credential = credential; self.port = port; self.intent = intent
        self.disconnected = disconnected; self.status = status
    }
    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
                let listener = try NWListener(using: parameters)
                self.listener = listener
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        let port = listener?.port?.rawValue
                        Task { @MainActor in self.status(port, nil) }
                    case .failed:
                        self.stopOnQueue()
                        Task { @MainActor in self.status(nil, "Receiver could not listen on loopback. Check whether another eucaly receiver is running.") }
                    default: break
                    }
                }
                listener.start(queue: queue)
            } catch { Task { @MainActor in status(nil, "Receiver could not start on loopback.") } }
        }
    }
    func stop() { queue.async { [self] in stopOnQueue() } }
    private func stopOnQueue() {
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for peer in Array(peers.values) { close(peer) }
    }
    private func accept(_ connection: NWConnection) {
        guard peers.count < ExternalPresentationProtocol.maximumClients else { connection.cancel(); return }
        let peer = Peer(connection); peers[peer.id] = peer
        connection.stateUpdateHandler = { [weak self, weak peer] state in
            guard let self, let peer else { return }
            switch state {
            case .ready: self.read(peer)
            case .failed, .cancelled: self.close(peer)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak peer] in
            guard let self, let peer, !peer.authenticated else { return }
            self.close(peer)
        }
    }
    private func read(_ peer: Peer) {
        guard peers[peer.id] === peer else { return }
        peer.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak peer] data, _, complete, error in
            guard let self, let peer, self.peers[peer.id] === peer else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try peer.decoder.append(data) {
                        var message = try JSONDecoder().decode(ExternalPresentationMessage.self, from: frame)
                        do { try message.validate() } catch {
                            if !peer.authenticated { self.close(peer); return }
                            self.enqueue(.init(kind: "rejected", actionID: message.actionID, revision: message.revision, detail: "Invalid request"), peer: peer)
                            continue
                        }
                        if !peer.authenticated {
                            guard message.kind == .hello, let key = message.credential, ExternalAuthentication.matches(key, self.credential) else {
                                self.close(peer); return
                            }
                            peer.authenticated = true; peer.name = message.clientName ?? "External app"
                            message.credential = nil
                        } else if message.kind == .hello { throw ExternalPresentationError.invalid("Already authenticated") }
                        if let actionID = message.actionID, message.kind != .state {
                            guard !peer.actionIDs.contains(actionID) else { throw ExternalPresentationError.invalid("Duplicate action identity") }
                            peer.actionIDs.append(actionID)
                            if peer.actionIDs.count > 64 { peer.actionIDs.removeFirst() }
                        }
                        if message.kind == .present { message.ingressOrder = self.recordAction() }
                        do { try peer.mailbox.enqueue(message) } catch {
                            self.enqueue(.init(kind: "rejected", actionID: message.actionID, revision: message.revision, detail: "Pending control limit reached"), peer: peer)
                        }
                    }
                    self.scheduleDrain(peer)
                } catch {
                    // Malformed input is never forwarded and cannot alter output.
                    self.enqueue(.init(kind: "error", detail: "Malformed, oversized or excessive request"), peer: peer)
                    self.close(peer); return
                }
            }
            if complete || error != nil { self.close(peer) }
            else { self.read(peer) }
        }
    }
    private func scheduleDrain(_ peer: Peer) {
        guard !peer.drainScheduled else { return }
        peer.drainScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let batch: (String, [ExternalPresentationMessage])? = self.queue.sync {
                guard self.peers[peer.id] === peer else { return nil }
                peer.drainScheduled = false
                return (peer.name, peer.mailbox.drain())
            }
            guard let batch else { return }
            for message in batch.1 { self.intent(peer.id, batch.0, message) }
        }
    }
    func send(_ reply: ExternalPresentationReply, to id: UUID) {
        queue.async { [self] in if let peer = peers[id] { enqueue(reply, peer: peer) } }
    }
    func broadcast(_ reply: ExternalPresentationReply) {
        queue.async { [self] in for peer in peers.values where peer.authenticated { enqueue(reply, peer: peer) } }
    }
    func reportOwnership(owner: UUID?, lease: OutputLease?) {
        queue.async { [self] in
            for peer in peers.values where peer.authenticated {
                enqueue(.init(kind: "ownership", lease: owner == peer.id ? lease : nil, ownsOutput: owner == peer.id), peer: peer)
            }
        }
    }
    private func enqueue(_ reply: ExternalPresentationReply, peer: Peer) {
        guard peers[peer.id] === peer, let data = try? ExternalPresentationProtocol.frame(reply) else { return }
        if ["feedback", "readiness", "ownership"].contains(reply.kind) { peer.latest[reply.kind] = data }
        else {
            guard peer.controls.count < ExternalPresentationProtocol.maximumControls else { close(peer); return }
            peer.controls.append(data)
        }
        sendNext(peer)
    }
    private func sendNext(_ peer: Peer) {
        guard !peer.sending, peers[peer.id] === peer else { return }
        let packet: Data?
        if !peer.controls.isEmpty { packet = peer.controls.removeFirst() }
        else if let key = ["ownership", "feedback", "readiness"].first(where: { peer.latest[$0] != nil }) { packet = peer.latest.removeValue(forKey: key) }
        else { packet = nil }
        guard let packet else { return }
        peer.sending = true
        peer.connection.send(content: packet, completion: .contentProcessed { [weak self, weak peer] error in
            guard let self, let peer, self.peers[peer.id] === peer else { return }
            peer.sending = false
            if error != nil { self.close(peer) } else { self.sendNext(peer) }
        })
    }
    private func close(_ peer: Peer) {
        guard peers.removeValue(forKey: peer.id) != nil else { return }
        peer.connection.stateUpdateHandler = nil; peer.connection.cancel()
        Task { @MainActor in disconnected(peer.id) }
    }
}
