import AppKit
import SwiftUI
import SQLite3
import XCTest
@testable import eucaly

@MainActor
final class LibrarySearchWorkspaceTests: XCTestCase {
    func testSearchCommandInRealContentViewOpensVisiblePaletteAndKeepsCurrent() async throws {
        try await exerciseSearchFixture(fullscreen: false)
    }

    func testClosingFullscreenWorkspaceReleasesSearchFixture() async throws {
        try await exerciseSearchFixture(fullscreen: true)
    }

    private func exerciseSearchFixture(fullscreen: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SearchContentView-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let closed = expectation(description: "Search fixture releases its SQLite connection before removing the library")
        let lifetime = FixtureLifetime()
        var failure: Error?
        do {
            try await exerciseSearchCommandInRealContentView(root: root, fullscreen: fullscreen, lifetime: lifetime, onConnectionClosed: { result in
                XCTAssertEqual(result, SQLITE_OK)
                if result == SQLITE_OK {
                    do { try FileManager.default.removeItem(at: root) }
                    catch { XCTFail("Could not remove the closed search fixture: \(error)") }
                }
                closed.fulfill()
            })
        } catch {
            failure = error
        }
        await fulfillment(of: [closed], timeout: 5)
        XCTAssertNil(lifetime.model)
        XCTAssertNil(lifetime.inventory)
        XCTAssertNil(lifetime.index)
        if let failure { throw failure }
    }

