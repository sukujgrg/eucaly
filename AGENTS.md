# eucaly - Agent Guide

## Purpose
`eucaly` is a macOS presentation app for churches and teams that need reliable projection of:
- lyrics (`.txt`)
- PDFs
- images
- videos
- webpages
- captured app windows (live stream)

Primary UX model:
- browse and preview a source item
- explicitly load it into **Current**
- project **Current** to display

Browsing must never silently replace Current. All presentation content follows
Sidebar -> Preview -> Current. ViewTheWord owns its own projection and styling;
eucaly does not receive or re-render its scripture.

## Tech Stack
- SwiftUI (main UI)
- AppKit (windowing, macOS integration)
- AVFoundation and AVKit (video and audio)
- PDFKit (PDF rendering)
- ScreenCaptureKit (window capture)
- Swift, with Sparkle 2.9.6 pinned through Xcode Swift Package Manager for self-updates

## Core Architecture

### Main Entry
- `eucaly/eucalyApp.swift`
  - Native AppKit application entry, menus and app-owned workspace `NSWindowController`s, identified by durable workspace UUIDs
  - `OutputWorkspaceWindows` owns named tabs, detaching, reopening and native state restoration; `NSHostingController` hosts the existing SwiftUI content and toolbar
  - App-owned Manage Workspaces window provides Open, Rename, Make Default and guarded Delete from the Workspace menu and workspace toolbar
  - Native Settings window (`SettingsWindowController`, `GeneralSettingsController`)
  - App command menu and shortcuts

### Releases and Self-Updates
- `VERSION` is the sole marketing-version source (`X.Y` or `X.Y.Z`). An Xcode build phase generates Info.plist in DerivedData for every build; do not restore a separate `MARKETING_VERSION` copy or modify a signed app's plist.
- Keep build/release entry points aligned with ViewTheWord: root `Makefile` and `VERSION`, implementation under `scripts/`. `make build` runs `scripts/build.sh` to archive/export into `~/Applications`; `make release` uses the Python pipeline directly. See the tooling layout in `docs/releasing.md` for the future shared-tooling boundary.
- `make release` runs `scripts/release.py` on the maintainer's Mac: clean source, successful **Validate** push run on `main` for that commit, arm64 archive/export, notarization, signed Sparkle feed, then tag and GitHub publication. Signing credentials remain in local Keychain. See `docs/releasing.md`.
- Preparation is resumable under `build/release/v<VERSION>/`. Preserve `state.json`, `work/`, and saved artifacts. `make clean` preserves releases and respects the shared release lock. Never force tags or overwrite uploaded release assets.
- Only the known legacy GitHub release `v1.32` (ID `383478874`) may bootstrap a missing appcast. Every later release must retain and verify the previous signed feed and advance its build number automatically.
- `AppDelegate` owns one `AppUpdateViewModel`, shared through the SwiftUI environment and app commands. `SparkleUpdateDriver` owns update UI, verification, installation, and relaunch. Scheduled checks show a toolbar reminder without stealing focus; installation requires user action.
- Target Apple Silicon (arm64) only, matching ViewTheWord, in Xcode, local builds, releases, and the appcast. `make build` is the sole local build command. Preserve eucaly's unsandboxed access and macOS 14 minimum; do not copy ViewTheWord's sandbox/XPC settings. Update restarts use normal unsaved-edit confirmation and capture cleanup.
- The update signing key is in Keychain under `com.suku.eucaly`. Only the public key belongs in `eucaly/Info.plist`. Never generate a replacement per release. See `docs/self-updates.md`.
- Validate with `make test` (app plus offline release/feed regressions). GitHub Actions validates only; it does not sign or publish.
- The unit-test host skips normal library/preference restoration and Sparkle startup; tests construct their own views and sessions without loading the maintainer's saved library.

### Main Composition
- `eucaly/ContentView.swift`
  - App-level orchestrator
  - Receives the app-retained workspace `PresentationSession` and `PresentationFlowController`; SwiftUI tab visibility never owns live playback
  - Hosts split view, toolbar controls, selection handling, and sidebar callbacks

