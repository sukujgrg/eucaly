import SwiftUI

enum EditorPaneAction: Equatable {
    case close
    case save
    case format
    case cleanUp
    case clear
    case previewDraft
}

struct EditorPaneContainerView: View {
    let newFileWarning: String?
    @ObservedObject var editor: LyricsEditorSession
    let saveButtonTitle: String
    let focusController: PlainTextEditorFocusController
    let onAction: (EditorPaneAction) -> Void
    /// Forces Save / Preview enablement to refresh on draft keystrokes without
    /// publishing through ContentView. Draft itself is intentionally unpublished.
    @State private var draftRenderToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let newFileWarning {
                Text(newFileWarning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
            }

            PlainTextEditor(
                text: draftBinding,
                focusController: focusController
            )
                .id(editor.documentID)
                .frame(minHeight: 220)
                .background(
                    VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                )

            footer

        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        )
        .onAppear { draftRenderToken = 0 }
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { editor.draft },
            set: { newValue in
                editor.draft = newValue
                draftRenderToken &+= 1
            }
        )
    }

    private var hasUsableText: Bool {
        _ = draftRenderToken
        return !editor.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSave: Bool {
        _ = draftRenderToken
        return editor.canSave
    }

    private var canPreviewDraft: Bool {
        _ = draftRenderToken
        return editor.canPreviewDraft
    }

    private var isDraftEmpty: Bool {
        _ = draftRenderToken
        return editor.draft.isEmpty
    }

    private var title: some View {
        Text("Lyrics Input")
            .font(.headline)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                title
                Spacer(minLength: 12)
                textTools
                closeButton
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    title
                    Spacer(minLength: 12)
                    closeButton
                }
                textTools
            }
            VStack(alignment: .leading, spacing: 8) {
                title
                textTools
                HStack { Spacer(minLength: 0); closeButton }
            }
        }
    }

    private var textTools: some View {
        Menu("Text Tools") {
            Button("Normalize Formatting") { onAction(.format) }
                .disabled(!hasUsableText)
                .help("Normalize headings and spacing, removing redundant empty lines below headings while preserving slide boundaries. Undo restores the previous text.")
                .accessibilityIdentifier("LyricsEditor.Format")
            Divider()
            Button("Clear Draft", role: .destructive) {
                onAction(.clear)
                // Clear may mutate draft outside draftBinding; refresh enablement locally.
                draftRenderToken &+= 1
            }
                .disabled(isDraftEmpty)
                .help("Empty the lyrics draft and Preview. Undo restores the draft.")
                .accessibilityIdentifier("LyricsEditor.Clear")
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: true, vertical: false)
        .help("Formatting and draft-clearing actions.")
        .accessibilityIdentifier("LyricsEditor.Tools")
    }

    private var closeButton: some View {
        Button("Close Editor") { onAction(.close) }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .help("Close the lyrics editor. You can save or discard unsaved changes.")
            .accessibilityIdentifier("LyricsEditor.Close")
    }

    private var cleanupButton: some View {
        Button("Clean Up Lyrics…") { onAction(.cleanUp) }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!hasUsableText)
            .help("Review cleanup suggestions before applying them to this draft, including normalized section spacing. Saving and updating Preview are separate.")
            .accessibilityIdentifier("LyricsEditor.CleanUp")
    }

    private var previewButton: some View {
        Button("Preview Draft") { onAction(.previewDraft) }
            .buttonStyle(.bordered)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!canPreviewDraft)
            .help("Update Preview using these lyrics without changing their text or saving the file.")
            .accessibilityIdentifier("LyricsEditor.Preview")
    }

    private var saveButton: some View {
        Button(saveButtonTitle) { onAction(.save) }
            .primaryActionStyle()
            .fixedSize(horizontal: true, vertical: false)
            .disabled(!canSave)
            .help("Save these lyrics to a text file and update Preview.")
            .accessibilityIdentifier("LyricsEditor.Save")
    }

    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                cleanupButton
                Spacer(minLength: 12)
                previewButton
                saveButton
            }
            VStack(alignment: .leading, spacing: 10) {
                cleanupButton
                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    previewButton
                    saveButton
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                cleanupButton
                HStack { Spacer(minLength: 0); previewButton }
                HStack { Spacer(minLength: 0); saveButton }
            }
        }
    }
}
