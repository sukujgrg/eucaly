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
        let blocks = layout.blocks(for: lines)
        let contentSize = CGSize(
            width: max(0, size.width - horizontalInset * 2),
            height: max(0, size.height - verticalInset * 2)
        )
        let count = CGFloat(max(1, blocks.count))
        let availableSpacing = (layout == .columns ? contentSize.width : contentSize.height) / count
        let spacing = min((rendering == .projection ? 28 : 6) * paddingMultiplier, availableSpacing)
        let gaps = spacing * CGFloat(max(0, blocks.count - 1))
        let availableSize = CGSize(
            width: layout == .columns ? max(0, contentSize.width - gaps) : contentSize.width,
            height: layout == .stacked ? max(0, contentSize.height - gaps) / count : contentSize.height
        )

        Group {
            switch layout {
            case .stacked:
                VStack(alignment: textAlignment.horizontalAlignment, spacing: spacing) {
                    textBlocks(blocks, in: availableSize)
                }
            case .columns:
                HStack(alignment: verticalPosition.verticalAlignment, spacing: spacing) {
                    textBlocks(blocks, in: availableSize)
                }
            }
        }
        .frame(width: contentSize.width, height: contentSize.height, alignment: verticalPosition.frameAlignment)
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var paddingMultiplier: CGFloat {
        CGFloat(min(2, max(0, paddingScale)))
    }

    private var horizontalInset: CGFloat {
        (rendering == .projection ? max(40, size.width * 0.1) : 6) * paddingMultiplier
    }

    private var verticalInset: CGFloat {
        (rendering == .projection ? max(32, size.height * 0.08) : 6) * paddingMultiplier
    }

    private func textBlocks(_ blocks: [LyricsTextBlock], in availableSize: CGSize) -> some View {
        // Give smaller text a proportionally narrower column. Normalizing over
        // the present blocks also lets a lone Meaning section use the full width.
        let totalWeight = blocks.reduce(0) { $0 + $1.relativeFontSize }
        return ForEach(blocks) { block in
            let blockSize = CGSize(
                width: layout == .columns
                    ? availableSize.width * CGFloat(block.relativeFontSize / totalWeight)
                    : availableSize.width,
                height: availableSize.height
            )
            LyricsTextFitLayout(maxHeight: blockSize.height) {
                Text(block.text)
                    .font(font(for: block, in: blockSize))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(textAlignment.textAlignment)
                    .lineLimit(nil)
                    .minimumScaleFactor(0.01)
            }
            .frame(width: blockSize.width, alignment: textAlignment.frameAlignment)
        }
    }

    private func font(for block: LyricsTextBlock, in blockSize: CGSize) -> Font {
        let preferredSize: CGFloat
        switch rendering {
        case .projection:
            preferredSize = min(84, blockSize.height * 0.9)
        case .thumbnail:
            preferredSize = min(16, max(8, blockSize.height * 0.6))
        }
        let fontSize = preferredSize * fontScale * block.relativeFontSize
        let font = Font.system(size: fontSize, weight: block.isMeaning ? .regular : .bold)
        return block.isMeaning ? font.italic() : font
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
