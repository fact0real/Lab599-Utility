# Lab599 Utility 2.290 (Build 296) — local review build

Telemetry now opens **Power Calibration…**, an offline workbench comparing TX
meter dots with external wattmeter readings. Enter observations or import
EA3JIC's v0.7 sweep CSV; export measurements or the selected group's analysis.
This workbench never opens a radio port or sends CAT commands.

Conditions remain separate: model, firmware, exact frequency, measured supply
voltage, carrier method, operator, instrument and individual radio label.
Simulated/empty-watt rows are excluded. Invalid real rows reject the import.
Fractional dots are preserved; repeated dots are averaged. Analysis includes
PC/watts comparison, fit/error and measured-range interpolation. Descending
scales block conversion. Tables are estimates and are never enabled live.

Live Telemetry now displays PC as its documented raw 10–100 setting, rather
than assuming PC050 means 5 W. DC current and PA temperature derived from that
assumption are unavailable in live CAT; Demo retains its synthetic readings.
Other existing power controls outside Telemetry retain their previous behavior.

The original automatic-transmit sweep was rejected for integration after safety
issues were found, despite no observed spyware in the reviewed files.
See [review and validation](docs/POWER-CALIBRATION-REVIEW-20261025.md).
No automatic sweep or hardware-validated watts calibration is included.

This build is local; it has not been published or installed over the user's app.
