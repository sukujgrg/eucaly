import AppKit

@MainActor
final class OutputDestinationEditor: NSViewController, NSTextFieldDelegate {
    let ownerLabel = outputSettingsLabel(secondary: true)
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
    let customizeButton = NSButton(title: "Customize Appearance…", target: nil, action: nil)
    let clearBackgroundButton = NSButton(title: "Clear Background", target: nil, action: nil)
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
        form.add(outputSettingsRow("Name", nameField)); form.add(enabledButton)
        moveWorkspaceButton.target = self; moveWorkspaceButton.action = #selector(moveWorkspace(_:))
        form.add(ownerLabel); form.add(outputSettingsActionRow([moveWorkspaceButton]))
        validationLabel.textColor = .systemOrange; validationLabel.isHidden = true; form.add(validationLabel)
        customizeButton.target = self; customizeButton.action = #selector(editProfile(_:))
        clearBackgroundButton.target = self; clearBackgroundButton.action = #selector(clearBackground(_:))
        form.add(outputSettingsFieldGroup("Appearance", profilePicker, actions: [
            customizeButton,
            clearBackgroundButton
        ]))
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
        if !coordinator.moveOutput(destinationID, to: session) { validationLabel.stringValue = session.projectionDisplayIssue ?? "Unable to move output." }
        render()
    }
    func render() {
        guard isViewLoaded, let destination, let profile = store.profile(destination.profileID) else { return }
        ownerLabel.stringValue = "Workspace: " + store.workspaceName(destination.workspaceID)
        moveWorkspaceButton.title = "Move to This Workspace (" + store.workspaceName(coordinator.focusedWorkspaceID) + ")"
        moveWorkspaceButton.isEnabled = coordinator.focusedWorkspaceID != nil && destination.workspaceID != coordinator.focusedWorkspaceID
        validationLabel.isHidden = validationLabel.stringValue.isEmpty
        if nameField.currentEditor() == nil { nameField.stringValue = destination.name }
        enabledButton.state = destination.enabled ? .on : .off
        customizeButton.isEnabled = store.canCustomizeProfile(for: destinationID)
        customizeButton.title = profile.isReusable ? "Customize Appearance…" : "Edit Appearance…"
        clearBackgroundButton.isEnabled = customizeButton.isEnabled
        clearBackgroundButton.isHidden = false
        let help = customizeButton.isEnabled ? nil : "The profile limit has been reached. Edit reusable profiles in Profiles."
        customizeButton.toolTip = help ?? "Edit an independent appearance for this output. Reusable profiles remain available in Profiles."
        clearBackgroundButton.toolTip = help ?? "Clear the background for this output only."
        var choices = store.reusableProfiles.map { ProfileEntry(id: $0.id, title: $0.name) }
        if !profile.isReusable {
            choices.insert(.init(id: profile.id, title: "Custom Appearance (" + profile.name + ")"), at: 0)
        }
        if profiles != choices {
            profiles = choices
            let menu = NSMenu(); menu.autoenablesItems = false
            for profile in profiles {
                let item = NSMenuItem(title: profile.title, action: nil, keyEquivalent: "")
                item.representedObject = profile.id; menu.addItem(item)
            }
            if !profile.isReusable { menu.insertItem(.separator(), at: 1) }
            profilePicker.menu = menu
        }
        profilePicker.toolTip = "Choose a reusable profile, or keep this output’s custom appearance. Customize Appearance edits this output only."
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
        statusLabel.stringValue = conflict ?? problem ?? (destination.monitor == nil ? "Choose a monitor, or keep None to leave this output unassigned."
            : !destination.enabled ? "Enable this output to use its assigned monitor."
            : coordinator.isOpen(destinationID) ? "Output open. Appearance follows the selected profile."
            : "Show Slides to open this output.")
        statusLabel.textColor = conflict != nil || problem != nil ? .systemOrange : .secondaryLabelColor
        confidenceButton.isHidden = profile.kind != .confidence
        confidenceActions?.isHidden = profile.kind != .confidence
        confidenceButton.title = coordinator.isOpen(destinationID) ? "Close Confidence" : "Open Confidence"
        confidenceButton.isEnabled = destination.enabled && conflict == nil && destination.monitor.flatMap { displays.resolve($0) } != nil
    }
    func controlTextDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextField === nameField, let destination else { return }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 160, !name.contains(where: \.isNewline) else {
            validationLabel.stringValue = "Use a short, non-empty output name on one line."
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
    @objc private func editProfile(_ sender: Any?) {
        finishOutputSettingsFieldEditing(in: view)
        if let id = store.customizeProfile(for: destinationID) { onEditProfile(id) }
    }
    @objc private func clearBackground(_ sender: Any?) {
        finishOutputSettingsFieldEditing(in: view)
        store.clearDestinationBackground(destinationID)
    }
    @objc private func toggleConfidence(_ sender: Any?) {
        if coordinator.isOpen(destinationID) { coordinator.closeOutput(destinationID) }
        else { coordinator.openConfidence(destinationID) }
        render()
    }
}
