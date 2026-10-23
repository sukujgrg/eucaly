import XCTest
import AVFoundation
@testable import eucaly

@MainActor
final class MediaFileRemovalSafetyTests: XCTestCase {
    func testRejectedProgramAcquisitionKeepsTheAcceptedPlayerAndControls() throws {
        let runtime = OutputMediaRuntime()
        defer { runtime.stop() }
        let outputs = coordinator()
        defer { outputs.stopAllOutputs() }
        let session = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        session.videoPaused = true
        let accepted = file("accepted.mov"), reserved = file("reserved.mov")
        runtime.updateProgram(slide: video(accepted), session: session, running: true, visible: false)
        let player = try XCTUnwrap(runtime.program)
        session.videoFill = true
        session.videoMuted = true
        runtime.updateProgram(slide: video(reserved), session: session, running: true, visible: true,
                              canAcquireFile: { $0 != reserved })
        XCTAssertTrue(runtime.program === player)
        XCTAssertFalse(runtime.programFill)
        XCTAssertEqual(runtime.programAudioGain.value, 1)
        XCTAssertTrue(runtime.retainsFile { $0 == accepted })
        XCTAssertFalse(runtime.retainsFile { $0 == reserved })
        runtime.updateProgram(slide: nil, session: session, running: false, visible: false,
                              canAcquireFile: { _ in false })
        XCTAssertNil(runtime.program, "Admission never prevents ordinary resource release")
        XCTAssertTrue(runtime.referencedFileURLs.isEmpty)
    }

    func testFailedOrCancelledRemovalRetriesOnlyItsDeferredBackgroundOnce() async throws {
        try await checkDeferredBackground(removed: false)
    }

    func testSuccessfulRemovalNeverFollowsItsDeferredBookmarkIntoTrash() async throws {
        try await checkDeferredBackground(removed: true)
    }

    func testSuccessfulUnrelatedRemovalRetriesAnUnknownDeferredBackgroundOnce() async throws {
        try await checkDeferredBackground(removed: true, resolvesRemovedSource: false)
    }

