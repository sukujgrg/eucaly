import AppKit
import SwiftUI
import XCTest
@testable import eucaly

/// Opt-in desktop observation, with real application event delivery supplied by
/// the operator/CUA. This fixture never synthesizes key events or matches menus.
@MainActor
final class WorkspaceShortcutDesktopObservationTests: XCTestCase {
    func testDesktopShortcutObservation() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["EUCALY_SHORTCUT_DESKTOP"], path.hasPrefix("/") else {
            throw XCTSkip("Set TEST_RUNNER_EUCALY_SHORTCUT_DESKTOP to an empty observation directory.")
        }
        // AppKit panels can persist native geometry into the host's standard
        // defaults even when every app-managed store is injected.
        guard Bundle.main.bundleIdentifier == "com.suku.eucaly.ShortcutDesktop" else {
            XCTFail("Desktop observation requires PRODUCT_BUNDLE_IDENTIFIER=com.suku.eucaly.ShortcutDesktop.")
            return
        }
        executionTimeAllowance = 2_760
        let fixture = try DesktopShortcutFixture(directory: URL(fileURLWithPath: path, isDirectory: true))
        defer { fixture.close() }
        try await fixture.start()
        let deadline = Date().addingTimeInterval(45 * 60)
        while !fixture.finished, Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
            try await fixture.poll()
        }
        XCTAssertTrue(fixture.finished, "Desktop observation reached its 45-minute hard deadline.")
    }
}

@MainActor
private final class DesktopShortcutFixture: NSObject {
    let directory: URL
    let root: URL
    let suite = "DesktopShortcuts." + UUID().uuidString
    let defaults: UserDefaults
    let profiles: OutputProfileStore
    let outputs: OutputCoordinator
    let home: PresentationSession
    let peer: PresentationSession
    let homeRow: UUID
    let peerRow: UUID
    let index: LibraryTextSearchIndex
    let inventory: LibraryInventoryStore
    let playlist = PlaylistStore()
    let search: LibrarySearchModel
    let app: AppDelegate
    let menus: AppMenuController
    let windows: OutputWorkspaceWindows
    let projection: PresentationWindow
    let panel: NSPanel
    let cleanup = LyricsCleanupController(generate: { source, _ in
        .init(original: source, proposed: "Verse\nReviewed disposable lyrics", changes: [], notes: [])
    })
    private let saved: OutputProfileDocument
    private let current: [Slide]
    private let previousMenu: NSMenu?
    private var monitor: Any?
    private var trace: [[String: Any]] = []
    private var sequence = 0
    private var lastAction = "starting"
    private var lastError = ""
    private var cleanupApplications = 0
    private(set) var finished = false

    var controller: OutputWorkspaceWindowController? {
        windows.controllers[home.outputSourceID]?.host
    }
    var window: NSWindow? { controller?.window }
    var palette: LibrarySearchPaletteController? { controller?.commands.librarySearchPresenter.activeController }
    var flow: PresentationFlowController { outputs.program(home.outputSourceID).flow }
    var editor: LyricsTextView? {
        func find(_ view: NSView) -> LyricsTextView? {
            if let editor = view as? LyricsTextView { return editor }
            return view.subviews.lazy.compactMap(find).first
        }
        return window?.contentView.flatMap(find)
    }

