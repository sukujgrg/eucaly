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
existing `eucalyNetworkHelper` executable is shared infrastructure: an authenticated
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

OMT SDK 1.0.0.19 is pinned under `Vendor/OMT`. The arm64 transport runtime is
built from unmodified pinned upstream managed/native sources, with the upstream
64 KiB buffer request and four async slots. The earlier local runtime patches
are inactive historical artifacts, reassessed below; the VMX codec is unchanged.
Source commits,
toolchain, dependency and file hashes are recorded in `provenance.json`, with
rebuild instructions in `BUILDING.md`. MIT and NativeAOT notices are retained.
The C header also has an ABI-equivalent function-prototype correction. Xcode embeds
and signs the libraries in `Contents/Frameworks/OMT`, and copies the notices to
`Contents/Resources/OMT`. The helper loads only those bundle paths and validates
their signing identity in production. A per-helper temporary SDK storage folder
isolates settings and logs from other OMT applications. Users need no separate
OMT SDK, .NET installation or `libomtnet.dll`.

The app, helper and source-built OMT transport runtime remain arm64-only. The
unchanged universal VMX codec retains its arm64 slice, like the prebuilt Sparkle
dependencies.
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

The required loopback fixtures connect to the exact test-owned sender helper's
TCP listener at `127.0.0.1`. They inspect only that helper's current PID and use
its actual port; they never assume port 6400 or select another process's source.
The SDK's advertised `HOSTNAME (NAME)` requires independent Bonjour discovery
and hostname resolution in each receiver; loopback fixtures must also work on
hosted CI runners without those LAN services. Numeric loopback keeps these codec,
media and teardown regressions independent of LAN discovery. The fixtures still
check the SDK's published source identity; these tests do not establish Bonjour
discovery on a physical network.

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
enforces its dated authorization cutoff and retains checkpoints, exact child
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
prove the network's sustainable capacity. This observation prompted the local SDK
repairs described below. Mixed-load cadence remains an open qualification
concern; thresholds and quality
have not been relaxed. Decoded network reception does not establish physical
panel latency, speaker output or audible continuity.

### Local SDK sender repairs and measured limits

`1.0.0.19+eucaly.1` builds the arm64 transport runtime from the pinned upstream
managed/native commits in `Vendor/OMT/provenance.json`. Two source patches are
retained in `Vendor/OMT/patches`, with rebuilding and regression instructions in
`Vendor/OMT/BUILDING.md`:

- Request a 512 KiB kernel send buffer per TCP channel, replacing 64 KiB. This
  applies to audio and metadata as well as video. The four encoded async slots
  remain per channel; raw pixels are still consumed synchronously. The nominal
  extra kernel capacity is 448 KiB per socket. Bounded memory does not guarantee
  bounded delay when a peer stops reading.
- Return the exact rented async slot when the socket is null or
  `Socket.SendAsync` throws synchronously, then preserve the existing exception
  path. The narrow catch excludes completion handling, preventing a second slot
  return. Successful synchronous/asynchronous ownership is unchanged.

The actual upstream pool class failed the null/disposed-socket regression before
that ownership repair (three of four slots remained). The patched class passed
null/disposed socket, bounded byte-identical small/large transfers and peer-reset
cases. This does not exhaust every completion/disposal race. The source-built
64 KiB, 256 KiB and combined 512 KiB variants each passed the four existing real
SDK loopback/teardown integration tests. The VMX codec, quality and wire format
are unchanged; the package retains the upstream MIT license plus the NativeAOT
runtime's license and third-party notices. No upstream repository was pushed.

The device comparison used one M1 Mac mini, the supplied 4K countdown through the
real shared program player, one Apple TV OMT receiver and a full-bandwidth remote
NDI receiver. The sender used Wi-Fi and an optimized Debug test host. Public
kernel socket telemetry confirmed actual 64/256 KiB send-buffer high-water marks
and full video queues under mixed load; audio queues were measured separately.
Source-built variants used the same pinned source/toolchain, with the buffer
patch isolated before adding the independently tested slot-ownership repair.
These are finite network/decoder measurements, not a wired production benchmark
or physical HDMI/speaker observation.

| OMT transport variant | TV measurement duration | TV video admission rate | Audio timing observations |
| --- | ---: | ---: | --- |
| Source-built 64 KiB | 185 s | 19.0433 fps | 2 timestamp discontinuities, 7 short-horizon packets |
| Source-built 256 KiB | 180 s | 29.6996 fps | 0 timestamp discontinuities, 2 short-horizon packets |
| 512 KiB plus slot repair | 1,255 s | 29.8980 fps | 0 timestamp discontinuities or late packets, 2 short-horizon packets |

These unequal-duration receiver runs are not interchangeable with the matched
source interval: over approximately 110 seconds at the same movie positions,
SDK admission rejected 1,496 frames with 64 KiB and 34 with 256 KiB. A subsequent
256 KiB loaded sample found the video queue full in 26.77% of samples, motivating
the 512 KiB request. SDK admissions and decoded receiver counts remain separate.

The 512 KiB functional phase passed 13 source checks across lyrics, PDF, image,
video, private Preview, Hide/Show and workspace transfers. Transfers retained
sender identities. Injecting a crash and explicitly retrying each protocol
recovered that destination while preserving its companion. Those deliberate
fault gaps are excluded from the later clean run.

The clean 512 KiB TV run had one connection attempt, no corrupt frames, five
native decoder drops (0.01338%), no pool stalls or ingress coalescing, and stable
48.67–53.78 MiB receiver memory. Video lead changed from 117.19 to 114.91 ms;
audio lead changed from 225.06 to 253.01 ms. The separate 1,300-second NDI run
received 38,927 video frames and 64,999 audio blocks with no SDK drops, invalid
PCM, capture errors or audio timestamp gaps. Its 731 near-silent blocks
(both channel RMS values below 1e-7) all fall inside the five source EOF/rewind
intervals. The live source recorded 727 exact-zero blocks there; 14 retained
source blocks match receiver timecodes exactly and contain zero PCM. An offline
audio-only decode found 2.773 seconds of zero samples across the movie's tail
and head, with audio covering its full 313-second video duration. Decoder/block
alignment and unrecorded live clock history prevent full packet attribution or
a gapless-loop claim. No transport-generated silence was established; timestamp
continuity alone does not establish audible quality.

The strict clean-run gate **failed**: 29.8980 fps is below the unchanged 29.9 fps
threshold, and two audio packets had less than the requested horizon. No audible
dropout was established. A controlled observer-on/paused/on comparison retained
the same helpers and receiver instance; equal interior receiver windows measured
29.9378 / 29.9385 / 29.9307 fps. Pausing only the test launcher did not materially
improve cadence, so no timer or observer workaround was added. Sustained mixed
load, worst-case queue delay, physical delivery and audible quality remain open
qualification items; neither thresholds nor quality were relaxed.

