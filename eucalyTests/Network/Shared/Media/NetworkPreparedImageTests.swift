import XCTest
import AppKit
@testable import eucaly

@MainActor
final class NetworkPreparedImageTests: XCTestCase {
    func testAtomicReplacementInvalidatesPreparedImageWhenDateAndSizeArePreserved() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-image-replacement-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let date = Date(timeIntervalSince1970: 1_700_000_000), prepared = OutputPreparedMedia()
        defer { prepared.stop() }
        try writeImage((255, 0, 0), to: url, date: date, atomic: true)
        let oldNumber = try attributes(url)[.systemFileNumber] as? NSNumber
        let first = try await frame(prepared, url: url, identity: "before replacement")
        XCTAssertGreaterThan(pixel(first)[2], 200)

        try writeImage((0, 0, 255), to: url, date: date, atomic: true)
        XCTAssertNotEqual(try attributes(url)[.systemFileNumber] as? NSNumber, oldNumber)
        let replacement = try await frame(prepared, url: url, identity: "after replacement")

        XCTAssertGreaterThan(pixel(replacement)[0], 200)
        XCTAssertLessThan(pixel(replacement)[2], 20)
        XCTAssertFalse(first === replacement)
    }

    func testExplicitLoadRefreshesImageBytesWhileOrdinaryCompositionReusesPreparedPicture() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ndi-image-reload-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let date = Date(timeIntervalSince1970: 1_700_000_000), prepared = OutputPreparedMedia()
        defer { prepared.stop() }
        try writeImage((255, 0, 0), to: url, date: date, atomic: true)
        let originalAttributes = try attributes(url)
        let first = try await frame(prepared, url: url, identity: "initial composition", loadIdentity: "workspace:1")

        // Simulate an editor that rewrites the same file and preserves its
        // timestamp. Only an explicit accepted Current load changes identity.
        try writeImage((0, 0, 255), to: url, date: date, atomic: false)
        let replacementAttributes = try attributes(url)
        for key in [FileAttributeKey.size, .modificationDate, .systemFileNumber] {
            XCTAssertEqual(originalAttributes[key] as? NSObject, replacementAttributes[key] as? NSObject)
        }
        let refreshedComposition = try await frame(prepared, url: url, identity: "appearance edit", loadIdentity: "workspace:1")
        XCTAssertTrue(first === refreshedComposition)
        let loaded = try await frame(prepared, url: url, identity: "explicit load", loadIdentity: "workspace:2")
        XCTAssertGreaterThan(pixel(loaded)[0], 200)
        XCTAssertLessThan(pixel(loaded)[2], 20)
        XCTAssertFalse(first === loaded)
        let laterComposition = try await frame(prepared, url: url, identity: "later output refresh", loadIdentity: "workspace:2")
        XCTAssertTrue(loaded === laterComposition)
    }

    private func frame(_ prepared: OutputPreparedMedia, url: URL, identity: String,
                       loadIdentity: String? = nil) async throws -> NetworkFrameResource {
        try await withCheckedThrowingContinuation { continuation in
            prepared.request(.init(url: url, page: nil, identity: identity, loadIdentity: loadIdentity), slot: 0) { _, frame, error in
                if let frame { continuation.resume(returning: frame) }
                else { continuation.resume(throwing: NSError(domain: "NetworkPreparedImageTests", code: 1,
                                                            userInfo: [NSLocalizedDescriptionKey: error ?? "Image preparation failed"])) }
            }
        }
    }

    private func attributes(_ url: URL) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: url.path)
    }

    private func writeImage(_ colour: (UInt8, UInt8, UInt8), to url: URL, date: Date, atomic: Bool) throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<8 { for x in 0..<8 {
            let offset = y * bitmap.bytesPerRow + x * 4
            pixels[offset] = colour.0
            pixels[offset + 1] = colour.1
            pixels[offset + 2] = colour.2
            pixels[offset + 3] = 255
        } }
        var data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        XCTAssertLessThan(data.count, 8192)
        data.append(Data(repeating: 0, count: 8192 - data.count))
        if atomic {
            try data.write(to: url, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func pixel(_ frame: NetworkFrameResource) -> [UInt8] {
        let surface = frame.surface
        let offset = surface.height / 2 * surface.bytesPerRow + surface.width / 2 * 4
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes + offset, count: 4))
    }
}
