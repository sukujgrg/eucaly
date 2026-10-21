import AppKit
import Combine
import SwiftUI

/// The toolbar and menu bar share ordering, labels, availability and actions.
/// The menu bar follows the active controls window; a toolbar keeps its owner.
@MainActor
final class OutputWorkspaceMenuController: NSObject, ObservableObject, NSMenuDelegate, NSMenuItemValidation {
    let menu = NSMenu(title: "Workspace")
    let button = NSPopUpButton(frame: .zero, pullsDown: true)
    let profiles: OutputProfileStore
    let badges: OutputWorkspaceTabBadges
    private weak var workspaces: OutputWorkspaceWindows?
    private let workspaceID: UUID?
    private enum Action: String {
        case new, rename, detach, open, manage
        var title: String {
            switch self {
            case .new: "New Workspace Tab"
            case .rename: "Rename Workspace…"
            case .detach: "Move Tab to New Window"
            case .open: ""
            case .manage: "Manage Workspaces…"
            }
        }
    }
    private var currentID: UUID? { workspaceID ?? workspaces?.activeWorkspaceID }

    init(workspaces: OutputWorkspaceWindows, workspaceID: UUID? = nil) {
        self.workspaces = workspaces; self.workspaceID = workspaceID
        profiles = workspaces.profiles; badges = workspaces.tabBadges
        super.init()
        menu.delegate = self
        menu.autoenablesItems = workspaceID == nil
        button.bezelStyle = .rounded; button.imagePosition = .imageOnly
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        rebuild()
        if workspaceID != nil { button.menu = menu }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        badges.synchronize(profiles.document.workspaces)
        rebuild()
    }
    private func rebuild() {
        menu.removeAllItems()
        if workspaceID != nil { menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: "")) }
        for action in [Action.new, .rename, .detach] { add(action) }
        menu.addItem(.separator())
        for record in profiles.document.workspaces {
            let item = add(.open, title: record.name)
            item.representedObject = record.id
            item.image = badges.badge(for: record.id).menuImage
            item.isEnabled = validateMenuItem(item)
        }
        menu.addItem(.separator())
        add(.manage)
        updateButtonLabel()
    }
    func updateButtonLabel() {
        guard let workspaceID else { return }
        let name = profiles.workspaceName(workspaceID)
        menu.items.first?.title = name
        menu.items.first?.image = badges.badge(for: workspaceID).menuImage
        button.toolTip = name + " — Workspace tabs and windows"
        button.setAccessibilityLabel("Workspace: " + name)
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = action(for: item), let workspaces else { return false }
        let current = currentID.flatMap { id in profiles.document.workspaces.first { $0.id == id } }
        switch action {
        case .new: return workspaces.canCreateWorkspace
        case .rename:
            guard profiles.recoveryNotice == nil, let current, let window = workspaces.controllers[current.id]?.window else { return false }
            return window.attachedSheet == nil
        case .detach: return workspaces.canDetach(current?.id)
        case .open:
            guard let id = item.representedObject as? UUID else { return false }
            item.state = id == currentID ? .on : .off
            return profiles.document.workspaces.contains { $0.id == id }
        case .manage: return true
        }
    }
    private func action(for item: NSMenuItem) -> Action? {
        guard let value = item.identifier?.rawValue, value.hasPrefix("workspace.") else { return nil }
        return Action(rawValue: String(value.dropFirst("workspace.".count)))
    }
    @discardableResult
    private func add(_ action: Action, title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? action.title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.identifier = .init("workspace." + action.rawValue); item.target = self
        item.isEnabled = validateMenuItem(item)
        menu.addItem(item)
        return item
    }
    @objc private func performAction(_ item: NSMenuItem) {
        guard validateMenuItem(item), let action = action(for: item), let workspaces else { return }
        switch action {
        case .new: workspaces.newWorkspace(beside: currentID)
        case .rename: if let id = currentID { workspaces.rename(id) }
        case .detach: if let id = currentID { workspaces.detach(id) }
        case .open:
            if let id = item.representedObject as? UUID, id != currentID { workspaces.open(id, beside: currentID) }
        case .manage: workspaces.manageWorkspaces()
        }
    }
}

struct OutputWorkspaceMenuButton: NSViewRepresentable {
    let controls: OutputWorkspaceMenuController
    @ObservedObject private var profiles: OutputProfileStore
    @ObservedObject private var badges: OutputWorkspaceTabBadges
    init(controls: OutputWorkspaceMenuController) {
        self.controls = controls; profiles = controls.profiles; badges = controls.badges
    }
    func makeNSView(context: Context) -> NSPopUpButton { controls.button }
    func updateNSView(_ view: NSPopUpButton, context: Context) { controls.updateButtonLabel() }
}

/// One native rename interaction and validation rule for controls and Settings.
@MainActor
final class OutputWorkspaceRenamer: NSObject, NSTextFieldDelegate {
    private let profiles: OutputProfileStore
    private var alert: NSAlert?
    private(set) var field: NSTextField?
    init(profiles: OutputProfileStore) { self.profiles = profiles; super.init() }

