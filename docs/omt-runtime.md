# OMT outputs

eucaly can publish a workspace's accepted Current as an Open Media Transport
(OMT) source. Choose **OMT Output** from the Add Output menu in Settings →
Outputs. Each network output keeps its own protocol: existing NDI outputs retain
their source identities, settings and assignments. There is no global protocol
switch. Native, NDI and OMT outputs can share a workspace or belong to different
workspaces.

## Operator workflow

An added OMT output is disabled and assigned to the workspace being controlled.
Choose its source name, appearance and workspace, enable it, and use Start or
Show Slides. Enabling, restoration, browsing and appearance edits do not start a
sender. On Apple TV, select the published source in OMTReceiver. OMT uses Bonjour
service `_omt._tcp` and direct TCP connections on the local network.

The shared network editor provides Alpha / Chroma Colour, typography and visual
background controls, the actual published source name, status and explicit
Start / Stop / Retry. A source name is unique among enabled outputs of the same
protocol. Its technology is fixed; add another output to use another protocol.
The toolbar's routing menu identifies the configured protocol, or says Network
when both are present. Moving a live output changes its workspace's content
without recreating the sender; moving a stopped output leaves it stopped.

Both network protocols support lyrics, PDFs, images and video files. Picked
windows remain native-only. An unsupported network-only activation preserves the
last accepted program and reports the problem inline; a native companion can
present the picked window while network outputs send an empty/key picture.

The initial OMT format is progressive 1920 × 1080 at 30/1 fps, SDR Rec.709,
with VMX1 compression at fixed Medium quality. Audio is stereo 48 kHz planar
Float32 (FPA1), in 960-sample blocks. There are no 4K, high-frame-rate or
interlaced output controls. Alpha is straight; an HDMI receiver such as
OMTReceiver composites transparent pixels over its display background.

Video sound follows the owning workspace. The existing background-music
destination picker selects one NDI **or** OMT destination (or Off); adding OMT
does not duplicate or reroute music. Listen on This Mac remains the workspace's
separate local-monitoring preference. Hide, Clear, independent backgrounds and
ordinary workspace Stop retain their existing semantics.

OMT's connection statistic counts TCP connections, including separate audio and
video connections. The UI labels that count as connections; it is not an exact
count of receiver devices.

## Rendering and process boundaries

The app-owned network router uses the same accepted snapshots, retained PDF
bytes, workspace players, reference-counted frame acquisition and program audio
bus for both protocols. Preview is never a program source. There is no NDI
receiver, desktop capture or forwarding stage in the OMT path.

Each destination owns an independent helper process and sender lifetime. The
existing `eucalyNDIHelper` executable is shared infrastructure: an authenticated
bootstrap explicitly selects NDI or OMT before loading a runtime. The app does
not load either media SDK. An OMT helper does not require or load the NDI runtime.

The compositor produces packed UYVY for proven opaque frames or UYVA with a
full-resolution straight-alpha plane. The OMT bridge maps pixel-format constants
explicitly, sets Rec.709 and alpha flags, and passes that frame directly to
`libomt`. Composition uses Metal; VMX compression uses the software codec.
The OMT call consumes the input synchronously; the frame lease remains alive
through GPU completion and the call's return. NDI retains its separate async SDK
borrow rules. Audio and video use one continuous destination timestamp domain in
100 ns units, independent of workspace transfer.

Bounded frame/PCM admission, exact-child supervision, stale-generation checks,
content-owner epochs and independent control/audio paths remain shared
requirements. A transfer closes prior-owner admission before accepting new work.
Packets already admitted to a receiver's network buffers cannot be withdrawn.
Failure and teardown are per destination and never block the UI on SDK calls.

## Dependencies and persistence

OMT SDK 1.0.0.19 is pinned under `Vendor/OMT`. Its MIT notices and file hashes
are recorded alongside the unmodified upstream libraries. The C header has one
documented, ABI-equivalent function-prototype correction in `PATCHES.md`. Xcode embeds
and signs the libraries in `Contents/Frameworks/OMT`, and copies the notices to
`Contents/Resources/OMT`. The helper loads only those bundle paths and validates
their signing identity in production. A per-helper temporary SDK storage folder
isolates settings and logs from other OMT applications. Users need no separate
OMT SDK, .NET installation or `libomtnet.dll`.

The app and helper remain arm64-only. The supplied third-party universal
libraries retain their arm64 slices, like the prebuilt Sparkle dependencies.
NDI continues to load its separately installed, signature-verified vendor
runtime; `libndi` is never bundled.

Saved document version 7 adds the explicit OMT destination case. Version 6 and
earlier migrate without adding a source, starting a helper, or changing saved
UUIDs, names, appearances, workspace ownership or the music destination. The
original bytes are retained in `outputProfilesOMTMigrationBackup`; earlier
migration backups remain intact. Newer or invalid documents retain the existing
recovery behavior.

## Validation scope

Use `make build` and `make test` for integration. Automated checks must exercise
mixed native/NDI/OMT destinations, passive-start prevention, independent programs,
transfer fencing, source continuity, music exclusivity and local monitoring,
native editor interaction, migration preservation, and packaged runtime signing.
Real-SDK loopback checks establish encoding, network reception and decoded
video/audio properties. They do not establish physical Apple TV HDMI delivery,
audible quality, end-to-end latency or sustained performance. Those require
separate device observation. Screen sharing remains deferred for both protocols.

