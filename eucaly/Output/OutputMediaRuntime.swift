import AVFoundation

/// One program playback owner. Destinations render the same AVPlayer; closing
/// an individual view never resets playback or adds an audio owner.
@MainActor
final class OutputMediaRuntime {
    let networkVideoFrames = NetworkSharedVideoFrames()
    let programAudioGain = ProgramAudioGain()
    private let bookmarkResolver: @Sendable (String) async -> URL?
    init(bookmarkResolver: @escaping @Sendable (String) async -> URL? = { bookmark in
        await Task.detached { SecurityScopedBookmarks.resolve(bookmark)?.url }.value
    }) { self.bookmarkResolver = bookmarkResolver }
    private var programPlayer: AVPlayer?
    var program: AVPlayer? { programPlayer }
    var hasRunningPlayback: Bool {
        programPlayer.map { $0.rate != 0 || $0.timeControlStatus == .waitingToPlayAtSpecifiedRate } == true
            || backgrounds.values.contains { $0.wantsPlayback }
    }
    private(set) var programFill = false
    private var programURL: URL?
    private var programGeneration = UUID()
    private var programVisible = false
    private var loopObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var durationTask: Task<Void, Never>?
    private var seekRevision = -1
    private weak var session: PresentationSession?
    private var backgrounds: [String: BackgroundResource] = [:]
    // A source belongs to all active profiles that use its bookmark. Appearance
    // customization changes profile identity, not the source or its lifetime.
    private var backgroundURLs: [String: URL] = [:]
    private var bookmarkTasks: [String: Task<Void, Never>] = [:]
    private var bookmarkAdmissionGuards: [String: (URL) -> OutputCoordinator.FileAcquisitionAdmission] = [:]
    private var requestedBookmarks: Set<String> = []
    private var scopedURLs: [String: URL] = [:]
    // A deferred resolution is intent, not an acquired resource. Its exact
    // reservation releases it for retry after failure or an unrelated removal.
    private struct DeferredBackground {
        let url: URL
        let reservationID: UUID
    }
    private var deferredBackgrounds: [String: DeferredBackground] = [:]

    var referencedFileURLs: Set<URL> {
        var urls = Set(backgroundURLs.values.map(\.standardizedFileURL))
        urls.formUnion(scopedURLs.values.map(\.standardizedFileURL))
        urls.formUnion(backgrounds.values.map { $0.url.standardizedFileURL })
        if let programURL { urls.insert(programURL.standardizedFileURL) }
        return urls
    }

    func retainsFile(where matches: (URL) -> Bool) -> Bool {
        referencedFileURLs.contains(where: matches)
    }

