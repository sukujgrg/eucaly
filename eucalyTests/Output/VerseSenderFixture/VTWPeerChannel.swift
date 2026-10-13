// Test fixture from actual ViewTheWord sender, 2026-10-13.
// Original SHA256: 696c36eb9dcad6005100cda0f6b1ea166a36a31f9347cd60ee8de6440a2839b1
// Only type names and explicit actor-independent declarations differ.
// Adapted from VTWAltView’s protocol v1 implementation (2026-10-02).
import Foundation
import Network
import Security

/// All methods and callbacks are confined to the supplied queue.
nonisolated final class VTWAltViewPeerChannel: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    let queue: DispatchQueue
    var onReady: (() -> Void)?
    var onMessage: ((VTWAltViewWireMessage) -> Void)?
    var onClose: ((String?) -> Void)?
    private(set) var retryableFailure = false
    private var decoder = VTWAltViewFrameDecoder()
    private var outbox = VTWAltViewMessageOutbox()
    private var sending = false
    private var ready = false
    private var closed = false
    private var sendStarted: TimeInterval?
    private let connectionTimeout: TimeInterval
    private var started = ProcessInfo.processInfo.systemUptime
    private(set) var lastReceived = ProcessInfo.processInfo.systemUptime

    init(connection: NWConnection, queue: DispatchQueue, connectionTimeout: TimeInterval = VTWAltViewProtocol.timeout) {
        self.connection = connection; self.queue = queue; self.connectionTimeout = connectionTimeout
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.ready = true
                self.lastReceived = ProcessInfo.processInfo.systemUptime
                self.onReady?()
                self.receive()
                self.pump()
            case .waiting(let error):
                // A rejected pairing key needs new input, not more time.
                if case .tls = error { self.fail(error); return }
                // Network.framework can recover when permission or the network path changes.
                // Keep this attempt alive within its existing timeout budget.
                break
            case .failed(let error): self.fail(error)
            case .cancelled: self.close(nil)
            default: break
            }
        }
        connection.start(queue: queue)
    }
    func send(_ message: VTWAltViewWireMessage) {
        guard !closed else { return }
        do { try outbox.enqueue(message); pump() }
        catch { close(error.localizedDescription) }
    }
    func discardPendingState() { outbox.clearState() }
    func checkTimeout(now: TimeInterval, timeout: TimeInterval = VTWAltViewProtocol.timeout) {
        guard !closed else { return }
        let timedOut = ready ? now - lastReceived > timeout : now - started > connectionTimeout
        if timedOut || sendStarted.map({ now - $0 > timeout }) == true {
            close("Connection timed out.", retryable: true)
        }
    }
    private func fail(_ error: NWError) {
        if !Self.isRetryableNetworkError(error) {
            close("The secure connection was rejected. Check the pairing code on the receiving Mac.")
        } else {
            close(error.localizedDescription, retryable: true)
        }
    }
    static func isRetryableNetworkError(_ error: NWError) -> Bool {
        guard case .tls(let status) = error else { return true }
        // A receiver quitting or losing its network can surface as a TLS close,
        // not only a POSIX error. These do not mean the pairing was rejected.
        return [errSSLClosedGraceful, errSSLClosedAbort, errSSLClosedNoNotify, errSSLNetworkTimeout].contains(status)
    }
    func close(_ reason: String?, retryable: Bool = false) {
        guard !closed else { return }
        closed = true
        retryableFailure = retryable
        connection.stateUpdateHandler = nil
        connection.cancel()
        let callback = onClose
        onClose = nil; onMessage = nil; onReady = nil
        callback?(reason)
    }
    private func pump() {
        guard ready, !closed, !sending, let message = outbox.next() else { return }
        do {
            let frame = try VTWAltViewFrameCodec.encode(message)
            sending = true
            sendStarted = ProcessInfo.processInfo.systemUptime
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                self.sending = false; self.sendStarted = nil
                if let error { self.fail(error) } else { self.pump() }
            })
        } catch { close(error.localizedDescription) }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            do {
                if let data, !data.isEmpty {
                    for message in try self.decoder.append(data) {
                        guard message.version == VTWAltViewProtocol.version else { self.close("Incompatible protocol version."); return }
                        self.lastReceived = ProcessInfo.processInfo.systemUptime
                        self.onMessage?(message)
                        if self.closed { return }
                    }
                }
                if let error { self.fail(error) }
                else if complete { self.close("Peer disconnected.", retryable: true) }
                else { self.receive() }
            } catch { self.close(error.localizedDescription) }
        }
    }
}
