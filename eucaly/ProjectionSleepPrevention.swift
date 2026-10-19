import Foundation

/// Owns one activity for an open projection, independent of slides and controls.
/// Foundation's activity API is actor-independent; teardown releases it directly.
nonisolated final class ProjectionSleepPrevention {
    private let beginActivity: (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol
    private let endActivity: (NSObjectProtocol) -> Void
    private var activity: NSObjectProtocol?
    private let preventsDisplaySleep: Bool

    init(preventsDisplaySleep: Bool = true, beginActivity: @escaping (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol = {
        ProcessInfo.processInfo.beginActivity(options: $0, reason: $1)
    }, endActivity: @escaping (NSObjectProtocol) -> Void = {
        ProcessInfo.processInfo.endActivity($0)
    }) {
        self.beginActivity = beginActivity
        self.endActivity = endActivity
        self.preventsDisplaySleep = preventsDisplaySleep
    }

    func start() {
        guard activity == nil else { return }
        var options: ProcessInfo.ActivityOptions = [.userInitiated, .idleSystemSleepDisabled]
        if preventsDisplaySleep { options.insert(.idleDisplaySleepDisabled) }
        activity = beginActivity(options,
                                 "Presenting eucaly output")
    }

    func stop() {
        guard let activity else { return }
        self.activity = nil
        endActivity(activity)
    }

    deinit {
        if let activity { endActivity(activity) }
    }
}
