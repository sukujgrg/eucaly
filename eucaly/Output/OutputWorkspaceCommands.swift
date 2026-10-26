import AppKit
import Combine
import SwiftUI

/// Sidebar navigation and the menu bar share ordering, availability and actions.
/// The menu bar follows the last controls context; a header keeps its owner.
@MainActor
final class OutputWorkspaceMenuController: NSObject, ObservableObject, NSMenuDelegate, NSMenuItemValidation {
    let menu = NSMenu(title: "Workspace")
    let button = NSPopUpButton(frame: .zero, pullsDown: true)
    let profiles: OutputProfileStore
    let badges: OutputWorkspaceTabBadges
    private weak var workspaces: OutputWorkspaceWindows?
    private let workspaceID: UUID?
    private enum Action: String {
        case new, rename, open, openInNewWindow, manage
        var title: String {
            switch self {
            case .new: "New Workspace"
            case .rename: "Rename Workspace…"
            case .open, .openInNewWindow: ""
            case .manage: "Manage Workspaces…"
            }
        }
    }
    private var currentID: UUID? { workspaceID ?? workspaces?.navigationWorkspaceID }
    var canCreateWorkspace: Bool {
        guard let workspaces else { return false }
        if let workspaceID, workspaces.controllers[workspaceID]?.window == nil { return false }
        return workspaces.canCreateWorkspace && currentID.flatMap { workspaces.controllers[$0]?.window?.attachedSheet } == nil
    }

    init(workspaces: OutputWorkspaceWindows, workspaceID: UUID? = nil) {
        self.workspaces = workspaces; self.workspaceID = workspaceID
        profiles = workspaces.profiles; badges = workspaces.tabBadges
        super.init()
        menu.delegate = self
        menu.autoenablesItems = workspaceID == nil
        button.imagePosition = .imageLeading
        button.alignment = .left
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        rebuild()
        if workspaceID != nil { button.menu = menu }
    }
    func menuNeedsUpdate(_ menu: NSMenu) {
        badges.synchronize(profiles.document.workspaces)
        if menu === self.menu { rebuild() }
        else { rebuildNewWindowMenu(menu) }
    }
    private func rebuild() {
        menu.removeAllItems()
        if workspaceID != nil { menu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: "")) }
        for record in profiles.document.workspaces {
            addWorkspace(record, action: .open, to: menu)
        }
        menu.addItem(.separator())
        add(.new)
        let newWindow = NSMenuItem(title: "Open in New Window", action: nil, keyEquivalent: "")
        newWindow.submenu = makeOpenInNewWindowMenu()
        menu.addItem(newWindow)
        add(.rename)
        menu.addItem(.separator())
        add(.manage)
        updateButtonLabel()
    }
    func makeOpenInNewWindowMenu() -> NSMenu {
        let result = NSMenu(title: "Open in New Window")
        result.delegate = self
        result.autoenablesItems = workspaceID == nil
        rebuildNewWindowMenu(result)
        return result
    }
    private func rebuildNewWindowMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for record in profiles.document.workspaces {
            addWorkspace(record, action: .openInNewWindow, to: menu)
        }
    }
    private func addWorkspace(_ record: OutputWorkspaceRecord, action: Action, to menu: NSMenu) {
        let item = add(action, title: record.name, to: menu)
        item.representedObject = record.id
        item.image = badges.badge(for: record.id).menuImage
        let status = workspaces?.status(workspace: record.id) ?? "Stopped"
        let visibleElsewhere = workspaces?.windows[record.id] != nil && record.id != currentID
        if action == .openInNewWindow, record.id == currentID, workspaces?.windows[record.id] != nil {
            item.subtitle = "Already open in this window · " + status
        } else { item.subtitle = visibleElsewhere ? "Show existing window · " + status : status }
        item.toolTip = record.name + " — " + (item.subtitle ?? status)
        item.isEnabled = validateMenuItem(item)
    }
    func updateButtonLabel() {
        guard let workspaceID else { return }
        let name = profiles.workspaceName(workspaceID)
        menu.items.first?.title = "Workspaces"
        menu.items.first?.image = badges.badge(for: workspaceID).menuImage
        button.toolTip = "Current workspace: " + name + " — Switch or open a workspace in a new window"
        button.setControlAccessibility(label: "Workspaces", value: name,
            help: "Switch workspaces, open a workspace in a new window, rename or manage workspaces.")
    }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let action = action(for: item), let workspaces else { return false }
        // A retained sidebar menu must never act on behalf of controls that
        // have since been parked, closed or replaced in their native window.
        if let workspaceID, action != .manage, workspaces.controllers[workspaceID]?.window == nil { return false }
        let current = currentID.flatMap { id in profiles.document.workspaces.first { $0.id == id } }
        switch action {
        case .new: return canCreateWorkspace
        case .rename:
            guard profiles.recoveryNotice == nil, let current, let window = workspaces.controllers[current.id]?.window else { return false }
            return window.attachedSheet == nil
        case .open:
            guard let id = item.representedObject as? UUID else { return false }
            item.state = id == currentID ? .on : .off
            return workspaces.canOpen(id, from: workspaceID)
        case .openInNewWindow:
            guard let id = item.representedObject as? UUID else { return false }
            return workspaces.canOpenInNewWindow(id)
        case .manage: return true
        }
    }
    private func action(for item: NSMenuItem) -> Action? {
        guard let value = item.identifier?.rawValue, value.hasPrefix("workspace.") else { return nil }
        return Action(rawValue: String(value.dropFirst("workspace.".count)))
    }
    @discardableResult
    private func add(_ action: Action, title: String? = nil, to targetMenu: NSMenu? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? action.title, action: #selector(performAction(_:)), keyEquivalent: "")
        item.identifier = .init("workspace." + action.rawValue); item.target = self
        item.isEnabled = validateMenuItem(item)
        (targetMenu ?? menu).addItem(item)
        return item
    }
    @objc private func performAction(_ item: NSMenuItem) {
        guard validateMenuItem(item), let action = action(for: item), let workspaces else { return }
        switch action {
        case .new: workspaces.newWorkspace(from: workspaceID)
        case .rename: if let id = currentID { workspaces.rename(id) }
        case .open:
            if let id = item.representedObject as? UUID, id != currentID { workspaces.open(id, from: workspaceID) }
        case .openInNewWindow:
            if let id = item.representedObject as? UUID { workspaces.openInNewWindow(id) }
        case .manage: workspaces.manageWorkspaces()
        }
    }
}

