import XCTest
@testable import eucaly

final class PresentationDocumentTests: XCTestCase {
    func testConcatenatesMaterializedSlidesAcrossSegments() {
        let image = Slide(
            index: 1, lines: [], label: "a.png",
            videoURL: nil, pdfURL: nil, pdfPageIndex: nil,
            imageURL: URL(fileURLWithPath: "/tmp/a.png"), captureWindowID: nil
        )
        let video = Slide(
            index: 2, lines: [], label: "b.mp4",
            videoURL: URL(fileURLWithPath: "/tmp/b.mp4"), pdfURL: nil, pdfPageIndex: nil,
            imageURL: nil, captureWindowID: nil
        )
        let document = PresentationDocument(segments: [.slides([image]), .slides([video])])
        XCTAssertEqual(document.slideCount, 2)
        XCTAssertEqual(document.slide(at: 0).imageURL?.lastPathComponent, "a.png")
        XCTAssertEqual(document.slide(at: 1).videoURL?.lastPathComponent, "b.mp4")
        XCTAssertTrue(document.containsMultipleSources)
        XCTAssertEqual(document.sourceURLs.map(\.lastPathComponent), ["a.png", "b.mp4"])
    }

    func testVirtualPDFBesideImageKeepsPerFileThumbnailGate() {
        let imageURL = URL(fileURLWithPath: "/tmp/cover.png")
        let pdfURL = URL(fileURLWithPath: "/tmp/large.pdf")
        let image = Slide(
            index: 1, lines: [], label: "cover.png",
            videoURL: nil, pdfURL: nil, pdfPageIndex: nil,
            imageURL: imageURL, captureWindowID: nil
        )
        let document = PresentationDocument(segments: [
            .slides([image]),
            .virtualPDF(PDFSlideSource(url: pdfURL, pageCount: 150))
        ])
        XCTAssertEqual(document.slideCount, 151)
        XCTAssertEqual(document.slide(at: 0).imageURL, imageURL)
        let page = document.slide(at: 1)
        XCTAssertEqual(page.pdfURL, pdfURL)
        XCTAssertEqual(page.pdfPageIndex, 0)
        XCTAssertTrue(page.label?.contains("large.pdf") == true)
        XCTAssertFalse(document.allowsPDFThumbnailRendering(for: page))
        XCTAssertTrue(document.allowsPDFThumbnailRendering(for: image))
        XCTAssertNil(document.soleVirtualPDFSource)
        XCTAssertTrue(document.materializedSlides.isEmpty)
        XCTAssertTrue(document.containsMultipleSources)
        // Stored multi-source flag must keep filename labels across repeated lookups.
        for index in [1, 50, 150] {
            XCTAssertTrue(
                document.slide(at: index).label?.contains("large.pdf") == true,
                "slide \(index) should include filename in multi-source deck"
            )
        }
    }

    func testIndexOfStablePDFIDAcrossMultiplePDFs() {
        let first = URL(fileURLWithPath: "/tmp/one.pdf")
        let second = URL(fileURLWithPath: "/tmp/two.pdf")
        let document = PresentationDocument(segments: [
            .slides(PDFSlideCatalog.slides(url: first, pageCount: 2, includeFilename: true)),
            .slides(PDFSlideCatalog.slides(url: second, pageCount: 3, includeFilename: true))
        ])
        XCTAssertEqual(document.slideCount, 5)
        let target = PDFSlideCatalog.slide(url: second, pageIndex: 1, includeFilename: true)
        XCTAssertEqual(document.index(of: target.id), 3)
        XCTAssertEqual(document.slide(at: 3).id, target.id)
    }

    func testMultiPDFMaterializedDeckStillRendersThumbnailsPerFile() {
        let first = URL(fileURLWithPath: "/tmp/a.pdf")
        let second = URL(fileURLWithPath: "/tmp/b.pdf")
        let slides = PDFSlideCatalog.slides(url: first, pageCount: 60)
            + PDFSlideCatalog.slides(url: second, pageCount: 60)
        XCTAssertTrue(PDFSlideCatalog.shouldRenderThumbnails(for: slides))
    }

    func testRemovingOneSourceKeepsRemainingDeck() {
        let imageURL = URL(fileURLWithPath: "/tmp/keep.png")
        let pdfURL = URL(fileURLWithPath: "/tmp/drop.pdf")
        let image = Slide(
            index: 1, lines: [], label: "keep.png",
            videoURL: nil, pdfURL: nil, pdfPageIndex: nil,
            imageURL: imageURL, captureWindowID: nil
        )
        let document = PresentationDocument(segments: [
            .slides([image]),
            .virtualPDF(PDFSlideSource(url: pdfURL, pageCount: 120))
        ])
        let remaining = document.removingSources { $0.standardizedFileURL == pdfURL.standardizedFileURL }
        XCTAssertEqual(remaining.slideCount, 1)
        XCTAssertEqual(remaining.slide(at: 0).imageURL, imageURL)
    }
}

final class PresentationDocumentComposerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PresentationDocumentComposerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testComposesImageAndLyricsInSelectionOrder() throws {
        let image = root.appendingPathComponent("cover.png")
        let lyrics = root.appendingPathComponent("song.txt")
        // Minimal valid PNG
        let png = Data([
            0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
            0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
            0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53, 0xDE, 0x00, 0x00, 0x00,
            0x0C, 0x49, 0x44, 0x41, 0x54, 0x08, 0xD7, 0x63, 0xF8, 0xCF, 0xC0, 0x00,
            0x00, 0x00, 0x03, 0x00, 0x01, 0x00, 0x05, 0xFE, 0xD4, 0xEF, 0x00, 0x00,
            0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
        ])
        try png.write(to: image)
        try "Verse\nHello\n\nChorus\nWorld\n".write(to: lyrics, atomically: true, encoding: .utf8)

        let result = PresentationDocumentComposer.compose(urls: [image, lyrics])
        XCTAssertTrue(result.skippedTitles.isEmpty)
        XCTAssertNil(result.soleLyricsURL)
        XCTAssertGreaterThanOrEqual(result.document.slideCount, 3)
        XCTAssertEqual(result.document.slide(at: 0).imageURL?.lastPathComponent, "cover.png")
        XCTAssertFalse(result.document.slide(at: 1).lines.isEmpty)
    }

    func testSkipsMissingFilesWithoutBlankingReadableOnes() throws {
        let lyrics = root.appendingPathComponent("ok.txt")
        try "Line\n".write(to: lyrics, atomically: true, encoding: .utf8)
        let missing = root.appendingPathComponent("gone.pdf")

        let result = PresentationDocumentComposer.compose(urls: [missing, lyrics])
        XCTAssertEqual(result.skippedTitles, ["gone.pdf"])
        XCTAssertEqual(result.document.slideCount, 1)
        XCTAssertEqual(result.soleLyricsURL?.lastPathComponent, "ok.txt")
    }
}

final class LibrarySelectionReconciliationTests: XCTestCase {
    func testDroppingPrimaryDoesNotInventReplacement() {
        let keep = URL(fileURLWithPath: "/tmp/keep.png")
        let gone = URL(fileURLWithPath: "/tmp/gone.png")
        let reconciled = LibrarySelectionReconciliation(
            selectedURLs: [keep, gone],
            primaryURL: gone,
            availableURLs: [keep]
        )
        XCTAssertEqual(reconciled.selectedURLs, [keep])
        XCTAssertNil(reconciled.primaryURL)
    }
}
