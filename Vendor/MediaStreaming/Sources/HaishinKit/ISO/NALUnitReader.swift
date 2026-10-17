import CoreMedia
import Foundation

final package class NALUnitReader {
    static package let defaultNALUnitHeaderLength: Int32 = 4
    package var nalUnitHeaderLength: Int32 = NALUnitReader.defaultNALUnitHeaderLength

    package init() {
    }

    package func read<T: NALUnit>(_ data: inout Data, type: T.Type) -> [T] {
        // Borrow contiguous storage once instead of going through Foundation's
        // Data subscript for every byte of every compressed video frame.
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count > 3 else { return [] }
            var units: [T] = []
            var end = bytes.count
            for i in (2..<bytes.count).reversed() {
                guard bytes[i] == 1 && bytes[i - 1] == 0 && bytes[i - 2] == 0 else { continue }
                let startCodeLength = i >= 3 && bytes[i - 3] == 0 ? 4 : 3
                if i + 1 < end {
                    units.append(T(Data(bytes: bytes.baseAddress!.advanced(by: i + 1), count: end - i - 1)))
                }
                end = i + 1 - startCodeLength
            }
            return units
        }
    }

    package func read(_ buffer: CMSampleBuffer) -> [Data] {
        var offset = 0
        let header = Int(Self.defaultNALUnitHeaderLength)
        let length = buffer.dataBuffer?.dataLength ?? 0
        var result: [Data] = []

        if !buffer.isNotSync {
            if let formatDescription = buffer.formatDescription {
                result.append(Data([0x09, 0x10]))
                formatDescription.parameterSets.forEach {
                    result.append($0)
                }
            }
        } else {
            result.append(Data([0x09, 0x30]))
        }

        try? buffer.dataBuffer?.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                return
            }
            while offset + header < length {
                var nalUnitLength: UInt32 = 0
                memcpy(&nalUnitLength, baseAddress + offset, header)
                nalUnitLength = CFSwapInt32BigToHost(nalUnitLength)
                let start = offset + header
                let end = start + Int(nalUnitLength)
                if end <= length {
                    result.append(Data(bytes: baseAddress + start, count: Int(nalUnitLength)))
                } else {
                    break
                }
                offset = end
            }
        }
        return result
    }
}
