import Foundation
import Combine

@MainActor
final class ExternalPresentationReceiver: ObservableObject {
    let coordinator: OutputCoordinator
    private let credentials: any ExternalCredentialStoring
    private var connections = Set<UUID>()
    private var server: ExternalPresentationServer?
    private var startTask: Task<Void, Never>?
    private var generation = UUID()
    @Published private(set) var port: UInt16?
    @Published private(set) var issue: String?
    var enabled: Bool { coordinator.profiles.document.receiverEnabled }

    init(coordinator: OutputCoordinator, credentials: any ExternalCredentialStoring = ExternalCredentialStore()) {
        self.coordinator = coordinator; self.credentials = credentials
    }
    func setEnabled(_ enabled: Bool) {
        coordinator.profiles.edit { $0.receiverEnabled = enabled }
        if enabled { startIfEnabled() } else { stop() }
    }
    func startIfEnabled() {
        guard enabled, server == nil, startTask == nil else { return }
        generation = UUID(); let generation = generation, credentials = credentials
        startTask = Task { [weak self] in
            do {
                let key = try await Task.detached { try credentials.loadOrCreate() }.value
                guard !Task.isCancelled, let self, self.generation == generation, self.enabled else { return }
                let actionClock = self.coordinator.actionClock
                let server = ExternalPresentationServer(credential: key, recordAction: { actionClock.next() }, intent: { [weak self] id, name, message in
                    guard self?.generation == generation else { return }
                    self?.handle(id: id, name: name, message: message)
                }, disconnected: { [weak self] id in
                    guard self?.generation == generation else { return }
                    self?.connections.remove(id)
                    self?.coordinator.externalDisconnected(id)
                }, status: { [weak self] port, error in
                    guard let self, self.generation == generation else { return }
                    self.port = port; self.issue = error
                })
                self.server = server; self.startTask = nil
                self.coordinator.onReadinessChange = { [weak self] in self?.broadcastFeedback() }
                server.start()
            } catch {
                guard let self, self.generation == generation else { return }
                self.issue = "Receiver credential could not be loaded from Keychain."
                self.startTask = nil
            }
        }
    }
    func stop() {
        generation = UUID(); startTask?.cancel(); startTask = nil
        server?.stop(); server = nil; port = nil
        // Server callbacks from a retired generation cannot mutate a new source.
        for id in connections { coordinator.externalDisconnected(id) }
        connections.removeAll()
        coordinator.onReadinessChange = nil
    }
    func copyCredential(_ copied: @escaping (String?) -> Void) {
        let credentials = credentials
        Task {
            let result = try? await Task.detached { try credentials.loadOrCreate() }.value
            copied(result)
        }
    }
    private func handle(id: UUID, name: String, message: ExternalPresentationMessage) {
        do {
            switch message.kind {
            case .hello:
                connections.insert(id)
                server?.send(coordinator.discoveryReply(), to: id)
            case .present:
                let lease = try coordinator.presentExternal(connection: id, name: name, message: message)
                server?.send(.init(kind: "accepted", actionID: message.actionID, lease: lease, revision: message.revision,
                                   destinations: coordinator.destinationStatuses(), ownsOutput: true), to: id)
            case .state:
                guard coordinator.updateExternal(connection: id, message: message) else { throw ExternalPresentationError.invalid("Stale revision or displaced lease") }
                server?.send(.init(kind: "feedback", lease: message.lease, revision: message.revision, destinations: coordinator.destinationStatuses(), ownsOutput: true), to: id)
            case .hide, .clear, .release:
                guard coordinator.externalControl(connection: id, message: message) else { throw ExternalPresentationError.invalid("Displaced lease") }
                server?.send(.init(kind: "accepted", actionID: message.actionID, revision: message.revision, ownsOutput: false), to: id)
            }
        } catch {
            server?.send(.init(kind: "rejected", actionID: message.actionID, revision: message.revision,
                               detail: (error as? ExternalPresentationError)?.detail ?? "Invalid request", destinations: coordinator.destinationStatuses(), ownsOutput: false), to: id)
        }
    }
    private func broadcastFeedback() {
        // Per-connection authority is reported with correlated state feedback;
        // general readiness never implies a lease grant or physical delivery.
        server?.broadcast(.init(kind: "readiness", destinations: coordinator.destinationStatuses()))
        let owner: UUID?
        if case .external(let id, _) = coordinator.ownership.source { owner = id } else { owner = nil }
        server?.reportOwnership(owner: owner, lease: coordinator.ownership.lease)
    }
    deinit { startTask?.cancel(); server?.stop() }
}
