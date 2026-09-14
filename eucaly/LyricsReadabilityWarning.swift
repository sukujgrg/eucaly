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
    let report: LyricsReadabilityReport

    var body: some View {
        if !report.isEmpty {
            Label("Small projected text", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .help(report.message)
                // The containing card exposes the full explanation as its value.
                .accessibilityHidden(true)
        }
    }
}

struct LyricsReadabilityCheck: View {
    let lines: [SlideLine]
    @Environment(\.lyricsProjectionSize) private var projectionSize
    @AppStorage("presentationLyricsLayout") private var layout: PresentationLyricsLayout = .stacked
    @AppStorage("presentationPaddingScale") private var paddingScale: Double = 1
    @AppStorage("presentationFontScale") private var fontScale: Double = 1

    var body: some View {
        if let projectionSize {
            LyricsReadabilityProbe(
                lines: lines, size: projectionSize, layout: layout,
                paddingScale: paddingScale, fontScale: fontScale
            )
            .hidden()
            .accessibilityHidden(true)
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
                            let needsSpace = geometry.size.height > ceil(availableSize.height)
                                || geometry.size.width > ceil(availableSize.width)
                            let component = block.companion?.rawValue ?? "Lyrics"
                            Color.clear.preference(
                                key: LyricsReadabilityPreferenceKey.self,
                                value: LyricsReadabilityReport(
                                    needsSpace: needsSpace ? [component] : [],
                                    smallFont: preferredSize < Self.minimumFontSize ? [component] : []
                                )
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
    static var defaultValue: LyricsReadabilityReport { .init() }

    static func reduce(value: inout LyricsReadabilityReport, nextValue: () -> LyricsReadabilityReport) {
        let next = nextValue()
        value.needsSpace.formUnion(next.needsSpace)
        value.smallFont.formUnion(next.smallFont)
    }
}

nonisolated struct LyricsReadabilityReport: Equatable {
    var needsSpace: Set<String> = []
    var smallFont: Set<String> = []

    var isEmpty: Bool { needsSpace.isEmpty && smallFont.isEmpty }

    var message: String {
        guard !isEmpty else { return "" }
        let names = needsSpace.union(smallFont).sorted().joined(separator: ", ")
        var messages = ["\(names) may be too small on the projection display."]
        if !needsSpace.isEmpty {
            messages.append("Reduce padding, change layout, or shorten this slide.")
        }
        // Increasing the requested font cannot fix a component that does not
        // fit at the threshold, even when its requested font is also small.
        let adjustableFonts = smallFont.subtracting(needsSpace)
        if !adjustableFonts.isEmpty {
            messages.append("Increase Projection Font Size for \(adjustableFonts.sorted().joined(separator: ", ")).")
        }
        return messages.joined(separator: " ")
    }
}
