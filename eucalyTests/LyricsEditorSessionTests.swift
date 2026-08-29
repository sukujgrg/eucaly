import XCTest
@testable import eucaly

final class LyricsEditorSessionTests: XCTestCase {
    func testNewDraftStartsCleanAndBecomesDirtyAfterEditing() {
        var session = LyricsEditorSession()

        session.beginNew()
        XCTAssertTrue(session.isEditing)
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(session.hasLoadableDraft)
        XCTAssertFalse(session.canSave)
        XCTAssertFalse(session.isPreviewSynchronized)

        session.draft = "#verse\nA lyric"
        XCTAssertTrue(session.isDirty)
        XCTAssertTrue(session.hasLoadableDraft)
        XCTAssertTrue(session.canSave)
        XCTAssertFalse(session.isPreviewSynchronized)

        session.markPreviewed()
        XCTAssertTrue(session.isPreviewSynchronized)

        session.draft += " corrected"
        XCTAssertFalse(session.isPreviewSynchronized)
    }

    func testSavingUpdatesIdentityAndDirtyBaseline() {
        let url = URL(fileURLWithPath: "/tmp/song.txt")
        var session = LyricsEditorSession()
        session.beginNew()
        session.draft = "#verse\nA lyric"

        session.markSaved(to: url)

        XCTAssertEqual(session.sourceURL, url)
        XCTAssertEqual(session.savedText, session.draft)
        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(session.canSave)
    }

    func testExistingFileTracksChangesAgainstLoadedText() {
        let url = URL(fileURLWithPath: "/tmp/song.txt")
        var session = LyricsEditorSession()
        session.beginEditing(text: "Original", sourceURL: url)

        XCTAssertFalse(session.isDirty)
        XCTAssertTrue(session.isPreviewSynchronized)
        session.draft = "Corrected"
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(session.isPreviewSynchronized)
        session.draft = "Original"
        XCTAssertFalse(session.isDirty)
        XCTAssertTrue(session.isPreviewSynchronized)
    }

    func testClearDraftDoesNotForgetFileIdentityOrSavedText() {
        let url = URL(fileURLWithPath: "/tmp/song.txt")
        var session = LyricsEditorSession()
        session.beginEditing(text: "Original", sourceURL: url)

        session.clearDraft()

        XCTAssertEqual(session.sourceURL, url)
        XCTAssertEqual(session.savedText, "Original")
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(session.hasLoadableDraft)
        XCTAssertFalse(session.canSave)
        XCTAssertFalse(session.isPreviewSynchronized)
    }

    func testEndEditingResetsTheWholeEditorSession() {
        let url = URL(fileURLWithPath: "/tmp/song.txt")
        var session = LyricsEditorSession()
        session.beginEditing(text: "Original", sourceURL: url)
        session.draft = "Corrected"

        session.endEditing()

        XCTAssertFalse(session.isEditing)
        XCTAssertFalse(session.isDirty)
        XCTAssertNil(session.sourceURL)
        XCTAssertEqual(session.savedText, "")
        XCTAssertNil(session.previewedText)
        XCTAssertEqual(session.draft, "")
    }
}
