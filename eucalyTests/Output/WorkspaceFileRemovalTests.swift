import AppKit
import XCTest
@testable import eucaly

@MainActor
final class WorkspaceFileRemovalTests: XCTestCase {
    func testClosedWorkspaceCurrentProtectsLyricsEveryMediaURLAndVirtualPDF() throws {
        let f = Fixture(); defer { f.close() }
        let owner = try XCTUnwrap(f.store.addWorkspace(name: "Closed controls"))
        let unopened = try XCTUnwrap(f.store.addWorkspace(name: "Never opened"))
        let session = f.outputs.session(workspace: owner)
        let lyrics = f.url("song.txt")
        session.setSlides(LyricsParser.parseDocument("Verse\nRetained lyrics").slides, lyricsSourceURL: lyrics)
        XCTAssertTrue(f.outputs.fileRemovalProblem(matchingFile: f.matcher(lyrics))?.contains("Closed controls") == true)

        let video = f.url("movie.mp4"), image = f.url("picture.png"), pdf = f.url("document.pdf")
        try f.writePDF(to: pdf)
        session.setSlides([
            slide(video: video), slide(image: image), PDFSlideCatalog.slide(url: pdf, pageIndex: 0)
        ])
        for url in [video, image, pdf] {
            XCTAssertNotNil(f.outputs.fileRemovalProblem(matchingFile: f.matcher(url)), "Every Current slide counts, including unselected media")
            XCTAssertTrue(f.outputs.referencedFileURLs.contains(url.standardizedFileURL))
        }
        session.setPDFSlideSource(.init(url: pdf, pageCount: 1000))
        XCTAssertTrue(session.slides.isEmpty)
        XCTAssertNotNil(f.outputs.fileRemovalProblem(matchingFile: f.matcher(pdf)), "Virtual PDFs have no materialized slide array")
        XCTAssertTrue(f.outputs.referencedFileURLs.contains(pdf.standardizedFileURL))
        XCTAssertNil(f.outputs.preparedSession(workspace: unopened))
        XCTAssertTrue(f.windows.controllers.isEmpty)
        XCTAssertTrue(f.ndi.starts.isEmpty)
        XCTAssertFalse(f.outputs.isRunning)
    }

    func testRejectedCurrentAndHiddenOutputKeepAcceptedSourceProtected() throws {
        let f = Fixture(); defer { f.close() }
        var output = OutputDestinationConfiguration(name: "Online", profileID: OutputProfile.audienceID, monitor: nil)
        output.ndi = .init(sourceName: "Isolated file-removal test")
        f.store.edit { $0.destinations.append(output) }
        let image = f.url("accepted.png")
        f.session.setSlides([slide(image: image)])
        XCTAssertTrue(f.outputs.presentLocal(f.session))
        f.session.setSlides([slide(window: 42)])
        XCTAssertFalse(f.outputs.presentLocal(f.session), "Picked windows cannot replace accepted NDI-only content")
        f.outputs.hide(for: f.session)
        let snapshot = f.outputs.snapshot(for: output.id)
        let revision = f.outputs.revision

        XCTAssertNotNil(f.outputs.fileRemovalProblem(matchingFile: f.matcher(image)))
        XCTAssertTrue(f.outputs.referencedFileURLs.contains(image.standardizedFileURL))
        XCTAssertEqual(f.outputs.snapshot(for: output.id).localMedia?.id, snapshot.localMedia?.id)
        XCTAssertEqual(f.outputs.snapshot(for: output.id).revision, snapshot.revision)
        XCTAssertEqual(f.outputs.revision, revision, "A safety query must not issue an output command")
        XCTAssertTrue(f.outputs.isOpen(output.id))
    }

    func testSelectedBackgroundRemainsProtectedWithoutPlaybackOrControls() throws {
        let f = Fixture(); defer { f.close() }
        let owner = try XCTUnwrap(f.store.addWorkspace(name: "Background"))
        let session = f.outputs.session(workspace: owner)
        let background = f.url("background.png")
        session.setBackgroundVisual(background)
        XCTAssertNotNil(f.outputs.fileRemovalProblem(matchingFile: f.matcher(background)))
        XCTAssertTrue(f.outputs.referencedFileURLs.contains(background.standardizedFileURL))
        XCTAssertFalse(f.outputs.isPlaybackRunning(workspace: owner))
        session.setBackgroundVisual(nil)
        XCTAssertNil(f.outputs.fileRemovalProblem(matchingFile: f.matcher(background)))
    }

