import AppKit
import XCTest
@testable import eucaly

@MainActor
final class ProjectionSleepPreventionTests: XCTestCase {
    func testActivityOptionsAndBalancedTokensAcrossRepeatedStartStopAndTeardown() {
        let recorder = ActivityRecorder()
        var protection: ProjectionSleepPrevention? = recorder.makeProtection()
        XCTAssertTrue(recorder.begun.isEmpty)
        protection?.stop()
        protection?.start()
        protection?.start()
        XCTAssertEqual(recorder.begun.count, 1)
        XCTAssertTrue(recorder.ended.isEmpty)
        protection?.stop()
        protection?.stop()
        XCTAssertEqual(recorder.ended, recorder.begun.map { ObjectIdentifier($0) })
        protection?.start()
        protection = nil
        XCTAssertEqual(recorder.begun.count, 2)
        XCTAssertEqual(recorder.ended, recorder.begun.map { ObjectIdentifier($0) })
        for options in recorder.options {
            XCTAssertTrue(options.contains(.userInitiated))
            XCTAssertTrue(options.contains(.idleSystemSleepDisabled))
            XCTAssertTrue(options.contains(.idleDisplaySleepDisabled))
        }
        XCTAssertTrue(recorder.reasons.allSatisfy { !$0.isEmpty })
    }

