@preconcurrency import AVFoundation
import MediaToolbox

/// Taps only explicitly selected live program players. Preview playback and other apps can
/// never enter this bus. The tap leaves the player's local audio untouched.
nonisolated final class SRTProgramAudio: @unchecked Sendable {
    private struct Segment { let start: Int64; let buffer: AVAudioPCMBuffer }
    private let queue = DispatchQueue(label: "eucaly.srt.program-audio")
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
    private var segments: [UUID: [Segment]] = [:]
    private var gains: [UUID: Float] = [:]
    private var converters: [UUID: AVAudioConverter] = [:]
    private var nextSample: Int64?
    private var timer: DispatchSourceTimer?
    private var active = true
    private let pendingLock = NSLock()
    private var pendingBuffers = 0
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
            if value == 0 { segments[id] = [] }
        }
    }
    func remove(_ id: UUID) { queue.async { [self] in segments[id] = nil; gains[id] = nil; converters[id] = nil } }
    func append(_ input: AVAudioPCMBuffer, at host: CMTime, id: UUID) {
        guard host.isNumeric else { return }
        pendingLock.lock()
        guard pendingBuffers < 8 else { pendingLock.unlock(); return }
        pendingBuffers += 1; pendingLock.unlock()
        queue.async { [self] in
            defer { pendingLock.lock(); pendingBuffers -= 1; pendingLock.unlock() }
            guard active, (gains[id] ?? 0) > 0 else { return }
            if converters[id]?.inputFormat != input.format { converters[id] = AVAudioConverter(from: input.format, to: format) }
            guard let converter = converters[id], let output = AVAudioPCMBuffer(pcmFormat: format,
                frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 48000 / input.format.sampleRate + 64)) else { return }
            var supplied = false; var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if supplied { status.pointee = .noDataNow; return nil }
                supplied = true; status.pointee = .haveData; return input
            }
            guard error == nil, output.frameLength > 0 else { return }
            var packets = segments[id] ?? []
            packets.append(.init(start: Int64(host.seconds * 48000), buffer: output))
            if packets.count > 64 { packets.removeFirst(packets.count - 64) }
            segments[id] = packets
        }
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
    func stop() { queue.async { [self] in active = false; timer?.cancel(); timer = nil; segments.removeAll(); converters.removeAll() } }
}

nonisolated private final class SRTTapContext: @unchecked Sendable {
    let id = UUID()
    private final class Client { weak var mixer: SRTProgramAudio?; init(_ mixer: SRTProgramAudio) { self.mixer = mixer } }
    private var clients: [ObjectIdentifier: Client] = [:]
    private let lock = NSLock()
    private var timebase: CMTimebase?
    private var format: AVAudioFormat?
    func add(_ mixer: SRTProgramAudio) { lock.lock(); clients[ObjectIdentifier(mixer)] = Client(mixer); lock.unlock() }
    func remove(_ mixer: SRTProgramAudio) { lock.lock(); clients[ObjectIdentifier(mixer)] = nil; lock.unlock(); mixer.remove(id) }
    func gain(_ value: Float) {
        lock.lock(); let mixers = clients.values.compactMap(\.mixer); lock.unlock()
        mixers.forEach { $0.setGain(value, id: id) }
    }
    func prepare(_ description: AudioStreamBasicDescription) {
        var value = description
        lock.lock(); format = AVAudioFormat(streamDescription: &value); lock.unlock()
    }
    func setTimebase(_ value: CMTimebase?) { lock.lock(); timebase = value; lock.unlock() }
    func process(_ tap: MTAudioProcessingTap, frames: CMItemCount, buffers: UnsafeMutablePointer<AudioBufferList>,
                 actual: UnsafeMutablePointer<CMItemCount>, flags: UnsafeMutablePointer<MTAudioProcessingTapFlags>) {
        var range = CMTimeRange.invalid
        guard MTAudioProcessingTapGetSourceAudio(tap, frames, buffers, flags, &range, actual) == noErr, actual.pointee > 0 else { return }
        lock.lock(); let format = format, timebase = timebase; lock.unlock()
        guard let format, let timebase, CMTimebaseGetRate(timebase) > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(actual.pointee)) else { return }
        copy.frameLength = AVAudioFrameCount(actual.pointee)
        let source = UnsafeMutableAudioBufferListPointer(buffers), target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for i in 0..<min(source.count, target.count) {
            if let from = source[i].mData, let to = target[i].mData {
                memcpy(to, from, min(Int(source[i].mDataByteSize), Int(target[i].mDataByteSize)))
            }
        }
        let host = CMSyncConvertTime(range.start, from: timebase, to: CMClockGetHostTimeClock())
        lock.lock(); let mixers = clients.values.compactMap(\.mixer); lock.unlock()
        mixers.forEach { $0.append(copy, at: host, id: id) }
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
    init(player: AVPlayer) {
        self.player = player
        let item = player.currentItem; self.item = item
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
        context.setTimebase(item?.timebase)
        context.gain(player?.isMuted == true || player?.rate == 0 ? 0 : player?.volume ?? 0)
    }
    func stop() {
        preparation?.cancel(); preparation = nil
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
