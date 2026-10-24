#if DEBUG
import Foundation

/// Full, opt-in wrapper-boundary evidence. This records no payload and performs
/// no SDK queries. Only the SDK-video owner mutates it; export follows cleanup.
final class NetworkVideoTrace: @unchecked Sendable {
    static let periodNanoseconds: UInt64 = 1_000_000_000 / 30
    static let capacity = 65_536 // About 36 minutes at 30 Hz; overflow invalidates.

    struct Record: Codable, Sendable {
        var kind = "idle"
        var tickIndex: UInt64?
        var tickEnteredNanoseconds: UInt64
        var timerFirings: UInt64?
        var contentEpoch: UInt64?
        var callIndex: UInt64?
        var timecode: Int64?
        var consumption: String?
        var format: UInt32?
        var rawByteCount: Int?
        var injectedWakeDelayStartedNanoseconds: UInt64?
        var injectedWakeDelayFinishedNanoseconds: UInt64?
        var injectedDelayStartedNanoseconds: UInt64?
        var injectedDelayFinishedNanoseconds: UInt64?
        var sdkEnteredNanoseconds: UInt64?
        var sdkReturnedNanoseconds: UInt64?
        var returnedBytes: Int32?
        var observationFinishedNanoseconds: UInt64?
        var tickFinishedNanoseconds: UInt64?
    }

    struct Snapshot: Codable, Sendable {
        let schemaVersion: Int
        let boundary: String
        let generation: UUID?
        let processIdentifier: Int32
        let technology: String
        let runtimeVersion: String
        let timerAnchorNanoseconds: UInt64
        let periodNanoseconds: UInt64
        let capacity: Int
        let tickCount: UInt64
        let liveCallCount: UInt64
        let terminalCallCount: UInt64
        let expectedLiveCalls: UInt64
        let overflowCount: UInt64
        let valid: Bool
        let invalidReasons: [String]
        let records: [Record]
    }

    let fileURL: URL
    private let generation: UUID?
    private let technology: String
    private var runtimeVersion = ""
    private(set) var timerAnchorNanoseconds: UInt64 = 0
    private var tickCount: UInt64 = 0
    private var liveCallCount: UInt64 = 0
    private var terminalCallCount: UInt64 = 0
    private var overflowCount: UInt64 = 0
    private var records: [Record] = []

    init(directory: URL, generation: UUID?, technology: String) {
        self.generation = generation
        self.technology = technology
        fileURL = directory.appendingPathComponent("video-trace-\(ProcessInfo.processInfo.processIdentifier)-\(generation?.uuidString ?? "missing-generation").json")
        records.reserveCapacity(Self.capacity)
    }

    static func fromEnvironment(generation: UUID?, technology: NetworkOutputTechnology) -> NetworkVideoTrace? {
        guard let path = ProcessInfo.processInfo.environment["EUCALY_NETWORK_VIDEO_TRACE_DIRECTORY"],
              path.hasPrefix("/"), !path.contains("\0") else { return nil }
        return .init(directory: URL(fileURLWithPath: path, isDirectory: true), generation: generation,
                     technology: technology.rawValue)
    }

    func started(runtimeVersion: String, timerAnchor: UInt64) {
        self.runtimeVersion = runtimeVersion
        timerAnchorNanoseconds = timerAnchor
    }

    func tick(firings: UInt64) -> Record {
        tickCount += 1
        return .init(tickIndex: tickCount, tickEnteredNanoseconds: DispatchTime.now().uptimeNanoseconds,
                     timerFirings: firings)
    }

    func terminal(consumption: NetworkVideoConsumption, format: NetworkVideoPixelFormat, timecode: Int64) -> Record {
        .init(kind: "terminal", tickEnteredNanoseconds: DispatchTime.now().uptimeNanoseconds,
              timecode: timecode, consumption: consumption.rawValue, format: format.rawValue, rawByteCount: format.byteCount)
    }

