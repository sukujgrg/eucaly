import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Both native Output menus describe the same workspace listening preference.
/// Native projection and explicitly requested standalone music retain their
/// local audio; the menu explains those routes without changing the preference.
@MainActor
struct OutputAudioListeningState: Equatable {
    static let title = "Listen on This Mac"
    let workspace: OutputWorkspaceRecord
    let hasNativeAudio: Bool
    let hasStandaloneAudio: Bool
    let isReadOnly: Bool

    init?(outputs: OutputCoordinator, workspaceID: UUID?) {
        guard let workspace = outputs.profiles.document.workspaces.first(where: { $0.id == workspaceID }) else { return nil }
        self.workspace = workspace
        hasNativeAudio = outputs.hasOpenNativeOutput(workspace: workspace.id)
        hasStandaloneAudio = outputs.hasStandaloneLocalAudio(workspace: workspace.id)
        isReadOnly = outputs.profiles.recoveryNotice != nil
    }
    var isListening: Bool { workspace.monitorAudioLocally || hasNativeAudio || hasStandaloneAudio }
    var canChange: Bool { !hasNativeAudio && !hasStandaloneAudio && !isReadOnly }
    var scope: String { "Audio for " + workspace.name }
    var detail: String {
        if hasNativeAudio { return "Native projection uses the default macOS audio output." }
        if hasStandaloneAudio { return "Standalone music uses the default macOS audio output." }
        return "Uses the default macOS audio output."
    }
    var help: String {
        "Play video and background music from \(workspace.name) through the default audio output selected in macOS Sound settings. Network output audio is unchanged."
            + (hasNativeAudio ? " Native projection already plays audio locally; the saved listening preference applies to network-only playback." : "")
            + (hasStandaloneAudio ? " Standalone music uses its own Play/Pause controls; the saved listening preference applies to network-only playback." : "")
    }
}


