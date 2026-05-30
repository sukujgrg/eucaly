import SwiftUI

struct SidebarAudioSeekView: View {
    @ObservedObject var playbackProgress: PlaybackProgressStore
    let isDisabled: Bool
    let onSeek: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(audioTimeLabel(playbackProgress.backgroundAudioCurrentTime))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { playbackProgress.backgroundAudioCurrentTime },
                    set: { onSeek($0) }
                ),
                in: 0...max(playbackProgress.backgroundAudioDuration, 1),
                step: 0.25
            )
            .controlSize(.small)
            .disabled(isDisabled || playbackProgress.backgroundAudioDuration <= 0)

            Text(audioTimeLabel(playbackProgress.backgroundAudioDuration))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)
        }
    }

    private func audioTimeLabel(_ time: Double) -> String {
        guard time.isFinite, time > 0 else { return "0:00" }
        let totalSeconds = Int(time.rounded(.down))
        return "\(totalSeconds / 60):\(String(format: "%02d", totalSeconds % 60))"
    }
}
