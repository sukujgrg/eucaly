@preconcurrency import AVFoundation
import VideoToolbox
import XCTest
@testable import eucaly

/// Machine-specific input diagnostic, using only the explicitly supplied copies.
/// It exercises the shared sampler without starting a helper or network output.
@MainActor
final class NetworkProductionInputTests: XCTestCase {
    func testSuppliedAV1AndH264ThroughSampler() async throws {
        guard ProcessInfo.processInfo.environment["EUCALY_OMT_PRODUCTION_INPUTS"] == "1" else {
            throw XCTSkip("Set EUCALY_OMT_PRODUCTION_INPUTS=1 to check the supplied AV1/H264 files on this Mac.")
        }
        let directory = URL(fileURLWithPath: "/tmp/videosfortst", isDirectory: true)
        let av1 = directory.appendingPathComponent("Big_Buck_Bunny_1080_10s_5MB_av1.mp4")
        let h264 = directory.appendingPathComponent("Big_Buck_Bunny_1080_10s_5MB_h264.mp4")
        for url in [av1, h264] {
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                XCTFail("The explicitly requested input is missing or unreadable: \(url.path)")
                throw ProbeFailure.missingInput
            }
        }
        // Native AV1 is hardware-only. Unsupported hosts must fail immediately;
        // M3+ must advance frames through the shared AVPlayerVideoOutput sampler.
        try await probe(av1, expectsDecoderFailure: !VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
        try await probe(h264, expectsDecoderFailure: false)
    }

    private func probe(_ url: URL, expectsDecoderFailure: Bool) async throws {
        let player = AVPlayer(url: url)
        player.isMuted = true
        player.volume = 0
        player.allowsExternalPlayback = false
        let item = try XCTUnwrap(player.currentItem)
        let pool = NetworkSharedVideoFrames(), lease = pool.acquire(player)
        defer {
            player.pause()
            lease.release()
            pool.stop()
            player.replaceCurrentItem(with: nil)
        }
        XCTAssertEqual(pool.sourceCount, 1)
        player.play()
        let started = ProcessInfo.processInfo.systemUptime, deadline = started + 8
        var decodedFrames = 0
        var previousFrame: NetworkFrameResource?
        var firstMediaTime: Double?, lastMediaTime = 0.0
        var decoderFailed = false
        while ProcessInfo.processInfo.systemUptime < deadline {
            do {
                let frame = try await Task.detached(priority: .userInitiated) { try lease.latest() }.value
                if let frame, frame !== previousFrame {
                    decodedFrames += 1
                    previousFrame = frame
                    XCTAssertNotNil(frame.pixelBuffer)
                    XCTAssertTrue(frame.input.matches(frame.surface))
                    firstMediaTime = firstMediaTime ?? player.currentTime().seconds
                }
            } catch {
                guard expectsDecoderFailure,
                      let failure = error as? NetworkVideoFrameSource.Failure,
                      case .decoder = failure else { throw error }
                decoderFailed = true
                break
            }
            let time = player.currentTime().seconds
            if time.isFinite { lastMediaTime = max(lastMediaTime, time) }
            if !expectsDecoderFailure, decodedFrames >= 8,
               let firstMediaTime, lastMediaTime > firstMediaTime + 0.1 { break }
            try await Task.sleep(for: .milliseconds(33))
        }

        XCTAssertTrue(player.isMuted)
        XCTAssertEqual(player.volume, 0)
        if expectsDecoderFailure {
            XCTAssertTrue(decoderFailed, "Unsupported AV1 must report decoder failure promptly")
            XCTAssertEqual(decodedFrames, 0, "Unsupported AV1 must not masquerade as a decoded picture")
        } else {
            XCTAssertEqual(item.status, .readyToPlay)
            XCTAssertGreaterThan(lastMediaTime, 0.1, "The native player must actually advance before interpreting sampler results")
            XCTAssertFalse(decoderFailed)
            XCTAssertGreaterThanOrEqual(decodedFrames, 8, "Supported video must acquire new decoded resources, beyond the cached first picture")
            XCTAssertGreaterThan(lastMediaTime, (firstMediaTime ?? lastMediaTime) + 0.1)
        }
        print("OMT input \(url.lastPathComponent): frames=\(decodedFrames), decoderFailure=\(decoderFailed), mediaSeconds=\(lastMediaTime), elapsed=\(ProcessInfo.processInfo.systemUptime - started), muted=\(player.isMuted), av1HW=\(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))")

        // Release the exact lease and verify asynchronous output detachment.
        player.pause()
        lease.release()
        pool.stop()
        let cleanupDeadline = ProcessInfo.processInfo.systemUptime + 2
        while player.videoOutput != nil, ProcessInfo.processInfo.systemUptime < cleanupDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(pool.sourceCount, 0)
        XCTAssertNil(player.videoOutput)
        XCTAssertNil(try lease.latest(), "A retired lease must reject late sampling without rethrowing its prior decoder failure")
    }

    private enum ProbeFailure: Error { case missingInput }
}
