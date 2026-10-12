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
                ZStack {
                    profile.background.colour.color.frame(width: size.width, height: size.height)
                    OutputBackgroundView(profile: profile, media: coordinator.media, visible: coordinator.visible,
                                         isMedia: coordinator.liveSlide.map { AltViewPresentationAdapter.mode(for: $0) == .media } ?? false)
                        .frame(width: size.width, height: size.height)
                    content(profile: profile, size: size).frame(width: size.width, height: size.height)
                    if profile.includesOverlay, let session = coordinator.overlaySession {
                        TimeOverlay().environmentObject(session).padding(26).frame(width: size.width, height: size.height)
                    }
                }.frame(width: size.width, height: size.height).clipped()
            }
        }.ignoresSafeArea()
    }
    @ViewBuilder private func content(profile: OutputProfile, size: CGSize) -> some View {
        if profile.kind == .confidence {
            OutputConfidenceView(coordinator: coordinator, profile: profile, size: size)
        } else if coordinator.visible {
            if profile.kind == .audience, let slide = coordinator.liveSlide, let session = coordinator.localSession,
               AltViewPresentationAdapter.mode(for: slide) == .media {
                OutputMediaSlideView(slide: slide, session: session, runtime: coordinator.media, showsBackground: profile.background.whenMediaShown).id(slide.id)
            } else {
                OutputTextView(content: coordinator.text, profile: profile, size: size)
            }
        }
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

private struct OutputConfidenceView: View {
    @ObservedObject var coordinator: OutputCoordinator
    let profile: OutputProfile
    let size: CGSize
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(coordinator.sourceName)
                Spacer()
                if !coordinator.visible { Text("Hidden").fontWeight(.bold) }
            }.font(profile.typography.font(at: 24)).foregroundStyle(profile.typography.colour.color)
            labeled(coordinator.text, heading: "Current", height: size.height * 0.52)
            if let next = coordinator.nextText { labeled(next, heading: "Next", height: size.height * 0.25) }
            if let slide = coordinator.liveSlide, AltViewPresentationAdapter.mode(for: slide) == .media {
                Text("\(slide.title) · \(slide.videoURL != nil ? "Video" : slide.pdfURL != nil ? "PDF" : slide.webpageURL != nil ? "Webpage" : slide.captureWindowID != nil ? "Captured window" : "Image")")
                    .font(profile.typography.font(at: 24)).foregroundStyle(profile.typography.colour.color)
                if let session = coordinator.localSession, slide.videoURL != nil {
                    OutputPlaybackStatus(progress: session.playbackProgress, paused: session.videoPaused, typography: profile.typography(for: .footer))
                }
            }
            Spacer(minLength: 0)
        }.padding(32).frame(width: size.width, height: size.height)
    }
    private func labeled(_ content: OutputTextContent, heading: String, height: CGFloat) -> some View {
        var labeled = content
        labeled.components = profile.components(in: content).map { component in
            var next = component
            next.text = "\(component.label ?? component.role.rawValue.capitalized)\n\(component.text)"
            return next
        }
        return VStack(alignment: .leading, spacing: 4) {
            Text(heading + (content.label.map { " · \($0)" } ?? "")).font(profile.typography.font(at: 24)).foregroundStyle(profile.typography.colour.color)
            OutputTextView(content: labeled, profile: profile, size: CGSize(width: max(0, size.width - 64), height: height))
        }
    }
}

private struct OutputPlaybackStatus: View {
    @ObservedObject var progress: PlaybackProgressStore
    let paused: Bool
    let typography: OutputTypography
    var body: some View {
        Text("\(paused ? "Paused" : "Playing") · \(Int(progress.videoCurrentTime)) / \(Int(progress.videoDuration)) seconds").font(typography.font(at: min(24, typography.size))).foregroundStyle(typography.colour.color)
    }
}
