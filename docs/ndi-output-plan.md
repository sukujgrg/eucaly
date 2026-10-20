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

The output remains SDR 1920×1080 at 30/1 fps. The final Metal compositor writes
Rec.709 studio-range UYVY directly into shared buffers when the canvas is opaque,
or UYVA with a full-range straight-alpha plane otherwise. Alpha is retained
conservatively when media opacity cannot be proven. There is no intermediate BGRA
output or CPU colour conversion on the normal send path. The helper
alone dynamically loads the signed external NDI 6.3 runtime. Preserve vendor checks,
helper-only library-validation exception, bounded latest-frame admission, four output
buffers, SDK borrow leases, authenticated private Mach IPC, bounded PCM and exact-child
supervision. Cached text and prepared images/PDFs remain BGRA. Qualifying tagged
SDR video uses decoder NV12 planes directly, with explicit matrix, range and chroma
location. Other video retains AVFoundation's BGRA conversion. Workspace-owned
reference-counted samplers share acquisition across destinations without sharing
their composition, sender or teardown. A proven opaque full-canvas media layer can
also select UYVY; fit gutters and unknown opacity always retain alpha.
GPU conversion does not move
the NDI codec onto the GPU. Higher frame rates remain a separate qualification gate.
The offline packed-pixel tests check legal-range Rec.709, packing, independent alpha
and coloured/transparent edges. Optional real-SDK tests compare against the former
BGRA path, including receiver colour/alpha, measured submission cadence and GPU/SDK
timings. The reference sender is Debug-only; it is not an operator format setting.

## Migration

Version 6 creates Home for legacy output rows. Keep both legacy NDI destinations
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

### GPU colour-conversion check, 2026-10-20

`make test` passed 536 app tests plus 108 offline release/feed tests on the local
Apple Silicon Mac (macOS 27.0.1, signed NDI runtime 6.3.2.0). This includes three
packed-byte tests and nine real-SDK tests: source/appearance transfers, shared video,
audio, alpha/chroma replacement, exact-child shutdown and conversion comparison.
`make build` also archived/exported the Release app successfully; the exported
helper accepted the signed runtime with its read-only `--check-runtime` command.

The comparison ran two senders and two loopback receivers, then drove both renderers
with the same 90 changing gradient-background frames at approximately 30 Hz. In that
run BGRA measured 28.7% of one CPU core versus 24.4% for GPU UYVA (about 15% less
helper CPU); both completed 30 SDK submissions/s. Median GPU duration was 0.394 ms
versus 0.542 ms. Median async SDK call duration was 0.014 ms versus 0.019 ms; this
call duration is not total codec CPU time. These are local measurements, not a
general performance guarantee. The test preserves its measurements as an XCTest
attachment; a local summary and log are retained in `build/ndi-yuv/`.

Packed-pixel tests independently check Rec.709 legal-range levels, both lumas and
shared chroma, full-range alpha, transparent colour edges and multilingual glyph
alpha against the original raster. Receiver palette checks require GPU conversion
to reproduce source colour/alpha within the SDK conversion tolerance and preserve or improve
accuracy relative to the SDK's approximate BGRA conversion. UYVA input is 6,220,800
bytes/frame and UYVY is 4,147,200, versus 8,294,400 for BGRA. This is an SDK input
memory reduction, not a claim about encoded network bandwidth. The equipment and
sustained-operation gates below remain open.

### Rapid workspace/format regression coverage

Two real-SDK receiver tests each issue 96 rapid workspace/format operations in
5 ms steps, ending at all four workspace/alpha-chroma combinations. They retain
one source/helper/receiver and check three fresh, advancing receiver frames at
each checkpoint. Coverage includes half-transparent red/blue PNGs, multilingual
lyrics, a cleared Current, green and magenta keys, straight alpha, stable decoded
colour, the four-buffer bound and continuous source timecodes. A separate offline
test runs the same ownership/transparency churn while checking that another source,
its Current, source identity and shared appearance remain unchanged.

The tests exposed a Debug receiver-observation race: timecodes travelled over the
control port separately from frame pixels. The probe now sends them in one frame
packet, and the supervisor delivers matching status before the frame event. PNG
fixtures use explicit sRGB colours and encoding rather than display-dependent
Device RGB. Exact packed tests now include half-transparent primaries. The installed
SDK decodes half-transparent blue as 242 through UYVA versus 239 through BGRA from
a 255 source, despite correct packed GPU values. Stress checks compare colour before
and after churn, with strict independent alpha/key checks; the SDK comparison still
requires source accuracy to equal or improve on BGRA. No compensating colour change
is applied to production rendering.

After these additions, `make test` passed 539 app tests (including eleven real-SDK
tests) and 108 offline release/feed tests. `make build` also archived/exported the
Release app successfully. Local stress-test logs and a summary are retained in
`build/ndi-yuv/workspace-format/`.

### Shared video acquisition and planar input check, 2026-10-20

`make test` passed 544 XCTest cases, the existing Swift Testing smoke test and
108 offline release/feed tests with the installed NDI 6.3.2 runtime. All eleven
real-SDK tests passed. The shared-video test now runs two generic destinations
against one player and one sampler, verifies moving video at a connected receiver,
then closes one destination and checks that the other continues submitting. Tagged
NV12 video uses opaque UYVY when it covers the canvas. Portrait fit/fill runs through
both tagged NV12 and untagged BGRA inputs.

Five additional input regressions check 601/709 matrices, full/video range, actual
packed pixels, plane bounds and descriptor mismatches, transparent fit gutters,
conservative format selection, concurrent sampling and cancellation/late lease
release. The first playback check exposed decoder-guessed SMPTE-C colour on untagged
SD video; eligibility now requires explicit supported colour metadata before the
output attaches, preserving AVFoundation's conversion for those files.

`make build` archived/exported the arm64 Release app. Its signed helper passed
`--check-runtime` without publishing a source. Passing logs and the runtime check
are retained in `build/ndi-media/`. These checks establish neither a general CPU
speedup nor physical receiver qualification. Idle submission, the 30 fps clocks,
audio routing and network defaults remain unchanged.

### Workspace-transfer and shutdown stability review, 2026-10-20

A gated frame-read regression reproduced the sampler's old shutdown path waiting
on AVFoundation while holding the main thread. Stop now closes admission under a
short state lock, rejects late results and queues exact-output detachment after
active reads finish. The regression verifies prompt stop and eventual detachment;
existing lease tests cover independent consumers and late releases.

Queued decoder failures now carry their render-plan version. A new Current or
Stop invalidates the pending failure before its main-actor callback can retire the
destination; the existing workspace epoch and sender generation checks still apply.
Three clock regressions cover replacement before failure delivery, replacement
during a failed read and stop before failure delivery.

`make test` passed 548 XCTest cases, the existing Swift Testing smoke test and
108 offline release/feed tests. All eleven real-SDK tests passed. The shared-video
integration test performs three video-to-lyrics-to-video workspace round trips
through one connected receiver, checks that neither sender is recreated and closes
the companion source while the remaining source continues with the shared player.
`make build` archived/exported the signed arm64 Release app, and its helper passed
the read-only NDI 6.3.2 runtime check. Review logs are retained in
`build/ndi-media/review/`. Physical delivery and sustained-operation gates below
remain open.

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
