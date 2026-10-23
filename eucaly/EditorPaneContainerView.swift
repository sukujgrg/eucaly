import SwiftUI

enum EditorPaneAction {
    case close
    case save
    case format
    case cleanUp
    case clear
}

struct EditorPaneContainerView: View {
    let newFileWarning: String?
    @Binding var rawLyrics: String
    let editorID: UUID
    let saveButtonTitle: String
    let canSave: Bool
    let focusController: PlainTextEditorFocusController
    let onAction: (EditorPaneAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lyrics Input")
                .font(.headline)
                .foregroundStyle(.primary)

            if let newFileWarning {
                Text(newFileWarning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
            }

            PlainTextEditor(
                text: $rawLyrics,
                focusController: focusController
            )
                .id(editorID)
                .frame(minHeight: 220)
                .background(
                    VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    cleanupActions
                    documentActions
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack { cleanupActions; Spacer(minLength: 0) }
                    HStack { documentActions; Spacer(minLength: 0) }
                }
            }

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
    }

    private var cleanupActions: some View {
        HStack(spacing: 10) {
            Button("Clean Up Lyrics…") { onAction(.cleanUp) }
                .primaryActionStyle()
                .disabled(rawLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Review character cleanup and natural lyric casing from local rules, plus sections and line-break repairs, before applying.")
            Button("Format") { onAction(.format) }
                .buttonStyle(.bordered)
        }
        .fixedSize()
    }

    private var documentActions: some View {
        HStack(spacing: 10) {
            Button(saveButtonTitle) { onAction(.save) }
                .buttonStyle(.bordered)
                .disabled(!canSave)
            Button("Clear") { onAction(.clear) }
                .buttonStyle(.bordered)
            Button("Close") { onAction(.close) }
                .buttonStyle(.bordered)
        }
        .fixedSize()
    }

}
