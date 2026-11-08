# Radio Utility Family release validation — 8 November 2026

All checks below use local, isolated release trees. Historical operator logs and contact archives are not release fixtures and are not published. Original working directories were preserved.

## Results

- FX: 277 application tests and 79 core tests passed in the final sealed run.
- ICOM: 254 application and 49 core Swift Testing tests passed. XCTest reported 23 tests with one explicitly skipped hardware test and zero failures. English text check: 230 text files, zero violations.
- Xiegu: all 60 release scripts resolved successfully. The first aggregate run had 59 passes and one localization failure while a concurrent builder had an incomplete app bundle; localization passed when repeated against the final completed bundle.
- Lab599: the complete scripted suite passed after correcting snapshot reply routing and the fake-screen poll handoff. This includes the family storage/concurrency/preservation contract, offline power-calibration, updater/privacy and logbook/cloud simulations. The targeted screen/settings/CW safety suites also passed.
- Storage tests cover concurrent publishers, original app/version/run provenance, isolated settings, rejected malformed values, segment rollover without historical truncation and explicit opt-in boundaries. Shared Swift storage is identical in FX, ICOM and Xiegu; Lab599 exercises the compatible Objective-C contract.
- Receive tests simulate one hour at positive/negative 250 ppm device-rate error. Exchange tests preserve actual report/start evidence across resumed contacts and prevent reuse after changing the exact dial frequency. Loopback CI-V tests reject missing or wrong modulation-source readback before preparation/keying.
- Every final archive passed ZIP CRC, extracted bundle version/build, architecture and deep strict codesign verification. Lab599 archive/feed signatures were generated and verified with the pinned Sparkle tools; the signed feed is published without editing its bytes.

## Boundaries

No physical PTT/RF, firmware programming, real cloud upload or operator credential retrieval was used. Qualified network measurements are still required for clock precision; operating-system USB/audio warnings and RF onset need a live setup. Native offscreen UI capture produced black/partial images, and an isolated native preview could not be launched in this environment; visual interaction with the new panels is therefore not claimed as verified. Compilation, settings consent and storage behavior have independent passing checks.

FX, ICOM and Xiegu packages use Apple Development signing. Lab599 retains its existing ad-hoc application signature plus Ed25519 update archive/feed verification. None is claimed to be Developer ID notarized. Lab599 remains a pre-release; ICOM and Xiegu remain development releases. Existing repository visibility is preserved.

## Exact packages

- FX Radio Utility 0.2.25 build 196: `FX-Radio-Utility-0.2.25-build196.zip` — SHA-256 `6b33ac060ad8be3dd91b8879663751b53e6db32f40be3e53dc8df4122b0a0e56`.
- ICOM Radio Utility 0.1.2 build 3: `ICOM-Radio-Utility-0.1.2.zip` — SHA-256 `697ba4fda85a0789bddbcecb4c718e8afab2279e20d3b41b4148776abd47a5e5`.
- Lab599 Utility 2.293 build 299: `Lab599-Utility-2.293.zip` — SHA-256 `5b1d965c1f8bbc3cd077fe8ed0b69bc543f16ad7dda0976db5fda5876f20f280`.
- Xiegu Utility 0.143 build 143: `Xiegu-Utility-v0.143-build143-macOS-universal.zip` — SHA-256 `9d2446a82e56a050c6b87ef38eac8648f86a6470b4782a00a63d34e76ac07fee`.
