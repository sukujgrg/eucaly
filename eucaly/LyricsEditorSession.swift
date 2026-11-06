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
/// the editor; draft mutations do not publish on every keystroke. Admission-relevant
/// transitions bump `previewAdmissionGeneration` so Preview Load chrome stays honest
/// without restoring ContentView thrash on each character.
@MainActor
final class LyricsEditorSession: ObservableObject {
    @Published private(set) var documentID = UUID()
    @Published private(set) var sourceURL: URL?
    @Published private(set) var isEditing = false
    /// Observability for Load-to-Current / Preview Draft enablement only.
    /// Increments when sync or loadable emptiness changes — not on every keystroke.
    @Published private(set) var previewAdmissionGeneration: UInt64 = 0

    private(set) var savedText = ""
    private(set) var previewedText: String?
    var draft = "" {
        didSet { notePreviewAdmissionChange(from: oldValue) }
    }

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
        let before = admissionSnapshot(for: draft)
        previewedText = draft
        publishAdmissionChange(from: before)
    }

    func invalidatePreview() {
        let before = admissionSnapshot(for: draft)
        previewedText = nil
        publishAdmissionChange(from: before)
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

    private struct AdmissionSnapshot: Equatable {
        var loadable: Bool
        var synchronized: Bool
    }

    private func admissionSnapshot(for text: String) -> AdmissionSnapshot {
        let loadable = isEditing && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return AdmissionSnapshot(loadable: loadable, synchronized: loadable && previewedText == text)
    }

    private func notePreviewAdmissionChange(from oldDraft: String) {
        publishAdmissionChange(from: admissionSnapshot(for: oldDraft))
    }

    private func publishAdmissionChange(from before: AdmissionSnapshot) {
        let after = admissionSnapshot(for: draft)
        guard before != after else { return }
        previewAdmissionGeneration &+= 1
    }
}
