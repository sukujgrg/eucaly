import AppKit

@MainActor
final class OutputDestinationEditor: NSViewController, NSTextFieldDelegate {
    let ownerLabel = outputSettingsLabel(secondary: true)
    let appearanceNotice = outputSettingsLabel(secondary: true)
    let moveNotice = outputSettingsLabel(secondary: true)
    let standbyNotice = outputSettingsLabel(secondary: true)
    let moveWorkspaceButton = NSButton(title: "Move to This Workspace", target: nil, action: nil)
    let coordinator: OutputCoordinator
    let destinationID: UUID
    var store: OutputProfileStore { coordinator.profiles }
    var destination: OutputDestinationConfiguration? { store.document.destinations.first { $0.id == destinationID } }
    let nameField = NSTextField()
    let enabledButton = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    let profilePicker = NSPopUpButton()
    let monitorPicker = NSPopUpButton()
    let statusLabel = outputSettingsLabel(secondary: true)
    let validationLabel = outputSettingsLabel(secondary: true)
    let confidenceButton = NSButton(title: "Open Confidence", target: nil, action: nil)
    let identifyButton = NSButton(title: "Identify", target: nil, action: nil)
    let nameMonitorButton = NSButton(title: "Name Monitor…", target: nil, action: nil)
    let editProfileButton = NSButton(title: "Edit Profile…", target: nil, action: nil)
    var onEditProfile: (UUID) -> Void = { _ in }
    private struct MonitorEntry: Equatable { let target: ProjectionMonitorTarget?; let title: String; let enabled: Bool }
    private struct ProfileEntry: Equatable { let id: UUID; let title: String }
    private var monitors: [MonitorEntry] = []
    private var profiles: [ProfileEntry] = []
    private var confidenceActions: NSStackView?
    private(set) var networkEditor: NetworkOutputSettingsEditor?

