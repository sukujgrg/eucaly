import SwiftUI

struct PreviewPaneContainerView: View {
    @ObservedObject var session: PresentationSession
    @ObservedObject var flow: PresentationFlowController
    @Binding var isCollapsed: Bool
    @Binding var isWebpageMuted: Bool
    let canEditSelection: Bool
    let thumbnailScale: Double
    let paneToggleAnimation: Animation
    let loadAnimation: Animation
    let titleForWebpage: (URL) -> String
    let onWebpageNavigationChange: (URL, URL) -> Void
    let onWebpageTitleChange: (String, URL) -> Void
    let onEdit: () -> Void
    let onLoadToCurrent: () -> Void

    var body: some View {
        let slides = flow.previewSlides
        let selectedWebpageURL = previewWebpageURL(from: slides)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: toggleCollapsed) {
                    HStack(spacing: 4) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Preview")
                            .font(.headline)
                            .fontWeight(.semibold)
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)

                Text("(Selected file)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if !slides.isEmpty {
                    Button(action: onLoadToCurrent) {
                        HStack(spacing: 6) {
                            Image(systemName: session.isPresenting ? "arrow.triangle.branch" : "arrow.down.circle.fill")
                            Text(session.isPresenting ? "Switch Current" : "Load to Current")
                        }
                    }
                    .primaryActionStyle(fixedWidth: 170)
                    .help(session.isPresenting ? "Switch to this document" : "Load to Current area")
                }

                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)

            if !isCollapsed {
                Group {
                    if slides.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                            Text("No preview")
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text("Select a file from Library to preview")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding()
                    } else if let selectedWebpageURL {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Label(
                                    titleForWebpage(selectedWebpageURL),
                                    systemImage: "globe"
                                )
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)

                                Spacer()

                                Button {
                                    isWebpageMuted.toggle()
                                } label: {
                                    Label(
                                        isWebpageMuted ? "Unmute" : "Mute",
                                        systemImage: isWebpageMuted ? "speaker.wave.2.fill" : "speaker.slash.fill"
                                    )
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 10)

                            WebpageViewRepresentable(
                                url: selectedWebpageURL,
                                isMuted: isWebpageMuted,
                                onURLChange: { currentURL in
                                    onWebpageNavigationChange(currentURL, selectedWebpageURL)
                                },
                                onTitleChange: { title, currentURL in
                                    onWebpageTitleChange(title, currentURL)
                                }
                            )
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(.separator, lineWidth: 1)
                                )
                                .padding(.horizontal, 10)
                                .padding(.bottom, 4)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    } else {
                        GeometryReader { proxy in
                            ScrollView {
                                let horizontalInset: CGFloat = 10
                                let layout = ThumbnailGridLayout.make(
                                    for: proxy.size.width - (horizontalInset * 2),
                                    thumbnailScale: thumbnailScale
                                )
                                LazyVGrid(columns: layout.columns, spacing: layout.spacing) {
                                    ForEach(slides) { slide in
                                    SlideGridCellView(
                                        slide: slide,
                                        itemWidth: layout.itemWidth,
                                        itemHeight: layout.itemHeight,
                                        isSelected: slide.id == flow.previewSelectionID,
                                        overlayText: nil,
                                        overlayLabel: nil,
                                        overlayColor: .clear,
                                        overlayScale: 1.0,
                                        onTap: {
                                            flow.selectPreviewSlide(slide.id)
                                        }
                                    )
                                }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                                .padding(.horizontal, horizontalInset)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            }

            if !isCollapsed {
                HStack(spacing: 10) {
                    Button("Edit", action: onEdit)
                        .buttonStyle(.bordered)
                        .disabled(!canEditSelection)
                    Spacer()
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: isCollapsed ? nil : .infinity, alignment: .top)
        .background(
            VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        )
        .animation(loadAnimation, value: slides.count)
    }

    private func toggleCollapsed() {
        withAnimation(paneToggleAnimation) {
            isCollapsed.toggle()
        }
    }

    private func previewWebpageURL(from slides: [Slide]) -> URL? {
        if let selectionID = flow.previewSelectionID,
           let selectedSlide = slides.first(where: { $0.id == selectionID }),
           let webpageURL = selectedSlide.webpageURL {
            return webpageURL
        }

        if slides.count == 1 {
            return slides.first?.webpageURL
        }

        return nil
    }
}
