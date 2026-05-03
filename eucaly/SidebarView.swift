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
    case background
    case timer
    case appearance

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
        case .background:
            Color(nsColor: .systemPink)
        case .timer:
            Color(nsColor: .systemPurple)
        case .appearance:
            Color(nsColor: .systemBrown)
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

struct SidebarView: View {
    @ObservedObject var session: PresentationSession
    let isWindowCaptureSupported: Bool
    let libraryFiles: [URL]
    let playlistItems: [PlaylistSidebarItem]
    let libraryRootURL: URL?
    let downloadsURL: URL?
    let libraryFolders: [URL]
    let captureWindows: [ScreenCaptureManager.CapturedWindow]
    let webpageURLs: [URL]
    let libraryScrollRequest: LibraryScrollRequest?
    @Binding var selectedLibraryFolder: URL?
    @Binding var selectedPlaylistEntryID: UUID?
    @Binding var selectedPlaylistEntryIDs: Set<UUID>
    @Binding var sidebarSelection: SidebarSelection?
    @Binding var backgroundAudioLoop: Bool
    @Binding var overlayScaleDraft: Double
    @Binding var backgroundAudioVolumeDraft: Double
    @Binding var countdownMinutes: Int
    @Binding var presentationFontScale: Double
    @Binding var thumbnailFontScale: Double
    @Binding var thumbnailScale: Double
    @Binding var windowCaptureFrameRate: Int
    @FocusState.Binding var isSidebarFocused: Bool

    let displayName: (URL) -> String
    let titleForWebpage: (URL) -> String
    let onSelectLibraryFolder: (URL?) -> Void
    let onSelectDownloads: (URL) -> Void
    let onAddLibraryItemToPlaylist: (URL) -> Void
    let onRemoveSelectedFromPlaylist: () -> Void
    let onMovePlaylistUp: () -> Void
    let onMovePlaylistDown: () -> Void
    let onChooseBackgroundVisual: () -> Void
    let onClearBackgroundVisual: () -> Void
    let onChooseBackgroundAudio: () -> Void
    let onPlayPauseBackgroundAudio: () -> Void
    let onStopBackgroundAudio: () -> Void
    let onClearBackgroundAudio: () -> Void
    let onApplyBackgroundAudioVolume: (Double) -> Void
    let onOverlayScaleDraftChange: (Double) -> Void
    let onSetOverlayMode: (PresentationSession.OverlayMode) -> Void
    let onStartCountdown: (Int) -> Void
    let onStopCountdown: () -> Void
    let onSetClockVisible: (Bool) -> Void
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

    @AppStorage("sidebar.backgroundSectionExpanded")
    private var isBackgroundSectionExpanded = false

    @AppStorage("sidebar.timerSectionExpanded")
    private var isTimerSectionExpanded = false

    @AppStorage("sidebar.appearanceSectionExpanded")
    private var isAppearanceSectionExpanded = false

    @State private var playlistSelectionAnchor: UUID?

    @State private var webpageAddressDraft: String = ""

    @State private var webpageAddressError: String? = nil

