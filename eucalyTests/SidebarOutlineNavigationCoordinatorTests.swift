import XCTest
@testable import eucaly

@MainActor
final class SidebarOutlineNavigationCoordinatorTests: XCTestCase {
    func testOutlineBoundaryVisitsCollapsedHeaderBeforeItsHiddenRows() {
        let coordinator = SidebarOutlineNavigationCoordinator()
        let playlist = NavigationRecorder(hasVisibleRows: false)
        let window = NavigationRecorder()
        coordinator.register(recorder: playlist, for: .playlist)
        coordinator.register(recorder: window, for: .window)

        let didMove = coordinator.moveFromOutline(
            from: .library,
            direction: .down,
            restoreSourceFocus: {}
        )

        XCTAssertTrue(didMove)
        XCTAssertEqual(playlist.headerFocusCount, 1)
        XCTAssertTrue(playlist.focusDirections.isEmpty)
        XCTAssertTrue(window.focusDirections.isEmpty)
    }

    func testHeaderTraversalIncludesAudioAndSkipsOnlyUnavailableSections() {
        let coordinator = SidebarOutlineNavigationCoordinator()
        let playlist = NavigationRecorder(isAvailable: false)
        let audio = NavigationRecorder()
        coordinator.register(recorder: playlist, for: .playlist)
        coordinator.register(recorder: audio, for: .audio)
        XCTAssertTrue(coordinator.moveFromOutline(from: .library, direction: .down, restoreSourceFocus: {}))
        XCTAssertEqual(playlist.headerFocusCount, 0)
        XCTAssertEqual(audio.headerFocusCount, 1)
        XCTAssertTrue(coordinator.moveFromHeader(from: .window, direction: .up, restoreSourceFocus: {}))
        XCTAssertEqual(audio.focusDirections, [.up])
    }

    func testUpFromFirstOutlineRowReturnsToItsOwnHeader() {
        let coordinator = SidebarOutlineNavigationCoordinator()
        let library = NavigationRecorder()
        coordinator.register(recorder: library, for: .library)
        XCTAssertTrue(coordinator.moveFromOutline(from: .library, direction: .up, restoreSourceFocus: {}))
        XCTAssertEqual(library.headerFocusCount, 1)
        XCTAssertTrue(library.focusDirections.isEmpty)
    }

    func testRejectedEntryFromHeaderRestoresSourceFocusWithoutSkipping() {
        let coordinator = SidebarOutlineNavigationCoordinator()
        let playlist = NavigationRecorder(acceptsFocus: false)
        let window = NavigationRecorder()
        var restoreFocusCount = 0
        coordinator.register(recorder: playlist, for: .playlist)
        coordinator.register(recorder: window, for: .window)

        XCTAssertTrue(
            coordinator.moveFromHeader(
                from: .playlist,
                direction: .down,
                restoreSourceFocus: { restoreFocusCount += 1 }
            )
        )
        XCTAssertEqual(playlist.focusDirections, [.down])
        XCTAssertTrue(window.focusDirections.isEmpty)
        XCTAssertEqual(restoreFocusCount, 1)
    }

    func testRetiringNavigationRemovesHeadersAndRows() {
        let coordinator = SidebarOutlineNavigationCoordinator()
        let library = NavigationRecorder()
        coordinator.register(recorder: library, for: .library)
        coordinator.removeAllRegistrations()
        XCTAssertFalse(coordinator.focusHeader(in: .library))
        XCTAssertFalse(coordinator.moveFromHeader(from: .library, direction: .down, restoreSourceFocus: {}))
        XCTAssertEqual(library.headerFocusCount, 0)
        XCTAssertTrue(library.focusDirections.isEmpty)
    }
}

@MainActor
private final class NavigationRecorder {
    let isAvailable: Bool
    let hasVisibleRows: Bool
    let acceptsFocus: Bool
    var focusDirections: [SidebarOutlineNavigationDirection] = []
    var headerFocusCount = 0

    init(isAvailable: Bool = true, hasVisibleRows: Bool = true, acceptsFocus: Bool = true) {
        self.isAvailable = isAvailable
        self.hasVisibleRows = hasVisibleRows
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
            for: section,
            isAvailable: { recorder.isAvailable },
            hasVisibleRows: { recorder.hasVisibleRows },
            focusHeader: {
                recorder.headerFocusCount += 1
                return true
            },
            focusBoundaryRow: { direction in
                recorder.focusDirections.append(direction)
                return recorder.acceptsFocus
            }
        )
    }
}
