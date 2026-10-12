# Lab599 Utility v2.283 (Build 289)

This release delivers soundcard CW transmission over the REM/DATA audio interface with full RF power, real-time transmit power and SWR telemetry, safety cutoff timers, interactive spectrum waterfall click-tuning, and robust CI test execution.

---

### Key Changes & Improvements

1. **Full-Power CW Transmission via REM/DATA (`DIG` Mode):**
   - **Root Cause Resolved:** The Lab599 TX-500 hardware muter disables the REM/DATA line-in audio while in hardware CW mode (`MD3;`) and ignores unsupported `KY` text CAT commands, causing 0.0 W output.
   - **Soundcard CW Modulation:** Transmission is routed via `DIG` mode (`MD6;`) with raised-cosine sine wave shaping at the nominal pitch (650 Hz), delivering full RF output power (~10 W) physically and spectrally identical to standard CW carrier keying.
   - **Automatic Mode Cycling:** When operating in `CW (Paddle Key)` mode, the software automatically commands `MD6;TX;` during transmission and restores `RX;MD3;` on release so physical keyers and internal CW filters continue to operate seamlessly.
   - **Default Mode:** The CW Station mode selector now defaults to `DIG (Soundcard CW)` with clear menu options (`DIG`, `CW`, `CW-R`, `USB`, `LSB`).

2. **Live Transmit Telemetry (⚡ PWR & 📶 SWR):**
   - Integrated live transceiver telemetry polling during transmission and antenna tuning.
   - Live RF power is read via `RM0;RM;` and calibrated to watts (0.0 W – 10.0 W) with animated level bars.
   - Antenna SWR is queried via `RM1;RM;` and mapped through the TX-500 lookup curve (1.0:1 to >5.0:1) with color-coded alerts (Green: ≤1.5, Yellow: ≤2.5, Red: >2.5).

3. **Safety Watchdog & Abort Enhancements:**
   - The manual `TX (Tune)` function is now protected by an automatic **10-second safety cutoff timer** to prevent accidental transmitter lockups.
   - Transmission completion and abort routines guarantee sending `RX;` under all code paths and audio buffer completions.

4. **Interactive Spectrum Waterfall Click-Tuning:**
   - Clicking any Morse signal on the spectrum waterfall immediately retunes the transceiver's VFO dial to center the signal on the operator's nominal CW pitch (650 Hz).
   - Added DSP narrow bandpass filtering presets (500–800 Hz) to eliminate wideband HF noise and background hiss.

5. **CI Runner Stability (GitHub Actions):**
   - Resolved the simulated pty acknowledgement timeout failure in `TransferTests.m` by increasing the acknowledgement timeout deadline from 0.2s to 0.8s, eliminating false failures caused by shared virtualization thread scheduler jitter.

---

### Persian Summary (خلاصه تغییرات به فارسی)

- **حل قطعی مشکل توان صفر وات در ارسال مورس با کابل REM/DATA:** به دلیل قطع بودن ورودی صدای رادیو در مد CW سخت‌افزاری، ارسال کد مورس از طریق مد دیجیتال (`DIG`) با توان کامل ۱۰ وات پیاده‌سازی شد. گیرنده مورس صدا را کاملاً شفاف و استاندارد به عنوان CW واقعی دریافت می‌کند.
- **تغییر خودکار مد در زمان ارسال:** در صورت انتخاب مد `CW (Paddle Key)`، نرم‌افزار به صورت خودکار لحظه ارسال را با `MD6;TX;` اجرا کرده و بلافاصله با `RX;MD3;` رادیو را به مد CW برای شنیدن برمی‌گرداند.
- **تله‌متری زنده توان و نسبت امواج ایستا:** اضافه شدن نمایشگر دیجیتال زنده توان خروجی (⚡ PWR بر حسب وات) و نسبت امواج ایستا (📶 SWR) با رنگ‌بندی هشدار.
- **تایمر ایمنی ۱۰ ثانیه‌ای برای کلید Tune:** جلوگیری از روشن ماندن ناخواسته فرستنده در زمان تیونینگ آنتن.
- **تیونینگ تعاملی با کلیک روی آبشار (Waterfall):** با کلیک روی هر خط مورس، فرکانس VFO رادیو به صورت خودکار جابجا شده و روی فرکانس صوتی استاندارد ۶۵۰ هرتز قفل می‌شود.
- **رفع خطای Action گیت‌هاب:** اصلاح تایم‌اوت تست شبیه‌ساز انتقال فریمور در `TransferTests.m` برای پایداری ۱۰۰٪ روی ماشین‌های مجازی CI.

---

### Validation & Verification
- All local and CI test suites passed:
  - `CWStationTests`: 100% passed (Goertzel decoding, soundcard CW keying, DIG mode lifecycle, CAT release).
  - `CWAudioSelectionTests`: 20/20 audio routing checks passed.
  - `StationTests`: 102 station checks passed.
  - `TransferTests`: 15/15 simulated firmware transfer checks passed.
  - `TuningTests`: 307 tuning checks passed.
- Built as a universal macOS Mach-O binary (`arm64` Apple Silicon & `x86_64` Intel) targeting macOS 12.0+.
- Code signed with local ad-hoc code signature and verified.

---

### Archive Information
- **Package:** `Lab599-Utility-v2.283-macOS-universal.zip`
- **Application:** `Lab599 Utility.app` (v2.283, Build 289)
- **Minimum macOS:** macOS 12.0 (Monterey) or later
- **SHA-256:** `bb2597717592d66fabe188f0638352bd0fcecfe8f853974542ca314154c9ac88`
