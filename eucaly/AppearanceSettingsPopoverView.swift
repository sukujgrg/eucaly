import SwiftUI

struct AppearanceSettingsPopoverView: View {
    @Binding var presentationFontScale: Double
    @Binding var presentationLyricsLayout: PresentationLyricsLayout
    @Binding var presentationTextAlignment: PresentationTextAlignment
    @Binding var presentationVerticalPosition: PresentationVerticalPosition
    @Binding var presentationPaddingScale: Double
    @Binding var thumbnailFontScale: Double
    @Binding var thumbnailScale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Appearance")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                Text("Slide Layout")
                    .font(.subheadline.weight(.semibold))
                Text("Applies to projection and thumbnails.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Layout", selection: $presentationLyricsLayout) {
                    ForEach(PresentationLyricsLayout.allCases) { layout in
                        Text(layout.title).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                if presentationLyricsLayout == .columns {
                    Text("Lyrics, meaning, translation, and transliteration appear side by side when present.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                AppearanceAlignmentRow(selection: $presentationTextAlignment)
                AppearanceVerticalPositionRow(selection: $presentationVerticalPosition)
                AppearancePaddingRow(value: $presentationPaddingScale)
            }

            Divider()

            AppearanceSliderRow(
                title: "Projection Font Size",
                value: $presentationFontScale,
                range: 0.5...2.0,
                step: 0.1
            )

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Text("Thumbnails")
                    .font(.subheadline.weight(.semibold))
                AppearanceSliderRow(
                    title: "Thumbnail Font Size",
                    value: $thumbnailFontScale,
                    range: 0.3...2.0,
                    step: 0.1
                )
                AppearanceSliderRow(
                    title: "Thumbnail Size",
                    value: $thumbnailScale,
                    range: 0.6...1.6,
                    step: 0.1
                )
            }
        }
        .padding(16)
        .frame(width: 340)
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
        VStack(alignment: .leading, spacing: 7) {
            AppearanceSliderRow(
                title: "Lyrics Padding",
                value: $draft,
                range: 0...2,
                step: 0.05
            )

            Text("Margins and gaps: 0% is edge to edge; 100% is the default.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
            // Preserve the last adjustment if the popover closes before the
            // debounce finishes, outside the view's lifecycle update.
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

private struct AppearanceVerticalPositionRow: View {
    @Binding var selection: PresentationVerticalPosition

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Lyrics Position")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Lyrics Position", selection: $selection) {
                ForEach(PresentationVerticalPosition.allCases) { position in
                    Text(position.title)
                        .tag(position)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

private struct AppearanceAlignmentRow: View {
    @Binding var selection: PresentationTextAlignment

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Lyrics Alignment")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Lyrics Alignment", selection: $selection) {
                ForEach(PresentationTextAlignment.allCases) { alignment in
                    Image(systemName: alignment.systemImage)
                        .tag(alignment)
                        .help(alignment.title)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }
}

private struct AppearanceSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Text("\(Int((value * 100).rounded()))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}
