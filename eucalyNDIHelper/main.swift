import AppKit
import IOSurface

/// A separate instance per destination. Only an explicit sender configuration
/// loads the SDK. Control remains independent of render and submission work.
final class HelperService: @unchecked Sendable {
    private let generation: UUID
    private let parentPID: Int32
    private let configuration: NDIHelperConfiguration
    private let queue = DispatchQueue(label: "com.suku.eucaly.ndi.helper-control")
    private let worker = DispatchQueue(label: "com.suku.eucaly.ndi.prototype-submission")
    private var control: NDIMachMailbox?
    private var peer: NDIMachMessage?
    private var busy = false
    private var audioBusy = false
    private var lastAudioSample: Int64?
    private var lastRevision: UInt64 = 0
    private var contentEpoch: UInt64 = 0
    @MainActor private var composedText: NDITextRenderRequest?
    @MainActor private var composedTextFrame: NDIGPUFrame?
    private var stopping = false
    private var shutdownComplete = false
    private var terminalColour = OutputColour.black
    private var fault = ""
    private var sender: NDISubmissionWorker?
    private var statusTimer: DispatchSourceTimer?
    #if DEBUG
    private var probe: NDIRuntime? // Confined to worker.
    #endif
    @MainActor private var renderer: OffscreenTextRenderer?
    private var mediaRenderer: OffscreenMediaRenderer? // worker-confined

    init(generation: UUID, parentPID: Int32, configuration: NDIHelperConfiguration) {
        self.generation = generation; self.parentPID = parentPID; self.configuration = configuration
    }

    func start(parentPort: mach_port_t) throws {
        control = try NDIMachMailbox(label: "com.suku.eucaly.ndi.helper-inbox") { [weak self] message in
            guard let self else { return }
            self.queue.sync { self.receive(message) }
        }
        guard NDIMachMailbox.send(.init(kind: .hello, generation: generation), to: parentPort,
                                  first: control!.port) else { throw NDIHelperWire.Failure.unavailable }
    }

