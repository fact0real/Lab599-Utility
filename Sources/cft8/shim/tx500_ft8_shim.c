// ft8808_shim.c — implementation of the FT8-808 C entry point.
//
// Wraps kgoba/ft8_lib (MIT). The decode pipeline and the callsign hashtable
// below are adapted from ft8_lib's demo/decode_ft8.c (MIT, (c) Kārlis Goba),
// reduced to a reentrant, device-free form suitable for offline sample blocks.

#include "tx500_ft8_shim.h"

#include <ft8/decode.h>
#include <ft8/message.h>
#include <ft8/encode.h>
#include <ft8/constants.h>
#include <common/monitor.h>
#include <common/wave.h>

#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <stdlib.h>
#include <math.h>

// ---- Decode tuning (Optimized for Deep FT8 Decoding) ------------------------
#define FT8808_MIN_SCORE      7    // Lowered threshold to extract faint signals (-24 to -26 dB)
#define FT8808_MAX_CANDIDATES 220  // Expanded candidate pool for dense band conditions
#define FT8808_LDPC_ITERS     40   // Increased LDPC belief propagation iterations for maximum convergence
#define FT8808_MAX_DECODED    100  // Allow up to 100 decodes per 15s window
#define FT8808_FREQ_OSR       2
#define FT8808_TIME_OSR       2

// ---- Callsign hashtable (adapted from ft8_lib demo) -----------------------
// FT8 can transmit hashed (non-standard) callsigns; decoding those requires a
// table of previously-seen calls. For a single offline slot this is mostly a
// no-op, but we keep it so hashed-callsign messages render correctly once we
// feed it a live stream of slots.
#define CALLSIGN_HASHTABLE_SIZE 256

static struct {
    char     callsign[12];
    uint32_t hash; // 8 MSB = age, 22 LSB = hash
} g_callsign_hashtable[CALLSIGN_HASHTABLE_SIZE];

static int g_callsign_hashtable_size;

static void hashtable_init(void) {
    g_callsign_hashtable_size = 0;
    memset(g_callsign_hashtable, 0, sizeof(g_callsign_hashtable));
}

static void hashtable_add(const char* callsign, uint32_t hash) {
    uint16_t hash10 = (hash >> 12) & 0x3FFu;
    int idx = (hash10 * 23) % CALLSIGN_HASHTABLE_SIZE;
    while (g_callsign_hashtable[idx].callsign[0] != '\0') {
        if (((g_callsign_hashtable[idx].hash & 0x3FFFFFu) == hash) &&
            (0 == strcmp(g_callsign_hashtable[idx].callsign, callsign))) {
            g_callsign_hashtable[idx].hash &= 0x3FFFFFu; // reset age
            return;
        }
        idx = (idx + 1) % CALLSIGN_HASHTABLE_SIZE;
    }
    g_callsign_hashtable_size++;
    strncpy(g_callsign_hashtable[idx].callsign, callsign, 11);
    g_callsign_hashtable[idx].callsign[11] = '\0';
    g_callsign_hashtable[idx].hash = hash;
}

static bool hashtable_lookup(ftx_callsign_hash_type_t hash_type, uint32_t hash, char* callsign) {
    uint8_t hash_shift = (hash_type == FTX_CALLSIGN_HASH_10_BITS) ? 12
                       : (hash_type == FTX_CALLSIGN_HASH_12_BITS ? 10 : 0);
    uint16_t hash10 = (hash >> (12 - hash_shift)) & 0x3FFu;
    int idx = (hash10 * 23) % CALLSIGN_HASHTABLE_SIZE;
    while (g_callsign_hashtable[idx].callsign[0] != '\0') {
        if (((g_callsign_hashtable[idx].hash & 0x3FFFFFu) >> hash_shift) == hash) {
            strcpy(callsign, g_callsign_hashtable[idx].callsign);
            return true;
        }
        idx = (idx + 1) % CALLSIGN_HASHTABLE_SIZE;
    }
    callsign[0] = '\0';
    return false;
}

