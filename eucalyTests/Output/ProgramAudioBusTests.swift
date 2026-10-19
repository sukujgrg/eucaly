import XCTest
import AVFoundation
@testable import eucaly

@MainActor
final class ProgramAudioBusTests: XCTestCase {
    func testLiveFileAudioTapReachesTwoMediaOutputsAndRetiresCleanly() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-audio-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96000)); pcm.frameLength = 96000
            for channel in 0..<2 { for i in 0..<96000 { pcm.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.05 } }
            try file.write(from: pcm)
        }
        let one = RecordedProgramAudio(), two = RecordedProgramAudio()
        let a = ProgramAudioBus { one.offer(.audio($0, $1)) }, b = ProgramAudioBus { two.offer(.audio($0, $1)) }
        let player = AVPlayer(url: url); player.volume = 0.001
        let first = PlayerAudioTap(player: player, mixer: a), second = PlayerAudioTap(player: player, mixer: b)
        defer { first.stop(); second.stop(); player.pause(); a.stop(); b.stop(); one.finish(); two.finish() }
        let now = CMClockGetTime(CMClockGetHostTimeClock()); a.start(at: now); b.start(at: now); player.play()
        var heardA = false, heardB = false
        func audible(_ samples: [RecordedProgramAudio.Sample], from time: Double? = nil) -> Bool {
            samples.contains { sample in
                guard case .audio(let buffer, let when) = sample, let channel = buffer.floatChannelData?[0] else { return false }
                let first = time.map {
                    min(Int(buffer.frameLength), max(0, Int(ceil($0 * when.sampleRate - Double(when.sampleTime)))))
                } ?? 0
                return (first..<Int(buffer.frameLength)).contains { abs(channel[$0]) > 0.000001 }
            }
        }
        for _ in 0..<80 {
            first.refresh(); second.refresh()
            try await Task.sleep(nanoseconds: 25_000_000)
            heardA = audible(one.drain()) || heardA; heardB = audible(two.drain()) || heardB
            if heardA && heardB { break }
        }
        XCTAssertTrue(heardA, "Live file audio must reach the first destination")
        XCTAssertTrue(heardB, "A second destination must share the tap without stealing it")
        let pausedAt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        first.stop(); player.pause(); second.refresh()
        _ = two.drain()
        try await Task.sleep(nanoseconds: 100_000_000)
        let afterPause = two.drain()
        XCTAssertTrue(afterPause.contains { sample in
            guard case .audio(_, let when) = sample else { return false }
            return Double(when.sampleTime) / when.sampleRate >= pausedAt
        }, "Paused video must keep emitting silent audio")
        // A pre-pause render can arrive after the drain above. Check the PCM
        // sample clock so those already rendered samples do not race this test.
        XCTAssertFalse(audible(afterPause, from: pausedAt), "Paused video must not leak buffered audio")
    }
    func testLiveFileAudioRemainsContinuousAfterStartup() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-continuity-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192000)); pcm.frameLength = 192000
            for channel in 0..<2 { for i in 0..<192000 { pcm.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.05 } }
            try file.write(from: pcm)
        }
        let ingest = RecordedProgramAudio(), audio = ProgramAudioBus { ingest.offer(.audio($0, $1)) }
        let player = AVPlayer(url: url); player.volume = 0.001
        let tap = PlayerAudioTap(player: player, mixer: audio)
        defer { tap.stop(); player.pause(); audio.stop(); ingest.finish() }
        audio.start(at: CMClockGetTime(CMClockGetHostTimeClock())); player.play()
        var total = 0, silent = 0, emptyChunks = 0, maxSilent = 0, run = 0
        var previous: Float?, maxJump: Float = 0
        for tick in 0..<140 {
            tap.refresh(); try await Task.sleep(nanoseconds: 20_000_000)
            for sample in ingest.drain() {
                guard tick > 30, case .audio(let buffer, _) = sample, let channel = buffer.floatChannelData?[0] else { continue }
                var audible = false
                for i in 0..<Int(buffer.frameLength) {
                    total += 1
                    if let previous { maxJump = max(maxJump, abs(channel[i] - previous)) }; previous = channel[i]
                    if abs(channel[i]) < 0.0000001 { silent += 1; run += 1; maxSilent = max(maxSilent, run) }
                    else { audible = true; run = 0 }
                }
                if !audible { emptyChunks += 1 }
            }
        }
        print("Audio continuity: total=\(total), silence=\(silent), emptyChunks=\(emptyChunks), longest=\(maxSilent), maxJump=\(maxJump)")
        XCTAssertGreaterThan(total, 48000)
        XCTAssertLessThan(Double(silent) / Double(max(1, total)), 0.02, "A live sine wave must not be replaced by gaps before encoding")
        XCTAssertLessThan(maxSilent, 48, "No gap longer than 1 ms in the live-file audio feed")
        XCTAssertLessThan(maxJump, 0.00001, "PCM conversion must preserve waveform continuity across input chunks")
    }
    func testProgramAudioAlwaysHasBoundedContinuousSilenceWhenNoPlayerIsLive() async throws {
        let ingest = RecordedProgramAudio(), audio = ProgramAudioBus { ingest.offer(.audio($0, $1)) }
        audio.start(at: CMClockGetTime(CMClockGetHostTimeClock()))
        try await Task.sleep(nanoseconds: 100_000_000)
        let samples = ingest.drain()
        audio.stop(); ingest.finish()
        XCTAssertGreaterThan(samples.count, 0)
        for sample in samples {
            if case .audio(let pcm, _) = sample {
                XCTAssertEqual(pcm.frameLength, 960)
                XCTAssertEqual(pcm.format.sampleRate, 48000)
                XCTAssertEqual(pcm.floatChannelData?[0][0], 0)
                XCTAssertEqual(pcm.floatChannelData?[1][959], 0)
            } else { XCTFail("Audio bus must not synthesize video") }
        }
    }

    func testShortPrerolledFileReachesMediaOutput() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-audio-preroll-\(UUID()).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)); pcm.frameLength = 1024
            for channel in 0..<2 { for i in 0..<1024 { pcm.floatChannelData![channel][i] = Float(sin(Double(i) * 2 * .pi * 440 / 48000)) * 0.05 } }
            try file.write(from: pcm)
        }
        let player = AVPlayer(url: url); player.volume = 0.001
        defer { player.pause() }
        let ingest = RecordedProgramAudio(), audio = ProgramAudioBus { ingest.offer(.audio($0, $1)) }
        let tap = PlayerAudioTap(player: player, mixer: audio)
        defer { tap.stop(); audio.stop(); ingest.finish() }
        for _ in 0..<100 {
            if player.status == .readyToPlay && player.currentItem?.audioMix != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard player.status == .readyToPlay, player.currentItem?.audioMix != nil else {
            return XCTFail("The preroll fixture must be ready with its audio tap installed")
        }
        let prerolled = await player.preroll(atRate: 1)
        XCTAssertTrue(prerolled)
        audio.start(at: CMClockGetTime(CMClockGetHostTimeClock()))
        player.play()
        var audible = false
        for _ in 0..<400 {
            try await Task.sleep(for: .milliseconds(5))
            audible = ingest.drain().contains { sample in
                guard case .audio(let pcm, _) = sample, let channel = pcm.floatChannelData?[0] else { return false }
                return (0..<Int(pcm.frameLength)).contains { abs(channel[$0]) > 0.000001 }
            } || audible
            if audible { break }
        }
        XCTAssertTrue(audible, "Source audio decoded during preroll must reach media output when playback starts")
    }

    func testPrerollBatchReachesMixerWithoutLosingItsTail() async throws {
        let ingest = RecordedProgramAudio(), audio = ProgramAudioBus { ingest.offer(.audio($0, $1)) }, id = UUID()
        defer { audio.stop(); ingest.finish() }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let firstSample = Int64((CMClockGetTime(CMClockGetHostTimeClock()).seconds + 0.1) * 48000)
        var inputs: [(AVAudioPCMBuffer, CMTime)] = []
        for index in 0..<96 {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)); pcm.frameLength = 960
            for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: Float(index + 1) / 100, count: 960) }
            inputs.append((pcm, CMTime(value: firstSample + Int64(index * 960), timescale: 48000)))
        }
        audio.setGain(1, id: id)
        audio.append(inputs, id: id)
        audio.start(at: CMTime(value: firstSample, timescale: 48000))
        var samples: [RecordedProgramAudio.Sample] = []
        for _ in 0..<110 {
            try await Task.sleep(for: .milliseconds(20))
            samples.append(contentsOf: ingest.drain())
        }
        for index in 0..<96 {
            let midpoint = firstSample + Int64(index * 960 + 480)
            let actual: Float? = samples.compactMap { sample -> Float? in
                guard case .audio(let pcm, let when) = sample else { return nil }
                let offset = midpoint - when.sampleTime
                guard offset >= 0, offset < Int64(pcm.frameLength) else { return nil }
                return pcm.floatChannelData?[0][Int(offset)]
            }.first
            XCTAssertEqual(try XCTUnwrap(actual), Float(index + 1) / 100, accuracy: 0.00001,
                           "Every buffer in a preroll handoff must reach the encoded audio clock")
        }
    }
}


nonisolated private final class RecordedProgramAudio: @unchecked Sendable {
    enum Sample { case audio(AVAudioPCMBuffer, AVAudioTime) }
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var stopped = false
    func offer(_ sample: Sample) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        if samples.count == 256 { samples.removeFirst() }
        samples.append(sample)
    }
    func drain() -> [Sample] {
        lock.lock(); defer { lock.unlock() }
        let result = samples; samples.removeAll(keepingCapacity: true); return result
    }
    func finish() { lock.lock(); stopped = true; samples.removeAll(); lock.unlock() }
}
