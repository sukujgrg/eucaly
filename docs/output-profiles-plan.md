# Eucaly output profiles implementation plan

Eucaly will keep its text editor, library, Preview and Current workflow while gaining several outputs with independently configured layouts and visual backgrounds. External apps will be able to present directly through a generic interface. Eucaly's normal presentation and slide-clearing actions will reclaim or blank those outputs. The existing AltView sender remains supported.

Implementation belongs on `codex/output-profiles`. Finish this plan before starting application changes. Work on eucaly first; ViewTheWord and AltView client changes are separate follow-up work.

## Scope and defaults

The first implementation has one presentation output group. Its enabled destinations follow one explicitly selected live source through different profiles. Local eucaly sessions and authenticated external connections are sources. Independent simultaneous sources in separate groups can use the same boundaries later.

Built-in profiles are Audience, Confidence, Meaning, Translation, and Lower Third. Audience preserves all six existing media types. Confidence starts with current and next text, component labels, clocks, countdowns, and media status or playback information. Meaning and Translation select their named components without substituting primary text when a component is absent. Lower Third composes selected text near the bottom of a configured canvas. Local screen output uses a configured background or key colour; transparent video delivery requires a later frame-output adapter. Existing AltView lower-third delivery continues using AltView's own templates.

External input initially supports structured text on the same Mac. This is sufficient to prove direct scripture, lyrics, and announcement presentation without modifying external apps during the eucaly implementation. The implementation supplies a reference sender and protocol fixtures. Remote input, external media transfer, NDI, SDI, and installable executable plugins are later extensions. Built-in adapters use explicit interfaces from the start.

## Operator behavior

The external path has no Preview, Load to Current, or manual takeover step. An external app's explicit Present command sends complete live content and takes the configured output group. Eucaly retains its own Preview, Current document, and selection while an external source is live.

Eucaly remains in control through its ordinary commands:

| Action | Result in the output group |
| --- | --- |
| Browse, edit a draft, refresh a file, or select a Preview slide | Updates local preparation only; external output continues. |
| Load Current with every output stopped | Loads locally without opening a display or taking output. |
| Load or Switch Current while the output group is running, including external presentation | Takes the group for that eucaly session and presents the loaded content. |
| Show Slides or explicitly activate a Current slide, including the same slide | Takes the group for that session and renders Current through enabled profiles. |
| Navigate Current during visible presentation | Takes or retains the group and presents the selected slide. Treat a visible external presentation as live for this explicit local action. |
| Navigate Current while group slides are hidden | Updates local selection privately; does not reveal slides or reclaim output. |
| Clear Current | Clears the local document, revokes external ownership, and clears group slide content. Visual backgrounds and independent audio retain their normal behavior. |
| Hide Slides or Escape | Revokes external ownership and hides audience, lower-third, and companion slide text. Confidence retains the last presented text with a Hidden indication. No previous source is automatically restored. |
| Show or Hide Slides shortcut | Uses the active group's visibility: visible means Hide; hidden means Show local Current and reclaim. |
| Clear Background Visual shortcut | Clears visual backgrounds across the enabled outputs in the group. Retains slide content and independent audio. |
| Clear Background Audio shortcut | Clears eucaly's background audio only. |
| Clear All Layers | Revokes external ownership, hides slides, clears group visual backgrounds, and clears eucaly's background audio. Preserve the existing timer and clock semantics. |
| Stop Projection | Closes all managed local output windows, cancels pending presentation requests and external leases, and retains local Current. Background audio follows its existing independent lifecycle. |
| Close or lose one output display | Stops that destination only. Other destinations continue; assignment and Current are retained. Reconnection requires an explicit Present or Show action. |
| External state update, Hide, Clear, or Release | Applies only with that connection's current ownership lease. An explicit new Present can request ownership again. |

Every takeover creates a new ownership generation before subsequent source updates can commit. Late external updates, reconnects, grants, disconnect callbacks, and releases from a displaced source cannot restore or clear another source. Validate and prepare an external Present before displacing working content. Record explicit action order before asynchronous preparation; preparation may commit only if no newer Present, local takeover, Hide, Clear, or Stop has superseded it. With no valid configured destination, reject Present with a visible error and retain existing state.

When a local Hide revokes an external lease, retain an immutable last-presented snapshot for hidden Confidence text. This does not insert external content into local Current or permit later updates from the revoked connection. Clear removes the retained text. No source resumes automatically after Hide, Clear, Release, or disconnect.

