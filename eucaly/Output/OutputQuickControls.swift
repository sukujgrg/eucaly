import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Native intrinsic sizes keep the toolbar independent of destination-name length.
/// The controls and their menus survive unrelated output/status view updates.
struct OutputQuickControls: View {
    @StateObject private var controls: OutputQuickControlsController
    let manageOutputs: () -> Void
    init(outputs: OutputCoordinator, workspaceID: UUID? = nil, manageOutputs: @escaping () -> Void) {
        self.manageOutputs = manageOutputs
        _controls = StateObject(wrappedValue: OutputQuickControlsController(outputs: outputs, workspaceID: workspaceID, manageOutputs: manageOutputs))
    }
    var body: some View {
        HStack(spacing: 8) {
            OutputQuickButton(button: controls.outputButton, controls: controls, manageOutputs: manageOutputs)
            OutputQuickButton(button: controls.ndiButton, controls: controls, manageOutputs: manageOutputs)
            OutputQuickButton(button: controls.backgroundButton, controls: controls, manageOutputs: manageOutputs)
            OutputQuickButton(button: controls.appearanceButton, controls: controls, manageOutputs: manageOutputs)
        }.fixedSize()
    }
}

private struct OutputQuickButton: NSViewRepresentable {
    let button: NSPopUpButton
    let controls: OutputQuickControlsController
    let manageOutputs: () -> Void
    @ObservedObject private var outputs: OutputCoordinator
    @ObservedObject private var store: OutputProfileStore
    @ObservedObject private var displays: ProjectionDisplayManager
    init(button: NSPopUpButton, controls: OutputQuickControlsController, manageOutputs: @escaping () -> Void) {
        self.button = button; self.controls = controls; self.manageOutputs = manageOutputs
        outputs = controls.outputs; store = controls.store; displays = controls.outputs.displays
    }
    func makeNSView(context: Context) -> NSPopUpButton { button }
    func updateNSView(_ view: NSPopUpButton, context: Context) {
        controls.manageOutputs = manageOutputs; controls.render()
    }
}

@MainActor
final class OutputQuickControlsController: NSObject, ObservableObject {
    let outputButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let ndiButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let appearanceButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let backgroundButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let outputs: OutputCoordinator
    let workspaceID: UUID?
    var store: OutputProfileStore { outputs.profiles }
    var manageOutputs: () -> Void
    private struct DefaultEntry: Equatable {
        let id: UUID
        let name: String
    }
    private struct SelectionState: Equatable {
        let rows: [DefaultEntry]
        let defaultID: UUID?
        let target: OutputProfileStore.QuickEditTarget?
        let kind: OutputProfile.Kind?
        let ndi: NDIOutputSettings?
        let monitors: [ProjectionMonitor]
        let labels: [String]
        let monitorProblems: [String?]
        let locked: Bool
        let problem: String?
    }
    private struct AppearanceState: Equatable {
        let target: OutputProfileStore.QuickEditTarget?
        let profile: OutputProfile?
        let canEdit: Bool
    }
    private struct NDIEntry: Equatable {
        let id: UUID
        let label: String
        let sourceName: String
        let workspaceID: UUID?
        let enabled: Bool
    }
    private struct NDIRoutingState: Equatable {
        let sources: [NDIEntry]
        let workspaces: [OutputWorkspaceRecord]
        let recoveryNotice: String?
    }
    private var selectionState: SelectionState?
    private var appearanceState: AppearanceState?
    private var ndiRoutingState: NDIRoutingState?

