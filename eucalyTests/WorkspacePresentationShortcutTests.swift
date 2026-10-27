import AppKit
import XCTest
@testable import eucaly

@MainActor
final class WorkspacePresentationShortcutTests: XCTestCase {
    func testNativeCommandReturnPreservesEditorsPreviewAndPeerProgram() async throws {
        let f = try Fixture(); defer { f.close() }
        try await activateNativeSearchTestWindow(f.window)
        let lyrics = LyricsTextView(frame: .init(x: 20, y: 20, width: 300, height: 100))
        lyrics.string = "Unsaved lyrics draft"
        let field = NSTextField(frame: .init(x: 20, y: 140, width: 300, height: 24))
        field.stringValue = "Uncommitted field text"
        let outline = NSOutlineView(frame: .init(x: 340, y: 20, width: 200, height: 100))
        for view in [lyrics, field, outline] { f.window.contentView?.addSubview(view) }
        let current = f.home.slides.map(\.id), preview = f.flow.previewSlides.map(\.id)
        let saved = f.profiles.document, peer = f.outputs.snapshot(for: f.peerRow)
        for view in [lyrics, field, outline] {
            XCTAssertTrue(f.window.makeFirstResponder(view))
            let responder = f.window.firstResponder
            (responder as? NSTextView)?.setSelectedRange(.init(location: 3, length: 2))
            let visible = f.home.areSlidesVisible
            NSApp.sendEvent(try f.key(in: f.window))
            XCTAssertEqual(f.home.areSlidesVisible, !visible)
            XCTAssertTrue(f.window.firstResponder === responder)
            XCTAssertEqual((responder as? NSTextView)?.selectedRange(), responder is NSTextView ? .init(location: 3, length: 2) : nil)
            NSApp.sendEvent(try f.key(in: f.window, repeatKey: true))
            XCTAssertEqual(f.home.areSlidesVisible, !visible, "Holding Return must not oscillate visibility")
        }
        XCTAssertEqual(lyrics.string, "Unsaved lyrics draft")
        XCTAssertEqual(field.stringValue, "Uncommitted field text")
        XCTAssertEqual(f.home.slides.map(\.id), current)
        XCTAssertEqual(f.flow.previewSlides.map(\.id), preview)
        XCTAssertEqual(f.profiles.document, saved)
        XCTAssertEqual(f.outputs.snapshot(for: f.peerRow).revision, peer.revision)
        XCTAssertTrue(f.outputs.isOpen(f.peerRow))

        NSApp.sendEvent(try f.key(in: f.window, modifiers: [.command, .shift]))
        XCTAssertFalse(f.outputs.isOpen(f.homeRow))
        XCTAssertTrue(f.outputs.isOpen(f.peerRow))
        XCTAssertEqual(f.home.slides.map(\.id), current)
        XCTAssertEqual(f.profiles.document, saved)
    }

