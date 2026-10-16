import AVFoundation
import Foundation

extension AVAudioCompressedBuffer {
    @discardableResult
    @inline(__always)
    final func copy(_ buffer: AVAudioBuffer) -> Bool {
        guard let buffer = buffer as? AVAudioCompressedBuffer,
              format == buffer.format, buffer.packetCount > 0,
              buffer.packetCount <= packetCapacity, buffer.byteLength <= byteCapacity else {
            return false
        }
        if let packetDescriptions = buffer.packetDescriptions {
            guard let destination = self.packetDescriptions else { return false }
            for i in 0..<Int(buffer.packetCount) {
                let packet = packetDescriptions[i]
                guard packet.mStartOffset >= 0, packet.mStartOffset <= Int64(buffer.byteLength),
                      packet.mDataByteSize <= buffer.byteLength - UInt32(packet.mStartOffset) else { return false }
            }
            destination.update(from: packetDescriptions, count: Int(buffer.packetCount))
        }
        packetCount = buffer.packetCount
        byteLength = buffer.byteLength
        data.copyMemory(from: buffer.data, byteCount: Int(buffer.byteLength))
        return true
    }

    package func encode(to data: inout Data) {
        guard let config = AudioSpecificConfig(formatDescription: format.formatDescription) else {
            return
        }
        config.encode(to: &data, length: Int(byteLength))
        data.withUnsafeMutableBytes {
            guard let baseAddress = $0.baseAddress else {
                return
            }
            memcpy(baseAddress.advanced(by: AudioSpecificConfig.adtsHeaderSize), self.data, Int(self.byteLength))
        }
    }
}
