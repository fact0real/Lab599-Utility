/* SPDX-License-Identifier: GPL-3.0-or-later
 * FM demodulator and sample buffer for the core. Standard DSP, written from scratch.
 */
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include "internal.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

int fm_demod_init(fm_demod *d, double fs, double fc, double lp_cut_hz, double target_fd) {
    memset(d, 0, sizeof *d);
    if (fs < 4000.0) return -1;
    d->fs = fs;
    d->fc = fc;
    d->D = (int)floor(fs / target_fd);
    if (d->D < 1) d->D = 1;
    d->fd = fs / d->D;
    /* Hamming window, transition about 500 Hz: about 3.3 * fs / 500 taps, odd. */
    int n = (int)ceil(3.3 * fs / 500.0);
    if (n < 31) n = 31;
    if ((n & 1) == 0) n++;
    d->ntaps = n;
    d->h = calloc((size_t)n, sizeof(double));
    d->hi = calloc((size_t)n, sizeof(double));
    d->hq = calloc((size_t)n, sizeof(double));
    if (!d->h || !d->hi || !d->hq) { fm_demod_free(d); return -1; }
    double wc = 2.0 * M_PI * lp_cut_hz / fs, sum = 0.0;
    int m = (n - 1) / 2;
    for (int i = 0; i < n; i++) {
        int k = i - m;
        double s = (k == 0) ? wc / M_PI : sin(wc * k) / (M_PI * k);
        double w = 0.54 - 0.46 * cos(2.0 * M_PI * i / (n - 1));
        d->h[i] = s * w;
        sum += d->h[i];
    }
    for (int i = 0; i < n; i++) d->h[i] /= sum;
    return 0;
}

void fm_demod_free(fm_demod *d) {
    free(d->h); free(d->hi); free(d->hq);
    d->h = d->hi = d->hq = NULL;
}

size_t fm_demod_run(fm_demod *d, const float *x, size_t n, float *f_out, float *a_out, double *t_out, size_t cap) {
    return fm_demod_run_iq(d, x, n, f_out, a_out, NULL, NULL, t_out, cap);
}

size_t fm_demod_run_iq(fm_demod *d, const float *x, size_t n, float *f_out, float *a_out, float *i_out, float *q_out,
                       double *t_out, size_t cap) {
    size_t out = 0;
    const int N = d->ntaps;
    const double delay = (N - 1) / 2.0;
    for (size_t i = 0; i < n; i++) {
        double ph = d->fc * (double)d->n / d->fs;
        ph -= floor(ph);
        ph *= 2.0 * M_PI;
        double v = x[i];
        d->hi[d->pos] = v * cos(ph);
        d->hq[d->pos] = -v * sin(ph);
        d->pos = (d->pos + 1) % N;
        d->n++;
        /* the ring starts full of zeros, so the first outputs are valid from the first sample:
           a sync at the very start of a file keeps its leading edge */
        if ((d->n % (uint64_t)d->D) != 0) continue;
        /* FIR over the ring: oldest sample first. */
        double zi = 0.0, zq = 0.0;
        int p = d->pos;
        for (int k = 0; k < N; k++) {
            zi += d->h[k] * d->hi[p];
            zq += d->h[k] * d->hq[p];
            if (++p == N) p = 0;
        }
        if (d->have_prev && out < cap) {
            /* phase step between this output and the previous one */
            double re = zi * d->zi_prev + zq * d->zq_prev;
            double im = zq * d->zi_prev - zi * d->zq_prev;
            double dphi = atan2(im, re);
            double f = d->fc + dphi * d->fd / (2.0 * M_PI);
            /* the newest input sample is n-1; the filter output refers to n-1-delay;
               the phase step sits half a decimated sample earlier */
            double t = ((double)(d->n - 1) - delay - 0.5 * d->D) / d->fs;
            f_out[out] = (float)f;
            a_out[out] = (float)sqrt(zi * zi + zq * zq);
            if (i_out) i_out[out] = (float)zi;
            if (q_out) q_out[out] = (float)zq;
            t_out[out] = t;
            out++;
        }
        d->zi_prev = zi; d->zq_prev = zq; d->have_prev = 1;
    }
    return out;
}

int sbuf_push_iq(sample_buf *b, float f, float a, float zi, float zq, double t) {
    if (!b->t0_set) { b->t0 = t; b->t0_set = 1; }
    if (b->n == b->cap) {
        size_t nc = b->cap ? b->cap * 2 : 65536;
        float *nf = realloc(b->f, nc * sizeof(float));
        if (!nf) return -1;
        b->f = nf;
        float *na = realloc(b->a, nc * sizeof(float));
        if (!na) return -1;
        b->a = na;
        if (b->has_iq) {
            float *ni = realloc(b->zi, nc * sizeof(float));
            if (!ni) return -1;
            b->zi = ni;
            float *nq = realloc(b->zq, nc * sizeof(float));
            if (!nq) return -1;
            b->zq = nq;
        }
        b->cap = nc;
    }
    b->f[b->n] = f;
    b->a[b->n] = a;
    if (b->has_iq) { b->zi[b->n] = zi; b->zq[b->n] = zq; }
    b->n++;
    return 0;
}

