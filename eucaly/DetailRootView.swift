import SwiftUI

struct DetailRootView<EditorPane: View, PreviewPane: View, CurrentPane: View>: View {
    let editorPane: EditorPane
    let previewPane: PreviewPane
    let currentPane: CurrentPane
    let showEditorAndPreview: Bool

    var body: some View {
        VStack(spacing: 12) {
            if showEditorAndPreview {
                HStack(alignment: .top, spacing: 12) {
                    editorPane
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    previewPane
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            } else {
                previewPane
            }

            currentPane
        }
        .padding(20)
        .frame(minWidth: 520)
        .background(
            VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                .ignoresSafeArea()
        )
    }
}
