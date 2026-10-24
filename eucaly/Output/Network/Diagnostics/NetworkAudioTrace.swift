import Foundation
import Darwin

#if DEBUG
/// Opt-in, per-process hop timing for owned diagnostic runs. No PCM or file
/// content is recorded. Normal Debug runs and Release builds do no trace I/O.
nonisolated enum NetworkAudioTrace {
    private static let sink = Sink()
    static var isEnabled: Bool { sink != nil }
    static func rms(_ samples: UnsafePointer<Float>, frames: Int, stride: Int = 1) -> Double {
        guard frames > 0 else { return 0 }
        var power = 0.0
        for index in 0..<frames { let value = Double(samples[index * stride]); power += value * value }
        return (power / Double(frames)).squareRoot()
    }
    static func record(_ event: String, sample: Int64 = 0, queued: Int = 0, generation: UUID? = nil,
                       source: UUID? = nil, mediaSample: Int64? = nil, frames: Int? = nil,
                       covered: Int? = nil, sampleRate: Double? = nil, leftRMS: Double? = nil, rightRMS: Double? = nil,
                       rate: Double? = nil, gain: Float? = nil, sdkReturnBytes: Int32? = nil) {
        sink?.record(event, sample: sample, queued: queued, generation: generation,
            source: source, mediaSample: mediaSample, frames: frames, covered: covered,
            sampleRate: sampleRate, leftRMS: leftRMS, rightRMS: rightRMS, rate: rate, gain: gain, sdkReturnBytes: sdkReturnBytes)
    }
    static func flush() { sink?.flush() }
    private final class Sink: @unchecked Sendable {
        private struct Record {
            let now: UInt64
            let event: String
            let sample: Int64
            let queued: Int
            let generation: UUID?
            let source: UUID?
            let mediaSample: Int64?
            let frames: Int?
            let covered: Int?
            let sampleRate: Double?
            let leftRMS: Double?
            let rightRMS: Double?
            let rate: Double?
            let gain: Float?
            let sdkReturnBytes: Int32? // Raw OMT return; NDI void/unknown stays empty.
        }
        private let lock = NSLock()
        private let queue = DispatchQueue(label: "com.suku.eucaly.network.audio-trace", qos: .utility)
        private let file: FileHandle
        private var pending: [Record] = []
        private var dropped = 0
        private var timer: DispatchSourceTimer?
        init?() {
            guard let path = ProcessInfo.processInfo.environment["EUCALY_NDI_AUDIO_TRACE_DIRECTORY"] else { return nil }
            let url = URL(fileURLWithPath: path).appendingPathComponent("audio-trace-\(getpid()).csv")
            guard FileManager.default.createFile(atPath: url.path, contents: Data("host_nanoseconds,event,sample,queued,generation,source,media_sample,frames,covered,sample_rate,left_rms,right_rms,rate,gain,sdk_return_bytes\n".utf8)),
                  let file = try? FileHandle(forWritingTo: url) else { return nil }
            guard (try? file.seekToEnd()) != nil else { try? file.close(); return nil }
            self.file = file
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.writePending() }
            self.timer = timer; timer.resume()
        }
        func record(_ event: String, sample: Int64, queued: Int, generation: UUID?, source: UUID?,
                    mediaSample: Int64?, frames: Int?, covered: Int?, sampleRate: Double?, leftRMS: Double?, rightRMS: Double?,
                    rate: Double?, gain: Float?, sdkReturnBytes: Int32?) {
            let record = Record(now: DispatchTime.now().uptimeNanoseconds, event: event, sample: sample,
                queued: queued, generation: generation, source: source, mediaSample: mediaSample,
                frames: frames, covered: covered, sampleRate: sampleRate, leftRMS: leftRMS, rightRMS: rightRMS,
                rate: rate, gain: gain, sdkReturnBytes: sdkReturnBytes)
            lock.withLock {
                if pending.count < 8192 { pending.append(record) }
                else { dropped += 1 }
            }
        }
        func flush() { queue.async { [self] in writePending() } }
        private func writePending() {
            let (batch, lost) = lock.withLock {
                let batch = pending, lost = dropped
                pending = []; dropped = 0
                return (batch, lost)
            }
            guard !batch.isEmpty || lost > 0 else { return }
            var text = batch.map { row -> String in
                var fields = [String(row.now), row.event, String(row.sample), String(row.queued)]
                fields.reserveCapacity(15)
                fields.append(row.generation?.uuidString ?? "")
                fields.append(row.source?.uuidString ?? "")
                fields.append(row.mediaSample.map { String($0) } ?? "")
                fields.append(row.frames.map { String($0) } ?? "")
                fields.append(row.covered.map { String($0) } ?? "")
                fields.append(row.sampleRate.map { String($0) } ?? "")
                fields.append(row.leftRMS.map { String($0) } ?? "")
                fields.append(row.rightRMS.map { String($0) } ?? "")
                fields.append(row.rate.map { String($0) } ?? "")
                fields.append(row.gain.map { String($0) } ?? "")
                fields.append(row.sdkReturnBytes.map { String($0) } ?? "")
                return fields.joined(separator: ",") + "\n"
            }.joined()
            if lost > 0 { text += "\(DispatchTime.now().uptimeNanoseconds),trace-overflow,0,\(lost),,,,,,,,,,,\n" }
            try? file.write(contentsOf: Data(text.utf8))
        }
        deinit { timer?.cancel(); try? file.close() }
    }
}
#endif
