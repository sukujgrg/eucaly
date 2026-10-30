import SwiftUI
import AVFoundation

/// Composition is a native layer boundary. Every layer receives identical full-screen geometry.
struct OutputCompositionView: View {
    @ObservedObject var coordinator: OutputCoordinator
    let destinationID: UUID
    var body: some View {
        GeometryReader { geometry in
            if let profile = coordinator.profile(for: destinationID) {
                let size = geometry.size
                let snapshot = coordinator.snapshot(for: destinationID)
                let confidence = OutputConfidenceContent(snapshot: snapshot, profile: profile)
                ZStack {
                    profile.background.colour.color.frame(width: size.width, height: size.height)
                    OutputBackgroundView(profile: profile, url: coordinator.media(for: destinationID)?.backgroundURL(for: profile),
                                         player: coordinator.media(for: destinationID)?.backgroundPlayer(for: profile), visible: snapshot.visible,
                                         isMedia: snapshot.localMedia.map { OutputContentClassifier.mode(for: $0) == .media } ?? false)
                        .frame(width: size.width, height: size.height)
                    content(profile: profile, snapshot: snapshot, confidence: confidence, size: size).frame(width: size.width, height: size.height)
                }.frame(width: size.width, height: size.height).clipped()
            }
        }.ignoresSafeArea()
    }
    @ViewBuilder private func content(profile: OutputProfile, snapshot: OutputContentSnapshot,
                                      confidence: OutputConfidenceContent, size: CGSize) -> some View {
        if profile.kind == .confidence {
            // Idle (empty/hidden) wins over retained localMedia so Hide restores the clock.
            if let slide = confidence.media, !confidence.isIdle,
               let session = coordinator.session(for: destinationID) {
                media(slide, snapshot: snapshot, profile: profile, session: session, size: size)
            } else {
                OutputConfidenceView(profile: profile, content: confidence, size: size)
            }
        } else if snapshot.visible {
            if let slide = snapshot.localMedia, let session = coordinator.session(for: destinationID),
                      OutputContentClassifier.mode(for: slide) == .media {
                media(slide, snapshot: snapshot, profile: profile, session: session, size: size)
            } else {
                OutputTextView(content: snapshot.current, profile: profile, size: size)
            }
        }
    }
    /// Media uses the whole output canvas in every profile. Confidence's text
    /// columns and playback status must not reduce the native playback frame.
    private func media(_ slide: Slide, snapshot: OutputContentSnapshot, profile: OutputProfile,
                       session: PresentationSession, size: CGSize) -> some View {
        // Native PDFKit retains its parsed document across pages of one accepted
        // source. Explicit reloads and workspace transfers bring a new source ID.
        let identity = slide.pdfURL != nil ? snapshot.acceptedPDF?.id ?? slide.id : slide.id
        return OutputMediaSlideView(slide: slide, snapshot: snapshot, session: session,
                             runtime: coordinator.program(session.outputSourceID).media,
                             showsBackground: profile.background.whenMediaShown).id(identity)
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .bottomLeading) {
                if profile.kind == .confidence && slide.videoURL != nil {
                    OutputConfidencePlaybackStatus(progress: session.playbackProgress,
                                                   typography: profile.typography(for: .footer), size: size)
                }
            }.clipped()
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
    let snapshot: OutputContentSnapshot
    @ObservedObject var session: PresentationSession
    let runtime: OutputMediaRuntime
    var showsBackground = false
    var body: some View {
        ZStack {
            if !showsBackground { Color.black }
            if let windowID = slide.captureWindowID { WindowCaptureSlideView(windowID: windowID, showsOperatorMessages: false) }
            else if slide.videoURL != nil { AVPlayerViewRepresentable(player: runtime.program, isMuted: session.videoMuted, isFill: session.videoFill) }
            else if slide.pdfURL != nil, let page = slide.pdfPageIndex {
                PDFSlideView(source: snapshot.acceptedPDF, pageIndex: page)
            }
            else if let url = slide.imageURL {
                ImageSlideView(url: url, backgroundColour: showsBackground ? .clear : .black,
                               contentIdentity: ProjectionImageContentIdentity(snapshot: snapshot))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
