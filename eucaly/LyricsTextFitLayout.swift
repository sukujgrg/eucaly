import SwiftUI

/// Gives Text a height limit without stretching short text to fill that height.
/// SwiftUI measures and fits its own glyphs, including fallback fonts used by
/// multilingual lyrics, so measurement and rendering cannot disagree.
struct LyricsTextFitLayout: Layout {
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

