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
