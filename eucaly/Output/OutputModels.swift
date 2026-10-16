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
        case audience, confidence, lowerThird, altView, altViewMedia

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
    mutating func clearBackground() {
        background.bookmark = nil
        // The key colour is part of Lower Third's output setup, even when
        // clearing all program layers. Preserve custom keys as well as green.
        if kind != .lowerThird { background.colour = .black }
    }
    func components(in content: OutputTextContent) -> [OutputTextComponent] {
        content.components.filter { roles.contains($0.role) && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    static let audienceID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let confidenceID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let lowerThirdID = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
    static let altViewID = UUID(uuidString: "00000000-0000-4000-8000-000000000006")!
    static let altViewMediaID = UUID(uuidString: "00000000-0000-4000-8000-000000000007")!
    var isNative: Bool { kind != .altView && kind != .altViewMedia }
    static var builtIns: [Self] {
        let identities: [(Kind, UUID)] = [(.audience, audienceID), (.confidence, confidenceID), (.lowerThird, lowerThirdID), (.altView, altViewID), (.altViewMedia, altViewMediaID)]
        return identities.map { kind, identity in
            var profile = Self(id: identity,
                               name: kind == .altViewMedia ? "AltView Media" : kind == .lowerThird ? "Lower Third" : kind == .altView ? "AltView" : kind.rawValue.capitalized, kind: kind)
            switch kind {
            case .audience:
                profile.usesLegacySizing = true
                profile.componentTypography[.meaning] = .init(relativeSize: 0.5, weight: 0, italic: true)
            case .confidence:
                profile.typography.size = 48
                profile.alignment = "left"
                profile.background.dimming = 0
            case .altView, .altViewMedia:
                profile.roles = [] // Receiver owns composition and appearance.
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

nonisolated struct OutputReceiverTarget: Codable, Equatable, Sendable {
    var receiverID: UUID
    var name: String
}

nonisolated enum OutputDestination: Codable, Equatable, Sendable {
    case none
    case monitor(ProjectionMonitorTarget)
    case altView(OutputReceiverTarget)
    case srt(SRTMediaSettings)
}

nonisolated struct OutputDestinationConfiguration: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var profileID: UUID
    var destination: OutputDestination = .none
    var enabled = true
    // Keep the native assignment while temporarily selecting the forwarding profile.
    var savedMonitor: ProjectionMonitorTarget?
    var sourceAudienceID: UUID?
    var includeBackgroundAudio = false
    var srt: SRTMediaSettings? { if case .srt(let settings) = destination { return settings }; return nil }
    var savedReceiver: OutputReceiverTarget?
    var monitor: ProjectionMonitorTarget? {
        get { if case .monitor(let target) = destination { return target }; return nil }
        set { destination = newValue.map(OutputDestination.monitor) ?? .none; savedMonitor = newValue }
    }
    var receiver: OutputReceiverTarget? {
        if case .altView(let target) = destination { return target }; return nil
    }
    init(id: UUID = UUID(), name: String, profileID: UUID, monitor: ProjectionMonitorTarget?, enabled: Bool = true) {
        self.id = id; self.name = name; self.profileID = profileID; self.enabled = enabled
        self.monitor = monitor
    }
    private enum CodingKeys: String, CodingKey { case id, name, profileID, destination, monitor, enabled, savedMonitor, savedReceiver, sourceAudienceID, includeBackgroundAudio }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); name = try c.decode(String.self, forKey: .name)
        profileID = try c.decode(UUID.self, forKey: .profileID); enabled = try c.decode(Bool.self, forKey: .enabled)
        savedMonitor = try c.decodeIfPresent(ProjectionMonitorTarget.self, forKey: .savedMonitor)
            ?? c.decodeIfPresent(ProjectionMonitorTarget.self, forKey: .monitor)
        sourceAudienceID = try c.decodeIfPresent(UUID.self, forKey: .sourceAudienceID)
        includeBackgroundAudio = try c.decodeIfPresent(Bool.self, forKey: .includeBackgroundAudio) ?? false
        savedReceiver = try c.decodeIfPresent(OutputReceiverTarget.self, forKey: .savedReceiver)
        destination = try c.decodeIfPresent(OutputDestination.self, forKey: .destination)
            ?? savedMonitor.map(OutputDestination.monitor) ?? .none
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(name, forKey: .name); try c.encode(profileID, forKey: .profileID)
        try c.encode(enabled, forKey: .enabled); try c.encode(destination, forKey: .destination)
        try c.encodeIfPresent(sourceAudienceID, forKey: .sourceAudienceID)
        try c.encode(includeBackgroundAudio, forKey: .includeBackgroundAudio)
        try c.encodeIfPresent(savedMonitor, forKey: .savedMonitor); try c.encodeIfPresent(savedReceiver, forKey: .savedReceiver)
    }
}

nonisolated struct OutputProfileDocument: Codable, Equatable {
    var version = 4
    var profiles: [OutputProfile]
    var destinations: [OutputDestinationConfiguration]
    var defaultDestinationID: UUID? = nil

    init(version: Int = 4, profiles: [OutputProfile], destinations: [OutputDestinationConfiguration], defaultDestinationID: UUID? = nil) {
        self.version = version; self.profiles = profiles; self.destinations = destinations
        self.defaultDestinationID = defaultDestinationID
    }

    private enum CodingKeys: String, CodingKey { case version, profiles, destinations, defaultDestinationID }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        profiles = try c.decode([OutputProfile].self, forKey: .profiles)
        destinations = try c.decode([OutputDestinationConfiguration].self, forKey: .destinations)
        // Missing means the old primary output. Explicit null means None and
        // must survive launches, migration and removal of the former default.
        defaultDestinationID = c.contains(.defaultDestinationID)
            ? try c.decodeIfPresent(UUID.self, forKey: .defaultDestinationID) : destinations.first?.id
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(profiles, forKey: .profiles)
        try c.encode(destinations, forKey: .destinations)
        try c.encode(defaultDestinationID, forKey: .defaultDestinationID)
    }
}

nonisolated enum OutputProfileMigration {
    /// Retire factory presets without losing physical monitor identities or custom copies.
    static func retireLegacyPresets(in saved: OutputProfileDocument) -> OutputProfileDocument {
        let retiredIDs: Set<UUID> = [
            UUID(uuidString: "00000000-0000-4000-8000-000000000003")!,
            UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
        ]
        var result = saved
        result.version = 4
        if !result.profiles.contains(where: { $0.id == OutputProfile.altViewID }) {
            result.profiles.append(OutputProfile.builtIns.first { $0.kind == .altView }!)
        }
        if !result.profiles.contains(where: { $0.id == OutputProfile.altViewMediaID }) {
            result.profiles.append(OutputProfile.builtIns.first { $0.kind == .altViewMedia }!)
        }
        result.profiles.removeAll { retiredIDs.contains($0.id) }
        for index in result.destinations.indices where retiredIDs.contains(result.destinations[index].profileID) {
            result.destinations[index].profileID = OutputProfile.audienceID
            if ["Meaning", "Translation"].contains(result.destinations[index].name) {
                result.destinations[index].name = "Audience"
            }
        }
        return result
    }

    static func migrate(defaults: UserDefaults?, monitor: ProjectionMonitorTarget?) -> OutputProfileDocument {
        var profiles = OutputProfile.builtIns
        if let layout = defaults?.string(forKey: "presentationLyricsLayout") { profiles[0].layout = layout }
        if let alignment = defaults?.string(forKey: "presentationTextAlignment") { profiles[0].alignment = alignment }
        if let position = defaults?.string(forKey: "presentationVerticalPosition") { profiles[0].position = position }
        if defaults?.object(forKey: "presentationPaddingScale") != nil {
            profiles[0].padding = min(2, max(0, (defaults?.double(forKey: "presentationPaddingScale") ?? 1)))
        }
        let scale = defaults?.object(forKey: "presentationFontScale") == nil ? 1 : (defaults?.double(forKey: "presentationFontScale") ?? 1)
        profiles[0].typography.size = 84 * (scale.isFinite ? min(4, max(0.1, scale)) : 1)
        profiles[0].background.bookmark = defaults?.string(forKey: "backgroundVisualBookmark").flatMap { $0.isEmpty ? nil : $0 }
        let audience = OutputDestinationConfiguration(name: "Audience", profileID: OutputProfile.audienceID, monitor: monitor)
        return .init(profiles: profiles, destinations: [audience], defaultDestinationID: audience.id)
    }
}

nonisolated struct OutputContentSnapshot {
    enum Kind { case empty, lyrics, text, video, pdf, image, webpage, capturedWindow }
    var source: UUID?
    var kind: Kind = .empty
    var current = OutputTextContent.empty
    var next: OutputTextContent?
    var visible = true
    var revision: UInt64 = 0
    // Native media references remain local to eucaly.
    var localMedia: Slide?
}

nonisolated extension OutputProfileDocument {
    var isValid: Bool {
        guard (1...4).contains(version), (1...128).contains(profiles.count), destinations.count <= 16,
              Set(profiles.map(\.id)).count == profiles.count,
              Set(destinations.map(\.id)).count == destinations.count,
              profiles.contains(where: { $0.id == OutputProfile.audienceID }),
              destinations.allSatisfy({ destination in destination.name.utf8.count <= 160 && profiles.contains { $0.id == destination.profileID } }) else { return false }
        if version >= 2 {
            guard destinations.allSatisfy({ row in
                guard let profile = profiles.first(where: { $0.id == row.profileID }) else { return false }
                switch row.destination {
                case .none: return true
                case .monitor: return profile.isNative
                case .srt(let settings): return profile.kind == .altViewMedia && settings.isValid
                case .altView(let receiver): return profile.kind == .altView && !receiver.name.isEmpty && receiver.name.utf8.count <= 160
                }
            }) else { return false }
        }
        return profiles.allSatisfy { profile in
            guard profile.name.utf8.count <= 160, ["stacked", "columns"].contains(profile.layout),
                  ["left", "center", "right"].contains(profile.alignment), ["top", "middle", "bottom"].contains(profile.position),
                  profile.padding.isFinite, (0...2).contains(profile.padding), profile.background.dimming.isFinite,
                  (0...1).contains(profile.background.dimming), ["fit", "fill"].contains(profile.background.fit),
                  (profile.background.bookmark?.utf8.count ?? 0) <= 65_536,
                  Set(profile.roles).count == profile.roles.count else { return false }
            guard profile.componentTypography.values.allSatisfy({ $0.relativeSize.map { $0.isFinite && (0.01...4).contains($0) } ?? true }) else { return false }
            return ([profile.typography] + profile.componentTypography.values.map { $0.resolve(inheriting: profile.typography) }).allSatisfy { type in
                type.size.isFinite && (1...800).contains(type.size) && type.weight.isFinite && (-1...1).contains(type.weight)
                    && type.lineSpacing.isFinite && (0...200).contains(type.lineSpacing) && (type.fontName?.utf8.count ?? 0) <= 256
                    && [type.colour.red, type.colour.green, type.colour.blue, type.colour.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
            } && [profile.background.colour.red, profile.background.colour.green, profile.background.colour.blue, profile.background.colour.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
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
nonisolated struct OutputDestinationStatus: Sendable {
    var id: UUID
    var name: String
    var profileID: UUID
    var readiness: OutputReadiness
}