Background selection, audio controls, timer updates, profile editing, and passive model refreshes have their documented scope. They do not become presentation requests. Source-changing commands must still work when eucaly's own session is inactive but an external source is presenting. Commands originating from inactive eucaly workspaces must not accidentally reclaim output; Stop Projection remains an app-level command.

## Profiles and independent visual backgrounds

Each profile owns its visual background configuration: colour or asset, image/video fit, dimming, and visibility when text is shown, when slides are hidden, and when full-screen media is presented. Confidence defaults to a solid readable background. Audience defaults reproduce today's lyrics and hidden-slide background behavior. Different profiles can use different images or muted looping videos.

Profiles are serializable settings, not owners of live players or windows. A profile ID references its configuration; a destination separately references its monitor identity and profile ID. The runtime acquires the resources needed by each active profile. Matching background assets and playback policy can share resources; differing policies use separate runtime instances. Background video remains muted. Background audio retains one explicit eucaly playback owner and is never implicitly duplicated or started by a profile.

Existing background selection and visibility controls operate on Audience by default, preserving the common one-projector workflow. Each output's settings also expose its own background selection, visibility, and Clear action. Group Clear Background Visual and Clear All Layers operate across enabled outputs. Clear removes the selected background from the affected working profile configuration, consistent with today's background clearing behavior.

Each profile also stores component selection, stacked/columns layout where applicable, font sizing, alignment, positioning, padding, and layer inclusion. Missing components collapse their space. Preserve Meaning's existing relative sizing and columns proportions in the migrated Audience profile; allow a Meaning-only profile to use its full frame. External scripture supplies verse text, references, and translation labels as structured data without being interpreted by the lyrics parser.

Readability measurements use the profile's geometry and its assigned display. Operator warnings remain outside projected content. Local Preview and Current thumbnails continue to use the Audience layout with independent thumbnail font controls. Optional output previews do not add a required preparation step for external apps.

## Runtime boundaries

Use focused types under `eucaly/Output/`, with corresponding tests. Exact type names can follow repository conventions; their responsibilities are fixed:

- A content snapshot carries source identity, content kind, current and optional next content, separately classified components, labels, visibility, timers, and a revision. Local media references stay internal. Pure models and lyrics adaptation remain `nonisolated` and reuse `LyricsParser` and `LyricsSectionCatalog`.
- A profile store owns versioned profile definitions and destination assignments. It preserves stable opaque IDs and reports corrupt or unsupported persisted data without choosing another monitor.
- An app-owned output coordinator owns the live source, explicit action ordering, the presentation group, and destination lifecycles. It survives controls-window closure and has injected dependencies for tests.
- A window destination owns one monitor-bound window and its geometry. Reservations are per physical display UUID. Invalid, mirrored, or ambiguous monitors stop only their own destination; output never moves to a fallback display.
- A media runtime owns program video, background-video resources, seek/loop/progress state, and shared capture consumers. Projection views consume resources; their appearance or disappearance does not control shared playback.
- A composition layer combines snapshot, profile, and destination geometry. All layers remain pinned to an explicit full-screen frame. Reuse existing text and native media rendering behind these boundaries first. A GPU compositor can implement the same boundary when offscreen frame delivery is added.
- An external receiver converts validated protocol messages into the same explicit presentation intents. It has no path to modify sidebar selection or overwrite the local Preview/Current document.
- An AltView adapter remains an independent outbound consumer of local eucaly presentation events, preserving its existing wire behavior.

Do not duplicate complete PresentationSessions or create independent players for every output. Closing an output releases its consumers; shared resources are released after the last relevant consumer stops. Picker-approved window capture remains one source stream with bounded frame fan-out. Preview consumers participate in that ownership; app shutdown remains responsible for global capture cleanup.

PDF and image outputs reuse caches and avoid eagerly materializing large documents. Full live webpage rendering remains in Audience for the first version; companion profiles use text or media status rather than starting additional WebKit playback. Preserve interactive Current navigation, private Preview navigation, saved sidebar bookmarks, and existing mute scopes. Reject unsupported profile/content combinations explicitly during preflight. Additional live media mirroring requires an adapter that preserves these semantics and must not introduce new launch-time screen-recording prompts.

