import XCTest
@testable import eucaly

final class LyricsFileSaveTests: XCTestCase {
    func testTwoEditorsDetectConflictAndCancelPreservesTheSecondDraft() throws {
        try withFile { url in
            var first = LyricsEditorSession(), second = LyricsEditorSession()
            first.beginEditing(text: "Original", sourceURL: url)
            second.beginEditing(text: "Original", sourceURL: url)
            first.draft = "First workspace edits"
            second.draft = "Second workspace edits"
            XCTAssertTrue(try LyricsFileSave.save(first.draft, replacing: first.savedText, at: url) {
                XCTFail("An unchanged file should save without a warning")
                return false
            })
            first.markSaved(to: url)

            var asked = false
            let saved = try LyricsFileSave.save(second.draft, replacing: second.savedText, at: url) {
                asked = true
                return false
            }
            if saved { second.markSaved(to: url) }

            XCTAssertTrue(asked)
            XCTAssertFalse(saved)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), first.draft)
            XCTAssertEqual(second.draft, "Second workspace edits")
            XCTAssertEqual(second.savedText, "Original")
            XCTAssertTrue(second.isDirty)
        }
    }

    func testExplicitOverwriteSavesTheSecondEditorsDraft() throws {
        try withFile { url in
            var second = LyricsEditorSession()
            second.beginEditing(text: "Original", sourceURL: url)
            second.draft = "Second workspace edits"
            try "First workspace edits".write(to: url, atomically: true, encoding: .utf8)
            var asked = false

            let saved = try LyricsFileSave.save(second.draft, replacing: second.savedText, at: url) {
                asked = true
                return true
            }
            if saved { second.markSaved(to: url) }

            XCTAssertTrue(asked)
            XCTAssertTrue(saved)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), second.draft)
            XCTAssertFalse(second.isDirty)
        }
    }

    func testDeletedOrUnreadableFileDoesNotSilentlyRecreateOrOverwriteIt() throws {
        try withFile { url in
            try FileManager.default.removeItem(at: url)
            XCTAssertThrowsError(try LyricsFileSave.save("Draft", replacing: "Original", at: url) {
                XCTFail("A read error must be reported without an overwrite prompt")
                return true
            })
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

            try Data([0xFF, 0xFE, 0xFF]).write(to: url)
            XCTAssertThrowsError(try LyricsFileSave.save("Draft", replacing: "Original", at: url) { true })
            XCTAssertEqual(try Data(contentsOf: url), Data([0xFF, 0xFE, 0xFF]))
        }
    }

    func testEditorReplacementDuringOverwriteConfirmationRejectsTheStaleSave() throws {
        try withFile { url in
            var editor = LyricsEditorSession()
            editor.beginEditing(text: "Original", sourceURL: url)
            editor.draft = "Old editor draft"
            let documentID = editor.documentID, draft = editor.draft
            try "Other saved changes".write(to: url, atomically: true, encoding: .utf8)

            let saved = try LyricsFileSave.save(draft, replacing: editor.savedText, at: url,
                isStillCurrent: { editor.documentID == documentID && editor.sourceURL == url && editor.draft == draft }) {
                    editor.beginNew()
                    editor.draft = "New editor draft"
                    return true
                }
            if saved { editor.markSaved(to: url) }

            XCTAssertFalse(saved)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Other saved changes")
            XCTAssertNotEqual(editor.documentID, documentID)
            XCTAssertEqual(editor.draft, "New editor draft")
            XCTAssertNil(editor.sourceURL)
            XCTAssertTrue(editor.isDirty)
        }
    }

    func testCurrentEditorValidationAlsoRunsWhenNoOverwriteConfirmationIsNeeded() throws {
        try withFile { url in
            let saved = try LyricsFileSave.save("Stale draft", replacing: "Original", at: url,
                isStillCurrent: { false }) {
                    XCTFail("An unchanged file needs no overwrite confirmation")
                    return true
                }

            XCTAssertFalse(saved)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Original")
        }
    }

    private func withFile(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-save-conflict-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Song.txt")
        try "Original".write(to: url, atomically: true, encoding: .utf8)
        try body(url)
    }
}
