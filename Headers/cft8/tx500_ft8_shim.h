// ft8808_shim.h — clean C entry point over kgoba/ft8_lib (MIT) for FT8-808.
//
// This header is intentionally self-contained (no ft8_lib types leak through),
// so the Swift side imports a small, stable surface. The implementation in
// shim/ft8808_shim.c drives the full ft8_lib decode pipeline
// (monitor -> find_candidates -> decode_candidate -> message_decode).

#ifndef FT8808_SHIM_H
#define FT8808_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    FT8808_PROTOCOL_FT8 = 0,
    FT8808_PROTOCOL_FT4 = 1
} ft8808_protocol_t;

typedef struct {
    char  text[35];  // decoded message, null-terminated (FTX_MAX_MESSAGE_LENGTH)
    float freq_hz;   // audio frequency offset within the passband
    float time_sec;  // time offset of the message start within the slot
    float time_uncertainty_sec; // one-sigma timing estimate after Costas peak refinement
    int   score;     // Costas sync score (higher = stronger candidate)
    float snr_db;    // Estimated SNR in dB, 2500 Hz reference (WSJT-X-comparable)
} ft8808_decoded_t;

// Decode FT8/FT4 from a block of mono float PCM samples in [-1, +1].
// Fills up to `max_out` entries in `out`. Duplicates are removed.
// Returns the number of messages decoded, or a negative value on error.
int ft8808_decode_samples(const float* samples,
                          int num_samples,
                          int sample_rate,
                          ft8808_protocol_t protocol,
                          ft8808_decoded_t* out,
                          int max_out);

// Convenience: load a 16-bit PCM WAV file and decode it.
// Returns the number of messages decoded, or:
//   -1 = failed to load the WAV file.
int ft8808_decode_wav(const char* path,
                      ft8808_protocol_t protocol,
                      ft8808_decoded_t* out,
                      int max_out);

// ---- Transmit path -------------------------------------------------------

// Maximum number of tones in a transmission (FT4 = 105 >= FT8 = 79).
#define FT8808_MAX_TONES 105

// Encode a message into FSK tones (0..7 for FT8). `tones_out` must hold at
// least FT8808_MAX_TONES bytes. Returns the number of tones (79 for FT8,
// 105 for FT4), or a negative value on error (-1 = message could not be
// parsed/packed into a valid FT8/FT4 message).
int ft8808_encode_message(const char* text,
                          ft8808_protocol_t protocol,
                          unsigned char* tones_out,
                          int max_tones);

// Synthesize GFSK-shaped audio from tones into `signal_out` (mono, [-1, +1]).
// `base_freq_hz` is the audio frequency of tone 0. Returns the number of
// samples written (the on-air waveform, no silence padding), or negative on
// error. Use ft8808_slot_samples() to size a full padded slot if desired.
int ft8808_synthesize(const unsigned char* tones,
                      int num_tones,
                      float base_freq_hz,
                      ft8808_protocol_t protocol,
                      int sample_rate,
                      float* signal_out,
                      int max_samples);

typedef ft8808_protocol_t tx500_ft8_protocol_t;
#define TX500_FT8_PROTOCOL_FT8 FT8808_PROTOCOL_FT8
#define TX500_FT8_PROTOCOL_FT4 FT8808_PROTOCOL_FT4
typedef ft8808_decoded_t tx500_ft8_decoded_t;
#define tx500_ft8_decode_samples ft8808_decode_samples
#define tx500_ft8_decode_wav ft8808_decode_wav
#define tx500_ft8_encode_message ft8808_encode_message
#define tx500_ft8_synthesize ft8808_synthesize

#ifdef __cplusplus
}
#endif

#endif // FT8808_SHIM_H
