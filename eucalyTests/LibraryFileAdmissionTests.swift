import Darwin
import XCTest
@testable import eucaly

final class LibraryFileAdmissionTests: XCTestCase {
    func testReadableRegularSourcesOfEveryPreviewKindAreAdmitted() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try scanPreviewSources(in: root)
        XCTAssertEqual(Set(files.map(\.kind)), [.txt, .pdf, .image, .video])
        for file in files {
            XCTAssertNoThrow(try LibraryFileAdmission.requireReadableRegularFile(at: file.url))
        }
    }

    func testSourcesDeletedAfterDiscoveryAreRejectedForEveryPreviewKind() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for file in try scanPreviewSources(in: root) {
            try FileManager.default.removeItem(at: file.url)
            XCTAssertThrowsError(try LibraryFileAdmission.requireReadableRegularFile(at: file.url), file.url.path)
        }
    }

    func testSourcesReplacedByDirectoriesAfterDiscoveryAreRejectedForEveryPreviewKind() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for file in try scanPreviewSources(in: root) {
            try FileManager.default.removeItem(at: file.url)
            try FileManager.default.createDirectory(at: file.url, withIntermediateDirectories: true)
            XCTAssertThrowsError(try LibraryFileAdmission.requireReadableRegularFile(at: file.url), file.url.path)
        }
    }

    func testSourcesThatLoseReadPermissionAfterDiscoveryAreRejectedAndCanBeRetried() throws {
        try XCTSkipIf(geteuid() == 0, "Root bypasses filesystem read permissions")
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for file in try scanPreviewSources(in: root) {
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.url.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path) }
            XCTAssertThrowsError(try LibraryFileAdmission.requireReadableRegularFile(at: file.url), file.url.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.url.path)
            XCTAssertNoThrow(try LibraryFileAdmission.requireReadableRegularFile(at: file.url))
        }
    }

    func testSourcesReplacedBySymbolicLinksAfterDiscoveryAreRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try scanPreviewSources(in: root)
        let target = root.appendingPathComponent("Readable target.dat")
        try Data("Readable target".utf8).write(to: target)
        for file in files {
            try FileManager.default.removeItem(at: file.url)
            try FileManager.default.createSymbolicLink(at: file.url, withDestinationURL: target)
            XCTAssertThrowsError(try LibraryFileAdmission.requireReadableRegularFile(at: file.url), file.url.path)
        }
    }

    func testNonlocalURLsAreRejectedBeforeOpeningAPath() throws {
        XCTAssertThrowsError(try LibraryFileAdmission.requireReadableRegularFile(
            at: XCTUnwrap(URL(string: "https://example.invalid/Slide.png"))))
        XCTAssertThrowsError(try LibraryFileAdmission.requireReadableRegularFile(
            at: XCTUnwrap(URL(string: "file://remote.invalid/Slide.png"))))
    }

    @MainActor
    func testAStaleAdmissionFailureCannotReplaceANewerWorkspacePreviewOrCurrent() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try scanPreviewSources(in: root)
        let removedURL = try XCTUnwrap(files.first(where: { $0.kind == .image })).url
        let validURL = try XCTUnwrap(files.first(where: { $0.kind == .txt })).url
        let flow = PresentationFlowController()
        let otherWorkspace = PresentationFlowController()
        otherWorkspace.setPreviewSource(.lyrics)
        otherWorkspace.setPreviewSlides(LyricsParser.parseDocument("Other workspace Preview").slides)
        let otherIDs = otherWorkspace.previewSlides.map(\.id)
        let session = PresentationSession(projectionDisplays: ProjectionDisplayManager(displays: { [] }))
        session.setSlides(LyricsParser.parseDocument("Current remains accepted").slides)
        let currentIDs = session.slides.map(\.id)
        let removedSource = PresentationFlowController.PreviewSource.file(removedURL)
        let removedToken = flow.beginPreviewLoad(to: removedSource)
        try FileManager.default.removeItem(at: removedURL)
        XCTAssertThrowsError(try LibraryFileAdmission.requireReadableRegularFile(at: removedURL))

        // Hold the failed request's main-queue delivery until a newer selection
        // has been admitted and accepted, without relying on queue timing.
        let validSource = PresentationFlowController.PreviewSource.file(validURL)
        let validToken = flow.beginPreviewLoad(to: validSource)
        try LibraryFileAdmission.requireReadableRegularFile(at: validURL)
        XCTAssertTrue(flow.completePreviewLoad(token: validToken, source: validSource))
        flow.setPreviewSlides(LyricsParser.parseDocument("Newer accepted Preview").slides)
        let acceptedIDs = flow.previewSlides.map(\.id)

        XCTAssertFalse(flow.failPreviewLoad(token: removedToken, source: removedSource))
        XCTAssertFalse(flow.completePreviewLoad(token: removedToken, source: removedSource))
        XCTAssertEqual(flow.previewSlides.map(\.id), acceptedIDs)
        XCTAssertEqual(flow.previewSource, validSource)
        XCTAssertNil(flow.previewLoadError)
        XCTAssertTrue(flow.canLoadPreview)
        XCTAssertEqual(otherWorkspace.previewSlides.map(\.id), otherIDs)
        XCTAssertEqual(session.slides.map(\.id), currentIDs)
        XCTAssertFalse(session.isPresenting)
    }

    private func scanPreviewSources(in root: URL) throws -> [LibraryDiscoveredFileModel] {
        for suffix in ["txt", "pdf", "png", "mp4"] {
            try Data("Readable source".utf8).write(to: root.appendingPathComponent("Source." + suffix))
        }
        let files = try LibraryFileScannerService().discoverFiles(in: root)
        XCTAssertEqual(files.count, 4)
        return files
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-file-admission-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
