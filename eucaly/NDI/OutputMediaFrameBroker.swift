@preconcurrency import AVFoundation
import IOSurface
import ImageIO
import QuartzCore

/// Immutable local render intent. URLs and players remain in the host; only
/// validated surface capabilities and small composition values enter the helper.
nonisolated struct OutputRenderSnapshot: Sendable {
    let workspace: UUID?
    let revision: UInt64
    let visible: Bool
    let profile: OutputProfile
    let geometry: CGSize
    let foreground: OutputPreparedMedia.Key?
    let background: OutputPreparedMedia.Key?
}

@MainActor
final class OutputMediaFrameBroker {
    private let generation: UUID
    private let clock: NDIMediaFrameClock
    private let prepared = OutputPreparedMedia()
    private var players: [ObjectIdentifier: NDIVideoFrameSource] = [:]
    private var requested: [Int: OutputPreparedMedia.Key] = [:]
    private var pictures: [Int: NDIFrameResource] = [:]
    private var plan: NDIMediaFrameClock.Plan?
    private let failure: @MainActor (String) -> Void
    private var stopped = false

    init(generation: UUID, deliver: @escaping @Sendable (NDIMediaSubmission) -> Void, failure: @escaping @MainActor (String) -> Void) {
        self.generation = generation; self.failure = failure
        clock = NDIMediaFrameClock(deliver: deliver) { reason in Task { @MainActor in failure(reason) } }
    }
    func update(_ snapshot: OutputContentSnapshot, profile: OutputProfile, runtime: OutputMediaRuntime, keyMode: NDIOutputSettings.KeyMode = .alpha) {
        guard !stopped else { return }
        let supported = !snapshot.visible || (snapshot.localMedia.map(OutputContentClassifier.supportsNDI) ?? true)
        let slide = snapshot.visible && supported ? snapshot.localMedia : nil
        let media = slide.map { OutputContentClassifier.mode(for: $0) == .media } ?? false
        let background = profile.background
        let showBackground = supported && background.visible && (!snapshot.visible ? background.whenHidden : media ? background.whenMediaShown : background.whenTextShown)
        let backgroundURL = showBackground ? runtime.backgroundURL(for: profile) : nil
        let foregroundKey: OutputPreparedMedia.Key? = slide.flatMap {
            if let url = $0.imageURL { return .init(url: url, page: nil, identity: "\(snapshot.source?.uuidString ?? ""):\($0.id):\(snapshot.revision)") }
            if let url = $0.pdfURL { return .init(url: url, page: $0.pdfPageIndex ?? 0, identity: "\(snapshot.source?.uuidString ?? ""):\($0.id):\(snapshot.revision)") }
            return nil
        }
        let backgroundKey = backgroundURL.flatMap { OutputMediaRuntime.isVideo($0) ? nil : OutputPreparedMedia.Key(url: $0, page: nil, identity: "\(snapshot.source?.uuidString ?? ""):\(profile.id):\(snapshot.revision)") }
        let intent = OutputRenderSnapshot(workspace: snapshot.source, revision: snapshot.revision,
            visible: snapshot.visible, profile: profile, geometry: .init(width: 1920, height: 1080), foreground: foregroundKey, background: backgroundKey)
        var required: Set<ObjectIdentifier> = []
        func source(_ player: AVPlayer?) -> NDIVideoFrameSource? {
            guard let player else { return nil }
            let key = ObjectIdentifier(player); required.insert(key)
            if let old = players[key], old.item === player.currentItem { return old }
            players[key]?.detach()
            let value = NDIVideoFrameSource(player: player); players[key] = value; return value
        }
        let foregroundVideo = source(slide?.videoURL != nil ? runtime.program : nil)
        let backgroundVideo = source(backgroundURL.map(OutputMediaRuntime.isVideo) == true ? runtime.backgroundPlayer(for: profile) : nil)
        for key in Array(players.keys) where !required.contains(key) { players.removeValue(forKey: key)?.detach() }
        request(intent.foreground, slot: 0); request(intent.background, slot: 1)
        var textProfile = profile; textProfile.background.bookmark = nil; textProfile.usesLegacySizing = false
        let text = snapshot.visible && supported && !snapshot.current.isEmpty
            ? NDITextRenderRequest(generation: generation, revision: 0, text: snapshot.current, profile: textProfile, transparent: true) : nil
        let request = NDIMediaRenderRequest(generation: generation, revision: 0, text: text,
            foregroundFill: slide?.videoURL != nil && runtime.programFill,
            backgroundFill: background.fit == "fill", dimming: background.dimming,
            colour: keyMode == .chroma ? background.colour : .init(alpha: 0))
        guard request.isValid else { failure("NDI render state exceeds the supported limits."); return }
        plan = .init(request: request, foregroundVideo: foregroundVideo, backgroundVideo: backgroundVideo)
        refreshPlan()
    }
    private func request(_ key: OutputPreparedMedia.Key?, slot: Int) {
        guard requested[slot] != key else { return }
        let previous = requested[slot]
        if key == nil || previous?.url != key?.url || previous?.page != key?.page { pictures[slot] = nil }
        requested[slot] = key
        prepared.request(key, slot: slot) { [weak self] key, frame, error in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.requested[slot] == key else { return }
                if let error { self.failure(error); return }
                self.pictures[slot] = frame; self.refreshPlan()
            }
        }
    }
    private func refreshPlan() {
        guard var plan, !stopped else { return }
        plan.foreground = pictures[0]; plan.background = pictures[1]
        clock.update(plan)
    }
    func stop() {
        guard !stopped else { return }; stopped = true
        clock.stop(); prepared.stop()
        for source in players.values { source.detach() }
        players.removeAll(); pictures.removeAll(); requested.removeAll(); plan = nil
    }
    func forceNextFrame() { clock.forceNextFrame() }
}

