# Lab599 Utility v2.265 (Build 271)

This pre-release adds a normal-mode radio identity check before firmware transfer. Select a reviewed official `.fw` file, turn the radio on normally with CAT set to LAB599 at 9600 baud, then click **Verify Radio (CAT)**. The updater reads `ID;` on the selected port. It requires `ID500;` for TX-500-family firmware or `ID505;` for TX-500MP firmware. A missing, malformed or mismatched reply blocks the update before any firmware is sent. The check expires after ten minutes or when the selected port or firmware changes.

After verification, enter loader mode using the instructions for your radio model. Click **Update Firmware** and select the exact model printed on the radio. The app rechecks the complete firmware SHA-256 against its reviewed official-release list and blocks a mismatched model before opening the bootloader port. The transfer protocol itself is unchanged.

**Known limits:** `ID500;` identifies the TX-500 family; it does not independently distinguish Discovery, PRO and ALTAI. The radio is power-cycled into bootloader mode after the CAT check, so the app cannot prove the same physical radio remains connected. We have not established whether the bootloader rejects a firmware image for a different model. This build has passed simulated serial tests and a universal macOS build, but the new two-stage update flow has not yet been validated on physical radio hardware. Keep stable power connected and follow the model-specific loader instructions.

Thanks to **u/kantorcodes1** for asking where cross-model protection actually happens. That question led directly to the pre-bootloader CAT check and clearer limits in the app and documentation.

**Download:** `Lab599-Utility-v2.265-macOS-universal.zip` contains the macOS 12+ app for Apple Silicon and Intel, English and Persian guides, and license notices. Compare its SHA-256 with `SHA256SUMS.txt`. The app is locally signed, not Apple notarized. Manufacturer firmware is not included.
