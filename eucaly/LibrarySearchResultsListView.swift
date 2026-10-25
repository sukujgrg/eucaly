import AppKit
import SwiftUI

@MainActor
final class LibrarySearchCommandRouter {
    fileprivate weak var resultsCoordinator: LibrarySearchResultsListView.Coordinator?
    private weak var searchField: NSSearchField?

    func register(searchField: NSSearchField) {
        self.searchField = searchField
        updateFocusCompanion()
    }

    func unregister(searchField: NSSearchField) {
        if self.searchField === searchField {
            self.searchField = nil
        }
    }

    func perform(_ selector: Selector, sender: Any?) -> Bool {
        guard isAttached else { return false }
        guard let command = LibrarySearchNavigationCommand(selector: selector) else {
            return false
        }
        return resultsCoordinator?.perform(command, sender: sender) ?? false
    }

    var isAttached: Bool { searchField?.window != nil }

    @discardableResult
    func focusExistingSearch() -> Bool {
        (searchField as? LibrarySearchField)?.focusForLibrarySearch() ?? false
    }

    func activateSelection() -> Bool {
        guard isAttached else { return false }
        return resultsCoordinator?.activateSelection() ?? false
    }

    @discardableResult
    func performPrimaryAction(commitQuery: () -> Void) -> Bool {
        guard isAttached else { return false }
        if !activateSelection() { commitQuery() }
        return true
    }

    @discardableResult
    func addSelectionToPlaylist() -> Bool {
        guard isAttached else { return false }
        return resultsCoordinator?.addSelectionToPlaylist() ?? false
    }

    fileprivate func updateFocusCompanion() {
        (searchField as? LibrarySearchField)?.focusCompanion = resultsCoordinator?.tableView
    }

    fileprivate func prepareForResultsRemoval(_ tableView: NSTableView) {
        guard let searchField, let window = tableView.window, searchField.window === window,
              let responder = window.firstResponder as? NSView,
              responder === tableView || responder.isDescendant(of: tableView) else { return }
        window.makeFirstResponder(searchField)
    }

    func restoreSearchFocus() {
        guard let searchField,
              !Self.isActivelyEditing(searchField)
        else { return }

        guard let window = searchField.window else { return }
        let initialResponder = window.firstResponder
        DispatchQueue.main.async { [weak searchField, weak window, weak initialResponder] in
            guard let searchField, let window, searchField.window === window,
                  window.firstResponder === initialResponder,
                  !Self.isActivelyEditing(searchField) else { return }
            window.makeFirstResponder(searchField)
        }
    }

    private static func isActivelyEditing(_ searchField: NSSearchField) -> Bool {
        guard let fieldEditor = searchField.currentEditor() else { return false }
        return searchField.window?.firstResponder === fieldEditor
    }
}

/// AppKit-backed result list for Quick Open. Keeping the scrolling and cell
/// reuse in `NSTableView` prevents large search result sets from rebuilding a
/// SwiftUI row hierarchy for every keystroke.
struct LibrarySearchResultsListView: NSViewRepresentable {
    @Binding var selectedEntry: LibrarySearchEntryID?

