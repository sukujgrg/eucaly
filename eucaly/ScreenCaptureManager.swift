import ScreenCaptureKit
import Combine
import AppKit
import CoreGraphics
import CoreVideo

/// The system picker can change application/window focus while it is open.
/// Keep the requesting workspace through asynchronous resolution and reject
/// completions superseded by a newer request or cancellation.
nonisolated struct WindowCapturePickerRouting {
    struct Request: Equatable, Sendable {
        let id = UUID()
        let workspaceID: UUID
    }
    struct Selection: Sendable {
        let workspaceID: UUID
        let windowID: CGWindowID
    }
    private(set) var current: Request?
    @discardableResult mutating func begin(workspaceID: UUID) -> Request {
        let request = Request(workspaceID: workspaceID)
        current = request
        return request
    }
    mutating func complete(_ request: Request, windowID: CGWindowID) -> Selection? {
        guard current == request else { return nil }
        current = nil
        return Selection(workspaceID: request.workspaceID, windowID: windowID)
    }
    mutating func cancel() { current = nil }
}

final class ScreenCaptureManager: NSObject, ObservableObject {
    static let shared = ScreenCaptureManager()

    // MARK: - Properties
    private struct ActiveCapture {
        let stream: SCStream
        let fanout: SharedCaptureOutput
        let start: Task<Void, Error>
        let generation: UUID
    }
    private struct SelectionRelease {
        let generation: UUID
        let isRetained: @MainActor (CGWindowID) -> Bool
    }

    private let sampleQueue = DispatchQueue(label: "eucaly.window-capture.sample", qos: .userInitiated)
    @MainActor var preferredFrameRate: Int = 60
    @MainActor private var activeStreams: [CGWindowID: ActiveCapture] = [:]
    @MainActor private var captureFilters: [CGWindowID: SCContentFilter] = [:]
    @MainActor @Published var windows: [CapturedWindow] = []
    @MainActor let windowPickerSelections = PassthroughSubject<WindowCapturePickerRouting.Selection, Never>()
    @MainActor private var pickerRouting = WindowCapturePickerRouting()
    @MainActor private var selectionGeneration = UUID()
    @MainActor private var pendingSelectionReleases: [CGWindowID: SelectionRelease] = [:]
    @MainActor private var availabilityMonitorTask: Task<Void, Never>?
    private let captureConsumerCount: (@MainActor (CGWindowID) -> Int)?
    private var pickerConfigured = false
    private var pickerObserverRegistered = false

    // MARK: - Data Model
    struct CapturedWindow: Identifiable {
        let id: CGWindowID
        let windowID: CGWindowID
        let title: String
        let appName: String
        let appBundleIdentifier: String?
        let frame: CGRect
    }

    override init() {
        captureConsumerCount = nil
        super.init()
    }

    /// Isolated lifetime checks can provide consumer counts without opening a
    /// picker or constructing a permission-requiring SCStream.
    init(captureConsumerCount: @escaping @MainActor (CGWindowID) -> Int) {
        self.captureConsumerCount = captureConsumerCount
        super.init()
    }

    // MARK: - Picker
    @MainActor
    func presentWindowPicker(workspaceID: UUID) {
        beginPickerRequest(workspaceID: workspaceID)
        configurePickerIfNeeded()
        SCContentSharingPicker.shared.present(using: .window)
    }

    @MainActor
    @discardableResult
    func beginPickerRequest(workspaceID: UUID) -> WindowCapturePickerRouting.Request {
        selectionGeneration = UUID()
        pendingSelectionReleases.removeAll()
        return pickerRouting.begin(workspaceID: workspaceID)
    }

    @MainActor
    var pendingPickerRequest: WindowCapturePickerRouting.Request? { pickerRouting.current }

