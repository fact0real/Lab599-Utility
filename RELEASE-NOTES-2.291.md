# Lab599 Utility 2.291 (Build 297)

This pre-release adds product-server application updates and includes the reviewed
local 2.286–2.290 changes. It is ad-hoc signed, not Apple notarized.

## Application updates

- Check for App Updates… and App Update Settings… in the application menu.
- Optional six-hourly, daily or weekly checks; manual is the initial policy.
- Official Sparkle 2.10.1, pinned by upstream archive SHA-256.
- Ed25519 verification of appcast and archive; archive validation before extraction.
- Fixed HTTPS feed at lab599-utility.asis.sh; matching release archives at the same host only.
- Embedded signed release notes; no unsigned API fallback, signature-expiration bypass, automatic installation or system profiling.
- Explicit Install & Relaunch and Later, with radio-activity, receive-recovery, file-operation and unsaved settings/memory checks. Canceled termination returns to the pending installer.
- Existing logs, station preferences and Keychain credentials remain in their existing stores.

Users of 2.285 install this bootstrap release manually once. Version 2.285 has
no updater or pinned update key. App updates never flash radio firmware.

## Included local improvements

- Strict Lab599 filter parsing, verified changes and clearer digital Stop, Halt TX and Stop Tone controls (2.286).
- Responsive CAT release, asynchronous CW preparation, CW QSO metadata corrections, SSTV device-loss handling and cancellable background Fax decoding (2.288).
- Private LoTW confirmation transport, explicit receive inputs, safer CSV import, SSTV recording preservation and stale CW-meter handling (2.289).
- Offline Power Calibration: compare manually recorded meter dots with external wattmeter observations or import EA3JIC v0.7 sweep CSV. Measured-range interpolation and CSV/report export; no radio connection or transmission (2.290).

Validation uses simulated serial devices, isolated data stores and disposable
local app copies. No RF transmission is part of release testing. Physical radio,
firmware, audio-interface and cloud-provider behavior retain their documented limits.
