import XCTest
@testable import eucaly

final class LyricsCopyrightParserTests: XCTestCase {
    func testExactUnlabelledUserCreditsAreASeparatedParagraphRegardlessOfHolder() {
        let body = """
        Verse 4
        കൂട്ടിനുണ്ട് കൂടെന്നും ഇദ്ധരെ
        വീട്ടിലെത്തി വിശ്രമിക്കും നാൾ വരെ
        ഹല്ലേലൂയ്യ പാടിടും മോദമായ്
        വല്ലഭനാം എൻ പ്രിയൻ മൂലമായ്

        Transliteration
        koottinunde koodennum iddhare
        veettilethi vishramikkum naal vare
        hallelooyah paadidum modamaay
        vallabhanam en priyan moolamaay
        """
        let credits = "T K Samuel\n© Unknown - VerseView Song Database ID : 218975"
        for prefix in ["", "#title: Saved title\nVerse 1\nWe sing with joy\n\n"] {
            let source = prefix + body + "\n\n" + credits
            let expected = LyricsParser.parseDocument(prefix + body)
            let document = LyricsParser.parseDocument(source)
            XCTAssertEqual(document.slides.map { $0.lines.map { [$0.languageTag, $0.text] } },
                           expected.slides.map { $0.lines.map { [$0.languageTag, $0.text] } })
            XCTAssertEqual(document.metadata["title"], expected.metadata["title"])
            XCTAssertEqual(Array((document.metadata["copyright-footer"] ?? "").utf8), Array(credits.utf8))
            XCTAssertEqual(document.metadata["copyright"], "© Unknown - VerseView Song Database ID : 218975")
            XCTAssertNil(document.metadata["authors"])
        }
    }

    func testAllNonemptyCreditParagraphLinesAreCreditsWithoutFieldShapeGuesses() {
        let credits = "Author One\nജോണ്\u{200D}\n©something\nArbitrary publisher words\nChorus\n#title: Part of this credit paragraph"
        let document = LyricsParser.parseDocument("#title: Actual title\nVerse 1\nWe sing with joy\n\n" + credits)
        XCTAssertEqual(document.slides.first?.lines.first?.text, "We sing with joy")
        XCTAssertEqual(document.slides.count, 1)
        XCTAssertEqual(document.metadata["title"], "Actual title")
        XCTAssertEqual(document.metadata["copyright"], "©something")
        XCTAssertEqual(Array((document.metadata["copyright-footer"] ?? "").utf8), Array(credits.utf8))
        XCTAssertNil(document.metadata["authors"])
    }

    func testFirstBlankEndsMetadataAndAllLaterSourceStaysOutOfLyrics() {
        let credits = "Authors: First Writer\n“Credit Title\" Words & Music by Second Writer\n© Unknown\nCCLI License #12345\nArbitrary publisher"
        let trailer = "Chorus\nThis must never revive lyrics\nAuthors: Wrong Writer\nCCLI License #99999\n\nAnother author\n© Later publisher\n[Copyright]\nMore discarded notes"
        let source = "#title: Actual title\nVerse 1\nWe sing with joy\n\n" + credits + "\n\n" + trailer
        let document = LyricsParser.parseDocument(source)
        XCTAssertEqual(document.slides.map { $0.lines.map(\.text) }, [["We sing with joy"]])
        XCTAssertEqual(document.metadata["title"], "Actual title")
        XCTAssertEqual(document.metadata["credit-song-title"], "Credit Title")
        XCTAssertEqual(document.metadata["authors"], "First Writer\nSecond Writer")
        XCTAssertEqual(document.metadata["ccli-licensenumber"], "12345")
        XCTAssertEqual(document.metadata["copyright"], "© Unknown")
        XCTAssertEqual(document.metadata["copyright-footer"], credits)
    }

