import AppKit

/// Native application menus use the responder chain for editing and window
/// actions. Presentation actions resolve their workspace in OutputCoordinator.
@MainActor
final class AppMenuController: NSObject, NSMenuDelegate, NSMenuItemValidation {
    private unowned let app: AppDelegate
    let mainMenu = NSMenu()
    let workspaceMenu = NSMenu(title: "Workspace")

    private enum Command: String {
        case settings, updates, notices, support, newWorkspace, openWorkspace, detach, manageWorkspaces
        case newLyrics, quickOpen, refresh, save, stop, stopAll, slides, background, audio
        case clearBackground, clearAudio, clearAll
    }

    init(app: AppDelegate) {
        self.app = app
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
        add("New Workspace Tab", to: file, command: .newWorkspace, key: "t")
        add("Quick Open…", to: file, command: .quickOpen, key: "o", modifiers: [.command, .shift])
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
        for (title, key, modifiers, action) in [
            ("Find…", "f", NSEvent.ModifierFlags.command, NSTextFinder.Action.showFindInterface),
            ("Find Next", "g", .command, .nextMatch),
            ("Find Previous", "g", [.command, .shift], .previousMatch),
            ("Use Selection for Find", "e", .command, .setSearchString)] {
            let item = add(title, to: find, action: #selector(NSTextView.performTextFinderAction(_:)), key: key, modifiers: modifiers)
            item.tag = action.rawValue
        }
        add("Show Fonts", to: edit, action: #selector(NSFontManager.orderFrontFontPanel(_:))).target = NSFontManager.shared

        let view = submenu("View")
        add("Show/Hide Sidebar", to: view, action: #selector(NSSplitViewController.toggleSidebar(_:)), key: "s", modifiers: [.command, .control])
        add("Enter Full Screen", to: view, action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control])

        let workspace = NSMenuItem(title: "Workspace", action: nil, keyEquivalent: "")
        workspace.submenu = workspaceMenu; mainMenu.addItem(workspace)
        workspaceMenu.delegate = self
        rebuildWorkspaceMenu()

        let slides = submenu("Slides")
        add("Stop Workspace Outputs", to: slides, command: .stop, key: "1")
        add("Stop All Outputs", to: slides, command: .stopAll)
        slides.addItem(.separator())
        add("Show/Hide Slides", to: slides, command: .slides, key: "2")
        add("Show/Hide Background", to: slides, command: .background)
        add("Pause/Play Background Audio", to: slides, command: .audio)
        slides.addItem(.separator())
        add("Clear Background Visual", to: slides, command: .clearBackground, key: "3")
        add("Clear Background Audio", to: slides, command: .clearAudio, key: "4")
        add("Clear All Layers", to: slides, command: .clearAll, key: "5")

        let window = submenu("Window")
        add("Minimize", to: window, action: #selector(NSWindow.performMiniaturize(_:)), key: "m")
        add("Zoom", to: window, action: #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add("Show All Tabs", to: window, action: #selector(NSWindow.toggleTabOverview(_:)))
        add("Show Tab Bar", to: window, action: #selector(NSWindow.toggleTabBar(_:)))
        add("Select Next Tab", to: window, action: #selector(NSWindow.selectNextTab(_:)), key: "\t", modifiers: [.control])
        add("Select Previous Tab", to: window, action: #selector(NSWindow.selectPreviousTab(_:)), key: "\t", modifiers: [.control, .shift])
        add("Move Tab to New Window", to: window, command: .detach)
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
        if menu === workspaceMenu { rebuildWorkspaceMenu() }
    }
    private func rebuildWorkspaceMenu() {
        workspaceMenu.removeAllItems()
        add("New Workspace Tab", to: workspaceMenu, command: .newWorkspace)
        add("Manage Workspaces…", to: workspaceMenu, command: .manageWorkspaces)
        add("Move Tab to New Window", to: workspaceMenu, command: .detach)
        workspaceMenu.addItem(.separator())
        for record in app.outputProfiles.document.workspaces {
            let item = add("Open " + record.name, to: workspaceMenu, command: .openWorkspace)
            item.representedObject = record.id
            item.state = app.workspaceWindows.activeWorkspaceID == record.id ? .on : .off
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let command = command(for: menuItem) else { return false }
        switch command {
        case .updates: return app.updates.state.canCheckForUpdates
        case .newWorkspace: return app.workspaceWindows.canCreateWorkspace
        case .detach: return app.workspaceWindows.activeWorkspaceID != nil
        case .newLyrics, .quickOpen, .refresh, .save: return app.workspaceWindows.activeWorkspaceID != nil
        case .stop, .slides, .background, .audio, .clearBackground, .clearAudio, .clearAll:
            return app.outputs.commandSession != nil
        case .stopAll: return app.outputs.isRunning
        case .openWorkspace:
            return (menuItem.representedObject as? UUID).map { id in app.outputProfiles.document.workspaces.contains { $0.id == id } } ?? false
        case .settings, .notices, .support, .manageWorkspaces: return true
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
        case .manageWorkspaces: app.workspaceWindows.showManagement()
        case .openWorkspace:
            if let id = sender.representedObject as? UUID { app.workspaceWindows.open(id, beside: app.workspaceWindows.activeWorkspaceID) }
        case .detach:
            if let id = app.workspaceWindows.activeWorkspaceID { app.workspaceWindows.detach(id) }
        case .newLyrics: post(.newLyrics)
        case .quickOpen: post(.showLibrarySearch)
        case .refresh: post(.refreshLibrary)
        case .save: post(.saveLyrics)
        case .stop: app.outputs.stop()
        case .stopAll: app.outputs.stopAllOutputs()
        case .slides: app.outputs.toggleSlides()
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
