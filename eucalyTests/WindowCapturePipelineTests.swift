import XCTest
@testable import eucaly
import CoreMedia

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
}
