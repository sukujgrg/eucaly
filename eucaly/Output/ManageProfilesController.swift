import AppKit
import Combine

/// Settings pane for reusable appearance Profiles. Destinations select a Profile;
/// appearance edits live here, never on Output destination rows.
@MainActor
final class ManageProfilesController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var confirmProfileRemoval: (OutputProfile) -> Bool = { profile in
        let alert = NSAlert()
        alert.messageText = "Remove “" + profile.name + "”?"
        alert.informativeText = "This permanently deletes the unused appearance. Outputs are unchanged."
        alert.addButton(withTitle: "Remove Appearance")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    let coordinator: OutputCoordinator
    var store: OutputProfileStore { coordinator.profiles }
    private let chrome = OutputSettingsListDetailChrome(
        tableAccessibilityLabel: "Profiles",
        tableColumnIdentifier: "profiles",
        rowHeight: 52
    )
    var table: NSTableView { chrome.table }
    var statusLabel: NSTextField { chrome.statusLabel }
    var issueLabel: NSTextField { chrome.issueLabel }
    let addProfile = NSButton()
    let removeProfile = NSButton(title: "−", target: nil, action: nil)
    private let profileActions = NSStackView()
    private(set) var selectedID: UUID?
    private enum DetailKey: Hashable { case profile(UUID), empty, recoveryBlocked }
    private var detailKey: DetailKey?
    private var child: NSViewController?
    private var profileForm: OutputProfileEditor?
    private var detailNotice: NSView?
    private var rows: [OutputSettingsListDetailChrome.ListRow] = []
    private var reloadingTable = false
    private var reloadTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private(set) var isPresented = false
    private var isSuspended = false
    var profileEditor: OutputProfileEditor? { child as? OutputProfileEditor }

    init(coordinator: OutputCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
        for publisher in [coordinator.objectWillChange, coordinator.profiles.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleReload() }.store(in: &subscriptions)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { reloadTask?.cancel() }

    override func loadView() {
        view = NSView()
        chrome.table.delegate = self
        chrome.table.dataSource = self
        addProfile.image = NSImage(named: NSImage.addTemplateName)
        addProfile.imagePosition = .imageOnly
        addProfile.target = self
        addProfile.action = #selector(addSelectedProfile(_:))
        addProfile.setAccessibilityLabel("Duplicate Profile")
        addProfile.toolTip = "Create a reusable profile by copying the selected profile."
        removeProfile.target = self
        removeProfile.action = #selector(removeSelectedProfile(_:))
        removeProfile.setAccessibilityLabel("Remove Unused Profile")
        for button in [addProfile, removeProfile] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        profileActions.orientation = .horizontal
        profileActions.alignment = .centerY
        profileActions.spacing = 8
        for action in [addProfile, removeProfile, NSView()] {
            profileActions.addArrangedSubview(action)
        }
        chrome.install(in: view, belowList: [profileActions])
        reload()
    }

    func setPresented(_ value: Bool) {
        isPresented = value
        isSuspended = !value
        if value {
            reload()
            profileEditor?.render(force: true)
        } else {
            reloadTask?.cancel()
            reloadTask = nil
            if isViewLoaded { finishEditing() }
        }
    }

    func finishEditing() {
        guard isViewLoaded else { return }
        finishOutputSettingsFieldEditing(in: view)
        profileEditor?.finishEditing()
    }

    func scheduleReload() {
        guard !isSuspended, reloadTask == nil else { return }
        reloadTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.reloadTask = nil
            self.reload()
        }
    }

    func reload() {
        guard isViewLoaded else { return }
        let recovering = store.recoveryNotice != nil
        let fresh = recovering ? [] : profileRows()
        if selectedID == nil || !fresh.contains(where: { $0.id == selectedID }) {
            finishEditing()
            selectedID = fresh.compactMap(\.id).first
        }
        reloadingTable = true
        if fresh != rows {
            rows = fresh
            table.reloadData()
        }
        chrome.syncSelection(rows: rows, selectedID: selectedID)
        reloadingTable = false

        addProfile.isEnabled = !recovering && selectedID.flatMap(store.profile) != nil
            && store.document.profiles.count < 128
        addProfile.toolTip = !addProfile.isEnabled && store.document.profiles.count >= 128
            ? "The 128 profile limit has been reached. Remove an unused profile before creating another."
            : "Create a reusable profile by copying the selected profile."
        let removalProblem = selectedID.map(store.profileRemovalProblem) ?? "Select a profile to remove."
        removeProfile.isEnabled = !recovering && selectedID != nil && removalProblem == nil
        removeProfile.toolTip = removalProblem ?? "Remove this unused profile. Output settings stay unchanged."

        let key: DetailKey
        if recovering { key = .recoveryBlocked }
        else if let id = selectedID { key = .profile(id) }
        else { key = .empty }
        if detailKey != key {
            finishEditing()
            buildDetail(key)
        }
        profileEditor?.render()
        renderStatus()
    }

