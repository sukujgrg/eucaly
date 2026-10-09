import AppKit
import Network
import XCTest
@testable import eucaly

@MainActor
final class AltViewRecoveryTests: XCTestCase {
    private func eventually(_ description: String, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), description)
    }

    private func local(_ id: UUID, port: UInt16) -> AltViewDestination {
        var destination = AltViewDestination.manual(host: "127.0.0.1", port: String(port))!
        destination.localReceiverID = id
        return destination
    }

    private func service(store: AltViewPairingStoring = RecordingAltViewPairingStore())
        -> (AltViewService, RecoveryAltViewSender, RecoveryAltViewDiscovery) {
        let sender = RecoveryAltViewSender(), discovery = RecoveryAltViewDiscovery()
        let suite = "AltViewRecoveryTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let service = AltViewService(defaults: defaults, restorePreferences: false, pairingStore: store,
            senderFactory: { _ in sender }, discoveryFactory: { _ in discovery })
        return (service, sender, discovery)
    }

    func testConnectUsesDiscoveredLocalPortInsteadOfCachedSelection() {
        let (service, sender, _) = service(), id = UUID()
        defer { service.disconnect(); service.stopDiscovery() }
        service.startDiscovery()
        let stale = local(id, port: 54321), fresh = local(id, port: 54322)
        service.receiveDiscovered([fresh], notice: nil)
        service.connect(to: stale, code: "ABCD2345")
        XCTAssertEqual(sender.connections.last?.endpoint, fresh.endpoint)
        XCTAssertEqual(sender.connections.last?.receiverID, id)
        XCTAssertEqual(service.destination, fresh)
        XCTAssertEqual(sender.takes, 0)
    }

    func testLocalConnectionWaitsForMatchingReceiverAndSurvivesClosingSettings() {
        let (service, sender, discovery) = service(), id = UUID()
        defer { service.disconnect() }
        service.startDiscovery()
        service.connect(to: local(id, port: 54321), code: "ABCD2345")
        XCTAssertTrue(service.isConnecting)
        XCTAssertTrue(sender.connections.isEmpty)
        service.stopDiscovery()
        XCTAssertEqual(discovery.stops, 0, "A pending This Mac connection keeps discovery alive")
        service.receiveDiscovered([local(UUID(), port: 54322)], notice: nil)
        XCTAssertTrue(sender.connections.isEmpty, "Another local receiver cannot satisfy the saved identity")
        let fresh = local(id, port: 54323)
        service.receiveDiscovered([fresh], notice: nil)
        XCTAssertEqual(sender.connections.last?.endpoint, fresh.endpoint)
        XCTAssertEqual(sender.connections.last?.receiverID, id)
        XCTAssertNil(service.connectionNotice)
        XCTAssertEqual(sender.takes, 0)
        let next = local(id, port: 54324)
        service.receiveDiscovered([next], notice: nil)
        XCTAssertEqual(sender.updatedEndpoints.last, next.endpoint)
    }

    func testStartupRestoreWaitsForDiscoveredPortAndRemainsConnectOnly() throws {
        let suite = "AltViewLocalRestore.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID(), store = RecordingAltViewPairingStore()
        let sender = RecoveryAltViewSender(), discovery = RecoveryAltViewDiscovery()
        defaults.set(try JSONEncoder().encode(local(id, port: 54321)), forKey: "altViewDestination")
        let service = AltViewService(defaults: defaults, pairingStore: store, senderFactory: { _ in sender },
            discoveryFactory: { _ in discovery })
        defer { service.disconnect() }
        service.restoreConnection()
        store.readCompletion?(.init(key: Data("ABCD2345".utf8), receiverID: id), nil)
        XCTAssertEqual(discovery.starts, 1)
        XCTAssertTrue(sender.connections.isEmpty)
        service.receiveDiscovered([local(id, port: 54322)], notice: nil)
        XCTAssertEqual(sender.connections.last?.endpoint, local(id, port: 54322).endpoint)
        service.receive(sender.connectedStatus)
        XCTAssertTrue(sender.submissions.isEmpty)
        XCTAssertEqual(sender.takes, 0)
    }

    func testPortDiscoveredDuringPairingReadIsUsedAndCancelRejectsLateDiscovery() {
        let store = RecordingAltViewPairingStore()
        let (service, sender, _) = service(store: store), id = UUID()
        defer { service.disconnect() }
        service.connect(to: local(id, port: 54321), code: "")
        service.receiveDiscovered([local(id, port: 54322)], notice: nil)
        XCTAssertTrue(sender.connections.isEmpty, "Discovery cannot bypass saved pairing authentication")
        store.readCompletion?(.init(key: Data("ABCD2345".utf8), receiverID: id), nil)
        XCTAssertEqual(sender.connections.last?.endpoint, local(id, port: 54322).endpoint)
        service.disconnect()
        service.connect(to: local(id, port: 54321), code: "")
        let lateRead = store.readCompletion
        service.disconnect()
        lateRead?(.init(key: Data("ABCD2345".utf8), receiverID: id), nil)
        service.receiveDiscovered([local(id, port: 54323)], notice: nil)
        XCTAssertEqual(sender.connections.count, 1)
        XCTAssertFalse(service.hasConnection)
    }

    func testMissingPairingStopsBackgroundDiscoveryAndNextConnectDoesNotUseOldResults() {
        let store = RecordingAltViewPairingStore()
        let (service, sender, discovery) = service(store: store), id = UUID()
        defer { service.disconnect() }
        service.connect(to: local(id, port: 54321), code: "")
        service.receiveDiscovered([local(id, port: 54322)], notice: nil)
        store.readCompletion?(nil, nil)
        XCTAssertFalse(service.hasConnection)
        XCTAssertEqual(discovery.stops, 1)
        XCTAssertTrue(service.receivers.isEmpty)
        service.connect(to: local(id, port: 54321), code: "ABCD2345")
        XCTAssertTrue(sender.connections.isEmpty, "An earlier browse cannot authenticate a current port")
        service.receiveDiscovered([local(id, port: 54323)], notice: nil)
        XCTAssertEqual(sender.connections.last?.endpoint, local(id, port: 54323).endpoint)
    }

    func testControlsDetachKeepsRuntimeHideClearAndStopEvents() async throws {
        let (service, sender, _) = service()
        defer { service.disconnect() }
        service.connect(to: .manual(host: "receiver.local", port: "54321")!, code: "ABCD2345")
        service.receive(sender.connectedStatus)
        let session = PresentationSession()
        service.attach(session)
        session.setSlides(LyricsParser.parseDocument("Verse 1\nPresented lyrics").slides)
        session.isPresenting = true // Keep this lifecycle test independent of a physical display.
        session.showSlides()
        service.detach(session)
        XCTAssertTrue(service.isSending)
        XCTAssertEqual(sender.releases, 0)
        session.hideSlides()
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(try XCTUnwrap(sender.submissions.last).content.visible)
        XCTAssertEqual(sender.submissions.last?.content.confidence?.body, "Presented lyrics")
        session.clearSlides()
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(sender.submissions.last?.content, .empty)
        session.stopPresentation()
        XCTAssertFalse(service.isSending)
        XCTAssertEqual(sender.releases, 1)
        service.detach(session)
        XCTAssertNil(session.onOutputEvent)
    }

    func testDetachedProjectionStopCancelsPublicationQueuedDuringReconnect() {
        let (service, sender, _) = service()
        defer { service.disconnect() }
        service.connect(to: .manual(host: "receiver.local", port: "54321")!, code: "ABCD2345")
        let session = PresentationSession()
        service.attach(session)
        session.setSlides(LyricsParser.parseDocument("Verse 1\nQueued lyrics").slides)
        session.isPresenting = true
        session.showSlides()
        service.detach(session)
        session.stopPresentation()
        service.receive(sender.connectedStatus)
        XCTAssertEqual(sender.takes, 0)
        XCTAssertFalse(service.isSending)
    }

    func testQueuedProjectionKeepsItsExplicitSnapshotThroughAPassiveRefresh() throws {
        let (service, sender, _) = service()
        defer { service.disconnect() }
        service.connect(to: .manual(host: "receiver.local", port: "54321")!, code: "ABCD2345")
        let source = UUID()
        let oversized = try XCTUnwrap(LyricsParser.parseDocument("Verse 1\n" + String(repeating: "界", count: 8_001)).slides.first)
        service.handle(.project(.init(slide: oversized, isPresenting: true, slidesVisible: true)), from: source)
        let explicit = try XCTUnwrap(service.submitted)
        let passive = try XCTUnwrap(LyricsParser.parseDocument("Verse 1\nPassive model refresh").slides.first)
        service.handle(.changed(.init(slide: passive, isPresenting: true, slidesVisible: true)), from: source)
        service.receive(sender.connectedStatus)
        XCTAssertEqual(sender.takeSubmissions.count, 1)
        XCTAssertEqual(sender.takeSubmissions.first?.content, explicit, "The queued action must validate the original explicit content")
        XCTAssertEqual(sender.submissions.last?.content.body, "Passive model refresh", "Transport still keeps the latest snapshot")
        XCTAssertNotEqual(sender.takeSubmissions.first?.id, sender.submissions.last?.id)
    }

    func testNativeProjectionCloseAfterControlsDetachReleasesOutput() async throws {
        let (service, sender, _) = service()
        defer { service.disconnect() }
        service.connect(to: .manual(host: "receiver.local", port: "54321")!, code: "ABCD2345")
        service.receive(sender.connectedStatus)
        let session = PresentationSession()
        service.attach(session)
        session.setSlides(LyricsParser.parseDocument("Verse 1\nPresented").slides)
        session.isPresenting = true
        session.showSlides()
        service.detach(session)
        session.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertFalse(session.isPresenting)
        XCTAssertFalse(service.isSending)
        XCTAssertEqual(sender.releases, 1)
    }

    func testFailedBrowserRestartsAndReadyClearsNotice() throws {
        let queue = DispatchQueue(label: "altview-discovery-recovery-test")
        var browsers: [RecoveryAltViewBrowser] = [] // Access only on queue.
        var notice: String?, deliveries = 0
        let discovery = AltViewReceiverDiscovery(queue: queue, retryDelay: 0.03, browserFactory: {
            let browser = RecoveryAltViewBrowser(); browsers.append(browser); return browser
        }) { _, error in notice = error; deliveries += 1 }
        discovery.start()
        defer { discovery.stop(); queue.sync {} }
        let first = try XCTUnwrap(queue.sync { browsers.first })
        first.emit(.failed(.posix(.ENETDOWN)))
        eventually("failure reaches Settings") { notice != nil }
        eventually("a fresh browser is started automatically") { queue.sync { browsers.count == 2 } }
        XCTAssertTrue(queue.sync { first.cancelled })
        let second = queue.sync { browsers[1] }
        second.emit(.ready)
        eventually("recovery clears the failure notice without requiring results") { notice == nil && deliveries >= 2 }
        second.emit(.waiting(.posix(.ENETDOWN)))
        eventually("waiting notice") { notice?.contains("waiting") == true }
        second.emit(.ready)
        eventually("the same browser can recover from waiting") { notice == nil }
        XCTAssertEqual(queue.sync { browsers.count }, 2)
    }

    func testStopCancelsDiscoveryRetryAndSuppressesQueuedFailure() throws {
        let queue = DispatchQueue(label: "altview-discovery-cancel-test")
        let unwantedRestart = expectation(description: "no browser starts after Stop")
        unwantedRestart.isInverted = true
        var browsers: [RecoveryAltViewBrowser] = []
        var deliveries = 0
        let discovery = AltViewReceiverDiscovery(queue: queue, retryDelay: 0.08, browserFactory: {
            let browser = RecoveryAltViewBrowser(); browsers.append(browser)
            if browsers.count > 1 { unwantedRestart.fulfill() }
            return browser
        }) { _, _ in deliveries += 1 }
        discovery.start()
        let first = try XCTUnwrap(queue.sync { browsers.first })
        first.emit(.failed(.posix(.ENETDOWN)))
        queue.sync {} // The failure delivery is queued on main, which has not yielded yet.
        discovery.stop()
        queue.sync {}
        wait(for: [unwantedRestart], timeout: 0.2)
        XCTAssertEqual(deliveries, 0, "Stop invalidates queued callbacks as well as the retry")
        XCTAssertTrue(queue.sync { first.cancelled })
    }

    func testRestartIgnoresCallbacksAndRetryFromPreviousBrowser() throws {
        let queue = DispatchQueue(label: "altview-discovery-generation-test")
        var browsers: [RecoveryAltViewBrowser] = []
        var notice: String?
        let discovery = AltViewReceiverDiscovery(queue: queue, retryDelay: 0.1, browserFactory: {
            let browser = RecoveryAltViewBrowser(); browsers.append(browser); return browser
        }) { _, error in notice = error }
        discovery.start()
        defer { discovery.stop(); queue.sync {} }
        let first = try XCTUnwrap(queue.sync { browsers.first })
        let staleCallback = queue.sync { first.stateUpdateHandler }
        first.emit(.failed(.posix(.ENETDOWN)))
        queue.sync {}
        discovery.stop()
        discovery.start()
        queue.sync { staleCallback?(.failed(.posix(.ENETDOWN))) }
        let second = queue.sync { browsers[1] }
        second.emit(.ready)
        eventually("new generation is ready") { notice == nil }
        let stable = expectation(description: "only the new browser remains")
        queue.asyncAfter(deadline: .now() + 0.2) { stable.fulfill() }
        wait(for: [stable], timeout: 1)
        XCTAssertEqual(queue.sync { browsers.count }, 2)
        XCTAssertFalse(queue.sync { second.cancelled })
    }
}

