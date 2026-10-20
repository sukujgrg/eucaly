@preconcurrency import AVFoundation
import MediaToolbox

/// The programme level sent to outputs, independently of AVPlayer's local
/// playback volume. The audio callback reads this snapshot off the main actor.
nonisolated final class ProgramAudioGain: @unchecked Sendable {
    private let lock = NSLock()
    private var level: Float = 1
    var value: Float { lock.lock(); defer { lock.unlock() }; return level }
    func set(_ value: Float) {
        lock.lock(); level = value.isFinite ? min(1, max(0, value)) : 0; lock.unlock()
    }
}

/// Taps only explicitly selected live program players. Preview playback and other apps can
/// never enter this bus. AVPlayer's local output level is applied after the tap;
/// managed players supply their separate programme gain to the output bus.
nonisolated final class ProgramAudioBus: @unchecked Sendable {
    typealias StemDelivery = @Sendable (AVAudioPCMBuffer, AVAudioPCMBuffer, AVAudioTime) -> Void
    fileprivate static let maximumBufferedBytes = 8 * 1024 * 1024
    private struct Segment {
        let start: Int64
        let buffer: AVAudioPCMBuffer
        var offset = 0
        var count: Int
        var end: Int64 { start + Int64(count) }
        init(start: Int64, buffer: AVAudioPCMBuffer, offset: Int = 0, count: Int? = nil) {
            self.start = start; self.buffer = buffer; self.offset = offset; self.count = count ?? Int(buffer.frameLength)
        }
        func slice(_ begin: Int64, _ end: Int64) -> Self {
            .init(start: begin, buffer: buffer, offset: offset + Int(begin - start), count: Int(end - begin))
        }
    }
    private let queue = DispatchQueue(label: "eucaly.program-audio", qos: .userInitiated)
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var segments: [UUID: [Segment]] = [:]
    private var gains: [UUID: Float] = [:]
    private var backgroundInputs: Set<UUID> = []
    private var converters: [UUID: AVAudioConverter] = [:]
    private var convertedEnd: [UUID: Int64] = [:]
    private var inputEnd: [UUID: Int64] = [:]
    // Immutable clock history also covers the mixer block just before a pause
    // or end-of-file. Reading a mutable, now-stopped timebase loses that tail.
    private struct PlaybackClock: Sendable {
        var start: Int64
        let hostAnchor: Double
        let mediaAnchor: Double
        let rate: Double
        let gain: Float
        func mediaSample(_ host: Int64) -> Int64 { Int64((mediaAnchor + (Double(host) - hostAnchor) * rate).rounded()) }
    }
    private var clocks: [UUID: [PlaybackClock]] = [:]
    private var silenced: Set<UUID> = []
    private var nextSample: Int64?
    private var timer: DispatchSourceTimer?
    private var active = true
    private let pendingLock = NSLock()
    private var pendingSubmissions = 0
    private let deliver: (@Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void)?
    private let deliverStems: StemDelivery?
    init(deliver: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) { self.deliver = deliver; deliverStems = nil }
    init(deliverStems: @escaping StemDelivery) { self.deliverStems = deliverStems; deliver = nil }
    /// Retarget delivery only after prior blocks finish and queued tap removals
    /// have discarded the previous owner's PCM. The host sample clock continues.
    func updateDelivery(_ change: @escaping @Sendable () -> Void) {
        queue.async { [self] in guard active else { return }; change() }
    }
    func setBackground(_ value: Bool, id: UUID) {
        queue.async { [self] in if value { backgroundInputs.insert(id) } else { backgroundInputs.remove(id) } }
    }
    func start(at time: CMTime) {
        queue.async { [self] in
            guard active, timer == nil, time.isNumeric else { return }
            nextSample = Int64(time.seconds * 48000) / 960 * 960
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in self?.render() }
            timer = source; source.resume()
        }
    }
    func setGain(_ value: Float, id: UUID) {
        queue.async { [self] in
            guard active else { return }; gains[id] = value
        }
    }
    func setPlaybackClock(_ timebase: CMTimebase?, gain: Float, id: UUID) {
        guard let timebase else { return }
        var rate: Double = 0, media = CMTime.invalid, host = CMTime.invalid
        guard CMSyncGetRelativeRateAndAnchorTime(timebase, relativeTo: CMClockGetHostTimeClock(),
            relativeRateOut: &rate, anchorTimeOut: &media, relativeToAnchorTimeOut: &host) == noErr,
              rate.isFinite, media.isNumeric, host.isNumeric else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        let value = PlaybackClock(start: now, hostAnchor: host.seconds * 48000, mediaAnchor: media.seconds * 48000, rate: rate, gain: gain)
        queue.async { [self] in
            if gain == 0 { silenced.insert(id) } else { silenced.remove(id) }
            var history = clocks[id] ?? [], clock = value
            if let last = history.last {
                let sameMapping = abs(last.mediaSample(now) - clock.mediaSample(now)) <= 1
                if last.rate == clock.rate, last.gain == clock.gain, sameMapping { return }
                clock.start = max(last.start, clock.start)
                if last.start == clock.start { history.removeLast() }
            }
            history.append(clock)
            clocks[id] = Array(history.suffix(64))
        }
    }
    func remove(_ id: UUID) { queue.async { [self] in segments[id] = nil; gains[id] = nil; clocks[id] = nil; silenced.remove(id); converters[id] = nil; convertedEnd[id] = nil; inputEnd[id] = nil; backgroundInputs.remove(id) } }
    @discardableResult
    func append(_ inputs: [(AVAudioPCMBuffer, CMTime)], id: UUID) -> Bool {
        guard !inputs.isEmpty else { return true }
        pendingLock.lock()
        guard pendingSubmissions < 8 else { pendingLock.unlock(); return false }
        pendingSubmissions += 1; pendingLock.unlock()
        queue.async { [self] in
            defer { pendingLock.lock(); pendingSubmissions -= 1; pendingLock.unlock() }
            guard active else { return }
            // One source handoff may contain several prerendered buffers. Admit
            // the bounded batch once rather than dropping its tail as a burst.
            for (input, time) in inputs { convert(input, at: time, id: id) }
        }
        return true
    }
    // Runs only on the mixer queue.
    private func convert(_ input: AVAudioPCMBuffer, at time: CMTime, id: UUID) {
        guard time.isNumeric else { return }
        let timestamp = time.convertScale(48000, method: .roundHalfAwayFromZero).value
        // A PCM converter may retain part of an input and return it with the
        // next input. Output belongs to one continuous sample clock, not to
        // whichever input happened to trigger a conversion callback.
        let discontinuity = inputEnd[id].map { abs(timestamp - $0) > 2400 } ?? false
        if converters[id]?.inputFormat != input.format || discontinuity {
            converters[id] = AVAudioConverter(from: input.format, to: format)
            convertedEnd[id] = timestamp
        }
        inputEnd[id] = timestamp + Int64((Double(input.frameLength) * 48000 / input.format.sampleRate).rounded())
        guard let converter = converters[id] else { return }
        var supplied = false; var packets = segments[id] ?? []
        var conversion: AVAudioConverterOutputStatus
        repeat {
            guard let output = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 48000 / input.format.sampleRate + 64)) else { break }
            var error: NSError?
            conversion = converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            guard error == nil else { break }
            if output.frameLength > 0 {
                let start = convertedEnd[id] ?? timestamp
                let replacement = Segment(start: start, buffer: output)
                // Decoders can preroll overlapping ranges after resume/seek.
                // Replace only the overlap, preserving the unplayed prefix/tail.
                if packets.last.map({ $0.end > replacement.start }) == true {
                    packets = packets.flatMap { old -> [Segment] in
                        guard old.start < replacement.end, old.end > replacement.start else { return [old] }
                        var keep: [Segment] = []
                        if old.start < replacement.start { keep.append(old.slice(old.start, replacement.start)) }
                        if old.end > replacement.end { keep.append(old.slice(replacement.end, old.end)) }
                        return keep
                    }
                    packets.append(replacement); packets.sort { $0.start < $1.start }
                } else { packets.append(replacement) }
                convertedEnd[id] = start + Int64(output.frameLength)
            }
        } while conversion == .haveData
        // PCM packet sizes vary. Bound storage by memory, while retaining a
        // decoded preroll batch regardless of how the tap divided its samples.
        let bytesPerFrame = MemoryLayout<Float>.stride * Int(format.channelCount)
        var bufferedBytes = packets.reduce(0) { $0 + Int($1.buffer.frameLength) * bytesPerFrame }
        while !packets.isEmpty && (packets.count > 512 || bufferedBytes > Self.maximumBufferedBytes) {
            bufferedBytes -= Int(packets.removeFirst().buffer.frameLength) * bytesPerFrame
        }
        segments[id] = packets
    }
    private func render() {
        guard active, var sample = nextSample else { return }
        let now = Int64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 48000)
        if sample < now - 24000 { sample = (now / 960 - 1) * 960 }
        // Dispatch timers coalesce delayed callbacks. Producing only one block
        // per callback accumulates audio timestamp lag until a discontinuity.
        // Recover due blocks against the host clock, with a bounded burst below
        // the NDI admission queue's eight-block limit.
        for _ in 0..<4 {
            guard sample + 960 <= now, renderBlock(at: sample) else { return }
            sample += 960; nextSample = sample
        }
    }
    private func renderBlock(at sample: Int64) -> Bool {
        // Always produce silence too: consumers need a continuous audio clock for
        // static slides, muted video and pauses.
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960),
              let channels = output.floatChannelData else { return false }
        output.frameLength = 960
        for channel in 0..<2 { channels[channel].initialize(repeating: 0, count: 960) }
        let background = deliverStems == nil ? nil : AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960)
        background?.frameLength = 960
        if let bg = background?.floatChannelData { for channel in 0..<2 { bg[channel].initialize(repeating: 0, count: 960) } }
        for (id, packets) in segments {
            let history = clocks[id] ?? [.init(start: .min, hostAnchor: 0, mediaAnchor: 0, rate: 1, gain: gains[id] ?? 0)]
            let destination = backgroundInputs.contains(id) ? (background?.floatChannelData ?? channels) : channels
            var consumedUntil: Int64?
            for (index, clock) in history.enumerated() where clock.rate > 0 {
                let begin = max(sample, clock.start), end = min(sample + 960, index + 1 < history.count ? history[index + 1].start : .max)
                guard begin < end else { continue }
                var packetIndex = 0
                for position in begin..<end {
                    let sourceSample = clock.mediaSample(position)
                    consumedUntil = sourceSample + 1
                    while packetIndex < packets.count && packets[packetIndex].end <= sourceSample { packetIndex += 1 }
                    guard clock.gain > 0, !silenced.contains(id), packetIndex < packets.count else { continue }
                    let packet = packets[packetIndex]
                    guard sourceSample >= packet.start, let source = packet.buffer.floatChannelData else { continue }
                    for channel in 0..<2 {
                        destination[channel][Int(position - sample)] += source[channel][packet.offset + Int(sourceSample - packet.start)] * clock.gain
                    }
                }
            }
            if let consumedUntil { segments[id] = packets.filter { $0.end > consumedUntil } }
            if let last = history.lastIndex(where: { $0.start < sample + 960 }), clocks[id] != nil {
                clocks[id] = Array(history.suffix(from: last))
            }
        }
        for channel in 0..<2 { for i in 0..<960 { channels[channel][i] = min(1, max(-1, channels[channel][i])) } }
        let time = AVAudioTime(sampleTime: sample, atRate: 48000)
        if let background, let deliverStems {
            if let bg = background.floatChannelData { for channel in 0..<2 { for i in 0..<960 { bg[channel][i] = min(1, max(-1, bg[channel][i])) } } }
            deliverStems(output, background, time)
        } else { deliver?(output, time) }
        return true
    }
    func stop() {
        queue.async { [self] in
            active = false; timer?.cancel(); timer = nil
            segments.removeAll(); clocks.removeAll(); gains.removeAll(); silenced.removeAll(); backgroundInputs.removeAll()
            converters.removeAll(); convertedEnd.removeAll(); inputEnd.removeAll()
        }
    }
}

