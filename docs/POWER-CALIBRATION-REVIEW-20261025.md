# TX-500 power calibration review — 25 October 2026

## Decision and security conclusion

Reject the supplied automatic-transmit sweep unchanged. Implement a native,
offline measurement/analysis workbench in **Telemetry → Power Calibration…**.
It has no serial transport, network API, process launch, credential access,
automatic transmission, retuning or executable import. Observations are entered
manually or read as bounded UTF-8 CSV data.

No evidence of spyware, exfiltration, persistence, obfuscation, shell execution,
credential collection or malicious payload was found in the reviewed source.
This is a scoped source review, not proof of absolute safety or a review of
future versions. The separately installed pyserial dependency is not certified
by this review and is not added to Lab599 Utility.

## Provenance and coverage

Source: EA3JIC's email **A small tool to measure the TX-500 meter in real watts**,
24 October 2026. It explicitly says the tool has not been tested on a real
radio and is GPLv3. It supplies `tx500_power_cat_v0.7.zip`, not a repository URL.
The matching local archive and extracted directory were present in Downloads.

The local ZIP's observed SHA-256 was
`6eaad809905b136cc48e985e47aedf3b077c9322c3ba986a0996ab449afc0e3c`.
The listing contained 122,210 uncompressed bytes: 13 files and 3 directories,
including three Python files, README, explanatory Markdown, GPL licence,
static SVG and six simulator examples. No binary or installer was listed.
The ZIP was no longer present when archive/extraction comparison was attempted.
Gmail's connector cannot fetch this ZIP MIME type, so the local archive has
**not** been cryptographically bound to the attachment, and no byte-for-byte
archive/extraction equality claim is made. A build-only snapshot preserves the
extracted files that were actually reviewed.

All Python source was read: imports, startup, options, serial I/O, transmit,
cleanup, analysis and test. Accompanying documents, SVG and simulator files were
inspected as data. The SVG has no script or external resource. No supplied
installer, shell command, sweep main function or physical serial operation was
run. Limited probes loaded reviewed functions with fake CAT and fake time;
they never imported pyserial or opened a port. The upstream test was read,
not run.

Reviewed executable source SHA-256:

| File | SHA-256 |
| --- | --- |
| `tx500_power_sweep.py` | `2bb282dabe5431b8398ea05d73f5a8650a7d66e2c40f0e61e58382830e75d233` |
| `analyze.py` | `9a582f171a9725b1f90651ee1bb636d5e819c10d90e0ab9955b04d89b1674823` |
| `tests/silent_radio_test.py` | `595b59d64813670f2ad513438f940d76597cf4abc9e306ed978857141a50fbbc` |

Review support files and logs are in `build/power-review/`, outside Git.

## Findings in v0.7

1. **Missing TX/RX confirmation does not fail closed.** `measure_step` catches
   a missing PT reply during TX and continues sampling. Failed final PT0
   confirmation only prints a warning and returns normally; another step can
   follow. A fake-CAT probe reproduced both. With a broken cable, sending RX
   cannot ensure that the transmitter receives it.
2. **Read-back is incomplete.** `main` reads `pc_rb` but does not compare it
   with requested `pc` before transmitting. The selected mode is written
   without read-back. Mutations during a sweep are not comprehensively checked.
3. **The TX deadline is cooperative.** Reads are timed on the control thread;
   writes independently wait up to one second. Sleeps and sequential cleanup
   writes add delay. There is no independent TX backstop. Finally cannot ensure
   stop on crash, suspension, power failure or cable loss. Do not adopt the
   upstream suggestion to disconnect a load during stuck TX: stop using the
   radio controls or power while keeping the load connected.
4. **Restore lacks verified RX and read-back.** Cleanup can restore frequency,
   mode and PC after an unconfirmed stop. Its success message means writes
   were attempted, not verified.
5. **Input validation has gaps.** The mW-entry path bypasses the W-path range
   check. NaN/infinity and malformed meter values are not consistently rejected.
   CSV text is exported without spreadsheet-formula neutralisation.
6. **Analysis merges incompatible observations.** Groups omit voltage,
   physical radio, instrument, operator and exact frequency. Callsigns cannot
   count physical units. Fractional median dots are truncated. Descending means
   still generate conversion values, reproduced with fake data. Two points
   trivially produce a perfect fit without establishing linearity.
7. **The silent-radio test is observational.** It prints timing and catches
   all exceptions without an assertion or failure exit for an excessive TX
   duration. A successful exit does not establish safety.

These are reliability and transmit-safety findings, not evidence of malicious
intent. Together they prevent approval of the unmodified sweep.

## Measurement validity

