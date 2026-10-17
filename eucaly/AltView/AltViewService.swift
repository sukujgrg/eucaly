import AppKit
import Combine
import Foundation

/// One receiver channel. Local projection never waits for this service, its
/// transport, discovery, Keychain, or receiver acknowledgements.
@MainActor
final class AltViewService: ObservableObject {
    @Published private(set) var status = AltViewSenderStatus()
    @Published private(set) var receivers: [AltViewDestination] = []
    @Published private(set) var discoveryNotice: String?
    @Published private(set) var connectionNotice: String?
    @Published private(set) var persistenceNotice: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var requiresPairingCode = false
    @Published private(set) var destination: AltViewDestination?
    @Published private(set) var submitted: AltViewDisplayContent?

    var onStatusChange: (() -> Void)?
    private let pairingStore: AltViewPairingStoring
    private let senderFactory: (@escaping (AltViewSenderStatus) -> Void) -> AltViewSending
    private var sender: AltViewSending?
    private var startedSender = false
    private var connectionID: UUID?
    private var pairingKey: Data?
    private var pairedReceiverID: UUID?
    private var savedThisConnection = false
    private var savedMedia: AltViewMediaOffer?
    private var activeSourceID: UUID?
    private var pendingTake: AltViewSubmission?
    private var submissionID: UUID?

    init(defaults: UserDefaults = .standard, senderIdentity: UUID? = nil,
         pairingStore: AltViewPairingStoring = AltViewPairingStore(),
         senderFactory: ((@escaping (AltViewSenderStatus) -> Void) -> AltViewSending)? = nil) {
        self.pairingStore = pairingStore
        self.senderFactory = senderFactory ?? { callback in
            let senderID = senderIdentity ?? defaults.string(forKey: "altViewSenderID").flatMap(UUID.init(uuidString:)) ?? UUID()
            if senderIdentity == nil { defaults.set(senderID.uuidString, forKey: "altViewSenderID") }
            var name = "eucaly · \(Host.current().localizedName ?? "Presentation Mac")"
            while name.utf8.count > 128 { name.removeLast() }
            return AltViewSenderClient(name: name, senderID: senderID, onStatus: callback)
        }
    }

    var hasConnection: Bool { connectionID != nil }
    var isSending: Bool { activeSourceID != nil }
    var needsAttention: Bool {
        status.contentError != nil || status.feedback.overdue
            || (isSending && !status.connected && !isConnecting)
            || (status.ownsOutput && status.feedback.output.map { $0 != .ready } == true)
    }
    var latestAccepted: Bool {
        submissionID != nil && status.contentError == nil && status.submissionID == submissionID && status.feedback.accepted
    }
    var deliveryDetail: String {
        if let error = status.contentError { return error }
        let acceptance: String
        if submitted == nil { acceptance = "No text submitted." }
        else if latestAccepted { acceptance = "Latest snapshot accepted by AltView." }
        else if status.feedback.overdue { acceptance = "Acknowledgement delayed; sending continues." }
        else { acceptance = "Waiting for the latest snapshot acknowledgement." }
        return "\(acceptance) \(status.feedback.output?.summary ?? "Waiting for output status")."
    }

    var detail: String {
        var parts = [isConnecting ? "Connecting securely…" : status.message]
        if status.connected || submitted != nil { parts.append(deliveryDetail) }
        if status.connected { parts.append(status.templateCapabilities.policyDetail) }
        parts.append(contentsOf: [connectionNotice, persistenceNotice].compactMap { $0 })
        return parts.joined(separator: "\n")
    }

    func receiveDiscovered(_ receivers: [AltViewDestination], notice: String?) {
        self.receivers = receivers.filter(\.isValid); discoveryNotice = notice
        guard let id = destination?.receiverIdentity,
              let fresh = self.receivers.first(where: { $0.receiverIdentity == id }) else { return }
        destination = fresh
        guard let connectionID else { return }
        if startedSender { sender?.updateEndpoint(fresh.endpoint, connectionID: connectionID) }
        else { startSenderIfReady(id: connectionID) }
    }
    /// Pairing is always connect-only. A later Show Slides or toolbar action is
    /// the separate, explicit authorization to take the receiver's output.
    func connect(to destination: AltViewDestination, code: String) {
        guard destination.isValid else {
            connectionNotice = "Enter a receiving Mac name or IP address and a port from 1 to 65535."
            return
        }
        let typedCode = !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let key = AltViewPairingKey.parse(code)
        guard !typedCode || key != nil else {
            requiresPairingCode = false
            connectionNotice = "Enter the eight-character code shown in AltView."
            return
        }
        disconnect()
        self.destination = destination
        let id = UUID()
        connectionID = id
        isConnecting = true
        connectionNotice = nil; persistenceNotice = nil
        if sender == nil {
            sender = senderFactory { [weak self] status in
                MainActor.assumeIsolated { self?.receive(status) }
            }
        }
        if let key {
            beginConnection(destination, key: key, receiverID: nil, id: id)
        } else {
            pairingStore.read(destination) { [weak self] credentials, notice in
                MainActor.assumeIsolated {
                    guard let self, self.connectionID == id else { return }
                    defer { self.onStatusChange?() }
                    guard let credentials else {
                        self.isConnecting = false
                        self.connectionID = nil
                        self.requiresPairingCode = notice == nil
                        self.connectionNotice = notice ?? "Enter the pairing code shown in AltView."
                        return
                    }
                    self.beginConnection(destination, key: credentials.key, receiverID: credentials.receiverID, id: id)
                }
            }
        }
    }

