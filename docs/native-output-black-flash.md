# Native output black flash (lyrics + background)

Investigation of Native Output briefly going fully black while lyrics and a
background visual image are both intended to be showing. Operator controls do
not change at the moment of the flash. Content returns by itself after about a
second.

Status: repair landed. A one-second blackout still needs a trace that `setFrame` ran.
The snippets below are the pre-repair path. `ProjectionWindowPlacement.move` now
uses `setFrame(_:display: false)`, and `ProjectionDisplayManager.changed()`
coalesces a nested observer pass before it returns.

## Symptom

- Physical monitor Audience (or other non-Confidence) output is live.
- Current shows lyrics; destination appearance has a background visual image.
- The whole output goes black for roughly one second: lyrics and background
  image disappear together.
- Eucaly’s operator UI shows no Hide, Clear, Load, appearance edit, or slide
  change at that moment.
- Output returns without Show Slides.

## Root cause

A screen-parameter notification can reach `refresh()` with no eucaly command.
Observers run only when the sorted `ProjectionMonitor` inventory differs. If an
open destination’s UUID still resolves and `window.frame` differs from that
screen’s frame, `reposition` calls `setFrame(_:display: true)`.

Apple documents that `display: true` sends `displayIfNeeded()` immediately,
rather than waiting for the next pass through the event loop. The window is
opaque, its background color is black, and its only content is one
`NSHostingView`. `NSView.isOpaque` defaults to false, so parts of that host
which have not covered their frame show the window background. Lyrics and the
background image are siblings in that host. This path leaves the window and
Current open.

Apple does not document that `displayIfNeeded` runs before layout. One
immediate redisplay is a single frame. A one-second blackout still needs a
trace that `setFrame` ran.

This is a eucaly wiring defect on top of that AppKit behaviour, not a
lyrics/background visibility toggle and not a Current/snapshot clear.

## Apple documentation for this behaviour

### 1. Screen-parameter notifications arrive without an eucaly command

[`NSApplication.didChangeScreenParametersNotification`](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification)
is posted when the configuration of attached displays changes. Apple states
that the change can be made programmatically or when the user changes settings
in Displays, that the notification has **no `userInfo`**, and that it is posted
on the main actor.

Because there is no payload describing *what* changed, an observer must diff
its own screen inventory. Eucaly does listen:

```87:92:eucaly/ProjectionDisplayManager.swift
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
```

A notification whose sorted inventory still compares equal returns inside
`refresh()`. A difference that still resolves the assigned UUID reaches
`displaysChanged` with no eucaly menu, toolbar, or keyboard action.

### 2. `setFrame(_:display: true)` forces a view-hierarchy redisplay

