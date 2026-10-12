# Lab599 Utility v2.284 (Build 290)

This release delivers the definitive resolution for transmitter audio drive and 0W RF power in DIG mode by migrating CW modulation to low-level CoreAudio `AudioQueue`, providing full ~10 Watt RF output, automatic input/output audio pairing, and bulletproof device selection persistence.

---

### Key Changes & Improvements

1. **Native CoreAudio AudioQueue Engine for CW Modulation:**
   - **Root Cause Resolved:** The high-level `AVAudioEngine` previously used in `TX500CWKeyer` tied its internal render graph to the macOS default output format (typically 44.1 kHz built-in speakers). Dynamic redirection via `AudioUnitSetProperty` failed to route audio buffers to external 48 kHz USB audio codecs (such as the GX-12 REM/DATA interface), resulting in silence at the DAC and 0 Watts of RF power.
   - **AudioQueue Migration:** Fully migrated radio modulation to low-level CoreAudio `AudioQueue` streaming natively at 48000 Hz, Float32, 2-channel stereo. Audio is streamed directly to the hardware endpoint without graph reconfiguration issues.
   - **Full RF Power Drive:** Morse tones and continuous tuning carriers are now streamed interleaved across both Left and Right channels with calibrated ~0.85 amplitude (-1.4 dBFS) and 4ms raised-cosine envelopes, producing full ~10 Watts RF output on the physical transmitter (`RM00009;`).

2. **Continuous Tuning Carrier Generator:**
   - Rewrote the `TX (Tune)` carrier generator to stream pure sine waves directly in the real-time audio render callback, eliminating buffer looping hitches and guaranteeing steady carrier power.

3. **Automatic Audio Endpoint Pairing in CW Station:**
   - When an audio input interface is selected or refreshed in CW Station, the controller automatically pairs and binds the matching USB audio output endpoint UID (`updateKeyerRadioOutputDevice`) so the operator never has to manually configure output endpoints.

4. **Strict Device Selection Preservation:**
   - Corrected the audio device enumeration logic in `TX500FT8AudioEngine` so that `preserveDeviceSelection` strictly prevents missing audio routes from being silently overridden by newly connected interfaces.

---

### Persian Summary (خلاصه تغییرات به فارسی)

- **حل قطعی مشکل توان صفر وات (0W) در مد DIG با بازنویسی موتور صوتی با AudioQueue:**
  علت صفر بودن توان خروجی، تلاش فریم‌ورک سطح‌بالای `AVAudioEngine` برای اتصال به اسپیکر داخلی مک (۴۴۱۰۰ هرتز) و ناتوانی آن در هدایت بافرها به کارت صدای اکسترنال (۴۸۰۰۰ هرتز) بود. با بازنویسی کامل موتور مدولاسیون رادیو با **Apple AudioQueue**، صدا مستقیماً با کیفیت ۴۸ کیلوهرتز استریو به پین دیتای کابل REM/DATA تزریق شده و توان کامل **۱۰ وات RF** (تأییدشده با پاسخ زنده رادیو `RM00009;`) حاصل شد.
- **تولید هم‌زمان صدا روی کانال‌های چپ و راست:**
  برای اطمینان از سازگاری با تمامی کابل‌ها و رابط‌های صوتی GX-12، سیگنال صوتی مورس به هر دو کانال چپ و راست تزریق می‌شود تا مستقل از سیم‌بندی داخلی کابل، ورودی رادیو با دامنه کامل درایو شود.
- **تطبیق خودکار پورت‌های ورودی و خروجی USB در CW Station:**
  به محض انتخاب کارت صدای ورودی رادیو، پورت خروجی متناظر آن نیز به صورت خودکار شناسایی و به Keyer متصل می‌گردد.
- **حفظ دقیق تنظیمات کارت صدای انتخابی:**
  اصلاح شرط `preserveDeviceSelection` تا اتصالات صوتی کاربر به صورت ناخواسته در زمان اسکن مجدد تغییر نکند.

---

### Validation & Verification
- **Physical Hardware Test:** Verified live on connected Lab599 TX-500 transceiver via `/dev/cu.usbserial-110` and `TTGK Technology USB Audio` card:
  - Mode: `MD6;` (DIG)
  - CAT Power target: `PC100;` (10.0 W)
  - Keyed with `TX;`, AudioQueue played 700 Hz tone.
  - Live RF power meter polling `RM0;RM;` returned **`RM00009;`** (~9–10 W full RF power).
- **All Automated Test Suites Passed (100% PASS):**
  - `CWStationTests`: Goertzel DSP, soundcard CW keying, DIG mode switching, CAT unkeying.
  - `CWAudioSelectionTests`: 20/20 checks passed.
  - `FT8StationTests`: 100% passed (encode/decode, audio engine, state machine, logging).
  - `TransferTests`: 15/15 checks passed.
  - `AudioMonitorTests`: 15/15 checks passed.
- Built as a universal macOS Mach-O binary (`arm64` Apple Silicon & `x86_64` Intel) for macOS 12.0+.
