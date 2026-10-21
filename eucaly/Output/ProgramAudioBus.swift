@preconcurrency import AVFoundation

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

/// Mixes only explicitly selected live program players. Preview playback and other apps can
/// never enter this bus. AVPlayer's local output volume is independent of asset
/// PCM; managed players supply their separate programme gain to the output bus.
nonisolated final class ProgramAudioBus: @unchecked Sendable {
    typealias StemDelivery = @Sendable (AVAudioPCMBuffer, AVAudioPCMBuffer, AVAudioTime) -> Void
    struct Input {
        let buffer: AVAudioPCMBuffer
        let range: CMTimeRange
        let startsNewStream: Bool
        init(_ buffer: AVAudioPCMBuffer, at time: CMTime, duration: CMTime? = nil, startsNewStream: Bool = false) {
            self.buffer = buffer
            range = CMTimeRange(start: time, duration: duration ?? CMTime(
                seconds: Double(buffer.frameLength) / buffer.format.sampleRate,
                preferredTimescale: CMTimeScale(buffer.format.sampleRate.rounded())))
            self.startsNewStream = startsNewStream
        }
        var isUnmappedPadding: Bool {
            guard range.duration == .zero else { return false }
            // All-zero bytes are silence in these signed/float PCM formats.
            // Keep unknown formats and nonzero processing tails conservatively.
            switch buffer.format.commonFormat {
            case .pcmFormatFloat32, .pcmFormatFloat64, .pcmFormatInt16, .pcmFormatInt32: break
            default: return false
            }
            let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            return !buffers.isEmpty && buffers.allSatisfy { audio in
                guard let data = audio.mData else { return false }
                return UnsafeRawBufferPointer(start: data, count: Int(audio.mDataByteSize)).allSatisfy { $0 == 0 }
            }
        }
    }
    static let maximumBufferedBytes = 8 * 1024 * 1024
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
    private struct Conversion {
        let converter: AVAudioConverter
        var assetEnd: CMTime
        var outputEnd: Int64
        var hasProcessingTail: Bool
    }
    private var conversions: [UUID: Conversion] = [:]
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
    private var sourceFailure: (@Sendable (UUID, String) -> Void)?
    init(deliver: @escaping @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void) { self.deliver = deliver; deliverStems = nil }
    init(deliverStems: @escaping StemDelivery) { self.deliverStems = deliverStems; deliver = nil }
    func setSourceFailureHandler(_ handler: @escaping @Sendable (UUID, String) -> Void) {
        queue.async { [self] in sourceFailure = handler }
    }
    func sourceFailed(_ id: UUID, reason: String) {
        queue.async { [self] in guard active else { return }; sourceFailure?(id, reason) }
    }
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
            #if DEBUG
            NDIAudioTrace.record("playback-clock", sample: clock.start, source: id,
                mediaSample: clock.mediaSample(clock.start), rate: clock.rate, gain: clock.gain)
            #endif
        }
    }
    func remove(_ id: UUID) { queue.async { [self] in segments[id] = nil; gains[id] = nil; clocks[id] = nil; silenced.remove(id); conversions[id] = nil; backgroundInputs.remove(id) } }
    @discardableResult
    func append(_ inputs: [Input], id: UUID) -> Bool {
        guard !inputs.isEmpty else { return true }
        pendingLock.lock()
        guard pendingSubmissions < 8 else { pendingLock.unlock(); return false }
        pendingSubmissions += 1; pendingLock.unlock()
        queue.async { [self] in
            defer { pendingLock.lock(); pendingSubmissions -= 1; pendingLock.unlock() }
            guard active else { return }
            // One source handoff may contain several prerendered buffers. Admit
            // the bounded batch once rather than dropping its tail as a burst.
            for input in inputs { convert(input, id: id) }
        }
        return true
    }
    // Runs only on the mixer queue.
    private func convert(_ source: Input, id: UUID) {
        let input = source.buffer, time = source.range.start
        guard time.isNumeric, source.range.duration.isNumeric, source.range.duration >= .zero,
              !source.isUnmappedPadding else { return }
        let timestamp = time.convertScale(48000, method: .roundHalfAwayFromZero).value
        let mapped = source.range.duration > .zero
        let previous = conversions[id]
        // An effects tail has no new asset anchor. It can continue an existing
        // converter clock, but cannot establish a programme source by itself.
        guard mapped || previous != nil else { return }
        // A PCM converter may retain part of an input and return it with the
        // next input. Output belongs to one continuous sample clock, not to
        // whichever input happened to trigger a conversion callback.
        // Use the tap's asset range to detect continuity. Its duration need
        // not equal PCM frames / format rate. Inferring it from that count
        // resets valid contiguous input and discards converter state.
        // One sample covers rounding onto the mixer's 48 kHz grid.
        let discontinuity = mapped && (source.startsNewStream || (previous.map {
            $0.hasProcessingTail || abs((time - $0.assetEnd).convertScale(48000, method: .roundHalfAwayFromZero).value) > 1
        } ?? false)
        )
        var state: Conversion
        if previous?.converter.inputFormat != input.format || discontinuity {
            guard let converter = AVAudioConverter(from: input.format, to: format) else { return }
            state = .init(converter: converter, assetEnd: mapped ? CMTimeRangeGetEnd(source.range) : previous!.assetEnd,
                          outputEnd: mapped ? timestamp : previous!.outputEnd, hasProcessingTail: !mapped)
        } else {
            state = previous!
            if mapped { state.assetEnd = CMTimeRangeGetEnd(source.range) }
            state.hasProcessingTail = !mapped
        }
        let converter = state.converter
        var supplied = false; var packets = segments[id] ?? []
        var conversion: AVAudioConverterOutputStatus
        repeat {
            let output: AVAudioPCMBuffer
            if input.format == format {
                // Streaming conversion batches even identical PCM formats:
                // a 4,474-frame callback can initially yield only 4,096 frames.
                // The copied input is immutable, so retain all of it directly
                // rather than waiting for another callback to release its tail.
                output = input
                conversion = .inputRanDry
            } else {
                guard let converted = AVAudioPCMBuffer(pcmFormat: format,
                    frameCapacity: AVAudioFrameCount(Double(input.frameLength) * 48000 / input.format.sampleRate + 64)) else { break }
                var error: NSError?
                conversion = converter.convert(to: converted, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true; status.pointee = .haveData; return input
                }
                guard error == nil else { break }
                output = converted
            }
            if output.frameLength > 0 {
                let start = state.outputEnd
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
                state.outputEnd = start + Int64(output.frameLength)
                #if DEBUG
                Self.tracePCM("convert-output", buffer: output, source: id, mediaSample: start)
                #endif
            }
        } while conversion == .haveData
        conversions[id] = state
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
            #if DEBUG
            var requested = 0, covered = 0
            var firstMediaSample: Int64?
            #endif
            let history = clocks[id] ?? [.init(start: .min, hostAnchor: 0, mediaAnchor: 0, rate: 1, gain: gains[id] ?? 0)]
            let destination = backgroundInputs.contains(id) ? (background?.floatChannelData ?? channels) : channels
            for (index, clock) in history.enumerated() where clock.rate > 0 {
                let begin = max(sample, clock.start), end = min(sample + 960, index + 1 < history.count ? history[index + 1].start : .max)
                guard begin < end else { continue }
                var packetIndex = 0
                for position in begin..<end {
                    let sourceSample = clock.mediaSample(position)
                    #if DEBUG
                    if clock.gain > 0, !silenced.contains(id) {
                        requested += 1
                        if firstMediaSample == nil { firstMediaSample = sourceSample }
                    }
                    #endif
                    while packetIndex < packets.count && packets[packetIndex].end <= sourceSample { packetIndex += 1 }
                    guard clock.gain > 0, !silenced.contains(id), packetIndex < packets.count else { continue }
                    let packet = packets[packetIndex]
                    guard sourceSample >= packet.start, let source = packet.buffer.floatChannelData else { continue }
                    #if DEBUG
                    covered += 1
                    #endif
                    for channel in 0..<2 {
                        destination[channel][Int(position - sample)] += source[channel][packet.offset + Int(sourceSample - packet.start)] * clock.gain
                    }
                }
            }
            // A running player's clock can re-anchor backward during recovery.
            // Keep decoded history within the existing byte/packet bounds in
            // convert(), so that correction never waits for decoding again.
            #if DEBUG
            if requested > 0 {
                NDIAudioTrace.record("mixer-coverage", sample: sample, source: id,
                    mediaSample: firstMediaSample, frames: requested, covered: covered, sampleRate: format.sampleRate)
            }
            #endif
            if let last = history.lastIndex(where: { $0.start < sample + 960 }), clocks[id] != nil {
                clocks[id] = Array(history.suffix(from: last))
            }
        }
        for channel in 0..<2 { for i in 0..<960 { channels[channel][i] = min(1, max(-1, channels[channel][i])) } }
        let time = AVAudioTime(sampleTime: sample, atRate: 48000)
        #if DEBUG
        Self.tracePCM("mix-output", buffer: output, sample: sample)
        #endif
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
            conversions.removeAll()
        }
    }
    #if DEBUG
    fileprivate static func tracePCM(_ event: String, buffer: AVAudioPCMBuffer, sample: Int64 = 0,
                                     source: UUID? = nil, mediaSample: Int64? = nil) {
        guard NDIAudioTrace.isEnabled, let data = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength), stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        let right = buffer.format.channelCount > 1 ? (buffer.format.isInterleaved ? data[0] + 1 : data[1]) : data[0]
        NDIAudioTrace.record(event, sample: sample, source: source, mediaSample: mediaSample,
            frames: frames, sampleRate: buffer.format.sampleRate,
            leftRMS: NDIAudioTrace.rms(data[0], frames: frames, stride: stride),
            rightRMS: NDIAudioTrace.rms(right, frames: frames, stride: stride))
    }
    #endif
}
