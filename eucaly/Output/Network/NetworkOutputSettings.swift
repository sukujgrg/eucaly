import Foundation

/// The network protocol belongs to a saved destination, independently of its
/// workspace, appearance and live sender generation.
nonisolated enum NetworkOutputTechnology: String, Codable, CaseIterable, Sendable {
    case ndi, omt
    var title: String { self == .ndi ? "NDI" : "OMT" }
}

/// Common source identity, format and transparency. The saved destination's
/// enum case selects its protocol without changing this persisted payload.
nonisolated struct NetworkOutputSettings: Codable, Equatable, Sendable {
    enum KeyMode: String, Codable, CaseIterable, Sendable { case alpha, chroma }
    var sourceID = UUID()
    var sourceName: String
    var width = 1920
    var height = 1080
    var frameRateNumerator = 30
    var frameRateDenominator = 1
    var keyMode: KeyMode = .alpha
    /// Chroma key colour for this destination. Retained while Alpha is selected.
    var keyColour = OutputColour.chromaGreen

    init(sourceName: String = "eucaly") { self.sourceName = sourceName }

    private enum CodingKeys: String, CodingKey {
        case sourceID, sourceName, width, height, frameRateNumerator, frameRateDenominator, keyMode, keyColour
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceID = try c.decode(UUID.self, forKey: .sourceID)
        sourceName = try c.decode(String.self, forKey: .sourceName)
        width = try c.decode(Int.self, forKey: .width)
        height = try c.decode(Int.self, forKey: .height)
        frameRateNumerator = try c.decode(Int.self, forKey: .frameRateNumerator)
        frameRateDenominator = try c.decode(Int.self, forKey: .frameRateDenominator)
        keyMode = try c.decodeIfPresent(KeyMode.self, forKey: .keyMode) ?? .alpha
        keyColour = try c.decodeIfPresent(OutputColour.self, forKey: .keyColour) ?? .chromaGreen
    }

    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name == name.trimmingCharacters(in: .whitespacesAndNewlines) && name.utf8.count <= 120
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || "\\/:*?\"<>|".unicodeScalars.contains($0) }
    }
    var normalizedName: String { sourceName.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
    var isValid: Bool {
        Self.validName(sourceName) && width == 1920 && height == 1080 && frameRateNumerator == 30 && frameRateDenominator == 1
            && [keyColour.red, keyColour.green, keyColour.blue, keyColour.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    /// A key/appearance edit is live; identity, name or format needs a new sender.
    func requiresRestart(comparedTo other: Self) -> Bool {
        sourceID != other.sourceID || sourceName != other.sourceName
            || width != other.width || height != other.height
            || frameRateNumerator != other.frameRateNumerator || frameRateDenominator != other.frameRateDenominator
    }
}
