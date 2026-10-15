import AppKit
import UniformTypeIdentifiers

/// Create the native panel on the first Import and reuse it afterward, without
/// adding system-service initialization to workspace startup or activation.
@MainActor
final class LibraryImportPanelController {
    enum Source {
        case library
        case audio

        var contentTypes: [UTType] {
            switch self {
            case .library: Self.libraryTypes
            case .audio: Self.audioTypes
            }
        }

        func acceptsFile(_ url: URL) -> Bool {
            guard url.isFileURL else { return false }
            let kind = LibraryFileKind(url: url)
            switch self {
            case .library: return kind.isPreviewLibraryItem
            case .audio: return kind.isBackgroundAudioSource
            }
        }

        private static let libraryTypes = [
            "txt", "pdf", "jpg", "jpeg", "png", "gif", "webp", "bmp", "tiff",
            "mp4", "mov", "m4v", "avi", "mkv"
        ].compactMap { UTType(filenameExtension: $0) }

        private static let audioTypes = [
            "mp4", "mov", "m4v", "avi", "mkv",
            "mp3", "m4a", "wav", "aiff", "aif", "flac", "aac"
        ].compactMap { UTType(filenameExtension: $0) }
    }

    private struct Request {
        let id = UUID()
        weak var window: NSWindow?
        let source: Source
        let completion: ([URL]) -> Void
    }

    private let makePanel: @MainActor () -> NSOpenPanel
    private let beginSheet: @MainActor (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private var panel: NSOpenPanel?
    private var isPreparing = false
    private var pendingRequest: Request?
    private var activeRequest: Request?
    private lazy var fileSelectionDelegate = FileSelectionDelegate()

    init(
        makePanel: @escaping @MainActor () -> NSOpenPanel = { NSOpenPanel() },
        beginSheet: @escaping @MainActor (NSOpenPanel, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
            $0.beginSheetModal(for: $1, completionHandler: $2)
        }
    ) {
        self.makePanel = makePanel
        self.beginSheet = beginSheet
    }

    private func preparePanelIfNeeded() {
        guard panel == nil, !isPreparing else { return }
        // NSOpenPanel initialization runs a nested AppKit loop. Another click
        // during initialization must not create a second panel.
        isPreparing = true
        let prepared = makePanel()
        prepared.isReleasedWhenClosed = false
        prepared.allowsMultipleSelection = true
        prepared.prompt = "Import"
        prepared.allowedContentTypes = Source.library.contentTypes
        prepared.canChooseFiles = true
        prepared.canChooseDirectories = false
        panel = prepared
        isPreparing = false
    }

    func present(source: Source, for window: NSWindow, completion: @escaping ([URL]) -> Void) {
        guard activeRequest == nil, pendingRequest == nil, window.isVisible, window.attachedSheet == nil else { return }
        pendingRequest = Request(window: window, source: source, completion: completion)
        preparePanelIfNeeded()
        presentPendingRequest()
    }

    func cancel() {
        pendingRequest = nil
        let wasPresented = activeRequest != nil
        activeRequest = nil
        if wasPresented { panel?.cancel(nil) }
    }

    private func presentPendingRequest() {
        guard let panel, let request = pendingRequest else { return }
        pendingRequest = nil
        guard let window = request.window, window.isVisible, window.attachedSheet == nil else { return }
        let requestID = request.id
        activeRequest = request
        fileSelectionDelegate.source = request.source
        panel.delegate = fileSelectionDelegate
        panel.allowedContentTypes = request.source.contentTypes
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.message = request.source == .audio
            ? "Choose audio or video files to use as background audio." : ""
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard activeRequest?.id == requestID else { return }
        // AppKit's reply may outlive the import. Keep its workspace callback in
        // the active request so cancel/completion releases it immediately.
        beginSheet(panel, window) { [weak self, weak panel] response in
            guard let self, let panel, let request = self.activeRequest, request.id == requestID else { return }
            let urls = response == .OK ? panel.urls : []
            self.activeRequest = nil
            // AppKit can invoke completion before the sheet is offscreen. An
            // import error or unsaved-editor confirmation may need its own alert.
            panel.orderOut(nil)
            guard response == .OK, request.window?.isVisible == true else { return }
            request.completion(urls)
        }
    }

    /// UTType filters include subtypes such as CSV and Markdown. The native
    /// delegate applies the same filename policy as the library and importer.
    /// It is created only when Import presents the panel.
    final class FileSelectionDelegate: NSObject, NSOpenSavePanelDelegate {
        var source: Source = .library

        func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
            guard url.isFileURL else { return false }
            // Inspect only directory/package metadata to keep folders browsable;
            // never read or parse file contents.
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            if values?.isDirectory == true {
                return values?.isPackage != true
            }
            return source.acceptsFile(url)
        }

        func panel(_ sender: Any, validate url: URL) throws {
            guard source.acceptsFile(url) else { throw UnsupportedFile(url: url) }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw UnsupportedFile(url: url) }
        }

        private struct UnsupportedFile: LocalizedError {
            let url: URL
            var errorDescription: String? {
                "\(url.lastPathComponent) is not supported for this import."
            }
        }
    }
}
