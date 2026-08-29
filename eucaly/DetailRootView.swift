import SwiftUI

struct DetailRootView<EditorPane: View, PreviewPane: View, CurrentPane: View>: View {
    let editorPane: EditorPane
    let previewPane: PreviewPane
    let currentPane: CurrentPane
    let hasEditorPane: Bool
    let isEditorPreviewAreaCollapsed: Bool

    var body: some View {
        VStack(spacing: 12) {
            if hasEditorPane {
                HStack(
                    alignment: .top,
                    spacing: isEditorPreviewAreaCollapsed ? 0 : 12
                ) {
                    editorPane
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .frame(
                            width: isEditorPreviewAreaCollapsed ? 0 : nil,
                            height: isEditorPreviewAreaCollapsed ? 0 : nil,
                            alignment: .topLeading
                        )
                        .clipped()
                        .opacity(isEditorPreviewAreaCollapsed ? 0 : 1)
                        .allowsHitTesting(!isEditorPreviewAreaCollapsed)
                        .accessibilityHidden(isEditorPreviewAreaCollapsed)

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
