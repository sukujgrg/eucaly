import Foundation
import IOSurface
import Security

/// Owns the exact launched Process until exit. All launch, IPC and termination
/// work happens off the UI thread. Each destination gets its own instance.
nonisolated final class NDIHelperSupervisor: @unchecked Sendable {
    enum Event: Sendable {
        case ready(UUID), frame(UUID, UInt64, IOSurface), rendered(UUID, UInt64)
        case status(UUID, NDIHelperStatus), failed(UUID, String), exited(UUID)
        case audio(UUID, NDIAudioObservation)
        case shutdown(UUID, NDIHelperShutdown)
    }
    private let queue = DispatchQueue(label: "com.suku.eucaly.ndi.supervisor")
    private let event: @Sendable (Event) -> Void
    private let progressDeadline: TimeInterval
    private var process: Process?
    private var control: NDIMachMailbox?
    private var frames: NDIMachMailbox?
    private var peer: NDIMachMessage?
    private var timer: DispatchSourceTimer?
    private var generation = UUID()
    private var startedAt: TimeInterval = 0
    private var workStartedAt: TimeInterval?
    private var readyState = false
    private var stopping = false
    private var exitWaiters: [CheckedContinuation<Void, Never>] = []
    private enum RenderJob: Sendable {
        case text(NDITextRenderRequest), media(NDIMediaSubmission)
        var generation: UUID { switch self { case .text(let v): v.generation; case .media(let v): v.request.generation } }
        var revision: UInt64 { switch self { case .text(let v): v.revision; case .media(let v): v.request.revision } }
        var contentEpoch: UInt64 { switch self { case .text: 0; case .media(let value): value.request.contentEpoch } }
        var isValid: Bool { switch self { case .text(let v): v.isValid; case .media(let v): v.isValid } }
    }
    private var pending: RenderJob?
    private var latestRevision: UInt64 = 0
    private var inFlight: RenderJob?
    private var configuration = NDIHelperConfiguration()
    private var submissionProgressAt: TimeInterval?
    private var submittedFrames: UInt64 = 0
    #if DEBUG
    private var replies: [UUID: @Sendable () -> Void] = [:]
    #endif
    private let admission = NSLock()
    private var contentEpoch: UInt64 = 0
    private var admittedContentEpoch: UInt64 = 0
    private var admittedGeneration: UUID?
    private var staged: RenderJob?
    private var drainScheduled = false
    private var stagedAudio: [NDIAudioBlock] = []
    private var audioOverflow = false
    private var audioDrainScheduled = false
    private var audioInFlight: Int64?
    private var audioStartedAt: TimeInterval?
    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    init(progressDeadline: TimeInterval = 5, event: @escaping @Sendable (Event) -> Void) {
        self.progressDeadline = progressDeadline; self.event = event
    }
    static var bundledExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/eucalyNDIHelper")
    }
    func start(generation: UUID, configuration: NDIHelperConfiguration = .init(), executable: URL = NDIHelperSupervisor.bundledExecutable) {
        queue.async { [self] in
            // A retry is legal only after the old generation has actually exited.
            guard process == nil else { event(.failed(generation, "Previous helper has not retired")); return }
            guard configuration.isValid else { event(.failed(generation, "Invalid output helper configuration")); return }
            self.generation = generation; contentEpoch = 0; stopping = false; readyState = false
            self.configuration = configuration; submissionProgressAt = nil; submittedFrames = 0
            // A content fence can arrive while asynchronous launch is pending.
            // Its admission epoch must survive startup until the queued fence runs.
            admission.lock(); admittedGeneration = generation; staged = nil; stagedAudio.removeAll(); audioOverflow = false; admission.unlock()
            audioInFlight = nil; audioStartedAt = nil
            latestRevision = 0; pending = nil; inFlight = nil; workStartedAt = nil
            startedAt = Self.now
            do {
                try Self.verifyHelper(executable)
                control = try NDIMachMailbox(label: "com.suku.eucaly.ndi.control") { [weak self] message in
                    guard let self else { return }
                    self.queue.sync { self.receiveControl(message) }
                }
                frames = try NDIMachMailbox(label: "com.suku.eucaly.ndi.frames") { [weak self] message in
                    guard let self else { return }
                    self.queue.sync { self.receiveFrame(message) }
                }
                let process = Process(), input = Pipe()
                process.executableURL = executable; process.standardInput = input
                process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
                process.terminationHandler = { [self] ended in
                    queue.async { [self] in
                        guard self.process === ended, self.generation == generation else { return }
                        let unexpected = !stopping
                        cleanUp()
                        if unexpected { event(.failed(generation, "Output helper exited")) }
                        event(.exited(generation))
                    }
                }
                self.process = process
                // Process.run inherits a private Mach send capability. Restore
                // this task's registered ports immediately, including on error.
                let slot = eucaly_mach_inherit_begin(control!.port)
                guard slot >= 0 else { throw NDIHelperWire.Failure.unavailable }
                let data: Data
                var restoredPorts = false
                do {
                    defer { restoredPorts = eucaly_mach_inherit_end() == KERN_SUCCESS }
                    data = try NDIHelperWire.encode(NDIHelperBootstrap(portIndex: slot, generation: generation,
                        version: NDIHelperWire.version, build: NDIHelperWire.build, parentPID: getpid(), configuration: configuration))
                    guard data.count <= 4096 else { throw NDIHelperWire.Failure.invalidMessage }
                    try process.run()
                }
                guard restoredPorts else { throw NDIHelperWire.Failure.unavailable }
                // Bootstrap fits in one pipe buffer and is written off the UI
                // thread. There is no discoverable service name or surface ID.
                try input.fileHandleForWriting.write(contentsOf: data)
                try input.fileHandleForWriting.close()
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
                timer.setEventHandler { [weak self] in self?.checkProgress() }
                self.timer = timer; timer.resume()
            } catch {
                if process?.isRunning == true { fail("Could not start output helper") }
                else {
                    cleanUp()
                    event(.failed(generation, "Bundled output helper startup failed: \(String(describing: error).prefix(240))"))
                    event(.exited(generation))
                }
            }
        }
    }
    private func accepts(_ message: NDIMachMessage) -> Bool {
        !stopping && message.packet.generation == generation && process?.isRunning == true
            && message.senderPID == process?.processIdentifier
    }
    private func receiveControl(_ message: NDIMachMessage) {
        if stopping {
            // Cleanup completes on the helper's SDK worker. Acknowledge its
            // report before it exits, so process-exit delivery cannot overtake
            // this evidence. The existing exact-child deadline still applies.
            let packet = message.packet
            guard packet.generation == generation, process?.isRunning == true,
                  message.senderPID == process?.processIdentifier,
                  packet.kind == .shutdownComplete, packet.version == NDIHelperWire.version,
                  packet.build == NDIHelperWire.build, message.first == 0, message.second == 0,
                  let report = packet.shutdown, let peer else { return }
            event(.shutdown(generation, report))
            _ = NDIMachMailbox.send(.init(kind: .shutdownAccepted, generation: generation), to: peer.first)
            return
        }
        guard accepts(message) else { return }
        let packet = message.packet
        guard packet.version == NDIHelperWire.version, packet.build == NDIHelperWire.build else {
            fail("Output helper protocol mismatch"); return
        }
        switch packet.kind {
        case .hello:
            guard peer == nil, message.first != 0, message.second == 0, let control, let frames else {
                fail("Output helper handshake failed"); return
            }
            peer = message // Retain the transferred send right through exit.
            guard NDIMachMailbox.send(.init(kind: .accepted, generation: generation), to: message.first,
                                      first: control.port, second: frames.port) else {
                fail("Output helper control queue unavailable"); return
            }
        case .ready:
            guard peer != nil, !readyState, message.first == 0, message.second == 0 else { fail("Invalid helper readiness"); return }
            readyState = true; sendContentFence()
            if let status = packet.status { event(.status(generation, status)) }
            event(.ready(generation)); sendPending()
        case .status:
            guard readyState, message.first == 0, message.second == 0, let status = packet.status,
                  status.sourceName.utf8.count <= 512, status.runtimeVersion.utf8.count <= 512,
                  status.submittedFrames >= submittedFrames, status.validMetrics else { fail("Invalid output status"); return }
            if status.submittedFrames > submittedFrames { submissionProgressAt = Self.now }
            submittedFrames = status.submittedFrames
            event(.status(generation, status))
        case .failure:
            fail("Output helper failed: \((packet.detail ?? "unknown error").prefix(240))")
        case .audioAccepted:
            guard message.first == 0, message.second == 0, let sample = audioInFlight, packet.revision == UInt64(sample) else {
                fail("Invalid audio acknowledgement"); return
            }
            audioInFlight = nil; audioStartedAt = nil; sendNextAudio()
        case .pong:
            #if DEBUG
            if let token = packet.token { replies.removeValue(forKey: token)?() }
            #endif
        default:
            fail("Unexpected output helper control message")
        }
    }
    func render(_ request: NDITextRenderRequest) { offer(.text(request)) }
    func renderMedia(_ submission: NDIMediaSubmission) { offer(.media(submission)) }
    func selectContent(epoch: UInt64) {
        // Queue the fence before new owner render/audio submissions. In-flight
        // leases remain retained until acknowledged, even when superseded.
        admission.lock()
        guard epoch > admittedContentEpoch else { admission.unlock(); return }
        admittedContentEpoch = epoch; staged = nil; stagedAudio.removeAll(); audioOverflow = false; admission.unlock()
        queue.async { [self] in
            guard epoch > contentEpoch else { return }
            contentEpoch = epoch; pending = nil
            // Admission may already belong to a still newer queued owner.
            // Advancing helper control must never move that boundary backwards.
            sendContentFence()
        }
    }
    private func sendContentFence() {
        guard readyState, let peer else { return }
        if !NDIMachMailbox.send(.init(kind: .route, generation: generation, contentEpoch: contentEpoch), to: peer.first) {
            fail("NDI ownership handoff failed")
        }
    }
    func sendAudio(_ block: NDIAudioBlock, generation: UUID, contentEpoch: UInt64 = 0) {
        guard block.isValid else { return }
        admission.lock()
        guard admittedGeneration == generation, admittedContentEpoch == contentEpoch else { admission.unlock(); return }
        if stagedAudio.count < 8 { stagedAudio.append(block) } else { audioOverflow = true }
        guard !audioDrainScheduled else { admission.unlock(); return }
        audioDrainScheduled = true; admission.unlock()
        queue.async { [self] in
            admission.lock(); audioDrainScheduled = false; admission.unlock()
            sendNextAudio()
        }
    }
    private func sendNextAudio() {
        guard readyState, !stopping, configuration.purpose == .sender, let peer else { return }
        admission.lock()
        if audioOverflow { admission.unlock(); fail("NDI audio queue overran. Choose Retry to restart this source."); return }
        guard audioInFlight == nil, !stagedAudio.isEmpty else { admission.unlock(); return }
        let block = stagedAudio.removeFirst(); admission.unlock()
        audioInFlight = block.sampleTime; audioStartedAt = Self.now
        guard NDIMachMailbox.send(.init(kind: .audio, generation: generation, contentEpoch: contentEpoch, audio: block), to: peer.first) else {
            fail("NDI audio handoff failed. Choose Retry to restart this source."); return
        }
    }
    private func offer(_ request: RenderJob) {
        guard request.isValid else { return }
        admission.lock()
        guard request.generation == admittedGeneration, request.contentEpoch == admittedContentEpoch,
              staged.map({ request.revision >= $0.revision }) ?? true else { admission.unlock(); return }
        staged = request
        guard !drainScheduled else { admission.unlock(); return }
        drainScheduled = true; admission.unlock()
        queue.async { [self] in
            admission.lock(); let value = staged; staged = nil; drainScheduled = false; admission.unlock()
            guard let request = value else { return }
            guard request.generation == generation, request.contentEpoch == contentEpoch, !stopping, process != nil,
                  request.revision >= latestRevision, request.isValid else { return }
            latestRevision = request.revision; pending = request
            sendPending()
        }
    }
    private func sendPending() {
        guard readyState, !stopping, inFlight == nil, let request = pending, let peer else { return }
        pending = nil
        inFlight = request; workStartedAt = Self.now
        let packet: NDIHelperPacket
        var first: mach_port_t = 0, second: mach_port_t = 0
        defer { eucaly_mach_send_release(first); eucaly_mach_send_release(second) }
        switch request {
        case .text(let text): packet = .init(kind: .render, generation: generation, revision: text.revision, request: text)
        case .media(let media):
            packet = .init(kind: .media, generation: generation, revision: media.request.revision, media: media.request)
            if let input = media.foreground { first = IOSurfaceCreateMachPort(input.surface) }
            if let input = media.background { second = IOSurfaceCreateMachPort(input.surface) }
            guard (first != 0) == (media.foreground != nil), (second != 0) == (media.background != nil) else {
                fail("Media surface transfer failed"); return
            }
        }
        guard NDIMachMailbox.send(packet, to: peer.first, first: first, second: second) else {
            fail("Output helper render queue unavailable"); return
        }
    }
    private func receiveFrame(_ message: NDIMachMessage) {
        guard accepts(message) else { return }
        let packet = message.packet
        guard readyState, packet.version == NDIHelperWire.version, packet.build == NDIHelperWire.build,
              packet.revision == inFlight?.revision, message.second == 0 else {
            fail("Output helper returned an invalid frame"); return
        }
        if configuration.purpose == .sender {
            guard packet.kind == .rendered, message.first == 0 else { fail("Invalid render acknowledgement"); return }
            if submissionProgressAt == nil { submissionProgressAt = Self.now }
            if packet.revision == latestRevision { event(.rendered(generation, packet.revision)) }
        } else if configuration.purpose == .audioProbe {
            guard packet.kind == .audioFrame, message.first == 0, let observation = packet.observation, observation.isValid else {
                fail("Invalid audio probe result"); return
            }
            event(.audio(generation, observation))
        } else {
            guard packet.kind == .frame, message.first != 0, let surface = IOSurfaceLookupFromMachPort(message.first),
                  NDIHelperWire.valid(surface) else { fail("Output helper returned an invalid frame"); return }
            if packet.revision == latestRevision { event(.frame(generation, packet.revision, surface)) }
        }
        inFlight = nil; workStartedAt = nil
        // Superseded frames never become accepted program state.
        sendPending()
    }
    private func checkProgress() {
        guard !stopping else { return }
        if !readyState && Self.now - startedAt > progressDeadline { fail("Output helper startup timed out") }
        if let due = workStartedAt, Self.now - due > progressDeadline { fail("Output helper made no rendering/submission progress") }
        if let due = submissionProgressAt, Self.now - due > progressDeadline { fail("NDI helper made no submission progress") }
        if let due = audioStartedAt, Self.now - due > progressDeadline { fail("NDI helper made no audio submission progress") }
        // No work due (including a source with no receivers) is not a stall.
    }
    private func fail(_ reason: String) { event(.failed(generation, reason)); retire() }
    func stop() { queue.async { [self] in retire() } }
    /// Used by app termination. Suspension never waits for SDK work on the UI
    /// thread, and completion means the exact owned child has actually exited.
    func stopAndWait() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard process != nil else { continuation.resume(); return }
                exitWaiters.append(continuation)
                retire()
            }
        }
    }
    private func retire() {
        guard !stopping, let owned = process else { return }
        stopping = true; pending = nil; workStartedAt = nil; submissionProgressAt = nil; timer?.cancel(); timer = nil
        admission.lock(); admittedGeneration = nil; staged = nil; stagedAudio.removeAll(); admission.unlock()
        audioInFlight = nil; audioStartedAt = nil
        let requestedStop = peer.map { NDIMachMailbox.send(.init(kind: .stop, generation: generation), to: $0.first) } ?? false
        // Let the helper flush an empty/key picture and destroy its sender.
        // SIGTERM here would preempt that cleanup and leave cached program on receivers.
        if !requestedStop, owned.isRunning { owned.terminate() }
        let generation = self.generation
        queue.asyncAfter(deadline: .now() + .milliseconds(500)) { [self] in
            guard self.generation == generation, process === owned, owned.isRunning else { return }
            // Never discover or terminate helpers by name. Process is retained
            // until its termination handler confirms this child's exit.
            kill(owned.processIdentifier, SIGKILL)
        }
    }
    private func cleanUp() {
        stopping = true; timer?.cancel(); timer = nil
        control?.close(); control = nil; frames?.close(); frames = nil; peer = nil
        process = nil; pending = nil; inFlight = nil; workStartedAt = nil; submissionProgressAt = nil
        #if DEBUG
        replies.removeAll()
        #endif
        admission.lock(); admittedGeneration = nil; admittedContentEpoch = 0; staged = nil; stagedAudio.removeAll(); admission.unlock()
        audioInFlight = nil; audioStartedAt = nil
        let waiters = exitWaiters; exitWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
    #if DEBUG
    func injectFault(_ fault: String, completion: @escaping @Sendable () -> Void) {
        debugRequest(.fault, detail: fault, completion: completion)
    }
    func ping(_ completion: @escaping @Sendable () -> Void) { debugRequest(.ping, completion: completion) }
    private func debugRequest(_ kind: NDIHelperPacket.Kind, detail: String? = nil, completion: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard readyState, !stopping, let peer, replies.count < 8 else { return }
            let token = UUID(); replies[token] = completion
            if !NDIMachMailbox.send(.init(kind: kind, generation: generation, detail: detail, token: token), to: peer.first) {
                replies.removeValue(forKey: token); fail("Output helper control queue unavailable")
            }
        }
    }
    #endif
    private static func verifyHelper(_ url: URL) throws {
        guard url.standardizedFileURL == bundledExecutable.standardizedFileURL else { throw NDIHelperWire.Failure.unavailable }
        var helper: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &helper) == errSecSuccess, let helper else { throw NDIHelperWire.Failure.unavailable }
        var ownCode: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        SecCodeCopySelf([], &ownCode)
        if let ownCode { SecCodeCopyStaticCode(ownCode, [], &staticCode) }
        if let staticCode { SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) }
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        #if DEBUG
        if team == nil { return } // make test builds both targets unsigned.
        #endif
        guard let team, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { throw NDIHelperWire.Failure.unavailable }
        var requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"com.suku.eucaly.ndi-helper\" and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(helper, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else { throw NDIHelperWire.Failure.unavailable }
    }
}