nonisolated private final class RecoveryAltViewBrowser: AltViewReceiverBrowsing, @unchecked Sendable {
    var browseResults: Set<NWBrowser.Result> = []
    var stateUpdateHandler: (@Sendable (NWBrowser.State) -> Void)?
    var browseResultsChangedHandler: (@Sendable (Set<NWBrowser.Result>, Set<NWBrowser.Result.Change>) -> Void)?
    private var queue: DispatchQueue!
    var cancelled = false
    func start(queue: DispatchQueue) { self.queue = queue }
    func cancel() { cancelled = true }
    func emit(_ state: NWBrowser.State) { queue.async { [self] in stateUpdateHandler?(state) } }
}

nonisolated private final class RecoveryAltViewDiscovery: AltViewReceiverDiscovering {
    var starts = 0, stops = 0
    func start() { starts += 1 }
    func stop() { stops += 1 }
}

nonisolated private final class RecoveryAltViewSender: AltViewSending {
    struct Connection { let endpoint: NWEndpoint; let receiverID: UUID? }
    var connections: [Connection] = []
    var updatedEndpoints: [NWEndpoint] = []
    var submissions: [AltViewSubmission] = []
    var connectionID: UUID?
    var takes = 0, releases = 0
    var takeSubmissions: [AltViewSubmission] = []
    var connectedStatus: AltViewSenderStatus { .init(connectionID: connectionID, connected: true) }
    func connect(to endpoint: NWEndpoint, key: Data, expectedReceiverID: UUID?, connectionID: UUID) {
        self.connectionID = connectionID; connections.append(.init(endpoint: endpoint, receiverID: expectedReceiverID))
    }
    func updateEndpoint(_ endpoint: NWEndpoint, connectionID: UUID) { updatedEndpoints.append(endpoint) }
    func submit(_ content: AltViewDisplayContent, submissionID: UUID) { submissions.append(.init(id: submissionID, content: content)) }
    func takeOutput(submission: AltViewSubmission?) {
        takes += 1
        if let submission { takeSubmissions.append(submission) }
    }
    func releaseOutput() { releases += 1 }
    func disconnect() { connectionID = nil }
}