    init(directory: URL) throws {
        self.directory = directory
        // Refuse reuse so a stale finish file cannot end a new run.
        guard !FileManager.default.fileExists(atPath: directory.path) else {
            throw DesktopFixtureError.directoryExists
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        root = directory.appendingPathComponent("Library", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try "#title: Disposable Grace\nVerse\nAmazing grace in this disposable song".write(
            to: root.appendingPathComponent("grace.txt"), atomically: true, encoding: .utf8)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(root.path, forKey: "libraryRootPath")
        index = LibraryTextSearchIndex(databaseURL: root.appendingPathComponent("index.sqlite"))
        inventory = LibraryInventoryStore(index: index)
        search = LibrarySearchModel(index: index)
        let monitors = (1...2).map { ProjectionMonitor(id: UInt32($0), identity: UUID().uuidString,
            name: "Disposable Monitor \($0)", frame: .init(x: 0, y: 0, width: 1920, height: 1080)) }
        profiles = OutputProfileStore(monitor: monitors[0].target)
        homeRow = try XCTUnwrap(profiles.document.destinations.first?.id)
        _ = profiles.renameWorkspace(OutputWorkspaceRecord.primaryID, name: "Shortcut Home")
        let peerID = try XCTUnwrap(profiles.addWorkspace(name: "Shortcut Peer"))
        let destination = OutputDestinationConfiguration(name: "Disposable Peer", profileID: OutputProfile.audienceID,
            monitor: monitors[1].target, workspaceID: peerID)
        profiles.edit { $0.destinations.append(destination) }
        peerRow = destination.id
        outputs = OutputCoordinator(profiles: profiles, displays: ProjectionDisplayManager(displays: { monitors }),
            retainsPreparedSessions: true, driverFactory: { FakeOutputDriver() })
        home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        peer = outputs.session(workspace: peerID)
        current = LyricsParser.parseDocument("Verse\nDisposable House Current").slides
        home.setSlides(current); home.showSlides()
        peer.setSlides(LyricsParser.parseDocument("Verse\nDisposable Peer Current").slides); peer.showSlides()
        saved = profiles.document
        app = AppDelegate(settingsDefaults: defaults)
        app.outputProfiles = profiles; app.outputs = outputs
        let updates = AppUpdateViewModel(driver: WorkspaceUpdateDriver())
        let fixtureDefaults = defaults, fixtureInventory = inventory, fixturePlaylist = playlist, fixtureSearch = search
        let fixtureIndex = index, homeID = home.outputSourceID
        windows = OutputWorkspaceWindows(outputs: outputs, updates: updates, defaults: fixtureDefaults,
            autosavesWindowFrames: false, contentFactory: { session, commands in
                let menu = OutputWorkspaceMenuController(workspaces: commands.workspaceWindows!, workspaceID: session.outputSourceID)
                let workspaceSearch = session.outputSourceID == homeID ? fixtureSearch : LibrarySearchModel(index: fixtureIndex)
                return OutputWorkspaceWindowController.hostingController(rootView:
                    ContentView(session: session, commands: commands, workspaceMenu: menu,
                        librarySearch: workspaceSearch, playlistStore: fixturePlaylist, libraryInventory: fixtureInventory,
                        controlPreferences: fixtureDefaults).environmentObject(updates).defaultAppStorage(fixtureDefaults))
            })
        app.workspaceWindows = windows
        menus = AppMenuController(app: app)
        previousMenu = NSApp.mainMenu
        projection = PresentationWindow(contentRect: .init(x: 40, y: 60, width: 420, height: 220),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        projection.isReleasedWhenClosed = false; projection.isRestorable = false
        projection.title = "Disposable Projection — Shortcut Home"
        projection.outputCoordinator = outputs; projection.outputDestinationID = homeRow
        projection.contentView = NSTextField(labelWithString: "Disposable projection command surface\nNo physical or network output is started.")
        panel = NSPanel(contentRect: .init(x: 30, y: 60, width: 320, height: 520),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "Shortcut Fixture Controls"; panel.isReleasedWhenClosed = false
        panel.isRestorable = false; panel.hidesOnDeactivate = false
        super.init()
        let actions = ["Search", "Focus Results", "Focus Add", "Editor", "Marked Text", "Clear Current",
                       "Restore Current", "Show Home", "Peer Focus Then Projection", "Cleanup", "Disable Apply",
                       "Enable Apply", "Cancel Cleanup", "Fullscreen", "Focus Home", "Finish"]
        let buttons = actions.map { title in
            let button = NSButton(title: title, target: self, action: #selector(controlAction(_:)))
            button.bezelStyle = .rounded
            return button
        }
        let stack = NSStackView(views: buttons)
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 6
        stack.edgeInsets = .init(top: 12, left: 12, bottom: 12, right: 12)
        panel.contentView = stack
        let controlsItem = NSMenuItem(title: panel.title, action: #selector(showControls(_:)), keyEquivalent: "")
        controlsItem.target = self
        menus.mainMenu.item(withTitle: "Window")?.submenu?.addItem(controlsItem)
    }

    func start() async throws {
        NSApp.mainMenu = menus.mainMenu
        _ = try XCTUnwrap(windows.open(home.outputSourceID))
        try await activateNativeSearchTestWindow(try XCTUnwrap(window))
        await inventory.waitForRefresh(root: root)
        flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPrivate disposable Preview").slides)
        try await prepare("Search")
        panel.orderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return event
        }
        try write(["pid": ProcessInfo.processInfo.processIdentifier,
                   "bundleURL": Bundle.main.bundleURL.path, "library": root.path,
                   "controlsWindow": window?.windowNumber ?? -1,
                   "scope": "Real ContentView/search/editor/event delivery; fake native outputs; no physical output."], name: "ready.json")
        try snapshot()
    }

    @objc private func controlAction(_ sender: NSButton) {
        Task { @MainActor in
            do { try await prepare(sender.title) }
            catch { lastError = String(reflecting: error); try? snapshot() }
        }
    }

    @objc private func showControls(_ sender: Any?) { panel.makeKeyAndOrderFront(nil) }

    func poll() async throws {
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("finish").path) { finished = true }
        try snapshot()
    }

    private func focusHome() throws {
        let window = try XCTUnwrap(window)
        window.makeKeyAndOrderFront(nil)
    }

    private func prepare(_ action: String) async throws {
        lastAction = action; lastError = ""
        switch action {
        case "Search":
            try focusHome()
            search.setQuery("grace", currentSelectedURL: nil)
            _ = await search.searchImmediately(currentSelectedURL: nil)
            NotificationCenter.default.post(name: .showLibrarySearch, object: nil)
        case "Focus Results":
            try focusHome(); _ = window?.makeFirstResponder(try XCTUnwrap(palette).resultsController.table)
        case "Focus Add":
            try focusHome(); _ = try XCTUnwrap(palette).commandRouter.focusPlaylistAccessory()
        case "Editor":
            controller?.commands.librarySearchPresenter.dismiss()
            try focusHome()
            // New Lyrics goes through the actual production menu action, once.
            // Later calls only refocus the existing draft, avoiding discard UI.
            if editor == nil {
                let menu = try XCTUnwrap(menus.mainMenu.item(withTitle: "File")?.submenu)
                let item = try XCTUnwrap(menu.item(withTitle: "New Lyrics"))
                _ = NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
                let deadline = Date().addingTimeInterval(5)
                while editor == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
            }
            let editor = try XCTUnwrap(editor)
            _ = window?.makeFirstResponder(editor)
            if editor.string.isEmpty { editor.insertText("Verse\nUnsaved disposable lyrics draft", replacementRange: .init(location: NSNotFound, length: 0)) }
            editor.setSelectedRange(.init(location: 8, length: 5))
        case "Marked Text":
            try await prepare("Editor")
            try XCTUnwrap(editor).setMarkedText("കൃപ", selectedRange: .init(location: 1, length: 0), replacementRange: .init(location: 8, length: 5))
        case "Clear Current": home.clearSlides(); try focusHome()
        case "Restore Current": home.setSlides(current); try focusHome()
        case "Show Home": home.showSlides(); try focusHome()
        case "Peer Focus Then Projection":
            outputs.focusWorkspace(peer)
            projection.makeKeyAndOrderFront(nil)
        case "Cleanup":
            controller?.commands.librarySearchPresenter.dismiss(); try focusHome()
            let source = editor?.string ?? "Verse\nDisposable cleanup source"
            _ = cleanup.present(source: source, documentID: UUID(), for: try XCTUnwrap(window),
                isCurrent: { true }, apply: { [weak self] _ in self?.cleanupApplications += 1; return true })
            await cleanup.pendingTask?.value
        case "Disable Apply": cleanup.reviewViewController?.applyButton.isEnabled = false
        case "Enable Apply": cleanup.reviewViewController?.applyButton.isEnabled = true
        case "Cancel Cleanup": cleanup.cancel()
        case "Fullscreen": try focusHome(); window?.toggleFullScreen(nil)
        case "Focus Home": try focusHome()
        case "Finish": finished = true
        default: throw DesktopFixtureError.unknownAction(action)
        }
        try snapshot()
    }

    private func record(_ event: NSEvent) {
        sequence += 1
        let id = sequence
        trace.append(["sequence": id, "timestamp": Date().timeIntervalSince1970,
                      "keyCode": event.keyCode, "characters": event.characters ?? "",
                      "modifiers": event.modifierFlags.rawValue, "repeat": event.isARepeat,
                      "eventWindow": event.windowNumber, "before": state()])
        if trace.count > 120 { trace.removeFirst() }
        DispatchQueue.main.async { [weak self] in
            guard let self, let index = self.trace.firstIndex(where: { $0["sequence"] as? Int == id }) else { return }
            self.trace[index]["after"] = self.state()
            try? self.snapshot()
        }
    }

    private func range(_ value: NSRange) -> [String: Int] {
        ["location": value.location == NSNotFound ? -1 : value.location, "length": value.length]
    }

    private func state() -> [String: Any] {
        let key = NSApp.keyWindow
        let responder = key?.firstResponder
        var value: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970, "appActive": NSApp.isActive,
            "keyWindow": key?.title ?? "", "keyWindowNumber": key?.windowNumber ?? -1,
            "responder": responder.map { String(reflecting: type(of: $0)) } ?? "nil",
            "query": search.query, "searchSelection": String(describing: search.selectedEntry),
            "searchPresented": controller?.commands.librarySearchPresenter.isPresented ?? false,
            "resultCount": search.filteredResults.count, "playlistCount": playlist.entries.count,
            "currentIDs": home.slides.map { $0.id.uuidString }, "currentText": home.slides.flatMap(\.lines).map(\.text),
            "previewIDs": flow.previewSlides.map { $0.id.uuidString }, "previewText": flow.previewSlides.flatMap(\.lines).map(\.text),
            "homeVisible": home.areSlidesVisible, "homeOpen": outputs.isOpen(homeRow),
            "homeRevision": outputs.snapshot(for: homeRow).revision,
            "peerVisible": peer.areSlidesVisible, "peerOpen": outputs.isOpen(peerRow),
            "peerCurrentIDs": peer.slides.map { $0.id.uuidString },
            "peerRevision": outputs.snapshot(for: peerRow).revision,
            "focusedWorkspace": outputs.focusedWorkspaceID?.uuidString ?? "nil",
            "profilesUnchanged": profiles.document == saved,
            "fullscreen": window?.styleMask.contains(.fullScreen) ?? false,
            "cleanupPresented": cleanup.isPresented, "cleanupApplied": cleanupApplications,
            "cleanupApplyEnabled": cleanup.reviewViewController?.applyButton.isEnabled ?? false,
            "lastAction": lastAction, "lastError": lastError, "finished": finished]
        if let editor {
            value["editorText"] = editor.string; value["editorSelection"] = range(editor.selectedRange())
            value["editorMarked"] = range(editor.markedRange()); value["editorHasMarkedText"] = editor.hasMarkedText()
            value["editorDirty"] = controller?.commands.canSaveLyrics ?? false
        }
        if let text = responder as? NSTextView {
            value["responderText"] = text.string; value["responderSelection"] = range(text.selectedRange())
            value["responderMarked"] = range(text.markedRange())
        }
        return value
    }

    private func snapshot() throws {
        var value = state(); value["eventTrace"] = trace
        try write(value, name: "state.json")
    }
    private func write(_ value: [String: Any], name: String) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(
            to: directory.appendingPathComponent(name), options: .atomic)
    }

    func close() {
        if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil
        cleanup.cancel(); search.cancelDebounce()
        for controls in windows.controllers.values { controls.commands.librarySearchPresenter.dismiss() }
        for window in windows.windows.values { window.close() }
        outputs.stopAllOutputs(); projection.close(); panel.close()
        NSApp.mainMenu = previousMenu
        defaults.removePersistentDomain(forName: suite)
    }
}

private enum DesktopFixtureError: Error { case unknownAction(String), directoryExists }
