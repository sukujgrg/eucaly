import SwiftUI

struct ThumbnailGridLayout {
    let columns: [GridItem]
    let columnCount: Int
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
        return ThumbnailGridLayout(
            columns: columns,
            columnCount: columnCount,
            itemWidth: itemWidth,
            itemHeight: itemHeight,
            spacing: spacing
        )
    }

    func selectionTargetIndex(
        from currentIndex: Int,
        itemCount: Int,
        direction: ThumbnailGridNavigationDirection
    ) -> Int {
        guard itemCount > 0 else { return currentIndex }
        let currentIndex = min(max(0, currentIndex), itemCount - 1)

        switch direction {
        case .previousItem:
            return max(0, currentIndex - 1)
        case .nextItem:
            return min(itemCount - 1, currentIndex + 1)
        case .previousRow:
            guard currentIndex >= columnCount else { return currentIndex }
            return currentIndex - columnCount
        case .nextRow:
            let targetIndex = currentIndex + columnCount
            if targetIndex < itemCount {
                return targetIndex
            }

            let nextRowStartIndex = ((currentIndex / columnCount) + 1) * columnCount
            guard nextRowStartIndex < itemCount else { return currentIndex }
            return itemCount - 1
        }
    }

    private static func gridItemHeight(for itemWidth: CGFloat) -> CGFloat {
        let previewAspect: CGFloat = 9.0 / 16.0
        let mediaHeight = itemWidth * previewAspect
        return max(130, mediaHeight + 44)
    }
}

enum ThumbnailGridNavigationDirection {
    case previousItem
    case nextItem
    case previousRow
    case nextRow
}
