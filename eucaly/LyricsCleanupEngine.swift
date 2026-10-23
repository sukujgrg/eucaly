import Foundation
import NaturalLanguage

nonisolated struct LyricsCleanupOptions: Equatable, Sendable {
    var cleanCharacters = true
    var suggestSections = true
    var naturalLyricCasing = true
    var repairLineBreaks = true
    var removeAnnotations = false
    var correctSpelling = true
    var identifyCopyright = true
    var sourceFileName: String? = nil
}

nonisolated enum LyricsCleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case characters, sections, casing, lineBreaks, annotations, spelling, copyright

    var id: String { rawValue }
    var title: String {
        switch self {
        case .characters: "Character cleanup"
        case .sections: "Section suggestions"
        case .casing: "Natural lyric casing"
        case .lineBreaks: "PDF line breaks and split words"
        case .annotations: "Remove non-lyric annotations"
        case .spelling: "Clear spelling errors"
        case .copyright: "Licence and copyright"
        }
    }
}

nonisolated struct LyricsCleanupChange: Identifiable, Equatable, Sendable {
    let id: UUID
    let category: LyricsCleanupCategory
    let summary: String
    let before: String
    let after: String

    init(category: LyricsCleanupCategory, summary: String, before: String, after: String) {
        id = UUID()
        self.category = category
        self.summary = summary
        self.before = before
        self.after = after
    }
}

nonisolated struct LyricsCleanupResult: Equatable, Sendable {
    let original: String
    let proposed: String
    let changes: [LyricsCleanupChange]
    let notes: [String]
    var hasChanges: Bool { original != proposed }
}

