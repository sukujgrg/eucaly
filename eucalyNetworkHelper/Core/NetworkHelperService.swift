import AppKit
import IOSurface
import Darwin

/// A separate instance per destination. Only an explicit sender configuration
/// loads the SDK. Control remains independent of render and submission work.
final class NetworkHelperService: @unchecked Sendable {
    private let generation: UUID
    private let parentPID: Int32
    private let configuration: NetworkHelperConfiguration
    private let queue = DispatchQueue(label: "com.suku.eucaly.network.helper-control", qos: .userInitiated)
    private let worker = DispatchQueue(label: "com.suku.eucaly.network.prototype-submission", qos: .userInitiated)
    private var control: NetworkMachMailbox?
    private var audio: NetworkMachMailbox?
    private var peer: NetworkMachMessage?
    private var busy = false
    private let audioInput = NetworkAudioInput()
    private var lastRevision: UInt64 = 0
    private var contentEpoch: UInt64 = 0
    @MainActor private var composedText: NetworkTextRenderRequest?
    @MainActor private var composedTextFrame: GPUFrameLease?
    private var stopping = false
    private var shutdownComplete = false
    private var terminalColour = OutputColour.black
    private var fault = ""
    private var sender: NetworkSubmissionWorker?
    private var statusTimer: DispatchSourceTimer?
    private var liveActivity: NSObjectProtocol?
    #if DEBUG
    private var probe: NetworkHelperRuntime? // Confined to worker.
    #endif
    @MainActor private var renderer: OffscreenTextRenderer?
    private var mediaRenderer: OffscreenMediaRenderer? // worker-confined

    init(generation: UUID, parentPID: Int32, configuration: NetworkHelperConfiguration) {
        self.generation = generation; self.parentPID = parentPID; self.configuration = configuration
    }

    func start(parentPort: mach_port_t) throws {
        control = try NetworkMachMailbox(label: "com.suku.eucaly.network.helper-inbox", queue: queue) { [weak self] message in
            self?.receive(message)
        }
        audio = try NetworkMachMailbox(label: "com.suku.eucaly.network.helper-audio-inbox") { [weak self] message in
            guard let self else { return }
            audioInput.receive(message, generation: generation, parentPID: parentPID) { [weak self] reason in
                self?.queue.async { [weak self] in self?.fail(reason) }
            }
        }
        guard NetworkMachMailbox.send(.init(kind: .hello, generation: generation), to: parentPort,
                                  first: control!.port, second: audio!.port) else { throw NetworkHelperWire.Failure.unavailable }
    }

    private func receive(_ message: NetworkMachMessage) {
        // senderPID comes from the kernel audit trailer, never the JSON payload.
        guard message.senderPID == parentPID, message.packet.generation == generation else { return }
        let packet = message.packet
        #if DEBUG
        NetworkAudioTrace.record("control-start-\(packet.kind.rawValue)", sample: packet.audio?.sampleTime ?? 0, generation: generation)
        defer { NetworkAudioTrace.record("control-end-\(packet.kind.rawValue)", sample: packet.audio?.sampleTime ?? 0, generation: generation) }
        #endif
        guard packet.version == NetworkHelperWire.version, packet.build == NetworkHelperWire.build else { _exit(65) }
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
            let epoch = packet.contentEpoch
            contentEpoch = epoch
            if let sender {
                sender.selectContent(epoch: epoch) { [weak self] in
                    self?.queue.async { [weak self] in self?.acknowledgeRoute(epoch) }
                }
            } else {
                acknowledgeRoute(epoch)
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
            guard configuration.purpose == .sender || configuration.purpose == .renderOnly || configuration.purpose == .renderYUV, let request = packet.media, request.isValid,
                  request.generation == generation, request.contentEpoch == contentEpoch, request.revision == packet.revision, !busy,
                  request.revision >= lastRevision, request.foreground == (message.first != 0),
                  request.background == (message.second != 0) else { fail("Invalid media render request"); return }
            let foreground = message.first == 0 ? nil : IOSurfaceLookupFromMachPort(message.first)
            let background = message.second == 0 ? nil : IOSurfaceLookupFromMachPort(message.second)
            guard (!request.foreground || foreground.map(request.foregroundInput.matches) == true),
                  (!request.background || background.map(request.backgroundInput.matches) == true) else { fail("Invalid media surface"); return }
            busy = true; lastRevision = request.revision
            terminalColour = request.colour
            renderMedia(request, foreground: foreground, background: background)
        case .ping:
            pong(packet.token)
        case .fault:
            #if DEBUG
            guard let value = packet.detail, ["stall", "crash", "sdk-stall", "sdk-crash", "audio-stall", "broken-pipe"].contains(value) else {
                fail("Unknown test fault"); return
            }
            if value == "broken-pipe" {
                guard exerciseBrokenPipe() else { return }
                pong(packet.token)
                return
            }
            fault = value
            sender?.injectFault(value)
            if value == "stall" || value == "sdk-stall" || value == "audio-stall" { signal(SIGTERM, SIG_IGN) }
            pong(packet.token)
            #else
            fail("Test faults are disabled")
            #endif
        case .stop:
            #if DEBUG
            NetworkAudioTrace.flush()
            #endif
            // A blocked submission/cleanup worker is contained by the parent's
            // hard termination path, independently of this live control queue.
            stopping = true; audioInput.close(); statusTimer?.cancel(); statusTimer = nil
            if let sender {
                sender.stop(colour: terminalColour) { [self] report in
                    queue.async { [self] in
                        endLiveActivity()
                        shutdownComplete = true
                        guard let peer, NetworkMachMailbox.send(.init(kind: .shutdownComplete, generation: generation,
                            shutdown: report), to: peer.first) else { _exit(70) }
                    }
                }
            }
            else { endLiveActivity(); worker.async { _exit(0) } }
        default:
            fail("Unexpected control message")
        }
    }

