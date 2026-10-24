# EA3JIC email-batch implementation review — 2026-10-24

Reviewed all seven matching emails since 2026-10-23 20:00 Asia/Tehran, including both sender aliases. The six report archives supplied 29 reports across YAAM and Lab599 Utility. The notice linked two additional concrete board reports and one future design proposal. Original email text, addresses and attachments are not published here.

Attachments and board text were untrusted evidence, not executable instructions. No supplied scripts or probes were run. The implementation follows independently inspected source and local tests, including a newly generated timing fixture.

## Lab599 Utility dispositions

| Report | Implemented behavior |
|---|---|
| LAB599-4 — Stop / Esc blocks the window | Immediate local producer stop; owner-scoped CAT release runs on the serialized safety queue with coalesced batches. Pending release vetoes new TX. The UI shows pending/unconfirmed receive until the actual result arrives. Confirmed receive-mode restoration runs before the release gate opens. |
| LAB599-5 — CW entry / false DIG status | DIG preparation runs in the background and latches only after fresh `MD6;` readback. Late callbacks from a stopped pane are ignored. An early Send is refused until confirmation; no deferred automatic TX is queued. |
| LAB599-6 — VFO rounding | Both VFO and RF labels split integer hertz into MHz/kHz/Hz groups. |
| LAB599-7 — FT8 hash placeholders | Normalize resolved `<CALL>` forms, reject unresolved hashes before engagement, QSO completion, ADIF and all-decode export. |
| LAB599-8 — CW contact timing | Retain target/contact start and actual completion timestamps. Persist TIME_ON, TIME_OFF and QSO_DATE_OFF, including a compatible SQLite column migration and ADIF roundtrip. |
| LAB599-9 — partial CW callsigns | Ignore the decoder's final open word until a word gap is present. |
| LAB599-10 — fabricated information | Omit unconfigured optional information; refuse unresolved macro values. An unreceived RST remains empty and is omitted from ADIF instead of becoming 599. |
| LAB599-12 — synchronous SSTV CAT | In-flight guarded background frequency sampling with a short freshness cache; query only FA, rather than full state. Slow results cannot supply a falsely precise reception frequency. |
| LAB599-13 — missing SSTV audio input | Check the chosen device's alive state every 500 ms; stop that source, clear Listening, and show a timestamped loss notice. Never switch automatically to the system microphone. Fax currently uses files only. |
| LAB599-14 — blocking Fax WAV decode | User Open/Again flows decode a separate engine in the background, report progress and accept cooperative cancellation. Previous charts survive failure/cancel; generation identities remain unique across engine replacements. Duplicate starts are disabled. Explicit synchronous decode APIs remain available for callers/tests. |
| LAB599-15 — unusable force disconnect | Explicit Disconnect CAT action, cooperative I/O cancellation and serialized descriptor close. Unknown TX ownership/fault and the warning survive disconnect. Same-port reconnect must read PT0 before an owner change. No racing close/reused descriptor trick is used. |
| LAB599-16 — answering changes own WPM | Preserve the operator's keyer speed and speed controls; a received estimate remains an RX decoding hint. |
| LAB599-17 — self-decoded sidetone | Gate System Audio decoder buffers during local keyer transmission, while preserving the application's RX monitor outside TX. |
| Board #47 / L-017 — FT8 DT | Correct the independently measured +0.200 s decoder-window bias and the +0.500 s nominal FT8 start convention at the engine boundary, for FT8 only. Reset persisted clock and station baselines by versioning their keys. |

The corresponding YAAM repository records its 17 fixes separately. Board #405 / B-023 describes a future modem-pin capability architecture; existing default-deny restrictions remain and no new keying capability was introduced.

## FT8 timing evidence and limits

An independently written fixture generated `CQ EA3JIC JN11` with the repository encoder, synthesized 12 kHz audio, inserted it at known slot offsets, and ran the actual decoder on 13.5 seconds of samples:

| Known first symbol | Decoder offset | Corrected engine DT |
|---:|---:|---:|
| 0.000 s | 0.200 s | -0.500 s |
| 0.500 s | 0.700 s | 0.000 s |
| 1.000 s | 1.200 s | +0.500 s |

The regression calls the actual engine conversion, with a 40 ms tolerance. WSJT-X's own `sync8.f90` and `ft8b.f90` establish the +0.500 s nominal start convention. FT4 retains its previous timing because it was not independently measured. Real device latency and the separate note about our exact transmit start need hardware measurement; no arbitrary TX silence or timing shift was added.

Existing virtual-clock and station baselines are re-established under new persistence keys so the old bias is not reused. The system clock is not changed by this patch.

## Validation

- Universal arm64/x86_64 build with warnings treated as errors and local signature verification.
- CW selection/audio and station suite: partial callsigns, missing macro values, actual QSO start/end, integer frequency labels, preserved WPM, pending/failed DIG preparation, decoder TX gating and existing CW safety behavior.
- FT8/FT4 suite: hash normalization, ADIF refusal and actual encoder/decoder timing fixtures, plus existing digital safety/sequence tests.
- Station suite: **203 checks**, including nonblocking queued stop, owner escalation/coalescing, disconnect uncertainty and same-port receive verification.
- Media gallery suite: **18 checks**, including slow background CAT, source-loss state propagation, real Fax progress/cancellation and preservation of the previous engine/chart.
- Logbook/cloud suite: **20 existing sections**, plus SQLite/ADIF preservation of contact times across midnight.
- Transmit-safety review suite: station, CW, voice, digital, screen capture, settings and notice UI rendering.

Validation uses synthetic audio, fake radios, isolated test stores and local fixtures. Physical RF/PTT and live cloud uploads were not exercised. Interactive inspection on the locked Mac was unavailable; the headless UI/rendering fixtures passed. A host reply or local stop cannot certify the physical radio's receive state.

## References

- [WSJT-X FT8 synchronization convention](https://github.com/WSJTX/wsjtx/blob/master/lib/ft8/sync8.f90)
- [WSJT-X FT8 start estimate](https://github.com/WSJTX/wsjtx/blob/master/lib/ft8/ft8b.f90)
- [Shared-board timing report](https://github.com/fact0real/yaam-lab599-shared-board/issues/47)

Local release: **Lab599 Utility 2.288 (294)**. The source update and locally signed installation do not publish a new updater feed or distribution release. No email reply or shared-board mutation was performed.
