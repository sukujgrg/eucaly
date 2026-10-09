import Network
import XCTest
@testable import eucaly

@MainActor
final class AltViewContentBoundsTests: XCTestCase {
    private func eventually(_ description: String, timeout: TimeInterval = 10, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), description)
    }

    func testRejectedQueuedContentDoesNotTakeOtherOutputAndRequiresANewExplicitAction() throws {
        let key = Data("ABCD2345".utf8)
        let escaped = String(repeating: "\u{1}", count: 6_000)
        let rejected = [
            AltViewDisplayContent(body: String(repeating: "界", count: 8_001)),
            AltViewDisplayContent(body: escaped, confidence: .init(body: escaped))
        ]
        for content in rejected {
            let senderID = UUID(), senderQueue = DispatchQueue(label: "altview-queued-bounds-test")
            var output = ReferenceAltViewReceiverStatus(), otherStatus = AltViewSenderStatus(), status = AltViewSenderStatus()
            var checkingRejection = true
            let noTake = expectation(description: "rejected content never takes output")
            noTake.isInverted = true
            let server = ReferenceAltViewReceiverServer(receiverID: UUID(), capabilities: AltViewProtocol.capabilities) {
                output = $0
                if checkingRejection && $0.ownerID == senderID { noTake.fulfill() }
            }
            let other = AltViewSenderClient(name: "ViewTheWord") { otherStatus = $0 }
            let sender = AltViewSenderClient(name: "eucaly", senderID: senderID, senderQueue: senderQueue) { status = $0 }
            server.start(name: "Queued content bounds", key: key, advertise: false)
            defer { sender.disconnect(); other.disconnect(); server.stop() }
            eventually("listener") { output.port != nil }
            let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
            other.connect(to: endpoint, key: key)
            other.submit(.init(body: "Presented Scripture"), submissionID: UUID()); other.takeOutput()
            eventually("other sender owns output") { otherStatus.feedback.accepted }

            // Queue all three operations before the transport can deliver welcome.
            senderQueue.suspend()
            sender.connect(to: endpoint, key: key)
            sender.submit(content, submissionID: UUID()); sender.takeOutput()
            senderQueue.resume()
            eventually("rejection after negotiated welcome") { status.connected && status.contentError != nil }
            XCTAssertFalse(status.ownsOutput)
            XCTAssertFalse(status.followingOutput)
            sender.submit(.init(body: "Valid next lyrics"), submissionID: UUID())
            eventually("valid update clears the notice") { status.contentError == nil }
            wait(for: [noTake], timeout: 0.15)
            XCTAssertEqual(output.ownerID, other.senderID)
            XCTAssertEqual(output.content.body, "Presented Scripture")
            checkingRejection = false
            sender.takeOutput()
            eventually("a new explicit action can take valid content") { output.content.body == "Valid next lyrics" && status.feedback.accepted }
        }
    }

    func testRejectedContentWithARevokedCachedLeaseCannotReclaimAnotherSender() throws {
        let key = Data("ABCD2345".utf8)
        var output = ReferenceAltViewReceiverStatus(), status = AltViewSenderStatus(), otherStatus = AltViewSenderStatus()
        let server = ReferenceAltViewReceiverServer(receiverID: UUID()) { output = $0 }
        let sender = AltViewSenderClient(name: "eucaly") { status = $0 }
        let other = AltViewSenderClient(name: "ViewTheWord") { otherStatus = $0 }
        server.start(name: "Rejected stale lease", key: key, advertise: false)
        defer { sender.disconnect(); other.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
        sender.connect(to: endpoint, key: key); other.connect(to: endpoint, key: key)
        sender.submit(.init(body: "First lyrics"), submissionID: UUID()); sender.takeOutput()
        eventually("first presentation") { status.feedback.accepted && otherStatus.connected }
        server.setOwnershipReportsSuspended(true, for: "eucaly")
        other.submit(.init(body: "Scripture"), submissionID: UUID()); other.takeOutput()
        eventually("other sender takes output") { otherStatus.feedback.accepted && output.content.body == "Scripture" }
        XCTAssertTrue(status.ownsOutput, "The sender still has a revoked cached lease")
        sender.submit(.init(body: String(repeating: "界", count: 8_001)), submissionID: UUID()); sender.takeOutput()
        eventually("invalid update processed under stale lease") { status.contentError != nil && output.rejectedSnapshots > 0 }
        server.setOwnershipReportsSuspended(false, for: "eucaly")
        eventually("revocation processed without a take") { !status.ownsOutput && status.ownerName == "ViewTheWord" }
        sender.submit(.init(body: "Valid background update"), submissionID: UUID())
        eventually("valid update clears rejection") { status.contentError == nil }
        let settled = expectation(description: "revocation and background update settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { settled.fulfill() }
        wait(for: [settled], timeout: 1)
        XCTAssertEqual(output.ownerID, other.senderID)
        XCTAssertEqual(output.content.body, "Scripture")
        sender.takeOutput()
        eventually("new explicit valid presentation") { output.content.body == "Valid background update" && status.feedback.accepted }
    }

    func testRejectedExplicitContentCannotBeReplacedByAPassiveMailboxUpdate() throws {
        let key = Data("ABCD2345".utf8)
        var output = ReferenceAltViewReceiverStatus(), status = AltViewSenderStatus(), otherStatus = AltViewSenderStatus()
        let senderID = UUID(), senderQueue = DispatchQueue(label: "altview-coalesced-bounds-test")
        var checkingRejection = true
        let noTake = expectation(description: "a passive update cannot validate a rejected explicit action")
        noTake.isInverted = true
        let server = ReferenceAltViewReceiverServer(receiverID: UUID(), capabilities: AltViewProtocol.capabilities) {
            output = $0
            if checkingRejection && $0.ownerID == senderID { noTake.fulfill() }
        }
        let sender = AltViewSenderClient(name: "eucaly", senderID: senderID, senderQueue: senderQueue) { status = $0 }
        let other = AltViewSenderClient(name: "ViewTheWord") { otherStatus = $0 }
        server.start(name: "Coalesced content bounds", key: key, advertise: false)
        defer { sender.disconnect(); other.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
        sender.connect(to: endpoint, key: key); other.connect(to: endpoint, key: key)
        other.submit(.init(body: "Presented Scripture"), submissionID: UUID()); other.takeOutput()
        eventually("other sender owns output") { otherStatus.feedback.accepted && status.connected }

        // Model a busy sender queue: the mailbox replaces the explicit snapshot
        // before its drain runs, but the operator action still refers to that snapshot.
        senderQueue.suspend()
        sender.submit(.init(body: String(repeating: "界", count: 8_001)), submissionID: UUID())
        sender.takeOutput()
        sender.submit(.init(body: "Passive model refresh"), submissionID: UUID())
        senderQueue.resume()
        wait(for: [noTake], timeout: 0.3)
        XCTAssertEqual(output.ownerID, other.senderID)
        XCTAssertEqual(output.content.body, "Presented Scripture")
        XCTAssertFalse(status.followingOutput)
        checkingRejection = false
        sender.takeOutput()
        eventually("a fresh explicit action validates the latest snapshot") {
            output.content.body == "Passive model refresh" && status.feedback.accepted
        }
    }

    func testCoalescedExplicitContentIsRevalidatedAfterWelcomeNegotiatesConfidence() throws {
        let key = Data("ABCD2345".utf8)
        var output = ReferenceAltViewReceiverStatus(), status = AltViewSenderStatus(), otherStatus = AltViewSenderStatus()
        let senderID = UUID(), senderQueue = DispatchQueue(label: "altview-coalesced-negotiation-test")
        let noTake = expectation(description: "negotiation rejects the original explicit action")
        noTake.isInverted = true
        let server = ReferenceAltViewReceiverServer(receiverID: UUID(), capabilities: AltViewProtocol.capabilities) {
            output = $0
            if $0.ownerID == senderID { noTake.fulfill() }
        }
        let sender = AltViewSenderClient(name: "eucaly", senderID: senderID, senderQueue: senderQueue) { status = $0 }
        let other = AltViewSenderClient(name: "ViewTheWord") { otherStatus = $0 }
        server.start(name: "Coalesced negotiated bounds", key: key, advertise: false)
        defer { sender.disconnect(); other.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!)
        other.connect(to: endpoint, key: key)
        other.submit(.init(body: "Presented Scripture"), submissionID: UUID()); other.takeOutput()
        eventually("other sender owns output") { otherStatus.feedback.accepted }

        let escaped = String(repeating: "\u{1}", count: 6_000)
        senderQueue.suspend()
        sender.connect(to: endpoint, key: key)
        sender.submit(.init(body: escaped, confidence: .init(body: escaped)), submissionID: UUID())
        sender.takeOutput()
        sender.submit(.init(body: "Passive model refresh"), submissionID: UUID())
        senderQueue.resume()
        eventually("welcome negotiated") { status.connected && status.capabilities.contains(AltViewProtocol.confidenceText) }
        wait(for: [noTake], timeout: 0.3)
        XCTAssertEqual(output.ownerID, other.senderID)
        XCTAssertEqual(output.content.body, "Presented Scripture")
        XCTAssertFalse(status.followingOutput)
        XCTAssertNil(status.contentError, "The latest passive content itself is valid")
    }

    func testRejectedSubmissionReleasesAnInFlightGrantWithoutPublishing() throws {
        let key = Data("ABCD2345".utf8)
        var output = ReferenceAltViewReceiverStatus(), status = AltViewSenderStatus()
        let server = ReferenceAltViewReceiverServer(receiverID: UUID(), grantDelay: 0.3) { output = $0 }
        let sender = AltViewSenderClient(name: "eucaly") { status = $0 }
        server.start(name: "Rejected late grant", key: key, advertise: false)
        defer { sender.disconnect(); server.stop() }
        eventually("listener") { output.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!), key: key)
        eventually("connected") { status.connected }
        sender.submit(.init(body: "Valid queued lyrics"), submissionID: UUID()); sender.takeOutput()
        eventually("take is in flight") { output.ownerID == sender.senderID }
        XCTAssertFalse(status.ownsOutput)
        sender.submit(.init(body: String(repeating: "界", count: 8_001)), submissionID: UUID())
        eventually("pending take cancelled") { status.contentError != nil && !status.followingOutput }
        eventually("late grant released") { output.ownerID == nil }
        XCTAssertEqual(output.content, .empty)
        XCTAssertEqual(output.revision, 0)
        XCTAssertFalse(status.ownsOutput)
        XCTAssertTrue(status.connected)
    }

    func testNegotiatedRejectionRetainsDesiredTextForLegacyReconnect() throws {
        let key = Data("ABCD2345".utf8), receiverID = UUID()
        var modernOutput = ReferenceAltViewReceiverStatus(), legacyOutput = ReferenceAltViewReceiverStatus()
        var status = AltViewSenderStatus()
        let modern = ReferenceAltViewReceiverServer(receiverID: receiverID, capabilities: AltViewProtocol.capabilities) { modernOutput = $0 }
        let legacy = ReferenceAltViewReceiverServer(receiverID: receiverID) { legacyOutput = $0 }
        let sender = AltViewSenderClient(name: "eucaly bounds reconnect") { status = $0 }
        modern.start(name: "Negotiated bounds", key: key, advertise: false)
        defer { sender.disconnect(); modern.stop(); legacy.stop() }
        eventually("modern listener") { modernOutput.port != nil }
        let port = try XCTUnwrap(modernOutput.port)
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), key: key)
        sender.submit(.init(body: "Old text"), submissionID: UUID()); sender.takeOutput()
        eventually("our own output") { status.feedback.accepted }
        let escaped = String(repeating: "\u{1}", count: 6_000), submissionID = UUID()
        sender.submit(.init(body: escaped, confidence: .init(body: escaped)), submissionID: submissionID)
        eventually("our oversize negotiated text clears safely") {
            modernOutput.content == .empty && status.contentError != nil && status.feedback.accepted
        }
        modern.stop()
        eventually("transport drops") { !status.connected }
        legacy.start(name: "Legacy bounds", key: key, port: port, advertise: false)
        eventually("legacy negotiation recovers original text", timeout: 15) {
            legacyOutput.content.body == escaped && status.feedback.accepted && status.submissionID == submissionID
        }
        XCTAssertNil(status.contentError)
        XCTAssertNil(legacyOutput.content.confidence)
        XCTAssertTrue(status.ownsOutput)
    }

    func testOversizedHiddenNavigationRetainsConfidenceAndMediaIdentityThroughReconnect() throws {
        let key = Data("ABCD2345".utf8)
        for media in [false, true] {
            var output = ReferenceAltViewReceiverStatus()
            let server = ReferenceAltViewReceiverServer(receiverID: UUID(), capabilities: AltViewProtocol.capabilities) { output = $0 }
            let suite = "AltViewHiddenBounds.\(UUID())", defaults = UserDefaults(suiteName: suite)!
            let service = AltViewService(defaults: defaults, restorePreferences: false,
                pairingStore: RecordingAltViewPairingStore(), senderFactory: {
                    AltViewSenderClient(name: "eucaly hidden bounds", onStatus: $0)
                })
            server.start(name: "Hidden content bounds", key: key, advertise: false)
            defer { service.disconnect(); server.stop(); defaults.removePersistentDomain(forName: suite) }
            eventually("listener") { output.port != nil }
            service.connect(to: .manual(host: "127.0.0.1", port: String(try XCTUnwrap(output.port)))!, code: "ABCD2345")
            eventually("connected") { service.status.connected }
            let source = UUID(), generation = UUID()
            let presented = media
                ? Slide(index: 1, lines: [], label: nil, videoURL: URL(fileURLWithPath: "/tmp/video"), pdfURL: nil, pdfPageIndex: nil, imageURL: nil)
                : try XCTUnwrap(LyricsParser.parseDocument("Verse 1\nPresented lyrics").slides.first)
            service.handle(.project(.init(slide: presented, isPresenting: true, slidesVisible: true,
                projectionWindowID: 77, projectionWindowGeneration: generation)), from: source)
            eventually("explicit presentation accepted") { service.latestAccepted }
            let report = try XCTUnwrap(output.content.projection), confidence = output.content.confidence
            for body in [String(repeating: "界", count: 8_001), String(repeating: "\u{1}", count: 24_000)] {
                let priorSubmission = service.status.submissionID
                let hidden = try XCTUnwrap(LyricsParser.parseDocument("Verse 1\n" + body).slides.first)
                service.handle(.changed(.init(slide: hidden, isPresenting: true, slidesVisible: false,
                    projectionWindowID: 77, projectionWindowGeneration: generation)), from: source)
                eventually("safe hidden fallback acknowledged") {
                    service.status.contentError != nil && service.status.feedback.accepted && service.status.submissionID != priorSubmission
                }
                XCTAssertEqual(output.content.projection, report)
                XCTAssertEqual(output.content.confidence, confidence)
                XCTAssertEqual(output.content.body, "")
                XCTAssertFalse(output.content.visible)
                XCTAssertTrue(service.status.ownsOutput)
            }
            server.dropConnections(named: "eucaly hidden bounds")
            eventually("transport drops") { !service.status.connected }
            eventually("former owner resumes retained Confidence", timeout: 15) {
                service.status.ownsOutput && service.status.feedback.accepted && output.content.projection == report
            }
            XCTAssertEqual(output.content.confidence, confidence)
            service.handle(.changed(.init(slide: nil, isPresenting: true, slidesVisible: false)), from: source)
            eventually("explicit Clear removes retained presentation") { output.content == .empty && service.latestAccepted }
        }
    }
}
