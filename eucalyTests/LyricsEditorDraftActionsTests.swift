import AppKit
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class LyricsEditorDraftActionsTests: XCTestCase {
    func testNewDraftPreviewKeepsUnsavedIdentityAndFencesOlderPendingLoad() throws {
        let draft = "[Verse 1:]\nWE GATHER &amp; SING\n\n[Chorus:]\nஅற்புத கிருபை"
        let fixture = try Fixture(draft, newDraft: true)
        defer { fixture.close() }
        let documentID = fixture.editor.documentID
        let currentIDs = fixture.current.slides.map(\.id)
        let savedBytes = try Data(contentsOf: fixture.fileURL)
        let savedFiles = try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)
        let olderSource = PresentationFlowController.PreviewSource.file(fixture.fileURL)
        let olderToken = fixture.flow.beginPreviewLoad(to: olderSource)
        XCTAssertTrue(fixture.flow.isPreviewLoading)
        XCTAssertNil(fixture.editor.sourceURL)
        XCTAssertTrue(fixture.editor.canPreviewDraft)

        XCTAssertTrue(try fixture.previewDraft())

        XCTAssertEqual(fixture.flow.previewSource, .lyrics)
        XCTAssertNil(fixture.flow.pendingPreviewSource)
        XCTAssertFalse(fixture.flow.isPreviewLoading)
        XCTAssertTrue(fixture.flow.canLoadPreview)
        XCTAssertNil(fixture.editor.sourceURL)
        XCTAssertEqual(fixture.editor.documentID, documentID)
        XCTAssertEqual(Array(fixture.editor.draft.utf8), Array(draft.utf8))
        XCTAssertEqual(fixture.view.string, draft)
        XCTAssertEqual(fixture.editor.savedText, "")
        XCTAssertTrue(fixture.editor.isDirty)
        XCTAssertTrue(fixture.editor.canSave)
        XCTAssertTrue(fixture.editor.isPreviewSynchronized)
        XCTAssertFalse(fixture.editor.canPreviewDraft)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), savedBytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), savedFiles)
        XCTAssertEqual(fixture.current.slides.map(\.id), currentIDs)
        XCTAssertFalse(fixture.current.isPresenting)
        XCTAssertFalse(fixture.undo.canUndo)

        let previewIDs = fixture.flow.previewSlides.map(\.id)
        XCTAssertFalse(fixture.flow.completePreviewLoad(token: olderToken, source: olderSource))
        XCTAssertEqual(fixture.flow.previewSource, .lyrics)
        XCTAssertEqual(fixture.flow.previewSlides.map(\.id), previewIDs)
        XCTAssertTrue(fixture.editor.isPreviewSynchronized)
    }

    func testClearUndoCanPreviewSavedDraftWithoutSavingOrChangingCurrent() throws {
        let fixture = try Fixture("Verse 1\nOriginal lyrics\n\nChorus\nWe sing together")
        defer { fixture.close() }
        let documentID = fixture.editor.documentID
        let currentIDs = fixture.current.slides.map(\.id)
        let savedBytes = try Data(contentsOf: fixture.fileURL)

        fixture.edit { XCTAssertTrue(fixture.focus.clearLyrics()) }
        fixture.flow.clearPreviewDocument()
        fixture.editor.invalidatePreview()
        fixture.undo.undo()

        XCTAssertEqual(fixture.editor.draft, fixture.editor.savedText)
        XCTAssertFalse(fixture.editor.canSave)
        XCTAssertTrue(fixture.editor.canPreviewDraft)
        XCTAssertTrue(fixture.flow.previewIsEmpty)

        XCTAssertTrue(try fixture.previewDraft())

        XCTAssertTrue(fixture.editor.isPreviewSynchronized)
        XCTAssertFalse(fixture.editor.canPreviewDraft)
        XCTAssertFalse(fixture.editor.canSave)
        XCTAssertTrue(fixture.flow.canLoadPreview)
        XCTAssertEqual(fixture.editor.documentID, documentID)
        XCTAssertEqual(fixture.editor.sourceURL, fixture.fileURL)
        XCTAssertEqual(try Data(contentsOf: fixture.fileURL), savedBytes)
        XCTAssertEqual(fixture.current.slides.map(\.id), currentIDs)
        XCTAssertFalse(fixture.current.isPresenting)

        // The existing explicit load is still required to replace Current.
        XCTAssertTrue(fixture.flow.setCurrentSlides(fixture.flow.previewSlides, in: fixture.current,
                                                  lyricsSourceURL: fixture.editor.sourceURL))
        XCTAssertEqual(fixture.current.slides.map(\.id), fixture.flow.previewSlides.map(\.id))
    }

    func testPreviewUsesExactReviewedDraftAndPreservesIdentitySelectionAndSavedFile() throws {
        let source = "Verse 1\nOriginal lyrics\n\nChorus\nWe sing together"
        let fixture = try Fixture(source)
        let otherWorkspace = try Fixture("Verse\nOther workspace lyrics")
        defer { fixture.close(); otherWorkspace.close() }
        let documentID = fixture.editor.documentID
        let currentIDs = fixture.current.slides.map(\.id)
        let otherPreviewIDs = otherWorkspace.flow.previewSlides.map(\.id)
        let otherCurrentIDs = otherWorkspace.current.slides.map(\.id)
        fixture.flow.selectPreviewSlide(fixture.flow.previewSlides[1].id)
        let proposed = "[Verse 1:]\nWE GATHER &amp; SING\n\n[Chorus:]\nஅற்புத கிருபை"
        fixture.edit {
            XCTAssertTrue(fixture.focus.applyLyricsCleanup(proposed, replacing: source))
        }
        let undoName = fixture.undo.undoActionName
        let editorSelection = NSRange(location: 4, length: 5)
        fixture.view.setSelectedRange(editorSelection)

        XCTAssertTrue(try fixture.previewDraft())

        XCTAssertEqual(Array(fixture.editor.draft.utf8), Array(proposed.utf8))
        XCTAssertEqual(fixture.view.string, proposed)
        XCTAssertEqual(fixture.view.selectedRange(), editorSelection)
        XCTAssertEqual(fixture.window.firstResponder as? LyricsTextView, fixture.view)
        XCTAssertEqual(fixture.undo.undoActionName, undoName, "Preview must not add a text-edit Undo action")
        XCTAssertEqual(fixture.editor.savedText, source)
        XCTAssertTrue(fixture.editor.canSave)
        XCTAssertTrue(fixture.editor.isPreviewSynchronized)
        XCTAssertEqual(fixture.editor.documentID, documentID)
        XCTAssertEqual(fixture.editor.sourceURL, fixture.fileURL)
        XCTAssertEqual(fixture.flow.previewSource, .file(fixture.fileURL))
        XCTAssertEqual(fixture.flow.previewSlides.map { $0.lines.map(\.text) },
                       LyricsParser.parseDocument(proposed).slides.map { $0.lines.map(\.text) })
        XCTAssertEqual(fixture.flow.previewSelectionID, fixture.flow.previewSlides[1].id)
        XCTAssertEqual(try String(contentsOf: fixture.fileURL, encoding: .utf8), source)
        XCTAssertEqual(fixture.current.slides.map(\.id), currentIDs)
        XCTAssertEqual(otherWorkspace.flow.previewSlides.map(\.id), otherPreviewIDs)
        XCTAssertEqual(otherWorkspace.current.slides.map(\.id), otherCurrentIDs)

        fixture.undo.undo()
        XCTAssertEqual(fixture.editor.draft, source)
        XCTAssertFalse(fixture.editor.isPreviewSynchronized,
                       "Undo edits the draft; it must not silently replace the reviewed Preview")
    }

    func testNormalizeFormattingIsDraftOnlyAndOneNativeUndoAction() throws {
        let source = "[Verse 1:]\nOriginal lyrics\n[Translation:]\nமொழிபெயர்ப்பு"
        let fixture = try Fixture(source)
        defer { fixture.close() }
        let previewIDs = fixture.flow.previewSlides.map(\.id)
        let currentIDs = fixture.current.slides.map(\.id)
        fixture.view.setSelectedRange(NSRange(location: 4, length: 2))

        try fixture.edit {
            XCTAssertTrue(try LyricsEditorDraftActions.normalizeFormatting(editor: fixture.editor, focus: fixture.focus))
        }

        XCTAssertEqual(fixture.editor.draft, "Verse 1\nOriginal lyrics\n\nTranslation\nமொழிபெயர்ப்பு")
        XCTAssertEqual(fixture.view.selectedRange(), NSRange(location: 4, length: 2))
        XCTAssertEqual(fixture.editor.previewedText, source)
        XCTAssertTrue(fixture.editor.canPreviewDraft)
        XCTAssertEqual(fixture.flow.previewSlides.map(\.id), previewIDs)
        XCTAssertEqual(fixture.current.slides.map(\.id), currentIDs)
        XCTAssertEqual(try String(contentsOf: fixture.fileURL, encoding: .utf8), source)
        fixture.undo.undo()
        XCTAssertEqual(fixture.editor.draft, source)
        XCTAssertTrue(fixture.editor.isPreviewSynchronized)
        XCTAssertFalse(fixture.undo.canUndo)
        fixture.undo.redo()
        XCTAssertTrue(try LyricsEditorDraftActions.normalizeFormatting(editor: fixture.editor, focus: fixture.focus))
        fixture.undo.undo()
        XCTAssertEqual(fixture.editor.draft, source, "A no-op normalization adds no second Undo action")
    }

    func testEmptyAndInactiveCommandsAreNoOps() throws {
        for text in ["", " \n\t "] {
            let fixture = try Fixture(text)
            defer { fixture.close() }
            fixture.flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nAccepted Preview").slides)
            let acceptedIDs = fixture.flow.previewSlides.map(\.id)
            XCTAssertFalse(fixture.editor.canPreviewDraft)
            XCTAssertFalse(try fixture.previewDraft())
            XCTAssertFalse(try LyricsEditorDraftActions.normalizeFormatting(editor: fixture.editor, focus: fixture.focus))
            XCTAssertEqual(fixture.flow.previewSlides.map(\.id), acceptedIDs)
            XCTAssertEqual(fixture.editor.draft, text)
            XCTAssertFalse(fixture.undo.canUndo)

            fixture.editor.endEditing()
            fixture.editor.draft = "A stale nonempty binding"
            XCTAssertFalse(try fixture.previewDraft())
            XCTAssertFalse(try LyricsEditorDraftActions.normalizeFormatting(editor: fixture.editor, focus: fixture.focus))
            XCTAssertEqual(fixture.flow.previewSlides.map(\.id), acceptedIDs)
        }
    }

    func testUnfinishedCompositionCannotReplaceAcceptedPreviewOrNormalizeDraft() throws {
        let fixture = try Fixture("Verse\nAccepted lyrics")
        defer { fixture.close() }
        let acceptedIDs = fixture.flow.previewSlides.map(\.id)
        let previewedText = fixture.editor.previewedText
        fixture.edit {
            fixture.view.setMarkedText("தமிழ்", selectedRange: NSRange(location: 0, length: 2),
                                       replacementRange: NSRange(location: 0, length: 0))
        }
        let composedText = fixture.view.string

        XCTAssertThrowsError(try fixture.previewDraft()) { error in
            XCTAssertEqual(error as? LyricsEditorDraftActions.Failure, .uncommittedText)
        }
        XCTAssertThrowsError(try LyricsEditorDraftActions.normalizeFormatting(editor: fixture.editor, focus: fixture.focus))
        XCTAssertTrue(fixture.view.hasMarkedText())
        XCTAssertEqual(fixture.view.string, composedText)
        XCTAssertEqual(fixture.flow.previewSlides.map(\.id), acceptedIDs)
        XCTAssertEqual(fixture.editor.previewedText, previewedText)
        fixture.edit { fixture.view.unmarkText() }
    }

    func testStaleBindingAndDetachedNativeEditorCannotReplaceAcceptedPreview() throws {
        let fixture = try Fixture("Verse\nAccepted lyrics")
        defer { fixture.close() }
        let acceptedIDs = fixture.flow.previewSlides.map(\.id)
        let previewedText = fixture.editor.previewedText
        fixture.editor.draft = "Stale binding differs from native text"
        XCTAssertThrowsError(try fixture.previewDraft())
        XCTAssertEqual(fixture.flow.previewSlides.map(\.id), acceptedIDs)
        XCTAssertEqual(fixture.editor.previewedText, previewedText)

        fixture.editor.draft = fixture.view.string
        fixture.focus.detach(fixture.view)
        XCTAssertThrowsError(try fixture.previewDraft())
        XCTAssertThrowsError(try LyricsEditorDraftActions.normalizeFormatting(editor: fixture.editor, focus: fixture.focus))
        XCTAssertEqual(fixture.flow.previewSlides.map(\.id), acceptedIDs)
        XCTAssertEqual(fixture.editor.previewedText, previewedText)
    }

    func testNoSlidesKeepsPreviouslyAcceptedPreviewAndSynchronizationBaseline() throws {
        let source = "Verse\nAccepted lyrics"
        let fixture = try Fixture(source)
        defer { fixture.close() }
        let acceptedIDs = fixture.flow.previewSlides.map(\.id)
        fixture.edit {
            XCTAssertTrue(fixture.focus.applyLyricsCleanup("#title: Metadata only", replacing: source))
        }

        XCTAssertThrowsError(try fixture.previewDraft()) { error in
            XCTAssertEqual(error as? LyricsEditorDraftActions.Failure, .noSlides)
        }

        XCTAssertEqual(fixture.flow.previewSlides.map(\.id), acceptedIDs)
        XCTAssertEqual(fixture.flow.previewSource, .file(fixture.fileURL))
        XCTAssertEqual(fixture.editor.previewedText, source)
        XCTAssertFalse(fixture.editor.isPreviewSynchronized)
        XCTAssertTrue(fixture.editor.canPreviewDraft)
    }

    @MainActor
    private final class Fixture {
        var editor = LyricsEditorSession()
        let focus = PlainTextEditorFocusController()
        let flow = PresentationFlowController()
        let current = PresentationSession(projectionDisplays: ProjectionDisplayManager(displays: { [] }))
        let window: NSWindow
        let directory: URL
        let fileURL: URL
        var coordinator: PlainTextEditor.Coordinator!
        var view: LyricsTextView!
        var undo: UndoManager { window.undoManager! }

        init(_ source: String, newDraft: Bool = false) throws {
            let fixtureDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
            let fixtureURL = fixtureDirectory.appendingPathComponent("draft-actions-fixture.txt")
            try source.write(to: fixtureURL, atomically: true, encoding: .utf8)
            directory = fixtureDirectory
            fileURL = fixtureURL
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            if newDraft {
                editor.beginNew()
                editor.draft = source
            } else {
                editor.beginEditing(text: source, sourceURL: fileURL)
                flow.setPreviewSource(.file(fileURL))
                flow.setPreviewSlides(LyricsParser.parseDocument(source).slides)
            }
            current.setSlides(LyricsParser.parseDocument("Verse\nCurrent stays intact").slides)
            coordinator = PlainTextEditor.Coordinator(
                text: Binding(get: { [unowned self] in self.editor.draft },
                              set: { [unowned self] in self.editor.draft = $0 }),
                focusController: focus)
            let scroll = PlainTextEditor.makeScrollView(text: editor.draft, coordinator: coordinator)
            window.contentView = scroll
            scroll.frame = NSRect(x: 0, y: 0, width: 640, height: 400)
            view = try XCTUnwrap(scroll.documentView as? LyricsTextView)
            XCTAssertTrue(window.makeFirstResponder(view))
            undo.groupsByEvent = false
            undo.removeAllActions()
        }

        func previewDraft() throws -> Bool {
            try LyricsEditorDraftActions.updatePreview(editor: &editor, focus: focus, flow: flow)
        }

        func edit(_ action: () throws -> Void) rethrows {
            undo.beginUndoGrouping()
            defer { undo.endUndoGrouping() }
            try action()
        }

        func close() {
            view.delegate = nil
            view.textStorage?.delegate = nil
            coordinator.detach(view)
            window.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
