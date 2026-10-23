import AppKit
import CoreGraphics
import PDFKit
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class AcceptedPDFOutputTests: XCTestCase {
    func testRejectedCurrentCannotReplaceNativePDFAfterFileReplacementOrDeletion() async throws {
        for profileID in [OutputProfile.audienceID, OutputProfile.confidenceID] {
            for deletesFile in [false, true] {
                try await withPDFFile { url in
                    try writePDF(to: url, pageCount: 2)
                    let fixture = try NativePDFOutputFixture(profileID: profileID)
                    defer { fixture.close() }
                    fixture.session.setPDFSlideSource(.init(url: url, pageCount: 2))
                    fixture.session.showSlides()
                    let accepted = try XCTUnwrap(fixture.outputs.snapshot(for: fixture.destination).acceptedPDF)
                    let host = fixture.host()
                    try await settle(host)
                    let originalView = try XCTUnwrap(pdfView(in: host))
                    let originalDocument = try XCTUnwrap(originalView.document)
                    let originalPixel = try pixel(in: originalDocument, page: 0)

                    if deletesFile { try FileManager.default.removeItem(at: url) }
                    else { try writePDF(to: url, pageCount: 3) }
                    let requester = try XCTUnwrap(fixture.outputs.profiles.addWorkspace(name: "Picker"))
                    _ = fixture.capture.beginPickerRequest(workspaceID: requester, replacementProblem: { nil })
                    fixture.session.setSlides([.init(index: 0, lines: [], label: "Picked window",
                        videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: 42)])
                    fixture.session.requestCurrentProjection()
                    try await settle(host)

                    XCTAssertTrue(fixture.session.projectionDisplayIssue?.contains("Finish or cancel") == true)
                    XCTAssertNil(fixture.session.pdfDocumentCache.acceptedSource(for: url), "Private Current has released its preparation cache")
                    XCTAssertTrue(fixture.outputs.snapshot(for: fixture.destination).acceptedPDF === accepted)
                    let retainedView = try XCTUnwrap(pdfView(in: host))
                    XCTAssertTrue(retainedView === originalView)
                    XCTAssertTrue(retainedView.document === originalDocument,
                                  "Observed Current changes must not reopen an accepted PDF's changed/deleted path")
                    XCTAssertEqual(try pixel(in: try XCTUnwrap(retainedView.document), page: 0), originalPixel)

                    // Rebuilding the native composition also needs no Current cache or live file.
                    let reopened = fixture.host()
                    try await settle(reopened)
                    let reopenedDocument = try XCTUnwrap(pdfView(in: reopened)?.document)
                    XCTAssertEqual(reopenedDocument.pageCount, 2)
                    XCTAssertEqual(try pixel(in: reopenedDocument, page: 0), originalPixel)
                }
            }
        }
    }

    func testNativeCompositionReusesAcceptedPDFForNavigationAndReplacesItOnExplicitReload() async throws {
        for profileID in [OutputProfile.audienceID, OutputProfile.confidenceID] {
            try await withPDFFile { url in
                try writePDF(to: url, pageCount: 2)
                let fixture = try NativePDFOutputFixture(profileID: profileID)
                defer { fixture.close() }
                fixture.session.setPDFSlideSource(.init(url: url, pageCount: 2))
                fixture.session.showSlides()
                let accepted = try XCTUnwrap(fixture.outputs.snapshot(for: fixture.destination).acceptedPDF)
                let host = fixture.host()
                try await settle(host)
                let firstView = try XCTUnwrap(pdfView(in: host))
                let firstDocument = try XCTUnwrap(firstView.document)
                let firstPixel = try pixel(in: firstDocument, page: 0)

                try writePDF(to: url, pageCount: 2, reversed: true)
                fixture.session.selectCurrentSlide(PDFSlideCatalog.stableSlideID(url: url, pageIndex: 1))
                try await settle(host)
                let secondView = try XCTUnwrap(pdfView(in: host))
                XCTAssertTrue(secondView === firstView, "Page navigation retains its native PDFView")
                XCTAssertTrue(secondView.document === firstDocument)
                XCTAssertEqual(firstDocument.index(for: try XCTUnwrap(secondView.currentPage)), 1)
                XCTAssertTrue(fixture.outputs.snapshot(for: fixture.destination).acceptedPDF === accepted)

                fixture.session.setPDFSlideSource(.init(url: url, pageCount: 2))
                fixture.session.requestCurrentProjection()
                try await settle(host)
                let reloadedSource = try XCTUnwrap(fixture.outputs.snapshot(for: fixture.destination).acceptedPDF)
                let reloadedView = try XCTUnwrap(pdfView(in: host))
                let reloadedDocument = try XCTUnwrap(reloadedView.document)
                XCTAssertFalse(reloadedSource === accepted)
                XCTAssertFalse(reloadedDocument === firstDocument)
                XCTAssertNotEqual(try pixel(in: reloadedDocument, page: 0), firstPixel)

                try FileManager.default.removeItem(at: url)
                fixture.session.selectCurrentSlide(PDFSlideCatalog.stableSlideID(url: url, pageIndex: 1))
                try await settle(host)
                XCTAssertTrue(pdfView(in: host) === reloadedView)
                XCTAssertTrue(pdfView(in: host)?.document === reloadedDocument)
                XCTAssertEqual(reloadedDocument.index(for: try XCTUnwrap(reloadedView.currentPage)), 1)
            }
        }
    }

    func testNativePDFTransferAndPeerClearPreserveAcceptedWorkspaceSources() async throws {
        try await withPDFFile { url in
            try writePDF(to: url, pageCount: 2)
            let fixture = try NativePDFOutputFixture()
            defer { fixture.close() }
            fixture.session.setPDFSlideSource(.init(url: url, pageCount: 2))
            fixture.session.showSlides()
            let sourceA = try XCTUnwrap(fixture.outputs.snapshot(for: fixture.destination).acceptedPDF)
            let host = fixture.host()
            try await settle(host)
            let pixelA = try pixel(in: try XCTUnwrap(pdfView(in: host)?.document), page: 0)

            try writePDF(to: url, pageCount: 3)
            let peerID = try XCTUnwrap(fixture.outputs.profiles.addWorkspace(name: "Peer"))
            let peer = fixture.outputs.session(workspace: peerID)
            peer.setPDFSlideSource(.init(url: url, pageCount: 3))
            XCTAssertEqual(peer.documentRevision, fixture.session.documentRevision)
            XCTAssertTrue(fixture.outputs.moveOutput(fixture.destination, to: peer))
            try await settle(host)
            let sourceB = try XCTUnwrap(fixture.outputs.snapshot(for: fixture.destination).acceptedPDF)
            XCTAssertFalse(sourceB === sourceA)
            XCTAssertEqual(pdfView(in: host)?.document?.pageCount, 3)
            XCTAssertNotEqual(try pixel(in: try XCTUnwrap(pdfView(in: host)?.document), page: 0), pixelA)

            peer.clearSlides()
            try await settle(host)
            XCTAssertNil(pdfView(in: host))
            XCTAssertTrue(fixture.outputs.moveOutput(fixture.destination, to: fixture.session))
            try await settle(host)
            XCTAssertTrue(fixture.outputs.snapshot(for: fixture.destination).acceptedPDF === sourceA)
            XCTAssertEqual(pdfView(in: host)?.document?.pageCount, 2)
            XCTAssertEqual(try pixel(in: try XCTUnwrap(pdfView(in: host)?.document), page: 0), pixelA)

            try FileManager.default.removeItem(at: url)
            let reopened = fixture.host()
            try await settle(reopened)
            XCTAssertEqual(pdfView(in: reopened)?.document?.pageCount, 2)
            XCTAssertEqual(try pixel(in: try XCTUnwrap(pdfView(in: reopened)?.document), page: 0), pixelA)
        }
    }

    func testNativePDFWithoutAcceptedBytesDoesNotReopenItsPath() async throws {
        try await withPDFFile { url in
            try writePDF(to: url, pageCount: 2)
            let fixture = try NativePDFOutputFixture()
            defer { fixture.close() }
            fixture.session.setPDFSlideSource(.init(url: url, pageCount: 2))
            fixture.session.pdfDocumentCache.clear()
            fixture.session.showSlides()
            XCTAssertNotNil(fixture.outputs.snapshot(for: fixture.destination).localMedia?.pdfURL)
            XCTAssertNil(fixture.outputs.snapshot(for: fixture.destination).acceptedPDF)
            let host = fixture.host()
            try await settle(host)
            XCTAssertNil(try XCTUnwrap(pdfView(in: host)).document,
                         "A rendering adapter cannot repair absent accepted bytes by reopening Current's path")
            XCTAssertNil(fixture.session.pdfDocumentCache.acceptedSource(for: url))
        }
    }

    private func settle(_ view: NSView) async throws {
        // Give SwiftUI's observed-object transaction and AppKit layout their UI boundaries.
        for _ in 0..<3 {
            view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        view.layoutSubtreeIfNeeded()
    }

    private func pdfView(in view: NSView) -> PDFSlideNSView? {
        if let pdf = view as? PDFSlideNSView { return pdf }
        return view.subviews.lazy.compactMap { self.pdfView(in: $0) }.first
    }

    private func pixel(in document: PDFDocument, page index: Int) throws -> [UInt8] {
        let page = try XCTUnwrap(document.page(at: index)?.pageRef)
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 64, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.concatenate(page.getDrawingTransform(.cropBox, rect: .init(x: 0, y: 0, width: 16, height: 16),
                                                    rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes + 8 * 64 + 8 * 4, count: 4))
    }

    private func withPDFFile(_ body: (URL) async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AcceptedPDFOutput-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try await body(directory.appendingPathComponent("accepted.pdf"))
    }

    private func writePDF(to url: URL, pageCount: Int, reversed: Bool = false) throws {
        let staging = url.deletingLastPathComponent().appendingPathComponent("replacement.pdf")
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

@MainActor
private final class NativePDFOutputFixture {
    let capture: ScreenCaptureManager
    let outputs: OutputCoordinator
    let session: PresentationSession
    let destination: UUID
    private var windows: [NSWindow] = []

    init(profileID: UUID = OutputProfile.audienceID) throws {
        let capture = ScreenCaptureManager()
        self.capture = capture
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "PDF test",
                                        frame: .init(x: 0, y: 0, width: 800, height: 600))
        let displays = ProjectionDisplayManager(displays: { [monitor] })
        let profiles = OutputProfileStore(monitor: monitor.target)
        let destination = try XCTUnwrap(profiles.document.destinations.first?.id)
        self.destination = destination
        profiles.selectProfile(profileID, for: destination)
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, captureManager: capture,
                                    driverFactory: { FakeOutputDriver() })
        self.outputs = outputs
        session = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
    }

    func host() -> NSHostingView<OutputCompositionView> {
        let host = NSHostingView(rootView: OutputCompositionView(coordinator: outputs, destinationID: destination))
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.animationBehavior = .none
        window.contentView = host
        windows.append(window)
        window.orderBack(nil)
        return host
    }

    func close() {
        outputs.stopAllOutputs()
        for window in windows { window.contentView = nil; window.close() }
        windows.removeAll()
    }
}
