import AppKit
import CoreGraphics
import IOSurface
import PDFKit
import XCTest
@testable import eucaly

@MainActor
final class PDFDocumentReloadTests: XCTestCase {
    func testNDINavigationRetainsAcceptedPagesAfterReplacementAndDeletion() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("accepted.pdf")
            try writePDF(to: url, pageCount: 2)
            let (outputs, session, destination) = makeNDISession()
            let prepared = OutputPreparedMedia()
            defer { prepared.stop(); outputs.stopAllOutputs() }
            session.setPDFSlideSource(.init(url: url, pageCount: 2))
            session.showSlides()
            let source = try XCTUnwrap(outputs.snapshot(for: destination).acceptedPDF)
            let native = makeView()
            try displayCurrent(in: native, session: session)
            let nativeDocument = try XCTUnwrap(native.document)
            let firstPixel = pixel(try await preparedFrame(prepared, source: source, page: 0))
            let secondPixel = pixel(try await preparedFrame(prepared, source: source, page: 1))
            // Leave page zero cached so navigating to page one must rasterize.
            _ = try await preparedFrame(prepared, source: source, page: 0)

            try writePDF(to: url, pageCount: 1)
            session.selectCurrentSlide(PDFSlideCatalog.stableSlideID(url: url, pageIndex: 1))
            let secondSnapshot = outputs.snapshot(for: destination)
            XCTAssertTrue(secondSnapshot.acceptedPDF === source)
            let retainedSecondPixel = pixel(try await preparedFrame(prepared, source: try XCTUnwrap(secondSnapshot.acceptedPDF), page: 1))
            XCTAssertEqual(retainedSecondPixel, secondPixel)
            try displayCurrent(in: native, session: session)
            XCTAssertTrue(native.document === nativeDocument)
            XCTAssertEqual(native.document?.pageCount, 2)

