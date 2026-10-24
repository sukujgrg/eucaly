import XCTest
import AppKit
@testable import eucaly

@MainActor
final class OMTOutputTests: XCTestCase {
    func testMixedTransportsKeepTheirProtocolAndSenderAcrossWorkspaceMoves() async throws {
        let factory = OMTRecordingFactory()
        let router = NetworkOutputRouter(senderFactory: { factory.make($0) })
        let store = OutputProfileStore()
        let online = try XCTUnwrap(store.addWorkspace(name: "Online"))
        var nativeNDI = OutputDestinationConfiguration(name: "NDI", profileID: OutputProfile.audienceID, monitor: nil)
        nativeNDI.ndi = .init(sourceName: "Existing NDI")
        var omt = OutputDestinationConfiguration(name: "Apple TV", profileID: OutputProfile.audienceID, monitor: nil)
        omt.omt = .init(sourceName: "eucaly Apple TV")
        store.edit { $0.destinations = [nativeNDI, omt] }
        let outputs = OutputCoordinator(profiles: store, displays: ProjectionDisplayManager(displays: { [] }), retainsPreparedSessions: true, network: router)
        let home = outputs.session(workspace: OutputWorkspaceRecord.primaryID), peer = outputs.session(workspace: online)
        defer { outputs.stopAllOutputs() }
        home.setSlides(LyricsParser.parseDocument("Verse\nHome program").slides)
        peer.setSlides(LyricsParser.parseDocument("Verse\nOnline program").slides)
        outputs.program(online).flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPrivate draft").slides)
        XCTAssertTrue(factory.senders.isEmpty, "Preparation and browsing must not create either network source")
        home.showSlides()
        try await until { factory.senders.count == 2 && factory.senders.allSatisfy { !$0.submissions.isEmpty } }
        let oldNDI = try XCTUnwrap(factory.senders.first { $0.configuration?.technology == .ndi })
        let sender = try XCTUnwrap(factory.senders.first { $0.configuration?.technology == .omt })
        let generation = sender.generation, sourceID = omt.omt?.sourceID
        XCTAssertTrue(outputs.moveOutput(omt.id, to: peer))
        try await until { sender.submissions.last?.request.text?.text.components.first?.text == "Online program" }
        XCTAssertEqual(oldNDI.submissions.last?.request.text?.text.components.first?.text, "Home program")
        XCTAssertEqual(outputs.program(online).flow.previewSlides.first?.lines.first?.text, "Private draft")
        peer.hideSlides()
        try await until { sender.submissions.last?.request.text == nil }
        peer.clearSlides()
        try await until { sender.submissions.last.map { !$0.request.foreground && $0.request.text == nil && $0.request.colour.alpha == 0 } == true }
        XCTAssertEqual(factory.senders.count, 2)
        XCTAssertEqual(sender.starts, 1); XCTAssertEqual(sender.stops, 0)
        XCTAssertEqual(sender.generation, generation)
        XCTAssertEqual(outputs.destination(omt.id)?.omt?.sourceID, sourceID)
        XCTAssertEqual(outputs.destination(omt.id)?.workspaceID, online)
        XCTAssertEqual(outputs.destination(nativeNDI.id)?.workspaceID, OutputWorkspaceRecord.primaryID)
        sender.fail()
        try await until { !router.state(omt.id).active }
        XCTAssertTrue(router.state(nativeNDI.id).active, "An OMT failure must preserve its NDI companion")
        XCTAssertEqual(oldNDI.stops, 0)
        outputs.stopAllOutputs(); await router.shutdown()
    }

    func testProtocolReplacementRetiresTheExactSenderAndRequiresAnExplicitRestart() async throws {
        let factory = OMTRecordingFactory()
        let router = NetworkOutputRouter(senderFactory: { factory.make($0) })
        var row = OutputDestinationConfiguration(name: "Network", profileID: OutputProfile.audienceID, monitor: nil)
        row.omt = .init(sourceName: "Source")
        XCTAssertTrue(router.start(row))
        try await until { factory.senders.count == 1 && router.state(row.id).active }
        let sender = try XCTUnwrap(factory.senders.first)
        var document = OutputProfileDocument(profiles: OutputProfile.builtIns, destinations: [row])
        row.ndi = row.omt
        XCTAssertFalse(router.start(row), "Start must not report an old protocol's sender as the requested source")
        document.destinations = [row]
        router.reconcile(document)
        XCTAssertEqual(sender.stops, 1)
        XCTAssertFalse(router.start(row), "Protocol replacement cannot reuse a still-retiring child")
        XCTAssertEqual(factory.senders.count, 1)
        await router.shutdown()
    }

    private func until(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(15)) }
        guard condition() else { XCTFail("Timed out waiting for network output state"); throw NetworkHelperWire.Failure.unavailable }
    }
}

@MainActor
private final class OMTRecordingFactory {
    var senders: [OMTRecordingSender] = []
    func make(_ event: @escaping @Sendable (NetworkHelperSupervisor.Event) -> Void) -> OMTRecordingSender {
        let sender = OMTRecordingSender(event: event); senders.append(sender); return sender
    }
}

nonisolated private final class OMTRecordingSender: NetworkSenderDriving, @unchecked Sendable {
    private let lock = NSLock()
    private let event: @Sendable (NetworkHelperSupervisor.Event) -> Void
    private var storedConfiguration: NetworkHelperConfiguration?
    private var identifier = UUID()
    private var startCount = 0, stopCount = 0
    private var epoch: UInt64 = 0
    private var values: [NetworkMediaSubmission] = []
    var configuration: NetworkHelperConfiguration? { lock.withLock { storedConfiguration } }
    var generation: UUID { lock.withLock { identifier } }
    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    var submissions: [NetworkMediaSubmission] { lock.withLock { values } }
    init(event: @escaping @Sendable (NetworkHelperSupervisor.Event) -> Void) { self.event = event }
    func startSender(generation: UUID, configuration: NetworkHelperConfiguration) {
        lock.withLock { identifier = generation; storedConfiguration = configuration; startCount += 1 }
        event(.ready(generation))
    }
    func selectContent(epoch: UInt64) { lock.withLock { self.epoch = epoch } }
    func renderMedia(_ submission: NetworkMediaSubmission) {
        lock.withLock { if submission.request.contentEpoch == epoch { values.append(submission) } }
    }
    func sendAudio(_ block: NetworkAudioBlock, generation: UUID, contentEpoch: UInt64) {}
    func stop() { lock.withLock { stopCount += 1 } }
    func stopAndWait() async { event(.exited(generation)) }
    func fail() { event(.failed(generation, "Injected OMT source failure")) }
}
