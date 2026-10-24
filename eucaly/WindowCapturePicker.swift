import Foundation
import CoreGraphics
import ScreenCaptureKit

nonisolated enum WindowCapturePickerRouting {
    struct Request: Equatable, Sendable {
        let id = UUID()
        let workspaceID: UUID
    }

    struct Selection: Sendable {
        let workspaceID: UUID
        let windowID: CGWindowID
    }
}

/// The system API has no identifier for a new-stream picker presentation.
/// Its observer is registered for exactly one app-owned request lifetime.
@MainActor
protocol WindowCapturePickerPresenting: AnyObject {
    func present(observer: any SCContentSharingPickerObserver)
    func remove(observer: any SCContentSharingPickerObserver)
    func deactivate()
}

@MainActor
final class SystemWindowCapturePicker: WindowCapturePickerPresenting {
    private var active = false

    func present(observer: any SCContentSharingPickerObserver) {
        let picker = SCContentSharingPicker.shared
        if !active {
            var config = SCContentSharingPickerConfiguration()
            config.allowedPickerModes = .singleWindow
            config.allowsChangingSelectedContent = false
            picker.defaultConfiguration = config
            picker.maximumStreamCount = 1
            picker.isActive = true
            active = true
        }
        picker.add(observer)
        picker.present(using: .window)
    }

    func remove(observer: any SCContentSharingPickerObserver) {
        guard active else { return }
        SCContentSharingPicker.shared.remove(observer)
    }

    func deactivate() {
        guard active else { return }
        SCContentSharingPicker.shared.isActive = false
        active = false
    }
}

/// SDK callbacks may arrive off the main actor or already be queued when this
/// observer is removed. Both their request identity and single terminal-event
/// admission are fixed here, before dispatching any work to the manager.
nonisolated final class WindowCapturePickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    // The SDK filter is retained unchanged and read only on the main actor.
    enum Event: @unchecked Sendable {
        case selection(SCContentFilter)
        case cancelled
        case failed(any Error)
    }

    let request: WindowCapturePickerRouting.Request
    private let receive: @Sendable (WindowCapturePickerRouting.Request, Event) -> Void
    private let lock = NSLock()
    private var finished = false

    init(request: WindowCapturePickerRouting.Request,
         receive: @escaping @Sendable (WindowCapturePickerRouting.Request, Event) -> Void) {
        self.request = request
        self.receive = receive
        super.init()
    }

    func invalidate() {
        lock.withLock { finished = true }
    }

    private func finish(_ event: Event) {
        let admitted = lock.withLock {
            guard !finished else { return false }
            finished = true
            return true
        }
        if admitted { receive(request, event) }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        // Our explicit presentation creates a new stream. A callback associated
        // with an existing stream cannot complete that request.
        guard stream == nil else { return }
        finish(.cancelled)
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        guard stream == nil else { return }
        finish(.selection(filter))
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        finish(.failed(error))
    }
}
