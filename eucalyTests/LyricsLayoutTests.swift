import AppKit
import SwiftUI
import XCTest
@testable import eucaly

final class LyricsLayoutTests: XCTestCase {
    func testColumnsGroupRepeatedComponentsWithoutLosingText() throws {
        let document = LyricsParser.parseDocument("""
        Verse
        Main lyrics
        Transliteration
        Romanized lyrics
        Meaning
        First explanation
        Translation
        Translated lyrics
        Meaning
        Second explanation
        """)
        let slide = try XCTUnwrap(document.slides.first)
        let blocks = PresentationLyricsLayout.columns.blocks(for: slide.lines)

        XCTAssertEqual(blocks.map(\.companion), [nil, .meaning, .translation, .transliteration])
        XCTAssertEqual(blocks.map(\.text), [
            "Main lyrics", "First explanation\n\nSecond explanation", "Translated lyrics", "Romanized lyrics"
        ])
        XCTAssertEqual(slide.lines.count, 5, "Layout must not rewrite the source slide.")
    }

    func testMissingAndEmptyComponentsDoNotReserveColumns() {
        let lines = [
            SlideLine(kind: .verse, languageTag: "", text: "Main lyrics"),
            SlideLine(kind: .verse, languageTag: "Meaning", text: " \n "),
            SlideLine(kind: .verse, languageTag: "Transliteration", text: "Romanized lyrics")
        ]
        let blocks = PresentationLyricsLayout.columns.blocks(for: lines)
        XCTAssertEqual(blocks.map(\.companion), [nil, .transliteration])
        XCTAssertEqual(blocks.map(\.id), [lines[0].id, lines[2].id])
        XCTAssertTrue(PresentationLyricsLayout.columns.blocks(for: []).isEmpty)
    }

    func testStackedLayoutPreservesSeparateBlocksAndTheirOrder() {
        let lines = [
            SlideLine(kind: .verse, languageTag: "", text: "Main lyrics"),
            SlideLine(kind: .verse, languageTag: "Meaning", text: "First explanation"),
            SlideLine(kind: .verse, languageTag: "Meaning", text: "Second explanation")
        ]
        let blocks = PresentationLyricsLayout.stacked.blocks(for: lines)
        XCTAssertEqual(blocks.map(\.id), lines.map(\.id))
        XCTAssertEqual(blocks.map(\.text), lines.map(\.text))
    }
}

@MainActor
final class LyricsLayoutRenderingTests: XCTestCase {
    func testReadabilityWarningUsesProjectionSettingsAndDisplaySize() throws {
        let lines = [
            SlideLine(kind: .verse, languageTag: "", text: "கர்த்தரை பாடுங்கள்"),
            SlideLine(kind: .verse, languageTag: "Meaning", text: Array(repeating: "Together we lift our voices and sing with joy.", count: 6).joined(separator: "\n")),
            SlideLine(kind: .verse, languageTag: "Transliteration", text: "Kartharai paadungal")
        ]
        let suiteName = "LyricsReadabilityTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set("columns", forKey: "presentationLyricsLayout")
        preferences.set(1.0, forKey: "presentationPaddingScale")
        preferences.set(1.0, forKey: "presentationFontScale")

        func warning(at size: CGSize?, thumbnailScale: Double = 1) throws -> Bool {
            preferences.set(thumbnailScale, forKey: "thumbnailFontScale")
            let bitmap = try render(
                LyricsReadabilityWarning(lines: lines)
                    .environment(\.lyricsProjectionSize, size)
                    .defaultAppStorage(preferences),
                size: CGSize(width: 20, height: 20), name: "Projection readability — \(String(describing: size))"
            )
            return hasOrangePixels(in: bitmap)
        }

        XCTAssertTrue(try warning(at: CGSize(width: 960, height: 270)))
        XCTAssertTrue(try warning(at: CGSize(width: 960, height: 270), thumbnailScale: 0.3))
        XCTAssertFalse(try warning(at: CGSize(width: 1920, height: 1080)), "The warning must use the selected display's geometry.")
        XCTAssertFalse(try warning(at: nil), "Do not guess the target size when no display is available.")

        preferences.set(0.5, forKey: "presentationFontScale")
        XCTAssertTrue(try warning(at: CGSize(width: 1920, height: 1080)), "A low requested font size also needs a warning.")
        preferences.set(1.0, forKey: "presentationFontScale")
        XCTAssertFalse(try warning(at: CGSize(width: 1920, height: 1080)), "Clearing the cause must clear the warning.")
    }