    func testPreviewRemovalDoesNotRepublishAnUnrelatedLiveProgram() throws {
        let f = Fixture(); defer { f.close() }
        var output = OutputDestinationConfiguration(name: "Online", profileID: OutputProfile.audienceID, monitor: nil)
        output.ndi = .init(sourceName: "Unchanged file-removal program")
        f.store.edit { $0.destinations.append(output) }
        f.session.setSlides(LyricsParser.parseDocument("Verse\nKeep presenting").slides)
        XCTAssertTrue(f.outputs.presentLocal(f.session))
        let target = f.url("preview-only.txt")
        let flow = f.outputs.program(f.session.outputSourceID).flow
        flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nRemove Preview").slides)
        flow.setPreviewSource(.file(target))
        let reservation = try reserve(f, at: target)
        let sent = f.ndi.snapshots.count, revision = f.outputs.revision
        let accepted = f.outputs.snapshot(for: output.id)

        XCTAssertTrue(f.outputs.finishFileRemoval(reservation, removed: true))
        XCTAssertTrue(flow.previewIsEmpty)
        XCTAssertEqual(f.ndi.snapshots.count, sent, "Removing a Preview source must not republish or refresh another program")
        XCTAssertEqual(f.outputs.revision, revision)
        XCTAssertEqual(f.outputs.snapshot(for: output.id).revision, accepted.revision)
        XCTAssertTrue(f.outputs.isOpen(output.id))
        XCTAssertEqual(f.session.currentSlideID, accepted.localMedia?.id)
    }

    func testPreviewRemovalCancelsOnlyMatchingSourceAndKeepsNewerPendingLoad() throws {
        let f = Fixture(); defer { f.close() }
        let flow = f.outputs.program(f.session.outputSourceID).flow
        let removed = f.url("removed.pdf"), next = f.url("next.txt")
        flow.setPreviewPDFSource(.init(url: removed, pageCount: 200))
        flow.setPreviewSource(.file(removed))
        let pending = flow.beginPreviewLoad(to: .file(next))
        let current = LyricsParser.parseDocument("Verse\nCurrent survives").slides
        f.session.setSlides(current)
        let currentRevision = f.session.documentRevision
        let reservation = try reserve(f, at: removed)

        XCTAssertFalse(flow.canLoadPreview)
        XCTAssertTrue(f.outputs.finishFileRemoval(reservation, removed: true))
        XCTAssertTrue(flow.previewIsEmpty)
        XCTAssertEqual(flow.pendingPreviewSource, .file(next))
        XCTAssertEqual(flow.previewLoadToken, pending)
        XCTAssertTrue(flow.completePreviewLoad(token: pending, source: .file(next)))
        XCTAssertEqual(f.session.currentSlideID, current.first?.id)
        XCTAssertEqual(f.session.documentRevision, currentRevision)
    }

    func testRemovingPendingSourcePreservesUnrelatedAcceptedPreviewAndRejectsLateCompletion() throws {
        let f = Fixture(); defer { f.close() }
        let flow = f.outputs.program(f.session.outputSourceID).flow
        let accepted = f.url("accepted.txt"), removed = f.url("pending.txt")
        let slides = LyricsParser.parseDocument("Verse\nKeep Preview").slides
        flow.setPreviewSlides(slides)
        flow.setPreviewSource(.file(accepted))
        let token = flow.beginPreviewLoad(to: .file(removed))
        XCTAssertTrue(f.outputs.referencedFileURLs.isSuperset(of: [accepted, removed]))
        let reservation = try reserve(f, at: removed)
        XCTAssertTrue(f.outputs.finishFileRemoval(reservation, removed: true))
        XCTAssertEqual(flow.previewSource, .file(accepted))
        XCTAssertEqual(flow.previewSelectionID, slides.first?.id)
        XCTAssertNil(flow.pendingPreviewSource)
        XCTAssertFalse(flow.completePreviewLoad(token: token, source: .file(removed)))
    }