nonisolated private final class PlayerAudioTapContext: @unchecked Sendable {
    let id = UUID()
    private struct RetainedAudio {
        let sequence: UInt64
        let buffer: AVAudioPCMBuffer
        let time: CMTime
        let byteCount: Int
        var end: CMTime { time + CMTime(seconds: Double(buffer.frameLength) / buffer.format.sampleRate, preferredTimescale: 48000) }
    }
    private final class Client {
        weak var mixer: ProgramAudioBus?
        var deliveredThrough: UInt64?
        init(_ mixer: ProgramAudioBus) { self.mixer = mixer }
    }
    private var clients: [ObjectIdentifier: Client] = [:]
    private let lock = NSLock()
    private var timebase: CMTimebase?
    private var format: AVAudioFormat?
    // Keep unplayed preroll for clients joining the existing tap. Per-client
    // cursors prevent replaying those buffers into a mixer that already has them.
    private var retained: [RetainedAudio] = []
    private var retainedBytes = 0
    private var nextSequence: UInt64 = 0
    private let maximumRetainedBytes = ProgramAudioBus.maximumBufferedBytes
    private let maximumRetainedBuffers = 256
    func add(_ mixer: ProgramAudioBus) { lock.lock(); clients[ObjectIdentifier(mixer)] = Client(mixer); lock.unlock() }
    func remove(_ mixer: ProgramAudioBus) {
        lock.lock(); clients[ObjectIdentifier(mixer)] = nil
        if clients.isEmpty { discardRetained() }
        lock.unlock(); mixer.remove(id)
    }
    func updatePlayback(from player: AVPlayer, item: AVPlayerItem, programGain: ProgramAudioGain? = nil) {
        let current = player.currentItem === item
        let timebase = current ? item.timebase : nil
        let gain = current && player.rate != 0 ? (programGain?.value ?? (player.isMuted ? 0 : player.volume)) : 0
        lock.lock(); defer { lock.unlock() }
        self.timebase = timebase
        let mixers = clients.values.compactMap(\.mixer)
        // Snapshot clock and gain before prerendered samples, including when playback
        // starts without another processing callback to deliver them.
        mixers.forEach { $0.setPlaybackClock(timebase, gain: gain, id: id) }
        flushRetained()
    }
    // Called with the context lock held so gain, clock and sample submission
    // stay ordered across the playback and audio processing queues.
    private func flushRetained() {
        guard let timebase, CMTimebaseGetEffectiveRate(timebase) > 0 else { return }
        // Retain one mixer block behind the running media clock, plus future
        // preroll. Old decoded history must not turn a new join into a large
        // conversion job on that destination's audio queue.
        let cutoff = CMTimebaseGetTime(timebase) - CMTime(value: 960, timescale: 48000)
        if cutoff.isNumeric {
            retained.removeAll { packet in
                guard packet.end < cutoff else { return false }
                retainedBytes -= packet.byteCount; return true
            }
        }
        guard let last = retained.last else { return }
        for client in clients.values {
            guard let mixer = client.mixer else { continue }
            let inputs = retained.filter { packet in client.deliveredThrough.map { packet.sequence > $0 } ?? true }
                .map { ($0.buffer, $0.time) }
            if mixer.append(inputs, id: id) { client.deliveredThrough = last.sequence }
        }
    }
    private func discardRetained() { retained.removeAll(); retainedBytes = 0 }
    func prepare(_ description: AudioStreamBasicDescription) {
        var value = description
        lock.lock()
        let next = AVAudioFormat(streamDescription: &value)
        if format != next { discardRetained() }
        format = next; lock.unlock()
    }
    func process(_ tap: MTAudioProcessingTap, frames: CMItemCount, buffers: UnsafeMutablePointer<AudioBufferList>,
                 actual: UnsafeMutablePointer<CMItemCount>, flags: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
        var range = CMTimeRange.invalid
        guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, &range, actual) == noErr, actual.pointee > 0 else { return }
        lock.lock()
        let format = format
        lock.unlock()
        guard let format, range.start.isNumeric,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(actual.pointee)) else { return }
        copy.frameLength = AVAudioFrameCount(actual.pointee)
        let source = UnsafeMutableAudioBufferListPointer(buffers), target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(source.count, target.count) {
            if let from = source[i].mData, let to = target[i].mData {
                memcpy(to, from, min(Int(source[i].mDataByteSize), Int(target[i].mDataByteSize)))
            }
        }
        lock.lock(); defer { lock.unlock() }
        guard !clients.isEmpty else { return }
        // AVPlayer can decode all of a short file during preroll, before its
        // timebase runs. A tap never receives that source audio a second time.
        // Keep media timestamps until they can be mapped to the playback clock.
        let byteCount = target.reduce(0) { $0 + Int($1.mDataByteSize) }
        guard byteCount <= maximumRetainedBytes else { return }
        if let last = retained.last, range.start < last.time { discardRetained() }
        while !retained.isEmpty && (retained.count >= maximumRetainedBuffers || retainedBytes + byteCount > maximumRetainedBytes) {
            retainedBytes -= retained.removeFirst().byteCount
        }
        retained.append(.init(sequence: nextSequence, buffer: copy, time: range.start, byteCount: byteCount))
        nextSequence &+= 1; retainedBytes += byteCount
        flushRetained()
    }
}

