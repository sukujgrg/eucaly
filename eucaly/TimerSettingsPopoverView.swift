import SwiftUI

struct TimerSettingsPopoverView: View {
    @ObservedObject var session: PresentationSession
    @Binding var overlayScaleDraft: Double
    @Binding var countdownMinutes: Int

    let onOverlayScaleDraftChange: (Double) -> Void
    let onSetOverlayMode: (PresentationSession.OverlayMode) -> Void
    let onStartCountdown: (Int) -> Void
    let onStopCountdown: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Overlay")
                .font(.headline)

            Picker(
                "Overlay",
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
                    Text("Size")
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
                    set: { newValue in
                        let newMinutes = Int(newValue.rounded())
                        guard newMinutes != countdownMinutes else { return }
                        countdownMinutes = newMinutes
                        if session.isCountdownRunning {
                            onStartCountdown(newMinutes)
                        }
                    }
                ),
                in: 1...30,
                step: 1
            )
            .controlSize(.small)

            HStack(spacing: 8) {
                Button(session.isCountdownRunning ? "Restart" : "Start") {
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
}
