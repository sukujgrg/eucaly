import XCTest
@testable import eucaly
import AppKit

final class BackgroundControlsTests: XCTestCase {
    func testSetBackgroundVisualUpdatesVisibility() async {
        let result = await MainActor.run { () -> (visibleAfterSet: Bool, visibleAfterClear: Bool) in
            let session = PresentationSession()
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-bg-visibility.jpg")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data([0x00]), attributes: nil)

            session.setBackgroundVisual(tempURL)
            let visibleAfterSet = session.isBackgroundVisualVisible

            session.setBackgroundVisual(nil)
            let visibleAfterClear = session.isBackgroundVisualVisible

            return (visibleAfterSet, visibleAfterClear)
        }

        XCTAssertTrue(result.visibleAfterSet)
        XCTAssertFalse(result.visibleAfterClear)
    }

    func testToggleBackgroundVisualDoesNotAffectSlidesVisibility() async {
        let result = await MainActor.run { () -> (slidesVisible: Bool, backgroundVisibleAfter: Bool) in
            let session = PresentationSession()
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-bg-toggle.jpg")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data([0x00]), attributes: nil)

            session.setBackgroundVisual(tempURL)
            session.isPresenting = true
            session.areSlidesVisible = true

            session.toggleBackgroundVisualVisibility(preferredScreen: nil)

            return (session.areSlidesVisible, session.isBackgroundVisualVisible)
        }

        XCTAssertTrue(result.slidesVisible)
        XCTAssertFalse(result.backgroundVisibleAfter)
    }

    func testToggleBackgroundVisualWhenPresentingTogglesVisibility() async {
        let result = await MainActor.run { () -> (firstVisible: Bool, secondVisible: Bool) in
            let session = PresentationSession()
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("eucaly-test-bg-toggle2.jpg")
            FileManager.default.createFile(atPath: tempURL.path, contents: Data([0x00]), attributes: nil)

            session.setBackgroundVisual(tempURL)
            session.isPresenting = true
            session.areSlidesVisible = false

            session.toggleBackgroundVisualVisibility(preferredScreen: nil)
            let firstVisible = session.isBackgroundVisualVisible

            session.toggleBackgroundVisualVisibility(preferredScreen: nil)
            let secondVisible = session.isBackgroundVisualVisible

            return (firstVisible, secondVisible)
        }

        XCTAssertFalse(result.firstVisible)
        XCTAssertTrue(result.secondVisible)
    }

    func testToggleBackgroundVisualWithNoSelectionNoop() async {
        let result = await MainActor.run { () -> Bool in
            let session = PresentationSession()
            session.isPresenting = true
            session.isBackgroundVisualVisible = true

            session.toggleBackgroundVisualVisibility(preferredScreen: nil)

            return session.isBackgroundVisualVisible
        }

        XCTAssertTrue(result)
    }
}
