import AppKit
import Combine
import SwiftUI

/// ViewTheWord's list-and-detail pattern, backed by eucaly's local output model.
@MainActor
final class ManageOutputsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let coordinator: OutputCoordinator
    var store: OutputProfileStore { coordinator.profiles }
    let section = NSSegmentedControl(labels: ["Outputs", "Profiles"], trackingMode: .selectOne, target: nil, action: nil)
    let table = NSTableView()
    let addOutputMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    let addNative = NSMenuItem(title: "Native Monitor Output", action: nil, keyEquivalent: "")
    let addNDI = NSMenuItem(title: "NDI Output", action: nil, keyEquivalent: "")
    let removeOutput = NSButton(title: "−", target: nil, action: nil)
    let makeDefault = NSButton(title: "Make Default", target: nil, action: nil)
    let addProfile = NSButton()
    let removeProfile = NSButton(title: "−", target: nil, action: nil)
    let statusLabel = outputSettingsLabel(secondary: true)
    let issueLabel = outputSettingsLabel(secondary: true)
    private let detailHost = NSView()
    private let profileActions = NSStackView()
    private let outputActions = NSStackView()
    private(set) var selectedID: UUID?
    private var outputSelection: UUID?
    private var profileSelection: UUID?
    private enum DetailKey: Hashable { case output(UUID), profile(UUID), recovery, empty }
    private var detailKey: DetailKey?
    private var child: NSViewController?
    // Keep the two navigation panes mounted. Profiles share one retargetable
    // form rather than retaining a large control tree for every saved profile.
    private var profileForm: OutputProfileEditor?
    // The model bounds destinations to 16. Keep each editor tied to its UUID,
    // rather than retargeting destination callbacks.
    private var destinationForms: [DetailKey: OutputDestinationEditor] = [:]
    private var detailNotice: NSView?
    private struct ListRow: Equatable { let id: UUID?; let title: String; let detail: String }
    private var rows: [ListRow] = []
    private var reloadingTable = false
    private var reloadTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var report = LyricsReadabilityReport()
    private var readabilityHost: NSHostingView<OutputSettingsReadabilityView>?
    private var readabilityInput: OutputSettingsReadabilityInput?
    private(set) var isPresented = false
    private var isSuspended = false
    var profileEditor: OutputProfileEditor? { child as? OutputProfileEditor }
    var destinationEditor: OutputDestinationEditor? { child as? OutputDestinationEditor }
    var profilesMode: Bool { section.selectedSegment == 1 }

    init(coordinator: OutputCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
        for publisher in [coordinator.objectWillChange, coordinator.profiles.objectWillChange,
                          coordinator.displays.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleReload() }.store(in: &subscriptions)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { reloadTask?.cancel() }

    override func loadView() {
        view = NSView()
        section.selectedSegment = 0; section.target = self; section.action = #selector(changeSection(_:))
        table.addTableColumn(NSTableColumn(identifier: .init("outputs")))
        table.headerView = nil; table.style = .sourceList; table.rowHeight = 52
        table.focusRingType = .none
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = self; table.dataSource = self; table.allowsEmptySelection = false
        table.setAccessibilityLabel("Outputs and profiles")
        let list = NSScrollView(); list.hasVerticalScroller = true; list.autohidesScrollers = true
        list.focusRingType = .none
        list.borderType = .bezelBorder; list.documentView = table
        list.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        addNative.target = self; addNative.action = #selector(addNativeOutput(_:))
        addNDI.target = self; addNDI.action = #selector(addNDIOutput(_:))
        let menu = NSMenu(); menu.autoenablesItems = false
        let glyph = NSMenuItem(title: "+", action: nil, keyEquivalent: "")
        glyph.image = NSImage(named: NSImage.addTemplateName)
        menu.addItem(glyph); menu.addItem(addNative); menu.addItem(addNDI)
        addOutputMenu.menu = menu; addOutputMenu.imagePosition = .imageOnly
        addOutputMenu.setAccessibilityLabel("Add Output")
        addOutputMenu.toolTip = "Add a disabled, unassigned output."
        removeOutput.target = self; removeOutput.action = #selector(removeSelectedOutput(_:))
        removeOutput.setAccessibilityLabel("Remove Output")
        makeDefault.target = self; makeDefault.action = #selector(makeSelectedDefault(_:))
        addProfile.image = NSImage(named: NSImage.addTemplateName)
        addProfile.imagePosition = .imageOnly
        addProfile.target = self; addProfile.action = #selector(addSelectedProfile(_:))
        addProfile.setAccessibilityLabel("Add Profile")
        addProfile.toolTip = "Add a profile by copying the selected profile."
        removeProfile.target = self; removeProfile.action = #selector(removeSelectedProfile(_:))
        removeProfile.setAccessibilityLabel("Remove Unused Profile")
        for button in [addOutputMenu, removeOutput, makeDefault, addProfile, removeProfile] {
            button.bezelStyle = .rounded; button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        outputActions.orientation = .horizontal; outputActions.alignment = .centerY; outputActions.spacing = 8
        for action in [addOutputMenu, removeOutput, NSView(), makeDefault] { outputActions.addArrangedSubview(action) }
        profileActions.orientation = .horizontal; profileActions.alignment = .centerY
        profileActions.spacing = 8
        for action in [addProfile, removeProfile, NSView()] { profileActions.addArrangedSubview(action) }
        let sidebar = NSStackView(views: [section, list, outputActions, profileActions])
        sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 8
        for item in sidebar.arrangedSubviews { item.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let status = NSStackView(views: [statusLabel, issueLabel])
        status.orientation = .vertical; status.alignment = .leading; status.spacing = 5
        // Extra window height belongs to the list and detail panes, even when
        // there is no editor contributing a minimum content height.
        status.setHuggingPriority(.required, for: .vertical)
        for item in status.arrangedSubviews { item.widthAnchor.constraint(equalTo: status.widthAnchor).isActive = true }
        status.translatesAutoresizingMaskIntoConstraints = false
        issueLabel.textColor = .systemOrange
        view.addSubview(status); view.addSubview(sidebar)
        detailHost.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(detailHost)
        NSLayoutConstraint.activate([
            status.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            status.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            status.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            sidebar.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            sidebar.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 14),
            sidebar.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            sidebar.widthAnchor.constraint(equalToConstant: 220),
            detailHost.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 16),
            detailHost.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            detailHost.topAnchor.constraint(equalTo: sidebar.topAnchor),
            detailHost.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor)
        ])
        reload()
    }
    // The native Settings window owns visibility, including close and reopen.
    func setPresented(_ value: Bool) {
        isPresented = value
        isSuspended = !value
        if value {
            coordinator.displays.refresh(); reload()
            profileEditor?.render(force: true)
        }
        else {
            reloadTask?.cancel(); reloadTask = nil
            if isViewLoaded { finishEditing() }
        }
    }
    func finishEditing() {
        guard isViewLoaded else { return }
        finishOutputSettingsFieldEditing(in: view)
        profileEditor?.finishEditing()
        destinationEditor?.ndiEditor?.finishEditing()
    }
    func scheduleReload() {
        guard !isSuspended, reloadTask == nil else { return }
        reloadTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.reloadTask = nil; self.reload()
        }
    }
    func reload() {
        guard isViewLoaded else { return }
        let statuses = profilesMode ? [:] : Dictionary(uniqueKeysWithValues: coordinator.destinationStatuses().map { ($0.id, $0.readiness.title) })
        let fresh = profilesMode ? profileRows() : store.document.destinations.map { output in
            ListRow(id: output.id, title: store.destinationLabel(output),
                detail: (output.id == store.document.defaultDestinationID ? "Default · " : "")
                    + store.workspaceName(output.workspaceID) + " · " + (output.ndi == nil ? "Native" : "NDI") + " · " + (statuses[output.id] ?? "Disabled"))
        }
        if selectedID == nil || !fresh.contains(where: { $0.id == selectedID }) {
            finishEditing(); selectedID = fresh.compactMap(\.id).first
        }
        if profilesMode { profileSelection = selectedID } else { outputSelection = selectedID }
        reloadingTable = true
        if fresh != rows { rows = fresh; table.reloadData() }
        if let index = rows.firstIndex(where: { $0.id == selectedID }), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if selectedID == nil { table.deselectAll(nil) }
        reloadingTable = false
        outputActions.isHidden = profilesMode
        profileActions.isHidden = !profilesMode
        addProfile.isEnabled = profilesMode && selectedID.flatMap(store.profile) != nil
            && store.document.profiles.count < 128 && store.recoveryNotice == nil
        let reusable = selectedID.flatMap(store.profile)?.isReusable ?? true
        addProfile.setAccessibilityLabel(reusable ? "Add Profile" : "Save as Reusable Profile")
        addProfile.toolTip = reusable ? "Create a reusable profile by copying the selected profile." : "Save a reusable copy without changing this output’s appearance."
        let removalProblem = selectedID.map(store.profileRemovalProblem) ?? "Select a profile to remove."
        removeProfile.isEnabled = profilesMode && selectedID != nil && removalProblem == nil
        removeProfile.toolTip = removalProblem ?? "Remove this unused profile. Output settings stay unchanged."
        let canAdd = !profilesMode && store.document.destinations.count < 16 && store.recoveryNotice == nil
        addNative.isEnabled = canAdd && store.profile(OutputProfile.audienceID) != nil
        addNDI.isEnabled = canAdd && store.document.profiles.count < 128
        addOutputMenu.isEnabled = canAdd
        removeOutput.isEnabled = !profilesMode && selectedID != nil && store.recoveryNotice == nil
        let isDefault = !profilesMode && selectedID != nil && selectedID == store.document.defaultDestinationID
        makeDefault.title = isDefault ? "Default" : "Make Default"
        makeDefault.isEnabled = !profilesMode && selectedID != nil && !isDefault && store.recoveryNotice == nil
        let key: DetailKey
        if store.recoveryNotice != nil { key = .recovery }
        else if let id = selectedID {
            key = profilesMode ? .profile(id) : .output(id)
        } else { key = .empty }
        if detailKey != key { finishEditing(); buildDetail(key) }
        pruneDestinationForms()
        profileEditor?.render(); destinationEditor?.render()
        renderStatus()
        updateReadability()
    }
    private func profileRows() -> [ListRow] {
        let used = Set(store.document.destinations.map(\.profileID))
        let groups: [(String, [OutputProfile])] = [
            ("Reusable Profiles", store.reusableProfiles),
            ("Output Appearances", store.document.profiles.filter { !$0.isReusable && used.contains($0.id) }),
            ("Unused Appearances", store.document.profiles.filter { !$0.isReusable && !used.contains($0.id) })
        ]
        return groups.flatMap { title, profiles -> [ListRow] in
            guard !profiles.isEmpty else { return [] }
            return [ListRow(id: nil, title: title, detail: "")] + profiles.map { profile in
                let names = store.document.destinations.filter { $0.profileID == profile.id }.map(\.name)
                let detail = names.isEmpty ? "Unused · " + (profile.isReusable ? "Reusable profile" : "Saved output appearance")
                    : "Used by: " + names.joined(separator: ", ")
                return ListRow(id: profile.id, title: profile.name, detail: detail)
            }
        }
    }
    private func renderStatus() {
        let active = store.document.workspaces.filter { coordinator.isRunning(workspace: $0.id) }
        statusLabel.stringValue = active.isEmpty ? "Workspace outputs stopped" : active.map {
            $0.name + ": " + coordinator.tabStatus(workspace: $0.id)
        }.joined(separator: " · ")
        statusLabel.maximumNumberOfLines = 2; statusLabel.toolTip = statusLabel.stringValue
        issueLabel.stringValue = [coordinator.issue, report.isEmpty ? nil : report.message].compactMap { $0 }.joined(separator: "\n")
        issueLabel.isHidden = issueLabel.stringValue.isEmpty
    }
    private func buildDetail(_ key: DetailKey) {
        detailKey = key
        let previous = child
        child = nil
        detailNotice?.removeFromSuperview(); detailNotice = nil
        switch key {
        case .profile(let id):
            let editor: OutputProfileEditor
            if let profileForm { editor = profileForm; editor.selectProfile(id) }
            else {
                editor = OutputProfileEditor(store: store, profileID: id,
                    makeFileAcquisitionGuard: { [weak coordinator] url in
                        coordinator?.makeFileAcquisitionGuard(for: url) ?? { _ in .removed }
                    })
                profileForm = editor
                addChild(editor); outputSettingsPin(editor.view, to: detailHost)
            }
            child = editor
        case .output(let id):
            let editor: OutputDestinationEditor
            if let cached = destinationForms[key] { editor = cached }
            else {
                editor = OutputDestinationEditor(coordinator: coordinator, destinationID: id)
                editor.onEditProfile = { [weak self] id in self?.selectProfile(id) }
                destinationForms[key] = editor
                addChild(editor); outputSettingsPin(editor.view, to: detailHost)
            }
            child = editor
        case .recovery:
            discardForms()
            let form = OutputSettingsForm(frame: .zero)
            form.add(outputSettingsLabel(store.recoveryNotice ?? "", secondary: true))
            form.add(outputSettingsActionRow([NSButton(title: "Recover Settings", target: self, action: #selector(recoverSettings(_:)))]))
            detailNotice = form
            outputSettingsPin(form, to: detailHost)
        case .empty:
            discardForms()
            let label = outputSettingsLabel(profilesMode ? "No native appearance profiles." : "Add an output to get started.", secondary: true)
            detailNotice = label
            label.translatesAutoresizingMaskIntoConstraints = false
            detailHost.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: detailHost.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: detailHost.trailingAnchor, constant: -8),
                label.topAnchor.constraint(equalTo: detailHost.topAnchor, constant: 8),
                label.bottomAnchor.constraint(lessThanOrEqualTo: detailHost.bottomAnchor, constant: -8)
            ])
        }
        if previous !== child {
            previous?.view.isHidden = true
        }
        child?.view.isHidden = false
    }
    private func pruneDestinationForms() {
        let keys = Set(store.document.destinations.map { destination in
            DetailKey.output(destination.id)
        })
        for key in Array(destinationForms.keys) where !keys.contains(key) {
            let form = destinationForms.removeValue(forKey: key)
            form?.view.removeFromSuperview(); form?.removeFromParent()
        }
    }
    private func discardForms() {
        profileForm?.view.removeFromSuperview(); profileForm?.removeFromParent()
        for form in destinationForms.values {
            form.view.removeFromSuperview(); form.removeFromParent()
        }
        profileForm = nil; destinationForms.removeAll()
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].id == nil }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].id != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].id == nil ? 28 : 52 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
        if entry.id == nil {
            let cell = NSTableCellView()
            let label = outputSettingsLabel(entry.title, secondary: true, heading: true)
            cell.textField = label; outputSettingsPin(label, to: cell, inset: 6)
            return cell
        }
        let title = outputSettingsLabel(entry.title, heading: true); title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        let detail = outputSettingsLabel(entry.detail, secondary: true); detail.maximumNumberOfLines = 1
        detail.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [title, detail]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 3
        for label in [title, detail] { label.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        let cell = NSTableCellView(); cell.textField = title
        outputSettingsPin(stack, to: cell, inset: 6)
        cell.setAccessibilityLabel(entry.title + ", " + entry.detail)
        cell.toolTip = entry.title + " · " + entry.detail
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloadingTable, rows.indices.contains(table.selectedRow) else { return }
        guard let id = rows[table.selectedRow].id else { return }
        if selectedID != id { finishEditing(); selectedID = id; reload() }
    }
    func selectDestination(_ id: UUID) { select(id, segment: 0) }
    func selectProfile(_ id: UUID) { select(id, segment: 1) }
    private func select(_ id: UUID, segment: Int) {
        finishEditing(); section.selectedSegment = segment; selectedID = id; reload()
    }
    @objc private func changeSection(_ sender: Any?) {
        finishEditing(); selectedID = profilesMode ? profileSelection : outputSelection; reload()
    }
    @objc private func addNativeOutput(_ sender: Any?) { addOutput(name: "Native Output", profileID: OutputProfile.audienceID) }
    @objc private func addNDIOutput(_ sender: Any?) {
        guard !profilesMode, store.recoveryNotice == nil, store.document.destinations.count < 16,
              store.document.profiles.count < 128 else { return }
        finishEditing()
        var sourceName = "eucaly", number = 2
        while store.document.destinations.contains(where: { $0.ndi?.sourceName.caseInsensitiveCompare(sourceName) == .orderedSame }) {
            sourceName = "eucaly \(number)"; number += 1
        }
        var profile = store.audience; profile.id = UUID(); profile.name = sourceName + " Appearance"
        profile.usesLegacySizing = false; profile.background = OutputBackground(); profile.background.colour = .chromaGreen
        var output = OutputDestinationConfiguration(name: "NDI Output", profileID: profile.id, monitor: nil,
            enabled: false, workspaceID: coordinator.focusedWorkspaceID)
        output.ndi = NDIOutputSettings(sourceName: sourceName); profile.customizedForDestinationID = output.id
        store.edit { $0.profiles.append(profile); $0.destinations.append(output) }
        selectDestination(output.id)
    }
    @objc private func addSelectedProfile(_ sender: Any?) {
        guard profilesMode, store.recoveryNotice == nil, let id = selectedID else { return }
        finishEditing()
        guard var profile = store.profile(id), store.document.profiles.count < 128 else { return }
        profile.id = UUID(); profile.customizedForDestinationID = nil
        // Leave room for the suffix even when the source name fills the limit.
        while (profile.name + " Copy").utf8.count > 160 { profile.name.removeLast() }
        profile.name += " Copy"
        store.edit { $0.profiles.append(profile) }
        selectProfile(profile.id)
        table.scrollRowToVisible(table.selectedRow)
    }
    private func addOutput(name: String, profileID: UUID) {
        guard !profilesMode, store.recoveryNotice == nil, store.profile(profileID) != nil, store.document.destinations.count < 16 else { return }
        finishEditing()
        let output = OutputDestinationConfiguration(name: name, profileID: profileID, monitor: nil, enabled: false, workspaceID: coordinator.focusedWorkspaceID)

        store.edit { $0.destinations.append(output) }; selectDestination(output.id)
    }
    @objc private func removeSelectedOutput(_ sender: Any?) {
        guard !profilesMode, store.recoveryNotice == nil, let id = selectedID else { return }
        finishEditing(); store.edit { $0.destinations.removeAll { $0.id == id } }; reload()
    }
    @objc private func removeSelectedProfile(_ sender: Any?) {
        guard profilesMode, let id = selectedID else { return }
        finishEditing()
        if store.removeProfile(id) { selectedID = nil }
        reload()
    }
    @objc private func makeSelectedDefault(_ sender: Any?) {
        guard !profilesMode, let id = selectedID else { return }
        finishEditing(); store.setDefaultDestination(id); reload()
    }
    @objc private func recoverSettings(_ sender: Any?) { store.recover(); reload() }

    // Preserve the existing SwiftUI font-metric probes for all assigned profiles,
    // independently of which native editor is selected. They never render output.
    private func updateReadability() {
        let input = OutputSettingsReadabilityInput(coordinator: coordinator)
        guard readabilityInput != input else { return }
        readabilityInput = input
        let root = OutputSettingsReadabilityView(input: input) { [weak self] report in
                guard let self, self.readabilityInput == input, self.report != report else { return }
                self.report = report; self.renderStatus()
            }
        if let readabilityHost { readabilityHost.rootView = root }
        else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []; host.translatesAutoresizingMaskIntoConstraints = false
            host.setAccessibilityHidden(true); view.addSubview(host)
            NSLayoutConstraint.activate([host.widthAnchor.constraint(equalToConstant: 0), host.heightAnchor.constraint(equalToConstant: 0),
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.topAnchor.constraint(equalTo: view.topAnchor)])
            readabilityHost = host
        }
    }
}

