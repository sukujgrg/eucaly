import AppKit
import XCTest
@testable import eucaly

@MainActor
final class LibraryImportPanelTests: XCTestCase {
    func testPanelIsCreatedOnFirstImportAndReusedWithResetFiltersAndMessage() {
        let panel = TestOpenPanel()
        let window = TestWindow()
        var creationCount = 0
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        let controller = LibraryImportPanelController(makePanel: {
            creationCount += 1
            return panel
        }, beginSheet: { presented, owner, completion in
            XCTAssertTrue(presented === panel)
            XCTAssertTrue(owner === window)
            completions.append(completion)
        })

        XCTAssertEqual(creationCount, 0, "Constructing a workspace must not initialize the picker.")
        XCTAssertTrue(completions.isEmpty)
        XCTAssertNil(panel.delegate)

        controller.present(source: .audio, for: window) { _ in XCTFail("Cancelled import") }
        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(Set(panel.allowedContentTypes), Set(LibraryImportPanelController.Source.audio.contentTypes))
        XCTAssertFalse(panel.message.isEmpty)
        XCTAssertTrue(panel.allowsMultipleSelection)
        XCTAssertTrue(panel.canChooseFiles)
        XCTAssertFalse(panel.canChooseDirectories)
        completions[0](.cancel)

        controller.present(source: .library, for: window) { _ in XCTFail("Cancelled import") }
        XCTAssertEqual(Set(panel.allowedContentTypes), Set(LibraryImportPanelController.Source.library.contentTypes))
        XCTAssertTrue(panel.message.isEmpty)
        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(completions.count, 2)
        completions[1](.cancel)
    }

    func testDuplicateClickDuringInitializationCannotReplaceRequestedImport() {
        let panel = TestOpenPanel()
        let window = TestWindow()
        let reference = ControllerReference()
        var creationCount = 0
        var presentationCount = 0
        let controller = LibraryImportPanelController(makePanel: {
            creationCount += 1
            reference.controller?.present(source: .audio, for: window) { _ in }
            reference.controller?.present(source: .library, for: window) { _ in XCTFail("Duplicate click") }
            return panel
        }, beginSheet: { presented, _, completion in
            presentationCount += 1
            XCTAssertTrue(presented === panel)
            XCTAssertEqual(Set(presented.allowedContentTypes), Set(LibraryImportPanelController.Source.library.contentTypes))
            completion(.cancel)
        })
        reference.controller = controller

        controller.present(source: .library, for: window) { _ in XCTFail("Cancelled import") }

        XCTAssertEqual(creationCount, 1)
        XCTAssertEqual(presentationCount, 1)
    }

    func testOnlyAcceptedSelectionIsDeliveredAndRepeatedClicksDoNotOpenAnotherSheet() {
        let panel = TestOpenPanel()
        let window = TestWindow()
        panel.selectedURLs = [URL(fileURLWithPath: "/tmp/lyrics.txt"), URL(fileURLWithPath: "/tmp/image.png")]
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        var importedURLs: [URL] = []
        var acceptedCount = 0
        let controller = LibraryImportPanelController(makePanel: { panel }, beginSheet: { _, _, completion in
            completions.append(completion)
        })

        controller.present(source: .library, for: window) {
            importedURLs = $0
            acceptedCount += 1
        }
        controller.present(source: .audio, for: window) { _ in XCTFail("Duplicate click") }
        XCTAssertTrue(importedURLs.isEmpty)
        XCTAssertEqual(completions.count, 1)
        completions[0](.OK)
        XCTAssertEqual(importedURLs, panel.selectedURLs)
        XCTAssertEqual(acceptedCount, 1)
        completions[0](.OK)
        XCTAssertEqual(importedURLs, panel.selectedURLs)
        XCTAssertEqual(acceptedCount, 1)
    }

    func testCancellationRejectsLateAcceptanceWithoutCancellingANewerImport() {
        let panel = TestOpenPanel()
        let window = TestWindow()
        var completions: [(NSApplication.ModalResponse) -> Void] = []
        var acceptedCount = 0
        let controller = LibraryImportPanelController(makePanel: { panel }, beginSheet: { _, _, completion in
            completions.append(completion)
        })

        controller.present(source: .library, for: window) { _ in XCTFail("Cancelled import") }
        controller.cancel()
        XCTAssertEqual(panel.cancelCount, 1)
        controller.present(source: .audio, for: window) { _ in acceptedCount += 1 }
        completions[0](.OK)
        completions[1](.OK)
        XCTAssertEqual(acceptedCount, 1)
    }

