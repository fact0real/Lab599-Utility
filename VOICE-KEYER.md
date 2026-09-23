# Voice Keyer / Auto-CQ

A native macOS voice-message station for Lab599 Utility. Open **Voice Keyer** in the sidebar. The panel owns radio control while visible; entering it stops CW, FT8/FT4, telemetry and the separate audio monitor. Leaving it stops voice activity and releases its CAT connection. A failure to confirm RX keeps the panel open so PTT can be released before another radio tool takes over.

## Operating

1. Select your **microphone**, **radio output**, and a separate **headphone output**. Select **radio input** if you want received audio in the headphones. Click **Listen** to monitor; the radio's own speaker is another option.
2. **Record** a CQ or **Import** an audio file. Give it a name and choose **CQ** or **Reply**. Supported imports must be decodable by AVFoundation, mono/stereo, 8–96 kHz, and 0.25–60 seconds. Preview uses the headphone output and sends no PTT command.
3. On the radio select `AUDIO IN → ONLY LINE`, turn VOX off, use VFO A for both RX and TX, and turn Split and XIT off. Confirm the audio-route checkbox. The app does not issue an undocumented command to change the radio's input source. Use LAB599 CAT at 9600 baud.
4. Select the CAT port and **Read radio**, or enter a frequency in MHz, choose USB/LSB/AM/FM and **Apply frequency**. Apply changes are read back. Frequency and mode are not silently restored or rewritten during CQ repetition.
5. **Send once** sends the selected message once. **Start Auto-CQ** repeats a CQ message, with a receive window after confirmed RX. Reply messages cannot be repeated automatically.
6. When you hear a reply, press **Esc**, or hold **Space / Hold to talk**. The live response uses the selected **computer microphone**, through the same line input as the recording. Releasing Talk stops live audio and returns to RX. Auto-CQ remains off. To send a recorded reply, stop CQ, select that message and click Send once.

Space does not key the radio while typing in a text field, in a sheet, or in another application. Releasing the key, losing application focus during Talk, leaving the panel, and system sleep cancel a live response. Live transmission is limited to 60 seconds. An ordinary USB foot switch that generates Space key-down and key-up can use the same path; arbitrary hardware foot-switch protocols are not implemented or validated.

**ONLY LINE means the hand microphone is not the selected transmit audio source.** To return to the radio's hand microphone, stop/disconnect this panel and restore AUDIO IN locally. Start at a low audio level and check the actual transmitted signal on an independent receiver before repeated use. The software gain meter does not calibrate the radio's modulation depth or RF output.

## Timing and storage

- Defaults: 7-second receive window, no random variation, 200 ms before audio and 200 ms after playback completion, maximum 20 calls.
- Receive gap UI: 3–30 s (engine accepts 3–60 s); variation ±0–2 s, never below a 3-second gap. Timing guard range: 100–1000 ms. These are configurable engineering defaults, not measured TX-500 switching specifications.
- Repetition uses a continuous monotonic clock, not FT8 UTC slots. A timing interruption stops the session rather than catching up missed calls. Sessions have a 20-minute limit. The process prevents idle system sleep during an active sequence; deliberate sleep stops it.
- Imports become mono 16-bit PCM WAV at the source rate. Near-digital silence is trimmed with 80 ms edge padding. Normalization targets a −3 dBFS peak, with amplification capped at +6 dB. It does not run a speech codec, resynthesize the voice, or perform recognition.
- Library: `~/Library/Application Support/Lab599 Utility/Voice Keyer/`. The manifest is atomic JSON, filenames are UUIDs, and all audio stays local. Removed recordings are retained in `Removed/` and can be reimported. Interrupted imports may leave unreferenced audio; they do not expose a partial manifest.
- Device UIDs and rhythm settings are remembered; active TX, repetition, a connected radio, and the line-input confirmation are never restored automatically.

## Architecture and failure handling

`TX500VoiceKeyer` owns the sequence on the main thread and uses a private serial worker for radio operations. Every continuation carries a generation token. Stop first cancels queued continuations and stops audio, then releases only PTT owned by this session. A TX attempt acquires ownership before sending the command so a lost acknowledgement still triggers RX cleanup.

`TX500VoiceCATRadio` uses bounded framed queries, including fragmented CAT replies. It requires valid FA, MD, FR, FT, XT, VX and PT status. Only documented `TX;` / `RX;` commands key the radio; RTS/DTR are not asserted and `TX1;` is not used. There is no direct transfer of audio over CAT. Software cannot read or verify the physical audio cable or the ONLY LINE menu choice, hence the explicit operator setting.

Before each transmission, the frequency/mode, VFOs, XIT, VOX and RX state are checked. During playback, live speech and receive gaps, status is polled approximately once a second. Changes or missing replies cancel the sequence. Polling cannot make knob changes and PTT atomic; it bounds detection rather than guaranteeing instant detection. Device disappearance stops playback; there is no intentional fallback to the default audio output.

`TX500VoiceAudioIO` handles selected-device capture and live routing using bounded PCM buffers. Recording does not write files on an audio callback; completed audio is persisted separately. Live and receive routing use a bounded ring buffer with explicit failure on overflow. The player uses AVAudioPlayer completion followed by the configured tail interval; actual output-path latency still needs hardware measurement.

The app cannot guarantee de-keying after process death, loss of CAT cabling, or a failed radio. An unconfirmed RX is reported explicitly and blocks normal ownership transfer; the operator can retry Stop or release PTT locally. Any radio/interface hardware transmit timeout is independent of the app.

## Validation and limits

Run `sh tests/run-voice-keyer-tests.sh` for the simulated radio, pseudo-terminal CAT transport, WAV conversion and cancellation regression suite. `--render` also checks and renders native layouts at 940, 700 and 540 points. `--audio-smoke` checks muted playback on the built-in output, without using a microphone or radio. The normal `build-utility.sh --test` includes this suite; `--test-only` runs the suites without building/installing the application, and `--build-only` builds/signs the app without replacing the installed application.

Hardware validation is still required for the user's exact radio, firmware and audio interface: physical line-input routing in each supported mode, CAT command compatibility, TX/RX acknowledgement timing, first/last syllable preservation, live microphone latency, levels, hot unplug and handoff to the physical microphone. No RF transmission is performed by these tests.

This release implements operator-controlled replies. It does **not** identify callers, decide whether a signal is a reply, or restart CQ after a conversation. Voice activity detection and automatic responses are not implemented.
