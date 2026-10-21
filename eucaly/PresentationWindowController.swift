import SwiftUI
import AppKit
import AVKit
import AVFoundation
import Combine
import PDFKit

@MainActor
final class PlaybackProgressStore: ObservableObject {
    @Published private(set) var videoCurrentTime: Double = 0
    @Published private(set) var videoDuration: Double = 0
    @Published private(set) var backgroundAudioCurrentTime: Double = 0
    @Published private(set) var backgroundAudioDuration: Double = 0

    func updateVideo(currentTime: Double, duration: Double) {
        let normalizedDuration = duration.isFinite && duration > 0 ? duration : 0
        let normalizedTime = currentTime.isFinite && currentTime >= 0 ? currentTime : 0
        // Progress ticks must not republish an unchanged duration or paused
        // position: @Published emits even when the assigned value is equal.
        if videoDuration != normalizedDuration { videoDuration = normalizedDuration }
        let nextTime = min(normalizedTime, max(normalizedDuration, normalizedTime))
        if videoCurrentTime != nextTime { videoCurrentTime = nextTime }
    }

    func resetVideo() {
        videoCurrentTime = 0
        videoDuration = 0
    }

    func seekVideo(to seconds: Double) {
        videoCurrentTime = seconds
    }

    func updateBackgroundAudio(currentTime: Double, duration: Double) {
        let normalizedTime = currentTime.isFinite ? max(0, currentTime) : 0
        let normalizedDuration = duration.isFinite && duration > 0 ? duration : 0

        if abs(backgroundAudioCurrentTime - normalizedTime) > 0.05 {
            backgroundAudioCurrentTime = normalizedTime
        }
        if abs(backgroundAudioDuration - normalizedDuration) > 0.05 {
            backgroundAudioDuration = normalizedDuration
        }
    }

    func resetBackgroundAudio() {
        backgroundAudioCurrentTime = 0
        backgroundAudioDuration = 0
    }

    func seekBackgroundAudio(to seconds: Double) {
        backgroundAudioCurrentTime = seconds
    }
}

@MainActor
final class PresentationSession: NSObject, ObservableObject {
    enum BackgroundAudioPlaybackState: Equatable {
        case stopped
        case paused
        case playing
    }

    @Published var slides: [Slide] = [] { didSet { scheduleOutputChange() } }
    @Published private(set) var currentLyricsSourceURL: URL?
    @Published private(set) var pdfSlideSource: PDFSlideSource? { didSet { scheduleOutputChange() } }
    @Published var currentSlideID: Slide.ID? { didSet { scheduleOutputChange() } }
    @Published var isPresenting = false { didSet { scheduleOutputChange() } }
    @Published var videoMuted = false { didSet { outputCoordinator.refreshMedia() } }
    @Published var videoPaused = false { didSet { outputCoordinator.refreshMedia() } }
    @Published var videoLoop = false { didSet { outputCoordinator.refreshMedia() } }
    @Published var videoFill = false { didSet { outputCoordinator.refreshMedia() } }
    @Published private(set) var videoSeekRevision = 0
    private(set) var videoSeekTarget: Double = 0
    let playbackProgress = PlaybackProgressStore()
    @Published private(set) var backgroundVisualURL: URL? = nil
    @Published var isBackgroundVisualVisible = true
    @Published private(set) var backgroundAudioURL: URL? = nil
    @Published private(set) var backgroundAudioPlaybackState = BackgroundAudioPlaybackState.stopped
    @Published private(set) var backgroundAudioLoop = true
    @Published private(set) var backgroundAudioVolume: Double = 1.0
    @Published var areSlidesVisible = true { didSet { scheduleOutputChange() } }

    private var currentResourceScope: URL?
    private var audioResourceScope: URL?
    func setCurrentResourceScope(_ url: URL?) {
        guard currentResourceScope != url else { return }
        currentResourceScope?.stopAccessingSecurityScopedResource(); currentResourceScope = nil
        if let url, url.startAccessingSecurityScopedResource() { currentResourceScope = url }
    }
    private var backgroundAudioGeneration = UUID()
    private var backgroundAudioPlayer: AVPlayer?
    let backgroundAudioGain = ProgramAudioGain()
    // An explicit Play without an NDI route may request standalone local
    // music. Output transfers/closure never create that request implicitly.
    private(set) var backgroundAudioHasStandaloneLocalRoute = false
    var programBackgroundAudioPlayer: AVPlayer? { backgroundAudioPlayer }
    private var backgroundAudioEndObserver: NSObjectProtocol?
    private var backgroundAudioTimeObserver: Any?