    func testClosingOwnerOrCancellingDuringPreparationDiscardsSelection() {
        let panel = TestOpenPanel()
        let window = TestWindow()
        let reference = ControllerReference()
        var presentationCount = 0
        let controller = LibraryImportPanelController(makePanel: {
            reference.controller?.cancel()
            return panel
        }, beginSheet: { _, _, _ in presentationCount += 1 })
        reference.controller = controller
        controller.present(source: .library, for: window) { _ in XCTFail("Cancelled import") }
        XCTAssertEqual(presentationCount, 0)

        let closingController = LibraryImportPanelController(makePanel: { panel }, beginSheet: { _, _, completion in
            window.simulatedVisibility = false
            completion(.OK)
        })
        closingController.present(source: .library, for: window) { _ in XCTFail("Closed workspace") }
    }

    func testCancellationReleasesImportContextBeforeDelayedNativeReply() {
        let panel = TestOpenPanel()
        let window = TestWindow()
        var nativeReply: ((NSApplication.ModalResponse) -> Void)?
        let controller = LibraryImportPanelController(makePanel: { panel }, beginSheet: { _, _, completion in
            nativeReply = completion
        })
        weak var context: ImportContext?
        autoreleasepool {
            let captured = ImportContext()
            context = captured
            controller.present(source: .library, for: window) { [captured] _ in
                withExtendedLifetime(captured) { XCTFail("Cancelled import") }
            }
        }
        XCTAssertNotNil(context)

        controller.cancel()

        XCTAssertNil(context, "A delayed native reply must not retain a cancelled workspace's import context.")
        nativeReply?(.OK)
    }

    func testFinishingImportReleasesContextEvenIfNativeReplyIsRetained() {
        let panel = TestOpenPanel()
        let window = TestWindow()
        var nativeReply: ((NSApplication.ModalResponse) -> Void)?
        let controller = LibraryImportPanelController(makePanel: { panel }, beginSheet: { _, _, completion in
            nativeReply = completion
        })
        weak var context: ImportContext?
        var acceptedCount = 0
        autoreleasepool {
            let captured = ImportContext()
            context = captured
            controller.present(source: .library, for: window) { [captured] _ in
                withExtendedLifetime(captured) { acceptedCount += 1 }
            }
        }
        XCTAssertNotNil(context)

        nativeReply?(.OK)

        XCTAssertEqual(acceptedCount, 1)
        XCTAssertNil(context, "A completed import must release the workspace's captured state.")
        nativeReply?(.OK)
        XCTAssertEqual(acceptedCount, 1)
    }

    func testHiddenWorkspaceOrExistingSheetDoesNotInitializePicker() {
        let window = TestWindow()
        var creationCount = 0
        let controller = LibraryImportPanelController(makePanel: {
            creationCount += 1
            return TestOpenPanel()
        }, beginSheet: { _, _, _ in XCTFail("Unavailable workspace") })

        window.simulatedVisibility = false
        controller.present(source: .library, for: window) { _ in XCTFail("Hidden workspace") }
        window.simulatedVisibility = true
        window.blockingSheet = TestWindow()
        controller.present(source: .audio, for: window) { _ in XCTFail("Existing sheet") }

        XCTAssertEqual(creationCount, 0)
    }

