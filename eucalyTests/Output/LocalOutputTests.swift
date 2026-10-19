import XCTest
import AppKit
@testable import eucaly

@MainActor
final class LocalOutputTests: XCTestCase {
    func testAnotherWorkspaceCannotPublishUntilAnOutputIsExplicitlyMoved() async throws {
        let output = LocalOutputHarness(); defer { output.stop() }
        output.load("Verse\nLive lyrics"); output.session.showSlides()
        let other = PresentationSession(projectionDisplays: output.outputs.displays, outputCoordinator: output.outputs)
        other.setSlides(LyricsParser.parseDocument("Verse\nPrepared workspace").slides)
        output.outputs.passiveLocal(other)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(output.outputs.text.components.first?.text, "Live lyrics")
        other.showSlides()
        XCTAssertTrue(output.session.isPresenting); XCTAssertFalse(other.isPresenting)
        XCTAssertTrue(output.outputs.moveOutput(output.nativeRow, to: other))
        output.outputs.focusWorkspace(other)
        XCTAssertEqual(output.outputs.text.components.first?.text, "Prepared workspace")
        XCTAssertEqual(output.outputs.ownership.source, other.outputSourceID)
        XCTAssertFalse(output.session.isPresenting); XCTAssertTrue(other.isPresenting)
    }

    func testDisablingLastDestinationsRetainsCurrentAndCancelsQueuedNavigation() async throws {
        let output = LocalOutputHarness(); defer { output.stop() }
        output.load("Verse\nFirst\n\nChorus\nSecond"); output.session.showSlides()
        let current = output.session.currentSlideID
        output.session.moveSelection(1)
        output.outputs.profiles.edit { document in for i in document.destinations.indices { document.destinations[i].enabled = false } }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(output.outputs.snapshot.source, output.session.outputSourceID); XCTAssertNil(output.outputs.localSession)
        XCTAssertNil(output.outputs.ownership.source); XCTAssertFalse(output.outputs.snapshot.visible)
        XCTAssertFalse(output.outputs.isPresenting); XCTAssertFalse(output.session.isPresenting)
        XCTAssertEqual(output.session.currentSlideID, current)
        XCTAssertEqual(output.outputs.text.components.first?.text, "First")
    }

}
