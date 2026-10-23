import XCTest
@testable import eucaly

final class LyricsFileNamingTests: XCTestCase {
    func testAuthoredTitlesKeepAllWordsAndShareExistingTitleFormatting() {
        let longTitle = "This authored title has considerably more than six words"
        for source in ["#title: " + longTitle, longTitle + "\nVerse 1\nWe sing with joy"] {
            XCTAssertEqual(LyricsFileNaming.title(from: source), longTitle)
            XCTAssertEqual(LyricsFileNaming.suggestedFileName(from: source), longTitle)
        }
        XCTAssertEqual(LyricsFileNaming.title(from: "#TiTlE: amazing grace\nVerse 1\nWe sing"), "Amazing Grace")
        XCTAssertEqual(LyricsFileNaming.suggestedFileName(from: "#title: amazing grace\nVerse 1\nWe sing"), "Amazing Grace")
        XCTAssertEqual(LyricsFileNaming.title(from: "My Song\n\nWe sing with joy", fileName: "My Song.txt"), "My Song")
    }

    func testUntitledNamesUseTheSameFirstSixPrimaryLyricWords() {
        for source in [
            "we gather here and sing with joy\nAnother lyric",
            "Verse 1\nwe gather here and sing with joy\nAnother lyric",
            "Meaning\nAn explanation is not the lyric\nVerse 1\nwe gather here and sing with joy\nTransliteration\nRomanized words",
            "\n\u{200B}\nVerse 1\nwe gather here and sing with joy\n\nAuthor\n© Unknown"
        ] {
            XCTAssertEqual(LyricsFileNaming.title(from: source), "we gather here and sing with")
            XCTAssertEqual(LyricsFileNaming.suggestedFileName(from: source), "we gather here and sing with")
        }
    }

    func testInferredNamesPreserveCasingPunctuationAndMultilingualWords() {
        for (line, expected) in [
            ("we sing Your name with joy", "we sing Your name with joy"),
            ("‘Holy,’\twe sing; Your name is\u{00A0}great", "‘Holy,’ we sing; Your name is"),
            ("ആ ക്രൂശിത രൂപത്തിൽ നോക്കി ഒന്നനുതപിക്കാൻ കഴിഞ്ഞെങ്കിൽ", "ആ ക്രൂശിത രൂപത്തിൽ നോക്കി ഒന്നനുതപിക്കാൻ കഴിഞ്ഞെങ്കിൽ"),
            ("祢的恩典 何等甘甜", "祢的恩典 何等甘甜")
        ] {
            XCTAssertEqual(LyricsFileNaming.title(from: "Verse 1\n" + line), expected)
            XCTAssertEqual(LyricsFileNaming.suggestedFileName(from: "Verse 1\n" + line), expected)
        }
    }

    func testOnlyTheFilenameProjectionRemovesInvalidPathCharacters() {
        let title = "A/B: C\\D?E%F*G|H\"I<J>K"
        XCTAssertEqual(LyricsFileNaming.title(from: "#title: " + title), title)
        XCTAssertEqual(LyricsFileNaming.suggestedFileName(from: "#title: " + title), "A B C D E F G H I J K")
        XCTAssertEqual(LyricsFileNaming.suggestedFileName(from: "#title: /:\\?%*|\"<>"), "Untitled")
    }

    func testHeadingsAndCompanionOnlyDocumentsHaveNoInferredName() {
        for source in ["", "\n\t\n", "Verse 1\n\nChorus", "Meaning\nAn explanation", "Transliteration\nRomanized words", "Translation\nTranslated words"] {
            XCTAssertNil(LyricsFileNaming.title(from: source))
            XCTAssertEqual(LyricsFileNaming.suggestedFileName(from: source), "Untitled")
        }
    }

    func testLegacyProjectionPreservesFilenameFallbackAndNormalTitles() {
        XCTAssertEqual(LyricsFileNaming.legacyCachedTitle("#title: Holy Forever", fileName: "song.txt"), "Holy Forever")
        XCTAssertEqual(LyricsFileNaming.legacyCachedTitle("#title: amazing grace", fileName: "song.txt"), "Amazing Grace")
        XCTAssertEqual(LyricsFileNaming.legacyCachedTitle("#title: fallback.txt", fileName: "#title: fallback.txt"), "#title: fallback.txt")
        XCTAssertEqual(LyricsFileNaming.legacyCachedTitle("original lowercase title", fileName: "song.txt"), "original lowercase title")
    }
}
