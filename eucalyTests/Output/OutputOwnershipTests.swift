import XCTest
@testable import eucaly

@MainActor
final class OutputOwnershipTests: XCTestCase {
    func testLocalCommandsAdvanceQueuedNavigationOrder() {
        let clock = OutputActionClock()
        let first = clock.next(), newer = clock.next()
        XCTAssertLessThan(first, newer); XCTAssertEqual(clock.current, newer)
    }
    func testLateWorkspacePreparationCannotDisplaceNewerAction() {
        var ownership = OutputOwnership()
        let a = UUID(), b = UUID()
        let oldAction = ownership.beginAction()
        let newer = ownership.beginAction()
        XCTAssertTrue(ownership.take(b, action: newer))
        XCTAssertFalse(ownership.take(a, action: oldAction)); XCTAssertEqual(ownership.source, b)
        ownership.revoke()
        XCTAssertNil(ownership.source); XCTAssertFalse(ownership.take(a, action: newer))
    }
    func testSameLocalSlideGetsFreshGeneration() {
        var ownership = OutputOwnership()
        let local = UUID()
        let firstAction = ownership.beginAction()
        XCTAssertTrue(ownership.take(local, action: firstAction))
        let first = ownership.generation
        let secondAction = ownership.beginAction()
        XCTAssertTrue(ownership.take(local, action: secondAction))
        XCTAssertGreaterThan(ownership.generation, first); XCTAssertEqual(ownership.source, local)
    }
}

