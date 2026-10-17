import Foundation
import Combine
import AVFoundation

@MainActor
final class SRTMediaOutputRouter: ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private weak var coordinator: OutputCoordinator?
    private var channels: [UUID: SRTMediaTransmission] = [:]
    private var notices: [UUID: String] = [:]
    init(coordinator: OutputCoordinator) { self.coordinator = coordinator }
    private var receiverRouter: AltViewOutputRouter? { coordinator?.remoteOutputs as? AltViewOutputRouter }
    func endpoint(for settings: SRTMediaSettings) -> PairedMediaEndpoint? {
        guard let id = settings.receiverID, let channel = receiverRouter?.receiverChannel(id),
              channel.status.connected, let offer = channel.status.media, offer.receiverID == id,
              offer.isValid, offer.ready, let host = channel.status.mediaHost else { return nil }
        var resolved = settings; resolved.host = host; resolved.port = offer.port
        guard resolved.isValid else { return nil }
        return PairedMediaEndpoint(settings: resolved, offer: offer)
    }
    func synchronize(explicit: Bool) {
        guard let coordinator else { stop(); return }
        let rows = coordinator.profiles.document.destinations.filter {
            $0.enabled && coordinator.profiles.profile($0.profileID)?.kind == .altViewMedia
        }
        let ids = Set(rows.map(\.id))
        for id in Array(channels.keys) where !ids.contains(id) { channels.removeValue(forKey: id)?.stop(); notices[id] = nil }
        for row in rows {
            if let problem = coordinator.profiles.assignmentProblem(for: row) {
                channels.removeValue(forKey: row.id)?.stop()
                notices[row.id] = problem
                continue
            }
            guard let settings = row.srt, let source = row.sourceAudienceID,
                  coordinator.profiles.profile(forDestination: source)?.kind == .audience,
                  let identity = coordinator.windowIdentity(for: source), coordinator.isPresenting else {
                channels.removeValue(forKey: row.id)?.stop()
                notices[row.id] = "Show Slides on the selected Audience output to send media."
                continue
            }
            if let channel = channels[row.id], channel.settings == settings,
               channel.windowID == identity.0, channel.windowGeneration == identity.1 {
                channel.setBackgroundAudioIncluded(row.includeBackgroundAudio); continue
            }
            channels.removeValue(forKey: row.id)?.stop()
            guard explicit else { notices[row.id] = "Show Slides again to start this media output."; continue }
            let channel = SRTMediaTransmission(settings: settings, windowID: identity.0, windowGeneration: identity.1,
                includeBackgroundAudio: row.includeBackgroundAudio, coordinator: coordinator,
                resolve: { [weak self] in self?.endpoint(for: settings) }) { [weak self, weak coordinator] in
                    self?.objectWillChange.send()
                    coordinator?.remoteReadinessChanged()
                    self?.notices[row.id] = nil
                }
            channels[row.id] = channel; channel.start()
        }
    }
    func stopReceiver(_ receiverID: UUID) {
        for (id, channel) in Array(channels) where channel.settings.receiverID == receiverID {
            channels.removeValue(forKey: id)?.stop()
            notices[id] = "Receiver connection changed. Connect this receiver in Settings, then Show Slides or Retry Media again."
        }
    }
    func controlConnectionChanged(_ receiverID: UUID, channel: AltViewService) {
        if !channel.hasConnection || (!channel.status.connected && !channel.status.waitingToRetry && channel.status.failureReason != nil) {
            stopReceiver(receiverID)
        }
    }
    func readiness(for id: UUID) -> OutputReadiness { channels[id]?.connected == true ? .ready : channels[id] == nil ? .closed : .unavailable }
    func detail(for id: UUID) -> String { channels[id]?.status ?? notices[id] ?? "Stopped" }
    func retry(_ id: UUID) { channels.removeValue(forKey: id)?.stop(); synchronize(explicit: true) }
    func stop() { channels.values.forEach { $0.stop() }; channels.removeAll(); notices.removeAll() }
}

struct PairedMediaEndpoint: Equatable {
    let settings: SRTMediaSettings
    let offer: AltViewMediaOffer
}

