import AppKit
import SwiftUI

enum SidebarOutlineItemID: Hashable {
    case group(String)
    case library(URL)
    case playlist(UUID)
    case audio(URL)
    case web(URL)
    case window(CGWindowID)
}

enum SidebarOutlineAction: Hashable {
    case addToPlaylist
    case remove
    case revealInFinder
    case copyURL

    var title: String {
        switch self {
        case .addToPlaylist:
            "Add to Playlist"
        case .remove:
            "Remove"
        case .revealInFinder:
            "Reveal in Finder"
        case .copyURL:
            "Copy URL"
        }
    }

    var systemImage: String {
        switch self {
        case .addToPlaylist:
            "plus"
        case .remove:
            "minus"
        case .revealInFinder:
            "folder"
        case .copyURL:
            "doc.on.doc"
        }
    }
}

final class SidebarOutlineItem: NSObject {
    let id: SidebarOutlineItemID
    let title: String
    let isMissing: Bool
    let children: [SidebarOutlineItem]
    let accessoryAction: SidebarOutlineAction?
    let contextActions: [SidebarOutlineAction]

    init(
        id: SidebarOutlineItemID,
        title: String,
        isMissing: Bool = false,
        children: [SidebarOutlineItem] = [],
        accessoryAction: SidebarOutlineAction? = nil,
        contextActions: [SidebarOutlineAction] = []
    ) {
        self.id = id
        self.title = title
        self.isMissing = isMissing
        self.children = children
        self.accessoryAction = accessoryAction
        self.contextActions = contextActions
        super.init()
    }

    var groupID: String? {
        guard case .group(let id) = id else { return nil }
        return id
    }
}

struct SidebarOutlineModel {
    let roots: [SidebarOutlineItem]
    let itemsByID: [SidebarOutlineItemID: SidebarOutlineItem]
    let parentGroupByItemID: [SidebarOutlineItemID: SidebarOutlineItem]
    let groupItemsByID: [String: SidebarOutlineItem]

    init(roots: [SidebarOutlineItem]) {
        self.roots = roots

        var itemsByID: [SidebarOutlineItemID: SidebarOutlineItem] = [:]
        var parentGroupByItemID: [SidebarOutlineItemID: SidebarOutlineItem] = [:]
        var groupItemsByID: [String: SidebarOutlineItem] = [:]

        func index(_ item: SidebarOutlineItem, parent: SidebarOutlineItem?) {
            itemsByID[item.id] = item
            if let parent {
                parentGroupByItemID[item.id] = parent
            }
            if let groupID = item.groupID {
                groupItemsByID[groupID] = item
            }
            for child in item.children {
                index(child, parent: item)
            }
        }

        for root in roots {
            index(root, parent: nil)
        }

        self.itemsByID = itemsByID
        self.parentGroupByItemID = parentGroupByItemID
        self.groupItemsByID = groupItemsByID
    }

    static let empty = SidebarOutlineModel(roots: [])
}

struct SidebarOutlineScrollRequest: Equatable {
    let id: UUID
    let itemID: SidebarOutlineItemID
}

struct SidebarOutlineExpansionCommand: Equatable {
    enum Action {
        case expandAll
        case collapseAll
    }

    let id = UUID()
    let action: Action
}

struct SidebarOutlineExpansionState: Equatable {
    let key: String
    let groupCount: Int
    let expandedGroupCount: Int
    let visibleContentHeight: CGFloat

    static let empty = SidebarOutlineExpansionState(
        key: "",
        groupCount: 0,
        expandedGroupCount: 0,
        visibleContentHeight: 0
    )

    var areAllGroupsCollapsed: Bool {
        groupCount > 0 && expandedGroupCount == 0
    }
}

final class SidebarOutlineExpansionStore {
    var expandedGroupIDs: [String: Set<String>] = [:]
}

