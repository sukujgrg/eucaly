import SwiftUI

struct PrimaryActionButtonStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .fontWeight(.semibold)
    }
}

struct PaneHeaderActionButtonStyle: ViewModifier {
    let isPrimary: Bool

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
        .controlSize(.regular)
    }
}

extension View {
    func primaryActionStyle() -> some View {
        modifier(PrimaryActionButtonStyle())
    }

    func paneHeaderActionStyle(primary: Bool = false) -> some View {
        modifier(PaneHeaderActionButtonStyle(isPrimary: primary))
    }
}
