import Foundation
import AppKit

nonisolated enum NewLyricsSavePolicy {
    enum DestinationError: LocalizedError, Equatable {
        case requiresTextFile
        case outsideLibraryRoot
        case unresolvableDestination

        var errorDescription: String? {
            switch self {
            case .requiresTextFile:
                return "Save lyrics using a .txt filename."
            case .outsideLibraryRoot:
                return "Save lyrics inside the Library Root."
            case .unresolvableDestination:
                return "Choose a save location without circular symbolic links."
            }
        }
    }

    /// Validate the exact URL shown by the save panel. Never change its overwrite target.
    static func validatedDestination(_ proposedURL: URL, libraryRootURL: URL?) throws -> URL {
        guard proposedURL.isFileURL, proposedURL.pathExtension.lowercased() == "txt" else {
            throw DestinationError.requiresTextFile
        }
        if let libraryRootURL {
            let root = try canonicalURL(libraryRootURL)
            let destination = try canonicalURL(proposedURL)
            guard LibraryRootPath.relativePath(for: destination, from: root) != nil else {
                throw DestinationError.outsideLibraryRoot
            }
        }
        return proposedURL
    }

    private static func canonicalURL(_ url: URL) throws -> URL {
        let fileManager = FileManager.default
        var ancestor = url
        var missingComponents: [String] = []
        var symbolicLinksFollowed = 0

        // Foundation leaves the whole path unresolved when its final file does
        // not exist. Resolve an existing ancestor before rebuilding that suffix.
        while !fileManager.fileExists(atPath: ancestor.path) {
            // A dangling link still names a destination outside its parent.
            if let target = try? fileManager.destinationOfSymbolicLink(atPath: ancestor.path) {
                guard symbolicLinksFollowed < 40 else { throw DestinationError.unresolvableDestination }
                symbolicLinksFollowed += 1
                ancestor = URL(fileURLWithPath: target, relativeTo: ancestor.deletingLastPathComponent())
                continue
            }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { throw DestinationError.unresolvableDestination }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }

        let resolvedAncestor = ancestor.resolvingSymlinksInPath()
        return missingComponents.reversed().reduce(resolvedAncestor) { $0.appendingPathComponent($1) }
            .standardizedFileURL
    }
}

@MainActor
final class NewLyricsSavePanelDelegate: NSObject, NSOpenSavePanelDelegate {
    private let libraryRootURL: URL?

    init(libraryRootURL: URL?) {
        self.libraryRootURL = libraryRootURL
    }

    func panel(_ sender: Any, validate url: URL) throws {
        _ = try NewLyricsSavePolicy.validatedDestination(url, libraryRootURL: libraryRootURL)
    }
}

struct NewLyricsState {
    var editor: LyricsEditorSession
    var selectedPlaylistEntryIDs: Set<UUID>
    var sidebarSelection: SidebarSelection?
}

enum NewLyricsAction {
    static func apply(state: inout NewLyricsState, clearPreview: () -> Void) {
        clearPreview()
        state.editor.beginNew()
        state.selectedPlaylistEntryIDs = []
        state.sidebarSelection = nil
    }
}