    private func receive(_ message: NDIMachMessage) {
        // senderPID comes from the kernel audit trailer, never the JSON payload.
        guard message.senderPID == parentPID, message.packet.generation == generation else { return }
        let packet = message.packet
        guard packet.version == NDIHelperWire.version, packet.build == NDIHelperWire.build else { _exit(65) }
        if stopping {
            if shutdownComplete, packet.kind == .shutdownAccepted, message.first == 0, message.second == 0 { _exit(0) }
            return
        }
        if packet.kind == .accepted {
            guard peer == nil, message.first != 0, message.second != 0 else { _exit(65) }
            peer = message; prepare(); return
        }
        guard peer != nil, packet.kind == .media || (message.first == 0 && message.second == 0) else { _exit(65) }
        switch packet.kind {
        case .route:
            guard packet.contentEpoch >= contentEpoch else { return }
            if packet.contentEpoch != contentEpoch {
                contentEpoch = packet.contentEpoch; lastAudioSample = nil
                sender?.selectContent(epoch: contentEpoch)
            }
        case .render:
            guard let request = packet.request, request.isValid, request.generation == generation,
                  request.revision == packet.revision, !busy, request.revision >= lastRevision else {
                fail("Invalid, busy or stale render request"); return
            }
            busy = true; lastRevision = request.revision
            terminalColour = request.transparent ? .init(alpha: 0) : request.profile.background.colour
            if configuration.purpose == .loopbackProbe || configuration.purpose == .audioProbe {
                #if DEBUG
                if configuration.purpose == .audioProbe { receiveAudioProbe(revision: request.revision) }
                else { receiveProbe(revision: request.revision) }
                #else
                fail("Test receiver is disabled")
                #endif
            } else { render(request, fault: fault) }
        case .media:
            guard configuration.purpose == .sender || configuration.purpose == .renderOnly, let request = packet.media, request.isValid,
                  request.generation == generation, request.contentEpoch == contentEpoch, request.revision == packet.revision, !busy,
                  request.revision >= lastRevision, request.foreground == (message.first != 0),
                  request.background == (message.second != 0) else { fail("Invalid media render request"); return }
            let foreground = message.first == 0 ? nil : IOSurfaceLookupFromMachPort(message.first)
            let background = message.second == 0 ? nil : IOSurfaceLookupFromMachPort(message.second)
            guard (!request.foreground || foreground.map(NDIHelperWire.validMedia) == true),
                  (!request.background || background.map(NDIHelperWire.validMedia) == true) else { fail("Invalid media surface"); return }
            busy = true; lastRevision = request.revision
            terminalColour = request.colour
            renderMedia(request, foreground: foreground, background: background)
        case .ping:
            pong(packet.token)
        case .audio:
            guard let sender, let block = packet.audio, block.isValid, !audioBusy else { fail("Invalid audio block"); return }
            if packet.contentEpoch != contentEpoch {
                if let peer { _ = NDIMachMailbox.send(.init(kind: .audioAccepted, generation: generation, revision: UInt64(block.sampleTime)), to: peer.first) }
                return
            }
            if let lastAudioSample, block.sampleTime != lastAudioSample + Int64(NDIAudioBlock.samples) {
                fail("NDI audio discontinuity. Choose Retry to restart this source."); return
            }
            lastAudioSample = block.sampleTime; audioBusy = true
            sender.sendAudio(block, epoch: contentEpoch) { [self] in
                queue.async { [self] in
                    guard !stopping else { return }
                    audioBusy = false
                    guard let peer, NDIMachMailbox.send(.init(kind: .audioAccepted, generation: generation,
                        revision: UInt64(block.sampleTime)), to: peer.first) else { fail("Audio acknowledgement failed"); return }
                }
            }
        case .fault:
            #if DEBUG
            guard let value = packet.detail, ["stall", "crash", "sdk-stall", "sdk-crash"].contains(value) else {
                fail("Unknown test fault"); return
            }
            fault = value
            sender?.injectFault(value)
            if value == "stall" || value == "sdk-stall" { signal(SIGTERM, SIG_IGN) }
            pong(packet.token)
            #else
            fail("Test faults are disabled")
            #endif
        case .stop:
            // A blocked submission/cleanup worker is contained by the parent's
            // hard termination path, independently of this live control queue.
            stopping = true; statusTimer?.cancel(); statusTimer = nil
            if let sender {
                sender.stop(colour: terminalColour) { [self] report in
                    queue.async { [self] in
                        shutdownComplete = true
                        guard let peer, NDIMachMailbox.send(.init(kind: .shutdownComplete, generation: generation,
                            shutdown: report), to: peer.first) else { _exit(70) }
                    }
                }
            }
            else { worker.async { _exit(0) } }
        default:
            fail("Unexpected control message")
        }
    }

    private func prepare() {
        switch configuration.purpose {
        case .renderOnly: ready(nil)
        case .sender:
            let sender = NDISubmissionWorker(); self.sender = sender
            sender.start(name: configuration.sourceName) { [self] status, error in
                queue.async { [self] in
                    guard !stopping else { return }
                    guard let status else { fail(error ?? "NDI startup failed"); return }
                    ready(status)
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
                    timer.setEventHandler { [weak self] in
                        guard let self, let peer = self.peer else { return }
                        if !NDIMachMailbox.send(.init(kind: .status, generation: self.generation, status: sender.status()), to: peer.first) {
                            self.fail("Output status queue unavailable")
                        }
                    }
                    statusTimer = timer; timer.resume()
                }
            }
        case .loopbackProbe, .audioProbe:
            #if DEBUG
            worker.async { [self] in
                do {
                    let runtime = try NDIRuntime()
                    guard eucaly_ndi_create_probe(runtime.handle, configuration.sourceName) else {
                        throw NDIRuntime.RuntimeError.message("Loopback receiver could not start")
                    }
                    probe = runtime
                    let status = NDIHelperStatus(runtimeVersion: runtime.version, sourceName: configuration.sourceName)
                    queue.async { [self] in ready(status) }
                } catch { queue.async { [self] in fail(error.localizedDescription) } }
            }
            #else
            fail("Test receiver is disabled")
            #endif
        }
    }
    private func ready(_ status: NDIHelperStatus?) {
        guard let peer, NDIMachMailbox.send(.init(kind: .ready, generation: generation, status: status), to: peer.first) else { _exit(70) }
    }