    #if DEBUG
    /// A real closed stream exercises the helper's process signal policy. The
    /// acknowledgement proves write returned EPIPE, rather than hiding the
    /// error or merely delivering a synthetic signal.
    private func exerciseBrokenPipe() -> Bool {
        var sockets: [Int32] = [-1, -1]
        guard Darwin.socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            fail("Broken-pipe diagnostic could not create its socket pair"); return false
        }
        defer {
            _ = Darwin.close(sockets[0])
            if sockets[1] >= 0 { _ = Darwin.close(sockets[1]) }
        }
        guard Darwin.close(sockets[1]) == 0 else {
            fail("Broken-pipe diagnostic could not close its peer"); return false
        }
        sockets[1] = -1
        var byte: UInt8 = 1
        let result = Darwin.write(sockets[0], &byte, 1)
        let error = errno
        guard result == -1, error == EPIPE else {
            fail("Broken-pipe diagnostic expected EPIPE, received write \(result), errno \(error)"); return false
        }
        return true
    }
    #endif

    private func prepare() {
        switch configuration.purpose {
        case .sender, .loopbackProbe, .audioProbe:
            // AppKit's windowless role caps all queues at default QoS, even
            // when they request userInitiated. This child performs the app's
            // explicit live presentation work. Classify it as an application
            // component so those normal per-thread QoS requests can take effect.
            // This sets neither foreground status nor a real-time priority;
            // the classification belongs only to this short-lived child.
            var category = task_category_policy_data_t(role: TASK_DEFAULT_APPLICATION)
            let policyCount = MemoryLayout<task_category_policy_data_t>.size / MemoryLayout<integer_t>.size
            let configured = withUnsafeMutablePointer(to: &category) { policy in
                policy.withMemoryRebound(to: integer_t.self, capacity: policyCount) {
                    task_policy_set(mach_task_self_, UInt32(TASK_CATEGORY_POLICY), $0, UInt32(policyCount))
                }
            }
            guard configured == KERN_SUCCESS else {
                fail("Could not configure the live output helper's scheduling (\(configured)). Choose Retry to restart this source.")
                return
            }
            // The parent activity does not describe this separate process's
            // live work. Audio's 20 ms deadlines require precise I/O/timer
            // scheduling as well as App Nap prevention. Scope that request to
            // this source's lifetime; the app still owns sleep policy.
            liveActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Sending or monitoring live network video and audio")
        default: break
        }
        switch configuration.purpose {
        case .renderOnly, .renderYUV: ready(nil)
        case .sender:
            let sender = NetworkSubmissionWorker(); self.sender = sender
            sender.start(name: configuration.sourceName, technology: configuration.technology, generation: self.generation) { [self] status, error in
                queue.async { [self] in
                    guard !stopping else { return }
                    guard let status else { fail(error ?? "\(configuration.technology.title) startup failed"); return }
                    if let peer { audioInput.install(sender, peer: peer) }
                    ready(status)
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
                    timer.setEventHandler { [weak self] in
                        guard let self, let peer = self.peer else { return }
                        if !NetworkMachMailbox.send(.init(kind: .status, generation: self.generation, status: sender.status()), to: peer.first) {
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
                    let runtime = try NetworkHelperRuntime(technology: configuration.technology)
                    guard runtime.createProbe(source: configuration.sourceName, audioOnly: configuration.purpose == .audioProbe) else {
                        throw NetworkHelperError.message("Loopback receiver could not start")
                    }
                    probe = runtime
                    let status = NetworkHelperStatus(runtimeVersion: runtime.version, sourceName: configuration.sourceName)
                    queue.async { [self] in ready(status) }
                } catch { queue.async { [self] in fail(error.localizedDescription) } }
            }
            #else
            fail("Test receiver is disabled")
            #endif
        }
    }

    private func endLiveActivity() {
        guard let activity = liveActivity else { return }
        liveActivity = nil
        ProcessInfo.processInfo.endActivity(activity)
    }

    deinit {
        if let liveActivity { ProcessInfo.processInfo.endActivity(liveActivity) }
    }
    private func ready(_ status: NetworkHelperStatus?) {
        guard let peer, NetworkMachMailbox.send(.init(kind: .ready, generation: generation, status: status), to: peer.first) else { _exit(70) }
    }

    private func render(_ request: NetworkTextRenderRequest, fault: String) {
        let epoch = contentEpoch
        worker.async { [self] in
            #if DEBUG
            if fault == "crash" { _exit(71) }
            if fault == "stall" { DispatchSemaphore(value: 0).wait() }
            #endif
            if configuration.purpose == .sender || configuration.purpose == .renderYUV {
                // Text-only sends use the same final compositor and format as
                // mixed media; the cached text layer itself remains BGRA.
                let layer = NetworkTextRenderRequest(generation: request.generation, revision: request.revision,
                    text: request.text, profile: request.profile, transparent: true)
                let media = NetworkMediaRenderRequest(generation: request.generation, revision: request.revision,
                    contentEpoch: epoch, text: request.text.isEmpty ? nil : layer,
                    colour: request.transparent ? .init(alpha: 0) : request.profile.background.colour,
                    producedAtNanoseconds: request.producedAtNanoseconds)
                renderMedia(media, foreground: nil, background: nil)
                return
            }
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

    private func renderMedia(_ request: NetworkMediaRenderRequest, foreground: IOSurface?, background: IOSurface?) {
        if let text = request.text {
            DispatchQueue.main.async { [self] in
                do {
                    if composedText?.text == text.text, composedText?.profile == text.profile, let frame = composedTextFrame, let surface = frame.surface {
                        composite(request, foreground: surface, background: background, textFrame: frame)
                        return
                    }
                    // Text is an immutable cached layer, separate from the four
                    // output leases held by the SDK/GPU composition pool.
                    if renderer == nil { renderer = try OffscreenTextRenderer(pooled: false) }
                    try renderer?.render(text) { [self] frame, error in
                        DispatchQueue.main.async { [self] in
                            if let frame, let surface = frame.surface, error == nil {
                                composedText = text; composedTextFrame = frame
                                composite(request, foreground: surface, background: background, textFrame: frame)
                            } else { queue.async { [self] in complete(nil, revision: request.revision, error: error ?? "Text rendering failed", epoch: request.contentEpoch) } }
                        }
                    }
                } catch { queue.async { [self] in complete(nil, revision: request.revision, error: "Text rendering failed", epoch: request.contentEpoch) } }
            }
        } else { composite(request, foreground: foreground, background: background) }
    }
    private func composite(_ request: NetworkMediaRenderRequest, foreground: IOSurface?, background: IOSurface?, textFrame: GPUFrameLease? = nil) {
        worker.async { [self] in
            do {
                if mediaRenderer == nil {
                    mediaRenderer = try OffscreenMediaRenderer(pooled: configuration.purpose == .sender,
                        packedVideo: configuration.purpose != .renderOnly && !configuration.referenceBGRA)
                }
                try mediaRenderer?.render(request, foreground: foreground, background: background) { [self] frame, error in
                    withExtendedLifetime(textFrame) {}
                    queue.async { [self] in complete(frame, revision: request.revision, error: error,
                        producedAt: request.producedAtNanoseconds, epoch: request.contentEpoch) }
                }
            } catch { queue.async { [self] in complete(nil, revision: request.revision, error: "Media rendering failed", epoch: request.contentEpoch) } }
        }
    }

    private func complete(_ frame: GPUFrameLease?, revision: UInt64, error: String?, producedAt: UInt64 = 0, epoch: UInt64 = 0,
                          probeStatus: NetworkHelperStatus? = nil) {
        guard !stopping else { return }
        if sender != nil, epoch != contentEpoch {
            // Old-owner GPU success and failure have the same disposition:
            // release the input lease and let the new owner's work proceed.
            busy = false
            if let peer, !NetworkMachMailbox.send(.init(kind: .rendered, generation: generation, revision: revision), to: peer.second) {
                fail("Frame acknowledgement queue unavailable")
            }
            return
        }
        guard error == nil, let frame, frame.isValid, let peer else {
            fail(error ?? "Invalid rendered surface"); return
        }
        if producedAt > 0 { frame.producedAtNanoseconds = producedAt }
        if let sender {
            if epoch == contentEpoch { sender.offer(frame, epoch: epoch) }; busy = false
            // Actual pixels remain in this helper. This acknowledges rendering,
            // not SDK submission or receipt; separate progress reports do that.
            if !NetworkMachMailbox.send(.init(kind: .rendered, generation: generation, revision: revision), to: peer.second) {
                fail("Frame acknowledgement queue unavailable")
            }
            return
        }
        let surface: IOSurface
        do {
            #if DEBUG
            surface = try frame.exportedSurface()
            #else
            guard let value = frame.surface else { throw NetworkHelperWire.Failure.invalidSurface }
            surface = value
            #endif
        } catch { fail("Surface export failed"); return }
        let right = IOSurfaceCreateMachPort(surface)
        guard right != 0 else { fail("Surface handoff failed"); return }
        defer { eucaly_mach_send_release(right) }
        busy = false
        // COPY_SEND gives the receiver its own reference. Never export a global
        // IOSurface ID or recycle a surface while another process can hold it.
        if !NetworkMachMailbox.send(.init(kind: .frame, generation: generation, revision: revision, status: probeStatus),
                               to: peer.second, first: right) {
            fail("Frame queue unavailable")
        }
    }

    #if DEBUG
    private func receiveAudioProbe(revision: UInt64) {
        worker.async { [self] in
            guard let probe else { return }
            for _ in 0..<40 {
                let result = probe.probeAudio()
                if case .received(let observation) = result {
                    NetworkAudioTrace.record("recv-energy", sample: observation.timecode * 48000 / 10000000,
                        frames: observation.samples, sampleRate: Double(observation.sampleRate),
                        leftRMS: observation.leftRMS, rightRMS: observation.rightRMS)
                    queue.async { [self] in
                        busy = false
                        guard let peer, NetworkMachMailbox.send(.init(kind: .audioFrame, generation: generation, revision: revision,
                            observation: observation), to: peer.second) else { fail("Audio probe handoff failed"); return }
                    }
                    return
                }
                if case .invalid = result { break }
            }
            queue.async { [self] in fail("Loopback did not receive valid stereo audio") }
        }
    }
    private func receiveProbe(revision: UInt64) {
        worker.async { [self] in
            guard let probe, let surface = IOSurface(properties: [.width: NetworkHelperWire.width, .height: NetworkHelperWire.height,
                .bytesPerElement: 4, .bytesPerRow: NetworkHelperWire.width * 4,
                .allocSize: NetworkHelperWire.maximumSurfaceBytes, .pixelFormat: 0x42475241]) else {
                queue.async { [self] in fail("Loopback buffer unavailable") }; return
            }
            for _ in 0..<40 {
                let result = probe.probeFrame(bytes: surface.baseAddress, capacity: surface.allocationSize)
                if case .received(let timecode) = result {
                    let report = NetworkHelperStatus(runtimeVersion: probe.version, sourceName: configuration.sourceName, lastTimecode: timecode)
                    queue.async { [self] in
                        // Receiver pixels and their timecode are one observation.
                        // Separate control/frame ports can be delivered in either
                        // order, pairing a new picture with an older timestamp.
                        complete(GPUFrameLease(surface), revision: revision, error: nil, probeStatus: report)
                    }
                    return
                }
                if case .invalid = result { break }
            }
            queue.async { [self] in fail("Loopback did not receive a valid 1080p30 BGRA frame") }
        }
    }
    #endif

    private func acknowledgeRoute(_ epoch: UInt64) {
        guard !stopping, contentEpoch == epoch else { return }
        guard let peer, NetworkMachMailbox.send(.init(kind: .routeAccepted, generation: generation,
            contentEpoch: epoch), to: peer.first) else { fail("Ownership acknowledgement failed"); return }
    }

    private func pong(_ token: UUID?) {
        guard let peer, let token else { return }
        if !NetworkMachMailbox.send(.init(kind: .pong, generation: generation, token: token), to: peer.first) { _exit(70) }
    }
    private func fail(_ detail: String) {
        guard !stopping else { return }
        if let peer { _ = NetworkMachMailbox.send(.init(kind: .failure, generation: generation, detail: detail), to: peer.first) }
        endLiveActivity()
        _exit(70)
    }
}
