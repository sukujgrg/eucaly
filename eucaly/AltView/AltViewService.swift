import AppKit
import Combine
import Foundation

/// One app-owned sender. Local projection never waits for this service, its
/// transport, discovery, Keychain, or receiver acknowledgements.
@MainActor
final class AltViewService: ObservableObject {
    @Published private(set) var status = AltViewSenderStatus()
    @Published private(set) var receivers: [AltViewDestination] = []
    @Published private(set) var discoveryNotice: String?
    @Published private(set) var connectionNotice: String?
    @Published private(set) var persistenceNotice: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var destination: AltViewDestination?
    @Published private(set) var submitted: AltViewDisplayContent?
    @Published private(set) var selectedTemplate: AltViewContentTemplate? = .lyrics

    private var confidenceText: AltViewConfidenceText?
    private var discoveryVisible = false
    private var discoveryRunning = false
    private let defaults: UserDefaults
    private let pairingStore: AltViewPairingStoring
    private let restorePreferences: Bool
    private var didRestoreConnection = false
    private let senderFactory: (@escaping (AltViewSenderStatus) -> Void) -> AltViewSending
    private var sender: AltViewSending?
    private var startedSender = false
    private lazy var discovery = AltViewReceiverDiscovery { [weak self] receivers, notice in
        MainActor.assumeIsolated {
            self?.receiveDiscovered(receivers.compactMap(AltViewDestination.init), notice: notice)
        }
    }
    private var connectionID: UUID?
    private var pairingKey: Data?
    private var savedThisConnection = false
    private var activeSourceID: UUID?
    private var pendingTake = false
    private var submissionID: UUID?
    private var submittedSlideID: UUID?

