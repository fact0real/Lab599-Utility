# Lab599 Utility for macOS

A native macOS application for the Lab599 TX-500 family of transceivers. It includes a Station workspace, DX Cluster, FT8/FT4 and CW operation, Voice Keyer, contact logbook, firmware updates, live telemetry, radio screen capture, time sync, CAT diagnostics, settings and memory management. Developed by **EP2AES (factoreal)**.

**Latest published release: v2.269 (Build 275) · macOS 12+ · Apple Silicon and Intel · English interface · Persian guide included**

[Download v2.269](https://github.com/fact0real/Lab599-Utility/releases/tag/2.269) · [راهنمای فارسی](QUICKSTART-FA.md) · [Build instructions](UPDATER-README.md) · [Report an issue](https://github.com/fact0real/Lab599-Utility/issues/new)

## Download and install

Download `Lab599-Utility-v2.269-macOS-universal.zip` from the [v2.269 release](https://github.com/fact0real/Lab599-Utility/releases/tag/2.269). Extract the ZIP and move `Lab599 Utility.app` to `/Applications`. The ZIP contains the app, English and Persian guides, and license notices; manufacturer firmware is not included.

Verify the download before opening the app:

```sh
shasum -a 256 Lab599-Utility-v2.268-macOS-universal.zip
```

Compare the result with the `SHA256SUMS.txt` asset on the release page. The app is ad-hoc signed, **not Apple notarized**. If macOS blocks the first launch, select this app in **System Settings → Privacy & Security → Open Anyway** after verifying the checksum.

## What's new in v2.269

- Clarifies that CAT needs a working macOS USB-to-serial port. macOS may provide one automatically, but some FT232 or PL2303 adapters need a compatible driver; there is no claim that every Mac works without a driver installation.
- Distinguishes FTDI VCP, which creates a serial port, from D2XX, which this app does not use. The older personal FT8 PDF incorrectly said D2XX was mandatory and is no longer bundled. Use the current in-app CAT Connection guidance and the chip maker's macOS instructions instead.

## What's new in v2.268

- **CAT Connection** replaces the misleading driver-installation screen. It lists possible macOS serial ports, explains how to check the radio in CAT Studio, and links to official [FTDI VCP guidance](https://ftdichip.com/drivers/vcp-drivers/) when an FTDI adapter appears in USB diagnostics but no serial port is available.
- Lab599 Utility uses a macOS serial port; the FTDI D2XX direct-access library is not required. The app no longer bundles that library or offers administrator-level install, Gatekeeper override, or broad uninstall actions. Existing macOS drivers are not modified.
- Model-dependent CAT menu numbering and the distinction between a visible port and a verified radio are now explicit. Related feedback diagnostics no longer claim a D2XX installation is “authorized” merely because a file exists.

### CAT adapter drivers on macOS

For CAT control, the adapter must appear as a working `/dev/cu.*` serial port. macOS may create that port without an extra installation, but this depends on the adapter chipset and macOS setup; some computers require a compatible USB-to-serial driver. Lab599 has shipped both FT232 (blue) and PL2303 (black) CAT adapters. For FT232, check the [FTDI VCP driver guidance](https://ftdichip.com/drivers/vcp-drivers/) if the adapter appears under USB but no serial port appears. For PL2303, use guidance for that adapter from its manufacturer. Identify the chip first; a driver for one chipset does not fix the other.

FTDI [distinguishes VCP from D2XX](https://ftdichip.com/drivers/): VCP exposes a serial port, while D2XX is a direct-access API. This app uses the serial-port path and does not call D2XX. Installing a D2XX library alone does not create the serial port this app needs. The [Lab599 manual](https://downloads.lab599.com/TX500/Lab599-TX500-User-Manual-EN-v1.12.08-04.2022.pdf) says to install a driver manually *if the OS does not install one automatically*; the [current Lab599 downloads page](https://lab599.com/downloads/) labels its FTDI and PL2303 driver packages for Windows. A visible port is only a first check: verify CAT communication in CAT Studio. Digital operation also needs an audio interface, appropriate radio settings, and working audio routing. We have not validated every macOS release and cable combination.

## What's new in v2.267

- Preferences now fit the visible screen, can scroll on shorter displays, and support keyboard Tab navigation through Station fields. The main window no longer shrinks after entering full screen.
- CAT model labels follow Lab599's documented IDs: `ID505;` identifies TX-500MP, while `ID500;` identifies only the TX-500 family. The legacy accepted `ID501;` and `ID502;` replies no longer claim a specific model.
- The Station workspace's **Official region plan** button opens an IARU document for the saved profile's region. The on-screen chart remains the simplified Region 1 reference.
- Changing the Live Audio palette immediately recolors existing waterfall rows, with a synchronized snapshot between the audio callback and drawing.

Thanks to **EA3JIC** for the careful reports and optional patches that prompted these fixes.

## What's new in v2.266

- Opening the main window or Station preferences no longer reads cloud credentials from Keychain. Logbook and cloud-account views load them when opened.
- Switching preference tabs no longer reloads credentials repeatedly. Saving Station preferences without opening the cloud tab leaves cloud credentials untouched.
- A saved 2FA cookie is read once when used, and an inactive session is not sent.

The Keychain still protects each saved item separately. macOS may ask for access when you open Logbook or Cloud & Logbook Accounts, especially after installing a newly signed build. Prompt counts on an existing user's Keychain cannot be verified by the automated tests.

## What's new in v2.265

- **Firmware safety:** Before bootloader mode, the updater reads `ID;` over normal-mode CAT and requires the documented `ID500;` for TX-500-family firmware or `ID505;` for TX-500MP firmware. Missing, malformed or mismatched replies block transfer. The check expires after ten minutes or a port/firmware change.
- **Reviewed firmware only:** Full-file SHA-256 and the known firmware target are checked again immediately before transfer. The operator must also select the exact model printed on the radio.
- **Limits:** CAT `ID500;` does not distinguish Discovery, PRO and ALTAI. The bootloader's own cross-model rejection behavior has not been verified. A CAT check before a manual power cycle cannot prove that the same physical radio remains connected afterward.

Thanks to **u/kantorcodes1** for asking where cross-model enforcement actually happens and prompting this additional check.

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

The updater accepts only firmware whose complete SHA-256 matches a reviewed official Lab599 release. It checks the BL20 model ID for Discovery and MP images and displays the reviewed firmware target. Before loader mode, it checks the normal-mode CAT `ID;` reply against the firmware family on the selected port; an absent or mismatched reply blocks transfer. Then the operator selects the exact model printed on the radio. PRO and ALTAI releases share Discovery's BL20 model ID, so their targets are distinguished by reviewed full-file hashes. CAT `ID500;` identifies only the TX-500 family, and the radio cannot be queried in bootloader mode. Manual selection and the earlier CAT result do not prove the hardware's exact model at transfer time.

## Functions

| View | What it does | Radio mode |
| --- | --- | --- |
| Station | Local operator profiles, audio routes, saved frequencies, verified CAT tuning and opt-in PSK Reporter uploads | Normal operation, CAT 9600 |
| DX Cluster | Displays live spots and local contact history; tuning and QSO drafts require explicit actions | Normal operation, CAT 9600 for tuning |
| FT8 / FT4 Digital | Live decode and waterfall, manual or automatic QSO sequencing, ADIF logging and simulation | Normal operation, CAT 9600 and audio interface |
| CW Station | Morse keying, live audio decoding, QSO assistant and logging | Normal operation, CAT 9600 and audio interface |
| Voice Keyer | Local voice messages, headphone preview, CQ repeat and microphone reply | Normal operation, CAT 9600 and audio interface |
| Logbook & Cloud | Local QSO records, ADIF import/export, callbook enrichment and configured cloud services | Offline for local records |
| Firmware Update | Select a reviewed official `.fw` file or download from the built-in Lab599 catalog; verify normal-mode CAT identity first, then enter the loader; checks the complete file hash and known target, blocks a mismatch with the CAT family or operator-declared radio model, transfers with a two-ACK handshake and TIOCOUTQ-paced streaming, and prevents system sleep during flash | CAT 9600 first, then bootloader — "The loader is waiting..." |
| Time Sync | Disciplines a continuous internal UTC clock from multi-source NTP, TLS/HTTPS fallback, calibrated holdover and robust FT8 timing consensus; sets the radio to local time or UTC and verifies read-back | Normal operation, CAT 9600 |
| Telemetry | Live arc-gauge dashboard: RF power, SWR (RM1 dots), supply/battery voltage, S-meter, frequency, mode, TX/RX state; rolling averages at 5 m / 15 m / 30 m / 60 m; over-voltage, low-voltage and high-SWR alert guards; selectable poll rate (250 ms / 500 ms / 1 s); Demo Mode | Normal operation, CAT 9600 |
| Radio Screen | Real-time 256×128 LCD mirror via CAT; four display themes (Amber, Cool White / Daylight, Green phosphor, OLED); panadapter spectrum and calibrated meter bars; save screenshot to PNG or copy to clipboard; Demo Mode | Normal operation, CAT 9600 |
| CAT Studio | Verified live controls and band presets; named quick-launch CAT macros with safe command validation and read-back; full 1024-byte settings snapshots with model check and pre-restore backup; app-owned CAT protocol monitor with TX/RX/error filters and response timeline; the separate system console starts collapsed | Normal operation, CAT 9600 |
| Settings | Read, save, open and restore the full 1024-byte `.set` backup; read-back comparison after every write | Normal operation, CAT 9600 |
| Memory | Read, edit, save, open and write 100 channels using the original 600-byte `.mem` format; built-in operating profiles (SOTA/POTA, FT8/JS8Call, Contest); CSV import/export; read-back comparison after every write; file editing without a connected radio | Normal operation, CAT 9600 |
| CAT Connection | Lists possible macOS serial ports and gives CAT setup and VCP troubleshooting guidance; radio identity is checked in CAT Studio | CAT adapter for live checks |
| Documentation | Embedded Lab599 manuals, schematics and firmware download library | — |
| Feedback & Suggestion | Structured bug report and feature request form; auto-collects macOS version and hardware model (`sysctl hw.model`); generates a pre-filled GitHub issue URL or copies Markdown to clipboard | — |

For operating details, see the [Station](STATION.md), [DX Cluster](DX-CLUSTER.md), and [Voice Keyer](VOICE-KEYER.md) guides.

Only one radio operation runs at a time. Telemetry and Radio Screen stop automatically when switching to another view. CAT Studio, Settings and Memory have a cooperative Stop button; partial writes are reported explicitly. File editing and Demo Mode work without a connected radio. Unsaved memory banks are protected by replacement and exit prompts.

Settings is a complete-block backup/restore tool matching the original utility; it does not identify individual setting fields. Memory exposes frequency, mode and preamplifier/attenuator. DIG uses the same stored code as USB. Writing memory replaces all 100 slots, including empty ones.

## Voice Keyer

The **Voice Keyer** sidebar panel records/imports local voice messages, previews them on a separate headphone output, sends one-shot replies, repeats CQ with adjustable receive gaps, and offers hold-to-talk microphone replies. It has exclusive radio ownership while open, verified CAT TX/RX transitions, cancellation of queued work, selected-device audio routing, and an explicit stop on radio changes or connection loss. [Setup, behavior and hardware validation limits](VOICE-KEYER.md).

## Network and privacy

PSK Reporter submissions are opt-in. DX Cluster connects only when you select **Connect**; it uses unencrypted public Telnet/TCP nodes and sends a callsign for login, so do not use a password-protected node. Cloud integrations require their own configuration, and credentials are stored in macOS Keychain. Simulation and Demo modes let you explore supported views without transmitting RF.

The app does not read cloud credentials just to open its main window or the Station preferences. It reads cloud Keychain items when you open Logbook, open Cloud & Logbook Accounts, or use a cloud service. The locally signed release may still prompt for access to individual saved items, especially after replacing the app with a new build; macOS controls those prompts. No Keychain access checks are disabled to suppress them.

## Use

Open **Lab599 Utility.app**, connect the CAT-USB cable and choose the serial port from the port menu. Tap **Refresh** if the port does not appear. Close other applications using the same port.

- **Firmware Update** — select a reviewed firmware file matching your model. Turn the radio on normally with CAT protocol **LAB599** at 9600 baud, select its port and click **Verify Radio (CAT)**. After a valid ID is shown, power off and enter loader mode according to your model's manual until the display shows *"The loader is waiting..."*. Within ten minutes, click **Update Firmware**, select the model printed on the radio in the confirmation dialog, and keep power and cable connected until completion. New or custom firmware must be reviewed and added to the app's hash list before it can be flashed.
- **Station, DX Cluster tuning, digital/CW/voice operation, Time Sync, CAT Studio, Settings, Memory, Telemetry, Radio Screen** — turn the radio on normally; set its CAT Protocol menu to **LAB599** at 9600 baud. Menu numbering varies by model and firmware. Digital/CW/voice features also need a suitable audio route.
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

The output is `Lab599 Utility.app`, a universal `arm64`/`x86_64` bundle. `--build-only` increments the source version and build number. To rebuild the current source version without changing either number, use `sh build-utility.sh --build-current`.

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

**Physical-radio result:** EP2AES used the macOS updater on his own TX-500 Discovery to update its firmware from 1.26.10 to 1.30.00. The transfer took about 20 seconds, and the radio restarted on 1.30.00. This is one successful real-radio update; it is separate from the v2.263 automated test run described above, which did not access a physical radio. Compatibility across other hardware revisions, firmware versions, USB adapters and radio models remains unconfirmed. Test firmware updates and transmit control carefully on the target hardware before relying on them. Settings acknowledgement contents and some reply framing remain unspecified by the original programs. Memory modem-control signals cannot be verified with pseudo-terminals.

## Project

Independent software, not an official Lab599 product. GitHub repository: [fact0real/Lab599-Utility](https://github.com/fact0real/Lab599-Utility). Author: EP2AES; [blog](https://ep2aes.asis.sh/); contact: `EP2AES@asis.sh`.

See [LICENSE](LICENSE) (GNU GPL version 3) and [THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md) for the bundled third-party components. Manufacturer executables and firmware files are not included in the release package.
