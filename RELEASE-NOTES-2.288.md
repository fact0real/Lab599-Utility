# Lab599 Utility 2.288 (294)

- Keep Stop/Esc responsive while CAT release and receive verification run in the background; preserve uncertainty across force disconnect.
- Prepare CW DIG mode asynchronously and enable sending only after readback confirmation.
- Preserve complete callsigns, operator WPM, actual CW contact start/end and midnight dates; omit unknown reports and unresolved macro values.
- Correct CW frequency labels and prevent System Audio from decoding local keyer sidetone.
- Make SSTV CAT sampling nonblocking, stop on input-device loss, and add background Fax decoding with progress and Cancel.
- Correct independently measured FT8 DT bias and rebuild old timing baselines. FT4 and physical-device latency need separate measurements.

See `validation/EA3JIC-EMAIL-BATCH-20261024.md` for the report matrix and validation details.
