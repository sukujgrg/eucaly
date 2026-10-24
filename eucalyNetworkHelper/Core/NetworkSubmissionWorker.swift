import Foundation
import Darwin

/// One bounded latest-frame mailbox. DispatchSource coalesces clock ticks if
/// the SDK blocks. Neither SDK calls nor cleanup run on control/UI queues.
final class NetworkSubmissionWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.suku.eucaly.network.sdk-submission", qos: .userInitiated)
    private let fences = DispatchQueue(label: "com.suku.eucaly.network.audio-fences", qos: .userInitiated)
    private let audioCalls = DispatchGroup()
    private var audioInProgress = false // protected by lock
    private var lastAudioSample: Int64? // protected by lock; reset only by ownership fences
    private let lock = NSLock()
    private var contentEpoch: UInt64 = 0
    private var currentEpoch: UInt64 = 0
    private var pending: GPUFrameLease?
    private var report = NetworkHelperStatus()
    private var fault = ""
    private var runtime: NetworkHelperRuntime?
    private var timer: DispatchSourceTimer?
    private var current: GPUFrameLease?
    // Held until the NEXT SDK send/flush returns, not just the async call itself.
    private var borrowed: GPUFrameLease?
    private weak var submittedPicture: GPUFrameLease?
    private var lastTick: UInt64 = 0
    private var metrics = NetworkSubmissionMetrics()
    private var stopping = false // protected by lock; blocks late GPU/audio handoffs
    private var videoFenceScheduled = false // protected by lock; latest epoch only
    #if DEBUG
    private var videoInProgress = false // protected by lock
    #endif

    func start(name: String, technology: NetworkOutputTechnology, generation: UUID? = nil,
               completion: @escaping @Sendable (NetworkHelperStatus?, String?) -> Void) {
        queue.async { [self] in
            do {
                let runtime = try NetworkHelperRuntime(technology: technology, generation: generation)
                guard runtime.createSender(name: name), let actual = runtime.sourceName else {
                    throw NetworkHelperError.message("The \(technology.title) source could not be created.")
                }
                lock.lock()
                self.runtime = runtime
                report.runtimeVersion = runtime.version; report.sourceName = actual
                let initial = report
                lock.unlock()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 30), leeway: .milliseconds(1))
                timer.setEventHandler { [weak self] in self?.tick() }
                self.timer = timer; timer.resume()
                completion(initial, nil)
            } catch { completion(nil, error.localizedDescription) }
        }
    }
    func selectContent(epoch: UInt64, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        if contentEpoch != epoch { lastAudioSample = nil }
        contentEpoch = epoch; pending = nil
        let scheduleVideoFence = !videoFenceScheduled
        videoFenceScheduled = true
        lock.unlock()
        // Audio's continuous clock cannot wait behind a codec/async-video
        // synchronization. Finish only admitted old-owner audio before ACK.
        // Video is serialized on its SDK queue and coalesces to the latest
        // owner while blocked. Its old SDK borrow remains leased until the next
        // async video send (or shutdown flush), which synchronizes that borrow.
        audioCalls.notify(queue: fences, execute: completion)
        if scheduleVideoFence {
            queue.async { [self] in
                let epoch = lock.withLock {
                    videoFenceScheduled = false
                    return contentEpoch
                }
                if currentEpoch != epoch { current = nil; currentEpoch = epoch }
            }
        }
    }
    func offer(_ surface: GPUFrameLease, epoch: UInt64 = 0) {
        lock.lock()
        guard !stopping, epoch == contentEpoch else { lock.unlock(); return }
        if pending != nil { report.replacedFrames &+= 1 }
        report.gpuMilliseconds = surface.gpuMilliseconds
        report.maximumGPUMilliseconds = max(report.maximumGPUMilliseconds, surface.gpuMilliseconds)
        report.surfacePoolHighWaterMark = max(report.surfacePoolHighWaterMark, surface.poolOccupancy)
        report.videoFormat = surface.format
        pending = surface
        lock.unlock()
    }
    func status() -> NetworkHelperStatus {
        lock.lock(); var value = report
        #if DEBUG
        value.audioCallInProgress = audioInProgress
        value.videoCallInProgress = videoInProgress
        #endif
        lock.unlock()
        #if DEBUG
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            value.processCPUSeconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        #endif
        return value
    }
    enum AudioResult { case submitted, superseded, discontinuity }
    /// Called serially by the private audio mailbox's dedicated reader. SDK
    /// work never runs on the control queue or parks a GCD worker for input.
    func sendAudio(_ block: NetworkAudioBlock, epoch: UInt64) -> AudioResult {
        lock.lock()
        guard !stopping, contentEpoch == epoch, let runtime else { lock.unlock(); return .superseded }
        guard !audioInProgress, lastAudioSample.map({ block.sampleTime == $0 + Int64(NetworkAudioBlock.samples) }) ?? true else {
            lock.unlock(); return .discontinuity
        }
        audioInProgress = true; lastAudioSample = block.sampleTime
        // Enter under the same lock as Stop's admission fence. The strong
        // runtime reference and group keep destruction behind accepted SDK work.
        audioCalls.enter()
        let fault = self.fault
        lock.unlock()
        defer {
            lock.lock(); audioInProgress = false; lock.unlock()
            audioCalls.leave()
        }
        #if DEBUG
        if fault == "audio-stall" { DispatchSemaphore(value: 0).wait() }
        #endif
        let started = DispatchTime.now().uptimeNanoseconds
        let age = max(0, Double(started) / 1_000_000 - Double(block.sampleTime) * 1000 / 48000)
        #if DEBUG
        NetworkAudioTrace.record("sdk-enter", sample: block.sampleTime)
        if NetworkAudioTrace.isEnabled {
            block.pcm.withUnsafeBytes { bytes in
                let samples = bytes.bindMemory(to: Float.self)
                if let first = samples.baseAddress, samples.count >= 1920 {
                    NetworkAudioTrace.record("sdk-energy", sample: block.sampleTime, frames: 960, sampleRate: 48000,
                        leftRMS: NetworkAudioTrace.rms(first, frames: 960),
                        rightRMS: NetworkAudioTrace.rms(first + 960, frames: 960))
                }
            }
        }
        #endif
        let returnedBytes = block.pcm.withUnsafeBytes { runtime.sendAudio($0.baseAddress!, sampleTime: block.sampleTime) }
        let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        #if DEBUG
        NetworkAudioTrace.record("sdk-return", sample: block.sampleTime, sdkReturnBytes: returnedBytes)
        #endif
        // The same audio reader queries enqueue observations after consumption.
        // SDK return/zero remains an observation; raw-buffer ACK is unchanged.
        let observation = runtime.audioSubmissionObservation()
        lock.lock()
        report.audioBlocks &+= 1; report.lastAudioSample = block.sampleTime
        report.lastAudioSDKReturnBytes = returnedBytes
        report.audioSubmissionAgeMilliseconds = age
        report.maximumAudioSubmissionAgeMilliseconds = max(report.maximumAudioSubmissionAgeMilliseconds, age)
        report.audioSubmissionMilliseconds = duration
        report.maximumAudioSubmissionMilliseconds = max(report.maximumAudioSubmissionMilliseconds, duration)
        observation?.apply(to: &report)
        lock.unlock()
        return .submitted
    }
    #if DEBUG
    func injectFault(_ value: String) { lock.lock(); fault = value; lock.unlock() }
    #endif
    private func tick() {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        let next = pending, epoch = contentEpoch; pending = nil; let fault = self.fault
        let callIndex = report.submittedFrames &+ 1
        lock.unlock()
        if currentEpoch != epoch { current = nil; currentEpoch = epoch }
        if let next { current = next }
        guard let current, let runtime else { return }
        #if DEBUG
        lock.withLock { videoInProgress = true }
        defer { lock.withLock { videoInProgress = false } }
        if fault == "sdk-stall" { DispatchSemaphore(value: 0).wait() }
        if fault == "sdk-crash" { _exit(72) }
        #endif
        // Timecode is monotonic and never follows a source player's seek/loop.
        let started = DispatchTime.now().uptimeNanoseconds
        let tick = started / 100
        let timecode = max(tick, lastTick + 1); lastTick = timecode
        let previous = borrowed
        let returnedBytes = runtime.sendVideo(current.baseAddress, format: current.format, timecode: Int64(timecode))
        let finished = DispatchTime.now().uptimeNanoseconds
        metrics.submitted(at: finished, newPictureProducedAt: current !== submittedPicture ? current.producedAtNanoseconds : nil)
        withExtendedLifetime(previous) {} // Previous async borrow is now synchronized.
        submittedPicture = current
        switch runtime.videoConsumption {
        case .synchronous: borrowed = nil
        case .borrowedUntilNextSendOrFlush: borrowed = current
        }
        let observation = runtime.videoSubmissionObservation(.init(contentEpoch: epoch, callIndex: callIndex,
            timecode: Int64(timecode), startedNanoseconds: started, finishedNanoseconds: finished,
            format: current.format, returnedBytes: returnedBytes))
        lock.lock(); report.submittedFrames &+= 1; report.lastTimecode = Int64(timecode)
        report.effectiveFramesPerSecond = metrics.framesPerSecond
        report.slowCadence = metrics.slowCadence; report.frameAgeMilliseconds = metrics.frameAgeMilliseconds
        report.submissionMilliseconds = Double(finished - started) / 1_000_000
        observation.transport?.apply(to: &report)
        report.connections = observation.connections; lock.unlock()
    }
    func stop(colour: OutputColour, completion: @escaping @Sendable (NetworkHelperShutdown) -> Void) {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            lock.lock()
            stopping = true; pending = nil
            let retiring = runtime; runtime = nil
            lock.unlock()
            // Finish admitted audio before destroying the shared sender. Both
            // workers remain isolated from control and the parent's UI thread.
            audioCalls.notify(queue: queue) { [self] in
                var report = NetworkHelperShutdown(terminalPixelBGRA: nil)
                if let retiring {
                    report = sendTerminalPicture(colour, runtime: retiring)
                    borrowed = nil; current = nil
                    // Explicitly destroy BEFORE completion exits the process.
                    // A local strong reference otherwise postpones deinit forever.
                    retiring.close()
                }
                completion(report)
            }
        }
    }
    private func sendTerminalPicture(_ colour: OutputColour, runtime: NetworkHelperRuntime) -> NetworkHelperShutdown {
        func byte(_ value: Double) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        let pixel = byte(colour.blue) | byte(colour.green) << 8 | byte(colour.red) << 16 | byte(colour.alpha) << 24
        let y = 0.2126 * colour.red + 0.7152 * colour.green + 0.0722 * colour.blue
        let luma = UInt32((16 + 219 * y).rounded())
        let u = UInt32((128 + 224 * (colour.blue - y) / 1.8556).rounded())
        let v = UInt32((128 + 224 * (colour.red - y) / 1.5748).rounded())
        let pair = u | luma << 8 | v << 16 | luma << 24
        let format: NetworkVideoPixelFormat = colour.alpha == 1 ? .uyvy : .uyva
        // One bounded shutdown buffer, independent of GPU leases still in use.
        // A single constant colour needs no GPU scheduling during teardown.
        var pixels = [UInt32](repeating: pair, count: format.byteCount / 4)
        if format == .uyva {
            _ = pixels.withUnsafeMutableBytes { bytes in
                bytes.baseAddress!.advanced(by: NetworkHelperWire.width * NetworkHelperWire.height * 2)
                    .initializeMemory(as: UInt8.self, repeating: UInt8(byte(colour.alpha)), count: NetworkHelperWire.width * NetworkHelperWire.height)
            }
        }
        let timecode = max(DispatchTime.now().uptimeNanoseconds / 100, lastTick + 1)
        pixels.withUnsafeMutableBytes { bytes in
            _ = runtime.sendVideo(bytes.baseAddress!, format: format, timecode: Int64(timecode))
            runtime.flush()
        }
        return .init(terminalPixelBGRA: pixel, videoFormat: format, terminalUYVY: pair, terminalAlpha: UInt8(byte(colour.alpha)))
    }
}
