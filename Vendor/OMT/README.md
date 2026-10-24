# Bundled Open Media Transport SDK

Bundled SDK: **1.0.0.19**, built from unmodified pinned upstream runtime sources.
The source-built `libomt.dylib` is arm64, matching eucaly and its helper.
`libvmx.dylib` remains the unchanged universal upstream codec. The base archive,
source commits, toolchain and retained-file hashes are recorded in
`provenance.json`. See `PATCHES.md` and `BUILDING.md` before rebuilding.

Only an explicitly started, separately supervised helper loads these libraries.
The main application loads neither OMT nor NDI. Packaged libraries are signed
with the app identity and verified before loading. Each helper isolates its SDK
settings/logs; exact-child retirement releases its process-lifetime NativeAOT
runtime. No separate .NET installation is needed to run eucaly. NDI continues
using its independent vendor-installed runtime.

The runtime retains upstream's 64 KiB send-buffer request and four encoded
async slots per channel. The previously bundled socket-pool and 512 KiB patches
are inactive historical artifacts; see `PATCHES.md` for the reassessment and
public-API evidence. Frame pacing is owned by eucaly's submission worker.
SDK enqueue counts do not prove socket completion or decoded receiver delivery.
Connection counts describe TCP channels, not receiver devices.

Output remains progressive SDR Rec.709 1920x1080 at 30/1 fps, UYVY or
straight-alpha UYVA, Medium VMX quality and stereo 48 kHz planar Float32 audio.
Picked-window sharing remains native-only. Do not replace a live helper's
libraries or search paths.

`LICENSE.txt` retains the upstream MIT license and the source-built NativeAOT
runtime's supplied license/third-party notices. The existing build copies the
notices and provenance into the signed app. Open Media Transport and associated
marks belong to their owners.

A finite read-only load check is available with the installed signed helper:

```sh
"$HOME/Applications/eucaly.app/Contents/Helpers/eucalyNetworkHelper" --check-omt-runtime
```

It creates no source or window. Use a finite process deadline in automation.
Receiver and physical qualification results are documented in
[`docs/omt-runtime.md`](../../docs/omt-runtime.md); source-build provenance is not qualification evidence.
