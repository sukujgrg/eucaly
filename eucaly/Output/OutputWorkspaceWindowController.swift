import AppKit
import Combine
import SwiftUI

/// App-owned controls windows. A workspace has at most one controls window;
/// native tab operations move that same window and its complete view hierarchy.
@MainActor
final class OutputWorkspaceWindows: ObservableObject {
    static let tabbingIdentifier = "com.suku.eucaly.workspaces"
    private static let identifierPrefix = "com.suku.eucaly.workspace."
    private static let lastWorkspaceKey = "lastControlsWorkspaceID"
    private let outputs: OutputCoordinator
    private let updates: AppUpdateViewModel
    private let defaults: UserDefaults?
    private let autosavesWindowFrames: Bool
    private let keyWindow: @MainActor () -> NSWindow?
    private let contentFactory: ((PresentationSession, OutputWorkspaceCommands) -> NSViewController)?
    private let showWorkspaceSettings: () -> Void
    var profiles: OutputProfileStore { outputs.profiles }
    let tabBadges: OutputWorkspaceTabBadges
    private var workspaceObservation: AnyCancellable?
    @Published private(set) var controllers: [UUID: OutputWorkspaceWindowController] = [:]
    var windows: [UUID: NSWindow] { controllers.compactMapValues(\.window) }
    var activeWorkspaceID: UUID? {
        guard let window = keyWindow() else { return nil }
        return controllers.first { $0.value.window === window }?.key
    }
    var canCreateWorkspace: Bool {
        outputs.profiles.canAddWorkspace
    }

    init(outputs: OutputCoordinator, updates: AppUpdateViewModel, defaults: UserDefaults? = nil,
         autosavesWindowFrames: Bool = !AppLaunchContext.isRunningTests,
         keyWindow: @escaping @MainActor () -> NSWindow? = { NSApp.keyWindow },
         manageWorkspaces: @escaping () -> Void = {},
         contentFactory: ((PresentationSession, OutputWorkspaceCommands) -> NSViewController)? = nil) {
        self.outputs = outputs; self.updates = updates; self.defaults = defaults
        self.autosavesWindowFrames = autosavesWindowFrames
        self.keyWindow = keyWindow; self.contentFactory = contentFactory
        self.showWorkspaceSettings = manageWorkspaces
        tabBadges = OutputWorkspaceTabBadges(workspaces: outputs.profiles.document.workspaces, defaults: defaults)
        workspaceObservation = outputs.profiles.$document
            .map(\.workspaces).removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.tabBadges.synchronize(self.outputs.profiles.document.workspaces)
            }
    }

    static func identifier(for id: UUID) -> NSUserInterfaceItemIdentifier {
        .init(identifierPrefix + id.uuidString)
    }
    static func workspaceID(for identifier: NSUserInterfaceItemIdentifier) -> UUID? {
        guard identifier.rawValue.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.rawValue.dropFirst(identifierPrefix.count)))
    }

    /// Creating a window for restoration never orders it onscreen. AppKit owns
    /// the restored geometry, minimization and native tab groups.
    func restoreWindow(identifier: NSUserInterfaceItemIdentifier) -> NSWindow? {
        guard let id = Self.workspaceID(for: identifier) else { return nil }
        return controller(for: id)?.window
    }

    @discardableResult
    func open(_ id: UUID, beside other: UUID? = nil) -> OutputWorkspaceWindowController? {
        let existing = controllers[id] != nil
        guard let controller = controller(for: id), let window = controller.window else { return nil }
        if !existing, let other, let parent = controllers[other]?.window, parent !== window {
            parent.addTabbedWindow(window, ordered: .above)
            if let group = parent.tabGroup, !group.isTabBarVisible { parent.toggleTabBar(nil) }
        }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.tabGroup?.selectedWindow = window
        controller.showWindow(nil)
        return controller
    }

    @discardableResult
    func newWorkspace(beside other: UUID? = nil) -> UUID? {
        guard let id = outputs.profiles.addWorkspace() else { return nil }
        open(id, beside: other ?? activeWorkspaceID ?? outputs.focusedWorkspaceID)
        return id
    }

    /// Called after native restoration completes. Even minimized windows count
    /// as restored; leave their geometry, selected tabs and ordering to AppKit.
    func openInitialWorkspace() {
        guard controllers.isEmpty else { return }
        reopen()
    }

    /// A Dock reopen returns to existing controls or the last saved workspace.
    func reopen() {
        let saved = defaults?.string(forKey: Self.lastWorkspaceKey).flatMap(UUID.init(uuidString:))
        let focused = outputs.focusedWorkspaceID
        let openFocused = focused.flatMap { controllers[$0] == nil ? nil : $0 }
        let openSaved = saved.flatMap { controllers[$0] == nil ? nil : $0 }
        let firstOpen = outputs.profiles.document.workspaces.first { controllers[$0.id] != nil }?.id
        let candidates = [activeWorkspaceID, openFocused, openSaved, firstOpen, saved, focused,
                          outputs.profiles.document.workspaces.first?.id].compactMap { $0 }
        guard let id = candidates.first(where: { candidate in
            outputs.profiles.document.workspaces.contains { $0.id == candidate }
        }) else { return }
        open(id)
    }

    func canDetach(_ id: UUID?) -> Bool {
        guard let id else { return false }
        return (controllers[id]?.window?.tabGroup?.windows.count ?? 0) > 1
    }
    func detach(_ id: UUID) {
        guard let window = controllers[id]?.window, let group = window.tabGroup, group.windows.count > 1 else { return }
        // Move this exact controls window, even if another tab became selected
        // after the menu opened. Its hosting view and session remain attached.
        group.removeWindow(window)
        window.makeKeyAndOrderFront(nil)
    }
    func rename(_ id: UUID) { controllers[id]?.renameWorkspace() }
    func manageWorkspaces() { showWorkspaceSettings() }

    @discardableResult
    func deleteWorkspace(_ id: UUID) -> String? {
        if let problem = outputs.workspaceDeletionProblem(id) { return problem }
        guard controllers[id]?.commands.confirmClose() ?? true else { return "Deletion cancelled. The workspace was kept." }
        // Unsaved-edit confirmation can process events; do not close controls
        // or remove data if an assignment or playback started during approval.
        if let problem = outputs.workspaceDeletionProblem(id) { return problem }
        controllers[id]?.window?.close()
        guard outputs.deleteWorkspace(id) else { return outputs.workspaceDeletionProblem(id) ?? "Unable to delete this workspace." }
        if autosavesWindowFrames { NSWindow.removeFrame(usingName: Self.identifier(for: id).rawValue) }
        if defaults?.string(forKey: Self.lastWorkspaceKey) == id.uuidString {
            defaults?.removeObject(forKey: Self.lastWorkspaceKey)
        }
        return nil
    }

    private func controller(for id: UUID) -> OutputWorkspaceWindowController? {
        if let controller = controllers[id] { return controller }
        guard outputs.profiles.document.workspaces.contains(where: { $0.id == id }) else { return nil }
        tabBadges.synchronize(outputs.profiles.document.workspaces)
        let badge = tabBadges.badge(for: id)
        let session = outputs.session(workspace: id)
        let commands = OutputWorkspaceCommands(keyWindow: keyWindow)
        let content: NSViewController
        if let contentFactory {
            content = contentFactory(session, commands)
        } else {
            content = OutputWorkspaceWindowController.hostingController(rootView: OutputWorkspaceView(session: session, commands: commands, workspaces: self)
                .environmentObject(updates))
        }
        let controller = OutputWorkspaceWindowController(session: session, commands: commands, content: content, badge: badge,
            autosavesFrame: autosavesWindowFrames,
            didBecomeKey: { [weak self] in self?.defaults?.set(id.uuidString, forKey: Self.lastWorkspaceKey) },
            didClose: { [weak self] closed in
                guard self?.controllers[id] === closed else { return }
                self?.controllers[id] = nil
            }, newWorkspace: { [weak self] in self?.newWorkspace(beside: id) })
        controllers[id] = controller
        return controller
    }
}

