import XCTest
@testable import eucaly

final class LyricsCleanupParserProtectionTests: XCTestCase {
    func testExplicitTitleAndValidatedCCLIFooterUseOriginalLineIndexes() {
        let source = "#title: WE GATHER\r\nVerse 1\r\nWe gather here\r\n\r\nCCLI Song #123\r\nAuthors: Jane Doe\r\n© 2026 Example\r\n"
        XCTAssertEqual(LyricsParser.protectedLineIndexesForCleanup(source), [0, 4, 5, 6, 7])
        XCTAssertEqual(LyricsParser.parseDocument(source).metadata["title"], "WE GATHER")
    }

    func testLegacyTitleUsesParserEvidenceAndUnlabelledStanzasRemainLyrics() {
        XCTAssertEqual(LyricsParser.protectedLineIndexesForCleanup("\nGather Together\n\nVerse 1\nWe gather here"), [1])
        XCTAssertTrue(LyricsParser.protectedLineIndexesForCleanup("We gather here\n\nWith joy").isEmpty)
        XCTAssertTrue(LyricsParser.protectedLineIndexesForCleanup("Authors: we sing\nWith joy").isEmpty)
    }

    func testFilenameEvidenceProtectsAnUnmarkedTitleWithoutGuessingOtherStanzas() {
        let source = "Gather Together\n\nWe gather here\nwith joy"
        XCTAssertEqual(LyricsParser.protectedLineIndexesForCleanup(source, fileName: "Gather Together.txt"), [0])
        XCTAssertTrue(LyricsParser.protectedLineIndexesForCleanup(source, fileName: "Another song.txt").isEmpty)
        XCTAssertEqual(LyricsParser.parseDocument(source, fileName: "Gather Together.txt").metadata["title"], "Gather Together")
    }

    func testCleanupStanzasUseTheSameBoundariesAsProjection() {
        let samples = [
            "We sing\n\nWith joy\n\nMeaning\nஅர்த்தம்\n\nTogether",
            "Verse 1\nWe sing\n\nWith joy\n\nChorus\nTogether",
            "#title: Gather\n\nVerse 1\nWe sing\n---\nWith joy\n\nTogether",
            "\n---\n\nOne\n\nMeaning\nMeaning one\n---\nTwo\n---\n\nThree\n"
        ]
        for source in samples {
            let lines = LyricsTextSanitizer.normalizeLineEndings(source).components(separatedBy: "\n")
            let protected = LyricsParser.protectedLineIndexesForCleanup(source)
            let ranges = LyricsParser.stanzaRangesForCleanup(lines, protected: protected)
            let expected = LyricsParser.parseDocument(source).slides
            XCTAssertEqual(ranges.count, expected.count, source)
            for (range, slide) in zip(ranges, expected) {
                let mode = lines.contains(where: LyricsTextSyntax.isSeparator) ? "---\n" : ""
                let fragment = mode + range.filter { !protected.contains($0) }.map { lines[$0] }.joined(separator: "\n")
                let actual = LyricsParser.parseDocument(fragment).slides
                XCTAssertEqual(actual.count, 1, source)
                XCTAssertEqual(actual.first?.lines.map(\.text), slide.lines.map(\.text), source)
            }
        }
    }
}