The source finished explicitly before its authorized cutoff: all owned helpers
exited, no outputs remained active, and no unexpected router failures or source
invariant violations were recorded. Raw source/observer evidence is retained
under `build/OMTProductionStress-20261024/sdk-buffer-comparison`; receiver evidence
is retained by OMTReceiver's `Eucaly-Clean512k` and `Eucaly-ObserverABA512k` runs.

Final integration checks for the local SDK package passed: `make test` executed
1,010 XCTest cases with six expected opt-in skips and no failures, plus one Swift
Testing case, seven feed tests and 103 release workflow tests. This includes the
four OMT real-SDK round-trip/teardown cases and the existing NDI SDK cases against
the integrated package. `make build` archived/exported the signed app; deep/strict
signature verification passed with normal macOS trust access. All nine unique
Mach-O binaries contain arm64, the packaged transport's executable text matches
the tested candidate, and packaged provenance/license bytes match the repository.
Finite signed-helper load checks reported `OMT 1.0.0.19+eucaly.1 (bundled)` and
installed NDI 6.3.2.0 without publishing a source. Independent integrated review
found no actionable defects. These checks do not turn the recorded device
qualification failure into a pass.

### Audio warning investigation and SDK admission diagnostics

The two short-horizon admissions in the clean run occurred at 18:00:37–42 and
18:01:17–22 UTC on October 23. They retained approximately 101 and 94 ms of
audio lead, respectively, against a 101.333 ms route horizon. Neither was late
by its presentation timestamp. Source maximum audio submission age and SDK-call
duration did not increase at either event; the coarse counters alone cannot
locate those individual delays. The older NDI capture's `receiver_timestamp`
column is the NDI SDK's sending-side UTC submission timestamp, not receive
arrival. Remote capture-return gaps also include capture/decoder scheduling;
the machines' absolute clocks were not calibrated against each other.

The operator renewed device access until 08:58 Sydney on October 24 for a bounded
investigation. In `audio-warning-trace-01`, adding a second full-bandwidth NDI
receiver while Apple TV received OMT reproduced sustained horizon violations,
late audio and bounded receiver audio-queue overruns. Removing only the owned
NDI probe restored reception while the operator's NDI Monitor stayed open. The
operator reported audible NDI gaps under load and clean audio after removal.
A confirmatory GUI-only / extra-probe / GUI-only comparison reproduced the
interaction with no source, quality, playout-margin or buffer changes.

For that confirmatory comparison, actual NDI UDP media flows changed 1 → 2 → 1.
Measured NDI transmit throughput averaged 74.04 → 99.73 → 62.52 Mbps; measured
OMT TCP RTT averaged 12.55 → 108.30 → 10.48 ms. Total interface transmit throughput
fell during load. This establishes a repeatable load interaction, not which
radio, access point, OS or vendor queue is the bottleneck; no matched wired test
was performed. The original two isolated warnings remain distinct from the
subsequent sustained overload reproduction.

Exact source timestamps from the receiver were matched to application and both
helper traces. Across the first failure window, each helper handled 6,001
continuous 960-sample blocks without missing trace events or overflow. OMT's
largest SDK call was 1.587 ms and largest SDK-return interval 23.176 ms; NDI's
were 0.352 ms and 23.533 ms. The app's admission-to-IPC delay stayed below
0.181 ms in the examined warning windows. The receiver's local parse-to-admit
work was short while packet receive gaps reached hundreds of milliseconds.
Application handoff and synchronous SDK calls remained timely. That run did not
record audio return values, so SDK admission rejection and downstream transport
or receiver acquisition delay remain unresolved; timely calls do not prove that
each enqueue attempt succeeded.

`lastAudioSDKReturnBytes` and `omtAudioStatistics` now expose that missing
distinction. OMT's raw audio return is the sum of encoded bytes accepted across
matching audio channels. Zero is valid without an audio subscriber, including
a video-only receiver or a connection still handshaking; it can also accompany
rejection. Positive means at least one channel accepted a frame, not every
channel or successful delivery. The pinned SDK's audio statistics describe its
first connected audio channel: frames and bytes enqueued, plus frames rejected
when the async pool is full or a frame exceeds its bound. Channel counters can
include metadata and reset or disappear on reconnect; they are not per-PCM loss
counts. Separate call/zero/positive/returned-byte totals
last for the sender's lifetime. NDI's void audio API leaves these optional fields
absent rather than inventing a success result.

Statistics are read on the existing dedicated audio owner while sender teardown
is fenced. Buffer-consumption acknowledgement, zero-return behavior and source
failure policy are unchanged. Debug traces add an optional `sdk_return_bytes`
column, retaining the existing bounded queue and overflow reporting. The
coordinated fixture opts in with `--audio-trace`; it clears inherited trace
settings when that flag is absent. A real-SDK regression covers zero returns
with no audio subscriber and a video-only subscriber while preserving the exact
helper and control/Stop behavior. The decoded stereo round-trip also requires
positive returns and channel enqueue statistics. These diagnostics do not fix
congestion or turn observed receiver failures into a qualification pass.

The second instrumented capture matched the first persistent load warnings at
source timestamps 192393200000, 192393400000 and 192394000000 (100 ns units).
Each OMT call returned 7,720 bytes, completing in less than 0.1 ms, with
SDK-return ages of 35.268–36.664 ms. The receiver measured receive gaps of
80.593 and 202.361 ms for the first and third blocks, with approximately
0.65 ms of local receive-to-admission work. These exact blocks had prompt
SDK enqueue acceptance; their later delay was not a long synchronous sender
call. Acceptance still means at least one audio channel, not wire completion.
The original two isolated warnings did not have these per-block observations.
The combined ±2-second window contained 205 continuous blocks per protocol,
without missing stages or trace overflow. OMT's return-to-ACK trace interval,
including the new statistics read and reporting, remained below 0.009 ms.

All 27 retained load-warning blocks, plus five separate startup warnings,
matched positive 7,720-byte returns. Zero returns began 1.22 seconds after the
first load warning, following channel removal, so the later zero-return span
must not be counted as failed live-peer submissions. During subsequent
reconnection, the SDK's first audio-channel drop count was observed at one and
then twelve; those are separate channel observations that can reset, not a
sender-lifetime total or an exact count of receiver losses. Initial enqueue
acceptance and later admission pressure both occurred in this failure sequence.

No valid socket-queue capture covered the final load peak: the manually aligned
sampler recorded recovery, and the last automated repeat failed to obtain a
fresh playing report before launching its NDI probe. Both failures are retained
as incomplete evidence. Baseline or recovery queue depths cannot establish the
loaded audio backlog or justify changing the audio socket bound. No additional
buffer, codec-quality, latency-margin or scheduling changes were made.

Final checks passed for this diagnostics follow-up: 26 focused tests including
the real SDK, then `make test` with 1,011 XCTest cases, six expected opt-in skips,
one Swift Testing case, seven feed tests and 103 release workflow tests.
`make build` archived and exported the signed app. Deep/strict signature
verification and finite signed-helper OMT/NDI runtime-load checks passed; all
nine unique packaged Mach-O binaries contain arm64, and both OMT libraries'
arm64 executable text matches the pinned vendor files after re-signing.
Independent code review found no actionable defects; a documentation finding
about attributing delay without enqueue results was resolved and rechecked.
Python syntax and `git diff --check` passed. Both coordinated source runs ended
with their exact app/helper processes gone, no source invariant violations or
unexpected router failures, and no active outputs. Receiver overload failures
remain failures; these checks establish neither a congestion repair nor full
production qualification.