    func record(_ value: Record) {
        if value.kind == "live" { liveCallCount += 1 }
        if value.kind == "terminal" { terminalCallCount += 1 }
        guard records.count < Self.capacity else { overflowCount += 1; return }
        records.append(value)
    }

    private func snapshot(expectedLiveCalls: UInt64) -> Snapshot {
        var failures: [String] = []
        if generation == nil { failures.append("missing generation") }
        if timerAnchorNanoseconds == 0 { failures.append("missing timer anchor") }
        if overflowCount != 0 { failures.append("trace overflow") }
        let live = records.filter { $0.kind == "live" }
        let ticks = records.filter { $0.tickIndex != nil }
        if liveCallCount != expectedLiveCalls || UInt64(live.count) != expectedLiveCalls {
            failures.append("missing live calls")
        }
        if UInt64(ticks.count) != tickCount || ticks.enumerated().contains(where: { $0.element.tickIndex != UInt64($0.offset + 1) }) {
            failures.append("missing ticks")
        }
        if live.enumerated().contains(where: { $0.element.callIndex != UInt64($0.offset + 1) }) {
            failures.append("missing or reordered call indices")
        }
        var priorEntry: UInt64 = 0
        var priorTimecode: Int64 = -1
        for record in records {
            guard let tickFinished = record.tickFinishedNanoseconds, tickFinished >= record.tickEnteredNanoseconds else {
                failures.append("incomplete tick"); continue
            }
            guard record.kind != "idle" else { continue }
            guard let entered = record.sdkEnteredNanoseconds, let returned = record.sdkReturnedNanoseconds,
                  let timecode = record.timecode, entered >= record.tickEnteredNanoseconds,
                  returned >= entered, tickFinished >= returned,
                  entered > priorEntry, timecode > priorTimecode,
                  let format = record.format.flatMap(NetworkVideoPixelFormat.init(rawValue:)),
                  record.rawByteCount == format.byteCount,
                  record.consumption == NetworkVideoConsumption.synchronous.rawValue
                    || record.consumption == NetworkVideoConsumption.borrowedUntilNextSendOrFlush.rawValue else {
                failures.append("invalid or incomplete call"); continue
            }
            if record.kind == "live" {
                guard let observed = record.observationFinishedNanoseconds, observed >= returned,
                      tickFinished >= observed, record.contentEpoch != nil else {
                    failures.append("missing observation completion or epoch"); continue
                }
                if timecode != Int64(entered / 100) { failures.append("timecode is not actual host entry time") }
            }
            priorEntry = entered
            priorTimecode = timecode
        }
        if terminalCallCount != 1 { failures.append("missing terminal call") }
        return .init(schemaVersion: 1,
            boundary: "Swift runtime.sendVideo wrapper entry/return, not internal SDK enqueue, socket completion or receiver arrival",
            generation: generation, processIdentifier: ProcessInfo.processInfo.processIdentifier,
            technology: technology, runtimeVersion: runtimeVersion, timerAnchorNanoseconds: timerAnchorNanoseconds,
            periodNanoseconds: Self.periodNanoseconds, capacity: Self.capacity, tickCount: tickCount,
            liveCallCount: liveCallCount, terminalCallCount: terminalCallCount, expectedLiveCalls: expectedLiveCalls,
            overflowCount: overflowCount, valid: failures.isEmpty, invalidReasons: Array(Set(failures)).sorted(), records: records)
    }

    /// The owner stops mutating before this method is called. Copy-on-write
    /// snapshots are encoded/written solely on the utility queue after cleanup.
    func exportAfterStop(expectedLiveCalls: UInt64, completion: @escaping @Sendable () -> Void) {
        let value = snapshot(expectedLiveCalls: expectedLiveCalls)
        let fileURL = fileURL
        DispatchQueue.global(qos: .utility).async {
            do {
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                try encoder.encode(value).write(to: fileURL, options: .atomic)
            } catch {
                FileHandle.standardError.write(Data("Video trace export failed: \(error)\n".utf8))
            }
            completion()
        }
    }
}
#endif