    func testIdleCurrentIdentifyAndFailedProjectionNeverStartActivity() {
        let fake = ProjectionMonitor(id: 10, identity: "11111111-1111-1111-1111-111111111111",
                                     name: "Test Monitor", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let displays = ProjectionDisplayManager(displays: { [fake] })
        let recorder = ActivityRecorder()
        let session = PresentationSession(projectionDisplays: displays, sleepPrevention: recorder.makeProtection())
        session.setSlides(LyricsParser.parseDocument("Verse\nCurrent stays private").slides)
        session.setBackgroundVisual(URL(fileURLWithPath: "/tmp/eucaly-test-background.png"))
        displays.identify(fake.target)
        XCTAssertTrue(recorder.begun.isEmpty)
        session.showSlides() // No selected monitor.
        session.toggleBackgroundVisualVisibility()
        XCTAssertFalse(session.isPresenting)
        XCTAssertTrue(displays.select(fake.target))
        session.showSlides() // Synthetic identity has no matching NSScreen.
        XCTAssertFalse(session.isPresenting)
        let owner = UUID()
        displays.lock(fake.target, owner: owner)
        session.showSlides() // Another session owns the output.
        displays.unlock(owner: owner)
        session.stopPresentation()
        XCTAssertTrue(recorder.begun.isEmpty)
        XCTAssertTrue(recorder.ended.isEmpty)
    }

    func testHiddenSlidesClearAndLayerChangesRetainActivityUntilStop() throws {
        let recorder = ActivityRecorder()
        let (session, _, _) = try makeLiveSession(recorder.makeProtection())
        defer { session.stopPresentation() }
        session.setSlides(LyricsParser.parseDocument("Verse\nKeep presenting").slides)
        session.showSlides()
        XCTAssertTrue(session.isPresenting)
        XCTAssertEqual(recorder.begun.count, 1)
        session.hideSlides()
        session.clearSlides()
        session.setBackgroundVisual(nil)
        session.clearBackgroundAudio()
        session.setOverlayMode(.clock)
        session.showSlides()
        XCTAssertEqual(recorder.begun.count, 1)
        XCTAssertTrue(recorder.ended.isEmpty, "An open output must remain awake even when blank.")
        session.stopPresentation()
        session.stopPresentation()
        XCTAssertEqual(recorder.ended.count, 1)
        session.showSlides()
        XCTAssertEqual(recorder.begun.count, 2)
        NotificationCenter.default.post(name: .stopProjection, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(session.isPresenting)
        XCTAssertEqual(recorder.ended, recorder.begun.map { ObjectIdentifier($0) })
    }

    func testBackgroundOnlyOutputRetainsActivityWhenHiddenAndReleasesOnNativeClose() throws {
        let recorder = ActivityRecorder()
        let (session, _, _) = try makeLiveSession(recorder.makeProtection())
        defer { session.stopPresentation() }
        let image = try temporaryBackgroundImage()
        defer { try? FileManager.default.removeItem(at: image) }
        session.setBackgroundVisual(image)
        session.toggleBackgroundVisualVisibility()
        XCTAssertTrue(session.isPresenting)
        XCTAssertFalse(session.areSlidesVisible)
        XCTAssertEqual(recorder.begun.count, 1)
        session.toggleBackgroundVisualVisibility()
        XCTAssertFalse(session.isBackgroundVisualVisible)
        XCTAssertTrue(recorder.ended.isEmpty)
        let windowID = try XCTUnwrap(session.outputSnapshot.projectionWindowID)
        let window = try XCTUnwrap(NSApp.windows.first { $0.windowNumber == Int(windowID) })
        window.close()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertFalse(session.isPresenting)
        XCTAssertEqual(recorder.ended, recorder.begun.map { ObjectIdentifier($0) })
    }

    func testDisconnectMirroringAndAmbiguousIdentityReleaseActivityWithoutAutomaticRestart() throws {
        let recorder = ActivityRecorder()
        let (session, inventory, actual) = try makeLiveSession(recorder.makeProtection())
        defer { session.stopPresentation() }
        var mirrored = actual
        mirrored.isMirrored = true
        let duplicate = ProjectionMonitor(id: actual.id &+ 100, identity: actual.identity,
                                          name: actual.name, frame: actual.frame)
        for unavailable in [[], [mirrored], [actual, duplicate]] {
            session.showSlides()
            XCTAssertTrue(session.isPresenting)
            inventory.displays = unavailable
            session.projectionDisplays.refresh()
            XCTAssertFalse(session.isPresenting)
            XCTAssertEqual(recorder.ended, recorder.begun.map { ObjectIdentifier($0) })
            let started = recorder.begun.count
            inventory.displays = [actual]
            session.projectionDisplays.refresh()
            XCTAssertFalse(session.isPresenting)
            XCTAssertEqual(recorder.begun.count, started, "Reconnect alone must not hold a sleep activity.")
        }
        XCTAssertEqual(recorder.begun.count, 3)
    }

    func testNativeSystemAndDisplaySleepAssertionsFollowTheProjectionWindow() throws {
        let (session, _, _) = try makeLiveSession(ProjectionSleepPrevention())
        defer { session.stopPresentation() }
        let assertionsBefore = try currentPowerAssertions()
        XCTAssertFalse(assertionsBefore.contains { $0.contains("Presenting eucaly output") })
        session.showSlides()
        session.hideSlides()
        let assertionsWhileHidden = try currentPowerAssertions()
        for kind in ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep"] {
            XCTAssertTrue(assertionsWhileHidden.contains { $0.contains(kind) && $0.contains("Presenting eucaly output") },
                          "An open projection must hold the native \(kind) assertion.")
        }
        session.stopPresentation()
        XCTAssertFalse(try currentPowerAssertions().contains { $0.contains("Presenting eucaly output") })
    }

    private func makeLiveSession(_ protection: ProjectionSleepPrevention) throws
        -> (PresentationSession, DisplayInventory, ProjectionMonitor) {
        let inventory = DisplayInventory(ProjectionScreenResolver.currentMonitors())
        let displays = ProjectionDisplayManager(displays: { inventory.displays })
        guard let actual = inventory.displays.first(where: {
            displays.problem(for: $0.target) == nil && ProjectionScreenResolver.screen(for: $0) != nil
        }) else {
            throw XCTSkip("Optional native-window check: no usable display. Activity lifecycle and failed-start tests still run without monitors.")
        }
        XCTAssertTrue(displays.select(actual.target))
        return (PresentationSession(projectionDisplays: displays, sleepPrevention: protection), inventory, actual)
    }

    private func temporaryBackgroundImage() throws -> URL {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.black, atX: 0, y: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-sleep-test-\(UUID()).png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    private func currentPowerAssertions() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        let ownPID = "pid \(ProcessInfo.processInfo.processIdentifier)("
        return String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).filter { $0.contains(ownPID) }
    }
}

nonisolated private final class ActivityRecorder {
    var begun: [NSObject] = []
    var ended: [ObjectIdentifier] = []
    var options: [ProcessInfo.ActivityOptions] = []
    var reasons: [String] = []

    func makeProtection() -> ProjectionSleepPrevention {
        ProjectionSleepPrevention(beginActivity: { [self] options, reason in
            self.options.append(options)
            reasons.append(reason)
            let token = NSObject()
            begun.append(token)
            return token
        }, endActivity: { [self] in ended.append(ObjectIdentifier($0)) })
    }
}

@MainActor
private final class DisplayInventory {
    var displays: [ProjectionMonitor]
    init(_ displays: [ProjectionMonitor]) { self.displays = displays }
}
