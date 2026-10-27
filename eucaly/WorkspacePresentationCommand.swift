import AppKit

/// Presentation key equivalents share one definition and one explicit-window
/// dispatch path. Focus is never an authority for a different window's outputs.
@MainActor
enum WorkspacePresentationCommand: CaseIterable {
    case toggleSlides, stopOutputs

    var keyEquivalent: String { "\r" }
    var modifiers: NSEvent.ModifierFlags {
        self == .toggleSlides ? .command : [.command, .shift]
    }
    var shortcutDescription: String {
        self == .toggleSlides ? "⌘Return" : "⇧⌘Return"
    }

    static func matching(_ event: NSEvent) -> Self? {
        guard event.type == .keyDown else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Return and keypad Enter are the same presentation action. Ignore
        // hardware flags such as numericPad, function and Caps Lock.
        guard event.charactersIgnoringModifiers == "\r" || event.charactersIgnoringModifiers == "\u{3}" else { return nil }
        return allCases.first { $0.modifiers == modifiers }
    }

    private static func coordinator(in window: NSWindow?) -> OutputCoordinator? {
        // Native sheets and app-modal dialogs own their key equivalents, notably
        // the cleanup review's Command-Return Apply. Unrelated panels never
        // inherit a presentation target from the last focused workspace.
        guard let window, window.attachedSheet == nil, window.sheetParent == nil,
              NSApp.modalWindow == nil else { return nil }
        if let controls = window as? OutputWorkspaceWindow {
            return controls.workspaceSession?.outputCoordinator
        }
        guard let projection = window as? PresentationWindow, projection.outputDestinationID != nil else { return nil }
        return projection.outputCoordinator
    }

    func isEnabled(in window: NSWindow?, outputs: OutputCoordinator) -> Bool {
        guard Self.coordinator(in: window) === outputs else { return false }
        switch self {
        case .toggleSlides: return outputs.commandSession(for: window)?.isEmpty == false
        case .stopOutputs: return outputs.commandWorkspaceID(for: window) != nil
        }
    }

    func perform(in window: NSWindow?, outputs: OutputCoordinator) {
        guard isEnabled(in: window, outputs: outputs) else { return }
        // A held Return must not repeatedly show and hide the program. A menu
        // click still works regardless of the previous keyboard event.
        if let event = NSApp.currentEvent, Self.matching(event) == self, event.isARepeat { return }
        switch self {
        case .toggleSlides: outputs.commandSession(for: window)?.toggleSlidesVisibility()
        case .stopOutputs:
            if let owner = outputs.commandWorkspaceID(for: window) { outputs.stop(workspace: owner) }
        }
    }

    static func handleKeyEquivalent(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard let command = matching(event), let outputs = coordinator(in: window) else { return false }
        if !event.isARepeat { command.perform(in: window, outputs: outputs) }
        // Consume recognized but disabled commands too: an empty Current must
        // never let Command-Return fall through to Search's Preview default.
        return true
    }
}
