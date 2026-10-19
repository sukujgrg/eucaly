# Generic NDI output: implementation and qualification

The implemented model is one Current per named workspace, with exclusive saved output
assignments. Multiple outputs share that workspace's program playback. Different
workspaces can present simultaneously. Profiles are reusable appearance settings.
There is no Follow House/Independent switch and no second Current inside a workspace.

## Operator contract

- New workspaces are empty and have no assigned outputs. Native tabs are the normal
  navigation; Move Tab to New Window retains the same window, session and live resources.
- Browsing, Preview, tab selection and window focus never take, start or reroute output.
- Explicit Move to This Workspace changes one destination's owner after capability
  preflight. Other outputs remain with their existing workspaces.
- Worship can own a native church monitor and an NDI output. Moving only NDI to Online
  leaves the church monitor on Worship. Moving it back preserves the sender/connection.
- Load, navigation, playback, Show/Hide, Clear and Stop are scoped to their workspace.
  Stop All Outputs is a separate global action. Hide/Clear/Stop retain assignments.

## Implemented transport boundary

Add NDI Output creates a disabled source with default name `eucaly`. Each generic
source supports lyrics, PDF/image and video with its permitted soundtrack. There
are no transport roles. Multiple sources use distinct enabled names across all
workspaces. Webpages and picked windows require native output; preflight rejects an
unsupported transfer, and native companions can render while NDI explicitly blanks.

An app-owned destination retains its source UUID/name, supervisor and exact helper
across workspace and content-type changes. A per-destination epoch fences old broker,
GPU and audio work; sender-lifetime revisions remain monotonic. Source name/format
changes still retire the helper and require explicit Start/Retry/Show. Restoration,
enabling and appearance edits do not publish.

Cached SwiftUI text and prepared media use one GPU composition path. Alpha surroundings
are transparent by default; enabled opaque visual backgrounds and remembered chroma
colours are independent. Hide/Clear replace the actual picture rather than freezing
it. Clear Current retains independent visual backgrounds and music. Each workspace
owns one shared program player; other workspace players run independently of tabs.
The single explicit background-music owner/route is retained on output transfer.

Initial qualification remains SDR 1920×1080 at 30/1 fps, BGRA/straight alpha. The helper
alone dynamically loads the signed external NDI 6.3 runtime. Preserve vendor checks,
helper-only library-validation exception, bounded latest-frame admission, four output
surfaces, SDK borrow leases, authenticated private Mach IPC, bounded PCM and exact-child
supervision. Do not infer GPU-only encoding from GPU composition. Higher frame rates
and UYVY/UYVA require separate parity/performance evidence.

## Migration

Version 6 creates Workspace 1 for legacy output rows. Keep both legacy NDI destinations
as generic outputs, preserving customized names, source identities, appearances and
music selection. Never silently merge receiver-visible sources. Duplicate enabled
names retain the first enabled row by saved order and disable later duplicates.
Preserve monitor UUIDs and disabled assignments. Save a pre-migration backup. Orphaned
saved workspace identities are recovered as disabled destinations in named recovered
workspaces, never assigned to whichever tab is focused. No migration starts NDI.

## Automated evidence

`make test` remains the required validation command. The added workspace/migration,
router-transfer and helper-pixel regressions exercise the contracts above. Existing
supervision, video geometry, preroll/mute, release/feed and native output regressions
remain relevant. Compiler checks do not establish runtime test success; current run
limits are recorded in [the implementation document](output-profiles-implementation.md#verification-and-limits).

The pre-refactor local SDK/signing evidence under `build/ndi-transition/` is historical.
It must not be reported as qualification of live workspace transfers. This work does
not authorize signing, notarization or publication.

## Equipment and sustained operation

These gates remain open before production qualification:

1. Real HDMI/native Audience and Confidence outputs on the minimum supported macOS
   and Apple Silicon hardware; tab/window operation, hot-plug, mirroring and display loss.
2. macOS and Windows NDI receivers on a reachable LAN; discovery, duplicate-name
   handling, source-name edits and explicit retirement/retry. Confirm the same connection
   survives repeated Worship ↔ Online moves and lyrics ↔ image/PDF/video transitions.
3. An alpha-capable mixer with cameras below eucaly: multilingual glyph edges,
   transparent surroundings, opaque backgrounds, Hide, Clear Current and Clear Visual.
   Confirm pictures actually replace the previous program and soundtrack/music semantics.
4. Real stereo audio with measurable markers: video/mute/pause/seek/loop, music Off/route
   changes, transfers, one source failing while another runs, A/V offset and long-term drift.
5. At least two hours of simultaneous sources and native output under desktop/GPU load.
   Record CPU/GPU, memory, bounded queue high-water marks, actual completed frame cadence,
   frame age, audio continuity, reconnect/failure behavior and UI responsiveness.
6. Network interruption, receiver churn, machine sleep/restart, missing/invalid runtime,
   permission UI, VoiceOver and normal quit/forced containment of a stalled helper.

Metrics, SDK submissions, receiver discovery and localhost loopback are separate from
physical display/audio delivery. Do not claim these gates have passed without retained
measurements. Runtime licensing/distribution requirements remain in [ndi-runtime.md](ndi-runtime.md#distribution-requirements).