### Output Profiles
- AppDelegate owns OutputProfileStore, OutputCoordinator and NDIOutputRouter independently of controls windows. OutputCoordinator owns native destinations, local workspace ownership, snapshots and shared media. There is no incoming presentation receiver or forwarding path.
- Each named workspace owns one Current, Preview flow, accepted snapshot, action clock and program media runtime. Destinations have one durable workspaceID; several outputs share its program playback and different workspaces present simultaneously. Profiles own reusable appearance, never content. New workspaces have no outputs. Native tabs retain editor/Preview/Current; detaching moves the same window. Tab/focus changes never reroute or start output.
- Home is the initial default workspace. The saved default opens after native restoration completes; restored windows remain available and Dock reopen returns to the last controlled workspace. Make Default is a launch preference, independent of the default output for appearance editing, assignments and playback. Preserve operator names; only the former untouched built-in Workspace 1 name becomes Home. Deleting the default selects the first remaining saved workspace.
- Workspace creation is limited to four through one shared creation guard. Existing saved/recovered records above four remain available under the legacy persistence bound; do not trim or reassign them on restore. Keep at least one workspace. Manage Workspaces lists saved identities, assigned outputs (including disabled rows), playback/output status and open/closed controls. Delete is separate from closing a tab: reject any assigned destination or running program/background/audio playback, honor the native unsaved-edit check and revalidate after it. Deletion releases only that workspace's runtime/paused music owner and invalidates queued work without rerouting music or other outputs. Removed workspace restoration and late callbacks cannot revive it. Closing controls continues to preserve Current, live output and background audio.
- Show, live Load/Switch, visible Current navigation, same-slide activation, playback and ordinary Stop operate only on that workspace’s assigned destinations. The output picker shows the saved owner and an explicit Move to This Workspace action; Show never takes another workspace’s output. Preflight transfers before changing ownership. Hide retains its private snapshot; Clear removes foreground only. Assignments survive Hide/Clear/Stop. Stop All Outputs is a distinct global action. Background and audio controls remain independent.
- AppDelegate owns OutputWorkspaceWindows and its native workspace window controllers. SwiftUI content receives an already prepared session and never creates or discovers controls windows. AppKit restores windows by workspace UUID and owns tab groups; detaching moves the same window. Coordinator construction never opens windows. The native workspace didBecomeKey delegate callback permits Confidence standby after the workspace exists; no timer, polling or replacement main window is used. Projection windows can become key, never main, and are excluded from automatic restoration.
- Open Confidence shows a large centered clock when empty, cleared or hidden. Current is on the left and Next on the right, with no source-name header or media filename. Enabled, assigned Confidence opens automatically after the real workspace becomes key or after assignment/enable. Standby never shows a slide, steals focus, takes ownership, starts program media or publishes to NDI. Stop, native close and display loss suppress reopening until Open Confidence/Show or a new assignment/enable. The old Timer/Clock overlay remains removed.
- Per-workspace OutputActionClock order and session cancellation generations invalidate old queued navigation after newer commands, transfer or destination closure without canceling another workspace’s navigation. Native close and outgoing connection callbacks are generation guarded.
- Reservations and teardown are per destination. Losing one retains the others, resources, Current and saved assignments. Reconnection requires explicit Show; never silently move output to a different monitor. Enabled destinations cannot share a monitor or NDI source name. Disabled rows retain assignments without reserving them. Pickers offer None.
- Images, PDFs, video and picked windows use the same native media boundary in every enabled profile. Live webpages require one Audience monitor; companions show a webpage status without additional WebKit playback. Remote-only media, including deferred model refresh, must not replace a valid live lyrics program.
- Each workspace’s OutputMediaRuntime owns one program AVPlayer shared by all its outputs and pools matching muted background resources. Independent workspaces have independent program players that outlive inactive tabs. ScreenCaptureManager owns one picker-approved stream with reference-counted consumers and GPU-backed sample-buffer fan-out. Closing one destination does not stop others. Independent background audio has one explicit session owner.
- AppDelegate owns one native AppKit Settings window shared by the app menu, Manage Outputs toolbar action and inline output notices. General and Manage Outputs use native toolbar tabs. Appearance and backgrounds live in Manage Outputs; thumbnail size and font size use a separate native Thumbnails toolbar menu. Add Native and Add NDI Output create disabled destinations for the controlled workspace. Native monitors are unassigned; generic NDI sources require no receiver assignment. Multiple generic NDI outputs use unique enabled names, with eucaly as the first default source name. Audience, Confidence and Lower Third are locally rendered appearance profiles. NDI output-level edits own independent customized appearances. Lower Third defaults to chroma green. Retired Meaning/Translation presets migrate to Audience while custom copies retain their settings.
- Validate a destination's assignment before enabling it. Conflicting monitor/source-name attempts leave its saved enabled state and assignment unchanged, with an inline settings error. Disabled destinations may retain shared assignments. Output failures use an inline workspace notice with Manage Outputs and Dismiss actions; never show a blocking output-unavailable dialog.
- Manage Outputs uses AppKit list-and-detail navigation, with native controls, colour wells and NSFontPanel. Settings apply immediately; names commit on Return or editing end, with no Save button. The Settings window owns visibility, resizing and close/reopen lifecycle. Disclosure headers are clickable across the full row. Preserve requested fonts during fallback and relative size inheritance when choosing a component font. Pickers preserve duplicate names by UUID. Audience thumbnails use its typeface/layout with independent size controls. Readability notices remain operator-only.
- Output-level Customize Appearance and toolbar edits use an exclusive customized profile, preserving reusable profiles and other outputs, including disabled rows. Direct Profiles-list edits intentionally affect every output using that profile. Import legacy appearance preferences only during migration; sidebar background changes must not reimport appearance.
- Manage Outputs groups reusable profiles, assigned output appearances and unused saved appearances using customization metadata and references, never names. Output pickers offer reusable profiles plus the current appearance. Copying an output appearance creates a reusable profile without reassigning outputs. Remove only unused custom profiles, rechecking disabled destinations too; protect built-ins. Retain legacy names/settings until explicit removal. NDI Transparency explains Alpha/Chroma; its chroma colour well appears only in Chroma mode and uses exclusive output customization. Alpha retains the saved key colour. NDI-only appearance editors direct key-colour edits to the output; native/shared profiles explain the existing colour's native-background/chroma meaning. No schema migration or source restart is needed for this UI organization.
- Saved document version 6 adds durable workspace records and exclusive destination ownership. Existing rows and both legacy NDI sources migrate to Home, retaining UUIDs, source names, appearances, monitors and music choice; both become generic outputs and are never merged. Duplicate enabled legacy names keep the first enabled row by saved order and disable later rows. Preserve the pre-v6 backup; orphaned owners recover as disabled rows in named recovered workspaces. Version-5 retirement still removes AltView/SRT data. No NDI source is automatically added or started. Credential cleanup follows verified persistence, uses only the exact retired eucaly services, has no authentication UI, and retries at most three times off the UI thread. Do not restore incoming reception, scripture components or hub protocol extensions. ViewTheWord's projection and appearance are independent.
- See docs/output-profiles-implementation.md for architecture, verification and physical/profiling limits. Snapshot acceptance does not prove GPU cadence or physical delivery.

