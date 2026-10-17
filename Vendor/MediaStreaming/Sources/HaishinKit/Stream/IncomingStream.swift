@preconcurrency import AVFoundation
import Foundation

/// An actor that provides a stream playback feature.
package final actor IncomingStream {
    public private(set) var isRunning = false
    /// The sound transform value control.
    public var soundTransfrom: SoundTransform? {
        get async {
            return await audioPlayerNode?.soundTransfrom
        }
    }
    private lazy var mediaLink = MediaLink()
    private lazy var audioCodec = AudioCodec()
    private lazy var videoCodec = VideoCodec()
    private weak var stream: (any StreamConvertible)?
    private var audioPlayerNode: AudioPlayerNode?
    private var videoOutputIsScheduled = true

    /// Creates a new instance.
    public init(_ stream: some StreamConvertible) {
        self.stream = stream
    }

    /// Disable before starting when the host schedules decoded video itself.
    package func setVideoOutputIsScheduled(_ scheduled: Bool) {
        guard !isRunning else { return }
        videoOutputIsScheduled = scheduled
    }

    /// Sets the sound transform value control.
    public func setSoundTransform(_ soundTransfrom: SoundTransform) async {
        await audioPlayerNode?.setSoundTransfrom(soundTransfrom)
    }

    /// Appends a sample buffer for playback.
    public func append(_ buffer: CMSampleBuffer) {
        switch buffer.formatDescription?.mediaType {
        case .audio:
            audioCodec.append(buffer)
        case .video:
            videoCodec.append(buffer)
        default:
            break
        }
    }

    /// Appends an audio buffer for playback.
    public func append(_ buffer: AVAudioBuffer, when: AVAudioTime) {
        audioCodec.append(buffer, when: when)
    }

    /// Attaches an audio player.
    public func attachAudioPlayer(_ audioPlayer: AudioPlayer?) async {
        await audioPlayerNode?.detach()
        audioPlayerNode = await audioPlayer?.makePlayerNode()
        await mediaLink.setAudioPlayer(audioPlayerNode)
    }
}

extension IncomingStream: AsyncRunner {
    // MARK: AsyncRunner
    public func startRunning() {
        guard !isRunning else {
            return
        }
        audioCodec.settings.format = .pcm
        let videoOutput = videoCodec.outputStream
        let audioOutput = audioCodec.outputStream
        videoCodec.startRunning()
        audioCodec.startRunning()
        isRunning = true
        if videoOutputIsScheduled {
            Task {
                await mediaLink.startRunning()
                for await video in await mediaLink.dequeue {
                    await stream?.append(video)
                }
            }
        }
        Task {
            for await video in videoOutput {
                if videoOutputIsScheduled {
                    await mediaLink.enqueue(video)
                } else {
                    await stream?.append(video)
                }
            }
        }
        Task {
            await audioPlayerNode?.startRunning()
            for await audio in audioOutput {
                await audioPlayerNode?.enqueue(audio.0, when: audio.1)
                await stream?.append(audio.0, when: audio.1)
            }
        }
    }

    public func stopRunning() {
        guard isRunning else {
            return
        }
        videoCodec.stopRunning()
        audioCodec.stopRunning()
        if videoOutputIsScheduled { Task { await mediaLink.stopRunning() } }
        Task { await audioPlayerNode?.stopRunning() }
        isRunning = false
    }
}
