import XCTest
@testable import eucaly

@MainActor
final class OutputCharacterizationTests: XCTestCase {
    func testPassiveReplacementAndPreviewNeverRequestPresentation() async throws {
        let sender = RecordingAltViewSender(), service = AltViewService(pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        let hub = LocalOutputHarness(service: service); defer { hub.stop() }
        service.receive(sender.connectedStatus)
        let session = hub.session, flow = hub.flow
        let current = LyricsParser.parseDocument("Verse\nCurrent").slides
        session.setSlides(current)
        session.showSlides()
        await settle()
        let submissions = sender.submissions.count, takes = sender.takes
        flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPrivate draft").slides)
        flow.selectPreviewSlide(try XCTUnwrap(flow.previewSlides.first?.id))
        await settle()
        XCTAssertEqual(sender.submissions.count, submissions)
        XCTAssertEqual(session.currentSlide?.id, current.first?.id)
        session.setSlides(LyricsParser.parseDocument("Verse\nPassive refresh").slides)
        await settle()
        XCTAssertEqual(sender.submissions.last?.content.body, "Passive refresh")
        XCTAssertEqual(sender.takes, takes)
        session.stopPresentation()
    }

    func testSameSlideActivationIsExplicitAndClearRetainsPreview() async {
        let sender = RecordingAltViewSender(), service = AltViewService(pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        let hub = LocalOutputHarness(service: service); defer { hub.stop() }
        service.receive(sender.connectedStatus)
        let session = hub.session, flow = hub.flow
        let slides = LyricsParser.parseDocument("Verse\nOne").slides
        session.setSlides(slides)
        flow.setPreviewSlides(slides)
        session.showSlides()
        await settle()
        session.selectCurrentSlide(slides[0].id)
        await settle()
        session.selectCurrentSlide(slides[0].id)
        await settle()
        XCTAssertEqual(sender.takes, 3, "Show and two same-slide activations are distinct actions")
        session.clearSlides()
        await settle()
        XCTAssertTrue(session.isEmpty)
        XCTAssertEqual(flow.previewSlideCount, 1)
        session.stopPresentation()
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(25)) }
}