    /// The helper's return releases the UI, inventory and query owners together.
    /// The close callback owns directory removal, including if a failed test
    /// leaves framework references alive beyond the assertion deadline.
    private func exerciseSearchCommandInRealContentView(
        root: URL, fullscreen: Bool, lifetime: FixtureLifetime, onConnectionClosed: @escaping @Sendable (Int32) -> Void
    ) async throws {
        let song = root.appendingPathComponent("220192.txt")
        try "Verse\nAmazing grace will always carry me safely home".write(to: song, atomically: true, encoding: .utf8)
        let suite = "SearchContentView." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(root.path, forKey: "libraryRootPath")
        defer { defaults.removePersistentDomain(forName: suite) }
        let index = LibraryTextSearchIndex(databaseURL: root.appendingPathComponent("index.sqlite"),
                                           onConnectionClosed: onConnectionClosed)
        let model = LibrarySearchModel(index: index)
        defer { model.cancelDebounce() }
        let inventory = LibraryInventoryStore(index: index)
        lifetime.model = model; lifetime.inventory = inventory; lifetime.index = index
        let playlist = PlaylistStore()
        let hub = LocalOutputHarness()
        hub.load("Verse\nCurrent remains live")
        hub.session.showSlides()
        let current = hub.outputs.snapshot(for: hub.nativeRow).current
        let updates = AppUpdateViewModel(driver: WorkspaceUpdateDriver())
        let focus = WindowFocus()
        let windows = OutputWorkspaceWindows(outputs: hub.outputs, updates: updates,
            autosavesWindowFrames: false, keyWindow: { focus.window },
            contentFactory: { session, commands in
                let menu = OutputWorkspaceMenuController(workspaces: commands.workspaceWindows!, workspaceID: session.outputSourceID)
                return OutputWorkspaceWindowController.hostingController(rootView:
                    ContentView(session: session, commands: commands, workspaceMenu: menu,
                        librarySearch: model, playlistStore: playlist, libraryInventory: inventory,
                        controlPreferences: defaults)
                    .environmentObject(updates).defaultAppStorage(defaults))
            })
        defer { for window in windows.windows.values { window.close() }; hub.outputs.stopAllOutputs() }
        var failure: Error?
        do {
            let host = try XCTUnwrap(windows.open(hub.session.outputSourceID))
            let window = try XCTUnwrap(host.window)
            focus.window = window
            try await until { model.scopeFilesSnapshot.contains(song) }
            model.setQuery("grace", currentSelectedURL: nil)
            try await until { model.queryPhase == .completed }
            NotificationCenter.default.post(name: .showLibrarySearch, object: nil)
            let palette = try XCTUnwrap(host.commands.librarySearchPresenter.activeController)
            await mainQueueBoundary()
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            assertHittable(palette.searchField, in: window)
            assertHittable(palette.closeButton, in: window)
            XCTAssertEqual(try searchResultTitle(in: palette).stringValue, "Amazing grace will always carry me")
            let selected = model.selectedEntry
            try "#title: Grace in every season\nVerse\nAmazing grace will always carry me safely home".write(to: song, atomically: true, encoding: .utf8)
            inventory.refresh(root: root)
            try await until { model.filteredResults.first?.title == "Grace in every season" }
            await mainQueueBoundary()
            window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(try searchResultTitle(in: palette).stringValue, "Grace in every season")
            XCTAssertEqual(model.selectedEntry, selected)
            XCTAssertFalse(try XCTUnwrap(window.toolbar).items.isEmpty)
            NotificationCenter.default.post(name: .showLibrarySearch, object: nil)
            XCTAssertTrue(host.commands.librarySearchPresenter.activeController === palette)
            XCTAssertEqual(model.query, "grace")
            palette.closeButton.performClick(nil)
            XCTAssertFalse(host.commands.librarySearchPresenter.isPresented)
            NotificationCenter.default.post(name: .showLibrarySearch, object: nil)
            let reopened = try XCTUnwrap(host.commands.librarySearchPresenter.activeController)
            XCTAssertFalse(reopened === palette)
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            assertHittable(reopened.searchField, in: window)
            XCTAssertEqual(model.query, "grace")
            XCTAssertEqual(hub.outputs.snapshot(for: hub.nativeRow).current, current)
            XCTAssertTrue(hub.session.isPresenting)
            let split = try XCTUnwrap((window.toolbar?.delegate as? PresentationToolbarController)?.splitController as? WorkspaceSplitViewController)
            let nativeContent = try XCTUnwrap(window.contentView)
            let pinnedButton = split.workspacesAccessory.controls.button
            let pinnedFrame = nativeContent.convert(pinnedButton.bounds, from: pinnedButton)
            let splitFrame = nativeContent.convert(split.view.bounds, from: split.view)
            XCTAssertEqual(splitFrame.maxY, nativeContent.bounds.maxY, accuracy: 1)
            let notice = "Fixture output notice must stay within detail"
            hub.outputs.reportAppearanceEditIssue(notice, workspace: hub.session.outputSourceID)
            try await until { hub.session.projectionDisplayIssue == notice }
            await mainQueueBoundary()
            window.layoutIfNeeded(); nativeContent.layoutSubtreeIfNeeded()
            XCTAssertEqual(nativeContent.convert(pinnedButton.bounds, from: pinnedButton), pinnedFrame)
            XCTAssertEqual(nativeContent.convert(split.view.bounds, from: split.view), splitFrame)
            XCTAssertEqual(hub.outputs.snapshot(for: hub.nativeRow).current, current)
            reopened.closeButton.performClick(nil)
            hub.outputs.dismissIssue(workspace: hub.session.outputSourceID)
            if fullscreen {
                let entered = expectation(forNotification: NSWindow.didEnterFullScreenNotification, object: window)
                window.toggleFullScreen(nil)
                await fulfillment(of: [entered], timeout: 5)
                XCTAssertTrue(window.styleMask.contains(.fullScreen))
            }
        } catch {
            failure = error
        }
        // Let root-scoped refreshes finish before retiring workspace subscribers.
        // Capture the task before cancellation clears the model's task handle.
        await inventory.waitForRefresh(root: root)
        for window in windows.windows.values {
            window.close()
            XCTAssertNil(window.toolbar)
            XCTAssertNil(window.contentViewController)
        }
        XCTAssertTrue(windows.controllers.isEmpty)
        focus.window = nil
        let pendingSearch = model.pendingSearchTaskForTests
        model.cancelDebounce()
        await pendingSearch?.value
        await mainQueueBoundary()
        if let failure { throw failure }
    }

