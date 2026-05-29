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
        videoDuration = normalizedDuration
        videoCurrentTime = min(normalizedTime, max(normalizedDuration, normalizedTime))
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
final class PresentationSession: NSObject, ObservableObject, NSWindowDelegate {
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

    @Published var slides: [Slide] = []
    @Published private(set) var pdfSlideSource: PDFSlideSource?
    @Published var currentSlideID: Slide.ID?
    @Published var isPresenting = false
    @Published var videoMuted = false
    // Current and projection webpage mute state; Preview keeps a separate local mute state.
    @Published var webpageMuted = false
    @Published var videoPaused = false
    @Published var videoLoop = false
    @Published var videoFill = false
    @Published private(set) var videoSeekRevision = 0
    private(set) var videoSeekTarget: Double = 0
    let playbackProgress = PlaybackProgressStore()
    @Published private(set) var backgroundVisualURL: URL? = nil
    @Published var isBackgroundVisualVisible = true
    @Published private(set) var backgroundAudioURL: URL? = nil
    @Published private(set) var isBackgroundAudioPlaying = false
    @Published private(set) var backgroundAudioLoop = true
    @Published private(set) var backgroundAudioVolume: Double = 1.0
    @Published var areSlidesVisible = true
    @Published private(set) var overlay = OverlayState()
    private var countdownToken = UUID()

    private var backgroundAudioPlayer: AVPlayer?
    private var backgroundAudioEndObserver: NSObjectProtocol?
    private var backgroundAudioTimeObserver: Any?

    private var window: NSWindow?
    private var preferredPresentationScreenID: CGDirectDisplayID?
    private var screenParametersObserver: NSObjectProtocol?
    private var screenRepositionWorkItem: DispatchWorkItem?
    private var currentThumbnailColumnCount: Int = 1

