import AVFoundation

/// The AudioCodec translate audio data to another format.
/// - seealso: https://developer.apple.com/library/ios/technotes/tn2236/_index.html
final class AudioCodec {
    static let defaultFrameCapacity: UInt32 = 1024
    static let defaultInputBuffersCursor = 0

    var settings: AudioCodecSettings = .default {
        didSet {
            if settings.invalidateConverter(oldValue) {
                inputFormat = nil
            } else {
                settings.apply(audioConverter, oldValue: oldValue)
            }
        }
    }

    var outputFormat: AVAudioFormat? {
        return audioConverter?.outputFormat
    }

    @AsyncStreamedFlow
    var outputStream: AsyncStream<(AVAudioBuffer, AVAudioTime)>

    /// This instance is running to process(true) or not(false).
    private(set) var isRunning = false
    private(set) var inputFormat: AVAudioFormat? {
        didSet {
            guard inputFormat != oldValue else {
                return
            }
            inputBuffers.removeAll()
            inputBuffersCursor = Self.defaultInputBuffersCursor
            outputBuffers.removeAll()
            audioConverter = makeAudioConverter()
            for _ in 0..<settings.format.inputBufferCounts {
                if let inputBuffer = makeInputBuffer() {
                    inputBuffers.append(inputBuffer)
                }
            }
        }
    }
    private var audioTime = AudioTime()
    private var ringBuffer: AudioRingBuffer?
    private var inputBuffers: [AVAudioBuffer] = []
    private var outputBuffers: [AVAudioBuffer] = []
    private var audioConverter: AVAudioConverter?
    private var inputBuffersCursor = AudioCodec.defaultInputBuffersCursor

