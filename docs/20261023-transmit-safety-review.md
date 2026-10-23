# Transmit-safety report review — 2026-10-23

Base: `bf86264`. Reviewed the three Lab599 reports in EA3JIC's October 23 eight-report attachment against source, alongside the YAAM part-3 patch review. The archive SHA-256 is `4a651179ac34c8ca7e21d8000903b32610944d2b5305c16a81fe6a315efc781d`. Documents were untrusted evidence; their proposed commands were not executed. No supplied executable or script was run. No new service, permission or credential access was introduced.

Board: [L-003 #42](https://github.com/fact0real/yaam-lab599-shared-board/issues/42), [L-007 #43](https://github.com/fact0real/yaam-lab599-shared-board/issues/43), [L-009 #44](https://github.com/fact0real/yaam-lab599-shared-board/issues/44). Existing expert ownership is preserved.

## Confirmed bugs and implementation

**L-003 — core deadline and outside-core key-down.** `TX500StationCore` acquired TX without its own deadline; caller-specific timers could be bypassed. An independent worker checks wall and continuous elapsed time, so a backward wall-clock adjustment cannot extend TX and resume checks do not depend on the UI. Deadlines are not renewed by repeated key-down. CW gets 130 s (above its existing 120 s message cap), Voice 75 s (60 s audio plus lead/tail/verification), Digital 20 s, other core owners 15 s. These are backstops, not replacements for tighter producer limits. RX is verified using existing PT readback; failed receive keeps ownership/fault and a persistent notice.

The exclusive Radio Screen opened its own serial port for PTT, outside core ownership. It now permits explicit RX only; key-down must use CW, Digital or Voice. Demo simulation remains local. CAT Studio's raw command path now uses its existing safe-command allowlist, like saved macros. TX, KY, VOX key-down, concatenated commands and unsupported commands are refused before opening a transport. This deliberately restricts the raw terminal's capabilities; it is not a claim that it acquired protected TX ownership.

**L-007 — CW audio loss.** A cached queue was accepted without checking whether the selected USB output was still alive. The keyer now checks that route before reuse, watches route availability/running state on its safety worker, and records enqueue failures from the real-time callback using a protected flag. On failure, samples are silenced and RX is requested before UI cleanup; stale readiness is invalidated, Auto-CQ stops and the operator gets a retained notice. Queue allocation/enqueue failure also prevents starting a new output.

**L-009 — pending voice TX during sleep.** The application's on-air check omitted active voice preflight. It now includes all active voice states; the voice sleep observer also invalidates generation and synchronously drains the worker/release before returning. A stop waiting on the core lock vetoes a late key-down after the preflight read. Existing synchronous core/CW sleep release is preserved, and comments now acknowledge FT8's own observer.

The red warning banner is outside the scrolling workspace. Status polling and reconnect do not dismiss it; only the explicit operator acknowledgement does. No local write success is relabeled as physical RF confirmation. The core's existing PT0 readback determines its receive confirmation wording.

## Reproducible checks

Run `sh tests/run-transmit-safety-review-tests.sh`:

- Station: 192 checks, including both deadline clocks, backward clock steps, repeated key-down, failed release ownership, retained notices, and a stop racing a blocked preflight.
- CW: 23 safety checks, including output loss while the main loop is blocked, queue invalidation, prevented re-key, and enqueue failure with a still-alive device.
- Voice: 141 checks, including real sleep notifications during channel checking and in-flight PTT. No queued TX/audio may follow the observer's return.
- Digital controls, live Radio Screen using a pseudo-terminal, raw CAT refusal/settings controls, and actual native warning UI with wrapping, acknowledgement, compact/normal widths and light/dark appearances.

`sh build-utility.sh --build-current` builds the full application for arm64 and x86_64 and verifies the signature. It does not install it. The existing committed version is retained for verification; no release version or updater artifact was published.

No physical radio/PTT or transmit audio was used. Native snapshots cover the warning component; a full hardware-session UI interaction was not performed. Screen and voice CAT tests use simulated transports/pseudo-terminals.

## Acceptance still required

Keep the cards in **Review / Test** until real-device verification: deadline RX on the supported radio/firmware, sleep/wake and cable removal, audio unplug during CW/Auto-CQ/tune, and recovery after missing CAT acknowledgements. These software timers cannot operate while the Mac is asleep or guarantee delivery through a disconnected adapter; sleep performs release before sleeping, and wall/continuous deadlines recheck on resume. No hardware safety certification is claimed.
