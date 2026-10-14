# Output profiles design

This document describes the narrowed local-content scope. ViewTheWord owns its
native scripture projection and appearance. eucaly profiles compose eucaly's own
Current content and can send primary lyrics directly to AltView. Incoming
presentation reception and forwarding are outside the supported architecture.

## Responsibilities

- PresentationFlowController owns Preview and explicit Preview -> Current movement.
- PresentationSession owns a local Current document, selection and media controls.
- OutputCoordinator owns active workspace identity, coherent snapshots, display
  reservations, output windows, sleep prevention and shared program media.
- OutputProfileStore owns versioned appearance and typed destination settings.
- AltViewOutputRouter owns shared discovery and independent outgoing receiver
  connections; AltView owns receiver appearance.

## Output behavior

Audience, Confidence and Lower Third render the same activated Current through
independent native compositions. Confidence shows Current/Next or its standby
clock. Lower Third defaults to chroma green. Lyrics components remain distinct;
missing companions reserve no space. All native media uses one playback/capture
runtime. Webpages permit one Audience output and status-only companion views.

Show, visible Current activation/navigation and live Load/Switch explicitly choose
the active workspace. Preview, stopped preparation, hidden navigation, background
controls and pairing do not. Hide retains private content; Clear removes it;
Stop closes native outputs and releases AltView leases. A lost destination does
not move to another monitor or stop another output.

## Settings and acceptance

Keep native controls in one Manage Outputs editor. Preserve local typography,
backgrounds, physical monitor identities, custom profiles, independent audio and
outgoing pairings during migration. Profile version 3 removes retired receiver
and Bible-only settings. No migration opens an unassigned output.

Validate Preview/Current privacy, explicit/passive ownership, same-slide actions,
queued-navigation cancellation, every native media type, Confidence startup/clock,
display hot-plug/mirroring, sleep prevention, native settings and independent
AltView reconnect/pairing/acknowledgement. Use `make test`, then `make build`.
See [implementation](output-profiles-implementation.md) and [AltView output](altview.md)
for current architecture and manual validation boundaries.
