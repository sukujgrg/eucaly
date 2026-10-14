import AppKit
import Combine
import SwiftUI

/// ViewTheWord's list-and-detail pattern, backed by eucaly's local output model.
@MainActor
final class ManageOutputsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    let coordinator: OutputCoordinator
    let router: AltViewOutputRouter
    var store: OutputProfileStore { coordinator.profiles }
    let section = NSSegmentedControl(labels: ["Outputs", "Profiles"], trackingMode: .selectOne, target: nil, action: nil)
    let table = NSTableView()
    let addNative = NSButton(title: "Add Native", target: nil, action: nil)
    let addAltView = NSButton(title: "Add AltView", target: nil, action: nil)
    let removeOutput = NSButton(title: "Remove Output", target: nil, action: nil)
    let addProfile = NSButton()
    let statusLabel = outputSettingsLabel(secondary: true)
    let issueLabel = outputSettingsLabel(secondary: true)
    private let detailHost = NSView()
    private let profileActions = NSStackView()
    private(set) var selectedID: UUID?
    private var outputSelection: UUID?
    private var profileSelection: UUID?
    private enum DetailKey: Equatable { case output(UUID, native: Bool), profile(UUID), recovery, empty }
    private var detailKey: DetailKey?
    private var child: NSViewController?
    private struct ListRow: Equatable { let id: UUID; let title: String; let detail: String }
    private var rows: [ListRow] = []
    private var reloadingTable = false
    private var reloadTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var report = LyricsReadabilityReport()
    private var readabilityHost: NSHostingView<OutputSettingsReadabilityView>?
    private(set) var isPresented = false
    var profileEditor: OutputProfileEditor? { child as? OutputProfileEditor }
    var destinationEditor: OutputDestinationEditor? { child as? OutputDestinationEditor }
    var profilesMode: Bool { section.selectedSegment == 1 }

    init(coordinator: OutputCoordinator, router: AltViewOutputRouter) {
        self.coordinator = coordinator; self.router = router
        super.init(nibName: nil, bundle: nil)
        for publisher in [coordinator.objectWillChange, coordinator.profiles.objectWillChange,
                          coordinator.displays.objectWillChange, router.objectWillChange] {
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
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.delegate = self; table.dataSource = self; table.allowsEmptySelection = false
        table.setAccessibilityLabel("Outputs and profiles")
        let list = NSScrollView(); list.hasVerticalScroller = true; list.autohidesScrollers = true
        list.borderType = .bezelBorder; list.documentView = table
        list.heightAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true
        addNative.target = self; addNative.action = #selector(addNativeOutput(_:))
        addAltView.target = self; addAltView.action = #selector(addAltViewOutput(_:))
        removeOutput.target = self; removeOutput.action = #selector(removeSelectedOutput(_:))
        addProfile.image = NSImage(named: NSImage.addTemplateName)
        addProfile.imagePosition = .imageOnly; addProfile.bezelStyle = .smallSquare
        addProfile.target = self; addProfile.action = #selector(addSelectedProfile(_:))
        addProfile.setAccessibilityLabel("Add Profile")
        addProfile.toolTip = "Add a profile by copying the selected profile."
        NSLayoutConstraint.activate([addProfile.widthAnchor.constraint(equalToConstant: 28),
                                     addProfile.heightAnchor.constraint(equalToConstant: 24)])
        profileActions.orientation = .horizontal; profileActions.alignment = .centerY
        profileActions.addArrangedSubview(addProfile); profileActions.addArrangedSubview(NSView())
        let sidebar = NSStackView(views: [section, list, profileActions, addNative, addAltView, removeOutput])
        sidebar.orientation = .vertical; sidebar.alignment = .leading; sidebar.spacing = 8
        for item in sidebar.arrangedSubviews { item.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true }
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let status = NSStackView(views: [statusLabel, issueLabel])
        status.orientation = .vertical; status.alignment = .leading; status.spacing = 5
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
            sidebar.widthAnchor.constraint(equalToConstant: 180),
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
        if value {
            coordinator.displays.refresh(); router.startDiscovery(); reload()
        }
        else {
            if isViewLoaded { finishEditing() }
            router.stopDiscovery()
        }
    }
    func finishEditing() {
        guard isViewLoaded else { return }
        finishOutputSettingsFieldEditing(in: view)
        profileEditor?.finishEditing()
    }
    func scheduleReload() {
        guard reloadTask == nil else { return }
        reloadTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.reloadTask = nil; self.reload()
        }
    }
    func reload() {
        guard isViewLoaded else { return }
        let statuses = Dictionary(uniqueKeysWithValues: coordinator.destinationStatuses().map { ($0.id, $0.readiness.title) })
        let fresh = profilesMode ? store.document.profiles.filter(\.isNative).map { profile in
            ListRow(id: profile.id, title: profile.name, detail: "Reusable appearance")
        } : store.document.destinations.map { output in
            ListRow(id: output.id, title: output.name,
                detail: (store.profile(output.profileID)?.isNative == true ? "Native" : "AltView") + " · " + (statuses[output.id] ?? "Disabled"))
        }
        if selectedID == nil || !fresh.contains(where: { $0.id == selectedID }) {
            finishEditing(); selectedID = fresh.first?.id
        }
        if profilesMode { profileSelection = selectedID } else { outputSelection = selectedID }
        reloadingTable = true
        if fresh != rows { rows = fresh; table.reloadData() }
        if let index = rows.firstIndex(where: { $0.id == selectedID }), table.selectedRow != index {
            table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if selectedID == nil { table.deselectAll(nil) }
        reloadingTable = false
        addNative.isHidden = profilesMode; addAltView.isHidden = profilesMode; removeOutput.isHidden = profilesMode
        profileActions.isHidden = !profilesMode
        addProfile.isEnabled = profilesMode && selectedID.flatMap(store.profile)?.isNative == true
            && store.document.profiles.count < 128 && store.recoveryNotice == nil
        let canAdd = store.document.destinations.count < 16 && store.recoveryNotice == nil
        addNative.isEnabled = canAdd && store.profile(OutputProfile.audienceID)?.isNative == true
        addAltView.isEnabled = canAdd && store.profile(OutputProfile.altViewID)?.kind == .altView
        removeOutput.isEnabled = selectedID != nil && selectedID != store.document.destinations.first?.id && store.recoveryNotice == nil
        let key: DetailKey
        if store.recoveryNotice != nil { key = .recovery }
        else if let id = selectedID {
            key = profilesMode ? .profile(id) : .output(id, native: store.profile(store.document.destinations.first { $0.id == id }!.profileID)?.isNative == true)
        } else { key = .empty }
        if detailKey != key { finishEditing(); buildDetail(key) }
        profileEditor?.render(); destinationEditor?.render()
        renderStatus()
        updateReadability()
    }
    private func renderStatus() {
        let source = coordinator.ownership.source == nil ? "No live source" : "eucaly Current"
        let slides = coordinator.isPresenting ? (coordinator.visible ? "Visible" : "Hidden") : "Stopped"
        statusLabel.stringValue = "Live Output · \(source) · \(slides)"
        issueLabel.stringValue = [coordinator.issue, report.isEmpty ? nil : report.message].compactMap { $0 }.joined(separator: "\n")
        issueLabel.isHidden = issueLabel.stringValue.isEmpty
    }
    private func buildDetail(_ key: DetailKey) {
        detailKey = key
        child?.removeFromParent(); child = nil
        for subview in detailHost.subviews { subview.removeFromSuperview() }
        switch key {
        case .profile(let id):
            let editor = OutputProfileEditor(store: store, profileID: id)
            child = editor
        case .output(let id, _):
            let editor = OutputDestinationEditor(coordinator: coordinator, router: router, destinationID: id)
            editor.onEditProfile = { [weak self] id in self?.selectProfile(id) }
            child = editor
        case .recovery:
            let form = OutputSettingsForm(frame: .zero)
            form.add(outputSettingsLabel(store.recoveryNotice ?? "", secondary: true))
            form.add(outputSettingsActionRow([NSButton(title: "Recover Settings", target: self, action: #selector(recoverSettings(_:)))]))
            outputSettingsPin(form, to: detailHost)
        case .empty:
            outputSettingsPin(outputSettingsLabel(profilesMode ? "No native appearance profiles." : "Add an output to get started.", secondary: true), to: detailHost, inset: 8)
        }
        if let child { addChild(child); outputSettingsPin(child.view, to: detailHost) }
    }
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = rows[row]
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
        let id = rows[table.selectedRow].id
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
    @objc private func addAltViewOutput(_ sender: Any?) { addOutput(name: "AltView", profileID: OutputProfile.altViewID) }
    @objc private func addSelectedProfile(_ sender: Any?) {
        guard profilesMode, store.recoveryNotice == nil, let id = selectedID else { return }
        finishEditing()
        guard var profile = store.profile(id), profile.isNative, store.document.profiles.count < 128 else { return }
        profile.id = UUID()
        // Leave room for the suffix even when the source name fills the limit.
        while (profile.name + " Copy").utf8.count > 160 { profile.name.removeLast() }
        profile.name += " Copy"
        store.edit { $0.profiles.append(profile) }
        selectProfile(profile.id)
        table.scrollRowToVisible(table.selectedRow)
    }
    private func addOutput(name: String, profileID: UUID) {
        guard store.recoveryNotice == nil, store.profile(profileID) != nil, store.document.destinations.count < 16 else { return }
        finishEditing()
        let output = OutputDestinationConfiguration(name: name, profileID: profileID, monitor: nil, enabled: false)
        store.edit { $0.destinations.append(output) }; selectDestination(output.id)
    }
    @objc private func removeSelectedOutput(_ sender: Any?) {
        guard !profilesMode, let id = selectedID, id != store.document.destinations.first?.id else { return }
        finishEditing(); store.edit { $0.destinations.removeAll { $0.id == id } }; reload()
    }
    @objc private func recoverSettings(_ sender: Any?) { store.recover(); reload() }

    // Preserve the existing SwiftUI font-metric probes for all assigned profiles,
    // independently of which native editor is selected. They never render output.
    private func updateReadability() {
        let root = OutputSettingsReadabilityView(document: store.document, snapshot: coordinator.snapshot,
            displays: coordinator.displays) { [weak self] report in
                guard let self, self.report != report else { return }
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

private struct OutputSettingsReadabilityView: View {
    let document: OutputProfileDocument
    let snapshot: OutputContentSnapshot
    let displays: ProjectionDisplayManager
    let onReport: (LyricsReadabilityReport) -> Void
    var body: some View {
        ZStack {
            ForEach(document.destinations) { destination in
                if let profile = document.profiles.first(where: { $0.id == destination.profileID }),
                   let target = destination.monitor, let monitor = displays.resolve(target) {
                    if profile.kind == .confidence {
                        OutputConfidenceReadabilityProbe(snapshot: snapshot, profile: profile, size: monitor.frame.size)
                    } else {
                        OutputReadabilityProbe(content: snapshot.current, profile: profile, size: monitor.frame.size)
                    }
                }
            }
        }.onPreferenceChange(LyricsReadabilityPreferenceKey.self) { report in
            DispatchQueue.main.async { onReport(report) }
        }
    }
}