Validation recorded on 23 October 2026:

- `make build` archived and exported the signed app successfully; the final build
  reported no compiler warnings. Deep/strict signature verification passed.
- The final `make test` run executed 998 XCTest cases with zero failures and four
  expected opt-in stress skips, plus the Swift Testing case. The seven update/feed
  and 103 release orchestration regressions passed as part of the same command.
- A subsequent focused run passed 59 OMT/native Settings/routing cases, including
  the added real-router media regression. That regression received a previously
  uncached PDF page after deleting its file, a PNG, moving AVPlayer video and its
  decoded stereo soundtrack through the same OMT sender. Private Preview changes,
  native-consumer closure, source identity and shared sampling were checked.
- OMT SDK loopback passed packed alpha/chroma/Clear, stereo/silent-channel PCM,
  timestamp continuity and blocked-video/control/audio/Stop checks. Existing NDI
  SDK integration cases passed in the full run.
- Signed helper `--check-omt-runtime` and `--check-runtime` commands loaded bundled
  OMT 1.0.0.19 and installed NDI 6.3.2.0, respectively, without starting sources.
  All nine shipped binaries passed the arm64 checks; the app and helper remained
  arm64-only. SDK hashes, bundled notices and both Bonjour declarations passed.
- Native Settings tests exercised source-name editing/Return, invalid-name
  recovery, UUID-based music selection, explicit Start/Stop/Retry, scrolling and
  minimum-size/light/dark layout. These are automated native-control results;
  offscreen cached images are not evidence of fully rendered native materials.
- The media consultation and independent implementation/final evidence reviews
  returned no actionable findings. `make test-codex-agents` and `git diff --check`
  passed.

The subsequent shared-audio crash was traced to simultaneous first access to
AVFoundation's lazy PCM channel table. A native cold-buffer reproducer exposed
null channel entries, and the admission regression failed against the original
sources before the repair. PCM admission now captures stable sample planes and
metadata before sharing them; conversion uses independent metadata over retained
samples. Four new regressions passed: concurrent admission, shared 44.1 kHz
conversion, planar/interleaved backing lifetime through teardown, and six seconds
of continuous PCM from one actual player to three destination buses. Independent
review's allocation/deallocation pairing finding was corrected; re-review found
no remaining actionable defects.

Physical Apple TV picture/sound, measured end-to-end A/V latency and sustained
mixed-protocol performance were not tested in this implementation task. The four
skips are the separately opted-in NDI stress/diagnostic and AAC stress cases.

## Coordinated device checks, 24 October 2026

The opt-in `scripts/test-omt-production-stress.py` fixture drives the real
OutputCoordinator, accepted Current, shared player/audio bus, compositor and
per-destination helpers with isolated in-memory settings. It never restores the
operator's library or outputs. Its initial source holds one supplied movie;
explicit, run-ID-fenced commands control subsequent phases. The dated fixture
enforces the authorized 05:30 Sydney cutoff and retains checkpoints, exact child
identities, process samples and command acknowledgements under
`build/OMTProductionStress-20261024`. The receiver project owns Apple TV and
remote NDI measurements. This optimized Debug host is not a signed Release
performance measurement.

Remote NDI attachment reproduced a helper exit twice while OMT continued. The
second run retained the actual OS cause: uncaught SIGPIPE (13). Helper startup
now ignores SIGPIPE before either SDK loads, allowing a closed stream write to
return EPIPE to its owner. Other failures, SDK results and buffer ownership stay
checked. A real closed-socket regression failed before the repair; afterward,
the same helper returned EPIPE, answered control, rendered and shut down. The
post-repair remote NDI checks decoded both video and stereo PCM, including a
disconnect/reconnect on the same sender. Exact exit identities are retained in
system diagnostics; operator status shows the concise exit reason.

The follow-up `make test` run passed 1,010 XCTest cases with six expected opt-in
skips, plus the Swift Testing case, seven feed tests and 103 release workflow
tests. The additional skips are the explicitly coordinated LAN source and
machine-specific supplied-input diagnostic. Independent review of the repair,
statistics and isolated fixtures found no actionable issues.

Sender API calls are not delivery counts. Optional `omtVideoStatistics` exposes
the pinned SDK's first connected video channel: enqueued frames/bytes, rejected
frames and sender codec time. Rejections include a full four-slot async send
pool or an oversized frame. Channel totals can reset when clients change;
bytes include metadata, and codec time belongs to the sender. The separate
sender-lifetime zero-return count also includes calls with no video subscriber.
None of these observations proves socket completion or receiver delivery.

The first five-minute Apple TV baseline met its configured checks. Subsequent
same-instance comparisons exposed lower OMT receipt cadence with a full-bandwidth
remote NDI receiver connected, followed by recovery after it disconnected.
Source call counts, receiver counts and kernel socket telemetry are retained
separately. In a matched loaded interval, the SDK reported 872 rejected video
frames and 958 enqueued frames over approximately 61 seconds, while the video
socket's configured 64 KiB send queue was full. Audio remained continuous and
codec time averaged approximately 6.2 ms per offered frame. This locates the
observed loss at SDK admission; it does not establish a buffer-size repair or
prove the network's sustainable capacity. The bundled SDK remains unchanged.
Mixed-load cadence remains an open qualification concern; thresholds and quality
have not been relaxed. Decoded network reception does not establish physical
panel latency, speaker output or audible continuity.
