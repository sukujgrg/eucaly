import XCTest
import Darwin
@testable import eucaly

@MainActor
final class NetworkSubmissionPacingTests: XCTestCase {
    /// Each wake receives a real finite 500 us delay, outside the SDK wrapper.
    /// A scheduler that adds ordinary lateness to every next period drifts below
    /// the unchanged cadence gate even though every individual gap is bounded.
    func testActualWorkerRetainsCadenceWithOrdinaryFiniteWakeLateness() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-video-cadence-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let process = Process(), output = Pipe()
        process.executableURL = NetworkHelperSupervisor.bundledExecutable
        process.arguments = ["--diagnose-video-cadence", directory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "EUCALY_NETWORK_VIDEO_TRACE_DIRECTORY")
        process.environment = environment
        let exited = expectation(description: "Bounded no-SDK cadence fixture exits")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        await fulfillment(of: [exited], timeout: 18)
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            XCTFail("Owned cadence fixture exceeded deadline; evidence: \(directory.path)")
            return
        }
        let diagnostic = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationReason, .exit, diagnostic)
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return }
        let data = try Data(contentsOf: directory.appendingPathComponent("cadence-report.json"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Actual worker ordinary wake-lateness cadence"; attachment.lifetime = .keepAlways; add(attachment)
        let report = try JSONDecoder().decode(CadenceReport.self, from: data)
        let traceData = try Data(contentsOf: directory.appendingPathComponent(report.traceFile))
        let traceAttachment = XCTAttachment(data: traceData, uniformTypeIdentifier: "public.json")
        traceAttachment.name = "Complete ordinary wake-lateness trace"; traceAttachment.lifetime = .keepAlways; add(traceAttachment)
        let trace = try JSONDecoder().decode(Trace.self, from: traceData)
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.requestedLiveCalls, 300)
        XCTAssertEqual(report.requestedWakeDelayNanoseconds, 500_000)
        XCTAssertTrue(report.measurementValid, report.measurementFailures.joined(separator: "; "))
        XCTAssertTrue(report.contractFailures.isEmpty, report.contractFailures.joined(separator: "; "))
        XCTAssertTrue(trace.valid, trace.invalidReasons.joined(separator: "; "))
        XCTAssertEqual(trace.overflowCount, 0)
        XCTAssertEqual(report.liveCalls, trace.expectedLiveCalls)
        XCTAssertGreaterThanOrEqual(report.liveCalls, 300)
        let live = trace.records.filter { $0.kind == "live" }
        XCTAssertEqual(live.compactMap(\.callIndex), Array(1...report.liveCalls))
        XCTAssertEqual(trace.records.filter { $0.kind == "terminal" }.count, 1)
        XCTAssertGreaterThanOrEqual(report.injectedWakeCount, live.count)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(report.minimumInjectedWakeNanoseconds), 500_000)
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.maximumInjectedWakeNanoseconds), 2_000_000)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(report.minimumEntrySpacingNanoseconds), 32_333_333,
            "Ordinary lateness must not be recovered by catch-up bursts")
        let first = try XCTUnwrap(live.first?.sdkEnteredNanoseconds)
        let last = try XCTUnwrap(live.last?.sdkEnteredNanoseconds)
        XCTAssertGreaterThan(last, first)
        guard last > first else { return }
        let actualFPS = Double(live.count - 1) * 1_000_000_000 / Double(last - first)
        XCTAssertEqual(try XCTUnwrap(report.entryFramesPerSecond), actualFPS, accuracy: 0.000001)
        XCTAssertGreaterThanOrEqual(actualFPS, 29.9,
            "Actual entry+period must not accumulate ordinary wake lateness; evidence: \(directory.path)")
    }

    /// This deliberately gates actual SDK-owner work, not a copy of the timer
    /// algorithm. The measurement-only baseline is expected to expose bursts;
    /// retained attachments establish the failure before any pacing repair.
    func testActualWorkerEntrySpacingSurvivesControlledSendAndObservationStalls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-video-pacing-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let process = Process(), output = Pipe()
        process.executableURL = NetworkHelperSupervisor.bundledExecutable
        process.arguments = ["--diagnose-video-pacing", directory.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = output
        // The standalone fixture owns its trace explicitly. Inherited live
        // diagnostic settings must not change its experiment or output path.
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "EUCALY_NETWORK_VIDEO_TRACE_DIRECTORY")
        process.environment = environment
        let exited = expectation(description: "Bounded no-SDK helper fixture exits")
        process.terminationHandler = { _ in exited.fulfill() }
        try process.run()
        await fulfillment(of: [exited], timeout: 18)
        if process.isRunning {
            // This Process was created by this test. Never locate/kill by name.
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
            XCTFail("Owned pacing fixture exceeded its hard deadline; evidence retained at \(directory.path)")
            return
        }
        let diagnostic = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationReason, .exit, diagnostic)
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { return }
        let reportURL = directory.appendingPathComponent("report.json")
        let reportData = try Data(contentsOf: reportURL)
        let attachment = XCTAttachment(data: reportData, uniformTypeIdentifier: "public.json")
        attachment.name = "Actual worker pacing report"; attachment.lifetime = .keepAlways; add(attachment)
        let report = try JSONDecoder().decode(Report.self, from: reportData)
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(Set(report.results.map(\.consumption)), ["synchronous", "borrowedUntilNextSendOrFlush"])
        XCTAssertEqual(report.results.count, 2)
        for result in report.results {
            let traceData = try Data(contentsOf: directory.appendingPathComponent(result.traceFile))
            let traceAttachment = XCTAttachment(data: traceData, uniformTypeIdentifier: "public.json")
            traceAttachment.name = "Complete wrapper trace \(result.consumption)"
            traceAttachment.lifetime = .keepAlways; add(traceAttachment)
            let trace = try JSONDecoder().decode(Trace.self, from: traceData)
            XCTAssertTrue(result.measurementValid, result.measurementFailures.joined(separator: "; "))
            XCTAssertTrue(result.contractFailures.isEmpty, result.contractFailures.joined(separator: "; "))
            XCTAssertTrue(trace.valid, trace.invalidReasons.joined(separator: "; "))
            XCTAssertEqual(trace.overflowCount, 0)
            XCTAssertEqual(trace.liveCallCount, trace.expectedLiveCalls)
            XCTAssertEqual(trace.liveCallCount, result.liveCallCount)
            XCTAssertGreaterThanOrEqual(result.liveCallCount, 16)
            XCTAssertEqual(trace.records.filter { $0.kind == "terminal" }.count, 1)
            let live = trace.records.filter { $0.kind == "live" }
            XCTAssertEqual(live.compactMap(\.callIndex), Array(1...result.liveCallCount))
            XCTAssertEqual(live.compactMap(\.contentEpoch), result.observedEpochs)
            XCTAssertTrue(live.allSatisfy { $0.consumption == result.consumption })
            XCTAssertEqual(result.audioSamples.count, 3)
            XCTAssertEqual(zip(result.audioSamples, result.audioSamples.dropFirst()).map { pair in pair.1 - pair.0 }, [960, 960])
            XCTAssertEqual(Set(result.releasedLeaseMarkers), [0xABCDEF01, 0xABCDEF02, 0xABCDEF03])
            XCTAssertEqual(Set(result.recovery.map(\.stage)), ["send", "observation"])
            // Allow only 1 ms of clock/dispatch jitter, not a second immediate
            // catch-up entry. The same unchanged criterion applies to both APIs.
            let minimum = report.periodNanoseconds - 1_000_000
            for recovery in result.recovery {
                XCTAssertGreaterThanOrEqual(recovery.entrySpacingNanoseconds, minimum,
                    "\(result.consumption) \(recovery.stage): calls \(recovery.firstCallIndex)→\(recovery.secondCallIndex) bunched; raw evidence: \(directory.path)")
            }
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.minimumLiveEntrySpacingNanoseconds), minimum,
                "Every live call must meet spacing, not just average FPS")
        }
    }

    private struct Report: Decodable {
        let schemaVersion: Int
        let periodNanoseconds: UInt64
        let results: [Result]
    }
    private struct Result: Decodable {
        let consumption: String
        let traceFile: String
        let measurementValid: Bool
        let measurementFailures: [String]
        let contractFailures: [String]
        let liveCallCount: UInt64
        let minimumLiveEntrySpacingNanoseconds: UInt64?
        let recovery: [Recovery]
        let audioSamples: [Int64]
        let observedEpochs: [UInt64]
        let releasedLeaseMarkers: [UInt32]
    }
    private struct Recovery: Decodable {
        let stage: String
        let firstCallIndex: UInt64
        let secondCallIndex: UInt64
        let entrySpacingNanoseconds: UInt64
    }
    private struct Trace: Decodable {
        let valid: Bool
        let invalidReasons: [String]
        let overflowCount: UInt64
        let liveCallCount: UInt64
        let expectedLiveCalls: UInt64
        let records: [Record]
    }
    private struct Record: Decodable {
        let kind: String
        let callIndex: UInt64?
        let contentEpoch: UInt64?
        let consumption: String?
        let sdkEnteredNanoseconds: UInt64?
    }
    private struct CadenceReport: Decodable {
        let schemaVersion: Int
        let traceFile: String
        let requestedLiveCalls: UInt64
        let liveCalls: UInt64
        let requestedWakeDelayNanoseconds: UInt64
        let injectedWakeCount: Int
        let minimumInjectedWakeNanoseconds: UInt64?
        let maximumInjectedWakeNanoseconds: UInt64?
        let minimumEntrySpacingNanoseconds: UInt64?
        let entryFramesPerSecond: Double?
        let measurementValid: Bool
        let measurementFailures: [String]
        let contractFailures: [String]
    }
}