    func testFailedRemovalKeepsPreviewAndStaleFinishCannotReleaseNewReservation() throws {
        let f = Fixture(); defer { f.close() }
        let flow = f.outputs.program(f.session.outputSourceID).flow
        let target = f.url("song.txt")
        let slides = LyricsParser.parseDocument("Verse\nKeep on failure").slides
        flow.setPreviewSlides(slides); flow.setPreviewSource(.file(target))
        let first = try reserve(f, at: target)
        XCTAssertNotNil(f.outputs.fileAdmissionProblem(for: target))
        XCTAssertTrue(f.outputs.finishFileRemoval(first, removed: false))
        XCTAssertEqual(flow.previewSource, .file(target))
        XCTAssertEqual(flow.previewSelectionID, slides.first?.id)
        let second = try reserve(f, at: target)
        XCTAssertFalse(f.outputs.finishFileRemoval(first, removed: true))
        XCTAssertNotNil(f.outputs.fileAdmissionProblem(for: target))
        XCTAssertEqual(flow.previewSelectionID, slides.first?.id)
        XCTAssertTrue(f.outputs.finishFileRemoval(second, removed: false))
        XCTAssertNil(f.outputs.fileAdmissionProblem(for: target))
    }

    func testFlowRefusesReservedSourceWithoutReplacingCurrentOrPreview() throws {
        let f = Fixture(); defer { f.close() }
        let flow = f.outputs.program(f.session.outputSourceID).flow
        let target = f.url("reserved.pdf")
        let old = LyricsParser.parseDocument("Verse\nKeep Current").slides
        f.session.setSlides(old)
        flow.setPreviewPDFSource(.init(url: target, pageCount: 200))
        flow.setPreviewSource(.file(target))
        let reservation = try reserve(f, at: target)
        let revision = f.session.documentRevision
        XCTAssertFalse(flow.setCurrentPDFSource(.init(url: target, pageCount: 200), in: f.session))
        XCTAssertFalse(flow.setCurrentSlides([slide(image: target)], in: f.session))
        XCTAssertEqual(f.session.currentSlideID, old.first?.id)
        XCTAssertEqual(f.session.documentRevision, revision)
        XCTAssertEqual(flow.previewSource, .file(target))
        XCTAssertEqual(flow.previewSlideCount, 200)
        XCTAssertTrue(f.outputs.finishFileRemoval(reservation, removed: false))
    }

    func testReservationSurvivesRequesterWorkspaceDeletionUntilExactCompletion() throws {
        let f = Fixture(); defer { f.close() }
        let remaining = try XCTUnwrap(f.store.addWorkspace(name: "Remaining"))
        let target = f.url("removing.txt")
        let reservation = try reserve(f, at: target)
        XCTAssertTrue(f.outputs.deleteWorkspace(f.session.outputSourceID))
        XCTAssertNotNil(f.outputs.fileAdmissionProblem(for: target))
        let otherSession = f.outputs.session(workspace: remaining)
        XCTAssertFalse(otherSession.setSlides(LyricsParser.parseDocument("Verse\nDo not accept").slides, lyricsSourceURL: target))
        XCTAssertTrue(otherSession.isEmpty)
        XCTAssertTrue(f.outputs.finishFileRemoval(reservation, removed: false))
        XCTAssertNil(f.outputs.fileAdmissionProblem(for: target))
        XCTAssertNil(f.outputs.preparedSession(workspace: f.session.outputSourceID))
    }

    func testPendingAcquisitionRejectsLateOriginalAndTrashPathsAfterSuccessWithoutBlockingFreshRequests() throws {
        let f = Fixture(); defer { f.close() }
        let original = f.url("late.txt"), trash = f.url("Trash/late.txt"), unrelated = f.url("other.txt")
        let pending = f.outputs.makeFileAcquisitionGuard()
        let reservation = try reserve(f, at: original)
        XCTAssertTrue(f.outputs.finishFileRemoval(reservation, removed: true, resultingURL: trash))

        XCTAssertEqual(pending(original), .removed)
        XCTAssertEqual(pending(trash), .removed, "A bookmark can follow the moved file before its resolver returns")
        XCTAssertEqual(pending(unrelated), .allowed)
        let fresh = f.outputs.makeFileAcquisitionGuard()
        XCTAssertEqual(fresh(original), .allowed)
        XCTAssertEqual(fresh(trash), .allowed, "Completed requests must not leave global permanent path bans")
        XCTAssertNil(f.outputs.fileAdmissionProblem(for: original))
    }

