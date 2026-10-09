import XCTest
import Network
@testable import eucaly

@MainActor
final class AltViewPresentationTests: XCTestCase {
    func testLaunchAndUnusedShutdownDoNotCreateSenderOrRestorePreferencesInTestHost() throws {
        let name = "AltViewLaunchTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("custom", forKey: "altViewTemplate")
        defaults.set(try JSONEncoder().encode(AltViewDestination.manual(host: "saved.local", port: "49721")!), forKey: "altViewDestination")
        var created = false
        let service = AltViewService(defaults: defaults, restorePreferences: false, senderFactory: { _ in
            created = true
            return RecordingAltViewSender()
        })
        XCTAssertNil(service.destination)
        XCTAssertEqual(service.selectedTemplate, .lyrics)
        service.restoreConnection()
        service.disconnect()
        XCTAssertFalse(created)
        XCTAssertNil(defaults.string(forKey: "altViewSenderID"))
    }

    private func snapshot(_ raw: String, visible: Bool = true) -> PresentationOutputSnapshot {
        PresentationOutputSnapshot(slide: LyricsParser.parseDocument(raw).slides.first, isPresenting: true, slidesVisible: visible)
    }

    func testPrimaryLyricsOnlyPreserveUnicodeAndLineBreaks() {
        let content = AltViewPresentationAdapter.content(for: snapshot("""
        Verse 1
        സ്തുതി · שלום
        Main second line
        Meaning
        Meaning text
        Translation
        Translation text
        Transliteration
        Transliteration text
        """))
        XCTAssertEqual(content.body, "സ്തുതി · שלום\nMain second line")
        XCTAssertEqual(content.title, "")
        XCTAssertEqual(content.footer, "")
        XCTAssertTrue(content.visible)
        XCTAssertEqual(content.emptyRegions, .collapse)
    }

    func testCompanionOnlyAndAllMediaClearText() {
        XCTAssertEqual(AltViewPresentationAdapter.content(for: snapshot("Meaning\nOnly companion text")), .empty)
        let lines = [SlideLine(kind: .verse, languageTag: "", text: "Must not leak from media")]
        let url = URL(fileURLWithPath: "/tmp/media")
        let slides = [
            Slide(index: 1, lines: lines, label: nil, videoURL: url, pdfURL: nil, pdfPageIndex: nil, imageURL: nil),
            Slide(index: 1, lines: lines, label: nil, videoURL: nil, pdfURL: url, pdfPageIndex: 0, imageURL: nil),
            Slide(index: 1, lines: lines, label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: url),
            Slide(index: 1, lines: lines, label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, webpageURL: URL(string: "https://example.com")),
            Slide(index: 1, lines: lines, label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: 42)
        ]
        for slide in slides {
            XCTAssertEqual(AltViewPresentationAdapter.content(for: .init(slide: slide, isPresenting: true, slidesVisible: true)), .empty)
        }
    }

    func testHideRetainsPrimaryText() {
        let content = AltViewPresentationAdapter.content(for: snapshot("Verse 1\nMain", visible: false))
        XCTAssertEqual(content.body, "Main")
        XCTAssertFalse(content.visible)
    }

    func testCurrentFlowAndLocalLayersRemainIndependent() async throws {
        let (service, sender) = connectedService()
        let session = PresentationSession()
        let flow = PresentationFlowController()
        service.attach(session)
        flow.setPreviewSlides(LyricsParser.parseDocument("Verse 1\nPreview only").slides)
        flow.selectPreviewSlide(try XCTUnwrap(flow.previewSlides.first?.id))
        await settle()
        XCTAssertTrue(sender.submissions.isEmpty)
        session.setSlides(LyricsParser.parseDocument("Verse 1\nCurrent first\n\nChorus\nCurrent second").slides)
        await settle()
        XCTAssertTrue(sender.submissions.isEmpty, "Loading Current while stopped is not a show intent")
        session.isPresenting = true // Avoid opening a physical window in unit tests.
        session.showSlides()
        XCTAssertEqual(sender.takes, 1)
        XCTAssertEqual(sender.submissions.last?.content.body, "Current first")
        flow.setPreviewSlides(LyricsParser.parseDocument("Verse 1\nDifferent preview").slides)
        await settle()
        XCTAssertEqual(sender.submissions.count, 1)
        session.currentSlideID = session.slides.last?.id
        await settle()
        XCTAssertEqual(sender.submissions.last?.content.body, "Current second")
        XCTAssertEqual(sender.takes, 1)
        session.hideSlides()
        await settle()
        XCTAssertFalse(try XCTUnwrap(sender.submissions.last).content.visible)
        XCTAssertEqual(sender.submissions.last?.content.body, "Current second")
        let count = sender.submissions.count
        session.isBackgroundVisualVisible.toggle()
        session.setBackgroundAudioVolume(0.25)
        session.setOverlayMode(.clock)
        await settle()
        XCTAssertEqual(sender.submissions.count, count)
        session.clearSlides()
        await settle()
        XCTAssertEqual(sender.submissions.last?.content, .empty)
        session.stopPresentation()
        XCTAssertEqual(sender.releases, 1)
    }