    private func checkDeferredBackground(removed: Bool, resolvesRemovedSource: Bool = true) async throws {
        let shouldRetry = !removed || !resolvesRemovedSource
        let goodRequest = expectation(description: "Existing background requested")
        let targetRequest = expectation(description: "Pending background requested")
        let retryRequest = shouldRetry ? expectation(description: "Deferred background retried") : nil
        let resolver = FileRemovalResolutionGate { bookmark, count in
            if bookmark == "good" { goodRequest.fulfill() }
            if bookmark == "target", count == 1 { targetRequest.fulfill() }
            if bookmark == "target", count == 2 { retryRequest?.fulfill() }
        }
        let runtime = OutputMediaRuntime(bookmarkResolver: { await resolver.resolve($0) })
        defer { runtime.stop() }
        let outputs = coordinator()
        defer { outputs.stopAllOutputs() }
        var good = OutputProfile.builtIns[0], target = OutputProfile.builtIns[1]
        good.background.bookmark = "good"; target.background.bookmark = "target"
        let goodURL = file("good.mov"), targetURL = file("target.mov")
        let resolvedURL = resolvesRemovedSource ? targetURL : file("unrelated.mov")
        let goodReady = expectation(description: "Existing background resolved")
        runtime.syncBackgrounds(profiles: [good], visible: true, media: false, changed: { goodReady.fulfill() })
        await fulfillment(of: [goodRequest], timeout: 2)
        await resolver.finish("good", url: goodURL)
        await fulfillment(of: [goodReady], timeout: 2)
        runtime.syncBackgrounds(profiles: [good], visible: true, media: false, changed: {})
        let goodPlayer = try XCTUnwrap(runtime.backgroundPlayer(for: good))
        let reservation = try reserve(targetURL, outputs: outputs, requester: OutputWorkspaceRecord.primaryID)
        let denied = expectation(description: "Reserved resolution rejected")
        runtime.syncBackgrounds(profiles: [good, target], visible: true, media: false,
                               canAcquireFile: { outputs.fileAdmissionProblem(for: $0) == nil },
                               makeFileAcquisitionGuard: { outputs.makeFileAcquisitionGuard() },
                               changed: { denied.fulfill() })
        await fulfillment(of: [targetRequest], timeout: 2)
        await resolver.finish("target", url: resolvedURL)
        await fulfillment(of: [denied], timeout: 2)
        XCTAssertNil(runtime.backgroundURL(for: target))
        XCTAssertNil(runtime.backgroundPlayer(for: target))
        XCTAssertFalse(runtime.retainsFile { $0 == resolvedURL }, "Deferred intent acquires no resource")
        XCTAssertTrue(runtime.backgroundPlayer(for: good) === goodPlayer)
        XCTAssertEqual(runtime.backgroundResourceCount, 1)
        for _ in 0..<3 {
            runtime.syncBackgrounds(profiles: [good, target], visible: true, media: false,
                                   canAcquireFile: { outputs.fileAdmissionProblem(for: $0) == nil },
                                   makeFileAcquisitionGuard: { outputs.makeFileAcquisitionGuard() }, changed: {})
        }
        XCTAssertFalse(runtime.finishFileRemoval(reservationID: UUID(), matching: { _ in true }, removed: false),
                       "An unrelated completion cannot free this reservation's deferred work")
        let requestsWhileBlocked = await resolver.requestCount("target")
        XCTAssertEqual(requestsWhileBlocked, 1, "Refresh must not busy-retry a reserved bookmark")

        XCTAssertTrue(outputs.finishFileRemoval(reservation, removed: removed))
        XCTAssertEqual(runtime.finishFileRemoval(reservationID: reservation.id,
                                                matching: { $0 == targetURL }, removed: removed), shouldRetry)
        let retryReady = shouldRetry ? expectation(description: "Deferred background accepted after completion") : nil
        runtime.syncBackgrounds(profiles: [good, target], visible: true, media: false,
                               canAcquireFile: { outputs.fileAdmissionProblem(for: $0) == nil },
                               makeFileAcquisitionGuard: { outputs.makeFileAcquisitionGuard() },
                               changed: { retryReady?.fulfill() })
        if shouldRetry {
            await fulfillment(of: [try XCTUnwrap(retryRequest)], timeout: 2)
            await resolver.finish("target", url: resolvedURL)
            await fulfillment(of: [try XCTUnwrap(retryReady)], timeout: 2)
            runtime.syncBackgrounds(profiles: [good, target], visible: true, media: false, changed: {})
            XCTAssertEqual(runtime.backgroundURL(for: target), resolvedURL)
            XCTAssertNotNil(runtime.backgroundPlayer(for: target))
            XCTAssertTrue(runtime.retainsFile { $0 == resolvedURL })
        } else {
            XCTAssertNil(runtime.backgroundURL(for: target))
            XCTAssertNil(runtime.backgroundPlayer(for: target))
        }
        XCTAssertFalse(runtime.finishFileRemoval(reservationID: reservation.id, matching: { $0 == targetURL }, removed: false),
                       "A completed intent cannot be retried by a later unrelated completion")
        runtime.syncBackgrounds(profiles: [good, target], visible: true, media: false, changed: {})
        let finalRequests = await resolver.requestCount("target")
        XCTAssertEqual(finalRequests, shouldRetry ? 2 : 1)
        XCTAssertTrue(runtime.backgroundPlayer(for: good) === goodPlayer)
        let goodRequests = await resolver.requestCount("good")
        XCTAssertEqual(goodRequests, 1)
    }

    func testLateOriginalBackgroundResolutionCannotReopenSuccessfullyRemovedSource() async throws {
        try await checkLateBackgroundResolution(.original)
    }

    func testLateTrashBackgroundResolutionCannotReopenSuccessfullyRemovedSource() async throws {
        try await checkLateBackgroundResolution(.trash)
    }

    func testLateUnrelatedBackgroundResolutionSurvivesSuccessfulRemoval() async throws {
        try await checkLateBackgroundResolution(.unrelated)
    }

    private enum LateResolution { case original, trash, unrelated }