    func testUnknownRequestsDeferByExactReservationWhileKnownUnrelatedRequestCanComplete() throws {
        let f = Fixture(); defer { f.close() }
        let target = f.url("target.txt"), other = f.url("unrelated.txt")
        let unknown = f.outputs.makeFileAcquisitionGuard()
        let knownTarget = f.outputs.makeFileAcquisitionGuard(for: target)
        let knownOther = f.outputs.makeFileAcquisitionGuard(for: other)
        XCTAssertTrue(f.outputs.referencedFileURLs.isSuperset(of: [target, other]), "Pending picker sources participate in alias preparation")
        let reservation = try reserve(f, at: target)

        XCTAssertEqual(unknown(target), .deferred(reservation.id))
        XCTAssertEqual(unknown(other), .deferred(reservation.id), "Opaque results may already name an unknown Trash destination")
        XCTAssertEqual(knownTarget(target), .deferred(reservation.id))
        XCTAssertEqual(knownOther(other), .allowed)
        XCTAssertTrue(f.outputs.finishFileRemoval(reservation, removed: true))
        XCTAssertEqual(unknown(target), .removed)
        XCTAssertEqual(unknown(other), .allowed)
        XCTAssertEqual(knownOther(other), .allowed)
    }

    func testFailedRemovalDoesNotPoisonPendingAcquisitionAndStaleReceiptCannotAddFence() throws {
        let f = Fixture(); defer { f.close() }
        let target = f.url("kept.txt"), trash = f.url("Trash/kept.txt")
        let pending = f.outputs.makeFileAcquisitionGuard()
        let reservation = try reserve(f, at: target)
        let stale = OutputCoordinator.FileRemovalReservation(id: UUID(), requesterWorkspaceID: reservation.requesterWorkspaceID, url: target)
        XCTAssertFalse(f.outputs.finishFileRemoval(stale, removed: true, resultingURL: trash))
        XCTAssertEqual(pending(trash), .deferred(reservation.id))
        XCTAssertTrue(f.outputs.finishFileRemoval(reservation, removed: false))
        XCTAssertEqual(pending(target), .allowed)
        XCTAssertEqual(pending(trash), .allowed)
    }

    func testKnownSourceTicketRejectsChangedLateResultAndEndsWithItsGuardLifetime() throws {
        let f = Fixture(); defer { f.close() }
        let target = f.url("picked.txt"), changedResult = f.url("changed.txt")
        var guardRequest: ((URL) -> OutputCoordinator.FileAcquisitionAdmission)? = f.outputs.makeFileAcquisitionGuard(for: target)
        XCTAssertTrue(f.outputs.referencedFileURLs.contains(target))
        let reservation = try reserve(f, at: target)
        XCTAssertTrue(f.outputs.finishFileRemoval(reservation, removed: true))
        XCTAssertEqual(guardRequest?(changedResult), .removed, "A pending picker cannot commit its removed original through a changed result")
        guardRequest = nil
        XCTAssertFalse(f.outputs.referencedFileURLs.contains(target), "The coordinator must not retain request tickets after cancellation/completion")
        let next = f.outputs.makeFileAcquisitionGuard(for: changedResult)
        XCTAssertEqual(next(changedResult), .allowed)
        XCTAssertFalse(f.outputs.referencedFileURLs.contains(target))
    }

