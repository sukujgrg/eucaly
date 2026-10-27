import SwiftUI

struct LyricsThumbnailView: View {
    @Environment(\.audienceOutputProfile) private var audienceProfile
    let slide: Slide
    let size: CGSize
    @AppStorage("thumbnailFontScale") private var thumbnailFontScale: Double = 1.0

    var body: some View {
        let profile = audienceProfile ?? OutputProfile.builtIns[0]
        ZStack {
            Color.black

            LyricsSlideContentView(
                lines: slide.lines,
                size: size,
                layout: PresentationLyricsLayout(rawValue: profile.layout) ?? .stacked,
                textAlignment: PresentationTextAlignment(rawValue: profile.alignment) ?? .center,
                verticalPosition: PresentationVerticalPosition(rawValue: profile.position) ?? .middle,
                fontScale: thumbnailFontScale,
                paddingScale: profile.padding,
                rendering: .thumbnail,
                profile: profile
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
