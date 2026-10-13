import XCTest
@testable import eucaly

@MainActor
final class ScriptureComponentTests: XCTestCase {
    private let bilingual = AltViewDisplayContent(title: "John 3:16", body: "Primary verse", footer: "NIV", template: .scripture,
        confidence: .init(title: "John 3:16", body: "Primary verse", footer: "NIV", secondary: .init(body: "Second verse", footer: "NLT")))

    func testLyricsChoicesNeverSuppressReceivedBibleTranslationsInAnyNativeProfile() {
        let scripture = OutputAltViewAdapter.text(bilingual)
        for var profile in OutputProfile.builtIns where profile.isNative {
            profile.roles = [.meaning] // A song companion choice is private to lyrics.
            let selected = profile.components(in: scripture)
            XCTAssertEqual(selected.map(\.text), ["John 3:16", "Primary verse", "NIV", "Second verse", "NLT"])
            XCTAssertEqual(selected.filter { $0.role == .secondary }.count, 1)
            XCTAssertFalse(selected.contains { $0.role == .translation })
            let lyrics = OutputContentAdapter.text(for: LyricsParser.parseDocument("Verse\nLyrics\nMeaning\nMeaning text").slides.first)
            XCTAssertEqual(profile.components(in: lyrics).map(\.text), ["Meaning text"])
        }
    }
    func testSingleLanguageAndReturnToLyricsAutomaticallyCollapseMissingComponents() {
        let profile = OutputProfile.builtIns[0]
        var single = bilingual; single.confidence?.secondary = nil
        XCTAssertEqual(profile.components(in: OutputAltViewAdapter.text(single)).map(\.text), ["John 3:16", "Primary verse", "NIV"])
        let lyrics = OutputContentAdapter.text(for: LyricsParser.parseDocument("Verse\nLyrics\nTranslation\nSong translation").slides.first)
        XCTAssertEqual(profile.components(in: lyrics).map(\.text), ["Lyrics", "Song translation"])
    }
    func testVerseOverridesPersistIndependentlyAndVersionsHideForBothLanguages() throws {
        var profile = OutputProfile.builtIns[0]
        profile.roles = [.primary, .translation]
        profile.scriptureRoles = [.primary, .secondary]
        let restored = try JSONDecoder().decode(OutputProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(restored, profile)
        XCTAssertEqual(restored.components(in: OutputAltViewAdapter.text(bilingual)).map(\.text), ["Primary verse", "Second verse"])
    }
    func testOldProfileAcquiresVerseDefaultsWithoutLosingItsSongChoices() throws {
        var profile = OutputProfile.builtIns[0]; profile.roles = [.meaning]
        var saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        saved.removeValue(forKey: "scriptureRoles")
        let migrated = try JSONDecoder().decode(OutputProfile.self, from: JSONSerialization.data(withJSONObject: saved))
        XCTAssertEqual(migrated.roles, [.meaning])
        XCTAssertEqual(migrated.scriptureRoles, OutputComponentRole.scriptureRoles)
        XCTAssertEqual(migrated.typography, profile.typography); XCTAssertEqual(migrated.background, profile.background)
    }
    func testExplicitSourceKindIsIndependentOfReceiverTemplate() {
        for template in [AltViewContentTemplate?.none, .scripture, .lyrics, .init(rawValue: "custom.future")] {
            var content = bilingual; content.template = template; content.sourceKind = .scripture
            let text = OutputAltViewAdapter.text(content)
            XCTAssertEqual(text.kind, .scripture)
            var profile = OutputProfile.builtIns[0]; profile.roles = [.meaning]
            XCTAssertEqual(profile.components(in: text).count, 5)
        }
    }
    func testSwitchingLiveSourcesUsesCorrectSelectionsWithoutEditingTheProfile() throws {
        let sender = RecordingAltViewSender(), service = AltViewService(pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        let hub = HubOutputHarness(service: service); defer { hub.stop() }
        service.receive(sender.connectedStatus)
        var audience = hub.outputs.profiles.audience; audience.roles = [.meaning]
        hub.outputs.profiles.update(audience)
        hub.load("Verse\nLyrics\nMeaning\nMeaning text"); hub.session.showSlides()
        XCTAssertEqual(audience.components(in: hub.outputs.text).map(\.text), ["Meaning text"])
        _ = try hub.outputs.presentReceived(connection: UUID(), sourceID: UUID(), name: "ViewTheWord", revision: 1,
            content: bilingual, ingressOrder: hub.outputs.actionClock.next())
        XCTAssertEqual(audience.components(in: hub.outputs.text).map(\.text), ["John 3:16", "Primary verse", "NIV", "Second verse", "NLT"])
        XCTAssertEqual(sender.submissions.last?.content.confidence?.secondary?.body, "Second verse")
        hub.session.showSlides()
        XCTAssertEqual(audience.components(in: hub.outputs.text).map(\.text), ["Meaning text"])
        XCTAssertEqual(hub.outputs.profiles.audience, audience)
    }
}
