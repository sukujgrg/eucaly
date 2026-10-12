import XCTest
import SwiftUI
import AppKit
import Combine
@testable import eucaly

@MainActor
final class OutputSettingsTests: XCTestCase {
    func testDisclosureExpandsFromLabelMiddleAndTrailingSpace() async throws {
        let state = DisclosureState()
        let view = NSHostingView(rootView: DisclosureFixture(state: state))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 480, height: 240),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderBack(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(state.labelFrame.width, 0)
        let headerFrame = state.labelFrame
        for (index, x) in [headerFrame.midX, view.bounds.midX, view.bounds.maxX - 40].enumerated() {
            let previous = state.expanded
            let y = view.isFlipped ? headerFrame.midY : view.bounds.height - headerFrame.midY
            let point = view.convert(NSPoint(x: x, y: y), to: nil)
            let timestamp = ProcessInfo.processInfo.systemUptime
            let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                timestamp: timestamp, windowNumber: window.windowNumber, context: nil, eventNumber: index * 2 + 1, clickCount: 1, pressure: 1))
            let up = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                timestamp: timestamp + 0.01, windowNumber: window.windowNumber, context: nil, eventNumber: index * 2 + 2, clickCount: 1, pressure: 0))
            window.sendEvent(down); window.sendEvent(up)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertNotEqual(state.expanded, previous, "Clicking the disclosure row at x=\(x) must toggle it")
        }
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/eucaly-disclosure-row.png"))
    }
}

@MainActor
private final class DisclosureState: ObservableObject {
    @Published var expanded = false
    @Published var labelFrame = CGRect.zero
}

private struct DisclosureFrameKey: PreferenceKey {
    static var defaultValue = CGRect.zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct DisclosureFixture: View {
    @ObservedObject var state: DisclosureState
    var body: some View {
        Form {
            Section("Typography") {
                DisclosureGroup(isExpanded: $state.expanded) {
                    Toggle("Custom size", isOn: .constant(false))
                } label: {
                    Text("Primary Overrides").background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: DisclosureFrameKey.self, value: geometry.frame(in: .named("fixture")))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disclosureGroupStyle(SettingsDisclosureGroupStyle())
        .coordinateSpace(name: "fixture")
        .onPreferenceChange(DisclosureFrameKey.self) { frame in
            DispatchQueue.main.async { if state.labelFrame != frame { state.labelFrame = frame } }
        }
    }
}
