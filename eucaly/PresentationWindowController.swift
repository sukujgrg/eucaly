import SwiftUI
import AppKit
import AVKit
import AVFoundation
import Combine
import PDFKit
import WebKit

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

    enum OverlayMode: String, CaseIterable, Identifiable {
        case hidden = "Hidden"
        case clock = "Clock"
        case countdown = "Countdown"

        var id: String { rawValue }
    }

    struct OverlayState: Equatable {
        var mode: OverlayMode = .hidden
        var isClockVisible: Bool = false
        var isCountdownRunning: Bool = false
        var countdownEndDate: Date? = nil
    }

    @Published var slides: [Slide] = [] { didSet { scheduleOutputChange() } }
    @Published private(set) var pdfSlideSource: PDFSlideSource? { didSet { scheduleOutputChange() } }
    @Published var currentSlideID: Slide.ID? { didSet { scheduleOutputChange() } }
    @Published var isPresenting = false { didSet { scheduleOutputChange() } }
    @Published var videoMuted = false { didSet { outputCoordinator.refreshMedia() } }
    // Current and projection webpage mute state; Preview keeps a separate local mute state.
    @Published var webpageMuted = false
    @Published var videoPaused = false { didSet { outputCoordinator.refreshMedia() } }
    @Published var videoLoop = false { didSet { outputCoordinator.refreshMedia() } }
    @Published var videoFill = false { didSet { outputCoordinator.refreshMedia() } }
    @Published private(set) var videoSeekRevision = 0
    private(set) var videoSeekTarget: Double = 0
    let playbackProgress = PlaybackProgressStore()
    @Published private(set) var backgroundVisualURL: URL? = nil
    @Published var isBackgroundVisualVisible = true { didSet { outputCoordinator.setAudienceBackgroundVisibility(isBackgroundVisualVisible) } }
    @Published private(set) var backgroundAudioURL: URL? = nil
    @Published private(set) var backgroundAudioPlaybackState = BackgroundAudioPlaybackState.stopped
    @Published private(set) var backgroundAudioLoop = true
    @Published private(set) var backgroundAudioVolume: Double = 1.0
    @Published var areSlidesVisible = true { didSet { scheduleOutputChange() } }
    @Published private(set) var overlay = OverlayState()
    private var countdownToken = UUID()

    private var backgroundAudioGeneration = UUID()
    private var backgroundAudioPlayer: AVPlayer?
    private var backgroundAudioEndObserver: NSObjectProtocol?
    private var backgroundAudioTimeObserver: Any?

    // The app owns injected coordinators; a standalone session owns its test/runtime
    // coordinator. Prepared Current retention must not form an app/session cycle.
    private let standaloneOutputCoordinator: OutputCoordinator?
    private unowned let linkedOutputCoordinator: OutputCoordinator
    var outputCoordinator: OutputCoordinator { linkedOutputCoordinator }
    let projectionDisplays: ProjectionDisplayManager
    var activePresentationTarget: ProjectionMonitorTarget? { outputCoordinator.audienceTarget }
    @Published var projectionDisplayIssue: String?
    private var currentThumbnailColumnCount: Int = 1
    private var currentDocumentRevision: UInt64 = 0
    private var pendingNavigationCount = 0
    private var navigationActionOrder: UInt64?

    let outputSourceID = UUID()
    var onOutputEvent: ((PresentationOutputEvent) -> Void)?
    private var outputObservers: [UUID: (PresentationOutputEvent) -> Void] = [:]
    @discardableResult func observeOutput(_ action: @escaping (PresentationOutputEvent) -> Void) -> UUID {
        let id = UUID(); outputObservers[id] = action; return id
    }
    func removeOutputObserver(_ id: UUID) { outputObservers.removeValue(forKey: id) }
    func emitOutputEvent(_ event: PresentationOutputEvent) {
        onOutputEvent?(event)
        for observer in Array(outputObservers.values) { observer(event) }
    }
    func cancelPendingProjection() { outputProjectionRequested = false }

    func applyOutputState(running: Bool, visible: Bool) {
        if isPresenting != running { isPresenting = running }
        if areSlidesVisible != visible { areSlidesVisible = visible }
    }

    private var outputChangeScheduled = false
    private var outputProjectionRequested = false

    var canSendCurrentToAltView: Bool {
        isPresenting && areSlidesVisible && (!outputCoordinator.isRunning || outputCoordinator.localSession === self)
    }

    var outputSnapshot: PresentationOutputSnapshot {
        let identity = outputCoordinator.localSession === self ? outputCoordinator.audienceIdentity : (nil, nil)
        return PresentationOutputSnapshot(slide: currentSlide, isPresenting: isPresenting, slidesVisible: areSlidesVisible,
                                          projectionWindowID: identity.0,
                                          projectionWindowGeneration: identity.1)
    }

    private func scheduleOutputChange(explicit: Bool = false) {
        outputProjectionRequested = outputProjectionRequested || explicit
        guard !outputChangeScheduled else { return }
        outputChangeScheduled = true
        // Read the completed model transaction, never @Published's willSet
        // values or an intermediate selection while replacing Current.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.outputChangeScheduled = false
            let snapshot = self.outputSnapshot
            let ownsGroup = self.outputCoordinator.ownership.source == .local(self.outputSourceID) || !self.outputCoordinator.isRunning
            let project = self.outputProjectionRequested && snapshot.isPresenting && snapshot.slidesVisible && ownsGroup
            self.outputProjectionRequested = false
            self.outputCoordinator.passiveLocal(self)
            self.emitOutputEvent(project ? .project(self.outputSnapshot) : .changed(self.outputSnapshot))
        }
    }

    /// User activation is distinct from model refreshes and hidden navigation.
    func selectCurrentSlide(_ slideID: Slide.ID) {
        guard containsSlide(id: slideID) else { return }
        if currentSlideID != slideID { currentSlideID = slideID }
        requestCurrentProjection()
    }

    func requestCurrentProjection() {
        guard isPresenting, areSlidesVisible else { return }
        if outputCoordinator.isRunning { guard outputCoordinator.presentLocal(self) else { return } }
        scheduleOutputChange(explicit: true)
    }

    var isBackgroundAudioPlaying: Bool {
        backgroundAudioPlaybackState == .playing
    }

    override convenience init() {
        self.init(projectionDisplays: ProjectionDisplayManager())
    }

    init(projectionDisplays: ProjectionDisplayManager,
         sleepPrevention: ProjectionSleepPrevention = ProjectionSleepPrevention(),
         outputCoordinator: OutputCoordinator? = nil) {
        self.projectionDisplays = projectionDisplays
        if let outputCoordinator {
            standaloneOutputCoordinator = nil
            linkedOutputCoordinator = outputCoordinator
        } else {
            let coordinator = OutputCoordinator(profiles: OutputProfileStore(monitor: projectionDisplays.target), displays: projectionDisplays, sleepPrevention: sleepPrevention)
            standaloneOutputCoordinator = coordinator
            linkedOutputCoordinator = coordinator
        }
        super.init()
        self.outputCoordinator.attach(self)
    }

    deinit {
        if let backgroundAudioEndObserver { NotificationCenter.default.removeObserver(backgroundAudioEndObserver) }
        if let backgroundAudioTimeObserver, let backgroundAudioPlayer { backgroundAudioPlayer.removeTimeObserver(backgroundAudioTimeObserver) }
    }

    var overlayMode: OverlayMode { overlay.mode }
    var isClockVisible: Bool { overlay.isClockVisible }
    var isCountdownRunning: Bool { overlay.isCountdownRunning }
    var countdownEndDate: Date? { overlay.countdownEndDate }

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
        guard let url = backgroundVisualURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func setSlides(
        _ slides: [Slide],
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        currentDocumentRevision &+= 1
        let preservedSelection = preferredSelection ?? currentSlideID
        pdfSlideSource = nil
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
        syncPDFDocumentCache()
    }

    func setPDFSlideSource(
        _ source: PDFSlideSource,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        currentDocumentRevision &+= 1
        slides = []
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
        syncPDFDocumentCache()
    }

    func clearSlides() {
        outputProjectionRequested = false
        outputCoordinator.clear()
        currentDocumentRevision &+= 1
        slides = []
        pdfSlideSource = nil
        currentSlideID = nil
        resetVideoPlaybackProgress()
        syncPDFDocumentCache()
    }

    private func syncPDFDocumentCache() {
        var retainedURLs = Set<URL>()
        if let pdfSlideSource {
            retainedURLs.insert(pdfSlideSource.url)
        }
        for slide in slides {
            if let pdfURL = slide.pdfURL {
                retainedURLs.insert(pdfURL)
            }
        }
        PDFDocumentCache.shared.releaseDocuments(notIn: retainedURLs)
    }

    func stopPresentation() {
        outputProjectionRequested = false
        outputCoordinator.stop()
        isPresenting = false
        emitOutputEvent(.stopped)
    }

    func showSlides() {
        if !outputCoordinator.presentLocal(self) {
            // A synthetic session can exercise events without a physical window.
            // An actual running group must keep its current source after preflight fails.
            guard isPresenting, !outputCoordinator.isRunning else { return }
        }
        areSlidesVisible = true
        outputProjectionRequested = false
        emitOutputEvent(.show(outputSnapshot))
    }

    func hideSlides() {
        guard isPresenting else { return }
        outputProjectionRequested = false
        areSlidesVisible = false
        if outputCoordinator.isRunning { outputCoordinator.hide() }
    }

    func toggleBackgroundVisualVisibility() {
        guard backgroundVisualURL != nil else { return }
        if !isPresenting {
            guard outputCoordinator.presentLocal(self, show: false) else { return }
            isBackgroundVisualVisible = true
            return
        }
        isBackgroundVisualVisible.toggle()
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
        if pendingNavigationCount == 0 { navigationActionOrder = nil }
        pendingNavigationCount += 1
        if isPresenting && areSlidesVisible { navigationActionOrder = outputCoordinator.actionClock.next() }
        // SwiftUI can invoke onKeyPress during its update pass. Resolve each
        // queued move in order, after that pass, against the same Current document.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingNavigationCount = max(0, self.pendingNavigationCount - 1)
            guard self.currentDocumentRevision == revision, !self.isEmpty else { return }
            if let order = self.navigationActionOrder, order != self.outputCoordinator.actionClock.current { return }
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

    func startCountdown(minutes: Int) {
        let safeMinutes = max(1, minutes)
        let endDate = Date().addingTimeInterval(Double(safeMinutes) * 60.0)
        applyOverlay { state in
            state.mode = .countdown
            state.isClockVisible = false
            state.isCountdownRunning = true
            state.countdownEndDate = endDate
        }
        let token = UUID()
        countdownToken = token
        let duration = Double(safeMinutes) * 60.0
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self else { return }
            guard self.countdownToken == token else { return }
            self.stopCountdown()
        }
    }

    func stopCountdown() {
        countdownToken = UUID()
        applyOverlay { state in
            state.isCountdownRunning = false
            state.countdownEndDate = nil
        }
    }

    func setOverlayMode(_ mode: OverlayMode) {
        if mode != .countdown {
            countdownToken = UUID()
        }
        applyOverlay { state in
            state.mode = mode
            switch mode {
            case .hidden:
                state.isClockVisible = false
                state.isCountdownRunning = false
                state.countdownEndDate = nil
            case .countdown:
                state.isClockVisible = false
            case .clock:
                state.isCountdownRunning = false
                state.countdownEndDate = nil
                state.isClockVisible = true
            }
        }
    }

    func remainingCountdownSeconds(at date: Date = Date()) -> Int {
        guard isCountdownRunning, let end = countdownEndDate else { return 0 }
        let remaining = Int(ceil(end.timeIntervalSince(date)))
        return max(0, remaining)
    }

    func countdownDisplay(at date: Date = Date()) -> String {
        let totalSeconds = remainingCountdownSeconds(at: date)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var isTimeOverlayVisible: Bool {
        switch overlay.mode {
        case .hidden:
            return false
        case .countdown:
            return overlay.isCountdownRunning
        case .clock:
            return overlay.isClockVisible
        }
    }

    func clockDisplay(at date: Date = Date()) -> String {
        Self.clockFormatter.string(from: date)
    }

    func setBackgroundVisual(_ url: URL?) {
        backgroundVisualURL = url
        isBackgroundVisualVisible = (url != nil)
    }

    func setBackgroundAudio(url: URL?, autoplay: Bool) {
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
        backgroundAudioPlayer?.volume = Float(clamped)
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

    func overlayTintColor(remaining: Int) -> Color {
        if overlay.mode == .countdown && remaining <= 60 {
            return .orange
        }
        return AccentColorProvider.color
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private func applyOverlay(_ update: @escaping (inout OverlayState) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var next = self.overlay
            update(&next)
            if next != self.overlay {
                self.overlay = next
                self.outputCoordinator.refreshOverlay(self)
            }
        }
    }

    private func configureBackgroundAudioPlayer(for url: URL?, autoplay: Bool) {
        backgroundAudioGeneration = UUID()
        backgroundAudioPlayer?.pause()
        removeBackgroundAudioTimeObserver()
        backgroundAudioPlayer = nil
        backgroundAudioPlaybackState = .stopped
        playbackProgress.resetBackgroundAudio()
        removeBackgroundAudioEndObserver()

        guard let url else { return }
        if autoplay { outputCoordinator.claimBackgroundAudio(self) }

        let player = AVPlayer(url: url)
        player.volume = Float(backgroundAudioVolume)
        backgroundAudioPlayer = player
        configureBackgroundAudioEndObserver()
        configureBackgroundAudioTimeObserver()
        refreshBackgroundAudioProgress()
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
                    if AltViewPresentationAdapter.mode(for: slide) == .media {
                        OutputMediaSlideView(slide: slide, session: session, runtime: session.outputCoordinator.media)
                    } else {
                        OutputTextView(content: OutputContentAdapter.text(for: slide), profile: previewProfile, size: size)
                    }
                }
                if session.isTimeOverlayVisible { TimeOverlay().environmentObject(session).padding(26).frame(width: size.width, height: size.height) }
            }.frame(width: size.width, height: size.height).clipped()
        }.ignoresSafeArea()
    }
}

