@preconcurrency import AVFoundation
import IOSurface
import ImageIO

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
    private var players: [ObjectIdentifier: NDIVideoFrameLease] = [:]
    private var requested: [Int: OutputPreparedMedia.Key] = [:]
    private var pictures: [Int: NDIFrameResource] = [:]
    private var plan: NDIMediaFrameClock.Plan?
    private let failure: @MainActor (String) -> Void
    private var stopped = false

    init(generation: UUID, deliver: @escaping @Sendable (NDIMediaSubmission) -> Void, failure: @escaping @MainActor (String) -> Void) {
        self.generation = generation; self.failure = failure
        clock = NDIMediaFrameClock(deliver: deliver) { clock, version, reason in
            Task { @MainActor in
                guard clock.acceptsFailure(version: version) else { return }
                failure(reason)
            }
        }
    }
    func update(_ snapshot: OutputContentSnapshot, profile: OutputProfile, runtime: OutputMediaRuntime, keyMode: NDIOutputSettings.KeyMode = .alpha) {
        guard !stopped else { return }
        let supported = !snapshot.visible || (snapshot.localMedia.map(OutputContentClassifier.supportsNDI) ?? true)
        let slide = snapshot.visible && supported ? snapshot.localMedia : nil
        // Workspace snapshots must carry their explicit load's accepted bytes.
        // URL-only requests are retained for standalone preparation/probe callers.
        if snapshot.source != nil, slide?.pdfURL != nil, snapshot.acceptedPDF == nil {
            failure("NDI could not prepare the accepted PDF. Load the PDF to Current again."); return
        }
        let media = slide.map { OutputContentClassifier.mode(for: $0) == .media } ?? false
        let background = profile.background
        let showBackground = supported && background.visible && (!snapshot.visible ? background.whenHidden : media ? background.whenMediaShown : background.whenTextShown)
        let backgroundURL = showBackground ? runtime.backgroundURL(for: profile) : nil
        let foregroundKey: OutputPreparedMedia.Key? = slide.flatMap {
            if let url = $0.imageURL { return .init(url: url, page: nil, identity: "\(snapshot.source?.uuidString ?? ""):\($0.id):\(snapshot.revision)") }
            if let url = $0.pdfURL { return .init(url: url, page: $0.pdfPageIndex ?? 0, identity: "\(snapshot.source?.uuidString ?? ""):\($0.id):\(snapshot.revision)", acceptedPDF: snapshot.acceptedPDF) }
            return nil
        }
        let backgroundKey = backgroundURL.flatMap { OutputMediaRuntime.isVideo($0) ? nil : OutputPreparedMedia.Key(url: $0, page: nil, identity: "\(snapshot.source?.uuidString ?? ""):\(profile.id):\(snapshot.revision)") }
        let intent = OutputRenderSnapshot(workspace: snapshot.source, revision: snapshot.revision,
            visible: snapshot.visible, profile: profile, geometry: .init(width: 1920, height: 1080), foreground: foregroundKey, background: backgroundKey)
        var required: Set<ObjectIdentifier> = []
        func source(_ player: AVPlayer?) -> NDIVideoFrameLease? {
            guard let player else { return nil }
            let key = ObjectIdentifier(player); required.insert(key)
            if let old = players[key], old.item === player.currentItem { return old }
            players[key]?.release()
            let value = runtime.ndiVideoFrames.acquire(player); players[key] = value; return value
        }
        let foregroundVideo = source(slide?.videoURL != nil ? runtime.program : nil)
        let backgroundVideo = source(backgroundURL.map(OutputMediaRuntime.isVideo) == true ? runtime.backgroundPlayer(for: profile) : nil)
        for key in Array(players.keys) where !required.contains(key) { players.removeValue(forKey: key)?.release() }
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
        if key == nil || previous?.url != key?.url || previous?.page != key?.page || previous?.acceptedPDF != key?.acceptedPDF { pictures[slot] = nil }
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
        for source in players.values { source.release() }
        players.removeAll(); pictures.removeAll(); requested.removeAll(); plan = nil
    }
    func forceNextFrame() { clock.forceNextFrame() }
}

