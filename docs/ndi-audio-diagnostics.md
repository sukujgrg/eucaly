# Finding NDI audio gaps while sending video

Use the same video and output configuration throughout a comparison. Record the
receiver app/version, sender and receiver connections (Ethernet or Wi-Fi), exact
source name, and the wall-clock times of audible gaps. A local NDI loopback test
does not exercise the access point or the receiver's sound device.

## Compare the boundaries

1. Play the file locally in eucaly. Check for the same missing audio in the source
   file. Keep Current visible, video unmuted and playback running. Hide, Pause,
   Clear and transferring to lyrics intentionally change the program audio.
   For an NDI-only workspace, enable Workspace → Monitor Audio Locally for this
   source check, then turn it off before listening through a separate receiver.
   In Settings → Manage Outputs → Performance Details, watch submitted audio
   blocks and source state. Uninterrupted audio submits about 50 blocks per second.
   Advancing counters establish submission, but cannot distinguish tone from silence.
2. Receive that source on the sending Mac with NDI Video Monitor. If the same gap
   occurs locally, investigate file decoding, tap/mixer delivery and sender load
   before blaming the wireless link. Local audio working alone does not prove the
   NDI tap is working.
3. Receive on the affected computer with a separate reference receiver. Compare
   its audio with the production app. If only one app fails, investigate that
   app's audio buffering, clock synchronization, sample rate and sound device.
4. Repeat the same test with both machines on Ethernet. Then test one wireless
   endpoint at a time, keeping the other on Ethernet. This separates the two
   wireless hops. Verify which interface actually carries NDI traffic.
5. Finally repeat on the production Wi-Fi path with the normal video workload.
   Keep a record of receiver CPU/GPU load and access-point retransmissions,
   signal quality and congestion at the dropout times. Change one variable per
   comparison. Extra unicast video receivers can add sender/network load.

## Capture delivery timing

### Mac receiver with NDI Video Monitor

