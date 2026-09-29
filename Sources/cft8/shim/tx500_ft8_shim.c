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
#include <limits.h>
#include <pthread.h>

// ---- Decode tuning (Optimized for Deep FT8 Decoding) ------------------------
#define FT8808_MIN_SCORE      7    // Lowered threshold to extract faint signals (-24 to -26 dB)
#define FT8808_MAX_CANDIDATES 220  // Expanded candidate pool for dense band conditions
#define FT8808_LDPC_ITERS     40   // Increased LDPC belief propagation iterations for maximum convergence
#define FT8808_MAX_DECODED    100  // Allow up to 100 decodes per 15s window
#define FT8808_FREQ_OSR       2
#define FT8808_TIME_OSR       4

// ---- Bounded callsign cache ----------------------------------------------
// FT8 hashes nonstandard callsigns. Keep recently decoded full calls across
// receive blocks, but never guess when a shortened hash matches two stations.
// A compact array makes expiry safe: deleting an entry cannot break a probe
// chain, and every lookup/insertion has a fixed upper bound of 256 entries.
#define CALLSIGN_CACHE_CAPACITY 256
#define CALLSIGN_MAX_AGE_DECODES 10
#define CALLSIGN_HASH_MASK 0x3FFFFFu

typedef struct {
    char callsign[12];
    uint32_t hash;
    uint8_t age;
    uint64_t last_seen;
} callsign_cache_entry_t;

static callsign_cache_entry_t g_callsign_cache[CALLSIGN_CACHE_CAPACITY];
static size_t g_callsign_cache_count;
static uint64_t g_callsign_cache_sequence;
static bool g_callsign_cache_ready;
// ft8_lib's hash callbacks have no context pointer. Hold this lock over the
// entire decode so callbacks and cache ageing cannot race across callers.
static pthread_mutex_t g_decode_mutex = PTHREAD_MUTEX_INITIALIZER;

static void hashtable_init(void) {
    g_callsign_cache_count = 0;
    g_callsign_cache_sequence = 0;
    g_callsign_cache_ready = true;
}

static void hashtable_cleanup(void) {
    size_t retained = 0;
    for (size_t i = 0; i < g_callsign_cache_count; ++i) {
        callsign_cache_entry_t entry = g_callsign_cache[i];
        if (entry.age >= CALLSIGN_MAX_AGE_DECODES) continue;
        entry.age++;
        g_callsign_cache[retained++] = entry;
    }
    g_callsign_cache_count = retained;
}

static void hashtable_add(const char* callsign, uint32_t hash) {
    if (!callsign || !callsign[0] || strlen(callsign) >= sizeof(g_callsign_cache[0].callsign)) return;
    hash &= CALLSIGN_HASH_MASK;
    for (size_t i = 0; i < g_callsign_cache_count; ++i) {
        callsign_cache_entry_t *entry = &g_callsign_cache[i];
        if (entry->hash == hash && strcmp(entry->callsign, callsign) == 0) {
            entry->age = 0;
            entry->last_seen = ++g_callsign_cache_sequence;
            return;
        }
    }

    size_t index = g_callsign_cache_count;
    if (index < CALLSIGN_CACHE_CAPACITY) {
        g_callsign_cache_count++;
    } else {
        // Evict the stalest entry; break same-age ties by last observation.
        index = 0;
        for (size_t i = 1; i < CALLSIGN_CACHE_CAPACITY; ++i) {
            if (g_callsign_cache[i].age > g_callsign_cache[index].age ||
                (g_callsign_cache[i].age == g_callsign_cache[index].age &&
                 g_callsign_cache[i].last_seen < g_callsign_cache[index].last_seen)) index = i;
        }
    }
    callsign_cache_entry_t *entry = &g_callsign_cache[index];
    strcpy(entry->callsign, callsign);
    entry->hash = hash;
    entry->age = 0;
    entry->last_seen = ++g_callsign_cache_sequence;
}