@MainActor
final class OutputWorkspaceWindow: NSWindow {
    weak var workspaceSession: PresentationSession?
}

@MainActor
final class OutputWorkspaceWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration {
    static let minimumContentSize = NSSize(width: 1060, height: 600)
    let session: PresentationSession
    let commands: OutputWorkspaceCommands
    let badge: OutputWorkspaceTabBadge
    let renamer: OutputWorkspaceRenamer
    private let creationAccessory: OutputWorkspaceCreationAccessory
    private let didBecomeKey: () -> Void
    private let didClose: (OutputWorkspaceWindowController) -> Void
    private let registrationID = UUID()
    private var titleObservation: AnyCancellable?
    private var initializedFocus = false
    private var closed = false

    static func hostingController<Content: View>(rootView: Content) -> NSViewController {
        let host = NSHostingController(rootView: rootView.frame(
            minWidth: minimumContentSize.width, minHeight: minimumContentSize.height))
        // The content supplies its minimum size. AppKit owns the window and title;
        // the public macOS 14 hosting bridge installs its existing toolbar only.
        host.sceneBridgingOptions = [.toolbars]
        host.sizingOptions = [.minSize]
        return host
    }

    init(session: PresentationSession, commands: OutputWorkspaceCommands, content: NSViewController, badge: OutputWorkspaceTabBadge,
         autosavesFrame: Bool,
         didBecomeKey: @escaping () -> Void, didClose: @escaping (OutputWorkspaceWindowController) -> Void,
         newWorkspace: @escaping () -> Void) {
        self.session = session; self.commands = commands
        self.badge = badge
        renamer = OutputWorkspaceRenamer(profiles: session.outputCoordinator.profiles)
        creationAccessory = OutputWorkspaceCreationAccessory(newWorkspace: newWorkspace)
        self.didBecomeKey = didBecomeKey; self.didClose = didClose
        let window = OutputWorkspaceWindow(contentRect: .init(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.identifier = OutputWorkspaceWindows.identifier(for: session.outputSourceID)
        window.isReleasedWhenClosed = false
        window.isRestorable = true
        window.restorationClass = OutputWorkspaceWindowController.self
        window.tabbingIdentifier = OutputWorkspaceWindows.tabbingIdentifier
        window.tabbingMode = .preferred
        window.toolbarStyle = .unified
        window.contentViewController = content
        window.contentMinSize = Self.minimumContentSize
        window.setContentSize(.init(width: 1280, height: 800))
        window.workspaceSession = session
        window.center()
        // Native restoration may subsequently supply the full window/tab state.
        // A stable UUID also remembers geometry after controls were closed.
        if autosavesFrame { window.setFrameAutosaveName(OutputWorkspaceWindows.identifier(for: session.outputSourceID).rawValue) }
        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
        commands.window = window
        ApplicationTerminationCoordinator.shared.register(id: registrationID, window: window) { [weak commands] in
            commands?.confirmClose() ?? true
        }
        updateTitle()
        let outputs = session.outputCoordinator
        titleObservation = Publishers.Merge(outputs.$revision.map { _ in () }, outputs.profiles.$document.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateTitle() }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func showWindow(_ sender: Any?) {
        guard !closed else { return }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        guard !initializedFocus else { return }
        initializedFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.closed, self.commands.isActive else { return }
            self.window?.makeFirstResponder(nil)
        }
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard !closed, commands.isActive else { return }
        // Native key events are already outside SwiftUI evaluation. Record the
        // current controls owner before a toolbar action can hand key focus to
        // Settings. A stale callback cannot overwrite a newer workspace's focus.
        session.outputCoordinator.workspaceWindowReady(session)
        didBecomeKey()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { commands.confirmClose() }
    func renameWorkspace() {
        guard !closed, let window else { return }
        renamer.present(workspaceID: session.outputSourceID, on: window)
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        // Release the autosave name before tearing down content. A retained,
        // closed window must not reserve the name or overwrite a reopened one.
        window?.setFrameAutosaveName("")
        renamer.cancel()
        commands.controlsWillClose()
        ApplicationTerminationCoordinator.shared.unregister(id: registrationID)
        titleObservation = nil
        creationAccessory.invalidate()
        commands.window = nil
        if let window = window as? OutputWorkspaceWindow {
            window.workspaceSession = nil
        }
        // Removing controls releases Preview consumers and editor resources.
        // The app-retained session, Current and live program are unaffected.
        window?.contentViewController = nil
        didClose(self)
    }
    private func updateTitle() {
        let outputs = session.outputCoordinator, id = session.outputSourceID
        let name = outputs.profiles.workspaceName(id)
        window?.title = name + " — " + outputs.tabStatus(workspace: id)
        window?.tab.title = window?.title ?? name
        window?.tab.attributedTitle = badge.title(window?.title ?? name)
        window?.tab.toolTip = window?.title ?? name
        guard let window else { return }
        let index = window.titlebarAccessoryViewControllers.firstIndex { $0 === creationAccessory }
        if outputs.profiles.canAddWorkspace {
            if index == nil { window.addTitlebarAccessoryViewController(creationAccessory) }
        } else if let index {
            window.removeTitlebarAccessoryViewController(at: index)
        }
    }

    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        guard !AppLaunchContext.isRunningTests, let app = NSApp.delegate as? AppDelegate else {
            completionHandler(nil, nil); return
        }
        completionHandler(app.workspaceWindows.restoreWindow(identifier: identifier), nil)
    }
}

/// An app-owned add control can be removed as the saved count changes. AppKit's
/// built-in tab-bar button caches action availability for the tab group's life.
@MainActor
final class OutputWorkspaceCreationAccessory: NSTitlebarAccessoryViewController {
    let button = NSButton()
    private var newWorkspace: (() -> Void)?

    init(newWorkspace: @escaping () -> Void) {
        self.newWorkspace = newWorkspace
        super.init(nibName: nil, bundle: nil)
        layoutAttribute = .trailing
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: .init(x: 0, y: 0, width: 44, height: 32))
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New Workspace Tab")
        button.bezelStyle = .texturedRounded; button.imagePosition = .imageOnly
        button.setAccessibilityLabel("New Workspace Tab")
        button.toolTip = "New Workspace Tab (⌘T)"
        button.target = self; button.action = #selector(createWorkspace(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 28), button.heightAnchor.constraint(equalToConstant: 28),
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor), button.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }
    func invalidate() { newWorkspace = nil; button.isEnabled = false }
    @objc private func createWorkspace(_ sender: Any?) { newWorkspace?() }
}
