import AppKit
import Combine

@MainActor
final class SidebarViewController: NSViewController {
    private var configuration: SidebarConfiguration
    private let defaults: UserDefaults
    private let expansionStore = SidebarOutlineExpansionStore()
    private let navigation = SidebarOutlineNavigationCoordinator()
    private let libraryModels = LibraryOutlineModelStore()
    private var libraryTask: Task<Void, Never>?
    private var requestedLibraryRevision: LibraryOutlineRevision?
    private var libraryExpansionState = SidebarOutlineExpansionState.empty
    private var libraryExpansionCommand: SidebarOutlineExpansionCommand?
    private var lastScrollRequestID: UUID?
    private var subscriptions: Set<AnyCancellable> = []
    private var preferenceSubscription: AnyCancellable?
    private var isApplyingSnapshot = false
    private var isDetached = false
    private var sessionRefreshScheduled = false
    private var progressRefreshScheduled = false
    private var grouping: LibraryGrouping

    let scrollView = NSScrollView()
    private let document = SidebarDocumentStackView()
    private var sections: [SidebarSection: SidebarSectionView] = [:]
    private lazy var libraryOutline = makeOutline(section: .library)
    private lazy var playlistOutline = makeOutline(section: .playlist)
    private lazy var audioOutline = makeOutline(section: .audio)
    private lazy var windowOutline = makeOutline(section: .windows)

    private let failureNotice = NSStackView()
    private let failurePath = NSTextField(wrappingLabelWithString: "")
    private let failureMessage = NSTextField(wrappingLabelWithString: "")
    private let retainedLibraryNotice = NSTextField(wrappingLabelWithString: "Showing the last available Library and Audio lists.")
    private let libraryCaption = NSTextField(labelWithString: "")
    private let playlistCaption = NSTextField(labelWithString: "No playlist items")
    private let audioCaption = NSTextField(labelWithString: "No audio or video files in Library")

    private var libraryImport: NSButton!
    private var audioImport: NSButton!
    private var retryLibrary: NSButton!
    private var removePlaylist: NSButton!
    private var movePlaylistUp: NSButton!
    private var movePlaylistDown: NSButton!
    private var pickWindow: NSButton!
    private var clearWindow: NSButton!
    private var playAudio: NSButton!
    private var stopAudio: NSButton!
    private var clearAudio: NSButton!
    private var loopAudio: NSButton!
    private var toggleGroups: NSButton!
    let groupingPopup = NSPopUpButton()
    let windowSettingsButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let volumeSlider = SidebarAudioSlider()
    let positionSlider = SidebarAudioSlider()
    private let volumeLabel = NSTextField(labelWithString: "")
    private let currentTime = NSTextField(labelWithString: "")
    private let duration = NSTextField(labelWithString: "")

    init(configuration: SidebarConfiguration, defaults: UserDefaults = .standard) {
        self.configuration = configuration
        self.defaults = defaults
        grouping = defaults.string(forKey: "sidebar.libraryGrouping").flatMap(LibraryGrouping.init(rawValue:)) ?? .kind
        super.init(nibName: nil, bundle: nil)
        loadViewIfNeeded()
        observeSession()
        preferenceSubscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification, object: defaults)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.restorePreferences() }
        update(configuration)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let background = NSVisualEffectView()
        background.material = .sidebar
        background.blendingMode = .withinWindow
        background.state = .followsWindowActiveState
        view = background
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        background.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: background.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor)
        ])
        document.orientation = .vertical
        document.alignment = .leading
        document.spacing = 12
        document.edgeInsets = NSEdgeInsets(top: 10, left: SidebarSectionMetrics.outerInset, bottom: 10, right: SidebarSectionMetrics.outerInset)
        document.detachesHiddenViews = true
        document.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = document
        document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        buildFailureNotice()
        appendDocument(failureNotice)
        for section in SidebarSection.allCases {
            if section != .library {
                let separator = NSBox()
                separator.boxType = .separator
                separator.identifier = NSUserInterfaceItemIdentifier("sidebar.\(section.rawValue).separator")
                appendDocument(separator)
            }
            let sectionView = SidebarSectionView(section: section, target: self, action: #selector(toggleSection(_:)))
            sections[section] = sectionView
            appendDocument(sectionView)
            sectionView.setExpanded(expandedPreference(section))
        }
        buildLibrary()
        buildPlaylist()
        buildAudio()
        buildWindows()
        configureSectionNavigation()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        libraryOutline.scrollView.maximumHeight = max(160, min(320, view.bounds.height * 0.35))
        audioOutline.scrollView.maximumHeight = max(120, min(240, view.bounds.height * 0.25))
        let standardMaximum = max(104, min(208, view.bounds.height * 0.22))
        playlistOutline.scrollView.maximumHeight = standardMaximum
        windowOutline.scrollView.maximumHeight = standardMaximum
    }

    func update(_ configuration: SidebarConfiguration) {
        guard !isDetached else { return }
        let sessionChanged = self.configuration.session !== configuration.session
        // Install commands and values together before AppKit applies selection.
        self.configuration = configuration
        if sessionChanged { observeSession() }
        isApplyingSnapshot = true
        defer { isApplyingSnapshot = false }
        if let request = configuration.libraryScrollRequest, request.id != lastScrollRequestID {
            lastScrollRequestID = request.id
            setExpanded(true, section: .library)
        }
        libraryImport.isEnabled = configuration.libraryRootURL != nil
        audioImport.isEnabled = configuration.libraryRootURL != nil
        retryLibrary.isEnabled = !configuration.isLibraryLoading
        let playlistMoves = PlaylistMoveAvailability(
            selectedIDs: configuration.selectedPlaylistEntryIDs,
            orderedIDs: configuration.playlistItems.map(\.id))
        removePlaylist.isEnabled = !playlistMoves.selectedIDs.isEmpty
        movePlaylistUp.isEnabled = playlistMoves.canMoveUp
        movePlaylistDown.isEnabled = playlistMoves.canMoveDown
        pickWindow.title = configuration.captureWindows.isEmpty ? "Pick Window…" : "Replace Window…"
        pickWindow.sidebarAccessibilityElement.setAccessibilityLabel(configuration.captureWindows.isEmpty ? "Pick Window" : "Replace Window")
        pickWindow.toolTip = configuration.captureWindows.isEmpty ? "Choose a window to preview" : "Choose a different window to preview"
        clearWindow.isEnabled = !configuration.captureWindows.isEmpty
        updateWindowSettings()
        sections[.windows]?.isHidden = !configuration.isWindowCaptureSupported
        document.arrangedSubviews.first { $0.identifier?.rawValue == "sidebar.windows.separator" }?.isHidden = !configuration.isWindowCaptureSupported
        updateFailureNotice()
        refreshAudioState()
        updateOutlines()
        prepareLibraryIfNeeded()
    }

