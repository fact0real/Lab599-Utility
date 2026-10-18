# Privacy and network connections

Reviewed against source on October 18, 2026 following EA3JIC's review of 2.285. This describes what the application requests, not external providers' retention policies. Every remote peer sees the public/proxy IP address, connection timing and normal transport metadata. DNS lookups disclose hostnames to the resolver even if the connection later fails. This document works offline.

## Startup and public services

Constructing the Documentation controller does not make a request. Its bundled catalog and local copies are available offline. Opening Documentation or pressing Refresh requests `https://lab599.com/downloads` and `https://lab599.ru/downloads` with the Lab599 Utility User-Agent and public paths, without a station profile or logbook. Downloading a document contacts its selected URL. Firmware discovery/downloads use their separate operator actions.

Internet time is **off by default**, controlled by **Cloud Settings → Privacy → Allow internet time synchronization (NTP)**. Merely opening the application or enabling the option does not start it. Opening Time Sync or starting FT8 monitoring while enabled starts the sampler, immediately and every 15 minutes thereafter. Disable the option to stop automatic sampling and prevent subsequent queries. An already issued packet or DNS lookup cannot be recalled. NTP in progress may finish, but disabled results are not adopted. Time synchronization affects the application's UTC clock, not the macOS system clock.

The sampler contacts `time.cloudflare.com`, `time.apple.com` and `time.nist.gov` over UDP port 123. Each 48-byte request includes a local clock timestamp. At least two agreeing sources are required. No HTTPS clock fallback contacts Google, Microsoft, or Cloudflare's captive-portal endpoint. When NTP is unavailable or disabled, the existing holdover/radio-consensus model and FT8 transmit timing gates remain in effect; disabling NTP does not force a timing-safe state.

CW sidetone audio is initialized when a sidetone is first played, rather than during CW controller construction. Audio capture starts through its own listening/monitoring actions; macOS controls device permissions. Deferring construction alone is not a claim that every OS audio-permission prompt has been eliminated.

## Logbook uploads

**Cloud Settings → Privacy** contains the automatic new-QSO upload switch, QRZ/Club Log/eQSL/LoTW switches, and three optional data-sharing switches. All default to off when no preference is stored; explicit existing preferences are preserved. Credentials alone do not enable an upload. The automatic switch controls uploads after QSO saves; manual synchronization still requires each destination to be enabled and configured. Disabling affects later dispatches and cannot recall a dispatched upload.

All provider upload routes, including single, full-logbook and selected/pending LoTW files, pass through an upload-only allowlist. Local SQLite records, ADIF imports and manual file exports retain their data, including contact email, notes and precise locators. A locally saved lookup email is not permission to upload it.

| Destination | Default upload fields | Optional data |
| --- | --- | --- |
| QRZ (`logbook.qrz.com/api`), Club Log (`clublog.org/realtime.php`), eQSL (`www.eqsl.cc/qslcard/ImportADIF.txt`) | Callsign, dates/times, band/frequency/mode/submode, reports, power, country/state/DXCC/zones, IOTA/SOTA/SIG awards, station/operator callsigns, station award/location fields and valid grids capped at six characters. | Names/QTH and profile descriptions (`NAME`, `QTH`, `MY_NAME`, `MY_CITY`, `MY_RIG`, `MY_ANTENNA`); contact email and grids over six characters; operator comments. Each group has an independent opt-in. |
| LoTW via TrustedQSL | `CALL`, `QSO_DATE`, `TIME_ON`, `BAND`, `MODE`, `SUBMODE`, `FREQ`, `STATION_CALLSIGN`, `OPERATOR`, `MY_GRIDSQUARE` (six characters maximum), `MY_STATE`, `MY_CNTY`, `MY_CQ_ZONE`, `MY_ITU_ZONE`, `MY_IOTA`. | None of the optional groups apply. TQSL also supplies its configured station location, so filtering does not hide the operator's location from LoTW. |

Unknown fields, `APP_*`, `*_INTL`, `MY_CALL`, and cross-service upload/confirmation statuses are excluded. Invalid locators are omitted. Unknown destinations receive no QSO fields. Upload credentials are still sent as required by the chosen destination; QRZ/Club Log/eQSL uploads refuse redirects. Only TQSL exit code 0 counts as success; partial/rejected runs do not mark the whole batch uploaded.

## Other operator-enabled connections

- QRZ (`xmldata.qrz.com`) and HamQTH (`www.hamqth.com`) receive requested callsigns and account/session credentials on lookup/enrichment. Local saving can retain returned contact details. HamQTH's current login URL carries its username/password in query parameters; avoid recording or sharing request URLs. No new claim about provider POST support is made here.
- LoTW confirmation downloads (`lotw.arrl.org`) use the configured account and date filters. The published download URL includes credentials; URLs must not be copied into shared diagnostics.
- PSK Reporter is opt-in and can receive station identity, locator and reception reports. DX cluster connects after the operator's Connect action, sends the login callsign and commands/spots, and may use unencrypted TCP.
- Web authentication and Help/reference pages can load browser cookies, scripts, images and third-party subresources. Opening an external link uses the selected browser's network behavior.
- Radio control and local services use the configured ports/endpoints. Selecting a remote host does not make that connection local. Firmware transfers and radio transmission have their own actions and safety interlocks.

Credentials use the existing macOS Keychain store. This change adds no telemetry. Verification uses offline stand-ins and invented records; authenticated provider behavior, packet-level startup traffic, physical radio/audio operation, and provider retention have not been certified by these tests.
