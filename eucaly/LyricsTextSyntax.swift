import Foundation

/// Shared comparison rules for parsing, section styling and Normalize Formatting.
/// The comparison view is deliberately stricter than cleanup of lyric content.
nonisolated enum LyricsTextSyntax {
    static func markerText(_ text: String) -> String {
        var output = String()
        output.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            if scalar.properties.isDefaultIgnorableCodePoint { continue }
            switch scalar.properties.generalCategory {
            case .format: continue
            case .control:
                if scalar.properties.isWhitespace { output.append(" ") }
            default:
                if scalar.properties.isWhitespace { output.append(" ") }
                else { output.unicodeScalars.append(scalar) }
            }
        }
        return output
    }

    static func isBlank(_ line: String) -> Bool {
        markerText(line).trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func isSeparator(_ line: String) -> Bool {
        let marker = markerText(line).trimmingCharacters(in: .whitespaces)
        return marker.utf8.count >= 3 && marker.utf8.allSatisfy { $0 == 0x2D }
    }

    static func explicitTitle(_ line: String) -> String? {
        let marker = markerText(line).trimmingCharacters(in: .whitespaces)
        guard marker.lowercased().hasPrefix("#title:") else { return nil }
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let title = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }

    static func format(_ text: String) -> String {
        let sourceLines = LyricsTextSanitizer.normalizeLineEndings(text).components(separatedBy: "\n")
        // Credit paragraphs and their terminating blank have parser meaning.
        // Keep that suffix intact, including any ignored text after the credits.
        let footerStart = LyricsCopyrightParser.footer(in: sourceLines)?.startIndex
        let body = sourceLines.prefix(footerStart ?? sourceLines.count).joined(separator: "\n")
        let lines = LyricsTextSanitizer.clean(body).components(separatedBy: "\n")
        // A blank after a companion heading can separate unheaded slides.
        // Reuse the parser's source spans rather than guessing those boundaries.
        let stanzaStarts = Set(LyricsParser.stanzaRangesForCleanup(lines, protected: []).map(\.lowerBound))
        var output: [String] = []
        var pendingBlank = false
        for (index, source) in lines.enumerated() {
            let line = source.trimmingCharacters(in: .whitespaces)
            if isBlank(line) { pendingBlank = !output.isEmpty; continue }

            let separator = isSeparator(line)
            let header = LyricsSectionCatalog.canonicalHeaderLine(line)
                ?? LyricsSectionCatalog.canonicalCompanionHeaderLine(line)
            let followsHeading = output.last.map { LyricsSectionCatalog.isHeading($0) } ?? false
            let keepsBlank = pendingBlank && (!followsHeading || stanzaStarts.contains(index))
            if !output.isEmpty, keepsBlank || separator || header != nil || output.last == "---" {
                output.append("")
            }
            output.append(separator ? "---" : header ?? line)
            pendingBlank = false
        }
        if let footerStart {
            if !output.isEmpty { output.append("") }
            output.append(contentsOf: sourceLines[footerStart...])
        }
        return output.joined(separator: "\n")
    }
}
