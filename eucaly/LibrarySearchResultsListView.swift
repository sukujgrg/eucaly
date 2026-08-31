import AppKit
import SwiftUI

/// AppKit-backed result list for Quick Open. Keeping the scrolling and cell
/// reuse in `NSTableView` prevents large search result sets from rebuilding a
/// SwiftUI row hierarchy for every keystroke.
struct LibrarySearchResultsListView: NSViewRepresentable {
    @Binding var selectedResult: URL?

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
        tableView.focusRingType = .none
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.performClickedRowAction(_:))
        tableView.doubleAction = #selector(Coordinator.performClickedRowAction(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.contentInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)

        context.coordinator.tableView = tableView
        context.coordinator.installNavigationMonitor()
        context.coordinator.update(from: self, forceReload: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.removeNavigationMonitor()
        coordinator.tableView?.delegate = nil
        coordinator.tableView?.dataSource = nil
        coordinator.tableView?.target = nil
        coordinator.tableView?.action = nil
        coordinator.tableView?.doubleAction = nil
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
        private var navigationMonitor: Any?
        private var selectedResult: Binding<URL?> = .constant(nil)
        private var onRunAction: (LibraryCommandPaletteAction) -> Void = { _ in }
        private var onOpenResult: (URL) -> Void = { _ in }
        private var onAddResultToPlaylist: (URL) -> Void = { _ in }

        func update(from view: LibrarySearchResultsListView, forceReload: Bool = false) {
            installNavigationMonitor()
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
                    onAddToPlaylist: { [weak self] in
                        self?.selectedResult.wrappedValue = url
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

        fileprivate func installNavigationMonitor() {
            guard navigationMonitor == nil else { return }
            navigationMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                self?.handleNavigationEvent(event) ?? event
            }
        }

        fileprivate func removeNavigationMonitor() {
            if let navigationMonitor {
                NSEvent.removeMonitor(navigationMonitor)
                self.navigationMonitor = nil
            }
        }

        @objc fileprivate func performClickedRowAction(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard rows.indices.contains(row) else { return }
            performDefaultAction(for: rows[row])
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

        private func handleNavigationEvent(_ event: NSEvent) -> NSEvent? {
            guard let tableView,
                  tableView.window?.isKeyWindow == true,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                  let command = LibrarySearchNavigationCommand(keyCode: event.keyCode)
            else {
                return event
            }

            guard moveSelection(command, in: tableView) else { return event }
            return nil
        }

        @discardableResult
        private func moveSelection(
            _ command: LibrarySearchNavigationCommand,
            in tableView: NSTableView
        ) -> Bool {
            let resultRows = rows.indices.filter { row in
                if case .result = rows[row].content {
                    return true
                }
                return false
            }
            guard !resultRows.isEmpty else { return false }

            let currentRow = currentResultRow(in: tableView, resultRows: resultRows)
            let targetRow: Int
            switch command {
            case .previous:
                targetRow = adjacentResultRow(
                    before: currentRow,
                    in: resultRows,
                    fallback: resultRows.last!
                )
            case .next:
                targetRow = adjacentResultRow(
                    after: currentRow,
                    in: resultRows,
                    fallback: resultRows.first!
                )
            case .pageUp:
                targetRow = pageResultRow(
                    from: currentRow ?? resultRows.last!,
                    direction: -1,
                    in: resultRows,
                    tableView: tableView
                )
            case .pageDown:
                targetRow = pageResultRow(
                    from: currentRow ?? resultRows.first!,
                    direction: 1,
                    in: resultRows,
                    tableView: tableView
                )
            case .first:
                targetRow = resultRows.first!
            case .last:
                targetRow = resultRows.last!
            }

            selectResultRow(targetRow, in: tableView)
            return true
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

        private func adjacentResultRow(
            before currentRow: Int?,
            in resultRows: [Int],
            fallback: Int
        ) -> Int {
            guard let currentRow,
                  let position = resultRows.firstIndex(of: currentRow)
            else {
                return fallback
            }
            return resultRows[max(position - 1, resultRows.startIndex)]
        }

        private func adjacentResultRow(
            after currentRow: Int?,
            in resultRows: [Int],
            fallback: Int
        ) -> Int {
            guard let currentRow,
                  let position = resultRows.firstIndex(of: currentRow)
            else {
                return fallback
            }
            return resultRows[min(position + 1, resultRows.index(before: resultRows.endIndex))]
        }

        private func pageResultRow(
            from currentRow: Int,
            direction: CGFloat,
            in resultRows: [Int],
            tableView: NSTableView
        ) -> Int {
            let currentRect = tableView.rect(ofRow: currentRow)
            let pageDistance = max(
                tableView.visibleRect.height - currentRect.height,
                currentRect.height
            )
            let desiredMidY = currentRect.midY + (direction * pageDistance)
            return resultRows.min { lhs, rhs in
                abs(tableView.rect(ofRow: lhs).midY - desiredMidY)
                    < abs(tableView.rect(ofRow: rhs).midY - desiredMidY)
            } ?? currentRow
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
    case first
    case last

    init?(keyCode: UInt16) {
        switch keyCode {
        case 126:
            self = .previous
        case 125:
            self = .next
        case 116:
            self = .pageUp
        case 121:
            self = .pageDown
        case 115:
            self = .first
        case 119:
            self = .last
        default:
            return nil
        }
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

    var isSelectable: Bool {
        if case .section = content {
            return false
        }
        return true
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

private final class LibrarySearchItemCellView: NSTableCellView {
    private let symbolView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(wrappingLabelWithString: "")
    private let playlistButton = NSButton()
    private var onAddToPlaylist: (() -> Void)?

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
        subtitleField.maximumNumberOfLines = 4
        addSubview(subtitleField)

        playlistButton.translatesAutoresizingMaskIntoConstraints = false
        playlistButton.image = NSImage(
            systemSymbolName: "plus",
            accessibilityDescription: "Add to Playlist"
        )
        playlistButton.imagePosition = .imageOnly
        playlistButton.isBordered = false
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
            playlistButton.heightAnchor.constraint(equalToConstant: 24)
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
        onAddToPlaylist: (() -> Void)?
    ) {
        titleField.stringValue = title
        titleField.toolTip = title
        subtitleField.stringValue = subtitle
        subtitleField.isHidden = subtitle.isEmpty
        symbolView.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil)
        symbolView.contentTintColor = showsPlaylistButton ? .secondaryLabelColor : .controlAccentColor
        playlistButton.isHidden = !showsPlaylistButton
        self.onAddToPlaylist = onAddToPlaylist
    }

    @objc private func performAddToPlaylist() {
        onAddToPlaylist?()
    }
}
