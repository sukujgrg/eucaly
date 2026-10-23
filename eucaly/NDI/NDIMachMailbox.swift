import Foundation
import Darwin

nonisolated final class NDIMachMessage: @unchecked Sendable {
    let packet: NDIHelperPacket
    let first: mach_port_t
    let second: mach_port_t
    let senderPID: Int32
    init(packet: NDIHelperPacket, first: mach_port_t, second: mach_port_t, senderPID: Int32) {
        self.packet = packet; self.first = first; self.second = second; self.senderPID = senderPID
    }
    deinit { eucaly_mach_send_release(first); eucaly_mach_send_release(second) }
}

/// Four kernel messages maximum, 64 KiB each. Receivers handle admission inline
/// so a producer cannot create an unbounded queue of Swift closures. Control and
/// frame delivery use separate ports. Received rights have one explicit owner.
nonisolated final class NDIMachMailbox: @unchecked Sendable {
    let port: mach_port_t
    private let reader: Reader
    /// A supplied queue must be serial and own the receiver's mutable state.
    init(label: String, queue: DispatchQueue? = nil, receive: @escaping @Sendable (NDIMachMessage) -> Void) throws {
        port = eucaly_mach_port_create()
        guard port != MACH_PORT_NULL else { throw NDIHelperWire.Failure.unavailable }
        let reader = Reader(port: port, queue: queue, receive: receive)
        self.reader = reader
        // A sleeping Mach reader must not occupy a GCD worker. Its independent
        // context also avoids retaining this mailbox while waiting for input.
        // Kernel arrival wakes the thread directly, without a dispatch-source
        // scheduling hop before decoding a time-sensitive PCM message.
        let thread = Thread { reader.run() }
        thread.name = label; thread.qualityOfService = .userInitiated
        thread.start()
    }
    func close() { reader.close() }
    deinit { close() }
    static func send(_ packet: NDIHelperPacket, to port: mach_port_t, first: mach_port_t = 0, second: mach_port_t = 0) -> Bool {
        #if DEBUG
        let tracedSample = packet.audio?.sampleTime
        if let tracedSample { NDIAudioTrace.record("encode-start", sample: tracedSample, generation: packet.generation) }
        #endif
        guard let data = try? NDIHelperWire.encode(packet) else { return false }
        #if DEBUG
        if let tracedSample { NDIAudioTrace.record("encode-done", sample: tracedSample, generation: packet.generation) }
        #endif
        let result = data.withUnsafeBytes { eucaly_mach_send(port, $0.baseAddress, UInt32($0.count), first, second) }
        #if DEBUG
        if let tracedSample { NDIAudioTrace.record("send-return", sample: tracedSample, queued: Int(result), generation: packet.generation) }
        #endif
        return result == KERN_SUCCESS
    }
    private final class Reader: @unchecked Sendable {
        private let port: mach_port_t
        private let queue: DispatchQueue?
        private let receive: @Sendable (NDIMachMessage) -> Void
        private let lock = NSLock()
        private var closed = false
        init(port: mach_port_t, queue: DispatchQueue?, receive: @escaping @Sendable (NDIMachMessage) -> Void) {
            self.port = port; self.queue = queue; self.receive = receive
        }
        func close() {
            lock.withLock {
                guard !closed else { return }
                closed = true
                // Serialize the wake with destruction so the port name cannot
                // be reused between checking closed and sending the wake.
                eucaly_mach_receive_wake(port)
            }
        }
        func run() {
            defer { lock.withLock { closed = true; eucaly_mach_receive_destroy(port) } }
            var bytes = Data(count: NDIHelperWire.maximumMessageBytes)
            while !lock.withLock({ closed }) {
                // A long-lived Foundation thread needs a pool per message,
                // rather than retaining autoreleased decoder objects until exit.
                if !autoreleasepool(invoking: { receiveNext(&bytes) }) { return }
            }
        }
        private func receiveNext(_ bytes: inout Data) -> Bool {
            var count: UInt32 = 0, first: mach_port_t = 0, second: mach_port_t = 0, pid: Int32 = 0
            let result = bytes.withUnsafeMutableBytes {
                eucaly_mach_receive(port, $0.baseAddress, UInt32($0.count), &count, &first, &second, &pid)
            }
            // Malformed/oversized input is consumed and discarded. An invalid
            // port or allocation/resource failure must end the reader rather
            // than spinning; peer failure/progress supervision then retires it.
            guard result == KERN_SUCCESS else {
                return result == KERN_INVALID_ARGUMENT || result == MACH_RCV_TOO_LARGE
            }
            guard !lock.withLock({ closed }) else {
                eucaly_mach_send_release(first); eucaly_mach_send_release(second); return false
            }
            #if DEBUG
            NDIAudioTrace.record("wire-receive", queued: Int(count))
            #endif
            guard let packet = try? NDIHelperWire.decode(NDIHelperPacket.self, bytes.prefix(Int(count))) else {
                eucaly_mach_send_release(first); eucaly_mach_send_release(second); return true
            }
            #if DEBUG
            if let block = packet.audio { NDIAudioTrace.record("mailbox-audio", sample: block.sampleTime, generation: packet.generation) }
            #endif
            let message = NDIMachMessage(packet: packet, first: first, second: second, senderPID: pid)
            let deliver = { [self] in if !lock.withLock({ closed }) { receive(message) } }
            // Sync serialization bounds admission to the kernel queue plus
            // this one message; no unbounded queue of delivery closures.
            if let queue { queue.sync(execute: deliver) } else { deliver() }
            return true
        }
    }
}

#if DEBUG
/// Opt-in, per-process hop timing for owned diagnostic runs. No PCM or file
/// content is recorded. Normal Debug runs and Release builds do no trace I/O.
nonisolated enum NDIAudioTrace {
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
        private let queue = DispatchQueue(label: "com.suku.eucaly.ndi.audio-trace", qos: .utility)
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
