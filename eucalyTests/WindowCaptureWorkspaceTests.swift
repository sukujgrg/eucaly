import XCTest
import CoreGraphics
import Combine
import ScreenCaptureKit
@testable import eucaly

@MainActor
final class WindowCaptureWorkspaceTests: XCTestCase {
    private let windowID: CGWindowID = 901

    func testQueuedPickerCancellationCannotReplaceItsRequestingWorkspace() async throws {
        let picker = PickerDriver(), manager = selectedWindowManager(pickerDriver: picker)
        let owner = UUID(), nextOwner = UUID()
        XCTAssertTrue(manager.presentWindowPicker(workspaceID: owner))
        let original = try XCTUnwrap(manager.pendingPickerRequest)
        let observer = try XCTUnwrap(picker.observer)
        let cancelled = expectation(description: "Cancellation retires its original presentation")
        picker.didRemove = { cancelled.fulfill() }

        // The observer has received A's cancellation, but its MainActor task
        // cannot run until this synchronous operator action finishes.
        observer.contentSharingPicker(.shared, didCancelFor: nil)

        XCTAssertFalse(manager.presentWindowPicker(workspaceID: nextOwner))
        XCTAssertEqual(picker.presentations, 1)
        XCTAssertEqual(manager.pendingPickerRequest, original)
        XCTAssertTrue(manager.hasPickedWindow(windowID))

        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertNil(manager.pendingPickerRequest)
        XCTAssertTrue(manager.hasPickedWindow(windowID))
        XCTAssertEqual(picker.deactivations, 0, "Cancellation must retain existing source approval.")
        XCTAssertTrue(manager.presentWindowPicker(workspaceID: nextOwner), "An explicit retry after cancellation is available.")
        XCTAssertEqual(manager.pendingPickerRequest?.workspaceID, nextOwner)
        let retried = expectation(description: "Retry can also be cancelled")
        picker.didRemove = { retried.fulfill() }
        try XCTUnwrap(picker.observer).contentSharingPicker(.shared, didCancelFor: nil)
        await fulfillment(of: [retried], timeout: 2)
    }

    func testQueuedPickerStartFailureCannotReplaceItsRequestingWorkspace() async throws {
        let picker = PickerDriver(), manager = selectedWindowManager(pickerDriver: picker)
        let owner = UUID(), nextOwner = UUID()
        var notices: [WindowCaptureIssue] = []
        let observation = manager.issues.sink { notices.append($0) }
        defer { observation.cancel() }
        XCTAssertTrue(manager.presentWindowPicker(workspaceID: owner))
        let original = try XCTUnwrap(manager.pendingPickerRequest)
        let observer = try XCTUnwrap(picker.observer)
        let failed = expectation(description: "Start failure retires its original presentation")
        picker.didRemove = { failed.fulfill() }

        observer.contentSharingPickerStartDidFailWithError(NSError(domain: "WindowCaptureWorkspaceTests", code: 2))

        XCTAssertFalse(manager.presentWindowPicker(workspaceID: nextOwner))
        XCTAssertEqual(manager.pendingPickerRequest, original)
        XCTAssertTrue(manager.hasPickedWindow(windowID))
        XCTAssertEqual(notices.map(\.workspaceID), [nextOwner], "A blocked request reports only to its own controls.")

        await fulfillment(of: [failed], timeout: 2)
        XCTAssertNil(manager.pendingPickerRequest)
        XCTAssertTrue(manager.hasPickedWindow(windowID))
        XCTAssertEqual(notices.map(\.workspaceID), [nextOwner, owner], "The queued error must report to the original requester.")
        XCTAssertTrue(manager.presentWindowPicker(workspaceID: nextOwner))
        let retried = expectation(description: "Retry after failure remains cancellable")
        picker.didRemove = { retried.fulfill() }
        try XCTUnwrap(picker.observer).contentSharingPicker(.shared, didCancelFor: nil)
        await fulfillment(of: [retried], timeout: 2)
    }

