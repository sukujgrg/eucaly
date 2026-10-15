import Foundation

/// Plain-text paste hygiene, not spelling correction or compatibility normalization.
/// Unrecognized letters, symbols, private-use glyphs and orthographic controls survive.
nonisolated enum LyricsTextSanitizer {
    static func clean(
        _ text: String,
        preceding: Unicode.Scalar? = nil,
        following: Unicode.Scalar? = nil
    ) -> String {
        let cleaned = transform(text, cleanup: true, preceding: preceding, following: following)
        return decodeQuoteReferences(cleaned)
    }

    static func normalizeLineEndings(_ text: String) -> String {
        transform(text, cleanup: false, preceding: nil, following: nil)
    }

    private static func transform(
        _ text: String,
        cleanup: Bool,
        preceding: Unicode.Scalar?,
        following: Unicode.Scalar?
    ) -> String {
        let scalars = text.unicodeScalars
        var output = String()
        var changed = false
        var previous = preceding
        var index = scalars.startIndex
        var contextIndex = scalars.startIndex
        var nextContext = following

        while index < scalars.endIndex {
            let scalar = scalars[index]
            var nextIndex = scalars.index(after: index)
            if cleanup, contextIndex < nextIndex {
                contextIndex = nextIndex
                while contextIndex < scalars.endIndex, isContextIgnorable(scalars[contextIndex]) {
                    contextIndex = scalars.index(after: contextIndex)
                }
                nextContext = contextIndex < scalars.endIndex ? scalars[contextIndex] : following
            }
            let replacement: Unicode.Scalar?

            switch scalar.value {
            case 0x0D:
                replacement = "\n"
                if nextIndex < scalars.endIndex, scalars[nextIndex] == "\n" {
                    nextIndex = scalars.index(after: nextIndex)
                }
            case 0x0B, 0x0C, 0x85, 0x2028, 0x2029:
                replacement = "\n"
            default:
                replacement = cleanup ? cleanedScalar(scalar, previous: previous, next: nextContext) : scalar
            }

            if !changed, replacement != scalar || nextIndex != scalars.index(after: index) {
                output = String(scalars[..<index])
                output.reserveCapacity(text.utf8.count)
                changed = true
            }
            if changed, let replacement {
                output.unicodeScalars.append(replacement)
            }
            if cleanup, let replacement, !isContextIgnorable(replacement) { previous = replacement }
            index = nextIndex
        }
        return changed ? output : text
    }

    // Clean Unicode first so discarded artifacts inside a reference cannot
    // expose an escaped quote only on a subsequent cleanup. Quote decoding
    // cannot create another reference; it needs no recursive decoding.
    private static func decodeQuoteReferences(_ text: String) -> String {
        guard text.utf8.contains(0x26) else { return text }
        let scalars = text.unicodeScalars
        var index = scalars.startIndex
        var output = String()
        var changed = false
        while index < scalars.endIndex {
            if scalars[index] == "&", let quote = quoteReference(in: scalars, at: index) {
                if !changed {
                    output = String(scalars[..<index])
                    output.reserveCapacity(text.utf8.count)
                    changed = true
                }
                output.unicodeScalars.append(quote.scalar)
                index = quote.end
            } else {
                if changed { output.unicodeScalars.append(scalars[index]) }
                index = scalars.index(after: index)
            }
        }
        return changed ? output : text
    }

    // Only complete quote references are clipboard hygiene. Other entities,
    // markup and incomplete references remain literal plain text.
    private static func quoteReference(
        in scalars: String.UnicodeScalarView,
        at index: String.Index
    ) -> (scalar: Unicode.Scalar, end: String.Index)? {
        let start = scalars.index(after: index)
        var end = start
        while end < scalars.endIndex, scalars[end] != ";" {
            let scalar = scalars[end]
            guard isASCIILetter(scalar) || (0x30...0x39).contains(scalar.value)
                || end == start && scalar == "#" else { return nil }
            end = scalars.index(after: end)
        }
        guard end < scalars.endIndex else { return nil }
        let reference = scalars[start..<end]
        let quote: Unicode.Scalar
        if reference.first == "#" {
            var digits = reference.dropFirst()
            var radix: UInt32 = 10
            if digits.first == "x" || digits.first == "X" {
                radix = 16
                digits = digits.dropFirst()
            }
            guard !digits.isEmpty else { return nil }
            var value: UInt32 = 0
            for scalar in digits {
                let digit: UInt32
                switch scalar.value {
                case 0x30...0x39: digit = scalar.value - 0x30
                case 0x41...0x46: digit = scalar.value - 0x41 + 10
                case 0x61...0x66: digit = scalar.value - 0x61 + 10
                default: return nil
                }
                guard digit < radix, value <= (0x10FFFF - digit) / radix else { return nil }
                value = value * radix + digit
            }
            guard let scalar = Unicode.Scalar(value), scalar.properties.isQuotationMark else { return nil }
            quote = scalar
        } else {
            guard let scalar = namedQuotes[String(reference)] else { return nil }
            quote = scalar
        }
        return (quote, scalars.index(after: end))
    }

    private static let namedQuotes: [String: Unicode.Scalar] = [
        "apos": "'", "quot": "\"", "QUOT": "\"",
        "lsquo": "‘", "OpenCurlyQuote": "‘",
        "rsquo": "’", "rsquor": "’", "CloseCurlyQuote": "’",
        "sbquo": "‚", "lsquor": "‚",
        "ldquo": "“", "OpenCurlyDoubleQuote": "“",
        "rdquo": "”", "rdquor": "”", "CloseCurlyDoubleQuote": "”",
        "bdquo": "„", "ldquor": "„",
        "laquo": "«", "raquo": "»", "lsaquo": "‹", "rsaquo": "›"
    ]

    private static func cleanedScalar(
        _ scalar: Unicode.Scalar,
        previous: Unicode.Scalar?,
        next: Unicode.Scalar?
    ) -> Unicode.Scalar? {
        switch scalar.value {
        case 0xFEFF, 0x00AD, 0x2060, 0xE0001, 0xFFFC:
            // A decoded clipboard string has no BOM framing. Discretionary
            // hyphenation and no-break hints from Word/PDF are not lyric content.
            return nil
        case 0x200B:
            // ZWSP is an intentional word-break opportunity in these scripts.
            return preservesWordBreak(previous) || preservesWordBreak(next) ? scalar : nil
        case 0x200C, 0x200D, 0x034F, 0x180E, 0x3164, 0xFFA0:
            // Remove stray glue within ordinary ASCII words; retain ambiguous
            // cases and all non-ASCII script/combining/emoji contexts.
            return (previous == nil || isASCIILetter(previous)) && (next == nil || isASCIILetter(next)) ? nil : scalar
        case 0xFE00...0xFE0F, 0xE0100...0xE01EF:
            // ASCII letters have no standardized variation sequences. Other
            // bases include CJK ideographs, mathematical symbols and emoji.
            return previous == nil || previous?.properties.isWhitespace == true || isASCIILetter(previous) ? nil : scalar
        case 0xE0020...0xE007F:
            // Retain flag-tag spelling after a black flag; discard unattached tags.
            return previous?.value == 0x1F3F4 ? scalar : nil
        default:
            if isNoncharacter(scalar) { return nil }
            if scalar.value < 0x80 {
                return scalar.value >= 0x20 && scalar.value != 0x7F || scalar == "\n" || scalar == "\t"
                    ? scalar : nil
            }
            switch scalar.properties.generalCategory {
            case .control: return nil
            case .spaceSeparator: return " "
            default: return scalar
            }
        }
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar?) -> Bool {
        guard let value = scalar?.value else { return false }
        return (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value)
    }

    static func isContextIgnorable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x80 {
            return scalar.value < 0x20 && !(0x09...0x0D).contains(scalar.value) || scalar.value == 0x7F
        }
        return scalar.value == 0xFFFC || isNoncharacter(scalar)
            || scalar.properties.isDefaultIgnorableCodePoint
            || scalar.properties.generalCategory == .control && scalar.value != 0x85
    }

    private static func isNoncharacter(_ scalar: Unicode.Scalar) -> Bool {
        (0xFDD0...0xFDEF).contains(scalar.value) || scalar.value & 0xFFFF >= 0xFFFE
    }

    // Foundation uses the platform's Unicode script properties. This lookup is
    // only needed at a ZWSP, never for every character of multilingual text.
    private static let wordBreakScripts = try! NSRegularExpression(
        pattern: "[\\p{sc=Thai}\\p{sc=Lao}\\p{sc=Khmer}\\p{sc=Myanmar}\\p{sc=Han}\\p{sc=Hiragana}\\p{sc=Katakana}]"
    )

    private static func preservesWordBreak(_ scalar: Unicode.Scalar?) -> Bool {
        guard let scalar, scalar.value > 0x7F else { return false }
        let text = String(scalar)
        return wordBreakScripts.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) != nil
    }
}
