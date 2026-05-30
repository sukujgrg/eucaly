import SwiftUI

struct SidebarRowLabel: View {
    let title: String
    let isSelected: Bool
    var isMissing: Bool = false

    var body: some View {
        let selectionShape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text(title)
            .font(.system(size: 14))
            .foregroundStyle(isMissing ? Color.secondary : Color.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(height: 22, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                selectionShape
                    .fill(isSelected ? AccentColorProvider.color.opacity(0.22) : Color.clear)
            )
            .overlay(
                selectionShape
                    .stroke(isSelected ? AccentColorProvider.color.opacity(0.7) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .focusEffectDisabled()
    }
}
