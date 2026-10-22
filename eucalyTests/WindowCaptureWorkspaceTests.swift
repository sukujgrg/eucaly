import XCTest
import CoreGraphics
import Combine
@testable import eucaly

@MainActor
final class WindowCaptureWorkspaceTests: XCTestCase {
    private let windowID: CGWindowID = 901

    func testBlockedPickerPreservesApprovedSourceAndPendingRequestWithoutOpeningSystemPicker() throws {
        let manager = selectedWindowManager()
        let old = manager.beginPickerRequest(workspaceID: UUID())
        let requester = UUID(), reason = "Stop the live window output before picking another window."
        var notices: [WindowCaptureIssue] = []
        let observation = manager.issues.sink { notices.append($0) }
        defer { observation.cancel() }

        XCTAssertFalse(manager.presentWindowPicker(workspaceID: requester, replacementProblem: { reason }))

        XCTAssertEqual(manager.pendingPickerRequest, old)
        XCTAssertTrue(manager.hasPickedWindow(windowID))
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.workspaceID, requester)
        XCTAssertEqual(notices.first?.message, reason)
    }

    func testPickerCompletionRevalidatesOutputProtectionBeforeReplacingApprovedSource() throws {
        let manager = selectedWindowManager(), protection = PickerProtection()
        let owner = UUID()
        let request = manager.beginPickerRequest(workspaceID: owner, replacementProblem: { protection.problem })
        XCTAssertTrue(manager.acceptsPickerSelection(for: request))
        var notices: [WindowCaptureIssue] = []
        let observation = manager.issues.sink { notices.append($0) }
        defer { observation.cancel() }

        // Another workspace can explicitly start its retained Current while
        // the system picker is open. Its source still cannot be replaced.
        protection.problem = "A workspace started using the picked window. Stop its output before picking another window."
        XCTAssertFalse(manager.acceptsPickerSelection(for: request))

        XCTAssertNil(manager.pendingPickerRequest)
        XCTAssertTrue(manager.hasPickedWindow(windowID))
        XCTAssertEqual(notices.first?.workspaceID, owner)
        XCTAssertEqual(notices.first?.message, protection.problem)
        XCTAssertFalse(manager.acceptsPickerSelection(for: request))
        XCTAssertEqual(notices.count, 1, "A stale result must not publish a second notice")
    }

    func testClearingOnePreviewRetainsAnotherWorkspacesCurrentWithoutPreparingClosedWorkspace() throws {
        let f = try Fixture()
        let manager = selectedWindowManager()
        let closedMedia = f.outputs.preparedMedia(workspace: f.closedWorkspaceID)
        f.a.setSlides([windowSlide()])
        f.outputs.program(f.b.outputSourceID).flow.setPreviewSlides([windowSlide()])

        // Workspace B's New Lyrics / clear Preview must not revoke A's source.
        f.outputs.program(f.b.outputSourceID).flow.clearPreviewDocument()
        f.outputs.releaseUnusedWindowCaptureSelection(using: manager)

        XCTAssertTrue(manager.hasPickedWindow(windowID))
        XCTAssertEqual(f.a.currentSlide?.captureWindowID, windowID)
        XCTAssertNil(f.outputs.preparedSession(workspace: f.closedWorkspaceID))
        XCTAssertTrue(f.outputs.preparedMedia(workspace: f.closedWorkspaceID) === closedMedia)
        XCTAssertFalse(f.outputs.isRunning)

        f.a.clearSlides()
        f.outputs.releaseUnusedWindowCaptureSelection(using: manager)
        XCTAssertFalse(manager.hasPickedWindow(windowID))
    }

    func testClearingSidebarSelectionRetainsOtherWorkspacesPreviewAndCurrent() throws {
        let f = try Fixture()
        let manager = selectedWindowManager()
        let aFlow = f.outputs.program(f.a.outputSourceID).flow
        let bFlow = f.outputs.program(f.b.outputSourceID).flow
        aFlow.setPreviewSlides([windowSlide()])
        bFlow.setPreviewSlides([windowSlide()])
        f.b.setSlides([windowSlide()])

        // Sidebar removal clears only B's matching documents before cleanup.
        bFlow.clearPreviewDocument()
        f.b.clearSlides()
        f.outputs.releaseUnusedWindowCaptureSelection(using: manager)
        XCTAssertTrue(manager.hasPickedWindow(windowID))
        XCTAssertEqual(aFlow.previewSlides.first?.captureWindowID, windowID)

        aFlow.clearPreviewDocument()
        f.outputs.releaseUnusedWindowCaptureSelection(using: manager)
        XCTAssertFalse(manager.hasPickedWindow(windowID))
    }

    func testHiddenAcceptedSnapshotRetainsWindowAfterCurrentChanges() throws {
        let monitor = ProjectionMonitor(id: 41, identity: UUID().uuidString, name: "Synthetic",
                                        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let f = try Fixture(monitor: monitor)
        defer { f.outputs.stopAllOutputs() }
        let manager = selectedWindowManager()
        f.a.setSlides([windowSlide()])
        f.a.showSlides()
        f.a.hideSlides()
        f.a.setSlides(LyricsParser.parseDocument("Verse\nReplacement").slides)

        f.outputs.releaseUnusedWindowCaptureSelection(using: manager)
        XCTAssertTrue(manager.hasPickedWindow(windowID))
        XCTAssertFalse(f.outputs.program(f.a.outputSourceID).snapshot.visible)
        XCTAssertEqual(f.outputs.program(f.a.outputSourceID).snapshot.localMedia?.captureWindowID, windowID)
        XCTAssertNil(f.a.currentSlide?.captureWindowID)

        f.outputs.stop(for: f.a)
        f.outputs.releaseUnusedWindowCaptureSelection(using: manager)
        XCTAssertFalse(manager.hasPickedWindow(windowID))
    }

    func testUnusedSelectionWaitsForEveryCaptureConsumer() throws {
        let f = try Fixture()
        let consumers = ConsumerCount(2)
        let manager = selectedWindowManager(captureConsumerCount: { _ in consumers.value })

        f.outputs.releaseUnusedWindowCaptureSelection(using: manager)
        XCTAssertTrue(manager.hasPickedWindow(windowID))
        consumers.value = 1
        manager.captureConsumersDidChange(windowID: windowID)
        XCTAssertTrue(manager.hasPickedWindow(windowID))
        consumers.value = 0
        manager.captureConsumersDidChange(windowID: windowID)
        XCTAssertFalse(manager.hasPickedWindow(windowID))
    }

    func testDeferredConsumerReleaseRechecksNewWorkspaceContent() throws {
        let f = try Fixture()
        let consumers = ConsumerCount(1)
        let manager = selectedWindowManager(captureConsumerCount: { _ in consumers.value })
        f.outputs.releaseUnusedWindowCaptureSelection(using: manager)

        // A new load before the departing view's final release keeps its source.
        f.a.setSlides([windowSlide()])
        consumers.value = 0
        manager.captureConsumersDidChange(windowID: windowID)
        XCTAssertTrue(manager.hasPickedWindow(windowID))

        f.a.clearSlides()
        f.outputs.releaseUnusedWindowCaptureSelection(using: manager)
        XCTAssertFalse(manager.hasPickedWindow(windowID))
    }

    func testCleanupPreservesPendingPickerAndInvalidatesOlderDeferredRelease() throws {
        let f = try Fixture()
        let consumers = ConsumerCount(1)
        let manager = selectedWindowManager(captureConsumerCount: { _ in consumers.value })
        f.outputs.releaseUnusedWindowCaptureSelection(using: manager)
        let request = manager.beginPickerRequest(workspaceID: f.b.outputSourceID)

        consumers.value = 0
        manager.captureConsumersDidChange(windowID: windowID)
        f.outputs.releaseUnusedWindowCaptureSelection(using: manager)

        XCTAssertTrue(manager.hasPickedWindow(windowID))
        XCTAssertEqual(manager.pendingPickerRequest, request)
        XCTAssertNil(f.outputs.preparedSession(workspace: f.closedWorkspaceID))
        XCTAssertFalse(f.outputs.isRunning)
    }

    func testFailedPickerPreservesAnotherWorkspacesApprovedLiveWindow() async throws {
        let monitor = ProjectionMonitor(id: 42, identity: UUID().uuidString, name: "Synthetic",
                                        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let f = try Fixture(monitor: monitor)
        defer { f.outputs.stopAllOutputs() }
        let manager = selectedWindowManager(captureConsumerCount: { _ in 1 })
        f.a.setSlides([windowSlide()])
        f.a.showSlides()
        f.outputs.program(f.b.outputSourceID).flow.setPreviewSlides([windowSlide()])
        let request = manager.beginPickerRequest(workspaceID: f.b.outputSourceID)

        manager.contentSharingPickerStartDidFailWithError(NSError(domain: "WindowCaptureWorkspaceTests", code: 1))
        let deadline = Date().addingTimeInterval(2)
        while manager.pendingPickerRequest == request, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }

        XCTAssertNil(manager.pendingPickerRequest, "Finish the failed request without revoking prior approval")
        XCTAssertTrue(manager.hasPickedWindow(windowID))
        XCTAssertEqual(f.a.currentSlide?.captureWindowID, windowID)
        XCTAssertEqual(f.outputs.program(f.a.outputSourceID).snapshot.localMedia?.captureWindowID, windowID)
        XCTAssertEqual(f.outputs.program(f.b.outputSourceID).flow.previewSlides.first?.captureWindowID, windowID)
        XCTAssertTrue(f.outputs.isPresenting(workspace: f.a.outputSourceID))
    }

    private func windowSlide() -> Slide {
        Slide(index: 0, lines: [], label: "Picked Window", videoURL: nil, pdfURL: nil,
              pdfPageIndex: nil, imageURL: nil, captureWindowID: windowID)
    }

    private func selectedWindowManager(captureConsumerCount: (@MainActor (CGWindowID) -> Int)? = nil) -> ScreenCaptureManager {
        let manager = captureConsumerCount.map { ScreenCaptureManager(captureConsumerCount: $0) } ?? ScreenCaptureManager()
        manager.windows = [.init(id: windowID, windowID: windowID, title: "Picked Window", appName: "Test",
                                 appBundleIdentifier: nil, frame: CGRect(x: 0, y: 0, width: 640, height: 480))]
        return manager
    }

    @MainActor
    private final class ConsumerCount {
        var value: Int
        init(_ value: Int) { self.value = value }
    }

    @MainActor
    private final class PickerProtection {
        var problem: String?
    }

    @MainActor
    private struct Fixture {
        let outputs: OutputCoordinator
        let a: PresentationSession
        let b: PresentationSession
        let closedWorkspaceID: UUID

        init(monitor: ProjectionMonitor? = nil) throws {
            let store = OutputProfileStore(monitor: monitor?.target)
            let bID = try XCTUnwrap(store.addWorkspace(name: "Other"))
            closedWorkspaceID = try XCTUnwrap(store.addWorkspace(name: "Closed"))
            let displays = ProjectionDisplayManager(displays: { monitor.map { [$0] } ?? [] })
            outputs = OutputCoordinator(profiles: store, displays: displays, retainsPreparedSessions: true,
                                        driverFactory: { FakeOutputDriver() })
            a = outputs.session(workspace: store.document.workspaces[0].id)
            b = outputs.session(workspace: bID)
        }
    }
}
