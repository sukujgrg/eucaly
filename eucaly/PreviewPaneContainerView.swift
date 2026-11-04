import SwiftUI

private struct PreviewThumbnailGrid: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let flow: PresentationFlowController
    @ObservedObject var selection: PreviewSelectionState
    let thumbnailScale: Double
    @FocusState.Binding var isFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            let horizontalInset: CGFloat = 10
            let layout = ThumbnailGridLayout.make(
                for: proxy.size.width - (horizontalInset * 2),
                thumbnailScale: thumbnailScale
            )
            let document = flow.previewDocument
            let multiSource = document?.containsMultipleSources == true

            ScrollViewReader { scrollProxy in
                ScrollView {
                    LazyVGrid(columns: layout.columns, spacing: layout.spacing) {
                        if let document, document.slideCount > 0 {
                            ForEach(0..<document.slideCount, id: \.self) { index in
                                let slide = document.slide(at: index)
                                SlideGridCellView(
                                    slide: slide,
                                    itemWidth: layout.itemWidth,
                                    itemHeight: layout.itemHeight,
                                    isSelected: slide.id == selection.selectedSlideID,
                                    allowsPDFThumbnailRendering: document.allowsPDFThumbnailRendering(for: slide),
                                    accessibilityTitleIncludesSource: multiSource,
                                    onTap: {
                                        flow.selectPreviewSlide(slide.id)
                                    }
                                )
                                .id(slide.id)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                    .padding(.horizontal, horizontalInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .focusable()
                .focused($isFocused)
                .focusEffectDisabled()
                .onKeyPress(.upArrow) {
                    handleArrowKey(direction: .previousRow, layout: layout)
                }
                .onKeyPress(.downArrow) {
                    handleArrowKey(direction: .nextRow, layout: layout)
                }
                .onKeyPress(.leftArrow) {
                    handleArrowKey(direction: .previousItem, layout: layout)
                }
                .onKeyPress(.rightArrow) {
                    handleArrowKey(direction: .nextItem, layout: layout)
                }
                .onTapGesture {
                    isFocused = true
                }
                .onChange(of: selection.selectedSlideID) { _, newValue in
                    scrollToSelectedSlide(newValue, with: scrollProxy)
                }
            }
        }
    }

    private func handleArrowKey(
        direction: ThumbnailGridNavigationDirection,
        layout: ThumbnailGridLayout
    ) -> KeyPress.Result {
        guard flow.previewSlideCount > 0 else { return .ignored }
        guard
            let selectionID = flow.previewSelectionID,
            let currentIndex = flow.previewSlideIndex(for: selectionID)
        else {
            if let firstSlide = flow.previewSlide(at: 0) {
                flow.selectPreviewSlide(firstSlide.id)
            }
            return .handled
        }

        let targetIndex = layout.selectionTargetIndex(
            from: currentIndex,
            itemCount: flow.previewSlideCount,
            direction: direction
        )
        if let targetSlide = flow.previewSlide(at: targetIndex) {
            flow.selectPreviewSlide(targetSlide.id)
        }
        return .handled
    }

    private func scrollToSelectedSlide(_ slideID: Slide.ID?, with proxy: ScrollViewProxy) {
        guard let slideID else { return }
        InterfaceMotion.selectionScroll.animate(reduceMotion: reduceMotion) {
            // The default anchor moves only enough to reveal an offscreen slide.
            proxy.scrollTo(slideID)
        }
    }
}

struct PreviewPaneContainerView: View {
    @ObservedObject var flow: PresentationFlowController
    let isEditorPreviewAreaCollapsed: Bool
    let hasEditorPane: Bool
    let canEditSelection: Bool
    let canLoadToCurrent: Bool
    let loadToCurrentHelp: String
    let loadError: String?
    let loadNotice: String?
    let thumbnailScale: Double
    let onEdit: () -> Void
    let onLoadToCurrent: () -> Void
    let onToggleEditorPreviewArea: () -> Void
    @FocusState private var isFocused: Bool
    @FocusState private var isEditorPreviewAreaToggleFocused: Bool

    init(
        flow: PresentationFlowController,
        isEditorPreviewAreaCollapsed: Bool,
        hasEditorPane: Bool,
        canEditSelection: Bool,
        canLoadToCurrent: Bool,
        loadToCurrentHelp: String,
        loadError: String?,
        loadNotice: String? = nil,
        thumbnailScale: Double,
        onEdit: @escaping () -> Void,
        onLoadToCurrent: @escaping () -> Void,
        onToggleEditorPreviewArea: @escaping () -> Void
    ) {
        self.flow = flow
        self.isEditorPreviewAreaCollapsed = isEditorPreviewAreaCollapsed
        self.hasEditorPane = hasEditorPane
        self.canEditSelection = canEditSelection
        self.canLoadToCurrent = canLoadToCurrent
        self.loadToCurrentHelp = loadToCurrentHelp
        self.loadError = loadError
        self.loadNotice = loadNotice
        self.thumbnailScale = thumbnailScale
        self.onEdit = onEdit
        self.onLoadToCurrent = onLoadToCurrent
        self.onToggleEditorPreviewArea = onToggleEditorPreviewArea
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button(action: toggleEditorPreviewArea) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .rotationEffect(.degrees(isEditorPreviewAreaCollapsed ? 0 : 90))
                        Text(editorPreviewAreaTitle)
                            .font(.headline)
                            .fontWeight(.semibold)

                        Text(previewStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                    .foregroundStyle(.primary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($isEditorPreviewAreaToggleFocused)
                .help(editorPreviewAreaToggleLabel)
                .accessibilityLabel(editorPreviewAreaToggleLabel)

                if !flow.previewIsEmpty || canLoadToCurrent {
                    HStack(spacing: 6) {
                        if !flow.previewIsEmpty {
                            Button("Edit", action: onEdit)
                                .paneHeaderActionStyle()
                                .disabled(!canEditSelection)
                        }

                        Button(action: onLoadToCurrent) {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.circle.fill")
                                Text("Load to Current")
                            }
                        }
                        .paneHeaderActionStyle(primary: true)
                        .disabled(!canLoadToCurrent)
                        .help(loadToCurrentHelp)
                    }
                }

                Rectangle()
                    .fill(.clear)
                    .frame(height: 28)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: toggleEditorPreviewArea)
            }
            .padding(.horizontal, 4)

            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            } else if let loadNotice {
                Label(loadNotice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
            }

            if !isEditorPreviewAreaCollapsed {
                Group {
                    if flow.previewIsEmpty {
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
                    } else {
                        PreviewThumbnailGrid(
                            flow: flow,
                            selection: flow.previewSelection,
                            thumbnailScale: thumbnailScale,
                            isFocused: $isFocused
                        )
                    }
                }
                .excludingInterfaceAnimation(.disclosure)
                .transition(.opacity)
            }

        }
        .padding(10)
        .frame(
            maxWidth: .infinity,
            maxHeight: isEditorPreviewAreaCollapsed ? nil : .infinity,
            alignment: .top
        )
        .background(
            VisualEffectView(material: .contentBackground, blendingMode: .withinWindow)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        )
        .paneAccentRing(
            .preview,
            isEmphasized: !flow.previewIsEmpty && !isEditorPreviewAreaCollapsed
        )
    }

    private var editorPreviewAreaTitle: String {
        hasEditorPane ? "Editor & Preview" : "Preview"
    }

    private func toggleEditorPreviewArea() {
        let isCollapsing = !isEditorPreviewAreaCollapsed
        onToggleEditorPreviewArea()
        if isCollapsing {
            isEditorPreviewAreaToggleFocused = true
        }
    }

    private var editorPreviewAreaToggleLabel: String {
        let action = isEditorPreviewAreaCollapsed ? "Expand" : "Collapse"
        return "\(action) \(editorPreviewAreaTitle)"
    }

    private var previewStatusText: String {
        if loadError != nil { return "(Load failed)" }
        guard let document = flow.previewDocument, !document.isEmpty else {
            return flow.isPreviewLoading ? "(Loading…)" : ""
        }
        let sources = document.sourceURLs.count
        let slides = document.slideCount
        if sources <= 1 {
            return slides == 1 ? "(1 slide)" : "(\(slides) slides)"
        }
        return "(\(sources) items · \(slides) slides)"
    }
}