nonisolated private final class NDIVideoFrameSource: @unchecked Sendable {
    let player: AVPlayer
    let item: AVPlayerItem?
    private let output: AVPlayerItemVideoOutput
    private var cached: NDIFrameResource?
    private var previousTime: CMTime = .invalid
    private var lastFrame = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var transform: CGAffineTransform?
    private var preparationFailed = false
    @MainActor private var preparation: Task<Void, Never>?
    @MainActor init(player: AVPlayer) {
        self.player = player; item = player.currentItem
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int](), kCVPixelBufferMetalCompatibilityKey as String: true
        ])
        output.suppressesPlayerRendering = false
        item?.add(output); output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.03)
        preparation = Task { [weak self, item] in
            do {
                guard let item, let track = try await item.asset.loadTracks(withMediaType: .video).first else { throw Failure.format }
                let transform = try await track.load(.preferredTransform)
                guard !Task.isCancelled else { return }
                self?.setTransform(transform)
            } catch { if !Task.isCancelled { self?.setTransform(nil) } }
        }
    }
    private func setTransform(_ value: CGAffineTransform?) {
        lock.lock(); transform = value; preparationFailed = value == nil; lock.unlock()
    }
    @MainActor func detach() { preparation?.cancel(); preparation = nil; item?.remove(output) }
    // Only the media clock reads/mutates the cached frame. AVFoundation's video
    // output maps the same player's host timeline; no second AVPlayer is created.
    func latest() throws -> NDIFrameResource? {
        lock.lock(); let transform = transform, failed = preparationFailed; lock.unlock()
        if failed { throw Failure.format }
        guard let transform else {
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
}

/// Timer callbacks coalesce on a dedicated queue. Host-side handoff is latest
/// only; the supervisor retains one pending and one in-flight pair of buffers.
nonisolated private final class NDIMediaFrameClock: @unchecked Sendable {
    struct Plan: Sendable {
        var request: NDIMediaRenderRequest
        var foregroundVideo: NDIVideoFrameSource?
        var backgroundVideo: NDIVideoFrameSource?
        var foreground: NDIFrameResource?
        var background: NDIFrameResource?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.suku.eucaly.ndi.media-clock", qos: .userInitiated)
    private var plan: Plan?
    private var planVersion: UInt64 = 0
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var revision: UInt64 = 0
    private var previousRequest: NDIMediaRenderRequest?
    private var previousForeground: NDIFrameResource?
    private var previousBackground: NDIFrameResource?
    private let deliver: @Sendable (NDIMediaSubmission) -> Void
    private let failure: @Sendable (String) -> Void
    init(deliver: @escaping @Sendable (NDIMediaSubmission) -> Void, failure: @escaping @Sendable (String) -> Void) {
        self.deliver = deliver; self.failure = failure
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 30), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
        }
    }
    func update(_ plan: Plan) { lock.lock(); if !stopped { self.plan = plan; planVersion &+= 1 }; lock.unlock() }
    func forceNextFrame() { queue.async { [self] in previousRequest = nil; tick() } }
    func stop() {
        lock.lock(); stopped = true; plan = nil; lock.unlock()
        queue.async { [self] in timer?.cancel(); timer = nil; previousForeground = nil; previousBackground = nil }
    }
    private func tick() {
        lock.lock(); let value = stopped ? nil : plan, version = planVersion; lock.unlock()
        guard let value else { return }
        do {
            let foreground = try value.foregroundVideo?.latest() ?? value.foreground
            let background = try value.backgroundVideo?.latest() ?? value.background
            var request = value.request; request.foreground = foreground != nil; request.background = background != nil
            request.foregroundGeometry = foreground?.geometry; request.backgroundGeometry = background?.geometry
            guard request != previousRequest || foreground !== previousForeground || background !== previousBackground else { return }
            lock.lock(); defer { lock.unlock() }
            // Commit the cache only with the admitted plan. A superseded tick
            // must not suppress the replacement plan's identical first frame.
            guard !stopped, version == planVersion else { return }
            previousRequest = request; previousForeground = foreground; previousBackground = background
            revision &+= 1; request = .init(generation: request.generation, revision: revision, contentEpoch: request.contentEpoch, text: request.text,
                foreground: request.foreground, background: request.background, foregroundFill: request.foregroundFill,
                backgroundFill: request.backgroundFill, dimming: request.dimming, colour: request.colour,
                foregroundGeometry: request.foregroundGeometry, backgroundGeometry: request.backgroundGeometry,
                producedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
            deliver(.init(request: request, foreground: foreground, background: background))
        } catch {
            lock.lock()
            let current = !stopped && version == planVersion
            if current { stopped = true; plan = nil }
            lock.unlock()
            if current { stop(); failure("NDI could not read the shared video frame. Use an SDR video file and choose Retry.") }
        }
    }
}

/// One preparation worker, two latest slots, two retained static pictures.
/// Rapid navigation cannot enqueue an unbounded set of PDF/image decoders.
nonisolated final class OutputPreparedMedia: @unchecked Sendable {
    struct Key: Equatable, Sendable { let url: URL; let page: Int?; let identity: String }
    private struct Work: Sendable { let key: Key; let result: @Sendable (Key, NDIFrameResource?, String?) -> Void }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.suku.eucaly.ndi.prepare-media", qos: .userInitiated)
    private var pending: [Int: Work] = [:]
    private var scheduled = false
    private struct Cache { let url: URL; let page: Int?; let modified: Date?; let size: UInt64; let frame: NDIFrameResource }
    private var cache: [Int: Cache] = [:] // Preparation queue only, at most two entries.
    private var stopped = false
    func request(_ key: Key?, slot: Int, result: @escaping @Sendable (Key, NDIFrameResource?, String?) -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, (0...1).contains(slot) else { return }
        pending[slot] = key.map { Work(key: $0, result: result) }
        guard !scheduled, !pending.isEmpty else { return }
        scheduled = true; queue.async { [self] in drain() }
    }
    func stop() { lock.lock(); stopped = true; pending.removeAll(); lock.unlock(); queue.async { [self] in cache.removeAll() } }
    private func drain() {
        while true {
            lock.lock()
            guard !stopped, let slot = pending.keys.min(), let work = pending.removeValue(forKey: slot) else {
                scheduled = false; lock.unlock(); return
            }
            lock.unlock()
            autoreleasepool {
                do {
                    let attributes = try FileManager.default.attributesOfItem(atPath: work.key.url.path)
                    let modified = attributes[.modificationDate] as? Date, size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    if let cached = cache[slot], cached.url == work.key.url, cached.page == work.key.page,
                       cached.modified == modified, cached.size == size {
                        work.result(work.key, cached.frame, nil)
                    } else {
                        let frame = try Self.prepare(work.key)
                        cache[slot] = .init(url: work.key.url, page: work.key.page, modified: modified, size: size, frame: frame)
                        work.result(work.key, frame, nil)
                    }
                }
                catch { work.result(work.key, nil, "NDI could not prepare the selected image or PDF page.") }
            }
        }
    }
    static func prepare(_ key: Key) throws -> NDIFrameResource {
        let scoped = key.url.startAccessingSecurityScopedResource()
        defer { if scoped { key.url.stopAccessingSecurityScopedResource() } }
        let image: CGImage?
        let page: CGPDFPage?
        let sourceSize: CGSize
        if let index = key.page {
            guard let document = CGPDFDocument(key.url as CFURL), let selected = document.page(at: index + 1) else { throw NDIHelperWire.Failure.unavailable }
            page = selected; image = nil
            let box = selected.getBoxRect(.cropBox)
            sourceSize = abs(selected.rotationAngle) % 180 == 90 ? .init(width: box.height, height: box.width) : box.size
        } else {
            guard let source = CGImageSourceCreateWithURL(key.url as CFURL, nil), let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 3840, kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary) else { throw NDIHelperWire.Failure.unavailable }
            image = decoded; page = nil; sourceSize = .init(width: decoded.width, height: decoded.height)
        }
        guard sourceSize.width.isFinite, sourceSize.height.isFinite, sourceSize.width > 0, sourceSize.height > 0 else { throw NDIHelperWire.Failure.invalidSurface }
        // PDF points are vector coordinates, not pixels. Rasterize for the fixed
        // output canvas; bitmap images retain their existing downsampling limit.
        let scale = page != nil
            ? min(CGFloat(NDIHelperWire.width) / sourceSize.width, CGFloat(NDIHelperWire.height) / sourceSize.height)
            : min(1, 3840 / max(sourceSize.width, sourceSize.height))
        let width = max(1, Int(sourceSize.width * scale)), height = max(1, Int(sourceSize.height * scale))
        let stride = ((width * 4 + 63) / 64) * 64
        guard let surface = IOSurface(properties: [.width: width, .height: height, .bytesPerElement: 4,
            .bytesPerRow: stride, .allocSize: stride * height, .pixelFormat: 0x42475241]),
              let context = CGContext(data: surface.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { throw NDIHelperWire.Failure.unavailable }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.clear(rect)
        if let image { context.draw(image, in: rect) }
        if let page {
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
            // CGPDFPage's drawing transform does not magnify beyond 1×.
            // Scale the context explicitly before normalizing crop/rotation.
            context.scaleBy(x: scale, y: scale)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: sourceSize), rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
        }
        return .init(surface: surface)
    }
}
