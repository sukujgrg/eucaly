import SwiftUI
import Foundation
import AVFoundation

struct CurrentPaneContainerView: View {
    @ObservedObject var session: PresentationSession
    @ObservedObject var flow: PresentationFlowController
    let thumbnailScale: Double
    let paneToggleAnimation: Animation
    let loadAnimation: Animation
    let titleForWebpage: (URL) -> String
    let onWebpageNavigationChange: (URL, URL) -> Void
    let onWebpageTitleChange: (String, URL) -> Void
    let canEditCurrentLyrics: Bool
    let onEditCurrentLyrics: () -> Void
    let onClearCurrent: (() -> Void)?
    @FocusState private var isFocused: Bool
    @State private var videoSeekDraft: Double = 0
    @State private var isSeekingVideo: Bool = false

    var body: some View {
        let slides = session.slides
        let isCollapsed = flow.isCurrentCollapsed
        let selectedWebpageURL = currentWebpageURL(from: slides)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if session.isPresenting || !slides.isEmpty {
                    Button(action: toggleCollapsed) {
                        HStack(spacing: 4) {
                            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Current")
                                .font(.headline)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.primary)
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                        Text("Current")
                            .font(.headline)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                    }
                }

                let statusText: String = {
                    if session.isPresenting {
                        return session.areSlidesVisible ? "(Presenting)" : "(Slides hidden)"
                    }
                    return slides.isEmpty ? "(Not presenting)" : "(Loaded)"
                }()
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !slides.isEmpty {
                    Button("Edit", action: onEditCurrentLyrics)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!canEditCurrentLyrics)
                        .help("Edit Current lyrics in Preview")

                    Button("Clear", action: clearSlides)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Clear Current area")
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)

