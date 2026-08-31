import XCTest
@testable import eucaly

final class LibrarySearchNavigationTests: XCTestCase {
    func testMacNavigationKeyCodesMapToQuickOpenCommands() {
        XCTAssertEqual(LibrarySearchNavigationCommand(keyCode: 126), .previous)
        XCTAssertEqual(LibrarySearchNavigationCommand(keyCode: 125), .next)
        XCTAssertEqual(LibrarySearchNavigationCommand(keyCode: 116), .pageUp)
        XCTAssertEqual(LibrarySearchNavigationCommand(keyCode: 121), .pageDown)
        XCTAssertEqual(LibrarySearchNavigationCommand(keyCode: 115), .first)
        XCTAssertEqual(LibrarySearchNavigationCommand(keyCode: 119), .last)
        XCTAssertNil(LibrarySearchNavigationCommand(keyCode: 0))
    }
}