    func testNativeSearchCommandReturnNeverActivatesPreviewIncludingEmptyCurrent() async throws {
        let f = try Fixture(); defer { f.close() }
        try await activateNativeSearchTestWindow(f.window)
        let palette = try await f.presentSearch()
        let editor = try XCTUnwrap(palette.searchField.currentEditor() as? NSTextView)
        editor.setSelectedRange(.init(location: 1, length: 2))
        let current = f.home.slides.map(\.id), preview = f.flow.previewSlides.map(\.id)
        let selection = f.search.selectedEntry
        let table = palette.resultsController.table
        table.layoutSubtreeIfNeeded()
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
        func buttons(in view: NSView) -> [NSButton] {
            view.subviews.compactMap { $0 as? NSButton } + view.subviews.flatMap { buttons(in: $0) }
        }
        let add = try XCTUnwrap(buttons(in: cell).first)
        let searchResponders: [NSView] = [palette.searchField, table, add]
        for view in searchResponders {
            XCTAssertTrue(f.window.makeFirstResponder(view))
            let responder = f.window.firstResponder
            let caret = (responder as? NSTextView)?.selectedRange()
            let visible = f.home.areSlidesVisible
            NSApp.sendEvent(try f.key(in: f.window))
            XCTAssertEqual(f.home.areSlidesVisible, !visible)
            XCTAssertTrue(f.window.firstResponder === responder)
            XCTAssertEqual((responder as? NSTextView)?.selectedRange(), caret)
            XCTAssertEqual(f.search.query, "song")
            XCTAssertEqual(f.search.selectedEntry, selection)
            XCTAssertTrue(f.presenter.isPresented)
            XCTAssertTrue(f.opened.isEmpty)
            XCTAssertEqual(f.home.slides.map(\.id), current)
            XCTAssertEqual(f.flow.previewSlides.map(\.id), preview)
        }
        f.home.clearSlides()
        let clock = f.home.outputActionClock.current
        for view in searchResponders {
            XCTAssertTrue(f.window.makeFirstResponder(view))
            let responder = f.window.firstResponder
            let caret = (responder as? NSTextView)?.selectedRange()
            NSApp.sendEvent(try f.key(in: f.window))
            XCTAssertTrue(f.window.firstResponder === responder)
            XCTAssertEqual((responder as? NSTextView)?.selectedRange(), caret)
            XCTAssertTrue(f.home.isEmpty)
            XCTAssertEqual(f.home.outputActionClock.current, clock)
            XCTAssertNil(palette.primaryTask, "Disabled projection must not fall through into Search Preview")
            XCTAssertTrue(f.opened.isEmpty)
            XCTAssertTrue(f.presenter.isPresented)
        }
        XCTAssertEqual(f.search.query, "song")
        XCTAssertEqual(f.search.selectedEntry, selection)
        XCTAssertEqual(f.flow.previewSlides.map(\.id), preview)
        NSApp.sendEvent(try f.key(in: f.window, modifiers: [.command, .shift]))
        XCTAssertFalse(f.outputs.isOpen(f.homeRow))
        XCTAssertTrue(f.outputs.isOpen(f.peerRow))
        XCTAssertTrue(f.presenter.isPresented)
        // Ordinary Return still activates the selected Search result.
        XCTAssertTrue(f.window.makeFirstResponder(table))
        NSApp.sendEvent(try f.key(in: f.window, modifiers: []))
        await palette.primaryTask?.value
        XCTAssertEqual(f.opened, [f.url])
        XCTAssertTrue(f.home.isEmpty)
    }

    func testProjectionKeyWindowResolvesDestinationOwnerAndRejectsRemovedBindings() async throws {
        let f = try Fixture(); defer { f.close() }
        let projection = f.projection
        f.outputs.focusWorkspace(f.peer)
        try await activateNativeSearchTestWindow(projection)
        let peer = f.outputs.snapshot(for: f.peerRow)
        let visible = f.home.areSlidesVisible
        NSApp.sendEvent(try f.key(in: projection))
        XCTAssertEqual(f.home.areSlidesVisible, !visible)
        XCTAssertEqual(f.outputs.snapshot(for: f.peerRow).revision, peer.revision)
        let clock = f.home.outputActionClock.current
        let extraModifiers: [NSEvent.ModifierFlags] = [[.command, .option], [.command, .control], [.command, .shift, .option]]
        for modifiers in extraModifiers {
            let extra = try f.key(in: projection, modifiers: modifiers)
            XCTAssertFalse(f.menus.mainMenu.performKeyEquivalent(with: extra))
            _ = projection.performKeyEquivalent(with: extra)
            XCTAssertEqual(f.home.outputActionClock.current, clock)
        }
        for code: UInt16 in [18, 19, 20, 21, 23] {
            let old = try f.key(in: projection, code: code)
            XCTAssertFalse(f.menus.mainMenu.performKeyEquivalent(with: old))
            // No hidden compatibility path may remain in projection keyDown.
            projection.keyDown(with: old)
            XCTAssertEqual(f.home.outputActionClock.current, clock)
            XCTAssertTrue(f.outputs.isOpen(f.homeRow))
        }
        let keypad = try f.key(in: projection, modifiers: [.command, .numericPad, .function, .capsLock], code: 76)
        XCTAssertTrue(projection.performKeyEquivalent(with: keypad))
        XCTAssertEqual(f.home.areSlidesVisible, visible)
        NSApp.sendEvent(try f.key(in: projection, modifiers: [.command, .shift]))
        XCTAssertFalse(f.outputs.isOpen(f.homeRow))
        XCTAssertTrue(f.outputs.isOpen(f.peerRow))
        f.profiles.edit { $0.destinations.removeAll { $0.id == f.homeRow } }
        let peerClock = f.peer.outputActionClock.current
        XCTAssertTrue(projection.performKeyEquivalent(with: try f.key(in: projection)))
        XCTAssertTrue(projection.performKeyEquivalent(with: try f.key(in: projection, modifiers: [.command, .shift])))
        XCTAssertEqual(f.peer.outputActionClock.current, peerClock, "A stale projection must never inherit focused workspace ownership")
        XCTAssertTrue(f.outputs.isOpen(f.peerRow))
        projection.outputDestinationID = nil
        XCTAssertFalse(f.menus.validateMenuItem(try f.slidesItem("Show/Hide Slides")))
        XCTAssertFalse(f.menus.validateMenuItem(try f.slidesItem("Stop Workspace Outputs")))
    }