    // The app owns injected coordinators; a standalone session owns its test/runtime
    // coordinator. Prepared Current retention must not form an app/session cycle.
    private let standaloneOutputCoordinator: OutputCoordinator?
    private unowned let linkedOutputCoordinator: OutputCoordinator
    var outputCoordinator: OutputCoordinator { linkedOutputCoordinator }
    let projectionDisplays: ProjectionDisplayManager
    var activePresentationTarget: ProjectionMonitorTarget? { outputCoordinator.audienceTarget(workspace: outputSourceID) }
    @Published var projectionDisplayIssue: String?
    private var currentThumbnailColumnCount: Int = 1
    private var currentDocumentRevision: UInt64 = 0
    // A page's stable slide ID does not change when its source is reloaded.
    // Native PDF views also need this workspace's explicit-load identity.
    var pdfDocumentRevision: UInt64 { currentDocumentRevision }
    let pdfDocumentCache = PDFDocumentCache()
    private var pendingNavigationCount = 0
    private var navigationActionOrder: UInt64?
    private var navigationGeneration = UUID()

    let outputSourceID: UUID
    let outputActionClock: OutputActionClock
    func cancelPendingProjection() {
        navigationGeneration = UUID()
        pendingNavigationCount = 0
        navigationActionOrder = nil
    }

    func applyOutputState(running: Bool, visible: Bool) {
        if isPresenting != running { isPresenting = running }
        if areSlidesVisible != visible { areSlidesVisible = visible }
    }

    private var outputChangeScheduled = false

