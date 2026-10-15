import XCTest
@testable import eucaly

final class LyricsTextSyntaxTests: XCTestCase {
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
