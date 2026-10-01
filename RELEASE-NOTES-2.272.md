# Lab599 Utility v2.272 (Build 278)

This update clarifies the audio and CAT connections and improves FT8 audio-device pairing.

- The tested AD-508 assembly connects directly from the TX-500 REM/DATA port to Mac USB-C. macOS enumerated it as a generic `USB Audio` input and output. The stock blue CAT cable connects separately to the radio's CAT port as a serial adapter. A generic device name does not establish a cable model or the physical location of its audio converter.
- Live Audio, FT8 and CW no longer label every preferred USB audio device as an AD-508. The previous preferred-device ordering remains in place for the tested setup.
- When CoreAudio exposes separate input and output endpoints with a shared device UID prefix, FT8 pairs those endpoints instead of choosing the first similarly named USB output. The selection remains visible and editable in the app.
- The offline Help, English README and Persian quick start reflect the tested connections. Lab599's [2025 product catalog](https://downloads.lab599.com/Lab599-Product-Catalog-2025-EN.pdf) lists AD-508 and AD-509 as distinct products; it does not establish converter placement for every cable revision.

**Validation:** The complete local test suite passed, including FT8 tests for two same-named USB interfaces and a bidirectional interface. The universal `arm64`/`x86_64` app built and passed code-signature verification. The connected Mac enumerated the AD-508 audio device and the stock FTDI CAT adapter. The installed older app held the CAT serial port during this check, so v2.272 was not used to query the physical radio or transmit RF. Keep this release marked as a pre-release until the rebuilt app is validated with the radio.

**Download:** `Lab599-Utility-v2.272-macOS-universal.zip` contains the macOS 12+ app, offline illustrated Help, English and Persian guides, and license notices. Compare its SHA-256 with `SHA256SUMS.txt`. The app is locally signed, not Apple notarized. Manufacturer firmware is not included.
