import SwiftUI

private struct LyricsProjectionSizeKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

extension EnvironmentValues {
    var lyricsProjectionSize: CGSize? {
        get { self[LyricsProjectionSizeKey.self] }
        set { self[LyricsProjectionSizeKey.self] = newValue }
    }
}

/// An advisory on operator cards, never on the audience display. Measure with
/// SwiftUI at 32 projection points to flag small text before it goes unnoticed.
/// This is an early warning threshold, not a guarantee of legibility in a hall.
struct LyricsReadabilityWarning: View {
    let lines: [SlideLine]
    @Environment(\.lyricsProjectionSize) private var projectionSize
    @AppStorage("presentationLyricsLayout") private var layout: PresentationLyricsLayout = .stacked
    @AppStorage("presentationPaddingScale") private var paddingScale: Double = 1
    @AppStorage("presentationFontScale") private var fontScale: Double = 1

    var body: some View {
        Color.clear
            .frame(width: 16, height: 16)
            .background {
                if let projectionSize {
                    LyricsReadabilityProbe(
                        lines: lines, size: projectionSize, layout: layout,
                        paddingScale: paddingScale, fontScale: fontScale
                    )
                    .hidden()
                    .accessibilityHidden(true)
                }
            }
            .overlayPreferenceValue(LyricsReadabilityPreferenceKey.self) { components in
                if !components.isEmpty {
                    let names = components.sorted().joined(separator: ", ")
                    let message = "\(names) may be too small on the projection display. Adjust font size, reduce padding, change layout, or shorten this slide."
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .help(message)
                        .accessibilityLabel(message)
                }
            }
    }
}

struct LyricsReadabilityProbe: View {
    static let minimumFontSize: CGFloat = 32
    let lines: [SlideLine]
    let size: CGSize
    let layout: PresentationLyricsLayout
    let paddingScale: Double
    let fontScale: Double

    var body: some View {
        let metrics = LyricsSlideMetrics(
            lines: lines, size: size, layout: layout,
            paddingScale: paddingScale, rendering: .projection
        )
        ZStack {
            ForEach(metrics.blocks) { block in
                let availableSize = metrics.size(for: block)
                let preferredSize = metrics.fontSize(for: block, scale: fontScale)
                Text(block.text)
                    .font(block.font(size: Self.minimumFontSize))
                    .lineLimit(nil)
                    .minimumScaleFactor(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .background {
                        GeometryReader { geometry in
                            // Text rounds its measured size to whole points;
                            // fractional column widths must not create warnings.
                            let tooSmall = preferredSize < Self.minimumFontSize
                                || geometry.size.height > ceil(availableSize.height)
                                || geometry.size.width > ceil(availableSize.width)
                            Color.clear.preference(
                                key: LyricsReadabilityPreferenceKey.self,
                                value: tooSmall ? [block.companion?.rawValue ?? "Lyrics"] : []
                            )
                        }
                    }
                    .frame(width: availableSize.width)
            }
        }
        .frame(width: 0, height: 0)
    }
}

nonisolated struct LyricsReadabilityPreferenceKey: PreferenceKey {
    static var defaultValue: Set<String> { [] }

    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) {
        value.formUnion(nextValue())
    }
}
