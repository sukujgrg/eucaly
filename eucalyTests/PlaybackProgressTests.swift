import Combine
import XCTest
@testable import eucaly

@MainActor
final class PlaybackProgressTests: XCTestCase {
    func testPlaybackTicksPublishOnlyChangedPositionAndDuration() {
        let progress = PlaybackProgressStore()
        var changes = 0
        let observer = progress.objectWillChange.sink { changes += 1 }
        defer { observer.cancel() }
        progress.updateVideo(currentTime: 1, duration: 120)
        XCTAssertEqual(changes, 2)
        progress.updateVideo(currentTime: 1.25, duration: 120)
        XCTAssertEqual(changes, 3, "A playback tick should update its position without republishing duration")
        progress.updateVideo(currentTime: 1.25, duration: 120)
        XCTAssertEqual(changes, 3, "Paused/repeated samples should not invalidate the playback controls")
        progress.updateVideo(currentTime: 1.25, duration: 121)
        XCTAssertEqual(changes, 4)
        XCTAssertEqual(progress.videoCurrentTime, 1.25)
        XCTAssertEqual(progress.videoDuration, 121)
    }

    func testSeekResetAndInvalidTimingStillUpdatePlaybackControls() {
        let progress = PlaybackProgressStore()
        progress.updateVideo(currentTime: 25, duration: 120)
        progress.seekVideo(to: 5)
        XCTAssertEqual(progress.videoCurrentTime, 5)
        progress.updateVideo(currentTime: 5.25, duration: 120)
        XCTAssertEqual(progress.videoCurrentTime, 5.25)
        progress.updateVideo(currentTime: .nan, duration: .infinity)
        XCTAssertEqual(progress.videoCurrentTime, 0)
        XCTAssertEqual(progress.videoDuration, 0)
        progress.updateVideo(currentTime: 10, duration: 120)
        progress.resetVideo()
        XCTAssertEqual(progress.videoCurrentTime, 0)
        XCTAssertEqual(progress.videoDuration, 0)
    }
}
