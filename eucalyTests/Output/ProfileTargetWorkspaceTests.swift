import AppKit
import XCTest
@testable import eucaly

@MainActor
final class ProfileTargetWorkspaceTests: XCTestCase {
    func testFactorySeedsHomeAudienceTarget() {
        let store = OutputProfileStore()
        let home = OutputWorkspaceRecord.primaryID
        let audience = try! XCTUnwrap(store.document.destinations.first)
        XCTAssertEqual(store.document.version, 9)
        XCTAssertEqual(store.document.profileTargets[home], audience.id)
        XCTAssertEqual(store.defaultDestination(for: home)?.profileID, OutputProfile.audienceID)
        XCTAssertNotNil(store.quickEditTarget(for: home))
    }

    func testV8MigratesOnlyOwningWorkspaceAndRetainsBackup() throws {
        let suite = "ProfileTargetMigrate.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(defaults: defaults)
        let home = OutputWorkspaceRecord.primaryID
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let homeRow = try XCTUnwrap(store.document.destinations.first)
        var onlineRow = OutputDestinationConfiguration(name: "Online Audience", profileID: OutputProfile.audienceID, monitor: nil)
        onlineRow.workspaceID = online
        store.edit { $0.destinations.append(onlineRow) }
        store.flush()

        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.document)) as? [String: Any])
        root["version"] = 8
        root.removeValue(forKey: "profileTargets")
        root["defaultDestinationID"] = homeRow.id.uuidString
        let legacy = try JSONSerialization.data(withJSONObject: root)
        defaults.set(legacy, forKey: OutputProfileStore.key)

        let migrated = OutputProfileStore(defaults: defaults)
        XCTAssertEqual(migrated.document.version, 9)
        XCTAssertEqual(migrated.document.profileTargets[home], homeRow.id,
                       "Migration must not steal the old global default into another workspace")
        XCTAssertEqual(migrated.document.profileTargets[online], onlineRow.id,
                       "Workspaces that already own destinations receive their own Profile Target")
        XCTAssertEqual(defaults.data(forKey: "outputProfilesProfileTargetMigrationBackup"), legacy)
    }

    func testAddOutputSeedsMissingProfileTargetWithoutSeedingOnMove() throws {
        let store = OutputProfileStore()
        let home = OutputWorkspaceRecord.primaryID
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        XCTAssertNil(store.document.profileTargets[online])

        var omt = OutputDestinationConfiguration(name: "OMT Output", profileID: OutputProfile.audienceID, monitor: nil, enabled: false)
        omt.workspaceID = online
        omt.destination = .omt(NetworkOutputSettings(sourceName: "eucaly"))
        store.edit { $0.destinations.append(omt) }
        XCTAssertEqual(store.document.profileTargets[online], omt.id, "Add Output seeds a missing Profile Target")

        store.setDefaultDestination(nil, workspace: online)
        XCTAssertNil(store.document.profileTargets[online])
        let homeRow = try XCTUnwrap(store.document.destinations.first { $0.workspaceID == home })
        store.edit { doc in
            if let index = doc.destinations.firstIndex(where: { $0.id == homeRow.id }) {
                doc.destinations[index].workspaceID = online
            }
        }
        XCTAssertNil(store.document.profileTargets[online], "Moving an existing output must not invent a Profile Target")
        XCTAssertNil(store.document.profileTargets[home], "Sanitizer clears Home when its targeted row moves away")
    }

    func testRevisionBackfillSeedsSparseProfileTargets() throws {
        let suite = "ProfileTargetBackfill.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(defaults: defaults)
        let home = OutputWorkspaceRecord.primaryID
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        var onlineRow = OutputDestinationConfiguration(name: "Online OMT", profileID: OutputProfile.audienceID, monitor: nil)
        onlineRow.workspaceID = online
        onlineRow.destination = .omt(NetworkOutputSettings(sourceName: "online"))
        store.edit { $0.destinations.append(onlineRow) }
        store.setDefaultDestination(nil, workspace: online)
        store.flush()
        // Simulate a sparse v9 document saved before Add Output seeding existed.
        defaults.set(2, forKey: "outputProfileDefaultsRevision")
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.document)) as? [String: Any])
        var targets = try XCTUnwrap(root["profileTargets"] as? [String: String])
        targets.removeValue(forKey: online.uuidString)
        root["profileTargets"] = targets
        defaults.set(try JSONSerialization.data(withJSONObject: root), forKey: OutputProfileStore.key)

        let restored = OutputProfileStore(defaults: defaults)
        XCTAssertEqual(restored.document.profileTargets[home], store.document.profileTargets[home])
        XCTAssertEqual(restored.document.profileTargets[online], onlineRow.id)
    }

    func testIsolationAndSharedProfileCaptionCoupling() throws {
        let store = OutputProfileStore()
        let home = OutputWorkspaceRecord.primaryID
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let homeRow = try XCTUnwrap(store.document.destinations.first)
        var onlineAudience = OutputDestinationConfiguration(name: "Online Audience", profileID: OutputProfile.confidenceID, monitor: nil)
        onlineAudience.workspaceID = online
        var onlineShared = OutputDestinationConfiguration(name: "Online Shared", profileID: homeRow.profileID, monitor: nil, enabled: false)
        onlineShared.workspaceID = online
        store.edit { $0.destinations.append(contentsOf: [onlineAudience, onlineShared]) }
        store.setDefaultDestination(homeRow.id, workspace: home)
        store.setDefaultDestination(onlineAudience.id, workspace: online)

        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
                                        driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let houseControls = OutputQuickControlsController(outputs: outputs, workspaceID: home, manageOutputs: {})
        let onlineControls = OutputQuickControlsController(outputs: outputs, workspaceID: online, manageOutputs: {})
        houseControls.render(); onlineControls.render()
        XCTAssertEqual(houseControls.background.title, "Solid colour")
        XCTAssertEqual(onlineControls.background.title, "Solid colour")

        store.editDefaultProfile(try XCTUnwrap(store.quickEditTarget(for: home))) {
            $0.background.bookmark = "house-asset"; $0.background.displayName = "house.png"
        }
        houseControls.render(); onlineControls.render()
        XCTAssertEqual(houseControls.background.title, "house.png")
        XCTAssertEqual(onlineControls.background.title, "Solid colour", "Different profiles keep independent captions")
        XCTAssertEqual(store.document.profileTargets[online], onlineAudience.id)

        store.setDefaultDestination(onlineShared.id, workspace: online)
        store.setEnabled(true, for: onlineShared.id)
        onlineControls.render()
        XCTAssertEqual(onlineControls.background.title, "house.png", "Shared Profile couples captions across workspaces")
        XCTAssertEqual(store.document.profileTargets[online], onlineShared.id)
        XCTAssertEqual(store.document.profileTargets[home], homeRow.id)
    }

    func testPickerOmitsForeignDestinationsAndRejectsForeignSetWithoutClearingSibling() throws {
        let store = OutputProfileStore()
        let home = OutputWorkspaceRecord.primaryID
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let homeRow = try XCTUnwrap(store.document.destinations.first)
        var onlineRow = OutputDestinationConfiguration(name: "Online Stage", profileID: OutputProfile.confidenceID, monitor: nil)
        onlineRow.workspaceID = online
        store.edit { $0.destinations.append(onlineRow) }
        store.setDefaultDestination(homeRow.id, workspace: home)
        store.setDefaultDestination(onlineRow.id, workspace: online)

        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
                                        driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let houseControls = OutputQuickControlsController(outputs: outputs, workspaceID: home, manageOutputs: {})
        let profileName = try XCTUnwrap(store.profile(homeRow.profileID)?.name)
        let ownedTitles = try XCTUnwrap(item(profileName, in: houseControls.appearance.menu).submenu).items.map(\.title)
        XCTAssertTrue(ownedTitles.contains("None"))
        XCTAssertTrue(ownedTitles.contains { $0.contains(homeRow.name) })
        XCTAssertFalse(ownedTitles.contains { $0.contains(onlineRow.name) }, "House picker must omit Online-owned destinations")

        store.setDefaultDestination(onlineRow.id, workspace: home)
        XCTAssertEqual(store.document.profileTargets[home], homeRow.id, "Foreign destination rejected")
        XCTAssertEqual(store.document.profileTargets[online], onlineRow.id, "Sibling workspace entry must remain")
    }

    func testDisableKeepsSelectionAndQuickEditNil() throws {
        let store = OutputProfileStore()
        let home = OutputWorkspaceRecord.primaryID
        let row = try XCTUnwrap(store.defaultDestination(for: home))
        XCTAssertNil(store.setEnabled(false, for: row.id))
        XCTAssertEqual(store.document.profileTargets[home], row.id)
        XCTAssertNil(store.quickEditTarget(for: home))
        XCTAssertNotNil(store.defaultDestination(for: home))
    }

    func testWorkspaceDeleteDropsOrphanProfileTarget() throws {
        let store = OutputProfileStore()
        let home = OutputWorkspaceRecord.primaryID
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        // Ownership mismatch and missing destinations are cleared by the edit() sanitizer.
        store.edit { $0.profileTargets[online] = $0.destinations[0].id }
        XCTAssertNil(store.document.profileTargets[online])
        store.edit { $0.profileTargets[online] = UUID() }
        XCTAssertNil(store.document.profileTargets[online], "Missing destination IDs are sanitized")
        XCTAssertNil(store.workspaceRemovalProblem(online))
        store.edit { $0.workspaces.removeAll { $0.id == online } }
        XCTAssertNil(store.document.profileTargets[online])
        XCTAssertEqual(store.document.workspaces.map(\.id), [home])
    }

    func testRemoveAndUndoRestoreRebindsOwningWorkspaceOnly() throws {
        let store = OutputProfileStore()
        let home = OutputWorkspaceRecord.primaryID
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let homeRow = try XCTUnwrap(store.document.destinations.first)
        var onlineRow = OutputDestinationConfiguration(name: "Online", profileID: OutputProfile.confidenceID, monitor: nil)
        onlineRow.workspaceID = online
        store.edit { $0.destinations.append(onlineRow) }
        store.setDefaultDestination(homeRow.id, workspace: home)
        store.setDefaultDestination(onlineRow.id, workspace: online)
        let removed = try XCTUnwrap(store.removeOutputConfiguration(homeRow.id))
        XCTAssertEqual(removed.editingTargetWorkspaceID, home)
        XCTAssertNil(store.document.profileTargets[home])
        XCTAssertEqual(store.document.profileTargets[online], onlineRow.id)
        XCTAssertNil(store.restoreOutputConfiguration(removed))
        XCTAssertEqual(store.document.profileTargets[home], homeRow.id)
        XCTAssertEqual(store.document.profileTargets[online], onlineRow.id)
    }

    func testDualWindowQuickEditGenerationIsWorkspaceScoped() throws {
        let store = OutputProfileStore()
        let home = OutputWorkspaceRecord.primaryID
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let homeRow = try XCTUnwrap(store.document.destinations.first)
        var onlineRow = OutputDestinationConfiguration(name: "Online", profileID: OutputProfile.confidenceID, monitor: nil)
        onlineRow.workspaceID = online
        store.edit { $0.destinations.append(onlineRow) }
        store.setDefaultDestination(homeRow.id, workspace: home)
        store.setDefaultDestination(onlineRow.id, workspace: online)
        let houseTarget = try XCTUnwrap(store.quickEditTarget(for: home))
        let onlineBefore = try XCTUnwrap(store.quickEditTarget(for: online))
        store.setDefaultDestination(nil, workspace: online)
        store.setDefaultDestination(onlineRow.id, workspace: online)
        XCTAssertEqual(store.quickEditTarget(for: home), houseTarget,
                       "Changing Online’s Profile Target must not invalidate House’s quick-edit generation")
        XCTAssertNotEqual(store.quickEditTarget(for: online), onlineBefore)
    }

    func testAppearanceHelpNamesSharedProfileWithoutForkGuidance() throws {
        let store = OutputProfileStore()
        let home = OutputWorkspaceRecord.primaryID
        let row = try XCTUnwrap(store.defaultDestination(for: home))
        let second = OutputDestinationConfiguration(name: "Copy", profileID: row.profileID, monitor: nil, enabled: false)
        store.edit { $0.destinations.append(second) }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
                                        driverFactory: { FakeOutputDriver() })
        defer { outputs.stop() }
        let controls = OutputQuickControlsController(outputs: outputs, workspaceID: home, manageOutputs: {})
        controls.render()
        let help = try XCTUnwrap(controls.appearance.accessibilityHelp)
        XCTAssertTrue(help.contains("shared profile"))
        XCTAssertFalse(help.localizedCaseInsensitiveContains("duplicate"))
        XCTAssertFalse(help.localizedCaseInsensitiveContains("independent look"))
    }
}

private extension ProfileTargetWorkspaceTests {
    func item(_ title: String, in menu: NSMenu?) throws -> NSMenuItem {
        func search(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if item.title == title { return item }
                if let nested = item.submenu, let found = search(nested) { return found }
            }
            return nil
        }
        return try XCTUnwrap(menu.flatMap(search), "Missing menu item \(title)")
    }
}