/// Selection and transport status are not measurement inputs. Resolve output
/// geometry once, and only update the SwiftUI probes when their inputs change.
private struct OutputSettingsReadabilityInput: Equatable {
    struct Assignment: Equatable, Identifiable {
        let id: UUID
        let profile: OutputProfile
        let size: CGSize
        let current: OutputTextContent
        let next: OutputTextContent?
        let visible: Bool
        let hasMedia: Bool
    }
    let assignments: [Assignment]
    @MainActor init(coordinator: OutputCoordinator) {
        assignments = coordinator.profiles.document.destinations.compactMap { destination in
            guard let profile = coordinator.profile(for: destination.id) else { return nil }
            let size: CGSize
            if let ndi = destination.ndi { size = .init(width: ndi.width, height: ndi.height) }
            else if let target = destination.monitor, let monitor = coordinator.displays.resolve(target) { size = monitor.frame.size }
            else { return nil }
            let snapshot = coordinator.snapshot(for: destination.id)
            return .init(id: destination.id, profile: profile, size: size, current: snapshot.current,
                next: snapshot.next, visible: snapshot.visible,
                hasMedia: snapshot.localMedia.map { OutputContentClassifier.mode(for: $0) == .media } ?? false)
        }
    }
}

private struct OutputSettingsReadabilityView: View {
    let input: OutputSettingsReadabilityInput
    let onReport: (LyricsReadabilityReport) -> Void
    var body: some View {
        ZStack {
            ForEach(input.assignments) { assignment in
                if assignment.visible && !assignment.hasMedia {
                    if assignment.profile.kind == .confidence {
                        OutputConfidenceReadabilityProbe(snapshot: .init(current: assignment.current, next: assignment.next, visible: assignment.visible), profile: assignment.profile, size: assignment.size)
                    } else {
                        OutputReadabilityProbe(content: assignment.current, profile: assignment.profile, size: assignment.size)
                    }
                }
            }
        }.onPreferenceChange(LyricsReadabilityPreferenceKey.self) { report in
            DispatchQueue.main.async { onReport(report) }
        }
    }
}
