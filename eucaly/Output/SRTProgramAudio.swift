@preconcurrency import AVFoundation
import MediaToolbox

/// Taps only explicitly selected live program players. Preview playback and other apps can
/// never enter this bus. The tap leaves the player's local audio untouched.
nonisolated final class SRTProgramAudio: @unchecked Sendable {
    fileprivate static let maximumBufferedBytes = 8 * 1024 * 1024
    private struct Segment { let start: Int64; let buffer: AVAudioPCMBuffer }
    private let queue = DispatchQueue(label: "eucaly.srt.program-audio")
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var segments: [UUID: [Segment]] = [:]
    private var gains: [UUID: Float] = [:]
    private var converters: [UUID: AVAudioConverter] = [:]
    private var convertedEnd: [UUID: Int64] = [:]
    private var inputEnd: [UUID: Int64] = [:]
    private var nextSample: Int64?
    private var timer: DispatchSourceTimer?
    private var active = true
    private let pendingLock = NSLock()
    private var pendingSubmissions = 0
    private let ingest: SRTMediaIngest
    init(ingest: SRTMediaIngest) { self.ingest = ingest }
    func start(at time: CMTime) {
        queue.async { [self] in
            guard active, timer == nil, time.isNumeric else { return }
            nextSample = Int64(time.seconds * 48000)
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
            source.setEventHandler { [weak self] in self?.render() }
            timer = source; source.resume()
        }
    }
    func setGain(_ value: Float, id: UUID) {
        queue.async { [self] in
            guard active else { return }; gains[id] = value
            if value == 0 { segments[id] = []; converters[id] = nil; convertedEnd[id] = nil; inputEnd[id] = nil }
        }
    }
    func remove(_ id: UUID) { queue.async { [self] in segments[id] = nil; gains[id] = nil; converters[id] = nil; convertedEnd[id] = nil; inputEnd[id] = nil } }
    func append(_ inputs: [(AVAudioPCMBuffer, CMTime)], id: UUID) {
        guard !inputs.isEmpty else { return }
        pendingLock.lock()
        guard pendingSubmissions < 8 else { pendingLock.unlock(); return }
        pendingSubmissions += 1; pendingLock.unlock()
        queue.async { [self] in
            defer { pendingLock.lock(); pendingSubmissions -= 1; pendingLock.unlock() }
            guard active, (gains[id] ?? 0) > 0 else { return }
            // One source handoff may contain several prerendered buffers. Admit
            // the bounded batch once rather than dropping its tail as a burst.
            for (input, host) in inputs { convert(input, at: host, id: id) }
        }
    }
    // Runs only on the mixer queue.
    private func convert(_ input: AVAudioPCMBuffer, at host: CMTime, id: UUID) {
        guard host.isNumeric else { return }
        let timestamp = Int64((host.seconds * 48000).rounded())
        // A PCM converter may retain part of an input and return it with the
        // next input. Output belongs to one continuous sample clock, not to
        // whichever input happened to trigger a conversion callback.
        let discontinuity = inputEnd[id].map { abs(timestamp - $0) > 2400 } ?? false
        if converters[id]?.inputFormat != input.format || discontinuity {
            converters[id] = AVAudioConverter(from: input.format, to: format)
            convertedEnd[id] = timestamp; segments[id] = []
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
                packets.append(.init(start: start, buffer: output))
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
        if sample < now - 24000 { sample = now - 960 }
        // Always send silence too: MPEG-TS has a continuous audio clock for
        // static slides, muted video and pauses.
        guard sample + 960 <= now, let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960),
              let channels = output.floatChannelData else { return }
        output.frameLength = 960
        for channel in 0..<2 { channels[channel].initialize(repeating: 0, count: 960) }
        for (id, packets) in segments {
            let gain = gains[id] ?? 0
            for packet in packets where gain > 0 {
                let begin = max(sample, packet.start), end = min(sample + 960, packet.start + Int64(packet.buffer.frameLength))
                guard begin < end, let source = packet.buffer.floatChannelData else { continue }
                for channel in 0..<2 {
                    for position in begin..<end {
                        channels[channel][Int(position - sample)] += source[channel][Int(position - packet.start)] * gain
                    }
                }
            }
            segments[id] = packets.filter { $0.start + Int64($0.buffer.frameLength) > sample + 960 }
        }
        for channel in 0..<2 { for i in 0..<960 { channels[channel][i] = min(1, max(-1, channels[channel][i])) } }
        ingest.offer(.audio(output, AVAudioTime(sampleTime: sample, atRate: 48000)))
        nextSample = sample + 960
    }
    func stop() { queue.async { [self] in active = false; timer?.cancel(); timer = nil; segments.removeAll(); converters.removeAll(); convertedEnd.removeAll(); inputEnd.removeAll() } }
}

