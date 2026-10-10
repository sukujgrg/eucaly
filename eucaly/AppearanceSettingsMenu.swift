import SwiftUI

struct AppearanceSettingsMenu: View {
    @Binding var presentationFontScale: Double
    @Binding var presentationLyricsLayout: PresentationLyricsLayout
    @Binding var presentationTextAlignment: PresentationTextAlignment
    @Binding var presentationVerticalPosition: PresentationVerticalPosition
    @Binding var presentationPaddingScale: Double
    @Binding var thumbnailFontScale: Double
    @Binding var thumbnailScale: Double
    @State private var showsSettings = false

    var body: some View {
        Menu {
            Section("Slide Layout") {
                layoutPickers(showsCurrentValues: true)
                SettingsPercentageMenu(title: "Lyrics Padding", value: $presentationPaddingScale,
                                       presets: [0, 25, 50, 75, 100, 125, 150, 175, 200]) {
                    showsSettings = true
                }
            }

            Divider()
            Section("Projection") {
                SettingsPercentageMenu(title: "Font Size", value: $presentationFontScale,
                                       presets: [50, 80, 100, 120, 150, 200]) {
                    showsSettings = true
                }
            }

            Divider()
            Section("Thumbnails") {
                SettingsPercentageMenu(title: "Font Size", value: $thumbnailFontScale,
                                       presets: [30, 50, 80, 100, 120, 150, 200]) {
                    showsSettings = true
                }
                SettingsPercentageMenu(title: "Size", value: $thumbnailScale,
                                       presets: [60, 80, 100, 120, 140, 160]) {
                    showsSettings = true
                }
            }

            Divider()
            Button("Appearance Settings…") { showsSettings = true }
        } label: {
            Label("Appearance", systemImage: "gearshape")
        }
        .toolbarSettingsMenuStyle()
        .help("Appearance settings")
        .sheet(isPresented: $showsSettings) {
            ToolbarSettingsPanel(title: "Appearance", contentHeight: 560) {
                Form {
                    Section {
                        layoutPickers(showsCurrentValues: false)
                    } header: {
                        Text("Slide Layout")
                    } footer: {
                        Text(presentationLyricsLayout == .columns
                             ? "Applies to projection and thumbnails. Lyrics, meaning, translation, and transliteration appear side by side when present."
                             : "Applies to projection and thumbnails.")
                    }

                    Section {
                        AppearancePaddingRow(value: $presentationPaddingScale)
                    } footer: {
                        Text("Margins and gaps: 0% is edge to edge; 100% is the default.")
                    }

                    Section("Projection") {
                        SettingsSliderRow(title: "Projection Font Size", value: $presentationFontScale,
                                          range: 0.5...2, step: 0.1)
                    }

                    Section("Thumbnails") {
                        SettingsSliderRow(title: "Thumbnail Font Size", value: $thumbnailFontScale,
                                          range: 0.3...2, step: 0.1)
                        SettingsSliderRow(title: "Thumbnail Size", value: $thumbnailScale,
                                          range: 0.6...1.6, step: 0.1)
                    }
                }
                .formStyle(.grouped)
            }
        }
    }

    @ViewBuilder
    private func layoutPickers(showsCurrentValues: Bool) -> some View {
        Picker(showsCurrentValues ? "Layout: \(presentationLyricsLayout.title)" : "Layout",
               selection: $presentationLyricsLayout) {
            ForEach(PresentationLyricsLayout.allCases) { layout in
                Text(layout.title).tag(layout)
            }
        }
        .pickerStyle(.menu)
        Picker(showsCurrentValues ? "Lyrics Alignment: \(presentationTextAlignment.title)" : "Lyrics Alignment",
               selection: $presentationTextAlignment) {
            ForEach(PresentationTextAlignment.allCases) { alignment in
                Text(alignment.title).tag(alignment)
            }
        }
        .pickerStyle(.menu)
        Picker(showsCurrentValues ? "Lyrics Position: \(presentationVerticalPosition.title)" : "Lyrics Position",
               selection: $presentationVerticalPosition) {
            ForEach(PresentationVerticalPosition.allCases) { position in
                Text(position.title).tag(position)
            }
        }
        .pickerStyle(.menu)
    }
}

private struct AppearancePaddingRow: View {
    @Binding var value: Double
    @State private var draft: Double

    init(value: Binding<Double>) {
        _value = value
        _draft = State(initialValue: value.wrappedValue)
    }

    var body: some View {
        SettingsSliderRow(title: "Lyrics Padding", value: $draft, range: 0...2, step: 0.05)
            .task(id: draft) {
                guard draft != value else { return }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                value = draft
            }
            .onChange(of: value) { _, newValue in
                draft = newValue
            }
            .onDisappear {
                // Flush the last adjustment outside the view's lifecycle update.
                let finalValue = draft
                let preference = $value
                DispatchQueue.main.async {
                    if preference.wrappedValue != finalValue {
                        preference.wrappedValue = finalValue
                    }
                }
            }
    }
}