static bool hashtable_lookup(ftx_callsign_hash_type_t hash_type, uint32_t hash, char* callsign) {
    if (!callsign) return false;
    callsign[0] = '\0';
    unsigned shift;
    switch (hash_type) {
        case FTX_CALLSIGN_HASH_10_BITS: shift = 12; break;
        case FTX_CALLSIGN_HASH_12_BITS: shift = 10; break;
        case FTX_CALLSIGN_HASH_22_BITS: shift = 0; break;
        default: return false;
    }
    const char *match = NULL;
    for (size_t i = 0; i < g_callsign_cache_count; ++i) {
        const callsign_cache_entry_t *entry = &g_callsign_cache[i];
        if ((entry->hash >> shift) != hash) continue;
        if (match && strcmp(match, entry->callsign) != 0) return false;
        match = entry->callsign;
    }
    if (!match) return false;
    strcpy(callsign, match);
    return true;
}

static void set_candidate_time_index(ftx_candidate_t *candidate, int index, int time_osr) {
    int offset = index / time_osr;
    int sub = index % time_osr;
    if (sub < 0) { sub += time_osr; offset--; }
    candidate->time_offset = offset;
    candidate->time_sub = (uint8_t)sub;
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

    if (wf->protocol == FTX_PROTOCOL_FT4) {
        for (int m = 0; m < FT4_NUM_SYNC; ++m) {
            for (int k = 0; k < FT4_LENGTH_SYNC; ++k) {
                int block = 1 + (FT4_SYNC_OFFSET * m) + k;
                int block_abs = cand->time_offset + block;
                if (block_abs < 0) continue;
                if (block_abs >= wf->num_blocks) break;

                const WF_ELEM_T* p4 = mag_cand + (block * wf->block_stride);
                int sm = kFT4_Costas_pattern[m][k]; // expected tone 0..3
                for (int tone = 0; tone < 4; ++tone) {
                    double lin = pow(10.0, WF_ELEM_MAG(p4[tone]) / 10.0);
                    if (tone == sm) { sig_sum += lin; ++sig_n; }
                    else            { noise_sum += lin; ++noise_n; }
                }
            }
        }
        if (sig_n == 0 || noise_n == 0) return -20.0f;

        double signal_plus_noise = sig_sum / sig_n;
        double noise = noise_sum / noise_n;
        double signal = signal_plus_noise - noise;
        if (signal < 1e-12) signal = 1e-12;

        // Tone spacing = 20.8333 Hz, reference noise bandwidth = 2500 Hz
        // 10 * log10(2500 / 20.8333) = 10 * log10(120) ≈ 20.79 dB
        double snr = 10.0 * log10(signal / noise) - 20.8;
        if (snr < -24.0) snr = -24.0;
        if (snr >  40.0) snr =  40.0;
        return (float)snr;
    } else {
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
}

// ---------------------------------------------------------------------------
int ft8808_decode_samples(const float* samples,
                          int num_samples,
                          int sample_rate,
                          ft8808_protocol_t protocol,
                          ft8808_decoded_t* out,
                          int max_out) {
    if (samples == NULL || out == NULL || max_out <= 0 || num_samples <= 0 || sample_rate <= 0) {
        return -2;
    }

    pthread_mutex_lock(&g_decode_mutex);
    if (!g_callsign_cache_ready) hashtable_init();
    else hashtable_cleanup();

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
    int num_stored = 0;

    for (int idx = 0; idx < num_candidates && num_out < max_out && num_stored < FT8808_MAX_DECODED; ++idx) {
        const ftx_candidate_t* cand = &candidates[idx];

        float freq_hz  = (mon.min_bin + cand->freq_offset + (float)cand->freq_sub / wf->freq_osr) / mon.symbol_period;
        int time_index = cand->time_offset * wf->time_osr + cand->time_sub;
        float fine_delta = 0.0f;
        float timing_sigma = mon.symbol_period / wf->time_osr;
        if (time_index > -10 * wf->time_osr && time_index < 20 * wf->time_osr - 1) {
            ftx_candidate_t before = *cand, after = *cand;
            set_candidate_time_index(&before, time_index - 1, wf->time_osr);
            set_candidate_time_index(&after, time_index + 1, wf->time_osr);
            int score_before = ftx_candidate_sync_score(wf, &before);
            int score_after = ftx_candidate_sync_score(wf, &after);
            float denominator = (float)score_before - 2.0f * cand->score + (float)score_after;
            if (denominator < -0.5f) {
                fine_delta = 0.5f * ((float)score_before - (float)score_after) / denominator;
                if (fine_delta < -0.5f) fine_delta = -0.5f;
                if (fine_delta > 0.5f) fine_delta = 0.5f;
                timing_sigma *= 0.5f;
            }
        }
        float time_sec = ((float)time_index + fine_delta) / wf->time_osr * mon.symbol_period;

        ftx_message_t message;
        ftx_decode_status_t status;
        if (!ftx_decode_candidate(wf, cand, FT8808_LDPC_ITERS, &message, &status)) {
            continue; // LDPC failure or CRC mismatch
        }

        // Linear-probe de-dup, identical to the upstream demo.
        int idx_hash = message.hash % FT8808_MAX_DECODED;
        bool found_empty = false, found_dup = false;
        int probes = 0;
        do {
            if (decoded_hashtable[idx_hash] == NULL) {
                found_empty = true;
            } else if ((decoded_hashtable[idx_hash]->hash == message.hash) &&
                       (0 == memcmp(decoded_hashtable[idx_hash]->payload, message.payload, sizeof(message.payload)))) {
                found_dup = true;
            } else {
                idx_hash = (idx_hash + 1) % FT8808_MAX_DECODED;
            }
        } while (!found_empty && !found_dup && ++probes < FT8808_MAX_DECODED);

        if (!found_empty) continue; // duplicate or a full de-duplication table

        num_stored++;
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
        o->time_uncertainty_sec = timing_sigma;
        o->score    = cand->score;
        o->snr_db   = ft8808_estimate_snr(wf, cand);
    }

    monitor_free(&mon);
    pthread_mutex_unlock(&g_decode_mutex);
    return num_out;
}

int ft8808_decode_wav(const char* path,
                      ft8808_protocol_t protocol,
                      ft8808_decoded_t* out,
                      int max_out) {
    // FT8 is ~15 s; allow a generous ceiling. 12 kHz * 30 s.
    const int capacity = 12000 * 30;
    float *signal = calloc((size_t)capacity, sizeof(*signal));
    if (!signal) return -2;
    int num_samples = capacity;
    int sample_rate = 0;

    if (load_wav(signal, &num_samples, &sample_rate, path) < 0) {
        free(signal);
        return -1;
    }
    int decoded = ft8808_decode_samples(signal, num_samples, sample_rate, protocol, out, max_out);
    free(signal);
    return decoded;
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
    if (tones == NULL || signal == NULL ||
        (protocol != FT8808_PROTOCOL_FT8 && protocol != FT8808_PROTOCOL_FT4) ||
        num_tones != (protocol == FT8808_PROTOCOL_FT4 ? FT4_NN : FT8_NN) ||
        sample_rate < 8000 || sample_rate > 192000 || max_samples <= 0 ||
        !isfinite(f0) || f0 < 0 || f0 >= sample_rate / 2.0f) return -2;
    bool is_ft4 = (protocol == FT8808_PROTOCOL_FT4);
    float symbol_period = is_ft4 ? FT4_SYMBOL_PERIOD : FT8_SYMBOL_PERIOD;
    float symbol_bt = is_ft4 ? FT4_SYMBOL_BT : FT8_SYMBOL_BT;

    int n_spsym = (int)(0.5f + sample_rate * symbol_period); // samples per symbol
    int64_t n_wave_wide = (int64_t)num_tones * n_spsym;
    if (n_spsym <= 0 || n_wave_wide > max_samples ||
        n_wave_wide > INT_MAX - 2LL * n_spsym) return -3;
    int n_wave = (int)n_wave_wide;                           // output samples

    float hmod = 1.0f;
    float dphi_peak = 2 * M_PI * hmod / n_spsym;
    int dphi_len = n_wave + 2 * n_spsym;

    float* dphi = (float*)calloc((size_t)dphi_len, sizeof(float));
    float* pulse = (float*)calloc((size_t)(3 * n_spsym), sizeof(float));
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
