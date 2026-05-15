import XCTest
@testable import eucaly
import AppKit

final class PresentationFlowTests: XCTestCase {
    func testThumbnailGridNavigationUsesVisibleColumnCount() {
        let layout = ThumbnailGridLayout.make(for: 700, thumbnailScale: 1.0)

        XCTAssertEqual(layout.columnCount, 3)
        XCTAssertEqual(
            layout.selectionTargetIndex(
                from: 4,
                itemCount: 9,
                direction: .previousItem
            ),
            3
        )
        XCTAssertEqual(
            layout.selectionTargetIndex(
                from: 4,
                itemCount: 9,
                direction: .nextItem
            ),
            5
        )
        XCTAssertEqual(
            layout.selectionTargetIndex(
                from: 4,
                itemCount: 9,
                direction: .previousRow
            ),
            1
        )
        XCTAssertEqual(
            layout.selectionTargetIndex(
                from: 4,
                itemCount: 9,
                direction: .nextRow
            ),
            7
        )
    }

    func testThumbnailGridNavigationDoesNotJumpFromTopRowToFirstItem() {
        let layout = ThumbnailGridLayout.make(for: 1_150, thumbnailScale: 1.0)

        XCTAssertEqual(layout.columnCount, 5)
        XCTAssertEqual(
            layout.selectionTargetIndex(
                from: 1,
                itemCount: 25,
                direction: .previousRow
            ),
            1
        )
        XCTAssertEqual(
            layout.selectionTargetIndex(
                from: 4,
                itemCount: 25,
                direction: .previousRow
            ),
            4
        )
    }

    func testThumbnailGridNavigationMovesToNearestItemInPartialNextRow() {
        let layout = ThumbnailGridLayout.make(for: 1_150, thumbnailScale: 1.0)

        XCTAssertEqual(layout.columnCount, 5)
        XCTAssertEqual(
            layout.selectionTargetIndex(
                from: 19,
                itemCount: 22,
                direction: .nextRow
            ),
            21
        )
    }

    func testThumbnailGridNavigationTargetsEveryItemInFullFiveByFiveGrid() {
        let layout = ThumbnailGridLayout.make(for: 1_150, thumbnailScale: 1.0)

        XCTAssertEqual(layout.columnCount, 5)
        for index in 0..<25 {
            let row = index / layout.columnCount

            let expectedUp = row == 0 ? index : index - layout.columnCount
            let expectedDown = row == 4 ? index : index + layout.columnCount
            let expectedLeft = max(0, index - 1)
            let expectedRight = min(24, index + 1)

            XCTAssertEqual(
                layout.selectionTargetIndex(
                    from: index,
                    itemCount: 25,
                    direction: .previousRow
                ),
                expectedUp,
                "Unexpected up target from index \(index)"
            )
            XCTAssertEqual(
                layout.selectionTargetIndex(
                    from: index,
                    itemCount: 25,
                    direction: .nextRow
                ),
                expectedDown,
                "Unexpected down target from index \(index)"
            )
            XCTAssertEqual(
                layout.selectionTargetIndex(
                    from: index,
                    itemCount: 25,
                    direction: .previousItem
                ),
                expectedLeft,
                "Unexpected left target from index \(index)"
            )
            XCTAssertEqual(
                layout.selectionTargetIndex(
                    from: index,
                    itemCount: 25,
                    direction: .nextItem
                ),
                expectedRight,
                "Unexpected right target from index \(index)"
            )
        }
    }

    func testThumbnailGridNavigationTargetsEveryItemInPartialFiveColumnGrid() {
        let layout = ThumbnailGridLayout.make(for: 1_150, thumbnailScale: 1.0)
        let expectedDownTargets = [
            5, 6, 7, 8, 9,
            10, 11, 12, 13, 14,
            15, 16, 17, 18, 19,
            20, 21, 21, 21, 21,
            20, 21
        ]

        XCTAssertEqual(layout.columnCount, 5)
        XCTAssertEqual(expectedDownTargets.count, 22)
        for index in 0..<22 {
            XCTAssertEqual(
                layout.selectionTargetIndex(
                    from: index,
                    itemCount: 22,
                    direction: .nextRow
                ),
                expectedDownTargets[index],
                "Unexpected down target from index \(index)"
            )
        }
    }

    func testThumbnailGridNavigationTargetsEveryItemInThreeColumnGrid() {
        let layout = ThumbnailGridLayout.make(for: 700, thumbnailScale: 1.0)

        XCTAssertEqual(layout.columnCount, 3)
        assertGridNavigationTargets(layout: layout, itemCount: 12)
    }

    func testThumbnailGridNavigationTargetsEveryItemInSevenColumnGrid() {
        let layout = ThumbnailGridLayout.make(for: 1_650, thumbnailScale: 1.0)

        XCTAssertEqual(layout.columnCount, 7)
        assertGridNavigationTargets(layout: layout, itemCount: 28)
    }