### NDI Output
- AppDelegate owns one NDIOutputRouter independently of controls windows. Constructors, restoration, assignment, enabling and appearance edits never load NDI or start helpers. Explicit Start/Show/Retry starts each generic source. There are no Lyrics/Media roles; multiple simultaneous outputs support the same content with globally unique enabled source names.
- Source UUID/name, supervisor, exact helper and receiver connection belong to the app-level destination. Explicit workspace transfer changes accepted content/audio without stopping, renaming or recreating that sender. Content-type changes also retain it. Source name/format edits require a new explicit start after exact-child retirement.
- The toolbar's NDI menu shows the saved owner and moves an existing source directly to any saved workspace's Current, including closed tabs. One source shows NDI: workspace; multiple sources have separate routing submenus, independent of the default appearance-editing output. Menu construction/focus never starts output or prepares closed sessions; explicit moves reuse the same preflight/transfer path, keep stopped/disabled sources stopped and report failed moves inline in the requesting workspace. Revalidate UUIDs for retained menu actions; do not open tabs, rename sources, change appearances/music routing or recreate helpers during routing.
- NDIContentRoute owns a sender-lifetime revision counter and content-owner epoch. Transfer fences staged frames/audio; helper GPU completions and SDK pending/current pictures reject old epochs. Ownership fences close old admission immediately, then acknowledge asynchronously after admitted old-owner audio finishes. Audio fencing never waits behind SDK video work; the SDK video queue coalesces to the latest epoch and retains the previous borrow through the next async send or shutdown flush. Control/Stop remain independent. Acknowledged fences coalesce to the latest admitted epoch; new-owner frames/audio wait for acknowledgement, and queued drains revalidate admission before consuming staged work. Keep CVPixelBuffer ownership through GPU acknowledgement and SDK leases until the next async send/flush. Stop never waits on SDK code in the UI process; confirm exit before retrying a generation.
- A separately installed signed NDI 6.3 runtime is loaded only by the bundled helper. No NDI binary is linked/bundled with the main app. Only the helper has the library-validation exception. Preserve vendor signature checks, private authenticated Mach IPC, exact-process supervision, bounded latest-frame/PCM admission and four output-surface leases. PCM uses a separate private helper port with three blocks in flight; the eight-block bound includes staged and unacknowledged blocks together. Its dedicated reader validates, submits to the SDK and acknowledges serially without control/worker dispatch hops. Stop closes admission and asynchronously waits for accepted audio calls before sender destruction. Audio replies reserve the frame port's fourth slot for one render acknowledgement; ownership/status/shutdown control stays independent. Mach mailboxes explicitly apply the four-message kernel limit. Dedicated blocking readers have independent lifetime contexts and per-message autorelease pools, holding no GCD worker while idle. Cancellation wakes them without waiting and releases the receive right after in-flight handling. Failed sends release Mach's returned copied rights. Live PCM/control/IPC/rendering/submission use user-initiated priority; control/frame readers serialize admission on their owner's queue without accumulating closures. The live helper selects the public default application task category so its windowless AppKit role does not cap the requested user-initiated queues. It claims no foreground or real-time priority. The live app PCM clock and each live helper own latency activities; the helper retains its activity through sender cleanup, independently of the app's system/display sleep policy.
- One generic composition path renders the owning workspace’s cached multilingual SwiftUI lyrics, prepared PDF/image textures and AVPlayerItemVideoOutput from its shared player. The workspace media runtime owns reference-counted samplers per player/item; destinations share acquisition, with independent composition and teardown. Sampler shutdown closes admission immediately and detaches after in-flight reads finish; the main actor never waits for acquisition. Queued decoder failures must match both the current render plan and destination epoch before retiring output. Text has straight alpha and transparent surroundings by default; chroma retains its configured colour. Independent opaque visual backgrounds remain explicit. There is no Audience capture, dummy display, helper AVPlayer, incoming receiver or forwarding path.
- NDI dimming applies only to visual textures. Empty/key frames and fit gutters retain the exact configured chroma colour through Hide, Clear and appearance changes.
- Hide/Clear submit actual replacement empty/key frames. Without an opaque background, cleared pixels are transparent. Clear Current removes foreground/soundtrack but retains independent visuals and music. Clearing visual assets retains the remembered key colour, including in alpha mode.
- Output remains SDR 1920×1080 at 30/1 fps. Metal composes directly into shared Rec.709 studio-range UYVY buffers for a proven opaque canvas or UYVA with full-range straight alpha otherwise. Cached text and prepared images/PDFs remain BGRA; explicitly tagged progressive SDR H.264/HEVC with supported 601/709 matrices and Rec.709 primaries/transfer uses decoder NV12 planes directly, preserving range and chroma location. Untagged, alpha, wide-colour, interlaced, composed and unknown video retains AVFoundation’s BGRA conversion. Opaque media can omit alpha only when it covers the full canvas; unknown opacity and fit gutters retain UYVA. Keep the four buffer/SDK borrow leases, conservative alpha retention, and alpha-weighted shared chroma for transparent glyph edges. Debug-only BGRA comparison and packed-byte tests verify conversion; decoded RGB can vary slightly through 8-bit 4:2:2 quantization. Keep 50/60 fps unavailable until separate gates pass. GPU composition/conversion does not move the SDK codec onto the GPU.
- Unsupported webpage/window content cannot replace a valid NDI-only program. Preflight rejects an unsupported transfer before accepting it; native companions may present it while NDI blanks explicitly. Failure or closure affects only that destination; other workspace outputs, Current and local music remain usable. Failed sources wait for explicit Retry/Show.
- NDI-only program playback remains alive after the last native consumer closes. NDI holds system-sleep prevention; physical windows additionally hold display-sleep prevention. Confidence standby never starts program media or publishes NDI.
- ProgramAudioBus/taps retain preroll, media/host-time mapping, mute and gain. The shared tap retains bounded unplayed PCM with per-mixer delivery cursors so late or restarted outputs do not miss already-decoded audio or duplicate it into existing consumers. Mixer callbacks recover due host-clock blocks in bounded bursts; coalesced timers must not accumulate timestamp lag. Each output keeps its continuous audio clock on transfer; video follows its owning workspace. The single explicit local music owner and saved backgroundAudioDestinationID (Off/nil or one NDI UUID) do not change on transfer. No silent music substitution, duplication or rerouting. Preview, microphone, webpage and system audio are excluded. Audio gaps/overruns retire only the affected source.
- Workspace → Monitor Audio Locally is a persisted per-workspace opt-in for local video/background-music monitoring, defaulting off for new and existing records. NDI-only playback is locally silent from before the first play; native outputs retain normal local audio while open. NDI gain/mute is independent of the player's local output volume. Monitoring never starts outputs, changes ownership/music routing, seeks or recreates players. Stopping/moving the last NDI output must not invent standalone local music playback; explicit standalone music playback without NDI remains available.
- Manage Outputs provides source-name/key/music controls, owner, explicit Move, actual published name, state and Start/Stop/Retry. Both typography and background controls apply to every generic output. Native Settings remain app-owned.
- See docs/output-profiles-implementation.md, docs/ndi-runtime.md and docs/ndi-output-plan.md for migration, architecture, automated evidence and open physical/sustained qualification. SDK submissions, connections and loopback acceptance do not prove receiver display/audio delivery.

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
  - Local Current document, navigation, playback controls, and presentation actions
  - Layer visibility state (`areSlidesVisible`, background visibility)
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

