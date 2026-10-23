import XCTest
@testable import eucaly

final class LyricsTextSyntaxTests: XCTestCase {
    func testFormattingRemovesTheGapBelowTheSecondVerseInTheReportedSong() {
        let source = "Test\n\nVerse\nThis is a test\n\nVerse\n\nThis another test\n\nBridge\nAsas"
        let expected = "Test\n\nVerse\nThis is a test\n\nVerse\nThis another test\n\nBridge\nAsas"

        XCTAssertEqual(LyricsTextSyntax.format(source), expected)
        XCTAssertEqual(LyricsTextSyntax.format(expected), expected)
        XCTAssertEqual(content(LyricsParser.parseDocument(source)), content(LyricsParser.parseDocument(expected)))
        XCTAssertEqual(LyricsParser.parseDocument(expected).metadata["title"], "Test")
    }

    func testHeadingGapsAreRemovedWithoutRemovingInternalOrUnheadedStanzaBreaks() {
        for gap in ["\n\n", "\n \n\t\n", "\r\n\u{200B}\r\n\r\n"] {
            let source = "[Verse 1:]" + gap + "One\n\nTwo\n\n[Translation:]" + gap + "மொழிபெயர்ப்பு"
            let expected = "Verse 1\nOne\n\nTwo\n\nTranslation\nமொழிபெயர்ப்பு"
            XCTAssertEqual(LyricsTextSyntax.format(source), expected)
            XCTAssertEqual(content(LyricsParser.parseDocument(source)), content(LyricsParser.parseDocument(expected)))
        }
        XCTAssertEqual(LyricsTextSyntax.format("One\n\n\nTwo"), "One\n\nTwo")
        XCTAssertEqual(LyricsTextSyntax.format("#title: Song\n\nVerse\n\nOne"), "#title: Song\n\nVerse\nOne")
        let separated = "First stanza\n---\nTranslation\n\nTranslated words"
        let expectedSeparated = "First stanza\n\n---\n\nTranslation\nTranslated words"
        XCTAssertEqual(LyricsTextSyntax.format(separated), expectedSeparated)
        XCTAssertEqual(content(LyricsParser.parseDocument(separated)), content(LyricsParser.parseDocument(expectedSeparated)))
    }

    func testCompanionGapThatSeparatesUnheadedStanzasIsPreserved() {
        let source = "We sing\n\nTranslation\n\nநாம் பாடுவோம்\n\nAnother stanza"
        let formatted = LyricsTextSyntax.format(source)
        XCTAssertEqual(formatted, source)
        let document = LyricsParser.parseDocument(formatted)
        XCTAssertEqual(document.slides.count, 3)
        XCTAssertEqual(document.slides.first?.lines.map(\.text), ["We sing"])
        XCTAssertEqual(document.slides.last?.lines.first?.text, "Another stanza")
        XCTAssertEqual(content(document), content(LyricsParser.parseDocument(source)))
    }

    func testCompanionOnlyStanzaGapCannotLoseTheCopyrightBoundary() {
        for heading in ["Meaning", "Translation", "Transliteration"] {
            let source = heading + "\n\nTranslated words\n\nWriter\n© Unknown"
            let formatted = LyricsTextSyntax.format(source)
            XCTAssertEqual(formatted, source)
            XCTAssertEqual(LyricsTextSyntax.format(formatted), formatted)
            let original = LyricsParser.parseDocument(source)
            let document = LyricsParser.parseDocument(formatted)
            XCTAssertNotNil(original.metadata["copyright-footer"])
            XCTAssertEqual(document.metadata, original.metadata)
            XCTAssertEqual(content(document), content(original))
        }
    }

    func testEmptySectionCannotAbsorbASeparatedCopyrightParagraph() {
        let source = "Verse 1\nWe sing\n\nVerse 2\n\nWriter\n© 2026 Publisher"
        let formatted = LyricsTextSyntax.format(source)
        XCTAssertEqual(formatted, source)
        XCTAssertEqual(LyricsParser.parseDocument(formatted).metadata, LyricsParser.parseDocument(source).metadata)
        XCTAssertEqual(LyricsParser.parseDocument(formatted).slides.first?.lines.first?.text, "We sing")
    }

    func testCreditHeadingsAndTheBlankThatEndsCreditsStayUntouched() {
        let credits = "Writer\n© Unknown\nMeaning\nVerse\nPublisher\n\nChorus\nIgnored trailer\n\n"
        let source = "Verse 1\n\nWe sing\n\n" + credits
        let expected = "Verse 1\nWe sing\n\n" + credits
        XCTAssertEqual(LyricsTextSyntax.format(source), expected)
        XCTAssertEqual(LyricsTextSyntax.format(expected), expected)
        let document = LyricsParser.parseDocument(expected)
        XCTAssertEqual(document.metadata, LyricsParser.parseDocument(source).metadata)
        XCTAssertEqual(document.slides.map { $0.lines.map(\.text) }, [["We sing"]])
    }

    func testFormattingIsIdempotentAndAgreesWithParserBoundaries() {
        let samples = [
            "Verse\r\nOne\n----\u{FEFF}\n[ Chorus: ]\nTwo\nTranslation:\nMeaningful words",
            "First lyric\n\nSecond lyric", "\n\n---\n---\nOne\n\n", "#title: Song\n\nVerse\nOne",
            "Verse 1 of your goodness\nkeep singing", "Verse\n\u{FEFF}\nlyrics",
            "My Song\nVerse 1\nFirst lyric", "First lyric\nTranslation\nTranslated lyric",
            "First lyric\nMeaning\nMeaningful words\n\nSecond lyric", "My Song\n---\nFirst lyric"
        ]
        for sample in samples {
            let formatted = LyricsTextSyntax.format(sample)
            XCTAssertEqual(LyricsTextSyntax.format(formatted), formatted)
            for fileName in [nil, "My Song.txt", "First lyric.txt"] {
                let original = LyricsParser.parseDocument(sample, fileName: fileName)
                let reformatted = LyricsParser.parseDocument(formatted, fileName: fileName)
                XCTAssertEqual(content(original), content(reformatted))
                XCTAssertEqual(original.metadata, reformatted.metadata)
            }
        }
    }

    func testFormattingPreservesMultilingualComponentsAndFullLyricLines() {
        let input = "[Verse 1]\nक्\u{200D}ष\nTranslation:\nمی\u{200C}خوانم\nMeaning is everywhere\n"
        XCTAssertEqual(LyricsTextSyntax.format(input), "Verse 1\nक्\u{200D}ष\n\nTranslation\nمی\u{200C}خوانم\nMeaning is everywhere")
    }

    private func content(_ document: LyricsDocument) -> [String] {
        document.slides.map { slide in
            "\(slide.label ?? ""):\(slide.lines.map { "\($0.languageTag):\($0.text)" }.joined(separator: "|"))"
        }
    }
}
