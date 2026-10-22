import SwiftUI
import AppKit

private struct AudienceOutputProfileKey: EnvironmentKey { static let defaultValue: OutputProfile? = nil }
extension EnvironmentValues {
    var audienceOutputProfile: OutputProfile? {
        get { self[AudienceOutputProfileKey.self] }
        set { self[AudienceOutputProfileKey.self] = newValue }
    }
}

extension OutputColour {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    init(_ color: Color) {
        let value = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: value.redComponent, green: value.greenComponent, blue: value.blueComponent, alpha: value.alphaComponent)
    }
}

extension OutputTypography {
    var unavailableFont: Bool { fontName.map { $0 != "system" && NSFont(name: $0, size: size) == nil } ?? false }
    func font(at size: CGFloat) -> Font {
        let weight = NSFont.Weight(rawValue: weight)
        var native = fontName.flatMap { NSFont(name: $0, size: size) } ?? NSFont.systemFont(ofSize: size, weight: weight)
        if fontName != nil && fontName != "system" {
            let descriptor = native.fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue]])
            native = NSFont(descriptor: descriptor, size: size) ?? native
        }
        if italic { native = NSFontManager.shared.convert(native, toHaveTrait: .italicFontMask) }
        return Font(native)
    }
}

/// Shared geometry and requested typography; native Text fits its own shaped
/// glyphs into these boxes without truncating or rewriting saved settings.
struct OutputTextMetrics {
    let components: [OutputTextComponent]
    let contentSize: CGSize
    let spacing: CGFloat
    let profile: OutputProfile
    private let available: CGSize
    init(content: OutputTextContent, profile: OutputProfile, size: CGSize) {
        self.profile = profile
        let selected = profile.components(in: content)
        if profile.layout == "columns" {
            components = OutputComponentRole.allCases.compactMap { role in
                let group = selected.filter { $0.role == role }
                guard let first = group.first else { return nil }
                return .init(id: first.id, role: role, text: group.map(\.text).joined(separator: "\n\n"), language: first.language, label: first.label)
            }
        } else { components = selected }
        let padding = CGFloat(min(2, max(0, profile.padding)))
        contentSize = CGSize(width: max(0, size.width - max(40, size.width * 0.1) * 2 * padding),
                             height: max(0, size.height - max(32, size.height * 0.08) * 2 * padding))
        let count = CGFloat(max(1, components.count))
        spacing = min(28 * padding, (profile.layout == "columns" ? contentSize.width : contentSize.height) / count)
        let gaps = spacing * CGFloat(max(0, components.count - 1))
        available = CGSize(width: profile.layout == "columns" ? max(0, contentSize.width - gaps) : contentSize.width,
                           height: profile.layout == "columns" ? contentSize.height : max(0, contentSize.height - gaps) / count)
    }
    func size(for component: OutputTextComponent) -> CGSize {
        let weight = components.reduce(0) { $0 + profile.typography(for: $1.role).size }
        let fraction = weight > 0 ? profile.typography(for: component.role).size / weight : 1
        return CGSize(width: available.width * (profile.layout == "columns" ? fraction : 1), height: available.height)
    }
    func requestedSize(for component: OutputTextComponent) -> CGFloat {
        let typography = profile.typography(for: component.role)
        if profile.usesLegacySizing { return min(84, size(for: component).height * 0.9) * typography.size / 84 }
        return typography.size
    }
}

struct OutputTextView: View {
    let content: OutputTextContent
    let profile: OutputProfile
    let size: CGSize
    var body: some View {
        let metrics = OutputTextMetrics(content: content, profile: profile, size: size)
        let alignment = PresentationTextAlignment(rawValue: profile.alignment) ?? .center
        let position = PresentationVerticalPosition(rawValue: profile.position) ?? .middle
        Group {
            if profile.layout == "columns" {
                HStack(alignment: position.verticalAlignment, spacing: metrics.spacing) { blocks(metrics, alignment: alignment) }
            } else {
                VStack(alignment: alignment.horizontalAlignment, spacing: metrics.spacing) { blocks(metrics, alignment: alignment) }
            }
        }
        .frame(width: metrics.contentSize.width, height: metrics.contentSize.height, alignment: position.frameAlignment)
        .frame(width: size.width, height: size.height)
        .clipped()
    }
    private func blocks(_ metrics: OutputTextMetrics, alignment: PresentationTextAlignment) -> some View {
        ForEach(metrics.components) { component in
            let typography = profile.typography(for: component.role)
            let box = metrics.size(for: component)
            LyricsTextFitLayout(maxHeight: box.height) {
                Text(component.text)
                    .font(typography.font(at: metrics.requestedSize(for: component)))
                    .foregroundStyle(typography.colour.color)
                    .lineSpacing(typography.lineSpacing)
                    .multilineTextAlignment(alignment.textAlignment)
                    .lineLimit(nil).minimumScaleFactor(0.01)
            }
            .frame(width: box.width, alignment: alignment.frameAlignment)
        }
    }
}
