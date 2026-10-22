import AppKit
import XCTest
import SwiftUI
@testable import eucaly

final class LibrarySearchNavigationTests: XCTestCase {
    @MainActor
    func testDismissingSearchRestoresLyricsInsertionPoint() async throws {
        let window = focusWindow()
        defer { window.close() }
        let lyrics = NSTextView(frame: .init(x: 10, y: 10, width: 300, height: 80))
        lyrics.string = "Sing with joy"
        window.contentView?.addSubview(lyrics)
        XCTAssertTrue(window.makeFirstResponder(lyrics))
        lyrics.selectedRange = NSRange(location: 5, length: 0)
        let search = LibrarySearchField(frame: .init(x: 10, y: 100, width: 300, height: 28))
        window.contentView?.addSubview(search)
        await drainFocusRequest()
        XCTAssertTrue(window.firstResponder === search.currentEditor())

        search.removeFromSuperview()
        XCTAssertTrue(window.firstResponder === lyrics)
        XCTAssertEqual(lyrics.selectedRange, NSRange(location: 5, length: 0))
        lyrics.insertText("together ", replacementRange: lyrics.selectedRange())
        XCTAssertEqual(lyrics.string, "Sing together with joy")
    }

    @MainActor
    func testSearchDismissalKeepsAnIntentionallySelectedNewResponder() async {
        let window = focusWindow()
        defer { window.close() }
        let original = NSTextView(frame: .init(x: 10, y: 10, width: 140, height: 80))
        let destination = NSTextView(frame: .init(x: 160, y: 10, width: 140, height: 80))
        window.contentView?.addSubview(original)
        window.contentView?.addSubview(destination)
        XCTAssertTrue(window.makeFirstResponder(original))
        let search = LibrarySearchField(frame: .init(x: 10, y: 100, width: 300, height: 28))
        window.contentView?.addSubview(search)
        await drainFocusRequest()

        XCTAssertTrue(window.makeFirstResponder(destination))
        search.removeFromSuperview()
        XCTAssertTrue(window.firstResponder === destination)
    }

    @MainActor
    func testSearchDismissalDoesNotReviveADetachedPreviousEditor() async {
        let window = focusWindow()
        defer { window.close() }
        let original = NSTextView(frame: .init(x: 10, y: 10, width: 300, height: 80))
        window.contentView?.addSubview(original)
        XCTAssertTrue(window.makeFirstResponder(original))
        let search = LibrarySearchField(frame: .init(x: 10, y: 100, width: 300, height: 28))
        window.contentView?.addSubview(search)
        await drainFocusRequest()

        original.removeFromSuperview()
        search.removeFromSuperview()
        XCTAssertFalse(window.firstResponder === original)
        await drainFocusRequest()
        XCTAssertFalse(window.firstResponder === original, "No deferred restoration may revive a removed editor.")
    }

    @MainActor
    func testDismissingSearchRestoresAFieldThroughItsControlAndKeepsSelection() async throws {
        let window = focusWindow()
        defer { window.close() }
        let original = NSTextField(frame: .init(x: 10, y: 50, width: 300, height: 28))
        original.stringValue = "Workspace name"
        window.contentView?.addSubview(original)
        XCTAssertTrue(window.makeFirstResponder(original))
        let originalEditor = try XCTUnwrap(original.currentEditor() as? NSTextView)
        originalEditor.selectedRange = NSRange(location: 3, length: 4)
        let search = LibrarySearchField(frame: .init(x: 10, y: 100, width: 300, height: 28))
        window.contentView?.addSubview(search)
        await drainFocusRequest()

        search.removeFromSuperview()
        let restoredEditor = try XCTUnwrap(original.currentEditor() as? NSTextView)
        XCTAssertTrue(window.firstResponder === restoredEditor)
        XCTAssertEqual(restoredEditor.selectedRange, NSRange(location: 3, length: 4))
    }

