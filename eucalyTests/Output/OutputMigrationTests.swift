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
        XCTAssertNil(store.recoveryNotice); XCTAssertEqual(store.document.version, 7)
        XCTAssertEqual(store.document.destinations, document.destinations)
        XCTAssertEqual(store.audience, document.profiles[0])
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: OutputProfileStore.key))) as? [String: Any])
        XCTAssertNil(saved["receiverEnabled"])
        let savedProfiles = try XCTUnwrap(saved["profiles"] as? [[String: Any]])
        XCTAssertTrue(savedProfiles.allSatisfy { $0["scriptureRoles"] == nil })
        XCTAssertEqual(OutputProfileStore(defaults: defaults).document, store.document)
    }

    func testCurrentSavedProfilesDropScriptureOverridesAndKeepConfidencePlaybackStyle() throws {
        let suite = "ProfileOverrides.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var document = OutputProfileMigration.migrate(defaults: nil, monitor: nil)
        let confidence = try XCTUnwrap(document.profiles.firstIndex { $0.kind == .confidence })
        document.profiles[confidence].componentTypography[.footer] = .init(size: 23, colour: .white)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        var profiles = try XCTUnwrap(json["profiles"] as? [[String: Any]])
        for index in profiles.indices {
            var roles = try XCTUnwrap(profiles[index]["roles"] as? [String])
            roles.append(contentsOf: ["heading", "reference", "secondary", "footer"])
            profiles[index]["roles"] = roles
            var typography = try XCTUnwrap(profiles[index]["componentTypography"] as? [Any])
            for role in ["heading", "reference", "secondary"] { typography.append(contentsOf: [role, ["size": 9999]]) }
            if index != confidence { typography.append(contentsOf: ["footer", ["size": 9999]]) }
            profiles[index]["componentTypography"] = typography
        }
        json["profiles"] = profiles
        defaults.set(1, forKey: "outputProfileDefaultsRevision")
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: OutputProfileStore.key)
        let store = OutputProfileStore(defaults: defaults); store.flush()
        XCTAssertNil(store.recoveryNotice)
        XCTAssertEqual(store.document, document)
        XCTAssertEqual(defaults.integer(forKey: "outputProfileDefaultsRevision"), 2)
        XCTAssertEqual(store.profile(OutputProfile.confidenceID)?.typography(for: .footer).size, 23)
        for profile in store.document.profiles {
            XCTAssertEqual(profile.typographyOverrideRoles, OutputComponentRole.lyricRoles + (profile.kind == .confidence ? [.footer] : []))
        }
        XCTAssertEqual(OutputComponentRole.footer.title, "Playback status")
        let data = try XCTUnwrap(defaults.data(forKey: OutputProfileStore.key))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let savedProfiles = try XCTUnwrap(saved["profiles"] as? [[String: Any]])
        for profile in savedProfiles {
            let roles = try XCTUnwrap(profile["roles"] as? [String])
            XCTAssertTrue(Set(roles).isDisjoint(with: ["heading", "reference", "secondary", "footer"]))
            let typography = try XCTUnwrap(profile["componentTypography"] as? [Any])
            let keys = stride(from: 0, to: typography.count, by: 2).compactMap { typography[$0] as? String }
            XCTAssertTrue(Set(keys).isDisjoint(with: ["heading", "reference", "secondary"]))
            if profile["kind"] as? String != "confidence" { XCTAssertFalse(keys.contains("footer")) }
        }
        XCTAssertEqual(OutputProfileStore(defaults: defaults).document, document)
    }
}
