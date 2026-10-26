import AppKit
import XCTest
@testable import eucaly

@MainActor
final class LibraryImportPanelControllerTests: XCTestCase {
    func testStaleControlsOwnerDoesNotInitializeTheNativePanel() {
        let window = TestWindow()
        var creations = 0
        let controller = LibraryImportPanelController(makePanel: {
            creations += 1
            return TestPanel()
        }, beginSheet: { _, _, _ in XCTFail("Stale owner must not present") })
        controller.present(source: .library, for: window, isCurrent: { false }) { _ in XCTFail("Stale owner must not import") }
        XCTAssertEqual(creations, 0)
    }

    func testSwitchDuringFirstPanelInitializationDiscardsPendingRequestAndReleasesContext() {
        let window = TestWindow(), panel = TestPanel()
        let a = UUID(), b = UUID()
        var currentOwner = a
        var creations = 0, presentations = 0
        let controller = LibraryImportPanelController(makePanel: {
            creations += 1
            // Represents a workspace command delivered by NSOpenPanel's nested
            // initialization loop; the same physical window remains visible.
            currentOwner = b
            return panel
        }, beginSheet: { _, _, completion in
            presentations += 1
            completion(.OK)
        })
        weak var retainedContext: ImportContext?
        autoreleasepool {
            let context = ImportContext()
            retainedContext = context
            controller.present(source: .library, for: window, isCurrent: { currentOwner == a }) { [context] _ in
                withExtendedLifetime(context) { XCTFail("Import must stay with its initiating workspace") }
            }
        }
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(creations, 1)
        XCTAssertEqual(presentations, 0)
        XCTAssertNil(retainedContext, "Dropping the stale pending request must release its workspace callback")
        var imports = 0
        controller.present(source: .audio, for: window, isCurrent: { currentOwner == b }) { _ in imports += 1 }
        XCTAssertEqual(creations, 1, "A discarded request must leave the reusable panel available")
        XCTAssertEqual(presentations, 1)
        XCTAssertEqual(imports, 1)
    }

    func testSwitchDuringPanelConfigurationIsRejectedAtTheSheetBoundary() {
        let window = TestWindow(), panel = TestPanel()
        var isCurrent = true
        var presentations = 0
        panel.onDirectoryChange = { isCurrent = false }
        let controller = LibraryImportPanelController(makePanel: { panel }, beginSheet: { _, _, _ in presentations += 1 })
        controller.present(source: .library, for: window, isCurrent: { isCurrent }) { _ in XCTFail("Stale request") }
        XCTAssertFalse(isCurrent, "The fixture must exercise the configuration boundary")
        XCTAssertEqual(presentations, 0)
        panel.onDirectoryChange = nil
        isCurrent = true
        controller.present(source: .audio, for: window, isCurrent: { isCurrent }) { _ in }
        XCTAssertEqual(presentations, 1, "Rejecting stale configuration must not leave an active request blocking Import")
        controller.cancel()
    }

    func testNativeAcceptanceRejectsChangedOwnerWithoutDisturbingANewerRequest() {
        let window = TestWindow(), panel = TestPanel()
        panel.selectedURLs = [URL(fileURLWithPath: "/tmp/owner-scoped-import.txt")]
        let a = UUID(), b = UUID()
        var currentOwner = a
        var replies: [(NSApplication.ModalResponse) -> Void] = []
        var accepted: [[URL]] = []
        let controller = LibraryImportPanelController(makePanel: { panel }, beginSheet: { _, _, completion in replies.append(completion) })
        controller.present(source: .library, for: window, isCurrent: { currentOwner == a }) { _ in XCTFail("A no longer owns these controls") }
        currentOwner = b
        replies[0](.OK)
        XCTAssertEqual(panel.orderOutCount, 1)
        controller.present(source: .audio, for: window, isCurrent: { currentOwner == b }) { accepted.append($0) }
        XCTAssertEqual(replies.count, 2)
        replies[0](.OK)
        XCTAssertTrue(accepted.isEmpty)
        replies[1](.OK)
        XCTAssertEqual(accepted, [panel.selectedURLs])
        replies[1](.OK)
        XCTAssertEqual(accepted.count, 1)
    }

    func testOwnerIsRevalidatedAfterNativeSheetDismissalBeforeDeliveringURLs() {
        let window = TestWindow(), panel = TestPanel()
        var isCurrent = true
        var reply: ((NSApplication.ModalResponse) -> Void)?
        panel.onOrderOut = { isCurrent = false }
        let controller = LibraryImportPanelController(makePanel: { panel }, beginSheet: { _, _, completion in reply = completion })
        controller.present(source: .library, for: window, isCurrent: { isCurrent }) { _ in XCTFail("Owner changed while AppKit dismissed the sheet") }
        reply?(.OK)
        XCTAssertEqual(panel.orderOutCount, 1)
        XCTAssertFalse(isCurrent)
    }

    private final class ImportContext {}
    private final class TestWindow: NSWindow {
        override var isVisible: Bool { true }
    }
    private final class TestPanel: NSOpenPanel {
        var selectedURLs: [URL] = []
        var orderOutCount = 0
        var onOrderOut: (() -> Void)?
        var onDirectoryChange: (() -> Void)?
        override var urls: [URL] { selectedURLs }
        override var directoryURL: URL? { didSet { onDirectoryChange?() } }
        override func orderOut(_ sender: Any?) { orderOutCount += 1; onOrderOut?() }
        override func cancel(_ sender: Any?) {}
    }
}
