import XCTest
import AppKit
import IOSurface
@testable import eucaly

/// Inspect the actual bytes produced by the production Metal kernel without
/// requiring the optional SDK. The helper's test export is an immutable copy.
@MainActor
final class NDIPackedVideoTests: XCTestCase {
    func testRec709StudioRangePackingPreservesLumaChromaAndFullRangeAlpha() async throws {
        let log = PackedVideoEvents(), id = UUID(), helper = NDIHelperSupervisor(event: log.record)
        defer { helper.stop() }
        helper.start(generation: id, configuration: .init(purpose: .renderYUV))
        try await until { log.ready || log.failure != nil }
        let colours: [[UInt8]] = [[0, 0, 255, 255], [0, 255, 0, 255], [255, 0, 0, 255],
            [255, 255, 255, 255], [0, 0, 0, 255], [128, 128, 128, 255],
            [0, 0, 128, 128], [128, 0, 0, 128], [0, 128, 0, 128], [0, 0, 0, 0]]
        let input = try surface()
        let bytes = input.baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<1080 {
            for x in 0..<1920 {
                let colour = colours[(x / 192) % colours.count]
                for channel in 0..<4 { bytes[y * input.bytesPerRow + x * 4 + channel] = colour[channel] }
            }
        }
        helper.renderMedia(.init(request: .init(generation: id, revision: 1, foreground: true, colour: .init(alpha: 0)),
            foreground: .init(surface: input), background: nil))
        try await until { log.revision == 1 || log.failure != nil }
        XCTAssertNil(log.failure)
        let alpha = try XCTUnwrap(log.surface)
        XCTAssertTrue(NDIHelperWire.validPackedVideo(alpha)); XCTAssertEqual(alpha.pixelFormat, NDIVideoPixelFormat.uyva.rawValue)
        let output = alpha.baseAddress.assumingMemoryBound(to: UInt8.self)
        for index in colours.indices {
            let x = index * 192 + 96, c = colours[index], a = Double(c[3])
            let rgb = a == 0 ? [0.0, 0.0, 0.0] : [Double(c[2]) / a, Double(c[1]) / a, Double(c[0]) / a]
            let expected = reference(rgb)
            let offset = 540 * 3840 + x * 2
            for (channel, value) in [expected.1, expected.0, expected.2, expected.0].enumerated() {
                XCTAssertEqual(Int(output[offset + channel]), value, accuracy: 1, "Rec.709 palette entry \(index), byte \(channel)")
            }
            XCTAssertEqual(output[3840 * 1080 + 540 * 1920 + x], c[3], "Alpha is full range, independent of YUV legal range")
        }
        helper.renderMedia(.init(request: .init(generation: id, revision: 2, dimming: 0.8, colour: .chromaGreen), foreground: nil, background: nil))
        try await until { log.revision == 2 || log.failure != nil }
        XCTAssertNil(log.failure)
        let chroma = try XCTUnwrap(log.surface)
        XCTAssertEqual(chroma.pixelFormat, NDIVideoPixelFormat.uyvy.rawValue)
        XCTAssertEqual(chroma.allocationSize, 1920 * 1080 * 2)
        let green = reference([0, 1, 0]), key = chroma.baseAddress.assumingMemoryBound(to: UInt8.self)
        for offset in stride(from: 0, to: chroma.allocationSize, by: 4) {
            guard Int(key[offset]) == green.1, Int(key[offset + 1]) == green.0,
                  Int(key[offset + 2]) == green.2, Int(key[offset + 3]) == green.0 else {
                XCTFail("Dimming changed an empty chroma picture at byte \(offset)"); break
            }
        }
        // The receiver's prior export must remain unchanged after a new frame.
        XCTAssertEqual(output[3840 * 1080 + 540 * 1920 + 1800], 0)
    }

