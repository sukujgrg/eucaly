import Foundation

struct LyricsEditorSession: Equatable {
    private(set) var sourceURL: URL?
    private(set) var savedText = ""
    private(set) var previewedText: String?
    private(set) var isEditing = false
    var draft = ""

    var isDirty: Bool {
        isEditing && draft != savedText
    }

    var hasLoadableDraft: Bool {
        isEditing && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSave: Bool {
        hasLoadableDraft && (sourceURL == nil || isDirty)
    }

    var isPreviewSynchronized: Bool {
        hasLoadableDraft && previewedText == draft
    }

    mutating func beginNew() {
        sourceURL = nil
        savedText = ""
        previewedText = nil
        draft = ""
        isEditing = true
    }

    mutating func beginEditing(text: String, sourceURL: URL) {
        self.sourceURL = sourceURL
        savedText = text
        previewedText = text
        draft = text
        isEditing = true
    }

    mutating func markSaved(to sourceURL: URL) {
        self.sourceURL = sourceURL
        savedText = draft
    }

    mutating func markPreviewed() {
        previewedText = draft
    }

    mutating func clearDraft() {
        draft = ""
    }

    mutating func endEditing() {
        sourceURL = nil
        savedText = ""
        previewedText = nil
        draft = ""
        isEditing = false
    }
}