    func testBlankComparisonAndMultilingualCreditSourceStayExact() {
        let credits = "  T\tK Samuel\n\u{200B}© Unknown\nമലയാളം പബ്ലിഷർ\u{200D}  "
        for blank in ["", "  ", "\t\u{00A0}", "\u{200B}"] {
            for newline in ["\n", "\r\n"] {
                let source = ("Verse 1\nWe sing with joy\n" + blank + "\n" + credits + "\n" + blank + "\nChorus\nIgnored")
                    .replacingOccurrences(of: "\n", with: newline)
                let document = LyricsParser.parseDocument(source)
                XCTAssertEqual(document.slides.map { $0.lines.map(\.text) }, [["We sing with joy"]])
                XCTAssertEqual(Array((document.metadata["copyright-footer"] ?? "").utf8), Array(credits.utf8))
                XCTAssertEqual(document.metadata["copyright"], "© Unknown")
            }
        }
    }

    func testCreditOnlyParagraphsCannotSupplyLyricEvidenceForLaterCredits() {
        for prefix in ["", "#title: Credit-only file\n\n", "Verse 1\n\n", "Meaning\nAn explanation\n\n", "[Copyright]\nAuthor One\n\n"] {
            for credits in [
                "Author Two\n© Unknown",
                "Author One\n© Unknown\nPublisher One\n\nAuthor Two\n© 2026 Publisher Two\n\nAuthor Three\n© Unknown - VerseView Song Database ID : 12"
            ] {
                let source = prefix + credits
                XCTAssertNil(LyricsCopyrightParser.footer(in: LyricsTextSanitizer.normalizeLineEndings(source).components(separatedBy: "\n")))
                XCTAssertNil(LyricsParser.parseDocument(source).metadata["copyright-footer"])
            }
        }
    }

    func testMissingCreditBoundaryDoesNotReclassifyPrimaryOrCompanionContent() {
        for source in [
            "We sing with joy\nT K Samuel\n© Unknown - VerseView Song Database ID : 218975",
            "Verse 1\nWe sing with joy\nT K Samuel\n© 2026 Publisher",
            "Verse 1\nWe sing with joy\n\nTransliteration\nwe sing with joy\nT K Samuel\n© Unknown",
            "Verse 1\nWe sing with joy\n\nMeaning\nAn explanation\n© Unknown",
            "Verse 1\nWe sing with joy\n\nChorus\nAnother lyric\n© Unknown",
            "Verse 1\nWe sing with joy\n\n---\nAnother lyric\n© Unknown"
        ] {
            let document = LyricsParser.parseDocument(source)
            XCTAssertNil(document.metadata["copyright-footer"])
            XCTAssertTrue(document.slides.flatMap(\.lines).contains { $0.text.contains("©") })
        }
    }

    func testNoSymbolAndInlineSymbolsDoNotDeclareCreditParagraphs() {
        for tail in ["Author One\nPublisher words", "We sing © the song\nPublisher words"] {
            let document = LyricsParser.parseDocument("Verse 1\nWe sing with joy\n\n" + tail)
            XCTAssertTrue(document.metadata.isEmpty)
            XCTAssertTrue(document.slides.first?.lines.first?.text.hasSuffix(tail) == true)
        }
    }

    func testExplicitMarkersBeforeAndInsideSymbolParagraphsKeepDeclaredCredits() {
        let body = "Verse 1\nWe sing with joy\n\n"
        let credits = "Authors: Jane Doe\n\n© Unknown\nPublisher"
        let earlier = LyricsParser.parseDocument(body + "[Copyright]\n" + credits + "\n\nChorus\nIgnored")
        XCTAssertEqual(earlier.slides.first?.lines.first?.text, "We sing with joy")
        XCTAssertEqual(earlier.metadata["authors"], "Jane Doe")
        XCTAssertEqual(earlier.metadata["copyright-footer"], credits)
        let within = LyricsParser.parseDocument(body + "Arbitrary credit name\n[Copyright]\n© Unknown\nPublisher\n\nChorus\nIgnored")
        XCTAssertEqual(within.slides.first?.lines.first?.text, "We sing with joy")
        XCTAssertEqual(within.metadata["copyright-footer"], "Arbitrary credit name\n© Unknown\nPublisher")
        XCTAssertNil(within.metadata["authors"])
    }

