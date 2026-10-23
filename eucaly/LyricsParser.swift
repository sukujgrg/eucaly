import Foundation

nonisolated enum LyricsParser {
    static func parseDocument(_ raw: String, fileName: String? = nil) -> LyricsDocument {
        let normalized = LyricsTextSanitizer.normalizeLineEndings(raw)
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        let footer = LyricsCopyrightParser.footer(in: lines)
        var workingLines = footer.map { Array(lines[..<$0.startIndex]) } ?? lines
        var documentMetadata = footer?.metadata ?? [:]
        if let (title, remaining) = extractTopTitle(from: workingLines, fileName: fileName) {
            documentMetadata["title"] = title
            workingLines = remaining
        }

        let slides = buildSlides(from: workingLines)
        return LyricsDocument(slides: slides, metadata: documentMetadata)
    }

    /// Validate a proposed footer boundary using the same title and component
    /// rules as lyric parsing, without recursively recognizing another footer.
    static func hasPrimaryLyricsBeforeCopyright(in lines: [String]) -> Bool {
        let body = extractTopTitle(from: lines, fileName: nil)?.1 ?? lines
        return buildSlides(from: body).contains { slide in
            slide.lines.contains { line in
                line.languageTag.isEmpty && !LyricsTextSyntax.isBlank(line.text)
            }
        }
    }

    /// Uses the same title/footer decisions as projection so cleanup cannot
    /// rewrite licensing information or reinterpret a title as a lyric section.
    static func protectedLineIndexesForCleanup(_ raw: String, fileName: String? = nil) -> Set<Int> {
        let lines = LyricsTextSanitizer.normalizeLineEndings(raw)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let footer = LyricsCopyrightParser.footer(in: lines)
        let workingLines = footer.map { Array(lines[..<$0.startIndex]) } ?? lines
        var protected = Set(footer.map { Array($0.startIndex..<lines.count) } ?? [])
        if extractTopTitle(from: workingLines, fileName: fileName) != nil,
           let titleIndex = workingLines.firstIndex(where: { !LyricsTextSyntax.isBlank($0) }) {
            protected.insert(titleIndex)
        }
        return protected
    }

    /// Returns source spans for the parser's own slide blocks. Cleanup uses
    /// these boundaries instead of maintaining another section parser.
    static func stanzaRangesForCleanup(_ lines: [String], protected: Set<Int>) -> [Range<Int>] {
        let body = lines.enumerated().filter { !protected.contains($0.offset) }
        let blocks = splitBlocks(from: body.map(\.element))
        var starts: [Int] = []
        var cursor = 0
        for block in blocks {
            var start: Int?
            for line in block where !LyricsTextSyntax.isBlank(line) {
                // Blocks retain every nonblank source line verbatim. Advance
                // over only lines omitted by the existing separator splitter.
                while cursor < body.count, body[cursor].element != line { cursor += 1 }
                if cursor < body.count {
                    if start == nil { start = body[cursor].offset }
                    cursor += 1
                }
            }
            if let start { starts.append(start) }
        }
        return starts.enumerated().map { index, start in
            start..<(index + 1 < starts.count ? starts[index + 1] : lines.count)
        }
    }

    private static func splitBlocks(from lines: [String]) -> [[String]] {
        if lines.contains(where: LyricsTextSyntax.isSeparator) {
            return splitOnSeparator(lines)
        }
        if containsPrimarySectionHeader(lines) {
            return splitSectionedWithoutSeparators(lines)
        }
        return splitOnBlankLine(lines)
    }


    private static func buildSlides(from lines: [String]) -> [Slide] {
        let blocks = splitBlocks(from: lines)

        var slides: [Slide] = []
        for block in blocks {
            guard let slide = buildSlide(from: block, index: slides.count + 1) else { continue }
            slides.append(slide)
        }
        return slides
    }

    private static func splitOnSeparator(_ lines: [String]) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String] = []

        for line in lines {
            if LyricsTextSyntax.isSeparator(line) {
                if !current.isEmpty { blocks.append(current) }
                current.removeAll()
                continue
            }
            current.append(line)
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private static func splitOnBlankLine(_ lines: [String]) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String] = []
        var pendingBoundary = false

        for line in lines {
            if LyricsTextSyntax.isBlank(line) {
                pendingBoundary = true
                continue
            }
            // Spacing before a companion marker belongs to the same slide,
            // including the spacing inserted by Format in unheaded lyrics.
            if pendingBoundary, !current.isEmpty, LyricsSectionCatalog.parseCompanionHeader(line) == nil {
                blocks.append(current)
                current.removeAll()
            }
            current.append(line)
            pendingBoundary = false
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private static func splitSectionedWithoutSeparators(_ lines: [String]) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String] = []
        var hasPrimaryHeader = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if LyricsTextSyntax.isBlank(line) {
                if !current.isEmpty { current.append(line) }
                continue
            }

            if isPrimarySectionHeader(trimmed), hasPrimaryHeader, !trimEmptyEdges(current).isEmpty {
                blocks.append(current)
                current = [line]
                hasPrimaryHeader = true
                continue
            }

            if isPrimarySectionHeader(trimmed) {
                hasPrimaryHeader = true
            }

            current.append(line)
        }

        if !trimEmptyEdges(current).isEmpty {
            blocks.append(current)
        }
        return blocks
    }

    private static func buildSlide(from rawBlock: [String], index: Int) -> Slide? {
        let block = trimEmptyEdges(rawBlock)
        guard !block.isEmpty else { return nil }

        let firstLine = block[0].trimmingCharacters(in: .whitespacesAndNewlines)
        var startIndex = 0
        var slideLabel: String?
        var primaryKind: SectionKind = .verse

        if let header = LyricsSectionCatalog.parseHeader(firstLine), !header.isMeaning {
            primaryKind = header.kind
            slideLabel = header.label
            startIndex = 1
        }

        var currentKind = primaryKind
        var currentTag = ""
        var currentLines: [String] = []
        var slideLines: [SlideLine] = []

        func flushCurrent() {
            let text = currentLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                currentLines.removeAll()
                return
            }
            slideLines.append(SlideLine(kind: currentKind, languageTag: currentTag, text: text))
            currentLines.removeAll()
        }

        for line in block[startIndex...] {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let marker = inlineSectionMarker(for: trimmed, defaultKind: primaryKind) {
                flushCurrent()
                currentKind = marker.kind
                currentTag = marker.languageTag
                if slideLabel == nil, let markerLabel = marker.suggestedSlideLabel {
                    slideLabel = markerLabel
                }
                continue
            }
            currentLines.append(LyricsTextSyntax.isBlank(line) ? "" : line)
        }

        flushCurrent()
        guard !slideLines.isEmpty else { return nil }
        slideLines = normalizeLineOrdering(slideLines)

        return Slide(
            index: index,
            lines: slideLines,
            label: slideLabel,
            videoURL: nil,
            pdfURL: nil,
            pdfPageIndex: nil,
            imageURL: nil,
            captureWindowID: nil
        )
    }

    private struct InlineSectionMarker {
        let kind: SectionKind
        let languageTag: String
        let suggestedSlideLabel: String?
    }

    private static func inlineSectionMarker(for line: String, defaultKind: SectionKind) -> InlineSectionMarker? {
        guard !line.isEmpty else { return nil }

        if let companion = LyricsSectionCatalog.parseCompanionHeader(line) {
            return InlineSectionMarker(
                kind: defaultKind,
                languageTag: companion.rawValue,
                suggestedSlideLabel: nil
            )
        }
        if let header = LyricsSectionCatalog.parseHeader(line), !header.isMeaning {
            return InlineSectionMarker(kind: header.kind, languageTag: "", suggestedSlideLabel: header.label)
        }

        return nil
    }

    private static func normalizeLineOrdering(_ lines: [SlideLine]) -> [SlideLine] {
        let ordered = lines.enumerated().sorted { lhs, rhs in
            let lhsRank = lineOrderRank(lhs.element)
            let rhsRank = lineOrderRank(rhs.element)
            if lhsRank == rhsRank { return lhs.offset < rhs.offset }
            return lhsRank < rhsRank
        }
        return ordered.map(\.element)
    }

    private static func lineOrderRank(_ line: SlideLine) -> Int {
        let tag = line.languageTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.isEmpty { return 0 }
        if tag.caseInsensitiveCompare("Meaning") == .orderedSame { return 1 }
        if tag.caseInsensitiveCompare("Translation") == .orderedSame { return 2 }
        if tag.caseInsensitiveCompare("Transliteration") == .orderedSame { return 3 }
        return 4
    }

    private static func containsPrimarySectionHeader(_ lines: [String]) -> Bool {
        lines.contains { isPrimarySectionHeader($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    private static func isPrimarySectionHeader(_ line: String) -> Bool {
        guard let header = LyricsSectionCatalog.parseHeader(line) else { return false }
        return !header.isMeaning
    }

    private static func trimEmptyEdges(_ lines: [String]) -> [String] {
        var start = 0
        var end = lines.count

        while start < end && LyricsTextSyntax.isBlank(lines[start]) {
            start += 1
        }
        while end > start && LyricsTextSyntax.isBlank(lines[end - 1]) {
            end -= 1
        }
        return Array(lines[start..<end])
    }

    private static func extractTopTitle(from lines: [String], fileName: String?) -> (title: String, remaining: [String])? {
        guard let first = lines.firstIndex(where: { !LyricsTextSyntax.isBlank($0) }) else { return nil }
        let firstLine = lines[first].trimmingCharacters(in: .whitespaces)
        if let title = LyricsTextSyntax.explicitTitle(firstLine) {
            var remaining = lines
            remaining.remove(at: first)
            return (title, remaining)
        }
        guard !LyricsTextSyntax.isSeparator(firstLine), !LyricsSectionCatalog.isHeading(firstLine),
              !LyricsCopyrightParser.isMetadataLine(firstLine),
              let next = lines.indices.dropFirst(first + 1).first(where: { !LyricsTextSyntax.isBlank(lines[$0]) }) else {
            return nil
        }

        // A blank line alone cannot distinguish a title from a one-line stanza.
        // Retain legacy title lines when a section heading or the filename supplies evidence.
        let followedByHeader = isPrimarySectionHeader(lines[next])
        let fileTitle = fileName.map { ($0 as NSString).deletingPathExtension }
        let standalone = next > first + 1 || LyricsTextSyntax.isSeparator(lines[next])
        let matchesFileName = standalone && LyricsSectionCatalog.parseCompanionHeader(lines[next]) == nil
            && fileTitle?.caseInsensitiveCompare(firstLine) == .orderedSame
        guard followedByHeader || matchesFileName else { return nil }
        var remaining = lines
        remaining.remove(at: first)
        return (firstLine, remaining)
    }

}
