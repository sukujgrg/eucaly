import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreGraphics
import Combine

public struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let workspaceCommands: OutputWorkspaceCommands
    @State private var hasInitializedControls = false
    @State private var importPanel = LibraryImportPanelController()
    @State private var importRequestID: UUID?
    @State private var importCancellation: LibraryImportCancellation?
    @State private var isImporting = false
    @State private var importSelectionGeneration = UUID()
    @State private var lyricsEditor = LyricsEditorSession()
    @State private var lyricsEditorFocusController = PlainTextEditorFocusController()
    @StateObject private var session: PresentationSession
    @ObservedObject private var outputProfiles: OutputProfileStore
    @ObservedObject private var projectionDisplays: ProjectionDisplayManager
    @StateObject private var flow: PresentationFlowController
    @State private var folderURL: URL?
    @State private var markdownFiles: [URL] = []
    @State private var previewLibraryFiles: [URL] = []
    @State private var backgroundAudioLibraryFiles: [URL] = []
    @State private var selectedPlaylistEntryIDs: Set<UUID> = []
    @StateObject private var playlistStore = PlaylistStore.shared
    @AppStorage("libraryRootPath") private var libraryRootPath: String = ""
    @AppStorage("libraryRootBookmark") private var libraryRootBookmark: String = ""
    @AppStorage("backgroundVisualBookmark") private var backgroundVisualBookmark: String = ""
    @AppStorage("backgroundAudioBookmark") private var backgroundAudioBookmark: String = ""
    @AppStorage("backgroundAudioVolume") private var backgroundAudioVolume: Double = 1.0
    @AppStorage("backgroundAudioLoop") private var backgroundAudioLoop: Bool = true
    @AppStorage("thumbnailScale") private var thumbnailScale: Double = 1.0
    @AppStorage("windowCaptureFrameRate") private var windowCaptureFrameRate: Int = 30
    @State private var backgroundAudioVolumeDraft: Double = 1.0
    @State private var backgroundAudioVolumeDebounceToken = UUID()
    @State private var fileDisplayNames: [URL: String] = [:]
    @State private var newFileWarning: String? = nil
    @State private var sidebarSelection: SidebarSelection? = nil
    @State private var selectedAudioURL: URL? = nil
    @State private var previewLoadToken = UUID()
    @State private var pendingPreviewSource: PreviewSource? = nil
    @State private var previewLoadError: String? = nil
    @State private var librarySearch = LibrarySearchModel()
    @State private var libraryScrollRequest: LibraryScrollRequest?
    @State private var isLibrarySearchPresented: Bool = false
    @State private var libraryLoadTask: Task<Void, Never>? = nil
    @State private var isLibraryLoading: Bool = false
    @State private var libraryLoadFailure: LibraryLoadFailure?
    @State private var libraryRevision: Int = 0
    @State private var displayedLibraryRootURL: URL? = nil
    @State private var lyricsProjectionSize: CGSize?
    @FocusState private var focusedDetailTarget: DetailFocusTarget?
    @State private var securityScopedRoot: URL? = nil
    @State private var securityScopedBackgroundVisual: URL? = nil
    @State private var securityScopedBackgroundAudio: URL? = nil
    @StateObject private var screenCaptureManager = ScreenCaptureManager.shared
    @EnvironmentObject private var appUpdateViewModel: AppUpdateViewModel
    @State private var isEditorPreviewAreaCollapsed: Bool = false
    private let playlistDirectoryName = "Playlist"
    private let windowCaptureFrameRateOptions = [24, 30, 60]
    private let libraryFileScanner = LibraryFileScannerService()

    init(session: PresentationSession, commands: OutputWorkspaceCommands) {
        self.projectionDisplays = session.outputCoordinator.displays
        workspaceCommands = commands
        _session = StateObject(wrappedValue: session)
        _flow = StateObject(wrappedValue: session.outputCoordinator.program(session.outputSourceID).flow)
        _outputProfiles = ObservedObject(wrappedValue: session.outputCoordinator.profiles)
        let prefix = "workspace." + session.outputSourceID.uuidString + "."
        let legacy = session.outputSourceID == OutputWorkspaceRecord.primaryID
        _backgroundVisualBookmark = AppStorage(wrappedValue: legacy ? UserDefaults.standard.string(forKey: "backgroundVisualBookmark") ?? "" : "", prefix + "backgroundVisualBookmark")
        _backgroundAudioBookmark = AppStorage(wrappedValue: legacy ? UserDefaults.standard.string(forKey: "backgroundAudioBookmark") ?? "" : "", prefix + "backgroundAudioBookmark")
        _backgroundAudioVolume = AppStorage(wrappedValue: legacy ? UserDefaults.standard.object(forKey: "backgroundAudioVolume") as? Double ?? 1 : 1, prefix + "backgroundAudioVolume")
        _backgroundAudioLoop = AppStorage(wrappedValue: legacy ? UserDefaults.standard.object(forKey: "backgroundAudioLoop") as? Bool ?? true : true, prefix + "backgroundAudioLoop")
    }

    private typealias PreviewSource = PresentationFlowController.PreviewSource
    private var previewSource: PreviewSource {
        get { flow.previewSource }
        nonmutating set { flow.previewSource = newValue }
    }
    private var currentLyricsSourceURL: URL? { session.currentLyricsSourceURL }

    private enum EditorExitAction: Equatable {
        case closeEditor
        case newLyrics
        case sidebarSelection(SidebarSelectionRequest)
        case editLyrics(URL)
        case editCurrentLyrics(URL)
    }

    private enum EditorExitDecision {
        case save
        case discard
        case cancel
    }

    private struct SidebarSelectionRequest: Equatable {
        let selection: SidebarSelection?
        let playlistEntryIDs: Set<UUID>
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

    private var isWindowCaptureSupported: Bool { true }

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
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    OutputIssueBanner(session: session, manageOutputs: showOutputSettings)
                    if isImporting {
                        HStack {
                            ProgressView().controlSize(.small)
                            Text("Importing files…")
                            Spacer()
                        }
                        .font(.caption)
                        .padding(10)
                    }
                    if let newFileWarning, !hasActiveEditorPane || isEditorPreviewAreaCollapsed {
                        HStack(alignment: .top) {
                            Image(systemName: "exclamationmark.triangle")
                            Text(newFileWarning).frame(maxWidth: .infinity, alignment: .leading)
                            Button("Dismiss") { self.newFileWarning = nil }
                        }
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(10)
                    }
                }
            }
            .environment(\.lyricsProjectionSize, lyricsProjectionSize)
            .environment(\.audienceOutputProfile, session.outputCoordinator.thumbnailProfile(workspace: session.outputSourceID))
            .background(
                OutputWorkspaceCloseConfirmation(commands: workspaceCommands, shouldClose: confirmMainWindowClose,
                                                 willClose: handleControlsWillClose)
                    .frame(width: 0, height: 0)
            )
    }

    private var rootSplitView: some View {
        rootSplitWithLibrarySearchOverlay
    }

    private var rootSplitBase: some View {
        NavigationSplitView {
            sidebarPane
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 520)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            projectionToolbar
        }
        .applyToolbarBackgroundIfAvailable()
    }

    private var rootSplitWithLibrarySearchOverlay: some View {
        ZStack {
            rootSplitWithNotificationObservers
                .excludingInterfaceAnimation(.search)

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
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(1)
            }
        }
    }

    private var rootSplitWithStateObservers: some View {
        rootSplitBase
        .onAppear {
            guard !hasInitializedControls else { return }
            hasInitializedControls = true
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
            let bookmark = backgroundVisualBookmark
            deferSessionChange { session.outputCoordinator.setBackgroundVisualBookmark(bookmark, for: session) }
            refreshBackgroundVisualAccess()
        }
        .onChange(of: backgroundAudioBookmark) { _, _ in
            refreshBackgroundAudioAccess()
        }
        .onChange(of: session.backgroundAudioURL) { _, newValue in
            selectedAudioURL = newValue?.standardizedFileURL
        }
        .onChange(of: libraryRevision) { _, _ in
            guard let selected = selectedAudioURL?.standardizedFileURL,
                  !backgroundAudioLibraryFiles.contains(where: { $0.standardizedFileURL == selected }) else { return }
            importSelectionGeneration = UUID()
            selectedAudioURL = session.backgroundAudioURL?.standardizedFileURL
        }
        .onChange(of: session.backgroundAudioPlaybackState) { _, _ in
            importSelectionGeneration = UUID()
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
        .onChange(of: outputProfiles.document.destinations) { _, _ in
            updateLyricsProjectionSize()
        }
        .onChange(of: projectionDisplays.revision) { _, _ in
            updateLyricsProjectionSize()
        }
    }

    private func handleControlsWillClose() {
        importPanel.cancel()
        cancelFileImport()
        cancelPreviewLoad()
        librarySearch.cancelDebounce()
        libraryLoadTask?.cancel()
        isLibraryLoading = false
        librarySearch.setIndexing(false)
        releaseSecurityScopedAccess()
        // Capture views release their own streams when removed. The surviving
        // projection session (and app termination) owns global capture cleanup.
    }

    private func handleExitCommand() {
        guard (session.isPresenting && session.areSlidesVisible) else { return }
        deferSessionChange {
            flow.hideSlides(in: session)
        }
    }

    private var rootSplitWithNotificationObservers: some View {
        rootSplitWithStateObservers
            .onReceive(screenCaptureManager.$windows, perform: handleCaptureWindowsUpdate)
            .onReceive(screenCaptureManager.windowPickerSelections, perform: handleWindowPickerSelection)
            .onReceive(NotificationCenter.default.publisher(for: .toggleSlidesVisibility), perform: handleToggleSlidesVisibilityNotification)
            .onReceive(NotificationCenter.default.publisher(for: .toggleBackgroundVisibility), perform: handleToggleBackgroundVisibilityNotification)
            .onReceive(NotificationCenter.default.publisher(for: .toggleBackgroundAudio), perform: handleToggleBackgroundAudioNotification)
            .onReceive(NotificationCenter.default.publisher(for: .clearAllLayers), perform: handleClearAllLayersNotification)
        .onReceive(NotificationCenter.default.publisher(for: .clearBackgroundVisual), perform: handleClearBackgroundVisualNotification)
        .onReceive(NotificationCenter.default.publisher(for: .clearBackgroundAudio), perform: handleClearBackgroundAudioNotification)
        .onReceive(NotificationCenter.default.publisher(for: .newLyrics), perform: handleNewLyricsNotification)
        .onReceive(NotificationCenter.default.publisher(for: .saveLyrics), perform: handleSaveLyricsNotification)
        .onReceive(NotificationCenter.default.publisher(for: .showLibrarySearch)) { _ in
            guard workspaceCommands.isActive else { return }
            presentLibrarySearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .refreshLibrary)) { _ in
            guard workspaceCommands.isActive else { return }
            refreshLibrary()
        }
    }

    @ViewBuilder
    private var sidebarPane: some View {
        SidebarView(configuration: SidebarConfiguration(
            session: session,
            isWindowCaptureSupported: isWindowCaptureSupported,
            libraryFiles: previewLibraryFiles,
            audioFiles: backgroundAudioLibraryFiles,
            isLibraryLoading: isLibraryLoading,
            libraryLoadFailure: libraryLoadFailure,
            libraryRevision: libraryRevision,
            playlistItems: playlistSidebarItems,
            libraryRootURL: libraryRootURL,
            captureWindows: captureWindows,
            libraryScrollRequest: libraryScrollRequest,
            selectedPlaylistEntryIDs: selectedPlaylistEntryIDs,
            sidebarSelection: sidebarSelection,
            selectedAudioURL: selectedAudioURL,
            backgroundAudioLoop: backgroundAudioLoop,
            backgroundAudioVolumeDraft: backgroundAudioVolumeDraft,
            windowCaptureFrameRate: windowCaptureFrameRate,
            displayName: { displayName(for: $0) },
            onImportToLibrary: importFilesToLibrary,
            onRetryLibraryLoad: refreshLibrary,
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
            onSelectionRequest: { selection, playlistEntryIDs in
                handleSidebarSelectionRequest(
                    selection,
                    playlistEntryIDs: playlistEntryIDs
                )
            },
            onPickWindow: pickWindowForPreview,
            onClearSelectedWindow: clearSelectedWindowFromSidebar,
            setSelectedAudioURL: { selection in
                importSelectionGeneration = UUID()
                selectedAudioURL = selection
            },
            setBackgroundAudioLoop: { backgroundAudioLoop = $0 },
            setBackgroundAudioVolumeDraft: { backgroundAudioVolumeDraft = $0 },
            setWindowCaptureFrameRate: { windowCaptureFrameRate = $0 }
        ))

    }

    @ViewBuilder
    private var detailPane: some View {
        detailView
    }

    @ToolbarContentBuilder
    private var projectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            HStack(spacing: 10) {
                OutputSlidesToggleButton(session: session, onToggle: toggleSlidesFromUI)

                Button {
                    presentLibrarySearch()
                } label: {
                    Label("Command Palette", systemImage: "magnifyingglass")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.bordered)
                .help("Open the command palette")
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            AppUpdateToolbarButton(viewModel: appUpdateViewModel)
            OutputQuickControls(outputs: session.outputCoordinator, workspaceID: session.outputSourceID, manageOutputs: showOutputSettings)
        }
        ToolbarItem(placement: .primaryAction) {
            ThumbnailSettingsMenu()
        }
    }

    private func showOutputSettings() {
        NotificationCenter.default.post(name: .showManageOutputsSettings, object: nil)
    }

    private func handleRootOnAppear() {
        deferSessionChange {
            projectionDisplays.refresh()
            updateLyricsProjectionSize()
        }
        refreshLibraryRootAccess()
        refreshBackgroundVisualAccess()
        refreshBackgroundAudioAccess()
        loadPlaylists()
        backgroundAudioVolumeDraft = backgroundAudioVolume
        deferSessionChange {
            session.setBackgroundAudioLoop(backgroundAudioLoop)
            session.setBackgroundAudioVolume(backgroundAudioVolume)
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
                setSidebarSelectionWithoutLoading(nil)
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
        if case .window = sidebarSelection {
            setSidebarSelectionWithoutLoading(nil)
            if flow.previewSlides.contains(where: { $0.captureWindowID != nil }) {
                cancelPreviewLoad()
                previewLoadError = nil
                flow.clearPreviewDocument()
            }
        }
    }

    private func handleWindowPickerSelection(_ result: WindowCapturePickerRouting.Selection) {
        guard result.workspaceID == session.outputSourceID else { return }
        let windowID = result.windowID
        let selection = SidebarSelection.window(windowID)
        guard sidebarSelection != selection,
              captureWindows.contains(where: { $0.windowID == windowID }) else {
            return
        }
        handleSidebarSelectionRequest(selection)
    }

    private func handleToggleSlidesVisibilityNotification(_ notification: Notification) {
        guard workspaceCommands.isActive else { return }
        deferSessionChange {
            flow.toggleSlidesVisibility(in: session)
        }
    }

    private func handleToggleBackgroundVisibilityNotification(_ notification: Notification) {
        guard workspaceCommands.isActive else { return }
        deferSessionChange {
            session.toggleBackgroundVisualVisibility()
        }
    }

    private func handleToggleBackgroundAudioNotification(_ notification: Notification) {
        guard workspaceCommands.isActive else { return }
        deferSessionChange {
            if session.isBackgroundAudioPlaying {
                session.pauseBackgroundAudio()
            } else {
                session.playBackgroundAudio()
            }
        }
    }

    private func handleClearAllLayersNotification(_ notification: Notification) {
        guard workspaceCommands.isActive else { return }
        deferSessionChange {
            session.outputCoordinator.clearBackgrounds(for: session)
            flow.hideSlides(in: session)
            clearBackgroundVisual()
            clearBackgroundAudio()
        }
    }

    private func handleClearBackgroundVisualNotification(_ notification: Notification) {
        guard workspaceCommands.isActive else { return }
        deferSessionChange {
            session.outputCoordinator.clearBackgrounds(for: session)
            clearBackgroundVisual()
        }
    }

    private func handleClearBackgroundAudioNotification(_ notification: Notification) {
        guard workspaceCommands.isActive else { return }
        deferSessionChange {
            clearBackgroundAudio()
        }
    }

    private func handleNewLyricsNotification(_ notification: Notification) {
        guard workspaceCommands.isActive else { return }
        DispatchQueue.main.async {
            requestEditorExit(.newLyrics)
        }
    }

    private func handleSaveLyricsNotification(_ notification: Notification) {
        guard workspaceCommands.isActive else { return }
        guard lyricsEditor.isEditing, !isCurrentSelectionMediaFile else { return }
        deferSessionChange {
            _ = saveEditorDraft()
        }
    }

    private func beginNewLyrics() {
        var state = NewLyricsState(
            editor: lyricsEditor,
            selectedPlaylistEntryIDs: selectedPlaylistEntryIDs,
            sidebarSelection: sidebarSelection
        )
        NewLyricsAction.apply(state: &state, clearPreview: clearPreviewDocument)
        lyricsEditor = state.editor
        setSidebarSelectionWithoutLoading(state.sidebarSelection)
        isEditorPreviewAreaCollapsed = false
        newFileWarning = nil
    }

    private var detailView: some View {
        DetailRootView(
            editorPane: EditorPaneContainerView(
                newFileWarning: newFileWarning,
                rawLyrics: Binding(get: { lyricsEditor.draft }, set: { draft in
                    importSelectionGeneration = UUID()
                    lyricsEditor.draft = draft
                }),
                editorID: lyricsEditor.documentID,
                saveButtonTitle: saveButtonTitle,
                canSave: canSaveEditorContent,
                focusController: lyricsEditorFocusController,
                onAction: handleEditorAction
            ),
            previewPane: PreviewPaneContainerView(
                flow: flow,
                isEditorPreviewAreaCollapsed: isEditorPreviewAreaCollapsed,
                hasEditorPane: hasActiveEditorPane,
                canEditSelection: canEditSelection && !isPreviewLoading && previewLoadError == nil,
                canLoadToCurrent: canLoadPreviewToCurrent,
                loadToCurrentHelp: loadToCurrentHelp,
                loadError: previewLoadError,
                thumbnailScale: thumbnailScale,
                onEdit: beginLyricsEditing,
                onLoadToCurrent: handleLoadPreviewToCurrent,
                onToggleEditorPreviewArea: toggleEditorPreviewArea
            ),
            currentPane: CurrentPaneContainerView(
                session: session,
                playbackProgress: session.playbackProgress,
                flow: flow,
                thumbnailScale: thumbnailScale,
                canEditCurrentLyrics: canEditCurrentLyrics,
                onEditCurrentLyrics: beginCurrentLyricsEditing,
                onClearCurrent: clearCurrentDocument,
                focusedDetailTarget: $focusedDetailTarget
            ),
            hasEditorPane: hasActiveEditorPane,
            isEditorPreviewAreaCollapsed: isEditorPreviewAreaCollapsed
        )
    }

    private var hasActiveEditorPane: Bool {
        lyricsEditor.isEditing && !isCurrentSelectionMediaFile
    }

    private var saveButtonTitle: String {
        editorSourceURL == nil ? "Save As..." : "Save"
    }

    private var canSaveEditorContent: Bool {
        lyricsEditor.canSave
    }

    private func handleEditorAction(_ action: EditorPaneAction) {
        importSelectionGeneration = UUID()
        switch action {
        case .close:
            requestEditorExit(.closeEditor)
        case .save:
            _ = saveEditorDraft()
        case .format:
            formatEditorDraft()
        case .clear:
            if !lyricsEditorFocusController.clearLyrics() { lyricsEditor.clearDraft() }
            clearPreviewDocument()
        }
    }

    @discardableResult
    private func requestEditorExit(_ action: EditorExitAction) -> Bool {
        importSelectionGeneration = UUID()
        guard lyricsEditor.isEditing else {
            performEditorExit(action)
            return true
        }
        guard lyricsEditor.isDirty else {
            lyricsEditor.endEditing()
            performEditorExit(action)
            return true
        }

        switch presentDirtyEditorAlert() {
        case .save:
            guard saveEditorDraft() else { return false }
        case .discard:
            if action == .closeEditor {
                restoreSavedEditorPreview()
            }
        case .cancel:
            return false
        }

        lyricsEditor.endEditing()
        performEditorExit(action)
        return true
    }

    private func presentDirtyEditorAlert() -> EditorExitDecision {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Save changes to these lyrics?"
        alert.informativeText = "Your edits have not been saved to disk."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.isEnabled = lyricsEditor.hasLoadableDraft

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .save
        case .alertSecondButtonReturn:
            return .discard
        default:
            return .cancel
        }
    }

    private func performEditorExit(_ action: EditorExitAction) {
        switch action {
        case .closeEditor:
            break
        case .newLyrics:
            beginNewLyrics()
        case .sidebarSelection(let request):
            commitSidebarSelection(request)
        case .editLyrics(let url):
            startLyricsEditing(url: url)
        case .editCurrentLyrics(let url):
            startCurrentLyricsEditing(url: url)
        }
    }

    private func toggleEditorPreviewArea() {
        if !isEditorPreviewAreaCollapsed {
            lyricsEditorFocusController.resignFocus()
        }
        // Loads also change this flag; only an explicit disclosure animates it.
        InterfaceMotion.disclosure.animate(reduceMotion: reduceMotion) {
            isEditorPreviewAreaCollapsed.toggle()
        }
    }

    private func confirmMainWindowClose() -> Bool {
        guard lyricsEditor.isDirty else { return true }

        switch presentDirtyEditorAlert() {
        case .save:
            return saveEditorDraft()
        case .discard:
            lyricsEditor.endEditing()
            return true
        case .cancel:
            return false
        }
    }

    private func commitCurrentSlides(
        _ slides: [Slide],
        lyricsSourceURL: URL? = nil,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        flow.setCurrentSlides(
            slides,
            in: session,
            lyricsSourceURL: lyricsSourceURL,
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    private func commitCurrentPDFSource(
        _ source: PDFSlideSource,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) {
        flow.setCurrentPDFSource(
            source,
            in: session,
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    private func clearPreviewDocument() {
        let clearedWindowFromPreview = flow.previewSlides.contains { $0.captureWindowID != nil }
        cancelPreviewLoad()
        previewLoadError = nil
        flow.clearPreviewDocument()
        lyricsEditor.invalidatePreview()
        if clearedWindowFromPreview {
            releaseWindowCaptureSelectionIfUnused()
        }
    }

    private func clearCurrentDocument() {
        let clearedWindowFromCurrent = session.slides.contains { $0.captureWindowID != nil }
        flow.clearCurrentDocument(in: session)
        flow.isCurrentCollapsed = true
        if clearedWindowFromCurrent, case .window = sidebarSelection {
            setSidebarSelectionWithoutLoading(nil)
        }
        if clearedWindowFromCurrent {
            releaseWindowCaptureSelectionIfUnused()
        }
    }

    private func releaseWindowCaptureSelectionIfUnused() {
        session.outputCoordinator.releaseUnusedWindowCaptureSelection()
    }

    private func selectCurrentSlide(_ slideID: Slide.ID) {
        flow.selectCurrentSlide(slideID, in: session)
    }

    private func handleLoadPreviewToCurrent() {
        guard canLoadPreviewToCurrent else { return }
        session.setCurrentResourceScope(securityScopedRoot)

        if lyricsEditor.isEditing {
            commitCurrentSlides(
                flow.previewSlides,
                lyricsSourceURL: lyricsEditor.sourceURL,
                preferredSelection: flow.previewSelectionID
            )
            flow.isCurrentCollapsed = false
            focusedDetailTarget = .currentThumbnails
            session.requestCurrentProjection()
            return
        }

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
        isEditorPreviewAreaCollapsed = true
        focusedDetailTarget = .currentThumbnails
        session.requestCurrentProjection()
    }

    private var canLoadPreviewToCurrent: Bool {
        guard !isPreviewLoading, previewLoadError == nil else { return false }
        if lyricsEditor.isEditing {
            return lyricsEditor.isPreviewSynchronized && !flow.previewIsEmpty
        }
        return !flow.previewIsEmpty
    }

    private var loadToCurrentHelp: String {
        if isPreviewLoading {
            return "Wait for Preview to finish loading."
        }
        if previewLoadError != nil {
            return "Resolve the Preview load error before loading to Current."
        }
        if lyricsEditor.isEditing && !lyricsEditor.isPreviewSynchronized {
            return "Save or Format the lyrics to update Preview before loading to Current."
        }
        return "Load Preview into Current."
    }

    private func toggleSlidesFromUI() { flow.toggleSlidesVisibility(in: session) }

    private func updateLyricsProjectionSize() {
        let size = session.outputCoordinator.thumbnailGeometry(workspace: session.outputSourceID)
        deferSessionChange {
            lyricsProjectionSize = size
        }
    }

    private var canEditSelection: Bool {
        guard !isPreviewLoading, let url = previewLyricsSourceURL() else { return false }
        return !lyricsEditor.isEditing || editorSourceURL != url
    }

    private var canEditCurrentLyrics: Bool {
        guard !session.slides.isEmpty, let currentLyricsSourceURL else { return false }
        return isLyricsFile(currentLyricsSourceURL)
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
        presentLibraryImport(source: .library)
    }

    private func importAudioToLibrary() {
        presentLibraryImport(source: .audio)
    }

    private func presentLibraryImport(source: LibraryImportPanelController.Source) {
        guard !isImporting else { return }
        guard let root = libraryRootURL else {
            newFileWarning = "Set a library root before importing files."
            return
        }
        guard let window = workspaceCommands.window else { return }
        importPanel.present(source: source, for: window) { urls in
            guard libraryRootURL?.standardizedFileURL == root.standardizedFileURL else { return }
            startFileImport(urls, root: root, source: source)
        }
    }

    private func startFileImport(_ urls: [URL], root: URL, source: LibraryImportPanelController.Source) {
        guard !urls.isEmpty, !isImporting else { return }
        let requestID = UUID()
        let cancellation = LibraryImportCancellation()
        let selectionGeneration = importSelectionGeneration
        let previewToken = previewLoadToken
        let editor = lyricsEditor
        let sidebar = sidebarSelection
        let previewSelection = flow.previewSelectionID
        let selectedAudio = selectedAudioURL
        let activeAudio = session.backgroundAudioURL
        let audioPlaybackState = session.backgroundAudioPlaybackState
        importRequestID = requestID
        importCancellation = cancellation
        isImporting = true
        newFileWarning = nil
        Task {
            let result = await LibraryFileImportService.shared.importFiles(urls, into: root, cancellation: cancellation)
            guard importRequestID == requestID else { return }
            importRequestID = nil
            importCancellation = nil
            isImporting = false
            guard !cancellation.isCancelled, workspaceCommands.window != nil,
                  libraryRootURL?.standardizedFileURL == root.standardizedFileURL else { return }
            if !result.importedURLs.isEmpty {
                folderURL = root
                loadMarkdownFiles(from: root, refreshSearchResults: true)
                loadPlaylists()
                // Copying can finish after the operator has selected or edited
                // something else. Keep the files and refresh, but preserve that
                // newer intent instead of opening a document or starting music.
                let maySelectImport = importSelectionGeneration == selectionGeneration
                    && previewLoadToken == previewToken && lyricsEditor == editor
                    && sidebarSelection == sidebar && flow.previewSelectionID == previewSelection
                    && selectedAudioURL == selectedAudio && session.backgroundAudioURL == activeAudio
                    && session.backgroundAudioPlaybackState == audioPlaybackState
                if maySelectImport {
                    switch source {
                    case .library:
                        if let first = result.importedURLs.first(where: { LibraryFileKind(url: $0).isPreviewLibraryItem }) {
                            libraryScrollRequest = LibraryScrollRequest(url: first)
                            handleSidebarSelectionRequest(.library(first))
                        }
                    case .audio:
                        if let first = result.importedURLs.first(where: { LibraryFileKind(url: $0).isBackgroundAudioSource }) {
                            setSidebarSelectionWithoutLoading(nil)
                            selectBackgroundAudio(first)
                        }
                    }
                }
            }
            if let failureMessage = result.failureMessage { newFileWarning = failureMessage }
        }
    }

    private func cancelFileImport() {
        importCancellation?.cancel()
        importCancellation = nil
        importRequestID = nil
        isImporting = false
    }

    private func loadMarkdownFiles(
        from folder: URL,
        refreshSearchResults: Bool = false
    ) {
        let previousSearchScopeFiles = librarySearch.scopeFilesSnapshot
        let index = librarySearch.index

        libraryLoadTask?.cancel()
        isLibraryLoading = true
        libraryLoadFailure = nil
        librarySearch.setIndexing(true)
        libraryLoadTask = Task.detached(priority: .userInitiated) {
            let cachedMetadata = await index.cachedLibraryMetadata(root: folder)
            if !cachedMetadata.isEmpty {
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    applyLibraryMetadata(cachedMetadata, for: folder)
                }
            }
            guard !Task.isCancelled else { return }

            let syncResult: LibraryTextSearchIndex.MetadataSyncResult
            do {
                syncResult = try await index.refreshLibraryMetadata(root: folder)
            } catch is CancellationError {
                return
            } catch {
                let failure = error as? LibraryLoadFailure
                    ?? LibraryLoadFailure(url: folder, error: error)
                await MainActor.run {
                    guard !Task.isCancelled else { return }
                    if !LibraryLoadFailure.shouldRetainExistingLists(
                        displayedRoot: displayedLibraryRootURL,
                        failedRoot: folder
                    ) {
                        applyLibraryMetadata([], for: folder)
                        librarySearch.applySearchResults(
                            [],
                            query: librarySearch.trimmedQuery,
                            currentSelectedURL: currentSelectedURL,
                            preferFirstResult: true
                        )
                    }
                    libraryLoadFailure = failure
                    isLibraryLoading = false
                    librarySearch.setIndexing(false)
                }
                return
            }
            guard !Task.isCancelled else { return }

            let metadata = syncResult.metadata

            let currentQuery = await MainActor.run {
                librarySearch.trimmedQuery
            }

            let refreshedResults: [LibraryTextSearchIndex.SearchResult]
            if currentQuery.count >= LibrarySearchModel.minimumCharacterCount {
                refreshedResults = await index.search(
                    query: currentQuery,
                    scopeFiles: metadata.filter { $0.kind.isPreviewLibraryItem }.map(\.url)
                )
            } else {
                refreshedResults = []
            }
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard !Task.isCancelled else { return }
                let searchScopeFiles = applyLibraryMetadata(metadata, for: folder)
                isLibraryLoading = false
                librarySearch.setIndexing(false)
                libraryLoadFailure = syncResult.failure.map { LibraryLoadFailure(url: folder, error: $0) }

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
        for root: URL
    ) -> [URL] {
        displayedLibraryRootURL = root.standardizedFileURL
        let files = metadata.map(\.url.standardizedFileURL)
        let previewFiles = metadata
            .filter { $0.kind.isPreviewLibraryItem }
            .map(\.url.standardizedFileURL)
        let backgroundAudioFiles = metadata
            .filter { $0.kind.isBackgroundAudioSource }
            .map(\.url.standardizedFileURL)
        let displayNames = Dictionary(
            uniqueKeysWithValues: metadata.map { ($0.url.standardizedFileURL, $0.title) }
        )

        let listsUnchanged =
            markdownFiles == files
            && previewLibraryFiles == previewFiles
            && backgroundAudioLibraryFiles == backgroundAudioFiles
        let titlesUnchanged = displayNames.allSatisfy { fileDisplayNames[$0.key] == $0.value }

        markdownFiles = files
        previewLibraryFiles = previewFiles
        backgroundAudioLibraryFiles = backgroundAudioFiles
        librarySearch.setScopeFiles(previewFiles)
        fileDisplayNames.merge(displayNames) { _, new in new }
        if !listsUnchanged || !titlesUnchanged {
            libraryRevision &+= 1
        }
        return previewFiles
    }

    private func haveSameStandardizedURLs(_ lhs: [URL], _ rhs: [URL]) -> Bool {
        lhs.map(\.standardizedFileURL) == rhs.map(\.standardizedFileURL)
    }

    private func loadSelectedFile(url: URL) {
        let source = PreviewSource.file(url)
        let token = beginPreviewLoad(to: source)
        newFileWarning = nil
        let kind = LibraryFileKind(url: url)
        DispatchQueue.global(qos: .userInitiated).async {
            switch kind {
            case .pdf:
                guard let pageCount = PDFSlideCatalog.pageCount(for: url) else {
                    DispatchQueue.main.async {
                        failPreviewLoad(token: token, source: source)
                    }
                    return
                }
                if PDFSlideCatalog.shouldUseVirtualCatalog(pageCount: pageCount) {
                    let pdfSource = PDFSlideSource(url: url, pageCount: pageCount)
                    DispatchQueue.main.async {
                        guard completePreviewLoad(token: token, source: source) else { return }
                        applyPreviewPDFLoad(source: pdfSource)
                    }
                } else {
                    let slides = buildPDFSlides(pageCount: pageCount, url: url)
                    DispatchQueue.main.async {
                        guard completePreviewLoad(token: token, source: source) else { return }
                        applyPreviewMediaLoad(slides: slides)
                    }
                }
            case .image:
                let slides = buildImageSlides(from: url)
                DispatchQueue.main.async {
                    guard completePreviewLoad(token: token, source: source) else { return }
                    applyPreviewMediaLoad(slides: slides)
                }
            case .video:
                let slides = buildVideoSlides(from: url)
                DispatchQueue.main.async {
                    guard completePreviewLoad(token: token, source: source) else { return }
                    applyPreviewMediaLoad(slides: slides)
                }
            case .audio:
                DispatchQueue.main.async {
                    failPreviewLoad(token: token, source: source)
                }
                return
            case .txt:
                guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                    DispatchQueue.main.async {
                        failPreviewLoad(token: token, source: source)
                    }
                    return
                }
                let doc = LyricsParser.parseDocument(contents, fileName: url.lastPathComponent)
                DispatchQueue.main.async {
                    guard completePreviewLoad(token: token, source: source) else { return }
                    applyPreviewLyricsLoad(slides: doc.slides)
                }
            case .unsupported:
                DispatchQueue.main.async {
                    failPreviewLoad(token: token, source: source)
                }
                return
            }
        }
    }

    private func applyPreviewMediaLoad(slides: [Slide]) {
        lyricsEditor.endEditing()
        setPreviewSlides(slides)
    }

    private func applyPreviewPDFLoad(source: PDFSlideSource) {
        lyricsEditor.endEditing()
        setPreviewPDFSource(source)
    }

    private func applyPreviewLyricsLoad(slides: [Slide]) {
        lyricsEditor.endEditing()
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
            isEditorPreviewAreaCollapsed = false
        }
        flow.setPreviewSlides(
            slides,
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    private func setPreviewPDFSource(
        _ source: PDFSlideSource,
        preferredSelectionIndex: Int? = nil
    ) {
        isEditorPreviewAreaCollapsed = false
        flow.setPreviewPDFSource(source, preferredSelectionIndex: preferredSelectionIndex)
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
        cancelFileImport()
        importPanel.cancel()
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
            restoreBackgroundAudioSelection(nil)
            return
        }
        if let result = SecurityScopedBookmarks.resolve(backgroundAudioBookmark) {
            if let updated = result.updatedBookmark {
                backgroundAudioBookmark = updated
            }
            restoreBackgroundAudioSelection(result.url)
        } else {
            restoreBackgroundAudioSelection(nil)
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

    private func updateBackgroundAudioAccess(_ url: URL?) {
        let didChangeAccess = securityScopedBackgroundAudio != url
        if didChangeAccess {
            securityScopedBackgroundAudio?.stopAccessingSecurityScopedResource()
        }
        securityScopedBackgroundAudio = url
        if didChangeAccess, let url {
            _ = url.startAccessingSecurityScopedResource()
        }
    }

    private func applyBackgroundAudioSelection(_ url: URL?, autoplay: Bool) {
        session.setBackgroundAudioLoop(backgroundAudioLoop)
        session.setBackgroundAudioVolume(backgroundAudioVolume)
        session.setBackgroundAudio(url: url, autoplay: autoplay)
    }

    private func restoreBackgroundAudioSelection(_ url: URL?) {
        updateBackgroundAudioAccess(url)
        deferSessionChange {
            applyBackgroundAudioSelection(url, autoplay: false)
        }
    }

    private func selectBackgroundAudio(_ url: URL) {
        importSelectionGeneration = UUID()
        updateBackgroundAudioAccess(url)
        applyBackgroundAudioSelection(url, autoplay: true)
        if let bookmark = SecurityScopedBookmarks.createBookmark(for: url) {
            backgroundAudioBookmark = bookmark
        }
    }

    private func clearBackgroundVisual() {
        updateBackgroundVisualSelection(nil)
        backgroundVisualBookmark = ""
    }

    private func clearBackgroundAudio() {
        importSelectionGeneration = UUID()
        updateBackgroundAudioAccess(nil)
        applyBackgroundAudioSelection(nil, autoplay: false)
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
        let standardizedURL = url.standardizedFileURL
        if let name = fileDisplayNames[standardizedURL], !name.isEmpty { return name }
        return standardizedURL.lastPathComponent
    }

    private var playlistResolvedURLs: [URL] {
        playlistStore.entries.compactMap { playlistStore.resolvedURL(for: $0) }
    }

    @MainActor
    private func presentLibrarySearch() {
        InterfaceMotion.search.animate(reduceMotion: reduceMotion) {
            isLibrarySearchPresented = true
        }
        librarySearch.syncSelectedResult(
            currentSelectedURL: currentSelectedURL,
            preferFirstResult: true
        )
    }

    @MainActor
    private func dismissLibrarySearch() {
        InterfaceMotion.search.animate(reduceMotion: reduceMotion) {
            isLibrarySearchPresented = false
        }
    }

    @MainActor
    private func previewLibrarySearchResult(_ url: URL) {
        dismissLibrarySearch()

        if let root = libraryRootURL, folderURL?.standardizedFileURL != root.standardizedFileURL {
            folderURL = root
            loadMarkdownFiles(from: root)
        }

        handleSidebarSelectionRequest(.library(url))
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

        newFileWarning = playlistStore.lastError
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
            requestEditorExit(.newLyrics)
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
        let missing = urls
            .map(\.standardizedFileURL)
            .filter { fileDisplayNames[$0] == nil }
        guard !missing.isEmpty else { return }
        let names = libraryFileScanner.displayNames(for: missing)
        fileDisplayNames.merge(names) { _, new in new }
    }

    private func loadPlaylists() {
        guard playlistStore.load(fromRoot: libraryRootURL) else {
            newFileWarning = playlistStore.lastError
            return
        }
        selectedPlaylistEntryIDs = selectedPlaylistEntryIDs.intersection(Set(playlistStore.entries.map(\.id)))
        if let selectedPlaylistEntryID,
           !playlistStore.entries.contains(where: { $0.id == selectedPlaylistEntryID }) {
            setSidebarSelectionWithoutLoading(nil)
        }
        rebuildDisplayNames(for: playlistResolvedURLs)
    }

    private func addLibraryItemToPlaylist(_ source: URL) {
        guard libraryRootURL != nil else {
            newFileWarning = "Set a library root before adding to playlists."
            return
        }

        if playlistStore.add(url: source, after: selectedPlaylistEntryID) != nil {
            newFileWarning = nil
            loadPlaylists()
            return
        }

        newFileWarning = playlistStore.lastError
    }

    private func removeSelectedFromPlaylist() {
        guard !selectedPlaylistEntryIDs.isEmpty else { return }
        guard playlistStore.remove(ids: selectedPlaylistEntryIDs) else {
            newFileWarning = playlistStore.lastError
            return
        }
        newFileWarning = nil
        if selectedPlaylistEntryID != nil {
            setSidebarSelectionWithoutLoading(nil)
        } else {
            selectedPlaylistEntryIDs = []
        }
        loadPlaylists()
    }

    private func removePlaylistItem(_ id: UUID) {
        guard playlistStore.remove(ids: [id]) else {
            newFileWarning = playlistStore.lastError
            return
        }
        newFileWarning = nil
        selectedPlaylistEntryIDs.remove(id)
        if selectedPlaylistEntryID == id {
            setSidebarSelectionWithoutLoading(nil)
        }
        loadPlaylists()
    }

    private func moveSelectedPlaylistEntriesUp() {
        guard !selectedPlaylistEntryIDs.isEmpty else { return }
        guard playlistStore.moveUp(ids: selectedPlaylistEntryIDs) else {
            newFileWarning = playlistStore.lastError
            return
        }
        newFileWarning = nil
        loadPlaylists()
    }

    private func moveSelectedPlaylistEntriesDown() {
        guard !selectedPlaylistEntryIDs.isEmpty else { return }
        guard playlistStore.moveDown(ids: selectedPlaylistEntryIDs) else {
            newFileWarning = playlistStore.lastError
            return
        }
        newFileWarning = nil
        loadPlaylists()
    }

    private func refreshLibrary() {
        if let root = libraryRootURL {
            ensurePlaylistDirectory(in: root)
            folderURL = root
            loadMarkdownFiles(
                from: root,
                refreshSearchResults: true
            )
            loadPlaylists()
            return
        }
        isLibraryLoading = false
        libraryLoadFailure = nil
        loadPlaylists()
    }

    private func toggleBackgroundAudioPlayback() {
        importSelectionGeneration = UUID()
        deferSessionChange {
            if session.isBackgroundAudioPlaying {
                session.pauseBackgroundAudio()
            } else {
                session.playBackgroundAudio()
            }
        }
    }

    private func stopBackgroundAudioPlayback() {
        importSelectionGeneration = UUID()
        deferSessionChange {
            session.stopBackgroundAudioPlayback()
        }
    }

    private func seekBackgroundAudio(to time: Double) {
        importSelectionGeneration = UUID()
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

    @discardableResult
    private func handleSidebarSelectionRequest(
        _ selection: SidebarSelection?,
        playlistEntryIDs: Set<UUID> = []
    ) -> Bool {
        // An explicit same-file selection also supersedes import auto-opening.
        importSelectionGeneration = UUID()
        let request = SidebarSelectionRequest(
            selection: selection,
            playlistEntryIDs: playlistEntryIDs
        )

        guard selection != sidebarSelection else {
            selectedPlaylistEntryIDs = playlistEntryIDs
            guard !lyricsEditor.isEditing, let selection else { return true }
            applySidebarSelection(selection)
            return true
        }

        guard selection != nil else {
            guard !lyricsEditor.isEditing else { return false }
            setSidebarSelectionWithoutLoading(nil)
            return true
        }

        if lyricsEditor.isEditing {
            return requestEditorExit(.sidebarSelection(request))
        }

        commitSidebarSelection(request)
        return true
    }

    private func commitSidebarSelection(_ request: SidebarSelectionRequest) {
        sidebarSelection = request.selection
        selectedPlaylistEntryIDs = request.playlistEntryIDs
        guard let selection = request.selection else { return }
        applySidebarSelection(selection)
    }

    private func applySidebarSelection(_ selection: SidebarSelection) {
        switch selection {
        case .library(let url):
            selectedPlaylistEntryIDs = []
            loadSelectedFile(url: url)
        case .playlist(let id):
            guard let url = playlistStore.resolvedURL(for: id) else { return }
            if selectedPlaylistEntryIDs.isEmpty {
                selectedPlaylistEntryIDs = [id]
            }
            loadSelectedFile(url: url)
        case .window(let windowID):
            loadWindowPreview(for: windowID)
        }
    }

    private var currentSelectedURL: URL? {
        switch sidebarSelection {
        case .library(let url):
            return url
        case .playlist(let id):
            return playlistStore.resolvedURL(for: id)
        default:
            return nil
        }
    }

    private var selectedPlaylistEntryID: UUID? {
        guard case .playlist(let id) = sidebarSelection else { return nil }
        return id
    }

    private func saveEditorDraft() -> Bool {
        guard lyricsEditor.isEditing else { return false }
        guard lyricsEditor.hasLoadableDraft else {
            newFileWarning = "Add some content before saving lyrics."
            return false
        }
        if editorSourceURL != nil, !lyricsEditor.isDirty {
            return true
        }
        if editorSourceURL == nil {
            return createNewFile()
        }
        return saveCurrentFile()
    }

    private func createNewFile() -> Bool {
        guard !isCurrentSelectionMediaFile else { return false }
        let baseDir = libraryRootURL ?? URL(fileURLWithPath: NSString(string: "~/Documents/eucaly").expandingTildeInPath)
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        if lyricsEditor.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            newFileWarning = "Add some content before creating a new file."
            return false
        }
        newFileWarning = nil

        let panel = NSSavePanel()
        panel.directoryURL = baseDir
        panel.nameFieldStringValue = suggestedFileName(from: lyricsEditor.draft) + ".txt"
        panel.allowedContentTypes = [UTType.plainText]
        panel.allowsOtherFileTypes = false
        let saveDelegate = NewLyricsSavePanelDelegate(libraryRootURL: libraryRootURL)
        panel.delegate = saveDelegate

        let response = withExtendedLifetime(saveDelegate) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return false }

        do {
            // The selected URL is also the native panel's overwrite-confirmed target.
            let fileURL = try NewLyricsSavePolicy.validatedDestination(url, libraryRootURL: libraryRootURL)
            let parentDir = fileURL.deletingLastPathComponent()
            let rootURL = libraryRootURL
            let didAccessRoot = rootURL?.startAccessingSecurityScopedResource() ?? false
            let didAccessParent = parentDir.startAccessingSecurityScopedResource()
            defer {
                if didAccessParent { parentDir.stopAccessingSecurityScopedResource() }
                if didAccessRoot { rootURL?.stopAccessingSecurityScopedResource() }
            }

            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            try lyricsEditor.draft.write(to: fileURL, atomically: true, encoding: .utf8)
            lyricsEditor.markSaved(to: fileURL)
            if let root = libraryRootURL {
                libraryRootPath = root.path
                folderURL = root
                loadMarkdownFiles(
                    from: root,
                    refreshSearchResults: true
                )
            }
            loadPlaylists()
            setSidebarSelectionWithoutLoading(.library(fileURL))
            libraryScrollRequest = LibraryScrollRequest(url: fileURL)
            _ = syncEditorDraftToPreview()
            return true
        } catch {
            newFileWarning = "Could not save file: \(error.localizedDescription)"
            return false
        }
    }

    private func suggestedFileName(from text: String) -> String {
        let lines = LyricsTextSanitizer.normalizeLineEndings(text)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        guard let first = lines.first(where: { !LyricsTextSyntax.isBlank($0) }) else { return "Untitled" }
        return sanitizedFileName(LyricsTextSyntax.explicitTitle(first) ?? first)
    }

    private func sanitizedFileName(_ raw: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = raw.components(separatedBy: invalid).joined(separator: " ")
        let collapsed = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? "Untitled" : collapsed
    }

    private func formatEditorDraft() {
        guard !isCurrentSelectionMediaFile, lyricsEditorFocusController.formatLyrics() else { return }
        _ = syncEditorDraftToPreview()
    }

    private func saveCurrentFile() -> Bool {
        guard !isCurrentSelectionMediaFile, let url = editorSourceURL else { return false }
        let documentID = lyricsEditor.documentID
        let draft = lyricsEditor.draft
        let baseline = lyricsEditor.savedText
        let controlsWindow = workspaceCommands.window
        let isStillCurrent = {
            controlsWindow != nil && workspaceCommands.window === controlsWindow
                && lyricsEditor.isEditing && lyricsEditor.documentID == documentID
                && lyricsEditor.sourceURL == url && lyricsEditor.draft == draft && lyricsEditor.savedText == baseline
        }
        do {
            guard try LyricsFileSave.save(draft, replacing: baseline, at: url, isStillCurrent: isStillCurrent,
                                         confirmOverwrite: { confirmLyricsOverwrite(url) }), isStillCurrent() else { return false }
            lyricsEditor.markSaved(to: url)
            if let folderURL {
                loadMarkdownFiles(
                    from: folderURL,
                    refreshSearchResults: true
                )
            } else {
                rebuildDisplayNames(for: [url] + playlistResolvedURLs)
            }
            newFileWarning = nil
            _ = syncEditorDraftToPreview()
            return true
        } catch {
            newFileWarning = "Could not save file: \(error.localizedDescription)"
            return false
        }
    }

    private func confirmLyricsOverwrite(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Overwrite changes to \(url.lastPathComponent)?"
        alert.informativeText = "This file has changed since you opened it. Overwrite replaces those saved changes with your draft."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Overwrite")
        return alert.runModal() == .alertSecondButtonReturn
    }

    @discardableResult
    private func syncEditorDraftToPreview() -> Bool {
        guard lyricsEditor.hasLoadableDraft else {
            newFileWarning = "Add some content before loading lyrics."
            return false
        }

        let preferredSelectionIndex = currentPreviewSelectionIndex()
        let fileName = lyricsEditor.sourceURL?.lastPathComponent
        let document = LyricsParser.parseDocument(lyricsEditor.draft, fileName: fileName)
        guard !document.slides.isEmpty else {
            newFileWarning = "These lyrics do not contain a slide to load."
            return false
        }

        let source = lyricsEditor.sourceURL.map(PreviewSource.file) ?? .lyrics
        setPreviewSource(source)
        setPreviewSlides(document.slides, preferredSelectionIndex: preferredSelectionIndex)
        lyricsEditor.markPreviewed()
        newFileWarning = nil
        return true
    }

    private func restoreSavedEditorPreview() {
        guard let sourceURL = lyricsEditor.sourceURL else {
            clearPreviewDocument()
            return
        }

        let document = LyricsParser.parseDocument(
            lyricsEditor.savedText,
            fileName: sourceURL.lastPathComponent
        )
        setPreviewSource(.file(sourceURL))
        setPreviewSlides(document.slides)
    }

    private func pickWindowForPreview() {
        guard isWindowCaptureSupported else { return }
        screenCaptureManager.presentWindowPicker(workspaceID: session.outputSourceID,
            replacementProblem: { [weak coordinator = session.outputCoordinator] in
                coordinator?.windowCaptureReplacementProblem()
            })
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
        }
        releaseWindowCaptureSelectionIfUnused()
        if case .window(let selectedID) = sidebarSelection, selectedID == windowID {
            setSidebarSelectionWithoutLoading(nil)
        }
    }

    private func setSidebarSelectionWithoutLoading(_ selection: SidebarSelection?) {
        sidebarSelection = selection
        if case .playlist(let id) = selection {
            selectedPlaylistEntryIDs = [id]
        } else {
            selectedPlaylistEntryIDs = []
        }
    }

    private func loadWindowPreview(for windowID: CGWindowID) {
        setPreviewSource(.window(windowID))
        selectedPlaylistEntryIDs = []
        lyricsEditor.endEditing()

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
    private func beginPreviewLoad(to source: PreviewSource) -> UUID {
        let token = UUID()
        previewLoadToken = token
        pendingPreviewSource = source
        previewLoadError = nil
        return token
    }

    private func previewTransitionIsCurrent(token: UUID, source: PreviewSource) -> Bool {
        previewLoadToken == token && pendingPreviewSource == source
    }

    @discardableResult
    private func completePreviewLoad(token: UUID, source: PreviewSource) -> Bool {
        guard previewTransitionIsCurrent(token: token, source: source) else { return false }
        pendingPreviewSource = nil
        previewSource = source
        previewLoadError = nil
        return true
    }

    private func failPreviewLoad(token: UUID, source: PreviewSource) {
        guard previewTransitionIsCurrent(token: token, source: source) else { return }
        let clearedWindowFromPreview = flow.previewSlides.contains { $0.captureWindowID != nil }
        pendingPreviewSource = nil
        flow.clearPreviewDocument()
        previewLoadError = "Couldn’t load \(previewSourceName(source))."
        if clearedWindowFromPreview {
            releaseWindowCaptureSelectionIfUnused()
        }
    }

    private func setPreviewSource(_ source: PreviewSource) {
        cancelPreviewLoad()
        previewSource = source
        previewLoadError = nil
    }

    private func previewSourceName(_ source: PreviewSource) -> String {
        switch source {
        case .file(let url):
            return url.lastPathComponent
        case .window:
            return "the selected window"
        case .lyrics:
            return "the lyrics draft"
        case .none:
            return "the selected item"
        }
    }

    private func cancelPreviewLoad() {
        previewLoadToken = UUID()
        pendingPreviewSource = nil
    }

    private var isPreviewLoading: Bool {
        pendingPreviewSource != nil
    }

    private var editorSourceURL: URL? {
        lyricsEditor.sourceURL
    }

    private func beginLyricsEditing() {
        importSelectionGeneration = UUID()
        guard canEditSelection, let url = previewLyricsSourceURL() else { return }
        if lyricsEditor.isEditing {
            requestEditorExit(.editLyrics(url))
        } else {
            startLyricsEditing(url: url)
        }
    }

    private func startLyricsEditing(url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            newFileWarning = "Could not open lyrics for editing."
            return
        }

        lyricsEditor.beginEditing(text: contents, sourceURL: url)
        isEditorPreviewAreaCollapsed = false
        newFileWarning = nil
    }

    private func beginCurrentLyricsEditing() {
        importSelectionGeneration = UUID()
        guard canEditCurrentLyrics, let url = currentLyricsSourceURL else { return }
        if lyricsEditor.isEditing {
            requestEditorExit(.editCurrentLyrics(url))
        } else {
            startCurrentLyricsEditing(url: url)
        }
    }

    private func startCurrentLyricsEditing(url: URL) {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            newFileWarning = "Could not open lyrics for editing."
            return
        }

        let doc = LyricsParser.parseDocument(contents, fileName: url.lastPathComponent)
        setPreviewSource(.file(url))
        setSidebarSelectionWithoutLoading(.library(url))
        lyricsEditor.beginEditing(text: contents, sourceURL: url)
        isEditorPreviewAreaCollapsed = false
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


}

extension View {
    func applyToolbarBackgroundIfAvailable() -> some View {
        self.toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