    func testCleanupProtectsTheRawCreditParagraphAndIgnoredTrailerWithoutDeletingSource() {
        let suffix = "T K Samuel\n© Unknown\nArbitrary Publisher\n\nChorus\n  discard â€™\u{200B} this trailer\nCCLI License #99999"
        let source = "#title: Exact title\nVerse 1\nWE SING WITH JOY\nTransliteration\nwe sing with joy\n\n" + suffix
        let result = LyricsCleanupEngine.clean(source)
        XCTAssertEqual(result.original, source)
        XCTAssertTrue(result.proposed.hasSuffix(suffix))
        XCTAssertTrue(result.proposed.contains("Verse 1\nWe sing with joy\nTransliteration\nwe sing with joy"))
        XCTAssertEqual(LyricsParser.parseDocument(result.proposed).metadata, LyricsParser.parseDocument(source).metadata)
        XCTAssertNil(LyricsParser.parseDocument(result.proposed).metadata["ccli-licensenumber"])
        let lines = LyricsTextSanitizer.normalizeLineEndings(source).components(separatedBy: "\n")
        XCTAssertTrue(Set(6..<lines.count).isSubset(of: LyricsParser.protectedLineIndexesForCleanup(source)))
    }

    func testOfficialThreeLineCCLINoticeIsMetadataWithoutChangingTheDocumentTitle() {
        for suffix in ["", "."] {
            let notice = "“Hallelujah\" words and music by John Doe\n© 2018 Good Music Co.\nUsed by Permission. CCLI License #12345" + suffix
            for title in ["#title: Authored title", "Authored title"] {
                let source = title + "\nVerse 1\nWe sing with joy\nTransliteration\nwe sing with joy\n\n" + notice
                let document = LyricsParser.parseDocument(source)
                XCTAssertEqual(document.slides.count, 1)
                XCTAssertEqual(document.slides.first?.lines.map(\.text), ["We sing with joy", "we sing with joy"])
                XCTAssertEqual(document.metadata["title"], "Authored title")
                XCTAssertEqual(document.metadata["credit-song-title"], "Hallelujah")
                XCTAssertEqual(document.metadata["authors"], "John Doe")
                XCTAssertEqual(document.metadata["copyright"], "© 2018 Good Music Co.")
                XCTAssertEqual(document.metadata["rights"], "Used by Permission.")
                XCTAssertEqual(document.metadata["ccli-licensenumber"], "12345")
                XCTAssertEqual(document.metadata["copyright-footer"], notice)
            }
        }
    }

    func testQuotedCreditNoticesSupportQuotesAndPunctuationWithoutColonSplitting() {
        let variants = [
            ("\"Grace: God's Love\" Words & Music by Jane Doe: John Roe", "Grace: God's Love", "Jane Doe: John Roe"),
            ("“Grace 'Forever'” WORDS AND MUSIC BY Jane Doe", "Grace 'Forever'", "Jane Doe"),
            ("‘Grace Forever’ Words and Music by John Doe", "Grace Forever", "John Doe"),
            ("'Grace “Forever”' words & music by John Doe", "Grace “Forever”", "John Doe")
        ]
        for (credit, title, authors) in variants {
            let notice = credit + "\n© 2018 Publisher\nUsed by Permission. CCLI License #12345."
            let document = LyricsParser.parseDocument("Verse 1\nWe sing with joy\n\n" + notice)
            XCTAssertEqual(document.metadata["credit-song-title"], title)
            XCTAssertEqual(document.metadata["authors"], authors)
            XCTAssertEqual(document.metadata["copyright-footer"], notice)
            XCTAssertEqual(document.slides.first?.lines.first?.text, "We sing with joy")
        }
    }

    func testInlinePermissionAndLicenceYieldBothRightsAndChurchLicence() {
        for (line, permission) in [
            ("Used by Permission. CCLI License #12345.", "Used by Permission."),
            ("used by permission CCLI Licence No. 12345", "used by permission"),
            ("Reproduced by permission.\tCCLI License Number: 12345.", "Reproduced by permission."),
            ("All rights reserved. CCLI Licence #12345.", "All rights reserved.")
        ] {
            let document = LyricsParser.parseDocument("Verse 1\nWe sing with joy\n\n© 2018 Publisher\n" + line)
            XCTAssertEqual(document.metadata["rights"], permission)
            XCTAssertEqual(document.metadata["ccli-licensenumber"], "12345")
            XCTAssertEqual(document.slides.first?.lines.first?.text, "We sing with joy")
        }
    }

