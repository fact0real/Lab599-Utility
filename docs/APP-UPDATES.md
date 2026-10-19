# Application updates

The application uses the official Sparkle 2.10.0 binary distribution, pinned by
version and SHA-256 in `scripts/prepare-sparkle.sh`. Run that script before an
Xcode build; the shell build runs it automatically. Xcode CI prepares it first.
The framework and tools are restored locally, not checked into the repository.
Its upstream licence is in `Resources/Sparkle-LICENSE.txt` and in the app bundle.

## Operator behavior

- Application menu → **Check for App Updates…** performs an explicit check.
- **Automatically Check for App Updates** is off by default and remembered when
  selected. Checks use GitHub's raw content service; downloads use GitHub release
  assets. No callsign, locator, logbook or account credentials are submitted.
- Automatic installation/downloads and system profiling are disabled. The
  updater displays version/release notes and asks before installing.
- Checks wait until the station is idle. If activity begins during a download,
  the final **Install & Relaunch** step refuses to continue. Close the panel
  with **Later** and return using **Finish App Update…**. It does not stop a
  contact or flash on its own. The application quit handler checks again.
- Sparkle's installer validates and stages the application replacement. Existing
  Application Support data and Keychain entries are not migrated or deleted.
  Keep a copy of the previous app when testing a new release. Replacing the app
  with that copy restores the earlier executable; it does not restore data.
- Radio firmware still uses the separate Firmware Update screen and catalog.

## Trust and release preparation

`SUPublicEDKey` pins the Ed25519 public key. Both feeds and archives require
signatures; archive verification happens before extraction. Signing failures
never expire into an unsigned-feed fallback. Feed origin is fixed in code.
The private signing key is in the local login Keychain under Sparkle's account
`ir.factoreal.lab599-utility.updates`; it is never bundled or committed. Preserve
an offline secure backup using Sparkle's documented key export procedure. Losing
this key can prevent upgrades of these locally signed builds.

`updates/appcast.xml` is an empty, signed stable feed. It intentionally does not
offer any historical unsigned release. No network deployment is implied by its
presence in the working tree. Publishing this empty feed on main enables
checks but offers no new binary release. Never replace this with an
unsigned GitHub releases API fallback.

After public release is authorized and a reviewed build is ready:

1. Build/sign the reviewed app (`sh build-utility.sh --build-current`). A
   Developer ID signed and notarized distribution is preferred; the local
   review bundle is only ad-hoc signed and may prompt for Keychain access again.
2. Run `sh scripts/prepare-app-update.sh` with the built app and release notes.
   It validates bundle identity and signing-key match, creates an archive,
   signs the archive, embeds release notes in a signed feed, verifies the feed,
   and writes all output under `build/app-update-VERSION`. It never publishes.
3. Test the exact old-to-new update using disposable app copies and a signed
   test feed. Include cancel, Later, active radio, interrupted download,
   modified archive, insufficient permission and failed relaunch scenarios.
4. Publish the prepared ZIP on GitHub under the version tag used in its URL.
   After verifying the asset is downloadable, replace `updates/appcast.xml`
   with the prepared signed feed and publish it on main. Re-sign after any
   feed edit; do not edit embedded release notes after signing.
5. A first installation of 2.286 from 2.285 must be manual. 2.285 contains no
   updater or pinned update key.

Public releases remain on hold under the repository's existing imagery policy.
Official references: https://sparkle-project.org/documentation/ and
https://sparkle-project.org/documentation/publishing/ .
