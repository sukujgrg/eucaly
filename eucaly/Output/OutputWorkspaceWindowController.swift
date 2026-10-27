import AppKit
import Combine
import SwiftUI

/// Retained controls belong to a workspace; native windows present one context
/// at a time. Switching never closes controls or changes a program's owner.
@MainActor
final class OutputWorkspaceWindows: ObservableObject {
    private static let identifierPrefix = "com.suku.eucaly.workspace."
    private static let lastWorkspaceKey = "lastControlsWorkspaceID"
    private let outputs: OutputCoordinator
    private let updates: AppUpdateViewModel
    private let defaults: UserDefaults?
    private let autosavesWindowFrames: Bool
    private let keyWindow: @MainActor () -> NSWindow?
    private let contentFactory: ((PresentationSession, OutputWorkspaceCommands) -> NSViewController)?
    private let showWorkspaceSettings: () -> Void
    private var workspaceObservation: AnyCancellable?
    private var hosts: [OutputWorkspaceWindowController] = []
    @Published private(set) var controllers: [UUID: OutputWorkspaceControls] = [:]
    var profiles: OutputProfileStore { outputs.profiles }
    let tabBadges: OutputWorkspaceTabBadges
    var windows: [UUID: NSWindow] { controllers.compactMapValues(\.window) }
    var activeWorkspaceID: UUID? {
        guard let window = keyWindow() else { return nil }
        return hosts.first { $0.window === window }?.session.outputSourceID
    }
    var navigationWorkspaceID: UUID? {
        activeWorkspaceID ?? outputs.focusedWorkspaceID.flatMap { controllers[$0]?.window == nil ? nil : $0 }
            ?? hosts.first?.session.outputSourceID
    }
    var canCreateWorkspace: Bool {
        let window = keyWindow()
        // Shift-Command-N belongs to New Folder while a native file panel owns
        // input, including panels attached to Settings rather than controls.
        return profiles.canAddWorkspace && NSApp.modalWindow == nil
            && window?.sheetParent == nil && window?.attachedSheet == nil
    }
    func status(workspace id: UUID) -> String { outputs.tabStatus(workspace: id) }

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
        workspaceObservation = outputs.profiles.$document.map(\.workspaces).removeDuplicates()
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self else { return }
                self.tabBadges.synchronize(self.profiles.document.workspaces)
            }
        ApplicationTerminationCoordinator.shared.register(owner: self) { [weak self] in
            self?.confirmTermination() ?? true
        }
    }

    static func identifier(for id: UUID) -> NSUserInterfaceItemIdentifier {
        .init(identifierPrefix + id.uuidString)
    }
    static func workspaceID(for identifier: NSUserInterfaceItemIdentifier) -> UUID? {
        guard identifier.rawValue.hasPrefix(identifierPrefix) else { return nil }
        return UUID(uuidString: String(identifier.rawValue.dropFirst(identifierPrefix.count)))
    }

    /// Native restoration supplies selected workspace identities and geometry.
    /// Legacy tab identities become independent, non-tabbable controls windows.
    func restoreWindow(identifier: NSUserInterfaceItemIdentifier) -> NSWindow? {
        guard let id = Self.workspaceID(for: identifier), let controls = controls(for: id) else { return nil }
        return controls.host?.window ?? makeHost(controls).window
    }

    func canOpen(_ id: UUID, from requesterID: UUID? = nil) -> Bool {
        guard profiles.document.workspaces.contains(where: { $0.id == id }) else { return false }
        if let requesterID, controllers[requesterID]?.window == nil { return false }
        let source = (requesterID ?? navigationWorkspaceID).flatMap { controllers[$0]?.window }
        return source?.attachedSheet == nil && controllers[id]?.window?.attachedSheet == nil
    }
    func canOpenInNewWindow(_ id: UUID) -> Bool {
        profiles.document.workspaces.contains { $0.id == id } && controllers[id]?.window?.attachedSheet == nil
    }

    @discardableResult
    func open(_ id: UUID, from requesterID: UUID? = nil) -> OutputWorkspaceWindowController? {
        guard canOpen(id, from: requesterID), let controls = controls(for: id) else { return nil }
        let host: OutputWorkspaceWindowController
        if let existing = controls.host { host = existing }
        else if let sourceID = requesterID ?? navigationWorkspaceID, let source = controllers[sourceID]?.host {
            guard source.present(controls) else { return nil }
            host = source
        } else { host = makeHost(controls) }
        host.showWindow(nil)
        recordFocus(host)
        objectWillChange.send()
        return host
    }

    @discardableResult
    func openInNewWindow(_ id: UUID) -> OutputWorkspaceWindowController? {
        guard canOpenInNewWindow(id), let controls = controls(for: id) else { return nil }
        let host = controls.host ?? makeHost(controls)
        host.showWindow(nil); recordFocus(host); objectWillChange.send()
        return host
    }

    @discardableResult
    func newWorkspace(from requesterID: UUID? = nil) -> UUID? {
        guard canCreateWorkspace else { return nil }
        if let requesterID, controllers[requesterID]?.window == nil { return nil }
        if let source = (requesterID ?? navigationWorkspaceID).flatMap({ controllers[$0]?.window }), source.attachedSheet != nil { return nil }
        guard let id = profiles.addWorkspace() else { return nil }
        open(id, from: requesterID)
        return id
    }

    func openInitialWorkspace() { if hosts.isEmpty { reopen() } }
    func reopen() {
        let saved = defaults?.string(forKey: Self.lastWorkspaceKey).flatMap(UUID.init(uuidString:))
        let candidates = [navigationWorkspaceID, saved, outputs.focusedWorkspaceID,
                          profiles.document.workspaces.first?.id].compactMap { $0 }
        guard let id = candidates.first(where: { candidate in profiles.document.workspaces.contains { $0.id == candidate } }) else { return }
        open(id)
    }
    func rename(_ id: UUID) { controllers[id]?.host?.renameWorkspace() }
    func manageWorkspaces() { showWorkspaceSettings() }

    var referencedFileURLs: Set<URL> {
        var urls = outputs.referencedFileURLs
        for controller in controllers.values {
            if let url = controller.commands.editingFileURL { urls.insert(url.standardizedFileURL) }
        }
        return urls
    }
    func fileRemovalProblem(matchingFile matches: (URL) -> Bool) -> String? {
        for record in profiles.document.workspaces {
            if let url = controllers[record.id]?.commands.editingFileURL, matches(url) {
                return "This file is open for editing in \(record.name). Close its editor before moving it to the Trash."
            }
        }
        return outputs.fileRemovalProblem(matchingFile: matches)
    }
    func beginFileRemoval(at url: URL, requesterWorkspaceID: UUID,
                          matchingFile: @escaping (URL) -> Bool) -> OutputCoordinator.FileRemovalAdmission {
        // Confirmation can run a nested event loop. Recheck every live editor
        // and retained program immediately before reserving, without yielding.
        if let problem = fileRemovalProblem(matchingFile: matchingFile) { return .blocked(problem) }
        return outputs.beginFileRemoval(at: url, requesterWorkspaceID: requesterWorkspaceID, matchingFile: matchingFile)
    }
    @discardableResult
    func finishFileRemoval(_ reservation: OutputCoordinator.FileRemovalReservation,
                           candidate: LibraryFileActionService.Candidate, removed: Bool, resultingURL: URL? = nil) -> Bool {
        guard outputs.finishFileRemoval(reservation, removed: removed, resultingURL: resultingURL) else { return false }
        if removed {
            // The requesting controls may have closed. Notify every remaining
            // owner with the prepared identity so aliased selections retire too.
            for controller in Array(controllers.values) {
                controller.commands.closeConfirmation?.fileWasRemoved(candidate)
            }
        }
        return true
    }

    @discardableResult
    func deleteWorkspace(_ id: UUID) -> String? {
        if let problem = outputs.workspaceDeletionProblem(id) { return problem }
        if let controls = controllers[id] {
            guard open(id) != nil else { return "Finish the open sheet before deleting this workspace." }
            guard controls.commands.confirmClose() else { return "Deletion cancelled. The workspace was kept." }
        }
        // Approval may run a nested event loop; revalidate all live ownership.
        if let problem = outputs.workspaceDeletionProblem(id) { return problem }
        if let controls = controllers[id] {
            if let host = controls.host { host.window?.close() }
            else { release(controls) }
        }
        guard outputs.deleteWorkspace(id) else { return outputs.workspaceDeletionProblem(id) ?? "Unable to delete this workspace." }
        if autosavesWindowFrames { NSWindow.removeFrame(usingName: Self.identifier(for: id).rawValue) }
        if defaults?.string(forKey: Self.lastWorkspaceKey) == id.uuidString { defaults?.removeObject(forKey: Self.lastWorkspaceKey) }
        return nil
    }

    private func controls(for id: UUID) -> OutputWorkspaceControls? {
        if let controls = controllers[id] { return controls }
        guard profiles.document.workspaces.contains(where: { $0.id == id }) else { return nil }
        let session = outputs.session(workspace: id), commands = OutputWorkspaceCommands(keyWindow: keyWindow)
        commands.workspaceWindows = self
        let content = contentFactory?(session, commands) ?? OutputWorkspaceWindowController.hostingController(
            rootView: OutputWorkspaceView(session: session, commands: commands, workspaces: self).environmentObject(updates))
        tabBadges.synchronize(profiles.document.workspaces)
        let controls = OutputWorkspaceControls(session: session, commands: commands, content: content, badge: tabBadges.badge(for: id))
        controllers[id] = controls
        return controls
    }
    private func makeHost(_ controls: OutputWorkspaceControls) -> OutputWorkspaceWindowController {
        let host = OutputWorkspaceWindowController(controls: controls, autosavesFrame: autosavesWindowFrames,
            didBecomeKey: { [weak self] host in self?.recordFocus(host) },
            didClose: { [weak self] host, closesControls in
                guard let self else { return }
                self.hosts.removeAll { $0 === host }
                if closesControls { self.release(host.controls) }
            })
        hosts.append(host)
        return host
    }
    private func recordFocus(_ host: OutputWorkspaceWindowController) {
        guard hosts.contains(where: { $0 === host }), controllers[host.session.outputSourceID] === host.controls else { return }
        outputs.focusWorkspace(host.session)
        if host.commands.isActive { outputs.workspaceWindowReady(host.session) }
        defaults?.set(host.session.outputSourceID.uuidString, forKey: Self.lastWorkspaceKey)
    }
    private func release(_ controls: OutputWorkspaceControls) {
        let id = controls.session.outputSourceID
        guard controllers[id] === controls else { return }
        controls.commands.controlsWillClose()
        (controls.content as? OutputWorkspaceContentController)?.retire()
        controls.toolbar = nil
        controls.fieldUndoManager.removeAllActions()
        controllers[id] = nil
    }
    private func confirmTermination() -> Bool {
        let selected = hosts.map { ($0, $0.controls, $0.window?.isMiniaturized == true, $0.window?.isVisible == true) }
        let previousKey = keyWindow()
        let previousFocus = outputs.focusedWorkspaceID
        let saved = defaults?.string(forKey: Self.lastWorkspaceKey)
        let ids = controllers.keys.sorted { $0 == navigationWorkspaceID && $1 != navigationWorkspaceID }
        for id in ids {
            guard let controls = controllers[id] else { continue }
            guard open(id) != nil, controls.commands.confirmClose() else { return false }
        }
        // Revealing a parked draft is necessary for native confirmation. Once
        // approved, restore the operator's window selections before AppKit
        // captures launch restoration, including a previously windowless app.
        for host in Array(hosts) where !selected.contains(where: { $0.0 === host }) {
            host.closePreservingControls()
        }
        for (host, controls, minimized, visible) in selected {
            guard hosts.contains(where: { $0 === host }), controllers[controls.session.outputSourceID] === controls,
                  controls.host == nil || controls.host === host else { continue }
            host.present(controls)
            if minimized { host.window?.miniaturize(nil) }
            else if !visible { host.window?.orderOut(nil) }
        }
        previousKey?.makeKeyAndOrderFront(nil)
        if let previousFocus, let session = outputs.preparedSession(workspace: previousFocus) { outputs.focusWorkspace(session) }
        if let saved { defaults?.set(saved, forKey: Self.lastWorkspaceKey) }
        else { defaults?.removeObject(forKey: Self.lastWorkspaceKey) }
        return true
    }
}

