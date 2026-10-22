import XCTest
@testable import eucaly

@MainActor
final class WorkspaceMigrationTests: XCTestCase {
    func testWorkspaceMigrationPreservesOperatorNamesAndRemovesRetiredLaunchPreference() throws {
        let store = OutputProfileStore()
        let other = try XCTUnwrap(store.addWorkspace(name: "Online"))
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(store.document)) as? [String: Any])
        root["workspaces"] = [["id": OutputWorkspaceRecord.primaryID.uuidString, "name": "Workspace 1"],
                              ["id": other.uuidString, "name": "Online"]]
        let home = try OutputLegacyMigration.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(home.workspaces.first?.name, "Home")
        XCTAssertEqual(home.destinations, store.document.destinations)
        root["workspaces"] = [["id": OutputWorkspaceRecord.primaryID.uuidString, "name": "Morning Service"],
                              ["id": other.uuidString, "name": "Online"]]
        let named = try OutputLegacyMigration.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(named.workspaces.first?.name, "Morning Service")
        root["defaultWorkspaceID"] = other.uuidString
        let migrated = try OutputLegacyMigration.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(migrated, named)
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any])
        XCTAssertNil(encoded["defaultWorkspaceID"])
        XCTAssertEqual(migrated.destinations, store.document.destinations)
        XCTAssertEqual(migrated.profiles, store.document.profiles)
        // A primary workspace named while the preference existed is operator
        // data, including an explicit reuse of the old built-in name.
        root["workspaces"] = [["id": OutputWorkspaceRecord.primaryID.uuidString, "name": "Workspace 1"]]
        let operatorNamed = try OutputLegacyMigration.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(operatorNamed.workspaces.first?.name, "Workspace 1")
        XCTAssertEqual(try OutputLegacyMigration.decode(JSONEncoder().encode(operatorNamed)), operatorNamed)
        root["workspaces"] = [["id": other.uuidString, "name": "Online"]]
        root["destinations"] = []
        root["defaultDestinationID"] = NSNull()
        root["defaultWorkspaceID"] = UUID().uuidString
        let recovered = try OutputLegacyMigration.decode(JSONSerialization.data(withJSONObject: root))
        XCTAssertEqual(recovered.workspaces, [.init(id: other, name: "Online")])
        XCTAssertTrue(recovered.isValid)
    }

    func testLegacyPairRetainsBothIdentitiesAppearancesNamesAndMusicChoice() throws {
        let store = OutputProfileStore()
        var lyrics = OutputDestinationConfiguration(name: "Worship Key", profileID: OutputProfile.audienceID, monitor: nil)
        lyrics.ndi = .init(sourceName: "Custom Worship")
        var media = OutputDestinationConfiguration(name: "Online Media", profileID: OutputProfile.audienceID, monitor: nil)
        media.ndi = .init(sourceName: "Custom Online")
        store.edit { $0.destinations += [lyrics, media]; $0.backgroundAudioDestinationID = media.id; $0.defaultDestinationID = lyrics.id }
        store.editDestinationProfile(lyrics.id) { $0.typography.size = 112; $0.background.colour = .chromaGreen }
        let original = store.document
        let migrated = try OutputLegacyMigration.decode(legacy(original))
        XCTAssertEqual(migrated.version, 6)
        XCTAssertEqual(migrated.workspaces, [.primary])
        XCTAssertEqual(migrated.destinations, original.destinations)
        XCTAssertEqual(migrated.profiles, original.profiles)
        XCTAssertEqual(migrated.defaultDestinationID, lyrics.id)
        XCTAssertEqual(migrated.backgroundAudioDestinationID, media.id)
        XCTAssertEqual(migrated.destinations.compactMap(\.ndi).map(\.sourceID), [lyrics.ndi!.sourceID, media.ndi!.sourceID])
        XCTAssertTrue(migrated.destinations.allSatisfy { $0.workspaceID == OutputWorkspaceRecord.primaryID })
        XCTAssertEqual(try OutputLegacyMigration.decode(JSONEncoder().encode(migrated)), migrated)
        let encoded = try XCTUnwrap(String(data: JSONEncoder().encode(migrated), encoding: .utf8))
        XCTAssertFalse(encoded.contains("\"role\""), "Legacy media roles are not a hidden mode in the new model")
    }
    func testDuplicateEnabledLegacyNamesAreDisabledInSavedOrderWithoutRenamingOrMerging() throws {
        var a = OutputDestinationConfiguration(name: "A", profileID: OutputProfile.audienceID, monitor: nil)
        a.ndi = .init(sourceName: "Worship")
        var b = OutputDestinationConfiguration(name: "B", profileID: OutputProfile.audienceID, monitor: nil)
        b.ndi = .init(sourceName: "worship")
        let document = OutputProfileDocument(profiles: OutputProfile.builtIns, destinations: [a, b])
        let migrated = try OutputLegacyMigration.decode(legacy(document))
        XCTAssertEqual(migrated.destinations.map(\.id), [a.id, b.id])
        XCTAssertTrue(migrated.destinations[0].enabled); XCTAssertFalse(migrated.destinations[1].enabled)
        XCTAssertEqual(migrated.destinations[1].ndi, b.ndi)
        XCTAssertTrue(migrated.isValid)
    }
    func testWorkspaceAndNativeMonitorAssignmentsRoundTripWithoutFocusFallback() throws {
        let store = OutputProfileStore()
        let other = try XCTUnwrap(store.addWorkspace(name: "Online"))
        let target = ProjectionMonitorTarget(identity: UUID().uuidString, name: "Saved monitor")
        let firstID = store.document.destinations[0].id
        store.edit { $0.destinations[0].monitor = target; $0.destinations[0].workspaceID = other }
        var unassigned = OutputDestinationConfiguration(name: "Unassigned", profileID: OutputProfile.audienceID, monitor: nil, enabled: false, workspaceID: nil)
        unassigned.ndi = .init(sourceName: "Unassigned")
        store.edit { $0.destinations.append(unassigned) }
        let saved = try OutputLegacyMigration.decode(JSONEncoder().encode(store.document))
        XCTAssertEqual(saved, store.document)
        XCTAssertEqual(saved.destinations.first { $0.id == firstID }?.workspaceID, other)
        XCTAssertEqual(saved.destinations.first { $0.id == firstID }?.monitor, target)
        XCTAssertNil(saved.destinations.last?.workspaceID)
    }
    func testOrphanedWorkspaceIsRecoveredWithoutEnablingAnyOfItsDestinations() throws {
        var a = OutputDestinationConfiguration(name: "One", profileID: OutputProfile.audienceID, monitor: nil)
        a.ndi = .init(sourceName: "One")
        var b = OutputDestinationConfiguration(name: "Two", profileID: OutputProfile.audienceID, monitor: nil)
        b.ndi = .init(sourceName: "Two")
        var doc = OutputProfileDocument(profiles: OutputProfile.builtIns, destinations: [a, b])
        let missing = UUID()
        for i in doc.destinations.indices { doc.destinations[i].workspaceID = missing }
        let restored = try OutputLegacyMigration.decode(JSONEncoder().encode(doc))
        XCTAssertEqual(restored.workspaces.last?.id, missing)
        XCTAssertTrue(restored.workspaces.last?.name.hasPrefix("Recovered Workspace") == true)
        XCTAssertEqual(restored.destinations.compactMap(\.workspaceID), [missing, missing])
        XCTAssertTrue(restored.destinations.allSatisfy { !$0.enabled })
        XCTAssertEqual(restored.destinations.compactMap(\.ndi), [a.ndi!, b.ndi!])
    }
    private func legacy(_ document: OutputProfileDocument) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        root["version"] = 5; root.removeValue(forKey: "workspaces")
        root["destinations"] = try XCTUnwrap(root["destinations"] as? [[String: Any]]).enumerated().map { index, original in
            var row = original; row.removeValue(forKey: "workspaceID")
            if var destination = row["destination"] as? [String: Any], var ndi = destination["ndi"] as? [String: Any], var settings = ndi["_0"] as? [String: Any] {
                settings["role"] = index == 1 ? "lyrics" : "media"; ndi["_0"] = settings; destination["ndi"] = ndi; row["destination"] = destination
            }
            return row
        }
        return try JSONSerialization.data(withJSONObject: root)
    }
}
