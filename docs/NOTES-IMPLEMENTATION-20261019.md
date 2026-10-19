# Notes priorities 1, 6 and 10 — local implementation review

Lab599 Utility 2.286, build 292. Base: 2.285 at
`0bdbdbc723a841d808e9a1c982c327d79b6331c5`. The implementation is prepared for source publication on GitHub.
No public binary release is included.

## Priority 1 — filter read-back (#273)

Radio Screen treated FL21 as FIL-2, whereas Lab599's documented zero-based
RX digit means FIL-3; the other digit is the TX preset, not bandwidth. It also
multiplied an undocumented FW response and substituted guessed preset widths.
A shared strict parser now accepts exactly FL[0-3][0-1]; and maps to display
numbers. CAT Studio, Radio Screen and Digital setup use the same definition.
Truncated and malformed replies remain unknown. Live widths are shown as
unavailable; the manufacturer question remains in the email already prepared.

A live filter change reads the current RX/TX presets, confirms RX, preserves
the TX digit and checks read-back. A cancellation token prevents a queued
change from acting after the live screen closes. Digital entry no longer
writes FW3000 or blindly resets both presets with FL00. CAT Studio labels the
number RX FIL rather than suggesting it is the raw FL command value.

## Priority 6 — Tune / Stop clarity (#275)

The visible status distinguishes stopped, listening, TX armed, transmitting,
Tune carrier, RX pending and RX stalled. Simulation is marked No RF. Tooltips,
a short in-view explanation and Help distinguish Stop FT8/FT4, Halt TX and Stop
Tone. Tune reflects engine state, and its first live use explains the carrier,
its maximum 15-second duration and the stop actions. A remembered frequency
cannot be promoted to verified DIG state by pressing Tune. A separate carrier
cannot start while the QSO/automatic transmit workflow is active.

## Priority 10 — application updates (#279)

Sparkle 2.10.0 is pinned by upstream archive SHA-256. The app pins an Ed25519
public key and requires signed feeds and archives, including archive validation
before extraction. Signing failures cannot expire into unsigned-feed fallback.
The private key stays in the login Keychain, outside the repository.

The application menu exposes a manual check and optional automatic checks,
which start off. Profiling, automatic downloads and silent installs are off.
Install & Relaunch is explicit and rechecks radio activity after download; the
normal quit path checks once more. The app updater does not flash the radio.

The source feed is signed and empty. A separate signed 2.286 package/appcast was
prepared under build/app-update-2.286 and verified locally, without publishing
it. Publishing the empty source feed enables checks without offering a new
binary. A signed release item must be published separately to offer 2.286. Initial 2.285 → 2.286 installation is manual.
Release steps and recovery limits are in APP-UPDATES.md. Public distribution
remains on hold under the existing imagery-permission policy.

## Validation

- Final `sh build-utility.sh --test-only`: exit 0. Includes the new Digital
  control and app-updater tests and the existing serial, tuning, screen,
  transfer, clock, CW, FT8, decoder sanitizer, waterfall and logbook/cloud suites.
- Digital tests exercise the real controller with a fake engine: no carrier
  before monitoring, explicit No RF simulation, Stop Tone from engine state,
  Halt TX preserving monitoring, pending/stalled RX, and unverified DIG refusal.
  The new control/status area was rendered and visually inspected.
- All eight documented RX/TX filter combinations and malformed/error replies
  are covered. Pseudo-terminal Radio Screen checks cover all four RX filters,
  unknown bandwidth, truncated reply and cancellation before queued CAT access.
- App-updater tests run inside an isolated signed test bundle and exercise
  initialization, default-off behavior, radio guards, deferred installation,
  explicit continuation, duplicate clicks and abort cleanup.
- Both shell and Xcode builds succeeded for arm64 and x86_64. Final bundle
  passes strict deep code-signature verification. The final ZIP executable
  matches that bundle byte-for-byte; its signature and appcast metadata passed
  verification. A modified signed feed was rejected.

No real radio, RF transmit or live firmware flash was used. Optional external
M4A fixtures were unavailable and skipped by the existing CW test. No complete
old-to-new installer run against the public production feed was performed;
that remains a release-stage check once publication is authorized. Existing
unrelated Xcode warnings are not new regressions from these changes.

Keep the three cards open in Review / Test pending hardware and release checks.
