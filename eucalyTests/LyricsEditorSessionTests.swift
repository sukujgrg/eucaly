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

    func testUndoingDraftClearDoesNotResynchronizeAClearedPreview() {
        var session = LyricsEditorSession()
        session.beginEditing(text: "Original lyrics", sourceURL: URL(fileURLWithPath: "/tmp/song.txt"))
        XCTAssertTrue(session.isPreviewSynchronized)

        session.clearDraft()
        session.invalidatePreview()
        session.draft = "Original lyrics" // Native Undo restores the draft only.

        XCTAssertFalse(session.isDirty)
        XCTAssertFalse(session.isPreviewSynchronized)
        session.markPreviewed()
        XCTAssertTrue(session.isPreviewSynchronized)
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

    func testOpeningAnExistingFileCleansOnlyTheDraftAndKeepsTheSavedBaseline() {
        var session = LyricsEditorSession()
        let original = "\u{FEFF}Verse\r\nAmazing\u{00AD}\u{00A0}grace"
        session.beginEditing(text: original, sourceURL: URL(fileURLWithPath: "/tmp/song.txt"))
        XCTAssertEqual(session.draft, "Verse\nAmazing grace")
        XCTAssertEqual(session.savedText, original)
        XCTAssertEqual(session.previewedText, original)
        XCTAssertTrue(session.isDirty)
        XCTAssertFalse(session.isPreviewSynchronized)
    }

    func testUndoDocumentIdentityChangesOnlyForANewEditingSession() {
        var session = LyricsEditorSession()
        session.beginNew()
        let firstDocument = session.documentID
        session.draft = "lyrics"
        session.markSaved(to: URL(fileURLWithPath: "/tmp/song.txt"))
        XCTAssertEqual(session.documentID, firstDocument, "Saving must retain the editor's undo history")
        session.clearDraft()
        XCTAssertEqual(session.documentID, firstDocument)
        session.beginEditing(text: "other lyrics", sourceURL: URL(fileURLWithPath: "/tmp/other.txt"))
        XCTAssertNotEqual(session.documentID, firstDocument, "History must never cross document boundaries")
    }
}
