import Combine
import CoreGraphics
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

    func testQueuedNavigationDoesNotMoveAReplacementPDF() async throws {
        let session = PresentationSession()
        session.setSlides(makeSlides())
        session.moveSelection(direction: .nextItem)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresentationSelectionScheduling-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("replacement.pdf")
        try writePDF(to: url, pageCount: 8)
        let source = PDFSlideSource(url: url, pageCount: 8)
        XCTAssertTrue(session.setPDFSlideSource(source, preferredSelectionIndex: 3))
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

    private func writePDF(to url: URL, pageCount: Int) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent("staging-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: staging) }
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 150)
        let context = try XCTUnwrap(CGContext(staging as CFURL, mediaBox: &mediaBox, nil))
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: CGFloat(index + 1) / CGFloat(pageCount + 1), alpha: 1))
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
        try Data(contentsOf: staging).write(to: url, options: .atomic)
    }
}