Hold sleep prevention while at least one physical projection window is open. Hide, Clear, or loss of a secondary window retains the activity. Closing the last window, Stop, and teardown release it. Receiver connections or AltView sending alone do not acquire it.

## External presentation interface

Document the app-neutral `eucaly.presentation.v1` protocol in `docs/external-presentation.md`. Use authenticated loopback transport, UTF-8 JSON with a four-byte big-endian length prefix, bounded messages, and work off the UI thread. Use a generated high-entropy receiver credential stored in Keychain and made available through explicit receiver setup; do not log it or store it with profiles. The receiver is disabled until enabled in Settings; enabling, authenticating, discovering profiles, and reconnecting never publish content. It does not listen on the LAN in the first version. Test credentials and transport are injected; do not restore user pairings or start listeners in the unit-test host.

The handshake reports protocol version, supported content roles, opaque profile IDs, the available output group, and output readiness. Client names are display labels, not identities or authority. Connection identity and generation accompany source IDs.

Present is an atomic explicit action carrying complete current and optional next content, an action ID, and an optional supported profile request. The default uses the host's existing assigned profiles. Requests are layout hints governed by host policy; they never change monitor assignments or enable destinations. The receiver validates bounds and compatibility, prepares the composition, and returns the ownership lease and correlated acceptance. Subsequent state messages carry that lease and increasing revisions. Hide, Clear, and Release require the current lease. Reconnect establishes a new connection; it does not recover control by itself.

Support primary text, Meaning, Translation, Transliteration, headings, references, and footers as distinct roles with optional language and label metadata. Content kinds identify lyrics, scripture, and generic text without app-specific branches. A Meaning-only request requires Meaning; never silently relabel verse or primary text as Meaning. An already configured Meaning destination shows no text when an otherwise valid scripture presentation lacks Meaning; it must not block Audience or retain the previous song's Meaning. Empty content is a supported Clear action. Reject malformed, oversized, stale, or unsupported requests before they replace live output. Start with a 64 KiB encoded frame limit, at most eight connected clients, bounded controls, and a latest-value state mailbox. Every accepted explicit action has a correlated ID; coalescing state updates cannot discard a Clear, Stop, or takeover intent.

Report ownership and per-destination readiness separately from snapshot acceptance. Acceptance does not certify physical HDMI delivery. The API reference and reference sender must demonstrate Present, rapid state updates, Hide, Clear, local eucaly takeover, stale-update rejection, Release, and reconnection without takeover.

## Existing AltView sending

Keep protocol v2, opaque receiver templates, pairing restoration, Connect Only, primary-lyrics filtering, submission-correlated acceptance, latest-value delivery, ownership recovery, and exact local projection identity. Local output profiles do not change what the legacy adapter sends. Meaning, Translation, and Transliteration remain available to local profiles without being inserted into AltView's primary body. Background and appearance changes never take AltView output.

Use an event subscription boundary so attaching the output coordinator does not replace `AltViewService.attach`'s single callback. Preserve the distinction between passive Changed snapshots and explicit Show/Project events, including same-slide activation.

Incoming external content is not automatically relayed to AltView in this first version. When external presentation displaces a locally presenting eucaly source, release only that eucaly source's existing outbound lease and cancel its local media-capture report. This prevents AltView Confidence from capturing external content through a reused eucaly window. It cannot release another app's AltView ownership. A later explicit eucaly Show or visible Current activation resumes the existing outbound takeover flow.

The designated Audience window supplies localProjectionV1 identity. Confidence and lower-third windows never substitute for it. Closing a secondary window does not send a global Stopped event. If Audience closes while another managed output continues, clear its window identity report; report a fresh exact identity and generation after explicit reopening. Tests must cover cancellation and stale reports as well as reconnect and same-slide requests.

## Persistence and settings migration

Create a versioned store for profiles, independent visual background bookmarks, destinations, and receiver settings. Use stable display UUIDs and separate destination IDs. Import the existing selected display and all current layout, font, padding, and background preferences into one enabled Audience destination. Keep existing thumbnail controls, monitor labels, security-scoped access, and independent audio preferences.

Migration is idempotent. The default single-output installation must look and behave as it does today. Do not auto-enable additional profiles, choose another monitor, start a receiver, or prompt for capture permission. Corrupt profile data produces a recovery notice and retains recoverable data and monitor assignments.

