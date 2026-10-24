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

    init(sourceName: String = "eucaly") { self.sourceName = sourceName }
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name == name.trimmingCharacters(in: .whitespacesAndNewlines) && name.utf8.count <= 120
            && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || "\\/:*?\"<>|".unicodeScalars.contains($0) }
    }
    var normalizedName: String { sourceName.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")) }
    var isValid: Bool {
        Self.validName(sourceName) && width == 1920 && height == 1080 && frameRateNumerator == 30 && frameRateDenominator == 1
    }
    /// A key/appearance edit is live; identity, name or format needs a new sender.
    func requiresRestart(comparedTo other: Self) -> Bool {
        sourceID != other.sourceID || sourceName != other.sourceName
            || width != other.width || height != other.height
            || frameRateNumerator != other.frameRateNumerator || frameRateDenominator != other.frameRateDenominator
    }
}