### Ethernet-sender baseline with one NDI and one OMT receiver

The operator resumed testing on October 24 with the sender on `en0`, negotiated
at 1000baseT full duplex, address `192.168.1.27`; Wi-Fi was inactive. Both receiver
routes used that interface. The remote NDI Mac's link remained 100baseTX, a
recorded downstream constraint. Testing was limited to one NDI and one OMT
receiver; no additional receiver-load experiment was run.

The restored movie matched the original retained SHA-256 exactly:
`1578bc4ae077a81fad6492a6c0b34d024f77d3870e11045a253b58df443e5507`,
328,913,440 bytes, 313.003 seconds, 3840×2160 H.264 at 30 fps and stereo 48 kHz
AAC. Source encoding remained progressive SDR Rec.709 1080p30, Medium VMX,
stereo 48 kHz Float32, SDK `1.0.0.19+eucaly.1` and the existing 512 KiB socket
request. The source player's local volume stayed zero and background music Off,
with one shared program player and sampler. Only the test fixture's dated
authorization cutoff and its NDI source identity changed. `eucaly Wired Audio NDI`
prevented the operator's Monitor from silently attaching to its previous test
source.

The source had a 35-minute cap and a 13:00 Sydney hard cutoff. A TV readiness
capture completed without audio warnings. The initial native NDI metadata probe
and partial TV window were then stopped explicitly so the operator could listen
through NDI Monitor. That planned client change was retained as a partial run;
it was not counted as a completed 20-minute baseline or a transport failure.
The GUI and native NDI consumers never overlapped. The same source helpers,
player, item and continuous clocks survived the change.

The subsequent NDI Monitor + OMTReceiver baseline completed a measured
1,205.001 seconds, admitting 36,123 video frames at 29.977561 fps and 60,251 audio
packets. All 23 configured receiver runtime targets passed. There were zero
audio route-horizon violations, late packets, timestamp discontinuities,
timeline resets, decoder-pool stalls, failures or reconnects. Minimum audio lead,
including warmup, was 137.531 ms against the unchanged 101.333 ms route horizon.
Native renderer metrics reported four dropped frames among 35,973 and zero
corruption. These native counters do not measure physical HDMI/panel delivery.

Full source tracing retained 3,713,861 well-formed rows with no overflow or
duplicate stages. All 98,898 OMT and 97,863 NDI blocks paired through application
admission, IPC, SDK return and acknowledgement, with continuous 960-sample steps.
The measured receiver-timestamp span contained 60,251 source blocks per protocol.
Every OMT return in that span was positive: 59,815 returned 7,720 bytes and 436
returned a valid 40-byte silent-channel encoding. NDI returns remained unknown
because its API is void. No audio-channel rejection was observed. The full run's
positive 40-byte returns all matched exact-zero stereo RMS. GUI minutes 13–20
alone retained 21,000 continuous blocks per protocol without OMT zero returns.

Largest instrumented SDK-call durations in the measured span were 10.479 ms
for OMT and 0.703 ms for NDI; SDK-return ages peaked at 38.265 and 50.845 ms.
These instrumented spans include the diagnostic trace and RMS work. The largest
retained receiver callback gap, 81.724 ms, matched a positive 7,720-byte OMT return
at age 27.518 ms, taking 0.099 ms. The largest receiver playback wait, 64.093 ms,
also matched prompt source work. These distinguish source submission timing
from callback and playback-queue timing; they do not measure kernel arrival or
identify which downstream component delayed a packet.

The worst five-second video admission window was 29.254247 fps around the
movie's fifth loop. The receiver's diagnostic `playbackCoalescedVideo` increased
by four, while both source helpers submitted 30 frames across the corresponding
source interval and OMT enqueued 30 with zero rejection. That diagnostic counts
both compressed-queue skips and completed decoded batches admitting no sample;
the periodic data cannot distinguish those sites or prove that EOF caused them.
The broader source loop window retained 495 SDK submissions per protocol at
approximately 30 fps, with 492 new-picture offers and no sustained CPU spike in
the process samples. Brief stalls remain unobservable at that sampling rate.
One separate video-channel rejection was first observed at 01:19:07 UTC; its
unchanged cumulative value appeared in 115 checkpoints. It was one rejection,
not 115, and did not explain the earlier EOF-window dip. No tuning was applied.

The source-side network measurements retained evidence of pressure: 12 of
11,629 sampled video queues were full, while the audio queue reached 23,160
bytes without being observed full. Sampling batches had gaps up to 0.858 seconds,
so short peaks may be absent. OMT audio RTT averaged 7.035 ms with a 9.75 ms
95th percentile and 11.28 ms maximum; the egress counters reported retransmitted
bytes. A successful audio baseline does not establish zero network pressure.
Source PSH/control headers are not complete audio frames or a receiving-NIC
arrival trace.

The operator confirmed clean NDI audio throughout the time they listened. The
listening duration was unspecified; this is neither continuous audible proof
for every measured second nor a TV speaker observation. The main 20-minute
NDI client was the GUI Monitor, whereas the original isolated-warning run used
the native probe. This prevents treating the comparison as a single-variable
Ethernet-versus-Wi-Fi experiment or identifying Wi-Fi as the cause of the
original two warnings.

The source finished explicitly at 01:22:50 UTC after 1,978.223 seconds. Its
196,761 observed output audio blocks had no invalid samples, duplicates,
timestamp gaps, regressions or overlaps. All exact app/helper processes exited,
no outputs remained active, and no source invariant violations or unexpected
router failures were recorded. The SDK log was copied before shutdown.
Evidence is retained under
`build/OMTProductionStress-20261024/wired-20261024/source-01`; receiver records
are in OMTReceiver's `build/WiredAudio-20261024/Receiver-Monitor`.

Both optimized build-for-testing runs passed, including the final source-name
change. Seven offline oracle/harness tests passed before starting the source;
the controlled production XCTest then completed with clean shutdown. This
follow-up changes only the fixture, launcher and evidence documentation. The
full app regression and signed-build checks above belong to the preceding
diagnostics commit; they were not rerun for this documentation follow-up.
Python syntax and `git diff --check` passed. Independent review found no
actionable issues in this follow-up or its evidence claims.

### Video rejection investigation with native, NDI and OMT together

The next authorized check investigated the baseline's single SDK video rejection
and added a real native projection alongside one NDI Monitor and one Apple TV
OMT receiver. The sender retained its wired gigabit interface; the remote NDI
Mac retained its 100 Mbps link. The movie, 1080p30 Medium VMX output, stereo audio
and shipping `1.0.0.19+eucaly.1` transport remained unchanged. These were optimized
Debug test-host runs, not sustained performance tests of the signed Release GUI.

