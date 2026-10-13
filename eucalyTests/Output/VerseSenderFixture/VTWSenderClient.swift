// Test fixture from actual ViewTheWord sender, 2026-10-13.
// Original SHA256: fa0a8cc481f7811b732c0e98025b86a62d19286236de2f6c337f70c437701c37
// Only type names and explicit actor-independent declarations differ.
import Foundation
import Network

nonisolated struct VTWAltViewSenderStatus: Equatable, Sendable {
    var connectionID: UUID?
    var connected = false
    var waitingToRetry = false
    var ownsOutput = false
    var receiverID: UUID?
    var rejectedPresentationIntent: UUID?
    var ownerName: String?
    var message = "Not connected"
    var failureReason: String?
    var feedback = VTWAltViewDeliveryFeedback()
    var outputIssue: String?
    var submissionID: UUID?
    var templateCapabilities = VTWAltViewTemplateCapabilities()
    var requestedTemplate: VTWAltViewContentTemplate?
    var capabilities: Set<String> = []
    var templateDetail: String { templateCapabilities.detail(requested: requestedTemplate) }
}

/// The intent is retained across blank/translation updates, and changes only for
/// an explicit publication. This prevents background updates from taking output.
nonisolated struct VTWAltViewSubmission: Sendable {
    let id = UUID()
    let connectionID: UUID
    let content: VTWAltViewDisplayContent?
    let intent: UUID?
}

nonisolated protocol VTWAltViewSending: AnyObject {
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID?, connectionID: UUID)
    func submit(_ submission: VTWAltViewSubmission)
    func updateEndpoint(_ endpoint: NWEndpoint, connectionID: UUID)
    func disconnect()
}

extension VTWAltViewSending {
    func updateEndpoint(_ endpoint: NWEndpoint, connectionID: UUID) {}
}

