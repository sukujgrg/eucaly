import AppKit
import XCTest
@testable import eucaly

final class LibrarySearchNavigationTests: XCTestCase {
    @MainActor
    func testRestoringExistingSearchFocusPreservesInsertionPoint() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        let searchField = NSSearchField(frame: NSRect(x: 10, y: 20, width: 300, height: 28))
        window.contentView?.addSubview(searchField)
        searchField.stringValue = "grace"

        XCTAssertTrue(window.makeFirstResponder(searchField))
        let fieldEditor = try XCTUnwrap(searchField.currentEditor() as? NSTextView)
        fieldEditor.selectedRange = NSRange(location: 5, length: 0)

        let router = LibrarySearchCommandRouter()
        router.register(searchField: searchField)
        router.restoreSearchFocus()
        await Task.yield()

        XCTAssertTrue(window.firstResponder === fieldEditor)
        XCTAssertEqual(fieldEditor.selectedRange, NSRange(location: 5, length: 0))
    }

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

    func testOnlyResultRowsParticipateInSelection() {
        XCTAssertFalse(LibrarySearchRowRole.section.isSelectable)
        XCTAssertFalse(LibrarySearchRowRole.action.isSelectable)
        XCTAssertTrue(LibrarySearchRowRole.result.isSelectable)
    }

    func testArrowNavigationSkipsNonResultRows() {
        let resultRows = [2, 5, 9]

        XCTAssertEqual(
            LibrarySearchResultNavigator.targetRow(
                resultRows: resultRows,
                currentRow: 2,
                direction: 1
            ),
            5
        )
        XCTAssertEqual(
            LibrarySearchResultNavigator.targetRow(
                resultRows: resultRows,
                currentRow: 9,
                direction: -1
            ),
            5
        )
    }

    func testArrowNavigationClampsAtResultBoundaries() {
        let resultRows = [2, 5, 9]

        XCTAssertEqual(
            LibrarySearchResultNavigator.targetRow(
                resultRows: resultRows,
                currentRow: 2,
                direction: -1
            ),
            2
        )
        XCTAssertEqual(
            LibrarySearchResultNavigator.targetRow(
                resultRows: resultRows,
                currentRow: 9,
                direction: 1
            ),
            9
        )
    }

    func testArrowNavigationUsesDirectionalFallbackWithoutSelection() {
        let resultRows = [2, 5, 9]

        XCTAssertEqual(
            LibrarySearchResultNavigator.targetRow(
                resultRows: resultRows,
                currentRow: nil,
                direction: -1
            ),
            9
        )
        XCTAssertEqual(
            LibrarySearchResultNavigator.targetRow(
                resultRows: resultRows,
                currentRow: nil,
                direction: 1
            ),
            2
        )
        XCTAssertNil(
            LibrarySearchResultNavigator.targetRow(
                resultRows: [],
                currentRow: nil,
                direction: 1
            )
        )
    }

    func testPageAndBoundaryKeysOnlyScroll() {
        XCTAssertEqual(
            LibrarySearchNavigationCommand.pageUp.operation,
            .scrollPage(up: true)
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand.pageDown.operation,
            .scrollPage(up: false)
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand.scrollToBeginning.operation,
            .scrollToBoundary(beginning: true)
        )
        XCTAssertEqual(
            LibrarySearchNavigationCommand.scrollToEnd.operation,
            .scrollToBoundary(beginning: false)
        )
    }
}
