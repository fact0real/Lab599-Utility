/* SPDX-License-Identifier: GPL-3.0-or-later
 * Internal pieces shared by the SSTV and radiofax receivers. Not part of the public API.
 */
#ifndef SSTV1_INTERNAL_H
#define SSTV1_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

/* FM demodulator: the input is mixed down by fc to a complex baseband, low-pass filtered
 * (windowed sinc), decimated by D, and the instantaneous frequency is the phase step between
 * two outputs. Every output carries its own time, in seconds, as a double: the decimation and
 * the filter delay are accounted for, nothing is rounded. */
typedef struct {
    double fs, fd, fc;
    int D;                  /* decimation factor: fd = fs / D */
    int ntaps;
    double *h;              /* low-pass taps */
    double *hi, *hq;        /* ring of mixed samples */
    int pos;
    uint64_t n;             /* input samples seen */
    double zi_prev, zq_prev;
    int have_prev;
} fm_demod;

int fm_demod_init(fm_demod *d, double fs, double fc, double lp_cut_hz, double target_fd);
void fm_demod_free(fm_demod *d);
/* Process n input samples; writes up to cap outputs (frequency in Hz, amplitude, time in s).
 * Returns the number written. cap must be at least n / D + 1. */
size_t fm_demod_run(fm_demod *d, const float *x, size_t n, float *f_out, float *a_out, double *t_out, size_t cap);
/* The same, and the baseband samples (i, q) of each output; i_out and q_out may be NULL. */
size_t fm_demod_run_iq(fm_demod *d, const float *x, size_t n, float *f_out, float *a_out, float *i_out, float *q_out,
                       double *t_out, size_t cap);

/* A growing array of demodulated samples, with their times. Sample i of the buffer is sample
 * (base + i) of the whole stream, at time t0 + (base + i) * dt: dropping old samples moves base,
 * never t0, so a time is computed the same way however the input was cut into blocks (test 3.10). */
typedef struct {
    float *f, *a;
    float *zi, *zq;         /* the complex baseband itself (fc removed), when has_iq: for tone tests */
    int has_iq;
    double t0, dt;          /* uniform after the demodulator */
    uint64_t base;          /* stream index of f[0] */
    size_t n, cap;
    int t0_set;             /* t0 is fixed: the first push does not set it (copies of a stream) */
} sample_buf;

int sbuf_push(sample_buf *b, float f, float a, double t);
/* The same, with the baseband sample (stored only when has_iq is set). */
int sbuf_push_iq(sample_buf *b, float f, float a, float zi, float zq, double t);
/* Power of the tone at baseband frequency fb (Hz) over [ta, tb): |sum z e^{-j 2 pi fb t}|^2 / N^2. */
double sbuf_tone_power(const sample_buf *b, double fb, double ta, double tb);
/* Mean power of the baseband over [ta, tb): the mean of the squared amplitude (0 if empty). */
double sbuf_power(const sample_buf *b, double ta, double tb);
/* 1 if the buffer holds samples from ta to tb, both ends included. */
int sbuf_covers(const sample_buf *b, double ta, double tb);
/* Drop the oldest k samples. */
void sbuf_drop(sample_buf *b, size_t k);
/* Time of buffer sample i. */
double sbuf_time(const sample_buf *b, size_t i);
/* Buffer index of the sample at or before time t (clamped to [0, n]). */
size_t sbuf_index(const sample_buf *b, double t);
void sbuf_clear(sample_buf *b);
void sbuf_free(sample_buf *b);
/* Mean frequency over [ta, tb), by linear interpolation of the samples (seconds). */
double sbuf_mean(const sample_buf *b, double ta, double tb);
/* Frequency at time t, linear interpolation. */
double sbuf_at(const sample_buf *b, double t);

/* PNG writer (8-bit gray or RGB), stored deflate blocks: no zlib needed. */
int png_write(const char *path, const uint8_t *pix, int w, int h, int channels);

#endif
