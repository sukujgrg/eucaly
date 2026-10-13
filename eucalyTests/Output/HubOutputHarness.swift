import AppKit
import Network
@testable import eucaly

/// Exercises the real coordinator/router boundary with a native destination
/// driver and an injected transport. It never synthesizes session output events.
@MainActor
final class HubOutputHarness {
    let outputs: OutputCoordinator
    let session: PresentationSession
    let flow = PresentationFlowController()
    let router: AltViewOutputRouter
    let service: AltViewService
    let remoteID: UUID
    let remoteRow: UUID
    let nativeRow: UUID
    let driver: FakeOutputDriver

    init(service: AltViewService, receiverID: UUID = UUID(), port: UInt16 = 49000,
         code: String = "ABCD2345", driver: FakeOutputDriver? = nil) {
        let driver = driver ?? FakeOutputDriver()
        self.service = service; self.driver = driver; remoteID = receiverID
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Audience",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] })
        displays.select(monitor.target)
        let store = OutputProfileStore(monitor: monitor.target)
        nativeRow = store.document.destinations[0].id
        var remote = OutputDestinationConfiguration(name: "AltView", profileID: OutputProfile.altViewID, monitor: nil)
        remote.destination = .altView(.init(receiverID: receiverID, name: "Test receiver")); remote.savedReceiver = remote.receiver
        remoteRow = remote.id
        store.edit { $0.destinations.append(remote) }
        outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { driver })
        session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        let suite = "HubHarness.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        router = AltViewOutputRouter(store: store, receiverID: UUID(), defaults: defaults,
            pairingStore: RecordingAltViewPairingStore(), channelFactory: { service })
        router.start(coordinator: outputs, discover: false)
        router.receiveDiscovered([AltViewDestination(.init(name: "Test receiver",
            endpoint: .hostPort(host: "127.0.0.1", port: .init(rawValue: port)!), receiverID: receiverID, isLocal: true))!], notice: nil)
        router.connect(remoteRow, code: code)
        defaults.removePersistentDomain(forName: suite)
    }
    func load(_ raw: String) { session.setSlides(LyricsParser.parseDocument(raw).slides) }
    func stop() { outputs.stop(); router.shutdown() }
}
