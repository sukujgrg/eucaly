import AppKit
import XCTest
@testable import eucaly

@MainActor
final class SidebarControlLayoutTests: XCTestCase {
    func testProductionSidebarActionsAlignAndFitAtMinimumAndLargerWidths() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        for width: CGFloat in [260, 520, 260] {
            fixture.window.setContentSize(.init(width: width, height: 1000))
            try await settle(fixture.window)
            XCTAssertEqual(fixture.controller.view.bounds.width, width, accuracy: 1, "Controls must fit without widening the sidebar")
            try fixture.saveSnapshot(width: width)
            let elements = accessibilityElements(in: fixture.window)
            let libraryImport = try element("sidebar.library.import", in: elements)
            let audioImport = try element("sidebar.audio.import", in: elements)
            let pickWindow = try element("sidebar.window.pick", in: elements)
            let windowSettings = try element("sidebar.window.settings", in: elements)
            let libraryHeader = try element("sidebar.library.header", in: elements)
            let headerFrame = libraryHeader.accessibilityFrame()
            let viewport = fixture.controller.scrollView.contentView
            let viewportFrame = fixture.window.convertToScreen(viewport.convert(viewport.bounds, to: nil))
            for control in [libraryImport, audioImport, pickWindow] {
                XCTAssertEqual(control.accessibilityFrame().minX, libraryImport.accessibilityFrame().minX, accuracy: 1)
                XCTAssertEqual(control.accessibilityFrame().height, libraryImport.accessibilityFrame().height, accuracy: 1)
            }
            XCTAssertEqual(headerFrame.minX - viewportFrame.minX, SidebarSectionMetrics.outerInset, accuracy: 1)
            XCTAssertEqual(viewportFrame.maxX - headerFrame.maxX, SidebarSectionMetrics.outerInset, accuracy: 1)
            // Native control alignment rectangles include their platform bezel
            // outsets; measure the content gutters using those rectangles.
            let importButton = try XCTUnwrap(nativeViews(NSButton.self, in: fixture.controller.view).first { $0.identifier?.rawValue == "sidebar.library.import" })
            let importRect = fixture.window.convertToScreen(importButton.superview!.convert(importButton.alignmentRect(forFrame: importButton.frame), to: nil))
            XCTAssertEqual(importRect.minX - headerFrame.minX, SidebarSectionMetrics.contentInset, accuracy: 1)
            let sectionActions = [
                ["sidebar.library.import", "sidebar.library.grouping", "sidebar.library.toggleGroups"],
                ["sidebar.playlist.remove", "sidebar.playlist.up", "sidebar.playlist.down"],
                ["sidebar.audio.import", "sidebar.audio.play", "sidebar.audio.stop", "sidebar.audio.clear", "sidebar.audio.loop"],
                ["sidebar.window.pick", "sidebar.window.clear", "sidebar.window.settings"]
            ]
            for identifiers in sectionActions {
                let frames = try identifiers.map { try element($0, in: elements).accessibilityFrame() }
                for frame in frames {
                    XCTAssertEqual(frame.midY, frames[0].midY, accuracy: 1, "Section actions must share one row: \(identifiers)")
                }
                for (left, right) in zip(frames, frames.dropFirst()) {
                    XCTAssertLessThanOrEqual(left.maxX, right.minX, "Adjacent controls must not overlap")
                    XCTAssertLessThanOrEqual(right.minX - left.maxX, 16, "Section actions must remain grouped at wider sidebar sizes")
                }
            }
            for control in try sectionActions.flatMap({ $0 }).map({ try element($0, in: elements) }) {
                let frame = control.accessibilityFrame()
                XCTAssertGreaterThan(frame.width, 0)
                XCTAssertGreaterThan(frame.height, 0)
                XCTAssertGreaterThanOrEqual(frame.minX, viewportFrame.minX)
                XCTAssertLessThanOrEqual(frame.maxX, viewportFrame.maxX)
            }
            for outline in nativeViews(NSOutlineView.self, in: fixture.controller.view) where !outline.isHiddenOrHasHiddenAncestor && outline.numberOfRows == 1 {
                let clip = try XCTUnwrap(outline.enclosingScrollView?.contentView)
                let row = outline.convert(outline.rect(ofRow: 0), to: clip)
                XCTAssertGreaterThanOrEqual(row.minY, clip.bounds.minY)
                XCTAssertLessThanOrEqual(row.maxY, clip.bounds.maxY)
            }
            XCTAssertEqual(windowSettings.accessibilityRole(), .menuButton)
            XCTAssertEqual(windowSettings.accessibilityLabel(), "Window Capture Settings")
            XCTAssertEqual(windowSettings.accessibilityValueDescription(), "30 frames per second")
            XCTAssertEqual(libraryImport.accessibilityLabel(), "Import files into Library")
            XCTAssertEqual(audioImport.accessibilityLabel(), "Import audio or video files for background audio")
            XCTAssertEqual(fixture.calls.count, 0)
            XCTAssertTrue(fixture.calls.selections.isEmpty)
            XCTAssertTrue(fixture.session.slides.isEmpty)
            XCTAssertFalse(fixture.session.isPresenting)
        }
    }

    func testProductionAudioSlidersExposeTheirPurposeAndFormattedValues() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        let elements = accessibilityElements(in: fixture.window)
        let volume = try element("sidebar.audio.volume", in: elements)
        let position = try element("sidebar.audio.position", in: elements)
        XCTAssertEqual(volume.accessibilityRole(), .slider)
        XCTAssertEqual(volume.accessibilityLabel(), "Background audio volume")
        XCTAssertEqual(volume.accessibilityValueDescription(), "37%")
        XCTAssertEqual(position.accessibilityLabel(), "Background audio position")
        XCTAssertEqual(position.accessibilityValueDescription(), "1:05 of 4:10")
        XCTAssertFalse(volume.isAccessibilityEnabled())
        XCTAssertFalse(position.isAccessibilityEnabled())
        let outlines = nativeViews(NSOutlineView.self, in: fixture.controller.view)
        let firstItems = outlines.map { $0.item(atRow: 0) as? SidebarOutlineItem }
        fixture.session.playbackProgress.updateBackgroundAudio(currentTime: 75, duration: 250)
        try await settle(fixture.window)
        XCTAssertEqual(fixture.controller.positionSlider.doubleValue, 75)
        XCTAssertEqual(position.accessibilityValueDescription(), "1:15 of 4:10")
        for (outline, original) in zip(outlines, firstItems) {
            XCTAssertTrue(outline.item(atRow: 0) as? SidebarOutlineItem === original, "Progress updates must not rebuild lists")
        }
        XCTAssertFalse(fixture.controller.positionSlider.isContinuous, "A drag commits one seek on release")
        XCTAssertEqual(fixture.calls.count, 0)
    }

    func testNativeFrameRateChoiceUpdatesBindingAndDisclosureKeepsIt() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        let popup = fixture.controller.windowSettingsButton
        let menu = try XCTUnwrap(popup.menu)
        let choices = menu.items.filter { [24, 30, 60].contains($0.tag) }
        XCTAssertTrue(popup.pullsDown)
        XCTAssertEqual(choices.map(\.title), ["24 fps", "30 fps", "60 fps"])
        XCTAssertEqual(choices.filter { $0.state == .on }.map(\.tag), [30])
        menu.performActionForItem(at: menu.indexOfItem(withTag: 24))
        XCTAssertEqual(fixture.frameRateSelection.value, 24)
        XCTAssertEqual(choices.filter { $0.state == .on }.map(\.tag), [24])
        let header = try XCTUnwrap(nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view).first { $0.section == .windows })
        _ = header.sidebarAccessibilityElement.accessibilityPerformPress()
        try await settle(fixture.window)
        XCTAssertFalse(fixture.isWindowSectionExpanded)
        XCTAssertTrue(popup.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(header.sidebarAccessibilityElement.accessibilityValueDescription(), "Collapsed")
        _ = header.sidebarAccessibilityElement.accessibilityPerformPress()
        try await settle(fixture.window)
        XCTAssertTrue(fixture.isWindowSectionExpanded)
        XCTAssertFalse(popup.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(choices.filter { $0.state == .on }.map(\.tag), [24])
        var next = fixture.configuration
        next.windowCaptureFrameRate = 60
        fixture.controller.update(next)
        XCTAssertEqual(choices.filter { $0.state == .on }.map(\.tag), [60])
        XCTAssertEqual(popup.sidebarAccessibilityElement.accessibilityValueDescription(), "60 frames per second")
        XCTAssertEqual(fixture.frameRateSelection.value, 24, "An incoming preference must not send an editing action")
        XCTAssertEqual(fixture.calls.count, 0)
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertFalse(fixture.session.isPresenting)
    }

    func testHeaderHitAreaIncludesContentAndCollapseRestoresFocus() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        let header = try XCTUnwrap(nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view).first { $0.section == .audio })
        let parent = try XCTUnwrap(header.superview)
        for fraction: CGFloat in [0.02, 0.10, 0.35, 0.70, 0.95] {
            let point = header.convert(NSPoint(x: header.bounds.width * fraction, y: header.bounds.midY), to: parent)
            XCTAssertTrue(header.hitTest(point) === header, "Icon, title, spacer and disclosure must share the button hit area")
        }
        let audioImport = try XCTUnwrap(nativeViews(NSButton.self, in: fixture.controller.view).first { $0.identifier?.rawValue == "sidebar.audio.import" })
        XCTAssertTrue(fixture.window.makeFirstResponder(audioImport))
        _ = header.sidebarAccessibilityElement.accessibilityPerformPress()
        try await settle(fixture.window)
        XCTAssertTrue(fixture.window.firstResponder === header)
        XCTAssertTrue(fixture.controller.volumeSlider.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(fixture.calls.count, 0)
    }

    func testSpaceActivatesFocusedNativeSectionHeader() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        let header = try XCTUnwrap(nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view).first { $0.section == .windows })
        XCTAssertTrue(fixture.window.makeFirstResponder(header))
        let down = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        header.keyDown(with: down)
        try await settle(fixture.window)
        XCTAssertFalse(fixture.isWindowSectionExpanded)
        XCTAssertTrue(fixture.window.firstResponder === header)
        let repeated = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: true, keyCode: 49))
        header.keyDown(with: repeated)
        XCTAssertFalse(fixture.isWindowSectionExpanded, "Holding Space must not repeatedly toggle a disclosure")
        XCTAssertEqual(fixture.calls.count, 0)
    }

    func testDynamicNativeAccessibilityStateTracksMenusAndCheckboxes() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        let buttons = nativeViews(NSButton.self, in: fixture.controller.view)
        let groups = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "sidebar.library.toggleGroups" })
        XCTAssertEqual(groups.sidebarAccessibilityElement.accessibilityLabel(), "Expand all kinds")
        _ = groups.sidebarAccessibilityElement.accessibilityPerformPress()
        try await settle(fixture.window)
        XCTAssertEqual(groups.sidebarAccessibilityElement.accessibilityLabel(), "Collapse all kinds")
        fixture.controller.groupingPopup.selectItem(withTitle: "Folder")
        _ = fixture.controller.groupingPopup.sendAction(fixture.controller.groupingPopup.action, to: fixture.controller.groupingPopup.target)
        try await settle(fixture.window)
        XCTAssertEqual(groups.sidebarAccessibilityElement.accessibilityLabel(), "Expand all folders")
        let pick = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "sidebar.window.pick" })
        XCTAssertEqual(pick.sidebarAccessibilityElement.accessibilityLabel(), "Replace Window")
        var next = fixture.configuration
        next.captureWindows = []
        next.backgroundAudioLoop = true
        fixture.controller.update(next)
        XCTAssertEqual(pick.sidebarAccessibilityElement.accessibilityLabel(), "Pick Window")
        let loop = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "sidebar.audio.loop" })
        XCTAssertEqual(loop.sidebarAccessibilityElement.accessibilityRole(), .checkBox)
        XCTAssertEqual(loop.sidebarAccessibilityElement.accessibilityValue() as? NSNumber, 1)
        XCTAssertFalse(loop.sidebarAccessibilityElement.isAccessibilityEnabled())
        XCTAssertEqual(fixture.calls.count, 0)
        XCTAssertTrue(fixture.calls.selections.isEmpty)
    }

    func testLibraryFailureRetainsNativeListsAndRetryRecovers() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        var failed = fixture.configuration
        failed.libraryLoadFailure = LibraryLoadFailure(url: URL(fileURLWithPath: "/sidebar-control-fixture"), error: CocoaError(.fileReadNoPermission))
        fixture.controller.update(failed)
        try await settle(fixture.window)
        let retry = try XCTUnwrap(nativeViews(NSButton.self, in: fixture.controller.view).first { $0.identifier?.rawValue == "sidebar.library.retry" })
        XCTAssertFalse(retry.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(retry.isEnabled)
        let playlist = try XCTUnwrap(nativeViews(NSOutlineView.self, in: fixture.controller.view).first { $0.accessibilityIdentifier() == "sidebar.playlist.outline" })
        XCTAssertEqual(playlist.numberOfRows, 1)
        _ = retry.sidebarAccessibilityElement.accessibilityPerformPress()
        XCTAssertEqual(fixture.calls.count, 1)
        failed.isLibraryLoading = true
        fixture.controller.update(failed)
        XCTAssertFalse(retry.isEnabled)
        fixture.controller.update(fixture.configuration)
        try await settle(fixture.window)
        XCTAssertTrue(retry.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertFalse(fixture.session.isPresenting)
    }

    func testArrowTraversalSkipsCollapsedPlaylistAndAudioAndHonorsSelectionRejection() async throws {
        for acceptsSelection in [true, false] {
            let fixture = try SidebarControlsFixture(grouping: .none, selectsLibraryItem: true)
            defer { fixture.close() }
            try await settle(fixture.window)
            fixture.calls.acceptsSelection = acceptsSelection
            let outlines = nativeViews(NSOutlineView.self, in: fixture.controller.view)
            let library = try XCTUnwrap(outlines.first { $0.accessibilityIdentifier() == "sidebar.library.outline" })
            let windows = try XCTUnwrap(outlines.first { $0.accessibilityIdentifier() == "sidebar.windows.outline" })
            let playlistHeader = try XCTUnwrap(nativeViews(SidebarSectionHeaderButton.self, in: fixture.controller.view).first { $0.section == .playlist })
            _ = playlistHeader.sidebarAccessibilityElement.accessibilityPerformPress()
            try await settle(fixture.window)
            XCTAssertEqual(library.selectedRow, 0)
            XCTAssertTrue(fixture.window.makeFirstResponder(library))
            library.moveDown(nil)
            try await settle(fixture.window)
            XCTAssertEqual(fixture.calls.selections, [.window(42)])
            XCTAssertTrue(fixture.window.firstResponder === (acceptsSelection ? windows : library))
            XCTAssertEqual(windows.selectedRow, acceptsSelection ? 0 : -1)
            XCTAssertEqual(fixture.calls.count, 0)
            XCTAssertTrue(fixture.session.slides.isEmpty)
        }
    }

    func testPassiveUpdatesAndRetainedControlsAreSilentAfterDetach() async throws {
        let fixture = try SidebarControlsFixture()
        defer { fixture.close() }
        try await settle(fixture.window)
        fixture.controller.update(fixture.configuration)
        XCTAssertEqual(fixture.calls.count, 0)
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        let playlist = try XCTUnwrap(nativeViews(NSOutlineView.self, in: fixture.controller.view).first { $0.accessibilityIdentifier() == "sidebar.playlist.outline" })
        let row = playlist.rect(ofRow: 0)
        let location = playlist.convert(NSPoint(x: row.midX, y: row.midY), to: nil)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let retainedMenu = try XCTUnwrap(playlist.menu(for: event))
        let button = try XCTUnwrap(nativeViews(NSButton.self, in: fixture.controller.view).first { $0.identifier?.rawValue == "sidebar.window.pick" })
        let retainedSettings = try XCTUnwrap(fixture.controller.windowSettingsButton.menu)
        fixture.session.playbackProgress.updateBackgroundAudio(currentTime: 99, duration: 250)
        fixture.controller.detach()
        button.performClick(nil)
        retainedSettings.performActionForItem(at: retainedSettings.indexOfItem(withTag: 60))
        _ = fixture.controller.volumeSlider.sendAction(fixture.controller.volumeSlider.action, to: fixture.controller.volumeSlider.target)
        _ = fixture.controller.positionSlider.sendAction(fixture.controller.positionSlider.action, to: fixture.controller.positionSlider.target)
        retainedMenu.performActionForItem(at: 0)
        try await settle(fixture.window)
        XCTAssertEqual(fixture.frameRateSelection.value, 30)
        XCTAssertEqual(fixture.controller.positionSlider.doubleValue, 65, "Queued UI refreshes must also retire on detach")
        XCTAssertEqual(fixture.calls.count, 0)
        XCTAssertTrue(fixture.calls.selections.isEmpty)
        XCTAssertTrue(fixture.session.slides.isEmpty)
        XCTAssertFalse(fixture.session.isPresenting)
    }

    private func element(_ identifier: String, in elements: [any NSAccessibilityProtocol]) throws -> any NSAccessibilityProtocol {
        try XCTUnwrap(elements.first { $0.accessibilityIdentifier() == identifier }, identifier + "\n" + elements.map { "\($0.accessibilityRole()?.rawValue ?? "nil") \($0.accessibilityIdentifier() ?? "nil")" }.joined(separator: "\n"))
    }

    private func accessibilityElements(in root: any NSAccessibilityProtocol) -> [any NSAccessibilityProtocol] {
        var result: [any NSAccessibilityProtocol] = []
        var visited: Set<ObjectIdentifier> = []
        func visit(_ element: any NSAccessibilityProtocol) {
            guard visited.insert(ObjectIdentifier(element)).inserted else { return }
            result.append(element)
            for child in element.accessibilityChildren() ?? [] {
                if let child = child as? any NSAccessibilityProtocol { visit(child) }
            }
        }
        visit(root)
        return result
    }

    private func nativeViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        let matches = (view as? T).map { [$0] } ?? []
        return matches + view.subviews.flatMap { nativeViews(type, in: $0) }
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private final class SidebarControlsFixture {
    let window: NSWindow
    let controller: SidebarViewController
    let session: PresentationSession
    let calls: SidebarControlCalls
    let frameRateSelection: SidebarFrameRateSelection
    let configuration: SidebarConfiguration
    private let defaults: UserDefaults
    private let suite: String

    init(grouping: LibraryGrouping = .kind, selectsLibraryItem: Bool = false) throws {
        let suite = "SidebarControlLayout." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.suite = suite
        self.defaults = defaults
        defaults.set(grouping.rawValue, forKey: "sidebar.libraryGrouping")
        for section in ["library", "playlist", "audio", "windows"] {
            defaults.set(true, forKey: "sidebar.\(section)SectionExpanded")
        }
        let displays = ProjectionDisplayManager(displays: { [] })
        let session = PresentationSession(projectionDisplays: displays)
        self.session = session
        session.playbackProgress.updateBackgroundAudio(currentTime: 65, duration: 250)
        let calls = SidebarControlCalls()
        self.calls = calls
        let frameRateSelection = SidebarFrameRateSelection()
        self.frameRateSelection = frameRateSelection
        let root = URL(fileURLWithPath: "/sidebar-control-fixture")
        let audio = root.appendingPathComponent("Audio/Fixture audio.mp3")
        let playlistID = UUID()
        let configuration = SidebarConfiguration(
            session: session,
            isWindowCaptureSupported: true,
            libraryFiles: [root.appendingPathComponent("Song.txt")],
            audioFiles: [audio],
            isLibraryLoading: false,
            libraryLoadFailure: nil,
            libraryRevision: 1,
            playlistItems: [.init(id: playlistID, title: "Fixture song", exists: true)],
            libraryRootURL: root,
            captureWindows: [.init(id: 42, windowID: 42, title: "Fixture window", appName: "Fixture", appBundleIdentifier: nil, frame: .init(x: 0, y: 0, width: 640, height: 480))],
            libraryScrollRequest: nil,
            selectedPlaylistEntryIDs: [playlistID],
            sidebarSelection: selectsLibraryItem ? .library(root.appendingPathComponent("Song.txt")) : nil,
            selectedAudioURL: audio,
            backgroundAudioLoop: false,
            backgroundAudioVolumeDraft: 0.37,
            windowCaptureFrameRate: frameRateSelection.value,
            displayName: { $0.lastPathComponent },
            onImportToLibrary: { calls.count += 1 },
            onRetryLibraryLoad: { calls.count += 1 },
            onImportToAudio: { calls.count += 1 },
            onAddLibraryItemToPlaylist: { _ in calls.count += 1 },
            onRemovePlaylistItem: { _ in calls.count += 1 },
            onRemoveSelectedFromPlaylist: { calls.count += 1 },
            onMovePlaylistUp: { calls.count += 1 },
            onMovePlaylistDown: { calls.count += 1 },
            onSelectBackgroundAudio: { _ in calls.count += 1 },
            onPlayPauseBackgroundAudio: { calls.count += 1 },
            onStopBackgroundAudio: { calls.count += 1 },
            onClearBackgroundAudio: { calls.count += 1 },
            onApplyBackgroundAudioVolume: { _ in calls.count += 1 },
            onSeekBackgroundAudio: { _ in calls.count += 1 },
            onSelectionRequest: { selection, _ in calls.selections.append(selection); return calls.acceptsSelection },
            onPickWindow: { calls.count += 1 },
            onClearSelectedWindow: { calls.count += 1 },
            setSelectedAudioURL: { _ in calls.count += 1 },
            setBackgroundAudioLoop: { _ in calls.count += 1 },
            setBackgroundAudioVolumeDraft: { _ in calls.count += 1 },
            setWindowCaptureFrameRate: { frameRateSelection.value = $0 }
        )
        self.configuration = configuration
        let controller = SidebarViewController(configuration: configuration, defaults: defaults)
        self.controller = controller
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 260, height: 1000),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        self.window = window
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentViewController = controller
        window.orderFrontRegardless()
    }

    var isWindowSectionExpanded: Bool { defaults.bool(forKey: "sidebar.windowsSectionExpanded") }

    func close() {
        controller.detach()
        window.contentViewController = nil
        window.close()
        defaults.removePersistentDomain(forName: suite)
    }

    func saveSnapshot(width: CGFloat) throws {
        let view = controller.view
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/sidebar-audit", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try png.write(to: directory.appendingPathComponent("sidebar-\(Int(width)).png"))
    }
}

@MainActor
private final class SidebarControlCalls {
    var count = 0
    var acceptsSelection = true
    var selections: [SidebarSelection?] = []
}

@MainActor
private final class SidebarFrameRateSelection {
    var value = 30
}
