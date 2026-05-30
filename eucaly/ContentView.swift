import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreGraphics
import Combine

public struct ContentView: View {
    @State private var rawLyrics: String = ""
    @StateObject private var session = PresentationSession()
    @StateObject private var flow = PresentationFlowController()
    @State private var folderURL: URL?
    @State private var markdownFiles: [URL] = []
    @State private var previewLibraryFiles: [URL] = []
    @State private var backgroundAudioLibraryFiles: [URL] = []
    @State private var selectedFileURL: URL?
    @State private var selectedPlaylistEntryID: UUID?
    @State private var selectedPlaylistEntryIDs: Set<UUID> = []
    @StateObject private var playlistStore = PlaylistStore()
    @AppStorage("libraryRootPath") private var libraryRootPath: String = ""
    @AppStorage("libraryRootBookmark") private var libraryRootBookmark: String = ""
    @AppStorage("backgroundVisualBookmark") private var backgroundVisualBookmark: String = ""
    @AppStorage("backgroundAudioBookmark") private var backgroundAudioBookmark: String = ""
    @AppStorage("backgroundAudioVolume") private var backgroundAudioVolume: Double = 1.0
    @AppStorage("backgroundAudioLoop") private var backgroundAudioLoop: Bool = true
    @AppStorage("thumbnailScale") private var thumbnailScale: Double = 1.0
    @AppStorage("presentationFontScale") private var presentationFontScale: Double = 1.0
    @AppStorage("presentationTextAlignment") private var presentationTextAlignment: PresentationTextAlignment = .center
    @AppStorage("presentationVerticalPosition") private var presentationVerticalPosition: PresentationVerticalPosition = .middle
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
    @State private var editingSourceURL: URL? = nil
    @State private var currentLyricsSourceURL: URL? = nil
    @State private var sidebarSelection: SidebarSelection? = nil
    @State private var ignoresNextSidebarSelectionChange: Bool = false
    @State private var previewLoadToken = UUID()
    @State private var previewSource: PreviewSource = .none
    @State private var isEditingLyrics: Bool = false
    @State private var librarySearch = LibrarySearchModel()
    @State private var libraryScrollRequest: LibraryScrollRequest?
    @State private var webpageURLs: [URL] = []
    @State private var webpageTitles: [URL: String] = [:]
    @State private var liveWebpageTitles: [URL: String] = [:]
    @State private var liveWebpageTitleOrder: [URL] = []
    @State private var selectedWebpageURL: URL? = nil
    // Preview mute is intentionally local; Current and projection share session.webpageMuted.
    @State private var previewWebpageMuted: Bool = false
    @State private var isLibrarySearchPresented: Bool = false
    @State private var libraryLoadTask: Task<Void, Never>? = nil
    @State private var isLibraryLoading: Bool = false
    @State private var libraryRevision: Int = 0
    @State private var projectionScreenOptions: [ProjectionScreenOption] = []
    @State private var isTimerSettingsPresented: Bool = false
    @State private var isAppearanceSettingsPresented: Bool = false
    @State private var isBackgroundSettingsPresented: Bool = false
    @FocusState private var isSidebarFocused: Bool
    @FocusState private var focusedDetailTarget: DetailFocusTarget?
    @State private var securityScopedRoot: URL? = nil
    @State private var securityScopedBackgroundVisual: URL? = nil
    @State private var securityScopedBackgroundAudio: URL? = nil
    @StateObject private var screenCaptureManager = ScreenCaptureManager.shared
    @StateObject private var appUpdateViewModel = AppUpdateViewModel()
    @State private var isPreviewCollapsed: Bool = false
    private let playlistDirectoryName = "Playlist"
    private let paneToggleAnimation = Animation.easeOut(duration: 0.12)
    private let loadAnimation = Animation.easeInOut(duration: 0.24)
    private let windowCaptureFrameRateOptions = [24, 30, 60]
    private let libraryFileScanner = LibraryFileScannerService()

    private struct ProjectionScreenOption: Identifiable, Hashable {
        let displayID: Int
        let label: String
        var id: Int { displayID }
    }

    private enum PreviewSource: Equatable {
        case none
        case file(URL)
        case web(URL)
        case window(CGWindowID)
        case lyrics
    }

    private enum ImportError: LocalizedError {
        case unsupportedFile(URL)

        var errorDescription: String? {
            switch self {
            case .unsupportedFile(let url):
                return "\(url.lastPathComponent) is not a supported library file."
            }
        }
    }

    private var isCurrentSelectionMediaFile: Bool {
        guard let url = currentSelectedURL else { return false }
        let kind = LibraryFileKind(url: url)
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
        rootSplitWithAppUpdateAlert
    }

