import XCTest
import AppKit
@testable import eucaly

@MainActor
final class NetworkOutputTests: XCTestCase {
    func testRestorationPreparationAndEnablingNeverStartPublication() throws {
        let fixture = Fixture(); defer { fixture.outputs.stop() }
        let controller = ManageOutputsController(coordinator: fixture.outputs)
        _ = controller.view; controller.setPresented(true); controller.setPresented(false)
        let session = fixture.session
        session.setSlides(LyricsParser.parseDocument("Verse\nPrivate Current").slides)
        let flow = PresentationFlowController(); flow.setPreviewSlides(LyricsParser.parseDocument("Verse\nPreview").slides)
        XCTAssertTrue(fixture.ndi.starts.isEmpty); XCTAssertTrue(fixture.ndi.snapshots.isEmpty)
        fixture.store.setEnabled(false, for: fixture.lyrics)
        fixture.store.setEnabled(true, for: fixture.lyrics)
        XCTAssertTrue(fixture.ndi.starts.isEmpty); XCTAssertFalse(fixture.outputs.isRunning)
        session.showSlides()
        XCTAssertEqual(Set(fixture.ndi.starts), [fixture.lyrics, fixture.media])
        XCTAssertTrue(fixture.outputs.isPresenting); XCTAssertTrue(session.isPresenting)
        XCTAssertEqual(fixture.nativeOpens, 0)
        XCTAssertEqual(fixture.ndi.snapshots.last?.current.components.first?.text, "Private Current")
    }
    func testNDIOnlyKeepsPrivateWorkspaceAndUnsupportedContentOutOfAcceptedProgram() async throws {
        let fixture = Fixture(); defer { fixture.outputs.stop() }
        fixture.session.setSlides(LyricsParser.parseDocument("Verse\nLive").slides); fixture.session.showSlides()
        let other = PresentationSession(projectionDisplays: fixture.outputs.displays, outputCoordinator: fixture.outputs)
        other.setSlides(LyricsParser.parseDocument("Verse\nPrivate").slides)
        fixture.outputs.passiveLocal(other)
        XCTAssertEqual(fixture.outputs.text.components.first?.text, "Live")
        let slide = Slide(index: 0, lines: [], label: "Picked Window", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: 42)
        fixture.session.setSlides([slide])
        fixture.outputs.passiveLocal(fixture.session)
        await Task.yield()
        XCTAssertEqual(fixture.outputs.text.components.first?.text, "Live", "A deferred refresh must preserve the accepted NDI program")
        fixture.session.showSlides()
        XCTAssertEqual(fixture.outputs.text.components.first?.text, "Live")
        XCTAssertNotNil(fixture.session.projectionDisplayIssue)
        other.showSlides()
        XCTAssertFalse(other.isPresenting)
        XCTAssertTrue(fixture.outputs.moveOutput(fixture.lyrics, to: other))
        XCTAssertTrue(fixture.outputs.moveOutput(fixture.media, to: other))
        fixture.outputs.focusWorkspace(other)
        XCTAssertEqual(fixture.outputs.ownership.source, other.outputSourceID)
        XCTAssertEqual(fixture.outputs.text.components.first?.text, "Private")
        fixture.outputs.hide()
        XCTAssertFalse(try XCTUnwrap(fixture.ndi.snapshots.last).visible)
        XCTAssertEqual(fixture.ndi.activeIDs.count, 2)
        other.selectCurrentSlide(other.slides[0].id)
        await Task.yield()
        XCTAssertFalse(try XCTUnwrap(fixture.ndi.snapshots.last).visible, "Hidden navigation must remain private")
        fixture.outputs.clear()
        XCTAssertTrue(try XCTUnwrap(fixture.ndi.snapshots.last).current.isEmpty)
    }
    func testIndependentStopDisableAndFailureKeepOtherConsumerAndCurrent() async throws {
        let fixture = Fixture(); defer { fixture.outputs.stop() }
        fixture.session.setSlides(LyricsParser.parseDocument("Verse\nLive").slides); fixture.session.showSlides()
        fixture.outputs.closeOutput(fixture.lyrics)
        XCTAssertEqual(fixture.ndi.activeIDs, [fixture.media])
        XCTAssertTrue(fixture.session.isPresenting)
        fixture.ndi.fail(fixture.media)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(fixture.outputs.isRunning)
        XCTAssertEqual(fixture.session.currentSlide?.lines.first?.text, "Live")
        let count = fixture.ndi.starts.count
        fixture.store.editDestinationProfile(fixture.media) { $0.typography.size = 72 }
        XCTAssertEqual(fixture.ndi.starts.count, count)
        fixture.outputs.startNetworkOutput(fixture.lyrics)
        XCTAssertEqual(fixture.ndi.activeIDs, [fixture.lyrics])
        fixture.store.setEnabled(false, for: fixture.lyrics)
        XCTAssertTrue(fixture.ndi.activeIDs.isEmpty)
    }
    func testPickedWindowUsesNativeOutputAndNativeCloseKeepsNDI() throws {
        let fixture = Fixture(); defer { fixture.outputs.stop() }
        fixture.store.edit { doc in let native = doc.destinations.removeFirst(); doc.destinations.append(native) }
        fixture.store.setEnabled(true, for: fixture.native)
        let slide = Slide(index: 0, lines: [], label: "Picked Window", videoURL: nil, pdfURL: nil, pdfPageIndex: nil, imageURL: nil, captureWindowID: 42)
        fixture.session.setSlides([slide]); fixture.session.showSlides()
        XCTAssertNil(fixture.session.projectionDisplayIssue)
        XCTAssertEqual(fixture.nativeOpens, 1); XCTAssertEqual(fixture.ndi.activeIDs.count, 2)
        XCTAssertNotNil(fixture.outputs.audienceTarget)
        XCTAssertNotNil(fixture.outputs.audienceIdentity.1)
        fixture.outputs.closeOutput(fixture.native)
        XCTAssertTrue(fixture.outputs.isRunning); XCTAssertEqual(fixture.ndi.activeIDs.count, 2)
    }
    func testClearingNDILyricsVisualPreservesItsKeyColourAndNativeAppearance() throws {
        let fixture = Fixture(); defer { fixture.outputs.stop() }
        fixture.store.editDestinationProfile(fixture.lyrics) {
            $0.background.colour = .chromaGreen
            $0.background.bookmark = "selected visual"
        }
        let originalNative = fixture.store.audience
        fixture.store.clearDestinationBackground(fixture.lyrics)
        var profile = try XCTUnwrap(fixture.outputs.profile(for: fixture.lyrics))
        XCTAssertNil(profile.background.bookmark)
        XCTAssertEqual(profile.background.colour, .chromaGreen)
        XCTAssertEqual(fixture.store.audience, originalNative)
        fixture.store.editDestinationProfile(fixture.lyrics) { $0.background.bookmark = "selected visual" }
        fixture.store.clearBackgrounds()
        profile = try XCTUnwrap(fixture.outputs.profile(for: fixture.lyrics))
        XCTAssertNil(profile.background.bookmark)
        XCTAssertEqual(profile.background.colour, .chromaGreen, "Clear All must retain the receiver's configured key colour")
        fixture.store.selectProfile(OutputProfile.confidenceID, for: fixture.lyrics)
        XCTAssertFalse(fixture.outputs.hasEnabledConfidenceOutput, "A profile must not turn NDI into a native standby destination")
    }
    func testSourceIdentityNamesFormatAndSingleAudioRoutePersistWithoutStartup() throws {
        let suite = "NDISettings.\(UUID())", defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = OutputProfileStore(defaults: defaults)
        let lyric = destination("Lyrics"), media = destination("Media")
        store.edit { $0.destinations += [lyric, media] }
        XCTAssertNil(store.document.backgroundAudioDestinationID)
        store.edit { $0.backgroundAudioDestinationID = lyric.id }; store.flush()
        let restored = OutputProfileStore(defaults: defaults); restored.flush()
        XCTAssertEqual(restored.document, store.document)
        var duplicate = try XCTUnwrap(media.ndi); duplicate.sourceName = "eucaly lyrics"
        XCTAssertNotNil(store.setNetworkSettings(duplicate, for: media.id))
        for name in ["", "   ", "bad/name", "bad\\name", "bad:name", "bad\nname", String(repeating: "x", count: 121)] {
            XCTAssertFalse(NetworkOutputSettings.validName(name), name)
        }
        XCTAssertTrue(NetworkOutputSettings.validName("சபை Lyrics"))
        var format = NetworkOutputSettings(); format.frameRateNumerator = 60
        XCTAssertFalse(format.isValid)
        store.setEnabled(false, for: lyric.id)
        XCTAssertEqual(store.document.backgroundAudioDestinationID, lyric.id, "Disabling never reroutes music")
        store.edit { $0.destinations.removeAll { $0.id == lyric.id } }
        XCTAssertNil(store.document.backgroundAudioDestinationID)
    }
    func testNetworkActivityDoesNotPreventDisplaySleep() {
        var options: ProcessInfo.ActivityOptions = []; var ends = 0
        let sleep = ProjectionSleepPrevention(preventsDisplaySleep: false, beginActivity: { value, _ in options = value; return NSObject() }, endActivity: { _ in ends += 1 })
        sleep.start(); sleep.start()
        XCTAssertTrue(options.contains(.idleSystemSleepDisabled))
        XCTAssertFalse(options.contains(.idleDisplaySleepDisabled))
        sleep.stop(); XCTAssertEqual(ends, 1)
    }
    private func destination(_ name: String) -> OutputDestinationConfiguration {
        var value = OutputDestinationConfiguration(name: name, profileID: OutputProfile.audienceID, monitor: nil)
        value.ndi = .init(sourceName: "eucaly " + name); return value
    }
    @MainActor private final class Fixture {
        let store: OutputProfileStore
        let ndi = RecordingNetworkOutput()
        let outputs: OutputCoordinator
        let session: PresentationSession
        let lyrics: UUID, media: UUID, native: UUID
        private let opened = OpenCounter()
        var nativeOpens: Int { opened.count }
        init() {
            let monitor = ProjectionMonitor(id: 1, identity: UUID().uuidString, name: "Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
            let displays = ProjectionDisplayManager(displays: { [monitor] }); displays.select(monitor.target)
            store = OutputProfileStore(monitor: monitor.target); native = store.document.destinations[0].id
            var a = OutputDestinationConfiguration(name: "Lyrics", profileID: OutputProfile.audienceID, monitor: nil)
            a.ndi = .init(sourceName: "eucaly Lyrics"); lyrics = a.id
            var b = OutputDestinationConfiguration(name: "Media", profileID: OutputProfile.audienceID, monitor: nil)
            b.ndi = .init(sourceName: "eucaly Media"); media = b.id
            store.edit { $0.destinations[0].enabled = false; $0.destinations += [a, b] }
            let opened = opened
            outputs = OutputCoordinator(profiles: store, displays: displays, network: ndi, driverFactory: { opened.count += 1; return FakeOutputDriver() })
            session = PresentationSession(projectionDisplays: displays, outputCoordinator: outputs)
        }
    }
    private final class OpenCounter { var count = 0 }
}

@MainActor
final class RecordingNetworkOutput: NetworkOutputDriving {
    var stateChanged: ((UUID, NetworkOutputState) -> Void)?
    var activeIDs: Set<UUID> = []
    var starts: [UUID] = []
    var snapshots: [OutputContentSnapshot] = []
    var routedSnapshots: [UUID: OutputContentSnapshot] = [:]
    private var states: [UUID: NetworkOutputState] = [:]
    private var settings: [UUID: NetworkOutputSettings] = [:]
    private var technologies: [UUID: NetworkOutputTechnology] = [:]
    private var performanceNotices: [UUID: String] = [:]
    func state(_ id: UUID) -> NetworkOutputState { states[id] ?? .stopped }
    func performanceNotice(_ id: UUID) -> String? { activeIDs.contains(id) ? performanceNotices[id] : nil }
    func reportPerformance(_ notice: String?, id: UUID) { performanceNotices[id] = notice; stateChanged?(id, state(id)) }
    func start(_ destination: OutputDestinationConfiguration) -> Bool {
        guard let next = destination.networkSettings else { return false }
        if !activeIDs.contains(destination.id) { starts.append(destination.id) }
        settings[destination.id] = next
        technologies[destination.id] = destination.networkTechnology
        activeIDs.insert(destination.id); states[destination.id] = .publishing; return true
    }
    func stop(_ id: UUID) { activeIDs.remove(id); states[id] = .stopped }
    func fail(_ id: UUID) { activeIDs.remove(id); states[id] = .failed("Injected failure"); stateChanged?(id, state(id)) }
    func reconcile(_ document: OutputProfileDocument) {
        for id in activeIDs {
            guard let row = document.destinations.first(where: { $0.id == id && $0.enabled }), let next = row.networkSettings, row.networkTechnology == technologies[id],
                  let old = settings[id], !next.requiresRestart(comparedTo: old) else { stop(id); continue }
        }
    }
    func publish(_ snapshot: OutputContentSnapshot, document: OutputProfileDocument, media: OutputMediaRuntime, audioSession: PresentationSession?) {
        let targets = document.destinations.filter { activeIDs.contains($0.id) }
        if !targets.isEmpty { snapshots.append(snapshot) }
        for target in targets { routedSnapshots[target.id] = snapshot }
    }
}
