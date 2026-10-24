import XCTest
@testable import eucaly
import CoreMedia
import CoreVideo
import IOSurface
import ScreenCaptureKit

final class WindowCapturePipelineTests: XCTestCase {
    func testFrameRateNormalizationAllowsSupportedValues() {
        XCTAssertEqual(WindowCaptureFrameRate.normalized(24), 24)
        XCTAssertEqual(WindowCaptureFrameRate.normalized(30), 30)
        XCTAssertEqual(WindowCaptureFrameRate.normalized(60), 60)
    }

    func testFrameRateNormalizationDefaultsUnsupportedValuesToSixty() {
        XCTAssertEqual(WindowCaptureFrameRate.normalized(0), 60)
        XCTAssertEqual(WindowCaptureFrameRate.normalized(15), 60)
        XCTAssertEqual(WindowCaptureFrameRate.normalized(120), 60)
    }

    @MainActor
    func testFrameRateChangesDuringStartApplyLatestOnlyAfterStartCompletes() async {
        let manager = ScreenCaptureManager(), generation = UUID()
        manager.preferredFrameRate = 30
        let applied = expectation(description: "Apply latest setting after startup")
        let probe = CaptureConfigurationProbe { rate in
            XCTAssertEqual(rate, 24); applied.fulfill()
        }
        var consumerRates: [Int] = []
        manager.frameRateUpdates.add(generation, initialFrameRate: 30,
            updateConsumers: { consumerRates.append($0) }, applyConfiguration: { try await probe.apply($0) },
            failure: { _ in XCTFail("The isolated update should succeed") })
        defer { manager.frameRateUpdates.removeAll() }
        manager.preferredFrameRate = 60
        manager.preferredFrameRate = 24
        XCTAssertEqual(consumerRates, [60, 24])
        XCTAssertTrue(probe.requested.isEmpty, "SCStream configuration must wait for startCapture to finish.")
        manager.frameRateUpdates.didStart(generation)
        await fulfillment(of: [applied], timeout: 3)
        probe.finishNext()
        let pending = manager.frameRateUpdates.remove(generation)
        await pending?.value
        XCTAssertEqual(probe.requested, [24])
    }

    @MainActor
    func testLiveFrameRateChangesSerializeAndCoalesceWithoutRestartingCapture() async {
        let manager = ScreenCaptureManager(), generation = UUID()
        manager.preferredFrameRate = 30
        let first = expectation(description: "First live configuration")
        let latest = expectation(description: "Latest live configuration")
        let probe = CaptureConfigurationProbe { rate in
            if rate == 24 { first.fulfill() }
            else { XCTAssertEqual(rate, 60); latest.fulfill() }
        }
        var consumerRates: [Int] = [], failures = 0
        manager.frameRateUpdates.add(generation, initialFrameRate: 30,
            updateConsumers: { consumerRates.append($0) }, applyConfiguration: { try await probe.apply($0) },
            failure: { _ in failures += 1 })
        defer { manager.frameRateUpdates.removeAll() }
        manager.frameRateUpdates.didStart(generation)
        manager.preferredFrameRate = 24
        await fulfillment(of: [first], timeout: 3)
        manager.preferredFrameRate = 60
        manager.preferredFrameRate = 30
        manager.preferredFrameRate = 60
        XCTAssertEqual(probe.requested, [24], "Do not enqueue work behind an in-flight update.")
        probe.finishNext(error: CaptureConfigurationProbe.Failure.rejected)
        await fulfillment(of: [latest], timeout: 3)
        XCTAssertEqual(probe.requested, [24, 60])
        XCTAssertEqual(probe.maximumPending, 1)
        XCTAssertEqual(failures, 0, "An obsolete setting's failure must not describe the new setting.")
        XCTAssertEqual(consumerRates, [24, 60, 30, 60])
        probe.finishNext()
        await manager.frameRateUpdates.remove(generation)?.value
    }