    private func scheduleOutputChange() {
        guard !outputChangeScheduled else { return }
        outputChangeScheduled = true
        // Read the completed model transaction, never @Published's willSet
        // values or an intermediate selection while replacing Current.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.outputChangeScheduled = false
            self.outputCoordinator.passiveLocal(self)
        }
    }

    /// User activation is distinct from model refreshes and hidden navigation.
    func selectCurrentSlide(_ slideID: Slide.ID) {
        guard containsSlide(id: slideID) else { return }
        if currentSlideID != slideID { currentSlideID = slideID }
        requestCurrentProjection()
    }

    func requestCurrentProjection() {
        guard (isPresenting && areSlidesVisible) else { return }
        guard outputCoordinator.presentLocal(self, activation: .current) else { return }
    }

    var isBackgroundAudioPlaying: Bool {
        backgroundAudioPlaybackState == .playing
    }

    override convenience init() {
        self.init(projectionDisplays: ProjectionDisplayManager())
    }

    init(projectionDisplays: ProjectionDisplayManager,
         sleepPrevention: ProjectionSleepPrevention = ProjectionSleepPrevention(),
         outputCoordinator: OutputCoordinator? = nil, workspaceID: UUID? = nil) {
        self.projectionDisplays = projectionDisplays
        if let outputCoordinator {
            standaloneOutputCoordinator = nil
            linkedOutputCoordinator = outputCoordinator
        } else {
            let coordinator = OutputCoordinator(profiles: OutputProfileStore(monitor: projectionDisplays.target), displays: projectionDisplays, sleepPrevention: sleepPrevention)
            standaloneOutputCoordinator = coordinator
            linkedOutputCoordinator = coordinator
        }
        outputSourceID = workspaceID ?? linkedOutputCoordinator.nextWorkspaceIdentity()
        outputActionClock = linkedOutputCoordinator.program(outputSourceID).actionClock
        super.init()
        self.outputCoordinator.attach(self)
    }

    deinit {
        currentResourceScope?.stopAccessingSecurityScopedResource(); audioResourceScope?.stopAccessingSecurityScopedResource()
        if let backgroundAudioEndObserver { NotificationCenter.default.removeObserver(backgroundAudioEndObserver) }
        if let backgroundAudioTimeObserver, let backgroundAudioPlayer { backgroundAudioPlayer.removeTimeObserver(backgroundAudioTimeObserver) }
    }

    var currentSlide: Slide? {
        guard let currentSlideID else { return nil }
        if let pdfSlideSource {
            guard let pageIndex = PDFSlideCatalog.pageIndex(fromStableSlideID: currentSlideID, url: pdfSlideSource.url) else {
                return nil
            }
            return PDFSlideCatalog.slide(url: pdfSlideSource.url, pageIndex: pageIndex)
        }
        return slides.first { $0.id == currentSlideID }
    }

    var isEmpty: Bool {
        slides.isEmpty && pdfSlideSource == nil
    }

    var slideCount: Int {
        pdfSlideSource?.pageCount ?? slides.count
    }

    var firstSlideID: Slide.ID? {
        if let pdfSlideSource {
            return PDFSlideCatalog.slide(url: pdfSlideSource.url, pageIndex: 0).id
        }
        return slides.first?.id
    }

    func containsSlide(id: Slide.ID) -> Bool {
        if let pdfSlideSource {
            return PDFSlideCatalog.pageIndex(fromStableSlideID: id, url: pdfSlideSource.url) != nil
        }
        return slides.contains { $0.id == id }
    }

    func slide(at index: Int) -> Slide? {
        guard index >= 0, index < slideCount else { return nil }
        if let pdfSlideSource {
            return PDFSlideCatalog.slide(url: pdfSlideSource.url, pageIndex: index)
        }
        return slides[index]
    }

    func slideIndex(for slideID: Slide.ID) -> Int? {
        if let pdfSlideSource {
            return PDFSlideCatalog.pageIndex(fromStableSlideID: slideID, url: pdfSlideSource.url)
        }
        return slides.firstIndex { $0.id == slideID }
    }

    var hasAvailableBackgroundVisual: Bool {
        if outputCoordinator.backgroundVisualVisibility(workspace: outputSourceID) != nil { return true }
        guard let url = backgroundVisualURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func setSlides(
        _ slides: [Slide],
        lyricsSourceURL: URL? = nil,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        currentDocumentRevision &+= 1
        pdfDocumentCache.clear()
        let preservedSelection = preferredSelection ?? currentSlideID
        pdfSlideSource = nil
        currentLyricsSourceURL = slides.isEmpty ? nil : lyricsSourceURL
        self.slides = slides
        if let preservedSelection,
           slides.contains(where: { $0.id == preservedSelection }) {
            currentSlideID = preservedSelection
        } else if let preferredSelectionIndex,
                  slides.indices.contains(preferredSelectionIndex) {
            currentSlideID = slides[preferredSelectionIndex].id
        } else {
            currentSlideID = slides.first?.id
        }
        resetVideoPlaybackProgress()
    }

    func setPDFSlideSource(
        _ source: PDFSlideSource,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        currentDocumentRevision &+= 1
        pdfDocumentCache.clear()
        slides = []
        currentLyricsSourceURL = nil
        pdfSlideSource = source

        if let preferredSelection,
           PDFSlideCatalog.pageIndex(fromStableSlideID: preferredSelection, url: source.url) != nil {
            currentSlideID = preferredSelection
        } else if let preferredSelectionIndex,
                  (0..<source.pageCount).contains(preferredSelectionIndex) {
            currentSlideID = PDFSlideCatalog.slide(url: source.url, pageIndex: preferredSelectionIndex).id
        } else {
            currentSlideID = PDFSlideCatalog.slide(url: source.url, pageIndex: 0).id
        }
        resetVideoPlaybackProgress()
    }

    func clearSlides() {
        cancelPendingProjection()
        outputCoordinator.clear(for: self)
        currentDocumentRevision &+= 1
        pdfDocumentCache.clear()
        slides = []
        currentLyricsSourceURL = nil
        pdfSlideSource = nil
        currentSlideID = nil
        setCurrentResourceScope(nil)
        resetVideoPlaybackProgress()
    }

    func stopPresentation() {
        outputCoordinator.stop(for: self)
        isPresenting = false
    }

    func showSlides() {
        guard outputCoordinator.presentLocal(self) else { return }
        areSlidesVisible = true
    }

    /// Slide commands require Current content; output and background controls
    /// can still open their destinations independently.
    func toggleSlidesVisibility() {
        guard !isEmpty else { return }
        if isPresenting && areSlidesVisible {
            hideSlides()
        } else {
            if currentSlide == nil { currentSlideID = firstSlideID }
            showSlides()
        }
    }

    func hideSlides() {
        guard isPresenting else { return }
        areSlidesVisible = false
        if outputCoordinator.isRunning(workspace: outputSourceID) { outputCoordinator.hide(for: self) }
    }

    func toggleBackgroundVisualVisibility() {
        guard hasAvailableBackgroundVisual else { return }
        if !isPresenting && !outputCoordinator.hasOpenAudienceOutput(workspace: outputSourceID) {
            guard outputCoordinator.openBackgroundOutputs(for: self) else { return }
            isBackgroundVisualVisible = true
            outputCoordinator.setAudienceBackgroundVisibility(true, for: self)
            return
        }
        let visible = outputCoordinator.backgroundVisualVisibility(workspace: outputSourceID) ?? isBackgroundVisualVisible
        isBackgroundVisualVisible = !visible
        outputCoordinator.setAudienceBackgroundVisibility(isBackgroundVisualVisible, for: self)
    }

    func moveSelection(_ delta: Int) {
        enqueueSelectionMove { index, count, _ in
            max(0, min(count - 1, index + delta))
        }
    }

    func setCurrentThumbnailColumnCount(_ columnCount: Int) {
        currentThumbnailColumnCount = max(1, columnCount)
    }

    func moveSelection(direction: ThumbnailGridNavigationDirection) {
        enqueueSelectionMove { index, count, columnCount in
            ThumbnailGridLayout.fixedColumnCount(columnCount).selectionTargetIndex(
                from: index,
                itemCount: count,
                direction: direction
            )
        }
    }

    private func enqueueSelectionMove(_ targetIndex: @escaping (Int, Int, Int) -> Int) {
        let revision = currentDocumentRevision
        let generation = navigationGeneration
        if pendingNavigationCount == 0 { navigationActionOrder = nil }
        pendingNavigationCount += 1
        if (isPresenting && areSlidesVisible) { navigationActionOrder = outputActionClock.next() }
        // SwiftUI can invoke onKeyPress during its update pass. Resolve each
        // queued move in order, after that pass, against the same Current document.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.navigationGeneration == generation else { return }
            self.pendingNavigationCount = max(0, self.pendingNavigationCount - 1)
            guard self.currentDocumentRevision == revision, !self.isEmpty else { return }
            if let order = self.navigationActionOrder, order != self.outputActionClock.current { return }
            let nextID: Slide.ID?
            if let currentID = self.currentSlideID, let index = self.slideIndex(for: currentID) {
                let nextIndex = targetIndex(index, self.slideCount, self.currentThumbnailColumnCount)
                nextID = self.slide(at: nextIndex)?.id
            } else {
                nextID = self.firstSlideID
            }
            if self.currentSlideID != nextID {
                if let nextID {
                    if self.pendingNavigationCount == 0 { self.navigationActionOrder = nil; self.selectCurrentSlide(nextID) }
                    else { self.currentSlideID = nextID }
                }
            } else if self.pendingNavigationCount == 0 { self.navigationActionOrder = nil }
        }
    }

    func seekVideo(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(videoDuration, 0))
        videoSeekTarget = clamped
        playbackProgress.seekVideo(to: clamped)
        videoSeekRevision += 1
        outputCoordinator.refreshMedia()
    }

    var videoCurrentTime: Double {
        playbackProgress.videoCurrentTime
    }

    var videoDuration: Double {
        playbackProgress.videoDuration
    }

    var backgroundAudioCurrentTime: Double {
        playbackProgress.backgroundAudioCurrentTime
    }

    var backgroundAudioDuration: Double {
        playbackProgress.backgroundAudioDuration
    }

    func updateVideoPlaybackProgress(currentTime: Double, duration: Double) {
        playbackProgress.updateVideo(currentTime: currentTime, duration: duration)
    }

    func resetVideoPlaybackProgress() {
        playbackProgress.resetVideo()
        videoSeekTarget = 0
        videoSeekRevision += 1
        outputCoordinator.refreshMedia()
    }

    func setBackgroundVisual(_ url: URL?) {
        backgroundVisualURL = url
        isBackgroundVisualVisible = (url != nil)
    }

    func setBackgroundAudio(url: URL?, autoplay: Bool) {
        guard outputCoordinator.profiles.document.workspaces.contains(where: { $0.id == outputSourceID }) else { return }
        if backgroundAudioURL == url {
            if autoplay {
                playBackgroundAudio()
            }
            return
        }
        backgroundAudioURL = url
        configureBackgroundAudioPlayer(for: url, autoplay: autoplay)
    }

    func playBackgroundAudio() {
        guard outputCoordinator.profiles.document.workspaces.contains(where: { $0.id == outputSourceID }) else { return }
        backgroundAudioHasStandaloneLocalRoute = outputCoordinator.canPlayStandaloneBackgroundAudio(workspace: outputSourceID)
        outputCoordinator.claimBackgroundAudio(self)
        backgroundAudioGeneration = UUID()
        configureBackgroundAudioEndObserver()
        configureBackgroundAudioTimeObserver()
        guard let player = backgroundAudioPlayer else {
            if let url = backgroundAudioURL {
                configureBackgroundAudioPlayer(for: url, autoplay: true)
            }
            return
        }
        outputCoordinator.refreshMedia()
        player.play()
        backgroundAudioPlaybackState = .playing
    }

    func pauseBackgroundAudio() {
        backgroundAudioGeneration = UUID()
        backgroundAudioPlayer?.pause()
        backgroundAudioPlaybackState = backgroundAudioURL == nil ? .stopped : .paused
        refreshBackgroundAudioProgress()
    }

    func stopBackgroundAudioPlayback() {
        backgroundAudioGeneration = UUID()
        backgroundAudioPlayer?.pause()
        backgroundAudioPlayer?.seek(to: .zero)
        playbackProgress.seekBackgroundAudio(to: 0)
        backgroundAudioPlaybackState = .stopped
    }

    func clearBackgroundAudio() {
        stopBackgroundAudioPlayback()
        removeBackgroundAudioTimeObserver()
        backgroundAudioPlayer = nil
        backgroundAudioHasStandaloneLocalRoute = false
        audioResourceScope?.stopAccessingSecurityScopedResource(); audioResourceScope = nil
        backgroundAudioURL = nil
        playbackProgress.resetBackgroundAudio()
        removeBackgroundAudioEndObserver()
    }

    func setBackgroundAudioLoop(_ loop: Bool) {
        backgroundAudioLoop = loop
    }

    func setBackgroundAudioVolume(_ volume: Double) {
        let clamped = min(max(volume, 0.0), 1.0)
        backgroundAudioVolume = clamped
        backgroundAudioGain.set(Float(clamped))
        updateBackgroundAudioLocalPlayback(enabled: outputCoordinator.localBackgroundAudioEnabled(workspace: outputSourceID))
        outputCoordinator.refreshMedia()
    }

    func updateBackgroundAudioLocalPlayback(enabled: Bool) {
        backgroundAudioPlayer?.volume = enabled ? Float(backgroundAudioVolume) : 0
    }

    func seekBackgroundAudio(to time: Double) {
        guard let player = backgroundAudioPlayer else { return }
        let clamped = min(max(time, 0), backgroundAudioDuration)
        playbackProgress.seekBackgroundAudio(to: clamped)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
    }

    func refreshBackgroundAudioProgress() {
        guard let player = backgroundAudioPlayer else {
            playbackProgress.resetBackgroundAudio()
            return
        }
        let current = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds ?? 0
        playbackProgress.updateBackgroundAudio(currentTime: current, duration: duration)
    }

    private func configureBackgroundAudioPlayer(for url: URL?, autoplay: Bool) {
        backgroundAudioGeneration = UUID()
        backgroundAudioPlayer?.pause()
        removeBackgroundAudioTimeObserver()
        backgroundAudioPlayer = nil
        backgroundAudioPlaybackState = .stopped
        playbackProgress.resetBackgroundAudio()
        removeBackgroundAudioEndObserver()

        audioResourceScope?.stopAccessingSecurityScopedResource(); audioResourceScope = nil
        guard let url else { return }
        if url.startAccessingSecurityScopedResource() { audioResourceScope = url }
        backgroundAudioHasStandaloneLocalRoute = autoplay && outputCoordinator.canPlayStandaloneBackgroundAudio(workspace: outputSourceID)
        if autoplay { outputCoordinator.claimBackgroundAudio(self) }

        let player = AVPlayer(url: url)
        backgroundAudioGain.set(Float(backgroundAudioVolume))
        player.volume = outputCoordinator.localBackgroundAudioEnabled(workspace: outputSourceID) ? Float(backgroundAudioVolume) : 0
        backgroundAudioPlayer = player
        configureBackgroundAudioEndObserver()
        configureBackgroundAudioTimeObserver()
        refreshBackgroundAudioProgress()
        outputCoordinator.refreshMedia()
        if autoplay {
            player.play()
            backgroundAudioPlaybackState = .playing
        }
    }

    private func configureBackgroundAudioEndObserver() {
        removeBackgroundAudioEndObserver()
        guard let item = backgroundAudioPlayer?.currentItem else { return }
        let generation = backgroundAudioGeneration
        backgroundAudioEndObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.backgroundAudioGeneration == generation, self.outputCoordinator.audioSession === self else { return }
                self.handleBackgroundAudioEnded()
            }
        }
    }
    private func handleBackgroundAudioEnded() {
        guard let player = backgroundAudioPlayer else { return }
        if backgroundAudioLoop {
            player.seek(to: .zero)
            playbackProgress.seekBackgroundAudio(to: 0)
            player.play()
            backgroundAudioPlaybackState = .playing
        } else {
            backgroundAudioPlaybackState = .stopped
            refreshBackgroundAudioProgress()
        }
    }

    private func removeBackgroundAudioEndObserver() {
        if let backgroundAudioEndObserver {
            NotificationCenter.default.removeObserver(backgroundAudioEndObserver)
            self.backgroundAudioEndObserver = nil
        }
    }

    private func configureBackgroundAudioTimeObserver() {
        removeBackgroundAudioTimeObserver()
        guard let backgroundAudioPlayer else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        backgroundAudioTimeObserver = backgroundAudioPlayer.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshBackgroundAudioProgress()
            }
        }
    }

    private func removeBackgroundAudioTimeObserver() {
        guard let backgroundAudioTimeObserver, let backgroundAudioPlayer else { return }
        backgroundAudioPlayer.removeTimeObserver(backgroundAudioTimeObserver)
        self.backgroundAudioTimeObserver = nil
    }

}