@MainActor
private final class SharedPlayerAudioTap {
    fileprivate let context = PlayerAudioTapContext()
    var users = 0
    private weak var player: AVPlayer?
    private var item: AVPlayerItem?
    private var previous: AVAudioMix?
    private var installed: AVAudioMix?
    private var preparation: Task<Void, Never>?
    private var playbackObservations: [NSKeyValueObservation] = []
    private var observedTimebase: CMTimebase?
    private var timebaseObservers: [NSObjectProtocol] = []
    let programGain: ProgramAudioGain?
    init(player: AVPlayer, programGain: ProgramAudioGain?) {
        self.programGain = programGain
        self.player = player
        let item = player.currentItem; self.item = item
        playbackObservations = [
            player.observe(\.rate) { [weak player, weak item, context] _, _ in
                if let player, let item { context.updatePlayback(from: player, item: item, programGain: programGain) }
            },
            player.observe(\.isMuted) { [weak player, weak item, context] _, _ in
                if let player, let item { context.updatePlayback(from: player, item: item, programGain: programGain) }
            },
            player.observe(\.volume) { [weak player, weak item, context] _, _ in
                if let player, let item { context.updatePlayback(from: player, item: item, programGain: programGain) }
            }
        ]
        if let item {
            playbackObservations.append(item.observe(\.status) { [weak self, weak player, weak item, context] _, _ in
                if let player, let item { context.updatePlayback(from: player, item: item, programGain: programGain) }
                Task { @MainActor [weak self] in self?.refresh() }
            })
        }
        preparation = Task { [weak self] in
            guard let item, let tracks = try? await item.asset.loadTracks(withMediaType: .audio), !Task.isCancelled,
                  let self, self.item === item else { return }
            var parameters: [AVAudioMixInputParameters] = []
            for track in tracks {
                let retained = Unmanaged.passRetained(self.context).toOpaque()
                var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
                    clientInfo: retained,
                    init: { _, client, storage in storage.pointee = client },
                    finalize: { tap in Unmanaged<PlayerAudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
                    prepare: { tap, _, format in Unmanaged<PlayerAudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee) },
                    unprepare: { _ in },
                    process: { tap, frames, _, buffers, actual, flags in
                        Unmanaged<PlayerAudioTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().process(tap, frames: frames, buffers: buffers, actual: actual, flags: flags)
                    })
                var tap: MTAudioProcessingTap?
                guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                    kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr, let tap else {
                    Unmanaged<PlayerAudioTapContext>.fromOpaque(retained).release(); continue
                }
                let input = AVMutableAudioMixInputParameters(track: track); input.audioTapProcessor = tap; parameters.append(input)
            }
            guard !parameters.isEmpty, !Task.isCancelled else { return }
            self.previous = item.audioMix
            let mix = AVMutableAudioMix(); mix.inputParameters = parameters
            self.installed = mix; item.audioMix = mix; self.refresh()
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
                    NotificationCenter.default.addObserver(forName: .init(name as String), object: clock, queue: nil) { [weak player, weak item, context, programGain] _ in
                        if let player, let item { context.updatePlayback(from: player, item: item, programGain: programGain) }
                    }
                }
            } ?? []
        }
        context.updatePlayback(from: player, item: item, programGain: programGain)
    }
    func stop() {
        preparation?.cancel(); preparation = nil
        playbackObservations.forEach { $0.invalidate() }; playbackObservations.removeAll()
        timebaseObservers.forEach { NotificationCenter.default.removeObserver($0) }; timebaseObservers.removeAll()
        observedTimebase = nil
        if item?.audioMix === installed { item?.audioMix = previous }
        item = nil
    }
}

