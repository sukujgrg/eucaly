import Foundation

nonisolated enum AltViewPresentationAdapter {
    static func mode(for slide: Slide) -> AltViewProjectionPresentation.Mode {
        slide.videoURL != nil || slide.pdfURL != nil || slide.imageURL != nil
            || slide.webpageURL != nil || slide.captureWindowID != nil ? .media : .lyrics
    }
    static func content(for snapshot: PresentationOutputSnapshot) -> AltViewDisplayContent {
        guard let slide = snapshot.slide,
              slide.videoURL == nil, slide.pdfURL == nil, slide.imageURL == nil,
              slide.webpageURL == nil, slide.captureWindowID == nil else { return .empty }
        // Reuse the parser's component classification. No companion fallback:
        // meaning, translation and transliteration never become the main lyric.
        let primary = slide.lines.filter {
            LyricsSectionCatalog.parseCompanionHeader($0.languageTag) == nil
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.map(\.text).joined(separator: "\n\n")
        guard !primary.isEmpty else { return .empty }
        return AltViewDisplayContent(body: primary, visible: snapshot.isPresenting && snapshot.slidesVisible)
    }
}
