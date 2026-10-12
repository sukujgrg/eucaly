import XCTest
@testable import eucaly

final class OutputOwnershipTests: XCTestCase {
    func testLatePreparationAndDisplacedConnectionCannotCommitOrClear() throws {
        var ownership = OutputOwnership()
        let a = UUID(), b = UUID()
        let oldAction = ownership.beginAction()
        let newer = ownership.beginAction()
        let lease = try XCTUnwrap(ownership.take(.external(connection: b, source: UUID()), action: newer))
        XCTAssertNil(ownership.take(.external(connection: a, source: UUID()), action: oldAction))
        XCTAssertFalse(ownership.update(connection: a, lease: lease, revision: 1))
        XCTAssertTrue(ownership.update(connection: b, lease: lease, revision: 1))
        XCTAssertFalse(ownership.update(connection: b, lease: lease, revision: 1))
        ownership.revoke()
        XCTAssertFalse(ownership.permits(connection: b, lease: lease))
        XCTAssertNil(ownership.take(.external(connection: a, source: UUID()), action: newer))
    }
    func testLocalSameSlideGetsFreshGenerationAndReconnectDoesNotRestoreLease() throws {
        var ownership = OutputOwnership()
        let local = UUID(), connection = UUID()
        let action = ownership.beginAction()
        let external = try XCTUnwrap(ownership.take(.external(connection: connection, source: UUID()), action: action))
        let firstAction = ownership.beginAction()
        let first = try XCTUnwrap(ownership.take(.local(local), action: firstAction))
        let secondAction = ownership.beginAction()
        let second = try XCTUnwrap(ownership.take(.local(local), action: secondAction))
        XCTAssertGreaterThan(second.generation, first.generation)
        XCTAssertFalse(ownership.permits(connection: connection, lease: external))
        XCTAssertFalse(ownership.permits(connection: UUID(), lease: external))
    }
}

@MainActor
final class OutputLifecycleTests: XCTestCase {
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
        let message = ExternalPresentationMessage(kind: .present, sourceID: UUID(), actionID: UUID(), revision: 1, current: .init(components: [.init(role: .primary, text: "No monitor")]))
        XCTAssertThrowsError(try outputs.presentExternal(connection: UUID(), name: "App", message: message))
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
    func testEventSubscriptionsDoNotReplaceExistingObservers() async {
        let session = PresentationSession()
        var legacy = 0, first = 0, second = 0
        session.onOutputEvent = { _ in legacy += 1 }
        let token = session.observeOutput { _ in first += 1 }
        _ = session.observeOutput { _ in second += 1 }
        session.emitOutputEvent(.stopped)
        session.removeOutputObserver(token)
        session.emitOutputEvent(.stopped)
        XCTAssertEqual(legacy, 2); XCTAssertEqual(first, 1); XCTAssertEqual(second, 2)
    }
}

@MainActor
final class FakeOutputDriver: OutputDestinationDriving {
    let generation = UUID()
    var windowNumber: UInt32? = 42
    var closes = 0
    func open(monitor: ProjectionMonitor, coordinator: OutputCoordinator, destinationID: UUID, activate: Bool) -> Bool { true }
    func reposition(monitor: ProjectionMonitor) -> Bool { true }
    func close() { closes += 1 }
}
