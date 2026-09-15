import Foundation

nonisolated enum PresentationLyricsLayout: String, CaseIterable, Identifiable {
    case stacked
    case columns

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stacked: return "Stacked"
        case .columns: return "Columns"
        }
    }

    func blocks(for lines: [SlideLine]) -> [LyricsTextBlock] {
        let nonemptyLines = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        switch self {
        case .stacked:
            return nonemptyLines.map { line in
                LyricsTextBlock(
                    id: line.id,
                    text: line.text,
                    companion: LyricsSectionCatalog.parseCompanionHeader(line.languageTag)
                )
            }
        case .columns:
            let groups = Dictionary(grouping: nonemptyLines) {
                LyricsSectionCatalog.parseCompanionHeader($0.languageTag)
            }
            let order: [LyricsSectionCatalog.CompanionKind?] = [nil]
                + LyricsSectionCatalog.CompanionKind.allCases.map { Optional($0) }
            return order.compactMap { companion in
                guard let lines = groups[companion], let first = lines.first else { return nil }
                return LyricsTextBlock(
                    id: first.id,
                    text: lines.map(\.text).joined(separator: "\n\n"),
                    companion: companion
                )
            }
        }
    }
}

nonisolated struct LyricsTextBlock: Identifiable {
    let id: UUID
    let text: String
    let companion: LyricsSectionCatalog.CompanionKind?

    var isMeaning: Bool { companion == .meaning }

    var relativeFontSize: Double { isMeaning ? 0.5 : 1 }
}
