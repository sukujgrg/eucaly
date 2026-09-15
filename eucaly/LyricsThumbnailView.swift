import SwiftUI

struct LyricsThumbnailView: View {
    let slide: Slide
    let size: CGSize
    @AppStorage("thumbnailFontScale") private var thumbnailFontScale: Double = 1.0
    @AppStorage("presentationLyricsLayout") private var presentationLyricsLayout: PresentationLyricsLayout = .stacked
    @AppStorage("presentationPaddingScale") private var presentationPaddingScale: Double = 1.0
    @AppStorage("presentationTextAlignment") private var presentationTextAlignment: PresentationTextAlignment = .center
    @AppStorage("presentationVerticalPosition") private var presentationVerticalPosition: PresentationVerticalPosition = .middle

    var body: some View {
        ZStack {
            Color.black

            LyricsSlideContentView(
                lines: slide.lines,
                size: size,
                layout: presentationLyricsLayout,
                textAlignment: presentationTextAlignment,
                verticalPosition: presentationVerticalPosition,
                fontScale: thumbnailFontScale,
                paddingScale: presentationPaddingScale,
                rendering: .thumbnail
            )
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 6, x: 0, y: 2)
    }
}
