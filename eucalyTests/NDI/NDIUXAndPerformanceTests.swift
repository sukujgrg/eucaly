import XCTest
import AppKit
@testable import eucaly

@MainActor
final class NDIUXAndPerformanceTests: XCTestCase {
    func testCompletedSubmissionRateWarnsForSustainedLowCadenceAndRecovers() throws {
        var metrics = NDISubmissionMetrics()
        XCTAssertNil(metrics.framesPerSecond)
        metrics.submitted(at: 0, newPictureProducedAt: nil)
        for index in 1...60 { metrics.submitted(at: UInt64(index) * 1_000_000_000 / 30, newPictureProducedAt: nil) }
        XCTAssertEqual(try XCTUnwrap(metrics.framesPerSecond), 30, accuracy: 0.01)
        XCTAssertFalse(metrics.slowCadence)
        for index in 1...5 { metrics.submitted(at: 2_000_000_000 + UInt64(index) * 200_000_000, newPictureProducedAt: nil) }
        XCTAssertFalse(metrics.slowCadence, "One slow window must not turn transient jitter into a persistent warning")
        for index in 1...5 { metrics.submitted(at: 3_000_000_000 + UInt64(index) * 200_000_000, newPictureProducedAt: nil) }
        XCTAssertEqual(try XCTUnwrap(metrics.framesPerSecond), 5, accuracy: 0.01)
        XCTAssertTrue(metrics.slowCadence, "Submission progress alone must not count as meeting 30 fps")
        for index in 1...30 { metrics.submitted(at: 4_000_000_000 + UInt64(index) * 1_000_000_000 / 30, newPictureProducedAt: nil) }
        XCTAssertFalse(metrics.slowCadence)
    }

    func testNewFrameAgeDoesNotAgeAnUnchangedCachedStill() throws {
        var metrics = NDISubmissionMetrics()
        metrics.submitted(at: 1_000_000_000, newPictureProducedAt: 980_000_000)
        XCTAssertEqual(try XCTUnwrap(metrics.frameAgeMilliseconds), 20, accuracy: 0.01)
        for index in 1...90 { metrics.submitted(at: 1_000_000_000 + UInt64(index) * 1_000_000_000 / 30, newPictureProducedAt: nil) }
        XCTAssertEqual(try XCTUnwrap(metrics.frameAgeMilliseconds), 20, accuracy: 0.01)
        XCTAssertFalse(metrics.slowCadence)
        var status = NDIHelperStatus(); status.effectiveFramesPerSecond = .nan
        XCTAssertFalse(status.validMetrics)
        status.effectiveFramesPerSecond = 30; status.frameAgeMilliseconds = -1
        XCTAssertFalse(status.validMetrics)
    }

