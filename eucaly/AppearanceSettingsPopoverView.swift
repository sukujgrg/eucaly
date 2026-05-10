import SwiftUI

struct AppearanceSettingsPopoverView: View {
    @Binding var presentationFontScale: Double
    @Binding var thumbnailFontScale: Double
    @Binding var thumbnailScale: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Appearance")
                .font(.headline)

            AppearanceSliderRow(
                title: "Presentation Font Size",
                value: $presentationFontScale,
                range: 0.5...2.0,
                step: 0.1
            )

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
