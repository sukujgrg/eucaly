import XCTest
@testable import eucaly

final class LyricsCleanupEngineTests: XCTestCase {
    private func options(characters: Bool = false, sections: Bool = false, casing: Bool = false,
                         wraps: Bool = false, annotations: Bool = false) -> LyricsCleanupOptions {
        var value = LyricsCleanupOptions()
        value.cleanCharacters = characters
        value.suggestSections = sections
        value.naturalLyricCasing = casing
        value.repairLineBreaks = wraps
        value.removeAnnotations = annotations
        value.correctSpelling = false
        return value
    }

    func testCharacterCleanupRepairsKnownArtifactsWithoutRecursiveDecoding() {
        let source = "Verse 1\n\u{FEFF}We&#39;re\u{00A0}singing &amp; dancing â€™todayâ€™\u{200B}\nKeep &amp;apos; literal �"
        let result = LyricsCleanupEngine.clean(source, options: options(characters: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe're singing & dancing ’today’\nKeep &amp;apos; literal �")
        XCTAssertTrue(result.notes.contains(where: { $0.contains("already lost") }))
        XCTAssertEqual(result.changes.map(\.category), [.characters])
        XCTAssertEqual(LyricsCleanupEngine.clean(result.proposed, options: options(characters: true)).proposed, result.proposed)
    }

    func testMetadataAndTitleRemainExactDuringCharacterAndCaseCleanup() {
        let source = "#title: WE&#39;RE HERE\nVerse 1\nWE GATHER HERE WITH JOY\n\nCCLI Song # 12345\nAuthors: A NAME\n© 2026 WE&#39;RE PUBLISHING\nCCLI License # 54321"
        let result = LyricsCleanupEngine.clean(source, options: options(characters: true, casing: true))
        XCTAssertTrue(result.proposed.hasPrefix("#title: WE&#39;RE HERE\n"))
        XCTAssertTrue(result.proposed.hasSuffix("CCLI Song # 12345\nAuthors: A NAME\n© 2026 WE&#39;RE PUBLISHING\nCCLI License # 54321"))
        XCTAssertEqual(LyricsParser.parseDocument(result.proposed).metadata, LyricsParser.parseDocument(source).metadata)
    }

    func testUnsectionedStanzasGetHeadingsWithoutChangingSlideBoundaries() {
        let source = "We gather here\nWe sing with joy\n\nAnother day begins\nA welcome for us all\n\nWe gather here\nWe sing with joy"
        let result = LyricsCleanupEngine.clean(source, options: options(sections: true))
        XCTAssertEqual(result.proposed, "Chorus\nWe gather here\nWe sing with joy\n\nVerse 1\nAnother day begins\nA welcome for us all\n\nChorus\nWe gather here\nWe sing with joy")
        let original = LyricsParser.parseDocument(source)
        let proposed = LyricsParser.parseDocument(result.proposed)
        XCTAssertEqual(proposed.slides.count, original.slides.count)
        XCTAssertEqual(proposed.slides.map { $0.lines.map(\.text) }, original.slides.map { $0.lines.map(\.text) })
    }

    func testSingleContinuousStanzaGetsVerseWithoutInventedLineCountBoundaries() {
        let source = "We gather here\nand sing with joy\nthrough every season\nwe walk together\nand help each other"
        let result = LyricsCleanupEngine.clean(source, options: options(sections: true))
        XCTAssertEqual(result.proposed, "Verse 1\n" + source)
        XCTAssertEqual(LyricsParser.parseDocument(result.proposed).slides.count, 1)
    }

    func testCompanionsRemainWithTheirPrimaryStanza() {
        let source = "അദ്ഭുത കൃപ\n\nMeaning\nAmazing grace\n\nTransliteration\nalbhutha krupa\n\nഅടുത്ത പാട്ട്"
        let result = LyricsCleanupEngine.clean(source, options: options(sections: true, casing: true))
        let original = LyricsParser.parseDocument(source)
        let proposed = LyricsParser.parseDocument(result.proposed)
        XCTAssertEqual(proposed.slides.count, original.slides.count)
        XCTAssertEqual(proposed.slides.map { $0.lines.map { [$0.languageTag, $0.text] } }, original.slides.map { $0.lines.map { [$0.languageTag, $0.text] } })
        XCTAssertTrue(result.proposed.contains("Meaning\nAmazing grace\n\nTransliteration\nalbhutha krupa"))
    }

    func testExplicitSeparatorsAndBlankLinesInsideLabelledVerseArePreserved() {
        for source in ["one\n---\ntwo\n\nthree", "Verse 1\nFirst line\n\nSecond line\n\nChorus\nThird line"] {
            let result = LyricsCleanupEngine.clean(source, options: options(sections: true))
            XCTAssertEqual(LyricsParser.parseDocument(result.proposed).slides.map { $0.lines.map(\.text) },
                           LyricsParser.parseDocument(source).slides.map { $0.lines.map(\.text) })
        }
    }

    func testNaturalLyricCasingCapitalizesEveryLine() {
        let source = "Verse 1\nwe gather here\nand sing with joy. i will\npraise the LORD"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe gather here\nAnd sing with joy. I will\nPraise the LORD")
    }

    func testBasicCasingPreservesNamesAndRecognizedDivineReferences() {
        let source = "Verse 1\nwe follow Jesus\nand Mary sings. we praise Him\nwe see Your love on TV"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe follow Jesus\nAnd Mary sings. We praise Him\nWe see Your love on TV")
        XCTAssertTrue(result.notes.contains { $0.contains("uncertain names") })
        XCTAssertFalse(result.notes.contains { $0.contains("Apple Intelligence") })
    }

    func testAllCapsBecomesNaturalCasingWithReviewNote() {
        let source = "Verse 1\nWE GATHER HERE\nAND SING WITH JOY"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe gather here\nAnd sing with joy")
        XCTAssertTrue(result.notes.contains(where: { $0.contains("All-caps") }))
    }

    func testUsPronounAndAuthoredAcronymsAndUnfamiliarNames() {
        let uppercase = LyricsCleanupEngine.clean("Verse 1\nHE LEADS US\nAND WE SING WITH JOY IN THE USA", options: options(casing: true))
        XCTAssertEqual(uppercase.proposed, "Verse 1\nHe leads us\nAnd we sing with joy in the USA")
        let authored = LyricsCleanupEngine.clean("Verse 1\nwe welcome Aoife\nand visit the UK. we follow McDonald", options: options(casing: true))
        XCTAssertEqual(authored.proposed, "Verse 1\nWe welcome Aoife\nAnd visit the UK. We follow McDonald")
    }

    func testLyricLineStartsKeepOpeningPunctuationSpacingAndDeliberateNames() {
        let source = "  (we sing)\n\t‘and we pray’\niPhone brings us together\nMcDonald sings. we sing again"
        XCTAssertEqual(LyricsCleanupEngine.capitalizingLyricLineStarts(in: source),
                       "  (We sing)\n\t‘And we pray’\niPhone brings us together\nMcDonald sings. We sing again")
    }

    func testOrdinaryLambsKingsAndFathersAreNotMechanicallyPromotedToTitles() {
        let source = "Verse 1\nwe watch a lamb\nand greet a king\nwe visit our father"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe watch a lamb\nAnd greet a king\nWe visit our father")
        let ordinary = LyricsCleanupEngine.clean("Verse 1\nwe sing with joy", options: options(casing: true))
        XCTAssertFalse(ordinary.notes.contains { $0.contains("Divine titles") })
    }

    func testBasicWrapRepairPrecedesCapitalizingRetainedLyricLines() {
        let source = "WE GATHER TO WORSHIP AND SING IN THIS ROOM TOGETHER AS ONE FAMILY WITH HOPE\nwith joy"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true, wraps: true))
        XCTAssertEqual(result.proposed, "We gather to worship and sing in this room together as one family with hope with joy")
    }