    func testLatestLocalSubmissionCannotBeConfirmedByAnOlderStatus() throws {
        let (service, sender) = connectedService()
        let source = UUID()
        service.handle(.show(snapshot("Verse 1\nOne")), from: source)
        let first = try XCTUnwrap(sender.submissions.last)
        var status = sender.connectedStatus
        let lease = UUID()
        status.ownsOutput = true
        status.followingOutput = true
        status.submissionID = first.id
        status.feedback.sent(1, now: 0)
        status.feedback.receive(.init(kind: .feedback, lease: lease, revision: 1, outputReadiness: .ready), lease: lease, now: 1)
        service.receive(status)
        XCTAssertTrue(service.latestAccepted)
        service.handle(.changed(snapshot("Verse 1\nTwo")), from: source)
        service.receive(status)
        XCTAssertFalse(service.latestAccepted)
    }

    func testStopAndSourceSwitchDiscardPendingPublication() {
        let (service, sender) = connectedService(ready: false)
        let a = UUID(), b = UUID()
        service.handle(.show(snapshot("Verse 1\nA")), from: a)
        service.handle(.stopped, from: a)
        service.receive(sender.connectedStatus)
        XCTAssertEqual(sender.takes, 0)
        service.handle(.show(snapshot("Verse 1\nB")), from: b)
        service.handle(.changed(snapshot("Verse 1\nOld A")), from: a)
        service.handle(.stopped, from: a)
        XCTAssertEqual(sender.submissions.last?.content.body, "B")
        XCTAssertEqual(sender.takes, 1)
    }

    func testBackgroundChangesStayPassiveAndExplicitShowSurvivesReconnect() {
        let (service, sender) = connectedService()
        let source = UUID()
        service.handle(.show(snapshot("Verse 1\nFirst")), from: source)
        var status = sender.connectedStatus
        status.ownerName = "Another sender"
        service.receive(status)
        service.handle(.changed(snapshot("Verse 1\nSecond")), from: source)
        XCTAssertEqual(sender.takes, 1)
        status.connected = false
        service.receive(status)
        service.handle(.show(snapshot("Verse 1\nThird")), from: source)
        service.receive(sender.connectedStatus)
        XCTAssertEqual(sender.takes, 2, "An explicit Show made during reconnect still takes output")
        XCTAssertEqual(sender.submissions.last?.content.body, "Third")
    }

    func testVisibleActivationNavigationAndLoadTakeButRefreshAndHideStayPassive() async throws {
        let (service, sender) = connectedService()
        let session = PresentationSession(), flow = PresentationFlowController()
        service.attach(session)
        let slides = LyricsParser.parseDocument("Verse 1\nFirst\n\nChorus\nSecond").slides
        session.setSlides(slides)
        session.isPresenting = true
        await settle()
        XCTAssertTrue(sender.submissions.isEmpty, "Connecting alone leaves existing Current private")
        flow.selectCurrentSlide(slides[0].id, in: session)
        await settle()
        XCTAssertEqual(sender.takes, 1)
        XCTAssertEqual(sender.submissions.last?.content.body, "First")
        flow.selectCurrentSlide(slides[0].id, in: session)
        await settle()
        XCTAssertEqual(sender.takes, 2, "Reactivating the same slide is an explicit projection")
        session.moveSelection(1)
        await settle()
        XCTAssertEqual(sender.takes, 3)
        XCTAssertEqual(sender.submissions.last?.content.body, "Second")

        var status = sender.connectedStatus
        status.ownerName = "ViewTheWord"
        service.receive(status)
        let replacement = LyricsParser.parseDocument("Verse 1\nRefreshed lyrics\n\nChorus\nReplacement").slides
        session.setSlides(replacement)
        await settle()
        XCTAssertEqual(sender.takes, 3, "Model refreshes, even with new slide IDs, cannot reclaim output")
        session.requestCurrentProjection() // Explicit Load/Switch Current after its model transaction.
        await settle()
        XCTAssertEqual(sender.takes, 4)
        session.hideSlides()
        flow.selectCurrentSlide(replacement[1].id, in: session)
        await settle()
        XCTAssertEqual(sender.takes, 4, "Hide and navigation while hidden cannot reclaim output")
        XCTAssertFalse(try XCTUnwrap(sender.submissions.last).content.visible)
        session.showSlides()
        XCTAssertEqual(sender.takes, 5)
        XCTAssertEqual(sender.submissions.last?.content.body, "Replacement")
        session.stopPresentation()
    }

