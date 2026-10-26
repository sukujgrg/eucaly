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

Browsing must never silently replace Current. All presentation content follows
Sidebar -> Preview -> Current. ViewTheWord owns its own projection and styling;
eucaly does not receive or re-render its scripture.

## Subagent Delegation

Use the project specialists automatically for substantial work when delegation
improves investigation, implementation or review. The user does not need to ask
for subagents each time. Use the smallest relevant set; handle simple, local
fixes and straightforward questions directly.

| Agent | Delegate when the task concerns |
| --- | --- |
| [presentation_core](.codex/agents/presentation_core.toml) | Preview/Current flow, workspace state, output ownership and transfers, persistence/migration, native monitor identity and projection/Confidence lifecycle. |
| [media_engine](.codex/agents/media_engine.toml) | Shared playback, audio clocks/routing, backgrounds, capture, media preparation, rendering and resource lifetimes. |
| [ndi_transport](.codex/agents/ndi_transport.toml) | NDI helper/SDK integration, Mach IPC, frame/audio admission, ownership fences, packed video and sender continuity. |
| [library_editing](.codex/agents/library_editing.toml) | Library discovery/import, search/indexing, lyrics parsing/editing, playlists, file access and thumbnail cache invalidation. |
| [macos_interface](.codex/agents/macos_interface.toml) | Settings, menu bar and top-right toolbar controls, controls windows/tabs, pane/sidebar interaction, accessibility and keyboard UX. |
| [independent_reviewer](.codex/agents/independent_reviewer.toml) | Independent review of an integrated change for concrete regressions, races, missing validation and contract violations. Does not edit files. |

### Coordinator responsibilities
- Keep the main agent as the user's contact and integration owner. It scopes the
  task, assigns work, resolves decisions across domains and verifies the result.
- Read the role definition before dispatching it. Give each handoff the objective,
  user constraints, explicit write ownership (or read-only scope), dependencies
  and acceptance/validation criteria from the Shared Completion Contract below.
- Prefer the named custom agent when the client supports role selection. If its
  spawn interface cannot select custom roles, include the role's full
  `developer_instructions` in the delegated task. A task name alone does not load
  a role. If delegation is unavailable, do the work in the main agent and state
  that limitation when material.
- Parallelize independent exploration and review. Parallel implementation needs
  disjoint write ownership; serialize edits to shared files such as
  `ContentView.swift`, `eucalyApp.swift`, `PresentationWindowController.swift` and
  `OutputCoordinator.swift`. A specialist's file map is a starting point, not a
  permanent lock. Coordinate boundary changes before editing another assignment.
- Bring in `presentation_core` for output/workspace ownership changes,
  `media_engine` for shared playback/lifetime changes and `ndi_transport` for
  sender/IPC changes, even when the visible change begins in a menu or Settings.
  Bring in `macos_interface` for substantial operator-interaction changes,
  including those caused by backend work. Consultations may be read-only and
  can run in phases; do not add every specialist to every task.
- Request `independent_reviewer` after integrating substantial behavior changes,
  concurrency/lifecycle changes, persistence migrations or delegation-policy
  changes. Provide the objective, changed files/diff and completion evidence.
- Keep one owner for full builds/tests; coordinate scoped checks to avoid
  duplicate concurrent Xcode runs. Use the validation commands in the contract.
- Respect the active client's concurrency limit and use batches when needed.
  Specialists execute their assigned task without recursively redispatching it;
  further subagents require an explicit delegation assignment from the parent.
- Models, reasoning and permissions inherit from the parent unless the user
  requests a change. Review-only instructions are a working constraint, not a
  separate sandbox. Keep durable knowledge in repository docs and tests, and
  reference existing architecture guidance instead of duplicating it in roles.

All specialists preserve the media-flow, workspace-isolation and explicit-output
contracts below, and assess UX effects within their task. Release/update work
stays with the coordinator, using the existing release and self-update guides;
add specialist assistance only when the task warrants it.

## Shared Completion Contract

This contract applies to the coordinator and all six roles. Scale it to the risk
and assigned scope; a small local edit does not need a broad refactor, new tests
or extra agents. Review-only agents return findings without making changes.

1. **Define acceptance.** For behavior changes, describe the starting state,
   operator action, expected result and state that must remain intact. Identify
   affected ownership/lifetime boundaries and the checks that will establish
   the result. Apply the relevant Change Checklist items below; shared media or
   flow changes need coverage across all affected media types and workspaces.
