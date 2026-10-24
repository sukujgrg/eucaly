#if DEBUG
import Foundation
import IOSurface
import Darwin

/// A finite process-local experiment, using the real submission worker and
/// IOSurface leases but no vendor SDK, player, socket, AppKit window or IPC.
enum NetworkSubmissionPacingFixture {
    struct GateEvidence: Codable {
        let stage: String
        let callIndex: UInt64
        let arrivedNanoseconds: UInt64
        let measuredPhaseAnchorNanoseconds: UInt64
        let measuredPreGatePeriodNanoseconds: UInt64
        let targetReleaseNanoseconds: UInt64
        let releasedNanoseconds: UInt64
        let resumedNanoseconds: UInt64
        let timedOut: Bool
    }
    struct Recovery: Codable {
        let stage: String
        let firstCallIndex: UInt64
        let secondCallIndex: UInt64
        let entrySpacingNanoseconds: UInt64
    }
    struct Result: Codable {
        let consumption: String
        let traceFile: String
        let measurementValid: Bool
        let measurementFailures: [String]
        let contractFailures: [String]
        let liveCallCount: UInt64
        let minimumLiveEntrySpacingNanoseconds: UInt64?
        let recovery: [Recovery]
        let gates: [GateEvidence]
        let maximumStatusCallNanoseconds: UInt64
        let stopMethodNanoseconds: UInt64
        let audioSamples: [Int64]
        let observedEpochs: [UInt64]
        let releasedLeaseMarkers: [UInt32]
    }
    struct Report: Codable {
        let schemaVersion: Int
        let boundary: String
        let periodNanoseconds: UInt64
        let scheduling: String
        let results: [Result]
    }
    enum Failure: Error { case timeout(String), invalid(String) }

    static func run(directory: URL) throws {
        guard directory.path.hasPrefix("/") else { throw Failure.invalid("An absolute evidence directory is required") }
        // main's diagnostic branch intentionally precedes AppKit/bootstrap.
        // Match the live service's public application task category and scoped
        // latency activity before creating its worker or release-timer threads.
        // This requests neither foreground nor real-time priority.
        var category = task_category_policy_data_t(role: TASK_DEFAULT_APPLICATION)
        let count = MemoryLayout<task_category_policy_data_t>.size / MemoryLayout<integer_t>.size
        let configured = withUnsafeMutablePointer(to: &category) { policy in
            policy.withMemoryRebound(to: integer_t.self, capacity: count) {
                task_policy_set(mach_task_self_, UInt32(TASK_CATEGORY_POLICY), $0, UInt32(count))
            }
        }
        guard configured == KERN_SUCCESS else { throw Failure.invalid("Could not match live helper task category: \(configured)") }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Controlled no-SDK submission pacing measurement")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var results: [Result] = []
        for consumption in [NetworkVideoConsumption.synchronous, .borrowedUntilNextSendOrFlush] {
            results.append(try run(consumption: consumption, directory: directory))
        }
        let report = Report(schemaVersion: 1,
            boundary: "Actual worker with a recording adapter; no SDK, network, player or window. Gates and wrapper timings are source-only evidence.",
            periodNanoseconds: NetworkVideoTrace.periodNanoseconds,
            scheduling: "TASK_DEFAULT_APPLICATION; scoped userInitiatedAllowingIdleSystemSleep + latencyCritical; strict diagnostic release timers; actual production worker scheduling",
            results: results)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(report).write(to: directory.appendingPathComponent("report.json"), options: .atomic)
    }