Lab599's primary [CAT reference rev.3](https://downloads.lab599.com/DOCS/Lab599-CAT-protocol-r3.pdf)
was obtained through its [official downloads page](https://lab599.com/downloads/).
Pages 8–9 were visually checked: PC specifies 010–100 without a watt unit;
RM reports 0–30 meter dots; SM0 represents the S-meter in RX and power meter in
TX. This does not establish a universal watts conversion or the physical
implementation of the internal detector. The attachment's claim about what
firmware knows and its simulated curve do not prove real hardware behavior.
ID500 also cannot identify an individual Discovery/PRO/ALTAI unit.

The new Telemetry parser keeps PC separately as a raw setting and marks RF
watts unavailable. DC current and PA temperature previously modeled using
assumed watts are no longer shown as live sensor readings. Demo remains
synthetic. Existing CAT Studio, Screen and CW power controls outside this
panel retain their previous behavior; their historical conversions are not
certified here. The existing SWR conversion is also outside this review.

## Workbench behavior and limits

- Manually observe TX dots and an external wattmeter on a rated 50 Ω dummy load,
  then return to RX before entering the point. The operator controls the radio.
  The confirmation records an operator declaration; it cannot sense the load,
  independently confirm TX or bound the operator's transmission duration.
- Record model, firmware, physical unit label, instrument, measured voltage,
  exact frequency/band, carrier, matching PC requested/read-back and SM0/RM0 TX
  dots. SM0 and RM0 stay separate. Optional raw VL text is never auto-converted.
- Import the original 19-column v0.7 CSV. Native exports add `radio_unit`.
  Rows without that label are exploratory data, not calibration of an identified
  physical radio. Keep one physical radio per such dataset. No calibration is
  downloaded, certified as manufacturer data or applied to live CAT.
- Groups separate model, firmware, exact frequency, numeric voltage, carrier,
  callsign, unit and instrument. Temperature and load still matter: record them
  in notes and repeat measurements. Matching labels cannot prove data truth.
- Input is capped at 2 MiB, 10,000 rows, 64 columns and 1,024 characters per
  field. The importer checks UTF-8, CSV quoting, columns, finite decimal numbers,
  ranges, PC equality, declared TX and band/frequency consistency. Unknown
  models/methods or malformed real rows reject the import atomically. Band
  classification is not a legal band plan or permission to transmit.
- Marked simulated rows and rows without measured watts are excluded and
  counted. There is no real-calibration override for simulator data. Export
  quotes CSV and neutralises spreadsheet formula prefixes in text.
- Analysis preserves fractional dots, averages repeats and reports fit/error
  and PC/watts comparison. Three distinct points, positive slope, R² ≥ 0.98
  and ≤10% maximum relative error are a descriptive check only. Piecewise
  interpolation stays within the measured range. Descending means block
  estimates; there is no extrapolation or invented endpoint. Zero W has no
  finite dBm. Repeated values can have scatter; estimates are not guarantees.
- Data stays in memory until explicit export. Closing/reopening the workbench
  retains its session within the app; quitting loses unexported data. Export
  paths are chosen by the operator. No upload, permission, dependency or
  Keychain access is introduced.

Credit: EA3JIC's GPLv3-or-later v0.7 tools prompted this feature. The native
workbench is written for this GPLv3 project; upstream Python and simulator
examples are not bundled in the app or source release.

## Validation

Completed locally on 25 October 2026:

- The full `sh build-utility.sh --test-only` suite exited 0. This includes the
  existing digital, update, privacy, documentation, CAT/settings/memory,
  firmware-transfer, Station, tuning, Voice Keyer, CW, audio, FT8 and logbook
  checks. Log: `build/power-review/full-tests.log`.
- Focused calibration/UI tests passed after the final input-size safeguards:
  original 19-column CSV compatibility, quoted text and formula handling,
  invalid/oversized/over-wide/over-long imports, row limits, malformed-input
  corpus, atomic replacement, exact context isolation, fractional/repeated
  dots, no extrapolation, descending data rejection and native export round-trip
  at its size limit. Opening the workbench does not start CAT. The confirmation
  resets after each point and the UI returns the expected table estimate.
- Focused Telemetry tests passed: PC050 is raw 50, copied snapshots preserve
  the raw setting, out-of-range PC is rejected, and live data does not acquire
  fabricated watts/current/temperature. The manual physical-radio probe was
  updated for the new raw field, but was not run against hardware.
- The focused workbench/UI suite also passed with AddressSanitizer and
  UndefinedBehaviorSanitizer. Clang static analysis of both new implementation
  files emitted no diagnostics. Logs are under `build/power-review/`.
- The 950 × 790 native workbench rendering was visually inspected. A scrollable
  document keeps the form accessible in smaller windows.
- The app was built locally as 2.290, Build 296, for arm64 and x86_64, using the
  existing ad-hoc signing and verification workflow. This is not notarisation,
  publication, installation over `/Applications`, or hardware certification.

Automated checks use fixtures and simulated transports without a physical
radio, wattmeter, serial adapter or RF transmission. Some existing audio tests
enumerate macOS audio devices. Hardware RF accuracy remains unverified.
