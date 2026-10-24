@preconcurrency import AVFoundation

/// Asset PCM is decoded ahead of the existing player's clock, independently of
/// its local audio queue. That queue's processing tap can omit source samples
/// at resume and deliver steady PCM after its programme deadline. Neither its
/// effects latency nor its missing samples belong in the transmitted programme.
nonisolated private final class PlayerAssetAudioDecoder: @unchecked Sendable {
    let id = UUID()
    private struct Packet {
        let sequence: UInt64
        let input: ProgramAudioBus.Input
        var end: CMTime { CMTimeRangeGetEnd(input.range) }
        var bytes: Int { input.byteCount }
    }
    private final class Client {
        weak var mixer: ProgramAudioBus?
        var users = 1
        var sequence: UInt64?
        let background: Bool
        init(_ mixer: ProgramAudioBus, background: Bool) { self.mixer = mixer; self.background = background }
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "eucaly.program-audio.decode", qos: .userInitiated)
    private var clients: [ObjectIdentifier: Client] = [:]
    private var cache: [Packet] = []
    private var nextSequence: UInt64 = 0
    private var timebase: CMTimebase?
    private var active = true
    private var prepared = false
    private var failure: String?
    private var preparedTrackCount = 0
    private var discardedThrough = CMTime.zero
    private var wakePending = false
    var isPrepared: Bool { lock.withLock { prepared } }
    var failureReason: String? { lock.withLock { failure } }
    var trackCount: Int { lock.withLock { preparedTrackCount } }
    // Reader, output and timer belong exclusively to the decoding queue.
    private var asset: AVAsset?
    private var tracks: [AVAssetTrack] = []
    private var audioMix: AVAudioMix?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderAudioMixOutput?
    private var timer: DispatchSourceTimer?
    private var decodedEnd = CMTime.zero
    private var exhausted = false

    func add(_ mixer: ProgramAudioBus, background: Bool) {
        lock.lock(); defer { lock.unlock() }
        let key = ObjectIdentifier(mixer)
        if let client = clients[key], client.mixer === mixer {
            precondition(client.background == background, "A shared player must have one stem per mixer")
            client.users += 1
        } else {
            mixer.setBackground(background, id: id)
            clients[key] = Client(mixer, background: background)
            if let failure { mixer.sourceFailed(id, reason: failure) }
            flush()
        }
    }
    func remove(_ mixer: ProgramAudioBus) {
        lock.lock()
        let key = ObjectIdentifier(mixer)
        if let client = clients[key] {
            client.users -= 1
            if client.users == 0 { clients[key] = nil; mixer.remove(id) }
        }
        lock.unlock()
    }
    func update(from player: AVPlayer, item: AVPlayerItem, programGain: ProgramAudioGain?) {
        let current = player.currentItem === item
        let base = current ? item.timebase : nil
        // A pause/EOF is a clock transition, not a programme mute. Keeping the
        // gain lets the mixer render any samples before that transition even
        // when its next block runs after the player has stopped. Explicit mute
        // still closes audible admission immediately through the supplied gain.
        let gain = current ? (programGain?.value ?? (player.isMuted ? 0 : player.volume)) : 0
        let paused = player.rate == 0
        lock.lock()
        guard active else { lock.unlock(); return }
        timebase = base
        for client in clients.values { client.mixer?.setPlaybackClock(base, gain: gain, id: id, paused: paused) }
        flush(); lock.unlock()
        wake()
    }
    private func flush() {
        guard let timebase else { return }
        guard CMTimebaseGetEffectiveRate(timebase) > 0, let last = cache.last else { return }
        for client in clients.values {
            guard let mixer = client.mixer else { continue }
            let inputs = cache.filter { packet in client.sequence.map { packet.sequence > $0 } ?? true }.map(\.input)
            if mixer.append(inputs, id: id) { client.sequence = last.sequence }
        }
    }
    func prepare(asset: AVAsset, tracks: [AVAssetTrack], audioMix: AVAudioMix?) {
        queue.async { [self] in
            guard lock.withLock({ active }) else { return }
            self.asset = asset; self.tracks = tracks; self.audioMix = audioMix
            lock.withLock { preparedTrackCount = tracks.count }
            guard !tracks.isEmpty else { lock.withLock { prepared = true }; return }
            let position = lock.withLock { timebase.map(CMTimebaseGetTime) } ?? .zero
            reset(at: position.isNumeric ? max(.zero, position - CMTime(value: 960, timescale: 48000)) : .zero)
            pump()
            guard lock.withLock({ active && failure == nil }) else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.pump() }
            self.timer = timer; timer.resume()
        }
    }
    private func reset(at time: CMTime) {
        reader?.cancelReading(); reader = nil; output = nil
        exhausted = false; decodedEnd = time
        lock.withLock { cache.removeAll(); discardedThrough = time }
        guard let asset, !tracks.isEmpty else { return }
        do {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: true
            ])
            output.audioMix = audioMix
            output.alwaysCopiesSampleData = false
            reader.timeRange = CMTimeRange(start: max(.zero, time), duration: .positiveInfinity)
            guard reader.canAdd(output) else { fail("The media's programme audio cannot be decoded."); return }
            reader.add(output)
            guard reader.startReading() else { fail("The media's programme audio decoder could not start."); return }
            self.reader = reader; self.output = output
        } catch { fail("The media's programme audio could not be opened.") }
    }
    private func wake() {
        let needed = lock.withLock {
            guard active, failure == nil, !wakePending else { return false }
            wakePending = true; return true
        }
        if needed {
            queue.async { [self] in lock.withLock { wakePending = false }; pump() }
        }
    }
    private func pump() {
        let state = lock.withLock { (active && failure == nil, timebase, discardedThrough) }
        guard state.0, output != nil else { return }
        let playbackTime = state.1.map(CMTimebaseGetTime).flatMap { $0.isNumeric ? $0 : nil } ?? .zero
        // A scheduled/prerolled player may temporarily map host time before
        // asset zero. There is nothing earlier to decode: retain the prepared
        // beginning instead of repeatedly rebuilding the reader at zero. This
        // clamps only the decode cursor; mixer clocks keep the real mapping.
        let now = max(.zero, playbackTime)
        // Reposition only when playback leaves the retained decoded interval.
        if now < state.2 - CMTime(value: 1, timescale: 48000)
            || (!exhausted && now > decodedEnd + CMTime(value: 9600, timescale: 48000)) {
            reset(at: max(.zero, now - CMTime(value: 960, timescale: 48000)))
        }
        guard let output else { return }
        let horizon = max(.zero, now) + CMTime(value: 48000, timescale: 48000)
        if !exhausted {
            for _ in 0..<16 {
                guard decodedEnd < horizon else { break }
                guard let sample = output.copyNextSampleBuffer() else {
                    if reader?.status == .failed { fail("Programme audio decoding failed. Choose Retry to restart this source."); return }
                    exhausted = true; break
                }
                guard let description = CMSampleBufferGetFormatDescription(sample) else { fail("Programme audio has no PCM format."); return }
                let format = AVAudioFormat(cmAudioFormatDescription: description)
                let frames = CMSampleBufferGetNumSamples(sample)
                guard frames > 0, frames <= ProgramAudioBus.maximumBufferedBytes / 8 else {
                    fail("Programme audio exceeded its bounded PCM buffer size."); return
                }
                let fits = lock.withLock {
                    var bytes = cache.reduce(0, { $0 + $1.bytes })
                    let cutoff = now - CMTime(value: 960, timescale: 48000)
                    // Retain rendered history as well as lookahead. An internal
                    // player-clock rewind may request it again. Evict only when
                    // the existing bounds require it, keeping unplayed PCM.
                    while (cache.count >= 256 || bytes + frames * 8 > ProgramAudioBus.maximumBufferedBytes),
                          let oldest = cache.first, oldest.end < cutoff {
                        bytes -= cache.removeFirst().bytes
                        discardedThrough = max(discardedThrough, oldest.end)
                    }
                    return cache.count < 256 && bytes + frames * 8 <= ProgramAudioBus.maximumBufferedBytes
                }
                guard fits,
                      format.sampleRate == 48000, format.channelCount == 2,
                      format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
                      let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
                    fail("Programme audio returned an unsupported PCM buffer."); return
                }
                pcm.frameLength = AVAudioFrameCount(frames)
                guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(frames), into: pcm.mutableAudioBufferList) == noErr else {
                    fail("Programme audio PCM could not be copied."); return
                }
                let start = CMSampleBufferGetPresentationTimeStamp(sample)
                let duration = CMSampleBufferGetDuration(sample)
                guard start.isNumeric, duration.isNumeric, duration > .zero else {
                    fail("Programme audio returned an invalid asset range."); return
                }
                let input = ProgramAudioBus.Input(pcm, at: start, duration: duration)
                decodedEnd = CMTimeRangeGetEnd(input.range)
                lock.lock()
                guard active, failure == nil else { lock.unlock(); return }
                cache.append(Packet(sequence: nextSequence, input: input)); nextSequence &+= 1
                let bytes = cache.reduce(0) { $0 + $1.bytes }, packets = cache.count
                flush(); lock.unlock()
                #if DEBUG
                NetworkAudioTrace.record("asset-source", queued: bytes, source: id,
                    mediaSample: start.convertScale(48000, method: .roundHalfAwayFromZero).value,
                    frames: frames, covered: packets, sampleRate: format.sampleRate)
                NetworkAudioTrace.record("asset-range-end", source: id,
                    mediaSample: decodedEnd.convertScale(48000, method: .roundHalfAwayFromZero).value)
                #endif
            }
        }
        lock.withLock {
            if decodedEnd >= horizon || exhausted { prepared = true }
            flush()
        }
    }
    func fail(_ reason: String) {
        lock.lock()
        guard active, failure == nil else { lock.unlock(); return }
        failure = reason; prepared = false
        for client in clients.values { client.mixer?.sourceFailed(id, reason: reason) }
        lock.unlock()
    }
    func stop() {
        lock.withLock { active = false; cache.removeAll(); clients.removeAll() }
        queue.async { [self] in
            timer?.cancel(); timer = nil; reader?.cancelReading(); reader = nil; output = nil; asset = nil
        }
    }
}

