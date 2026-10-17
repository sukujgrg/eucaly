import Foundation
@preconcurrency import ScreenCaptureKit
import CoreMedia
import CoreVideo
import AppKit

/// Capture already supplies the video clock. Only synthesize a picture when
/// ScreenCaptureKit goes idle on a still/paused slide, to keep the receiver live.
nonisolated struct SRTAudienceFramePacer {
    private var latest: CMSampleBuffer?
    private var lastSent: CMTime?
    private var lastCapturePTS: CMTime?
    private var heartbeatBoundary: CMTime?
    private var lastCaptureArrival: CMTime?
    private let interval: CMTime
    private let rateLimitRequired: Bool
    private var nextCapture: CMTime?
    private var presentationOrigin: CMTime?
    private var presentationIndex: Int64 = -1
    private(set) var receivedFrames = 0
    private(set) var rateLimitedFrames = 0
    init(maximumFrameRate: Int = 60, displayFrameRate: Double? = nil) {
        let maximum = Double(max(1, maximumFrameRate))
        let native = displayFrameRate.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let rate = min(maximum, native ?? maximum)
        interval = rate.rounded() == rate ? CMTime(value: 1, timescale: CMTimeScale(rate))
            : CMTime(seconds: 1 / rate, preferredTimescale: 1_000_000_000)
        rateLimitRequired = native.map { $0 > maximum + 0.01 } ?? true
    }
    mutating func suspend() {
        latest = nil; lastCaptureArrival = nil
    }

    mutating func capture(_ source: CMSampleBuffer, at now: CMTime, displayTime: UInt64? = nil) -> CMSampleBuffer? {
        var frame = source
        if let displayTime, displayTime > 0 {
            // WindowServer's display event is the source presentation clock;
            // callback/sample creation can arrive with additional jitter.
            let pts = CMClockMakeHostTimeFromSystemUnits(displayTime)
            var timing = CMSampleTimingInfo(duration: source.duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: source,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                let copy else { return nil }
            frame = copy
        }
        let pts = frame.presentationTimeStamp
        guard pts.isNumeric, now.isNumeric, lastCapturePTS.map({ pts > $0 }) ?? true,
              heartbeatBoundary.map({ pts > $0 }) ?? true else { return nil }
        lastCapturePTS = pts
        // Follow the display's cadence without a second capture timer. A
        // timestamp grid caps high-refresh displays without accumulating drift
        // or dropping 59.94/60 Hz frames for normal capture timestamp jitter.
        receivedFrames += 1
        let tolerance = CMTimeMultiplyByFloat64(interval, multiplier: 0.25)
        if rateLimitRequired, let nextCapture, pts < CMTimeSubtract(nextCapture, tolerance) {
            rateLimitedFrames += 1; return nil
        }
        if let nextCapture {
            let steps = max(1, Int64(floor(CMTimeSubtract(pts, nextCapture).seconds / interval.seconds)) + 1)
            self.nextCapture = CMTimeAdd(nextCapture, CMTimeMultiplyByFloat64(interval, multiplier: Double(steps)))
        } else { nextCapture = CMTimeAdd(pts, interval) }
        // Captured display events have small timing variations. Keep their
        // host-clock origin and missing-frame gaps, but place accepted pictures
        // on unique presentation ticks so two frames cannot share one refresh.
        // This is timestamp normalization, not another sampling timer.
        let origin = presentationOrigin ?? pts
        presentationOrigin = origin
        let index = max(presentationIndex + 1, Int64((CMTimeSubtract(pts, origin).seconds / interval.seconds).rounded()))
        let presentationPTS = CMTimeAdd(origin, CMTimeMultiplyByFloat64(interval, multiplier: Double(index)))
        if presentationPTS != frame.presentationTimeStamp {
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: presentationPTS, decodeTimeStamp: .invalid)
            var copy: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: frame,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
                let copy else { return nil }
            frame = copy
        }
        presentationIndex = index
        latest = frame; lastSent = presentationPTS; lastCaptureArrival = now
        return frame
    }

    mutating func heartbeat(at now: CMTime) -> CMSampleBuffer? {
        guard let latest, let lastSent, let lastCaptureArrival, now.isNumeric,
              CMTimeSubtract(now, lastCaptureArrival).seconds >= 0.5,
              CMTimeSubtract(now, lastSent).seconds >= 0.5 else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: latest,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy) == noErr,
            let copy else { return nil }
        self.lastSent = now; heartbeatBoundary = now
        if let presentationOrigin {
            presentationIndex = max(presentationIndex, Int64(floor(CMTimeSubtract(now, presentationOrigin).seconds / interval.seconds)))
        }
        return copy
    }
}

