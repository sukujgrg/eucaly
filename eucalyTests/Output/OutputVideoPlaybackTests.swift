import AppKit
import AVFoundation
import XCTest
@testable import eucaly

@MainActor
final class OutputVideoPlaybackTests: XCTestCase {
    func testRealEOFFeedbackReplaySeekAndHidePreserveIndependentWorkspace() async throws {
        let url = try await NetworkRegressionTests.makePortraitVideoFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try Fixture(); defer { f.outputs.stopAllOutputs() }
        f.load(url, into: f.a); f.load(url, into: f.b)
        let first = try XCTUnwrap(f.outputs.preparedMedia(workspace: f.a.outputSourceID)?.program)
        let second = try XCTUnwrap(f.outputs.preparedMedia(workspace: f.b.outputSourceID)?.program)
        XCTAssertFalse(first === second)
        XCTAssertEqual(f.a.playbackProgress.videoPlaybackState, .waiting)
        try await until("both paused programs prepared") {
            f.a.playbackProgress.videoPlaybackState == .paused && f.b.playbackProgress.videoPlaybackState == .paused
                && f.a.videoDuration > 2 && f.b.videoDuration > 2
        }
        f.b.seekVideo(to: 1)
        f.a.seekVideo(to: f.a.videoDuration - 0.15)
        try await until("positioned before EOF") {
            abs(second.currentTime().seconds - 1) < 0.05 && first.currentTime().seconds > 2.7
        }
        f.a.videoPaused = false
        try await until("real non-looping EOF") { f.a.playbackProgress.videoPlaybackState == .ended }
        XCTAssertFalse(f.a.videoPaused, "EOF must not rewrite operator playback intent.")
        XCTAssertEqual(f.a.videoPlaybackActionTitle, "Replay")
        XCTAssertEqual(first.rate, 0)
        XCTAssertEqual(f.b.playbackProgress.videoPlaybackState, .paused)
        XCTAssertEqual(second.currentTime().seconds, 1, accuracy: 0.05)
        f.outputs.refreshMedia()
        XCTAssertEqual(f.a.playbackProgress.videoPlaybackState, .ended, "An appearance/status refresh cannot replay EOF.")

        f.a.toggleVideoPlayback()
        try await until("replay starts from the beginning") {
            f.a.playbackProgress.videoPlaybackState == .playing && first.currentTime().seconds < 0.5
        }
        XCTAssertTrue(f.outputs.preparedMedia(workspace: f.a.outputSourceID)?.program === first)
        f.a.videoPaused = true
        try await until("operator pause") { f.a.playbackProgress.videoPlaybackState == .paused }
        XCTAssertEqual(f.a.videoPlaybackActionTitle, "Play")
        f.a.seekVideo(to: f.a.videoDuration - 0.15)
        try await until("paused seek before the next end") { first.currentTime().seconds > 2.7 }
        f.a.videoPaused = false
        try await until("second EOF") { f.a.playbackProgress.videoPlaybackState == .ended }
        f.a.seekVideo(to: 0.5)
        try await until("seek from EOF resumes the requested playback") {
            f.a.playbackProgress.videoPlaybackState == .playing && first.currentTime().seconds < 1
        }
        f.a.hideSlides()
        try await until("hidden slides pause the runtime") { f.a.playbackProgress.videoPlaybackState == .paused }
        XCTAssertFalse(f.a.videoPaused)
        f.a.showSlides()
        try await until("Show resumes playback") { f.a.playbackProgress.videoPlaybackState == .playing }
        XCTAssertEqual(f.b.playbackProgress.videoPlaybackState, .paused)
        XCTAssertEqual(second.currentTime().seconds, 1, accuracy: 0.05)
    }