#if DEBUG
    var pendingLibraryPreparationForTests: Task<Void, Never>? { libraryTask }
#endif

    /// Closing controls releases UI observers and delegates only. The app keeps
    /// its session, players, captures and outputs alive independently.
    func detach() {
        guard !isDetached else { return }
        isDetached = true
        libraryTask?.cancel()
        libraryTask = nil
        subscriptions.removeAll()
        preferenceSubscription = nil
        navigation.removeAllRegistrations()
        sections.values.forEach { $0.header.navigationHandler = nil }
        [libraryOutline, playlistOutline, audioOutline, windowOutline].forEach { $0.detach() }
    }

    private func observeSession() {
        subscriptions.removeAll()
        // objectWillChange precedes assignment. Read the new state on the next
        // main-queue boundary, keeping progress refreshes out of list updates.
        configuration.session.objectWillChange.sink { [weak self] _ in
            self?.scheduleRefresh(progressOnly: false)
        }.store(in: &subscriptions)
        configuration.session.playbackProgress.objectWillChange.sink { [weak self] _ in
            self?.scheduleRefresh(progressOnly: true)
        }.store(in: &subscriptions)
    }

    private func scheduleRefresh(progressOnly: Bool) {
        guard !isDetached else { return }
        if progressOnly {
            guard !progressRefreshScheduled else { return }
            progressRefreshScheduled = true
        } else {
            guard !sessionRefreshScheduled else { return }
            sessionRefreshScheduled = true
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, !isDetached else { return }
            if progressOnly {
                progressRefreshScheduled = false
                refreshProgressControls()
            } else {
                sessionRefreshScheduled = false
                refreshAudioState()
                updateAudioOutline()
            }
        }
    }

    private func appendDocument(_ child: NSView) {
        document.addArrangedSubview(child)
        child.widthAnchor.constraint(equalTo: document.widthAnchor, constant: -2 * SidebarSectionMetrics.outerInset).isActive = true
    }

    private func actionRow(_ children: [NSView]) -> NSStackView {
        let row = NSStackView(views: children)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 0, left: SidebarSectionMetrics.contentInset, bottom: 0, right: SidebarSectionMetrics.contentInset)
        return row
    }

    private func flexibleSpace() -> NSView {
        let space = NSView()
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return space
    }

    private func button(_ title: String, symbol: String? = nil, identifier: String, help: String, iconOnly: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(performAction(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.sidebarAccessibilityElement.setAccessibilityIdentifier(identifier)
        button.sidebarAccessibilityElement.setAccessibilityLabel(help)
        button.toolTip = help
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        if let symbol {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = iconOnly ? .imageOnly : .imageLeading
        }
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    private func caption(_ field: NSTextField) -> NSView {
        field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        field.textColor = .secondaryLabelColor
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return actionRow([field, flexibleSpace()])
    }

    private func buildLibrary() {
        libraryImport = button("Import…", symbol: "square.and.arrow.down", identifier: "sidebar.library.import", help: "Import files into Library", iconOnly: true)
        groupingPopup.addItems(withTitles: LibraryGrouping.allCases.map(\.title))
        for (index, grouping) in LibraryGrouping.allCases.enumerated() {
            groupingPopup.item(at: index)?.representedObject = grouping.rawValue
        }
        groupingPopup.controlSize = .small
        groupingPopup.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        groupingPopup.target = self
        groupingPopup.action = #selector(changeGrouping(_:))
        groupingPopup.sidebarAccessibilityElement.setAccessibilityLabel("Library grouping")
        groupingPopup.sidebarAccessibilityElement.setAccessibilityIdentifier("sidebar.library.grouping")
        groupingPopup.selectItem(at: LibraryGrouping.allCases.firstIndex(of: grouping) ?? 0)
        toggleGroups = button("Collapse Groups", symbol: "rectangle.compress.vertical", identifier: "sidebar.library.toggleGroups", help: "Collapse all kinds", iconOnly: true)
        sections[.library]?.append(actionRow([libraryImport, groupingPopup, toggleGroups, flexibleSpace()]))
        sections[.library]?.append(libraryOutline.scrollView)
        sections[.library]?.append(caption(libraryCaption))
    }

    private func buildPlaylist() {
        removePlaylist = button("Remove Selected", symbol: "minus.circle", identifier: "sidebar.playlist.remove", help: "Remove Selected from Playlist", iconOnly: true)
        movePlaylistUp = button("Move Up", symbol: "arrow.up", identifier: "sidebar.playlist.up", help: "Move Selected Up", iconOnly: true)
        movePlaylistDown = button("Move Down", symbol: "arrow.down", identifier: "sidebar.playlist.down", help: "Move Selected Down", iconOnly: true)
        sections[.playlist]?.append(actionRow([removePlaylist, movePlaylistUp, movePlaylistDown, flexibleSpace()]))
        sections[.playlist]?.append(playlistOutline.scrollView)
        sections[.playlist]?.append(caption(playlistCaption))
    }

    private func buildAudio() {
        audioImport = button("Import…", symbol: "square.and.arrow.down", identifier: "sidebar.audio.import", help: "Import audio or video files for background audio", iconOnly: true)
        playAudio = button("Play", symbol: "play.fill", identifier: "sidebar.audio.play", help: "Play Background Audio", iconOnly: true)
        stopAudio = button("Stop", symbol: "stop.fill", identifier: "sidebar.audio.stop", help: "Stop Background Audio", iconOnly: true)
        clearAudio = button("Clear", symbol: "xmark.circle", identifier: "sidebar.audio.clear", help: "Clear Background Audio", iconOnly: true)
        loopAudio = button("Loop", symbol: "repeat", identifier: "sidebar.audio.loop", help: "Loop Background Audio", iconOnly: true)
        loopAudio.setButtonType(.pushOnPushOff)
        sections[.audio]?.append(actionRow([audioImport, playAudio, stopAudio, clearAudio, loopAudio, flexibleSpace()]))
        sections[.audio]?.append(audioOutline.scrollView)
        sections[.audio]?.append(caption(audioCaption))
        configureSlider(volumeSlider, label: "Background audio volume", identifier: "sidebar.audio.volume", action: #selector(changeVolume(_:)))
        volumeSlider.minValue = 0
        volumeSlider.maxValue = 1
        volumeSlider.isContinuous = true
        configureSlider(positionSlider, label: "Background audio position", identifier: "sidebar.audio.position", action: #selector(changePosition(_:)))
        // Track locally while dragging and commit the seek on release. Keyboard
        // and accessibility adjustments still send one native control action.
        positionSlider.isContinuous = false
        for label in [volumeLabel, currentTime, duration] {
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.textColor = .secondaryLabelColor
            label.sidebarAccessibilityElement.setAccessibilityElement(false)
            label.widthAnchor.constraint(equalToConstant: 36).isActive = true
        }
        volumeLabel.alignment = .right
        currentTime.alignment = .right
        let volumeTrailingSpace = NSView()
        volumeTrailingSpace.widthAnchor.constraint(equalToConstant: 36).isActive = true
        sections[.audio]?.append(actionRow([volumeLabel, volumeSlider, volumeTrailingSpace]))
        sections[.audio]?.append(actionRow([currentTime, positionSlider, duration]))
    }

    private func configureSlider(_ slider: NSSlider, label: String, identifier: String, action: Selector) {
        slider.controlSize = .small
        slider.target = self
        slider.action = action
        slider.sidebarAccessibilityElement.setAccessibilityLabel(label)
        slider.sidebarAccessibilityElement.setAccessibilityIdentifier(identifier)
        slider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
    }

    private func buildWindows() {
        pickWindow = button("Pick Window…", identifier: "sidebar.window.pick", help: "Choose a window to preview")
        clearWindow = button("Clear", symbol: "xmark.circle", identifier: "sidebar.window.clear", help: "Clear Selected Window", iconOnly: true)
        windowSettingsButton.controlSize = .small
        windowSettingsButton.bezelStyle = .rounded
        windowSettingsButton.imagePosition = .imageOnly
        (windowSettingsButton.cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        windowSettingsButton.setContentHuggingPriority(.required, for: .horizontal)
        windowSettingsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        windowSettingsButton.sidebarAccessibilityElement.setAccessibilityLabel("Window Capture Settings")
        windowSettingsButton.sidebarAccessibilityElement.setAccessibilityIdentifier("sidebar.window.settings")
        let menu = NSMenu()
        menu.autoenablesItems = false
        let icon = NSMenuItem(title: "Window Capture Settings", action: nil, keyEquivalent: "")
        icon.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
        menu.addItem(icon)
        menu.addItem(.sectionHeader(title: "Frame Rate"))
        for rate in [24, 30, 60] {
            let item = NSMenuItem(title: "\(rate) fps", action: #selector(changeFrameRate(_:)), keyEquivalent: "")
            item.target = self
            item.tag = rate
            menu.addItem(item)
        }
        windowSettingsButton.menu = menu
        sections[.windows]?.append(actionRow([pickWindow, clearWindow, windowSettingsButton, flexibleSpace()]))
        sections[.windows]?.append(windowOutline.scrollView)
    }

    private func updateWindowSettings() {
        let rate = configuration.windowCaptureFrameRate
        for item in windowSettingsButton.itemArray where [24, 30, 60].contains(item.tag) {
            item.state = item.tag == rate ? .on : .off
        }
        windowSettingsButton.toolTip = "Window capture settings — \(rate) fps"
        windowSettingsButton.sidebarAccessibilityElement.setAccessibilityValueDescription("\(rate) frames per second")
    }

    private func buildFailureNotice() {
        failureNotice.orientation = .vertical
        failureNotice.alignment = .leading
        failureNotice.spacing = 6
        let title = NSTextField(wrappingLabelWithString: "Library couldn’t be refreshed")
        title.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        failurePath.maximumNumberOfLines = 2
        failurePath.lineBreakMode = .byTruncatingMiddle
        for field in [failurePath, failureMessage, retainedLibraryNotice] {
            field.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            field.textColor = .secondaryLabelColor
        }
        retryLibrary = button("Retry", identifier: "sidebar.library.retry", help: "Refresh Library and Audio")
        for child in [title, failurePath, failureMessage, retainedLibraryNotice] {
            failureNotice.addArrangedSubview(child)
            child.widthAnchor.constraint(equalTo: failureNotice.widthAnchor).isActive = true
        }
        failureNotice.addArrangedSubview(retryLibrary)
    }

    private func updateFailureNotice() {
        failureNotice.isHidden = configuration.libraryLoadFailure == nil
        if let failure = configuration.libraryLoadFailure {
            failurePath.stringValue = failure.url.path
            failurePath.toolTip = failure.url.path
            failureMessage.stringValue = failure.message
            retainedLibraryNotice.isHidden = configuration.libraryFiles.isEmpty && configuration.audioFiles.isEmpty
        }
    }

    private func expandedPreference(_ section: SidebarSection) -> Bool {
        defaults.object(forKey: section.preferenceKey) as? Bool ?? section.defaultExpanded
    }

    private func setExpanded(_ expanded: Bool, section: SidebarSection) {
        applySectionExpansion(expanded, section: section)
        defaults.set(expanded, forKey: section.preferenceKey)
    }

    private func applySectionExpansion(_ expanded: Bool, section: SidebarSection) {
        sections[section]?.setExpanded(expanded)
        guard expanded else { return }
        switch section {
        case .library:
            groupingPopup.selectItem(at: LibraryGrouping.allCases.firstIndex(of: grouping) ?? 0)
        case .audio:
            refreshAudioState()
        case .windows:
            updateWindowSettings()
        case .playlist:
            break
        }
    }

    private func restorePreferences() {
        guard !isDetached else { return }
        var changed = false
        for section in SidebarSection.allCases where sections[section]?.isExpanded != expandedPreference(section) {
            applySectionExpansion(expandedPreference(section), section: section)
            changed = true
        }
        let savedGrouping = defaults.string(forKey: "sidebar.libraryGrouping").flatMap(LibraryGrouping.init(rawValue:)) ?? .kind
        if savedGrouping != grouping {
            grouping = savedGrouping
            groupingPopup.selectItem(at: LibraryGrouping.allCases.firstIndex(of: grouping) ?? 0)
            prepareLibraryIfNeeded()
            changed = true
        }
        if changed { updateOutlines() }
    }

    @objc private func toggleSection(_ sender: SidebarSectionHeaderButton) {
        guard acceptsAction(from: sender), let section = sections[sender.section] else { return }
        setExpanded(!section.isExpanded, section: sender.section)
        updateOutlines()
    }

    private func acceptsAction(from control: NSView) -> Bool {
        !isDetached && !isApplyingSnapshot && control.window != nil
            && control.isDescendant(of: view) && !control.isHiddenOrHasHiddenAncestor
    }

    @objc private func changeGrouping(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let grouping = LibraryGrouping(rawValue: raw),
              acceptsAction(from: sender), sender.isEnabled else { return }
        self.grouping = grouping
        defaults.set(raw, forKey: "sidebar.libraryGrouping")
        updateLibraryOutline()
        prepareLibraryIfNeeded()
    }

    @objc private func changeFrameRate(_ sender: NSMenuItem) {
        let rate = sender.tag
        guard acceptsAction(from: windowSettingsButton), windowSettingsButton.isEnabled,
              sender.menu === windowSettingsButton.menu, [24, 30, 60].contains(rate) else { return }
        configuration.windowCaptureFrameRate = rate
        updateWindowSettings()
        configuration.setWindowCaptureFrameRate(rate)
    }

    @objc private func changeVolume(_ sender: NSSlider) {
        guard acceptsAction(from: sender), sender.isEnabled else { return }
        let value = min(1, max(0, sender.doubleValue))
        configuration.backgroundAudioVolumeDraft = value
        configuration.setBackgroundAudioVolumeDraft(value)
        configuration.onApplyBackgroundAudioVolume(value)
        updateVolumeValue()
    }

    @objc private func changePosition(_ sender: NSSlider) {
        guard acceptsAction(from: sender), sender.isEnabled else { return }
        configuration.onSeekBackgroundAudio(sender.doubleValue)
        currentTime.stringValue = audioTimeLabel(sender.doubleValue)
        positionSlider.sidebarAccessibilityElement.setAccessibilityValueDescription("\(currentTime.stringValue) of \(duration.stringValue)")
    }

    @objc private func performAction(_ sender: NSButton) {
        guard acceptsAction(from: sender), sender.isEnabled else { return }
        switch sender.identifier?.rawValue {
        case "sidebar.library.import": configuration.onImportToLibrary()
        case "sidebar.library.retry": configuration.onRetryLibraryLoad()
        case "sidebar.audio.import": configuration.onImportToAudio()
        case "sidebar.playlist.remove": configuration.onRemoveSelectedFromPlaylist()
        case "sidebar.playlist.up": configuration.onMovePlaylistUp()
        case "sidebar.playlist.down": configuration.onMovePlaylistDown()
        case "sidebar.window.pick": configuration.onPickWindow()
        case "sidebar.window.clear": configuration.onClearSelectedWindow()
        case "sidebar.audio.play": performAudio(AudioSidebarInteraction.toggleAction(selectedURL: configuration.selectedAudioURL, activeURL: activeAudioURL))
        case "sidebar.audio.stop": configuration.onStopBackgroundAudio()
        case "sidebar.audio.clear":
            configuration.selectedAudioURL = nil
            configuration.setSelectedAudioURL(nil)
            configuration.onClearBackgroundAudio()
        case "sidebar.audio.loop":
            configuration.backgroundAudioLoop = sender.state == .on
            configuration.setBackgroundAudioLoop(sender.state == .on)
        case "sidebar.library.toggleGroups":
            libraryExpansionCommand = SidebarOutlineExpansionCommand(action: libraryExpansionState.areAllGroupsCollapsed ? .expandAll : .collapseAll)
            updateLibraryOutline()
        default: break
        }
    }

    private var activeAudioURL: URL? { configuration.session.backgroundAudioURL?.standardizedFileURL }

    private func performAudio(_ intent: AudioSidebarPlaybackIntent) {
        switch intent {
        case .none: break
        case .selectAndPlay(let url): configuration.onSelectBackgroundAudio(url)
        case .togglePlayback: configuration.onPlayPauseBackgroundAudio()
        }
    }

    private func refreshAudioState() {
        let session = configuration.session
        let playing = session.isBackgroundAudioPlaying && (configuration.selectedAudioURL?.standardizedFileURL ?? activeAudioURL) == activeAudioURL
        playAudio.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill", accessibilityDescription: nil)
        playAudio.sidebarAccessibilityElement.setAccessibilityLabel(playing ? "Pause Background Audio" : "Play Background Audio")
        playAudio.toolTip = playing ? "Pause Background Audio" : "Play Background Audio"
        playAudio.isEnabled = configuration.selectedAudioURL != nil || activeAudioURL != nil
        for control in [stopAudio, clearAudio, loopAudio] { control?.isEnabled = activeAudioURL != nil }
        loopAudio.state = configuration.backgroundAudioLoop ? .on : .off
        volumeSlider.isEnabled = activeAudioURL != nil
        if !volumeSlider.isTracking { volumeSlider.doubleValue = configuration.backgroundAudioVolumeDraft }
        updateVolumeValue()
        refreshProgressControls()
    }

    private func updateVolumeValue() {
        let value = "\(Int((volumeSlider.doubleValue * 100).rounded()))%"
        volumeLabel.stringValue = value
        volumeSlider.sidebarAccessibilityElement.setAccessibilityValueDescription(value)
        volumeSlider.toolTip = "Background music volume for NDI and local playback. For local listening, use Output → Listen on This Mac."
    }

    private func refreshProgressControls() {
        let progress = configuration.session.playbackProgress
        positionSlider.isEnabled = activeAudioURL != nil && progress.backgroundAudioDuration > 0
        guard !positionSlider.isTracking else { return }
        positionSlider.maxValue = max(1, progress.backgroundAudioDuration)
        positionSlider.doubleValue = progress.backgroundAudioCurrentTime
        currentTime.stringValue = audioTimeLabel(progress.backgroundAudioCurrentTime)
        duration.stringValue = audioTimeLabel(progress.backgroundAudioDuration)
        positionSlider.sidebarAccessibilityElement.setAccessibilityValueDescription("\(currentTime.stringValue) of \(duration.stringValue)")
    }

    private func audioTimeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let value = Int(seconds.rounded(.down))
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }

    private func makeOutline(section: SidebarSection) -> SidebarOutlineController {
        let controller = SidebarOutlineController(configuration: SidebarOutlineConfiguration(
            contentRevision: 0, modelBuilder: { .empty }, selectedItemIDs: [], primarySelectedItemID: nil,
            expansionStore: expansionStore, allowsEmptySelection: true, onSelectionChange: { _, _ in true }
        ))
        controller.outlineView.setAccessibilityLabel("\(section.title) items")
        controller.outlineView.setAccessibilityIdentifier("sidebar.\(section.rawValue).outline")
        return controller
    }

    private var libraryRevision: LibraryOutlineRevision {
        LibraryOutlineRevision(libraryRevision: configuration.libraryRevision, grouping: grouping, libraryRootURL: configuration.libraryRootURL?.standardizedFileURL)
    }

    private var libraryExpansionKey: String { "library:\(grouping.rawValue)" }

    private func prepareLibraryIfNeeded() {
        let revision = libraryRevision
        guard requestedLibraryRevision != revision else { return }
        requestedLibraryRevision = revision
        libraryTask?.cancel()
        guard !configuration.libraryFiles.isEmpty else { return }
        let files = configuration.libraryFiles
        let displayName = configuration.displayName
        libraryTask = Task { [weak self] in
            guard let self else { return }
            await libraryModels.prepare(revision: revision) {
                files.map { LibraryOutlineSourceItem(url: $0.standardizedFileURL, title: displayName($0)) }
            }
            guard !Task.isCancelled, !isDetached, libraryRevision == revision else { return }
            updateLibraryOutline()
        }
    }

    private func updateOutlines() {
        updateLibraryOutline()
        updatePlaylistOutline()
        updateAudioOutline()
        updateWindowOutline()
    }

    private func navigationSection(_ section: SidebarSection) -> SidebarOutlineNavigationSection? {
        guard sections[section]?.isExpanded == true, sections[section]?.isHidden == false else { return nil }
        return navigationIdentity(section)
    }

    private func navigationIdentity(_ section: SidebarSection) -> SidebarOutlineNavigationSection {
        switch section {
        case .library: return .library
        case .playlist: return .playlist
        case .windows: return .window
        case .audio: return .audio
        }
    }

    private func outline(for section: SidebarSection) -> SidebarOutlineController {
        switch section {
        case .library: libraryOutline
        case .playlist: playlistOutline
        case .audio: audioOutline
        case .windows: windowOutline
        }
    }

    private func setOutlineHidden(_ hidden: Bool, section: SidebarSection) {
        let outline = outline(for: section)
        if hidden, !outline.scrollView.isHidden,
           let responder = view.window?.firstResponder as? NSView,
           responder === outline.outlineView || responder.isDescendant(of: outline.outlineView) {
            _ = focusHeader(section)
        }
        outline.scrollView.isHidden = hidden
    }

    private func configureSectionNavigation() {
        for section in SidebarSection.allCases {
            navigation.register(
                for: navigationIdentity(section),
                isAvailable: { [weak self] in
                    guard let self, !isDetached, let view = sections[section],
                          view.window != nil else { return false }
                    return !view.isHiddenOrHasHiddenAncestor
                },
                hasVisibleRows: { [weak self] in
                    guard let self, !isDetached, sections[section]?.isExpanded == true else { return false }
                    return outline(for: section).hasVisibleRows
                },
                focusHeader: { [weak self] in self?.focusHeader(section) ?? false },
                focusBoundaryRow: { [weak self] direction in
                    guard let self, !isDetached else { return false }
                    return outline(for: section).focusBoundaryRow(for: direction)
                }
            )
            sections[section]?.header.navigationHandler = { [weak self] command in
                self?.navigateSection(section, command: command)
            }
        }
    }

    private func focusHeader(_ section: SidebarSection) -> Bool {
        guard !isDetached, let header = sections[section]?.header,
              let window = header.window, !header.isHiddenOrHasHiddenAncestor else { return false }
        header.scrollToVisible(header.bounds)
        return window.makeFirstResponder(header)
    }

    private func navigateSection(_ section: SidebarSection, command: SidebarSectionNavigationCommand) {
        guard !isDetached, let sectionView = sections[section], !sectionView.isHiddenOrHasHiddenAncestor else { return }
        switch command {
        case .up, .down:
            _ = navigation.moveFromHeader(
                from: navigationIdentity(section), direction: command == .up ? .up : .down,
                restoreSourceFocus: { [weak self] in _ = self?.focusHeader(section) }
            )
        case .right:
            if !sectionView.isExpanded {
                setExpanded(true, section: section)
                updateOutlines()
            } else if outline(for: section).hasVisibleRows,
                      !outline(for: section).focusBoundaryRow(for: .down) {
                _ = focusHeader(section)
            }
        case .left:
            if sectionView.isExpanded {
                setExpanded(false, section: section)
                updateOutlines()
            }
        }
    }

    private func updateLibraryOutline() {
        let presentation = libraryModels.presentation
        let isPrepared = presentation?.revision == libraryRevision
        let sameSource = presentation.map {
            $0.revision.grouping == grouping && $0.revision.libraryRootURL == libraryRevision.libraryRootURL
        } ?? false
        let hideOutline = configuration.libraryFiles.isEmpty || (!isPrepared && !sameSource)
        setOutlineHidden(hideOutline, section: .library)
        libraryCaption.superview?.isHidden = !libraryOutline.scrollView.isHidden || (configuration.libraryFiles.isEmpty && configuration.libraryLoadFailure != nil)
        libraryCaption.stringValue = configuration.libraryFiles.isEmpty
            ? (configuration.isLibraryLoading ? "Loading library…" : "No supported files in Library")
            : "Preparing \(grouping.title) view…"
        // Same-source preparation keeps the last complete list visible so its
        // native keyboard ownership survives. A new root/grouping waits at its
        // header; an actual empty inventory clears the native model below.
        guard configuration.libraryFiles.isEmpty || isPrepared else {
            updateGroupButton()
            return
        }
        let model = configuration.libraryFiles.isEmpty ? .empty : presentation!.model
        let selected: SidebarOutlineItemID? = if case .library(let url) = configuration.sidebarSelection { .library(url.standardizedFileURL) } else { nil }
        libraryOutline.update(SidebarOutlineConfiguration(
            contentRevision: AnyHashable(libraryRevision),
            expansionKey: libraryExpansionKey, modelBuilder: { model }, selectedItemIDs: selected.map { [$0] } ?? [], primarySelectedItemID: selected,
            scrollRequest: configuration.libraryScrollRequest.map { .init(id: $0.id, itemID: .library($0.url.standardizedFileURL)) },
            expansionCommand: libraryExpansionCommand, expansionStore: expansionStore,
            navigationSection: libraryOutline.scrollView.isHidden ? nil : navigationSection(.library), navigationCoordinator: navigation, allowsEmptySelection: true,
            onSelectionChange: { [weak self] _, primary in
                guard let self, !isDetached, !isApplyingSnapshot else { return false }
                guard let primary else { return configuration.onSelectionRequest(nil, []) }
                guard case .library(let url) = primary,
                      configuration.libraryFiles.contains(where: { $0.standardizedFileURL == url }) else { return false }
                return configuration.onSelectionRequest(.library(url), [])
            }, onAction: { [weak self] item, action in
                guard let self, !isDetached, !isApplyingSnapshot, case .library(let url) = item,
                      configuration.libraryFiles.contains(where: { $0.standardizedFileURL == url }) else { return }
                switch action {
                case .addToPlaylist: configuration.onAddLibraryItemToPlaylist(url)
                case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([url])
                case .moveToTrash: configuration.onMoveFileToTrash(url)
                case .remove: break
                }
            }, onExpansionStateChange: { [weak self] state in
                guard let self, !isDetached, state.key == libraryExpansionKey else { return }
                libraryExpansionState = state
                updateGroupButton()
            }
        ))
        updateGroupButton()
    }

    private func updateGroupButton() {
        let collapsed = libraryExpansionState.key == libraryExpansionKey && libraryExpansionState.areAllGroupsCollapsed
        toggleGroups.isEnabled = grouping != .none && libraryModels.presentation?.revision == libraryRevision && libraryExpansionState.key == libraryExpansionKey && libraryExpansionState.groupCount > 0
        let action = collapsed ? "Expand" : "Collapse"
        let help = grouping == .none ? "Choose Kind or Folder grouping to collapse sections" : "\(action) all \(grouping == .kind ? "kinds" : "folders")"
        toggleGroups.toolTip = help
        toggleGroups.sidebarAccessibilityElement.setAccessibilityLabel(help)
        toggleGroups.image = NSImage(systemSymbolName: collapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical", accessibilityDescription: nil)
    }

    private func updatePlaylistOutline() {
        let items = configuration.playlistItems
        setOutlineHidden(items.isEmpty, section: .playlist)
        playlistCaption.superview?.isHidden = !items.isEmpty
        let selected: SidebarOutlineItemID? = if case .playlist(let id) = configuration.sidebarSelection { .playlist(id) } else { nil }
        playlistOutline.update(SidebarOutlineConfiguration(
            contentRevision: AnyHashable(items), modelBuilder: {
                SidebarOutlineModel(roots: items.map { SidebarOutlineItem(id: .playlist($0.id), title: $0.title, isMissing: !$0.exists, accessoryAction: .remove, contextActions: [.remove]) })
            }, selectedItemIDs: Set(configuration.selectedPlaylistEntryIDs.map { .playlist($0) }), primarySelectedItemID: selected,
            expansionStore: expansionStore, navigationSection: items.isEmpty ? nil : navigationSection(.playlist), navigationCoordinator: navigation,
            allowsMultipleSelection: true, allowsEmptySelection: true,
            onSelectionChange: { [weak self] ids, primary in
                guard let self, !isDetached, !isApplyingSnapshot else { return false }
                let ids = Set(ids.compactMap { if case .playlist(let id) = $0 { id } else { nil } })
                let primaryID: UUID? = if case .playlist(let id) = primary { id } else { ids.first }
                return configuration.onSelectionRequest(primaryID.map(SidebarSelection.playlist), ids)
            }, onAction: { [weak self] item, action in
                guard let self, !isDetached, !isApplyingSnapshot, case .playlist(let id) = item, action == .remove else { return }
                configuration.onRemovePlaylistItem(id)
            }
        ))
    }

    private func updateAudioOutline() {
        let files = configuration.audioFiles
        setOutlineHidden(files.isEmpty, section: .audio)
        audioCaption.superview?.isHidden = !files.isEmpty || configuration.libraryLoadFailure != nil
        let selected = configuration.selectedAudioURL.map { SidebarOutlineItemID.audio($0.standardizedFileURL) }
        var statuses: [SidebarOutlineItemID: SidebarOutlineItemStatus] = [:]
        if let activeAudioURL {
            let status: SidebarOutlineItemStatus = switch configuration.session.backgroundAudioPlaybackState {
            case .stopped: .stoppedAudio
            case .paused: .pausedAudio
            case .playing: .playingAudio
            }
            statuses[.audio(activeAudioURL)] = status
        }
        audioOutline.update(SidebarOutlineConfiguration(
            contentRevision: AnyHashable(configuration.libraryRevision), modelBuilder: {
                SidebarOutlineModel(roots: files.map { SidebarOutlineItem(id: .audio($0.standardizedFileURL), title: self.configuration.displayName($0), contextActions: [.revealInFinder, .moveToTrash]) })
            }, selectedItemIDs: selected.map { [$0] } ?? [], primarySelectedItemID: selected, itemStatuses: statuses,
            expansionStore: expansionStore, navigationSection: files.isEmpty ? nil : navigationSection(.audio),
            navigationCoordinator: navigation, allowsEmptySelection: true,
            onSelectionChange: { [weak self] _, primary in
                guard let self, !isDetached, !isApplyingSnapshot else { return false }
                let url: URL? = if case .audio(let url) = primary { url.standardizedFileURL } else { nil }
                configuration.selectedAudioURL = url
                configuration.setSelectedAudioURL(url)
                refreshAudioState()
                return true
            }, onDefaultAction: { [weak self] item in
                guard let self, !isDetached, !isApplyingSnapshot, case .audio(let url) = item else { return }
                configuration.selectedAudioURL = url
                configuration.setSelectedAudioURL(url)
                performAudio(AudioSidebarInteraction.defaultAction(targetURL: url, activeURL: activeAudioURL, isPlaying: configuration.session.isBackgroundAudioPlaying))
            }, onSpaceAction: { [weak self] item in
                guard let self, !isDetached, !isApplyingSnapshot else { return }
                if case .audio(let url) = item {
                    configuration.selectedAudioURL = url
                    configuration.setSelectedAudioURL(url)
                }
                performAudio(AudioSidebarInteraction.toggleAction(selectedURL: configuration.selectedAudioURL, activeURL: activeAudioURL))
            }, onAction: { [weak self] item, action in
                guard let self, !isDetached, !isApplyingSnapshot, case .audio(let url) = item,
                      configuration.audioFiles.contains(where: { $0.standardizedFileURL == url }) else { return }
                switch action {
                case .revealInFinder: NSWorkspace.shared.activateFileViewerSelecting([url])
                case .moveToTrash: configuration.onMoveFileToTrash(url)
                case .addToPlaylist, .remove: break
                }
            }
        ))
    }

    private func updateWindowOutline() {
        let windows = configuration.captureWindows
        setOutlineHidden(windows.isEmpty, section: .windows)
        let selected: SidebarOutlineItemID? = if case .window(let id) = configuration.sidebarSelection { .window(id) } else { nil }
        windowOutline.update(SidebarOutlineConfiguration(
            contentRevision: AnyHashable(windows.map { "\($0.windowID)|\($0.appName)|\($0.title)" }), modelBuilder: {
                SidebarOutlineModel(roots: windows.map { SidebarOutlineItem(id: .window($0.windowID), title: $0.title == $0.appName ? $0.appName : "\($0.appName): \($0.title)") })
            }, selectedItemIDs: selected.map { [$0] } ?? [], primarySelectedItemID: selected,
            expansionStore: expansionStore, navigationSection: windows.isEmpty ? nil : navigationSection(.windows), navigationCoordinator: navigation,
            allowsEmptySelection: true, onSelectionChange: { [weak self] _, primary in
                guard let self, !isDetached, !isApplyingSnapshot else { return false }
                guard let primary else { return configuration.onSelectionRequest(nil, []) }
                guard case .window(let id) = primary else { return false }
                return configuration.onSelectionRequest(.window(id), [])
            }
        ))
    }
}

private final class SidebarDocumentStackView: NSStackView {
    override var isFlipped: Bool { true }
}
