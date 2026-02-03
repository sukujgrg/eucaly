import SwiftUI

struct OverlayBadgeView: View {
    let label: String?
    let text: String
    let scale: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6 * scale) {
            if let label {
                Label(label, systemImage: systemImageName(for: label))
                    .font(.system(size: 12 * scale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.hierarchical)
                    .tint(tint)
            }
            Text(text)
                .font(.system(size: 42 * scale, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 18 * scale)
        .padding(.vertical, 12 * scale)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        )
    }

    private func systemImageName(for label: String) -> String {
        let lowered = label.lowercased()
        if lowered.contains("timer") { return "timer" }
        if lowered.contains("clock") { return "clock" }
        return "info.circle"
    }
}
