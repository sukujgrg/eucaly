# Self-updates

eucaly uses Sparkle **2.9.6**, pinned in its Xcode project and `Package.resolved`.
The feed is served from
`https://github.com/sukujgrg/eucaly/releases/latest/download/appcast.xml`.
Both the feed and update archive require Ed25519 signatures, and Sparkle verifies
the update before extraction and installation.

## App behavior

- **eucaly → Check for Updates…** opens Sparkle's native update UI, including
  download, installation, errors, and up-to-date results.
- **Automatically Check for Updates** controls Sparkle's persisted preference.
  It defaults to enabled on Sparkle's daily schedule.
- Scheduled checks add an **Update** toolbar reminder without opening a dialog
  or stealing focus, even during projection or launch. Clicking it brings the
  update UI into focus. The reminder clears when the update session finishes.
- Automatic installation is disabled. Download and restart require user action.
  Restart uses normal unsaved-edit confirmation and waits for capture cleanup.
- `AppDelegate` owns one `AppUpdateViewModel` shared by every window and the app
  menu. `SparkleUpdateDriver` owns Sparkle. Closing a window does not stop updates.

The app stays unsandboxed, retains its bundle ID and preferences, and supports
Apple Silicon (arm64) on macOS 14+. New appcast entries require Apple Silicon.
Sparkle's sandbox installer/downloader flags and Mach lookup exceptions are
intentionally absent, following its
[sandbox integration guidance](https://sparkle-project.org/documentation/sandboxing/).
The toolbar behavior uses
[gentle scheduled reminders](https://sparkle-project.org/documentation/gentle-reminders/).

## Signing key

The private signing key is stored in the maintainer's login Keychain under
account **com.suku.eucaly**. Only its public key is in `eucaly/Info.plist`.
Never generate a replacement for each release. Preserve the existing key and
use Sparkle's documented export/import procedure when moving release machines;
keep private-key backups outside the repository.

Resolve the pinned tools and display the existing public key:

```sh
xcodebuild -resolvePackageDependencies -project eucaly.xcodeproj \
  -scheme eucaly -derivedDataPath build/DerivedData
build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys \
  --account com.suku.eucaly -p
```

The release script rejects a Keychain key that differs from `SUPublicEDKey`.
macOS may ask you to approve Keychain access the first time `generate_appcast`
or `sign_update` uses this key. Complete that prompt on the release Mac; the
script never exports the private key.
See [releasing](releasing.md) for the `make release` workflow and migration from
the legacy updater. Until the first appcast is published, manual Sparkle checks
report an update-information retrieval error.

## Verification

`make test` runs injected updater tests without contacting a feed or installer,
plus offline release and feed regressions. These exercise shared reminders,
manual-check enablement, preference changes, archive metadata, retained feed
history, first-feed migration, and safe release retries.

Before distribution, check a signed and notarized pair in a disposable app
installation: download, install, relaunch, canceled quit with unsaved lyrics,
unwritable installation location, corrupted download, disconnected network,
and an update while projection/capture is active. Verify library access,
playlists, preferences, and projection afterward. These installation checks
require real release artifacts and are separate from the offline tests.