### Webpages
- Webpages are opened from `File > Quick Open...` / the command palette.
- Opening a webpage creates a saved entry in the sidebar Web list and loads the page into **Preview**.
- The sidebar Web list is **saved entries only**; link navigation in Preview or Current does not rewrite sidebar URLs.
- Webpages are live and interactive in both **Preview** and **Current**.
- Navigation inside Preview updates Preview slides only and must not silently rebuild Current.
- Navigation inside Current updates Current/runtime state (`session.slides`, projection) only and must not silently rebuild Preview.
- Preview, Current, and projection share the same webpage navigation model: slide `webpageURL` plus `webpageNavigationRevision`, updated via `WebpageSlideCatalog` helpers in `WebpageNavigation.swift`.
- Projection recreates its read-only webpage view from `webpageNavigationRevision`; Preview and Current keep a persistent interactive `WKWebView` and update through `updateNSView`.
- Sidebar Web list entries are saved bookmarks only; live navigated URLs are tracked in Preview/Current slides, not by rewriting sidebar rows.
- Preview webpage mute is local to Preview.
- Current webpage mute is session-level (`session.webpageMuted`) and affects Current plus projection.

### Projection
- Toolbar and menu control slide visibility separately from background layer visibility.
- ESC hides slides.
- Projection can remain active while slides are hidden.
- `OutputCoordinator` holds one `ProjectionSleepPrevention` activity while any physical projection window (including a standby clock) is open, preventing idle system and display sleep. Hide Slides, Clear Current, and background/layer changes retain it. Stop Projection, native window close, display-loss shutdown, and teardown release it; browsing, naming, Identify, audio alone, and failed projection starts do not acquire it.
- Background and audio are independent from slides visibility.
- Projection target display is user-selectable from the toolbar (`display` menu).
- `ProjectionDisplayManager` is shared by the toolbar, Manage Outputs, and sessions. Assignments, monitor numbers, and custom names are persisted by macOS display UUID; the old `projectionScreenDisplayID` preference is migrated once.
- Identify briefly labels an idle monitor without changing Current or opening projection. Stop projection before selecting another monitor.
- Projection requires an explicitly selected monitor; there is no Auto selection or fallback. A previous Auto preference becomes unassigned and requires a choice. Each active projection pins the selected physical identity. Disconnect, mirroring, or ambiguous identity closes projection immediately, retaining Current, audio, names, and the saved assignment; reconnect requires an explicit Show Slides. Never silently move output to another monitor.

