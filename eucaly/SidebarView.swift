import SwiftUI
import AppKit
import CoreGraphics

enum SidebarSelection: Hashable {
    case library(URL)
    case playlist(UUID)
    case web(URL)
    case window(CGWindowID)
}

private enum SidebarSectionTint {
    case library
    case web
    case playlist
    case windows
    case audio

    var color: Color {
        switch self {
        case .library:
            Color(nsColor: .systemTeal)
        case .web:
            Color(nsColor: .systemIndigo)
        case .playlist:
            Color(nsColor: .systemGreen)
        case .windows:
            Color(nsColor: .systemOrange)
        case .audio:
            Color(nsColor: .systemPurple)
        }
    }
}

struct PlaylistSidebarItem: Identifiable, Hashable {
    let id: UUID
    let title: String
    let exists: Bool
}

struct SidebarView: View {
    @ObservedObject var session: PresentationSession
    let isWindowCaptureSupported: Bool
    let libraryFiles: [URL]
    let audioFiles: [URL]
    let isLibraryLoading: Bool
    let libraryLoadFailure: LibraryLoadFailure?
    let libraryRevision: Int
    let playlistItems: [PlaylistSidebarItem]
    let libraryRootURL: URL?
    let captureWindows: [ScreenCaptureManager.CapturedWindow]
    let webpageURLs: [URL]
    let libraryScrollRequest: LibraryScrollRequest?
    let selectedPlaylistEntryIDs: Set<UUID>
    let sidebarSelection: SidebarSelection?
    @Binding var selectedAudioURL: URL?
    @Binding var backgroundAudioLoop: Bool
    @Binding var backgroundAudioVolumeDraft: Double
    @Binding var windowCaptureFrameRate: Int

    let displayName: (URL) -> String
    let titleForWebpage: (URL) -> String
    let onImportToLibrary: () -> Void
    let onRetryLibraryLoad: () -> Void
    let onImportToAudio: () -> Void
    let onAddLibraryItemToPlaylist: (URL) -> Void
    let onRemovePlaylistItem: (UUID) -> Void
    let onRemoveSelectedFromPlaylist: () -> Void
    let onMovePlaylistUp: () -> Void
    let onMovePlaylistDown: () -> Void
    let onSelectBackgroundAudio: (URL) -> Void
    let onPlayPauseBackgroundAudio: () -> Void
    let onStopBackgroundAudio: () -> Void
    let onClearBackgroundAudio: () -> Void
    let onApplyBackgroundAudioVolume: (Double) -> Void
    let onSeekBackgroundAudio: (Double) -> Void
    let onSelectionRequest: (SidebarSelection?, Set<UUID>) -> Bool
    let onOpenWebpageAddress: (String) -> Bool
    let onRemoveWebpage: (URL) -> Void
    let onPickWindow: () -> Void
    let onClearSelectedWindow: () -> Void

    @AppStorage("sidebar.librarySectionExpanded")
    private var isLibrarySectionExpanded = true

    @AppStorage("sidebar.webSectionExpanded")
    private var isWebSectionExpanded = true

    @AppStorage("sidebar.playlistSectionExpanded")
    private var isPlaylistSectionExpanded = true

    @AppStorage("sidebar.windowsSectionExpanded")
    private var isWindowsSectionExpanded = false

    @AppStorage("sidebar.audioSectionExpanded")
    private var isAudioSectionExpanded = false

    @AppStorage("sidebar.libraryGrouping")
    private var libraryGrouping = LibraryGrouping.kind

    @State private var webpageAddressDraft: String = ""

    @State private var webpageAddressError: String? = nil

    @State private var libraryExpansionState = SidebarOutlineExpansionState.empty

    @State private var libraryExpansionCommand: SidebarOutlineExpansionCommand?

    @State private var outlineExpansionStore = SidebarOutlineExpansionStore()

    @State private var outlineNavigationCoordinator = SidebarOutlineNavigationCoordinator()

    @StateObject private var libraryOutlineModelStore = LibraryOutlineModelStore()