Select the published source in Video Monitor's NDI menu, keep Mute off, and use
the normal full-bandwidth setting for the first comparison. Note the receiver's
local clock time whenever you hear a gap, and whether the picture pauses at the
same time. Repeat with Low Bandwidth only as a separate comparison.
See the [Video Monitor guide](https://docs.ndi.video/all/using-ndi/ndi-tools/ndi-tools-for-mac/video-monitor)
for the source and audio controls.

With both Macs on Wi-Fi, test each wireless hop separately by wiring one Mac at a
time when an adapter is available. The local reference probes exclude the access
point path; if they remain clean while the remote sound drops, the next boundary
to investigate is transport or receiver playout. On each Mac,
[Wireless Diagnostics](https://support.apple.com/en-gb/guide/mac-help/mchlf4de377f/mac)
can collect connection evidence. Apple documents opening it by holding Option
while opening the Wi-Fi menu and choosing Open Wireless Diagnostics.

Keep the original recording and its matching `.mov.ndi` file during diagnosis.
An unplayable MOV is not by itself evidence of lost audio. Inspect its actual
streams first: the diagnostic receiver recording used SpeedHQ video and stereo
48 kHz floating-point PCM. Its audio could be extracted even though QuickTime
would not play the movie. With FFmpeg available, extract without decoding video:

```sh
ffmpeg -i "recording.mov" -map 0:a:0 -c:a pcm_s16le "recording-audio.wav"
```

See the [FFmpeg manual](https://ffmpeg.org/ffmpeg.html) for stream selection and
audio codec options. Compare the WAV with the live sound. NDI's
[recorder](https://docs.ndi.video/all/developing-with-ndi/sdk/command-line-tools)
performs time-base correction, so recorded silence does not directly measure
raw packet loss or identify which side introduced a timing problem.

### Optional Windows timing capture

[NDI Analysis](https://ndi.video/tools/analysis/) is an official Windows utility
that measures incoming streams without video decoding. This helps distinguish
delivery problems from a receiver's decode/render/audio-device load.

On a Windows receiver with that utility installed, select the exact published
source name and collect both streams for ten minutes:

```powershell
NDIAnalysis.exe /source:"EXACT PUBLISHED SOURCE NAME" /csvvideo:"video.csv" /csvaudio:"audio.csv" /time:600
```

The [Analysis documentation](https://docs.ndi.video/all/using-ndi/utilities/analysis)
describes the CSV fields and supports separate audio and video exports. Compare
arrival intervals with the source timecodes. eucaly sends stereo 48 kHz audio in
960-sample blocks, so consecutive uninterrupted audio timecodes advance by 20 ms.
Its video cadence is 30 fps. Deliberate Stop/Start creates a new sender generation;
evaluate those intervals separately from uninterrupted playback.

| Observation | Next investigation |
| --- | --- |
| Local NDI audio and remote audio both contain the same silence | Source file, AVPlayer audio tap, mixer coverage or sender scheduling |
| Local NDI is clean; remote arrival intervals burst or stall | Sender-to-receiver transport, access point, interface routing and receiving host network load |
| Source timecodes also skip on the local receiver | Sender admission, mixer scheduling or dropped local receiver buffers; compare sender counters |
| Analysis timing is healthy but the production app's audio drops | Decode/playout buffering, clock handling, audio interface and receiver load |
| Ethernet is clean; one Wi-Fi endpoint introduces the gap | That endpoint's wireless hop and access point under the actual video traffic |

These are isolation steps, not proof of a particular cause. A missing frame at a
receiver can originate upstream; a large arrival delay alone does not identify
which device delayed it. Compare matching source timecodes across locations,
rather than subtracting unrelated machines' clock values.

NDI's [receiver performance counters](https://docs.ndi.video/all/developing-with-ndi/sdk/ndi-recv)
count frames discarded because the receiver could not dequeue them quickly enough.
They are not a direct Wi-Fi packet-loss counter. A growing receive queue suggests
the consumer is falling behind; continuous packet timestamps can still carry
silent samples.

## Repeatable local qualification

The late-joining-output regression reproduced missing unplayed PCM before the
NDI SDK: a shared tap had already delivered its preroll to the first destination
and discarded it before a second destination attached. The tap now retains
unplayed buffers with a delivery cursor per mixer. Retention stays within the
existing 8 MiB / 256-buffer limits, and completed playback history is pruned.
Existing consumers do not receive duplicate submissions.
Delivery cursors advance only after mixer admission succeeds; temporary
conversion-queue backpressure retains the batch for the next tap/clock refresh.

The steady remote comparison also exposed accumulating audio timestamp lag.
A dispatch timer may coalesce delayed callbacks; producing only one 20 ms block
per callback left the sample clock progressively behind video. The source eventually
hit its existing discontinuity guard and retired. The mixer now emits due blocks
against host time in bursts of at most four, within the bounded sender admission.
The existing severe-stall retirement behavior remains in place. The delayed-callback
regression checks contiguous samples and recovery toward the host clock; the steady
test also gates local audio age, rather than checking packet continuity alone.
The receiver stamps each SDK capture before scheduling its reply. Receiver age
and parent notification age are retained separately, so a delayed test callback
cannot be mistaken for the original audio arrival time.

Live PCM, supervisor/control IPC and helper work use user-initiated queues. The
app's live NDI PCM clock and each live helper own latency activities: one process's
activity does not describe the other process's work. Constructors acquire none.
This uses Apple's documented
[activity API](https://developer.apple.com/library/archive/documentation/Performance/Conceptual/power_efficiency_guidelines_osx/PrioritizeWorkAtTheAppLevel.html)
to prevent App Nap during live work, with
[latency-critical precision](https://developer.apple.com/documentation/foundation/processinfo/activityoptions/latencycritical)
for live audio/video handoffs. These activities allow idle system sleep;
the output coordinator continues to own system/display sleep policy. Stopping
the PCM bus releases its app activity. Normal helper shutdown ends
the activity after SDK cleanup, and exact-process termination bounds stalled work.
Queue capacities and discontinuity/overrun retirement are unchanged.

The windowless helper also needs an application task classification while doing
this explicit live work. Measurements found its requested user-initiated queues
and audio reader running at default priority instead. Apple's
[task policy implementation](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task_policy.c)
caps unspecified and non-UI application roles this way. The helper uses the
public `TASK_CATEGORY_POLICY` API to select `TASK_DEFAULT_APPLICATION` before
starting live NDI work; the owned child exits after cleanup. This permits its
existing per-thread QoS requests to take effect, without claiming foreground
status or assigning real-time priorities. AppKit activities and process launch
QoS alone did not remove the measured cap. The corrected helper reader was
observed at user-initiated priority during requalification; the requested
duration and audio continuity must still pass independently.

Mach receive ports use dedicated blocking reader threads. Kernel arrival wakes
those readers without waiting for a dispatch receive-source callback; no GCD
worker is parked in a receive or polling loop. A separate reader context avoids
retaining an idle mailbox. Control/frame messages enter their owner's serial queue
synchronously, bounding admission instead of accumulating delivery closures.
Per-message autorelease pools bound Foundation temporary-object lifetime.
Cancellation closes admission immediately and sends a nonblocking wake; the
reader destroys its port after any active callback finishes. A full mailbox
already has input to wake the reader, so cancellation does not need another slot.
Regressions cover idle release, refill during handling, and full-queue cancellation.

Timed-out sends are pseudo-received by Mach: copied destination and transferred
rights return as newly owned references. The bridge now destroys unsent messages
for the recoverable send errors, matching
[Apple's libsyscall cleanup](https://github.com/apple/darwin-xnu/blob/main/libsyscall/mach/mach_msg.c).
Freeing just the message bytes leaked those references, including failed surface
transfers. A regression fills the mailbox, repeats 64 timed-out sends and requires
unchanged send-reference counts on all three ports. The cancellation wake uses the
same cleanup.

The port constructor explicitly applies `MPO_QLIMIT`; setting the limit field
alone left the kernel default of five messages. A regression queries the actual
kernel limit and requires four.

Ownership fences close old-owner admission immediately. Their acknowledgements
wait asynchronously for already admitted old-owner audio calls. The regression reproduced a new-owner
picture passing the old fence while old-owner audio was stalled. The corrected
fence holds that picture while control remains responsive, and explicit Stop
still retires the exact stalled child within its deadline.
Audio fencing runs independently of the video SDK queue. A failed soak isolated
roughly 260 ms with PCM held behind video draining, exhausting the unchanged
eight-block admission bound. The corrected handoff lets the new owner's audio
proceed while a blocked video lane coalesces to the latest epoch. Video keeps
its previous SDK surface leased until the next async send or shutdown flush.
A deterministic blocked-video regression checks that new-owner audio still
submits, while the existing blocked-audio regression checks that old audio must
finish before acknowledging the handoff. Neither path waits on the UI thread.
Only one fence is in flight; rapid workspace transfers coalesce to the
latest admitted owner. New-owner video and PCM wait for that acknowledgement.
Queued drains resolve the latest admitted epoch before taking staged work, so
an older queued selection cannot discard the newest picture or relabel PCM.
The regression interleaves 100 ownership changes and frame submissions on one
helper. This retains the four-message kernel limit and eight-block PCM bound.

PCM handoffs use a separate private helper port with at most three blocks in
flight. The eight-block bound includes both staged and unacknowledged audio;
it is not eight blocks in each process. Audio acknowledgements share the frame
reply port, leaving its fourth slot for one outstanding render acknowledgement.
Ownership/status/shutdown remain on control ports. This avoids serializing each
20 ms block behind a complete IPC/SDK/acknowledgement round trip. The blocked-audio
regression fills the eight-block bound, checks that control/video and a companion
source still progress, then checks that one additional block retires only the
affected source within the existing exact-child deadline.
The private audio reader now handles validation, SDK submission and its reply
serially on that same thread. This removes control-to-worker-to-control dispatch
hops from each PCM block. Ownership selection shares only a short admission lock.
Stop closes new audio admission, and sender destruction waits asynchronously for
any accepted SDK audio call to finish; a blocked call remains bounded by exact-
process retirement. No SDK audio work runs on control or app UI queues.

Full-suite validation also exposed a controls-window focus issue: a stale native
key callback could replace the current workspace and its saved Dock reopen
identity. The controller now validates that it is still the current key window
before recording focus or permitting Confidence standby. A deterministic
regression reproduced both incorrect identities before this guard. This changes
no destination assignment and introduces no focus polling.

Run the opt-in app/SDK stress harness with the installed NDI runtime:

```sh
make test-ndi-stress
# Choose a longer run explicitly:
make test-ndi-stress NDI_STRESS_SECONDS=7200
```

Each run creates a separate directory under `build/ndi-stress/`, containing the
Xcode log/result bundle, JSON Lines checkpoints and process CPU/RSS samples. Each
bounded checkpoint is appended once, so longer runs do not repeatedly rewrite
their entire history or add increasing diagnostic load. It uses
owned test senders and Debug-only receiver helpers; no incoming receiver is added
to the Release app.

The harness transfers one source between video and lyrics, keeps a companion
source on one continuous movie, and deliberately stops/restarts both outputs. The
audio receiver reports channel RMS, timecode gaps, SDK receive drops and queue
depth. RMS distinguishes received silence from missing or late blocks. Sender
`audioBlocks` and `lastAudioSample` only establish SDK submission, not audible
content or physical sound delivery. After each receiver's startup, the stationary
output must acquire no further silent blocks, timecode gaps or SDK dequeue drops.
Intentional route/stop boundaries are inspected separately. An earlier short-loop
fixture produced silence around end-of-file seeks; it was replaced so those
source transitions cannot weaken the continuous-audio gate. Interrupted runs
remain retained and are not sustained passes.

For a separate remote comparison with no workspace switches or planned restarts:

```sh
make test-ndi-diagnostics
```

This publishes one diagnostic source for ten minutes, with moving 1080p30 video
and different continuous tones in the left/right channels. Its fixture is one
long movie, so the measurement does not include end-of-file seeks. Select the
exact name saved in that run's `source.txt` on the second machine. The local
reference audio/video probes keep collecting timestamps and RMS at the same time.
Compare audible gap times or remote Analysis CSVs against `checkpoints.jsonl`
(older retained runs use a JSON array in `checkpoints.json`).
The test source closes automatically at the end; it does not edit saved outputs,
workspaces or the operator's Current.

The steady checkpoints include UTC observation time and sender/probe failures,
including the measurement that fails a gate. Audio submission age measures how
far the first sample of a block is behind this Mac's host clock immediately
before the helper calls NDI. SDK call duration measures the call itself. Their
maximum values preserve short stalls between checkpoints. Local receiver age
also includes SDK buffering, IPC and the diagnostic reader; its pump runs off
the UI thread so checkpoint writing cannot delay dequeuing. These ages are
comparable only on the sending Mac and must not be subtracted from a remote
Mac's unrelated host clock.

For per-block timing on the diagnostic, run:

```sh
python3 scripts/test-ndi-stress.py --mode steady --seconds 600 --trace-audio
```

Debug-only `audio-trace-<pid>.csv` files record admission, IPC, SDK entry/return
and acknowledgement times on the same host clock. They contain timing/sample
positions, generation IDs and queue depth, without recording PCM. Generation IDs
separate concurrent destinations and restarts when using `--mode switches`.
Normal runs do no trace I/O;
Release builds exclude the trace implementation. The trace uses a bounded
8,192-record buffer and writes batches from a separate utility queue; disk writes
never run on the audio/control paths. A `trace-overflow` row marks lost records.
Forced process exit may lose the last unflushed batch, so evaluate completed hop
pairs and the retained failure checkpoint together.

Use NDI Test Patterns as an independent sender comparison when it is installed.
Choose its source in the same receiver and compare the continuous tone. A static
test pattern can generate much less traffic than moving video, so a clean tone
there does not establish that the same Wi-Fi path can sustain the production
video workload. Keep the normal and Low Bandwidth observations separate.

## Physical comparison on 21 October 2026

The receiver was an M1 MacBook Pro (2020, 16 GB) running macOS 27.0.1 and NDI
Video Monitor 6.3.2 through its built-in speakers, plugged into power without
Low Power Mode. Ordinary local audio/video playback in QuickTime was clean.
Treat that as the general playback control; the observed fault is within the
NDI paths. The initial comparisons used Wi-Fi at both ends; a wired receiver
comparison became available later, as recorded below.
The radios reported channel 157 at 5 GHz / 80 MHz, link rates of 866–867 Mb/s,
and strong signals (sender −40 dBm, receiver −33 dBm). These are link statistics,
not measured end-to-end delivery guarantees.

A 600-second moving-video/tone run completed its local raw-receive gates with
zero silent blocks, timecode gaps or SDK receive drops. The remote 20.52-second
recording nevertheless contained 24 post-startup silent intervals in both
channels, totaling 2.977 seconds; the longest was 503 ms. The user confirmed the
same frequent gaps in the extracted WAV. This excludes the physical speakers
as the sole cause, while leaving transport, upstream timing and receiver
time-base/playout processing open.

The official Chroma Zone Plate reference initially sounded continuous, then
also developed frequent gaps. Restarting Video Monitor did not restore a clean
first minute. Its measured median traffic was about 3.15 Mb/s, versus 62.6 Mb/s
for the moving eucaly sender in a separate capture window (one-second deltas).
The static reference therefore does not qualify the heavier moving-video path.
The findings do not establish that Wi-Fi or Video Monitor alone is responsible.

The M1's own local Test Patterns source also developed audio gaps in Video
Monitor after initially sounding continuous. That reproduction does not need
eucaly or the inter-Mac Wi-Fi path. It leaves NDI source timing, SDK clock
synchronization and Video Monitor playback open; ordinary Mac playback remains
the clean control.

An independent command-line measurement on the sending Mac used two separate
audio-only NDI receiver connections: raw capture and the SDK frame synchronizer,
pulled at 48 kHz in 960-sample blocks from a monotonic host clock. It rendered no
video and opened no audio device. After a two-second startup exclusion:

| 180-second source comparison | Raw capture | SDK clocked output |
| --- | --- | --- |
| This Mac's official Test Patterns | 1,781 blocks, no silent PCM or timecode gaps, no SDK dequeue drops | 8,899 blocks, no fully silent blocks |
| M1's official Test Patterns over Wi-Fi | 1,779 blocks, no silent PCM or timecode gaps, no SDK dequeue drops; longest arrival interval 448 ms | 8,899 blocks, including 3,644 fully silent blocks; longest measured wake delay 22.5 ms |

The raw reference confirms continuous source samples on that connection. These
are separate receiver connections, so they cannot prove delivery to the clocked
connection was identical. The SDK frame synchronizer
[inserts silence when current audio is unavailable](https://docs.ndi.video/all/developing-with-ndi/sdk/ndi-recv).
The result narrows investigation to NDI delivery timing and clocked playout;
it does not identify the access point, SDK or receiver as the sole cause.
Invalid timecodes attached to inserted silence are not raw source timecode gaps.

The official Free Audio 6.3.2 receive-only utility provides a further receiver
comparison independent of Video Monitor. Keep the same local Test Patterns
source, quit Video Monitor, and listen through the same built-in speakers.
Record its result separately from the host-clock measurement above.
The initial two-minute local Free Audio comparison was clean, but gaps appeared
in the subsequent ten-minute local comparison. The shorter result does not
establish a Video Monitor-only defect. Inter-Mac transmission, video decoding and
eucaly are not required to reproduce this local NDI failure. The receiver's
Wi-Fi was still enabled, so this does not exclude its effect on NDI timing.
Ordinary local QuickTime playback remains the clean control; a repeated local
NDI comparison with Wi-Fi disabled keeps that question open.
The same Free Audio receiver then had gaps when receiving the sending Mac's
official Test Patterns over Wi-Fi, with Video Monitor closed. Video decoding
and the moving eucaly workload are therefore not required for that remote
failure. It does not establish that every Video Monitor gap has the same cause.

A separate low-rate ICMP comparison to the M1 received all 300 replies, with
round trips from 5.822 to 283.008 ms (mean 53.701 ms). ICMP is a different flow
from NDI, so this supports investigating delivery jitter without measuring NDI
packet loss or proving which endpoint/access point introduced a delay.

The receive-only TCP comparison uses NDI's documented
[`NDI_CONFIG_DIR` process setting](https://docs.ndi.video/all/developing-with-ndi/sdk/platform-considerations)
and a temporary configuration directory. Disabling Multi-TCP, reliable UDP and
unicast UDP selects the documented
[base TCP fallback](https://docs.ndi.video/all/developing-with-ndi/sdk/configuration-files).
It does not alter saved Access Manager, Wi-Fi or system audio settings. Stop the
comparison normally and retain the result independently of the default run.
The M1 still had audible gaps with this isolated TCP comparison. TCP is not a
validated remedy, and no transport override is added to eucaly.

The M1 was then connected to LAN with its Wi-Fi off. Free Audio receiving the
same sending Mac Test Patterns was continuous after startup during the initial
two-minute wired-receiver comparison, and remained continuous for ten minutes
total. The sender remained on Wi-Fi, so removing the receiver's wireless hop
stopped the frequent remote gaps in this comparison. The M1 can therefore
sustain clean NDI audio playback with this network setup. This does not yet
qualify the heavier eucaly video stream or explain its earlier local Test Patterns
source failure while Wi-Fi was enabled.

A ten-minute native measurement of the sending Mac's official Test Patterns,
received locally on that same Mac, remained clean after startup: 5,980 raw
100 ms blocks and 29,899 clocked 20 ms blocks had no fully silent blocks. Raw
sample timecodes were continuous and SDK dequeue drops stayed at zero. The
largest raw receipt interval was 158.76 ms, and the largest clock wake delay was
120.54 ms. This is a measurement before a sound device, using two separate
audio-only NDI connections; it does not qualify the M1's NDI or audio path.
Evidence is retained in
`build/ndi-stress/reference-local-ten-minute-20261021/`.

Local stress failures are retained separately from earlier successful evidence:
an audio admission overrun at 433 seconds, an ownership handoff failure at
266 seconds, and further audio overruns during requalification. The ownership
failure has a deterministic rapid-transfer regression and the acknowledged
fence change above. Audio traces also captured acknowledgement scheduling delay
after the SDK returned, so a fast SDK call alone does not qualify local delivery.
Failed or partial runs must not be counted as sustained passes.
Direct delivery on the owner queue also failed requalification after 168.89
seconds, and a subsequent traced run captured roughly 140 ms between sending
an audio IPC packet and decoding it in the helper. A later failing window had
no disk page-ins in the affected app/helper. These observations narrow the
remaining local scheduling investigation; neither is a successful soak result.

The subsequent task-classification correction completed a 600.30-second local
moving-video/tone run with 30,020 received audio blocks, no silent blocks,
timecode gaps or SDK dequeue drops, and confirmed sender exit. The maximum
checkpoint receiver age was 56.05 ms, the maximum pre-SDK submission age was
97.99 ms, and the maximum SDK audio-call duration was 0.76 ms. The helper's audio
reader was observed at user-initiated priority throughout the external thread
measurements. Its surface pool stayed within four leases. Evidence is retained
in `build/ndi-stress/steady-task-role-20261021/`. Temporary receive-syscall timing
instrumentation used in that run was then removed before final requalification.
This result is independent of physical M1 playback and does not qualify Wi-Fi.

The final independent-fence implementation then completed a 902.70-second
continuous-audio workspace/output stress run: 342 cycles, 2,109 transfers and
148 deliberate output restarts. All 150 created sender helpers retired; sender
and probe failure lists were empty. After each receiver's startup, the stationary
output acquired no unexpected silent blocks, sample-time gaps or SDK dequeue
drops. The maximum surface-pool occupancy was four, pre-SDK audio age was
92.72 ms, SDK audio-call duration was 4.88 ms, and measured stop duration was
161.63 ms. These are measured maxima for this run, not deadline guarantees.
Source-file hashes were recorded before the run and verified unchanged after it.
Evidence is retained in
`build/ndi-stress/sustained-independent-fences-final-20261021/`, including
`summary.json`, append-only checkpoints, process measurements and the Xcode
result bundle. This is local SDK qualification; the M1's playback of this final
moving-video sender and the earlier Wi-Fi-enabled local-source gaps remain
separate physical checks. The two-hour and minimum-supported-macOS gates remain
open.

The exact protocol-15 implementation also passed `make test`: 562 XCTest cases
(two opt-in sustained tests skipped in the ordinary suite), one Swift Testing
case and 108 offline release/feed regressions, with no failures. The sustained
test above was run explicitly and completed separately.

`make build` then archived and exported the signed app to `~/Applications`.
Deep/strict signature verification passed; both executables were arm64 and the
app retained its macOS 14 minimum. Only the NDI helper had the library-validation
exception, and no NDI runtime was bundled or linked into the main app. The signed
helper's read-only `--check-runtime` command loaded the installed, vendor-signed
NDI 6.3.2 runtime successfully under a 20-second process deadline. Results are
retained beside the soak in `signed-build-checks.json`.

## Independent local audio monitoring

Workspace → Monitor Audio Locally now controls local listening separately from
NDI programme gain. Existing and new workspaces default to off. Both video and
background music are silent locally for NDI-only playback; native projection
retains ordinary audio while open. The same option is present in the native
Workspace menu and workspace toolbar menu, with no shortcut. Programme mute and
music volume still affect both destinations. Standalone local music remains an
explicit playback action; output closure or transfer cannot invent that action.

Local AVPlayer volume is configured before the first play, independently of the
logical gain applied to tapped PCM. Monitoring changes do not replace players,
seek, transfer content or restart senders. A real-player regression verifies
nonzero, continuous tapped PCM while local volume is zero, unchanged PCM gain
through repeated local-volume changes, and independent programme mute/unmute.
An actual SDK receiver also verifies unchanged background-music RMS through local
monitoring changes, workspace transfers and sender restart/reconnection.

`make test` passed 575 XCTest cases (two opt-in sustained tests skipped), one
Swift Testing case and 108 offline release/feed tests. The subsequent explicit
901.82-second sustained run passed 344 cycles, 2,121 workspace transfers, 148
output restarts and 687 local-monitoring changes. All 150 sender helpers retired.
The stationary receiver had no unexpected silent blocks, audio-clock gaps or SDK
dequeue drops; sender and probe failure lists were empty. Measured maxima were
30.29 ms for stopping, 62.03 ms for pre-SDK audio age and 0.85 ms for an SDK audio
call. The surface pool stayed at four leases. All 188 recorded source/tool hashes
remained unchanged through the run. Evidence, including `summary.json`, logs,
checkpoints, process measurements and `Stress.xcresult`, is retained in
`build/ndi-stress/local-audio-monitoring-20261021/`.

The switching receiver also records timestamp gaps during the deliberate
transfer/restart workload: its final connection reported one gap of 60 ms.
Those intervals are not uninterrupted-playback qualification. The zero-gap
result above applies to the stationary stream after each receiver's startup;
this test does not establish gap-free audio across every handoff boundary.

These are local real-SDK measurements, not a physical Wi-Fi qualification or a
guarantee of maximum latency on other systems.

The signed archive/export also passed. Deep/strict signature verification and
the signed helper's bounded read-only runtime check succeeded. Both executables
remain arm64, the minimum macOS version remains 14.0, and only the helper has the
library-validation exception. No NDI runtime is bundled or linked into the main
app. `signed-build-checks.json` and `signed-build.log` retain these checks beside
the sustained measurements. The rebuilt app is in `~/Applications/eucaly.app`.
Commit preparation subsequently removed one redundant blank EOF line in the
stress-test harness; `commit-preparation.json` records both hashes. No executable
code changed after qualification.

## Measuring a specific movie

The steady diagnostic can read an operator-supplied movie instead of generating
the checkerboard/tone fixture. Use a stable copy that will not be overwritten
during playback. The test never rewrites or removes an external movie, and its
duration must exceed the requested measurement by at least five seconds.

```sh
python3 scripts/test-ndi-stress.py --mode steady --seconds 180 \
  --media /tmp/ndi/stable-copy.mp4 --trace-audio --observe-only \
  --source-name 'eucaly movie diagnostic'
```

`--observe-only` is permitted only with an explicit movie in steady mode. It
records audio timecode gaps and SDK dequeue drops through the full observation
instead of stopping at the first such event. Helper health, receiver/player
liveness, exact-child shutdown and the four-surface limit remain checked. A
successful observation is **not** an audio qualification pass. Ordinary steady
and workspace-switch qualification retain their strict assertions.

Actual-media checkpoints include the movie path, media time, player state,
local volume, audio/video arrivals, silence intervals and receiver counters.
Unlike the generated continuous-tone fixture, real movies can contain intended
silence and arbitrary colours. Compare them with an independent audio decode
before classifying any silent block as a fault.

The opt-in Debug trace records channel RMS at the copied source tap, converter
output, mixed programme PCM, SDK audio entry and raw SDK receiver, plus mixer
coverage. It retains no PCM content. Join SDK/receiver records by source sample
time, and join mixer coverage to tap/converter records by media sample ranges.
Audio levels alone cannot detect every waveform discontinuity. Trace collection
is bounded, and normal runs and Release builds perform no trace I/O.

The 313-second `worship-countdown-5min-4k.mp4` case used a 3,840 × 2,160 H.264
30 fps movie with stereo 48 kHz AAC (SHA-256
`7a60db1cd500b9b92063395c8e042b4979accad36175fa4cfcde49cd89bb2a35`).
Both FFmpeg and Apple's audio-only AVAssetReader decode found continuous audio
between the startup and ending silence, including the implicated 128–130 second
section.

An initial actual-media run failed near 291 seconds on a local receiver
timestamp gap of 620 ms. Sender admission and SDK-entry sample clocks remained
continuous, so that observation does not locate the missing delivery upstream
of the SDK. A separate 280 ms zero-valued run near media time 128.7 seconds is
confounded: the diagnostic movie's filesystem modification/change times were
23:36:22 UTC, immediately before the added-silence checkpoints at 23:36:23–24.
This temporal match does not prove how the file was replaced or that the write
caused silence. Preserve this failed run rather than count it as a pass.
Evidence: `build/ndi-stress/countdown-original-20261021/`.

A subsequent 180.43-second observation used a separate stable copy. No stage
acquired zero-valued audio after startup; there were no mixer coverage losses,
receiver timestamp gaps or SDK dequeue drops. Across 8,935 matched blocks,
mixer and SDK-entry channel RMS agreed exactly; maximum SDK-to-receiver RMS
difference was 0.000017. This did not reproduce the earlier failures and does
not establish uninterrupted playback across the whole movie or on the M1.
Evidence: `build/ndi-stress/countdown-energy-20261021/analysis.json`.

### M1 receiver timing comparisons

The affected receiver was an Apple M1 running macOS 27.0.1 and NDI Video Monitor
6.3.2. Wi-Fi was off. Its Apple USB Ethernet adapter negotiated full-duplex
100baseTX and reported only 10/100 media support. This does not meet NDI's
[Gigabit network guidance](https://docs.ndi.video/all/getting-started/white-paper/network-layout),
but the comparisons below do not establish link capacity as the cause.

A silent diagnostic measured raw and SDK-frame-synchronized audio on separate
connections while Video Monitor received the normal moving countdown. In the
180-second comparison, 8,820 overlapping raw blocks had identical channel RMS,
silence classifications and sender SDK timestamps on the Mini and M1. Neither
raw receiver lost sample timecodes or reported SDK dequeue drops. Matching RMS
does not establish per-sample byte identity because PCM content was not recorded.

The M1's synchronized output contained 34.82 seconds of silence versus 3.94
seconds locally; 3.36 seconds also existed in raw audio at the natural movie
loop boundary. After conservatively excluding that boundary and two seconds
around every probe wake delay over 5 ms, the M1 still had 15.44 seconds of
additional silence in 271 complete events, while the corresponding qualified
local observation had none. The largest raw SDK submission interval was
44.79 ms on both machines, but raw capture arrival intervals exceeded 60 ms
333 times on the M1 and ten times locally. These measurements are before any
speaker device and do not identify which downstream component delayed delivery.
Evidence:
`build/ndi-stress/countdown-receiver-20261021/countdown-mini-m1-comparison-20261021.json`.

Video Monitor was then closed for three controlled 120-second comparisons.
One raw A/V receiver and two audio-only connections ran in each case. The same
movie section was replayed. Video was decoded by the SDK and freed immediately,
without rendering or speaker playback. Network figures below are approximate
application byte rates, including the two constant audio-only connections;
they exclude link overhead. Startup audio was excluded from the silence totals.

| Receiver mode | Actual video | Mean combined traffic | Raw A/V silence / sample gaps | SDK synchronized silence |
| --- | --- | --- | --- | --- |
| Default transport, high bandwidth | 1920 × 1080 UYVA, 30 fps | 73 Mb/s | 0 / 0 | 21.94 s |
| Default transport, low bandwidth | 640 × 360 UYVA, 30 fps | 20 Mb/s | 0 / 0 | 23.46 s |
| RUDP disabled for these processes | 1920 × 1080 UYVA, 30 fps | 72 Mb/s | 0 / 0 | 21.46 s |

The last case used only the documented receiver-side
`ndi.rudp.recv.enable=false` override in a temporary `NDI_CONFIG_DIR`.
Connection-level byte counters verified that multi-connection TCP carried the
media, with only small UDP discovery traffic. Saved settings were untouched,
and Video Monitor was reopened normally afterward. Lower video traffic and
verified TCP did not resolve the measured synchronization gaps. Neither an
adapter-only conclusion nor forcing TCP in eucaly is justified by these tests.
Separate connections and successive captures remain important limitations.

Evidence is retained under `build/ndi-stress/countdown-receiver-20261021/`,
including `m1-countdown-results-20261021/`, `m1-av-high-20261021/`,
`m1-av-low-20261021/` and `m1-av-rudp-off-20261021/`. Its `manifest.json`
records original locations, byte counts and verified SHA-256 hashes; copied
analysis files retain their original input paths. The accompanying README
records the measurement limitations. SDK capture-return timing alone cannot
distinguish network arrival delay from delay within the receiver SDK or its
scheduling.

Two bounded packet-header captures measured the next boundary. The operator
confirmed that the M1 was connected directly to a Netgear Nighthawk R7000P,
without mesh; the Mini sender remained on Wi-Fi. After startup, raw audio was
nonzero with continuous sample timecodes throughout each qualified overlap.

| Capture | Qualified overlap | Packet gaps over 60 ms (range; median) | Raw pauses overlapping packet gaps | Separate FrameSync silence |
| --- | --- | --- | --- | --- |
| First | 17.693 s | 33; 71.308–100.463 ms; 89.413 ms | 33 of 34 | 4.00 s in 67 events |
| Idle repeat | 17.675 s | 33; 72.906–121.279 ms; 89.084 ms | 33 of 36 | 3.56 s in 65 events |

The packet-gap starts recurred at median intervals of 528.1 ms and 528.8 ms,
respectively. The first capture, at 00:40:43–00:41:03 UTC, overlapped offline
Python/Git release regressions on the sender; Xcode audio/video tests started
afterward. The 00:45:22–00:45:42 UTC repeat ran without builds or tests, after
the earlier low-rate pings had finished. The packet-boundary pattern therefore
reproduced without concurrent tests. All captured headers parsed successfully,
with zero reported kernel capture drops.

Most raw SDK pauses coincide with gaps already visible in the receiver's
kernel packet-capture timestamps, so those delays are not confined to SDK
dequeue timing. The responsible component remains unproven. Capture timestamps
include NIC/driver/kernel behavior; ports and rates do not identify individual
SDK connections, and the raw and FrameSync connections remain separate.
FrameSync silence was not an immediate, one-to-one match to the packet gaps.
These results establish neither an adapter-only nor a Wi-Fi-only cause.
Evidence and independent parser/alignment reviews are retained under
`build/ndi-stress/countdown-receiver-20261021/packet-first/` and `packet-idle/`,
each with a SHA-256 provenance manifest.

A subsequent control stopped only the Online NDI output, verified its helper
had exited, and retained the other workspace's live output. All 80 low-rate
ICMP requests on each path returned in both conditions:

| Path | NDI live: mean / maximum RTT | Online NDI stopped: mean / maximum RTT |
| --- | --- | --- |
| Mini → gateway | 13.727 / 96.009 ms | 13.642 / 93.988 ms |
| Mini → M1 | 53.430 / 129.786 ms | 13.150 / 91.612 ms |
| Wired M1 → gateway | 34.706 / 97.852 ms | 0.753 / 6.138 ms |

The sender-to-gateway path still had latency spikes with this NDI source off;
the other paths improved in this comparison. ICMP and router reply priorities
differ from forwarded media, and these sequential logs cannot locate individual
NDI gaps. Online was restored afterward. The original logs and context are
retained in `build/ndi-stress/countdown-receiver-20261021/ping-controls/`.
A comparison with both Macs on Ethernet was unavailable because the sender
could not be reached with an available cable. The latency evidence supports
investigating the sender's Wi-Fi path, without establishing that it explains
every NDI audio observation.

The operator then set AirDrop receiving to No One and Handoff Off on the Mini,
and requested that both remain Off. The same installed app/source continued;
the movie was sought to its beginning before a separate 60-second observation.
After excluding each probe's first two seconds, observed FrameSync silence
fell from 5.32 seconds in 1,399 blocks in the earlier idle comparison to 1.14
seconds in 2,900 blocks, approximately 19.0% to 2.0% of requested audio samples.
The common 57.950-second Off interval contained 18 silence events and 17 raw
arrival pauses over 60 ms; its largest raw pause was still 219.549 ms. Raw
samples stayed nonzero, with continuous source timecodes and no SDK dequeue
drops. The earlier regular arrival-pause pattern did not persist throughout
this short comparison, but residual gaps remained.

The consumer's wake-delay distribution also changed: its Off maximum was
9.961 ms, and 1,679 of 2,897 common observation blocks woke over 5 ms late.
Applying the earlier strict 5 ms cutoff with two-second guards excludes every
Off observation. Strict wake-qualified evidence is therefore **unavailable**,
not a zero-silence result or an audio qualification pass. The ordinary observed
silence counts above remain useful, with that scheduling limitation.

Both 300-request Off ICMP comparisons returned every reply. Mini-to-gateway
mean RTT was 4.622 ms, with a 6.461 ms 95th percentile and 96.718 ms maximum;
Mini-to-M1 mean RTT was 13.961 ms, with a 36.575 ms 95th percentile and 85.401 ms
maximum. These distributions improved against the earlier 80-request live
comparisons, while occasional spikes remained. Both settings changed together,
the runs were sequential, and their durations and movie sections differed;
the user requested no reversal. This observation does not settle the complete
cause or establish a remedy. The longer Off observation and actual Video Monitor
listening were evaluated separately. Evidence, event distributions and the explicit
unavailable qualification are retained in
`build/ndi-stress/countdown-receiver-20261021/peer-features-off/`.

A subsequent 360-second observation retained the Mini's settings Off throughout.
After startup, raw audio contained 3.12 seconds of natural movie-loop silence,
while FrameSync contained 8.64 seconds of silence. Excluding the raw quiet
windows with one-second guards left 5.48 seconds in 352.40 seconds of requested
audio; half-second guards gave 5.50 seconds. Applying the prior 5 ms wake cutoff
and two-second guards left 2.82 seconds in 258.32 seconds, **1.09% residual
instrumented silence**, so this was not a clean audio qualification pass.
Raw source timecodes stayed continuous and SDK dequeue drops stayed zero.
Sender SDK submission intervals were 15.322–25.878 ms despite raw receiver
arrival pauses up to 245.280 ms.

This run mixed receiver conditions. Only M1 AirPlay Receiver was newly turned
Off during it, reported around 00:59:32 UTC; M1 AirDrop No One was preexisting,
as the corrected operator journal records. With twenty-second guards around
that approximate report and one-second natural-silence guards, observed
pre/post silence was 1.89% and 1.04%. After the strict wake exclusions it was
0.92% and 0.98%, which does not establish an additional AirPlay Receiver benefit.
Ten-second action guards and half-second natural guards are retained as
sensitivity checks. Cross-Mac action timing was not precisely calibrated, and
movie complexity changed over time. Before the M1 AirPlay Receiver change, the
operator described Video Monitor as noticeably better and continuous after
the Mini changes. That subjective report does not establish uninterrupted
listening throughout the six-minute measurement. Residual instrumented silence
and the earlier local-only NDI gaps remain separate limits. All settings were left
as requested. The mixed-run evidence, corrected journal, clock alignment and
segmented analysis are retained in
`build/ndi-stress/countdown-receiver-20261021/peer-features-off-sustained/`.

### Opaque video bandwidth reduction

This movie requires AVFoundation's BGRA colour conversion because its source
matrix is unmarked and its transfer function is sRGB. Colour conversion and
opacity are independent: a proven opaque local H.264 track can keep that
conversion while omitting an unnecessary transmitted alpha plane. The sampler
now marks those frames opaque only for one uncomposed track with consistent
negative alpha metadata. Unknown metadata, other codecs and compositions retain
the alpha path. Item replacement creates a separate sampler and cannot inherit
the previous item's proof.

Full-canvas opaque frames can use UYVY. Transparent fit gutters, text, unknown
BGRA inputs and Hide/Clear still use UYVA. Focused tests exercise actual H.264
BGRA decoding, packing changes, retained surfaces and replacement by a
composition. This is a bandwidth optimization, not an established audio-gap
fix: the 20 Mb/s low-bandwidth receiver comparison above still contained gaps.

Validation on 21 October passed 582 XCTest cases with four opt-in skips, one
Swift Testing case and 108 offline release/feed regressions. The focused video
input/packing checks passed 21 cases. Separate real-player AAC observations at
44.1 and 48 kHz each passed 30 seconds, alongside irregular-buffer resampling
coverage. Startup measurement races in the late-join and local-monitor tests
were corrected using queue completion and PCM sample clocks; each corrected
test passed ten repetitions without relaxing its audio thresholds. Evidence is
retained under the receiver archive's `validation/` and `test-fixtures/` folders.

The physical receiver comparisons used the previously installed
`3b0f4cbe` build throughout. The opaque-video optimization was not active in
those comparisons and must not receive credit for their network improvement.
