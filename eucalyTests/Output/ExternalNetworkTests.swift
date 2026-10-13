import XCTest
import Network
import Security
@testable import eucaly

@MainActor
final class ExternalNetworkTests: XCTestCase {
    private let key = Data("ABCD2345".utf8)
    private func eventually(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }; try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Secure receiver condition timed out"); throw ExternalPresentationError.invalid("Timed out")
    }
    func testWrongPairingAndChangedPinnedHubIdentityCannotChangeLocalOutput() async throws {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let outputs = OutputCoordinator(profiles: OutputProfileStore(monitor: monitor.target), displays: displays, driverFactory: { FakeOutputDriver() })
        let local = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        local.setSlides(LyricsParser.parseDocument("Verse\nLocal retained").slides); local.showSlides()
        let receiverID = UUID()
        let receiver = ExternalPresentationReceiver(coordinator: outputs, receiverID: receiverID,
            credentialStore: HubReceiverCredentialStore(keychain: TestReceiverKeychain(initial: key)), advertise: false)
        receiver.setEnabled(true)
        defer { receiver.stop(); outputs.stop() }
        try await eventually { receiver.port != nil }
        for (pairing, pin) in [(Data("WXYZ6789".utf8), receiverID), (key, UUID())] {
            var status = VTWAltViewSenderStatus()
            let sender = VTWAltViewSenderClient(name: "Rejected fixture") { value in MainActor.assumeIsolated { status = value } }
            let connection = UUID()
            sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: receiver.port!)!), key: pairing, expectedReceiverID: pin, connectionID: connection)
            sender.submit(.init(connectionID: connection, content: .init(body: "Must never present"), intent: UUID()))
            try await eventually { status.failureReason != nil }
            XCTAssertFalse(status.ownsOutput); XCTAssertEqual(outputs.ownership.source, .local(local.outputSourceID))
            XCTAssertEqual(outputs.text.components.first?.text, "Local retained")
            sender.disconnect()
        }
    }
    func testActualSenderStopBetweenGrantAndFirstStateCancelsOnlyThatIntent() async throws {
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        var opens = 0
        let outputs = OutputCoordinator(profiles: OutputProfileStore(monitor: monitor.target), displays: displays,
            driverFactory: { opens += 1; return FakeOutputDriver() })
        let relay = HubTestReplyRelay(), id = UUID()
        let receiver = ExternalPresentationReceiver(coordinator: outputs, receiverID: id, advertise: false,
            replySink: { relay.server?.send($0, to: $1) })
        var port: UInt16?, stoppedGrant = false, status = VTWAltViewSenderStatus()
        let server = HubReceiverServer(receiverID: id, key: key, name: "Grant fixture", actionClock: outputs.actionClock,
            advertise: false, intent: { event in
                receiver.handle(event)
                if event.message.kind == .take && !stoppedGrant {
                    stoppedGrant = true
                    outputs.stop() // Deterministic native action after grant, before first state.
                }
            }, disconnected: { outputs.externalDisconnected($0) }, status: { value, _, _ in port = value })
        relay.server = server
        let sender = VTWAltViewSenderClient(name: "Grant fixture") { value in MainActor.assumeIsolated { status = value } }
        defer { sender.disconnect(); server.stop(); receiver.stop(); outputs.stop() }
        server.start(); try await eventually { port != nil }
        let connection = UUID()
        sender.connect(to: .hostPort(host: "127.0.0.1", port: .init(rawValue: port!)!), key: key, expectedReceiverID: id, connectionID: connection)
        try await eventually { status.connected }
        let cancelled = UUID()
        sender.submit(.init(connectionID: connection, content: .init(body: "Cancelled verse"), intent: cancelled))
        try await eventually { stoppedGrant && status.rejectedPresentationIntent == cancelled }
        XCTAssertEqual(opens, 0); XCTAssertNil(outputs.ownership.source)
        sender.submit(.init(connectionID: connection, content: .init(body: "Passive old refresh"), intent: cancelled))
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(opens, 0); XCTAssertNil(outputs.ownership.source)
        sender.submit(.init(connectionID: connection, content: .init(body: "Fresh explicit verse"), intent: UUID()))
        try await eventually { outputs.text.components.first?.text == "Fresh explicit verse" && status.feedback.accepted }
        XCTAssertEqual(opens, 1); XCTAssertTrue(status.connected)
    }

    func testPairingKeyIsPersistedOnceAndCorruptOrDeniedItemsAreNotReplaced() async throws {
        let access = TestReceiverKeychain()
        let first = HubReceiverCredentialStore(service: "fixture", keychain: access)
        let key = try await first.loadOrCreate()
        XCTAssertTrue(AltViewPairingKey.isValid(key))
        let restored = try await HubReceiverCredentialStore(service: "fixture", keychain: access).loadOrCreate()
        XCTAssertEqual(key, restored); XCTAssertEqual(access.saveCount, 1)
        for access in [TestReceiverKeychain(initial: Data("corrupt".utf8)), TestReceiverKeychain(denied: true)] {
            do { _ = try await HubReceiverCredentialStore(service: "fixture", keychain: access).loadOrCreate(); XCTFail("Invalid/denied pairing must remain an error") }
            catch { XCTAssertEqual(access.saveCount, 0) }
        }
    }
}

nonisolated final class TestReceiverKeychain: AltViewKeychainAccess, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var saves = 0
    private let denied: Bool
    init(initial: Data? = nil, denied: Bool = false) { data = initial; self.denied = denied }
    var saveCount: Int { lock.withLock { saves } }
    func read(service: String, account: String, dataProtection: Bool) throws -> Data? {
        if denied { throw NSError(domain: NSOSStatusErrorDomain, code: Int(errSecInteractionNotAllowed)) }
        return lock.withLock { data }
    }
    func save(_ data: Data, service: String, account: String, dataProtection: Bool) throws {
        lock.withLock { self.data = data; saves += 1 }
    }
}

@MainActor
private final class HubTestReplyRelay {
    weak var server: HubReceiverServer?
}