    func testPaletteControlsStayVisibleAndHittableAboveNativeWorkspaceSplit() async throws {
        let hub = LocalOutputHarness()
        let suite = "NativeSearchSplit." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let updates = AppUpdateViewModel(driver: WorkspaceUpdateDriver())
        let windows = OutputWorkspaceWindows(outputs: hub.outputs, updates: updates, autosavesWindowFrames: false,
            contentFactory: { session, commands in
                let menu = OutputWorkspaceMenuController(workspaces: commands.workspaceWindows!, workspaceID: session.outputSourceID)
                return OutputWorkspaceWindowController.hostingController(rootView:
                    WorkspaceSplitView(sidebarConfiguration: WorkspaceChromeFixture.sidebar(session: session),
                        workspaceMenu: menu, defaults: defaults,
                        session: session, updates: updates, toggleSlides: {}, searchLibrary: {}, manageOutputs: {},
                        detail: Text("Private workspace content")))
            })
        defer { for window in windows.windows.values { window.close() } }
        let host = try XCTUnwrap(windows.open(hub.session.outputSourceID))
        let window = try XCTUnwrap(host.window)
        window.makeKeyAndOrderFront(nil)
        await mainQueueBoundary()
        let model = LibrarySearchModel()
        XCTAssertTrue(host.commands.librarySearchPresenter.present(in: window, model: model,
            currentSelectedURL: { nil },
            onRunAction: { _ in }, onOpenResult: { _ in }, onAddResultToPlaylist: { _ in .added }))
        let palette = try XCTUnwrap(host.commands.librarySearchPresenter.activeController)
        let content = try XCTUnwrap(window.contentView)
        for size in [NSSize(width: 1280, height: 800), .init(width: 1060, height: 600),
                     .init(width: 1440, height: 900)] {
            window.setContentSize(size)
            await mainQueueBoundary()
            window.layoutIfNeeded()
            content.layoutSubtreeIfNeeded()
            window.display()
            assertHittable(palette.searchField, in: window)
            assertHittable(palette.closeButton, in: window)
        }
        try await until { palette.searchField.currentEditor() != nil && window.toolbar != nil }
        let editor = try XCTUnwrap(palette.searchField.currentEditor())
        let sidebarToggle = try XCTUnwrap(window.toolbar?.items.first { $0.itemIdentifier == .toggleSidebar })
        for _ in 0..<2 {
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(sidebarToggle.action), to: sidebarToggle.target, from: sidebarToggle))
            await mainQueueBoundary()
            content.layoutSubtreeIfNeeded()
            assertHittable(palette.searchField, in: window)
            XCTAssertTrue(palette.searchField.currentEditor() === editor,
                          "Native sidebar changes must preserve the palette's active query editor")
        }
    }

    func testNativePaletteIsAccessibleAboveHostedWorkspaceContent() async throws {
        let hub = LocalOutputHarness()
        let windows = OutputWorkspaceWindows(outputs: hub.outputs,
            updates: AppUpdateViewModel(driver: WorkspaceUpdateDriver()), autosavesWindowFrames: false,
            contentFactory: { _, _ in
                OutputWorkspaceWindowController.hostingController(rootView:
                    Text("Workspace content").environment(\.accessibilityEnabled, true))
            })
        defer { for window in windows.windows.values { window.close() } }
        let host = try XCTUnwrap(windows.open(hub.session.outputSourceID))
        let window = try XCTUnwrap(host.window)
        await mainQueueBoundary()
        let model = LibrarySearchModel()
        XCTAssertTrue(host.commands.librarySearchPresenter.present(in: window, model: model,
            currentSelectedURL: { nil },
            onRunAction: { _ in }, onOpenResult: { _ in }, onAddResultToPlaylist: { _ in .added }))
        let palette = try XCTUnwrap(host.commands.librarySearchPresenter.activeController)
        try await until { palette.searchField.currentEditor() != nil }
        window.layoutIfNeeded()
        var visited: Set<ObjectIdentifier> = []
        func descendants(_ object: Any) -> [any NSAccessibilityProtocol] {
            guard let element = object as? any NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(element)).inserted else { return [] }
            return [element] + (element.accessibilityChildren() ?? []).flatMap(descendants)
        }
        let labels = descendants(window).compactMap { $0.accessibilityLabel() }
        XCTAssertTrue(labels.contains("Library search"))
        XCTAssertTrue(labels.contains("Search library files or commands"))
        XCTAssertTrue(labels.contains("Close library search"))
    }

    func testNativePaletteAddAndWorkspaceSwitchPreserveCurrentAndEditorFocus() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SearchWorkspace-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("anthem.txt")
        try "Verse\nPlaylist song".write(to: url, atomically: true, encoding: .utf8)
        let playlist = PlaylistStore()
        XCTAssertTrue(playlist.load(fromRoot: root))
        let model = LibrarySearchModel(index: LibraryTextSearchIndex(databaseURL: root.appendingPathComponent("index.sqlite")),
            debounce: {}, search: { _, files in files.map { .init(url: $0, snippet: "Playlist song") } })
        defer { model.cancelDebounce() }
        model.setScopeFiles([url])
        model.setQuery("anthem", currentSelectedURL: nil)
        try await until { model.queryPhase == .completed }
        model.syncSelection(currentSelectedURL: nil, preferFirstResult: true)

        let hub = LocalOutputHarness()
        hub.load("Verse\nCurrent must stay live")
        hub.session.showSlides()
        let windows = makeWorkspaceWindows(outputs: hub.outputs)
        defer { for window in windows.windows.values { window.close() }; hub.outputs.stopAllOutputs() }
        let primary = hub.session.outputSourceID
        let host = try XCTUnwrap(windows.open(primary))
        let window = try XCTUnwrap(host.window)
        await mainQueueBoundary()
        let editor = NSTextView(frame: .init(x: 20, y: 20, width: 300, height: 100))
        editor.string = "Private editor draft"
        try XCTUnwrap(window.contentView).addSubview(editor)
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.selectedRange = .init(location: 8, length: 6)
        let slides = hub.session.slides.map(\.id)
        let accepted = hub.outputs.snapshot(for: hub.nativeRow).current
        let presenter = host.commands.librarySearchPresenter
        var opened: [URL] = []
        XCTAssertTrue(presenter.present(in: window, model: model, currentSelectedURL: { nil },
            onRunAction: { _ in XCTFail("Add must not run a command") },
            onOpenResult: { opened.append($0) }, onAddResultToPlaylist: { url in
                playlist.add(url: url, after: nil) == nil ? .failed(playlist.lastError ?? "Add failed") : .added
            }))
        let palette = try XCTUnwrap(presenter.activeController)
        try await until { palette.searchField.currentEditor() != nil }
        let queryEditor = try XCTUnwrap(palette.searchField.currentEditor())
        queryEditor.selectedRange = .init(location: 2, length: 3)
        let table = palette.resultsController.table
        let row = try XCTUnwrap(palette.resultsController.coordinator.tableView(table,
            viewFor: table.tableColumns.first, row: 1) as? NSTableCellView)
        let add = try XCTUnwrap(row.subviews.compactMap { $0 as? NSButton }.first)
        add.performClick(nil)
        XCTAssertEqual(playlist.entries.count, 1)
        XCTAssertEqual(palette.feedbackLabel.stringValue, "Added anthem.txt to Playlist")
        XCTAssertEqual(model.query, "anthem")
        XCTAssertEqual(model.selectedEntry, .result(url))
        XCTAssertEqual(queryEditor.selectedRange, NSRange(location: 2, length: 3))
        XCTAssertTrue(presenter.isPresented)
        XCTAssertTrue(opened.isEmpty)
        XCTAssertEqual(hub.session.slides.map(\.id), slides)
        XCTAssertEqual(hub.outputs.snapshot(for: hub.nativeRow).current, accepted)

        let second = try XCTUnwrap(hub.outputs.profiles.addWorkspace())
        XCTAssertTrue(windows.open(second, from: primary) === host)
        XCTAssertFalse(presenter.isPresented)
        XCTAssertNil(palette.view.superview)
        XCTAssertTrue(palette.searchField.isSearchDismissed)
        XCTAssertEqual(model.query, "anthem")
        XCTAssertTrue(windows.open(primary, from: second) === host)
        try await until { window.firstResponder === editor }
        XCTAssertEqual(editor.selectedRange, NSRange(location: 8, length: 6))
        XCTAssertEqual(hub.session.slides.map(\.id), slides)
        XCTAssertEqual(hub.outputs.snapshot(for: hub.nativeRow).current, accepted)
        XCTAssertTrue(hub.outputs.isOpen(hub.nativeRow))
    }

    @MainActor private final class WindowFocus { weak var window: NSWindow? }

    @MainActor private final class FixtureLifetime {
        weak var model: LibrarySearchModel?
        weak var inventory: LibraryInventoryStore?
        weak var index: LibraryTextSearchIndex?
    }

    private func assertHittable(_ control: NSView, in window: NSWindow,
                               file: StaticString = #filePath, line: UInt = #line) {
        guard let content = window.contentView, let parent = content.superview else {
            XCTFail("The workspace must have its native content", file: file, line: line)
            return
        }
        let point = parent.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), from: control)
        let hit = content.hitTest(point)
        XCTAssertTrue(hit === control || hit?.isDescendant(of: control) == true,
                      "Search controls must be visible above the native split view, not merely present in the AX tree",
                      file: file, line: line)
    }

    private func searchResultTitle(in palette: LibrarySearchPaletteController) throws -> NSTextField {
        let table = palette.resultsController.table
        let cell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true))
        func labels(_ view: NSView) -> [NSTextField] {
            view.subviews.compactMap { $0 as? NSTextField } + view.subviews.flatMap(labels)
        }
        return try XCTUnwrap(labels(cell).first { $0.identifier?.rawValue == "LibrarySearch.ItemTitle" })
    }

    private func mainQueueBoundary() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { XCTFail("Native search state did not settle"); throw SearchFailure.timeout }
    }
    private enum SearchFailure: Error { case timeout }
}
