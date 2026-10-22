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
        media = snapshot.localMedia.flatMap { OutputContentClassifier.mode(for: $0) == .media ? $0 : nil }
        isIdle = !snapshot.visible || (media == nil && profile.components(in: current).isEmpty && next == nil)
    }
    static func labeled(_ content: OutputTextContent, profile: OutputProfile) -> OutputTextContent {
        var labeled = content
        let selected = profile.components(in: content)
        labeled.components = selected.map { component in
            guard selected.count > 1 || component.role != .primary || component.label != nil else { return component }
            var next = component
            let primaryLabel = content.kind == .lyrics ? "Lyrics" : "Text"
            let roleLabel = component.role == .primary ? primaryLabel : component.role.title
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

/// Pin text to explicit column boxes. Next reserves space only
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

    init(size: CGSize, hasNext: Bool) {
        padding = min(32, max(0, min(size.width, size.height) * 0.05))
        width = max(0, size.width - padding * 2)
        height = max(0, size.height - padding * 2)
        spacing = min(24, max(0, size.width * 0.02))
        fontSize = min(24, max(1, size.height * 0.04))
        headingHeight = fontSize * 1.4
        let columnsWidth = max(0, width - (hasNext ? spacing * 2 + 1 : 0))
        currentSize = CGSize(width: columnsWidth * (hasNext ? 0.68 : 1),
                             height: height)
        nextSize = CGSize(width: hasNext ? columnsWidth * 0.32 : 0,
                          height: max(0, height - headingHeight - spacing / 3))
    }
}

struct OutputConfidenceView: View {
    let profile: OutputProfile
    let content: OutputConfidenceContent
    let size: CGSize

    var body: some View {
        let geometry = OutputConfidenceGeometry(size: size, hasNext: content.next != nil)
        HStack(alignment: .top, spacing: geometry.spacing) {
            text(content.current, size: geometry.currentSize)
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
                .font(.system(size: max(1, min(size.width * 0.23, size.height * 0.45)), weight: .heavy, design: .rounded))
                .monospacedDigit().foregroundStyle(Color(red: 1, green: 0.82, blue: 0.24))
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
        let geometry = OutputConfidenceGeometry(size: size, hasNext: content.next != nil)
        if !content.isIdle && content.media == nil {
            OutputReadabilityProbe(content: OutputConfidenceContent.labeled(content.current, profile: profile), profile: profile, size: geometry.currentSize)
            if let next = content.next {
                let nextProfile = OutputConfidenceContent.nextProfile(profile)
                OutputReadabilityProbe(content: OutputConfidenceContent.labeled(next, profile: nextProfile), profile: nextProfile, size: geometry.nextSize)
            }
        }
    }
}

struct OutputConfidencePlaybackStatus: View {
    @ObservedObject var session: PresentationSession
    @ObservedObject var progress: PlaybackProgressStore
    let typography: OutputTypography
    let size: CGSize
    var body: some View {
        let geometry = OutputConfidenceGeometry(size: size, hasNext: false)
        Text("\(session.videoPaused ? "Paused" : "Playing") · \(Int(progress.videoCurrentTime)) / \(Int(progress.videoDuration)) seconds")
            .font(typography.font(at: min(geometry.fontSize, typography.size))).foregroundStyle(typography.colour.color)
            .lineLimit(1).minimumScaleFactor(0.5)
            .padding(8).background(.black.opacity(0.85))
            .padding(geometry.padding).allowsHitTesting(false)
    }
}
