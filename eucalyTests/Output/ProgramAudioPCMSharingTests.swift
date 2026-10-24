import AVFoundation
import XCTest
@testable import eucaly

@MainActor
final class ProgramAudioPCMSharingTests: XCTestCase {
    func testSharedAdmissionNeverReentersProducerBufferFromConcurrentMixers() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let pcm = try XCTUnwrap(ProducerPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        pcm.frameLength = 4800
        // This matches the decoder's cold-buffer construction: it fills raw
        // planes without priming AVAudioPCMBuffer's floatChannelData table.
        let planes = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for channel in 0..<2 {
            let samples = try XCTUnwrap(planes[channel].mData).assumingMemoryBound(to: Float.self)
            samples.initialize(repeating: channel == 0 ? 0.125 : -0.0625, count: 4800)
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        let start = (now / 960 + 8) * 960
        let admission = ProgramAudioBus.Input(pcm, at: CMTime(value: start, timescale: 48000))
        pcm.accesses.arm()
        let first = SharedPCMMeasurement(start: start, count: 4800), second = SharedPCMMeasurement(start: start, count: 4800)
        let a = ProgramAudioBus { first.consume($0, at: $1) }, b = ProgramAudioBus { second.consume($0, at: $1) }
        defer { a.stop(); b.stop() }
        let id = UUID()
        for bus in [a, b] {
            bus.setGain(1, id: id)
            XCTAssertTrue(bus.append([admission], id: id))
            bus.start(at: CMTime(value: start, timescale: 48000))
        }
        try await until("both destinations consume the complete shared PCM window", timeout: 3) {
            first.snapshot.complete && second.snapshot.complete
        }
        assertPCM(first.snapshot, count: 4800); assertPCM(second.snapshot, count: 4800)
        XCTAssertEqual(pcm.accesses.count, 0,
            "Fanout must use immutable admission metadata and sample planes; the producer's AVAudioPCMBuffer accessors cannot run on destination queues")
    }

    func testShared44100PCMUsesIndependentConversionViewsWithoutReenteringItsOwner() async throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let pcm = try XCTUnwrap(ProducerPCMBuffer(pcmFormat: format, frameCapacity: 44100))
        pcm.frameLength = 44100
        let planes = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
        for channel in 0..<2 {
            let samples = try XCTUnwrap(planes[channel].mData).assumingMemoryBound(to: Float.self)
            samples.initialize(repeating: channel == 0 ? 0.125 : -0.0625, count: 44100)
        }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        let start = (now / 960 + 8) * 960
        let admission = ProgramAudioBus.Input(pcm, at: CMTime(value: start, timescale: 48000))
        pcm.accesses.arm()
        // Exclude converter priming while checking the actual resampled PCM.
        let first = SharedPCMMeasurement(start: start + 4800, count: 4800)
        let second = SharedPCMMeasurement(start: start + 4800, count: 4800)
        let a = ProgramAudioBus { first.consume($0, at: $1) }, b = ProgramAudioBus { second.consume($0, at: $1) }
        defer { a.stop(); b.stop() }
        let id = UUID()
        for bus in [a, b] {
            bus.setGain(1, id: id)
            XCTAssertTrue(bus.append([admission], id: id))
            bus.start(at: CMTime(value: start, timescale: 48000))
        }
        try await until("both destinations independently resample shared 44.1 kHz PCM", timeout: 3) {
            first.snapshot.complete && second.snapshot.complete
        }
        // The 44.1 → 48 kHz polyphase filter has a small phase-dependent DC
        // response (about 5e-6 here). Direct PCM retains the tighter oracle.
        assertPCM(first.snapshot, count: 4800, accuracy: 0.00001)
        assertPCM(second.snapshot, count: 4800, accuracy: 0.00001)
        XCTAssertEqual(pcm.accesses.count, 0, "The converters must receive destination-local AVAudioPCMBuffer metadata")
    }