    func testLoopRewindsSharedPlayerAndRetiredNotificationsCannotChangeNewProgram() async throws {
        let url = try await NetworkRegressionTests.makePortraitVideoFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try Fixture(); defer { f.outputs.stopAllOutputs() }
        f.load(url, into: f.a)
        let runtime = try XCTUnwrap(f.outputs.preparedMedia(workspace: f.a.outputSourceID))
        let player = try XCTUnwrap(runtime.program), oldItem = try XCTUnwrap(player.currentItem)
        try await until("loop fixture ready") { f.a.playbackProgress.videoPlaybackState == .paused && f.a.videoDuration > 2 }
        f.a.videoLoop = true
        f.a.seekVideo(to: f.a.videoDuration - 0.15)
        try await until("loop fixture positioned") { player.currentTime().seconds > 2.7 }
        let ends = EndCount()
        let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: oldItem, queue: .main) { _ in ends.record() }
        defer { NotificationCenter.default.removeObserver(observer) }
        f.a.videoPaused = false
        try await until("loop returns to beginning") {
            ends.count > 0 && f.a.playbackProgress.videoPlaybackState == .playing && player.currentTime().seconds < 0.5
        }
        XCTAssertTrue(runtime.program === player)
        XCTAssertFalse(f.a.videoPaused)

        // A pending seek and native callbacks from the retired item cannot
        // resume output or overwrite the replacement's stopped state.
        f.a.seekVideo(to: 1)
        f.a.setSlides(LyricsParser.parseDocument("Verse\nReplacement lyrics").slides)
        f.a.requestCurrentProjection()
        XCTAssertNil(runtime.program)
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: oldItem)
        NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(f.a.playbackProgress.videoPlaybackState, .stopped)
        XCTAssertNil(runtime.program)
        XCTAssertEqual(f.outputs.snapshot(for: f.aRow).current.components.first?.text, "Replacement lyrics")
    }

    func testFailedRuntimeReportsFailureAndExplicitReloadCanRecoverTheSameURL() async throws {
        let source = try await NetworkRegressionTests.makePortraitVideoFixture()
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-missing-video-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: source); try? FileManager.default.removeItem(at: missing) }
        let f = try Fixture(); defer { f.outputs.stopAllOutputs() }
        f.load(missing, into: f.a)
        try await until("missing item reports its failure") { f.a.playbackProgress.videoPlaybackState.failure != nil }
        let failed = try XCTUnwrap(f.outputs.preparedMedia(workspace: f.a.outputSourceID)?.program)
        XCTAssertEqual(f.a.playbackProgress.videoPlaybackState.title, "Playback failed")
        f.outputs.refreshMedia()
        XCTAssertNotNil(f.a.playbackProgress.videoPlaybackState.failure)
        try FileManager.default.copyItem(at: source, to: missing)
        f.load(missing, into: f.a)
        try await until("an explicit replacement recovers the failed load") {
            f.a.playbackProgress.videoPlaybackState == .paused && f.a.videoDuration > 2
        }
        XCTAssertFalse(f.outputs.preparedMedia(workspace: f.a.outputSourceID)?.program === failed)
        f.outputs.stopAllOutputs()
        XCTAssertEqual(f.a.playbackProgress.videoPlaybackState, .stopped)
    }

    private func until(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { XCTFail("Timed out: \(description)"); throw NetworkHelperWire.Failure.unavailable }
    }

    @MainActor private struct Fixture {
        let outputs: OutputCoordinator
        let a: PresentationSession
        let b: PresentationSession
        let aRow: UUID
        init() throws {
            let one = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "One", frame: .init(x: 0, y: 0, width: 640, height: 360))
            let two = ProjectionMonitor(id: 2, identity: UUID().uuidString, name: "Two", frame: .init(x: 640, y: 0, width: 640, height: 360))
            let store = OutputProfileStore(monitor: one.target)
            let other = try XCTUnwrap(store.addWorkspace(name: "Other"))
            aRow = try XCTUnwrap(store.document.destinations.first?.id)
            store.edit { $0.destinations.append(.init(name: "Other", profileID: OutputProfile.audienceID, monitor: two.target, workspaceID: other)) }
            outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [one, two] }),
                retainsPreparedSessions: true, network: RecordingNetworkOutput(), driverFactory: { FakeOutputDriver() })
            a = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
            b = outputs.session(workspace: other)
        }
        func load(_ url: URL, into session: PresentationSession) {
            session.videoPaused = true
            session.setSlides([.init(index: 0, lines: [], label: "Video fixture", videoURL: url,
                pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
            session.showSlides()
        }
    }

    nonisolated private final class EndCount: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func record() { lock.withLock { value += 1 } }
    }
}
