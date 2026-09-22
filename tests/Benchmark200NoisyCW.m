#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <math.h>
#import "TX500CWAudioDecoder.h"

@interface TX500CWAudioDecoder (Private)
- (void)processRawAudioSamples:(const float *)channelData count:(int)totalFrames;
@end

// Deterministic PRNG for 100% reproducibility
static uint64_t g_rng_state = 123456789ULL;
static inline double prng_uniform(void) {
    g_rng_state ^= g_rng_state << 13;
    g_rng_state ^= g_rng_state >> 7;
    g_rng_state ^= g_rng_state << 17;
    return (double)(g_rng_state & 0xFFFFFFFF) / 4294967296.0;
}

// Box-Muller transform for standard Gaussian N(0, 1) noise
static inline double prng_gaussian(void) {
    double u1 = prng_uniform();
    if (u1 < 1e-15) u1 = 1e-15;
    double u2 = prng_uniform();
    return sqrt(-2.0 * log(u1)) * cos(2.0 * M_PI * u2);
}

typedef struct {
    char word[16];
    int length;
    double wpm;
    double pitchHz;
    double noiseSigma; // 0.010 (light), 0.020 (moderate), 0.035 (heavy)
} TestCase;

static const char *const MORSE_MAP[26] = {
    ".-",   "-...", "-.-.", "-..",  ".",    "..-.", "--.",  "....", "..",   // A-I
    ".---", "-.-",  ".-..", "--",   "-.",   "---",  ".--.", "--.-", ".-.",  // J-R
    "...",  "-",    "..-",  "...-", ".--",  "-..-", "-.--", "--.."          // S-Z
};

static void generate200TestCases(TestCase *cases) {
    g_rng_state = 987654321ULL; // Fixed seed
    int lengths[5] = {3, 4, 5, 6, 7};
    double pitches[6] = {550.0, 600.0, 650.0, 700.0, 750.0, 800.0};

    int idx = 0;
    for (int group = 0; group < 5; group++) {
        int len = lengths[group];
        for (int i = 0; i < 40; i++) {
            TestCase *tc = &cases[idx++];
            tc->length = len;
            for (int c = 0; c < len; c++) {
                tc->word[c] = 'A' + (int)(prng_uniform() * 26.0);
            }
            tc->word[len] = '\0';

            // Speeds distributed across 8 to 32 WPM
            tc->wpm = 8.0 + prng_uniform() * 24.0;
            tc->pitchHz = pitches[(int)(prng_uniform() * 6.0)];

            // Realistic noise levels: 40% light (0.012), 40% moderate (0.022), 20% heavy (0.032)
            double r = prng_uniform();
            if (r < 0.40) {
                tc->noiseSigma = 0.012; // ~23 dB SNR in Goertzel
            } else if (r < 0.80) {
                tc->noiseSigma = 0.022; // ~18 dB SNR in Goertzel
            } else {
                tc->noiseSigma = 0.032; // ~14 dB SNR in Goertzel
            }
        }
    }
}

