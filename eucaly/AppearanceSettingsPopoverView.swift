import SwiftUI

struct AppearanceSettingsPopoverView: View {
    @Binding var presentationFontScale: Double
    @Binding var presentationTextAlignment: PresentationTextAlignment
    @Binding var presentationVerticalPosition: PresentationVerticalPosition
    @Binding var thumbnailFontScale: Double
    @Binding var thumbnailScale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Lyrics Appearance")
                .font(.headline)

            AppearanceSliderRow(
                title: "Lyrics Font Size",
                value: $presentationFontScale,
                range: 0.5...2.0,
                step: 0.1
            )

            AppearanceAlignmentRow(selection: $presentationTextAlignment)

            AppearanceVerticalPositionRow(selection: $presentationVerticalPosition)

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
        .padding(16)
        .frame(width: 320)
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

                Text("\(Int(value * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
            }

            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
        }
    }
}