    func testBasicLyricCasingPreservesLordPossessivesExactly() {
        let source = "Verse 1\nWE SING OF THE LORD'S MERCY\nAND KNOW THE LORD’S LOVE\nWE SING OF Lord's GRACE\nAND KNOW Lord’s NAME"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe sing of the LORD'S mercy\nAnd know the LORD’S love\nWe sing of Lord's grace\nAnd know Lord’s name")
    }

    func testTitleCaseFormattingNormalizesOrdinaryWordsAndPreservesPublicNames() {
        let source = "Verse 1\nWe Welcome Aoife And Beatrix\nWe Travel To Paris With NASA\nA Thousand Generations Sing With Joy"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe welcome Aoife and Beatrix\nWe travel to Paris with NASA\nA thousand generations sing with joy")
        XCTAssertTrue(result.notes.contains { $0.contains("Title-case formatting was normalized locally") })
    }

    func testLocalWorshipCasingRepairsOriginalAndPreviouslyCleanedSources() {
        var proposals: [String] = []
        for source in [LyricsCleanupTestFixtures.worshipCasingSource, LyricsCleanupTestFixtures.worshipCasingReportedResult] {
            let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
            proposals.append(result.proposed)
            XCTAssertEqual(result.proposed.lowercased(), source.lowercased())
            XCTAssertEqual(result.proposed.components(separatedBy: "Lamb").count - 1, 4)
            XCTAssertTrue(result.proposed.contains("A thousand generations\nFalling down in worship"))
            XCTAssertTrue(result.proposed.contains("If you've been forgiven\nIf you've been redeemed"))
            XCTAssertTrue(result.proposed.contains("If you walk in freedom\nIf you bear His name"))
            XCTAssertTrue(result.proposed.contains("Hear Your people sing, holy\nTo the King of Kings, holy"))
            XCTAssertEqual(result.proposed.filter { $0 == "," }.count, 9)
            XCTAssertEqual(LyricsParser.parseDocument(result.proposed).slides.map(\.label), LyricsParser.parseDocument(source).slides.map(\.label))
            XCTAssertTrue(LyricsCleanupEngine.primaryText(in: result.proposed).components(separatedBy: "\n").allSatisfy {
                $0.first(where: \.isLetter)?.isUppercase == true
            })
            XCTAssertEqual(LyricsCleanupEngine.clean(result.proposed, options: options(casing: true)).proposed, result.proposed)
        }
        XCTAssertEqual(proposals[0], proposals[1])
    }