struct PresentationView: View {
    @EnvironmentObject var session: PresentationSession
    @AppStorage("presentationFontScale") private var scale: Double = 1
    @AppStorage("presentationLyricsLayout") private var layout: PresentationLyricsLayout = .stacked
    @AppStorage("presentationPaddingScale") private var padding: Double = 1
    @AppStorage("presentationTextAlignment") private var alignment: PresentationTextAlignment = .center
    @AppStorage("presentationVerticalPosition") private var position: PresentationVerticalPosition = .middle
    private var previewProfile: OutputProfile {
        var profile = OutputProfile.builtIns[0]
        profile.layout = layout.rawValue; profile.alignment = alignment.rawValue; profile.position = position.rawValue
        profile.padding = padding; profile.typography.size = 84 * scale
        return profile
    }
    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                Color.black.frame(width: size.width, height: size.height)
                if session.areSlidesVisible, let slide = session.currentSlide {
                    if OutputContentClassifier.mode(for: slide) == .media {
                        if let runtime = session.outputCoordinator.preparedMedia(workspace: session.outputSourceID) {
                            OutputMediaSlideView(slide: slide, session: session, runtime: runtime)
                        }
                    } else {
                        OutputTextView(content: OutputContentAdapter.text(for: slide), profile: previewProfile, size: size)
                    }
                }
            }.frame(width: size.width, height: size.height).clipped()
        }.ignoresSafeArea()
    }
}

