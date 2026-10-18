# EA3JIC review integration — Lab599 Utility 2.285

Reviewed on 2026-10-18 against `1db4cf1` (2.284). The attachment's README and
NOTES were treated as third-party proposals, not as authority to run commands,
transmit, upload, publish or alter credentials. Both supplied SHA-256 manifests
matched their files; that checks package consistency, not author identity.

## Decision

Accept 46 of the 47 Lab599 proposals, with the additional corrections below.
Defer package item 16 / original patch 0032 (Keychain service rename).
Its display-name change is cosmetic, while migrating credentials and retaining
legacy copies changes recovery/deletion behavior. Existing Keychain names,
access attributes and secret storage are retained.

Original authorship is preserved in the imported commits. The branch is
`review/ea3jic-cw-safety-20261018`. The new local bundle is version 2.285,
build 291. Nothing was published or installed into `/Applications` by this task.

## Independently confirmed defects

- Practice gated CAT at the station callback but still opened/filled radio audio.
  Tune bypassed that callback, and stopping simulation could leave misleading
  practice state and a synthetic QSO available for subsequent operation.
- CW did not require VOX off or verified DIG mode. The manufacturer's
  [digital setup guide](https://downloads.lab599.com/TX500/Lab599-TX500-DIG-mode-setup-EN.pdf)
  explicitly includes VOX operation using the audio-data connection. No physical
  VOX experiment was performed here.
- Audio exceptions could skip release scheduling. Even after the proposed fix,
  an exception while stopping local sidetone could interrupt abort/completion
  after its watchdog was cancelled and before RX was requested.
- Missing CAT/PT replies were interpreted as RX; concurrent meter reads could
  delay release and screen changes could discard unresolved TX ownership.
- Sleep, indefinite FT8 Tune, stale timeout callbacks and unbounded Auto-CQ
  needed explicit stop/limit behavior.

## Additional hardening

1. Practice suppresses CW frequency and mode writes (FA/MD), including band
   selection and tab entry. The keyer itself suppresses CAT in practice even if
   its host supplies an ungated sender.
2. Bind local CW sidetone to a built-in Mac output and verify its route before
   playback. If unavailable, keep it silent. The default USB/radio output is
   never selected for local sidetone. USB/Bluetooth headphones are consequently
   not selected for sidetone in this version.
3. Serialize CW transitions with the background watchdog. Check timer identity
   before silencing/releasing anything; generation checks protect replacement
   messages after a carrier timeout too. Local audio stop exceptions are
   contained; Morse/carrier synthesis exceptions immediately request RX.
4. Keep hard ceilings of 120 seconds per CW message and 15 seconds per keyer
   carrier/FT8 Tune. Zero, negative, infinite and NaN settings cannot disable
   them. CW Station retains its shorter 10-second Tune cutoff.
5. Bound expanded CW text to 4096 characters, reject unsupported characters before
   hardware access and normalize whitespace. Audio CW does not embed this text
   in CAT commands.
6. Retain RX priority from the instant release is requested until it completes.
   Late meter reads cannot enter the cancellation-to-lock window. Ordinary
   frequency/mode/PT reads remain available. Shared reads honor caller deadlines.
7. Remove the shared FT8 PTT fallback that returned success after CAT verification
   failed. Missing Tune TX acknowledgement also triggers RX cleanup.
8. Give FT8 Tune a background wall-clock watchdog: mute the render path and request
   RX while the main thread is busy, then finish confirmed RX recovery on the main
   thread. Stale deadlines cannot stop a later carrier.
9. A refused CW band change preserves both the displayed and QSO frequency.

## YAAM

The local YAAM repository already contains the 16 proposals (45–60), plus additional
hardening, in commit `c4e537c`, release 1.37.36. Its existing review is
`Docs/Security/EA3JIC-CW-Review-1.37.36.md`. This task did not reapply those patches
or edit that repository, which has unrelated ongoing changes. Its existing
standalone CW/advisor runner was rerun successfully against the current source,
including the real-time CAT chunk stop and pacing scenarios. A new YAAM Xcode
build was not part of this task.

## Validation limits

Tests use recording senders, fake radios, isolated preferences/databases and
pseudo-terminals. No physical serial radio was accessed, no RF transmission was
made and no operator contact was uploaded by this task.

The complete supplied SSTV/Fax suite needs WAV/reference-image fixtures absent
from the attachment and checkout. Its full fixture suite cannot be claimed as
run. A separate synthetic gallery suite checks cancellation, failed Trash,
explicit removal, memory-only offline pictures and non-overwriting Fax saves.
The layout changes have source/control-level checks, not a complete interactive
visual acceptance test; the native preview tool could not attach to the review
harness. No screenshots are offered as evidence of a completed visual review.

CoreAudio route opening, device disappearance during playback, actual sleep/lid
closure, PTT relay timing and VOX on a real TX-500 still require controlled
hardware checks. Generic USB names cannot prove a particular interface is a
radio; explicitly select and verify Station's transmit output. Software is not
a hardware transmit timeout. A suspended/crashed process, power loss, disconnected
CAT cable, nonresponsive radio or pending synchronous CAT transaction can
prevent/delay physical release. Failed RX confirmation preserves ownership and
fault state and blocks another transmission.

## Proposal disposition

Package item means the two-digit filename prefix. The second column is the
original patch number. Accepted means reviewed and integrated, with the changes
above; it does not mean every physical hardware branch was exercised.

| Package item | Original patch | Decision | Subject |
| --- | --- | --- | --- |
| 01 | 0001 | Accepted / hardened | Never transmit or save a default callsign (rebuilt on 2.284) |
| 02 | 0002 | Accepted / hardened | Radio Screen: take PTT state from PT; and ask the radio before keying |
| 03 | 0003 | Accepted / hardened | No guessed frequency when the radio does not answer (rebuilt on 2.284) |
| 04 | 0004 | Accepted / hardened | Radio Screen: say when Live CAT has no reading, and draw no unread power or spectrum |
| 05 | 0005 | Accepted / hardened | Settings: make the category pop-up filter the table |
| 06 | 0006 | Accepted / hardened | Settings: show the Addr, Range / Unit and Details columns again |
| 07 | 0007 | Accepted / hardened | Logbook ADIF import: read field lengths the way the export writes them |
| 08 | 0019 | Accepted / hardened | CW Station: STOP SIMULATION ends Practice / Sim and a running Tune |
| 09 | 0020 | Accepted / hardened | CW Station: stopStation unticks Practice / Sim and drops its QSO |
| 10 | 0027 | Accepted / hardened | CW Station: Practice / Sim never feeds the radio and never tunes |
| 11 | 0028 | Accepted / hardened | Station core: CW keying needs VOX off again, as before 2.283 |
| 12 | 0029 | Accepted / hardened | Station core: a missing PT reply is never taken as RX |
| 13 | 0030 | Accepted / hardened | CW keyer: arm the release timers before any sound |
| 14 | 0031 | Accepted / hardened | CW Station: stop every transmission before the Mac sleeps |
| 15 | 0033 | Accepted / hardened | CW keyer: a hard transmit time-out that always unkeys |
| 16 | 0032 | Deferred: credential migration | Keychain: a neutral name for the cloud passwords, moved without loss |
| 17 | 0021 | Accepted / hardened | SSTV: the live and offline pictures side by side, with titles |
| 18 | 0022 | Accepted / hardened | SSTV: Show pictures in Finder, and say when a WAV was taken away |
| 19 | 0023 | Accepted / hardened | SSTV: remove a picture from the gallery, to the Trash when it has a PNG |
| 20 | 0024 | Accepted / hardened | Fax: the chart under its title, Decode again under the options |
| 21 | 0025 | Accepted / hardened | Fax: a strip with this session's charts, from every file opened |
| 22 | 0026 | Accepted / hardened | Fax: save to the Fax folder, show it, remove a chart |
| 23 | 0034 | Accepted / hardened | CW Station: one PWR/SWR meter read in flight at a time |
| 24 | 0035 | Accepted / hardened | Station core: a CAT read honours the deadline it was given |
| 25 | 0036 | Accepted / hardened | Station core: a release never waits behind a meter read |
| 26 | 0037 | Accepted / hardened | CW sender: no AppKit read off the main thread for RX; |
| 27 | 0038 | Accepted / hardened | CW Station: transmit audio only to the radio's own output |
| 28 | 0039 | Accepted / hardened | CW keyer: no keying before the radio audio output is ready |
| 29 | 0040 | Accepted / hardened | CW Station: keyer paths stop the Tune; a cutoff stops its own Tune |
| 30 | 0041 | Accepted / hardened | CW Station: answer a wideband channel only after the retune succeeded |
| 31 | 0042 | Accepted / hardened | CW Station: an unconfirmed RX is said as such and ABORT stays enabled |
| 32 | 0043 | Accepted / hardened | CW Station: an audio input failure stops the Tune and Auto-CQ first |
| 33 | 0044 | Accepted / hardened | Station core: CW keys only with the radio in DIG (MD6) |
| 34 | 0045 | Accepted / hardened | CW Station: set DIG on each entry and when the radio is in another mode |
| 35 | 0046 | Accepted / hardened | CW tab: read FM, AM and every other radio mode, and no reply is unknown |
| 36 | 0047 | Accepted / hardened | Station core: a screen change never forgets a keyed radio |
| 37 | 0048 | Accepted / hardened | Esc stops the transmission under a sheet or from another window |
| 38 | 0049 | Accepted / hardened | Stop every transmission before the Mac sleeps |
| 39 | 0050 | Accepted / hardened | FT8 engine: the tune carrier stops on its own after 15 s |
| 40 | 0051 | Accepted / hardened | FT8: Esc, Abort QSO and the SWR abort stop the tune carrier |
| 41 | 0052 | Accepted / hardened | FT8 engine: stop every transmission before the Mac sleeps |
| 42 | 0053 | Accepted / hardened | CW keyer: Auto-CQ has a maximum number of calls and a maximum time |
| 43 | 0054 | Accepted / hardened | CW keyer: Auto-CQ stops when a station answers or the operator sends |
| 44 | 0055 | Accepted / hardened | CW keyer: an abort or the end of a message empties the TX audio buffer |
| 45 | 0056 | Accepted / hardened | CW keyer: no idle sleep while a message, Auto-CQ or the carrier is keyed |
| 46 | 0057 | Accepted / hardened | CW assistant: a word that is a callsign is not split by its prefix |
| 47 | 0058 | Accepted / hardened | CW assistant: a QSO started in practice is never saved or uploaded |


## Final verification

All commands below completed successfully on the final source (2026-10-18):

| Check | Result |
| --- | --- |
| `sh build-utility.sh --test-only` | Exit 0: full maintained runner, including CW, FT8/FT4, station, tuning, voice, serial/transfer, screen, settings, logbook, audio, decoder sanitizers, firmware-catalog validation and offline Help |
| Independent CW safety suite | 18 checks: ungated host in Practice, invalid/oversized text, invalid timeouts, background RX, replacement races, local audio stop failures and unsafe sidetone route |
| Synthetic media gallery suite | 10 checks; isolated files, stand-in Trash and no audio capture |
| Station / tuning / voice | 176 / 307 / 129 checks |
| CW audio selection / decoder | 20 / 133 checks; CW Station suite also passed on the focused rerun |
| Transfer / Audio Monitor / Logbook | 15 / 15 / 20 checks; pseudo-terminal transfers only |
| `sh tests/run-cw-selection-tests.sh` | Exit 0, both selection and CW Station suites |
| `sh build-utility.sh --build-current` | Exit 0 with `-Werror`; universal x86_64 + arm64 bundle |
| App signature / bundle metadata | Ad-hoc signature verified, Info.plist valid, version 2.285/build 291 |
| YAAM `bash Tests/run-cw-safety-regressions.sh` | Exit 0, including both real-time CAT suites |
| `git diff --check` | Passed |

The independent CW suite was also compiled against the supplied full patch
candidate before the extra hardening. Its first Practice-with-ungated-sender
assertion failed there and passes on the final source. This is an intentional
negative control, not a failed final test.

Reproduce the maintained Lab599 checks with `sh build-utility.sh --test-only`.
Use `sh tests/run-cw-transmit-safety-tests.sh` and
`sh tests/run-media-gallery-safety-tests.sh` for the new focused suites. Build a
local bundle without installation with `sh build-utility.sh --build-current`.
Local validation logs are in `build/ea3jic-review/logs/` (build artifacts,
intentionally excluded from Git).