struct SidebarOutlineView: NSViewRepresentable {
    let contentRevision: AnyHashable
    let expansionKey: String
    let modelBuilder: () -> SidebarOutlineModel
    let selectedItemIDs: Set<SidebarOutlineItemID>
    let primarySelectedItemID: SidebarOutlineItemID?
    let scrollRequest: SidebarOutlineScrollRequest?
    let expansionCommand: SidebarOutlineExpansionCommand?
    let expansionStore: SidebarOutlineExpansionStore
    let allowsMultipleSelection: Bool
    let allowsEmptySelection: Bool
    let onSelectionChange: (Set<SidebarOutlineItemID>, SidebarOutlineItemID?) -> Bool
    let onAction: (SidebarOutlineItemID, SidebarOutlineAction) -> Void
    let onExpansionStateChange: (SidebarOutlineExpansionState) -> Void

    init(
        contentRevision: AnyHashable,
        expansionKey: String = "",
        modelBuilder: @escaping () -> SidebarOutlineModel,
        selectedItemIDs: Set<SidebarOutlineItemID>,
        primarySelectedItemID: SidebarOutlineItemID?,
        scrollRequest: SidebarOutlineScrollRequest? = nil,
        expansionCommand: SidebarOutlineExpansionCommand? = nil,
        expansionStore: SidebarOutlineExpansionStore,
        allowsMultipleSelection: Bool = false,
        allowsEmptySelection: Bool = false,
        onSelectionChange: @escaping (Set<SidebarOutlineItemID>, SidebarOutlineItemID?) -> Bool,
        onAction: @escaping (SidebarOutlineItemID, SidebarOutlineAction) -> Void = { _, _ in },
        onExpansionStateChange: @escaping (SidebarOutlineExpansionState) -> Void = { _ in }
    ) {
        self.contentRevision = contentRevision
        self.expansionKey = expansionKey
        self.modelBuilder = modelBuilder
        self.selectedItemIDs = selectedItemIDs
        self.primarySelectedItemID = primarySelectedItemID
        self.scrollRequest = scrollRequest
        self.expansionCommand = expansionCommand
        self.expansionStore = expansionStore
        self.allowsMultipleSelection = allowsMultipleSelection
        self.allowsEmptySelection = allowsEmptySelection
        self.onSelectionChange = onSelectionChange
        self.onAction = onAction
        self.onExpansionStateChange = onExpansionStateChange
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(expansionStore: expansionStore)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = ReusableSidebarNSOutlineView()
        let column = NSTableColumn(identifier: Coordinator.columnIdentifier)
        column.resizingMask = .autoresizingMask
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        outlineView.intercellSpacing = .zero
        outlineView.rowSizeStyle = .custom
        outlineView.indentationPerLevel = 8
        outlineView.allowsEmptySelection = true
        outlineView.allowsTypeSelect = true
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
        outlineView.style = .sourceList
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        context.coordinator.outlineView = outlineView
        outlineView.groupToggleHandler = { [weak coordinator = context.coordinator] item in
            coordinator?.toggleGroup(item)
        }
        outlineView.repeatedSelectionHandler = { [weak coordinator = context.coordinator] in
            coordinator?.activateCurrentSelection()
        }
        outlineView.menuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(forRow: row)
        }
        context.coordinator.update(from: self, forceReload: true)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(from: self)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.outlineView?.delegate = nil
        coordinator.outlineView?.dataSource = nil
        coordinator.outlineView?.groupToggleHandler = nil
        coordinator.outlineView?.repeatedSelectionHandler = nil
        coordinator.outlineView?.menuProvider = nil
        coordinator.outlineView = nil
    }

    @MainActor
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        static let columnIdentifier = NSUserInterfaceItemIdentifier("SidebarOutlineColumn")
        private static let rowCellIdentifier = NSUserInterfaceItemIdentifier("SidebarOutlineRowCell")
        private static let groupCellIdentifier = NSUserInterfaceItemIdentifier("SidebarOutlineGroupCell")

        fileprivate weak var outlineView: ReusableSidebarNSOutlineView?

        private var model = SidebarOutlineModel.empty
        private var loadedContentRevision: AnyHashable?
        private var expansionKey = ""
        private let expansionStore: SidebarOutlineExpansionStore
        private var externalSelectedItemIDs: Set<SidebarOutlineItemID> = []
        private var externalPrimarySelectedItemID: SidebarOutlineItemID?
        private var lastScrollRequestID: UUID?
        private var lastExpansionCommandID: UUID?
        private var lastReportedExpansionState: SidebarOutlineExpansionState?
        private var isSynchronizingSelection = false
        private var isProcessingExpansion = false

        private var onSelectionChange: (Set<SidebarOutlineItemID>, SidebarOutlineItemID?) -> Bool = { _, _ in true }
        private var onAction: (SidebarOutlineItemID, SidebarOutlineAction) -> Void = { _, _ in }
        private var onExpansionStateChange: (SidebarOutlineExpansionState) -> Void = { _ in }

        init(expansionStore: SidebarOutlineExpansionStore) {
            self.expansionStore = expansionStore
        }

        func update(from view: SidebarOutlineView, forceReload: Bool = false) {
            onSelectionChange = view.onSelectionChange
            onAction = view.onAction
            onExpansionStateChange = view.onExpansionStateChange
            isSynchronizingSelection = true
            outlineView?.allowsMultipleSelection = view.allowsMultipleSelection
            outlineView?.allowsEmptySelection = view.allowsEmptySelection
            isSynchronizingSelection = false

            let needsReload = forceReload
                || loadedContentRevision != view.contentRevision
                || expansionKey != view.expansionKey

            if needsReload {
                model = view.modelBuilder()
                loadedContentRevision = view.contentRevision
                expansionKey = view.expansionKey
                isSynchronizingSelection = true
                isProcessingExpansion = true
                outlineView?.reloadData()
                restoreExpansionState()
                isProcessingExpansion = false
                isSynchronizingSelection = false
                reportExpansionState()
            }

            applyExpansionCommandIfNeeded(view.expansionCommand)
            synchronizeSelection(
                to: view.selectedItemIDs,
                primary: view.primarySelectedItemID,
                forceReveal: needsReload
            )
            applyScrollRequestIfNeeded(view.scrollRequest, force: needsReload)
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? SidebarOutlineItem)?.children.count ?? model.roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            if let item = item as? SidebarOutlineItem {
                return item.children[index]
            }
            return model.roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            guard let item = item as? SidebarOutlineItem else { return false }
            return !item.children.isEmpty
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            (item as? SidebarOutlineItem)?.groupID == nil
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            typeSelectStringFor tableColumn: NSTableColumn?,
            item: Any
        ) -> String? {
            guard let item = item as? SidebarOutlineItem, item.groupID == nil else { return nil }
            return item.title
        }

        func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
            26
        }

        func outlineView(
            _ outlineView: NSOutlineView,
            viewFor tableColumn: NSTableColumn?,
            item: Any
        ) -> NSView? {
            guard let item = item as? SidebarOutlineItem else { return nil }
            if item.groupID != nil {
                let cell = groupCell(in: outlineView)
                cell.configure(title: item.title, count: item.children.count)
                return cell
            }

            let cell = rowCell(in: outlineView)
            cell.configure(
                title: item.title,
                isMissing: item.isMissing,
                accessoryAction: item.accessoryAction
            ) { [weak self] action in
                self?.onAction(item.id, action)
            }
            return cell
        }

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard !isSynchronizingSelection, !isProcessingExpansion else { return }
            submitCurrentSelection()
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            updateExpansionState(for: notification, isExpanded: true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            updateExpansionState(for: notification, isExpanded: false)
        }

        fileprivate func toggleGroup(_ item: SidebarOutlineItem) {
            guard let outlineView, item.groupID != nil else { return }
            isProcessingExpansion = true
            if outlineView.isItemExpanded(item) {
                outlineView.collapseItem(item)
            } else {
                outlineView.expandItem(item)
            }
            isProcessingExpansion = false
            reportExpansionState()
        }

        fileprivate func activateCurrentSelection() {
            guard !isSynchronizingSelection, !isProcessingExpansion else { return }
            submitCurrentSelection()
        }

        fileprivate func contextMenu(forRow row: Int) -> NSMenu? {
            guard let outlineView,
                  row >= 0,
                  let item = outlineView.item(atRow: row) as? SidebarOutlineItem,
                  !item.contextActions.isEmpty
            else {
                return nil
            }

            let menu = NSMenu()
            for action in item.contextActions {
                let menuItem = NSMenuItem(
                    title: action.title,
                    action: #selector(performContextAction(_:)),
                    keyEquivalent: ""
                )
                menuItem.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
                menuItem.target = self
                menuItem.representedObject = SidebarOutlineMenuAction(itemID: item.id, action: action)
                menu.addItem(menuItem)
            }
            return menu
        }

        @objc private func performContextAction(_ sender: NSMenuItem) {
            guard let representedAction = sender.representedObject as? SidebarOutlineMenuAction else { return }
            onAction(representedAction.itemID, representedAction.action)
        }

        private func rowCell(in outlineView: NSOutlineView) -> SidebarOutlineRowCellView {
            if let reused = outlineView.makeView(
                withIdentifier: Self.rowCellIdentifier,
                owner: self
            ) as? SidebarOutlineRowCellView {
                return reused
            }
            let cell = SidebarOutlineRowCellView()
            cell.identifier = Self.rowCellIdentifier
            return cell
        }

        private func groupCell(in outlineView: NSOutlineView) -> SidebarOutlineGroupCellView {
            if let reused = outlineView.makeView(
                withIdentifier: Self.groupCellIdentifier,
                owner: self
            ) as? SidebarOutlineGroupCellView {
                return reused
            }
            let cell = SidebarOutlineGroupCellView()
            cell.identifier = Self.groupCellIdentifier
            return cell
        }

        private func submitCurrentSelection() {
            guard let outlineView else { return }
            let selectedRows = outlineView.selectedRowIndexes
            let selectedItems = selectedRows.compactMap { row in
                outlineView.item(atRow: row) as? SidebarOutlineItem
            }
            let proposedIDs = Set(selectedItems.map(\.id))
            let primaryID = primarySelectionID(in: outlineView, proposedIDs: proposedIDs)

            if onSelectionChange(proposedIDs, primaryID) {
                externalSelectedItemIDs = proposedIDs
                externalPrimarySelectedItemID = primaryID
            } else {
                synchronizeSelection(
                    to: externalSelectedItemIDs,
                    primary: externalPrimarySelectedItemID,
                    forceReveal: true
                )
            }
        }

        private func primarySelectionID(
            in outlineView: ReusableSidebarNSOutlineView,
            proposedIDs: Set<SidebarOutlineItemID>
        ) -> SidebarOutlineItemID? {
            if let activeInteractionItemID = outlineView.activeInteractionItemID,
               proposedIDs.contains(activeInteractionItemID) {
                return activeInteractionItemID
            }
            if outlineView.selectedRow >= 0,
               let item = outlineView.item(atRow: outlineView.selectedRow) as? SidebarOutlineItem,
               proposedIDs.contains(item.id) {
                return item.id
            }
            if let externalPrimarySelectedItemID,
               proposedIDs.contains(externalPrimarySelectedItemID) {
                return externalPrimarySelectedItemID
            }
            return proposedIDs.first
        }

        private func synchronizeSelection(
            to selectedItemIDs: Set<SidebarOutlineItemID>,
            primary: SidebarOutlineItemID?,
            forceReveal: Bool = false
        ) {
            guard let outlineView else { return }
            let selectionChanged = externalSelectedItemIDs != selectedItemIDs
                || externalPrimarySelectedItemID != primary
            externalSelectedItemIDs = selectedItemIDs
            externalPrimarySelectedItemID = primary

            guard forceReveal || selectionChanged else { return }

            for itemID in selectedItemIDs {
                expandParentIfNeeded(for: itemID)
            }
            let selectedRows = IndexSet(selectedItemIDs.compactMap { itemID in
                guard let item = model.itemsByID[itemID] else { return nil }
                let row = outlineView.row(forItem: item)
                return row >= 0 ? row : nil
            })

            isSynchronizingSelection = true
            outlineView.selectRowIndexes(selectedRows, byExtendingSelection: false)
            if let primary,
               let item = model.itemsByID[primary] {
                let row = outlineView.row(forItem: item)
                if row >= 0 {
                    outlineView.scrollRowToVisible(row)
                }
            }
            isSynchronizingSelection = false
        }

        private func applyScrollRequestIfNeeded(_ request: SidebarOutlineScrollRequest?, force: Bool) {
            guard let request else { return }
            guard force || request.id != lastScrollRequestID else { return }
            lastScrollRequestID = request.id

            guard let outlineView, let item = model.itemsByID[request.itemID] else { return }
            expandParentIfNeeded(for: request.itemID)
            let row = outlineView.row(forItem: item)
            guard row >= 0 else { return }
            outlineView.scrollRowToVisible(row)
        }

        private func expandParentIfNeeded(for itemID: SidebarOutlineItemID) {
            guard let outlineView, let parent = model.parentGroupByItemID[itemID] else { return }
            outlineView.expandItem(parent)
            if let groupID = parent.groupID {
                expansionStore.expandedGroupIDs[expansionKey, default: []].insert(groupID)
            }
        }

        private func applyExpansionCommandIfNeeded(_ command: SidebarOutlineExpansionCommand?) {
            guard let command, command.id != lastExpansionCommandID, let outlineView else { return }
            lastExpansionCommandID = command.id

            isProcessingExpansion = true
            switch command.action {
            case .expandAll:
                expansionStore.expandedGroupIDs[expansionKey] = Set(model.groupItemsByID.keys)
                for item in model.roots where item.groupID != nil {
                    outlineView.expandItem(item)
                }
            case .collapseAll:
                expansionStore.expandedGroupIDs[expansionKey] = []
                for item in model.roots where item.groupID != nil {
                    outlineView.collapseItem(item)
                }
            }
            isProcessingExpansion = false
            reportExpansionState()
        }

        private func restoreExpansionState() {
            guard let outlineView else { return }
            let groupIDs = expansionStore.expandedGroupIDs[expansionKey, default: []]
            for groupID in groupIDs {
                if let item = model.groupItemsByID[groupID] {
                    outlineView.expandItem(item)
                }
            }
        }

        private func updateExpansionState(for notification: Notification, isExpanded: Bool) {
            guard let item = notification.userInfo?["NSObject"] as? SidebarOutlineItem,
                  let groupID = item.groupID
            else {
                return
            }
            if isExpanded {
                expansionStore.expandedGroupIDs[expansionKey, default: []].insert(groupID)
            } else {
                expansionStore.expandedGroupIDs[expansionKey, default: []].remove(groupID)
            }
            if !isProcessingExpansion {
                reportExpansionState()
            }
        }

        private func reportExpansionState() {
            let groupIDs = Set(model.groupItemsByID.keys)
            let expandedCount = expansionStore.expandedGroupIDs[expansionKey, default: []]
                .intersection(groupIDs)
                .count
            let state = SidebarOutlineExpansionState(
                key: expansionKey,
                groupCount: groupIDs.count,
                expandedGroupCount: expandedCount,
                visibleContentHeight: visibleContentHeight
            )
            guard lastReportedExpansionState != state else { return }
            lastReportedExpansionState = state
            DispatchQueue.main.async { [weak self] in
                guard let self, self.expansionKey == state.key else { return }
                self.onExpansionStateChange(state)
            }
        }

        private var visibleContentHeight: CGFloat {
            guard let outlineView, outlineView.numberOfRows > 0 else { return 0 }
            return ceil(outlineView.rect(ofRow: outlineView.numberOfRows - 1).maxY)
        }
    }
}