struct TimeOverlay: View {
    @EnvironmentObject var session: PresentationSession
    @AppStorage("overlayScale") private var overlayScale: Double = 1.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0)) { context in
            let remaining = session.remainingCountdownSeconds(at: context.date)
            overlayView(remaining: remaining, date: context.date)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 28)
                .padding(.top, 28)
        }
    }

    private func overlayView(remaining: Int, date: Date) -> some View {
        let mode = session.overlayMode
        let timeText = mode == .clock
            ? session.clockDisplay(at: date)
            : session.countdownDisplay(at: date)
        return Text(timeText)
            .font(.system(size: 36 * overlayScale, weight: .bold))
            .monospacedDigit()
            .foregroundStyle(foregroundColor(remaining: remaining))
            .shadow(color: .black.opacity(0.45), radius: 4, x: 0, y: 2)
            .accessibilityLabel(mode == .clock ? "Clock" : "Countdown")
    }

    private func foregroundColor(remaining: Int) -> Color {
        if session.overlayMode == .countdown && remaining <= 60 {
            return .orange
        }
        return .white
    }
}

struct PDFSlideView: NSViewRepresentable {
    let url: URL
    let pageIndex: Int

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displayDirection = .vertical
        view.backgroundColor = .clear
        view.displaysPageBreaks = false
        view.pageBreakMargins = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        view.displaysAsBook = false
        if let document = PDFDocumentCache.shared.document(for: url),
           let page = document.page(at: pageIndex) {
            view.document = document
            view.go(to: page)
        }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocumentCache.shared.document(for: url)
        }
        nsView.backgroundColor = .clear
        nsView.displaysPageBreaks = false
        nsView.pageBreakMargins = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        nsView.displaysAsBook = false
        if let document = nsView.document, let page = document.page(at: pageIndex) {
            nsView.go(to: page)
        }
    }
}

