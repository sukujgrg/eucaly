import Foundation

nonisolated struct LyricsEditorSession: Equatable {
    private(set) var documentID = UUID()
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

    var canPreviewDraft: Bool {
        hasLoadableDraft && !isPreviewSynchronized
    }

    mutating func beginNew() {
        documentID = UUID()
        sourceURL = nil
        savedText = ""
        previewedText = nil
        draft = ""
        isEditing = true
    }

    mutating func beginEditing(text: String, sourceURL: URL) {
        documentID = UUID()
        self.sourceURL = sourceURL
        savedText = text
        previewedText = text
        draft = LyricsTextSanitizer.clean(text)
        isEditing = true
    }

    mutating func markSaved(to sourceURL: URL) {
        self.sourceURL = sourceURL
        savedText = draft
    }

    mutating func markPreviewed() {
        previewedText = draft
    }

    mutating func invalidatePreview() {
        previewedText = nil
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
