import AppKit

@MainActor
final class ApplicationTerminationCoordinator {
    static let shared = ApplicationTerminationCoordinator()

    private final class Registration {
        weak var window: NSWindow?
        var shouldClose: () -> Bool

        init(window: NSWindow, shouldClose: @escaping () -> Bool) {
            self.window = window
            self.shouldClose = shouldClose
        }
    }

    private var registrations: [UUID: Registration] = [:]

    private init() {}

    func register(id: UUID, window: NSWindow, shouldClose: @escaping () -> Bool) {
        registrations[id] = Registration(window: window, shouldClose: shouldClose)
    }

    func unregister(id: UUID) {
        registrations.removeValue(forKey: id)
    }

    func confirmApplicationTermination() -> Bool {
        registrations = registrations.filter { $0.value.window != nil }
        let ordered = registrations.values.sorted { lhs, rhs in
            (lhs.window?.isKeyWindow == true) && (rhs.window?.isKeyWindow != true)
        }

        for registration in ordered {
            registration.window?.makeKeyAndOrderFront(nil)
            guard registration.shouldClose() else { return false }
        }
        return true
    }
}