    func testHideAndStopCancelDeferredProjectionAndReconnectRequests() async {
        let (service, sender) = connectedService()
        let session = PresentationSession(), flow = PresentationFlowController()
        service.attach(session)
        let slides = LyricsParser.parseDocument("Verse 1\nFirst\n\nChorus\nSecond").slides
        session.setSlides(slides)
        session.isPresenting = true
        flow.selectCurrentSlide(slides[0].id, in: session)
        session.hideSlides()
        await settle()
        XCTAssertEqual(sender.takes, 0)
        session.areSlidesVisible = true
        flow.selectCurrentSlide(slides[0].id, in: session)
        session.stopPresentation()
        await settle()
        XCTAssertEqual(sender.takes, 0, "Stop invalidates a deferred activation")

        var disconnected = sender.connectedStatus
        disconnected.connected = false
        service.receive(disconnected)
        service.handle(.show(snapshot("Verse 1\nPending")), from: session.outputSourceID)
        service.handle(.stopped, from: session.outputSourceID)
        service.receive(sender.connectedStatus)
        XCTAssertEqual(sender.takes, 0, "Stop cancels a projection queued during established reconnect")
        XCTAssertFalse(service.isSending)
    }

    func testCancelIgnoresLateConnectionAndGrants() {
        let (service, sender) = connectedService(ready: false)
        service.handle(.show(snapshot("Verse 1\nPending")), from: UUID())
        let oldStatus = sender.connectedStatus
        service.disconnect()
        service.receive(oldStatus)
        XCTAssertFalse(service.status.connected)
        XCTAssertFalse(service.isSending)
        XCTAssertEqual(sender.takes, 0)
    }

    func testTemplateSelectionIsPrivateUntilNextSlideOrExplicitShow() throws {
        let (service, sender) = connectedService()
        let source = UUID()
        let first = snapshot("Verse 1\nFirst")
        service.handle(.show(first), from: source)
        XCTAssertEqual(sender.submissions.last?.content.template, .lyrics)
        service.selectTemplate(.scripture)
        var status = sender.connectedStatus
        status.templateCapabilities = .init(templates: [.init(id: .lyrics, name: "Lyrics")], policy: .custom)
        service.receive(status)
        service.handle(.changed(first), from: source)
        XCTAssertEqual(sender.submissions.count, 1)
        let hidden = PresentationOutputSnapshot(slide: first.slide, isPresenting: true, slidesVisible: false)
        service.handle(.changed(hidden), from: source)
        XCTAssertEqual(sender.submissions.last?.content.template, .lyrics, "Blank preserves the published request")
        service.handle(.show(first), from: source)
        XCTAssertEqual(sender.submissions.last?.content.template, .scripture)
        service.selectTemplate(nil)
        service.handle(.changed(snapshot("Verse 1\nNext")), from: source)
        XCTAssertNil(sender.submissions.last?.content.template)
        service.selectTemplate(.lyrics)
        service.handle(.changed(.init(slide: nil, isPresenting: true, slidesVisible: true)), from: source)
        XCTAssertEqual(sender.submissions.last?.content, .empty)
        XCTAssertEqual(sender.takes, 2, "Discovery and selection never take output")
    }

    func testSavedTemplateAndConnectionRestoreWithoutTakingOutput() throws {
        let name = "AltViewRestoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let destination = AltViewDestination.manual(host: "saved.local", port: "49721")!
        defaults.set(try JSONEncoder().encode(destination), forKey: "altViewDestination")
        defaults.set("future.v3", forKey: "altViewTemplate")
        let store = RecordingAltViewPairingStore()
        let sender = RecordingAltViewSender()
        let service = AltViewService(defaults: defaults, pairingStore: store, senderFactory: { _ in sender })
        XCTAssertEqual(service.selectedTemplate?.rawValue, "future.v3")
        service.restoreConnection()
        service.restoreConnection()
        XCTAssertEqual(store.readCount, 1)
        XCTAssertTrue(service.isConnecting)
        let credentials = AltViewCredentials(key: Data("ABCD2345".utf8), receiverID: UUID())
        store.readCompletion?(credentials, nil)
        XCTAssertEqual(sender.expectedReceiverID, credentials.receiverID)
        service.receive(sender.connectedStatus)
        XCTAssertTrue(sender.submissions.isEmpty)
        XCTAssertEqual(sender.takes, 0)
        service.selectTemplate(nil)
        XCTAssertEqual(defaults.string(forKey: "altViewTemplate"), "")
        XCTAssertNil(AltViewService(defaults: defaults, pairingStore: store).selectedTemplate)
    }

