import XCTest
@testable import eucaly

final class LyricsParserTests: XCTestCase {
    func testSectionHeadersAreCaseInsensitiveAndColonTolerant() {
        let raw = """
        Title

        Verse 1:
        line a

        VERSE:
        line b
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.metadata["title"], "Title")
        XCTAssertEqual(doc.slides.count, 2)
        XCTAssertEqual(doc.slides[0].label, "Verse 1")
        XCTAssertEqual(doc.slides[0].lines.first?.text, "line a")
        XCTAssertEqual(doc.slides[1].label, "Verse")
        XCTAssertEqual(doc.slides[1].lines.first?.text, "line b")
    }

    func testMeaningAndTransliterationInlineSections() {
        let raw = """
        Verse 1
        line 1

        Meaning:
        meaning line

        Transliteration:
        translit line
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.slides.count, 1)
        let lines = doc.slides[0].lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].languageTag, "")
        XCTAssertEqual(lines[0].text, "line 1")
        XCTAssertEqual(lines[1].languageTag, "Meaning")
        XCTAssertEqual(lines[1].text, "meaning line")
        XCTAssertEqual(lines[2].languageTag, "Transliteration")
        XCTAssertEqual(lines[2].text, "translit line")
    }

    func testTranslationInlineSectionAlias() {
        let raw = """
        Verse
        line 1

        Translation:
        translated line
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.slides.count, 1)
        XCTAssertEqual(doc.slides[0].lines.count, 2)
        XCTAssertEqual(doc.slides[0].lines[1].languageTag, "Translation")
        XCTAssertEqual(doc.slides[0].lines[1].text, "translated line")
    }

    func testTransalationTypoInlineSectionAlias() {
        let raw = """
        Verse
        line 1

        Transalation:
        translated line
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.slides.count, 1)
        XCTAssertEqual(doc.slides[0].lines.count, 2)
        XCTAssertEqual(doc.slides[0].lines[1].languageTag, "Translation")
    }

    func testMeaningIsPlacedBeforeTranslationRegardlessOfInputOrder() {
        let raw = """
        Verse 1
        line 1

        Translation:
        translated line

        Meaning:
        meaning line
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.slides.count, 1)
        let lines = doc.slides[0].lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0].languageTag, "")
        XCTAssertEqual(lines[1].languageTag, "Meaning")
        XCTAssertEqual(lines[2].languageTag, "Translation")
        XCTAssertEqual(lines[1].text, "meaning line")
        XCTAssertEqual(lines[2].text, "translated line")
    }

    func testMeaningIsPlacedBeforeTranslationAliasRegardlessOfInputOrder() {
        let raw = """
        Chorus
        line 1

        Transalation:
        translated line

        Meaning:
        meaning line
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.slides.count, 1)
        let lines = doc.slides[0].lines
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[1].languageTag, "Meaning")
        XCTAssertEqual(lines[2].languageTag, "Translation")
    }

    func testDashSeparatorCreatesSlides() {
        let raw = """
        Verse
        one
        ---
        Verse
        two
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.slides.count, 2)
    }

    func testBlankLineSeparationWhenNoHeaders() {
        let raw = """
        line 1
        line 2

        line 3
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.slides.count, 2)
        XCTAssertEqual(doc.slides[0].lines.first?.text, "line 1\nline 2")
        XCTAssertEqual(doc.slides[1].lines.first?.text, "line 3")
    }

    func testSectionedWithoutSeparatorsSplitsOnPrimaryHeaders() {
        let raw = """
        Verse 1
        line a

        Chorus
        line b
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.slides.count, 2)
        XCTAssertEqual(doc.slides[0].label, "Verse 1")
        XCTAssertEqual(doc.slides[1].label, "Chorus")
    }

    func testInvisibleCharactersDoNotPreventSectionHeaderRecognition() {
        let raw = """
        \u{FEFF}Ver\u{034F}se\u{200B} 1\u{2060}
        line a

        \u{0007}Cho\u{FE0F}r\u{200D}us\u{0008}
        line b
        """

        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")

        XCTAssertEqual(doc.slides.count, 2)
        XCTAssertEqual(doc.slides[0].label, "Verse 1")
        XCTAssertEqual(doc.slides[0].lines.first?.text, "line a")
        XCTAssertEqual(doc.slides[1].label, "Chorus")
        XCTAssertEqual(doc.slides[1].lines.first?.text, "line b")
    }

    func testInvisibleCharactersDoNotPreventCompanionMarkerRecognition() {
        let raw = """
        Verse
        original line

        \u{FEFF}Trans\u{200B}lation:\u{2060}
        translated line
        """

        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")

        XCTAssertEqual(doc.slides.count, 1)
        XCTAssertEqual(doc.slides[0].lines.count, 2)
        XCTAssertEqual(doc.slides[0].lines[1].languageTag, "Translation")
        XCTAssertEqual(doc.slides[0].lines[1].text, "translated line")
    }

    func testUnicodeWhitespaceIsAcceptedInsideMultiwordHeader() {
        let raw = """
        Pre\u{00A0}Chorus 2
        line
        """

        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")

        XCTAssertEqual(doc.slides.count, 1)
        XCTAssertEqual(doc.slides[0].label, "Pre-Chorus 2")
        XCTAssertEqual(doc.slides[0].lines.first?.text, "line")
    }

    func testInvisibleCharactersInLyricsArePreserved() {
        let lyric = "keep\u{200D}together"
        let doc = LyricsParser.parseDocument("Verse\n\(lyric)", fileName: "test.txt")

        XCTAssertEqual(doc.slides.first?.lines.first?.text, lyric)
    }

    func testBracketedCompanionMarkerUsesSharedRecognition() {
        let raw = """
        Verse
        original line

        [Trans\u{FE0F}lation:]
        translated line
        """

        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")

        XCTAssertEqual(doc.slides.count, 1)
        XCTAssertEqual(doc.slides[0].lines.count, 2)
        XCTAssertEqual(doc.slides[0].lines[1].languageTag, "Translation")
        XCTAssertEqual(
            LyricsSectionCatalog.canonicalCompanionHeaderLine("[Trans\u{FE0F}lation:]"),
            "Translation"
        )
    }

    func testCommonSectionHeadings() {
        let headings = [
            ("Intro", "Intro"),
            ("Outro", "Outro"),
            ("Ending", "Ending"),
            ("Instrumental", "Instrumental"),
            ("Vamp", "Vamp"),
            ("Coda", "Coda"),
            ("Pre Chorus", "Pre-Chorus"),
            ("Post-Chorus", "Post-Chorus"),
            ("Hook", "Chorus")
        ]

        for (heading, expectedLabel) in headings {
            let doc = LyricsParser.parseDocument(
                """
                \(heading)
                line
                """,
                fileName: "test.txt"
            )
            XCTAssertEqual(doc.slides.count, 1, heading)
            XCTAssertEqual(doc.slides[0].label, expectedLabel, heading)
            XCTAssertEqual(doc.slides[0].lines.first?.text, "line", heading)
        }
    }

    func testBracketedSectionHeadings() {
        let headings = [
            ("[Verse 1]", "Verse 1"),
            ("[Chorus:]", "Chorus"),
            ("[Pre Chorus 2]", "Pre-Chorus 2"),
            ("[Post-Chorus]", "Post-Chorus"),
            ("[Hook]", "Chorus"),
            ("[Instrumental]", "Instrumental")
        ]

        for (heading, expectedLabel) in headings {
            let doc = LyricsParser.parseDocument(
                """
                \(heading)
                line
                """,
                fileName: "test.txt"
            )
            XCTAssertEqual(doc.slides.count, 1, heading)
            XCTAssertEqual(doc.slides[0].label, expectedLabel, heading)
            XCTAssertEqual(LyricsSectionCatalog.canonicalHeaderLine(heading), expectedLabel, heading)
        }
    }

    func testCCLITrailerAndAuthorAreStripped() {
        let raw = """
        Verse
        line a

        Reuben Morgan
        CCLI Song #2397964
        © 1998 Hillsong Music Publishing Australia
        For use solely with the SongSelect® Terms of Use.  All rights reserved. www.ccli.com
        CCLI License #308328
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.slides.count, 1)
        XCTAssertEqual(doc.slides[0].lines.first?.text, "line a")
        XCTAssertNil(doc.slides.first { $0.lines.contains(where: { $0.text.contains("Reuben") }) })
    }

    func testCCLIMatchingPreservesOriginalMetadataValues() {
        let author = "Author\u{200D} Name"
        let copyright = "© 2026 Music\u{200D} Works"
        let claim = "Copyright\u{200D} claim"
        let rights = "For use solely with Song\u{200D}Select Terms of Use. www.ccli.com"
        let raw = """
        Verse
        line a

        \(author)
        C\u{034F}CLI Song #12345
        \(copyright)
        \(claim)
        \(rights)
        CCLI License #67890
        """

        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")

        XCTAssertEqual(doc.metadata["authors"], author)
        XCTAssertEqual(doc.metadata["ccli-songnumber"], "12345")
        XCTAssertEqual(doc.metadata["copyright"], copyright)
        XCTAssertEqual(doc.metadata["copyright-claim"], claim)
        XCTAssertEqual(doc.metadata["rights"], rights)
        XCTAssertEqual(doc.metadata["ccli-licensenumber"], "67890")
        XCTAssertEqual(doc.slides.count, 1)
        XCTAssertEqual(doc.slides[0].lines.first?.text, "line a")
    }

    func testCCLILineInsideLyricsDoesNotStripContent() {
        let raw = """
        Verse
        My CCLI reference is in the lyric line

        Chorus
        Keep singing
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.slides.count, 2)
        XCTAssertEqual(doc.slides[0].lines.first?.text, "My CCLI reference is in the lyric line")
        XCTAssertEqual(doc.slides[1].lines.first?.text, "Keep singing")
    }

    func testSongSelectWordInsideLyricsDoesNotStripContent() {
        let raw = """
        Verse
        We sing songselect together
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.slides.count, 1)
        XCTAssertEqual(doc.slides[0].lines.first?.text, "We sing songselect together")
    }

    func testCCLITrailerRequiresMetadataBlockDensity() {
        let raw = """
        Verse
        line a

        CCLI Song #2397964
        Not really metadata
        """
        let doc = LyricsParser.parseDocument(raw, fileName: "test.txt")
        XCTAssertEqual(doc.slides.count, 2)
    }
}
