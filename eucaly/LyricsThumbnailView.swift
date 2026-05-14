import SwiftUI
import AppKit

struct LyricsThumbnailView: View {
    let slide: Slide
    let size: CGSize
    @AppStorage("thumbnailFontScale") private var thumbnailFontScale: Double = 1.0
    @AppStorage("presentationTextAlignment") private var presentationTextAlignment: PresentationTextAlignment = .center
    @AppStorage("presentationVerticalPosition") private var presentationVerticalPosition: PresentationVerticalPosition = .middle

    var body: some View {
        let contentAlignment = presentationVerticalPosition.frameAlignment
        ZStack {
            Color.black

            VStack(alignment: presentationTextAlignment.horizontalAlignment, spacing: 3) {
                ForEach(slide.lines) { line in
                    let isMeaning = line.languageTag.caseInsensitiveCompare("Meaning") == .orderedSame
                    Text(line.text)
                        .font(.system(
                            size: isMeaning ? fontSize * 0.5 : fontSize,
                            weight: isMeaning ? .regular : .bold
                        ))
                        .italic(isMeaning)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(presentationTextAlignment.textAlignment)
                        .lineLimit(nil)
                        .frame(maxWidth: size.width - 12, alignment: presentationTextAlignment.frameAlignment)
                }
            }
            .frame(maxWidth: size.width - 12, alignment: presentationTextAlignment.frameAlignment)
            .frame(maxWidth: size.width, maxHeight: size.height, alignment: contentAlignment)
            .padding(6)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
    }

    private var fontSize: CGFloat {
        // Simple formula: base size on thumbnail height and line count
        let lineCount = max(1, slide.lines.count)

        // Create a simple cache key from slide lines
        let cacheText = slide.lines.map { $0.text }.joined(separator: "\n")

        // Check cache (using dummy weight/italic since this is just sizing)
        if let cached = CacheManager.shared.getCachedFontSize(
            text: cacheText,
            maxWidth: size.width,
            maxHeight: size.height,
            maxSize: 16 * thumbnailFontScale,
            minSize: 8 * thumbnailFontScale,
            weight: .bold,
            italic: false
        ) {
            return cached
        }

        // Calculate if not cached
        let baseSize = (size.height - 20) / CGFloat(lineCount)
        let calculatedSize = min(16, max(8, baseSize * 0.6))
        let finalSize = calculatedSize * thumbnailFontScale

        // Cache the result
        CacheManager.shared.cacheFontSize(
            finalSize,
            text: cacheText,
            maxWidth: size.width,
            maxHeight: size.height,
            maxSize: 16 * thumbnailFontScale,
            minSize: 8 * thumbnailFontScale,
            weight: .bold,
            italic: false
        )

        return finalSize
    }
}
