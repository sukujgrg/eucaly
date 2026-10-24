#if DEBUG
import Foundation
import Darwin

/// Ordinary finite wake lateness is injected into the ACTUAL worker, before
/// admission and outside the SDK wrapper. No timer algorithm or timestamp is
/// simulated here. The separate stall fixture retains the borrow/fence tests.
enum NetworkSubmissionCadenceFixture {
    static let targetCalls: UInt64 = 300
    static let wakeDelayNanoseconds: UInt64 = 500_000

    struct Report: Codable {
        let schemaVersion: Int
        let boundary: String
        let traceFile: String
        let requestedLiveCalls: UInt64
        let liveCalls: UInt64
        let requestedWakeDelayNanoseconds: UInt64
        let injectedWakeCount: Int
        let minimumInjectedWakeNanoseconds: UInt64?
        let medianInjectedWakeNanoseconds: UInt64?
        let maximumInjectedWakeNanoseconds: UInt64?
        let minimumEntrySpacingNanoseconds: UInt64?
        let medianEntrySpacingNanoseconds: UInt64?
        let firstEntryNanoseconds: UInt64?
        let lastEntryNanoseconds: UInt64?
        let entryFramesPerSecond: Double?
        let measurementValid: Bool
        let measurementFailures: [String]
        let contractFailures: [String]
    }
    enum Failure: Error { case timeout(String), invalid(String) }

    static func run(directory: URL) throws {
        guard directory.path.hasPrefix("/") else { throw Failure.invalid("Use an absolute evidence directory") }
        // Match the live helper before creating timer/worker threads. These are
        // its existing public scheduling requests, not elevated priorities.
        var category = task_category_policy_data_t(role: TASK_DEFAULT_APPLICATION)
        let count = MemoryLayout<task_category_policy_data_t>.size / MemoryLayout<integer_t>.size
        let configured = withUnsafeMutablePointer(to: &category) { policy in
            policy.withMemoryRebound(to: integer_t.self, capacity: count) {
                task_policy_set(mach_task_self_, UInt32(TASK_CATEGORY_POLICY), $0, UInt32(count))
            }
        }
        guard configured == KERN_SUCCESS else { throw Failure.invalid("Task category failed: \(configured)") }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Controlled no-SDK ordinary wake-lateness cadence measurement")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let generation = UUID()
        let trace = NetworkVideoTrace(directory: directory, generation: generation, technology: "recording-cadence-fixture")
        let adapter = RecordingAdapter()
        let worker = NetworkSubmissionWorker(recording: adapter, trace: trace, wakeDelayNanoseconds: wakeDelayNanoseconds)
        let released = DispatchSemaphore(value: 0)
        var picture: GPUFrameLease? = GPUFrameLease(try SurfacePool.makeSurface(), poolOccupancy: 1) { released.signal() }
        worker.offer(picture!); picture = nil
        let started = DispatchSemaphore(value: 0), startup = StartupResult()
        worker.start(name: "No-SDK cadence fixture", technology: .omt, generation: generation) { status, error in
            startup.set(ready: status != nil, error: error); started.signal()
        }
        guard started.wait(timeout: .now() + .seconds(2)) == .success, startup.ready else {
            throw Failure.invalid(startup.error ?? "Worker did not start")
        }
        // Ordered by real adapter observations, not a sleep or manufactured
        // count. The CLI also owns an independent finite process deadline.
        guard adapter.reachedTarget.wait(timeout: .now() + .seconds(12)) == .success else {
            throw Failure.timeout("300 actual adapter calls")
        }
        let stopped = DispatchSemaphore(value: 0)
        worker.stop(colour: .chromaGreen) { _ in stopped.signal() }
        guard stopped.wait(timeout: .now() + .seconds(2)) == .success else { throw Failure.timeout("cleanup/export") }
        let snapshot = try JSONDecoder().decode(NetworkVideoTrace.Snapshot.self, from: Data(contentsOf: trace.fileURL))
        let live = snapshot.records.filter { $0.kind == "live" }
        let entries = live.compactMap(\.sdkEnteredNanoseconds)
        let gaps = zip(entries, entries.dropFirst()).compactMap { first, second in second >= first ? second - first : nil }.sorted()
        let wakeDurations = snapshot.records.compactMap { record -> UInt64? in
            guard let first = record.injectedWakeDelayStartedNanoseconds,
                  let second = record.injectedWakeDelayFinishedNanoseconds, second >= first else { return nil }
            return second - first
        }.sorted()
        var failures = snapshot.invalidReasons
        if !snapshot.valid { failures.append("Invalid common trace") }
        if snapshot.liveCallCount < targetCalls || UInt64(live.count) != snapshot.liveCallCount
            || snapshot.liveCallCount != adapter.calls { failures.append("Missing actual calls") }
        if entries.count != live.count || gaps.count != max(0, entries.count - 1) { failures.append("Missing entry times") }
        if wakeDurations.count != Int(snapshot.tickCount) { failures.append("Missing measured wake delays") }
        for record in live {
            guard let first = record.injectedWakeDelayStartedNanoseconds,
                  let second = record.injectedWakeDelayFinishedNanoseconds,
                  let sdk = record.sdkEnteredNanoseconds, second >= first,
                  second - first >= wakeDelayNanoseconds, first >= record.tickEnteredNanoseconds,
                  sdk >= second else { failures.append("Wake injection is missing, too short or inside SDK timing"); continue }
        }
        // A long uncontrolled pause is retained but cannot qualify as the
        // requested ordinary-wake experiment. Do not loosen cadence for it.
        if let longest = wakeDurations.last, longest > 2_000_000 { failures.append("Wake injection exceeded ordinary-delay bound") }
        var contracts: [String] = []
        if !adapter.closed || !adapter.flushed { contracts.append("Sender did not flush/close") }
        if released.wait(timeout: .now()) != .success { contracts.append("Frame lease survived cleanup") }
        if live.contains(where: { $0.contentEpoch != 0 || $0.consumption != "synchronous" }) {
            contracts.append("Unexpected owner/consumption change")
        }
        let first = entries.first, last = entries.last
        let fps: Double?
        if let first, let last, last > first { fps = Double(entries.count - 1) * 1_000_000_000 / Double(last - first) }
        else { fps = nil; failures.append("Missing cadence span") }
        let report = Report(schemaVersion: 1,
            boundary: "Actual worker, synchronous recording adapter, real 500us pre-admission wake delays; no SDK/network/player/window; no timestamp substitution",
            traceFile: trace.fileURL.lastPathComponent, requestedLiveCalls: targetCalls, liveCalls: snapshot.liveCallCount,
            requestedWakeDelayNanoseconds: wakeDelayNanoseconds, injectedWakeCount: wakeDurations.count,
            minimumInjectedWakeNanoseconds: wakeDurations.first, medianInjectedWakeNanoseconds: median(wakeDurations),
            maximumInjectedWakeNanoseconds: wakeDurations.last, minimumEntrySpacingNanoseconds: gaps.first,
            medianEntrySpacingNanoseconds: median(gaps), firstEntryNanoseconds: first, lastEntryNanoseconds: last,
            entryFramesPerSecond: fps, measurementValid: failures.isEmpty,
            measurementFailures: Array(Set(failures)).sorted(), contractFailures: contracts)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(report).write(to: directory.appendingPathComponent("cadence-report.json"), options: .atomic)
    }