    func testThumbnailGridNavigationTargetsEveryItemInPartialThreeColumnGrid() {
        let layout = ThumbnailGridLayout.make(for: 700, thumbnailScale: 1.0)

        XCTAssertEqual(layout.columnCount, 3)
        assertGridNavigationTargets(layout: layout, itemCount: 11)
    }

    func testThumbnailGridNavigationMovesBottomRightUpInThreeByTwoGrid() {
        let layout = ThumbnailGridLayout.make(for: 700, thumbnailScale: 1.0)

        XCTAssertEqual(layout.columnCount, 3)
        XCTAssertEqual(
            layout.selectionTargetIndex(
                from: 5,
                itemCount: 6,
                direction: .previousRow
            ),
            2
        )
    }

    func testThumbnailGridNavigationTargetsEveryItemInPartialSevenColumnGrid() {
        let layout = ThumbnailGridLayout.make(for: 1_650, thumbnailScale: 1.0)

        XCTAssertEqual(layout.columnCount, 7)
        assertGridNavigationTargets(layout: layout, itemCount: 25)
    }

    func testSetPreviewSlidesCanPreserveSelectionByIndex() async {
        let result = await MainActor.run { () -> String? in
            let flow = PresentationFlowController()

            let originalSlides = [
                Slide(
                    index: 1,
                    lines: [SlideLine(kind: .verse, languageTag: "", text: "Verse 1")],
                    label: "Verse 1",
                    videoURL: nil,
                    pdfURL: nil,
                    pdfPageIndex: nil,
                    imageURL: nil,
                    captureWindowID: nil
                ),
                Slide(
                    index: 2,
                    lines: [SlideLine(kind: .chorus, languageTag: "", text: "Chorus")],
                    label: "Chorus",
                    videoURL: nil,
                    pdfURL: nil,
                    pdfPageIndex: nil,
                    imageURL: nil,
                    captureWindowID: nil
                )
            ]

            flow.setPreviewSlides(originalSlides, preferredSelection: originalSlides[1].id)

            let rebuiltSlides = [
                Slide(
                    index: 1,
                    lines: [SlideLine(kind: .verse, languageTag: "", text: "Verse 1 updated")],
                    label: "Verse 1",
                    videoURL: nil,
                    pdfURL: nil,
                    pdfPageIndex: nil,
                    imageURL: nil,
                    captureWindowID: nil
                ),
                Slide(
                    index: 2,
                    lines: [SlideLine(kind: .chorus, languageTag: "", text: "Chorus updated")],
                    label: "Chorus",
                    videoURL: nil,
                    pdfURL: nil,
                    pdfPageIndex: nil,
                    imageURL: nil,
                    captureWindowID: nil
                )
            ]

            flow.setPreviewSlides(
                rebuiltSlides,
                preferredSelection: originalSlides[1].id,
                preferredSelectionIndex: 1
            )

            guard let selectionID = flow.previewSelectionID else { return nil }
            return flow.previewSlides.first(where: { $0.id == selectionID })?.label
        }

        XCTAssertEqual(result, "Chorus")
    }

    func testSetCurrentSlidesReplacesStaleCurrentSelection() async {
        let result = await MainActor.run { () -> (current: Slide.ID?, expected: Slide.ID?) in
            let flow = PresentationFlowController()
            let session = PresentationSession()
            let oldSlides = makeTestSlides(count: 1)
            let newSlides = makeTestSlides(count: 6)

            flow.setCurrentSlides(oldSlides, in: session)
            flow.setCurrentSlides(newSlides, in: session)

            return (session.currentSlideID, newSlides.first?.id)
        }

        XCTAssertEqual(result.current, result.expected)
    }

    func testSessionGridNavigationUsesCurrentThumbnailColumnCount() async {
        let result = await MainActor.run { () -> (current: Slide.ID?, expected: Slide.ID?) in
            let session = PresentationSession()
            let slides = makeTestSlides(count: 6)

            session.setSlides(slides)
            session.currentSlideID = slides[5].id
            session.setCurrentThumbnailColumnCount(3)
            session.moveSelection(direction: .previousRow)

            return (session.currentSlideID, slides[2].id)
        }

        XCTAssertEqual(result.current, result.expected)
    }

    func testSessionGridNavigationMovesDownByRowWhilePresenting() async {
        let result = await MainActor.run { () -> (current: Slide.ID?, expected: Slide.ID?) in
            let session = PresentationSession()
            let slides = makeTestSlides(count: 6)

            session.setSlides(slides)
            session.currentSlideID = slides[1].id
            session.setCurrentThumbnailColumnCount(3)
            session.moveSelection(direction: .nextRow)

            return (session.currentSlideID, slides[4].id)
        }

        XCTAssertEqual(result.current, result.expected)
    }