[`NSWindow.setFrame(_:display:)`](https://developer.apple.com/documentation/appkit/nswindow/setframe(_:display:))
sets the window’s on-screen frame. Apple’s `display` flag:

> Specifies whether the window redraws the views that need to be displayed.
> When `true` the window sends a `displayIfNeeded()` message down its view
> hierarchy, thus redrawing all views.

[`displayIfNeeded()`](https://developer.apple.com/documentation/appkit/nswindow/displayifneeded())
itself says it redraws the views that need displaying, and that a window
normally does that on each pass through the event loop. `display: true` is
the immediate pass. It does not say every view is dirty, and it does not say
the pass runs before layout.

Eucaly’s live reposition path uses that forced redisplay:

```41:45:eucaly/Output/OutputWindowDestination.swift
    func reposition(monitor: ProjectionMonitor) -> Bool {
        guard let screen = ProjectionScreenResolver.screen(for: monitor) else { return false }
        if window?.frame != screen.frame { window?.setFrame(screen.frame, display: true) }
        return true
    }
```

Identify, on the same full-screen borderless pattern, uses `display: false`:

```36:36:eucaly/ProjectionMonitorIdentifier.swift
        window.setFrame(screen.frame, display: false)
```

### 3. The window background is black and the host is not opaque

Current AppKit docs name [`backgroundColor`](https://developer.apple.com/documentation/appkit/nswindow/backgroundcolor)
as the color of the window’s background and [`isOpaque`](https://developer.apple.com/documentation/appkit/nswindow/isopaque)
as whether the window is opaque. [`NSView.isOpaque`](https://developer.apple.com/documentation/appkit/nsview/isopaque)
defaults to false. The archived [How a Window is Displayed](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/WinPanel/Concepts/HowWindowIsDisplayed.html)
guide says display draws views into the window’s display buffer, and
`displayIfNeeded` redraws views that need display. Current symbol docs do not
say the background is painted when those views have not covered the frame.

Native output sets the window to a black opaque shield before hosting content:

```29:35:eucaly/Output/OutputWindowDestination.swift
        output.level = .screenSaver; output.backgroundColor = .black
        output.isOpaque = true; output.hasShadow = false
        ...
        output.contentView = NSHostingView(rootView: OutputCompositionView(...))
        output.setFrame(screen.frame, display: true)
```

Where the hosting view has not covered its frame, the black window background
is what remains visible. That is a consequence of the opaque window and the
non-opaque host, not a documented “draw the background before layout” step.

### 4. `NSHostingView` reports SwiftUI size during layout

[`NSHostingView`](https://developer.apple.com/documentation/swiftui/nshostingview)
is the AppKit bridge for SwiftUI. Apple documents that during layout the hosting
view reports SwiftUI size preferences back to AppKit. If its frame is larger
than the size its SwiftUI content requires, that content is centered in the
frame. As the content view of a window, the default `sizingOptions` also push
the content’s minimum and maximum size into the window. None of this says
`displayIfNeeded` runs before layout.

Native composition sizes **every** layer from one `GeometryReader` inside that
host:

```8:21:eucaly/Output/OutputCompositionView.swift
        GeometryReader { geometry in
            if let profile = coordinator.profile(for: destinationID) {
                let size = geometry.size
                ...
                ZStack {
                    profile.background.colour.color.frame(width: size.width, height: size.height)
                    OutputBackgroundView(...)
                        .frame(width: size.width, height: size.height)
                    content(...).frame(width: size.width, height: size.height)
```

Lyrics (`OutputTextView`) and the background image (`OutputBackgroundView` →
`ImageSlideView`) are siblings in that stack. There is no separate “hide
lyrics” or “hide background” step on this path. Both are absent together when
the host has not covered the black window.

## Eucaly amplification of the AppKit behaviour

### Over-broad inventory equality

Synthesized `ProjectionMonitor` equality includes the runtime
`CGDirectDisplayID`, localized name, frame, `isBuiltIn`, and `isMirrored`,
not only the durable ColorSync UUID:

```10:16:eucaly/ProjectionDisplayManager.swift
nonisolated struct ProjectionMonitor: Equatable, Identifiable {
    let id: CGDirectDisplayID
    let identity: String?
    let name: String
    let frame: CGRect
    var isBuiltIn = false
    var isMirrored = false
```

`refresh()` notifies observers whenever that value differs:

```158:166:eucaly/ProjectionDisplayManager.swift
    func refresh() {
        let fresh = displaySource()
        let previous = displays
        displays = fresh
        rememberMonitors()
        guard previous != displays else { return }
        identifier.close()
        changed()
    }
```

Apple’s screen-parameter notification carries no `userInfo`, so this equality
is eucaly’s entire filter. Waking the coordinator and redrawing the shield are
different effects:

- A same-UUID frame change is the success-path case that calls
  `setFrame(_:display: true)`.
- A runtime-id, localized-name, or `isBuiltIn` change wakes `displaysChanged`
  and `OutputCoordinator.changed()`. When the frame is equal, `reposition`
  skips `setFrame`.
- A missing UUID, duplicate UUID, non-UUID identity, mirror, or zero frame
  fails `resolve` and takes the close path. Those remain destructive.
- A notification whose sorted inventory still compares equal returns inside
  `refresh()` and does not reach the coordinator.

### Success path keeps the window and forces reposition

```892:899:eucaly/Output/OutputCoordinator.swift
        for id in Array(windows.keys) {
            if let target = targets[id], let monitor = displays.resolve(target), windows[id]?.reposition(monitor: monitor) == true { continue }
            ...
            standbySuppressed.insert(id); closeDestination(id); readiness[id] = .displayMissing
        }
        refreshIssues(); changed(); scheduleConfidenceStandby()
```

`continue` requires both `resolve` and `reposition == true`. `reposition`
returns false when `ProjectionScreenResolver.screen(for:)` cannot find that
single unmirrored screen, and that failure closes the destination. When
`reposition` returns true, the window stays open, Current is left alone, and
no disconnect issue is posted. That is the branch that can return without
Show. The failure branch closes the output and suppresses automatic reopening.

### Synchronous observer re-entry

`ProjectionDisplayManager.changed()` invokes observers inline. `lock`,
`unlock`, and `refresh` all call it, and the coordinator observes with
`displaysChanged`.

The re-entry is `unlock` on the close path. `displaysChanged` calls
`closeDestination`, which calls `unlock`, which calls `changed()` and enters
`displaysChanged` again before the outer pass finishes.

`openDestination` calls `lock` only after `open` has returned from `setFrame`.
That `changed()` is the outermost pass. It runs inside `lock`, and it is not a
nested call. A screen-parameter notification does not, by itself, re-enter
from inside `setFrame`.

A guard belongs inside `changed()` and has to finish before `changed()`
returns. `ProjectionDisplayTests` call `refresh()` and require the disconnect
and mirror closes on that same turn (`XCTAssertFalse(session.isPresenting)`
immediately after `refresh()`).

## Why the symptom can match this defect

| Observation | Explanation from this path |
| --- | --- |
| Lyrics and background vanish together | One hosting composition; both layers share `geometry.size` on one black opaque window |
| No eucaly UI change | A screen-parameter notification whose sorted inventory differs, not a presentation command |
| Recovers without Show | Success branch never closes the window. One forced redisplay is a single frame; a burst of unequal frames can keep sampling the black backing until the frames stop changing |
| Background-image / lyrics toggles are not required | Snapshot visibility and profile bookmarks are not mutated on the success path |

## Intended repair

Correctness repair for the forced redisplay. Geometry updates and destructive
invalidation are separate signals; one filter cannot both ignore a new frame
and move the window onto it. One `displayIfNeeded` is a single frame. A
modeset of the projection panel, or an HDMI splitter renegotiating the link,
can blank the picture for about a second without this call. Those incidents
do not confirm or reject the repair.

1. **Close only when the assigned UUID no longer resolves.** Missing,
   duplicated, non-UUID, mirrored, and zero-frame identities take the close
   path. Another display appearing does not. A runtime-id, localized-name, or
   `isBuiltIn` change updates the inventory, leaves the window open, and does
   not call `setFrame` when the frame is unchanged.
2. **Same-UUID frame changes still move the window.** Resolution and
   arrangement change `NSScreen.frame` while the ColorSync UUID stays. Apply
   that frame with `setFrame(_:display: false)` so the window covers the
   monitor without an immediate `displayIfNeeded`. Identify uses
   `display: false` only before `orderFrontRegardless`; that shows the flag
   on a window that is not yet on screen.
3. **Keep delivery synchronous, and stop the `unlock` nest.** `changed()`
   still invokes observers before it returns, so `refresh()` closes a lost
   monitor in the same turn. If a pass is already running, coalesce one
   follow-up and run it after the current pass returns, still before the
   outer `changed()` returns. That stops the close loop from entering
   `displaysChanged` again through `unlock`. The outermost `lock()` pass
   still runs inside `lock`. An asynchronous callback would miss the
   same-turn close `ProjectionDisplayTests` already require.
4. **Keep the hard close path.** Failed resolve still closes that native
   output and suppresses automatic reopening. Audience stays closed until
   Show. Confidence stays closed until Open Confidence, Show, or a new
   assignment or enable.

## Validation

- Same UUID and a changed frame calls `setFrame(_:display: false)`, and the
  window’s frame equals the new monitor frame. It does not call
  `setFrame(_:display: true)`.
- Runtime-id-only, name-only, and `isBuiltIn`-only refreshes leave the window
  open and do not call `setFrame`. Another display appearing also leaves the
  assigned window open.
- Mirror, duplicate UUID, non-UUID identity, zero frame, and a removed UUID
  still close before `refresh()` returns. Reconnect still needs Show.
- `unlock` during an observer pass does not re-enter `displaysChanged` on
  the same stack. The coalesced pass still runs before `changed()` returns.
- Existing `ProjectionDisplayTests` stay as they are: disconnect closes,
  reconnect needs Show, and same-monitor reposition ends on the full monitor
  frame.
- Physical check uses a change that does not modeset the projection panel:
  move that display in Arrangement so only its origin changes, or hot-plug a
  different monitor, and record whether the projection frame changed and
  whether `setFrame` ran. HDR, refresh, and resolution changes blank that
  panel in WindowServer. An HDMI splitter blanks its sinks on link resync
  while macOS still sees one display. Neither result is evidence for this
  defect.

## Related code

- `eucaly/ProjectionDisplayManager.swift`
- `eucaly/ProjectionScreenResolver.swift`
- `eucaly/Output/OutputCoordinator.swift` (`displaysChanged`)
- `eucaly/Output/OutputWindowDestination.swift`
- `eucaly/Output/OutputCompositionView.swift`
- `eucaly/ProjectionMonitorIdentifier.swift` (`display: false` before the window is ordered front)
- `docs/projection-monitors.md`
- `eucalyTests/ProjectionDisplayTests.swift`
