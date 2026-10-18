# Lab599 Utility 2.285 (build 291)

Reviewed integration of EA3JIC's 2026-10-15 proposals, based on 2.284.

- CW Practice/Sim sends neither CAT changes nor radio audio. Tune is refused in
  Practice, ending practice resets its QSO state, and practice contacts stay out
  of the Logbook and cloud uploads.
- CW requires verified DIG mode and VOX off. Missing PT replies keep TX unresolved;
  ABORT remains available and screen handoff cannot discard that ownership.
- CW messages have a 120-second ceiling; CW Station Tune stops after 10 seconds,
  with a separate 15-second carrier watchdog. FT8 Tune has an independent
  15-second watchdog. Stop, Esc, audio failure and sleep request radio release.
- Watchdogs cannot cancel replacement messages, meter reads yield to RX, and
  local audio failures cannot skip release. Unsupported/oversized CW text is
  refused before hardware access. Auto-CQ defaults to 10 calls or 10 minutes and
  stops on an answer or a manual message.
- Local CW sidetone uses the built-in Mac output. If unavailable, sidetone is
  silent; it does not follow the system's default USB/radio output.
- No assumed operator callsign, locator or invented initial QSO frequency. A
  refused band change preserves the prior frequency. Radio Screen uses PT state
  and stops drawing invented Live CAT power/spectrum readings.
- Restore Settings filtering/detail columns, improve ADIF round trips, and improve
  SSTV/Fax galleries with explicit saves, cancellation and no overwrites.
- Existing Keychain names/storage are retained; the proposed cosmetic credential
  migration was deferred.

The app bundle was built locally for Intel and Apple Silicon. This is a software
review and simulated validation, not on-air certification. Physical radio, audio
routing and sleep behavior still need controlled hardware validation. See
[the detailed review](docs/EA3JIC-REVIEW-20261018.md).