    func present(workspaceID: UUID, on window: NSWindow, completion: ((String?) -> Void)? = nil) {
        guard profiles.recoveryNotice == nil, alert == nil, window.attachedSheet == nil,
              let record = profiles.document.workspaces.first(where: { $0.id == workspaceID }) else { return }
        let alert = NSAlert(); alert.messageText = "Rename Workspace"
        alert.informativeText = "Choose a short name for this workspace. Its Current and output assignments stay the same."
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.isEnabled = OutputWorkspaceRecord.normalizedName(record.name) != nil
        let field = NSTextField(string: record.name); field.frame = .init(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel("Workspace name"); field.delegate = self
        alert.accessoryView = field
        self.alert = alert; self.field = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            var problem: String?
            if response == .alertFirstButtonReturn {
                self.alert?.window.makeFirstResponder(nil)
                if let name = self.field?.stringValue, !self.profiles.renameWorkspace(workspaceID, name: name) {
                    problem = self.profiles.recoveryNotice ?? "Use a short, non-empty name on one line."
                }
            }
            self.alert = nil; self.field = nil
            completion?(problem)
        }
        alert.window.makeFirstResponder(field)
    }
    func cancel() {
        guard let sheet = alert?.window, let parent = sheet.sheetParent else { return }
        parent.endSheet(sheet, returnCode: .cancel)
    }
    func controlTextDidChange(_ notification: Notification) {
        guard let field else { return }
        alert?.buttons.first?.isEnabled = OutputWorkspaceRecord.normalizedName(field.stringValue) != nil
    }
}

@MainActor
final class OutputWorkspaceCommands {
    private let keyWindow: @MainActor () -> NSWindow?
    init(keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow }) { self.keyWindow = keyWindow }
    weak var window: NSWindow?
    weak var closeConfirmation: (any OutputWorkspaceCloseConfirming)?
    var isActive: Bool { window != nil && window === keyWindow() }
    func confirmClose() -> Bool { closeConfirmation?.confirmClose() ?? true }
    func controlsWillClose() { closeConfirmation?.controlsWillClose() }
}

@MainActor
protocol OutputWorkspaceCloseConfirming: AnyObject {
    func confirmClose() -> Bool
    func controlsWillClose()
}

/// Provides the current editor's close decision to the native window controller,
/// without replacing its delegate or taking ownership of the window lifecycle.
struct OutputWorkspaceCloseConfirmation: NSViewRepresentable {
    let commands: OutputWorkspaceCommands
    let shouldClose: () -> Bool
    var willClose: () -> Void = {}
    func makeNSView(context: Context) -> ConfirmationView {
        let view = ConfirmationView(frame: .zero)
        view.shouldClose = shouldClose
        view.willClose = willClose
        commands.closeConfirmation = view
        return view
    }
    func updateNSView(_ view: ConfirmationView, context: Context) {
        view.shouldClose = shouldClose
        view.willClose = willClose
        commands.closeConfirmation = view
    }

    final class ConfirmationView: NSView, OutputWorkspaceCloseConfirming {
        var shouldClose: () -> Bool = { true }
        var willClose: () -> Void = {}
        func confirmClose() -> Bool { shouldClose() }
        func controlsWillClose() { willClose() }
    }
}

/// Observe live output only in this small toolbar subtree. Prepared Current
/// does not become a second live selection source or drive the Hide label.
struct OutputSlidesToggleButton: View {
    @ObservedObject var session: PresentationSession
    @ObservedObject private var outputs: OutputCoordinator
    let onToggle: () -> Void
    init(session: PresentationSession, onToggle: @escaping () -> Void) {
        self.session = session; self.outputs = session.outputCoordinator; self.onToggle = onToggle
    }
    private var showing: Bool {
        !session.isEmpty && session.isPresenting && session.areSlidesVisible
    }
    var body: some View {
        Button(action: onToggle) {
            Label(showing ? "Hide Slides" : "Show Slides", systemImage: showing ? "rectangle.slash" : "rectangle")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderedProminent)
        .disabled(session.isEmpty)
        .help(session.isEmpty ? "Load a document into Current to show slides." : showing ? "Hide Slides" : "Show Slides")
    }
}

/// Output problems stay visible to the operator without blocking workspace edits.
struct OutputIssueBanner: View {
    @ObservedObject var session: PresentationSession
    @ObservedObject private var outputs: OutputCoordinator
    let manageOutputs: () -> Void
    init(session: PresentationSession, manageOutputs: @escaping () -> Void) {
        self.session = session; outputs = session.outputCoordinator; self.manageOutputs = manageOutputs
    }
    var body: some View {
        if let issue = session.projectionDisplayIssue {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(issue).frame(maxWidth: .infinity, alignment: .leading)
                Button("Manage Outputs…", action: manageOutputs)
                Button { outputs.dismissIssue(workspace: session.outputSourceID) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Dismiss output notice")
            }
            .font(.callout).padding(12).background(.regularMaterial)
        }
    }
}
