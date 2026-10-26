import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CoreGraphics
import Combine

public struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let workspaceCommands: OutputWorkspaceCommands
    private let workspaceMenu: OutputWorkspaceMenuController
    @State private var hasInitializedControls = false
    @State private var importPanel = LibraryImportPanelController()
    @State private var fileTrashController = LibraryFileTrashController()
    @State private var importRequestID: UUID?
    @State private var importCancellation: LibraryImportCancellation?
    @State private var isImporting = false
    @State private var importSelectionGeneration = UUID()
    @State private var lyricsEditor = LyricsEditorSession()
    @State private var lyricsEditorFocusController = PlainTextEditorFocusController()
    @State private var lyricsCleanupController = LyricsCleanupController()
    @StateObject private var session: PresentationSession
    @ObservedObject private var outputProfiles: OutputProfileStore
    @ObservedObject private var backgroundSettings: WorkspaceBackgroundSettings
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
    @AppStorage("thumbnailScale") private var thumbnailScale: Double = 1.0
    @AppStorage("windowCaptureFrameRate") private var windowCaptureFrameRate: Int = 30
    @State private var backgroundAudioVolumeDraft: Double = 1.0
    @State private var backgroundAudioVolumeDebounceToken = UUID()
    @State private var fileDisplayNames: [URL: String] = [:]
    @State private var newFileWarning: String? = nil
    @State private var sidebarSelection: SidebarSelection? = nil
    @State private var selectedAudioURL: URL? = nil
    @State private var librarySearch = LibrarySearchModel()
    @State private var libraryScrollRequest: LibraryScrollRequest?
    private let libraryInventory = LibraryInventoryStore.shared
    @State private var appliedInventoryRevision: UInt64?
    @State private var isLibraryLoading: Bool = false
    @State private var libraryLoadFailure: LibraryLoadFailure?
    @State private var libraryRevision: Int = 0
    @State private var displayedLibraryRootURL: URL? = nil
    @State private var lyricsProjectionSize: CGSize?
    @FocusState private var focusedDetailTarget: DetailFocusTarget?
    @State private var securityScopedRoot: URL? = nil
    @StateObject private var screenCaptureManager = ScreenCaptureManager.shared
    @EnvironmentObject private var appUpdateViewModel: AppUpdateViewModel
    @State private var isEditorPreviewAreaCollapsed: Bool = false
    private let playlistDirectoryName = "Playlist"
    private let windowCaptureFrameRateOptions = [24, 30, 60]
    private let libraryFileScanner = LibraryFileScannerService()

    init(session: PresentationSession, commands: OutputWorkspaceCommands, workspaceMenu: OutputWorkspaceMenuController) {
        self.projectionDisplays = session.outputCoordinator.displays
        workspaceCommands = commands
        self.workspaceMenu = workspaceMenu
        _session = StateObject(wrappedValue: session)
        _flow = StateObject(wrappedValue: session.outputCoordinator.program(session.outputSourceID).flow)
        _outputProfiles = ObservedObject(wrappedValue: session.outputCoordinator.profiles)
        _backgroundSettings = ObservedObject(wrappedValue: session.backgroundSettings)
    }

    private var backgroundAudioVolume: Double { backgroundSettings.values.audioVolume }
    private var backgroundAudioLoop: Bool { backgroundSettings.values.audioLoop }

    private typealias PreviewSource = PresentationFlowController.PreviewSource
    private var previewSource: PreviewSource {
        get { flow.previewSource }
    }
    private var previewLoadToken: UUID { flow.previewLoadToken }
    private var previewLoadError: String? { flow.previewLoadError }
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
            .onChange(of: lyricsEditor.documentID) { _, _ in lyricsCleanupController.cancel() }
            .onChange(of: lyricsEditor.isEditing) { _, isEditing in
                if !isEditing { lyricsCleanupController.cancel() }
            }
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
                                                 willClose: handleControlsWillClose,
                                                 editorFileURL: { lyricsEditor.isEditing ? lyricsEditor.sourceURL : nil },
                                                 canSaveLyrics: { hasActiveEditorPane && canSaveEditorContent },
                                                 didRemoveFile: handleRemovedLibraryFile)
                    .frame(width: 0, height: 0)
            )
    }

    private var rootSplitView: some View {
        rootSplitWithNotificationObservers
    }

    private var rootSplitBase: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                OutputWorkspaceNavigationHeader(controls: workspaceMenu)
                sidebarPane
            }
            .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 520)
        } detail: {
            detailPane
        }
        .navigationSplitViewStyle(.balanced)
        .modifier(PresentationToolbar(session: session, updates: appUpdateViewModel,
            toggleSlides: toggleSlidesFromUI, searchLibrary: presentLibrarySearch,
            manageOutputs: showOutputSettings))
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
        .onChange(of: playlistStore.entries) { _, _ in
            reconcilePlaylistSelection()
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
        workspaceCommands.librarySearchPresenter.dismiss()
        lyricsCleanupController.cancel()
        fileTrashController.cancel()
        importPanel.cancel()
        cancelFileImport()
        cancelPreviewLoad()
        librarySearch.cancelDebounce()
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
            .onReceive(libraryInventory.changes, perform: applyLibraryInventory)
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
            onMoveFileToTrash: moveLibraryFileToTrash,
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
            setBackgroundAudioLoop: { session.setBackgroundAudioLoop($0) },
            setBackgroundAudioVolumeDraft: { backgroundAudioVolumeDraft = $0 },
            setWindowCaptureFrameRate: { windowCaptureFrameRate = $0 }
        ))

    }

    @ViewBuilder
    private var detailPane: some View {
        detailView
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
        loadPlaylists()
        selectedAudioURL = session.backgroundAudioURL?.standardizedFileURL
        backgroundAudioVolumeDraft = backgroundAudioVolume
    }

    private func handleBackgroundAudioVolumeChange(_ newValue: Double) {
        if abs(backgroundAudioVolumeDraft - newValue) > 0.0001 {
            backgroundAudioVolumeDraft = newValue
        }
    }

    private func handleCaptureWindowsUpdate(_ windows: [ScreenCaptureManager.CapturedWindow]) {
        guard isWindowCaptureSupported else { return }
        let windowIDs = Set(windows.map(\.windowID))
        if case .window(let currentID) = sidebarSelection,
           !windowIDs.contains(currentID) {
            setSidebarSelectionWithoutLoading(nil)
        }
        if flow.clearUnavailableWindowPreview(availableWindowIDs: windowIDs) {
            lyricsEditor.invalidatePreview()
            releaseWindowCaptureSelectionIfUnused()
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
            session.outputCoordinator.clearAllLayers(for: session)
        }
    }

    private func handleClearBackgroundVisualNotification(_ notification: Notification) {
        guard workspaceCommands.isActive else { return }
        deferSessionChange {
            session.outputCoordinator.clearBackgrounds(for: session)
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
                canPreviewDraft: lyricsEditor.canPreviewDraft,
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
        editorSourceURL == nil ? "Save As…" : "Save"
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
        case .previewDraft:
            guard hasActiveEditorPane, lyricsEditor.canPreviewDraft else { return }
            _ = syncEditorDraftToPreview()
        case .format:
            formatEditorDraft()
        case .cleanUp:
            cleanUpEditorDraft()
        case .clear:
            guard hasActiveEditorPane, !lyricsEditor.draft.isEmpty else { return }
            if !lyricsEditorFocusController.clearLyrics() { lyricsEditor.clearDraft() }
            clearPreviewDocument()
        }
    }

    @discardableResult
    private func requestEditorExit(_ action: EditorExitAction) -> Bool {
        lyricsCleanupController.cancel()
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

    @discardableResult
    private func commitCurrentSlides(
        _ slides: [Slide],
        lyricsSourceURL: URL? = nil,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) -> Bool {
        flow.setCurrentSlides(
            slides,
            in: session,
            lyricsSourceURL: lyricsSourceURL,
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    @discardableResult
    private func commitCurrentPDFSource(
        _ source: PDFSlideSource,
        preferredSelection: Slide.ID? = nil,
        preferredSelectionIndex: Int? = nil
    ) -> Bool {
        flow.setCurrentPDFSource(
            source,
            in: session,
            preferredSelection: preferredSelection,
            preferredSelectionIndex: preferredSelectionIndex
        )
    }

    private func clearPreviewDocument() {
        let clearedWindowFromPreview = flow.previewSlides.contains { $0.captureWindowID != nil }
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
        guard flow.referencedFileURLs.allSatisfy({ permitFileUse($0) }),
              permitFileUse(lyricsEditor.isEditing ? lyricsEditor.sourceURL : nil) else { return }

        if lyricsEditor.isEditing {
            guard commitCurrentSlides(
                flow.previewSlides,
                lyricsSourceURL: lyricsEditor.sourceURL,
                preferredSelection: flow.previewSelectionID
            ) else { return }
            session.setCurrentResourceScope(securityScopedRoot)
            flow.isCurrentCollapsed = false
            focusedDetailTarget = .currentThumbnails
            session.requestCurrentProjection()
            return
        }

        guard !flow.previewIsEmpty else { return }
        if let pdfSource = flow.previewPDFSource {
            guard commitCurrentPDFSource(
                pdfSource,
                preferredSelection: flow.previewSelectionID
            ) else { return }
        } else {
            guard commitCurrentSlides(
                flow.previewSlides,
                lyricsSourceURL: previewLyricsSourceURL(),
                preferredSelection: flow.previewSelectionID
            ) else { return }
        }
        session.setCurrentResourceScope(securityScopedRoot)
        clearPreviewDocument()
        flow.isCurrentCollapsed = false
        isEditorPreviewAreaCollapsed = true
        focusedDetailTarget = .currentThumbnails
        session.requestCurrentProjection()
    }

    private var canLoadPreviewToCurrent: Bool {
        guard flow.canLoadPreview else { return false }
        if lyricsEditor.isEditing {
            return lyricsEditor.isPreviewSynchronized
        }
        return true
    }

    private var loadToCurrentHelp: String {
        if isPreviewLoading {
            return "Wait for Preview to finish loading."
        }
        if previewLoadError != nil {
            return "Resolve the Preview load error before loading to Current."
        }
        if lyricsEditor.isEditing && !lyricsEditor.isPreviewSynchronized {
            return lyricsEditor.hasLoadableDraft
                ? "Choose Preview Draft to update Preview before loading to Current."
                : "Add lyrics, then choose Preview Draft before loading to Current."
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
        importPanel.present(source: source, for: window, isCurrent: { workspaceCommands.window === window }) { urls in
            guard workspaceCommands.window === window,
                  libraryRootURL?.standardizedFileURL == root.standardizedFileURL else { return }
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
            guard !cancellation.isCancelled,
                  libraryRootURL?.standardizedFileURL == root.standardizedFileURL else { return }
            if !result.importedURLs.isEmpty {
                folderURL = root
                // The import service already publishes this completed mutation.
                if let snapshot = libraryInventory.snapshot(root: root) { applyLibraryInventory(snapshot) }
                loadPlaylists()
                // Copying can finish after the operator has selected or edited
                // something else. Keep the files and refresh, but preserve that
                // newer intent instead of opening a document or starting music.
                // Parked controls still own import results and inline feedback.
                // Follow-up selection can prompt to save or start audio, so it
                // additionally requires the requesting controls to remain active.
                let maySelectImport = workspaceCommands.isActive
                    && importSelectionGeneration == selectionGeneration
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

    private func moveLibraryFileToTrash(_ url: URL) {
        guard let root = libraryRootURL, let window = workspaceCommands.window else { return }
        let isCurrent = {
            workspaceCommands.window === window
                && libraryRootURL?.standardizedFileURL == root.standardizedFileURL
                && markdownFiles.contains { $0.standardizedFileURL == url.standardizedFileURL }
        }
        guard isCurrent() else { return }
        newFileWarning = nil
        fileTrashController.present(url: url, under: root, for: window, workspace: workspaceCommands,
                                    knownFileURLs: Set(markdownFiles),
                                    isCurrent: isCurrent, reportError: { newFileWarning = $0 })
    }

    private func handleRemovedLibraryFile(_ candidate: LibraryFileActionService.Candidate) {
        guard libraryRootURL?.standardizedFileURL == candidate.rootURL.standardizedFileURL
                || markdownFiles.contains(where: candidate.matches) else { return }
        importSelectionGeneration = UUID()
        if case .library(let url) = sidebarSelection, candidate.matches(url) {
            setSidebarSelectionWithoutLoading(nil)
        }
        if let selectedAudioURL, candidate.matches(selectedAudioURL) { self.selectedAudioURL = nil }
        // Current and active editors were checked before admission. The core
        // has already retired only this source's accepted/pending Preview.
        refreshLibrary()
    }

    private func permitFileUse(_ url: URL?) -> Bool {
        guard let url, let problem = session.outputCoordinator.fileAdmissionProblem(for: url) else { return true }
        newFileWarning = problem
        return false
    }

    private func loadMarkdownFiles(from folder: URL) {
        libraryInventory.refresh(root: folder)
    }

    private func applyLibraryInventory(_ snapshot: LibraryInventoryStore.Snapshot) {
        guard libraryRootURL?.standardizedFileURL == snapshot.root else { return }
        let rootChanged = displayedLibraryRootURL != snapshot.root
        if rootChanged { appliedInventoryRevision = nil }
        _ = applyLibraryMetadata(snapshot.metadata, for: snapshot.root)
        isLibraryLoading = snapshot.isLoading
        libraryLoadFailure = snapshot.failure
        librarySearch.setIndexing(snapshot.isLoading)
        if !snapshot.isLoading, appliedInventoryRevision != snapshot.revision {
            appliedInventoryRevision = snapshot.revision
            // Content/title edits can retain identical URLs. Refresh each private
            // query against the newly committed index without resetting it.
            librarySearch.refreshSearch(currentSelectedURL: currentSelectedURL)
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


    private func loadSelectedFile(url: URL) {
        guard permitFileUse(url) else { return }
        let source = PreviewSource.file(url)
        let token = beginPreviewLoad(to: source)
        newFileWarning = nil
        let kind = LibraryFileKind(url: url)
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try LibraryFileAdmission.requireReadableRegularFile(at: url)
            } catch {
                DispatchQueue.main.async {
                    failPreviewLoad(token: token, source: source)
                }
                return
            }
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
        fileTrashController.cancel()
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

    private func updateLibraryRootAccess(_ url: URL?) {
        guard securityScopedRoot != url else { return }
        fileTrashController.cancel()
        securityScopedRoot?.stopAccessingSecurityScopedResource()
        securityScopedRoot = url
        if let url {
            _ = url.startAccessingSecurityScopedResource()
        }
    }

    private func releaseSecurityScopedAccess() {
        securityScopedRoot?.stopAccessingSecurityScopedResource()
        securityScopedRoot = nil
    }

    private func selectBackgroundAudio(_ url: URL) {
        guard permitFileUse(url) else { return }
        importSelectionGeneration = UUID()
        session.selectBackgroundAudio(url)
    }

    @discardableResult
    private func clearBackgroundAudio() -> Bool {
        importSelectionGeneration = UUID()
        return session.clearBackgroundAudio()
    }

    private func applyBackgroundAudioVolume(_ value: Double) {
        let clamped = min(max(value, 0.0), 1.0)
        deferSessionChange {
            if !session.setBackgroundAudioVolume(clamped) {
                backgroundAudioVolumeDraft = session.backgroundAudioVolume
            }
        }
    }

    private func configureLibraryRoot(_ root: URL) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: root.path) {
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        ensurePlaylistDirectory(in: root)
        playlistStore.load(fromRoot: root)
        reconcilePlaylistSelection()
        folderURL = root
        libraryInventory.ensureLoaded(root: root)
        if let snapshot = libraryInventory.snapshot(root: root) { applyLibraryInventory(snapshot) }
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
        let presenter = workspaceCommands.librarySearchPresenter
        if presenter.isPresented {
            presenter.focusExistingSearch()
            return
        }
        guard let window = workspaceCommands.window, window.attachedSheet == nil else { return }
        librarySearch.refreshSearch(currentSelectedURL: currentSelectedURL)
        librarySearch.syncSelection(currentSelectedURL: currentSelectedURL, preferFirstResult: true)
        presenter.present(in: window, model: librarySearch,
            currentSelectedURL: { currentSelectedURL }, displayName: { displayName(for: $0) },
            onRunAction: runLibrarySearchAction,
            onOpenResult: previewLibrarySearchResult,
            onAddResultToPlaylist: addLibrarySearchResultToPlaylist)
    }

    @MainActor
    private func previewLibrarySearchResult(_ url: URL) {
        if let root = libraryRootURL, folderURL?.standardizedFileURL != root.standardizedFileURL {
            folderURL = root
            loadMarkdownFiles(from: root)
        }

        handleSidebarSelectionRequest(.library(url))
        libraryScrollRequest = LibraryScrollRequest(url: url)
    }

    @MainActor
    private func addLibrarySearchResultToPlaylist(_ url: URL) -> LibrarySearchPlaylistAddResult {
        guard libraryRootURL != nil else {
            return .failed("Set a library root before adding to playlists.")
        }

        guard playlistStore.add(url: url, after: selectedPlaylistEntryID) != nil else {
            return .failed(playlistStore.lastError ?? "Could not add this file to Playlist.")
        }

        // The store already publishes the committed order. A second disk read
        // must not turn a successful add into an apparent failure and retry.
        reconcilePlaylistSelection()
        rebuildDisplayNames(for: playlistResolvedURLs)
        return .added
    }

    @MainActor
    private func runLibrarySearchAction(_ action: LibraryCommandPaletteAction) {
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
        let loaded = playlistStore.load(fromRoot: libraryRootURL)
        reconcilePlaylistSelection()
        guard loaded else {
            newFileWarning = playlistStore.lastError
            return
        }
        rebuildDisplayNames(for: playlistResolvedURLs)
    }

    private func reconcilePlaylistSelection() {
        let reconciled = PlaylistSelectionReconciliation(
            selectedIDs: selectedPlaylistEntryIDs,
            primaryID: selectedPlaylistEntryID,
            availableIDs: Set(playlistStore.entries.map(\.id))
        )
        if selectedPlaylistEntryIDs != reconciled.selectedIDs {
            selectedPlaylistEntryIDs = reconciled.selectedIDs
        }
        if case .playlist = sidebarSelection, reconciled.primaryID == nil {
            // Removing a saved row retires its sidebar identity, not its accepted
            // Preview or an editor draft. Surviving highlights remain selected.
            sidebarSelection = nil
        }
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
        reconcilePlaylistSelection()
        guard !selectedPlaylistEntryIDs.isEmpty else { return }
        guard playlistStore.remove(ids: selectedPlaylistEntryIDs) else {
            newFileWarning = playlistStore.lastError
            return
        }
        newFileWarning = nil
        loadPlaylists()
    }

    private func removePlaylistItem(_ id: UUID) {
        reconcilePlaylistSelection()
        guard playlistStore.entries.contains(where: { $0.id == id }) else { return }
        guard playlistStore.remove(ids: [id]) else {
            newFileWarning = playlistStore.lastError
            return
        }
        newFileWarning = nil
        loadPlaylists()
    }

    private func moveSelectedPlaylistEntriesUp() {
        reconcilePlaylistSelection()
        let availability = PlaylistMoveAvailability(
            selectedIDs: selectedPlaylistEntryIDs, orderedIDs: playlistStore.entries.map(\.id))
        guard availability.canMoveUp else { return }
        guard playlistStore.moveUp(ids: selectedPlaylistEntryIDs) else {
            newFileWarning = playlistStore.lastError
            return
        }
        newFileWarning = nil
        loadPlaylists()
    }

    private func moveSelectedPlaylistEntriesDown() {
        reconcilePlaylistSelection()
        let availability = PlaylistMoveAvailability(
            selectedIDs: selectedPlaylistEntryIDs, orderedIDs: playlistStore.entries.map(\.id))
        guard availability.canMoveDown else { return }
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
                from: root
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
        guard permitSidebarSelection(selection) else { return false }
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
        guard permitSidebarSelection(request.selection) else { return }
        sidebarSelection = request.selection
        selectedPlaylistEntryIDs = request.playlistEntryIDs
        guard let selection = request.selection else { return }
        applySidebarSelection(selection)
    }

    private func permitSidebarSelection(_ selection: SidebarSelection?) -> Bool {
        switch selection {
        case .library(let url): return permitFileUse(url)
        case .playlist(let id): return permitFileUse(playlistStore.resolvedURL(for: id))
        default: return true
        }
    }

    private func applySidebarSelection(_ selection: SidebarSelection) {
        switch selection {
        case .library(let url):
            selectedPlaylistEntryIDs = []
            loadSelectedFile(url: url)
        case .playlist(let id):
            if selectedPlaylistEntryIDs.isEmpty {
                selectedPlaylistEntryIDs = [id]
            }
            let hadWindowPreview = flow.previewSlides.contains { $0.captureWindowID != nil }
            if !flow.previewPlaylistEntry(id, from: playlistStore, loadFile: loadSelectedFile) {
                lyricsEditor.invalidatePreview()
                if hadWindowPreview { releaseWindowCaptureSelectionIfUnused() }
            }
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
        guard permitFileUse(editorSourceURL) else { return false }
        guard lyricsEditor.hasLoadableDraft else {
            newFileWarning = "Add some content before saving lyrics."
            return false
        }
        guard lyricsEditorFocusController.committedLyrics() == lyricsEditor.draft else {
            newFileWarning = "Finish composing the current text before saving lyrics."
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
        panel.nameFieldStringValue = LyricsFileNaming.suggestedFileName(from: lyricsEditor.draft) + ".txt"
        panel.allowedContentTypes = [UTType.plainText]
        panel.allowsOtherFileTypes = false
        let saveDelegate = NewLyricsSavePanelDelegate(libraryRootURL: libraryRootURL)
        panel.delegate = saveDelegate

        let response = withExtendedLifetime(saveDelegate) { panel.runModal() }
        guard response == .OK, let url = panel.url else { return false }

        do {
            // The selected URL is also the native panel's overwrite-confirmed target.
            let fileURL = try NewLyricsSavePolicy.validatedDestination(url, libraryRootURL: libraryRootURL)
            guard permitFileUse(fileURL) else { return false }
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
            if let rootURL { libraryInventory.refresh(root: rootURL) }
            lyricsEditor.markSaved(to: fileURL)
            if let root = libraryRootURL {
                libraryRootPath = root.path
                folderURL = root
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

    private func cleanUpEditorDraft() {
        guard hasActiveEditorPane, let window = workspaceCommands.window,
              window.isVisible, window.attachedSheet == nil else { return }
        guard let source = lyricsEditorFocusController.committedLyrics(), source == lyricsEditor.draft else {
            newFileWarning = "Finish composing the current text before cleaning up lyrics."
            return
        }
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let documentID = lyricsEditor.documentID
        let sourceURL = editorSourceURL
        lyricsCleanupController.present(source: source, documentID: documentID, sourceFileName: sourceURL?.lastPathComponent, for: window,
            isCurrent: { [weak window] in
                hasActiveEditorPane && lyricsEditor.documentID == documentID && lyricsEditor.draft == source
                    && editorSourceURL == sourceURL
                    && window?.isVisible == true && workspaceCommands.window === window
            }, apply: { proposed in
                guard hasActiveEditorPane, lyricsEditor.documentID == documentID, lyricsEditor.draft == source,
                      editorSourceURL == sourceURL else {
                    return false
                }
                return lyricsEditorFocusController.applyLyricsCleanup(proposed, replacing: source)
            })
    }

    private func formatEditorDraft() {
        guard hasActiveEditorPane else { return }
        do {
            if try LyricsEditorDraftActions.normalizeFormatting(editor: lyricsEditor, focus: lyricsEditorFocusController) {
                newFileWarning = nil
            }
        } catch {
            newFileWarning = error.localizedDescription
        }
    }

    private func saveCurrentFile() -> Bool {
        guard !isCurrentSelectionMediaFile, let url = editorSourceURL else { return false }
        guard permitFileUse(url) else { return false }
        let documentID = lyricsEditor.documentID
        let draft = lyricsEditor.draft
        let baseline = lyricsEditor.savedText
        let controlsWindow = workspaceCommands.window
        let isStillCurrent = {
            controlsWindow != nil && workspaceCommands.window === controlsWindow
                && lyricsEditor.isEditing && lyricsEditor.documentID == documentID
                && lyricsEditor.sourceURL == url && lyricsEditor.draft == draft && lyricsEditor.savedText == baseline
                && session.outputCoordinator.fileAdmissionProblem(for: url) == nil
        }
        do {
            guard try LyricsFileSave.save(draft, replacing: baseline, at: url, isStillCurrent: isStillCurrent,
                                         confirmOverwrite: { confirmLyricsOverwrite(url) }) else { return false }
            if let root = libraryRootURL { libraryInventory.refresh(root: root) }
            guard isStillCurrent() else { return false }
            lyricsEditor.markSaved(to: url)
            if libraryRootURL == nil {
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
        guard hasActiveEditorPane else { return false }
        do {
            guard try LyricsEditorDraftActions.updatePreview(
                editor: &lyricsEditor, focus: lyricsEditorFocusController, flow: flow
            ) else { return false }
            isEditorPreviewAreaCollapsed = false
            newFileWarning = nil
            return true
        } catch {
            newFileWarning = error.localizedDescription
            return false
        }
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
        flow.beginPreviewLoad(to: source)
    }

    @discardableResult
    private func completePreviewLoad(token: UUID, source: PreviewSource) -> Bool {
        if case .file(let url) = source, !permitFileUse(url) {
            if flow.previewLoadToken == token { flow.cancelPreviewLoad() }
            return false
        }
        return flow.completePreviewLoad(token: token, source: source)
    }

    private func failPreviewLoad(token: UUID, source: PreviewSource) {
        let clearedWindowFromPreview = flow.previewSlides.contains { $0.captureWindowID != nil }
        guard flow.failPreviewLoad(token: token, source: source) else { return }
        if clearedWindowFromPreview {
            releaseWindowCaptureSelectionIfUnused()
        }
    }

    private func setPreviewSource(_ source: PreviewSource) {
        flow.setPreviewSource(source)
    }

    private func cancelPreviewLoad() {
        flow.cancelPreviewLoad()
    }

    private var isPreviewLoading: Bool {
        flow.isPreviewLoading
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
        guard permitFileUse(url) else { return }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            newFileWarning = "Could not open lyrics for editing."
            return
        }

        lyricsEditor.beginEditing(text: contents, sourceURL: url)
        isEditorPreviewAreaCollapsed = false
        newFileWarning = lyricsEditor.isDirty
            ? "Characters and line endings were normalized in the draft. Review these pending changes before saving; the saved file has not changed."
            : nil
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
        guard permitFileUse(url) else { return }
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
            newFileWarning = "Could not open lyrics for editing."
            return
        }

        let doc = LyricsParser.parseDocument(contents, fileName: url.lastPathComponent)
        setPreviewSource(.file(url))
        setSidebarSelectionWithoutLoading(.library(url))
        lyricsEditor.beginEditing(text: contents, sourceURL: url)
        isEditorPreviewAreaCollapsed = false
        newFileWarning = lyricsEditor.isDirty
            ? "Characters and line endings were normalized in the draft. Review these pending changes before saving; the saved file has not changed."
            : nil
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

}