/// Timer callbacks coalesce on a dedicated queue. Host-side handoff is latest
/// only; the supervisor retains one pending and one in-flight pair of buffers.
nonisolated final class NDIMediaFrameClock: @unchecked Sendable {
    struct Plan: Sendable {
        var request: NDIMediaRenderRequest
        var foregroundVideo: NDIVideoFrameLease?
        var backgroundVideo: NDIVideoFrameLease?
        var foreground: NDIFrameResource?
        var background: NDIFrameResource?
    }
    typealias Picture = (foreground: NDIFrameResource?, background: NDIFrameResource?)
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.suku.eucaly.ndi.media-clock", qos: .userInitiated)
    private var plan: Plan?
    private var planVersion: UInt64 = 0
    private var failedPlanVersion: UInt64?
    private var stopped = false
    private var timer: DispatchSourceTimer?
    private var revision: UInt64 = 0
    private var previousRequest: NDIMediaRenderRequest?
    private var previousForeground: NDIFrameResource?
    private var previousBackground: NDIFrameResource?
    private let deliver: @Sendable (NDIMediaSubmission) -> Void
    private let failure: @Sendable (NDIMediaFrameClock, UInt64, String) -> Void
    private let read: @Sendable (Plan) throws -> Picture
    init(read: @escaping @Sendable (Plan) throws -> Picture = {
        (try $0.foregroundVideo?.latest() ?? $0.foreground, try $0.backgroundVideo?.latest() ?? $0.background)
    }, deliver: @escaping @Sendable (NDIMediaSubmission) -> Void,
         failure: @escaping @Sendable (NDIMediaFrameClock, UInt64, String) -> Void) {
        self.read = read; self.deliver = deliver; self.failure = failure
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 30), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.tick() }; self.timer = timer; timer.resume()
        }
    }
    func update(_ plan: Plan) {
        lock.lock()
        if !stopped { self.plan = plan; planVersion &+= 1; failedPlanVersion = nil }
        lock.unlock()
    }
    func acceptsFailure(version: UInt64) -> Bool {
        lock.withLock { !stopped && planVersion == version && failedPlanVersion == version }
    }
    func forceNextFrame() { queue.async { [self] in previousRequest = nil; tick() } }
    func stop() {
        lock.lock(); stopped = true; plan = nil; failedPlanVersion = nil; lock.unlock()
        queue.async { [self] in timer?.cancel(); timer = nil; previousForeground = nil; previousBackground = nil }
    }
    private func tick() {
        lock.lock(); let value = stopped ? nil : plan, version = planVersion; lock.unlock()
        guard let value else { return }
        do {
            let (foreground, background) = try read(value)
            var request = value.request; request.foreground = foreground != nil; request.background = background != nil
            request.foregroundGeometry = foreground?.geometry; request.backgroundGeometry = background?.geometry
            request.foregroundInput = foreground?.input ?? .init(); request.backgroundInput = background?.input ?? .init()
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
                foregroundInput: request.foregroundInput, backgroundInput: request.backgroundInput,
                producedAtNanoseconds: DispatchTime.now().uptimeNanoseconds)
            deliver(.init(request: request, foreground: foreground, background: background))
        } catch {
            lock.lock()
            let current = !stopped && version == planVersion
            // Quiesce this failed plan while its main-actor callback is queued.
            // A newer Current can replace it before that callback is delivered.
            if current { failedPlanVersion = version; plan = nil }
            lock.unlock()
            if current { failure(self, version, "NDI could not read the shared video frame. Use an SDR video file and choose Retry.") }
        }
    }
}

/// One preparation worker, two latest slots, two retained static pictures.
/// Rapid navigation cannot enqueue an unbounded set of PDF/image decoders.
nonisolated final class OutputPreparedMedia: @unchecked Sendable {
    struct Key: Equatable, Sendable {
        let url: URL
        let page: Int?
        let identity: String
        let acceptedPDF: AcceptedPDFSource?
        init(url: URL, page: Int?, identity: String, acceptedPDF: AcceptedPDFSource? = nil) {
            self.url = url; self.page = page; self.identity = identity; self.acceptedPDF = acceptedPDF
        }
    }
    private struct Work: Sendable { let key: Key; let result: @Sendable (Key, NDIFrameResource?, String?) -> Void }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.suku.eucaly.ndi.prepare-media", qos: .userInitiated)
    private var pending: [Int: Work] = [:]
    private var scheduled = false
    private struct Cache { let url: URL; let page: Int?; let sourceID: UUID?; let modified: Date?; let size: UInt64; let frame: NDIFrameResource }
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
                    let sourceID = work.key.acceptedPDF?.id
                    // Accepted PDFs remain usable after replacement/deletion.
                    // Only unpinned image/probe inputs consult the live path.
                    let attributes = sourceID == nil ? try FileManager.default.attributesOfItem(atPath: work.key.url.path) : [:]
                    let modified = attributes[.modificationDate] as? Date, size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                    if let cached = cache[slot], cached.url == work.key.url, cached.page == work.key.page,
                       cached.sourceID == sourceID, cached.modified == modified, cached.size == size {
                        work.result(work.key, cached.frame, nil)
                    } else {
                        let frame = try Self.prepare(work.key)
                        cache[slot] = .init(url: work.key.url, page: work.key.page, sourceID: sourceID, modified: modified, size: size, frame: frame)
                        work.result(work.key, frame, nil)
                    }
                }
                catch { work.result(work.key, nil, "NDI could not prepare the selected image or PDF page.") }
            }
        }
    }
    static func prepare(_ key: Key) throws -> NDIFrameResource {
        let scoped = key.acceptedPDF == nil && key.url.startAccessingSecurityScopedResource()
        defer { if scoped { key.url.stopAccessingSecurityScopedResource() } }
        let image: CGImage?
        let page: CGPDFPage?
        let sourceSize: CGSize
        if let index = key.page {
            let document: CGPDFDocument?
            if let source = key.acceptedPDF {
                guard source.url == key.url.standardizedFileURL else { throw NDIHelperWire.Failure.unavailable }
                document = source.makeDocument()
            } else { document = CGPDFDocument(key.url as CFURL) }
            guard let document, let selected = document.page(at: index + 1) else { throw NDIHelperWire.Failure.unavailable }
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
        let opaque = page != nil || image.map { [.none, .noneSkipFirst, .noneSkipLast].contains($0.alphaInfo) } == true
        return .init(surface: surface, opaque: opaque)
    }
}
