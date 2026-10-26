import AppKit

@MainActor
final class ApplicationTerminationCoordinator {
    static let shared = ApplicationTerminationCoordinator()

    private final class Registration {
        weak var owner: AnyObject?
        var shouldClose: () -> Bool

        init(owner: AnyObject, shouldClose: @escaping () -> Bool) {
            self.owner = owner
            self.shouldClose = shouldClose
        }
    }

    private var registrations: [ObjectIdentifier: Registration] = [:]

    private init() {}

    func register(owner: AnyObject, shouldClose: @escaping () -> Bool) {
        registrations[ObjectIdentifier(owner)] = Registration(owner: owner, shouldClose: shouldClose)
    }

    func confirmApplicationTermination() -> Bool {
        registrations = registrations.filter { $0.value.owner != nil }
        // Owners reveal each retained editor before asking, including controls
        // parked without a window after a workspace switch.
        for registration in Array(registrations.values) {
            guard registration.shouldClose() else { return false }
        }
        return true
    }
}
