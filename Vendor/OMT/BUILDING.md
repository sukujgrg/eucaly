# Rebuilding the local OMT runtime

Use an isolated work directory on an Apple Silicon Mac with .NET SDK 8.0.426
and Apple's command-line toolchain. eucaly itself requires no .NET runtime.
The recorded build resolved NativeAOT 8.0.32; dependency hashes are retained in
`build-packages.json` and runtime notice hashes in `provenance.json`.

Create sibling clones named `libomtnet` and `libomt` from the official
`https://github.com/openmediatransport/libomtnet.git` and
`https://github.com/openmediatransport/libomt.git` repositories. Check out these
exact detached commits, respectively:

```
5395139d45cf47bf9f90364bf68f9960183e7638
bb4b67be8e5964f1017592b9fc5406495e704e5d
```

From the managed checkout, apply only patch 0003 (512 KiB) and patch 0002
(ownership), using their absolute paths in this directory. Check the resulting
diff against both recorded patches before building. Use isolated temporary
`DOTNET_CLI_HOME` and `NUGET_PACKAGES` directories; set
`DOTNET_CLI_TELEMETRY_OPTOUT=1` and `DOTNET_GENERATE_ASPNET_CERTIFICATE=false`.
Run in the managed directory:

```sh
dotnet build libomtnet.csproj -c Release -f netstandard2.0 \
  -p:TargetFrameworks=netstandard2.0
```

Then run in the sibling native wrapper directory:

```sh
dotnet publish libomt.csproj -c Release -r osx-arm64
```

The result is `bin/Release/net8.0/osx-arm64/native/libomt.dylib`. Preserve its
linker ad-hoc signature and relative install name; app packaging signs the
copied file with the app identity. NativeAOT build identifiers and final signing
can change file bytes, so validate source state, exports, dependencies and
behavior as well as recording each actual artifact hash. Do not replace the
unchanged VMX codec, app library search paths or a live helper's mapped files.
The app/helper support arm64 only; an x64 runtime build is not required.

Run the independent pool regression against that exact managed source:

```sh
dotnet run --project /path/to/eucaly/Vendor/OMT/tests/SocketPoolRegression.csproj \
  -c Release -p:OMTUpstreamRoot=/absolute/path/to/libomtnet
```

It needs local loopback permission and has bounded network waits. Preserve its
before/after results. Run eucaly's existing SDK round-trip/teardown regressions,
`make test` and `make build`, and verify packaged signatures, both runtime-load
checks, arm64 slices and notices. SDK call/enqueue counts are separate from
receiver delivery and sustained/physical qualification.
