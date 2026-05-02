import XCTest
@testable import eucaly
import AppKit

final class PresentationFlowTests: XCTestCase {
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
}