    private func checkLateBackgroundResolution(_ resolution: LateResolution) async throws {
        let goodRequested = expectation(description: "Existing background requested")
        let pendingRequested = expectation(description: "Opaque bookmark requested before removal")
        let resolver = FileRemovalResolutionGate { bookmark, _ in
            if bookmark == "good" { goodRequested.fulfill() }
            if bookmark == "pending" { pendingRequested.fulfill() }
        }
        let runtime = OutputMediaRuntime(bookmarkResolver: { await resolver.resolve($0) })
        defer { runtime.stop() }
        let outputs = coordinator()
        defer { outputs.stopAllOutputs() }
        var good = OutputProfile.builtIns[0], pending = OutputProfile.builtIns[1]
        good.background.bookmark = "good"; pending.background.bookmark = "pending"
        let goodURL = file("good.mov"), originalURL = file("removed.mov"), trashURL = file("Trash/removed.mov")
        let resolvedURL: URL
        switch resolution {
        case .original: resolvedURL = originalURL
        case .trash: resolvedURL = trashURL
        case .unrelated: resolvedURL = file("unrelated.mov")
        }
        let goodReady = expectation(description: "Existing background accepted")
        runtime.syncBackgrounds(profiles: [good], visible: true, media: false, changed: { goodReady.fulfill() })
        await fulfillment(of: [goodRequested], timeout: 2)
        await resolver.finish("good", url: goodURL)
        await fulfillment(of: [goodReady], timeout: 2)
        runtime.syncBackgrounds(profiles: [good], visible: true, media: false, changed: {})
        let goodPlayer = try XCTUnwrap(runtime.backgroundPlayer(for: good))
        let lateResult = expectation(description: "Late bookmark resolution processed")
        runtime.syncBackgrounds(profiles: [good, pending], visible: true, media: false,
                               canAcquireFile: { outputs.fileAdmissionProblem(for: $0) == nil },
                               makeFileAcquisitionGuard: { outputs.makeFileAcquisitionGuard() },
                               changed: { lateResult.fulfill() })
        await fulfillment(of: [pendingRequested], timeout: 2)
        let reservation = try reserve(originalURL, outputs: outputs, requester: OutputWorkspaceRecord.primaryID)
        XCTAssertTrue(outputs.finishFileRemoval(reservation, removed: true, resultingURL: trashURL))
        XCTAssertFalse(runtime.finishFileRemoval(reservationID: reservation.id,
                                                matching: { $0 == originalURL || $0 == trashURL }, removed: true),
                       "The resolver is still suspended, so only its request-lifetime ticket can fence it")

        await resolver.finish("pending", url: resolvedURL)
        await fulfillment(of: [lateResult], timeout: 2)
        for _ in 0..<3 {
            runtime.syncBackgrounds(profiles: [good, pending], visible: true, media: false,
                                   canAcquireFile: { outputs.fileAdmissionProblem(for: $0) == nil },
                                   makeFileAcquisitionGuard: { outputs.makeFileAcquisitionGuard() }, changed: {})
        }
        if case .unrelated = resolution {
            XCTAssertEqual(runtime.backgroundURL(for: pending), resolvedURL)
            XCTAssertNotNil(runtime.backgroundPlayer(for: pending))
            XCTAssertEqual(runtime.backgroundResourceCount, 2)
        } else {
            XCTAssertNil(runtime.backgroundURL(for: pending))
            XCTAssertNil(runtime.backgroundPlayer(for: pending))
            XCTAssertFalse(runtime.retainsFile { $0 == originalURL || $0 == trashURL })
            XCTAssertEqual(runtime.backgroundResourceCount, 1)
        }
        XCTAssertTrue(runtime.backgroundPlayer(for: good) === goodPlayer)
        let requests = await resolver.requestCount("pending")
        XCTAssertEqual(requests, 1, "Success never follows a removed bookmark through repeated refreshes")
    }

