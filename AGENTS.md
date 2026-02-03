# eucaly - Agent Guide

## Purpose
`eucaly` is a macOS presentation app for churches and teams that need reliable projection of:
- lyrics (`.txt`)
- PDFs
- images
- videos
- captured app windows (live stream)

Primary UX model:
- browse and preview a source item
- explicitly load it into **Current**
- project **Current** to display

Browsing must never silently replace Current.

## Tech Stack
- SwiftUI (main UI)
- AppKit (windowing, macOS integration)
- AVFoundation and AVKit (video and audio)
- PDFKit (PDF rendering)
- ScreenCaptureKit (window capture)
- Pure Swift (no third-party packages)

## Core Architecture

### Main Entry
- `eucaly/eucalyApp.swift`
  - Main `WindowGroup`
  - Settings scene (`AppSettingsView`)
  - App command menu and shortcuts

### Main Composition
- `eucaly/ContentView.swift`
  - App-level orchestrator
  - Owns:
    - `@StateObject var session = PresentationSession()`
    - `@StateObject var flow = PresentationFlowController()`
  - Hosts split view, toolbar controls, selection handling, and sidebar callbacks

### Pane Containers
- `eucaly/EditorPaneContainerView.swift`
- `eucaly/PreviewPaneContainerView.swift`
- `eucaly/CurrentPaneContainerView.swift`
- `eucaly/DetailRootView.swift`

These isolate rendering concerns from orchestration.

### Flow Controller
- `eucaly/PresentationFlowController.swift`
  - Source of truth for Preview document state
  - Moves Preview -> Current (`movePreviewToCurrent`)
  - Current collapse/selection behavior
  - Slide visibility toggling rules

### Presentation Runtime
- `eucaly/PresentationWindowController.swift`
  - `PresentationSession`
  - Projection window lifecycle
  - Layer visibility state (`areSlidesVisible`, background visibility, overlay)
  - Media playback controls
  - Window-capture slide support

## Media Flow Contract (Required)

This is the mandatory pattern for every existing and future media type.

1. Sidebar selection updates Preview only.
2. Preview selection is user-facing, but does not mutate Current.
3. Current changes only via explicit user action:
   - `Load to Current` / `Switch Current`
   - `Clear`
4. Projection renders Current only.
5. If a type needs special runtime handling (streaming, async, permissions), this must be an implementation detail. It must still follow the same Sidebar -> Preview -> Current contract.
6. Any new type must integrate with:
   - sidebar selection model (`SidebarSelection`)
   - preview slide construction
   - `flow.movePreviewToCurrent`
   - current-pane thumbnails
   - projection slides layer

If a new type cannot follow this contract, treat it as a design bug and refactor before adding more behavior.

## Current UX and Behavior

### Preview vs Current
- Selecting files updates **Preview** only.
- **Current** changes only when user clicks:
  - `Load to Current` (or `Switch Current` while presenting)
  - `Clear`
- Clear can run while projecting; it clears Current without implicitly restoring Preview.

### Projection
- Toolbar and menu control slide visibility separately from background layer visibility.
- ESC hides slides.
- Projection can remain active while slides are hidden.
- Background and audio are independent from slides visibility.
- Projection target display is user-selectable from the toolbar (`display` menu).
- Display selection is persisted (`projectionScreenDisplayID`) with `Auto` fallback behavior.

### Keyboard Shortcuts (Current)
- `Cmd+1`: Stop Projection (close projection window and reclaim display)
- `Cmd+2`: Show/Hide Slides
- `Cmd+3`: Clear Background Visual
- `Cmd+4`: Clear Background Audio
- `Cmd+5`: Clear All Layers (hide slides + clear visual/audio)
- ESC: Hide Slides only (does not stop projection, does not clear background/audio)

### Layer Model
Order in projection:
1. Background visual layer
2. Slides layer (lyrics/PDF/image/video/window)
3. Timer/clock overlay layer

Projection layout rule:
- Pin each projection layer to the same explicit full-screen geometry frame.
- Do not rely on implicit `ZStack` sizing for media-backed layers (`AVPlayerView`, `PDFView`, capture views).
- This prevents background visuals from influencing slide vertical positioning (historical "slides pushed downward" regression).

