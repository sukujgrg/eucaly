import Foundation

enum LyricsParser {
    static func parseDocument(_ raw: String, fileName _: String? = nil) -> LyricsDocument {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        var workingLines = lines
        let metadata = extractCCLIMetadata(lines: lines)
        if !metadata.isEmpty {
            workingLines = stripCCLITrailer(from: lines, metadata: metadata)
        }

        var documentMetadata = metadata
        if let (title, remaining) = extractTopTitle(from: workingLines) {
            documentMetadata["title"] = title
            workingLines = remaining
        }

        let slides = buildSlides(from: workingLines)
        return LyricsDocument(slides: slides, metadata: documentMetadata)
    }

    private static func buildSlides(from lines: [String]) -> [Slide] {
        let usesExplicitSeparators = lines.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }
        let blocks: [[String]]
        if usesExplicitSeparators {
            blocks = splitOnSeparator(lines)
        } else if containsPrimarySectionHeader(lines) {
            blocks = splitSectionedWithoutSeparators(lines)
        } else {
            blocks = splitOnBlankLine(lines)
        }

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
            if line.trimmingCharacters(in: .whitespacesAndNewlines) == "---" {
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

        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !current.isEmpty { blocks.append(current) }
                current.removeAll()
                continue
            }
            current.append(line)
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
            if trimmed.isEmpty {
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

            if isCCLIMetadataLine(trimmed), hasPrimaryHeader, !trimEmptyEdges(current).isEmpty {
                blocks.append(current)
                current = [line]
                continue
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
            currentLines.append(line)
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
        let normalized = normalizedSectionToken(line)

        if normalized.caseInsensitiveCompare("Meaning") == .orderedSame {
            return InlineSectionMarker(kind: defaultKind, languageTag: "Meaning", suggestedSlideLabel: nil)
        }
        if let translationTag = canonicalTranslationTag(for: normalized) {
            return InlineSectionMarker(kind: defaultKind, languageTag: translationTag, suggestedSlideLabel: nil)
        }
        if let header = LyricsSectionCatalog.parseHeader(line), !header.isMeaning {
            return InlineSectionMarker(kind: header.kind, languageTag: "", suggestedSlideLabel: header.label)
        }

        return nil
    }

    private static func normalizedSectionToken(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func canonicalTranslationTag(for normalized: String) -> String? {
        if normalized.caseInsensitiveCompare("Translation") == .orderedSame ||
            normalized.caseInsensitiveCompare("Transalation") == .orderedSame {
            return "Translation"
        }
        if normalized.caseInsensitiveCompare("Transliteration") == .orderedSame {
            return "Transliteration"
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

        while start < end && lines[start].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            start += 1
        }
        while end > start && lines[end - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end -= 1
        }
        return Array(lines[start..<end])
    }

    private static func extractTopTitle(from lines: [String]) -> (title: String, remaining: [String])? {
        guard let firstIndex = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            return nil
        }

        let firstLine = lines[firstIndex].trimmingCharacters(in: .whitespacesAndNewlines)
        if firstLine == "---" || LyricsSectionCatalog.isHeader(firstLine) || isCCLIMetadataLine(firstLine) {
            return nil
        }

        let nextIndex = lines[(firstIndex + 1)...].firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard let nextIndex else { return nil }

        let between = lines[(firstIndex + 1)..<nextIndex]
        let isStandalone =
            !between.isEmpty &&
            between.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let followedByHeader = LyricsSectionCatalog.isHeader(lines[nextIndex].trimmingCharacters(in: .whitespacesAndNewlines))
        guard isStandalone || followedByHeader else { return nil }

        var remaining = lines
        remaining.remove(at: firstIndex)
        return (firstLine, remaining)
    }

    private static func extractCCLIMetadata(lines: [String]) -> [String: String] {
        var metadata: [String: String] = [:]
        let trimmedLines = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let songNumberIndex = trimmedLines.firstIndex(where: { $0.lowercased().hasPrefix("ccli song #") }) {
            if songNumberIndex > 0 {
                let authors = trimmedLines[songNumberIndex - 1]
                if !authors.isEmpty { metadata["authors"] = authors }
            }
            let songNumber = trimmedLines[songNumberIndex]
                .replacingOccurrences(of: "CCLI Song #", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !songNumber.isEmpty { metadata["ccli-songnumber"] = songNumber }
        }

        if let licenseIndex = trimmedLines.firstIndex(where: { $0.lowercased().hasPrefix("ccli license #") }) {
            let license = trimmedLines[licenseIndex]
                .replacingOccurrences(of: "CCLI License #", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !license.isEmpty { metadata["ccli-licensenumber"] = license }
        }

        if let copyrightIndex = trimmedLines.firstIndex(where: { $0.hasPrefix("©") }) {
            metadata["copyright"] = trimmedLines[copyrightIndex]
            if copyrightIndex + 1 < trimmedLines.count {
                let claim = trimmedLines[copyrightIndex + 1]
                if !claim.isEmpty { metadata["copyright-claim"] = claim }
            }
        }

        if let rightsIndex = trimmedLines.firstIndex(where: { isCCLIRightsLine($0.lowercased()) }) {
            let rights = trimmedLines[rightsIndex]
            if !rights.isEmpty { metadata["rights"] = rights }
        }

        return metadata
    }

    private static func stripCCLITrailer(from lines: [String], metadata: [String: String]) -> [String] {
        let trimmed = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let firstMetadataIndex = trimmed.firstIndex(where: { isCCLIMetadataLine($0) }) else {
            return lines
        }

        let hasPriorContent = trimmed[..<firstMetadataIndex].contains { !$0.isEmpty }
        let metadataBlock = trimmed[firstMetadataIndex...]
        let metadataDensity = metadataBlock.isEmpty ? 0.0 :
            Double(metadataBlock.filter { isCCLIMetadataLine($0) || $0.isEmpty }.count) / Double(metadataBlock.count)

        guard hasPriorContent, metadataDensity >= 0.6 else {
            return lines
        }

        var pruneStart = firstMetadataIndex
        var authorIndex = firstMetadataIndex - 1
        while authorIndex >= 0 && trimmed[authorIndex].isEmpty {
            authorIndex -= 1
        }

        if authorIndex >= 0 {
            let candidate = trimmed[authorIndex]
            let shouldTreatAsAuthor =
                !candidate.isEmpty &&
                candidate != "---" &&
                !LyricsSectionCatalog.isHeader(candidate)
            if shouldTreatAsAuthor {
                pruneStart = authorIndex
            }
        }

        var remaining = Array(lines[..<pruneStart])
        while let last = remaining.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            remaining.removeLast()
        }
        return remaining
    }

    private static func isCCLIMetadataLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let lower = trimmed.lowercased()

        if lower.hasPrefix("ccli song #") || lower.hasPrefix("ccli license #") {
            return true
        }
        if lower.hasPrefix("©") {
            return true
        }
        if isCCLIRightsLine(lower) { return true }
        if lower.hasPrefix("ccli") {
            return true
        }
        return false
    }

    private static func isCCLIRightsLine(_ lower: String) -> Bool {
        guard lower.contains("songselect") else { return false }
        if lower.contains("terms of use") { return true }
        if lower.contains("for use solely") { return true }
        if lower.contains("www.ccli.com") { return true }
        if lower.contains("ccli.com") { return true }
        return false
    }
}