struct PDFSlideView: NSViewRepresentable {
    let url: URL
    let pageIndex: Int
    let documentRevision: UInt64
    let documentCache: PDFDocumentCache

    func makeNSView(context: Context) -> PDFSlideNSView {
        let view = PDFSlideNSView(frame: .zero)
        update(view)
        return view
    }

    func updateNSView(_ nsView: PDFSlideNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: PDFSlideNSView) {
        view.display(url: url, pageIndex: pageIndex, revision: documentRevision, cache: documentCache)
    }
}

/// A page change reuses its accepted document. An explicit Current load changes
/// the revision, even when its URL and page-derived slide identity are unchanged.
final class PDFSlideNSView: PDFView {
    private struct Source: Equatable {
        let url: URL
        let revision: UInt64
    }
    private var displayedSource: Source?
    private weak var displayedCache: PDFDocumentCache?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        autoScales = true
        displayMode = .singlePage
        displayDirection = .vertical
        backgroundColor = .clear
        displaysPageBreaks = false
        pageBreakMargins = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        displaysAsBook = false
    }

    func display(url: URL, pageIndex: Int, revision: UInt64, cache: PDFDocumentCache) {
        let source = Source(url: url.standardizedFileURL, revision: revision)
        if displayedSource != source || displayedCache !== cache {
            document = cache.document(for: url)
            displayedSource = source
            displayedCache = cache
        }
        if let page = document?.page(at: pageIndex) { go(to: page) }
    }
}

