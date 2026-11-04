import AppKit
import Combine
import SwiftUI

/// Settings pane for output destinations. Appearance edits live under Profiles.
@MainActor
final class ManageOutputsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var confirmOutputRemoval: (OutputDestinationConfiguration) -> Bool = { destination in
        let alert = NSAlert()
        alert.messageText = "Remove “" + destination.name + "”?"
        if let settings = destination.networkSettings, let technology = destination.networkTechnology {
            alert.informativeText = technology.title + " source “" + settings.sourceName
                + "”. This removes its saved configuration and stops this output if it is running. Its appearance editing target and music route are cleared when selected. Other outputs keep running. Undo Remove restores the configuration disabled."
        } else {
            alert.informativeText = "This removes its saved configuration and stops this output if it is running. Its appearance editing target and music route are cleared when selected. Other outputs keep running. Undo Remove restores the configuration disabled."
        }
        alert.addButton(withTitle: "Remove Output")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// Settings shell jumps to the Profiles pane when destination Edit Profile… is used.
    var onEditProfile: ((UUID) -> Void)?
    let coordinator: OutputCoordinator
    var store: OutputProfileStore { coordinator.profiles }
    private let chrome = OutputSettingsListDetailChrome(
        tableAccessibilityLabel: "Outputs",
        tableColumnIdentifier: "outputs",
        rowHeight: 100
    )
    var table: NSTableView { chrome.table }
    var statusLabel: NSTextField { chrome.statusLabel }
    var issueLabel: NSTextField { chrome.issueLabel }
    let addOutputMenu = NSPopUpButton(frame: .zero, pullsDown: true)
    let addNative = NSMenuItem(title: "Native Monitor Output", action: nil, keyEquivalent: "")
    let addNDI = NSMenuItem(title: "NDI Output", action: nil, keyEquivalent: "")
    let addOMT = NSMenuItem(title: "OMT Output", action: nil, keyEquivalent: "")
    let removeOutput = NSButton(title: "Remove Output…", target: nil, action: nil)
    let undoRemoveOutput = NSButton(title: "Undo Remove", target: nil, action: nil)
    let removalNotice = outputSettingsLabel(secondary: true)
    private let outputActions = NSStackView()
    private(set) var selectedID: UUID?
    private var removedConfiguration: OutputProfileStore.RemovedOutput?
    private var managementProblem: String?
    private enum DetailKey: Hashable { case output(UUID), recovery, empty }
    private var detailKey: DetailKey?
    private var child: NSViewController?
    private var destinationForms: [DetailKey: OutputDestinationEditor] = [:]
    private var detailNotice: NSView?
    private var rows: [OutputSettingsListDetailChrome.ListRow] = []
    private var reloadingTable = false
    private var reloadTask: Task<Void, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private var report = LyricsReadabilityReport()
    private var readabilityHost: NSHostingView<OutputSettingsReadabilityView>?
    private var readabilityInput: OutputSettingsReadabilityInput?
    private var readabilityTask: Task<Void, Never>?
    private(set) var isPresented = false
    private var isSuspended = false
    var destinationEditor: OutputDestinationEditor? { child as? OutputDestinationEditor }