nonisolated final class SRTAudienceCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "eucaly.srt.audience-frames", qos: .userInteractive)
    // These properties are confined to the sample-handler queue.
    private var activeCapture: SCStream?
    private var pacer = SRTAudienceFramePacer()
    private var failed = false
    private var unavailableSince: CMTime?
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
        // Use native display updates; the pacer applies the selected maximum
        // without introducing another free-running capture clock.
        config.minimumFrameInterval = .zero
        config.queueDepth = 8; config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = false; config.capturesAudio = false
        config.preservesAspectRatio = true; config.scalesToFit = true; config.ignoreShadowsSingleWindow = true
        if #available(macOS 15, *) { config.captureDynamicRange = .SDR }
        // A 50 Hz Audience display must retain its native cadence even when
        // the destination ceiling is 60. Variable/high-refresh displays remain
        // capped by the destination setting.
        let sourceWindow = NSApplication.shared.windows.first { UInt32($0.windowNumber) == windowID }
        let displayRate = sourceWindow?.screen.map { screen in
            let identifier = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            let nominal = identifier.flatMap { CGDisplayCopyDisplayMode($0) }?.refreshRate ?? 0
            return nominal > 0 ? nominal : Double(screen.maximumFramesPerSecond)
        }
        let capture = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: config, delegate: self)
        try capture.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        stream = capture
        queue.async { [self] in
            activeCapture = capture; pacer = SRTAudienceFramePacer(maximumFrameRate: frameRate, displayFrameRate: displayRate); failed = false
            unavailableSince = CMClockGetTime(CMClockGetHostTimeClock())
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500), leeway: .milliseconds(10))
            source.setEventHandler { [weak self] in
                guard let self, !self.failed, self.activeCapture === capture else { return }
                let now = CMClockGetTime(CMClockGetHostTimeClock())
                if let since = self.unavailableSince, CMTimeSubtract(now, since).seconds >= 3 {
                    self.failed = true; self.pacer.suspend()
                    self.fail("Audience capture is unavailable")
                    return
                }
                if let frame = self.pacer.heartbeat(at: now) { self.ingest.offer(.video(frame)) }
            }
            timer = source; source.resume()
        }
        do { try await capture.startCapture() }
        catch { await stop(); throw error }
    }
    func statistics() async -> (received: Int, rateLimited: Int) {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                continuation.resume(returning: (pacer.receivedFrames, pacer.rateLimitedFrames))
            }
        }
    }
    @MainActor
    func stop() async {
        let retired = stream; stream = nil
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                activeCapture = nil; timer?.cancel(); timer = nil; pacer = SRTAudienceFramePacer()
                continuation.resume()
            }
        }
        try? await retired?.stopCapture()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            guard activeCapture === stream, !failed else { return }
            failed = true; pacer = SRTAudienceFramePacer()
            fail("Audience capture stopped: \(error.localizedDescription)")
        }
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard activeCapture === stream, !failed, outputType == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int else { return }
        guard raw == SCFrameStatus.complete.rawValue else {
            if raw == SCFrameStatus.stopped.rawValue {
                failed = true; pacer.suspend(); fail("Audience capture stopped")
            } else if [SCFrameStatus.blank.rawValue, SCFrameStatus.suspended.rawValue].contains(raw) {
                // Transient suspension is not a permanent capture failure.
                // Stop repeating the held picture; fail only if it persists.
                pacer.suspend()
                if unavailableSince == nil { unavailableSince = CMClockGetTime(CMClockGetHostTimeClock()) }
            }
            return
        }
        guard CMSampleBufferGetImageBuffer(sampleBuffer) != nil,
              let frame = pacer.capture(sampleBuffer, at: CMClockGetTime(CMClockGetHostTimeClock()),
                displayTime: (attachments.first?[.displayTime] as? NSNumber)?.uint64Value) else { return }
        // Follow the native display clock with a stable presentation cadence,
        // rather than sampling latest on another timer. Audio uses this host clock.
        unavailableSince = nil
        audio.start(at: frame.presentationTimeStamp)
        ingest.offer(.video(frame))
    }
    private func fail(_ message: String) {
        let callback = onFailure
        Task { @MainActor in callback(message) }
    }
}
