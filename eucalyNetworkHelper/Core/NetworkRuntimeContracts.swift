import Foundation

/// The raw-pixel lifetime is an SDK contract, independent of encoded network
/// queues. A synchronous consumer releases its borrow before the call returns.
enum NetworkVideoConsumption: Sendable {
    case synchronous
    case borrowedUntilNextSendOrFlush
}

/// Context captured by the common video lane. Adapters can attach their own
/// observations without owning the destination clock, epochs or call ordering.
struct NetworkVideoSubmissionContext: Sendable {
    let contentEpoch: UInt64
    let callIndex: UInt64
    let timecode: Int64
    let startedNanoseconds: UInt64
    let finishedNanoseconds: UInt64
    let format: NetworkVideoPixelFormat
    let returnedBytes: Int32?
}

/// An immutable adapter snapshot. Applying it only copies data into the wire
/// report; it must never call an SDK while the report's admission lock is held.
protocol NetworkTransportStatusObservation: Sendable {
    func apply(to status: inout NetworkHelperStatus)
}

struct NetworkVideoSubmissionObservation: Sendable {
    let connections: Int
    var transport: (any NetworkTransportStatusObservation)? = nil
}

/// Each adapter owns its SDK handle, format mapping, telemetry and cleanup.
/// Video methods run on the SDK-video lane; audio methods run serially on the
/// dedicated PCM reader. Neither lane dispatches SDK work through control.
protocol NetworkRuntimeAdapter: AnyObject {
    var version: String { get }
    var sourceName: String? { get }
    var videoConsumption: NetworkVideoConsumption { get }
    func createSender(name: String) -> Bool
    func sendVideo(_ bytes: UnsafeMutableRawPointer, format: NetworkVideoPixelFormat, timecode: Int64) -> Int32?
    func videoSubmissionObservation(_ context: NetworkVideoSubmissionContext) -> NetworkVideoSubmissionObservation
    func sendAudio(_ bytes: UnsafeRawPointer, sampleTime: Int64) -> Int32?
    func audioSubmissionObservation() -> (any NetworkTransportStatusObservation)?
    func flush()
    func close()

    #if DEBUG
    func createProbe(source: String, audioOnly: Bool) -> Bool
    func probeFrame(bytes: UnsafeMutableRawPointer, capacity: Int) -> NetworkProbeResult<Int64>
    func probeAudio() -> NetworkProbeResult<NetworkAudioObservation>
    #endif
}

#if DEBUG
enum NetworkProbeResult<Value: Sendable>: Sendable {
    case pending
    case received(Value)
    case invalid
}
#endif
