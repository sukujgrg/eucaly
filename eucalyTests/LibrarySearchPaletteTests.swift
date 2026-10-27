import AppKit
import XCTest
@testable import eucaly

@MainActor
final class LibrarySearchPaletteTests: XCTestCase {
    func testRowAddShowsCommittedFeedbackWithoutChangingSearchOrCurrent() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        try await fixture.prepareResults()
        let controller = try fixture.present()
        try await until("native query editor") { controller.searchField.currentEditor() != nil }
        let editor = try XCTUnwrap(controller.searchField.currentEditor() as? NSTextView)
        editor.selectedRange = .init(location: 1, length: 2)
        let current = fixture.hub.session.slides.map(\.id)
        let output = fixture.hub.outputs.snapshot(for: fixture.hub.nativeRow).current
        let candidate = fixture.model.selectedEntry
        let button = try accessory(in: controller)
        XCTAssertTrue(controller.fieldController.control(controller.searchField, textView: editor,
            doCommandBy: #selector(NSResponder.insertTab(_:))))
        XCTAssertTrue(fixture.window.firstResponder === button)
        button.performClick(nil)
        try await until("query caret after row add") {
            controller.searchField.currentEditor()?.selectedRange == NSRange(location: 1, length: 2)
        }
        XCTAssertTrue(fixture.presenter.isPresented)
        XCTAssertEqual(controller.feedbackLabel.stringValue, "Added Song to Playlist")
        XCTAssertFalse(controller.feedbackLabel.isHidden)
        XCTAssertTrue(String(describing: controller.feedbackLabel.accessibilityValue()).contains("Song"))
        var visited: Set<ObjectIdentifier> = []
        func accessibleElements(_ object: Any) -> [any NSAccessibilityProtocol] {
            guard let element = object as? any NSAccessibilityProtocol,
                  visited.insert(ObjectIdentifier(element)).inserted else { return [] }
            return [element] + (element.accessibilityChildren() ?? []).flatMap(accessibleElements)
        }
        XCTAssertTrue(accessibleElements(fixture.window).contains {
            ($0.accessibilityValue() as? String) == "Added Song to Playlist"
        }, "The actual exposed accessibility element must retain the feedback message")
        XCTAssertEqual(fixture.store.entries.count, 1)
        XCTAssertEqual(fixture.model.query, "grace")
        XCTAssertEqual(fixture.model.selectedEntry, candidate)
        XCTAssertTrue(fixture.opened.isEmpty); XCTAssertTrue(fixture.actions.isEmpty)
        XCTAssertEqual(fixture.hub.session.slides.map(\.id), current)
        XCTAssertEqual(fixture.hub.outputs.snapshot(for: fixture.hub.nativeRow).current, output)
        XCTAssertTrue(fixture.hub.session.isPresenting)

        // Repeating a song is an existing playlist capability, not a duplicate
        // error invented by presentation feedback.
        button.performClick(nil)
        XCTAssertEqual(fixture.store.entries.count, 2)
        XCTAssertEqual(controller.feedbackLabel.stringValue, "Added Song to Playlist")
        editor.insertText("mercy", replacementRange: .init(location: 0, length: editor.string.utf16.count))
        XCTAssertTrue(controller.feedbackLabel.isHidden)
    }

    func testAccessibleAddReportsSaveFailureInsideSearchAndKeepsSavedBytes() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        try await fixture.prepareResults()
        let controller = try fixture.present()
        try await until("native query editor") { controller.searchField.currentEditor() != nil }
        let document = fixture.directory.appendingPathComponent("Playlist/playlist.json")
        let corrupted = Data("not a playlist document".utf8)
        try corrupted.write(to: document)
        let cell = try resultCell(in: controller)
        let action = try XCTUnwrap(cell.accessibilityCustomActions()?.first { $0.name == "Add to Playlist" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(action.selector), to: action.target, from: action))
        XCTAssertTrue(fixture.presenter.isPresented)
        XCTAssertFalse(controller.feedbackLabel.isHidden)
        XCTAssertEqual(controller.feedbackLabel.stringValue,
                       "Could not add Song to Playlist. " + (try XCTUnwrap(fixture.store.lastError)))
        XCTAssertTrue(String(describing: controller.feedbackLabel.accessibilityValue()).contains("Could not add Song"))
        XCTAssertEqual(try Data(contentsOf: document), corrupted)
        XCTAssertTrue(fixture.store.entries.isEmpty)
        XCTAssertEqual(fixture.model.query, "grace")
        XCTAssertEqual(fixture.model.selectedEntry, .result(fixture.url))
        XCTAssertTrue(fixture.opened.isEmpty)
        XCTAssertEqual(fixture.hub.session.slides.first?.lines.first?.text, "Current stays live")
    }