/// One AVAudioMix tap per live player, shared by all media destinations. Each
/// destination still has its own bounded mixer and optional background choice.
@MainActor
final class PlayerAudioTap {
    private static var sources: [ObjectIdentifier: SharedPlayerAudioTap] = [:]
    private let key: ObjectIdentifier
    private let shared: SharedPlayerAudioTap
    private let mixer: ProgramAudioBus
    private var stopped = false
    init(player: AVPlayer, mixer: ProgramAudioBus, background: Bool = false, programGain: ProgramAudioGain? = nil) {
        key = ObjectIdentifier(player); self.mixer = mixer
        if let existing = Self.sources[key], existing.matches(player) {
            precondition(existing.programGain === programGain, "A shared player must have one programme audio level")
            shared = existing
        } else { shared = SharedPlayerAudioTap(player: player, programGain: programGain); Self.sources[key] = shared }
        shared.users += 1; mixer.setBackground(background, id: shared.context.id); shared.context.add(mixer); shared.refresh()
    }
    func matches(_ player: AVPlayer) -> Bool { !stopped && shared.matches(player) }
    func refresh() { if !stopped { shared.refresh() } }
    func stop() {
        guard !stopped else { return }; stopped = true
        shared.context.remove(mixer); shared.users -= 1
        if shared.users == 0 {
            shared.stop()
            if Self.sources[key] === shared { Self.sources[key] = nil }
        }
    }
}