            try FileManager.default.removeItem(at: url)
            session.selectCurrentSlide(PDFSlideCatalog.stableSlideID(url: url, pageIndex: 0))
            let deletedSnapshot = outputs.snapshot(for: destination)
            XCTAssertTrue(deletedSnapshot.acceptedPDF === source)
            let retainedFirstPixel = pixel(try await preparedFrame(prepared, source: try XCTUnwrap(deletedSnapshot.acceptedPDF), page: 0))
            XCTAssertEqual(retainedFirstPixel, firstPixel,
                           "Neither preparation nor its cache lookup may stat/reopen the deleted path")
            try displayCurrent(in: native, session: session)
            XCTAssertTrue(native.document === nativeDocument)
        }
    }

    func testExplicitPDFReloadInvalidatesNDICacheWithUnchangedPathAndFileMetadata() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("reload.pdf")
            try writePDF(to: url, pageCount: 2)
            try padPDF(at: url)
            let modified = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            let originalAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let (outputs, session, destination) = makeNDISession()
            let prepared = OutputPreparedMedia()
            defer { prepared.stop(); outputs.stopAllOutputs() }
            session.setPDFSlideSource(.init(url: url, pageCount: 2))
            session.showSlides()
            let original = try XCTUnwrap(outputs.snapshot(for: destination).acceptedPDF)
            let originalPixel = pixel(try await preparedFrame(prepared, source: original, page: 0))

            try writePDF(to: url, pageCount: 2, reversed: true)
            try padPDF(at: url)
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
            let replacementAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(originalAttributes[.size] as? NSNumber, replacementAttributes[.size] as? NSNumber)
            XCTAssertEqual(originalAttributes[.modificationDate] as? Date, replacementAttributes[.modificationDate] as? Date)
            session.setPDFSlideSource(.init(url: url, pageCount: 2))
            session.requestCurrentProjection()
            let reloaded = try XCTUnwrap(outputs.snapshot(for: destination).acceptedPDF)
            XCTAssertFalse(reloaded === original)
            let reloadedPixel = pixel(try await preparedFrame(prepared, source: reloaded, page: 0))
            XCTAssertNotEqual(reloadedPixel, originalPixel,
                              "Accepted source identity must invalidate a same-path/page/mtime/size cached picture")
            let retainedOriginalPixel = pixel(try await preparedFrame(prepared, source: original, page: 0))
            XCTAssertEqual(retainedOriginalPixel, originalPixel,
                           "A retained prior snapshot remains bound to its original bytes")
            let native = makeView()
            try displayCurrent(in: native, session: session)
            XCTAssertEqual(native.document?.pageCount, 2)
        }
    }

    func testPDFTransferAndOtherWorkspaceClearPreserveIndependentAcceptedSources() async throws {
        try await withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("workspaces.pdf")
            try writePDF(to: url, pageCount: 2)
            let (outputs, a, destination) = makeNDISession()
            let prepared = OutputPreparedMedia()
            defer { prepared.stop(); outputs.stopAllOutputs() }
            let bID = try XCTUnwrap(outputs.profiles.addWorkspace())
            let b = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs, workspaceID: bID)
            a.setPDFSlideSource(.init(url: url, pageCount: 2))
            a.showSlides()
            let acceptedA = try XCTUnwrap(outputs.snapshot(for: destination).acceptedPDF)
            let originalPixel = pixel(try await preparedFrame(prepared, source: acceptedA, page: 1))
            try writePDF(to: url, pageCount: 3)
            b.setPDFSlideSource(.init(url: url, pageCount: 3))
            XCTAssertEqual(a.documentRevision, b.documentRevision)
            XCTAssertTrue(outputs.moveOutput(destination, to: b))
            let acceptedB = try XCTUnwrap(outputs.snapshot(for: destination).acceptedPDF)
            XCTAssertFalse(acceptedA === acceptedB)
            let workspaceBPixel = pixel(try await preparedFrame(prepared, source: acceptedB, page: 1))
            XCTAssertNotEqual(workspaceBPixel, originalPixel)

            b.clearSlides()
            XCTAssertNil(outputs.snapshot(for: destination).acceptedPDF)
            XCTAssertTrue(a.pdfDocumentCache.acceptedSource(for: url) === acceptedA)
            XCTAssertTrue(outputs.moveOutput(destination, to: a))
            XCTAssertTrue(outputs.snapshot(for: destination).acceptedPDF === acceptedA)
            try FileManager.default.removeItem(at: url)
            let workspaceAPixel = pixel(try await preparedFrame(prepared, source: acceptedA, page: 1))
            XCTAssertEqual(workspaceAPixel, originalPixel)
        }
    }

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
            let originalRevision = session.documentRevision

            try writePDF(to: url, pageCount: 2)
            session.setSlides(PDFSlideCatalog.slides(url: url, pageCount: 2))
            XCTAssertEqual(session.currentSlideID, originalSlideID, "PDF slide identity stays stable for the same path/page")
            XCTAssertNotEqual(session.documentRevision, originalRevision)
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

            let revision = session.documentRevision
            session.selectCurrentSlide(PDFSlideCatalog.stableSlideID(url: url, pageIndex: 1))
            try displayCurrent(in: view, session: session)
            XCTAssertEqual(session.documentRevision, revision, "Ordinary page navigation is not a source reload")
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
            let acceptedRevision = a.documentRevision

            try writePDF(to: url, pageCount: 2)
            b.setPDFSlideSource(.init(url: url, pageCount: 2))
            XCTAssertEqual(a.documentRevision, b.documentRevision, "Different workspaces may have equal load counters")
            let movedView = makeView()
            try displayCurrent(in: movedView, session: a)
            XCTAssertEqual(movedView.document?.pageCount, 1)
            try displayCurrent(in: movedView, session: b)
            XCTAssertEqual(movedView.document?.pageCount, 2)
            XCTAssertFalse(movedView.document === accepted, "A destination transferred to another workspace must use that workspace's document")

            b.clearSlides()
            let reopenedAView = makeView()
            try displayCurrent(in: aView, session: a)
            try displayCurrent(in: reopenedAView, session: a)
            XCTAssertEqual(a.documentRevision, acceptedRevision)
            XCTAssertTrue(aView.document === accepted)
            XCTAssertEqual(reopenedAView.document?.pageCount, 1, "A new native view must use the workspace's accepted bytes")
            XCTAssertEqual(accepted.pageCount, 1)

            a.setPDFSlideSource(.init(url: url, pageCount: 2))
            try displayCurrent(in: aView, session: a)
            XCTAssertFalse(aView.document === accepted)
            XCTAssertEqual(aView.document?.pageCount, 2)
        }
    }

    func testAcceptedSourceCacheEvictsTheLeastRecentlyUsedOfThreeSources() throws {
        try withTemporaryDirectory { directory in
            let urls = (0..<4).map { directory.appendingPathComponent("source-\($0).pdf") }
            for url in urls { try writePDF(to: url, pageCount: 1) }
            let cache = AcceptedPDFSourceCache()
            let first = try XCTUnwrap(cache.prepareAcceptedSource(for: urls[0]))
            let second = try XCTUnwrap(cache.prepareAcceptedSource(for: urls[1]))
            XCTAssertNotNil(cache.prepareAcceptedSource(for: urls[2]))
            XCTAssertTrue(cache.prepareAcceptedSource(for: urls[0]) === first)
            XCTAssertNotNil(cache.prepareAcceptedSource(for: urls[3]))
            XCTAssertTrue(cache.prepareAcceptedSource(for: urls[0]) === first)
            XCTAssertNil(cache.acceptedSource(for: urls[1]), "Eviction removes only the cache's reference")
            XCTAssertFalse(cache.prepareAcceptedSource(for: urls[1]) === second, "A fourth source must evict the least-recently-used entry")
        }
    }

    private func makeSession() -> PresentationSession {
        PresentationSession(projectionDisplays: ProjectionDisplayManager(displays: { [] }))
    }

    private func makeNDISession() -> (OutputCoordinator, PresentationSession, UUID) {
        let store = OutputProfileStore()
        var destination = OutputDestinationConfiguration(name: "PDF NDI", profileID: OutputProfile.audienceID, monitor: nil)
        destination.ndi = .init(sourceName: "PDF regression")
        store.edit { $0.destinations[0].enabled = false; $0.destinations.append(destination) }
        let displays = ProjectionDisplayManager(displays: { [] })
        let outputs = OutputCoordinator(profiles: store, displays: displays, ndi: RecordingNDIOutput())
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        return (outputs, session, destination.id)
    }

    private func preparedFrame(_ prepared: OutputPreparedMedia, source: AcceptedPDFSource, page: Int) async throws -> NDIFrameResource {
        try await withCheckedThrowingContinuation { continuation in
            prepared.request(.init(url: source.url, page: page, identity: "\(source.id):\(page)", acceptedPDF: source), slot: 0) { _, frame, error in
                if let frame { continuation.resume(returning: frame) }
                else { continuation.resume(throwing: NSError(domain: "PDF preparation regression", code: 1,
                                                            userInfo: [NSLocalizedDescriptionKey: error ?? "No prepared PDF frame"])) }
            }
        }
    }

    private func pixel(_ frame: NDIFrameResource) -> [UInt8] {
        let surface = frame.surface
        let offset = (surface.height / 2) * surface.bytesPerRow + (surface.width / 2) * 4
        let pixels = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: pixels + offset, count: 4))
    }

    private func makeView() -> PDFSlideNSView {
        PDFSlideNSView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    }

    private func displayCurrent(in view: PDFSlideNSView, session: PresentationSession) throws {
        let slide = try XCTUnwrap(session.currentSlide)
        let url = try XCTUnwrap(slide.pdfURL)
        view.display(source: try XCTUnwrap(session.pdfDocumentCache.acceptedSource(for: url)),
                     pageIndex: try XCTUnwrap(slide.pdfPageIndex))
        view.layoutSubtreeIfNeeded()
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-pdf-reload-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func withTemporaryDirectory(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-pdf-reload-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory)
    }

    private func padPDF(at url: URL) throws {
        var data = try Data(contentsOf: url)
        guard data.count <= 8192 else { throw CocoaError(.fileWriteUnknown) }
        data.append(Data(repeating: 0x20, count: 8192 - data.count))
        try data.write(to: url, options: .atomic)
    }

    private func writePDF(to url: URL, pageCount: Int, reversed: Bool = false) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent("replacement-\(UUID()).pdf")
        defer { try? FileManager.default.removeItem(at: staging) }
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 150)
        let context = try XCTUnwrap(CGContext(staging as CFURL, mediaBox: &mediaBox, nil))
        for index in 0..<pageCount {
            context.beginPDFPage(nil)
            let level = reversed ? pageCount - index : index + 1
            context.setFillColor(CGColor(gray: CGFloat(level) / CGFloat(pageCount + 1), alpha: 1))
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
        try Data(contentsOf: staging).write(to: url, options: .atomic)
    }
}
