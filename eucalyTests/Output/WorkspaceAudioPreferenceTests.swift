import AppKit
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceAudioPreferenceTests: XCTestCase {
    func testImmediateRestoreReadsLatestListeningPreferenceAfterQueuedEdits() throws {
        let suite = "WorkspaceAudioQueuedRestore." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = OutputProfileStore(defaults: defaults)
        defer { store.flush(); defaults.removePersistentDomain(forName: suite) }
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        store.flush()
        for revision in 0..<200 {
            store.edit { document in
                document.workspaces[1].monitorAudioLocally = revision.isMultiple(of: 2)
                document.workspaces[1].name = "Online \(revision)"
            }
        }
        let expected = store.document
        let restored = OutputProfileStore(defaults: defaults)
        defer { restored.flush() }
        XCTAssertEqual(restored.document, expected, "Restoration must read after earlier queued saves, without a caller flushing first")
        XCTAssertFalse(try XCTUnwrap(restored.document.workspaces.first { $0.id == online }).monitorAudioLocally)
    }

    func testNewWorkspacesDefaultToLocalListening() throws {
        XCTAssertTrue(OutputWorkspaceRecord.primary.monitorAudioLocally)
        let store = OutputProfileStore()
        let id = try XCTUnwrap(store.addWorkspace(name: "Online"))
        XCTAssertTrue(try XCTUnwrap(store.document.workspaces.first { $0.id == id }).monitorAudioLocally)
        XCTAssertTrue(store.document.workspaces.allSatisfy(\.monitorAudioLocally))
    }

    func testLegacyWorkspaceWithoutMonitoringPreferenceUsesCurrentDefault() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "name": "Online"])
        let record = try JSONDecoder().decode(OutputWorkspaceRecord.self, from: data)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.name, "Online")
        XCTAssertTrue(record.monitorAudioLocally)
        XCTAssertEqual(try JSONDecoder().decode(OutputWorkspaceRecord.self, from: JSONEncoder().encode(record)), record)
    }

    func testLocalMonitoringPreferencePersistsIndependentlyForEachWorkspace() throws {
        let suite = "WorkspaceAudioPreferenceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(defaults: defaults)
        defer { store.flush() }
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let other = try XCTUnwrap(store.addWorkspace(name: "Overflow"))
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }))
        outputs.setMonitorAudioLocally(false, workspace: OutputWorkspaceRecord.primaryID)
        outputs.setMonitorAudioLocally(false, workspace: other)
        store.flush()

        let restored = OutputProfileStore(defaults: defaults)
        XCTAssertEqual(restored.document, store.document)
        XCTAssertTrue(try XCTUnwrap(restored.document.workspaces.first { $0.id == online }).monitorAudioLocally)
        XCTAssertFalse(try XCTUnwrap(restored.document.workspaces.first { $0.id == other }).monitorAudioLocally)
        XCTAssertFalse(try XCTUnwrap(restored.document.workspaces.first { $0.id == OutputWorkspaceRecord.primaryID }).monitorAudioLocally)

        restored.edit { document in
            document.workspaces[document.workspaces.firstIndex { $0.id == online }!].monitorAudioLocally = false
        }
        restored.flush()
        XCTAssertTrue(OutputProfileStore(defaults: defaults).document.workspaces.allSatisfy { !$0.monitorAudioLocally })
    }

    func testNativeMonitoringMenuRevalidatesTheCommandWorkspaceWithoutStartingOutput() throws {
        let store = OutputProfileStore(), transport = RecordingNetworkOutput()
        let onlineID = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
            network: transport, keyWindow: { nil })
        let app = AppDelegate()
        app.outputProfiles = store; app.outputs = outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: outputs)
        let menus = AppMenuController(app: app)
        XCTAssertNil(menus.workspaceMenu.item(withTitle: "Monitor Audio Locally"))
        XCTAssertNil(menus.workspaceMenu.item(withTitle: "Listen on This Mac"))
        let item = try XCTUnwrap(menus.outputMenu.item(withTitle: "Listen on This Mac"))
        XCTAssertFalse(menus.validateMenuItem(item))
        XCTAssertTrue(item.keyEquivalent.isEmpty)
        XCTAssertNil(item.representedObject, "The action must resolve the current command workspace rather than retain a menu-build UUID")

        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID), online = outputs.session(workspace: onlineID)
        outputs.focusWorkspace(home)
        outputs.setMonitorAudioLocally(false, workspace: onlineID)
        XCTAssertTrue(menus.validateMenuItem(item)); XCTAssertEqual(item.state, .on)
        outputs.focusWorkspace(online)
        XCTAssertTrue(menus.validateMenuItem(item)); XCTAssertEqual(item.state, .off)
        menus.outputMenu.performActionForItem(at: menus.outputMenu.index(of: item))
        XCTAssertTrue(outputs.monitorAudioLocally(workspace: onlineID))
        XCTAssertTrue(outputs.monitorAudioLocally(workspace: home.outputSourceID))

        // Keep the same menu item across another focus change. Its action
        // resolves the command workspace again at the moment of selection.
        outputs.focusWorkspace(home)
        menus.outputMenu.performActionForItem(at: menus.outputMenu.index(of: item))
        XCTAssertFalse(outputs.monitorAudioLocally(workspace: home.outputSourceID))
        XCTAssertTrue(outputs.monitorAudioLocally(workspace: onlineID))
        XCTAssertFalse(outputs.isRunning)
        XCTAssertTrue(transport.starts.isEmpty)

        store.edit {
            $0.destinations.removeAll { $0.workspaceID == home.outputSourceID }
            $0.workspaces.removeAll { $0.id == home.outputSourceID }
        }
        XCTAssertFalse(menus.validateMenuItem(item), "A retained action cannot target a removed workspace")
        XCTAssertEqual(item.state, .off)
    }

    func testMenubarListeningIsIndependentOfDefaultOutputAndFocus() throws {
        let store = OutputProfileStore(), transport = RecordingNetworkOutput()
        let peerID = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), network: transport, keyWindow: { nil })
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID), peer = outputs.session(workspace: peerID)
        outputs.focusWorkspace(home)
        let app = AppDelegate()
        app.outputProfiles = store; app.outputs = outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: outputs)
        let menus = AppMenuController(app: app)
        let controls = OutputQuickControlsController(outputs: outputs, workspaceID: home.outputSourceID, manageOutputs: {})
        func listenItem() throws -> NSMenuItem {
            // menuNeedsUpdate rebuilds Output; always resolve the live item before acting.
            try XCTUnwrap(menus.outputMenu.item(withTitle: "Listen on This Mac"))
        }
        var menuItem = try listenItem()
        XCTAssertNotNil(menus.outputMenu.item(withTitle: "Audio"))
        XCTAssertFalse(controls.network.menu?.items.contains { $0.title == OutputAudioListeningState.title } == true,
                       "Listen belongs on the menubar Output menu, not Network")
        XCTAssertTrue(menus.validateMenuItem(menuItem)); XCTAssertEqual(menuItem.state, .on)
        XCTAssertTrue(try XCTUnwrap(menuItem.toolTip).contains("Audio for Home"))
        XCTAssertTrue(try XCTUnwrap(menuItem.toolTip).contains("Uses the default macOS audio output."))

        outputs.focusWorkspace(peer)
        menus.menuNeedsUpdate(menus.outputMenu)
        menuItem = try listenItem()
        XCTAssertTrue(menus.validateMenuItem(menuItem)); XCTAssertEqual(menuItem.state, .on)
        menus.outputMenu.performActionForItem(at: menus.outputMenu.index(of: menuItem))
        XCTAssertFalse(outputs.monitorAudioLocally(workspace: peerID))
        XCTAssertTrue(outputs.monitorAudioLocally(workspace: home.outputSourceID))
        outputs.focusWorkspace(home)
        menus.menuNeedsUpdate(menus.outputMenu)
        menuItem = try listenItem()
        XCTAssertTrue(menus.validateMenuItem(menuItem)); XCTAssertEqual(menuItem.state, .on)
        menus.outputMenu.performActionForItem(at: menus.outputMenu.index(of: menuItem))
        XCTAssertFalse(outputs.monitorAudioLocally(workspace: home.outputSourceID))

        store.setDefaultDestination(nil, workspace: OutputWorkspaceRecord.primaryID); controls.render()
        XCTAssertTrue(controls.appearance.isEnabled, "Appearance stays openable to choose a Profile Target")
        XCTAssertFalse(controls.background.isEnabled)
        store.renameWorkspace(home.outputSourceID, name: "House")
        menus.menuNeedsUpdate(menus.outputMenu)
        menuItem = try listenItem()
        _ = menus.validateMenuItem(menuItem)
        XCTAssertTrue(try XCTUnwrap(menuItem.toolTip).contains("Audio for House"))
        XCTAssertFalse(outputs.isRunning); XCTAssertTrue(transport.starts.isEmpty)

        outputs.focusWorkspace(peer)
        menus.menuNeedsUpdate(menus.outputMenu)
        menuItem = try listenItem()
        _ = menus.validateMenuItem(menuItem)
        XCTAssertTrue(outputs.deleteWorkspace(peerID))
        XCTAssertNil(store.document.workspaces.first { $0.id == peerID })
        menus.menuNeedsUpdate(menus.outputMenu)
        menuItem = try listenItem()
        XCTAssertTrue(menus.validateMenuItem(menuItem), "Listen retargets the remaining workspace; it cannot revive the deleted one")
        XCTAssertTrue(try XCTUnwrap(menuItem.toolTip).contains("Audio for House"))
        let saved = store.document
        menus.outputMenu.performActionForItem(at: menus.outputMenu.index(of: menuItem))
        XCTAssertNil(store.document.workspaces.first { $0.id == peerID }, "Listen must not recreate a deleted workspace")
        XCTAssertNotEqual(store.document, saved, "Listen continues to edit the remaining workspace’s preference")
    }

    func testNativeProjectionExplainsEffectiveLocalAudioWithoutOverwritingSavedPreference() throws {
        let hub = LocalOutputHarness()
        defer { hub.outputs.stopAllOutputs() }
        let id = hub.session.outputSourceID
        hub.outputs.setMonitorAudioLocally(false, workspace: id)
        let app = AppDelegate()
        app.outputProfiles = hub.outputs.profiles; app.outputs = hub.outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: hub.outputs)
        let menus = AppMenuController(app: app)
        hub.outputs.focusWorkspace(hub.session)
        menus.menuNeedsUpdate(menus.outputMenu)
        var item = try XCTUnwrap(menus.outputMenu.item(withTitle: "Listen on This Mac"))
        XCTAssertTrue(menus.validateMenuItem(item)); XCTAssertEqual(item.state, .off)
        hub.load("Verse\nNative audio")
        hub.session.showSlides()
        menus.menuNeedsUpdate(menus.outputMenu)
        item = try XCTUnwrap(menus.outputMenu.item(withTitle: "Listen on This Mac"))
        XCTAssertFalse(menus.validateMenuItem(item)); XCTAssertEqual(item.state, .on)
        XCTAssertTrue(try XCTUnwrap(item.toolTip).contains("Native projection"))
        menus.outputMenu.performActionForItem(at: menus.outputMenu.index(of: item))
        XCTAssertFalse(hub.outputs.monitorAudioLocally(workspace: id), "Locked effective listening must not overwrite the saved preference")
        hub.outputs.closeOutput(hub.nativeRow)
        menus.menuNeedsUpdate(menus.outputMenu)
        item = try XCTUnwrap(menus.outputMenu.item(withTitle: "Listen on This Mac"))
        XCTAssertTrue(menus.validateMenuItem(item)); XCTAssertEqual(item.state, .off)
    }

    func testStandaloneMusicExplainsItsLocalRouteWithoutChangingTheNDIOnlyPreference() throws {
        let store = OutputProfileStore(), outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }))
        let session = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        defer { session.clearBackgroundAudio() }
        outputs.setMonitorAudioLocally(false, workspace: session.outputSourceID)
        let app = AppDelegate()
        app.outputProfiles = store; app.outputs = outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: outputs)
        let menus = AppMenuController(app: app)
        outputs.focusWorkspace(session)
        session.setBackgroundAudio(url: URL(fileURLWithPath: "/tmp/listening-standalone.caf"), autoplay: true)
        menus.menuNeedsUpdate(menus.outputMenu)
        var item = try XCTUnwrap(menus.outputMenu.item(withTitle: "Listen on This Mac"))
        XCTAssertFalse(menus.validateMenuItem(item)); XCTAssertEqual(item.state, .on)
        XCTAssertTrue(try XCTUnwrap(item.toolTip).contains("Standalone music"))
        XCTAssertFalse(outputs.monitorAudioLocally(workspace: session.outputSourceID))
        session.clearBackgroundAudio()
        menus.menuNeedsUpdate(menus.outputMenu)
        item = try XCTUnwrap(menus.outputMenu.item(withTitle: "Listen on This Mac"))
        XCTAssertTrue(menus.validateMenuItem(item)); XCTAssertEqual(item.state, .off)
    }
}
