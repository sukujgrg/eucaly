@preconcurrency import AVFoundation
import VideoToolbox

/// A workspace's media runtime owns acquisition, while each destination leases
/// its inputs. Removing one destination never detaches another one's output.
@MainActor
final class NetworkSharedVideoFrames {
    private struct Key: Hashable {
        let player: ObjectIdentifier
        let item: ObjectIdentifier?
    }
    private struct Entry {
        let source: NetworkVideoFrameSource
        var consumers: Set<UUID>
    }
    private var entries: [Key: Entry] = [:]
    var sourceCount: Int { entries.count }

    func acquire(_ player: AVPlayer) -> NetworkVideoFrameLease {
        let key = Key(player: ObjectIdentifier(player), item: player.currentItem.map(ObjectIdentifier.init))
        let consumer = UUID()
        let source: NetworkVideoFrameSource
        if var entry = entries[key] {
            source = entry.source; entry.consumers.insert(consumer); entries[key] = entry
        } else {
            source = NetworkVideoFrameSource(player: player)
            entries[key] = .init(source: source, consumers: [consumer])
        }
        return NetworkVideoFrameLease(source: source) { [weak self, weak source] in
            guard let self, let source, var entry = self.entries[key], entry.source === source else { return }
            entry.consumers.remove(consumer)
            if entry.consumers.isEmpty { self.entries[key] = nil; source.stop() }
            else { self.entries[key] = entry }
        }
    }
    func stop(player: AVPlayer) {
        for key in Array(entries.keys) where key.player == ObjectIdentifier(player) {
            entries.removeValue(forKey: key)?.source.stop()
        }
    }
    func stop() {
        let old = entries; entries.removeAll()
        for entry in old.values { entry.source.stop() }
    }
}

@MainActor
final class NetworkVideoFrameLease {
    nonisolated let source: NetworkVideoFrameSource
    private var releaseAction: (@MainActor @Sendable () -> Void)?
    init(source: NetworkVideoFrameSource, release: @escaping @MainActor @Sendable () -> Void) {
        self.source = source; releaseAction = release
    }
    nonisolated var item: AVPlayerItem? { source.item }
    nonisolated func latest() throws -> NetworkFrameResource? { try source.latest() }
    func release() { let action = releaseAction; releaseAction = nil; action?() }
    deinit {
        // Explicit release handles normal teardown; a discarded broker/plan
        // still relinquishes its lease without calling AVFoundation off-main.
        if let releaseAction { Task { @MainActor in releaseAction() } }
    }
}

/// Select the format before attaching an output. Unknown codecs, alpha, wide
/// colour and compositions keep AVFoundation's established BGRA conversion.
nonisolated enum NetworkVideoInputPolicy {
    /// Colour conversion and opacity are independent decisions. A plain local
    /// H.264/AV1 track cannot add transparency, even when AVFoundation must
    /// perform its colour conversion into BGRA. Unknown codecs/metadata retain alpha.
    static func provesOpaqueBGRA(_ formats: [CMFormatDescription], localFile: Bool,
                                 composed: Bool, trackContainsAlpha: Bool?) -> Bool {
        guard localFile, !composed, trackContainsAlpha == false, !formats.isEmpty else { return false }
        return formats.allSatisfy { format in
            let codec = CMFormatDescriptionGetMediaSubType(format)
            guard CMFormatDescriptionGetMediaType(format) == kCMMediaType_Video,
                  codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_AV1,
                  CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_AlphaChannelMode) == nil else { return false }
            if let alpha = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) {
                guard let containsAlpha = alpha as? Bool, !containsAlpha else { return false }
            }
            return true
        }
    }

    static func prefersNV12(_ formats: [CMFormatDescription], composed: Bool) -> Bool {
        !composed && !formats.isEmpty && formats.allSatisfy { format in
            let codec = CMFormatDescriptionGetMediaSubType(format)
            guard codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC || codec == kCMVideoCodecType_AV1,
                  CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool != true else { return false }
            func value(_ key: CFString) -> String? { CMFormatDescriptionGetExtension(format, extensionKey: key) as? String }
            // Untagged SD video may acquire guessed SMPTE-C primaries only
            // after decoding. Leave those conversions to AVFoundation rather
            // than guessing a colour space or switching outputs after failure.
            guard let matrix = value(kCMFormatDescriptionExtension_YCbCrMatrix),
                  let primaries = value(kCMFormatDescriptionExtension_ColorPrimaries),
                  let transfer = value(kCMFormatDescriptionExtension_TransferFunction) else { return false }
            let chroma = value(kCMFormatDescriptionExtension_ChromaLocationTopField)
            let bottomChroma = value(kCMFormatDescriptionExtension_ChromaLocationBottomField)
            let fields = CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FieldCount) as? Int ?? 1
            return NetworkMediaInput.Matrix.attachments[matrix] != nil
                && NetworkMediaInput.supportsPlanarColour(primaries: primaries, transfer: transfer)
                && fields == 1 && (bottomChroma == nil || bottomChroma == chroma)
                && (chroma.map { NetworkMediaInput.ChromaLocation.attachments[$0] != nil } ?? true)
        }
    }

    /// Apple AV1 decode is hardware-only. Unsupported hosts must fail before the
    /// sampler waits for frames that can never arrive.
    static func supportsHardwareDecode(_ formats: [CMFormatDescription]) -> Bool {
        formats.allSatisfy { format in
            let codec = CMFormatDescriptionGetMediaSubType(format)
            guard codec == kCMVideoCodecType_AV1 else { return true }
            return VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)
        }
    }
}