int sbuf_push(sample_buf *b, float f, float a, double t) { return sbuf_push_iq(b, f, a, 0.0f, 0.0f, t); }

double sbuf_tone_power(const sample_buf *b, double fb, double ta, double tb) {
    if (!b->has_iq || b->n == 0) return 0.0;
    size_t i0 = sbuf_index(b, ta), i1 = sbuf_index(b, tb);
    if (i1 <= i0) return 0.0;
    double w = 2.0 * M_PI * fb * b->dt;
    /* rotate by e^{-j w k} with a recurrence, renormalised now and then */
    double cr = 1.0, ci = 0.0, sr = 0.0, si = 0.0, dr = cos(w), di = -sin(w);
    for (size_t i = i0; i < i1; i++) {
        double x = b->zi[i], y = b->zq[i];
        sr += x * cr - y * ci;
        si += x * ci + y * cr;
        double nr = cr * dr - ci * di;
        ci = cr * di + ci * dr;
        cr = nr;
        if (((i - i0) & 255) == 255) { double m = sqrt(cr * cr + ci * ci); cr /= m; ci /= m; }
    }
    double n = (double)(i1 - i0);
    return (sr * sr + si * si) / (n * n);
}

double sbuf_power(const sample_buf *b, double ta, double tb) {
    if (b->n == 0) return 0.0;
    size_t i0 = sbuf_index(b, ta), i1 = sbuf_index(b, tb);
    if (i1 <= i0) return 0.0;
    double s = 0.0;
    for (size_t i = i0; i < i1; i++) s += (double)b->a[i] * b->a[i];
    return s / (double)(i1 - i0);
}

int sbuf_covers(const sample_buf *b, double ta, double tb) {
    return b->n > 0 && ta >= sbuf_time(b, 0) && tb <= sbuf_time(b, b->n - 1);
}

void sbuf_drop(sample_buf *b, size_t k) {
    if (k == 0) return;
    if (k >= b->n) { b->base += b->n; b->n = 0; return; }
    memmove(b->f, b->f + k, (b->n - k) * sizeof(float));
    memmove(b->a, b->a + k, (b->n - k) * sizeof(float));
    if (b->has_iq) {
        memmove(b->zi, b->zi + k, (b->n - k) * sizeof(float));
        memmove(b->zq, b->zq + k, (b->n - k) * sizeof(float));
    }
    b->n -= k;
    b->base += k;
}

double sbuf_time(const sample_buf *b, size_t i) { return b->t0 + (double)(b->base + i) * b->dt; }

size_t sbuf_index(const sample_buf *b, double t) {
    double x = (t - b->t0) / b->dt - (double)b->base;
    if (x <= 0.0) return 0;
    if (x >= (double)b->n) return b->n;
    return (size_t)x;
}

void sbuf_clear(sample_buf *b) { b->base += b->n; b->n = 0; }

void sbuf_free(sample_buf *b) {
    free(b->f); free(b->a); free(b->zi); free(b->zq);
    memset(b, 0, sizeof *b);
}

double sbuf_at(const sample_buf *b, double t) {
    if (b->n == 0) return 0.0;
    double x = (t - b->t0) / b->dt - (double)b->base;
    if (x <= 0.0) return b->f[0];
    if (x >= (double)(b->n - 1)) return b->f[b->n - 1];
    size_t i = (size_t)x;
    double fr = x - (double)i;
    return b->f[i] * (1.0 - fr) + b->f[i + 1] * fr;
}

/* Exact integral of the piecewise-linear interpolant over [ta, tb), divided by the length. */
double sbuf_mean(const sample_buf *b, double ta, double tb) {
    if (b->n == 0) return 0.0;
    if (tb <= ta) return sbuf_at(b, ta);
    double xa = (ta - b->t0) / b->dt - (double)b->base, xb = (tb - b->t0) / b->dt - (double)b->base;
    double last = (double)(b->n - 1);
    if (xa < 0.0) xa = 0.0;
    if (xb > last) xb = last;
    if (xb <= xa) return sbuf_at(b, ta);
    double acc = 0.0;
    double x = xa;
    while (x < xb) {
        double xi = floor(x);
        double xn = xi + 1.0;
        if (xn > xb) xn = xb;
        size_t i = (size_t)xi;
        double f0 = b->f[i], f1 = (i + 1 < b->n) ? b->f[i + 1] : b->f[i];
        double fa = f0 + (f1 - f0) * (x - xi);
        double fb = f0 + (f1 - f0) * (xn - xi);
        acc += 0.5 * (fa + fb) * (xn - x);
        x = xn;
    }
    return acc / (xb - xa);
}
