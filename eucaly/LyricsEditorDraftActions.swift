import Foundation

/// Synchronous commands that edit the draft or refresh Preview without saving
/// files or touching Current.
@MainActor
enum LyricsEditorDraftActions {
    nonisolated enum Failure: LocalizedError, Equatable {
        case uncommittedText
        case noSlides

        var errorDescription: String? {
            switch self {
            case .uncommittedText:
                return "Finish composing the current text before continuing."
            case .noSlides:
                return "These lyrics do not contain a slide to preview."
            }
        }
    }

    /// A disabled command is a no-op. A successful command can also leave text
    /// unchanged; the native editor avoids creating an extra Undo action then.
    @discardableResult
    static func normalizeFormatting(
        editor: LyricsEditorSession,
        focus: PlainTextEditorFocusController
    ) throws -> Bool {
        guard editor.hasLoadableDraft else { return false }
        guard focus.committedLyrics() == editor.draft else { throw Failure.uncommittedText }
        return focus.formatLyrics()
    }

    /// Parses exactly the committed draft. Preview is replaced only after the
    /// complete document is valid, retaining the selected slide where possible.
    @discardableResult
    static func updatePreview(
        editor: inout LyricsEditorSession,
        focus: PlainTextEditorFocusController,
        flow: PresentationFlowController
    ) throws -> Bool {
        guard editor.hasLoadableDraft else { return false }
        guard let text = focus.committedLyrics(), text == editor.draft else {
            throw Failure.uncommittedText
        }
        let document = LyricsParser.parseDocument(text, fileName: editor.sourceURL?.lastPathComponent)
        guard !document.slides.isEmpty else { throw Failure.noSlides }

        let selectionIndex = flow.previewSelectionID.flatMap { flow.previewSlideIndex(for: $0) }
        let source = editor.sourceURL.map(PresentationFlowController.PreviewSource.file) ?? .lyrics
        flow.setPreviewSource(source)
        flow.setPreviewSlides(document.slides, preferredSelectionIndex: selectionIndex)
        editor.markPreviewed()
        return true
    }
}
