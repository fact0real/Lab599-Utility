# Startup connections and Lab599 upload privacy: implementation review

Completed locally on October 18, 2026 in response to EA3JIC's three review notes attached to “Startup connections (YAAM and Lab599) and Lab599 upload privacy: material for you (no hurry)”. Tracking: https://github.com/fact0real/yaam-lab599-shared-board/issues/262.

## Findings and decisions

The current sources confirmed construction-time requests in YAAM's satellite, aurora, absorption and solar-image engines, eager documentation/time sampling in Lab599, and reuse of Lab599's unfiltered local ADIF serializer at provider upload boundaries. The original reports distinguish laboratory observations from code-based conclusions; the same distinction is preserved here.

YAAM now retains offline/bundled state at engine construction. Each visible map consumer registers independent demand for its enabled layers; shared engines use a single refresh timer, and the last disappearing consumer stops it and cancels the pending request. NASA images subscribe only while their solar pane or zoom is visible. Cancellation invalidates request identifiers so stale callbacks cannot publish after disabling or switching demand. Settings > Data Safety > Public data feeds controls these four feeds together, with persisted choices. Public feeds remain allowed by default, but engine construction alone never downloads. Restored visible layers can request data. Weather, other propagation services, account integrations and MapKit have separate triggers.

Lab599 documentation requests moved from controller construction to opening Documentation or Refresh. Network time defaults off and starts only after opt-in and opening Time Sync or starting FT8 monitoring. It uses the existing three NTP sources, with no HTTPS fallback; disabling stops the timer and prevents subsequent queries/adoption. NTP failure retains existing holdover, radio consensus and transmit timing gates. CW sidetone construction moved to first playback.

Lab599's upload projection starts from an allowlist per destination. QRZ, Club Log and eQSL retain core contact/award fields. Optional names/QTH and station descriptions, contact email/precise locators, and comments each require their own default-off switch. Station descriptions (`MY_NAME`, `MY_CITY`, `MY_RIG`, `MY_ANTENNA`) are grouped with names/QTH rather than shared by default. Coarse state/country and award fields remain core. Local lookup email saving remains unchanged, and local presence is not upload consent. Statuses, `MY_CALL`, unknown, `APP_*` and `*_INTL` fields stay out of uploads.

LoTW has its own limited signing set and six-character maximum station grid regardless of optional switches. Single, full-logbook and selected/pending uploads use the same projection; manual exports and stored/imported records retain their fields. Whole-logbook status updates use the same record snapshot as its uploaded document. Only TQSL exit 0 marks an upload successful. Provider toggles are also checked at individual send boundaries. Cloud Settings > Privacy exposes the automatic, destination, optional-field and NTP controls; unset preferences default off and explicit existing choices are preserved. The automatic switch applies to new-QSO uploads; destination switches also apply to manual sync.

## Verification

- YAAM `PublicDataFeedActivityRegression`: construction makes no request, multiple consumer identities share demand, disabled policy cancels, settings persist, visible demand resumes, and refresh timers stop when the last consumer disappears.
- YAAM Debug scheme build, code signing disabled.
- Lab599 `run-logbook-cloud-tests.sh`: existing logbook/cloud suite plus independent privacy opt-ins, allowlists, strict LoTW projection, locator validation/truncation, length-aware embedded-tag/malformed input checks, all upload route coverage, preserved local ADIF, and all nine settings controls. Standard preferences are injected with a unique test suite so repeat runs cannot inherit previous test settings.
- Lab599 `run-startup-privacy-tests.sh`: documentation construction is quiet; explicit requests use offline stand-ins; disabled NTP is quiet; enabled sampling targets only the three documented sources; disabling prevents further queries; sidetone is absent from initialization.
- Existing time-discipline suite: slew/outlier/holdover, FT8 consensus and audio-clock tracking.
- Existing 18 independent CW transmit-safety checks, with no audio devices or radio.
- Offline Help guide verification.
- Universal Lab599 build (`--build-current`, arm64 and x86_64), preserving version 2.285/build 291.
- Light/dark snapshots of the added YAAM control and Lab599 Privacy tab content at narrow and wide widths; source whitespace checks.

The new Lab599 regressions are wired into its standard test build. No provider upload, real TQSL upload or radio transmission was performed.

## Remaining observational questions

Y-063's one-off normal exit at roughly 21 seconds has not been reproduced or attributed. Y-064's four NOAA DNS lookups cannot be mapped one-to-one to requests from the report alone. Y-065's authenticated-startup behavior requires isolated account-enabled testing. These original cards are not closed by this implementation task. No packet-capture certification, real-radio/audio test, provider-retention claim, or certification of every macOS permission prompt is implied.

Apple MapKit can still connect for the default Station screen; its configuration host and viewport exposure are documented. HamQTH login and LoTW confirmation-download query-string credential exposure are documented; their protocols were not changed on an unverified assumption about POST support.

This records implementation and verification before publication. Commit links and publication status are recorded on the tracking issue; a source push does not constitute a released application version. The earlier EP2AES QSL-card changes remain intact.
