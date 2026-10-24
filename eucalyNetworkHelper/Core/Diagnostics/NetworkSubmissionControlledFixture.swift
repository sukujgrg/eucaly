#if DEBUG
import Foundation

/// A recording-only deadline driver. It delivers callbacks on the worker's real
/// owner queue, but advances logical scheduling time without waiting on the OS.
/// It does not implement a pacing policy or supply transport timestamps.
final class NetworkSubmissionControlledScheduler: @unchecked Sendable {
    struct Event: Codable {
        let kind: String
        let logicalNanoseconds: UInt64
        let deadlineNanoseconds: UInt64?
    }
    final class Delivery: @unchecked Sendable {
        private let completed = DispatchSemaphore(value: 0)
        func finish() { completed.signal() }
        func wait() throws {
            guard completed.wait(timeout: .now() + .seconds(2)) == .success else {
                throw NetworkSubmissionControlledFixture.Failure.timeout("worker callback")
            }
        }
    }
    private let lock = NSLock()
    private var logicalNanoseconds: UInt64 = 1_000_000_000
    private var deadline: UInt64?
    private var active = false
    private var callback: (@Sendable (@escaping @Sendable () -> Void) -> Void)?
    private var events: [Event] = []
    private var overflow = 0

    var now: UInt64 { lock.withLock { logicalNanoseconds } }
    var nextDeadline: UInt64? { lock.withLock { deadline } }
    var isActive: Bool { lock.withLock { active } }
    var history: [Event] { lock.withLock { events } }
    var overflowCount: Int { lock.withLock { overflow } }

    func install(_ callback: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void) {
        lock.withLock { self.callback = callback; active = true }
    }
    func schedule(at deadline: UInt64) {
        lock.withLock {
            guard active else { return }
            self.deadline = deadline
            record("schedule", deadline: deadline)
        }
    }
    func cancel() { lock.withLock { active = false; deadline = nil; record("cancel") } }
    func advance(to value: UInt64) throws {
        try lock.withLock {
            guard value >= logicalNanoseconds else { throw NetworkSubmissionControlledFixture.Failure.invalid("Logical clock regressed") }
            logicalNanoseconds = value; record("advance")
        }
    }
    func deliver(at value: UInt64, staleAfterStop: Bool = false) throws -> Delivery {
        let callback = try lock.withLock {
            guard value >= logicalNanoseconds, active || staleAfterStop, let callback else {
                throw NetworkSubmissionControlledFixture.Failure.invalid("Invalid controlled callback")
            }
            logicalNanoseconds = value
            record(staleAfterStop ? "stale-callback" : "callback", deadline: deadline)
            deadline = nil
            return callback
        }
        let delivery = Delivery()
        callback { delivery.finish() }
        return delivery
    }
    func deliverNext(lateness: UInt64 = 0) throws -> Delivery {
        guard let deadline = nextDeadline else { throw NetworkSubmissionControlledFixture.Failure.invalid("Worker did not rearm") }
        return try deliver(at: max(now, deadline) + lateness)
    }
    private func record(_ kind: String, deadline: UInt64? = nil) {
        if events.count < 2_048 { events.append(.init(kind: kind, logicalNanoseconds: logicalNanoseconds, deadlineNanoseconds: deadline)) }
        else { overflow += 1 }
    }
}

