import AppKit
import Combine

nonisolated enum OutputReadiness: String, Codable, Sendable {
    case closed, ready, displayMissing, unavailable, unsupported
    var title: String {
        switch self {
        case .closed: return "Stopped"
        case .ready: return "Open"
        case .displayMissing: return "Monitor unavailable"
        case .unavailable: return "Unavailable"
        case .unsupported: return "Not supported"
        }
    }
}

@MainActor
final class OutputCoordinator: ObservableObject {
    nonisolated let actionClock = OutputActionClock()
    let media = OutputMediaRuntime()
    let profiles: OutputProfileStore
    let displays: ProjectionDisplayManager
    private let sleepPrevention: ProjectionSleepPrevention
    private let driverFactory: @MainActor () -> any OutputDestinationDriving
    private let retainsPreparedSessions: Bool
    private var wasRunning = false
    private var windows: [UUID: any OutputDestinationDriving] = [:]
    private var targets: [UUID: ProjectionMonitorTarget] = [:]
    private var displayObservation: UUID?
    private var profileObservation: UUID?
    private var stopObserver: NSObjectProtocol?
    private var sessions: [UUID: WeakSession] = [:]
    private struct WeakSession { weak var value: PresentationSession? }
    private(set) var ownership = OutputOwnership()
    @Published private(set) var snapshot = OutputContentSnapshot()
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var readiness: [UUID: OutputReadiness] = [:]
    @Published private(set) var issue: String?
    @Published private(set) var visible = true
    @Published private(set) var text = OutputTextContent.empty
    @Published private(set) var nextText: OutputTextContent?
    @Published private(set) var sourceName = "Local Current"
    private(set) var liveSlide: Slide?
    private weak var preferredWeak: PresentationSession?
    private var retainedPreferred: PresentationSession?
    private(set) var preferredLocalSession: PresentationSession? {
        get { retainedPreferred ?? preferredWeak }
        set { preferredWeak = newValue; retainedPreferred = retainsPreparedSessions ? newValue : nil }
    }
    private(set) var localSession: PresentationSession?
    private weak var audioWeak: PresentationSession?
    private var retainedAudio: PresentationSession?
    private(set) var audioSession: PresentationSession? {
        get { retainedAudio ?? audioWeak }
        set { audioWeak = newValue; retainedAudio = retainsPreparedSessions ? newValue : nil }
    }
    private(set) var overlaySession: PresentationSession?
    var isRunning: Bool { !windows.isEmpty }
    var isExternal: Bool { if case .external = ownership.source { return true }; return false }
    var onReadinessChange: (() -> Void)?

