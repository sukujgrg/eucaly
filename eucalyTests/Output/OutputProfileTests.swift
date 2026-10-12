import XCTest
@testable import eucaly

@MainActor
final class OutputProfileTests: XCTestCase {
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
        XCTAssertFalse(store.document.receiverEnabled)
        XCTAssertEqual(store.audience.typography.size, 126)
        XCTAssertEqual(store.audience.typography(for: .meaning).size, 63)
        XCTAssertEqual(store.audience.background.bookmark, "bookmark")
        XCTAssertEqual(store.audience.layout, "columns")
        let saved = store.document
        defaults.set(2, forKey: "presentationFontScale")
        XCTAssertEqual(OutputProfileStore(defaults: defaults).document, saved)
        var meaning = try XCTUnwrap(store.document.profiles.first { $0.kind == .meaning })
        meaning.typography.fontName = "Unavailable font"
        meaning.background.dimming = 0.9
        store.update(meaning)
        XCTAssertEqual(store.audience.typography.size, 126)
        XCTAssertEqual(store.audience.background.dimming, 0.35)
        XCTAssertEqual(defaults.double(forKey: "thumbnailFontScale"), 0.7)
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
        let profile = try XCTUnwrap(OutputProfile.builtIns.first { $0.kind == .meaning })
        XCTAssertEqual(profile.components(in: content).map(\.text), ["Meaning text"])
        XCTAssertTrue(profile.components(in: .init(kind: .scripture, components: [.init(role: .primary, text: "Verse")])).isEmpty)
        let base = OutputTypography(fontName: "Requested font", size: 70)
        XCTAssertEqual(OutputTypographyOverride(italic: true).resolve(inheriting: base).fontName, base.fontName)
        XCTAssertEqual(OutputTypographyOverride(italic: true).resolve(inheriting: base).size, 70)
    }
}
