import AppKit
import AVFoundation
import Combine

nonisolated enum OutputReadiness: String, Codable, Sendable {
    case closed, ready, starting, stopping, publishing, sending, displayMissing, unavailable, unsupported
    var title: String {
        switch self {
        case .closed: "Stopped"
        case .ready: "Open"
        case .starting: "Starting"
        case .stopping: "Stopping"
        case .publishing: "Publishing · No receivers"
        case .sending: "Sending"
        case .displayMissing: "Monitor unavailable"
        case .unavailable: "Unavailable"
        case .unsupported: "Not supported"
        }
    }
}

/// Destinations and their native/helper lifetimes belong to the app. Accepted
/// program state, action ordering and playback belong to a durable workspace.
@MainActor
final class OutputCoordinator: ObservableObject {
    let profiles: OutputProfileStore
    let displays: ProjectionDisplayManager
    let ndi: any NDIOutputDriving
    private let retainsPreparedSessions: Bool
    private let sleepPrevention: ProjectionSleepPrevention
    private let keyWindow: @MainActor () -> NSWindow?
    private let driverFactory: @MainActor () -> any OutputDestinationDriving
    private var programs: [UUID: OutputWorkspaceProgram] = [:]
    private var windows: [UUID: any OutputDestinationDriving] = [:]
    private var targets: [UUID: ProjectionMonitorTarget] = [:]
    private var displayObservation: UUID?
    private var profileObservation: UUID?
    private var stopObserver: NSObjectProtocol?
    private var legacyMonitorTarget: ProjectionMonitorTarget?
    private var standbyConfigurations: [OutputDestinationConfiguration]
    private var confidenceDestinationIDs: Set<UUID>
    private var standbySuppressed: Set<UUID> = []
    private var standbyScheduled = false
    private var workspaceReady = false
    private var dismissedNDIPerformance: Set<UUID> = []
    private var dismissedNDIFailures: [UUID: String] = [:]
    private var issues: [UUID: String] = [:]
    private enum IssueReason { case presentation, background, assignment(UUID, ProjectionMonitorTarget), disconnected, transfer }
    private var issueReasons: [UUID: IssueReason] = [:]
    @Published private(set) var focusedWorkspaceID: UUID?
    @Published private(set) var revision: UInt64 = 0
    @Published private(set) var readiness: [UUID: OutputReadiness] = [:]
    @Published private(set) var issue: String?
    private weak var audioWeak: PresentationSession?
    private var retainedAudio: PresentationSession?
    var audioSession: PresentationSession? { retainedAudio ?? audioWeak }

    // These are operator editing conveniences only. Rendering always resolves a
    // destination's saved owner; focus never participates in output routing.
    var preferredLocalSession: PresentationSession? { focusedWorkspaceID.flatMap { programs[$0]?.session } }
    var commandSession: PresentationSession? { commandSession(for: keyWindow()) }
    func commandSession(for window: NSWindow?) -> PresentationSession? {
        if let controls = window as? OutputWorkspaceWindow,
           let session = controls.workspaceSession, session.outputCoordinator === self { return session }
        if let output = window as? PresentationWindow, output.outputCoordinator === self,
           let id = output.outputDestinationID {
            return session(for: id)
        }
        return preferredLocalSession
    }
    private var commandProgram: OutputWorkspaceProgram { commandSession.map { program($0.outputSourceID) } ?? focusedProgram }
    var localSession: PresentationSession? { isPresenting ? preferredLocalSession : nil }
    private var focusedProgram: OutputWorkspaceProgram { program(focusedWorkspaceID ?? profiles.document.workspaces[0].id) }
    var snapshot: OutputContentSnapshot { focusedProgram.snapshot }
    var visible: Bool { snapshot.visible }
    var text: OutputTextContent { snapshot.current }
    var nextText: OutputTextContent? { snapshot.next }
    var liveSlide: Slide? { snapshot.localMedia }
    var media: OutputMediaRuntime { focusedProgram.media }
    var ownership: OutputOwnership { focusedProgram.ownership }
    var actionClock: OutputActionClock { focusedProgram.actionClock }
    var isRunning: Bool { !windows.isEmpty || !ndi.activeIDs.isEmpty }
    var isPresenting: Bool { isPresenting(workspace: focusedProgram.id) }
    var hasEnabledConfidenceOutput: Bool { hasEnabledConfidenceOutput(workspace: focusedProgram.id) }
    var hasOpenAudienceOutput: Bool { hasOpenAudienceOutput(workspace: focusedProgram.id) }
    var audienceTarget: ProjectionMonitorTarget? { audienceTarget(workspace: focusedProgram.id) }
    func audienceTarget(workspace: UUID) -> ProjectionMonitorTarget? { audienceDestination(workspace: workspace).flatMap { targets[$0.id] } }
    var audienceIdentity: (UInt32?, UUID?) {
        guard let destination = audienceDestination(workspace: focusedProgram.id), let driver = windows[destination.id] else { return (nil, nil) }
        return (driver.windowNumber, driver.generation)
    }

