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
        let store = OutputProfileStore(), transport = RecordingNDIOutput()
        let onlineID = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
            ndi: transport, keyWindow: { nil })
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

    func testOutputMenusShareListeningStateAndKeepItIndependentOfDefaultOutputAndFocus() throws {
        let store = OutputProfileStore(), transport = RecordingNDIOutput()
        let peerID = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), ndi: transport, keyWindow: { nil })
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID), peer = outputs.session(workspace: peerID)
        outputs.focusWorkspace(home)
        let app = AppDelegate()
        app.outputProfiles = store; app.outputs = outputs
        app.workspaceWindows = makeWorkspaceWindows(outputs: outputs)
        let menus = AppMenuController(app: app)
        let controls = OutputQuickControlsController(outputs: outputs, workspaceID: home.outputSourceID, manageOutputs: {})
        let peerControls = OutputQuickControlsController(outputs: outputs, workspaceID: peerID, manageOutputs: {})
        let menuItem = try XCTUnwrap(menus.outputMenu.item(withTitle: "Listen on This Mac"))
        let toolbarItem = try XCTUnwrap(controls.outputButton.menu?.item(withTitle: "Listen on This Mac"))
        XCTAssertTrue(toolbarItem.isEnabled)
        XCTAssertEqual(toolbarItem.state, .on)
        XCTAssertTrue(menus.validateMenuItem(menuItem)); XCTAssertEqual(menuItem.state, .on)
        XCTAssertNotNil(controls.outputButton.menu?.item(withTitle: "Audio for Home"))
        XCTAssertNotNil(menus.outputMenu.item(withTitle: "Uses the default macOS audio output."))
        XCTAssertNotNil(controls.outputButton.menu?.item(withTitle: "Uses the default macOS audio output."))
        XCTAssertEqual(toolbarItem.toolTip, menuItem.toolTip)

        // A toolbar action is scoped to its own window, even when another
        // workspace became the command target after its menu was constructed.
        outputs.focusWorkspace(peer)
        try invoke(toolbarItem)
        XCTAssertFalse(outputs.monitorAudioLocally(workspace: home.outputSourceID))
        XCTAssertTrue(outputs.monitorAudioLocally(workspace: peerID))
        XCTAssertEqual(controls.outputButton.menu?.item(withTitle: "Listen on This Mac")?.state, .off)
        peerControls.render()
        XCTAssertEqual(peerControls.outputButton.menu?.item(withTitle: "Listen on This Mac")?.state, .on)
        outputs.focusWorkspace(home)
        XCTAssertTrue(menus.validateMenuItem(menuItem)); XCTAssertEqual(menuItem.state, .off)
        menus.outputMenu.performActionForItem(at: menus.outputMenu.index(of: menuItem))
        controls.render()
        XCTAssertEqual(controls.outputButton.menu?.item(withTitle: "Listen on This Mac")?.state, .on)

        store.setDefaultDestination(nil); controls.render()
        XCTAssertTrue(try XCTUnwrap(controls.outputButton.menu?.item(withTitle: "Listen on This Mac")).isEnabled)
        XCTAssertFalse(controls.appearanceButton.isEnabled)
        store.renameWorkspace(home.outputSourceID, name: "House"); controls.render()
        menus.menuNeedsUpdate(menus.outputMenu)
        XCTAssertNotNil(controls.outputButton.menu?.item(withTitle: "Audio for House"))
        XCTAssertNotNil(menus.outputMenu.item(withTitle: "Audio for House"))
        XCTAssertFalse(outputs.isRunning); XCTAssertTrue(transport.starts.isEmpty)

        let retained = try XCTUnwrap(peerControls.outputButton.menu?.item(withTitle: "Listen on This Mac"))
        XCTAssertTrue(outputs.deleteWorkspace(peerID))
        let saved = store.document
        try invoke(retained)
        XCTAssertEqual(store.document, saved, "A retained listening action cannot recreate a deleted workspace")
    }

    func testNativeProjectionExplainsEffectiveLocalAudioWithoutOverwritingSavedPreference() throws {
        let hub = LocalOutputHarness()
        defer { hub.outputs.stopAllOutputs() }
        let id = hub.session.outputSourceID
        hub.outputs.setMonitorAudioLocally(false, workspace: id)
        let controls = OutputQuickControlsController(outputs: hub.outputs, workspaceID: id, manageOutputs: {})
        let retained = try XCTUnwrap(controls.outputButton.menu?.item(withTitle: "Listen on This Mac"))
        hub.load("Verse\nNative audio")
        hub.session.showSlides(); controls.render()
        let item = try XCTUnwrap(controls.outputButton.menu?.item(withTitle: "Listen on This Mac"))
        XCTAssertFalse(item.isEnabled); XCTAssertEqual(item.state, .on)
        XCTAssertNotNil(controls.outputButton.menu?.item(withTitle: "Native projection uses the default macOS audio output."))
        try invoke(retained)
        XCTAssertFalse(hub.outputs.monitorAudioLocally(workspace: id))
        hub.outputs.closeOutput(hub.nativeRow); controls.render()
        let closed = try XCTUnwrap(controls.outputButton.menu?.item(withTitle: "Listen on This Mac"))
        XCTAssertTrue(closed.isEnabled); XCTAssertEqual(closed.state, .off)
    }

    func testStandaloneMusicExplainsItsLocalRouteWithoutChangingTheNDIOnlyPreference() throws {
        let store = OutputProfileStore(), outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }))
        let session = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        defer { session.clearBackgroundAudio() }
        outputs.setMonitorAudioLocally(false, workspace: session.outputSourceID)
        session.setBackgroundAudio(url: URL(fileURLWithPath: "/tmp/listening-standalone.caf"), autoplay: true)
        let controls = OutputQuickControlsController(outputs: outputs, workspaceID: session.outputSourceID, manageOutputs: {})
        let item = try XCTUnwrap(controls.outputButton.menu?.item(withTitle: "Listen on This Mac"))
        XCTAssertEqual(item.state, .on); XCTAssertFalse(item.isEnabled)
        XCTAssertNotNil(controls.outputButton.menu?.item(withTitle: "Standalone music uses the default macOS audio output."))
        XCTAssertFalse(outputs.monitorAudioLocally(workspace: session.outputSourceID))
        session.clearBackgroundAudio(); controls.render()
        XCTAssertTrue(try XCTUnwrap(controls.outputButton.menu?.item(withTitle: "Listen on This Mac")).isEnabled)
        XCTAssertEqual(controls.outputButton.menu?.item(withTitle: "Listen on This Mac")?.state, .off)
    }

    private func invoke(_ item: NSMenuItem) throws {
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
    }
}