    @MainActor
    private func focusWindow() -> NSWindow {
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 320, height: 150),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @MainActor
    private func drainFocusRequest() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    func testNativeRowViewHasAReuseIdentifier() throws {
        let tableView = NSTableView()
        let coordinator = LibrarySearchResultsListView.Coordinator()

        let rowView = try XCTUnwrap(
            coordinator.tableView(tableView, rowViewForRow: 0)
        )

        XCTAssertEqual(
            rowView.identifier,
            LibrarySearchResultsListView.Coordinator.rowViewIdentifier
        )
    }

    @MainActor
    func testRestoringExistingSearchFocusPreservesInsertionPoint() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let searchField = LibrarySearchField(frame: NSRect(x: 10, y: 20, width: 300, height: 28))
        window.contentView?.addSubview(searchField)
        searchField.stringValue = "grace"

        XCTAssertTrue(window.makeFirstResponder(searchField))
        let fieldEditor = try XCTUnwrap(searchField.currentEditor() as? NSTextView)
        fieldEditor.selectedRange = NSRange(location: 5, length: 0)

        let router = LibrarySearchCommandRouter()
        router.register(searchField: searchField)
        router.restoreSearchFocus()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }

        XCTAssertTrue(window.firstResponder === fieldEditor)
        XCTAssertEqual(fieldEditor.selectedRange, NSRange(location: 5, length: 0))
    }

    @MainActor
    func testSearchEditorPreservesLiteralQueriesWithoutChangingOtherFields() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 120),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let search = LibrarySearchField(frame: NSRect(x: 10, y: 70, width: 300, height: 28))
        let name = NSTextField(frame: NSRect(x: 10, y: 20, width: 300, height: 28))
        window.contentView?.addSubview(search)
        window.contentView?.addSubview(name)
        let sharedEditor = try XCTUnwrap(window.fieldEditor(true, for: name) as? NSTextView)
        let originalTypes = sharedEditor.enabledTextCheckingTypes

        for query in ["\"grace\" -- 'peace'", "https://example.test 12/25/2026", "கிருபை कृपा grace"] {
            XCTAssertTrue(window.makeFirstResponder(search))
            let editor = try XCTUnwrap(search.currentEditor() as? NSTextView)
            XCTAssertFalse(editor === sharedEditor, "Search text checking must not change the window's shared editor.")
            XCTAssertEqual(editor.enabledTextCheckingTypes, 0, "Literal queries must not schedule spell checking, substitutions or data detection.")
            editor.selectAll(nil)
            editor.insertText(query, replacementRange: editor.selectedRange())
            XCTAssertEqual(editor.string, query)

            XCTAssertTrue(window.makeFirstResponder(name))
            XCTAssertEqual(search.stringValue, query)
            XCTAssertTrue(name.currentEditor() === sharedEditor)
            XCTAssertEqual(sharedEditor.enabledTextCheckingTypes, originalTypes)
        }
    }

    @MainActor
    func testEmptyQuickOpenFieldArrowsAndReturnRunBothCommands() async throws {
        let fixture = SearchNavigationFixture(actions: LibraryCommandPaletteAction.allCases)
        defer { fixture.close() }
        await drainFocusRequest()
        let editor = try XCTUnwrap(fixture.field.currentEditor() as? NSTextView)
        XCTAssertTrue(fixture.fieldCoordinator.control(fixture.field, textView: editor,
            doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(fixture.selection, .action(.newLyrics))
        XCTAssertTrue(fixture.fieldCoordinator.control(fixture.field, textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(fixture.actionsRun, [.newLyrics])
        XCTAssertTrue(fixture.fieldCoordinator.control(fixture.field, textView: editor,
            doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertEqual(fixture.selection, .action(.refreshLibrary))
        XCTAssertTrue(fixture.fieldCoordinator.control(fixture.field, textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(fixture.actionsRun, [.newLyrics, .refreshLibrary])
        XCTAssertTrue(fixture.opened.isEmpty)
    }

    @MainActor
    func testNativeTraversalCrossesActionAndFileSectionsWithoutActivating() async throws {
        let url = URL(fileURLWithPath: "/tmp/search-navigation/song.txt")
        let fixture = SearchNavigationFixture(actions: LibraryCommandPaletteAction.allCases,
            results: [.init(url: url, snippet: "Song")])
        defer { fixture.close() }
        await drainFocusRequest()
        fixture.table.moveDown(nil)
        XCTAssertEqual(fixture.selection, .action(.newLyrics))
        fixture.table.moveDown(nil)
        XCTAssertEqual(fixture.selection, .action(.refreshLibrary))
        fixture.table.moveDown(nil)
        XCTAssertEqual(fixture.selection, .result(url))
        XCTAssertEqual(fixture.table.selectedRow, 4)
        XCTAssertFalse(fixture.coordinator.tableView(fixture.table, shouldSelectRow: 0))
        XCTAssertFalse(fixture.coordinator.tableView(fixture.table, shouldSelectRow: 3))
        XCTAssertTrue(fixture.opened.isEmpty, "Navigation only selects a candidate")
        XCTAssertTrue(fixture.actionsRun.isEmpty)
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.table))
        fixture.table.keyDown(with: try keyEvent(code: 36, window: fixture.window))
        XCTAssertEqual(fixture.opened, [url])
        fixture.table.moveUp(nil)
        XCTAssertEqual(fixture.selection, .action(.refreshLibrary))
        fixture.table.keyDown(with: try keyEvent(code: 36, window: fixture.window))
        XCTAssertEqual(fixture.actionsRun, [.refreshLibrary])
        fixture.table.keyDown(with: try keyEvent(code: 53, window: fixture.window))
        XCTAssertEqual(fixture.closeRequests, 1)
    }

    @MainActor
    func testLiveEmptySearchTableConsumesMovementWithoutSuperclassCommands() async {
        let fixture = SearchNavigationFixture(actions: [], results: [])
        defer { fixture.close() }
        await drainFocusRequest()
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.table))
        fixture.table.moveUp(nil)
        fixture.table.moveDown(nil)
        XCTAssertNil(fixture.selection)
        XCTAssertEqual(fixture.table.selectedRow, -1)
        XCTAssertTrue(fixture.actionsRun.isEmpty)
        XCTAssertTrue(fixture.opened.isEmpty)
        XCTAssertTrue(fixture.added.isEmpty)
    }

    @MainActor
    func testFilteredCommandAndFileDoubleActionsUseTheirSharedSelectionIdentity() async throws {
        let url = URL(fileURLWithPath: "/tmp/search-navigation/song.txt")
        let fixture = SearchNavigationFixture(actions: [.refreshLibrary], results: [.init(url: url, snippet: "")])
        defer { fixture.close() }
        await drainFocusRequest()
        let sender = SearchClickedRowTableView()
        sender.testClickedRow = 1
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(fixture.table.doubleAction), to: fixture.table.target, from: sender))
        XCTAssertEqual(fixture.selection, .action(.refreshLibrary))
        XCTAssertEqual(fixture.actionsRun, [.refreshLibrary])
        sender.testClickedRow = 3
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(fixture.table.doubleAction), to: fixture.table.target, from: sender))
        XCTAssertEqual(fixture.selection, .result(url))
        XCTAssertEqual(fixture.opened, [url])
    }

    @MainActor
    func testNativePlaylistMenuAndFocusableAccessoryUseTheSelectedFileAndRejectStaleMenus() async throws {
        let url = URL(fileURLWithPath: "/tmp/search-navigation/song.txt")
        let fixture = SearchNavigationFixture(actions: [.newLyrics], results: [.init(url: url, snippet: "Song")])
        defer { fixture.close() }
        await drainFocusRequest()
        fixture.selection = .result(url)
        fixture.coordinator.update(from: fixture.listView)
        let menu = try XCTUnwrap(fixture.table.menu)
        fixture.coordinator.menuNeedsUpdate(menu)
        XCTAssertEqual(menu.items.map(\.title), ["Preview", "Add to Playlist"])
        let retainedAdd = try XCTUnwrap(menu.item(at: 1))
        menu.performActionForItem(at: 1)
        XCTAssertEqual(fixture.added, [url])

        let cell = try XCTUnwrap(fixture.coordinator.tableView(fixture.table,
            viewFor: fixture.table.tableColumns.first, row: 3) as? NSTableCellView)
        let accessory = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSButton }.first)
        XCTAssertFalse(accessory.refusesFirstResponder)
        accessory.performClick(nil)
        XCTAssertEqual(fixture.added, [url, url])
        XCTAssertEqual(cell.accessibilityCustomActions()?.map(\.name), ["Preview", "Add to Playlist"])

        fixture.results = []
        fixture.selection = .action(.newLyrics)
        fixture.coordinator.update(from: fixture.listView)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(retainedAdd.action), to: retainedAdd.target, from: retainedAdd))
        XCTAssertEqual(fixture.added, [url, url], "A retained menu must not act on a row removed by a new query")
    }

    @MainActor
    func testRetainedSearchActionsAreInertAfterNativeTeardown() async throws {
        let url = URL(fileURLWithPath: "/tmp/search-navigation/song.txt")
        let fixture = SearchNavigationFixture(actions: LibraryCommandPaletteAction.allCases,
            results: [.init(url: url, snippet: "Song")])
        defer { fixture.close() }
        await drainFocusRequest()
        fixture.selection = .result(url)
        fixture.coordinator.update(from: fixture.listView)
        let menu = try XCTUnwrap(fixture.table.menu)
        fixture.coordinator.menuNeedsUpdate(menu)
        let previewItem = try XCTUnwrap(menu.item(at: 0))
        let addItem = try XCTUnwrap(menu.item(at: 1))
        let cell = try XCTUnwrap(fixture.coordinator.tableView(fixture.table,
            viewFor: fixture.table.tableColumns.first, row: 4) as? NSTableCellView)
        let accessory = try XCTUnwrap(cell.subviews.compactMap { $0 as? NSButton }.first)
        let accessibilityActions = try XCTUnwrap(cell.accessibilityCustomActions())
        let retainedDefaultAction = try XCTUnwrap(fixture.table.defaultActionHandler)
        let retainedCancelAction = try XCTUnwrap(fixture.table.cancelActionHandler)
        let retainedFieldAction = try XCTUnwrap(fixture.field.action)
        let editor = try XCTUnwrap(fixture.field.currentEditor() as? NSTextView)
        fixture.query = "literal query"
        fixture.dismissSearch()
        fixture.selection = .action(.refreshLibrary)
        var commits = 0

        for item in [previewItem, addItem] {
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        accessory.performClick(nil)
        for action in accessibilityActions {
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(action.selector), to: action.target, from: action))
        }
        XCTAssertFalse(retainedDefaultAction())
        retainedCancelAction()
        XCTAssertFalse(fixture.router.activateSelection())
        XCTAssertFalse(fixture.router.addSelectionToPlaylist())
        XCTAssertFalse(fixture.router.performPrimaryAction { commits += 1 })
        XCTAssertFalse(fixture.router.perform(#selector(NSResponder.moveDown(_:)), sender: nil))
        XCTAssertNil(fixture.table.defaultActionHandler)
        XCTAssertNil(fixture.table.menu)
        XCTAssertNil(fixture.table.navigationHandler)
        fixture.table.moveUp(nil)
        fixture.table.moveDown(nil)
        // A retained bridge update cannot register a retired coordinator again.
        fixture.coordinator.update(from: fixture.listView)
        XCTAssertFalse(fixture.router.activateSelection())
        fixture.field.stringValue = "late callback"
        XCTAssertTrue(NSApp.sendAction(retainedFieldAction, to: fixture.fieldCoordinator, from: fixture.field))
        XCTAssertFalse(fixture.fieldCoordinator.control(fixture.field, textView: editor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertFalse(fixture.fieldCoordinator.control(fixture.field, textView: editor,
            doCommandBy: #selector(NSResponder.cancelOperation(_:))))
        XCTAssertEqual(fixture.query, "literal query")
        XCTAssertEqual(fixture.selection, .action(.refreshLibrary))
        XCTAssertTrue(fixture.opened.isEmpty)
        XCTAssertTrue(fixture.added.isEmpty)
        XCTAssertTrue(fixture.actionsRun.isEmpty)
        XCTAssertEqual(fixture.closeRequests, 0)
        XCTAssertEqual(commits, 0)
    }

    @MainActor
    func testSearchCommandsLeaveMarkedInputAndTextEditingToTheNativeEditor() async throws {
        let fixture = SearchNavigationFixture(actions: LibraryCommandPaletteAction.allCases)
        defer { fixture.close() }
        await drainFocusRequest()
        let editor = try XCTUnwrap(fixture.field.currentEditor() as? NSTextView)
        editor.insertText("கிருபை grace", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(fixture.field.stringValue, "கிருபை grace")
        for selector in [#selector(NSResponder.moveLeft(_:)), #selector(NSResponder.deleteBackward(_:)),
                         #selector(NSText.selectAll(_:)), #selector(NSText.paste(_:))] {
            XCTAssertFalse(fixture.fieldCoordinator.control(fixture.field, textView: editor, doCommandBy: selector))
        }
        editor.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        for selector in [#selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)),
                         #selector(NSResponder.cancelOperation(_:))] {
            XCTAssertFalse(fixture.fieldCoordinator.control(fixture.field, textView: editor, doCommandBy: selector))
        }
        XCTAssertNil(fixture.selection)
        XCTAssertTrue(fixture.actionsRun.isEmpty)
        XCTAssertEqual(fixture.closeRequests, 0)
        editor.insertText("仮名", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertTrue(fixture.field.stringValue.hasSuffix("仮名"))
    }

    @MainActor
    func testDismissingTableFocusedSearchRestoresTheLyricsCaretInEitherTeardownOrder() async throws {
        for tableFirst in [true, false] {
            let fixture = SearchNavigationFixture(actions: LibraryCommandPaletteAction.allCases)
            defer { fixture.close() }
            await drainFocusRequest()
            XCTAssertTrue(fixture.window.makeFirstResponder(fixture.table))
            fixture.dismissSearch(tableFirst: tableFirst)
            XCTAssertTrue(fixture.window.firstResponder === fixture.originalLyrics)
            XCTAssertEqual(fixture.originalLyrics.selectedRange(), NSRange(location: 5, length: 0))
        }
    }

    @MainActor
    func testQueuedFocusRestorationDoesNotStealANewerResponder() async throws {
        let fixture = SearchNavigationFixture(actions: LibraryCommandPaletteAction.allCases)
        defer { fixture.close() }
        await drainFocusRequest()
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.table))
        fixture.router.restoreSearchFocus()
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.originalLyrics))
        await drainFocusRequest()
        XCTAssertTrue(fixture.window.firstResponder === fixture.originalLyrics)
    }

    @MainActor
    func testOverlayShowsSearchingUntilTheCurrentQueryCompletes() {
        var selection: LibrarySearchEntryID? = .action(.refreshLibrary)
        let overlay = LibrarySearchOverlayView(query: .constant("refresh"),
            selectedEntry: Binding(get: { selection }, set: { selection = $0 }),
            actions: [.refreshLibrary], results: [], minimumCharacterCount: 3, isIndexing: false,
            searchPhase: .pending, displayName: { $0.lastPathComponent }, onRunAction: { _ in },
            onClose: {}, onOpenResult: { _ in XCTFail("Commands cannot preview a file") },
            onAddResultToPlaylist: { _ in }, onCommitQuery: { XCTFail("An available command runs immediately") })
        XCTAssertEqual(overlay.statusText, "Searching songs…")
        let empty = LibrarySearchOverlayView(query: .constant("unmatched"), selectedEntry: .constant(nil),
            actions: [], results: [], minimumCharacterCount: 3, isIndexing: false, searchPhase: .completed,
            displayName: { $0.lastPathComponent }, onRunAction: { _ in }, onClose: {}, onOpenResult: { _ in },
            onAddResultToPlaylist: { _ in }, onCommitQuery: {})
        XCTAssertEqual(empty.statusText, "No matching songs or actions found")
    }

    @MainActor
    private func keyEvent(code: UInt16, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: code == 53 ? "\u{1b}" : "\r",
            charactersIgnoringModifiers: code == 53 ? "\u{1b}" : "\r", isARepeat: false, keyCode: code))
    }

    func testAppKitSelectorsMapToQuickOpenCommands() {
        XCTAssertEqual(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.moveUp(_:))),
            .previous
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.moveDown(_:))),
            .next
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.pageUp(_:))),
            .pageUp
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.scrollPageUp(_:))),
            .pageUp
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.pageDown(_:))),
            .pageDown
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.scrollPageDown(_:))),
            .pageDown
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(
                selector: #selector(NSResponder.scrollToBeginningOfDocument(_:))
            ),
            .scrollToBeginning
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(
                selector: #selector(NSResponder.scrollToEndOfDocument(_:))
            ),
            .scrollToEnd
        )
        XCTAssertNil(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.deleteBackward(_:)))
        )
    }

    func testActionsAndResultsParticipateInSelection() {
        XCTAssertFalse(LibrarySearchRowRole.section.isSelectable)
        XCTAssertTrue(LibrarySearchRowRole.action.isSelectable)
        XCTAssertTrue(LibrarySearchRowRole.result.isSelectable)
    }

    func testArrowNavigationSkipsSectionHeadings() {
        let resultRows = [2, 5, 9]

        XCTAssertEqual(
            LibrarySearchEntryNavigator.targetRow(
                selectableRows: resultRows,
                currentRow: 2,
                direction: 1
            ),
            5
        )
        XCTAssertEqual(
            LibrarySearchEntryNavigator.targetRow(
                selectableRows: resultRows,
                currentRow: 9,
                direction: -1
            ),
            5
        )
    }

    func testArrowNavigationClampsAtEntryBoundaries() {
        let resultRows = [2, 5, 9]

        XCTAssertEqual(
            LibrarySearchEntryNavigator.targetRow(
                selectableRows: resultRows,
                currentRow: 2,
                direction: -1
            ),
            2
        )
        XCTAssertEqual(
            LibrarySearchEntryNavigator.targetRow(
                selectableRows: resultRows,
                currentRow: 9,
                direction: 1
            ),
            9
        )
    }

    func testArrowNavigationUsesDirectionalFallbackWithoutSelection() {
        let resultRows = [2, 5, 9]

        XCTAssertEqual(
            LibrarySearchEntryNavigator.targetRow(
                selectableRows: resultRows,
                currentRow: nil,
                direction: -1
            ),
            9
        )
        XCTAssertEqual(
            LibrarySearchEntryNavigator.targetRow(
                selectableRows: resultRows,
                currentRow: nil,
                direction: 1
            ),
            2
        )
        XCTAssertNil(
            LibrarySearchEntryNavigator.targetRow(
                selectableRows: [],
                currentRow: nil,
                direction: 1
            )
        )
    }

    func testPageAndBoundaryKeysOnlyScroll() {
        XCTAssertEqual(
            LibrarySearchNavigationCommand.pageUp.operation,
            .scrollPage(up: true)
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand.pageDown.operation,
            .scrollPage(up: false)
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand.scrollToBeginning.operation,
            .scrollToBoundary(beginning: true)
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand.scrollToEnd.operation,
            .scrollToBoundary(beginning: false)
        )
    }
}

