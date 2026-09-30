# Lab599 Utility v2.270 (Build 276)

This release adds an **offline, illustrated Help section** inside the app. Open it from the sidebar or **Help → Lab599 Utility Help**. A topic index links to setup, CAT diagnostics, Station, FT8/FT4, CW, Voice Keyer, Live Audio, logging and cloud services, DX Cluster, Radio Screen, Telemetry, Settings, Memory, Time Sync, firmware updating, documentation, feedback and troubleshooting.

The guide includes 15 screenshots captured from the app with no physical radio connected. Simulation and demo views are identified in their captions. It distinguishes a listed serial port from a verified CAT connection, explains that digital audio needs a separate route, and gives the firmware update sequence and its model-verification limits. The Help page is bundled locally, needs no network access, and has no executable scripts or remote media.

**Validation:** The guide's image files, internal links and accessibility descriptions were checked. The universal `arm64`/`x86_64` app was built and its code signature verified. The in-app Help layout was visually checked. No physical radio or RF transmission was used for this release validation.

**Download:** `Lab599-Utility-v2.270-macOS-universal.zip` contains the macOS 12+ app, offline Help, English and Persian guides, and license notices. Compare its SHA-256 with `SHA256SUMS.txt`. The app is locally signed, not Apple notarized. Manufacturer firmware is not included.
