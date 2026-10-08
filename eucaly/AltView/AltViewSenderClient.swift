// Adapted from AltView protocol v2 sender, source 9918ca19a5ab6480cb58f2d8ea90878e4f5c67cd.
// Kept local so eucaly builds and runs without an AltView checkout or process.
import Foundation
import Network

nonisolated struct AltViewSenderStatus: Equatable, Sendable {
    var connectionID: UUID?
    var connected = false
    var ownsOutput = false
    var followingOutput = false
    var receiverID: UUID?
    var ownerName: String?
    var message = "Not connected"
    var failureReason: String?
    var waitingToRetry = false
    var feedback = AltViewDeliveryFeedback()
    var submissionID: UUID?
    var contentError: String?
    var capabilities: Set<String> = []
    var templateCapabilities = AltViewTemplateCapabilities()
}

nonisolated struct AltViewSubmission: Sendable {
    let id: UUID
    let content: AltViewDisplayContent
}

nonisolated protocol AltViewSending: AnyObject {
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID?, connectionID: UUID)
    func updateEndpoint(_ endpoint: NWEndpoint, connectionID: UUID)
    func submit(_ content: AltViewDisplayContent, submissionID: UUID)
    func takeOutput()
    func releaseOutput()
    func disconnect()
}

extension AltViewSending {
    nonisolated func updateEndpoint(_ endpoint: NWEndpoint, connectionID: UUID) {}
}

