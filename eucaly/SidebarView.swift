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

struct LibraryScrollRequest: Equatable {
    let id = UUID()
    let url: URL
}

private enum LibraryGrouping: String, CaseIterable, Identifiable {
    case kind
    case folder
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .kind:
            "Kind"
        case .folder:
            "Folder"
        case .none:
            "None"
        }
    }
}

private enum LibraryFileGroup: Int, CaseIterable, Identifiable {
    case lyrics
    case pdfs
    case images
    case videos
    case other

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .lyrics:
            "Lyrics"
        case .pdfs:
            "PDFs"
        case .images:
            "Images"
        case .videos:
            "Videos"
        case .other:
            "Other"
        }
    }

    init(url: URL) {
        switch url.pathExtension.lowercased() {
        case "txt":
            self = .lyrics
        case "pdf":
            self = .pdfs
        case "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff":
            self = .images
        case "mp4", "mov", "m4v", "avi", "mkv":
            self = .videos
        default:
            self = .other
        }
    }
}

private struct LibraryFileGroupSection: Identifiable {
    let group: LibraryFileGroup
    let urls: [URL]

    var id: LibraryFileGroup { group }
}

private struct LibraryFolderGroupSection: Identifiable {
    let title: String
    let sortKey: String
    let urls: [URL]

    var id: String { sortKey }
}

private struct LibraryFolderGroupKey: Hashable {
    let title: String
    let sortKey: String
}

struct SidebarView: View {
    @ObservedObject var session: PresentationSession
    let isWindowCaptureSupported: Bool
    let libraryFiles: [URL]
    let audioFiles: [URL]
    let isLibraryLoading: Bool
    let libraryRevision: Int
    let playlistItems: [PlaylistSidebarItem]
    let libraryRootURL: URL?
    let captureWindows: [ScreenCaptureManager.CapturedWindow]
    let webpageURLs: [URL]
    let libraryScrollRequest: LibraryScrollRequest?
    @Binding var selectedPlaylistEntryID: UUID?
    @Binding var selectedPlaylistEntryIDs: Set<UUID>
    @Binding var sidebarSelection: SidebarSelection?
    @Binding var backgroundAudioLoop: Bool
    @Binding var backgroundAudioVolumeDraft: Double
    @Binding var windowCaptureFrameRate: Int
    @FocusState.Binding var isSidebarFocused: Bool

    let displayName: (URL) -> String
    let titleForWebpage: (URL) -> String
    let onImportToLibrary: () -> Void
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
    let onSelectionChange: (SidebarSelection?) -> Void
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

    @State private var playlistSelectionAnchor: UUID?

    @State private var webpageAddressDraft: String = ""

    @State private var webpageAddressError: String? = nil

    @State private var pendingLibraryScrollTarget: URL?

    @State private var keyboardLibraryScrollTarget: URL?

    @State private var collapsedLibraryGroups: Set<LibraryFileGroup> = []

    @State private var collapsedLibraryFolders: Set<String> = []

    @State private var cachedLibraryKindSections: [LibraryFileGroupSection] = []

    @State private var cachedLibraryFolderSections: [LibraryFolderGroupSection] = []

    @State private var displayedLibraryGrouping: LibraryGrouping = .kind

    @State private var isPreparingLibraryGrouping: Bool = false

    @State private var libraryGroupingTransitionTask: Task<Void, Never>? = nil

