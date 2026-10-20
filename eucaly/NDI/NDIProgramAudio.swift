@preconcurrency import AVFoundation

/// All sender buses use the same 960-sample host grid. A route change takes
/// effect on one future block boundary, so queues draining in different orders
/// cannot put the same music block on both the former and new destinations.
nonisolated final class NDIMusicRoute: @unchecked Sendable {
    private struct Change { let sample: Int64; let destination: UUID? }
    private let lock = NSLock()
    private var changes: [Change] = []
    func select(_ destination: UUID?, effectiveSample: Int64? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard changes.last?.destination != destination || changes.isEmpty else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock()).convertScale(48000, method: .roundHalfAwayFromZero).value
        let boundary = effectiveSample ?? ((now / 960 + 1) * 960)
        if changes.last?.sample == boundary { changes.removeLast() }
        changes.append(.init(sample: boundary, destination: destination))
        if changes.count > 64 { changes.removeFirst(changes.count - 64) }
    }
    func destination(at sample: Int64) -> UUID? {
        lock.lock(); defer { lock.unlock() }
        return changes.last(where: { $0.sample <= sample })?.destination
    }
}

/// The route is sampled once per 20 ms block. Music is added to at most one
/// output, even while the operator changes routing; video follows each output’s owning workspace.
nonisolated final class NDIAudioDistribution: @unchecked Sendable {
    struct Target: Sendable {
        let id: UUID
        let send: @Sendable (NDIAudioBlock) -> Void
    }
    private let lock = NSLock()
    private var targets: [Target] = []
    private var music: UUID?
    private let sharedMusicRoute: NDIMusicRoute?
    init(musicRoute: NDIMusicRoute? = nil) { sharedMusicRoute = musicRoute }
    func configure(_ targets: [Target], music: UUID?) {
        lock.lock(); self.targets = Array(targets.prefix(16)); self.music = music; lock.unlock()
    }
    func remove(_ id: UUID) { lock.lock(); targets.removeAll { $0.id == id }; lock.unlock() }
    func deliver(program: AVAudioPCMBuffer, background: AVAudioPCMBuffer, time: AVAudioTime) {
        guard program.frameLength == 960, background.frameLength == 960,
              program.format.channelCount == 2, background.format.channelCount == 2,
              let video = program.floatChannelData, let song = background.floatChannelData else { return }
        lock.lock(); let outputs = targets, localSelection = music; lock.unlock()
        let selected: UUID?
        if let sharedMusicRoute { selected = sharedMusicRoute.destination(at: time.sampleTime) }
        else { selected = localSelection }
        for output in outputs {
            var samples = [Float](repeating: 0, count: 1920)
            for channel in 0..<2 {
                for frame in 0..<960 {
                    let sum = video[channel][frame] + (selected == output.id ? song[channel][frame] : 0)
                    samples[channel * 960 + frame] = sum.isFinite ? min(1, max(-1, sum)) : 0
                }
            }
            let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
            output.send(.init(sampleTime: time.sampleTime, pcm: data))
        }
    }
}

@MainActor
final class NDIProgramAudio {
    private let distribution: NDIAudioDistribution
    private let makeBus: (@escaping ProgramAudioBus.StemDelivery) -> ProgramAudioBus
    private var bus: ProgramAudioBus?
    private var videoTap: PlayerAudioTap?
    private var musicTap: PlayerAudioTap?
    private weak var runtime: OutputMediaRuntime?
    private weak var session: PresentationSession?
    private var timer: Timer?
    init(musicRoute: NDIMusicRoute? = nil,
         makeBus: @escaping (@escaping ProgramAudioBus.StemDelivery) -> ProgramAudioBus = { ProgramAudioBus(deliverStems: $0) }) {
        distribution = NDIAudioDistribution(musicRoute: musicRoute); self.makeBus = makeBus
    }
    func update(targets: [NDIAudioDistribution.Target], music: UUID?, preparing: Bool, wantsVideo: Bool,
                runtime: OutputMediaRuntime, session: PresentationSession?) {
        self.runtime = wantsVideo ? runtime : nil
        self.session = music != nil ? session : nil
        guard !targets.isEmpty || preparing else { stop(); return }
        if bus == nil {
            let distribution = distribution
            let bus = makeBus { distribution.deliver(program: $0, background: $1, time: $2) }
            self.bus = bus; bus.start(at: CMClockGetTime(CMClockGetHostTimeClock()))
            timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        refresh()
        let distribution = distribution
        bus?.updateDelivery { distribution.configure(targets, music: music) }
    }
    private func refresh() {
        guard let bus else { return }
        if let player = runtime?.program {
            if videoTap?.matches(player) != true { videoTap?.stop(); videoTap = PlayerAudioTap(player: player, mixer: bus) }
            videoTap?.refresh()
        } else { videoTap?.stop(); videoTap = nil }
        if let player = session?.programBackgroundAudioPlayer {
            if musicTap?.matches(player) != true { musicTap?.stop(); musicTap = PlayerAudioTap(player: player, mixer: bus, background: true) }
            musicTap?.refresh()
        } else { musicTap?.stop(); musicTap = nil }
    }
    func remove(_ id: UUID) { distribution.remove(id) }
    func stop() {
        distribution.configure([], music: nil)
        timer?.invalidate(); timer = nil
        videoTap?.stop(); musicTap?.stop(); videoTap = nil; musicTap = nil
        bus?.stop(); bus = nil; runtime = nil; session = nil
    }
    deinit {
        timer?.invalidate(); bus?.stop()
        let video = videoTap, music = musicTap
        DispatchQueue.main.async { video?.stop(); music?.stop() }
    }
}