// Synthesize floating point PCM with raised-cosine keying envelope and Gaussian noise
static float *synthesizeNoisyCW(const TestCase *tc, int sampleRate, int *outSampleCount) {
    double ditSec = 1.2 / tc->wpm;
    double dahSec = ditSec * 3.0;
    double elemSpaceSec = ditSec;
    double charSpaceSec = ditSec * 3.0;
    double leadInSec = 0.25;
    double leadOutSec = 1.0;

    // Calculate total duration
    double totalSec = leadInSec + leadOutSec;
    for (int c = 0; c < tc->length; c++) {
        char ch = tc->word[c];
        const char *code = MORSE_MAP[ch - 'A'];
        int codeLen = (int)strlen(code);
        for (int s = 0; s < codeLen; s++) {
            totalSec += (code[s] == '-') ? dahSec : ditSec;
            if (s < codeLen - 1) totalSec += elemSpaceSec;
        }
        if (c < tc->length - 1) totalSec += charSpaceSec;
    }

    int totalSamples = (int)(totalSec * sampleRate);
    totalSamples = ((totalSamples + 511) / 512) * 512; // Round to multiple of 512
    *outSampleCount = totalSamples;

    float *buf = (float *)calloc(totalSamples, sizeof(float));
    if (!buf) return NULL;

    // Generate Gaussian noise background across entire buffer
    for (int i = 0; i < totalSamples; i++) {
        buf[i] = (float)(prng_gaussian() * tc->noiseSigma);
    }

    int curSample = (int)(leadInSec * sampleRate);
    double omega = 2.0 * M_PI * tc->pitchHz / (double)sampleRate;
    int rampSamples = (int)(0.005 * sampleRate); // 5ms Hann ramp

    for (int c = 0; c < tc->length; c++) {
        char ch = tc->word[c];
        const char *code = MORSE_MAP[ch - 'A'];
        int codeLen = (int)strlen(code);

        for (int s = 0; s < codeLen; s++) {
            double dur = (code[s] == '-') ? dahSec : ditSec;
            int markSamples = (int)(dur * sampleRate);
            int rLen = (rampSamples > markSamples / 2) ? (markSamples / 2) : rampSamples;

            for (int i = 0; i < markSamples; i++) {
                int idx = curSample + i;
                if (idx >= totalSamples) break;

                float env = 1.0f;
                if (i < rLen) {
                    env = 0.5f * (1.0f - cosf((float)i / (float)rLen * (float)M_PI));
                } else if (i > markSamples - rLen) {
                    env = 0.5f * (1.0f - cosf((float)(markSamples - i) / (float)rLen * (float)M_PI));
                }
                float tone = 0.30f * env * (float)sin(omega * (double)idx);
                buf[idx] += tone;
            }

            curSample += markSamples;
            if (s < codeLen - 1) {
                curSample += (int)(elemSpaceSec * sampleRate);
            }
        }
        if (c < tc->length - 1) {
            curSample += (int)(charSpaceSec * sampleRate);
        }
    }

    return buf;
}