    var body: some View {
        GeometryReader { proxy in
            let libraryListMaxHeight = max(160, min(320, proxy.size.height * 0.35))
            let audioListMaxHeight = max(120, min(240, proxy.size.height * 0.25))
            let standardListMaxHeight = max(104, min(208, proxy.size.height * 0.22))
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let libraryLoadFailure {
                        libraryLoadFailureNotice(libraryLoadFailure)
                    }

                    sidebarSection(
                        "Library",
                        systemImage: "folder",
                        tint: .library,
                        isExpanded: $isLibrarySectionExpanded
                    ) {
                        libraryControls
                        libraryContent(maxHeight: libraryListMaxHeight)
                    }

                    sectionDivider

                    sidebarSection(
                        "Playlist",
                        systemImage: "folder",
                        tint: .playlist,
                        isExpanded: $isPlaylistSectionExpanded
                    ) {
                        playlistControls
                        playlistList(maxHeight: standardListMaxHeight)
                    }

                    sectionDivider

                    sidebarSection(
                        "Audio",
                        systemImage: "music.note.list",
                        tint: .audio,
                        isExpanded: $isAudioSectionExpanded
                    ) {
                        audioControls(maxListHeight: audioListMaxHeight)
                    }

                    sectionDivider

                    sidebarSection(
                        "Web",
                        systemImage: "globe",
                        tint: .web,
                        isExpanded: $isWebSectionExpanded
                    ) {
                        webControls(maxListHeight: standardListMaxHeight)
                    }

                    if isWindowCaptureSupported {
                        sectionDivider

                        sidebarSection(
                            "Window",
                            systemImage: "macwindow",
                            tint: .windows,
                            isExpanded: $isWindowsSectionExpanded
                        ) {
                            windowsControls(maxListHeight: standardListMaxHeight)
                        }
                    }

                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, 18)
                .padding(.vertical, 10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(
            VisualEffectView(material: .sidebar, blendingMode: .withinWindow)
                .ignoresSafeArea()
        )
        .controlSize(.small)
        .focusEffectDisabled(true)
        .onChange(of: libraryScrollRequest?.id) { _, _ in
            if libraryScrollRequest != nil {
                isLibrarySectionExpanded = true
            }
        }
        .onChange(of: libraryRevision) { _, _ in
            reconcileAudioSelection()
        }
        .font(.subheadline)
    }

    private var libraryControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    onImportToLibrary()
                } label: {
                    Label("Import...", systemImage: "square.and.arrow.down")
                }
                .sidebarActionStyle(primary: true)
                .disabled(libraryRootURL == nil)
                .help("Import files into Library")

