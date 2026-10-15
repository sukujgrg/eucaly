import XCTest
@testable import eucaly

final class LyricsTextSanitizerTests: XCTestCase {
    func testWordAndPDFPasteArtifactsDisappearBeforeParsing() {
        let dirty = "\u{FEFF}Ver\u{034F}\u{FEFF}se\u{FE0F}\u{200B} 1\u{2060}\r\nAmazing\u{00AD} grace\u{0000}\u{0007}\u{007F}\u{009F}\u{E0001}\u{E0061}\u{FFFC}" + String(Unicode.Scalar(0xFDD0)!) + String(Unicode.Scalar(0x10FFFF)!)
        let cleaned = LyricsTextSanitizer.clean(dirty)
        XCTAssertEqual(cleaned, "Verse 1\nAmazing grace")
        XCTAssertEqual(LyricsParser.parseDocument(cleaned).slides.first?.lines.first?.text, "Amazing grace")
    }

    func testLineEndingsAndSpacesNormalizeWithoutMergingWordsOrStanzas() {
        XCTAssertEqual(
            LyricsTextSanitizer.clean("a\r\nb\rc\u{0085}d\u{2028}e\u{2029}f\u{000B}g\u{000C}h\n\nnext"),
            "a\nb\nc\nd\ne\nf\ng\nh\n\nnext"
        )
        XCTAssertEqual(LyricsTextSanitizer.clean("one\u{00A0}two\u{202F}three\u{2009}four\u{3000}five\tend"), "one two three four five\tend")
    }

    func testDecimalHexadecimalAndNamedQuoteReferencesDecodeToTheirOriginalPunctuation() {
        let samples = [
            ("We&#39;re We&#039;re We&#x27;re We&#X00027;re We&apos;re", "We're We're We're We're We're"),
            ("&#34;Sing&#x22; &quot;Sing&QUOT;", "\"Sing\" \"Sing\""),
            ("&lsquo;We&rsquo;re&CloseCurlyQuote; &ldquo;Sing&rdquo;", "‘We’re’ “Sing”"),
            ("&OpenCurlyQuote;&rsquor;&sbquo;&lsquor;", "‘’‚‚"),
            ("&OpenCurlyDoubleQuote;&rdquor;&CloseCurlyDoubleQuote;&bdquo;&ldquor;", "“””„„"),
            ("&laquo;Sing&raquo; &lsaquo;Sing&rsaquo;", "«Sing» ‹Sing›"),
            ("&#8216;We&#x2019;re&#8217; &#x201c;Sing&#X201D;", "‘We’re’ “Sing”"),
            ("&#x300C;歌&#x300D; &#x300E;歌&#x300F;", "「歌」 『歌』")
        ]
        for (input, expected) in samples {
            XCTAssertEqual(LyricsTextSanitizer.clean(input), expected)
            XCTAssertEqual(LyricsTextSanitizer.clean(expected), expected)
        }
        let quotes = "We're ‘singing’ “தமிழ்” «می\u{200C}خوانم» 「歌」"
        XCTAssertEqual(Array(LyricsTextSanitizer.clean(quotes).utf8), Array(quotes.utf8))
    }

    func testOtherEntitiesMarkupAndMalformedQuoteReferencesRemainLiteral() {
        let samples = [
            "Rock & Roll &amp; &lt; &gt; &nbsp; &#160; &#65; <b>Sing</b>",
            "&#39 &#x27 &apos &quot &#; &#x; &#-39; &#+39; &#３９; &#xZZ;",
            "&#999999999999999999999; &#x110000; &#xD800; &unknown; &APOS; &Quot;",
            "&amp;#39; &amp;apos; & &; &&apos;"
        ]
        for sample in samples {
            // The final complete reference still decodes beside a literal ampersand.
            let expected = sample.replacingOccurrences(of: "&&apos;", with: "&'")
            XCTAssertEqual(LyricsTextSanitizer.clean(sample), expected)
            XCTAssertEqual(LyricsTextSanitizer.clean(expected), expected)
        }
        XCTAssertEqual(LyricsTextSanitizer.normalizeLineEndings("We&#39;re\rnext"), "We&#39;re\nnext")
    }

