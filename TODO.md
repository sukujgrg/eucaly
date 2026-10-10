# Follow-up work

## AltView pairing: migrate to provisioned data-protection Keychain

- [ ] Migrate AltView pairing credentials and pinned receiver identities to a properly provisioned data-protection Keychain, coordinating the rollout with ViewTheWord. The current login Keychain fallback fixes persistence in signed builds without the required entitlements; Apple's preferred long-term implementation is the data-protection Keychain.
- [ ] Configure the app's Keychain entitlements and matching development and Developer ID distribution profiles through the existing build/release pipeline. Signing with the Developer account alone does not authorize Keychain access groups. Preserve arm64, macOS 14, hardened runtime, and eucaly's unsandboxed access; verify entitlements and the embedded distribution profile in the exported app.
- [ ] Migrate existing login Keychain pairings without requiring users to pair again. Preserve service/destination identity and receiver pins; verify the protected write and read before removing a legacy item. Handle interrupted migration and replacement so an older protected item cannot override newer credentials. Retain compatible reads during rollout.
- [ ] Keep Keychain work off the UI thread. Keep locked, denied, corrupt, and failed migration errors visible; preserve usable saved credentials and session-only recovery. Never store pairing secrets in app preferences, app files, or logs.
- [ ] Cover migration, interruption, pairing replacement, per-receiver isolation, and failure recovery in regression tests. Verify a Developer ID signed build on another Mac: save, quit/relaunch, reconnect without a code, replace pairing, and update through Sparkle without losing pairing.
- [ ] Update `docs/altview.md` and `docs/releasing.md` with provisioning, migration, and validation requirements. Retire the login Keychain write fallback only after the supported builds and migration path have been verified.

References: [Apple's Mac Keychain guidance](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains) and [distribution signing and provisioning](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac).