    init(outputs: OutputCoordinator, workspaceID: UUID? = nil, manageOutputs: @escaping () -> Void) {
        self.outputs = outputs; self.workspaceID = workspaceID ?? outputs.focusedWorkspaceID; self.manageOutputs = manageOutputs
        super.init()
        for button in [outputButton, ndiButton, backgroundButton, appearanceButton] {
            button.bezelStyle = .rounded
            button.imagePosition = button === outputButton || button === ndiButton ? .imageLeft : .imageOnly
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        render()
    }

    func render() {
        renderNDIRouting()
        let destination = store.defaultDestination
        let profile = destination.flatMap { store.profile($0.profileID) }
        let target = store.quickEditTarget
        let displays = outputs.displays
        let reason = store.recoveryNotice ?? (destination == nil ? "Choose a default output to use quick controls."
            : destination?.enabled == false ? "Default output is disabled."
            : nil)
        let name = destination?.name ?? "None"
        outputButton.toolTip = "Default output: \(name). \(reason ?? "Quick edits affect only this output.")"
        outputButton.setAccessibilityLabel("Output, default: \(name)")
        outputButton.setAccessibilityHelp(reason ?? "Choose the default output or edit its monitor assignment.")
        let selection = SelectionState(rows: store.document.destinations.map { DefaultEntry(id: $0.id, name: store.destinationLabel($0) + " · " + store.workspaceName($0.workspaceID)) }, defaultID: store.document.defaultDestinationID,
            target: target, kind: profile?.kind, ndi: destination?.ndi, monitors: displays.displays,
            labels: displays.displays.map { displays.label(for: $0.target) },
            monitorProblems: displays.displays.map { display in destination.flatMap { outputs.monitorAssignmentProblem(for: display.target, destinationID: $0.id) } },
            locked: destination.map { outputs.isOpen($0.id) } ?? false,
            problem: reason ?? destination?.monitor.flatMap { displays.problem(for: $0) })
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
            submenu("Default: \(name)", defaults, in: menu)
            let assignments = NSMenu(); assignments.autoenablesItems = false
            for row in store.document.destinations {
                let owner = store.workspaceName(row.workspaceID)
                let actions = NSMenu(); actions.autoenablesItems = false
                actions.addItem(info("Owner: " + owner))
                actions.addItem(command("Move to This Workspace", enabled: workspaceID != nil && row.workspaceID != workspaceID) { [weak self] in
                    guard let self, let id = self.workspaceID else { return }
                    _ = self.outputs.moveOutput(row.id, toWorkspace: id, reportingTo: id)
                })
                submenu(store.destinationLabel(row) + " · " + owner, actions, in: assignments)
            }
            submenu("Workspace Assignments", assignments, in: menu)
            if let reason { menu.addItem(info(reason)) }
            if let ndi = destination?.ndi { menu.addItem(info("NDI source: " + ndi.sourceName)) }
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
            menu.addItem(command("Manage Outputs…") { [weak self] in self?.manageOutputs() })
            outputButton.menu = menu
        }
        let canEdit = target.map { store.canCustomizeProfile(for: $0.destinationID) } ?? false
        let appearance = AppearanceState(target: target, profile: profile, canEdit: canEdit)
        let help: String
        if let recovery = store.recoveryNotice { help = recovery }
        else if destination == nil { help = "Choose a default output from the Output menu to use these controls." }
        else if destination?.enabled == false { help = "Default output is disabled. Enable it in Manage Outputs or choose another default from the Output menu." }
        else { help = reason ?? (canEdit ? "Quick edits affect only \(name)." : "The profile limit has been reached. Manage Outputs to edit profiles.") }
        let appearanceHelp = help
        let backgroundHelp = help
        appearanceButton.isEnabled = canEdit; backgroundButton.isEnabled = canEdit
        appearanceButton.toolTip = "Appearance for \(name)\n\(appearanceHelp)"
        backgroundButton.toolTip = "Background for \(name)\n\(backgroundHelp)"
        appearanceButton.setAccessibilityLabel("Appearance for default output: \(name)")
        backgroundButton.setAccessibilityLabel("Background for default output: \(name)")
        appearanceButton.setAccessibilityHelp(appearanceHelp)
        backgroundButton.setAccessibilityHelp(backgroundHelp)
        if appearance != appearanceState {
            appearanceState = appearance
            appearanceButton.menu = appearanceMenu(profile, target: target)
            backgroundButton.menu = backgroundMenu(profile, target: target)
        }
    }