/// No network operation or serialization runs on the caller's UI thread.
/// Mutable transport state is confined to queue; submissions/delivery use locks.
nonisolated final class AltViewSenderClient: AltViewSending, @unchecked Sendable {
    let senderID: UUID
    let name: String
    private let queue: DispatchQueue
    private var peer: AltViewPeerChannel?
    private var endpoint: NWEndpoint?
    private var key: Data?
    private var expectedReceiverID: UUID?
    private var reconnectWork: DispatchWorkItem?
    private var attempts = 0
    private var initialConnectionDeadline: TimeInterval?
    private var timer: DispatchSourceTimer?
    private var lease: UUID?
    private var revision: UInt64 = 0
    private var latest = AltViewDisplayContent.empty
    private var latestSubmissionID: UUID?
    private var wantsConnection = false
    private var shouldRestoreOwnership = false
    // A cached lease can already be revoked. Retain explicit projection until
    // its snapshot is accepted or a fresh ownership grant resolves the request.
    private var pendingTake = false
    private var pendingProjectionRevision: UInt64?
    private enum OwnershipRequest { case take, resume }
    private var pendingOwnershipRequest: OwnershipRequest?
    private var status = AltViewSenderStatus()
    private let delivery: AltViewSnapshotMailbox<AltViewSenderStatus>
    private let inputLock = NSLock()
    private var submissions: AltViewSnapshotMailbox<AltViewSubmission>?

    init(name: String, senderID: UUID = UUID(),
         senderQueue: DispatchQueue = DispatchQueue(label: "com.suku.eucaly.altview.sender", qos: .userInitiated),
         callbackQueue: DispatchQueue = .main, onStatus: @escaping (AltViewSenderStatus) -> Void) {
        self.name = name; self.senderID = senderID
        queue = senderQueue
        delivery = AltViewSnapshotMailbox(queue: callbackQueue, consume: onStatus)
    }
    private func accept(_ submission: AltViewSubmission, connectionID: UUID) {
        guard wantsConnection, status.connectionID == connectionID else { return }
        // Check escaped JSON as well as UTF-8 limits off the UI thread. Clear a
        // previous verse if this one cannot be represented; never truncate it.
        let content = submission.content
        let encodable = content.isValid && (try? AltViewFrameCodec.encode(AltViewWireMessage(
            kind: .state, lease: UUID(), revision: UInt64.max, content: contentForSending(content)
        ))) != nil
        latest = encodable ? content : .empty
        latestSubmissionID = submission.id
        status.contentError = encodable ? nil : "This slide exceeds AltView’s text limits. AltView text is cleared; local projection continues."
        sendLatest()
        publish()
    }
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID? = nil, connectionID: UUID = UUID()) {
        inputLock.lock()
        defer { inputLock.unlock() }
        // A new mailbox cannot be consumed by an old connection's queued drain.
        // Queue the connect before exposing this mailbox to submissions.
        submissions = AltViewSnapshotMailbox(queue: queue) { [weak self] in
            self?.accept($0, connectionID: connectionID)
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.disconnectOnQueue()
            self.status.connectionID = connectionID
            self.endpoint = endpoint; self.key = key
            self.expectedReceiverID = expectedReceiverID
            self.wantsConnection = true; self.attempts = 0
            self.initialConnectionDeadline = ProcessInfo.processInfo.systemUptime + AltViewProtocol.connectionTimeout
            self.openConnection()
        }
    }
    func updateEndpoint(_ endpoint: NWEndpoint, connectionID: UUID) {
        queue.async { [weak self] in
            guard let self, self.wantsConnection, self.status.connectionID == connectionID, self.endpoint != endpoint else { return }
            self.shouldRestoreOwnership = self.status.ownsOutput || self.shouldRestoreOwnership
            self.endpoint = endpoint
            self.stopTransport()
            self.openConnection()
        }
    }
    func submit(_ content: AltViewDisplayContent, submissionID: UUID) {
        let mailbox = inputLock.withLock { submissions }
        mailbox?.offer(AltViewSubmission(id: submissionID, content: content))
    }
    func takeOutput() {
        queue.async { [weak self] in
            guard let self, self.wantsConnection else { return }
            self.pendingTake = true
            self.pendingProjectionRevision = nil
            self.status.followingOutput = true
            if self.lease != nil {
                // Reaffirm even an unchanged slide with a fresh revision. An
                // earlier acceptance cannot confirm this operator action.
                self.sendLatest(force: true)
            } else {
                self.requestPendingTake()
            }
            self.publish()
        }
    }
    private func requestPendingTake() {
        guard pendingTake, lease == nil, status.connected else { return }
        if pendingOwnershipRequest == .resume {
            // v2 broadcasts cannot distinguish a refused resume from an
            // unrelated ownership update. Retire that uncertain request
            // before an explicit take so its late grant cannot race ours.
            stopTransport()
            shouldRestoreOwnership = false
            openConnection()
        } else if pendingOwnershipRequest == nil {
            peer?.discardPendingState()
            pendingOwnershipRequest = .take
            peer?.send(AltViewWireMessage(kind: .take))
        }
    }
    func releaseOutput() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shouldRestoreOwnership = false
            self.pendingTake = false
            self.pendingProjectionRevision = nil
            self.status.followingOutput = false
            self.peer?.discardPendingState()
            if let lease = self.lease { self.peer?.send(AltViewWireMessage(kind: .release, lease: lease)) }
            self.lease = nil
            self.status.ownsOutput = false
            self.status.feedback.resetSnapshot()
            self.status.submissionID = nil
            self.status.message = self.status.connected ? "Connected — output released" : self.status.message
            self.publish()
        }
    }
    func disconnect() {
        inputLock.withLock {
            submissions = nil
            queue.async { [weak self] in self?.disconnectOnQueue(); self?.publish() }
        }
    }
    private func stopTransport() {
        reconnectWork?.cancel(); reconnectWork = nil
        timer?.cancel(); timer = nil
        peer?.onClose = nil; peer?.close(nil); peer = nil
        lease = nil; pendingOwnershipRequest = nil; pendingProjectionRevision = nil
        status.connected = false; status.ownsOutput = false
        status.waitingToRetry = false; status.submissionID = nil
        status.feedback = AltViewDeliveryFeedback()
        status.templateCapabilities = AltViewTemplateCapabilities()
        status.capabilities = []
    }
    private func disconnectOnQueue() {
        wantsConnection = false; shouldRestoreOwnership = false; pendingTake = false
        initialConnectionDeadline = nil
        stopTransport()
        latest = .empty; latestSubmissionID = nil; revision = 0
        endpoint = nil; key = nil; expectedReceiverID = nil
        status = AltViewSenderStatus()
    }
    private func openConnection() {
        guard wantsConnection, let endpoint, let key else { return }
        let setupTimeout: TimeInterval
        if let deadline = initialConnectionDeadline {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else {
                failInitialConnection("Connection timed out. Check that the receiving Mac is ready and AltView has Local Network access in System Settings.")
                return
            }
            setupTimeout = min(AltViewProtocol.connectionAttemptTimeout, remaining)
            status.message = attempts == 0 ? "Connecting…" : "Connecting… Retrying the network connection."
        } else {
            setupTimeout = AltViewProtocol.connectionTimeout
            status.message = "Reconnecting…"
        }
        status.failureReason = nil
        status.waitingToRetry = false
        publish()
        let peer = AltViewPeerChannel(connection: NWConnection(to: endpoint, using: AltViewSecureConnection.parameters(key: key)),
                               queue: queue, connectionTimeout: setupTimeout)
        self.peer = peer
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            peer.send(AltViewWireMessage(kind: .hello, senderID: self.senderID, name: self.name, capabilities: AltViewProtocol.capabilities))
            // The application handshake starts after the transport is ready.
            self.queue.asyncAfter(deadline: .now() + AltViewProtocol.timeout) { [weak self, weak peer] in
                guard let self, let peer, self.peer === peer, !self.status.connected else { return }
                peer.close("Receiver did not complete the handshake.")
            }
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer, self.peer === peer else { return }
            self.handle(message)
        }
        peer.onClose = { [weak self, weak peer] reason in
            guard let self, let peer, self.peer === peer else { return }
            self.shouldRestoreOwnership = self.status.ownsOutput || self.shouldRestoreOwnership
            self.peer = nil; self.lease = nil
            self.pendingOwnershipRequest = nil; self.pendingProjectionRevision = nil
            self.status.connected = false; self.status.ownsOutput = false
            self.status.followingOutput = self.shouldRestoreOwnership || self.pendingTake
            self.status.submissionID = nil
            self.status.feedback = AltViewDeliveryFeedback()
            self.status.templateCapabilities = AltViewTemplateCapabilities()
            self.status.capabilities = []
            self.timer?.cancel(); self.timer = nil
            if let deadline = self.initialConnectionDeadline {
                if self.wantsConnection, peer.retryableSetupFailure, ProcessInfo.processInfo.systemUptime < deadline {
                    // A Bonjour connection can remain stuck in preparing after Local Network
                    // access changes. Use a fresh connection without cancelling the user's action.
                    self.status.message = "Connecting… Retrying the network connection."
                    self.publish()
                    self.scheduleReconnect()
                } else {
                    self.failInitialConnection(reason ?? "The receiving Mac closed the connection.")
                }
                return
            }
            self.status.failureReason = reason
            self.status.message = self.wantsConnection ? "Disconnected. \(reason ?? "") Retrying…" : (reason ?? "Disconnected")
            self.publish()
            self.scheduleReconnect()
        }
        peer.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            if self.status.connected { peer.send(AltViewWireMessage(kind: .heartbeat)) }
            if self.status.feedback.checkTimeout(now: ProcessInfo.processInfo.systemUptime) { self.publish() }
            peer.checkTimeout(now: ProcessInfo.processInfo.systemUptime)
        }
        self.timer = timer; timer.resume()
    }
    private func handle(_ message: AltViewWireMessage) {
        guard message.version == AltViewProtocol.version else { wantsConnection = false; peer?.close("Incompatible AltView protocol. Update both apps."); return }
        if message.kind == .welcome || message.kind == .feedback {
            let capabilities = AltViewTemplateCapabilities(templates: message.templates, policy: message.templatePolicy)
            guard capabilities.isValid else {
                wantsConnection = false
                peer?.close("Invalid template catalogue or receiver policy.")
                return
            }
        }
        switch message.kind {
        case .welcome:
            guard !status.connected, let receiverID = message.receiverID,
                  (message.ownerID == nil && message.ownerName == nil)
                    || (message.ownerID != nil && validName(message.ownerName)) else { peer?.close("Invalid welcome."); return }
            if let expectedReceiverID, expectedReceiverID != receiverID {
                wantsConnection = false
                peer?.close("Receiver identity changed. Pair again.")
                status.message = "Receiver identity changed. Pair again."
                publish()
                return
            }
            status.feedback = AltViewDeliveryFeedback()
            // Discovery must be ready before resume can grant a fresh lease.
            status.templateCapabilities = AltViewTemplateCapabilities(templates: message.templates, policy: message.templatePolicy)
            status.capabilities = Set(message.capabilities ?? []).intersection(AltViewProtocol.capabilities)
            expectedReceiverID = receiverID
            initialConnectionDeadline = nil
            attempts = 0; status.connected = true; status.receiverID = receiverID
            status.ownerName = message.ownerName
            status.message = "Connected — ready to take output"
            if pendingTake {
                pendingOwnershipRequest = .take
                peer?.send(AltViewWireMessage(kind: .take))
            } else if shouldRestoreOwnership && message.ownerID == nil {
                pendingOwnershipRequest = .resume
                peer?.send(AltViewWireMessage(kind: .resume))
            }
            else if message.ownerID != nil { shouldRestoreOwnership = false; status.followingOutput = false }
            publish()
        case .granted:
            guard status.connected, pendingOwnershipRequest != nil, let lease = message.lease else { peer?.close("Invalid output grant."); return }
            pendingTake = false; pendingProjectionRevision = nil; pendingOwnershipRequest = nil
            // Stop may have crossed an in-flight take/resume. Relinquish the new
            // lease without ever publishing text or restarting restoration.
            guard status.followingOutput else {
                peer?.send(AltViewWireMessage(kind: .release, lease: lease))
                return
            }
            self.lease = lease; revision = 0
            status.feedback.resetSnapshot()
            status.ownsOutput = true; shouldRestoreOwnership = true
            status.message = "Controlling output"
            sendLatest(); publish()
        case .ownership:
            guard status.connected,
                  (message.ownerID == nil && message.ownerName == nil && message.lease == nil)
                    || (message.ownerID != nil && validName(message.ownerName) && message.lease != nil) else {
                peer?.close("Invalid ownership report."); return
            }
            status.ownerName = message.ownerName
            if message.ownerID != senderID || message.lease != lease {
                lease = nil; status.ownsOutput = false; pendingProjectionRevision = nil
                if pendingOwnershipRequest != .resume || message.ownerID != nil { shouldRestoreOwnership = false }
                // Broadcasts are unsolicited, including when an idle sender
                // disconnects. They cannot settle a pending take or resume;
                // a valid grant may still follow on this connection.
                if pendingOwnershipRequest == nil { status.followingOutput = pendingTake }
                status.submissionID = nil
                status.feedback.resetSnapshot()
                peer?.discardPendingState()
                status.message = message.ownerName.map { "Output controlled by \($0)" } ?? "Connected — output is clear"
                requestPendingTake()
            }
            publish()
        case .feedback:
            guard status.connected, message.outputReadiness != nil,
                  (message.lease == nil && message.revision == nil) || (message.lease != nil && message.revision.map { $0 > 0 } == true) else {
                peer?.close("Unexpected output feedback."); return
            }
            // A complete report replaces discovery, including missing fields
            // from older receivers. Discovery alone never republishes text.
            status.templateCapabilities = AltViewTemplateCapabilities(templates: message.templates, policy: message.templatePolicy)
            status.feedback.receive(message, lease: lease, now: ProcessInfo.processInfo.systemUptime)
            if let pendingProjectionRevision, status.feedback.acceptedRevision >= pendingProjectionRevision {
                pendingTake = false
                self.pendingProjectionRevision = nil
            }
            publish()
        case .heartbeat: break
        case .error:
            wantsConnection = false
            peer?.close(message.detail ?? "Receiver rejected the message")
        default: peer?.close("Unexpected receiver message.")
        }
    }
    private func sendLatest(force: Bool = false) {
        guard latest.isValid else { status.message = "Text is too long to send"; publish(); return }
        guard let lease, status.connected, status.followingOutput else { return }
        guard force || status.submissionID != latestSubmissionID || status.feedback.sentRevision == 0 else { return }
        guard revision < UInt64.max else { peer?.close("Session revision exhausted."); return }
        var content = contentForSending(latest)
        // Welcome may enable confidence after a submission was queued. Validate
        // the negotiated frame before enqueueing it so oversize text cannot close TLS.
        if (try? AltViewFrameCodec.encode(AltViewWireMessage(kind: .state, lease: lease, revision: UInt64.max, content: content))) == nil {
            content = .empty; latest = .empty
            status.contentError = "This slide exceeds AltView’s text limits. AltView text is cleared; local projection continues."
        }
        revision += 1
        if pendingTake, pendingProjectionRevision == nil { pendingProjectionRevision = revision }
        status.feedback.sent(revision, now: ProcessInfo.processInfo.systemUptime)
        status.submissionID = latestSubmissionID
        peer?.send(AltViewWireMessage(kind: .state, lease: lease, revision: revision, content: content))
        publish()
    }
    private func contentForSending(_ snapshot: AltViewDisplayContent) -> AltViewDisplayContent {
        var content = status.templateCapabilities.contentForSending(snapshot)
        if !status.capabilities.contains(AltViewProtocol.confidenceText) { content.confidence = nil }
        return content
    }
    private func validName(_ name: String?) -> Bool {
        guard let name else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 128
    }
    private func scheduleReconnect() {
        guard wantsConnection else { return }
        let delay = initialConnectionDeadline.map { min(1, max(0, $0 - ProcessInfo.processInfo.systemUptime)) }
            ?? min(8.0, pow(2.0, Double(min(attempts, 3))))
        attempts += 1
        status.waitingToRetry = true
        publish()
        let connectionID = status.connectionID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsConnection, self.status.connectionID == connectionID, self.peer == nil else { return }
            self.reconnectWork = nil
            self.openConnection()
        }
        reconnectWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func failInitialConnection(_ reason: String) {
        wantsConnection = false; initialConnectionDeadline = nil
        pendingTake = false; shouldRestoreOwnership = false; status.followingOutput = false
        pendingProjectionRevision = nil
        reconnectWork?.cancel(); reconnectWork = nil
        status.failureReason = reason
        status.waitingToRetry = false
        status.message = "Disconnected. \(reason)"
        publish()
    }
    private func publish() { delivery.offer(status) }
}
