import Foundation
import IOSurface
import CoreVideo

/// No SDK types, AVPlayer, bookmarks, file paths or observable state cross IPC.
/// The schema is shared by the app and its separately linked helper executable.
nonisolated enum NetworkHelperWire {
    static let version = 17
    static let build = "network-omt-1"
    static let maximumMessageBytes = 65_536
    static let maximumAudioBlocks = 8
    // Audio acknowledgements share the four-slot reply port with one render
    // acknowledgement; ownership/status/shutdown use the control port.
    static let maximumInFlightAudioBlocks = 3
    static let width = 1920
    static let height = 1080
    static let maximumSurfaceBytes = width * height * 4

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
    static func validPackedVideo(_ surface: IOSurface) -> Bool {
        guard let format = NetworkVideoPixelFormat(rawValue: surface.pixelFormat), format != .bgra else { return false }
        return surface.width == width && surface.height == height && surface.bytesPerElement == 2
            && surface.bytesPerRow == width * 2 && surface.allocationSize == format.byteCount && surface.planeCount == 0
    }
    static func validMedia(_ surface: IOSurface) -> Bool {
        guard (1...4096).contains(surface.width), (1...4096).contains(surface.height),
              surface.allocationSize <= 67_108_864 else { return false }
        if surface.pixelFormat == kCVPixelFormatType_32BGRA {
            return surface.bytesPerElement == 4 && surface.planeCount == 0
                && surface.bytesPerRow >= surface.width * 4 && surface.bytesPerRow <= 16_384
                && surface.allocationSize >= surface.bytesPerRow * surface.height
        }
        guard surface.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || surface.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              surface.width.isMultiple(of: 2), surface.height.isMultiple(of: 2), surface.planeCount == 2 else { return false }
        var previousEnd = 0
        for plane in 0..<2 {
            let width = surface.widthOfPlane(at: plane), height = surface.heightOfPlane(at: plane)
            let stride = surface.bytesPerRowOfPlane(at: plane)
            let offset = surface.baseAddress.distance(to: surface.baseAddressOfPlane(at: plane))
            guard width == surface.width / (plane == 0 ? 1 : 2), height == surface.height / (plane == 0 ? 1 : 2),
                  surface.bytesPerElementOfPlane(at: plane) == (plane == 0 ? 1 : 2),
                  (surface.width...16_384).contains(stride), offset >= previousEnd,
                  offset <= surface.allocationSize, stride * height <= surface.allocationSize - offset else { return false }
            previousEnd = offset + stride * height
        }
        return true
    }
}

