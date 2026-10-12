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
        if coordinator.visible {
            if profile.kind == .confidence {
                OutputConfidenceView(coordinator: coordinator, profile: profile, size: size)
            } else if let slide = coordinator.liveSlide, let session = coordinator.localSession,
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

private struct OutputWebpageCompanionView: View {
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

/// Reserve chrome before fitting Current/Next so native media cannot expand
/// the stack or push another pane outside the destination frame.
struct OutputConfidenceGeometry {
    let width: CGFloat
    let padding: CGFloat
    let spacing: CGFloat
    let fontSize: CGFloat
    let headingHeight: CGFloat
    let currentHeight: CGFloat
    let nextHeight: CGFloat
    init(size: CGSize, hasNext: Bool, hasPlayback: Bool) {
        padding = min(32, max(0, min(size.width, size.height) * 0.05))
        width = max(0, size.width - padding * 2)
        spacing = min(12, max(0, size.height * 0.02))
        fontSize = min(24, max(1, size.height * 0.04))
        headingHeight = fontSize * 1.4
        let sectionCount = 2 + (hasNext ? 1 : 0) + (hasPlayback ? 1 : 0)
        let labelCount = hasNext ? 2 : 1
        let chrome = headingHeight * CGFloat(1 + (hasPlayback ? 1 : 0))
            + CGFloat(labelCount) * (headingHeight + spacing / 3)
            + CGFloat(sectionCount - 1) * spacing
        let available = max(0, size.height - padding * 2 - chrome)
        currentHeight = available * (hasNext ? 0.72 : 1)
        nextHeight = hasNext ? available * 0.28 : 0
    }
}

private struct OutputConfidenceView: View {
    @ObservedObject var coordinator: OutputCoordinator
    let profile: OutputProfile
    let size: CGSize
    var body: some View {
        let next = coordinator.nextText.flatMap { profile.components(in: $0).isEmpty ? nil : $0 }
        let slide = coordinator.liveSlide.flatMap { AltViewPresentationAdapter.mode(for: $0) == .media ? $0 : nil }
        let geometry = OutputConfidenceGeometry(size: size, hasNext: next != nil, hasPlayback: slide?.videoURL != nil)
        VStack(alignment: .leading, spacing: geometry.spacing) {
            Text(coordinator.sourceName)
                .font(profile.typography.font(at: geometry.fontSize)).foregroundStyle(profile.typography.colour.color)
                .lineLimit(1).frame(height: geometry.headingHeight)
            VStack(alignment: .leading, spacing: geometry.spacing / 3) {
                heading("Current", label: slide?.title ?? coordinator.text.label, geometry: geometry)
                if let slide, let session = coordinator.localSession {
                    if slide.webpageURL != nil {
                        OutputWebpageCompanionView()
                            .frame(width: geometry.width, height: geometry.currentHeight)
                    } else {
                        OutputMediaSlideView(slide: slide, session: session, runtime: coordinator.media,
                                             showsBackground: profile.background.whenMediaShown)
                            .frame(width: geometry.width, height: geometry.currentHeight).clipped().id(slide.id)
                    }
                } else {
                    text(coordinator.text, height: geometry.currentHeight, geometry: geometry)
                }
            }
            if let next {
                VStack(alignment: .leading, spacing: geometry.spacing / 3) {
                    heading("Next", label: next.label, geometry: geometry)
                    text(next, height: geometry.nextHeight, geometry: geometry)
                }
            }
            if let session = coordinator.localSession, slide?.videoURL != nil {
                OutputPlaybackStatus(session: session, progress: session.playbackProgress,
                                     typography: profile.typography(for: .footer), fontSize: geometry.fontSize)
                    .frame(height: geometry.headingHeight)
            }
        }.padding(geometry.padding).frame(width: size.width, height: size.height, alignment: .topLeading)
    }
    private func heading(_ title: String, label: String?, geometry: OutputConfidenceGeometry) -> some View {
        Text(title + (label.map { " · \($0)" } ?? ""))
            .font(profile.typography.font(at: geometry.fontSize)).foregroundStyle(profile.typography.colour.color)
            .lineLimit(1).frame(height: geometry.headingHeight)
    }
    private func text(_ content: OutputTextContent, height: CGFloat, geometry: OutputConfidenceGeometry) -> some View {
        var labeled = content
        labeled.components = profile.components(in: content).map { component in
            var next = component
            next.text = "\(component.label ?? component.role.rawValue.capitalized)\n\(component.text)"
            return next
        }
        return OutputTextView(content: labeled, profile: profile, size: CGSize(width: geometry.width, height: height))
    }
}

private struct OutputPlaybackStatus: View {
    @ObservedObject var session: PresentationSession
    @ObservedObject var progress: PlaybackProgressStore
    let typography: OutputTypography
    let fontSize: CGFloat
    var body: some View {
        Text("\(session.videoPaused ? "Paused" : "Playing") · \(Int(progress.videoCurrentTime)) / \(Int(progress.videoDuration)) seconds").font(typography.font(at: min(fontSize, typography.size))).foregroundStyle(typography.colour.color)
    }
}
