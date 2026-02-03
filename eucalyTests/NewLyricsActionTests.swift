import XCTest
@testable import eucaly

final class NewLyricsActionTests: XCTestCase {
    func testNewLyricsClearsPreviewAndResetsSelection() async {
        let result = await MainActor.run { () -> (previewIsNil: Bool, rawLyrics: String, lastLoadedText: String, isEditingLyrics: Bool, selectedFileURLIsNil: Bool, selectedPlaylistEntryIDIsNil: Bool, selectedPlaylistEntryIDsIsEmpty: Bool, sidebarSelectionIsNil: Bool) in
            let flow = PresentationFlowController()

            let line = SlideLine(kind: .verse, languageTag: "", text: "line 1")
            let slide = Slide(
                index: 1,
                lines: [line],
                label: nil,
                videoURL: nil,
                pdfURL: nil,
                pdfPageIndex: nil,
                imageURL: nil,
                captureWindowID: nil
            )

            flow.setPreviewSlides([slide], preferredSelection: slide.id)

            var state = NewLyricsState(
                rawLyrics: "old",
                lastLoadedText: "old",
                isEditingLyrics: false,
                selectedFileURL: URL(fileURLWithPath: "/tmp/example.txt"),
                selectedPlaylistEntryID: UUID(),
                selectedPlaylistEntryIDs: [UUID()],
                sidebarSelection: .library(URL(fileURLWithPath: "/tmp/example.txt"))
            )

            NewLyricsAction.apply(state: &state, flow: flow)

            return (
                previewIsNil: flow.previewDocument == nil,
                rawLyrics: state.rawLyrics,
                lastLoadedText: state.lastLoadedText,
                isEditingLyrics: state.isEditingLyrics,
                selectedFileURLIsNil: state.selectedFileURL == nil,
                selectedPlaylistEntryIDIsNil: state.selectedPlaylistEntryID == nil,
                selectedPlaylistEntryIDsIsEmpty: state.selectedPlaylistEntryIDs.isEmpty,
                sidebarSelectionIsNil: state.sidebarSelection == nil
            )
        }

        XCTAssertTrue(result.previewIsNil)
        XCTAssertEqual(result.rawLyrics, "")
        XCTAssertEqual(result.lastLoadedText, "")
        XCTAssertTrue(result.isEditingLyrics)
        XCTAssertTrue(result.selectedFileURLIsNil)
        XCTAssertTrue(result.selectedPlaylistEntryIDIsNil)
        XCTAssertTrue(result.selectedPlaylistEntryIDsIsEmpty)
        XCTAssertTrue(result.sidebarSelectionIsNil)
    }
}
