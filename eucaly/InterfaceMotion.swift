import SwiftUI

enum InterfaceMotion: Equatable, Sendable {
    case disclosure
    case selectionScroll
    case selectionHighlight
    case search
    case hover
    case press

    func animation(reduceMotion: Bool) -> Animation? {
        // Brief background fades remain useful feedback with Reduce Motion.
        if reduceMotion && self != .hover && self != .press {
            return nil
        }

        // Smooth springs retarget scrolling and disclosure without overshoot.
        // Keep the selection border quick when navigating with arrow keys.
        switch self {
        case .disclosure: return .smooth(duration: 0.24)
        case .selectionScroll: return .smooth(duration: 0.18)
        case .selectionHighlight: return .easeInOut(duration: 0.12)
        case .search: return .smooth(duration: 0.2)
        case .hover: return .easeOut(duration: 0.1)
        case .press: return .easeOut(duration: 0.08)
        }
    }

    func animate(reduceMotion: Bool, _ changes: () -> Void) {
        var transaction = Transaction(animation: animation(reduceMotion: reduceMotion))
        transaction[InterfaceMotionTransactionKey.self] = self
        withTransaction(transaction, changes)
    }
}

private struct InterfaceMotionTransactionKey: TransactionKey {
    nonisolated static let defaultValue: InterfaceMotion? = nil
}

extension View {
    /// Keep a container's animation out of expensive descendants while allowing
    /// their own selection and scrolling animations to run normally.
    func excludingInterfaceAnimation(_ motion: InterfaceMotion) -> some View {
        transaction { transaction in
            if transaction[InterfaceMotionTransactionKey.self] == motion {
                transaction.animation = nil
            }
        }
    }
}