/// Several destination clocks can call latest(). Acquisition and its cache are
/// serialized off-main; the state lock never encloses an AVFoundation call.
/// Stop closes admission immediately and defers detachment until reads finish.
nonisolated final class NetworkVideoFrameSource: @unchecked Sendable {
    let player: AVPlayer
    let item: AVPlayerItem?
    private let lock = NSLock()
    private let samplingQueue = DispatchQueue(label: "com.suku.eucaly.network.video-sampling", qos: .userInitiated)
    private var output: AVPlayerVideoOutput?
    // Sampling queue only. UI teardown never waits for this queue or clears its cache.
    private var cached: NetworkFrameResource?
    private var previousTime: CMTime = .invalid
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private var transform: CGAffineTransform?
    private var provenOpaque = false
    private var preparationFailure: Failure?
    private var stopped = false
    private let sampleHook: (@Sendable () -> Void)?
    @MainActor private var preparation: Task<Void, Never>?

    @MainActor init(
        player: AVPlayer,
        makeOutput: @escaping @MainActor @Sendable (OSType) -> AVPlayerVideoOutput = { NetworkVideoFrameSource.makeOutput(pixelFormat: $0) },
        sampleHook: (@Sendable () -> Void)? = nil
    ) {
        self.player = player
        item = player.currentItem
        self.sampleHook = sampleHook
        preparation = Task { [weak self, item] in
            do {
                guard let item else { throw Failure.format }
                let tracks = try await item.asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { throw Failure.format }
                let transform = try await track.load(.preferredTransform)
                let formats = try await track.load(.formatDescriptions)
                guard NetworkVideoInputPolicy.supportsHardwareDecode(formats) else { throw Failure.decoder }
                // Failure to establish opacity keeps the existing alpha path;
                // it must not turn an optional optimization into decode failure.
                let characteristics = try? await track.load(.mediaCharacteristics)
                guard !Task.isCancelled, let self else { return }
                let composed = item.asset is AVComposition || item.videoComposition != nil || tracks.count != 1
                let nv12 = characteristics?.contains(.containsAlphaChannel) != true
                    && NetworkVideoInputPolicy.prefersNV12(formats, composed: composed)
                let opaque = NetworkVideoInputPolicy.provesOpaqueBGRA(formats,
                    localFile: (item.asset as? AVURLAsset)?.url.isFileURL == true,
                    composed: composed, trackContainsAlpha: characteristics?.contains(.containsAlphaChannel))
                let output = makeOutput(nv12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA)
                self.install(output, transform: transform, provenOpaque: opaque)
            } catch let failure as Failure {
                if !Task.isCancelled { self?.markPreparationFailed(failure) }
            } catch {
                if !Task.isCancelled { self?.markPreparationFailed(.format) }
            }
        }
    }

    @MainActor static func makeOutput(pixelFormat: OSType) -> AVPlayerVideoOutput {
        let tags = [CMTag].monoscopicForVideoOutput()
        let specification = AVVideoOutputSpecification(tagCollections: [tags])
        let settings: [String: any Sendable] = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            AVVideoAllowWideColorKey: false
        ]
        specification.setOutputSettings(settings, for: tags)
        specification.defaultOutputSettings = settings
        return AVPlayerVideoOutput(specification: specification)
    }

    @MainActor private func install(_ output: AVPlayerVideoOutput, transform: CGAffineTransform, provenOpaque: Bool) {
        guard lock.withLock({ !stopped }), player.currentItem === item else { return }
        player.videoOutput = output
        let accepted = lock.withLock {
            guard !stopped else { return false }
            self.output = output; self.transform = transform; self.provenOpaque = provenOpaque; return true
        }
        if !accepted, player.videoOutput === output { player.videoOutput = nil }
    }
    private func markPreparationFailed(_ failure: Failure) {
        lock.withLock { preparationFailure = failure }
    }
    @MainActor func stop() {
        preparation?.cancel(); preparation = nil
        let old: AVPlayerVideoOutput? = lock.withLock {
            stopped = true
            let old = output; output = nil; return old
        }
        samplingQueue.async { [self] in
            cached = nil
            if let old {
                let player = player
                DispatchQueue.main.async {
                    if player.videoOutput === old { player.videoOutput = nil }
                }
            }
        }
    }
    func latest() throws -> NetworkFrameResource? {
        try samplingQueue.sync {
            do {
                let frame = try sample()
                return lock.withLock({ stopped }) || player.currentItem !== item ? nil : frame
            } catch {
                if lock.withLock({ stopped }) || player.currentItem !== item { return nil }
                throw error
            }
        }
    }
    private func sample() throws -> NetworkFrameResource? {
        let state = lock.withLock {
            (stopped: stopped, failure: preparationFailure, output: output, transform: transform, provenOpaque: provenOpaque)
        }
        guard !state.stopped, player.currentItem === item else { cached = nil; return nil }
        if let failure = state.failure { throw failure }
        guard let output = state.output, let transform = state.transform else {
            if ProcessInfo.processInfo.systemUptime - lastFrame > 5 { throw Failure.decoder }
            return nil
        }
        if item?.status == .failed { throw Failure.decoder }
        sampleHook?()
        if lock.withLock({ stopped }) || player.currentItem !== item { return nil }
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        guard let sample = output.sample(forHostTime: hostTime) else {
            if player.rate != 0 && ProcessInfo.processInfo.systemUptime - lastFrame > 5 { throw Failure.decoder }
            if player.rate == 0 { lastFrame = ProcessInfo.processInfo.systemUptime }
            return cached
        }
        let presentationTime = sample.presentationTime
        if previousTime.isNumeric && presentationTime.isNumeric && presentationTime < previousTime { cached = nil }
        previousTime = presentationTime
        let sampleTransform = sample.activeConfiguration.preferredTransform
        let resolvedTransform = sampleTransform == .identity ? transform : sampleTransform
        guard let buffer = Self.pixelBuffer(from: sample.taggedBuffers),
              let frame = NetworkFrameResource(pixelBuffer: buffer, transform: resolvedTransform, provenOpaque: state.provenOpaque) else {
            throw Failure.format
        }
        cached = frame; lastFrame = ProcessInfo.processInfo.systemUptime
        return cached
    }

    private static func pixelBuffer(from taggedBuffers: [CMTaggedDynamicBuffer]) -> CVPixelBuffer? {
        for tagged in taggedBuffers {
            if case .pixelBuffer(let readOnly) = tagged.content {
                return readOnly.withUnsafeBuffer { buffer in buffer }
            }
        }
        return nil
    }

    enum Failure: Error { case decoder, format }
    deinit {
        let player = player, output = output
        if let output {
            DispatchQueue.main.async {
                if player.videoOutput === output { player.videoOutput = nil }
            }
        }
    }
}
