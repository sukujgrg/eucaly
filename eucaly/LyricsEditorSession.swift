import Foundation
import Combine

/// Fingerprint of editor intent for import auto-select cancellation.
/// Draft typing must cancel follow-up selection without relying on reference identity.
nonisolated struct LyricsEditorImportFingerprint: Equatable, Sendable {
    let documentID: UUID
    let isEditing: Bool
    let sourceURL: URL?
    let draft: String
}

/// Owns lyrics draft text. Lifecycle fields publish so the workspace can show/hide
/// the editor; draft mutations do not publish, so typing stays local to the pane.
@MainActor
final class LyricsEditorSession: ObservableObject {
    @Published private(set) var documentID = UUID()
    @Published private(set) var sourceURL: URL?
    @Published private(set) var isEditing = false

    private(set) var savedText = ""
    private(set) var previewedText: String?
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

    var importFingerprint: LyricsEditorImportFingerprint {
        LyricsEditorImportFingerprint(
            documentID: documentID,
            isEditing: isEditing,
            sourceURL: sourceURL,
            draft: draft
        )
    }

    func beginNew() {
        documentID = UUID()
        sourceURL = nil
        savedText = ""
        previewedText = nil
        draft = ""
        isEditing = true
    }

    func beginEditing(text: String, sourceURL: URL) {
        documentID = UUID()
        self.sourceURL = sourceURL
        savedText = text
        previewedText = text
        draft = LyricsTextSanitizer.clean(text)
        isEditing = true
    }

    func markSaved(to sourceURL: URL) {
        self.sourceURL = sourceURL
        savedText = draft
    }

    func markPreviewed() {
        previewedText = draft
    }

    func invalidatePreview() {
        previewedText = nil
    }

    func clearDraft() {
        draft = ""
    }

    func endEditing() {
        sourceURL = nil
        savedText = ""
        previewedText = nil
        draft = ""
        isEditing = false
    }
}
