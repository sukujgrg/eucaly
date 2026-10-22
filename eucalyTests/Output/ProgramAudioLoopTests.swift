import XCTest
import AVFoundation
@testable import eucaly

@MainActor
final class ProgramAudioLoopTests: XCTestCase {
    func testLoopingVideoRetainsNDIAudioAndContinuousHostClock() async throws {
        let url = try await Self.makeVideoWithAudio()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = OutputProfileStore()
        var destination = OutputDestinationConfiguration(name: "Loop audio", profileID: OutputProfile.audienceID, monitor: nil)
        destination.ndi = .init(sourceName: "Loop audio test")
        store.edit {
            $0.destinations = [destination]
            for index in $0.workspaces.indices { $0.workspaces[index].monitorAudioLocally = false }
        }
        let outputs = OutputCoordinator(profiles: store,
            displays: ProjectionDisplayManager(displays: { [] }), ndi: RecordingNDIOutput())
        let session = PresentationSession(projectionDisplays: outputs.displays, outputCoordinator: outputs)
        let audio = NDIProgramAudio(), received = LoopProgramAudio()
        defer { audio.stop(); outputs.stopAllOutputs() }
        audio.sourceFailed = { received.fail($0) }
        session.setSlides([Slide(index: 0, lines: [], label: "Loop", videoURL: url,
            pdfURL: nil, pdfPageIndex: nil, imageURL: nil)])
        session.videoLoop = true
        session.videoPaused = true
        session.showSlides()
        let runtime = try XCTUnwrap(outputs.media(for: destination.id))
        let player = try XCTUnwrap(runtime.program)
        let item = try XCTUnwrap(player.currentItem)
        let observer = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
            object: item, queue: .main) { _ in received.endIteration() }
        defer { NotificationCenter.default.removeObserver(observer) }
        audio.update(targets: [.init(id: destination.id, send: received.record)], music: nil,
            preparing: false, wantsVideo: true, runtime: runtime, session: session)
        try await until("loop fixture ready") { player.status == .readyToPlay }
        let prerolled = await player.preroll(atRate: 1)
        XCTAssertTrue(prerolled)
        let started = LoopProgramAudio.hostSample
        session.videoPaused = false
        try await until("three complete video iterations") { received.snapshot.ends.count >= 3 }
        let finalEnd = try XCTUnwrap(received.snapshot.ends.prefix(3).last)
        try await until("audio clock passed the third end") {
            received.snapshot.blocks.last.map { $0.sample >= finalEnd + 960 } == true
        }
        let result = received.snapshot
        XCTAssertNil(result.failure)
        XCTAssertTrue(runtime.program === player, "Looping must retain the workspace's shared player")
        XCTAssertEqual(player.volume, 0, "NDI audio must survive with local listening disabled")
        XCTAssertGreaterThan(result.blocks.count, 100)
        for (previous, next) in zip(result.blocks, result.blocks.dropFirst()) {
            XCTAssertEqual(next.sample - previous.sample, 960, "Looping must retain one continuous NDI host clock")
        }
        let boundaries = [started] + Array(result.ends.prefix(3))
        for iteration in 0..<3 {
            // Measure the middle of each iteration using PCM timestamps, so
            // delayed delivery cannot count the previous iteration's tail.
            let first = boundaries[iteration] + 9600
            let last = boundaries[iteration + 1] - 2400
            let blocks = result.blocks.filter { $0.sample >= first && $0.sample + 960 <= last }
            // Seeking at EOF need not be gapless. Require a fresh audible
            // interval after each rewind, rather than a restart deadline.
            let audible = blocks.filter { abs($0.rms - 0.05 / sqrt(2)) <= 0.0005 }
            XCTAssertGreaterThanOrEqual(audible.count, 10,
                "Iteration \(iteration + 1) must transmit at least 200 ms of fresh audio at the expected level")
        }
    }

    private func until(_ description: String, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard condition() else {
            XCTFail("Timed out: \(description)")
            throw NDIHelperWire.Failure.unavailable
        }
    }

    nonisolated private static func makeVideoWithAudio() async throws -> URL {
        let video = try await NDIRegressionTests.makePortraitVideoFixture()
        let tone = FileManager.default.temporaryDirectory.appendingPathComponent("program-loop-tone-\(UUID()).caf")
        defer {
            try? FileManager.default.removeItem(at: video)
            try? FileManager.default.removeItem(at: tone)
        }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: tone, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48000))
            pcm.frameLength = 48000
            for channel in 0..<2 { for frame in 0..<48000 {
                pcm.floatChannelData![channel][frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 48000)) * 0.05
            } }
            try file.write(from: pcm)
        }
        let composition = AVMutableComposition()
        let sources = [(AVURLAsset(url: video), AVMediaType.video), (AVURLAsset(url: tone), AVMediaType.audio)]
        defer { withExtendedLifetime(sources) {} }
        for (asset, type) in sources {
            let sourceTracks = try await asset.loadTracks(withMediaType: type)
            let source = try XCTUnwrap(sourceTracks.first)
            let track = try XCTUnwrap(composition.addMutableTrack(withMediaType: type,
                preferredTrackID: kCMPersistentTrackID_Invalid))
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1)),
                of: source, at: .zero)
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("program-loop-video-\(UUID()).mov")
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        do { try await export.export(to: url, as: .mov) }
        catch { try? FileManager.default.removeItem(at: url); throw error }
        return url
    }
}

nonisolated private final class LoopProgramAudio: @unchecked Sendable {
    struct Block { let sample: Int64; let rms: Double }
    struct Snapshot {
        var blocks: [Block] = []
        var ends: [Int64] = []
        var failure: String?
    }
    private let lock = NSLock()
    private var value = Snapshot()
    var snapshot: Snapshot { lock.withLock { value } }
    static var hostSample: Int64 {
        CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
    }
    func endIteration() { lock.withLock { value.ends.append(Self.hostSample) } }
    func fail(_ reason: String) { lock.withLock { value.failure = reason } }
    func record(_ block: NDIAudioBlock) {
        let power = block.pcm.withUnsafeBytes { bytes in
            (0..<960).reduce(0.0) { sum, frame in
                let sample = Double(bytes.loadUnaligned(fromByteOffset: frame * 4, as: Float.self))
                return sum + sample * sample
            }
        }
        lock.withLock { value.blocks.append(.init(sample: block.sampleTime, rms: sqrt(power / 960))) }
    }
}