    init(defaults: UserDefaults = .standard, restorePreferences: Bool = true,
         pairingStore: AltViewPairingStoring = AltViewPairingStore(),
         senderFactory: ((@escaping (AltViewSenderStatus) -> Void) -> AltViewSending)? = nil) {
        self.defaults = defaults
        self.pairingStore = pairingStore
        self.restorePreferences = restorePreferences
        if restorePreferences, let raw = defaults.string(forKey: "altViewTemplate") {
            if raw.isEmpty { selectedTemplate = nil }
            else if AltViewContentTemplate(rawValue: raw).isValid { selectedTemplate = .init(rawValue: raw) }
        }
        if restorePreferences, let data = defaults.data(forKey: "altViewDestination") {
            let saved = try? JSONDecoder().decode(AltViewDestination.self, from: data)
            destination = saved?.isValid == true ? saved : nil
        }
        self.senderFactory = senderFactory ?? { callback in
            let senderID = defaults.string(forKey: "altViewSenderID").flatMap(UUID.init(uuidString:)) ?? UUID()
            defaults.set(senderID.uuidString, forKey: "altViewSenderID")
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

    /// Restoring a paired connection never takes output or publishes Current.
    func restoreConnection() {
        guard restorePreferences, !didRestoreConnection else { return }
        didRestoreConnection = true
        if let destination { connect(to: destination, code: "") }
    }

    func selectTemplate(_ template: AltViewContentTemplate?) {
        guard template?.isValid ?? true else { return }
        selectedTemplate = template
        defaults.set(template?.rawValue ?? "", forKey: "altViewTemplate")
    }

    func startDiscovery() { discoveryVisible = true; refreshDiscovery() }
    func stopDiscovery() { discoveryVisible = false; refreshDiscovery() }
    private func refreshDiscovery() {
        let needed = discoveryVisible || (hasConnection && destination?.localReceiverID != nil)
        guard needed != discoveryRunning else { return }
        discoveryRunning = needed
        if needed { discovery.start() } else { discovery.stop() }
    }
    func receiveDiscovered(_ receivers: [AltViewDestination], notice: String?) {
        self.receivers = receivers; discoveryNotice = notice
        guard let id = destination?.localReceiverID,
              let fresh = receivers.first(where: { $0.localReceiverID == id }) else { return }
        destination = fresh
        if startedSender, let connectionID { sender?.updateEndpoint(fresh.endpoint, connectionID: connectionID) }
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
            connectionNotice = "Enter the eight-character code shown in AltView."
            return
        }
        disconnect()
        self.destination = destination
        let id = UUID()
        connectionID = id
        isConnecting = true
        refreshDiscovery()
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
                    guard let credentials else {
                        self.isConnecting = false
                        self.connectionID = nil
                        self.connectionNotice = notice ?? "Enter the pairing code shown in AltView."
                        return
                    }
                    self.beginConnection(destination, key: credentials.key, receiverID: credentials.receiverID, id: id)
                }
            }
        }
    }

    private func beginConnection(_ destination: AltViewDestination, key: Data, receiverID: UUID?, id: UUID) {
        pairingKey = key
        startedSender = true
        sender?.connect(to: self.destination?.endpoint ?? destination.endpoint, key: key, expectedReceiverID: receiverID ?? destination.localReceiverID, connectionID: id)
        // Show/navigation can arrive while a saved pairing is being read. Keep
        // that snapshot in the service until its connection mailbox exists.
        if let submitted, let submissionID { sender?.submit(submitted, submissionID: submissionID) }
    }

    func disconnect() {
        didRestoreConnection = true
        connectionID = nil; pairingKey = nil; savedThisConnection = false
        isConnecting = false; activeSourceID = nil; pendingTake = false
        submitted = nil; submissionID = nil; submittedSlideID = nil; confidenceText = nil
        startedSender = false
        sender?.disconnect()
        status = AltViewSenderStatus()
        refreshDiscovery()
    }

    func attach(_ session: PresentationSession) {
        let id = session.outputSourceID
        session.onOutputEvent = { [weak self] event in self?.handle(event, from: id) }
    }

    func detach(_ session: PresentationSession) {
        session.onOutputEvent = nil
        if activeSourceID == session.outputSourceID { stopSending() }
    }

    func sendCurrent(from session: PresentationSession) {
        guard session.isPresenting, session.areSlidesVisible else { return }
        publish(session.outputSnapshot, from: session.outputSourceID)
    }

    func stopSending() {
        activeSourceID = nil; pendingTake = false
        submitted = nil; submissionID = nil; submittedSlideID = nil; confidenceText = nil
        guard hasConnection else { return }
        sender?.releaseOutput()
        status.ownsOutput = false; status.followingOutput = false
        status.submissionID = nil; status.feedback.resetSnapshot()
    }

    func handle(_ event: PresentationOutputEvent, from sourceID: UUID) {
        switch event {
        case .show(let snapshot), .project(let snapshot):
            publish(snapshot, from: sourceID)
        case .changed(let snapshot):
            guard activeSourceID == sourceID else { return }
            if !snapshot.isPresenting { stopSending(); return }
            // Hiding during initial pairing cancels the queued takeover.
            if isConnecting && !snapshot.slidesVisible { pendingTake = false }
            submit(snapshot)
        case .stopped:
            if activeSourceID == sourceID { stopSending() }
        }
    }

    private func publish(_ snapshot: PresentationOutputSnapshot, from sourceID: UUID) {
        guard hasConnection, snapshot.isPresenting, snapshot.slidesVisible else { return }
        activeSourceID = sourceID
        submit(snapshot, explicit: true)
        if status.connected { sender?.takeOutput() }
        else { pendingTake = true }
        // A user projection made during reconnect still authorizes takeover.
    }

    private func submit(_ snapshot: PresentationOutputSnapshot, explicit: Bool = false) {
        var content = AltViewPresentationAdapter.content(for: snapshot)
        if explicit || (content.body.isEmpty && snapshot.slide == nil) {
            confidenceText = AltViewConfidenceText(title: content.title, body: content.body, footer: content.footer)
        }
        content.confidence = confidenceText?.hasText == true ? confidenceText : nil
        let changedSlide = submittedSlideID != snapshot.slide?.id || submitted?.body != content.body
        // A settings edit is a private choice. Hiding/reconnecting the existing
        // slide retains its request; the next slide or explicit Show adopts it.
        if !content.body.isEmpty {
            content.template = explicit || changedSlide ? selectedTemplate : submitted?.template
        }
        submittedSlideID = snapshot.slide?.id
        guard explicit || content != submitted else { return }
        submitted = content
        let id = UUID()
        submissionID = id
        if startedSender { sender?.submit(content, submissionID: id) }
    }

    func receive(_ status: AltViewSenderStatus) {
        guard let connectionID, status.connectionID == connectionID else { return }
        self.status = status
        if status.connected {
            isConnecting = false
            if !savedThisConnection, let receiverID = status.receiverID, let pairingKey, let destination {
                savedThisConnection = true
                if let data = try? JSONEncoder().encode(destination) { defaults.set(data, forKey: "altViewDestination") }
                pairingStore.save(AltViewCredentials(key: pairingKey, receiverID: receiverID), for: destination) { [weak self] notice in
                    MainActor.assumeIsolated {
                        guard self?.connectionID == connectionID else { return }
                        self?.persistenceNotice = notice
                    }
                }
            }
            if pendingTake {
                pendingTake = false
                sender?.takeOutput()
            }
        } else if isConnecting && status.failureReason != nil {
            isConnecting = false; pendingTake = false; activeSourceID = nil
        }
    }
}