/// Each prepared workspace retains at most three native documents. Reloading or
/// clearing its Current cannot invalidate another workspace's accepted PDF.
@MainActor
final class PDFDocumentCache {
    private let maxCachedDocuments = 3
    private var documents: [URL: PDFDocument] = [:]
    private var accessOrder: [URL] = []

    init() {}

    func document(for url: URL) -> PDFDocument? {
        let key = url.standardizedFileURL
        if let cached = documents[key] {
            touch(key)
            return cached
        }

        while documents.count >= maxCachedDocuments, let oldest = accessOrder.first {
            documents.removeValue(forKey: oldest)
            accessOrder.removeAll { $0 == oldest }
        }

        guard let document = PDFDocument(url: key) else { return nil }
        documents[key] = document
        touch(key)
        return document
    }

    func clear() {
        documents.removeAll()
        accessOrder.removeAll()
    }

    private func touch(_ url: URL) {
        accessOrder.removeAll { $0 == url }
        accessOrder.append(url)
    }
}

struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer?
    let isMuted: Bool
    let isFill: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = isFill ? .resizeAspectFill : .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
        nsView.player?.isMuted = isMuted
        nsView.videoGravity = isFill ? .resizeAspectFill : .resizeAspect
    }
}

final class PresentationWindow: NSWindow {
    weak var outputCoordinator: OutputCoordinator?
    var outputDestinationID: UUID?

