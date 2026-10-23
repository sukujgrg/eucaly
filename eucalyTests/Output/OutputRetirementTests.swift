import XCTest
import Security
@testable import eucaly

@MainActor
final class OutputRetirementTests: XCTestCase {
    func testMixedLegacyDocumentRetainsNativeSettingsAndRemovesRetiredDefault() throws {
        let fixture = try legacy()
        let document = try OutputLegacyMigration.decode(fixture.data)
        XCTAssertEqual(document.version, 7)
        XCTAssertEqual(document.destinations, [fixture.native])
        XCTAssertNil(document.defaultDestinationID)
        XCTAssertEqual(document.profiles, fixture.profiles)
        XCTAssertEqual(try OutputLegacyMigration.decode(JSONEncoder().encode(document)), document)
    }
    func testRemoteOnlyDocumentCreatesNoReplacementOrAutomaticDestination() throws {
        var object = try legacy().object
        object["destinations"] = (object["destinations"] as! [[String: Any]]).dropFirst().map { $0 }
        let document = try OutputLegacyMigration.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(document.destinations.isEmpty)
        XCTAssertNil(document.defaultDestinationID)
    }
    func testVersionOneMonitorAssignmentSurvivesDisabledStateAndNativeDefault() throws {
        let fixture = try legacy()
        var object = fixture.object
        object["version"] = 1
        var rows = object["destinations"] as! [[String: Any]]
        let destination = rows[0].removeValue(forKey: "destination") as! [String: Any]
        rows[0]["monitor"] = (destination["monitor"] as! [String: Any])["_0"]
        object["destinations"] = rows; object["defaultDestinationID"] = fixture.native.id.uuidString
        let document = try OutputLegacyMigration.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(document.destinations, [fixture.native])
        XCTAssertEqual(document.defaultDestinationID, fixture.native.id)
    }
    func testInvalidLegacyConfigurationKeepsOriginalAndRecoversNativeAssignmentsWithoutCleanup() async throws {
        let suite = "RetirementRecovery.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try legacy(); var object = fixture.object
        var profiles = object["profiles"] as! [[String: Any]]; profiles[0]["layout"] = "unknown"
        object["profiles"] = profiles
        let data = try JSONSerialization.data(withJSONObject: object)
        defaults.set(data, forKey: OutputProfileStore.key)
        let recorder = CredentialDeletes()
        let cleanup = OutputRetirementCleanup(defaults: defaults, delete: recorder.delete)
        let store = OutputProfileStore(defaults: defaults, retirementCleanup: cleanup)
        await store.waitForPersistence(); await cleanup.waitForCompletion()
        XCTAssertNotNil(store.recoveryNotice)
        XCTAssertEqual(defaults.data(forKey: OutputProfileStore.key), data)
        XCTAssertEqual(store.document.destinations, [fixture.native])
        XCTAssertNil(store.document.defaultDestinationID)
        XCTAssertTrue(recorder.calls.isEmpty)
    }
    func testCleanupFollowsVerifiedPersistenceAndTouchesOnlyRetiredServicesOffMain() async throws {
        let suite = "RetirementCleanup.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(try legacy().data, forKey: OutputProfileStore.key)
        defaults.set("unrelated library", forKey: "libraryPath")
        defaults.set("old identity", forKey: "altViewSenderID")
        let recorder = CredentialDeletes()
        let cleanup = OutputRetirementCleanup(defaults: defaults, delete: recorder.delete)
        let store = OutputProfileStore(defaults: defaults, retirementCleanup: cleanup)
        await store.waitForPersistence(); await cleanup.waitForCompletion()
        let saved = try JSONDecoder().decode(OutputProfileDocument.self, from: XCTUnwrap(defaults.data(forKey: OutputProfileStore.key)))
        XCTAssertEqual(saved, store.document)
        XCTAssertEqual(Set(recorder.calls.map(\.service)), Set(OutputRetirementCleanup.services))
        XCTAssertEqual(recorder.calls.count, 4)
        XCTAssertTrue(recorder.calls.allSatisfy { !$0.main })
        XCTAssertNil(defaults.object(forKey: "altViewSenderID"))
        XCTAssertEqual(defaults.string(forKey: "libraryPath"), "unrelated library")
        cleanup.schedule(); await cleanup.waitForCompletion()
        XCTAssertEqual(recorder.calls.count, 4, "A completed retirement is not repeated")
    }
    func testDeniedCleanupHasBoundedRetryAndDoesNotResetConfiguration() async throws {
        let suite = "RetirementDenied.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recorder = CredentialDeletes(status: errSecInteractionNotAllowed)
        let cleanup = OutputRetirementCleanup(defaults: defaults, delete: recorder.delete)
        let store = OutputProfileStore(defaults: defaults, retirementCleanup: cleanup)
        await store.waitForPersistence(); await cleanup.waitForCompletion()
        let saved = defaults.data(forKey: OutputProfileStore.key)
        cleanup.schedule(); await cleanup.waitForCompletion()
        XCTAssertEqual(recorder.calls.count, 4)
        for count in 1...3 {
            defaults.set(["attempts": count, "lastAttempt": Date.distantPast, "complete": false], forKey: OutputRetirementCleanup.markerKey)
            cleanup.schedule(); await cleanup.waitForCompletion()
        }
        XCTAssertEqual(recorder.calls.count, 12)
        XCTAssertEqual(defaults.data(forKey: OutputProfileStore.key), saved)
        XCTAssertNil(store.recoveryNotice)
    }
    private struct Fixture {
        let object: [String: Any]
        let native: OutputDestinationConfiguration
        let profiles: [OutputProfile]
        var data: Data { get throws { try JSONSerialization.data(withJSONObject: object) } }
    }
    private func legacy() throws -> Fixture {
        var profiles = OutputProfile.builtIns
        profiles[0].typography.fontName = "Tamil MN"; profiles[0].padding = 1.3
        let native = OutputDestinationConfiguration(name: "Stage", profileID: OutputProfile.audienceID,
            monitor: .init(identity: UUID().uuidString, name: "Kept monitor"), enabled: false)
        let remoteID = UUID(), exclusiveID = UUID()
        var exclusive = profiles[0]; exclusive.id = exclusiveID; exclusive.customizedForDestinationID = remoteID
        var reusable = profiles[0]; reusable.id = UUID(); reusable.name = "Retained reusable style"
        profiles.append(reusable)
        let document = OutputProfileDocument(profiles: profiles, destinations: [native], defaultDestinationID: remoteID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        object["version"] = 4
        var rawProfiles = object["profiles"] as! [[String: Any]]
        var retired = rawProfiles[0]; retired["kind"] = "altView"; retired["id"] = "00000000-0000-4000-8000-000000000006"
        rawProfiles.append(retired)
        rawProfiles.append(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(exclusive)) as? [String: Any]))
        object["profiles"] = rawProfiles
        var rows = object["destinations"] as! [[String: Any]]
        rows.append(["id": remoteID.uuidString, "name": "Retired", "profileID": exclusiveID.uuidString, "enabled": true,
                     "destination": ["altView": ["_0": ["receiverID": UUID().uuidString, "name": "Receiver"]]]])
        rows.append(["id": UUID().uuidString, "name": "Retired media", "profileID": retired["id"]!, "enabled": false,
                     "destination": ["srt": ["_0": [:]]]])
        object["destinations"] = rows
        return .init(object: object, native: native, profiles: profiles)
    }
}

nonisolated private final class CredentialDeletes: @unchecked Sendable {
    struct Call { let service: String; let protected: Bool; let main: Bool }
    private let lock = NSLock()
    private var recorded: [Call] = []
    let status: OSStatus
    init(status: OSStatus = errSecSuccess) { self.status = status }
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    func delete(_ service: String, _ protected: Bool) -> OSStatus {
        lock.lock(); defer { lock.unlock() }
        recorded.append(.init(service: service, protected: protected, main: Thread.isMainThread)); return status
    }
}
