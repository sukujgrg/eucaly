import XCTest
import AVFoundation
@testable import eucaly

@MainActor
final class ProgramAudioAACStressTests: XCTestCase {
    func testAAC44100RemainsContinuousWithSilentLocalPlayback() async throws {
        try await qualifyAAC(sampleRate: 44100)
    }

    func testAAC48000RemainsContinuousWithSilentLocalPlayback() async throws {
        try await qualifyAAC(sampleRate: 48000)
    }

    func testIrregular44100InputChunksKeepContinuousResampledAudio() async throws {
        try await qualifyIrregularInputChunks(assetFrameDifference: 0)
    }

    func testContiguousAssetRangesPreservePCMDespiteDifferentFrameDurations() async throws {
        try await qualifyIrregularInputChunks(assetFrameDifference: 10)
    }

    private func qualifyIrregularInputChunks(assetFrameDifference: Int64) async throws {
        let sourceRate = 44100.0
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2))
        let id = UUID()
        let first = CMClockGetTime(CMClockGetHostTimeClock())
            .convertScale(48000, method: .roundHalfAwayFromZero).value + 9600
        // Exclude converter priming, while inspecting the boundaries between
        // deliberately irregular source buffers throughout the measured window.
        let metrics = AACBusMetrics(start: first + 4800, end: first + 48000)
        let bus = ProgramAudioBus { metrics.consume($0, at: $1) }
        defer { bus.stop() }
        var inputs: [ProgramAudioBus.Input] = []
        let sizes = [1024, 3072, 4410, 333, 2048]
        var position = 0, chunk = 0
        var mediaPosition: Int64 = 0
        while position < 88200 {
            let count = min(sizes[chunk % sizes.count], 88200 - position)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            pcm.frameLength = AVAudioFrameCount(count)
            fillTone(pcm, firstFrame: position, sampleRate: sourceRate)
            let time = CMTime(value: first, timescale: 48000) + CMTime(value: mediaPosition, timescale: 44100)
            let mediaCount = Int64(count) - assetFrameDifference
            inputs.append(.init(pcm, at: time, duration: CMTime(value: mediaCount, timescale: 44100)))
            position += count; mediaPosition += mediaCount; chunk += 1
        }
        bus.setGain(1, id: id)
        XCTAssertTrue(bus.append(inputs, id: id))
        bus.start(at: CMTime(value: first, timescale: 48000))
        let deadline = ProcessInfo.processInfo.systemUptime + 4
        while !metrics.snapshot.complete, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let measured = metrics.snapshot
        assertContinuity(measured, expectedFrames: 43200, expectedRMS: 0.05 / sqrt(2), label: "irregular 44.1 kHz PCM")
        XCTAssertLessThan(measured.maximumSampleJump, 0.006,
            "Resampling must preserve the waveform across irregular input-buffer boundaries")
    }

    private func qualifyAAC(sampleRate: Double) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["EUCALY_AAC_AUDIO_STRESS"] == "1" else {
            throw XCTSkip("Set EUCALY_AAC_AUDIO_STRESS=1 for sustained real-player AAC qualification.")
        }
        let seconds = Double(environment["EUCALY_AAC_AUDIO_SECONDS"] ?? "30") ?? .nan
        guard seconds.isFinite, seconds >= 30, seconds <= 3600 else {
            throw AACAudioStressError.invalidDuration
        }
        let url = try makeAAC(sampleRate: sampleRate, duration: seconds + 8)
        defer { try? FileManager.default.removeItem(at: url) }
        // Assert the actual encoded fixture, so a platform encoder silently
        // selecting another sample rate cannot turn this into a different test.
        do {
            let file = try AVAudioFile(forReading: url)
            XCTAssertEqual(file.fileFormat.sampleRate, sampleRate, accuracy: 0.1)
            XCTAssertEqual(file.fileFormat.streamDescription.pointee.mFormatID, kAudioFormatMPEG4AAC)
        }
        let player = AVPlayer(url: url), gain = ProgramAudioGain()
        player.volume = 0; gain.set(0.25)
        let clock = AACBusMeasurement()
        let bus = ProgramAudioBus { clock.consume($0, at: $1) }
        let tap = PlayerProgramAudioSource(player: player, mixer: bus, programGain: gain)
        defer { tap.stop(); player.pause(); bus.stop() }
        let readyDeadline = ProcessInfo.processInfo.systemUptime + 8
        while !tap.isPrepared || player.status != .readyToPlay {
            guard ProcessInfo.processInfo.systemUptime < readyDeadline,
                  player.status != .failed else {
                XCTFail("AAC player did not become ready: \(player.error?.localizedDescription ?? "timeout")")
                throw AACAudioStressError.playerNotReady
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        let prerolled = await player.preroll(atRate: 1)
        XCTAssertTrue(prerolled)
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let first = now.convertScale(48000, method: .roundHalfAwayFromZero).value + 96000
        let expectedFrames = Int64((seconds * 48000).rounded())
        let metrics = AACBusMetrics(start: first, end: first + expectedFrames)
        clock.begin(metrics)
        bus.start(at: now); player.play()
        let deadline = ProcessInfo.processInfo.systemUptime + seconds + 7
        while !metrics.snapshot.complete, ProcessInfo.processInfo.systemUptime < deadline {
            tap.refresh()
            try await Task.sleep(for: .milliseconds(20))
        }
        let measured = metrics.snapshot
        let summary: [String: Any] = [
            "sampleRate": sampleRate, "measurementSeconds": seconds,
            "frames": measured.frames, "blocks": measured.blocks,
            "timecodeGaps": measured.timecodeGaps, "maximumTimecodeGapFrames": measured.maximumTimecodeGapFrames,
            "silentBlocks": measured.silentBlocks, "longestZeroRunFrames": measured.longestZeroRun,
            "leftRMS": measured.leftRMS, "rightRMS": measured.rightRMS,
            "minimumBlockRMS": measured.minimumBlockRMS, "maximumSampleJump": measured.maximumSampleJump,
            "nonFiniteSamples": measured.nonFiniteSamples,
            "localVolume": player.volume, "programGain": gain.value
        ]
        let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
        print("AAC audio qualification: " + String(decoding: data, as: UTF8.self))
        assertContinuity(measured, expectedFrames: expectedFrames, expectedRMS: 0.05 * 0.25 / sqrt(2), label: "AAC \(sampleRate) Hz")
        XCTAssertEqual(player.volume, 0)
        XCTAssertEqual(gain.value, 0.25)
    }

    private func assertContinuity(_ value: AACBusMetrics.Snapshot, expectedFrames: Int64,
                                  expectedRMS: Double, label: String,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value.complete, "\(label): the full measurement must finish", file: file, line: line)
        XCTAssertEqual(value.frames, expectedFrames, "\(label): no measured host-clock samples may go missing", file: file, line: line)
        XCTAssertEqual(value.timecodeGaps, 0, "\(label): output blocks must have contiguous timecodes", file: file, line: line)
        XCTAssertEqual(value.silentBlocks, 0, "\(label): continuous source audio must not become silent PCM", file: file, line: line)
        XCTAssertLessThan(value.longestZeroRun, 48, "\(label): no inserted silence lasting 1 ms", file: file, line: line)
        XCTAssertEqual(value.nonFiniteSamples, 0, file: file, line: line)
        XCTAssertEqual(value.leftRMS, expectedRMS, accuracy: expectedRMS * 0.05, file: file, line: line)
        XCTAssertEqual(value.rightRMS, expectedRMS, accuracy: expectedRMS * 0.05, file: file, line: line)
        XCTAssertGreaterThan(value.minimumBlockRMS, expectedRMS * 0.75,
            "\(label): partial missing coverage must not hide inside non-silent blocks", file: file, line: line)
    }

    private func makeAAC(sampleRate: Double, duration: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-aac-\(Int(sampleRate))-\(UUID()).m4a")
        var complete = false
        defer { if !complete { try? FileManager.default.removeItem(at: url) } }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000]
        // AVAudioFile uses the system encoder while accepting ordinary Float32
        // PCM; no external executable or downloaded fixture is required.
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let count = Int((duration * sampleRate).rounded(.up))
        var position = 0
        while position < count {
            let length = min(4096, count - position)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(length)))
            pcm.frameLength = AVAudioFrameCount(length)
            fillTone(pcm, firstFrame: position, sampleRate: sampleRate)
            try file.write(from: pcm); position += length
        }
        complete = true
        return url
    }

    private func fillTone(_ pcm: AVAudioPCMBuffer, firstFrame: Int, sampleRate: Double) {
        for channel in 0..<2 { for frame in 0..<Int(pcm.frameLength) {
            let frequency = channel == 0 ? 440.0 : 660.0
            pcm.floatChannelData![channel][frame] = Float(sin(Double(firstFrame + frame) * 2 * .pi * frequency / sampleRate)) * 0.05
        } }
    }
}

