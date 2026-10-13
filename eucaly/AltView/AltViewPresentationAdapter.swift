import Foundation

nonisolated enum AltViewPresentationAdapter {
    static func mode(for slide: Slide) -> AltViewProjectionPresentation.Mode {
        slide.videoURL != nil || slide.pdfURL != nil || slide.imageURL != nil
            || slide.webpageURL != nil || slide.captureWindowID != nil ? .media : .lyrics
    }
}
