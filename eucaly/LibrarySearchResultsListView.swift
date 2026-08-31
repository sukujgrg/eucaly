import AppKit
import SwiftUI

@MainActor
final class LibrarySearchCommandRouter {
    fileprivate weak var resultsCoordinator: LibrarySearchResultsListView.Coordinator?
    private weak var searchField: NSSearchField?

    func register(searchField: NSSearchField) {
        self.searchField = searchField
    }

    func unregister(searchField: NSSearchField) {
        if self.searchField === searchField {
            self.searchField = nil
        }
    }

    func perform(_ selector: Selector, sender: Any?) -> Bool {
        guard let command = LibrarySearchNavigationCommand(selector: selector) else {
            return false
        }
        return resultsCoordinator?.perform(command, sender: sender) ?? false
    }

    func restoreSearchFocus() {
        guard let searchField else { return }
        DispatchQueue.main.async { [weak searchField] in
            guard let searchField else { return }
            searchField.window?.makeFirstResponder(searchField)
        }
    }
}

/// AppKit-backed result list for Quick Open. Keeping the scrolling and cell
/// reuse in `NSTableView` prevents large search result sets from rebuilding a
/// SwiftUI row hierarchy for every keystroke.
struct LibrarySearchResultsListView: NSViewRepresentable {
    @Binding var selectedResult: URL?