    func testStopReleasesTheAcquisitionTicketBeforeANoncooperativeResolverReturns() async {
        let requested = expectation(description: "Noncooperative bookmark resolver suspended")
        let resolver = FileRemovalResolutionGate { _, _ in requested.fulfill() }
        let runtime = OutputMediaRuntime(bookmarkResolver: { await resolver.resolve($0) })
        defer { runtime.stop() }
        var profile = OutputProfile.builtIns[0]
        profile.background.bookmark = "pending"
        weak var pendingTicket: FileAcquisitionLifetimeProbe?
        runtime.syncBackgrounds(profiles: [profile], visible: true, media: false,
                               makeFileAcquisitionGuard: {
                                   let ticket = FileAcquisitionLifetimeProbe()
                                   pendingTicket = ticket
                                   return { [ticket] _ in ticket.admission }
                               }, changed: { XCTFail("A cancelled background request must not publish its result") })
        await fulfillment(of: [requested], timeout: 2)
        XCTAssertNotNil(pendingTicket)
        runtime.stop()
        XCTAssertNil(pendingTicket, "Stop releases completed-removal matchers without waiting on filesystem resolution")
        await resolver.finish("pending", url: file("late.mov"))
        XCTAssertTrue(runtime.referencedFileURLs.isEmpty)
        XCTAssertEqual(runtime.backgroundResourceCount, 0)
    }

    func testResolvedImageBackgroundIsRetainedEvenWithoutAPlayer() async throws {
        let requested = expectation(description: "Image requested")
        let resolved = expectation(description: "Image resolved")
        let resolver = FileRemovalResolutionGate { _, _ in requested.fulfill() }
        let runtime = OutputMediaRuntime(bookmarkResolver: { await resolver.resolve($0) })
        defer { runtime.stop() }
        var profile = OutputProfile.builtIns[0]
        profile.background.bookmark = "image"
        let url = file("still.png")
        runtime.syncBackgrounds(profiles: [profile], visible: false, media: false, changed: { resolved.fulfill() })
        await fulfillment(of: [requested], timeout: 2)
        await resolver.finish("image", url: url)
        await fulfillment(of: [resolved], timeout: 2)
        XCTAssertEqual(runtime.backgroundURL(for: profile), url)
        XCTAssertNil(runtime.backgroundPlayer(for: profile))
        XCTAssertTrue(runtime.retainsFile { $0 == url })
        runtime.syncBackgrounds(profiles: [], visible: false, media: false, changed: {})
        XCTAssertFalse(runtime.retainsFile { $0 == url })
    }

    func testReservedCurrentSourcesPreserveDocumentRevisionSelectionAndAllMediaKinds() throws {
        let outputs = coordinator()
        defer { outputs.stopAllOutputs() }
        let session = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        let accepted = file("accepted.txt"), target = file("reserved.pdf")
        let old = LyricsParser.parseDocument("Verse 1\nAccepted words").slides
        XCTAssertTrue(session.setSlides(old, lyricsSourceURL: accepted))
        let revision = session.documentRevision, selected = session.currentSlideID
        let reservation = try reserve(target, outputs: outputs, requester: session.outputSourceID)
        defer { outputs.finishFileRemoval(reservation, removed: false) }
        let replacements = [
            Slide(index: 0, lines: [], label: "Image", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: target),
            Slide(index: 0, lines: [], label: "Video", videoURL: target, pdfURL: nil, pdfPageIndex: nil, imageURL: nil),
            Slide(index: 0, lines: [], label: "PDF", videoURL: nil, pdfURL: target, pdfPageIndex: 0, imageURL: nil)
        ]
        for replacement in replacements {
            XCTAssertFalse(session.setSlides([replacement]))
            XCTAssertEqual(session.slides.map(\.id), old.map(\.id))
            XCTAssertEqual(session.currentLyricsSourceURL, accepted)
            XCTAssertEqual(session.currentSlideID, selected)
            XCTAssertEqual(session.documentRevision, revision)
        }
        XCTAssertFalse(session.setSlides(old, lyricsSourceURL: target))
        XCTAssertFalse(session.setPDFSlideSource(.init(url: target, pageCount: 500)))
        XCTAssertNil(session.pdfSlideSource)
        XCTAssertEqual(session.documentRevision, revision)
        XCTAssertFalse(session.referencedFileURLs.contains(target))
        XCTAssertTrue(session.referencedFileURLs.contains(accepted))
    }