The original rejection can be bracketed to 29 SDK calls between source
checkpoints at 01:19:06–07 UTC: 28 enqueues, one additional zero return and one
additional channel drop. The retained first-channel counters are generic and
can include metadata or received media; they do not alone identify a rejected
video call. The exact call was not retained and cannot be reconstructed from
the one-second status export. The source kept the same player, item, helper,
format and content epoch, away from an EOF or operator transition. Four kernel
samples showed the 512 KiB video socket full in this bracket, and the retained
header trace's largest video PSH gap was 302.824 ms within the same cluster.
Audio was not observed full there. This supports bounded video-send pressure;
it does not identify a receiving NIC, cable or scheduling component as the cause.
The separate earlier EOF-window admission dip remains a different event.

The follow-up adds opt-in `EUCALY_OMT_VIDEO_DIAGNOSTICS=1` history to Debug OMT
helpers. It pairs the synchronous return with its generation, content epoch,
call index, explicit timestamp, packed format, raw byte count, host start/end,
connection context and the existing before/after channel queries on the video
owner queue. Separate first-four/recent-four sets retain connected zero-return
observations and observed drop-counter increases. No payloads, unbounded trace,
new SDK query, retry, delay or admission-policy change is added. No-subscriber
zeros and channel-counter resets retain their existing meaning. Normal helpers
leave this field absent, Release does not enable it, and NDI retains its void
async API and buffer leases. Terminal shutdown pictures are outside this live
call history.

Two isolated product directories used identical app, helper and VMX bytes, the
same pinned managed/native sources and the same NativeAOT dependency hashes.
The control kept the slot-return repair but requested 64 KiB; the shipping arm
kept 512 KiB. The 64 KiB transport hash was
`96584ea4ef060ff0fd22cb93521c6ae2e01b4c6ae462aeac86ebf997404491a3`;
the repository's 512 KiB library stayed
`425f8ad3d87b7b4e0c8381ca0b2f3b499bbc7f59fecb250a8402b21511920cb9`.
The control was never installed in `Vendor/OMT` or the operator's app.

Both arms explicitly started the normal native Audience window on the auxiliary
DELL P2721Q, physical UUID `D3C19136-E594-42E7-938E-942EFB5ADE85`, at its full
1920×1080-point frame with backing scale 2. Native activation retained the exact
program player/item, one frame sampler and both network helper generations.
One matching AVPlayerView reported ready video with nonempty bounds. Native
window 393 remained open from 02:56:54–03:09:06 UTC in the control; window 939
remained open from 03:11:52–03:24:30 in the shipping arm. The operator confirmed
the control's native picture was visible and smooth, for an unspecified duration.
Window/readiness checks and player progression do not count native presented
frames or establish sustained physical scanout. Normal native local audio was
enabled without changing network gain or adding standalone music.

Seek acknowledgements initially reported an actual position of 96.3 seconds,
so comparison used observed first-pass movie positions, not the nominal seek
label or source elapsed time. Both receivers were connected in these interiors:

| Arm | Actual movie positions | Interior duration | SDK calls / enqueues | SDK zero + drop increments |
| --- | --- | ---: | ---: | ---: |
| 64 KiB + slot repair | 140.438–209.173 s | 68.733 s | 2,056 / 2,048 | 8 / 8 |
| 512 KiB + slot repair | 140.582–209.480 s | 68.896 s | 2,057 / 2,057 | 0 / 0 |

All eight control exceptions are retained exactly: each returned zero with a
one-frame drop increase, no enqueue/byte increase, two connections and a
3.260–4.650 ms synchronous call. They occurred around movie positions
151.250–183.351 seconds. Both windows retained epoch 1, one player/item/helper
generation, UYVY 4,147,200-byte input, one sampler, native output and two NDI SDK
connections; the four-surface pool's high-water mark was three. A later empty
peer state does not erase the retained observations. First/recent sets cover
these eight events, not a complete per-frame history.

| TV receiver arm | Measured interval | Video admissions / rate | Audio admissions | Runtime gates |
| --- | ---: | ---: | ---: | --- |
| 64 KiB + slot repair | 184.989 s | 5,527 / 29.877380 fps | 9,251 | Failed cadence; memory sample coverage insufficient |
| 512 KiB + slot repair | 604.9996 s | 18,107 / 29.928946 fps | 30,250 | All 23 passed |

Neither arm reported late audio, route-horizon violations, audio timestamp
discontinuities, timeline resets, pool stalls, reconnects or corrupt frames.
The source PCM oracle observed 75,522 blocks in the control and 77,011 in the
shipping arm with no invalid/nonfinite/out-of-range samples, timestamp gaps,
regressions, duplicates or overlaps. Those are source-admission observations,
not a complete per-block receiving or listening trace.
Receiver baseline/latest video timestamps select source checkpoint interiors
containing 9,187 and 30,212 OMT audio calls respectively: all were positive with
matching enqueue increments and no zero-return/drop increase. These interior
counts omit checkpoint edges and must not be substituted for receiver totals;
positive 40–7,720-byte encodings include valid silent-channel blocks.
The 512 KiB arm's minimum audio lead including warmup was 140.684 ms against a
101.333 ms route horizon. Its TV native renderer reported three drops among
17,957 frames over 599.997 seconds (0.01671%); these receiver drops are distinct
from the source's zero SDK video rejections. Receiver memory remained
48.89–53.84 MiB with nominal thermal state. The control's memory gate did not
establish a 20 MiB leak: its short post-warmup record lacked the required coverage.
Neither arm establishes continuous audible quality or physical HDMI latency.

Kernel queue telemetry supports retaining 512 KiB on this wired setup: the
64 KiB video socket was full in 99 of 875 retained samples, versus 12 of 5,902
for 512 KiB. The control's telemetry ended before its receiver measurement did,
so these unequal and partly covered samples are not normalized stall rates.
Audio peaked at 15,440 bytes without an observed full queue in either arm.
One NDI UDP stream was present in each retained Monitor snapshot. Queue
occupancy is not a measurement of unsent delay.

The first control Monitor selection delivered audio without UDP video; selecting
None and then the same source restored 1080/30p with the same source helpers and
native window. This setup recovery was retained, not attributed to an app fix.
The control SDK log later discovered unrelated test-source names on port 6401;
the matched comparison and all eight exceptions preceded that discovery. DNS
records alone neither prove a concurrent workload nor exclude earlier activity.
The shipping arm's existing process sampler found no unowned eucaly/helper; one
brief xcodebuild observation coincided with a read-only VMX disassembly query,
not an observed build/test. These limits prevent claiming perfect environmental
isolation or that Ethernet alone solved the earlier Wi-Fi warnings.