    private func beginConnection(_ destination: AltViewDestination, key: Data, receiverID: UUID?, id: UUID) {
        guard receiverID == nil || destination.receiverIdentity == nil || receiverID == destination.receiverIdentity else {
            connectionID = nil; isConnecting = false
            connectionNotice = "Saved receiver identity differs. Select the receiver and enter its code again."
            return
        }
        pairingKey = key
        pairedReceiverID = receiverID ?? destination.receiverIdentity
        startSenderIfReady(id: id)
    }

    private func startSenderIfReady(id: UUID) {
        guard connectionID == id, !startedSender, let pairingKey, let destination else { return }
        let resolved: AltViewDestination
        if let localID = destination.receiverIdentity {
            guard let fresh = receivers.first(where: { $0.receiverIdentity == localID }) else {
                connectionNotice = "Waiting for the selected AltView receiver. Its current service will be discovered automatically."
                return
            }
            resolved = fresh
        } else { resolved = destination }
        self.destination = resolved
        connectionNotice = nil
        startedSender = true
        sender?.connect(to: resolved.endpoint, key: pairingKey, expectedReceiverID: pairedReceiverID, connectionID: id)
        // Show/navigation can arrive while a saved pairing is being read. Keep
        // that snapshot in the service until its connection mailbox exists.
        if let submitted, let submissionID { sender?.submit(submitted, submissionID: submissionID) }
    }

    func disconnect() {
        connectionID = nil; pairingKey = nil; pairedReceiverID = nil; savedThisConnection = false; savedMedia = nil
        isConnecting = false; requiresPairingCode = false; activeSourceID = nil; pendingTake = nil
        connectionNotice = nil
        submitted = nil; submissionID = nil
        startedSender = false
        sender?.disconnect()
        status = AltViewSenderStatus()
    }

    func stopSending() {
        activeSourceID = nil; pendingTake = nil
        submitted = nil; submissionID = nil
        guard hasConnection else { return }
        sender?.releaseOutput()
        status.ownsOutput = false; status.followingOutput = false
        status.submissionID = nil; status.feedback.resetSnapshot()
    }
    func cancelPendingPresentation() {
        pendingTake = nil
        if startedSender { sender?.cancelPendingPresentation() }
    }

    /// The coordinator provides eucaly's coherent live program. A native window
    /// is not needed to authorize its direct AltView text destination.
    func publishProgram(_ content: AltViewDisplayContent, sourceID: UUID, explicit: Bool) {
        guard hasConnection else { return }
        if explicit { activeSourceID = sourceID }
        guard activeSourceID != nil else { return }
        guard explicit || content != submitted else { return }
        submitted = content
        let id = UUID(); submissionID = id
        if startedSender { sender?.submit(content, submissionID: id) }
        if explicit {
            let request = AltViewSubmission(id: id, content: content)
            if status.connected { sender?.takeOutput(submission: request) }
            else { pendingTake = request }
        }
    }

    func receive(_ status: AltViewSenderStatus) {
        guard let connectionID, status.connectionID == connectionID else { return }
        self.status = status
        defer { onStatusChange?() }
        if status.connected {
            isConnecting = false
            if (!savedThisConnection || savedMedia != status.media), let receiverID = status.receiverID, let pairingKey, let destination {
                savedThisConnection = true; savedMedia = status.media
                pairingStore.save(AltViewCredentials(key: pairingKey, receiverID: receiverID, media: status.media), for: destination) { [weak self] notice in
                    MainActor.assumeIsolated {
                        guard self?.connectionID == connectionID else { return }
                        self?.persistenceNotice = notice
                        self?.onStatusChange?()
                    }
                }
            }
            if let pendingTake {
                self.pendingTake = nil
                sender?.takeOutput(submission: pendingTake)
            }
        } else if isConnecting && status.failureReason != nil {
            isConnecting = false; pendingTake = nil; activeSourceID = nil
        }
    }
}
