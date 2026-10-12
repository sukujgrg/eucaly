import SwiftUI

/// Composition is a native layer boundary. Every layer receives identical full
/// screen geometry. A future frame adapter can provide GPU-backed offscreen output.
struct OutputCompositionView: View {
    @ObservedObject var coordinator: OutputCoordinator
    let destinationID: UUID
    var body: some View {
        GeometryReader { geometry in
            if let profile = coordinator.profile(for: destinationID) {
                let size = geometry.size
                let confidence = OutputConfidenceContent(snapshot: coordinator.snapshot, profile: profile)
                ZStack {
                    profile.background.colour.color.frame(width: size.width, height: size.height)
                    OutputBackgroundView(profile: profile, media: coordinator.media, visible: coordinator.visible,
                                         isMedia: coordinator.liveSlide.map { AltViewPresentationAdapter.mode(for: $0) == .media } ?? false)
                        .frame(width: size.width, height: size.height)
                    content(profile: profile, confidence: confidence, size: size).frame(width: size.width, height: size.height)
                    if profile.includesOverlay, let session = coordinator.overlaySession,
                       !(profile.kind == .confidence && confidence.isIdle && session.overlayMode == .clock) {
                        TimeOverlay().environmentObject(session).padding(26).frame(width: size.width, height: size.height)
                    }
                }.frame(width: size.width, height: size.height).clipped()
            }
        }.ignoresSafeArea()
    }
    @ViewBuilder private func content(profile: OutputProfile, confidence: OutputConfidenceContent, size: CGSize) -> some View {
        if profile.kind == .confidence {
            if confidence.isIdle {
                OutputConfidenceIdleClock(size: size)
            } else {
                OutputConfidenceView(coordinator: coordinator, profile: profile, content: confidence, size: size)
            }
        } else if coordinator.visible {
            if let slide = coordinator.liveSlide, let session = coordinator.localSession,
                      AltViewPresentationAdapter.mode(for: slide) == .media {
                if slide.webpageURL != nil && profile.kind != .audience {
                    OutputWebpageCompanionView()
                } else {
                    OutputMediaSlideView(slide: slide, session: session, runtime: coordinator.media, showsBackground: profile.background.whenMediaShown).id(slide.id)
                }
            } else {
                OutputTextView(content: coordinator.text, profile: profile, size: size)
            }
        }
    }
}

struct OutputWebpageCompanionView: View {
    var body: some View {
        ContentUnavailableView("Webpage on Audience", systemImage: "globe", description: Text("Live webpages play on the Audience output."))
    }
}

struct OutputBackgroundView: View {
    let profile: OutputProfile
    let media: OutputMediaRuntime
    let visible: Bool
    let isMedia: Bool
    var body: some View {
        let background = profile.background
        let show = background.visible && (!visible ? background.whenHidden : isMedia ? background.whenMediaShown : background.whenTextShown)
        Group {
            if let url = media.backgroundURL(for: profile) {
                if OutputMediaRuntime.isVideo(url) {
                    AVPlayerViewRepresentable(player: media.backgroundPlayer(for: profile), isMuted: true, isFill: background.fit == "fill")
                } else {
                    ImageSlideView(url: url, backgroundColour: profile.background.colour.color, contentMode: background.fit == "fill" ? .fill : .fit, showsLoadingIndicator: false, retainsPreviousImageWhileLoading: true)
                }
            }
        }.overlay(Color.black.opacity(background.dimming)).opacity(show ? 1 : 0).clipped().allowsHitTesting(false)
    }
}

struct OutputMediaSlideView: View {
    let slide: Slide
    @ObservedObject var session: PresentationSession
    let runtime: OutputMediaRuntime
    var showsBackground = false
    var body: some View {
        ZStack {
            if !showsBackground { Color.black }
            if let windowID = slide.captureWindowID { WindowCaptureSlideView(windowID: windowID) }
            else if slide.videoURL != nil { AVPlayerViewRepresentable(player: runtime.program, isMuted: session.videoMuted, isFill: session.videoFill) }
            else if let url = slide.pdfURL, let page = slide.pdfPageIndex { PDFSlideView(url: url, pageIndex: page) }
            else if let url = slide.webpageURL { WebpageSlideView(url: url, navigationRevision: slide.webpageNavigationRevision, isMuted: session.webpageMuted) }
            else if let url = slide.imageURL { ImageSlideView(url: url, backgroundColour: showsBackground ? .clear : .black) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
