import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// Menubar Output describes the workspace listening preference.
/// Native projection and explicitly requested standalone music retain their
/// local audio; the menu explains those routes without changing the preference.
@MainActor
struct OutputAudioListeningState: Equatable {
    static let title = "Listen on This Mac"
    static let sectionTitle = "Audio"
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
    /// Scope and detail stay on the toggle via help instead of disabled menu rows.
    var menuHelp: String { scope + ". " + detail + " " + help }

    func applyHelp(to item: NSMenuItem) {
        item.toolTip = menuHelp
        item.setAccessibilityHelp(menuHelp)
    }
}


@MainActor
final class OutputQuickControlsController: NSObject, ObservableObject {
    let networkButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let appearanceButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let backgroundButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let outputs: OutputCoordinator
    let workspaceID: UUID?
    var store: OutputProfileStore { outputs.profiles }
    let manageOutputs: () -> Void
    let manageProfiles: () -> Void
    private let createBackgroundBookmark: @Sendable (URL) -> String?
    private let makeBackgroundPanel: @MainActor () -> NSOpenPanel
    private let beginBackgroundSheet: @MainActor (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private struct DefaultEntry: Equatable {
        let id: UUID
        let shortTitle: String
        let detailTitle: String
    }
    private struct AppearanceState: Equatable {
        let rows: [DefaultEntry]
        let defaultID: UUID?
        let target: OutputProfileStore.QuickEditTarget?
        let profile: OutputProfile?
        let canEdit: Bool
        let reason: String?
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
    private var appearanceState: AppearanceState?
    private var networkRoutingState: NetworkRoutingState?
    // Runtime state changes update descriptions on retained native items. Menu
    // identity belongs to the saved routing topology, preserving open menus.
    private var networkMoveActions: [(item: NSMenuItem, destinationID: UUID, workspaceID: UUID)] = []
    private var isRetired = false

    init(outputs: OutputCoordinator, workspaceID: UUID? = nil, manageOutputs: @escaping () -> Void,
         manageProfiles: @escaping () -> Void = {},
         makeBackgroundPanel: @escaping @MainActor () -> NSOpenPanel = { NSOpenPanel() },
         createBackgroundBookmark: @escaping @Sendable (URL) -> String? = { SecurityScopedBookmarks.createBookmark(for: $0) },
         beginBackgroundSheet: @escaping @MainActor (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
             $0.beginSheetModal(for: $1, completionHandler: $2)
         }) {
        self.outputs = outputs
        self.workspaceID = workspaceID ?? outputs.focusedWorkspaceID
        self.manageOutputs = manageOutputs
        self.manageProfiles = manageProfiles
        self.createBackgroundBookmark = createBackgroundBookmark
        self.makeBackgroundPanel = makeBackgroundPanel
        self.beginBackgroundSheet = beginBackgroundSheet
        super.init()
        for button in [networkButton, backgroundButton, appearanceButton] {
            button.bezelStyle = .toolbar
            // Network and Background show identity beside the symbol; Appearance stays icon-only.
            button.imagePosition = button === appearanceButton ? .imageOnly : .imageLeft
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
        let profileName = destination.flatMap { store.profile($0.profileID)?.name } ?? "None"
        let reason = store.recoveryNotice ?? (destination == nil ? "Choose a Profile Target to use quick controls."
            : destination?.enabled == false ? "Profile Target is disabled."
            : nil)
        let name = destination?.name ?? "None"
        let scope = destination.map(accessibilityDestinationTitle) ?? "None"
        let rows = store.document.destinations.map { row in
            DefaultEntry(id: row.id, shortTitle: shortDestinationTitle(row), detailTitle: accessibilityDestinationTitle(row))
        }
        let canEdit = target != nil
        let appearance = AppearanceState(rows: rows, defaultID: store.document.defaultDestinationID, target: target,
                                         profile: profile, canEdit: canEdit, reason: reason)
        let appearanceHelp: String
        if let recovery = store.recoveryNotice { appearanceHelp = recovery }
        else if destination == nil { appearanceHelp = "Choose a Profile Target in this menu to use Appearance and Background quick controls." }
        else if destination?.enabled == false {
            appearanceHelp = "Profile Target is disabled. Enable it in Manage Outputs or choose another target in this menu."
        } else {
            appearanceHelp = reason ?? "Quick edits change profile “\(profileName)” for every output using it. Duplicate the profile in Manage Profiles first if you need an independent look."
        }
        // Appearance stays openable so operators can pick a Profile Target; Background
        // waits for a usable target. Recovery freezes both until the document is healthy.
        let appearanceOpenable = store.recoveryNotice == nil
        appearanceButton.isEnabled = appearanceOpenable
        backgroundButton.isEnabled = canEdit
        appearanceButton.toolTip = "Profile for \(name)\n\(appearanceHelp)"
        let backgroundSummary = backgroundSummary(for: profile)
        let backgroundHelp: String
        if canEdit {
            backgroundHelp = backgroundSummary + "\n" + appearanceHelp
        } else if store.recoveryNotice != nil {
            backgroundHelp = appearanceHelp
        } else {
            backgroundHelp = "Choose a Profile Target from the Appearance menu to edit backgrounds."
        }
        backgroundButton.toolTip = "Background for \(name)\n\(backgroundHelp)"
        appearanceButton.setControlAccessibility(label: "Profile for output: \(scope)", help: appearanceHelp)
        backgroundButton.setControlAccessibility(label: "Background for output: \(scope)", help: backgroundHelp)
        if appearance != appearanceState {
            appearanceState = appearance
            appearanceButton.menu = appearanceMenu(profileName: profileName, destination: destination, rows: rows,
                                                   profile: profile, target: target, canEdit: canEdit)
            backgroundButton.menu = backgroundMenu(profile, target: target, summary: backgroundSummary)
        }
    }

    private func appendProfileTarget(to menu: NSMenu, profileName: String, destination: OutputDestinationConfiguration?, rows: [DefaultEntry]) {
        menu.addItem(section("Profile Target"))
        let defaults = NSMenu(); defaults.autoenablesItems = false
        defaults.addItem(command("None", selected: destination == nil) { [weak self] in
            self?.store.setDefaultDestination(nil)
            self?.render()
        })
        for row in rows {
            let item = command(row.shortTitle, selected: row.id == destination?.id) { [weak self] in
                self?.store.setDefaultDestination(row.id)
                self?.render()
            }
            annotate(item, help: "Use \(row.detailTitle) as the Profile Target for Appearance and Background quick edits.")
            defaults.addItem(item)
        }
        submenu(profileName, defaults, in: menu)
        if let reason = store.recoveryNotice ?? (destination == nil ? "Choose a Profile Target to use quick controls."
            : destination?.enabled == false ? "Profile Target is disabled." : nil) {
            menu.addItem(status(reason))
        }
    }

    private func renderNetworkRouting() {
        let state = NetworkRoutingState(sources: store.document.destinations.compactMap { row in
            guard let settings = row.networkSettings, let technology = row.networkTechnology else { return nil }
            return .init(id: row.id, label: shortDestinationTitle(row), sourceName: settings.sourceName,
                         technology: technology, workspaceID: row.workspaceID, enabled: row.enabled)
        }, workspaces: store.document.workspaces, recoveryNotice: store.recoveryNotice)
        guard state != networkRoutingState else { refreshNetworkMoveDescriptions(); return }
        networkRoutingState = state
        networkMoveActions.removeAll()
        let technologies = Set(state.sources.map(\.technology))
        let technologyName = technologies.count == 1 ? technologies.first!.title : "Network"
        func owner(_ id: UUID?) -> String {
            outputs.managementWorkspaceName(id)
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
        if state.sources.isEmpty { menu.addItem(status("No network outputs configured.")) }
        for (index, source) in state.sources.enumerated() {
            let choices = state.sources.count == 1 ? menu : NSMenu()
            choices.autoenablesItems = false
            let sourceHeading = source.technology.title + " · " + source.sourceName + (source.enabled ? "" : " · Disabled")
            choices.addItem(section(sourceHeading))
            for workspace in state.workspaces {
                let action = command("Move to " + owner(workspace.id),
                    enabled: state.recoveryNotice == nil && source.workspaceID != workspace.id,
                    selected: source.workspaceID == workspace.id) { [weak self] in
                        self?.moveNetworkOutput(source.id, technology: source.technology, to: workspace.id)
                    }
                annotate(action, help: "Current from: " + owner(source.workspaceID) + ". Route " + source.sourceName + " to " + owner(workspace.id) + "’s Current.")
                networkMoveActions.append((action, source.id, workspace.id))
                choices.addItem(action)
            }
            if state.sources.count > 1 {
                let duplicate = state.sources.filter { $0.label == source.label && $0.technology == source.technology }.count > 1
                let label = (technologies.count > 1 ? source.technology.title + " · " : "") + source.label
                submenu(label + (duplicate ? " (\(index + 1))" : "") + " → " + owner(source.workspaceID), choices, in: menu)
            }
        }
        if let notice = state.recoveryNotice { menu.addItem(status(notice)) }
        addManagementFooter(to: menu, target: .outputs)
        networkButton.menu = menu
        refreshNetworkMoveDescriptions()
    }

    private func refreshNetworkMoveDescriptions() {
        for action in networkMoveActions {
            let tooltip = outputs.isOpen(action.destinationID)
                ? "Moves this live source to " + outputs.managementWorkspaceName(action.workspaceID) + "’s Current immediately."
                    + (outputs.preparedSession(workspace: action.workspaceID)?.isEmpty != false ? " The target Current is empty." : "")
                : "Changes assignment; this output remains stopped."
            action.item.toolTip = tooltip
            action.item.setAccessibilityHelp(tooltip)
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
    private func appearanceMenu(profileName: String, destination: OutputDestinationConfiguration?, rows: [DefaultEntry],
                                profile: OutputProfile?, target: OutputProfileStore.QuickEditTarget?, canEdit: Bool) -> NSMenu {
        let menu = menu(caption: "Appearance", symbol: "textformat")
        appendProfileTarget(to: menu, profileName: profileName, destination: destination, rows: rows)
        defer { addManagementFooter(to: menu, target: .profiles) }
        guard canEdit, let profile, let target else { return menu }
        menu.addItem(.separator())
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
            let current = status(points(profile.typography.size) + " (Current)")
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
        let paddingPresets = Array(stride(from: 0, through: 200, by: 25))
        let paddingPercent = profile.padding * 100
        if !paddingPresets.contains(where: { abs(paddingPercent - Double($0)) < 0.01 }) {
            let label = paddingPercent == paddingPercent.rounded()
                ? "\(Int(paddingPercent))% (Current)"
                : String(format: "%.1f%% (Current)", paddingPercent)
            let current = status(label)
            current.state = .on; padding.addItem(current)
        }
        for percent in paddingPresets {
            padding.addItem(edit("\(percent)%", target, selected: abs(paddingPercent - Double(percent)) < 0.01) { $0.padding = Double(percent) / 100 })
        }
        submenu("Lyrics Padding", padding, in: menu)
        return menu
    }
    private func backgroundSummary(for profile: OutputProfile?) -> String {
        guard let profile else { return "Solid colour" }
        if let name = profile.background.displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
           profile.background.bookmark != nil {
            return name
        }
        if profile.background.bookmark != nil { return "Selected image or video" }
        return "Solid colour"
    }
    private func backgroundMenu(_ profile: OutputProfile?, target: OutputProfileStore.QuickEditTarget?,
                                summary: String) -> NSMenu {
        // Pull-down first item is the visible button title — keep the current asset there.
        let menu = menu(caption: summary, symbol: "photo.on.rectangle", showsTitle: true)
        defer { addManagementFooter(to: menu, target: .profiles) }
        guard let profile, let target else { return menu }
        let hasVisual = profile.background.bookmark != nil
        menu.addItem(command("Choose…") { [weak self] in self?.chooseBackground(target) })
        menu.addItem(edit("Clear", target, enabled: hasVisual) { $0.clearBackground() })
        menu.addItem(edit("Enabled", target, selected: profile.background.visible) { $0.background.visible.toggle() })
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
                    outputs.reportAppearanceEditIssue("The selected background could not be saved. Choose again to retry; the existing background is unchanged.", workspace: requestingWorkspaceID)
                    return
                }
                let problem = store.editDefaultProfile(target) {
                    $0.background.bookmark = bookmark
                    $0.background.displayName = url.lastPathComponent
                }
                outputs.reportAppearanceEditIssue(problem, workspace: requestingWorkspaceID)
            }
        }
    }
    private enum ManagementTarget { case outputs, profiles }

    private func addManagementFooter(to menu: NSMenu, target: ManagementTarget) {
        if menu.items.last?.isSeparatorItem != true { menu.addItem(.separator()) }
        switch target {
        case .outputs:
            menu.addItem(command("Manage Outputs…") { [weak self] in self?.manageOutputs() })
        case .profiles:
            menu.addItem(command("Manage Profiles…") { [weak self] in self?.manageProfiles() })
        }
    }
    private func menu(caption: String, symbol: String, showsTitle: Bool = false) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        let label = NSMenuItem(title: caption, action: nil, keyEquivalent: "")
        label.image = NSImage(systemSymbolName: symbol, accessibilityDescription: caption)
        menu.addItem(label)
        if !showsTitle {
            // Pull-down buttons display their first item's image; the remaining
            // items retain complete labels and native keyboard/menu behavior.
            label.title = ""
        }
        return menu
    }
    private func shortDestinationTitle(_ destination: OutputDestinationConfiguration) -> String {
        outputs.managementDestinationLabel(destination)
    }
    private func accessibilityDestinationTitle(_ destination: OutputDestinationConfiguration) -> String {
        shortDestinationTitle(destination) + " · " + outputs.managementWorkspaceName(destination.workspaceID)
    }
    private func section(_ title: String) -> NSMenuItem { .sectionHeader(title: title) }
    private func status(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
    private func annotate(_ item: NSMenuItem, help: String) {
        item.toolTip = help
        item.setAccessibilityHelp(help)
    }
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
        for button in [networkButton, appearanceButton, backgroundButton] { button.isEnabled = false }
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
