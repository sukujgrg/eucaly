import SwiftUI

/// Operator-only warnings. Read the same native font and geometry as projection.
struct OutputReadabilityProbe: View {
    let content: OutputTextContent
    let profile: OutputProfile
    let size: CGSize
    var body: some View {
        let metrics = OutputTextMetrics(content: content, profile: profile, size: size)
        ZStack {
            ForEach(metrics.components) { component in
                let box = metrics.size(for: component)
                let typography = profile.typography(for: component.role)
                Text(component.text).font(typography.font(at: 32))
                    .lineSpacing(typography.lineSpacing)
                    .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: LyricsReadabilityPreferenceKey.self, value: .init(
                                needsSpace: geometry.size.width > ceil(box.width) || geometry.size.height > ceil(box.height) ? [component.role.rawValue.capitalized] : [],
                                smallFont: metrics.requestedSize(for: component) < 32 ? [component.role.rawValue.capitalized] : []))
                        }
                    }.frame(width: box.width)
            }
        }.frame(width: 0, height: 0).hidden().accessibilityHidden(true)
    }
}
