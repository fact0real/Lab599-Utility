# Lab599 Utility v2.267 (Build 273)

This update addresses five usability and accuracy reports from EA3JIC. Thank you for testing the app so carefully and sharing the optional patches.

- **Preferences:** Station fields now participate in the Tab key order. The window fits the visible screen, remains resizable, and scrolls its Station content on shorter displays while keeping Save & Apply available.
- **Full screen:** The main window no longer applies normal-window size limits just after entering macOS full screen.
- **CAT model labels:** The documented `ID505;` reply is shown as TX-500MP. `ID500;` is labeled as the TX-500 family; `ID019;` identifies the TS-2000 protocol; and the legacy accepted `ID501;`/`ID502;` replies no longer imply a specific model. Labels require an exact reply. This does not add or claim full TX-500MP feature support.
- **Band-plan source:** The Station button opens the official IARU document for the active saved profile's Region 1, 2, or 3. The embedded frequency chart remains a simplified **Region 1** reference and must not be used as authorization for another region.
- **Live Audio:** Switching between Cyber Cyan and Phosphor Amber recolors existing waterfall rows immediately. The audio callback and renderer share the level buffer through a short lock rather than racing on stored colors.

The full local test suite passed with simulated radios and isolated cloud data. The universal `arm64`/`x86_64` app was built and its code signature verified. Physical TX-500MP behavior, on-air operation, and real display configurations beyond the test machine have not been validated in this release. Firmware transfer safeguards and protocol are unchanged.

**Download:** `Lab599-Utility-v2.267-macOS-universal.zip` contains the macOS 12+ app, English and Persian guides, and license notices. Compare its SHA-256 with `SHA256SUMS.txt`. The app is locally signed, not Apple notarized. Manufacturer firmware is not included.