The source audit narrows the rejection mechanism. At fixed 1920×1080 the largest
possible input buffer is BGRA 8,294,400 bytes. The bridge zero-initializes the
OMT frame and supplies zero frame metadata; the pinned encoder's destination
buffer grows only to input length plus that metadata. Its actual bundled arm64
VMX_SaveTo checks capacity and returns zero on overflow, or the written length
on success. Even a buffer retained after an earlier BGRA frame therefore cannot
exceed 8,294,448 bytes including the 48-byte video headers, below the SDK's
10 MiB channel limit. Ordinary receiver control metadata is consumed before
the SDK's incoming-AV drop branch, and OMTReceiver sends no AV backchannel.
The normal helper path excludes oversize and incoming-media rejection here;
the paired returns and queue pressure support bounded send-pool exhaustion.
This does not recover the original unrecorded call or prove arbitrary VMX inputs
safe; the binary audit establishes the relevant bound, not complete source and
binary identity.

No new eucaly retry, pool growth or quality change is justified by this evidence.
Keep both existing local SDK patches. The actual pinned socket-pool regression
still loses one of four slots on null/disposed synchronous sends without the
repair and passes all four cases with it; Cat6 cannot repair that ownership bug.
A separate actual-SDK channel harness passes the same bounded-pressure policy
with original and repaired sources: four paused-peer slots fill, a fifth frame
is rejected once, then all four frames return byte-identically and sending
recovers after the peer resumes. That behavior is intentional bounded admission,
not a reason to hide drops. The matched wired comparison gives positive evidence
for the 512 KiB request independently of the earlier Wi-Fi measurements. It does
not establish the optimal buffer size for every receiver/network or authorize an
upstream/fork push.

The result supports supervised 1080p30 wired use on this tested topology, while
retaining the two documented patches. It is not an unqualified production
certification: the earlier 20-minute run still had one pressure rejection,
the new three-output run was about ten minutes, hardware used an instrumented
Debug host, the NDI Mac had a 100 Mbps constraint, and sustained Release-GUI
behavior, physical A/V latency, continuous listening and other topologies remain
unmeasured. Existing failures and gate thresholds were not relaxed.

Both source runs completed with zero source invariant violations or unexpected
router failures. All exact helpers exited, both native windows closed and the
coordinator had no active outputs. The 512 KiB source retired automatically at
03:24:30 UTC before the authorized 03:25 cutoff. TV returned to its ordinary
unselected source picker, NDI Monitor was left on None and temporary telemetry
and keep-awake processes ended. No further hardware work was run.

Source evidence is retained under
`build/OMTProductionStress-20261024/three-output-20261024/{arm-64k,arm-512k}`;
toolchain, pool regression and offline common-position analysis are under
`build/OMTProductionStress-20261024/video-rejection-followup`.
Receiver/network/VMX evidence belongs to OMTReceiver's
`build/WiredThreeOutput-20261024`, with receiver run IDs
`E446FCD6-FA33-4ECC-956B-66F4ADF121BA` and
`5D1267C9-6DA6-4172-ADE4-F38ADB3E4402`. These local raw artifacts are not
shipping app resources. Rebuild the shipping package using
`Vendor/OMT/BUILDING.md`; the 64 KiB control used the same procedure with only
the send-buffer constant reverted, retaining the slot repair and dependency pins.

Final integration passed `make test`: 1,020 XCTest cases, six expected opt-in
skips and zero failures, plus one Swift Testing case, seven feed regressions and
103 release-workflow regressions. A focused optimized run passed 21 observation,
native-input, audio-oracle, harness and real-SDK cases; the isolated 64 KiB SDK
diagnostic check also passed. Eight offline Python evidence-gate regressions,
Python syntax and `git diff --check` passed. `make build` archived/exported the
signed Release app; deep/strict signature verification and finite no-source OMT
and NDI load checks passed. All nine unique packaged Mach-O binaries contain
arm64; app/helper/transport remain arm64-only, the packaged transport executable
text matches the shipping 512 KiB library, and packaged OMT notices/provenance
match their repository bytes. Independent integrated review found no actionable
issues. Building and loading the Release package do not supply the missing
sustained Release-GUI or physical-output qualification.

### Stock SDK reassessment and application frame pacing

This reassessment supersedes the earlier recommendation to retain both local
runtime patches. The current bundle uses unmodified upstream .19 runtime source.
Historical results above remain evidence of their particular builds and networks;
they do not qualify the current application pacing implementation.

