import Foundation
import Security
import IOSurface

/// Only this helper target can load NDI. Constructors in the main app never do.
final class NDIRuntime {
    let handle: OpaquePointer
    private var closed = false
    var version: String { String(cString: eucaly_ndi_version(handle)) }

    init() throws {
        let paths = NDIHelperWire.installedRuntimePaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard let path = paths.first else {
            throw RuntimeError.message("Install the macOS NDI runtime to enable this output.")
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var code: SecStaticCode?, requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"libndi\" and certificate leaf[subject.OU] = \"W8U66ET244\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw RuntimeError.message("The installed NDI runtime has an unrecognized or invalid signature. Reinstall it from NDI.")
        }
        var error = [CChar](repeating: 0, count: 256)
        guard let handle = eucaly_ndi_open(url.path, &error, error.count) else {
            throw RuntimeError.message(String(cString: error))
        }
        self.handle = handle
    }
    // Destruction can block in the SDK. The owner confines it to its worker;
    // the supervisor can terminate this entire process within a finite deadline.
    func close() {
        guard !closed else { return }; closed = true
        eucaly_ndi_close(handle)
    }
    deinit { close() }
    enum RuntimeError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
    }
}

/// One bounded latest-frame mailbox. DispatchSource coalesces clock ticks if
/// NDI blocks. Neither SDK calls nor its cleanup run on the control/UI queues.
final class NDISubmissionWorker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.suku.eucaly.ndi.sdk-submission", qos: .userInitiated)
    private let fences = DispatchQueue(label: "com.suku.eucaly.ndi.audio-fences", qos: .userInitiated)
    private let audioCalls = DispatchGroup()
    private var audioInProgress = false // protected by lock
    private var lastAudioSample: Int64? // protected by lock; reset only by ownership fences
    private let lock = NSLock()
    private var contentEpoch: UInt64 = 0
    private var currentEpoch: UInt64 = 0
    private var pending: NDIGPUFrame?
    private var report = NDIHelperStatus()
    private var fault = ""
    private var runtime: NetworkHelperRuntime?
    private var timer: DispatchSourceTimer?
    private var current: NDIGPUFrame?
    // Held until the NEXT SDK send/flush returns, not just the async call itself.
    private var borrowed: NDIGPUFrame?
    private weak var submittedPicture: NDIGPUFrame?
    private var lastTick: UInt64 = 0
    private var metrics = NDISubmissionMetrics()
    private var stopping = false // protected by lock; blocks late GPU/audio handoffs
    private var videoFenceScheduled = false // protected by lock; latest epoch only
    #if DEBUG
    private var videoInProgress = false // protected by lock
    #endif

    func start(name: String, technology: NetworkOutputTechnology = .ndi, completion: @escaping @Sendable (NDIHelperStatus?, String?) -> Void) {
        queue.async { [self] in
            do {
                let runtime = try NetworkHelperRuntime(technology: technology)
                guard runtime.createSender(name: name), let actual = runtime.sourceName else {
                    throw NDIRuntime.RuntimeError.message("The \(technology.title) source could not be created.")
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
    func offer(_ surface: NDIGPUFrame, epoch: UInt64 = 0) {
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
    func status() -> NDIHelperStatus {
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
    func sendAudio(_ block: NDIAudioBlock, epoch: UInt64) -> AudioResult {
        lock.lock()
        guard !stopping, contentEpoch == epoch, let runtime else { lock.unlock(); return .superseded }
        guard !audioInProgress, lastAudioSample.map({ block.sampleTime == $0 + Int64(NDIAudioBlock.samples) }) ?? true else {
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
        NDIAudioTrace.record("sdk-enter", sample: block.sampleTime)
        if NDIAudioTrace.isEnabled {
            block.pcm.withUnsafeBytes { bytes in
                let samples = bytes.bindMemory(to: Float.self)
                if let first = samples.baseAddress, samples.count >= 1920 {
                    NDIAudioTrace.record("sdk-energy", sample: block.sampleTime, frames: 960, sampleRate: 48000,
                        leftRMS: NDIAudioTrace.rms(first, frames: 960),
                        rightRMS: NDIAudioTrace.rms(first + 960, frames: 960))
                }
            }
        }
        #endif
        block.pcm.withUnsafeBytes { runtime.sendAudio($0.baseAddress!, sampleTime: block.sampleTime) }
        let duration = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        #if DEBUG
        NDIAudioTrace.record("sdk-return", sample: block.sampleTime)
        #endif
        lock.lock()
        report.audioBlocks &+= 1; report.lastAudioSample = block.sampleTime
        report.audioSubmissionAgeMilliseconds = age
        report.maximumAudioSubmissionAgeMilliseconds = max(report.maximumAudioSubmissionAgeMilliseconds, age)
        report.audioSubmissionMilliseconds = duration
        report.maximumAudioSubmissionMilliseconds = max(report.maximumAudioSubmissionMilliseconds, duration)
        lock.unlock()
        return .submitted
    }
    #if DEBUG
    func injectFault(_ value: String) { lock.lock(); fault = value; lock.unlock() }
    #endif
    private func tick() {
        lock.lock()
        guard !stopping else { lock.unlock(); return }
        let next = pending, epoch = contentEpoch; pending = nil; let fault = self.fault; lock.unlock()
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
        runtime.sendVideo(current.baseAddress, format: current.format, timecode: Int64(timecode))
        let finished = DispatchTime.now().uptimeNanoseconds
        metrics.submitted(at: finished, newPictureProducedAt: current !== submittedPicture ? current.producedAtNanoseconds : nil)
        withExtendedLifetime(previous) {} // Previous async borrow is now synchronized.
        submittedPicture = current
        borrowed = runtime.borrowsVideoAfterReturn ? current : nil
        let connections = runtime.connections
        let omtStatistics = runtime.omtVideoStatistics
        lock.lock(); report.submittedFrames &+= 1; report.lastTimecode = Int64(timecode)
        report.effectiveFramesPerSecond = metrics.framesPerSecond
        report.slowCadence = metrics.slowCadence; report.frameAgeMilliseconds = metrics.frameAgeMilliseconds
        report.submissionMilliseconds = Double(finished - started) / 1_000_000
        report.omtVideoStatistics = omtStatistics
        report.connections = max(0, Int(connections)); lock.unlock()
    }
    func stop(colour: OutputColour, completion: @escaping @Sendable (NDIHelperShutdown) -> Void) {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            lock.lock()
            stopping = true; pending = nil
            let retiring = runtime; runtime = nil
            lock.unlock()
            // Finish admitted audio before destroying the shared sender. Both
            // workers remain isolated from control and the parent's UI thread.
            audioCalls.notify(queue: queue) { [self] in
                var report = NDIHelperShutdown(terminalPixelBGRA: nil)
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
    private func sendTerminalPicture(_ colour: OutputColour, runtime: NetworkHelperRuntime) -> NDIHelperShutdown {
        func byte(_ value: Double) -> UInt32 { UInt32((min(1, max(0, value)) * 255).rounded()) }
        let pixel = byte(colour.blue) | byte(colour.green) << 8 | byte(colour.red) << 16 | byte(colour.alpha) << 24
        let y = 0.2126 * colour.red + 0.7152 * colour.green + 0.0722 * colour.blue
        let luma = UInt32((16 + 219 * y).rounded())
        let u = UInt32((128 + 224 * (colour.blue - y) / 1.8556).rounded())
        let v = UInt32((128 + 224 * (colour.red - y) / 1.5748).rounded())
        let pair = u | luma << 8 | v << 16 | luma << 24
        let format: NDIVideoPixelFormat = colour.alpha == 1 ? .uyvy : .uyva
        // One bounded shutdown buffer, independent of GPU leases still in use.
        // A single constant colour needs no GPU scheduling during teardown.
        var pixels = [UInt32](repeating: pair, count: format.byteCount / 4)
        if format == .uyva {
            _ = pixels.withUnsafeMutableBytes { bytes in
                bytes.baseAddress!.advanced(by: NDIHelperWire.width * NDIHelperWire.height * 2)
                    .initializeMemory(as: UInt8.self, repeating: UInt8(byte(colour.alpha)), count: NDIHelperWire.width * NDIHelperWire.height)
            }
        }
        let timecode = max(DispatchTime.now().uptimeNanoseconds / 100, lastTick + 1)
        pixels.withUnsafeMutableBytes { bytes in
            runtime.sendVideo(bytes.baseAddress!, format: format, timecode: Int64(timecode))
            runtime.flush()
        }
        return .init(terminalPixelBGRA: pixel, videoFormat: format, terminalUYVY: pair, terminalAlpha: UInt8(byte(colour.alpha)))
    }
}

/// The private audio reader handles one PCM block through SDK completion and
/// acknowledgement, with no dispatch handoff between those stages. Installation
/// and closing share only a short admission lock with the control queue.
final class NDIAudioInput: @unchecked Sendable {
    private struct Target {
        let sender: NDISubmissionWorker
        let peer: NDIMachMessage
    }
    private let lock = NSLock()
    private var target: Target?
    private var closed = false
    func install(_ sender: NDISubmissionWorker, peer: NDIMachMessage) {
        lock.withLock { if !closed { target = .init(sender: sender, peer: peer) } }
    }
    func close() { lock.withLock { closed = true; target = nil } }
    func receive(_ message: NDIMachMessage, generation: UUID, parentPID: Int32,
                 failed: @Sendable (String) -> Void) {
        guard message.senderPID == parentPID, message.packet.generation == generation else { return }
        guard let target = lock.withLock({ closed ? nil : target }) else { return }
        let packet = message.packet
        guard packet.version == NDIHelperWire.version, packet.build == NDIHelperWire.build,
              packet.kind == .audio, message.first == 0, message.second == 0,
              let block = packet.audio, block.isValid else {
            close(); failed("Invalid audio block"); return
        }
        #if DEBUG
        NDIAudioTrace.record("ipc-receive", sample: block.sampleTime, generation: generation)
        #endif
        switch target.sender.sendAudio(block, epoch: packet.contentEpoch) {
        case .submitted, .superseded: break
        case .discontinuity:
            close(); failed("Network output audio discontinuity. Choose Retry to restart this source."); return
        }
        #if DEBUG
        NDIAudioTrace.record("ack-send", sample: block.sampleTime, generation: generation)
        #endif
        guard NDIMachMailbox.send(.init(kind: .audioAccepted, generation: generation,
            revision: UInt64(block.sampleTime)), to: target.peer.second) else {
            close(); failed("Audio acknowledgement failed"); return
        }
    }
}
