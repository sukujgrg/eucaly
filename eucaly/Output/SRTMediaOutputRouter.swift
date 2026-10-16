import Foundation
import Combine
import AVFoundation

@MainActor
final class SRTMediaOutputRouter {
    private weak var coordinator: OutputCoordinator?
    private var channels: [UUID: SRTMediaTransmission] = [:]
    private var notices: [UUID: String] = [:]
    init(coordinator: OutputCoordinator) { self.coordinator = coordinator }
    func synchronize(explicit: Bool) {
        guard let coordinator else { stop(); return }
        let rows = coordinator.profiles.document.destinations.filter {
            $0.enabled && coordinator.profiles.profile($0.profileID)?.kind == .altViewMedia
        }
        let ids = Set(rows.map(\.id))
        for id in Array(channels.keys) where !ids.contains(id) { channels.removeValue(forKey: id)?.stop(); notices[id] = nil }
        for row in rows {
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
                secretAccount: "output-\(row.id.uuidString)", includeBackgroundAudio: row.includeBackgroundAudio, coordinator: coordinator) { [weak self, weak coordinator] in
                    coordinator?.remoteReadinessChanged()
                    self?.notices[row.id] = nil
                }
            channels[row.id] = channel; channel.start()
        }
    }
    func readiness(for id: UUID) -> OutputReadiness { channels[id]?.connected == true ? .ready : channels[id] == nil ? .closed : .unavailable }
    func detail(for id: UUID) -> String { channels[id]?.status ?? notices[id] ?? "Stopped. Show Slides to send the selected Audience picture." }
    func retry(_ id: UUID) { channels.removeValue(forKey: id)?.stop(); synchronize(explicit: true) }
    func stop() { channels.values.forEach { $0.stop() }; channels.removeAll(); notices.removeAll() }
}

@MainActor
private final class SRTMediaTransmission {
    let settings: SRTMediaSettings
    let windowID: UInt32
    let windowGeneration: UUID
    private(set) var includeBackgroundAudio: Bool
    private let secretAccount: String
    private weak var coordinator: OutputCoordinator?
    private let changed: () -> Void
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
    init(settings: SRTMediaSettings, windowID: UInt32, windowGeneration: UUID, secretAccount: String,
         includeBackgroundAudio: Bool, coordinator: OutputCoordinator, changed: @escaping () -> Void) {
        self.settings = settings; self.windowID = windowID; self.windowGeneration = windowGeneration
        self.includeBackgroundAudio = includeBackgroundAudio
        self.secretAccount = secretAccount; self.coordinator = coordinator; self.changed = changed
    }
    func start() {
        task = Task { [weak self] in
            guard let self else { return }
            let passphrase: String
            do {
                guard let saved = try await SRTMediaSecrets.shared.read(secretAccount) else {
                    self.setStatus("Enter and save the passphrase from AltView, then Retry Media."); return
                }
                passphrase = saved
            } catch { self.setStatus(error.localizedDescription); return }
            var attempt = 0
            while !Task.isCancelled && !self.stopped {
                let token = UUID(); self.attemptID = token
                let session = SRTMediaSession(), ingest = SRTMediaIngest()
                // Each attempt owns fresh queues so callbacks from a retired
                // player/capture cannot enter its replacement stream.
                let audio = SRTProgramAudio(ingest: ingest)
                self.session = session; self.ingest = ingest; self.mixer = audio; self.failure = nil
                self.setStatus(attempt == 0 ? "Connecting to AltView…" : "Reconnecting to AltView…")
                do {
                    try await session.publish(settings: settings, passphrase: passphrase, ingest: ingest)
                    guard !self.stopped, !Task.isCancelled else { await session.close(); break }
                    let capture = SRTAudienceCapture(ingest: ingest, audio: audio) { [weak self] message in
                        guard let self, self.attemptID == token, !self.stopped else { return }
                        self.failure = message
                    }
                    self.capture = capture; self.refreshAudio()
                    try await capture.start(windowID: self.windowID, frameRate: settings.frameRate)
                    guard !self.stopped, !Task.isCancelled else { await capture.stop(); await session.close(); break }
                    self.connected = true; self.setStatus("Sending Audience · 1080p\(settings.frameRate) with program audio")
                    attempt = 0
                    while !Task.isCancelled && !self.stopped {
                        if self.failure != nil { break }
                        guard await session.isConnected() else { break }
                        self.refreshAudio()
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                } catch {
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
                self.setStatus("AltView disconnected · retrying…")
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
