import XCTest
import AppKit
@testable import eucaly

@MainActor
final class LocalOutputTests: XCTestCase {
    func testAnotherWorkspaceCannotPublishThroughPassiveRefreshAndExplicitShowTakesOutput() async throws {
        let sender = RecordingAltViewSender(), service = AltViewService(pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        let output = LocalOutputHarness(service: service); defer { output.stop() }
        service.receive(sender.connectedStatus)
        output.load("Verse\nLive lyrics"); output.session.showSlides()
        let other = PresentationSession(projectionDisplays: output.outputs.displays, outputCoordinator: output.outputs)
        other.setSlides(LyricsParser.parseDocument("Verse\nPrepared workspace").slides)
        output.outputs.passiveLocal(other)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sender.submissions.last?.content.body, "Live lyrics")
        other.showSlides()
        XCTAssertEqual(sender.submissions.last?.content.body, "Prepared workspace")
        XCTAssertEqual(output.outputs.ownership.source, other.outputSourceID)
        XCTAssertFalse(output.session.isPresenting); XCTAssertTrue(other.isPresenting)
    }
    func testRemoteOnlyLyricsDoNotCreateNativeWindowAndMediaCannotReplaceThem() async throws {
        let sender = RecordingAltViewSender(), service = AltViewService(pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        let output = LocalOutputHarness(service: service); defer { output.stop() }
        output.outputs.profiles.edit { $0.destinations[0].enabled = false }
        service.receive(sender.connectedStatus)
        output.load("Verse\nRemote lyrics"); output.session.showSlides()
        XCTAssertEqual(sender.submissions.last?.content.body, "Remote lyrics")
        XCTAssertFalse(output.outputs.isOpen(output.nativeRow)); XCTAssertTrue(output.session.isPresenting)
        let media = Slide(index: 1, lines: [], label: "Image", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: URL(fileURLWithPath: "/tmp/local-output-image.png"))
        output.session.setSlides([media]); output.session.showSlides()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sender.submissions.last?.content.body, "Remote lyrics")
        XCTAssertEqual(output.outputs.text.components.first?.text, "Remote lyrics")
        XCTAssertNotNil(output.session.projectionDisplayIssue)
    }
    func testDisablingLastDestinationsRetainsCurrentAndCancelsQueuedNavigation() async throws {
        let sender = RecordingAltViewSender(), service = AltViewService(pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        let output = LocalOutputHarness(service: service); defer { output.stop() }
        service.receive(sender.connectedStatus)
        output.load("Verse\nFirst\n\nChorus\nSecond"); output.session.showSlides()
        let current = output.session.currentSlideID
        output.session.moveSelection(1)
        output.outputs.profiles.edit { document in for i in document.destinations.indices { document.destinations[i].enabled = false } }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(output.outputs.snapshot.source); XCTAssertNil(output.outputs.localSession)
        XCTAssertFalse(output.outputs.isPresenting); XCTAssertFalse(output.session.isPresenting)
        XCTAssertEqual(output.session.currentSlideID, current)
        XCTAssertEqual(output.outputs.text.components.first?.text, "First")
    }
    func testSenderIdentityMigratesWithoutEnablingAnyReceiverOrOpeningOutput() {
        let suite = "LocalIdentity.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(); defaults.set(id.uuidString, forKey: "hubReceiverID")
        let store = OutputProfileStore(), outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }))
        let router = AltViewOutputRouter(store: store, defaults: defaults)
        router.start(coordinator: outputs, discover: false)
        defer { router.shutdown(); outputs.stop() }
        XCTAssertEqual(defaults.string(forKey: "altViewSenderID"), id.uuidString)
        XCTAssertNil(defaults.object(forKey: "hubReceiverID")); XCTAssertFalse(outputs.isRunning)
        XCTAssertNil(outputs.ownership.source)
    }
}
