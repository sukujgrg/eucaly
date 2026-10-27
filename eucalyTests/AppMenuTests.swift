import AppKit
import XCTest
@testable import eucaly

@MainActor
final class AppMenuTests: XCTestCase {
    func testSaveLyricsUsesActiveEditorsCurrentEligibility() throws {
        let hub = LocalOutputHarness()
        let focus = MenuFocus()
        let app = AppDelegate()
        app.outputProfiles = hub.outputs.profiles; app.outputs = hub.outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: hub.outputs, keyWindow: { focus.window })
        let controls = try XCTUnwrap(app.workspaceWindows.open(hub.session.outputSourceID))
        defer { controls.window?.close(); hub.outputs.stopAllOutputs() }
        focus.window = controls.window
        let bridge = OutputWorkspaceCloseConfirmation.ConfirmationView(frame: .zero)
        controls.commands.closeConfirmation = bridge
        let menus = AppMenuController(app: app)
        let save = try XCTUnwrap(menus.mainMenu.item(withTitle: "File")?.submenu?.item(withTitle: "Save Lyrics"))
        for (description, eligible) in [("empty workspace", false), ("media Preview", false), ("clean lyrics", false), ("dirty lyrics", true), ("invalid empty draft", false)] {
            bridge.saveEligibility = { eligible }
            XCTAssertEqual(menus.validateMenuItem(save), eligible, description)
        }
        focus.window = nil
        XCTAssertFalse(menus.validateMenuItem(save))
    }

    func testStandbyOwnerWithoutControlsCanStopFromProjectionKeyboardAndMenu() async throws {
        let monitors = (1...2).map {
            ProjectionMonitor(id: UInt32($0), identity: UUID().uuidString, name: "Monitor \($0)",
                              frame: .init(x: 0, y: 0, width: 1920, height: 1080))
        }
        let displays = ProjectionDisplayManager(displays: { monitors })
        let profiles = OutputProfileStore(monitor: monitors[0].target)
        let owner = try XCTUnwrap(profiles.addWorkspace(name: "Stage"))
        let standby = OutputDestinationConfiguration(name: "Stage", profileID: OutputProfile.confidenceID,
                                                     monitor: monitors[1].target, workspaceID: owner)
        profiles.edit { $0.destinations.append(standby) }
        let focus = MenuFocus()
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, retainsPreparedSessions: true,
                                        keyWindow: { focus.window }, driverFactory: { FakeOutputDriver() })
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        let audience = profiles.document.destinations[0].id
        home.setSlides(LyricsParser.parseDocument("Verse\nKeep Home live").slides)
        home.showSlides()
        outputs.workspaceWindowReady(home)
        try await Task.sleep(for: .milliseconds(50))

        let projection = PresentationWindow(contentRect: .init(x: -10000, y: -10000, width: 100, height: 100),
                                            styleMask: .borderless, backing: .buffered, defer: false)
        projection.isReleasedWhenClosed = false
        projection.outputCoordinator = outputs; projection.outputDestinationID = standby.id
        focus.window = projection
        defer { outputs.stopAllOutputs(); projection.close() }
        let app = AppDelegate()
        app.outputProfiles = profiles; app.outputs = outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: outputs)
        let saved = profiles.document
        let menus = AppMenuController(app: app)
        let slides = try XCTUnwrap(menus.mainMenu.item(withTitle: "Slides")?.submenu)
        let stop = try XCTUnwrap(slides.item(withTitle: "Stop Workspace Outputs"))
        XCTAssertTrue(outputs.isOpen(standby.id))
        XCTAssertEqual(outputs.commandWorkspaceID, owner)
        XCTAssertNil(outputs.commandSession)
        XCTAssertTrue(menus.validateMenuItem(stop))
        XCTAssertFalse(menus.validateMenuItem(try XCTUnwrap(slides.item(withTitle: "Show/Hide Slides"))))
        menus.menuNeedsUpdate(menus.outputMenu)
        XCTAssertNil(outputs.preparedSession(workspace: owner), "Menu construction and validation must stay passive.")
        XCTAssertNil(outputs.preparedMedia(workspace: owner)?.program)
        XCTAssertTrue(app.workspaceWindows.controllers.isEmpty)
        XCTAssertEqual(profiles.document, saved)

        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift],
                                               timestamp: 0, windowNumber: projection.windowNumber, context: nil,
                                               characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        XCTAssertTrue(projection.performKeyEquivalent(with: key))
        XCTAssertFalse(outputs.isOpen(standby.id))
        XCTAssertTrue(outputs.isOpen(audience), "Stopping a workspace must preserve another workspace's program.")
        XCTAssertTrue(home.isPresenting)
        XCTAssertNil(outputs.preparedSession(workspace: owner))

        outputs.openConfidence(standby.id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(outputs.isOpen(standby.id))
        slides.performActionForItem(at: slides.index(of: stop))
        XCTAssertFalse(outputs.isOpen(standby.id))
        XCTAssertTrue(outputs.isOpen(audience))
        XCTAssertNil(outputs.preparedSession(workspace: owner))
        profiles.edit { $0.destinations.removeAll { $0.id == standby.id } }
        XCTAssertTrue(outputs.deleteWorkspace(owner))
        XCTAssertFalse(menus.validateMenuItem(stop), "A stale projection window must not fall back to focused Home.")
        XCTAssertTrue(projection.performKeyEquivalent(with: key))
        XCTAssertTrue(outputs.isOpen(audience))
    }

    func testSlidesCommandRequiresCurrentInTheControlledWorkspace() throws {
        let focus = MenuFocus()
        let hub = LocalOutputHarness(keyWindow: { focus.window })
        let window = OutputWorkspaceWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.workspaceSession = hub.session
        focus.window = window
        defer { hub.outputs.stopAllOutputs(); window.close() }
        let app = AppDelegate()
        app.outputProfiles = hub.outputs.profiles; app.outputs = hub.outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: hub.outputs)
        let menus = AppMenuController(app: app)
        let slides = try XCTUnwrap(menus.mainMenu.item(withTitle: "Slides")?.submenu)
        let toggle = try XCTUnwrap(slides.item(withTitle: "Show/Hide Slides"))
        XCTAssertEqual(toggle.keyEquivalent, "\r")
        XCTAssertEqual(toggle.keyEquivalentModifierMask, .command)
        XCTAssertFalse(menus.validateMenuItem(toggle))

        hub.load("Verse\nLoaded Current")
        XCTAssertTrue(menus.validateMenuItem(toggle))
        slides.performActionForItem(at: slides.index(of: toggle))
        XCTAssertTrue(hub.session.isPresenting)

        let otherID = try XCTUnwrap(app.outputProfiles.addWorkspace(name: "Online"))
        let other = hub.outputs.session(workspace: otherID)
        hub.outputs.focusWorkspace(other)
        window.workspaceSession = other
        XCTAssertFalse(menus.validateMenuItem(toggle), "Another workspace's Current cannot enable Command-Return")
        // Virtual PDFs have no materialized slides but still count as Current.
        other.setPDFSlideSource(.init(url: URL(fileURLWithPath: "/tmp/menu-current.pdf"), pageCount: 200))
        XCTAssertTrue(other.slides.isEmpty)
        XCTAssertTrue(menus.validateMenuItem(toggle))

        hub.outputs.focusWorkspace(hub.session)
        window.workspaceSession = hub.session
        hub.session.clearSlides()
        XCTAssertTrue(hub.session.isPresenting, "Clear retains the output")
        XCTAssertFalse(menus.validateMenuItem(toggle))
        let action = hub.session.outputActionClock.current
        slides.performActionForItem(at: slides.index(of: toggle))
        XCTAssertEqual(hub.session.outputActionClock.current, action)
        XCTAssertTrue(hub.outputs.isOpen(hub.nativeRow))
        hub.session.setBackgroundAudio(url: URL(fileURLWithPath: "/tmp/menu-selected-track.caf"), autoplay: false)
        defer { hub.session.clearBackgroundAudio() }
        for title in ["Stop Workspace Outputs", "Show/Hide Background", "Pause/Play Background Audio", "Clear All Layers"] {
            XCTAssertTrue(menus.validateMenuItem(try XCTUnwrap(slides.item(withTitle: title))))
        }
    }

    func testWorkspaceLimitDisablesCreationButKeepsManagementAvailable() throws {
        let suite = "WorkspaceSettingsMenu." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hub = LocalOutputHarness()
        let app = AppDelegate(settingsDefaults: defaults)
        app.outputProfiles = hub.outputs.profiles; app.outputs = hub.outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: hub.outputs, manageWorkspaces: { [weak app] in app?.showSettings(pane: .workspaces) })
        defer { app.settings?.close(); for window in app.workspaceWindows.windows.values { window.close() } }
        for _ in 1..<4 { XCTAssertNotNil(app.outputProfiles.addWorkspace()) }
        let menus = AppMenuController(app: app)
        let file = try XCTUnwrap(menus.mainMenu.item(withTitle: "File")?.submenu)
        XCTAssertFalse(menus.validateMenuItem(try XCTUnwrap(file.item(withTitle: "New Workspace"))))
        let manage = try XCTUnwrap(menus.workspaceMenu.item(withTitle: "Manage Workspaces…"))
        XCTAssertTrue(menus.validateMenuItem(manage)); XCTAssertTrue(manage.keyEquivalent.isEmpty)
        let saved = app.outputProfiles.document
        app.showSettings(pane: .general)
        let window = try XCTUnwrap(app.settings?.window)
        menus.workspaceMenu.performActionForItem(at: menus.workspaceMenu.index(of: manage))
        XCTAssertTrue(app.settings?.window === window)
        XCTAssertEqual(app.settings?.settings.selectedPane, .workspaces)
        XCTAssertEqual(app.settings?.settings.workspaces.isPresented, true)
        XCTAssertTrue(app.workspaceWindows.controllers.isEmpty)
        XCTAssertEqual(app.outputProfiles.document, saved)
        XCTAssertFalse(hub.outputs.isRunning)
        let manageOutputs = try XCTUnwrap(menus.outputMenu.item(withTitle: "Manage Outputs…"))
        menus.outputMenu.performActionForItem(at: menus.outputMenu.index(of: manageOutputs))
        XCTAssertTrue(app.settings?.window === window)
        XCTAssertEqual(app.settings?.settings.selectedPane, .outputs)
        XCTAssertFalse(hub.outputs.isRunning)
    }

    func testNativeMenusPreserveEditingResponderChainAndShortcutAssignments() throws {
        let app = AppDelegate()
        let menus = AppMenuController(app: app)
        let edit = try XCTUnwrap(menus.mainMenu.item(withTitle: "Edit")?.submenu)
        for (title, action, key) in [
            ("Undo", Selector(("undo:")), "z"),
            ("Cut", #selector(NSText.cut(_:)), "x"),
            ("Copy", #selector(NSText.copy(_:)), "c"),
            ("Paste", #selector(NSText.paste(_:)), "v"),
            ("Select All", #selector(NSText.selectAll(_:)), "a")
        ] {
            let item = try XCTUnwrap(edit.item(withTitle: title))
            XCTAssertNil(item.target, "Editing actions must reach the active field editor")
            XCTAssertEqual(item.action, action)
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(item.keyEquivalentModifierMask, .command)
        }
        let shortcuts = descendants(menus.mainMenu).filter { !$0.keyEquivalent.isEmpty }
        let grouped = Dictionary(grouping: shortcuts) { $0.keyEquivalent + ":" + String($0.keyEquivalentModifierMask.rawValue) }
        XCTAssertTrue(grouped.values.allSatisfy { $0.count == 1 }, "Every command shortcut must have one owner")
        let file = try XCTUnwrap(menus.mainMenu.item(withTitle: "File")?.submenu)
        XCTAssertEqual(file.item(withTitle: "New Workspace")?.keyEquivalent, "n")
        XCTAssertEqual(file.item(withTitle: "New Workspace")?.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(file.item(withTitle: "New Lyrics")?.keyEquivalent, "n")
        let fonts = try XCTUnwrap(edit.item(withTitle: "Show Fonts"))
        XCTAssertEqual(fonts.keyEquivalent, "t")
        XCTAssertEqual(fonts.keyEquivalentModifierMask, .command)
        XCTAssertEqual(fonts.action, #selector(NSFontManager.orderFrontFontPanel(_:)))
        XCTAssertTrue(fonts.target === NSFontManager.shared)
        let slides = try XCTUnwrap(menus.mainMenu.item(withTitle: "Slides")?.submenu)
        XCTAssertEqual(Array(slides.items.prefix(2).map(\.title)), ["Show/Hide Slides", "Stop Workspace Outputs"])
        XCTAssertEqual(slides.item(withTitle: "Stop Workspace Outputs")?.keyEquivalent, "\r")
        XCTAssertEqual(slides.item(withTitle: "Stop Workspace Outputs")?.keyEquivalentModifierMask, [.command, .shift])
        for title in ["Clear Background Visual", "Clear Background Audio", "Clear All Layers", "Stop All Outputs"] {
            XCTAssertEqual(slides.item(withTitle: title)?.keyEquivalent, "")
        }
        XCTAssertFalse(shortcuts.contains { ["1", "2", "3", "4", "5"].contains($0.keyEquivalent) })
        XCTAssertEqual(file.item(withTitle: "Close Window")?.action, #selector(NSWindow.performClose(_:)))
        XCTAssertNil(file.item(withTitle: "Quick Open…"))
        XCTAssertFalse(shortcuts.contains { $0.keyEquivalent == "o" && $0.keyEquivalentModifierMask == [.command, .shift] })
        let find = try XCTUnwrap(edit.item(withTitle: "Find")?.submenu)
        let search = try XCTUnwrap(find.item(withTitle: "Search Library…"))
        XCTAssertEqual(search.keyEquivalent, "f")
        XCTAssertEqual(search.keyEquivalentModifierMask, .command)
        XCTAssertTrue(search.target === menus)
        let lyricsFind = try XCTUnwrap(find.item(withTitle: "Find in Lyrics…"))
        XCTAssertTrue(lyricsFind.keyEquivalent.isEmpty)
        XCTAssertNil(lyricsFind.target)
        for (title, key, modifiers) in [("Find Next", "g", NSEvent.ModifierFlags.command),
                                      ("Find Previous", "g", [.command, .shift]),
                                      ("Use Selection for Find", "e", .command)] {
            let item = try XCTUnwrap(find.item(withTitle: title))
            XCTAssertNil(item.target)
            XCTAssertEqual(item.action, #selector(LyricsTextView.performLyricsFindAction(_:)))
            XCTAssertEqual(item.keyEquivalent, key)
            XCTAssertEqual(item.keyEquivalentModifierMask, modifiers)
        }
    }

    func testCommandFDispatchesLibrarySearchAcrossWorkspaceRespondersWithoutChangingCurrent() throws {
        let hub = LocalOutputHarness(), focus = MenuFocus()
        let app = AppDelegate()
        app.outputProfiles = hub.outputs.profiles; app.outputs = hub.outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: hub.outputs, keyWindow: { focus.window })
        defer { for window in app.workspaceWindows.windows.values { window.close() } }
        let controller = try XCTUnwrap(app.workspaceWindows.open(hub.session.outputSourceID))
        let window = try XCTUnwrap(controller.window)
        focus.window = window
        hub.load("Verse\nKeep Current")
        let savedSlides = hub.session.slides.map(\.id), action = hub.session.outputActionClock.current
        let menus = AppMenuController(app: app)
        let lyrics = LyricsTextView(frame: .init(x: 0, y: 0, width: 200, height: 100))
        lyrics.string = "Unsaved lyrics draft"
        let sidebar = NSOutlineView(frame: .init(x: 0, y: 100, width: 100, height: 100))
        let preview = NSCollectionView(frame: .init(x: 100, y: 100, width: 100, height: 100))
        let current = NSCollectionView(frame: .init(x: 200, y: 100, width: 100, height: 100))
        let field = NSSearchField(frame: .init(x: 0, y: 200, width: 200, height: 28))
        let results = LibrarySearchTableView(frame: .init(x: 0, y: 230, width: 200, height: 100))
        let responders: [NSView] = [lyrics, sidebar, preview, current, field, results]
        responders.forEach { window.contentView?.addSubview($0) }
        let requests = MenuSearchRequests()
        let observation = NotificationCenter.default.addObserver(forName: .showLibrarySearch, object: nil, queue: nil) { _ in
            MainActor.assumeIsolated { requests.count += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observation) }
        for responder in responders {
            XCTAssertTrue(window.makeFirstResponder(responder))
            if responder === lyrics { lyrics.setSelectedRange(.init(location: 8, length: 0)) }
            let before = requests.count
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f",
                charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
            XCTAssertTrue(menus.mainMenu.performKeyEquivalent(with: key))
            XCTAssertEqual(requests.count, before + 1)
        }
        XCTAssertEqual(lyrics.string, "Unsaved lyrics draft")
        XCTAssertEqual(lyrics.selectedRange(), .init(location: 8, length: 0))
        XCTAssertEqual(hub.session.slides.map(\.id), savedSlides)
        XCTAssertEqual(hub.session.outputActionClock.current, action)
        XCTAssertFalse(hub.outputs.isRunning)
        let oldShortcut = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [.command, .shift], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: "O", charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31))
        XCTAssertFalse(menus.mainMenu.performKeyEquivalent(with: oldShortcut))
        XCTAssertEqual(requests.count, responders.count)
    }

    func testWorkspaceMenuOpensSavedUUIDsAndCreatesWorkspacesWithoutDuplicatingRecords() throws {
        let hub = LocalOutputHarness()
        let app = AppDelegate()
        app.outputProfiles = hub.outputs.profiles
        app.outputs = hub.outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: hub.outputs)
        defer { for window in app.workspaceWindows.windows.values { window.close() } }
        let secondID = try XCTUnwrap(app.outputProfiles.addWorkspace(name: "Home"))
        let menus = AppMenuController(app: app)
        menus.menuNeedsUpdate(menus.workspaceMenu)
        let saved = menus.workspaceMenu.items.filter { $0.representedObject is UUID }
        XCTAssertEqual(saved.map(\.title), ["Home", "Home"])
        XCTAssertTrue(saved.allSatisfy { $0.image != nil && $0.image?.isTemplate == false })
        XCTAssertEqual(saved.compactMap { $0.representedObject as? UUID }, [hub.session.outputSourceID, secondID])
        let item = try XCTUnwrap(saved.last)
        let index = menus.workspaceMenu.index(of: item)
        menus.workspaceMenu.performActionForItem(at: index)
        let opened = try XCTUnwrap(app.workspaceWindows.controllers[secondID])
        menus.workspaceMenu.performActionForItem(at: index)
        XCTAssertTrue(app.workspaceWindows.controllers[secondID] === opened)
        XCTAssertEqual(app.outputProfiles.document.workspaces.count, 2)
        let file = try XCTUnwrap(menus.mainMenu.item(withTitle: "File")?.submenu)
        file.performActionForItem(at: file.indexOfItem(withTitle: "New Workspace"))
        XCTAssertEqual(app.outputProfiles.document.workspaces.count, 3)
        let newID = try XCTUnwrap(app.outputProfiles.document.workspaces.last?.id)
        XCTAssertNotNil(app.workspaceWindows.controllers[newID])
        XCTAssertTrue(hub.outputs.destinations(workspace: newID).isEmpty)
        XCTAssertEqual(hub.outputs.destination(hub.nativeRow)?.workspaceID, hub.session.outputSourceID)
    }

    func testToolbarAndMenuBarWorkspaceChoicesMatchAndCurrentSelectionIsEnabledAndInert() async throws {
        let hub = LocalOutputHarness(), focus = MenuFocus()
        let app = AppDelegate()
        app.outputProfiles = hub.outputs.profiles; app.outputs = hub.outputs
        let peerID = try XCTUnwrap(app.outputProfiles.addWorkspace(name: "Home"))
        app.workspaceWindows = makeWorkspaceWindows(outputs: hub.outputs, keyWindow: { focus.window })
        defer { for window in app.workspaceWindows.windows.values { window.close() } }
        let home = try XCTUnwrap(app.workspaceWindows.open(hub.session.outputSourceID))
        let homeControls = try XCTUnwrap(app.workspaceWindows.controllers[hub.session.outputSourceID])
        let window = try XCTUnwrap(home.window)
        focus.window = home.window
        let menus = AppMenuController(app: app)
        let toolbar = OutputWorkspaceMenuController(workspaces: app.workspaceWindows, workspaceID: hub.session.outputSourceID)
        let toolbarItems = Array(toolbar.menu.items.dropFirst())
        XCTAssertEqual(toolbarItems.map(\.title), menus.workspaceMenu.items.map(\.title))
        XCTAssertEqual(toolbarItems.map(\.isSeparatorItem), menus.workspaceMenu.items.map(\.isSeparatorItem))
        XCTAssertEqual(toolbarItems.map(\.isEnabled), menus.workspaceMenu.items.map(\.isEnabled))
        XCTAssertEqual(toolbarItems.last?.title, "Manage Workspaces…")
        XCTAssertEqual(toolbarItems.dropLast().last?.isSeparatorItem, true)
        XCTAssertNotNil(menus.workspaceMenu.item(withTitle: "Rename Workspace…"))
        let toolbarChoices = toolbar.menu.items.filter { $0.representedObject is UUID }
        let barChoices = menus.workspaceMenu.items.filter { $0.representedObject is UUID }
        XCTAssertEqual(toolbarChoices.map(\.title), barChoices.map(\.title))
        XCTAssertEqual(toolbarChoices.map(\.subtitle), barChoices.map(\.subtitle))
        XCTAssertEqual(toolbarChoices.map(\.subtitle), ["Stopped", "No outputs"])
        XCTAssertEqual(toolbarChoices.count, 2)
        for (choice, barChoice) in zip(toolbarChoices, barChoices) {
            XCTAssertTrue(menus.validateMenuItem(barChoice))
            XCTAssertTrue(choice.isEnabled, "The current choice is selected, not unavailable")
            XCTAssertEqual(choice.state, barChoice.state)
            XCTAssertNotNil(choice.image); XCTAssertNotNil(barChoice.image)
            XCTAssertEqual(choice.image?.isTemplate, false)
            XCTAssertEqual(barChoice.image?.isTemplate, false)
        }
        let current = try XCTUnwrap(toolbarChoices.first)
        XCTAssertEqual(current.state, .on)
        let saved = app.outputProfiles.document
        let action = hub.session.outputActionClock.current
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(current.action), to: current.target, from: current))
        let barCurrent = try XCTUnwrap(barChoices.first)
        menus.workspaceMenu.performActionForItem(at: menus.workspaceMenu.index(of: barCurrent))
        XCTAssertTrue(app.workspaceWindows.controllers[hub.session.outputSourceID] === homeControls)
        XCTAssertEqual(app.workspaceWindows.controllers.count, 1)
        XCTAssertEqual(app.outputProfiles.document, saved)
        XCTAssertEqual(hub.session.outputActionClock.current, action)
        XCTAssertFalse(hub.outputs.isRunning)
        let peer = try XCTUnwrap(toolbarChoices.last)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(peer.action), to: peer.target, from: peer))
        XCTAssertNotNil(app.workspaceWindows.controllers[peerID])
        XCTAssertEqual(app.workspaceWindows.controllers.count, 2)
        XCTAssertEqual(app.workspaceWindows.windows.count, 1)
        XCTAssertTrue(app.workspaceWindows.windows[peerID] === window)
        XCTAssertNil(homeControls.window)
        XCTAssertFalse(toolbar.validateMenuItem(peer), "A retained sidebar menu cannot act after its controls are parked")
        XCTAssertEqual(app.outputProfiles.document, saved)
    }

    func testClosedWorkspaceDoesNotReceiveCommandsAndRemainsAvailableToReopen() throws {
        let hub = LocalOutputHarness()
        let app = AppDelegate()
        app.outputProfiles = hub.outputs.profiles
        app.outputs = hub.outputs
        let focus = MenuFocus()
        app.workspaceWindows = makeWorkspaceWindows(outputs: hub.outputs, keyWindow: { focus.window })
        defer { for window in app.workspaceWindows.windows.values { window.close() } }
        let menus = AppMenuController(app: app)
        let edit = try XCTUnwrap(menus.mainMenu.item(withTitle: "Edit")?.submenu)
        let find = try XCTUnwrap(edit.item(withTitle: "Find")?.submenu)
        let search = try XCTUnwrap(find.item(withTitle: "Search Library…"))
        XCTAssertFalse(menus.validateMenuItem(search))
        let controller = try XCTUnwrap(app.workspaceWindows.open(hub.session.outputSourceID))
        focus.window = controller.window
        XCTAssertTrue(menus.validateMenuItem(search))
        controller.window?.performClose(nil)
        focus.window = nil
        XCTAssertFalse(menus.validateMenuItem(search))
        menus.menuNeedsUpdate(menus.workspaceMenu)
        let saved = try XCTUnwrap(menus.workspaceMenu.items.first { $0.representedObject as? UUID == hub.session.outputSourceID })
        XCTAssertTrue(menus.validateMenuItem(saved))
    }

    func testWorkspaceActionsValidateSwitchingAndExplicitWindowsBeforeChangingSavedState() async throws {
        let hub = LocalOutputHarness(), focus = MenuFocus()
        let app = AppDelegate()
        app.outputProfiles = hub.outputs.profiles; app.outputs = hub.outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: hub.outputs, keyWindow: { focus.window })
        defer { for window in app.workspaceWindows.windows.values { window.close() } }
        hub.load("Verse\nKeep Current")
        let id = hub.session.outputSourceID
        let otherID = try XCTUnwrap(app.outputProfiles.addWorkspace(name: "Online"))
        let home = try XCTUnwrap(app.workspaceWindows.open(id))
        let homeControls = try XCTUnwrap(app.workspaceWindows.controllers[id])
        let window = try XCTUnwrap(home.window)
        focus.window = window
        let menus = AppMenuController(app: app)
        let toolbar = OutputWorkspaceMenuController(workspaces: app.workspaceWindows, workspaceID: id)
        let windowMenu = try XCTUnwrap(menus.mainMenu.item(withTitle: "Window")?.submenu)
        for title in ["Show All Tabs", "Show Tab Bar", "Select Next Tab", "Select Previous Tab", "Move Tab to New Window"] {
            XCTAssertNil(windowMenu.item(withTitle: title))
        }
        XCTAssertEqual(window.tabbingMode, .disallowed)
        let newWindow = try XCTUnwrap(windowMenu.item(withTitle: "Open in New Window")?.submenu)
        XCTAssertEqual(newWindow.items.compactMap { $0.representedObject as? UUID }, [id, otherID])
        let switchChoice = try XCTUnwrap(menus.workspaceMenu.items.first { $0.representedObject as? UUID == otherID })
        let rename = try XCTUnwrap(menus.workspaceMenu.item(withTitle: "Rename Workspace…"))
        let retainedRename = try XCTUnwrap(toolbar.menu.item(withTitle: "Rename Workspace…"))
        XCTAssertTrue(menus.validateMenuItem(rename))
        let current = hub.session.slides.map(\.id)
        let assignments = app.outputProfiles.document.destinations
        menus.workspaceMenu.performActionForItem(at: menus.workspaceMenu.index(of: rename))
        let field = try XCTUnwrap(home.renamer.field)
        let sheet = try XCTUnwrap(window.attachedSheet)
        XCTAssertFalse(menus.validateMenuItem(rename))
        XCTAssertFalse(menus.validateMenuItem(switchChoice), "A workspace switch must not replace controls below a modal sheet")
        let file = try XCTUnwrap(menus.mainMenu.item(withTitle: "File")?.submenu)
        XCTAssertFalse(menus.validateMenuItem(try XCTUnwrap(file.item(withTitle: "New Workspace"))))
        menus.workspaceMenu.performActionForItem(at: menus.workspaceMenu.index(of: switchChoice))
        XCTAssertTrue(app.workspaceWindows.windows[id] === window)
        XCTAssertNil(app.workspaceWindows.controllers[otherID])
        for value in ["", " \n ", "House\nOnline", String(repeating: "é", count: 81)] {
            field.stringValue = value; field.currentEditor()?.string = value
            home.renamer.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
            XCTAssertEqual(sheet.defaultButtonCell?.isEnabled, false)
        }
        field.stringValue = "  House  "; field.currentEditor()?.string = "  House  "
        home.renamer.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(sheet.defaultButtonCell?.isEnabled, true)
        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        for _ in 0..<30 {
            if home.renamer.field == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(app.outputProfiles.workspaceName(id), "House")
        XCTAssertEqual(hub.session.slides.map(\.id), current)
        XCTAssertEqual(app.outputProfiles.document.destinations, assignments)
        XCTAssertFalse(hub.outputs.isRunning)
        let saved = app.outputProfiles.document
        menus.workspaceMenu.performActionForItem(at: menus.workspaceMenu.index(of: switchChoice))
        XCTAssertTrue(app.workspaceWindows.windows[otherID] === window)
        XCTAssertNil(homeControls.window)
        XCTAssertFalse(toolbar.validateMenuItem(retainedRename), "Parked controls cannot rename another workspace through an old menu")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(retainedRename.action), to: retainedRename.target, from: retainedRename))
        XCTAssertEqual(app.outputProfiles.document, saved)
        XCTAssertEqual(app.workspaceWindows.controllers.count, 2)
        XCTAssertEqual(app.workspaceWindows.windows.count, 1)
        XCTAssertTrue(app.workspaceWindows.controllers[id] === homeControls)
        newWindow.delegate?.menuNeedsUpdate?(newWindow)
        let separateHome = try XCTUnwrap(newWindow.items.first { $0.representedObject as? UUID == id })
        XCTAssertTrue(menus.validateMenuItem(separateHome))
        newWindow.performActionForItem(at: newWindow.index(of: separateHome))
        let homeWindow = try XCTUnwrap(homeControls.window)
        focus.window = homeWindow
        XCTAssertFalse(homeWindow === window)
        XCTAssertTrue(app.workspaceWindows.windows[otherID] === window)
        XCTAssertEqual(app.workspaceWindows.windows.count, 2)
        XCTAssertTrue(app.workspaceWindows.controllers[id] === homeControls)
        newWindow.performActionForItem(at: newWindow.index(of: separateHome))
        XCTAssertEqual(app.workspaceWindows.windows.count, 2, "An already-visible workspace must reuse its controls window")
        XCTAssertTrue(homeControls.window === homeWindow)
        XCTAssertEqual(app.outputProfiles.document, saved)
        XCTAssertEqual(hub.session.slides.map(\.id), current)
        let staleOther = try XCTUnwrap(newWindow.items.first { $0.representedObject as? UUID == otherID })
        XCTAssertNil(app.workspaceWindows.deleteWorkspace(otherID))
        XCTAssertFalse(menus.validateMenuItem(staleOther))
        newWindow.performActionForItem(at: newWindow.index(of: staleOther))
        XCTAssertNil(app.workspaceWindows.controllers[otherID])
        toolbar.menuNeedsUpdate(toolbar.menu)
        let toolbarRename = try XCTUnwrap(toolbar.menu.item(withTitle: "Rename Workspace…"))
        toolbar.menu.performActionForItem(at: toolbar.menu.index(of: toolbarRename))
        let unconfirmed = try XCTUnwrap(homeControls.renamer.field)
        unconfirmed.stringValue = "Unconfirmed"; unconfirmed.currentEditor()?.string = "Unconfirmed"
        homeWindow.close()
        for _ in 0..<30 {
            if homeControls.renamer.field == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(homeControls.renamer.field)
        XCTAssertEqual(app.outputProfiles.workspaceName(id), "House")
    }

    private func descendants(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(descendants) ?? []) }
    }
}

@MainActor private final class MenuFocus { var window: NSWindow? }
@MainActor private final class MenuSearchRequests { var count = 0 }
