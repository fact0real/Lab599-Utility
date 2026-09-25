# DX Cluster

The DX Cluster workspace connects live spots to local contact history, explicit
radio tuning and an editable QSO draft. Incoming spots never tune or transmit.

## Getting started

1. Set your callsign in **Station → Station Profiles**. The cluster uses the
   operator callsign when present, otherwise the station callsign.
2. Open **DX Cluster** from the sidebar. Enter a public callsign-login node
   hostname and port, then press **Connect**. The suggested endpoint is
   `dxcluster.f5len.org:7373`, as published on the
   [F5LEN node's information page](https://cluster.f5len.org/index.php?p=about).
   Endpoint availability is not guaranteed. Nothing connects automatically at
   application launch.
3. Filter by band or contact history. Search matches callsigns, estimated
   countries, reporters and comments. **Last 15 minutes** hides old reports.
4. Select a spot. Its comment, reporter, reported UTC time and recent contacts
   appear below the table. **Lookup** uses the existing QRZ/HamQTH service and
   configured credentials. Prefix-derived country names are estimates.
5. Choose the mode, then **Tune radio** to apply frequency/mode through Station
   control and verify readback. Radio activity must be stopped. Split, XIT,
   VOX, unsupported frequencies and unconfirmed RX block this operation.
   Digital modes select the radio's DIG mode; they do not start a decoder or TX.
6. **Prepare QSO** opens an unsaved Logbook draft. It preserves frequency down
   to the hertz, leaves reports blank and asks before replacing another draft.
   Enter the actual exchanged reports and press **Log QSO** after making the
   contact. Normal configured cloud-upload behaviour applies only after saving.

The mode hint is extracted only from explicit tokens in the report comment.
Unknown or generic SSB reports require a deliberate mode/sideband choice.
Reports describe another operator's observation, not reception at your station.

## Contact history and alerts

| Badge | Meaning |
|---|---|
| NEW | No exact callsign match in the local logbook |
| NEW BAND | Callsign worked before, but not on this band |
| WORKED | A previous contact exists on this band |
| CONFIRMED | A contact on this band is marked confirmed by LoTW, QRZ or eQSL |

History is indexed away from the UI thread. Badges update when the logbook
changes; a pending history read is shown as CHECKING, never as a new contact.
These badges are band-based, not a contest's duplicate-contact rules.

Enable **Highlight matching spots** and enter callsigns or wildcard prefixes
such as `W1AW, EP*`, and/or exact country names from the details panel. Commas
mean OR within each field; populated callsign and country fields combine with
AND. Save the rule. Matching fresh rows are orange. Optional sound and the
latest alert appear in the app; this release does not request macOS notification
permission or send push notifications.

Sounds are limited to one per 30 seconds globally and one per callsign/band
per 10 minutes. Old reports do not notify. Sound is suppressed when shared
Station control knows the radio is transmitting. Alert evaluation continues
while the cluster remains connected in the background.

## Connection and data behaviour

- Live `DX de …` records are parsed incrementally, including fragmented TCP
  input, CR/LF, basic ANSI colour sequences and Telnet negotiation.
- Input lines are bounded at 1,024 bytes. Duplicate callsign/frequency/reported
  minute entries are suppressed. Up to 1,000 session spots remain in memory;
  the oldest entries are evicted. Session spots are not saved to disk.
- UTC times are resolved across midnight. Row age comes from the reported
  time, not the time it arrived on this computer.
- TCP failures reconnect with a 2–60 second exponential backoff. Login has a
  20-second deadline; TCP keepalive detects broken connections. Disconnect
  cancels pending retries. Changing the login callsign disconnects the old
  session; reconnect explicitly with the new identity.
- This release supports unencrypted public Telnet/TCP callsign-login nodes.
  It sends only callsign login and Telnet option refusals. Password/registration
  prompts stop the session with an explanatory message. Passwords, arbitrary
  terminal commands, outbound spots and node-specific server filter commands
  are not implemented. Display filters run locally.
- Endpoint and alert preferences use the application's preferences store.
  No credentials are stored by the DX Cluster feature.

Live record and login conventions were checked against the
[DXSpider documentation](https://wiki.dxcluster.org/wiki/DXSpider_User_Manual)
and the [CW Skimmer Telnet example](https://dxatlas.com/cwskimmer/Files/CwSkimmer.pdf).
Other node formats, historical search output and password-protected nodes are
outside this release's supported protocol subset.

## Validation

- `sh tests/run-dxcluster-tests.sh`: parser, framing, frequency conversion,
  UTC rollover, malformed input, deduplication, bounded history and alert rules.
- `./build/DXClusterTests --network --render`: two-width native layout checks,
  a localhost-only server for login/reconnection/password rejection, local
  logbook badges, fake-radio tuning and draft preparation without saving.
- `./build-utility.sh --test-only`: complete application regression suite.
- `./build-utility.sh --build-only`: universal macOS app; does not replace an
  installed application. The workspace build is ad-hoc signed, not notarized.

For local UI inspection, launch with `--dx-cluster --cluster-demo`. Demo spots
are labelled and cannot tune, prepare a QSO or trigger external lookup. The
normal Connect button starts a new live session and removes the demo rows.

No public-node login, physical radio transmission or cloud upload was used
for these tests. A live-node interoperability check and hardware validation
remain necessary before treating this as field-verified operation.

## Country flags and source selection (2.195)

The spot table and selected-station details show the country/entity name and
flag from the existing local prefix database. These are estimates, not live
location verification or a complete DXCC adjudication; unresolved prefixes
show “Unknown” with a globe. Country search and alert rules continue to use the
country name. Compact windows allow horizontal scrolling to keep columns
readable, and a tooltip provides the full cell text.

Choose a **Spot source**, then press **Connect**. Selecting a source never logs
in automatically. Disconnect before changing sources. **Custom server…** keeps
manual hostname/port entry available. The endpoint is retained across launches.
**Node website** opens the selected preset's published information page.

Published endpoints checked on 2026-09-23:

| Source | Endpoint | Operator documentation |
| --- | --- | --- |
| F5LEN | `dxcluster.f5len.org:7373` | https://cluster.f5len.org/index.php?p=about |
| G1FEF / DXSpider | `dxc.hamserve.uk:7300` | https://wiki.dxcluster.org/wiki/How_to_connect |
| EA3KZ-5 | `dx.ea3kz.com:7300` | https://dx.ea3kz.com/ |

The presets use the same receive-only Telnet client. Public service uptime and
live interoperability were not tested by logging in. Only one source is active
at a time; the program does not aggregate or automatically switch servers.