    private final class BackgroundResource {
        let url: URL
        let player: AVPlayer
        var endObserver: NSObjectProtocol?
        var wantsPlayback = false
        func setPlayback(_ play: Bool) { wantsPlayback = play; if play { player.play() } else { player.pause() } }
        init(url: URL) {
            self.url = url
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
    func updateProgram(slide: Slide?, session: PresentationSession?, running: Bool, visible: Bool,
                       localAudioEnabled: Bool = true, documentRevision: UInt64? = nil,
                       canAcquireFile: (URL) -> Bool = { _ in true }) {
        let url = running ? slide?.videoURL : nil
        if let url, (programURL != url || self.session !== session), !canAcquireFile(url) { return }
        programFill = session?.videoFill ?? false
        programVisible = visible && running
        programAudioGain.set(session?.videoMuted == true ? 0 : 1)
        if programURL != url || self.session !== session {
            stopProgram()
            self.session = session; programURL = url
            if let url {
                let player = AVPlayer(url: url); player.allowsExternalPlayback = false
                // Set the local output level before the first play/preroll.
                // NDI reads programme gain separately, before this output gain.
                player.volume = localAudioEnabled ? 1 : 0
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
        program.volume = localAudioEnabled ? 1 : 0
        program.isMuted = session?.videoMuted ?? false
        if visible && session?.videoPaused != true { program.play() } else { program.pause() }
        // Current can hold a replacement document before output accepts it.
        // Its progress reset must not seek the previously accepted live video,
        // including when a later appearance/audio edit refreshes that program.
        if let session, documentRevision == nil || documentRevision == session.documentRevision,
           session.videoSeekRevision != seekRevision {
            seekRevision = session.videoSeekRevision
            program.seek(to: CMTime(seconds: session.videoSeekTarget, preferredTimescale: 600))
        }
    }
    private func stopProgram() {
        if let program { networkVideoFrames.stop(player: program) }
        programGeneration = UUID(); durationTask?.cancel(); durationTask = nil
        program?.pause()
        if let timeObserver { program?.removeTimeObserver(timeObserver) }
        if let loopObserver { NotificationCenter.default.removeObserver(loopObserver) }
        timeObserver = nil; loopObserver = nil; programPlayer = nil; programURL = nil; seekRevision = -1
    }
    static func isVideo(_ url: URL) -> Bool { ["mp4", "mov", "m4v", "avi", "mkv"].contains(url.pathExtension.lowercased()) }
    func backgroundURL(for profile: OutputProfile) -> URL? {
        profile.background.bookmark.flatMap { backgroundURLs[$0] }
    }
    private func backgroundKey(_ profile: OutputProfile, url: URL) -> String {
        "\(url.standardizedFileURL.absoluteString)|\(profile.background.whenTextShown)|\(profile.background.whenHidden)|\(profile.background.whenMediaShown)"
    }
    func backgroundPlayer(for profile: OutputProfile) -> AVPlayer? {
        guard let url = backgroundURL(for: profile) else { return nil }
        return backgrounds[backgroundKey(profile, url: url)]?.player
    }
    func syncBackgrounds(profiles: [OutputProfile], visible: Bool, media: Bool,
                         canAcquireFile: (URL) -> Bool = { _ in true },
                         makeFileAcquisitionGuard: () -> (URL) -> OutputCoordinator.FileAcquisitionAdmission = { { _ in .allowed } },
                         changed: @escaping () -> Void) {
        let bookmarks = Set(profiles.compactMap(\.background.bookmark).filter { !$0.isEmpty })
        for bookmark in requestedBookmarks.subtracting(bookmarks) {
            bookmarkTasks.removeValue(forKey: bookmark)?.cancel()
            bookmarkAdmissionGuards.removeValue(forKey: bookmark)
            backgroundURLs.removeValue(forKey: bookmark)
            deferredBackgrounds.removeValue(forKey: bookmark)
            scopedURLs.removeValue(forKey: bookmark)?.stopAccessingSecurityScopedResource()
        }
        let added = bookmarks.subtracting(requestedBookmarks)
        requestedBookmarks = bookmarks
        for bookmark in added {
            // Bookmark resolution and filesystem access never run in a View body.
            let resolve = bookmarkResolver
            // Keep the ticket outside the awaiting task: cancellation must
            // release it even if the resolver does not finish cooperatively.
            bookmarkAdmissionGuards[bookmark] = makeFileAcquisitionGuard()
            bookmarkTasks[bookmark] = Task { [weak self] in
                let url = await resolve(bookmark)
                guard !Task.isCancelled, let self, self.requestedBookmarks.contains(bookmark) else { return }
                self.bookmarkTasks.removeValue(forKey: bookmark)
                guard let admission = self.bookmarkAdmissionGuards.removeValue(forKey: bookmark) else { return }
                if let url {
                    switch admission(url) {
                    case .deferred(let reservationID):
                        self.deferredBackgrounds[bookmark] = .init(url: url, reservationID: reservationID)
                        changed()
                        return
                    case .removed:
                        self.deferredBackgrounds.removeValue(forKey: bookmark)
                        changed()
                        return
                    case .allowed:
                        break
                    }
                    self.deferredBackgrounds.removeValue(forKey: bookmark)
                    if url.startAccessingSecurityScopedResource() { self.scopedURLs[bookmark] = url }
                    self.backgroundURLs[bookmark] = url
                }
                changed()
            }
        }
        var wanted: [String: (URL, Bool)] = [:]
        for profile in profiles {
            guard let url = backgroundURL(for: profile), Self.isVideo(url) else { continue }
            let config = profile.background
            let showing = config.visible && (!visible ? config.whenHidden : media ? config.whenMediaShown : config.whenTextShown)
            let key = backgroundKey(profile, url: url)
            wanted[key] = (url, (wanted[key]?.1 ?? false) || showing)
        }
        for key in Array(backgrounds.keys) where wanted[key] == nil {
            if let resource = backgrounds.removeValue(forKey: key) { networkVideoFrames.stop(player: resource.player) }
        }
        for (key, value) in wanted {
            if backgrounds[key] == nil {
                guard canAcquireFile(value.0) else { continue }
                backgrounds[key] = BackgroundResource(url: value.0)
            }
            backgrounds[key]?.setPlayback(value.1)
        }
    }
    @discardableResult
    func finishFileRemoval(reservationID: UUID, matching matches: (URL) -> Bool, removed: Bool) -> Bool {
        let deferred = deferredBackgrounds.filter { $0.value.reservationID == reservationID }
        var needsRetry = false
        for (bookmark, intent) in deferred {
            deferredBackgrounds.removeValue(forKey: bookmark)
            // The coordinator releases its reservation before the next normal
            // refresh. A successful removal must never follow a bookmark into Trash.
            if !removed || !matches(intent.url) {
                requestedBookmarks.remove(bookmark)
                needsRetry = true
            }
        }
        return needsRetry
    }
    var backgroundResourceCount: Int { backgrounds.count }
    func stop() {
        networkVideoFrames.stop()
        stopProgram(); backgrounds.removeAll()
        for task in bookmarkTasks.values { task.cancel() }
        bookmarkTasks.removeAll(); bookmarkAdmissionGuards.removeAll(); requestedBookmarks.removeAll()
        backgroundURLs.removeAll(); deferredBackgrounds.removeAll()
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
