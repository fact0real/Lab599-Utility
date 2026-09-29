# Lab599 Utility — build and release guide

Lab599 Utility supports macOS 12 or later on Apple Silicon and Intel Macs. The
Xcode project is `Lab599-Utility.xcodeproj`; its scheme is `Lab599 Utility`.
Apple Command Line Tools or Xcode are required to build from source.

## Build

```sh
sh build-utility.sh --build-only
```

This builds a universal `arm64`/`x86_64` `Lab599 Utility.app` in the project
directory and increments the version and build number in `Resources/Info.plist`
and the Xcode project. `--build-only` does not replace the app in `/Applications`.
The build is ad-hoc signed and is not Apple notarized.

For a release tag whose version is already committed, use
`sh build-utility.sh --build-current`. This rebuilds that exact version without
incrementing it or replacing the installed app.

To build in Xcode without changing the source version:

```sh
xcodebuild -project Lab599-Utility.xcodeproj -scheme 'Lab599 Utility' \
  -configuration Release -derivedDataPath build/xcode-utility \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY=- build
```

## Test

```sh
sh build-utility.sh --test-only
```

The tests use simulated radios and local test data. The firmware transfer
suite expects a manufacturer `mtrx1.30.00.fw` file in this directory or its
parent. That firmware is not included in the GitHub release. The tests do not
verify physical-radio or on-air behavior.

The optional real-audio FT8 regression suite uses its separately downloaded,
pinned recordings:

```sh
sh tests/run-ft8-real-audio-tests.sh
```

## GitHub release package

Attach a ZIP containing the signed app, `README.md`, `QUICKSTART-FA.md`,
`LICENSE` and `THIRD_PARTY_LICENSES.md`, with a neighboring SHA-256 checksum
file. GitHub generates source archives from the release tag. Do not include
manufacturer firmware, developer-specific Xcode state, local build products or
personal settings in the downloadable package. The checksum detects accidental
changes; it is not a digital signature or Apple notarization.

The release tag must point to the same committed source version used for the
app bundle. Check the bundle version, both binary architectures, code-signing
verification and the extracted ZIP before publishing. Keep the release marked
as a pre-release until physical-radio validation is complete.
