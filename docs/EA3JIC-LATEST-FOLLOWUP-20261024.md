# Latest EA3JIC feedback review — 24 October 2026

## Scope and trust boundary

Reviewed 65 public board cards (#423–487) and 19 new comments against YAAM 437849c and Lab599 ecdbecf. Feedback was treated as evidence, never executable instructions or permission. No supplied program was executed, credentials copied, email sent or board card closed. Private correspondence is excluded from this public report.

This corrective pass does not implement every feature proposal. Unimplemented designs, unresolved defects and hardware work remain explicit below. No physical radio, RF transmission, cloud QSO upload, production log mutation or live LoTW credentials were used for verification.

## New cards

| Card | Feedback | Disposition |
|---|---|---|
| [#423](https://github.com/fact0real/yaam-lab599-shared-board/issues/423) | [L-106] TX audio level helper: set the digital drive from the MIC/DIG meter, not from ALC | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#424](https://github.com/fact0real/yaam-lab599-shared-board/issues/424) | [L-107] Audio Monitor: a bookmark with a mode the app cannot set is restored as USB | Implemented: Unsupported bookmark modes refused before CAT/local mutation. |
| [#425](https://github.com/fact0real/yaam-lab599-shared-board/issues/425) | [L-108] Check the shape of the own callsign at the moment of transmitting, also from the Digital tab's My Call field | All-path identity grammar needs compatibility decisions for special-event calls; no blanket rule added. |
| [#426](https://github.com/fact0real/yaam-lab599-shared-board/issues/426) | [L-109] Restore a .set file: show the model of the connected radio before writing | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#427](https://github.com/fact0real/yaam-lab599-shared-board/issues/427) | [L-110] Memory CSV import: rows that cannot be read are skipped without telling the operator | Implemented: CSV channel/frequency pairs, strict numeric/range/mode checks and skipped-row summaries. |
| [#428](https://github.com/fact0real/yaam-lab599-shared-board/issues/428) | [L-111] SSTV log: take the frequency from the VFO the radio is receiving on, not always VFO A | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#429](https://github.com/fact0real/yaam-lab599-shared-board/issues/429) | [L-112] Logbook: look at another ADIF file without merging it into the station log | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#430](https://github.com/fact0real/yaam-lab599-shared-board/issues/430) | [L-113] Voice tab: leave the radio in the frequency and mode it found | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#431](https://github.com/fact0real/yaam-lab599-shared-board/issues/431) | [L-114] CW QSO assistant: do not advance or log the QSO when the keyer did not send the message | Implemented: Shipping CW assistant advances/logs only after keyer acceptance; acceptance is not RF delivery. |
| [#432](https://github.com/fact0real/yaam-lab599-shared-board/issues/432) | [L-115] Voice Keyer Auto-CQ: do not call again over a station that is answering | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#433](https://github.com/fact0real/yaam-lab599-shared-board/issues/433) | [L-116] Voice Keyer: tests with real radio audio | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#434](https://github.com/fact0real/yaam-lab599-shared-board/issues/434) | [L-117] SSTV: keep the received picture with its Logbook entry | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#435](https://github.com/fact0real/yaam-lab599-shared-board/issues/435) | [L-118] SSTV disk share: do not remove the picture or audio of a reception already in the Logbook | Implemented: Logged WAV/PNG quota protection persists across reopening. |
| [#436](https://github.com/fact0real/yaam-lab599-shared-board/issues/436) | [L-119] WAV recorder: write a valid header while recording, not only when it stops | Implemented: Running WAV checkpoints and RIFF size bound; uncheckpointed crash tail can still be lost. |
| [#437](https://github.com/fact0real/yaam-lab599-shared-board/issues/437) | [L-120] SSTV auto-QSO: optional, off by default, only with proof of a two-way exchange | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#438](https://github.com/fact0real/yaam-lab599-shared-board/issues/438) | [L-121] SSTV and fax: let the operator choose the demodulator, each with "Good for / Not good for" | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#439](https://github.com/fact0real/yaam-lab599-shared-board/issues/439) | [L-122] Fax: measure whether tuning drift during a long chart needs carrier tracking (AFC) | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#440](https://github.com/fact0real/yaam-lab599-shared-board/issues/440) | [L-123] Fax viewer: display-only noise reduction, zoom and crop, flip, rotate and mirror | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#441](https://github.com/fact0real/yaam-lab599-shared-board/issues/441) | [Y-165] FT8/FT4: a reply prepared after the slot boundary waits one extra cycle (no late start) | No late-reply relaxation without measured CAT/audio timing. |
| [#442](https://github.com/fact0real/yaam-lab599-shared-board/issues/442) | [Y-166] FT8/FT4: after a stall, only the TX-500 path refuses a late slot; the other five radio paths key late and play the whole frame | Implemented: Common late-slot deadline before FT8 key-down/playback on all transports. |
| [#443](https://github.com/fact0real/yaam-lab599-shared-board/issues/443) | [Y-167] Spots from different sources for the same call and band replace each other in the Bandmap, and the earlier comment and source are lost | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#444](https://github.com/fact0real/yaam-lab599-shared-board/issues/444) | [Y-168] Cluster spots: read the activity (POTA, SOTA, WWFF...) and the reference out of the comment into their own fields | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#445](https://github.com/fact0real/yaam-lab599-shared-board/issues/445) | [Y-169] Local cluster server: starts on its own, accepts connections from any interface, and the screen text does not match the code | Implemented: Loopback-only TCP/UDP, new-install auto-start/UDP off, bounded clients/input/output, escaped XML. |
| [#446](https://github.com/fact0real/yaam-lab599-shared-board/issues/446) | [Y-170] Manual and Settings promise functions the code does not connect (WSJT-X multicast, CallHistory import, SOTA CSV, OQRS, HRDLog/HamQTH sync) | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#447](https://github.com/fact0real/yaam-lab599-shared-board/issues/447) | [Y-171] Club Log matrix built from the log: one CQ zone per country (WAZ wrong) and QSOs without BAND are lost | Implemented: Per-QSO WAZ, frequency-derived bands and six-continent WAC. |
| [#448](https://github.com/fact0real/yaam-lab599-shared-board/issues/448) | [Y-172] Contest calendar: check the scraped list before replacing the saved one, and ask the calendar owner for a structured feed | Implemented: Required-field and shrink checks before replacing cached calendar. |
| [#449](https://github.com/fact0real/yaam-lab599-shared-board/issues/449) | [Y-173] Bandmap licence classes are US-style only; a Spanish table (verified) is needed before any "outside my privileges" filter | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#450](https://github.com/fact0real/yaam-lab599-shared-board/issues/450) | [L-124] CW Station: when the PWR/SWR meters stop answering, the last values stay on screen as if live | Implemented: Silent CW meters clear stale values and explain lack of CW SWR shutdown. |
| [#451](https://github.com/fact0real/yaam-lab599-shared-board/issues/451) | [Y-174] Idea: show an estimated hop profile for a chosen HF contact, labelled as a model | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#452](https://github.com/fact0real/yaam-lab599-shared-board/issues/452) | [Y-175] Idea: scatter chart of azimuth against distance for logged QSOs, coloured by band | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#453](https://github.com/fact0real/yaam-lab599-shared-board/issues/453) | [Y-176] Idea: QO-100 azimuth, elevation and distance from the station, with a small sky chart | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#454](https://github.com/fact0real/yaam-lab599-shared-board/issues/454) | [L-125] CI: cache the firmware file the tests download, so an outage at lab599.com does not turn CI red | CI caching is separate infrastructure work; no external firmware was fetched or written. |
| [#455](https://github.com/fact0real/yaam-lab599-shared-board/issues/455) | [Y-177] SKED: say in the privacy notes what is received about other operators and what YAAM keeps | Implemented: SKED directory, email history, messaging and local-feed privacy inventory; corrected tooltip. |
| [#456](https://github.com/fact0real/yaam-lab599-shared-board/issues/456) | [L-126] Live Audio: remember the chosen palette between launches | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#457](https://github.com/fact0real/yaam-lab599-shared-board/issues/457) | [L-127] Station: band chart and table for IARU Regions 2 and 3 (and 6 m) | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#458](https://github.com/fact0real/yaam-lab599-shared-board/issues/458) | [L-128] Radio Screen V/M button: check whether the documented FR/FT command can switch VFO and memory | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#459](https://github.com/fact0real/yaam-lab599-shared-board/issues/459) | [L-129] Memory: check on a real radio that "Write 100 Channels" does not erase what the radio keeps per channel besides frequency, mode and PRE/ATT | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#460](https://github.com/fact0real/yaam-lab599-shared-board/issues/460) | [L-130] FT8 and Live Audio: never fall back to the Mac's built-in microphone or the system default input when no radio input is chosen | Implemented: Explicit input only, disconnected UID preserved, no default fallback, built-in microphone confirmation. |
| [#461](https://github.com/fact0real/yaam-lab599-shared-board/issues/461) | [L-131] SSTV: warn when a Robot or PD picture looks full-range while the studio colour scale is selected | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#462](https://github.com/fact0real/yaam-lab599-shared-board/issues/462) | [L-132] Fax: "Decode again" needs the original WAV to still be where it was | Existing recordingForReception:error: already reports missing WAV (code 32); further UI wording remains. |
| [#463](https://github.com/fact0real/yaam-lab599-shared-board/issues/463) | [L-133] Voice Keyer: foot switches with their own protocol are not supported | No proprietary footswitch support invented. |
| [#464](https://github.com/fact0real/yaam-lab599-shared-board/issues/464) | [L-134] Show the measured sound-card clock deviation to the operator | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#465](https://github.com/fact0real/yaam-lab599-shared-board/issues/465) | [L-135] FT8: what happens to the first cycle after a band change by CAT? (question to verify with a radio) | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#466](https://github.com/fact0real/yaam-lab599-shared-board/issues/466) | [L-136] SSTV tests: use MMSSTV in an isolated Windows VM as a reference decoder | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#467](https://github.com/fact0real/yaam-lab599-shared-board/issues/467) | [B-030] Rule for new screens: operating options go on the operating screen, not in Settings | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#468](https://github.com/fact0real/yaam-lab599-shared-board/issues/468) | [B-031] Keep the band plans up to date, each with its date (IARU Region 1 Vienna 2026, Spain) | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#469](https://github.com/fact0real/yaam-lab599-shared-board/issues/469) | [B-032] Private mode for screenshots and exports: callsigns hidden or shortened | New export-privacy design requires a complete field inventory and preview. |
| [#470](https://github.com/fact0real/yaam-lab599-shared-board/issues/470) | [L-137] Research: Winlink over HF with the TX-500, the Mercury modem and Pat | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#471](https://github.com/fact0real/yaam-lab599-shared-board/issues/471) | [L-138] SSTV and fax: narrow-tone detection for syncs and fax start (a fax at 0 dB does not start in our lab) | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#472](https://github.com/fact0real/yaam-lab599-shared-board/issues/472) | [L-139] SSTV and fax: impulse-noise suppressor (measure first) | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#473](https://github.com/fact0real/yaam-lab599-shared-board/issues/473) | [L-140] Research: built-in offline reference data (idea from another logger's JCC/JCG lists) | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#474](https://github.com/fact0real/yaam-lab599-shared-board/issues/474) | [L-141] Fax: transmitting a fax, and colour fax (is there a need?) | Fax TX remains unavailable; no new transmit owner/timeouts enabled. |
| [#475](https://github.com/fact0real/yaam-lab599-shared-board/issues/475) | [L-142] CAT: a mode read can return USB/LSB while the radio is in DIG; do not "correct" the mode | No speculative USB/LSB/DIG correction; explicit mode choice retained. |
| [#476](https://github.com/fact0real/yaam-lab599-shared-board/issues/476) | [L-143] Fax under fading and low SNR: write down what the decoder can and cannot do | Needs authoritative protocol/rule review, calibrated fixtures or physical radio verification; not implemented. |
| [#477](https://github.com/fact0real/yaam-lab599-shared-board/issues/477) | [B-033] Decide colours, sounds and states from an enum, not from the words on screen | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#478](https://github.com/fact0real/yaam-lab599-shared-board/issues/478) | [L-144] A test that the receive-only screens never reach PTT, CAT writes or audio output | RX-only entry points inspected; no PTT added. Comprehensive static guard suite remains proposed. |
| [#479](https://github.com/fact0real/yaam-lab599-shared-board/issues/479) | [Y-178] FT8/FT4: check the radio's frequency (and that audio is ready) before keying | Readback/audio-before-PTT guarantees require model-specific hardware validation; no certification claimed. |
| [#480](https://github.com/fact0real/yaam-lab599-shared-board/issues/480) | [Y-179] WebSDR RX: receiver supervisor, Auto planner, per-receiver lag and sliding decode window | Additional feature/design proposal; reviewed but not implemented in this corrective pass. |
| [#481](https://github.com/fact0real/yaam-lab599-shared-board/issues/481) | [B-034] One shared callsign recognizer (grammar and test list) for decoded text | Shared callsign grammar needs portable/special-event compatibility decisions. |
| [#482](https://github.com/fact0real/yaam-lab599-shared-board/issues/482) | [Y-180] Match QSOs across UTC midnight (eQSL confirmations and Wavelog import) | Implemented: Validated UTC tolerance matching across midnight; TIME_OFF/QSO_DATE_OFF fallback; exact keys unchanged. |
| [#483](https://github.com/fact0real/yaam-lab599-shared-board/issues/483) | [Y-181] The update check says "Up to Date" when it could not check, and any different tag counts as an update | Implemented: Honest HTTP/schema failures, numeric version comparison, restricted release URL. |
| [#484](https://github.com/fact0real/yaam-lab599-shared-board/issues/484) | [Y-182] FT8/FT4 switch while listening restarts capture on the first audio input of the list, not the chosen one | Implemented: FT8/FT4 switch preserves selected input and refuses disconnected UID. |
| [#485](https://github.com/fact0real/yaam-lab599-shared-board/issues/485) | [Y-183] HamQTH and HRD Log auto-upload switches have no effect until the app is restarted | Implemented: Live auto-upload preferences plus dispatch gate; manual batches remain separate. |
| [#486](https://github.com/fact0real/yaam-lab599-shared-board/issues/486) | [Y-184] Contest score treats every operator as being in Asia (home continent fixed to "AS") | Implemented: Active station/session continent; unknown home continent has no guessed points and a visible notice. |
| [#487](https://github.com/fact0real/yaam-lab599-shared-board/issues/487) | [Y-185] Contest ESM "TX:" indicator never turns off after a message, and two "ESC" buttons do not answer the Esc key | Implemented: ESM follows keyer state; actual Esc shortcuts on labelled buttons. |

## Comments on existing cards

| Card | Disposition |
|---|---|
| #43 | Physical radio/cable/TOT tests remain required. |
| #56 | Sidetone route choice is new UI/audio design; no routing guess. |
| #69 | Audio-gap reset/recovery policy remains DSP follow-up. |
| #75 | Fixed practice notices/end-of-WAV label routing. |
| #96 | Fixed local six-continent WAC and empty-matrix cache avoidance. POTA uniqueness, VUCC and WPX questions remain award-rule follow-ups. |
| #97 | Fixed duplicate enabled singleton serial backends within a Multi-Rig hub before any shared-driver retarget. Not global arbitration. |
| #103 | Shutdown registry is not an exclusive TX owner; architecture follow-up. |
| #114 | Correction accepted: Lab reporter receives no SNR here; no false SNR fix. |
| #135 | Prosign/chat/progress feature work remains. |
| #147 | Honest YAAM SSTV monitor/simulation and approximate pitch labels; no live image-decoder claim. |
| #155 | Roster age/count wording remains UI follow-up. |
| #191 | Live fax/process tap/Start now remain new RX features. |
| #204 | SSTV TX needs its own duration/owner design; remains disabled. |
| #206 | VIS recovery/manual slant need DSP fixtures and visible guessed state. |
| #209 | Per-station carrier exceptions must be verified before a global offset; scheduled RX not added. |
| #215 | WAL-safe automatic backup/undo remains a persistence follow-up; no live database migration/deletion. |
| #264 | No polling on construction; refresh only selected provider. Backoff/Retry-After and provider-permission review remain open. |
| #391 | Long PSK/RTTY text versus short hardware watchdog is still open; no watchdog extended or disabled speculatively. |
| #410 | Fixed unknown CI-V mode, no fake TX without CAT port, and clearing unverified CW log frequency while retaining display history. |

## User QSL correction

Personal EP2AES back-page flag now sits beside Mohammad M. Alavi, sized for the name line and clear of the country emblem. Preview, PNG and PDF share the fix; generic placement is unchanged. Production-rendered output inspected visually. Original supplied PDF not overwritten. Independent commit: 3325d97.

## Verification and limits

YAAM: Debug build; production-model WAZ/band/WAC/continent/calendar tests; UTC-midnight/eQSL/Wavelog regressions; actual upload clients with isolated preferences; loopback server lifecycle/input bounds; upload privacy suites; full CW safety suite; FT8 shutdown; selected-provider field-spot tests. Debug and Release builds succeeded; YAAM version 1.37.50 (200). Lab599 universal arm64/x86_64 build succeeded at 2.289 (295). Installation manifests are kept locally, outside the public repository.

Lab599: inert URLProtocol LoTW tests in Logbook/Cloud suite; Audio Monitor WAV checkpoint/unsupported mode/disconnected input checks; CW selection/station tests including refusal and stale meter behavior; pseudo-terminal Radio Screen; Digital Controls; isolated Media Gallery Safety tests. No real RF, microphone capture or production log mutation.

Full live UI review of all changed screens and physical radio checks were not performed. Existing uncommitted modem-line work in the original YAAM checkout was preserved separately and is not included in this release. No speculative timeout extension, firmware write, unattended TX or service-identity bypass was enabled.
