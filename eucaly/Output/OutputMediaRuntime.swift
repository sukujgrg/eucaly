import AVFoundation
import Combine

/// One program playback owner. Destinations render the same AVPlayer; closing
/// an individual view never resets playback or adds an audio owner.
@MainActor
final class OutputMediaRuntime: ObservableObject {
    private let bookmarkResolver: @Sendable (String) async -> URL?
    init(bookmarkResolver: @escaping @Sendable (String) async -> URL? = { bookmark in
        await Task.detached { SecurityScopedBookmarks.resolve(bookmark)?.url }.value
    }) { self.bookmarkResolver = bookmarkResolver }
    private var programPlayer: AVPlayer?
    var program: AVPlayer? { programPlayer }
    private var programURL: URL?
    private var programGeneration = UUID()
    private var programVisible = false
    private var loopObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var durationTask: Task<Void, Never>?
    private var seekRevision = -1
    private weak var session: PresentationSession?
    private var backgrounds: [String: BackgroundResource] = [:]
    private var backgroundURLs: [UUID: URL] = [:]
    private var bookmarkTasks: [UUID: Task<Void, Never>] = [:]
    private var requestedBookmarks: [UUID: String] = [:]
    private var scopedURLs: [UUID: URL] = [:]

    private final class BackgroundResource {
        let player: AVPlayer
        var endObserver: NSObjectProtocol?
        var wantsPlayback = false
        func setPlayback(_ play: Bool) { wantsPlayback = play; if play { player.play() } else { player.pause() } }
        init(url: URL) {
            player = AVPlayer(url: url); player.allowsExternalPlayback = false; player.isMuted = true
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.wantsPlayback else { return }
                    self.player.seek(to: .zero); self.player.play()
                }
            }
        }
        deinit {
            player.pause()
            if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        }
    }
    func updateProgram(slide: Slide?, session: PresentationSession?, running: Bool, visible: Bool) {
        programVisible = visible && running
        let url = running ? slide?.videoURL : nil
        if programURL != url || self.session !== session {
            stopProgram()
            self.session = session; programURL = url
            if let url {
                let player = AVPlayer(url: url); player.allowsExternalPlayback = false
                programPlayer = player
                let generation = programGeneration
                timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.programGeneration == generation, let player = self.program else { return }
                        self.session?.updateVideoPlaybackProgress(currentTime: player.currentTime().seconds, duration: player.currentItem?.duration.seconds ?? 0)
                    }
                }
                loopObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        guard let self, self.programGeneration == generation, self.session?.videoLoop == true, self.programVisible, self.session?.videoPaused != true else { return }
                        self.program?.seek(to: .zero); self.program?.play()
                    }
                }
                durationTask = Task { [weak self] in
                    let duration = try? await AVURLAsset(url: url).load(.duration)
                    guard !Task.isCancelled, let self, self.programGeneration == generation else { return }
                    self.session?.updateVideoPlaybackProgress(currentTime: player.currentTime().seconds, duration: duration?.seconds ?? 0)
                }
            }
        }
        guard let program else { return }
        program.isMuted = session?.videoMuted ?? false
        if visible && session?.videoPaused != true { program.play() } else { program.pause() }
        if let session, session.videoSeekRevision != seekRevision {
            seekRevision = session.videoSeekRevision
            program.seek(to: CMTime(seconds: session.videoSeekTarget, preferredTimescale: 600))
        }
    }
    private func stopProgram() {
        programGeneration = UUID(); durationTask?.cancel(); durationTask = nil
        program?.pause()
        if let timeObserver { program?.removeTimeObserver(timeObserver) }
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        timeObserver = nil; loopObserver = nil; programPlayer = nil; programURL = nil; seekRevision = -1
    }
    static func isVideo(_ url: URL) -> Bool { ["mp4", "mov", "m4v", "avi", "mkv"].contains(url.pathExtension.lowercased()) }
    func backgroundURL(for profile: OutputProfile) -> URL? { backgroundURLs[profile.id] }
    private func backgroundKey(_ profile: OutputProfile, url: URL) -> String {
        "\(url.standardizedFileURL.absoluteString)|\(profile.background.whenTextShown)|\(profile.background.whenHidden)|\(profile.background.whenMediaShown)"
    }
    func backgroundPlayer(for profile: OutputProfile) -> AVPlayer? {
        guard let url = backgroundURLs[profile.id] else { return nil }
        return backgrounds[backgroundKey(profile, url: url)]?.player
    }
    func syncBackgrounds(profiles: [OutputProfile], visible: Bool, media: Bool, changed: @escaping () -> Void) {
        let ids = Set(profiles.map(\.id))
        for id in Array(requestedBookmarks.keys) where !ids.contains(id) {
            bookmarkTasks.removeValue(forKey: id)?.cancel(); requestedBookmarks.removeValue(forKey: id)
            backgroundURLs.removeValue(forKey: id)
            scopedURLs.removeValue(forKey: id)?.stopAccessingSecurityScopedResource()
        }
        for profile in profiles {
            let bookmark = profile.background.bookmark ?? ""
            if requestedBookmarks[profile.id] != bookmark {
                requestedBookmarks[profile.id] = bookmark
                bookmarkTasks[profile.id]?.cancel()
                backgroundURLs.removeValue(forKey: profile.id)
                scopedURLs.removeValue(forKey: profile.id)?.stopAccessingSecurityScopedResource()
                guard !bookmark.isEmpty else { continue }
                // Bookmark resolution and filesystem access never run in a View body.
                bookmarkTasks[profile.id] = Task {
                    let url = await bookmarkResolver(bookmark)
                    guard !Task.isCancelled, requestedBookmarks[profile.id] == bookmark else { return }
                    if let url {
                        if url.startAccessingSecurityScopedResource() { scopedURLs[profile.id] = url }
                        backgroundURLs[profile.id] = url
                    }
                    changed()
                }
            }
        }
        var wanted: [String: (URL, Bool)] = [:]
        for profile in profiles {
            guard let url = backgroundURLs[profile.id], Self.isVideo(url) else { continue }
            let config = profile.background
            let showing = config.visible && (!visible ? config.whenHidden : media ? config.whenMediaShown : config.whenTextShown)
            let key = backgroundKey(profile, url: url)
            wanted[key] = (url, (wanted[key]?.1 ?? false) || showing)
        }
        for key in Array(backgrounds.keys) where wanted[key] == nil { backgrounds.removeValue(forKey: key) }
        for (key, value) in wanted {
            if backgrounds[key] == nil { backgrounds[key] = BackgroundResource(url: value.0) }
            backgrounds[key]?.setPlayback(value.1)
        }
    }
    var backgroundResourceCount: Int { backgrounds.count }
    func stop() {
        stopProgram(); backgrounds.removeAll()
        for task in bookmarkTasks.values { task.cancel() }
        bookmarkTasks.removeAll(); requestedBookmarks.removeAll(); backgroundURLs.removeAll()
        for url in scopedURLs.values { url.stopAccessingSecurityScopedResource() }
        scopedURLs.removeAll()
    }
    deinit {
        programPlayer?.pause(); durationTask?.cancel()
        if let timeObserver { programPlayer?.removeTimeObserver(timeObserver) }
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        for task in bookmarkTasks.values { task.cancel() }
        for url in scopedURLs.values { url.stopAccessingSecurityScopedResource() }
    }
}
