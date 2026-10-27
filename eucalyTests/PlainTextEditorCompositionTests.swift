import AppKit
import Combine
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class PlainTextEditorCompositionTests: XCTestCase {
    func testHostedBindingRefreshPreservesCompositionAndLaterCommitsNormally() async throws {
        let fixture = HostedEditorFixture(text: "Verse\nUnsaved lyrics")
        defer { fixture.close() }
        try await activateNativeSearchTestWindow(fixture.window)
        await refresh(fixture)
        let editor = try fixture.editor()
        XCTAssertTrue(fixture.window.makeFirstResponder(editor))
        let undo = try XCTUnwrap(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.setSelectedRange(.init(location: editor.string.utf16.count, length: 0))
        editor.insertText("!", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        let committed = fixture.draft.text
        XCTAssertEqual(committed, "Verse\nUnsaved lyrics!")
        XCTAssertTrue(undo.canUndo)

        // Begin composition before the committed edit's pending SwiftUI update
        // renders. Its binding legitimately lacks the input method's marked text.
        undo.beginUndoGrouping()
        editor.setMarkedText("കൃപ", selectedRange: .init(location: 1, length: 0),
                             replacementRange: .init(location: 6, length: 7))
        undo.endUndoGrouping()
        XCTAssertTrue(editor.hasMarkedText())
        let composing = editor.string, marked = editor.markedRange(), selected = editor.selectedRange()
        XCTAssertNotEqual(composing, fixture.draft.text)
        await refresh(fixture)
        XCTAssertTrue(try fixture.editor() === editor)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        XCTAssertEqual(editor.string, composing)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.selectedRange(), selected)
        XCTAssertEqual(fixture.draft.text, committed)
        XCTAssertTrue(undo.canUndo, "A passive body update must not clear this document's editing history")

        // A later unrelated refresh must preserve the same ongoing composition.
        await refresh(fixture)
        XCTAssertEqual(editor.string, composing)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.selectedRange(), selected)
        undo.beginUndoGrouping()
        editor.insertText("കൃപ", replacementRange: .init(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        undo.endUndoGrouping()
        XCTAssertFalse(editor.hasMarkedText())
        XCTAssertEqual(fixture.draft.text, editor.string)
        XCTAssertEqual(editor.string, composing)
        await refresh(fixture)
        XCTAssertEqual(editor.string, composing)
        XCTAssertFalse(editor.hasMarkedText())
    }

    func testNewHostedDocumentReplacesCompositionAndRetiresItsUndoHistory() async throws {
        let fixture = HostedEditorFixture(text: "First document")
        defer { fixture.close() }
        try await activateNativeSearchTestWindow(fixture.window)
        await refresh(fixture)
        let first = try fixture.editor()
        XCTAssertTrue(fixture.window.makeFirstResponder(first))
        let undo = try XCTUnwrap(first.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        first.insertText("edited ", replacementRange: .init(location: 0, length: 0))
        undo.endUndoGrouping()
        undo.beginUndoGrouping()
        first.setMarkedText("കൃപ", selectedRange: .init(location: 1, length: 0),
                            replacementRange: .init(location: 7, length: 5))
        undo.endUndoGrouping()
        XCTAssertTrue(first.hasMarkedText())
        XCTAssertTrue(undo.canUndo)
        // EditorPaneContainerView changes this identity for New/Edit Lyrics.
        fixture.draft.documentID = UUID()
        fixture.draft.text = "Second document"
        await refresh(fixture)
        let second = try fixture.editor()
        XCTAssertFalse(first === second)
        XCTAssertEqual(second.string, "Second document")
        XCTAssertEqual(fixture.draft.text, "Second document")
        XCTAssertFalse(second.hasMarkedText())
        XCTAssertFalse(undo.canUndo)
        XCTAssertFalse(second.undoManager?.canUndo ?? true)
    }

    func testHostedExternalReplacementWithoutCompositionStillUpdatesTheDocument() async throws {
        let fixture = HostedEditorFixture(text: "Original lyrics")
        defer { fixture.close() }
        try await activateNativeSearchTestWindow(fixture.window)
        await refresh(fixture)
        let editor = try fixture.editor()
        let undo = try XCTUnwrap(editor.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        editor.insertText("edited ", replacementRange: .init(location: 0, length: 0))
        undo.endUndoGrouping()
        XCTAssertTrue(undo.canUndo)
        fixture.draft.text = "External replacement"
        await refresh(fixture)
        XCTAssertTrue(try fixture.editor() === editor)
        XCTAssertEqual(editor.string, "External replacement")
        XCTAssertFalse(undo.canUndo)
    }

    private func refresh(_ fixture: HostedEditorFixture) async {
        let rendered = expectation(description: "Hosted SwiftUI update completed")
        let revision = fixture.draft.revision + 1
        fixture.probe.onUpdate = { [weak probe = fixture.probe] observed in
            guard observed == revision else { return }
            probe?.onUpdate = nil
            rendered.fulfill()
        }
        fixture.draft.revision = revision
        fixture.host.view.layoutSubtreeIfNeeded()
        await fulfillment(of: [rendered], timeout: 4)
    }

    @MainActor
    private final class HostedEditorFixture {
        let draft: HostedDraft
        let focus = PlainTextEditorFocusController()
        let probe = RenderProbe()
        let window: NSWindow
        let host: NSHostingController<HostedEditorRoot>

        init(text: String) {
            draft = HostedDraft(text: text)
            host = NSHostingController(rootView: HostedEditorRoot(draft: draft, focus: focus, probe: probe))
            window = NSWindow(contentRect: .init(x: 60, y: 60, width: 640, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.animationBehavior = .none
            window.contentViewController = host
        }

        func editor() throws -> LyricsTextView {
            func find(_ view: NSView) -> LyricsTextView? {
                if let editor = view as? LyricsTextView { return editor }
                return view.subviews.lazy.compactMap(find).first
            }
            return try XCTUnwrap(find(host.view))
        }

        func close() {
            probe.onUpdate = nil
            window.contentViewController = nil
            window.close()
        }
    }

    @MainActor
    private final class HostedDraft: ObservableObject {
        @Published var text: String
        @Published var documentID = UUID()
        @Published var revision = 0
        init(text: String) { self.text = text }
    }

    @MainActor
    private final class RenderProbe {
        var onUpdate: ((Int) -> Void)?
    }

    @MainActor
    private struct HostedEditorRoot: View {
        @ObservedObject var draft: HostedDraft
        let focus: PlainTextEditorFocusController
        let probe: RenderProbe
        var body: some View {
            VStack {
                PlainTextEditor(text: $draft.text, focusController: focus).id(draft.documentID)
                RenderBoundary(revision: draft.revision, probe: probe).frame(height: 0)
            }
        }
    }

    @MainActor
    private struct RenderBoundary: NSViewRepresentable {
        let revision: Int
        let probe: RenderProbe
        func makeNSView(context: Context) -> NSView { NSView() }
        func updateNSView(_ view: NSView, context: Context) {
            // Complete only after this render transaction returns to AppKit.
            let revision = revision, probe = probe
            DispatchQueue.main.async { probe.onUpdate?(revision) }
        }
    }
}