static ftx_callsign_hash_interface_t g_hash_if = {
    .lookup_hash = hashtable_lookup,
    .save_hash   = hashtable_add,
};

// ---------------------------------------------------------------------------
// SNR estimate. The waterfall stores per-bin magnitudes in dB. At the 21 FT8
// sync (Costas) symbols the transmitted tone is known, so we can separate
// signal+noise (the expected tone) from noise (the other 7 tones) without
// depending on the decode. We then normalize the per-bin (~6.25 Hz) noise to
// the 2500 Hz reference WSJT-X reports against (−10·log10(2500/6.25) ≈ −26 dB).
// Replaces the old `score * 0.5` proxy, which was a sync score, not SNR.

// Pointer to symbol 0 of the candidate (mirrors decode.c's get_cand_mag).
static const WF_ELEM_T* ft8808_cand_mag(const ftx_waterfall_t* wf,
                                        const ftx_candidate_t* c) {
    int32_t offset = c->time_offset;
    offset = (offset * wf->time_osr) + c->time_sub;
    offset = (offset * wf->freq_osr) + c->freq_sub;
    offset = (offset * wf->num_bins) + c->freq_offset;
    return wf->mag + offset;
}

static float ft8808_estimate_snr(const ftx_waterfall_t* wf,
                                 const ftx_candidate_t* cand) {
    const WF_ELEM_T* mag_cand = ft8808_cand_mag(wf, cand);
    double sig_sum = 0.0, noise_sum = 0.0;
    int sig_n = 0, noise_n = 0;

    for (int m = 0; m < FT8_NUM_SYNC; ++m) {
        for (int k = 0; k < FT8_LENGTH_SYNC; ++k) {
            int block = (FT8_SYNC_OFFSET * m) + k;
            int block_abs = cand->time_offset + block;
            if (block_abs < 0) continue;
            if (block_abs >= wf->num_blocks) break;

            const WF_ELEM_T* p8 = mag_cand + (block * wf->block_stride);
            int sm = kFT8_Costas_pattern[k];   // expected tone
            for (int tone = 0; tone < 8; ++tone) {
                double lin = pow(10.0, WF_ELEM_MAG(p8[tone]) / 10.0);
                if (tone == sm) { sig_sum += lin; ++sig_n; }
                else            { noise_sum += lin; ++noise_n; }
            }
        }
    }
    if (sig_n == 0 || noise_n == 0) return -24.0f;

    double signal_plus_noise = sig_sum / sig_n;
    double noise = noise_sum / noise_n;
    double signal = signal_plus_noise - noise;
    if (signal < 1e-12) signal = 1e-12;

    double snr = 10.0 * log10(signal / noise) - 26.0;  // → 2500 Hz reference
    if (snr < -28.0) snr = -28.0;
    if (snr >  40.0) snr =  40.0;
    return (float)snr;
}