    func testCancelSavedConnectionReadCannotConnectLater() {
        let store = RecordingAltViewPairingStore()
        let sender = RecordingAltViewSender()
        let service = AltViewService(restorePreferences: false, pairingStore: store, senderFactory: { _ in sender })
        service.connect(to: .manual(host: "saved.local", port: "49721")!, code: "")
        service.disconnect()
        store.readCompletion?(.init(key: Data("ABCD2345".utf8), receiverID: UUID()), nil)
        XCTAssertNil(sender.connectionID)
        XCTAssertFalse(service.hasConnection)
    }

    func testShowDuringSavedPairingReadSubmitsLatestWhenConnectionStarts() {
        let store = RecordingAltViewPairingStore()
        let sender = RecordingAltViewSender()
        let service = AltViewService(restorePreferences: false, pairingStore: store, senderFactory: { _ in sender })
        service.connect(to: .manual(host: "saved.local", port: "49721")!, code: "")
        let source = UUID()
        service.handle(.show(snapshot("Verse 1\nFirst")), from: source)
        service.handle(.changed(snapshot("Verse 1\nLatest")), from: source)
        XCTAssertTrue(sender.submissions.isEmpty, "A snapshot waits for its connection mailbox")
        store.readCompletion?(.init(key: Data("ABCD2345".utf8), receiverID: UUID()), nil)
        XCTAssertEqual(sender.submissions.count, 1)
        XCTAssertEqual(sender.submissions.last?.content.body, "Latest")
        service.receive(sender.connectedStatus)
        XCTAssertEqual(sender.takes, 1)
    }

    func testStopDuringSavedPairingReadCancelsBufferedPublication() {
        let store = RecordingAltViewPairingStore()
        let sender = RecordingAltViewSender()
        let service = AltViewService(restorePreferences: false, pairingStore: store, senderFactory: { _ in sender })
        service.connect(to: .manual(host: "saved.local", port: "49721")!, code: "")
        let source = UUID()
        service.handle(.show(snapshot("Verse 1\nStopped")), from: source)
        service.handle(.stopped, from: source)
        store.readCompletion?(.init(key: Data("ABCD2345".utf8), receiverID: UUID()), nil)
        service.receive(sender.connectedStatus)
        XCTAssertTrue(sender.submissions.isEmpty)
        XCTAssertEqual(sender.takes, 0)
        XCTAssertFalse(service.isSending)
    }

    private func connectedService(ready: Bool = true) -> (AltViewService, RecordingAltViewSender) {
        let sender = RecordingAltViewSender()
        let name = "AltViewTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let service = AltViewService(defaults: defaults, senderFactory: { _ in sender })
        service.connect(to: .manual(host: "127.0.0.1", port: "49721")!, code: "ABCD2345")
        if ready { service.receive(sender.connectedStatus) }
        return (service, sender)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(25)) }
}

nonisolated final class RecordingAltViewSender: AltViewSending {
    var submissions: [AltViewSubmission] = []
    var endpoints: [NWEndpoint] = []
    var takes = 0
    var releases = 0
    var connectionID: UUID?
    var expectedReceiverID: UUID?
    var connectedStatus: AltViewSenderStatus {
        AltViewSenderStatus(connectionID: connectionID, connected: true)
    }
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID?, connectionID: UUID) { self.connectionID = connectionID; self.expectedReceiverID = expectedReceiverID }
    func submit(_ content: AltViewDisplayContent, submissionID: UUID) { submissions.append(.init(id: submissionID, content: content)) }
    func updateEndpoint(_ endpoint: NWEndpoint, connectionID: UUID) { if self.connectionID == connectionID { endpoints.append(endpoint) } }
    func takeOutput(submission: AltViewSubmission?) { takes += 1 }
    func releaseOutput() { releases += 1 }
    func disconnect() { connectionID = nil }
}

nonisolated final class RecordingAltViewPairingStore: AltViewPairingStoring {
    var readCount = 0
    var readCompletion: ((AltViewCredentials?, String?) -> Void)?
    func read(_ destination: AltViewDestination, completion: @escaping (AltViewCredentials?, String?) -> Void) {
        readCount += 1
        readCompletion = completion
    }
    func save(_ credentials: AltViewCredentials, for destination: AltViewDestination, completion: @escaping (String?) -> Void) {
        completion(nil)
    }
}
