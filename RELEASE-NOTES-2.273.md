# Lab599 Utility v2.273 (Build 279)

This build addresses the reported digital-mode, audio, layout, Help, and firmware-preview issues.

- Starting FT8/FT4 requests `MD6;` when needed, then confirms DIG mode, unchanged dial frequency, and RX by CAT before enabling transmit. A failed read-back leaves transmit blocked.
- The Digital tab exposes **Set MHz…** beside the dial and opens the custom-frequency editor from the **Custom…** band choice. Exact MHz input is validated and the requested CAT frequency is read back before use.
- Live Audio monitoring continues when the user visits another section. Explicit Stop and app Quit still stop it. Firmware verification waits for monitoring to stop.
- Help fills the available window height and uses smaller type. The main window clamps to the visible screen, offers horizontal scrolling on narrow displays, and rearranges dense FT8 controls into short rows.
- Firmware Update shows the image for the reviewed firmware's target model at a larger size. The operator must confirm the picture and printed model before CAT verification, then confirm them again before transfer. Changing the firmware file or CAT port clears that confirmation. If the matching image is missing, verification is blocked.

**Validation:** The complete automated test suite passed, including simulated CAT and firmware-transfer checks. A universal `arm64`/`x86_64` app built and passed code-signature verification. A compact FT8 layout screenshot was checked in Simulation mode. Physical-radio operation and the firmware screen's final visual check remain unverified because the Mac locked during the preview attempt. No firmware was sent to the connected radio.

This build is locally signed and is not Apple notarized. Keep a public release marked as a pre-release until the fixes are confirmed on the physical radio.
