import AppKit

/// One native preferences window, shared by the app menu and Manage Outputs.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let settings: NativeSettingsController

    init(outputs: OutputCoordinator, router: AltViewOutputRouter, updates: AppUpdateViewModel,
         defaults: UserDefaults = .standard, general: GeneralSettingsController? = nil) {
        settings = NativeSettingsController(outputs: outputs, router: router, updates: updates, defaults: defaults, general: general)
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

    func show(pane: NativeSettingsController.Pane? = nil) {
        if let pane, window?.attachedSheet == nil { settings.select(pane) }
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
    /// Closing Settings and quitting the app both commit the sheet's active
    /// field editor before dismissing it, just like the sheet's Done button.
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
    enum Pane: String { case general, outputs = "projection" }
    let general: GeneralSettingsController
    let outputs: ManageOutputsController
    private let defaults: UserDefaults
    private var isPresented = false
    private var isConfigured = false
    var selectedPane: Pane { selectedTabViewItemIndex == 1 ? .outputs : .general }

    init(outputs: OutputCoordinator, router: AltViewOutputRouter, updates: AppUpdateViewModel,
         defaults: UserDefaults, general: GeneralSettingsController?) {
        self.defaults = defaults
        self.general = general ?? GeneralSettingsController(updates: updates, defaults: defaults)
        self.outputs = ManageOutputsController(coordinator: outputs, router: router)
        let saved = defaults.string(forKey: "settingsTab") ?? "general"
        super.init(nibName: nil, bundle: nil)
        title = "Settings"; tabStyle = .toolbar; transitionOptions = []
        for (controller, label, symbol) in [(self.general as NSViewController, "General", "gearshape"),
                                             (self.outputs, "Manage Outputs", "display")] {
            let item = NSTabViewItem(viewController: controller)
            item.label = label; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            addTabViewItem(item)
        }
        selectedTabViewItemIndex = ["projection", "altView", "receiver"].contains(saved) ? 1 : 0
        isConfigured = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func select(_ pane: Pane) { selectedTabViewItemIndex = pane == .general ? 0 : 1 }
    func setPresented(_ value: Bool) {
        isPresented = value
        general.setPresented(value && selectedPane == .general)
        outputs.setPresented(value && selectedPane == .outputs)
    }
    override func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool {
        super.tabView(tabView, shouldSelect: tabViewItem) && (!isViewLoaded || view.window?.attachedSheet == nil)
    }
    override func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        general.finishEditing(); outputs.finishEditing()
        super.tabView(tabView, willSelect: tabViewItem)
    }
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        guard isConfigured else { return }
        defaults.set(selectedPane.rawValue, forKey: "settingsTab")
        setPresented(isPresented)
    }
}
