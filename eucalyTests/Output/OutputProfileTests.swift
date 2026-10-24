import XCTest
@testable import eucaly

@MainActor
final class OutputProfileTests: XCTestCase {
    func testOMTSourceNamesAreReservedWithinTheirProtocolAndEditsKeepTheProtocol() throws {
        let store = OutputProfileStore()
        var ndi = OutputDestinationConfiguration(name: "NDI", profileID: OutputProfile.audienceID, monitor: nil)
        ndi.ndi = .init(sourceName: "eucaly")
        var first = OutputDestinationConfiguration(name: "OMT", profileID: OutputProfile.audienceID, monitor: nil)
        first.omt = .init(sourceName: "eucaly")
        var second = OutputDestinationConfiguration(name: "Second OMT", profileID: OutputProfile.audienceID,
            monitor: nil, enabled: false)
        second.omt = .init(sourceName: "EUCALY")
        store.edit { $0.destinations = [ndi, first, second] }
        XCTAssertTrue(store.conflictingDestinationIDs.isEmpty)
        let original = store.document
        XCTAssertTrue(store.setEnabled(true, for: second.id)?.contains("OMT source name") == true)
        XCTAssertEqual(store.document, original, "Rejected enabling leaves saved assignments and names intact.")
        var changed = try XCTUnwrap(second.omt)
        changed.sourceName = "Other OMT"
        XCTAssertNil(store.setNetworkSettings(changed, for: second.id))
        XCTAssertNil(store.setEnabled(true, for: second.id))
        XCTAssertEqual(store.document.destinations[2].networkTechnology, .omt)
        XCTAssertEqual(store.document.destinations[2].omt, changed)
        XCTAssertNil(store.document.destinations[2].ndi)
        changed.sourceName = "EUCALY"
        let enabled = store.document
        XCTAssertNotNil(store.setNetworkSettings(changed, for: second.id))
        XCTAssertEqual(store.document, enabled)
    }

    func testOMTBackgroundClearRetainsItsKeyColourAndSingleSavedMusicRoute() throws {
        let store = OutputProfileStore()
        var omt = OutputDestinationConfiguration(name: "OMT", profileID: OutputProfile.audienceID, monitor: nil)
        omt.omt = .init(sourceName: "OMT key")
        store.edit { $0.destinations.append(omt); $0.backgroundAudioDestinationID = omt.id }
        let colour = OutputColour(red: 0.1, green: 0.6, blue: 0.2)
        store.editDestinationProfile(omt.id) { $0.background.bookmark = "selected visual"; $0.background.colour = colour }
        store.clearDestinationBackground(omt.id)
        let profile = try XCTUnwrap(store.document.destinations.first { $0.id == omt.id }.flatMap { store.profile($0.profileID) })
        XCTAssertNil(profile.background.bookmark)
        XCTAssertEqual(profile.background.colour, colour)
        XCTAssertEqual(store.document.backgroundAudioDestinationID, omt.id)
        store.clearBackgrounds()
        XCTAssertEqual(store.profile(profile.id)?.background.colour, colour)
        XCTAssertEqual(store.document.backgroundAudioDestinationID, omt.id)
        store.edit { $0.destinations.removeAll { $0.id == omt.id } }
        XCTAssertNil(store.document.backgroundAudioDestinationID)
    }