/// The complete operator state survives while its content is parked offscreen.
@MainActor
final class OutputWorkspaceControls {
    let session: PresentationSession
    let commands: OutputWorkspaceCommands
    let content: NSViewController
    let badge: OutputWorkspaceTabBadge
    let renamer: OutputWorkspaceRenamer
    let fieldUndoManager = UndoManager()
    // The hosting bridge's toolbar belongs to these controls as well. Keeping
    // it with its host prevents reuse of another workspace's native item state.
    var toolbar: NSToolbar?
    weak var host: OutputWorkspaceWindowController?
    var window: NSWindow? { host?.window }
    private weak var responder: NSResponder?
    private var fieldSelection: NSRange?

    init(session: PresentationSession, commands: OutputWorkspaceCommands, content: NSViewController, badge: OutputWorkspaceTabBadge) {
        self.session = session; self.commands = commands; self.content = content; self.badge = badge
        renamer = OutputWorkspaceRenamer(profiles: session.outputCoordinator.profiles)
    }
    func rememberFocus(in window: NSWindow) {
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
           let field = editingField(in: content.view, editor: editor) {
            responder = field
            fieldSelection = editor.selectedRange()
        } else if let view = window.firstResponder as? NSView, view.isDescendant(of: content.view) {
            responder = view; fieldSelection = nil
        }
    }
    private func editingField(in view: NSView, editor: NSTextView) -> NSTextField? {
        if let field = view as? NSTextField, field.currentEditor() === editor { return field }
        for child in view.subviews {
            if let field = editingField(in: child, editor: editor) { return field }
        }
        return nil
    }
    func restoreFocus(in window: NSWindow) {
        guard let responder else { window.makeFirstResponder(nil); return }
        if let fieldSelection, let field = responder as? NSTextField {
            // Begin native field editing synchronously before restoring its
            // selection; merely assigning firstResponder can defer select-all.
            field.selectText(nil)
            field.currentEditor()?.selectedRange = fieldSelection
        } else { window.makeFirstResponder(responder) }
    }
}