### Keyboard Shortcuts (Current)
- `Cmd+T`: New Workspace Tab
- `Cmd+1`: Stop Workspace Outputs (retain that workspace’s Current and assignments)
- Stop All Outputs: explicit global Slides-menu action, without a shortcut
- `Cmd+2`: Show/Hide Slides
- `Cmd+3`: Clear Background Visual
- `Cmd+4`: Clear Background Audio
- `Cmd+5`: Clear All Layers (hide slides + clear visual/audio)
- ESC: Hide Slides only (does not stop projection, does not clear background/audio)

### Layer Model
Order in projection:
1. Background visual layer
2. Slides layer (lyrics/PDF/image/video/window)

Projection layout rule:
- Pin each projection layer to the same explicit full-screen geometry frame.
- Do not rely on implicit `ZStack` sizing for media-backed layers (`AVPlayerView`, `PDFView`, capture views).
- This prevents background visuals from influencing slide vertical positioning (historical "slides pushed downward" regression).

Projection screen rule:
- All projection entry points must resolve target display through the same selection source.
- Do not hardcode screen selection (`NSScreen.screens[1]`) in call sites.

### Confidence Standby Clock
- An open Confidence output with no visible text or media always shows a large centered clock.
- Enabled, assigned Confidence opens its clock before the first slide at startup or after explicit assignment/enable.
- This clock is local to Confidence and does not change ownership, Current, NDI output or session presentation state.
- Stop, Close Confidence and monitor loss retain an explicit closed state; Open Confidence or Show Slides resumes output on the saved physical identity.
- The old optional Timer/Clock overlay and countdown controls have been removed.

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
  - Picker updates are the source of truth for selectable windows. Only the controlled workspace accepts a picker selection into Preview.
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
- Capture consumers attach when a window slide appears and detach when it disappears. The shared source stream stops after its last consumer releases it.
- Destination/session teardown releases its own consumers; app shutdown stops all active captures.
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
- Lyrics layout: `eucaly/PresentationLyricsLayout.swift`, `eucaly/LyricsSlideContentView.swift`
  - Manage Outputs offers Stacked / Columns plus Top / Middle / Bottom positioning.
  - Lyrics Padding scales outer margins and component gaps in both layouts, from 0% (full slide) to 200%; 100% preserves the default spacing. The saved setting also applies to Preview and Current thumbnails.
  - Columns group existing lyric components (lyrics, meaning, translation, transliteration); missing components do not reserve space.
  - Column widths follow relative font sizes: Meaning gets half the width of each full-size component (40% / 20% / 40% for lyrics / meaning / transliteration, after margins and gaps). A single component always uses the full available width.
  - Preview and Current thumbnails share the projection text layout. SwiftUI measures and fits its own text, including multilingual fallback fonts.
  - Manage Outputs owns per-profile layout and projection fonts; the separate Thumbnails toolbar menu owns thumbnail controls. Projection and thumbnail font sizes remain independent.
  - Preview and Current lyrics cards show an advisory when a component cannot fit at 32 projection points, or its requested font is smaller. The check uses the selected display's full frame, shared layout geometry, and SwiftUI font metrics. It does not guarantee readability at every viewing distance. Keep the full text fitting behavior; never silently truncate, change layout, or project operator warnings.
  - The advisory is a visible status row and is included in the card button's accessibility value. Suggest increasing Projection Font Size only for components that fit at the threshold; overflow needs more space or shorter content. Apply measured status outside the layout update and reserve no warning space on unaffected cards.