    let commandRouter: LibrarySearchCommandRouter
    let actions: [LibraryCommandPaletteAction]
    let results: [LibraryTextSearchIndex.SearchResult]
    let displayName: (URL) -> String
    let onRunAction: (LibraryCommandPaletteAction) -> Void
    let onOpenResult: (URL) -> Void
    let onAddResultToPlaylist: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = NSTableView()
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
        tableView.refusesFirstResponder = true
        tableView.focusRingType = .none
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.performClickedRowAction(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        context.coordinator.tableView = tableView
        context.coordinator.update(from: self, forceReload: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.unregisterCommandRouter()
        coordinator.tableView?.delegate = nil
        coordinator.tableView?.dataSource = nil
        coordinator.tableView?.target = nil
        coordinator.tableView?.action = nil
        coordinator.tableView = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        static let columnIdentifier = NSUserInterfaceItemIdentifier("LibrarySearchColumn")
        private static let sectionCellIdentifier = NSUserInterfaceItemIdentifier("LibrarySearchSectionCell")
        private static let itemCellIdentifier = NSUserInterfaceItemIdentifier("LibrarySearchItemCell")

        fileprivate weak var tableView: NSTableView?

        private var rows: [Row] = []
        private var isSynchronizingSelection = false
        private weak var commandRouter: LibrarySearchCommandRouter?
        private var selectedResult: Binding<URL?> = .constant(nil)
        private var onRunAction: (LibraryCommandPaletteAction) -> Void = { _ in }
        private var onOpenResult: (URL) -> Void = { _ in }
        private var onAddResultToPlaylist: (URL) -> Void = { _ in }

        func update(from view: LibrarySearchResultsListView, forceReload: Bool = false) {
            registerCommandRouter(view.commandRouter)
            selectedResult = view.$selectedResult
            onRunAction = view.onRunAction
            onOpenResult = view.onOpenResult
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
            synchronizeSelection(to: view.selectedResult, reveal: contentChanged)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            rows.count
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            rows.indices.contains(row) && rows[row].isSelectable
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            LibrarySearchRowView()
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rows.indices.contains(row) else { return 36 }
            switch rows[row].content {
            case .section:
                return 24
            case .action:
                return 48
            case .result(_, _, let snippet):
                return snippet.isEmpty ? 36 : 72
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
                        self?.onRunAction(action)
                    },
                    onAddToPlaylist: nil
                )
                return cell
            case .result(let url, let title, let snippet):
                let cell = itemCell(in: tableView)
                cell.configure(
                    title: title,
                    subtitle: snippet,
                    systemImage: "doc.text",
                    showsPlaylistButton: true,
                    onActivate: nil,
                    onAddToPlaylist: { [weak self] in
                        self?.onAddResultToPlaylist(url)
                    }
                )
                return cell
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizingSelection,
                  let tableView,
                  rows.indices.contains(tableView.selectedRow),
                  case .result(let url, _, _) = rows[tableView.selectedRow].content
            else {
                return
            }
            selectedResult.wrappedValue = url
        }

        fileprivate func registerCommandRouter(_ router: LibrarySearchCommandRouter) {
            if commandRouter !== router {
                unregisterCommandRouter()
                commandRouter = router
            }
            router.resultsCoordinator = self
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
            switch row.content {
            case .section:
                break
            case .action(let action):
                onRunAction(action)
            case .result(let url, _, _):
                selectedResult.wrappedValue = url
                onOpenResult(url)
            }
        }

        @discardableResult
        fileprivate func perform(
            _ command: LibrarySearchNavigationCommand,
            sender: Any?
        ) -> Bool {
            guard let tableView else { return false }

            switch command.operation {
            case .moveResultSelection(let direction):
                return moveResultSelection(direction: direction, in: tableView)
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

        private func moveResultSelection(
            direction: Int,
            in tableView: NSTableView
        ) -> Bool {
            let resultRows = rows.indices.filter { row in
                rows[row].role == .result
            }
            let currentRow = currentResultRow(in: tableView, resultRows: resultRows)
            guard let targetRow = LibrarySearchResultNavigator.targetRow(
                resultRows: resultRows,
                currentRow: currentRow,
                direction: direction
            ) else { return false }

            selectResultRow(targetRow, in: tableView)
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

        private func currentResultRow(
            in tableView: NSTableView,
            resultRows: [Int]
        ) -> Int? {
            if resultRows.contains(tableView.selectedRow) {
                return tableView.selectedRow
            }
            guard let selectedURL = selectedResult.wrappedValue else { return nil }
            return resultRows.first { row in
                guard case .result(let url, _, _) = rows[row].content else { return false }
                return url == selectedURL
            }
        }

        private func selectResultRow(_ row: Int, in tableView: NSTableView) {
            guard rows.indices.contains(row),
                  case .result(let url, _, _) = rows[row].content
            else {
                return
            }

            isSynchronizingSelection = true
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            isSynchronizingSelection = false
            if selectedResult.wrappedValue != url {
                selectedResult.wrappedValue = url
            }
        }

        private func synchronizeSelection(to url: URL?, reveal: Bool) {
            guard let tableView else { return }
            let targetRow = url.flatMap { selectedURL in
                rows.firstIndex { row in
                    guard case .result(let rowURL, _, _) = row.content else { return false }
                    return rowURL == selectedURL
                }
            }

            let selectedRow = tableView.selectedRow
            guard selectedRow != targetRow else {
                if reveal, let targetRow {
                    tableView.scrollRowToVisible(targetRow)
                }
                return
            }

            isSynchronizingSelection = true
            if let targetRow {
                tableView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
                tableView.scrollRowToVisible(targetRow)
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
                    Row(id: .action(action), content: .action(action))
                })
            }
            if !results.isEmpty {
                rows.append(Row(id: .section("songs"), content: .section("Songs", results.count)))
                rows.append(contentsOf: results.map { result in
                    let url = result.url.standardizedFileURL
                    return Row(
                        id: .result(url),
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
            return .moveResultSelection(direction: -1)
        case .next:
            return .moveResultSelection(direction: 1)
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
    case moveResultSelection(direction: Int)
    case scrollPage(up: Bool)
    case scrollToBoundary(beginning: Bool)
}

nonisolated enum LibrarySearchRowRole: Equatable {
    case section
    case action
    case result

    var isSelectable: Bool {
        self == .result
    }
}

nonisolated enum LibrarySearchResultNavigator {
    static func targetRow(
        resultRows: [Int],
        currentRow: Int?,
        direction: Int
    ) -> Int? {
        guard let firstRow = resultRows.first,
              let lastRow = resultRows.last
        else {
            return nil
        }

        guard let currentRow,
              let currentIndex = resultRows.firstIndex(of: currentRow)
        else {
            return direction < 0 ? lastRow : firstRow
        }

        let targetIndex = min(
            max(currentIndex + (direction < 0 ? -1 : 1), resultRows.startIndex),
            resultRows.index(before: resultRows.endIndex)
        )
        return resultRows[targetIndex]
    }
}

private struct Row: Hashable {
    enum ID: Hashable {
        case section(String)
        case action(LibraryCommandPaletteAction)
        case result(URL)
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

    var isSelectable: Bool {
        role.isSelectable
    }
}

private final class LibrarySearchRowView: NSTableRowView {
    override var isSelected: Bool {
        didSet {
            needsDisplay = true
            updateCellBackgroundStyles()
        }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        isSelected ? .emphasized : .normal
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? NSTableCellView)?.backgroundStyle = interiorBackgroundStyle
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.86).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 4, dy: 1),
            xRadius: 8,
            yRadius: 8
        ).fill()
    }

    private func updateCellBackgroundStyles() {
        for case let cell as NSTableCellView in subviews {
            cell.backgroundStyle = interiorBackgroundStyle
        }
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
    private let subtitleField = NSTextField(wrappingLabelWithString: "")
    private let playlistButton = LibrarySearchEmbeddedButton()
    private let activationButton = LibrarySearchEmbeddedButton()
    private var onAddToPlaylist: (() -> Void)?
    private var onActivate: (() -> Void)?
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
        addSubview(symbolView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        textField = titleField
        addSubview(titleField)

        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.font = .systemFont(ofSize: 11)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.maximumNumberOfLines = 2
        addSubview(subtitleField)

        playlistButton.translatesAutoresizingMaskIntoConstraints = false
        playlistButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "Add to Playlist"
        )
        playlistButton.imagePosition = .imageOnly
        playlistButton.isBordered = false
        playlistButton.refusesFirstResponder = true
        playlistButton.focusRingType = .none
        playlistButton.contentTintColor = .controlAccentColor
        playlistButton.toolTip = "Add to Playlist"
        playlistButton.target = self
        playlistButton.action = #selector(performAddToPlaylist)
        addSubview(playlistButton)

        activationButton.translatesAutoresizingMaskIntoConstraints = false
        activationButton.title = ""
        activationButton.isBordered = false
        activationButton.refusesFirstResponder = true
        activationButton.focusRingType = .none
        activationButton.target = self
        activationButton.action = #selector(performActivation)
        activationButton.isHidden = true
        addSubview(activationButton)

        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            symbolView.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            symbolView.widthAnchor.constraint(equalToConstant: 18),
            symbolView.heightAnchor.constraint(equalToConstant: 18),

            titleField.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 9),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: playlistButton.leadingAnchor, constant: -8),

            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 2),
            subtitleField.trailingAnchor.constraint(lessThanOrEqualTo: playlistButton.leadingAnchor, constant: -8),
            subtitleField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -6),

            playlistButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            playlistButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            playlistButton.widthAnchor.constraint(equalToConstant: 24),
            playlistButton.heightAnchor.constraint(equalToConstant: 24),

            activationButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            activationButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            activationButton.topAnchor.constraint(equalTo: topAnchor),
            activationButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        subtitle: String,
        systemImage: String,
        showsPlaylistButton: Bool,
        onActivate: (() -> Void)?,
        onAddToPlaylist: (() -> Void)?
    ) {
        titleField.stringValue = title
        titleField.toolTip = title
        subtitleField.stringValue = subtitle
        subtitleField.isHidden = subtitle.isEmpty
        symbolView.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        self.showsPlaylistButton = showsPlaylistButton
        playlistButton.isHidden = !showsPlaylistButton
        activationButton.isHidden = onActivate == nil
        activationButton.setAccessibilityLabel(title)
        self.onActivate = onActivate
        self.onAddToPlaylist = onAddToPlaylist
        updateColors()
    }

    @objc private func performActivation() {
        onActivate?()
    }

    @objc private func performAddToPlaylist() {
        onAddToPlaylist?()
    }

    private func updateColors() {
        if backgroundStyle == .emphasized {
            let selectedColor = NSColor.alternateSelectedControlTextColor
            titleField.textColor = selectedColor
            subtitleField.textColor = selectedColor.withAlphaComponent(0.78)
            symbolView.contentTintColor = selectedColor.withAlphaComponent(0.84)
            playlistButton.contentTintColor = selectedColor
        } else {
            titleField.textColor = .labelColor
            subtitleField.textColor = .secondaryLabelColor
            symbolView.contentTintColor = showsPlaylistButton
                ? .secondaryLabelColor
                : .controlAccentColor
            playlistButton.contentTintColor = .controlAccentColor
        }
    }
}
