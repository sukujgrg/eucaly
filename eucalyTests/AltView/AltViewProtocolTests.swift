import XCTest
import Network
import Security
@testable import eucaly

final class AltViewProtocolTests: XCTestCase {
    func testTLSClosesRetryButAuthenticationFailuresDoNot() {
        for code in [errSSLClosedGraceful, errSSLClosedAbort, errSSLClosedNoNotify, errSSLNetworkTimeout] {
            XCTAssertTrue(AltViewPeerChannel.isRetryableNetworkError(.tls(code)))
        }
        XCTAssertTrue(AltViewPeerChannel.isRetryableNetworkError(.posix(.ECONNRESET)))
        for code in [errSSLBadRecordMac, errSSLPeerHandshakeFail, errSSLPeerUnknownCA] {
            XCTAssertFalse(AltViewPeerChannel.isRetryableNetworkError(.tls(code)))
        }
    }

    func testGoldenV2SnapshotFragmentedAndCombinedFrames() throws {
        let lease = UUID()
        let json = "{\"version\":2,\"kind\":\"state\",\"lease\":\"\(lease)\",\"revision\":42,\"content\":{\"body\":\"Main lyrics\\nSecond line\",\"visible\":true}}"
        let bytes = Data(json.utf8)
        var count = UInt32(bytes.count).bigEndian
        var frame = withUnsafeBytes(of: &count) { Data($0) }
        frame.append(bytes)
        let heartbeat = try AltViewFrameCodec.encode(.init(kind: .heartbeat))
        var decoder = AltViewFrameDecoder()
        var messages: [AltViewWireMessage] = []
        for byte in frame { messages += try decoder.append(Data([byte])) }
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.lease, lease)
        XCTAssertEqual(messages.first?.content, .init(body: "Main lyrics\nSecond line"))
        XCTAssertEqual(try decoder.append(heartbeat + frame).map(\.kind), [.heartbeat, .state])
    }

    func testInvalidRequiredFieldsAndBounds() throws {
        for json in ["{}", "{\"body\":\"x\"}", "{\"body\":1,\"visible\":true}", "{\"body\":\"x\",\"visible\":true,\"emptyRegions\":\"unknown\"}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(AltViewDisplayContent.self, from: Data(json.utf8)))
        }
        for header in [Data([0, 0, 0, 0]), Data([0, 1, 0, 1])] {
            var decoder = AltViewFrameDecoder()
            XCTAssertThrowsError(try decoder.append(header))
        }
        XCTAssertFalse(AltViewDisplayContent(body: String(repeating: "界", count: 8_001)).isValid)
        let escaping = AltViewDisplayContent(body: String(repeating: "\u{1}", count: 24_000))
        XCTAssertTrue(escaping.isValid)
        XCTAssertThrowsError(try AltViewFrameCodec.encode(.init(kind: .state, content: escaping)))
    }

    func testPairingNormalizationAndLegacyRejection() {
        XCTAssertEqual(AltViewPairingKey.parse(" abcd-2345 \n"), Data("ABCD2345".utf8))
        for invalid in ["00000000", "IIIIIIII", String(repeating: "A", count: 64), "ÄBCD2345", "ABCD234"] {
            XCTAssertNil(AltViewPairingKey.parse(invalid))
        }
    }

    func testOutboxAndMailboxStayBoundedDuringBursts() throws {
        var outbox = AltViewMessageOutbox()
        for revision in 1...10_000 {
            try outbox.enqueue(.init(kind: .state, revision: UInt64(revision)))
            try outbox.enqueue(.init(kind: .heartbeat))
        }
        XCTAssertEqual(outbox.count, 2)
        XCTAssertEqual(outbox.next()?.revision, 10_000)
        for _ in 0..<16 { try outbox.enqueue(.init(kind: .take)) }
        XCTAssertThrowsError(try outbox.enqueue(.init(kind: .take)))

        let queue = DispatchQueue(label: "altview-mailbox-test")
        queue.suspend()
        let delivered = expectation(description: "latest value")
        let mailbox = AltViewSnapshotMailbox<Int>(queue: queue) { value in
            XCTAssertEqual(value, 9_999)
            delivered.fulfill()
        }
        for value in 0..<10_000 { mailbox.offer(value) }
        queue.resume()
        wait(for: [delivered], timeout: 2)
    }

    func testDelayedAcknowledgementNeverAcceptsStaleLeaseOrNewerUnsentRevision() {
        var feedback = AltViewDeliveryFeedback()
        let lease = UUID()
        feedback.sent(2, now: 0)
        XCTAssertTrue(feedback.checkTimeout(now: 5))
        feedback.receive(.init(kind: .feedback, lease: UUID(), revision: 2, outputReadiness: .ready), lease: lease, now: 6)
        feedback.receive(.init(kind: .feedback, lease: lease, revision: 3, outputReadiness: .ready), lease: lease, now: 6)
        XCTAssertFalse(feedback.accepted)
        XCTAssertTrue(feedback.overdue)
        feedback.receive(.init(kind: .feedback, lease: lease, revision: 2, outputReadiness: .closed), lease: lease, now: 7)
        XCTAssertTrue(feedback.accepted)
        XCTAssertFalse(feedback.overdue)
        XCTAssertEqual(feedback.output, .closed)
    }
}
