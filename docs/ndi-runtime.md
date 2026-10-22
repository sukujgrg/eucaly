# Optional NDI® runtime

The implementation is available in Manage Outputs for engineering qualification.
Native presentation remains independent of the runtime. The physical receiver,
minimum-OS and two-hour sustained-operation gates remain open; see the
[implementation plan](ndi-output-plan.md#equipment-and-sustained-operation).

The selected distribution model uses a separately installed macOS runtime.
End users will need the runtime, not the full development SDK or NDI Tools.
The helper looks for `libndi.dylib` at `/usr/local/lib` (NDI's documented runtime
location), then at `/Library/NDI SDK for Apple/lib/macOS` for SDK installations.
It verifies the NDI vendor signature before loading and requires the 6.3 API.
Use the current runtime from [NDI](https://ndi.video/); see its
[dynamic-loading documentation](https://docs.ndi.video/all/developing-with-ndi/sdk/dynamic-loading-of-ndi-libraries).

The initial tested package is `com.newtek.NDI.SDK` version `6.3.2.0.260413`.
Its runtime contains arm64 and x86_64, with macOS 13 as its minimum; eucaly still
requires macOS 26 and builds arm64 only. The installed runtime is signed by
NewTek, Inc., team `W8U66ET244`, identifier `libndi`. Checksums and header provenance
are in [Vendor/NDI/provenance.json](../Vendor/NDI/provenance.json).

Only `eucalyNDIHelper` loads the library. Its hardened-runtime entitlement allows
the differently signed vendor library after a signature check. Eucaly's main
process retains library validation. No NDI runtime, installer or Tools is copied
into the application. Missing, outdated or invalid libraries produce a helper
failure; they cannot prevent native eucaly startup.

After `make build`, the signed helper supports a read-only installation check:

```sh
"$HOME/Applications/eucaly.app/Contents/Helpers/eucalyNDIHelper" --check-runtime
```

The check reports the loaded version without creating a sender or window. When
automating it, impose a process timeout; runtime initialization is third-party
code. `make test` includes real 1080p30 loopback checks when the optional runtime
is installed and reports an explicit skip otherwise. This does not qualify a
physical receiver, network, audio synchronization or a sustained session.

## Using the outputs

1. Create/name workspace tabs from the Workspace menu (`Cmd+T` creates a tab).
   Each keeps one independent Sidebar → Preview → Current flow. Move Tab to New
   Window retains the same workspace for side-by-side operation.
   **Manage Workspaces…**, also in the workspace toolbar, provides Open, Rename
   and Delete. New creation is limited to four workspaces; older saved workspaces
   above that limit remain accessible. Keep at least one. Delete is available only
   after all output assignments (including disabled rows) are moved/removed and
   playback is stopped. Closing a tab keeps its saved workspace, Current, live NDI
   source and background audio running.
2. In Settings → Outputs, use **+ → NDI Output**. New rows start disabled,
   retain the default-output editing preference, and suggest `eucaly` (then an
   unused numbered name). Enable the row and assign it to the intended workspace.
3. Load the intended item into that workspace’s Current. Choose **Start Output**
   for the source, or **Show Slides** for that workspace’s enabled assigned outputs.
   Select its advertised name at the receiver. No physical display is needed.
4. Every generic source renders lyrics, PDFs, images and video with the permitted
   soundtrack. **Transparent Alpha** leaves surroundings transparent; **Chroma
   Colour** uses the appearance profile’s remembered colour. Typography, layout
   and explicit visual backgrounds apply to the same connection.
5. **Global Music** defaults to Off. Choose one NDI destination or Off. The existing
   explicit local music owner and this route survive output moves. Video audio
   follows the owning workspace; transfer never substitutes another music selection.
   Stopping the selected destination leaves the route inactive without moving it.
6. **Output → Listen on This Mac**, in both the toolbar and menu bar, controls
   local listening for the named workspace's video and background music through
   the **default macOS audio output** selected in Sound settings. It defaults to
   **on** for new workspaces and unset preferences; an explicit saved off is retained.
   Turning it off silences NDI-only playback on the sending Mac
   without changing NDI gain, the selected music destination or playback position.
   The choice is saved per workspace and survives tab changes and output restarts.
   Native projection retains normal local audio while open; the menus show this
   checked and unavailable to change, without overwriting the NDI-only preference.
   Intentional standalone
   music playback without an NDI assignment/route remains available; losing,
   stopping or moving an NDI output never creates a standalone playback request.
   While a standalone music route is requested, the menu likewise shows listening
   checked with an explanation; music remains controlled by its own Play/Pause.

Programme mute and music volume still apply to both local and NDI audio. Local
monitoring uses AVPlayer's output volume, independently of asset PCM decoding; NDI
uses a separate programme-gain snapshot. The local level is set before playback
starts, so asynchronous programme-audio preparation cannot produce a local startup burst.
Monitoring edits neither replace the shared player nor restart the NDI helper.

The output's **Appearance** picker lists reusable profiles and its current custom
appearance. Profiles style text/backgrounds for every supported media type; choosing
Lower Third does not make a source lyrics-only. The Profiles list groups reusable
profiles, output appearances and unused saved appearances separately. Use + on an
output appearance to save a reusable copy. Use − to remove an unused custom profile;
built-ins and profiles used by any output, including disabled rows, are protected.
Existing legacy appearance names/settings are retained until explicitly removed.

**Transparency → Transparent Alpha** requires alpha compositing at the receiver.
The saved chroma colour is inactive and retained, while enabled image/video
backgrounds remain visible. **Chroma Colour** shows a colour well on the output;
configure the receiver to remove that colour. Editing the well customizes that
output's appearance without changing other outputs or its source identity. NDI-only
appearance editors direct transparency/key-colour changes back to these controls.
Visual dimming does not alter the key colour, including empty frames and the gutters
around a fitted image or video.

The toolbar's **NDI: workspace** menu shows the source's saved owner. Choose
**Move to Online** to use Online's Current, then **Move to Worship** to share
Worship's Current with the church monitor again. Either move is available from
the same toolbar without changing tabs or opening Settings. Closed workspace tabs
remain available. With multiple NDI outputs, each source has its own routing
submenu; the default output used for appearance edits does not select the source
to move. Long names are shortened only on the button, with complete source and
workspace names in its tooltip, accessibility label and menu.

The general Output menu and Manage Outputs retain **Move to This Workspace**.
A live move preflights supported Current, then changes accepted content/audio
without restarting or renaming the app-owned sender. A stopped or disabled source
stays stopped. Unsupported Current leaves the live owner unchanged and reports the
failed move inline in the workspace whose toolbar requested it. Worship can keep
the church monitor while only NDI moves to Online, then move the same source back.
Tabs and window focus never route output. Multiple generic sources can run with
unique enabled names. Disabled assignments may overlap. Ordinary Show/Hide, Clear,
playback and Stop affect their workspace; **Stop All Outputs** is explicitly global.

Picked windows remain native-only. An NDI-only attempt retains the
last valid live snapshot and shows a notice. An unsupported transfer leaves the
owner unchanged. With native companions, the workspace can present locally while
NDI sends an actual empty/key picture. Hide and Clear send replacement pictures;
without an opaque visual background they are transparent. Clear Current retains
independent backgrounds and music. Stop retains Current and assignment, flushes
an empty/key picture and withdraws the source. Source name/format edits require
explicit Start/Retry/Show after retirement; content-type changes do not.

Restoration never starts NDI. Existing native rows and both old NDI rows migrate to
Home. Both old sources become generic, retaining source UUIDs, custom names,
appearance and music choice. They are not merged. Duplicate enabled legacy names
keep the first enabled row and disable later rows without renaming. New workspaces
start with no assigned outputs. See [migration details](output-profiles-implementation.md#settings-and-persistence).

Start/Stop, status and performance remain above the scrolling configuration. Start
and Retry remain unavailable until the exact old helper exits. Normal quit waits
asynchronously for all helpers, with a 500 ms forced-exit bound for stalled code.
Failure/performance notices identify the affected output. Typography and background
controls are available for every generic output. Tab titles show useful live status.

The format remains SDR 1920 × 1080 at 30/1 fps. Higher rates need separate
qualification. Images/PDF pages prepare off the UI thread; video uses the owning
workspace’s existing player, without window/screen capture. Geometry preserves
rotation/mirroring, clean aperture and pixel aspect. PDF vectors rasterize at the
output canvas size. Programme audio uses one shared `PlayerProgramAudioSource` per real player/item.
An `AVAssetReaderAudioMixOutput` decodes the enabled asset tracks into stereo
48 kHz Float32 PCM on a user-initiated worker queue, preserving the item's audio
mix. It reads up to one second ahead of the existing AVPlayer timebase; this is
decoded lookahead, not an offset or extra delay in the transmitted clock. The
local audio queue's effects latency, padding and pause/resume omissions cannot
enter programme PCM. No additional player or audio device is created.

The shared decoder retains still-unplayed PCM within the 8 MiB / 256-buffer bound
and tracks delivery per mixer. Late or restarted destinations receive retained
PCM without duplicate submission into existing consumers. Rendered history remains available within those bounds for backward player-clock
corrections. Pause retains decoded future PCM; seeks outside retained history or
lookahead reposition the reader using asset timestamps. Stop closes
admission immediately and cancels decoding asynchronously. Decoder failures retire
only affected outputs through the existing inline failure/Retry path.

The mixer retains media timestamps and bounded clock history across mute,
pause/resume and preroll. A stopped clock's final media position closes the
preceding running interval, preserving pending audio even when an EOF notification
arrives before the next render. Its 8 MiB / 512-segment history stays sorted by
media position for lookup and evicts by admission age, so a freshly decoded loop
beginning survives ahead of an older retained tail. Discontinuity detection uses
actual adjacent asset
ranges, rather than inferring their duration from PCM frame counts. Adjacent
ranges preserve converter state; gaps and overlaps re-anchor it at the supplied
timestamp. PCM already matching the mixer's format retains its immutable copied
buffer directly, avoiding streaming-converter batching. Actual format/rate
conversions retain their converter.
NDI prevents idle system sleep while allowing
display sleep. These engineering checks do not qualify physical receiver delivery.

The mixer clocks against host time and recovers coalesced timer callbacks with
at most four due blocks per callback. It preserves contiguous sample timestamps;
the existing severe-stall discontinuity guard still retires a source. Helper
statistics retain current/maximum audio submission age and SDK call duration to
distinguish upstream lateness from time spent inside NDI.

Private Mach mailboxes use dedicated blocking reader threads. Idle input holds
no GCD worker and does not retain the mailbox wrapper. Closing cancels admission
immediately and sends a nonblocking wake; the reader releases its receive right
after any active callback finishes. Per-message autorelease pools release decoder
temporaries. Timed-out sends release Mach's returned copied rights, including
surface capabilities. This does not change authentication, bounds or SDK leases.
The constructor applies `MPO_QLIMIT` explicitly, and a regression checks the
kernel's actual four-message limit.

Before live sender work (or an explicit Debug probe), the helper selects the public default
application task category. Its windowless AppKit role otherwise caps even
user-initiated queues at default priority. This classification belongs only to
the owned child, permits its explicit QoS requests, and claims no foreground or
real-time priority. Scoped latency activities remain responsible for live-work
timing hints; the app's output coordinator owns sleep policy.

Audio uses a separate private helper port and a three-block submission pipeline.
The eight-block limit covers staged and unacknowledged PCM together, across both
processes. Its acknowledgements share the four-slot frame reply port with at
most one render acknowledgement. Ownership, status and shutdown keep the control
ports free of PCM traffic. The audio reader validates, submits and acknowledges
serially, avoiding control/worker dispatch hops. Stop closes admission and waits
asynchronously for accepted audio SDK calls before destroying the sender. A
blocked audio reader cannot prevent control, video or another source from
progressing; an overrun retires its exact helper.
Ownership fences immediately close old-owner admission and acknowledge after
admitted old-owner audio calls finish. Audio fencing stays independent of video
SDK synchronization. The SDK video queue coalesces fences to the latest owner;
old pending/current pictures are discarded there, and an old SDK borrow remains
leased through the next async send or shutdown flush. A blocked video lane
cannot hold new-owner PCM or fill its admission queue. Control/Stop and exact-
child retirement remain independent. Fences coalesce to the latest admitted epoch;
new-owner picture/audio submission waits for that fence. Queued drains recheck
the actual admission epoch before taking work.
Readers serialize each delivery on the owner's queue without accumulating
pending closures. Live PCM/control/IPC, offscreen render and video-submission
workers use user-initiated priority. The app PCM clock and each helper own scoped
latency activities; helper activities end after normal SDK cleanup.

For sender/receiver/Wi-Fi isolation, CSV capture commands and the opt-in sustained
test, see [NDI audio diagnostics](ndi-audio-diagnostics.md).

### Performance monitoring

The source header shows completed SDK submissions per second and the age of the
latest new picture at submission. **Performance Details** shows frame replacements,
GPU time, SDK call time and submitted audio blocks. Cached stills keep submitting;
their last new-picture age does not grow simply because the slide is unchanged.
The displayed frame rate is measured, independent of the declared 30 fps format.
Two consecutive one-second windows below 27 fps produce a named inline warning;
normal cadence clears it without restarting the source or changing Current.
Dismiss keeps that warning quiet until the source recovers; a later degradation
can warn again. Live measurements remain visible in Settings.
The separate five-second progress watchdog still retires a stalled helper.
These diagnostics do not prove physical receiver delivery or A/V synchronization;
the sustained-operation and receiver qualification gates remain open.

## Source discovery

Explicit Start/Show creates a normally advertised NDI source. A compatible
receiver on the same reachable local network should list it within a few seconds,
typically as `Mac name (eucaly)` for a new source. The operator
selects the source at the receiver. Browsing Preview, opening Settings and merely
enabling an output must not create a source.

NDI uses mDNS discovery; network segmentation, guest Wi-Fi isolation, firewall or
local-network permission settings can prevent discovery. Across routed networks,
use the receiver/NDI network configuration appropriate to that network. Eucaly
does not enable multicast video by default. See the official
[source discovery](https://docs.ndi.video/all/developing-with-ndi/sdk/ndi-find) and
[sender documentation](https://docs.ndi.video/all/developing-with-ndi/sdk/ndi-send).

The implementation follows NDI's
[performance guidance](https://docs.ndi.video/all/developing-with-ndi/sdk/performance-and-implementation):
asynchronous submission, explicit frame ownership and worker isolation. The final
Metal pass composes and converts directly to Rec.709 UYVY (opaque canvas) or UYVA
(alpha may be needed), including a full-resolution, full-range alpha plane.
Cached text and prepared images/PDFs remain BGRA. Explicitly tagged, progressive
SDR H.264/HEVC with supported 601/709 matrices and Rec.709 primaries/transfer uses
decoder NV12 planes directly in the compositor, preserving range, chroma location,
crop and display transforms. Untagged, alpha, wide-colour, interlaced, composed and
unknown video keeps AVFoundation's BGRA conversion. Each workspace's media runtime
shares one leased sampler per player/item across its NDI destinations. Frames retain
their pixel buffers until each helper acknowledges GPU completion; stopping or moving
one output releases only its lease.
Sampler shutdown closes admission immediately and detaches its exact AVFoundation
output after in-flight reads finish, without waiting on the main thread. Queued
decoder failures are checked against the current render plan as well as the owning
destination's content epoch, so a replaced item cannot retire newer Current content.

UYVY also applies when a proven opaque image/PDF or NV12 layer covers the entire
canvas. Fit gutters, unknown BGRA opacity and transparent media retain UYVA; no
pixel scan or nearly-equal aspect-ratio shortcut decides opacity. The live 30 fps
clock, including with no receivers, and the existing audio timing remain unchanged.
The four shared output buffers stay
leased through GPU completion and the next SDK send/flush. Each buffer reserves
6,220,800 bytes for UYVA; the SDK reads 4,147,200 bytes for UYVY, compared with
8,294,400 bytes for the former BGRA frame. This reduces SDK input memory traffic,
not the encoded network bitrate by the same ratio.

Colour conversion uses studio-range luma/chroma with full-range straight alpha.
Shared chroma is weighted by alpha to avoid transparent neighbours desaturating
coloured glyph edges. Ordinary 8-bit YUV quantization and 4:2:2 chroma subsampling
still apply: a decoded RGB key colour can differ slightly from its original RGB
value. Dimming never changes the configured key before conversion. Format changes
retain the source/helper/connection; no setting migration or restart is needed.
The one terminal empty/key picture is filled in packed YUV on the submission worker
without waiting for a GPU lease during teardown. NDI encoding remains SDK-owned.

## Distribution requirements

The installed SDK agreement grants a royalty-free licence for qualifying desktop
products, subject to its terms. External installation does not remove SDK
developer obligations. Before shipping the NDI feature:

- Incorporate the product EULA terms required by section 3(d) of the selected
  [SDK agreement](https://downloads.ndi.tv/SDK/NDI_SDK/NDI%20SDK%20License%20Agreement.pdf).
- Keep applicable header copyright/MIT notices, and NDI attribution in About.
- Link to [NDI](https://ndi.video/) near NDI controls, on the website and in docs.
- Recheck the then-current SDK compatibility and distribution requirements.
- Complete the signed-runtime, missing-runtime and physical receiver gates in
  [the implementation plan](ndi-output-plan.md). A custom Apple TV receiver is
  separate work with its own SDK licensing assessment.

These are engineering release requirements, not a claim of legal approval.
Eucaly's own licence has not been changed. NDI® is a registered trademark of
Vizrt NDI AB.
