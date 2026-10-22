import Foundation

nonisolated enum OutputComponentRole: String, Codable, CaseIterable, Sendable {
    case primary, meaning, translation, transliteration
    // Preserve the saved key for Confidence's native video playback status.
    case footer

    static let lyricRoles: [Self] = [.primary, .meaning, .translation, .transliteration]
    var title: String {
        switch self {
        case .primary: return "Primary lyrics"
        case .footer: return "Playback status"
        default: return rawValue.capitalized
        }
    }
}

nonisolated struct OutputTextComponent: Codable, Equatable, Sendable, Identifiable {
    var id: UUID = UUID()
    var role: OutputComponentRole
    var text: String
    var language: String? = nil
    var label: String? = nil
}

nonisolated struct OutputTextContent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case lyrics, text }
    var kind: Kind = .text
    var components: [OutputTextComponent] = []
    var label: String? = nil
    static let empty = Self()
    var isEmpty: Bool { components.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

nonisolated struct OutputColour: Codable, Equatable, Sendable {
    var red: Double = 0
    var green: Double = 0
    var blue: Double = 0
    var alpha: Double = 1
    static let black = Self()
    static let white = Self(red: 1, green: 1, blue: 1)
    static let chromaGreen = Self(red: 0, green: 1, blue: 0)
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
    var relativeSize: Double? = nil
    var weight: Double? = nil
    var italic: Bool? = nil
    var colour: OutputColour? = nil
    var lineSpacing: Double? = nil

    func resolve(inheriting base: OutputTypography) -> OutputTypography {
        .init(fontName: fontName ?? base.fontName, size: size ?? relativeSize.map { base.size * $0 } ?? base.size,
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
    enum Kind: String, Codable, CaseIterable, Sendable {
        case audience, confidence, lowerThird

        init(from decoder: any Decoder) throws {
            let value = try decoder.singleValueContainer().decode(String.self)
            // Old custom copies retain their components and appearance as Audience profiles.
            if value == "meaning" || value == "translation" { self = .audience }
            else if let kind = Self(rawValue: value) { self = kind }
            else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown output profile kind")) }
        }
    }
    var id: UUID
    var name: String
    var kind: Kind
    var roles: [OutputComponentRole] = OutputComponentRole.lyricRoles
    var layout = "stacked"
    var alignment = "center"
    var position = "middle"
    var padding: Double = 1
    var typography = OutputTypography()
    var componentTypography: [OutputComponentRole: OutputTypographyOverride] = [:]
    var background = OutputBackground()
    // Migrated Audience matches the old geometry-dependent requested font size.
    var usesLegacySizing = false
    // Quick controls customize a destination without editing its reusable source.
    var customizedForDestinationID: UUID? = nil

    func typography(for role: OutputComponentRole) -> OutputTypography {
        componentTypography[role]?.resolve(inheriting: typography) ?? typography
    }
    var typographyOverrideRoles: [OutputComponentRole] {
        OutputComponentRole.lyricRoles + (kind == .confidence ? [.footer] : [])
    }
    mutating func clearBackground(preservingKeyColour: Bool = false) {
        background.bookmark = nil
        // A key colour is output configuration, not a program visual. NDI
        // also remembers its key while transparent mode is selected.
        if kind != .lowerThird && !preservingKeyColour { background.colour = .black }
    }
    func components(in content: OutputTextContent) -> [OutputTextComponent] {
        content.components.filter { roles.contains($0.role) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    static let audienceID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let confidenceID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let lowerThirdID = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
    var isBuiltIn: Bool { [Self.audienceID, Self.confidenceID, Self.lowerThirdID].contains(id) }
    var isReusable: Bool { isBuiltIn || customizedForDestinationID == nil }
    static var builtIns: [Self] {
        let identities: [(Kind, UUID)] = [(.audience, audienceID), (.confidence, confidenceID), (.lowerThird, lowerThirdID)]
        return identities.map { kind, identity in
            var profile = Self(id: identity,
                               name: kind == .lowerThird ? "Lower Third" : kind.rawValue.capitalized, kind: kind)
            switch kind {
            case .audience:
                profile.usesLegacySizing = true
                profile.componentTypography[.meaning] = .init(relativeSize: 0.5, weight: 0, italic: true)
            case .confidence:
                profile.typography.size = 48
                profile.alignment = "left"
                profile.background.dimming = 0
            case .lowerThird:
                profile.roles = [.primary]
                profile.position = "bottom"
                profile.typography.size = 48
                profile.background.colour = .chromaGreen
                profile.background.dimming = 0
            }
            return profile
        }
    }
}

nonisolated extension OutputProfile {
    private enum CodingKeys: String, CodingKey {
        case id, name, kind, roles, layout, alignment, position, padding, typography, componentTypography, background, usesLegacySizing
        case customizedForDestinationID
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(Kind.self, forKey: .kind)
        roles = try c.decode([String].self, forKey: .roles).compactMap { try Self.persistedRole($0, decoder: decoder) }
            .filter { OutputComponentRole.lyricRoles.contains($0) }
        layout = try c.decode(String.self, forKey: .layout)
        alignment = try c.decode(String.self, forKey: .alignment)
        position = try c.decode(String.self, forKey: .position)
        padding = try c.decode(Double.self, forKey: .padding)
        typography = try c.decode(OutputTypography.self, forKey: .typography)
        componentTypography = try c.decode(PersistedTypography.self, forKey: .componentTypography).values
        if kind != .confidence { componentTypography.removeValue(forKey: .footer) }
        background = try c.decode(OutputBackground.self, forKey: .background)
        usesLegacySizing = try c.decode(Bool.self, forKey: .usesLegacySizing)
        customizedForDestinationID = try c.decodeIfPresent(UUID.self, forKey: .customizedForDestinationID)
    }
    private static func persistedRole(_ value: String, decoder: any Decoder) throws -> OutputComponentRole? {
        if ["secondary", "heading", "reference"].contains(value) { return nil } // Retired scripture components.
        guard let role = OutputComponentRole(rawValue: value) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown output component"))
        }
        return role
    }
    /// Enum-key dictionaries encode as alternating keys/values. Read the retired
    /// Scripture overrides only to discard them, retaining local profile settings.
    nonisolated private struct PersistedTypography: Decodable {
        var values: [OutputComponentRole: OutputTypographyOverride] = [:]
        init(from decoder: any Decoder) throws {
            var entries = try decoder.unkeyedContainer()
            while !entries.isAtEnd {
                let key = try entries.decode(String.self)
                let override = try entries.decode(OutputTypographyOverride.self)
                if let role = try OutputProfile.persistedRole(key, decoder: decoder) { values[role] = override }
            }
        }
    }
}
