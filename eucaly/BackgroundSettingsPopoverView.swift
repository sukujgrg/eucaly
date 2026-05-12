import SwiftUI

struct BackgroundSettingsPopoverView: View {
    @ObservedObject var session: PresentationSession
    let visualName: String?
    let isMediaCurrent: Bool
    let onChooseVisual: () -> Void
    let onClearVisual: () -> Void
    let onToggleVisibility: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Background")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        onChooseVisual()
                    } label: {
                        Label("Set Visual", systemImage: "photo.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        onClearVisual()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.backgroundVisualURL == nil)
                }

                if let visualName {
                    Text(visualName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No visual selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button {
                onToggleVisibility()
            } label: {
                Label(
                    session.isBackgroundVisualVisible ? "Hide Background" : "Show Background",
                    systemImage: session.isBackgroundVisualVisible ? "photo.fill.on.rectangle.fill" : "photo.on.rectangle"
                )
            }
            .buttonStyle(.bordered)
            .disabled(!session.hasAvailableBackgroundVisual || isMediaCurrent)

            Text("Applies to lyrics only")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 320, alignment: .leading)
    }
}
