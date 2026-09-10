import AppKit
import Combine
import SwiftUI
import XCTest
@testable import eucaly

@MainActor
final class InterfaceMotionTests: XCTestCase {
    func testDisclosureAnimatesContainerButNotMediaDescendants() async {
        let animations = await updateHostedView(using: .disclosure)
        XCTAssertNotNil(animations.container)
        XCTAssertNil(animations.content)
    }

    func testDisclosureBoundaryPreservesSelectionScrolling() async {
        let animations = await updateHostedView(using: .selectionScroll)
        XCTAssertNotNil(animations.container)
        XCTAssertEqual(animations.content, animations.container)
    }

    func testOrdinaryUpdatesDoNotAcquireAnAnimation() async {
        let animations = await updateHostedView(using: nil)
        XCTAssertNil(animations.container)
        XCTAssertNil(animations.content)
    }

    func testReduceMotionDisablesDisclosure() async {
        let animations = await updateHostedView(using: .disclosure, reduceMotion: true)
        XCTAssertNil(animations.container)
        XCTAssertNil(animations.content)
    }

    private func updateHostedView(
        using motion: InterfaceMotion?,
        reduceMotion: Bool = false
    ) async -> (container: Animation?, content: Animation?) {
        let state = MotionTestState()
        let containerUpdated = expectation(description: "Container received state update")
        let contentUpdated = expectation(description: "Content received state update")
        var containerAnimation: Animation?
        var contentAnimation: Animation?
        let host = NSHostingView(rootView: MotionTestView(
            state: state,
            containerUpdated: { transaction in
                containerAnimation = transaction.animation
                containerUpdated.fulfill()
            },
            contentUpdated: { transaction in
                contentAnimation = transaction.animation
                contentUpdated.fulfill()
            }
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        defer { window.close() }

        if let motion {
            motion.animate(reduceMotion: reduceMotion) { state.revision += 1 }
        } else {
            state.revision += 1
        }
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [containerUpdated, contentUpdated], timeout: 3)
        return (containerAnimation, contentAnimation)
    }
}

@MainActor
private final class MotionTestState: ObservableObject {
    @Published var revision = 0
}

private struct MotionTestView: View {
    @ObservedObject var state: MotionTestState
    let containerUpdated: (Transaction) -> Void
    let contentUpdated: (Transaction) -> Void

    var body: some View {
        HStack {
            MotionTransactionProbe(revision: state.revision, onUpdate: containerUpdated)
            MotionTransactionProbe(revision: state.revision, onUpdate: contentUpdated)
                .excludingInterfaceAnimation(.disclosure)
        }
        .frame(height: state.revision == 0 ? 100 : 150)
    }
}

private struct MotionTransactionProbe: NSViewRepresentable {
    let revision: Int
    let onUpdate: (Transaction) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        if revision == 1 { onUpdate(context.transaction) }
    }
}
