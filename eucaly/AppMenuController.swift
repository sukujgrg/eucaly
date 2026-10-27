import AppKit

/// Native application menus use the responder chain for editing and window
/// actions. Presentation actions resolve their workspace in OutputCoordinator.
@MainActor
final class AppMenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private unowned let app: AppDelegate
    let mainMenu = NSMenu()
    private let workspaceCommands: OutputWorkspaceMenuController
    var workspaceMenu: NSMenu { workspaceCommands.menu }
    let outputMenu = NSMenu(title: "Output")

    private enum Command: String {
        case settings, updates, notices, support, newWorkspace
        case newLyrics, searchLibrary, refresh, save, stop, stopAll, slides, background, audio
        case clearBackground, clearAudio, clearAll
        case monitorAudioLocally, manageOutputs
    }

    init(app: AppDelegate) {
        self.app = app
        workspaceCommands = OutputWorkspaceMenuController(workspaces: app.workspaceWindows)
        super.init()
        let application = submenu("eucaly")
        add("About eucaly", to: application, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)))
        add("Check for Updates…", to: application, command: .updates)
        add("Third-Party Notices…", to: application, command: .notices)
        application.addItem(.separator())
        add("Settings…", to: application, command: .settings, key: ",")
        application.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services"); application.addItem(services)
        application.addItem(.separator())
        add("Hide eucaly", to: application, action: #selector(NSApplication.hide(_:)), key: "h")
        add("Hide Others", to: application, action: #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option])
        add("Show All", to: application, action: #selector(NSApplication.unhideAllApplications(_:)))
        application.addItem(.separator())
        add("Quit eucaly", to: application, action: #selector(NSApplication.terminate(_:)), key: "q")

        let file = submenu("File")
        add("New Lyrics", to: file, command: .newLyrics, key: "n")
        add("New Workspace", to: file, command: .newWorkspace, key: "n", modifiers: [.command, .shift])
        add("Refresh Library", to: file, command: .refresh, key: "r")
        file.addItem(.separator())
        add("Save Lyrics", to: file, command: .save, key: "s")
        add("Close Window", to: file, action: #selector(NSWindow.performClose(_:)), key: "w")

        let edit = submenu("Edit")
        add("Undo", to: edit, action: Selector(("undo:")), key: "z")
        add("Redo", to: edit, action: Selector(("redo:")), key: "z", modifiers: [.command, .shift])
        edit.addItem(.separator())
        add("Cut", to: edit, action: #selector(NSText.cut(_:)), key: "x")
        add("Copy", to: edit, action: #selector(NSText.copy(_:)), key: "c")
        add("Paste", to: edit, action: #selector(NSText.paste(_:)), key: "v")
        add("Paste and Match Style", to: edit, action: #selector(NSTextView.pasteAsPlainText(_:)), key: "v", modifiers: [.command, .option, .shift])
        add("Delete", to: edit, action: #selector(NSText.delete(_:)))
        add("Select All", to: edit, action: #selector(NSText.selectAll(_:)), key: "a")
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        let findItem = NSMenuItem(title: "Find", action: nil, keyEquivalent: ""); findItem.submenu = find; edit.addItem(findItem)
        add("Search Library…", to: find, command: .searchLibrary, key: "f")
        for (title, key, modifiers, action) in [
            ("Find in Lyrics…", "", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", .command, .setSearchString)] {
            let item = add(title, to: find, action: #selector(LyricsTextView.performLyricsFindAction(_:)), key: key, modifiers: modifiers)
            item.tag = action.rawValue
        }
        add("Show Fonts", to: edit, action: #selector(NSFontManager.orderFrontFontPanel(_:)), key: "t").target = NSFontManager.shared

        let view = submenu("View")
        add("Show/Hide Sidebar", to: view, action: #selector(NSSplitViewController.toggleSidebar(_:)), key: "s", modifiers: [.command, .control])
        add("Enter Full Screen", to: view, action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control])

        let workspace = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        workspace.submenu = workspaceMenu; mainMenu.addItem(workspace)

        let slides = submenu("Slides")
        add("Show/Hide Slides", to: slides, command: .slides, shortcut: .toggleSlides)
        add("Stop Workspace Outputs", to: slides, command: .stop, shortcut: .stopOutputs)
        slides.addItem(.separator())
        add("Show/Hide Background", to: slides, command: .background)
        add("Pause/Play Background Audio", to: slides, command: .audio)
        slides.addItem(.separator())
        add("Clear Background Visual", to: slides, command: .clearBackground)
        add("Clear Background Audio", to: slides, command: .clearAudio)
        add("Clear All Layers", to: slides, command: .clearAll)
        slides.addItem(.separator())
        add("Stop All Outputs", to: slides, command: .stopAll)

        let output = NSMenuItem(title: "Output", action: nil, keyEquivalent: "")
        output.submenu = outputMenu; mainMenu.addItem(output)
        outputMenu.delegate = self
        rebuildOutputMenu()

        let window = submenu("Window")
        add("Minimize", to: window, action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add("Zoom", to: window, action: #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        let newWindow = NSMenuItem(title: "Open in New Window", action: nil, keyEquivalent: "")
        newWindow.submenu = workspaceCommands.makeOpenInNewWindowMenu()
        window.addItem(newWindow)
        window.addItem(.separator())
        add("Bring All to Front", to: window, action: #selector(NSApplication.arrangeInFront(_:)))

        let help = submenu("Help")
        add("eucaly Support", to: help, command: .support)
    }

    func install(in application: NSApplication) {
        application.mainMenu = mainMenu
        application.servicesMenu = mainMenu.item(at: 0)?.submenu?.item(withTitle: "Services")?.submenu
        application.windowsMenu = mainMenu.item(withTitle: "Window")?.submenu
        application.helpMenu = mainMenu.item(withTitle: "Help")?.submenu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === workspaceMenu { workspaceCommands.menuNeedsUpdate(menu) }
        else if menu === outputMenu { rebuildOutputMenu() }
    }
    private func rebuildOutputMenu() {
        outputMenu.removeAllItems()
        let listening = OutputAudioListeningState(outputs: app.outputs, workspaceID: app.outputs.commandWorkspaceID)
        if let listening { outputMenu.addItem(NSMenuItem(title: listening.scope, action: nil, keyEquivalent: "")) }
        let item = add(OutputAudioListeningState.title, to: outputMenu, command: .monitorAudioLocally)
        _ = validateMenuItem(item)
        outputMenu.addItem(NSMenuItem(title: listening?.detail ?? "Open a workspace to change local listening.", action: nil, keyEquivalent: ""))
        outputMenu.addItem(.separator())
        add("Manage Outputs…", to: outputMenu, command: .manageOutputs)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = command(for: menuItem) else { return workspaceCommands.validateMenuItem(menuItem) }
        switch command {
        case .updates: return app.updates.state.canCheckForUpdates
        case .newWorkspace: return workspaceCommands.canCreateWorkspace
        case .monitorAudioLocally:
            guard let listening = OutputAudioListeningState(outputs: app.outputs, workspaceID: app.outputs.commandWorkspaceID) else {
                menuItem.state = .off
                return false
            }
            menuItem.state = listening.isListening ? .on : .off
            menuItem.toolTip = listening.help
            return listening.canChange
        case .newLyrics, .searchLibrary, .refresh: return app.workspaceWindows.activeWorkspaceID != nil
        case .save:
            guard let id = app.workspaceWindows.activeWorkspaceID else { return false }
            return app.workspaceWindows.controllers[id]?.commands.canSaveLyrics == true
        case .slides: return WorkspacePresentationCommand.toggleSlides.isEnabled(in: app.outputs.commandWindow, outputs: app.outputs)
        case .stop: return WorkspacePresentationCommand.stopOutputs.isEnabled(in: app.outputs.commandWindow, outputs: app.outputs)
        case .audio: return app.outputs.commandSession?.backgroundAudioURL != nil
        case .background, .clearBackground, .clearAudio, .clearAll:
            return app.outputs.commandSession != nil
        case .stopAll: return app.outputs.isRunning
        case .settings, .notices, .support, .manageOutputs: return true
        }
    }

    @objc private func performCommand(_ sender: NSMenuItem) {
        guard validateMenuItem(sender), let command = command(for: sender) else { return }
        switch command {
        case .settings: app.showSettings()
        case .updates: app.updates.checkForUpdates()
        case .notices:
            if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt") { NSWorkspace.shared.open(url) }
        case .support: NSWorkspace.shared.open(URL(string: "https://sukujgrg.github.io/eucaly/")!)
        case .newWorkspace: app.workspaceWindows.newWorkspace()
        case .manageOutputs: app.showSettings(pane: .outputs)
        case .monitorAudioLocally:
            if let listening = OutputAudioListeningState(outputs: app.outputs, workspaceID: app.outputs.commandWorkspaceID), listening.canChange {
                app.outputs.setMonitorAudioLocally(!listening.workspace.monitorAudioLocally, workspace: listening.workspace.id)
            }
        case .newLyrics: post(.newLyrics)
        case .searchLibrary: post(.showLibrarySearch)
        case .refresh: post(.refreshLibrary)
        case .save: post(.saveLyrics)
        case .stop: WorkspacePresentationCommand.stopOutputs.perform(in: app.outputs.commandWindow, outputs: app.outputs)
        case .stopAll: app.outputs.stopAllOutputs()
        case .slides: WorkspacePresentationCommand.toggleSlides.perform(in: app.outputs.commandWindow, outputs: app.outputs)
        case .background: app.outputs.commandSession?.toggleBackgroundVisualVisibility()
        case .audio:
            if let session = app.outputs.commandSession {
                if session.isBackgroundAudioPlaying { session.pauseBackgroundAudio() } else { session.playBackgroundAudio() }
            }
        case .clearBackground: app.outputs.clearBackgrounds()
        case .clearAudio: app.outputs.clearAudio()
        case .clearAll: app.outputs.clearAllLayers()
        }
    }
    private func post(_ name: Notification.Name) { NotificationCenter.default.post(name: name, object: nil) }
    private func command(for item: NSMenuItem) -> Command? { item.identifier.flatMap { Command(rawValue: $0.rawValue) } }
    private func submenu(_ title: String) -> NSMenu {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title); item.submenu = menu; mainMenu.addItem(item)
        return menu
    }
    @discardableResult
    private func add(_ title: String, to menu: NSMenu, command: Command, shortcut: WorkspacePresentationCommand) -> NSMenuItem {
        add(title, to: menu, command: command, key: shortcut.keyEquivalent, modifiers: shortcut.modifiers)
    }
    @discardableResult
    private func add(_ title: String, to menu: NSMenu, command: Command, key: String = "",
                     modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = add(title, to: menu, action: #selector(performCommand(_:)), key: key, modifiers: modifiers)
        item.target = self; item.identifier = .init(command.rawValue)
        return item
    }
    @discardableResult
    private func add(_ title: String, to menu: NSMenu, action: Selector, key: String = "",
                     modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        menu.addItem(item)
        return item
    }
}
