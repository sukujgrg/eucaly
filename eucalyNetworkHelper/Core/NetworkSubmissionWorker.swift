import Foundation
import Darwin

/// One bounded latest-frame mailbox. A nominal 30 Hz phase preserves cadence;
/// actual-entry spacing bounds recovery without replaying obsolete opportunities.
/// Neither SDK calls nor cleanup run on control/UI queues.
final class NetworkSubmissionWorker: @unchecked Sendable {
    private static let videoPeriodNanoseconds: UInt64 = 1_000_000_000 / 30
    private static let minimumVideoSpacingNanoseconds = videoPeriodNanoseconds - 1_000_000
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
    private var lastVideoEntryNanoseconds: UInt64? // SDK-video queue; survives owner/empty changes.
    private var nextVideoOpportunityNanoseconds: UInt64? // SDK-video queue; nominal phase, not wake time.
    private var metrics = NetworkSubmissionMetrics()
    private var stopping = false // protected by lock; blocks late GPU/audio handoffs
    private var videoFenceScheduled = false // protected by lock; latest epoch only
    #if DEBUG
    private var videoInProgress = false // protected by lock
    private let recordingAdapter: (any NetworkRuntimeAdapter)?
    private let recordingWakeDelayNanoseconds: UInt64
    private var videoTrace: NetworkVideoTrace?

    init() { recordingAdapter = nil; recordingWakeDelayNanoseconds = 0 }

    /// The fixture uses the actual timer, fences, mailbox and buffer leases;
    /// only the SDK boundary is replaced. Neither vendor runtime is loaded.
    init(recording adapter: any NetworkRuntimeAdapter, trace: NetworkVideoTrace, wakeDelayNanoseconds: UInt64 = 0) {
        precondition(wakeDelayNanoseconds <= 1_000_000)
        recordingAdapter = adapter
        recordingWakeDelayNanoseconds = wakeDelayNanoseconds
        videoTrace = trace
    }
    #else
    init() {}
    #endif

