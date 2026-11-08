# Radio Utility Family storage contract — schema 1

The four products keep their original identities and radio capabilities. New diagnostics share one location on the current Mac:

`~/Library/Application Support/Radio-Utility-Family/Logs/<app-id>/<UTC-date>/<run-id>-<channel>-<segment>.jsonl`

Each JSON record has `schemaVersion`, `appID`, `appName`, `bundleID`, `appVersion`, `appBuild`, `runID`, `eventID`, `processID`, `channel`, `timestampUTC`, `writtenAtUTC` and `monotonicUptimeSeconds`. Channel-specific fields retain their original meaning. In particular, signal time, decode delivery, reserved slot and write time must not be conflated. The monotonic timestamp supports ordering when UTC changes; run and event IDs preserve provenance.

- Product IDs are `fx-radio-utility`, `icom-radio-utility`, `lab599-utility` and `xiegu-utility`.
- Every process writes only its own run files. Appends happen off the UI/audio/radio-control path. New segments start near 8 MiB; earlier segments are preserved. No automatic retention deletion is enabled.
- Directories are created with mode 0700 and files with mode 0600. Diagnostic failure cannot hold PTT. Test/development executables do not write operator diagnostics; tests explicitly use disposable roots.
- Existing logs, contact archives, ADIF exports and legacy shared archives are not moved, merged, corrected or rewritten by the new logger. Existing files stay available to their original app readers. Family log export contains the new family `Logs` directory only, excluding settings and credentials.
- `timestampUTC` can represent event/signal time. `writtenAtUTC` is when the diagnostic writer processes the record. `runID` is an application launch; a separate operational `sessionID`, when present, retains its existing automation-session meaning.

## Optional station settings

Station sharing and import are off by default in each app. In Radio Family settings, enable sharing, publish this app's identity, select another app and review its name, version, build, timestamp and values before explicitly importing. Publishing uses one atomic file per product under `Radio-Utility-Family/Settings/<app-id>.json`; apps never perform a competing read/modify/write of one combined station archive.

The common envelope is `{ "schemaVersion": 1, "source": { "appID", "appName", "bundleID", "appVersion", "appBuild" }, "updatedAtUTC": "ISO-8601", "values": { ... } }` (the object-key illustration is descriptive, not a literal JSON fixture).

Only `station.callsign`, `station.grid`, `station.operatorName`, `station.qthCity`, `station.cqZone`, `station.ituZone` and `station.iota` are portable. Unsupported schema versions, malformed values and oversized files are rejected. FX and ICOM support the full station-identity set. Lab599 maps supported values to its local station preferences. Xiegu currently uses callsign and locator; it has no compatible QSL upload account workflow.

Connection ports, model/CI-V addresses, audio routing, power, firmware state, transmission consent and operating interlocks remain local. Importing identity never authorizes transmitting, enabling cloud uploads or changing radio settings. Contact history is not part of station-settings sharing. Disabling sharing removes this app's published settings; already imported local settings are retained.

## Explicit credential transfer

FX, ICOM and Lab599 provide a separate, default-off control and explicit publish/import buttons for compatible log-service accounts. Credentials are stored only in macOS Keychain under service `com.factoreal.radiofamily.log-services`, with one `<app-id>.credentials.v1` item per publisher. The encrypted item contains the schema/source envelope and an allowlisted value dictionary. macOS may ask the user to authorize another signed app.

No credential values are included in the common settings JSON, log folder or support export. Disabling credential sharing removes this app's published Keychain item; already imported app-local accounts remain available. It does not delete another app's credentials. LoTW certificate passwords use `lotw.certificatePassword`, separately from Lab599's LoTW account password. Import never turns cloud uploads on.

## Advisory multi-radio timing

FX and ICOM can explicitly opt into advisory coordination. Per-run coordination snapshots live under `Coordination`, separately from logs/settings. Only recent, active states qualify; idle app launches do not announce an armed transmitter. Filesystem polling and publication run off the timing-critical actor. Coordination may defer a fresh CQ; it does not change a locked exchange's parity or grant permission to key a radio. This is not an RF isolation or inter-radio safety guarantee.

## Validation boundaries

Storage/concurrency and protocol behavior are tested with disposable directories, synthetic PCM and loopback radios. No physical PTT, RF, firmware programming, operator credential retrieval or real cloud upload is part of these checks. Clock precision still depends on independently qualified network evidence. Apple Development or ad-hoc signatures must not be described as Developer ID notarization.
