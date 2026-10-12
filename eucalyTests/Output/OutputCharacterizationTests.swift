import XCTest
@testable import eucaly

@MainActor
final class OutputCharacterizationTests: XCTestCase {
    func testPassiveReplacementAndPreviewNeverRequestPresentation() async throws {
        let session = PresentationSession()
        let flow = PresentationFlowController()
        var events: [PresentationOutputEvent] = []
        session.onOutputEvent = { events.append($0) }
        let current = LyricsParser.parseDocument("Verse\nCurrent").slides
        session.setSlides(current)
        session.isPresenting = true
        await settle()
        events.removeAll()
        flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPrivate draft").slides)
        flow.selectPreviewSlide(try XCTUnwrap(flow.previewSlides.first?.id))
        await settle()
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(session.currentSlide?.id, current.first?.id)
        session.setSlides(LyricsParser.parseDocument("Verse\nPassive refresh").slides)
        await settle()
        XCTAssertFalse(events.isEmpty)
        for event in events {
            guard case .changed(let snapshot) = event else { return XCTFail("Passive replacement requested output") }
            XCTAssertEqual(snapshot.slide?.lines.first?.text, "Passive refresh")
        }
        session.stopPresentation()
    }

    func testSameSlideActivationIsExplicitAndClearRetainsPreview() async {
        let session = PresentationSession(), flow = PresentationFlowController()
        var projects = 0
        session.onOutputEvent = { if case .project = $0 { projects += 1 } }
        let slides = LyricsParser.parseDocument("Verse\nOne").slides
        session.setSlides(slides)
        flow.setPreviewSlides(slides)
        session.isPresenting = true
        await settle()
        session.selectCurrentSlide(slides[0].id)
        await settle()
        session.selectCurrentSlide(slides[0].id)
        await settle()
        XCTAssertEqual(projects, 2)
        session.clearSlides()
        await settle()
        XCTAssertTrue(session.isEmpty)
        XCTAssertEqual(flow.previewSlideCount, 1)
        session.stopPresentation()
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(25)) }
}