    func testNativeEditorQueriesUseLiveSourceInInactiveControlsWithoutClosingIt() throws {
        let f = Fixture(); defer { f.close() }
        let other = try XCTUnwrap(f.store.addWorkspace(name: "Editor"))
        _ = try XCTUnwrap(f.windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: other)))
        let commands = try XCTUnwrap(f.windows.controllers[other]?.commands)
        let view = OutputWorkspaceCloseConfirmation.ConfirmationView(frame: .zero)
        var source: URL? = f.url("open.txt")
        var closeChecks = 0
        view.editorFileURL = { source }
        view.shouldClose = { closeChecks += 1; return false }
        commands.closeConfirmation = view
        let target = try XCTUnwrap(source)
        XCTAssertTrue(f.windows.referencedFileURLs.contains(target))
        XCTAssertTrue(f.windows.fileRemovalProblem(matchingFile: f.matcher(target))?.contains("Editor") == true)
        switch f.windows.beginFileRemoval(at: target, requesterWorkspaceID: f.session.outputSourceID, matchingFile: f.matcher(target)) {
        case .admitted: XCTFail("An open editor source is protected even without unsaved changes")
        case .blocked: break
        }
        source = f.url("different.txt")
        XCTAssertNil(f.windows.fileRemovalProblem(matchingFile: f.matcher(target)))
        XCTAssertFalse(f.windows.referencedFileURLs.contains(target))
        XCTAssertEqual(closeChecks, 0, "File actions cannot implicitly close or prompt for an unrelated editor")
    }

    func testClosedRequesterStillFinishesAndNotifiesRemainingControlsWithPreparedIdentity() async throws {
        let f = Fixture(); defer { f.close() }
        let other = try XCTUnwrap(f.store.addWorkspace(name: "Other controls"))
        _ = try XCTUnwrap(f.windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: f.session.outputSourceID)))
        _ = try XCTUnwrap(f.windows.restoreWindow(identifier: OutputWorkspaceWindows.identifier(for: other)))
        let requester = try XCTUnwrap(f.windows.controllers[f.session.outputSourceID])
        let observer = try XCTUnwrap(f.windows.controllers[other])
        let view = OutputWorkspaceCloseConfirmation.ConfirmationView(frame: .zero)
        let target = f.url("remove.txt")
        try "Verse\nA file action fixture".write(to: target, atomically: true, encoding: .utf8)
        let candidate = try await LibraryFileActionService().prepareMoveToTrash(url: target, under: f.root,
            knownFileURLs: requester.commands.referencedFileURLs, cancellation: LibraryFileActionCancellation())
        var removedPaths: [URL] = []
        view.didRemoveFile = { prepared in
            XCTAssertTrue(prepared === candidate)
            XCTAssertTrue(prepared.matches(target))
            removedPaths.append(prepared.url)
        }
        observer.commands.closeConfirmation = view
        let flow = f.outputs.program(other).flow
        flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nRemove this Preview").slides)
        flow.setPreviewSource(.file(target))
        let reservation: OutputCoordinator.FileRemovalReservation
        switch requester.commands.beginFileRemoval(at: target, matchingFile: candidate.matches) {
        case .admitted(let token): reservation = token
        case .blocked(let message): XCTFail(message); return
        }
        requester.window?.close()
        XCTAssertNil(requester.commands.window)
        XCTAssertNotNil(f.outputs.fileAdmissionProblem(for: target))
        XCTAssertTrue(requester.commands.finishFileRemoval(reservation, candidate: candidate, removed: true))
        XCTAssertEqual(removedPaths, [target])
        XCTAssertTrue(flow.previewIsEmpty)
        XCTAssertNil(f.outputs.fileAdmissionProblem(for: target))
        XCTAssertFalse(requester.commands.finishFileRemoval(reservation, candidate: candidate, removed: true))
        XCTAssertEqual(removedPaths.count, 1)
    }

    private func reserve(_ f: Fixture, at url: URL) throws -> OutputCoordinator.FileRemovalReservation {
        switch f.outputs.beginFileRemoval(at: url, requesterWorkspaceID: f.session.outputSourceID, matchingFile: f.matcher(url)) {
        case .admitted(let token): return token
        case .blocked(let message):
            XCTFail(message)
            return try XCTUnwrap(nil as OutputCoordinator.FileRemovalReservation?)
        }
    }

    private func slide(video: URL? = nil, image: URL? = nil, window: CGWindowID? = nil) -> Slide {
        .init(index: 0, lines: [], label: "Fixture", videoURL: video, pdfURL: nil,
              pdfPageIndex: nil, imageURL: image, captureWindowID: window)
    }

    @MainActor private final class Fixture {
        let suite = "WorkspaceFileRemoval.\(UUID())"
        let defaults: UserDefaults
        let root: URL
        let store: OutputProfileStore
        let ndi = RecordingNDIOutput()
        let outputs: OutputCoordinator
        let session: PresentationSession
        let windows: OutputWorkspaceWindows
        init() {
            defaults = UserDefaults(suiteName: suite)!
            root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-file-removal-\(UUID())", isDirectory: true)
            try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = OutputProfileStore(defaults: defaults)
            store.edit { $0.destinations = []; $0.defaultDestinationID = nil }
            outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }),
                                        retainsPreparedSessions: true, ndi: ndi)
            session = outputs.session(workspace: OutputWorkspaceRecord.primaryID)
            windows = makeWorkspaceWindows(outputs: outputs, defaults: defaults)
        }
        func url(_ name: String) -> URL { root.appendingPathComponent(name).standardizedFileURL }
        func matcher(_ url: URL) -> (URL) -> Bool { { $0.standardizedFileURL == url.standardizedFileURL } }
        func writePDF(to url: URL) throws {
            let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
            var box = CGRect(x: 0, y: 0, width: 64, height: 64)
            let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
            context.beginPDFPage(nil); context.endPDFPage(); context.closePDF()
        }
        func close() {
            for window in windows.windows.values { window.close() }
            outputs.stopAllOutputs()
            store.flush(); defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}
