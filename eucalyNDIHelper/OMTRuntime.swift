import Foundation
import Security

/// Bundled OMT is loaded only in an explicitly started destination's helper.
/// Each child owns one SDK configuration, sender and bounded transport lifetime.
final class OMTRuntime {
    let handle: OpaquePointer
    private let storage: URL
    private let ownsStorage: Bool
    private var closed = false
    static let version = "OMT 1.0.0.19 (bundled)"

    init() throws {
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
            throw NDIRuntime.RuntimeError.message("The OMT helper could not isolate its runtime settings.")
        }
        var error = [CChar](repeating: 0, count: 512)
        guard let handle = eucaly_omt_open(library.path, codec.path, &error, error.count) else {
            if ownsStorage { try? FileManager.default.removeItem(at: storage) }
            throw NDIRuntime.RuntimeError.message(String(cString: error))
        }
        self.handle = handle
    }

    private static func verifyBundledLibrary(_ url: URL) throws {
        guard url.resolvingSymlinksInPath() == url.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path) else {
            throw NDIRuntime.RuntimeError.message("The bundled OMT runtime is missing or invalid. Reinstall eucaly.")
        }
        var library: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &library) == errSecSuccess, let library else {
            throw NDIRuntime.RuntimeError.message("The bundled OMT runtime could not be verified. Reinstall eucaly.")
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
            throw NDIRuntime.RuntimeError.message("The OMT helper's application signature is invalid. Reinstall eucaly.")
        }
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCheckValidity(library, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess else {
            throw NDIRuntime.RuntimeError.message("The bundled OMT runtime has an invalid application signature. Reinstall eucaly.")
        }
    }

    func close() {
        guard !closed else { return }; closed = true
        eucaly_omt_close(handle)
        if ownsStorage { try? FileManager.default.removeItem(at: storage) }
    }
    deinit { close() }
}

/// Composition, clocking, admission and ownership fences are common. Only the
/// final SDK calls and their raw-buffer lease contracts depend on technology.
enum NetworkHelperRuntime {
    case ndi(NDIRuntime), omt(OMTRuntime)

    init(technology: NetworkOutputTechnology) throws {
        switch technology {
        case .ndi: self = .ndi(try NDIRuntime())
        case .omt: self = .omt(try OMTRuntime())
        }
    }
    var version: String {
        switch self { case .ndi(let runtime): runtime.version; case .omt: OMTRuntime.version }
    }
    var borrowsVideoAfterReturn: Bool { if case .ndi = self { true } else { false } }
    var sourceName: String? {
        switch self {
        case .ndi(let runtime): eucaly_ndi_source_name(runtime.handle).map { String(cString: $0) }
        case .omt(let runtime): eucaly_omt_source_name(runtime.handle).map { String(cString: $0) }
        }
    }
    func createSender(name: String) -> Bool {
        switch self {
        case .ndi(let runtime): eucaly_ndi_create_sender(runtime.handle, name)
        case .omt(let runtime): eucaly_omt_create_sender(runtime.handle, name)
        }
    }
    var connections: Int32 {
        switch self {
        case .ndi(let runtime): eucaly_ndi_connections(runtime.handle)
        case .omt(let runtime): eucaly_omt_connections(runtime.handle)
        }
    }
    func sendVideo(_ bytes: UnsafeMutableRawPointer, format: NDIVideoPixelFormat, timecode: Int64) {
        switch self {
        case .ndi(let runtime):
            if format == .bgra {
                eucaly_ndi_send_bgra(runtime.handle, bytes, Int32(NDIHelperWire.width), Int32(NDIHelperWire.height), Int32(format.bytesPerRow), timecode)
            } else {
                eucaly_ndi_send_yuv(runtime.handle, bytes, Int32(NDIHelperWire.width), Int32(NDIHelperWire.height), Int32(format.bytesPerRow), format == .uyva, timecode)
            }
        case .omt(let runtime):
            // The SDK returns bytes offered to its bounded TCP channel pools.
            // Zero is valid with no subscribers or a full channel pool. As for
            // NDI, submission counters do not claim receiver delivery.
            _ = eucaly_omt_send_video(runtime.handle, bytes, Int32(NDIHelperWire.width), Int32(NDIHelperWire.height), Int32(format.bytesPerRow), format.rawValue, timecode)
        }
    }
    func sendAudio(_ bytes: UnsafeRawPointer, sampleTime: Int64) {
        switch self {
        case .ndi(let runtime): eucaly_ndi_send_audio(runtime.handle, bytes, sampleTime)
        case .omt(let runtime): _ = eucaly_omt_send_audio(runtime.handle, bytes, sampleTime)
        }
    }
    func flush() {
        if case .ndi(let runtime) = self { eucaly_ndi_flush(runtime.handle) }
        // omt_send consumes the raw buffer synchronously. Sender destruction
        // owns its encoded TCP queues; there is no asynchronous raw-pixel borrow.
    }
    func close() {
        switch self { case .ndi(let runtime): runtime.close(); case .omt(let runtime): runtime.close() }
    }

    #if DEBUG
    func createProbe(source: String, audioOnly: Bool) -> Bool {
        switch self {
        case .ndi(let runtime): eucaly_ndi_create_probe(runtime.handle, source, audioOnly)
        case .omt(let runtime): eucaly_omt_create_probe(runtime.handle, source, audioOnly)
        }
    }
    func probeFrame(bytes: UnsafeMutableRawPointer, capacity: Int, timecode: inout Int64) -> Int32 {
        switch self {
        case .ndi(let runtime): eucaly_ndi_probe_frame(runtime.handle, bytes, capacity, &timecode)
        case .omt(let runtime): eucaly_omt_probe_frame(runtime.handle, bytes, capacity, &timecode)
        }
    }
    func probeAudio(_ observation: inout eucaly_ndi_audio_observation) -> Int32 {
        switch self {
        case .ndi(let runtime): return eucaly_ndi_probe_audio(runtime.handle, &observation)
        case .omt(let runtime):
            var result = eucaly_omt_audio_observation()
            let status = eucaly_omt_probe_audio(runtime.handle, &result)
            observation.samples = result.samples; observation.sample_rate = result.sample_rate
            observation.timecode = result.timecode; observation.left = result.left; observation.right = result.right
            observation.left_rms = result.left_rms; observation.right_rms = result.right_rms
            observation.dropped_frames = result.dropped_frames; observation.queued_frames = result.queued_frames
            return status
        }
    }
    #endif
}
