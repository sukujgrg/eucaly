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
requires macOS 14 and builds arm64 only. The installed runtime is signed by
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
2. In Settings → Manage Outputs, use **+ → NDI Output**. New rows start disabled,
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

Webpages and picked windows remain native-only. An NDI-only attempt retains the
last valid live snapshot and shows a notice. An unsupported transfer leaves the
owner unchanged. With native companions, the workspace can present locally while
NDI sends an actual empty/key picture. Hide and Clear send replacement pictures;
without an opaque visual background they are transparent. Clear Current retains
independent backgrounds and music. Stop retains Current and assignment, flushes
an empty/key picture and withdraws the source. Source name/format edits require
explicit Start/Retry/Show after retirement; content-type changes do not.

Restoration never starts NDI. Existing native rows and both old NDI rows migrate to
Workspace 1. Both old sources become generic, retaining source UUIDs, custom names,
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
output canvas size. Tapped audio retains media timestamps and bounded clock history
across mute, pause/resume and preroll. NDI prevents idle system sleep while allowing
display sleep. These engineering checks do not qualify physical receiver delivery.

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
asynchronous submission, explicit frame ownership and worker isolation. BGRA is
the initial alpha-correct interchange format. UYVY/UYVA conversion is a measured
optimization gate; GPU composition does not imply GPU-only NDI encoding.

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
