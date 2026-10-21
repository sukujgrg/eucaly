import AppKit
import XCTest
@testable import eucaly

@MainActor
final class AppMenuTests: XCTestCase {
    func testSlidesCommandRequiresCurrentInTheControlledWorkspace() throws {
        let hub = LocalOutputHarness()
        defer { hub.outputs.stopAllOutputs() }
        let app = AppDelegate()
        app.outputProfiles = hub.outputs.profiles; app.outputs = hub.outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: hub.outputs)
        let menus = AppMenuController(app: app)
        let slides = try XCTUnwrap(menus.mainMenu.item(withTitle: "Slides")?.submenu)
        let toggle = try XCTUnwrap(slides.item(withTitle: "Show/Hide Slides"))
        XCTAssertEqual(toggle.keyEquivalent, "2")
        XCTAssertFalse(menus.validateMenuItem(toggle))

        hub.load("Verse\nLoaded Current")
        XCTAssertTrue(menus.validateMenuItem(toggle))
        slides.performActionForItem(at: slides.index(of: toggle))
        XCTAssertTrue(hub.session.isPresenting)

        let otherID = try XCTUnwrap(app.outputProfiles.addWorkspace(name: "Online"))
        let other = hub.outputs.session(workspace: otherID)
        hub.outputs.focusWorkspace(other)
        XCTAssertFalse(menus.validateMenuItem(toggle), "Another workspace's Current cannot enable Cmd+2")
        // Virtual PDFs have no materialized slides but still count as Current.
        other.setPDFSlideSource(.init(url: URL(fileURLWithPath: "/tmp/menu-current.pdf"), pageCount: 200))
        XCTAssertTrue(other.slides.isEmpty)
        XCTAssertTrue(menus.validateMenuItem(toggle))

        hub.outputs.focusWorkspace(hub.session)
        hub.session.clearSlides()
        XCTAssertTrue(hub.session.isPresenting, "Clear retains the output")
        XCTAssertFalse(menus.validateMenuItem(toggle))
        let action = hub.session.outputActionClock.current
        slides.performActionForItem(at: slides.index(of: toggle))
        XCTAssertEqual(hub.session.outputActionClock.current, action)
        XCTAssertTrue(hub.outputs.isOpen(hub.nativeRow))
        for title in ["Stop Workspace Outputs", "Show/Hide Background", "Pause/Play Background Audio", "Clear All Layers"] {
            XCTAssertTrue(menus.validateMenuItem(try XCTUnwrap(slides.item(withTitle: title))))
        }
    }

    func testWorkspaceLimitDisablesCreationButKeepsManagementAvailable() throws {
        let hub = LocalOutputHarness()
        let app = AppDelegate()
        app.outputProfiles = hub.outputs.profiles; app.outputs = hub.outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: hub.outputs)
        defer { app.workspaceWindows.management?.window?.close(); for window in app.workspaceWindows.windows.values { window.close() } }
        for _ in 1..<4 { XCTAssertNotNil(app.outputProfiles.addWorkspace()) }
        let menus = AppMenuController(app: app)
        let file = try XCTUnwrap(menus.mainMenu.item(withTitle: "File")?.submenu)
        XCTAssertFalse(menus.validateMenuItem(try XCTUnwrap(file.item(withTitle: "New Workspace Tab"))))
        let manage = try XCTUnwrap(menus.workspaceMenu.item(withTitle: "Manage Workspaces…"))
        XCTAssertTrue(menus.validateMenuItem(manage)); XCTAssertTrue(manage.keyEquivalent.isEmpty)
        let saved = app.outputProfiles.document
        menus.workspaceMenu.performActionForItem(at: menus.workspaceMenu.index(of: manage))
        XCTAssertNotNil(app.workspaceWindows.management)
        XCTAssertEqual(app.outputProfiles.document, saved)
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
        XCTAssertEqual(file.item(withTitle: "New Workspace Tab")?.keyEquivalent, "t")
        XCTAssertEqual(file.item(withTitle: "New Lyrics")?.keyEquivalent, "n")
        XCTAssertEqual(file.item(withTitle: "Close Window")?.action, #selector(NSWindow.performClose(_:)))
    }

    func testWorkspaceMenuOpensSavedUUIDsAndNativeNewTabWithoutDuplicatingRecords() throws {
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
        XCTAssertEqual(saved.map(\.title), ["Open Home", "Open Home"])
        XCTAssertEqual(saved.compactMap { $0.representedObject as? UUID }, [hub.session.outputSourceID, secondID])
        let item = try XCTUnwrap(saved.last)
        let index = menus.workspaceMenu.index(of: item)
        menus.workspaceMenu.performActionForItem(at: index)
        let opened = try XCTUnwrap(app.workspaceWindows.controllers[secondID])
        menus.workspaceMenu.performActionForItem(at: index)
        XCTAssertTrue(app.workspaceWindows.controllers[secondID] === opened)
        XCTAssertEqual(app.outputProfiles.document.workspaces.count, 2)
        let file = try XCTUnwrap(menus.mainMenu.item(withTitle: "File")?.submenu)
        file.performActionForItem(at: file.indexOfItem(withTitle: "New Workspace Tab"))
        XCTAssertEqual(app.outputProfiles.document.workspaces.count, 3)
        let newID = try XCTUnwrap(app.outputProfiles.document.workspaces.last?.id)
        XCTAssertNotNil(app.workspaceWindows.controllers[newID])
        XCTAssertTrue(hub.outputs.destinations(workspace: newID).isEmpty)
        XCTAssertEqual(hub.outputs.destination(hub.nativeRow)?.workspaceID, hub.session.outputSourceID)
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
        let file = try XCTUnwrap(menus.mainMenu.item(withTitle: "File")?.submenu)
        let quickOpen = try XCTUnwrap(file.item(withTitle: "Quick Open…"))
        XCTAssertFalse(menus.validateMenuItem(quickOpen))
        let controller = try XCTUnwrap(app.workspaceWindows.open(hub.session.outputSourceID))
        focus.window = controller.window
        XCTAssertTrue(menus.validateMenuItem(quickOpen))
        controller.window?.performClose(nil)
        focus.window = nil
        XCTAssertFalse(menus.validateMenuItem(quickOpen))
        menus.menuNeedsUpdate(menus.workspaceMenu)
        let saved = try XCTUnwrap(menus.workspaceMenu.items.first { $0.representedObject as? UUID == hub.session.outputSourceID })
        XCTAssertTrue(menus.validateMenuItem(saved))
    }

    private func descendants(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { [$0] + ($0.submenu.map(descendants) ?? []) }
    }
}

@MainActor private final class MenuFocus { var window: NSWindow? }
