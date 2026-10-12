import XCTest
import Network
import AppKit
@testable import eucaly

final class ExternalProtocolTests: XCTestCase {
    func testFragmentedFramesBoundsAndAllRoles() throws {
        let text = OutputTextContent(kind: .scripture, components: OutputComponentRole.allCases.map { .init(role: $0, text: "സ്തുതി · שלום · \($0.rawValue)", language: "mul") })
        let message = ExternalPresentationMessage(kind: .present, sourceID: UUID(), actionID: UUID(), revision: 1, current: text)
        try message.validate()
        let frame = try ExternalPresentationProtocol.frame(message)
        var decoder = ExternalFrameDecoder(), payloads: [Data] = []
        for byte in frame { payloads += try decoder.append(Data([byte])) }
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(try JSONDecoder().decode(ExternalPresentationMessage.self, from: payloads[0]), message)
        XCTAssertThrowsError(try decoder.append(Data([0, 1, 0, 1])))
        XCTAssertThrowsError(try ExternalPresentationMessage(kind: .present).validate())
        XCTAssertThrowsError(try ExternalPresentationMessage(kind: .hello, protocolVersion: "future", credential: "key", clientName: "app").validate())
        let oversized = ExternalPresentationMessage(kind: .present, sourceID: UUID(), actionID: UUID(), revision: 1,
            current: .init(components: [.init(role: .primary, text: String(repeating: "界", count: 30_000))]))
        XCTAssertThrowsError(try ExternalPresentationProtocol.frame(oversized))
        XCTAssertThrowsError(try oversized.validate())
    }
    func testMailboxKeepsExplicitActionsAndBoundsRapidUpdates() throws {
        var mailbox = ExternalInboundMailbox()
        let lease = OutputLease(id: UUID(), generation: 1)
        for revision in 1...2_000 { try mailbox.enqueue(.init(kind: .state, revision: UInt64(revision), lease: lease, current: .empty)) }
        XCTAssertEqual(mailbox.messages.count, 1)
        try mailbox.enqueue(.init(kind: .clear, actionID: UUID(), lease: lease))
        try mailbox.enqueue(.init(kind: .state, revision: 2_001, lease: lease, current: .empty))
        XCTAssertEqual(mailbox.drain().map(\.kind), [.state, .clear, .state])
        for _ in 0..<32 { try mailbox.enqueue(.init(kind: .hide, actionID: UUID(), lease: lease)) }
        XCTAssertThrowsError(try mailbox.enqueue(.init(kind: .release, actionID: UUID(), lease: lease)))
    }
    func testCredentialAuthenticationRejectsMalformedAndWrongKeys() {
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        XCTAssertTrue(ExternalAuthentication.matches(key, key))
        XCTAssertFalse(ExternalAuthentication.matches("bad", key))
        XCTAssertFalse(ExternalAuthentication.matches(Data(repeating: 8, count: 32).base64EncodedString(), key))
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
    private func present(_ text: String, role: OutputComponentRole = .primary) -> ExternalPresentationMessage {
        .init(kind: .present, sourceID: UUID(), actionID: UUID(), revision: 1,
              current: .init(kind: .scripture, components: [.init(role: role, text: text)]))
    }
    func testDirectPresentRetainsLocalPreparationAndOrdinaryActionsReclaim() async throws {
        let (outputs, session, flow) = setup(); defer { outputs.stop() }
        let current = LyricsParser.parseDocument("Verse\nLocal one\n\nChorus\nLocal two").slides
        session.setSlides(current)
        flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPrepared next song").slides)
        let connection = UUID()
        let lease = try outputs.presentExternal(connection: connection, name: "Reference scripture", message: present("Verse text"))
        XCTAssertTrue(outputs.isExternal); XCTAssertEqual(outputs.text.components.first?.text, "Verse text")
        XCTAssertEqual(session.currentSlideID, current[0].id); XCTAssertEqual(flow.previewSlideCount, 1)
        // Private preparation and passive refresh never take back external output.
        session.setSlides(current); flow.selectPreviewSlide(flow.previewSlides[0].id)
        session.setOverlayMode(.clock); session.setBackgroundAudioVolume(0.2)
        var meaning = outputs.profiles.document.profiles[2]; meaning.typography.size = 100; outputs.profiles.update(meaning)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(outputs.isExternal)
        session.selectCurrentSlide(current[0].id) // Same-slide action reclaims.
        XCTAssertEqual(outputs.ownership.source, .local(session.outputSourceID))
        XCTAssertFalse(outputs.updateExternal(connection: connection, message: .init(kind: .state, revision: 2, lease: lease, current: present("Late").current)))
        outputs.externalDisconnected(connection)
        XCTAssertTrue(outputs.visible); XCTAssertEqual(outputs.text.components.first?.text, "Local one")
        _ = try outputs.presentExternal(connection: UUID(), name: "App", message: present("External again"))
        session.moveSelection(1)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(outputs.text.components.first?.text, "Local two")
        _ = try outputs.presentExternal(connection: UUID(), name: "App", message: present("External load"))
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
        let connection = UUID(), message = present("Frozen external")
        let lease = try outputs.presentExternal(connection: connection, name: "Scripture", message: message)
        session.hideSlides()
        XCTAssertFalse(outputs.visible); XCTAssertNil(outputs.ownership.source)
        XCTAssertEqual(outputs.text.components.first?.text, "Frozen external")
        session.selectCurrentSlide(session.slides[0].id)
        XCTAssertNil(outputs.ownership.source)
        XCTAssertFalse(outputs.updateExternal(connection: connection, message: .init(kind: .state, revision: 2, lease: lease, current: present("Late").current)))
        outputs.clear(); XCTAssertTrue(outputs.text.isEmpty)
        session.showSlides(); XCTAssertEqual(outputs.text.components.first?.text, "Private")
    }
    func testInvalidPresentLeavesLiveSourceAndConfiguredMissingMeaningCollapses() throws {
        let (outputs, session, _) = setup(); defer { outputs.stop() }
        session.setSlides(LyricsParser.parseDocument("Verse\nCurrent").slides); session.showSlides()
        let oldSource = outputs.ownership.source
        var request = present("Scripture")
        request.profileID = outputs.profiles.document.profiles[2].id
        XCTAssertThrowsError(try outputs.presentExternal(connection: UUID(), name: "App", message: request))
        XCTAssertEqual(outputs.ownership.source, oldSource)
        outputs.profiles.edit { $0.destinations[0].enabled = false }
        XCTAssertThrowsError(try outputs.presentExternal(connection: UUID(), name: "App", message: present("No destination")))
        XCTAssertEqual(outputs.text.components.first?.text, "Current")
        let meaning = outputs.profiles.document.profiles[2]
        XCTAssertTrue(meaning.components(in: present("Scripture").current!).isEmpty)
    }
    func testDisplacementCancelsDeferredAltViewRequestAndExactAudienceIdentity() async throws {
        let (outputs, session, _) = setup(); defer { outputs.stop() }
        let sender = RecordingAltViewSender()
        let name = "OutputAltView.\(UUID())", defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let service = AltViewService(defaults: defaults, restorePreferences: false, pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        service.connect(to: .manual(host: "127.0.0.1", port: "49721")!, code: "ABCD2345")
        service.receive(sender.connectedStatus); service.attach(session)
        session.setSlides(LyricsParser.parseDocument("Verse\nLyrics\nMeaning\nCompanion").slides)
        session.showSlides()
        XCTAssertEqual(sender.submissions.last?.content.body, "Lyrics")
        XCTAssertEqual(sender.submissions.last?.content.projection?.windowID, 42)
        let takes = sender.takes
        session.selectCurrentSlide(session.slides[0].id)
        _ = try outputs.presentExternal(connection: UUID(), name: "Scripture", message: present("External must not relay"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sender.takes, takes)
        XCTAssertEqual(sender.releases, 1)
        XCTAssertFalse(service.isSending)
        session.showSlides()
        XCTAssertEqual(sender.takes, takes + 1)
        XCTAssertEqual(sender.submissions.last?.content.body, "Lyrics")
        service.disconnect()
    }
    func testQueuedNavigationCannotTakeBackANewerExternalPresent() async throws {
        let (outputs, session, _) = setup(); defer { outputs.stop() }
        session.setSlides(LyricsParser.parseDocument("Verse\nOne\n\nChorus\nTwo").slides)
        session.showSlides(); session.moveSelection(1)
        _ = try outputs.presentExternal(connection: UUID(), name: "Newer scripture", message: present("Newer"))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(outputs.isExternal)
        XCTAssertEqual(outputs.text.components.first?.text, "Newer")
    }
    func testQueuedExternalPresentCannotOvertakeNewerLocalShowHideClearOrStop() throws {
        let (outputs, session, _) = setup(); defer { outputs.stop() }
        session.setSlides(LyricsParser.parseDocument("Verse\nLocal").slides)
        for command in [session.showSlides, session.hideSlides, session.clearSlides, session.stopPresentation] {
            session.showSlides()
            var queued = present("Queued old external")
            queued.ingressOrder = outputs.actionClock.next()
            command()
            XCTAssertThrowsError(try outputs.presentExternal(connection: UUID(), name: "Delayed app", message: queued))
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