@MainActor
private final class SharedPlayerProgramAudio {
    let source = PlayerAssetAudioDecoder()
    var users = 0
    private weak var player: AVPlayer?
    private let item: AVPlayerItem?
    private var preparation: Task<Void, Never>?
    private var prerolling = false
    private var observations: [NSKeyValueObservation] = []
    private var observedTimebase: CMTimebase?
    private var timebaseObservers: [NSObjectProtocol] = []
    let programGain: ProgramAudioGain?
    init(player: AVPlayer, programGain: ProgramAudioGain?) {
        self.player = player; item = player.currentItem; self.programGain = programGain
        let item = item, source = source
        observations = [player.observe(\.rate) { [weak player, weak item] _, _ in
            if let player, let item { source.update(from: player, item: item, programGain: programGain) }
        }, player.observe(\.isMuted) { [weak player, weak item] _, _ in
            if let player, let item { source.update(from: player, item: item, programGain: programGain) }
        }, player.observe(\.volume) { [weak player, weak item] _, _ in
            if let player, let item { source.update(from: player, item: item, programGain: programGain) }
        }]
        #if DEBUG
        observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { _, change in
            guard NetworkAudioTrace.isEnabled, let status = change.newValue else { return }
            // Read the notification payload. Re-entering currentTime() inside
            // a synchronous CoreMedia/KVO callback can invert AVPlayer locks.
            NetworkAudioTrace.record("player-control-status", queued: Int(status.rawValue), source: source.id)
        })
        #endif
        if let item {
            observations.append(item.observe(\.status) { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        preparation = Task { [weak self] in
            do {
                guard let item else { return }
                let tracks = try await item.asset.loadTracks(withMediaType: .audio)
                while item.status == .unknown {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard !Task.isCancelled, let self else { return }
                guard item.status == .readyToPlay else { source.fail("The programme player could not load its audio."); return }
                if let player = self.player, player.currentItem === item, player.rate == 0 {
                    // Prepare the paused native playback pipeline as well as
                    // asset PCM before reporting readiness. Preroll neither
                    // starts playback nor changes its position or output gain.
                    self.prerolling = true
                    _ = await player.preroll(atRate: 1)
                    self.prerolling = false
                    guard !Task.isCancelled, self.player === player, player.currentItem === item else { return }
                }
                let enabled = Set(item.tracks.filter(\.isEnabled).compactMap { $0.assetTrack?.trackID })
                source.prepare(asset: item.asset, tracks: tracks.filter { enabled.contains($0.trackID) }, audioMix: item.audioMix)
                self.refresh()
            } catch is CancellationError { }
            catch { source.fail("The media's programme audio tracks could not be loaded.") }
        }
        refresh()
    }
    func matches(_ value: AVPlayer) -> Bool { player === value && item === value.currentItem }
    func refresh() {
        guard let item, let player else { return }
        let timebase = item.timebase
        if observedTimebase !== timebase {
            timebaseObservers.forEach { NotificationCenter.default.removeObserver($0) }
            observedTimebase = timebase
            timebaseObservers = timebase.map { clock in
                [kCMTimebaseNotification_EffectiveRateChanged, kCMTimebaseNotification_TimeJumped].map { name in
                    NotificationCenter.default.addObserver(forName: .init(name as String), object: clock, queue: nil) { [weak player, weak item, source, programGain] _ in
                        if let player, let item { source.update(from: player, item: item, programGain: programGain) }
                    }
                }
            } ?? []
        }
        source.update(from: player, item: item, programGain: programGain)
    }
    func stop() {
        source.stop()
        preparation?.cancel(); preparation = nil
        if prerolling, let player, player.currentItem === item { player.cancelPendingPrerolls() }
        prerolling = false
        observations.forEach { $0.invalidate() }; observations.removeAll()
        timebaseObservers.forEach { NotificationCenter.default.removeObserver($0) }; timebaseObservers.removeAll()
    }
}

@MainActor
final class PlayerProgramAudioSource {
    private static var sources: [ObjectIdentifier: SharedPlayerProgramAudio] = [:]
    private let key: ObjectIdentifier
    private let shared: SharedPlayerProgramAudio
    private let mixer: ProgramAudioBus
    private var stopped = false
    var isPrepared: Bool { shared.source.isPrepared }
    var trackCount: Int { shared.source.trackCount }
    var sourceID: UUID { shared.source.id }
    var failureReason: String? { shared.source.failureReason }
    init(player: AVPlayer, mixer: ProgramAudioBus, background: Bool = false, programGain: ProgramAudioGain? = nil) {
        key = ObjectIdentifier(player); self.mixer = mixer
        if let existing = Self.sources[key], existing.matches(player) {
            precondition(existing.programGain === programGain)
            shared = existing
        } else { shared = SharedPlayerProgramAudio(player: player, programGain: programGain); Self.sources[key] = shared }
        shared.users += 1; shared.source.add(mixer, background: background); shared.refresh()
    }
    func matches(_ player: AVPlayer) -> Bool { !stopped && shared.matches(player) }
    func refresh() { if !stopped { shared.refresh() } }
    func stop() {
        guard !stopped else { return }; stopped = true
        shared.source.remove(mixer); shared.users -= 1
        if shared.users == 0 {
            shared.stop()
            if Self.sources[key] === shared { Self.sources[key] = nil }
        }
    }
}
