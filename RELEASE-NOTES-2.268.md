# Lab599 Utility v2.268 (Build 274)

This update corrects the CAT connection page after a content and safety review.

The previous **Driver Install** page incorrectly called FTDI D2XX mandatory, treated a library file as proof of a working or authorized driver, gave one set of menu numbers for different radios, and offered administrator-level installation and broad removal of system files. The app itself opens macOS serial ports; it does not use the D2XX direct-access API.

The replacement **CAT Connection** page lists possible `/dev/cu.*` ports without claiming that a listed port is a connected radio. It explains the LAB599 CAT protocol and 9600-baud setup, offers a direct route to CAT Studio for a read-only communication check, and links to Lab599 manuals and FTDI's VCP guidance for FTDI-based adapters. It no longer installs, removes, signs, or clears quarantine from system driver files. The unused D2XX binary and headers have been removed from the app and source package. This update does not change any driver already installed on your Mac.

The full local test suite passed. The universal `arm64`/`x86_64` app was built and its code signature verified. The CAT page was visually checked in the built app. Serial-port listing was tested with simulated names; no physical radio or USB adapter was used for this release validation.

**Download:** `Lab599-Utility-v2.268-macOS-universal.zip` contains the macOS 12+ app, English and Persian guides, and license notices. Compare its SHA-256 with `SHA256SUMS.txt`. The app is locally signed, not Apple notarized. Manufacturer firmware is not included.
