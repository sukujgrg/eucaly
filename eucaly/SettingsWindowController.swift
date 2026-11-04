import AppKit

/// One native Settings window, shared by app, output and workspace commands.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let settings: NativeSettingsController

    init(outputs: OutputCoordinator, workspaces: OutputWorkspaceWindows, updates: AppUpdateViewModel,
         defaults: UserDefaults = .standard, general: GeneralSettingsController? = nil) {
        settings = NativeSettingsController(outputs: outputs, workspaces: workspaces, updates: updates, defaults: defaults, general: general)
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 820, height: 650),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.tabbingMode = .disallowed
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.contentViewController = settings
        window.setContentSize(.init(width: 820, height: 650))
        window.contentMinSize = .init(width: 780, height: 580)
        window.center()
        super.init(window: window)
        window.delegate = self
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(pane: NativeSettingsController.Pane? = nil, profileID: UUID? = nil) {
        if let pane { settings.select(pane) }
        if let profileID { settings.selectProfile(profileID) }
        showWindow(nil)
    }
    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        settings.setPresented(true)
    }
    func windowWillClose(_ notification: Notification) {
        finishPresentation()
    }
    /// Finish active field editing before dismissing any sheet. Immediate output
    /// edits commit normally; workspace renames still require explicit Rename.
    func finishPresentation() {
        if let sheet = window?.attachedSheet {
            if let view = sheet.contentView { finishOutputSettingsFieldEditing(in: view) }
            window?.endSheet(sheet, returnCode: .cancel)
        }
        settings.setPresented(false)
    }
}

@MainActor
final class NativeSettingsController: NSTabViewController {
    enum Pane: String { case general, outputs = "projection", profiles, workspaces }
    let general: GeneralSettingsController
    let outputs: ManageOutputsController
    let profiles: ManageProfilesController
    let workspaces: ManageWorkspacesController
    private let defaults: UserDefaults
    private var isPresented = false
    private var isConfigured = false
    var selectedPane: Pane {
        switch selectedTabViewItemIndex {
        case 1: .outputs
        case 2: .profiles
        case 3: .workspaces
        default: .general
        }
    }

    init(outputs: OutputCoordinator, workspaces: OutputWorkspaceWindows, updates: AppUpdateViewModel,
         defaults: UserDefaults, general: GeneralSettingsController?) {
        self.defaults = defaults
        self.general = general ?? GeneralSettingsController(updates: updates, defaults: defaults)
        self.outputs = ManageOutputsController(coordinator: outputs)
        self.profiles = ManageProfilesController(coordinator: outputs)
        self.workspaces = ManageWorkspacesController(outputs: outputs, workspaces: workspaces)
        let saved = defaults.string(forKey: "settingsTab") ?? "general"
        super.init(nibName: nil, bundle: nil)
        title = "Settings"; tabStyle = .toolbar; transitionOptions = []
        self.outputs.onEditProfile = { [weak self] id in self?.selectProfile(id) }
        for (controller, label, symbol) in [
            (self.general as NSViewController, "General", "gearshape"),
            (self.outputs, "Outputs", "display"),
            (self.profiles, "Profiles", "paintpalette"),
            (self.workspaces, "Workspaces", "rectangle.stack")
        ] {
            let item = NSTabViewItem(viewController: controller)
            item.label = label
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            addTabViewItem(item)
        }
        select(["altView", "receiver"].contains(saved) ? .outputs : Pane(rawValue: saved) ?? .general)
        isConfigured = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ pane: Pane) {
        guard !isViewLoaded || view.window?.attachedSheet == nil else { return }
        switch pane {
        case .general: selectedTabViewItemIndex = 0
        case .outputs: selectedTabViewItemIndex = 1
        case .profiles: selectedTabViewItemIndex = 2
        case .workspaces: selectedTabViewItemIndex = 3
        }
    }

    func selectProfile(_ id: UUID) {
        guard !isViewLoaded || view.window?.attachedSheet == nil else { return }
        select(.profiles)
        _ = profiles.view
        profiles.selectProfile(id)
    }

    func selectDestination(_ id: UUID) {
        guard !isViewLoaded || view.window?.attachedSheet == nil else { return }
        select(.outputs)
        _ = outputs.view
        outputs.selectDestination(id)
    }

    func setPresented(_ value: Bool) {
        isPresented = value
        general.setPresented(value && selectedPane == .general)
        outputs.setPresented(value && selectedPane == .outputs)
        profiles.setPresented(value && selectedPane == .profiles)
        workspaces.setPresented(value && selectedPane == .workspaces)
    }
    override func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool {
        super.tabView(tabView, shouldSelect: tabViewItem) && (!isViewLoaded || view.window?.attachedSheet == nil)
    }
    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        general.finishEditing()
        outputs.finishEditing()
        profiles.finishEditing()
        super.tabView(tabView, willSelect: tabViewItem)
    }
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard isConfigured else { return }
        defaults.set(selectedPane.rawValue, forKey: "settingsTab")
        setPresented(isPresented)
    }
}