    func testReadabilityWarningRespondsToPaddingAndMissingComponentsInBothLayouts() throws {
        let suiteName = "LyricsReadabilityPaddingTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set(1.0, forKey: "presentationFontScale")
        let meaning = SlideLine(kind: .verse, languageTag: "Meaning", text: "Together we lift our voices and sing with joy.")
        let lines = [
            SlideLine(kind: .verse, languageTag: "", text: "Joy"), meaning,
            SlideLine(kind: .verse, languageTag: "Transliteration", text: "Hope")
        ]

        func warning(for lines: [SlideLine], padding: Double) throws -> Bool {
            preferences.set(padding, forKey: "presentationPaddingScale")
            let bitmap = try render(
                LyricsReadabilityWarning(lines: lines)
                    .environment(\.lyricsProjectionSize, CGSize(width: 960, height: 270))
                    .defaultAppStorage(preferences),
                size: CGSize(width: 20, height: 20), name: "Readability — \(lines.count) components, padding \(padding)"
            )
            return hasOrangePixels(in: bitmap)
        }

        for layout in PresentationLyricsLayout.allCases {
            preferences.set(layout.rawValue, forKey: "presentationLyricsLayout")
            XCTAssertFalse(try warning(for: lines, padding: 0), layout.title)
            if layout == .columns {
                XCTAssertFalse(try warning(for: lines, padding: 1), "Rounded text measurements must fit fractional column widths.")
            }
            XCTAssertTrue(try warning(for: lines, padding: 2), layout.title)
            XCTAssertFalse(try warning(for: [meaning], padding: 2), "A lone component can use all the available space.")
            XCTAssertFalse(try warning(for: [], padding: 2))
            XCTAssertFalse(try warning(for: [SlideLine(kind: .verse, languageTag: "Meaning", text: " \n ")], padding: 2))
        }
    }

    func testSmallTextWarningAppearsOnOperatorCardOnly() throws {
        let slide = try XCTUnwrap(LyricsParser.parseDocument("""
        Verse
        Sing with joy
        Meaning
        \(Array(repeating: "Together we lift our voices and sing with joy.", count: 6).joined(separator: "\n"))
        Transliteration
        Sing with joy
        """).slides.first)
        let suiteName = "LyricsReadabilityCardTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set("columns", forKey: "presentationLyricsLayout")
        preferences.set(1.0, forKey: "presentationPaddingScale")
        preferences.set(1.0, forKey: "presentationFontScale")
        let session = PresentationSession()
        session.setSlides([slide])
        let displaySize = CGSize(width: 960, height: 270)

        let card = try render(
            SlideGridCellView(slide: slide, itemWidth: 320, itemHeight: 210,
                              isSelected: false, allowsPDFThumbnailRendering: false, onTap: {})
                .environment(\.lyricsProjectionSize, displaySize)
                .defaultAppStorage(preferences),
            size: CGSize(width: 340, height: 260), name: "Operator card with small Meaning warning"
        )
        XCTAssertTrue(hasOrangePixels(in: card))
        let projection = try render(
            PresentationView().environmentObject(session).defaultAppStorage(preferences),
            size: displaySize, name: "Audience slide without operator warning"
        )
        XCTAssertFalse(hasOrangePixels(in: projection))
        XCTAssertEqual(session.currentSlideID, slide.id)
        XCTAssertEqual(session.slides.first?.lines, slide.lines)
    }

