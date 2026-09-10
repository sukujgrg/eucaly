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
        let fontSize = thumbnailFontSize
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

    private var thumbnailFontSize: CGFloat {
        // This is cheaper to calculate once than to join and hash all the lyrics
        // for a shared-cache lookup on every rendered line.
        let lineCount = max(1, slide.lines.count)
        let baseSize = (size.height - 20) / CGFloat(lineCount)
        let calculatedSize = min(16, max(8, baseSize * 0.6))
        return calculatedSize * thumbnailFontScale
    }
}
