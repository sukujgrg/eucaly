import XCTest
@testable import eucaly

final class NewLyricsActionTests: XCTestCase {
    func testNewLyricsClearsPreviewAndResetsEditorAndSelection() async {
        await MainActor.run {
            let oldURL = URL(fileURLWithPath: "/tmp/example.txt")
            let oldPlaylistID = UUID()
            let flow = PresentationFlowController()
            let slide = Slide(
                index: 1,
                lines: [SlideLine(kind: .verse, languageTag: "", text: "Old lyrics")],
                label: nil,
                videoURL: nil,
                pdfURL: nil,
                pdfPageIndex: nil,
                imageURL: nil,
                captureWindowID: nil
            )
            flow.setPreviewSlides([slide])

            var editor = LyricsEditorSession()
            editor.beginEditing(text: "Old lyrics", sourceURL: oldURL)
            editor.draft = "Unsaved lyrics"
            var state = NewLyricsState(
                editor: editor,
                selectedPlaylistEntryIDs: [oldPlaylistID],
                sidebarSelection: .playlist(oldPlaylistID)
            )

            NewLyricsAction.apply(state: &state) {
                flow.clearPreviewDocument()
            }

            XCTAssertTrue(flow.previewIsEmpty)
            XCTAssertTrue(state.editor.isEditing)
            XCTAssertFalse(state.editor.isDirty)
            XCTAssertEqual(state.editor.draft, "")
            XCTAssertNil(state.editor.sourceURL)
            XCTAssertTrue(state.selectedPlaylistEntryIDs.isEmpty)
            XCTAssertNil(state.sidebarSelection)
        }
    }
}