    private func profileRows() -> [OutputSettingsListDetailChrome.ListRow] {
        store.document.profiles.map { profile in
            let names = store.document.destinations.filter { $0.profileID == profile.id }.map(\.name)
            var parts = [profile.kind.displayTitle]
            if profile.isBuiltIn { parts.append("Built-in") }
            parts.append(names.isEmpty ? "Unused" : "Used by: " + names.joined(separator: ", "))
            return .init(id: profile.id, title: profile.name, detail: parts.joined(separator: " · "))
        }
    }

    private func renderStatus() {
        let active = store.document.workspaces.filter { coordinator.isRunning(workspace: $0.id) }
        statusLabel.stringValue = active.isEmpty
            ? "Workspace outputs stopped"
            : active.map { $0.name + ": " + coordinator.tabStatus(workspace: $0.id) }.joined(separator: " · ")
        statusLabel.maximumNumberOfLines = 2
        statusLabel.toolTip = statusLabel.stringValue
        issueLabel.stringValue = ""
        issueLabel.isHidden = true
    }

    private func buildDetail(_ key: DetailKey) {
        detailKey = key
        let previous = child
        child = nil
        detailNotice?.removeFromSuperview()
        detailNotice = nil
        switch key {
        case .profile(let id):
            let editor: OutputProfileEditor
            if let profileForm {
                editor = profileForm
                editor.selectProfile(id)
            } else {
                editor = OutputProfileEditor(store: store, profileID: id,
                    makeFileAcquisitionGuard: { [weak coordinator] url in
                        coordinator?.makeFileAcquisitionGuard(for: url) ?? { _ in .removed }
                    })
                profileForm = editor
                addChild(editor)
                outputSettingsPin(editor.view, to: chrome.detailHost)
            }
            child = editor
        case .recoveryBlocked:
            discardForm()
            chrome.showEmptyNotice(
                "Settings recovery is in progress on the Outputs tab. Recover there before editing profiles.",
                replacing: &detailNotice
            )
        case .empty:
            discardForm()
            chrome.showEmptyNotice("Select a profile.", replacing: &detailNotice)
        }
        if previous !== child {
            previous?.view.isHidden = true
        }
        child?.view.isHidden = false
    }

    private func discardForm() {
        profileForm?.view.removeFromSuperview()
        profileForm?.removeFromParent()
        profileForm = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].id == nil }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].id != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].id == nil ? 28 : 52 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        chrome.makeCell(for: rows[row], detailLines: 1)
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingTable, rows.indices.contains(table.selectedRow) else { return }
        guard let id = rows[table.selectedRow].id else { return }
        if selectedID != id {
            finishEditing()
            selectedID = id
            reload()
        }
    }

    func selectProfile(_ id: UUID) {
        finishEditing()
        selectedID = id
        reload()
    }

    @objc private func addSelectedProfile(_ sender: Any?) {
        guard store.recoveryNotice == nil, let id = selectedID else { return }
        finishEditing()
        guard var profile = store.profile(id), store.document.profiles.count < 128 else { return }
        profile.id = UUID()
        profile.customizedForDestinationID = nil
        while (profile.name + " Copy").utf8.count > 160 { profile.name.removeLast() }
        profile.name += " Copy"
        store.edit { $0.profiles.append(profile) }
        selectProfile(profile.id)
        table.scrollRowToVisible(table.selectedRow)
    }

    @objc private func removeSelectedProfile(_ sender: Any?) {
        guard let id = selectedID, let profile = store.profile(id) else { return }
        finishEditing()
        let ids = profileRows().compactMap(\.id)
        guard let index = ids.firstIndex(of: id) else { return }
        guard confirmProfileRemoval(profile) else { return }
        guard store.removeProfile(id) else {
            reload()
            return
        }
        let remaining = ids.filter { $0 != id }
        selectedID = index < remaining.count ? remaining[index] : remaining.last
        reload()
    }
}