    private func hasOrangePixels(in bitmap: NSBitmapImageRep) -> Bool {
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.alphaComponent > 0.5 && color.redComponent > 0.8
                    && color.greenComponent > 0.25 && color.greenComponent < 0.8
                    && color.blueComponent < 0.3 { return true }
            }
        }
        return false
    }

    func testProjectionAndThumbnailsPositionEveryColumn() throws {
        let slide = try XCTUnwrap(LyricsParser.parseDocument("""
        Verse
        Joy
        Hope
        Meaning
        Together
        Transliteration
        Sing
        With
        Joy
        """).slides.first)
        let suiteName = "LyricsLayoutRenderingTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set("columns", forKey: "presentationLyricsLayout")
        preferences.set("left", forKey: "presentationTextAlignment")
        let session = PresentationSession()
        session.setSlides([slide])

        for position in PresentationVerticalPosition.allCases {
            preferences.set(position.rawValue, forKey: "presentationVerticalPosition")
            let projection = try render(
                PresentationView().environmentObject(session).defaultAppStorage(preferences),
                size: CGSize(width: 960, height: 360),
                name: "Projection columns — \(position.title)"
            )
            let thumbnailSize = CGSize(width: 320, height: 180)
            let thumbnail = try render(
                LyricsThumbnailView(slide: slide, size: thumbnailSize).defaultAppStorage(preferences),
                size: thumbnailSize,
                name: "Thumbnail columns — \(position.title)"
            )
            for bitmap in [projection, thumbnail] {
                let boundaries = [0, bitmap.pixelsWide * 2 / 5, bitmap.pixelsWide * 3 / 5, bitmap.pixelsWide]
                for column in 0..<3 {
                    let bounds = try XCTUnwrap(whiteBounds(
                        in: bitmap,
                        xRange: boundaries[column]..<boundaries[column + 1]
                    ))
                    let height = CGFloat(bitmap.pixelsHigh)
                    switch position {
                    case .top:
                        XCTAssertLessThan(bounds.minY, height * 0.23)
                    case .middle:
                        XCTAssertEqual(bounds.midY, height / 2, accuracy: height * 0.07)
                    case .bottom:
                        XCTAssertGreaterThan(bounds.maxY, height * 0.77)
                    }
                    XCTAssertGreaterThan(bounds.minY, 0)
                    XCTAssertLessThan(bounds.maxY, height)
                }
            }
        }
        XCTAssertEqual(session.currentSlideID, slide.id)
        XCTAssertEqual(session.slides.map(\.id), [slide.id])
    }

    func testStackedLayoutMovesTogetherAndSingleColumnUsesFullWidth() throws {
        let lines = [
            SlideLine(kind: .verse, languageTag: "", text: "Joy"),
            SlideLine(kind: .verse, languageTag: "Meaning", text: "Together")
        ]
        for layout in PresentationLyricsLayout.allCases {
            for position in PresentationVerticalPosition.allCases {
                let bitmap = try render(
                    LyricsSlideContentView(
                        lines: layout == .columns ? [lines[0]] : lines,
                        size: CGSize(width: 960, height: 540),
                        layout: layout,
                        textAlignment: .right,
                        verticalPosition: position,
                        fontScale: 1,
                        paddingScale: 1,
                        rendering: .projection
                    ).background(.black),
                    size: CGSize(width: 960, height: 540),
                    name: "\(layout.title) — \(position.title)"
                )
                let bounds = try XCTUnwrap(whiteBounds(in: bitmap, xRange: 0..<bitmap.pixelsWide))
                XCTAssertGreaterThan(bounds.minX, 480, "A single component must use the full slide width.")
                switch position {
                case .top: XCTAssertLessThan(bounds.minY, 100)
                case .middle: XCTAssertEqual(bounds.midY, 270, accuracy: 25)
                case .bottom: XCTAssertGreaterThan(bounds.maxY, 440)
                }
            }
        }
    }

    func testLongMultilingualColumnsStayWithinShortDisplayMargins() throws {
        let lines = [
            SlideLine(kind: .verse, languageTag: "", text: Array(repeating: "கர்த்தரை பாடுங்கள்", count: 8).joined(separator: "\n")),
            SlideLine(kind: .verse, languageTag: "Meaning", text: Array(repeating: "Together we lift our voices and sing with joy.", count: 6).joined(separator: "\n")),
            SlideLine(kind: .verse, languageTag: "Transliteration", text: Array(repeating: "Kartharai paadungal", count: 8).joined(separator: "\n"))
        ]
        for paddingScale in [0.0, 1.0, 2.0] {
            let bitmap = try render(
                LyricsSlideContentView(
                    lines: lines, size: CGSize(width: 960, height: 270), layout: .columns,
                    textAlignment: .center, verticalPosition: .top, fontScale: 2,
                    paddingScale: paddingScale, rendering: .projection
                ).background(.black),
                size: CGSize(width: 960, height: 270),
                name: "Long multilingual columns — padding \(Int(paddingScale * 100))%"
            )
            let boundaries = [0, 384, 576, 960]
            for column in 0..<3 {
                let bounds = try XCTUnwrap(whiteBounds(in: bitmap, xRange: boundaries[column]..<boundaries[column + 1]))
                XCTAssertGreaterThanOrEqual(bounds.minY, 32 * paddingScale)
                XCTAssertLessThanOrEqual(bounds.maxY, 270 - 32 * paddingScale)
            }
        }
    }

    func testPaddingPreferenceAdjustsBothLayoutsInProjectionAndThumbnails() throws {
        let slide = try XCTUnwrap(LyricsParser.parseDocument("Verse\nJoy\nMeaning\nHope").slides.first)
        let suiteName = "LyricsPaddingRenderingTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set("left", forKey: "presentationTextAlignment")
        preferences.set("top", forKey: "presentationVerticalPosition")
        let session = PresentationSession()
        session.setSlides([slide])
        let thumbnailSize = CGSize(width: 320, height: 180)

        for layout in PresentationLyricsLayout.allCases {
            preferences.set(layout.rawValue, forKey: "presentationLyricsLayout")
            var projectionBounds: [CGRect] = []
            var thumbnailBounds: [CGRect] = []
            for padding in [0.0, 2.0] {
                preferences.set(padding, forKey: "presentationPaddingScale")
                let projection = try render(
                    PresentationView().environmentObject(session).defaultAppStorage(preferences),
                    size: CGSize(width: 960, height: 540),
                    name: "Projection \(layout.title) — padding \(Int(padding * 100))%"
                )
                let thumbnail = try render(
                    LyricsThumbnailView(slide: slide, size: thumbnailSize).defaultAppStorage(preferences),
                    size: thumbnailSize,
                    name: "Thumbnail \(layout.title) — padding \(Int(padding * 100))%"
                )
                projectionBounds.append(try XCTUnwrap(whiteBounds(in: projection, xRange: 0..<projection.pixelsWide)))
                thumbnailBounds.append(try XCTUnwrap(whiteBounds(in: thumbnail, xRange: 0..<thumbnail.pixelsWide)))
            }
            for bounds in [projectionBounds, thumbnailBounds] {
                XCTAssertLessThan(bounds[0].minX, 5, "Zero padding must remove the fixed horizontal margin.")
                XCTAssertGreaterThan(bounds[1].minX, bounds[0].minX + 10)
                XCTAssertGreaterThan(bounds[1].minY, bounds[0].minY + 10)
            }
        }
        XCTAssertEqual(session.currentSlideID, slide.id)
        XCTAssertEqual(session.slides.map(\.id), [slide.id])
    }

    func testMeaningUsesHalfAColumnAndMissingComponentsReleaseTheirWidth() throws {
        let fixtures: [(source: String, columnStarts: [Double])] = [
            ("Verse\nX\nMeaning\nX\nTransliteration\nX", [0, 0.4, 0.6]),
            ("Verse\nX\nMeaning\nX\nTranslation\nX\nTransliteration\nX", [0, 2.0 / 7, 3.0 / 7, 5.0 / 7]),
            ("Verse\nX\nTransliteration\nX", [0, 0.5]),
            ("Meaning\nX", [0])
        ]
        let suiteName = "LyricsColumnWidthTests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { preferences.removePersistentDomain(forName: suiteName) }
        preferences.set("columns", forKey: "presentationLyricsLayout")
        preferences.set("left", forKey: "presentationTextAlignment")
        preferences.set("top", forKey: "presentationVerticalPosition")
        preferences.set(0, forKey: "presentationPaddingScale")
        let session = PresentationSession()
        let thumbnailSize = CGSize(width: 320, height: 180)

        for (source, columnStarts) in fixtures {
            let slide = try XCTUnwrap(LyricsParser.parseDocument(source).slides.first)
            session.setSlides([slide])
            let projection = try render(
                PresentationView().environmentObject(session).defaultAppStorage(preferences),
                size: CGSize(width: 960, height: 360),
                name: "Projection column widths — \(columnStarts)"
            )
            let thumbnail = try render(
                LyricsThumbnailView(slide: slide, size: thumbnailSize).defaultAppStorage(preferences),
                size: thumbnailSize,
                name: "Thumbnail column widths — \(columnStarts)"
            )
            for bitmap in [projection, thumbnail] {
                let boundaries = (columnStarts + [1]).map { Int($0 * Double(bitmap.pixelsWide)) }
                for column in columnStarts.indices {
                    let bounds = try XCTUnwrap(whiteBounds(
                        in: bitmap,
                        xRange: boundaries[column]..<boundaries[column + 1]
                    ))
                    XCTAssertEqual(bounds.minX, CGFloat(boundaries[column]), accuracy: 5,
                                   "Each component must begin at its allocated column, including Meaning-only slides.")
                }
            }
        }
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String) throws -> NSBitmapImageRep {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let attachment = XCTAttachment(image: NSImage(cgImage: image, size: size))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        return NSBitmapImageRep(cgImage: image)
    }

    private func whiteBounds(in bitmap: NSBitmapImageRep, xRange: Range<Int>) -> CGRect? {
        var bounds = CGRect.null
        for y in 0..<bitmap.pixelsHigh {
            for x in xRange {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.redComponent > 0.7, color.greenComponent > 0.7, color.blueComponent > 0.7 else { continue }
                bounds = bounds.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return bounds.isNull ? nil : bounds
    }
}
