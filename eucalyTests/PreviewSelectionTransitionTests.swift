import CoreGraphics
import XCTest
@testable import eucaly

@MainActor
final class PreviewSelectionTransitionTests: XCTestCase {
    func testMissingPlaylistSelectionRetiresEveryAcceptedPreviewTypeWithoutChangingCurrent() throws {
        for kind in PreviewKind.allCases {
            let fixture = try Fixture()
            defer { fixture.close() }
            fixture.accept(kind)
            XCTAssertTrue(fixture.flow.canLoadPreview)

            var requestedFiles: [URL] = []
            XCTAssertFalse(fixture.flow.previewPlaylistEntry(fixture.entryID, from: fixture.playlist) {
                requestedFiles.append($0)
            })

            XCTAssertTrue(requestedFiles.isEmpty)
            XCTAssertTrue(fixture.flow.previewIsEmpty, "A missing row cannot leave \(kind) loadable")
            XCTAssertFalse(fixture.flow.canLoadPreview)
            XCTAssertEqual(fixture.flow.previewSource, .none)
            XCTAssertNil(fixture.flow.previewSelectionID)
            XCTAssertTrue(fixture.flow.previewLoadError?.contains("Missing.txt") == true)
            XCTAssertEqual(fixture.playlist.entries.map(\.id), [fixture.entryID], "Missing entries remain removable")
            fixture.assertCurrentUnchanged()
        }
    }

    func testMissingPlaylistSelectionRejectsSuccessAndFailureFromAnEarlierPendingFile() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.accept(.lyrics)
        let source = PresentationFlowController.PreviewSource.file(fixture.root.appendingPathComponent("Earlier.pdf"))
        let token = fixture.flow.beginPreviewLoad(to: source)
        XCTAssertFalse(fixture.flow.canLoadPreview)

        XCTAssertFalse(fixture.flow.previewPlaylistEntry(fixture.entryID, from: fixture.playlist) { _ in
            XCTFail("A missing source must not reach the file loader")
        })
        let unavailableMessage = fixture.flow.previewLoadError

