// Compile the shim here so the bounded cache and time-index normalization can
// be exercised without adding test-only functions to the production API.
#include "../Sources/cft8/shim/tx500_ft8_shim.c"

#include <stdio.h>

static void check(bool condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        exit(1);
    }
}

static void test_time_indices(void) {
    ftx_candidate_t candidate = {0};
    set_candidate_time_index(&candidate, -1, FT8808_TIME_OSR);
    check(candidate.time_offset == -1 && candidate.time_sub == 3,
          "negative sub-bin index uses floor division");
    set_candidate_time_index(&candidate, -39, FT8808_TIME_OSR);
    check(candidate.time_offset == -10 && candidate.time_sub == 1,
          "earliest search offsets remain normalized");
}

static void test_callsign_cache(void) {
    char found[12] = {0};
    hashtable_init();
    hashtable_add("A1AAA", 0);
    hashtable_add("B2BBB", 256u << 12); // Same old table bucket, different hash.
    g_callsign_cache[0].age = CALLSIGN_MAX_AGE_DECODES;
    hashtable_cleanup();
    check(g_callsign_cache_count == 1, "expired entry is removed");
    check(hashtable_lookup(FTX_CALLSIGN_HASH_22_BITS, 256u << 12, found) &&
          strcmp(found, "B2BBB") == 0,
          "removing one entry does not hide another");

    hashtable_init();
    hashtable_add("C3CCC", (0x155u << 12) | 1u);
    hashtable_add("D4DDD", (0x155u << 12) | 2u);
    check(!hashtable_lookup(FTX_CALLSIGN_HASH_10_BITS, 0x155u, found) && found[0] == '\0',
          "ambiguous short hash cannot select the wrong station");

    hashtable_init();
    hashtable_add("E5EEE", 42);
    for (int i = 0; i < CALLSIGN_MAX_AGE_DECODES; ++i) hashtable_cleanup();
    check(hashtable_lookup(FTX_CALLSIGN_HASH_22_BITS, 42, found),
          "recent callsign survives ten subsequent decodes");
    hashtable_cleanup();
    check(!hashtable_lookup(FTX_CALLSIGN_HASH_22_BITS, 42, found),
          "old callsign expires");

    hashtable_init();
    for (unsigned i = 0; i < 400; ++i) {
        char call[12];
        snprintf(call, sizeof(call), "A%04u", i);
        hashtable_add(call, i);
    }
    check(g_callsign_cache_count == CALLSIGN_CACHE_CAPACITY,
          "cache remains bounded under dense traffic");
    check(hashtable_lookup(FTX_CALLSIGN_HASH_22_BITS, 399, found) &&
          strcmp(found, "A0399") == 0,
          "new callsign remains available when the cache is full");
}

static void test_noise_decode(void) {
    const int count = 180000;
    float *samples = malloc((size_t)count * sizeof(*samples));
    check(samples != NULL, "noise buffer allocated");
    uint32_t rng = 0x19830623u;
    for (int i = 0; i < count; ++i) {
        rng = rng * 1664525u + 1013904223u;
        samples[i] = ((int)(rng >> 16) - 32768) / 3276800.0f;
    }
    ft8808_decoded_t out[100];
    int decoded = ft8808_decode_samples(samples, count, 12000, FT8808_PROTOCOL_FT8, out, 100);
    check(decoded >= 0, "noisy receive block decodes without a memory error");
    free(samples);
}

static void *decode_in_parallel(void *context) {
    const float *samples = context;
    for (int i = 0; i < 2; ++i) {
        ft8808_decoded_t out[10];
        int decoded = ft8808_decode_samples(samples, 180000, 12000,
                                             FT8808_PROTOCOL_FT8, out, 10);
        if (decoded < 0) return (void *)1;
    }
    return NULL;
}

static void test_parallel_decodes(void) {
    float *silence = calloc(180000, sizeof(*silence));
    check(silence != NULL, "parallel receive buffer allocated");
    pthread_t threads[4];
    for (size_t i = 0; i < 4; ++i)
        check(pthread_create(&threads[i], NULL, decode_in_parallel, silence) == 0,
              "parallel decoder thread started");
    for (size_t i = 0; i < 4; ++i) {
        void *result = NULL;
        check(pthread_join(threads[i], &result) == 0 && result == NULL,
              "parallel decodes completed safely");
    }
    free(silence);
}

static void test_two_slot_hash(void) {
    const char *messages[] = {"CQ PJ4/K1ABC", "EP2AES PJ4/K1ABC RR73"};
    const char *expected[] = {"CQ PJ4/K1ABC", "EP2AES <PJ4/K1ABC> RR73"};
    hashtable_init();
    for (int slot = 0; slot < 2; ++slot) {
        unsigned char tones[FT8808_MAX_TONES];
        int n = ft8808_encode_message(messages[slot], FT8808_PROTOCOL_FT8,
                                      tones, FT8808_MAX_TONES);
        check(n == 79, "FT8 message encoded");
        float *samples = calloc(180000, sizeof(*samples));
        check(samples != NULL, "slot buffer allocated");
        int written = ft8808_synthesize(tones, n, 1500.0f, FT8808_PROTOCOL_FT8,
                                        12000, samples + 6000, 174000);
        check(written > 0, "FT8 audio synthesized");
        ft8808_decoded_t out[10];
        int decoded = ft8808_decode_samples(samples, 180000, 12000,
                                             FT8808_PROTOCOL_FT8, out, 10);
        bool matched = false;
        for (int i = 0; i < decoded; ++i) {
            if (strcmp(out[i].text, expected[slot]) == 0) matched = true;
        }
        check(matched, "hashed callsign resolves across receive slots");
        free(samples);
    }
}

int main(void) {
    test_time_indices();
    test_callsign_cache();
    test_noise_decode();
    test_two_slot_hash();
    test_parallel_decodes();
    puts("FT8 decoder safety tests passed");
    return 0;
}