    private static func run(consumption: NetworkVideoConsumption, directory: URL) throws -> Result {
        let generation = UUID()
        let trace = NetworkVideoTrace(directory: directory, generation: generation, technology: "recording-fixture")
        let adapter = RecordingAdapter(consumption: consumption)
        let worker = NetworkSubmissionWorker(recording: adapter, trace: trace)
        let released = ReleasedLeases()
        var initial: GPUFrameLease? = try lease(marker: 0xABCDEF01, released: released)
        adapter.track(initial!, marker: 0xABCDEF01)
        worker.offer(initial!, epoch: 0); initial = nil
        let started = DispatchSemaphore(value: 0)
        let startup = StartupResult()
        worker.start(name: "No-SDK pacing fixture", technology: .omt, generation: generation) { status, error in
            startup.set(status: status, error: error); started.signal()
        }
        try wait(started, "worker start")
        if let error = startup.error { throw Failure.invalid(error) }
        guard startup.ready else { throw Failure.invalid("Worker did not start") }
        var contracts: [String] = []
        var maximumStatus: UInt64 = 0
        func responsiveStatus() {
            let entered = DispatchTime.now().uptimeNanoseconds
            _ = worker.status()
            maximumStatus = max(maximumStatus, DispatchTime.now().uptimeNanoseconds - entered)
        }
        defer { adapter.releaseAllGates() }

        try wait(adapter.sendGate.entered, "send gate entered")
        responsiveStatus()
        let fenced = DispatchSemaphore(value: 0)
        worker.selectContent(epoch: 1) { fenced.signal() }
        try wait(fenced, "audio/content fence bypasses held video")
        var replacement: GPUFrameLease? = try lease(marker: 0xABCDEF02, released: released)
        adapter.track(replacement!, marker: 0xABCDEF02)
        worker.offer(replacement!, epoch: 1); replacement = nil
        var late: GPUFrameLease? = try lease(marker: 0xABCDEF03, released: released)
        worker.offer(late!, epoch: 0); late = nil
        if !released.markers.contains(0xABCDEF03) { contracts.append("Old-owner offer was retained") }
        let sample = Int64(ProcessInfo.processInfo.systemUptime * 48000) / 960 * 960
        let pcm = [Float](repeating: 0.01, count: 1920).withUnsafeBufferPointer { Data(buffer: $0) }
        if case .superseded = worker.sendAudio(.init(sampleTime: sample, pcm: pcm), epoch: 0) {} else {
            contracts.append("Old-owner audio was admitted")
        }
        if case .submitted = worker.sendAudio(.init(sampleTime: sample, pcm: pcm), epoch: 1) {} else {
            contracts.append("New-owner audio waited behind video")
        }
        if case .submitted = worker.sendAudio(.init(sampleTime: sample + 960, pcm: pcm), epoch: 1) {} else {
            contracts.append("Continuous new-owner audio was rejected")
        }
        try release(adapter.sendGate, measuredBefore: 4, adapter: adapter)

        try wait(adapter.observationGate.entered, "post-call observation gate entered")
        responsiveStatus()
        if case .submitted = worker.sendAudio(.init(sampleTime: sample + 1920, pcm: pcm), epoch: 1) {} else {
            contracts.append("Audio waited behind video observation")
        }
        try release(adapter.observationGate, measuredBefore: 10, adapter: adapter)

        try wait(adapter.stopGate.entered, "stop gate entered")
        responsiveStatus()
        let stopped = DispatchSemaphore(value: 0)
        let stopEntered = DispatchTime.now().uptimeNanoseconds
        worker.stop(colour: .chromaGreen) { _ in stopped.signal() }
        let stopDuration = DispatchTime.now().uptimeNanoseconds - stopEntered
        adapter.stopGate.releaseNow()
        try wait(stopped, "worker cleanup and trace export")
        if maximumStatus > 50_000_000 { contracts.append("Status blocked for more than 50 ms") }
        if stopDuration > 50_000_000 { contracts.append("Stop admission blocked for more than 50 ms") }
        contracts += adapter.failures
        if !adapter.closed || !adapter.flushed { contracts.append("Sender did not flush and close") }
        if !released.markers.contains(0xABCDEF01) || !released.markers.contains(0xABCDEF02) {
            contracts.append("Accepted frame leases survived cleanup")
        }
        let snapshot = try JSONDecoder().decode(NetworkVideoTrace.Snapshot.self, from: Data(contentsOf: trace.fileURL))
        let live = snapshot.records.filter { $0.kind == "live" }
        var measurement = snapshot.invalidReasons
        if !snapshot.valid { measurement.append("Common trace is invalid") }
        if snapshot.liveCallCount != adapter.observations.count { measurement.append("Adapter/common trace call count differs") }
        if snapshot.liveCallCount < 16 { measurement.append("Did not recover through both controlled stalls") }
        if snapshot.records.filter({ $0.kind == "terminal" }).count != 1 { measurement.append("Missing labeled terminal send") }
        let gates = [adapter.sendGate.evidence, adapter.observationGate.evidence, adapter.stopGate.evidence]
        let period = NetworkVideoTrace.periodNanoseconds
        for gate in gates.prefix(2) {
            let anchor = gate.measuredPhaseAnchorNanoseconds
            let phase = gate.releasedNanoseconds >= anchor ? (gate.releasedNanoseconds - anchor) % period : 0
            let measured = gate.measuredPreGatePeriodNanoseconds
            let periodError = measured > period ? measured - period : period - measured
            let releaseError = gate.releasedNanoseconds >= gate.targetReleaseNanoseconds
                ? gate.releasedNanoseconds - gate.targetReleaseNanoseconds : UInt64.max
            if gate.timedOut || gate.releasedNanoseconds <= gate.arrivedNanoseconds + period
                || anchor == 0 || periodError > 1_000_000 || releaseError > 1_000_000
                || phase < period * 2 / 3 || phase > period * 31 / 32
                || gate.resumedNanoseconds < gate.releasedNanoseconds
                || gate.resumedNanoseconds - gate.releasedNanoseconds > period / 4 {
                measurement.append("Controlled release missed its measured timer phase: \(gate.stage)")
            }
        }
        var recovery: [Recovery] = []
        for gate in gates.prefix(2) {
            let after = live.filter { ($0.callIndex ?? 0) > gate.callIndex }
            guard after.count >= 2, let firstIndex = after[0].callIndex, let secondIndex = after[1].callIndex,
                  let first = after[0].sdkEnteredNanoseconds, let second = after[1].sdkEnteredNanoseconds, second > first else {
                measurement.append("Missing post-gate entries: \(gate.stage)"); continue
            }
            recovery.append(.init(stage: gate.stage, firstCallIndex: firstIndex, secondCallIndex: secondIndex,
                                  entrySpacingNanoseconds: second - first))
        }
        let entries = live.compactMap(\.sdkEnteredNanoseconds)
        let spacings = zip(entries, entries.dropFirst()).compactMap { prior, next in next >= prior ? next - prior : nil }
        let epochs = adapter.observations.map(\.contentEpoch)
        if epochs.contains(where: { $0 != 0 && $0 != 1 }) || epochs.dropFirst(4).contains(0) {
            contracts.append("Old epoch returned after the acknowledged owner change")
        }
        if adapter.audioSamples != [sample, sample + 960, sample + 1920] { contracts.append("Audio samples were lost or duplicated") }
        return .init(consumption: consumption.rawValue, traceFile: trace.fileURL.lastPathComponent,
            measurementValid: measurement.isEmpty, measurementFailures: Array(Set(measurement)).sorted(),
            contractFailures: Array(Set(contracts)).sorted(), liveCallCount: snapshot.liveCallCount,
            minimumLiveEntrySpacingNanoseconds: spacings.min(), recovery: recovery, gates: gates,
            maximumStatusCallNanoseconds: maximumStatus, stopMethodNanoseconds: stopDuration,
            audioSamples: adapter.audioSamples, observedEpochs: epochs, releasedLeaseMarkers: released.markers.sorted())
    }

