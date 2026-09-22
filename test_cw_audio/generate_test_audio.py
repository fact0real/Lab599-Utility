#!/usr/bin/env python3
import os
import math
import struct
import wave
import random

SAMPLE_RATE = 48000
OUTPUT_DIR = "/Users/factoreal/Downloads/TX-500/Updater/test_cw_audio"
os.makedirs(OUTPUT_DIR, exist_ok=True)

MORSE_CODE = {
    'A': '.-', 'B': '-...', 'C': '-.-.', 'D': '-..', 'E': '.',
    'F': '..-.', 'G': '--.', 'H': '....', 'I': '..', 'J': '.---',
    'K': '-.-', 'L': '.-..', 'M': '--', 'N': '-.', 'O': '---',
    'P': '.--.', 'Q': '--.-', 'R': '.-.', 'S': '...', 'T': '-',
    'U': '..-', 'V': '...-', 'W': '.--', 'X': '-..-', 'Y': '-.--',
    'Z': '--..',
    '0': '-----', '1': '.----', '2': '..---', '3': '...--', '4': '....-',
    '5': '.....', '6': '-....', '7': '--...', '8': '---..', '9': '----.'
}

# 20 test cases with random letters (lengths 3 to 7) and speeds from 5 to 36 WPM
TEST_CASES = [
    # (id, length, word, wpm, pitch_hz)
    (1,  3, "XJW",     5.0,  650.0),
    (2,  3, "QBZ",     6.0,  700.0),
    (3,  3, "KVH",     8.0,  600.0),
    (4,  4, "PLFD",   10.0,  750.0),
    (5,  4, "MYRX",   12.0,  800.0),
    (6,  4, "TWCG",   13.0, 1225.0),  # User's exact pitch
    (7,  4, "SBJN",   14.0,  650.0),
    (8,  5, "HZKVT",  15.0,  700.0),
    (9,  5, "RDXMB",  16.0,  600.0),
    (10, 5, "WQLPJ",  18.0,  850.0),
    (11, 5, "GMCFY",  20.0,  650.0),
    (12, 6, "KTRWQX", 22.0,  700.0),
    (13, 6, "VBZPDL", 24.0,  650.0),
    (14, 6, "NJMFGH", 25.0,  800.0),
    (15, 6, "CXLYSW", 26.0,  600.0),
    (16, 7, "PBKVWZT", 28.0, 700.0),
    (17, 7, "MRXDFLQ", 30.0, 650.0),
    (18, 7, "TGNSHYC", 32.0, 750.0),
    (19, 7, "WJPMKBX", 34.0, 600.0),
    (20, 7, "FLVQZND", 36.0, 650.0),
]

def synthesize_morse_audio(word, wpm, pitch_hz):
    dit_sec = 1.2 / wpm
    dah_sec = dit_sec * 3.0
    elem_space_sec = dit_sec
    char_space_sec = dit_sec * 3.0
    lead_in_sec = 0.3
    lead_out_sec = 1.2

    samples = []

    def append_silence(duration_sec):
        count = int(duration_sec * SAMPLE_RATE)
        samples.extend([0.0] * count)

    def append_tone(duration_sec):
        count = int(duration_sec * SAMPLE_RATE)
        ramp_samples = int(0.005 * SAMPLE_RATE)  # 5ms Hann ramp
        if ramp_samples > count // 2:
            ramp_samples = count // 2
        omega = 2.0 * math.pi * pitch_hz / SAMPLE_RATE

        for i in range(count):
            if i < ramp_samples:
                envelope = 0.5 * (1.0 - math.cos(math.pi * i / ramp_samples))
            elif i > count - ramp_samples:
                envelope = 0.5 * (1.0 - math.cos(math.pi * (count - i) / ramp_samples))
            else:
                envelope = 1.0
            val = 0.35 * envelope * math.sin(omega * i)
            samples.append(val)

    append_silence(lead_in_sec)

    for c_idx, ch in enumerate(word):
        code = MORSE_CODE[ch]
        for s_idx, sym in enumerate(code):
            dur = dah_sec if sym == '-' else dit_sec
            append_tone(dur)
            if s_idx < len(code) - 1:
                append_silence(elem_space_sec)
        if c_idx < len(word) - 1:
            append_silence(char_space_sec)

    append_silence(lead_out_sec)
    return samples

print(f"Generating 20 Morse test audio files in {OUTPUT_DIR}...")
metadata = []
for case_id, length, word, wpm, pitch in TEST_CASES:
    morse_pattern = " ".join(MORSE_CODE[c] for c in word)
    samples = synthesize_morse_audio(word, wpm, pitch)
    
    filename = f"cw_test_{case_id:02d}_{length}chars_{word}_{int(wpm)}wpm_{int(pitch)}hz.wav"
    filepath = os.path.join(OUTPUT_DIR, filename)

    with wave.open(filepath, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(SAMPLE_RATE)
        # Convert float (-1.0 .. 1.0) to int16
        int_data = bytearray()
        for s in samples:
            val = int(max(-32767, min(32767, s * 32767.0)))
            int_data += struct.pack("<h", val)
        wf.writeframes(int_data)

    duration_sec = len(samples) / SAMPLE_RATE
    metadata.append((case_id, length, word, morse_pattern, wpm, pitch, duration_sec, filepath))
    print(f"[{case_id:02d}/20] {word} ({length} letters) | Morse: {morse_pattern:24s} | {wpm:4.1f} WPM | {pitch:6.1f} Hz | {duration_sec:4.1f}s -> {filename}")

print("\nAll 20 Morse audio files successfully generated!")
