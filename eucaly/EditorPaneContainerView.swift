import SwiftUI

enum EditorPaneAction {
    case close
    case save
    case format
    case clear
}

struct EditorPaneContainerView: View {
    let newFileWarning: String?
    @Binding var rawLyrics: String
    let saveButtonTitle: String
    let canSave: Bool
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

            PlainTextEditor(text: $rawLyrics)
                .frame(minHeight: 220)
                .background(
                    VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                )

            HStack(spacing: 10) {
                Button("Format") {
                    onAction(.format)
                }
                .primaryActionStyle()

                Button(saveButtonTitle) {
                    onAction(.save)
                }
                .buttonStyle(.bordered)
                .disabled(!canSave)

                Menu {
                    Button("Clear") {
                        onAction(.clear)
                    }
                    Divider()
                    Button("Close") {
                        onAction(.close)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .buttonStyle(.bordered)

                Spacer()
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
}