static void writeWavFile(const char *path, const float *samples, int sampleCount, int sampleRate) {
    FILE *f = fopen(path, "wb");
    if (!f) return;
    int numChannels = 1;
    int bitsPerSample = 16;
    int byteRate = sampleRate * numChannels * (bitsPerSample / 8);
    int blockAlign = numChannels * (bitsPerSample / 8);
    int subchunk2Size = sampleCount * numChannels * (bitsPerSample / 8);
    int chunkSize = 36 + subchunk2Size;

    // RIFF header
    fwrite("RIFF", 1, 4, f);
    fwrite(&chunkSize, 4, 1, f);
    fwrite("WAVE", 1, 4, f);
    // fmt subchunk
    fwrite("fmt ", 1, 4, f);
    int subchunk1Size = 16;
    fwrite(&subchunk1Size, 4, 1, f);
    short audioFormat = 1; // PCM
    fwrite(&audioFormat, 2, 1, f);
    fwrite(&numChannels, 2, 1, f);
    fwrite(&sampleRate, 4, 1, f);
    fwrite(&byteRate, 4, 1, f);
    fwrite(&blockAlign, 2, 1, f);
    fwrite(&bitsPerSample, 2, 1, f);
    // data subchunk
    fwrite("data", 1, 4, f);
    fwrite(&subchunk2Size, 4, 1, f);

    for (int i = 0; i < sampleCount; i++) {
        float s = fmaxf(-1.0f, fminf(1.0f, samples[i]));
        short val = (short)(s * 32767.0f);
        fwrite(&val, 2, 1, f);
    }
    fclose(f);
}

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        BOOL blind = argc > 1 && strcmp(argv[1], "--blind") == 0;
        NSLog(@"=== Running TX-500 CW Audio Decoder 200-Word Noisy Benchmark ===");

        NSString *samplesDir = @"/Users/factoreal/Downloads/TX-500/Updater/test_cw_audio/noisy_samples";
        [[NSFileManager defaultManager] createDirectoryAtPath:samplesDir withIntermediateDirectories:YES attributes:nil error:nil];

        TestCase cases[200];
        generate200TestCases(cases);

        int sampleRate = 48000;
        int exactMatches = 0;
        int totalCharsExpected = 0;
        int totalCharsCorrect = 0;

        int lightPassed = 0, lightTotal = 0;
        int modPassed = 0, modTotal = 0;
        int heavyPassed = 0, heavyTotal = 0;

        for (int i = 0; i < 200; i++) {
            TestCase *tc = &cases[i];
            int sampleCount = 0;
            float *samples = synthesizeNoisyCW(tc, sampleRate, &sampleCount);
            if (!samples) continue;

            TX500CWAudioDecoder *decoder = [[TX500CWAudioDecoder alloc] init];
            decoder.nominalPitchHz = blind ? 650.0 : tc->pitchHz;
            decoder.afcEnabled = YES;
            [decoder setNominalWPM:blind ? 20.0 : tc->wpm];

            int chunkSize = 512;
            int totalChunks = sampleCount / chunkSize;
            for (int c = 0; c < totalChunks; c++) {
                [decoder processRawAudioSamples:(samples + c * chunkSize) count:chunkSize];
            }

            NSString *expected = [NSString stringWithUTF8String:tc->word];
            NSString *decoded = [decoder.rawDecodedText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            decoded = [decoded stringByReplacingOccurrencesOfString:@" " withString:@""];

            BOOL match = [expected isEqualToString:decoded];
            if (match) exactMatches++;

            if (tc->noiseSigma < 0.015) {
                lightTotal++;
                if (match) lightPassed++;
            } else if (tc->noiseSigma < 0.025) {
                modTotal++;
                if (match) modPassed++;
            } else {
                heavyTotal++;
                if (match) heavyPassed++;
            }

            totalCharsExpected += (int)expected.length;
            // Count matching characters
            int charMatch = 0;
            for (int k = 0; k < (int)expected.length && k < (int)decoded.length; k++) {
                if ([expected characterAtIndex:k] == [decoded characterAtIndex:k]) charMatch++;
            }
            totalCharsCorrect += charMatch;

            if (i < 10) {
                NSString *wavName = [NSString stringWithFormat:@"noisy_sample_%02d_%dchars_%s_%dwpm_%dhz_sigma%03d.wav",
                                     i + 1, tc->length, tc->word, (int)tc->wpm, (int)tc->pitchHz, (int)(tc->noiseSigma * 1000)];
                NSString *wavPath = [samplesDir stringByAppendingPathComponent:wavName];
                writeWavFile([wavPath UTF8String], samples, sampleCount, sampleRate);
            }

            if (i < 15 || !match) {
                printf("[%03d/200] %s | Exp: %-7s | Dec: %-7s | WPM: %4.1f | Pitch: %5.0f | Noise: %.3f\n",
                       i + 1, match ? "PASS" : "FAIL", tc->word, [decoded UTF8String], tc->wpm, tc->pitchHz, tc->noiseSigma);
            }

            free(samples);
        }

        printf("\n=======================================================\n");
        printf("%s BENCHMARK RESULTS (200 NOISY WORDS):\n", blind ? "BLIND" : "CALIBRATED");
        printf("Exact Word Accuracy:   %d / 200 (%.1f%%)\n", exactMatches, (double)exactMatches / 2.0);
        printf("Character Accuracy:   %d / %d (%.1f%%)\n", totalCharsCorrect, totalCharsExpected, (double)totalCharsCorrect / (double)totalCharsExpected * 100.0);
        printf("  - Light Noise   (sigma=0.012): %d / %d (%.1f%%)\n", lightPassed, lightTotal, (double)lightPassed / (double)lightTotal * 100.0);
        printf("  - Moderate Noise(sigma=0.022): %d / %d (%.1f%%)\n", modPassed, modTotal, (double)modPassed / (double)modTotal * 100.0);
        printf("  - Heavy Noise   (sigma=0.032): %d / %d (%.1f%%)\n", heavyPassed, heavyTotal, (double)heavyPassed / (double)heavyTotal * 100.0);
        printf("=======================================================\n");
        return exactMatches == 200 ? 0 : 1;
    }
}