    private static func lease(marker: UInt32, released: ReleasedLeases) throws -> GPUFrameLease {
        let surface = try SurfacePool.makeSurface()
        surface.baseAddress.storeBytes(of: marker, as: UInt32.self)
        return GPUFrameLease(surface, poolOccupancy: 3) { released.record(marker) }
    }
    private static func wait(_ semaphore: DispatchSemaphore, _ name: String) throws {
        guard semaphore.wait(timeout: .now() + .seconds(3)) == .success else { throw Failure.timeout(name) }
    }
    private static func release(_ gate: Gate, measuredBefore callIndex: UInt64, adapter: RecordingAdapter) throws {
        // Initial timer activation and its first delivered event need not have
        // the same phase as subsequent delivery. Derive this experiment's
        // release from actual pre-gate entries, without changing that timer.
        let prior = adapter.observations.filter { $0.callIndex < callIndex }.suffix(2)
        guard prior.count == 2, let first = prior.first, let last = prior.last,
              last.startedNanoseconds > first.startedNanoseconds else {
            throw Failure.invalid("Missing measured pre-gate phase")
        }
        gate.releaseOnTimerPhase(anchor: last.startedNanoseconds,
            measuredPeriod: last.startedNanoseconds - first.startedNanoseconds)
    }

    private final class StartupResult: @unchecked Sendable {
        private let lock = NSLock()
        private var status: NetworkHelperStatus?
        private var failure: String?
        func set(status: NetworkHelperStatus?, error: String?) { lock.withLock { self.status = status; failure = error } }
        var error: String? { lock.withLock { failure } }
        var ready: Bool { lock.withLock { status != nil } }
    }
    private final class ReleasedLeases: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [UInt32] = []
        func record(_ value: UInt32) { lock.withLock { values.append(value) } }
        var markers: [UInt32] { lock.withLock { values } }
    }
    private final class WeakLease { weak var value: GPUFrameLease?; init(_ value: GPUFrameLease) { self.value = value } }

    private final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        private let resume = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private let stage: String
        private let callIndex: UInt64
        private let releaseQueue = DispatchQueue(label: "com.suku.eucaly.fixture.phase-release", qos: .userInitiated)
        private var arrived: UInt64 = 0, target: UInt64 = 0, released: UInt64 = 0, resumed: UInt64 = 0
        private var measuredAnchor: UInt64 = 0, measuredPeriod: UInt64 = 0
        private var timedOut = false
        private var timer: DispatchSourceTimer?
        init(_ stage: String, callIndex: UInt64) { self.stage = stage; self.callIndex = callIndex }
        func hold() {
            lock.withLock { arrived = DispatchTime.now().uptimeNanoseconds }
            entered.signal()
            let result = resume.wait(timeout: .now() + .seconds(2))
            lock.withLock { resumed = DispatchTime.now().uptimeNanoseconds; timedOut = result != .success }
        }
        func releaseOnTimerPhase(anchor: UInt64, measuredPeriod: UInt64) {
            let period = NetworkVideoTrace.periodNanoseconds
            let now = DispatchTime.now().uptimeNanoseconds
            // End after multiple missed opportunities, near (but before) the
            // observed timer's next deadline. The measured phase is validated;
            // late system delivery invalidates the experiment, never passes it.
            let cycle = now > anchor ? (now - anchor) / period : 0
            let deadline = anchor + (cycle + 3) * period - period / 8
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: releaseQueue)
            lock.withLock {
                target = deadline; self.timer = timer
                measuredAnchor = anchor; self.measuredPeriod = measuredPeriod
            }
            timer.setEventHandler { [weak self] in self?.releaseNow() }
            timer.schedule(deadline: DispatchTime(uptimeNanoseconds: deadline), leeway: .nanoseconds(0))
            timer.resume()
        }
        func releaseNow() {
            let source: DispatchSourceTimer? = lock.withLock {
                guard released == 0 else { return nil }
                released = DispatchTime.now().uptimeNanoseconds
                let source = timer; timer = nil
                return source
            }
            source?.cancel(); resume.signal()
        }
        var evidence: GateEvidence { lock.withLock {
            .init(stage: stage, callIndex: callIndex, arrivedNanoseconds: arrived,
                  measuredPhaseAnchorNanoseconds: measuredAnchor, measuredPreGatePeriodNanoseconds: measuredPeriod,
                  targetReleaseNanoseconds: target,
                  releasedNanoseconds: released, resumedNanoseconds: resumed, timedOut: timedOut)
        } }
    }

    private final class RecordingAdapter: NetworkRuntimeAdapter, @unchecked Sendable {
        let videoConsumption: NetworkVideoConsumption
        let sendGate = Gate("send", callIndex: 4)
        let observationGate = Gate("observation", callIndex: 10)
        let stopGate = Gate("stop", callIndex: 16)
        private let lock = NSLock()
        private var count: UInt64 = 0
        private var contexts: [NetworkVideoSubmissionContext] = []
        private var audio: [Int64] = []
        private var errors: [String] = []
        private var leases: [UInt32: WeakLease] = [:]
        private var previousPointer: UnsafeMutableRawPointer?
        private var previousMarker: UInt32?
        private var didFlush = false, didClose = false
        init(consumption: NetworkVideoConsumption) { videoConsumption = consumption }
        var version: String { "recording-adapter-no-sdk" }
        var sourceName: String? { "No-SDK pacing fixture" }
        func createSender(name: String) -> Bool { true }
        func track(_ lease: GPUFrameLease, marker: UInt32) { lock.withLock { leases[marker] = WeakLease(lease) } }
        func sendVideo(_ bytes: UnsafeMutableRawPointer, format: NetworkVideoPixelFormat, timecode: Int64) -> Int32? {
            let index = lock.withLock { count += 1; return count }
            verifyPreviousBorrow()
            if index == 4 { sendGate.hold() }
            if index == 16 { stopGate.hold() }
            verifyPreviousBorrow() // The prior borrow must survive the whole call.
            let marker = bytes.load(as: UInt32.self)
            lock.withLock {
                if marker == 0xABCDEF03 { errors.append("A stale-owner frame reached the adapter") }
                previousPointer = bytes; previousMarker = marker
            }
            return videoConsumption == .synchronous ? Int32(format.byteCount) : nil
        }
        private func verifyPreviousBorrow() {
            guard videoConsumption == .borrowedUntilNextSendOrFlush else { return }
            lock.withLock {
                guard let marker = previousMarker, let weak = leases[marker] else { return }
                guard weak.value != nil else { errors.append("Previous asynchronous lease ended before next send returned"); return }
                if previousPointer?.load(as: UInt32.self) != marker { errors.append("Borrowed pixels changed") }
            }
        }
        func videoSubmissionObservation(_ context: NetworkVideoSubmissionContext) -> NetworkVideoSubmissionObservation {
            lock.withLock {
                if contexts.count < 256 { contexts.append(context) } else { errors.append("Recording adapter overflow") }
            }
            if context.callIndex == 10 { observationGate.hold() }
            return .init(connections: 0)
        }
        func sendAudio(_ bytes: UnsafeRawPointer, sampleTime: Int64) -> Int32? {
            lock.withLock { if audio.count < 16 { audio.append(sampleTime) } else { errors.append("Audio observer overflow") } }
            return videoConsumption == .synchronous ? 7680 : nil
        }
        func audioSubmissionObservation() -> (any NetworkTransportStatusObservation)? { nil }
        func flush() {
            // The terminal stack buffer must remain readable through flush.
            lock.withLock { if let previousPointer { _ = previousPointer.load(as: UInt32.self) }; didFlush = true }
        }
        func close() { lock.withLock { if !didFlush { errors.append("Close preceded flush") }; didClose = true } }
        func createProbe(source: String, audioOnly: Bool) -> Bool { false }
        func probeFrame(bytes: UnsafeMutableRawPointer, capacity: Int) -> NetworkProbeResult<Int64> { .invalid }
        func probeAudio() -> NetworkProbeResult<NetworkAudioObservation> { .invalid }
        func releaseAllGates() { sendGate.releaseNow(); observationGate.releaseNow(); stopGate.releaseNow() }
        var failures: [String] { lock.withLock { errors } }
        var observations: [NetworkVideoSubmissionContext] { lock.withLock { contexts } }
        var audioSamples: [Int64] { lock.withLock { audio } }
        var closed: Bool { lock.withLock { didClose } }
        var flushed: Bool { lock.withLock { didFlush } }
    }
}
#endif
