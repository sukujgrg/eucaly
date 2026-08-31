import AppKit
import SwiftUI

nonisolated enum SidebarOutlineItemID: Hashable, Sendable {
    case group(String)
    case library(URL)
    case playlist(UUID)
    case audio(URL)
    case web(URL)
    case window(CGWindowID)
}

nonisolated enum SidebarOutlineAction: Hashable, Sendable {
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

nonisolated enum SidebarOutlineItemStatus: Hashable, Sendable {
    case stoppedAudio
    case pausedAudio
    case playingAudio

    var systemImage: String {
        switch self {
        case .stoppedAudio:
            "stop.fill"
        case .pausedAudio:
            "pause.fill"
        case .playingAudio:
            "speaker.wave.2.fill"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .stoppedAudio:
            "Stopped background audio"
        case .pausedAudio:
            "Paused background audio"
        case .playingAudio:
            "Playing background audio"
        }
    }
}

nonisolated enum SidebarOutlineActivation: Hashable, Sendable {
    case defaultAction
    case space
}

// The outline snapshot is assembled off-main, then read by AppKit on the main
// actor. Items are immutable after initialization, so crossing that boundary is safe.
nonisolated final class SidebarOutlineItem: NSObject, @unchecked Sendable {
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

nonisolated struct SidebarOutlineModel: Sendable {
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

    func visibleRowCount(expandedGroupIDs: Set<String>) -> Int {
        func countVisibleItems(_ items: [SidebarOutlineItem]) -> Int {
            items.reduce(into: 0) { count, item in
                count += 1
                if let groupID = item.groupID, expandedGroupIDs.contains(groupID) {
                    count += countVisibleItems(item.children)
                }
            }
        }
        return countVisibleItems(roots)
    }
}

nonisolated enum SidebarOutlineNavigationSection: Int, CaseIterable, Hashable, Sendable {
    // Background audio owns an independent selection and intentionally is not
    // part of the primary source-selection traversal.
    case library
    case playlist
    case web
    case window
}

nonisolated enum SidebarOutlineNavigationDirection: Equatable, Sendable {
    case up
    case down
}

@MainActor
final class SidebarOutlineNavigationCoordinator: NSObject {
    private struct Registration {
        let id: UUID
        let hasSelectableRows: () -> Bool
        let focusBoundaryRow: (SidebarOutlineNavigationDirection) -> Bool
    }

    private var registrations: [SidebarOutlineNavigationSection: Registration] = [:]

    func register(
        id: UUID,
        for section: SidebarOutlineNavigationSection,
        hasSelectableRows: @escaping () -> Bool,
        focusBoundaryRow: @escaping (SidebarOutlineNavigationDirection) -> Bool
    ) {
        registrations[section] = Registration(
            id: id,
            hasSelectableRows: hasSelectableRows,
            focusBoundaryRow: focusBoundaryRow
        )
    }

    func unregister(id: UUID, for section: SidebarOutlineNavigationSection) {
        guard registrations[section]?.id == id else { return }
        registrations.removeValue(forKey: section)
    }

    func move(
        from section: SidebarOutlineNavigationSection,
        direction: SidebarOutlineNavigationDirection,
        restoreSourceFocus: () -> Void
    ) -> Bool {
        let orderedSections = SidebarOutlineNavigationSection.allCases
        guard let sourceIndex = orderedSections.firstIndex(of: section) else { return false }
        let candidateSections: [SidebarOutlineNavigationSection]
        switch direction {
        case .down:
            candidateSections = Array(orderedSections.dropFirst(sourceIndex + 1))
        case .up:
            candidateSections = Array(orderedSections.prefix(sourceIndex).reversed())
        }

        for candidateSection in candidateSections {
            guard let registration = registrations[candidateSection] else { continue }
            guard registration.hasSelectableRows() else { continue }
            if registration.focusBoundaryRow(direction) {
                return true
            }
            restoreSourceFocus()
            return true
        }
        return false
    }
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
    let itemStatuses: [SidebarOutlineItemID: SidebarOutlineItemStatus]
    let scrollRequest: SidebarOutlineScrollRequest?
    let expansionCommand: SidebarOutlineExpansionCommand?
    let expansionStore: SidebarOutlineExpansionStore
    let navigationSection: SidebarOutlineNavigationSection?
    let navigationCoordinator: SidebarOutlineNavigationCoordinator?
    let allowsMultipleSelection: Bool
    let allowsEmptySelection: Bool
    let onSelectionChange: (Set<SidebarOutlineItemID>, SidebarOutlineItemID?) -> Bool
    let onActivate: ((SidebarOutlineItemID, SidebarOutlineActivation) -> Void)?
    let onAction: (SidebarOutlineItemID, SidebarOutlineAction) -> Void
    let onExpansionStateChange: (SidebarOutlineExpansionState) -> Void

    init(
        contentRevision: AnyHashable,
        expansionKey: String = "",
        modelBuilder: @escaping () -> SidebarOutlineModel,
        selectedItemIDs: Set<SidebarOutlineItemID>,
        primarySelectedItemID: SidebarOutlineItemID?,
        itemStatuses: [SidebarOutlineItemID: SidebarOutlineItemStatus] = [:],
        scrollRequest: SidebarOutlineScrollRequest? = nil,
        expansionCommand: SidebarOutlineExpansionCommand? = nil,
        expansionStore: SidebarOutlineExpansionStore,
        navigationSection: SidebarOutlineNavigationSection? = nil,
        navigationCoordinator: SidebarOutlineNavigationCoordinator? = nil,
        allowsMultipleSelection: Bool = false,
        allowsEmptySelection: Bool = false,
        onSelectionChange: @escaping (Set<SidebarOutlineItemID>, SidebarOutlineItemID?) -> Bool,
        onActivate: ((SidebarOutlineItemID, SidebarOutlineActivation) -> Void)? = nil,
        onAction: @escaping (SidebarOutlineItemID, SidebarOutlineAction) -> Void = { _, _ in },
        onExpansionStateChange: @escaping (SidebarOutlineExpansionState) -> Void = { _ in }
    ) {
        self.contentRevision = contentRevision
        self.expansionKey = expansionKey
        self.modelBuilder = modelBuilder
        self.selectedItemIDs = selectedItemIDs
        self.primarySelectedItemID = primarySelectedItemID
        self.itemStatuses = itemStatuses
        self.scrollRequest = scrollRequest
        self.expansionCommand = expansionCommand
        self.expansionStore = expansionStore
        self.navigationSection = navigationSection
        self.navigationCoordinator = navigationCoordinator
        self.allowsMultipleSelection = allowsMultipleSelection
        self.allowsEmptySelection = allowsEmptySelection
        self.onSelectionChange = onSelectionChange
        self.onActivate = onActivate
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
        outlineView.allowsEmptySelection = allowsEmptySelection
        outlineView.allowsTypeSelect = true
        outlineView.focusRingType = .none
        outlineView.backgroundColor = .clear
        outlineView.style = .sourceList
        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator
        outlineView.target = context.coordinator
        outlineView.doubleAction = #selector(Coordinator.performDefaultAction(_:))

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
        outlineView.spaceActionHandler = { [weak coordinator = context.coordinator] in
            coordinator?.activateCurrentSelection(.space) ?? false
        }
        outlineView.menuProvider = { [weak coordinator = context.coordinator] row in
            coordinator?.contextMenu(forRow: row)
        }
        outlineView.boundaryMoveHandler = { [weak coordinator = context.coordinator] direction in
            coordinator?.moveAcrossBoundary(direction) ?? false
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
        coordinator.outlineView?.spaceActionHandler = nil
        coordinator.outlineView?.menuProvider = nil
        coordinator.outlineView?.boundaryMoveHandler = nil
        coordinator.outlineView?.target = nil
        coordinator.outlineView?.doubleAction = nil
        coordinator.detachNavigation()
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
        private let navigationRegistrationID = UUID()
        private weak var navigationCoordinator: SidebarOutlineNavigationCoordinator?
        private var navigationSection: SidebarOutlineNavigationSection?
        private var externalSelectedItemIDs: Set<SidebarOutlineItemID> = []
        private var externalPrimarySelectedItemID: SidebarOutlineItemID?
        private var itemStatuses: [SidebarOutlineItemID: SidebarOutlineItemStatus] = [:]
        private var lastScrollRequestID: UUID?
        private var lastExpansionCommandID: UUID?
        private var lastReportedExpansionState: SidebarOutlineExpansionState?
        private var isSynchronizingSelection = false
        private var isProcessingExpansion = false

        private var onSelectionChange: (Set<SidebarOutlineItemID>, SidebarOutlineItemID?) -> Bool = { _, _ in true }
        private var onActivate: ((SidebarOutlineItemID, SidebarOutlineActivation) -> Void)?
        private var onAction: (SidebarOutlineItemID, SidebarOutlineAction) -> Void = { _, _ in }
        private var onExpansionStateChange: (SidebarOutlineExpansionState) -> Void = { _ in }

        init(expansionStore: SidebarOutlineExpansionStore) {
            self.expansionStore = expansionStore
        }

        func update(from view: SidebarOutlineView, forceReload: Bool = false) {
            onSelectionChange = view.onSelectionChange
            onActivate = view.onActivate
            onAction = view.onAction
            onExpansionStateChange = view.onExpansionStateChange
            let itemStatusesChanged = itemStatuses != view.itemStatuses
            itemStatuses = view.itemStatuses
            updateNavigationRegistration(
                coordinator: view.navigationCoordinator,
                section: view.navigationSection
            )
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
            } else if itemStatusesChanged {
                updateVisibleItemStatuses()
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
                status: itemStatuses[item.id],
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

        @objc fileprivate func performDefaultAction(_ sender: NSOutlineView) {
            _ = activateCurrentSelection(.defaultAction)
        }

        @discardableResult
        fileprivate func activateCurrentSelection(_ activation: SidebarOutlineActivation) -> Bool {
            guard !isSynchronizingSelection,
                  !isProcessingExpansion,
                  let outlineView,
                  let onActivate
            else {
                return false
            }

            let row: Int
            if activation == .defaultAction, outlineView.clickedRow >= 0 {
                row = outlineView.clickedRow
            } else {
                row = outlineView.selectedRow
            }
            guard row >= 0,
                  let item = outlineView.item(atRow: row) as? SidebarOutlineItem,
                  item.groupID == nil
            else {
                return false
            }
            onActivate(item.id, activation)
            return true
        }

        fileprivate func moveAcrossBoundary(_ direction: SidebarOutlineNavigationDirection) -> Bool {
            guard isAtSelectionBoundary(for: direction),
                  let navigationCoordinator,
                  let navigationSection
            else {
                return false
            }
            return navigationCoordinator.move(
                from: navigationSection,
                direction: direction,
                restoreSourceFocus: { [weak self] in
                    self?.restoreKeyboardFocus()
                }
            )
        }

        fileprivate func detachNavigation() {
            if let navigationCoordinator, let navigationSection {
                navigationCoordinator.unregister(id: navigationRegistrationID, for: navigationSection)
            }
            navigationCoordinator = nil
            navigationSection = nil
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

        @discardableResult
        private func submitCurrentSelection() -> Bool {
            guard let outlineView else { return false }
            let selectedRows = outlineView.selectedRowIndexes
            let selectedItems = selectedRows.compactMap { row in
                outlineView.item(atRow: row) as? SidebarOutlineItem
            }
            let proposedIDs = Set(selectedItems.map(\.id))
            let primaryID = primarySelectionID(in: outlineView, proposedIDs: proposedIDs)

            if onSelectionChange(proposedIDs, primaryID) {
                externalSelectedItemIDs = proposedIDs
                externalPrimarySelectedItemID = primaryID
                return true
            } else {
                synchronizeSelection(
                    to: externalSelectedItemIDs,
                    primary: externalPrimarySelectedItemID,
                    forceReveal: true
                )
                return false
            }
        }

        private func updateNavigationRegistration(
            coordinator: SidebarOutlineNavigationCoordinator?,
            section: SidebarOutlineNavigationSection?
        ) {
            guard navigationCoordinator !== coordinator || navigationSection != section else { return }
            detachNavigation()
            navigationCoordinator = coordinator
            navigationSection = section
            if let coordinator, let section {
                coordinator.register(
                    id: navigationRegistrationID,
                    for: section,
                    hasSelectableRows: { [weak self] in
                        self?.hasSelectableRows ?? false
                    },
                    focusBoundaryRow: { [weak self] direction in
                        self?.focusBoundaryRow(for: direction) ?? false
                    }
                )
            }
        }

        private func isAtSelectionBoundary(for direction: SidebarOutlineNavigationDirection) -> Bool {
            guard let outlineView else { return false }
            let selectableRows = selectableRowIndexes(in: outlineView)
            guard !selectableRows.isEmpty else { return true }
            guard outlineView.selectedRowIndexes.count == 1 else { return false }
            switch direction {
            case .up:
                return outlineView.selectedRowIndexes.first == selectableRows.first
            case .down:
                return outlineView.selectedRowIndexes.last == selectableRows.last
            }
        }

        private func selectableRowIndexes(in outlineView: NSOutlineView) -> [Int] {
            (0..<outlineView.numberOfRows).filter { row in
                guard let item = outlineView.item(atRow: row) as? SidebarOutlineItem else { return false }
                return item.groupID == nil
            }
        }

        var hasSelectableRows: Bool {
            guard let outlineView else { return false }
            return (0..<outlineView.numberOfRows).contains { row in
                guard let item = outlineView.item(atRow: row) as? SidebarOutlineItem else { return false }
                return item.groupID == nil
            }
        }

        func focusBoundaryRow(for direction: SidebarOutlineNavigationDirection) -> Bool {
            guard let outlineView else { return false }
            let selectableRows = selectableRowIndexes(in: outlineView)
            guard let targetRow = direction == .down ? selectableRows.first : selectableRows.last else {
                return false
            }

            outlineView.window?.makeFirstResponder(outlineView)
            isSynchronizingSelection = true
            outlineView.selectRowIndexes(IndexSet(integer: targetRow), byExtendingSelection: false)
            outlineView.scrollRowToVisible(targetRow)
            isSynchronizingSelection = false
            return submitCurrentSelection()
        }

        func restoreKeyboardFocus() {
            guard let outlineView else { return }
            outlineView.window?.makeFirstResponder(outlineView)
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

        private func updateVisibleItemStatuses() {
            guard let outlineView else { return }
            for row in 0..<outlineView.numberOfRows {
                guard let cell = outlineView.view(
                    atColumn: 0,
                    row: row,
                    makeIfNecessary: false
                ) as? SidebarOutlineRowCellView,
                    let item = outlineView.item(atRow: row) as? SidebarOutlineItem
                else {
                    continue
                }
                cell.configureStatus(itemStatuses[item.id])
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
    var spaceActionHandler: (() -> Bool)?
    var menuProvider: ((Int) -> NSMenu?)?
    var boundaryMoveHandler: ((SidebarOutlineNavigationDirection) -> Bool)?
    fileprivate var activeInteractionItemID: SidebarOutlineItemID?

    override func moveUp(_ sender: Any?) {
        guard boundaryMoveHandler?(.up) != true else { return }
        super.moveUp(sender)
    }

    override func moveDown(_ sender: Any?) {
        guard boundaryMoveHandler?(.down) != true else { return }
        super.moveDown(sender)
    }

    override func keyDown(with event: NSEvent) {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        if event.keyCode == 49,
           event.modifierFlags.intersection(disallowedModifiers).isEmpty,
           spaceActionHandler?() == true {
            return
        }
        super.keyDown(with: event)
    }

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

        activeInteractionItemID = clickedRow >= 0
            ? (item(atRow: clickedRow) as? SidebarOutlineItem)?.id
            : nil
        defer { activeInteractionItemID = nil }
        super.mouseDown(with: event)
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
    private let statusImageView = NSImageView()
    private let accessoryButton = NSButton()
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

        statusImageView.translatesAutoresizingMaskIntoConstraints = false
        statusImageView.imageScaling = .scaleProportionallyDown

        accessoryButton.translatesAutoresizingMaskIntoConstraints = false
        accessoryButton.imagePosition = .imageOnly
        accessoryButton.isBordered = false
        accessoryButton.target = self
        accessoryButton.action = #selector(performAccessoryAction)

        let trailingStack = NSStackView(views: [statusImageView, accessoryButton])
        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 4
        addSubview(trailingStack)

        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: trailingStack.leadingAnchor, constant: -6),
            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusImageView.widthAnchor.constraint(equalToConstant: 16),
            statusImageView.heightAnchor.constraint(equalToConstant: 16),
            accessoryButton.widthAnchor.constraint(equalToConstant: 20),
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
        status: SidebarOutlineItemStatus?,
        accessoryAction: SidebarOutlineAction?,
        onAccessoryAction: @escaping (SidebarOutlineAction) -> Void
    ) {
        titleField.stringValue = title
        titleField.toolTip = title
        titleField.textColor = isMissing ? .secondaryLabelColor : .labelColor
        self.accessoryAction = accessoryAction
        self.onAccessoryAction = onAccessoryAction

        configureStatus(status)

        accessoryButton.isHidden = accessoryAction == nil
        accessoryButton.image = accessoryAction.flatMap {
            NSImage(systemSymbolName: $0.systemImage, accessibilityDescription: $0.title)
        }
        accessoryButton.toolTip = accessoryAction?.title
        accessoryButton.contentTintColor = accessoryAction == .addToPlaylist
            ? .controlAccentColor
            : .secondaryLabelColor
    }

    func configureStatus(_ status: SidebarOutlineItemStatus?) {
        statusImageView.isHidden = status == nil
        statusImageView.image = status.flatMap {
            NSImage(systemSymbolName: $0.systemImage, accessibilityDescription: $0.accessibilityLabel)
        }
        statusImageView.contentTintColor = status == .playingAudio
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