    @MainActor
    func releaseUnusedWindowSelection(isRetained: @escaping @MainActor (CGWindowID) -> Bool) {
        // Pane cleanup is not cancellation of another workspace's pending pick.
        guard pickerRouting.current == nil else { return }
        for windowID in windows.map(\.windowID) {
            if isRetained(windowID) {
                pendingSelectionReleases[windowID] = nil
                continue
            }
            pendingSelectionReleases[windowID] = SelectionRelease(generation: selectionGeneration, isRetained: isRetained)
            captureConsumersDidChange(windowID: windowID)
        }
    }

    @MainActor
    func captureConsumersDidChange(windowID: CGWindowID) {
        guard let request = pendingSelectionReleases[windowID] else { return }
        guard request.generation == selectionGeneration, pickerRouting.current == nil else {
            pendingSelectionReleases[windowID] = nil
            return
        }
        guard !request.isRetained(windowID) else {
            pendingSelectionReleases[windowID] = nil
            return
        }
        // A departing view may still own a live consumer until SwiftUI finishes
        // dismantling it. Its last release retries this decision synchronously.
        let actualConsumers = activeStreams[windowID]?.fanout.consumerCount ?? 0
        guard actualConsumers == 0, (captureConsumerCount?(windowID) ?? 0) == 0 else { return }
        pendingSelectionReleases[windowID] = nil
        removePickedWindow(windowID: windowID)
    }

    // MARK: - Stream Management
    @MainActor
    func startCapture(
        windowID: CGWindowID,
        ownerID: UUID = UUID(),
        outputHandler: SCStreamOutput
    ) async throws -> SCStream {
        if let existing = activeStreams[windowID] {
            existing.fanout.add(ownerID, output: outputHandler)
            do { try await existing.start.value } catch {
                if activeStreams[windowID]?.generation == existing.generation { activeStreams.removeValue(forKey: windowID) }
                throw error
            }
            guard activeStreams[windowID]?.generation == existing.generation else { throw CancellationError() }
            return existing.stream
        }

        guard let filter = captureFilters[windowID] else {
            throw ScreenCaptureError.windowNotFound
        }

        let info = SCShareableContent.info(for: filter)
        let config = SCStreamConfiguration()
        let sourceScale = max(Double(info.pointPixelScale), 1.0)
        let sourceWidth = max(1, Int((info.contentRect.width * sourceScale).rounded(.up)))
        let sourceHeight = max(1, Int((info.contentRect.height * sourceScale).rounded(.up)))
        let scaleDown = max(
            Double(sourceWidth) / 3840.0,
            Double(sourceHeight) / 2160.0,
            1.0
        )
        config.width = max(1, Int((Double(sourceWidth) / scaleDown).rounded(.down)))
        config.height = max(1, Int((Double(sourceHeight) / scaleDown).rounded(.down)))
        // Display the captured IOSurface directly through Core Animation.
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let fps = normalizedPreferredFrameRate
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 6
        config.showsCursor = true
        config.captureResolution = .best
        config.scalesToFit = true
        config.preservesAspectRatio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        let fanout = SharedCaptureOutput()
        fanout.add(ownerID, output: outputHandler)
        try stream.addStreamOutput(fanout, type: .screen, sampleHandlerQueue: sampleQueue)
        let generation = UUID()
        let start = Task { try await stream.startCapture() }
        activeStreams[windowID] = ActiveCapture(stream: stream, fanout: fanout, start: start, generation: generation)
        do { try await start.value } catch {
            if activeStreams[windowID]?.generation == generation { activeStreams.removeValue(forKey: windowID) }
            throw error
        }
        guard activeStreams[windowID]?.generation == generation else { throw CancellationError() }
        ensureAvailabilityMonitorIfNeeded()
        return stream
    }

    @MainActor
    func stopCapture(windowID: CGWindowID, ownerID: UUID? = nil) async throws {
        guard let activeCapture = activeStreams[windowID] else { return }
        if let ownerID {
            activeCapture.fanout.remove(ownerID)
            guard activeCapture.fanout.isEmpty else { return }
        }
        // Remove before awaiting. Late stop callbacks cannot remove a new stream.
        activeStreams.removeValue(forKey: windowID)
        activeCapture.fanout.removeAll()
        // Recheck retained workspace content before yielding to stream shutdown.
        // Nothing after the await can clear a newly picked window or stream.
        captureConsumersDidChange(windowID: windowID)
        _ = try? await activeCapture.start.value
        try await activeCapture.stream.stopCapture()
        stopAvailabilityMonitorIfIdle()
    }