    private func render(_ request: NDITextRenderRequest, fault: String) {
        worker.async { [self] in
            #if DEBUG
            if fault == "crash" { _exit(71) }
            if fault == "stall" { DispatchSemaphore(value: 0).wait() }
            #endif
            DispatchQueue.main.async { [self] in
                do {
                    if renderer == nil { renderer = try OffscreenTextRenderer(pooled: configuration.purpose == .sender) }
                    try renderer?.render(request) { [self] surface, error in
                        queue.async { [self] in complete(surface, revision: request.revision, error: error, producedAt: request.producedAtNanoseconds) }
                    }
                } catch {
                    queue.async { [self] in fail("Offscreen rendering failed") }
                }
            }
        }
    }

    private func renderMedia(_ request: NDIMediaRenderRequest, foreground: IOSurface?, background: IOSurface?) {
        if let text = request.text {
            DispatchQueue.main.async { [self] in
                do {
                    if composedText?.text == text.text, composedText?.profile == text.profile, let frame = composedTextFrame {
                        composite(request, foreground: frame.surface, background: background, textFrame: frame)
                        return
                    }
                    // Text is an immutable cached layer, separate from the four
                    // output leases held by the SDK/GPU composition pool.
                    if renderer == nil { renderer = try OffscreenTextRenderer(pooled: false) }
                    try renderer?.render(text) { [self] frame, error in
                        DispatchQueue.main.async { [self] in
                            if let frame, error == nil {
                                composedText = text; composedTextFrame = frame
                                composite(request, foreground: frame.surface, background: background, textFrame: frame)
                            } else { queue.async { [self] in complete(nil, revision: request.revision, error: error ?? "Text rendering failed", epoch: request.contentEpoch) } }
                        }
                    }
                } catch { queue.async { [self] in complete(nil, revision: request.revision, error: "Text rendering failed", epoch: request.contentEpoch) } }
            }
        } else { composite(request, foreground: foreground, background: background) }
    }
    private func composite(_ request: NDIMediaRenderRequest, foreground: IOSurface?, background: IOSurface?, textFrame: NDIGPUFrame? = nil) {
        worker.async { [self] in
            do {
                if mediaRenderer == nil { mediaRenderer = try OffscreenMediaRenderer(pooled: configuration.purpose == .sender) }
                try mediaRenderer?.render(request, foreground: foreground, background: background) { [self] frame, error in
                    withExtendedLifetime(textFrame) {}
                    queue.async { [self] in complete(frame, revision: request.revision, error: error,
                        producedAt: request.producedAtNanoseconds, epoch: request.contentEpoch) }
                }
            } catch { queue.async { [self] in complete(nil, revision: request.revision, error: "Media rendering failed", epoch: request.contentEpoch) } }
        }
    }

    private func complete(_ frame: NDIGPUFrame?, revision: UInt64, error: String?, producedAt: UInt64 = 0, epoch: UInt64 = 0) {
        guard !stopping else { return }
        if sender != nil, epoch != contentEpoch {
            // Old-owner GPU success and failure have the same disposition:
            // release the input lease and let the new owner's work proceed.
            busy = false
            if let peer, !NDIMachMailbox.send(.init(kind: .rendered, generation: generation, revision: revision), to: peer.second) {
                fail("Frame acknowledgement queue unavailable")
            }
            return
        }
        guard error == nil, let frame, NDIHelperWire.valid(frame.surface), let peer else {
            fail(error ?? "Invalid rendered surface"); return
        }
        let surface = frame.surface
        if producedAt > 0 { frame.producedAtNanoseconds = producedAt }
        if let sender {
            if epoch == contentEpoch { sender.offer(frame, epoch: epoch) }; busy = false
            // Actual pixels remain in this helper. This acknowledges rendering,
            // not SDK submission or receipt; separate progress reports do that.
            if !NDIMachMailbox.send(.init(kind: .rendered, generation: generation, revision: revision), to: peer.second) {
                fail("Frame acknowledgement queue unavailable")
            }
            return
        }
        let right = IOSurfaceCreateMachPort(surface)
        guard right != 0 else { fail("Surface handoff failed"); return }
        defer { eucaly_mach_send_release(right) }
        busy = false
        // COPY_SEND gives the receiver its own reference. Never export a global
        // IOSurface ID or recycle a surface while another process can hold it.
        if !NDIMachMailbox.send(.init(kind: .frame, generation: generation, revision: revision),
                               to: peer.second, first: right) {
            fail("Frame queue unavailable")
        }
    }

