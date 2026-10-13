import XCTest
import Network
@testable import eucaly

@MainActor
final class AltViewPresentationTests: XCTestCase {
    private func setup(ready: Bool = true) -> (HubOutputHarness, RecordingAltViewSender) {
        let sender = RecordingAltViewSender()
        let service = AltViewService(pairingStore: RecordingAltViewPairingStore(), senderFactory: { _ in sender })
        let hub = HubOutputHarness(service: service)
        if ready { service.receive(sender.connectedStatus) }
        return (hub, sender)
    }
    private func settle() async { try? await Task.sleep(for: .milliseconds(30)) }

    func testLaunchAndUnusedShutdownDoNotCreateSenderOrRestoreLegacySelection() throws {
        let name = "AltViewLaunchTests.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("custom", forKey: "altViewTemplate")
        defaults.set(try JSONEncoder().encode(AltViewDestination.manual(host: "saved.local", port: "49721")!), forKey: "altViewDestination")
        var created = false
        let service = AltViewService(defaults: defaults, senderFactory: { _ in created = true; return RecordingAltViewSender() })
        XCTAssertNil(service.destination)
        service.disconnect()
        XCTAssertFalse(created); XCTAssertNil(defaults.string(forKey: "altViewSenderID"))
    }
    func testPrimaryLyricsOnlyPreserveUnicodeAndLineBreaks() {
        let (hub, sender) = setup(); defer { hub.stop() }
        hub.load("Verse 1\nസ്തുതി · שלום\nMain second line\nMeaning\nMeaning text\nTranslation\nTranslation text\nTransliteration\nTransliteration text")
        hub.session.showSlides()
        XCTAssertEqual(sender.submissions.last?.content.body, "സ്തുതി · שלום\nMain second line")
        XCTAssertEqual(sender.submissions.last?.content.title, ""); XCTAssertEqual(sender.submissions.last?.content.footer, "")
        XCTAssertEqual(sender.submissions.last?.content.template, .lyrics)
    }
    func testPreviewLoadingAndBackgroundStayPrivateAndRuntimeHideClearStopPublish() async {
        let (hub, sender) = setup(); defer { hub.stop() }
        hub.flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPreview only").slides)
        hub.load("Verse\nFirst\n\nChorus\nSecond"); await settle()
        XCTAssertTrue(sender.submissions.isEmpty)
        hub.session.showSlides(); XCTAssertEqual(sender.takes, 1)
        hub.flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nDifferent Preview").slides); await settle()
        XCTAssertEqual(sender.submissions.count, 1)
        hub.session.moveSelection(1); await settle()
        XCTAssertEqual(sender.submissions.last?.content.body, "Second"); XCTAssertEqual(sender.takes, 2)
        hub.session.hideSlides(); await settle()
        XCTAssertFalse(sender.submissions.last!.content.visible)
        let count = sender.submissions.count
        hub.session.isBackgroundVisualVisible.toggle(); hub.session.setBackgroundAudioVolume(0.25); await settle()
        XCTAssertEqual(sender.submissions.count, count)
        hub.session.clearSlides(); await settle()
        XCTAssertEqual(sender.submissions.last?.content, .empty)
        hub.session.stopPresentation(); XCTAssertFalse(hub.service.isSending)
    }
    func testLatestSubmissionCannotBeConfirmedByAnOlderStatus() throws {
        let (hub, sender) = setup(); defer { hub.stop() }
        hub.load("Verse\nOne"); hub.session.showSlides()
        let first = try XCTUnwrap(sender.submissions.last), lease = UUID()
        var status = sender.connectedStatus; status.ownsOutput = true; status.followingOutput = true; status.submissionID = first.id
        status.feedback.sent(1, now: 0)
        status.feedback.receive(.init(kind: .feedback, lease: lease, revision: 1, outputReadiness: .ready), lease: lease, now: 1)
        hub.service.receive(status); XCTAssertTrue(hub.service.latestAccepted)
        hub.load("Verse\nTwo"); hub.outputs.passiveLocal(hub.session)
        hub.service.receive(status); XCTAssertFalse(hub.service.latestAccepted)
    }
    func testStopDiscardsPendingPublicationAndNewSourceCanPublish() {
        let (hub, sender) = setup(ready: false); defer { hub.stop() }
        hub.load("Verse\nA"); hub.session.showSlides(); hub.outputs.stop()
        hub.service.receive(sender.connectedStatus); XCTAssertEqual(sender.takes, 0)
        hub.load("Verse\nB"); hub.session.showSlides()
        XCTAssertEqual(sender.submissions.last?.content.body, "B"); XCTAssertEqual(sender.takes, 1)
    }
    func testPassiveRefreshDoesNotTakeAndExplicitShowSurvivesReconnect() {
        let (hub, sender) = setup(); defer { hub.stop() }
        hub.load("Verse\nFirst"); hub.session.showSlides()
        var status = sender.connectedStatus; status.ownerName = "Another sender"; hub.service.receive(status)
        hub.load("Verse\nSecond"); hub.outputs.passiveLocal(hub.session); XCTAssertEqual(sender.takes, 1)
        status.connected = false; hub.service.receive(status)
        hub.load("Verse\nThird"); hub.session.showSlides(); hub.service.receive(sender.connectedStatus)
        XCTAssertEqual(sender.takes, 2); XCTAssertEqual(sender.submissions.last?.content.body, "Third")
    }
    func testVisibleActivationNavigationAndLoadTakeButHiddenNavigationStaysPrivate() async {
        let (hub, sender) = setup(); defer { hub.stop() }
        hub.load("Verse\nFirst\n\nChorus\nSecond"); hub.session.showSlides()
        let slides = hub.session.slides
        hub.flow.selectCurrentSlide(slides[0].id, in: hub.session); await settle()
        XCTAssertEqual(sender.takes, 2)
        hub.session.moveSelection(1); await settle(); XCTAssertEqual(sender.takes, 3)
        hub.load("Verse\nRefreshed\n\nChorus\nReplacement"); await settle()
        XCTAssertEqual(sender.takes, 3)
        hub.session.requestCurrentProjection(); await settle(); XCTAssertEqual(sender.takes, 4)
        hub.session.hideSlides(); hub.flow.selectCurrentSlide(hub.session.slides[1].id, in: hub.session); await settle()
        XCTAssertEqual(sender.takes, 4); XCTAssertFalse(sender.submissions.last!.content.visible)
        hub.session.showSlides(); XCTAssertEqual(sender.takes, 5)
        XCTAssertEqual(sender.submissions.last?.content.body, "Replacement")
    }
    func testHideAndStopCancelDeferredNavigationAndReconnectRequests() async {
        let (hub, sender) = setup(); defer { hub.stop() }
        hub.load("Verse\nFirst\n\nChorus\nSecond"); hub.session.showSlides()
        let takes = sender.takes
        hub.session.moveSelection(1); hub.session.hideSlides(); await settle()
        XCTAssertEqual(sender.takes, takes)
        hub.session.showSlides()
        let beforeStop = sender.takes
        hub.session.moveSelection(1); hub.session.stopPresentation(); await settle()
        XCTAssertEqual(sender.takes, beforeStop)
        var status = sender.connectedStatus; status.connected = false; hub.service.receive(status)
        hub.session.showSlides(); hub.outputs.stop(); hub.service.receive(sender.connectedStatus)
        XCTAssertEqual(sender.takes, beforeStop); XCTAssertFalse(hub.service.isSending)
    }
    func testCancelIgnoresLateConnection() {
        let (hub, sender) = setup(ready: false); defer { hub.stop() }
        hub.load("Verse\nPending"); hub.session.showSlides()
        let oldStatus = sender.connectedStatus
        hub.service.disconnect(); hub.service.receive(oldStatus)
        XCTAssertFalse(hub.service.status.connected); XCTAssertFalse(hub.service.isSending); XCTAssertEqual(sender.takes, 0)
    }
    func testHideCancelsUnacceptedShowDuringEstablishedReconnect() {
        let (hub, sender) = setup(); defer { hub.stop() }
        hub.load("Verse\nPresented"); hub.session.showSlides()
        var status = sender.connectedStatus; status.connected = false; hub.service.receive(status)
        hub.session.showSlides()
        let takes = sender.takes, cancellations = sender.cancellations
        hub.session.hideSlides(); hub.service.receive(sender.connectedStatus)
        XCTAssertEqual(sender.takes, takes, "Hide cancels the buffered take before reconnection completes")
        XCTAssertGreaterThan(sender.cancellations, cancellations)
        XCTAssertFalse(sender.submissions.last!.content.visible)
    }
    func testCancelSavedConnectionReadCannotConnectLater() {
        let store = RecordingAltViewPairingStore(), sender = RecordingAltViewSender()
        let service = AltViewService(pairingStore: store, senderFactory: { _ in sender })
        service.connect(to: .manual(host: "saved.local", port: "49721")!, code: ""); service.disconnect()
        store.readCompletion?(.init(key: Data("ABCD2345".utf8), receiverID: UUID()), nil)
        XCTAssertNil(sender.connectionID); XCTAssertFalse(service.hasConnection)
    }
    func testShowDuringSavedPairingReadSubmitsLatestAndRetainsExplicitSnapshot() {
        let store = RecordingAltViewPairingStore(), sender = RecordingAltViewSender()
        let service = AltViewService(pairingStore: store, senderFactory: { _ in sender })
        let hub = HubOutputHarness(service: service, code: ""); defer { hub.stop() }
        hub.load("Verse\nFirst"); hub.session.showSlides()
        hub.load("Verse\nLatest"); hub.outputs.passiveLocal(hub.session)
        XCTAssertTrue(sender.submissions.isEmpty)
        store.readCompletion?(.init(key: Data("ABCD2345".utf8), receiverID: hub.remoteID), nil)
        XCTAssertEqual(sender.submissions.last?.content.body, "Latest")
        service.receive(sender.connectedStatus); XCTAssertEqual(sender.takes, 1)
        XCTAssertEqual(sender.takeSubmissions.first?.content.body, "First")
    }
    func testStopDuringSavedPairingReadCancelsBufferedPublication() {
        let store = RecordingAltViewPairingStore(), sender = RecordingAltViewSender()
        let service = AltViewService(pairingStore: store, senderFactory: { _ in sender })
        let hub = HubOutputHarness(service: service, code: ""); defer { hub.stop() }
        hub.load("Verse\nStopped"); hub.session.showSlides(); hub.outputs.stop()
        store.readCompletion?(.init(key: Data("ABCD2345".utf8), receiverID: hub.remoteID), nil)
        service.receive(sender.connectedStatus)
        XCTAssertTrue(sender.submissions.isEmpty); XCTAssertEqual(sender.takes, 0); XCTAssertFalse(service.isSending)
    }
}