// ---------------------------------------------------------------------------
int ft8808_decode_samples(const float* samples,
                          int num_samples,
                          int sample_rate,
                          ft8808_protocol_t protocol,
                          ft8808_decoded_t* out,
                          int max_out) {
    if (samples == NULL || out == NULL || max_out <= 0 || num_samples <= 0) {
        return -2;
    }

    hashtable_init();

    monitor_config_t mon_cfg = {
        .f_min       = 200,
        .f_max       = 3000,
        .sample_rate = sample_rate,
        .time_osr    = FT8808_TIME_OSR,
        .freq_osr    = FT8808_FREQ_OSR,
        .protocol    = (protocol == FT8808_PROTOCOL_FT4) ? FTX_PROTOCOL_FT4 : FTX_PROTOCOL_FT8,
    };

    monitor_t mon;
    monitor_init(&mon, &mon_cfg);

    // Accumulate the whole sample block into the waterfall, block by block.
    for (int pos = 0; pos + mon.block_size <= num_samples; pos += mon.block_size) {
        monitor_process(&mon, samples + pos);
    }

    const ftx_waterfall_t* wf = &mon.wf;

    ftx_candidate_t candidates[FT8808_MAX_CANDIDATES];
    int num_candidates = ftx_find_candidates(wf, FT8808_MAX_CANDIDATES, candidates, FT8808_MIN_SCORE);

    // De-duplication table of decoded messages.
    ftx_message_t  decoded[FT8808_MAX_DECODED];
    ftx_message_t* decoded_hashtable[FT8808_MAX_DECODED];
    for (int i = 0; i < FT8808_MAX_DECODED; ++i) decoded_hashtable[i] = NULL;

    int num_out = 0;

    for (int idx = 0; idx < num_candidates && num_out < max_out; ++idx) {
        const ftx_candidate_t* cand = &candidates[idx];

        float freq_hz  = (mon.min_bin + cand->freq_offset + (float)cand->freq_sub / wf->freq_osr) / mon.symbol_period;
        float time_sec = (cand->time_offset + (float)cand->time_sub / wf->time_osr) * mon.symbol_period;

        ftx_message_t message;
        ftx_decode_status_t status;
        if (!ftx_decode_candidate(wf, cand, FT8808_LDPC_ITERS, &message, &status)) {
            continue; // LDPC failure or CRC mismatch
        }

        // Linear-probe de-dup, identical to the upstream demo.
        int idx_hash = message.hash % FT8808_MAX_DECODED;
        bool found_empty = false, found_dup = false;
        do {
            if (decoded_hashtable[idx_hash] == NULL) {
                found_empty = true;
            } else if ((decoded_hashtable[idx_hash]->hash == message.hash) &&
                       (0 == memcmp(decoded_hashtable[idx_hash]->payload, message.payload, sizeof(message.payload)))) {
                found_dup = true;
            } else {
                idx_hash = (idx_hash + 1) % FT8808_MAX_DECODED;
            }
        } while (!found_empty && !found_dup);

        if (!found_empty) continue; // duplicate

        memcpy(&decoded[idx_hash], &message, sizeof(message));
        decoded_hashtable[idx_hash] = &decoded[idx_hash];

        char text[FTX_MAX_MESSAGE_LENGTH];
        ftx_message_offsets_t offsets;
        ftx_message_rc_t rc = ftx_message_decode(&message, &g_hash_if, text, &offsets);
        if (rc != FTX_MESSAGE_RC_OK) continue;

        ft8808_decoded_t* o = &out[num_out++];
        strncpy(o->text, text, sizeof(o->text) - 1);
        o->text[sizeof(o->text) - 1] = '\0';
        o->freq_hz  = freq_hz;
        o->time_sec = time_sec;
        o->score    = cand->score;
        o->snr_db   = ft8808_estimate_snr(wf, cand);
    }

    monitor_free(&mon);
    return num_out;
}

int ft8808_decode_wav(const char* path,
                      ft8808_protocol_t protocol,
                      ft8808_decoded_t* out,
                      int max_out) {
    // FT8 is ~15 s; allow a generous ceiling. 12 kHz * 30 s.
    static float signal[12000 * 30];
    int num_samples = sizeof(signal) / sizeof(signal[0]);
    int sample_rate = 0;

    if (load_wav(signal, &num_samples, &sample_rate, path) < 0) {
        return -1;
    }
    return ft8808_decode_samples(signal, num_samples, sample_rate, protocol, out, max_out);
}

// ---- Transmit path --------------------------------------------------------
// GFSK synthesis adapted from ft8_lib demo/gen_ft8.c (MIT, (c) Kārlis Goba),
// with heap-allocated work buffers instead of large stack VLAs.

#define FT8808_GFSK_K 5.336446f // == pi * sqrt(2 / log(2))
#define FT8_SYMBOL_BT 2.0f
#define FT4_SYMBOL_BT 1.0f

