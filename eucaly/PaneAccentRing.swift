import SwiftUI

enum PaneAccentRingStyle {
    case preview
    case current

    var color: Color {
        switch self {
        case .preview:
            return Color(nsColor: .systemOrange)
        case .current:
            return Color(nsColor: .systemGreen)
        }
    }
}

private struct PaneAccentRingModifier: ViewModifier {
    let style: PaneAccentRingStyle
    let isEmphasized: Bool

    func body(content: Content) -> some View {
        content.overlay {
            let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
            shape
                .strokeBorder(.separator, lineWidth: 1)
                .overlay {
                    shape.strokeBorder(
                        style.color.opacity(isEmphasized ? 0.42 : 0.2),
                        lineWidth: isEmphasized ? 1.5 : 1
                    )
                }
                .allowsHitTesting(false)
        }
    }
}

extension View {
    func paneAccentRing(
        _ style: PaneAccentRingStyle,
        isEmphasized: Bool
    ) -> some View {
        modifier(PaneAccentRingModifier(style: style, isEmphasized: isEmphasized))
    }
}
