import XCTest
import Network
@testable import eucaly

final class AltViewNetworkTests: XCTestCase {
    private func eventually(_ description: String, timeout: TimeInterval = 10, _ predicate: @escaping () -> Bool) {
        let done = expectation(description: description)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func check() {
            if predicate() { done.fulfill() }
            else if ProcessInfo.processInfo.systemUptime < deadline { DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: check) }
        }
        check()
        wait(for: [done], timeout: timeout + 0.5)
    }

    func testTLSReferenceReceiverOwnershipBlankClearReconnectAndBurst() throws {
        let key = try XCTUnwrap(AltViewPairingKey.parse("ABCD2345"))
        var output = ReferenceAltViewReceiverStatus()
        let server = ReferenceAltViewReceiverServer(receiverID: UUID()) { output = $0 }
        server.start(name: "eucaly protocol test", key: key, advertise: false)
        defer { server.stop() }
        eventually("listener") { output.port != nil }
        let port = try XCTUnwrap(output.port)
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: port)!)
        var aStatus = AltViewSenderStatus(), bStatus = AltViewSenderStatus()
        let a = AltViewSenderClient(name: "eucaly · Test Mac") { aStatus = $0 }
        let b = AltViewSenderClient(name: "Other sender") { bStatus = $0 }
        defer { a.disconnect(); b.disconnect() }
        a.connect(to: endpoint, key: key)
        b.connect(to: endpoint, key: key)
        eventually("connected without taking") { aStatus.connected && bStatus.connected }
        XCTAssertNil(output.ownerID)
        XCTAssertEqual(output.content, .empty)
        let first = AltViewDisplayContent(body: "Primary\nText")
        a.submit(first, submissionID: UUID()); a.takeOutput()
        eventually("first accepted") { output.content == first && aStatus.feedback.accepted }
        XCTAssertEqual(aStatus.feedback.output, .closed)
        server.updateOutputReadiness(.ready)
        eventually("ready feedback") { aStatus.feedback.output == .ready }
        var hidden = first; hidden.visible = false
        a.submit(hidden, submissionID: UUID())
        eventually("hidden") { output.content == hidden }
        a.submit(.empty, submissionID: UUID())
        eventually("clear retains ownership") { output.content == .empty && aStatus.ownsOutput }
        b.submit(.init(body: "Other"), submissionID: UUID()); b.takeOutput()
        eventually("takeover") { bStatus.ownsOutput && !aStatus.ownsOutput }
        a.submit(first, submissionID: UUID()); a.releaseOutput()
        XCTAssertEqual(output.content.body, "Other")
        b.submit(first, submissionID: UUID())
        eventually("restore before outage") { output.content == first }
        server.stop()
        eventually("outage clears owner") { !output.listening && !bStatus.connected }
        let newest = AltViewDisplayContent(body: "Newest while disconnected", visible: false)
        b.submit(newest, submissionID: UUID())
        server.start(name: "eucaly protocol test", key: key, port: port, advertise: false)
        eventually("former owner resumes newest hidden state", timeout: 15) { output.content == newest && bStatus.ownsOutput }
        for index in 0..<2_000 { b.submit(.init(body: "Slide \(index)"), submissionID: UUID()) }
        let finalID = UUID()
        b.submit(.init(body: "Last"), submissionID: finalID)
        eventually("latest burst accepted") { output.content.body == "Last" && bStatus.submissionID == finalID && bStatus.feedback.accepted }
        b.releaseOutput()
        eventually("release") { output.ownerID == nil && output.content == .empty }
    }

    @MainActor
    func testCurrentSlideActivationTakesFromAnotherSenderWithoutManualReconnect() throws {
        let key = Data("ABCD2345".utf8)
        var output = ReferenceAltViewReceiverStatus(), otherStatus = AltViewSenderStatus()
        let server = ReferenceAltViewReceiverServer(receiverID: UUID()) { output = $0 }
        let other = AltViewSenderClient(name: "ViewTheWord") { otherStatus = $0 }
        let name = "AltViewHandoffTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let service = AltViewService(defaults: defaults, restorePreferences: false,
            pairingStore: RecordingAltViewPairingStore(), senderFactory: {
                AltViewSenderClient(name: "eucaly", onStatus: $0)
            })
        let session = PresentationSession(), flow = PresentationFlowController()
        service.attach(session)
        let slides = LyricsParser.parseDocument("Verse 1\nFirst lyrics\n\nChorus\nNext lyrics").slides
        session.setSlides(slides)
        session.isPresenting = true // Suppress physical local projection in tests.
        server.start(name: "Handoff", key: key, advertise: false)
        defer { service.disconnect(); other.disconnect(); server.stop(); defaults.removePersistentDomain(forName: name) }
        eventually("listener") { output.port != nil }
        let port = try XCTUnwrap(output.port)
        service.connect(to: .manual(host: "127.0.0.1", port: String(port))!, code: "ABCD2345")
        other.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), key: key)
        eventually("both connected without output") { service.status.connected && otherStatus.connected }
        XCTAssertNil(output.ownerID)
        session.showSlides(preferredScreen: nil)
        eventually("first lyrics accepted") { output.content.body == "First lyrics" && service.latestAccepted }
        other.submit(.init(body: "Scripture"), submissionID: UUID()); other.takeOutput()
        eventually("other app takes output") { otherStatus.feedback.accepted && service.status.ownerName == "ViewTheWord" }

        flow.selectCurrentSlide(slides[0].id, in: session)
        eventually("same slide activation reclaims output") { output.content.body == "First lyrics" && service.latestAccepted }
        other.submit(.init(body: "Scripture again"), submissionID: UUID()); other.takeOutput()
        eventually("other app takes output again") { otherStatus.feedback.accepted && !service.status.ownsOutput }
        session.moveSelection(1)
        eventually("keyboard projection reclaims output") { output.content.body == "Next lyrics" && service.latestAccepted }
        XCTAssertTrue(otherStatus.connected)
        XCTAssertEqual(output.connections, 2)

        server.dropConnections(named: "eucaly")
        eventually("eucaly reconnecting") { service.status.waitingToRetry }
        other.submit(.init(body: "Scripture during outage"), submissionID: UUID()); other.takeOutput()
        eventually("other app owns during outage") { otherStatus.feedback.accepted }
        flow.selectCurrentSlide(slides[0].id, in: session)
        eventually("projection during reconnect reclaims output", timeout: 15) {
            output.content.body == "First lyrics" && service.latestAccepted
        }
        XCTAssertTrue(service.status.ownsOutput)
        XCTAssertTrue(otherStatus.connected)
        XCTAssertEqual(output.connections, 2)
    }

    func testExplicitTakeSurvivesTransportDropBeforeGrant() throws {
        let key = Data("ABCD2345".utf8)
        var output = ReferenceAltViewReceiverStatus(), aStatus = AltViewSenderStatus(), bStatus = AltViewSenderStatus()
        let server = ReferenceAltViewReceiverServer(receiverID: UUID(), grantDelay: 0.4) { output = $0 }
        let a = AltViewSenderClient(name: "eucaly") { aStatus = $0 }
        let b = AltViewSenderClient(name: "ViewTheWord") { bStatus = $0 }
        server.start(name: "Pending handoff", key: key, advertise: false)
        defer { a.disconnect(); b.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
        a.connect(to: endpoint, key: key); b.connect(to: endpoint, key: key)
        eventually("both connected") { aStatus.connected && bStatus.connected }
        a.submit(.init(body: "Requested lyrics"), submissionID: UUID()); a.takeOutput()
        eventually("take processed before grant") { output.ownerName == "eucaly" }
        XCTAssertFalse(aStatus.ownsOutput)
        server.dropConnections(named: "eucaly")
        eventually("eucaly reconnecting") { aStatus.waitingToRetry }
        b.submit(.init(body: "Scripture"), submissionID: UUID()); b.takeOutput()
        eventually("other app accepted") { bStatus.feedback.accepted }
        eventually("pending explicit take recovers", timeout: 15) {
            output.content.body == "Requested lyrics" && aStatus.feedback.accepted
        }
        XCTAssertTrue(aStatus.ownsOutput)
        XCTAssertTrue(bStatus.connected)
    }

    func testExplicitProjectionSurvivesStaleLeaseUntilOwnershipReportArrives() throws {
        let key = Data("ABCD2345".utf8)
        var output = ReferenceAltViewReceiverStatus(), aStatus = AltViewSenderStatus(), bStatus = AltViewSenderStatus()
        let server = ReferenceAltViewReceiverServer(receiverID: UUID()) { output = $0 }
        let a = AltViewSenderClient(name: "eucaly") { aStatus = $0 }
        let b = AltViewSenderClient(name: "ViewTheWord") { bStatus = $0 }
        server.start(name: "Stale lease", key: key, advertise: false)
        defer { a.disconnect(); b.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
        a.connect(to: endpoint, key: key); b.connect(to: endpoint, key: key)
        eventually("both connected") { aStatus.connected && bStatus.connected }
        a.submit(.init(body: "First lyrics"), submissionID: UUID()); a.takeOutput()
        eventually("first snapshot accepted") { aStatus.feedback.accepted }
        server.setOwnershipReportsSuspended(true, for: "eucaly")
        b.submit(.init(body: "Scripture"), submissionID: UUID()); b.takeOutput()
        eventually("other app owns") { bStatus.feedback.accepted && output.content.body == "Scripture" }
        XCTAssertTrue(aStatus.ownsOutput, "The sender still has the revoked lease")
        a.submit(.init(body: "Explicit lyrics"), submissionID: UUID()); a.takeOutput()
        eventually("snapshot rejected under stale lease") { output.rejectedSnapshots > 0 }
        XCTAssertEqual(output.content.body, "Scripture")
        a.submit(.init(body: "Newest lyrics", visible: false), submissionID: UUID())
        eventually("newest snapshot also uses stale lease") { output.rejectedSnapshots > 1 }
        server.setOwnershipReportsSuspended(false, for: "eucaly")
        eventually("explicit request reclaims after revocation") { output.content.body == "Newest lyrics" && aStatus.feedback.accepted }
        XCTAssertFalse(output.content.visible)
        XCTAssertTrue(bStatus.connected)
        XCTAssertEqual(output.connections, 2)
        b.submit(.init(body: "Later scripture"), submissionID: UUID()); b.takeOutput()
        eventually("later explicit projection wins") { bStatus.feedback.accepted && !aStatus.ownsOutput }
        a.submit(.init(body: "Background refresh"), submissionID: UUID())
        let unchanged = expectation(description: "background update does not reclaim settled output")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { unchanged.fulfill() }
        wait(for: [unchanged], timeout: 1)
        XCTAssertEqual(output.content.body, "Later scripture")
        XCTAssertFalse(aStatus.ownsOutput)
    }

    func testReleaseCancelsUnchangedSlideTakeWaitingForStaleLeaseRevocation() throws {
        let key = Data("ABCD2345".utf8)
        var output = ReferenceAltViewReceiverStatus(), aStatus = AltViewSenderStatus(), bStatus = AltViewSenderStatus()
        let server = ReferenceAltViewReceiverServer(receiverID: UUID()) { output = $0 }
        let a = AltViewSenderClient(name: "A") { aStatus = $0 }
        let b = AltViewSenderClient(name: "B") { bStatus = $0 }
        server.start(name: "Stale lease cancellation", key: key, advertise: false)
        defer { a.disconnect(); b.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
        a.connect(to: endpoint, key: key); b.connect(to: endpoint, key: key)
        a.submit(.init(body: "Same slide"), submissionID: UUID()); a.takeOutput()
        eventually("first accepted") { aStatus.feedback.accepted && bStatus.connected }
        server.setOwnershipReportsSuspended(true, for: "A")
        b.submit(.init(body: "Other app"), submissionID: UUID()); b.takeOutput()
        eventually("other app owns") { bStatus.feedback.accepted && output.content.body == "Other app" }
        // No new submission: reactivating the accepted slide still needs a fresh
        // revision, since its previous acceptance predates this explicit action.
        a.takeOutput()
        eventually("unchanged slide sent under revoked lease") { output.rejectedSnapshots > 0 }
        a.releaseOutput()
        eventually("released pending intent") { !aStatus.ownsOutput && !aStatus.followingOutput }
        server.setOwnershipReportsSuspended(false, for: "A")
        eventually("revocation processed") { aStatus.ownerName == "B" }
        let unchanged = expectation(description: "release prevents delayed takeover")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { unchanged.fulfill() }
        wait(for: [unchanged], timeout: 1)
        XCTAssertEqual(output.content.body, "Other app")
        XCTAssertTrue(bStatus.ownsOutput)
        XCTAssertFalse(aStatus.ownsOutput)
    }

    func testTemplateDiscoveryUpdatesArePrivateAndReconnectionUsesNewCatalogue() throws {
        let key = Data("ABCD2345".utf8)
        let catalogue = AltViewTemplateCapabilities(templates: [.init(id: .lyrics, name: "Lyrics")], policy: .sender)
        var output = ReferenceAltViewReceiverStatus(), status = AltViewSenderStatus()
        let server = ReferenceAltViewReceiverServer(receiverID: UUID(), templateCapabilities: catalogue) { output = $0 }
        let sender = AltViewSenderClient(name: "Template discovery") { status = $0 }
        server.start(name: "Templates", key: key, advertise: false)
        defer { sender.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        let port = try XCTUnwrap(output.port)
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), key: key)
        eventually("welcome discovery") { status.connected && status.templateCapabilities == catalogue }
        XCTAssertNil(output.ownerID)
        XCTAssertEqual(output.revision, 0)
        let desired = AltViewDisplayContent(body: "Primary", template: .lyrics)
        sender.submit(desired, submissionID: UUID()); sender.takeOutput()
        eventually("supported request") { output.content == desired && status.feedback.accepted }
        let revision = output.revision
        let override = AltViewTemplateCapabilities(templates: catalogue.templates, policy: .custom)
        server.updateTemplateCapabilities(override)
        eventually("policy feedback") { status.templateCapabilities == override }
        XCTAssertEqual(output.revision, revision)
        XCTAssertEqual(status.feedback.sentRevision, revision)
        XCTAssertEqual(output.content.template, .lyrics, "Policy must not rewrite the request")
        server.updateTemplateCapabilities(.init(templates: [], policy: .sender))
        eventually("empty catalogue") { status.templateCapabilities.templates == [] }
        XCTAssertEqual(status.feedback.sentRevision, revision)
        var hidden = desired; hidden.visible = false
        sender.submit(hidden, submissionID: UUID())
        eventually("blank uses latest catalogue") { !output.content.visible && output.content.template == nil && output.revision > revision }
        server.stop()
        eventually("disconnect clears discovery") { !status.connected && status.templateCapabilities.templates == nil }
        server.updateTemplateCapabilities(catalogue)
        server.start(name: "Templates", key: key, port: port, advertise: false)
        eventually("resume restores retained request using new welcome", timeout: 15) { output.content == hidden && status.ownsOutput }
        server.updateTemplateCapabilities(.init())
        eventually("legacy feedback clears capabilities") { status.connected && status.templateCapabilities.templates == nil }
        sender.submit(desired, submissionID: UUID())
        eventually("legacy receiver gets generic text") { output.content.visible && output.content.body == desired.body && output.content.template == nil }
    }

    func testMalformedTemplateCatalogueAndPolicyCloseConnection() throws {
        let key = Data("ABCD2345".utf8)
        for malformedWelcome in [true, false] {
            var output = ReferenceAltViewReceiverStatus(), status = AltViewSenderStatus()
            let invalid = AltViewTemplateCapabilities(templates: [.init(id: .lyrics, name: "Lyrics")], policy: .fixed(.scripture))
            let server = ReferenceAltViewReceiverServer(receiverID: UUID(), templateCapabilities: malformedWelcome ? invalid : .init()) { output = $0 }
            let sender = AltViewSenderClient(name: "Invalid discovery") { status = $0 }
            server.start(name: "Invalid discovery", key: key, advertise: false)
            defer { sender.disconnect(); server.stop() }
            eventually("listener") { output.port != nil }
            sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!), key: key)
            if !malformedWelcome {
                eventually("connected") { status.connected }
                server.updateTemplateCapabilities(.init(templates: [.init(id: .lyrics, name: "One"), .init(id: .lyrics, name: "Duplicate")]))
            }
            eventually("invalid discovery rejected") { status.failureReason?.contains("template catalogue") == true }
            XCTAssertFalse(status.connected)
            XCTAssertFalse(status.waitingToRetry)
            XCTAssertNil(status.templateCapabilities.templates)
            XCTAssertNil(output.ownerID)
        }
    }

    func testOversizedAndEscapedSnapshotsClearOldTextWithoutDisconnecting() throws {
        let key = try XCTUnwrap(AltViewPairingKey.parse("ABCD2345"))
        var output = ReferenceAltViewReceiverStatus(), status = AltViewSenderStatus()
        let server = ReferenceAltViewReceiverServer(receiverID: UUID()) { output = $0 }
        let sender = AltViewSenderClient(name: "Bounds") { status = $0 }
        server.start(name: "Bounds", key: key, advertise: false)
        defer { sender.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!), key: key)
        eventually("connected") { status.connected }
        for body in [String(repeating: "界", count: 8_001), String(repeating: "\u{1}", count: 24_000)] {
            sender.submit(.init(body: "Old"), submissionID: UUID()); sender.takeOutput()
            eventually("old text") { output.content.body == "Old" }
            sender.submit(.init(body: body), submissionID: UUID())
            eventually("invalid clears") { output.content == .empty && status.contentError != nil }
            XCTAssertTrue(status.connected)
            XCTAssertTrue(status.ownsOutput)
        }
        sender.submit(.init(body: "Recovered"), submissionID: UUID())
        eventually("valid text recovers") { output.content.body == "Recovered" && status.contentError == nil }
    }

    func testWrongCodeAndPinnedIdentityCannotPublish() throws {
        let key = try XCTUnwrap(AltViewPairingKey.parse("ABCD2345"))
        var output = ReferenceAltViewReceiverStatus(), status = AltViewSenderStatus()
        let server = ReferenceAltViewReceiverServer(receiverID: UUID()) { output = $0 }
        let sender = AltViewSenderClient(name: "Authentication") { status = $0 }
        server.start(name: "Authentication", key: key, advertise: false)
        defer { sender.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
        sender.connect(to: endpoint, key: Data("ABCD2346".utf8))
        eventually("wrong key rejected") { status.failureReason != nil }
        XCTAssertFalse(status.connected)
        XCTAssertFalse(status.waitingToRetry)
        let id = UUID()
        sender.connect(to: endpoint, key: key, expectedReceiverID: UUID(), connectionID: id)
        eventually("wrong identity rejected") { status.connectionID == id && status.message.contains("identity changed") }
        XCTAssertFalse(status.connected)
        XCTAssertFalse(status.waitingToRetry)
        XCTAssertNil(output.ownerID)
    }

    func testDestinationChangeCannotSendNewSnapshotThroughQueuedOldDrain() throws {
        let key = Data("ABCD2345".utf8)
        let senderQueue = DispatchQueue(label: "altview-destination-change-test")
        let allowConnectionChange = DispatchSemaphore(value: 0)
        let oldDrainCompleted = expectation(description: "old mailbox drain completed")
        let noLeakedText = expectation(description: "new destination text stays off old receiver")
        noLeakedText.isInverted = true
        let newContent = AltViewDisplayContent(body: "New receiver private slide")
        var oldOutput = ReferenceAltViewReceiverStatus(), newOutput = ReferenceAltViewReceiverStatus()
        var status = AltViewSenderStatus()
        let old = ReferenceAltViewReceiverServer(receiverID: UUID()) {
            oldOutput = $0
            if $0.content == newContent { noLeakedText.fulfill() }
        }
        let new = ReferenceAltViewReceiverServer(receiverID: UUID()) { newOutput = $0 }
        let sender = AltViewSenderClient(name: "Destination change", senderQueue: senderQueue) { status = $0 }
        old.start(name: "Old", key: key, advertise: false)
        new.start(name: "New", key: key, advertise: false)
        defer { allowConnectionChange.signal(); sender.disconnect(); old.stop(); new.stop() }
        eventually("two listeners") { oldOutput.port != nil && newOutput.port != nil }
        let oldEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(oldOutput.port))!)
        let newEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(newOutput.port))!)
        sender.connect(to: oldEndpoint, key: key)
        eventually("old connected") { status.connected }
        sender.submit(.init(body: "Old receiver slide"), submissionID: UUID()); sender.takeOutput()
        eventually("old accepted") { status.feedback.accepted }

        senderQueue.suspend()
        sender.submit(.init(body: "Old pending slide"), submissionID: UUID())
        // Give the old drain a chance to reach the socket before connect runs.
        senderQueue.async {
            oldDrainCompleted.fulfill()
            _ = allowConnectionChange.wait(timeout: .now() + 3)
        }
        sender.disconnect()
        let connectionID = UUID(), submissionID = UUID()
        sender.connect(to: newEndpoint, key: key, connectionID: connectionID)
        sender.submit(newContent, submissionID: submissionID)
        senderQueue.resume()
        wait(for: [oldDrainCompleted], timeout: 2)
        wait(for: [noLeakedText], timeout: 0.25)
        allowConnectionChange.signal()
        eventually("new connected without taking") { status.connected && status.connectionID == connectionID }
        XCTAssertNil(newOutput.ownerID)
        XCTAssertEqual(newOutput.content, .empty)
        sender.takeOutput()
        eventually("new mailbox retains its snapshot") {
            newOutput.content == newContent && status.submissionID == submissionID && status.feedback.accepted
        }
        XCTAssertNotEqual(oldOutput.content, newContent)
    }

    func testIdleDisconnectBeforeResumeGrantRestoresLatestHiddenSnapshot() throws {
        let key = Data("ABCD2345".utf8)
        var output = ReferenceAltViewReceiverStatus(), aStatus = AltViewSenderStatus(), bStatus = AltViewSenderStatus()
        let server = ReferenceAltViewReceiverServer(receiverID: UUID()) { output = $0 }
        let a = AltViewSenderClient(name: "A") { aStatus = $0 }
        let b = AltViewSenderClient(name: "B") { bStatus = $0 }
        server.start(name: "Resume race", key: key, advertise: false)
        defer { a.disconnect(); b.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
        a.connect(to: endpoint, key: key); b.connect(to: endpoint, key: key)
        eventually("both connected") { aStatus.connected && bStatus.connected }
        a.submit(.init(body: "First"), submissionID: UUID()); a.takeOutput()
        eventually("owner accepted") { aStatus.feedback.accepted }
        server.setResumesSuspended(true)
        server.dropConnections(named: "A")
        eventually("resume pending") { output.pendingResumes == 1 && aStatus.connected }
        let newest = AltViewDisplayContent(body: "Newest while reconnecting", visible: false)
        let submissionID = UUID()
        a.submit(newest, submissionID: submissionID)
        b.disconnect()
        eventually("idle disconnect broadcast received") {
            output.connections == 1 && aStatus.ownerName == nil && aStatus.message == "Connected — output is clear"
        }
        server.setResumesSuspended(false)
        eventually("resume restores latest hidden state") {
            output.content == newest && aStatus.ownsOutput && aStatus.submissionID == submissionID && aStatus.feedback.accepted
        }
        XCTAssertTrue(aStatus.connected)
        XCTAssertNil(aStatus.failureReason)
    }

    func testRefusedResumeDoesNotTakeAutomaticallyAndStillAllowsExplicitTake() throws {
        let key = Data("ABCD2345".utf8)
        var output = ReferenceAltViewReceiverStatus(), aStatus = AltViewSenderStatus(), bStatus = AltViewSenderStatus()
        let server = ReferenceAltViewReceiverServer(receiverID: UUID()) { output = $0 }
        let a = AltViewSenderClient(name: "A") { aStatus = $0 }
        let b = AltViewSenderClient(name: "B") { bStatus = $0 }
        server.start(name: "Refused resume", key: key, advertise: false)
        defer { a.disconnect(); b.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
        a.connect(to: endpoint, key: key); b.connect(to: endpoint, key: key)
        eventually("both connected") { aStatus.connected && bStatus.connected }
        a.submit(.init(body: "A first"), submissionID: UUID()); a.takeOutput()
        eventually("A owns output") { aStatus.feedback.accepted }
        server.setResumesSuspended(true)
        server.dropConnections(named: "A")
        eventually("resume pending") { output.pendingResumes == 1 && aStatus.connected }
        b.submit(.init(body: "B"), submissionID: UUID()); b.takeOutput()
        eventually("B takes output") { bStatus.feedback.accepted && aStatus.ownerName == "B" }
        server.setResumesSuspended(false)
        eventually("resume refused") { output.pendingResumes == 0 }
        a.submit(.init(body: "Automatic navigation"), submissionID: UUID())
        let unchanged = expectation(description: "ordinary navigation does not take output")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { unchanged.fulfill() }
        wait(for: [unchanged], timeout: 1)
        XCTAssertEqual(output.content.body, "B")
        XCTAssertTrue(bStatus.ownsOutput)
        a.submit(.init(body: "Explicit show"), submissionID: UUID()); a.takeOutput()
        eventually("explicit take after refused resume") {
            output.content.body == "Explicit show" && aStatus.ownsOutput && aStatus.feedback.accepted
        }
        XCTAssertNil(aStatus.failureReason)
    }

    func testTransientDisconnectBeforeWelcomeRetriesWithoutTakingOutput() throws {
        let key = Data("ABCD2345".utf8)
        var output = ReferenceAltViewReceiverStatus(), status = AltViewSenderStatus()
        var retried = false
        let server = ReferenceAltViewReceiverServer(receiverID: UUID(), handshakeDisconnects: 1) { output = $0 }
        let sender = AltViewSenderClient(name: "Setup recovery") {
            status = $0
            retried = retried || $0.waitingToRetry
        }
        server.start(name: "Setup recovery", key: key, advertise: false)
        defer { sender.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!), key: key)
        eventually("transient handshake close recovers") { status.connected }
        XCTAssertTrue(retried)
        XCTAssertNil(status.failureReason)
        XCTAssertNil(output.ownerID)
        XCTAssertEqual(output.content, .empty)
        sender.submit(.init(body: "After recovery"), submissionID: UUID()); sender.takeOutput()
        eventually("recovered connection can publish") { output.content.body == "After recovery" && status.feedback.accepted }
    }

    func testStopDuringTakeReleasesLateGrantWithoutPublishing() throws {
        let key = Data("ABCD2345".utf8)
        let queue = DispatchQueue(label: "late-altview-grant")
        let listener = try NWListener(using: AltViewSecureConnection.parameters(key: key), on: .any)
        let ready = expectation(description: "listener ready")
        let take = expectation(description: "take arrived")
        let released = expectation(description: "late grant released")
        let noState = expectation(description: "no text after stop")
        noState.isInverted = true
        var peer: AltViewPeerChannel?
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.newConnectionHandler = { connection in
            let channel = AltViewPeerChannel(connection: connection, queue: queue)
            peer = channel
            channel.onMessage = { [weak channel] message in
                switch message.kind {
                case .hello: channel?.send(.init(kind: .welcome, receiverID: UUID()))
                case .take:
                    take.fulfill()
                    queue.asyncAfter(deadline: .now() + 0.2) { channel?.send(.init(kind: .granted, lease: UUID())) }
                case .release: released.fulfill()
                case .state: noState.fulfill()
                default: break
                }
            }
            channel.start()
        }
        listener.start(queue: queue)
        defer { queue.sync { peer?.close(nil); listener.cancel() } }
        wait(for: [ready], timeout: 3)
        var status = AltViewSenderStatus()
        let sender = AltViewSenderClient(name: "Late grant") { status = $0 }
        defer { sender.disconnect() }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: try XCTUnwrap(listener.port)), key: key)
        eventually("sender connected") { status.connected }
        sender.submit(.init(body: "Must not return"), submissionID: UUID())
        sender.takeOutput()
        wait(for: [take], timeout: 3)
        sender.releaseOutput()
        wait(for: [released, noState], timeout: 0.7)
        XCTAssertFalse(status.ownsOutput)
        XCTAssertTrue(status.connected)
    }
}