    let commandRouter: LibrarySearchCommandRouter
    let actions: [LibraryCommandPaletteAction]
    let results: [LibraryTextSearchIndex.SearchResult]
    let displayName: (URL) -> String
    let onRunAction: (LibraryCommandPaletteAction) -> Void
    let onOpenResult: (URL) -> Void
    let onClose: () -> Void
    let onAddResultToPlaylist: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        Self.makeScrollView(coordinator: context.coordinator, from: self)
    }

    static func makeScrollView(coordinator: Coordinator, from view: Self) -> NSScrollView {
        let tableView = LibrarySearchTableView()
        let column = NSTableColumn(identifier: Coordinator.columnIdentifier)
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.rowSizeStyle = .custom
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.allowsTypeSelect = false
        tableView.refusesFirstResponder = false
        tableView.focusRingType = .default
        tableView.setAccessibilityLabel("Songs and library actions")
        tableView.backgroundColor = .clear
        tableView.style = .inset
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        tableView.target = coordinator
        tableView.doubleAction = #selector(Coordinator.performClickedRowAction(_:))
        tableView.defaultActionHandler = { [weak coordinator] in coordinator?.activateSelection() ?? false }
        tableView.cancelActionHandler = { [weak coordinator] in coordinator?.closeSearch() }
        tableView.navigationHandler = { [weak coordinator] command in
            coordinator?.perform(command, sender: nil) ?? false
        }
        tableView.menuProvider = { [weak coordinator] row in coordinator?.contextMenu(for: row) }
        tableView.willRemoveHandler = { [weak coordinator, weak tableView] in
            guard let tableView else { return }
            coordinator?.prepareForRemoval(tableView)
        }
        let menu = NSMenu()
        menu.delegate = coordinator
        menu.autoenablesItems = false
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        coordinator.tableView = tableView
        coordinator.update(from: view, forceReload: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        if let tableView = coordinator.tableView { coordinator.prepareForRemoval(tableView) }
        coordinator.retire()
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        static let columnIdentifier = NSUserInterfaceItemIdentifier("LibrarySearchColumn")
        private static let sectionCellIdentifier = NSUserInterfaceItemIdentifier("LibrarySearchSectionCell")
        private static let itemCellIdentifier = NSUserInterfaceItemIdentifier("LibrarySearchItemCell")
        static let rowViewIdentifier = NSUserInterfaceItemIdentifier("LibrarySearchRowView")

        fileprivate weak var tableView: NSTableView?

        private var rows: [Row] = []
        private var isSynchronizingSelection = false
        private weak var commandRouter: LibrarySearchCommandRouter?
        private var selectedEntry: Binding<LibrarySearchEntryID?> = .constant(nil)
        private var onRunAction: (LibraryCommandPaletteAction) -> Void = { _ in }
        private var onOpenResult: (URL) -> Void = { _ in }
        private var onClose: () -> Void = {}
        private var onAddResultToPlaylist: (URL) -> Void = { _ in }

        func update(from view: LibrarySearchResultsListView, forceReload: Bool = false) {
            guard tableView != nil else { return }
            registerCommandRouter(view.commandRouter)
            selectedEntry = view.$selectedEntry
            onRunAction = view.onRunAction
            onOpenResult = view.onOpenResult
            onClose = view.onClose
            onAddResultToPlaylist = view.onAddResultToPlaylist

            let newRows = Self.makeRows(
                actions: view.actions,
                results: view.results,
                displayName: view.displayName
            )
            let contentChanged = forceReload || rows != newRows
            if contentChanged {
                rows = newRows
                isSynchronizingSelection = true
                tableView?.reloadData()
                isSynchronizingSelection = false
            }
            synchronizeSelection(to: view.selectedEntry, reveal: contentChanged)
        }

        private var hasLiveTable: Bool {
            guard commandRouter?.isAttached == true,
                  let tableView, tableView.window != nil else { return false }
            return tableView.dataSource === self && tableView.delegate === self
        }

        fileprivate func retire() {
            unregisterCommandRouter()
            if let nativeTable = tableView as? LibrarySearchTableView {
                nativeTable.defaultActionHandler = nil
                nativeTable.cancelActionHandler = nil
                nativeTable.navigationHandler = nil
                nativeTable.menuProvider = nil
                nativeTable.willRemoveHandler = nil
            }
            tableView?.menu?.delegate = nil
            tableView?.menu = nil
            tableView?.delegate = nil
            tableView?.dataSource = nil
            tableView?.target = nil
            tableView?.doubleAction = nil
            tableView = nil
            rows.removeAll()
            selectedEntry = .constant(nil)
            onRunAction = { _ in }
            onOpenResult = { _ in }
            onAddResultToPlaylist = { _ in }
            onClose = {}
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            rows.indices.contains(row) && rows[row].isSelectable
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            rows.indices.contains(row) && rows[row].role == .section
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            if let reused = tableView.makeView(
                withIdentifier: Self.rowViewIdentifier,
                owner: self
            ) as? NSTableRowView {
                return reused
            }

            let rowView = NSTableRowView()
            rowView.identifier = Self.rowViewIdentifier
            return rowView
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 36 }
            switch rows[row].content {
            case .section:
                return 24
            case .action:
                return 48
            case .result(_, _, let snippet):
                return snippet.isEmpty ? 48 : 84
            }
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard rows.indices.contains(row) else { return nil }
            switch rows[row].content {
            case .section(let title, let count):
                let cell = sectionCell(in: tableView)
                cell.configure(title: title, count: count)
                return cell
            case .action(let action):
                let cell = itemCell(in: tableView)
                cell.configure(
                    title: action.title,
                    subtitle: action.subtitle,
                    systemImage: action.systemImage,
                    showsPlaylistButton: false,
                    onActivate: { [weak self] in
                        self?.activate(.action(action)) ?? false
                    },
                    onAddToPlaylist: nil
                )
                return cell
            case .result(let url, let title, let snippet):
                let cell = itemCell(in: tableView)
                cell.configure(
                    title: title,
                    subtitle: snippet,
                    location: url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent,
                    systemImage: Self.fileSymbol(for: url),
                    showsPlaylistButton: true,
                    onActivate: { [weak self] in
                        self?.activate(.result(url)) ?? false
                    },
                    onAddToPlaylist: { [weak self] in
                        self?.addToPlaylist(.result(url)) ?? false
                    }
                )
                return cell
            }
        }

        private static func fileSymbol(for url: URL) -> String {
            switch LibraryFileKind(url: url) {
            case .txt: "doc.text"
            case .pdf: "doc.richtext"
            case .image: "photo"
            case .video: "film"
            case .audio: "music.note"
            case .unsupported: "doc"
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizingSelection, let tableView else { return }
            let entry = rows.indices.contains(tableView.selectedRow) ? rows[tableView.selectedRow].entryID : nil
            if selectedEntry.wrappedValue != entry { selectedEntry.wrappedValue = entry }
        }

        fileprivate func registerCommandRouter(_ router: LibrarySearchCommandRouter) {
            if commandRouter !== router {
                unregisterCommandRouter()
                commandRouter = router
            }
            router.resultsCoordinator = self
            router.updateFocusCompanion()
        }

        fileprivate func unregisterCommandRouter() {
            if commandRouter?.resultsCoordinator === self {
                commandRouter?.resultsCoordinator = nil
            }
            commandRouter = nil
        }

        @objc fileprivate func performClickedRowAction(_ sender: NSTableView) {
            guard !clickIsInsideEmbeddedControl(in: sender) else { return }
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            performDefaultAction(for: rows[row])
        }

        private func clickIsInsideEmbeddedControl(in tableView: NSTableView) -> Bool {
            guard let event = NSApp.currentEvent,
                  event.window === tableView.window
            else {
                return false
            }

            let point = tableView.convert(event.locationInWindow, from: nil)
            var hitView = tableView.hitTest(point)
            while let view = hitView, view !== tableView {
                if view is LibrarySearchEmbeddedButton {
                    return true
                }
                hitView = view.superview
            }
            return false
        }

        private func performDefaultAction(for row: Row) {
            guard let entry = row.entryID else { return }
            _ = activate(entry)
        }

        @discardableResult
        private func activate(_ entry: LibrarySearchEntryID) -> Bool {
            guard hasLiveTable, rows.contains(where: { $0.entryID == entry }) else { return false }
            selectedEntry.wrappedValue = entry
            switch entry {
            case .action(let action): onRunAction(action)
            case .result(let url): onOpenResult(url)
            }
            return true
        }

        fileprivate func activateSelection() -> Bool {
            guard let entry = selectedEntry.wrappedValue else { return false }
            return activate(entry)
        }

        fileprivate func closeSearch() {
            guard hasLiveTable else { return }
            onClose()
        }

        fileprivate func prepareForRemoval(_ tableView: NSTableView) {
            commandRouter?.prepareForResultsRemoval(tableView)
        }

        @discardableResult
        private func addToPlaylist(_ entry: LibrarySearchEntryID) -> Bool {
            guard hasLiveTable, case .result(let url) = entry,
                  rows.contains(where: { $0.entryID == entry }) else { return false }
            selectedEntry.wrappedValue = entry
            onAddResultToPlaylist(url)
            return true
        }

        fileprivate func addSelectionToPlaylist() -> Bool {
            guard let entry = selectedEntry.wrappedValue else { return false }
            return addToPlaylist(entry)
        }

        fileprivate func contextMenu(for row: Int) -> NSMenu? {
            guard let tableView, rows.indices.contains(row), rows[row].isSelectable else { return nil }
            selectEntryRow(row, in: tableView)
            guard let menu = tableView.menu else { return nil }
            menuNeedsUpdate(menu)
            return menu
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard hasLiveTable, let entry = selectedEntry.wrappedValue,
                  rows.contains(where: { $0.entryID == entry }) else { return }
            let title: String
            switch entry {
            case .action(let action): title = action.title
            case .result: title = "Preview"
            }
            let activateItem = NSMenuItem(title: title, action: #selector(activateMenuEntry(_:)), keyEquivalent: "")
            activateItem.target = self
            activateItem.representedObject = entry
            menu.addItem(activateItem)
            if case .result = entry {
                let addItem = NSMenuItem(title: "Add to Playlist", action: #selector(addMenuEntryToPlaylist(_:)), keyEquivalent: "")
                addItem.target = self
                addItem.representedObject = entry
                menu.addItem(addItem)
            }
        }

        @objc private func activateMenuEntry(_ sender: NSMenuItem) {
            guard let entry = sender.representedObject as? LibrarySearchEntryID else { return }
            _ = activate(entry)
        }

        @objc private func addMenuEntryToPlaylist(_ sender: NSMenuItem) {
            guard let entry = sender.representedObject as? LibrarySearchEntryID else { return }
            addToPlaylist(entry)
        }

        @discardableResult
        fileprivate func perform(
            _ command: LibrarySearchNavigationCommand,
            sender: Any?
        ) -> Bool {
            guard hasLiveTable, let tableView else { return false }

            switch command.operation {
            case .moveSelection(let direction):
                return moveSelection(direction: direction, in: tableView)
            case .scrollPage(let up):
                return scrollPage(up: up, sender: sender, tableView: tableView)
            case .scrollToBoundary(let beginning):
                return tableView.tryToPerform(
                    beginning
                        ? #selector(NSResponder.scrollToBeginningOfDocument(_:))
                        : #selector(NSResponder.scrollToEndOfDocument(_:)),
                    with: sender
                )
            }
        }

        private func moveSelection(direction: Int, in tableView: NSTableView) -> Bool {
            let selectableRows = rows.indices.filter { rows[$0].isSelectable }
            let currentRow = selectedEntry.wrappedValue.flatMap { entry in rows.firstIndex { $0.entryID == entry } }
            guard let targetRow = LibrarySearchEntryNavigator.targetRow(
                selectableRows: selectableRows, currentRow: currentRow, direction: direction
            ) else { return false }
            selectEntryRow(targetRow, in: tableView)
            return true
        }

        private func scrollPage(
            up: Bool,
            sender: Any?,
            tableView: NSTableView
        ) -> Bool {
            guard let scrollView = tableView.enclosingScrollView else { return false }
            let selector = up
                ? #selector(NSResponder.pageUp(_:))
                : #selector(NSResponder.pageDown(_:))
            return scrollView.tryToPerform(selector, with: sender)
        }

        private func selectEntryRow(_ row: Int, in tableView: NSTableView) {
            guard rows.indices.contains(row), let entry = rows[row].entryID else { return }
            isSynchronizingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            isSynchronizingSelection = false
            if selectedEntry.wrappedValue != entry { selectedEntry.wrappedValue = entry }
        }

        private func synchronizeSelection(to entry: LibrarySearchEntryID?, reveal: Bool) {
            guard let tableView else { return }
            let targetRow = entry.flatMap { entry in rows.firstIndex { $0.entryID == entry } }
            if tableView.selectedRow == (targetRow ?? -1) {
                if reveal, let targetRow { tableView.scrollRowToVisible(targetRow) }
                return
            }
            isSynchronizingSelection = true
            if let targetRow {
                tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
                if reveal { tableView.scrollRowToVisible(targetRow) }
            } else {
                tableView.deselectAll(nil)
            }
            isSynchronizingSelection = false
        }

        private func sectionCell(in tableView: NSTableView) -> LibrarySearchSectionCellView {
            if let reused = tableView.makeView(
                withIdentifier: Self.sectionCellIdentifier,
                owner: self
            ) as? LibrarySearchSectionCellView {
                return reused
            }
            let cell = LibrarySearchSectionCellView()
            cell.identifier = Self.sectionCellIdentifier
            return cell
        }

        private func itemCell(in tableView: NSTableView) -> LibrarySearchItemCellView {
            if let reused = tableView.makeView(
                withIdentifier: Self.itemCellIdentifier,
                owner: self
            ) as? LibrarySearchItemCellView {
                return reused
            }
            let cell = LibrarySearchItemCellView()
            cell.identifier = Self.itemCellIdentifier
            return cell
        }

        private static func makeRows(
            actions: [LibraryCommandPaletteAction],
            results: [LibraryTextSearchIndex.SearchResult],
            displayName: (URL) -> String
        ) -> [Row] {
            var rows: [Row] = []
            if !actions.isEmpty {
                rows.append(Row(id: .section("actions"), content: .section("Actions", actions.count)))
                rows.append(contentsOf: actions.map { action in
                    Row(id: .entry(.action(action)), content: .action(action))
                })
            }
            if !results.isEmpty {
                rows.append(Row(id: .section("files"), content: .section("Library Files", results.count)))
                rows.append(contentsOf: results.map { result in
                    let url = result.url.standardizedFileURL
                    return Row(
                        id: .entry(.result(url)),
                        content: .result(url, displayName(url), result.snippet)
                    )
                })
            }
            return rows
        }
    }
}

nonisolated enum LibrarySearchNavigationCommand: Equatable {
    case previous
    case next
    case pageUp
    case pageDown
    case scrollToBeginning
    case scrollToEnd

    var operation: LibrarySearchNavigationOperation {
        switch self {
        case .previous:
            return .moveSelection(direction: -1)
        case .next:
            return .moveSelection(direction: 1)
        case .pageUp:
            return .scrollPage(up: true)
        case .pageDown:
            return .scrollPage(up: false)
        case .scrollToBeginning:
            return .scrollToBoundary(beginning: true)
        case .scrollToEnd:
            return .scrollToBoundary(beginning: false)
        }
    }

    init?(selector: Selector) {
        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            self = .previous
        case #selector(NSResponder.moveDown(_:)):
            self = .next
        case #selector(NSResponder.pageUp(_:)),
             #selector(NSResponder.scrollPageUp(_:)):
            self = .pageUp
        case #selector(NSResponder.pageDown(_:)),
             #selector(NSResponder.scrollPageDown(_:)):
            self = .pageDown
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)):
            self = .scrollToBeginning
        case #selector(NSResponder.scrollToEndOfDocument(_:)):
            self = .scrollToEnd
        default:
            return nil
        }
    }
}

