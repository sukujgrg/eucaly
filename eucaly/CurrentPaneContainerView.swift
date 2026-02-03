import SwiftUI

struct CurrentPaneContainerView: View {
    @ObservedObject var session: PresentationSession
    @ObservedObject var flow: PresentationFlowController
    let thumbnailScale: Double
    let paneToggleAnimation: Animation
    let loadAnimation: Animation
    let onClearCurrent: (() -> Void)?
    @AppStorage("overlayScale") private var overlayScale: Double = 1.0
    @FocusState private var isFocused: Bool

    var body: some View {
        let slides = session.slides
        let isCollapsed = flow.isCurrentCollapsed
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

                if !slides.isEmpty {
                    Button("Clear", action: clearSlides)
                        .primaryActionStyle(fixedWidth: 170)
                        .help("Clear Current area")
                }

                Spacer()
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
                } else {
                    GeometryReader { proxy in
                        TimelineView(.periodic(from: .now, by: 1.0)) { context in
                            let overlayText = overlayBadgeText(at: context.date)
                            let overlayLabel = overlayBadgeLabel()
                            let overlayColor = overlayBadgeColor(at: context.date)
                            ScrollView {
                                let layout = ThumbnailGridLayout.make(for: proxy.size.width, thumbnailScale: thumbnailScale)
                                LazyVGrid(columns: layout.columns, spacing: layout.spacing) {
                                    ForEach(slides) { slide in
                                        SlideGridCellView(
                                            slide: slide,
                                            itemWidth: layout.itemWidth,
                                            itemHeight: layout.itemHeight,
                                            isSelected: slide.id == session.currentSlideID,
                                            overlayText: overlayText,
                                            overlayLabel: overlayLabel,
                                            overlayColor: overlayColor,
                                            overlayScale: overlayScale,
                                            onTap: {
                                                flow.selectCurrentSlide(slide.id, in: session)
                                            }
                                        )
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, 10)
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
                        }
                    }
                }

                if session.currentSlide?.videoURL != nil {
                    HStack(spacing: 8) {
                        Button {
                            session.videoPaused.toggle()
                        } label: {
                            Label(session.videoPaused ? "Play" : "Pause", systemImage: session.videoPaused ? "play.fill" : "pause.fill")
                        }
                        Button {
                            session.videoMuted.toggle()
                        } label: {
                            Label(session.videoMuted ? "Unmute" : "Mute", systemImage: session.videoMuted ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        }
                        Button {
                            session.videoLoop.toggle()
                        } label: {
                            Label("Loop", systemImage: session.videoLoop ? "repeat.1" : "repeat")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .labelStyle(.iconOnly)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: isCollapsed ? nil : .infinity, alignment: .top)
        .background(
            VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        )
        .animation(paneToggleAnimation, value: isCollapsed)
        .animation(loadAnimation, value: slides.count)
    }

    private func toggleCollapsed() {
        flow.isCurrentCollapsed.toggle()
    }

    private func clearSlides() {
        if let onClearCurrent {
            onClearCurrent()
            return
        }
        flow.clearCurrentDocument(in: session)
        flow.isCurrentCollapsed = true
    }

    private func overlayBadgeText(at date: Date) -> String? {
        guard session.isTimeOverlayVisible else { return nil }
        switch session.overlayMode {
        case .clock:
            return session.clockDisplay(at: date)
        case .countdown:
            return session.countdownDisplay(at: date)
        }
    }

    private func overlayBadgeColor(at date: Date) -> Color {
        guard session.isTimeOverlayVisible else { return .clear }
        return session.overlayTintColor(remaining: session.remainingCountdownSeconds(at: date))
    }

    private func overlayBadgeLabel() -> String? {
        guard session.isTimeOverlayVisible else { return nil }
        switch session.overlayMode {
        case .clock:
            return "Clock"
        case .countdown:
            return "Timer"
        }
    }

    private func handleArrowKey(delta: Int) -> KeyPress.Result {
        guard !session.slides.isEmpty else { return .ignored }
        // No check for isPresenting - allow control during presentation too
        // This provides an alternative way to navigate when PresentationWindow loses focus
        session.moveSelection(delta)
        return .handled
    }
}
