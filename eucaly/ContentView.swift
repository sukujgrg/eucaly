import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PDFKit
import CoreGraphics

public struct ContentView: View {
    @State private var rawLyrics: String = ""
    @StateObject private var session = PresentationSession()
    @StateObject private var flow = PresentationFlowController()
    @State private var folderURL: URL?
    @State private var markdownFiles: [URL] = []
    @State private var selectedFileURL: URL?
    @State private var selectedPlaylistEntryID: UUID?
    @State private var selectedPlaylistEntryIDs: Set<UUID> = []
    @StateObject private var playlistStore = PlaylistStore()
    @AppStorage("libraryRootPath") private var libraryRootPath: String = ""
    @AppStorage("libraryRootBookmark") private var libraryRootBookmark: String = ""
    @AppStorage("downloadsBookmark") private var downloadsBookmark: String = ""
    @AppStorage("backgroundVisualBookmark") private var backgroundVisualBookmark: String = ""
    @AppStorage("backgroundAudioBookmark") private var backgroundAudioBookmark: String = ""
    @AppStorage("backgroundAudioVolume") private var backgroundAudioVolume: Double = 1.0
    @AppStorage("backgroundAudioLoop") private var backgroundAudioLoop: Bool = true
    @AppStorage("thumbnailScale") private var thumbnailScale: Double = 1.0
    @AppStorage("presentationFontScale") private var presentationFontScale: Double = 1.0
    @AppStorage("thumbnailFontScale") private var thumbnailFontScale: Double = 1.0
    @AppStorage("countdownMinutes") private var countdownMinutes: Int = 5
    @AppStorage("overlayScale") private var overlayScale: Double = 1.0
    @AppStorage("windowCaptureFrameRate") private var windowCaptureFrameRate: Int = 30
    @AppStorage("projectionScreenDisplayID") private var projectionScreenDisplayID: Int = 0
    @AppStorage("savedWebpageURLs") private var savedWebpageURLs: String = ""
    @AppStorage("savedSelectedWebpageURL") private var savedSelectedWebpageURL: String = ""
    @AppStorage("savedWebpageTitles") private var savedWebpageTitles: String = ""
    @State private var overlayScaleDraft: Double = 1.0
    @State private var overlayScaleDebounceToken = UUID()
    @State private var backgroundAudioVolumeDraft: Double = 1.0
    @State private var backgroundAudioVolumeDebounceToken = UUID()
    @State private var fileDisplayNames: [URL: String] = [:]
    @State private var newFileWarning: String? = nil
    @State private var lastLoadedText: String = ""
    @State private var sidebarSelection: SidebarSelection? = nil
    @State private var ignoresNextSidebarSelectionChange: Bool = false
    @State private var currentLoadingURL: URL? = nil
    @State private var isEditingLyrics: Bool = false
    @State private var libraryFolders: [URL] = []
    @State private var selectedLibraryFolder: URL? = nil
    @State private var librarySearchQuery: String = ""
    @State private var webpageURLs: [URL] = []
    @State private var webpageTitles: [URL: String] = [:]
    @State private var selectedWebpageURL: URL? = nil
    @State private var previewWebpageMuted: Bool = false
    @State private var librarySearchResults: [LibraryTextSearchIndex.SearchResult] = []
    @State private var isLibrarySearchPresented: Bool = false
    @State private var selectedLibrarySearchResult: URL? = nil
    @State private var isLibrarySearchIndexing: Bool = false
    @State private var librarySearchDebounceTask: Task<Void, Never>? = nil
    @State private var librarySearchRebuildTask: Task<Void, Never>? = nil
    @State private var projectionScreenOptions: [ProjectionScreenOption] = []
    @FocusState private var isSidebarFocused: Bool
    @State private var securityScopedRoot: URL? = nil
    @State private var securityScopedDownloads: URL? = nil
    @State private var securityScopedBackgroundVisual: URL? = nil
    @State private var securityScopedBackgroundAudio: URL? = nil
    @StateObject private var screenCaptureManager = ScreenCaptureManager.shared
    @State private var librarySearchIndex = LibraryTextSearchIndex()
    @State private var isPreviewCollapsed: Bool = false
    private let playlistDirectoryName = "Playlist"
    private let paneToggleAnimation = Animation.easeInOut(duration: 0.20)
    private let loadAnimation = Animation.easeInOut(duration: 0.24)
    private let librarySearchMinimumCharacterCount = 3
    private let windowCaptureFrameRateOptions = [24, 30, 60]

    private struct ProjectionScreenOption: Identifiable, Hashable {
        let displayID: Int
        let label: String
        var id: Int { displayID }
    }

    private enum FileKind {
        case pdf
        case image
        case video
        case txt
        case unsupported

        init(url: URL) {
            let ext = url.pathExtension.lowercased()
            switch ext {
            case "pdf":
                self = .pdf
            case "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff":
                self = .image
            case "mp4", "mov", "m4v", "avi", "mkv":
                self = .video
            case "txt":
                self = .txt
            default:
                self = .unsupported
            }
        }

        var isSupportedLibraryItem: Bool {
            self != .unsupported
        }

        var isEditableLyrics: Bool {
            switch self {
            case .txt:
                return true
            default:
                return false
            }
        }
    }

    private var isCurrentSelectionMediaFile: Bool {
        guard let url = currentSelectedURL else { return false }
        let kind = FileKind(url: url)
        switch kind {
        case .pdf, .image, .video:
            return true
        default:
            return false
        }
    }

    private var canControlProjectedOverlay: Bool {
        session.isPresenting
    }