    var body: some View {
        GeometryReader { proxy in
            let libraryListMaxHeight = max(160, min(320, proxy.size.height * 0.35))
            let audioListMaxHeight = max(120, min(240, proxy.size.height * 0.25))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
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
                        sidebarPlaylistList
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
                        webControls
                    }

                    if isWindowCaptureSupported {
                        sectionDivider

                        sidebarSection(
                            "Window",
                            systemImage: "macwindow",
                            tint: .windows,
                            isExpanded: $isWindowsSectionExpanded
                        ) {
                            windowsControls
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
        .overlay(
            Color.clear
                .frame(width: 1, height: 1)
                .focusable(true)
                .focusEffectDisabled(true)
                .focused($isSidebarFocused)
                .onMoveCommand { direction in
                    guard isSidebarFocused else { return }
                    handleSidebarMoveCommand(direction)
                }
        )
        .onChange(of: sidebarSelection) { _, newValue in
            onSelectionChange(newValue)
        }
        .onAppear {
            displayedLibraryGrouping = libraryGrouping
            rebuildLibraryCaches()
        }
        .onDisappear {
            libraryGroupingTransitionTask?.cancel()
        }
        .onChange(of: libraryRevision) { _, _ in
            rebuildLibraryCaches()
        }
        .onChange(of: libraryScrollRequest?.id) { _, _ in
            if libraryScrollRequest != nil {
                isLibrarySectionExpanded = true
            }
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

                Picker("Group", selection: libraryGroupingBinding) {
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
                .disabled(isPreparingLibraryGrouping || !canToggleLibraryGroups)
                .help(libraryGroupToggleHelp)
            }
        }
    }

    private var libraryGroupingBinding: Binding<LibraryGrouping> {
        Binding(
            get: { libraryGrouping },
            set: { prepareLibraryGroupingChange($0) }
        )
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
                withAnimation(.easeInOut(duration: 0.16)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                sidebarSectionHeader(
                    title,
                    detail: detail,
                    systemImage: systemImage,
                    tint: tint,
                    isExpanded: isExpanded.wrappedValue
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

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

    private var webControls: some View {
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

            ForEach(webpageURLs, id: \.self) { url in
                HStack(spacing: 6) {
                    Button {
                        isSidebarFocused = true
                        let selectionValue = SidebarSelection.web(url)
                        if sidebarSelection == selectionValue {
                            onSelectionChange(selectionValue)
                        } else {
                            sidebarSelection = selectionValue
                        }
                    } label: {
                        sidebarRow(
                            title: titleForWebpage(url),
                            isSelected: sidebarSelection == .web(url)
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())

                    Button {
                        onRemoveWebpage(url)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle()
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Remove webpage")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contextMenu {
                    Button {
                        copyWebpageURL(url)
                    } label: {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }
                }
            }

            if webpageURLs.isEmpty {
                Text("No saved webpages")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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

    private var windowsControls: some View {
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

            if let window = captureWindows.first {
                selectedWindowRow(window)
            }
        }
    }

    private var hasSelectedWindow: Bool {
        !captureWindows.isEmpty
    }

    private func audioControls(maxListHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    onImportToAudio()
                } label: {
                    Label("Import...", systemImage: "square.and.arrow.down")
                }
                .sidebarActionStyle(primary: true)
                .disabled(libraryRootURL == nil)
                .help("Import audio or video files for background audio")

                Button {
                    onPlayPauseBackgroundAudio()
                } label: {
                    Label(session.isBackgroundAudioPlaying ? "Pause" : "Play",
                          systemImage: session.isBackgroundAudioPlaying ? "pause.fill" : "play.fill")
                }
                .labelStyle(.iconOnly)
                .sidebarActionStyle()
                .disabled(session.backgroundAudioURL == nil)
                .help(session.isBackgroundAudioPlaying ? "Pause" : "Play")

                Button {
                    onStopBackgroundAudio()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .labelStyle(.iconOnly)
                .sidebarActionStyle()
                .disabled(session.backgroundAudioURL == nil)
                .help("Stop")

                Button {
                    onClearBackgroundAudio()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .labelStyle(.iconOnly)
                .sidebarActionStyle()
                .disabled(session.backgroundAudioURL == nil)
                .help("Clear audio")

                Toggle(isOn: $backgroundAudioLoop) {
                    Label("Loop", systemImage: "repeat")
                }
                .labelStyle(.iconOnly)
                .toggleStyle(.button)
                .controlSize(.small)
                .disabled(session.backgroundAudioURL == nil)
                .help("Loop")
            }

            if audioFiles.isEmpty {
                Text("No audio or video files in Library")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    sidebarAudioList
                }
                .frame(maxWidth: .infinity, maxHeight: maxListHeight, alignment: .topLeading)
            }

            HStack(spacing: 8) {
                Text("\(Int(backgroundAudioVolumeDraft * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)

                Slider(value: $backgroundAudioVolumeDraft, in: 0.0...1.0, step: 0.01)
                    .controlSize(.small)
                    .disabled(session.backgroundAudioURL == nil)
                    .onChange(of: backgroundAudioVolumeDraft) { _, newValue in
                        onApplyBackgroundAudioVolume(newValue)
                    }

                Text("")
                    .frame(width: 42)
            }

            HStack(spacing: 8) {
                Text(audioTimeLabel(session.backgroundAudioCurrentTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)

                Slider(
                    value: Binding(
                        get: { session.backgroundAudioCurrentTime },
                        set: { onSeekBackgroundAudio($0) }
                    ),
                    in: 0...max(session.backgroundAudioDuration, 1),
                    step: 0.25
                )
                .controlSize(.small)
                .disabled(session.backgroundAudioURL == nil || session.backgroundAudioDuration <= 0)

                Text(audioTimeLabel(session.backgroundAudioDuration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
            }
        }
    }

    private var sidebarAudioList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(audioFiles, id: \.standardizedFileURL) { url in
                let isSelected = session.backgroundAudioURL?.standardizedFileURL == url.standardizedFileURL
                Button {
                    isSidebarFocused = true
                    onSelectBackgroundAudio(url)
                } label: {
                    sidebarRow(title: displayName(url), isSelected: isSelected)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .contextMenu {
                    revealInFinderButton(for: url)
                }
            }
        }
    }

    private func audioTimeLabel(_ time: Double) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let totalSeconds = Int(time.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }

    private func sidebarSectionHeader(
        _ title: String,
        detail: String?,
        systemImage: String,
        tint: SidebarSectionTint,
        isExpanded: Bool
    ) -> some View {
        HStack(spacing: 10) {
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

            Capsule(style: .continuous)
                .fill(tint.color.opacity(0.28))
                .frame(width: 24, height: 4)

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)
        }
        .padding(.top, 4)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sectionDivider: some View {
        Divider()
            .padding(.vertical, 4)
    }

    private func sidebarFileList(_ urls: [URL], selection: @escaping (URL) -> SidebarSelection) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(urls, id: \.standardizedFileURL) { url in
                sidebarFileRow(url, selection: selection)
                .id(url.standardizedFileURL)
            }
        }
    }

    private func sidebarGroupedFileList(_ urls: [URL], selection: @escaping (URL) -> SidebarSelection) -> some View {
        let sections = cachedLibraryKindSections
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                Button {
                    toggleLibraryGroup(section.group)
                } label: {
                    libraryGroupHeader(section.group, count: section.urls.count)
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.top, section.group == sections.first?.group ? 0 : 6)

                if !collapsedLibraryGroups.contains(section.group) {
                    ForEach(section.urls, id: \.standardizedFileURL) { url in
                        sidebarFileRow(url, selection: selection)
                            .id(url.standardizedFileURL)
                    }
                }
            }
        }
    }

    private func sidebarFolderGroupedFileList(_ urls: [URL], selection: @escaping (URL) -> SidebarSelection) -> some View {
        let sections = cachedLibraryFolderSections
        return LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(sections) { section in
                Button {
                    toggleLibraryFolder(section.id)
                } label: {
                    libraryFolderHeader(
                        section.title,
                        count: section.urls.count,
                        isCollapsed: collapsedLibraryFolders.contains(section.id)
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .padding(.top, section.id == sections.first?.id ? 0 : 6)

                if !collapsedLibraryFolders.contains(section.id) {
                    ForEach(section.urls, id: \.standardizedFileURL) { url in
                        sidebarFileRow(url, selection: selection)
                            .id(url.standardizedFileURL)
                    }
                }
            }
        }
    }

    private func sidebarFileRow(_ url: URL, selection: @escaping (URL) -> SidebarSelection) -> some View {
        let selectionValue = selection(url)
        return HStack(spacing: 6) {
            Button {
                isSidebarFocused = true
                if sidebarSelection == selectionValue {
                    onSelectionChange(selectionValue)
                } else {
                    sidebarSelection = selectionValue
                }
            } label: {
                sidebarRow(title: displayName(url), isSelected: sidebarSelection == selectionValue)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            Button {
                onAddLibraryItemToPlaylist(url)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AccentColorProvider.color)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(AccentColorProvider.color.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help("Add to Playlist")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button {
                onAddLibraryItemToPlaylist(url)
            } label: {
                Label("Add to Playlist", systemImage: "plus")
            }

            revealInFinderButton(for: url)
        }
    }

    private func revealInFinderButton(for url: URL) -> some View {
        Button {
            revealInFinder(url)
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func libraryGroupHeader(_ group: LibraryFileGroup, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: collapsedLibraryGroups.contains(group) ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Text(group.title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
        .frame(height: 22)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private func groupedLibrarySections(from urls: [URL]) -> [LibraryFileGroupSection] {
        let sortedURLs = urls.sorted {
            displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending
        }
        let grouped = Dictionary(grouping: sortedURLs) { LibraryFileGroup(url: $0) }
        return LibraryFileGroup.allCases.compactMap { group in
            guard let groupURLs = grouped[group], !groupURLs.isEmpty else { return nil }
            return LibraryFileGroupSection(group: group, urls: groupURLs)
        }
    }

    private func libraryFolderHeader(_ title: String, count: Int, isCollapsed: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            Spacer(minLength: 0)
        }
        .frame(height: 22)
        .padding(.horizontal, 8)
        .contentShape(Rectangle())
    }

    private func groupedLibraryFolderSections(from urls: [URL]) -> [LibraryFolderGroupSection] {
        let sortedURLs = urls.sorted {
            displayName($0).localizedCaseInsensitiveCompare(displayName($1)) == .orderedAscending
        }
        let grouped = Dictionary(grouping: sortedURLs) { libraryFolderGroup(for: $0) }
        return grouped.map { key, urls in
            LibraryFolderGroupSection(
                title: key.title,
                sortKey: key.sortKey,
                urls: urls
            )
        }
        .sorted { lhs, rhs in
            lhs.sortKey.localizedCaseInsensitiveCompare(rhs.sortKey) == .orderedAscending
        }
    }

    private func libraryFolderGroup(for url: URL) -> LibraryFolderGroupKey {
        guard let libraryRootURL else {
            return LibraryFolderGroupKey(title: "Root", sortKey: "0-root")
        }
        let rootPath = libraryRootURL.standardizedFileURL.path
        let parentPath = url.deletingLastPathComponent().standardizedFileURL.path
        guard parentPath.hasPrefix(rootPath) else {
            return LibraryFolderGroupKey(title: "Other", sortKey: "z-other")
        }
        let suffix = parentPath
            .dropFirst(rootPath.count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let folderName = suffix.split(separator: "/").first, !folderName.isEmpty else {
            return LibraryFolderGroupKey(title: "Root", sortKey: "0-root")
        }
        let title = String(folderName)
        return LibraryFolderGroupKey(title: title, sortKey: "1-\(title.lowercased())")
    }

    private func toggleLibraryGroup(_ group: LibraryFileGroup) {
        if collapsedLibraryGroups.contains(group) {
            collapsedLibraryGroups.remove(group)
        } else {
            collapsedLibraryGroups.insert(group)
        }
    }

    private func toggleLibraryFolder(_ folderID: String) {
        if collapsedLibraryFolders.contains(folderID) {
            collapsedLibraryFolders.remove(folderID)
        } else {
            collapsedLibraryFolders.insert(folderID)
        }
    }

    private func prepareLibraryGroupingChange(_ grouping: LibraryGrouping) {
        libraryGrouping = grouping
        libraryGroupingTransitionTask?.cancel()
        guard displayedLibraryGrouping != grouping else {
            isPreparingLibraryGrouping = false
            return
        }

        isPreparingLibraryGrouping = true
        libraryGroupingTransitionTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(nanoseconds: 50_000_000)
            guard !Task.isCancelled else { return }
            displayedLibraryGrouping = grouping
            isPreparingLibraryGrouping = false
        }
    }

    private var canToggleLibraryGroups: Bool {
        switch displayedLibraryGrouping {
        case .kind:
            !libraryKindGroups.isEmpty
        case .folder:
            !libraryFolderIDs.isEmpty
        case .none:
            false
        }
    }

    private var libraryGroupToggleHelp: String {
        let action = allVisibleLibraryGroupsCollapsed ? "Expand" : "Collapse"
        switch displayedLibraryGrouping {
        case .kind:
            return "\(action) all kinds"
        case .folder:
            return "\(action) all folders"
        case .none:
            return "Choose Kind or Folder grouping to collapse sections"
        }
    }

    private var libraryKindGroups: [LibraryFileGroup] {
        cachedLibraryKindSections.map(\.group)
    }

    private var libraryFolderIDs: [String] {
        cachedLibraryFolderSections.map(\.id)
    }

    private var allVisibleLibraryGroupsCollapsed: Bool {
        switch displayedLibraryGrouping {
        case .kind:
            let groups = libraryKindGroups
            return !groups.isEmpty && groups.allSatisfy { collapsedLibraryGroups.contains($0) }
        case .folder:
            let folderIDs = libraryFolderIDs
            return !folderIDs.isEmpty && folderIDs.allSatisfy { collapsedLibraryFolders.contains($0) }
        case .none:
            return false
        }
    }

    private func toggleAllLibraryGroups() {
        switch displayedLibraryGrouping {
        case .kind:
            let groups = libraryKindGroups
            guard !groups.isEmpty else { return }
            if allVisibleLibraryGroupsCollapsed {
                collapsedLibraryGroups.subtract(groups)
            } else {
                collapsedLibraryGroups.formUnion(groups)
            }
        case .folder:
            let folderIDs = libraryFolderIDs
            guard !folderIDs.isEmpty else { return }
            if allVisibleLibraryGroupsCollapsed {
                collapsedLibraryFolders.subtract(folderIDs)
            } else {
                collapsedLibraryFolders.formUnion(folderIDs)
            }
        case .none:
            return
        }
    }

    private func rebuildLibraryCaches() {
        cachedLibraryKindSections = groupedLibrarySections(from: libraryFiles)
        cachedLibraryFolderSections = groupedLibraryFolderSections(from: libraryFiles)
    }

    private func sidebarScrollableFileList(
        _ urls: [URL],
        maxHeight: CGFloat,
        selection: @escaping (URL) -> SidebarSelection
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                if displayedLibraryGrouping == .kind {
                    sidebarGroupedFileList(urls, selection: selection)
                } else if displayedLibraryGrouping == .folder {
                    sidebarFolderGroupedFileList(urls, selection: selection)
                } else {
                    sidebarFileList(urls, selection: selection)
                }
            }
            .onAppear {
                prepareLibraryScrollIfNeeded(with: proxy)
            }
            .onChange(of: libraryScrollRequest?.id) { _, _ in
                prepareLibraryScrollIfNeeded(with: proxy)
            }
            .onChange(of: libraryRevision) { _, _ in
                prepareLibraryScrollIfNeeded(with: proxy)
            }
            .onChange(of: keyboardLibraryScrollTarget) { _, newValue in
                guard let newValue else { return }
                prepareLibraryScroll(to: newValue, with: proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func libraryContent(maxHeight: CGFloat) -> some View {
        if isLibraryLoading && libraryFiles.isEmpty {
            Text("Loading library...")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else if isPreparingLibraryGrouping {
            preparingLibraryGroupingView(maxHeight: maxHeight)
        } else {
            sidebarScrollableFileList(libraryFiles, maxHeight: maxHeight) { .library($0) }
        }
    }

    private func preparingLibraryGroupingView(maxHeight: CGFloat) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)

            Text("Preparing \(libraryGrouping.title) view...")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private func prepareLibraryScrollIfNeeded(with proxy: ScrollViewProxy) {
        guard let libraryScrollRequest else { return }
        prepareLibraryScroll(to: libraryScrollRequest.url, with: proxy)
    }

    private func prepareLibraryScroll(to url: URL, with proxy: ScrollViewProxy) {
        let targetURL = url.standardizedFileURL
        guard libraryFiles.contains(where: { $0.standardizedFileURL == targetURL }) else { return }
        collapsedLibraryGroups.remove(LibraryFileGroup(url: targetURL))
        collapsedLibraryFolders.remove(libraryFolderGroup(for: targetURL).sortKey)

        pendingLibraryScrollTarget = targetURL
        Task { @MainActor in
            await Task.yield()
            guard pendingLibraryScrollTarget == targetURL else { return }
            guard libraryFiles.contains(where: { $0.standardizedFileURL == targetURL }) else { return }
            scrollLibraryList(to: targetURL, with: proxy)
            pendingLibraryScrollTarget = nil
        }
    }

    private func scrollLibraryList(to targetURL: URL, with proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.16)) {
            proxy.scrollTo(targetURL, anchor: .center)
        }
    }

    private var sidebarPlaylistList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(playlistItems) { item in
                HStack(spacing: 6) {
                    Button {
                        isSidebarFocused = true
                        applyPlaylistSelection(item.id)
                    } label: {
                        sidebarRow(
                            title: item.title,
                            isSelected: selectedPlaylistEntryIDs.contains(item.id),
                            isMissing: !item.exists
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())

                    Button {
                        onRemovePlaylistItem(item.id)
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle()
                                    .fill(Color.secondary.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Remove from Playlist")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func selectedWindowRow(_ window: ScreenCaptureManager.CapturedWindow) -> some View {
        let selectionValue = SidebarSelection.window(window.windowID)
        let rowTitle = window.title == window.appName ? window.appName : "\(window.appName): \(window.title)"
        return Button {
            isSidebarFocused = true
            if sidebarSelection == selectionValue {
                // Re-load the same picked window after Current gets cleared.
                onSelectionChange(selectionValue)
            } else {
                sidebarSelection = selectionValue
            }
        } label: {
            sidebarRow(
                title: rowTitle,
                isSelected: sidebarSelection == selectionValue
            )
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func sidebarRow(title: String, isSelected: Bool, isMissing: Bool = false) -> some View {
        let selectionShape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Text(title)
            .font(.system(size: 14))
            .foregroundStyle(isMissing ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(height: 22, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectionShape
                    .fill(isSelected ? AccentColorProvider.color.opacity(0.22) : Color.clear)
            )
            .overlay(
                selectionShape
                    .stroke(isSelected ? AccentColorProvider.color.opacity(0.7) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .focusEffectDisabled()
    }

    private var sidebarSelectableItems: [SidebarSelection] {
        let libraryItems = visibleLibraryFilesForKeyboard.map { SidebarSelection.library($0) }
        let playlistSelectionItems = playlistItems.map { SidebarSelection.playlist($0.id) }
        let webpageItems = webpageURLs.map { SidebarSelection.web($0) }
        let windowItems = captureWindows.map { SidebarSelection.window($0.windowID) }
        return libraryItems + playlistSelectionItems + webpageItems + windowItems
    }

    private var visibleLibraryFilesForKeyboard: [URL] {
        if displayedLibraryGrouping == .none {
            return libraryFiles
        }
        if displayedLibraryGrouping == .folder {
            return cachedLibraryFolderSections.flatMap { section in
                collapsedLibraryFolders.contains(section.id) ? [] : section.urls
            }
        }
        return cachedLibraryKindSections.flatMap { section in
            collapsedLibraryGroups.contains(section.group) ? [] : section.urls
        }
    }

    private func handleSidebarMoveCommand(_ direction: MoveCommandDirection) {
        guard direction == .up || direction == .down else { return }
        let items = sidebarSelectableItems
        guard !items.isEmpty else { return }

        if let current = sidebarSelection, let index = items.firstIndex(of: current) {
            let nextIndex = direction == .up ? max(0, index - 1) : min(items.count - 1, index + 1)
            if nextIndex != index {
                applyKeyboardSelection(items[nextIndex])
            }
            return
        }

        applyKeyboardSelection(direction == .up ? items.last : items.first)
    }

    private func applyPlaylistSelection(_ id: UUID) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let isCommand = flags.contains(.command)
        let isShift = flags.contains(.shift)
        let selectionValue = SidebarSelection.playlist(id)

        if isShift,
           let anchor = playlistSelectionAnchor,
           let anchorIndex = playlistItems.firstIndex(where: { $0.id == anchor }),
           let tappedIndex = playlistItems.firstIndex(where: { $0.id == id }) {
            let range = anchorIndex <= tappedIndex ? anchorIndex...tappedIndex : tappedIndex...anchorIndex
            selectedPlaylistEntryIDs = Set(playlistItems[range].map(\.id))
            sidebarSelection = selectionValue
            return
        }

        if isCommand {
            if selectedPlaylistEntryIDs.contains(id) {
                selectedPlaylistEntryIDs.remove(id)
                if case .playlist(let currentID) = sidebarSelection, currentID == id {
                    sidebarSelection = selectedPlaylistEntryIDs.first.map { .playlist($0) }
                }
            } else {
                selectedPlaylistEntryIDs.insert(id)
                sidebarSelection = .playlist(id)
            }
            playlistSelectionAnchor = selectedPlaylistEntryIDs.first ?? id
            return
        }

        if sidebarSelection == selectionValue {
            selectedPlaylistEntryIDs = [id]
            playlistSelectionAnchor = id
            onSelectionChange(selectionValue)
            return
        }

        selectedPlaylistEntryIDs = [id]
        sidebarSelection = selectionValue
        playlistSelectionAnchor = id
    }

    private func applyKeyboardSelection(_ selection: SidebarSelection?) {
        guard let selection else { return }
        sidebarSelection = selection
        switch selection {
        case .library(let url):
            selectedPlaylistEntryID = nil
            selectedPlaylistEntryIDs = []
            keyboardLibraryScrollTarget = url.standardizedFileURL
        case .playlist(let id):
            selectedPlaylistEntryIDs = [id]
            playlistSelectionAnchor = id
        case .web:
            selectedPlaylistEntryID = nil
            selectedPlaylistEntryIDs = []
        case .window:
            selectedPlaylistEntryID = nil
            selectedPlaylistEntryIDs = []
        }
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
