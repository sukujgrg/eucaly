# Bundled Open Media Transport SDK

Pinned SDK: **1.0.0.19**, from the
[official release](https://github.com/openmediatransport/libomtnet/releases/tag/v1.0.0.19).
`provenance.json` records the download archive, retained files and SHA-256 hashes.
`PATCHES.md` records the ABI-neutral C header correction.

Only the separately supervised output helper loads these libraries after an
explicit Start/Show/Retry. The main application does not link or load OMT.
The helper uses the bundled copies in `Contents/Frameworks/OMT`, verifies their
application signing identity, and isolates SDK settings and logs for that child.
The parent removes that temporary storage after normal or forced retirement.

The SDK's `libomt.dylib` is a NativeAOT library. A separate .NET installation and
`libomtnet.dll` are unnecessary. `libvmx.dylib` supplies VMX software encoding.
The app ships the universal upstream libraries, verifies the arm64 slices and
signs the packaged copies with the app identity. App and helper remain arm64.
Do not replace dependencies or change runtime library search paths during a
live sender's lifetime. NDI continues using its independent external runtime.

The upstream MIT licence is retained in `LICENSE.txt` and copied into the app.
Open Media Transport and associated marks belong to their respective owners.

The initial output is progressive SDR Rec.709 1920×1080 at 30/1 fps, using
UYVY or straight-alpha UYVA, fixed Medium VMX quality and stereo 48 kHz planar
Float32 audio. Submission counts establish SDK calls, not receiver delivery.
SDK connection counts are TCP channels, so one physical receiver can have
more than one connection. Window capture is outside this release's network
output capability.

With a signed local build, the helper supports a read-only library check:

```sh
"$HOME/Applications/eucaly.app/Contents/Helpers/eucalyNDIHelper" --check-omt-runtime
```

Use a finite process deadline for automated checks, as initialization runs
third-party code. This command creates no source or output window.