    init(profiles: OutputProfileStore, displays: ProjectionDisplayManager, retainsPreparedSessions: Bool = false,
         sleepPrevention: ProjectionSleepPrevention = ProjectionSleepPrevention(),
         driverFactory: @escaping @MainActor () -> any OutputDestinationDriving = { OutputWindowDestination() }) {
        self.retainsPreparedSessions = retainsPreparedSessions
        self.profiles = profiles; self.displays = displays
        self.sleepPrevention = sleepPrevention; self.driverFactory = driverFactory
        displayObservation = displays.observe { [weak self] in self?.displaysChanged() }
        profileObservation = profiles.observe { [weak self] in self?.profilesChanged() }
        stopObserver = NotificationCenter.default.addObserver(forName: .stopProjection, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.stop() }
        }
    }
    func attach(_ session: PresentationSession) {
        sessions[session.outputSourceID] = WeakSession(value: session)
        if preferredLocalSession == nil { preferredLocalSession = session }
        session.applyOutputState(running: isRunning, visible: visible)
    }
    func focusWorkspace(_ session: PresentationSession) { preferredLocalSession = session }
    func toggleSlides() {
        if isRunning && visible { hide() }
        else if let session = preferredLocalSession, isRunning || !session.isEmpty || session.hasAvailableBackgroundVisual { session.showSlides() }
    }
    func clearBackgrounds() {
        let clearsAudience = profiles.document.destinations.contains { $0.enabled && $0.profileID == profiles.audience.id }
        profiles.clearBackgrounds()
        if clearsAudience { for session in sessions.values.compactMap(\.value) { session.setBackgroundVisual(nil) } }
    }
    func clearAudio() { audioSession?.clearBackgroundAudio() }
    func clearAllLayers() { hide(); clearBackgrounds(); clearAudio() }
    func setAudienceBackgroundVisibility(_ visible: Bool) {
        var profile = profiles.audience; profile.background.visible = visible; profiles.update(profile)
    }
    var audienceIdentity: (UInt32?, UUID?) {
        guard let destination = profiles.document.destinations.first(where: { $0.enabled && profiles.profile($0.profileID)?.kind == .audience }),
              let window = windows[destination.id] else { return (nil, nil) }
        return (window.windowNumber, window.generation)
    }
    var audienceTarget: ProjectionMonitorTarget? {
        profiles.document.destinations.first(where: { $0.enabled && profiles.profile($0.profileID)?.kind == .audience }).flatMap { targets[$0.id] }
    }
    func profile(for destination: UUID) -> OutputProfile? {
        profiles.document.destinations.first(where: { $0.id == destination }).flatMap { profiles.profile($0.profileID) }
    }
    func presentLocal(_ session: PresentationSession, show: Bool = true) -> Bool {
        _ = actionClock.next()
        let order = ownership.beginAction()
        if session.currentSlide?.webpageURL != nil {
            let audience = profiles.document.destinations.filter { $0.enabled && profiles.profile($0.profileID)?.kind == .audience }
            if audience.count > 1 {
                issue = "Live webpages support one Audience output. Disable the extra Audience output or use a companion profile."
                session.projectionDisplayIssue = issue
                return false
            }
        }
        guard openDestinations() else { session.projectionDisplayIssue = issue; return false }
        let previous = localSession
        guard ownership.take(.local(session.outputSourceID), action: order) != nil else { return false }
        if previous !== session { previous?.cancelPendingProjection(); previous?.emitOutputEvent(.stopped) }
        localSession = session; preferredLocalSession = session; overlaySession = session; sourceName = "eucaly Current"
        liveSlide = session.currentSlide
        updateText(from: session)
        visible = show
        session.projectionDisplayIssue = nil
        changed()
        return true
    }
    func passiveLocal(_ session: PresentationSession) {
        guard ownership.source == .local(session.outputSourceID) else { return }
        liveSlide = session.currentSlide; updateText(from: session); changed()
    }
    private func updateText(from session: PresentationSession) {
        text = OutputContentAdapter.text(for: session.currentSlide)
        nextText = session.currentSlideID.flatMap { session.slideIndex(for: $0) }.flatMap { session.slide(at: $0 + 1) }.map { OutputContentAdapter.text(for: $0) }
    }
    func presentExternal(connection: UUID, name: String, message: ExternalPresentationMessage) throws -> OutputLease {
        try message.validate()
        let ingress = message.ingressOrder ?? actionClock.next()
        guard ingress == actionClock.current else { throw ExternalPresentationError.invalid("Present was superseded by a newer action") }
        let action = ownership.beginAction()
        guard let current = message.current, let source = message.sourceID, let revision = message.revision else { throw ExternalPresentationError.invalid("Incomplete Present") }
        if let id = message.profileID {
            guard let profile = profiles.profile(id), profiles.document.destinations.contains(where: { $0.enabled && $0.profileID == id }) else {
                throw ExternalPresentationError.invalid("Requested profile is not assigned to an enabled output")
            }
            if profile.kind == .meaning && !current.components.contains(where: { $0.role == .meaning && !$0.text.isEmpty }) {
                throw ExternalPresentationError.invalid("Meaning profile requires a Meaning component")
            }
            if profile.kind == .translation && !current.components.contains(where: { $0.role == .translation && !$0.text.isEmpty }) {
                throw ExternalPresentationError.invalid("Translation profile requires a Translation component")
            }
        }
        guard openDestinations(activate: false) else { throw ExternalPresentationError.invalid(issue ?? "No destination is ready") }
        guard let lease = ownership.take(.external(connection: connection, source: source), action: action, revision: revision) else { throw ExternalPresentationError.invalid("Present was superseded") }
        // Cancel only this eucaly source's outbound request and capture identity.
        localSession?.cancelPendingProjection()
        localSession?.emitOutputEvent(.stopped)
        localSession = nil; liveSlide = nil
        if overlaySession == nil { overlaySession = preferredLocalSession }
        text = current; nextText = message.next; sourceName = name; visible = true
        changed(); return lease
    }
    func updateExternal(connection: UUID, message: ExternalPresentationMessage) -> Bool {
        guard (try? message.validate()) != nil, let lease = message.lease, let revision = message.revision, let current = message.current,
              ownership.update(connection: connection, lease: lease, revision: revision) else { return false }
        text = current; nextText = message.next; changed(); return true
    }
    func externalControl(connection: UUID, message: ExternalPresentationMessage) -> Bool {
        guard let lease = message.lease, ownership.permits(connection: connection, lease: lease) else { return false }
        if message.kind == .clear { clear() } else { hide() }
        return true
    }
    func externalDisconnected(_ connection: UUID) {
        guard case .external(let owner, _) = ownership.source, owner == connection else { return }
        hide()
    }
    func destinationStatuses() -> [ExternalDestinationStatus] {
        profiles.document.destinations.filter(\.enabled).map { destination in
            let state: OutputReadiness
            if let target = destination.monitor, displays.resolve(target) != nil {
                state = windows[destination.id] != nil ? .ready : displays.isReserved(target) ? .unavailable : .closed
            } else { state = .displayMissing }
            return .init(id: destination.id, name: destination.name, profileID: destination.profileID, readiness: state)
        }
    }
    func discoveryReply() -> ExternalPresentationReply {
        .init(kind: "welcome", groupID: ExternalPresentationProtocol.groupID, roles: OutputComponentRole.allCases,
              profiles: profiles.document.profiles.map { .init(id: $0.id, name: $0.name, kind: $0.kind, roles: $0.roles) }, destinations: destinationStatuses(), ownsOutput: false)
    }
    private func cancelPendingLocalRequests() {
        _ = actionClock.next()
        for session in sessions.values.compactMap(\.value) { session.cancelPendingProjection() }
    }
    func claimBackgroundAudio(_ session: PresentationSession) {
        guard audioSession !== session else { return }
        audioSession?.stopBackgroundAudioPlayback()
        audioSession = session
    }
    func hide() {
        cancelPendingLocalRequests()
        ownership.revoke()
        visible = false
        // Retain a frozen last-presented value for Confidence; updates are revoked.
        changed()
        localSession?.emitOutputEvent(.changed(localSession!.outputSnapshot))
    }
    func clear() {
        cancelPendingLocalRequests()
        ownership.revoke(); text = .empty; nextText = nil; liveSlide = nil
        changed()
    }
    func stop() {
        cancelPendingLocalRequests()
        ownership.revoke()
        let previous = localSession
        for id in Array(windows.keys) { closeDestination(id) }
        localSession = nil; overlaySession = nil; liveSlide = nil; text = .empty; nextText = nil
        changed(); previous?.emitOutputEvent(.stopped)
    }
    func destinationClosed(_ id: UUID, generation: UUID) {
        guard windows[id]?.generation == generation else { return }
        cancelPendingLocalRequests()
        closeDestination(id); changed()
        if !isRunning {
            ownership.revoke(); localSession?.emitOutputEvent(.stopped)
            localSession = nil; overlaySession = nil
        } else {
            // Clear Audience identity without stopping another output or AltView text.
            localSession?.emitOutputEvent(.changed(localSession!.outputSnapshot))
        }
    }
    private func closeDestination(_ id: UUID) {
        windows.removeValue(forKey: id)?.close(); targets.removeValue(forKey: id)
        readiness[id] = .closed; displays.unlock(owner: id)
        if windows.isEmpty { sleepPrevention.stop() }
    }
    private func openDestinations(activate: Bool = true) -> Bool {
        displays.refresh()
        issue = nil
        for destination in profiles.document.destinations where destination.enabled {
            guard windows[destination.id] == nil else { continue }
            guard let target = destination.monitor, let monitor = displays.resolve(target) else {
                readiness[destination.id] = .displayMissing; continue
            }
            guard !displays.isReserved(target), !targets.values.contains(where: { $0.identity == target.identity }) else {
                readiness[destination.id] = .unavailable; continue
            }
            let driver = driverFactory()
            guard driver.open(monitor: monitor, coordinator: self, destinationID: destination.id, activate: activate) else {
                readiness[destination.id] = .unavailable; continue
            }
            windows[destination.id] = driver; targets[destination.id] = target
            readiness[destination.id] = .ready; displays.lock(target, owner: destination.id)
        }
        if windows.isEmpty { issue = "Choose an available monitor in Projection settings before presenting."; return false }
        sleepPrevention.start(); return true
    }
    private func profilesChanged() {
        for id in Array(windows.keys) {
            guard let config = profiles.document.destinations.first(where: { $0.id == id }), config.enabled,
                  config.monitor == targets[id] else { closeDestination(id); continue }
        }
        changed()
    }
    private func displaysChanged() {
        // The simple toolbar controls Audience's saved assignment only while idle.
        if !isRunning, profiles.document.destinations.first?.monitor != displays.target {
            profiles.edit { doc in
                if !doc.destinations.isEmpty { doc.destinations[0].monitor = displays.target }
            }
        }
        for id in Array(windows.keys) {
            guard let target = targets[id] else { continue }
            if let monitor = displays.resolve(target), windows[id]?.reposition(monitor: monitor) == true { continue }
            else {
                cancelPendingLocalRequests()
                issue = "An output monitor disconnected. Show Slides to reopen it after reconnecting."
                for session in sessions.values.compactMap(\.value) { session.projectionDisplayIssue = issue }
                closeDestination(id); readiness[id] = .displayMissing
            }
        }
        changed()
        if !isRunning { ownership.revoke(); localSession?.emitOutputEvent(.stopped); localSession = nil; overlaySession = nil }
    }
    func refreshMedia() {
        media.updateProgram(slide: liveSlide, session: localSession, running: isRunning, visible: visible)
        let active = Set(windows.keys.compactMap { id in profiles.document.destinations.first { $0.id == id }?.profileID })
        media.syncBackgrounds(profiles: profiles.document.profiles.filter { active.contains($0.id) }, visible: visible,
                              media: liveSlide.map { AltViewPresentationAdapter.mode(for: $0) == .media } ?? false) { [weak self] in self?.changed() }
    }
    func refreshOverlay(_ session: PresentationSession) {
        if overlaySession === session { changed() }
    }
    private func changed() {
        refreshMedia()
        let kind: OutputContentSnapshot.Kind
        if let slide = liveSlide {
            kind = slide.videoURL != nil ? .video : slide.pdfURL != nil ? .pdf : slide.imageURL != nil ? .image : slide.webpageURL != nil ? .webpage : slide.captureWindowID != nil ? .capturedWindow : .lyrics
        } else { kind = text.isEmpty ? .empty : text.kind == .scripture ? .scripture : text.kind == .lyrics ? .lyrics : .text }
        snapshot = .init(source: ownership.source, kind: kind, current: text, next: nextText, visible: visible, revision: revision &+ 1,
                         clockVisible: overlaySession?.isClockVisible ?? false, countdownEndDate: overlaySession?.countdownEndDate, localMedia: liveSlide)
        revision &+= 1
        sessions = sessions.filter { $0.value.value != nil }
        if isRunning || wasRunning {
            for session in sessions.values.compactMap(\.value) {
                session.applyOutputState(running: isRunning, visible: visible)
                if let issue { session.projectionDisplayIssue = issue }
            }
        }
        wasRunning = isRunning
        onReadinessChange?()
    }
    deinit {
        if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
        let displays = displays, profiles = profiles, displayObservation = displayObservation, profileObservation = profileObservation
        let windows = windows
        DispatchQueue.main.async {
            if let displayObservation { displays.removeObserver(displayObservation) }
            if let profileObservation { profiles.removeObserver(profileObservation) }
            for (id, driver) in windows { driver.close(); displays.unlock(owner: id) }
        }
    }
}
