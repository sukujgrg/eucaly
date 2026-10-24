import Foundation
import Security

/// Only this helper target can load NDI. Constructors in the main app never do.
final class NDIRuntime: NetworkRuntimeAdapter {
    private let handle: OpaquePointer
    private var closed = false
    var version: String { String(cString: eucaly_ndi_version(handle)) }

    init() throws {
        let paths = NDIRuntimeInstallation.searchPaths.filter { FileManager.default.fileExists(atPath: $0) }
        guard let path = paths.first else {
            throw NetworkHelperError.message("Install the macOS NDI runtime to enable this output.")
        }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var code: SecStaticCode?, requirement: SecRequirement?
        let expression = "anchor apple generic and identifier \"libndi\" and certificate leaf[subject.OU] = \"W8U66ET244\""
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw NetworkHelperError.message("The installed NDI runtime has an unrecognized or invalid signature. Reinstall it from NDI.")
        }
        var error = [CChar](repeating: 0, count: 256)
        guard let handle = eucaly_ndi_open(url.path, &error, error.count) else {
            throw NetworkHelperError.message(String(cString: error))
        }
        self.handle = handle
    }

    var sourceName: String? { eucaly_ndi_source_name(handle).map { String(cString: $0) } }
    var videoConsumption: NetworkVideoConsumption { .borrowedUntilNextSendOrFlush }

    func createSender(name: String) -> Bool { eucaly_ndi_create_sender(handle, name) }

    func sendVideo(_ bytes: UnsafeMutableRawPointer, format: NetworkVideoPixelFormat, timecode: Int64) -> Int32? {
        if format == .bgra {
            eucaly_ndi_send_bgra(handle, bytes, Int32(NetworkHelperWire.width), Int32(NetworkHelperWire.height),
                                Int32(format.bytesPerRow), timecode)
        } else {
            eucaly_ndi_send_yuv(handle, bytes, Int32(NetworkHelperWire.width), Int32(NetworkHelperWire.height),
                               Int32(format.bytesPerRow), format == .uyva, timecode)
        }
        return nil // NDI's asynchronous API supplies no enqueue result.
    }

    func videoSubmissionObservation(_ context: NetworkVideoSubmissionContext) -> NetworkVideoSubmissionObservation {
        .init(connections: max(0, Int(eucaly_ndi_connections(handle))))
    }

    func sendAudio(_ bytes: UnsafeRawPointer, sampleTime: Int64) -> Int32? {
        eucaly_ndi_send_audio(handle, bytes, sampleTime)
        return nil // NDI's void API supplies no enqueue/delivery result.
    }

    func audioSubmissionObservation() -> (any NetworkTransportStatusObservation)? { nil }
    func flush() { eucaly_ndi_flush(handle) }

    #if DEBUG
    func createProbe(source: String, audioOnly: Bool) -> Bool {
        eucaly_ndi_create_probe(handle, source, audioOnly)
    }

    func probeFrame(bytes: UnsafeMutableRawPointer, capacity: Int) -> NetworkProbeResult<Int64> {
        var timecode: Int64 = 0
        let result = eucaly_ndi_probe_frame(handle, bytes, capacity, &timecode)
        if result > 0 { return .received(timecode) }
        return result == 0 ? .pending : .invalid
    }

    func probeAudio() -> NetworkProbeResult<NetworkAudioObservation> {
        var result = eucaly_ndi_audio_observation()
        let status = eucaly_ndi_probe_audio(handle, &result)
        let receivedAt = DispatchTime.now().uptimeNanoseconds
        guard status > 0 else { return status == 0 ? .pending : .invalid }
        return .received(.init(samples: Int(result.samples), sampleRate: Int(result.sample_rate),
            timecode: result.timecode, receivedAtNanoseconds: receivedAt, left: result.left, right: result.right,
            leftRMS: result.left_rms, rightRMS: result.right_rms,
            droppedFrames: result.dropped_frames, queuedFrames: Int(result.queued_frames)))
    }
    #endif

    // Destruction can block in the SDK. The owner confines it to its worker;
    // the supervisor can terminate this entire process within a finite deadline.
    func close() {
        guard !closed else { return }; closed = true
        eucaly_ndi_close(handle)
    }
    deinit { close() }
}