Projection screen rule:
- All projection entry points must resolve target display through the same selection source.
- Do not hardcode screen selection (`NSScreen.screens[1]`) in call sites.

### Timer / Clock Overlay
- Sidebar controls are always available.
- Overlay renders on projection and in Current thumbnails.
- Overlay is fixed top-right with consistent padding.
- Overlay writes are debounced and deferred to avoid publish-during-update issues.

## Window Capture Support (Authoritative)

This section supersedes older window-capture docs.

### Scope
Window capture supports live streaming of a user-picked app window into a slide.

### Data Model
- `eucaly/Models.swift`
  - `Slide.captureWindowID: CGWindowID?`
  - Non-window slides set this to `nil`.

### Source Selection (System Picker)
- `eucaly/ScreenCaptureManager.swift`
  - Uses `SCContentSharingPicker` in `.window` mode.
  - `maximumStreamCount = 1`.
  - Maintains selected windows in `@Published var windows: [CapturedWindow]`.
  - Picker updates are the source of truth for selectable windows.
- No persisted allowlist model is used.

### Permission Behavior
- Screen recording permission must be requested lazily from explicit user action only.
- Do not trigger screen-capture permission prompts during app launch.
- Permission prompts are expected only after user clicks `Pick Window...`.

### Window Enumeration and Capture
- `eucaly/ScreenCaptureManager.swift`
  - Picker observer updates selected windows.
  - `windows: [CapturedWindow]`
  - `startCapture(windowID:outputHandler:)`
  - `stopCapture(windowID:)`
  - `stopAllCaptures()`

### Sidebar Behavior
- `eucaly/SidebarView.swift`
  - Windows section is list-oriented.
  - `Pick Window...` appears as a row-styled action.
  - Picked windows appear as selectable rows (`SidebarSelection.window(windowID)`).

### Preview Behavior
- `eucaly/ContentView.swift`
  - Selecting a picked window maps to `SidebarSelection.window(windowID)`
  - Loads window preview via `loadWindowPreview`
  - Builds standard preview slides with `Slide.captureWindowID`.

### Load to Current
- Must use the same preview-to-current path as other media:
  - preview slides built in flow
  - `handleLoadPreviewToCurrent` -> `flow.movePreviewToCurrent(...)`
- Window type must not bypass this contract.

### Projection Rendering
- `eucaly/PresentationWindowController.swift` slides layer:
  - if `slide.captureWindowID != nil`, render `WindowCaptureSlideView`
  - otherwise render video/pdf/image/lyrics branch
- `isLyricsSlide` must continue excluding window slides.

### Lifecycle and Cleanup
- Capture starts when window slide appears and stops when it disappears.
- Session teardown must stop all active captures.
- Missing window or permission failure must degrade gracefully (error state, no crash).

### Known Design Constraint
- Current mode is single selected stream from the system picker (`maximumStreamCount = 1`).
- If multi-window support is introduced later, it must still honor the same media flow contract and explicit selection semantics.

## Background Visual and Audio

### Visual
- Selected via sidebar.
- Used as background layer.
- Applies only to lyrics slides (or when slides are hidden).
- Hidden/visible state is independent from slide visibility.

### Audio
- Selected via sidebar.
- Independent from slides visibility.
- Playback state is explicit (play/pause/stop/loop, volume).

## Data and Rendering Files
- Models: `eucaly/Models.swift`
- Parser: `eucaly/LyricsParser.swift`
- Grid layout: `eucaly/ThumbnailGridLayout.swift`
- Grid cell: `eucaly/SlideGridCellView.swift`
- Media slide views:
  - `eucaly/ImageSlideView.swift`
  - `eucaly/PresentationWindowController.swift` (`VideoSlideView`, `PDFSlideView`)
  - `eucaly/WindowCaptureSlideView.swift`
- Capture:
  - `eucaly/ScreenCaptureManager.swift`
- Search:
  - See `/Users/suku/Swift/eucaly/SEARCH.md` for query behavior, indexing rules, and implementation details.

## Caching
- `eucaly/CacheManager.swift`
  - `@MainActor`, singleton
  - Memory and disk thumbnail caches
  - File-change invalidation
  - Font calculation cache
  - startup cleanup and manual clear action