    func testMigrationIsIdempotentAndKeepsIndependentPreferences() throws {
        let name = "Profiles.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(1.5, forKey: "presentationFontScale")
        defaults.set(0.8, forKey: "presentationPaddingScale")
        defaults.set("columns", forKey: "presentationLyricsLayout")
        defaults.set("bookmark", forKey: "backgroundVisualBookmark")
        defaults.set(0.7, forKey: "thumbnailFontScale")
        let target = ProjectionMonitorTarget(identity: UUID().uuidString, name: "Saved monitor")
        let store = OutputProfileStore(defaults: defaults, monitor: target)
        store.flush()
        XCTAssertEqual(store.document.destinations.count, 1)
        XCTAssertEqual(store.document.destinations.first?.monitor, target)
        XCTAssertEqual(store.document.version, 7)
        XCTAssertEqual(store.audience.typography.size, 126)
        XCTAssertEqual(store.audience.typography(for: .meaning).size, 63)
        XCTAssertEqual(store.audience.background.bookmark, "bookmark")
        XCTAssertEqual(store.audience.layout, "columns")
        let saved = store.document
        defaults.set(2, forKey: "presentationFontScale")
        XCTAssertEqual(OutputProfileStore(defaults: defaults).document, saved)
        var confidence = try XCTUnwrap(store.document.profiles.first { $0.kind == .confidence })
        confidence.typography.fontName = "Unavailable font"
        confidence.background.dimming = 0.9
        store.update(confidence)
        XCTAssertEqual(store.audience.typography.size, 126)
        XCTAssertEqual(store.audience.background.dimming, 0.35)
        XCTAssertEqual(defaults.double(forKey: "thumbnailFontScale"), 0.7)
    }
    func testShutdownBarrierPersistsLatestSnapshotAfterRapidEdits() async throws {
        let name = "ProfileShutdown.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OutputProfileStore(defaults: defaults)
        for revision in 1...100 {
            store.edit { document in
                document.destinations[0].name = "Audience \(revision)"
                document.profiles[0].typography.size = Double(40 + revision)
            }
        }
        let expected = store.document
        await store.waitForPersistence()
        let data = try XCTUnwrap(defaults.data(forKey: OutputProfileStore.key))
        XCTAssertEqual(try JSONDecoder().decode(OutputProfileDocument.self, from: data), expected)
        XCTAssertEqual(OutputProfileStore(defaults: defaults).document, expected)
        XCTAssertEqual(defaults.integer(forKey: "outputProfileDefaultsRevision"), 2)
    }

