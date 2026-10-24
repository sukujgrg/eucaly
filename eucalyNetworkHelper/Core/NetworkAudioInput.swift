import Foundation

/// The private audio reader handles one PCM block through SDK completion and
/// acknowledgement, with no dispatch handoff between those stages. Installation
/// and closing share only a short admission lock with the control queue.
final class NetworkAudioInput: @unchecked Sendable {
    private struct Target {
        let sender: NetworkSubmissionWorker
        let peer: NetworkMachMessage
    }
    private let lock = NSLock()
    private var target: Target?
    private var closed = false
    func install(_ sender: NetworkSubmissionWorker, peer: NetworkMachMessage) {
        lock.withLock { if !closed { target = .init(sender: sender, peer: peer) } }
    }
    func close() { lock.withLock { closed = true; target = nil } }
    func receive(_ message: NetworkMachMessage, generation: UUID, parentPID: Int32,
                 failed: @Sendable (String) -> Void) {
        guard message.senderPID == parentPID, message.packet.generation == generation else { return }
        guard let target = lock.withLock({ closed ? nil : target }) else { return }
        let packet = message.packet
        guard packet.version == NetworkHelperWire.version, packet.build == NetworkHelperWire.build,
              packet.kind == .audio, message.first == 0, message.second == 0,
              let block = packet.audio, block.isValid else {
            close(); failed("Invalid audio block"); return
        }
        #if DEBUG
        NetworkAudioTrace.record("ipc-receive", sample: block.sampleTime, generation: generation)
        #endif
        switch target.sender.sendAudio(block, epoch: packet.contentEpoch) {
        case .submitted, .superseded: break
        case .discontinuity:
            close(); failed("Network output audio discontinuity. Choose Retry to restart this source."); return
        }
        #if DEBUG
        NetworkAudioTrace.record("ack-send", sample: block.sampleTime, generation: generation)
        #endif
        guard NetworkMachMailbox.send(.init(kind: .audioAccepted, generation: generation,
            revision: UInt64(block.sampleTime)), to: target.peer.second) else {
            close(); failed("Audio acknowledgement failed"); return
        }
    }
}
