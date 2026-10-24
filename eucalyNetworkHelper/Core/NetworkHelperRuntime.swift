import Foundation

/// Select exactly one independent adapter for this helper process. Rendering,
/// admission and ownership live above this boundary; vendor APIs live below it.
enum NetworkHelperRuntime {
    case ndi(NDIRuntime)
    case omt(OMTRuntime)

    init(technology: NetworkOutputTechnology, generation: UUID? = nil) throws {
        switch technology {
        case .ndi: self = .ndi(try NDIRuntime())
        case .omt: self = .omt(try OMTRuntime(generation: generation))
        }
    }

    private var adapter: any NetworkRuntimeAdapter {
        switch self {
        case .ndi(let runtime): runtime
        case .omt(let runtime): runtime
        }
    }

    var version: String { adapter.version }
    var sourceName: String? { adapter.sourceName }
    var videoConsumption: NetworkVideoConsumption { adapter.videoConsumption }

    func createSender(name: String) -> Bool { adapter.createSender(name: name) }

    @discardableResult
    func sendVideo(_ bytes: UnsafeMutableRawPointer, format: NetworkVideoPixelFormat, timecode: Int64) -> Int32? {
        adapter.sendVideo(bytes, format: format, timecode: timecode)
    }

    func videoSubmissionObservation(_ context: NetworkVideoSubmissionContext) -> NetworkVideoSubmissionObservation {
        adapter.videoSubmissionObservation(context)
    }

    func sendAudio(_ bytes: UnsafeRawPointer, sampleTime: Int64) -> Int32? {
        adapter.sendAudio(bytes, sampleTime: sampleTime)
    }

    func audioSubmissionObservation() -> (any NetworkTransportStatusObservation)? {
        adapter.audioSubmissionObservation()
    }

    func flush() { adapter.flush() }
    func close() { adapter.close() }

    #if DEBUG
    func createProbe(source: String, audioOnly: Bool) -> Bool {
        adapter.createProbe(source: source, audioOnly: audioOnly)
    }

    func probeFrame(bytes: UnsafeMutableRawPointer, capacity: Int) -> NetworkProbeResult<Int64> {
        adapter.probeFrame(bytes: bytes, capacity: capacity)
    }

    func probeAudio() -> NetworkProbeResult<NetworkAudioObservation> { adapter.probeAudio() }
    #endif
}
