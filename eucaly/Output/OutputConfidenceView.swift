import SwiftUI

/// Rendering policy uses the coherent last-presented snapshot. Private Current
/// navigation cannot replace hidden output or suppress Confidence's idle clock.
nonisolated struct OutputConfidenceContent {
    let current: OutputTextContent
    let next: OutputTextContent?
    let media: Slide?
    let isIdle: Bool

    init(snapshot: OutputContentSnapshot, profile: OutputProfile) {
        current = snapshot.current
        next = snapshot.next.flatMap { profile.components(in: $0).isEmpty ? nil : $0 }
        media = snapshot.localMedia.flatMap { AltViewPresentationAdapter.mode(for: $0) == .media ? $0 : nil }
        isIdle = !snapshot.visible || (media == nil && profile.components(in: current).isEmpty && next == nil)
    }
    static func labeled(_ content: OutputTextContent, profile: OutputProfile) -> OutputTextContent {
        var labeled = content
        let selected = profile.components(in: content)
        labeled.components = selected.map { component in
            guard selected.count > 1 || component.role != .primary || component.label != nil else { return component }
            var next = component
            let primaryLabel = content.kind == .lyrics ? "Lyrics" : content.kind == .scripture ? "Scripture" : "Text"
            let roleLabel = component.role == .primary ? primaryLabel : component.role.rawValue.capitalized
            next.text = "\(component.label ?? roleLabel)\n\(component.text)"
            return next
        }
        return labeled
    }
    static func nextProfile(_ profile: OutputProfile) -> OutputProfile {
        var next = profile
        next.typography.size *= 0.8
        for role in next.componentTypography.keys {
            if let size = next.componentTypography[role]?.size { next.componentTypography[role]?.size = size * 0.8 }
        }
        return next
    }
}

/// Pin native media and text to explicit column boxes. Next reserves space only
/// when it has selected text; Current otherwise receives the full inner frame.
nonisolated struct OutputConfidenceGeometry {
    let width: CGFloat
    let height: CGFloat
    let padding: CGFloat
    let spacing: CGFloat
    let fontSize: CGFloat
    let headingHeight: CGFloat
    let currentSize: CGSize
    let nextSize: CGSize

    init(size: CGSize, hasNext: Bool, hasPlayback: Bool) {
        padding = min(32, max(0, min(size.width, size.height) * 0.05))
        width = max(0, size.width - padding * 2)
        height = max(0, size.height - padding * 2)
        spacing = min(24, max(0, size.width * 0.02))
        fontSize = min(24, max(1, size.height * 0.04))
        headingHeight = fontSize * 1.4
        let columnsWidth = max(0, width - (hasNext ? spacing * 2 + 1 : 0))
        let textHeight = max(0, height - headingHeight - spacing / 3)
        currentSize = CGSize(width: columnsWidth * (hasNext ? 0.68 : 1),
                             height: max(0, textHeight - (hasPlayback ? headingHeight + spacing / 3 : 0)))
        nextSize = CGSize(width: hasNext ? columnsWidth * 0.32 : 0, height: textHeight)
    }
}

struct OutputConfidenceView: View {
    @ObservedObject var coordinator: OutputCoordinator
    let profile: OutputProfile
    let content: OutputConfidenceContent
    let size: CGSize

