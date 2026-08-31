import XCTest
@testable import eucaly

@MainActor
final class SidebarOutlineNavigationCoordinatorTests: XCTestCase {
    func testMoveUsesVisualSectionOrderAndSkipsUnavailableTargets() {
        let coordinator = SidebarOutlineNavigationCoordinator()
        let playlist = NavigationRecorder(hasSelectableRows: false)
        let web = NavigationRecorder()
        coordinator.register(recorder: playlist, for: .playlist)
        coordinator.register(recorder: web, for: .web)

        let didMove = coordinator.move(
            from: .library,
            direction: .down,
            restoreSourceFocus: {}
        )

        XCTAssertTrue(didMove)
        XCTAssertTrue(playlist.focusDirections.isEmpty)
        XCTAssertEqual(web.focusDirections, [.down])
    }

    func testRejectedBoundarySelectionRestoresSourceFocus() {
        let coordinator = SidebarOutlineNavigationCoordinator()
        let web = NavigationRecorder(acceptsFocus: false)
        var restoreFocusCount = 0
        coordinator.register(recorder: web, for: .web)

        XCTAssertTrue(
            coordinator.move(
                from: .playlist,
                direction: .down,
                restoreSourceFocus: { restoreFocusCount += 1 }
            )
        )
        XCTAssertEqual(web.focusDirections, [.down])
        XCTAssertEqual(restoreFocusCount, 1)
    }
}

@MainActor
private final class NavigationRecorder {
    let hasSelectableRows: Bool
    let acceptsFocus: Bool
    var focusDirections: [SidebarOutlineNavigationDirection] = []

    init(hasSelectableRows: Bool = true, acceptsFocus: Bool = true) {
        self.hasSelectableRows = hasSelectableRows
        self.acceptsFocus = acceptsFocus
    }
}

@MainActor
private extension SidebarOutlineNavigationCoordinator {
    func register(
        recorder: NavigationRecorder,
        for section: SidebarOutlineNavigationSection
    ) {
        register(
            id: UUID(),
            for: section,
            hasSelectableRows: { recorder.hasSelectableRows },
            focusBoundaryRow: { direction in
                recorder.focusDirections.append(direction)
                return recorder.acceptsFocus
            }
        )
    }
}
