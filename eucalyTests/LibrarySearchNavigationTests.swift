import AppKit
import XCTest
@testable import eucaly

final class LibrarySearchNavigationTests: XCTestCase {
    func testAppKitSelectorsMapToQuickOpenCommands() {
        XCTAssertEqual(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.moveUp(_:))),
            .previous
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.moveDown(_:))),
            .next
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.pageUp(_:))),
            .pageUp
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.scrollPageUp(_:))),
            .pageUp
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.pageDown(_:))),
            .pageDown
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.scrollPageDown(_:))),
            .pageDown
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(
                selector: #selector(NSResponder.scrollToBeginningOfDocument(_:))
            ),
            .scrollToBeginning
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand(
                selector: #selector(NSResponder.scrollToEndOfDocument(_:))
            ),
            .scrollToEnd
        )
        XCTAssertNil(
            LibrarySearchNavigationCommand(selector: #selector(NSResponder.deleteBackward(_:)))
        )
    }

    func testOnlyArrowCommandsChangeResultSelection() {
        XCTAssertTrue(LibrarySearchNavigationCommand.previous.changesSelection)
        XCTAssertTrue(LibrarySearchNavigationCommand.next.changesSelection)
        XCTAssertFalse(LibrarySearchNavigationCommand.pageUp.changesSelection)
        XCTAssertFalse(LibrarySearchNavigationCommand.pageDown.changesSelection)
        XCTAssertFalse(LibrarySearchNavigationCommand.scrollToBeginning.changesSelection)
        XCTAssertFalse(LibrarySearchNavigationCommand.scrollToEnd.changesSelection)
    }
}
