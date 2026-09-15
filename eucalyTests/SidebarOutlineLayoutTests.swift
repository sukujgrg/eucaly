import AppKit
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class SidebarOutlineLayoutTests: XCTestCase {
    func testWideningAnInitiallyNarrowSidebarRefitsExistingRows() async throws {
        let model = SidebarOutlineModel(roots: (0..<100).map { index in
            SidebarOutlineItem(
                id: .library(URL(fileURLWithPath: "/sidebar-layout-fixture/\(index).txt")),
                title: "Library item \(index) with a long title",
                accessoryAction: .addToPlaylist
            )
        })
        var modelBuildCount = 0
        var selectionChangeCount = 0
        let narrow = makeWindow(idealWidth: nil, model: model) {
            modelBuildCount += 1
        } onSelectionChange: {
            selectionChangeCount += 1
        }
        let reference = makeWindow(idealWidth: 320, model: model)
        defer { narrow.close(); reference.close() }
        try await settle([narrow, reference])

        let outline = try XCTUnwrap(find(NSOutlineView.self, in: narrow.contentView))
        let split = try XCTUnwrap(find(NSSplitView.self, in: narrow.contentView))
        let referenceOutline = try XCTUnwrap(find(NSOutlineView.self, in: reference.contentView))
        let referenceSplit = try XCTUnwrap(find(NSSplitView.self, in: reference.contentView))
        XCTAssertLessThan(outline.frame.width, 160)

        referenceSplit.setPosition(450, ofDividerAt: 0)
        try await settle([reference])
        let referenceColumnWidth = try XCTUnwrap(referenceOutline.tableColumns.first).width
        XCTAssertGreaterThan(referenceColumnWidth, 300)

        for width: CGFloat in [450, 150, 450] {
            split.setPosition(width, ofDividerAt: 0)
            try await settle([narrow])
            XCTAssertTrue(find(NSOutlineView.self, in: narrow.contentView) === outline)
            XCTAssertEqual(outline.selectedRow, -1)
            XCTAssertEqual(outline.numberOfRows, 100)

            if width == 450 {
                XCTAssertEqual(outline.tableColumns[0].width, referenceColumnWidth, accuracy: 1)
                let cell = try XCTUnwrap(outline.view(atColumn: 0, row: 0, makeIfNecessary: false))
                let referenceCell = try XCTUnwrap(referenceOutline.view(
                    atColumn: 0, row: 0, makeIfNecessary: false
                ))
                XCTAssertEqual(cell.frame.width, referenceCell.frame.width, accuracy: 1)
                XCTAssertFalse(cell.isHiddenOrHasHiddenAncestor)
            }
        }

        XCTAssertEqual(modelBuildCount, 1, "Resizing must not rebuild the list")
        XCTAssertEqual(selectionChangeCount, 0, "Resizing must not select a source")
    }

    private func makeWindow(
        idealWidth: CGFloat?,
        model: SidebarOutlineModel,
        onModelBuild: @escaping () -> Void = {},
        onSelectionChange: @escaping () -> Void = {}
    ) -> NSWindow {
        let outline = SidebarOutlineView(
            contentRevision: 1,
            modelBuilder: { onModelBuild(); return model },
            selectedItemIDs: [],
            primarySelectedItemID: nil,
            expansionStore: SidebarOutlineExpansionStore(),
            onSelectionChange: { _, _ in onSelectionChange(); return true }
        )
        let host = NSHostingView(rootView: SidebarLayoutFixture(idealWidth: idealWidth, outline: outline))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentView = host
        return window
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0) }.first
    }

    private func settle(_ windows: [NSWindow]) async throws {
        for _ in 0..<10 {
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

private struct SidebarLayoutFixture: View {
    let idealWidth: CGFloat?
    let outline: SidebarOutlineView

    var body: some View {
        NavigationSplitView {
            if let idealWidth {
                sidebar.navigationSplitViewColumnWidth(min: 140, ideal: idealWidth, max: 520)
            } else {
                sidebar
            }
        } detail: {
            Color.clear.frame(minWidth: 520)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1060, minHeight: 600)
    }

    private var sidebar: some View {
        GeometryReader { _ in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Library")
                    HStack {
                        Button("Import...") {}
                        Text("Group")
                        Picker("Group", selection: .constant(0)) {
                            Text("Kind").tag(0)
                        }
                        .labelsHidden()
                        Button("Collapse") {}
                    }
                    outline.frame(maxWidth: .infinity, minHeight: 240, maxHeight: 240)
                    Text("Playlist")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, 18)
            }
        }
    }
}