/// Deterministic CI exercises the actual worker, including SDK-owner stalls,
/// fences, bounded latest-frame admission, borrowed leases, audio and Stop.
/// Logical cadence is not OS scheduling, SDK throughput or physical evidence.
enum NetworkSubmissionControlledFixture {
    enum Failure: Error { case timeout(String), invalid(String) }
    static let period: UInt64 = 1_000_000_000 / 30
    static let lateness: UInt64 = 500_000
    struct Entry: Codable {
        let callIndex: UInt64
        let contentEpoch: UInt64
        let marker: UInt32
        let logicalEntryNanoseconds: UInt64
        let logicalReturnNanoseconds: UInt64
        let transportTimecode100ns: Int64
        let actualSDKEntryUptimeNanoseconds: UInt64
        let actualSDKReturnUptimeNanoseconds: UInt64
    }
    struct Result: Codable {
        let scenario: String
        let consumption: String
        let entries: [Entry]
        let logicalFramesPerSecond: Double
        let minimumLogicalEntrySpacingNanoseconds: UInt64
        let earlyCallbacksRejected: Int
        let idleCallbacksRejected: Int
        let idleDeadlineIsFuture: Bool
        let stoppedCallbackRejected: Bool
        let terminalCallCount: Int
        let audioSamples: [Int64]
        let releasedLeaseMarkers: [UInt32]
        let schedulerEvents: [NetworkSubmissionControlledScheduler.Event]
        let overflowCount: Int
        let contractFailures: [String]
    }
    struct Report: Codable {
        let schemaVersion: Int
        let boundary: String
        let periodNanoseconds: UInt64
        let injectedLogicalWakeLatenessNanoseconds: UInt64
        let results: [Result]
    }