    @MainActor
    func stopAllCaptures() async {
        let captures = Array(activeStreams.values)
        activeStreams.removeAll()
        for capture in captures {
            capture.fanout.removeAll()
            _ = try? await capture.start.value
            try? await capture.stream.stopCapture()
        }
        stopAvailabilityMonitorIfIdle()
    }

    @MainActor
    func hasPickedWindow(_ windowID: CGWindowID) -> Bool {
        windows.contains { $0.windowID == windowID }
    }

    @MainActor
    private func configurePickerIfNeeded() {
        guard !pickerConfigured else { return }
        if !pickerObserverRegistered {
            SCContentSharingPicker.shared.add(self)
            pickerObserverRegistered = true
        }
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = SCContentSharingPickerMode.singleWindow
        config.allowsChangingSelectedContent = false
        SCContentSharingPicker.shared.defaultConfiguration = config
        SCContentSharingPicker.shared.maximumStreamCount = 1
        SCContentSharingPicker.shared.isActive = true
        pickerConfigured = true
    }

    @MainActor
    private func updatePickedWindows(_ pickedWindows: [CapturedWindow], filter: SCContentFilter,
                                     request: WindowCapturePickerRouting.Request?) async {
        guard pickerRouting.current == request else { return }
        selectionGeneration = UUID()
        let generation = selectionGeneration
        pendingSelectionReleases.removeAll()
        windows = pickedWindows

        var nextFilters: [CGWindowID: SCContentFilter] = [:]
        for window in pickedWindows {
            nextFilters[window.windowID] = filter
        }
        captureFilters = nextFilters

        if let request, let pickedWindow = pickedWindows.first,
           let selection = pickerRouting.complete(request, windowID: pickedWindow.windowID) {
            windowPickerSelections.send(selection)
        } else {
            pickerRouting.cancel()
        }

        let pickedWindowIDs = Set(pickedWindows.map(\.windowID))
        let staleCaptures = activeStreams.filter { !pickedWindowIDs.contains($0.key) }
        for (windowID, capture) in staleCaptures {
            guard selectionGeneration == generation else { return }
            guard activeStreams[windowID]?.generation == capture.generation else { continue }
            try? await stopCapture(windowID: windowID)
        }

        ensureAvailabilityMonitorIfNeeded()
        stopAvailabilityMonitorIfIdle()
    }

    @MainActor
    private func removePickedWindow(windowID: CGWindowID) {
        pendingSelectionReleases[windowID] = nil
        windows.removeAll { $0.windowID == windowID }
        captureFilters.removeValue(forKey: windowID)
        stopAvailabilityMonitorIfIdle()
        deactivatePickerIfIdle()
    }

    @MainActor
    private func ensureAvailabilityMonitorIfNeeded() {
        guard availabilityMonitorTask == nil else { return }
        guard !windows.isEmpty || !activeStreams.isEmpty else { return }

        availabilityMonitorTask = Task { [weak self] in
            while let self {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                await self.pruneUnavailableWindows()
                if Task.isCancelled {
                    break
                }
            }
        }
    }

    @MainActor
    private func stopAvailabilityMonitorIfIdle() {
        guard windows.isEmpty && activeStreams.isEmpty else { return }
        availabilityMonitorTask?.cancel()
        availabilityMonitorTask = nil
    }

    @MainActor
    private func deactivatePickerIfIdle() {
        guard windows.isEmpty && activeStreams.isEmpty else { return }
        guard pickerRouting.current == nil else { return }
        guard pickerConfigured else { return }
        SCContentSharingPicker.shared.isActive = false
        pickerConfigured = false
    }

