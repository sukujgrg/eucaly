import AppKit
import SwiftUI

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

struct SidebarAudioControlsView: View {
    @ObservedObject var session: PresentationSession
    let audioFiles: [URL]
    let libraryRevision: Int
    let maxListHeight: CGFloat
    let libraryRootURL: URL?
    let outlineExpansionStore: SidebarOutlineExpansionStore
    @Binding var backgroundAudioLoop: Bool
    @Binding var backgroundAudioVolumeDraft: Double
    @Binding var selectedAudioURL: URL?

    let displayName: (URL) -> String
    let onImportToAudio: () -> Void
    let onSelectBackgroundAudio: (URL) -> Void
    let onPlayPauseBackgroundAudio: () -> Void
    let onStopBackgroundAudio: () -> Void
    let onClearBackgroundAudio: () -> Void
    let onApplyBackgroundAudioVolume: (Double) -> Void
    let onSeekBackgroundAudio: (Double) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            controlsRow
            audioList
            volumeRow
            SidebarAudioSeekView(
                playbackProgress: session.playbackProgress,
                isDisabled: session.backgroundAudioURL == nil,
                onSeek: onSeekBackgroundAudio
            )
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 6) {
            Button {
                onImportToAudio()
            } label: {
                Label("Import...", systemImage: "square.and.arrow.down")
            }
            .sidebarActionStyle(primary: true)
            .disabled(libraryRootURL == nil)
            .help("Import audio or video files for background audio")

            Button {
                togglePlayback(for: selectedAudioURL)
            } label: {
                Label(
                    isPlaybackTargetPlaying ? "Pause" : "Play",
                    systemImage: isPlaybackTargetPlaying ? "pause.fill" : "play.fill"
                )
            }
            .labelStyle(.iconOnly)
            .sidebarActionStyle()
            .disabled(playbackTargetURL == nil)
            .help(isPlaybackTargetPlaying ? "Pause" : "Play")

            Button {
                onStopBackgroundAudio()
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .labelStyle(.iconOnly)
            .sidebarActionStyle()
            .disabled(session.backgroundAudioURL == nil)
            .help("Stop")

            Button {
                clearBackgroundAudio()
            } label: {
                Label("Clear", systemImage: "xmark.circle")
            }
            .labelStyle(.iconOnly)
            .sidebarActionStyle()
            .disabled(session.backgroundAudioURL == nil)
            .help("Clear audio")

            Toggle(isOn: $backgroundAudioLoop) {
                Label("Loop", systemImage: "repeat")
            }
            .labelStyle(.iconOnly)
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(session.backgroundAudioURL == nil)
            .help("Loop")
        }
    }

    @ViewBuilder
    private var audioList: some View {
        if audioFiles.isEmpty {
            Text("No audio or video files in Library")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            SidebarOutlineView(
                contentRevision: AnyHashable(libraryRevision),
                modelBuilder: {
                    SidebarOutlineModel(
                        roots: audioFiles.map { sourceURL in
                            let url = sourceURL.standardizedFileURL
                            return SidebarOutlineItem(
                                id: .audio(url),
                                title: displayName(url),
                                contextActions: [.revealInFinder]
                            )
                        }
                    )
                },
                selectedItemIDs: selectedAudioItemID.map { [$0] } ?? [],
                primarySelectedItemID: selectedAudioItemID,
                itemStatuses: audioItemStatuses,
                expansionStore: outlineExpansionStore,
                allowsEmptySelection: true,
                onSelectionChange: { _, primaryID in
                    guard primaryID != nil else {
                        selectedAudioURL = nil
                        return true
                    }
                    guard case .audio(let url) = primaryID else { return false }
                    selectedAudioURL = url.standardizedFileURL
                    return true
                },
                onDefaultAction: { itemID in
                    guard case .audio(let url) = itemID else { return }
                    selectedAudioURL = url.standardizedFileURL
                    playIfNeeded(url)
                },
                onSpaceAction: { itemID in
                    if case .audio(let url) = itemID {
                        selectedAudioURL = url.standardizedFileURL
                        togglePlayback(for: url)
                    } else {
                        togglePlayback(for: nil)
                    }
                },
                onAction: { itemID, action in
                    guard case .audio(let url) = itemID, action == .revealInFinder else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            )
            .frame(
                height: min(
                    maxListHeight,
                    max(26, CGFloat(audioFiles.count) * 26)
                )
            )
        }
    }

    private var volumeRow: some View {
        HStack(spacing: 8) {
            Text("\(Int(backgroundAudioVolumeDraft * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .trailing)

            Slider(value: $backgroundAudioVolumeDraft, in: 0.0...1.0, step: 0.01)
                .controlSize(.small)
                .disabled(session.backgroundAudioURL == nil)
                .onChange(of: backgroundAudioVolumeDraft) { _, newValue in
                    onApplyBackgroundAudioVolume(newValue)
                }

            Text("")
                .frame(width: 42)
        }
    }

    private var selectedAudioItemID: SidebarOutlineItemID? {
        selectedAudioURL.map { .audio($0.standardizedFileURL) }
    }

    private var activeAudioURL: URL? {
        session.backgroundAudioURL?.standardizedFileURL
    }

    private var playbackTargetURL: URL? {
        selectedAudioURL?.standardizedFileURL ?? activeAudioURL
    }

    private var isPlaybackTargetPlaying: Bool {
        playbackTargetURL == activeAudioURL && session.isBackgroundAudioPlaying
    }

    private var audioItemStatuses: [SidebarOutlineItemID: SidebarOutlineItemStatus] {
        guard let activeAudioURL else { return [:] }
        let status: SidebarOutlineItemStatus
        switch session.backgroundAudioPlaybackState {
        case .stopped:
            status = .stoppedAudio
        case .paused:
            status = .pausedAudio
        case .playing:
            status = .playingAudio
        }
        return [
            .audio(activeAudioURL): status
        ]
    }

    private func togglePlayback(for selectedURL: URL?) {
        perform(
            AudioSidebarInteraction.toggleAction(
                selectedURL: selectedURL,
                activeURL: activeAudioURL
            )
        )
    }

    private func playIfNeeded(_ url: URL) {
        perform(
            AudioSidebarInteraction.defaultAction(
                targetURL: url,
                activeURL: activeAudioURL,
                isPlaying: session.isBackgroundAudioPlaying
            )
        )
    }

    private func perform(_ intent: AudioSidebarPlaybackIntent) {
        switch intent {
        case .none:
            break
        case .selectAndPlay(let url):
            onSelectBackgroundAudio(url)
        case .togglePlayback:
            onPlayPauseBackgroundAudio()
        }
    }

    private func clearBackgroundAudio() {
        selectedAudioURL = nil
        onClearBackgroundAudio()
    }
}