    static func run(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var results: [Result] = []
        for mode in [NetworkVideoConsumption.synchronous, .borrowedUntilNextSendOrFlush] {
            results.append(try run(consumption: mode, cadence: true))
            results.append(try run(consumption: mode, cadence: false))
        }
        let report = Report(schemaVersion: 1,
            boundary: "Controlled logical scheduler driving the actual worker and recording adapter. Transport timecodes and SDK context uptime remain real; logical cadence is not runtime or physical performance. No SDK, network, player or window.",
            periodNanoseconds: period, injectedLogicalWakeLatenessNanoseconds: lateness, results: results)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: directory.appendingPathComponent("controlled-scheduling-report.json"), options: .atomic)
    }

    private static func run(consumption: NetworkVideoConsumption, cadence: Bool) throws -> Result {
        let scheduler = NetworkSubmissionControlledScheduler()
        let adapter = RecordingAdapter(scheduler: scheduler, consumption: consumption, gates: !cadence)
        let worker = NetworkSubmissionWorker(recording: adapter, scheduler: scheduler)
        let leases = ReleasedLeases()
        var initial: GPUFrameLease? = try lease(1, releases: leases)
        adapter.track(initial!, marker: 1); worker.offer(initial!); initial = nil
        let ready = DispatchSemaphore(value: 0), startup = StartupResult()
        worker.start(name: "Controlled recording fixture", technology: .omt) { status, error in
            startup.set(status != nil, error: error); ready.signal()
        }
        try wait(ready, "worker ready")
        guard startup.ready else { throw Failure.invalid(startup.error ?? "Worker did not start") }
        defer { adapter.releaseGates() }
        var failures: [String] = []
        var early = 0, idle = 0
        var futureIdle = true
        let sample: Int64 = 48_000
        let pcm = [Float](repeating: 0.01, count: 1920).withUnsafeBufferPointer { Data(buffer: $0) }
        func requireAudio(_ sample: Int64, epoch: UInt64, submitted: Bool) {
            switch worker.sendAudio(.init(sampleTime: sample, pcm: pcm), epoch: epoch) {
            case .submitted: if !submitted { failures.append("Stale audio admitted") }
            case .superseded: if submitted { failures.append("Current audio rejected") }
            case .discontinuity: failures.append("Continuous audio rejected")
            }
        }
        func rejectEarly() throws {
            let count = adapter.entries.count
            let delivery = try scheduler.deliver(at: scheduler.now + 1_000_000)
            try delivery.wait()
            if adapter.entries.count == count { early += 1 } else { failures.append("Early callback entered SDK") }
        }
        func reach(_ calls: Int) throws {
            for _ in 0..<64 {
                if adapter.entries.count >= calls { return }
                try scheduler.deliverNext(lateness: lateness).wait()
            }
            throw Failure.invalid("Worker did not reach \(calls) calls within the controlled callback bound")
        }
        if cadence {
            for _ in 0..<300 { try scheduler.deliverNext(lateness: lateness).wait() }
        } else {
            for _ in 0..<3 { try scheduler.deliverNext(lateness: lateness).wait() }
            let heldSend = try scheduler.deliverNext(lateness: lateness)
            try wait(adapter.sendGate.entered, "held SDK call")
            _ = worker.status() // A lock held across SDK work would block the bounded fixture.
            let fenced = DispatchSemaphore(value: 0)
            worker.selectContent(epoch: 1) { fenced.signal() }
            try wait(fenced, "ownership fence while SDK held")
            var coalesced: GPUFrameLease? = try lease(2, releases: leases)
            adapter.track(coalesced!, marker: 2); worker.offer(coalesced!, epoch: 1); coalesced = nil
            var replacement: GPUFrameLease? = try lease(4, releases: leases)
            adapter.track(replacement!, marker: 4); worker.offer(replacement!, epoch: 1); replacement = nil
            var stale: GPUFrameLease? = try lease(3, releases: leases)
            worker.offer(stale!, epoch: 0); stale = nil
            if !leases.markers.contains(2) || !leases.markers.contains(3) { failures.append("Latest-frame/stale admission retained discarded leases") }
            requireAudio(sample, epoch: 0, submitted: false)
            requireAudio(sample, epoch: 1, submitted: true)
            requireAudio(sample + 960, epoch: 1, submitted: true)
            try scheduler.advance(to: scheduler.now + 95_000_000)
            adapter.sendGate.release(); try heldSend.wait()
            try scheduler.deliverNext().wait()
            try rejectEarly()
            try reach(9)
            let heldObservation = try scheduler.deliverNext(lateness: lateness)
            try wait(adapter.observationGate.entered, "held post-call observation")
            _ = worker.status()
            requireAudio(sample + 1920, epoch: 1, submitted: true)
            try scheduler.advance(to: scheduler.now + 95_000_000)
            adapter.observationGate.release(); try heldObservation.wait()
            try scheduler.deliverNext().wait()
            try rejectEarly()
            try reach(12)

            let fencedAgain = DispatchSemaphore(value: 0)
            worker.selectContent(epoch: 2) { fencedAgain.signal() }
            try wait(fencedAgain, "idle ownership fence")
            let beforeIdle = adapter.entries.count
            try scheduler.deliverNext().wait()
            if adapter.entries.count == beforeIdle { idle += 1 }
            futureIdle = scheduler.nextDeadline.map { $0 > scheduler.now } ?? false
            // An arbitrarily long idle period must create neither SDK work nor
            // an obsolete opportunity replay when a new frame arrives.
            try scheduler.deliver(at: scheduler.now + 3_600_000_000_000).wait()
            if adapter.entries.count == beforeIdle { idle += 1 }
            futureIdle = futureIdle && (scheduler.nextDeadline.map { $0 > scheduler.now } ?? false)
            var resumed: GPUFrameLease? = try lease(5, releases: leases)
            adapter.track(resumed!, marker: 5); worker.offer(resumed!, epoch: 2); resumed = nil
            try rejectEarly()
            try reach(15)
        }
        let heldStop: NetworkSubmissionControlledScheduler.Delivery?
        if cadence { heldStop = nil }
        else { heldStop = try scheduler.deliverNext(lateness: lateness) }
        if !cadence { try wait(adapter.stopGate.entered, "held SDK call during Stop"); _ = worker.status() }
        let stopped = DispatchSemaphore(value: 0)
        worker.stop(colour: .chromaGreen) { _ in stopped.signal() }
        adapter.stopGate.release()
        try heldStop?.wait()
        try wait(stopped, "worker Stop")
        let beforeStale = adapter.entries.count, schedules = scheduler.history.filter { $0.kind == "schedule" }.count
        try scheduler.deliver(at: scheduler.now + period, staleAfterStop: true).wait()
        let stoppedRejected = adapter.entries.count == beforeStale && !scheduler.isActive && scheduler.nextDeadline == nil
            && scheduler.history.filter { $0.kind == "schedule" }.count == schedules
        requireAudio(sample + 2880, epoch: cadence ? 0 : 2, submitted: false)
        if !adapter.closed || !adapter.flushed { failures.append("Stop did not flush and close") }
        let expectedReleases: Set<UInt32> = cadence ? [1] : [1, 2, 3, 4, 5]
        if leases.markers != expectedReleases { failures.append("Accepted leases survived Stop") }
        let entries = adapter.entries
        guard entries.count >= 2, let first = entries.first, let last = entries.last,
              last.logicalEntryNanoseconds > first.logicalEntryNanoseconds else {
            throw Failure.invalid("Missing logical entry span")
        }
        if !cadence {
            if entries.dropFirst(4).prefix(8).contains(where: { $0.contentEpoch != 1 || $0.marker != 4 })
                || entries.dropFirst(12).contains(where: { $0.contentEpoch != 2 || $0.marker != 5 }) {
                failures.append("Wrong owner/latest picture after fence")
            }
        }
        let gaps = zip(entries, entries.dropFirst()).map { $1.logicalEntryNanoseconds - $0.logicalEntryNanoseconds }
        let span = last.logicalEntryNanoseconds - first.logicalEntryNanoseconds
        return .init(scenario: cadence ? "ordinary-lateness" : "stalls-fences-idle-stop", consumption: consumption.rawValue,
            entries: entries, logicalFramesPerSecond: Double(entries.count - 1) * 1_000_000_000 / Double(span),
            minimumLogicalEntrySpacingNanoseconds: gaps.min() ?? 0, earlyCallbacksRejected: early, idleCallbacksRejected: idle,
            idleDeadlineIsFuture: futureIdle, stoppedCallbackRejected: stoppedRejected,
            terminalCallCount: adapter.terminalCallCount, audioSamples: adapter.audioSamples,
            releasedLeaseMarkers: leases.markers.sorted(), schedulerEvents: scheduler.history,
            overflowCount: scheduler.overflowCount + adapter.overflowCount, contractFailures: failures + adapter.failures)
    }

    private static func lease(_ marker: UInt32, releases: ReleasedLeases) throws -> GPUFrameLease {
        let surface = try SurfacePool.makeSurface(); surface.baseAddress.storeBytes(of: marker, as: UInt32.self)
        return GPUFrameLease(surface, poolOccupancy: 3) { releases.record(marker) }
    }
    private static func wait(_ semaphore: DispatchSemaphore, _ reason: String) throws {
        guard semaphore.wait(timeout: .now() + .seconds(2)) == .success else { throw Failure.timeout(reason) }
    }
    private final class StartupResult: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false, detail: String?
        func set(_ ready: Bool, error: String?) { lock.withLock { value = ready; detail = error } }
        var ready: Bool { lock.withLock { value } }
        var error: String? { lock.withLock { detail } }
    }
    private final class ReleasedLeases: @unchecked Sendable {
        private let lock = NSLock()
        private var values: Set<UInt32> = []
        func record(_ value: UInt32) { lock.withLock { _ = values.insert(value) } }
        var markers: Set<UInt32> { lock.withLock { values } }
    }
    private final class WeakLease { weak var value: GPUFrameLease?; init(_ value: GPUFrameLease) { self.value = value } }
    private final class Gate: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        private let released = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var expired = false
        func hold() {
            entered.signal()
            if released.wait(timeout: .now() + .seconds(2)) != .success { lock.withLock { expired = true } }
        }
        func release() { released.signal() }
        var timedOut: Bool { lock.withLock { expired } }
    }
    private final class RecordingAdapter: NetworkRuntimeAdapter, @unchecked Sendable {
        let sendGate = Gate(), observationGate = Gate(), stopGate = Gate()
        let videoConsumption: NetworkVideoConsumption
        private let scheduler: NetworkSubmissionControlledScheduler
        private let gates: Bool
        private let lock = NSLock()
        private var calls: UInt64 = 0
        private var recorded: [Entry] = [], audio: [Int64] = [], errors: [String] = []
        private var leases: [UInt32: WeakLease] = [:]
        private var previousPointer: UnsafeMutableRawPointer?, previousMarker: UInt32?
        private var logicalEntry: UInt64 = 0, logicalReturn: UInt64 = 0
        private var didClose = false, didFlush = false
        private var overflow = 0
        init(scheduler: NetworkSubmissionControlledScheduler, consumption: NetworkVideoConsumption, gates: Bool) {
            self.scheduler = scheduler; videoConsumption = consumption; self.gates = gates
        }
        var version: String { "controlled-recording-no-sdk" }
        var sourceName: String? { "Controlled recording fixture" }
        func createSender(name: String) -> Bool { true }
        func track(_ lease: GPUFrameLease, marker: UInt32) { lock.withLock { leases[marker] = WeakLease(lease) } }
        func sendVideo(_ bytes: UnsafeMutableRawPointer, format: NetworkVideoPixelFormat, timecode: Int64) -> Int32? {
            let index = lock.withLock { calls += 1; logicalEntry = scheduler.now; return calls }
            verifyBorrow()
            if gates, index == 4 { sendGate.hold() }
            if gates, index == 16 { stopGate.hold() }
            verifyBorrow()
            lock.withLock { previousPointer = bytes; previousMarker = bytes.load(as: UInt32.self); logicalReturn = scheduler.now }
            return videoConsumption == .synchronous ? Int32(format.byteCount) : nil
        }
        private func verifyBorrow() {
            guard videoConsumption == .borrowedUntilNextSendOrFlush else { return }
            lock.withLock {
                guard let marker = previousMarker, let lease = leases[marker] else { return }
                guard lease.value != nil else { errors.append("Async borrow ended before next call/flush"); return }
                if previousPointer?.load(as: UInt32.self) != marker { errors.append("Borrowed pixels changed") }
            }
        }
        func videoSubmissionObservation(_ context: NetworkVideoSubmissionContext) -> NetworkVideoSubmissionObservation {
            lock.withLock {
                if recorded.count < 512 {
                    recorded.append(.init(callIndex: context.callIndex, contentEpoch: context.contentEpoch, marker: previousMarker ?? 0,
                        logicalEntryNanoseconds: logicalEntry, logicalReturnNanoseconds: logicalReturn,
                        transportTimecode100ns: context.timecode, actualSDKEntryUptimeNanoseconds: context.startedNanoseconds,
                        actualSDKReturnUptimeNanoseconds: context.finishedNanoseconds))
                } else { overflow += 1 }
            }
            if gates, context.callIndex == 10 { observationGate.hold() }
            return .init(connections: 0)
        }
        func sendAudio(_ bytes: UnsafeRawPointer, sampleTime: Int64) -> Int32? {
            lock.withLock { if audio.count < 16 { audio.append(sampleTime) } else { overflow += 1 } }
            return nil
        }
        func audioSubmissionObservation() -> (any NetworkTransportStatusObservation)? { nil }
        func flush() {
            verifyBorrow()
            lock.withLock { if let previousPointer { _ = previousPointer.load(as: UInt32.self) }; didFlush = true }
        }
        func close() { lock.withLock { if !didFlush { errors.append("Close preceded flush") }; didClose = true } }
        func createProbe(source: String, audioOnly: Bool) -> Bool { false }
        func probeFrame(bytes: UnsafeMutableRawPointer, capacity: Int) -> NetworkProbeResult<Int64> { .invalid }
        func probeAudio() -> NetworkProbeResult<NetworkAudioObservation> { .invalid }
        func releaseGates() { sendGate.release(); observationGate.release(); stopGate.release() }
        var entries: [Entry] { lock.withLock { recorded } }
        var audioSamples: [Int64] { lock.withLock { audio } }
        var failures: [String] {
            let timeouts = [sendGate, observationGate, stopGate].contains { $0.timedOut }
            return lock.withLock { errors + (timeouts ? ["Controlled ordering gate timed out"] : []) }
        }
        var overflowCount: Int { lock.withLock { overflow } }
        var terminalCallCount: Int { lock.withLock { Int(calls) - recorded.count } }
        var closed: Bool { lock.withLock { didClose } }
        var flushed: Bool { lock.withLock { didFlush } }
    }
}
#endif