    private func renderNDIRouting() {
        let state = NDIRoutingState(sources: store.document.destinations.compactMap { row in
            row.ndi.map { .init(id: row.id, label: store.destinationLabel(row), sourceName: $0.sourceName,
                              workspaceID: row.workspaceID, enabled: row.enabled) }
        }, workspaces: store.document.workspaces, recoveryNotice: store.recoveryNotice)
        guard state != ndiRoutingState else { return }
        ndiRoutingState = state
        func owner(_ id: UUID?) -> String {
            guard let index = state.workspaces.firstIndex(where: { $0.id == id }) else { return "Unassigned" }
            let record = state.workspaces[index]
            return record.name + (state.workspaces.filter { $0.name == record.name }.count > 1 ? " (\(index + 1))" : "")
        }
        let caption: String
        if let source = state.sources.first, state.sources.count == 1 { caption = "NDI: " + owner(source.workspaceID) }
        else { caption = state.sources.isEmpty ? "NDI" : "NDI: \(state.sources.count) outputs" }
        // Bound the visible title using native font metrics. Full workspace and
        // source names remain in the menu, tooltip and accessibility label.
        var title = caption
        let attributes: [NSAttributedString.Key: Any] = [.font: ndiButton.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)]
        while (title as NSString).size(withAttributes: attributes).width > 96, title.count > 5 {
            title.removeLast()
        }
        if title != caption { title += "…" }
        let menu = menu(caption: title, symbol: "network", showsTitle: true)
        let summary = state.sources.map { $0.sourceName + " → " + owner($0.workspaceID) + ($0.enabled ? "" : " (Disabled)") }.joined(separator: "\n")
        let help = state.recoveryNotice ?? (state.sources.isEmpty
            ? "Add an NDI output in Manage Outputs to route it between workspaces."
            : "Choose a workspace’s Current for NDI. A live move keeps the source name and receiver connection; a stopped output stays stopped.")
        ndiButton.toolTip = [summary, help].filter { !$0.isEmpty }.joined(separator: "\n")
        ndiButton.setAccessibilityLabel("NDI workspace routing" + (summary.isEmpty ? "" : ": " + summary))
        ndiButton.setAccessibilityHelp(help)
        if state.sources.isEmpty { menu.addItem(info("No NDI outputs configured.")) }
        for (index, source) in state.sources.enumerated() {
            let choices = state.sources.count == 1 ? menu : NSMenu()
            choices.autoenablesItems = false
            choices.addItem(info("Source: " + source.sourceName + (source.enabled ? "" : " · Disabled")))
            choices.addItem(info("Current from: " + owner(source.workspaceID)))
            for workspace in state.workspaces {
                choices.addItem(command("Move to " + owner(workspace.id),
                    enabled: state.recoveryNotice == nil && source.workspaceID != workspace.id,
                    selected: source.workspaceID == workspace.id) { [weak self] in
                        self?.moveNDIOutput(source.id, to: workspace.id)
                    })
            }
            if state.sources.count > 1 {
                let duplicate = state.sources.filter { $0.label == source.label }.count > 1
                submenu(source.label + (duplicate ? " (\(index + 1))" : "") + " → " + owner(source.workspaceID), choices, in: menu)
            }
        }
        if let notice = state.recoveryNotice { menu.addItem(info(notice)) }
        menu.addItem(.separator())
        menu.addItem(command("Manage Outputs…") { [weak self] in self?.manageOutputs() })
        ndiButton.menu = menu
    }

    private func moveNDIOutput(_ destinationID: UUID, to targetWorkspaceID: UUID) {
        // Revalidate retained menu actions before preparing a session. Removed
        // workspaces and destinations must never be recreated by a stale menu.
        guard outputs.destination(destinationID)?.ndi != nil else { return }
        _ = outputs.moveOutput(destinationID, toWorkspace: targetWorkspaceID, reportingTo: workspaceID)
        render()
    }

    func assignMonitor(_ monitor: ProjectionMonitorTarget?, target: OutputProfileStore.QuickEditTarget) {
        guard let destination = store.enabledDefault(for: target) else { return }
        outputs.assignMonitor(monitor, to: destination.id)
    }
    private func appearanceMenu(_ profile: OutputProfile?, target: OutputProfileStore.QuickEditTarget?) -> NSMenu {
        let menu = menu(caption: "Appearance", symbol: "textformat")
        guard let profile, let target else { return menu }
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
        guard let profile, let target else { return menu }
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
        guard let destination = store.enabledDefault(for: target), store.profile(destination.profileID) != nil,
              let window = backgroundButton.window, window.attachedSheet == nil else { return }
        let store = store
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image, .movie]
        panel.beginSheetModal(for: window) { result in
            guard result == .OK, let url = panel.url else { return }
            Task { @MainActor in
                let bookmark = await Task.detached { SecurityScopedBookmarks.createBookmark(for: url) }.value
                if let bookmark { store.editDefaultProfile(target) { $0.background.bookmark = bookmark } }
            }
        }
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
        command(title, enabled: enabled, selected: selected) { [weak self] in self?.store.editDefaultProfile(target, change) }
    }
    private func command(_ title: String, enabled: Bool = true, selected: Bool = false, action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(performCommand(_:)), keyEquivalent: "")
        item.target = self; item.representedObject = Command(action); item.isEnabled = enabled; item.state = selected ? .on : .off
        return item
    }
    @objc private func performCommand(_ sender: NSMenuItem) { (sender.representedObject as? Command)?.action() }
    private final class Command {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
    }
}
