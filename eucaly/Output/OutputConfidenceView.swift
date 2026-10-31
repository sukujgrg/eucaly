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

/// Pin text to explicit vertical boxes. Next reserves height only when it has
/// selected text; Current otherwise receives the full inner frame. Next chrome
/// (hairline + heading) is measured so verse text never shares that band.
nonisolated struct OutputConfidenceGeometry {
    let width: CGFloat
    let height: CGFloat
    let padding: CGFloat
    let spacing: CGFloat
    let fontSize: CGFloat
    let headingHeight: CGFloat
    let separatorHeight: CGFloat
    let nextChromeHeight: CGFloat
    let currentSize: CGSize
    let nextSize: CGSize

    init(size: CGSize, hasNext: Bool) {
        padding = min(32, max(0, min(size.width, size.height) * 0.05))
        width = max(0, size.width - padding * 2)
        height = max(0, size.height - padding * 2)
        spacing = min(24, max(0, size.height * 0.02))
        fontSize = min(22, max(1, size.height * 0.035))
        headingHeight = fontSize * 1.35
        separatorHeight = 1
        // Hairline, gap under it, heading, gap before Next lyrics.
        nextChromeHeight = hasNext ? separatorHeight + spacing * 0.5 + headingHeight + spacing / 3 : 0
        if hasNext {
            let nextBlock = max(0, height * 0.34)
            nextSize = CGSize(width: width, height: max(0, nextBlock - nextChromeHeight))
            currentSize = CGSize(width: width, height: max(0, height - nextBlock - spacing))
        } else {
            nextSize = .zero
            currentSize = CGSize(width: width, height: height)
        }
    }
}

struct OutputConfidenceView: View {
    let profile: OutputProfile
    let content: OutputConfidenceContent
    let size: CGSize

    var body: some View {
        ZStack {
            OutputConfidenceClock(size: size, prominence: content.isIdle ? .standby : .backdrop)
            if !content.isIdle {
                lyrics
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var lyrics: some View {
        let geometry = OutputConfidenceGeometry(size: size, hasNext: content.next != nil)
        return VStack(alignment: .leading, spacing: geometry.spacing) {
            text(content.current, size: geometry.currentSize)
            if let next = content.next {
                nextSection(next, geometry: geometry)
            }
        }
        .frame(width: geometry.width, height: geometry.height, alignment: .topLeading)
        .padding(geometry.padding)
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    private func nextSection(_ next: OutputTextContent, geometry: OutputConfidenceGeometry) -> some View {
        let colour = profile.typography.colour.color
        let label = next.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(colour.opacity(0.35))
                .frame(width: geometry.width, height: geometry.separatorHeight)
                .accessibilityHidden(true)
            Color.clear.frame(height: geometry.spacing * 0.5)
            HStack(alignment: .firstTextBaseline, spacing: max(8, geometry.fontSize * 0.45)) {
                Text("NEXT")
                    .font(.system(size: geometry.fontSize * 0.82, weight: .semibold, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(colour.opacity(0.5))
                if let label, !label.isEmpty {
                    Text(label)
                        .font(profile.typography.font(at: geometry.fontSize))
                        .foregroundStyle(colour.opacity(0.78))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
            }
            .frame(width: geometry.width, height: geometry.headingHeight, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label.flatMap { $0.isEmpty ? nil : "Next, \($0)" } ?? "Next")
            Color.clear.frame(height: geometry.spacing / 3)
            text(next, size: geometry.nextSize, style: OutputConfidenceContent.nextProfile(profile))
        }
        .frame(width: geometry.width, height: geometry.nextSize.height + geometry.nextChromeHeight, alignment: .topLeading)
    }

    private func text(_ content: OutputTextContent, size: CGSize, style: OutputProfile? = nil) -> some View {
        let style = style ?? profile
        return OutputTextView(content: OutputConfidenceContent.labeled(content, profile: style), profile: style, size: size)
    }
}

/// Confidence remains useful to the stage when there is no visible program.
/// The clock is local to Confidence composition and never takes output ownership.
struct OutputConfidenceClock: View {
    enum Prominence {
        case standby
        case backdrop
    }

    let size: CGSize
    var prominence: Prominence = .standby

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let calendar = Calendar.autoupdatingCurrent
            let clock = String(format: "%02d:%02d",
                               calendar.component(.hour, from: context.date),
                               calendar.component(.minute, from: context.date))
            let scale: CGFloat = prominence == .standby ? 1 : 0.82
            let opacity: Double = prominence == .standby ? 1 : 0.28
            Text(clock)
                .font(.system(size: max(1, min(size.width * 0.23, size.height * 0.45) * scale),
                              weight: .heavy, design: .rounded))
                .monospacedDigit().foregroundStyle(Color(red: 1, green: 0.82, blue: 0.24).opacity(opacity))
                .lineLimit(1).minimumScaleFactor(0.1)
                .padding(min(32, max(0, size.height * 0.04)))
                .background(Color.black.opacity(prominence == .standby ? 0.85 : 0.35), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Clock").accessibilityValue(clock)
                .accessibilityHidden(prominence == .backdrop)
                .frame(width: size.width, height: size.height, alignment: .center)
        }
    }
}

/// Measure the same labeled text and vertical boxes as the stage composition.
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
    @ObservedObject var progress: PlaybackProgressStore
    let typography: OutputTypography
    let size: CGSize
    var body: some View {
        let geometry = OutputConfidenceGeometry(size: size, hasNext: false)
        Text("\(progress.videoPlaybackState.title) · \(Int(progress.videoCurrentTime)) / \(Int(progress.videoDuration)) seconds")
            .font(typography.font(at: min(geometry.fontSize, typography.size))).foregroundStyle(typography.colour.color)
            .lineLimit(1).minimumScaleFactor(0.5)
            .padding(8).background(.black.opacity(0.85))
            .padding(geometry.padding).allowsHitTesting(false)
    }
}
