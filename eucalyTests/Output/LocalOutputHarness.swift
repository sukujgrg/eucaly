import AppKit
@testable import eucaly

@MainActor
final class LocalOutputHarness {
    let outputs: OutputCoordinator
    let session: PresentationSession
    let flow = PresentationFlowController()
    let nativeRow: UUID
    let driver: FakeOutputDriver
    init(driver: FakeOutputDriver? = nil) {
        let driver = driver ?? FakeOutputDriver(); self.driver = driver
        let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Audience",
            frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
        let store = OutputProfileStore(monitor: monitor.target)
        nativeRow = store.document.destinations[0].id
        outputs = OutputCoordinator(profiles: store, displays: displays, driverFactory: { driver })
        session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
    }
    func load(_ raw: String) { session.setSlides(LyricsParser.parseDocument(raw).slides) }
    func stop() { outputs.stop() }
}