    func testBackingLifetimeAfterProducerAndAdmissionRetireForPlanarAndInterleavedPCM() async throws {
        for interleaved in [false, true] {
            let sampleRate = interleaved ? 44100.0 : 48000.0
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate, channels: 2, interleaved: interleaved))
            let first = SharedPCMMeasurement(start: 0, count: 0), second = SharedPCMMeasurement(start: 0, count: 0)
            let a = ProgramAudioBus { first.consume($0, at: $1) }, b = ProgramAudioBus { second.consume($0, at: $1) }
            defer { a.stop(); b.stop() }
            let released = expectation(description: "\(interleaved ? "interleaved conversion" : "direct planar") backing released")
            weak var producer: ProducerPCMBuffer?
            var admission: ProgramAudioBus.Input?
            do {
                let frames = Int(sampleRate / 2)
                let pcm = try XCTUnwrap(ProducerPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
                producer = pcm
                pcm.lifetime.notify { released.fulfill() }
                pcm.frameLength = AVAudioFrameCount(frames)
                let planes = UnsafeMutableAudioBufferListPointer(pcm.mutableAudioBufferList)
                if interleaved {
                    let samples = try XCTUnwrap(planes[0].mData).assumingMemoryBound(to: Float.self)
                    for index in 0..<frames { samples[index * 2] = 0.125; samples[index * 2 + 1] = -0.0625 }
                } else {
                    for channel in 0..<2 {
                        let samples = try XCTUnwrap(planes[channel].mData).assumingMemoryBound(to: Float.self)
                        samples.initialize(repeating: channel == 0 ? 0.125 : -0.0625, count: frames)
                    }
                }
                admission = ProgramAudioBus.Input(pcm, at: .zero)
            }
            let id = UUID(), admitted = expectation(description: "both destination admission queues drained")
            admitted.expectedFulfillmentCount = 2
            for bus in [a, b] {
                XCTAssertTrue(bus.append([try XCTUnwrap(admission)], id: id))
                bus.updateDelivery { admitted.fulfill() }
            }
            admission = nil
            await fulfillment(of: [admitted], timeout: 2)
            // Direct segments still borrow the producer's allocation. Converted
            // segments may already own independent output; the conversion view
            // must retain the source until the converter has finished with it.
            if !interleaved { XCTAssertNotNil(producer) }
            var optionalClock: CMTimebase?
            XCTAssertEqual(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                sourceClock: CMClockGetHostTimeClock(), timebaseOut: &optionalClock), noErr)
            let clock = try XCTUnwrap(optionalClock)
            let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
            let start = (now / 960 + 2) * 960
            XCTAssertEqual(CMTimebaseSetRateAndAnchorTime(clock, rate: 1, anchorTime: .zero,
                immediateSourceTime: CMTime(value: start, timescale: 48000)), noErr)
            for measurement in [first, second] { measurement.begin(start: start + 4800, count: 4800) }
            for bus in [a, b] {
                bus.setPlaybackClock(clock, gain: 1, id: id)
                bus.start(at: CMTime(value: start, timescale: 48000))
            }
            try await until("PCM survives retirement of the producer and admission", timeout: 3) {
                first.snapshot.complete && second.snapshot.complete
            }
            let accuracy: Float = interleaved ? 0.00001 : 0.000001
            assertPCM(first.snapshot, count: 4800, accuracy: accuracy)
            assertPCM(second.snapshot, count: 4800, accuracy: accuracy)
            a.stop(); b.stop()
            await fulfillment(of: [released], timeout: 2)
            XCTAssertNil(producer, "No destination or conversion metadata may retain the backing allocation after teardown")
        }
    }

    func testThreeDestinationsShareOneActualPlayerForSixSecondsOfContinuousPCM() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-shared-pcm-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeFixture(url)
        let player = AVPlayer(url: url), gain = ProgramAudioGain()
        player.volume = 0; player.sourceClock = CMClockGetHostTimeClock()
        var measurements: [SharedPCMMeasurement] = []
        var buses: [ProgramAudioBus] = []
        var sources: [PlayerProgramAudioSource] = []
        defer { for source in sources { source.stop() }; player.pause(); for bus in buses { bus.stop() } }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        // Choose the observation window after all three consumers are prepared.
        let initial = (now / 960 + 1) * 960
        for _ in 0..<3 {
            let measurement = SharedPCMMeasurement(start: initial, count: 0)
            let bus = ProgramAudioBus { measurement.consume($0, at: $1) }
            measurements.append(measurement); buses.append(bus)
            sources.append(PlayerProgramAudioSource(player: player, mixer: bus, programGain: gain))
        }
        try await until("shared player and asset decoder prepared", timeout: 8) {
            sources.forEach { $0.refresh() }
            return sources.allSatisfy(\.isPrepared) && player.status == .readyToPlay
        }
        XCTAssertEqual(Set(sources.map(\.sourceID)).count, 1)
        let started = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        let start = (started / 960 + 50) * 960
        for measurement in measurements { measurement.begin(start: start, count: 6 * 48000) }
        for bus in buses { bus.start(at: CMTime(value: started, timescale: 48000)) }
        player.play(); sources.forEach { $0.refresh() }
        try await until("six seconds of PCM on all concurrent destination buses", timeout: 9) {
            sources.forEach { $0.refresh() }
            return measurements.allSatisfy { $0.snapshot.complete }
        }
        for measurement in measurements { assertPCM(measurement.snapshot, count: 6 * 48000) }
        XCTAssertEqual(player.volume, 0)
        XCTAssertTrue(sources.allSatisfy { $0.failureReason == nil })
    }

    private func assertPCM(_ snapshot: SharedPCMMeasurement.Snapshot, count: Int64, accuracy: Float = 0.000001) {
        XCTAssertEqual(snapshot.frames, count)
        XCTAssertEqual(snapshot.discontinuities, 0)
        XCTAssertEqual(snapshot.nonFinite, 0)
        XCTAssertEqual(snapshot.maximumError, 0, accuracy: accuracy)
    }
    private func until(_ reason: String, timeout: Double, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(for: .milliseconds(5)) }
        guard condition() else { XCTFail("Timed out: \(reason)"); throw NetworkHelperWire.Failure.unavailable }
    }
    private func writeFixture(_ url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480000))
        pcm.frameLength = 480000
        pcm.floatChannelData![0].initialize(repeating: 0.125, count: 480000)
        pcm.floatChannelData![1].initialize(repeating: -0.0625, count: 480000)
        try file.write(from: pcm)
    }
}