@MainActor
final class PDFDocumentCache {
    static let shared = PDFDocumentCache()

    private let maxCachedDocuments = 3
    private var documents: [URL: PDFDocument] = [:]
    private var accessOrder: [URL] = []

    private init() {}

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

    func releaseDocument(for url: URL) {
        let key = url.standardizedFileURL
        documents.removeValue(forKey: key)
        accessOrder.removeAll { $0 == key }
    }

    func releaseDocuments(notIn retainedURLs: Set<URL>) {
        let retained = Set(retainedURLs.map(\.standardizedFileURL))
        for url in Array(documents.keys) where !retained.contains(url) {
            documents.removeValue(forKey: url)
            accessOrder.removeAll { $0 == url }
        }
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

struct WebpageSlideView: View {
    let url: URL
    let navigationRevision: Int
    let isMuted: Bool

    var body: some View {
        WebpageViewRepresentable(
            url: url,
            isMuted: isMuted
        )
            .id(WebpageSlideCatalog.viewIdentity(url: url, navigationRevision: navigationRevision))
            .background(Color.white)
    }
}

private let webpageMuteBootstrapScript = """
(function() {
  window.__eucalyAudioContexts = window.__eucalyAudioContexts || [];

  const mediaState = new WeakMap();

  const applyMuteToMediaElement = function(element, muted) {
    if (!mediaState.has(element)) {
      mediaState.set(element, {
        volume: typeof element.volume === 'number' ? element.volume : 1
      });
    }

    const state = mediaState.get(element);

    if (muted && typeof element.volume === 'number') {
      state.volume = element.volume;
    }

    element.defaultMuted = muted;
    element.muted = muted;

    if (typeof element.volume === 'number') {
      element.volume = muted ? 0 : state.volume;
    }
  };

  const applyMuteToMediaTree = function(root, muted) {
    if (!root || !root.querySelectorAll) {
      return;
    }

    root.querySelectorAll('audio,video').forEach(function(element) {
      applyMuteToMediaElement(element, muted);
    });
  };

  const wrapAudioContextConstructor = function(name) {
    const Original = window[name];
    if (!Original || Original.__eucalyWrapped) {
      return;
    }

    const Wrapped = function(...args) {
      const context = new Original(...args);
      window.__eucalyAudioContexts.push(context);

      if (window.__eucalyMuted) {
        try {
          context.suspend();
        } catch (error) {}
      }

      return context;
    };

    Wrapped.prototype = Original.prototype;
    Object.setPrototypeOf(Wrapped, Original);
    Wrapped.__eucalyWrapped = true;
    window[name] = Wrapped;
  };

  wrapAudioContextConstructor('AudioContext');
  wrapAudioContextConstructor('webkitAudioContext');

  if (!window.__eucalyMediaPlayPatched && window.HTMLMediaElement) {
    const originalPlay = window.HTMLMediaElement.prototype.play;

    window.HTMLMediaElement.prototype.play = function(...args) {
      applyMuteToMediaElement(this, !!window.__eucalyMuted);
      return originalPlay.apply(this, args);
    };

    window.__eucalyMediaPlayPatched = true;
  }

  window.__eucalyApplyMute = function(muted) {
    window.__eucalyMuted = muted;
    applyMuteToMediaTree(document, muted);
    window.__eucalyAudioContexts.forEach(function(context) {
      try {
        if (muted) {
          context.suspend();
        } else {
          context.resume();
        }
      } catch (error) {}
    });

    if (!window.__eucalyMuteObserver) {
      window.__eucalyMuteObserver = new MutationObserver(function() {
        applyMuteToMediaTree(document, !!window.__eucalyMuted);
      });

      const target = document.documentElement || document.body;
      if (target) {
        window.__eucalyMuteObserver.observe(target, {
          childList: true,
          subtree: true
        });
      }
    }
  };
})();
"""

private let webpageNavigationBridgeScript = """
(function() {
  if (window.__eucalyNavigationBridgeInstalled) {
    return;
  }
  window.__eucalyNavigationBridgeInstalled = true;

  const postNavigation = function() {
    try {
      window.webkit.messageHandlers.eucalyNavigation.postMessage(window.location.href);
    } catch (_) {
    }
  };

  const schedulePostNavigation = function() {
    setTimeout(postNavigation, 0);
  };

  const wrapHistoryMethod = function(name) {
    const original = window.history && window.history[name];
    if (typeof original !== 'function') {
      return;
    }

    window.history[name] = function() {
      const result = original.apply(this, arguments);
      schedulePostNavigation();
      return result;
    };
  };

  wrapHistoryMethod('pushState');
  wrapHistoryMethod('replaceState');
  window.addEventListener('popstate', schedulePostNavigation);
  window.addEventListener('hashchange', schedulePostNavigation);
})();
"""

final class WebpageContainerNSView: NSView {
    let webView: WKWebView

    private let overlayView = WebpageOverlayView()

    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        webView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(webView)
        addSubview(overlayView)

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor),
            webView.topAnchor.constraint(equalTo: topAnchor),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showLoading(for url: URL?) {
        overlayView.showLoading(for: url)
    }

    func showFailure(for url: URL, message: String, retryTarget: AnyObject, action: Selector) {
        overlayView.showFailure(
            for: url,
            message: message,
            retryTarget: retryTarget,
            action: action
        )
    }

    func hideStatusOverlay() {
        overlayView.isHidden = true
    }
}

final class WebpageOverlayView: NSVisualEffectView {
    private let statusIconView = NSImageView()

