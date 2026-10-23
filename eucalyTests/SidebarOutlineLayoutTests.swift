import AppKit
import XCTest
@testable import eucaly

@MainActor
final class SidebarOutlineLayoutTests: XCTestCase {
    func testWideningAnInitiallyNarrowSidebarRefitsExistingRows() async throws {
        let model = SidebarOutlineModel(roots: (0..<100).map { index in
            SidebarOutlineItem(id: .library(URL(fileURLWithPath: "/sidebar-layout-fixture/\(index).txt")),
                               title: "Library item \(index) with a long title", accessoryAction: .addToPlaylist)
        })
        var modelBuildCount = 0
        var selectionChangeCount = 0
        let configuration = SidebarOutlineConfiguration(
            contentRevision: 1, modelBuilder: { modelBuildCount += 1; return model },
            selectedItemIDs: [], primarySelectedItemID: nil, expansionStore: SidebarOutlineExpansionStore(),
            onSelectionChange: { _, _ in selectionChangeCount += 1; return true }
        )
        let controller = SidebarOutlineController(configuration: configuration)
        let window = makeWindow(controller: controller, width: 150)
        let reference = SidebarOutlineController(configuration: configuration)
        let referenceWindow = makeWindow(controller: reference, width: 450)
        defer { controller.detach(); reference.detach(); window.close(); referenceWindow.close() }
        try await settle(window)
        try await settle(referenceWindow)
        let wideColumnWidth = reference.outlineView.tableColumns[0].width
        let outline = controller.outlineView
        XCTAssertLessThan(outline.frame.width, 160)
        let firstItem = outline.item(atRow: 0) as? SidebarOutlineItem
        for width: CGFloat in [450, 150, 450] {
            window.setContentSize(NSSize(width: width, height: 700))
            try await settle(window)
            XCTAssertEqual(outline.selectedRow, -1)
            XCTAssertEqual(outline.numberOfRows, 100)
            XCTAssertTrue(outline.item(atRow: 0) as? SidebarOutlineItem === firstItem)
            if width == 450 {
                XCTAssertEqual(outline.tableColumns[0].width, wideColumnWidth, accuracy: 1)
                let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: false))
                XCTAssertGreaterThan(cell.frame.width, 300)
                XCTAssertFalse(cell.isHiddenOrHasHiddenAncestor)
            }
        }
        XCTAssertEqual(modelBuildCount, 2, "Resizing must not rebuild the list")
        XCTAssertEqual(selectionChangeCount, 0, "Resizing must not select a source")
    }

    func testNativeSourceListMeasurementFitsSingleRowsAndTracksExpansion() async throws {
        let children = (0..<2).map { SidebarOutlineItem(id: .library(URL(fileURLWithPath: "/sidebar-layout-fixture/\($0).txt")), title: "Item \($0)") }
        let group = SidebarOutlineItem(id: .group("kind:lyrics"), title: "Lyrics", children: children)
        let model = SidebarOutlineModel(roots: [group])
        let store = SidebarOutlineExpansionStore()
        func configuration(_ command: SidebarOutlineExpansionCommand? = nil) -> SidebarOutlineConfiguration {
            SidebarOutlineConfiguration(contentRevision: 1, expansionKey: "library:kind", modelBuilder: { model },
                selectedItemIDs: [], primarySelectedItemID: nil, expansionCommand: command, expansionStore: store,
                allowsEmptySelection: true, onSelectionChange: { _, _ in XCTFail("Measuring must remain passive"); return false })
        }
        let controller = SidebarOutlineController(configuration: configuration())
        let window = makeWindow(controller: controller, width: 260)
        defer { controller.detach(); window.close() }
        try await settle(window)
        let outline = controller.outlineView
        let clip = controller.scrollView.contentView
        XCTAssertEqual(outline.numberOfRows, 1)
        let collapsedHeight = controller.scrollView.frame.height
        assertAllRowsFit(outline, in: clip)
        XCTAssertEqual(collapsedHeight, outline.frame.height, accuracy: 1)
        controller.update(configuration(.init(action: .expandAll)))
        try await settle(window)
        XCTAssertEqual(outline.numberOfRows, 3)
        XCTAssertGreaterThan(controller.scrollView.frame.height, collapsedHeight)
        XCTAssertEqual(controller.scrollView.frame.height, outline.frame.height, accuracy: 1)
        assertAllRowsFit(outline, in: clip)
        controller.update(configuration(.init(action: .collapseAll)))
        try await settle(window)
        XCTAssertEqual(controller.scrollView.frame.height, collapsedHeight, accuracy: 1)
        assertAllRowsFit(outline, in: clip)
        controller.scrollView.maximumHeight = collapsedHeight
        controller.update(configuration(.init(action: .expandAll)))
        try await settle(window)
        XCTAssertEqual(controller.scrollView.frame.height, collapsedHeight, accuracy: 1)
        XCTAssertGreaterThan(outline.frame.height, clip.bounds.height)
    }

    private func assertAllRowsFit(_ outline: NSOutlineView, in clip: NSClipView, file: StaticString = #filePath, line: UInt = #line) {
        for row in 0..<outline.numberOfRows {
            let rect = outline.convert(outline.rect(ofRow: row), to: clip)
            XCTAssertGreaterThanOrEqual(rect.minY, clip.bounds.minY, file: file, line: line)
            XCTAssertLessThanOrEqual(rect.maxY, clip.bounds.maxY, file: file, line: line)
        }
    }

    private func makeWindow(controller: SidebarOutlineController, width: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        let content = NSView()
        window.contentView = content
        let scroll = controller.scrollView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor)
        ])
        return window
    }

    private func settle(_ window: NSWindow) async throws {
        for _ in 0..<5 {
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