    func testRetiredPresetsRestoreAssignmentsAndCustomComponentsWithoutRecovery() throws {
        let name = "RetiredProfiles.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var legacy = OutputProfileMigration.migrate(defaults: nil, monitor: nil)
        let meaningID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000003"))
        let translationID = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-000000000004"))
        let customID = UUID()
        var custom = OutputProfile(id: customID, name: "Stage languages", kind: .audience, roles: [.meaning, .transliteration])
        custom.typography.fontName = "Saved custom typeface"
        custom.typography.size = 62
        legacy.profiles += [
            .init(id: meaningID, name: "Meaning", kind: .audience, roles: [.meaning]),
            .init(id: translationID, name: "Translation", kind: .audience, roles: [.translation]),
            custom
        ]
        let target = ProjectionMonitorTarget(identity: UUID().uuidString, name: "Stage TV")
        legacy.destinations += [
            .init(name: "Meaning", profileID: meaningID, monitor: target, enabled: false),
            .init(name: "Named translated output", profileID: translationID, monitor: target, enabled: false),
            .init(name: "Custom output", profileID: customID, monitor: nil)
        ]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        var rows = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        for index in rows.indices {
            if rows[index]["id"] as? String == meaningID.uuidString || rows[index]["id"] as? String == customID.uuidString {
                rows[index]["kind"] = "meaning"
            } else if rows[index]["id"] as? String == translationID.uuidString {
                rows[index]["kind"] = "translation"
            }
            rows[index]["includesOverlay"] = true // Removed settings must still decode safely.
        }
        object["version"] = 4
        object["profiles"] = rows
        defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: OutputProfileStore.key)
        let store = OutputProfileStore(defaults: defaults); store.flush()
        XCTAssertNil(store.recoveryNotice)
        XCTAssertNil(store.profile(meaningID)); XCTAssertNil(store.profile(translationID))
        XCTAssertEqual(store.document.destinations[1].profileID, OutputProfile.audienceID)
        XCTAssertEqual(store.document.destinations[2].profileID, OutputProfile.audienceID)
        XCTAssertEqual(store.document.destinations[1].monitor, target)
        XCTAssertEqual(store.document.destinations[2].monitor, target)
        XCTAssertFalse(store.document.destinations[1].enabled)
        XCTAssertEqual(store.document.destinations[2].name, "Named translated output")
        XCTAssertEqual(store.profile(customID), custom)
        XCTAssertEqual(store.profile(OutputProfile.lowerThirdID)?.kind, .lowerThird)
        XCTAssertEqual(store.document, OutputProfileStore(defaults: defaults).document, "Migration is idempotent")
        XCTAssertEqual(OutputProfile.builtIns.map(\.kind), [.audience, .confidence, .lowerThird])
    }

    func testLowerThirdGreenDefaultUpgradesOnceAndPreservesLaterExplicitBlack() throws {
        let name = "LowerThirdDefaults.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var legacy = OutputProfileMigration.migrate(defaults: nil, monitor: nil)
        let index = try XCTUnwrap(legacy.profiles.firstIndex { $0.kind == .lowerThird })
        XCTAssertEqual(legacy.profiles[index].background.colour, .chromaGreen)
        XCTAssertEqual(legacy.profiles[index].background.dimming, 0)
        XCTAssertEqual(legacy.profiles[0].background.colour, .black)
        legacy.profiles[index].background = OutputBackground()
        defaults.set(try JSONEncoder().encode(legacy), forKey: OutputProfileStore.key)
        let upgraded = OutputProfileStore(defaults: defaults); upgraded.flush()
        var lowerThird = try XCTUnwrap(upgraded.profile(legacy.profiles[index].id))
        XCTAssertEqual(lowerThird.background.colour, .chromaGreen)
        XCTAssertEqual(lowerThird.background.dimming, 0)
        lowerThird.background = OutputBackground() // A later explicit choice, matching the old factory black.
        upgraded.update(lowerThird); upgraded.flush()
        XCTAssertEqual(OutputProfileStore(defaults: defaults).profile(lowerThird.id)?.background, lowerThird.background)
    }
    func testLowerThirdDefaultUpgradePreservesCustomizedSavedBackground() throws {
        let name = "LowerThirdCustom.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var legacy = OutputProfileMigration.migrate(defaults: nil, monitor: nil)
        let index = try XCTUnwrap(legacy.profiles.firstIndex { $0.kind == .lowerThird })
        legacy.profiles[index].background = .init(colour: .init(red: 0.2, green: 0.3, blue: 0.4), bookmark: "chosen visual", dimming: 0.7)
        defaults.set(try JSONEncoder().encode(legacy), forKey: OutputProfileStore.key)
        let restored = OutputProfileStore(defaults: defaults); restored.flush()
        XCTAssertEqual(restored.document, legacy)
        XCTAssertNil(restored.recoveryNotice)
    }

    func testClearBackgroundPreservesLowerThirdKeyColoursAndPersistsVisualRemoval() throws {
        let name = "LowerThirdClear.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OutputProfileStore(defaults: defaults)
        var lowerThird = try XCTUnwrap(store.profile(OutputProfile.lowerThirdID))
        lowerThird.background.bookmark = "selected visual"
        store.update(lowerThird)
        lowerThird.clearBackground()
        store.update(lowerThird)
        XCTAssertNil(store.profile(lowerThird.id)?.background.bookmark)
        XCTAssertEqual(store.profile(lowerThird.id)?.background.colour, .chromaGreen)

        lowerThird.id = UUID(); lowerThird.name = "Blue key"
        lowerThird.background.colour = .init(red: 0, green: 0, blue: 1)
        store.edit { doc in
            doc.profiles.append(lowerThird)
            doc.destinations.append(.init(name: lowerThird.name, profileID: lowerThird.id, monitor: nil))
            doc.destinations.append(.init(name: "Green key", profileID: OutputProfile.lowerThirdID, monitor: nil))
            let confidence = doc.profiles.first { $0.kind == .confidence }!
            doc.destinations.append(.init(name: "Disabled Confidence", profileID: confidence.id, monitor: nil, enabled: false))
            for index in doc.profiles.indices {
                doc.profiles[index].background.bookmark = "selected visual"
                if doc.profiles[index].kind != .lowerThird { doc.profiles[index].background.colour = .white }
            }
        }
        let disabledBackground = store.profile(OutputProfile.confidenceID)?.background
        store.clearBackgrounds()
        XCTAssertEqual(store.profile(OutputProfile.lowerThirdID)?.background.colour, .chromaGreen)
        XCTAssertEqual(store.profile(lowerThird.id)?.background.colour, lowerThird.background.colour)
        XCTAssertNil(store.profile(OutputProfile.lowerThirdID)?.background.bookmark)
        XCTAssertNil(store.profile(lowerThird.id)?.background.bookmark)
        XCTAssertEqual(store.audience.background.colour, .black)
        XCTAssertNil(store.audience.background.bookmark)
        XCTAssertEqual(store.profile(OutputProfile.confidenceID)?.background, disabledBackground)
        store.flush()
        XCTAssertEqual(OutputProfileStore(defaults: defaults).document, store.document)
    }

    func testWorkspaceBackgroundSelectionPreservesProfileAppearanceAndComponentOverrides() {
        let name = "ProfileRelative.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = OutputProfileStore(defaults: defaults)
        let displays = ProjectionDisplayManager(displays: { [] })
        let outputs = OutputCoordinator(profiles: store, displays: displays)
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        var audience = store.audience
        audience.typography.size = 500
        audience.layout = "columns"
        audience.typography.fontName = "Helvetica"
        store.update(audience)
        XCTAssertEqual(store.audience.typography(for: .meaning).size, 250)
        audience.componentTypography[.meaning]?.size = 72
        store.update(audience)
        defaults.set(1.5, forKey: "presentationFontScale")
        defaults.set("stacked", forKey: "presentationLyricsLayout")
        defaults.set("sidebar visual", forKey: "backgroundVisualBookmark")
        outputs.setBackgroundVisualBookmark("sidebar visual", for: session)
        XCTAssertEqual(store.audience.typography.size, 500)
        XCTAssertEqual(store.audience.typography.fontName, "Helvetica")
        XCTAssertEqual(store.audience.layout, "columns")
        XCTAssertEqual(store.audience.typography(for: .meaning).size, 72)
        XCTAssertEqual(store.audience.background.bookmark, "sidebar visual")
        XCTAssertNil(store.profile(OutputProfile.audienceID)?.background.bookmark,
                     "A workspace selection customizes its output without editing the reusable profile")
        store.flush()
    }
    func testCorruptOrFutureDataIsRetainedUntilExplicitRecovery() throws {
        let name = "Profiles.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        for data in [Data("broken".utf8), Data("{\"version\":99}".utf8)] {
            defaults.set(data, forKey: OutputProfileStore.key)
            let store = OutputProfileStore(defaults: defaults)
            XCTAssertNotNil(store.recoveryNotice)
            store.clearBackgrounds(); store.flush()
            XCTAssertEqual(defaults.data(forKey: OutputProfileStore.key), data)
            store.recover(); store.flush()
            XCTAssertEqual(defaults.data(forKey: "outputProfilesRecoveryBackup"), data)
        }
    }
    func testDistinctComponentsAndMissingMeaningNeverSubstitute() throws {
        let slide = try XCTUnwrap(LyricsParser.parseDocument("Verse\nMain\nMeaning\nMeaning text\nTranslation\nTranslated\nTransliteration\nSounds").slides.first)
        let content = OutputContentAdapter.text(for: slide)
        XCTAssertEqual(content.components.map(\.role), [.primary, .meaning, .translation, .transliteration])
        let profile = OutputProfile(id: UUID(), name: "Custom", kind: .audience, roles: [.meaning])
        XCTAssertEqual(profile.components(in: content).map(\.text), ["Meaning text"])
        XCTAssertTrue(profile.components(in: .init(components: [.init(role: .primary, text: "Main")])).isEmpty,
            "Missing meaning cannot substitute the primary lyrics")
        let base = OutputTypography(fontName: "Requested font", size: 70)
        XCTAssertEqual(OutputTypographyOverride(italic: true).resolve(inheriting: base).fontName, base.fontName)
        XCTAssertEqual(OutputTypographyOverride(italic: true).resolve(inheriting: base).size, 70)
    }
}

@MainActor
final class OutputProfileRecoveryTests: XCTestCase {
    func testUnsupportedVersionRecoversEveryMonitorAssignmentWithoutEnablingOutputs() throws {
        let name = "ProfilesRecovery.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var doc = OutputProfileMigration.migrate(defaults: nil, monitor: .init(identity: UUID().uuidString, name: "Audience"))
        doc.destinations.append(.init(name: "Confidence", profileID: doc.profiles[1].id, monitor: .init(identity: UUID().uuidString, name: "Confidence")))
        doc.version = 99
        let original = try JSONEncoder().encode(doc)
        defaults.set(original, forKey: OutputProfileStore.key)
        let store = OutputProfileStore(defaults: defaults)
        XCTAssertNotNil(store.recoveryNotice)
        XCTAssertEqual(store.document.destinations.map(\.monitor), doc.destinations.map(\.monitor))
        XCTAssertEqual(store.document.destinations.map(\.id), doc.destinations.map(\.id))
        XCTAssertTrue(store.document.destinations.allSatisfy { !$0.enabled })
        XCTAssertEqual(store.document.version, 7)
        store.flush(); XCTAssertEqual(defaults.data(forKey: OutputProfileStore.key), original)
    }
}
