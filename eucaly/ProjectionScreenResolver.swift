import AppKit

enum ProjectionScreenResolver {
    static func activeScreens(from screens: [NSScreen] = NSScreen.screens) -> [NSScreen] {
        screens.filter { $0.frame.width > 0 && $0.frame.height > 0 }
    }

    static func exactScreen(
        displayID: CGDirectDisplayID?,
        screens: [NSScreen] = NSScreen.screens
    ) -> NSScreen? {
        guard let displayID, displayID != 0 else { return nil }
        return activeScreens(from: screens).first { $0.displayID == displayID }
    }

    static func resolve(
        displayID: CGDirectDisplayID?,
        screens: [NSScreen] = NSScreen.screens
    ) -> NSScreen? {
        if let exactMatch = exactScreen(displayID: displayID, screens: screens) {
            return exactMatch
        }

        let activeScreens = activeScreens(from: screens)
        return activeScreens.count > 1 ? activeScreens[1] : NSScreen.main
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }
}