2. **Explain the repair.** Trace the actual state owner and failure or design
   decision. Apply the Engineering Rules below: make the smallest coherent
   root-cause repair and remove superseded logic. Justify new retries, delays,
   fallbacks or state flags by the behavior they model. Do not mask failures by
   swallowing errors, suppressing diagnostics or weakening checks to pass.
3. **Verify the behavior.** For substantial bugs, establish a concrete
   reproduction and, when practical, a regression that fails before the repair
   and passes afterward. Exercise affected failure, cancellation, stale-callback,
   retry and teardown paths. Prefer controlled ordering for race regressions over
   timing sleeps. Use isolated fixtures, never the operator's library, preferences
   or live output. Avoid tests that merely mirror implementation details.
4. **Check the operator workflow.** For material interaction changes, verify the
   affected keyboard navigation, text editing, focus return, menu/toolbar state,
   resizing, accessibility interaction and error recovery. Use existing native
   tests and targeted UI observation when relevant and available within scope;
   labels or screenshots alone do not establish usable interaction.
   AppKit migrations should adopt appropriate native selection, disclosure and
   responder behavior; limitations of the previous UI are not acceptance criteria.
5. **Validate and review the integrated result.** Use `make build` for local app
   builds and `make test` for app regressions. For changes confined to agent
   instructions/configuration and their validator, use `make test-codex-agents`
   to check TOML, references and contract wiring instead of building the app.
   Static checks do not prove live delegation: discovery/dispatch smoke checks,
   when assigned, need a current Codex client (use the desktop app's bundled
   client when PATH lags). Resolve actionable independent-review findings and
   repeat affected checks after repairs. The coordinator owns final integration;
   a specialist's completed handoff does not establish whole-task completion.
6. **Report evidence.** Return the cause/decision, files changed or referenced,
   checks actually run with results and skips, review findings/resolution, and
   remaining risks or cross-domain work. Reviewers report actionable findings
   first. Distinguish automated, native-observed, runtime/loopback and physical
   evidence; never claim unobserved results or treat skipped checks as passes.
   Run optional stress, hardware and production-qualification work only when
   assigned; record relevant gaps without expanding unrelated development into
   a qualification campaign. See the existing qualification documents below.

Read only the architecture sections relevant to the task. This guide's contracts
and the current implementation resolve older plan descriptions; report conflicts
with the requested behavior rather than treating existing code as proof of
correctness. Keep shared process here and domain-specific checks in the roles.

## Tech Stack
- Apple Silicon Macs running macOS 26 or later
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
  - `OutputWorkspaceWindows` owns retained workspace controls, in-place switching, explicit separate windows, reopening and native state restoration; `NSHostingController` retains each workspace’s SwiftUI content
  - AppKit Workspaces tab in the shared Settings window provides coloured workspace identities, Open, Rename and guarded Delete; the Workspace menu and pinned sidebar Workspaces action open that tab
  - Sidebar and menu-bar Workspace menus share native construction and validation. Management actions are separated final rows, including Output/NDI/Appearance/Background quick menus. Workspace renaming shares one native sheet and name validator with Settings. Open in New Window reuses an already visible workspace; native window tabbing is disabled.
  - Native Settings window (`SettingsWindowController`, `GeneralSettingsController`)
  - App command menu and shortcuts

### Releases and Self-Updates
- `VERSION` is the sole marketing-version source (`X.Y` or `X.Y.Z`). An Xcode build phase generates Info.plist in DerivedData for every build; do not restore a separate `MARKETING_VERSION` copy or modify a signed app's plist.
- Keep build/release entry points aligned with ViewTheWord: root `Makefile` and `VERSION`, implementation under `scripts/`. `make build` runs `scripts/build.sh` to archive/export into `~/Applications`; `make release` uses the Python pipeline directly. See the tooling layout in `docs/releasing.md` for the future shared-tooling boundary.
- `make release` runs `scripts/release.py` on the maintainer's Mac: clean source, successful **Validate** push run on `main` for that commit, arm64 archive/export, notarization, signed Sparkle feed, then tag and GitHub publication. Signing credentials remain in local Keychain. See `docs/releasing.md`.
- Preparation is resumable under `build/release/v<VERSION>/`. Preserve `state.json`, `work/`, and saved artifacts. `make clean` preserves releases and respects the shared release lock. Never force tags or overwrite uploaded release assets.
- Only the known legacy GitHub release `v1.32` (ID `383478874`) may bootstrap a missing appcast. Every later release must retain and verify the previous signed feed and advance its build number automatically.
- `AppDelegate` owns one `AppUpdateViewModel`, shared through the SwiftUI environment and app commands. `SparkleUpdateDriver` owns update UI, verification, installation, and relaunch. Scheduled checks show a toolbar reminder without stealing focus; installation requires user action.
- Target Apple Silicon (arm64) only, matching ViewTheWord, in Xcode, local builds, releases, and the appcast. `make build` is the sole local build command. Preserve eucaly's unsandboxed access and macOS 26 minimum; do not copy ViewTheWord's sandbox/XPC settings. Update restarts use normal unsaved-edit confirmation and capture cleanup.
- The update signing key is in Keychain under `com.suku.eucaly`. Only the public key belongs in `eucaly/Info.plist`. Never generate a replacement per release. See `docs/self-updates.md`.
- Validate with `make test` (app plus offline release/feed regressions). GitHub Actions validates only; it does not sign or publish.
- The unit-test host skips normal library/preference restoration and Sparkle startup; tests construct their own views and sessions without loading the maintainer's saved library.

