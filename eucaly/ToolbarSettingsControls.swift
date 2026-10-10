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

/// Common values in a native submenu, with precise adjustments in its settings panel.
struct SettingsPercentageMenu: View {
    let title: String
    @Binding var value: Double
    let presets: [Int]
    let onAdjust: () -> Void

    private var percentage: Int { Int((value * 100).rounded()) }
    private var choices: [Int] { Array(Set(presets + [percentage])).sorted() }

    var body: some View {
        Menu {
            Picker(title, selection: Binding(
                get: { percentage },
                set: { value = Double($0) / 100 }
            )) {
                ForEach(choices, id: \.self) { choice in
                    Text("\(choice)%").tag(choice)
                }
            }
            .pickerStyle(.inline)

            Divider()
            Button("Adjust…", action: onAdjust)
        } label: {
            Text("\(title): \(percentage)%")
        }
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

struct ToolbarSettingsPanel<Content: View>: View {
    let title: String
    let contentHeight: CGFloat
    @ViewBuilder let content: Content
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)

            content.frame(height: contentHeight)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 480)
        .controlSize(.regular)
        .buttonStyle(.bordered)
    }
}
