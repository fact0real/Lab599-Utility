# Station workspace

The Station page brings local frequencies, operator profiles, band reference,
quick commands and connection diagnostics into one native macOS workspace.

## Operating the station

1. Select the CAT serial port. In **Station Profiles**, enter the station and
   operator callsigns, grid, radio and antenna. Choose the receive input,
   transmit output, microphone and headphones, then **Save & use profile**.
2. Select **Read radio** to obtain the actual VFO and mode. Saving or switching
   profiles does not tune or transmit.
3. Select a saved frequency or enter MHz and mode. **Apply to radio** checks
   RX, VFO A for both RX/TX, and disabled XIT/VOX, then verifies the new settings.
   Presets never assert PTT. **Save VFO** prepares an editable local entry.
4. Use the quick commands to open Voice, CW, FT8/FT4 or Logbook. Configure
   Command–Option shortcuts in **Connections & Keys**. Escape stops station
   audio/keying activity and requests release of app-owned PTT.

Profiles can be changed while the station is stopped. Explicit audio device
IDs are preserved if hardware disappears; a missing configured route blocks
startup instead of choosing another device. In **CW Station**, choose the input
next to **Start Decoder**; this choice is saved automatically and takes precedence
over Station Profiles. **System Audio (Direct)** captures audio playing on the Mac
on macOS 14.2 or later, subject to macOS recording permission. Station Profiles
are not required for CW input selection. Existing settings are migrated from
saved preferences.

## Data and integration

- Profiles and local frequency entries are saved atomically to
  `~/Library/Application Support/Lab599 Utility/Station/station.json`.
  Local frequencies do not write the radio's hardware memory channels.
  Unreadable or invalid stored data is preserved and saving is blocked.
- Each new log record snapshots station metadata in SQLite. ADIF carries
  the station callsign, separate operator callsign and station details.
  Editing the current profile does not rewrite historical contacts.
- Normal Voice, CW, digital and telemetry CAT traffic uses one serialized
  transport. Operating-mode changes release owned TX before handing off;
  maintenance and binary-protocol tools use an exclusive handoff.
- Lost PTT acknowledgement retains cleanup ownership. The next transmission
  is blocked until RX is confirmed. External PTT is not claimed or released.
  Failure to clear a CW queue does not prevent an RX cleanup attempt.
- Diagnostic snapshots can be read without waiting for serial I/O.

## Band reference

The included reference is a simplified **IARU Region 1 HF plan**, effective
16 October 2020, covering 160–10 metres. It is not a complete regional rules
engine and does not include Region 2/3 or 6 metres. Profiles may record those
regions, but the page explicitly continues to identify its reference as
Region 1. It links to the [official IARU document](https://www.iaru-r1.org/wp-content/uploads/2021/06/hf_r1_bandplan.pdf).
Segment endpoints are half-open. Recommendations concern occupied bandwidth,
not only the dial frequency; the reference is not national authorization.

## PSK Reporter

Reporting is opt-in. Real FT8/FT4 decodes are captured with their decode time,
RF frequency (dial plus audio offset), receiver callsign, grid and antenna.
Simulated decodes and unresolved callsigns are excluded.

The reporter implements the [documented IPFIX protocol](https://pskreporter.info/pskdev.html)
over UDP to `report.pskreporter.info:4739`. It batches about every five minutes,
deduplicates recent reports and bounds its queue at 256 entries. Packets stay
within a 1,400-byte budget; failed local UDP submissions retain queued records.
Disabling reporting discards unsent records. Successful UDP submission does
not prove server receipt. This template does not upload SNR.

## Validation and limits

Run `./build-utility.sh --test-only` for the regression suite and
`sh tests/run-station-tests.sh` for the isolated Station tests. The latter use
fake radios, a temporary store and an injected UDP sender. They exercise
ownership, failed PTT/CW cleanup, read-only CAT restrictions, tuning readback,
store validation, packet format, retry retention and packet-size splitting.
`./build/StationTests --render` additionally checks all four sections at two
widths, including table-column fit.

FT8 and audio regressions cover missing configured devices and failed PTT;
logbook tests cover station metadata in SQLite and ADIF. The built app is
visually checked in light/dark and compact windows. These checks do not replace
verification with a physical TX-500, its audio interface and a suitable test
load. No on-air transmission or real PSK Reporter upload was used for testing.

`./build-utility.sh --build-only` creates the universal arm64/x86_64 app in this
workspace without replacing an installed application. The local build is
ad-hoc signed, not notarized for public distribution.