    func testAuthorPrefixesCaptureTheCompleteWriterTextIncludingColons() {
        let authors = "John Doe: \"J.D.\" & Jane Roe"
        for prefix in ["Authors: ", "Author: ", "Written by ", "Words and Music by ", "Words & Music by ", "Lyrics by ", "Music by "] {
            let document = LyricsParser.parseDocument("Verse 1\nWe sing with joy\n\n" + prefix + authors + "\n© 2018 Publisher")
            XCTAssertEqual(document.metadata["authors"], authors)
        }
    }

    func testNoticeCapturesPreserveUnicodeSourceWhileUsingSharedMarkerComparison() {
        let title = "Grace: A\u{200D}ges"
        let authors = "J\u{200D}ane Doe: John Roe"
        let credit = "“" + title + "\" Wo\u{200D}rds\u{00A0}&\tMusic by " + authors
        let permission = "Used by Permis\u{200D}sion."
        let notice = "  " + credit + "  \n© 2018 Good Music Co.\n" + permission + "\tCCLI Li\u{200D}cense #12345."
        let document = LyricsParser.parseDocument("Verse 1\nWe sing with joy\n\n" + notice)
        XCTAssertEqual(Array((document.metadata["credit-song-title"] ?? "").utf8), Array(title.utf8))
        XCTAssertEqual(Array((document.metadata["authors"] ?? "").utf8), Array(authors.utf8))
        XCTAssertEqual(Array((document.metadata["rights"] ?? "").utf8), Array(permission.utf8))
        XCTAssertEqual(Array((document.metadata["copyright-footer"] ?? "").utf8), Array(notice.utf8))
        XCTAssertEqual(document.metadata["ccli-licensenumber"], "12345")
    }

    func testCapturedTitleAndWriterKeepLeadingAndTerminalUnicodeShapingScalars() {
        let title = "\u{200D}കൃപ\u{200D}"
        let authors = "\u{200D}ജോണ്\u{200D}"
        for prefix in ["“" + title + "\" Words and Music by ", "Authors: "] {
            let notice = prefix + authors + "\n© 2018 Publisher\nUsed by Permission. CCLI License #12345"
            let document = LyricsParser.parseDocument("Verse 1\nWe sing with joy\n\n" + notice)
            XCTAssertEqual(Array((document.metadata["authors"] ?? "").utf8), Array(authors.utf8))
            XCTAssertEqual(Array((document.metadata["authors"] ?? "").unicodeScalars), Array(authors.unicodeScalars))
            if prefix.hasPrefix("“") {
                XCTAssertEqual(Array((document.metadata["credit-song-title"] ?? "").utf8), Array(title.utf8))
                XCTAssertEqual(Array((document.metadata["credit-song-title"] ?? "").unicodeScalars), Array(title.unicodeScalars))
            }
            XCTAssertEqual(Array((document.metadata["copyright-footer"] ?? "").utf8), Array(notice.utf8))
        }
    }

    func testMalformedOrSungNoticeLinesRemainLyricContent() {
        for line in [
            "\"Hallelujah\" words and music John Doe",
            "“Hallelujah words and music by John Doe",
            "“\" words and music by John Doe",
            "“Hallelujah\" words and music by",
            "We sing \"Hallelujah\" words and music by John Doe",
            "Holy Forever", "John Doe"
        ] {
            let source = "Verse 1\nWe sing with joy\n" + line + "\n© 2018 Publisher\nUsed by Permission. CCLI License #12345."
            let document = LyricsParser.parseDocument(source)
            XCTAssertEqual(document.slides.first?.lines.first?.text, "We sing with joy\n" + line)
            XCTAssertNil(document.metadata["authors"])
            XCTAssertNil(document.metadata["credit-song-title"])
        }
    }