    init(coordinator: OutputCoordinator) {
        self.coordinator = coordinator
        super.init(nibName: nil, bundle: nil)
        for publisher in [coordinator.objectWillChange, coordinator.profiles.objectWillChange,
                          coordinator.displays.objectWillChange] {
            publisher.sink { [weak self] _ in self?.scheduleReload() }.store(in: &subscriptions)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { reloadTask?.cancel(); readabilityTask?.cancel() }

    override func loadView() {
        view = NSView()
        chrome.table.delegate = self
        chrome.table.dataSource = self
        addNative.target = self
        addNative.action = #selector(addNativeOutput(_:))
        addNDI.target = self
        addNDI.action = #selector(addNDIOutput(_:))
        addOMT.target = self
        addOMT.action = #selector(addOMTOutput(_:))
        let menu = NSMenu()
        menu.autoenablesItems = false
        let glyph = NSMenuItem(title: "+", action: nil, keyEquivalent: "")
        glyph.image = NSImage(named: NSImage.addTemplateName)
        menu.addItem(glyph)
        menu.addItem(addNative)
        menu.addItem(addNDI)
        menu.addItem(addOMT)
        addOutputMenu.menu = menu
        addOutputMenu.imagePosition = .imageOnly
        addOutputMenu.setAccessibilityLabel("Add Output")
        addOutputMenu.toolTip = "Add a disabled, unassigned output."
        removeOutput.target = self
        removeOutput.action = #selector(removeSelectedOutput(_:))
        removeOutput.setAccessibilityLabel("Remove Output")
        undoRemoveOutput.target = self
        undoRemoveOutput.action = #selector(undoOutputRemoval(_:))
        for button in [addOutputMenu, removeOutput, undoRemoveOutput] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        outputActions.orientation = .horizontal
        outputActions.alignment = .centerY
        outputActions.spacing = 8
        for action in [addOutputMenu, removeOutput, NSView()] {
            outputActions.addArrangedSubview(action)
        }
        let recoveryActions = outputSettingsActionRow([undoRemoveOutput])
        chrome.install(in: view, belowList: [outputActions, recoveryActions, removalNotice])
        reload()
    }

    func setPresented(_ value: Bool) {
        isPresented = value
        isSuspended = !value
        if value {
            coordinator.displays.refresh()
            reload()
        } else {
            reloadTask?.cancel()
            reloadTask = nil
            readabilityTask?.cancel()
            readabilityTask = nil
            if isViewLoaded {
                finishEditing()
                destinationEditor?.networkEditor?.discardDraft()
            }
        }
    }

    func finishEditing() {
        guard isViewLoaded else { return }
        finishOutputSettingsFieldEditing(in: view)
        destinationEditor?.networkEditor?.finishEditing()
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
        let statuses = Dictionary(uniqueKeysWithValues: coordinator.destinationStatuses().map { ($0.id, $0.readiness.title) })
        let fresh = store.document.destinations.map { output in
            OutputSettingsListDetailChrome.ListRow(
                id: output.id,
                title: coordinator.managementDestinationLabel(output),
                detail: coordinator.managementWorkspaceName(output.workspaceID) + " · "
                    + (store.profile(output.profileID)?.name ?? "Missing appearance")
                    + "\n" + (output.enabled ? "Enabled" : "Disabled") + " · " + (statuses[output.id] ?? "Stopped")
                    + " · " + (coordinator.isOpen(output.id) && coordinator.snapshot(for: output.id).visible
                        ? "Slides visible" : "Slides hidden")
            )
        }
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

        let canAdd = store.document.destinations.count < 16 && store.recoveryNotice == nil
        addOutputMenu.toolTip = canAdd
            ? "Add a disabled, unassigned output."
            : "The 16 output limit has been reached. Remove an unused output before adding another."
        addNative.isEnabled = canAdd && store.profile(OutputProfile.audienceID) != nil
        addNDI.isEnabled = canAdd && store.profile(OutputProfile.audienceID) != nil
        addOMT.isEnabled = addNDI.isEnabled
        addOutputMenu.isEnabled = canAdd
        removeOutput.isEnabled = selectedID != nil && store.recoveryNotice == nil
        undoRemoveOutput.isHidden = removedConfiguration == nil
        undoRemoveOutput.isEnabled = store.recoveryNotice == nil
        removalNotice.isHidden = removedConfiguration == nil
        removalNotice.stringValue = removedConfiguration.map {
            "Removed “" + $0.destination.name + "”. Undo restores it disabled; enable and start it explicitly."
        } ?? ""

        let key: DetailKey
        if store.recoveryNotice != nil { key = .recovery }
        else if let id = selectedID { key = .output(id) }
        else { key = .empty }
        if detailKey != key {
            finishEditing()
            buildDetail(key)
        }
        pruneDestinationForms()
        destinationEditor?.render()
        renderStatus()
        scheduleReadabilityUpdate()
    }

    private func renderStatus() {
        let active = store.document.workspaces.filter { coordinator.isRunning(workspace: $0.id) }
        statusLabel.stringValue = active.isEmpty
            ? "Workspace outputs stopped"
            : active.map { $0.name + ": " + coordinator.tabStatus(workspace: $0.id) }.joined(separator: " · ")
        statusLabel.maximumNumberOfLines = 2
        statusLabel.toolTip = statusLabel.stringValue
        let owner = selectedID.flatMap { coordinator.destination($0)?.workspaceID }
        let outputIssue: String?
        if let owner {
            outputIssue = coordinator.outputIssue(workspace: owner).map {
                "Workspace " + coordinator.managementWorkspaceName(owner) + ": " + $0
            }
        } else {
            outputIssue = coordinator.issue
        }
        issueLabel.stringValue = [managementProblem, outputIssue, report.isEmpty ? nil : report.message]
            .compactMap { $0 }.joined(separator: "\n")
        issueLabel.isHidden = issueLabel.stringValue.isEmpty
    }

    private func buildDetail(_ key: DetailKey) {
        detailKey = key
        let previous = child
        child = nil
        detailNotice?.removeFromSuperview()
        detailNotice = nil
        switch key {
        case .output(let id):
            let editor: OutputDestinationEditor
            if let cached = destinationForms[key] {
                editor = cached
            } else {
                editor = OutputDestinationEditor(coordinator: coordinator, destinationID: id)
                editor.onEditProfile = { [weak self] profileID in self?.onEditProfile?(profileID) }
                destinationForms[key] = editor
                addChild(editor)
                outputSettingsPin(editor.view, to: chrome.detailHost)
            }
            child = editor
        case .recovery:
            discardForms()
            let form = OutputSettingsForm(frame: .zero)
            form.add(outputSettingsLabel(store.recoveryNotice ?? "", secondary: true))
            form.add(outputSettingsActionRow([
                NSButton(title: "Recover Settings", target: self, action: #selector(recoverSettings(_:)))
            ]))
            detailNotice = form
            outputSettingsPin(form, to: chrome.detailHost)
        case .empty:
            discardForms()
            chrome.showEmptyNotice("Add an output to get started.", replacing: &detailNotice)
        }
        if previous !== child {
            (previous as? OutputDestinationEditor)?.networkEditor?.discardDraft()
            previous?.view.isHidden = true
        }
        child?.view.isHidden = false
    }

    private func pruneDestinationForms() {
        let keys = Set(store.document.destinations.map { DetailKey.output($0.id) })
        for key in Array(destinationForms.keys) where !keys.contains(key) {
            let form = destinationForms.removeValue(forKey: key)
            form?.view.removeFromSuperview()
            form?.removeFromParent()
        }
    }

    private func discardForms() {
        for form in destinationForms.values {
            form.view.removeFromSuperview()
            form.removeFromParent()
        }
        destinationForms.removeAll()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { rows[row].id == nil }
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].id != nil }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rows[row].id == nil ? 28 : 100 }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        chrome.makeCell(for: rows[row], detailLines: 4)
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

    func selectDestination(_ id: UUID) {
        finishEditing()
        selectedID = id
        reload()
    }

    @objc private func addNativeOutput(_ sender: Any?) {
        var number = 1
        while store.document.destinations.contains(where: { $0.name == "Native Output \(number)" }) { number += 1 }
        addOutput(name: "Native Output \(number)", profileID: OutputProfile.audienceID)
    }
    @objc private func addNDIOutput(_ sender: Any?) { addNetworkOutput(.ndi) }
    @objc private func addOMTOutput(_ sender: Any?) { addNetworkOutput(.omt) }

    private func addNetworkOutput(_ technology: NetworkOutputTechnology) {
        guard store.recoveryNotice == nil, store.document.destinations.count < 16,
              store.profile(OutputProfile.audienceID) != nil else { return }
        finishEditing()
        var sourceName = "eucaly", number = 2
        while store.document.destinations.contains(where: {
            $0.networkTechnology == technology
                && $0.networkSettings?.sourceName.caseInsensitiveCompare(sourceName) == .orderedSame
        }) {
            sourceName = "eucaly \(number)"
            number += 1
        }
        var outputNumber = 1
        var outputName = technology.title + " Output"
        while store.document.destinations.contains(where: { $0.name == outputName }) {
            outputNumber += 1
            outputName = technology.title + " Output \(outputNumber)"
        }
        var settings = NetworkOutputSettings(sourceName: sourceName)
        settings.keyColour = .chromaGreen
        var output = OutputDestinationConfiguration(
            name: outputName, profileID: OutputProfile.audienceID, monitor: nil,
            enabled: false, workspaceID: coordinator.focusedWorkspaceID
        )
        output.destination = technology == .ndi ? .ndi(settings) : .omt(settings)
        store.edit { $0.destinations.append(output) }
        selectDestination(output.id)
    }

    private func addOutput(name: String, profileID: UUID) {
        guard store.recoveryNotice == nil, store.profile(profileID) != nil,
              store.document.destinations.count < 16 else { return }
        finishEditing()
        let output = OutputDestinationConfiguration(
            name: name, profileID: profileID, monitor: nil, enabled: false,
            workspaceID: coordinator.focusedWorkspaceID
        )
        store.edit { $0.destinations.append(output) }
        selectDestination(output.id)
    }

    @objc private func removeSelectedOutput(_ sender: Any?) {
        guard store.recoveryNotice == nil, let id = selectedID else { return }
        finishEditing()
        guard let destination = coordinator.destination(id) else { return }
        guard confirmOutputRemoval(destination) else { return }
        removedConfiguration = store.removeOutputConfiguration(id)
        managementProblem = removedConfiguration == nil
            ? "The output could not be removed. Its configuration was retained." : nil
        reload()
    }

    @objc private func undoOutputRemoval(_ sender: Any?) {
        guard let removedConfiguration else { return }
        managementProblem = store.restoreOutputConfiguration(removedConfiguration)
        if managementProblem == nil {
            self.removedConfiguration = nil
            selectDestination(removedConfiguration.destination.id)
        }
        reload()
    }

    @objc private func recoverSettings(_ sender: Any?) {
        store.recover()
        reload()
    }

    private func scheduleReadabilityUpdate() {
        guard isViewLoaded, !isSuspended else { return }
        readabilityTask?.cancel()
        readabilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled, self.isViewLoaded, !self.isSuspended else { return }
            self.readabilityTask = nil
            self.applyReadability()
        }
    }