/// Register the pinned menu with the sidebar's native layout and scroll-edge
/// geometry instead of taking space away from its scrolling surface.
@MainActor
final class WorkspaceSidebarAccessoryController: NSSplitViewItemAccessoryViewController {
    let controls: OutputWorkspaceMenuController
    private var labelSubscription: AnyCancellable?

    init(controls: OutputWorkspaceMenuController) {
        self.controls = controls
        super.init(nibName: nil, bundle: nil)
        labelSubscription = Publishers.Merge(controls.profiles.$document.map { _ in () },
            controls.badges.$assignments.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.controls.updateButtonLabel() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView()
        let button = controls.button
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            button.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor),
            button.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),
            button.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -8)
        ])
        controls.updateButtonLabel()
    }

    func detach() { labelSubscription = nil }
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
    let librarySearchPresenter = LibrarySearchPalettePresenter()
    private let keyWindow: @MainActor () -> NSWindow?
    init(keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow }) { self.keyWindow = keyWindow }
    weak var window: NSWindow?
    weak var closeConfirmation: (any OutputWorkspaceCloseConfirming)?
    weak var workspaceWindows: OutputWorkspaceWindows?
    var isActive: Bool { window != nil && window === keyWindow() }
    var editingFileURL: URL? { closeConfirmation?.editingFileURL }
    var canSaveLyrics: Bool { closeConfirmation?.canSaveLyrics ?? false }
    var referencedFileURLs: Set<URL> { workspaceWindows?.referencedFileURLs ?? [] }
    func fileRemovalProblem(matchingFile: (URL) -> Bool) -> String? {
        guard let workspaceWindows else { return "These workspace controls are no longer available." }
        return workspaceWindows.fileRemovalProblem(matchingFile: matchingFile)
    }
    func beginFileRemoval(at url: URL, matchingFile: @escaping (URL) -> Bool) -> OutputCoordinator.FileRemovalAdmission {
        guard let workspaceWindows, let window = window as? OutputWorkspaceWindow,
              let workspaceID = window.workspaceSession?.outputSourceID else {
            return .blocked("These workspace controls are no longer available.")
        }
        return workspaceWindows.beginFileRemoval(at: url, requesterWorkspaceID: workspaceID, matchingFile: matchingFile)
    }
    @discardableResult
    func finishFileRemoval(_ reservation: OutputCoordinator.FileRemovalReservation,
                           candidate: LibraryFileActionService.Candidate, removed: Bool, resultingURL: URL? = nil) -> Bool {
        workspaceWindows?.finishFileRemoval(reservation, candidate: candidate, removed: removed, resultingURL: resultingURL) ?? false
    }
    func confirmClose() -> Bool { closeConfirmation?.confirmClose() ?? true }
    func controlsWillClose() { closeConfirmation?.controlsWillClose() }
}

