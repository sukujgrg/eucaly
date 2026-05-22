import ScreenCaptureKit
import Combine
import AppKit
import CoreGraphics

@available(macOS 14.0, *)
final class ScreenCaptureManager: NSObject, ObservableObject {
    static let shared = ScreenCaptureManager()

    // MARK: - Properties
    private struct ActiveCapture {
        let stream: SCStream
        let ownerID: UUID
    }

    private let sampleQueue = DispatchQueue(label: "eucaly.window-capture.sample", qos: .userInitiated)
    @MainActor var preferredFrameRate: Int = 60
    @MainActor private var activeStreams: [CGWindowID: ActiveCapture] = [:]
    @MainActor private var captureFilters: [CGWindowID: SCContentFilter] = [:]
    @MainActor @Published var windows: [CapturedWindow] = []
    @MainActor private var availabilityMonitorTask: Task<Void, Never>?
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

    private override init() {
        super.init()
    }

    // MARK: - Picker
    @MainActor
    func presentWindowPicker() {
        configurePickerIfNeeded()
        SCContentSharingPicker.shared.present(using: .window)
    }

    @MainActor
    func clearWindows() {
        windows = []
        captureFilters = [:]
        stopAvailabilityMonitorIfIdle()
        deactivatePickerIfIdle()
    }

    @MainActor
    func clearWindow(windowID: CGWindowID) {
        removePickedWindow(windowID: windowID)
        if activeStreams[windowID] != nil {
            Task { @MainActor in
                try? await stopCapture(windowID: windowID)
                deactivatePickerIfIdle()
            }
        }
    }

    // MARK: - Stream Management
    @MainActor
    func startCapture(
        windowID: CGWindowID,
        ownerID: UUID = UUID(),
        outputHandler: SCStreamOutput
    ) async throws -> SCStream {
        if let existingCapture = activeStreams[windowID] {
            try? await existingCapture.stream.stopCapture()
            activeStreams.removeValue(forKey: windowID)
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
        let fps = Self.normalizedFrameRate(preferredFrameRate)
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 6
        config.showsCursor = true
        config.captureResolution = .best
        config.scalesToFit = true
        config.preservesAspectRatio = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(outputHandler, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()

        activeStreams[windowID] = ActiveCapture(stream: stream, ownerID: ownerID)
        ensureAvailabilityMonitorIfNeeded()
        return stream
    }

    @MainActor
    func stopCapture(windowID: CGWindowID, ownerID: UUID? = nil) async throws {
        guard let activeCapture = activeStreams[windowID] else { return }
        if let ownerID, activeCapture.ownerID != ownerID { return }
        try await activeCapture.stream.stopCapture()
        activeStreams.removeValue(forKey: windowID)
        stopAvailabilityMonitorIfIdle()
    }

    @MainActor
    func stopAllCaptures() async {
        for (_, activeCapture) in activeStreams {
            try? await activeCapture.stream.stopCapture()
        }
        activeStreams.removeAll()
        stopAvailabilityMonitorIfIdle()
    }

    @MainActor
    func clearWindowSelectionAndDeactivatePicker() async {
        await stopAllCaptures()
        windows = []
        captureFilters = [:]
        stopAvailabilityMonitorIfIdle()
        deactivatePickerIfIdle()
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
    private func updatePickedWindows(_ pickedWindows: [CapturedWindow], filter: SCContentFilter) async {
        windows = pickedWindows

        var nextFilters: [CGWindowID: SCContentFilter] = [:]
        for window in pickedWindows {
            nextFilters[window.windowID] = filter
        }
        captureFilters = nextFilters

        let pickedWindowIDs = Set(pickedWindows.map(\.windowID))
        let staleActiveWindowIDs = activeStreams.keys.filter { !pickedWindowIDs.contains($0) }
        for windowID in staleActiveWindowIDs {
            try? await stopCapture(windowID: windowID)
        }

        ensureAvailabilityMonitorIfNeeded()
        stopAvailabilityMonitorIfIdle()
    }

    @MainActor
    private func removePickedWindow(windowID: CGWindowID) {
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
        guard pickerConfigured else { return }
        SCContentSharingPicker.shared.isActive = false
        pickerConfigured = false
    }

    @MainActor
    private func pruneUnavailableWindows() async {
        let trackedIDs = Set(windows.map(\.windowID)).union(activeStreams.keys)
        guard !trackedIDs.isEmpty else {
            stopAvailabilityMonitorIfIdle()
            return
        }

        let missingIDs = trackedIDs.filter { !Self.isWindowAvailable($0) }
        guard !missingIDs.isEmpty else { return }

        for id in missingIDs {
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

    private func resolvePickedWindows(from filter: SCContentFilter) async -> [CapturedWindow] {
        if #available(macOS 15.2, *) {
            return filter.includedWindows.compactMap(Self.capturedWindow(from:))
        }
        return []
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

    private static func normalizedFrameRate(_ value: Int) -> Int {
        switch value {
        case 24, 30, 60:
            return value
        default:
            return 60
        }
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

@available(macOS 14.0, *)
extension ScreenCaptureManager: SCContentSharingPickerObserver {
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        // Keep previous picked window list on cancel.
        Task { @MainActor in
            deactivatePickerIfIdle()
        }
    }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task {
            let pickedWindows = await resolvePickedWindows(from: filter)
            await updatePickedWindows(pickedWindows, filter: filter)
        }
    }

    func contentSharingPickerStartDidFailWithError(_ error: any Error) {
        Task { @MainActor in
            clearWindows()
        }
        NSLog("ScreenCapture picker failed to start: %@", error.localizedDescription)
    }
}

@available(macOS 14.0, *)
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
