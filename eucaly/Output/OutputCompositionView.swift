import SwiftUI
import AVFoundation

/// Composition is a native layer boundary. Every layer receives identical full
/// screen geometry. A future frame adapter can provide GPU-backed offscreen output.
struct OutputCompositionView: View {
    @ObservedObject var coordinator: OutputCoordinator
    let destinationID: UUID
    var body: some View {
        GeometryReader { geometry in
            if let profile = coordinator.profile(for: destinationID) {
                let size = geometry.size
                let confidence = OutputConfidenceContent(snapshot: coordinator.snapshot(for: destinationID), profile: profile)
                ZStack {
                    profile.background.colour.color.frame(width: size.width, height: size.height)
                    OutputBackgroundView(profile: profile, url: coordinator.media(for: destinationID)?.backgroundURL(for: profile),
                                         player: coordinator.media(for: destinationID)?.backgroundPlayer(for: profile), visible: coordinator.snapshot(for: destinationID).visible,
                                         isMedia: coordinator.snapshot(for: destinationID).localMedia.map { OutputContentClassifier.mode(for: $0) == .media } ?? false)
                        .frame(width: size.width, height: size.height)
                    content(profile: profile, confidence: confidence, size: size).frame(width: size.width, height: size.height)
                }.frame(width: size.width, height: size.height).clipped()
            }
        }.ignoresSafeArea()
    }
    @ViewBuilder private func content(profile: OutputProfile, confidence: OutputConfidenceContent, size: CGSize) -> some View {
        if profile.kind == .confidence {
            if confidence.isIdle {
                OutputConfidenceIdleClock(size: size)
            } else if let slide = confidence.media, let session = coordinator.session(for: destinationID) {
                media(slide, profile: profile, session: session, size: size)
            } else {
                OutputConfidenceView(profile: profile, content: confidence, size: size)
            }
        } else if coordinator.snapshot(for: destinationID).visible {
            if let slide = coordinator.snapshot(for: destinationID).localMedia, let session = coordinator.session(for: destinationID),
                      OutputContentClassifier.mode(for: slide) == .media {
                media(slide, profile: profile, session: session, size: size)
            } else {
                OutputTextView(content: coordinator.snapshot(for: destinationID).current, profile: profile, size: size)
            }
        }
    }
    /// Media uses the whole output canvas in every profile. Confidence's text
    /// columns and playback status must not reduce the native playback frame.
    private func media(_ slide: Slide, profile: OutputProfile, session: PresentationSession, size: CGSize) -> some View {
        Group {
            if slide.webpageURL != nil && profile.kind != .audience {
                OutputWebpageCompanionView()
            } else {
                OutputMediaSlideView(slide: slide, session: session, runtime: coordinator.program(session.outputSourceID).media,
                                     showsBackground: profile.background.whenMediaShown).id(slide.id)
            }
        }.frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomLeading) {
                if profile.kind == .confidence && slide.videoURL != nil {
                    OutputConfidencePlaybackStatus(session: session, progress: session.playbackProgress,
                                                   typography: profile.typography(for: .footer), size: size)
                }
            }.clipped()
    }
}

struct OutputWebpageCompanionView: View {
    var body: some View {
        ContentUnavailableView("Webpage on Audience", systemImage: "globe", description: Text("Live webpages play on the Audience output."))
    }
}

struct OutputBackgroundView: View {
    let profile: OutputProfile
    // Resolved resources are rendering inputs. The runtime is stable while an
    // asynchronous resolution changes these values, even for an unchanged profile.
    let url: URL?
    let player: AVPlayer?
    let visible: Bool
    let isMedia: Bool
    var body: some View {
        let background = profile.background
        let show = background.visible && (!visible ? background.whenHidden : isMedia ? background.whenMediaShown : background.whenTextShown)
        Group {
            if let url {
                if OutputMediaRuntime.isVideo(url) {
                    AVPlayerViewRepresentable(player: player, isMuted: true, isFill: background.fit == "fill")
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
