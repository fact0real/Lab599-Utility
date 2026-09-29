# Lab599 Utility v2.266 (Build 272)

This update reduces repeated macOS Keychain access during normal app startup. Opening the main window or Station preferences no longer reads cloud credentials merely to build hidden Logbook and Cloud views. Credentials are loaded when you open those views or use a cloud service.

Cloud preferences now load credentials once per opening, and saving Station preferences without visiting the cloud tab leaves saved cloud credentials untouched. The 2FA session path no longer reads the same cookie twice for one request, and inactive sessions are never used.

**Limit:** Existing credentials remain separate items in macOS Keychain. The app is locally signed, so macOS may still request access to individual items when you open Logbook or Cloud & Logbook Accounts, particularly after replacing the app with a new build. This change does not disable Keychain access controls. We have not measured the number of prompts on an existing user's Mac.

The full local test suite passed with simulated radios and isolated cloud credentials. The universal `arm64`/`x86_64` app was built and its code signature verified. No physical radio, RF transmission or personal Keychain was used for these checks.

**Download:** `Lab599-Utility-v2.266-macOS-universal.zip` contains the macOS 12+ app, English and Persian guides, and license notices. Compare its SHA-256 with `SHA256SUMS.txt`. The app is locally signed, not Apple notarized. Manufacturer firmware is not included.
