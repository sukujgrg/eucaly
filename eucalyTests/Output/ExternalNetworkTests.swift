import XCTest
import Network
@testable import eucaly

@MainActor
final class ExternalNetworkTests: XCTestCase {
    func testLoopbackAuthenticationDiscoveryPresentBurstHideStaleAndReconnect() async throws {
        let key = Data(repeating: 9, count: 32).base64EncodedString()
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Test", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let store = OutputProfileStore(monitor: monitor.target)
        let outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { FakeOutputDriver() })
        let session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        session.setSlides(LyricsParser.parseDocument("Verse\nLocal Current").slides)
        var port: UInt16?, replies: [ExternalPresentationReply] = []
        let repliesToClient = ExternalTestReplyRelay()
        let server = ExternalPresentationServer(credential: key, port: 0, intent: { id, name, message in
            do {
                switch message.kind {
                case .hello: repliesToClient.send(outputs.discoveryReply(), to: id)
                case .present:
                    let lease = try outputs.presentExternal(connection: id, name: name, message: message)
                    repliesToClient.send(.init(kind: "accepted", actionID: message.actionID, lease: lease), to: id)
                case .state:
                    repliesToClient.send(.init(kind: outputs.updateExternal(connection: id, message: message) ? "feedback" : "rejected", revision: message.revision), to: id)
                case .hide, .clear, .release:
                    repliesToClient.send(.init(kind: outputs.externalControl(connection: id, message: message) ? "accepted" : "rejected", actionID: message.actionID), to: id)
                }
            } catch { repliesToClient.send(.init(kind: "rejected", actionID: message.actionID), to: id) }
        }, disconnected: { outputs.externalDisconnected($0) }, status: { port = $0; XCTAssertNil($1) })
        repliesToClient.server = server
        server.start(); defer { server.stop(); outputs.stop() }
        try await eventually { port != nil }
        let client = ExternalTestClient(port: try XCTUnwrap(port)) { replies.append($0) }
        defer { client.stop() }
        client.start()
        client.send(.init(kind: .hello, protocolVersion: ExternalPresentationProtocol.version, credential: key, clientName: "Scripture"))
        try await eventually { replies.contains { $0.kind == "welcome" } }
        XCTAssertFalse(outputs.isRunning); XCTAssertFalse(outputs.isExternal)
        let action = UUID(), content = OutputTextContent(kind: .scripture, components: [.init(role: .primary, text: "Direct verse"), .init(role: .reference, text: "John 3:16")])
        client.send(.init(kind: .present, sourceID: UUID(), actionID: action, revision: 1, current: content))
        try await eventually { replies.contains { $0.actionID == action && $0.kind == "accepted" } }
        let lease = try XCTUnwrap(replies.first { $0.actionID == action }?.lease)
        XCTAssertEqual(outputs.text, content)
        XCTAssertEqual(session.currentSlide?.lines.first?.text, "Local Current")
        for revision in 2...1_000 {
            client.send(.init(kind: .state, revision: UInt64(revision), lease: lease, current: .init(components: [.init(role: .primary, text: "\(revision)")])))
        }
        try await eventually { outputs.text.components.first?.text == "1000" }
        let hide = UUID(); client.send(.init(kind: .hide, actionID: hide, lease: lease))
        try await eventually { replies.contains { $0.actionID == hide } }
        XCTAssertFalse(outputs.visible)
        client.send(.init(kind: .state, revision: 1_001, lease: lease, current: content))
        try await eventually { replies.contains { $0.kind == "rejected" && $0.revision == 1_001 } }
        client.stop()
        let reconnect = ExternalTestClient(port: try XCTUnwrap(port)) { replies.append($0) }
        defer { reconnect.stop() }
        reconnect.start(); reconnect.send(.init(kind: .hello, protocolVersion: ExternalPresentationProtocol.version, credential: key, clientName: "Scripture"))
        try await eventually { replies.filter { $0.kind == "welcome" }.count == 2 }
        XCTAssertNil(outputs.ownership.source); XCTAssertFalse(outputs.visible)
        reconnect.send(.init(kind: .state, revision: 1_002, lease: lease, current: content))
        try await eventually { replies.contains { $0.kind == "rejected" && $0.revision == 1_002 } }
    }
    private func eventually(_ predicate: @escaping () -> Bool) async throws {
        let end = Date().addingTimeInterval(8)
        while !predicate() && Date() < end { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(predicate(), "Loopback request timed out")
        if !predicate() { throw ExternalPresentationError.invalid("Timed out") }
    }
}

/// A stable main-actor reference avoids capturing a variable while assigning
/// the server, and the weak backlink prevents the test handler retaining it.
@MainActor
private final class ExternalTestReplyRelay {
    weak var server: ExternalPresentationServer?
    func send(_ reply: ExternalPresentationReply, to id: UUID) { server?.send(reply, to: id) }
}

nonisolated final class ExternalTestClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "external-test-client")
    private let connection: NWConnection
    private var decoder = ExternalFrameDecoder()
    private let received: @MainActor @Sendable (ExternalPresentationReply) -> Void
    init(port: UInt16, received: @escaping @MainActor @Sendable (ExternalPresentationReply) -> Void) {
        connection = NWConnection(host: "127.0.0.1", port: .init(rawValue: port)!, using: .tcp)
        self.received = received
    }
    func start() { connection.start(queue: queue); read() }
    func send(_ message: ExternalPresentationMessage) {
        queue.async { [self] in if let frame = try? ExternalPresentationProtocol.frame(message) { connection.send(content: frame, completion: .contentProcessed { _ in }) } }
    }
    func stop() { connection.cancel() }
    private func read() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, let frames = try? decoder.append(data) {
                for frame in frames { if let reply = try? JSONDecoder().decode(ExternalPresentationReply.self, from: frame) { Task { @MainActor in self.received(reply) } } }
            }
            if !done && error == nil { read() }
        }
    }
}