int ft8808_encode_message(const char* text, ft8808_protocol_t protocol,
                          unsigned char* tones_out, int max_tones) {
    if (text == NULL || tones_out == NULL) return -2;
    bool is_ft4 = (protocol == FT8808_PROTOCOL_FT4);
    int num_tones = is_ft4 ? FT4_NN : FT8_NN;
    if (max_tones < num_tones) return -3;

    ftx_message_t msg;
    ftx_message_rc_t rc = ftx_message_encode(&msg, NULL, text);
    if (rc != FTX_MESSAGE_RC_OK) return -1;

    if (is_ft4) {
        ft4_encode(msg.payload, tones_out);
    } else {
        ft8_encode(msg.payload, tones_out);
    }
    return num_tones;
}

static void ft8808_gfsk_pulse(int n_spsym, float symbol_bt, float* pulse) {
    for (int i = 0; i < 3 * n_spsym; ++i) {
        float t = i / (float)n_spsym - 1.5f;
        float arg1 = FT8808_GFSK_K * symbol_bt * (t + 0.5f);
        float arg2 = FT8808_GFSK_K * symbol_bt * (t - 0.5f);
        pulse[i] = (erff(arg1) - erff(arg2)) / 2;
    }
}

int ft8808_synthesize(const unsigned char* tones, int num_tones, float f0,
                      ft8808_protocol_t protocol, int sample_rate,
                      float* signal, int max_samples) {
    if (tones == NULL || signal == NULL || num_tones <= 0 || sample_rate <= 0) return -2;
    bool is_ft4 = (protocol == FT8808_PROTOCOL_FT4);
    float symbol_period = is_ft4 ? FT4_SYMBOL_PERIOD : FT8_SYMBOL_PERIOD;
    float symbol_bt = is_ft4 ? FT4_SYMBOL_BT : FT8_SYMBOL_BT;

    int n_spsym = (int)(0.5f + sample_rate * symbol_period); // samples per symbol
    int n_wave = num_tones * n_spsym;                        // output samples
    if (n_wave > max_samples) return -3;

    float hmod = 1.0f;
    float dphi_peak = 2 * M_PI * hmod / n_spsym;
    int dphi_len = n_wave + 2 * n_spsym;

    float* dphi = (float*)malloc(sizeof(float) * (size_t)dphi_len);
    float* pulse = (float*)malloc(sizeof(float) * (size_t)(3 * n_spsym));
    if (dphi == NULL || pulse == NULL) { free(dphi); free(pulse); return -4; }

    for (int i = 0; i < dphi_len; ++i) dphi[i] = 2 * M_PI * f0 / sample_rate;
    ft8808_gfsk_pulse(n_spsym, symbol_bt, pulse);

    for (int i = 0; i < num_tones; ++i) {
        int ib = i * n_spsym;
        for (int j = 0; j < 3 * n_spsym; ++j)
            dphi[j + ib] += dphi_peak * tones[i] * pulse[j];
    }
    // Extend first and last symbols.
    for (int j = 0; j < 2 * n_spsym; ++j) {
        dphi[j] += dphi_peak * pulse[j + n_spsym] * tones[0];
        dphi[j + num_tones * n_spsym] += dphi_peak * pulse[j] * tones[num_tones - 1];
    }

    float phi = 0;
    for (int k = 0; k < n_wave; ++k) {
        signal[k] = sinf(phi);
        phi = fmodf(phi + dphi[k + n_spsym], 2 * M_PI);
    }
    // Ramp the first/last symbol envelopes to avoid key clicks.
    int n_ramp = n_spsym / 8;
    for (int i = 0; i < n_ramp; ++i) {
        float env = (1 - cosf(2 * M_PI * i / (2 * n_ramp))) / 2;
        signal[i] *= env;
        signal[n_wave - 1 - i] *= env;
    }

    free(dphi);
    free(pulse);
    return n_wave;
}
