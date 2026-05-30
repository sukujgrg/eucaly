import SwiftUI

struct SidebarLibraryRowView: View, Equatable {
    let url: URL
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onAddToPlaylist: () -> Void
    let onRevealInFinder: () -> Void

    static func == (lhs: SidebarLibraryRowView, rhs: SidebarLibraryRowView) -> Bool {
        lhs.url.standardizedFileURL == rhs.url.standardizedFileURL
            && lhs.title == rhs.title
            && lhs.isSelected == rhs.isSelected
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: onSelect) {
                SidebarRowLabel(title: title, isSelected: isSelected)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())

            Button(action: onAddToPlaylist) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AccentColorProvider.color)
                    .frame(width: 20, height: 20)
                    .background(
                        Circle()
                            .fill(AccentColorProvider.color.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help("Add to Playlist")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contextMenu {
            Button(action: onAddToPlaylist) {
                Label("Add to Playlist", systemImage: "plus")
            }

            Button(action: onRevealInFinder) {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }
}
