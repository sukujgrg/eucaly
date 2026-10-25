import SwiftUI
import Foundation
import AVFoundation

enum DetailFocusTarget: Hashable {
    case currentThumbnails
}

struct CurrentPaneContainerView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var session: PresentationSession
    @ObservedObject var playbackProgress: PlaybackProgressStore
    @ObservedObject var flow: PresentationFlowController
    let thumbnailScale: Double
    let canEditCurrentLyrics: Bool
    let onEditCurrentLyrics: () -> Void
    let onClearCurrent: (() -> Void)?
    @FocusState.Binding var focusedDetailTarget: DetailFocusTarget?
    @State private var videoSeekDraft: Double = 0
    @State private var isSeekingVideo: Bool = false

    var body: some View {
        let slides = session.slides
        let isCollapsed = flow.isCurrentCollapsed
        let allowsPDFThumbnailRendering: Bool = {
            if let pdfSource = session.pdfSlideSource {
                return PDFSlideCatalog.shouldRenderThumbnails(pageCount: pdfSource.pageCount)
            }
            return PDFSlideCatalog.shouldRenderThumbnails(for: slides)
        }()
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                let statusText: String = {
                    if session.isPresenting {
                        if !session.areSlidesVisible { return "(Slides hidden)" }
                        return session.outputCoordinator.currentMatchesAcceptedProgram(workspace: session.outputSourceID)
                            ? "(Presenting)" : "(Current is not live)"
                    }
                    return session.isEmpty ? "(Not presenting)" : "(Loaded)"
                }()

                if session.isPresenting || !session.isEmpty {
                    Button(action: toggleCollapsed) {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 11, weight: .semibold))
                                .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                            Text("Current")
                                .font(.headline)
                                .fontWeight(.semibold)

                            Text(statusText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 6)
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isCollapsed ? "Expand Current" : "Collapse Current")
                    .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text("Current")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                if !session.isEmpty {
                    HStack(spacing: 6) {
                        Button("Edit", action: onEditCurrentLyrics)
                            .paneHeaderActionStyle()
                            .disabled(!canEditCurrentLyrics)
                            .help("Edit Current lyrics in Preview")

                        Button("Clear", role: .destructive, action: clearSlides)
                            .paneHeaderActionStyle()
                            .help("Clear Current area")
                    }
                }

                if session.isPresenting || !session.isEmpty {
                    Rectangle()
                        .fill(.clear)
                        .frame(height: 28)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture(perform: toggleCollapsed)
                } else {
                    Spacer()
                }
            }
            .padding(.horizontal, 4)

            if !isCollapsed {
                if session.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No document loaded")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Select a slide in Preview, then click Load to Current")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                    .transition(.opacity)
                } else {
                    GeometryReader { proxy in
                        let horizontalInset: CGFloat = 10
                        let layout = ThumbnailGridLayout.make(
                            for: proxy.size.width - (horizontalInset * 2),
                            thumbnailScale: thumbnailScale
                        )
                        ScrollViewReader { scrollProxy in
                            ScrollView {
                                LazyVGrid(columns: layout.columns, spacing: layout.spacing) {
                                    if let pdfSource = session.pdfSlideSource {
                                        ForEach(0..<pdfSource.pageCount, id: \.self) { pageIndex in
                                            let slide = PDFSlideCatalog.slide(url: pdfSource.url, pageIndex: pageIndex)
                                            SlideGridCellView(
                                                slide: slide,
                                                itemWidth: layout.itemWidth,
                                                itemHeight: layout.itemHeight,
                                                isSelected: slide.id == session.currentSlideID,
                                                allowsPDFThumbnailRendering: allowsPDFThumbnailRendering,
                                                onTap: {
                                                    focusCurrentThumbnails()
                                                    flow.selectCurrentSlide(slide.id, in: session)
                                                }
                                            )
                                            .id(slide.id)
                                        }
                                    } else {
                                        ForEach(slides) { slide in
                                            SlideGridCellView(
                                                slide: slide,
                                                itemWidth: layout.itemWidth,
                                                itemHeight: layout.itemHeight,
                                                isSelected: slide.id == session.currentSlideID,
                                                allowsPDFThumbnailRendering: allowsPDFThumbnailRendering,
                                                onTap: {
                                                    focusCurrentThumbnails()
                                                    flow.selectCurrentSlide(slide.id, in: session)
                                                }
                                            )
                                            .id(slide.id)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, horizontalInset)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .focusable()
                            .focused($focusedDetailTarget, equals: .currentThumbnails)
                            .focusEffectDisabled()
                            .onKeyPress(.upArrow) {
                                return handleArrowKey(
                                    direction: .previousRow,
                                    layout: layout
                                )
                            }
                            .onKeyPress(.downArrow) {
                                return handleArrowKey(
                                    direction: .nextRow,
                                    layout: layout
                                )
                            }
                            .onKeyPress(.leftArrow) {
                                return handleArrowKey(
                                    direction: .previousItem,
                                    layout: layout
                                )
                            }
                            .onKeyPress(.rightArrow) {
                                return handleArrowKey(
                                    direction: .nextItem,
                                    layout: layout
                                )
                            }
                            .onTapGesture {
                                focusCurrentThumbnails()
                            }
                            .onAppear {
                                session.setCurrentThumbnailColumnCount(layout.columnCount)
                            }
                            .onChange(of: layout.columnCount) { _, columnCount in
                                session.setCurrentThumbnailColumnCount(columnCount)
                            }
                            .onChange(of: session.currentSlideID) { _, newValue in
                                scrollToSelectedSlide(newValue, with: scrollProxy)
                            }
                        }
                    }
                    .excludingInterfaceAnimation(.disclosure)
                    .transition(.opacity)
                }

                if session.currentSlide?.videoURL != nil {
                    videoControls
                        .excludingInterfaceAnimation(.disclosure)
                        .transition(.opacity)
                }
            }
        }
        .padding(10)
        .frame(
            maxWidth: .infinity,
            maxHeight: isCollapsed ? nil : .infinity,
            alignment: .top
        )
        .background(
            VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .paneAccentRing(.current, isEmphasized: !session.isEmpty && !isCollapsed)
        .onChange(of: playbackProgress.videoCurrentTime, initial: true) { _, newValue in
            guard !isSeekingVideo else { return }
            videoSeekDraft = newValue
        }
        .onChange(of: session.currentSlide?.videoURL) { _, _ in
            videoSeekDraft = playbackProgress.videoCurrentTime
            isSeekingVideo = false
        }
        .task(id: session.currentSlide?.videoURL) {
            await loadCurrentVideoDuration(from: session.currentSlide?.videoURL)
        }
    }

    private var videoControls: some View {
        HStack(spacing: 8) {
            Button {
                session.toggleVideoPlayback()
            } label: {
                Label(
                    session.videoPlaybackActionTitle,
                    systemImage: playbackProgress.videoPlaybackState == .ended ? "arrow.counterclockwise"
                        : session.videoPaused ? "play.fill" : "pause.fill"
                )
            }
            .disabled(playbackProgress.videoPlaybackState.failure != nil)
            .help(playbackProgress.videoPlaybackState.failure ?? session.videoPlaybackActionTitle)

            Button {
                session.videoMuted.toggle()
            } label: {
                Label(
                    session.videoMuted ? "Unmute" : "Mute",
                    systemImage: session.videoMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
                )
            }
            .help("Mute or unmute video audio on every output, including NDI and local monitoring. For local listening through the default macOS audio output, use Output → Listen on This Mac.")

            Toggle(isOn: $session.videoLoop) {
                Label("Loop", systemImage: session.videoLoop ? "repeat.1" : "repeat")
            }
            .toggleStyle(.button)
            .accessibilityLabel("Video Loop")
            .accessibilityValue(session.videoLoop ? "On" : "Off")

            Text(playbackProgress.videoPlaybackState.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Video playback")
                .accessibilityValue(playbackProgress.videoPlaybackState.title)

            Text(formattedVideoTime(videoSeekDraft))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { videoSeekDraft },
                    set: { newValue in
                        videoSeekDraft = newValue
                        if playbackProgress.videoDuration > 0 {
                            session.seekVideo(to: newValue)
                        }
                    }
                ),
                in: 0...max(playbackProgress.videoDuration, 0.01),
                onEditingChanged: { isEditing in
                    isSeekingVideo = isEditing
                }
            )
            .disabled(playbackProgress.videoDuration <= 0)
            .accessibilityLabel("Video position")
            .accessibilityValue(formattedVideoTime(videoSeekDraft))

            Text(formattedVideoTime(playbackProgress.videoDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 4)
    }

    private func toggleCollapsed() {
        InterfaceMotion.disclosure.animate(reduceMotion: reduceMotion) {
            flow.isCurrentCollapsed.toggle()
        }
        if flow.isCurrentCollapsed {
            focusedDetailTarget = nil
        }
    }

    private func clearSlides() {
        if let onClearCurrent {
            focusedDetailTarget = nil
            onClearCurrent()
            return
        }
        flow.clearCurrentDocument(in: session)
        flow.isCurrentCollapsed = true
        focusedDetailTarget = nil
    }

    private func focusCurrentThumbnails() {
        guard !flow.isCurrentCollapsed, !session.isEmpty else { return }
        focusedDetailTarget = .currentThumbnails
    }

    private func handleArrowKey(
        direction: ThumbnailGridNavigationDirection,
        layout: ThumbnailGridLayout
    ) -> KeyPress.Result {
        // No check for isPresenting - allow control during presentation too
        // This provides an alternative way to navigate when PresentationWindow loses focus
        guard !session.isEmpty else { return .ignored }
        session.setCurrentThumbnailColumnCount(layout.columnCount)
        session.moveSelection(direction: direction)
        return .handled
    }

    private func scrollToSelectedSlide(_ slideID: Slide.ID?, with proxy: ScrollViewProxy) {
        guard let slideID else { return }
        InterfaceMotion.selectionScroll.animate(reduceMotion: reduceMotion) {
            proxy.scrollTo(slideID)
        }
    }

    private func formattedVideoTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    private func loadCurrentVideoDuration(from url: URL?) async {
        guard let url else { return }
        let asset = AVURLAsset(url: url)

        do {
            let duration = try await asset.load(.duration)
            let seconds = duration.seconds
            guard
                !Task.isCancelled,
                session.currentSlide?.videoURL == url,
                seconds.isFinite,
                seconds > 0
            else {
                return
            }

            session.updateVideoPlaybackProgress(
                currentTime: playbackProgress.videoCurrentTime,
                duration: seconds
            )
        } catch {
            return
        }
    }
}
