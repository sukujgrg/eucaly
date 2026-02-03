import SwiftUI

struct PrimaryActionButtonStyle: ViewModifier {
    let fixedWidth: CGFloat?

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .fontWeight(.semibold)
            .frame(width: fixedWidth)
    }
}

extension View {
    func primaryActionStyle(fixedWidth: CGFloat? = nil) -> some View {
        modifier(PrimaryActionButtonStyle(fixedWidth: fixedWidth))
    }
}
