import Foundation

nonisolated enum OutputComponentRole: String, Codable, CaseIterable, Sendable {
    case primary, meaning, translation, transliteration, heading, reference, footer
}

nonisolated struct OutputTextComponent: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var role: OutputComponentRole
    var text: String
    var language: String? = nil
    var label: String? = nil
}

nonisolated struct OutputTextContent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case lyrics, scripture, text }
    var kind: Kind = .text
    var components: [OutputTextComponent] = []
    var label: String? = nil
    static let empty = Self()
    var isEmpty: Bool { components.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

nonisolated enum OutputContentAdapter {
    static func role(for line: SlideLine) -> OutputComponentRole {
        switch LyricsSectionCatalog.parseCompanionHeader(line.languageTag) {
        case .meaning: return .meaning
        case .translation: return .translation
        case .transliteration: return .transliteration
        case nil: return .primary
        }
    }
    static func text(for slide: Slide?) -> OutputTextContent {
        guard let slide, AltViewPresentationAdapter.mode(for: slide) == .lyrics else { return .empty }
        return .init(kind: .lyrics, components: slide.lines.map {
            .init(id: $0.id, role: role(for: $0), text: $0.text)
        }, label: slide.label)
    }
}

nonisolated struct OutputColour: Codable, Equatable, Sendable {
    var red: Double = 0
    var green: Double = 0
    var blue: Double = 0
    var alpha: Double = 1
    static let black = Self()
    static let white = Self(red: 1, green: 1, blue: 1)
}

nonisolated struct OutputTypography: Codable, Equatable, Sendable {
    // nil means the native system font. Preserve unavailable identifiers.
    var fontName: String? = nil
    var size: Double = 84
    var weight: Double = 0.4 // NSFont.Weight.bold
    var italic = false
    var colour = OutputColour.white
    var lineSpacing: Double = 0
}

nonisolated struct OutputTypographyOverride: Codable, Equatable, Sendable {
    var fontName: String? = nil
    var size: Double? = nil
    var weight: Double? = nil
    var italic: Bool? = nil
    var colour: OutputColour? = nil
    var lineSpacing: Double? = nil

    func resolve(inheriting base: OutputTypography) -> OutputTypography {
        .init(fontName: fontName ?? base.fontName, size: size ?? base.size,
              weight: weight ?? base.weight, italic: italic ?? base.italic,
              colour: colour ?? base.colour, lineSpacing: lineSpacing ?? base.lineSpacing)
    }
}

nonisolated struct OutputBackground: Codable, Equatable, Sendable {
    var colour = OutputColour.black
    var bookmark: String? = nil
    var fit: String = "fill"
    var dimming: Double = 0.35
    var visible = true
    var whenTextShown = true
    var whenHidden = true
    var whenMediaShown = false
}

nonisolated struct OutputProfile: Codable, Equatable, Sendable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Sendable { case audience, confidence, meaning, translation, lowerThird }
    var id: UUID
    var name: String
    var kind: Kind
    var roles: [OutputComponentRole] = OutputComponentRole.allCases
    var layout = "stacked"
    var alignment = "center"
    var position = "middle"
    var padding: Double = 1
    var typography = OutputTypography()
    var componentTypography: [OutputComponentRole: OutputTypographyOverride] = [:]
    var background = OutputBackground()
    var includesOverlay = true
    // Migrated Audience matches the old geometry-dependent requested font size.
    var usesLegacySizing = false

    func typography(for role: OutputComponentRole) -> OutputTypography {
        componentTypography[role]?.resolve(inheriting: typography) ?? typography
    }
    func components(in content: OutputTextContent) -> [OutputTextComponent] {
        content.components.filter { roles.contains($0.role) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    static let audienceID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static var builtIns: [Self] {
        Kind.allCases.enumerated().map { index, kind in
            var profile = Self(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                               name: kind == .lowerThird ? "Lower Third" : kind.rawValue.capitalized, kind: kind)
            switch kind {
            case .audience:
                profile.usesLegacySizing = true
                profile.componentTypography[.meaning] = .init(size: 42, weight: 0, italic: true)
            case .confidence:
                profile.typography.size = 48
                profile.alignment = "left"
                profile.background.dimming = 0
            case .meaning: profile.roles = [.meaning]; profile.typography.weight = 0
            case .translation: profile.roles = [.translation]
            case .lowerThird:
                profile.roles = [.primary, .heading, .reference, .footer]
                profile.position = "bottom"
                profile.typography.size = 48
            }
            return profile
        }
    }
}

nonisolated struct OutputDestinationConfiguration: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var profileID: UUID
    var monitor: ProjectionMonitorTarget?
    var enabled = true
}

nonisolated struct OutputProfileDocument: Codable, Equatable {
    var version = 1
    var profiles: [OutputProfile]
    var destinations: [OutputDestinationConfiguration]
    var receiverEnabled = false
}

nonisolated enum OutputProfileMigration {
    static func migrate(defaults: UserDefaults, monitor: ProjectionMonitorTarget?) -> OutputProfileDocument {
        var profiles = OutputProfile.builtIns
        if let layout = defaults.string(forKey: "presentationLyricsLayout") { profiles[0].layout = layout }
        if let alignment = defaults.string(forKey: "presentationTextAlignment") { profiles[0].alignment = alignment }
        if let position = defaults.string(forKey: "presentationVerticalPosition") { profiles[0].position = position }
        if defaults.object(forKey: "presentationPaddingScale") != nil {
            profiles[0].padding = min(2, max(0, defaults.double(forKey: "presentationPaddingScale")))
        }
        let scale = defaults.object(forKey: "presentationFontScale") == nil ? 1 : defaults.double(forKey: "presentationFontScale")
        profiles[0].typography.size = 84 * scale
        profiles[0].componentTypography[.meaning]?.size = 42 * scale
        profiles[0].background.bookmark = defaults.string(forKey: "backgroundVisualBookmark").flatMap { $0.isEmpty ? nil : $0 }
        return .init(profiles: profiles, destinations: [.init(name: "Audience", profileID: OutputProfile.audienceID, monitor: monitor)])
    }
}