    #if DEBUG
    private func receiveAudioProbe(revision: UInt64) {
        worker.async { [self] in
            guard let probe else { return }
            for _ in 0..<40 {
                var result = eucaly_ndi_audio_observation()
                let status = eucaly_ndi_probe_audio(probe.handle, &result)
                if status > 0 {
                    let observation = NDIAudioObservation(samples: Int(result.samples), sampleRate: Int(result.sample_rate),
                        timecode: result.timecode, left: result.left, right: result.right)
                    queue.async { [self] in
                        busy = false
                        guard let peer, NDIMachMailbox.send(.init(kind: .audioFrame, generation: generation, revision: revision,
                            observation: observation), to: peer.second) else { fail("Audio probe handoff failed"); return }
                    }
                    return
                }
                if status < 0 { break }
            }
            queue.async { [self] in fail("Loopback did not receive valid stereo audio") }
        }
    }
    private func receiveProbe(revision: UInt64) {
        worker.async { [self] in
            guard let probe, let surface = IOSurface(properties: [.width: NDIHelperWire.width, .height: NDIHelperWire.height,
                .bytesPerElement: 4, .bytesPerRow: NDIHelperWire.width * 4,
                .allocSize: NDIHelperWire.maximumSurfaceBytes, .pixelFormat: 0x42475241]) else {
                queue.async { [self] in fail("Loopback buffer unavailable") }; return
            }
            for _ in 0..<40 {
                var timecode: Int64 = 0
                let result = eucaly_ndi_probe_frame(probe.handle, surface.baseAddress, surface.allocationSize, &timecode)
                if result > 0 {
                    let report = NDIHelperStatus(runtimeVersion: probe.version, sourceName: configuration.sourceName, lastTimecode: timecode)
                    queue.async { [self] in
                        if let peer { _ = NDIMachMailbox.send(.init(kind: .status, generation: generation, status: report), to: peer.first) }
                        complete(NDIGPUFrame(surface), revision: revision, error: nil)
                    }
                    return
                }
                if result < 0 { break }
            }
            queue.async { [self] in fail("Loopback did not receive a valid 1080p30 BGRA frame") }
        }
    }
    #endif

    private func pong(_ token: UUID?) {
        guard let peer, let token else { return }
        if !NDIMachMailbox.send(.init(kind: .pong, generation: generation, token: token), to: peer.first) { _exit(70) }
    }
    private func fail(_ detail: String) {
        guard !stopping else { return }
        if let peer { _ = NDIMachMailbox.send(.init(kind: .failure, generation: generation, detail: detail), to: peer.first) }
        _exit(70)
    }
}

// Explicit read-only qualification command for the installed, signed helper.
// It neither creates a sender nor opens a window. The caller owns a finite
// process deadline just as the app supervisor does.
if CommandLine.arguments == [CommandLine.arguments[0], "--check-runtime"] {
    do {
        let runtime = try NDIRuntime()
        let result = ["runtime": runtime.version]
        let data = try JSONEncoder().encode(result)
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        withExtendedLifetime(runtime) {}
        exit(0)
    } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1)
    }
}

// stdin is an inherited private pipe, not a discoverable service name. Bound
// the bootstrap before decoding, then claim the inherited send capability.
let bootstrapData = FileHandle.standardInput.readData(ofLength: NDIHelperWire.maximumMessageBytes + 1)
guard let bootstrap = try? NDIHelperWire.decode(NDIHelperBootstrap.self, bootstrapData),
      bootstrap.version == NDIHelperWire.version, bootstrap.build == NDIHelperWire.build,
      bootstrap.parentPID == getppid(), (0..<3).contains(bootstrap.portIndex), bootstrap.configuration.isValid else { _exit(64) }
let parentPort = eucaly_mach_inherited_port(bootstrap.portIndex)
guard parentPort != 0 else { _exit(64) }
NSApplication.shared.setActivationPolicy(.prohibited)
let parent = DispatchSource.makeProcessSource(identifier: bootstrap.parentPID, eventMask: .exit, queue: .global())
parent.setEventHandler { _exit(0) }; parent.resume()
guard getppid() == bootstrap.parentPID else { _exit(0) }
let service = HelperService(generation: bootstrap.generation, parentPID: bootstrap.parentPID, configuration: bootstrap.configuration)
do { try service.start(parentPort: parentPort) } catch { _exit(70) }
eucaly_mach_send_release(parentPort)
NSApplication.shared.run()