    private let statusSpinner = NSProgressIndicator()

    private let titleField = NSTextField(labelWithString: "")

    private let subtitleField = NSTextField(wrappingLabelWithString: "")

    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true

        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        statusIconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .medium)
        statusIconView.contentTintColor = .secondaryLabelColor

        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusSpinner.style = .spinning
        statusSpinner.controlSize = .regular
        statusSpinner.isDisplayedWhenStopped = false

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .preferredFont(forTextStyle: .title3)
        titleField.alignment = .center
        titleField.textColor = .labelColor

        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.font = .preferredFont(forTextStyle: .body)
        subtitleField.alignment = .center
        subtitleField.lineBreakMode = .byWordWrapping
        subtitleField.maximumNumberOfLines = 4
        subtitleField.textColor = .secondaryLabelColor

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .rounded
        retryButton.controlSize = .large
        retryButton.isHidden = true

        let stackView = NSStackView(views: [
            statusIconView,
            statusSpinner,
            titleField,
            subtitleField,
            retryButton
        ])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 12

        addSubview(stackView)

        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor),
            stackView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 28),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -28),
            stackView.widthAnchor.constraint(lessThanOrEqualToConstant: 520)
        ])

        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func showLoading(for url: URL?) {
        let host = url?.host(percentEncoded: false) ?? url?.absoluteString ?? ""

        isHidden = false
        retryButton.isHidden = true
        retryButton.target = nil
        retryButton.action = nil

        statusIconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        statusIconView.isHidden = false
        statusSpinner.startAnimation(nil)

        titleField.stringValue = "Loading webpage"
        subtitleField.stringValue = host
    }

    func showFailure(for url: URL, message: String, retryTarget: AnyObject, action: Selector) {
        let host = url.host(percentEncoded: false) ?? url.absoluteString

        isHidden = false
        statusSpinner.stopAnimation(nil)
        retryButton.isHidden = false
        retryButton.target = retryTarget
        retryButton.action = action

        statusIconView.image = NSImage(systemSymbolName: "wifi.exclamationmark", accessibilityDescription: nil)
        statusIconView.isHidden = false

        titleField.stringValue = "Unable to load webpage"
        subtitleField.stringValue = "\(host)\n\(message)"
    }
}