                Text("Group")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Group", selection: $libraryGrouping) {
                    ForEach(LibraryGrouping.allCases) { grouping in
                        Text(grouping.title).tag(grouping)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()

                Button {
                    toggleAllLibraryGroups()
                } label: {
                    Label(
                        allVisibleLibraryGroupsCollapsed ? "Expand Groups" : "Collapse Groups",
                        systemImage: allVisibleLibraryGroupsCollapsed
                            ? "rectangle.expand.vertical"
                            : "rectangle.compress.vertical"
                    )
                }
                .labelStyle(.iconOnly)
                .playlistIconButtonStyle()
                .disabled(!canToggleLibraryGroups)
                .help(libraryGroupToggleHelp)
            }
        }
    }

    private func libraryLoadFailureNotice(_ failure: LibraryLoadFailure) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Library couldn’t be refreshed", systemImage: "exclamationmark.triangle")
                .font(.caption.weight(.semibold))
            Text(failure.url.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(failure.url.path)
            Text(failure.message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            if !libraryFiles.isEmpty || !audioFiles.isEmpty {
                Text("Showing the last available Library and Audio lists.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button("Retry", action: onRetryLibraryLoad)
                .sidebarActionStyle()
                .disabled(isLibraryLoading)
                .help("Refresh Library and Audio")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sidebarSection<Content: View>(
        _ title: String,
        detail: String? = nil,
        systemImage: String,
        tint: SidebarSectionTint,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.wrappedValue.toggle()
            } label: {
                sidebarSectionHeader(
                    title,
                    detail: detail,
                    systemImage: systemImage,
                    tint: tint,
                    isExpanded: isExpanded.wrappedValue
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(SidebarSectionHeaderButtonStyle())
            .focusEffectDisabled(false)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("\(title) section")
            .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
            .accessibilityHint(
                isExpanded.wrappedValue ? "Collapses the section" : "Expands the section"
            )

            if isExpanded.wrappedValue {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func webControls(maxListHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("https://example.com or localhost:8000", text: $webpageAddressDraft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.go)
                    .onSubmit(submitWebpageAddress)

                Button("Open") {
                    submitWebpageAddress()
                }
                .sidebarActionStyle(primary: true)
                .disabled(webpageAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Text("Enter a URL to load it into Preview and save it here. Local server addresses default to http://.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let webpageAddressError {
                Text(webpageAddressError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }

            if webpageURLs.isEmpty {
                Text("No saved webpages")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                webpageList(maxHeight: maxListHeight)
            }
        }
    }

    private func webpageList(maxHeight: CGFloat) -> some View {
        SidebarOutlineView(
            contentRevision: AnyHashable(webpageURLs.map(\.absoluteString)),
            modelBuilder: {
                SidebarOutlineModel(
                    roots: webpageURLs.map { url in
                        SidebarOutlineItem(
                            id: .web(url),
                            title: titleForWebpage(url),
                            accessoryAction: .remove,
                            contextActions: [.copyURL, .remove]
                        )
                    }
                )
            },
            selectedItemIDs: selectedWebItemID.map { [$0] } ?? [],
            primarySelectedItemID: selectedWebItemID,
            expansionStore: outlineExpansionStore,
            navigationSection: .web,
            navigationCoordinator: outlineNavigationCoordinator,
            allowsEmptySelection: true,
            onSelectionChange: { _, primaryID in
                guard primaryID != nil else { return onSelectionRequest(nil, []) }
                guard case .web(let url) = primaryID else { return false }
                return onSelectionRequest(.web(url), [])
            },
            onAction: { itemID, action in
                guard case .web(let url) = itemID else { return }
                switch action {
                case .remove:
                    onRemoveWebpage(url)
                case .copyURL:
                    copyWebpageURL(url)
                case .addToPlaylist, .revealInFinder:
                    break
                }
            }
        )
        .frame(height: outlineHeight(rowCount: webpageURLs.count, maximum: maxHeight))
    }

    private var selectedWebItemID: SidebarOutlineItemID? {
        guard case .web(let url) = sidebarSelection else { return nil }
        return .web(url)
    }

    private func copyWebpageURL(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    private var playlistControls: some View {
        HStack(spacing: 4) {
            Button {
                onRemoveSelectedFromPlaylist()
            } label: {
                Label("Remove Selected", systemImage: "minus.circle")
            }
            .labelStyle(.iconOnly)
            .playlistIconButtonStyle()
            .disabled(selectedPlaylistEntryIDs.isEmpty)
            .help("Remove selected from Playlist")

            Button {
                onMovePlaylistUp()
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .labelStyle(.iconOnly)
            .playlistIconButtonStyle()
            .disabled(selectedPlaylistEntryIDs.isEmpty)
            .help("Move selected up")

            Button {
                onMovePlaylistDown()
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .labelStyle(.iconOnly)
            .playlistIconButtonStyle()
            .disabled(selectedPlaylistEntryIDs.isEmpty)
            .help("Move selected down")
        }
    }

    private func windowsControls(maxListHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(captureWindows.isEmpty ? "Pick Window" : "Replace Window") {
                    onPickWindow()
                }
                .sidebarActionStyle(primary: true)
                .help(captureWindows.isEmpty ? "Choose a window to preview" : "Choose a different window to preview")

                Button {
                    onClearSelectedWindow()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .labelStyle(.iconOnly)
                .sidebarActionStyle()
                .disabled(!hasSelectedWindow)
                .help("Clear selected window")

                Text("FPS")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Frame Rate", selection: $windowCaptureFrameRate) {
                    Text("24").tag(24)
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 104)
                .help("Window capture frame rate")
            }

            if !captureWindows.isEmpty {
                windowList(maxHeight: maxListHeight)
            }
        }
    }

    private func windowList(maxHeight: CGFloat) -> some View {
        SidebarOutlineView(
            contentRevision: AnyHashable(
                captureWindows.map { "\($0.windowID)|\($0.appName)|\($0.title)" }
            ),
            modelBuilder: {
                SidebarOutlineModel(
                    roots: captureWindows.map { window in
                        let title = window.title == window.appName
                            ? window.appName
                            : "\(window.appName): \(window.title)"
                        return SidebarOutlineItem(id: .window(window.windowID), title: title)
                    }
                )
            },
            selectedItemIDs: selectedWindowItemID.map { [$0] } ?? [],
            primarySelectedItemID: selectedWindowItemID,
            expansionStore: outlineExpansionStore,
            navigationSection: .window,
            navigationCoordinator: outlineNavigationCoordinator,
            allowsEmptySelection: true,
            onSelectionChange: { _, primaryID in
                guard primaryID != nil else { return onSelectionRequest(nil, []) }
                guard case .window(let windowID) = primaryID else { return false }
                return onSelectionRequest(.window(windowID), [])
            }
        )
        .frame(height: outlineHeight(rowCount: captureWindows.count, maximum: maxHeight))
    }

    private var selectedWindowItemID: SidebarOutlineItemID? {
        guard case .window(let windowID) = sidebarSelection else { return nil }
        return .window(windowID)
    }

    private var hasSelectedWindow: Bool {
        !captureWindows.isEmpty
    }

    private func audioControls(maxListHeight: CGFloat) -> some View {
        SidebarAudioControlsView(
            session: session,
            audioFiles: audioFiles,
            hasLibraryLoadFailure: libraryLoadFailure != nil,
            maxListHeight: maxListHeight,
            libraryRevision: libraryRevision,
            libraryRootURL: libraryRootURL,
            outlineExpansionStore: outlineExpansionStore,
            backgroundAudioLoop: $backgroundAudioLoop,
            backgroundAudioVolumeDraft: $backgroundAudioVolumeDraft,
            selectedAudioURL: $selectedAudioURL,
            displayName: displayName,
            onImportToAudio: onImportToAudio,
            onSelectBackgroundAudio: onSelectBackgroundAudio,
            onPlayPauseBackgroundAudio: onPlayPauseBackgroundAudio,
            onStopBackgroundAudio: onStopBackgroundAudio,
            onClearBackgroundAudio: onClearBackgroundAudio,
            onApplyBackgroundAudioVolume: onApplyBackgroundAudioVolume,
            onSeekBackgroundAudio: onSeekBackgroundAudio
        )
    }

    private func reconcileAudioSelection() {
        guard let currentSelection = selectedAudioURL else { return }
        let standardizedSelection = currentSelection.standardizedFileURL
        guard !audioFiles.contains(where: { $0.standardizedFileURL == standardizedSelection }) else {
            return
        }
        let activeURL = session.backgroundAudioURL?.standardizedFileURL
        selectedAudioURL = activeURL.flatMap { activeURL in
            audioFiles.contains(where: { $0.standardizedFileURL == activeURL }) ? activeURL : nil
        }
    }

    private func sidebarSectionHeader(
        _ title: String,
        detail: String?,
        systemImage: String,
        tint: SidebarSectionTint,
        isExpanded: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.headline)
                .foregroundStyle(tint.color)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(tint.color.opacity(0.16))
                )

            Text(title)
                .font(.headline)
                .foregroundStyle(.primary)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .layoutPriority(1)
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(.easeInOut(duration: 0.16), value: isExpanded)
                .frame(width: 16, height: 22)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, SidebarHighlightMetrics.horizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 4)
    }

    private var canToggleLibraryGroups: Bool {
        libraryGrouping != .none
            && libraryOutlineModelStore.presentation?.revision == libraryOutlineRevision
            && libraryExpansionState.key == libraryExpansionKey
            && libraryExpansionState.groupCount > 0
    }

    private var libraryGroupToggleHelp: String {
        let action = libraryExpansionState.areAllGroupsCollapsed ? "Expand" : "Collapse"
        switch libraryGrouping {
        case .kind:
            return "\(action) all kinds"
        case .folder:
            return "\(action) all folders"
        case .none:
            return "Choose Kind or Folder grouping to collapse sections"
        }
    }

    private var allVisibleLibraryGroupsCollapsed: Bool {
        libraryExpansionState.key == libraryExpansionKey
            && libraryExpansionState.areAllGroupsCollapsed
    }

    private var libraryExpansionKey: String {
        "library:\(libraryGrouping.rawValue)"
    }

    private func toggleAllLibraryGroups() {
        guard canToggleLibraryGroups else { return }
        libraryExpansionCommand = SidebarOutlineExpansionCommand(
            action: allVisibleLibraryGroupsCollapsed ? .expandAll : .collapseAll
        )
    }

    @ViewBuilder
    private func libraryContent(maxHeight: CGFloat) -> some View {
        let revision = libraryOutlineRevision
        Group {
            if isLibraryLoading && libraryFiles.isEmpty {
                Text("Loading library...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if libraryFiles.isEmpty {
                if libraryLoadFailure == nil {
                    Text("No supported files in Library")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if let presentation = libraryOutlineModelStore.presentation,
                      presentation.revision == revision {
                libraryOutline(presentation, maxHeight: maxHeight)
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Preparing \(libraryGrouping.title) view...")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: revision) {
            guard !libraryFiles.isEmpty else { return }
            await libraryOutlineModelStore.prepare(revision: revision) {
                libraryFiles.map { sourceURL in
                    let url = sourceURL.standardizedFileURL
                    return LibraryOutlineSourceItem(url: url, title: displayName(url))
                }
            }
        }
    }

    private var libraryOutlineRevision: LibraryOutlineRevision {
        LibraryOutlineRevision(
            libraryRevision: libraryRevision,
            grouping: libraryGrouping,
            libraryRootURL: libraryRootURL?.standardizedFileURL
        )
    }

    private func libraryOutline(
        _ presentation: LibraryOutlineModelStore.Presentation,
        maxHeight: CGFloat
    ) -> some View {
        SidebarOutlineView(
            contentRevision: AnyHashable(presentation.revision),
            expansionKey: libraryExpansionKey,
            modelBuilder: { presentation.model },
            selectedItemIDs: selectedLibraryItemID.map { [$0] } ?? [],
            primarySelectedItemID: selectedLibraryItemID,
            scrollRequest: libraryScrollRequest.map {
                SidebarOutlineScrollRequest(
                    id: $0.id,
                    itemID: .library($0.url.standardizedFileURL)
                )
            },
            expansionCommand: libraryExpansionCommand,
            expansionStore: outlineExpansionStore,
            navigationSection: .library,
            navigationCoordinator: outlineNavigationCoordinator,
            allowsEmptySelection: true,
            onSelectionChange: { _, primaryID in
                guard primaryID != nil else { return onSelectionRequest(nil, []) }
                guard case .library(let url) = primaryID else { return false }
                return onSelectionRequest(.library(url), [])
            },
            onAction: { itemID, action in
                guard case .library(let url) = itemID else { return }
                switch action {
                case .addToPlaylist:
                    onAddLibraryItemToPlaylist(url)
                case .revealInFinder:
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                case .remove, .copyURL:
                    break
                }
            },
            onExpansionStateChange: { state in
                guard state.key == libraryExpansionKey else { return }
                guard libraryExpansionState != state else { return }
                libraryExpansionState = state
            }
        )
        .frame(
            maxWidth: .infinity,
            minHeight: libraryOutlineHeight(model: presentation.model, maximum: maxHeight),
            maxHeight: libraryOutlineHeight(model: presentation.model, maximum: maxHeight)
        )
    }

    private func libraryOutlineHeight(model: SidebarOutlineModel, maximum: CGFloat) -> CGFloat {
        if libraryExpansionState.key == libraryExpansionKey {
            return min(maximum, max(26, libraryExpansionState.visibleContentHeight))
        }
        let expandedGroupIDs = outlineExpansionStore.expandedGroupIDs[libraryExpansionKey, default: []]
        let estimatedHeight = CGFloat(model.visibleRowCount(expandedGroupIDs: expandedGroupIDs)) * 26
        return min(maximum, max(26, estimatedHeight))
    }

    private var selectedLibraryItemID: SidebarOutlineItemID? {
        if case .library(let url) = sidebarSelection {
            return .library(url.standardizedFileURL)
        }
        return nil
    }

    @ViewBuilder
    private func playlistList(maxHeight: CGFloat) -> some View {
        if playlistItems.isEmpty {
            Text("No playlist items")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            SidebarOutlineView(
                contentRevision: AnyHashable(playlistItems),
                modelBuilder: {
                    SidebarOutlineModel(
                        roots: playlistItems.map { item in
                            SidebarOutlineItem(
                                id: .playlist(item.id),
                                title: item.title,
                                isMissing: !item.exists,
                                accessoryAction: .remove,
                                contextActions: [.remove]
                            )
                        }
                    )
                },
                selectedItemIDs: Set(selectedPlaylistEntryIDs.map { .playlist($0) }),
                primarySelectedItemID: selectedPlaylistItemID,
                expansionStore: outlineExpansionStore,
                navigationSection: .playlist,
                navigationCoordinator: outlineNavigationCoordinator,
                allowsMultipleSelection: true,
                allowsEmptySelection: true,
                onSelectionChange: { selectedIDs, primaryID in
                    let playlistIDs = Set(selectedIDs.compactMap { itemID -> UUID? in
                        guard case .playlist(let id) = itemID else { return nil }
                        return id
                    })
                    let primaryPlaylistID: UUID? = {
                        guard case .playlist(let id) = primaryID else { return playlistIDs.first }
                        return id
                    }()
                    return onSelectionRequest(
                        primaryPlaylistID.map { .playlist($0) },
                        playlistIDs
                    )
                },
                onAction: { itemID, action in
                    guard case .playlist(let id) = itemID, action == .remove else { return }
                    onRemovePlaylistItem(id)
                }
            )
            .frame(height: outlineHeight(rowCount: playlistItems.count, maximum: maxHeight))
        }
    }

    private var selectedPlaylistItemID: SidebarOutlineItemID? {
        if case .playlist(let id) = sidebarSelection {
            return .playlist(id)
        }
        return nil
    }

    private func outlineHeight(rowCount: Int, maximum: CGFloat) -> CGFloat {
        min(maximum, max(26, CGFloat(rowCount) * 26))
    }

    private func submitWebpageAddress() {
        let candidate = webpageAddressDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }

        if onOpenWebpageAddress(candidate) {
            webpageAddressDraft = ""
            webpageAddressError = nil
        } else {
            webpageAddressError = "Enter a valid http(s) URL or local server address."
        }
    }
}

private extension View {
    func playlistIconButtonStyle() -> some View {
        self
            .buttonStyle(.plain)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 22)
            .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

private struct SidebarSectionHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(SidebarSectionHeaderInteraction(isPressed: configuration.isPressed))
    }
}

private struct SidebarSectionHeaderInteraction: ViewModifier {
    let isPressed: Bool

    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(
                    cornerRadius: SidebarHighlightMetrics.cornerRadius,
                    style: .circular
                )
                    .fill(backgroundColor)
                    .padding(.horizontal, SidebarHighlightMetrics.horizontalInset)
                    .padding(.vertical, SidebarHighlightMetrics.verticalInset)
            )
            .onHover { isHovered = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: isPressed)
    }

    private var backgroundColor: Color {
        guard controlActiveState == .key else { return .clear }

        if isPressed {
            return Color.primary.opacity(Double(SidebarHighlightMetrics.pressedOpacity))
        }
        if isHovered {
            return Color.primary.opacity(Double(SidebarHighlightMetrics.hoverOpacity))
        }
        return .clear
    }
}
