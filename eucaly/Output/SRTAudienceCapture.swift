import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo

nonisolated final class SRTAudienceCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "eucaly.srt.audience-frames")
    private var latest: CMSampleBuffer?
    private var failed = false
    private var timer: DispatchSourceTimer?
    private let ingest: SRTMediaIngest
    private let audio: SRTProgramAudio
    let onFailure: @MainActor @Sendable (String) -> Void
    init(ingest: SRTMediaIngest, audio: SRTProgramAudio, onFailure: @escaping @MainActor @Sendable (String) -> Void) {
        self.ingest = ingest; self.audio = audio; self.onFailure = onFailure
    }
    @MainActor
    func start(windowID: UInt32, frameRate: Int) async throws {
        let content: SCShareableContent
        if #available(macOS 14.4, *) { content = try await SCShareableContent.currentProcess }
        else { content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) }
        guard let window = content.windows.first(where: { $0.windowID == windowID && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }) else {
            throw NSError(domain: "eucaly.Media", code: 1, userInfo: [NSLocalizedDescriptionKey: "The selected Audience window is no longer open."])
        }
        let config = SCStreamConfiguration()
        config.width = 1920; config.height = 1080
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        config.queueDepth = 3; config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false; config.capturesAudio = false
        config.preservesAspectRatio = true; config.scalesToFit = true; config.ignoreShadowsSingleWindow = true
        if #available(macOS 15, *) { config.captureDynamicRange = .SDR }
        let capture = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = capture
        queue.async { [self] in
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / frameRate), leeway: .milliseconds(1))
            source.setEventHandler { [weak self] in self?.sendLatest() }
            timer = source; source.resume()
        }
        do { try await capture.startCapture() }
        catch { stream = nil; throw error }
    }
    @MainActor
    func stop() async {
        queue.async { [self] in timer?.cancel(); timer = nil; latest = nil }
        let retired = stream; stream = nil
        try? await retired?.stopCapture()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { fail("Audience capture stopped: \(error.localizedDescription)") }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return }
        guard raw == SCFrameStatus.complete.rawValue else {
            if [SCFrameStatus.blank.rawValue, SCFrameStatus.suspended.rawValue, SCFrameStatus.stopped.rawValue].contains(raw), !failed {
                failed = true; latest = nil
                fail("Audience capture is unavailable")
            }
            return // Idle frames keep the last complete still image.
        }
        guard !failed, CMSampleBufferGetImageBuffer(sampleBuffer) != nil else { return }
        latest = sampleBuffer
    }
    private func fail(_ message: String) {
        let callback = onFailure
        Task { @MainActor in callback(message) }
    }
    private func sendLatest() {
        guard let latest else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var frame: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: latest,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &frame) == noErr, let frame else { return }
        audio.start(at: now); ingest.offer(.video(frame))
    }
}
