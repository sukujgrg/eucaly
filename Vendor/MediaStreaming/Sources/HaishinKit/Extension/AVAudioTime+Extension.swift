import AVFoundation
import CoreMedia
import Foundation

extension AVAudioTime {
    package func makeTime() -> CMTime {
        if isHostTimeValid {
            return .init(seconds: AVAudioTime.seconds(forHostTime: hostTime), preferredTimescale: 1000000000)
        }
        guard isSampleTimeValid, sampleRate > 0 else { return .invalid }
        if let scale = CMTimeScale(exactly: sampleRate) {
            return .init(value: sampleTime, timescale: scale)
        }
        return .init(seconds: Double(sampleTime) / sampleRate, preferredTimescale: 1000000000)
    }
}
