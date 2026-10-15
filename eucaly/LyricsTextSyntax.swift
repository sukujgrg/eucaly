import Foundation

/// Shared comparison rules for the parser, section styling and Format action.
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
        let lines = LyricsTextSanitizer.clean(text).split(separator: "\n", omittingEmptySubsequences: false)
        var output: [String] = []
        var pendingBlank = false
        for source in lines {
            let line = String(source).trimmingCharacters(in: .whitespaces)
            if isBlank(line) { pendingBlank = !output.isEmpty; continue }

            let separator = isSeparator(line)
            let header = LyricsSectionCatalog.canonicalHeaderLine(line)
                ?? LyricsSectionCatalog.canonicalCompanionHeaderLine(line)
            if !output.isEmpty, pendingBlank || separator || header != nil || output.last == "---" {
                output.append("")
            }
            output.append(separator ? "---" : header ?? line)
            pendingBlank = false
        }
        return output.joined(separator: "\n")
    }
}
