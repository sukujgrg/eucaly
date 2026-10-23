import Foundation

/// One source of names for the library and the new-lyrics save panel.
/// Only the bounded prefix is inspected; lyric content is never rewritten.
nonisolated enum LyricsFileNaming {
    static let sourceByteLimit = 8192

    static func title(from source: String, fileName: String? = nil) -> String? {
        let prefix = sourcePrefix(Data(source.utf8.prefix(sourceByteLimit)))
        let document = LyricsParser.parseDocument(prefix, fileName: fileName)
        if let title = document.metadata["title"] {
            return formattedAuthoredTitle(title)
        }
        for slide in document.slides {
            for component in slide.lines where component.languageTag.isEmpty {
                guard let line = component.text.split(separator: "\n", omittingEmptySubsequences: false)
                    .first(where: { !LyricsTextSyntax.isBlank(String($0)) }) else { continue }
                return line.split(whereSeparator: \.isWhitespace).prefix(6).joined(separator: " ")
            }
        }
        return nil
    }

    static func suggestedFileName(from source: String, fileName: String? = nil) -> String {
        guard let title = title(from: source, fileName: fileName) else { return "Untitled" }
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = title.components(separatedBy: invalid).joined(separator: " ")
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? "Untitled" : collapsed
    }

    /// Legacy rows stored the title-marker line. A filename fallback is not a
    /// marker; current-version rows bypass this compatibility projection.
    static func legacyCachedTitle(_ source: String, fileName: String) -> String {
        guard source != fileName, let title = LyricsTextSyntax.explicitTitle(source) else { return source }
        return formattedAuthoredTitle(title)
    }

    static func sourcePrefix(_ bytes: Data) -> String {
        var end = min(bytes.count, sourceByteLimit)
        while end > 0 {
            if let text = String(data: bytes.prefix(end), encoding: .utf8) { return text }
            end -= 1
        }
        return ""
    }

    private static func formattedAuthoredTitle(_ raw: String) -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = title.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty, title == title.localizedLowercase else { return title }
        return title.localizedCapitalized
    }
}