    init(profiles: OutputProfileStore, displays: ProjectionDisplayManager, retainsPreparedSessions: Bool = false,
         media: OutputMediaRuntime? = nil, ndi: (any NDIOutputDriving)? = nil,
         sleepPrevention: ProjectionSleepPrevention = ProjectionSleepPrevention(),
         keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
         driverFactory: @escaping @MainActor () -> any OutputDestinationDriving = { OutputWindowDestination() }) {
        self.profiles = profiles; self.displays = displays; self.retainsPreparedSessions = retainsPreparedSessions
        self.keyWindow = keyWindow
        self.ndi = ndi ?? NDIOutputRouter(); self.sleepPrevention = sleepPrevention; self.driverFactory = driverFactory
        standbyConfigurations = profiles.document.destinations; legacyMonitorTarget = displays.target
        confidenceDestinationIDs = Set(profiles.document.destinations.filter { profiles.profile($0.profileID)?.kind == .confidence }.map(\.id))
        for (index, record) in profiles.document.workspaces.enumerated() {
            programs[record.id] = OutputWorkspaceProgram(id: record.id, media: index == 0 ? media ?? OutputMediaRuntime() : OutputMediaRuntime())
        }
        self.ndi.stateChanged = { [weak self] id, state in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.ndi.state(id) == state else { return }
                if state.failureReason != nil, let owner = self.destination(id)?.workspaceID {
                    self.programs[owner]?.session?.cancelPendingProjection()
                }
                self.changed()
            }
        }
        displays.selectionConstraint = { [weak profiles] target in
            guard let profiles, let primary = profiles.document.destinations.first, primary.isMonitorDestination else { return nil }
            return profiles.monitorAssignmentProblem(for: target, excluding: primary.id)
        }
        displayObservation = displays.observe { [weak self] in self?.displaysChanged() }
        profileObservation = profiles.observe { [weak self] in self?.profilesChanged() }
        stopObserver = NotificationCenter.default.addObserver(forName: .stopProjection, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.async { self?.stop() }
        }
    }
    func program(_ id: UUID) -> OutputWorkspaceProgram {
        if let value = programs[id] { return value }
        let value = OutputWorkspaceProgram(id: id); programs[id] = value; return value
    }
    func session(workspace id: UUID) -> PresentationSession {
        if let value = programs[id]?.session { return value }
        return PresentationSession(projectionDisplays: displays, outputCoordinator: self, workspaceID: id)
    }
    func preparedSession(workspace id: UUID) -> PresentationSession? { programs[id]?.session }
    func preparedMedia(workspace id: UUID) -> OutputMediaRuntime? { programs[id]?.media }
    func isPlaybackRunning(workspace id: UUID) -> Bool {
        let session = programs[id]?.session
        let audio = session?.programBackgroundAudioPlayer
        return session?.isBackgroundAudioPlaying == true || audio.map { $0.rate != 0 || $0.timeControlStatus == .waitingToPlayAtSpecifiedRate } == true
            || programs[id]?.media.hasRunningPlayback == true
    }
    func workspaceDeletionProblem(_ id: UUID) -> String? {
        if let problem = profiles.workspaceRemovalProblem(id) { return problem }
        return isPlaybackRunning(workspace: id) ? "Stop playback in this workspace before deleting it." : nil
    }
    /// The controls owner obtains unsaved-edit approval before calling this.
    /// Recheck safety after approval, which can run a nested native event loop.
    @discardableResult
    func deleteWorkspace(_ id: UUID) -> Bool {
        guard workspaceDeletionProblem(id) == nil else { return false }
        profiles.edit { $0.workspaces.removeAll { $0.id == id } }
        guard !profiles.document.workspaces.contains(where: { $0.id == id }) else { return false }
        if let state = programs.removeValue(forKey: id) {
            cancelRequests(state); state.ownership.revoke(); state.media.stop()
            state.session?.clearBackgroundAudio()
            state.retainedSession = nil
        }
        if audioSession?.outputSourceID == id { audioWeak = nil; retainedAudio = nil }
        issues[id] = nil; issueReasons[id] = nil
        if focusedWorkspaceID == id { focusedWorkspaceID = profiles.document.workspaces.first?.id }
        changed()
        return true
    }
    func nextWorkspaceIdentity() -> UUID {
        profiles.document.workspaces.first(where: { programs[$0.id]?.session == nil })?.id
            ?? profiles.addWorkspace() ?? UUID()
    }
    func attach(_ session: PresentationSession) {
        let state = program(session.outputSourceID)
        state.session = session; state.retainedSession = retainsPreparedSessions ? session : nil
        if focusedWorkspaceID == nil { focusedWorkspaceID = state.id }
        session.applyOutputState(running: isPresenting(workspace: state.id), visible: state.snapshot.visible)
    }
    func focusWorkspace(_ session: PresentationSession) {
        guard profiles.document.workspaces.contains(where: { $0.id == session.outputSourceID }) else { return }
        guard focusedWorkspaceID != session.outputSourceID else { return }
        focusedWorkspaceID = session.outputSourceID; publishIssues()
    }
    func workspaceWindowReady(_ session: PresentationSession) {
        guard profiles.document.workspaces.contains(where: { $0.id == session.outputSourceID }) else { return }
        focusWorkspace(session); workspaceReady = true; scheduleConfidenceStandby()
    }
    func destination(_ id: UUID) -> OutputDestinationConfiguration? { profiles.document.destinations.first { $0.id == id } }
    func destinations(workspace: UUID) -> [OutputDestinationConfiguration] { profiles.document.destinations.filter { $0.workspaceID == workspace } }
    func monitorAudioLocally(workspace: UUID) -> Bool {
        profiles.document.workspaces.first { $0.id == workspace }?.monitorAudioLocally ?? false
    }
    func setMonitorAudioLocally(_ enabled: Bool, workspace: UUID) {
        guard profiles.recoveryNotice == nil, monitorAudioLocally(workspace: workspace) != enabled,
              profiles.document.workspaces.contains(where: { $0.id == workspace }) else { return }
        profiles.edit { document in
            if let index = document.workspaces.firstIndex(where: { $0.id == workspace }) {
                document.workspaces[index].monitorAudioLocally = enabled
            }
        }
        // This is an audio-level edit, never a presentation/ownership command.
        // Do not accept snapshots, start outputs, seek or recreate players.
        refreshMedia()
    }
    func localBackgroundAudioEnabled(workspace: UUID) -> Bool {
        let rows = destinations(workspace: workspace)
        return monitorAudioLocally(workspace: workspace)
            || rows.contains { $0.enabled && $0.isMonitorDestination && windows[$0.id] != nil }
            // Retain explicit standalone local music. A saved NDI music route
            // never falls back to local speakers when its sender stops/moves.
            || (programs[workspace]?.session?.backgroundAudioHasStandaloneLocalRoute == true
                && canPlayStandaloneBackgroundAudio(workspace: workspace))
    }
    func canPlayStandaloneBackgroundAudio(workspace: UUID) -> Bool {
        profiles.document.backgroundAudioDestinationID == nil && !destinations(workspace: workspace).contains { $0.ndi != nil }
    }
    func profile(for destination: UUID) -> OutputProfile? { self.destination(destination).flatMap { profiles.profile($0.profileID) } }
    func snapshot(for destination: UUID) -> OutputContentSnapshot {
        self.destination(destination)?.workspaceID.flatMap { programs[$0]?.snapshot } ?? .init(visible: false)
    }
    func session(for destination: UUID) -> PresentationSession? { self.destination(destination)?.workspaceID.flatMap { programs[$0]?.session } }
    func media(for destination: UUID) -> OutputMediaRuntime? { self.destination(destination)?.workspaceID.flatMap { programs[$0]?.media } }
    func isOpen(_ id: UUID) -> Bool { windows[id] != nil || ndi.activeIDs.contains(id) }
    func isRunning(workspace: UUID) -> Bool { destinations(workspace: workspace).contains { isOpen($0.id) } }
    func isPresenting(workspace: UUID) -> Bool { programs[workspace]?.started == true && isRunning(workspace: workspace) }
    func hasEnabledConfidenceOutput(workspace: UUID) -> Bool {
        destinations(workspace: workspace).contains { $0.enabled && $0.isMonitorDestination && profiles.profile($0.profileID)?.kind == .confidence }
    }
    func hasOpenAudienceOutput(workspace: UUID) -> Bool {
        destinations(workspace: workspace).contains { $0.enabled && profiles.profile($0.profileID)?.kind == .audience && windows[$0.id] != nil }
    }
    /// Settings and sidebar selection feed the same output appearance model.
    /// Mixed configurations hide together, then show together on the next toggle.
    func backgroundVisualVisibility(workspace: UUID) -> Bool? {
        let backgrounds = destinations(workspace: workspace).filter(\.enabled).compactMap { profiles.profile($0.profileID)?.background }
            .filter { $0.bookmark.map { !$0.isEmpty } == true }
        return backgrounds.isEmpty ? nil : backgrounds.contains(where: \.visible)
    }
    private func audienceDestination(workspace: UUID) -> OutputDestinationConfiguration? {
        destinations(workspace: workspace).first { $0.enabled && $0.isMonitorDestination && profiles.profile($0.profileID)?.kind == .audience && windows[$0.id] != nil }
    }
    func thumbnailProfile(workspace: UUID) -> OutputProfile {
        let rows = destinations(workspace: workspace).filter(\.enabled)
        let row = rows.first { $0.isMonitorDestination && profiles.profile($0.profileID)?.kind == .audience } ?? rows.first
        return row.flatMap { profiles.profile($0.profileID) } ?? profiles.profile(OutputProfile.audienceID) ?? profiles.audience
    }
    func thumbnailGeometry(workspace: UUID) -> CGSize? {
        let rows = destinations(workspace: workspace).filter(\.enabled)
        let row = rows.first { $0.isMonitorDestination && profiles.profile($0.profileID)?.kind == .audience } ?? rows.first
        if let settings = row?.ndi { return .init(width: settings.width, height: settings.height) }
        return row?.monitor.flatMap { displays.resolve($0)?.frame.size }
    }
    func tabStatus(workspace: UUID) -> String {
        let rows = destinations(workspace: workspace).filter(\.enabled)
        let statuses = destinationStatuses().filter { status in rows.contains { $0.id == status.id } }
        if workspaceIssue(workspace) != nil || statuses.contains(where: { $0.readiness == .unavailable || $0.readiness == .displayMissing }) { return "Output issue" }
        let count = rows.filter { isOpen($0.id) }.count
        if count > 0 {
            let state = programs[workspace]
            let activity = state?.started == true ? (state?.snapshot.visible == true ? "Live" : "Hidden") : state?.backgroundOpen == true ? "Background" : "Standby"
            let blank = state?.snapshot.localMedia.map { !OutputContentClassifier.supportsNDI($0) } == true && rows.contains { $0.ndi != nil && isOpen($0.id) }
            return "\(count) output\(count == 1 ? "" : "s") · " + activity + (blank ? " · NDI blank" : "")
        }
        return rows.isEmpty ? "No outputs" : "Stopped"
    }

    /// Explicit reassignment is transactional. No destination is stopped or
    /// renamed. Its next publication is fenced from the previous owner's work.
    @discardableResult
    func moveOutput(_ id: UUID, toWorkspace workspaceID: UUID, reportingTo requesterID: UUID? = nil) -> Bool {
        // Native menus can retain an action beyond deletion or reconfiguration.
        // Validate all identities before constructing a closed workspace's Current.
        guard profiles.recoveryNotice == nil, destination(id) != nil,
              profiles.document.workspaces.contains(where: { $0.id == workspaceID }),
              requesterID.map({ id in profiles.document.workspaces.contains { $0.id == id } }) != false else { return false }
        return moveOutput(id, to: session(workspace: workspaceID), reportingTo: requesterID)
    }

    @discardableResult
    func moveOutput(_ id: UUID, to session: PresentationSession, reportingTo workspaceID: UUID? = nil) -> Bool {
        guard let row = destination(id), profiles.recoveryNotice == nil,
              profiles.document.workspaces.contains(where: { $0.id == session.outputSourceID }) else { return false }
        guard row.workspaceID != session.outputSourceID else { return true }
        var proposed = destinations(workspace: session.outputSourceID); proposed.append(row)
        if let slide = session.currentSlide, row.ndi != nil, !OutputContentClassifier.supportsNDI(slide) {
            setIssue("Cannot move \(profiles.destinationLabel(row)) to \(profiles.workspaceName(session.outputSourceID)). NDI supports lyrics, PDFs, images and video files. Choose supported Current content before moving this output.",
                     workspace: workspaceID ?? session.outputSourceID, reason: .transfer)
            return false
        }
        if let problem = presentationProblem(for: session.currentSlide, rows: proposed) {
            setIssue(problem, workspace: workspaceID ?? session.outputSourceID, reason: .transfer); return false
        }
        let transferringProgram = isOpen(id) && row.workspaceID.flatMap { programs[$0]?.started } == true
        if let previous = row.workspaceID { cancelRequests(program(previous)) }
        let state = program(session.outputSourceID); cancelRequests(state)
        if transferringProgram {
            let show = state.started ? state.snapshot.visible : true
            state.started = true
            accept(session, into: state, visible: show)
        }
        profiles.edit { doc in
            if let index = doc.destinations.firstIndex(where: { $0.id == id }) { doc.destinations[index].workspaceID = session.outputSourceID }
        }
        setIssue(nil, workspace: session.outputSourceID)
        if let workspaceID, case .transfer? = issueReasons[workspaceID] { setIssue(nil, workspace: workspaceID) }
        changed()
        return destination(id)?.workspaceID == session.outputSourceID
    }
    func toggleSlides() {
        commandSession?.toggleSlidesVisibility()
    }
    func startNDI(_ id: UUID) {
        guard let row = destination(id), row.enabled, row.ndi != nil, let owner = row.workspaceID,
              ndi.state(id).canStart || ndi.state(id).active else { return }
        let session = session(workspace: owner)
        if let slide = session.currentSlide, !OutputContentClassifier.supportsNDI(slide) {
            setIssue("NDI supports lyrics, PDFs, images and video files. Choose supported Current content before starting this source.", workspace: owner); return
        }
        _ = presentLocal(session, onlyDestinationID: id)
    }
    enum PresentationActivation { case show, current }
    func presentLocal(_ session: PresentationSession, show: Bool = true, onlyDestinationID: UUID? = nil,
                      activation: PresentationActivation = .show) -> Bool {
        guard profiles.document.workspaces.contains(where: { $0.id == session.outputSourceID }) else { return false }
        let state = program(session.outputSourceID); cancelRequests(state)
        let rows = destinations(workspace: state.id).filter {
            $0.enabled && (onlyDestinationID == nil || $0.id == onlyDestinationID)
                && (activation == .show || isOpen($0.id))
        }
        if let problem = presentationProblem(for: session.currentSlide, rows: rows) {
            setIssue(problem, workspace: state.id); return false
        }
        // A Current activation updates the surviving consumers. Only explicit
        // Show/Start/Retry may reopen a closed window or restart a failed sender.
        guard activation == .show ? openDestinations(rows) : !rows.isEmpty else {
            setIssue(profiles.monitorConflictNotice ?? "Choose an available output assigned to this workspace in Manage Outputs before presenting.", workspace: state.id); return false
        }
        if let slide = session.currentSlide, !OutputContentClassifier.supportsNDI(slide),
           !rows.contains(where: { windows[$0.id] != nil }) {
            setIssue("This content needs an available native output.", workspace: state.id); return false
        }
        state.started = true
        accept(session, into: state, visible: show)
        setIssue(nil, workspace: state.id); changed(workspace: state.id)
        return true
    }
    private func accept(_ session: PresentationSession, into state: OutputWorkspaceProgram, visible: Bool, activate: Bool = true) {
        if activate { let order = state.ownership.beginAction(); _ = state.ownership.take(state.id, action: order) }
        let slide = session.currentSlide
        let kind: OutputContentSnapshot.Kind = slide.map {
            $0.videoURL != nil ? .video : $0.pdfURL != nil ? .pdf : $0.imageURL != nil ? .image : $0.webpageURL != nil ? .webpage : $0.captureWindowID != nil ? .capturedWindow : .lyrics
        } ?? .empty
        state.snapshot = .init(source: state.id, kind: kind, current: OutputContentAdapter.text(for: slide),
            next: session.currentSlideID.flatMap { session.slideIndex(for: $0) }.flatMap { session.slide(at: $0 + 1) }.map { OutputContentAdapter.text(for: $0) },
            visible: visible, revision: state.snapshot.revision &+ 1, localMedia: slide)
    }
    private func presentationProblem(for slide: Slide?, rows: [OutputDestinationConfiguration]) -> String? {
        let available = availableDestinations(rows)
        if slide?.webpageURL != nil {
            let audience = rows.filter { $0.enabled && $0.isMonitorDestination && profiles.profile($0.profileID)?.kind == .audience }
            if audience.count > 1 { return "Live webpages support one Audience output. Disable the extra Audience output or use a companion profile." }
            if !audience.contains(where: { $0.monitor.flatMap { displays.resolve($0) } != nil }) { return "Live webpages need an enabled Audience output with an available monitor." }
        }
        if let slide, !OutputContentClassifier.supportsNDI(slide), !available.contains(where: { $0.isMonitorDestination }) {
            return "NDI supports lyrics, PDFs, images and video files. Use a native monitor for webpages and picked windows."
        }
        return nil
    }
    func passiveLocal(_ session: PresentationSession) {
        guard profiles.document.workspaces.contains(where: { $0.id == session.outputSourceID }) else { return }
        let state = program(session.outputSourceID)
        guard state.ownership.source == state.id else { return }
        if let problem = presentationProblem(for: session.currentSlide, rows: destinations(workspace: state.id).filter(\.enabled)) {
            setIssue(problem, workspace: state.id); return
        }
        accept(session, into: state, visible: state.snapshot.visible, activate: false); changed(workspace: state.id)
    }
    private func cancelRequests(_ state: OutputWorkspaceProgram) { _ = state.actionClock.next(); state.session?.cancelPendingProjection() }
    func hide(for session: PresentationSession? = nil) {
        if let session, !profiles.document.workspaces.contains(where: { $0.id == session.outputSourceID }) { return }
        let state = (session.map { program($0.outputSourceID) }) ?? commandProgram
        cancelRequests(state); state.ownership.revoke(); state.snapshot.visible = false
        changed(workspace: state.id)
    }
    func clear(for session: PresentationSession? = nil) {
        if let session, !profiles.document.workspaces.contains(where: { $0.id == session.outputSourceID }) { return }
        let state = (session.map { program($0.outputSourceID) }) ?? commandProgram
        cancelRequests(state); state.ownership.revoke()
        state.snapshot.current = .empty; state.snapshot.next = nil; state.snapshot.localMedia = nil; state.snapshot.kind = .empty
        changed(workspace: state.id)
    }
    /// Ordinary stop is workspace scoped. Stop All Outputs is deliberately separate.
    func stop(for session: PresentationSession? = nil) {
        stop(workspace: session?.outputSourceID ?? commandProgram.id)
        changed()
    }
    private func stop(workspace: UUID) {
        guard profiles.document.workspaces.contains(where: { $0.id == workspace }) else { return }
        let state = program(workspace); cancelRequests(state); state.ownership.revoke(); state.started = false; state.backgroundOpen = false
        for row in destinations(workspace: workspace) {
            standbySuppressed.insert(row.id); closeDestination(row.id); ndi.stop(row.id)
        }
        state.snapshot = .init(source: workspace, visible: false, revision: state.snapshot.revision &+ 1)
    }
    func stopAllOutputs() {
        for id in Array(programs.keys) { stop(workspace: id) }
        for id in ndi.activeIDs { ndi.stop(id) }
        changed()
    }
    func closeOutput(_ id: UUID) {
        guard let owner = destination(id)?.workspaceID else { return }
        cancelRequests(program(owner)); standbySuppressed.insert(id)
        closeDestination(id); ndi.stop(id); changed(workspace: owner)
    }
    func destinationClosed(_ id: UUID, generation: UUID) {
        guard windows[id]?.generation == generation else { return }; closeOutput(id)
    }
    private func closeDestination(_ id: UUID) {
        windows.removeValue(forKey: id)?.close(); targets[id] = nil; displays.unlock(owner: id); readiness[id] = .closed
        if windows.isEmpty { sleepPrevention.stop() }
    }
    func openConfidence(_ id: UUID) { standbySuppressed.remove(id); scheduleConfidenceStandby() }
    func openBackgroundOutputs(for session: PresentationSession? = nil) -> Bool {
        if let session, !profiles.document.workspaces.contains(where: { $0.id == session.outputSourceID }) { return false }
        guard let session = session ?? commandSession else { return false }
        let state = program(session.outputSourceID)
        if isPresenting(workspace: state.id) { return true }
        guard openDestinations(destinations(workspace: state.id).filter { $0.enabled && $0.isMonitorDestination }), isRunning(workspace: state.id) else {
            setIssue("Background visuals need an available native output.", workspace: state.id, reason: .background); return false
        }
        state.backgroundOpen = true; state.snapshot.visible = false; changed(workspace: state.id); return true
    }
    private func availableDestinations(_ rows: [OutputDestinationConfiguration]) -> [OutputDestinationConfiguration] {
        let conflicts = profiles.conflictingDestinationIDs
        return rows.filter { row in
            guard row.enabled, !conflicts.contains(row.id) else { return false }
            if row.ndi?.isValid == true { return true }
            guard let target = row.monitor, displays.resolve(target) != nil else { return false }
            return windows[row.id] != nil || !displays.isReserved(target)
        }
    }
    private func openDestinations(_ rows: [OutputDestinationConfiguration]) -> Bool {
        displays.refresh(); var ready = false
        for row in availableDestinations(rows) {
            if row.ndi != nil { if ndi.start(row) { ready = true } }
            else if openDestination(row, activate: true) { ready = true }
        }
        return ready
    }
    private func openDestination(_ row: OutputDestinationConfiguration, activate: Bool) -> Bool {
        guard row.workspaceID != nil, profiles.profile(row.profileID) != nil else { return false }
        if windows[row.id] != nil { return true }
        guard let target = row.monitor, let monitor = displays.resolve(target) else { readiness[row.id] = .displayMissing; return false }
        guard !displays.isReserved(target) else { readiness[row.id] = .unavailable; return false }
        let driver = driverFactory()
        guard driver.open(monitor: monitor, coordinator: self, destinationID: row.id, activate: activate) else { readiness[row.id] = .unavailable; return false }
        windows[row.id] = driver; targets[row.id] = target; displays.lock(target, owner: row.id)
        readiness[row.id] = .ready; standbySuppressed.remove(row.id); sleepPrevention.start(); return true
    }
    private func scheduleConfidenceStandby() {
        guard workspaceReady, !standbyScheduled else { return }; standbyScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }; self.standbyScheduled = false
            guard self.profiles.recoveryNotice == nil else { return }
            for row in self.availableDestinations(self.profiles.document.destinations) where row.monitor != nil && row.workspaceID != nil && self.profiles.profile(row.profileID)?.kind == .confidence && self.windows[row.id] == nil && !self.standbySuppressed.contains(row.id) {
                if !self.openDestination(row, activate: false) { self.standbySuppressed.insert(row.id) }
            }
            self.changed()
        }
    }
    func monitorAssignmentProblem(for target: ProjectionMonitorTarget, destinationID: UUID) -> String? {
        displays.problem(for: target) ?? profiles.monitorAssignmentProblem(for: target, excluding: destinationID)
    }
    @discardableResult func assignMonitor(_ target: ProjectionMonitorTarget?, to id: UUID) -> Bool {
        guard windows[id] == nil, let row = destination(id), row.isMonitorDestination else { return false }
        if let target, let problem = monitorAssignmentProblem(for: target, destinationID: id) {
            // Keep a failed Show request eligible for revalidation after this
            // assignment attempt. Fixing one row need not resolve its content constraint.
            let reason: IssueReason
            if let owner = row.workspaceID, case .presentation? = issueReasons[owner] { reason = .presentation }
            else { reason = .assignment(id, target) }
            setIssue(problem, workspace: row.workspaceID, reason: reason); return false
        }
        if id == profiles.document.destinations.first?.id, !displays.setSelection(target, owner: id) { return false }
        profiles.edit { doc in if let i = doc.destinations.firstIndex(where: { $0.id == id }) { doc.destinations[i].monitor = target } }
        if let owner = row.workspaceID, case .assignment? = issueReasons[owner] { setIssue(nil, workspace: owner) }
        refreshIssues(); return true
    }
    func destinationStatuses() -> [OutputDestinationStatus] {
        profiles.document.destinations.filter(\.enabled).map { row in
            let state: OutputReadiness
            if profiles.conflictingDestinationIDs.contains(row.id) { state = .unavailable }
            else if row.ndi != nil {
                switch ndi.state(row.id) {
                case .stopped: state = .closed
                case .starting: state = .starting
                case .stopping: state = .stopping
                case .publishing: state = .publishing
                case .sending: state = .sending
                case .failed: state = .unavailable
                }
            } else if let target = row.monitor, displays.resolve(target) != nil {
                state = windows[row.id] != nil ? .ready : displays.isReserved(target) ? .unavailable : .closed
            } else { state = .displayMissing }
            return .init(id: row.id, name: row.name, profileID: row.profileID, readiness: state)
        }
    }
    private func profilesChanged() {
        ndi.reconcile(profiles.document)
        let previous = standbyConfigurations; standbyConfigurations = profiles.document.destinations
        let previousConfidence = confidenceDestinationIDs
        confidenceDestinationIDs = Set(standbyConfigurations.filter { profiles.profile($0.profileID)?.kind == .confidence }.map(\.id))
        for old in previous where old.enabled {
            let next = destination(old.id)
            if next == nil || next?.enabled == false || next?.workspaceID != old.workspaceID || next?.monitor != old.monitor {
                if let owner = old.workspaceID { cancelRequests(program(owner)) }
            }
        }
        standbySuppressed.formIntersection(Set(standbyConfigurations.map(\.id)))
        for row in standbyConfigurations where row.enabled {
            let old = previous.first { $0.id == row.id }
            if old?.enabled != true || old?.monitor != row.monitor || old?.workspaceID != row.workspaceID
                || (!previousConfidence.contains(row.id) && confidenceDestinationIDs.contains(row.id)) {
                standbySuppressed.remove(row.id)
            }
        }
        for id in Array(windows.keys) {
            if let row = destination(id), row.enabled, row.workspaceID != nil, row.monitor == targets[id], !profiles.conflictingDestinationIDs.contains(id) { continue }
            closeDestination(id)
        }
        // Resolve saved missing workspace IDs as unassigned, never as the focused tab.
        refreshIssues(); changed(); scheduleConfidenceStandby()
    }
    private func displaysChanged() {
        let selectionChanged = legacyMonitorTarget != displays.target; legacyMonitorTarget = displays.target
        if selectionChanged, let first = profiles.document.destinations.first, first.isMonitorDestination, windows[first.id] == nil, first.monitor != displays.target {
            profiles.edit { $0.destinations[0].monitor = displays.target }
        }
        for id in Array(windows.keys) {
            if let target = targets[id], let monitor = displays.resolve(target), windows[id]?.reposition(monitor: monitor) == true { continue }
            if let owner = destination(id)?.workspaceID {
                cancelRequests(program(owner)); setIssue("An output monitor disconnected. Show Slides to reopen it after reconnecting.", workspace: owner, reason: .disconnected)
            }
            standbySuppressed.insert(id); closeDestination(id); readiness[id] = .displayMissing
        }
        refreshIssues(); changed(); scheduleConfidenceStandby()
    }
    func claimBackgroundAudio(_ session: PresentationSession) {
        guard profiles.document.workspaces.contains(where: { $0.id == session.outputSourceID }) else { return }
        guard audioSession !== session else { return }; audioSession?.stopBackgroundAudioPlayback()
        audioWeak = session; retainedAudio = retainsPreparedSessions ? session : nil; refreshMedia()
    }
    func setBackgroundVisualBookmark(_ bookmark: String, for session: PresentationSession) {
        for row in destinations(workspace: session.outputSourceID) where row.enabled {
            profiles.editDestinationProfile(row.id) {
                $0.background.bookmark = bookmark.isEmpty ? nil : bookmark
                $0.background.visible = !bookmark.isEmpty
            }
        }
    }
    func clearAudio() { commandSession?.clearBackgroundAudio() }
    func clearAllLayers() { hide(); clearBackgrounds(); clearAudio() }
    func clearBackgrounds(for session: PresentationSession? = nil) {
        let id = session?.outputSourceID ?? commandProgram.id
        for row in destinations(workspace: id) where row.enabled { profiles.clearDestinationBackground(row.id) }
        programs[id]?.session?.setBackgroundVisual(nil)
    }
    func setAudienceBackgroundVisibility(_ visible: Bool, for session: PresentationSession? = nil) {
        let id = session?.outputSourceID ?? commandProgram.id
        for row in destinations(workspace: id) where row.enabled { profiles.editDestinationProfile(row.id) { $0.background.visible = visible } }
    }
    func refreshMedia(publish: Bool = true) {
        for state in Array(programs.values) { refreshMedia(state, publish: publish) }
    }
    private func refreshMedia(_ state: OutputWorkspaceProgram, publish: Bool) {
        let rows = destinations(workspace: state.id)
        let live = rows.filter { isOpen($0.id) }
        let playbackReady = live.contains { $0.isMonitorDestination || ndi.state($0.id) != .starting }
        state.session?.updateBackgroundAudioLocalPlayback(enabled: localBackgroundAudioEnabled(workspace: state.id))
        state.media.updateProgram(slide: state.snapshot.localMedia, session: state.session,
            running: state.started && !live.isEmpty, visible: state.snapshot.visible && playbackReady,
            localAudioEnabled: monitorAudioLocally(workspace: state.id) || live.contains { $0.isMonitorDestination })
        let active = Set(live.map(\.profileID))
        let workspaceID = state.id
        state.media.syncBackgrounds(profiles: profiles.document.profiles.filter { active.contains($0.id) }, visible: state.snapshot.visible,
            media: state.snapshot.localMedia.map { OutputContentClassifier.mode(for: $0) == .media } ?? false) { [weak self] in self?.changed(workspace: workspaceID) }
        if publish {
            var document = profiles.document; document.destinations = rows
            ndi.publish(state.snapshot, document: document, media: state.media, audioSession: audioSession)
        }
    }
    private func changed(workspace: UUID? = nil) {
        for state in Array(programs.values) where workspace == nil || state.id == workspace {
            let running = isRunning(workspace: state.id)
            if !running {
                if state.started { cancelRequests(state); state.snapshot.visible = false }
                state.started = false; state.backgroundOpen = false; state.ownership.revoke()
            }
            state.snapshot.revision &+= 1
            refreshMedia(state, publish: true)
            state.session?.applyOutputState(running: state.started && running, visible: state.snapshot.visible)
        }
        publishIssues()
        // Observers must see the completed ownership/media transaction.
        revision &+= 1
    }
    private func ndiMessage(_ message: String, id: UUID) -> String {
        guard let row = destination(id) else { return "NDI output: " + message }
        let duplicate = profiles.document.destinations.filter { $0.name == row.name }.count > 1
        return row.name + (duplicate ? " (" + (row.ndi?.sourceName ?? profiles.workspaceName(row.workspaceID)) + ")" : "") + ": " + message
    }
    private func refreshIssues() {
        for (id, reason) in issueReasons {
            let message: String?
            let rows = destinations(workspace: id).filter(\.enabled)
            switch reason {
            case .presentation:
                message = presentationProblem(for: programs[id]?.session?.currentSlide, rows: rows)
                    ?? (availableDestinations(rows).isEmpty ? "Choose an available output assigned to this workspace in Manage Outputs before presenting." : nil)
            case .background:
                message = availableDestinations(rows).contains { $0.monitor != nil } ? nil : "Background visuals need an available native output."
            case .assignment(let destinationID, let target):
                message = destination(destinationID).map { _ in monitorAssignmentProblem(for: target, destinationID: destinationID) } ?? nil
            case .disconnected:
                message = "An output monitor disconnected. Show Slides to reopen it after reconnecting."
            case .transfer:
                // A failed move leaves ownership unchanged. Keep its explanation
                // in the requesting workspace until retry succeeds or dismissal.
                message = issues[id]
            }
            setIssue(message, workspace: id, reason: reason)
        }
    }
    private func setIssue(_ message: String?, workspace: UUID?, reason: IssueReason = .presentation) {
        guard let workspace else { issue = message; return }
        issues[workspace] = message; issueReasons[workspace] = message == nil ? nil : reason
        publishIssues()
    }
    private func workspaceIssue(_ id: UUID) -> String? {
        let rows = destinations(workspace: id).filter(\.enabled)
        let failures = rows.compactMap { row -> String? in
            guard let reason = ndi.state(row.id).failureReason, dismissedNDIFailures[row.id] != reason else { return nil }
            return ndiMessage(reason, id: row.id)
        }
        let warnings = rows.compactMap { row -> String? in
            guard !dismissedNDIPerformance.contains(row.id), let notice = ndi.performanceNotice(row.id) else { return nil }
            return ndiMessage(notice, id: row.id)
        }
        let messages = [issues[id]].compactMap { $0 } + failures + warnings
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }
    private func publishIssues() {
        dismissedNDIPerformance = dismissedNDIPerformance.filter { destination($0)?.enabled == true && ndi.performanceNotice($0) != nil }
        dismissedNDIFailures = dismissedNDIFailures.filter { destination($0.key)?.enabled == true && ndi.state($0.key).failureReason == $0.value }
        for state in programs.values {
            let message = workspaceIssue(state.id)
            if state.session?.projectionDisplayIssue != message { state.session?.projectionDisplayIssue = message }
        }
        let message = focusedWorkspaceID.flatMap(workspaceIssue) ?? profiles.monitorConflictNotice
        if issue != message { issue = message }
    }
    func dismissIssue(workspace: UUID? = nil) {
        let id = workspace ?? focusedProgram.id
        for row in destinations(workspace: id) {
            if ndi.performanceNotice(row.id) != nil { dismissedNDIPerformance.insert(row.id) }
            if let reason = ndi.state(row.id).failureReason { dismissedNDIFailures[row.id] = reason }
        }
        setIssue(nil, workspace: id)
    }
    deinit {
        if let stopObserver { NotificationCenter.default.removeObserver(stopObserver) }
        let displays = displays, profiles = profiles, displayObservation = displayObservation, profileObservation = profileObservation, windows = windows
        DispatchQueue.main.async {
            if let displayObservation { displays.removeObserver(displayObservation) }
            if let profileObservation { profiles.removeObserver(profileObservation) }
            for (id, driver) in windows { driver.close(); displays.unlock(owner: id) }
        }
    }
}
