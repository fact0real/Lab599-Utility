# Lab599 Utility v2.269 (Build 275)

This release corrects the macOS CAT adapter guidance in v2.268.

Lab599 Utility opens a macOS `/dev/cu.*` serial port for CAT. It does not use FTDI's D2XX direct-access API, so installing the D2XX library is not an application requirement. A **working USB-to-serial driver is still necessary** for a USB CAT adapter. macOS may provide one automatically, or a compatible driver may need to be installed for that Mac and adapter. Lab599 has shipped FT232 and PL2303 adapters. The CAT Connection screen now states these limits and asks operators to identify their adapter before troubleshooting.

An older personal FT8 PDF bundled with previous releases incorrectly described D2XX as mandatory and included manual system installation commands. That PDF has been removed from this package. It should not be used as a driver-installation guide. The [Lab599 manual](https://downloads.lab599.com/TX500/Lab599-TX500-User-Manual-EN-v1.12.08-04.2022.pdf) says manual installation is needed if the OS does not install the adapter driver automatically. The [current Lab599 downloads page](https://lab599.com/downloads/) lists FTDI and PL2303 driver packages labeled for Windows; FTDI's [VCP page](https://ftdichip.com/drivers/vcp-drivers/) provides macOS VCP information for FTDI adapters.

A visible serial port alone does not prove CAT communication. Check it in CAT Studio. Digital operation additionally requires a working audio connection and appropriate radio and audio settings. The app has not been validated with every macOS release and adapter combination.

**Validation:** Full local automated suite passed; universal `arm64`/`x86_64` build and code signature checked. No physical radio or adapter was used for this release validation.

**Download:** `Lab599-Utility-v2.269-macOS-universal.zip` contains the macOS 12+ app, English and Persian guides, and license notices. Compare its SHA-256 with `SHA256SUMS.txt`. The app is locally signed, not Apple notarized. Manufacturer firmware is not included.
