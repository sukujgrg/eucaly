import Foundation
import IOSurface
import CoreVideo

/// No SDK types, AVPlayer, bookmarks, file paths or observable state cross IPC.
/// The schema is shared by the app and its separately linked helper executable.
nonisolated enum NDIHelperWire {
    static let version = 7
    static let build = "ndi-workspaces-2"
    static let maximumMessageBytes = 65_536
    static let width = 1920
    static let height = 1080
    static let maximumSurfaceBytes = width * height * 4
    static let installedRuntimePaths = ["/usr/local/lib/libndi.dylib", "/Library/NDI SDK for Apple/lib/macOS/libndi.dylib"]

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumMessageBytes else { throw Failure.invalidMessage }
        return data
    }
    static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard data.count <= maximumMessageBytes else { throw Failure.invalidMessage }
        return try JSONDecoder().decode(type, from: data)
    }
    enum Failure: Error { case invalidMessage, invalidSurface, unavailable }
    static func valid(_ surface: IOSurface) -> Bool {
        surface.width == width && surface.height == height && surface.bytesPerElement == 4
            && surface.bytesPerRow == width * 4 && surface.allocationSize == maximumSurfaceBytes
            && surface.pixelFormat == 0x42475241 && surface.planeCount == 0
    }
    static func validMedia(_ surface: IOSurface) -> Bool {
        (1...4096).contains(surface.width) && (1...4096).contains(surface.height)
            && surface.bytesPerElement == 4 && surface.planeCount == 0 && surface.pixelFormat == 0x42475241
            && surface.bytesPerRow >= surface.width * 4 && surface.bytesPerRow <= 16_384
            && surface.allocationSize >= surface.bytesPerRow * surface.height && surface.allocationSize <= 67_108_864
    }
}

nonisolated struct NDIHelperBootstrap: Codable {
    let portIndex: Int32
    let generation: UUID
    let version: Int
    let build: String
    let parentPID: Int32
    var configuration = NDIHelperConfiguration()
}

nonisolated struct NDIHelperConfiguration: Codable, Sendable {
    enum Purpose: String, Codable, Sendable { case renderOnly, sender, loopbackProbe, audioProbe }
    var purpose: Purpose = .renderOnly
    var sourceName = ""
    var isValid: Bool {
        switch purpose {
        case .renderOnly: return sourceName.isEmpty
        case .sender, .loopbackProbe, .audioProbe:
            return !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && sourceName.utf8.count <= (purpose == .sender ? 120 : 512)
                && !sourceName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
    }
}

nonisolated struct NDIHelperStatus: Codable, Sendable {
    var runtimeVersion = ""
    var sourceName = ""
    var submittedFrames: UInt64 = 0
    var lastTimecode: Int64 = 0
    var connections = 0
    var replacedFrames: UInt64 = 0
    var audioBlocks: UInt64 = 0
    var lastAudioSample: Int64 = 0
    var gpuMilliseconds: Double = 0
    var maximumGPUMilliseconds: Double = 0
    var surfacePoolHighWaterMark: Int = 0
    var effectiveFramesPerSecond: Double? = nil
    var frameAgeMilliseconds: Double? = nil
    var submissionMilliseconds: Double = 0
    var slowCadence = false

    var validMetrics: Bool {
        [effectiveFramesPerSecond, frameAgeMilliseconds, submissionMilliseconds].compactMap { $0 }
            .allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000 }
    }
    var performanceNotice: String? {
        if slowCadence, let fps = effectiveFramesPerSecond {
            return "Output is below 30 fps (\(fps.formatted(.number.precision(.fractionLength(1)))) fps). Reduce video load and check the connection."
        }
        return nil
    }
}

/// One-second monotonic windows count completed SDK submissions, including
/// cached stills. Two low windows warn without turning normal jitter into a fault.
nonisolated struct NDISubmissionMetrics {
    private var windowStart: UInt64?
    private var completed: UInt64 = 0
    private var slowWindows = 0
    private(set) var framesPerSecond: Double?
    private(set) var slowCadence = false
    private(set) var frameAgeMilliseconds: Double?
    mutating func submitted(at now: UInt64, newPictureProducedAt: UInt64?) {
        if let produced = newPictureProducedAt, produced <= now {
            frameAgeMilliseconds = Double(now - produced) / 1_000_000
        }
        guard let start = windowStart else { windowStart = now; return }
        guard now > start else { return }
        completed &+= 1
        let elapsed = Double(now - start) / 1_000_000_000
        guard elapsed >= 1 else { return }
        let fps = Double(completed) / elapsed
        framesPerSecond = fps
        slowWindows = fps < 27 ? min(2, slowWindows + 1) : 0
        slowCadence = slowWindows >= 2
        windowStart = now; completed = 0
    }
}

