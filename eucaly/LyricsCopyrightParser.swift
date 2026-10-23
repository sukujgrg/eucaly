import Foundation

/// A separated paragraph containing a leading © line ends lyric content.
/// Its next blank ends credit metadata; all later source text remains protected.
/// Typed legacy attribution is supported without guessing unlabelled authors.
nonisolated enum LyricsCopyrightParser {
    static let explicitMarker = "[Copyright]"

    struct Footer: Equatable, Sendable {
        let startIndex: Int
        let metadata: [String: String]
    }

    private enum Kind {
        case song(String), license(String), licenseTerms, database(String), authors, creditNotice, copyright, rights, rightsWithLicense(String), publisher

        var isAnchor: Bool {
            switch self {
            case .song, .license, .licenseTerms, .database, .copyright, .rightsWithLicense: true
            default: false
            }
        }
    }

    static func footer(in lines: [String]) -> Footer? {
        let matching = lines.map(normalized)
        let paragraphs = paragraphRanges(in: lines)
        let symbolParagraphs = paragraphs.filter { range in
            !isStructuralStart(lines[range.lowerBound]) && range.contains { matching[$0].hasPrefix("©") }
        }
        let symbolIndexes = Set(symbolParagraphs.flatMap { $0 })
        let lyricEvidenceEnd = matching.firstIndex { $0.caseInsensitiveCompare(explicitMarker) == .orderedSame } ?? lines.count
        func hasEarlierLyrics(before end: Int) -> Bool {
            // A credit-only paragraph cannot become lyric evidence for another
            // credit paragraph, including text after an explicit credit marker.
            // The parser owns title/component interpretation.
            let body = (0..<min(end, lyricEvidenceEnd)).filter { index in
                !symbolIndexes.contains(index)
                    && !isMetadataLine(lines[index]) && !matching[index].hasPrefix("©")
            }.map { lines[$0] }
            return LyricsParser.hasPrimaryLyricsBeforeCopyright(in: body)
        }
        for paragraph in symbolParagraphs where paragraph.lowerBound > 0 && hasEarlierLyrics(before: paragraph.lowerBound) {
            // The first admitted © paragraph ends lyric content permanently.
            // Its first following blank ends metadata, not the source file.
            var boundary = paragraph.lowerBound
            if let marker = matching.indices.prefix(paragraph.upperBound).first(where: { index in
                guard matching[index].caseInsensitiveCompare(explicitMarker) == .orderedSame,
                      hasEarlierLyrics(before: index) else { return false }
                return index >= paragraph.lowerBound
                    || !lines[(index + 1)..<paragraph.lowerBound].contains(where: isStructuralStart)
            }) { boundary = min(boundary, marker) }
            // An earlier explicit marker already declared its preceding credit
            // paragraphs. Keep those credits through this © paragraph's end.
            let credits = boundary < paragraph.lowerBound ? (boundary + 1)..<paragraph.upperBound : paragraph
            return Footer(startIndex: boundary, metadata: metadata(in: lines, matching: matching, within: credits))
        }

        // Preserve explicit reviewed footers and typed legacy CCLI/attribution
        // formats when there is no admitted separated © paragraph.
        if let marker = matching.indices.first(where: { index in
            matching[index].caseInsensitiveCompare(explicitMarker) == .orderedSame
                && hasEarlierLyrics(before: index)
                && matching[(index + 1)...].contains(where: { !$0.isEmpty })
                && !lines[(index + 1)...].contains(where: isStructuralStart)
        }) {
            return Footer(startIndex: marker, metadata: metadata(in: lines, matching: matching, within: (marker + 1)..<lines.count))
        }
        let kinds = matching.map(kind)
        var start = lines.count
        while start > 0 {
            let candidate = start - 1
            if matching[candidate].isEmpty || kinds[candidate] != nil {
                start = candidate
            } else if candidate > 0, case .copyright? = kinds[candidate - 1], isCopyrightClaim(matching[candidate]) {
                start = candidate
            } else { break }
        }
        while start < lines.count, matching[start].isEmpty { start += 1 }
        guard start < lines.count,
              kinds[start...].contains(where: { $0?.isAnchor == true }), hasEarlierLyrics(before: start) else { return nil }
        if matching[start...].contains(where: { $0.hasPrefix("©") }) {
            // A copyright symbol alone does not guess an adjacent unseparated
            // lyric/companion boundary. Explicit legacy fields remain supported.
            guard kinds[start...].contains(where: { value in
                switch value {
                case .song, .license, .licenseTerms, .database, .authors, .creditNotice, .rightsWithLicense: true
                default: false
                }
            }) else { return nil }
        }
        return Footer(startIndex: start, metadata: metadata(in: lines, matching: matching, within: start..<lines.count))
    }

    private static func paragraphRanges(in lines: [String]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        var index = 0
        while index < lines.count {
            if LyricsTextSyntax.isBlank(lines[index]) { index += 1; continue }
            let start = index
            while index < lines.count, !LyricsTextSyntax.isBlank(lines[index]) { index += 1 }
            result.append(start..<index)
        }
        return result
    }

    private static func isStructuralStart(_ line: String) -> Bool {
        LyricsSectionCatalog.isHeading(line) || LyricsTextSyntax.isSeparator(line) || LyricsTextSyntax.explicitTitle(line) != nil
    }

    static func isMetadataLine(_ line: String) -> Bool {
        let matching = normalized(line)
        return kind(matching) != nil || matching.caseInsensitiveCompare(explicitMarker) == .orderedSame
    }

    private static func normalized(_ line: String) -> String {
        LyricsTextSyntax.markerText(line).trimmingCharacters(in: .whitespaces)
    }

    private static func kind(_ line: String) -> Kind? {
        if let type = capture(ccliNumber, in: line, group: 1), let number = capture(ccliNumber, in: line, group: 2) {
            return type.caseInsensitiveCompare("song") == .orderedSame ? .song(number) : .license(number)
        }
        if let permission = capture(inlineLicense, in: line, group: 1),
           rights.firstMatch(in: permission, range: NSRange(permission.startIndex..., in: permission)) != nil,
           let license = capture(inlineLicense, in: line, group: 2),
           let type = capture(ccliNumber, in: license, group: 1), type.caseInsensitiveCompare("song") != .orderedSame,
           let number = capture(ccliNumber, in: license, group: 2) { return .rightsWithLicense(number) }
        if let title = capture(creditNotice, in: line, group: 1),
           let authors = capture(creditNotice, in: line, group: 2),
           !title.trimmingCharacters(in: .whitespaces).isEmpty,
           !authors.trimmingCharacters(in: .whitespaces).isEmpty { return .creditNotice }
        if line.hasPrefix("©"), capture(verseViewID, in: line, group: 1) != nil { return .copyright }
        if let number = capture(verseViewID, in: line, group: 1),
           line.lowercased().hasPrefix("verseview") { return .database(number) }
        if copyrightWithYear.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { return .copyright }
        if authorLabel.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { return .authors }
        let lower = line.lowercased()
        if lower.hasPrefix("copyright:"), !line.dropFirst("copyright:".count).trimmingCharacters(in: .whitespaces).isEmpty { return .copyright }
        if lower.hasPrefix("license:") || lower.hasPrefix("licence:") {
            if !line.dropFirst("license:".count).trimmingCharacters(in: .whitespaces).isEmpty { return .licenseTerms }
        }
        if lower.hasPrefix("publisher:") || lower.hasPrefix("published by ") || lower.hasPrefix("administered by ") { return .publisher }
        if rights.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil { return .rights }
        if lower.hasPrefix("for use solely with"), lower.contains("songselect"),
           lower.contains("terms of use") || lower.contains("ccli.com") { return .rights }
        return nil
    }

    private static func metadata(in lines: [String], matching: [String], within range: Range<Int>) -> [String: String] {
        var values: [String: String] = [:]
        values["copyright-footer"] = range.filter { matching[$0].caseInsensitiveCompare(explicitMarker) != .orderedSame }
            .map { lines[$0] }.joined(separator: "\n").trimmingCharacters(in: .newlines)
        for index in range {
            let original = lines[index].trimmingCharacters(in: .whitespaces)
            guard !matching[index].isEmpty else { continue }
            // Generic © text is a field only after the boundary was admitted;
            // it does not broaden legacy matching of ordinary lyric lines.
            switch matching[index].hasPrefix("©") ? .copyright : kind(matching[index]) {
            case .song(let number): values["ccli-songnumber"] = number
            case .license(let number): values["ccli-licensenumber"] = number
            case .licenseTerms: append(original, to: "license", in: &values)
            case .database(let number): values["verseview-song-id"] = number
            case .authors:
                if let authors = sourceCapture(authorLabel, in: original, group: 1) {
                    append(authors.trimmingCharacters(in: .whitespaces), to: "authors", in: &values)
                }
            case .creditNotice:
                if let title = sourceCapture(creditNotice, in: original, group: 1),
                   let authors = sourceCapture(creditNotice, in: original, group: 2) {
                    append(title, to: "credit-song-title", in: &values)
                    append(authors.trimmingCharacters(in: .whitespaces), to: "authors", in: &values)
                }
            case .rightsWithLicense(let number):
                values["ccli-licensenumber"] = number
                if let permission = sourceCapture(inlineLicense, in: original, group: 1) {
                    append(permission, to: "rights", in: &values)
                }
            case .copyright:
                append(original, to: "copyright", in: &values)
                if let number = capture(verseViewID, in: matching[index], group: 1) { values["verseview-song-id"] = number }
            case .rights: append(original, to: "rights", in: &values)
            case .publisher: append(original, to: "publisher", in: &values)
            case nil:
                if isCopyrightClaim(matching[index]) { append(original, to: "copyright-claim", in: &values) }
            }
        }
        return values
    }

    private static func append(_ value: String, to key: String, in values: inout [String: String]) {
        values[key] = values[key].map { $0 + "\n" + value } ?? value
    }

    private static func isCopyrightClaim(_ line: String) -> Bool {
        let lower = line.lowercased()
        return lower.hasPrefix("copyright ") || lower.hasPrefix("(admin. by ") || lower.hasPrefix("admin. by ")
    }

    /// Match the shared marker comparison view while returning source text.
    /// Prefix punctuation is parsed by the expression, never an arbitrary colon
    /// in a song title or writer's name. Internal Unicode shaping stays intact.
    private static func sourceCapture(_ regex: NSRegularExpression, in line: String, group: Int) -> String? {
        var comparison: [Unicode.Scalar] = []
        var sourceSpans: [Range<String.Index>] = []
        for index in line.unicodeScalars.indices {
            let end = line.unicodeScalars.index(after: index)
            for scalar in LyricsTextSyntax.markerText(String(line.unicodeScalars[index])).unicodeScalars {
                comparison.append(scalar)
                sourceSpans.append(index..<end)
            }
        }
        guard let start = comparison.firstIndex(where: { $0.value != 0x20 }),
              let last = comparison.lastIndex(where: { $0.value != 0x20 }) else { return nil }
        let matching = String(String.UnicodeScalarView(comparison[start...last]))
        guard let match = regex.firstMatch(in: matching, range: NSRange(matching.startIndex..., in: matching)),
              group < match.numberOfRanges,
              let range = Range(match.range(at: group), in: matching), !range.isEmpty else { return nil }
        let lower = start + matching[..<range.lowerBound].unicodeScalars.count
        let upper = start + matching[..<range.upperBound].unicodeScalars.count - 1
        // Unemitted scalars immediately inside the capture's delimiters are
        // still part of the source field (for example a terminal shaping ZWJ).
        let sourceStart = lower > 0 ? sourceSpans[lower - 1].upperBound : line.startIndex
        let sourceEnd = upper + 1 < sourceSpans.count ? sourceSpans[upper + 1].lowerBound : line.endIndex
        return String(line[sourceStart..<sourceEnd])
    }

    private static func capture(_ regex: NSRegularExpression, in line: String, group: Int) -> String? {
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let range = Range(match.range(at: group), in: line) else { return nil }
        return String(line[range])
    }

    private static let ccliNumber = try! NSRegularExpression(
        pattern: "^CCLI[ \\t]+(Song|Licen[cs]e)[ \\t]*(?:(?:Number|No\\.?|#)[ \\t]*)?[:#]?[ \\t]*([0-9]+)\\.?$",
        options: .caseInsensitive)
    private static let inlineLicense = try! NSRegularExpression(
        pattern: "^(.+?)[ \\t]+(CCLI[ \\t]+.+)$", options: .caseInsensitive)
    private static let creditNotice = try! NSRegularExpression(
        pattern: "^[\"“‘'](.+)[\"”’'][ \\t]+Words[ \\t]+(?:and|&)[ \\t]+Music[ \\t]+by[ \\t]+(.+)$",
        options: .caseInsensitive)
    private static let verseViewID = try! NSRegularExpression(
        pattern: "VerseView[ \\t]+Song[ \\t]+Database[ \\t]+ID[ \\t]*[:#]?[ \\t]*([0-9]+)$",
        options: .caseInsensitive)
    private static let copyrightWithYear = try! NSRegularExpression(
        pattern: "^(?:©|\\(c\\)|Copyright(?:[ \\t]+©)?)[ \\t]*[0-9]{4}(?:[ \\t]*[-–,/][ \\t]*[0-9]{2,4})*(?:[ \\t]+.*)?$",
        options: .caseInsensitive)
    private static let authorLabel = try! NSRegularExpression(
        pattern: "^(?:Authors?[ \\t]*:[ \\t]*|(?:Written|Words(?:[ \\t]+(?:and|&)[ \\t]+Music)?|Music|Lyrics)[ \\t]+by[ \\t]+)(.+)$",
        options: .caseInsensitive)
    private static let rights = try! NSRegularExpression(
        pattern: "^(?:All rights reserved[.!]?(?:[ \\t]+(?:Used|Reproduced|Printed)[ \\t]+by[ \\t]+permission\\.?)*|(?:Used|Reproduced|Printed)[ \\t]+by[ \\t]+permission\\.?(?:[ \\t]+All rights reserved\\.?)?)$",
        options: .caseInsensitive)
}
