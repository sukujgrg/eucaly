import Foundation

/// Local content capabilities belong to eucaly, independently of any transport.
nonisolated enum OutputContentClassifier {
    enum Mode { case lyrics, media }
    static func mode(for slide: Slide) -> Mode {
        slide.videoURL != nil || slide.pdfURL != nil || slide.imageURL != nil
            || slide.captureWindowID != nil ? .media : .lyrics
    }
    static func supportsNDI(_ slide: Slide) -> Bool {
        supportsNetworkOutput(slide)
    }
    static func supportsNetworkOutput(_ slide: Slide) -> Bool {
        slide.captureWindowID == nil
    }
}