    @MainActor
    func testStoppedCaptureRejectsLateRateCompletionAndReplacementKeepsItsOwnLane() async {
        let manager = ScreenCaptureManager(), old = UUID(), replacement = UUID()
        manager.preferredFrameRate = 30
        let oldApplied = expectation(description: "Old update entered async configuration")
        let newApplied = expectation(description: "Replacement update entered async configuration")
        let oldProbe = CaptureConfigurationProbe { _ in oldApplied.fulfill() }
        let newProbe = CaptureConfigurationProbe { rate in XCTAssertEqual(rate, 24); newApplied.fulfill() }
        var oldRates: [Int] = [], newRates: [Int] = [], failures = 0
        manager.frameRateUpdates.add(old, initialFrameRate: 30,
            updateConsumers: { oldRates.append($0) }, applyConfiguration: { try await oldProbe.apply($0) },
            failure: { _ in failures += 1 })
        manager.frameRateUpdates.didStart(old)
        manager.preferredFrameRate = 60
        await fulfillment(of: [oldApplied], timeout: 3)
        let retired = manager.frameRateUpdates.remove(old)
        manager.frameRateUpdates.add(replacement, initialFrameRate: 60,
            updateConsumers: { newRates.append($0) }, applyConfiguration: { try await newProbe.apply($0) },
            failure: { _ in failures += 1 })
        manager.frameRateUpdates.didStart(replacement)
        manager.preferredFrameRate = 24
        await fulfillment(of: [newApplied], timeout: 3)
        oldProbe.finishNext(error: CaptureConfigurationProbe.Failure.rejected)
        await retired?.value
        manager.frameRateUpdates.didStart(old)
        XCTAssertEqual(oldRates, [60], "Retired generations cannot receive the replacement's frame-rate setting.")
        XCTAssertEqual(newRates, [24])
        XCTAssertEqual(oldProbe.requested, [60])
        XCTAssertEqual(failures, 0, "A stopped stream's late failure is no longer an operator error.")
        newProbe.finishNext()
        await manager.frameRateUpdates.remove(replacement)?.value
    }

    @MainActor
    func testCurrentFrameRateUpdateFailureReportsOnceAndNextChoiceCanRecover() async {
        let manager = ScreenCaptureManager(), generation = UUID()
        manager.preferredFrameRate = 30
        let rejected = expectation(description: "Rate configuration was attempted")
        let reported = expectation(description: "Current failure was reported")
        let recovered = expectation(description: "New rate was attempted")
        let probe = CaptureConfigurationProbe { rate in
            if rate == 24 { rejected.fulfill() } else { XCTAssertEqual(rate, 60); recovered.fulfill() }
        }
        var failures = 0
        manager.frameRateUpdates.add(generation, initialFrameRate: 30, updateConsumers: { _ in },
            applyConfiguration: { try await probe.apply($0) }, failure: { _ in failures += 1; reported.fulfill() })
        manager.frameRateUpdates.didStart(generation)
        manager.preferredFrameRate = 24
        await fulfillment(of: [rejected], timeout: 3)
        probe.finishNext(error: CaptureConfigurationProbe.Failure.rejected)
        await fulfillment(of: [reported], timeout: 3)
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(probe.requested, [24], "A failed configuration must not spin or retry by itself.")
        manager.preferredFrameRate = 60
        await fulfillment(of: [recovered], timeout: 3)
        probe.finishNext()
        await manager.frameRateUpdates.remove(generation)?.value
        XCTAssertEqual(failures, 1)
    }

    @MainActor
    func testLiveRateChangesReachExistingAndNewConsumersWithoutChangingMembership() async {
        let manager = ScreenCaptureManager(), generation = UUID()
        manager.preferredFrameRate = 30
        let fanout = SharedCaptureOutput(frameRate: 30)
        let one = RateAwareCaptureOutput(), two = RateAwareCaptureOutput(), three = RateAwareCaptureOutput()
        let firstID = UUID(), secondID = UUID(), thirdID = UUID()
        fanout.add(firstID, output: one); fanout.add(secondID, output: two)
        manager.frameRateUpdates.add(generation, initialFrameRate: 30,
            updateConsumers: { fanout.setFrameRate($0) }, applyConfiguration: { _ in XCTFail("Capture has not started.") },
            failure: { _ in XCTFail("Capture has not started.") })
        manager.preferredFrameRate = 24
        XCTAssertEqual(fanout.consumerCount, 2)
        XCTAssertEqual(one.rates, [30, 24]); XCTAssertEqual(two.rates, [30, 24])
        fanout.remove(firstID)
        manager.preferredFrameRate = 60
        fanout.add(thirdID, output: three)
        XCTAssertEqual(fanout.consumerCount, 2)
        XCTAssertEqual(one.rates, [30, 24])
        XCTAssertEqual(two.rates, [30, 24, 60]); XCTAssertEqual(three.rates, [60])
        manager.frameRateUpdates.removeAll()
        manager.preferredFrameRate = 30
        XCTAssertEqual(two.rates, [30, 24, 60], "Stopped configuration lanes cannot publish late gate updates.")
        XCTAssertEqual(fanout.consumerCount, 2, "Frame-rate teardown does not own consumer membership.")
        fanout.removeAll()
    }

