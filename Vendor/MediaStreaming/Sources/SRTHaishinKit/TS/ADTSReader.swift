import Foundation
import HaishinKit

class ADTSReader: Sequence {
    private var data: Data = .init()

    func read(_ data: Data) {
        self.data = data
    }

    func makeIterator() -> ADTSReaderIterator {
        return ADTSReaderIterator(data: data)
    }
}

struct ADTSReaderIterator: IteratorProtocol {
    private let data: Data
    private var cursor: Int = 0

    init(data: Data) {
        self.data = data
    }

    mutating func next() -> Int? {
        guard cursor < data.count else {
            return nil
        }
        guard let header = ADTSHeader(validating: Data(data.dropFirst(cursor))) else {
            cursor = data.count
            return nil
        }
        let length = Int(header.aacFrameLength)
        cursor += length
        return length
    }
}
