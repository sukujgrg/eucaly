import SwiftUI

struct TimerSettingsMenu: View {
    @ObservedObject var session: PresentationSession
    @Binding var overlayScaleDraft: Double
    @Binding var countdownMinutes: Int
    @State private var showsSettings = false

    let onOverlayScaleDraftChange: (Double) -> Void
    let onSetOverlayMode: (PresentationSession.OverlayMode) -> Void
    let onStartCountdown: (Int) -> Void
    let onStopCountdown: () -> Void

    private var modeSelection: Binding<PresentationSession.OverlayMode> {
        Binding(get: { session.overlayMode }, set: onSetOverlayMode)
    }

    private var scaleSelection: Binding<Double> {
        Binding(get: { overlayScaleDraft }, set: { newValue in
            guard newValue != overlayScaleDraft else { return }
            overlayScaleDraft = newValue
            onOverlayScaleDraftChange(newValue)
        })
    }

    private var durationSelection: Binding<Int> {
        Binding(get: { countdownMinutes }, set: { newValue in
            guard newValue != countdownMinutes else { return }
            countdownMinutes = newValue
            if session.isCountdownRunning { onStartCountdown(newValue) }
        })
    }

    private var durationChoices: [Int] {
        Array(Set([1, 3, 5, 10, 15, 20, 30, countdownMinutes])).sorted()
    }

    var body: some View {
        Menu {
            Picker("Overlay", selection: modeSelection) {
                ForEach(PresentationSession.OverlayMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.inline)

            SettingsPercentageMenu(title: "Size", value: scaleSelection,
                                   presets: [50, 100, 150, 200, 300, 400, 500, 600]) {
                showsSettings = true
            }

            if session.overlayMode == .countdown {
                Divider()
                Section {
                    Menu("Duration: \(countdownMinutes) min") {
                        Picker("Duration", selection: durationSelection) {
                            ForEach(durationChoices, id: \.self) { minutes in
                                Text(minutes == 1 ? "1 minute" : "\(minutes) minutes").tag(minutes)
                            }
                        }
                        .pickerStyle(.inline)
                        Divider()
                        Button("Adjust…") { showsSettings = true }
                    }
                    countdownActions
                } header: {
                    Text(session.isCountdownRunning ? "Countdown · Running" : "Countdown · Stopped")
                }
            }

            Divider()
            Button("Overlay Settings…") { showsSettings = true }
        } label: {
            Label("Overlay", systemImage: "clock")
        }
        .toolbarSettingsMenuStyle()
        .help("Overlay settings")
        .sheet(isPresented: $showsSettings) {
            ToolbarSettingsPanel(title: "Overlay", contentHeight: session.overlayMode == .countdown ? 320 : 190) {
                Form {
                    Section {
                        Picker("Show", selection: modeSelection) {
                            ForEach(PresentationSession.OverlayMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.menu)
                        SettingsSliderRow(title: "Size", value: scaleSelection, range: 0.5...6, step: 0.1)
                    }
                    if session.overlayMode == .countdown {
                        Section("Countdown") {
                            VStack(spacing: 8) {
                                LabeledContent("Duration", value: "\(countdownMinutes) min")
                                Slider(value: Binding(
                                    get: { Double(countdownMinutes) },
                                    set: { durationSelection.wrappedValue = Int($0.rounded()) }
                                ), in: 1...30, step: 1)
                                .labelsHidden()
                                .accessibilityLabel("Countdown duration in minutes")
                            }
                            HStack(spacing: 8) { countdownActions }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    @ViewBuilder
    private var countdownActions: some View {
        Button(session.isCountdownRunning ? "Restart Countdown" : "Start Countdown") {
            onStartCountdown(countdownMinutes)
        }
        Button("Stop Countdown", action: onStopCountdown)
            .disabled(!session.isCountdownRunning)
    }
}
