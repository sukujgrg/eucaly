@preconcurrency import AVFoundation
import QuartzCore

/// A workspace's media runtime owns acquisition, while each destination leases
/// its inputs. Removing one destination never detaches another one's output.
@MainActor
final class NDISharedVideoFrames {
    private struct Key: Hashable {
        let player: ObjectIdentifier
        let item: ObjectIdentifier?
    }
    private struct Entry {
        let source: NDIVideoFrameSource
        var consumers: Set<UUID>
    }
    private var entries: [Key: Entry] = [:]
    var sourceCount: Int { entries.count }

    func acquire(_ player: AVPlayer) -> NDIVideoFrameLease {
        let key = Key(player: ObjectIdentifier(player), item: player.currentItem.map(ObjectIdentifier.init))
        let consumer = UUID()
        let source: NDIVideoFrameSource
        if var entry = entries[key] {
            source = entry.source; entry.consumers.insert(consumer); entries[key] = entry
        } else {
            source = NDIVideoFrameSource(player: player)
            entries[key] = .init(source: source, consumers: [consumer])
        }
        return NDIVideoFrameLease(source: source) { [weak self, weak source] in
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
final class NDIVideoFrameLease {
    nonisolated let source: NDIVideoFrameSource
    private var releaseAction: (@MainActor @Sendable () -> Void)?
    init(source: NDIVideoFrameSource, release: @escaping @MainActor @Sendable () -> Void) {
        self.source = source; releaseAction = release
    }
    nonisolated var item: AVPlayerItem? { source.item }
    nonisolated func latest() throws -> NDIFrameResource? { try source.latest() }
    func release() { let action = releaseAction; releaseAction = nil; action?() }
    deinit {
        // Explicit release handles normal teardown; a discarded broker/plan
        // still relinquishes its lease without calling AVFoundation off-main.
        if let releaseAction { Task { @MainActor in releaseAction() } }
    }
}

/// Select the format before attaching an output. Unknown codecs, alpha, wide
/// colour and compositions keep AVFoundation's established BGRA conversion.
nonisolated enum NDIVideoInputPolicy {
    static func prefersNV12(_ formats: [CMFormatDescription], composed: Bool) -> Bool {
        !composed && !formats.isEmpty && formats.allSatisfy { format in
            let codec = CMFormatDescriptionGetMediaSubType(format)
            guard codec == kCMVideoCodecType_H264 || codec == kCMVideoCodecType_HEVC,
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
            return NDIMediaInput.Matrix.attachments[matrix] != nil
                && NDIMediaInput.supportsPlanarColour(primaries: primaries, transfer: transfer)
                && fields == 1 && (bottomChroma == nil || bottomChroma == chroma)
                && (chroma.map { NDIMediaInput.ChromaLocation.attachments[$0] != nil } ?? true)
        }
    }
}

/// Several destination clocks can call latest(). Acquisition and its cache are
/// serialized off-main; the state lock never encloses an AVFoundation call.
/// Stop closes admission immediately and defers detachment until reads finish.
nonisolated final class NDIVideoFrameSource: @unchecked Sendable {
    let player: AVPlayer
    let item: AVPlayerItem?
    private let lock = NSLock()
    private let samplingQueue = DispatchQueue(label: "com.suku.eucaly.ndi.video-sampling", qos: .userInitiated)
    private var output: AVPlayerItemVideoOutput?
    // Sampling queue only. UI teardown never waits for this queue or clears its cache.
    private var cached: NDIFrameResource?
    private var previousTime: CMTime = .invalid
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private var transform: CGAffineTransform?
    private var preparationFailed = false
    private var stopped = false
    @MainActor private var preparation: Task<Void, Never>?

    @MainActor init(player: AVPlayer,
                    makeOutput: @escaping @MainActor @Sendable (OSType) -> AVPlayerItemVideoOutput = { format in
        AVPlayerItemVideoOutput(outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            AVVideoAllowWideColorKey: false
        ])
    }) {
        self.player = player; item = player.currentItem
        preparation = Task { [weak self, item] in
            do {
                guard let item else { throw Failure.format }
                let tracks = try await item.asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else { throw Failure.format }
                let transform = try await track.load(.preferredTransform)
                let formats = try await track.load(.formatDescriptions)
                guard !Task.isCancelled, let self else { return }
                let nv12 = NDIVideoInputPolicy.prefersNV12(formats, composed: item.videoComposition != nil || tracks.count != 1)
                let output = makeOutput(nv12 ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA)
                output.suppressesPlayerRendering = false
                self.install(output, transform: transform)
            } catch { if !Task.isCancelled { self?.markPreparationFailed() } }
        }
    }
    @MainActor private func install(_ output: AVPlayerItemVideoOutput, transform: CGAffineTransform) {
        guard lock.withLock({ !stopped }), player.currentItem === item else { return }
        item?.add(output); output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        let accepted = lock.withLock {
            guard !stopped else { return false }
            self.output = output; self.transform = transform; return true
        }
        if !accepted { item?.remove(output) }
    }
    private func markPreparationFailed() { lock.withLock { preparationFailed = true } }
    @MainActor func stop() {
        preparation?.cancel(); preparation = nil
        let old: AVPlayerItemVideoOutput? = lock.withLock {
            stopped = true
            let old = output; output = nil; return old
        }
        samplingQueue.async { [self] in
            cached = nil
            if let old {
                let item = item
                DispatchQueue.main.async { item?.remove(old) }
            }
        }
    }
    func latest() throws -> NDIFrameResource? {
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
    private func sample() throws -> NDIFrameResource? {
        let state = lock.withLock { (stopped: stopped, failed: preparationFailed, output: output, transform: transform) }
        guard !state.stopped, player.currentItem === item else { cached = nil; return nil }
        if state.failed { throw Failure.format }
        guard let output = state.output, let transform = state.transform else {
            if ProcessInfo.processInfo.systemUptime - lastFrame > 5 { throw Failure.decoder }
            return nil
        }
        if item?.status == .failed { throw Failure.decoder }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        if previousTime.isNumeric && time.isNumeric && time < previousTime { cached = nil }
        previousTime = time
        if time.isNumeric, output.hasNewPixelBuffer(forItemTime: time), let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            guard let frame = NDIFrameResource(pixelBuffer: buffer, transform: transform) else { throw Failure.format }
            cached = frame; lastFrame = ProcessInfo.processInfo.systemUptime
        } else if player.rate != 0 && ProcessInfo.processInfo.systemUptime - lastFrame > 5 { throw Failure.decoder }
        else if player.rate == 0 { lastFrame = ProcessInfo.processInfo.systemUptime }
        return cached
    }
    enum Failure: Error { case decoder, format }
    deinit {
        let item = item, output = output
        if let output { DispatchQueue.main.async { item?.remove(output) } }
    }
}
