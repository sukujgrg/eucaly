@preconcurrency import AVFoundation
import Foundation
import XCTest
@testable import eucaly

/// Observes the actual application mixer/distribution output before the SDK.
/// This is PCM evidence, never a claim of network or physical receiver delivery.
nonisolated final class OMTProductionAudioOracle: @unchecked Sendable {
    enum Expectation: Sendable {
        case observe
        case silence
        case constant(left: Float, right: Float)
        case rms(left: Double, right: Double, tolerance: Double)
        case position(PositionPattern, tolerance: Double)

        fileprivate var label: String {
            switch self {
            case .observe: "observe arbitrary PCM"
            case .silence: "known silence"
            case .constant: "known constant PCM"
            case .rms: "known RMS; no waveform-position claim"
            case .position: "known source position from frozen host clock"
            }
        }
    }

    /// Matches the generated position PCM used by ProgramAudioClockTests. The
    /// reference is frozen before observation; observed values never select it.
    struct PositionPattern: Sendable {
        let hostAnchor: Double
        let mediaAnchor: Double
        let rate: Double
        let leftOffset: Double
        let rightOffset: Double
        let increment: Double

        init(clock: CMTimebase, leftOffset: Double = 0.1, rightOffset: Double = 0.1,
             increment: Double = 0.0000001) throws {
            var rate = 0.0, media = CMTime.invalid, host = CMTime.invalid
            guard CMSyncGetRelativeRateAndAnchorTime(clock, relativeTo: CMClockGetHostTimeClock(),
                relativeRateOut: &rate, anchorTimeOut: &media, relativeToAnchorTimeOut: &host) == noErr,
                rate.isFinite, rate > 0, media.isNumeric, host.isNumeric,
                !CMSyncMightDrift(clock, CMClockGetHostTimeClock()), leftOffset.isFinite,
                rightOffset.isFinite, increment.isFinite else {
                throw NSError(domain: "OMTProductionAudioOracle", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Position PCM requires a frozen running common-source clock."])
            }
            self.init(hostAnchor: host.seconds * 48000, mediaAnchor: media.seconds * 48000,
                rate: rate, leftOffset: leftOffset, rightOffset: rightOffset, increment: increment)
        }

        init(hostAnchor: Double, mediaAnchor: Double, rate: Double = 1,
             leftOffset: Double = 0.1, rightOffset: Double = 0.1, increment: Double = 0.0000001) {
            self.hostAnchor = hostAnchor; self.mediaAnchor = mediaAnchor; self.rate = rate
            self.leftOffset = leftOffset; self.rightOffset = rightOffset; self.increment = increment
        }

        fileprivate func sample(host: Int64, channel: Int) -> Float {
            let media = (mediaAnchor + (Double(host) - hostAnchor) * rate).rounded()
            return Float((channel == 0 ? leftOffset : rightOffset) + media * increment)
        }
    }

    private struct Key: Hashable { let destination: UUID; let generation: UUID }
    private struct Phase {
        let id: UInt64
        let name: String
        let effectiveSample: Int64
        let expectation: Expectation
        let expectations: [UUID: Expectation]
    }
    private struct Measurement {
        var valid = false
        var nonFinite = 0, outOfRange = 0
        var leftRMS = 0.0, rightRMS = 0.0, peak = 0.0
        var fingerprint: UInt64 = 14695981039346656037
        var expectationError = 0.0
        var expectationFailed = false
    }
    private struct Statistics {
        var blocks: UInt64 = 0, invalidBlocks: UInt64 = 0, nonFiniteSamples: UInt64 = 0, outOfRangeSamples: UInt64 = 0
        var silentBlocks: UInt64 = 0, repeatedFingerprints: UInt64 = 0, expectationFailures: UInt64 = 0
        var timestampDiscontinuities: UInt64 = 0, stableTimestampGaps: UInt64 = 0, transitionTimestampGaps: UInt64 = 0
        var duplicateTimestamps: UInt64 = 0, timestampRegressions: UInt64 = 0, overlappingTimestamps: UInt64 = 0
        var maximumMissingSamples: Int64 = 0, maximumExpectationError = 0.0, maximumPeak = 0.0
        var leftRMS = 0.0, rightRMS = 0.0
        var lastFingerprint: UInt64 = 0
        mutating func consume(_ value: Measurement, delta: Int64?, stable: Bool, repeated: Bool) {
            blocks &+= 1
            if !value.valid { invalidBlocks &+= 1 }
            nonFiniteSamples &+= UInt64(value.nonFinite); outOfRangeSamples &+= UInt64(value.outOfRange)
            if value.valid, value.peak == 0 { silentBlocks &+= 1 }
            if repeated { repeatedFingerprints &+= 1 }
            if value.expectationFailed { expectationFailures &+= 1 }
            maximumExpectationError = max(maximumExpectationError, value.expectationError)
            maximumPeak = max(maximumPeak, value.peak)
            leftRMS = value.leftRMS; rightRMS = value.rightRMS; lastFingerprint = value.fingerprint
            if let delta, delta != Int64(NDIAudioBlock.samples) {
                timestampDiscontinuities &+= 1
                if delta == 0 { duplicateTimestamps &+= 1 }
                else if delta < 0 { timestampRegressions &+= 1 }
                else if delta < Int64(NDIAudioBlock.samples) { overlappingTimestamps &+= 1 }
                else {
                    if stable { stableTimestampGaps &+= 1 } else { transitionTimestampGaps &+= 1 }
                    maximumMissingSamples = max(maximumMissingSamples, delta - Int64(NDIAudioBlock.samples))
                }
            }
        }
        var json: [String: Any] {
            ["blocks": blocks, "invalidBlocks": invalidBlocks, "nonFiniteSamples": nonFiniteSamples,
             "outOfRangeSamples": outOfRangeSamples, "silentBlocksObserved": silentBlocks,
             "repeatedFingerprintsObserved": repeatedFingerprints, "expectationFailures": expectationFailures,
             "maximumExpectationError": maximumExpectationError, "maximumPeak": maximumPeak,
             "timestampDiscontinuities": timestampDiscontinuities, "stableTimestampGaps": stableTimestampGaps,
             "transitionTimestampGaps": transitionTimestampGaps, "duplicateTimestamps": duplicateTimestamps,
             "timestampRegressions": timestampRegressions, "overlappingTimestamps": overlappingTimestamps,
             "maximumMissingSamples": maximumMissingSamples, "lastLeftRMS": leftRMS, "lastRightRMS": rightRMS,
             "lastFingerprint": String(lastFingerprint, radix: 16)]
        }
    }
    private struct PhaseResult {
        let id: UInt64
        let name: String
        let expectation: String
        var statistics = Statistics()
    }
    private struct Source {
        let key: Key
        var epoch: UInt64?
        var phase: UInt64?
        var lastSample: Int64?
        var lastFingerprint: UInt64?
        var statistics = Statistics()
        var phases: [PhaseResult] = []
        var transitions: [[String: Any]] = []
    }
    private let lock = NSLock()
    private var phases = [Phase(id: 0, name: "startup", effectiveSample: .min, expectation: .observe, expectations: [:])]
    private var nextPhase: UInt64 = 1
    private var sources: [Key: Source] = [:]
    private var sourceOrder: [Key] = []
    private var totals = Statistics()
    private var evictedGenerations: UInt64 = 0

    /// Label by media timestamp, not by the arrival order of concurrent queues.
    /// Labels retain their raw clock deltas, but only an actual content-epoch
    /// change classifies a gap as a transition. Duplicate/regressing timestamps
    /// are violations even across an epoch change.
    @discardableResult
    func beginPhase(_ name: String, expectation: Expectation = .observe,
                    expectations: [UUID: Expectation] = [:], effectiveSample: Int64? = nil) -> Int64 {
        let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        let effective = effectiveSample ?? ((now / Int64(NDIAudioBlock.samples) + 1) * Int64(NDIAudioBlock.samples))
        return lock.withLock {
            phases.append(.init(id: nextPhase, name: String(name.prefix(96)), effectiveSample: effective,
                expectation: expectation, expectations: expectations))
            nextPhase &+= 1
            if phases.count > 64 { phases.removeFirst(phases.count - 64) }
            return effective
        }
    }

    /// Close waveform expectations before mutating players or music routing.
    /// The phase is installed at ingress: every subsequent record, including an
    /// overdue block, observes arbitrary PCM. Already admitted measurements,
    /// coverage and failures remain intact; clock/epoch checks always continue.
    func endWaveformExpectations(_ name: String) {
        // The latest matching phase wins. An unbounded timestamp range makes
        // this an ingress boundary without relabelling earlier observations.
        beginPhase(name, effectiveSample: .min)
    }

    func record(_ block: NDIAudioBlock, destinationID: UUID, generation: UUID, contentEpoch: UInt64) {
        let phase = lock.withLock { phases.last(where: { $0.effectiveSample <= block.sampleTime }) ?? phases[0] }
        let expectation = phase.expectations[destinationID] ?? phase.expectation
        let value = Self.measure(block, expectation: expectation)
        let key = Key(destination: destinationID, generation: generation)
        lock.withLock {
            if sources[key] == nil {
                sources[key] = Source(key: key); sourceOrder.append(key)
                if sourceOrder.count > 32 {
                    sources[sourceOrder.removeFirst()] = nil; evictedGenerations &+= 1
                }
            }
            guard var source = sources[key] else { return }
            let validTimestamp = block.sampleTime >= 0 && block.sampleTime < Int64.max / 1000
            let delta = validTimestamp ? source.lastSample.map { block.sampleTime - $0 } : nil
            let stable = source.epoch == contentEpoch
            let repeated = value.valid && source.lastFingerprint == value.fingerprint
            if source.epoch != contentEpoch || source.phase != phase.id {
                source.transitions.append(["sampleTime": block.sampleTime, "epoch": contentEpoch,
                    "previousEpoch": source.epoch.map(String.init) ?? "none", "phase": phase.name,
                    "deltaSamples": delta.map(String.init) ?? "first block"])
                if source.transitions.count > 32 { source.transitions.removeFirst(source.transitions.count - 32) }
            }
            if source.phases.last?.id != phase.id {
                source.phases.append(.init(id: phase.id, name: phase.name, expectation: expectation.label))
                if source.phases.count > 8 { source.phases.removeFirst(source.phases.count - 8) }
            }
            source.statistics.consume(value, delta: delta, stable: stable, repeated: repeated)
            source.phases[source.phases.count - 1].statistics.consume(value, delta: delta, stable: stable, repeated: repeated)
            totals.consume(value, delta: delta, stable: stable, repeated: repeated)
            source.epoch = contentEpoch; source.phase = phase.id
            if validTimestamp { source.lastSample = block.sampleTime }
            source.lastFingerprint = value.valid ? value.fingerprint : nil
            sources[key] = source
        }
    }

    func report() -> [String: Any] {
        lock.withLock {
            ["scope": "actual application post-mix PCM before SDK; receiver delivery is measured separately",
             "phase": phases.last?.name ?? "startup", "phaseEffectiveSample": phases.last?.effectiveSample ?? 0,
             "phaseBoundary": phases.last?.effectiveSample == Int64.min ? "ingress" : "timestamp",
             "totals": totals.json, "evictedGenerations": evictedGenerations,
             "sources": sourceOrder.compactMap { key -> [String: Any]? in
                guard let source = sources[key] else { return nil }
                return ["destinationID": key.destination.uuidString, "generation": key.generation.uuidString,
                    "epoch": source.epoch ?? 0, "lastSampleTime": source.lastSample ?? 0,
                    "totals": source.statistics.json, "transitions": source.transitions,
                    "recentPhases": source.phases.map { ["name": $0.name, "expectation": $0.expectation, "metrics": $0.statistics.json] as [String: Any] }]
             }]
        }
    }

    private static func measure(_ block: NDIAudioBlock, expectation: Expectation) -> Measurement {
        var result = Measurement()
        guard block.sampleTime >= 0, block.sampleTime < Int64.max / 1000,
              block.pcm.count == NDIAudioBlock.samples * 2 * MemoryLayout<Float>.stride else { return result }
        result.valid = true
        var powers = [0.0, 0.0]
        block.pcm.withUnsafeBytes { bytes in
            for channel in 0..<2 { for frame in 0..<NDIAudioBlock.samples {
                let value = bytes.loadUnaligned(fromByteOffset: (channel * NDIAudioBlock.samples + frame) * MemoryLayout<Float>.stride, as: Float.self)
                result.fingerprint = (result.fingerprint ^ UInt64(value.bitPattern)) &* 1099511628211
                guard value.isFinite else { result.nonFinite += 1; result.expectationFailed = true; continue }
                let sample = Double(value)
                powers[channel] += sample * sample; result.peak = max(result.peak, abs(sample))
                if abs(sample) > 1 { result.outOfRange += 1 }
                let expected: Float?
                let tolerance: Double
                switch expectation {
                case .observe, .rms: expected = nil; tolerance = 0
                case .silence: expected = 0; tolerance = 0.000001
                case .constant(let left, let right): expected = channel == 0 ? left : right; tolerance = 0.000001
                case .position(let pattern, let error): expected = pattern.sample(host: block.sampleTime + Int64(frame), channel: channel); tolerance = error
                }
                if let expected {
                    guard expected.isFinite, tolerance.isFinite, tolerance >= 0 else {
                        result.expectationFailed = true; continue
                    }
                    let error = abs(sample - Double(expected))
                    result.expectationError = max(result.expectationError, error)
                    if error > tolerance { result.expectationFailed = true }
                }
            } }
        }
        result.leftRMS = sqrt(powers[0] / Double(NDIAudioBlock.samples))
        result.rightRMS = sqrt(powers[1] / Double(NDIAudioBlock.samples))
        if case .rms(let left, let right, let tolerance) = expectation {
            if left.isFinite, right.isFinite, tolerance.isFinite, tolerance >= 0 {
                result.expectationError = max(abs(result.leftRMS - left), abs(result.rightRMS - right))
                result.expectationFailed = result.expectationFailed || result.expectationError > tolerance
            } else { result.expectationFailed = true }
        }
        result.valid = result.nonFinite == 0 && result.outOfRange == 0
        return result
    }
}

@MainActor
final class OMTProductionAudioOracleTests: XCTestCase {
    func testPositionPatternRejectsRepeatedWaveformWithContinuousTimestamps() throws {
        let oracle = OMTProductionAudioOracle(), destination = UUID(), generation = UUID()
        let pattern = OMTProductionAudioOracle.PositionPattern(hostAnchor: 0, mediaAnchor: 0)
        oracle.beginPhase("known positions", expectation: .position(pattern, tolerance: 0.0000004), effectiveSample: 0)
        for (timestamp, assetPosition) in [(0, 0), (960, 960), (1920, 960)] {
            oracle.record(pcm(timestamp: Int64(timestamp)) { _, frame in Float(0.1 + Double(assetPosition + frame) * 0.0000001) },
                destinationID: destination, generation: generation, contentEpoch: 1)
        }
        let totals = try XCTUnwrap(oracle.report()["totals"] as? [String: Any])
        XCTAssertEqual(totals["expectationFailures"] as? UInt64, 1)
        XCTAssertEqual(totals["timestampDiscontinuities"] as? UInt64, 0,
            "A valid timestamp sequence cannot conceal repeated source PCM")
        XCTAssertEqual(totals["repeatedFingerprintsObserved"] as? UInt64, 1)
    }

    func testBoundaryClassificationRetainsClockGapsDuplicatesAndRegressions() throws {
        let oracle = OMTProductionAudioOracle(), destination = UUID(), generation = UUID()
        oracle.beginPhase("first", effectiveSample: 0)
        for timestamp in [0, 960] {
            oracle.record(pcm(timestamp: Int64(timestamp)) { _, _ in 0 }, destinationID: destination, generation: generation, contentEpoch: 1)
        }
        oracle.beginPhase("move", effectiveSample: 1920)
        for timestamp in [2880, 3840, 5760, 5760, 4800] {
            oracle.record(pcm(timestamp: Int64(timestamp)) { _, _ in 0 }, destinationID: destination, generation: generation, contentEpoch: 2)
        }
        let totals = try XCTUnwrap(oracle.report()["totals"] as? [String: Any])
        XCTAssertEqual(totals["transitionTimestampGaps"] as? UInt64, 1)
        XCTAssertEqual(totals["stableTimestampGaps"] as? UInt64, 1)
        XCTAssertEqual(totals["duplicateTimestamps"] as? UInt64, 1)
        XCTAssertEqual(totals["timestampRegressions"] as? UInt64, 1)
    }

    func testObservationalPhaseChangeDoesNotExemptMissingAudio() throws {
        let oracle = OMTProductionAudioOracle(), destination = UUID(), generation = UUID()
        oracle.beginPhase("steady", effectiveSample: 0)
        for timestamp in [0, 960] {
            oracle.record(pcm(timestamp: Int64(timestamp)) { _, _ in 0 },
                destinationID: destination, generation: generation, contentEpoch: 1)
        }
        oracle.beginPhase("status marker", effectiveSample: 1920)
        oracle.record(pcm(timestamp: 2880) { _, _ in 0 },
            destinationID: destination, generation: generation, contentEpoch: 1)

        let totals = try XCTUnwrap(oracle.report()["totals"] as? [String: Any])
        XCTAssertEqual(totals["stableTimestampGaps"] as? UInt64, 1,
            "A measurement label cannot conceal the missing 1920-sample block")
        XCTAssertEqual(totals["transitionTimestampGaps"] as? UInt64, 0)
        XCTAssertEqual(totals["timestampDiscontinuities"] as? UInt64, 1)
    }

    func testWaveformEndObservesOverdueIngressWithoutErasingFailuresOrClockGaps() throws {
        let oracle = OMTProductionAudioOracle(), destination = UUID(), generation = UUID()
        let pattern = OMTProductionAudioOracle.PositionPattern(hostAnchor: 0, mediaAnchor: 0)
        oracle.beginPhase("strict positions", expectation: .position(pattern, tolerance: 0.0000004), effectiveSample: 0)
        oracle.record(pcm(timestamp: 0) { _, frame in Float(0.1 + Double(frame) * 0.0000001) },
            destinationID: destination, generation: generation, contentEpoch: 1)
        oracle.record(pcm(timestamp: 960) { _, _ in 0 },
            destinationID: destination, generation: generation, contentEpoch: 1)

        // Hold an old-timestamp teardown block outside the oracle until the
        // command closes waveform admission. No timer or scheduling race is needed.
        let overdueTeardown = pcm(timestamp: 1920) { _, _ in 0 }
        oracle.endWaveformExpectations("teardown")
        oracle.record(overdueTeardown, destinationID: destination, generation: generation, contentEpoch: 1)
        oracle.record(pcm(timestamp: 3840) { _, _ in 0 },
            destinationID: destination, generation: generation, contentEpoch: 1)

        let report = oracle.report(), totals = try XCTUnwrap(report["totals"] as? [String: Any])
        XCTAssertEqual(totals["blocks"] as? UInt64, 4)
        XCTAssertEqual(totals["expectationFailures"] as? UInt64, 1,
            "The prior real failure survives; overdue teardown PCM adds no waveform failure")
        XCTAssertEqual(totals["stableTimestampGaps"] as? UInt64, 1)
        XCTAssertEqual(totals["transitionTimestampGaps"] as? UInt64, 0)
        XCTAssertEqual(totals["timestampDiscontinuities"] as? UInt64, 1)
        XCTAssertEqual(report["phaseBoundary"] as? String, "ingress")
        let sources = try XCTUnwrap(report["sources"] as? [[String: Any]])
        let phases = try XCTUnwrap(sources.first?["recentPhases"] as? [[String: Any]])
        let strict = try XCTUnwrap(phases.first { $0["name"] as? String == "strict positions" }?["metrics"] as? [String: Any])
        XCTAssertEqual(strict["blocks"] as? UInt64, 2, "Ending a phase must preserve its measured coverage")
        XCTAssertEqual(strict["expectationFailures"] as? UInt64, 1)

        oracle.beginPhase("new strict positions", expectation: .position(pattern, tolerance: 0.0000004), effectiveSample: 4800)
        oracle.record(pcm(timestamp: 4800) { _, _ in 0 },
            destinationID: destination, generation: generation, contentEpoch: 1)
        let resumed = try XCTUnwrap(oracle.report()["totals"] as? [String: Any])
        XCTAssertEqual(resumed["expectationFailures"] as? UInt64, 2, "A later strict phase reopens waveform checks")
    }

    func testMalformedAndNonFinitePCMProduceUsableFailureEvidence() throws {
        let oracle = OMTProductionAudioOracle(), destination = UUID(), generation = UUID()
        oracle.record(.init(sampleTime: Int64.min, pcm: Data()), destinationID: destination, generation: generation, contentEpoch: 1)
        oracle.record(pcm(timestamp: 0) { channel, frame in channel == 0 && frame == 0 ? .nan : 0.1 },
            destinationID: destination, generation: generation, contentEpoch: 1)
        let report = oracle.report(), totals = try XCTUnwrap(report["totals"] as? [String: Any])
        XCTAssertEqual(totals["invalidBlocks"] as? UInt64, 2)
        XCTAssertEqual(totals["nonFiniteSamples"] as? UInt64, 1)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(report), "The failing observation must remain writable before cleanup")
    }

    private func pcm(timestamp: Int64, _ value: (Int, Int) -> Float) -> NDIAudioBlock {
        let values = (0..<2).flatMap { channel in (0..<NDIAudioBlock.samples).map { value(channel, $0) } }
        return .init(sampleTime: timestamp, pcm: values.withUnsafeBufferPointer { Data(buffer: $0) })
    }
}
