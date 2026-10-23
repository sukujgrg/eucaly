import Foundation

/// A typed model plan still passes a final parser-level conservation check.
/// Only source-matched spelling patches are reflected in the trusted baseline.
nonisolated enum LyricsCleanupValidation {
    static func validate(_ candidate: String, against baseline: String, original: String, options: LyricsCleanupOptions) throws {
        guard candidate.utf8.count <= max(8_000, baseline.utf8.count * 2), !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LyricsCleanupModelError.invalidSuggestion("the result was empty or unexpectedly long.")
        }
        guard LyricsParser.parseDocument(candidate, fileName: options.sourceFileName).metadata == LyricsParser.parseDocument(baseline, fileName: options.sourceFileName).metadata,
              protectedLines(candidate, fileName: options.sourceFileName) == protectedLines(baseline, fileName: options.sourceFileName) else {
            throw LyricsCleanupModelError.invalidSuggestion("title or copyright information changed.")
        }
        guard signature(candidate, options: options) == signature(baseline, options: options) else {
            throw LyricsCleanupModelError.invalidSuggestion("lyric words, punctuation or repetitions changed.")
        }
        if !options.naturalLyricCasing,
           signature(candidate, options: options, foldCase: false) != signature(baseline, options: options, foldCase: false) {
            throw LyricsCleanupModelError.invalidSuggestion("capitalization changed while natural lyric casing was disabled.")
        }
        if !options.suggestSections, structuralLines(candidate, fileName: options.sourceFileName) != structuralLines(baseline, fileName: options.sourceFileName) {
            throw LyricsCleanupModelError.invalidSuggestion("section headings changed while section suggestions were disabled.")
        }
        if !options.repairLineBreaks, bodyLines(candidate, fileName: options.sourceFileName).map({ options.naturalLyricCasing ? $0.lowercased() : $0 })
            != bodyLines(baseline, fileName: options.sourceFileName).map({ options.naturalLyricCasing ? $0.lowercased() : $0 }) {
            throw LyricsCleanupModelError.invalidSuggestion("lyric line breaks changed while PDF repairs were disabled.")
        }
        let originalHeaders = structuralLines(original, fileName: options.sourceFileName).filter { !LyricsTextSyntax.isSeparator($0) }
        let candidateHeaders = structuralLines(candidate, fileName: options.sourceFileName)
        var cursor = 0
        for header in originalHeaders {
            guard let next = candidateHeaders.indices.dropFirst(cursor).first(where: { candidateHeaders[$0] == header }) else {
                throw LyricsCleanupModelError.invalidSuggestion("an existing section or companion heading changed.")
            }
            cursor = next + 1
        }
        let beforeSlides = LyricsParser.parseDocument(baseline, fileName: options.sourceFileName).slides
        let afterSlides = LyricsParser.parseDocument(candidate, fileName: options.sourceFileName).slides
        guard boundaryOffsets(beforeSlides, options: options).isSubset(of: boundaryOffsets(afterSlides, options: options)) else {
            throw LyricsCleanupModelError.invalidSuggestion("an existing stanza boundary was lost.")
        }
        guard companionAnchors(beforeSlides, options: options) == companionAnchors(afterSlides, options: options) else {
            throw LyricsCleanupModelError.invalidSuggestion("companion text moved away from its original lyric stanza.")
        }
        let beforeLord = bodyLines(baseline, fileName: options.sourceFileName).reduce(0) { $0 + wholeWordCount("LORD", in: $1) }
        let afterLord = bodyLines(candidate, fileName: options.sourceFileName).reduce(0) { $0 + wholeWordCount("LORD", in: $1) }
        guard beforeLord == afterLord else {
            throw LyricsCleanupModelError.invalidSuggestion("the intentional LORD spelling changed.")
        }
    }

    /// Small mechanical errors only: one edit, an adjacent transposition, or two
    /// edits in a longer word. Three-letter words permit adjacent swaps only.
    /// A native dictionary check independently confirms
    /// that the source is misspelled and the proposed word is accepted English.
    static func isSmallSpellingCorrection(_ before: String, _ after: String) -> Bool {
        guard before != after, before.count >= 3, before.count <= 30, after.count >= 3, after.count <= 30,
              before.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil,
              after.range(of: "^[A-Za-z]+$", options: .regularExpression) != nil else { return false }
        let a = Array(before.lowercased()), b = Array(after.lowercased())
        guard a != b, abs(a.count - b.count) <= 1 else { return false }
        if a.count == b.count {
            let differences = a.indices.filter { a[$0] != b[$0] }
            if differences.count == 2, differences[1] == differences[0] + 1,
               a[differences[0]] == b[differences[1]], a[differences[1]] == b[differences[0]] { return true }
        }
        guard a.count >= 4, b.count >= 4 else { return false }
        var previous = Array(0...b.count)
        for (index, left) in a.enumerated() {
            var row = [index + 1]
            for (column, right) in b.enumerated() {
                row.append(min(row[column] + 1, previous[column + 1] + 1, previous[column] + (left == right ? 0 : 1)))
            }
            previous = row
        }
        return previous[b.count] <= (max(a.count, b.count) >= 8 ? 2 : 1)
    }

    static func preservesCaseStyle(_ before: String, _ after: String) -> Bool {
        if before == before.lowercased() { return after == after.lowercased() }
        if before == before.uppercased() { return after == after.uppercased() }
        if before == before.prefix(1).uppercased() + before.dropFirst().lowercased() {
            return after == after.prefix(1).uppercased() + after.dropFirst().lowercased()
        }
        return false
    }

    static func preservesAuthoredLordCase(_ before: String, _ after: String) -> Bool {
        let source = LyricsCleanupEngine.casingWordRanges(in: before).map { String(before[$0]) }
        let candidate = LyricsCleanupEngine.casingWordRanges(in: after).map { String(after[$0]) }
        guard source.count == candidate.count else { return false }
        for (original, replacement) in zip(source, candidate) {
            let word = original.lowercased()
            if word == "lord" || word.hasPrefix("lord'") || word.hasPrefix("lord’") {
                let style = String(original.prefix(4))
                if style == "LORD" || style == "Lord", replacement.prefix(4) != original.prefix(4) { return false }
            }
        }
        return true
    }

    /// The shared local casing pass retains every source grapheme and layout
    /// position. No model text or case classification reaches this boundary.
    static func validateCasing(_ candidate: String, against source: String) throws {
        guard candidate.utf8.count <= max(8_000, source.utf8.count * 4),
              LyricsCleanupEngine.isSafeCasingChange(source, candidate),
              candidate.lowercased() == source.lowercased(),
              preservesAuthoredLordCase(source, candidate) else {
            throw LyricsCleanupModelError.invalidSuggestion("a casing edit changed source content, layout or intentional LORD spelling.")
        }
    }

    private static func protectedLines(_ text: String, fileName: String?) -> [String] {
        let lines = LyricsCleanupEngine.lines(in: text)
        return LyricsCleanupEngine.protectedIndexes(in: text, fileName: fileName).sorted().map { lines[$0] }.filter { !LyricsTextSyntax.isBlank($0) }
    }

    private static func structuralLines(_ text: String, fileName: String?) -> [String] {
        let lines = LyricsCleanupEngine.lines(in: text)
        let protected = LyricsCleanupEngine.protectedIndexes(in: text, fileName: fileName)
        return lines.enumerated().compactMap { index, line in
            guard !protected.contains(index) else { return nil }
            if LyricsTextSyntax.isSeparator(line) { return "---" }
            return LyricsSectionCatalog.canonicalHeaderLine(line) ?? LyricsSectionCatalog.canonicalCompanionHeaderLine(line)
        }
    }

    private static func bodyLines(_ text: String, fileName: String?) -> [String] {
        let lines = LyricsCleanupEngine.lines(in: text)
        let protected = LyricsCleanupEngine.protectedIndexes(in: text, fileName: fileName)
        return lines.enumerated().compactMap { index, line in
            guard !protected.contains(index), !LyricsTextSyntax.isBlank(line),
                  !LyricsTextSyntax.isSeparator(line), !LyricsSectionCatalog.isHeading(line) else { return nil }
            return line
        }
    }

    private static func signature(_ text: String, options: LyricsCleanupOptions, foldCase: Bool = true) -> String {
        compact(bodyLines(text, fileName: options.sourceFileName).joined(separator: "\n"), options: options, foldCase: foldCase)
    }

    private static func compact(_ text: String, options: LyricsCleanupOptions, foldCase: Bool = true) -> String {
        let content = text.filter { !$0.isWhitespace }
        return foldCase ? content.lowercased() : content
    }

    private static func boundaryOffsets(_ slides: [Slide], options: LyricsCleanupOptions) -> Set<Int> {
        var total = 0
        var offsets = Set<Int>()
        for slide in slides {
            total += slide.lines.reduce(0) { $0 + compact($1.text, options: options).count }
            offsets.insert(total)
        }
        return offsets
    }

    private static func companionAnchors(_ slides: [Slide], options: LyricsCleanupOptions) -> [[String]] {
        slides.compactMap { slide in
            let companions = slide.lines.filter { !$0.languageTag.isEmpty }
            guard !companions.isEmpty else { return nil }
            let primary = slide.lines.filter { $0.languageTag.isEmpty }.map { compact($0.text, options: options) }.joined()
            return [primary] + companions.flatMap { [$0.languageTag, $0.text] }
        }
    }

    private static func wholeWordCount(_ word: String, in text: String) -> Int {
        let regex = try! NSRegularExpression(pattern: "(?<![\\p{L}\\p{M}])\(NSRegularExpression.escapedPattern(for: word))(?![\\p{L}\\p{M}])")
        return regex.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }
}