The later upstream review changes the scope of the earlier patch conclusions.
The internal socket-pool regression retained and inspected a pool after a failed
send, without exercising the owning channel's invalidation and disposal. It did
not establish a persistent public-API capacity leak. The maintainer explains
that the failed channel retires its pool, and recommends externally spacing
frames while retaining the deliberately small 64 KiB send buffer. Both proposed
PRs were closed without merging. See the primary feedback on
[channel cleanup](https://github.com/openmediatransport/libomtnet/pull/62#issuecomment-6381388937)
and [frame pacing](https://github.com/openmediatransport/libomtnet/pull/63#issuecomment-6381480869).
Neither explanation by itself establishes the cause of the eight old rejections.

A fresh source build used completely unmodified managed commit
`5395139d45cf47bf9f90364bf68f9960183e7638` and native wrapper
`bb4b67be8e5964f1017592b9fc5406495e704e5d`, with no slot, buffer or configurable
settings patches. Source files were verified unchanged after building; the
8.0.426 toolchain, NativeAOT 8.0.32 dependency hashes and unchanged VMX codec
match the earlier comparison. This stock arm64 library's SHA-256 is
`d55a2a4ab39b597284a9f7f77660f21331004525d10c3ef675642afbbcbeeb57`.
It was first placed only in isolated copied test products. Those helpers retain
the previous hard-coded package version label, so the source manifest and actual
library hash establish stock identity; that label alone does not.

Independent public-API tests in OMTReceiver exercised pristine .19 and .20,
real codecs and low-resolution loopback: eight receiver dispose/recreate cycles,
eight abrupt receiver-process exits and eight sender restarts with a retained
receiver per version. All 24 cycles in each version received fresh decoded video
and audio, with connections retiring and no persistent capacity-loss defect
reproduced. These are functional lifecycle checks, not throughput qualification.
Eucaly's actual stock-.19 helper tests also passed six receiver cycles (including
three exact-child SIGKILLs while companion audio stayed usable) and three sender
stop/start cycles. Helper identity and fresh payload/timestamp markers were
checked instead of inferring recovery from an internal pool counter.

The application did have a separately reproduced pacing bug. Its repeating
DispatchSource timer coalesced missed events but did not enforce spacing between
actual SDK entries. A finite worker fixture holds an SDK call or its post-call
observation behind controlled gates, then captures every tick and wrapper entry,
return and observation. It uses the actual worker with recording adapters for
synchronous consumption and NDI-style borrowing, including ownership fences,
independent audio/status, lease release and Stop. It loads no SDK or window.
The first experiment missed its gate-release phase and was explicitly invalid;
no production repair was justified by that capture. Matching live helper task
category/latency activity, strict diagnostic release timers and measured phase
validation produced valid fail-before evidence.

The unchanged worker then made post-stall calls only 2.666–4.076 ms apart in the
regression, with complete records and no other contract failures. A separate
actual stock-.19 SDK helper test injected one bounded 95 ms owner-queue delay
outside the timed SDK call and observed a 5.626459 ms recovery interval. Both
regressions failed their unchanged 32.333333 ms minimum criterion before the
repair. This establishes an application scheduling defect. The eight historical
rejects had approximately 33.26–33.40 ms immediate predecessor intervals, so the
new reproducer does not prove that catch-up caused those particular events.

The initial application repair used a strict one-shot timer, with the next
opportunity based on the previous actual SDK entry plus 33,333,333 ns. Early
wakes rearm before consuming pending frames. An over-budget call may resume
when eligible; it does not replay an obsolete timer grid. Codec and observation
time remain inside the period, rather than adding a whole period after return.
Empty/fenced states scheduled a future wake, ownership changes retained the anchor
and Stop prevented rearming. Video continued to use actual host uptime in 100 ns units;
audio's independent 48 kHz clock, bounded admission, epochs, quality and NDI's
previous-buffer borrow through the next send/flush remain intact. No retry,
larger buffer, synthesized timestamp or `Timestamp = -1` substitution was added.

After that initial repair, the unchanged regressions and all nine stock SDK tests passed
(ten focused cases total). Both recording modes had valid captures and no
contract failures, with minimum entry intervals around 33.39 ms. The opted-in
local source-cadence test measured 1,796 SDK calls over a 60.0406-second window,
29.923191 fps, minimum spacing 33.348333 ms and maximum 51.535542 ms. Complete
traces were valid and measured-window returns positive. The unchanged 29.9 fps
source gate passed. This is SDK-wrapper cadence with draining decoded loopback
video/audio peers, not receiver display FPS or physical latency. The independent
review's stale report-label finding was corrected to a neutral actual-worker
description; no production pacing/ownership defect remained in review.

Stock build, source manifests, invalid and valid baseline captures, fail-before
XCTest logs, repaired traces and the local cadence report are retained under
`build/OMTStockSDK-20261024`. The independent public-API artifacts are in
OMTReceiver's `build/StockSDK-20261024/{PublicApi19-Final,PublicApi20-Final}`.

#### Physical stock comparison: initial one-shot cadence failure

A new, fixed 30-minute hardware window ended at 20:54:27 Sydney on October 24.
It included preparation and cleanup. Both arms used the same unmodified .19
transport and VMX hashes, the same read-only 4K countdown movie, Apple TV build
1.0.0 (5), one remote NDI Monitor and the existing DELL P2721Q native output
(`D3C19136-E594-42E7-938E-942EFB5ADE85`). The sender and remote Mac were both
wired at 1000baseT; the remote Mac had been 100baseTX in the previous comparison.
That topology change prevents attributing differences from the old 64/512 KiB
experiment solely to this application's timing. No builds or separate tests ran
during either measured arm. Native evidence establishes the selected window's
visibility, AVPlayerView readiness and shared-player progress; it does not
measure physical presentation cadence or HDMI/audio delivery.

The old repeating timer's TV interval was 184.994510 seconds, with 5,538 decoded
admissions at 29.936023 fps and 9,250 audio packets. Twenty-two of 23 unchanged
gates passed. The memory gate had only 13 post-warmup samples against its required
24, so it remains insufficient evidence. It must not be reported as a pass.
The initial strict one-shot interval was 484.993641 seconds, with 14,475 decoded
admissions at 29.845752 fps and 24,250 audio packets. Twenty-one of 23 gates
passed: both admission and output-sample cadence missed the unchanged 29.9 fps
minimum. Its memory gate passed with 74 post-warmup samples and about 0.043 MiB
mean growth. Neither arm reported audio late/horizon warnings, timestamp
discontinuities or reconnects. The longer run also reported no corruption or
pool stalls. These observations do not turn its cadence failure into a pass.

All complete source traces were valid without overflow or missing calls;
terminal shutdown sends were explicitly excluded from live spacing analysis.
Across its entire lifetime, including setup, seek, loops and disconnection, the
old OMT source made 12,750 calls at 29.953004 fps, minimum interval 9.787833 ms,
with 82 intervals below the unchanged 32.333333 ms regression floor. The initial
one-shot source made 16,569 calls at 29.847830 fps, minimum 33.347792 ms, with no
short intervals. Its median was 33.383958 ms and 95th percentile 33.409625 ms;
43 intervals exceeded 40 ms and 20 exceeded two frame periods. Thus the initial
repair removed bursts but accumulated ordinary wake lateness and retained some
longer source stalls. SDK drop counters did not explain the observed deficit.

The first contiguous source-checkpoint ranges covering movie positions 140–210
were approximately matched, not identical exact boundaries:

| Timer | Actual movie range | Source OMT calls / entry FPS | Minimum interval | Zero returns |
| --- | --- | --- | --- | --- |
| Old repeating | 140.111550–209.171574 s | 2,067 / 29.927338 | 19.788542 ms | 0 |
| Initial strict one-shot | 140.180350–209.353595 s | 2,066 / 29.861124 | 33.359458 ms | 0 |

The old common range contained ten short entries; the initial one-shot contained
none. Corresponding NDI entry rates were 29.912662 and 29.924944 fps, with minima
21.864084 and 33.357959 ms. These are complete SDK-wrapper entry measurements,
not receiver counts or measured native presentation rates.

Both source runs finished normally, with no source invariant/router failures,
PCM discontinuities, stable audio gaps or invalid PCM blocks. All owned helpers
and native windows closed, and the exact host/helper processes exited. The last
source finished at 20:50:29, before the original hard cutoff; the TV returned to
its normal picker and the remote Monitor disconnected. No further hardware arm
was run within that window. Evidence is under `build/OMTStockSDK-20261024/physical/{old-timer,fixed-timer}`
with the combined `source-timing-analysis.json`.

The bundle was subsequently restored to the verified unmodified .19 library.
The public-API lifecycle results and zero transport-drop observations support
retiring the unproven runtime patches, while the application's cadence failure
requires its own correction and validation. The physical result above belongs
to the initial strict one-shot implementation, not any subsequent clock repair.

#### Final phase-clock repair and local regression evidence

The longer physical gaps were mostly inside the preceding synchronous
`runtime.sendVideo` wrapper. For example, a 223.268583 ms entry gap followed a
223.235041 ms wrapper call; observation took 0.007625 ms and the next wake after
observation took 0.022834 ms. A 149.134833 ms gap followed a 149.048750 ms call.
The wrapper duration can include SDK/codec execution, waiting and process
descheduling; this trace does not isolate those internal causes. Ordinary timer
drift is a separate, independently reproduced application issue. A pacing repair
cannot eliminate every slow synchronous call.

A new finite diagnostic runs the actual submission worker for 300 calls with
an explicitly measured 500 microsecond owner-queue wake delay before admission,
outside SDK timing. It uses a recording adapter, no SDK/player/socket/window,
real entry timestamps and complete bounded traces. An injection longer than
2 ms invalidates the ordinary-delay experiment. The first baseline capture had
one 2.161959 ms injection and remains invalid evidence. An unchanged recheck
was valid: injection 0.526833–0.768584 ms, no contract failures, and 29.365847 fps.
Only the unchanged 29.9 fps assertion failed. Both records and the initial
one-shot helper executable were retained before the final scheduling change.

The final worker retains a nominal 30 Hz opportunity clock rather than moving
every deadline by the preceding wake's lateness. It consumes at most one latest
picture per callback and advances arithmetically past obsolete nominal slots.
Actual SDK entries retain the existing regression's period-minus-1-ms minimum,
32.333333 ms: a bounded ordinary jitter allowance, not the old 6–12 ms catch-up
bursts. The next strict one-shot deadline is the latest of that floor, the
nominal opportunity and now. An eligible overdue call can proceed without an
unnecessary additional grid period. An empty/fenced canvas moves only its nominal
opportunity into the future; it retains the actual-entry floor and accumulates
no idle debt. Timestamps still use actual entry uptime, and audio clocks,
admission, quality, priorities, ownership fences, NDI borrows and cleanup remain
unchanged.

The parent agent's review of the
[OBS OMT output](https://github.com/openmediatransport/omtplugin/blob/master/src/OBSOutput.cs)
found direct forwarding of OBS's raw video/audio callbacks with producer
timestamps, without a separate output timer or buffer patch. Its output ends
capture before sender disposal; the separate
[receive implementation](https://github.com/openmediatransport/omtplugin/blob/master/src/OBSReceiveInstance.cs)
retains its receiver across polling timeouts. These support the public-API
lifecycle checks. eucaly retains independent audio/video lanes and its own
borrow/shutdown fences; OBS's shared callback lock is not copied.

All 11 focused tests passed after the final repair: both actual-worker
regressions and all nine real-SDK cases, including the opted-in 60-second local
cadence run. The ordinary-delay regression measured 29.999813 fps with a valid
300-call trace, no contract failures and minimum interval 33.090667 ms. Both
unchanged controlled-stall modes passed, with minimum intervals 32.389292 ms
(synchronous) and 32.387250 ms (NDI borrowing). The real stock-SDK run measured
1,797 calls over 60.002680 seconds at 29.949955 fps, minimum 32.365042 ms and
maximum 78.131542 ms; its complete trace was valid and measured returns positive.
The 29.9 fps gate and spacing criteria were not relaxed. These are bounded local
source checks, not a rerun of the three-output physical experiment.

Evidence is retained in `build/OMTStockSDK-20261024/phase-baseline-{invalid,valid}`,
`phase-baseline-validity-recheck.{log,xcresult}`, `phase-fixed-focused.{log,xcresult}`,
`phase-fixed-headless` and `phase-fixed-sdk-traces`. This focused run did not
complete physical qualification; the subsequent bounded steady-output check is
recorded below. The historical eight rejections remain unattributed.

#### Retained-receiver timing and functional recovery

The first integrated `make test` after the phase repair ran 1,070 XCTest cases,
with seven opt-in skips, and failed the new
`testReceiverHelperSurvivesExactSenderStopAndStart` case. Its DEBUG incoming
loopback probe received no valid picture; the other cases passed. This failure
must remain distinct from the successful optimized focused run and is not
covered by steady-output physical testing.

Diagnostic-only changes retained the probe's 40-call budget, 100 ms maximum SDK
wait and immediate invalid-frame failure, while reporting termination, pending
count and elapsed time. Three isolated unoptimized iterations passed, but the
surrounding real-SDK sequence reproduced two failures with 40 pending returns
over 4,128.777 and 4,136.074 ms. Thus early exhaustion of a call counter does not
explain these failures. No timeout extension or polling-policy change was made.

Further captures failed at cycle 2, the third quick sender, while the original
video-only receiver retained `omt://127.0.0.1:6400`. The new sender was healthy,
with 140–142 wrapper calls near 30 fps, zero connected peers and zero drops;
the receiver retained the previous sender's last timecode. All pending reads
lasted about 4.25 seconds. The sender's SDK log registered the expected listener
without a receiver connection. A later sequence with bounded receiver-log
capture passed; adding diagnostics is not evidence of a causal repair.

The earlier public managed tests used A/V reception with discovery and newly
allocated ports, so their success does not settle this direct-URL video-only
case. Exact native-helper logs, SDK state and corresponding public-API cases
were retained separately. Failure artifacts are
`final-make-test.log`, `restart-probe-diagnostic.{log,xcresult}`,
`restart-sequence-diagnostic.{log,xcresult}`, `restart-state-diagnostic.{log,xcresult}`
and `restart-receiver-log.{log,xcresult}` under `build/OMTStockSDK-20261024`.

A subsequent unoptimized sequence removed periodic log reads entirely and
retained logs only after the exact failed probe child had exited, before its
private storage was deleted. Two of three retained-receiver iterations failed
at the third and second sender respectively: 40 pending calls over 4,243.575
and 4,278.577 ms. Both complete retained SDK logs showed the preceding connection,
but no disconnect or new connection attempt after the last old sender exited.
This narrows the observation; it does not establish the SDK or application cause.
Evidence is `restart-post-exit-capture.{log,xcresult}` and `failed-probe-capture`.

For this failure-only DEBUG capture, set
`EUCALY_OMT_FAILED_PROBE_LOG_DIRECTORY` to an absolute canonical directory.
Only failed OMT video/audio probes are retained, after matched PID/generation
exit. Each capture contains exit/failure metadata and at most eight 64 KiB
regular log tails, using no-follow descriptor access. Capture errors preserve
the original failure. No log polling occurs during reception; final unwritten
SDK logging-queue entries may be absent after abrupt exit.

The parent subsequently matched video-only direct-URL sender-process replacement
through the public API. Unmodified managed .19 and .20 each passed eight cycles,
including the pause in receive calls across sender exit and replacement readiness.
A minimal native C API case then matched one fresh picture, an identical opaque
UYVY terminal send, destroy/shutdown and `_exit`, without Swift or Mach IPC.
It missed the four-second target and recovered without replacing the receiver
at 5,138.558 ms. A repeat with `POSIX_SPAWN_CLOEXEC_DEFAULT` excluded the obvious
inherited-descriptor confound: cycle 3 recovered at 5,054.157 ms after 47 pending
reads. Earlier cycles were 10.125, 1,073.714 and 997.696 ms. Both native reports
remain failed against their unchanged four-second diagnostic target. They show
delayed public recovery, not permanent capacity loss or a proven internal cause.
Evidence is in the receiver project's `build/StockSDK-20261024` directories
`NativeDirect19-OneFrameOpaqueExit` and `NativeDirect19-OpaqueExit-Cloexec`.
An otherwise identical clean-descriptor arm using normal process return also
recovered late, at 5,105.405 ms in cycle 7. Its report is
`NativeDirect19-OpaqueNormal-Cloexec`. This supplies no basis for changing the
helper's exit path; the SDK header's destroy, shutdown, process-exit sequence is
already followed.

Four seconds was the existing DEBUG loopback probe's request budget, not a
documented SDK reconnect guarantee. The pinned SDK configures a five-second
TCP keepalive in `OMTChannel.cs` and throttles connection attempts to one second
in `OMTReceive.cs`. The new functional retained-receiver test therefore opts
into a separate DEBUG `senderRecovery` budget: 80 requests of at most 100 ms,
with an eight-second first-fresh-picture assertion and a ten-second fixture-only
supervisor watchdog. This allows keepalive, retry and two seconds of slack;
it does not promise an SDK recovery bound or turn the four-second miss into a
pass. Ordinary video/audio probes keep 40 requests. The optional bootstrap field
defaults to ordinary when absent and rejects recovery outside OMT video probes;
Release contains no alternative budget. Timing is retained after sender exit,
with the four-second diagnostic result reported separately. No producer linger,
receiver recreation, SDK patch or production timeout change was introduced.

The resulting focused run completed 34 test executions with one opt-in skip and
no failures, covering three iterations of shared pacing, SDK lifecycle and
budget-validation cases. In its first retained-receiver iteration, first-fresh
times were 266.301, 5,210.847 and 5,235.105 ms: two explicit four-second misses,
while functional recovery passed. The other iterations recovered in about
0.23–0.92 seconds. Evidence is `recovery-functional-focused.{log,xcresult}`.

#### Final steady-output physical check

After fresh user authorization, a separate 30-minute device window ran from
21:11:36 to 21:41:36 Sydney. The fixture and launcher both enforced Unix
1792838496, with automatic source retirement 30 seconds earlier. Final optimized
Debug products were frozen under `FinalPhaseStockProducts`; the manifest is
`final-phase-products.json`. The helper SHA-256 was
`613e41367e87a4af977d1ae0db326a3ae50e3f5d75bd2d98f5a128cb599f22a0`;
the unmodified stock transport and unchanged VMX hashes remained as above.
This run assesses steady output, not short receiver-restart latency or
general production qualification.

The same read-only movie, native Dell, one remote NDI Monitor and one Apple TV
receiver ran together on the verified gigabit links. All three were ready before
the seek-to-100 command completed at 21:31:12. The TV's measurement baseline
preceded that seek, so setup and seek effects remain included. The movie crossed
two EOF/rewind boundaries. No builds, separate tests or probes ran during
measurement.

The TV measured 605.000562 seconds, 18,096 decoded admissions at 29.910716 fps
and 30,251 audio packets. All 23 unchanged runtime targets passed, including
the 29.9 fps admission/output-sample gates. There were no audio horizon or late
warnings, timestamp/timeline resets, pool stalls or failures, and one connection
attempt. Ninety-seven post-warmup memory samples ranged from 48.266 to 53.173 MiB,
with mean growth -1.636719 MiB. The receiver renderer reported 17,946 frames over
599.997140 seconds, one drop (0.005572%) and no corruption. These counters do not
measure physical HDMI presentation or acoustic delivery. Native evidence remains
window/AVPlayerView readiness and shared-player progress; NDI Monitor was selected
and connected, without an independent presented-frame counter.

Both source traces were complete and valid, with no overflow, missing calls or
live interval below 32.333333 ms. Whole sender lifetimes included setup and
disconnection: OMT made 23,889 calls at 29.919839 fps, minimum 32.354125 ms,
median 33.333042 ms and maximum 181.021167 ms. NDI made 23,539 calls at
29.944024 fps with minimum 32.352333 ms. Slow synchronous calls remained, while
the old closely spaced catch-up calls were absent.

The first actual post-seek common movie range was 140.775114–209.153120 seconds,
bounded by source checkpoints at 21:31:57–21:33:05. OMT made 2,049 calls at
29.965227 fps, minimum 32.366375 ms and zero SDK zero returns; NDI made 2,050 at
29.985402 fps, minimum 32.365833 ms. Approximate checkpoint movie boundaries
differ slightly from the earlier arms. Terminal shutdown sends are excluded.

The TV returned to its ordinary picker and NDI Monitor disconnected. The source
retired normally at 21:41:06 through its automatic authorized-deadline path;
an explicit finish request arrived afterward and was queued without an ACK.
All owned helpers and native windows closed, exact PIDs exited, active outputs
were zero, and collection completed with exit 0 and no forced cleanup. Source
invariants, router failures, PCM discontinuities, stable gaps and invalid blocks
were zero. Logs, commands, ACKs and traces are retained in
`physical/final-phase`; analysis is `physical/source-timing-final-analysis.json`,
both under `build/OMTStockSDK-20261024`.

This bounded final run supplies steady three-output evidence for the phase
repair with stock .19. It does not establish four-second direct-URL receiver
restart recovery, qualify every receiver/network/load, or establish the
cause of the eight historical rejections.

#### Integrated build status

The final `make build` archived and exported the signed arm64 application to
`~/Applications/eucaly.app`. Deep/strict signature verification, finite
OMT/NDI runtime-load checks, architecture checks, all 13 vendor file hashes,
and packaged notices/provenance comparisons passed. The signed bundled
`libomt` executable text matched the verified unmodified stock source build.
After the DEBUG budget correction, `make build` and the same package checks
passed again. Evidence is `recovery-final-make-build.log` and
`recovery-signed-package-verification.{json,log}`; the earlier
`final-make-build.log` and `signed-package-verification.{json,log}` are retained
under `build/OMTStockSDK-20261024`.

The latest full `make test` ran 1,071 XCTest cases with seven opt-in skips.
All network, NDI/OMT, pacing and functional-recovery cases passed. The retained
receiver measured 248.663, 5,266.211 and 929.760 ms, explicitly marking the late
second cycle as a four-second miss. The full command remains failed: four
assertions, including two caught errors, belong to two unrelated native-focus
setups. `LibrarySearchNavigationTests.testRepeatedLibrarySearchFocusSelectsExistingQueryAndPreservesCandidateAndReturnFocus`
and `LyricsTextViewTests.testNativeLyricsFindRoutesDocumentAndFindBarKeysWithoutSearchingOtherFields`
received neither app-active nor window-key readiness before their five-second
deadline, so their keyboard assertions did not run. A subsequent read-only GUI
session check reported `CGSSessionScreenIsLocked=1` and foreground `loginwindow`.
The unchanged tests passed in the earlier full run. An unlocked-session rerun
remains a validation gap; neither test, timeout nor product focus behavior was
changed. Evidence is `recovery-final-make-test.log` and
`build/DerivedData/Logs/Test/Test-eucaly-2026.10.24_22-34-56-+1100.xcresult`.

`make test-codex-agents`, all eight production-harness checks and
`git diff --check` passed; no network helpers remained after validation.
Independent review cleared the pacing/provenance changes, bounded failure-only
diagnostics and explicit recovery-test scope. The unbounded ad hoc sender-log
dump was removed. Functional recovery does not turn the four-second diagnostic
miss into a pass, establish a hidden capacity leak or explain the eight
historical rejections. No speculative SDK patch, producer linger or production
timeout change was introduced.
