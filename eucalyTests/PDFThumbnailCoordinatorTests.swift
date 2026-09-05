import XCTest
import AppKit
import CoreGraphics
@testable import eucaly

final class PDFThumbnailCoordinatorTests: XCTestCase {
    func testReplacedPDFAtSamePathRendersNewContent() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-pdf-revision-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let pdfURL = directoryURL.appendingPathComponent("sermon.pdf")
        try writePDF(to: pdfURL, label: "A")
        let first = await PDFThumbnailCoordinator.shared.thumbnail(
            for: pdfURL,
            pageIndex: 0,
            size: CGSize(width: 80, height: 60)
        )
        let firstImage = try XCTUnwrap(renderedImage(from: first))

        try writePDF(to: pdfURL, label: "B")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(120)],
            ofItemAtPath: pdfURL.path
        )

        let second = await PDFThumbnailCoordinator.shared.thumbnail(
            for: pdfURL,
            pageIndex: 0,
            size: CGSize(width: 80, height: 60)
        )
        let secondImage = try XCTUnwrap(renderedImage(from: second))

        XCTAssertNotEqual(pngData(from: firstImage), pngData(from: secondImage))
        let revision = await PDFSourceRevision.currentAsync(for: pdfURL)
        XCTAssertNotNil(revision.modificationDate)
    }

    @MainActor
    func testConcurrentRequestsRenderDistinctPagesFromSharedDocument() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-pdf-concurrent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let pdfURL = directoryURL.appendingPathComponent("pages.pdf")
        let colors = [
            NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1),
            NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
            NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1),
            NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        ]
        try writePDF(to: pdfURL, pageColors: colors.map(\.cgColor))

        let outcomes = await withTaskGroup(of: (Int, PDFThumbnailRenderOutcome).self) { group in
            for pageIndex in colors.indices {
                group.addTask {
                    let outcome = await PDFThumbnailCoordinator.shared.thumbnail(
                        for: pdfURL,
                        pageIndex: pageIndex,
                        size: CGSize(width: 80, height: 60)
                    )
                    return (pageIndex, outcome)
                }
            }

            var outcomes: [Int: PDFThumbnailRenderOutcome] = [:]
            for await (pageIndex, outcome) in group {
                outcomes[pageIndex] = outcome
            }
            return outcomes
        }

        for pageIndex in colors.indices {
            let outcome = try XCTUnwrap(outcomes[pageIndex])
            guard case .rendered(_, let data, _) = outcome else {
                return XCTFail("Expected a rendered thumbnail for page \(pageIndex), got \(outcome)")
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            let pixel = try XCTUnwrap(
                bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?
                    .usingColorSpace(.sRGB)
            )
            let components = [pixel.redComponent, pixel.greenComponent, pixel.blueComponent]
            // Verify page identity without depending on exact ColorSync conversions.
            if pageIndex < 3 {
                for otherChannel in components.indices where otherChannel != pageIndex {
                    XCTAssertGreaterThan(components[pageIndex] - components[otherChannel], 0.5)
                }
            } else {
                XCTAssertLessThan(try XCTUnwrap(components.max()), 0.25)
            }
        }
    }

    func testFinalizeReturnsBusyWhenRevisionChangesAfterRender() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        let result = PDFThumbnailRenderResult(image: image, pngData: Data([0x01]))
        let captured = Self.revision(timeIntervalSince1970: 1, size: 10)
        let current = Self.revision(timeIntervalSince1970: 2, size: 10)

        let outcome = PDFThumbnailRenderGate.finalize(
            result,
            wasCancelled: false,
            capturedRevision: captured,
            currentRevision: current
        )

        guard case .busy = outcome else {
            return XCTFail("expected busy after revision change, got \(outcome)")
        }
    }

    func testFinalizeReturnsRenderedWhenRevisionIsUnchanged() throws {
        let image = NSImage(size: NSSize(width: 2, height: 2))
        let png = Data([0x01, 0x02])
        let result = PDFThumbnailRenderResult(image: image, pngData: png)
        let revision = Self.revision(timeIntervalSince1970: 1, size: 10)

        let outcome = PDFThumbnailRenderGate.finalize(
            result,
            wasCancelled: false,
            capturedRevision: revision,
            currentRevision: revision
        )

        guard case .rendered(_, let pngData, let renderedRevision) = outcome else {
            return XCTFail("expected rendered for unchanged revision, got \(outcome)")
        }
        XCTAssertEqual(pngData, png)
        XCTAssertEqual(renderedRevision, revision)
    }

    func testFinalizeReturnsBusyWhenRenderFailsAfterRevisionChange() {
        let captured = Self.revision(timeIntervalSince1970: 1, size: 10)
        let current = Self.revision(timeIntervalSince1970: 2, size: 10)

        let outcome = PDFThumbnailRenderGate.finalize(
            nil,
            wasCancelled: false,
            capturedRevision: captured,
            currentRevision: current
        )

        guard case .busy = outcome else {
            return XCTFail("expected busy after revision change, got \(outcome)")
        }
    }

    func testFinalizeReturnsFailedWhenRenderFailsWithUnchangedRevision() {
        let revision = Self.revision(timeIntervalSince1970: 1, size: 10)

        let outcome = PDFThumbnailRenderGate.finalize(
            nil,
            wasCancelled: false,
            capturedRevision: revision,
            currentRevision: revision
        )

        guard case .failed = outcome else {
            return XCTFail("expected failed for unchanged revision, got \(outcome)")
        }
    }

    func testFinalizeReturnsBusyWhenCancelledEvenIfRevisionUnchanged() {
        let revision = Self.revision(timeIntervalSince1970: 1, size: 10)

        let outcome = PDFThumbnailRenderGate.finalize(
            nil,
            wasCancelled: true,
            capturedRevision: revision,
            currentRevision: revision
        )

        guard case .busy = outcome else {
            return XCTFail("expected busy after cancellation, got \(outcome)")
        }
    }

    @MainActor
    func testAsyncRevisionReadFromMainActorPreservesFilesystemModificationDate() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-pdf-revision-date-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let pdfURL = directoryURL.appendingPathComponent("sermon.pdf")
        try writePDF(to: pdfURL, label: "A")

        let filesystemDate = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: pdfURL.path)[.modificationDate] as? Date
        )
        let revision = await PDFSourceRevision.currentAsync(for: pdfURL)

        XCTAssertEqual(revision.modificationDate, filesystemDate)
    }

    private static func revision(timeIntervalSince1970: TimeInterval, size: Int64) -> PDFSourceRevision {
        PDFSourceRevision(
            modificationDate: Date(timeIntervalSince1970: timeIntervalSince1970),
            size: size
        )
    }

    private func renderedImage(from outcome: PDFThumbnailRenderOutcome) -> NSImage? {
        if case .rendered(let image, _, _) = outcome {
            return image
        }
        return nil
    }

    private func pngData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            return nil
        }
        return rep.representation(using: .png, properties: [:])
    }

    private func writePDF(to url: URL, label: String) throws {
        let color = label == "A"
            ? CGColor(red: 1, green: 0, blue: 0, alpha: 1)
            : CGColor(red: 0, green: 0, blue: 1, alpha: 1)
        try writePDF(to: url, pageColors: [color])
    }

    private func writePDF(to url: URL, pageColors: [CGColor]) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 200, height: 200)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "eucaly.tests", code: 1)
        }
        for color in pageColors {
            context.beginPDFPage(nil)
            context.setFillColor(color)
            context.fill(mediaBox)
            context.endPDFPage()
        }
        context.closePDF()
    }
}