    func testNativeCleanupSheetOwnsCommandReturnAndUnrelatedPanelsCannotProject() async throws {
        let f = try Fixture(); defer { f.close() }
        try await activateNativeSearchTestWindow(f.window)
        var applied: [String] = []
        let cleanup = LyricsCleanupController(generate: { source, _ in
            .init(original: source, proposed: "Reviewed lyrics", changes: [], notes: [])
        })
        XCTAssertTrue(cleanup.present(source: "Original draft", documentID: UUID(), for: f.window,
            isCurrent: { true }, apply: { applied.append($0); return true }))
        defer { cleanup.cancel() }
        await cleanup.pendingTask?.value
        let sheet = try XCTUnwrap(f.window.attachedSheet)
        let review = try XCTUnwrap(cleanup.reviewViewController)
        try await activateNativeSearchTestWindow(sheet)
        XCTAssertTrue(sheet.makeFirstResponder(review.proposedTextView))
        let clock = f.home.outputActionClock.current, peerClock = f.peer.outputActionClock.current
        XCTAssertFalse(f.menus.validateMenuItem(try f.slidesItem("Show/Hide Slides")))
        XCTAssertFalse(f.menus.validateMenuItem(try f.slidesItem("Stop Workspace Outputs")))
        XCTAssertFalse(f.window.performKeyEquivalent(with: try f.key(in: f.window)))
        let proposal = review.proposedTextView.string
        NSApp.sendEvent(try f.key(in: sheet, modifiers: [.command, .shift]))
        XCTAssertTrue(cleanup.isPresented)
        XCTAssertTrue(applied.isEmpty, "Shift-Command-Return must not match the sheet's Command-Return Apply")
        XCTAssertTrue(sheet.firstResponder === review.proposedTextView)
        XCTAssertEqual(review.proposedTextView.string, proposal)
        XCTAssertEqual(f.home.outputActionClock.current, clock)
        XCTAssertTrue(f.outputs.isOpen(f.homeRow)); XCTAssertTrue(f.outputs.isOpen(f.peerRow))
        review.applyButton.isEnabled = false
        NSApp.sendEvent(try f.key(in: sheet))
        XCTAssertTrue(applied.isEmpty)
        XCTAssertEqual(f.home.outputActionClock.current, clock)
        review.applyButton.isEnabled = true
        let sheetEnded = expectation(forNotification: NSWindow.didEndSheetNotification, object: f.window)
        NSApp.sendEvent(try f.key(in: sheet))
        XCTAssertEqual(applied, ["Reviewed lyrics"])
        XCTAssertFalse(cleanup.isPresented)
        XCTAssertEqual(f.home.outputActionClock.current, clock)
        XCTAssertEqual(f.peer.outputActionClock.current, peerClock)
        await fulfillment(of: [sheetEnded], timeout: 4)

        let panel = NSPanel(contentRect: .init(x: 50, y: 50, width: 300, height: 200),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        try await activateNativeSearchTestWindow(panel)
        XCTAssertFalse(f.menus.validateMenuItem(try f.slidesItem("Show/Hide Slides")))
        XCTAssertFalse(f.menus.validateMenuItem(try f.slidesItem("Stop Workspace Outputs")))
        NSApp.sendEvent(try f.key(in: panel))
        NSApp.sendEvent(try f.key(in: panel, modifiers: [.command, .shift]))
        XCTAssertEqual(f.home.outputActionClock.current, clock)
        XCTAssertEqual(f.peer.outputActionClock.current, peerClock)
        XCTAssertTrue(f.outputs.isOpen(f.homeRow)); XCTAssertTrue(f.outputs.isOpen(f.peerRow))
    }

    func testNativeSettingsFilePanelRetainsNewFolderShortcut() async throws {
        let f = try Fixture(); defer { f.close() }
        let settings = NSWindow(contentRect: .init(x: 80, y: 80, width: 600, height: 400),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        settings.title = "Settings fixture"; settings.isReleasedWhenClosed = false
        defer { settings.close() }
        try await activateNativeSearchTestWindow(settings)
        let panel = NSOpenPanel()
        panel.directoryURL = f.directory; panel.canCreateDirectories = true
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.beginSheetModal(for: settings) { _ in }
        defer { panel.cancel(nil) }
        try await activateNativeSearchTestWindow(panel)
        let saved = f.profiles.document
        let newWorkspace = try XCTUnwrap(f.menus.mainMenu.item(withTitle: "File")?.submenu?.item(withTitle: "New Workspace"))
        XCTAssertFalse(f.app.workspaceWindows.canCreateWorkspace)
        XCTAssertFalse(f.menus.validateMenuItem(newWorkspace))
        let newFolder = try f.nativeMenuKey(modifiers: [.command, .shift], code: 45)
        XCTAssertFalse(f.menus.mainMenu.performKeyEquivalent(with: newFolder))
        NSApp.sendEvent(newFolder)
        XCTAssertEqual(f.profiles.document, saved)
        XCTAssertNil(f.app.workspaceWindows.newWorkspace(), "A file panel must retain its native New Folder command")
        XCTAssertTrue(f.outputs.isOpen(f.homeRow)); XCTAssertTrue(f.outputs.isOpen(f.peerRow))
    }

    func testCommandReturnPreservesNativeMarkedTextComposition() async throws {
        let f = try Fixture(); defer { f.close() }
        try await activateNativeSearchTestWindow(f.window)
        let editor = LyricsTextView(frame: .init(x: 20, y: 20, width: 300, height: 100))
        editor.string = "Unsaved lyrics draft"
        f.window.contentView?.addSubview(editor)
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        editor.setMarkedText("കൃപ", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: 3, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        let draft = editor.string, marked = editor.markedRange(), selection = editor.selectedRange()
        let visible = f.home.areSlidesVisible
        NSApp.sendEvent(try f.key(in: f.window))
        XCTAssertEqual(f.home.areSlidesVisible, !visible)
        XCTAssertEqual(editor.string, draft)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.selectedRange(), selection)
        XCTAssertTrue(editor.hasMarkedText())
    }

    func testNativeFontsAndNewWorkspaceShortcutsPreserveParkedDraftAndLivePrograms() async throws {
        let f = try Fixture(); defer { f.close() }
        let controls = try XCTUnwrap(f.app.workspaceWindows.open(f.home.outputSourceID))
        let parked = controls.controls
        let window = try XCTUnwrap(controls.window)
        try await activateNativeSearchTestWindow(window)
        let editor = LyricsTextView(frame: .init(x: 20, y: 20, width: 300, height: 100))
        editor.string = "Unsaved parked lyrics"
        window.contentView?.addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        let home = f.home.slides.map(\.id), peer = f.peer.slides.map(\.id)
        NSApp.sendEvent(try f.key(in: window, code: 17))
        let fonts = try XCTUnwrap(NSFontManager.shared.fontPanel(false))
        defer { fonts.close() }
        XCTAssertTrue(fonts.isVisible)
        try await activateNativeSearchTestWindow(fonts)
        let clock = f.home.outputActionClock.current
        XCTAssertFalse(f.menus.validateMenuItem(try f.slidesItem("Show/Hide Slides")))
        NSApp.sendEvent(try f.key(in: fonts))
        XCTAssertEqual(f.home.outputActionClock.current, clock)
        fonts.close()
        try await activateNativeSearchTestWindow(window)
        XCTAssertTrue(NSApp.mainMenu === f.menus.mainMenu)
        XCTAssertEqual(f.app.workspaceWindows.activeWorkspaceID, f.home.outputSourceID)
        let newWorkspace = try XCTUnwrap(f.menus.mainMenu.item(withTitle: "File")?.submenu?.item(withTitle: "New Workspace"))
        XCTAssertTrue(f.menus.validateMenuItem(newWorkspace))
        let count = f.profiles.document.workspaces.count
        let createKey = try f.nativeMenuKey(modifiers: [.command, .shift], code: 45)
        XCTAssertTrue(f.menus.mainMenu.performKeyEquivalent(with: createKey))
        XCTAssertEqual(f.profiles.document.workspaces.count, count + 1)
        let created = try XCTUnwrap(f.profiles.document.workspaces.last?.id)
        XCTAssertTrue(f.outputs.destinations(workspace: created).isEmpty)
        XCTAssertNil(parked.window, "New Workspace parks the retained controls in the same physical window")
        XCTAssertTrue(f.app.workspaceWindows.windows[created] === window)
        XCTAssertEqual(editor.string, "Unsaved parked lyrics")
        XCTAssertEqual(f.home.slides.map(\.id), home)
        XCTAssertEqual(f.peer.slides.map(\.id), peer)
        XCTAssertTrue(f.outputs.isOpen(f.homeRow)); XCTAssertTrue(f.outputs.isOpen(f.peerRow))
    }

    @MainActor
    private final class Fixture {
        let directory: URL, url: URL
        let profiles: OutputProfileStore, outputs: OutputCoordinator
        let home: PresentationSession, peer: PresentationSession
        let homeRow: UUID, peerRow: UUID
        var flow: PresentationFlowController { outputs.program(home.outputSourceID).flow }
        let app: AppDelegate, menus: AppMenuController
        let window: OutputWorkspaceWindow
        let projection: PresentationWindow
        let presenter = LibrarySearchPalettePresenter()
        let search: LibrarySearchModel
        var opened: [URL] = []
        private let previousMenu: NSMenu?

        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("PresentationShortcuts." + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("song.txt")
            try Data("Verse\nPrivate result".utf8).write(to: url)
            let resultURL = url
            search = LibrarySearchModel(index: .init(databaseURL: directory.appendingPathComponent("index.sqlite")),
                debounce: { throw CancellationError() },
                search: { _, _ in [.init(url: resultURL, snippet: "Private result", title: "Song")] })
            let monitors = (1...2).map { ProjectionMonitor(id: UInt32($0), identity: UUID().uuidString,
                name: "Monitor \($0)", frame: .init(x: 0, y: 0, width: 1920, height: 1080)) }
            let displays = ProjectionDisplayManager(displays: { monitors })
            profiles = OutputProfileStore(monitor: monitors[0].target)
            homeRow = profiles.document.destinations[0].id
            let peerID = try XCTUnwrap(profiles.addWorkspace(name: "Online"))
            let destination = OutputDestinationConfiguration(name: "Online", profileID: OutputProfile.audienceID,
                monitor: monitors[1].target, workspaceID: peerID)
            profiles.edit { $0.destinations.append(destination) }; peerRow = destination.id
            outputs = OutputCoordinator(profiles: profiles, displays: displays, retainsPreparedSessions: true,
                driverFactory: { FakeOutputDriver() })
            home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
            peer = outputs.session(workspace: peerID)
            home.setSlides(LyricsParser.parseDocument("Verse\nHouse Current").slides); home.showSlides()
            peer.setSlides(LyricsParser.parseDocument("Verse\nOnline Current").slides); peer.showSlides()
            window = OutputWorkspaceWindow(contentRect: .init(x: 100, y: 100, width: 1060, height: 660),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.workspaceSession = home
            let content = NSViewController()
            content.view = NSView(frame: .init(origin: .zero, size: window.contentLayoutRect.size))
            window.contentViewController = content
            projection = PresentationWindow(contentRect: .init(x: 100, y: 100, width: 320, height: 200),
                styleMask: .borderless, backing: .buffered, defer: false)
            projection.isReleasedWhenClosed = false
            projection.outputCoordinator = outputs; projection.outputDestinationID = homeRow
            app = AppDelegate(); app.outputProfiles = profiles; app.outputs = outputs
            app.workspaceWindows = makeWorkspaceWindows(outputs: outputs)
            menus = AppMenuController(app: app)
            previousMenu = NSApp.mainMenu; NSApp.mainMenu = menus.mainMenu
            flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPrivate Preview").slides)
        }

        func presentSearch() async throws -> LibrarySearchPaletteController {
            search.setScopeFiles([url]); search.setQuery("song", currentSelectedURL: nil)
            _ = await search.searchImmediately(currentSelectedURL: nil)
            XCTAssertTrue(presenter.present(in: window, model: search, currentSelectedURL: { nil },
                onRunAction: { _ in XCTFail("Projection must not execute Search actions") },
                onOpenResult: { [weak self] in self?.opened.append($0) }, onAddResultToPlaylist: { _ in .added }))
            let palette = try XCTUnwrap(presenter.activeController)
            let ready = XCTestExpectation(description: "Query focus installed")
            DispatchQueue.main.async { ready.fulfill() }
            await XCTWaiter().fulfillment(of: [ready], timeout: 4)
            XCTAssertNotNil(palette.searchField.currentEditor())
            return palette
        }

        func key(in window: NSWindow, modifiers: NSEvent.ModifierFlags = .command,
                 code: UInt16 = 36, repeatKey: Bool = false) throws -> NSEvent {
            let translated = try nativeMenuKey(modifiers: modifiers, code: code)
            return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                characters: try XCTUnwrap(translated.characters), charactersIgnoringModifiers: try XCTUnwrap(translated.charactersIgnoringModifiers),
                isARepeat: repeatKey, keyCode: code))
        }
        func nativeMenuKey(modifiers: NSEvent.ModifierFlags = .command, code: UInt16 = 36) throws -> NSEvent {
            // Keep the native event backing for menu lookup. Rebuilding an
            // NSEvent with identical visible characters/modifiers loses the
            // shifted-letter matching behavior used by NSMenu on macOS 26.
            let physical = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
            physical.flags = .init(rawValue: UInt64(modifiers.rawValue))
            return try XCTUnwrap(NSEvent(cgEvent: physical))
        }
        func slidesItem(_ title: String) throws -> NSMenuItem {
            try XCTUnwrap(menus.mainMenu.item(withTitle: "Slides")?.submenu?.item(withTitle: title))
        }
        func close() {
            presenter.dismiss(); search.cancelDebounce()
            for window in app.workspaceWindows.windows.values { window.close() }
            outputs.stopAllOutputs(); window.close(); projection.close()
            NSApp.mainMenu = previousMenu
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
