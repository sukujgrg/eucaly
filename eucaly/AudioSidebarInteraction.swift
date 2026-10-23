import Foundation

nonisolated enum AudioSidebarPlaybackIntent: Equatable, Sendable {
    case none
    case selectAndPlay(URL)
    case togglePlayback
}

nonisolated struct AudioSidebarInteraction {
    static func defaultAction(
        targetURL: URL,
        activeURL: URL?,
        isPlaying: Bool
    ) -> AudioSidebarPlaybackIntent {
        let targetURL = targetURL.standardizedFileURL
        guard targetURL == activeURL?.standardizedFileURL else {
            return .selectAndPlay(targetURL)
        }
        return isPlaying ? .none : .togglePlayback
    }

    static func toggleAction(
        selectedURL: URL?,
        activeURL: URL?
    ) -> AudioSidebarPlaybackIntent {
        guard let targetURL = (selectedURL ?? activeURL)?.standardizedFileURL else {
            return .none
        }
        guard targetURL == activeURL?.standardizedFileURL else {
            return .selectAndPlay(targetURL)
        }
        return .togglePlayback
    }
}
