import XCTest
@testable import eucaly

final class OMTVideoObservationTests: XCTestCase {
    func testExactCallSurvivesPeerOffAndOwnershipChangeWithoutClaimingDelivery() throws {
        var history = OMTVideoSDKDiagnostics()
        let rejected = call(7, epoch: 1, bytes: 0, beforeDrop: 0, afterDrop: 1)
        history.record(rejected)
        for index in 8...100 { history.record(call(UInt64(index), epoch: 2, bytes: 0, connections: 0)) }
        XCTAssertEqual(history.firstDropCounterIncreases.first?.timecode, rejected.timecode)
        XCTAssertEqual(history.firstDropCounterIncreases.first?.startedNanoseconds, rejected.startedNanoseconds)
        XCTAssertEqual(history.firstDropCounterIncreases.first?.finishedNanoseconds, rejected.finishedNanoseconds)
        XCTAssertEqual(history.firstDropCounterIncreases.first?.contentEpoch, 1)
        XCTAssertEqual(history.lastCall?.contentEpoch, 2)
        XCTAssertEqual(history.lastCall?.callIndex, 100)
        XCTAssertEqual(history.recentZeroReturnsWithConnections.count, 1)
        XCTAssertTrue(history.isValid)
        let decoded = try JSONDecoder().decode(OMTVideoSDKDiagnostics.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(decoded.firstDropCounterIncreases.first?.generation, rejected.generation)
        XCTAssertEqual(decoded.recentDropCounterIncreases.first?.returnedBytes, 0)
        XCTAssertTrue(decoded.isValid)
    }

    func testFirstAndRecentSetsAreBoundedAndPreserveTheFirstExactException() {
        var history = OMTVideoSDKDiagnostics()
        for index in 1...100 {
            history.record(call(UInt64(index), bytes: 0, beforeDrop: Int64(index-1), afterDrop: Int64(index)))
        }
        XCTAssertEqual(history.firstZeroReturnsWithConnections.map(\.callIndex), [1, 2, 3, 4])
        XCTAssertEqual(history.recentZeroReturnsWithConnections.map(\.callIndex), [97, 98, 99, 100])
        XCTAssertEqual(history.firstDropCounterIncreases.map(\.callIndex), [1, 2, 3, 4])
        XCTAssertEqual(history.recentDropCounterIncreases.map(\.callIndex), [97, 98, 99, 100])
        XCTAssertTrue(history.isValid)
        history.firstDropCounterIncreases.append(call(101, bytes: 0, beforeDrop: 100, afterDrop: 101))
        XCTAssertFalse(history.isValid, "Decoded status must enforce retention bounds too")
    }

    func testHandshakeZerosChannelResetAndPositiveReturnKeepTheirObservedMeaning() {
        var history = OMTVideoSDKDiagnostics()
        history.record(call(1, bytes: 0, connections: 0))
        XCTAssertTrue(history.firstZeroReturnsWithConnections.isEmpty)
        history.record(call(2, bytes: 0, beforeDrop: 0, afterDrop: 0))
        XCTAssertEqual(history.firstZeroReturnsWithConnections.count, 1, "An audio-only/handshaking connection stays ambiguous")
        XCTAssertTrue(history.firstDropCounterIncreases.isEmpty)
        history.record(call(3, bytes: 7720, beforeDrop: 4, afterDrop: 0))
        XCTAssertTrue(history.firstDropCounterIncreases.isEmpty, "A channel reset is not a new rejection")
        history.record(call(4, bytes: 7720, beforeDrop: 0, afterDrop: 1))
        XCTAssertEqual(history.firstDropCounterIncreases.first?.returnedBytes, 7720,
            "Generic channel counters can change even when this call returns positive")
        XCTAssertEqual(history.firstZeroReturnsWithConnections.count, 1)
        XCTAssertTrue(history.isValid)
    }

    func testStatusRejectsInvalidTimingFormatOrGenerationAndOldStatusDecodesWithoutDiagnostics() throws {
        var history = OMTVideoSDKDiagnostics()
        history.record(call(1, bytes: 0, beforeDrop: 0, afterDrop: 1))
        var status = NetworkHelperStatus()
        status.omtVideoDiagnostics = history
        XCTAssertTrue(status.validMetrics)
        let encoded = try JSONEncoder().encode(NetworkHelperStatus())
        let old = try JSONDecoder().decode(NetworkHelperStatus.self, from: encoded)
        XCTAssertNil(old.omtVideoDiagnostics)
        history.lastCall?.finishedNanoseconds = 1
        status.omtVideoDiagnostics = history
        XCTAssertFalse(status.validMetrics)
        history.lastCall = call(2, bytes: 7720)
        history.lastCall?.rawByteCount = 1
        XCTAssertFalse(history.isValid)
        history.lastCall = call(2, bytes: 7720)
        history.lastCall?.generation = UUID()
        XCTAssertFalse(history.isValid)
    }

    private func call(_ index: UInt64, epoch: UInt64 = 1, bytes: Int32, connections: Int = 2,
                      beforeDrop: Int64 = 0, afterDrop: Int64 = 0) -> OMTVideoSDKCallObservation {
        let generation = UUID(uuidString: "00B0D806-E8B3-49A5-91F1-95051CB784B8")!
        let timecode = Int64(index * 333333)
        return .init(generation: generation, contentEpoch: epoch, callIndex: index, timecode: timecode,
            startedNanoseconds: UInt64(timecode) * 100, finishedNanoseconds: UInt64(timecode) * 100 + 1000000,
            format: .uyvy, rawByteCount: NetworkVideoPixelFormat.uyvy.byteCount, returnedBytes: bytes,
            connectionsAfter: connections, previousConnections: connections, previousTimecode: timecode-333333,
            previousStatistics: .init(framesEnqueued: Int64(index-1), framesDropped: beforeDrop,
                bytesEnqueued: 0, codecMilliseconds: 0, zeroReturnCalls: 0),
            statistics: .init(framesEnqueued: Int64(index), framesDropped: afterDrop,
                bytesEnqueued: 0, codecMilliseconds: 0, zeroReturnCalls: bytes == 0 ? 1 : 0))
    }
}
