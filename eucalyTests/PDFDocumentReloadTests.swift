import AppKit
import CoreGraphics
import PDFKit
import XCTest
@testable import eucaly

@MainActor
final class PDFDocumentReloadTests: XCTestCase {
    func testExplicitSameURLReloadReplacesNativeDocumentForMaterializedSlides() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("slides.pdf")
            try writePDF(to: url, pageCount: 1)
            let session = makeSession()
            session.setSlides(PDFSlideCatalog.slides(url: url, pageCount: 1))
            let view = makeView()
            try displayCurrent(in: view, session: session)
            let original = try XCTUnwrap(view.document)
            let originalSlideID = session.currentSlideID
            let originalRevision = session.pdfDocumentRevision

            try writePDF(to: url, pageCount: 2)
            session.setSlides(PDFSlideCatalog.slides(url: url, pageCount: 2))
            XCTAssertEqual(session.currentSlideID, originalSlideID, "PDF slide identity stays stable for the same path/page")
            XCTAssertNotEqual(session.pdfDocumentRevision, originalRevision)
            try displayCurrent(in: view, session: session)

            XCTAssertFalse(view.document === original, "An existing native PDFView must replace its same-URL document after explicit Load")
            XCTAssertEqual(view.document?.pageCount, 2)
            XCTAssertEqual(original.pageCount, 1)
        }
    }

    func testVirtualPDFReloadShowsNewPagesWhileNavigationReusesTheLoadedDocument() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("virtual.pdf")
            try writePDF(to: url, pageCount: 1)
            let session = makeSession()
            session.setPDFSlideSource(.init(url: url, pageCount: 1))
            let view = makeView()
            try displayCurrent(in: view, session: session)
            let original = try XCTUnwrap(view.document)

            try writePDF(to: url, pageCount: 3)
            session.setPDFSlideSource(.init(url: url, pageCount: 3), preferredSelectionIndex: 2)
            try displayCurrent(in: view, session: session)
            let reloaded = try XCTUnwrap(view.document)
            XCTAssertFalse(reloaded === original)
            XCTAssertEqual(reloaded.pageCount, 3)
            XCTAssertEqual(reloaded.index(for: try XCTUnwrap(view.currentPage)), 2)

            let revision = session.pdfDocumentRevision
            session.selectCurrentSlide(PDFSlideCatalog.stableSlideID(url: url, pageIndex: 1))
            try displayCurrent(in: view, session: session)
            XCTAssertEqual(session.pdfDocumentRevision, revision, "Ordinary page navigation is not a source reload")
            XCTAssertTrue(view.document === reloaded)
            XCTAssertEqual(reloaded.index(for: try XCTUnwrap(view.currentPage)), 1)
        }
    }

    func testAnotherWorkspaceReloadAndClearCannotReplaceTheAcceptedPDF() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("shared.pdf")
            try writePDF(to: url, pageCount: 1)
            let displays = ProjectionDisplayManager(displays: { [] })
            let outputs = OutputCoordinator(profiles: OutputProfileStore(), displays: displays)
            let a = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
            let b = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
            defer { outputs.stopAllOutputs() }
            XCTAssertNotEqual(a.outputSourceID, b.outputSourceID)
            a.setPDFSlideSource(.init(url: url, pageCount: 1))
            let aView = makeView()
            try displayCurrent(in: aView, session: a)
            let accepted = try XCTUnwrap(aView.document)
            let acceptedRevision = a.pdfDocumentRevision

            try writePDF(to: url, pageCount: 2)
            b.setPDFSlideSource(.init(url: url, pageCount: 2))
            XCTAssertEqual(a.pdfDocumentRevision, b.pdfDocumentRevision, "Different workspaces may have equal load counters")
            let movedView = makeView()
            try displayCurrent(in: movedView, session: a)
            XCTAssertTrue(movedView.document === accepted)
            try displayCurrent(in: movedView, session: b)
            XCTAssertEqual(movedView.document?.pageCount, 2)
            XCTAssertFalse(movedView.document === accepted, "A destination transferred to another workspace must use that workspace's document")

            b.clearSlides()
            let reopenedAView = makeView()
            try displayCurrent(in: aView, session: a)
            try displayCurrent(in: reopenedAView, session: a)
            XCTAssertEqual(a.pdfDocumentRevision, acceptedRevision)
            XCTAssertTrue(aView.document === accepted)
            XCTAssertTrue(reopenedAView.document === accepted, "Closing/reopening a view must retain the workspace's accepted source")
            XCTAssertEqual(accepted.pageCount, 1)

            a.setPDFSlideSource(.init(url: url, pageCount: 2))
            try displayCurrent(in: aView, session: a)
            XCTAssertFalse(aView.document === accepted)
            XCTAssertEqual(aView.document?.pageCount, 2)
        }
    }

    func testDocumentCacheEvictsTheLeastRecentlyUsedOfThreeSources() throws {
        try withTemporaryDirectory { directory in
            let urls = (0..<4).map { directory.appendingPathComponent("source-\($0).pdf") }
            for url in urls { try writePDF(to: url, pageCount: 1) }
            let cache = PDFDocumentCache()
            let first = try XCTUnwrap(cache.document(for: urls[0]))
            let second = try XCTUnwrap(cache.document(for: urls[1]))
            XCTAssertNotNil(cache.document(for: urls[2]))
            XCTAssertTrue(cache.document(for: urls[0]) === first)
            XCTAssertNotNil(cache.document(for: urls[3]))
            XCTAssertTrue(cache.document(for: urls[0]) === first)
            XCTAssertFalse(cache.document(for: urls[1]) === second, "A fourth source must evict the least-recently-used entry")
        }
    }

    private func makeSession() -> PresentationSession {
        PresentationSession(projectionDisplays: ProjectionDisplayManager(displays: { [] }))
    }

    private func makeView() -> PDFSlideNSView {
        PDFSlideNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    private func displayCurrent(in view: PDFSlideNSView, session: PresentationSession) throws {
        let slide = try XCTUnwrap(session.currentSlide)
        view.display(url: try XCTUnwrap(slide.pdfURL), pageIndex: try XCTUnwrap(slide.pdfPageIndex),
                     revision: session.pdfDocumentRevision, cache: session.pdfDocumentCache)
        view.layoutSubtreeIfNeeded()
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-pdf-reload-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func writePDF(to url: URL, pageCount: Int) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent("replacement-\(UUID()).pdf")
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