    func testOperationsRemainVisibleWhenNDIConfigurationScrolls() throws {
        let fixture = Fixture(); defer { fixture.outputs.stop() }
        var longName = try XCTUnwrap(fixture.store.document.destinations.first { $0.id == fixture.lyrics }?.ndi)
        longName.sourceName = String(repeating: "Source", count: 20)
        XCTAssertNil(fixture.store.setNDISettings(longName, for: fixture.lyrics))
        let controller = ManageOutputsController(coordinator: fixture.outputs)
        let window = NSWindow(contentRect: .init(x: -10000, y: -10000, width: 780, height: 580), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentViewController = controller
        window.setContentSize(.init(width: 780, height: 580))
        defer { controller.finishEditing(); window.close() }
        window.orderBack(nil); controller.setPresented(true); controller.selectDestination(fixture.lyrics)
        let editor = try XCTUnwrap(controller.destinationEditor?.ndiEditor)
        editor.publishedNameLabel.stringValue = "Published: " + String(repeating: "Source name ", count: 15)
        editor.publishedNameLabel.isHidden = false
        editor.performanceLabel.stringValue = "30.0 / 30 fps · New frame age 20 ms"; editor.performanceLabel.isHidden = false
        window.layoutIfNeeded()
        XCTAssertNil(editor.startButton.enclosingScrollView)
        XCTAssertNil(editor.statusLabel.enclosingScrollView)
        let form = try XCTUnwrap(editor.sourceName.enclosingScrollView)
        let before = controller.view.convert(editor.startButton.bounds, from: editor.startButton)
        XCTAssertTrue(controller.view.bounds.contains(before), "Start/Stop must fit inside the minimum Settings content size")
        XCTAssertLessThanOrEqual(controller.view.bounds.width, 780)
        form.documentView?.scroll(.init(x: 0, y: form.documentView?.bounds.height ?? 0))
        window.layoutIfNeeded()
        XCTAssertEqual(controller.view.convert(editor.startButton.bounds, from: editor.startButton), before)
    }

    func testEveryGenericOutputExposesTypographyAndBackgrounds() throws {
        let fixture = Fixture(); defer { fixture.outputs.stop() }
        let lyricsProfile = try XCTUnwrap(fixture.outputs.profile(for: fixture.lyrics))
        let mediaProfile = try XCTUnwrap(fixture.outputs.profile(for: fixture.media))
        let editor = OutputProfileEditor(store: fixture.store, profileID: lyricsProfile.id)
        _ = editor.view
        XCTAssertFalse(editor.textControls.isHidden)
        XCTAssertFalse(editor.visualControls.isHidden)
        XCTAssertTrue(editor.usageNotice.stringValue.contains("owning workspace"))
        editor.selectProfile(mediaProfile.id)
        XCTAssertFalse(editor.textControls.isHidden)
        XCTAssertFalse(editor.visualControls.isHidden)
        fixture.store.selectProfile(mediaProfile.id, for: fixture.store.document.destinations[0].id)
        editor.render()
        XCTAssertFalse(editor.textControls.isHidden, "A reusable profile shared with a native output must retain its native controls")
        let quick = OutputQuickControlsController(outputs: fixture.outputs, manageOutputs: {})
        fixture.store.setDefaultDestination(fixture.lyrics); quick.render()
        XCTAssertTrue(quick.appearanceButton.isEnabled); XCTAssertTrue(quick.backgroundButton.isEnabled)
        fixture.store.setDefaultDestination(fixture.media); quick.render()
        XCTAssertTrue(quick.appearanceButton.isEnabled); XCTAssertTrue(quick.backgroundButton.isEnabled)
    }

    func testGlobalMusicChoicesDisambiguateNamesAndKeepUUIDRouting() throws {
        let fixture = Fixture(); defer { fixture.outputs.stop() }
        let lyrics = NDIOutputSettingsEditor(coordinator: fixture.outputs, destinationID: fixture.lyrics)
        let media = NDIOutputSettingsEditor(coordinator: fixture.outputs, destinationID: fixture.media)
        _ = lyrics.view; _ = media.view
        XCTAssertNotEqual(lyrics.audioRoute.itemTitle(at: 1), lyrics.audioRoute.itemTitle(at: 2))
        XCTAssertTrue(lyrics.audioRoute.itemTitle(at: 1).contains("Lyrics"))
        XCTAssertTrue(lyrics.audioRoute.itemTitle(at: 2).contains("eucaly Media"))
        lyrics.audioRoute.selectItem(at: 2)
        NSApp.sendAction(try XCTUnwrap(lyrics.audioRoute.action), to: lyrics.audioRoute.target, from: lyrics.audioRoute)
        XCTAssertEqual(fixture.store.document.backgroundAudioDestinationID, fixture.media)
        media.render()
        XCTAssertEqual(media.audioRoute.selectedItem?.representedObject as? UUID, fixture.media)
        media.audioRoute.selectItem(at: 0)
        NSApp.sendAction(try XCTUnwrap(media.audioRoute.action), to: media.audioRoute.target, from: media.audioRoute)
        XCTAssertNil(fixture.store.document.backgroundAudioDestinationID)
    }

    func testFailureAndPerformanceNoticesNameTheAffectedSourceAndPreserveCurrent() async throws {
        let fixture = Fixture(); defer { fixture.outputs.stop() }
        fixture.session.showSlides()
        fixture.driver.reportPerformance("Output is below 30 fps (5.0 fps).", id: fixture.media)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(fixture.outputs.issue?.contains("Projector (eucaly Media)") == true)
        XCTAssertTrue(fixture.outputs.issue?.contains("5.0 fps") == true)
        XCTAssertEqual(fixture.outputs.snapshot.current.components.first?.text, "Live")
        fixture.outputs.dismissIssue()
        fixture.driver.reportPerformance("Output is below 30 fps (6.0 fps).", id: fixture.media)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(fixture.outputs.issue, "Changing measurements must not undo an operator's dismissal")
        fixture.driver.reportPerformance(nil, id: fixture.media)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(fixture.outputs.issue)
        fixture.driver.reportPerformance("Output is below 30 fps (5.0 fps).", id: fixture.media)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(fixture.outputs.issue, "A fresh degradation after recovery must warn again")
        fixture.driver.reportPerformance(nil, id: fixture.media)
        try await Task.sleep(for: .milliseconds(20))
        fixture.driver.fail(fixture.lyrics)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(fixture.outputs.issue?.contains("Projector (eucaly Lyrics): Injected failure") == true)
        XCTAssertEqual(fixture.driver.activeIDs, [fixture.media])
        XCTAssertTrue(fixture.session.isPresenting)
        fixture.store.setEnabled(false, for: fixture.lyrics)
        XCTAssertNil(fixture.outputs.issue, "Disabling the failed source acknowledges its workspace failure")
    }

    func testRecoveryClearsPerformanceWarningWithoutDismissingAndFailureHasPriority() async throws {
        let fixture = Fixture(); defer { fixture.outputs.stop() }
        fixture.session.showSlides()
        fixture.driver.reportPerformance("Output is below 30 fps.", id: fixture.media)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNotNil(fixture.session.projectionDisplayIssue)
        fixture.driver.reportPerformance(nil, id: fixture.media)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(fixture.outputs.issue)
        XCTAssertNil(fixture.session.projectionDisplayIssue)

        fixture.driver.reportPerformance("Output is below 30 fps.", id: fixture.media)
        fixture.driver.fail(fixture.lyrics)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(fixture.session.projectionDisplayIssue?.contains("Injected failure") == true)
        fixture.driver.reportPerformance(nil, id: fixture.media)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(fixture.session.projectionDisplayIssue?.contains("Injected failure") == true)
        fixture.outputs.startNDI(fixture.lyrics)
        XCTAssertNil(fixture.outputs.issue)
    }

    @MainActor private final class Fixture {
        let store = OutputProfileStore()
        let driver = RecordingNDIOutput()
        let outputs: OutputCoordinator
        let session: PresentationSession
        let lyrics: UUID, media: UUID
        init() {
            var a = OutputDestinationConfiguration(name: "Projector", profileID: OutputProfile.audienceID, monitor: nil)
            var b = a; b.id = UUID()
            a.ndi = .init(sourceName: "eucaly Lyrics"); b.ndi = .init(sourceName: "eucaly Media")
            var pa = store.audience, pb = pa
            pa.id = UUID(); pb.id = UUID(); a.profileID = pa.id; b.profileID = pb.id
            pa.customizedForDestinationID = a.id; pb.customizedForDestinationID = b.id
            lyrics = a.id; media = b.id
            store.edit { $0.destinations[0].enabled = false; $0.profiles += [pa, pb]; $0.destinations += [a, b] }
            outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), ndi: driver)
            session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
            session.setSlides(LyricsParser.parseDocument("Verse\nLive").slides)
        }
    }
}