nonisolated enum LibrarySearchNavigationOperation: Equatable {
    case moveSelection(direction: Int)
    case scrollPage(up: Bool)
    case scrollToBoundary(beginning: Bool)
}

nonisolated enum LibrarySearchRowRole: Equatable {
    case section
    case action
    case result

    var isSelectable: Bool {
        self != .section
    }
}

nonisolated enum LibrarySearchEntryNavigator {
    static func targetRow(
        selectableRows: [Int],
        currentRow: Int?,
        direction: Int
    ) -> Int? {
        guard let firstRow = selectableRows.first,
              let lastRow = selectableRows.last
        else {
            return nil
        }

        guard let currentRow,
              let currentIndex = selectableRows.firstIndex(of: currentRow)
        else {
            return direction < 0 ? lastRow : firstRow
        }

        let targetIndex = min(
            max(currentIndex + (direction < 0 ? -1 : 1), selectableRows.startIndex),
            selectableRows.index(before: selectableRows.endIndex)
        )
        return selectableRows[targetIndex]
    }
}

private struct Row: Hashable {
    enum ID: Hashable {
        case section(String)
        case entry(LibrarySearchEntryID)
    }

    enum Content: Hashable {
        case section(String, Int)
        case action(LibraryCommandPaletteAction)
        case result(URL, String, String)
    }