            if !isCollapsed {
                if slides.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                        Text("No document loaded")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Click any slide in Preview to load it here")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
                } else if let selectedWebpageURL {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Label(
                                titleForWebpage(selectedWebpageURL),
                                systemImage: "globe"
                            )
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                            Spacer()

                            Button {
                                session.webpageMuted.toggle()
                            } label: {
                                Label(
                                    session.webpageMuted ? "Unmute" : "Mute",
                                    systemImage: session.webpageMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
                                )
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .padding(.horizontal, 10)

                        WebpageViewRepresentable(
                            url: selectedWebpageURL,
                            isMuted: session.webpageMuted,
                            onURLChange: { currentURL in
                                onWebpageNavigationChange(currentURL, selectedWebpageURL)
                            },
                            onTitleChange: { title, currentURL in
                                onWebpageTitleChange(title, currentURL)
                            }
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(.separator, lineWidth: 1)
                        )
                        .padding(.horizontal, 10)
                        .padding(.bottom, 4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else {
                    GeometryReader { proxy in
                        ScrollViewReader { scrollProxy in
                            ScrollView {
                                let horizontalInset: CGFloat = 10
                                let layout = ThumbnailGridLayout.make(
                                    for: proxy.size.width - (horizontalInset * 2),
                                    thumbnailScale: thumbnailScale
                                )
                                LazyVGrid(columns: layout.columns, spacing: layout.spacing) {
                                    ForEach(slides) { slide in
                                        SlideGridCellView(
                                            slide: slide,
                                            itemWidth: layout.itemWidth,
                                            itemHeight: layout.itemHeight,
                                            isSelected: slide.id == session.currentSlideID,
                                            onTap: {
                                                flow.selectCurrentSlide(slide.id, in: session)
                                            }
                                        )
                                        .id(slide.id)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, horizontalInset)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .focusable()
                            .focused($isFocused)
                            .focusEffectDisabled()
                            .onKeyPress(.upArrow) {
                                return handleArrowKey(delta: -1)
                            }
                            .onKeyPress(.downArrow) {
                                return handleArrowKey(delta: 1)
                            }
                            .onKeyPress(.leftArrow) {
                                return handleArrowKey(delta: -1)
                            }
                            .onKeyPress(.rightArrow) {
                                return handleArrowKey(delta: 1)
                            }
                            .onTapGesture {
                                isFocused = true
                            }
                            .onChange(of: session.currentSlideID) { _, newValue in
                                scrollToSelectedSlide(newValue, with: scrollProxy)
                            }
                        }
                    }
                }

                if session.currentSlide?.videoURL != nil {
                    videoControls
                }
            }
        }
        .padding(10)
        .frame(
            maxWidth: .infinity,
            minHeight: selectedWebpageURL == nil || isCollapsed ? nil : 420,
            maxHeight: isCollapsed ? nil : .infinity,
            alignment: .top
        )
        .background(
            VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        )
        .animation(loadAnimation, value: slides.count)
        .layoutPriority(selectedWebpageURL == nil ? 0 : 1)
        .onChange(of: session.videoCurrentTime) { _, newValue in
            guard !isSeekingVideo else { return }
            videoSeekDraft = newValue
        }
        .onChange(of: session.currentSlide?.videoURL) { _, _ in
            videoSeekDraft = session.videoCurrentTime
            isSeekingVideo = false
        }
        .task(id: session.currentSlide?.videoURL) {
            await loadCurrentVideoDuration(from: session.currentSlide?.videoURL)
        }
    }

    private var videoControls: some View {
        HStack(spacing: 8) {
            Button {
                session.videoPaused.toggle()
            } label: {
                Label(
                    session.videoPaused ? "Play" : "Pause",
                    systemImage: session.videoPaused ? "play.fill" : "pause.fill"
                )
            }

            Button {
                session.videoMuted.toggle()
            } label: {
                Label(
                    session.videoMuted ? "Unmute" : "Mute",
                    systemImage: session.videoMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
                )
            }

            Button {
                session.videoLoop.toggle()
            } label: {
                Label("Loop", systemImage: session.videoLoop ? "repeat.1" : "repeat")
            }

            Text(formattedVideoTime(videoSeekDraft))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { videoSeekDraft },
                    set: { newValue in
                        videoSeekDraft = newValue
                        if session.videoDuration > 0 {
                            session.seekVideo(to: newValue)
                        }
                    }
                ),
                in: 0...max(session.videoDuration, 0.01),
                onEditingChanged: { isEditing in
                    isSeekingVideo = isEditing
                }
            )
            .disabled(session.videoDuration <= 0)

            Text(formattedVideoTime(session.videoDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
        .labelStyle(.iconOnly)
        .padding(.horizontal, 4)
    }

    private func toggleCollapsed() {
        withAnimation(paneToggleAnimation) {
            flow.isCurrentCollapsed.toggle()
        }
    }

    private func clearSlides() {
        if let onClearCurrent {
            onClearCurrent()
            return
        }
        flow.clearCurrentDocument(in: session)
        flow.isCurrentCollapsed = true
    }

    private func handleArrowKey(delta: Int) -> KeyPress.Result {
        guard !session.slides.isEmpty else { return .ignored }
        // No check for isPresenting - allow control during presentation too
        // This provides an alternative way to navigate when PresentationWindow loses focus
        session.moveSelection(delta)
        return .handled
    }

    private func scrollToSelectedSlide(_ slideID: Slide.ID?, with proxy: ScrollViewProxy) {
        guard let slideID else { return }
        withAnimation(.easeInOut(duration: 0.12)) {
            proxy.scrollTo(slideID, anchor: .center)
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
                currentTime: session.videoCurrentTime,
                duration: seconds
            )
        } catch {
            return
        }
    }

    private func currentWebpageURL(from slides: [Slide]) -> URL? {
        if let selectionID = session.currentSlideID,
           let selectedSlide = slides.first(where: { $0.id == selectionID }),
           let webpageURL = selectedSlide.webpageURL {
            return webpageURL
        }

        if slides.count == 1 {
            return slides.first?.webpageURL
        }

        return nil
    }
}