private final class ReusableSidebarNSOutlineView: NSOutlineView {
    var groupToggleHandler: ((SidebarOutlineItem) -> Void)?
    var repeatedSelectionHandler: (() -> Void)?
    var menuProvider: ((Int) -> NSMenu?)?
    fileprivate var activeInteractionItemID: SidebarOutlineItemID?

    override func mouseDown(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: location)
        if clickedRow >= 0,
           let item = item(atRow: clickedRow) as? SidebarOutlineItem,
           item.groupID != nil {
            window?.makeFirstResponder(self)
            if event.clickCount == 1 {
                groupToggleHandler?(item)
            }
            return
        }

        let previousSelection = selectedRowIndexes
        activeInteractionItemID = clickedRow >= 0
            ? (item(atRow: clickedRow) as? SidebarOutlineItem)?.id
            : nil
        defer { activeInteractionItemID = nil }
        super.mouseDown(with: event)
        if event.clickCount == 1,
           clickedRow >= 0,
           previousSelection == selectedRowIndexes {
            repeatedSelectionHandler?()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let location = convert(event.locationInWindow, from: nil)
        return menuProvider?(row(at: location))
    }
}

private final class SidebarOutlineMenuAction: NSObject {
    let itemID: SidebarOutlineItemID
    let action: SidebarOutlineAction

