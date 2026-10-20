import XCTest
@testable import eucaly

@MainActor
final class WorkspaceAudioPreferenceTests: XCTestCase {
    func testNewWorkspacesDefaultToNoLocalMonitoring() throws {
        XCTAssertFalse(OutputWorkspaceRecord.primary.monitorAudioLocally)
        let store = OutputProfileStore()
        let id = try XCTUnwrap(store.addWorkspace(name: "Online"))
        XCTAssertFalse(try XCTUnwrap(store.document.workspaces.first { $0.id == id }).monitorAudioLocally)
        XCTAssertTrue(store.document.workspaces.allSatisfy { !$0.monitorAudioLocally })
    }

    func testLegacyWorkspaceWithoutMonitoringPreferenceDecodesQuietly() throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: ["id": id.uuidString, "name": "Online"])
        let record = try JSONDecoder().decode(OutputWorkspaceRecord.self, from: data)
        XCTAssertEqual(record.id, id)
        XCTAssertEqual(record.name, "Online")
        XCTAssertFalse(record.monitorAudioLocally)
        XCTAssertEqual(try JSONDecoder().decode(OutputWorkspaceRecord.self, from: JSONEncoder().encode(record)), record)
    }

    func testLocalMonitoringPreferencePersistsIndependentlyForEachWorkspace() throws {
        let suite = "WorkspaceAudioPreferenceTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(defaults: defaults)
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let other = try XCTUnwrap(store.addWorkspace(name: "Overflow"))
        store.edit { document in
            document.workspaces[document.workspaces.firstIndex { $0.id == online }!].monitorAudioLocally = true
        }
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
        let item = try XCTUnwrap(menus.workspaceMenu.item(withTitle: "Monitor Audio Locally"))
        XCTAssertFalse(menus.validateMenuItem(item))
        XCTAssertTrue(item.keyEquivalent.isEmpty)
        XCTAssertNil(item.representedObject, "The action must resolve the current command workspace rather than retain a menu-build UUID")

        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID), online = outputs.session(workspace: onlineID)
        outputs.focusWorkspace(home)
        outputs.setMonitorAudioLocally(true, workspace: home.outputSourceID)
        XCTAssertTrue(menus.validateMenuItem(item)); XCTAssertEqual(item.state, .on)
        outputs.focusWorkspace(online)
        XCTAssertTrue(menus.validateMenuItem(item)); XCTAssertEqual(item.state, .off)
        menus.workspaceMenu.performActionForItem(at: menus.workspaceMenu.index(of: item))
        XCTAssertTrue(outputs.monitorAudioLocally(workspace: onlineID))
        XCTAssertTrue(outputs.monitorAudioLocally(workspace: home.outputSourceID))

        // Keep the same menu item across another focus change. Its action
        // resolves the command workspace again at the moment of selection.
        outputs.focusWorkspace(home)
        menus.workspaceMenu.performActionForItem(at: menus.workspaceMenu.index(of: item))
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
}