    var body: some View {
        GeometryReader { proxy in
            let libraryListMaxHeight = max(160, min(320, proxy.size.height * 0.35))
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    sidebarSection(
                        "Library",
                        systemImage: "folder",
                        tint: .library,
                        isExpanded: $isLibrarySectionExpanded
                    ) {
                        libraryControls
                        sidebarScrollableFileList(libraryFiles, maxHeight: libraryListMaxHeight) { .library($0) }
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

                    if isWindowCaptureSupported {
                        sectionDivider

                        sidebarSection(
                            "Windows",
                            systemImage: "macwindow",
                            tint: .windows,
                            isExpanded: $isWindowsSectionExpanded
                        ) {
                            windowsControls
                        }
                    }

                    sectionDivider

                    sidebarSection(
                        "Background",
                        systemImage: "photo.on.rectangle",
                        tint: .background,
                        isExpanded: $isBackgroundSectionExpanded
                    ) {
                        backgroundControls
                    }

                    sectionDivider

                    sidebarSection(
                        "Timer",
                        systemImage: "timer",
                        tint: .timer,
                        isExpanded: $isTimerSectionExpanded
                    ) {
                        timerControls
                    }

                    sectionDivider

                    sidebarSection(
                        "Appearance",
                        systemImage: "slider.horizontal.3",
                        tint: .appearance,
                        isExpanded: $isAppearanceSectionExpanded
                    ) {
                        appearanceControls
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
        .onChange(of: libraryScrollRequest?.id) { _, _ in
            if libraryScrollRequest != nil {
                isLibrarySectionExpanded = true
            }
        }
        .font(.subheadline)
    }

    private var libraryControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let rootURL = libraryRootURL {
                Text(rootURL.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack(spacing: 8) {
                Picker("Library", selection: $selectedLibraryFolder) {
                    Text("Root").tag(Optional<URL>.none)
                    ForEach(libraryFolders, id: \.self) { folder in
                        Text(folder.lastPathComponent).tag(Optional(folder))
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)

                if let downloadsURL {
                    Button {
                        selectedLibraryFolder = nil
                        onSelectDownloads(downloadsURL)
                    } label: {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                    .sidebarActionStyle()
                }
            }
            .onChange(of: selectedLibraryFolder) { _, newValue in
                onSelectLibraryFolder(newValue)
            }
        }
    }

    private func sidebarSection<Content: View>(
        _ title: String,
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
                    systemImage: systemImage,
                    tint: tint,
                    isExpanded: isExpanded.wrappedValue
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

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
            }

            if webpageURLs.isEmpty {
                Text("No saved webpages")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var playlistControls: some View {
        HStack(spacing: 10) {
            Button("Remove Selected") { onRemoveSelectedFromPlaylist() }
                .sidebarActionStyle()
                .disabled(selectedPlaylistEntryIDs.isEmpty)
            Button {
                onMovePlaylistUp()
            } label: {
                Label("Move Up", systemImage: "arrow.up")
            }
            .labelStyle(.iconOnly)
            .sidebarActionStyle()
            .disabled(selectedPlaylistEntryIDs.isEmpty)
            Button {
                onMovePlaylistDown()
            } label: {
                Label("Move Down", systemImage: "arrow.down")
            }
            .labelStyle(.iconOnly)
            .sidebarActionStyle()
            .disabled(selectedPlaylistEntryIDs.isEmpty)
        }
    }

    private var windowsControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Pick Window") {
                    onPickWindow()
                }
                .sidebarActionStyle(primary: true)
                .help("Choose a window to preview")

                Button {
                    onClearSelectedWindow()
                } label: {
                    Label("Clear", systemImage: "xmark.circle")
                }
                .labelStyle(.iconOnly)
                .sidebarActionStyle()
                .disabled(!hasSelectedWindow)
                .help("Clear selected window")
            }

            if !captureWindows.isEmpty {
                sidebarWindowsList
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Frame Rate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Frame Rate", selection: $windowCaptureFrameRate) {
                    Text("24").tag(24)
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                Text("Applies to the next window capture.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var hasSelectedWindow: Bool {
        if case .window = sidebarSelection {
            return true
        }
        return false
    }

    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Visual")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Set Visual") { onChooseBackgroundVisual() }
                        .sidebarActionStyle(primary: true)
                        .help("Choose a background image or video")
                    Button {
                        onClearBackgroundVisual()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .labelStyle(.iconOnly)
                    .sidebarActionStyle()
                    .disabled(session.backgroundVisualURL == nil)
                }
                if let url = session.backgroundVisualURL {
                    Text(displayName(url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("Applies to lyrics only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Audio")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Set Audio") { onChooseBackgroundAudio() }
                        .sidebarActionStyle(primary: true)
                        .help("Choose a background audio file")
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
                if let url = session.backgroundAudioURL {
                    Text(displayName(url))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Audio Volume")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("\(Int(backgroundAudioVolumeDraft * 100))%")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                        Slider(value: $backgroundAudioVolumeDraft, in: 0.0...1.0, step: 0.01)
                            .controlSize(.small)
                            .onChange(of: backgroundAudioVolumeDraft) { _, newValue in
                                onApplyBackgroundAudioVolume(newValue)
                            }
                    }
                }
            }
        }
    }

    private var timerControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(
                "Overlay Mode",
                selection: Binding(
                    get: { session.overlayMode },
                    set: { newMode in
                        onSetOverlayMode(newMode)
                    }
                )
            ) {
                ForEach(PresentationSession.OverlayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 8) {
                Text("Overlay Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("\(Int(overlayScaleDraft * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Slider(value: $overlayScaleDraft, in: 0.5...6.0, step: 0.1)
                        .controlSize(.small)
                        .onChange(of: overlayScaleDraft) { _, newValue in
                            onOverlayScaleDraftChange(newValue)
                        }
                }
            }

            if session.overlayMode == .countdown {
                HStack(spacing: 8) {
                    Text("\(countdownMinutes)m")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Slider(
                        value: Binding(
                            get: { Double(countdownMinutes) },
                            set: { countdownMinutes = Int($0.rounded()) }
                        ),
                        in: 1...30,
                        step: 1
                    )
                    .controlSize(.small)
                }
                HStack(spacing: 8) {
                    Button(session.isCountdownRunning ? "Restart Timer" : "Start Timer") {
                        onStartCountdown(countdownMinutes)
                    }
                    .sidebarActionStyle(primary: true)
                    Button("Stop") {
                        onStopCountdown()
                    }
                    .sidebarActionStyle()
                    .disabled(!session.isCountdownRunning)
                }
            } else {
                HStack(spacing: 8) {
                    Button(session.isClockVisible ? "Hide Clock" : "Show Clock") {
                        onSetClockVisible(!session.isClockVisible)
                    }
                    .sidebarActionStyle(primary: true)
                }
            }
        }
    }

    private var appearanceControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Presentation Font Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("\(Int(presentationFontScale * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Slider(value: $presentationFontScale, in: 0.5...2.0, step: 0.1)
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Thumbnail Font Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("\(Int(thumbnailFontScale * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Slider(value: $thumbnailFontScale, in: 0.3...2.0, step: 0.1)
                        .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Thumbnail Size")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text("\(Int(thumbnailScale * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Slider(value: $thumbnailScale, in: 0.6...1.6, step: 0.1)
                        .controlSize(.small)
                }
            }
        }
    }

    private func sidebarSectionHeader(
        _ title: String,
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
            ForEach(urls, id: \.self) { url in
                let selectionValue = selection(url)
                HStack(spacing: 6) {
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

                    Button {
                        onAddLibraryItemToPlaylist(url)
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 20, height: 20)
                            .background(
                                Circle()
                                    .fill(Color.accentColor.opacity(0.12))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Add to Playlist")
                }
                .id(url.standardizedFileURL)
            }
        }
    }

    private func sidebarScrollableFileList(
        _ urls: [URL],
        maxHeight: CGFloat,
        selection: @escaping (URL) -> SidebarSelection
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                sidebarFileList(urls, selection: selection)
            }
            .onAppear {
                scrollLibraryListIfNeeded(with: proxy)
            }
            .onChange(of: libraryScrollRequest?.id) { _, _ in
                scrollLibraryListIfNeeded(with: proxy)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: maxHeight, alignment: .topLeading)
    }

    private func scrollLibraryListIfNeeded(with proxy: ScrollViewProxy) {
        guard let libraryScrollRequest else { return }
        let targetURL = libraryScrollRequest.url.standardizedFileURL
        guard libraryFiles.contains(where: { $0.standardizedFileURL == targetURL }) else { return }

        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.16)) {
                proxy.scrollTo(targetURL, anchor: .center)
            }
        }
    }

    private var sidebarPlaylistList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(playlistItems) { item in
                Button {
                    isSidebarFocused = true
                    applyPlaylistSelection(item.id)
                } label: {
                    sidebarRow(title: item.title, isSelected: selectedPlaylistEntryIDs.contains(item.id), isMissing: !item.exists)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var sidebarWindowsList: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(captureWindows) { window in
                let selectionValue = SidebarSelection.window(window.windowID)
                let rowTitle = window.title == window.appName ? window.appName : "\(window.appName): \(window.title)"
                Button {
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
            }
        }
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
            .focusEffectDisabled()
    }

    private var sidebarSelectableItems: [SidebarSelection] {
        let libraryItems = libraryFiles.map { SidebarSelection.library($0) }
        let playlistSelectionItems = playlistItems.map { SidebarSelection.playlist($0.id) }
        let webpageItems = webpageURLs.map { SidebarSelection.web($0) }
        let windowItems = captureWindows.map { SidebarSelection.window($0.windowID) }
        return libraryItems + webpageItems + playlistSelectionItems + windowItems
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
        case .library:
            selectedPlaylistEntryID = nil
            selectedPlaylistEntryIDs = []
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
