import SwiftUI

private struct ToolbarSettingsMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
    }
}
extension View {
    func toolbarSettingsMenuStyle() -> some View {
        modifier(ToolbarSettingsMenuStyle())
    }
}
