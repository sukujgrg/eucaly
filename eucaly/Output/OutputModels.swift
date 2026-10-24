import Foundation

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
        guard let slide, OutputContentClassifier.mode(for: slide) == .lyrics else { return .empty }
        return .init(kind: .lyrics, components: slide.lines.map {
            .init(id: $0.id, role: role(for: $0), text: $0.text)
        }, label: slide.label)
    }
}

nonisolated enum OutputDestination: Codable, Equatable, Sendable {
    case none
    case monitor(ProjectionMonitorTarget)
    case ndi(NetworkOutputSettings)
    case omt(NetworkOutputSettings)
}

nonisolated struct OutputDestinationConfiguration: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var profileID: UUID
    var destination: OutputDestination = .none
    var enabled = true
    var workspaceID: UUID? = OutputWorkspaceRecord.primaryID
    var ndi: NetworkOutputSettings? {
        get { if case .ndi(let settings) = destination { return settings }; return nil }
        set { destination = newValue.map(OutputDestination.ndi) ?? .none }
    }
    var omt: NetworkOutputSettings? {
        get { if case .omt(let settings) = destination { return settings }; return nil }
        set { destination = newValue.map(OutputDestination.omt) ?? .none }
    }
    var networkTechnology: NetworkOutputTechnology? {
        switch destination {
        case .ndi: .ndi
        case .omt: .omt
        case .none, .monitor: nil
        }
    }
    var networkSettings: NetworkOutputSettings? {
        get {
            switch destination {
            case .ndi(let settings), .omt(let settings): settings
            case .none, .monitor: nil
            }
        }
        set {
            guard let newValue else { destination = .none; return }
            destination = networkTechnology == .omt ? .omt(newValue) : .ndi(newValue)
        }
    }
    var isNetworkDestination: Bool { networkTechnology != nil }
    var isMonitorDestination: Bool {
        switch destination {
        case .none, .monitor: true
        case .ndi, .omt: false
        }
    }
    var monitor: ProjectionMonitorTarget? {
        get { if case .monitor(let target) = destination { return target }; return nil }
        set { destination = newValue.map(OutputDestination.monitor) ?? .none }
    }
    init(id: UUID = UUID(), name: String, profileID: UUID, monitor: ProjectionMonitorTarget?, enabled: Bool = true, workspaceID: UUID? = OutputWorkspaceRecord.primaryID) {
        self.id = id; self.name = name; self.profileID = profileID; self.enabled = enabled; self.workspaceID = workspaceID
        self.monitor = monitor
    }
}

nonisolated struct OutputProfileDocument: Codable, Equatable {
    var version = 7
    var workspaces: [OutputWorkspaceRecord] = [.primary]
    var profiles: [OutputProfile]
    var destinations: [OutputDestinationConfiguration]
    var defaultDestinationID: UUID? = nil
    var backgroundAudioDestinationID: UUID? = nil

    init(version: Int = 7, profiles: [OutputProfile], destinations: [OutputDestinationConfiguration], defaultDestinationID: UUID? = nil) {
        self.version = version; self.profiles = profiles; self.destinations = destinations
        self.defaultDestinationID = defaultDestinationID
    }

    private enum CodingKeys: String, CodingKey { case version, workspaces, profiles, destinations, defaultDestinationID, backgroundAudioDestinationID }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        workspaces = try c.decodeIfPresent([OutputWorkspaceRecord].self, forKey: .workspaces) ?? [.primary]
        profiles = try c.decode([OutputProfile].self, forKey: .profiles)
        destinations = try c.decode([OutputDestinationConfiguration].self, forKey: .destinations)
        // Missing means the old primary output. Explicit null means None and
        // must survive launches, migration and removal of the former default.
        defaultDestinationID = c.contains(.defaultDestinationID)
            ? try c.decodeIfPresent(UUID.self, forKey: .defaultDestinationID) : destinations.first?.id
        backgroundAudioDestinationID = try c.decodeIfPresent(UUID.self, forKey: .backgroundAudioDestinationID)
    }
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version); try c.encode(workspaces, forKey: .workspaces); try c.encode(profiles, forKey: .profiles)
        try c.encode(destinations, forKey: .destinations)
        try c.encode(defaultDestinationID, forKey: .defaultDestinationID)
        try c.encode(backgroundAudioDestinationID, forKey: .backgroundAudioDestinationID)
    }
}

nonisolated enum OutputProfileMigration {
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
    enum Kind { case empty, lyrics, text, video, pdf, image, capturedWindow }
    // Origin workspace of the accepted snapshot, including a privately retained
    // snapshot after output loss. OutputOwnership separately gates publication.
    var source: UUID?
    var kind: Kind = .empty
    var current = OutputTextContent.empty
    var next: OutputTextContent?
    var visible = true
    var revision: UInt64 = 0
    var documentRevision: UInt64 = 0
    // Native media references remain local to eucaly.
    var localMedia: Slide?
    var acceptedPDF: AcceptedPDFSource?
}

nonisolated extension OutputProfileDocument {
    var isValid: Bool {
        let network = destinations.compactMap(\.networkSettings)
        guard network.allSatisfy(\.isValid), Set(network.map(\.sourceID)).count == network.count,
              backgroundAudioDestinationID == nil || destinations.contains(where: { $0.id == backgroundAudioDestinationID && $0.isNetworkDestination }) else { return false }
        guard version == 7, (1...OutputWorkspaceRecord.legacyPersistenceLimit).contains(workspaces.count),
              Set(workspaces.map(\.id)).count == workspaces.count,
              workspaces.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.name.utf8.count <= 160 }),
              destinations.allSatisfy({ destination in destination.workspaceID == nil || workspaces.contains(where: { $0.id == destination.workspaceID }) }), (1...128).contains(profiles.count), destinations.count <= 16,
              Set(profiles.map(\.id)).count == profiles.count,
              Set(destinations.map(\.id)).count == destinations.count,
              profiles.contains(where: { $0.id == OutputProfile.audienceID }),
              destinations.allSatisfy({ destination in destination.name.utf8.count <= 160 && profiles.contains { $0.id == destination.profileID } }) else { return false }
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

nonisolated struct OutputDestinationStatus: Sendable {
    var id: UUID
    var name: String
    var profileID: UUID
    var readiness: OutputReadiness
}