    private var isWindowCaptureSupported: Bool {
        if #available(macOS 15.0, *) {
            return true
        }
        return false
    }

    private var captureWindows: [ScreenCaptureManager.CapturedWindow] {
        guard isWindowCaptureSupported else { return [] }
        return screenCaptureManager.windows
    }

    private func deferSessionChange(_ action: @escaping () -> Void) {
        DispatchQueue.main.async {
            action()
        }
    }

    private func syncWindowCaptureFrameRate() {
        let normalized = windowCaptureFrameRateOptions.contains(windowCaptureFrameRate)
            ? windowCaptureFrameRate
            : 30
        if normalized != windowCaptureFrameRate {
            DispatchQueue.main.async {
                windowCaptureFrameRate = normalized
            }
        }
        if #available(macOS 14.0, *) {
            screenCaptureManager.preferredFrameRate = normalized
        }
    }

    public var body: some View {
        rootSplitView
    }

    private var rootSplitView: some View {
        rootSplitWithLibrarySearchOverlay
    }

    private var rootSplitBase: some View {
        NavigationSplitView {
            sidebarPane
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 520)
        .toolbar {
            projectionToolbar
        }
        .applyToolbarBackgroundIfAvailable()
    }

    private var rootSplitWithLibrarySearchOverlay: some View {
        ZStack {
            rootSplitWithNotificationObservers

            if isLibrarySearchPresented {
                LibrarySearchOverlayView(
                    query: $librarySearchQuery,
                    selectedResult: $selectedLibrarySearchResult,
                    actions: matchingLibrarySearchActions,
                    webpageCandidateURL: commandPaletteWebpageCandidateURL,
                    results: filteredLibrarySearchResults,
                    minimumCharacterCount: librarySearchMinimumCharacterCount,
                    isIndexing: isLibrarySearchIndexing,
                    displayName: { displayName(for: $0) },
                    snippet: librarySearchSnippet(for:),
                    onRunAction: runLibrarySearchAction,
                    onOpenWebpage: openWebpageFromCommandPalette,
                    onClose: dismissLibrarySearch,
                    onOpenResult: previewLibrarySearchResult
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: isLibrarySearchPresented)
    }

    private var rootSplitWithStateObservers: some View {
        rootSplitBase
        .onAppear {
            handleRootOnAppear()
            syncWindowCaptureFrameRate()
        }
        .onExitCommand {
            handleExitCommand()
        }
        .onChange(of: libraryRootBookmark) { _, _ in
            refreshLibraryRootAccess()
        }
        .onChange(of: libraryRootPath) { _, _ in
            refreshLibraryRootAccess()
        }
        .onChange(of: downloadsBookmark) { _, _ in
            refreshDownloadsAccess()
        }
        .onChange(of: backgroundVisualBookmark) { _, _ in
            refreshBackgroundVisualAccess()
        }
        .onChange(of: backgroundAudioBookmark) { _, _ in
            refreshBackgroundAudioAccess()
        }
        .onChange(of: selectedFileURL) { _, newValue in
            handleSelectedFileURLChange(newValue)
        }
        .onChange(of: selectedPlaylistEntryID) { _, newValue in
            handleSelectedPlaylistEntryIDChange(newValue)
        }
        .onChange(of: overlayScale) { _, newValue in
            handleOverlayScaleChange(newValue)
        }
        .onChange(of: backgroundAudioVolume) { _, newValue in
            handleBackgroundAudioVolumeChange(newValue)
        }
        .onChange(of: backgroundAudioLoop) { _, newValue in
            deferSessionChange {
                session.setBackgroundAudioLoop(newValue)
            }
        }
        .onChange(of: windowCaptureFrameRate) { _, _ in
            syncWindowCaptureFrameRate()
        }
        .onChange(of: librarySearchQuery) { _, newValue in
            handleLibrarySearchQueryChange(newValue)
        }
        .onChange(of: webpageURLs) { _, _ in
            persistWebpageState()
        }
        .onChange(of: selectedWebpageURL) { _, _ in
            persistWebpageState()
        }
        .onChange(of: webpageTitles) { _, _ in
            persistWebpageState()
        }
        .onDisappear {
            librarySearchDebounceTask?.cancel()
            librarySearchRebuildTask?.cancel()
        }
    }

    private func handleExitCommand() {
        guard session.isPresenting, session.areSlidesVisible else { return }
        deferSessionChange {
            flow.hideSlides(in: session)
        }
    }

    private var rootSplitWithNotificationObservers: some View {
        rootSplitWithStateObservers
            .onReceive(screenCaptureManager.$windows, perform: handleCaptureWindowsUpdate)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
                refreshProjectionScreenOptions()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSlidesVisibility), perform: handleToggleSlidesVisibilityNotification)
            .onReceive(NotificationCenter.default.publisher(for: .stopProjection), perform: handleStopProjectionNotification)
            .onReceive(NotificationCenter.default.publisher(for: .toggleBackgroundVisibility), perform: handleToggleBackgroundVisibilityNotification)
            .onReceive(NotificationCenter.default.publisher(for: .toggleBackgroundAudio), perform: handleToggleBackgroundAudioNotification)
            .onReceive(NotificationCenter.default.publisher(for: .clearAllLayers), perform: handleClearAllLayersNotification)
        .onReceive(NotificationCenter.default.publisher(for: .clearBackgroundVisual), perform: handleClearBackgroundVisualNotification)
        .onReceive(NotificationCenter.default.publisher(for: .clearBackgroundAudio), perform: handleClearBackgroundAudioNotification)
        .onReceive(NotificationCenter.default.publisher(for: .newLyrics), perform: handleNewLyricsNotification)
        .onReceive(NotificationCenter.default.publisher(for: .saveLyrics), perform: handleSaveLyricsNotification)
        .onReceive(NotificationCenter.default.publisher(for: .showLibrarySearch)) { _ in
            presentLibrarySearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification), perform: handleMainWindowWillCloseNotification)
    }

    @ViewBuilder
    private var sidebarPane: some View {
        SidebarView(
            session: session,
            isWindowCaptureSupported: isWindowCaptureSupported,
            libraryFiles: markdownFiles,
            playlistItems: playlistSidebarItems,
            libraryRootURL: libraryRootURL,
            downloadsURL: downloadsURL,
            libraryFolders: libraryFolders,
            captureWindows: captureWindows,
            webpageURLs: webpageURLs,
            selectedWebpageURL: selectedWebpageURL,
            selectedLibraryFolder: $selectedLibraryFolder,
            selectedFileURL: $selectedFileURL,
            selectedPlaylistEntryID: $selectedPlaylistEntryID,
            selectedPlaylistEntryIDs: $selectedPlaylistEntryIDs,
            sidebarSelection: $sidebarSelection,
            backgroundAudioLoop: $backgroundAudioLoop,
            overlayScaleDraft: $overlayScaleDraft,
            backgroundAudioVolumeDraft: $backgroundAudioVolumeDraft,
            countdownMinutes: $countdownMinutes,
            presentationFontScale: $presentationFontScale,
            thumbnailFontScale: $thumbnailFontScale,
            thumbnailScale: $thumbnailScale,
            windowCaptureFrameRate: $windowCaptureFrameRate,
            isSidebarFocused: $isSidebarFocused,
            displayName: { displayName(for: $0) },
            titleForWebpage: webpageTitle(for:),
            onShowLibrarySearch: presentLibrarySearch,
            onSelectLibraryFolder: handleSelectedLibraryFolderChange,
            onSelectDownloads: selectDownloadsFolder,
            onAddSelectedToPlaylist: addSelectedToPlaylist,
            onRemoveSelectedFromPlaylist: removeSelectedFromPlaylist,
            onMovePlaylistUp: moveSelectedPlaylistEntriesUp,
            onMovePlaylistDown: moveSelectedPlaylistEntriesDown,
            onChooseBackgroundVisual: chooseBackgroundVisual,
            onClearBackgroundVisual: clearBackgroundVisual,
            onChooseBackgroundAudio: chooseBackgroundAudio,
            onPlayPauseBackgroundAudio: toggleBackgroundAudioPlayback,
            onStopBackgroundAudio: stopBackgroundAudioPlayback,
            onClearBackgroundAudio: clearBackgroundAudio,
            onApplyBackgroundAudioVolume: handleBackgroundAudioVolumeDraftChange,
            onOverlayScaleDraftChange: handleOverlayScaleDraftChange,
            onSetOverlayMode: setOverlayMode,
            onStartCountdown: startCountdown,
            onStopCountdown: stopCountdown,
            onSetClockVisible: setClockVisible,
            onSelectionChange: handleSidebarSelection,
            onClearWebpage: clearWebpageFromSidebar,
            onPickWindow: pickWindowForPreview,
            onClearSelectedWindow: clearSelectedWindowFromSidebar
        )
        .navigationTitle("")
    }

    @ViewBuilder
    private var detailPane: some View {
        detailView
    }

    @ToolbarContentBuilder
    private var projectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 10) {
                let isShowingSlides = session.isPresenting && session.areSlidesVisible
                Button {
                    toggleSlidesFromUI()
                } label: {
                    Label(
                        isShowingSlides ? "Hide Slides" : "Show Slides",
                        systemImage: isShowingSlides ? "rectangle.slash" : "rectangle"
                    )
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .disabled(!canToggleSlides)
                .help(isShowingSlides ? "Hide Slides" : "Show Slides")

                projectionScreenPicker

                let isBackgroundVisible = session.isBackgroundVisualVisible
                Button {
                    toggleBackgroundVisualFromUI()
                } label: {
                    Label(
                        "Background",
                        systemImage: isBackgroundVisible ? "photo.fill.on.rectangle.fill" : "photo.on.rectangle"
                    )
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .disabled(!session.hasAvailableBackgroundVisual || isCurrentSelectionMediaFile)
                .help(isBackgroundVisible ? "Hide background" : "Show background")
            }
        }
    }

    private var projectionScreenPicker: some View {
        Menu {
            Button("Auto") {
                projectionScreenDisplayID = 0
            }

            if !projectionScreenOptions.isEmpty {
                Divider()
                ForEach(projectionScreenOptions) { option in
                    Button(option.label) {
                        projectionScreenDisplayID = option.displayID
                    }
                }
            }
        } label: {
            Label("Projection Screen", systemImage: "display")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .help("Choose projection display")
    }

    private func handleRootOnAppear() {
        refreshProjectionScreenOptions()
        refreshLibraryRootAccess()
        refreshDownloadsAccess()
        refreshBackgroundVisualAccess()
        refreshBackgroundAudioAccess()
        restoreWebpageState()
        loadPlaylists()
        overlayScaleDraft = overlayScale
        backgroundAudioVolumeDraft = backgroundAudioVolume
        deferSessionChange {
            session.setBackgroundAudioLoop(backgroundAudioLoop)
            session.setBackgroundAudioVolume(backgroundAudioVolume)
        }
    }

    private func handleSelectedFileURLChange(_ newValue: URL?) {
        if let newValue {
            sidebarSelection = .library(newValue)
        } else if case .library = sidebarSelection {
            sidebarSelection = nil
        }
    }

    private func handleSelectedPlaylistEntryIDChange(_ newValue: UUID?) {
        if let newValue {
            sidebarSelection = .playlist(newValue)
        } else if case .playlist = sidebarSelection {
            sidebarSelection = nil
        }
    }

    private func handleOverlayScaleChange(_ newValue: Double) {
        if abs(overlayScaleDraft - newValue) > 0.0001 {
            overlayScaleDraft = newValue
        }
    }

    private func handleBackgroundAudioVolumeChange(_ newValue: Double) {
        if abs(backgroundAudioVolumeDraft - newValue) > 0.0001 {
            backgroundAudioVolumeDraft = newValue
        }
    }

    private func handleCaptureWindowsUpdate(_ windows: [ScreenCaptureManager.CapturedWindow]) {
        guard isWindowCaptureSupported else { return }
        if windows.isEmpty {
            if case .window = sidebarSelection {
                sidebarSelection = nil
            }
            if flow.previewSlides.contains(where: { $0.captureWindowID != nil }) {
                flow.clearPreviewDocument()
            }
            return
        }
        if case .window(let currentID) = sidebarSelection,
           windows.contains(where: { $0.windowID == currentID }) {
            return
        }
        guard let firstWindow = windows.first else { return }
        sidebarSelection = .window(firstWindow.windowID)
        loadWindowPreview(for: firstWindow.windowID)
    }

    private func handleToggleSlidesVisibilityNotification(_ notification: Notification) {
        deferSessionChange {
            flow.toggleSlidesVisibility(
                in: session,
                preferredScreen: preferredProjectionScreen()
            )
        }
    }

    private func handleStopProjectionNotification(_ notification: Notification) {
        deferSessionChange {
            session.stopPresentation()
        }
    }

    private func handleToggleBackgroundVisibilityNotification(_ notification: Notification) {
        deferSessionChange {
            session.toggleBackgroundVisualVisibility(
                preferredScreen: preferredProjectionScreen()
            )
        }
    }

    private func handleToggleBackgroundAudioNotification(_ notification: Notification) {
        deferSessionChange {
            if session.isBackgroundAudioPlaying {
                session.pauseBackgroundAudio()
            } else {
                session.playBackgroundAudio()
            }
        }
    }

    private func handleClearAllLayersNotification(_ notification: Notification) {
        deferSessionChange {
            flow.hideSlides(in: session)
            clearBackgroundVisual()
            clearBackgroundAudio()
        }
    }

    private func handleClearBackgroundVisualNotification(_ notification: Notification) {
        deferSessionChange {
            clearBackgroundVisual()
        }
    }

    private func handleClearBackgroundAudioNotification(_ notification: Notification) {
        deferSessionChange {
            clearBackgroundAudio()
        }
    }

    private func handleNewLyricsNotification(_ notification: Notification) {
        DispatchQueue.main.async {
            handleNewLyrics()
        }
    }

    private func handleSaveLyricsNotification(_ notification: Notification) {
        guard isEditingLyrics, !isCurrentSelectionMediaFile else { return }
        deferSessionChange {
            if currentSelectedURL == nil {
                createNewFile()
            } else {
                saveCurrentFile()
            }
        }
    }

    private func handleMainWindowWillCloseNotification(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else { return }
        if closingWindow is PresentationWindow { return }
        let remainingNonPresentation = NSApp.windows.filter { window in
            !(window is PresentationWindow) && window != closingWindow
        }
        guard remainingNonPresentation.isEmpty else { return }
        deferSessionChange {
            session.stopPresentation()
        }
    }

    private func handleNewLyrics() {
        var state = NewLyricsState(
            rawLyrics: rawLyrics,
            lastLoadedText: lastLoadedText,
            isEditingLyrics: isEditingLyrics,
            selectedFileURL: selectedFileURL,
            selectedPlaylistEntryID: selectedPlaylistEntryID,
            selectedPlaylistEntryIDs: selectedPlaylistEntryIDs,
            sidebarSelection: sidebarSelection
        )
        NewLyricsAction.apply(state: &state, flow: flow)
        rawLyrics = state.rawLyrics
        lastLoadedText = state.lastLoadedText
        isEditingLyrics = state.isEditingLyrics
        selectedFileURL = state.selectedFileURL
        selectedPlaylistEntryID = state.selectedPlaylistEntryID
        selectedPlaylistEntryIDs = state.selectedPlaylistEntryIDs
        sidebarSelection = state.sidebarSelection
    }

    public init() {}

    private var detailView: some View {
        DetailRootView(
            editorPane: EditorPaneContainerView(
                newFileWarning: newFileWarning,
                rawLyrics: $rawLyrics,
                saveButtonTitle: saveButtonTitle,
                canSave: canSaveEditorContent,
                onAction: handleEditorAction
            ),
            previewPane: PreviewPaneContainerView(
                session: session,
                flow: flow,
                isCollapsed: $isPreviewCollapsed,
                isWebpageMuted: $previewWebpageMuted,
                canEditSelection: canEditSelection,
                thumbnailScale: thumbnailScale,
                paneToggleAnimation: paneToggleAnimation,
                loadAnimation: loadAnimation,
                titleForWebpage: webpageTitle(for:),
                onWebpageNavigationChange: updatePreviewWebpageURL(to:from:),
                onWebpageTitleChange: updateWebpageTitle(_:for:),
                onEdit: {
                    isEditingLyrics = true
                },
                onLoadToCurrent: handleLoadPreviewToCurrent
            ),
            currentPane: CurrentPaneContainerView(
                session: session,
                flow: flow,
                thumbnailScale: thumbnailScale,
                paneToggleAnimation: paneToggleAnimation,
                loadAnimation: loadAnimation,
                titleForWebpage: webpageTitle(for:),
                onWebpageNavigationChange: updateCurrentWebpageURL(to:from:),
                onWebpageTitleChange: updateWebpageTitle(_:for:),
                onClearCurrent: clearCurrentDocument
            ),
            showEditorAndPreview: isEditingLyrics && !isCurrentSelectionMediaFile && !isPreviewCollapsed
        )
    }

    private var saveButtonTitle: String {
        currentSelectedURL == nil ? "Save As..." : "Save"
    }

    private var canSaveEditorContent: Bool {
        let trimmed = rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if currentSelectedURL != nil && rawLyrics == lastLoadedText { return false }
        return true
    }

    private func handleEditorAction(_ action: EditorPaneAction) {
        switch action {
        case .close:
            isEditingLyrics = false
        case .save:
            if currentSelectedURL == nil {
                createNewFile()
            } else {
                saveCurrentFile()
            }
        case .format:
            formatAndSave()
        case .clear:
            rawLyrics = ""
            clearCurrentDocument()
        }
    }

    private func setCurrentSlides(_ slides: [Slide], preferredSelection: Slide.ID? = nil) {
        flow.setCurrentSlides(slides, in: session, preferredSelection: preferredSelection)
    }

    private func clearCurrentDocument() {
        let clearedWindowFromCurrent = session.slides.contains { $0.captureWindowID != nil }
        flow.clearCurrentDocument(in: session)
        flow.isCurrentCollapsed = true
        if clearedWindowFromCurrent, case .window = sidebarSelection {
            sidebarSelection = nil
        }
    }

    private func selectCurrentSlide(_ slideID: Slide.ID) {
        flow.selectCurrentSlide(slideID, in: session)
    }

    private func handleLoadPreviewToCurrent() {
        guard !flow.previewSlides.isEmpty else { return }
        flow.movePreviewToCurrent(in: session, force: true)
    }

    private func toggleSlidesFromUI() {
        DispatchQueue.main.async {
            flow.toggleSlidesVisibility(
                in: session,
                preferredScreen: preferredProjectionScreen()
            )
        }
    }

    private func toggleBackgroundVisualFromUI() {
        DispatchQueue.main.async {
            session.toggleBackgroundVisualVisibility(
                preferredScreen: preferredProjectionScreen()
            )
        }
    }

    private func preferredProjectionScreen() -> NSScreen? {
        let activeScreens = NSScreen.screens.filter { $0.frame.width > 0 && $0.frame.height > 0 }
        if projectionScreenDisplayID != 0,
           let exactMatch = activeScreens.first(where: { screenDisplayID($0) == projectionScreenDisplayID }) {
            return exactMatch
        }
        return activeScreens.count > 1 ? activeScreens[1] : NSScreen.main
    }

    private func refreshProjectionScreenOptions() {
        let activeScreens = NSScreen.screens
            .filter { $0.frame.width > 0 && $0.frame.height > 0 }
            .map { screen in
                (
                    name: screen.localizedName,
                    displayID: screenDisplayID(screen),
                    width: Int(screen.frame.width.rounded()),
                    height: Int(screen.frame.height.rounded())
                )
            }

        let countsByName = Dictionary(grouping: activeScreens, by: \.name)
            .mapValues(\.count)

        projectionScreenOptions = activeScreens.compactMap { screen in
            guard screen.displayID != 0 else { return nil }
            let hasDuplicateName = (countsByName[screen.name] ?? 0) > 1
            let label: String
            if hasDuplicateName {
                label = "\(screen.name) • \(screen.width)x\(screen.height) • #\(screen.displayID)"
            } else {
                label = "\(screen.name) • \(screen.width)x\(screen.height)"
            }
            return ProjectionScreenOption(displayID: screen.displayID, label: label)
        }

        if projectionScreenDisplayID != 0,
           !projectionScreenOptions.contains(where: { $0.displayID == projectionScreenDisplayID }) {
            projectionScreenDisplayID = 0
        }
    }

    private func screenDisplayID(_ screen: NSScreen) -> Int {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return 0
        }
        return number.intValue
    }

    private var canEditSelection: Bool {
        guard !isCurrentSelectionMediaFile, let url = currentSelectedURL else { return false }
        return isLyricsFile(url)
    }

    private var canToggleSlides: Bool {
        session.isPresenting || !session.slides.isEmpty || !flow.previewSlides.isEmpty || session.hasAvailableBackgroundVisual
    }

    private func buildPDFSlides(from document: PDFDocument, url: URL) -> [Slide] {
        guard document.pageCount > 0 else { return [] }
        return (0..<document.pageCount).map { index in
            Slide(
                index: index + 1,
                lines: [],
                label: "Page \(index + 1)",
                videoURL: nil,
                pdfURL: url,
                pdfPageIndex: index,
                imageURL: nil,
                captureWindowID: nil
            )
        }
    }

    private func buildImageSlides(from url: URL) -> [Slide] {
        return [
            Slide(
                index: 1,
                lines: [],
                label: url.lastPathComponent,
                videoURL: nil,
                pdfURL: nil,
                pdfPageIndex: nil,
                imageURL: url,
                captureWindowID: nil
            )
        ]
    }

    private func buildVideoSlides(from url: URL) -> [Slide] {
        return [
            Slide(
                index: 1,
                lines: [],
                label: url.lastPathComponent,
                videoURL: url,
                pdfURL: nil,
                pdfPageIndex: nil,
                imageURL: nil,
                captureWindowID: nil
            )
        ]
    }

    private func buildWindowSlides(from window: ScreenCaptureManager.CapturedWindow) -> [Slide] {
        let trimmedTitle = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = trimmedTitle.isEmpty ? window.appName : trimmedTitle
        return [
            Slide(
                index: 1,
                lines: [],
                label: "Window: \(displayTitle)",
                videoURL: nil,
                pdfURL: nil,
                pdfPageIndex: nil,
                imageURL: nil,
                captureWindowID: window.windowID
            )
        ]
    }

    private func buildWebpageSlides(from url: URL) -> [Slide] {
        let label = url.host(percentEncoded: false) ?? url.absoluteString
        return [
            Slide(
                index: 1,
                lines: [],
                label: label,
                videoURL: nil,
                pdfURL: nil,
                pdfPageIndex: nil,
                imageURL: nil,
                webpageURL: url
            )
        ]
    }

    private func isLyricsFile(_ url: URL) -> Bool {
        FileKind(url: url).isEditableLyrics
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if let root = libraryRootURL {
            panel.directoryURL = root
        }
        var types: [UTType] = [.plainText, .text, .pdf, .jpeg, .png, .gif, .bmp, .tiff, .movie, .video, .mpeg4Movie, .quickTimeMovie]
        if let webpType = UTType(filenameExtension: "webp") {
            types.append(webpType)
        }
        if let mkvType = UTType(filenameExtension: "mkv") {
            types.append(mkvType)
        }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            guard isUnderLibraryRoot(url) else {
                newFileWarning = "Selected file is outside the configured library root."
                return
            }
            newFileWarning = nil
            folderURL = url.deletingLastPathComponent()
            loadMarkdownFiles(from: folderURL!)
            selectedFileURL = url
            selectedPlaylistEntryID = nil
            selectedPlaylistEntryIDs = []
            loadSelectedFile()
        }
    }

    private func chooseBackgroundVisual() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = backgroundVisualContentTypes()
        if panel.runModal() == .OK, let url = panel.url {
            if let bookmark = SecurityScopedBookmarks.createBookmark(for: url) {
                backgroundVisualBookmark = bookmark
            }
            updateBackgroundVisualSelection(url)
        }
    }

    private func chooseBackgroundAudio() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = backgroundAudioContentTypes()
        if panel.runModal() == .OK, let url = panel.url {
            if let bookmark = SecurityScopedBookmarks.createBookmark(for: url) {
                backgroundAudioBookmark = bookmark
            }
            updateBackgroundAudioSelection(url, autoplay: true)
        }
    }

    private func backgroundVisualContentTypes() -> [UTType] {
        var types: [UTType] = [.image, .movie, .video, .mpeg4Movie, .quickTimeMovie]
        if let webp = UTType(filenameExtension: "webp") {
            types.append(webp)
        }
        if let mkv = UTType(filenameExtension: "mkv") {
            types.append(mkv)
        }
        return types
    }

    private func backgroundAudioContentTypes() -> [UTType] {
        var types: [UTType] = [.audio]
        if let mp3 = UTType(filenameExtension: "mp3") {
            types.append(mp3)
        }
        if let m4a = UTType(filenameExtension: "m4a") {
            types.append(m4a)
        }
        if let wav = UTType(filenameExtension: "wav") {
            types.append(wav)
        }
        if let aiff = UTType(filenameExtension: "aiff") {
            types.append(aiff)
        }
        if let flac = UTType(filenameExtension: "flac") {
            types.append(flac)
        }
        return types
    }

    private func isUnderLibraryRoot(_ url: URL) -> Bool {
        guard let root = libraryRootURL else { return true }
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }

    private func loadMarkdownFiles(from folder: URL) {
        let files = listSupportedLibraryFilesRecursively(from: folder)
        markdownFiles = files
        rebuildDisplayNames(for: markdownFiles + playlistResolvedURLs)
        rebuildLibrarySearchIndex(for: markdownFiles)
    }

    private func listSupportedLibraryFilesRecursively(from folder: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                values.isRegularFile == true,
                FileKind(url: url).isSupportedLibraryItem
            else {
                continue
            }
            files.append(url)
        }

        let basePath = folder.standardizedFileURL.path
        return files.sorted {
            relativeSortKey(for: $0, basePath: basePath) < relativeSortKey(for: $1, basePath: basePath)
        }
    }

    private func relativeSortKey(for url: URL, basePath: String) -> String {
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath) else { return path.lowercased() }
        let suffix = path.dropFirst(basePath.count)
        return suffix.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
    }

    private func loadSelectedFile() {
        guard let url = currentSelectedURL else { return }
        loadSelectedFile(url: url)
    }

    private func loadSelectedFile(url: URL) {
        currentLoadingURL = url
        let kind = FileKind(url: url)
        DispatchQueue.global(qos: .userInitiated).async {
            switch kind {
            case .pdf:
                guard let document = PDFDocument(url: url) else { return }
                let slides = buildPDFSlides(from: document, url: url)
                DispatchQueue.main.async {
                    guard currentLoadingURL == url else { return }
                    applyPreviewMediaLoad(slides: slides)
                }
            case .image:
                let slides = buildImageSlides(from: url)
                DispatchQueue.main.async {
                    guard currentLoadingURL == url else { return }
                    applyPreviewMediaLoad(slides: slides)
                }
            case .video:
                let slides = buildVideoSlides(from: url)
                DispatchQueue.main.async {
                    guard currentLoadingURL == url else { return }
                    applyPreviewMediaLoad(slides: slides)
                }
            case .txt:
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
                let doc = LyricsParser.parseDocument(contents, fileName: url.lastPathComponent)
                DispatchQueue.main.async {
                    guard currentLoadingURL == url else { return }
                    applyPreviewLyricsLoad(contents: contents, slides: doc.slides)
                }
            case .unsupported:
                return
            }
        }
    }

    private func applyPreviewMediaLoad(slides: [Slide]) {
        isEditingLyrics = false
        rawLyrics = ""
        lastLoadedText = ""
        setPreviewSlides(slides)
    }

    private func applyPreviewLyricsLoad(contents: String, slides: [Slide]) {
        isEditingLyrics = false
        rawLyrics = contents
        lastLoadedText = contents
        setPreviewSlides(slides)
        // Keep Current independent from browsing.
        // User must explicitly Load/Switch from Preview to Current.
    }

    private func setPreviewSlides(_ slides: [Slide], preferredSelection: Slide.ID? = nil) {
        flow.setPreviewSlides(slides, preferredSelection: preferredSelection)
    }

    private var downloadsURL: URL? {
        securityScopedDownloads
    }

    private var libraryRootURL: URL? {
        if let securityScopedRoot {
            return securityScopedRoot
        }
        if libraryRootPath.isEmpty {
            return nil
        }
        return URL(fileURLWithPath: libraryRootPath)
    }

    private func refreshLibraryRootAccess() {
        if libraryRootPath.isEmpty {
            let defaultRoot = URL(fileURLWithPath: NSString(string: "~/Documents/eucaly").expandingTildeInPath)
            libraryRootPath = defaultRoot.path
        }

        if let result = SecurityScopedBookmarks.resolve(libraryRootBookmark) {
            if let updated = result.updatedBookmark {
                libraryRootBookmark = updated
            }
            securityScopedRoot = result.url
        } else {
            securityScopedRoot = nil
        }

        if let root = libraryRootURL {
            configureLibraryRoot(root)
        }
    }

    private func refreshDownloadsAccess() {
        if let result = SecurityScopedBookmarks.resolve(downloadsBookmark) {
            if let updated = result.updatedBookmark {
                downloadsBookmark = updated
            }
            securityScopedDownloads = result.url
        } else {
            securityScopedDownloads = nil
        }
    }

    private func refreshBackgroundVisualAccess() {
        guard !backgroundVisualBookmark.isEmpty else {
            updateBackgroundVisualSelection(nil)
            return
        }
        if let result = SecurityScopedBookmarks.resolve(backgroundVisualBookmark) {
            if let updated = result.updatedBookmark {
                backgroundVisualBookmark = updated
            }
            updateBackgroundVisualSelection(result.url)
        } else {
            updateBackgroundVisualSelection(nil)
        }
    }

    private func refreshBackgroundAudioAccess() {
        guard !backgroundAudioBookmark.isEmpty else {
            updateBackgroundAudioSelection(nil, autoplay: false)
            return
        }
        if let result = SecurityScopedBookmarks.resolve(backgroundAudioBookmark) {
            if let updated = result.updatedBookmark {
                backgroundAudioBookmark = updated
            }
            updateBackgroundAudioSelection(result.url, autoplay: false)
        } else {
            updateBackgroundAudioSelection(nil, autoplay: false)
        }
    }

    private func updateBackgroundVisualSelection(_ url: URL?) {
        if securityScopedBackgroundVisual != url {
            securityScopedBackgroundVisual?.stopAccessingSecurityScopedResource()
        }
        securityScopedBackgroundVisual = url
        if let url {
            _ = url.startAccessingSecurityScopedResource()
        }
        deferSessionChange {
            session.setBackgroundVisual(url)
        }
    }

    private func updateBackgroundAudioSelection(_ url: URL?, autoplay: Bool) {
        if securityScopedBackgroundAudio != url {
            securityScopedBackgroundAudio?.stopAccessingSecurityScopedResource()
        }
        securityScopedBackgroundAudio = url
        if let url {
            _ = url.startAccessingSecurityScopedResource()
        }
        deferSessionChange {
            session.setBackgroundAudioLoop(backgroundAudioLoop)
            session.setBackgroundAudioVolume(backgroundAudioVolume)
            session.setBackgroundAudio(url: url, autoplay: autoplay)
        }
    }

    private func clearBackgroundVisual() {
        updateBackgroundVisualSelection(nil)
        backgroundVisualBookmark = ""
    }

    private func clearBackgroundAudio() {
        updateBackgroundAudioSelection(nil, autoplay: false)
        backgroundAudioBookmark = ""
    }

    private func applyBackgroundAudioVolume(_ value: Double) {
        let clamped = min(max(value, 0.0), 1.0)
        backgroundAudioVolume = clamped
        deferSessionChange {
            session.setBackgroundAudioVolume(clamped)
        }
    }

    private func configureLibraryRoot(_ root: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        ensurePlaylistDirectory(in: root)
        playlistStore.load(fromRoot: root)
        folderURL = root
        selectedLibraryFolder = nil
        loadLibraryFolders(from: root)
        loadMarkdownFiles(from: root)
    }

    private func loadLibraryFolders(from root: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            libraryFolders = []
            return
        }
        libraryFolders = items.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }
        .filter { $0.lastPathComponent != playlistDirectoryName }
        .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }
    }

    private func ensurePlaylistDirectory(in root: URL) {
        let fm = FileManager.default
        let url = root.appendingPathComponent(playlistDirectoryName, isDirectory: true)
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func displayName(for url: URL) -> String {
        if let name = fileDisplayNames[url], !name.isEmpty { return name }
        return url.lastPathComponent
    }

    private func librarySearchSnippet(for url: URL) -> String? {
        let standardizedURL = url.standardizedFileURL
        guard let snippet = filteredLibrarySearchResults.first(where: { $0.url == standardizedURL })?.snippet,
              !snippet.isEmpty else {
            return nil
        }
        return snippet
    }

    private var playlistResolvedURLs: [URL] {
        playlistStore.entries.compactMap { playlistStore.resolvedURL(for: $0) }
    }

    @MainActor
    private func handleLibrarySearchQueryChange(_ newQuery: String) {
        librarySearchDebounceTask?.cancel()

        let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= librarySearchMinimumCharacterCount else {
            librarySearchResults = []
            selectedLibrarySearchResult = nil
            return
        }

        let index = librarySearchIndex
        librarySearchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            guard !Task.isCancelled else { return }

            let results = await index.search(query: trimmed)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                let currentQuery = librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard currentQuery == trimmed else { return }
                librarySearchResults = filterSearchResultsToCurrentLibrary(results)
                syncSelectedLibrarySearchResult()
            }
        }
    }

    @MainActor
    private func rebuildLibrarySearchIndex(for urls: [URL]) {
        librarySearchRebuildTask?.cancel()
        let index = librarySearchIndex
        let urlsToIndex = urls

        isLibrarySearchIndexing = true
        librarySearchRebuildTask = Task {
            _ = await index.rebuild(with: urlsToIndex)
            guard !Task.isCancelled else { return }

            let currentQuery = await MainActor.run {
                librarySearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            var refreshedResults: [LibraryTextSearchIndex.SearchResult] = []
            if currentQuery.count >= librarySearchMinimumCharacterCount {
                refreshedResults = await index.search(query: currentQuery)
            }

            await MainActor.run {
                isLibrarySearchIndexing = false
                librarySearchResults = filterSearchResultsToCurrentLibrary(refreshedResults)
                syncSelectedLibrarySearchResult()
            }
        }
    }

    private var filteredLibrarySearchResults: [LibraryTextSearchIndex.SearchResult] {
        filterSearchResultsToCurrentLibrary(librarySearchResults)
    }

    private var matchingLibrarySearchActions: [LibraryCommandPaletteAction] {
        LibraryCommandPaletteAction.allCases.filter {
            $0.matches(librarySearchQuery)
        }
    }

    private var commandPaletteWebpageCandidateURL: URL? {
        normalizedWebpageURL(from: librarySearchQuery)
    }

    private func filterSearchResultsToCurrentLibrary(
        _ results: [LibraryTextSearchIndex.SearchResult]
    ) -> [LibraryTextSearchIndex.SearchResult] {
        let available = Set(markdownFiles.map(\.standardizedFileURL))
        return results
            .map { result in
                LibraryTextSearchIndex.SearchResult(
                    url: result.url.standardizedFileURL,
                    snippet: result.snippet
                )
            }
            .filter { available.contains($0.url) }
    }

    @MainActor
    private func syncSelectedLibrarySearchResult() {
        let resultURLs = filteredLibrarySearchResults.map(\.url)
        if let selectedLibrarySearchResult, resultURLs.contains(selectedLibrarySearchResult) {
            return
        }
        if let currentSelectedURL {
            let standardizedCurrentURL = currentSelectedURL.standardizedFileURL
            if resultURLs.contains(standardizedCurrentURL) {
                selectedLibrarySearchResult = standardizedCurrentURL
                return
            }
        }
        selectedLibrarySearchResult = resultURLs.first
    }

    @MainActor
    private func presentLibrarySearch() {
        isLibrarySearchPresented = true
        syncSelectedLibrarySearchResult()
    }

    @MainActor
    private func dismissLibrarySearch() {
        isLibrarySearchPresented = false
    }

    @MainActor
    private func previewLibrarySearchResult(_ url: URL) {
        dismissLibrarySearch()
        sidebarSelection = .library(url)
    }

    @MainActor
    private func runLibrarySearchAction(_ action: LibraryCommandPaletteAction) {
        dismissLibrarySearch()
        switch action {
        case .newLyrics:
            handleNewLyrics()
        case .openFile:
            chooseFile()
        case .refreshLibrary:
            refreshLibrary()
        }
    }

    @MainActor
    private func openWebpageFromCommandPalette(_ url: URL) {
        dismissLibrarySearch()
        previewWebpage(url)
    }

    private var playlistSidebarItems: [PlaylistSidebarItem] {
        playlistStore.entries.map { entry in
            let resolved = playlistStore.resolvedURL(for: entry)
            let title: String
            if let resolved {
                title = displayName(for: resolved)
            } else {
                title = URL(fileURLWithPath: entry.relativePath).lastPathComponent
            }
            return PlaylistSidebarItem(id: entry.id, title: title, exists: resolved != nil)
        }
    }

    private func rebuildDisplayNames(for urls: [URL]) {
        var names: [URL: String] = [:]
        for url in urls {
            names[url] = extractTitle(from: url)
        }
        fileDisplayNames.merge(names) { _, new in new }
    }

    private func extractTitle(from url: URL) -> String {
        let kind = FileKind(url: url)
        switch kind {
        case .pdf, .image, .video:
            return url.lastPathComponent
        default:
            break
        }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return url.lastPathComponent
        }
        let lines = contents
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        if let first = lines.first, !first.isEmpty {
            return first
        }

        return url.lastPathComponent
    }

    private func loadPlaylists() {
        playlistStore.load(fromRoot: libraryRootURL)
        selectedPlaylistEntryIDs = selectedPlaylistEntryIDs.intersection(Set(playlistStore.entries.map(\.id)))
        if let selectedPlaylistEntryID, selectedPlaylistEntryIDs.contains(selectedPlaylistEntryID) == false {
            self.selectedPlaylistEntryID = selectedPlaylistEntryIDs.first
        }
        rebuildDisplayNames(for: markdownFiles + playlistResolvedURLs)
    }

    private func addSelectedToPlaylist() {
        guard let source = selectedFileURL else {
            newFileWarning = "Select a file from the Library first."
            return
        }
        guard libraryRootURL != nil else {
            newFileWarning = "Set a library root before adding to playlists."
            return
        }

        if let newID = playlistStore.add(url: source, after: selectedPlaylistEntryID) {
            newFileWarning = nil
            loadPlaylists()
            selectedPlaylistEntryID = newID
            selectedPlaylistEntryIDs = [newID]
            return
        }

        newFileWarning = "Only files inside the library root can be added to Playlist."
    }

    private func removeSelectedFromPlaylist() {
        guard !selectedPlaylistEntryIDs.isEmpty else { return }
        playlistStore.remove(ids: selectedPlaylistEntryIDs)
        selectedPlaylistEntryID = nil
        selectedPlaylistEntryIDs = []
        loadPlaylists()
    }

    private func moveSelectedPlaylistEntriesUp() {
        guard !selectedPlaylistEntryIDs.isEmpty else { return }
        playlistStore.moveUp(ids: selectedPlaylistEntryIDs)
        loadPlaylists()
    }

    private func moveSelectedPlaylistEntriesDown() {
        guard !selectedPlaylistEntryIDs.isEmpty else { return }
        playlistStore.moveDown(ids: selectedPlaylistEntryIDs)
        loadPlaylists()
    }

    private func refreshLibrary() {
        if let root = libraryRootURL {
            loadLibraryFolders(from: root)
            ensurePlaylistDirectory(in: root)
        }
        if let folderURL {
            loadMarkdownFiles(from: folderURL)
            loadPlaylists()
            return
        }
        if let root = libraryRootURL {
            folderURL = root
            loadMarkdownFiles(from: root)
            loadPlaylists()
            return
        }
        loadPlaylists()
    }

    private func handleSelectedLibraryFolderChange(_ newValue: URL?) {
        if newValue == nil, let downloadsURL, folderURL == downloadsURL {
            return
        }
        if let newValue {
            folderURL = newValue
            loadMarkdownFiles(from: newValue)
        } else {
            folderURL = libraryRootURL
            if let root = libraryRootURL {
                loadMarkdownFiles(from: root)
            } else {
                markdownFiles = []
            }
        }
    }

    private func selectDownloadsFolder(_ downloadsURL: URL) {
        folderURL = downloadsURL
        selectedLibraryFolder = nil
        loadMarkdownFiles(from: downloadsURL)
    }

    private func toggleBackgroundAudioPlayback() {
        deferSessionChange {
            if session.isBackgroundAudioPlaying {
                session.pauseBackgroundAudio()
            } else {
                session.playBackgroundAudio()
            }
        }
    }

    private func stopBackgroundAudioPlayback() {
        deferSessionChange {
            session.stopBackgroundAudioPlayback()
        }
    }

    private func handleBackgroundAudioVolumeDraftChange(_ newValue: Double) {
        let token = UUID()
        backgroundAudioVolumeDebounceToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard backgroundAudioVolumeDebounceToken == token else { return }
            applyBackgroundAudioVolume(newValue)
        }
    }

    private func handleOverlayScaleDraftChange(_ newValue: Double) {
        let token = UUID()
        overlayScaleDebounceToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            guard overlayScaleDebounceToken == token else { return }
            overlayScale = newValue
        }
    }

    private func setOverlayMode(_ newMode: PresentationSession.OverlayMode) {
        deferSessionChange {
            session.setOverlayMode(newMode)
        }
    }

    private func startCountdown(_ minutes: Int) {
        deferSessionChange {
            session.startCountdown(minutes: minutes)
        }
    }

    private func stopCountdown() {
        deferSessionChange {
            session.stopCountdown()
        }
    }

    private func setClockVisible(_ isVisible: Bool) {
        deferSessionChange {
            session.setClockVisible(isVisible)
        }
    }

    private func handleSidebarSelection(_ selection: SidebarSelection?) {
        if ignoresNextSidebarSelectionChange {
            ignoresNextSidebarSelectionChange = false
            return
        }

        guard let selection else { return }
        switch selection {
        case .library(let url):
            if selectedFileURL == url, selectedPlaylistEntryID == nil {
                return
            }
            selectedFileURL = url
            selectedPlaylistEntryID = nil
            selectedPlaylistEntryIDs = []
            loadSelectedFile(url: url)
        case .playlist(let id):
            guard let url = playlistStore.resolvedURL(for: id) else { return }
            if selectedPlaylistEntryID == id, selectedFileURL == nil {
                return
            }
            selectedPlaylistEntryID = id
            if selectedPlaylistEntryIDs.isEmpty {
                selectedPlaylistEntryIDs = [id]
            }
            selectedFileURL = nil
            loadSelectedFile(url: url)
        case .web(let url):
            loadWebpagePreview(for: url)
        case .window(let windowID):
            loadWindowPreview(for: windowID)
        }
    }

    private var currentSelectedURL: URL? {
        if let selectedFileURL {
            return selectedFileURL
        }
        guard let id = selectedPlaylistEntryID else { return nil }
        return playlistStore.resolvedURL(for: id)
    }

    private func createNewFile() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { createNewFile() }
            return
        }
        guard !isCurrentSelectionMediaFile else { return }
        let baseDir = libraryRootURL ?? URL(fileURLWithPath: NSString(string: "~/Documents/eucaly").expandingTildeInPath)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        if rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newFileWarning = "Add some content before creating a new file."
            return
        }
        newFileWarning = nil

        let panel = NSSavePanel()
        panel.directoryURL = baseDir
        panel.nameFieldStringValue = suggestedFileName(from: rawLyrics)
        panel.allowedContentTypes = [UTType.plainText]

        if panel.runModal() == .OK, let url = panel.url {
            let requestedURL = enforcedTextURL(url)
            let fileURL: URL
            if let root = libraryRootURL, !isUnderLibraryRoot(requestedURL) {
                fileURL = root.appendingPathComponent(requestedURL.lastPathComponent)
                newFileWarning = "Save location adjusted to Library Root."
            } else {
                fileURL = requestedURL
            }
            do {
                let parentDir = fileURL.deletingLastPathComponent()
                let rootURL = libraryRootURL
                let didAccessRoot = rootURL?.startAccessingSecurityScopedResource() ?? false
                let didAccessParent = parentDir.startAccessingSecurityScopedResource()
                defer {
                    if didAccessParent { parentDir.stopAccessingSecurityScopedResource() }
                    if didAccessRoot { rootURL?.stopAccessingSecurityScopedResource() }
                }

                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
                let contents = rawLyrics
                try contents.write(to: fileURL, atomically: true, encoding: .utf8)
                lastLoadedText = contents
                folderURL = fileURL.deletingLastPathComponent()
                if let root = libraryRootURL {
                    libraryRootPath = root.path
                }
                if let folderURL {
                    loadMarkdownFiles(from: folderURL)
                }
                if let root = libraryRootURL {
                    loadLibraryFolders(from: root)
                }
                loadPlaylists()
                selectedFileURL = fileURL
                selectedPlaylistEntryID = nil
                selectedPlaylistEntryIDs = []
                let doc = LyricsParser.parseDocument(rawLyrics)
                setCurrentSlides(doc.slides)
            } catch {
                newFileWarning = "Could not save file: \(error.localizedDescription)"
            }
        }
    }

    private func enforcedTextURL(_ url: URL) -> URL {
        if url.pathExtension.lowercased() == "txt" {
            return url
        }
        return url.deletingPathExtension().appendingPathExtension("txt")
    }

    private func parseLyricsDocument(_ raw: String) -> LyricsDocument {
        LyricsParser.parseDocument(raw, fileName: "draft.txt")
    }

    private func suggestedFileName(from text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }

        if let titleLine = lines.first(where: { $0.lowercased().hasPrefix("#title:") }) {
            let title = titleLine.replacingOccurrences(of: "#title:", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return sanitizedFileName(title.isEmpty ? "Untitled" : title)
        }

        if let first = lines.first, !first.isEmpty {
            return sanitizedFileName(first)
        }

        return "Untitled"
    }

    private func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: " ")
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? "Untitled" : collapsed
    }

    private func formatAndSave() {
        guard !isCurrentSelectionMediaFile else { return }
        let formatted = formatLyricsMarkdown(rawLyrics)
        rawLyrics = formatted
        let doc = parseLyricsDocument(formatted)
        setPreviewSlides(doc.slides, preferredSelection: flow.previewSelectionID)
    }

    private func formatLyricsMarkdown(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let formattedLines = lines.map { formatLine($0) }
        var output: [String] = []
        var previousBlank = false
        var previousSeparator = false

        for line in formattedLines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "---" {
                if let last = output.last, !last.isEmpty && last != "---" {
                    output.append("")
                }
                output.append("---")
                previousSeparator = true
                previousBlank = false
                continue
            }

            if trimmed.isEmpty {
                if previousSeparator {
                    if output.last != "" {
                        output.append("")
                    }
                } else if !previousBlank {
                    output.append("")
                    previousBlank = true
                }
                continue
            }

            if previousSeparator {
                if output.last != "" {
                    output.append("")
                }
                previousSeparator = false
            }

            if isLyricsHeader(trimmed) {
                if let last = output.last, !last.isEmpty && last != "---" {
                    output.append("")
                }
            }

            previousBlank = false
            output.append(trimmed)
        }

        while output.first == "" { output.removeFirst() }
        while output.last == "" { output.removeLast() }
        return output.joined(separator: "\n")
    }

    private func formatLine(_ line: String) -> String {
        let trimmedTrailing = trimTrailingSpaces(line)
        let trimmed = trimmedTrailing.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }

        if isSeparatorLine(trimmed) {
            return "---"
        }

        return normalizeHeader(line: trimmed)
    }

    private func trimTrailingSpaces(_ line: String) -> String {
        var end = line.endIndex
        while end > line.startIndex {
            let prev = line.index(before: end)
            if line[prev].isWhitespace {
                end = prev
            } else {
                break
            }
        }
        return String(line[..<end])
    }

    private func isSeparatorLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "---" { return true }
        if trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 3 { return true }
        return false
    }

    private func isLyricsHeader(_ line: String) -> Bool {
        if LyricsSectionCatalog.isHeader(line) { return true }
        return canonicalCompanionHeader(line: line) != nil
    }

    private func normalizeHeader(line: String) -> String {
        if let canonical = LyricsSectionCatalog.canonicalHeaderLine(line) {
            return canonical
        }
        if let companion = canonicalCompanionHeader(line: line) {
            return companion
        }
        return line
    }

    private func canonicalCompanionHeader(line: String) -> String? {
        let normalized = line
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.caseInsensitiveCompare("Meaning") == .orderedSame {
            return "Meaning"
        }
        if normalized.caseInsensitiveCompare("Translation") == .orderedSame ||
            normalized.caseInsensitiveCompare("Transalation") == .orderedSame {
            return "Translation"
        }
        if normalized.caseInsensitiveCompare("Transliteration") == .orderedSame {
            return "Transliteration"
        }
        return nil
    }

    private func saveCurrentFile() {
        guard !isCurrentSelectionMediaFile, let url = currentSelectedURL else { return }
        do {
            try rawLyrics.write(to: url, atomically: true, encoding: .utf8)
            lastLoadedText = rawLyrics
            rebuildDisplayNames(for: markdownFiles + playlistResolvedURLs)
        } catch {
            // Silently ignore for now; could surface UI feedback later.
        }
    }

    private func pickWindowForPreview() {
        guard isWindowCaptureSupported else { return }
        screenCaptureManager.presentWindowPicker()
    }

    private func previewWebpage(_ url: URL) {
        newFileWarning = nil
        if !webpageURLs.contains(url) {
            webpageURLs.append(url)
        }
        selectedWebpageURL = url
        sidebarSelection = .web(url)
    }

    private func clearWebpageFromSidebar() {
        guard let selectedWebpageURL else {
            if case .web = sidebarSelection {
                sidebarSelection = nil
            }
            return
        }
        webpageURLs.removeAll { $0 == selectedWebpageURL }
        if flow.previewSlides.contains(where: { $0.webpageURL == selectedWebpageURL }) {
            flow.clearPreviewDocument()
        }
        if sidebarSelection == .web(selectedWebpageURL) {
            sidebarSelection = nil
        }
        self.selectedWebpageURL = nil
    }

    private func clearSelectedWindowFromSidebar() {
        guard case .window(let windowID) = sidebarSelection else { return }
        if flow.previewSlides.contains(where: { $0.captureWindowID == windowID }) {
            flow.clearPreviewDocument()
        }
        if session.slides.contains(where: { $0.captureWindowID == windowID }) {
            flow.clearCurrentDocument(in: session)
        }
        if #available(macOS 14.0, *), isWindowCaptureSupported {
            screenCaptureManager.clearWindow(windowID: windowID)
        }
        if case .window(let selectedID) = sidebarSelection, selectedID == windowID {
            sidebarSelection = nil
        }
    }

    private func loadWebpagePreview(for url: URL) {
        selectedFileURL = nil
        selectedPlaylistEntryID = nil
        selectedPlaylistEntryIDs = []
        if !webpageURLs.contains(url) {
            webpageURLs.append(url)
        }
        selectedWebpageURL = url
        applyPreviewMediaLoad(slides: buildWebpageSlides(from: url))
    }

    private func webpageTitle(for url: URL) -> String {
        let cachedTitle = webpageTitles[url]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cachedTitle.isEmpty {
            return cachedTitle
        }
        return url.host(percentEncoded: false) ?? url.absoluteString
    }

    private func updateWebpageTitle(_ title: String, for url: URL) {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = normalizedTitle.isEmpty
            ? (url.host(percentEncoded: false) ?? url.absoluteString)
            : normalizedTitle
        if webpageTitles[url] != resolvedTitle {
            webpageTitles[url] = resolvedTitle
        }
    }

    private func restoreWebpageState() {
        let restoredURLs = decodeWebpageURLs(from: savedWebpageURLs)
        let restoredTitles = decodeWebpageTitles(from: savedWebpageTitles, validURLs: Set(restoredURLs))
        let restoredSelectedURL = URL(string: savedSelectedWebpageURL).flatMap { url in
            restoredURLs.contains(url) ? url : nil
        }

        if webpageURLs != restoredURLs {
            webpageURLs = restoredURLs
        }
        if webpageTitles != restoredTitles {
            webpageTitles = restoredTitles
        }
        if selectedWebpageURL != restoredSelectedURL {
            selectedWebpageURL = restoredSelectedURL
        }
    }

    private func persistWebpageState() {
        let encoder = JSONEncoder()
        let sortedURLs = webpageURLs.map(\.absoluteString)
        if let data = try? encoder.encode(sortedURLs),
           let string = String(data: data, encoding: .utf8) {
            savedWebpageURLs = string
        } else {
            savedWebpageURLs = ""
        }

        savedSelectedWebpageURL = selectedWebpageURL?.absoluteString ?? ""

        let titleMap = webpageTitles.reduce(into: [String: String]()) { partialResult, entry in
            partialResult[entry.key.absoluteString] = entry.value
        }
        if let data = try? encoder.encode(titleMap),
           let string = String(data: data, encoding: .utf8) {
            savedWebpageTitles = string
        } else {
            savedWebpageTitles = ""
        }
    }

    private func decodeWebpageURLs(from rawValue: String) -> [URL] {
        guard let data = rawValue.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }

        var seen = Set<URL>()
        return strings.compactMap { value in
            guard let url = URL(string: value), isSupportedWebpageURL(url), seen.insert(url).inserted else {
                return nil
            }
            return url
        }
    }

    private func decodeWebpageTitles(from rawValue: String, validURLs: Set<URL>) -> [URL: String] {
        guard let data = rawValue.data(using: .utf8),
              let strings = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }

        return strings.reduce(into: [URL: String]()) { partialResult, entry in
            guard let url = URL(string: entry.key), validURLs.contains(url) else { return }
            partialResult[url] = entry.value
        }
    }

    private func updatePreviewWebpageURL(to newURL: URL, from previousURL: URL) {
        guard isSupportedWebpageURL(newURL) else { return }

        let sourceURL = previousURL
        if sourceURL == newURL {
            if !webpageURLs.contains(newURL) {
                webpageURLs.append(newURL)
            }
            selectedWebpageURL = newURL
            setPreviewSlides(buildWebpageSlides(from: newURL))
            return
        }

        if let existingIndex = webpageURLs.firstIndex(of: sourceURL) {
            webpageURLs[existingIndex] = newURL
        } else if !webpageURLs.contains(newURL) {
            webpageURLs.append(newURL)
        }

        var seenURLs = Set<URL>()
        webpageURLs = webpageURLs.filter { seenURLs.insert($0).inserted }

        if let existingTitle = webpageTitles[sourceURL], webpageTitles[newURL] == nil {
            webpageTitles[newURL] = existingTitle
        }
        webpageTitles.removeValue(forKey: sourceURL)

        selectedWebpageURL = newURL
        setPreviewSlides(buildWebpageSlides(from: newURL))

        if sidebarSelection == .web(sourceURL) {
            setSidebarSelectionWithoutLoading(.web(newURL))
        }
    }

    private func updateCurrentWebpageURL(to newURL: URL, from previousURL: URL) {
        guard isSupportedWebpageURL(newURL) else { return }

        let sourceURL = previousURL
        if sourceURL == newURL {
            if !webpageURLs.contains(newURL) {
                webpageURLs.append(newURL)
            }
            selectedWebpageURL = newURL
            setCurrentSlides(buildWebpageSlides(from: newURL))
            return
        }

        if let existingIndex = webpageURLs.firstIndex(of: sourceURL) {
            webpageURLs[existingIndex] = newURL
        } else if !webpageURLs.contains(newURL) {
            webpageURLs.append(newURL)
        }

        var seenURLs = Set<URL>()
        webpageURLs = webpageURLs.filter { seenURLs.insert($0).inserted }

        if let existingTitle = webpageTitles[sourceURL], webpageTitles[newURL] == nil {
            webpageTitles[newURL] = existingTitle
        }
        webpageTitles.removeValue(forKey: sourceURL)

        selectedWebpageURL = newURL
        setCurrentSlides(buildWebpageSlides(from: newURL))

        if sidebarSelection == .web(sourceURL) {
            setSidebarSelectionWithoutLoading(.web(newURL))
        }
    }

    private func setSidebarSelectionWithoutLoading(_ selection: SidebarSelection?) {
        ignoresNextSidebarSelectionChange = true
        sidebarSelection = selection
    }

    private func loadWindowPreview(for windowID: CGWindowID) {
        selectedFileURL = nil
        selectedPlaylistEntryID = nil
        selectedPlaylistEntryIDs = []

        guard isWindowCaptureSupported else {
            flow.clearPreviewDocument()
            return
        }
        guard let window = captureWindows.first(where: { $0.windowID == windowID }) else {
            flow.clearPreviewDocument()
            return
        }
        applyPreviewMediaLoad(slides: buildWindowSlides(from: window))
    }

    private func normalizedWebpageURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let direct = URL(string: trimmed), isSupportedWebpageURL(direct) {
            return direct
        }

        guard !trimmed.contains("://") else { return nil }
        let httpsCandidate = "https://\(trimmed)"
        guard let normalized = URL(string: httpsCandidate), isSupportedWebpageURL(normalized) else {
            return nil
        }
        return normalized
    }

    private func isSupportedWebpageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return false
        }
        return url.host(percentEncoded: false)?.isEmpty == false
    }
}

// MARK: - View Extensions for macOS Version Compatibility

extension View {
    /// Applies toolbar background visibility modifier on macOS 15.0+
    /// Falls back to no-op on macOS 14.x
    @ViewBuilder
    func applyToolbarBackgroundIfAvailable() -> some View {
        if #available(macOS 15.0, *) {
            self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            self
        }
    }
}
