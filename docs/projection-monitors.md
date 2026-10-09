# Projection monitors

Use the toolbar’s display menu → **Manage Monitors…**, or **Settings → Projection**, to choose, identify, and name monitors. Identify displays a monitor’s eucaly number and name for three seconds without loading Current or starting projection. It is unavailable on a monitor currently projecting. In the name editor, click anywhere on the **Monitor Details** row to show or hide the model name and macOS display UUID.

Monitors receive remembered numbers even when several share the same model name. Give each a useful name such as “Front Left TV” or “Main Projector”. An empty name restores the model name. Disconnected monitors remain listed and can still be renamed.

A selected monitor is a fixed destination. If that monitor disconnects, becomes mirrored, or cannot be distinguished from another monitor, projection stops. Current and background audio remain intact. Reconnect the monitor, then explicitly show slides again, or choose another monitor. Eucaly keeps the assignment and never switches output to another display.

Choose a monitor before showing slides or background visuals. The selection is remembered between launches. There is no automatic monitor choice or fallback, even when only one monitor is connected. A previous Auto preference shows “Choose a monitor” and requires a selection before output can start. Stop projection before changing the monitor selection.

While projection is open, eucaly keeps the Mac and displays awake. This includes hidden slides, an empty Current, and background-only output. **Stop Projection**, closing the projection window, disconnecting its monitor, or quitting releases the protection. Browsing, Identify, and audio playing without projection do not keep displays awake. Your macOS sleep settings are not changed.

Names and assignments follow the macOS display UUID, using the same identity mechanism as AltView. macOS may report a different identity after changing cables or adapters; use Identify again to confirm the physical screens. If monitors report the same identity, eucaly refuses to guess. Use distinguishable connections and extended displays in macOS.

## Implementation and validation

`ProjectionDisplayManager` owns the inventory, assignment, labels, and active-output locks. `ProjectionScreenResolver` derives UUIDs through ColorSync and resolves exactly one current `NSScreen`. Temporary `CGDirectDisplayID` values are used only to inspect connected screens. The legacy numeric selection is migrated once if it can be matched; an unavailable or unreadable saved selection requires an explicit choice.

`PresentationSession` resolves the explicitly selected UUID against a fresh inventory at each start. Screen changes close unsafe output immediately and defer frame adjustment for the same identity. Reconnecting does not automatically reopen projection. Slides, background visuals, commands, and projection-window shortcuts use this same authority. The Stop Projection command belongs to the session so it also releases the monitor after the original controls window closes. Preview/Current flow remains independent.

The session owns a `ProjectionSleepPrevention` activity using `ProcessInfo.beginActivity` with `.userInitiated`, `.idleSystemSleepDisabled`, and `.idleDisplaySleepDisabled`. It starts only after a valid projection window is created and ends through the common projection teardown. The activity also releases on owner deinitialization. `ProjectionSleepPreventionTests` verifies balanced activity tokens with injected callbacks without needing a physical display; optional window checks cover hidden/cleared output, background starts, close, disconnect, and reconnect.

`ProjectionDisplayTests` covers identical names, remembered numbering and renaming, reordered inventories, runtime ID changes and reuse, disconnected assignments, ambiguous and mirrored displays, required explicit selection, migration, corrupt preferences, active-output locks, and session disconnection behavior. Synthetic frames test window positioning with monitors to the right, left, above, and below without requiring physical monitors. Optional live-window checks use any uniquely identified, unmirrored display available on the host and skip when none is available; no Dell model or second monitor is required in GitHub Actions. Window creation uses coordinates relative to the selected screen, then applies the global frame before showing output. Run `make test` for the complete regression suite.

For physical validation, connect two same-model monitors, identify and name both, select one, and show Current. Reorder displays in macOS and confirm the output stays on the named monitor. Unplug it and verify projection closes without appearing on the other screen; reconnect and explicitly show slides again. Repeat with hidden slides and background visual output, and with mirroring enabled. Confirm names survive relaunch.
