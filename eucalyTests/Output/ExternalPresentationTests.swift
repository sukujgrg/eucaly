import XCTest
import Network
import AppKit
@testable import eucaly

final class ExternalProtocolTests: XCTestCase {
    func testV2PairingCodeValidationPreservesItsWireAlphabet() throws {
        let generated = try AltViewPairingKey.generate()
        XCTAssertEqual(generated.count, 8)
        XCTAssertEqual(AltViewPairingKey.parse(AltViewPairingKey.text(generated)), generated)
        XCTAssertNil(AltViewPairingKey.parse("bad")); XCTAssertNil(AltViewPairingKey.parse("0000OOOO"))
    }
}

@MainActor
final class ExternalPresentationTests: XCTestCase {
    private func setup() -> (OutputCoordinator, PresentationSession, PresentationFlowController) {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Audience", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let profiles = OutputProfileStore(monitor: monitor.target)
        let coordinator = OutputCoordinator(profiles: profiles, displays: displays, driverFactory: { FakeOutputDriver() })
        return (coordinator, PresentationSession(projectionDisplays: displays, outputCoordinator: coordinator), PresentationFlowController())
    }
    @discardableResult private func present(_ outputs: OutputCoordinator, _ text: String, connection: UUID = UUID(), name: String = "ViewTheWord") throws -> OutputLease {
        try outputs.presentReceived(connection: connection, sourceID: UUID(), name: name, revision: 1,
            content: .init(body: text, template: .scripture), ingressOrder: outputs.actionClock.next())
    }
    func testDirectPresentRetainsLocalPreparationAndOrdinaryActionsReclaim() async throws {
        let (outputs, session, flow) = setup(); defer { outputs.stop() }
        let current = LyricsParser.parseDocument("Verse\nLocal one\n\nChorus\nLocal two").slides
        session.setSlides(current)
        flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPrepared next song").slides)
        let connection = UUID()
        let lease = try present(outputs, "Verse text", connection: connection)
        XCTAssertTrue(outputs.isExternal); XCTAssertEqual(outputs.text.components.first?.text, "Verse text")
        XCTAssertEqual(session.currentSlideID, current[0].id); XCTAssertEqual(flow.previewSlideCount, 1)
        // Private preparation and passive refresh never take back external output.
        session.setSlides(current); flow.selectPreviewSlide(flow.previewSlides[0].id)
        session.setBackgroundAudioVolume(0.2)
        var confidence = outputs.profiles.document.profiles[1]; confidence.typography.size = 100; outputs.profiles.update(confidence)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(outputs.isExternal)
        session.selectCurrentSlide(current[0].id) // Same-slide action reclaims.
        XCTAssertEqual(outputs.ownership.source, .local(session.outputSourceID))
        XCTAssertFalse(outputs.updateReceived(connection: connection, lease: lease, revision: 2, content: .init(body: "Late")))
        outputs.externalDisconnected(connection)
        XCTAssertTrue(outputs.visible); XCTAssertEqual(outputs.text.components.first?.text, "Local one")
        try present(outputs, "External again")
        session.moveSelection(1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(outputs.text.components.first?.text, "Local two")
        try present(outputs, "External load")
        flow.setCurrentSlides(flow.previewSlides, in: session)
        session.requestCurrentProjection()
        XCTAssertEqual(outputs.text.components.first?.text, "Prepared next song")
        session.clearSlides()
        XCTAssertTrue(outputs.text.isEmpty); XCTAssertNil(outputs.ownership.source)
        XCTAssertEqual(flow.previewSlideCount, 1)
    }
    func testHideFreezesConfidenceAndHiddenNavigationCannotReclaim() throws {
        let (outputs, session, _) = setup(); defer { outputs.stop() }
        session.setSlides(LyricsParser.parseDocument("Verse\nPrivate").slides)
        let connection = UUID()
        let lease = try present(outputs, "Frozen external", connection: connection)
        session.hideSlides()
        XCTAssertFalse(outputs.visible); XCTAssertNil(outputs.ownership.source)
        XCTAssertEqual(outputs.text.components.first?.text, "Frozen external")
        session.selectCurrentSlide(session.slides[0].id)
        XCTAssertNil(outputs.ownership.source)
        XCTAssertFalse(outputs.updateReceived(connection: connection, lease: lease, revision: 2, content: .init(body: "Late")))
        outputs.clear(); XCTAssertTrue(outputs.text.isEmpty)
        session.showSlides(); XCTAssertEqual(outputs.text.components.first?.text, "Private")
    }
    func testInvalidPresentLeavesLiveSourceAndConfiguredMissingMeaningCollapses() throws {
        let (outputs, session, _) = setup(); defer { outputs.stop() }
        session.setSlides(LyricsParser.parseDocument("Verse\nCurrent").slides); session.showSlides()
        let oldSource = outputs.ownership.source
        XCTAssertThrowsError(try present(outputs, String(repeating: "界", count: 30_000)))
        XCTAssertEqual(outputs.ownership.source, oldSource)
        outputs.profiles.edit { $0.destinations[0].enabled = false }
        XCTAssertThrowsError(try present(outputs, "No destination"))
        XCTAssertEqual(outputs.text.components.first?.text, "Current")
        let meaning = OutputProfile(id: UUID(), name: "Custom", kind: .audience, roles: [.meaning])
        XCTAssertTrue(meaning.components(in: .init(components: [.init(role: .primary, text: "Text")])).isEmpty)
    }
    func testDisplacementCancelsDeferredAltViewRequestAndExactAudienceIdentity() async throws {
        let sender = RecordingAltViewSender()
        let name = "OutputAltView.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let service = AltViewService(defaults: defaults, pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        let hub = HubOutputHarness(service: service); defer { hub.stop() }
        let outputs = hub.outputs, session = hub.session
        service.receive(sender.connectedStatus)
        session.setSlides(LyricsParser.parseDocument("Verse\nLyrics\nMeaning\nCompanion\n\nChorus\nNext lyrics").slides)
        session.showSlides()
        XCTAssertEqual(sender.submissions.last?.content.body, "Lyrics")
        XCTAssertEqual(sender.submissions.last?.content.projection?.windowID, 42)
        let takes = sender.takes
        session.moveSelection(1)
        try present(outputs, "External follows the live program")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sender.takes, takes + 1)
        XCTAssertEqual(sender.submissions.last?.content.body, "External follows the live program")
        XCTAssertNil(sender.submissions.last?.content.projection)
        XCTAssertTrue(service.isSending)
        XCTAssertNil(outputs.localSession)
        XCTAssertNil(outputs.snapshot.localMedia)
        session.showSlides()
        XCTAssertTrue(outputs.localSession === session)
        XCTAssertEqual(sender.takes, takes + 2)
        XCTAssertEqual(sender.submissions.last?.content.body, "Lyrics")
        service.disconnect()
    }
    func testQueuedNavigationCannotTakeBackANewerExternalPresent() async throws {
        let (outputs, session, _) = setup(); defer { outputs.stop() }
        session.setSlides(LyricsParser.parseDocument("Verse\nOne\n\nChorus\nTwo").slides)
        session.showSlides(); session.moveSelection(1)
        try present(outputs, "Newer")
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(outputs.isExternal)
        XCTAssertEqual(outputs.text.components.first?.text, "Newer")
    }
    func testQueuedExternalPresentCannotOvertakeNewerLocalShowHideClearOrStop() throws {
        let (outputs, session, _) = setup(); defer { outputs.stop() }
        session.setSlides(LyricsParser.parseDocument("Verse\nLocal").slides)
        for command in [session.showSlides, session.hideSlides, session.clearSlides, session.stopPresentation] {
            session.showSlides()
            let queuedOrder = outputs.actionClock.next()
            command()
            XCTAssertThrowsError(try outputs.presentReceived(connection: UUID(), sourceID: UUID(), name: "Delayed app", revision: 1,
                content: .init(body: "Queued old external"), ingressOrder: queuedOrder))
            XCTAssertNotEqual(outputs.text.components.first?.text, "Queued old external")
        }
    }
    func testWorkspaceRoutingUsesOnlyFocusedWorkspace() {
        let first = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        let second = NSWindow(contentRect: CGRect(x: 30, y: 30, width: 200, height: 100), styleMask: .titled, backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        defer { first.close(); second.close() }
        let focus = TestKeyWindowSource()
        focus.value = first
        let a = OutputWorkspaceCommands(keyWindow: { focus.value }), b = OutputWorkspaceCommands(keyWindow: { focus.value })
        a.window = first; b.window = second
        XCTAssertTrue(a.isActive); XCTAssertFalse(b.isActive)
        focus.value = second
        XCTAssertFalse(a.isActive); XCTAssertTrue(b.isActive)
        focus.value = nil
        XCTAssertFalse(a.isActive); XCTAssertFalse(b.isActive)
    }
}

@MainActor private final class TestKeyWindowSource { var value: NSWindow? }
