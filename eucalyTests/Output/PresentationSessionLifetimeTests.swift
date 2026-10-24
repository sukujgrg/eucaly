import AVFoundation
import XCTest
@testable import eucaly

@MainActor
final class PresentationSessionLifetimeTests: XCTestCase {
    func testQueuedPassivePublicationDoesNotUseARetiredInjectedCoordinator() async {
        let displays = ProjectionDisplayManager(displays: { [] })
        let profiles = OutputProfileStore()
        var outputs: OutputCoordinator? = OutputCoordinator(profiles: profiles, displays: displays,
            retainsPreparedSessions: true, keyWindow: { nil })
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        let slides = makeSlides()
        session.setSlides(slides)
        outputs?.stopAllOutputs()
        let savedDocument = profiles.document
        weak var retiredCoordinator = outputs

        // Native controls can retain their session after the app-owned runtime
        // retires. Keep that session alive while its passive publication waits.
        outputs = nil
        XCTAssertNil(retiredCoordinator, "Pending publication must not prolong its owner's lifetime.")
        await drainMainQueue()

        XCTAssertEqual(session.currentSlideID, slides[0].id)
        XCTAssertEqual(session.slides.map(\.id), slides.map(\.id))
        XCTAssertFalse(session.isPresenting)
        XCTAssertEqual(profiles.document, savedDocument)
    }

    func testQueuedNavigationDoesNotChangeCurrentAfterItsCoordinatorRetires() async {
        let displays = ProjectionDisplayManager(displays: { [] })
        let profiles = OutputProfileStore()
        var outputs: OutputCoordinator? = OutputCoordinator(profiles: profiles, displays: displays,
            retainsPreparedSessions: true, keyWindow: { nil })
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        let slides = makeSlides()
        session.setSlides(slides)
        XCTAssertGreaterThan(session.slideCount, 1)
        session.applyOutputState(running: true, visible: true)
        await drainMainQueue()

        session.moveSelection(1)
        session.moveSelection(direction: .nextItem)
        weak var retiredCoordinator = outputs
        outputs = nil
        XCTAssertNil(retiredCoordinator, "Queued input must not retain a retired output owner.")
        await drainMainQueue()

        XCTAssertEqual(session.currentSlideID, slides[0].id, "Input queued by a retired runtime cannot change retained Current.")
        XCTAssertEqual(session.slides.map(\.id), slides.map(\.id))
    }

    func testQueuedAudioEndDoesNotRestartMusicAfterItsCoordinatorRetires() async throws {
        let url = try makeAudioFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let displays = ProjectionDisplayManager(displays: { [] })
        let profiles = OutputProfileStore()
        var outputs: OutputCoordinator? = OutputCoordinator(profiles: profiles, displays: displays,
            retainsPreparedSessions: true, keyWindow: { nil })
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setBackgroundAudio(url: url, autoplay: false)
        outputs?.claimBackgroundAudio(session)
        let player = try XCTUnwrap(session.programBackgroundAudioPlayer)
        let item = try XCTUnwrap(player.currentItem)
        await drainMainQueue()
        XCTAssertEqual(session.backgroundAudioPlaybackState, .stopped)

        // NotificationCenter calls the main-queue observer synchronously here;
        // its actor task cannot run until this turn releases the actual owner.
        NotificationCenter.default.post(name: .AVPlayerItemDidPlayToEndTime, object: item)
        weak var retiredCoordinator = outputs
        outputs = nil
        XCTAssertNil(retiredCoordinator, "An admitted audio callback must not retain its owner through retirement.")
        await drainMainQueue()

        XCTAssertEqual(session.backgroundAudioPlaybackState, .stopped)
        XCTAssertEqual(player.rate, 0)
        XCTAssertTrue(session.programBackgroundAudioPlayer === player)
        XCTAssertEqual(session.backgroundAudioURL, url)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeSlides() -> [Slide] {
        LyricsParser.parseDocument("One\n\nTwo\n\nThree", fileName: "Lifetime.txt").slides
    }

    private func makeAudioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("session-lifetime-\(UUID()).caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let samples = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48))
        samples.frameLength = samples.frameCapacity
        for channel in 0..<2 {
            samples.floatChannelData?[channel].update(repeating: 0, count: Int(samples.frameLength))
        }
        try AVAudioFile(forWriting: url, settings: format.settings).write(from: samples)
        return url
    }
}