    func testRejectedBackgroundSelectionsKeepResourcesAndAnotherWorkspacesMusicOwner() throws {
        let outputs = coordinator()
        defer { outputs.stopAllOutputs() }
        let session = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
        let ownerID = try XCTUnwrap(outputs.profiles.addWorkspace(name: "Music"))
        let owner = outputs.session(workspace: ownerID)
        defer { session.clearBackgroundAudio(); owner.clearBackgroundAudio() }
        let visual = file("visual.png"), audio = file("selected.caf"), playing = file("playing.caf"), target = file("reserved.caf")
        XCTAssertTrue(session.setBackgroundVisual(visual))
        XCTAssertTrue(session.setBackgroundAudio(url: audio, autoplay: false))
        XCTAssertTrue(owner.setBackgroundAudio(url: playing, autoplay: true))
        let selectedPlayer = session.programBackgroundAudioPlayer, playingPlayer = owner.programBackgroundAudioPlayer
        let reservation = try reserve(target, outputs: outputs, requester: session.outputSourceID)
        defer { outputs.finishFileRemoval(reservation, removed: false) }
        XCTAssertFalse(session.setBackgroundVisual(target))
        XCTAssertFalse(session.setBackgroundAudio(url: target, autoplay: true))
        XCTAssertEqual(session.backgroundVisualURL, visual)
        XCTAssertEqual(session.backgroundAudioURL, audio)
        XCTAssertTrue(session.programBackgroundAudioPlayer === selectedPlayer)
        XCTAssertTrue(owner.programBackgroundAudioPlayer === playingPlayer)
        XCTAssertTrue(outputs.audioSession === owner)
        XCTAssertEqual(owner.backgroundAudioPlaybackState, .playing)
        XCTAssertEqual(session.backgroundAudioPlaybackState, .stopped)
        XCTAssertTrue(session.referencedFileURLs.contains(audio))
        XCTAssertFalse(session.referencedFileURLs.contains(target))
        XCTAssertTrue(session.setBackgroundVisual(nil), "Clear remains available during removal")
        XCTAssertTrue(session.setBackgroundAudio(url: nil, autoplay: false))
    }

    private func coordinator() -> OutputCoordinator {
        OutputCoordinator(profiles: OutputProfileStore(), displays: ProjectionDisplayManager(displays: { [] }),
                          retainsPreparedSessions: true, ndi: RecordingNDIOutput(), driverFactory: { FakeOutputDriver() })
    }
    private func reserve(_ url: URL, outputs: OutputCoordinator, requester: UUID) throws -> OutputCoordinator.FileRemovalReservation {
        if case .admitted(let reservation) = outputs.beginFileRemoval(at: url, requesterWorkspaceID: requester, matchingFile: { $0 == url }) {
            return reservation
        }
        throw XCTUnwrapError.unexpectedReservation
    }
    private enum XCTUnwrapError: Error { case unexpectedReservation }
    private func file(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-media-removal-\(UUID())").appendingPathComponent(name)
    }
    private func video(_ url: URL) -> Slide {
        .init(index: 0, lines: [], label: "Video", videoURL: url, pdfURL: nil, pdfPageIndex: nil, imageURL: nil)
    }
}

@MainActor
private final class FileAcquisitionLifetimeProbe {
    var admission: OutputCoordinator.FileAcquisitionAdmission { .allowed }
}

private actor FileRemovalResolutionGate {
    private let requested: @Sendable (String, Int) -> Void
    private var waiting: [String: CheckedContinuation<URL?, Never>] = [:]
    private var counts: [String: Int] = [:]
    init(requested: @escaping @Sendable (String, Int) -> Void) { self.requested = requested }
    func resolve(_ bookmark: String) async -> URL? {
        await withCheckedContinuation { continuation in
            waiting[bookmark] = continuation
            counts[bookmark, default: 0] += 1
            requested(bookmark, counts[bookmark]!)
        }
    }
    func finish(_ bookmark: String, url: URL?) {
        waiting.removeValue(forKey: bookmark)?.resume(returning: url)
    }
    func requestCount(_ bookmark: String) -> Int { counts[bookmark] ?? 0 }
}