/// Pixel layout and colour interpretation travel with each immutable input.
/// Only SDR 601/709 NV12 enters the planar path; other video retains BGRA.
nonisolated struct NetworkMediaInput: Codable, Equatable, Sendable {
    enum Format: String, Codable, Sendable { case bgra, nv12VideoRange, nv12FullRange }
    enum Matrix: String, Codable, Sendable {
        case rec601, rec709
        static let attachments: [String: Matrix] = [kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String: .rec601,
                                                    kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String: .rec709]
    }
    enum ChromaLocation: String, Codable, Sendable {
        case center, left, topLeft, top, bottomLeft, bottom
        static let attachments: [String: ChromaLocation] = [kCVImageBufferChromaLocation_Center as String: .center,
            kCVImageBufferChromaLocation_Left as String: .left, kCVImageBufferChromaLocation_TopLeft as String: .topLeft,
            kCVImageBufferChromaLocation_Top as String: .top, kCVImageBufferChromaLocation_BottomLeft as String: .bottomLeft,
            kCVImageBufferChromaLocation_Bottom as String: .bottom]
    }
    var format: Format = .bgra
    var matrix: Matrix = .rec709
    var chromaLocation: ChromaLocation = .center
    // BGRA opacity requires a non-alpha image, opaque PDF raster or a proven
    // uncomposed opaque video track. Arbitrary BGRA pixels imply no such proof.
    var opaque = false
    var isOpaque: Bool { opaque || format != .bgra }
    func matches(_ surface: IOSurface) -> Bool {
        guard NetworkHelperWire.validMedia(surface) else { return false }
        switch format {
        case .bgra: return surface.pixelFormat == kCVPixelFormatType_32BGRA
        case .nv12VideoRange: return surface.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .nv12FullRange: return surface.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        }
    }
    var uniforms: [Float] {
        let offset: (Float, Float) = switch chromaLocation {
        case .center: (0, 0)
        case .left: (0.5, 0)
        case .topLeft: (0.5, 0.5)
        case .top: (0, 0.5)
        case .bottomLeft: (0.5, -0.5)
        case .bottom: (0, -0.5)
        }
        return [format == .bgra ? 0 : format == .nv12VideoRange ? 1 : 2,
                matrix == .rec709 ? 0.2126 : 0.299, matrix == .rec709 ? 0.0722 : 0.114, 0,
                offset.0, offset.1, 0, 0]
    }
    init(format: Format = .bgra, matrix: Matrix = .rec709, chromaLocation: ChromaLocation = .center, opaque: Bool = false) {
        self.format = format; self.matrix = matrix; self.chromaLocation = chromaLocation; self.opaque = opaque
    }
    init?(pixelBuffer: CVPixelBuffer) {
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if pixelFormat == kCVPixelFormatType_32BGRA { self.init(); return }
        guard pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                || pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange else { return nil }
        func attachment(_ key: CFString) -> String? {
            CVBufferCopyAttachment(pixelBuffer, key, nil) as? String
        }
        guard Self.supportsPlanarColour(primaries: attachment(kCVImageBufferColorPrimariesKey),
                                       transfer: attachment(kCVImageBufferTransferFunctionKey)) else { return nil }
        let matrix: Matrix
        if let name = attachment(kCVImageBufferYCbCrMatrixKey) {
            guard let value = Matrix.attachments[name] else { return nil }; matrix = value
        } else {
            matrix = CVPixelBufferGetWidth(pixelBuffer) > 720 || CVPixelBufferGetHeight(pixelBuffer) > 576 ? .rec709 : .rec601
        }
        let chroma: ChromaLocation
        if let name = attachment(kCVImageBufferChromaLocationTopFieldKey) {
            guard let value = ChromaLocation.attachments[name] else { return nil }; chroma = value
        } else { chroma = .center }
        self.init(format: pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? .nv12VideoRange : .nv12FullRange,
                  matrix: matrix, chromaLocation: chroma)
    }
    static func supportsPlanarColour(primaries: String?, transfer: String?) -> Bool {
        (primaries == nil || primaries == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
            && (transfer == nil || transfer == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
    }
}

/// IOSurface tags use character order; the helper bridge maps these to the SDK's
/// own FourCC constants. UYVA has a tightly packed, full-resolution alpha plane.
nonisolated enum NetworkVideoPixelFormat: UInt32, Codable, Sendable {
    case bgra = 0x42475241, uyvy = 0x55595659, uyva = 0x55595641
    var bytesPerRow: Int { NetworkHelperWire.width * (self == .bgra ? 4 : 2) }
    var byteCount: Int { NetworkHelperWire.width * NetworkHelperWire.height * (self == .bgra ? 4 : self == .uyva ? 3 : 2) }
    var name: String { self == .bgra ? "BGRA" : self == .uyva ? "UYVA" : "UYVY" }
}

nonisolated struct NetworkHelperBootstrap: Codable {
    let portIndex: Int32
    let generation: UUID
    let version: Int
    let build: String
    let parentPID: Int32
    var configuration = NetworkHelperConfiguration()
}

nonisolated struct NetworkHelperConfiguration: Codable, Sendable {
    enum Purpose: String, Codable, Sendable { case renderOnly, renderYUV, sender, loopbackProbe, audioProbe }
    var purpose: Purpose = .renderOnly
    var sourceName = ""
    var technology: NetworkOutputTechnology = .ndi
    // Debug-only comparison against the previous SDK input path. Never saved or
    // exposed as an operator setting; Release always submits GPU-produced YUV.
    var referenceBGRA = false
    var isValid: Bool {
        #if !DEBUG
        guard !referenceBGRA, purpose != .renderYUV else { return false }
        #endif
        switch purpose {
        case .renderOnly, .renderYUV: return sourceName.isEmpty && !referenceBGRA
        case .sender, .loopbackProbe, .audioProbe:
            return !sourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && sourceName.utf8.count <= (purpose == .sender ? 120 : 512)
                && !sourceName.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }
    }
}

nonisolated struct NetworkHelperStatus: Codable, Sendable {
    var runtimeVersion = ""
    var sourceName = ""
    var submittedFrames: UInt64 = 0
    var lastTimecode: Int64 = 0
    var connections = 0
    var replacedFrames: UInt64 = 0
    var audioBlocks: UInt64 = 0
    var lastAudioSample: Int64 = 0
    var lastAudioSDKReturnBytes: Int32? = nil // OMT enqueue sum; NDI void/unknown.
    var audioSubmissionAgeMilliseconds: Double = 0
    var maximumAudioSubmissionAgeMilliseconds: Double = 0
    var audioSubmissionMilliseconds: Double = 0
    var maximumAudioSubmissionMilliseconds: Double = 0
    var gpuMilliseconds: Double = 0
    var maximumGPUMilliseconds: Double = 0
    var surfacePoolHighWaterMark: Int = 0
    var effectiveFramesPerSecond: Double? = nil
    var frameAgeMilliseconds: Double? = nil
    var submissionMilliseconds: Double = 0
    var slowCadence = false
    var videoFormat: NetworkVideoPixelFormat? = nil
    var processCPUSeconds: Double? = nil // Debug qualification; not a codec-only measurement.
    var omtVideoStatistics: OMTVideoSDKStatistics? = nil
    var omtAudioStatistics: OMTAudioSDKStatistics? = nil
    var omtVideoDiagnostics: OMTVideoSDKDiagnostics? = nil
    #if DEBUG
    var audioCallInProgress: Bool? = nil
    var videoCallInProgress: Bool? = nil
    #endif

    var validMetrics: Bool {
        [effectiveFramesPerSecond, frameAgeMilliseconds, submissionMilliseconds,
         audioSubmissionAgeMilliseconds, maximumAudioSubmissionAgeMilliseconds,
         audioSubmissionMilliseconds, maximumAudioSubmissionMilliseconds].compactMap { $0 }
            .allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000 }
            && (omtVideoStatistics?.isValid ?? true)
            && (omtAudioStatistics?.isValid ?? true)
            && (omtVideoDiagnostics?.isValid ?? true)
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
nonisolated struct NetworkSubmissionMetrics {
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
nonisolated struct NetworkTextRenderRequest: Codable, Equatable, Sendable {
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

nonisolated struct NetworkHelperPacket: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case hello, accepted, ready, status, route, routeAccepted, render, media, audio, audioAccepted, audioFrame, rendered, frame, failure, ping, pong, fault, stop, shutdownComplete, shutdownAccepted }
    let kind: Kind
    let generation: UUID
    var revision: UInt64 = 0
    var contentEpoch: UInt64 = 0
    var version: Int = NetworkHelperWire.version
    var build: String = NetworkHelperWire.build
    var request: NetworkTextRenderRequest? = nil
    var detail: String? = nil
    var token: UUID? = nil
    var status: NetworkHelperStatus? = nil
    var media: NetworkMediaRenderRequest? = nil
    var audio: NetworkAudioBlock? = nil
    var observation: NetworkAudioObservation? = nil
    var shutdown: NetworkHelperShutdown? = nil
}

/// Emitted only after the SDK's terminal send, flush and sender destruction
/// return. This proves sender cleanup, independently of receiver buffering.
nonisolated struct NetworkHelperShutdown: Codable, Sendable {
    // Requested empty/key colour, plus the actual SDK format and packed pair.
    let terminalPixelBGRA: UInt32?
    var videoFormat: NetworkVideoPixelFormat? = nil
    var terminalUYVY: UInt32? = nil
    var terminalAlpha: UInt8? = nil
}

nonisolated struct NetworkAudioObservation: Codable, Sendable {
    let samples: Int
    let sampleRate: Int
    let timecode: Int64
    let receivedAtNanoseconds: UInt64 // Helper's SDK capture boundary, before reply/UI scheduling.
    let left: Double
    let right: Double
    var leftRMS: Double = 0
    var rightRMS: Double = 0
    var droppedFrames: Int64 = 0
    var queuedFrames: Int = 0
    var isValid: Bool {
        (1...8192).contains(samples) && sampleRate == 48000 && timecode >= 0 && receivedAtNanoseconds > 0
            && [left, right, leftRMS, rightRMS].allSatisfy(\.isFinite)
            && leftRMS >= 0 && rightRMS >= 0 && droppedFrames >= 0 && queuedFrames >= 0
    }
}

nonisolated struct NetworkAudioBlock: Codable, Sendable {
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

nonisolated struct NetworkMediaRenderRequest: Codable, Equatable, Sendable {
    let generation: UUID
    var revision: UInt64
    var contentEpoch: UInt64 = 0
    var text: NetworkTextRenderRequest? = nil
    var foreground = false
    var background = false
    var foregroundFill = false
    var backgroundFill = false
    var dimming: Double = 0
    var colour = OutputColour.black
    var foregroundGeometry: NetworkMediaGeometry? = nil
    var backgroundGeometry: NetworkMediaGeometry? = nil
    var foregroundInput = NetworkMediaInput()
    var backgroundInput = NetworkMediaInput()
    var producedAtNanoseconds: UInt64 = 0
    var isValid: Bool {
        (text?.isValid ?? true) && (text == nil || (!foreground && text?.generation == generation && text?.transparent == true))
            && dimming.isFinite && (0...1).contains(dimming)
            && [colour.red, colour.green, colour.blue, colour.alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && (foregroundGeometry?.isValid ?? true) && (backgroundGeometry?.isValid ?? true)
            && (foreground || foregroundInput == NetworkMediaInput()) && (background || backgroundInput == NetworkMediaInput())
    }

    func hasOpaqueCanvas(foreground: IOSurface?, background: IOSurface?) -> Bool {
        func covers(_ surface: IOSurface?, _ geometry: NetworkMediaGeometry?, _ fill: Bool, _ input: NetworkMediaInput) -> Bool {
            guard let surface, input.isOpaque, input.matches(surface) else { return false }
            let geometry = geometry ?? NetworkMediaGeometry(width: Double(surface.width), height: Double(surface.height))
            return geometry.coversCanvas(fill: fill)
        }
        return colour.alpha == 1
            || (self.foreground && covers(foreground, foregroundGeometry, foregroundFill, foregroundInput))
            || (self.background && covers(background, backgroundGeometry, backgroundFill, backgroundInput))
    }
}

/// Display size and inverse normalized texture coordinates. Crop, pixel aspect,
/// rotation and mirroring survive IOSurface transfer without changing playback.
nonisolated struct NetworkMediaGeometry: Codable, Equatable, Sendable {
    var width: Double
    var height: Double
    var a: Double = 1
    var b: Double = 0
    var c: Double = 0
    var d: Double = 1
    var tx: Double = 0
    var ty: Double = 0
    // The valid aperture is expressed in the original texture's normalized
    // coordinates. Rotated bounding boxes contain points outside this crop.
    var cropMinX: Double = 0
    var cropMinY: Double = 0
    var cropMaxX: Double = 1
    var cropMaxY: Double = 1
    var isValid: Bool {
        width.isFinite && height.isFinite && (0.01...65536).contains(width) && (0.01...65536).contains(height)
            && [a, b, c, d, tx, ty].allSatisfy { $0.isFinite && abs($0) <= 8192 }
            && abs(a * d - b * c) > 0.00000001
            && [cropMinX, cropMinY, cropMaxX, cropMaxY].allSatisfy { $0.isFinite && (0...1).contains($0) }
            && cropMinX < cropMaxX && cropMinY < cropMaxY
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
        cropMinX = crop.minX / full.width; cropMinY = crop.minY / full.height
        cropMaxX = crop.maxX / full.width; cropMaxY = crop.maxY / full.height
    }
    func coversCanvas(fill: Bool) -> Bool {
        guard isValid else { return false }
        let canvasWidth = Double(NetworkHelperWire.width), canvasHeight = Double(NetworkHelperWire.height)
        // No tolerance: an almost-matching fit can still have transparent gutters.
        guard fill || width * canvasHeight == height * canvasWidth else { return false }
        let scale = fill ? max(canvasWidth / width, canvasHeight / height) : min(canvasWidth / width, canvasHeight / height)
        let left = (width * scale - canvasWidth) / (2 * width * scale)
        let top = (height * scale - canvasHeight) / (2 * height * scale)
        // The inverse map is affine and the crop is convex, so all four canvas
        // corners must be inside the real aperture to prove opaque coverage.
        // Merely filling the transformed bounding box does not establish this.
        return [(left, top), (1 - left, top), (left, 1 - top), (1 - left, 1 - top)].allSatisfy { x, y in
            let u = a * x + c * y + tx, v = b * x + d * y + ty
            return (cropMinX...cropMaxX).contains(u) && (cropMinY...cropMaxY).contains(v)
        }
    }
    var uniforms: [Float] { [width, height, a, b, c, d, tx, ty, cropMinX, cropMinY, cropMaxX, cropMaxY].map(Float.init) }
}

/// Retain the CVPixelBuffer, not just its IOSurface: a decoder pool may reuse a
/// surface as soon as its pixel buffer is released. The in-flight job owns both.
nonisolated final class NetworkFrameResource: @unchecked Sendable {
    let surface: IOSurface
    let pixelBuffer: CVPixelBuffer?
    let geometry: NetworkMediaGeometry?
    let input: NetworkMediaInput
    init(surface: IOSurface, opaque: Bool = false) {
        self.surface = surface; pixelBuffer = nil; geometry = nil; input = .init(opaque: opaque)
    }
    init?(pixelBuffer: CVPixelBuffer, transform: CGAffineTransform = .identity, provenOpaque: Bool = false) {
        guard let surface = CVPixelBufferGetIOSurface(pixelBuffer)?.takeUnretainedValue(),
              var input = NetworkMediaInput(pixelBuffer: pixelBuffer), input.matches(surface) else { return nil }
        if input.format == .bgra { input.opaque = provenOpaque }
        let geometry = NetworkMediaGeometry(pixelBuffer: pixelBuffer, transform: transform)
        guard geometry.isValid else { return nil }
        self.surface = surface; self.pixelBuffer = pixelBuffer; self.geometry = geometry; self.input = input
    }
}
nonisolated struct NetworkMediaSubmission: Sendable {
    var request: NetworkMediaRenderRequest
    var foreground: NetworkFrameResource?
    var background: NetworkFrameResource?
    var isValid: Bool {
        request.isValid && request.foreground == (foreground != nil) && request.background == (background != nil)
            && (foreground.map { NetworkHelperWire.validMedia($0.surface) } ?? true)
            && (background.map { NetworkHelperWire.validMedia($0.surface) } ?? true)
            && (foreground.map { request.foregroundInput == $0.input && $0.input.matches($0.surface) } ?? true)
            && (background.map { request.backgroundInput == $0.input && $0.input.matches($0.surface) } ?? true)
    }
}
