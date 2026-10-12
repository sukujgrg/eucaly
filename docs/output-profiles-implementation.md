# Output profiles implementation

## Characterization

Implementation checkout is isolated on `codex/output-profiles`, from plan commit
893b1169cc08db8f657512af7ece0f55f267c96e. Local Preview and Current are owned by
PresentationFlowController and PresentationSession; explicit user activation is
separate from deferred passive model events. The session currently owns one
projection window, sleep activity and media controls. ProjectionDisplayManager
resolves physical UUIDs and reserves outputs. AltViewService attaches through a
single callback; that boundary must become a subscription before adding consumers.

Main has separate uncommitted AltView Audience/Confidence readiness work in the
protocol, service, settings and tests. It was reviewed read-only and is excluded
from feature commits. Merge it when committed, then rerun all AltView regressions.

Existing tests cover private Preview, all media adaptation, explicit/same-slide
activation, canceled deferred actions, window identity, display loss, sleep
activity, webpage scope and active-workspace commands. Added characterization
covers passive Current replacement and event transaction coherence.

## Validation record

Baseline `make test` is running. Physical multi-monitor rehearsal and Instruments
CPU/GPU/cadence measurements require the operator's display and media setup.