    var body: some View {
        let geometry = OutputConfidenceGeometry(size: size, hasNext: content.next != nil, hasPlayback: content.media?.videoURL != nil)
        HStack(alignment: .top, spacing: geometry.spacing) {
            VStack(alignment: .leading, spacing: geometry.spacing / 3) {
                heading("Current", label: content.media?.title ?? content.current.label, width: geometry.currentSize.width, geometry: geometry)
                current(size: geometry.currentSize)
                if let session = coordinator.localSession, content.media?.videoURL != nil {
                    OutputPlaybackStatus(session: session, progress: session.playbackProgress,
                                         typography: profile.typography(for: .footer), fontSize: geometry.fontSize)
                        .frame(height: geometry.headingHeight)
                }
            }.frame(width: geometry.currentSize.width, height: geometry.height, alignment: .topLeading)
            if let next = content.next {
                Divider().frame(width: 1, height: geometry.height).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: geometry.spacing / 3) {
                    heading("Next", label: next.label, width: geometry.nextSize.width, geometry: geometry)
                    text(next, size: geometry.nextSize, style: OutputConfidenceContent.nextProfile(profile))
                }.frame(width: geometry.nextSize.width, height: geometry.height, alignment: .topLeading)
            }
        }.frame(width: geometry.width, height: geometry.height, alignment: .topLeading)
            .padding(geometry.padding).frame(width: size.width, height: size.height)
    }
    @ViewBuilder private func current(size: CGSize) -> some View {
        if let slide = content.media, let session = coordinator.localSession {
            if slide.webpageURL != nil {
                OutputWebpageCompanionView().frame(width: size.width, height: size.height)
            } else {
                OutputMediaSlideView(slide: slide, session: session, runtime: coordinator.media,
                                     showsBackground: profile.background.whenMediaShown)
                    .frame(width: size.width, height: size.height).clipped().id(slide.id)
            }
        } else {
            text(content.current, size: size)
        }
    }
    private func heading(_ title: String, label: String?, width: CGFloat, geometry: OutputConfidenceGeometry) -> some View {
        Text(title + (label.map { " · \($0)" } ?? ""))
            .font(profile.typography.font(at: geometry.fontSize)).foregroundStyle(profile.typography.colour.color)
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            .frame(width: width, height: geometry.headingHeight, alignment: .leading)
    }
    private func text(_ content: OutputTextContent, size: CGSize, style: OutputProfile? = nil) -> some View {
        let style = style ?? profile
        return OutputTextView(content: OutputConfidenceContent.labeled(content, profile: style), profile: style, size: size)
    }
}

/// Confidence remains useful to the stage when there is no visible program.
/// The standby clock is local to Confidence and never takes output ownership.
struct OutputConfidenceIdleClock: View {
    let size: CGSize
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let calendar = Calendar.autoupdatingCurrent
            let clock = String(format: "%02d:%02d", calendar.component(.hour, from: context.date), calendar.component(.minute, from: context.date))
            Text(clock)
                .font(.system(size: max(1, min(size.width * 0.23, size.height * 0.45)), weight: .bold))
                .monospacedDigit().foregroundStyle(.white)
                .lineLimit(1).minimumScaleFactor(0.1)
                .padding(min(32, max(0, size.height * 0.04)))
                .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Clock").accessibilityValue(clock)
                .frame(width: size.width, height: size.height, alignment: .center)
        }
    }
}

/// Measure the same labeled text and column boxes as the stage composition.
struct OutputConfidenceReadabilityProbe: View {
    let snapshot: OutputContentSnapshot
    let profile: OutputProfile
    let size: CGSize
    var body: some View {
        let content = OutputConfidenceContent(snapshot: snapshot, profile: profile)
        let geometry = OutputConfidenceGeometry(size: size, hasNext: content.next != nil, hasPlayback: content.media?.videoURL != nil)
        if !content.isIdle {
            if content.media == nil {
                OutputReadabilityProbe(content: OutputConfidenceContent.labeled(content.current, profile: profile), profile: profile, size: geometry.currentSize)
            }
            if let next = content.next {
                let nextProfile = OutputConfidenceContent.nextProfile(profile)
                OutputReadabilityProbe(content: OutputConfidenceContent.labeled(next, profile: nextProfile), profile: nextProfile, size: geometry.nextSize)
            }
        }
    }
}

private struct OutputPlaybackStatus: View {
    @ObservedObject var session: PresentationSession
    @ObservedObject var progress: PlaybackProgressStore
    let typography: OutputTypography
    let fontSize: CGFloat
    var body: some View {
        Text("\(session.videoPaused ? "Paused" : "Playing") · \(Int(progress.videoCurrentTime)) / \(Int(progress.videoDuration)) seconds")
            .font(typography.font(at: min(fontSize, typography.size))).foregroundStyle(typography.colour.color)
    }
}
