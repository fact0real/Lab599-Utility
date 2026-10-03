# Protocol scope and validation limits

Lab599 Utility is an independent community application. The published
[Lab599 CAT Protocol Commands rev. 3](https://downloads.lab599.com/DOCS/Lab599-CAT-protocol-r3.pdf)
is the reference for its documented commands. Some features use
commands, file layouts or loader behavior that are **not specified there**.
Their presence in the app does not mean Lab599 has approved or verified them.

| Feature | What this project uses | Current evidence and limit |
| --- | --- | --- |
| Normal CAT identity | `ID;`, with documented `ID500;` (TX-500 family) and `ID505;` (TX-500MP) | A valid reply verifies the responding radio family before an update. It does not distinguish Discovery, PRO and ALTAI, or prove that the same radio remains connected after a power cycle. |
| Additional identity replies | `ID501;` and `ID502;` | Accepted as numeric replies without assigning a model name. Their model meanings are not established by the published CAT revision. |
| Additional mode codes | `MD8;` and `MD9;` replies; Station can also send `MD9;` when the operator selects that preset mode | Shown by their numeric codes with an “undocumented” label. The app does not infer DIG-L, DIG-R or FSK from them. The meaning and safety of sending `MD9;` on every radio model are unverified. Digital transmit is armed only after the expected `MD6;` read-back. |
| Settings block | `XL` reads and `XS` writes of 1,024 addressed bytes; `.set` backups | The app validates size and compares all bytes after a write. The provenance of the named field offsets in the Settings editor is unknown, and this project has no documented manufacturer validation for them. Retain an unedited raw backup before changing settings. Read-back checks bytes, not field meaning. JSON describes the named fields and is not a complete replacement for `.set`. |
| Memory bank | 100 channels in a 600-byte `.mem` file; CAT memory transfer with DTR/RTS control | Local format tests and simulated serial tests exist. Modem-control behavior and compatibility across radio models and firmware revisions require physical hardware checks. Writing replaces the whole bank. |
| Firmware loader | `BL20` header, file target ID, acknowledgement sequence and paced payload transfer | Only reviewed full-file firmware hashes are accepted. One TX-500 Discovery was updated from 1.26.10 to 1.30.00. The bootloader's response to a cross-model image remains unverified; the pre-loader CAT check and operator confirmation are necessary but cannot guarantee compatibility. |
| Other CAT commands | `FW`, `KY`, `RC` and similar TS-2000-style extensions | Implemented uses can be found in the source, but support and exact semantics for every TX-500 model are not established by the published CAT revision. |
| Radio Screen V/M button | Formerly sent `VR0;` | The TX-500 meaning of this command has not been verified. The on-screen button now reports that it is unavailable and sends no command. Use the radio's physical V/M key. |

This table describes implementation and test evidence, not a claim of official
protocol support. Please report the exact radio model, firmware and observed CAT
reply when a behavior differs. We welcome Lab599's corrections or authoritative
documentation, especially for settings-field offsets, model-specific IDs,
additional mode codes and loader safeguards.

The automated suites use fixtures and pseudo-terminals. They do not substitute
for controlled validation on each physical radio model. The source tree does
not include manufacturer executables or firmware. Older release-tag archives
still contain historical review documents; see the README's historical-source
notice.
