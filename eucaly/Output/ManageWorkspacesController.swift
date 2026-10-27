import AppKit
import AVFoundation
import Combine

/// Native Settings pane. Browsing it never prepares a session or starts output.
@MainActor
final class ManageWorkspacesController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let outputs: OutputCoordinator
    private let workspaces: OutputWorkspaceWindows
    let table = NSTableView()
    let openButton = NSButton(title: "Open", target: nil, action: nil)
    let renameButton = NSButton(title: "Rename…", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    let capacityLabel = outputSettingsLabel(secondary: true)
    let deletionLabel = outputSettingsLabel(secondary: true)
    let messageLabel = outputSettingsLabel(secondary: true)
    private(set) var selectedID: UUID?
    private let renamer: OutputWorkspaceRenamer
    var renameField: NSTextField? { renamer.field }
    private(set) var isPresented = false
    private var reloading = false
    private var reloadTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private struct PlaybackIdentity: Equatable {
        let session: ObjectIdentifier
        let audio: ObjectIdentifier?
        let program: ObjectIdentifier?
    }
    private struct PlaybackObservation { let identity: PlaybackIdentity; let subscriptions: Set<AnyCancellable> }
    private var playbackSubscriptions: [UUID: PlaybackObservation] = [:]
    private struct Row: Equatable { let id: UUID; let name: String; let badge: OutputWorkspaceTabBadge; let outputs: String; let status: String }
    private var rows: [Row] = []

    init(outputs: OutputCoordinator, workspaces: OutputWorkspaceWindows) {
        self.outputs = outputs; self.workspaces = workspaces
        renamer = OutputWorkspaceRenamer(profiles: outputs.profiles)
        super.init(nibName: nil, bundle: nil)
        for publisher in [outputs.objectWillChange, outputs.profiles.objectWillChange, workspaces.objectWillChange,
                          workspaces.tabBadges.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleReload() }.store(in: &subscriptions)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { reloadTask?.cancel() }

    override func loadView() {
        view = NSView()
        for (id, title, width) in [("name", "Workspace", 190.0), ("outputs", "Assigned Outputs", 250.0), ("status", "Status", 200.0)] {
            let column = NSTableColumn(identifier: .init(id)); column.title = title
            column.width = width; column.minWidth = id == "name" ? 120 : 130
            table.addTableColumn(column)
        }
        table.delegate = self; table.dataSource = self; table.style = .inset
        table.rowHeight = 38; table.allowsEmptySelection = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityLabel("Saved workspaces")
        table.target = self; table.doubleAction = #selector(openSelected(_:))
        let list = NSScrollView(); list.documentView = table; list.hasVerticalScroller = true
        list.borderType = .bezelBorder; list.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        for (button, action) in [(openButton, #selector(openSelected(_:))), (renameButton, #selector(renameSelected(_:))), (deleteButton, #selector(deleteSelected(_:)))] {
            button.target = self; button.action = action
        }
        let actions = outputSettingsActionRow([openButton, renameButton, deleteButton])
        messageLabel.textColor = .systemOrange; messageLabel.isHidden = true
        let help = outputSettingsLabel("Switch workspaces in the current window, or use Workspaces → Open in New Window for separate controls. Switching and closing controls keep live output and background audio running. Delete is separate and keeps library files.", secondary: true)
        for label in [capacityLabel, deletionLabel, messageLabel, help] {
            label.maximumNumberOfLines = 2; label.lineBreakMode = .byTruncatingTail
        }
        help.toolTip = help.stringValue
        let content = NSStackView(views: [capacityLabel, list, deletionLabel, messageLabel, actions, help])
        content.orientation = .vertical; content.alignment = .leading; content.spacing = 10
        for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
        outputSettingsPin(content, to: view, inset: 16)
        reload()
    }
    func setPresented(_ value: Bool) {
        isPresented = value
        if value { _ = view; reload() }
        else { reloadTask?.cancel(); reloadTask = nil; playbackSubscriptions.removeAll() }
    }
    private func scheduleReload() {
        guard isPresented, reloadTask == nil else { return }
        reloadTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.reloadTask = nil; self.reload()
        }
    }
    func reload() {
        guard isViewLoaded else { return }
        let records = outputs.profiles.document.workspaces
        let fresh = records.map { record in
            let assigned = outputs.destinations(workspace: record.id)
            let activity = outputs.isRunning(workspace: record.id) ? outputs.tabStatus(workspace: record.id)
                : outputs.isPlaybackRunning(workspace: record.id) ? "Playback running" : assigned.isEmpty ? "No outputs" : "Stopped"
            return Row(id: record.id, name: outputs.managementWorkspaceName(record.id),
                       badge: workspaces.tabBadges.badge(for: record.id), outputs: assigned.isEmpty ? "None" : assigned.map {
                outputs.managementDestinationLabel($0) + ($0.enabled ? "" : " · Disabled")
            }.joined(separator: ", "),
                       status: activity + (workspaces.windows[record.id] != nil ? " · Open" : workspaces.controllers[record.id] != nil ? " · Controls retained" : " · Controls closed"))
        }
        if !fresh.contains(where: { $0.id == selectedID }) { selectedID = fresh.first?.id }
        reloading = true
        if fresh != rows { rows = fresh; table.reloadData() }
        if let index = rows.firstIndex(where: { $0.id == selectedID }) { table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }
        reloading = false
        let limit = OutputWorkspaceRecord.creationLimit
        capacityLabel.stringValue = records.count > limit
            ? "\(records.count) saved workspaces. New workspaces are limited to \(limit); existing workspaces remain available. Remove unused workspaces to create another."
            : records.count == limit ? "\(records.count) of \(limit) workspaces. Delete an unused workspace to create another." : "\(records.count) of \(limit) workspaces."
        capacityLabel.toolTip = capacityLabel.stringValue
        let problem = selectedID.flatMap(outputs.workspaceDeletionProblem)
        deletionLabel.stringValue = problem ?? "This workspace has no assigned outputs or running playback and can be deleted."
        deletionLabel.toolTip = deletionLabel.stringValue
        openButton.isEnabled = selectedID.map { workspaces.canOpen($0) } ?? false
        renameButton.isEnabled = selectedID != nil && outputs.profiles.recoveryNotice == nil
        deleteButton.isEnabled = selectedID != nil && problem == nil
        deleteButton.toolTip = problem ?? "Delete this unused workspace."
        if isPresented {
            let prepared = records.filter { outputs.preparedSession(workspace: $0.id) != nil }
            for id in Array(playbackSubscriptions.keys) where !prepared.contains(where: { $0.id == id }) { playbackSubscriptions[id] = nil }
            for record in prepared where playbackSubscriptions[record.id]?.identity != playbackIdentity(record.id) {
                observePlayback(record.id)
            }
        }
    }
    private func playbackIdentity(_ id: UUID) -> PlaybackIdentity? {
        guard let session = outputs.preparedSession(workspace: id) else { return nil }
        return .init(session: ObjectIdentifier(session), audio: session.programBackgroundAudioPlayer.map(ObjectIdentifier.init),
                     program: outputs.preparedMedia(workspace: id)?.program.map(ObjectIdentifier.init))
    }
    private func observePlayback(_ id: UUID) {
        guard let session = outputs.preparedSession(workspace: id), let identity = playbackIdentity(id) else { return }
        var subscriptions = Set<AnyCancellable>()
        session.objectWillChange.sink { [weak self] _ in self?.scheduleReload() }.store(in: &subscriptions)
        // AVPlayer finishes waiting/pausing asynchronously, after the session's
        // publication. Observe the actual state used by the deletion guard too.
        for player in [session.programBackgroundAudioPlayer, outputs.preparedMedia(workspace: id)?.program].compactMap({ $0 }) {
            player.publisher(for: \.rate, options: [.new]).map { _ in () }
                .merge(with: player.publisher(for: \.timeControlStatus, options: [.new]).map { _ in () })
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in self?.scheduleReload() }.store(in: &subscriptions)
        }
        playbackSubscriptions[id] = .init(identity: identity, subscriptions: subscriptions)
    }
    func selectWorkspace(_ id: UUID) { selectedID = id; messageLabel.isHidden = true; reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = rows[row]
        let text = tableColumn?.identifier.rawValue == "name" ? item.name : tableColumn?.identifier.rawValue == "outputs" ? item.outputs : item.status
        let label = outputSettingsLabel(text)
        label.maximumNumberOfLines = 1; label.lineBreakMode = .byTruncatingTail
        let cell = NSTableCellView(); cell.textField = label
        if tableColumn?.identifier.rawValue == "name" {
            let icon = NSImageView(); icon.image = item.badge.menuImage
            icon.imageScaling = .scaleProportionallyDown; icon.setAccessibilityElement(false)
            icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 14).isActive = true
            cell.imageView = icon
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [icon, label])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
            outputSettingsPin(row, to: cell, inset: 6)
        } else {
            outputSettingsPin(label, to: cell, inset: 6)
        }
        cell.toolTip = text
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, rows.indices.contains(table.selectedRow) else { return }
        selectedID = rows[table.selectedRow].id; messageLabel.isHidden = true; reload()
    }
    @objc private func openSelected(_ sender: Any?) {
        guard let id = selectedID else { return }
        workspaces.open(id)
    }
    @objc private func deleteSelected(_ sender: Any?) {
        guard let id = selectedID else { return }
        let problem = workspaces.deleteWorkspace(id)
        messageLabel.stringValue = problem ?? ""; messageLabel.isHidden = problem == nil
        messageLabel.toolTip = problem
        reload()
    }
    @objc private func renameSelected(_ sender: Any?) {
        guard let id = selectedID, let window = view.window else { return }
        renamer.present(workspaceID: id, on: window) { [weak self] problem in
            guard let self else { return }
            if let problem {
                self.messageLabel.stringValue = problem
                self.messageLabel.isHidden = false
            }
            self.reload()
        }
    }
}
