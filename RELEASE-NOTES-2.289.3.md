# Lab599 Utility 2.289.3 (298)

Maintenance release from committed 2.289, excluding unrelated uncommitted telemetry/power-calibration changes in the owner's checkout.

- Sanitize activity and diagnostic-session messages before storage/display, including credential-shaped fields, sensitive URL components, authentication/cookie headers and control characters.
- Remove partial QRZ XML/HamQTH session identifiers from credential-check success messages.
- Withhold raw cloud-server rejection and TQSL failure output; report network error codes and recovery steps.
- Document the existing local process-list exposure of TQSL certificate passwords.

Validation: diagnostic-privacy regression, existing logbook/cloud regression suite and complete universal build/signature verification. No real upload or radio transmission was performed. B-018's full service-health/status architecture and remaining silent-failure migrations are still open.
