import SwiftUI

@MainActor
enum AccentColorProvider {
    static var color: Color {
        if #available(macOS 15.0, *) {
            return .accentColor
        }
        return Color(nsColor: .controlAccentColor)
    }
}
