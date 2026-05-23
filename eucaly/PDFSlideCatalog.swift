import CoreGraphics
import CryptoKit
import Foundation

struct PDFSlideSource: Equatable, Sendable {
    let url: URL
    let pageCount: Int
}

enum PDFSlideCatalog {
    static func pageCount(for url: URL) -> Int? {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        let count = document.numberOfPages
        return count > 0 ? count : nil
    }

    static func shouldUseVirtualCatalog(pageCount: Int) -> Bool {
        pageCount > pdfThumbnailRenderPageLimit
    }

    static func stableSlideID(url: URL, pageIndex: Int) -> UUID {
        let normalizedURL = url.standardizedFileURL.absoluteString
        var hasher = SHA256()
        hasher.update(data: Data(normalizedURL.utf8))
        let digest = hasher.finalize()

        var bytes = Array(digest.prefix(16))
        bytes[0] = UInt8((pageIndex >> 24) & 0xFF)
        bytes[1] = UInt8((pageIndex >> 16) & 0xFF)
        bytes[2] = UInt8((pageIndex >> 8) & 0xFF)
        bytes[3] = UInt8(pageIndex & 0xFF)
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func pageIndex(fromStableSlideID id: UUID, url: URL) -> Int? {
        let uuidBytes = id.uuid
        let encodedIndex = (Int(uuidBytes.0) << 24)
            | (Int(uuidBytes.1) << 16)
            | (Int(uuidBytes.2) << 8)
            | Int(uuidBytes.3)
        guard encodedIndex >= 0 else { return nil }
        guard stableSlideID(url: url, pageIndex: encodedIndex) == id else { return nil }
        return encodedIndex
    }

    static func slide(url: URL, pageIndex: Int) -> Slide {
        Slide(
            id: stableSlideID(url: url, pageIndex: pageIndex),
            index: pageIndex + 1,
            lines: [],
            label: "Page \(pageIndex + 1)",
            videoURL: nil,
            pdfURL: url,
            pdfPageIndex: pageIndex,
            imageURL: nil,
            captureWindowID: nil
        )
    }

    static func slides(url: URL, pageCount: Int) -> [Slide] {
        guard pageCount > 0 else { return [] }
        return (0..<pageCount).map { slide(url: url, pageIndex: $0) }
    }
}
