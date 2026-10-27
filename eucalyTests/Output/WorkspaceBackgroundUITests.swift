import AppKit
import AVFoundation
import Combine
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceBackgroundUITests: XCTestCase {
    func testBookmarkCreationFailureReportsInlineWithoutReplacingBackground() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        let panel = BackgroundOpenPanel(); panel.selectedURL = fixture.visualURL
        var completeQuick: ((NSApplication.ModalResponse) -> Void)?
        let controls = OutputQuickControlsController(outputs: fixture.outputs, workspaceID: fixture.home.outputSourceID,
            manageOutputs: {}, makeBackgroundPanel: { panel }, createBackgroundBookmark: { _ in nil },
            beginBackgroundSheet: { _, _, completion in completeQuick = completion })
        _ = fixture.hostButton(controls.backgroundButton)
        let original = fixture.store.document
        let failed = expectation(description: "Quick picker reports failed bookmark")
        let observation = fixture.home.$projectionDisplayIssue.compactMap { $0 }
            .filter { $0.contains("Choose Visual again") }.first().sink { _ in failed.fulfill() }
        try invoke(menuItem("Choose Visual…", in: controls.backgroundButton.menu))
        try XCTUnwrap(completeQuick)(.OK)
        await fulfillment(of: [failed], timeout: 3)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(fixture.store.document, original)
        XCTAssertNil(fixture.peer.projectionDisplayIssue)

        var completeProfile: ((NSApplication.ModalResponse) -> Void)?
        let editor = OutputProfileEditor(store: fixture.store, profileID: fixture.sharedProfileID,
            createBackgroundBookmark: { _ in nil }, makeBackgroundPanel: { panel },
            beginBackgroundSheet: { _, _, completion in completeProfile = completion })
        _ = fixture.host(editor)
        let profileFailed = expectation(description: "Profile picker reports failed bookmark")
        let labelObservation = editor.validationLabel.publisher(for: \.stringValue)
            .filter { $0.contains("Choose Visual again") }.first().sink { _ in profileFailed.fulfill() }
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.compactMap { $0 as? NSButton } + view.subviews.flatMap { buttons(in: $0) }
        }
        try XCTUnwrap(buttons(in: editor.view).first { $0.title == "Choose Visual…" }).performClick(nil)
        try XCTUnwrap(completeProfile)(.OK)
        await fulfillment(of: [profileFailed], timeout: 3)
        withExtendedLifetime(labelObservation) {}
        XCTAssertEqual(fixture.store.document, original)
        XCTAssertFalse(editor.validationLabel.isHidden)
        XCTAssertFalse(fixture.outputs.isRunning)
    }

    func testPlayMenuRequiresThisWorkspacesSelectedTrackWhileCurrentMayBeEmpty() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let play = try fixture.slideCommand("Pause/Play Background Audio")
        XCTAssertTrue(fixture.home.isEmpty)
        XCTAssertFalse(fixture.menus.validateMenuItem(play))

        fixture.home.setBackgroundAudio(url: fixture.audioURL, autoplay: false)
        XCTAssertTrue(fixture.menus.validateMenuItem(play), "A selected track does not require Current slides.")
        fixture.outputs.focusWorkspace(fixture.peer)
        XCTAssertFalse(fixture.menus.validateMenuItem(play), "Another workspace's selected track cannot enable this command.")
        XCTAssertTrue(fixture.outputs.preparedSession(workspace: fixture.peer.outputSourceID) === fixture.peer)
        XCTAssertFalse(fixture.outputs.isRunning)
    }

    func testRetainedQuickBackgroundActionReportsCapacityFailureThenRetriesWithoutTouchingSharers() throws {
        let fixture = try Fixture(profileCount: 127)
        defer { fixture.close() }
        let controls = OutputQuickControlsController(outputs: fixture.outputs,
            workspaceID: fixture.home.outputSourceID, manageOutputs: {})
        let clear = try menuItem("Clear Visual", in: controls.backgroundButton.menu)
        fixture.fillProfiles(to: 128)
        let before = fixture.store.document

        try invoke(clear)

        XCTAssertEqual(fixture.store.document, before)
        XCTAssertTrue(fixture.home.projectionDisplayIssue?.contains("profile limit") == true)
        XCTAssertNil(fixture.peer.projectionDisplayIssue)
        XCTAssertFalse(controls.backgroundButton.isEnabled)
        XCTAssertTrue(controls.backgroundButton.accessibilityHelp()?.contains("profile limit") == true)
        try fixture.removeUnusedAppearance()
        try invoke(clear)

        XCTAssertNil(fixture.home.projectionDisplayIssue)
        XCTAssertNil(fixture.outputs.profile(for: fixture.homeRows[0])?.background.bookmark)
        XCTAssertEqual(fixture.outputs.profile(for: fixture.peerRow)?.background.bookmark, "original visual")
        XCTAssertNotEqual(fixture.outputs.destination(fixture.homeRows[0])?.profileID, fixture.sharedProfileID)
        XCTAssertFalse(fixture.outputs.isRunning)
    }

    func testRetainedSettingsClearReportsCapacityAndCommitsNameBeforeSuccessfulRetry() throws {
        let fixture = try Fixture(profileCount: 127)
        defer { fixture.close() }
        let editor = OutputDestinationEditor(coordinator: fixture.outputs, destinationID: fixture.homeRows[0])
        let window = fixture.host(editor)
        let clearAction = try XCTUnwrap(editor.clearBackgroundButton.action)
        fixture.fillProfiles(to: 128)
        let appearances = fixture.store.document.profiles
        let assignments = fixture.store.document.destinations
        XCTAssertTrue(window.makeFirstResponder(editor.nameField))
        try XCTUnwrap(editor.nameField.currentEditor()).string = "Renamed front output"

        XCTAssertTrue(NSApp.sendAction(clearAction, to: editor.clearBackgroundButton.target, from: editor.clearBackgroundButton))

        XCTAssertEqual(fixture.outputs.destination(fixture.homeRows[0])?.name, "Renamed front output")
        XCTAssertEqual(fixture.store.document.profiles, appearances)
        XCTAssertEqual(fixture.store.document.destinations.map(\.profileID), assignments.map(\.profileID))
        XCTAssertFalse(editor.validationLabel.isHidden)
        XCTAssertTrue(editor.validationLabel.stringValue.contains("profile limit"))
        XCTAssertNil(window.attachedSheet, "Appearance failure stays inline.")
        try fixture.removeUnusedAppearance()
        XCTAssertTrue(NSApp.sendAction(clearAction, to: editor.clearBackgroundButton.target, from: editor.clearBackgroundButton))

        XCTAssertTrue(editor.validationLabel.isHidden)
        XCTAssertNil(fixture.outputs.profile(for: fixture.homeRows[0])?.background.bookmark)
        XCTAssertEqual(fixture.outputs.profile(for: fixture.peerRow)?.background.bookmark, "original visual")
        XCTAssertFalse(fixture.outputs.isRunning)
    }

    func testPendingQuickVisualPanelRechecksCapacityAtCompletion() async throws {
        let fixture = try Fixture(profileCount: 127)
        defer { fixture.close() }
        let panel = BackgroundOpenPanel()
        panel.selectedURL = fixture.visualURL
        var completion: ((NSApplication.ModalResponse) -> Void)?
        let controls = OutputQuickControlsController(outputs: fixture.outputs,
            workspaceID: fixture.home.outputSourceID, manageOutputs: {},
            makeBackgroundPanel: { panel }, beginBackgroundSheet: { presented, _, completed in
                XCTAssertTrue(presented === panel)
                completion = completed
            })
        let window = fixture.hostButton(controls.backgroundButton)
        XCTAssertTrue(controls.backgroundButton.window === window)
        try invoke(menuItem("Choose Visual…", in: controls.backgroundButton.menu))
        let complete = try XCTUnwrap(completion)
        fixture.fillProfiles(to: 128)
        let before = fixture.store.document
        let rejected = expectation(description: "Pending visual selection reports its capacity failure")
        let observation = fixture.home.$projectionDisplayIssue.compactMap { $0 }
            .filter { $0.contains("profile limit") }.first().sink { _ in rejected.fulfill() }

        complete(.OK)
        await fulfillment(of: [rejected], timeout: 3)
        withExtendedLifetime(observation) {}

        XCTAssertEqual(fixture.store.document, before)
        XCTAssertEqual(fixture.outputs.profile(for: fixture.homeRows[0])?.background.bookmark, "original visual")
        XCTAssertNil(fixture.peer.projectionDisplayIssue)
        XCTAssertFalse(fixture.outputs.isRunning)
    }

    func testMenuClearAllCapacityFailurePreservesProgramAndMusicThenProjectionRetrySucceeds() throws {
        let fixture = try Fixture(profileCount: 127, homeOutputCount: 2)
        defer { fixture.close() }
        fixture.home.setSlides(LyricsParser.parseDocument("Verse\nHome program").slides)
        fixture.peer.setSlides(LyricsParser.parseDocument("Verse\nPeer program").slides)
        fixture.home.showSlides()
        XCTAssertTrue(fixture.home.selectBackgroundAudio(fixture.audioURL))
        let player = try XCTUnwrap(fixture.home.programBackgroundAudioPlayer)
        let current = fixture.home.currentSlideID
        let peerCurrent = fixture.peer.currentSlideID
        let before = fixture.store.document
        let accepted = fixture.outputs.snapshot(for: fixture.homeRows[0])
        let clear = try fixture.slideCommand("Clear All Layers")

        try invoke(clear)

        XCTAssertEqual(fixture.store.document, before)
        XCTAssertEqual(fixture.home.currentSlideID, current)
        XCTAssertTrue(fixture.home.areSlidesVisible)
        XCTAssertEqual(fixture.outputs.snapshot(for: fixture.homeRows[0]).revision, accepted.revision)
        XCTAssertEqual(fixture.home.backgroundAudioPlaybackState, .playing)
        XCTAssertTrue(fixture.home.programBackgroundAudioPlayer === player)
        XCTAssertTrue(fixture.home.projectionDisplayIssue?.contains("profile limit") == true)
        XCTAssertNil(fixture.peer.projectionDisplayIssue)
        try fixture.removeUnusedAppearance()
        let projection = fixture.projectionWindow()
        fixture.outputs.focusWorkspace(fixture.peer)
        fixture.focus.window = projection
        try invoke(clear)

        XCTAssertEqual(fixture.home.currentSlideID, current)
        XCTAssertFalse(fixture.home.areSlidesVisible)
        XCTAssertNil(fixture.home.backgroundAudioURL)
        XCTAssertTrue(fixture.homeRows.allSatisfy { fixture.outputs.isOpen($0) })
        XCTAssertTrue(fixture.homeRows.allSatisfy { fixture.outputs.profile(for: $0)?.background.bookmark == nil })
        XCTAssertEqual(fixture.peer.currentSlideID, peerCurrent)
        XCTAssertEqual(fixture.outputs.profile(for: fixture.peerRow)?.background.bookmark, "original visual")
        XCTAssertNil(fixture.home.projectionDisplayIssue)
    }

    func testClearMenuActionsForgetAudioFromControlsAndProjectionAcrossControlsReopen() throws {
        for title in ["Clear Background Audio", "Clear All Layers"] {
            for fromProjection in [false, true] {
                let fixture = try Fixture()
                defer { fixture.close() }
                XCTAssertTrue(fixture.home.selectBackgroundAudio(fixture.audioURL))
                fixture.peer.setBackgroundAudio(url: fixture.audioURL, autoplay: false)
                let peerBookmark = try XCTUnwrap(SecurityScopedBookmarks.createBookmark(for: fixture.audioURL))
                fixture.store.backgroundPreferences.settings(for: fixture.peer.outputSourceID).setAudioBookmark(peerBookmark)
                let controls = try XCTUnwrap(fixture.app.workspaceWindows.open(fixture.home.outputSourceID))
                let window = try XCTUnwrap(controls.window)
                fixture.focus.window = window
                let field = NSTextField(frame: .init(x: 20, y: 20, width: 200, height: 24))
                field.stringValue = "Unsaved operator text"
                window.contentView?.addSubview(field)
                XCTAssertTrue(window.makeFirstResponder(field))
                let text = try XCTUnwrap(field.currentEditor() as? NSTextView)
                text.setSelectedRange(.init(location: 3, length: 0))
                let peerCurrent = fixture.peer.currentSlideID
                let clear = try fixture.slideCommand(title)
                XCTAssertTrue(clear.keyEquivalent.isEmpty, "Layer clearing is an explicit menu action.")
                if fromProjection {
                    let projection = fixture.projectionWindow()
                    fixture.outputs.focusWorkspace(fixture.peer)
                    fixture.focus.window = projection
                }
                XCTAssertTrue(fixture.menus.validateMenuItem(clear))
                try invoke(clear)
                XCTAssertTrue(window.firstResponder === text)
                XCTAssertEqual(text.selectedRange(), .init(location: 3, length: 0))
                XCTAssertEqual(field.stringValue, "Unsaved operator text")
                XCTAssertNil(fixture.home.backgroundAudioURL)
                XCTAssertEqual(fixture.store.backgroundPreferences.settings(for: fixture.home.outputSourceID).values.audioBookmark, "")
                XCTAssertEqual(fixture.store.backgroundPreferences.settings(for: fixture.peer.outputSourceID).values.audioBookmark, peerBookmark)
                XCTAssertEqual(fixture.peer.backgroundAudioURL, fixture.audioURL)
                XCTAssertEqual(fixture.peer.currentSlideID, peerCurrent)
                window.close()
                fixture.focus.window = nil
                XCTAssertNil(fixture.app.workspaceWindows.controllers[fixture.home.outputSourceID])
                let reopened = try XCTUnwrap(fixture.app.workspaceWindows.open(fixture.home.outputSourceID))
                XCTAssertTrue(reopened.session === fixture.home)
                XCTAssertNil(reopened.session.backgroundAudioURL)
                fixture.store.flush()
                let reloaded = OutputProfileStore(defaults: fixture.defaults)
                XCTAssertEqual(reloaded.backgroundPreferences.settings(for: fixture.home.outputSourceID).values.audioBookmark, "")
                reloaded.flush()
                fixture.home.playBackgroundAudio()
                XCTAssertNil(fixture.home.programBackgroundAudioPlayer)
                XCTAssertFalse(fixture.home.isBackgroundAudioPlaying)
            }
        }
    }

    private func menuItem(_ title: String, in menu: NSMenu?) throws -> NSMenuItem {
        try XCTUnwrap(menu?.items.first { $0.title == title })
    }
    private func invoke(_ item: NSMenuItem) throws {
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }
    @MainActor
    private final class Fixture {
        let suite = "WorkspaceBackgroundUI." + UUID().uuidString
        let defaults: UserDefaults
        let store: OutputProfileStore
        let outputs: OutputCoordinator
        let home: PresentationSession
        let peer: PresentationSession
        let sharedProfileID: UUID
        let homeRows: [UUID]
        let peerRow: UUID
        let audioURL: URL
        let visualURL: URL
        let focus: Focus
        let app: AppDelegate
        let menus: AppMenuController
        private var windows: [NSWindow] = []

        init(profileCount: Int = 4, homeOutputCount: Int = 1) throws {
            let focus = Focus()
            self.focus = focus
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            self.defaults = defaults
            let monitors = (1...homeOutputCount).map { number in
                ProjectionMonitor(id: UInt32(number), identity: UUID().uuidString, name: "Isolated output \(number)",
                    frame: .init(x: number * 640, y: 0, width: 640, height: 360))
            }
            let displays = ProjectionDisplayManager(displays: { monitors })
            let store = OutputProfileStore(defaults: defaults)
            self.store = store
            let peerID = try XCTUnwrap(store.addWorkspace(name: "Peer"))
            var shared = OutputProfile(id: UUID(), name: "Shared operator appearance", kind: .audience)
            shared.background.bookmark = "original visual"
            sharedProfileID = shared.id
            let rows = monitors.map { OutputDestinationConfiguration(name: $0.name, profileID: shared.id, monitor: $0.target) }
            homeRows = rows.map(\.id)
            let peerRow = OutputDestinationConfiguration(name: "Peer disabled output", profileID: shared.id,
                monitor: nil, enabled: false, workspaceID: peerID)
            self.peerRow = peerRow.id
            store.edit { document in
                document.profiles.append(shared)
                document.destinations = rows + [peerRow]
                document.defaultDestinationID = rows.first?.id
                while document.profiles.count < profileCount {
                    document.profiles.append(OutputProfile(id: UUID(), name: "Unused appearance \(document.profiles.count)", kind: .audience))
                }
            }
            let outputs = OutputCoordinator(profiles: store, displays: displays, retainsPreparedSessions: true,
                keyWindow: { focus.window }, driverFactory: { FakeOutputDriver() })
            self.outputs = outputs
            home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
            peer = outputs.session(workspace: peerID)
            audioURL = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-ui-audio-\(UUID()).caf")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 { buffer.floatChannelData?[channel].update(repeating: 0, count: Int(buffer.frameLength)) }
            try AVAudioFile(forWriting: audioURL, settings: format.settings).write(from: buffer)
            visualURL = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-ui-visual-\(UUID()).png")
            let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 4, bitsPerPixel: 32))
            image.setColor(.white, atX: 0, y: 0)
            try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: visualURL)
            let app = AppDelegate(settingsDefaults: defaults)
            app.outputProfiles = store; app.outputs = outputs
            app.workspaceWindows = makeWorkspaceWindows(outputs: outputs, defaults: defaults, keyWindow: { focus.window })
            self.app = app
            menus = AppMenuController(app: app)
            outputs.focusWorkspace(home)
        }

        func fillProfiles(to count: Int) {
            store.edit { document in
                while document.profiles.count < count {
                    document.profiles.append(OutputProfile(id: UUID(), name: "Unused appearance \(document.profiles.count)", kind: .audience))
                }
            }
        }
        func removeUnusedAppearance() throws {
            let unused = try XCTUnwrap(store.document.profiles.last { $0.name.hasPrefix("Unused appearance ") })
            XCTAssertTrue(store.removeProfile(unused.id))
        }
        func slideCommand(_ title: String) throws -> NSMenuItem {
            try XCTUnwrap(menus.mainMenu.item(withTitle: "Slides")?.submenu?.item(withTitle: title))
        }
        func host(_ editor: NSViewController) -> NSWindow {
            let window = makeWindow()
            window.contentViewController = editor
            window.layoutIfNeeded()
            return window
        }
        func hostButton(_ button: NSButton) -> NSWindow {
            let window = makeWindow()
            button.frame = .init(x: 20, y: 20, width: 160, height: 28)
            window.contentView?.addSubview(button)
            return window
        }
        func projectionWindow() -> PresentationWindow {
            let window = PresentationWindow(contentRect: .init(x: -10000, y: -10000, width: 160, height: 90),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.outputCoordinator = outputs; window.outputDestinationID = homeRows[0]
            windows.append(window)
            return window
        }
        private func makeWindow() -> NSWindow {
            let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 820, height: 650),
                styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            window.orderBack(nil)
            windows.append(window)
            return window
        }
        func close() {
            home.clearBackgroundAudio(); peer.clearBackgroundAudio()
            for window in Array(app.workspaceWindows.windows.values) + windows { window.close() }
            focus.window = nil
            outputs.stopAllOutputs(); store.flush()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: visualURL)
        }
    }
    @MainActor private final class Focus { var window: NSWindow? }
    @MainActor private final class BackgroundOpenPanel: NSOpenPanel {
        var selectedURL: URL?
        override var url: URL? { selectedURL }
    }
}
