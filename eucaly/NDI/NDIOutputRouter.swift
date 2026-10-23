import AppKit
import Combine

typealias NetworkOutputState = NDIOutputState
typealias NetworkOutputDriving = NDIOutputDriving
typealias NetworkOutputRouter = NDIOutputRouter

nonisolated enum NDIOutputState: Equatable, Sendable {
    case stopped, starting, publishing, sending(Int), stopping(String?), failed(String)
    var title: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .stopping(let reason): reason.map { "Stopping · " + $0 } ?? "Stopping…"
        case .publishing: "Publishing · No receivers"
        case .sending(let count): "Sending · \(count) receiver\(count == 1 ? "" : "s")"
        case .failed(let reason): reason
        }
    }
    func title(for technology: NetworkOutputTechnology) -> String {
        if technology == .omt {
            if case .publishing = self { return "Publishing · No connections" }
            if case .sending(let count) = self { return "Sending · \(count) connection\(count == 1 ? "" : "s")" }
        }
        return title
    }
    var active: Bool {
        switch self { case .starting, .publishing, .sending: true; case .stopped, .stopping, .failed: false }
    }
    var failureReason: String? {
        switch self { case .failed(let reason): reason; case .stopping(let reason): reason; default: nil }
    }
    var canStart: Bool {
        switch self { case .stopped, .failed: true; default: false }
    }
}

@MainActor
protocol NDIOutputDriving: AnyObject {
    var stateChanged: ((UUID, NDIOutputState) -> Void)? { get set }
    var activeIDs: Set<UUID> { get }
    func state(_ id: UUID) -> NDIOutputState
    func performanceNotice(_ id: UUID) -> String?
    func start(_ destination: OutputDestinationConfiguration) -> Bool
    func stop(_ id: UUID)
    func reconcile(_ document: OutputProfileDocument)
    func publish(_ snapshot: OutputContentSnapshot, document: OutputProfileDocument, media: OutputMediaRuntime,
                 audioSession: PresentationSession?)
}

extension NDIOutputDriving {
    func performanceNotice(_ id: UUID) -> String? { nil }
}

nonisolated protocol NDISenderDriving: AnyObject, Sendable {
    func startSender(generation: UUID, configuration: NDIHelperConfiguration)
    func selectContent(epoch: UInt64)
    func renderMedia(_ submission: NDIMediaSubmission)
    func sendAudio(_ block: NDIAudioBlock, generation: UUID, contentEpoch: UInt64)
    func stop()
    func stopAndWait() async
}

extension NDIHelperSupervisor: NDISenderDriving {
    nonisolated func startSender(generation: UUID, configuration: NDIHelperConfiguration) { start(generation: generation, configuration: configuration) }
}