    func testValidTimestampGateAcceptsFirstFrameAndDropsFramesInsideInterval() {
        var gate = WindowCaptureFrameGate(frameRate: 30)

        XCTAssertTrue(
            gate.shouldAcceptFrame(
                at: .zero,
                fallbackUptimeNanoseconds: 0
            )
        )
        XCTAssertFalse(
            gate.shouldAcceptFrame(
                at: CMTime(value: 1, timescale: 60),
                fallbackUptimeNanoseconds: 0
            )
        )
        XCTAssertTrue(
            gate.shouldAcceptFrame(
                at: CMTime(value: 1, timescale: 30),
                fallbackUptimeNanoseconds: 0
            )
        )
    }

    func testFrameRateUpdateChangesIntervalAndResetsPriorState() {
        var gate = WindowCaptureFrameGate(frameRate: 30)

        XCTAssertTrue(
            gate.shouldAcceptFrame(
                at: .zero,
                fallbackUptimeNanoseconds: 0
            )
        )
        XCTAssertFalse(
            gate.shouldAcceptFrame(
                at: CMTime(value: 1, timescale: 60),
                fallbackUptimeNanoseconds: 0
            )
        )

        gate.updateFrameRate(60)

        XCTAssertTrue(
            gate.shouldAcceptFrame(
                at: CMTime(value: 1, timescale: 60),
                fallbackUptimeNanoseconds: 0
            )
        )
        XCTAssertFalse(
            gate.shouldAcceptFrame(
                at: CMTime(value: 1, timescale: 120),
                fallbackUptimeNanoseconds: 0
            )
        )
    }

    func testInvalidTimestampGateUsesFallbackUptime() {
        var gate = WindowCaptureFrameGate(frameRate: 60)

        XCTAssertTrue(
            gate.shouldAcceptFrame(
                at: .invalid,
                fallbackUptimeNanoseconds: 1_000
            )
        )
        XCTAssertFalse(
            gate.shouldAcceptFrame(
                at: .invalid,
                fallbackUptimeNanoseconds: 10_001_000
            )
        )
        XCTAssertTrue(
            gate.shouldAcceptFrame(
                at: .invalid,
                fallbackUptimeNanoseconds: 17_001_000
            )
        )
    }

    func testCommitGenerationRejectsStaleCommitsAfterAdvance() {
        var generation = WindowCaptureCommitGeneration()
        let staleGeneration = generation.current

        XCTAssertTrue(generation.allowsCommit(staleGeneration))

        generation.advance()

        XCTAssertFalse(generation.allowsCommit(staleGeneration))
        XCTAssertTrue(generation.allowsCommit(generation.current))
    }

    func testCompleteFrameUsesOriginalCaptureSurface() throws {
        let buffer = try makePixelBuffer()
        let sample = try makeSampleBuffer(pixelBuffer: buffer)
        let originalSurface = try XCTUnwrap(CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue())
        let frame = try XCTUnwrap(WindowCaptureFrame(sampleBuffer: sample))

        XCTAssertEqual(frame.surface.surfaceID, IOSurfaceGetID(originalSurface))
        XCTAssertEqual(frame.surface.width, CVPixelBufferGetWidth(buffer))
        XCTAssertEqual(frame.surface.height, CVPixelBufferGetHeight(buffer))
    }

    func testIncompleteAndUnclassifiedFramesAreIgnored() throws {
        let buffer = try makePixelBuffer()
        let statuses: [SCFrameStatus?] = [.idle, .blank, .suspended, .started, .stopped, nil]

        for status in statuses {
            let sample = try makeSampleBuffer(pixelBuffer: buffer, status: status)
            XCTAssertNil(WindowCaptureFrame(sampleBuffer: sample), "Status: \(String(describing: status))")
        }
    }

    func testInvalidSampleBufferIsIgnored() throws {
        let sample = try makeSampleBuffer(pixelBuffer: makePixelBuffer())
        CMSampleBufferInvalidate(sample)

        XCTAssertNil(WindowCaptureFrame(sampleBuffer: sample))
    }

    func testFrameWithoutSurfaceIsIgnored() throws {
        let buffer = try makePixelBuffer(surfaceBacked: false)
        XCTAssertNil(CVPixelBufferGetIOSurface(buffer))
        let sample = try makeSampleBuffer(pixelBuffer: buffer)

        XCTAssertNil(WindowCaptureFrame(sampleBuffer: sample))
    }

    @MainActor
    func testQueuedAndDisplayedFrameKeepPooledBufferAliveUntilCleared() throws {
        var pool: CVPixelBufferPool?
        XCTAssertEqual(
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelBufferAttributes as CFDictionary, &pool),
            kCVReturnSuccess
        )
        let capturePool = try XCTUnwrap(pool)
        let allocationLimit = [kCVPixelBufferPoolAllocationThresholdKey: 1] as CFDictionary

