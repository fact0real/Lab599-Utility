# Lab599 Utility for macOS

A native macOS application for the Lab599 TX-500 family of transceivers. It includes a Station workspace, DX Cluster, FT8/FT4 and CW operation, Voice Keyer, contact logbook, firmware updates, live telemetry, radio screen capture, time sync, CAT diagnostics, settings and memory management. Developed by **EP2AES (factoreal)**.

**v2.263 (Build 269) · macOS 12+ · Apple Silicon and Intel · English interface · Persian guide included**

[Download v2.263](https://github.com/fact0real/Lab599-Utility/releases/tag/2.263) · [راهنمای فارسی](QUICKSTART-FA.md) · [Build instructions](UPDATER-README.md) · [Report an issue](https://github.com/fact0real/Lab599-Utility/issues/new)

## Download and install

Download `Lab599-Utility-v2.263-macOS-universal.zip` from the [v2.263 release](https://github.com/fact0real/Lab599-Utility/releases/tag/2.263). Extract the ZIP and move `Lab599 Utility.app` to `/Applications`. The ZIP contains the app, English and Persian guides, and license notices; manufacturer firmware is not included.

Verify the download before opening the app:

```sh
shasum -a 256 Lab599-Utility-v2.263-macOS-universal.zip
```

The expected ZIP SHA-256 is `328d6fa51734eae86469a5c1672340c6a1f2423cebe8bedd4e8cf32ee8b1ccd6`. The app is ad-hoc signed, **not Apple notarized**. If macOS blocks the first launch, select this app in **System Settings → Privacy & Security → Open Anyway** after verifying the checksum.

## What's new in v2.263

- **Station:** Local operator and audio profiles, frequency presets, guarded CAT tuning with read-back, and optional PSK Reporter uploads.
- **DX Cluster:** Live spots, local filters and alerts, contact-history badges, explicit tuning, and QSO drafts. Incoming spots never tune or transmit by themselves.
- **FT8/FT4:** More reliable receive and transmit recovery, sequencing, waterfall rendering, frequency handling, and audio-device errors.
- **Security and data integrity:** Reviewed firmware download hashes, cloud secrets stored in macOS Keychain, stricter Club Log acknowledgements, and safer WAV parsing and FT8 audio synthesis.

Thanks to **EA3JIC** for the detailed review, bug reports, and contributions behind many of these fixes.

## Supported Hardware

| Model | Firmware catalog | BL20 Model ID |
| --- | --- | --- |
| TX-500 Discovery | v1.30.00, v1.29.06 | `0xc61ab4aa` |
| TX-500MP (Manpack) | v1.30.00, v1.30.00B27 HAM-Bands patch | `0x963bcdf4` |
| TX-500PRO (Tactical) | v1.29.05 | — |
| TX-500PRO ALTAI | v1.29.05 | — |

Firmware header validation reads the BL20 model ID before transfer begins and displays a hardware-match badge or a cross-model warning.

## Functions

| View | What it does | Radio mode |
| --- | --- | --- |
| Station | Local operator profiles, audio routes, saved frequencies, verified CAT tuning and opt-in PSK Reporter uploads | Normal operation, CAT 9600 |
| DX Cluster | Displays live spots and local contact history; tuning and QSO drafts require explicit actions | Normal operation, CAT 9600 for tuning |
| FT8 / FT4 Digital | Live decode and waterfall, manual or automatic QSO sequencing, ADIF logging and simulation | Normal operation, CAT 9600 and audio interface |
| CW Station | Morse keying, live audio decoding, QSO assistant and logging | Normal operation, CAT 9600 and audio interface |
| Voice Keyer | Local voice messages, headphone preview, CQ repeat and microphone reply | Normal operation, CAT 9600 and audio interface |
| Logbook & Cloud | Local QSO records, ADIF import/export, callbook enrichment and configured cloud services | Offline for local records |
| Firmware Update | Select a local `.fw` file or download from the built-in Lab599 catalog; validates the BL20 header and model ID; transfers with a two-ACK handshake and TIOCOUTQ-paced streaming; prevents system sleep during flash | Bootloader — "The loader is waiting..." |
| Time Sync | Disciplines a continuous internal UTC clock from multi-source NTP, TLS/HTTPS fallback, calibrated holdover and robust FT8 timing consensus; sets the radio to local time or UTC and verifies read-back | Normal operation, CAT 9600 |
| Telemetry | Live arc-gauge dashboard: RF power, SWR (RM1 dots), supply/battery voltage, S-meter, frequency, mode, TX/RX state; rolling averages at 5 m / 15 m / 30 m / 60 m; over-voltage, low-voltage and high-SWR alert guards; selectable poll rate (250 ms / 500 ms / 1 s); Demo Mode | Normal operation, CAT 9600 |
| Radio Screen | Real-time 256×128 LCD mirror via CAT; four display themes (Amber, Cool White / Daylight, Green phosphor, OLED); panadapter spectrum and calibrated meter bars; save screenshot to PNG or copy to clipboard; Demo Mode | Normal operation, CAT 9600 |
| CAT Studio | Verified live controls and band presets; named quick-launch CAT macros with safe command validation and read-back; full 1024-byte settings snapshots with model check and pre-restore backup; app-owned CAT protocol monitor with TX/RX/error filters and response timeline; the separate system console starts collapsed | Normal operation, CAT 9600 |
| Settings | Read, save, open and restore the full 1024-byte `.set` backup; read-back comparison after every write | Normal operation, CAT 9600 |
| Memory | Read, edit, save, open and write 100 channels using the original 600-byte `.mem` format; built-in operating profiles (SOTA/POTA, FT8/JS8Call, Contest); CSV import/export; read-back comparison after every write; file editing without a connected radio | Normal operation, CAT 9600 |
| Driver Install | FTDI D2XX driver download and installation guide; system serial-device diagnostics | — |
| Documentation | Embedded Lab599 manuals, schematics and firmware download library | — |
| Feedback & Suggestion | Structured bug report and feature request form; auto-collects macOS version and hardware model (`sysctl hw.model`); generates a pre-filled GitHub issue URL or copies Markdown to clipboard | — |

For operating details, see the [Station](STATION.md), [DX Cluster](DX-CLUSTER.md), and [Voice Keyer](VOICE-KEYER.md) guides.

Only one radio operation runs at a time. Telemetry and Radio Screen stop automatically when switching to another view. CAT Studio, Settings and Memory have a cooperative Stop button; partial writes are reported explicitly. File editing and Demo Mode work without a connected radio. Unsaved memory banks are protected by replacement and exit prompts.

Settings is a complete-block backup/restore tool matching the original utility; it does not identify individual setting fields. Memory exposes frequency, mode and preamplifier/attenuator. DIG uses the same stored code as USB. Writing memory replaces all 100 slots, including empty ones.

## Voice Keyer

The **Voice Keyer** sidebar panel records/imports local voice messages, previews them on a separate headphone output, sends one-shot replies, repeats CQ with adjustable receive gaps, and offers hold-to-talk microphone replies. It has exclusive radio ownership while open, verified CAT TX/RX transitions, cancellation of queued work, selected-device audio routing, and an explicit stop on radio changes or connection loss. [Setup, behavior and hardware validation limits](VOICE-KEYER.md).

## Network and privacy

PSK Reporter submissions are opt-in. DX Cluster connects only when you select **Connect**; it uses unencrypted public Telnet/TCP nodes and sends a callsign for login, so do not use a password-protected node. Cloud integrations require their own configuration, and credentials are stored in macOS Keychain. Simulation and Demo modes let you explore supported views without transmitting RF.

## Use

Open **Lab599 Utility.app**, connect the CAT-USB cable and choose the serial port from the port menu. Tap **Refresh** if the port does not appear. Close other applications using the same port.

- **Firmware Update** — power off the radio; hold the third top function key while pressing POWER until the display shows *"The loader is waiting..."*; select firmware matching your model; click Start Update and keep power and cable connected until completion.
- **Station, DX Cluster tuning, digital/CW/voice operation, Time Sync, CAT Studio, Settings, Memory, Telemetry, Radio Screen** — turn the radio on normally; set CAT protocol to **LAB599** (Menu 35) at 9600 baud. Digital/CW/voice features also need a suitable audio route.
- **Telemetry / Radio Screen Demo Mode** — enable Demo Mode in either panel to explore the UI without a connected radio.

Read and save the current settings/memory before restoring another bank. File-size checks cannot identify which radio model or firmware version created an untagged backup. A failed or interrupted write can leave the radio in a partially changed state; success is reported only after the implemented read-back checks complete.

### FT8 time discipline

Lab599 Utility does not step the macOS system clock. FT8/FT4 slot scheduling and the radio Time Sync command use a process-local UTC clock anchored to `mach_continuous_time`. Its two-state phase/frequency filter learns oscillator error from independent network sources, persists the calibration for offline holdover, and slews corrections while FT8 monitoring is active.

If UDP NTP is blocked, three TLS-authenticated HTTP Date sources provide a lower-precision fallback with an explicit uncertainty. CRC-valid FT8 decodes then refine offline time after at least eight independent callsigns across three slots. Per-callsign baselines are scoped to the selected audio-device UID, one station gets one vote per slot, and a weighted median, MAD rejection and Huber reweighting prevent a mistimed transmitter from moving the clock. Real transmission is blocked whenever estimated UTC uncertainty exceeds one second; receive and decode remain available for recovery.

## Build and tests

With Apple Command Line Tools or Xcode installed, build without replacing the installed app:

```sh
sh build-utility.sh --build-only
```

The output is `Lab599 Utility.app`, a universal `arm64`/`x86_64` bundle. `--build-only` increments the source version and build number. To rebuild the committed v2.263 version without changing either number, use `sh build-utility.sh --build-current`.

```sh
sh build-utility.sh --test-only
```

Tests use pseudo-terminals only. The firmware suite looks for `mtrx1.30.00.fw` in this directory or its parent; that manufacturer file is not redistributed in the release ZIP. See [the build guide](UPDATER-README.md) for release packaging and the optional real-audio test.

For v2.263, the full local suite, 60 real FT8 recordings under AddressSanitizer/UndefinedBehaviorSanitizer, and Xcode Release build and static analysis completed successfully. These checks did not access a physical radio or transmit on air.

The Xcode project is `Lab599-Utility.xcodeproj`; its target and scheme are **Lab599 Utility**.

## Reconstruction and validation

- [Firmware protocol review](PROTOCOL-REVIEW.md)
- [TimeSync review](TIMESYNC-REVIEW.md)
- [CAT review](CAT-REVIEW.md)
- [Settings and Memory review](CONFIGURATION-REVIEW.md)
- [Validation record](validation/RELEASE-2.0.md)

Reports distinguish observed binary behaviour, deliberate improvements, and unresolved details. Disassembly, binary hashes, extraction scripts and tests are included. This is a behavioural reconstruction, not recovery of the manufacturer's original source code.

**Physical-radio validation for this release remains outstanding.** Simulated responses verify the implemented protocol, but compatibility with every hardware revision, firmware version and USB driver has not been confirmed. Test firmware updates and transmit control carefully on the target hardware before relying on them. Settings acknowledgement contents and some reply framing remain unspecified by the original programs. Memory modem-control signals cannot be verified with pseudo-terminals.

## Project

Independent software, not an official Lab599 product. GitHub repository: [fact0real/Lab599-Utility](https://github.com/fact0real/Lab599-Utility). Author: EP2AES; contact: `EP2AES@asis.sh`.

See [LICENSE](LICENSE) (GNU GPL version 3) and [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for the bundled third-party components. Manufacturer executables and firmware files are not included in the release package.
