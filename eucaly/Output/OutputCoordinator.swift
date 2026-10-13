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
    let actionClock = OutputActionClock()
    let media = OutputMediaRuntime()
    let profiles: OutputProfileStore
    let displays: ProjectionDisplayManager
    private let sleepPrevention: ProjectionSleepPrevention
    private let driverFactory: @MainActor () -> any OutputDestinationDriving
    private let retainsPreparedSessions: Bool
    private var wasPresenting = false
    private var programStarted = false
    private var backgroundWindowsOpen = false
    private var standbyScheduled = false
    private var workspaceReady = false
    private var standbySuppressed: Set<UUID> = []
    private var standbyConfigurations: [OutputDestinationConfiguration]
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
    var remoteOutputs: (any OutputRemoteRouting)?
    var isRunning: Bool { !windows.isEmpty || remoteOutputs?.isRunning == true }
    // A physical standby clock is independent of explicit program presentation.
    var isPresenting: Bool { programStarted && isRunning }
    func isOpen(_ destinationID: UUID) -> Bool { windows[destinationID] != nil }
    func openConfidence(_ destinationID: UUID) {
        guard profiles.document.destinations.contains(where: { $0.id == destinationID && $0.enabled && profiles.profile($0.profileID)?.kind == .confidence }) else { return }
        standbySuppressed.remove(destinationID)
        scheduleConfidenceStandby()
    }
    func closeOutput(_ destinationID: UUID) {
        if let generation = windows[destinationID]?.generation { destinationClosed(destinationID, generation: generation) }
    }
    var hasEnabledConfidenceOutput: Bool {
        profiles.document.destinations.contains { $0.enabled && profiles.profile($0.profileID)?.kind == .confidence }
    }

    init(profiles: OutputProfileStore, displays: ProjectionDisplayManager, retainsPreparedSessions: Bool = false,
         sleepPrevention: ProjectionSleepPrevention = ProjectionSleepPrevention(),
         driverFactory: @escaping @MainActor () -> any OutputDestinationDriving = { OutputWindowDestination() }) {
        self.retainsPreparedSessions = retainsPreparedSessions
        self.profiles = profiles; self.displays = displays
        standbyConfigurations = profiles.document.destinations
        self.sleepPrevention = sleepPrevention; self.driverFactory = driverFactory
        displays.selectionConstraint = { [weak profiles] target in
            guard let profiles, let primary = profiles.document.destinations.first else { return nil }
            return profiles.monitorAssignmentProblem(for: target, excluding: primary.id)
        }
        displayObservation = displays.observe { [weak self] in self?.displaysChanged() }
        profileObservation = profiles.observe { [weak self] in self?.profilesChanged() }
        stopObserver = NotificationCenter.default.addObserver(forName: .stopProjection, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.stop() }
        }
    }
    func attach(_ session: PresentationSession) {
        sessions[session.outputSourceID] = WeakSession(value: session)
        if preferredLocalSession == nil { preferredLocalSession = session }
        session.applyOutputState(running: isPresenting && localSession === session, visible: visible)
    }
    func focusWorkspace(_ session: PresentationSession) { preferredLocalSession = session }
    /// Called by the native workspace window after it becomes key. Constructors
    /// never create projection windows ahead of SwiftUI's initial WindowGroup.
    func workspaceWindowReady(_ session: PresentationSession) {
        focusWorkspace(session)
        workspaceReady = true
        scheduleConfidenceStandby()
    }
    func toggleSlides() {
        if isPresenting && visible { hide() }
        else if let session = preferredLocalSession, isRunning || session.hasProjectionContent { session.showSlides() }
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
    /// Background-only opening owns windows, never a foreground program/lease.
    func openBackgroundOutputs() -> Bool {
        guard !programStarted else { return true }
        guard openDestinations(), !windows.isEmpty else {
            issue = "Background visuals need an available native output."
            return false
        }
        backgroundWindowsOpen = true
        visible = false
        changed()
        return true
    }
    var hasOpenAudienceOutput: Bool {
        profiles.document.destinations.contains { $0.enabled && profiles.profile($0.profileID)?.kind == .audience && windows[$0.id] != nil }
    }
    func presentLocal(_ session: PresentationSession, show: Bool = true) -> Bool {
        _ = actionClock.next()
        let order = ownership.beginAction()
        if let problem = localPresentationProblem(for: session.currentSlide) {
            issue = problem; session.projectionDisplayIssue = problem
            return false
        }
        guard openDestinations() else { session.projectionDisplayIssue = issue; return false }
        if let problem = nativeContentProblem(for: session.currentSlide, show: show) {
            issue = problem; session.projectionDisplayIssue = problem
            return false
        }
        let previous = localSession
        guard ownership.take(session.outputSourceID, action: order) else { return false }
        if previous !== session { previous?.cancelPendingProjection() }
        programStarted = true
        localSession = session; preferredLocalSession = session
        liveSlide = session.currentSlide
        updateText(from: session)
        visible = show
        session.projectionDisplayIssue = nil
        changed(explicit: show)
        return true
    }
    private func localPresentationProblem(for slide: Slide?) -> String? {
        guard slide?.webpageURL != nil else { return nil }
        let audience = profiles.document.destinations.filter { $0.enabled && profiles.profile($0.profileID)?.kind == .audience }
        if audience.count > 1 { return "Live webpages support one Audience output. Disable the extra Audience output or use a companion profile." }
        if !audience.contains(where: { $0.monitor.flatMap { displays.resolve($0) } != nil }) {
            return "Live webpages need an enabled Audience output with an available monitor."
        }
        return nil
    }
    private func nativeContentProblem(for slide: Slide?, show: Bool = true) -> String? {
        guard windows.isEmpty, slide.map({ AltViewPresentationAdapter.mode(for: $0) == .media }) == true || !show else { return nil }
        return "Media and background visuals need an available native output. AltView LAN destinations support text."
    }
    func passiveLocal(_ session: PresentationSession) {
        guard ownership.source == session.outputSourceID else { return }
        // A deferred model refresh must not bypass the same media preflight as Show.
        if let problem = localPresentationProblem(for: session.currentSlide) ?? nativeContentProblem(for: session.currentSlide) {
            issue = problem; session.projectionDisplayIssue = problem
            return
        }
        liveSlide = session.currentSlide; updateText(from: session); changed()
    }
    private func updateText(from session: PresentationSession) {
        text = OutputContentAdapter.text(for: session.currentSlide)
        nextText = session.currentSlideID.flatMap { session.slideIndex(for: $0) }.flatMap { session.slide(at: $0 + 1) }.map { OutputContentAdapter.text(for: $0) }
    }
    func monitorAssignmentProblem(for target: ProjectionMonitorTarget, destinationID: UUID) -> String? {
        displays.problem(for: target) ?? profiles.monitorAssignmentProblem(for: target, excluding: destinationID)
    }
    @discardableResult
    func assignMonitor(_ target: ProjectionMonitorTarget?, to destinationID: UUID) -> Bool {
        guard windows[destinationID] == nil,
              let destination = profiles.document.destinations.first(where: { $0.id == destinationID }),
              profiles.profile(destination.profileID)?.isNative == true else { return false }
        if let target, let problem = monitorAssignmentProblem(for: target, destinationID: destinationID) {
            issue = problem
            return false
        }
        if destinationID == profiles.document.destinations.first?.id {
            guard target.map({ displays.select($0) }) ?? displays.clearSelection() else { return false }
        }
        profiles.edit { doc in
            if let index = doc.destinations.firstIndex(where: { $0.id == destinationID }) { doc.destinations[index].monitor = target }
        }
        issue = profiles.monitorConflictNotice
        return true
    }
    func destinationStatuses() -> [OutputDestinationStatus] {
        let conflicts = profiles.conflictingDestinationIDs.union(profiles.conflictingReceiverIDs)
        return profiles.document.destinations.filter(\.enabled).map { destination in
            let state: OutputReadiness
            if conflicts.contains(destination.id) { state = .unavailable }
            else if profiles.profile(destination.profileID)?.kind == .altView { state = remoteOutputs?.readiness(for: destination.id) ?? .closed }
            else if let target = destination.monitor, displays.resolve(target) != nil {
                state = windows[destination.id] != nil ? .ready : displays.isReserved(target) ? .unavailable : .closed
            } else { state = .displayMissing }
            return .init(id: destination.id, name: destination.name, profileID: destination.profileID, readiness: state)
        }
    }
    private func cancelPendingLocalRequests(recordAction: Bool = true) {
        if recordAction { _ = actionClock.next() }
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
        // Keep the last-presented snapshot private while every foreground is hidden.
        changed()
    }
    func clear() {
        cancelPendingLocalRequests()
        ownership.revoke(); text = .empty; nextText = nil; liveSlide = nil
        changed()
    }
    func stop() {
        cancelPendingLocalRequests()
        ownership.revoke()
        remoteOutputs?.stop()
        programStarted = false; backgroundWindowsOpen = false
        standbySuppressed.formUnion(profiles.document.destinations.map(\.id))
        for id in Array(windows.keys) { closeDestination(id) }
        localSession = nil; liveSlide = nil; text = .empty; nextText = nil
        changed()
    }
    func destinationClosed(_ id: UUID, generation: UUID) {
        guard windows[id]?.generation == generation else { return }
        standbySuppressed.insert(id)
        cancelPendingLocalRequests(recordAction: false)
        closeDestination(id)
        if !isRunning {
            ownership.revoke()
            localSession = nil
            changed()
        } else {
            changed()
        }
    }
    private func closeDestination(_ id: UUID) {
        windows.removeValue(forKey: id)?.close(); targets.removeValue(forKey: id)
        readiness[id] = .closed; displays.unlock(owner: id)
        if windows.isEmpty { backgroundWindowsOpen = false; sleepPrevention.stop() }
        if !isRunning { programStarted = false }
    }
    private func openDestinations(activate: Bool = true) -> Bool {
        displays.refresh()
        issue = nil
        let conflicts = profiles.conflictingDestinationIDs.union(profiles.conflictingReceiverIDs)
        var ready = false
        for destination in profiles.document.destinations where destination.enabled {
            guard !conflicts.contains(destination.id) else { readiness[destination.id] = .unavailable; continue }
            if profiles.profile(destination.profileID)?.kind == .altView {
                if remoteOutputs?.canPresent(destination) == true { ready = true }
                readiness[destination.id] = remoteOutputs?.readiness(for: destination.id) ?? .closed
            } else if openDestination(destination, activate: activate) { ready = true }
        }
        guard ready else {
            issue = profiles.monitorConflictNotice ?? "Choose an available monitor or connect an AltView destination in Manage Outputs before presenting."
            return false
        }
        if !windows.isEmpty { sleepPrevention.start() }
        return true
    }
    private func openDestination(_ destination: OutputDestinationConfiguration, activate: Bool) -> Bool {
        guard profiles.profile(destination.profileID)?.isNative == true else { return false }
        if windows[destination.id] != nil { return true }
        guard let target = destination.monitor, let monitor = displays.resolve(target) else {
            readiness[destination.id] = .displayMissing; return false
        }
        guard !displays.isReserved(target), !targets.values.contains(where: { $0.identity == target.identity }) else {
            readiness[destination.id] = .unavailable; return false
        }
        let driver = driverFactory()
        guard driver.open(monitor: monitor, coordinator: self, destinationID: destination.id, activate: activate) else {
            readiness[destination.id] = .unavailable; return false
        }
        standbySuppressed.remove(destination.id)
        windows[destination.id] = driver; targets[destination.id] = target
        readiness[destination.id] = .ready; displays.lock(target, owner: destination.id)
        return true
    }
    private func scheduleConfidenceStandby() {
        guard workspaceReady, !standbyScheduled else { return }
        standbyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.standbyScheduled = false
            self.openConfidenceStandbys()
        }
    }
    private func openConfidenceStandbys() {
        let candidates = profiles.document.destinations.filter {
            $0.enabled && $0.monitor != nil && profiles.profile($0.profileID)?.kind == .confidence
                && windows[$0.id] == nil && !standbySuppressed.contains($0.id)
        }
        guard !candidates.isEmpty, profiles.recoveryNotice == nil else { return }
        guard profiles.monitorConflictNotice == nil else { return }
        displays.refresh()
        // Publish standby before the native view can read a retained old slide.
        if !programStarted && snapshot.visible {
            visible = false
            changed()
        }
        var opened = false
        for destination in candidates {
            guard !standbySuppressed.contains(destination.id),
                  profiles.document.destinations.contains(destination) else { continue }
            if openDestination(destination, activate: false) { opened = true }
            else { standbySuppressed.insert(destination.id) }
        }
        if opened { sleepPrevention.start(); changed() }
    }
    private func profilesChanged() {
        issue = profiles.monitorConflictNotice
        let previous = standbyConfigurations
        standbyConfigurations = profiles.document.destinations
        standbySuppressed.formIntersection(Set(standbyConfigurations.map(\.id)))
        for config in standbyConfigurations where config.enabled {
            let old = previous.first { $0.id == config.id }
            if old?.enabled != true || old?.profileID != config.profileID || old?.monitor != config.monitor {
                standbySuppressed.remove(config.id)
            }
        }
        for id in Array(windows.keys) {
            guard let config = profiles.document.destinations.first(where: { $0.id == id }), config.enabled,
                  !profiles.conflictingDestinationIDs.contains(id), config.monitor == targets[id], programStarted || backgroundWindowsOpen || profiles.profile(config.profileID)?.kind == .confidence else { closeDestination(id); continue }
        }
        let conflicts = profiles.conflictingDestinationIDs.union(profiles.conflictingReceiverIDs)
        let hasDestination = profiles.document.destinations.contains {
            $0.enabled && !conflicts.contains($0.id) && ($0.monitor != nil || $0.receiver != nil)
        }
        if !hasDestination {
            cancelPendingLocalRequests(recordAction: false)
            ownership.revoke(); programStarted = false; localSession = nil
        }
        changed()
        scheduleConfidenceStandby()
    }
    private func displaysChanged() {
        // The simple toolbar controls Audience's saved assignment only while idle.
        if let primary = profiles.document.destinations.first, profiles.profile(primary.profileID)?.isNative == true, windows[primary.id] == nil, primary.monitor != displays.target {
            profiles.edit { doc in
                if !doc.destinations.isEmpty { doc.destinations[0].monitor = displays.target }
            }
        }
        for id in Array(windows.keys) {
            guard let target = targets[id] else { continue }
            if let monitor = displays.resolve(target), windows[id]?.reposition(monitor: monitor) == true { continue }
            else {
                cancelPendingLocalRequests(recordAction: false)
                issue = "An output monitor disconnected. Show Slides to reopen it after reconnecting."
                for session in sessions.values.compactMap(\.value) { session.projectionDisplayIssue = issue }
                standbySuppressed.insert(id)
                closeDestination(id); readiness[id] = .displayMissing
            }
        }
        if !isRunning { ownership.revoke(); localSession = nil }
        changed()
        scheduleConfidenceStandby()
    }
    func refreshMedia() {
        media.updateProgram(slide: liveSlide, session: localSession, running: isPresenting && !windows.isEmpty, visible: visible)
        let active = Set(windows.keys.compactMap { id in profiles.document.destinations.first { $0.id == id }?.profileID })
        media.syncBackgrounds(profiles: profiles.document.profiles.filter { active.contains($0.id) }, visible: visible,
                              media: liveSlide.map { AltViewPresentationAdapter.mode(for: $0) == .media } ?? false) { [weak self] in self?.changed() }
    }
    func remoteReadinessChanged() {
        for session in sessions.values.compactMap(\.value) {
            session.applyOutputState(running: isPresenting && localSession === session, visible: visible)
        }
    }
    private func changed(explicit: Bool = false) {
        refreshMedia()
        let kind: OutputContentSnapshot.Kind
        if let slide = liveSlide {
            kind = slide.videoURL != nil ? .video : slide.pdfURL != nil ? .pdf : slide.imageURL != nil ? .image : slide.webpageURL != nil ? .webpage : slide.captureWindowID != nil ? .capturedWindow : .lyrics
        } else { kind = text.isEmpty ? .empty : text.kind == .lyrics ? .lyrics : .text }
        snapshot = .init(source: ownership.source, kind: kind, current: text, next: nextText, visible: visible, revision: revision &+ 1,
                         localMedia: liveSlide)
        revision &+= 1
        remoteOutputs?.publish(snapshot, explicit: explicit)
        sessions = sessions.filter { $0.value.value != nil }
        if isPresenting || wasPresenting {
            for session in sessions.values.compactMap(\.value) {
                session.applyOutputState(running: isPresenting && localSession === session, visible: visible)
                if let issue { session.projectionDisplayIssue = issue }
            }
        }
        wasPresenting = isPresenting
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