        XCTAssertFalse(fixture.flow.isPreviewLoading)
        XCTAssertFalse(fixture.flow.completePreviewLoad(token: token, source: source))
        XCTAssertFalse(fixture.flow.failPreviewLoad(token: token, source: source))
        XCTAssertTrue(fixture.flow.previewIsEmpty)
        XCTAssertEqual(fixture.flow.previewLoadError, unavailableMessage)
        XCTAssertFalse(fixture.flow.canLoadPreview)
        fixture.assertCurrentUnchanged()
    }

    func testRestoredPlaylistSourceCanBeExplicitlyRetriedAndRemovedRecordsFailSafely() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        XCTAssertFalse(fixture.flow.previewPlaylistEntry(fixture.entryID, from: fixture.playlist) { _ in
            XCTFail("A missing source must not reach the file loader")
        })
        try "Restored lyrics".write(to: fixture.missingURL, atomically: true, encoding: .utf8)

        var retryToken: UUID?
        XCTAssertTrue(fixture.flow.previewPlaylistEntry(fixture.entryID, from: fixture.playlist) { url in
            XCTAssertEqual(url, fixture.missingURL)
            retryToken = fixture.flow.beginPreviewLoad(to: .file(url))
        })
        XCTAssertTrue(fixture.flow.isPreviewLoading)
        XCTAssertNil(fixture.flow.previewLoadError)
        XCTAssertFalse(fixture.flow.canLoadPreview)
        XCTAssertTrue(fixture.flow.completePreviewLoad(token: try XCTUnwrap(retryToken), source: .file(fixture.missingURL)))
        fixture.flow.setPreviewSlides(LyricsParser.parseDocument("Restored lyrics").slides)
        XCTAssertTrue(fixture.flow.canLoadPreview)

        XCTAssertTrue(fixture.playlist.remove(ids: [fixture.entryID]))
        XCTAssertFalse(fixture.flow.previewPlaylistEntry(fixture.entryID, from: fixture.playlist) { _ in
            XCTFail("A retained selection for a removed entry must not load a file")
        })
        XCTAssertTrue(fixture.flow.previewIsEmpty)
        XCTAssertNotNil(fixture.flow.previewLoadError)
        XCTAssertFalse(fixture.flow.canLoadPreview)
        fixture.assertCurrentUnchanged()
    }

    func testWindowRetirementPreservesNewerPendingFilesIncludingVirtualPDFs() throws {
        let availableSelections: [Set<CGWindowID>] = [[], [99]]
        for kind in PreviewKind.fileKinds {
            for availableIDs in availableSelections {
                let fixture = try Fixture()
                defer { fixture.close() }
                fixture.accept(.window)
                let source = PresentationFlowController.PreviewSource.file(fixture.url(for: kind))
                let token = fixture.flow.beginPreviewLoad(to: source)

                XCTAssertTrue(fixture.flow.clearUnavailableWindowPreview(availableWindowIDs: availableIDs))

                XCTAssertTrue(fixture.flow.previewIsEmpty)
                XCTAssertEqual(fixture.flow.previewSource, .none)
                XCTAssertTrue(fixture.flow.isPreviewLoading, "Retiring an old window must not cancel \(kind)")
                XCTAssertEqual(fixture.flow.pendingPreviewSource, source)
                XCTAssertEqual(fixture.flow.previewLoadToken, token)
                XCTAssertNil(fixture.flow.previewLoadError)
                XCTAssertFalse(fixture.flow.canLoadPreview)
                XCTAssertTrue(fixture.flow.completePreviewLoad(token: token, source: source))
                fixture.setDocument(kind)
                XCTAssertTrue(fixture.flow.canLoadPreview)
                XCTAssertEqual(fixture.flow.previewSource, source)
                XCTAssertFalse(fixture.flow.clearUnavailableWindowPreview(availableWindowIDs: availableIDs))
                XCTAssertTrue(fixture.flow.canLoadPreview, "A late window notification cannot clear the new file")
                fixture.assertCurrentUnchanged()
            }
        }
    }

    func testUnchangedWindowSelectionKeepsPreviewAndPendingLoadWhileActualLossClearsOnlyThatWorkspace() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.accept(.window)
        let otherWorkspace = PresentationFlowController()
        otherWorkspace.setPreviewSource(.window(99))
        otherWorkspace.setPreviewSlides([Fixture.windowSlide(99)])
        let source = PresentationFlowController.PreviewSource.file(fixture.url(for: .lyrics))
        let token = fixture.flow.beginPreviewLoad(to: source)

        XCTAssertFalse(fixture.flow.clearUnavailableWindowPreview(availableWindowIDs: [41]))
        XCTAssertFalse(fixture.flow.previewIsEmpty)
        XCTAssertEqual(fixture.flow.previewLoadToken, token)
        XCTAssertTrue(fixture.flow.isPreviewLoading)

        fixture.flow.cancelPreviewLoad()
        XCTAssertTrue(fixture.flow.clearUnavailableWindowPreview(availableWindowIDs: []))
        XCTAssertTrue(fixture.flow.previewIsEmpty)
        XCTAssertFalse(fixture.flow.isPreviewLoading)
        XCTAssertNil(fixture.flow.previewLoadError)
        XCTAssertFalse(fixture.flow.canLoadPreview)
        XCTAssertFalse(fixture.flow.completePreviewLoad(token: token, source: source))
        XCTAssertEqual(otherWorkspace.previewSource, .window(99))
        XCTAssertEqual(otherWorkspace.previewSlides.first?.captureWindowID, 99)
        fixture.assertCurrentUnchanged()
    }

    func testPreviewTransitionsRejectSupersededCancelledAndClearedCompletions() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let first = PresentationFlowController.PreviewSource.file(fixture.url(for: .lyrics))
        let second = PresentationFlowController.PreviewSource.file(fixture.url(for: .pdf))
        let firstToken = fixture.flow.beginPreviewLoad(to: first)
        let secondToken = fixture.flow.beginPreviewLoad(to: second)
        let returnedToken = fixture.flow.beginPreviewLoad(to: first)
        XCTAssertFalse(fixture.flow.completePreviewLoad(token: firstToken, source: first))
        XCTAssertFalse(fixture.flow.failPreviewLoad(token: secondToken, source: second))
        XCTAssertTrue(fixture.flow.completePreviewLoad(token: returnedToken, source: first))
        fixture.setDocument(.lyrics)
        XCTAssertTrue(fixture.flow.canLoadPreview)

        let cancelledToken = fixture.flow.beginPreviewLoad(to: second)
        fixture.flow.cancelPreviewLoad()
        XCTAssertFalse(fixture.flow.completePreviewLoad(token: cancelledToken, source: second))
        XCTAssertFalse(fixture.flow.failPreviewLoad(token: cancelledToken, source: second))
        XCTAssertTrue(fixture.flow.canLoadPreview, "Canceling a pending load retains its accepted Preview")

        let clearedToken = fixture.flow.beginPreviewLoad(to: second)
        fixture.flow.clearPreviewDocument()
        XCTAssertFalse(fixture.flow.completePreviewLoad(token: clearedToken, source: second))
        XCTAssertFalse(fixture.flow.failPreviewLoad(token: clearedToken, source: second))
        XCTAssertTrue(fixture.flow.previewIsEmpty)
        XCTAssertNil(fixture.flow.previewLoadError)
        fixture.assertCurrentUnchanged()
    }

    func testActivePreviewLoadFailureRetiresAcceptedPreviewAndNewSelectionClearsItsError() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        fixture.accept(.window)
        let source = PresentationFlowController.PreviewSource.file(fixture.root.appendingPathComponent("Unreadable.pdf"))
        let token = fixture.flow.beginPreviewLoad(to: source)

        XCTAssertTrue(fixture.flow.failPreviewLoad(token: token, source: source))
        XCTAssertTrue(fixture.flow.previewIsEmpty)
        XCTAssertFalse(fixture.flow.isPreviewLoading)
        XCTAssertFalse(fixture.flow.canLoadPreview)
        XCTAssertEqual(fixture.flow.previewLoadError, "Couldn’t load Unreadable.pdf.")
        XCTAssertFalse(fixture.flow.completePreviewLoad(token: token, source: source))

        fixture.flow.setPreviewSource(.lyrics)
        fixture.setDocument(.lyrics)
        XCTAssertNil(fixture.flow.previewLoadError)
        XCTAssertTrue(fixture.flow.canLoadPreview)
        fixture.assertCurrentUnchanged()
    }

    private enum PreviewKind: CaseIterable, Equatable {
        case lyrics, pdf, image, video, window

        static var fileKinds: [PreviewKind] { [.lyrics, .pdf, .image, .video] }
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let missingURL: URL
        let entryID: UUID
        let playlist: PlaylistStore
        let flow = PresentationFlowController()
        let session = PresentationSession(projectionDisplays: ProjectionDisplayManager(displays: { [] }))
        let currentIDs: [Slide.ID]

        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("PreviewSelection-" + UUID().uuidString, isDirectory: true)
            let missingURL = root.appendingPathComponent("Missing.txt")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let playlist = PlaylistStore()
            XCTAssertTrue(playlist.load(fromRoot: root))
            let entryID = try XCTUnwrap(playlist.add(url: missingURL, after: nil))
            let current = LyricsParser.parseDocument("Current stays private to this workspace").slides
            self.root = root
            self.missingURL = missingURL
            self.playlist = playlist
            self.entryID = entryID
            currentIDs = current.map(\.id)
            session.setSlides(current)
        }

        func url(for kind: PreviewKind) -> URL {
            let suffix: String
            switch kind {
            case .lyrics: suffix = "txt"
            case .pdf: suffix = "pdf"
            case .image: suffix = "png"
            case .video: suffix = "mp4"
            case .window: suffix = "window"
            }
            return root.appendingPathComponent("Accepted." + suffix)
        }

        func accept(_ kind: PreviewKind) {
            flow.setPreviewSource(kind == .window ? .window(41) : .file(url(for: kind)))
            setDocument(kind)
        }

        func setDocument(_ kind: PreviewKind) {
            switch kind {
            case .lyrics:
                flow.setPreviewSlides(LyricsParser.parseDocument("Accepted lyrics").slides)
            case .pdf:
                flow.setPreviewPDFSource(PDFSlideSource(url: url(for: kind), pageCount: 250))
            case .image:
                flow.setPreviewSlides([Slide(index: 1, lines: [], label: "Image", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: url(for: kind), captureWindowID: nil)])
            case .video:
                flow.setPreviewSlides([Slide(index: 1, lines: [], label: "Video", videoURL: url(for: kind), pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: nil)])
            case .window:
                flow.setPreviewSlides([Self.windowSlide(41)])
            }
        }

        static func windowSlide(_ id: CGWindowID) -> Slide {
            Slide(index: 1, lines: [], label: "Window", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: id)
        }

        func assertCurrentUnchanged(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(session.slides.map(\.id), currentIDs, file: file, line: line)
            XCTAssertFalse(session.isPresenting, file: file, line: line)
        }

        func close() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
