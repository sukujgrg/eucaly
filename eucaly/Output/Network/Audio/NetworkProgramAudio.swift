@preconcurrency import AVFoundation

/// All sender buses use the same 960-sample host grid. A route change takes
/// effect on one future block boundary, so queues draining in different orders
/// cannot put the same music block on both the former and new destinations.
nonisolated final class NetworkMusicRoute: @unchecked Sendable {
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
nonisolated final class NetworkAudioDistribution: @unchecked Sendable {
    struct Target: Sendable {
        let id: UUID
        let send: @Sendable (NetworkAudioBlock) -> Void
    }
    private let lock = NSLock()
    private var targets: [Target] = []
    private var music: UUID?
    private let sharedMusicRoute: NetworkMusicRoute?
    init(musicRoute: NetworkMusicRoute? = nil) { sharedMusicRoute = musicRoute }
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
final class NetworkProgramAudio {
    var sourceFailed: ((String) -> Void)?
    private let distribution: NetworkAudioDistribution
    private let makeBus: (@escaping ProgramAudioBus.StemDelivery) -> ProgramAudioBus
    private var bus: ProgramAudioBus?
    private var videoSource: PlayerProgramAudioSource?
    private var musicSource: PlayerProgramAudioSource?
    private weak var runtime: OutputMediaRuntime?
    private weak var session: PresentationSession?
    private var timer: Timer?
    private var timingActivity: NSObjectProtocol?
    private var receivesMusic = false
    private var reportedFailures: Set<UUID> = []
    init(musicRoute: NetworkMusicRoute? = nil,
         makeBus: @escaping (@escaping ProgramAudioBus.StemDelivery) -> ProgramAudioBus = { ProgramAudioBus(deliverStems: $0) }) {
        distribution = NetworkAudioDistribution(musicRoute: musicRoute); self.makeBus = makeBus
    }
    #if DEBUG
    var isVideoSourcePreparedForTests: Bool { videoSource?.isPrepared == true }
    #endif
    func update(targets: [NetworkAudioDistribution.Target], music: UUID?, preparing: Bool, wantsVideo: Bool,
                runtime: OutputMediaRuntime, session: PresentationSession?) {
        self.runtime = wantsVideo ? runtime : nil
        self.session = music != nil ? session : nil
        receivesMusic = music.map { selected in targets.contains { $0.id == selected } } ?? false
        guard !targets.isEmpty || preparing else { stop(); return }
        if bus == nil {
            // This process owns the PCM clock; the separate helper's activity
            // cannot describe its deadlines. Keep the latency hint scoped to
            // live network audio. The output coordinator still owns sleep policy.
            timingActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Producing live network output audio")
            let distribution = distribution
            let bus = makeBus { distribution.deliver(program: $0, background: $1, time: $2) }
            bus.setSourceFailureHandler { [weak self] id, reason in
                Task { @MainActor [weak self] in
                    self?.reportFailure(id, reason: reason)
                }
            }
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
            if videoSource?.matches(player) != true {
                videoSource?.stop(); videoSource = PlayerProgramAudioSource(player: player, mixer: bus, programGain: runtime?.programAudioGain)
            }
            videoSource?.refresh()
        } else { videoSource?.stop(); videoSource = nil }
        if let player = session?.programBackgroundAudioPlayer {
            if musicSource?.matches(player) != true {
                musicSource?.stop(); musicSource = PlayerProgramAudioSource(player: player, mixer: bus, background: true, programGain: session?.backgroundAudioGain)
            }
            musicSource?.refresh()
        } else { musicSource?.stop(); musicSource = nil }
        for source in [videoSource, receivesMusic ? musicSource : nil].compactMap({ $0 }) {
            if let reason = source.failureReason { reportFailure(source.sourceID, reason: reason) }
        }
    }
    private func reportFailure(_ id: UUID, reason: String) {
        guard videoSource?.sourceID == id || (receivesMusic && musicSource?.sourceID == id),
              reportedFailures.insert(id).inserted else { return }
        sourceFailed?(reason)
    }
    func stop() {
        distribution.configure([], music: nil)
        timer?.invalidate(); timer = nil
        videoSource?.stop(); musicSource?.stop(); videoSource = nil; musicSource = nil
        receivesMusic = false; reportedFailures.removeAll()
        bus?.stop(); bus = nil; runtime = nil; session = nil
        if let timingActivity {
            self.timingActivity = nil
            ProcessInfo.processInfo.endActivity(timingActivity)
        }
    }
    deinit {
        timer?.invalidate(); bus?.stop()
        if let timingActivity { ProcessInfo.processInfo.endActivity(timingActivity) }
        let video = videoSource, music = musicSource
        DispatchQueue.main.async { video?.stop(); music?.stop() }
    }
}