/// A small immutable complete render state, sharing native OutputTextView.
nonisolated struct NDITextRenderRequest: Codable, Equatable, Sendable {
    let generation: UUID
    let revision: UInt64
    let text: OutputTextContent
    let profile: OutputProfile
    let transparent: Bool
    var producedAtNanoseconds: UInt64 = 0

    var isValid: Bool {
        profile.background.bookmark == nil && profile.name.utf8.count <= 160
            && (text.label?.utf8.count ?? 0) <= 512 && profile.roles.count <= OutputComponentRole.allCases.count
            && Set(profile.roles).count == profile.roles.count && text.components.count <= 32
            && text.components.allSatisfy { ($0.label?.utf8.count ?? 0) <= 512 }
            && text.components.reduce(0, { $0 + $1.text.utf8.count }) <= 32_768
            && ["stacked", "columns"].contains(profile.layout)
            && ["left", "center", "right"].contains(profile.alignment)
            && ["top", "middle", "bottom"].contains(profile.position)
            && profile.padding.isFinite && (0...2).contains(profile.padding)
            && ([profile.typography] + profile.componentTypography.values.map { $0.resolve(inheriting: profile.typography) }).allSatisfy {
                $0.size.isFinite && (1...800).contains($0.size) && $0.weight.isFinite && (-1...1).contains($0.weight)
                    && $0.lineSpacing.isFinite && (0...200).contains($0.lineSpacing) && ($0.fontName?.utf8.count ?? 0) <= 256
                    && [$0.colour.red, $0.colour.green, $0.colour.blue, $0.colour.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
            }
            && [profile.background.colour.red, profile.background.colour.green, profile.background.colour.blue, profile.background.colour.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

nonisolated struct NDIHelperPacket: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case hello, accepted, ready, status, route, render, media, audio, audioAccepted, audioFrame, rendered, frame, failure, ping, pong, fault, stop, shutdownComplete, shutdownAccepted }
    let kind: Kind
    let generation: UUID
    var revision: UInt64 = 0
    var contentEpoch: UInt64 = 0
    var version: Int = NDIHelperWire.version
    var build: String = NDIHelperWire.build
    var request: NDITextRenderRequest? = nil
    var detail: String? = nil
    var token: UUID? = nil
    var status: NDIHelperStatus? = nil
    var media: NDIMediaRenderRequest? = nil
    var audio: NDIAudioBlock? = nil
    var observation: NDIAudioObservation? = nil
    var shutdown: NDIHelperShutdown? = nil
}

/// Emitted only after the SDK's terminal send, flush and sender destruction
/// return. This proves sender cleanup, independently of receiver buffering.
nonisolated struct NDIHelperShutdown: Codable, Sendable {
    // The actual packed pixel submitted, or nil if startup created no sender.
    let terminalPixelBGRA: UInt32?
}

nonisolated struct NDIAudioObservation: Codable, Sendable {
    let samples: Int
    let sampleRate: Int
    let timecode: Int64
    let left: Double
    let right: Double
    var isValid: Bool { (1...8192).contains(samples) && sampleRate == 48000 && timecode >= 0 && left.isFinite && right.isFinite }
}

nonisolated struct NDIAudioBlock: Codable, Sendable {
    static let samples = 960
    let sampleTime: Int64
    let pcm: Data // Two planar float32 channels, 48 kHz, exactly 20 ms.
    var isValid: Bool {
        guard sampleTime >= 0, sampleTime < Int64.max / 1000, pcm.count == Self.samples * 2 * 4 else { return false }
        return pcm.withUnsafeBytes { bytes in
            stride(from: 0, to: bytes.count, by: 4).allSatisfy {
                let value = bytes.loadUnaligned(fromByteOffset: $0, as: Float.self)
                return value.isFinite && abs(value) <= 1
            }
        }
    }
}

nonisolated struct NDIMediaRenderRequest: Codable, Equatable, Sendable {
    let generation: UUID
    var revision: UInt64
    var contentEpoch: UInt64 = 0
    var text: NDITextRenderRequest? = nil
    var foreground = false
    var background = false
    var foregroundFill = false
    var backgroundFill = false
    var dimming: Double = 0
    var colour = OutputColour.black
    var foregroundGeometry: NDIMediaGeometry? = nil
    var backgroundGeometry: NDIMediaGeometry? = nil
    var producedAtNanoseconds: UInt64 = 0
    var isValid: Bool {
        (text?.isValid ?? true) && (text == nil || (!foreground && text?.generation == generation && text?.transparent == true))
            && dimming.isFinite && (0...1).contains(dimming)
            && [colour.red, colour.green, colour.blue, colour.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && (foregroundGeometry?.isValid ?? true) && (backgroundGeometry?.isValid ?? true)
    }
}

/// Display size and inverse normalized texture coordinates. Crop, pixel aspect,
/// rotation and mirroring survive IOSurface transfer without changing playback.
nonisolated struct NDIMediaGeometry: Codable, Equatable, Sendable {
    var width: Double
    var height: Double
    var a: Double = 1
    var b: Double = 0
    var c: Double = 0
    var d: Double = 1
    var tx: Double = 0
    var ty: Double = 0
    var isValid: Bool {
        width.isFinite && height.isFinite && (0.01...65536).contains(width) && (0.01...65536).contains(height)
            && [a, b, c, d, tx, ty].allSatisfy { $0.isFinite && abs($0) <= 8192 }
            && abs(a * d - b * c) > 0.00000001
    }
    init(width: Double, height: Double) { self.width = width; self.height = height }
    init(pixelBuffer: CVPixelBuffer, transform: CGAffineTransform) {
        let full = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        let clean = CVImageBufferGetCleanRect(pixelBuffer).intersection(full)
        let crop = clean.isEmpty ? full : clean
        let display = CVImageBufferGetDisplaySize(pixelBuffer)
        let aspect = CGAffineTransform(scaleX: display.width > 0 ? display.width / crop.width : 1,
                                       y: display.height > 0 ? display.height / crop.height : 1)
        let presentation = aspect.concatenating(transform)
        let bounds = crop.applying(presentation).standardized
        let inverse = presentation.inverted()
        width = bounds.width; height = bounds.height
        a = inverse.a * bounds.width / full.width
        b = inverse.b * bounds.width / full.height
        c = inverse.c * bounds.height / full.width
        d = inverse.d * bounds.height / full.height
        tx = (inverse.a * bounds.minX + inverse.c * bounds.minY + inverse.tx) / full.width
        ty = (inverse.b * bounds.minX + inverse.d * bounds.minY + inverse.ty) / full.height
    }
    var uniforms: [Float] { [width, height, a, b, c, d, tx, ty].map(Float.init) }
}

/// Retain the CVPixelBuffer, not just its IOSurface: a decoder pool may reuse a
/// surface as soon as its pixel buffer is released. The in-flight job owns both.
nonisolated final class NDIFrameResource: @unchecked Sendable {
    let surface: IOSurface
    let pixelBuffer: CVPixelBuffer?
    let geometry: NDIMediaGeometry?
    init(surface: IOSurface) { self.surface = surface; pixelBuffer = nil; geometry = nil }
    init?(pixelBuffer: CVPixelBuffer, transform: CGAffineTransform = .identity) {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue(), NDIHelperWire.validMedia(surface) else { return nil }
        let geometry = NDIMediaGeometry(pixelBuffer: pixelBuffer, transform: transform)
        guard geometry.isValid else { return nil }
        self.surface = surface; self.pixelBuffer = pixelBuffer; self.geometry = geometry
    }
}
nonisolated struct NDIMediaSubmission: Sendable {
    var request: NDIMediaRenderRequest
    var foreground: NDIFrameResource?
    var background: NDIFrameResource?
    var isValid: Bool {
        request.isValid && request.foreground == (foreground != nil) && request.background == (background != nil)
            && (foreground.map { NDIHelperWire.validMedia($0.surface) } ?? true)
            && (background.map { NDIHelperWire.validMedia($0.surface) } ?? true)
    }
}