    func testLocalContextKeepsLiteralAndDivineSensesSeparateInTheSameStanza() {
        let source = "Verse 1\nWe Sing To The Lamb Of God\nOur Little Lamb Follows An Earthly King\nWe Greet Our Human Father\nWe Praise The King Of Kings\nWe Call On The Holy Spirit\nWe Pray To Our Father In Heaven"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe sing to the Lamb of God\nOur little lamb follows an earthly king\nWe greet our human father\nWe praise the King of Kings\nWe call on the Holy Spirit\nWe pray to our Father in heaven")
        XCTAssertEqual(result.proposed.lowercased(), source.lowercased())
    }

    func testHumanAudiencePredicatesDoNotLeakAcrossPrayerClauses() {
        let source = "Verse 1\nWe Sing To The Lamb\nIf You've Been Forgiven, We Praise His Name\nIf You Walk In Freedom, If You Speak, I Will Follow\nIf You Bear His Name\nWe Greet Our Human Father And Remember His Name"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe sing to the Lamb\nIf you've been forgiven, we praise His name\nIf you walk in freedom, if You speak, I will follow\nIf you bear His name\nWe greet our human father and remember his name")
        XCTAssertTrue(result.notes.contains { $0.contains("uncertain names, titles and pronoun references") })
    }

