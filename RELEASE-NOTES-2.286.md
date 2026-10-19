# Lab599 Utility 2.286 (build 292) — local review

- Radio Screen and CAT Studio use the same strict Lab599 filter parser. FL21
  means RX FIL-3 and TX FIL-2. Invalid, truncated and ambiguous replies show an
  unknown filter. Live filter changes preserve the TX preset and require RX and
  read-back. The Radio Screen no longer invents filter widths, and entering
  Digital no longer writes an undocumented width or resets the TX filter.
- Digital shows a visible operating status and explains the three stop actions:
  Stop FT8/FT4 stops monitoring and TX, Halt TX keeps listening, and Stop Tone
  ends the Tune carrier. Tune follows engine state, not its button label; its
  first live use explains the carrier and 15-second ceiling. Unverified dial or
  DIG state cannot be promoted to verified by pressing Tune.
- The application menu offers Check for App Updates and an optional automatic
  check. Sparkle 2.10.0 verifies signed feeds and update archives before
  extraction. Automatic checks start off, silent installation is disabled, and
  an explicit Install & Relaunch rechecks radio activity. The normal quit guard
  checks again immediately before termination. Firmware updates are separate.

This build is for local review. The signed appcast and release preparation
workflow are staged locally; they have not been published. Public distribution
remains on hold pending Lab599 imagery permission. The first upgrade from
2.285 must be installed manually, because 2.285 has no application updater.

Automated serial fixtures and simulation do not certify physical radio behavior.
