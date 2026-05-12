import Foundation
import CoreGraphics

nonisolated enum SectionKind: String, CaseIterable, Identifiable {
    case intro = "Intro"
    case verse = "Verse"
    case chorus = "Chorus"
    case preChorus = "Pre-Chorus"
    case postChorus = "Post-Chorus"
    case bridge = "Bridge"
    case instrumental = "Instrumental"
    case vamp = "Vamp"
    case coda = "Coda"
    case ending = "Ending"
    case outro = "Outro"
    case tag = "Tag"

    var id: String { rawValue }
}

nonisolated enum LyricsSectionCatalog {
    struct HeaderMatch {
        let kind: SectionKind
        let label: String
        let isMeaning: Bool
    }

    private static let aliases: [(String, SectionKind)] = [
        ("intro", .intro),
        ("verse", .verse),
        ("vers", .verse),
        ("strophe", .verse),
        ("chorus", .chorus),
        ("refrain", .chorus),
        ("hook", .chorus),
        ("pre-chorus", .preChorus),
        ("pre chorus", .preChorus),
        ("prechorus", .preChorus),
        ("pre", .preChorus),
        ("post-chorus", .postChorus),
        ("bridge", .bridge),
        ("instrumental", .instrumental),
        ("vamp", .vamp),
        ("coda", .coda),
        ("ending", .ending),
        ("outro", .outro),
        ("tag", .tag)
    ]

    static func parseHeader(_ line: String) -> HeaderMatch? {
        let trimmed = normalizedHeaderLine(line)
        guard !trimmed.isEmpty else { return nil }

        let tokens = trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard let firstToken = tokens.first else { return nil }

        let first = normalizedHeaderToken(firstToken)

        if first == "meaning" {
            return HeaderMatch(kind: .tag, label: "Meaning", isMeaning: true)
        }

        let twoWordKey: String? = {
            guard tokens.count > 1 else { return nil }
            let second = normalizedHeaderToken(tokens[1])
            guard Int(second) == nil else { return nil }
            return "\(first) \(second)"
        }()

        let key = twoWordKey ?? first
        guard let kind = sectionKind(for: key) else { return nil }

        var label = kind.rawValue
        let numberTokenIndex = twoWordKey == nil ? 1 : 2
        if tokens.indices.contains(numberTokenIndex) {
            let numberToken = normalizedHeaderToken(tokens[numberTokenIndex])
            if Int(numberToken) != nil {
                label += " \(numberToken)"
            }
        }

        return HeaderMatch(kind: kind, label: label, isMeaning: false)
    }

    static func isHeader(_ line: String) -> Bool {
        parseHeader(line) != nil
    }

    static func canonicalHeaderLine(_ line: String) -> String? {
        guard let match = parseHeader(line) else { return nil }
        return match.label
    }

    private static func normalizedHeaderToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .lowercased()
    }

    private static func normalizedHeaderLine(_ line: String) -> String {
        var trimmed = line
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.first == "[", trimmed.last == "]" {
            trimmed.removeFirst()
            trimmed.removeLast()
            trimmed = trimmed
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed
    }

    private static func sectionKind(for key: String) -> SectionKind? {
        for (alias, kind) in aliases where key == alias {
            return kind
        }
        return nil
    }
}

nonisolated struct SlideLine: Identifiable, Hashable {
    let id = UUID()
    let kind: SectionKind
    let languageTag: String
    let text: String

    var title: String {
        languageTag.isEmpty ? "\(kind.rawValue)" : "\(kind.rawValue) \(languageTag)"
    }
}

nonisolated struct Slide: Identifiable {
    let id = UUID()
    let index: Int
    let lines: [SlideLine]
    let label: String?
    let videoURL: URL?
    let pdfURL: URL?
    let pdfPageIndex: Int?
    let imageURL: URL?
    let webpageURL: URL?
    let webpageNavigationRevision: Int
    let captureWindowID: CGWindowID?

    var title: String { label ?? "Slide \(index)" }

    init(
        index: Int,
        lines: [SlideLine],
        label: String?,
        videoURL: URL?,
        pdfURL: URL?,
        pdfPageIndex: Int?,
        imageURL: URL?,
        webpageURL: URL? = nil,
        webpageNavigationRevision: Int = 0,
        captureWindowID: CGWindowID? = nil
    ) {
        self.index = index
        self.lines = lines
        self.label = label
        self.videoURL = videoURL
        self.pdfURL = pdfURL
        self.pdfPageIndex = pdfPageIndex
        self.imageURL = imageURL
        self.webpageURL = webpageURL
        self.webpageNavigationRevision = webpageNavigationRevision
        self.captureWindowID = captureWindowID
    }
}

nonisolated struct LyricsDocument {
    var slides: [Slide]
    var metadata: [String: String] = [:]
}