    func testQueuedSelectionKeepsItsOriginalWorkspaceAndLeavesCurrentAndOutputIntact() async throws {
        let monitor = ProjectionMonitor(id: 42, identity: UUID().uuidString, name: "Synthetic",
                                        frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let f = try Fixture(monitor: monitor)
        defer { f.outputs.stopAllOutputs() }
        f.a.setSlides(LyricsParser.parseDocument("Verse\nA Current").slides)
        f.b.setSlides(LyricsParser.parseDocument("Verse\nB Current").slides)
        f.a.showSlides()
        // setSlides/Show schedule a passive publication on the main queue.
        // Finish those earlier transactions before measuring picker effects.
        let settled = expectation(description: "Initial Current and output publications finish")
        DispatchQueue.main.async { settled.fulfill() }
        await fulfillment(of: [settled], timeout: 2)
        let aCurrent = f.a.currentSlideID, bCurrent = f.b.currentSlideID
        let accepted = f.outputs.program(f.a.outputSourceID).snapshot
        XCTAssertEqual(accepted.localMedia?.id, aCurrent)
        let picker = PickerDriver(), manager = selectedWindowManager(pickerDriver: picker)
        defer { manager.releaseUnusedWindowSelection(isRetained: { _ in false }) }
        let selected = expectation(description: "Original request receives its picked window")
        var selections: [WindowCapturePickerRouting.Selection] = []
        let observation = manager.windowPickerSelections.sink { result in
            selections.append(result)
            selected.fulfill()
        }
        defer { observation.cancel() }

        XCTAssertTrue(manager.presentWindowPicker(workspaceID: f.a.outputSourceID))
        let original = try XCTUnwrap(manager.pendingPickerRequest)
        let observer = try XCTUnwrap(picker.observer)
        observer.contentSharingPicker(.shared, didUpdateWith: SCContentFilter(), for: nil)
        observer.contentSharingPicker(.shared, didCancelFor: nil)
        observer.contentSharingPickerStartDidFailWithError(NSError(domain: "WindowCaptureWorkspaceTests", code: 4))
        XCTAssertFalse(manager.presentWindowPicker(workspaceID: f.b.outputSourceID))
        XCTAssertEqual(manager.pendingPickerRequest, original)

        await fulfillment(of: [selected], timeout: 2)
        XCTAssertNil(manager.pendingPickerRequest)
        XCTAssertEqual(selections.map(\.workspaceID), [f.a.outputSourceID])
        XCTAssertEqual(selections.map(\.windowID), [902])
        XCTAssertEqual(manager.windows.map(\.windowID), [902])
        XCTAssertEqual(f.a.currentSlideID, aCurrent)
        XCTAssertEqual(f.b.currentSlideID, bCurrent)
        let after = f.outputs.program(f.a.outputSourceID).snapshot
        XCTAssertEqual(after.current, accepted.current)
        XCTAssertEqual(after.revision, accepted.revision)
        XCTAssertEqual(after.documentRevision, accepted.documentRevision)
        XCTAssertEqual(after.source, accepted.source)
        XCTAssertEqual(after.visible, accepted.visible)
        XCTAssertEqual(after.localMedia?.id, accepted.localMedia?.id)
        XCTAssertEqual(after.localMedia?.lines, accepted.localMedia?.lines)
        XCTAssertNil(after.localMedia?.captureWindowID)
        XCTAssertTrue(f.outputs.isPresenting(workspace: f.a.outputSourceID))
    }

    func testRetiredObserverCannotSelectCancelOrFailAnotherWorkspacesPicker() async throws {
        let picker = PickerDriver()
        var resolutions = 0
        let manager = ScreenCaptureManager(pickerDriver: picker, resolvePickedWindows: { _ in
            resolutions += 1
            return [.init(id: 902, windowID: 902, title: "New Window", appName: "Test", appBundleIdentifier: nil,
                          frame: CGRect(x: 0, y: 0, width: 640, height: 480))]
        })
        defer { manager.releaseUnusedWindowSelection(isRetained: { _ in false }) }
        let firstOwner = UUID(), nextOwner = UUID()
        var notices: [WindowCaptureIssue] = []
        let noticeObservation = manager.issues.sink { notices.append($0) }
        defer { noticeObservation.cancel() }
        XCTAssertTrue(manager.presentWindowPicker(workspaceID: firstOwner))
        let retired = try XCTUnwrap(picker.observer)
        let cancelled = expectation(description: "First presentation ends")
        picker.didRemove = { cancelled.fulfill() }
        retired.contentSharingPicker(.shared, didCancelFor: nil)
        await fulfillment(of: [cancelled], timeout: 2)
        XCTAssertTrue(manager.presentWindowPicker(workspaceID: nextOwner))
        let nextRequest = try XCTUnwrap(manager.pendingPickerRequest)
        let nextObserver = try XCTUnwrap(picker.observer)
        let selected = expectation(description: "Second presentation receives only its own selection")
        var selections: [WindowCapturePickerRouting.Selection] = []
        let selectionObservation = manager.windowPickerSelections.sink { result in
            selections.append(result)
            selected.fulfill()
        }
        defer { selectionObservation.cancel() }

        // Invoke the actual old SDK observer after B has started, including a
        // late result, cancel and start error. None may consume B's lifetime.
        retired.contentSharingPicker(.shared, didUpdateWith: SCContentFilter(), for: nil)
        retired.contentSharingPicker(.shared, didCancelFor: nil)
        retired.contentSharingPickerStartDidFailWithError(NSError(domain: "WindowCaptureWorkspaceTests", code: 3))
        XCTAssertEqual(manager.pendingPickerRequest, nextRequest)
        XCTAssertEqual(resolutions, 0)
        XCTAssertTrue(selections.isEmpty)
        XCTAssertTrue(notices.isEmpty)
        picker.didRemove = nil
        nextObserver.contentSharingPicker(.shared, didUpdateWith: SCContentFilter(), for: nil)
        await fulfillment(of: [selected], timeout: 2)

        XCTAssertNil(manager.pendingPickerRequest)
        XCTAssertEqual(resolutions, 1)
        XCTAssertEqual(selections.map(\.workspaceID), [nextOwner])
        XCTAssertTrue(notices.isEmpty)
    }

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

    func testPickerCompletionRevalidatesOutputProtectionBeforeReplacingApprovedSource() async throws {
        let picker = PickerDriver(), protection = PickerProtection()
        let manager = selectedWindowManager(pickerDriver: picker)
        let owner = UUID()
        XCTAssertTrue(manager.presentWindowPicker(workspaceID: owner, replacementProblem: { protection.problem }))
        let request = try XCTUnwrap(manager.pendingPickerRequest)
        let observer = try XCTUnwrap(picker.observer)
        var notices: [WindowCaptureIssue] = []
        var selections: [WindowCapturePickerRouting.Selection] = []
        let observation = manager.issues.sink { notices.append($0) }
        let selectionObservation = manager.windowPickerSelections.sink { selections.append($0) }
        defer { observation.cancel(); selectionObservation.cancel() }
        let rejected = expectation(description: "Output protection retires the selected request")
        picker.didRemove = { rejected.fulfill() }

        // Another workspace can explicitly start its retained Current while
        // the system picker is open. Its source still cannot be replaced.
        protection.problem = "A workspace started using the picked window. Stop its output before picking another window."
        observer.contentSharingPicker(.shared, didUpdateWith: SCContentFilter(), for: nil)
        await fulfillment(of: [rejected], timeout: 2)

        XCTAssertNil(manager.pendingPickerRequest)
        XCTAssertTrue(manager.hasPickedWindow(windowID))
        XCTAssertTrue(selections.isEmpty)
        XCTAssertEqual(notices.first?.workspaceID, owner)
        XCTAssertEqual(notices.first?.message, protection.problem)
        XCTAssertFalse(manager.acceptsPickerSelection(for: request))
        XCTAssertEqual(notices.count, 1, "A stale result must not publish a second notice")
        observer.contentSharingPickerStartDidFailWithError(NSError(domain: "WindowCaptureWorkspaceTests", code: 5))
        XCTAssertEqual(notices.count, 1)
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
        let picker = PickerDriver()
        let manager = selectedWindowManager(captureConsumerCount: { _ in 1 }, pickerDriver: picker)
        f.a.setSlides([windowSlide()])
        f.a.showSlides()
        f.outputs.program(f.b.outputSourceID).flow.setPreviewSlides([windowSlide()])
        XCTAssertTrue(manager.presentWindowPicker(workspaceID: f.b.outputSourceID))
        let failed = expectation(description: "Failed presentation releases its request")
        picker.didRemove = { failed.fulfill() }
        try XCTUnwrap(picker.observer).contentSharingPickerStartDidFailWithError(NSError(domain: "WindowCaptureWorkspaceTests", code: 1))
        await fulfillment(of: [failed], timeout: 2)

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

    private func selectedWindowManager(captureConsumerCount: (@MainActor (CGWindowID) -> Int)? = nil,
                                       pickerDriver: PickerDriver? = nil) -> ScreenCaptureManager {
        let manager: ScreenCaptureManager
        if let pickerDriver {
            manager = ScreenCaptureManager(pickerDriver: pickerDriver, resolvePickedWindows: { _ in
                [.init(id: 902, windowID: 902, title: "New Window", appName: "Test", appBundleIdentifier: nil,
                       frame: CGRect(x: 0, y: 0, width: 640, height: 480))]
            }, captureConsumerCount: captureConsumerCount)
        } else {
            manager = captureConsumerCount.map { ScreenCaptureManager(captureConsumerCount: $0) } ?? ScreenCaptureManager()
        }
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
    private final class PickerDriver: WindowCapturePickerPresenting {
        private(set) var observer: (any SCContentSharingPickerObserver)?
        private(set) var presentations = 0
        private(set) var deactivations = 0
        var didRemove: (() -> Void)?

        func present(observer: any SCContentSharingPickerObserver) {
            XCTAssertNil(self.observer, "Only one presentation can be registered.")
            self.observer = observer
            presentations += 1
        }
        func remove(observer: any SCContentSharingPickerObserver) {
            XCTAssertTrue(self.observer as AnyObject? === observer as AnyObject)
            self.observer = nil
            didRemove?()
        }
        func deactivate() { deactivations += 1 }
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