/// Produces a review draft. Nothing here writes a file or mutates Preview/Current.
/// Interpretive operations remain suggestions even when the rule is deterministic.
nonisolated enum LyricsCleanupEngine {
    static func clean(_ source: String, options: LyricsCleanupOptions = .init()) -> LyricsCleanupResult {
        var text = source
        var changes: [LyricsCleanupChange] = []
        var notes: [String] = []

        if options.identifyCopyright, let footer = LyricsCopyrightParser.footer(in: lines(in: source)) {
            notes.append("Recognized licence or copyright credits from line \(footer.startIndex + 1). The original credit text stays in the file and is excluded from lyric slides.")
        }

        func apply(_ category: LyricsCleanupCategory, _ summary: String, _ transform: (String) -> String) {
            let before = text
            text = transform(text)
            if before != text {
                changes.append(.init(category: category, summary: summary, before: before, after: text))
            }
        }

        if options.cleanCharacters {
            apply(.characters, "Clean pasted characters, spaces and recoverable encoding artifacts.") { cleanCharacters($0, fileName: options.sourceFileName) }
        }
        if options.removeAnnotations {
            apply(.annotations, "Remove recognizable chords, web links and performance annotations.") { removeAnnotations($0, fileName: options.sourceFileName) }
        }
        if options.repairLineBreaks {
            apply(.lineBreaks, "Join hyphen-wrapped lines and short continuations of long PDF lines.") { repairLineBreaks($0, fileName: options.sourceFileName) }
            if changes.contains(where: { $0.category == .lineBreaks }) {
                notes.append("Line-wrap repairs retain source hyphens. Analyze with Apple Intelligence to distinguish split-word hyphens from compound words; review intentional lyric line breaks.")
            }
        }
        if options.suggestSections {
            apply(.sections, "Label unheaded stanzas; suggest Chorus for repeated stanzas.") { suggestSections($0, fileName: options.sourceFileName) }
            if changes.contains(where: { $0.category == .sections }) {
                notes.append("Section names are suggestions. Repeated stanzas may be verses rather than a chorus; every occurrence is retained.")
            }
        }
        if options.naturalLyricCasing {
            let casing = lyricCasingDraft(text, fileName: options.sourceFileName)
            text = casing.proposed
            changes += casing.changes
            notes += casing.notes
        }
        if source.contains("�") {
            notes.append("The replacement character � marks text already lost during decoding. It was retained so you can repair the original word.")
        }
        if !options.removeAnnotations, containsAnnotations(text, fileName: options.sourceFileName) {
            notes.append("Possible chords or non-lyric annotations were found. Enable Remove non-lyric annotations to review their removal.")
        }
        if options.correctSpelling {
            notes.append("Contextual spelling corrections require Apple Intelligence. Standard cleanup preserves lyric spelling.")
        }
        if hasUncertainWrapping(text, fileName: options.sourceFileName) {
            notes.append("Some long lines may contain PDF wrapping. Their boundaries are uncertain; review them or Analyze with Apple Intelligence.")
        }
        return LyricsCleanupResult(original: source, proposed: text, changes: changes, notes: notes)
    }

    static func lines(in text: String) -> [String] {
        LyricsTextSanitizer.normalizeLineEndings(text).components(separatedBy: "\n")
    }

    static func protectedIndexes(in text: String, fileName: String? = nil) -> Set<Int> {
        LyricsParser.protectedLineIndexesForCleanup(text, fileName: fileName)
    }

    /// Primary words are used for language and casing decisions; companion text
    /// retains its own spelling, case and association with the source stanza.
    static func primaryText(in text: String, fileName: String? = nil) -> String {
        let input = lines(in: text)
        let protected = protectedIndexes(in: text, fileName: fileName)
        return stanzaRanges(input, protected: protected).flatMap { range in
            primaryIndexes(in: range, lines: input, protected: protected).map { input[$0] }
        }.joined(separator: "\n")
    }

    static func isEnglish(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        // A Latin title must not cause a Malayalam/English or other mixed lyric
        // to be lowercased. Combining accents remain valid Latin spelling.
        guard text.range(of: "[\\p{L}&&[^\\p{Latin}]]", options: .regularExpression) == nil else { return false }
        if NLLanguageRecognizer.dominantLanguage(for: text) == .english { return true }
        let words = Set(wordMatches(text).map { String(text[$0]).lowercased() })
        return words.intersection(["the", "and", "we", "you", "your", "our", "with", "sing", "praise", "grace"]).count >= 2
    }

    private static func cleanCharacters(_ text: String, fileName: String?) -> String {
        let input = lines(in: text)
        let protected = protectedIndexes(in: text, fileName: fileName)
        return input.enumerated().map { index, line in
            guard !protected.contains(index) else { return line }
            let encodingRepairs = [
                "â€™": "’", "â€˜": "‘", "â€œ": "“", "â€\u{009D}": "”",
                "â€“": "–", "â€”": "—", "â€¦": "…", "Â ": " "
            ]
            let repaired = replacingMatches(in: line,
                pattern: encodingRepairs.keys.map(NSRegularExpression.escapedPattern(for:)).sorted().joined(separator: "|"),
                transform: { encodingRepairs[$0] ?? $0 })
            var cleaned = LyricsTextSanitizer.clean(repaired)
            // Replace only recognized, complete references in one pass. Nested
            // escaped markup remains literal and is not recursively decoded.
            cleaned = replacingMatches(in: cleaned, pattern: "&(?:amp;(?!#?[A-Za-z0-9]+;)|(?:nbsp|lt|gt|#160|#x[Aa]0);)", transform: { match in
                switch match {
                case "&amp;": "&"
                case "&lt;": "<"
                case "&gt;": ">"
                default: " "
                }
            })
            return cleaned.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    private static func removeAnnotations(_ text: String, fileName: String?) -> String {
        let input = lines(in: text)
        let protected = protectedIndexes(in: text, fileName: fileName)
        return input.enumerated().compactMap { index, line -> String? in
            guard !protected.contains(index), !LyricsSectionCatalog.isHeading(line), !LyricsTextSyntax.isSeparator(line) else { return line }
            if isAnnotationLine(line) { return nil }
            var cleaned = replacingMatches(in: line, pattern: "\\[(?:[A-G](?:#|b)?(?:m|maj|min|sus|dim|aug|add)?[0-9]*(?:/[A-G](?:#|b)?)?)\\]", transform: { _ in "" })
            cleaned = replacingMatches(in: cleaned, pattern: "</?(?:b|i|em|strong|span)(?:[ \\t]+[^<>]*)?>", transform: { _ in "" })
            return cleaned.trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }

    private static func containsAnnotations(_ text: String, fileName: String?) -> Bool {
        let input = lines(in: text)
        let protected = protectedIndexes(in: text, fileName: fileName)
        return input.enumerated().contains { index, line in
            !protected.contains(index) && !LyricsSectionCatalog.isHeading(line)
                && (isAnnotationLine(line) || line.range(of: "\\[[A-G](?:#|b)?(?:m|maj|min|sus|dim|aug|add)?[0-9]*(?:/[A-G](?:#|b)?)?\\]", options: .regularExpression) != nil)
        }
    }

    private static func isAnnotationLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        if trimmed.range(of: "^(?:https?://|www\\.)\\S+$", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if trimmed.range(of: "^Page[ \\t]+[0-9]+(?:[ \\t]+of[ \\t]+[0-9]+)?$", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if trimmed.range(of: "^(?:\\(|\\[)[ \\t]*(?:repeat(?:[ \\t]+(?:chorus|verse|bridge))?(?:[ \\t]+(?:x?[0-9]+|twice|once|times))*|instrumental|guitar solo|piano solo)[ \\t]*(?:\\)|\\])$", options: [.regularExpression, .caseInsensitive]) != nil { return true }
        let tokens = trimmed.split(whereSeparator: { $0.isWhitespace || $0 == "|" })
        return tokens.count >= 2 && tokens.allSatisfy {
            $0.range(of: "^[A-G](?:#|b)?(?:m|maj|min|sus|dim|aug|add)?[0-9]*(?:/[A-G](?:#|b)?)?$", options: .regularExpression) != nil
        }
    }

    private static func repairLineBreaks(_ text: String, fileName: String?) -> String {
        let input = lines(in: text)
        let protected = protectedIndexes(in: text, fileName: fileName)
        var output: [String] = []
        var index = 0
        while index < input.count {
            var current = input[index]
            let start = index
            while index + 1 < input.count {
                let next = input[index + 1]
                guard !protected.contains(index), !protected.contains(index + 1),
                      !LyricsTextSyntax.isBlank(current), !LyricsTextSyntax.isBlank(next),
                      !LyricsSectionCatalog.isHeading(current), !LyricsSectionCatalog.isHeading(next),
                      !LyricsTextSyntax.isSeparator(current), !LyricsTextSyntax.isSeparator(next) else { break }
                let hyphenSplit = current.range(of: "[A-Za-z]{2,}-$", options: .regularExpression) != nil
                    && next.range(of: "^[a-z]{2,}", options: .regularExpression) != nil
                let orphanContinuation = index == start && current.count >= 70 && current.count <= 110
                    && next.count <= 24 && next.range(of: "^[a-z]", options: .regularExpression) != nil
                    && current.range(of: "[.!?:;]$", options: .regularExpression) == nil
                guard hyphenSplit || orphanContinuation else { break }
                current = hyphenSplit ? current + next : current + " " + next
                index += 1
            }
            output.append(current)
            index += 1
        }
        return output.joined(separator: "\n")
    }

    private static func hasUncertainWrapping(_ text: String, fileName: String?) -> Bool {
        let input = lines(in: text)
        let protected = protectedIndexes(in: text, fileName: fileName)
        return input.enumerated().contains { index, line in
            !protected.contains(index) && !LyricsSectionCatalog.isHeading(line) && line.count > 110
        }
    }

    private static func suggestSections(_ text: String, fileName: String?) -> String {
        var input = lines(in: text)
        let protected = protectedIndexes(in: text, fileName: fileName)
        let insertions = suggestedSectionHeadings(in: text, fileName: fileName)
        // Every implicit stanza gets a heading when the first heading is added:
        // the parser then switches from blank-line to explicit-section splitting.
        for index in input.indices.reversed() {
            if let header = insertions[index] { input.insert(header, at: index) }
            else if let header = LyricsSectionCatalog.canonicalHeaderLine(input[index])
                        ?? LyricsSectionCatalog.canonicalCompanionHeaderLine(input[index]), !protected.contains(index) {
                input[index] = header
            }
        }
        return input.joined(separator: "\n")
    }

    static func suggestedSectionHeadings(in text: String, fileName: String? = nil) -> [Int: String] {
        let input = lines(in: text)
        let protected = protectedIndexes(in: text, fileName: fileName)
        let ranges = stanzaRanges(input, protected: protected)
        let candidates = ranges.compactMap { range -> (index: Int, key: String)? in
            guard !range.contains(where: { LyricsSectionCatalog.parseHeader(input[$0]).map { !$0.isMeaning } == true }),
                  let first = primaryIndexes(in: range, lines: input, protected: protected).first else { return nil }
            let words = primaryIndexes(in: range, lines: input, protected: protected).map { input[$0] }.joined(separator: " ")
            let key = words.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !key.isEmpty else { return nil }
            return (first, key)
        }
        let frequencies = Dictionary(grouping: candidates, by: \.key).mapValues(\.count)
        let repeated = candidates.map(\.key).reduce(into: [String]()) { result, key in
            if frequencies[key, default: 0] > 1, !result.contains(key) { result.append(key) }
        }
        var usedVerseNumbers = authoredVerseNumbers(in: input)
        var insertions: [Int: String] = [:]
        for candidate in candidates {
            if let chorus = repeated.firstIndex(of: candidate.key) {
                insertions[candidate.index] = repeated.count == 1 ? "Chorus" : "Chorus \(chorus + 1)"
            } else {
                if let number = nextVerseNumber(used: usedVerseNumbers) {
                    usedVerseNumbers.insert(number)
                    insertions[candidate.index] = "Verse \(number)"
                } else {
                    insertions[candidate.index] = "Verse"
                }
            }
        }
        return insertions
    }

    static func authoredVerseNumbers(in lines: [String]) -> Set<Int> {
        Set(lines.compactMap { line in
            guard let header = LyricsSectionCatalog.parseHeader(line), header.kind == .verse else { return nil }
            return header.label.split(separator: " ").last.flatMap { Int($0) }
        })
    }

    /// Prefer continuing the authored sequence. An unusually large source
    /// ordinal must not overflow; use the first free positive ordinal instead.
    static func nextVerseNumber(used: Set<Int>) -> Int? {
        let largest = used.max() ?? 0
        if largest < Int.max { return max(1, largest + 1) }
        var candidate = 1
        while used.contains(candidate) {
            guard candidate < Int.max else { return nil }
            candidate += 1
        }
        return candidate
    }

    /// Lyric style starts each line and each ordinary sentence with a capital. Keep
    /// deliberate mixed-case names such as iPhone and avoid case expansions
    /// that would change the source word rather than just its letter case.
    static func capitalizingLyricLineStarts(in text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        var needsCapital = true
        let boundaries = Set(text.indices).union([text.endIndex])
        for range in casingWordRanges(in: text) {
            let punctuation = text[cursor..<range.lowerBound]
            if punctuation.contains(where: { $0.isNewline || ".!?".contains($0) }) { needsCapital = true }
            result += punctuation
            let word = String(text[range])
            var replacement = word
            if needsCapital, boundaries.contains(range.lowerBound), boundaries.contains(range.upperBound),
               safeCasingForms(for: word) != nil,
               !word.dropFirst().contains(where: \.isUppercase) || word == word.uppercased() {
                let capitalized = word.prefix(1).uppercased() + word.dropFirst()
                if isSafeCasingChange(word, capitalized) { replacement = capitalized }
            }
            result += replacement
            needsCapital = false
            cursor = range.upperBound
        }
        result += text[cursor...]
        return result
    }

    /// Preserve deliberate names and LORD/Lord. Pronouns remain eligible:
    /// source title case alone cannot establish a human or divine referent.
    static func isProtectedCasingWord(_ word: String) -> Bool {
        let stem = String(word.prefix { $0 != "'" && $0 != "’" })
        if stem == "LORD" || stem == "Lord" || word == "I" { return true }
        if word.dropFirst().contains(where: \.isUppercase), word.contains(where: \.isLowercase) { return true }
        if stem == "I", word.contains(where: \.isLowercase) { return true }
        return properNames[stem.lowercased()] == stem
    }

    /// Local case forms retain the exact source spelling and Unicode shape.
    /// Expansions and mappings with a different lowercase identity stay authored.
    static func safeCasingForms(for word: String) -> (lower: String, capital: String)? {
        let lower = word.lowercased()
        let capital = lower.prefix(1).uppercased() + lower.dropFirst()
        guard [lower, capital].allSatisfy({ isSafeCasingChange(word, $0) && $0.lowercased() == lower }) else { return nil }
        return (lower, capital)
    }

    static func isSafeCasingChange(_ before: String, _ after: String) -> Bool {
        let source = Array(before), candidate = Array(after)
        guard source.count == candidate.count else { return false }
        func sameScalars(_ left: String, _ right: String) -> Bool { left.unicodeScalars.elementsEqual(right.unicodeScalars) }
        for (original, replacement) in zip(source, candidate) {
            let left = String(original), right = String(replacement)
            guard left.unicodeScalars.count == right.unicodeScalars.count,
                  sameScalars(left, right) || sameScalars(left.lowercased(), right) || sameScalars(left.uppercased(), right)
                    || sameScalars(right.lowercased(), left) || sameScalars(right.uppercased(), left) else { return false }
        }
        return true
    }

    /// Matches the parser's section/blank/separator selection. In particular a
    /// blank before Meaning/Translation/Transliteration stays inside its stanza.
    static func stanzaRanges(_ lines: [String], protected: Set<Int>) -> [Range<Int>] {
        LyricsParser.stanzaRangesForCleanup(lines, protected: protected)
    }

    static func primaryIndexes(in range: Range<Int>, lines: [String], protected: Set<Int>) -> [Int] {
        var result: [Int] = []
        for index in range where !protected.contains(index) {
            if LyricsSectionCatalog.parseCompanionHeader(lines[index]) != nil { break }
            if LyricsSectionCatalog.isHeading(lines[index]) || LyricsTextSyntax.isSeparator(lines[index]) || LyricsTextSyntax.isBlank(lines[index]) { continue }
            result.append(index)
        }
        return result
    }

    /// One reproducible local policy is shared by basic cleanup and the final
    /// layout admitted by Apple section/PDF suggestions. No generated lyric
    /// text or model casing answers enter this path.
    static func lyricCasingDraft(_ text: String, fileName: String? = nil) -> LyricsCleanupResult {
        let primary = primaryText(in: text, fileName: fileName)
        guard isEnglish(primary) else {
            let notes = primary.unicodeScalars.contains(where: { $0.properties.isAlphabetic })
                ? ["Local natural lyric casing is limited to recognized English lyrics. Other scripts and uncertain text retain their casing."] : []
            return .init(original: text, proposed: text, changes: [], notes: notes)
        }
        let cased = lyricCase(text, fileName: fileName)
        var notes: [String] = []
        if cased.uncertainReferences {
            notes.append("Local casing keeps uncertain names, titles and pronoun references as authored. Review their capitalization in context.")
        }
        if cased.unsafeWords {
            notes.append("Some words retain their original casing because Unicode case conversion would expand or change their authored spelling.")
        }
        if looksMostlyUppercase(primary) {
            notes.append("All-caps text hides some names, acronyms and emphasis. Review the proposed capitalization.")
        } else if looksTitleCased(primary), cased.text != text {
            notes.append("Title-case formatting was normalized locally. Review unfamiliar names and intentional emphasis.")
        }
        let changes: [LyricsCleanupChange] = cased.text == text ? [] : [
            .init(category: .casing, summary: "Use local natural lyric casing, with a capital at each lyric line.", before: text, after: cased.text)
        ]
        return .init(original: text, proposed: cased.text, changes: changes, notes: notes)
    }

    private struct CaseWord {
        let line: Int
        let range: Range<String.Index>
        let source: String
        let lower: String
        let clause: Int
    }

    private enum ContextualCase { case lower, capital, authored, authoredTitle }

    private static func lyricCase(_ text: String, fileName: String?)
        -> (text: String, uncertainReferences: Bool, unsafeWords: Bool) {
        var input = lines(in: text)
        let protected = protectedIndexes(in: text, fileName: fileName)
        let primary = primaryText(in: text, fileName: fileName)
        let documentUppercase = looksMostlyUppercase(primary)
        let documentTitleCase = looksTitleCased(primary)
        // A source's general Title Case is formatting evidence, not name
        // evidence. Public name recognition is considered independently.
        let names = documentUppercase ? Set<String>() : recognizedNames(in: primary, ignoringTitleCasePhrases: true)
        var uncertainReferences = false
        var unsafeWords = false
        for stanza in stanzaRanges(input, protected: protected) {
            let indexes = primaryIndexes(in: stanza, lines: input, protected: protected)
            let stanzaText = indexes.map { input[$0] }.joined(separator: "\n")
            let mostlyUppercase = documentUppercase || looksMostlyUppercase(stanzaText)
            let titleCase = documentTitleCase || looksTitleCased(stanzaText)
            var words: [CaseWord] = []
            var clause = 0
            for line in indexes {
                clause += 1
                var cursor = input[line].startIndex
                for range in casingWordRanges(in: input[line]) {
                    if input[line][cursor..<range.lowerBound].contains(where: { ",;:.!?".contains($0) }) { clause += 1 }
                    let source = String(input[line][range])
                    words.append(.init(line: line, range: range, source: source,
                                       lower: source.lowercased().replacingOccurrences(of: "’", with: "'"), clause: clause))
                    cursor = range.upperBound
                }
            }
            let contextual = contextualCases(words, names: names)
            var replacements: [Int: [(Range<String.Index>, String)]] = [:]
            for (offset, token) in words.enumerated() {
                let original = token.source
                if isProtectedCasingWord(original) { continue }
                let boundaries = Set(input[token.line].indices).union([input[token.line].endIndex])
                guard boundaries.contains(token.range.lowerBound), boundaries.contains(token.range.upperBound),
                      let forms = safeCasingForms(for: original) else {
                    unsafeWords = true
                    continue
                }
                let lower = original.lowercased()
                let stem = String(lower.prefix { $0 != "'" && $0 != "’" })
                var word = forms.lower
                if let style = contextual[offset] {
                    switch style {
                    case .lower: word = forms.lower
                    case .capital: word = forms.capital
                    case .authoredTitle:
                        word = original
                        uncertainReferences = true
                    case .authored:
                        word = mostlyUppercase ? forms.lower : original
                        if original.first?.isUppercase == true,
                           words.first(where: { $0.line == token.line })?.range != token.range { uncertainReferences = true }
                    }
                } else if let proper = properNames[stem] {
                    word = proper + lower.dropFirst(stem.count)
                } else if stem == "i" {
                    word = forms.capital
                } else if acronyms.contains(original), !(mostlyUppercase && original == "US") {
                    word = original
                } else if names.contains(lower), !functionWords.contains(lower) {
                    word = mostlyUppercase ? forms.capital : original
                } else if !mostlyUppercase, original.count > 1, original.allSatisfy(\.isUppercase) {
                    word = original
                } else if !mostlyUppercase, !titleCase,
                          original.first?.isUppercase == true, !functionWords.contains(lower) {
                    word = original
                }
                if word != original { replacements[token.line, default: []].append((token.range, word)) }
            }
            for line in indexes {
                // Ranges belong to immutable source lines. Applying from the
                // end also preserves offsets when UTF-8 case lengths differ.
                for (range, word) in replacements[line, default: []].reversed() { input[line].replaceSubrange(range, with: word) }
                input[line] = capitalizingLyricLineStarts(in: input[line])
            }
        }
        return (input.joined(separator: "\n"), uncertainReferences, unsafeWords)
    }

    /// Narrow contextual cues resolve common worship titles and explicit human
    /// addressees. Clause-local negatives win over unrelated worship language;
    /// ambiguous references keep source style rather than claiming semantics.
    private static func contextualCases(_ words: [CaseWord], names: Set<String>) -> [Int: ContextualCase] {
        let lower = words.map(\.lower)
        var styles: [Int: ContextualCase] = [:]
        func matches(_ index: Int, _ phrase: [String]) -> Bool {
            index >= 0 && index <= lower.count - phrase.count
                && Array(lower[index..<(index + phrase.count)]) == phrase
        }
        func clauseBefore(_ index: Int, limit: Int = 12) -> [String] {
            Array((max(0, index - limit)..<index).filter { words[$0].clause == words[index].clause }.map { lower[$0] })
        }
        func clauseAfter(_ index: Int) -> [String] {
            Array(((index + 1)..<words.count).prefix { words[$0].clause == words[index].clause }.map { lower[$0] })
        }
        func literal(_ index: Int) -> Bool {
            let before = clauseBefore(index, limit: 6)
            let after = clauseAfter(index)
            let previous = before.last
            switch lower[index] {
            case "lamb":
                return ["a", "little", "small", "young", "newborn", "woolly", "lost"].contains(previous ?? "")
                    || Set(before + after.prefix(4)).intersection(["farmer", "flock", "sheep", "pasture", "fence", "animal"]).count > 0
            case "king", "kings":
                return ["a", "earthly", "human", "mortal", "foreign", "local", "young", "old"].contains(previous ?? "")
                    || before.suffix(2).contains("earthly") || before.suffix(2).contains("human")
            case "father":
                let humanRelationship = ["her", "his", "their"].contains(previous ?? "")
                    && Set(before).intersection(["child", "daughter", "son", "girl", "boy"]).count > 0
                    && Set(before).intersection(["walks", "beside", "holds", "visits"]).count > 0
                return ["a", "human", "earthly"].contains(previous ?? "") || humanRelationship
                    || Set(before.suffix(3)).intersection(["visit", "greet", "meet"]).count > 0
            case "spirit": return ["a", "human", "gentle", "quiet", "bitter"].contains(previous ?? "")
            default: return false
            }
        }
        for index in words.indices {
            if matches(index, ["our", "lady", "of"]), index + 3 < words.count, names.contains(lower[index + 3]) {
                styles[index] = .capital
                styles[index + 1] = .capital
            }
            if matches(index, ["lamb", "of", "god"])
                || matches(index, ["spirit", "of", "god"]) || matches(index, ["spirit", "of", "the", "lord"]) { styles[index] = .capital }
            if matches(index, ["king", "of", "kings"]), !literal(index) {
                styles[index] = .capital
                styles[index + 2] = .capital
            } else if matches(index, ["king", "of", "kings"]) {
                styles[index] = .lower
                styles[index + 2] = .lower
            }
            if matches(index, ["holy", "spirit"]) {
                let style: ContextualCase = index > 0 && lower[index - 1] == "a" ? .lower : .capital
                styles[index] = style
                styles[index + 1] = style
            }
            if matches(index, ["father", "in", "heaven"]) || lower[index] == "father" && index > 0 && lower[index - 1] == "heavenly" {
                styles[index] = literal(index) ? .lower : .capital
            }
        }
        for index in words.indices where ["lamb", "king", "kings", "father", "spirit", "savior", "saviour", "redeemer", "almighty"].contains(lower[index]) && styles[index] == nil {
            if literal(index) { styles[index] = .lower; continue }
            let before = clauseBefore(index)
            if lower[index] == "lamb", before.last == "the",
               before.suffix(3).elementsEqual(["worthy", "is", "the"])
                || before.suffix(2).elementsEqual(["to", "the"]) && before.contains(where: { ["sing", "sings", "singing", "sung", "song", "praise", "worship"].contains($0) })
                || before.contains(where: { ["praise", "worship", "worshipped", "worshiped"].contains($0) }) {
                styles[index] = .capital
            } else { styles[index] = .authoredTitle }
        }
        let divineNames: Set<String> = ["god", "jesus", "christ", "lord", "yahweh", "jehovah", "messiah", "emmanuel", "immanuel"]
        func isDivineReference(_ index: Int) -> Bool {
            let stem = String(lower[index].prefix { $0 != "'" })
            return divineNames.contains(stem)
                || ["lamb", "king", "kings", "father", "spirit"].contains(lower[index]) && styles[index] == .capital
        }
        // A prior divine address is useful only until another explicit person,
        // literal relationship or uncertain named referent intervenes. Looking
        // backward prevents a later worship line from recasing human speech.
        func nearestReference(before index: Int, sameClause: Bool) -> ContextualCase? {
            for offset in (0..<index).reversed() {
                if sameClause, words[offset].clause != words[index].clause { break }
                if isDivineReference(offset) { return .capital }
                let stem = String(lower[offset].prefix { $0 != "'" })
                if names.contains(lower[offset]) || properNames[stem] != nil
                    || ["lamb", "king", "kings", "father"].contains(lower[offset]) && styles[offset] == .lower
                    || ["child", "farmer", "mother", "teacher", "daughter", "brother", "sister", "man", "woman"].contains(stem) { return .lower }
            }
            return nil
        }
        for index in words.indices {
            let stem = String(lower[index].prefix { $0 != "'" })
            guard ["you", "your", "yours", "he", "him", "his"].contains(stem) else { continue }
            let before = clauseBefore(index)
            let after = clauseAfter(index)
            let humanAudience = stem == "you" && before.suffix(3).contains("if") && (
                after.starts(with: ["been", "forgiven"]) || after.starts(with: ["been", "redeemed"])
                    || after.starts(with: ["have", "been", "forgiven"]) || after.starts(with: ["have", "been", "redeemed"])
                    || after.starts(with: ["walk", "in", "freedom"]) || after.starts(with: ["bear", "his", "name"]))
            if humanAudience { styles[index] = .lower; continue }
            let divineName = stem == "your" && after.first == "name" && (
                after.contains("highest") || after.contains("greatest") || after.starts(with: ["name", "stands", "above"]))
            let divineAddress = stem == "you" && after.starts(with: ["are", "lifted", "high"])
            let sacredObject = ["your", "his"].contains(stem) && ["name", "love", "mercy", "grace", "glory"].contains(after.first ?? "")
            let sungPeople = stem == "your" && before.last == "hear" && after.starts(with: ["people", "sing"])
            let worshipObject = ["you", "him"].contains(stem) && ["praise", "worship", "adore"].contains(before.last ?? "")
            let humanAntecedent = ["he", "him", "his"].contains(stem) && !worshipObject
                && nearestReference(before: index, sameClause: true) == .lower
            let divineAntecedent = nearestReference(before: index, sameClause: false) == .capital
            let followingSungTitle = sungPeople && ((index + 1)..<min(words.count, index + 12)).contains { offset in
                isDivineReference(offset) && ["lamb", "king", "kings"].contains(lower[offset])
            }
            if humanAntecedent || after.starts(with: ["human", "father"]) || after.starts(with: ["earthly", "father"]) {
                styles[index] = .lower
            } else if divineName || divineAddress || divineAntecedent && (sacredObject || sungPeople || worshipObject) || followingSungTitle {
                styles[index] = .capital
            } else { styles[index] = .authored }
        }
        return styles
    }

    private static func looksTitleCased(_ text: String) -> Bool {
        let words = wordMatches(text).map { String(text[$0]) }.filter { $0.count > 1 }
        guard words.count >= 4 else { return false }
        let titled = words.filter { $0.first?.isUppercase == true && $0.dropFirst().allSatisfy(\.isLowercase) }
        return Double(titled.count) / Double(words.count) >= 0.65
    }

    static func recognizedNames(in text: String, ignoringTitleCasePhrases: Bool = false) -> Set<String> {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names = Set<String>()
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitWhitespace, .omitPunctuation, .joinNames]) { tag, range in
            if tag == .personalName || tag == .placeName || tag == .organizationName {
                let name = String(text[range])
                let words = wordMatches(name).map { String(name[$0]).lowercased() }
                // Name recognition can misread a pervasive Title Case phrase
                // such as "We Sing" as a place. That grammatical phrase is not
                // independent evidence for preserving its ordinary capitals.
                if ignoringTitleCasePhrases, words.count == 2, isPronounVerbPhrase(name) { return true }
                names.formUnion(words)
            }
            return true
        }
        return names
    }

    private static func isPronounVerbPhrase(_ text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var tags: [NLTag] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if let tag { tags.append(tag) }
            return true
        }
        return tags == [.pronoun, .verb]
    }

    static func isProtectedSpellingWord(_ word: String) -> Bool {
        let lower = word.lowercased()
        let archaic: Set<String> = ["thou", "thee", "thy", "thine", "hath", "doth", "art", "wast", "wert", "o'er", "o’er", "e'er", "e’er", "hallelujah", "alleluia", "hosanna", "amen"]
        return properNames[lower] != nil || archaic.contains(lower)
            || word.dropFirst().contains(where: \.isUppercase) && word.contains(where: \.isLowercase)
    }

    private static func looksMostlyUppercase(_ text: String) -> Bool {
        let ordinary = wordMatches(text).map { String(text[$0]) }.filter {
            !($0.dropFirst().contains(where: \.isUppercase) && $0.contains(where: \.isLowercase))
        }.joined()
        let cased = ordinary.filter { $0.isUppercase || $0.isLowercase }
        return !cased.isEmpty && Double(cased.filter(\.isUppercase).count) / Double(cased.count) > 0.8
    }

    static func wordMatches(_ text: String) -> [Range<String.Index>] {
        let regex = try! NSRegularExpression(pattern: "[\\p{L}\\p{M}]+(?:[’'][\\p{L}\\p{M}]+)*")
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    static func casingWordRanges(in text: String) -> [Range<String.Index>] {
        wordMatches(text).compactMap { range in
            // A leading mark may belong to the preceding nonletter glyph,
            // even without a space. Keep that whole Character literal.
            guard let letter = text.range(of: "\\p{L}", options: .regularExpression, range: range) else { return nil }
            return letter.lowerBound..<range.upperBound
        }
    }

    static func replacingMatches(in text: String, pattern: String, transform: (String) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let range = Range(match.range, in: output), let sourceRange = Range(match.range, in: text) else { continue }
            output.replaceSubrange(range, with: transform(String(text[sourceRange])))
        }
        return output
    }

    private static let properNames = [
        "god": "God", "jesus": "Jesus", "christ": "Christ", "lord": "Lord", "yahweh": "Yahweh",
        "jehovah": "Jehovah", "emmanuel": "Emmanuel", "immanuel": "Immanuel", "messiah": "Messiah",
        "israel": "Israel", "jerusalem": "Jerusalem", "bethlehem": "Bethlehem", "nazareth": "Nazareth",
        "zion": "Zion", "abraham": "Abraham", "isaac": "Isaac", "jacob": "Jacob", "moses": "Moses",
        "david": "David", "mary": "Mary", "joseph": "Joseph", "peter": "Peter", "paul": "Paul", "john": "John"
    ]
    private static let acronyms: Set<String> = ["USA", "UK", "US", "EU", "CCLI", "DVD", "TV", "PDF", "NASA", "NATO", "UN", "BBC"]
    // In normally authored mixed case, retain unfamiliar names and emphasis.
    // Pervasive Title Case has a separate local formatting profile.
    private static let functionWords: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "of", "on", "or", "so", "the", "to", "we", "with"]
}