    func append(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            return
        }
        switch settings.format {
        case .pcm:
            if let formatDescription = sampleBuffer.formatDescription, inputFormat?.formatDescription != formatDescription {
                inputFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)
            }
            guard let format = inputFormat, format.sampleRate > 0,
                  let blockBuffer = sampleBuffer.dataBuffer else { return }
            var offset = 0
            var presentationTimeStamp = sampleBuffer.presentationTimeStamp
            let frameDuration = CMTime(value: 1024, timescale: CMTimeScale(format.sampleRate))
            for i in 0..<sampleBuffer.numSamples {
                let sampleSize = CMSampleBufferGetSampleSize(sampleBuffer, at: i)
                guard sampleSize > 0, sampleSize <= blockBuffer.dataLength - offset else { return }
                defer { offset += sampleSize; presentationTimeStamp = presentationTimeStamp + frameDuration }
                guard sampleSize <= ADTSHeader.maximumFrameLength else { continue }
                var bytes = Data(count: sampleSize)
                let status = bytes.withUnsafeMutableBytes {
                    CMBlockBufferCopyDataBytes(blockBuffer, atOffset: offset, dataLength: sampleSize, destination: $0.baseAddress!)
                }
                guard status == noErr, let header = ADTSHeader(validating: bytes),
                      Int(header.aacFrameLength) == sampleSize else { continue }
                let byteCount = sampleSize - header.headerSize
                // AAC packet size is variable. The previous fixed 1024-byte
                // allocation raised an Objective-C exception on larger packets.
                let buffer = AVAudioCompressedBuffer(format: format, packetCapacity: 1, maximumPacketSize: byteCount)
                buffer.packetDescriptions?.pointee = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0, mDataByteSize: UInt32(byteCount))
                buffer.packetCount = 1
                buffer.byteLength = UInt32(byteCount)
                bytes.withUnsafeBytes { buffer.data.copyMemory(from: $0.baseAddress!.advanced(by: header.headerSize), byteCount: byteCount) }
                append(buffer, when: presentationTimeStamp.makeAudioTime())
            }
        default:
            break
        }
    }

    func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        inputFormat = audioBuffer.format
        let timestamp = when.makeTime()
        guard let audioConverter, isRunning, timestamp.isNumeric else {
            return
        }
        var error: NSError?
        if let audioBuffer = audioBuffer as? AVAudioPCMBuffer {
            ringBuffer?.append(audioBuffer, when: when)
        }
        if settings.format == .pcm || !audioTime.hasAnchor {
            audioTime.reset()
            audioTime.anchor(timestamp, sampleRate: audioConverter.outputFormat.sampleRate)
        }
        var consumedCompressedInput = false
        var outputStatus: AVAudioConverterOutputStatus = .endOfStream
        repeat {
            let outputBuffer = self.outputBuffer
            outputStatus = audioConverter.convert(to: outputBuffer, error: &error) { inNumberFrames, inputStatus in
                switch self.inputBuffer {
                case let cached as AVAudioCompressedBuffer:
                    guard !consumedCompressedInput, let source = audioBuffer as? AVAudioCompressedBuffer,
                          source.packetCount > 0 else {
                        inputStatus.pointee = .noDataNow; return nil
                    }
                    let inputBuffer: AVAudioCompressedBuffer
                    if cached.byteCapacity < source.byteLength || cached.packetCapacity < source.packetCount {
                        inputBuffer = AVAudioCompressedBuffer(format: source.format, packetCapacity: source.packetCount,
                            maximumPacketSize: source.maximumPacketSize)
                        self.inputBuffers[self.inputBuffersCursor] = inputBuffer
                    } else { inputBuffer = cached }
                    guard inputBuffer.copy(source) else { inputStatus.pointee = .noDataNow; return nil }
                    consumedCompressedInput = true
                    inputStatus.pointee = .haveData
                    return inputBuffer
                case let inputBuffer as AVAudioPCMBuffer:
                    if self.ringBuffer?.isDataAvailable(inNumberFrames) == true {
                        inputBuffer.frameLength = inNumberFrames
                        _ = self.ringBuffer?.render(inNumberFrames, ioData: inputBuffer.mutableAudioBufferList)
                        inputStatus.pointee = .haveData
                        return inputBuffer
                    } else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                default:
                    inputStatus.pointee = .noDataNow
                    return nil
                }
            }
            switch outputStatus {
            case .haveData:
                _outputStream.yield((outputBuffer, audioTime.at))
                let frames = (outputBuffer as? AVAudioPCMBuffer)?.frameLength
                    ?? audioConverter.outputFormat.streamDescription.pointee.mFramesPerPacket
                audioTime.advanced(AVAudioFramePosition(frames))
                inputBuffersCursor += 1
                if inputBuffersCursor == inputBuffers.count {
                    inputBuffersCursor = Self.defaultInputBuffersCursor
                }
            default:
                releaseOutputBuffer(outputBuffer)
            }
        } while(outputStatus == .haveData && settings.format != .pcm)
    }

    private func makeInputBuffer() -> AVAudioBuffer? {
        guard let inputFormat else {
            return nil
        }
        switch inputFormat.formatDescription.mediaSubType {
        case .linearPCM:
            let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: Self.defaultFrameCapacity)
            buffer?.frameLength = Self.defaultFrameCapacity
            return buffer
        default:
            return AVAudioCompressedBuffer(format: inputFormat, packetCapacity: 1, maximumPacketSize: 1024)
        }
    }

    private func makeAudioConverter() -> AVAudioConverter? {
        guard
            let inputFormat,
            let outputFormat = settings.format.makeOutputAudioFormat(inputFormat, sampleRate: settings.sampleRate, channelMap: settings.channelMap) else {
            return nil
        }
        let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        settings.apply(converter, oldValue: nil)
        if inputFormat.formatDescription.mediaSubType == .linearPCM {
            ringBuffer = AudioRingBuffer(inputFormat)
        }
        if self.outputFormat?.sampleRate != outputFormat.sampleRate {
            audioTime.reset()
        }
        if logger.isEnabledFor(level: .info) {
            logger.info("converter:", converter ?? "nil", ",inputFormat:", inputFormat, ",outputFormat:", outputFormat)
        }
        return converter
    }
}

extension AudioCodec: Codec {
    // MARK: Codec
    typealias Buffer = AVAudioBuffer

    var outputBuffer: AVAudioBuffer {
        guard let outputFormat = audioConverter?.outputFormat else {
            return .init()
        }
        if outputBuffers.isEmpty {
            for _ in 0..<settings.format.outputBufferCounts {
                outputBuffers.append(settings.format.makeAudioBuffer(outputFormat) ?? .init())
            }
        }
        return outputBuffers.removeFirst()
    }

    func releaseOutputBuffer(_ buffer: AVAudioBuffer) {
        outputBuffers.append(buffer)
    }

    private var inputBuffer: AVAudioBuffer {
        return inputBuffers[inputBuffersCursor]
    }
}

extension AudioCodec: Runner {
    // MARK: Running
    func startRunning() {
        guard !isRunning else {
            return
        }
        audioTime.reset()
        ringBuffer?.reset()
        audioConverter?.reset()
        isRunning = true
    }

    func stopRunning() {
        guard isRunning else {
            return
        }
        isRunning = false
        _outputStream.finish()
    }
}
