import AppKit
import XCTest
@testable import eucaly

@MainActor
final class LibraryFileTrashControllerTests: XCTestCase {
    func testCancelledConfirmationNeverReservesOrMovesAndLateApprovalIsIgnored() async throws {
        let fixture = try TrashControllerFixture()
        defer { fixture.close() }
        var reply: ((NSApplication.ModalResponse) -> Void)?
        let presented = expectation(description: "native confirmation prepared")
        let controller = LibraryFileTrashController(service: fixture.service(), beginSheet: { alert, _, completion in
            XCTAssertEqual(alert.buttons.map(\.title), ["Move to Trash", "Cancel"])
            XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
            reply = completion
            presented.fulfill()
        })
        let task = try XCTUnwrap(fixture.present(controller))
        await fulfillment(of: [presented], timeout: 5)
        XCTAssertNil(fixture.present(controller), "Repeated actions cannot create a second confirmation")
        controller.cancel()
        reply?(.alertFirstButtonReturn)
        await task.value
        XCTAssertEqual(fixture.workspace.admissions, 0)
        XCTAssertTrue(fixture.workspace.completions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testEditorOrCurrentOpenedDuringConfirmationBlocksTrash() async throws {
        let fixture = try TrashControllerFixture()
        defer { fixture.close() }
        let controller = LibraryFileTrashController(service: fixture.service(), beginSheet: { _, _, completion in
            fixture.workspace.problem = "This file is open in an editor."
            completion(.alertFirstButtonReturn)
        })
        let task = try XCTUnwrap(fixture.present(controller))
        await task.value
        XCTAssertEqual(fixture.errors, ["This file is open in an editor."])
        XCTAssertEqual(fixture.workspace.admissions, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testNewUnresolvedReferenceDuringConfirmationRequiresFreshPreparation() async throws {
        let fixture = try TrashControllerFixture()
        defer { fixture.close() }
        let controller = LibraryFileTrashController(service: fixture.service(), beginSheet: { _, _, completion in
            fixture.workspace.referencedFileURLs.insert(fixture.root.appendingPathComponent("New.txt"))
            completion(.alertFirstButtonReturn)
        })
        let task = try XCTUnwrap(fixture.present(controller))
        await task.value
        XCTAssertEqual(fixture.workspace.admissions, 0)
        XCTAssertEqual(fixture.errors.count, 1)
        XCTAssertTrue(fixture.errors[0].contains("open documents changed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testRootOrInventoryChangeDuringConfirmationRevokesApproval() async throws {
        let fixture = try TrashControllerFixture()
        defer { fixture.close() }
        let controller = LibraryFileTrashController(service: fixture.service(), beginSheet: { _, _, completion in
            fixture.contextIsCurrent = false
            completion(.alertFirstButtonReturn)
        })
        let task = try XCTUnwrap(fixture.present(controller))
        await task.value
        XCTAssertEqual(fixture.workspace.admissions, 0)
        XCTAssertTrue(fixture.errors.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testNativeFailureReleasesExactReservationAndLeavesSourceUsable() async throws {
        let fixture = try TrashControllerFixture()
        defer { fixture.close() }
        let service = LibraryFileActionService(trashItem: { _ in throw CocoaError(.fileWriteNoPermission) })
        let controller = LibraryFileTrashController(service: service, beginSheet: { _, _, completion in completion(.alertFirstButtonReturn) })
        let task = try XCTUnwrap(fixture.present(controller))
        await task.value
        XCTAssertEqual(fixture.workspace.admissions, 1)
        XCTAssertEqual(fixture.workspace.completions.map(\.removed), [false])
        XCTAssertNil(fixture.workspace.active)
        XCTAssertEqual(fixture.errors.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }

    func testClosingRequesterAfterNativeAdmissionStillReportsActualSuccessAndReleasesReservation() async throws {
        let fixture = try TrashControllerFixture()
        defer { fixture.close() }
        let entered = expectation(description: "native move admitted")
        let gate = DispatchSemaphore(value: 0)
        let trashURL = fixture.trash.appendingPathComponent(fixture.file.lastPathComponent)
        let service = LibraryFileActionService(trashItem: { url in
            entered.fulfill()
            gate.wait()
            try FileManager.default.moveItem(at: url, to: trashURL)
            return trashURL
        })
        let controller = LibraryFileTrashController(service: service, beginSheet: { _, _, completion in completion(.alertFirstButtonReturn) })
        let task = try XCTUnwrap(fixture.present(controller))
        await fulfillment(of: [entered], timeout: 5)
        XCTAssertNotNil(fixture.workspace.active)
        controller.cancel()
        fixture.window.orderOut(nil)
        fixture.contextIsCurrent = false
        XCTAssertNotNil(fixture.workspace.active, "Closing controls cannot release admitted filesystem ownership")
        gate.signal()
        await task.value
        XCTAssertEqual(fixture.workspace.completions.map(\.removed), [true])
        XCTAssertNil(fixture.workspace.active)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
        XCTAssertTrue(fixture.errors.isEmpty)
    }

    func testSuccessfulRemovalTargetsClickedFileAndControllerCanBeReused() async throws {
        let fixture = try TrashControllerFixture()
        defer { fixture.close() }
        let other = fixture.root.appendingPathComponent("Other.txt")
        try "unrelated".write(to: other, atomically: true, encoding: .utf8)
        let controller = LibraryFileTrashController(service: fixture.service(), beginSheet: { _, _, completion in completion(.alertFirstButtonReturn) })
        let first = try XCTUnwrap(fixture.present(controller))
        await first.value
        XCTAssertEqual(fixture.workspace.completions.map(\.url), [fixture.file])
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
        fixture.file = other
        let second = try XCTUnwrap(fixture.present(controller))
        await second.value
        XCTAssertEqual(fixture.workspace.completions.map(\.removed), [true, true])
        XCTAssertTrue(fixture.errors.isEmpty)
    }
}

@MainActor
private final class TrashControllerWorkspace: LibraryFileTrashWorkspace {
    var referencedFileURLs: Set<URL> = []
    var problem: String?
    var admissions = 0
    var active: OutputCoordinator.FileRemovalReservation?
    struct Completion { let url: URL; let removed: Bool }
    var completions: [Completion] = []

    func fileRemovalProblem(matchingFile: (URL) -> Bool) -> String? { problem }
    func beginFileRemoval(at url: URL, matchingFile: @escaping (URL) -> Bool) -> OutputCoordinator.FileRemovalAdmission {
        admissions += 1
        let token = OutputCoordinator.FileRemovalReservation(id: UUID(), requesterWorkspaceID: UUID(), url: url)
        active = token
        return .admitted(token)
    }
    func finishFileRemoval(_ reservation: OutputCoordinator.FileRemovalReservation,
                           candidate: LibraryFileActionService.Candidate, removed: Bool, resultingURL: URL?) -> Bool {
        guard active == reservation else { return false }
        active = nil
        completions.append(.init(url: candidate.url, removed: removed))
        return true
    }
}

@MainActor
private final class TrashControllerFixture {
    let directory: URL
    let root: URL
    let trash: URL
    var file: URL
    let window: NSWindow
    let workspace = TrashControllerWorkspace()
    var contextIsCurrent = true
    var errors: [String] = []

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("eucaly-trash-controller-" + UUID().uuidString)
        root = directory.appendingPathComponent("Library")
        trash = directory.appendingPathComponent("Isolated Trash")
        file = root.appendingPathComponent("Selected.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try "lyrics".write(to: file, atomically: true, encoding: .utf8)
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 360, height: 180),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.tabbingMode = .disallowed
        window.makeKeyAndOrderFront(nil)
    }

    func service() -> LibraryFileActionService {
        let trash = trash
        return LibraryFileActionService(trashItem: { url in
            let destination = trash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        })
    }

    func present(_ controller: LibraryFileTrashController) -> Task<Void, Never>? {
        controller.present(url: file, under: root, for: window, workspace: workspace,
                           isCurrent: { [self] in contextIsCurrent }, reportError: { [self] in errors.append($0) })
    }

    func close() {
        window.close()
        try? FileManager.default.removeItem(at: directory)
    }
}
