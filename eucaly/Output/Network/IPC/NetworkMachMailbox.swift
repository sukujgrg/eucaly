import Foundation
import Darwin

nonisolated final class NetworkMachMessage: @unchecked Sendable {
    let packet: NetworkHelperPacket
    let first: mach_port_t
    let second: mach_port_t
    let senderPID: Int32
    init(packet: NetworkHelperPacket, first: mach_port_t, second: mach_port_t, senderPID: Int32) {
        self.packet = packet; self.first = first; self.second = second; self.senderPID = senderPID
    }
    deinit { eucaly_mach_send_release(first); eucaly_mach_send_release(second) }
}

/// Four kernel messages maximum, 64 KiB each. Receivers handle admission inline
/// so a producer cannot create an unbounded queue of Swift closures. Control and
/// frame delivery use separate ports. Received rights have one explicit owner.
nonisolated final class NetworkMachMailbox: @unchecked Sendable {
    let port: mach_port_t
    private let reader: Reader
    /// A supplied queue must be serial and own the receiver's mutable state.
    init(label: String, queue: DispatchQueue? = nil, receive: @escaping @Sendable (NetworkMachMessage) -> Void) throws {
        port = eucaly_mach_port_create()
        guard port != MACH_PORT_NULL else { throw NetworkHelperWire.Failure.unavailable }
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
    static func send(_ packet: NetworkHelperPacket, to port: mach_port_t, first: mach_port_t = 0, second: mach_port_t = 0) -> Bool {
        #if DEBUG
        let tracedSample = packet.audio?.sampleTime
        if let tracedSample { NetworkAudioTrace.record("encode-start", sample: tracedSample, generation: packet.generation) }
        #endif
        guard let data = try? NetworkHelperWire.encode(packet) else { return false }
        #if DEBUG
        if let tracedSample { NetworkAudioTrace.record("encode-done", sample: tracedSample, generation: packet.generation) }
        #endif
        let result = data.withUnsafeBytes { eucaly_mach_send(port, $0.baseAddress, UInt32($0.count), first, second) }
        #if DEBUG
        if let tracedSample { NetworkAudioTrace.record("send-return", sample: tracedSample, queued: Int(result), generation: packet.generation) }
        #endif
        return result == KERN_SUCCESS
    }
    private final class Reader: @unchecked Sendable {
        private let port: mach_port_t
        private let queue: DispatchQueue?
        private let receive: @Sendable (NetworkMachMessage) -> Void
        private let lock = NSLock()
        private var closed = false
        init(port: mach_port_t, queue: DispatchQueue?, receive: @escaping @Sendable (NetworkMachMessage) -> Void) {
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
            var bytes = Data(count: NetworkHelperWire.maximumMessageBytes)
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
            NetworkAudioTrace.record("wire-receive", queued: Int(count))
            #endif
            guard let packet = try? NetworkHelperWire.decode(NetworkHelperPacket.self, bytes.prefix(Int(count))) else {
                eucaly_mach_send_release(first); eucaly_mach_send_release(second); return true
            }
            #if DEBUG
            if let block = packet.audio { NetworkAudioTrace.record("mailbox-audio", sample: block.sampleTime, generation: packet.generation) }
            #endif
            let message = NetworkMachMessage(packet: packet, first: first, second: second, senderPID: pid)
            let deliver = { [self] in if !lock.withLock({ closed }) { receive(message) } }
            // Sync serialization bounds admission to the kernel queue plus
            // this one message; no unbounded queue of delivery closures.
            if let queue { queue.sync(execute: deliver) } else { deliver() }
            return true
        }
    }
}