nonisolated final class RecordingAltViewSender: AltViewSending {
    var submissions: [AltViewSubmission] = []
    var endpoints: [NWEndpoint] = []
    var takes = 0
    var releases = 0
    var cancellations = 0
    var takeSubmissions: [AltViewSubmission] = []
    var connectionID: UUID?
    var expectedReceiverID: UUID?
    var connectedStatus: AltViewSenderStatus { AltViewSenderStatus(connectionID: connectionID, connected: true) }
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID?, connectionID: UUID) { self.connectionID = connectionID; self.expectedReceiverID = expectedReceiverID }
    func submit(_ content: AltViewDisplayContent, submissionID: UUID) { submissions.append(.init(id: submissionID, content: content)) }
    func updateEndpoint(_ endpoint: NWEndpoint, connectionID: UUID) { if self.connectionID == connectionID { endpoints.append(endpoint) } }
    func takeOutput(submission: AltViewSubmission?) { takes += 1; if let submission { takeSubmissions.append(submission) } }
    func releaseOutput() { releases += 1 }
    func cancelPendingPresentation() { cancellations += 1 }
    func disconnect() { connectionID = nil }
}

nonisolated final class RecordingAltViewPairingStore: AltViewPairingStoring {
    var readCount = 0
    var readCompletion: ((AltViewCredentials?, String?) -> Void)?
    func read(_ destination: AltViewDestination, completion: @escaping (AltViewCredentials?, String?) -> Void) { readCount += 1; readCompletion = completion }
    func save(_ credentials: AltViewCredentials, for destination: AltViewDestination, completion: @escaping (String?) -> Void) { completion(nil) }
}