- Media slide views:
  - `eucaly/ImageSlideView.swift`
  - `eucaly/PresentationWindowController.swift` (`VideoSlideView`, `PDFSlideView`)
  - `eucaly/WindowCaptureSlideView.swift`
- Capture:
  - `eucaly/ScreenCaptureManager.swift`
- Search:
  - See `SEARCH.md` for query behavior, indexing rules, and implementation details.
- Webpages:
  - `eucaly/PresentationWindowController.swift` (`WebpageViewRepresentable`, `WebpageSlideView`)
  - `eucaly/PreviewPaneContainerView.swift`
  - `eucaly/CurrentPaneContainerView.swift`

### Parser and Domain Models
- Pure parser/domain-model code should remain actor-independent (`nonisolated`) when it has no UI, AppKit, SwiftUI state, `@Published`, or shared mutable state.
- Do not duplicate parser rules in UI/search/runtime code. Reuse `LyricsParser` and `LyricsSectionCatalog`.
- If parser/domain code later needs main-thread-only APIs or observable state, isolate only that new UI-facing layer instead of moving parsing back onto `MainActor`.

## Caching
- `eucaly/CacheManager.swift`
  - `@MainActor`, singleton
  - Memory and disk thumbnail caches
  - File-change invalidation
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
- Debounce rapid user-driven state writes (audio sliders and similar).

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
- Very aggressive scrolling through large sidebar libraries can expose SwiftUI `LazyVStack` limits. If this becomes a real workflow issue, prefer a scoped native `NSOutlineView`/`NSTableView` wrapper for the library list over piling on more `LazyVStack` caching or row micro-optimizations.

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
  - Verify selected UUID resolves uniquely after hot-plug/unplug, including reused runtime IDs and identical monitor names.
  - Keep disconnected assignments; never clear them or silently use another screen. An unassigned destination must block projection until the user chooses a monitor.
  - Verify screen-parameter changes close unavailable/mirrored/ambiguous output immediately and reposition only the same physical identity.