@MainActor
private final class SearchNavigationFixture {
    let window: NSWindow
    let router = LibrarySearchCommandRouter()
    let coordinator = LibrarySearchResultsListView.Coordinator()
    let originalLyrics = NSTextView(frame: .init(x: 0, y: 0, width: 300, height: 25))
    var selection: LibrarySearchEntryID?
    var query = ""
    var actions: [LibraryCommandPaletteAction]
    var results: [LibraryTextSearchIndex.SearchResult]
    var actionsRun: [LibraryCommandPaletteAction] = []
    var opened: [URL] = []
    var added: [URL] = []
    var closeRequests = 0
    var fieldCoordinator: LibrarySearchFieldView.Coordinator!
    var field: LibrarySearchField!
    var scrollView: NSScrollView!
    private var dismissed = false

    var table: LibrarySearchTableView { scrollView.documentView as! LibrarySearchTableView }
    var listView: LibrarySearchResultsListView {
        LibrarySearchResultsListView(selectedEntry: Binding(get: { [unowned self] in self.selection },
            set: { [unowned self] in self.selection = $0 }), commandRouter: router, actions: actions, results: results,
            displayName: { $0.lastPathComponent }, onRunAction: { [weak self] in self?.actionsRun.append($0) },
            onOpenResult: { [weak self] in self?.opened.append($0) }, onClose: { [weak self] in self?.closeRequests += 1 },
            onAddResultToPlaylist: { [weak self] in self?.added.append($0) })
    }

