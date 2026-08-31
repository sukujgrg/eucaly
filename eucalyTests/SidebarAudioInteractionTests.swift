import XCTest
@testable import eucaly

final class SidebarAudioInteractionTests: XCTestCase {
    private let firstURL = URL(fileURLWithPath: "/library/first.mp3")
    private let secondURL = URL(fileURLWithPath: "/library/second.mp3")

    func testDefaultActionLoadsAndPlaysDifferentTrack() {
        XCTAssertEqual(
            AudioSidebarInteraction.defaultAction(
                targetURL: secondURL,
                activeURL: firstURL,
                isPlaying: true
            ),
            .selectAndPlay(secondURL)
        )
    }

    func testDefaultActionStartsPausedTrackWithoutPausingPlayingTrack() {
        XCTAssertEqual(
            AudioSidebarInteraction.defaultAction(
                targetURL: firstURL,
                activeURL: firstURL,
                isPlaying: false
            ),
            .togglePlayback
        )
        XCTAssertEqual(
            AudioSidebarInteraction.defaultAction(
                targetURL: firstURL,
                activeURL: firstURL,
                isPlaying: true
            ),
            .none
        )
    }

    func testSpaceTogglesActiveTrack() {
        XCTAssertEqual(
            AudioSidebarInteraction.toggleAction(
                targetURL: firstURL,
                activeURL: firstURL
            ),
            .togglePlayback
        )
    }

    func testSpaceLoadsAndPlaysDifferentTrack() {
        XCTAssertEqual(
            AudioSidebarInteraction.toggleAction(
                targetURL: secondURL,
                activeURL: firstURL
            ),
            .selectAndPlay(secondURL)
        )
    }
}