nonisolated private final class SRTTapContext: @unchecked Sendable {
    let id = UUID()
    private struct PendingAudio { let buffer: AVAudioPCMBuffer; let time: CMTime; let byteCount: Int }
    private final class Client { weak var mixer: SRTProgramAudio?; init(_ mixer: SRTProgramAudio) { self.mixer = mixer } }
    private var clients: [ObjectIdentifier: Client] = [:]
    private let lock = NSLock()
    private var timebase: CMTimebase?
    private var playbackGain: Float = 0
    private var format: AVAudioFormat?
    private var pending: [PendingAudio] = []
    private var pendingBytes = 0
    private let maximumPendingBytes = SRTProgramAudio.maximumBufferedBytes
    private let maximumPendingBuffers = 256
    func add(_ mixer: SRTProgramAudio) { lock.lock(); clients[ObjectIdentifier(mixer)] = Client(mixer); lock.unlock() }
    func remove(_ mixer: SRTProgramAudio) {
        lock.lock(); clients[ObjectIdentifier(mixer)] = nil
        if clients.isEmpty { discardPending() }
        lock.unlock(); mixer.remove(id)
    }
    func updatePlayback(from player: AVPlayer, item: AVPlayerItem) {
        let current = player.currentItem === item
        let timebase = current ? item.timebase : nil
        let gain = current && !player.isMuted && player.rate != 0 ? player.volume : 0
        lock.lock(); defer { lock.unlock() }
        self.timebase = timebase
        playbackGain = gain
        let mixers = clients.values.compactMap(\.mixer)
        // Enqueue gain before any prerendered samples, including when playback
        // starts without another processing callback to deliver them.
        mixers.forEach { $0.setGain(gain, id: id) }
        flushPending(to: mixers)
    }
    // Called with the context lock held so gain, clock and sample submission
    // stay ordered across the playback and audio processing queues.
    private func flushPending(to mixers: [SRTProgramAudio]) {
        guard playbackGain > 0, let timebase, CMTimebaseGetEffectiveRate(timebase) > 0 else { return }
        var inputs: [(AVAudioPCMBuffer, CMTime)] = []
        pending.removeAll { packet in
            let host = CMSyncConvertTime(packet.time, from: timebase, to: CMClockGetHostTimeClock())
            guard host.isNumeric else { return false }
            inputs.append((packet.buffer, host))
            pendingBytes -= packet.byteCount
            return true
        }
        mixers.forEach { $0.append(inputs, id: id) }
    }
    private func discardPending() { pending.removeAll(); pendingBytes = 0 }
    func prepare(_ description: AudioStreamBasicDescription) {
        var value = description
        lock.lock(); discardPending(); format = AVAudioFormat(streamDescription: &value); lock.unlock()
    }
    func process(_ tap: MTAudioProcessingTap, frames: CMItemCount, buffers: UnsafeMutablePointer<AudioBufferList>,
                 actual: UnsafeMutablePointer<CMItemCount>, flags: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
        var range = CMTimeRange.invalid
        guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, &range, actual) == noErr, actual.pointee > 0 else { return }
        lock.lock()
        if flags.pointee & kMTAudioProcessingTapFlag_StartOfStream != 0 { discardPending() }
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
        guard byteCount <= maximumPendingBytes else { return }
        while !pending.isEmpty && (pending.count >= maximumPendingBuffers || pendingBytes + byteCount > maximumPendingBytes) {
            pendingBytes -= pending.removeFirst().byteCount
        }
        pending.append(.init(buffer: copy, time: range.start, byteCount: byteCount)); pendingBytes += byteCount
        flushPending(to: clients.values.compactMap(\.mixer))
    }
}

@MainActor
private final class SRTSharedPlayerAudioTap {
    fileprivate let context = SRTTapContext()
    var users = 0
    private weak var player: AVPlayer?
    private var item: AVPlayerItem?
    private var previous: AVAudioMix?
    private var installed: AVAudioMix?
    private var preparation: Task<Void, Never>?
    private var playbackObservations: [NSKeyValueObservation] = []
    private var observedTimebase: CMTimebase?
    private var timebaseObservers: [NSObjectProtocol] = []
    init(player: AVPlayer) {
        self.player = player
        let item = player.currentItem; self.item = item
        playbackObservations = [
            player.observe(\.rate) { [weak player, weak item, context] _, _ in
                if let player, let item { context.updatePlayback(from: player, item: item) }
            },
            player.observe(\.isMuted) { [weak player, weak item, context] _, _ in
                if let player, let item { context.updatePlayback(from: player, item: item) }
            },
            player.observe(\.volume) { [weak player, weak item, context] _, _ in
                if let player, let item { context.updatePlayback(from: player, item: item) }
            }
        ]
        if let item {
            playbackObservations.append(item.observe(\.status) { [weak self, weak player, weak item, context] _, _ in
                if let player, let item { context.updatePlayback(from: player, item: item) }
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
                    finalize: { tap in Unmanaged<SRTTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
                    prepare: { tap, _, format in Unmanaged<SRTTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee) },
                    unprepare: { _ in },
                    process: { tap, frames, _, buffers, actual, flags in
                        Unmanaged<SRTTapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().process(tap, frames: frames, buffers: buffers, actual: actual, flags: flags)
                    })
                var tap: MTAudioProcessingTap?
                guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks,
                    kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr, let tap else {
                    Unmanaged<SRTTapContext>.fromOpaque(retained).release(); continue
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
                    NotificationCenter.default.addObserver(forName: .init(name as String), object: clock, queue: nil) { [weak player, weak item, context] _ in
                        if let player, let item { context.updatePlayback(from: player, item: item) }
                    }
                }
            } ?? []
        }
        context.updatePlayback(from: player, item: item)
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
final class SRTPlayerAudioTap {
    private static var sources: [ObjectIdentifier: SRTSharedPlayerAudioTap] = [:]
    private let key: ObjectIdentifier
    private let shared: SRTSharedPlayerAudioTap
    private let mixer: SRTProgramAudio
    private var stopped = false
    init(player: AVPlayer, mixer: SRTProgramAudio) {
        key = ObjectIdentifier(player); self.mixer = mixer
        if let existing = Self.sources[key], existing.matches(player) { shared = existing }
        else { shared = SRTSharedPlayerAudioTap(player: player); Self.sources[key] = shared }
        shared.users += 1; shared.context.add(mixer); shared.refresh()
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
