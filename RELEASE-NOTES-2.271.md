# Lab599 Utility v2.271 (Build 277)

This maintenance release fixes the Live Audio waterfall palette test on Retina Macs. The test now renders both 1x and 2x snapshots on every test Mac and converts its view-space sample point to bitmap pixels using each snapshot's horizontal and vertical scale. This is a **test-only** change; the app's palette rendering, audio processing and radio behavior are unchanged.

Thanks to **EA3JIC** for the precise report and suggested patch. The change was reviewed before implementation; no supplied patch was applied blindly.

**Validation:** The old test reproduced the reported failure with a forced 2x snapshot; the corrected AudioMonitorTests suite passed at both 1x and 2x (15/15). The full `build-utility.sh --test-only` suite passed, and the universal `arm64`/`x86_64` app was rebuilt and its code signature verified. No physical radio or RF transmission was used for this release validation.

**Download:** `Lab599-Utility-v2.271-macOS-universal.zip` contains the macOS 12+ app, offline illustrated Help, English and Persian guides, and license notices. Compare its SHA-256 with `SHA256SUMS.txt`. The app is locally signed, not Apple notarized. Manufacturer firmware is not included.