    private var rootSplitWithAppUpdateAlert: some View {
        rootSplitWithLibrarySearchOverlay
            .alert(item: $appUpdateViewModel.checkAlert) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"))
                )
            }
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
                LibrarySearchOverlayContainerView(
                    model: librarySearch,
                    currentSelectedURL: currentSelectedURL,
                    displayName: { displayName(for: $0) },
                    onRunAction: runLibrarySearchAction,
                    onClose: dismissLibrarySearch,
                    onOpenResult: previewLibrarySearchResult,
                    onAddResultToPlaylist: addLibrarySearchResultToPlaylist,
                    onCommitQuery: commitLibrarySearchQuery
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
        .onChange(of: webpageURLs) { _, _ in
            persistWebpageState()
        }
        .onChange(of: selectedWebpageURL) { _, _ in
            persistWebpageState()
        }
        .onChange(of: webpageTitles) { _, _ in
            persistWebpageState()
        }
        .onChange(of: projectionScreenDisplayID) { _, _ in
            applyProjectionScreenPreference()
        }
        .onDisappear(perform: handleRootOnDisappear)
    }

    private func handleRootOnDisappear() {
        librarySearch.cancelDebounce()
        libraryLoadTask?.cancel()
        isLibraryLoading = false
        librarySearch.setIndexing(false)
        releaseSecurityScopedAccess()
        stopWindowCapturesForShutdown()
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
            .onReceive(NotificationCenter.default.publisher(for: .projectionScreenFellBackToAuto)) { _ in
                projectionScreenDisplayID = 0
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleSlidesVisibility), perform: handleToggleSlidesVisibilityNotification)
            .onReceive(NotificationCenter.default.publisher(for: .stopProjection), perform: handleStopProjectionNotification)
            .onReceive(NotificationCenter.default.publisher(for: .toggleBackgroundVisibility), perform: handleToggleBackgroundVisibilityNotification)
            .onReceive(NotificationCenter.default.publisher(for: .toggleBackgroundAudio), perform: handleToggleBackgroundAudioNotification)
            .onReceive(NotificationCenter.default.publisher(for: .clearAllLayers), perform: handleClearAllLayersNotification)
        .onReceive(NotificationCenter.default.publisher(for: .checkForUpdates)) { _ in
            appUpdateViewModel.checkForUpdates()
        }
        .onReceive(NotificationCenter.default.publisher(for: .clearBackgroundVisual), perform: handleClearBackgroundVisualNotification)
        .onReceive(NotificationCenter.default.publisher(for: .clearBackgroundAudio), perform: handleClearBackgroundAudioNotification)
        .onReceive(NotificationCenter.default.publisher(for: .newLyrics), perform: handleNewLyricsNotification)
        .onReceive(NotificationCenter.default.publisher(for: .saveLyrics), perform: handleSaveLyricsNotification)
        .onReceive(NotificationCenter.default.publisher(for: .showLibrarySearch)) { _ in
            presentLibrarySearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshLibrary)) { _ in
            refreshLibrary()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification), perform: handleMainWindowWillCloseNotification)
    }

    @ViewBuilder
    private var sidebarPane: some View {
        SidebarView(
            session: session,
            isWindowCaptureSupported: isWindowCaptureSupported,
            libraryFiles: previewLibraryFiles,
            audioFiles: backgroundAudioLibraryFiles,
            isLibraryLoading: isLibraryLoading,
            libraryRevision: libraryRevision,
            playlistItems: playlistSidebarItems,
            libraryRootURL: libraryRootURL,
            captureWindows: captureWindows,
            webpageURLs: webpageURLs,
            libraryScrollRequest: libraryScrollRequest,
            selectedPlaylistEntryID: $selectedPlaylistEntryID,
            selectedPlaylistEntryIDs: $selectedPlaylistEntryIDs,
            sidebarSelection: $sidebarSelection,
            backgroundAudioLoop: $backgroundAudioLoop,
            backgroundAudioVolumeDraft: $backgroundAudioVolumeDraft,
            windowCaptureFrameRate: $windowCaptureFrameRate,
            isSidebarFocused: $isSidebarFocused,
            displayName: { displayName(for: $0) },
            titleForWebpage: webpageTitle(for:),
            onImportToLibrary: importFilesToLibrary,
            onImportToAudio: importAudioToLibrary,
            onAddLibraryItemToPlaylist: addLibraryItemToPlaylist,
            onRemovePlaylistItem: removePlaylistItem,
            onRemoveSelectedFromPlaylist: removeSelectedFromPlaylist,
            onMovePlaylistUp: moveSelectedPlaylistEntriesUp,
            onMovePlaylistDown: moveSelectedPlaylistEntriesDown,
            onSelectBackgroundAudio: selectBackgroundAudio,
            onPlayPauseBackgroundAudio: toggleBackgroundAudioPlayback,
            onStopBackgroundAudio: stopBackgroundAudioPlayback,
            onClearBackgroundAudio: clearBackgroundAudio,
            onApplyBackgroundAudioVolume: handleBackgroundAudioVolumeDraftChange,
            onSeekBackgroundAudio: seekBackgroundAudio,
            onSelectionChange: handleSidebarSelection,
            onOpenWebpageAddress: openWebpageFromSidebar,
            onRemoveWebpage: removeWebpage,
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

                Button {
                    presentLibrarySearch()
                } label: {
                    Label("Command Palette", systemImage: "magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .help("Open the command palette")

                projectionScreenPicker
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            AppUpdateToolbarButton(viewModel: appUpdateViewModel)
            backgroundSettingsButton
            timerSettingsButton
            appearanceSettingsButton
        }
    }

    private var backgroundSettingsButton: some View {
        Button {
            isBackgroundSettingsPresented.toggle()
        } label: {
            Label("Background", systemImage: "photo.on.rectangle")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .help("Background settings")
        .popover(isPresented: $isBackgroundSettingsPresented, arrowEdge: .top) {
            BackgroundSettingsPopoverView(
                session: session,
                visualName: session.backgroundVisualURL.map { displayName(for: $0) },
                isMediaCurrent: isCurrentSelectionMediaFile,
                onChooseVisual: chooseBackgroundVisual,
                onClearVisual: clearBackgroundVisual,
                onToggleVisibility: toggleBackgroundVisualFromUI
            )
        }
    }

    private var timerSettingsButton: some View {
        Button {
            isTimerSettingsPresented.toggle()
        } label: {
            Label("Overlay", systemImage: "clock")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .help("Overlay settings")
        .popover(isPresented: $isTimerSettingsPresented, arrowEdge: .top) {
            TimerSettingsPopoverView(
                session: session,
                overlayScaleDraft: $overlayScaleDraft,
                countdownMinutes: $countdownMinutes,
                onOverlayScaleDraftChange: handleOverlayScaleDraftChange,
                onSetOverlayMode: setOverlayMode,
                onStartCountdown: startCountdown,
                onStopCountdown: stopCountdown
            )
        }
    }

    private var appearanceSettingsButton: some View {
        Button {
            isAppearanceSettingsPresented.toggle()
        } label: {
            Label("Appearance", systemImage: "gearshape")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
        .help("Appearance settings")
        .popover(isPresented: $isAppearanceSettingsPresented, arrowEdge: .top) {
            AppearanceSettingsPopoverView(
                presentationFontScale: $presentationFontScale,
                presentationTextAlignment: $presentationTextAlignment,
                presentationVerticalPosition: $presentationVerticalPosition,
                thumbnailFontScale: $thumbnailFontScale,
                thumbnailScale: $thumbnailScale
            )
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
        refreshBackgroundVisualAccess()
        refreshBackgroundAudioAccess()
        restoreWebpageState()
        loadPlaylists()
        appUpdateViewModel.checkForUpdatesIfNeeded()
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
                clearPreviewDocument()
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
            if editorSourceURL == nil {
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
        beginPreviewTransition(to: .lyrics)
        editingSourceURL = nil
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

    private var sidebarSelectedWebpageURL: URL? {
        if case .web(let url) = sidebarSelection {
            return url
        }
        return nil
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
                flow: flow,
                isCollapsed: $isPreviewCollapsed,
                isWebpageMuted: $previewWebpageMuted,
                canEditSelection: canEditSelection,
                thumbnailScale: thumbnailScale,
                paneToggleAnimation: paneToggleAnimation,
                loadAnimation: loadAnimation,
                titleForWebpage: webpageTitle(for:),
                savedWebpageEntryURL: sidebarSelectedWebpageURL,
                onWebpageNavigationChange: updatePreviewWebpageURL(to:from:),
                onWebpageTitleChange: updateWebpageTitle(_:for:),
                onEdit: beginLyricsEditing,
                onLoadToCurrent: handleLoadPreviewToCurrent
            ),
            currentPane: CurrentPaneContainerView(
                session: session,
                playbackProgress: session.playbackProgress,
                flow: flow,
                thumbnailScale: thumbnailScale,
                paneToggleAnimation: paneToggleAnimation,
                loadAnimation: loadAnimation,
                titleForWebpage: webpageTitle(for:),
                savedWebpageEntryURL: sidebarSelectedWebpageURL,
                onWebpageNavigationChange: updateCurrentWebpageURL(to:from:),
                onWebpageTitleChange: updateWebpageTitle(_:for:),
                canEditCurrentLyrics: canEditCurrentLyrics,
                onEditCurrentLyrics: beginCurrentLyricsEditing,
                onClearCurrent: clearCurrentDocument,
                focusedDetailTarget: $focusedDetailTarget
            ),
            showEditorAndPreview: isEditingLyrics && !isCurrentSelectionMediaFile && !isPreviewCollapsed
        )
    }

    private var saveButtonTitle: String {
        editorSourceURL == nil ? "Save As..." : "Save"
    }

    private var canSaveEditorContent: Bool {
        let trimmed = rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        if editorSourceURL != nil && rawLyrics == lastLoadedText { return false }
        return true
    }

    private func handleEditorAction(_ action: EditorPaneAction) {
        switch action {
        case .close:
            editingSourceURL = nil
            isEditingLyrics = false
        case .save:
            if editorSourceURL == nil {
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

    private func commitCurrentSlides(
        _ slides: [Slide],
        lyricsSourceURL: URL? = nil,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        currentLyricsSourceURL = lyricsSourceURL
        flow.setCurrentSlides(
            slides,
            in: session,
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    private func commitCurrentPDFSource(
        _ source: PDFSlideSource,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        currentLyricsSourceURL = nil
        flow.setCurrentPDFSource(
            source,
            in: session,
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    private func clearPreviewDocument() {
        let clearedWindowFromPreview = flow.previewSlides.contains { $0.captureWindowID != nil }
        previewLoadToken = UUID()
        previewSource = .none
        flow.clearPreviewDocument()
        if clearedWindowFromPreview {
            releaseWindowCaptureSelectionIfUnused()
        }
    }

    private func clearCurrentDocument() {
        let clearedWindowFromCurrent = session.slides.contains { $0.captureWindowID != nil }
        flow.clearCurrentDocument(in: session)
        currentLyricsSourceURL = nil
        flow.isCurrentCollapsed = true
        if clearedWindowFromCurrent, case .window = sidebarSelection {
            sidebarSelection = nil
        }
        if clearedWindowFromCurrent {
            releaseWindowCaptureSelectionIfUnused()
        }
    }

    private func releaseWindowCaptureSelectionIfUnused() {
        guard isWindowCaptureSupported else { return }
        let previewHasWindow = flow.previewSlides.contains { $0.captureWindowID != nil }
        let currentHasWindow = session.slides.contains { $0.captureWindowID != nil }
        guard !previewHasWindow && !currentHasWindow else { return }
        Task { @MainActor in
            await screenCaptureManager.clearWindowSelectionAndDeactivatePicker()
        }
    }

    private func selectCurrentSlide(_ slideID: Slide.ID) {
        flow.selectCurrentSlide(slideID, in: session)
    }

    private func handleLoadPreviewToCurrent() {
        guard !flow.previewIsEmpty else { return }
        if let pdfSource = flow.previewPDFSource {
            commitCurrentPDFSource(
                pdfSource,
                preferredSelection: flow.previewSelectionID
            )
        } else {
            commitCurrentSlides(
                flow.previewSlides,
                lyricsSourceURL: previewLyricsSourceURL(),
                preferredSelection: flow.previewSelectionID
            )
        }
        clearPreviewDocument()
        flow.isCurrentCollapsed = false
        isPreviewCollapsed = true
        focusedDetailTarget = session.slides.contains { $0.webpageURL != nil }
            ? nil
            : .currentThumbnails
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
        let displayID = projectionScreenDisplayID == 0
            ? nil
            : CGDirectDisplayID(projectionScreenDisplayID)
        return ProjectionScreenResolver.resolve(displayID: displayID)
    }

    private func refreshProjectionScreenOptions() {
        let activeScreens = ProjectionScreenResolver.activeScreens()
            .map { screen in
                (
                    name: screen.localizedName,
                    displayID: screen.displayID,
                    width: Int(screen.frame.width.rounded()),
                    height: Int(screen.frame.height.rounded())
                )
            }

        let countsByName = Dictionary(grouping: activeScreens, by: \.name)
            .mapValues(\.count)

        projectionScreenOptions = activeScreens.compactMap { screen in
            guard let displayID = screen.displayID, displayID != 0 else { return nil }
            let displayIDValue = Int(displayID)
            let hasDuplicateName = (countsByName[screen.name] ?? 0) > 1
            let label: String
            if hasDuplicateName {
                label = "\(screen.name) • \(screen.width)x\(screen.height) • #\(displayIDValue)"
            } else {
                label = "\(screen.name) • \(screen.width)x\(screen.height)"
            }
            return ProjectionScreenOption(displayID: displayIDValue, label: label)
        }

        if projectionScreenDisplayID != 0,
           !projectionScreenOptions.contains(where: { $0.displayID == projectionScreenDisplayID }) {
            projectionScreenDisplayID = 0
        }

        applyProjectionScreenPreference()
    }

    private func applyProjectionScreenPreference() {
        guard session.isPresenting else { return }
        session.setPreferredPresentationScreen(preferredProjectionScreen())
    }

    private func stopWindowCapturesForShutdown() {
        Task { @MainActor in
            await ScreenCaptureManager.shared.stopAllCaptures()
        }
    }

    private var canEditSelection: Bool {
        guard !isCurrentSelectionMediaFile, let url = currentSelectedURL else { return false }
        return isLyricsFile(url)
    }

    private var canEditCurrentLyrics: Bool {
        guard !session.slides.isEmpty, let currentLyricsSourceURL else { return false }
        return isLyricsFile(currentLyricsSourceURL)
    }

    private var canToggleSlides: Bool {
        session.isPresenting || !session.isEmpty || session.hasAvailableBackgroundVisual
    }

    private func buildPDFSlides(pageCount: Int, url: URL) -> [Slide] {
        PDFSlideCatalog.slides(url: url, pageCount: pageCount)
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

    private func isLyricsFile(_ url: URL) -> Bool {
        LibraryFileKind(url: url).isEditableLyrics
    }

    private func importFilesToLibrary() {
        guard let root = libraryRootURL else {
            newFileWarning = "Set a library root before importing files."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = previewLibraryContentTypes()
        panel.directoryURL = defaultImportDirectory()
        panel.prompt = "Import"

        guard panel.runModal() == .OK else { return }

        let didAccessRoot = root.startAccessingSecurityScopedResource()
        defer {
            if didAccessRoot {
                root.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let importedURLs = try panel.urls.map { try importFile($0, into: root) }
            guard !importedURLs.isEmpty else { return }

            newFileWarning = nil
            folderURL = root
            loadMarkdownFiles(
                from: root,
                refreshLibrarySearchScope: true,
                refreshSearchResults: true
            )
            loadPlaylists()
            if let firstPreviewURL = importedURLs.first(where: { LibraryFileKind(url: $0).isPreviewLibraryItem }) {
                selectedFileURL = firstPreviewURL
                selectedPlaylistEntryID = nil
                selectedPlaylistEntryIDs = []
                sidebarSelection = .library(firstPreviewURL)
                libraryScrollRequest = LibraryScrollRequest(url: firstPreviewURL)
                loadSelectedFile(url: firstPreviewURL)
            }
        } catch {
            newFileWarning = "Could not import file: \(error.localizedDescription)"
        }
    }

    private func importAudioToLibrary() {
        guard let root = libraryRootURL else {
            newFileWarning = "Set a library root before importing files."
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = backgroundAudioSourceContentTypes()
        panel.directoryURL = defaultImportDirectory()
        panel.prompt = "Import"
        panel.message = "Choose audio or video files to use as background audio."

        guard panel.runModal() == .OK else { return }

        let didAccessRoot = root.startAccessingSecurityScopedResource()
        defer {
            if didAccessRoot {
                root.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let importedURLs = try panel.urls.map { try importFile($0, into: root) }
            guard let firstAudioURL = importedURLs.first(where: { LibraryFileKind(url: $0).isBackgroundAudioSource }) else {
                return
            }

            newFileWarning = nil
            folderURL = root
            loadMarkdownFiles(
                from: root,
                refreshLibrarySearchScope: true,
                refreshSearchResults: true
            )
            loadPlaylists()
            selectedFileURL = nil
            selectedPlaylistEntryID = nil
            selectedPlaylistEntryIDs = []
            sidebarSelection = nil
            selectBackgroundAudio(firstAudioURL)
        } catch {
            newFileWarning = "Could not import audio: \(error.localizedDescription)"
        }
    }

    private func previewLibraryContentTypes() -> [UTType] {
        [
            "txt",
            "pdf",
            "jpg",
            "jpeg",
            "png",
            "gif",
            "webp",
            "bmp",
            "tiff",
            "mp4",
            "mov",
            "m4v",
            "avi",
            "mkv"
        ].compactMap { UTType(filenameExtension: $0) }
    }

    private func backgroundAudioSourceContentTypes() -> [UTType] {
        [
            "mp4",
            "mov",
            "m4v",
            "avi",
            "mkv",
            "mp3",
            "m4a",
            "wav",
            "aiff",
            "aif",
            "flac",
            "aac"
        ].compactMap { UTType(filenameExtension: $0) }
    }

    private func defaultImportDirectory() -> URL? {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    private func importFile(_ sourceURL: URL, into root: URL) throws -> URL {
        let kind = LibraryFileKind(url: sourceURL)
        guard kind.isSupportedLibraryItem else {
            throw ImportError.unsupportedFile(sourceURL)
        }

        if isUnderLibraryRoot(sourceURL) {
            return sourceURL
        }

        let destinationFolder = root.appendingPathComponent(
            importFolderName(for: kind),
            isDirectory: true
        )
        let didAccessSource = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSource {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        try FileManager.default.createDirectory(
            at: destinationFolder,
            withIntermediateDirectories: true
        )
        let destinationURL = availableImportDestination(
            for: sourceURL.lastPathComponent,
            in: destinationFolder
        )
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    private func importFolderName(for kind: LibraryFileKind) -> String {
        switch kind {
        case .txt:
            "Lyrics"
        case .pdf:
            "PDFs"
        case .image:
            "Images"
        case .video:
            "Videos"
        case .audio:
            "Audio"
        case .unsupported:
            "Other"
        }
    }

    private func availableImportDestination(for fileName: String, in folder: URL) -> URL {
        let fileManager = FileManager.default
        let baseURL = folder.appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: baseURL.path) else {
            return baseURL
        }

        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var index = 2
        while true {
            let candidateName = ext.isEmpty
                ? "\(name) \(index)"
                : "\(name) \(index).\(ext)"
            let candidateURL = folder.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            index += 1
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

    private func isUnderLibraryRoot(_ url: URL) -> Bool {
        guard let root = libraryRootURL else { return true }
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        return filePath == rootPath || filePath.hasPrefix(rootPath + "/")
    }

    private func loadMarkdownFiles(
        from folder: URL,
        refreshLibrarySearchScope: Bool = false,
        refreshSearchResults: Bool = false
    ) {
        let previousSearchScopeFiles = librarySearch.scopeFilesSnapshot
        let scanner = libraryFileScanner
        let index = librarySearch.index

        libraryLoadTask?.cancel()
        isLibraryLoading = true
        librarySearch.setIndexing(true)
        libraryLoadTask = Task.detached(priority: .userInitiated) {
            let cachedMetadata = await index.cachedLibraryMetadata(root: folder)
            if !cachedMetadata.isEmpty {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    applyLibraryMetadata(
                        cachedMetadata,
                        displayedFolder: folder,
                        refreshLibrarySearchScope: refreshLibrarySearchScope
                    )
                }
            }
            guard !Task.isCancelled else { return }

            let discoveredFiles = scanner.discoverFiles(in: folder)
            guard !Task.isCancelled else { return }

            let metadata = await index.syncLibraryMetadata(
                root: folder,
                discoveredFiles: discoveredFiles
            )
            guard !Task.isCancelled else { return }

            let currentQuery = await MainActor.run {
                librarySearch.trimmedQuery
            }

            let refreshedResults: [LibraryTextSearchIndex.SearchResult]
            if currentQuery.count >= LibrarySearchModel.minimumCharacterCount {
                refreshedResults = await index.search(query: currentQuery)
            } else {
                refreshedResults = []
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                let searchScopeFiles = applyLibraryMetadata(
                    metadata,
                    displayedFolder: folder,
                    refreshLibrarySearchScope: refreshLibrarySearchScope
                )
                isLibraryLoading = false
                librarySearch.setIndexing(false)

                if refreshSearchResults || !haveSameStandardizedURLs(previousSearchScopeFiles, searchScopeFiles) {
                    librarySearch.applySearchResults(
                        refreshedResults,
                        query: currentQuery,
                        currentSelectedURL: currentSelectedURL,
                        preferFirstResult: true
                    )
                }
            }
        }
    }

    @discardableResult
    private func applyLibraryMetadata(
        _ metadata: [LibraryTextSearchIndex.FileMetadata],
        displayedFolder: URL,
        refreshLibrarySearchScope: Bool
    ) -> [URL] {
        let files = metadata.map(\.url)
        let previewFiles = metadata
            .filter { $0.kind.isPreviewLibraryItem }
            .map(\.url)
        let backgroundAudioFiles = metadata
            .filter { $0.kind.isBackgroundAudioSource }
            .map(\.url)
        let displayNames = Dictionary(
            uniqueKeysWithValues: metadata.map { ($0.url, $0.title) }
        )
        let searchScopeFiles = resolveLibrarySearchScopeFiles(
            displayedFolder: displayedFolder,
            displayedFiles: previewFiles,
            refreshLibrarySearchScope: refreshLibrarySearchScope
        )

        markdownFiles = files
        previewLibraryFiles = previewFiles
        backgroundAudioLibraryFiles = backgroundAudioFiles
        librarySearch.setScopeFiles(searchScopeFiles)
        fileDisplayNames.merge(displayNames) { _, new in new }
        libraryRevision &+= 1
        return searchScopeFiles
    }

    private func resolveLibrarySearchScopeFiles(
        displayedFolder: URL,
        displayedFiles: [URL],
        refreshLibrarySearchScope: Bool
    ) -> [URL] {
        displayedFiles
    }

    private func haveSameStandardizedURLs(_ lhs: [URL], _ rhs: [URL]) -> Bool {
        lhs.map(\.standardizedFileURL) == rhs.map(\.standardizedFileURL)
    }

    private func loadSelectedFile() {
        guard let url = currentSelectedURL else { return }
        loadSelectedFile(url: url)
    }

    private func loadSelectedFile(url: URL) {
        let source = PreviewSource.file(url)
        let token = beginPreviewTransition(to: source)
        let kind = LibraryFileKind(url: url)
        DispatchQueue.global(qos: .userInitiated).async {
            switch kind {
            case .pdf:
                guard let pageCount = PDFSlideCatalog.pageCount(for: url) else { return }
                if PDFSlideCatalog.shouldUseVirtualCatalog(pageCount: pageCount) {
                    let pdfSource = PDFSlideSource(url: url, pageCount: pageCount)
                    DispatchQueue.main.async {
                        guard previewTransitionIsCurrent(token: token, source: source) else { return }
                        applyPreviewPDFLoad(source: pdfSource)
                    }
                } else {
                    let slides = buildPDFSlides(pageCount: pageCount, url: url)
                    DispatchQueue.main.async {
                        guard previewTransitionIsCurrent(token: token, source: source) else { return }
                        applyPreviewMediaLoad(slides: slides)
                    }
                }
            case .image:
                let slides = buildImageSlides(from: url)
                DispatchQueue.main.async {
                    guard previewTransitionIsCurrent(token: token, source: source) else { return }
                    applyPreviewMediaLoad(slides: slides)
                }
            case .video:
                let slides = buildVideoSlides(from: url)
                DispatchQueue.main.async {
                    guard previewTransitionIsCurrent(token: token, source: source) else { return }
                    applyPreviewMediaLoad(slides: slides)
                }
            case .audio:
                return
            case .txt:
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return }
                let doc = LyricsParser.parseDocument(contents, fileName: url.lastPathComponent)
                DispatchQueue.main.async {
                    guard previewTransitionIsCurrent(token: token, source: source) else { return }
                    applyPreviewLyricsLoad(contents: contents, slides: doc.slides)
                }
            case .unsupported:
                return
            }
        }
    }

    private func applyPreviewMediaLoad(slides: [Slide]) {
        isEditingLyrics = false
        editingSourceURL = nil
        rawLyrics = ""
        lastLoadedText = ""
        setPreviewSlides(slides)
    }

    private func applyPreviewPDFLoad(source: PDFSlideSource) {
        isEditingLyrics = false
        editingSourceURL = nil
        rawLyrics = ""
        lastLoadedText = ""
        setPreviewPDFSource(source)
    }

    private func applyPreviewLyricsLoad(contents: String, slides: [Slide]) {
        isEditingLyrics = false
        editingSourceURL = nil
        rawLyrics = contents
        lastLoadedText = contents
        setPreviewSlides(slides)
        // Keep Current independent from browsing.
        // User must explicitly load Preview into Current.
    }

    private func setPreviewSlides(_ slides: [Slide], preferredSelection: Slide.ID? = nil) {
        setPreviewSlides(slides, preferredSelection: preferredSelection, preferredSelectionIndex: nil)
    }

    private func setPreviewSlides(
        _ slides: [Slide],
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int?
    ) {
        if !slides.isEmpty {
            isPreviewCollapsed = false
        }
        let preservedCurrentSlides = session.slides
        let preservedPDFSource = session.pdfSlideSource
        let preservedCurrentSlideID = session.currentSlideID
        let preservedCurrentSlideIndex = preservedCurrentSlideID.flatMap { slideID in
            session.slideIndex(for: slideID)
        }

        flow.setPreviewSlides(
            slides,
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )

        restoreCurrentDocumentIfNeeded(
            slides: preservedCurrentSlides,
            pdfSource: preservedPDFSource,
            currentSlideID: preservedCurrentSlideID,
            currentSlideIndex: preservedCurrentSlideIndex
        )
    }

    private func setPreviewPDFSource(
        _ source: PDFSlideSource,
        preferredSelectionIndex: Int? = nil
    ) {
        isPreviewCollapsed = false
        let preservedCurrentSlides = session.slides
        let preservedPDFSource = session.pdfSlideSource
        let preservedCurrentSlideID = session.currentSlideID
        let preservedCurrentSlideIndex = preservedCurrentSlideID.flatMap { slideID in
            session.slideIndex(for: slideID)
        }

        flow.setPreviewPDFSource(source, preferredSelectionIndex: preferredSelectionIndex)

        restoreCurrentDocumentIfNeeded(
            slides: preservedCurrentSlides,
            pdfSource: preservedPDFSource,
            currentSlideID: preservedCurrentSlideID,
            currentSlideIndex: preservedCurrentSlideIndex
        )
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
            updateLibraryRootAccess(result.url)
        } else {
            updateLibraryRootAccess(nil)
        }

        if let root = libraryRootURL {
            configureLibraryRoot(root)
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
        let didChangeAccess = securityScopedBackgroundVisual != url
        if didChangeAccess {
            securityScopedBackgroundVisual?.stopAccessingSecurityScopedResource()
        }
        securityScopedBackgroundVisual = url
        if didChangeAccess, let url {
            _ = url.startAccessingSecurityScopedResource()
        }
        deferSessionChange {
            session.setBackgroundVisual(url)
        }
    }

    private func updateLibraryRootAccess(_ url: URL?) {
        guard securityScopedRoot != url else { return }
        securityScopedRoot?.stopAccessingSecurityScopedResource()
        securityScopedRoot = url
        if let url {
            _ = url.startAccessingSecurityScopedResource()
        }
    }

    private func releaseSecurityScopedAccess() {
        securityScopedRoot?.stopAccessingSecurityScopedResource()
        securityScopedRoot = nil
        securityScopedBackgroundVisual?.stopAccessingSecurityScopedResource()
        securityScopedBackgroundVisual = nil
        securityScopedBackgroundAudio?.stopAccessingSecurityScopedResource()
        securityScopedBackgroundAudio = nil
    }

    private func updateBackgroundAudioSelection(_ url: URL?, autoplay: Bool) {
        let didChangeAccess = securityScopedBackgroundAudio != url
        if didChangeAccess {
            securityScopedBackgroundAudio?.stopAccessingSecurityScopedResource()
        }
        securityScopedBackgroundAudio = url
        if didChangeAccess, let url {
            _ = url.startAccessingSecurityScopedResource()
        }
        deferSessionChange {
            session.setBackgroundAudioLoop(backgroundAudioLoop)
            session.setBackgroundAudioVolume(backgroundAudioVolume)
            session.setBackgroundAudio(url: url, autoplay: autoplay)
        }
    }

    private func selectBackgroundAudio(_ url: URL) {
        if let bookmark = SecurityScopedBookmarks.createBookmark(for: url) {
            backgroundAudioBookmark = bookmark
        }
        updateBackgroundAudioSelection(url, autoplay: true)
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
        loadMarkdownFiles(
            from: root,
            refreshLibrarySearchScope: true,
            refreshSearchResults: true
        )
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

    private var playlistResolvedURLs: [URL] {
        playlistStore.entries.compactMap { playlistStore.resolvedURL(for: $0) }
    }

    @MainActor
    private func presentLibrarySearch() {
        isLibrarySearchPresented = true
        librarySearch.syncSelectedResult(
            currentSelectedURL: currentSelectedURL,
            preferFirstResult: true
        )
    }

    @MainActor
    private func dismissLibrarySearch() {
        isLibrarySearchPresented = false
    }

    @MainActor
    private func previewLibrarySearchResult(_ url: URL) {
        dismissLibrarySearch()

        if let root = libraryRootURL, folderURL?.standardizedFileURL != root.standardizedFileURL {
            folderURL = root
            loadMarkdownFiles(from: root)
        }

        sidebarSelection = .library(url)
        libraryScrollRequest = LibraryScrollRequest(url: url)
    }

    @MainActor
    private func addLibrarySearchResultToPlaylist(_ url: URL) {
        guard libraryRootURL != nil else {
            newFileWarning = "Set a library root before adding to playlists."
            return
        }

        if playlistStore.add(url: url, after: selectedPlaylistEntryID) != nil {
            newFileWarning = nil
            loadPlaylists()
            return
        }

        newFileWarning = "Only files inside the library root can be added to Playlist."
    }

    @MainActor
    private func commitLibrarySearchQuery() {
        Task {
            let url = await librarySearch.searchImmediately(currentSelectedURL: currentSelectedURL)
            guard isLibrarySearchPresented, let url else {
                return
            }
            previewLibrarySearchResult(url)
        }
    }

    @MainActor
    private func runLibrarySearchAction(_ action: LibraryCommandPaletteAction) {
        dismissLibrarySearch()
        switch action {
        case .newLyrics:
            handleNewLyrics()
        case .refreshLibrary:
            refreshLibrary()
        }
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
        let names = libraryFileScanner.displayNames(for: urls)
        fileDisplayNames.merge(names) { _, new in new }
    }

    private func loadPlaylists() {
        playlistStore.load(fromRoot: libraryRootURL)
        selectedPlaylistEntryIDs = selectedPlaylistEntryIDs.intersection(Set(playlistStore.entries.map(\.id)))
        if let selectedPlaylistEntryID, selectedPlaylistEntryIDs.contains(selectedPlaylistEntryID) == false {
            self.selectedPlaylistEntryID = selectedPlaylistEntryIDs.first
        }
        rebuildDisplayNames(for: playlistResolvedURLs)
    }

    private func addLibraryItemToPlaylist(_ source: URL) {
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

    private func removePlaylistItem(_ id: UUID) {
        playlistStore.remove(ids: [id])
        selectedPlaylistEntryIDs.remove(id)
        if selectedPlaylistEntryID == id {
            selectedPlaylistEntryID = playlistStore.entries.first {
                selectedPlaylistEntryIDs.contains($0.id)
            }?.id
        }
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
            ensurePlaylistDirectory(in: root)
            folderURL = root
            loadMarkdownFiles(
                from: root,
                refreshLibrarySearchScope: true,
                refreshSearchResults: true
            )
            loadPlaylists()
            return
        }
        isLibraryLoading = false
        loadPlaylists()
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

    private func seekBackgroundAudio(to time: Double) {
        deferSessionChange {
            session.seekBackgroundAudio(to: time)
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

    private func handleSidebarSelection(_ selection: SidebarSelection?) {
        if ignoresNextSidebarSelectionChange {
            ignoresNextSidebarSelectionChange = false
            return
        }

        guard let selection else { return }
        switch selection {
        case .library(let url):
            if selectedFileURL == url, selectedPlaylistEntryID == nil {
                if flow.previewIsEmpty {
                    loadSelectedFile(url: url)
                }
                return
            }
            selectedFileURL = url
            selectedPlaylistEntryID = nil
            selectedPlaylistEntryIDs = []
            loadSelectedFile(url: url)
        case .playlist(let id):
            guard let url = playlistStore.resolvedURL(for: id) else { return }
            if selectedPlaylistEntryID == id, selectedFileURL == nil {
                if flow.previewIsEmpty {
                    loadSelectedFile(url: url)
                }
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
                if let root = libraryRootURL {
                    libraryRootPath = root.path
                    folderURL = root
                    loadMarkdownFiles(
                        from: root,
                        refreshLibrarySearchScope: true,
                        refreshSearchResults: true
                    )
                }
                loadPlaylists()
                selectedFileURL = fileURL
                selectedPlaylistEntryID = nil
                selectedPlaylistEntryIDs = []
                editingSourceURL = fileURL
                sidebarSelection = .library(fileURL)
                libraryScrollRequest = LibraryScrollRequest(url: fileURL)
                let doc = LyricsParser.parseDocument(rawLyrics)
                beginPreviewTransition(to: .file(fileURL))
                setPreviewSlides(doc.slides)
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
        let preferredSelectionIndex = currentPreviewSelectionIndex()
        let formatted = formatLyricsMarkdown(rawLyrics)
        rawLyrics = formatted
        let doc = parseLyricsDocument(formatted)
        beginPreviewTransition(to: .lyrics)
        setPreviewSlides(doc.slides, preferredSelectionIndex: preferredSelectionIndex)
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
        var normalized = line
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if normalized.first == "[", normalized.last == "]" {
            normalized.removeFirst()
            normalized.removeLast()
            normalized = normalized
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

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
        guard !isCurrentSelectionMediaFile, let url = editorSourceURL else { return }
        do {
            try rawLyrics.write(to: url, atomically: true, encoding: .utf8)
            lastLoadedText = rawLyrics
            if let folderURL {
                loadMarkdownFiles(
                    from: folderURL,
                    refreshSearchResults: true
                )
            } else {
                rebuildDisplayNames(for: [url] + playlistResolvedURLs)
            }
        } catch {
            // Silently ignore for now; could surface UI feedback later.
        }
    }

    private func pickWindowForPreview() {
        guard isWindowCaptureSupported else { return }
        screenCaptureManager.presentWindowPicker()
    }

    private func removeWebpage(_ url: URL) {
        webpageURLs.removeAll { $0 == url }
        webpageTitles.removeValue(forKey: url)

        if flow.previewSlides.contains(where: { $0.webpageURL == url }) {
            clearPreviewDocument()
        }

        if session.slides.contains(where: { $0.webpageURL == url }) {
            clearCurrentDocument()
        }

        if sidebarSelection == .web(url) {
            sidebarSelection = nil
        }

        if selectedWebpageURL == url {
            selectedWebpageURL = nil
        }
    }

    private func openWebpageFromSidebar(_ rawValue: String) -> Bool {
        guard let url = WebpageURLMatcher.normalizedURL(from: rawValue) else {
            return false
        }

        setSidebarSelectionWithoutLoading(.web(url))
        loadWebpagePreview(for: url)
        return true
    }

    private func clearSelectedWindowFromSidebar() {
        let windowID: CGWindowID?
        if case .window(let selectedWindowID) = sidebarSelection {
            windowID = selectedWindowID
        } else {
            windowID = captureWindows.first?.windowID
        }
        guard let windowID else { return }
        if flow.previewSlides.contains(where: { $0.captureWindowID == windowID }) {
            clearPreviewDocument()
        }
        if session.slides.contains(where: { $0.captureWindowID == windowID }) {
            clearCurrentDocument()
        } else {
            releaseWindowCaptureSelectionIfUnused()
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
        beginPreviewTransition(to: .web(url))
        applyPreviewMediaLoad(slides: WebpageSlideCatalog.initialSlides(from: url))
    }

    private func webpageTitle(for url: URL) -> String {
        if let liveTitle = LiveWebpageTitleCache.title(for: url, in: liveWebpageTitles)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !liveTitle.isEmpty {
            return liveTitle
        }

        let cachedTitle = WebpageURLMatcher.matchingURL(in: webpageURLs, for: url)
            .flatMap { webpageTitles[$0] }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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

        LiveWebpageTitleCache.store(
            resolvedTitle,
            for: url,
            titles: &liveWebpageTitles,
            accessOrder: &liveWebpageTitleOrder
        )

        guard let savedEntryURL = WebpageURLMatcher.matchingURL(in: webpageURLs, for: url) else { return }
        guard webpageTitles[savedEntryURL] != resolvedTitle else { return }
        webpageTitles[savedEntryURL] = resolvedTitle
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
            guard let url = URL(string: value), WebpageURLMatcher.isSupported(url), seen.insert(url).inserted else {
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
        guard isPreviewWebpageNavigationActive else { return }
        guard let slides = WebpageSlideCatalog.navigatedSlides(
            in: flow.previewSlides,
            to: newURL,
            from: previousURL
        ) else {
            return
        }

        beginPreviewTransition(to: .web(newURL))
        setPreviewSlides(slides)
    }

    private func updateCurrentWebpageURL(to newURL: URL, from previousURL: URL) {
        guard let slides = WebpageSlideCatalog.navigatedSlides(
            in: session.slides,
            to: newURL,
            from: previousURL
        ) else {
            return
        }

        commitCurrentSlides(slides)
    }

    private var isPreviewWebpageNavigationActive: Bool {
        guard case .web = previewSource else { return false }
        return flow.previewSlides.contains { $0.webpageURL != nil }
    }

    private func setSidebarSelectionWithoutLoading(_ selection: SidebarSelection?) {
        guard sidebarSelection != selection else {
            ignoresNextSidebarSelectionChange = false
            return
        }
        ignoresNextSidebarSelectionChange = true
        sidebarSelection = selection
    }

    private func loadWindowPreview(for windowID: CGWindowID) {
        beginPreviewTransition(to: .window(windowID))
        selectedFileURL = nil
        selectedPlaylistEntryID = nil
        selectedPlaylistEntryIDs = []
        editingSourceURL = nil

        guard isWindowCaptureSupported else {
            clearPreviewDocument()
            return
        }
        guard let window = captureWindows.first(where: { $0.windowID == windowID }) else {
            clearPreviewDocument()
            return
        }
        applyPreviewMediaLoad(slides: buildWindowSlides(from: window))
    }

    @discardableResult
    private func beginPreviewTransition(to source: PreviewSource) -> UUID {
        let token = UUID()
        previewLoadToken = token
        previewSource = source
        return token
    }

    private func previewTransitionIsCurrent(token: UUID, source: PreviewSource) -> Bool {
        previewLoadToken == token && previewSource == source
    }

    private var editorSourceURL: URL? {
        editingSourceURL
    }

    private func beginLyricsEditing() {
        guard canEditSelection else { return }
        editingSourceURL = currentSelectedURL
        isEditingLyrics = true
    }

    private func beginCurrentLyricsEditing() {
        guard canEditCurrentLyrics, let url = currentLyricsSourceURL else { return }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            newFileWarning = "Could not open lyrics for editing."
            return
        }

        let doc = LyricsParser.parseDocument(contents, fileName: url.lastPathComponent)
        beginPreviewTransition(to: .file(url))
        setSidebarSelectionWithoutLoading(.library(url))
        selectedFileURL = url
        selectedPlaylistEntryID = nil
        selectedPlaylistEntryIDs = []
        editingSourceURL = url
        rawLyrics = contents
        lastLoadedText = contents
        isEditingLyrics = true
        newFileWarning = nil
        setPreviewSlides(doc.slides)
    }

    private func previewLyricsSourceURL() -> URL? {
        guard case .file(let url) = previewSource,
              LibraryFileKind(url: url).isEditableLyrics,
              !flow.previewIsEmpty else {
            return nil
        }
        return url
    }

    private func currentPreviewSelectionIndex() -> Int? {
        guard let previewSelectionID = flow.previewSelectionID else { return nil }
        return flow.previewSlideIndex(for: previewSelectionID)
    }

    private func restoreCurrentDocumentIfNeeded(
        slides: [Slide],
        pdfSource: PDFSlideSource?,
        currentSlideID: Slide.ID?,
        currentSlideIndex: Int?
    ) {
        let preservedUsesPDF = pdfSource != nil
        let currentUsesPDF = session.pdfSlideSource != nil
        let preservedSlideIDs = slides.map(\.id)
        let currentSlideIDs = session.slides.map(\.id)
        let pdfSourcesMatch = pdfSource == session.pdfSlideSource

        guard preservedSlideIDs != currentSlideIDs
            || preservedUsesPDF != currentUsesPDF
            || !pdfSourcesMatch
            || session.currentSlideID != currentSlideID else {
            return
        }

        if WebpageSlideCatalog.shouldPreserveCurrentWebpageOverRestore(
            preservedSlides: slides,
            currentSlides: session.slides
        ) {
            return
        }

        if let pdfSource {
            commitCurrentPDFSource(
                pdfSource,
                preferredSelection: currentSlideID,
                preferredSelectionIndex: currentSlideIndex
            )
            return
        }

        let restoredSelection = currentSlideID.flatMap { slideID in
            slides.contains(where: { $0.id == slideID }) ? slideID : nil
        }
        commitCurrentSlides(
            slides,
            lyricsSourceURL: currentLyricsSourceURL,
            preferredSelection: restoredSelection,
            preferredSelectionIndex: currentSlideIndex
        )
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