@MainActor
final class OutputWorkspaceWindow: NSWindow {
    weak var workspaceSession: PresentationSession?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        WorkspacePresentationCommand.handleKeyEquivalent(event, in: self) || super.performKeyEquivalent(with: event)
    }

    /// Search and text completion consume cancellation earlier in the responder
    /// chain. At the workspace boundary Escape hides slides, including when
    /// native controls are focused or the controls window is fullscreen.
    override func cancelOperation(_ sender: Any?) {
        guard let session = workspaceSession, session.isPresenting, session.areSlidesVisible else { return }
        session.hideSlides()
    }

    /// Menus also route while native search owns the responder chain, outside
    /// the split's descendants. Resolve the mounted workspace's toolbar owner.
    @objc func toggleSidebar(_ sender: Any?) {
        (toolbar?.delegate as? PresentationToolbarController)?.toggleSidebar(sender)
    }
}

@MainActor
final class OutputWorkspaceWindowController: NSWindowController, NSWindowDelegate, NSWindowRestoration {
    static let minimumContentSize = NSSize(width: 1060, height: 600)
    private(set) var controls: OutputWorkspaceControls
    var session: PresentationSession { controls.session }
    var commands: OutputWorkspaceCommands { controls.commands }
    var badge: OutputWorkspaceTabBadge { controls.badge }
    var renamer: OutputWorkspaceRenamer { controls.renamer }
    private let autosavesFrame: Bool
    private let didBecomeKey: (OutputWorkspaceWindowController) -> Void
    private let didClose: (OutputWorkspaceWindowController, Bool) -> Void
    private var titleObservation: AnyCancellable?
    private var pendingFocusRestoration: UUID?
    private var closed = false

