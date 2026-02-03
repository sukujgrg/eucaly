import SwiftUI

struct SidebarActionButtonStyle: ViewModifier {
    let isPrimary: Bool
    let minWidth: CGFloat?

    func body(content: Content) -> some View {
        Group {
            if isPrimary {
                content
                    .buttonStyle(.borderedProminent)
                    .fontWeight(.semibold)
            } else {
                content
                    .buttonStyle(.bordered)
                    .fontWeight(.regular)
            }
        }
        .controlSize(.small)
        .font(.subheadline)
        .frame(minWidth: minWidth)
    }
}

extension View {
    func sidebarActionStyle(primary: Bool = false, minWidth: CGFloat? = nil) -> some View {
        modifier(SidebarActionButtonStyle(isPrimary: primary, minWidth: minWidth))
    }
}