    func testMalformedInlineLicencesDoNotConfirmATrailingNotice() {
        for line in [
            "Used by Permission. CCLI License #abc.",
            "Used by Permission. CCLI License #12345 and more lyrics",
            "Used by Permission. CCLI Song #12345.",
            "We sing by permission CCLI License #12345."
        ] {
            let text = "We sing with joy\n“Title\" words and music by John Doe\n© 2018 Publisher\n" + line
            let document = LyricsParser.parseDocument("Verse 1\n" + text)
            XCTAssertTrue(document.metadata.isEmpty)
            XCTAssertEqual(document.slides.first?.lines.first?.text, text)
        }
    }

    func testNoticeMustBeTrailingAndCannotConsumeSectionsOrUnanchoredLyrics() {
        let credit = "“Title\" words and music by John Doe"
        let notice = credit + "\n© 2018 Publisher\nUsed by Permission. CCLI License #12345."
        let interrupted = LyricsParser.parseDocument("Verse 1\nWe sing with joy\n" + notice + "\nChorus\nKeep this chorus")
        XCTAssertTrue(interrupted.metadata.isEmpty)
        XCTAssertEqual(interrupted.slides.last?.lines.first?.text, "Keep this chorus")
        XCTAssertTrue(interrupted.slides.first?.lines.first?.text.contains(notice) == true)
        let unanchored = LyricsParser.parseDocument("Verse 1\nWe sing with joy\n" + credit)
        XCTAssertTrue(unanchored.metadata.isEmpty)
        XCTAssertEqual(unanchored.slides.first?.lines.first?.text, "We sing with joy\n" + credit)
    }

    func testRecognizedNoticeStaysByteExactAndProtectedDuringCleanup() {
        let notice = "“Hallelujah\" words and music by John Doe\n© 2018 GOOD MUSIC CO.\nUsed by Permission. CCLI License #12345."
        let source = "#title: ORIGINAL TITLE\nVerse 1\nWE SING WITH JOY\nTransliteration\nwe sing with joy\n\n" + notice
        let cleaned = LyricsCleanupEngine.clean(source).proposed
        XCTAssertTrue(cleaned.hasSuffix(notice))
        XCTAssertTrue(cleaned.contains("Verse 1\nWe sing with joy\nTransliteration\nwe sing with joy"))
        XCTAssertEqual(LyricsParser.parseDocument(cleaned).metadata, LyricsParser.parseDocument(source).metadata)
        let lines = LyricsCleanupEngine.lines(in: source)
        let footer = LyricsCopyrightParser.footer(in: lines)
        XCTAssertEqual(footer?.startIndex, 6)
        XCTAssertTrue(Set(6..<lines.count).isSubset(of: LyricsParser.protectedLineIndexesForCleanup(source)))
    }

    func testVerseViewCreditsDoNotBecomeTransliterationOrASlide() {
        let lyric = """
        ആ ക്രൂശിത രൂപത്തിൽ നോക്കി
        ഒന്നനുതപിക്കാൻ കഴിഞ്ഞെങ്കിൽ(2)
        ആ വചനങ്ങൾ അനുസരിച്ചെന്നും
        ഒന്നു ജീവിക്കാൻ കഴിഞ്ഞിരുന്നെങ്കിൽ;
        ആ കരതാരിൽ മുഖമൊന്നുമർത്തി
        """
        let transliteration = """
        aa krooshitha ropathil nokki
        onnanuthapikkaan kazhinjengkil(2)
        aa vachanangal anusarichennum
        onnu jeevikkan kazhinjirunnengkil
        aa karathaaril mukhamonnumarthi
        """
        let credit = "© Unknown - VerseView Song Database ID : 218976"
        for gap in ["\n", "\n\n"] {
            let source = "Verse 4\n" + lyric + "\n\nTransliteration\n" + transliteration + gap + "Unknown\n" + credit
            let document = LyricsParser.parseDocument(source)
            XCTAssertEqual(document.slides.count, 1)
            if gap == "\n\n" {
                XCTAssertEqual(document.slides.first?.lines.map(\.text), [lyric, transliteration])
                XCTAssertNil(document.metadata["authors"])
                XCTAssertEqual(document.metadata["copyright"], credit)
                XCTAssertEqual(document.metadata["verseview-song-id"], "218976")
                XCTAssertEqual(document.metadata["copyright-footer"], "Unknown\n" + credit)
            } else {
                // No separate © paragraph: holder identity no longer guesses
                // which unlabelled line belongs to copyright rather than song.
                XCTAssertEqual(document.slides.first?.lines.map(\.text), [lyric, transliteration + "\nUnknown\n" + credit])
                XCTAssertTrue(document.metadata.isEmpty)
            }
        }
    }

