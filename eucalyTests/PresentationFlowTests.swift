import XCTest
@testable import eucaly
import AppKit

final class PresentationFlowTests: XCTestCase {
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
