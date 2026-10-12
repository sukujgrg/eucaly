import SwiftUI

private struct ToolbarSettingsMenuStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.bordered)
    }
}

extension View {
    func toolbarSettingsMenuStyle() -> some View {
        modifier(ToolbarSettingsMenuStyle())
    }
}

struct SettingsSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    var body: some View {
        VStack(spacing: 8) {
            LabeledContent(title) {
                Text("\(Int((value * 100).rounded()))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }
}