    private static func median(_ sorted: [UInt64]) -> UInt64? { sorted.isEmpty ? nil : sorted[sorted.count / 2] }
    private final class StartupResult: @unchecked Sendable {
        private let lock = NSLock()
        private var isReady = false, failure: String?
        func set(ready: Bool, error: String?) { lock.withLock { isReady = ready; failure = error } }
        var ready: Bool { lock.withLock { isReady } }
        var error: String? { lock.withLock { failure } }
    }
    private final class RecordingAdapter: NetworkRuntimeAdapter, @unchecked Sendable {
        let reachedTarget = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var count: UInt64 = 0
        private var didFlush = false, didClose = false
        var version: String { "recording-cadence-adapter-no-sdk" }
        var sourceName: String? { "No-SDK cadence fixture" }
        var videoConsumption: NetworkVideoConsumption { .synchronous }
        func createSender(name: String) -> Bool { true }
        func sendVideo(_ bytes: UnsafeMutableRawPointer, format: NetworkVideoPixelFormat, timecode: Int64) -> Int32? { Int32(format.byteCount) }
        func videoSubmissionObservation(_ context: NetworkVideoSubmissionContext) -> NetworkVideoSubmissionObservation {
            lock.withLock { count += 1 }
            if context.callIndex == NetworkSubmissionCadenceFixture.targetCalls { reachedTarget.signal() }
            return .init(connections: 0)
        }
        func sendAudio(_ bytes: UnsafeRawPointer, sampleTime: Int64) -> Int32? { nil }
        func audioSubmissionObservation() -> (any NetworkTransportStatusObservation)? { nil }
        func flush() { lock.withLock { didFlush = true } }
        func close() { lock.withLock { didClose = true } }
        func createProbe(source: String, audioOnly: Bool) -> Bool { false }
        func probeFrame(bytes: UnsafeMutableRawPointer, capacity: Int) -> NetworkProbeResult<Int64> { .invalid }
        func probeAudio() -> NetworkProbeResult<NetworkAudioObservation> { .invalid }
        var calls: UInt64 { lock.withLock { count } }
        var closed: Bool { lock.withLock { didClose } }
        var flushed: Bool { lock.withLock { didFlush } }
    }
}
#endif