    func start(name: String, technology: NetworkOutputTechnology, generation: UUID? = nil,
               completion: @escaping @Sendable (NetworkHelperStatus?, String?) -> Void) {
        queue.async { [self] in
            do {
                let runtime: NetworkHelperRuntime
                #if DEBUG
                if let recordingAdapter { runtime = .recording(recordingAdapter) }
                else { runtime = try NetworkHelperRuntime(technology: technology, generation: generation) }
                if videoTrace == nil {
                    videoTrace = NetworkVideoTrace.fromEnvironment(generation: generation, technology: technology)
                }
                #else
                runtime = try NetworkHelperRuntime(technology: technology, generation: generation)
                #endif
                guard runtime.createSender(name: name), let actual = runtime.sourceName else {
                    throw NetworkHelperError.message("The \(technology.title) source could not be created.")
                }
                lock.lock()
                self.runtime = runtime
                report.runtimeVersion = runtime.version; report.sourceName = actual
                let initial = report
                lock.unlock()
                // A live frame deadline needs the strict timer's best effort,
                // rather than ordinary timer coalescing. This grants neither
                // foreground nor real-time priority; early wakes are guarded.
                let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
                let timerStart = DispatchTime.now()
                nextVideoOpportunityNanoseconds = timerStart.uptimeNanoseconds
                timer.schedule(deadline: timerStart, leeway: .nanoseconds(0))
                #if DEBUG
                videoTrace?.started(runtimeVersion: runtime.version, timerAnchor: timerStart.uptimeNanoseconds)
                #endif
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
        defer { scheduleNextVideoTick() }
        #if DEBUG
        var trace = videoTrace?.tick(firings: UInt64(timer?.data ?? 0))
        defer {
            if var trace {
                trace.tickFinishedNanoseconds = DispatchTime.now().uptimeNanoseconds
                videoTrace?.record(trace)
            }
        }
        if recordingWakeDelayNanoseconds != 0 {
            // Recording fixture only: model finite owner-queue wake lateness
            // before admission/SDK entry, using real elapsed host time. This
            // changes neither the production scheduler nor the transmitted clock.
            trace?.injectedWakeDelayStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .nanoseconds(Int(recordingWakeDelayNanoseconds)))
            trace?.injectedWakeDelayFinishedNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
        #endif
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        // Dispatch deadlines are not a minimum-spacing guarantee. Re-arm an
        // early wake without taking the pending latest frame or an SDK borrow.
        let now = DispatchTime.now().uptimeNanoseconds
        let earliestEntry = lastVideoEntryNanoseconds.map { $0 + Self.minimumVideoSpacingNanoseconds } ?? 0
        if now < max(earliestEntry, nextVideoOpportunityNanoseconds ?? 0) {
            lock.unlock(); return
        }
        let next = pending, epoch = contentEpoch; pending = nil; let fault = self.fault
        #if DEBUG
        if fault == "video-queue-delay-once" { self.fault = "" }
        #endif
        let callIndex = report.submittedFrames &+ 1
        lock.unlock()
        if currentEpoch != epoch { current = nil; currentEpoch = epoch }
        if let next { current = next }
        guard let current, let runtime else { return }
        #if DEBUG
        trace?.contentEpoch = epoch
        trace?.consumption = runtime.videoConsumption.rawValue
        trace?.format = current.format.rawValue
        trace?.rawByteCount = current.format.byteCount
        lock.withLock { videoInProgress = true }
        defer { lock.withLock { videoInProgress = false } }
        if fault == "sdk-stall" { DispatchSemaphore(value: 0).wait() }
        if fault == "sdk-crash" { _exit(72) }
        if fault == "video-queue-delay-once" {
            // Opt-in, finite owner-queue delay, deliberately OUTSIDE the timed
            // SDK call. It is never a production pacing policy or retry.
            trace?.injectedDelayStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
            _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(95))
            trace?.injectedDelayFinishedNanoseconds = DispatchTime.now().uptimeNanoseconds
        }
        #endif
        // Timecode is monotonic and never follows a source player's seek/loop.
        let started = DispatchTime.now().uptimeNanoseconds
        lastVideoEntryNanoseconds = started
        // Consume one current opportunity and skip every nominal slot already
        // obsolete at this real entry. Ordinary wake lateness does not become
        // an added offset on every subsequent deadline. There is no replay loop.
        let opportunity = nextVideoOpportunityNanoseconds ?? started
        let elapsed = started >= opportunity ? started - opportunity : 0
        nextVideoOpportunityNanoseconds = opportunity + (elapsed / Self.videoPeriodNanoseconds + 1) * Self.videoPeriodNanoseconds
        let tick = started / 100
        let timecode = max(tick, lastTick + 1); lastTick = timecode
        let previous = borrowed
        #if DEBUG
        trace?.kind = "live"
        trace?.callIndex = callIndex
        trace?.timecode = Int64(timecode)
        trace?.sdkEnteredNanoseconds = started
        #endif
        let returnedBytes = runtime.sendVideo(current.baseAddress, format: current.format, timecode: Int64(timecode))
        let finished = DispatchTime.now().uptimeNanoseconds
        #if DEBUG
        trace?.sdkReturnedNanoseconds = finished
        trace?.returnedBytes = returnedBytes
        #endif
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
        #if DEBUG
        trace?.observationFinishedNanoseconds = DispatchTime.now().uptimeNanoseconds
        #endif
        lock.lock(); report.submittedFrames &+= 1; report.lastTimecode = Int64(timecode)
        report.effectiveFramesPerSecond = metrics.framesPerSecond
        report.slowCadence = metrics.slowCadence; report.frameAgeMilliseconds = metrics.frameAgeMilliseconds
        report.submissionMilliseconds = Double(finished - started) / 1_000_000
        observation.transport?.apply(to: &report)
        report.connections = observation.connections; lock.unlock()
    }
    private func scheduleNextVideoTick() {
        guard let timer, !lock.withLock({ stopping }) else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let earliest = lastVideoEntryNanoseconds.map { $0 + Self.minimumVideoSpacingNanoseconds } ?? 0
        let deadline: UInt64
        if current == nil {
            // An empty/fenced program has no SDK entry to advance the clock.
            // Start its next opportunity in the future, retaining the entry
            // floor while accumulating neither idle debt nor immediate wakes.
            let future = now + Self.videoPeriodNanoseconds
            nextVideoOpportunityNanoseconds = future
            deadline = max(earliest, future)
        } else {
            // Keep the nominal phase through ordinary wake lateness. After an
            // over-budget call, serve one already-due opportunity immediately
            // if spacing permits, instead of needlessly waiting another slot.
            // Codec/observation time remains inside the frame period.
            deadline = max(now, max(earliest, nextVideoOpportunityNanoseconds ?? now))
        }
        timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
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
                #if DEBUG
                if let videoTrace {
                    // Snapshot only on the owner queue. Encoding and file I/O
                    // happen after SDK cleanup on a separate utility queue.
                    let expected = lock.withLock { self.report.submittedFrames }
                    let shutdown = report
                    videoTrace.exportAfterStop(expectedLiveCalls: expected) { completion(shutdown) }
                    return
                }
                #endif
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
            #if DEBUG
            var trace = videoTrace?.terminal(consumption: runtime.videoConsumption, format: format, timecode: Int64(timecode))
            trace?.sdkEnteredNanoseconds = DispatchTime.now().uptimeNanoseconds
            #endif
            let returned = runtime.sendVideo(bytes.baseAddress!, format: format, timecode: Int64(timecode))
            #if DEBUG
            trace?.sdkReturnedNanoseconds = DispatchTime.now().uptimeNanoseconds
            trace?.returnedBytes = returned
            #else
            _ = returned
            #endif
            runtime.flush()
            #if DEBUG
            if var trace {
                trace.tickFinishedNanoseconds = DispatchTime.now().uptimeNanoseconds
                videoTrace?.record(trace)
            }
            #endif
        }
        return .init(terminalPixelBGRA: pixel, videoFormat: format, terminalUYVY: pair, terminalAlpha: UInt8(byte(colour.alpha)))
    }
}