/// A producer may retire or replace its AVFoundation-facing state after it
/// admits PCM. Destination work must not re-enter that object's metadata APIs.
nonisolated private final class ProducerPCMBuffer: AVAudioPCMBuffer, @unchecked Sendable {
    let accesses = ProducerPCMAccesses()
    let lifetime = ProducerPCMLifetime()
    override var format: AVAudioFormat { accesses.record(); return super.format }
    override var frameLength: AVAudioFrameCount {
        get { accesses.record(); return super.frameLength }
        set { accesses.record(); super.frameLength = newValue }
    }
    override var audioBufferList: UnsafePointer<AudioBufferList> { accesses.record(); return super.audioBufferList }
    override var mutableAudioBufferList: UnsafeMutablePointer<AudioBufferList> { accesses.record(); return super.mutableAudioBufferList }
    override var floatChannelData: UnsafePointer<UnsafeMutablePointer<Float>>? { accesses.record(); return super.floatChannelData }
    deinit { lifetime.didRelease() }
}

nonisolated private final class ProducerPCMLifetime: @unchecked Sendable {
    private var onRelease: (@Sendable () -> Void)?
    func notify(_ callback: @escaping @Sendable () -> Void) { onRelease = callback }
    func didRelease() { onRelease?() }
}

nonisolated private final class ProducerPCMAccesses: @unchecked Sendable {
    private let lock = NSLock()
    private var armed = false, stored = 0
    var count: Int { lock.withLock { stored } }
    func arm() { lock.withLock { armed = true; stored = 0 } }
    func record() { lock.withLock { if armed { stored += 1 } } }
}

nonisolated private final class SharedPCMMeasurement: @unchecked Sendable {
    struct Snapshot {
        var frames: Int64 = 0, discontinuities = 0, nonFinite = 0
        var maximumError: Float = 0
        var complete = false
    }
    private let lock = NSLock()
    private var start: Int64, count: Int64, next: Int64
    private var stored = Snapshot()
    init(start: Int64, count: Int64) { self.start = start; self.count = count; next = start }
    var snapshot: Snapshot { lock.withLock { stored } }
    func begin(start: Int64, count: Int64) { lock.withLock { self.start = start; self.count = count; next = start; stored = Snapshot() } }
    func consume(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let channels = buffer.floatChannelData else { return }
        lock.withLock {
            guard count > 0, !stored.complete else { return }
            let begin = max(start, time.sampleTime), end = min(start + count, time.sampleTime + Int64(buffer.frameLength))
            guard begin < end else { return }
            if begin != next { stored.discontinuities += 1 }
            for sample in begin..<end {
                let index = Int(sample - time.sampleTime)
                for channel in 0..<2 {
                    let value = channels[channel][index], expected: Float = channel == 0 ? 0.125 : -0.0625
                    if value.isFinite { stored.maximumError = max(stored.maximumError, abs(value - expected)) }
                    else { stored.nonFinite += 1 }
                }
            }
            stored.frames += end - begin; next = end
            stored.complete = end == start + count
        }
    }
}
