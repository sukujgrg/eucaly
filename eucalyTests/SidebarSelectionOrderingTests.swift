import XCTest
@testable import eucaly

final class SidebarSelectionOrderingTests: XCTestCase {
    func testCmdClickAppendsInClickOrderNotVisualOrder() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.txt")
        // Visual outline lists lyrics before images (Kind grouping).
        let visual = [b, a]
        let afterFirst = SidebarSelectionOrdering.updatingOrder(
            previous: [],
            newSet: [a],
            visualOrder: visual
        )
        XCTAssertEqual(afterFirst, [a])

        let afterSecond = SidebarSelectionOrdering.updatingOrder(
            previous: afterFirst,
            newSet: [a, b],
            visualOrder: visual
        )
        XCTAssertEqual(afterSecond, [a, b], "Later ⌘-click appends even when it sits above in the outline")
    }

    func testCmdClickRemoveKeepsRelativeOrder() {
        let urls = (0..<3).map { URL(fileURLWithPath: "/tmp/\($0).png") }
        let remaining = SidebarSelectionOrdering.updatingOrder(
            previous: urls,
            newSet: [urls[0], urls[2]],
            visualOrder: urls.reversed()
        )
        XCTAssertEqual(remaining, [urls[0], urls[2]])
    }

    func testShiftRangeAppendsNewItemsInVisualOrder() {
        let urls = (0..<4).map { URL(fileURLWithPath: "/tmp/\($0).png") }
        let after = SidebarSelectionOrdering.updatingOrder(
            previous: [urls[3]],
            newSet: Set(urls),
            visualOrder: urls
        )
        XCTAssertEqual(after, [urls[3], urls[0], urls[1], urls[2]])
    }

    func testEarlyExitIgnoresTrailingVisualOrder() {
        let selected = (0..<3).map { URL(fileURLWithPath: "/tmp/sel\($0).png") }
        let trailing = (0..<200).map { URL(fileURLWithPath: "/tmp/extra\($0).png") }
        let visual = selected + trailing
        let after = SidebarSelectionOrdering.updatingOrder(
            previous: [selected[2]],
            newSet: Set(selected),
            visualOrder: visual
        )
        XCTAssertEqual(after, [selected[2], selected[0], selected[1]])
    }

    func testLeftoverIDsMissingFromVisualOrderAppendAfterKnown() {
        let a = URL(fileURLWithPath: "/tmp/a.png")
        let b = URL(fileURLWithPath: "/tmp/b.png")
        let orphan = URL(fileURLWithPath: "/tmp/orphan.png")
        let after = SidebarSelectionOrdering.updatingOrder(
            previous: [a],
            newSet: [a, b, orphan],
            visualOrder: [a, b]
        )
        XCTAssertEqual(after, [a, b, orphan])
    }
}
