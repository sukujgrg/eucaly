import AppKit

/// Shared Settings list-and-detail chrome for Outputs and Profiles panes.
@MainActor
final class OutputSettingsListDetailChrome {
    struct ListRow: Equatable {
        let id: UUID?
        let title: String
        let detail: String
    }

    let statusLabel = outputSettingsLabel(secondary: true)
    let issueLabel = outputSettingsLabel(secondary: true)
    let table = NSTableView()
    let detailHost = NSView()
    let sidebar = NSStackView()
    private let status = NSStackView()
    private let listScroll = NSScrollView()

    init(tableAccessibilityLabel: String, tableColumnIdentifier: String, rowHeight: CGFloat) {
        table.addTableColumn(NSTableColumn(identifier: .init(tableColumnIdentifier)))
        table.headerView = nil
        table.style = .sourceList
        table.rowHeight = rowHeight
        table.focusRingType = .default
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.allowsEmptySelection = false
        table.setAccessibilityLabel(tableAccessibilityLabel)

        listScroll.hasVerticalScroller = true
        listScroll.autohidesScrollers = true
        listScroll.focusRingType = .default
        listScroll.borderType = .bezelBorder
        listScroll.documentView = table
        listScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true

        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 8
        sidebar.translatesAutoresizingMaskIntoConstraints = false

        status.orientation = .vertical
        status.alignment = .leading
        status.spacing = 5
        status.setHuggingPriority(.required, for: .vertical)
        status.translatesAutoresizingMaskIntoConstraints = false
        issueLabel.textColor = .systemOrange
        for item in [statusLabel, issueLabel] {
            status.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: status.widthAnchor).isActive = true
        }

        detailHost.translatesAutoresizingMaskIntoConstraints = false
    }

    func install(in view: NSView, belowList: [NSView]) {
        for item in [listScroll] + belowList {
            sidebar.addArrangedSubview(item)
            item.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true
        }
        view.addSubview(status)
        view.addSubview(sidebar)
        view.addSubview(detailHost)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            status.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sidebar.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 14),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            sidebar.widthAnchor.constraint(equalToConstant: 280),
            detailHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            detailHost.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            detailHost.topAnchor.constraint(equalTo: sidebar.topAnchor),
            detailHost.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])
    }

    func syncSelection(rows: [ListRow], selectedID: UUID?) {
        if let index = rows.firstIndex(where: { $0.id == selectedID }), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if selectedID == nil {
            table.deselectAll(nil)
        }
    }

    func makeCell(for entry: ListRow, detailLines: Int) -> NSView {
        if entry.id == nil {
            let cell = NSTableCellView()
            let label = outputSettingsLabel(entry.title, secondary: true, heading: true)
            cell.textField = label
            outputSettingsPin(label, to: cell, inset: 6)
            return cell
        }
        let title = outputSettingsLabel(entry.title, heading: true)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        let detail = outputSettingsLabel(entry.detail, secondary: true)
        detail.maximumNumberOfLines = detailLines
        detail.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        for label in [title, detail] {
            label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let cell = NSTableCellView()
        cell.textField = title
        outputSettingsPin(stack, to: cell, inset: 6)
        cell.setAccessibilityLabel(entry.title + ", " + entry.detail)
        cell.toolTip = entry.title + " · " + entry.detail
        return cell
    }

    func showEmptyNotice(_ text: String, replacing notice: inout NSView?) {
        notice?.removeFromSuperview()
        let label = outputSettingsLabel(text, secondary: true)
        notice = label
        label.translatesAutoresizingMaskIntoConstraints = false
        detailHost.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: detailHost.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: detailHost.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: detailHost.topAnchor, constant: 8),
            label.bottomAnchor.constraint(lessThanOrEqualTo: detailHost.bottomAnchor, constant: -8)
        ])
    }
}