    func testDismissalEndsNativeFocusBeforeRemovalAndRestoresDefaultButtonImmediately() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        try await fixture.prepareResults()
        let original = fixture.originalLyrics
        original.selectedRange = .init(location: 4, length: 2)
        let defaultButton = fixture.window.defaultButtonCell
        let controller = try fixture.present()
        try await until("native query editor") { controller.searchField.currentEditor() != nil }
        let accessory = try accessory(in: controller)
        XCTAssertEqual(controller.searchField.focusRingType, .default)
        XCTAssertTrue(fixture.window.makeFirstResponder(controller.closeButton))
        controller.closeButton.performClick(nil)

        // No animation completion, timer or main-queue turn is needed for these
        // ownership assertions: the old native focus scope is already retired.
        XCTAssertFalse(fixture.presenter.isPresented)
        XCTAssertNil(controller.view.superview)
        XCTAssertNil(controller.searchField.window)
        XCTAssertTrue(controller.searchField.isSearchDismissed)
        XCTAssertFalse(controller.commandRouter.isAttached)
        XCTAssertTrue(fixture.window.firstResponder === original)
        XCTAssertEqual(original.selectedRange, NSRange(location: 4, length: 2))
        XCTAssertTrue(fixture.window.defaultButtonCell === defaultButton)
        accessory.performClick(nil)
        controller.performPrimaryAction()
        controller.searchField.stringValue = "late retired edit"
        controller.fieldController.controlTextDidChange(.init(name: NSControl.textDidChangeNotification,
                                                             object: controller.searchField))
        XCTAssertTrue(fixture.store.entries.isEmpty)
        XCTAssertEqual(fixture.model.query, "grace")
        await mainQueueBoundary()
        XCTAssertTrue(fixture.window.firstResponder === original)
    }

    func testDismissBeforeQueuedInitialFocusAndReopenCannotReviveOldControls() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        try await fixture.prepareResults()
        let first = try fixture.present()
        fixture.presenter.dismiss()
        let second = try fixture.present()
        XCTAssertFalse(first === second)
        XCTAssertFalse(first.searchField === second.searchField)
        try await until("new query editor") { second.searchField.currentEditor() != nil }
        let editor = try XCTUnwrap(second.searchField.currentEditor())
        editor.selectedRange = .init(location: 2, length: 1)
        first.commandRouter.restoreSearchFocus()
        first.performPrimaryAction()
        first.closeButton.performClick(nil)
        await mainQueueBoundary()
        XCTAssertTrue(fixture.presenter.activeController === second)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertEqual(editor.selectedRange, NSRange(location: 2, length: 1))
        XCTAssertEqual(editor.string, "grace")
        XCTAssertTrue(fixture.opened.isEmpty); XCTAssertTrue(fixture.actions.isEmpty)
    }

    func testModelInvalidationRejectsRetainedRowAddBeforeNativeRenderRuns() async throws {
        let fixture = try Fixture(); defer { fixture.close() }
        try await fixture.prepareResults()
        let controller = try fixture.present()
        try await until("native query editor") { controller.searchField.currentEditor() != nil }
        let oldAdd = try accessory(in: controller)
        fixture.model.setScopeFiles([])
        // The model has committed its new scope, but its coalesced native render
        // is intentionally still queued.
        oldAdd.performClick(nil)
        XCTAssertTrue(fixture.store.entries.isEmpty)
        XCTAssertTrue(controller.feedbackLabel.isHidden)
        XCTAssertNil(fixture.model.selectedEntry)
        XCTAssertTrue(fixture.opened.isEmpty)
    }

    func testPendingPrimaryCannotActivateAReopenedSearch() async throws {
        let gate = SearchGate()
        let fixture = try Fixture(search: { _, _ in await gate.search() })
        defer { fixture.close() }
        fixture.model.setScopeFiles([fixture.url])
        fixture.model.setQuery("pending", currentSelectedURL: nil)
        try await until("debounce cancellation") { fixture.model.queryPhase == .idle }
        let first = try fixture.present()
        first.performPrimaryAction()
        await gate.waitForStart()
        let task = try XCTUnwrap(first.primaryTask)
        fixture.presenter.dismiss()
        let second = try fixture.present()
        await gate.finish([.init(url: fixture.url, snippet: "late")])
        await task.value
        XCTAssertTrue(fixture.presenter.activeController === second)
        XCTAssertTrue(fixture.presenter.isPresented)
        XCTAssertTrue(fixture.opened.isEmpty)
        XCTAssertEqual(fixture.model.query, "pending")
    }

    func testQueuedPrimaryIsRejectedBeforeItCanCancelAReopenedQuery() async throws {
        let counter = SearchCounter()
        let fixture = try Fixture(search: { query, files in await counter.search(query, files: files) })
        defer { fixture.close() }
        fixture.model.setScopeFiles([fixture.url])
        fixture.model.setQuery("pending", currentSelectedURL: nil)
        try await until("debounce cancellation") { fixture.model.queryPhase == .idle }
        let first = try fixture.present()
        first.performPrimaryAction()
        let oldTask = try XCTUnwrap(first.primaryTask)
        // No actor/main-queue suspension occurs between Return and replacement.
        fixture.presenter.dismiss()
        fixture.model.setQuery("newer", currentSelectedURL: nil)
        let second = try fixture.present()
        second.performPrimaryAction()
        let freshTask = try XCTUnwrap(second.primaryTask)
        await freshTask.value
        await oldTask.value
        let queries = await counter.queries
        XCTAssertEqual(queries, ["newer"])
        XCTAssertEqual(fixture.opened, [fixture.url])
        XCTAssertEqual(fixture.model.query, "newer")
    }

    func testNativeFooterAndStatusSemanticsAndAppearance() async throws {
        let pending = LibrarySearchPalettePresentation(query: "refresh", selectedEntry: .action(.refreshLibrary),
            actions: [.refreshLibrary], results: [], minimumCharacterCount: 3, isIndexing: false, searchPhase: .pending)
        XCTAssertEqual(pending.statusText, "Searching library files…")
        XCTAssertEqual(pending.primaryButtonTitle, "Refresh Library")
        XCTAssertTrue(pending.primaryButtonEnabled)
        let completed = LibrarySearchPalettePresentation(query: "missing", selectedEntry: nil,
            actions: [], results: [], minimumCharacterCount: 3, isIndexing: false, searchPhase: .completed)
        XCTAssertEqual(completed.statusText, "No matching files or actions found")
        XCTAssertFalse(completed.primaryButtonEnabled)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let fixture = try Fixture(); defer { fixture.close() }
            fixture.window.appearance = NSAppearance(named: appearance)
            try await fixture.prepareResults()
            let controller = try fixture.present()
            try await until("native query editor") { controller.searchField.currentEditor() != nil }
            XCTAssertEqual(controller.closeButton.title, "Close")
            XCTAssertEqual(controller.primaryButton.title, "Preview")
            XCTAssertEqual(controller.primaryButton.keyEquivalent, "\r")
            XCTAssertTrue(fixture.window.defaultButtonCell === controller.primaryButton.cell)
            XCTAssertFalse(descendants(NSButton.self, in: controller.view).contains { $0.title == "Add to Playlist" })
            XCTAssertTrue(controller.primaryButton.nextKeyView === controller.searchField)
            XCTAssertTrue(controller.closeButton.nextKeyView === controller.primaryButton)
            try accessory(in: controller).performClick(nil)
            fixture.window.layoutIfNeeded(); fixture.window.contentView?.layoutSubtreeIfNeeded()
            fixture.window.display()
            let footer = try XCTUnwrap(controller.primaryButton.superview)
            let primaryAlignment = controller.card.convert(
                controller.primaryButton.alignmentRect(forFrame: controller.primaryButton.frame), from: footer)
            let closeAlignment = controller.card.convert(
                controller.closeButton.alignmentRect(forFrame: controller.closeButton.frame), from: footer)
            XCTAssertEqual(primaryAlignment.maxX, controller.card.bounds.maxX - 16, accuracy: 1,
                           "The primary action belongs at the card's trailing inset")
            XCTAssertEqual(closeAlignment.minX, controller.card.bounds.minX + 16, accuracy: 1,
                           "Close belongs at the card's leading inset")
            let content = try XCTUnwrap(fixture.window.contentView)
            // Bitmap caching omits compositor-backed selection materials;
            // selected-row contrast requires native on-screen observation.
            let bitmap = try XCTUnwrap(content.bitmapImageRepForCachingDisplay(in: content.bounds))
            content.effectiveAppearance.performAsCurrentDrawingAppearance {
                content.cacheDisplay(in: content.bounds, to: bitmap)
            }
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: "/tmp/eucaly-native-search-palette-\(appearance.rawValue).png"))
        }
    }

    private func resultCell(in controller: LibrarySearchPaletteController) throws -> NSTableCellView {
        let table = controller.resultsController.table
        table.layoutSubtreeIfNeeded()
        return try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
    }
    private func accessory(in controller: LibrarySearchPaletteController) throws -> NSButton {
        try XCTUnwrap(descendants(NSButton.self, in: resultCell(in: controller)).first)
    }
    private func descendants<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.compactMap { $0 as? T } + view.subviews.flatMap { descendants(type, in: $0) }
    }
    private func mainQueueBoundary() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }
    private func until(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { XCTFail("Timed out waiting for \(description)"); throw PaletteTestFailure.timedOut }
    }

    private enum PaletteTestFailure: Error { case timedOut }

    @MainActor
    private final class Fixture: NSObject, NSWindowDelegate {
        let directory: URL
        let url: URL
        let store = PlaylistStore()
        let model: LibrarySearchModel
        let hub = LocalOutputHarness()
        let presenter = LibrarySearchPalettePresenter()
        let window: NSWindow
        let root = NSViewController()
        let originalLyrics = NSTextView(frame: .init(x: 30, y: 30, width: 300, height: 80))
        let previousButton = NSButton(title: "Previous Default", target: nil, action: nil)
        var opened: [URL] = []
        var actions: [LibraryCommandPaletteAction] = []

        init(search: LibrarySearchModel.Search? = nil) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent("NativeSearchPalette." + UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            url = directory.appendingPathComponent("song.txt")
            try Data("Verse\nSong".utf8).write(to: url)
            let resultURL = url
            model = LibrarySearchModel(index: LibraryTextSearchIndex(databaseURL: directory.appendingPathComponent("index.sqlite")),
                debounce: { throw CancellationError() },
                search: search ?? { _, _ in [.init(url: resultURL, snippet: "Song lyrics\nSecond lyric", title: "Song")] })
            window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1060, height: 660),
                styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            super.init()
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            root.view = NSView(frame: .init(x: 0, y: 0, width: 1060, height: 660))
            originalLyrics.string = "Original editor selection"
            root.view.addSubview(originalLyrics)
            root.view.addSubview(previousButton)
            window.contentViewController = root
            window.delegate = self
            window.defaultButtonCell = previousButton.cell as? NSButtonCell
            window.setFrameOrigin(.init(x: -10000, y: -10000))
            window.orderBack(nil)
            window.makeFirstResponder(originalLyrics)
            XCTAssertTrue(store.load(fromRoot: directory))
            hub.load("Verse\nCurrent stays live"); hub.session.showSlides()
        }
        func prepareResults() async throws {
            model.setScopeFiles([url])
            model.setQuery("grace", currentSelectedURL: nil)
            let result = await model.searchImmediately(currentSelectedURL: nil)
            XCTAssertEqual(result, url)
        }
        func present() throws -> LibrarySearchPaletteController {
            XCTAssertTrue(presenter.present(in: window, model: model, currentSelectedURL: { nil },
                onRunAction: { [weak self] in self?.actions.append($0) },
                onOpenResult: { [weak self] in self?.opened.append($0) },
                onAddResultToPlaylist: { [weak self] url in
                    guard let self else { return .failed("Closed") }
                    return self.store.add(url: url, after: nil) != nil
                        ? .added : .failed(self.store.lastError ?? "Could not add file")
                }))
            return try XCTUnwrap(presenter.activeController)
        }
        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { presenter.undoManager }
        func close() {
            presenter.dismiss(); window.close(); model.cancelDebounce(); hub.outputs.stopAllOutputs()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private actor SearchGate {
        private var request: CheckedContinuation<[LibraryTextSearchIndex.SearchResult], Never>?
        private var waiter: CheckedContinuation<Void, Never>?
        func search() async -> [LibraryTextSearchIndex.SearchResult] {
            await withCheckedContinuation { continuation in
                request = continuation
                waiter?.resume(); waiter = nil
            }
        }
        func waitForStart() async {
            if request != nil { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func finish(_ results: [LibraryTextSearchIndex.SearchResult]) {
            let continuation = request; request = nil
            continuation?.resume(returning: results)
        }
    }

    private actor SearchCounter {
        private(set) var queries: [String] = []
        func search(_ query: String, files: [URL]) -> [LibraryTextSearchIndex.SearchResult] {
            queries.append(query)
            return files.map { .init(url: $0, snippet: query) }
        }
    }
}