@MainActor
private final class SRTMediaTransmission {
    private struct ControlChanged: LocalizedError {
        var errorDescription: String? { "Receiver connection changed. Waiting for authenticated Media readiness." }
    }
    let settings: SRTMediaSettings
    let windowID: UInt32
    let windowGeneration: UUID
    private(set) var includeBackgroundAudio: Bool
    private weak var coordinator: OutputCoordinator?
    private let changed: () -> Void
    private let resolve: () -> PairedMediaEndpoint?
    private var task: Task<Void, Never>?
    private var session: SRTMediaSession?
    private var capture: SRTAudienceCapture?
    private var mixer: SRTProgramAudio?
    private var ingest: SRTMediaIngest?
    private var taps: [SRTPlayerAudioTap] = []
    private var failure: String?
    private var attemptID = UUID()
    private var stopped = false
    private(set) var connected = false
    private(set) var status = "Connecting…"
    init(settings: SRTMediaSettings, windowID: UInt32, windowGeneration: UUID,
         includeBackgroundAudio: Bool, coordinator: OutputCoordinator, resolve: @escaping () -> PairedMediaEndpoint?, changed: @escaping () -> Void) {
        self.settings = settings; self.windowID = windowID; self.windowGeneration = windowGeneration
        self.includeBackgroundAudio = includeBackgroundAudio
        self.coordinator = coordinator; self.resolve = resolve; self.changed = changed
    }
    func start() {
        task = Task { [weak self] in
            guard let self else { return }
            var attempt = 0
            while !Task.isCancelled && !self.stopped {
                guard let endpoint = self.resolve() else {
                    self.setStatus("Waiting for paired \(settings.receiverName ?? "AltView") · Connect this receiver in Settings and Start Receiving on that Mac.")
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                let token = UUID(); self.attemptID = token
                let session = SRTMediaSession(), ingest = SRTMediaIngest()
                // Each attempt owns fresh queues so callbacks from a retired
                // player/capture cannot enter its replacement stream.
                let audio = SRTProgramAudio(ingest: ingest)
                self.session = session; self.ingest = ingest; self.mixer = audio; self.failure = nil
                self.setStatus(attempt == 0 ? "Connecting to AltView…" : "Reconnecting to AltView…")
                var connectionIssue: String?
                do {
                    try await session.publish(settings: endpoint.settings, passphrase: endpoint.offer.passphrase, ingest: ingest)
                    guard !self.stopped, !Task.isCancelled else { await session.close(); break }
                    guard self.resolve() == endpoint else { throw ControlChanged() }
                    let capture = SRTAudienceCapture(ingest: ingest, audio: audio) { [weak self] message in
                        guard let self, self.attemptID == token, !self.stopped else { return }
                        self.failure = message
                    }
                    self.capture = capture; self.refreshAudio()
                    try await capture.start(windowID: self.windowID, frameRate: settings.frameRate)
                    guard !self.stopped, !Task.isCancelled else { await capture.stop(); await session.close(); break }
                    self.connected = true; self.setStatus("Sending Audience · 1080p · up to \(settings.frameRate) fps with program audio")
                    attempt = 0
                    while !Task.isCancelled && !self.stopped {
                        if self.failure != nil { break }
                        // Revocation, endpoint changes and readiness are checked on
                        // the authenticated control session, including while live.
                        guard self.resolve() == endpoint else { break }
                        guard await session.isConnected() else { break }
                        self.refreshAudio()
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                } catch {
                    connectionIssue = error.localizedDescription
                    if !self.stopped { self.setStatus("Media unavailable: \(error.localizedDescription)") }
                    // Capture permission/window failures need an explicit retry.
                    if self.capture != nil { self.failure = error.localizedDescription }
                }
                self.attemptID = UUID()
                self.connected = false; ingest.finish(); audio.stop(); self.taps.forEach { $0.stop() }; self.taps.removeAll()
                await self.capture?.stop(); self.capture = nil; await session.close()
                guard !Task.isCancelled, !self.stopped else { break }
                if let failure = self.failure { self.setStatus(failure + " · Retry Media after resolving it."); break }
                attempt += 1
                self.setStatus((connectionIssue ?? "AltView disconnected") + " · retrying…")
                try? await Task.sleep(nanoseconds: UInt64(min(8, attempt * 2)) * 1_000_000_000)
            }
        }
    }
    func setBackgroundAudioIncluded(_ included: Bool) {
        includeBackgroundAudio = included
        refreshAudio()
    }
    func refreshAudio() {
        guard let mixer, let coordinator else { return }
        let players = [coordinator.media.program, includeBackgroundAudio ? coordinator.audioSession?.programBackgroundAudioPlayer : nil].compactMap { $0 }
        taps.removeAll { tap in
            if players.contains(where: { tap.matches($0) }) { return false }
            tap.stop(); return true
        }
        for player in players where !taps.contains(where: { $0.matches(player) }) { taps.append(SRTPlayerAudioTap(player: player, mixer: mixer)) }
        taps.forEach { $0.refresh() }
    }
    private func setStatus(_ value: String) { status = value; changed() }
    func stop() {
        attemptID = UUID(); stopped = true; connected = false; task?.cancel(); task = nil
        ingest?.finish(); mixer?.stop(); taps.forEach { $0.stop() }; taps.removeAll()
        let capture = capture, session = session
        self.capture = nil; self.session = nil
        Task { await capture?.stop(); await session?.close() }
    }
}

private extension OutputProfileStore {
    func profile(forDestination id: UUID) -> OutputProfile? {
        document.destinations.first { $0.id == id }.flatMap { profile($0.profileID) }
    }
}