private enum AACAudioStressError: Error {
    case invalidDuration
    case playerNotReady
}

/// The bus callback retains only bounded counters, never an entire long PCM run.
nonisolated private final class AACBusMeasurement: @unchecked Sendable {
    private let lock = NSLock()
    private var active: AACBusMetrics?
    func begin(_ metrics: AACBusMetrics) { lock.lock(); active = metrics; lock.unlock() }
    func consume(_ pcm: AVAudioPCMBuffer, at time: AVAudioTime) {
        lock.lock(); let metrics = active; lock.unlock()
        metrics?.consume(pcm, at: time)
    }
}

nonisolated private final class AACBusMetrics: @unchecked Sendable {
    struct Snapshot {
        var frames: Int64 = 0
        var blocks = 0
        var timecodeGaps = 0
        var maximumTimecodeGapFrames: Int64 = 0
        var silentBlocks = 0
        var longestZeroRun = 0
        var nonFiniteSamples = 0
        var minimumBlockRMS = Double.greatestFiniteMagnitude
        var maximumSampleJump: Float = 0
        var complete = false
        fileprivate var leftPower = 0.0
        fileprivate var rightPower = 0.0
        var leftRMS: Double { frames == 0 ? 0 : sqrt(leftPower / Double(frames)) }
        var rightRMS: Double { frames == 0 ? 0 : sqrt(rightPower / Double(frames)) }
    }
    private let lock = NSLock()
    private let start: Int64, end: Int64
    private var value = Snapshot()
    private var lastBlock: Int64?
    private var zeroRuns = [0, 0]
    private var previous: [Float?] = [nil, nil]
    init(start: Int64, end: Int64) { self.start = start; self.end = end }
    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return value }
    func consume(_ pcm: AVAudioPCMBuffer, at time: AVAudioTime) {
        let blockStart = time.sampleTime, blockEnd = blockStart + Int64(pcm.frameLength)
        guard blockEnd > start, blockStart < end, let channels = pcm.floatChannelData else { return }
        lock.lock(); defer { lock.unlock() }
        if let lastBlock, blockStart != lastBlock + 960 {
            value.timecodeGaps += 1
            value.maximumTimecodeGapFrames = max(value.maximumTimecodeGapFrames, abs(blockStart - lastBlock - 960))
        }
        lastBlock = blockStart
        let begin = Int(max(start, blockStart) - blockStart)
        let finish = Int(min(end, blockEnd) - blockStart)
        var powers = [0.0, 0.0], silent = true
        for channel in 0..<2 { for frame in begin..<finish {
            let sample = channels[channel][frame]
            guard sample.isFinite else { value.nonFiniteSamples += 1; continue }
            powers[channel] += Double(sample * sample)
            if abs(sample) < 0.00000001 {
                zeroRuns[channel] += 1
                value.longestZeroRun = max(value.longestZeroRun, zeroRuns[channel])
            } else { silent = false; zeroRuns[channel] = 0 }
            if let last = previous[channel] { value.maximumSampleJump = max(value.maximumSampleJump, abs(sample - last)) }
            previous[channel] = sample
        } }
        value.frames += Int64(finish - begin); value.blocks += 1
        value.leftPower += powers[0]; value.rightPower += powers[1]
        if finish - begin == 960 {
            if silent { value.silentBlocks += 1 }
            let blockRMS = min(sqrt(powers[0] / 960), sqrt(powers[1] / 960))
            value.minimumBlockRMS = min(value.minimumBlockRMS, blockRMS)
        }
        value.complete = blockEnd >= end
    }
}
