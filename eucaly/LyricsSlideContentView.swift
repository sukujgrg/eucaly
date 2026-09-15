import SwiftUI

/// The same text layout is used by projection and by Preview / Current thumbnails.
struct LyricsSlideContentView: View {
    enum Rendering {
        case projection
        case thumbnail
    }

    let lines: [SlideLine]
    let size: CGSize
    let layout: PresentationLyricsLayout
    let textAlignment: PresentationTextAlignment
    let verticalPosition: PresentationVerticalPosition
    let fontScale: Double
    let paddingScale: Double
    let rendering: Rendering

    var body: some View {
        let metrics = LyricsSlideMetrics(
            lines: lines, size: size, layout: layout,
            paddingScale: paddingScale, rendering: rendering
        )

        Group {
            switch layout {
            case .stacked:
                VStack(alignment: textAlignment.horizontalAlignment, spacing: metrics.spacing) {
                    textBlocks(using: metrics)
                }
            case .columns:
                HStack(alignment: verticalPosition.verticalAlignment, spacing: metrics.spacing) {
                    textBlocks(using: metrics)
                }
            }
        }
        .frame(width: metrics.contentSize.width, height: metrics.contentSize.height, alignment: verticalPosition.frameAlignment)
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func textBlocks(using metrics: LyricsSlideMetrics) -> some View {
        ForEach(metrics.blocks) { block in
            let blockSize = metrics.size(for: block)
            LyricsTextFitLayout(maxHeight: blockSize.height) {
                Text(block.text)
                    .font(block.font(size: metrics.fontSize(for: block, scale: fontScale)))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(textAlignment.textAlignment)
                    .lineLimit(nil)
                    // Preserve the complete text. Operator cards warn when it
                    // cannot fit at the readability threshold; a hard floor
                    // here would silently truncate dense lyrics instead.
                    .minimumScaleFactor(0.01)
            }
            .frame(width: blockSize.width, alignment: textAlignment.frameAlignment)
        }
    }
}

/// Shared geometry for rendering and projection readability checks.
struct LyricsSlideMetrics {
    let blocks: [LyricsTextBlock]
    let contentSize: CGSize
    let spacing: CGFloat
    private let availableSize: CGSize
    private let layout: PresentationLyricsLayout
    private let rendering: LyricsSlideContentView.Rendering
    private let totalWeight: Double

    init(lines: [SlideLine], size: CGSize, layout: PresentationLyricsLayout,
         paddingScale: Double, rendering: LyricsSlideContentView.Rendering) {
        self.layout = layout
        self.rendering = rendering
        blocks = layout.blocks(for: lines)
        totalWeight = blocks.reduce(0) { $0 + $1.relativeFontSize }
        let padding = CGFloat(min(2, max(0, paddingScale)))
        let horizontalInset = (rendering == .projection ? max(40, size.width * 0.1) : 6) * padding
        let verticalInset = (rendering == .projection ? max(32, size.height * 0.08) : 6) * padding
        contentSize = CGSize(
            width: max(0, size.width - horizontalInset * 2),
            height: max(0, size.height - verticalInset * 2)
        )
        let count = CGFloat(max(1, blocks.count))
        let availableSpacing = (layout == .columns ? contentSize.width : contentSize.height) / count
        spacing = min((rendering == .projection ? 28 : 6) * padding, availableSpacing)
        let gaps = spacing * CGFloat(max(0, blocks.count - 1))
        availableSize = CGSize(
            width: layout == .columns ? max(0, contentSize.width - gaps) : contentSize.width,
            height: layout == .stacked ? max(0, contentSize.height - gaps) / count : contentSize.height
        )
    }

    func size(for block: LyricsTextBlock) -> CGSize {
        CGSize(
            width: layout == .columns
                ? availableSize.width * CGFloat(block.relativeFontSize / totalWeight)
                : availableSize.width,
            height: availableSize.height
        )
    }

    func fontSize(for block: LyricsTextBlock, scale: Double) -> CGFloat {
        let blockSize = size(for: block)
        let preferredSize: CGFloat
        switch rendering {
        case .projection:
            preferredSize = min(84, blockSize.height * 0.9)
        case .thumbnail:
            preferredSize = min(16, max(8, blockSize.height * 0.6))
        }
        return preferredSize * scale * block.relativeFontSize
    }
}

extension LyricsTextBlock {
    func font(size: CGFloat) -> Font {
        let font = Font.system(size: size, weight: isMeaning ? .regular : .bold)
        return isMeaning ? font.italic() : font
    }
}

/// Gives Text a height limit without stretching short text to fill that height.
/// SwiftUI measures and fits its own glyphs, including fallback fonts used by
/// multilingual lyrics, so measurement and rendering cannot disagree.
private struct LyricsTextFitLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        return text.sizeThatFits(ProposedViewSize(width: proposal.width, height: maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            proposal: ProposedViewSize(width: proposal.width, height: maxHeight)
        )
    }
}

#Preview("Columns at the top") {
    LyricsSlideContentView(
        lines: LyricsParser.parseDocument("""
        Verse
        Sing with joy
        Lift your voice
        Meaning
        Together we sing
        Transliteration
        Sing with joy
        Lift your voice
        """).slides[0].lines,
        size: CGSize(width: 640, height: 360),
        layout: .columns,
        textAlignment: .center,
        verticalPosition: .top,
        fontScale: 1,
        paddingScale: 1,
        rendering: .thumbnail
    )
    .background(.black)
}

#Preview("Single component at the bottom") {
    LyricsSlideContentView(
        lines: [SlideLine(kind: .verse, languageTag: "", text: "Sing with joy\nLift your voice")],
        size: CGSize(width: 640, height: 360),
        layout: .columns,
        textAlignment: .left,
        verticalPosition: .bottom,
        fontScale: 1,
        paddingScale: 0,
        rendering: .thumbnail
    )
    .background(.black)
}
