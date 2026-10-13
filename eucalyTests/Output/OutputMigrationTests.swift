import XCTest
@testable import eucaly

@MainActor
final class OutputMigrationTests: XCTestCase {
    func testVersionTwoDropsBibleSettingsAndPreservesLocalAppearanceAndAssignments() throws {
        let suite = "ProfileRemoval.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let target = ProjectionMonitorTarget(identity: UUID().uuidString, name: "Audience")
        var document = OutputProfileMigration.migrate(defaults: nil, monitor: target)
        document.profiles[0].roles = [.meaning, .translation]
        document.profiles[0].typography.size = 117
        document.profiles[0].componentTypography[.meaning] = .init(size: 51, italic: true)
        document.profiles[0].background.colour = .init(red: 0.2, green: 0.3, blue: 0.4)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        json["version"] = 2; json["receiverEnabled"] = true
        var profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        profiles[0]["scriptureRoles"] = ["primary", "secondary", "reference", "footer"]
        profiles[0]["roles"] = ["meaning", "translation", "secondary"]
        var typography = try XCTUnwrap(profiles[0]["componentTypography"] as? [Any])
        typography.append(contentsOf: ["secondary", ["size": 9999]])
        profiles[0]["componentTypography"] = typography; json["profiles"] = profiles
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: OutputProfileStore.key)
        let store = OutputProfileStore(defaults: defaults); store.flush()
        XCTAssertNil(store.recoveryNotice); XCTAssertEqual(store.document.version, 3)
        XCTAssertEqual(store.document.destinations, document.destinations)
        XCTAssertEqual(store.audience, document.profiles[0])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: OutputProfileStore.key))) as? [String: Any])
        XCTAssertNil(saved["receiverEnabled"])
        let savedProfiles = try XCTUnwrap(saved["profiles"] as? [[String: Any]])
        XCTAssertTrue(savedProfiles.allSatisfy { $0["scriptureRoles"] == nil })
        XCTAssertEqual(OutputProfileStore(defaults: defaults).document, store.document)
    }
}