### Main Composition
- `eucaly/ContentView.swift`
  - App-level orchestrator
  - Receives the app-retained workspace `PresentationSession` and `PresentationFlowController`; SwiftUI tab visibility never owns live playback
  - Hosts split view, toolbar controls, selection handling, and sidebar callbacks

### Native Sidebar
- `eucaly/SidebarView.swift` is the thin host bridge from the SwiftUI workspace.
- `eucaly/SidebarViewController.swift` owns AppKit sidebar layout, section
  disclosure, controls, menus, sliders and UI subscriptions.
- `eucaly/SidebarOutlineView.swift` owns the shared native outline behavior,
  selection approval, expansion and keyboard traversal.
- Apply incoming state without invoking user actions or binding setters. Keep
  selection reconciliation in its workspace owner. Dismantling releases UI work
  only; closing controls must preserve the app-owned presentation runtime.
- Size native lists from their content, including source-list edge space. Hidden
  section contents must not receive keyboard selection; visible headers remain
  reachable for expansion.
- Arrow navigation reaches visible sections, groups and items. Right expands or
  enters a container; Left collapses or returns to its parent. Container focus
  preserves Preview/Current, and passive updates preserve that focus and expansion.
  Leaf selection still requires the workspace's normal selection approval.

### Output Profiles
- AppDelegate owns OutputProfileStore, OutputCoordinator and NetworkOutputRouter independently of controls windows. OutputCoordinator owns native destinations, local workspace ownership, snapshots and shared media. There is no incoming presentation receiver or forwarding path.
- Each named workspace owns one Current, Preview flow, accepted snapshot, action clock and program media runtime. Destinations have one durable workspaceID; several outputs share its program playback and different workspaces present simultaneously. Profiles own reusable appearance, never content. New workspaces have no outputs. Workspace controls retain their hosting controller, editor draft, selection and focus while parked. The Workspaces selector replaces controls in the same native window; Open in New Window explicitly presents parked/closed controls separately and focuses an existing visible owner. Switching never reroutes output.
- Home is the initial workspace. AppKit restores previous independent windows, selected workspace identities, minimization and geometry; launch never opens or selects another workspace when any controls window was restored. With nothing restored, reopen the saved last-used workspace, falling back to an existing workspace if its identity was deleted. Dock reopen prefers existing controls and otherwise the saved last-used workspace. Each workspace UUID has a native frame autosave name; closing and reopening controls preserves its size and position. There is no default-workspace preference. Preserve operator names and legacy identities; retire the former launch preference and obsolete SwiftUI window-frame keys without changing content or output assignments.
- Workspace creation is limited to four through one shared creation guard. Existing saved/recovered records above four remain available under the legacy persistence bound; do not trim or reassign them on restore. Keep at least one workspace. Manage Workspaces lists saved identities, assigned outputs (including disabled rows), playback/output status and open/closed controls. Delete is separate from closing controls: reject any assigned destination or running program/background/audio playback, honor the native unsaved-edit check and revalidate after it. Deletion releases only that workspace's runtime/paused music owner and invalidates queued work without rerouting music or other outputs. Removed workspace restoration and late callbacks cannot revive it. Closing controls continues to preserve Current, live output and background audio.
- Show, live Load/Switch, visible Current navigation, same-slide activation, playback and ordinary Stop operate only on that workspace’s assigned destinations. The output picker shows the saved owner and an explicit Move to This Workspace action; Show never takes another workspace’s output. Preflight transfers before changing ownership. Hide retains its private snapshot; Clear removes foreground only. Assignments survive Hide/Clear/Stop. Stop All Outputs is a distinct global action. Background and audio controls remain independent.
- AppDelegate owns OutputWorkspaceWindows and its native workspace window controllers. SwiftUI content receives an already prepared session and never creates or discovers controls windows. AppKit restores non-tabbable windows by their selected workspace UUID. Normal switching preserves the physical window’s geometry and never tears down the parked controls. Closing releases the visible controls only; Quit reveals and confirms every retained draft, including parked controls, then restores pre-quit selections before successful native restoration capture. Coordinator construction never opens windows. Native key activation or an explicit switch within the key controls window permits Confidence standby after the workspace exists; no timer, polling or replacement main window is used. Projection windows can become key, never main, and are excluded from automatic restoration.
- Confidence output follows [Confidence Standby Clock](#confidence-standby-clock) below.
- Per-workspace OutputActionClock order and session cancellation generations invalidate old queued navigation after newer commands, transfer or destination closure without canceling another workspace’s navigation. Native close and outgoing connection callbacks are generation guarded.
- Reservations and teardown are per destination. Losing one retains the others, resources, Current and saved assignments. Reconnection requires explicit Show; never silently move output to a different monitor. Enabled destinations cannot share a monitor or NDI source name. Disabled rows retain assignments without reserving them. Pickers offer None.
- Images, PDFs, video and picked windows use the same native media boundary in every enabled profile. Remote-only media, including deferred model refresh, must not replace a valid live lyrics program.
- Explicit PDF loads replace the owning session's accepted source even when its URL is unchanged. Native page navigation reuses its accepted document; another workspace's reload or Clear cannot invalidate it.
- Native and NDI PDF output render the accepted snapshot's retained PDF bytes.
  A rejected Current replacement cannot reopen its path or alter accepted output.
- Each workspace’s OutputMediaRuntime owns one program AVPlayer shared by all its outputs and pools matching muted background resources. Independent workspaces have independent program players that outlive parked controls. ScreenCaptureManager owns one picker-approved stream with reference-counted consumers and GPU-backed sample-buffer fan-out. Closing one destination does not stop others. Independent background audio has one explicit session owner.
- AppDelegate owns one native AppKit Settings window shared by the app menu, Manage Outputs toolbar action and inline output notices. General, Outputs and Workspaces use native toolbar tabs. Appearance and backgrounds live in Manage Outputs; thumbnail size and font size use a separate native Thumbnails toolbar menu. Add Native and Add NDI Output create disabled destinations for the controlled workspace. Native monitors are unassigned; generic NDI sources require no receiver assignment. Multiple generic NDI outputs use unique enabled names, with eucaly as the first default source name. Audience, Confidence and Lower Third are locally rendered appearance profiles. NDI output-level edits own independent customized appearances. Lower Third defaults to chroma green. Retired Meaning/Translation presets migrate to Audience while custom copies retain their settings.
- Validate a destination's assignment before enabling it. Conflicting monitor/source-name attempts leave its saved enabled state and assignment unchanged, with an inline settings error. Disabled destinations may retain shared assignments. Output failures use an inline workspace notice with Manage Outputs and Dismiss actions; never show a blocking output-unavailable dialog.
- Manage Outputs uses AppKit list-and-detail navigation, with native controls, colour wells and NSFontPanel. Settings apply immediately; names commit on Return or editing end, with no Save button. The Settings window owns visibility, resizing and close/reopen lifecycle. Disclosure headers are clickable across the full row. Preserve requested fonts during fallback and relative size inheritance when choosing a component font. Pickers preserve duplicate names by UUID. Audience thumbnails use its typeface/layout with independent size controls. Readability notices remain operator-only.
- Output-level Customize Appearance and toolbar edits use an exclusive customized profile, preserving reusable profiles and other outputs, including disabled rows. Direct Profiles-list edits intentionally affect every output using that profile. Import legacy appearance preferences only during migration; sidebar background changes must not reimport appearance.
- Manage Outputs groups reusable profiles, assigned output appearances and unused saved appearances using customization metadata and references, never names. Output pickers offer reusable profiles plus the current appearance. Copying an output appearance creates a reusable profile without reassigning outputs. Remove only unused custom profiles, rechecking disabled destinations too; protect built-ins. Retain legacy names/settings until explicit removal. NDI Transparency explains Alpha/Chroma; its chroma colour well appears only in Chroma mode and uses exclusive output customization. Alpha retains the saved key colour. NDI-only appearance editors direct key-colour edits to the output; native/shared profiles explain the existing colour's native-background/chroma meaning. No schema migration or source restart is needed for this UI organization.
- Saved document version 6 adds durable workspace records and exclusive destination ownership. Existing rows and both legacy NDI sources migrate to Home, retaining UUIDs, source names, appearances, monitors and music choice; both become generic outputs and are never merged. Duplicate enabled legacy names keep the first enabled row by saved order and disable later rows. Preserve the pre-v6 backup; orphaned owners recover as disabled rows in named recovered workspaces. Version-5 retirement still removes AltView/SRT data. No NDI source is automatically added or started. Credential cleanup follows verified persistence, uses only the exact retired eucaly services, has no authentication UI, and retries at most three times off the UI thread. Do not restore incoming reception, scripture components or hub protocol extensions. ViewTheWord's projection and appearance are independent.
- See docs/output-profiles-implementation.md for architecture, verification and physical/profiling limits. Snapshot acceptance does not prove GPU cadence or physical delivery.

### OMT and network output selection
- Shared network routing, IPC, audio and media live under `eucaly/Output/Network`;
  the neutral helper separates `Core`, `Rendering` and independent NDI/OMT
  adapters. SDK calls and handles belong only to their matching adapter. See
  `docs/network-output-architecture.md` for dependency direction, buffer
  contracts and stable data boundaries. Do not restore protocol compatibility
  aliases or put shared machinery inside an SDK adapter.
- Protocol is a saved per-destination choice. Add Native, NDI or OMT Output creates a disabled row for the controlled workspace. OMT and NDI use one native network editor and one routing toolbar/menu; show the protocol in mixed-source menus. There is no global protocol switch or live protocol conversion.
- OMT starts at progressive SDR Rec.709 1920×1080, 30/1 fps, fixed Medium VMX quality, with stereo 48 kHz planar Float32 audio. Source names are unique among enabled destinations of the same protocol. Lyrics, PDFs, images and video use the shared accepted-Current rendering path. Picked windows remain native-only for both network protocols.
- AppDelegate's network router retains a separate helper process per destination. The `eucalyNetworkHelper` executable selects an explicit technology from authenticated bootstrap configuration. OMT loads only its app-bundled, signed SDK 1.0.0.19 libraries, built from unmodified pinned upstream runtime sources documented in `Vendor/OMT`; NDI retains its separately installed vendor runtime. The UI process loads neither SDK. Reuse rendering, bounded admission, ownership fencing and shared media; retain each SDK's own buffer-consumption rules.
- OMT uses UYVY for a proven opaque canvas and straight-alpha UYVA otherwise. Keep each frame through GPU completion and synchronous SDK consumption. Audio and video share an explicit continuous 100 ns timestamp domain. OMT status reports TCP connections, including separate audio connections, rather than claiming receiver-device counts.
- Preserve one backgroundAudioDestinationID across NDI and OMT, with no duplication or implicit rerouting. Local listening/liveness policy covers both protocols. Current, Preview, transfer, teardown, explicit startup, inline failure, unsupported-capture and independent-workspace contracts apply equally to both.
- Saved document version 7 adds OMT and preserves all earlier IDs, names, profiles, workspace assignments and the music route. Retain the original pre-v7 bytes in outputProfilesOMTMigrationBackup without replacing earlier migration backups. Migration never adds a network output or starts a helper.
- See docs/omt-runtime.md for setup, dependencies and validation scope. Real SDK loopback establishes decoded reception, not physical HDMI/audio delivery or sustained qualification.

### NDI Output
- AppDelegate owns one NetworkOutputRouter independently of controls windows. Constructors, restoration, assignment, enabling and appearance edits never load NDI or start helpers. Explicit Start/Show/Retry starts each generic source. There are no Lyrics/Media roles; multiple simultaneous outputs support the same content with globally unique enabled source names.
- Source UUID/name, supervisor, exact helper and receiver connection belong to the app-level destination. Explicit workspace transfer changes accepted content/audio without stopping, renaming or recreating that sender. Content-type changes also retain it. Source name/format edits require a new explicit start after exact-child retirement.
- The toolbar's NDI menu shows the saved owner and moves an existing source directly to any saved workspace's Current, including closed tabs. One source shows NDI: workspace; multiple sources have separate routing submenus, independent of the default appearance-editing output. Menu construction/focus never starts output or prepares closed sessions; explicit moves reuse the same preflight/transfer path, keep stopped/disabled sources stopped and report failed moves inline in the requesting workspace. Revalidate UUIDs for retained menu actions; do not open tabs, rename sources, change appearances/music routing or recreate helpers during routing.
- NetworkContentRoute owns a sender-lifetime revision counter and content-owner epoch. Transfer fences staged frames/audio; helper GPU completions and SDK pending/current pictures reject old epochs. Ownership fences close old admission immediately, then acknowledge asynchronously after admitted old-owner audio finishes. Audio fencing never waits behind SDK video work; the SDK video queue coalesces to the latest epoch and retains the previous borrow through the next async send or shutdown flush. Control/Stop remain independent. Acknowledged fences coalesce to the latest admitted epoch; new-owner frames/audio wait for acknowledgement, and queued drains revalidate admission before consuming staged work. Keep CVPixelBuffer ownership through GPU acknowledgement and SDK leases until the next async send/flush. Stop never waits on SDK code in the UI process; confirm exit before retrying a generation.
- A separately installed signed NDI 6.3 runtime is loaded only by the bundled helper. No NDI binary is linked/bundled with the main app. Only the helper has the library-validation exception. Preserve vendor signature checks, private authenticated Mach IPC, exact-process supervision, bounded latest-frame/PCM admission and four output-surface leases. PCM uses a separate private helper port with three blocks in flight; the eight-block bound includes staged and unacknowledged blocks together. Its dedicated reader validates, submits to the SDK and acknowledges serially without control/worker dispatch hops. Stop closes admission and asynchronously waits for accepted audio calls before sender destruction. Audio replies reserve the frame port's fourth slot for one render acknowledgement; ownership/status/shutdown control stays independent. Mach mailboxes explicitly apply the four-message kernel limit. Dedicated blocking readers have independent lifetime contexts and per-message autorelease pools, holding no GCD worker while idle. Cancellation wakes them without waiting and releases the receive right after in-flight handling. Failed sends release Mach's returned copied rights. Live PCM/control/IPC/rendering/submission use user-initiated priority; control/frame readers serialize admission on their owner's queue without accumulating closures. The live helper selects the public default application task category so its windowless AppKit role does not cap the requested user-initiated queues. It claims no foreground or real-time priority. The live app PCM clock and each live helper own latency activities; the helper retains its activity through sender cleanup, independently of the app's system/display sleep policy.
- One generic composition path renders the owning workspace’s cached multilingual SwiftUI lyrics, prepared PDF/image textures and AVPlayerItemVideoOutput from its shared player. The workspace media runtime owns reference-counted samplers per player/item; destinations share acquisition, with independent composition and teardown. Sampler shutdown closes admission immediately and detaches after in-flight reads finish; the main actor never waits for acquisition. Queued decoder failures must match both the current render plan and destination epoch before retiring output. Text has straight alpha and transparent surroundings by default; chroma retains its configured colour. Independent opaque visual backgrounds remain explicit. There is no Audience capture, dummy display, helper AVPlayer, incoming receiver or forwarding path.
- NDI dimming applies only to visual textures. Empty/key frames and fit gutters retain the exact configured chroma colour through Hide, Clear and appearance changes.
- Hide/Clear submit actual replacement empty/key frames. Without an opaque background, cleared pixels are transparent. Clear Current removes foreground/soundtrack but retains independent visuals and music. Clearing visual assets retains the remembered key colour, including in alpha mode.
- Output remains SDR 1920×1080 at 30/1 fps. Metal composes directly into shared Rec.709 studio-range UYVY buffers for a proven opaque canvas or UYVA with full-range straight alpha otherwise. Cached text and prepared images/PDFs remain BGRA; explicitly tagged progressive SDR H.264/HEVC with supported 601/709 matrices and Rec.709 primaries/transfer uses decoder NV12 planes directly, preserving range and chroma location. Untagged, alpha, wide-colour, interlaced, composed and unknown video retains AVFoundation’s BGRA conversion. Opaque media can omit alpha only when it covers the full canvas; unknown opacity and fit gutters retain UYVA. Keep the four buffer/SDK borrow leases, conservative alpha retention, and alpha-weighted shared chroma for transparent glyph edges. Debug-only BGRA comparison and packed-byte tests verify conversion; decoded RGB can vary slightly through 8-bit 4:2:2 quantization. Keep 50/60 fps unavailable until separate gates pass. GPU composition/conversion does not move the SDK codec onto the GPU.
- Unsupported picked-window content cannot replace a valid NDI-only program. Preflight rejects an unsupported transfer before accepting it; native companions may present it while NDI blanks explicitly. Failure or closure affects only that destination; other workspace outputs, Current and local music remain usable. Failed sources wait for explicit Retry/Show.
- NDI-only program playback remains alive after the last native consumer closes. NDI holds system-sleep prevention; physical windows additionally hold display-sleep prevention. Confidence standby never starts program media or publishes NDI.
- ProgramAudioBus/taps retain preroll, media/host-time mapping, mute and gain. The shared tap retains bounded unplayed PCM with per-mixer delivery cursors so late or restarted outputs do not miss already-decoded audio or duplicate it into existing consumers. Mixer callbacks recover due host-clock blocks in bounded bursts; coalesced timers must not accumulate timestamp lag. Each output keeps its continuous audio clock on transfer; video follows its owning workspace. The single explicit local music owner and saved backgroundAudioDestinationID (Off/nil or one NDI/OMT UUID) do not change on transfer. No silent music substitution, duplication or rerouting. Preview, microphone and system audio are excluded. Audio gaps/overruns retire only the affected source.
- Output → Listen on This Mac, in both the toolbar and menu bar, is a persisted per-workspace preference for video/background-music listening through the default macOS audio output. New and unset preferences default on; explicit saved off remains off. Native outputs and explicitly requested standalone music retain their local audio; the menus show that effective checked state and explain it without overwriting the NDI-only preference. NDI gain/mute is independent of the player's local output volume. Listening edits never start outputs, change ownership/music routing, seek or recreate players. Stopping/moving the last NDI output must not invent standalone local music playback; explicit standalone music playback without NDI remains available. Preference restoration reads after pending saves on the same persistence queue.
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
- Follow the Media Flow Contract above for every source type.
- Clear can run while projecting; it clears Current without implicitly restoring Preview.
- Show/Hide Slides and Cmd+2 are disabled when that workspace's Current is empty, including while outputs remain open. NDI Start/Stop/Retry, background controls and Open Confidence remain independent.

### Projection
- Toolbar and menu control slide visibility separately from backgrounds/audio. Projection may remain active with slides hidden; see Keyboard Shortcuts below for ESC and layer commands.
- `OutputCoordinator` holds one `ProjectionSleepPrevention` activity while any physical projection window (including a standby clock) is open, preventing idle system and display sleep. Hide Slides, Clear Current, and background/layer changes retain it. Stop Projection, native window close, display-loss shutdown, and teardown release it; browsing, naming, Identify, audio alone, and failed projection starts do not acquire it.
- Projection target display is user-selectable from the toolbar (`display` menu).
- `ProjectionDisplayManager` is shared by the toolbar, Manage Outputs, and sessions. Assignments, monitor numbers, and custom names are persisted by macOS display UUID; the old `projectionScreenDisplayID` preference is migrated once.
- Identify briefly labels an idle monitor without changing Current or opening projection. Stop projection before selecting another monitor.
- Projection requires an explicitly selected monitor; there is no Auto selection or fallback. A previous Auto preference becomes unassigned and requires a choice. Each active projection pins the selected physical identity. Disconnect, mirroring, or ambiguous identity closes projection immediately, retaining Current, audio, names, and the saved assignment; reconnect requires an explicit Show Slides. Never silently move output to another monitor.

### Keyboard Shortcuts (Current)
- `Cmd+F`: Search Library in the active workspace, including from the lyrics editor; repeating focuses the existing query. See `SEARCH.md` for search focus and activation behavior.
- Find in Lyrics: separate native Edit > Find command without a shortcut. `Cmd+G` / `Shift+Cmd+G` find the next / previous text match; `Cmd+E` uses selected lyrics for Find. These do not navigate library results.
- `Cmd+T`: New Workspace
- `Cmd+1`: Stop Workspace Outputs (retain that workspace’s Current and assignments)
- Stop All Outputs: explicit global Slides-menu action, without a shortcut
- `Cmd+2`: Show/Hide Slides
- `Cmd+3`: Clear Background Visual
- `Cmd+4`: Clear Background Audio
- `Cmd+5`: Clear All Layers (hide slides + clear visual/audio)
- ESC: Dismiss library search and restore focus when search is open; otherwise Hide Slides only (does not stop projection, does not clear background/audio)

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
- An open Confidence output with no visible text or media shows a large centered clock, including when empty, cleared or hidden. Visible content shows Current on the left and Next on the right, with no source-name header or media filename.
- Enabled, assigned Confidence opens automatically after the real workspace becomes key or after assignment/enable, including before the first slide.
- Standby stays local to Confidence: it never shows a slide, steals focus, takes ownership, starts program media, publishes NDI or changes Current/session presentation state.
- Stop, native close and display loss suppress reopening until Open Confidence/Show or a new assignment/enable; resume only on the saved physical identity.
- The old optional Timer/Clock overlay and countdown controls have been removed.

## Window Capture Support (Authoritative)

This section supersedes older window-capture docs.

Window capture streams one user-picked app window into a normal slide.

### Picker and Permission
- `eucaly/ScreenCaptureManager.swift` uses `SCContentSharingPicker` in `.window` mode with `maximumStreamCount = 1`. Picker observer updates to `@Published var windows: [CapturedWindow]` are the selection authority; no persisted allowlist is used. Only the controlled workspace accepts the selection into Preview.
- Request screen-recording permission lazily, only after explicit `Pick Window...`; never prompt at app launch.
- The manager exposes `startCapture(windowID:outputHandler:)`, `stopCapture(windowID:)` and `stopAllCaptures()`.

### Preview, Current and Rendering
- `eucaly/Models.swift` defines `Slide.captureWindowID: CGWindowID?`; non-window slides use `nil`.
- `eucaly/SidebarViewController.swift` owns list-style Windows rows, the native
  `Pick Window...` action and selectable `SidebarSelection.window(windowID)` rows.
- `eucaly/ContentView.swift` maps that selection through `loadWindowPreview` to standard flow slides with `captureWindowID`. Load follows `handleLoadPreviewToCurrent` -> `flow.movePreviewToCurrent(...)`, exactly as other media; capture cannot bypass the Media Flow Contract.
- In `eucaly/PresentationWindowController.swift`, the slides layer renders `WindowCaptureSlideView` when `captureWindowID != nil`, otherwise the video/PDF/image/lyrics branch. `isLyricsSlide` must exclude window slides.

### Lifecycle and Cleanup
- Capture consumers attach when a window slide appears and detach when it disappears. The shared source stream stops after its last consumer releases it.
- Pane cleanup checks every retained workspace's Preview, Current and accepted output before releasing a shared picker selection. Defer release while any consumer remains; preserve pending picker requests and revalidate selection/stream generations before async teardown.
- Destination/session teardown releases its own consumers; app shutdown stops all active captures.
- Missing window or permission failure must degrade gracefully (error state, no crash).

Future multi-window support must retain the same media-flow and explicit-selection semantics.

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
  - `LibrarySearchPalettePresenter` owns an AppKit palette in the existing workspace
    window. Native field/results controllers own keyboard and accessibility work;
    no SwiftUI search overlay or presentation animation owns their lifetime.
    `OutputWorkspaceContentController` owns the native root: the retained SwiftUI
    host and search palette are siblings, outside SwiftUI's managed view hierarchy.
    Dismiss it before workspace focus capture or controls teardown. Playlist feedback
    stays inside search; adding never opens Preview or changes Current.

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
  - Manual clear drains continuation-owning reads and rejects stale results by generation; never cancel queued reads without resuming them.

## Filesystem Model
- Library root is user-configurable and persisted.
- Security-scoped bookmarks are used for out-of-container folders.
- Playlist is persisted under library root:
  - `<LibraryRoot>/Playlist/playlist.json`
  - root-relative paths + stable IDs + explicit order
  - Controls share one observable playlist store. Mutations read the latest saved order and preserve unreadable documents instead of overwriting them with an empty fallback.
- New lyrics save the exact `.txt` destination confirmed by the native save panel. Validate library-root containment before confirmation; never redirect an outside-root selection to another path after overwrite confirmation.

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
- Use the existing accent provider and native system accent behavior.

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
- Use native outline/table virtualization for large sidebar libraries; preserve stable row identities and expansion state across updates.

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
Select checks for affected behavior and shared boundaries under the Shared
Completion Contract; shared flow/media changes must cover every affected type:
- Lyrics/PDF/Image/Video/Window all load into Preview.
- Preview does not implicitly overwrite Current.
- Load to Current works identically across media types.
- Projection renders its destination’s assigned workspace Current; browsing, workspace/focus changes and passive preparation stay private.
- Simultaneous workspace programs remain independent; a live NDI transfer retains source identity/helper/connection and rejects prior-owner work.
- Ordinary controls affect their workspace; Stop All Outputs is explicitly global.
- Migration/restoration preserve names/IDs/appearances/music and never auto-start NDI.
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
