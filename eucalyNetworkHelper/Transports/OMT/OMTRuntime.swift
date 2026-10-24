import Foundation
import Security

/// Bundled OMT is loaded only in an explicitly started destination's helper.
/// Each child owns one SDK configuration, sender and bounded transport lifetime.
final class OMTRuntime: NetworkRuntimeAdapter {
    private let handle: OpaquePointer
    private let storage: URL
    private let ownsStorage: Bool
    private var closed = false
    private static let runtimeVersion = "OMT 1.0.0.19+eucaly.1 (bundled)"
    // These observations and the bounded opt-in history belong exclusively to
    // this adapter's SDK-video lane, independently of the SDK-audio reader.
    private var diagnosticGeneration: UUID?
    private var videoDiagnostics: OMTVideoSDKDiagnostics?
    private var previousVideoStatistics: OMTVideoSDKStatistics?
    private var previousVideoConnections: Int?
    private var previousVideoTimecode: Int64?

    init(generation: UUID? = nil) throws {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let directory = executable.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Frameworks/OMT", isDirectory: true)
        let library = directory.appendingPathComponent("libomt.dylib")
        let codec = directory.appendingPathComponent("libvmx.dylib")
        try Self.verifyBundledLibrary(library)
        try Self.verifyBundledLibrary(codec)
        if let parentStorage = ProcessInfo.processInfo.environment["EUCALY_OMT_STORAGE_PATH"], !parentStorage.isEmpty {
            storage = URL(fileURLWithPath: parentStorage, isDirectory: true)
            ownsStorage = false
        } else {
            storage = FileManager.default.temporaryDirectory.appendingPathComponent("com.suku.eucaly.omt.\(UUID().uuidString)", isDirectory: true)
            ownsStorage = true
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        // Set before dlopen: NativeAOT/library initialization must not consult
        // another application's ~/.OMT preferences or create operator files.
        guard setenv("OMT_STORAGE_PATH", storage.path, 1) == 0 else {
            if ownsStorage { try? FileManager.default.removeItem(at: storage) }
            throw NetworkHelperError.message("The OMT helper could not isolate its runtime settings.")
        }
        var error = [CChar](repeating: 0, count: 512)
        guard let handle = eucaly_omt_open(library.path, codec.path, &error, error.count) else {
            if ownsStorage { try? FileManager.default.removeItem(at: storage) }
            throw NetworkHelperError.message(String(cString: error))
        }
        self.handle = handle
        #if DEBUG
        if let generation, ProcessInfo.processInfo.environment["EUCALY_OMT_VIDEO_DIAGNOSTICS"] == "1" {
            diagnosticGeneration = generation
            videoDiagnostics = .init()
        }
        #endif
    }

    private static func verifyBundledLibrary(_ url: URL) throws {
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw NetworkHelperError.message("The bundled OMT runtime is missing or invalid. Reinstall eucaly.")
        }
        var library: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &library) == errSecSuccess, let library else {
            throw NetworkHelperError.message("The bundled OMT runtime could not be verified. Reinstall eucaly.")
        }
        var ownCode: SecCode?, staticCode: SecStaticCode?, info: CFDictionary?
        SecCodeCopySelf([], &ownCode)
        if let ownCode { SecCodeCopyStaticCode(ownCode, [], &staticCode) }
        if let staticCode { SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) }
        let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
        #if DEBUG
        if team == nil { return } // make test builds the app/helper unsigned.
        #endif
        guard let team, team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
            throw NetworkHelperError.message("The OMT helper's application signature is invalid. Reinstall eucaly.")
        }
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(library, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw NetworkHelperError.message("The bundled OMT runtime has an invalid application signature. Reinstall eucaly.")
        }
    }

    var version: String { Self.runtimeVersion }
    var sourceName: String? { eucaly_omt_source_name(handle).map { String(cString: $0) } }
    var videoConsumption: NetworkVideoConsumption { .synchronous }

    func createSender(name: String) -> Bool { eucaly_omt_create_sender(handle, name) }

    func sendVideo(_ bytes: UnsafeMutableRawPointer, format: NetworkVideoPixelFormat, timecode: Int64) -> Int32? {
        // Zero is valid with no subscribers or a full bounded channel pool.
        // This is an enqueue observation, not decoded receiver delivery.
        eucaly_omt_send_video(handle, bytes, Int32(NetworkHelperWire.width), Int32(NetworkHelperWire.height),
                             Int32(format.bytesPerRow), format.rawValue, timecode)
    }

    func videoSubmissionObservation(_ context: NetworkVideoSubmissionContext) -> NetworkVideoSubmissionObservation {
        let connections = max(0, Int(eucaly_omt_connections(handle)))
        var value = eucaly_omt_video_statistics()
        eucaly_omt_get_video_statistics(handle, &value)
        let statistics = OMTVideoSDKStatistics(framesEnqueued: value.frames_enqueued, framesDropped: value.frames_dropped,
            bytesEnqueued: value.bytes_enqueued, codecMilliseconds: value.codec_milliseconds,
            zeroReturnCalls: value.zero_return_calls)
        if let generation = diagnosticGeneration, let returnedBytes = context.returnedBytes {
            videoDiagnostics?.record(.init(generation: generation, contentEpoch: context.contentEpoch,
                callIndex: context.callIndex, timecode: context.timecode,
                startedNanoseconds: context.startedNanoseconds, finishedNanoseconds: context.finishedNanoseconds,
                format: context.format, rawByteCount: context.format.byteCount, returnedBytes: returnedBytes,
                connectionsAfter: connections, previousConnections: previousVideoConnections,
                previousTimecode: previousVideoTimecode, previousStatistics: previousVideoStatistics, statistics: statistics))
        }
        previousVideoStatistics = statistics
        previousVideoConnections = connections
        previousVideoTimecode = context.timecode
        return .init(connections: connections,
                     transport: OMTVideoStatusObservation(statistics: statistics, diagnostics: videoDiagnostics))
    }

    func sendAudio(_ bytes: UnsafeRawPointer, sampleTime: Int64) -> Int32? {
        eucaly_omt_send_audio(handle, bytes, sampleTime)
    }

    func audioSubmissionObservation() -> (any NetworkTransportStatusObservation)? {
        var value = eucaly_omt_audio_statistics()
        eucaly_omt_get_audio_statistics(handle, &value)
        return OMTAudioStatusObservation(statistics: .init(framesEnqueued: value.frames_enqueued,
            framesDropped: value.frames_dropped, bytesEnqueued: value.bytes_enqueued,
            sendCalls: value.send_calls, zeroReturnCalls: value.zero_return_calls,
            positiveReturnCalls: value.positive_return_calls, bytesReturned: value.bytes_returned))
    }

    func flush() {
        // omt_send consumes raw pixels synchronously. Encoded TCP queues belong
        // to sender destruction; there is no outstanding raw-pixel borrow.
    }

    #if DEBUG
    func createProbe(source: String, audioOnly: Bool) -> Bool {
        eucaly_omt_create_probe(handle, source, audioOnly)
    }

    func probeFrame(bytes: UnsafeMutableRawPointer, capacity: Int) -> NetworkProbeResult<Int64> {
        var timecode: Int64 = 0
        let result = eucaly_omt_probe_frame(handle, bytes, capacity, &timecode)
        if result > 0 { return .received(timecode) }
        return result == 0 ? .pending : .invalid
    }

    func probeAudio() -> NetworkProbeResult<NetworkAudioObservation> {
        var result = eucaly_omt_audio_observation()
        let status = eucaly_omt_probe_audio(handle, &result)
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        guard status > 0 else { return status == 0 ? .pending : .invalid }
        return .received(.init(samples: Int(result.samples), sampleRate: Int(result.sample_rate),
            timecode: result.timecode, receivedAtNanoseconds: receivedAt, left: result.left, right: result.right,
            leftRMS: result.left_rms, rightRMS: result.right_rms,
            droppedFrames: result.dropped_frames, queuedFrames: Int(result.queued_frames)))
    }
    #endif

    func close() {
        guard !closed else { return }; closed = true
        eucaly_omt_close(handle)
        if ownsStorage { try? FileManager.default.removeItem(at: storage) }
    }
    deinit { close() }
}

private struct OMTVideoStatusObservation: NetworkTransportStatusObservation {
    let statistics: OMTVideoSDKStatistics
    let diagnostics: OMTVideoSDKDiagnostics?

    func apply(to status: inout NetworkHelperStatus) {
        status.omtVideoStatistics = statistics
        status.omtVideoDiagnostics = diagnostics
    }
}

private struct OMTAudioStatusObservation: NetworkTransportStatusObservation {
    let statistics: OMTAudioSDKStatistics

    func apply(to status: inout NetworkHelperStatus) {
        status.omtAudioStatistics = statistics
    }
}
