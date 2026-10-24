# Network output architecture

NDI and OMT are independent SDK adapters beneath one shared network-output
engine. A workspace owns its accepted Current and media runtime. Each network
destination owns its sender identity, helper process, admission and teardown.
Neither protocol implements the other.

## Source ownership

| Location | Responsibility |
| --- | --- |
| `eucaly/Output/Network/` | Real network routing, state, settings and native settings editor |
| `eucaly/Output/Network/Audio/` | Program PCM distribution and the single explicit music route |
| `eucaly/Output/Network/Media/` | Accepted content, shared acquisition, preparation and frame clocks |
| `eucaly/Output/Network/IPC/` | SDK-free wire values, authenticated Mach capabilities and exact-child supervision |
| `eucaly/Output/Network/Diagnostics/` | Common bounded audio trace |
| `eucaly/Output/Network/Transports/` | Protocol metadata and wire telemetry values; no SDK loading in the app |
| `eucalyNetworkHelper/Core/` | Service, admission, submission worker and neutral adapter contracts |
| `eucalyNetworkHelper/Rendering/` | Shared text/media composition, packed pixels and bounded GPU leases |
| `eucalyNetworkHelper/Transports/NDI/` | Installed NDI runtime verification, SDK calls and buffer consumption |
| `eucalyNetworkHelper/Transports/OMT/` | Bundled OMT runtime verification, SDK calls, enqueue statistics and optional history |
| `eucalyTests/Network/Shared/`, `NDI/`, `OMT/` | Shared contracts and separate protocol regressions |

`OutputCoordinator` calls a real `NetworkOutputDriving` implementation.
`NetworkOutputRouter` sends accepted workspace content through
`NetworkHelperSupervisor`. The helper's `NetworkHelperService` owns rendering
and control; `NetworkSubmissionWorker` owns the continuous submission clock and
bounded admission. `NetworkHelperRuntime` is the composition root selecting one
adapter that implements `NetworkRuntimeAdapter`.

SDK handles and bridge calls are private to their matching adapter. The common
worker does not collect vendor counters, maintain OMT history, interpret vendor
C structures or use protocol-specific errors. Adapters return immutable status
observations; applying those observations under the report lock only copies
values and never calls an SDK. Probe results use neutral Swift values.

There are no NDI-to-network or OMT-to-NDI compatibility typealiases, duplicate
coordinator properties, old start/settings wrappers or duplicate rendering and
playback engines. Protocol-specific destination accessors and saved enum cases
remain meaningful: `.ndi` and `.omt` identify different transports.

## Lifetimes and SDK contracts

The workspace retains one program player and reference-counted samplers shared
by its native and network consumers. Moving or closing controls does not own
those resources. Losing one destination releases only its consumers. Routing
retains explicit preflight, workspace identity and content epochs; it never
starts a stopped sender or changes the music route.

The video-consumption contract is explicit. NDI borrows the raw picture until
the next send or flush completes. OMT consumes raw pixels synchronously. The
worker retains each lease according to that contract, including the previous
NDI borrow through the next call. Packed composition, four surface leases,
latest-picture coalescing and conservative alpha remain shared.

Audio stays on its dedicated reader and continuous clock. Ownership fencing
closes old admission immediately; admitted audio finishes before SDK destruction.
Control and Stop do not wait behind SDK video work. OMT's video observations are
collected on the video lane, and its audio observations on the audio lane.
Counters retain their SDK-specific limitations and do not claim delivery.

The `eucalyNetworkHelper` executable uses the signing identifier
`com.suku.eucaly.network-helper`. Its authenticated bootstrap chooses exactly one
SDK. Only this helper has the library-validation exception needed for the
separately signed NDI runtime. OMT still loads only the verified bundled
libraries. The UI process loads neither SDK.

## Stable data and validation

This extraction does not migrate operator data. Document version 7 retains the
saved `.ndi`/`.omt` cases and `_0` settings payloads, all IDs, appearance and
workspace assignments, preference keys, migration backups and music routing.
IPC remains version 17/build `network-omt-1` with the same keys, raw values,
FourCCs and bounds. The existing opt-in diagnostic environment keys and CSV
schema remain stable, including `EUCALY_NDI_AUDIO_TRACE_DIRECTORY`.

`NetworkSerializationTests` decodes fixed pre-refactor JSON rather than creating
its fixtures with the current encoder. It checks canonical round trips for
saved destinations, authenticated bootstraps and representative IPC packets.

`make test` runs `scripts/test-network-architecture.py` before app regressions.
The structural check rejects bridge APIs outside the matching adapter,
cross-protocol adapter dependencies, protocol-owned shared declarations and
compatibility aliases. It complements compilation, real-SDK round trips,
lifecycle tests and independent architecture review; it does not prove runtime
delivery or physical performance.

Use `make build`, `make test` and `make test-codex-agents` for integrated changes.
NDI/OMT runtime, device and sustained-qualification limits remain documented in
`ndi-runtime.md` and `omt-runtime.md`.
