import AppKit
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class LyricsCleanupApplicationTests: XCTestCase {
    func testApplyUpdatesOnlyDraftAsOneUndoableEditAndPreservesDocumentIdentity() throws {
        let source = "WE GATHER HERE\nWITH JOY"
        let fixture = try Fixture(source)
        defer { fixture.close() }
        let documentID = fixture.editor.documentID
        let proposed = "Verse 1\nWe gather here\nwith joy"
        fixture.view.setSelectedRange(NSRange(location: 3, length: 6))

        fixture.edit {
            XCTAssertTrue(fixture.focus.applyLyricsCleanup(proposed, replacing: source))
        }

        XCTAssertEqual(fixture.editor.draft, proposed)
        XCTAssertEqual(fixture.editor.savedText, source)
        XCTAssertEqual(fixture.editor.previewedText, source)
        XCTAssertFalse(fixture.editor.isPreviewSynchronized)
        XCTAssertTrue(fixture.editor.isDirty)
        XCTAssertEqual(fixture.editor.documentID, documentID)
        XCTAssertEqual(fixture.view.selectedRange(), NSRange(location: 3, length: 6))
        XCTAssertEqual(fixture.undo.undoActionName, "Clean Up Lyrics")
        fixture.undo.undo()
        XCTAssertEqual(fixture.editor.draft, source)
        XCTAssertFalse(fixture.editor.isDirty)
        XCTAssertTrue(fixture.editor.isPreviewSynchronized)
        XCTAssertFalse(fixture.undo.canUndo)
        fixture.undo.redo()
        XCTAssertEqual(fixture.editor.draft, proposed)
    }

    func testStaleSourceAndMarkedCompositionCannotApply() throws {
        let fixture = try Fixture("Original lyrics")
        defer { fixture.close() }
        XCTAssertFalse(fixture.focus.applyLyricsCleanup("Corrected", replacing: "Older lyrics"))
        XCTAssertEqual(fixture.editor.draft, "Original lyrics")
        XCTAssertFalse(fixture.undo.canUndo)

        fixture.edit {
            fixture.view.setMarkedText("தமிழ்", selectedRange: NSRange(location: 0, length: 2),
                                       replacementRange: NSRange(location: 0, length: 0))
        }
        let composed = fixture.view.string
        XCTAssertTrue(fixture.view.hasMarkedText())
        XCTAssertFalse(fixture.focus.applyLyricsCleanup("Corrected", replacing: composed))
        XCTAssertEqual(fixture.view.string, composed)
        XCTAssertTrue(fixture.view.hasMarkedText())
        fixture.edit { fixture.view.unmarkText() }
    }

    func testApprovedTextIsAppliedExactlyAndNoOpAddsNoUndo() throws {
        let source = "Original lyrics"
        let fixture = try Fixture(source)
        defer { fixture.close() }
        XCTAssertTrue(fixture.focus.applyLyricsCleanup(source, replacing: source))
        XCTAssertFalse(fixture.undo.canUndo)
        XCTAssertFalse(fixture.focus.applyLyricsCleanup(" \n", replacing: source))
        XCTAssertFalse(fixture.undo.canUndo)

        let reviewed = "Verse 1\nWe sing &amp; rejoice\nஅற்புத கிருபை"
        fixture.edit { XCTAssertTrue(fixture.focus.applyLyricsCleanup(reviewed, replacing: source)) }
        XCTAssertEqual(fixture.editor.draft, reviewed,
                       "Applying cannot perform another unreviewed cleanup pass")
    }

    func testDetachedEditorAndOtherWorkspaceStayUntouched() throws {
        let first = try Fixture("First workspace")
        let second = try Fixture("Second workspace")
        defer { first.close(); second.close() }
        first.edit {
            XCTAssertTrue(first.focus.applyLyricsCleanup("Verse 1\nFirst workspace", replacing: "First workspace"))
        }
        XCTAssertEqual(second.editor.draft, "Second workspace")
        XCTAssertFalse(second.undo.canUndo)

        let scroll = try XCTUnwrap(first.view.enclosingScrollView)
        PlainTextEditor.dismantleNSView(scroll, coordinator: first.coordinator)
        XCTAssertFalse(first.focus.applyLyricsCleanup("Late cleanup", replacing: first.editor.draft))
        XCTAssertEqual(first.editor.draft, "Verse 1\nFirst workspace")
    }

    @MainActor
    private final class Fixture {
        var editor = LyricsEditorSession()
        let focus = PlainTextEditorFocusController()
        let window: NSWindow
        var coordinator: PlainTextEditor.Coordinator!
        var view: LyricsTextView!
        var undo: UndoManager { view.undoManager! }

        init(_ source: String) throws {
            editor.beginEditing(text: source, sourceURL: URL(fileURLWithPath: "/tmp/cleanup-fixture.txt"))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
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

        func edit(_ action: () -> Void) {
            undo.beginUndoGrouping()
            action()
            undo.endUndoGrouping()
        }

        func close() {
            view.delegate = nil
            view.textStorage?.delegate = nil
            coordinator.detach(view)
            window.close()
        }
    }
}
