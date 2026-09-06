import Combine
import XCTest
@testable import eucaly

@MainActor
final class PresentationSelectionSchedulingTests: XCTestCase {
    func testDirectionalNavigationPublishesAfterTheInputCallbackReturns() async {
        let session = PresentationSession()
        let slides = makeSlides()
        session.setSlides(slides)
        session.setCurrentThumbnailColumnCount(2)
        var isHandlingInput = true
        var publishedDuringInput = false
        let observation = session.$currentSlideID.dropFirst().sink { _ in
            publishedDuringInput = publishedDuringInput || isHandlingInput
        }

        session.moveSelection(direction: .nextRow)
        XCTAssertFalse(publishedDuringInput)
        XCTAssertEqual(session.currentSlideID, slides[0].id)
        isHandlingInput = false
        await drainMainQueue()

        XCTAssertEqual(session.currentSlideID, slides[2].id)
        withExtendedLifetime(observation) {}
    }

    func testRepeatedNavigationUsesTheLatestSelectionInOrder() async {
        let session = PresentationSession()
        let slides = makeSlides()
        session.setSlides(slides)
        session.moveSelection(direction: .nextItem)
        session.moveSelection(direction: .nextItem)
        session.moveSelection(direction: .previousItem)
        await drainMainQueue()
        XCTAssertEqual(session.currentSlideID, slides[1].id)
    }

    func testQueuedNavigationDoesNotMoveAReplacementCurrentDocument() async {
        let session = PresentationSession()
        session.setSlides(makeSlides())
        session.moveSelection(1)
        session.moveSelection(direction: .nextItem)
        let replacement = makeSlides()
        session.setSlides(replacement)
        await drainMainQueue()
        XCTAssertEqual(session.currentSlideID, replacement[0].id)
    }

    func testBoundaryNavigationDoesNotRepublishUnchangedSelection() async {
        let session = PresentationSession()
        let slides = makeSlides()
        session.setSlides(slides)
        var publicationCount = 0
        let observation = session.$currentSlideID.dropFirst().sink { _ in publicationCount += 1 }
        session.moveSelection(direction: .previousItem)
        session.moveSelection(-1)
        await drainMainQueue()
        XCTAssertEqual(session.currentSlideID, slides[0].id)
        XCTAssertEqual(publicationCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testQueuedNavigationDoesNotMoveAReplacementPDF() async {
        let session = PresentationSession()
        session.setSlides(makeSlides())
        session.moveSelection(direction: .nextItem)
        let source = PDFSlideSource(
            url: URL(fileURLWithPath: "/library/replacement.pdf"),
            pageCount: 8
        )
        session.setPDFSlideSource(source, preferredSelectionIndex: 3)
        await drainMainQueue()
        XCTAssertEqual(session.currentSlideID, PDFSlideCatalog.slide(url: source.url, pageIndex: 3).id)
    }

    func testQueuedNavigationLeavesClearedCurrentEmpty() async {
        let session = PresentationSession()
        session.setSlides(makeSlides())
        session.moveSelection(direction: .nextItem)
        session.clearSlides()
        await drainMainQueue()
        XCTAssertTrue(session.isEmpty)
        XCTAssertNil(session.currentSlideID)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeSlides() -> [Slide] {
        LyricsParser.parseDocument("One\n\nTwo\n\nThree\n\nFour", fileName: "Test.txt").slides
    }
}