    init(itemID: SidebarOutlineItemID, action: SidebarOutlineAction) {
        self.itemID = itemID
        self.action = action
    }
}

private final class SidebarOutlineRowCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let accessoryButton = NSButton()
    private var accessoryWidthConstraint: NSLayoutConstraint!
    private var accessoryAction: SidebarOutlineAction?
    private var onAccessoryAction: ((SidebarOutlineAction) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        textField = titleField
        addSubview(titleField)

        accessoryButton.translatesAutoresizingMaskIntoConstraints = false
        accessoryButton.imagePosition = .imageOnly
        accessoryButton.isBordered = false
        accessoryButton.target = self
        accessoryButton.action = #selector(performAccessoryAction)
        addSubview(accessoryButton)

        accessoryWidthConstraint = accessoryButton.widthAnchor.constraint(equalToConstant: 20)
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: accessoryButton.leadingAnchor, constant: -6),
            accessoryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            accessoryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessoryWidthConstraint,
            accessoryButton.heightAnchor.constraint(equalToConstant: 20)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        title: String,
        isMissing: Bool,
        accessoryAction: SidebarOutlineAction?,
        onAccessoryAction: @escaping (SidebarOutlineAction) -> Void
    ) {
        titleField.stringValue = title
        titleField.toolTip = title
        titleField.textColor = isMissing ? .secondaryLabelColor : .labelColor
        self.accessoryAction = accessoryAction
        self.onAccessoryAction = onAccessoryAction

        accessoryButton.isHidden = accessoryAction == nil
        accessoryWidthConstraint.constant = accessoryAction == nil ? 0 : 20
        accessoryButton.image = accessoryAction.flatMap {
            NSImage(systemSymbolName: $0.systemImage, accessibilityDescription: $0.title)
        }
        accessoryButton.toolTip = accessoryAction?.title
        accessoryButton.contentTintColor = accessoryAction == .addToPlaylist
            ? .controlAccentColor
            : .secondaryLabelColor
    }

    @objc private func performAccessoryAction() {
        guard let accessoryAction else { return }
        onAccessoryAction?(accessoryAction)
    }
}

private final class SidebarOutlineGroupCellView: NSTableCellView {
    private let titleField = NSTextField(labelWithString: "")
    private let countField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        textField = titleField
        addSubview(titleField)

        countField.translatesAutoresizingMaskIntoConstraints = false
        countField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countField.textColor = .secondaryLabelColor
        countField.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(countField)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: countField.leadingAnchor, constant: -6),
            countField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            countField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(title: String, count: Int) {
        titleField.stringValue = title
        countField.stringValue = "\(count)"
    }
}
