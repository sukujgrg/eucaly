import AppKit
import SwiftUI

struct SidebarAudioControlsView: View {
    @ObservedObject var session: PresentationSession
    let audioFiles: [URL]
    let maxListHeight: CGFloat
    let libraryRootURL: URL?
    @Binding var backgroundAudioLoop: Bool
    @Binding var backgroundAudioVolumeDraft: Double
    @FocusState.Binding var isSidebarFocused: Bool

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
                onPlayPauseBackgroundAudio()
            } label: {
                Label(
                    session.isBackgroundAudioPlaying ? "Pause" : "Play",
                    systemImage: session.isBackgroundAudioPlaying ? "pause.fill" : "play.fill"
                )
            }
            .labelStyle(.iconOnly)
            .sidebarActionStyle()
            .disabled(session.backgroundAudioURL == nil)
            .help(session.isBackgroundAudioPlaying ? "Pause" : "Play")

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
                onClearBackgroundAudio()
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
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(audioFiles, id: \.standardizedFileURL) { url in
                        audioRow(url)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: maxListHeight, alignment: .topLeading)
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

    private func audioRow(_ url: URL) -> some View {
        let isSelected = session.backgroundAudioURL?.standardizedFileURL == url.standardizedFileURL
        return Button {
            isSidebarFocused = true
            onSelectBackgroundAudio(url)
        } label: {
            SidebarRowLabel(title: displayName(url), isSelected: isSelected)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                revealInFinder(url)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
        }
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

}