    func testQuoteReferencesContainingDiscardedArtifactsDecodeInOneCleanup() {
        let input = "We&#3\u{FEFF}9;re &qu\u{00AD}ot;sing&quo\u{2060}t;"
        let expected = "We're \"sing\""
        XCTAssertEqual(LyricsTextSanitizer.clean(input), expected)
        XCTAssertEqual(LyricsTextSanitizer.clean(expected), expected)
    }

    func testMultilingualOrthographyAndEmojiRemainByteIdentical() {
        let samples = [
            "அற்புத கிருபை", "അദ്ഭുത കൃപ", "क्\u{200D}ष क्\u{200C}ष", "ශ්‍රී", "র\u{200D}্য",
            "می\u{200C}خوانم", "\u{061C}العربية \u{200F}123", "\u{2067}שלום\u{2069} English",
            "\u{1820}\u{180B}", "漢\u{E0100}字", "❤️ 👩🏽\u{200D}💻 👨\u{200D}👩\u{200D}👧\u{200D}👦 1️⃣ 🇦🇺",
            "\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}",
            "e\u{0301} a\u{034F}\u{0301} \u{E123}"
        ]
        for sample in samples {
            XCTAssertEqual(Array(LyricsTextSanitizer.clean(sample).utf8), Array(sample.utf8), sample)
        }
    }

    func testWordBreaksInUnspacedScriptsSurvive() {
        for sample in ["ภาษา\u{200B}ไทย", "မြန်မာ\u{200B}စာ", "ខ្មែរ\u{200B}ភាសា", "日本\u{200B}語"] {
            XCTAssertEqual(Array(LyricsTextSanitizer.clean(sample).utf8), Array(sample.utf8))
        }
        XCTAssertEqual(LyricsTextSanitizer.clean("Amazing\u{200B} grace"), "Amazing grace")
    }

    func testFragmentCleanupUsesTheSurroundingText() {
        XCTAssertEqual(LyricsTextSanitizer.clean("\u{200D}", preceding: "👩", following: "💻"), "\u{200D}")
        XCTAssertEqual(LyricsTextSanitizer.clean("\u{200C}", preceding: "ی", following: "خ"), "\u{200C}")
        XCTAssertEqual(LyricsTextSanitizer.clean("\u{E0100}", preceding: "漢"), "\u{E0100}")
        XCTAssertEqual(LyricsTextSanitizer.clean("\u{200D}", preceding: "a", following: "b"), "")
    }

    func testCleanupIsIdempotentIncludingAdjacentArtifacts() {
        let pieces = ["a", "b", "\u{FEFF}", "\u{00AD}", "\u{2060}", "\u{200B}", "\u{034F}", "\u{200D}", "\u{FE0F}", "\u{0301}", "漢", "\r", "\n", "\u{00A0}", "\u{FFFC}", String(Unicode.Scalar(0xFDD0)!)]
        for first in pieces {
            for second in pieces {
                for third in pieces {
                    let cleaned = LyricsTextSanitizer.clean(first + second + third)
                    XCTAssertEqual(Array(LyricsTextSanitizer.clean(cleaned).utf8), Array(cleaned.utf8))
                }
            }
        }
    }

    func testLineEndingNormalizationLeavesLyricCodepointsUntouched() {
        let input = "keep\u{200D}\u{034F}\u{FE0F}together\rnext\u{2028}line"
        XCTAssertEqual(Array(LyricsTextSanitizer.normalizeLineEndings(input).utf8), Array("keep\u{200D}\u{034F}\u{FE0F}together\nnext\nline".utf8))
    }

    func testLargeMultilingualCleanupPerformance() {
        let input = String(repeating: "Verse 1\r\nAmazing\u{00A0}grace\u{200B}\nWe&#39;re &ldquo;singing&rdquo;\nஅற்புத கிருபை می\u{200C}خوانم 👩\u{200D}💻\n", count: 1_000)
        let expected = String(repeating: "Verse 1\nAmazing grace\nWe're “singing”\nஅற்புத கிருபை می\u{200C}خوانم 👩\u{200D}💻\n", count: 1_000)
        XCTAssertEqual(LyricsTextSanitizer.clean(input), expected)
        let options = XCTMeasureOptions()
        options.iterationCount = 5
        measure(metrics: [XCTClockMetric()], options: options) {
            XCTAssertEqual(LyricsTextSanitizer.clean(input), expected)
        }
    }
}