    init(coordinator: OutputCoordinator, destinationID: UUID) {
        self.coordinator = coordinator; self.destinationID = destinationID
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        let form = OutputSettingsForm(frame: .zero); view = form
        guard destination != nil else { return }
        form.section(destination?.networkTechnology.map { $0.title + " Output" } ?? "Native Output")
        nameField.delegate = self; nameField.setAccessibilityLabel("Output name")
        enabledButton.target = self; enabledButton.action = #selector(enabledChanged(_:))
        profilePicker.autoenablesItems = false
        profilePicker.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        profilePicker.cell?.lineBreakMode = .byTruncatingMiddle
        profilePicker.target = self; profilePicker.action = #selector(profileChanged(_:)); profilePicker.setAccessibilityLabel("Appearance profile")
        editProfileButton.target = self; editProfileButton.action = #selector(editProfile(_:))
        form.add(outputSettingsRow("Name", nameField)); form.add(enabledButton)
        moveWorkspaceButton.target = self; moveWorkspaceButton.action = #selector(moveWorkspace(_:))
        form.add(ownerLabel); form.add(outputSettingsActionRow([moveWorkspaceButton])); form.add(moveNotice)
        validationLabel.textColor = .systemOrange; validationLabel.isHidden = true; form.add(validationLabel)
        form.add(outputSettingsFieldGroup("Profile", profilePicker, actions: [editProfileButton]))
        form.add(appearanceNotice)
        form.add(standbyNotice)
        if destination?.isNetworkDestination == true {
            let editor = NetworkOutputSettingsEditor(coordinator: coordinator, destinationID: destinationID)
            networkEditor = editor; addChild(editor)
            let operations = editor.view
            form.add(editor.configurationView)
            let content = NSStackView(views: [operations, form]); content.orientation = .vertical
            content.alignment = .leading; content.spacing = 12
            for child in content.arrangedSubviews { child.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true }
            view = content; render(); return
        }
        monitorPicker.autoenablesItems = false
        monitorPicker.target = self; monitorPicker.action = #selector(monitorChanged(_:)); monitorPicker.setAccessibilityLabel("Monitor assignment")
        identifyButton.target = self; identifyButton.action = #selector(identifyMonitor(_:))
        nameMonitorButton.target = self; nameMonitorButton.action = #selector(nameMonitor(_:))
        form.add(outputSettingsFieldGroup("Monitor", monitorPicker, actions: [identifyButton, nameMonitorButton]))
        form.add(statusLabel)
        confidenceButton.target = self; confidenceButton.action = #selector(toggleConfidence(_:))
        let confidenceActions = outputSettingsActionRow([confidenceButton])
        self.confidenceActions = confidenceActions; form.add(confidenceActions)
        form.add(outputSettingsLabel("This output follows its assigned workspace’s Current. Close this output before changing its monitor. Disconnected monitors keep their assignment and require an explicit Show Slides to reopen.", secondary: true))
        render()
    }
    @objc private func moveWorkspace(_ sender: Any?) {
        guard let session = coordinator.preferredLocalSession else { return }
        validationLabel.stringValue = coordinator.moveOutput(destinationID, to: session)
            ? "" : session.projectionDisplayIssue ?? "Unable to move output."
        render()
    }
    private static let invalidNameMessage = "Use a short, non-empty output name on one line."
    func render() {
        guard isViewLoaded, let destination, let profile = store.profile(destination.profileID) else { return }
        let target = destination.networkSettings.map { (destination.networkTechnology?.title ?? "Network") + " source: " + $0.sourceName }
            ?? destination.monitor.map { "Monitor: " + coordinator.displays.label(for: $0) } ?? "Monitor: None"
        let state = destination.isNetworkDestination ? coordinator.network.state(destinationID).title(for: destination.networkTechnology ?? .ndi)
            : coordinator.isOpen(destinationID) ? "Window open" : "Window closed"
        let visibility = coordinator.isOpen(destinationID) && coordinator.snapshot(for: destinationID).visible ? "Slides visible" : "Slides hidden"
        ownerLabel.stringValue = "Workspace: " + coordinator.managementWorkspaceName(destination.workspaceID) + "\nOutput: " + destination.name
            + " · " + target + "\nProfile: " + profile.name + " · " + (destination.enabled ? "Enabled" : "Disabled") + " · " + state + " · " + visibility
        let targetWorkspace = coordinator.managementWorkspaceName(coordinator.focusedWorkspaceID)
        moveNotice.stringValue = coordinator.isOpen(destinationID)
            ? "Moves this live output to " + targetWorkspace + "’s Current immediately." + (coordinator.focusedWorkspaceID.flatMap { coordinator.preparedSession(workspace: $0) }?.isEmpty == false ? "" : " The target Current is empty.")
            : "Changes assignment to " + targetWorkspace + "; this output remains stopped."
        if destination.isNetworkDestination && profile.kind == .confidence {
            appearanceNotice.stringValue = "Uses profile “" + profile.name + "”. This network feed publishes accepted Current with that profile’s styling. Confidence Next, clock and standby belong to native Confidence monitors only. Edit or duplicate profiles in Profiles."
        } else {
            appearanceNotice.stringValue = "Uses profile “" + profile.name + "”. Edit or duplicate profiles in Profiles."
        }
        standbyNotice.stringValue = "Confidence is a native stage monitor: Current above Next when present, with a centered 24-hour clock behind lyrics (full strength when empty or hidden). It opens automatically on its assigned monitor. Changing an idle standby to another appearance closes that standby window."
        standbyNotice.isHidden = !destination.isMonitorDestination || profile.kind != .confidence
        moveWorkspaceButton.title = "Move to This Workspace (" + coordinator.managementWorkspaceName(coordinator.focusedWorkspaceID) + ")"
        moveWorkspaceButton.isEnabled = coordinator.focusedWorkspaceID != nil && destination.workspaceID != coordinator.focusedWorkspaceID
        if nameField.currentEditor() == nil {
            nameField.stringValue = destination.name
            // Restored saved names are valid again; do not keep a stale name error
            // across profile/monitor edits.
            if validationLabel.stringValue == Self.invalidNameMessage { validationLabel.stringValue = "" }
        }
        validationLabel.isHidden = validationLabel.stringValue.isEmpty
        enabledButton.state = destination.enabled ? .on : .off
        var offered = store.reusableAppearanceChoices(for: destinationID)
        if !offered.contains(where: { $0.id == profile.id }) {
            offered.insert(profile, at: 0)
        }
        let choices = offered.map { ProfileEntry(id: $0.id, title: $0.name) }
        if profiles != choices {
            profiles = choices
            let menu = NSMenu(); menu.autoenablesItems = false
            for profile in profiles {
                let item = NSMenuItem(title: profile.title, action: nil, keyEquivalent: "")
                item.representedObject = profile.id; menu.addItem(item)
            }
            profilePicker.menu = menu
        }
        profilePicker.toolTip = "Choose a profile for this output. Edit profiles in the Profiles list."
        profilePicker.select(profilePicker.itemArray.first { $0.representedObject as? UUID == destination.profileID })
        if let networkEditor { networkEditor.render(); return }
        let displays = coordinator.displays
        var fresh = [MonitorEntry(target: nil, title: "None", enabled: true)]
        fresh += displays.displays.map { display in
            .init(target: display.target, title: displays.label(for: display.target),
                  enabled: coordinator.monitorAssignmentProblem(for: display.target, destinationID: destinationID) == nil)
        }
        if let target = destination.monitor, !fresh.contains(where: { $0.target?.identity == target.identity }) {
            fresh.append(.init(target: target, title: displays.label(for: target) + " · Unavailable", enabled: false))
        }
        if fresh != monitors {
            monitors = fresh
            let menu = NSMenu(); menu.autoenablesItems = false
            for entry in monitors {
                let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
                item.representedObject = entry.target; item.isEnabled = entry.enabled; menu.addItem(item)
            }
            monitorPicker.menu = menu
        }
        monitorPicker.selectItem(at: monitors.firstIndex { $0.target?.identity == destination.monitor?.identity } ?? 0)
        monitorPicker.isEnabled = !coordinator.isOpen(destinationID)
        identifyButton.isEnabled = destination.monitor.map(displays.canIdentify) ?? false
        nameMonitorButton.isEnabled = destination.monitor.map(displays.canRename) ?? false
        let conflict = destination.monitor.flatMap { store.monitorAssignmentProblem(for: $0, excluding: destinationID) }
        let problem = destination.monitor.flatMap { displays.problem(for: $0) }
        let isConfidence = profile.kind == .confidence
        let nativeStatus = conflict ?? problem ?? (destination.monitor == nil ? "Choose a monitor, or keep None to leave this output unassigned."
            : !destination.enabled ? "Enable this output to use its assigned monitor."
            : coordinator.isOpen(destinationID) ? "Output open. Appearance follows the selected profile."
            : isConfidence
                ? "Confidence opens a standby clock on this monitor. Show Slides presents Current above Next when text is selected."
                : "Show Slides opens this output with Current. Open Native Output places a background-only window without accepting Current.")
        let ownerIssue = destination.workspaceID.flatMap { coordinator.outputIssue(workspace: $0) }
        let workspaceStatus = ownerIssue.map { "Workspace " + coordinator.managementWorkspaceName(destination.workspaceID) + ": " + $0 }
        statusLabel.stringValue = [nativeStatus, workspaceStatus].compactMap { $0 }.joined(separator: "\n")
        statusLabel.textColor = conflict != nil || problem != nil || ownerIssue != nil ? .systemOrange : .secondaryLabelColor
        confidenceButton.isHidden = false
        confidenceActions?.isHidden = false
        if coordinator.isOpen(destinationID) {
            confidenceButton.title = isConfidence ? "Close Confidence" : "Close Native Output"
        } else {
            confidenceButton.title = isConfidence ? "Open Confidence" : "Open Native Output"
        }
        confidenceButton.isEnabled = coordinator.isOpen(destinationID) || (destination.enabled && conflict == nil && destination.monitor.flatMap { displays.resolve($0) } != nil)
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === nameField, let destination else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 160, !name.contains(where: \.isNewline) else {
            validationLabel.stringValue = Self.invalidNameMessage
            validationLabel.isHidden = false
            nameField.stringValue = destination.name; return
        }
        validationLabel.stringValue = ""
        validationLabel.isHidden = true
        store.edit { document in
            if let index = document.destinations.firstIndex(where: { $0.id == destinationID }) { document.destinations[index].name = name }
        }
    }
    @objc private func enabledChanged(_ sender: NSButton) {
        validationLabel.stringValue = store.setEnabled(sender.state == .on, for: destinationID) ?? ""
        render()
    }
    @objc private func profileChanged(_ sender: Any?) {
        guard let id = profilePicker.selectedItem?.representedObject as? UUID,
              store.profile(id) != nil else { return }
        store.selectProfile(id, for: destinationID)
        render()
    }
    @objc private func editProfile(_ sender: Any?) {
        guard let destination else { return }
        onEditProfile(destination.profileID)
    }
    @objc private func monitorChanged(_ sender: Any?) {
        let target = monitorPicker.selectedItem?.representedObject as? ProjectionMonitorTarget
        if !coordinator.assignMonitor(target, to: destinationID) { validationLabel.stringValue = coordinator.issue ?? "Close this output before changing its monitor." }
        else { validationLabel.stringValue = "" }
        render()
    }
    @objc private func identifyMonitor(_ sender: Any?) { if let target = destination?.monitor { coordinator.displays.identify(target) } }
    @objc private func nameMonitor(_ sender: Any?) {
        if let target = destination?.monitor { OutputMonitorSettingsController.present(displays: coordinator.displays, target: target, from: view.window) }
    }
    @objc private func toggleConfidence(_ sender: Any?) {
        if coordinator.isOpen(destinationID) { coordinator.closeOutput(destinationID) }
        else { coordinator.openNativeOutput(destinationID) }
        render()
    }
}