@MainActor
final class OutputQuickControlsController: NSObject, ObservableObject {
    let outputButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let networkButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let appearanceButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let backgroundButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let outputs: OutputCoordinator
    let workspaceID: UUID?
    var store: OutputProfileStore { outputs.profiles }
    let manageOutputs: () -> Void
    private let createBackgroundBookmark: @Sendable (URL) -> String?
    private let makeBackgroundPanel: @MainActor () -> NSOpenPanel
    private let beginBackgroundSheet: @MainActor (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private struct DefaultEntry: Equatable {
        let id: UUID
        let name: String
    }
    private struct SelectionState: Equatable {
        let rows: [DefaultEntry]
        let defaultID: UUID?
        let target: OutputProfileStore.QuickEditTarget?
        let kind: OutputProfile.Kind?
        let network: NetworkOutputSettings?
        let technology: NetworkOutputTechnology?
        let monitors: [ProjectionMonitor]
        let labels: [String]
        let monitorProblems: [String?]
        let locked: Bool
        let problem: String?
        let listening: OutputAudioListeningState?
    }
    private struct AppearanceState: Equatable {
        let target: OutputProfileStore.QuickEditTarget?
        let profile: OutputProfile?
        let canEdit: Bool
    }
    private struct NetworkEntry: Equatable {
        let id: UUID
        let label: String
        let sourceName: String
        let technology: NetworkOutputTechnology
        let workspaceID: UUID?
        let enabled: Bool
    }
    private struct NetworkRoutingState: Equatable {
        let sources: [NetworkEntry]
        let workspaces: [OutputWorkspaceRecord]
        let recoveryNotice: String?
    }
    private var selectionState: SelectionState?
    private var appearanceState: AppearanceState?
    private var networkRoutingState: NetworkRoutingState?
    // Runtime state changes update descriptions on retained native items. Menu
    // identity belongs to the saved routing topology, preserving open menus.
    private var networkMoveActions: [(item: NSMenuItem, destinationID: UUID, workspaceID: UUID)] = []
    private var isRetired = false

    init(outputs: OutputCoordinator, workspaceID: UUID? = nil, manageOutputs: @escaping () -> Void,
         makeBackgroundPanel: @escaping @MainActor () -> NSOpenPanel = { NSOpenPanel() },
         createBackgroundBookmark: @escaping @Sendable (URL) -> String? = { SecurityScopedBookmarks.createBookmark(for: $0) },
         beginBackgroundSheet: @escaping @MainActor (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
             $0.beginSheetModal(for: $1, completionHandler: $2)
         }) {
        self.outputs = outputs; self.workspaceID = workspaceID ?? outputs.focusedWorkspaceID; self.manageOutputs = manageOutputs
        self.createBackgroundBookmark = createBackgroundBookmark
        self.makeBackgroundPanel = makeBackgroundPanel; self.beginBackgroundSheet = beginBackgroundSheet
        super.init()
        for button in [outputButton, networkButton, backgroundButton, appearanceButton] {
            button.bezelStyle = .toolbar
            button.imagePosition = button === outputButton || button === networkButton ? .imageLeft : .imageOnly
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        render()
    }

    func render() {
        guard !isRetired else { return }
        renderNetworkRouting()
        let destination = store.defaultDestination
        let profile = destination.flatMap { store.profile($0.profileID) }
        let target = store.quickEditTarget
        let displays = outputs.displays
        let reason = store.recoveryNotice ?? (destination == nil ? "Choose an appearance editing target to use quick controls."
            : destination?.enabled == false ? "Appearance editing target is disabled."
            : nil)
        let name = destination?.name ?? "None"
        let scope = destination.map { outputs.managementDestinationLabel($0) + " · " + outputs.managementWorkspaceName($0.workspaceID) } ?? "None"
        outputButton.toolTip = "Edit output appearance: \(scope). \(reason ?? "Quick edits affect only this output.")"
        outputButton.setControlAccessibility(label: "Output appearance editing target: \(scope)",
            help: reason ?? "Choose the appearance editing target or edit its monitor assignment.")
        let selection = SelectionState(rows: store.document.destinations.map { DefaultEntry(id: $0.id, name: outputs.managementDestinationLabel($0) + " · " + outputs.managementWorkspaceName($0.workspaceID)) }, defaultID: store.document.defaultDestinationID,
            target: target, kind: profile?.kind, network: destination?.networkSettings, technology: destination?.networkTechnology, monitors: displays.displays,
            labels: displays.displays.map { displays.label(for: $0.target) },
            monitorProblems: displays.displays.map { display in destination.flatMap { outputs.monitorAssignmentProblem(for: display.target, destinationID: $0.id) } },
            locked: destination.map { outputs.isOpen($0.id) } ?? false,
            problem: reason ?? destination?.monitor.flatMap { displays.problem(for: $0) },
            listening: OutputAudioListeningState(outputs: outputs, workspaceID: workspaceID))
        if selection != selectionState {
            selectionState = selection
            let menu = menu(caption: "Output", symbol: "display")
            let defaults = NSMenu(); defaults.autoenablesItems = false
            defaults.addItem(command("None", selected: destination == nil) { [weak self] in self?.store.setDefaultDestination(nil) })
            for row in selection.rows {
                defaults.addItem(command(row.name, selected: row.id == destination?.id) { [weak self] in
                    self?.store.setDefaultDestination(row.id)
                })
            }
            submenu("Edit Output Appearance: \(name)", defaults, in: menu)
            let assignments = NSMenu(); assignments.autoenablesItems = false
            for row in store.document.destinations {
                let owner = outputs.managementWorkspaceName(row.workspaceID)
                let actions = NSMenu(); actions.autoenablesItems = false
                actions.addItem(info("Owner: " + owner))
                actions.addItem(command("Move to This Workspace", enabled: workspaceID != nil && row.workspaceID != workspaceID) { [weak self] in
                    guard let self, let id = self.workspaceID else { return }
                    _ = self.outputs.moveOutput(row.id, toWorkspace: id, reportingTo: id)
                })
                submenu(outputs.managementDestinationLabel(row) + " · " + owner, actions, in: assignments)
            }
            submenu("Workspace Assignments", assignments, in: menu)
            if let reason { menu.addItem(info(reason)) }
            if let settings = destination?.networkSettings, let technology = destination?.networkTechnology {
                menu.addItem(info(technology.title + " source: " + settings.sourceName))
            }
            if let destination, destination.isMonitorDestination, let target {
                let monitors = NSMenu(); monitors.autoenablesItems = false
                monitors.addItem(command("None", enabled: !selection.locked, selected: destination.monitor == nil) { [weak self] in
                    self?.assignMonitor(nil, target: target)
                })
                for display in displays.displays {
                    monitors.addItem(command(displays.label(for: display.target),
                        enabled: !selection.locked && outputs.monitorAssignmentProblem(for: display.target, destinationID: destination.id) == nil,
                        selected: destination.monitor?.identity == display.identity) { [weak self] in
                            self?.assignMonitor(display.target, target: target)
                        })
                }
                submenu("Monitor: " + (destination.monitor.map(displays.label) ?? "None"), monitors, in: menu)
                if let problem = destination.monitor.flatMap({ displays.problem(for: $0) }) { menu.addItem(info(problem)) }

            }
            menu.addItem(.separator())
            if let listening = selection.listening {
                menu.addItem(info(listening.scope))
                let item = command(OutputAudioListeningState.title, enabled: listening.canChange, selected: listening.isListening) { [weak self] in
                    guard let self, let current = OutputAudioListeningState(outputs: self.outputs, workspaceID: self.workspaceID),
                          current.canChange else { return }
                    self.outputs.setMonitorAudioLocally(!current.workspace.monitorAudioLocally, workspace: current.workspace.id)
                    self.render()
                }
                item.toolTip = listening.help
                menu.addItem(item)
                menu.addItem(info(listening.detail))
            }
            addManagementFooter(to: menu)
            outputButton.menu = menu
        }
        let canEdit = target.map { store.canCustomizeProfile(for: $0.destinationID) } ?? false
        let appearance = AppearanceState(target: target, profile: profile, canEdit: canEdit)
        let help: String
        if let recovery = store.recoveryNotice { help = recovery }
        else if destination == nil { help = "Choose an appearance editing target from the Output menu to use these controls." }
        else if destination?.enabled == false { help = "Appearance editing target is disabled. Enable it in Manage Outputs or choose another target from the Output menu." }
        else { help = reason ?? (canEdit ? "Quick edits affect only \(name)." : "The profile limit has been reached. Manage Outputs to edit profiles.") }
        let connection = " Customizing any property makes the whole appearance independent; future reusable-profile changes no longer apply."
        let appearanceHelp = help + connection
        let backgroundHelp = help + connection
        appearanceButton.isEnabled = canEdit; backgroundButton.isEnabled = canEdit
        appearanceButton.toolTip = "Appearance for \(name)\n\(appearanceHelp)"
        backgroundButton.toolTip = "Background for \(name)\n\(backgroundHelp)"
        appearanceButton.setControlAccessibility(label: "Appearance for output: \(scope)", help: appearanceHelp)
        backgroundButton.setControlAccessibility(label: "Background for output: \(scope)", help: backgroundHelp)
        if appearance != appearanceState {
            appearanceState = appearance
            appearanceButton.menu = appearanceMenu(profile, target: target)
            backgroundButton.menu = backgroundMenu(profile, target: target)
        }
    }

    private func renderNetworkRouting() {
        let state = NetworkRoutingState(sources: store.document.destinations.compactMap { row in
            guard let settings = row.networkSettings, let technology = row.networkTechnology else { return nil }
            return .init(id: row.id, label: outputs.managementDestinationLabel(row), sourceName: settings.sourceName,
                         technology: technology, workspaceID: row.workspaceID, enabled: row.enabled)
        }, workspaces: store.document.workspaces, recoveryNotice: store.recoveryNotice)
        guard state != networkRoutingState else { refreshNetworkMoveDescriptions(); return }
        networkRoutingState = state
        networkMoveActions.removeAll()
        let technologies = Set(state.sources.map(\.technology))
        let technologyName = technologies.count == 1 ? technologies.first!.title : "Network"
        func owner(_ id: UUID?) -> String {
            guard let index = state.workspaces.firstIndex(where: { $0.id == id }) else { return "Unassigned" }
            let record = state.workspaces[index]
            return record.name + (state.workspaces.filter { $0.name == record.name }.count > 1 ? " (\(index + 1))" : "")
        }
        let caption: String
        if let source = state.sources.first, state.sources.count == 1 { caption = technologyName + ": " + owner(source.workspaceID) }
        else { caption = state.sources.isEmpty ? technologyName : technologyName + ": \(state.sources.count) outputs" }
        // Bound the visible title using native font metrics. Full workspace and
        // source names remain in the menu, tooltip and accessibility label.
        var title = caption
        let attributes: [NSAttributedString.Key: Any] = [.font: networkButton.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        while (title as NSString).size(withAttributes: attributes).width > 96, title.count > 5 {
            title.removeLast()
        }
        if title != caption { title += "…" }
        let menu = menu(caption: title, symbol: "network", showsTitle: true)
        let summary = state.sources.map {
            (technologies.count > 1 ? $0.technology.title + ": " : "") + $0.sourceName + " → " + owner($0.workspaceID)
                + ($0.enabled ? "" : " (Disabled)")
        }.joined(separator: "\n")
        let help = state.recoveryNotice ?? (state.sources.isEmpty
            ? "Add an NDI or OMT output in Manage Outputs to route it between workspaces."
            : "Choose a workspace’s Current for " + technologyName + " output. A live move keeps the source name and receiver connection; a stopped output stays stopped.")
        networkButton.toolTip = [summary, help].filter { !$0.isEmpty }.joined(separator: "\n")
        networkButton.setControlAccessibility(label: technologyName + " workspace routing" + (summary.isEmpty ? "" : ": " + summary), help: help)
        if state.sources.isEmpty { menu.addItem(info("No network outputs configured.")) }
        for (index, source) in state.sources.enumerated() {
            let choices = state.sources.count == 1 ? menu : NSMenu()
            choices.autoenablesItems = false
            choices.addItem(info(source.technology.title + " source: " + source.sourceName + (source.enabled ? "" : " · Disabled")))
            choices.addItem(info("Current from: " + owner(source.workspaceID)))
            for workspace in state.workspaces {
                let action = command("Move to " + owner(workspace.id),
                    enabled: state.recoveryNotice == nil && source.workspaceID != workspace.id,
                    selected: source.workspaceID == workspace.id) { [weak self] in
                        self?.moveNetworkOutput(source.id, technology: source.technology, to: workspace.id)
                    }
                networkMoveActions.append((action, source.id, workspace.id))
                choices.addItem(action)
            }
            if state.sources.count > 1 {
                let duplicate = state.sources.filter { $0.label == source.label && $0.technology == source.technology }.count > 1
                let label = (technologies.count > 1 ? source.technology.title + " · " : "") + source.label
                submenu(label + (duplicate ? " (\(index + 1))" : "") + " → " + owner(source.workspaceID), choices, in: menu)
            }
        }
        if let notice = state.recoveryNotice { menu.addItem(info(notice)) }
        addManagementFooter(to: menu)
        networkButton.menu = menu
        refreshNetworkMoveDescriptions()
    }

    private func refreshNetworkMoveDescriptions() {
        for action in networkMoveActions {
            action.item.toolTip = outputs.isOpen(action.destinationID)
                ? "Moves this live source to " + outputs.managementWorkspaceName(action.workspaceID) + "’s Current immediately."
                    + (outputs.preparedSession(workspace: action.workspaceID)?.isEmpty != false ? " The target Current is empty." : "")
                : "Changes assignment; this output remains stopped."
        }
    }

    private func moveNetworkOutput(_ destinationID: UUID, technology: NetworkOutputTechnology, to targetWorkspaceID: UUID) {
        // Revalidate retained menu actions before preparing a session. Removed
        // workspaces and destinations must never be recreated by a stale menu.
        guard outputs.destination(destinationID)?.networkTechnology == technology else { return }
        _ = outputs.moveOutput(destinationID, toWorkspace: targetWorkspaceID, reportingTo: workspaceID)
        render()
    }

    func assignMonitor(_ monitor: ProjectionMonitorTarget?, target: OutputProfileStore.QuickEditTarget) {
        guard let destination = store.enabledDefault(for: target) else { return }
        outputs.assignMonitor(monitor, to: destination.id)
    }
    private func appearanceMenu(_ profile: OutputProfile?, target: OutputProfileStore.QuickEditTarget?) -> NSMenu {
        let menu = menu(caption: "Appearance", symbol: "textformat")
        defer { addManagementFooter(to: menu) }
        guard let profile, let target else { return menu }
        menu.addItem(info("Edits this output’s complete independent appearance; future reusable-profile changes no longer apply."))
        for (title, key, values) in [
            ("Layout", \OutputProfile.layout, [("Stacked", "stacked"), ("Columns", "columns")]),
            ("Alignment", \OutputProfile.alignment, [("Left", "left"), ("Centre", "center"), ("Right", "right")]),
            ("Position", \OutputProfile.position, [("Top", "top"), ("Middle", "middle"), ("Bottom", "bottom")])
        ] {
            let choices = NSMenu(); choices.autoenablesItems = false
            for (label, value) in values {
                choices.addItem(edit(label, target, selected: profile[keyPath: key] == value) { $0[keyPath: key] = value })
            }
            submenu(title, choices, in: menu)
        }
        let components = NSMenu(); components.autoenablesItems = false
        for role in OutputComponentRole.lyricRoles {
            components.addItem(edit(role.title, target, selected: profile.roles.contains(role)) { value in
                if value.roles.contains(role) { value.roles.removeAll { $0 == role } } else { value.roles.append(role) }
            })
        }
        submenu("Text Components", components, in: menu)
        let sizes = NSMenu(); sizes.autoenablesItems = false
        let presets: [Double] = [32, 40, 48, 64, 72, 84, 96, 120, 144, 168]
        func points(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(0...2))) + " pt" }
        if !presets.contains(profile.typography.size) {
            let current = info(points(profile.typography.size) + " (Current)")
            current.state = .on; sizes.addItem(current)
        }
        var candidate = store.document
        if let index = candidate.profiles.firstIndex(where: { $0.id == profile.id }) {
            for size in presets {
                // Use the same validation as Settings, including relative
                // component sizes, rather than offering choices that cannot save.
                candidate.profiles[index].typography.size = size
                let item = edit(points(size), target, enabled: candidate.isValid, selected: profile.typography.size == size) { $0.typography.size = size }
                if !item.isEnabled { item.toolTip = "A component font would fall outside the supported 1–800 point range." }
                sizes.addItem(item)
            }
        }
        submenu("Font Size", sizes, in: menu)
        let padding = NSMenu(); padding.autoenablesItems = false
        for percent in stride(from: 0, through: 200, by: 25) {
            padding.addItem(edit("\(percent)%", target, selected: abs(profile.padding * 100 - Double(percent)) < 0.01) { $0.padding = Double(percent) / 100 })
        }
        submenu("Lyrics Padding", padding, in: menu)
        return menu
    }
    private func backgroundMenu(_ profile: OutputProfile?, target: OutputProfileStore.QuickEditTarget?) -> NSMenu {
        let menu = menu(caption: "Background", symbol: "photo.on.rectangle")
        defer { addManagementFooter(to: menu) }
        guard let profile, let target else { return menu }
        menu.addItem(info("Edits this output’s complete independent appearance; future reusable-profile changes no longer apply."))
        menu.addItem(command("Choose Visual…") { [weak self] in self?.chooseBackground(target) })
        menu.addItem(edit("Clear Visual", target) { $0.background.bookmark = nil })
        menu.addItem(edit("Visual Enabled", target, selected: profile.background.visible) { $0.background.visible.toggle() })
        for (title, key) in [("Show Behind Text", \OutputBackground.whenTextShown), ("Show When Slides Hidden", \OutputBackground.whenHidden), ("Show Behind Media", \OutputBackground.whenMediaShown)] {
            menu.addItem(edit(title, target, selected: profile.background[keyPath: key]) { $0.background[keyPath: key].toggle() })
        }
        let fit = NSMenu(); fit.autoenablesItems = false
        for value in ["fill", "fit"] {
            fit.addItem(edit(value.capitalized, target, selected: profile.background.fit == value) { $0.background.fit = value })
        }
        submenu("Fit", fit, in: menu)
        return menu
    }
    private func chooseBackground(_ target: OutputProfileStore.QuickEditTarget) {
        guard !isRetired,
              let destination = store.enabledDefault(for: target), store.profile(destination.profileID) != nil,
              let window = backgroundButton.window, window.attachedSheet == nil else { return }
        let store = store
        let outputs = outputs
        let createBackgroundBookmark = createBackgroundBookmark
        guard let requestingWorkspaceID = workspaceID ?? destination.workspaceID,
              store.document.workspaces.contains(where: { $0.id == requestingWorkspaceID }) else { return }
        if let problem = store.profileCustomizationProblem(for: destination.id) {
            outputs.reportAppearanceEditIssue(problem, workspace: requestingWorkspaceID)
            return
        }
        let panel = makeBackgroundPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie]
        // Creating an AppKit panel may run a nested event loop. The controls,
        // requesting workspace and default output must still be the same.
        guard !isRetired, backgroundButton.window === window, window.attachedSheet == nil,
              store.document.workspaces.contains(where: { $0.id == requestingWorkspaceID }),
              store.enabledDefault(for: target) != nil else { return }
        beginBackgroundSheet(panel, window) { [weak self] result in
            guard self?.isRetired == false, result == .OK, let url = panel.url else { return }
            // Accepting the native selection transfers preparation to the app's
            // store/output owners. Closing controls after this admission must
            // not discard an explicitly accepted background choice.
            let fileAcquisitionGuard = outputs.makeFileAcquisitionGuard(for: url)
            Task { @MainActor in
                let bookmark = await Task.detached { createBackgroundBookmark(url) }.value
                guard store.document.workspaces.contains(where: { $0.id == requestingWorkspaceID }) else { return }
                guard case .allowed = fileAcquisitionGuard(url) else {
                    outputs.reportFileActionIssue("The selected file changed while it was being prepared. Choose it again.",
                                                 workspace: requestingWorkspaceID)
                    return
                }
                guard let bookmark else {
                    outputs.reportAppearanceEditIssue("The selected background could not be saved. Choose Visual again to retry; the existing background is unchanged.", workspace: requestingWorkspaceID)
                    return
                }
                let problem = store.editDefaultProfile(target) { $0.background.bookmark = bookmark }
                outputs.reportAppearanceEditIssue(problem, workspace: requestingWorkspaceID)
            }
        }
    }
    private func addManagementFooter(to menu: NSMenu) {
        if menu.items.last?.isSeparatorItem != true { menu.addItem(.separator()) }
        menu.addItem(command("Manage Outputs…") { [weak self] in self?.manageOutputs() })
    }
    private func menu(caption: String, symbol: String, showsTitle: Bool = false) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let label = NSMenuItem(title: caption, action: nil, keyEquivalent: "")
        label.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(label)
        if caption != "Output" && !showsTitle {
            // Pull-down buttons display their first item's image; the remaining
            // items retain complete labels and native keyboard/menu behavior.
            label.title = ""
        }
        return menu
    }
    private func info(_ title: String) -> NSMenuItem { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); item.isEnabled = false; return item }
    private func submenu(_ title: String, _ submenu: NSMenu, in menu: NSMenu, enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu; item.isEnabled = enabled; menu.addItem(item)
    }
    private func edit(_ title: String, _ target: OutputProfileStore.QuickEditTarget, enabled: Bool = true, selected: Bool = false,
                      change: @escaping (inout OutputProfile) -> Void) -> NSMenuItem {
        command(title, enabled: enabled, selected: selected) { [weak self] in
            guard let self,
                  let requestingWorkspaceID = self.workspaceID ?? self.store.enabledDefault(for: target)?.workspaceID,
                  self.store.document.workspaces.contains(where: { $0.id == requestingWorkspaceID }) else { return }
            let problem = self.store.editDefaultProfile(target, change)
            self.outputs.reportAppearanceEditIssue(problem, workspace: requestingWorkspaceID)
            self.render()
        }
    }
    private func command(_ title: String, enabled: Bool = true, selected: Bool = false, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = Command(action); item.isEnabled = enabled; item.state = selected ? .on : .off
        return item
    }
    func retire() {
        isRetired = true
        for button in [outputButton, networkButton, appearanceButton, backgroundButton] { button.isEnabled = false }
    }
    @objc private func performCommand(_ sender: NSMenuItem) {
        guard !isRetired else { return }
        (sender.representedObject as? Command)?.action()
    }
    private final class Command {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }
}