    @MainActor
    private func pruneUnavailableWindows() async {
        let generation = selectionGeneration
        let trackedIDs = Set(windows.map(\.windowID)).union(activeStreams.keys)
        guard !trackedIDs.isEmpty else {
            stopAvailabilityMonitorIfIdle()
            return
        }

        let missingIDs = trackedIDs.filter { !Self.isWindowAvailable($0) }
        guard !missingIDs.isEmpty else { return }

        for id in missingIDs {
            guard selectionGeneration == generation else { return }
            removePickedWindow(windowID: id)
            if activeStreams[id] != nil {
                try? await stopCapture(windowID: id)
            }
        }
    }

    private static func isWindowAvailable(_ windowID: CGWindowID) -> Bool {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]] else {
            return false
        }
        return !info.isEmpty
    }

    private func resolvePickedWindows(from filter: SCContentFilter) -> [CapturedWindow] {
        filter.includedWindows.compactMap { Self.capturedWindow(from: $0) }
    }

    private static func capturedWindow(from window: SCWindow) -> CapturedWindow? {
        guard let appName = window.owningApplication?.applicationName,
              !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        let title = normalizedTitle(window.title) ?? appName
        let id = window.windowID
        return CapturedWindow(
            id: id,
            windowID: id,
            title: title,
            appName: appName,
            appBundleIdentifier: window.owningApplication?.bundleIdentifier,
            frame: window.frame
        )
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @MainActor
    var normalizedPreferredFrameRate: Int {
        Self.normalizedFrameRate(preferredFrameRate)
    }

    static func normalizedFrameRate(_ value: Int) -> Int {
        WindowCaptureFrameRate.normalized(value)
    }

}

enum ScreenCaptureError: LocalizedError {
    case windowNotFound
    case pickerFailed(Error)

    var errorDescription: String? {
        switch self {
        case .windowNotFound:
            return "The selected window is no longer available."
        case .pickerFailed(let error):
            return "Window picker failed: \(error.localizedDescription)"
        }
    }
}

extension ScreenCaptureManager: SCContentSharingPickerObserver {
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        // Keep previous picked window list on cancel.
        Task { @MainActor in
            pickerRouting.cancel()
            deactivatePickerIfIdle()
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            let request = pickerRouting.current
            let pickedWindows = resolvePickedWindows(from: filter)
            await updatePickedWindows(pickedWindows, filter: filter, request: request)
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            // A failed new pick must preserve the app-shared source that other
            // workspaces already have in Preview, Current or a live output.
            pickerRouting.cancel()
            deactivatePickerIfIdle()
        }
        NSLog("ScreenCapture picker failed to start: %@", error.localizedDescription)
    }
}

extension ScreenCaptureManager: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        Task { @MainActor in
            if let stoppedWindowID = activeStreams.first(where: { $0.value.stream === stream })?.key {
                activeStreams.removeValue(forKey: stoppedWindowID)
                removePickedWindow(windowID: stoppedWindowID)
            }
            stopAvailabilityMonitorIfIdle()
        }
        NSLog("ScreenCapture stream stopped: %@", error.localizedDescription)
    }
}

/// One picker-approved source stream fans out the same GPU-backed sample buffer.
/// Each consumer keeps its own bounded latest-frame mailbox. No bitmap copies.
nonisolated final class SharedCaptureOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var outputs: [UUID: SCStreamOutput] = [:]
    func add(_ id: UUID, output: SCStreamOutput) { lock.lock(); outputs[id] = output; lock.unlock() }
    func remove(_ id: UUID) { lock.lock(); outputs.removeValue(forKey: id); lock.unlock() }
    func removeAll() { lock.lock(); outputs.removeAll(); lock.unlock() }
    var isEmpty: Bool { lock.lock(); defer { lock.unlock() }; return outputs.isEmpty }
    var consumerCount: Int { lock.lock(); defer { lock.unlock() }; return outputs.count }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        lock.lock(); let consumers = Array(outputs.values); lock.unlock()
        for consumer in consumers { consumer.stream?(stream, didOutputSampleBuffer: sampleBuffer, of: type) }
    }
}