    init(actions: [LibraryCommandPaletteAction], results: [LibraryTextSearchIndex.SearchResult] = []) {
        self.actions = actions
        self.results = results
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 640, height: 400),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        originalLyrics.string = "Sing with joy"
        window.contentView?.addSubview(originalLyrics)
        window.makeFirstResponder(originalLyrics)
        originalLyrics.setSelectedRange(NSRange(location: 5, length: 0))
        fieldCoordinator = LibrarySearchFieldView.Coordinator(
            text: Binding(get: { [unowned self] in self.query }, set: { [unowned self] in self.query = $0 }),
            commandRouter: router, onSubmit: { [weak self] in _ = self?.router.activateSelection() },
            onClose: { [weak self] in self?.closeRequests += 1 })
        field = LibrarySearchFieldView.makeSearchField(coordinator: fieldCoordinator, commandRouter: router)
        field.frame = .init(x: 10, y: 360, width: 620, height: 28)
        window.contentView?.addSubview(field)
        scrollView = LibrarySearchResultsListView.makeScrollView(coordinator: coordinator, from: listView)
        scrollView.frame = .init(x: 10, y: 35, width: 620, height: 300)
        window.contentView?.addSubview(scrollView)
        window.contentView?.layoutSubtreeIfNeeded()
    }

    func dismissSearch(tableFirst: Bool = true) {
        guard !dismissed else { return }
        dismissed = true
        let removeTable = {
            LibrarySearchResultsListView.dismantleNSView(self.scrollView, coordinator: self.coordinator)
            self.scrollView.removeFromSuperview()
        }
        let removeField = {
            LibrarySearchFieldView.dismantleNSView(self.field, coordinator: self.fieldCoordinator)
            self.field.removeFromSuperview()
        }
        if tableFirst { removeTable(); removeField() } else { removeField(); removeTable() }
    }

    func close() {
        dismissSearch()
        window.close()
    }
}

@MainActor
private final class SearchClickedRowTableView: NSTableView {
    var testClickedRow = -1
    override var clickedRow: Int { testClickedRow }
}
