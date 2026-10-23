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

OMT SDK 1.0.0.19+eucaly.1 is pinned under `Vendor/OMT`. The arm64 transport
runtime is built from pinned upstream source with the two local sender repairs
in `PATCHES.md`; the VMX codec remains unchanged. Source commits, patches,
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