    func testSharedChromaUsesBothLumasAndKeepsTransparentNeighboursFromDesaturatingText() async throws {
        let log = PackedVideoEvents(), id = UUID(), helper = NDIHelperSupervisor(event: log.record)
        defer { helper.stop() }
        helper.start(generation: id, configuration: .init(purpose: .renderYUV))
        try await until { log.ready || log.failure != nil }
        let input = try surface(), p = input.baseAddress.assumingMemoryBound(to: UInt8.self)
        // Red/blue pairs in the top half; red/transparent pairs below them.
        for y in 0..<1080 {
            for x in 0..<1920 {
                let offset = y * input.bytesPerRow + x * 4
                let c: [UInt8] = x.isMultiple(of: 2) ? [0, 0, 255, 255] : y < 540 ? [255, 0, 0, 255] : [0, 0, 0, 0]
                for channel in 0..<4 { p[offset + channel] = c[channel] }
            }
        }
        helper.renderMedia(.init(request: .init(generation: id, revision: 1, foreground: true, colour: .init(alpha: 0)),
            foreground: .init(surface: input), background: nil))
        try await until { log.revision == 1 || log.failure != nil }
        XCTAssertNil(log.failure)
        let frame = try XCTUnwrap(log.surface), q = frame.baseAddress.assumingMemoryBound(to: UInt8.self)
        let red = reference([1, 0, 0]), blue = reference([0, 0, 1]), mixed = reference([0.5, 0, 0.5])
        let top = 100 * 3840 + 200 * 2, bottom = 800 * 3840 + 200 * 2
        for (index, value) in [mixed.1, red.0, mixed.2, blue.0].enumerated() { XCTAssertEqual(Int(q[top + index]), value, accuracy: 1) }
        for (index, value) in [red.1, red.0, red.2, 16].enumerated() { XCTAssertEqual(Int(q[bottom + index]), value, accuracy: 1) }
        XCTAssertEqual(q[3840 * 1080 + 800 * 1920 + 200], 255)
        XCTAssertEqual(q[3840 * 1080 + 800 * 1920 + 201], 0)
    }

    func testMultilingualGlyphAlphaMatchesTheBGRAReference() async throws {
        let raw = PackedVideoEvents(), referenceLog = PackedVideoEvents(), id = UUID(), otherID = UUID()
        let helper = NDIHelperSupervisor(event: raw.record), baseline = NDIHelperSupervisor(event: referenceLog.record)
        defer { helper.stop(); baseline.stop() }
        helper.start(generation: id, configuration: .init(purpose: .renderYUV))
        baseline.start(generation: otherID)
        try await until { (raw.ready && referenceLog.ready) || raw.failure != nil || referenceLog.failure != nil }
        var profile = OutputProfile.builtIns.first { $0.kind == .audience }!
        profile.usesLegacySizing = false; profile.typography.colour = .init(red: 1)
        let text = OutputTextContent(kind: .lyrics, components: [.init(role: .primary, text: "தமிழ் · Ελληνικά · العربية")])
        helper.render(.init(generation: id, revision: 1, text: text, profile: profile, transparent: true))
        baseline.render(.init(generation: otherID, revision: 1, text: text, profile: profile, transparent: true))
        try await until { (raw.revision == 1 && referenceLog.revision == 1) || raw.failure != nil || referenceLog.failure != nil }
        XCTAssertNil(raw.failure); XCTAssertNil(referenceLog.failure)
        let packed = try XCTUnwrap(raw.surface), bgra = try XCTUnwrap(referenceLog.surface)
        let a = packed.baseAddress.assumingMemoryBound(to: UInt8.self), b = bgra.baseAddress.assumingMemoryBound(to: UInt8.self)
        var glyphs = 0, edges = 0
        for y in 0..<1080 {
            for x in 0..<1920 {
                let actual = a[3840 * 1080 + y * 1920 + x], expected = b[y * bgra.bytesPerRow + x * 4 + 3]
                guard abs(Int(actual) - Int(expected)) <= 1 else { XCTFail("Alpha geometry differs at \(x),\(y)"); return }
                if actual > 0 { glyphs += 1 }
                if actual > 0 && actual < 240 { edges += 1 }
            }
        }
        XCTAssertGreaterThan(glyphs, 100); XCTAssertGreaterThan(edges, 100)
    }

    private func reference(_ rgb: [Double]) -> (Int, Int, Int) {
        let y = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2]
        return (Int((16 + 219 * y).rounded()), Int((128 + 224 * (rgb[2] - y) / 1.8556).rounded()),
                Int((128 + 224 * (rgb[0] - y) / 1.5748).rounded()))
    }
    private func surface() throws -> IOSurface {
        try XCTUnwrap(IOSurface(properties: [.width: 1920, .height: 1080, .bytesPerElement: 4,
            .bytesPerRow: 7680, .allocSize: 1920 * 1080 * 4, .pixelFormat: 0x42475241]))
    }
    private func until(_ check: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 8
        while !check(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(for: .milliseconds(20)) }
        guard check() else { XCTFail("Timed out waiting for packed video"); throw NDIHelperWire.Failure.unavailable }
    }
}

private final class PackedVideoEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var value = (ready: false, revision: UInt64(0), surface: Optional<IOSurface>.none, failure: Optional<String>.none)
    var ready: Bool { lock.withLock { value.ready } }
    var revision: UInt64 { lock.withLock { value.revision } }
    var surface: IOSurface? { lock.withLock { value.surface } }
    var failure: String? { lock.withLock { value.failure } }
    func record(_ event: NDIHelperSupervisor.Event) {
        lock.withLock {
            switch event {
            case .ready: value.ready = true
            case .frame(_, let revision, let surface): value.revision = revision; value.surface = surface
            case .failed(_, let reason): value.failure = reason
            default: break
            }
        }
    }
}