    override init() {
        super.init()
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.schedulePresentationWindowReposition()
            }
        }
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        if let backgroundAudioEndObserver {
            NotificationCenter.default.removeObserver(backgroundAudioEndObserver)
        }
        if let backgroundAudioTimeObserver, let backgroundAudioPlayer {
            backgroundAudioPlayer.removeTimeObserver(backgroundAudioTimeObserver)
        }
        screenRepositionWorkItem?.cancel()
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

    func setPreferredPresentationScreen(_ screen: NSScreen?) {
        preferredPresentationScreenID = screen?.displayID
        schedulePresentationWindowReposition()
    }

    func clearSlides() {
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

    func startPresentation(preferredScreen: NSScreen?, slidesVisible: Bool = true) {
        guard window == nil else { return }
        let screen = preferredScreen ?? NSScreen.main
        preferredPresentationScreenID = screen?.displayID
        let frame = screen?.frame ?? .zero

        let view = PresentationView()
            .environmentObject(self)

        let hostingView = NSHostingView(rootView: view)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let presentationWindow = PresentationWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        presentationWindow.isReleasedWhenClosed = false
        presentationWindow.level = .screenSaver
        presentationWindow.backgroundColor = .black
        presentationWindow.isOpaque = true
        presentationWindow.hasShadow = false
        presentationWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        presentationWindow.delegate = self
        presentationWindow.session = self
        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        presentationWindow.contentView = container
        presentationWindow.makeKeyAndOrderFront(nil)
        presentationWindow.makeFirstResponder(presentationWindow)

        if frame != .zero {
            presentationWindow.setFrame(frame, display: true)
        }

        window = presentationWindow
        isPresenting = true
        areSlidesVisible = slidesVisible
    }

    func stopPresentation() {
        guard let window else {
            teardownPresentationState()
            return
        }
        window.orderOut(nil)
        window.close()
    }

    func showSlides(preferredScreen: NSScreen?) {
        if !isPresenting {
            startPresentation(preferredScreen: preferredScreen)
        }
        areSlidesVisible = true
    }

    func hideSlides() {
        guard isPresenting else { return }
        areSlidesVisible = false
    }

    func toggleBackgroundVisualVisibility(preferredScreen: NSScreen?) {
        guard backgroundVisualURL != nil else { return }
        if !isPresenting {
            startPresentation(preferredScreen: preferredScreen, slidesVisible: false)
            isBackgroundVisualVisible = true
            return
        }
        isBackgroundVisualVisible.toggle()
    }

    func moveSelection(_ delta: Int) {
        // Defer to avoid publishing changes during view updates.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard let currentID = self.currentSlideID,
                  let index = self.slideIndex(for: currentID) else {
                self.currentSlideID = self.firstSlideID
                return
            }
            let nextIndex = max(0, min(self.slideCount - 1, index + delta))
            self.currentSlideID = self.slide(at: nextIndex)?.id
        }
    }

    func setCurrentThumbnailColumnCount(_ columnCount: Int) {
        currentThumbnailColumnCount = max(1, columnCount)
    }

    func moveSelection(direction: ThumbnailGridNavigationDirection) {
        guard slideCount > 0 else { return }
        guard let selectedSlideID = currentSlideID,
              let currentIndex = slideIndex(for: selectedSlideID) else {
            currentSlideID = firstSlideID
            return
        }

        let layout = ThumbnailGridLayout.fixedColumnCount(currentThumbnailColumnCount)
        let targetIndex = layout.selectionTargetIndex(
            from: currentIndex,
            itemCount: slideCount,
            direction: direction
        )
        currentSlideID = slide(at: targetIndex)?.id
    }

    func seekVideo(to seconds: Double) {
        let clamped = min(max(seconds, 0), max(videoDuration, 0))
        videoSeekTarget = clamped
        playbackProgress.seekVideo(to: clamped)
        videoSeekRevision += 1
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
    }

    private func teardownPresentationState() {
        screenRepositionWorkItem?.cancel()
        screenRepositionWorkItem = nil
        window = nil
        isPresenting = false
        stopWindowCapturesForShutdown()
    }

    private func schedulePresentationWindowReposition() {
        guard isPresenting else { return }
        screenRepositionWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.repositionPresentationWindowIfNeeded()
        }
        screenRepositionWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: workItem)
    }

    private func repositionPresentationWindowIfNeeded() {
        guard let window else { return }
        guard let targetScreen = resolvePreferredPresentationScreen() else { return }
        let targetFrame = targetScreen.frame
        guard targetFrame != .zero else { return }
        guard window.frame != targetFrame else { return }
        window.setFrame(targetFrame, display: true)
    }

    private func resolvePreferredPresentationScreen() -> NSScreen? {
        let requestedDisplayID = preferredPresentationScreenID
        if let exactMatch = ProjectionScreenResolver.exactScreen(displayID: requestedDisplayID) {
            return exactMatch
        }

        let fallbackScreen = ProjectionScreenResolver.resolve(displayID: nil)
        let fallbackDisplayID = fallbackScreen?.displayID
        preferredPresentationScreenID = fallbackDisplayID

        if let requestedDisplayID, requestedDisplayID != fallbackDisplayID {
            NotificationCenter.default.post(name: .projectionScreenFellBackToAuto, object: nil)
        }

        return fallbackScreen
    }

    private func stopWindowCapturesForShutdown() {
        Task { @MainActor in
            await ScreenCaptureManager.shared.stopAllCaptures()
        }
    }

    func windowWillClose(_ notification: Notification) {
        deferTeardownPresentationState()
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
        guard let player = backgroundAudioPlayer else {
            if let url = backgroundAudioURL {
                configureBackgroundAudioPlayer(for: url, autoplay: true)
            }
            return
        }
        player.play()
        isBackgroundAudioPlaying = true
    }

    func pauseBackgroundAudio() {
        backgroundAudioPlayer?.pause()
        isBackgroundAudioPlaying = false
        refreshBackgroundAudioProgress()
    }

    func stopBackgroundAudioPlayback() {
        backgroundAudioPlayer?.pause()
        backgroundAudioPlayer?.seek(to: .zero)
        playbackProgress.seekBackgroundAudio(to: 0)
        isBackgroundAudioPlaying = false
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
            }
        }
    }

    private func deferTeardownPresentationState() {
        DispatchQueue.main.async { [weak self] in
            self?.teardownPresentationState()
        }
    }

    private func configureBackgroundAudioPlayer(for url: URL?, autoplay: Bool) {
        backgroundAudioPlayer?.pause()
        removeBackgroundAudioTimeObserver()
        backgroundAudioPlayer = nil
        isBackgroundAudioPlaying = false
        playbackProgress.resetBackgroundAudio()
        removeBackgroundAudioEndObserver()

        guard let url else { return }

        let player = AVPlayer(url: url)
        player.volume = Float(backgroundAudioVolume)
        backgroundAudioPlayer = player
        if let item = player.currentItem {
            backgroundAudioEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleBackgroundAudioEnded()
                }
            }
        }
        configureBackgroundAudioTimeObserver()
        refreshBackgroundAudioProgress()
        if autoplay {
            player.play()
            isBackgroundAudioPlaying = true
        }
    }

    private func handleBackgroundAudioEnded() {
        guard let player = backgroundAudioPlayer else { return }
        if backgroundAudioLoop {
            player.seek(to: .zero)
            playbackProgress.seekBackgroundAudio(to: 0)
            player.play()
            isBackgroundAudioPlaying = true
        } else {
            isBackgroundAudioPlaying = false
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
    @AppStorage("presentationFontScale") private var presentationFontScale: Double = 1.0
    @AppStorage("presentationTextAlignment") private var presentationTextAlignment: PresentationTextAlignment = .center
    @AppStorage("presentationVerticalPosition") private var presentationVerticalPosition: PresentationVerticalPosition = .middle

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let horizontalMargin = max(40, size.width * 0.1)
            let maxWidth = max(0, size.width - horizontalMargin * 2)

            ZStack {
                Color.black
                    .frame(width: size.width, height: size.height)

                backgroundLayer
                    .frame(width: size.width, height: size.height)

                slidesLayer(in: size, maxWidth: maxWidth)
                    .frame(width: size.width, height: size.height)

                overlayLayer
                    .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if let backgroundURL = session.backgroundVisualURL,
           session.hasAvailableBackgroundVisual,
           session.isBackgroundVisualVisible {
            let isVisible = shouldShowBackground(for: session.currentSlide)
            BackgroundVisualView(url: backgroundURL, isVisible: isVisible)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(Color.black.opacity(0.35))
                .opacity(isVisible ? 1.0 : 0.0)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func slidesLayer(in size: CGSize, maxWidth: CGFloat) -> some View {
        ZStack {
            let currentSlide = session.currentSlide
            // Show black background only when a non-lyrics slide is actively shown.
            // When there is no selected slide, keep projection visually equivalent to "slides hidden".
            let isLyricsVisible = session.areSlidesVisible && (currentSlide.map(isLyricsSlide) ?? false)
            let shouldShowBlackBg = session.areSlidesVisible && currentSlide != nil && !isLyricsVisible
            if shouldShowBlackBg {
                Color.black
            }
            VStack(spacing: 28) {
                if session.areSlidesVisible, let slide = currentSlide {
                    Group {
                        if let windowID = slide.captureWindowID {
                            WindowCaptureSlideView(windowID: windowID)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let videoURL = slide.videoURL {
                            VideoSlideView(
                                url: videoURL,
                                isMuted: $session.videoMuted,
                                isPaused: $session.videoPaused,
                                isLooping: $session.videoLoop,
                                isFill: $session.videoFill
                            )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let pdfURL = slide.pdfURL, let pageIndex = slide.pdfPageIndex {
                            PDFSlideView(url: pdfURL, pageIndex: pageIndex)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let webpageURL = slide.webpageURL {
                            WebpageSlideView(
                                url: webpageURL,
                                navigationRevision: slide.webpageNavigationRevision,
                                isMuted: session.webpageMuted
                            )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else if let imageURL = slide.imageURL {
                            ImageSlideView(url: imageURL)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            VStack(spacing: 28) {
                                ForEach(slide.lines) { line in
                                    VStack(alignment: presentationTextAlignment.horizontalAlignment, spacing: 10) {
                                        Text(line.text)
                                            .font(dynamicFont(for: line, in: size, maxWidth: maxWidth))
                                            .foregroundStyle(.white)
                                            .multilineTextAlignment(presentationTextAlignment.textAlignment)
                                            .frame(maxWidth: maxWidth, alignment: presentationTextAlignment.frameAlignment)
                                            .lineLimit(nil)
                                            .minimumScaleFactor(0.4)
                                            .allowsTightening(true)
                                    }
                                }
                            }
                            .frame(maxWidth: maxWidth, alignment: presentationTextAlignment.frameAlignment)
                            .padding(.vertical, max(32, size.height * 0.08))
                            .frame(
                                maxWidth: .infinity,
                                maxHeight: .infinity,
                                alignment: presentationVerticalPosition.frameAlignment
                            )
                        }
                    }
                    .id(slide.id)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var overlayLayer: some View {
        if session.isTimeOverlayVisible {
            TimeOverlay()
                .environmentObject(session)
                .padding(26)
        }
    }

    private func isLyricsSlide(_ slide: Slide) -> Bool {
        slide.videoURL == nil
            && slide.pdfURL == nil
            && slide.imageURL == nil
            && slide.webpageURL == nil
            && slide.captureWindowID == nil
    }

    private func shouldShowBackground(for slide: Slide?) -> Bool {
        if !session.isBackgroundVisualVisible { return false }
        if !session.areSlidesVisible { return true }
        guard let slide else { return true }
        return isLyricsSlide(slide)
    }

    private func lineFont(for line: SlideLine) -> Font {
        let baseSize: CGFloat = 52
        if line.languageTag.caseInsensitiveCompare("Meaning") == .orderedSame {
            return .system(size: baseSize * 0.5, weight: .regular).italic()
        }
        return .system(size: baseSize, weight: .bold)
    }

    private func dynamicFont(for line: SlideLine, in size: CGSize, maxWidth: CGFloat) -> Font {
        let isMeaning = line.languageTag.caseInsensitiveCompare("Meaning") == .orderedSame
        let lineCount = max(1, session.currentSlide?.lines.count ?? 1)
        let verticalPadding: CGFloat = 120
        let availableHeight = max(80, (size.height - verticalPadding) / CGFloat(lineCount))

        let maxSize: CGFloat = min(84, availableHeight * 0.9) * presentationFontScale
        let minSize: CGFloat = 16 * presentationFontScale
        let baseSize = fitFontSize(
            text: line.text,
            maxWidth: maxWidth,
            maxHeight: availableHeight,
            maxSize: maxSize,
            minSize: minSize,
            weight: isMeaning ? .regular : .bold,
            italic: isMeaning
        )

        let finalSize = isMeaning ? max(minSize, baseSize * 0.5) : baseSize
        let font = Font.system(size: finalSize, weight: isMeaning ? .regular : .bold)
        return isMeaning ? font.italic() : font
    }


    private func fitFontSize(
        text: String,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        maxSize: CGFloat,
        minSize: CGFloat,
        weight: NSFont.Weight,
        italic: Bool
    ) -> CGFloat {
        if text.isEmpty { return minSize }

        // Check cache first
        if let cached = CacheManager.shared.getCachedFontSize(
            text: text,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            maxSize: maxSize,
            minSize: minSize,
            weight: weight,
            italic: italic
        ) {
            return cached
        }

        // Calculate if not cached
        var low = minSize
        var high = maxSize
        var best = minSize
        let constraint = CGSize(width: maxWidth, height: maxHeight)

        while high - low > 0.5 {
            let mid = (low + high) / 2
            let font = makeNSFont(size: mid, weight: weight, italic: italic)
            let rect = measure(text: text, font: font, constraint: constraint)
            if rect.width <= constraint.width && rect.height <= constraint.height {
                best = mid
                low = mid
            } else {
                high = mid
            }
        }

        // Cache the result
        CacheManager.shared.cacheFontSize(
            best,
            text: text,
            maxWidth: maxWidth,
            maxHeight: maxHeight,
            maxSize: maxSize,
            minSize: minSize,
            weight: weight,
            italic: italic
        )

        return best
    }

    private func makeNSFont(size: CGFloat, weight: NSFont.Weight, italic: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if italic {
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        }
        return base
    }

    private func measure(text: String, font: NSFont, constraint: CGSize) -> CGRect {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byWordWrapping
        paragraphStyle.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraphStyle
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        return attributed.boundingRect(
            with: constraint,
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

}

struct BackgroundVisualView: View {
    let url: URL
    let isVisible: Bool

    var body: some View {
        if isVideoURL(url) {
            BackgroundVideoView(url: url, isVisible: isVisible)
        } else {
            BackgroundImageView(url: url)
        }
    }

    private func isVideoURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ["mp4", "mov", "m4v", "avi", "mkv"].contains(ext)
    }
}

struct BackgroundImageView: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.black
            if let image = image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            }
        }
        .onAppear {
            loadImage()
        }
        .onChange(of: url) { _, _ in
            loadImage()
        }
    }

    private func loadImage() {
        DispatchQueue.global(qos: .userInitiated).async {
            let loadedImage = NSImage(contentsOf: url)
            DispatchQueue.main.async {
                self.image = loadedImage
            }
        }
    }
}

struct BackgroundVideoView: View {
    let url: URL
    let isVisible: Bool
    @State private var player: AVPlayer? = nil
    @State private var endObserver: Any? = nil
    @State private var configuredURL: URL? = nil

    var body: some View {
        AVPlayerViewRepresentable(
            player: player,
            isMuted: true,
            isFill: true
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            configurePlayer()
        }
        .onChange(of: url) { _, _ in
            configurePlayer()
        }
        .onChange(of: isVisible) { _, newValue in
            if newValue {
                player?.play()
            } else {
                player?.pause()
            }
            configureLoopObserver()
        }
        .onDisappear {
            teardownPlayer()
        }
    }

    private func configurePlayer() {
        if configuredURL == url, let currentPlayer = player {
            currentPlayer.isMuted = true
            if isVisible {
                currentPlayer.play()
            } else {
                currentPlayer.pause()
            }
            configureLoopObserver()
            return
        }

        teardownPlayer()
        let newPlayer = AVPlayer(url: url)
        newPlayer.allowsExternalPlayback = false
        newPlayer.isMuted = true
        player = newPlayer
        configuredURL = url
        if isVisible {
            newPlayer.play()
        }
        configureLoopObserver()
    }

    private func teardownPlayer() {
        removeLoopObserver()
        endObserver = nil
        player?.pause()
        player = nil
        configuredURL = nil
    }

    private func configureLoopObserver() {
        removeLoopObserver()
        guard let currentItem = player?.currentItem else { return }
        let currentPlayer = player
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { _ in
            guard isVisible else { return }
            currentPlayer?.seek(to: .zero)
            currentPlayer?.play()
        }
    }

    private func removeLoopObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
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

struct VideoSlideView: View {
    let url: URL
    @Binding var isMuted: Bool
    @Binding var isPaused: Bool
    @Binding var isLooping: Bool
    @Binding var isFill: Bool
    @EnvironmentObject private var session: PresentationSession
    @State private var player: AVPlayer? = nil
    @State private var endObserver: Any? = nil
    @State private var timeObserver: Any? = nil
    @State private var configuredURL: URL? = nil
    @State private var loadedDuration: Double = 0

    var body: some View {
        AVPlayerViewRepresentable(
            player: player,
            isMuted: isMuted,
            isFill: isFill
        )
            .onAppear {
                configurePlayer()
            }
            .onChange(of: url) { _, _ in
                configurePlayer()
            }
            .onChange(of: isMuted) { _, newValue in
                player?.isMuted = newValue
            }
            .onChange(of: isPaused) { _, newValue in
                if newValue {
                    player?.pause()
                } else {
                    player?.play()
                }
            }
            .onChange(of: isLooping) { _, _ in
                configureLoopObserver()
            }
            .onChange(of: isFill) { _, _ in
                // handled in AVPlayerViewRepresentable
            }
            .onChange(of: session.videoSeekRevision) { _, _ in
                seekToSessionTarget()
            }
            .onDisappear {
                teardownPlayer()
            }
    }

    private func configurePlayer() {
        if configuredURL == url, let currentPlayer = player {
            currentPlayer.isMuted = isMuted
            if isPaused {
                currentPlayer.pause()
            } else {
                currentPlayer.play()
            }
            configureLoopObserver()
            configureTimeObserver()
            loadVideoDurationIfNeeded()
            updateSessionProgress()
            return
        }

        teardownPlayer()
        loadedDuration = 0
        let newPlayer = AVPlayer(url: url)
        newPlayer.allowsExternalPlayback = false
        player = newPlayer
        configuredURL = url
        newPlayer.isMuted = isMuted
        if isPaused {
            newPlayer.pause()
        } else {
            newPlayer.play()
        }
        configureLoopObserver()
        configureTimeObserver()
        loadVideoDurationIfNeeded()
        seekToSessionTarget()
        updateSessionProgress()
    }

    private func teardownPlayer() {
        removeLoopObserver()
        removeTimeObserver()
        endObserver = nil
        timeObserver = nil
        player?.pause()
        player = nil
        configuredURL = nil
        loadedDuration = 0
    }

    private func configureLoopObserver() {
        removeLoopObserver()
        guard isLooping, let currentItem = player?.currentItem else { return }
        let currentPlayer = player
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: currentItem,
            queue: .main
        ) { _ in
            currentPlayer?.seek(to: .zero)
            currentPlayer?.play()
        }
    }

    private func configureTimeObserver() {
        removeTimeObserver()
        guard let player else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { _ in
            updateSessionProgress()
        }
    }

    private func removeLoopObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
    }

    private func removeTimeObserver() {
        guard let timeObserver, let player else { return }
        player.removeTimeObserver(timeObserver)
    }

    private func seekToSessionTarget() {
        guard let player else { return }
        let target = CMTime(seconds: session.videoSeekTarget, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            updateSessionProgress()
        }
    }

    private func updateSessionProgress() {
        guard let player else { return }
        let currentTime = player.currentTime().seconds
        let itemDuration = player.currentItem?.duration.seconds ?? 0
        let duration = itemDuration.isFinite && itemDuration > 0
            ? itemDuration
            : loadedDuration
        session.updateVideoPlaybackProgress(
            currentTime: currentTime,
            duration: duration
        )
    }

    private func loadVideoDurationIfNeeded() {
        guard loadedDuration <= 0 else { return }
        let durationURL = url
        let asset = AVURLAsset(url: durationURL)
        asset.loadValuesAsynchronously(forKeys: ["duration"]) {
            var error: NSError?
            let status = asset.statusOfValue(forKey: "duration", error: &error)
            guard status == .loaded else { return }
            let seconds = asset.duration.seconds
            DispatchQueue.main.async {
                guard configuredURL == durationURL, seconds.isFinite, seconds > 0 else { return }
                loadedDuration = seconds
                updateSessionProgress()
            }
        }
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
    weak var session: PresentationSession?

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

    private func requestHideSlides() {
        DispatchQueue.main.async { [weak self] in
            self?.session?.hideSlides()
        }
    }

    private func requestStopProjection() {
        DispatchQueue.main.async { [weak self] in
            self?.session?.stopPresentation()
        }
    }

    private func requestToggleSlidesVisibility() {
        DispatchQueue.main.async { [weak self] in
            guard let session = self?.session else { return }
            if session.areSlidesVisible {
                session.hideSlides()
            } else {
                session.showSlides(preferredScreen: nil)
            }
        }
    }

    private func requestClearBackgroundVisual() {
        DispatchQueue.main.async { [weak self] in
            self?.session?.setBackgroundVisual(nil)
        }
    }

    private func requestClearBackgroundAudio() {
        DispatchQueue.main.async { [weak self] in
            self?.session?.clearBackgroundAudio()
        }
    }

    private func requestClearAllLayers() {
        DispatchQueue.main.async { [weak self] in
            guard let session = self?.session else { return }
            session.hideSlides()
            session.setBackgroundVisual(nil)
            session.clearBackgroundAudio()
        }
    }

    private func requestMoveSelection(_ delta: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.session?.moveSelection(delta)
        }
    }

    private func requestMoveSelection(direction: ThumbnailGridNavigationDirection) {
        DispatchQueue.main.async { [weak self] in
            self?.session?.moveSelection(direction: direction)
        }
    }
}
