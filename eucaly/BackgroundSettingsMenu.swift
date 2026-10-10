import SwiftUI

struct BackgroundSettingsMenu: View {
    @ObservedObject var session: PresentationSession
    let visualName: String?
    let isMediaCurrent: Bool
    let onChooseVisual: () -> Void
    let onClearVisual: () -> Void
    let onToggleVisibility: () -> Void

    var body: some View {
        Menu {
            Section("Background") {
                Text(visualName ?? "No visual selected").font(.caption)
                Text("Applies to lyrics only").font(.caption)

                Divider()
                Button("Set Visual…", action: onChooseVisual)
                Button("Clear Visual", action: onClearVisual)
                    .disabled(session.backgroundVisualURL == nil)
            }

            Divider()

            Button(session.isBackgroundVisualVisible ? "Hide Background" : "Show Background",
                   action: onToggleVisibility)
                .disabled(!session.hasAvailableBackgroundVisual || isMediaCurrent)
        } label: {
            Label("Background", systemImage: "photo.on.rectangle")
        }
        .toolbarSettingsMenuStyle()
        .help("Background settings")
    }
}
