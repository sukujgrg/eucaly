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
    private let audioQueue = DispatchQueue(label: "com.suku.eucaly.ndi.sdk-audio", qos: .userInitiated)
    private let lock = NSLock()
    private var contentEpoch: UInt64 = 0
    private var currentEpoch: UInt64 = 0
    private var pending: NDIGPUFrame?
    private var report = NDIHelperStatus()
    private var fault = ""
    private var runtime: NDIRuntime?
    private var timer: DispatchSourceTimer?
    private var current: NDIGPUFrame?
    // Held until the NEXT SDK send/flush returns, not just the async call itself.
    private var borrowed: NDIGPUFrame?
    private var lastTick: UInt64 = 0
    private var metrics = NDISubmissionMetrics()
    private var stopping = false // protected by lock; blocks late GPU/audio handoffs

    func start(name: String, completion: @escaping @Sendable (NDIHelperStatus?, String?) -> Void) {
        queue.async { [self] in
            do {
                let runtime = try NDIRuntime()
                guard eucaly_ndi_create_sender(runtime.handle, name), let actual = eucaly_ndi_source_name(runtime.handle) else {
                    throw NDIRuntime.RuntimeError.message("The NDI source could not be created.")
                }
                lock.lock()
                self.runtime = runtime
                report.runtimeVersion = runtime.version; report.sourceName = String(cString: actual)
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
    func selectContent(epoch: UInt64) {
        lock.lock(); contentEpoch = epoch; pending = nil; lock.unlock()
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
        lock.lock(); var value = report; lock.unlock()
        #if DEBUG
        var usage = rusage()
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            value.processCPUSeconds = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        }
        #endif
        return value
    }
    func sendAudio(_ block: NDIAudioBlock, epoch: UInt64 = 0, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        guard !stopping, let runtime else { lock.unlock(); return }
        // One request is admitted by the service. This strong runtime reference
        // keeps the sender alive if the video worker concurrently starts cleanup.
        audioQueue.async { [self, runtime] in
            lock.lock(); let accepted = contentEpoch == epoch; lock.unlock()
            guard accepted else { completion(); return }
            block.pcm.withUnsafeBytes { eucaly_ndi_send_audio(runtime.handle, $0.baseAddress!, block.sampleTime) }
            lock.lock(); report.audioBlocks &+= 1; report.lastAudioSample = block.sampleTime; lock.unlock()
            completion()
        }
        // Enqueue under the lock so Stop's audio barrier cannot overtake a
        // handoff that has already acquired the runtime.
        lock.unlock()
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
        if fault == "sdk-stall" { DispatchSemaphore(value: 0).wait() }
        if fault == "sdk-crash" { _exit(72) }
        #endif
        // Timecode is monotonic and never follows a source player's seek/loop.
        let started = DispatchTime.now().uptimeNanoseconds
        let tick = started / 100
        let timecode = max(tick, lastTick + 1); lastTick = timecode
        let previous = borrowed
        if current.format == .bgra {
            // Only the explicit Debug comparison configuration produces BGRA.
            eucaly_ndi_send_bgra(runtime.handle, current.baseAddress, Int32(NDIHelperWire.width), Int32(NDIHelperWire.height),
                                Int32(current.format.bytesPerRow), Int64(timecode))
        } else {
            eucaly_ndi_send_yuv(runtime.handle, current.baseAddress, Int32(NDIHelperWire.width), Int32(NDIHelperWire.height),
                               Int32(current.format.bytesPerRow), current.format == .uyva, Int64(timecode))
        }
        let finished = DispatchTime.now().uptimeNanoseconds
        metrics.submitted(at: finished, newPictureProducedAt: current !== previous ? current.producedAtNanoseconds : nil)
        withExtendedLifetime(previous) {} // Previous async borrow is now synchronized.
        borrowed = current
        let connections = eucaly_ndi_connections(runtime.handle)
        lock.lock(); report.submittedFrames &+= 1; report.lastTimecode = Int64(timecode)
        report.effectiveFramesPerSecond = metrics.framesPerSecond
        report.slowCadence = metrics.slowCadence; report.frameAgeMilliseconds = metrics.frameAgeMilliseconds
        report.submissionMilliseconds = Double(finished - started) / 1_000_000
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
            audioQueue.async { [self] in
                queue.async { [self] in
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
    }
    private func sendTerminalPicture(_ colour: OutputColour, runtime: NDIRuntime) -> NDIHelperShutdown {
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
            eucaly_ndi_send_yuv(runtime.handle, bytes.baseAddress!, Int32(NDIHelperWire.width), Int32(NDIHelperWire.height),
                               Int32(format.bytesPerRow), format == .uyva, Int64(timecode))
            eucaly_ndi_flush(runtime.handle)
        }
        return .init(terminalPixelBGRA: pixel, videoFormat: format, terminalUYVY: pair, terminalAlpha: UInt8(byte(colour.alpha)))
    }
}
