# Workspace outputs: implemented direction

The implementation uses named workspace tabs with one Sidebar → Preview → Current
flow per workspace. Native tab detachment preserves the same window/session.
Operator focus never owns a program or destination. Each saved destination has one
workspace owner, and several destinations can share a workspace’s player/snapshot.
Different workspaces can present simultaneously. Profiles own reusable appearance.

AppDelegate owns OutputProfileStore, OutputCoordinator, NetworkOutputRouter and native
Settings independently of controls windows. OutputCoordinator retains workspace
sessions, Preview flows, accepted snapshots, action clocks and media runtimes.
Per-destination generation/epoch fences and global monitor/source-name reservations
preserve failure isolation and explicit action ordering.

The output picker displays owners and provides Move to This Workspace. Transfer is
explicit and capability checked. Show, Load/navigation, Hide, Clear and ordinary
Stop remain workspace scoped; Stop All Outputs is a separate global menu action.
Hide/Clear/Stop retain assignments. Closing controls never stops live resources.

Add NDI Output replaces the Lyrics/Media pair. All sources support lyrics and
PDF/image/video on one connection. Source identity, sender/helper and receiver
connection survive workspace/content-type changes. Transparent surrounds and
actual empty/key replacement frames reveal cameras when independent opaque
backgrounds are absent. Clear Current leaves backgrounds/music intact. The explicit
local music owner and saved network music route are never silently replaced on move.
Window capture retains its native-only limit.

Version 6 migrates existing rows to Home, preserves both legacy NDI sources
as generic destinations with their names/identities/appearance/music, resolves
legacy enabled-name duplicates by disabling later rows, and never publishes during
restoration. New workspaces have no outputs. Earlier retirement of AltView/SRT and
exact verified credential cleanup remain unchanged.

The maintained architecture, migration and verification details are in
[output-profiles-implementation.md](output-profiles-implementation.md). Runtime setup
and the open physical/two-hour qualification gates are in
[ndi-runtime.md](ndi-runtime.md) and [ndi-output-plan.md](ndi-output-plan.md).