    func testUncertainAuthoredTitlesStayAuthoredWithAReviewNote() {
        let source = "Verse 1\nwe ponder the Lamb\nwe hear Your story\nwe sing with joy"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe ponder the Lamb\nWe hear Your story\nWe sing with joy")
        XCTAssertTrue(result.notes.contains { $0.contains("uncertain names, titles and pronoun references") })
        XCTAssertFalse(result.notes.contains { $0.contains("Analyze with Apple Intelligence") })
    }

    func testHumanRelationshipsAndNamedPeopleDoNotInheritNearbyDivineCasing() {
        let titleCase = "Verse 1\nWe Worship The Lamb Of God\nThe Child Walks Beside Her Father\nWe Thank John For His Love\nWe Honour The King Of Kings"
        let result = LyricsCleanupEngine.clean(titleCase, options: options(casing: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe worship the Lamb of God\nThe child walks beside her father\nWe thank John for his love\nWe honour the King of Kings")
        let authored = "Verse 1\nwe worship God.\nwe thank John for his love"
        XCTAssertEqual(LyricsCleanupEngine.clean(authored, options: options(casing: true)).proposed,
                       "Verse 1\nWe worship God.\nWe thank John for his love")
    }

    func testPublicNameEvidenceKeepsMultiwordTitlesWithoutFreezingPronounVerbPhrases() {
        let source = "Verse 1\nWe Sing To The Lamb Of God\nWe Pray At Our Lady Of Lourdes\nWe Walk With Aoife And Beatrix"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe sing to the Lamb of God\nWe pray at Our Lady of Lourdes\nWe walk with Aoife and Beatrix")
        let names = LyricsCleanupEngine.recognizedNames(in: "We Sing To The Lamb Of God\nWe Pray At Our Lady of Lourdes", ignoringTitleCasePhrases: true)
        XCTAssertFalse(names.contains("sing"))
        XCTAssertTrue(names.contains("lourdes"))
    }

    func testUncertainAuthoredReligiousTitlesArePreservedAndExplicitSpiritCompoundsResolve() {
        let source = "Verse 1\nYou Are My Savior And Redeemer\nWe Know The Saviour And Almighty\nWe Welcome The Spirit Of God\nWe Hear The Spirit Of The Lord\nWe Consider The Spirit"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
        XCTAssertEqual(result.proposed, "Verse 1\nYou are my Savior and Redeemer\nWe know the Saviour and Almighty\nWe welcome the Spirit of God\nWe hear the Spirit of the Lord\nWe consider the Spirit")
        XCTAssertTrue(result.notes.contains { $0.contains("uncertain names, titles and pronoun references") })
    }

    func testUnsafeUnicodeCasingStaysAuthoredWhileOtherWordsAreCleaned() {
        let source = "Verse 1\nWE SING ß ı ſ ǰ ﬃ WITH JOY\nWE SING CAFÉ\nWE SING CAFE\u{301}"
        let result = LyricsCleanupEngine.clean(source, options: options(casing: true))
        XCTAssertEqual(Array(result.proposed.lowercased().utf8), Array(source.lowercased().utf8))
        XCTAssertTrue(result.proposed.contains("We sing ß ı ſ ǰ ﬃ with joy"))
        XCTAssertTrue(result.notes.contains { $0.contains("Unicode case conversion") })
        XCTAssertEqual(LyricsCleanupEngine.safeCasingForms(for: "café")?.capital, "Café")
        XCTAssertTrue(LyricsCleanupEngine.safeCasingForms(for: "ß") == nil)
        XCTAssertTrue(LyricsCleanupEngine.safeCasingForms(for: "ı") == nil)
        XCTAssertTrue(LyricsCleanupEngine.safeCasingForms(for: "ſ") == nil)
    }

    func testMultilingualShapingAndUncertainCaseRemainIntact() {
        let source = "Verse 1\nഅദ്ഭുത കൃപ\nक्\u{200D}ष\nمی\u{200C}خوانم\n\nTransliteration\nAlbhutha Krupa"
        let result = LyricsCleanupEngine.clean(source, options: options(characters: true, casing: true))
        XCTAssertEqual(Array(result.proposed.utf8), Array(source.utf8))
    }

    func testSplitWordsRepairWithinAStanzaButNeverAcrossHeadersOrCompanions() {
        let source = "Verse 1\nWe sing ama-\nzing grace\n\nVerse 2\nA hope un-\n\nMeaning\nbroken"
        let result = LyricsCleanupEngine.clean(source, options: options(wraps: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe sing ama-zing grace\n\nVerse 2\nA hope un-\n\nMeaning\nbroken")
        XCTAssertTrue(result.notes.contains(where: { $0.contains("compound words") }))
    }

    func testBasicWrapRepairRetainsCompoundHyphens() {
        let result = LyricsCleanupEngine.clean("Verse 1\nWe follow a well-\nknown path", options: options(wraps: true))
        XCTAssertEqual(result.proposed, "Verse 1\nWe follow a well-known path")
    }

    func testAnnotationsRequireOptInAndDoNotEraseSungParentheticalsOrCredits() {
        let source = "Verse 1\nG C Am F\n[G]We gather here\n(We sing together)\n(Repeat chorus x2)\nhttps://example.com/song\n\n© 2026 Publisher"
        let untouched = LyricsCleanupEngine.clean(source, options: options())
        XCTAssertEqual(untouched.proposed, source)
        XCTAssertTrue(untouched.notes.contains(where: { $0.contains("annotations were found") }))
        let removed = LyricsCleanupEngine.clean(source, options: options(annotations: true))
        XCTAssertEqual(removed.proposed, "Verse 1\nWe gather here\n(We sing together)\n\n© 2026 Publisher")
    }

    func testRepeatedCleanupDoesNotAddDuplicateSectionHeadings() {
        let source = "We gather here\n\nWe sing with joy"
        let first = LyricsCleanupEngine.clean(source, options: options(sections: true)).proposed
        XCTAssertEqual(LyricsCleanupEngine.clean(first, options: options(sections: true)).proposed, first)
    }

    func testLargeAuthoredVerseOrdinalCannotOverflowSectionSuggestions() {
        let source = "Verse \(Int.max)\nFirst lyric\n---\nSecond lyric"
        let proposed = LyricsCleanupEngine.clean(source, options: options(sections: true)).proposed
        XCTAssertEqual(proposed, "Verse \(Int.max)\nFirst lyric\n---\nVerse 1\nSecond lyric")
        XCTAssertEqual(LyricsParser.parseDocument(proposed).slides.count, 2)
        XCTAssertEqual(LyricsCleanupEngine.nextVerseNumber(used: [1, .max]), 2)
    }

    func testVerseViewCreditsStayExactAndAreNotLabelledAsAnotherVerse() {
        let source = LyricsCleanupTestFixtures.verseViewTail
        let result = LyricsCleanupEngine.clean(source)
        XCTAssertEqual(result.proposed, source)
        XCTAssertTrue(result.notes.contains(where: { $0.contains("Recognized licence or copyright") }))
        let document = LyricsParser.parseDocument(result.proposed)
        XCTAssertEqual(document.slides.count, 1)
        XCTAssertFalse(document.slides[0].lines.contains { $0.text.contains("VerseView") || $0.text.contains("Unknown") })
        var disabled = LyricsCleanupOptions()
        disabled.identifyCopyright = false
        XCTAssertFalse(LyricsCleanupEngine.clean(source, options: disabled).notes.contains { $0.contains("Recognized licence or copyright") })
    }

    func testFilenameBackedUnheadedTitleRemainsProtected() {
        let source = "My Song\n\nWE GATHER HERE\nAND SING WITH JOY\n\nANOTHER DAY BEGINS"
        var options = LyricsCleanupOptions()
        options.sourceFileName = "My Song.txt"
        let result = LyricsCleanupEngine.clean(source, options: options)
        XCTAssertTrue(result.proposed.hasPrefix("My Song\n\nVerse 1\n"))
        let original = LyricsParser.parseDocument(source, fileName: options.sourceFileName)
        let proposed = LyricsParser.parseDocument(result.proposed, fileName: options.sourceFileName)
        XCTAssertEqual(proposed.metadata["title"], original.metadata["title"])
        XCTAssertEqual(proposed.slides.count, original.slides.count)
        XCTAssertFalse(proposed.slides.contains { $0.lines.contains { $0.text.contains("My Song") } })
    }
}

nonisolated enum LyricsCleanupTestFixtures {
    static let verseViewTail = """
    Verse 4
    ആ ക്രൂശിത രൂപത്തിൽ നോക്കി
    ഒന്നനുതപിക്കാൻ കഴിഞ്ഞെങ്കിൽ(2)
    ആ വചനങ്ങൾ അനുസരിച്ചെന്നും
    ഒന്നു ജീവിക്കാൻ കഴിഞ്ഞിരുന്നെങ്കിൽ;
    ആ കരതാരിൽ മുഖമൊന്നുമർത്തി

    Transliteration
    aa krooshitha ropathil nokki
    onnanuthapikkaan kazhinjengkil(2)
    aa vachanangal anusarichennum
    onnu jeevikkan kazhinjirunnengkil
    aa karathaaril mukhamonnumarthi

    Unknown
    © Unknown - VerseView Song Database ID : 218976
    """
    static let worshipCasingSource = """
    #title: Holy Forever

    Verse 1
    A Thousand Generations
    Falling Down In Worship
    To Sing The Song Of Ages To The Lamb
    And All Who've Gone Before Us And All Who Will Believe
    Will Sing The Song Of Ages To The Lamb

    Pre-Chorus
    Your Name Is The Highest
    Your Name Is The Greatest
    Your Name Stands Above Them All
    All Thrones And Dominions
    All Powers And Positions
    Your Name Stands Above Them All

    Chorus 1
    And the angels cry, Holy
    All creation cries, Holy
    You are lifted high, Holy
    Holy Forever

    Verse 2
    If You've Been Forgiven
    If You've Been Redeemed
    Sing The Song Forever To The Lamb

    Verse 2
    If You Walk In Freedom
    If You Bear His Name
    Sing The Song Forever To The Lamb
    We'll Sing The Song Forever And Amen

    Chorus 2
    And the angels cry, Holy
    All creation cries, Holy
    You are lifted high, Holy
    Holy Forever

    Chorus 2
    Hear your people sing, Holy
    To The King Of Kings, Holy
    You will always be, Holy
    Holy Forever

    Bridge
    Your Name is the Highest
    Your Name is the Greatest
    Your Name Stands above them all
    All thrones and dominions
    All powers and positions
    Your Name stands above them all
    """

    static let worshipCasingReportedResult = """
    #title: Holy Forever

    Verse 1
    A thousand generations
    falling down in worship
    to sing the song of ages to the lamb
    and all who've gone before us and all who will believe
    will sing the song of ages to the lamb

    Pre-Chorus
    Your name is the highest
    Your name is the greatest
    Your name stands above them all
    all thrones and dominions
    all powers and positions
    Your name stands above them all

    Chorus 1
    And the angels cry, holy
    all creation cries, holy
    You are lifted high, holy
    holy forever

    Verse 2
    If You've been forgiven
    if You've been redeemed
    sing the song forever to the lamb

    Verse 2
    If You walk in freedom
    if You bear His name
    sing the song forever to the lamb
    we'll sing the song forever and amen

    Chorus 2
    And the angels cry, holy
    all creation cries, holy
    You are lifted high, holy
    holy forever

    Chorus 2
    Hear your people sing, holy
    to the king of kings, holy
    You will always be, holy
    holy forever

    Bridge
    Your name is the highest
    Your name is the greatest
    Your name stands above them all
    all thrones and dominions
    all powers and positions
    Your name stands above them all
    """

}