        var frame: WindowCaptureFrame? = try autoreleasepool {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(
                CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                    kCFAllocatorDefault, capturePool, allocationLimit, &buffer
                ),
                kCVReturnSuccess
            )
            let sample = try makeSampleBuffer(pixelBuffer: XCTUnwrap(buffer))
            return try XCTUnwrap(WindowCaptureFrame(sampleBuffer: sample))
        }
        XCTAssertNotNil(frame)

        var nextBuffer: CVPixelBuffer?
        withExtendedLifetime(frame) {
            XCTAssertEqual(
                CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                    kCFAllocatorDefault, capturePool, allocationLimit, &nextBuffer
                ),
                kCVReturnWouldExceedAllocationThreshold
            )
        }

        let view = WindowCaptureLayerHostView(frame: .zero)
        view.displayFrame(try XCTUnwrap(frame))
        frame = nil
        XCTAssertEqual(
            CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault, capturePool, allocationLimit, &nextBuffer
            ),
            kCVReturnWouldExceedAllocationThreshold
        )

        view.clearFrame()
        XCTAssertEqual(
            CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
                kCFAllocatorDefault, capturePool, allocationLimit, &nextBuffer
            ),
            kCVReturnSuccess
        )
    }

    @MainActor
    func testLayerDisplaysSurfaceAndClearsIt() throws {
        let sample = try makeSampleBuffer(pixelBuffer: makePixelBuffer())
        let frame = try XCTUnwrap(WindowCaptureFrame(sampleBuffer: sample))
        let view = WindowCaptureLayerHostView(frame: .zero)

        view.displayFrame(frame)

        let displayedSurface = try XCTUnwrap(view.layer?.contents as? IOSurface)
        XCTAssertEqual(displayedSurface.surfaceID, frame.surface.surfaceID)
        XCTAssertEqual(view.layer?.contentsGravity, .resizeAspect)
        XCTAssertTrue(view.layer?.animationKeys()?.isEmpty ?? true)

        view.clearFrame()
        XCTAssertNil(view.layer?.contents)
    }

    private var pixelBufferAttributes: [CFString: Any] {
        [
            kCVPixelBufferWidthKey: 16,
            kCVPixelBufferHeightKey: 8,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]
        ]
    }

    private func makePixelBuffer(surfaceBacked: Bool = true) throws -> CVPixelBuffer {
        var attributes = pixelBufferAttributes
        if !surfaceBacked {
            attributes.removeValue(forKey: kCVPixelBufferIOSurfacePropertiesKey)
        }
        var buffer: CVPixelBuffer?
        XCTAssertEqual(
            CVPixelBufferCreate(
                kCFAllocatorDefault, 16, 8, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
            ),
            kCVReturnSuccess
        )
        return try XCTUnwrap(buffer)
    }

    private func makeSampleBuffer(
        pixelBuffer: CVPixelBuffer,
        status: SCFrameStatus? = .complete
    ) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        XCTAssertEqual(
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &format
            ),
            noErr
        )
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 60),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        XCTAssertEqual(
            CMSampleBufferCreateReadyWithImageBuffer(
                allocator: kCFAllocatorDefault,
                imageBuffer: pixelBuffer,
                formatDescription: try XCTUnwrap(format),
                sampleTiming: &timing,
                sampleBufferOut: &sample
            ),
            noErr
        )
        let sampleBuffer = try XCTUnwrap(sample)
        if let status {
            let attachments = try XCTUnwrap(
                CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true)
            ) as NSArray
            let frameInfo = try XCTUnwrap(attachments.firstObject as? NSMutableDictionary)
            frameInfo[SCStreamFrameInfo.status.rawValue] = status.rawValue
        }
        return sampleBuffer
    }
}

@MainActor
private final class CaptureConfigurationProbe {
    enum Failure: Error { case rejected }
    private let onRequest: (Int) -> Void
    private var pending: [CheckedContinuation<Void, Error>] = []
    private(set) var requested: [Int] = []
    private(set) var maximumPending = 0

    init(onRequest: @escaping (Int) -> Void) { self.onRequest = onRequest }

    func apply(_ frameRate: Int) async throws {
        requested.append(frameRate)
        try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
            maximumPending = max(maximumPending, pending.count)
            onRequest(frameRate)
        }
    }

    func finishNext(error: Error? = nil) {
        guard !pending.isEmpty else { XCTFail("No configuration is pending"); return }
        let continuation = pending.removeFirst()
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }
}

nonisolated private final class RateAwareCaptureOutput: NSObject, SCStreamOutput, WindowCaptureFrameRateConsumer, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    var rates: [Int] { lock.withLock { values } }
    func setFrameRate(_ frameRate: Int) { lock.withLock { values.append(frameRate) } }
}
