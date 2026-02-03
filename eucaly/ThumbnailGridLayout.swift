import SwiftUI

struct ThumbnailGridLayout {
    let columns: [GridItem]
    let itemWidth: CGFloat
    let itemHeight: CGFloat
    let spacing: CGFloat

    static func make(for availableWidth: CGFloat, thumbnailScale: Double) -> ThumbnailGridLayout {
        let spacing: CGFloat = 12
        let effectiveWidth = max(120, availableWidth)
        let targetCardWidth = max(120, 220 * CGFloat(thumbnailScale))
        let columnCount = max(1, Int((effectiveWidth + spacing) / (targetCardWidth + spacing)))
        let totalSpacing = spacing * CGFloat(max(0, columnCount - 1))
        let itemWidth = max(120, (effectiveWidth - totalSpacing) / CGFloat(columnCount))
        let itemHeight = gridItemHeight(for: itemWidth)
        let columns = Array(repeating: GridItem(.fixed(itemWidth), spacing: spacing), count: columnCount)
        return ThumbnailGridLayout(columns: columns, itemWidth: itemWidth, itemHeight: itemHeight, spacing: spacing)
    }

    private static func gridItemHeight(for itemWidth: CGFloat) -> CGFloat {
        let previewAspect: CGFloat = 9.0 / 16.0
        let mediaHeight = itemWidth * previewAspect
        return max(130, mediaHeight + 44)
    }
}
