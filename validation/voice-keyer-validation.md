# Voice Keyer validation — 2.178 (184)

Validated on macOS, 2026-09-23.

- Universal standalone release build succeeded for arm64 and x86_64 with warnings treated as errors. The ad-hoc application signature verifies with `codesign --verify --deep --strict`.
- 143 Voice Keyer checks passed: simulated CAT state, fragmented pseudo-terminal responses, WAV conversion and manifest integrity, cancellation races, failed TX/RX acknowledgements, frequency/mode changes, output disappearance, repetition limits, explicit RX windows, native panel layouts, and muted native playback on the built-in output.
- Native panel layouts rendered at 940, 700 and 540 points. The integrated application was also inspected in light and dark appearances. The compact window remains 800 points wide, with a 771-point content fitting width.
- Firmware, TimeSync, TimeDiscipline, Utility, Driver/Docs, Telemetry, Feedback, Screen, CW Station, CW regression, AudioMonitor, FT8, FT8 waterfall and Logbook/Cloud test suites passed. The Utility profile test required an isolated temporary home directory because the restricted test environment could not write its normal Application Support location. See the individual logs in this directory.
- The Xcode Release target built successfully during integration. The final UI refinements were rebuilt and verified through the universal standalone build.
- No physical radio was used, no microphone audio was captured, and no RF transmission occurred. Muted playback validates device selection/start/completion, not transmitted audio fidelity. Actual CAT firmware compatibility, line-input routing, modulation levels, switching latency, live microphone latency and first/last syllable preservation still require a connected TX-500 and its audio interface.

The existing installed application was not replaced. The workspace app and versioned ZIP contain the new feature. See `../VOICE-KEYER.md` for setup and operating details.