@MainActor
final class OutputLifecycleTests: XCTestCase {
    func testExplicitNativeOpenDoesNotNeedKeyControlsOrAcceptPreparedCurrent() async throws {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Confidence", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] })
        let profiles = OutputProfileStore(monitor: monitor.target)
        let id = profiles.document.destinations[0].id
        profiles.selectProfile(OutputProfile.confidenceID, for: id)
        let driver = FakeOutputDriver()
        let coordinator = OutputCoordinator(profiles: profiles, displays: displays, keyWindow: { nil }, driverFactory: { driver })
        defer { coordinator.stopAllOutputs() }
        XCTAssertFalse(coordinator.isOpen(id), "Passive restoration waits for real controls readiness.")
        XCTAssertNil(coordinator.preparedSession(workspace: OutputWorkspaceRecord.primaryID))
        coordinator.openConfidence(id)
        XCTAssertTrue(coordinator.isOpen(id))
        XCTAssertEqual(driver.activations, [false])
        XCTAssertNil(coordinator.preparedSession(workspace: OutputWorkspaceRecord.primaryID))
        XCTAssertNil(coordinator.media(for: id)?.program)
        XCTAssertFalse(coordinator.snapshot(for: id).visible)
        coordinator.closeOutput(id)
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: coordinator)
        coordinator.workspaceWindowReady(session)
        await drainMainQueue()
        XCTAssertFalse(coordinator.isOpen(id), "Native Close suppresses passive reopening.")
        coordinator.openNativeOutput(id)
        XCTAssertTrue(coordinator.isOpen(id))
    }

    func testConfidenceEnableAndAssignmentWorkBeforeControlsReadinessAndRoleChangeRetiresOnlyStandby() async throws {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Confidence", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] })
        let profiles = OutputProfileStore()
        let id = profiles.document.destinations[0].id
        profiles.selectProfile(OutputProfile.confidenceID, for: id)
        XCTAssertNil(profiles.setEnabled(false, for: id))
        let coordinator = OutputCoordinator(profiles: profiles, displays: displays, keyWindow: { nil }, driverFactory: { FakeOutputDriver() })
        defer { coordinator.stopAllOutputs() }
        XCTAssertTrue(coordinator.assignMonitor(monitor.target, to: id))
        await drainMainQueue()
        XCTAssertFalse(coordinator.isOpen(id))
        XCTAssertNil(profiles.setEnabled(true, for: id))
        await drainMainQueue()
        XCTAssertTrue(coordinator.isOpen(id))
        XCTAssertNil(coordinator.preparedSession(workspace: OutputWorkspaceRecord.primaryID))
        profiles.selectProfile(OutputProfile.audienceID, for: id)
        XCTAssertFalse(coordinator.isOpen(id), "An automatic idle clock has no program to retain after its role changes.")
        profiles.selectProfile(OutputProfile.confidenceID, for: id)
        await drainMainQueue()
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: coordinator)
        session.setSlides(LyricsParser.parseDocument("Verse\nLive program").slides); session.showSlides()
        profiles.selectProfile(OutputProfile.audienceID, for: id)
        XCTAssertTrue(coordinator.isOpen(id), "A live program is independent of automatic standby.")
        XCTAssertTrue(session.isPresenting)
        XCTAssertEqual(coordinator.snapshot(for: id).current.components.first?.text, "Live program")
    }

    func testExplicitNativeOpenRejectsUnavailableMonitorWithoutPreparingProgram() {
        let profiles = OutputProfileStore(monitor: .init(identity: UUID().uuidString, name: "Disconnected"))
        let coordinator = OutputCoordinator(profiles: profiles, displays: ProjectionDisplayManager(displays: { [] }), keyWindow: { nil }, driverFactory: { FakeOutputDriver() })
        let id = profiles.document.destinations[0].id
        let editor = OutputDestinationEditor(coordinator: coordinator, destinationID: id)
        _ = editor.view
        coordinator.openNativeOutput(id)
        editor.render()
        XCTAssertFalse(coordinator.isOpen(id))
        XCTAssertNil(coordinator.preparedSession(workspace: OutputWorkspaceRecord.primaryID))
        XCTAssertTrue(coordinator.outputIssue(workspace: OutputWorkspaceRecord.primaryID)?.contains("available monitor") == true)
        XCTAssertTrue(editor.statusLabel.stringValue.contains("Workspace Home:"))
        XCTAssertTrue(editor.statusLabel.stringValue.contains("available monitor"))
        XCTAssertNil(coordinator.focusedWorkspaceID, "A Settings action must not invent controls focus.")
    }

    func testNativeSettingsOpenShowsDriverFailureAndRecoversWithoutControlsFocus() {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Available", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let profiles = OutputProfileStore(monitor: monitor.target)
        let driver = FakeOutputDriver(); driver.opensSuccessfully = false
        let coordinator = OutputCoordinator(profiles: profiles, displays: ProjectionDisplayManager(displays: { [monitor] }),
                                            keyWindow: { nil }, driverFactory: { driver })
        defer { coordinator.stopAllOutputs() }
        let id = profiles.document.destinations[0].id
        let editor = OutputDestinationEditor(coordinator: coordinator, destinationID: id)
        _ = editor.view
        XCTAssertTrue(editor.confidenceButton.isEnabled)
        editor.confidenceButton.performClick(nil)
        XCTAssertFalse(coordinator.isOpen(id))
        XCTAssertTrue(editor.statusLabel.stringValue.contains("Workspace Home:"))
        XCTAssertTrue(editor.statusLabel.stringValue.contains("could not be opened"))
        profiles.edit { $0.profiles[0].alignment = "left" }
        editor.render()
        XCTAssertTrue(editor.statusLabel.stringValue.contains("could not be opened"), "A cosmetic edit does not complete the failed Open action.")
        XCTAssertNil(coordinator.focusedWorkspaceID)
        XCTAssertNil(coordinator.preparedSession(workspace: OutputWorkspaceRecord.primaryID))
        driver.opensSuccessfully = true
        editor.confidenceButton.performClick(nil)
        XCTAssertTrue(coordinator.isOpen(id))
        XCTAssertFalse(editor.statusLabel.stringValue.contains("could not be opened"))
        XCTAssertNil(coordinator.outputIssue(workspace: OutputWorkspaceRecord.primaryID))
        XCTAssertNil(coordinator.focusedWorkspaceID)
        XCTAssertNil(coordinator.preparedSession(workspace: OutputWorkspaceRecord.primaryID))
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
    }

    func testLossAndClosureAffectOneDestinationAndRetainCurrent() throws {
        var monitors = [1, 2].map { number in ProjectionMonitor(id: UInt32(number), identity: UUID().uuidString, name: "Identical", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)) }
        let displays = ProjectionDisplayManager(displays: { monitors })
        XCTAssertTrue(displays.select(monitors[0].target))
        let profiles = OutputProfileStore(monitor: monitors[0].target)
        let confidence = try XCTUnwrap(profiles.document.profiles.first { $0.kind == .confidence })
        profiles.edit { $0.destinations.append(.init(name: "Confidence", profileID: confidence.id, monitor: monitors[1].target)) }
        var drivers: [FakeOutputDriver] = []
        var begins = 0, ends = 0
        let sleep = ProjectionSleepPrevention(beginActivity: { _, _ in begins += 1; return NSObject() }, endActivity: { _ in ends += 1 })
        let coordinator = OutputCoordinator(profiles: profiles, displays: displays, sleepPrevention: sleep, driverFactory: {
            let driver = FakeOutputDriver(); drivers.append(driver); return driver
        })
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: coordinator)
        let slides = LyricsParser.parseDocument("Verse\nCurrent retained").slides
        session.setSlides(slides); session.showSlides()
        XCTAssertEqual(coordinator.readiness.values.filter { $0 == .ready }.count, 2)
        XCTAssertEqual(begins, 1)
        let secondaryID = profiles.document.destinations[1].id
        coordinator.destinationClosed(secondaryID, generation: drivers[1].generation)
        XCTAssertTrue(coordinator.isRunning); XCTAssertEqual(ends, 0)
        XCTAssertEqual(session.currentSlideID, slides[0].id)
        session.hideSlides(); XCTAssertEqual(ends, 0)
        session.showSlides(); XCTAssertEqual(drivers.count, 3)
        // A late close cannot close the new generation.
        coordinator.destinationClosed(secondaryID, generation: drivers[1].generation)
        XCTAssertEqual(coordinator.readiness[secondaryID], .ready)
        monitors.removeFirst(); displays.refresh()
        XCTAssertTrue(coordinator.isRunning)
        XCTAssertNil(coordinator.audienceIdentity.0)
        XCTAssertEqual(ends, 0)
        coordinator.stop(); XCTAssertEqual(ends, 1)
        XCTAssertEqual(session.currentSlideID, slides[0].id)
    }
    func testDuplicatedAudienceUsesDefaultMonitorControlAndUnassignmentSurvivesRefresh() throws {
        var monitors = [1, 2].map { ProjectionMonitor(id: UInt32($0), identity: UUID().uuidString, name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080)) }
        let displays = ProjectionDisplayManager(displays: { monitors }); displays.select(monitors[0].target)
        let profiles = OutputProfileStore(monitor: monitors[0].target)
        var copy = profiles.audience; copy.id = UUID(); copy.name = "Custom Audience"
        profiles.edit { $0.profiles.append(copy); $0.destinations[0].profileID = copy.id }
        let outputs = OutputCoordinator(profiles: profiles, displays: displays, driverFactory: { FakeOutputDriver() })
        XCTAssertEqual(profiles.audience.id, copy.id)
        XCTAssertTrue(displays.select(monitors[1].target))
        XCTAssertEqual(profiles.document.destinations[0].monitor, monitors[1].target)
        XCTAssertTrue(displays.clearSelection())
        XCTAssertNil(profiles.document.destinations[0].monitor)
        monitors.removeFirst(); displays.refresh()
        XCTAssertNil(displays.target); XCTAssertNil(profiles.document.destinations[0].monitor)
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nNo monitor").slides); session.showSlides()
        XCTAssertNotNil(session.projectionDisplayIssue); XCTAssertNil(outputs.ownership.source)
        XCTAssertFalse(outputs.isRunning)
    }
    func testUnusedStandaloneSessionAndCoordinatorAreReleased() {
        weak var releasedSession: PresentationSession?
        weak var releasedCoordinator: OutputCoordinator?
        do {
            let session = PresentationSession()
            releasedSession = session; releasedCoordinator = session.outputCoordinator
            session.setBackgroundAudio(url: URL(fileURLWithPath: "/tmp/audio-lifetime.mov"), autoplay: true)
        }
        XCTAssertNil(releasedSession)
        XCTAssertNil(releasedCoordinator)
    }
    func testInjectedCoordinatorCanTearDownAfterRetainingPreparedCurrent() {
        weak var releasedSession: PresentationSession?
        weak var releasedCoordinator: OutputCoordinator?
        do {
            let displays = ProjectionDisplayManager(displays: { [] })
            let outputs = OutputCoordinator(profiles: OutputProfileStore(), displays: displays, retainsPreparedSessions: true)
            let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
            releasedSession = session; releasedCoordinator = outputs
            session.setSlides(LyricsParser.parseDocument("Verse\nPrepared").slides)
            outputs.stop()
        }
        XCTAssertNil(releasedSession); XCTAssertNil(releasedCoordinator)
    }
    func testAppOwnedCoordinatorRetainsPreparedCurrentAfterStop() {
        let displays = ProjectionDisplayManager(displays: { [] })
        let outputs = OutputCoordinator(profiles: OutputProfileStore(), displays: displays, retainsPreparedSessions: true)
        weak var retainedSession: PresentationSession?
        do {
            let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
            session.setSlides(LyricsParser.parseDocument("Verse\nRetain Current").slides)
            retainedSession = session
        }
        outputs.stop()
        XCTAssertNotNil(retainedSession)
        XCTAssertEqual(outputs.preferredLocalSession?.currentSlide?.lines.first?.text, "Retain Current")
    }
    func testDestinationCloseCancelsQueuedNavigationWithoutReopeningTheWindow() async throws {
        let hub = LocalOutputHarness(); defer { hub.stop() }
        hub.load("Verse\nFirst\n\nChorus\nSecond"); hub.session.showSlides()
        let current = hub.session.currentSlideID
        hub.session.moveSelection(1)
        hub.outputs.destinationClosed(hub.nativeRow, generation: hub.driver.generation)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(hub.outputs.isOpen(hub.nativeRow))
        XCTAssertEqual(hub.session.currentSlideID, current)
        XCTAssertEqual(hub.outputs.text.components.first?.text, "First")
    }
}

@MainActor
final class FakeOutputDriver: OutputDestinationDriving {
    let generation = UUID()
    var windowNumber: UInt32? = 42
    var closes = 0
    var activations: [Bool] = []
    var opensSuccessfully = true
    func open(monitor: ProjectionMonitor, coordinator: OutputCoordinator, destinationID: UUID, activate: Bool) -> Bool { activations.append(activate); return opensSuccessfully }
    func reposition(monitor: ProjectionMonitor) -> Bool { true }
    func close() { closes += 1 }
}
