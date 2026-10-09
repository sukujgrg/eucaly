import AppKit
import Network
import XCTest
@testable import eucaly

@MainActor
final class AltViewConfidenceTests: XCTestCase {
    private func service() -> (AltViewService, RecordingAltViewSender) {
        let suite = "Confidence.\(UUID())", sender = RecordingAltViewSender()
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let service = AltViewService(defaults: defaults, restorePreferences: false, senderFactory: { _ in sender })
        service.connect(to: .manual(host: "127.0.0.1", port: "54321")!, code: "ABCD2345")
        service.receive(sender.connectedStatus)
        return (service, sender)
    }
    private func snapshot(_ text: String, visible: Bool = true) -> PresentationOutputSnapshot {
        PresentationOutputSnapshot(slide: LyricsParser.parseDocument("Verse 1\n" + text).slides.first, isPresenting: true, slidesVisible: visible)
    }
    func testHiddenNavigationKeepsLastExplicitConfidenceTextAndClearClearsIt() {
        let (service, sender) = service(), source = UUID()
        defer { service.disconnect() }
        service.handle(.show(snapshot("Presented")), from: source)
        service.handle(.changed(snapshot("Hidden navigation", visible: false)), from: source)
        XCTAssertEqual(sender.submissions.last?.content.body, "Hidden navigation")
        XCTAssertEqual(sender.submissions.last?.content.confidence?.body, "Presented")
        XCTAssertEqual(sender.takes, 1)
        service.handle(.project(snapshot("Next visible")), from: source)
        XCTAssertEqual(sender.submissions.last?.content.confidence?.body, "Next visible")
        service.handle(.changed(PresentationOutputSnapshot(slide: nil, isPresenting: true, slidesVisible: false)), from: source)
        XCTAssertEqual(sender.submissions.last?.content, .empty)
        XCTAssertEqual(sender.takes, 2)
    }
    func testThisMacUsesCurrentPortStablePairingIdentityAndNoPublication() throws {
        let marker = "current-boot", id = UUID()
        let discovery = AltViewReceiverDiscovery { _, _ in }
        let endpoint = NWEndpoint.service(name: "AltView", type: AltViewProtocol.serviceType, domain: "local.", interface: nil)
        func destination(_ port: String) throws -> AltViewDestination {
            let receiver = try XCTUnwrap(discovery.receiver(endpoint: endpoint, metadata: .bonjour(NWTXTRecord(["receiverID": id.uuidString, "localMarker": marker, "port": port])), localMarker: marker))
            return try XCTUnwrap(AltViewDestination(receiver))
        }
        let first = try destination("54321"), next = try destination("54322")
        XCTAssertEqual(first.id, next.id)
        XCTAssertEqual(first.endpoint, .hostPort(host: "127.0.0.1", port: .init(rawValue: 54321)!))
        let (service, sender) = service()
        defer { service.disconnect() }
        service.connect(to: first, code: "ABCD2345")
        XCTAssertNil(sender.connectionID, "A saved This Mac port is not a live endpoint")
        service.receiveDiscovered([first], notice: nil)
        XCTAssertEqual(sender.expectedReceiverID, id)
        service.receiveDiscovered([next], notice: nil)
        XCTAssertEqual(service.destination?.port, 54322)
        XCTAssertEqual(sender.endpoints.last, next.endpoint)
        XCTAssertTrue(sender.submissions.isEmpty); XCTAssertEqual(sender.takes, 0)
        service.disconnect()
        let count = sender.endpoints.count
        service.receiveDiscovered([first], notice: nil)
        XCTAssertEqual(sender.endpoints.count, count)
        let remote = discovery.receiver(endpoint: endpoint, metadata: .bonjour(NWTXTRecord(["receiverID": id.uuidString, "localMarker": "different", "port": "54321"])), localMarker: marker)
        XCTAssertEqual(remote?.endpoint, endpoint)
    }
    func testLegacyReceiverNeverReceivesExtensionMessages() throws {
        let key = AltViewPairingKey.parse("ABCD2345")!
        var output = ReferenceAltViewReceiverStatus(), status = AltViewSenderStatus()
        let receiver = ReferenceAltViewReceiverServer(receiverID: UUID()) { output = $0 }
        let sender = AltViewSenderClient(name: "Legacy-compatible") { status = $0 }
        defer { sender.disconnect(); receiver.stop() }
        receiver.start(name: "Legacy", key: key, advertise: false)
        eventually { output.port != nil }
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!), key: key)
        eventually { status.connected }
        sender.submit(.init(body: "Ordinary", confidence: .init(body: "Ordinary"), projection: .init(sessionID: UUID(), mode: .media, windowID: 7, windowGeneration: UUID())), submissionID: UUID()); sender.takeOutput()
        eventually { output.content.body == "Ordinary" && status.feedback.accepted }
        XCTAssertNil(output.content.confidence)
        XCTAssertNil(output.content.projection)
        XCTAssertTrue(status.connected)
    }
    func testNegotiatedFrameLimitKeepsLegacyTextAndClearsOversizeConfidenceWithoutDisconnect() throws {
        let key = AltViewPairingKey.parse("ABCD2345")!
        let text = String(repeating: "\u{01}", count: 6_000)
        let content = AltViewDisplayContent(body: text, confidence: .init(body: text))
        XCTAssertTrue(content.isValid)
        XCTAssertThrowsError(try AltViewFrameCodec.encode(AltViewWireMessage(kind: .state, content: content)))
        for capabilities in [[], AltViewProtocol.capabilities] {
            var output = ReferenceAltViewReceiverStatus(), status = AltViewSenderStatus()
            let receiver = ReferenceAltViewReceiverServer(receiverID: UUID(), capabilities: capabilities) { output = $0 }
            let sender = AltViewSenderClient(name: "Frame limits") { status = $0 }
            defer { sender.disconnect(); receiver.stop() }
            receiver.start(name: "Frames", key: key, advertise: false)
            eventually { output.port != nil }
            sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: try XCTUnwrap(output.port))!), key: key)
            // Queued before welcome: check the final capability set again.
            sender.submit(content, submissionID: UUID()); sender.takeOutput()
            if capabilities.isEmpty {
                eventually { output.content.body == text && status.feedback.accepted }
                XCTAssertNil(output.content.confidence); XCTAssertNil(status.contentError)
            } else {
                eventually { status.connected && status.contentError != nil }
                XCTAssertEqual(output.content, .empty)
                XCTAssertNil(output.ownerID, "Rejected queued content cannot take output even when it is clear")
                XCTAssertFalse(status.ownsOutput)
            }
            XCTAssertTrue(status.connected)
        }
    }
    func testExplicitMediaModeHiddenNavigationAndWindowRecreation() throws {
        let (service, sender) = service(), source = UUID()
        defer { service.disconnect() }
        let url = URL(fileURLWithPath: "/tmp/media")
        let slides = [
            Slide(index: 1, lines: [], label: nil, videoURL: url, pdfURL: nil, pdfPageIndex: nil, imageURL: nil),
            Slide(index: 1, lines: [], label: nil, videoURL: nil, pdfURL: url, pdfPageIndex: 0, imageURL: nil),
            Slide(index: 1, lines: [], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: url),
            Slide(index: 1, lines: [], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, webpageURL: URL(string: "https://example.com")),
            Slide(index: 1, lines: [], label: nil, videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: 42)
        ]
        for slide in slides {
            let generation = UUID()
            let media = PresentationOutputSnapshot(slide: slide, isPresenting: true, slidesVisible: true,
                projectionWindowID: 77, projectionWindowGeneration: generation)
            let count = sender.submissions.count
            service.handle(.changed(media), from: UUID())
            XCTAssertEqual(sender.submissions.count, count, "An inactive session cannot publish or take output")
            service.handle(.project(media), from: source)
            XCTAssertEqual(sender.submissions.last?.content.projection?.mode, .media)
            XCTAssertEqual(sender.submissions.last?.content.projection?.sessionID, source)
            XCTAssertEqual(sender.submissions.last?.content.projection?.windowID, 77)
            XCTAssertEqual(sender.submissions.last?.content.body, "")
            XCTAssertNil(sender.submissions.last?.content.confidence)
            let takes = sender.takes
            var hiddenLyrics = snapshot("Private navigation", visible: false)
            hiddenLyrics.projectionWindowID = 77; hiddenLyrics.projectionWindowGeneration = generation
            service.handle(.changed(hiddenLyrics), from: source)
            XCTAssertEqual(sender.submissions.last?.content.projection?.mode, .media)
            XCTAssertEqual(sender.takes, takes)
            let newGeneration = UUID()
            hiddenLyrics.projectionWindowID = 88; hiddenLyrics.projectionWindowGeneration = newGeneration
            service.handle(.changed(hiddenLyrics), from: source)
            XCTAssertEqual(sender.submissions.last?.content.projection?.windowID, 88)
            XCTAssertEqual(sender.submissions.last?.content.projection?.windowGeneration, newGeneration)
            XCTAssertEqual(sender.submissions.last?.content.projection?.mode, .media)
            service.handle(.show(snapshot("Presented lyrics")), from: source)
            XCTAssertEqual(sender.submissions.last?.content.projection?.mode, .lyrics)
            XCTAssertEqual(sender.submissions.last?.content.confidence?.body, "Presented lyrics")
            service.handle(.changed(PresentationOutputSnapshot(slide: nil, isPresenting: true, slidesVisible: false)), from: source)
            XCTAssertNil(sender.submissions.last?.content.projection)
            XCTAssertEqual(sender.submissions.last?.content, .empty)
        }
        service.handle(.stopped, from: source)
        XCTAssertNil(service.submitted)
        XCTAssertFalse(service.isSending)
    }
    func testBackgroundAndConnectOnlyNeverPublishProjection() {
        let (service, sender) = service()
        defer { service.disconnect() }
        let source = UUID()
        service.handle(.changed(snapshot("Unpresented")), from: source)
        XCTAssertTrue(sender.submissions.isEmpty); XCTAssertEqual(sender.takes, 0)
        service.handle(.show(snapshot("Primary")), from: source)
        let original = service.submitted?.projection
        service.handle(.changed(snapshot("Hidden different media", visible: false)), from: source)
        XCTAssertEqual(service.submitted?.projection?.mode, original?.mode)
        XCTAssertEqual(service.submitted?.confidence?.body, "Primary")
        XCTAssertEqual(sender.takes, 1)
        service.disconnect()
        XCTAssertNil(service.submitted)
    }
    private func eventually(_ check: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !check() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(check())
    }
}