    let id: ID
    let content: Content

    var role: LibrarySearchRowRole {
        switch content {
        case .section:
            return .section
        case .action:
            return .action
        case .result:
            return .result
        }
    }

    var entryID: LibrarySearchEntryID? {
        guard case .entry(let entry) = id else { return nil }
        return entry
    }

    var isSelectable: Bool { role.isSelectable }
}

final class LibrarySearchTableView: NSTableView {
    private var needsSelectionRevealAfterLayout = false

    var defaultActionHandler: (() -> Bool)?
    var cancelActionHandler: (() -> Void)?
    var navigationHandler: ((LibrarySearchNavigationCommand) -> Bool)?
    var menuProvider: ((Int) -> NSMenu?)?
    var willRemoveHandler: (() -> Void)?

    override func scrollRowToVisible(_ row: Int) {
        // NSViewRepresentable creates the table before its viewport has a size.
        // Scrolling then leaves the first result underneath its floating heading.
        guard !visibleRect.isEmpty else {
            needsSelectionRevealAfterLayout = true
            needsLayout = true
            return
        }
        needsSelectionRevealAfterLayout = false
        // Reloading results also invalidates the floating heading's geometry.
        // Finish that layout before AppKit computes the selected row's scroll.
        layoutSubtreeIfNeeded()
        super.scrollRowToVisible(row)
    }

