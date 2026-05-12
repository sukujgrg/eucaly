import Foundation
import CoreGraphics

nonisolated enum SectionKind: String, CaseIterable, Identifiable {
    case verse = "Verse"
    case chorus = "Chorus"
    case preChorus = "Pre-Chorus"
    case bridge = "Bridge"
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
        ("verse", .verse),
        ("vers", .verse),
        ("strophe", .verse),
        ("chorus", .chorus),
        ("refrain", .chorus),
        ("pre-chorus", .preChorus),
        ("prechorus", .preChorus),
        ("pre", .preChorus),
        ("bridge", .bridge),
        ("tag", .tag)
    ]

    static func parseHeader(_ line: String) -> HeaderMatch? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let tokens = trimmed
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard let firstToken = tokens.first else { return nil }

        let first = firstToken
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .lowercased()

        if first == "meaning" {
            return HeaderMatch(kind: .tag, label: "Meaning", isMeaning: true)
        }

        guard let kind = sectionKind(for: first) else { return nil }

        var label = kind.rawValue
        if tokens.count > 1 {
            let second = tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            if Int(second) != nil {
                label += " \(second)"
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