@MainActor
protocol OutputWorkspaceCloseConfirming: AnyObject {
    var editingFileURL: URL? { get }
    var canSaveLyrics: Bool { get }
    func fileWasRemoved(_ candidate: LibraryFileActionService.Candidate)
    func confirmClose() -> Bool
    func controlsWillClose()
}

extension OutputWorkspaceCloseConfirming {
    var editingFileURL: URL? { nil }
    var canSaveLyrics: Bool { false }
    func fileWasRemoved(_ candidate: LibraryFileActionService.Candidate) {}
}

/// Provides the current editor's close decision to the native window controller,
/// without replacing its delegate or taking ownership of the window lifecycle.
struct OutputWorkspaceCloseConfirmation: NSViewRepresentable {
    let commands: OutputWorkspaceCommands
    let shouldClose: () -> Bool
    var willClose: () -> Void = {}
    var editorFileURL: () -> URL? = { nil }
    var canSaveLyrics: () -> Bool = { false }
    var didRemoveFile: (LibraryFileActionService.Candidate) -> Void = { _ in }
    func makeNSView(context: Context) -> ConfirmationView {
        let view = ConfirmationView(frame: .zero)
        view.shouldClose = shouldClose
        view.willClose = willClose
        view.editorFileURL = editorFileURL
        view.saveEligibility = canSaveLyrics
        view.didRemoveFile = didRemoveFile
        commands.closeConfirmation = view
        return view
    }
    func updateNSView(_ view: ConfirmationView, context: Context) {
        guard !view.isRetired else { return }
        view.shouldClose = shouldClose
        view.willClose = willClose
        view.editorFileURL = editorFileURL
        view.saveEligibility = canSaveLyrics
        view.didRemoveFile = didRemoveFile
        commands.closeConfirmation = view
    }

    static func dismantleNSView(_ view: ConfirmationView, coordinator: ()) {
        view.retire()
    }

    final class ConfirmationView: NSView, OutputWorkspaceCloseConfirming {
        private(set) var isRetired = false
        var shouldClose: () -> Bool = { true }
        var willClose: () -> Void = {}
        var editorFileURL: () -> URL? = { nil }
        var saveEligibility: () -> Bool = { false }
        var didRemoveFile: (LibraryFileActionService.Candidate) -> Void = { _ in }
        var editingFileURL: URL? { editorFileURL() }
        var canSaveLyrics: Bool { saveEligibility() }
        func fileWasRemoved(_ candidate: LibraryFileActionService.Candidate) { didRemoveFile(candidate) }
        func confirmClose() -> Bool { shouldClose() }
        func controlsWillClose() {
            guard !isRetired else { return }
            let cleanup = willClose
            retire()
            cleanup()
        }
        func retire() {
            isRetired = true
            shouldClose = { true }; willClose = {}
            editorFileURL = { nil }; saveEligibility = { false }; didRemoveFile = { _ in }
        }
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