    func testCommonCCLINumberAndLicenceVariantsUseSharedFooterRecognition() {
        let variants = [
            ("CCLI Song #123", "CCLI License #456"),
            ("CCLI Song No. 123", "CCLI Licence No. 456"),
            ("CCLI Song Number: 123", "CCLI License Number: 456"),
            ("ccli song: 123", "ccli licence: 456")
        ]
        for (song, license) in variants {
            let document = LyricsParser.parseDocument("Verse 1\nWe gather here\n\n" + song + "\n" + license)
            XCTAssertEqual(document.slides.first?.lines.first?.text, "We gather here")
            XCTAssertEqual(document.metadata["ccli-songnumber"], "123")
            XCTAssertEqual(document.metadata["ccli-licensenumber"], "456")
        }
    }

    func testCopyrightDoesNotRequireCCLINumbersAndRetainsAllCreditText() {
        for copyright in ["© 2026 Example Music", "(c) 2026 Example Music", "Copyright 2026 Example Music", "© 2025–2026 Example Music"] {
            let footer = "Words and Music by Jane Doe\n" + copyright + "\nAll rights reserved.\nPublished by Example Publishing"
            let document = LyricsParser.parseDocument("Verse\nWe gather here\n\n" + footer)
            XCTAssertEqual(document.slides.first?.lines.first?.text, "We gather here")
            XCTAssertEqual(document.metadata["authors"], "Jane Doe")
            XCTAssertEqual(document.metadata["copyright"], copyright)
            XCTAssertEqual(document.metadata["copyright-footer"], footer)
        }
    }

    func testUnlabelledFinalLyricAndMetadataLikeWordsRemainContent() {
        for lyric in ["Unknown", "Reuben Morgan", "All rights reserved for the King", "© We sing together"] {
            let document = LyricsParser.parseDocument("Verse 1\nWe gather here\n" + lyric + "\nCCLI Song #123\nCCLI Licence #456")
            XCTAssertEqual(document.slides.first?.lines.first?.text, "We gather here\n" + lyric)
            XCTAssertNil(document.metadata["authors"])
        }
        let interrupted = "Verse 1\nWe gather here\nCCLI Song #123\nThis is another lyric"
        XCTAssertTrue(LyricsParser.parseDocument(interrupted).metadata.isEmpty)
    }

    func testExplicitCopyrightAndLicenceLabelsWorkWithoutAYearOrCCLINumber() {
        for credit in ["Copyright: Public Domain", "License: Creative Commons Attribution 4.0", "Licence: Used by permission"] {
            let document = LyricsParser.parseDocument("Verse 1\nWe gather here\n\n" + credit)
            XCTAssertEqual(document.slides.first?.lines.first?.text, "We gather here")
            XCTAssertEqual(document.metadata["copyright-footer"], credit)
        }
    }

    func testReviewedExplicitFooterPreservesFreeformCreditsAndProtectsFollowingSections() {
        let footer = "Jane Doe\nCopyright held by Example Music\nLicensed under the venue agreement"
        let source = "Verse 1\nWe gather here\n\n[Copyright]\n" + footer
        let document = LyricsParser.parseDocument(source)
        XCTAssertEqual(document.slides.first?.lines.first?.text, "We gather here")
        XCTAssertEqual(document.metadata["copyright-footer"], footer)
        let misplaced = "Verse 1\nWe gather here\n[Copyright]\nCopyright held by Example Music\nChorus\nKeep this chorus"
        let content = LyricsParser.parseDocument(misplaced)
        XCTAssertEqual(content.slides.last?.lines.first?.text, "Keep this chorus")
        XCTAssertTrue(content.metadata.isEmpty)
    }

}