    func testLibraryPickerEnforcesSupportedExtensionsInsteadOfBroadTextTypes() throws {
        try withImportFixture { directory in
            let panel = TestOpenPanel()
            let window = TestWindow()
            let controller = LibraryImportPanelController(makePanel: { panel }, beginSheet: { _, _, _ in })
            controller.present(source: .library, for: window) { _ in }
            defer { controller.cancel() }
            let delegate = try XCTUnwrap(panel.delegate as? LibraryImportPanelController.FileSelectionDelegate)

            for name in ["song.txt", "UPPER.TXT", "slides.pdf", "photo.png", "video.mov"] {
                let url = directory.appendingPathComponent(name)
                try Data("test".utf8).write(to: url)
                XCTAssertTrue(delegate.panel(panel, shouldEnable: url), name)
                XCTAssertNoThrow(try delegate.panel(panel, validate: url), name)
            }
            for name in ["notes.md", "data.csv", "settings.json", "track.mp3", "photo.heic", "code.swift"] {
                let url = directory.appendingPathComponent(name)
                try Data("test".utf8).write(to: url)
                XCTAssertFalse(delegate.panel(panel, shouldEnable: url), name)
                XCTAssertThrowsError(try delegate.panel(panel, validate: url), name)
            }
        }
    }

    func testReusedAudioPickerSwitchesItsNativeValidationPolicy() throws {
        try withImportFixture { directory in
            let panel = TestOpenPanel()
            let window = TestWindow()
            var nativeReply: ((NSApplication.ModalResponse) -> Void)?
            let controller = LibraryImportPanelController(makePanel: { panel }, beginSheet: { _, _, completion in
                nativeReply = completion
            })
            controller.present(source: .library, for: window) { _ in }
            let delegate = try XCTUnwrap(panel.delegate as? LibraryImportPanelController.FileSelectionDelegate)
            nativeReply?(.cancel)
            controller.present(source: .audio, for: window) { _ in }
            defer { controller.cancel() }
            XCTAssertTrue(panel.delegate === delegate)

            for name in ["track.mp3", "track.wav", "track.flac", "video.mov", "VIDEO.MP4"] {
                let url = directory.appendingPathComponent(name)
                try Data("test".utf8).write(to: url)
                XCTAssertTrue(delegate.panel(panel, shouldEnable: url), name)
                XCTAssertNoThrow(try delegate.panel(panel, validate: url), name)
            }
            for name in ["song.txt", "notes.md", "data.csv", "slides.pdf", "photo.png"] {
                let url = directory.appendingPathComponent(name)
                try Data("test".utf8).write(to: url)
                XCTAssertFalse(delegate.panel(panel, shouldEnable: url), name)
                XCTAssertThrowsError(try delegate.panel(panel, validate: url), name)
            }
        }
    }

    func testDirectoriesRemainBrowsableButCannotBeImportedAsFiles() throws {
        try withImportFixture { directory in
            let panel = TestOpenPanel()
            let window = TestWindow()
            let controller = LibraryImportPanelController(makePanel: { panel }, beginSheet: { _, _, _ in })
            controller.present(source: .library, for: window) { _ in }
            defer { controller.cancel() }
            let delegate = try XCTUnwrap(panel.delegate as? LibraryImportPanelController.FileSelectionDelegate)

            for name in ["Songs", "Folder.md", "Folder.txt"] {
                let folder = directory.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                XCTAssertTrue(delegate.panel(panel, shouldEnable: folder), name)
                XCTAssertThrowsError(try delegate.panel(panel, validate: folder), name)
            }
            let package = directory.appendingPathComponent("Unsupported.app", isDirectory: true)
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            XCTAssertFalse(delegate.panel(panel, shouldEnable: package))
            XCTAssertThrowsError(try delegate.panel(panel, validate: package))
            let nonFileURL = try XCTUnwrap(URL(string: "https://example.com/song.txt"))
            XCTAssertFalse(delegate.panel(panel, shouldEnable: nonFileURL))
            XCTAssertThrowsError(try delegate.panel(panel, validate: nonFileURL))
        }
    }

    private func withImportFixture(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("eucaly-import-filter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private final class ImportContext {}

    private final class ControllerReference {
        weak var controller: LibraryImportPanelController?
    }

    private final class TestWindow: NSWindow {
        var simulatedVisibility = true
        var blockingSheet: NSWindow?
        override var isVisible: Bool { simulatedVisibility }
        override var attachedSheet: NSWindow? { blockingSheet }
    }

    private final class TestOpenPanel: NSOpenPanel {
        var selectedURLs: [URL] = []
        var cancelCount = 0
        override var urls: [URL] { selectedURLs }
        override func cancel(_ sender: Any?) { cancelCount += 1 }
    }
}