## Filesystem Model
- Library root is user-configurable and persisted.
- Security-scoped bookmarks are used for out-of-container folders.
- Playlist is persisted under library root:
  - `<LibraryRoot>/Playlist/playlist.json`
  - root-relative paths + stable IDs + explicit order

## Sandbox Access Pattern (macOS)
- Do not assume system-folder APIs return real user folders inside sandbox.
- Use `NSOpenPanel` + security-scoped bookmark + restore on launch.
- This applies to:
  - library root
  - downloads
  - background visual/audio file access

## UI and HIG Rules

### Accent and Theming
- Respect system accent color.
- Do not hardcode accent blue for app branding controls.
- Use the existing accent provider fallback for macOS 14 recursion issues.

### Window and Materials
- Keep unified toolbar style in app entry.
- Apply toolbar background visibility only where supported.
- Use native materials and controls over custom heavy styling.

### Sidebar and Controls
- Sidebar should use list-row style consistency (sizing, spacing, selection appearance).
- Primary actions should use shared styling helpers where paired.
- Keep section headers and helper text hierarchy consistent.

## Engineering Rules

### 1) Prefer correct design over patch-on-patch
- Avoid layered quick fixes on brittle paths.
- If ownership/flow is unclear, refactor or rewrite the affected area.
- Rewrite is preferred over patch-over-patch when stability is at risk.
- Rewrites must stay scoped to root-cause boundaries.

### 2) Fix root cause, not symptoms
- Crashes, runtime warnings, and state races must be solved at source.
- Do not hide state-model issues with workaround chains.

### 3) SwiftUI state safety
- Never publish observable changes while the view tree is being evaluated.
- Defer lifecycle-edge writes to a safe boundary on main queue when required.
- Debounce rapid user-driven state writes (overlay/audio sliders and similar).

### 4) Keep boundaries clean
- `ContentView` orchestrates.
- Container views render.
- `PresentationFlowController` handles preview/current flow.
- `PresentationSession` handles projection runtime.

### 5) Remove dead or duplicate logic
- Remove stale paths after refactors.
- Do not leave parallel legacy branches.

### 6) Performance discipline
- Extract heavy subtrees into focused views.
- Narrow bindings and callback surfaces to reduce `body` recomputation.
- Keep sidebar lists stable and driven by minimal inputs.

### 7) Keyboard shortcut collision safety
- Any new shortcut must be checked against standard macOS text-editing bindings before merge.
- Do not override core editing shortcuts (`Cmd+X`, `Cmd+C`, `Cmd+V`, `Cmd+Z`, `Cmd+A`, etc.) for app commands.
- Prefer non-colliding command menu shortcuts and validate behavior inside active text fields.

## Debugging Notes
- `Publishing changes from within view updates...`
  - Means state mutation during update cycle; move to safe deferred boundary.
- Projection layout issues
  - Validate explicit sizing in projection stack.
  - Validate layer order and per-media aspect rules.
  - Ensure background/media layers are frame-pinned so they cannot affect slide-layer layout.
  - Test with and without background visual enabled.
- Projection screen issues
  - Verify selected display exists after hot-plug/unplug.
  - Ensure stale display preference is cleared back to `Auto`.
  - Verify screen-parameter-change handling repositions projection window safely.
- Capture issues
  - Check picker selection state (`ScreenCaptureManager.shared.windows`).
  - Check permission grant state after explicit picker invocation.
  - Check target window still exists.

## Change Checklist
When changing behavior, verify:
- Lyrics/PDF/Image/Video/Window all load into Preview.
- Preview does not implicitly overwrite Current.
- Load to Current works identically across media types.
- Projection only renders Current.
- Background visual/audio remain independent from slides visibility.
- Projection display picker selects the correct monitor across start/toggle/background actions.
- Display unplug/hot-plug does not leave projection on an invalid screen.
- Timer/clock controls and rendering still work.
- No new SwiftUI publish-during-update warnings.
- No stale capture streams after slide/session teardown.

## Keyboard Navigation (Current Pane)
- Current pane focus is local to `CurrentPaneContainerView`.
- Arrow keys move selection via `session.moveSelection(delta)`.
- Focus state must not become a second selection source of truth.
