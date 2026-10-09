import AppKit
import ColorSync

enum ProjectionScreenResolver {
    /// AppKit adds the chosen screen's origin during window initialization.
    /// Keep this conversion independent of the connected display inventory.
    nonisolated static func screenRelativeContentRect(for frame: CGRect) -> CGRect {
        CGRect(origin: .zero, size: frame.size)
    }

    static func activeScreens(from screens: [NSScreen] = NSScreen.screens) -> [NSScreen] {
        screens.filter { $0.frame.width > 0 && $0.frame.height > 0 }
    }

    static func currentMonitors() -> [ProjectionMonitor] {
        activeScreens().compactMap { screen in
            guard let id = screen.displayID, id != 0 else { return nil }
            return ProjectionMonitor(id: id, identity: screen.displayIdentity, name: screen.localizedName,
                                     frame: screen.frame, isBuiltIn: CGDisplayIsBuiltin(id) != 0,
                                     isMirrored: CGDisplayIsInMirrorSet(id) != 0)
        }
    }

    static func screen(
        for monitor: ProjectionMonitor,
        screens: [NSScreen] = NSScreen.screens
    ) -> NSScreen? {
        guard let identity = monitor.identity, !monitor.isMirrored else { return nil }
        let matches = activeScreens(from: screens).filter { $0.displayIdentity == identity }
        guard matches.count == 1, let screen = matches.first,
              let id = screen.displayID, CGDisplayIsInMirrorSet(id) == 0 else { return nil }
        return screen
    }
}

extension NSScreen {
    var displayIdentity: String? {
        guard let id = displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
              let identity = CFUUIDCreateString(nil, uuid) else { return nil }
        return identity as String
    }

    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