struct WebpageViewRepresentable: NSViewRepresentable {
    private static let navigationMessageName = "eucalyNavigation"

    let url: URL
    var isMuted: Bool = false
    var onURLChange: ((_ newURL: URL, _ previousURL: URL) -> Void)? = nil
    var onTitleChange: ((String, URL) -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onURLChange: onURLChange, onTitleChange: onTitleChange)
    }

    func makeNSView(context: Context) -> WebpageContainerNSView {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.websiteDataStore = .default()
        userContentController.addUserScript(
            WKUserScript(
                source: webpageMuteBootstrapScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        userContentController.addUserScript(
            WKUserScript(
                source: webpageNavigationBridgeScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
        )
        userContentController.add(context.coordinator, name: Self.navigationMessageName)
        configuration.userContentController = userContentController
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false
        webView.underPageBackgroundColor = .windowBackgroundColor
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        let containerView = WebpageContainerNSView(webView: webView)
        context.coordinator.setMute(isMuted, in: containerView)
        context.coordinator.load(url: url, in: containerView)
        return containerView
    }

    func updateNSView(_ nsView: WebpageContainerNSView, context: Context) {
        context.coordinator.updateCallbacks(onURLChange: onURLChange, onTitleChange: onTitleChange)
        context.coordinator.setMute(isMuted, in: nsView)
        context.coordinator.load(url: url, in: nsView)
    }

    static func dismantleNSView(_ nsView: WebpageContainerNSView, coordinator: Coordinator) {
        coordinator.teardown(nsView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        private var requestedURL: URL?
        private var lastReportedURL: URL?
        private var isShowingFailure = false
        private var isMuted = false
        private var onURLChange: ((_ newURL: URL, _ previousURL: URL) -> Void)?
        private var onTitleChange: ((String, URL) -> Void)?
        private var urlObservation: NSKeyValueObservation?
        private var titleObservation: NSKeyValueObservation?
        private weak var currentContainerView: WebpageContainerNSView?

        init(
            onURLChange: ((_ newURL: URL, _ previousURL: URL) -> Void)? = nil,
            onTitleChange: ((String, URL) -> Void)? = nil
        ) {
            self.onURLChange = onURLChange
            self.onTitleChange = onTitleChange
        }

        func updateCallbacks(
            onURLChange: ((_ newURL: URL, _ previousURL: URL) -> Void)?,
            onTitleChange: ((String, URL) -> Void)?
        ) {
            self.onURLChange = onURLChange
            self.onTitleChange = onTitleChange
        }

        func load(url: URL, in containerView: WebpageContainerNSView) {
            currentContainerView = containerView
            attachObservers(to: containerView.webView)
            let webView = containerView.webView

            if requestedURL == url && !isShowingFailure {
                containerView.hideStatusOverlay()
                return
            }

            if !isShowingFailure,
               !webView.isLoading,
               let settledURL = webView.url,
               WebpageURLMatcher.isSupported(settledURL),
               WebpageURLMatcher.representSamePage(settledURL, url) {
                requestedURL = url
                if !WebpageURLMatcher.representSamePage(lastReportedURL, settledURL) {
                    reportSettledURL(from: webView)
                } else {
                    containerView.hideStatusOverlay()
                }
                return
            }

            containerView.showLoading(for: url)
            requestedURL = url
            lastReportedURL = nil
            isShowingFailure = false
            webView.load(URLRequest(url: url))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isShowingFailure = false
            currentContainerView?.hideStatusOverlay()
            applyMute(in: webView)
            reportSettledURL(from: webView)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !shouldIgnoreFailure(error) else { return }
            showFailure(error, in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            guard !shouldIgnoreFailure(error) else { return }
            showFailure(error, in: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let requestedURL, let currentContainerView else { return }
            isShowingFailure = false
            lastReportedURL = nil
            currentContainerView.showLoading(for: requestedURL)
            webView.load(URLRequest(url: requestedURL))
        }

        func webView(
            _ webView: WKWebView,
            runOpenPanelWith parameters: WKOpenPanelParameters,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping @MainActor ([URL]?) -> Void
        ) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canCreateDirectories = false
            panel.resolvesAliases = true

            if let window = webView.window {
                panel.beginSheetModal(for: window) { response in
                    completionHandler(response == .OK ? panel.urls : nil)
                }
            } else {
                let response = panel.runModal()
                completionHandler(response == .OK ? panel.urls : nil)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == WebpageViewRepresentable.navigationMessageName,
                  let rawURL = message.body as? String,
                  let url = URL(string: rawURL),
                  WebpageURLMatcher.isSupported(url),
                  !WebpageURLMatcher.representSamePage(lastReportedURL, url) else {
                return
            }

            let previousURL = lastReportedURL ?? requestedURL ?? url
            requestedURL = url
            lastReportedURL = url
            onURLChange?(url, previousURL)
        }

        func teardown(_ containerView: WebpageContainerNSView) {
            requestedURL = nil
            lastReportedURL = nil
            isShowingFailure = false
            isMuted = false
            currentContainerView = nil
            urlObservation?.invalidate()
            titleObservation?.invalidate()
            urlObservation = nil
            titleObservation = nil
            containerView.webView.stopLoading()
            containerView.webView.navigationDelegate = nil
            containerView.webView.uiDelegate = nil
            containerView.webView.configuration.userContentController.removeScriptMessageHandler(
                forName: WebpageViewRepresentable.navigationMessageName
            )
            containerView.webView.load(URLRequest(url: URL(string: "about:blank")!))
        }

        func setMute(_ isMuted: Bool, in containerView: WebpageContainerNSView) {
            self.isMuted = isMuted
            applyMute(in: containerView.webView)
        }

        private func attachObservers(to webView: WKWebView) {
            guard urlObservation == nil, titleObservation == nil else { return }

            urlObservation = webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
                guard let self, let currentURL = webView.url, WebpageURLMatcher.isSupported(currentURL) else { return }
                guard !webView.isLoading else { return }
                self.reportSettledURL(from: webView)
            }

            titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                guard let self,
                      let currentURL = webView.url,
                      WebpageURLMatcher.isSupported(currentURL),
                      let title = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !title.isEmpty else { return }
                self.onTitleChange?(title, currentURL)
            }
        }

        private func reportSettledURL(from webView: WKWebView) {
            guard let currentURL = webView.url, WebpageURLMatcher.isSupported(currentURL) else { return }
            guard !WebpageURLMatcher.representSamePage(lastReportedURL, currentURL) else { return }
            let previousURL = lastReportedURL ?? requestedURL ?? currentURL
            requestedURL = currentURL
            lastReportedURL = currentURL
            onURLChange?(currentURL, previousURL)
        }

        private func applyMute(in webView: WKWebView) {
            webView.evaluateJavaScript(
                "window.__eucalyApplyMute && window.__eucalyApplyMute(\(isMuted ? "true" : "false"));"
            )
        }

        @objc
        private func retryRequested() {
            guard let requestedURL, let currentContainerView else { return }
            load(url: requestedURL, in: currentContainerView)
        }

        private func shouldIgnoreFailure(_ error: Error) -> Bool {
            let nsError = error as NSError
            return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
        }

        private func showFailure(_ error: Error, in webView: WKWebView) {
            guard let requestedURL else { return }
            isShowingFailure = true
            let message = (error as NSError).localizedDescription

            currentContainerView?.showFailure(
                for: requestedURL,
                message: message,
                retryTarget: self,
                action: #selector(retryRequested)
            )
            webView.stopLoading()
        }
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

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

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

    private var commandSession: PresentationSession? { outputCoordinator?.preferredLocalSession ?? outputCoordinator?.localSession }

    private func requestHideSlides() { outputCoordinator?.hide() }
    private func requestStopProjection() { outputCoordinator?.stop() }
    private func requestToggleSlidesVisibility() { outputCoordinator?.toggleSlides() }
    private func requestClearBackgroundVisual() { outputCoordinator?.clearBackgrounds() }
    private func requestClearBackgroundAudio() { outputCoordinator?.clearAudio() }
    private func requestClearAllLayers() { outputCoordinator?.clearAllLayers() }

    private func requestMoveSelection(_ delta: Int) {
        commandSession?.moveSelection(delta)
    }

    private func requestMoveSelection(direction: ThumbnailGridNavigationDirection) {
        commandSession?.moveSelection(direction: direction)
    }
}