Extend Projection settings with output rows containing name, profile, assigned monitor, enable state, live status, and per-output design/background controls. Keep native controls and system accent behavior. Preserve the toolbar's simple default Audience selection while making other outputs discoverable. Show the active source in the output status so externally presented content is not confused with local Current. Existing shortcuts keep their defined actions and gain no text-editing collisions.

## Implementation milestones

Complete these on the feature branch in dependency order. Each milestone should remain reviewable and leave the default Audience path working.

1. **Characterize the existing behavior.** Extend focused regressions for explicit and passive actions, same-slide presentation, Current retention, local AltView sending, window identity, monitor loss, sleep prevention, and workspace-command routing. Record the existing architecture and pending AltView work before refactoring.
2. **Introduce content, intent, and profile models.** Add source snapshots, component adapters, independent visual background configuration, profile storage, and migration tests. Keep local rendering on the existing Audience path until migration matches current behavior.
3. **Extract output ownership and window lifecycle.** Add the app-owned coordinator, explicit local intents, per-monitor reservations, aggregate output state, and destination teardown. Make the existing Audience window its first destination. Replace lifecycle dependencies rather than maintaining competing legacy branches.
4. **Centralize program and background media resources.** Move player and capture ownership out of output view lifecycle. Support independent profile backgrounds, single program audio, reference-counted capture, and cancellation guarded by source and resource generations. Keep webpages within their existing navigation and mute boundaries.
5. **Add profile compositions and multiple destinations.** Implement Audience, Confidence, Meaning, Translation, and Lower Third; connect per-profile appearance and background controls, readiness, fitting, and previews. Verify distinct background videos and unplugging one output during shared playback.
6. **Add direct external presentation.** Implement the authenticated local receiver, discovery, capabilities, atomic Present, leases, bounds, source takeover, and the reference sender. Verify direct presentation without any eucaly Load action. Do not modify ViewTheWord or AltView.
7. **Preserve AltView and finish integration.** Complete explicit/passive event fan-out, displaced-source cancellation, exact Audience identity reporting, toolbar controls, migration recovery, shutdown, and multiwindow behavior. Remove obsolete single-window ownership code. Update AGENTS.md with the scoped external-source exception while preserving every local media flow rule.
8. **Validate and document the operator workflow.** Run the required regressions, rehearse physical displays, finish the protocol reference, and record results and remaining hardware limitations. Prepare the branch for review without publishing a release.

## Validation and acceptance

Run `make test` after meaningful runtime milestones and before review. This includes app tests and offline release/feed regressions. Use `make build` for the final Apple Silicon build; retain macOS 14 minimum, unsandboxed access, and existing release/update configuration. Do not use release publication as validation.

Required automated coverage includes profile/background migration and independent edits; all component roles and missing-component behavior; source ownership and local priority; malformed and stale external messages; bounded updates and readiness; independent monitor failure; shared playback and capture lifetimes; balanced sleep activity; native closure and shutdown; all existing media flows; webpage navigation and mute separation; and the complete AltView regression suite.

Required physical rehearsal includes Audience plus Confidence with different backgrounds; Meaning and translation on distinct outputs; external scripture followed immediately by local Show, live Load, same-slide activation, Clear, Escape, and Stop; independent video/background playback; unplug and reconnect; identical monitor names and changed runtime IDs; controls-window closure; capture cleanup; and local AltView Confidence identity cancellation during source switches. Record measured behavior rather than equating requested frame rate or network acceptance with delivered frames.

Completion means the migrated single-output workflow remains intact, each profile retains its own visual background and settings, several assigned outputs run safely, an external reference sender presents immediately, normal eucaly actions take back or clear external output, and existing AltView sending passes its regressions. External app integrations and new broadcast transports follow after this eucaly foundation.

## Branch isolation and existing work

The planning checkout starts at main commit `70b7820fcb48c8f66103c14e6abab9748dc6b89f`. The primary checkout has in-progress AltView Audience/Confidence readiness changes in its protocol, service, settings, tests, and documentation. Leave those edits intact. They are not included in this branch's initial base.

Before application implementation, integrate the completed AltView work after it is committed on main. If it remains uncommitted, keep this feature isolated and account for those files during the later merge; do not silently include, overwrite, or commit that separate work. Re-run AltView regressions after integrating it. Keep the plan and subsequent application work on the feature branch, with no release tagging or publication.