- Capture issues
  - Check picker selection state (`ScreenCaptureManager.shared.windows`).
  - Check permission grant state after explicit picker invocation.
  - Check target window still exists.

## Change Checklist
When changing behavior, verify:
- Lyrics/PDF/Image/Video/Webpage/Window all load into Preview.
- Preview does not implicitly overwrite Current.
- Load to Current works identically across media types.
- Projection renders its destination’s assigned workspace Current; browsing, tab/focus changes and passive preparation stay private.
- Simultaneous workspace programs remain independent; a live NDI transfer retains source identity/helper/connection and rejects prior-owner work.
- Ordinary controls affect their workspace; Stop All Outputs is explicitly global.
- Migration/restoration preserve names/IDs/appearances/music and never auto-start NDI.
- Webpage navigation in Current updates Current/runtime state and projection without forcing Preview to reload.
- Webpage navigation in Preview updates Preview only and does not rewrite sidebar saved entries.
- Webpage mute affects Preview, Current, and projection consistently.
- Background visual/audio remain independent from slides visibility.
- Projection display picker selects the correct monitor across start/toggle/background actions.
- Display unplug/hot-plug closes invalid output and keeps the chosen identity; reconnect and a new Show Slides use that identity even with a new runtime ID.
- Confidence shows its centered standby clock when empty, cleared or hidden, and other profiles have no Timer/Clock overlay.
- No new SwiftUI publish-during-update warnings.
- No stale capture streams after slide/session teardown.

## Keyboard Navigation (Current Pane)
- Current pane focus is local to `CurrentPaneContainerView`.
- Arrow keys move selection via `session.moveSelection(delta)` and that workspace’s action clock.
- Projection-window commands resolve its workspace by destination ID; focus never transfers assignments.
- Focus state must not become a second selection source of truth.
