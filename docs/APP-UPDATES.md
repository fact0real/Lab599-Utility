# Application updates

The application uses the official Sparkle 2.10.1 binary distribution, pinned by
version and SHA-256 in `scripts/prepare-sparkle.sh`. Run that script before an
Xcode build; the shell build runs it automatically. Xcode CI prepares it first.
The framework and tools are restored locally, not checked into the repository.
Its upstream licence is in `Resources/Sparkle-LICENSE.txt` and in the app bundle.

## Operator behavior

- Settings → Application Updates → **Check for App Updates…** performs an explicit check.
- **Automatically Check for App Updates** is off by default and remembered when
  selected. Checks use `https://lab599-utility.asis.sh/updates/appcast.xml`; downloads use
  the same origin under `/releases/`. No callsign, locator, logbook or account credentials are submitted.
- **Settings → Application Updates…** offers manual, six-hourly, daily and weekly checks,
  plus last-check time and status. The default interval is daily, but automatic
  checks remain off until selected.
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
never expire into an unsigned-feed fallback. Feed origin is fixed in code. A second delegate gate requires a successfully
verified signed feed and a matching release archive at the exact product HTTPS
host, with no URL credentials, query, fragment or custom port. Each new check
clears previous feed-validation state. Release notes are embedded in the signed
feed; no external release-note request is made.
The private signing key is in the local login Keychain under Sparkle's account
`ir.factoreal.lab599-utility.updates`; it is never bundled or committed. Preserve
an offline secure backup using Sparkle's documented key export procedure. Losing
this key can prevent upgrades of these locally signed builds.

`updates/appcast.xml` is the signed product feed. Keep its exact bytes after
signing. A release archive must be uploaded and verified before the new feed
is made visible. Never replace the signed channel with an unsigned releases
API fallback. Historical 2.285 archives are not offered to this updater.

For every reviewed release:

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
4. Upload the prepared ZIP to the product server’s `/releases/` path.
   Verify the remote archive hash first. Only then atomically replace
   `/updates/appcast.xml` with the prepared signed feed. Re-sign after any
   feed edit; do not edit embedded release notes after signing.
5. A first installation of 2.291 from 2.285 must be manual. 2.285 contains no
   updater or pinned update key.

On 5 November 2026 the project owner confirmed receipt of the required written
Lab599 imagery permission in the release conversation. Version 2.291 bootstraps
this server-hosted update channel.
Official references: https://sparkle-project.org/documentation/ and
https://sparkle-project.org/documentation/publishing/ .