    static func hostingController<Content: View>(rootView: Content) -> NSViewController {
        let host = NSHostingController(rootView: AnyView(rootView.frame(minWidth: minimumContentSize.width, minHeight: minimumContentSize.height)))
        host.sceneBridgingOptions = [.toolbars]
        host.sizingOptions = [.minSize]
        return OutputWorkspaceContentController(hostedContent: host)
    }

    init(controls: OutputWorkspaceControls, autosavesFrame: Bool,
         didBecomeKey: @escaping (OutputWorkspaceWindowController) -> Void,
         didClose: @escaping (OutputWorkspaceWindowController, Bool) -> Void) {
        self.controls = controls; self.autosavesFrame = autosavesFrame
        self.didBecomeKey = didBecomeKey; self.didClose = didClose
        let window = OutputWorkspaceWindow(contentRect: .init(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isRestorable = true
        window.restorationClass = OutputWorkspaceWindowController.self
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.contentMinSize = Self.minimumContentSize
        window.center()
        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
        attach(controls, preservingFrame: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Same native window, same retained views. A modal sheet must finish before
    /// its controls can leave the responder chain.
    @discardableResult
    func present(_ next: OutputWorkspaceControls) -> Bool {
        guard !closed, let window, window.attachedSheet == nil else { return false }
        if next === controls { return true }
        commands.librarySearchPresenter.dismiss()
        // A newly attached field may have AppKit's automatic select-all before
        // its saved focus has been restored. That is not a new operator choice.
        if pendingFocusRestoration == nil { controls.rememberFocus(in: window) }
        guard window.makeFirstResponder(nil) else { return false }
        if autosavesFrame { window.saveFrame(usingName: OutputWorkspaceWindows.identifier(for: session.outputSourceID).rawValue) }
        controls.host = nil; commands.window = nil
        titleObservation = nil
        controls.toolbar = window.toolbar
        window.contentViewController = nil
        attach(next, preservingFrame: true)
        return true
    }
    private func attach(_ next: OutputWorkspaceControls, preservingFrame: Bool) {
        guard let window = window as? OutputWorkspaceWindow else { return }
        let frame = window.frame
        window.setFrameAutosaveName("")
        controls = next; next.host = self
        next.commands.window = window; window.workspaceSession = next.session
        window.identifier = OutputWorkspaceWindows.identifier(for: session.outputSourceID)
        window.tabbingIdentifier = window.identifier!.rawValue
        window.toolbar = next.toolbar
        window.contentViewController = next.content
        if autosavesFrame { window.setFrameAutosaveName(window.identifier!.rawValue) }
        if preservingFrame { window.setFrame(frame, display: false) }
        updateTitle()
        let outputs = session.outputCoordinator
        titleObservation = Publishers.Merge(outputs.$revision.map { _ in () }, outputs.profiles.$document.map { _ in () })
            .receive(on: RunLoop.main).sink { [weak self] in self?.updateTitle() }
        let focusRequest = UUID()
        pendingFocusRestoration = focusRequest
        DispatchQueue.main.async { [weak self, weak next, weak window] in
            guard let self, let next, let window, !self.closed, self.controls === next, next.host === self,
                  self.pendingFocusRestoration == focusRequest else { return }
            next.restoreFocus(in: window)
            self.pendingFocusRestoration = nil
        }
    }
    override func showWindow(_ sender: Any?) {
        guard !closed else { return }
        if window?.isMiniaturized == true { window?.deminiaturize(nil) }
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
    }
    func windowDidBecomeKey(_ notification: Notification) {
        guard !closed, commands.isActive else { return }
        didBecomeKey(self)
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { commands.confirmClose() }
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        if let manager = commands.librarySearchPresenter.undoManager { return manager }
        // AppKit's Edit menu routes Undo through the window. Supply the active
        // document's stack; ordinary field editing is workspace-owned as well.
        if let editor = window.firstResponder as? LyricsTextView { return editor.undoManager }
        return controls.fieldUndoManager
    }
    func renameWorkspace() {
        guard !closed, let window else { return }
        renamer.present(workspaceID: session.outputSourceID, on: window)
    }
    func closePreservingControls() {
        guard !closed else { return }
        commands.librarySearchPresenter.dismiss()
        if let window {
            if pendingFocusRestoration == nil { controls.rememberFocus(in: window) }
            window.makeFirstResponder(nil)
            controls.toolbar = window.toolbar
        }
        commands.window = nil; controls.host = nil
        window?.contentViewController = nil
        window?.close()
    }
    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        commands.librarySearchPresenter.dismiss()
        let closesControls = controls.host === self
        closed = true
        window?.setFrameAutosaveName("")
        renamer.cancel()
        titleObservation = nil
        commands.window = nil; controls.host = nil
        (window as? OutputWorkspaceWindow)?.workspaceSession = nil
        window?.toolbar = nil
        window?.contentViewController = nil
        didClose(self, closesControls)
    }
    private func updateTitle() {
        window?.title = session.outputCoordinator.profiles.workspaceName(session.outputSourceID)
            + " — " + session.outputCoordinator.tabStatus(workspace: session.outputSourceID)
    }
    static func restoreWindow(withIdentifier identifier: NSUserInterfaceItemIdentifier, state: NSCoder,
                              completionHandler: @escaping (NSWindow?, Error?) -> Void) {
        guard !AppLaunchContext.isRunningTests, let app = NSApp.delegate as? AppDelegate else { completionHandler(nil, nil); return }
        completionHandler(app.workspaceWindows.restoreWindow(identifier: identifier), nil)
    }
}