/// App-owned; constructing/restoring this router creates no helper, SDK or
/// network source. A generation remains retained until its exact child exits.
@MainActor
final class NDIOutputRouter: ObservableObject, NDIOutputDriving {
    var stateChanged: ((UUID, NDIOutputState) -> Void)?
    @Published private(set) var states: [UUID: NDIOutputState] = [:]
    @Published private(set) var statistics: [UUID: NDIHelperStatus] = [:]
    private final class Entry {
        let generation = UUID()
        let supervisor: any NDISenderDriving
        let technology: NetworkOutputTechnology
        var settings: NDIOutputSettings
        var ready = false
        var retiring = false
        let route = NDIContentRoute()
        let audio: NDIProgramAudio
        var media: OutputMediaFrameBroker?
        init(settings: NDIOutputSettings, technology: NetworkOutputTechnology, supervisor: any NDISenderDriving, musicRoute: NDIMusicRoute) {
            self.settings = settings; self.technology = technology; self.supervisor = supervisor; audio = NDIProgramAudio(musicRoute: musicRoute)
        }
    }
    private var entries: [UUID: Entry] = [:]
    private let musicRoute = NDIMusicRoute()
    private var shuttingDown = false
    private let sleep: ProjectionSleepPrevention
    private let senderFactory: @MainActor (@escaping @Sendable (NDIHelperSupervisor.Event) -> Void) -> any NDISenderDriving
    init(sleep: ProjectionSleepPrevention = ProjectionSleepPrevention(preventsDisplaySleep: false),
         senderFactory: @escaping @MainActor (@escaping @Sendable (NDIHelperSupervisor.Event) -> Void) -> any NDISenderDriving = { NDIHelperSupervisor(event: $0) }) {
        self.sleep = sleep; self.senderFactory = senderFactory
    }
    var activeIDs: Set<UUID> { Set(entries.keys.filter { states[$0]?.active == true && entries[$0]?.retiring == false }) }
    func state(_ id: UUID) -> NDIOutputState { states[id] ?? .stopped }
    func performanceNotice(_ id: UUID) -> String? { state(id).active ? statistics[id]?.performanceNotice : nil }
    func start(_ destination: OutputDestinationConfiguration) -> Bool {
        guard !shuttingDown, destination.enabled, let settings = destination.networkSettings,
              let technology = destination.networkTechnology, settings.isValid else { return false }
        if let entry = entries[destination.id] {
            return !entry.retiring && state(destination.id).active && entry.technology == technology
                && !settings.requiresRestart(comparedTo: entry.settings)
        }
        let id = destination.id
        let supervisor = senderFactory { [weak self] event in
            Task { @MainActor [weak self] in self?.receive(event, id: id) }
        }
        let entry = Entry(settings: settings, technology: technology, supervisor: supervisor, musicRoute: musicRoute)
        entry.audio.sourceFailed = { [weak self, weak entry] reason in
            guard let self, let entry, self.entries[id] === entry, !entry.retiring else { return }
            self.fail(id, reason)
        }
        entries[id] = entry; statistics[id] = nil; setState(.starting, for: id)
        supervisor.startSender(generation: entry.generation, configuration: .init(purpose: .sender, sourceName: settings.sourceName, technology: technology))
        return true
    }
    func stop(_ id: UUID) {
        guard let entry = entries[id], !entry.retiring else { return }
        entry.retiring = true; entry.route.invalidate(); entry.media?.stop(); entry.media = nil; entry.supervisor.stop()
        entry.audio.stop()
        setState(.stopping(nil), for: id)
    }
    func shutdown() async {
        shuttingDown = true
        let retiring = entries
        for id in retiring.keys { stop(id) }
        await withTaskGroup(of: Void.self) { group in
            for supervisor in retiring.values.map(\.supervisor) {
                group.addTask { await supervisor.stopAndWait() }
            }
        }
        // The supervisor confirms exit before returning. Its MainActor event
        // may still be queued; finish through the same generation-safe path.
        for (id, entry) in retiring { finishRetirement(id, entry: entry) }
    }
    func reconcile(_ document: OutputProfileDocument) {
        for (id, entry) in entries {
            guard let destination = document.destinations.first(where: { $0.id == id && $0.enabled }),
                  let settings = destination.networkSettings else { stop(id); continue }
            if destination.networkTechnology != entry.technology || settings.requiresRestart(comparedTo: entry.settings) { stop(id) }
            else { entry.settings = settings }
        }
    }
    func publish(_ snapshot: OutputContentSnapshot, document: OutputProfileDocument, media: OutputMediaRuntime,
                 audioSession: PresentationSession?) {
        musicRoute.select(document.backgroundAudioDestinationID)
        for destination in document.destinations where activeIDs.contains(destination.id) {
            let id = destination.id
            guard let entry = entries[id], var profile = document.profiles.first(where: { $0.id == destination.profileID }) else { continue }
            let lease = entry.route.select(destination.workspaceID)
            if lease.changed {
                entry.media?.stop(); entry.media = nil
                entry.supervisor.selectContent(epoch: lease.epoch)
            }
            let route = entry.route, epoch = lease.epoch, supervisor = entry.supervisor, generation = entry.generation
            let targets: [NDIAudioDistribution.Target] = entry.ready ? [.init(id: id, send: { block in
                route.admitAudio(block, epoch: epoch) { supervisor.sendAudio($0, generation: generation, contentEpoch: epoch) }
            })] : []
            entry.audio.update(targets: targets, music: document.backgroundAudioDestinationID, preparing: true,
                wantsVideo: snapshot.visible && snapshot.kind == .video, runtime: media, session: audioSession)
            // A retained decoder failure can retire this entry synchronously.
            guard entries[id] === entry, !entry.retiring else { continue }
            if entry.media == nil {
                entry.media = OutputMediaFrameBroker(generation: generation, deliver: { submission in
                    route.admit(submission, epoch: epoch, deliver: supervisor.renderMedia)
                }) { [weak self, weak entry] reason in
                    guard let self, let entry, self.entries[id] === entry, !entry.retiring, route.isCurrent(epoch) else { return }
                    self.fail(id, reason)
                }
            }
            profile.usesLegacySizing = false
            entry.media?.update(snapshot, profile: profile, runtime: media, keyMode: entry.settings.keyMode)
        }
    }
    private func receive(_ event: NDIHelperSupervisor.Event, id: UUID) {
        guard let entry = entries[id] else { return }
        switch event {
        case .ready(let generation):
            guard generation == entry.generation, !entry.retiring else { return }
            entry.ready = true; setState(.publishing, for: id)
            entry.media?.forceNextFrame()
        case .status(let generation, let status):
            guard generation == entry.generation, !entry.retiring else { return }
            let previousNotice = performanceNotice(id), previousState = state(id)
            statistics[id] = status
            if entry.ready { setState(status.connections > 0 ? .sending(status.connections) : .publishing, for: id) }
            if previousState == state(id), previousNotice != performanceNotice(id) { stateChanged?(id, state(id)) }
        case .failed(let generation, let reason):
            guard generation == entry.generation, !entry.retiring else { return }
            fail(id, reason)
        case .exited(let generation):
            guard generation == entry.generation else { return }
            finishRetirement(id, entry: entry)
        case .frame, .rendered, .audio, .shutdown: break
        }
    }
    private func finishRetirement(_ id: UUID, entry: Entry) {
        guard entries[id] === entry else { return }
        entry.media?.stop(); entry.media = nil; entry.audio.stop()
        entries[id] = nil
        if case .stopping(let reason) = state(id) { setState(reason.map(NDIOutputState.failed) ?? .stopped, for: id) }
        else if state(id).active { setState(.failed("\(entry.technology.title) output stopped unexpectedly. Choose Retry or Show Slides."), for: id) }
    }
    private func fail(_ id: UUID, _ reason: String) {
        if let entry = entries[id] { entry.retiring = true; entry.route.invalidate(); entry.media?.stop(); entry.media = nil; entry.supervisor.stop() }
        entries[id]?.audio.stop()
        setState(.stopping(reason), for: id)
    }
    private func setState(_ state: NDIOutputState, for id: UUID) {
        guard states[id] != state else { return }
        states[id] = state
        if activeIDs.isEmpty { sleep.stop() } else { sleep.start() }
        stateChanged?(id, state)
    }
    deinit {
        let entries = entries
        for entry in entries.values { entry.supervisor.stop() }
        DispatchQueue.main.async { for entry in entries.values { entry.media?.stop() } }
    }
}