    func testHideSlidesDoesNotClearBackgroundVisual() async {
        let result = await MainActor.run { () -> (wasVisible: Bool, backgroundURL: URL?) in
            let session = PresentationSession()
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-bg.jpg")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data([0x00]), attributes: nil)
            session.setBackgroundVisual(tempURL)
            session.isPresenting = true
            session.areSlidesVisible = true

            session.hideSlides()

            return (session.areSlidesVisible, session.backgroundVisualURL)
        }

        XCTAssertFalse(result.wasVisible)
        XCTAssertNotNil(result.backgroundURL)
    }

    func testShowSlidesRestoresVisibilityWhenPresenting() async {
        let result = await MainActor.run { () -> Bool in
            let session = PresentationSession()
            session.isPresenting = true
            session.areSlidesVisible = false

            session.showSlides(preferredScreen: nil)

            return session.areSlidesVisible
        }

        XCTAssertTrue(result)
    }

    func testToggleSlidesVisibilityWhilePresentingDoesNotClearBackground() async {
        let result = await MainActor.run { () -> (firstToggleVisible: Bool, secondToggleVisible: Bool, backgroundURL: URL?) in
            let flow = PresentationFlowController()
            let session = PresentationSession()
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-bg2.jpg")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data([0x00]), attributes: nil)
            session.setBackgroundVisual(tempURL)
            session.isPresenting = true
            session.areSlidesVisible = true

            flow.toggleSlidesVisibility(in: session, preferredScreen: nil)
            let firstVisible = session.areSlidesVisible

            flow.toggleSlidesVisibility(in: session, preferredScreen: nil)
            let secondVisible = session.areSlidesVisible

            return (firstVisible, secondVisible, session.backgroundVisualURL)
        }

        XCTAssertFalse(result.firstToggleVisible)
        XCTAssertTrue(result.secondToggleVisible)
        XCTAssertNotNil(result.backgroundURL)
    }

    private func assertGridNavigationTargets(
        layout: ThumbnailGridLayout,
        itemCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for index in 0..<itemCount {
            XCTAssertEqual(
                layout.selectionTargetIndex(
                    from: index,
                    itemCount: itemCount,
                    direction: .previousItem
                ),
                expectedPreviousItemTarget(from: index),
                "Unexpected left target from index \(index)",
                file: file,
                line: line
            )
            XCTAssertEqual(
                layout.selectionTargetIndex(
                    from: index,
                    itemCount: itemCount,
                    direction: .nextItem
                ),
                expectedNextItemTarget(from: index, itemCount: itemCount),
                "Unexpected right target from index \(index)",
                file: file,
                line: line
            )
            XCTAssertEqual(
                layout.selectionTargetIndex(
                    from: index,
                    itemCount: itemCount,
                    direction: .previousRow
                ),
                expectedPreviousRowTarget(
                    from: index,
                    columnCount: layout.columnCount
                ),
                "Unexpected up target from index \(index)",
                file: file,
                line: line
            )
            XCTAssertEqual(
                layout.selectionTargetIndex(
                    from: index,
                    itemCount: itemCount,
                    direction: .nextRow
                ),
                expectedNextRowTarget(
                    from: index,
                    itemCount: itemCount,
                    columnCount: layout.columnCount
                ),
                "Unexpected down target from index \(index)",
                file: file,
                line: line
            )
        }
    }

    private func expectedPreviousItemTarget(from index: Int) -> Int {
        max(0, index - 1)
    }

    private func expectedNextItemTarget(from index: Int, itemCount: Int) -> Int {
        min(itemCount - 1, index + 1)
    }

    private func expectedPreviousRowTarget(from index: Int, columnCount: Int) -> Int {
        index < columnCount ? index : index - columnCount
    }

    private func expectedNextRowTarget(
        from index: Int,
        itemCount: Int,
        columnCount: Int
    ) -> Int {
        let targetIndex = index + columnCount
        if targetIndex < itemCount {
            return targetIndex
        }

        let nextRowStartIndex = ((index / columnCount) + 1) * columnCount
        return nextRowStartIndex < itemCount ? itemCount - 1 : index
    }

    private func makeTestSlides(count: Int) -> [Slide] {
        (0..<count).map { index in
            Slide(
                index: index + 1,
                lines: [
                    SlideLine(
                        kind: .verse,
                        languageTag: "",
                        text: "Slide \(index + 1)"
                    )
                ],
                label: "Slide \(index + 1)",
                videoURL: nil,
                pdfURL: nil,
                pdfPageIndex: nil,
                imageURL: nil,
                captureWindowID: nil
            )
        }
    }
}
