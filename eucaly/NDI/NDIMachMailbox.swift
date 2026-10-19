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
    private let lock = NSLock()
    private var closed = false
    init(label: String, receive: @escaping @Sendable (NDIMachMessage) -> Void) throws {
        port = eucaly_mach_port_create()
        guard port != MACH_PORT_NULL else { throw NDIHelperWire.Failure.unavailable }
        DispatchQueue(label: label).async { [self] in
            var bytes = Data(count: NDIHelperWire.maximumMessageBytes)
            while true {
                lock.lock(); let stop = closed; lock.unlock()
                if stop { break }
                var count: UInt32 = 0, first: mach_port_t = 0, second: mach_port_t = 0, pid: Int32 = 0
                let result = bytes.withUnsafeMutableBytes {
                    eucaly_mach_receive(port, $0.baseAddress, UInt32($0.count), &count, &first, &second, &pid)
                }
                guard result == KERN_SUCCESS else { continue }
                guard let packet = try? NDIHelperWire.decode(NDIHelperPacket.self, bytes.prefix(Int(count))) else {
                    eucaly_mach_send_release(first); eucaly_mach_send_release(second); continue
                }
                receive(.init(packet: packet, first: first, second: second, senderPID: pid))
            }
            eucaly_mach_receive_destroy(port)
        }
    }
    func close() { lock.lock(); closed = true; lock.unlock() }
    static func send(_ packet: NDIHelperPacket, to port: mach_port_t, first: mach_port_t = 0, second: mach_port_t = 0) -> Bool {
        guard let data = try? NDIHelperWire.encode(packet) else { return false }
        return data.withUnsafeBytes { eucaly_mach_send(port, $0.baseAddress, UInt32($0.count), first, second) == KERN_SUCCESS }
    }
}