    private func applyReadability() {
        let input = OutputSettingsReadabilityInput(coordinator: coordinator)
        guard readabilityInput != input else { return }
        readabilityInput = input
        let root = OutputSettingsReadabilityView(input: input) { [weak self] report in
            guard let self, self.readabilityInput == input, self.report != report else { return }
            self.report = report
            self.renderStatus()
        }
        if let readabilityHost {
            readabilityHost.rootView = root
        } else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            host.translatesAutoresizingMaskIntoConstraints = false
            host.setAccessibilityHidden(true)
            view.addSubview(host)
            NSLayoutConstraint.activate([
                host.widthAnchor.constraint(equalToConstant: 0),
                host.heightAnchor.constraint(equalToConstant: 0),
                host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.topAnchor.constraint(equalTo: view.topAnchor)
            ])
            readabilityHost = host
        }
    }
}

private struct OutputSettingsReadabilityInput: Equatable {
    struct Assignment: Equatable, Identifiable {
        let id: UUID
        let profile: OutputProfile
        let size: CGSize
        let current: OutputTextContent
        let next: OutputTextContent?
        let visible: Bool
        let hasMedia: Bool
        let isNetworkDestination: Bool
        let destinationName: String
    }
    let assignments: [Assignment]
    @MainActor init(coordinator: OutputCoordinator) {
        assignments = coordinator.profiles.document.destinations.compactMap { destination in
            guard destination.enabled, let profile = coordinator.profile(for: destination.id) else { return nil }
            let size: CGSize
            if let settings = destination.networkSettings {
                size = .init(width: settings.width, height: settings.height)
            } else if let target = destination.monitor, let monitor = coordinator.displays.resolve(target) {
                size = monitor.frame.size
            } else {
                return nil
            }
            let snapshot = coordinator.snapshot(for: destination.id)
            return .init(
                id: destination.id, profile: profile, size: size, current: snapshot.current,
                next: snapshot.next, visible: snapshot.visible,
                hasMedia: snapshot.localMedia.map { OutputContentClassifier.mode(for: $0) == .media } ?? false,
                isNetworkDestination: destination.isNetworkDestination,
                destinationName: destination.name
            )
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
                    if OutputConfidenceContent.usesNativeMonitorComposition(
                        profile: assignment.profile, isNetworkDestination: assignment.isNetworkDestination
                    ) {
                        OutputConfidenceReadabilityProbe(
                            snapshot: .init(current: assignment.current, next: assignment.next, visible: assignment.visible),
                            profile: assignment.profile, size: assignment.size,
                            labelPrefix: assignment.destinationName
                        )
                    } else {
                        OutputReadabilityProbe(
                            content: assignment.current, profile: assignment.profile, size: assignment.size,
                            labelPrefix: assignment.destinationName
                        )
                    }
                }
            }
        }.onPreferenceChange(LyricsReadabilityPreferenceKey.self) { report in
            DispatchQueue.main.async { onReport(report) }
        }
    }
}
