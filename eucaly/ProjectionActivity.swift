import Combine
import Foundation

/// Application-wide projection activity, including windows with hidden slides.
@MainActor
final class ProjectionActivity: ObservableObject {
    static let shared = ProjectionActivity()

    @Published private(set) var isActive = false
    private var activeSessions = Set<UUID>()

    func setActive(_ active: Bool, for sessionID: UUID) {
        if active {
            activeSessions.insert(sessionID)
        } else {
            activeSessions.remove(sessionID)
        }
        let newValue = !activeSessions.isEmpty
        if isActive != newValue {
            isActive = newValue
        }
    }
}
