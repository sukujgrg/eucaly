# Releasing eucaly

Releases run on your Mac using the Developer ID certificate, notarization
credentials, and Sparkle signing key in your Keychain. GitHub Actions validates
source; it does not hold signing credentials or publish releases.

## Normal release

1. Change `VERSION` to a new numeric version, such as `1.33` or `1.33.1`.
   You can also run `scripts/set-version.sh 1.33`.
2. Commit and merge or push the change to `main`, then update your local checkout.
3. Run `make release`.

That command checks the clean source commit and GitHub destination, waits for
the latest successful **Validate** push run on `main` for that exact commit,
builds an Apple Silicon app, exports with Developer ID, notarizes and staples it,
and signs the Sparkle feed. It then creates and pushes `v<VERSION>`, uploads
the prepared files to a draft release, verifies their checksums, and publishes
the draft as latest. There is no manual tagging step.

`VERSION` is the only marketing-version source, including ordinary Xcode builds.
Build numbers are automatic UTC timestamps, raised above every previous signed
feed entry when necessary. The app requires Apple Silicon (arm64) and macOS 14+.
Code signatures, signing team, hardened runtime, and the absence of debugging
entitlements are checked for arm64, including Sparkle helpers. The appcast
requires Apple Silicon. The app retains its existing unsandboxed file access.

The repository is derived from the single HTTPS GitHub push URL on `origin`
and must match the embedded update-feed URL. No version, tag, build-number,
repository, or validation-bypass flags are needed or accepted.

## Tooling layout

The build and release entry points follow ViewTheWord's layout:

```text
Makefile                       # public commands
VERSION                        # app version
scripts/
  build.sh                     # local Xcode archive and export
  release.py                   # distribution archive through publication
  update-feed.py               # Sparkle appcast generation and verification
  generate-info-plist.sh        # VERSION into the built Info.plist
  set-version.sh               # update VERSION
.github/workflows/validate.yml  # source validation
```

`make build` runs `scripts/build.sh` and exports into `~/Applications` using
Xcode's `mac-application` export method. `make release` runs `scripts/release.py`
directly with a separate archive and Developer ID export. Both projects use
`release-check`, `release-notarize`, and `release-publish` for the optional
stages. The old `release-local` and `release-github` names have been removed;
use `make build` and `make release` respectively.

Both apps target Apple Silicon only. The remaining release differences express
each app's requirements:

| Setting | eucaly | ViewTheWord |
| --- | --- | --- |
| Project, bundle ID, signing account | eucaly / `com.suku.eucaly` | ViewTheWord / `suku.ViewTheWord` |
| Release branch | `main` | `master` |
| Minimum macOS | 14 | 26 |
| App Sandbox | Disabled | Enabled, with Sparkle XPC configuration |
| Version format | `X.Y` or `X.Y.Z` | `X.Y.Z` |
| First feed | Can bootstrap after the known legacy `v1.32` release | Requires the previous published release's signed feed |

Eucaly uses `make test` for its Xcode app tests and release regressions.
ViewTheWord's Swift package and its content-processing scripts belong to that
app; they are not release prerequisites for eucaly.

For a future shared release repository, move the Python release/feed engine
and common Make rules there, with a pinned tooling revision. Keep `VERSION`,
Xcode signing/entitlements, the Info.plist template, and validation workflow in
each app repository. A per-app configuration can supply the settings above and
the notarization profile. The shared tool must receive the app checkout path
explicitly; today's scripts resolve it from their location under `scripts/`.
Keep saved release state tied to that checkout and preserve existing recovery
and signed-feed history checks when extracting the tooling.

## Release Mac setup

Install Xcode and Python 3.9+, sign in to `gh`, and ensure your Keychain contains
a valid **Developer ID Application** certificate for the project's
`DEVELOPMENT_TEAM`. Store notarization credentials once if the existing
`eucalyNotary` profile is not already configured:

```sh
xcrun notarytool store-credentials eucalyNotary \
  --apple-id you@example.com --team-id YOURTEAMID \
  --password app-specific-password
```

Use `NOTARY_PROFILE=ProfileName` to select a different local profile. The
Sparkle key is stored under account `com.suku.eucaly`; preserve and transfer
that existing key when changing Macs. See [self-update signing](self-updates.md).

## Optional commands

| Command | Purpose |
| --- | --- |
| `make release-check` | Check source, destination, and CI without building or publishing. |
| `make release-notarize` | Prepare signed, notarized artifacts without tagging or publishing. |
| `make release-publish` | Publish saved artifacts without building or notarizing again. |
| `make release NOTES_FILE=/tmp/eucaly-notes.md` | Use an external release-notes file. |
| `make test` | Run app tests and offline release/feed regressions. |
| `make clean` | Remove build caches while preserving saved releases. |

Keep optional release notes outside the checkout, including ignored folders.
The script reads them before preparation and saves them with the draft so
retries use the same notes. `make build` installs local builds in
`~/Applications` and preserves saved releases.

## Saved work and retries

`build/release/v<VERSION>/` contains the app, notarized zip, SHA-256 checksum,
source metadata, and signed `appcast.xml`. Keep `state.json` and `work/`: they
bind the source commit, repository, archive, notarization submission, and file
checksums to this release. Release builds use separate `build/ReleaseDerivedData`.

Usually recovery is simply rerunning the same command. It reuses verified
archives and exports, waits on the saved Apple submission, and uploads only
missing draft assets. A lost response after publication is recovered by checking
the exact published release without modifying it or marking it latest again.
Conflicting tags, unrelated drafts, modified files, or a changed latest release
stop the command; it never force-pushes tags or overwrites uploaded assets.
Only an empty failed-upload placeholder on the matching draft may be removed.

If Apple accepted an upload but no submission ID was saved, recover it explicitly:

```sh
xcrun notarytool history --keychain-profile eucalyNotary
python3 scripts/release.py --no-publish --resume-notarization SUBMISSION_ID
make release-publish
```

The script verifies Apple's archive SHA-256 before accepting the recovered ID.
Do not edit recovery state to skip steps. Keep package contents unchanged,
including Finder metadata inside `.app` and `.xcarchive` packages. Git's tag
signing preferences are respected; a canceled signing prompt preserves artifacts.

If `main` advances, the prepared release still belongs to its recorded commit.
Check out that commit to finish it, or move unfinished preparation aside and
prepare the newer source. If a tag already exists for the old commit, use a new
`VERSION`. Keep the exact `origin` push URL unchanged until publication finishes.
Cleanup and releases share a lock across linked worktrees. Separate clones or
Macs still require one publisher at a time.

## First Sparkle release

The known legacy release `v1.32` (GitHub release ID `383478874`) has no appcast.
The script can start the first feed after that specific release. A different
release without a feed is rejected. Once a feed exists, its signature must
verify, its build numbers must advance, and every previous archive's URL,
signature, size, and compatibility metadata must be retained.

The zip and checksum filenames remain compatible with the old updater. Existing
Apple Silicon users can install the first Sparkle version using that updater or
a manual download; subsequent versions use Sparkle. Before distributing, test
installation and relaunch with a signed, notarized pair in a disposable installation.
