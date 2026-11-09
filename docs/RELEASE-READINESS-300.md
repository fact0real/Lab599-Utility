# Build 300 release readiness

- Source base: GitHub main v2.293/build299; the only application feature ported from the operator workspace is opt-in family presence/status display.
- Compiled the universal arm64/x86_64 application with `sh build-utility.sh --build-current`. Bundle signature, identity, and plist were checked by the build pipeline.
- Prepared the Sparkle release archive and feed with the product signing key. The archive checksum is recorded alongside the release asset; the signed feed must be copied byte-for-byte after publication.
- Presence remains off by default, reports radio/CAT state as unverified, and accepts no remote radio-control commands.
- No physical radio transmission or firmware activity is part of this release. App is not notarized.