    override func layout() {
        super.layout()
        guard needsSelectionRevealAfterLayout, !visibleRect.isEmpty else { return }
        needsSelectionRevealAfterLayout = false
        // Selection may have changed or disappeared while waiting for a viewport.
        if selectedRow >= 0 { super.scrollRowToVisible(selectedRow) }
    }

    // These selectors are declared by the responder protocol but do not have
    // superclass implementations. Empty or retired lists simply cannot move.
    override func moveUp(_ sender: Any?) {
        _ = navigationHandler?(.previous)
    }

    override func moveDown(_ sender: Any?) {
        _ = navigationHandler?(.next)
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if (event.keyCode == 36 || event.keyCode == 76), defaultActionHandler?() == true { return }
            if event.keyCode == 53, let cancelActionHandler {
                cancelActionHandler()
                return
            }
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?(row(at: convert(event.locationInWindow, from: nil)))
    }

    override func removeFromSuperview() {
        willRemoveHandler?()
        super.removeFromSuperview()
    }
}

private final class LibrarySearchSectionCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 11, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        textField = titleField
        addSubview(titleField)

        countField.translatesAutoresizingMaskIntoConstraints = false
        countField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countField.textColor = .tertiaryLabelColor
        countField.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(countField)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: countField.leadingAnchor, constant: -6),
            countField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, count: Int) {
        titleField.stringValue = title.uppercased()
        countField.stringValue = String(count)
    }
}

