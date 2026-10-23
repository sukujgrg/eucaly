import AppKit

/// The native window registry supplies fresh editor and retained-program checks.
/// This controller owns only the lifetime of one confirmed filesystem action.
@MainActor
protocol LibraryFileTrashWorkspace: AnyObject {
    var referencedFileURLs: Set<URL> { get }
    func fileRemovalProblem(matchingFile: (URL) -> Bool) -> String?
    func beginFileRemoval(at url: URL, matchingFile: @escaping (URL) -> Bool) -> OutputCoordinator.FileRemovalAdmission
    @discardableResult
    func finishFileRemoval(_ reservation: OutputCoordinator.FileRemovalReservation,
                           candidate: LibraryFileActionService.Candidate, removed: Bool, resultingURL: URL?) -> Bool
}

extension OutputWorkspaceCommands: LibraryFileTrashWorkspace {}

@MainActor
final class LibraryFileTrashController {
    private final class Request {
        let url: URL
        let root: URL
        weak var window: NSWindow?
        let workspace: any LibraryFileTrashWorkspace
        let knownFileURLs: Set<URL>
        let isCurrent: () -> Bool
        let reportError: (String) -> Void
        let cancellation = LibraryFileActionCancellation()
        var isCancelled = false
        var alert: NSAlert?
        var confirmationReply: ((Bool) -> Void)?

        init(url: URL, root: URL, window: NSWindow, workspace: any LibraryFileTrashWorkspace,
             knownFileURLs: Set<URL>, isCurrent: @escaping () -> Bool, reportError: @escaping (String) -> Void) {
            self.url = url; self.root = root; self.window = window; self.workspace = workspace
            self.knownFileURLs = knownFileURLs
            self.isCurrent = isCurrent; self.reportError = reportError
        }
    }

    private let service: LibraryFileActionService
    private let makeAlert: @MainActor () -> NSAlert
    private let beginSheet: @MainActor (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void
    private var active: Request?

    init(service: LibraryFileActionService = .shared,
         makeAlert: @escaping @MainActor () -> NSAlert = { NSAlert() },
         beginSheet: @escaping @MainActor (NSAlert, NSWindow, @escaping (NSApplication.ModalResponse) -> Void) -> Void = {
             $0.beginSheetModal(for: $1, completionHandler: $2)
         }) {
        self.service = service; self.makeAlert = makeAlert; self.beginSheet = beginSheet
    }

    /// Returns the task to permit deterministic fixture verification. Closing a
    /// window cancels work that has not entered native Trash; admitted I/O still
    /// completes and releases its app-owned reservation even after controls close.
    @discardableResult
    func present(url: URL, under root: URL, for window: NSWindow,
                 workspace: any LibraryFileTrashWorkspace,
                 knownFileURLs: Set<URL> = [],
                 isCurrent: @escaping () -> Bool,
                 reportError: @escaping (String) -> Void) -> Task<Void, Never>? {
        guard active == nil else {
            reportError("Another file action is still finishing. Try again shortly.")
            return nil
        }
        guard window.isVisible, window.attachedSheet == nil, isCurrent() else { return nil }
        let request = Request(url: url, root: root, window: window, workspace: workspace,
                              knownFileURLs: knownFileURLs, isCurrent: isCurrent, reportError: reportError)
        active = request
        return Task { await perform(request) }
    }

    func cancel() {
        guard let request = active else { return }
        request.isCancelled = true
        request.cancellation.cancel()
        if let sheet = request.alert?.window, let parent = sheet.sheetParent {
            parent.endSheet(sheet, returnCode: .cancel)
        }
        request.alert?.window.orderOut(nil)
        reply(to: request, approved: false)
    }

    private func isValid(_ request: Request) -> Bool {
        active === request && !request.isCancelled && request.window?.isVisible == true && request.isCurrent()
    }

    private func perform(_ request: Request) async {
        defer { if active === request { active = nil } }
        var reservation: OutputCoordinator.FileRemovalReservation?
        var candidate: LibraryFileActionService.Candidate?
        var removed = false
        var resultingURL: URL?
        defer {
            if let reservation, let candidate {
                request.workspace.finishFileRemoval(reservation, candidate: candidate, removed: removed, resultingURL: resultingURL)
            }
        }
        do {
            let prepared = try await service.prepareMoveToTrash(
                url: request.url, under: request.root,
                knownFileURLs: request.workspace.referencedFileURLs.union(request.knownFileURLs).union([request.url]),
                cancellation: request.cancellation)
            candidate = prepared
            guard isValid(request) else { return }
            guard canRemove(prepared, request: request) else { return }
            guard await confirm(prepared, request: request), isValid(request) else { return }
            // Native sheet completion and file preparation both yield. Recheck
            // the live read set and all owners immediately before reservation.
            guard canRemove(prepared, request: request) else { return }
            switch request.workspace.beginFileRemoval(at: prepared.url, matchingFile: prepared.matchesFile) {
            case .blocked(let problem):
                request.reportError(problem)
                return
            case .admitted(let token):
                reservation = token
            }
            let receipt = try await service.moveToTrash(prepared, cancellation: request.cancellation)
            resultingURL = receipt.resultingURL
            removed = true
        } catch is CancellationError {
            // Cancelled queued work leaves the source and Preview untouched.
        } catch {
            if isValid(request) { request.reportError(error.localizedDescription) }
        }
    }

    private func canRemove(_ candidate: LibraryFileActionService.Candidate, request: Request) -> Bool {
        if let problem = request.workspace.fileRemovalProblem(matchingFile: candidate.matches) {
            request.reportError(problem)
            return false
        }
        let currentReferences = Set(request.workspace.referencedFileURLs.map(\.standardizedFileURL))
        guard currentReferences.isSubset(of: candidate.checkedKnownURLs) else {
            request.reportError("The open documents changed. Open this file’s menu again before moving it to Trash.")
            return false
        }
        return true
    }

    private func confirm(_ candidate: LibraryFileActionService.Candidate, request: Request) async -> Bool {
        guard let window = request.window, window.attachedSheet == nil else { return false }
        // Creating native panels may run a nested AppKit loop. The request is
        // already installed, and context is checked again after construction.
        let alert = makeAlert()
        alert.messageText = "Move “\(candidate.url.lastPathComponent)” to Trash?"
        alert.informativeText = "You can restore the file from the Trash in Finder. Playlist entries will remain listed as missing."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        guard isValid(request), window.attachedSheet == nil else { return false }
        request.alert = alert
        return await withCheckedContinuation { continuation in
            request.confirmationReply = { continuation.resume(returning: $0) }
            beginSheet(alert, window) { [weak self, weak request] response in
                guard let self, let request else { return }
                request.alert?.window.orderOut(nil)
                self.reply(to: request, approved: response == .alertFirstButtonReturn)
            }
        }
    }

    private func reply(to request: Request, approved: Bool) {
        let completion = request.confirmationReply
        request.confirmationReply = nil
        request.alert = nil
        completion?(approved)
    }
}
