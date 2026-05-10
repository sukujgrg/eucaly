import SwiftUI

struct TimerSettingsPopoverView: View {
    @ObservedObject var session: PresentationSession
    @Binding var overlayScaleDraft: Double
    @Binding var countdownMinutes: Int

    let onOverlayScaleDraftChange: (Double) -> Void
    let onSetOverlayMode: (PresentationSession.OverlayMode) -> Void
    let onStartCountdown: (Int) -> Void
    let onStopCountdown: () -> Void
    let onSetClockVisible: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Timer")
                .font(.headline)

            Picker(
                "Overlay Mode",
                selection: Binding(
                    get: { session.overlayMode },
                    set: { newMode in
                        onSetOverlayMode(newMode)
                    }
                )
            ) {
                ForEach(PresentationSession.OverlayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text("Overlay Size")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text("\(Int(overlayScaleDraft * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 44, alignment: .trailing)
                }

                Slider(value: $overlayScaleDraft, in: 0.5...6.0, step: 0.1)
                    .controlSize(.small)
                    .onChange(of: overlayScaleDraft) { _, newValue in
                        onOverlayScaleDraftChange(newValue)
                    }
            }

            if session.overlayMode == .countdown {
                countdownControls
            } else {
                clockControls
            }
        }
        .padding(16)
        .frame(width: 320)
    }

    private var countdownControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Duration")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(countdownMinutes)m")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Slider(
                value: Binding(
                    get: { Double(countdownMinutes) },
                    set: { countdownMinutes = Int($0.rounded()) }
                ),
                in: 1...30,
                step: 1
            )
            .controlSize(.small)

            HStack(spacing: 8) {
                Button(session.isCountdownRunning ? "Restart Timer" : "Start Timer") {
                    onStartCountdown(countdownMinutes)
                }
                .primaryActionStyle()

                Button("Stop") {
                    onStopCountdown()
                }
                .buttonStyle(.bordered)
                .disabled(!session.isCountdownRunning)
            }
        }
    }

    private var clockControls: some View {
        HStack(spacing: 8) {
            Button(session.isClockVisible ? "Hide Clock" : "Show Clock") {
                onSetClockVisible(!session.isClockVisible)
            }
            .primaryActionStyle()
        }
    }
}