private final class LibrarySearchEmbeddedButton: NSButton {}

private final class LibrarySearchItemCellView: NSTableCellView {
    private let symbolView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let locationField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(wrappingLabelWithString: "")
    private let textStack = NSStackView()
    private let playlistButton = LibrarySearchEmbeddedButton()
    private var onAddToPlaylist: (() -> Bool)?
    private var onActivate: (() -> Bool)?
    private var showsPlaylistButton = false

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet {
            updateColors()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = .controlAccentColor
        symbolView.setAccessibilityHidden(true)
        addSubview(symbolView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        textField = titleField
        titleField.identifier = NSUserInterfaceItemIdentifier("LibrarySearch.ItemTitle")

        locationField.translatesAutoresizingMaskIntoConstraints = false
        locationField.font = .systemFont(ofSize: 11)
        locationField.textColor = .secondaryLabelColor
        locationField.lineBreakMode = .byTruncatingMiddle
        locationField.maximumNumberOfLines = 1
        locationField.identifier = NSUserInterfaceItemIdentifier("LibrarySearch.ItemLocation")

        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.maximumNumberOfLines = 2
        subtitleField.identifier = NSUserInterfaceItemIdentifier("LibrarySearch.ItemSnippet")
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.detachesHiddenViews = true
        for field in [titleField, locationField, subtitleField] {
            field.setContentCompressionResistancePriority(.required, for: .vertical)
            textStack.addArrangedSubview(field)
            field.widthAnchor.constraint(equalTo: textStack.widthAnchor).isActive = true
        }
        addSubview(textStack)

        playlistButton.translatesAutoresizingMaskIntoConstraints = false
        playlistButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "Add to Playlist"
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        )
        playlistButton.imagePosition = .imageOnly
        playlistButton.imageScaling = .scaleProportionallyDown
        playlistButton.isBordered = true
        playlistButton.bezelStyle = .circular
        playlistButton.controlSize = .small
        playlistButton.setButtonType(.momentaryPushIn)
        playlistButton.ignoresMultiClick = true
        playlistButton.refusesFirstResponder = false
        playlistButton.focusRingType = .default
        playlistButton.contentTintColor = .controlAccentColor
        playlistButton.toolTip = "Add to Playlist"
        playlistButton.target = self
        playlistButton.action = #selector(performAddToPlaylist)
        addSubview(playlistButton)

        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            symbolView.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            symbolView.heightAnchor.constraint(equalToConstant: 18),

            textStack.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 9),
            textStack.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            textStack.trailingAnchor.constraint(equalTo: playlistButton.leadingAnchor, constant: -8),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),

            playlistButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            playlistButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playlistButton.widthAnchor.constraint(equalToConstant: 26),
            playlistButton.heightAnchor.constraint(equalToConstant: 26)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        subtitle: String,
        location: String? = nil,
        systemImage: String,
        showsPlaylistButton: Bool,
        onActivate: (() -> Bool)?,
        onAddToPlaylist: (() -> Bool)?
    ) {
        titleField.stringValue = title
        titleField.toolTip = title
        locationField.stringValue = location ?? ""
        locationField.toolTip = location
        locationField.isHidden = location == nil
        subtitleField.stringValue = subtitle
        subtitleField.isHidden = subtitle.isEmpty
        symbolView.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        self.showsPlaylistButton = showsPlaylistButton
        playlistButton.isHidden = !showsPlaylistButton
        playlistButton.setAccessibilityHidden(!showsPlaylistButton)
        playlistButton.setAccessibilityLabel("Add \(title) to Playlist")

        setAccessibilityLabel(title)
        let detail = [location, subtitle.isEmpty ? nil : subtitle].compactMap { $0 }.joined(separator: "\n")
        setAccessibilityHelp(detail.isEmpty ? nil : detail)
        var accessibilityActions = [NSAccessibilityCustomAction(name: showsPlaylistButton ? "Preview" : title,
            target: self, selector: #selector(performAccessibleActivation))]
        if showsPlaylistButton {
            accessibilityActions.append(NSAccessibilityCustomAction(name: "Add to Playlist",
                target: self, selector: #selector(performAccessibleAddToPlaylist)))
        }
        setAccessibilityCustomActions(accessibilityActions)
        self.onActivate = onActivate
        self.onAddToPlaylist = onAddToPlaylist
        updateColors()
    }

    @objc private func performAccessibleActivation() -> Bool {
        onActivate?() ?? false
    }

    @objc private func performAccessibleAddToPlaylist() -> Bool {
        onAddToPlaylist?() ?? false
    }

    @objc private func performAddToPlaylist() {
        _ = onAddToPlaylist?()
    }

    private func updateColors() {
        if backgroundStyle == .emphasized {
            let selectedColor = NSColor.alternateSelectedControlTextColor
            titleField.textColor = selectedColor
            locationField.textColor = selectedColor.withAlphaComponent(0.78)
            subtitleField.textColor = selectedColor.withAlphaComponent(0.78)
            symbolView.contentTintColor = selectedColor.withAlphaComponent(0.84)
            playlistButton.contentTintColor = selectedColor
        } else {
            titleField.textColor = .labelColor
            locationField.textColor = .secondaryLabelColor
            subtitleField.textColor = .secondaryLabelColor
            symbolView.contentTintColor = showsPlaylistButton
                ? .secondaryLabelColor
                : .controlAccentColor
            playlistButton.contentTintColor = .controlAccentColor
        }
    }
}