/// Mutable transport state belongs exclusively to queue. The only cross-queue
/// input is a bounded mailbox; encoding and socket work never run on the UI thread.
nonisolated final class VTWAltViewSenderClient: VTWAltViewSending, @unchecked Sendable {
    private let senderID = UUID()
    private let name: String
    private let queue = DispatchQueue(label: "suku.ViewTheWord.altview.sender", qos: .userInitiated)
    private var peer: VTWAltViewPeerChannel?
    private var endpoint: NWEndpoint?
    private var key: Data?
    private var expectedReceiverID: UUID?
    private var reconnectWork: DispatchWorkItem?
    private var attempts = 0
    private var hasConnected = false
    private var timer: DispatchSourceTimer?
    private var lease: UUID?
    private var revision: UInt64 = 0
    private var latest: VTWAltViewDisplayContent?
    private var lastIntent: UUID?
    // A cached lease can already be revoked. Retain explicit projection until
    // its snapshot is accepted or a fresh ownership grant resolves the request.
    private var pendingTake = false
    private var pendingProjectionRevision: UInt64?
    private enum GrantRequest { case take, resume }
    private var awaitingGrant: GrantRequest?
    private var wantsConnection = false
    private var restoreOwnership = false
    private var status = VTWAltViewSenderStatus()
    private let delivery: VTWAltViewSnapshotMailbox<VTWAltViewSenderStatus>
    private let inputLock = NSLock()
    private var submissions: VTWAltViewSnapshotMailbox<VTWAltViewSubmission>?

    init(name: String, callbackQueue: DispatchQueue = .main,
         onStatus: @escaping @Sendable (VTWAltViewSenderStatus) -> Void) {
        // Truncate by characters, preserving valid UTF-8 within the protocol bound.
        var name = name
        while name.utf8.count > 128 { name.removeLast() }
        self.name = name.isEmpty ? "ViewTheWord" : name
        delivery = VTWAltViewSnapshotMailbox(queue: callbackQueue, consume: onStatus)
    }
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID?, connectionID: UUID) {
        inputLock.lock()
        defer { inputLock.unlock() }
        // A mailbox per connection prevents a new destination's snapshot from
        // being drained by a job queued before that destination's connect command.
        submissions = VTWAltViewSnapshotMailbox(queue: queue) { [weak self] in self?.apply($0) }
        queue.async { [weak self] in
            guard let self else { return }
            self.disconnectOnQueue()
            self.status.connectionID = connectionID
            self.endpoint = endpoint; self.key = key; self.expectedReceiverID = expectedReceiverID
            self.wantsConnection = true
            self.openConnection()
        }
    }
    func updateEndpoint(_ endpoint: NWEndpoint, connectionID: UUID) {
        queue.async { [weak self] in
            guard let self, self.wantsConnection, self.status.connectionID == connectionID, self.endpoint != endpoint else { return }
            self.restoreOwnership = self.status.ownsOutput || self.restoreOwnership
            self.endpoint = endpoint
            self.stopTransport()
            self.openConnection()
        }
    }
    func submit(_ submission: VTWAltViewSubmission) {
        let mailbox = inputLock.withLock { submissions }
        mailbox?.offer(submission)
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
        lease = nil; awaitingGrant = nil; pendingProjectionRevision = nil
        status.connected = false; status.ownsOutput = false
        status.waitingToRetry = false
        status.feedback = VTWAltViewDeliveryFeedback()
        status.templateCapabilities = VTWAltViewTemplateCapabilities()
        status.capabilities = []
    }
    private func disconnectOnQueue() {
        wantsConnection = false; restoreOwnership = false; pendingTake = false
        hasConnected = false; latest = nil; lastIntent = nil; attempts = 0
        stopTransport()
        endpoint = nil; key = nil; expectedReceiverID = nil
        status = VTWAltViewSenderStatus()
    }
    private func apply(_ submission: VTWAltViewSubmission) {
        guard wantsConnection, submission.connectionID == status.connectionID else { return }
        guard let content = submission.content else { status.outputIssue = nil; stopOutput(); return }
        // Check escaped JSON size before taking output, as well as text bounds.
        guard content.isValid,
              (try? VTWAltViewFrameCodec.encode(VTWAltViewWireMessage(kind: .state, lease: UUID(), revision: UInt64.max, content: contentForSending(content)))) != nil else {
            stopOutput()
            lastIntent = submission.intent // A later automatic refresh still cannot take output.
            status.outputIssue = "VTWAltView text limit exceeded; remote output stopped."
            publish()
            return
        }
        if status.outputIssue != nil { status.outputIssue = nil; publish() }
        latest = content
        status.requestedTemplate = content.template
        status.submissionID = submission.id
        let explicit = submission.intent != nil && submission.intent != lastIntent
        lastIntent = submission.intent
        if explicit {
            status.rejectedPresentationIntent = nil
            pendingTake = true
            pendingProjectionRevision = nil
            requestPendingTake()
        }
        // Background updates preserve an existing request but cannot create one.
        // Without a pending explicit take, reconnect only resumes unowned output.
        sendLatest()
    }
    private func takeMessage() -> VTWAltViewWireMessage {
        var message = VTWAltViewWireMessage(kind: .take)
        if status.capabilities.contains(VTWAltViewProtocol.presentationIntent) { message.presentationIntent = lastIntent }
        return message
    }
    private func requestPendingTake() {
        guard pendingTake, lease == nil, status.connected else { return }
        guard validateLatestForSending() else { return }
        if awaitingGrant == .resume {
            // v2 cannot distinguish a refused resume from an unrelated
            // ownership broadcast. Retire that uncertain request before
            // taking explicitly, so its late grant cannot race the new take.
            stopTransport()
            restoreOwnership = false
            openConnection()
        } else if awaitingGrant == nil {
            awaitingGrant = .take
            peer?.discardPendingState()
            peer?.send(takeMessage())
        }
    }
    private func stopOutput() {
        latest = nil; lastIntent = nil; pendingTake = false; restoreOwnership = false
        pendingProjectionRevision = nil
        status.requestedTemplate = nil
        peer?.discardPendingState()
        if awaitingGrant != nil {
            // A take cannot be cancelled on the wire. Closing the socket invalidates a late grant.
            stopTransport()
            if wantsConnection { openConnection() }
        } else {
            if let lease { peer?.send(VTWAltViewWireMessage(kind: .release, lease: lease)) }
            lease = nil; status.ownsOutput = false
            status.feedback.resetSnapshot()
            if status.connected { status.message = "Connected · waiting for projection" }
            publish()
        }
    }
    private func openConnection() {
        guard wantsConnection, let endpoint, let key else { return }
        status.message = hasConnected ? "Reconnecting…" : "Connecting…"
        status.waitingToRetry = false
        status.failureReason = nil
        publish()
        let peer = VTWAltViewPeerChannel(connection: NWConnection(to: endpoint, using: VTWAltViewSecureConnection.parameters(key: key)),
                                      queue: queue, connectionTimeout: VTWAltViewProtocol.connectionAttemptTimeout)
        self.peer = peer
        peer.onReady = { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            peer.send(VTWAltViewWireMessage(kind: .hello, senderID: self.senderID, name: self.name, capabilities: VTWAltViewProtocol.capabilities))
            self.queue.asyncAfter(deadline: .now() + VTWAltViewProtocol.timeout) { [weak self, weak peer] in
                guard let self, let peer, self.peer === peer, !self.status.connected else { return }
                peer.close("Receiver did not complete the handshake.", retryable: true)
            }
        }
        peer.onMessage = { [weak self, weak peer] message in
            guard let self, let peer, self.peer === peer else { return }
            self.handle(message)
        }
        peer.onClose = { [weak self, weak peer] reason in
            guard let self, let peer, self.peer === peer else { return }
            self.restoreOwnership = self.status.ownsOutput || self.restoreOwnership
            self.peer = nil; self.lease = nil; self.awaitingGrant = nil; self.pendingProjectionRevision = nil
            self.status.connected = false; self.status.ownsOutput = false
            self.status.feedback = VTWAltViewDeliveryFeedback()
            self.status.templateCapabilities = VTWAltViewTemplateCapabilities()
            self.status.capabilities = []
            self.timer?.cancel(); self.timer = nil
            guard peer.retryableFailure else {
                self.fail(reason ?? "The receiving Mac rejected the connection.")
                return
            }
            self.scheduleReconnect()
        }
        peer.start()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self, weak peer] in
            guard let self, let peer, self.peer === peer else { return }
            if self.status.connected { peer.send(VTWAltViewWireMessage(kind: .heartbeat)) }
            if self.status.feedback.checkTimeout(now: ProcessInfo.processInfo.systemUptime) { self.publish() }
            peer.checkTimeout(now: ProcessInfo.processInfo.systemUptime)
        }
        self.timer = timer; timer.resume()
    }
    private func handle(_ message: VTWAltViewWireMessage) {
        guard message.isValidReceiverMessage else { fail("Invalid VTWAltView response."); return }
        switch message.kind {
        case .welcome:
            guard !status.connected, let receiverID = message.receiverID else { fail("Invalid welcome."); return }
            if let expectedReceiverID, expectedReceiverID != receiverID { fail("Receiver identity changed. Enter its code to pair again."); return }
            status.feedback = VTWAltViewDeliveryFeedback()
            status.templateCapabilities = VTWAltViewTemplateCapabilities(templates: message.templates, policy: message.templatePolicy)
            status.capabilities = Set(message.capabilities ?? []).intersection(VTWAltViewProtocol.capabilities)
            expectedReceiverID = receiverID
            hasConnected = true; attempts = 0
            status.connected = true; status.receiverID = receiverID; status.ownerName = message.ownerName
            status.message = message.ownerName.map { "Connected · output controlled by \($0)" } ?? "Connected · waiting for projection"
            // A queued snapshot was checked before capabilities were known.
            // Reject it before take/resume can clear another sender's output.
            guard validateLatestForSending() else { return }
            if pendingTake, latest != nil {
                awaitingGrant = .take; peer?.send(takeMessage())
            } else if restoreOwnership, latest != nil, message.ownerID == nil {
                awaitingGrant = .resume; peer?.send(VTWAltViewWireMessage(kind: .resume))
            } else { restoreOwnership = false }
            publish()
        case .granted:
            guard status.connected, let lease = message.lease else { fail("Unexpected VTWAltView grant."); return }
            guard awaitingGrant != nil else {
                // A superseded intent may still receive an in-flight grant.
                peer?.send(VTWAltViewWireMessage(kind: .release, lease: lease)); return
            }
            // The granted lease may be revoked before its first state arrives.
            // Keep the current explicit request until its revision is accepted.
            pendingProjectionRevision = nil
            awaitingGrant = nil; self.lease = lease; revision = 0
            status.feedback.resetSnapshot()
            status.ownsOutput = true; restoreOwnership = true
            status.message = "Sending projected verse"
            sendLatest(); publish()
        case .ownership:
            guard status.connected else { fail("Ownership before welcome."); return }
            status.ownerName = message.ownerName
            if message.ownerID != senderID || message.lease != lease {
                lease = nil; status.ownsOutput = false; pendingProjectionRevision = nil
                if awaitingGrant != .resume || message.ownerID != nil { restoreOwnership = false }
                status.feedback.resetSnapshot()
                // Broadcasts are unsolicited, including when an idle sender
                // disconnects. They cannot settle a pending take or resume;
                // a valid grant may still follow on this connection.
                peer?.discardPendingState()
                status.message = message.ownerName.map { "Output controlled by \($0)" } ?? "Connected · waiting for projection"
                requestPendingTake()
            }
            publish()
        case .feedback:
            if let rejected = message.rejectedPresentationIntent, rejected == lastIntent {
                status.rejectedPresentationIntent = rejected
                pendingTake = false; pendingProjectionRevision = nil; awaitingGrant = nil
                restoreOwnership = false; lease = nil; status.ownsOutput = false
                peer?.discardPendingState()
                status.message = "Connected · presentation superseded by the hub"
            }
            guard status.connected, message.outputReadiness != nil,
                  (message.lease == nil && message.revision == nil) || (message.lease != nil && message.revision.map { $0 > 0 } == true) else {
                peer?.close("Unexpected output feedback."); return
            }
            status.templateCapabilities = VTWAltViewTemplateCapabilities(templates: message.templates, policy: message.templatePolicy)
            status.feedback.receive(message, lease: lease, now: ProcessInfo.processInfo.systemUptime)
            if let pendingProjectionRevision, status.feedback.acceptedRevision >= pendingProjectionRevision {
                pendingTake = false
                self.pendingProjectionRevision = nil
            }
            publish()
        case .heartbeat: break
        case .error: fail(message.detail ?? "VTWAltView rejected the message.")
        default: fail("Unexpected VTWAltView response.")
        }
    }
    private func sendLatest() {
        guard let latest, let lease, status.connected else { return }
        guard revision < UInt64.max else { fail("Session revision exhausted. Connect again."); return }
        guard validateLatestForSending() else { return }
        let content = contentForSending(latest)
        revision += 1
        if pendingTake, pendingProjectionRevision == nil { pendingProjectionRevision = revision }
        status.feedback.sent(revision, now: ProcessInfo.processInfo.systemUptime)
        peer?.send(stateMessage(content: content, lease: lease, revision: revision))
        publish()
    }
    private func stateMessage(content: VTWAltViewDisplayContent, lease: UUID, revision: UInt64) -> VTWAltViewWireMessage {
        var message = VTWAltViewWireMessage(kind: .state, lease: lease, revision: revision, content: content)
        if status.capabilities.contains(VTWAltViewProtocol.presentationIntent) { message.presentationIntent = lastIntent }
        return message
    }
    private func validateLatestForSending() -> Bool {
        guard let latest else { return true }
        guard latest.isValid,
              (try? VTWAltViewFrameCodec.encode(stateMessage(content: contentForSending(latest), lease: UUID(), revision: UInt64.max))) != nil else {
            let intent = lastIntent
            stopOutput(); lastIntent = intent
            status.outputIssue = "VTWAltView text limit exceeded; remote output stopped."
            publish()
            return false
        }
        return true
    }
    private func contentForSending(_ snapshot: VTWAltViewDisplayContent) -> VTWAltViewDisplayContent {
        var content = status.templateCapabilities.contentForSending(snapshot)
        if !status.capabilities.contains(VTWAltViewProtocol.textSource) { content.sourceKind = nil }
        return content
    }
    private func scheduleReconnect() {
        guard wantsConnection else { return }
        let delay = Self.reconnectDelay(attempt: attempts)
        attempts = min(attempts + 1, 5)
        status.waitingToRetry = true
        status.message = "VTWAltView is unavailable. Retrying in \(Int(delay)) seconds. Check that VTWAltView is receiving and Local Network access is allowed."
        publish()
        let id = status.connectionID
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.wantsConnection, self.status.connectionID == id, self.peer == nil else { return }
            self.reconnectWork = nil; self.openConnection()
        }
        reconnectWork = work; queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    static func reconnectDelay(attempt: Int) -> TimeInterval {
        min(30, pow(2, Double(min(max(attempt, 0), 5))))
    }
    private func fail(_ reason: String) {
        wantsConnection = false; restoreOwnership = false; pendingTake = false
        stopTransport()
        status.failureReason = reason; status.message = reason
        publish()
    }
    private func publish() { delivery.offer(status) }
}