    override var canBecomeKey: Bool { true }
    // Projection can receive slide shortcuts without replacing the workspace
    // as the app's main document window.
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: // Esc
            cancelOperation(nil)
        case 18 where event.modifierFlags.contains(.command): // Cmd+1
            requestStopProjection()
        case 19 where event.modifierFlags.contains(.command): // Cmd+2
            requestToggleSlidesVisibility()
        case 20 where event.modifierFlags.contains(.command): // Cmd+3
            requestClearBackgroundVisual()
        case 21 where event.modifierFlags.contains(.command): // Cmd+4
            requestClearBackgroundAudio()
        case 23 where event.modifierFlags.contains(.command): // Cmd+5
            requestClearAllLayers()
        case 123: // Left
            requestMoveSelection(direction: .previousItem)
        case 124: // Right
            requestMoveSelection(direction: .nextItem)
        case 126: // Up
            requestMoveSelection(direction: .previousRow)
        case 125: // Down
            requestMoveSelection(direction: .nextRow)
        case 116: // Page Up
            requestMoveSelection(-1)
        case 121: // Page Down
            requestMoveSelection(1)
        default:
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        requestHideSlides()
    }

    private var commandSession: PresentationSession? { outputCoordinator?.commandSession(for: self) }

    private func requestHideSlides() { commandSession?.hideSlides() }
    private func requestStopProjection() { commandSession?.stopPresentation() }
    private func requestToggleSlidesVisibility() { commandSession?.toggleSlidesVisibility() }
    private func requestClearBackgroundVisual() { if let session = commandSession { outputCoordinator?.clearBackgrounds(for: session) } }
    private func requestClearBackgroundAudio() { commandSession?.clearBackgroundAudio() }
    private func requestClearAllLayers() { requestHideSlides(); requestClearBackgroundVisual(); requestClearBackgroundAudio() }

    private func requestMoveSelection(_ delta: Int) {
        commandSession?.moveSelection(delta)
    }

    private func requestMoveSelection(direction: ThumbnailGridNavigationDirection) {
        commandSession?.moveSelection(direction: direction)
    }
}
