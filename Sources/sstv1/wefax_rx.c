/* SPDX-License-Identifier: GPL-3.0-or-later
 * The radiofax (WEFAX) receiver of the core.
 *
 * Written from scratch from WMO-No. 386 Part III section 5 ([W]). Before it was written, fldigi's
 * WEFAX code was read to draw ideas and lessons from it, and nothing was copied from it: the
 * lessons (L1-L8) come from there.
 *  - white +dev, black -dev around 1900 Hz; dev 400 by default, 150, 300 and 425 too (A20);
 *  - start: black/white alternation at 300 Hz (IOC 576) or 675 Hz; stop: 450 Hz; a plain audio
 *    tone at those frequencies is accepted too, as fldigi sends it (A17);
 *  - the receiver starts with the start signal or with the phasing ([W] §5.2.1), and needs
 *    neither: a picture without phasing can be started at hand (F3b);
 *  - phasing symmetric or 5/95, normal or inverted (A22, A23); the line starts at the leading
 *    edge of the white ([W] §5.2.3.4, A24);
 *  - the line period is a double, never rounded (lesson L1): fitted on the phasing edges, then
 *    refined on the picture itself (lesson L2, A19);
 *  - width pi * IOC, without truncating on the way (A36); a flip option (A29);
 *  - the demodulated samples are kept until the picture is accepted (lesson L3, test 3.9);
 *  - a picture is never dropped in silence (lesson L4).
 *
 * The decisions are taken on fixed 0.1 s blocks of the demodulated stream and of the raw input,
 * aligned to sample indices, so the result does not depend on the size of the input blocks.
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sstv1.h"
#include "internal.h"

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

#define NTONES 3
static const double TONES[NTONES] = { 300.0, 675.0, 450.0 };   /* start 576, start 288, stop */
#define PROFILE_BINS 200

void wefax_rx_config_default(wefax_rx_config *c) {
    memset(c, 0, sizeof *c);
    c->deviation_hz = 400.0;
    c->center_hz = 1900.0;
    c->ioc = 576;
    c->lpm = 120.0;
    c->width = 0;
    c->start_now = 0;
    c->flip = 0;
    c->keep_buffers = 1;
    c->auto_tune = 1;
    c->fit_slant = 1;
    c->preset_slant_ppm = 0.0;
    c->preset_offset_ms = 0.0;
    c->max_lines = 4000.0;
}

enum { S_IDLE = 0, S_START, S_PHASING, S_RECEIVING, S_AFTER_STOP };

typedef struct {
    double c, T;              /* line g starts at c + g * T */
    int g0, lines;            /* first picture line, number of lines */
    int W;
    double off, dev;
    int flip;
} fax_params;

typedef struct {
    sample_buf buf;
    fax_params p;
    int nlost, lost_r0[64], lost_r1[64];   /* the rows inside cuts, grey again when it is drawn again */
    int valid;
} fax_retained;

struct wefax_rx {
    double fs;
    wefax_rx_config cfg;
    double T0;                /* nominal line period */
    int W;
    fm_demod dm;
    float *tf, *ta; double *tt; size_t tcap;
    sample_buf st;
    /* raw tone detector, on blocks of Br input samples */
    uint64_t raw_n;           /* input samples seen */
    int Br;
    double g_s1[NTONES], g_s2[NTONES], g_coef[NTONES], r_sum, r_sum2;
    int r_cnt;
    signed char *raw_tone; float *raw_ratio; size_t nraw, capraw;
    /* stream blocks */
    int B;
    uint64_t next_blk;        /* stream index of the next block */
    int start_run, stop_run, loss_run;
    uint64_t stop_hist;       /* the last 40 blocks: 1 where the stop signal was seen */
    int stop_latched;         /* the vote has passed for this stop signal */
    double start_run_t0, stop_run_t0, start_end;
    int start_freq_tone, start_plain;
    double amp_ref;
    int amp_ref_n;
    /* state */
    int state;
    double ph_a, ph_b, after_until;
    fax_params cur;
    int have_phasing, phasing_kind, phasing_inv, phasing_lines, symmetric_pending, inverted_pending, margin_source;
    double c_alt;             /* symmetric phasing: the other candidate line start */
    int lpm_warned;
    double lpm_cand;          /* the other speed the last check saw (a warning needs two in a row) */
    int ph_fail, ph_fail_max; /* bad phasing windows in a row, and how many end the phasing */
    int ph_from_state;        /* the state before the phasing began */
    int ph_strict;            /* a chart closed by the line limit: only a clear phasing starts the next (until a start or a stop) */
    /* cuts (a cut never closes a chart): the lines go on in place and come out grey */
    int lost_open, good_run;
    double lost_from;
    int nlost; double lost_a[64], lost_b[64];
    double inimg_ph_a;        /* a phasing seen inside a chart since then (the next chart, after one with no stop) */
    int inimg_ph_on;
    double tmpl[PROFILE_BINS];/* the phasing line, folded (analyse_phasing) */
    int margin_seam_px;
    int fldigi_style_seen;    /* the seam put the line start where fldigi puts it (said, not applied, by default) */
    double dev_meas;
    /* results */
    wefax_image *imgs; fax_retained *ret; int nimg, capimg;
    wefax_event *ev; int evn, evcap, evhead;
};

/* ---------------------------------------------------------------- helpers */

static void push_ev(wefax_rx *rx, wefax_event_type type, double t, double value, int plain, int idx, const char *text) {
    if (rx->evn == rx->evcap) {
        int nc = rx->evcap ? rx->evcap * 2 : 32;
        wefax_event *ne = realloc(rx->ev, (size_t)nc * sizeof *ne);
        if (!ne) return;
        rx->ev = ne; rx->evcap = nc;
    }
    wefax_event *e = &rx->ev[rx->evn++];
    memset(e, 0, sizeof *e);
    e->type = type; e->t = t; e->value = value; e->plain_tone = plain; e->image_index = idx;
    snprintf(e->text, sizeof e->text, "%s", text);
}

static void push_note(wefax_rx *rx, wefax_note note, double t, double value, int idx, const char *text) {
    int n0 = rx->evn;
    push_ev(rx, WEFAX_EV_WARNING, t, value, 0, idx, text);
    if (rx->evn > n0) rx->ev[rx->evn - 1].note = note;
}

static int cmp_d(const void *x, const void *y) {
    double a = *(const double *)x, b = *(const double *)y;
    return (a > b) - (a < b);
}

static double median_d(double *v, int n) {
    if (n <= 0) return 0.0;
    qsort(v, (size_t)n, sizeof *v, cmp_d);
    return (n & 1) ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2]);
}

static double bright(double f, double off, double dev, double fc) {
    return (f - off - (fc - dev)) / (2.0 * dev);       /* 0 = black, 1 = white */
}

/* ---------------------------------------------------------------- creation */

wefax_rx *wefax_rx_new(double fs, const wefax_rx_config *cfg) {
    wefax_rx *rx = calloc(1, sizeof *rx);
    if (!rx) return NULL;
    rx->fs = fs;
    if (cfg) rx->cfg = *cfg; else wefax_rx_config_default(&rx->cfg);
    if (rx->cfg.lpm <= 0.0) rx->cfg.lpm = 120.0;
    if (rx->cfg.deviation_hz <= 0.0) rx->cfg.deviation_hz = 400.0;
    if (rx->cfg.center_hz <= 0.0) rx->cfg.center_hz = 1900.0;
    if (rx->cfg.ioc <= 0) rx->cfg.ioc = 576;
    if (rx->cfg.max_lines <= 0.0) rx->cfg.max_lines = 6000.0;
    rx->T0 = 60.0 / rx->cfg.lpm;
    rx->W = rx->cfg.width > 0 ? rx->cfg.width : (int)lround(M_PI * rx->cfg.ioc);
    /* the same front end as SSTV: 1200 Hz either side of 1900 Hz covers 1263-2537 Hz */
    if (fm_demod_init(&rx->dm, fs, rx->cfg.center_hz, 1200.0, 4000.0) != 0) { free(rx); return NULL; }
    rx->st.dt = rx->dm.D / fs;
    rx->B = (int)lround(0.1 / rx->st.dt);
    rx->ph_fail_max = (int)ceil(2.0 * rx->T0 / 0.1);           /* two lines of bad windows */
    rx->Br = (int)lround(0.1 * fs);
    for (int k = 0; k < NTONES; k++) rx->g_coef[k] = 2.0 * cos(2.0 * M_PI * TONES[k] / fs);
    rx->start_end = -1.0;
    rx->cur.W = rx->W;
    rx->cur.off = 0.0;
    rx->cur.dev = rx->cfg.deviation_hz;
    rx->cur.T = rx->T0 * (1.0 + rx->cfg.preset_slant_ppm * 1e-6);
    if (rx->cfg.start_now) {
        /* started at hand (F3b): line 0 begins at the first input sample */
        rx->state = S_RECEIVING;
        rx->cur.c = 0.0;
        rx->cur.g0 = 0;
    }
    return rx;
}

void wefax_rx_free(wefax_rx *rx) {
    if (!rx) return;
    fm_demod_free(&rx->dm);
    free(rx->tf); free(rx->ta); free(rx->tt);
    sbuf_free(&rx->st);
    free(rx->raw_tone); free(rx->raw_ratio);
    for (int i = 0; i < rx->nimg; i++) { free(rx->imgs[i].gray); sbuf_free(&rx->ret[i].buf); }
    free(rx->imgs); free(rx->ret); free(rx->ev);
    free(rx);
}

int wefax_rx_next_event(wefax_rx *rx, wefax_event *ev) {
    if (rx->evhead >= rx->evn) return 0;
    *ev = rx->ev[rx->evhead++];
    if (rx->evhead == rx->evn) rx->evhead = rx->evn = 0;   /* all read: the list does not grow for hours */
    return 1;
}

int wefax_rx_image_count(const wefax_rx *rx) { return rx->nimg; }
const wefax_image *wefax_rx_image(const wefax_rx *rx, int i) { return (i >= 0 && i < rx->nimg) ? &rx->imgs[i] : NULL; }

/* ---------------------------------------------------------------- raw tones (fldigi's plain tones) */

static void raw_block_done(wefax_rx *rx) {
    double n = (double)rx->r_cnt;
    double var = rx->r_sum2 / n - (rx->r_sum / n) * (rx->r_sum / n);
    int best = -1; double bestr = 0.0;
    for (int k = 0; k < NTONES; k++) {
        double p = rx->g_s1[k] * rx->g_s1[k] + rx->g_s2[k] * rx->g_s2[k] - rx->g_coef[k] * rx->g_s1[k] * rx->g_s2[k];
        double r = (var > 1e-20) ? 2.0 * p / (n * n) / var : 0.0;
        if (r > bestr) { bestr = r; best = k; }
        rx->g_s1[k] = rx->g_s2[k] = 0.0;
    }
    if (rx->nraw == rx->capraw) {
        size_t nc = rx->capraw ? rx->capraw * 2 : 1024;
        signed char *nt = realloc(rx->raw_tone, nc);
        float *nr = realloc(rx->raw_ratio, nc * sizeof(float));
        if (nt) rx->raw_tone = nt;
        if (nr) rx->raw_ratio = nr;
        if (!nt || !nr) { rx->r_sum = rx->r_sum2 = 0.0; rx->r_cnt = 0; return; }
        rx->capraw = nc;
    }
    rx->raw_tone[rx->nraw] = (signed char)((bestr > 0.6) ? best : -1);
    rx->raw_ratio[rx->nraw] = (float)bestr;
    rx->nraw++;
    rx->r_sum = rx->r_sum2 = 0.0; rx->r_cnt = 0;
}

static void raw_feed(wefax_rx *rx, const float *x, size_t n) {
    for (size_t i = 0; i < n; i++) {
        double v = x[i];
        for (int k = 0; k < NTONES; k++) {
            double s0 = v + rx->g_coef[k] * rx->g_s1[k] - rx->g_s2[k];
            rx->g_s2[k] = rx->g_s1[k]; rx->g_s1[k] = s0;
        }
        rx->r_sum += v; rx->r_sum2 += v * v; rx->r_cnt++;
        rx->raw_n++;
        if (rx->r_cnt == rx->Br) raw_block_done(rx);
    }
}

/* the plain tone heard around time t, or -1 */
static int raw_tone_at(const wefax_rx *rx, double t) {
    if (t < 0.0) return -1;
    size_t k = (size_t)(t * rx->fs / rx->Br);
    if (k >= rx->nraw) return -1;
    return rx->raw_tone[k];
}

/* ---------------------------------------------------------------- the alternation, on the stream */

static int stream_alt(const wefax_rx *rx, size_t i0, size_t n, double *amp_out) {
    const sample_buf *b = &rx->st;
    double fd = 1.0 / b->dt;
    double mean = 0.0, amp = 0.0;
    for (size_t i = 0; i < n; i++) { mean += b->f[i0 + i]; amp += b->a[i0 + i]; }
    mean /= (double)n; amp /= (double)n;
    *amp_out = amp;
    double var = 0.0;
    for (size_t i = 0; i < n; i++) { double d = b->f[i0 + i] - mean; var += d * d; }
    var /= (double)n;
    /* an alternation swings between black and white: at least half the deviation */
    if (sqrt(var) < 0.5 * rx->cfg.deviation_hz) return -1;
    int best = -1; double bestr = 0.0;
    for (int k = 0; k < NTONES; k++) {
        double w = 2.0 * M_PI * TONES[k] / fd, re = 0.0, im = 0.0;
        for (size_t i = 0; i < n; i++) {
            double d = b->f[i0 + i] - mean;
            re += d * cos(w * (double)i); im -= d * sin(w * (double)i);
        }
        double r = 2.0 * (re * re + im * im) / ((double)n * (double)n) / var;
        if (r > bestr) { bestr = r; best = k; }
    }
    return bestr > 0.45 ? best : -1;
}

/* The share of the samples in [i0, i0 + n) that fall outside the fax band (more than the
 * deviation + 200 Hz from the centre). A fax signal stays in the band, even at 0 dB of SNR or in a
 * fade (at most 0.35 in the channel of our tests); noise alone puts about 0.4 outside. */
static double out_of_band(const wefax_rx *rx, size_t i0, size_t n) {
    const sample_buf *b = &rx->st;
    if (n == 0) return 0.0;
    size_t out = 0;
    for (size_t i = i0; i < i0 + n && i < b->n; i++)
        if (fabs(b->f[i] - rx->cfg.center_hz) > rx->cfg.deviation_hz + 200.0) out++;
    return (double)out / (double)n;
}

/* ---------------------------------------------------------------- phasing */

/* Folded brightness profile over [ta, tb) at period T and origin c, PROFILE_BINS bins. */
static void fold(const sample_buf *b, double ta, double tb, double c, double T, double off, double dev, double fc, double *prof) {
    double cnt[PROFILE_BINS];
    for (int k = 0; k < PROFILE_BINS; k++) { prof[k] = 0.0; cnt[k] = 0.0; }
    size_t i0 = sbuf_index(b, ta), i1 = sbuf_index(b, tb);
    for (size_t i = i0; i < i1 && i < b->n; i++) {
        double t = sbuf_time(b, i);
        double ph = (t - c) / T;
        ph -= floor(ph);
        int k = (int)(ph * PROFILE_BINS);
        if (k >= PROFILE_BINS) k = PROFILE_BINS - 1;
        prof[k] += bright(b->f[i], off, dev, fc); cnt[k] += 1.0;
    }
    for (int k = 0; k < PROFILE_BINS; k++) prof[k] = cnt[k] > 0 ? prof[k] / cnt[k] : 0.0;
}

/* Is [te - 8 T, te) phasing at period T? Two levels, high contrast, and every line like the others.
 * *contrast (if given) gets the folded profile's range. */
static int phasing_window_T(const wefax_rx *rx, double te, double T, double *contrast) {
    const sample_buf *b = &rx->st;
    double ta = te - 8.0 * T;
    if (contrast) *contrast = 0.0;
    if (ta < sbuf_time(b, 0) || b->n == 0) return 0;
    double prof[PROFILE_BINS];
    fold(b, ta, te, 0.0, T, 0.0, rx->cfg.deviation_hz, rx->cfg.center_hz, prof);
    double lo = 1e9, hi = -1e9;
    for (int k = 0; k < PROFILE_BINS; k++) { if (prof[k] < lo) lo = prof[k]; if (prof[k] > hi) hi = prof[k]; }
    if (contrast) *contrast = hi - lo;
    if (hi - lo < 0.6) return 0;
    int mid_bins = 0, white = 0;
    for (int k = 0; k < PROFILE_BINS; k++) {
        double v = (prof[k] - lo) / (hi - lo);
        if (v > 0.25 && v < 0.75) mid_bins++;
        if (v >= 0.5) white++;
    }
    if (mid_bins > PROFILE_BINS * 15 / 100) return 0;
    if (white < 4 || white > PROFILE_BINS - 4) return 0;       /* both levels present */
    /* the lines close to the folded profile: all but two (a fade takes a line or two at a time) */
    int bad = 0;
    for (int l = 0; l < 8; l++) {
        double lp[PROFILE_BINS];
        fold(b, ta + l * T, ta + (l + 1) * T, 0.0, T, 0.0, rx->cfg.deviation_hz, rx->cfg.center_hz, lp);
        double mad = 0.0;
        for (int k = 0; k < PROFILE_BINS; k++) mad += fabs(lp[k] - prof[k]);
        if (mad / PROFILE_BINS > 0.12 && ++bad > 2) return 0;
    }
    return 1;
}

static int phasing_window(const wefax_rx *rx, double te) { return phasing_window_T(rx, te, rx->T0, NULL); }

/* Test 3.11: a phasing at another standard speed ([W] §5.1.5: 60, 90, 120, 240) than the one
 * chosen. Only when the chosen speed does not show it and the other one shows it much more
 * clearly: folded at twice its speed, a phasing in noise passes the window test with half its
 * contrast (F-4). Returns that speed, or 0. */
static double phasing_other_lpm(const wefax_rx *rx, double te) {
    static const double LPM[4] = { 60.0, 90.0, 120.0, 240.0 };
    double c_chosen;
    if (phasing_window_T(rx, te, rx->T0, &c_chosen)) return 0.0;
    for (int k = 0; k < 4; k++) {
        if (fabs(LPM[k] - rx->cfg.lpm) < 0.5) continue;
        double c_other;
        if (phasing_window_T(rx, te, 60.0 / LPM[k], &c_other) && c_other > c_chosen + 0.25) return LPM[k];
    }
    return 0.0;
}

/* The black and white levels of a phasing over [ta, tb), folded at period T: the median frequency
 * in every profile bin (a click or a burst of noise does not move a median), then two-means on
 * the bin medians, then the median of the bins of each plateau. Two-means on the raw samples of a
 * noisy 5/95 phasing does not separate its 5 % of white from the noise (F-1). */
static void two_levels(const sample_buf *b, double ta, double tb, double T, double *lo, double *hi) {
    size_t i0 = sbuf_index(b, ta), i1 = sbuf_index(b, tb);
    size_t n = i1 > i0 ? i1 - i0 : 0;
    double med[PROFILE_BINS];
    int cnt[PROFILE_BINS], off[PROFILE_BINS + 1], have = 0;
    for (int k = 0; k < PROFILE_BINS; k++) cnt[k] = 0;
    short *bin = malloc((n ? n : 1) * sizeof *bin);
    double *v = malloc((n ? n : 1) * sizeof *v);
    if (!bin || !v) { free(bin); free(v); *lo = *hi = 0.0; return; }
    for (size_t i = 0; i < n; i++) {
        double ph = (sbuf_time(b, i0 + i) - ta) / T;
        ph -= floor(ph);
        int k = (int)(ph * PROFILE_BINS);
        if (k >= PROFILE_BINS) k = PROFILE_BINS - 1;
        bin[i] = (short)k; cnt[k]++;
    }
    off[0] = 0;
    for (int k = 0; k < PROFILE_BINS; k++) off[k + 1] = off[k] + cnt[k];
    int fill[PROFILE_BINS];
    for (int k = 0; k < PROFILE_BINS; k++) fill[k] = off[k];
    for (size_t i = 0; i < n; i++) v[fill[bin[i]]++] = b->f[i0 + i];
    double a = 1e9, z = -1e9;
    for (int k = 0; k < PROFILE_BINS; k++) {
        if (!cnt[k]) continue;
        med[k] = median_d(v + off[k], cnt[k]);
        if (med[k] < a) a = med[k];
        if (med[k] > z) z = med[k];
        have++;
    }
    free(bin); free(v);
    if (!have) { *lo = *hi = 0.0; return; }
    double c0 = a, c1 = z;
    for (int it = 0; it < 20; it++) {
        double s0 = 0, s1 = 0; int n0 = 0, n1 = 0;
        double m = 0.5 * (c0 + c1);
        for (int k = 0; k < PROFILE_BINS; k++) {
            if (!cnt[k]) continue;
            if (med[k] < m) { s0 += med[k]; n0++; } else { s1 += med[k]; n1++; }
        }
        if (n0) c0 = s0 / n0;
        if (n1) c1 = s1 / n1;
    }
    /* the plateaus, not the edges: medians of the bins near each centre */
    double pl[PROFILE_BINS];
    int np = 0;
    double m = 0.5 * (c0 + c1), q = 0.25 * (c1 - c0);
    for (int k = 0; k < PROFILE_BINS; k++) if (cnt[k] && med[k] < m && fabs(med[k] - c0) < q) pl[np++] = med[k];
    if (np) c0 = median_d(pl, np);
    np = 0;
    for (int k = 0; k < PROFILE_BINS; k++) if (cnt[k] && med[k] >= m && fabs(med[k] - c1) < q) pl[np++] = med[k];
    if (np) c1 = median_d(pl, np);
    *lo = c0; *hi = c1;
}

/* Time where the 1 ms average of f crosses thr in the given direction, nearest to t_pred within
 * +-win; -1 if none. */
static double find_edge(const sample_buf *b, double t_pred, double win, double thr, int rising) {
    size_t i0 = sbuf_index(b, t_pred - win), i1 = sbuf_index(b, t_pred + win);
    if (i1 >= b->n) i1 = b->n - 1;
    int h = (int)lround(0.0005 / b->dt);
    double best = -1.0, bestd = 1e9, prev = 0.0;
    int have = 0;
    for (size_t i = i0; i <= i1; i++) {
        double acc = 0.0; int cnt = 0;
        for (int k = -h; k <= h; k++) {
            long j = (long)i + k;
            if (j < 0 || (size_t)j >= b->n) continue;
            acc += b->f[j]; cnt++;
        }
        double s = acc / cnt;
        if (have) {
            int cross = rising ? (prev < thr && s >= thr) : (prev >= thr && s < thr);
            if (cross) {
                double t = sbuf_time(b, i) - b->dt + (thr - prev) / (s - prev) * b->dt;
                if (fabs(t - t_pred) < bestd) { bestd = fabs(t - t_pred); best = t; }
            }
        }
        prev = s; have = 1;
    }
    return best;
}

/* Fit the edges of one kind across the phasing: c + n T. Returns the lines used. */
static int fit_edges(const sample_buf *b, double ta, double tb, double first, double T0, double thr, int rising,
                     double *c_out, double *T_out, double *rms_out) {
    int cap = 1024, m = 0;
    double *tn = malloc((size_t)cap * sizeof(double)), *nn = malloc((size_t)cap * sizeof(double));
    double *org = malloc((size_t)cap * sizeof(double));
    if (!tn || !nn || !org) { free(tn); free(nn); free(org); return 0; }
    double c = first, T = T0;
    int miss = 0;
    for (int n = 0; ; n++) {
        double tp = c + T * n;
        if (tp > tb) break;
        if (tp < ta) continue;
        double te = find_edge(b, tp, (m < 4 ? 0.04 : 0.01) * T0, thr, rising);
        if (te < 0.0) { if (++miss > 8) break; continue; }
        if (m == cap) break;
        tn[m] = te; nn[m] = n; m++;
        /* the line through the edges: with few of them, the median origin at the nominal period; then
           least squares over the edges within 3 ms of it. A median does not follow one odd edge, and
           least squares does (fldigi's first phasing pulse is half a pulse: its leading edge comes
           12.5 ms early) */
        if (m < 6) {
            for (int i = 0; i < m; i++) org[i] = tn[i] - T0 * nn[i];
            c = median_d(org, m);
            T = T0;
        } else {
            double sn = 0, st = 0, snn = 0, snt = 0; int k = 0;
            for (int i = 0; i < m; i++) {
                if (fabs(tn[i] - (c + T * nn[i])) > 0.003) continue;
                sn += nn[i]; st += tn[i]; snn += nn[i] * nn[i]; snt += nn[i] * tn[i]; k++;
            }
            double den = k * snn - sn * sn;
            if (k >= 3 && den > 0) { T = (k * snt - sn * st) / den; c = (st - T * sn) / k; }
        }
    }
    /* reject outliers once, refit */
    double rms = 0.0;
    if (m >= 3) {
        double *r = malloc((size_t)m * sizeof(double));
        if (r) {
            for (int i = 0; i < m; i++) r[i] = fabs(tn[i] - (c + T * nn[i]));
            double *rs = malloc((size_t)m * sizeof(double));
            if (rs) {
                memcpy(rs, r, (size_t)m * sizeof(double));
                double mad = median_d(rs, m);
                free(rs);
                double lim = fmax(2e-4, 5.0 * 1.4826 * mad);
                double sn = 0, st = 0, snn = 0, snt = 0; int k = 0;
                for (int i = 0; i < m; i++) if (r[i] <= lim) { sn += nn[i]; st += tn[i]; snn += nn[i] * nn[i]; snt += nn[i] * tn[i]; k++; }
                double den = k * snn - sn * sn;
                if (k >= 3 && den > 0) { T = (k * snt - sn * st) / den; c = (st - T * sn) / k; m = k; }
                for (int i = 0; i < m; i++) { double d = tn[i] - (c + T * nn[i]); rms += d * d; }
                rms = sqrt(rms / m);
            }
            free(r);
        }
    }
    free(tn); free(nn); free(org);
    *c_out = c; *T_out = T; *rms_out = rms;
    return m;
}

/* Does line g of p look like the phasing line kept in rx->tmpl? Its pulse (the shorter level,
 * either one in a symmetric phasing) and the rest must both match: on the mean difference alone,
 * a white picture row matches an inverted phasing (95 % white) and would be taken for one. */
static int line_is_phasing(const wefax_rx *rx, const fax_params *p, int g) {
    double lp[PROFILE_BINS];
    fold(&rx->st, p->c + g * p->T, p->c + (g + 1) * p->T, p->c, p->T, p->off, p->dev, rx->cfg.center_hz, lp);
    int white = 0;
    for (int k = 0; k < PROFILE_BINS; k++) if (rx->tmpl[k] >= 0.5) white++;
    int pulse_white = (white <= PROFILE_BINS / 2);
    double sp = 0, sr = 0; int np = 0, nr = 0;
    for (int k = 0; k < PROFILE_BINS; k++) {
        double d = fabs(lp[k] - rx->tmpl[k]);
        if ((rx->tmpl[k] >= 0.5) == pulse_white) { sp += d; np++; } else { sr += d; nr++; }
    }
    if (np == 0 || nr == 0) return 0;
    return sp / np <= 0.3 && sr / nr <= 0.15;
}

/* The phasing just seen, over [ph_a, ph_b). What it says (tuning, speed, line start) is applied
 * only if it makes sense (F-1): a mistuning within half the deviation (the automatic tuning range,
 * [J] p. 17), a measured deviation within half of the chosen one either way, and edges on 8 lines
 * or more. Returns 1 if applied, 0 if not (the caller then receives without phasing). */
static int analyse_phasing(wefax_rx *rx, double te_now) {
    sample_buf *b = &rx->st;
    double fc = rx->cfg.center_hz, dev = rx->cfg.deviation_hz;
    double lo, hi;
    double t16 = rx->ph_a + 16.0 * rx->T0 < rx->ph_b ? rx->ph_a + 16.0 * rx->T0 : rx->ph_b;
    two_levels(b, rx->ph_a, t16, rx->T0, &lo, &hi);
    double mid = 0.5 * (lo + hi);
    rx->dev_meas = 0.5 * (hi - lo);
    char tx[200];
    int sane = fabs(mid - fc) <= 0.5 * dev && rx->dev_meas >= 0.5 * dev && rx->dev_meas <= 1.5 * dev;
    /* the duty cycle and the coarse edges, on the folded profile */
    /* on the first 8 lines only, so that a clock offset does not smear the edges */
    double prof[PROFILE_BINS];
    double tcoarse = rx->ph_a + 8.0 * rx->T0 < rx->ph_b ? rx->ph_a + 8.0 * rx->T0 : rx->ph_b;
    fold(b, rx->ph_a, tcoarse, 0.0, rx->T0, mid - fc, dev, fc, prof);
    int white = 0, kr = -1, kf = -1;
    for (int k = 0; k < PROFILE_BINS; k++) {
        if (prof[k] >= 0.5) white++;
        int kp = (k + PROFILE_BINS - 1) % PROFILE_BINS;
        if (prof[kp] < 0.5 && prof[k] >= 0.5) kr = k;
        if (prof[kp] >= 0.5 && prof[k] < 0.5) kf = k;
    }
    double duty = (double)white / PROFILE_BINS;
    double first_r = (kr + 0.5) / PROFILE_BINS * rx->T0, first_f = (kf + 0.5) / PROFILE_BINS * rx->T0;
    /* go back to the first whole line inside the phasing */
    first_r += ceil((rx->ph_a - first_r) / rx->T0) * rx->T0;
    first_f += ceil((rx->ph_a - first_f) / rx->T0) * rx->T0;
    double cr = 0, Tr = rx->T0, rr = 0, cf = 0, Tf = rx->T0, rf = 0;
    int nr = (sane && kr >= 0) ? fit_edges(b, rx->ph_a, rx->ph_b, first_r, rx->T0, mid, 1, &cr, &Tr, &rr) : 0;
    int nf = (sane && kf >= 0) ? fit_edges(b, rx->ph_a, rx->ph_b, first_f, rx->T0, mid, 0, &cf, &Tf, &rf) : 0;
    int inverted = 0, kind = 1, symmetric = 0;
    if (duty < 0.3) { kind = 1; inverted = 0; }                      /* 5/95: short white */
    else if (duty > 0.7) { kind = 1; inverted = 1; }                 /* 5/95 inverted: short black */
    else { kind = 2; inverted = 0; symmetric = 1; }
    double c, T;
    int nused;
    if (!inverted) { c = cr; T = Tr; nused = nr; } else { c = cf; T = Tf; nused = nf; }
    if (nused < 3) {
        /* fall back to the other edge */
        if (inverted) { c = cr; T = Tr; nused = nr; } else { c = cf; T = Tf; nused = nf; }
    }
    if (!sane || nused < 8) {
        snprintf(tx, sizeof tx, "Fase poc fiable (desintonia %+.0f Hz, desviació mesurada %.0f Hz, vores a %d línies): "
                 "es mantenen la sintonia i el ritme triats, i el marge no es coneix", mid - fc, rx->dev_meas, nused);
        push_note(rx, WEFAX_NOTE_PHASING_UNRELIABLE, rx->ph_b, 0, -1, tx);
        rx->cur.off = 0.0;
        rx->cur.dev = dev;
        return 0;
    }
    if (fabs(T / rx->T0 - 1.0) > 0.01) T = rx->T0;                   /* nonsense: keep nominal */
    rx->cur.off = rx->cfg.auto_tune ? mid - fc : 0.0;
    rx->cur.dev = dev;
    rx->phasing_kind = kind;
    rx->symmetric_pending = symmetric;
    if (symmetric) rx->c_alt = cf;
    /* TC-1: no source says which edge an inverted 5/95 phasing (95 % white) marks the line start
       with: ours is the start of the short black; the other is the start of the white, 5 % later.
       The dead sector decides, as with the symmetric one */
    rx->inverted_pending = inverted;
    if (inverted) rx->c_alt = cr;
    rx->phasing_inv = inverted;
    rx->phasing_lines = nused;
    rx->have_phasing = 1;
    rx->margin_source = 1;
    rx->cur.T = T;
    /* the line origin near the phasing's last line */
    int gb = (int)floor((rx->ph_b - c) / T);
    rx->cur.c = c;
    /* the picture starts at the first line, after the phasing, that no longer looks like it */
    fold(b, rx->ph_a, rx->ph_b, c, T, rx->cur.off, rx->cur.dev, fc, rx->tmpl);
    /* from 3 lines before the one the phasing's last window falls in: that window can land a line late
       (at 44 100 Hz it did, and the chart lost its first line: N2-fax-app-1); a phasing line taken for the
       first of the chart is skipped again in finish_picture */
    int g0 = gb + 1;
    for (int g = gb - 3; g <= gb + 6; g++) {
        if (c + (g + 1) * T > te_now) { g0 = g; break; }
        if (!line_is_phasing(rx, &rx->cur, g)) { g0 = g; break; }
        g0 = g + 1;
    }
    rx->cur.g0 = g0;
    snprintf(tx, sizeof tx, "Fase %s%s: %d línies, període %.4f ms, desintonia %+.1f Hz, desviació mesurada %.0f Hz",
             kind == 2 ? "simètrica" : "5/95", inverted ? " invertida" : "",
             nused, T * 1e3, mid - fc, rx->dev_meas);
    push_ev(rx, WEFAX_EV_PHASING, c + g0 * T, T * 1e3, 0, -1, tx);
    /* TC-2: the levels are drawn with the chosen deviation; say so when the station's differs. Only
       with a clean phasing: noise pulls the measured deviation down (-2.5 % at +10 dB, -15 % at +3) */
    size_t pa = sbuf_index(b, rx->ph_a), pb = sbuf_index(b, rx->ph_b);
    if (out_of_band(rx, pa, pb > pa ? pb - pa : 0) < 0.08 && fabs(rx->dev_meas - dev) > 20.0) {
        snprintf(tx, sizeof tx, "Desviació mesurada a la fase: %.0f Hz; la triada és %.0f Hz: els grisos poden sortir "
                 "desplaçats (tria la desviació de l'emissora)", rx->dev_meas, dev);
        push_note(rx, WEFAX_NOTE_DEVIATION_DIFFERS, c + g0 * T, rx->dev_meas, -1, tx);
    }
    return 1;
}

/* ---------------------------------------------------------------- rendering */

static void render_float(const sample_buf *b, const fax_params *p, double fc, float *out) {
    for (int n = 0; n < p->lines; n++) {
        double t0 = p->c + (double)(p->g0 + n) * p->T;
        double px = p->T / p->W;
        for (int j = 0; j < p->W; j++) {
            double f = sbuf_mean(b, t0 + j * px, t0 + (j + 1) * px);
            out[(size_t)n * p->W + j] = (float)bright(f, p->off, p->dev, fc);
        }
    }
}

/* Drift of the picture content, in pixels per line, by cross-correlating 4-line averages that are
 * dist lines apart, within +-R pixels. Returns the number of pairs used. */
static int picture_drift(const float *img, int W, int L, int dist, int R, double *drift) {
    if (L < dist + 8) return 0;
    float *a = malloc((size_t)W * sizeof(float)), *z = malloc((size_t)W * sizeof(float));
    double *sh = malloc((size_t)(L / 4 + 1) * sizeof(double));
    double *cc = malloc((size_t)(2 * R + 1) * sizeof(double));
    if (!a || !z || !sh || !cc) { free(a); free(z); free(sh); free(cc); return 0; }
    int ns = 0;
    for (int n0 = 0; n0 + dist + 4 <= L; n0 += 4) {
        for (int pass = 0; pass < 2; pass++) {
            float *v = pass ? z : a;
            int base = n0 + (pass ? dist : 0);
            for (int j = 0; j < W; j++) {
                double s = 0;
                for (int k = 0; k < 4; k++) s += img[(size_t)(base + k) * W + j];
                v[j] = (float)(s / 4.0);
            }
            /* high-pass: minus a 15-pixel circular moving average */
            double run = 0;
            float *tmp = malloc((size_t)W * sizeof(float));
            if (!tmp) continue;
            for (int k = -7; k <= 7; k++) run += v[(k + W) % W];
            for (int j = 0; j < W; j++) {
                tmp[j] = (float)(v[j] - run / 15.0);
                run += v[(j + 8) % W] - v[(j - 7 + W) % W];
            }
            memcpy(v, tmp, (size_t)W * sizeof(float));
            free(tmp);
        }
        double ea = 0, ez = 0;
        for (int j = 0; j < W; j++) { ea += a[j] * a[j]; ez += z[j] * z[j]; }
        if (ea < 1e-6 * W || ez < 1e-6 * W) continue;
        int bk = 0; double bv = -1e300;
        for (int s = -R; s <= R; s++) {
            double acc = 0;
            for (int j = 0; j < W; j++) acc += a[j] * z[(j + s + W) % W];
            cc[s + R] = acc;
            if (acc > bv) { bv = acc; bk = s; }
        }
        if (bv / sqrt(ea * ez) < 0.3) continue;                   /* no clear match */
        if (bk == -R || bk == R) continue;                         /* at the edge of the search */
        double y0 = cc[bk + R - 1], y1 = cc[bk + R], y2 = cc[bk + R + 1];
        double den = y0 - 2 * y1 + y2;
        double frac = (fabs(den) > 1e-12) ? 0.5 * (y0 - y2) / den : 0.0;
        sh[ns++] = (bk + frac) / dist;
    }
    if (ns >= 8) *drift = median_d(sh, ns);
    free(a); free(z); free(sh); free(cc);
    return ns >= 8 ? ns : 0;
}

/* Where is the dead sector? The brightest band of 4.5 % of the line in the mean column profile.
 * Returns the column, or -1 if there is no clear band. */
static int dead_sector(const float *img, int W, int L) {
    if (L < 8) return -1;
    double *col = calloc((size_t)W, sizeof(double));
    if (!col) return -1;
    for (int n = 0; n < L; n++) for (int j = 0; j < W; j++) col[j] += img[(size_t)n * W + j];
    for (int j = 0; j < W; j++) col[j] /= L;
    int w = (int)lround(0.045 * W);
    int best = -1; double bs = -1e9;
    for (int x0 = 0; x0 < W; x0++) {
        double in = 0, out = 0;
        for (int k = 0; k < w; k++) in += col[(x0 + k) % W];
        for (int k = 1; k <= w; k++) out += col[(x0 + W - k) % W] + col[(x0 + w - 1 + k) % W];
        double s = in / w - out / (2 * w);
        if (s > bs) { bs = s; best = x0; }
    }
    free(col);
    return bs > 0.25 ? best : -1;
}

/* Where does each line really begin, according to the picture itself? At that column, a
 * horizontal feature that runs off the right-hand edge of one line comes back on the next row:
 * the pixel just before it in time is one row lower. So at the true line start, a pixel matches
 * the one at its left on the row below better than the one at its left on the same row; elsewhere
 * it is the other way round. Pixels up to 20 columns apart are compared, to step over a black
 * frame. Returns the column, or -1 if no column stands out. The idea is from our own
 * corregeix_wefax.py (08-10-2026), written again here. */
static int seam_column(const float *img, int W, int L, double *strength) {
    *strength = 0.0;
    if (L < 16 || W < 64) return -1;
    static const int K[6] = { 0, 4, 8, 12, 16, 20 };
    double *sc = malloc((size_t)W * sizeof(double));
    if (!sc) return -1;
    for (int x = 0; x < W; x++) {
        double acc = 0.0;
        for (int y = 0; y + 1 < L; y++) {
            const float *r0 = img + (size_t)y * W, *r1 = img + (size_t)(y + 1) * W;
            for (int q = 0; q < 6; q++) {
                int xr = (x + K[q]) % W, xl = (x - 1 - K[q] + 2 * W) % W;
                acc += fabs(r0[xr] - r0[xl]) - fabs(r0[xr] - r1[xl]);
            }
        }
        sc[x] = acc / (6.0 * (L - 1));
    }
    int best = 0;
    for (int x = 1; x < W; x++) if (sc[x] > sc[best]) best = x;
    /* the peak is about 20 columns wide (the comparisons reach 20 columns): look for a rival
       further away than 25 */
    double second = -1e9;
    for (int x = 0; x < W; x++) {
        int d = abs(x - best); if (d > W / 2) d = W - d;
        if (d > 25 && sc[x] > second) second = sc[x];
    }
    double peak = sc[best];
    free(sc);
    *strength = (second > 0.0) ? peak / second : 99.0;
    /* elsewhere the score is negative (horizontal features continue on the same row); the true
       start is the one clearly positive place, and alone */
    if (peak > 0.006 && second < 0.3 * peak) return best;
    return -1;
}

static double mean_cols(const float *img, int W, int L, int x0, int w) {
    double s = 0; int n = 0;
    for (int r = 0; r < L; r++) for (int k = 0; k < w; k++) { s += img[(size_t)r * W + (x0 + k) % W]; n++; }
    return n ? s / n : 0.0;
}

static void finish_picture(wefax_rx *rx, double t_end, int complete, wefax_note why_note, const char *why) {
    sample_buf *b = &rx->st;
    double fc = rx->cfg.center_hz;
    rx->margin_seam_px = 0;                  /* each chart its own: never the seam of the one before (NUC-9) */
    /* phasing lines that a long bad stretch cut off from the phasing still come before the
       picture: skip them (F-3); the buffer still has them */
    if (rx->have_phasing && rx->margin_source == 1) {
        /* the last phasing line before 8 lines in a row that are not (a fade can take a few) */
        int last = rx->cur.g0 - 1;
        for (int g = rx->cur.g0; g < rx->cur.g0 + 80 && g - last <= 8; g++) {
            if (rx->cur.c + (g + 2) * rx->cur.T > t_end) break;
            if (line_is_phasing(rx, &rx->cur, g)) last = g;
        }
        rx->cur.g0 = last + 1;
    }
    fax_params p = rx->cur;
    p.W = rx->W;
    p.flip = rx->cfg.flip;
    p.c += rx->cfg.preset_offset_ms * 1e-3;
    double t_first = p.c + p.g0 * p.T;
    int L = (int)floor((t_end - t_first) / p.T + 2.0 / p.W);
    if (L > (int)rx->cfg.max_lines) L = (int)rx->cfg.max_lines;
    rx->state = S_IDLE;
    char tx[160];
    if (L <= 0) {
        snprintf(tx, sizeof tx, "Fax sense cap línia d'imatge (%s): no es desa res", why);
        push_note(rx, WEFAX_NOTE_NO_LINES, t_end, 0, -1, tx);
        rx->nlost = 0; rx->lost_open = 0;
        return;
    }
    p.lines = L;
    float *img = malloc((size_t)p.W * L * sizeof(float));
    if (!img) { push_note(rx, WEFAX_NOTE_NO_MEMORY, t_end, 0, -1, "Fax: sense memòria per a la imatge"); rx->nlost = 0; rx->lost_open = 0; return; }
    double T_start = p.T;
    render_float(b, &p, fc, img);
    /* the slant, refined on the picture itself (A19, lesson L2): a coarse pass, then a fine one */
    if (rx->cfg.fit_slant && L >= 48) {
        /* the anchor stays where it was measured: the middle of the phasing, or the first line */
        double ga = (rx->margin_source == 1) ? 0.5 * rx->phasing_lines : (double)p.g0;
        double d1 = 0;
        if (picture_drift(img, p.W, L, 8, 24, &d1) && fabs(d1) > 0.02) {
            double Tn = p.T * (1.0 + d1 / p.W);
            p.c += ga * (p.T - Tn);
            p.T = Tn;
            render_float(b, &p, fc, img);
        }
        int dist = L / 2 < 256 ? L / 2 : 256;
        double d2 = 0;
        if (dist >= 16 && picture_drift(img, p.W, L, dist, 8, &d2) && fabs(d2 * L) > 0.25) {
            double Tn = p.T * (1.0 + d2 / p.W);
            p.c += ga * (p.T - Tn);
            p.T = Tn;
            render_float(b, &p, fc, img);
        }
    }
    /* symmetric phasing: the polarity is not in the phasing; the dead sector at the start of the
       picture lines decides (it is mostly white, [W] §5.1.3.3). An inverted 5/95 one: which edge
       starts the line has no source (TC-1), and the dead sector decides too */
    if (rx->have_phasing && (rx->symmetric_pending || rx->inverted_pending)) {
        int w = (int)lround(0.04 * p.W);
        double a = mean_cols(img, p.W, L, 0, w);
        /* the other candidate is half a line away */
        double other_c = rx->c_alt + rx->cfg.preset_offset_ms * 1e-3;
        double k = round((p.c - other_c) / p.T);
        double x_other = (other_c + k * p.T - p.c) / p.T * p.W;
        int xo = (int)lround(fmod(fmod(x_other, p.W) + p.W, p.W));
        double z = mean_cols(img, p.W, L, xo, w);
        if (z > a + 0.1) {
            p.c += (double)xo / p.W * p.T;
            if (xo > p.W / 2) p.c -= p.T;
            if (rx->symmetric_pending) rx->phasing_inv = 1;
            else push_note(rx, WEFAX_NOTE_INVERTED_WHITE_FIRST, t_first, 0, -1,
                           "Fase invertida: el sector mort diu que la línia comença al blanc, no al negre; s'hi posa el marge");
            render_float(b, &p, fc, img);
        } else if (!(a > z + 0.1)) {
            push_note(rx, rx->symmetric_pending ? WEFAX_NOTE_POLARITY_UNDECIDED : WEFAX_NOTE_INVERTED_UNDECIDED, t_first, 0, -1, rx->symmetric_pending ?
                    "Fase simètrica: el sector mort no decideix la polaritat; es pren la normal" :
                    "Fase invertida: el sector mort no decideix el flanc; es pren el del negre (convenció nostra, sense font)");
        }
    }
    /* the margin, in this order: the phasing ([W] §5.2.3.4); else the dead sector, the white band
       at the start of every line ([W] §5.1.3.3), also when started at hand; else the picture's own
       seam. With a phasing, a dead sector right at column 0 confirms it; with no dead sector at all,
       the seam may still show that the sender starts its lines elsewhere (fldigi 4.2.13 starts
       them in the middle of its phasing pulse, 12.5 ms after the edge [W] names: test F1) */
    int x0 = dead_sector(img, p.W, L);
    int xd = (x0 > p.W / 2) ? x0 - p.W : x0;
    if (!rx->have_phasing && x0 >= 0) {
        p.c += (double)xd / p.W * p.T;
        rx->margin_source = 2;
        render_float(b, &p, fc, img);
    } else if (rx->have_phasing && x0 >= 0 && abs(xd) > 3) {
        char tx2[160];
        snprintf(tx2, sizeof tx2, "El sector mort no és on diu la fase: %+d punts. Es manté la fase", xd);
        push_note(rx, WEFAX_NOTE_DEAD_SECTOR_ELSEWHERE, t_first, (double)xd, -1, tx2);
    }
    /* fldigi's line start, when chosen: the middle of its phasing band, 2.5 % of a line after the edge */
    if (rx->have_phasing && rx->cfg.line_start == WEFAX_LINE_START_FLDIGI) {
        p.c += 0.025 * p.T;
        rx->margin_source = 4;
        render_float(b, &p, fc, img);
    }
    if (x0 < 0) {
        double strength;
        int sx = seam_column(img, p.W, L, &strength);
        int sd = (sx > p.W / 2) ? sx - p.W : sx;
        /* the standard by default (A22): the seam only says what it sees; it moves the margin only
           when Auto-align is chosen. A seam 2.5 % of a line after the phasing edge is fldigi's way */
        int fl = (int)lround(0.025 * p.W);
        if (sx >= 0 && rx->have_phasing && rx->cfg.line_start == WEFAX_LINE_START_STANDARD && abs(sd - fl) <= 3) {
            char tx2[200];
            snprintf(tx2, sizeof tx2, "Les línies comencen %+d punts després del flanc de la fase, com les de fldigi (el mig de "
                     "la banda de fase): es manté la norma; es pot triar «fldigi» o «Auto-align»", sd);
            push_note(rx, WEFAX_NOTE_FLDIGI_STYLE, t_first, (double)sd, -1, tx2);
            rx->fldigi_style_seen = 1;
        }
        if (sx >= 0 && abs(sd) > 2 && rx->cfg.line_start == WEFAX_LINE_START_AUTO) {
            char tx2[160];
            snprintf(tx2, sizeof tx2, "Marge per la costura de la imatge: %+d punts respecte de %s (força %.0f)",
                     sd, rx->margin_source == 1 ? "la fase" : "l'inici", strength);
            push_note(rx, WEFAX_NOTE_SEAM_MARGIN, t_first, (double)sd, -1, tx2);
            p.c += (double)sd / p.W * p.T;
            rx->margin_seam_px = sd;
            rx->margin_source = 3;
            render_float(b, &p, fc, img);
        } else if (sx >= 0 && rx->cfg.line_start == WEFAX_LINE_START_AUTO) {
            /* a clear seam within 2 points of the start: it confirms it (N3-fax-app-1) */
            char tx2[160];
            snprintf(tx2, sizeof tx2, "La costura de la imatge confirma l'inici de línia (%+d punts respecte de %s, força %.0f)",
                     sd, rx->margin_source == 1 ? "la fase" : "l'inici", strength);
            push_note(rx, WEFAX_NOTE_SEAM_CONFIRMS, t_first, (double)sd, -1, tx2);
            if (!rx->have_phasing) { rx->margin_seam_px = 0; rx->margin_source = 3; }
        } else if (!rx->have_phasing) {
            /* the hint to choose Auto-align only when it is not the choice already (NUC-10) */
            push_note(rx, WEFAX_NOTE_MARGIN_UNKNOWN, t_first, 0, -1, rx->cfg.line_start == WEFAX_LINE_START_AUTO
                      ? "Fax sense fase ni sector mort, i la costura de la imatge no diu on comença la línia: el marge no es coneix; "
                        "es pot corregir després"
                      : "Fax sense fase ni sector mort: el marge no es coneix; es pot corregir després (o triar «Auto-align»)");
        }
    }
    if (rx->nimg == rx->capimg) {
        int nc = rx->capimg ? rx->capimg * 2 : 4;
        wefax_image *ni = realloc(rx->imgs, (size_t)nc * sizeof *ni);
        fax_retained *nr = ni ? realloc(rx->ret, (size_t)nc * sizeof *nr) : NULL;
        if (ni) rx->imgs = ni;
        if (nr) rx->ret = nr;
        if (!ni || !nr) { free(img); return; }
        rx->capimg = nc;
    }
    wefax_image *im = &rx->imgs[rx->nimg];
    fax_retained *rt = &rx->ret[rx->nimg];
    memset(im, 0, sizeof *im);
    memset(rt, 0, sizeof *rt);
    /* the lines inside the cuts: in their place, grey */
    for (int k = 0; k < rx->nlost && rt->nlost < 64; k++) {
        int r0 = (int)floor((rx->lost_a[k] - t_first) / p.T), r1 = (int)ceil((rx->lost_b[k] - t_first) / p.T);
        if (r0 < 0) r0 = 0;
        if (r1 > L) r1 = L;
        if (r1 <= r0) continue;
        rt->lost_r0[rt->nlost] = r0; rt->lost_r1[rt->nlost] = r1; rt->nlost++;
        im->lost_lines += r1 - r0;
        for (int n = r0; n < r1; n++) for (int j = 0; j < p.W; j++) img[(size_t)n * p.W + j] = 0.5f;
    }
    rx->nlost = 0; rx->lost_open = 0;
    im->width = p.W; im->height = L; im->rows_received = L; im->complete = complete;
    im->gray = malloc((size_t)p.W * L);
    if (!im->gray) { free(img); return; }
    for (int n = 0; n < L; n++) {
        int r = p.flip ? L - 1 - n : n;
        for (int j = 0; j < p.W; j++) {
            double v = img[(size_t)n * p.W + j] * 255.0;
            im->gray[(size_t)r * p.W + j] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v + 0.5);
        }
    }
    free(img);
    im->line_period_s = p.T;
    im->slant_ppm = (p.T / rx->T0 - 1.0) * 1e6;
    im->slant_refined_ppm = (p.T / T_start - 1.0) * 1e6;
    im->t_first_line = p.c + p.g0 * p.T;
    im->phasing_found = rx->have_phasing ? rx->phasing_kind : 0;
    im->phasing_inverted = rx->phasing_inv;
    im->phasing_lines = rx->phasing_lines;
    im->offset_hz = p.off;
    im->deviation_measured_hz = rx->dev_meas;
    im->margin_source = rx->margin_source;
    im->margin_seam_px = rx->margin_seam_px;
    im->fldigi_style_seen = rx->fldigi_style_seen;
    rx->fldigi_style_seen = 0;
    if (rx->cfg.keep_buffers) {
        double ta = im->t_first_line - 0.5, tb = im->t_first_line + (L + 1) * p.T;
        size_t i0 = sbuf_index(b, ta), i1 = sbuf_index(b, tb);
        rt->buf.dt = b->dt; rt->buf.t0 = b->t0; rt->buf.t0_set = 1; rt->buf.base = b->base + i0;
        for (size_t i = i0; i < i1 && i < b->n; i++) sbuf_push(&rt->buf, b->f[i], b->a[i], 0.0);
        rt->p = p;
        rt->valid = 1;
        im->retained = 1;
    }
    snprintf(tx, sizeof tx, "Fax: %d línies de %d punts%s; %.4f ms per línia (%+.1f ppm); marge: %s",
             L, p.W, complete ? "" : " (incompleta)", p.T * 1e3, im->slant_ppm,
             rx->margin_source == 1 ? "fase" : rx->margin_source == 2 ? "sector mort" :
             rx->margin_source == 3 ? "costura de la imatge" : "sense referència");
    push_ev(rx, WEFAX_EV_IMAGE, im->t_first_line, (double)L, 0, rx->nimg, tx);
    if (!complete) {
        snprintf(tx, sizeof tx, "Imatge desada com a incompleta: %s", why);
        push_note(rx, why_note ? why_note : WEFAX_NOTE_INCOMPLETE, t_end, 0, rx->nimg, tx);
    }
    rx->nimg++;
}

int wefax_rx_rerender(wefax_rx *rx, int index, double extra_slant_ppm, double offset_ms) {
    if (index < 0 || index >= rx->nimg || !rx->ret[index].valid || !rx->imgs[index].gray) return -1;
    fax_retained *rt = &rx->ret[index];
    wefax_image *im = &rx->imgs[index];
    fax_params p = rt->p;
    double t_first = p.c + p.g0 * p.T;
    p.T *= 1.0 + extra_slant_ppm * 1e-6;
    p.c = t_first - p.g0 * p.T + offset_ms * 1e-3;
    float *img = malloc((size_t)p.W * p.lines * sizeof(float));
    if (!img) return -1;
    render_float(&rt->buf, &p, rx->cfg.center_hz, img);
    for (int k = 0; k < rt->nlost; k++)
        for (int n = rt->lost_r0[k]; n < rt->lost_r1[k] && n < p.lines; n++) for (int j = 0; j < p.W; j++) img[(size_t)n * p.W + j] = 0.5f;
    for (int n = 0; n < p.lines; n++) {
        int r = p.flip ? p.lines - 1 - n : n;
        for (int j = 0; j < p.W; j++) {
            double v = img[(size_t)n * p.W + j] * 255.0;
            im->gray[(size_t)r * p.W + j] = (uint8_t)(v < 0 ? 0 : v > 255 ? 255 : v + 0.5);
        }
    }
    free(img);
    im->line_period_s = p.T;
    im->slant_ppm = (p.T / rx->T0 - 1.0) * 1e6;
    im->t_first_line = p.c + p.g0 * p.T;
    return 0;
}

void wefax_rx_drop_pixels(wefax_rx *rx, int index) {
    if (index < 0 || index >= rx->nimg) return;
    wefax_rx_accept(rx, index);
    free(rx->imgs[index].gray);
    rx->imgs[index].gray = NULL;
}

void wefax_rx_accept(wefax_rx *rx, int index) {
    if (index < 0 || index >= rx->nimg) return;
    sbuf_free(&rx->ret[index].buf);
    rx->ret[index].valid = 0;
    rx->imgs[index].retained = 0;
}

/* ---------------------------------------------------------------- the block clock */

static void begin_receiving_without_phasing(wefax_rx *rx, double t_line0) {
    rx->state = S_RECEIVING;
    rx->have_phasing = 0;
    rx->margin_source = 0;
    rx->cur.c = t_line0;
    rx->cur.g0 = 0;
    rx->cur.T = rx->T0 * (1.0 + rx->cfg.preset_slant_ppm * 1e-6);
    rx->amp_ref = 0; rx->amp_ref_n = 0; rx->loss_run = 0;
}

/* The start of the stop signal, to the stream sample: the first 5 ms window, from 0.2 s before
 * the first stop block, where the 450 Hz alternation (or, for a plain tone, the drop of the
 * in-band signal) has begun. */
static double refine_stop(wefax_rx *rx, double t_blk, int plain) {
    sample_buf *b = &rx->st;
    double fd = 1.0 / b->dt, w = 2.0 * M_PI * 450.0 / fd;
    double win = plain ? 0.002 : 0.005;
    int n = (int)lround(win / b->dt);
    if (n < 4) n = 4;
    for (double t = t_blk - 0.2; t < t_blk + 0.1; t += 0.00025) {
        size_t i0 = sbuf_index(b, t);
        if (i0 + (size_t)n > b->n) break;
        if (plain) {
            /* a plain tone is outside the band: the in-band signal drops */
            double amp = 0;
            for (int i = 0; i < n; i++) amp += b->a[i0 + i];
            if (amp / n < 0.5 * rx->amp_ref) return t + 0.5 * n * b->dt;
        } else {
            double mean = 0, var = 0, re = 0, im = 0;
            for (int i = 0; i < n; i++) mean += b->f[i0 + i];
            mean /= n;
            for (int i = 0; i < n; i++) {
                double d = b->f[i0 + i] - mean;
                var += d * d; re += d * cos(w * i); im -= d * sin(w * i);
            }
            if (var / n > 0.25 * rx->cfg.deviation_hz * rx->cfg.deviation_hz &&
                2.0 * (re * re + im * im) / ((double)n * n) / (var / n) > 0.5)
                return t + 0.5 * n * b->dt;            /* the middle of the first window that shows it */
        }
    }
    return t_blk;
}

/* A chart closed by the line limit: what follows may be more of the same chart, and its straight
 * lines can look like a phasing (F-09). Until a start or a stop signal, only a clear phasing starts
 * the next chart: a normal 5/95 or a symmetric one, of 20 lines or more (after a
 * chart with no stop, a new phasing is accepted). Said, never silent (L4). */
static void strict_phasing(wefax_rx *rx, double t) {
    rx->ph_strict = 1;
    push_note(rx, WEFAX_NOTE_PHASING_STRICT, t, 0, -1, "Carta tancada al límit de línies: fins al pròxim senyal d'inici o de "
              "parada, només una fase clara (5/95 normal o simètrica, de 20 línies o més) comença la carta següent");
}

/* the folded phasing window: the share of white, and its two levels (0 black, 1 white) */
static double window_duty(const wefax_rx *rx, double te, double *lo_out, double *hi_out) {
    double prof[PROFILE_BINS];
    fold(&rx->st, te - 8.0 * rx->T0, te, 0.0, rx->T0, 0.0, rx->cfg.deviation_hz, rx->cfg.center_hz, prof);
    double lo = 1e9, hi = -1e9;
    for (int k = 0; k < PROFILE_BINS; k++) { if (prof[k] < lo) lo = prof[k]; if (prof[k] > hi) hi = prof[k]; }
    int white = 0;
    for (int k = 0; k < PROFILE_BINS; k++) if (hi > lo && (prof[k] - lo) / (hi - lo) >= 0.5) white++;
    if (lo_out) *lo_out = lo;
    if (hi_out) *hi_out = hi;
    return (double)white / PROFILE_BINS;
}

/* A phasing clear enough to start a chart when it is not expected: normal 5/95 or symmetric, from
 * true black to true white. A dark picture shows its dead sector (white, 5 % of the line) on every
 * line, the shape of a 5/95 phasing: its dark is not black (test F4b: a chart grey to its edges). */
static int clear_phasing(const wefax_rx *rx, double te) {
    if (!phasing_window(rx, te)) return 0;
    double lo, hi, d = window_duty(rx, te, &lo, &hi);
    if (lo > 0.15 || hi < 0.85) return 0;
    return d < 0.3 || (d > 0.4 && d < 0.6);
}

/* Where a chart ends when it is closed: if the signal was lost and has not come back, where it was
 * last heard; and if it came back only with the next transmission (its start or its phasing, a few
 * seconds before it is closed), where it was lost too: the cut before the next chart is not part of
 * this one (tests F21, F22). */
static double chart_end(wefax_rx *rx, double t) {
    if (rx->lost_open) { rx->lost_open = 0; if (rx->lost_from < t) t = rx->lost_from; }
    else if (rx->nlost > 0 && rx->lost_b[rx->nlost - 1] >= t - 3.0 && rx->lost_a[rx->nlost - 1] < t) {
        t = rx->lost_a[rx->nlost - 1];
        rx->nlost--;
    }
    return t;
}

static void process_block(wefax_rx *rx, size_t i0, double tb, double te) {
    double amp;
    int alt = stream_alt(rx, i0, (size_t)rx->B, &amp);
    int tone = raw_tone_at(rx, 0.5 * (tb + te));
    int is_start = (alt == 0 || alt == 1 || tone == 0 || tone == 1);
    int is_stop = (alt == 2 || tone == 2);
    int prev_start = rx->start_run;
    if (is_start) { if (rx->start_run++ == 0) { rx->start_run_t0 = tb; rx->start_plain = !(alt == 0 || alt == 1); rx->start_freq_tone = (alt >= 0) ? alt : tone; } }
    else rx->start_run = 0;
    if (is_stop) { if (rx->stop_run++ == 0) rx->stop_run_t0 = tb; }
    else rx->stop_run = 0;
    /* the stop signal lasts 5 s ([W] §5.2.5); a fade breaks it into pieces (F-4 d): 20 of the last
       40 blocks decide, once per stop signal. Its start: the oldest of those blocks */
    rx->stop_hist = ((rx->stop_hist << 1) | (uint64_t)(is_stop ? 1 : 0)) & ((1ULL << 40) - 1);
    int stop_cnt = __builtin_popcountll(rx->stop_hist);
    int stop_vote = 0;
    double stop_t0 = tb;
    if (stop_cnt == 0) rx->stop_latched = 0;
    else if (stop_cnt >= 20 && !rx->stop_latched) {
        rx->stop_latched = 1;
        stop_vote = 1;
        int k = 63 - __builtin_clzll(rx->stop_hist);              /* blocks back to the oldest one */
        stop_t0 = tb - (double)k * (double)rx->B * rx->st.dt;
    }
    char tx[160];
    switch (rx->state) {
    case S_IDLE:
    case S_START:
        if (rx->start_run == 15) {
            snprintf(tx, sizeof tx, "Senyal d'inici: %s a %.0f Hz", rx->start_plain ? "to pur" : "alternança",
                     TONES[rx->start_freq_tone]);
            push_ev(rx, WEFAX_EV_START, rx->start_run_t0, TONES[rx->start_freq_tone], rx->start_plain, -1, tx);
            rx->state = S_START;
            rx->start_end = -1.0;
            rx->ph_strict = 0;
        }
        if (stop_vote) rx->ph_strict = 0;             /* the end of the transmission that was cut */
        /* the start signal ends at its last block: a fade inside it is not its end */
        if (rx->state == S_START && is_start) rx->start_end = te;
        if (rx->start_run == 0 && (rx->ph_strict ? clear_phasing(rx, te) : phasing_window(rx, te))) {
            rx->ph_from_state = rx->state;
            rx->state = S_PHASING;
            rx->ph_a = te - 8.0 * rx->T0;
            rx->ph_b = te;
            rx->ph_fail = 0;
            break;
        }
        if (!rx->lpm_warned && !rx->ph_strict && rx->start_run == 0 && (rx->next_blk / (uint64_t)rx->B) % 5 == 0) {
            /* twice in a row (half a second apart), never once */
            double other = phasing_other_lpm(rx, te);
            if (other > 0.0 && other == rx->lpm_cand) {
                snprintf(tx, sizeof tx, "La fase va a %.0f LPM, no a %.0f com s'ha triat: el període no quadra", other, rx->cfg.lpm);
                push_note(rx, WEFAX_NOTE_LPM_MISMATCH, te, other, -1, tx);
                rx->lpm_warned = 1;
            }
            rx->lpm_cand = other;
        }
        /* the phasing needs 8 lines to be seen: wait that long, and 3 s more, before going without */
        if (rx->state == S_START && rx->start_end >= 0.0 && tb - rx->start_end > 8.0 * rx->T0 + 3.0) {
            begin_receiving_without_phasing(rx, rx->start_end);
            push_note(rx, WEFAX_NOTE_NO_PHASING_AFTER_START, rx->start_end, 0, -1, "Després del senyal d'inici no ve cap fase: es rep sense");
        }
        break;
    case S_PHASING:
        if (phasing_window(rx, te)) { rx->ph_b = te; rx->ph_fail = 0; break; }
        /* one bad window in noise or in a fade does not end the phasing; two lines of them do (F-3) */
        if (++rx->ph_fail < rx->ph_fail_max) break;
        rx->ph_fail = 0;
        if (rx->ph_b - rx->ph_a < (rx->ph_strict ? 20.0 : 16.0) * rx->T0 - 1e-9) {
            /* under 16 lines: a straight line in a chart, not a phasing ([W] sends 30 s, fldigi 20 lines) */
            rx->state = rx->ph_from_state;
            break;
        }
        if (analyse_phasing(rx, te)) {
            rx->state = S_RECEIVING;
            rx->amp_ref = 0; rx->amp_ref_n = 0; rx->loss_run = 0;
            rx->nlost = 0; rx->lost_open = 0; rx->inimg_ph_on = 0; rx->ph_strict = 0;
        } else {
            begin_receiving_without_phasing(rx, rx->ph_b);
        }
        break;
    case S_RECEIVING: {
        /* a new start signal closes the chart (it is saved) and the next one begins: 2.5 s of it or
           more ([W] §5.2.2.1: 5 to 10 s; a piece of 2 s is no start, test F14a). A shorter piece is
           said and ignored */
        if (rx->start_run == 25) {
            double t0 = rx->start_run_t0;
            finish_picture(rx, chart_end(rx, t0), 0, WEFAX_NOTE_CLOSED_BY_START, "un senyal d'inici nou");
            snprintf(tx, sizeof tx, "Senyal d'inici: %s a %.0f Hz", rx->start_plain ? "to pur" : "alternança",
                     TONES[rx->start_freq_tone]);
            push_ev(rx, WEFAX_EV_START, t0, TONES[rx->start_freq_tone], rx->start_plain, -1, tx);
            rx->state = S_START;
            rx->start_end = te;
            rx->ph_strict = 0;
            break;
        }
        if (rx->start_run == 0 && prev_start >= 15)
            push_note(rx, WEFAX_NOTE_START_IN_PICTURE, rx->start_run_t0, 0, -1, "Un tros de senyal d'inici dins de la carta: s'ignora");
        if (stop_vote) {
            int plain = !(alt == 2);
            double ts = refine_stop(rx, stop_t0, plain);
            snprintf(tx, sizeof tx, "Senyal de parada: %s a 450 Hz", plain ? "to pur" : "alternança");
            push_ev(rx, WEFAX_EV_STOP, ts, 450.0, plain, -1, tx);
            finish_picture(rx, chart_end(rx, ts), 1, WEFAX_NOTE_NONE, "parada");
            rx->state = S_AFTER_STOP;
            rx->after_until = te + 11.0;               /* 10 s of black after the stop ([W] §5.2.5) */
            break;
        }
        /* a new phasing: the next chart, after one that ended with no stop. Only a clear one (normal
           5/95 or symmetric: a chart's vertical line can look like an inverted one), 20 lines long */
        if ((rx->next_blk / (uint64_t)rx->B) % 5 == 0) {
            if (clear_phasing(rx, te)) {
                if (!rx->inimg_ph_on) { rx->inimg_ph_on = 1; rx->inimg_ph_a = te - 8.0 * rx->T0; }
                if (te - rx->inimg_ph_a >= 20.0 * rx->T0) {
                    double ta = rx->inimg_ph_a;
                    double so_far = (ta - (rx->cur.c + rx->cur.g0 * rx->cur.T)) / rx->cur.T;
                    if (so_far < 20.0) {
                        /* fewer than 20 lines of picture before it: it is the same phasing, which a fade had
                           cut short, going on; it is taken whole, and no scrap of a chart is saved
                           (5.1-fax, good +6 dB, seed 201) */
                        rx->state = S_PHASING;
                        /* a chart that began without phasing has no start of it yet: it is where this one
                           began (N2-fax-app-24) */
                        if (!rx->have_phasing) rx->ph_a = rx->inimg_ph_a;
                        rx->ph_b = te; rx->ph_fail = 0;
                        rx->ph_from_state = S_IDLE;
                        rx->have_phasing = 0;
                        rx->nlost = 0; rx->lost_open = 0;
                        rx->inimg_ph_on = 0;
                        break;
                    }
                    finish_picture(rx, chart_end(rx, ta), 0, WEFAX_NOTE_CLOSED_BY_PHASING, "una fase nova");
                    rx->ph_from_state = S_IDLE;
                    rx->state = S_PHASING;
                    rx->ph_a = ta; rx->ph_b = te; rx->ph_fail = 0;
                    rx->inimg_ph_on = 0;
                    break;
                }
            } else rx->inimg_ph_on = 0;
        }
        /* the reference level of the signal (not learnt during a cut), and the cuts: the signal is
           lost when it drops, or when only noise is left (a radio's noise does not drop). A cut never
           closes the chart: the line clock goes on, and those lines come out grey */
        int lost = rx->amp_ref_n >= 10 && (amp < 0.05 * rx->amp_ref || out_of_band(rx, i0, (size_t)rx->B) > 0.37);
        if (!lost && !rx->lost_open) {
            if (rx->amp_ref_n < 50) { rx->amp_ref = (rx->amp_ref * rx->amp_ref_n + amp) / (rx->amp_ref_n + 1); rx->amp_ref_n++; }
            else rx->amp_ref = 0.98 * rx->amp_ref + 0.02 * amp;
        }
        if (lost) { rx->loss_run++; rx->good_run = 0; }
        else { rx->loss_run = 0; rx->good_run++; }
        if (rx->loss_run == 10 && !rx->lost_open) {
            rx->lost_open = 1;
            rx->lost_from = tb - 0.9;
            push_note(rx, WEFAX_NOTE_SIGNAL_LOST, rx->lost_from, 0, -1,
                      "Es perd el senyal: les línies continuen al seu lloc i surten en gris");
        }
        if (rx->lost_open && rx->good_run == 10) {
            double back = tb - 0.9;
            if (rx->nlost < 64) { rx->lost_a[rx->nlost] = rx->lost_from; rx->lost_b[rx->nlost] = back; rx->nlost++; }
            rx->lost_open = 0;
            snprintf(tx, sizeof tx, "Torna el senyal: %.1f s perduts, en gris", back - rx->lost_from);
            push_note(rx, WEFAX_NOTE_SIGNAL_BACK, back, back - rx->lost_from, -1, tx);
        }
        /* one chart with no stop: 4000 lines at most */
        if ((te - (rx->cur.c + rx->cur.g0 * rx->cur.T)) / rx->cur.T >= rx->cfg.max_lines) {
            finish_picture(rx, chart_end(rx, te), 0, WEFAX_NOTE_LINE_LIMIT, "límit de línies");
            rx->state = S_IDLE;
            strict_phasing(rx, te);
        }
        break;
    }
    case S_AFTER_STOP:
        if (tb >= rx->after_until) { rx->state = S_IDLE; rx->start_run = rx->stop_run = 0; }
        break;
    }
}

static void process_stream(wefax_rx *rx, int at_end) {
    sample_buf *b = &rx->st;
    for (;;) {
        if (rx->next_blk < b->base) rx->next_blk = b->base;
        size_t i0 = (size_t)(rx->next_blk - b->base);
        size_t need = i0 + (size_t)rx->B * (at_end ? 1 : 3);
        if (need > b->n) break;
        double tb = sbuf_time(b, i0), te = sbuf_time(b, i0 + (size_t)rx->B);
        /* the raw tone block for this time must be done too, so that the block size does not change the result */
        if (!at_end && (size_t)((te + 0.1) * rx->fs / rx->Br) >= rx->nraw) break;
        process_block(rx, i0, tb, te);
        rx->next_blk += (uint64_t)rx->B;
    }
    /* trim: keep enough for a phasing window and the stop refinement */
    if (rx->state == S_IDLE || rx->state == S_AFTER_STOP || rx->state == S_START) {
        double keep = 10.0 * rx->T0 + 2.0;
        size_t done = (size_t)(rx->next_blk - b->base);
        if (done > b->n) done = b->n;
        double t_keep = sbuf_time(b, done) - keep;
        size_t cut = sbuf_index(b, t_keep);
        if (cut > done) cut = done;
        if (cut > 0) sbuf_drop(b, cut);
    }
}

int wefax_rx_feed(wefax_rx *rx, const float *x, size_t n) {
    size_t need = n / (size_t)rx->dm.D + 2;
    if (need > rx->tcap) {
        free(rx->tf); free(rx->ta); free(rx->tt);
        rx->tf = malloc(need * sizeof(float));
        rx->ta = malloc(need * sizeof(float));
        rx->tt = malloc(need * sizeof(double));
        if (!rx->tf || !rx->ta || !rx->tt) { rx->tcap = 0; return -1; }
        rx->tcap = need;
    }
    raw_feed(rx, x, n);
    size_t m = fm_demod_run(&rx->dm, x, n, rx->tf, rx->ta, rx->tt, rx->tcap);
    for (size_t i = 0; i < m; i++)
        if (sbuf_push(&rx->st, rx->tf[i], rx->ta[i], rx->tt[i]) != 0) return -1;
    process_stream(rx, 0);
    return 0;
}

int wefax_rx_finish(wefax_rx *rx) {
    if (rx->r_cnt > rx->Br / 2) raw_block_done(rx);
    /* a filter's length of zeros brings out the last outputs (as in the SSTV receiver) */
    {
        size_t n = (size_t)rx->dm.ntaps;
        float *z = calloc(n, sizeof(float));
        if (z && n / (size_t)rx->dm.D + 2 <= rx->tcap) {
            size_t m = fm_demod_run(&rx->dm, z, n, rx->tf, rx->ta, rx->tt, rx->tcap);
            for (size_t i = 0; i < m; i++) sbuf_push(&rx->st, rx->tf[i], rx->ta[i], rx->tt[i]);
        }
        free(z);
    }
    process_stream(rx, 1);
    sample_buf *b = &rx->st;
    double t_end = b->n ? sbuf_time(b, b->n - 1) : 0.0;
    /* the input ends during a phasing: as when a phasing ends in the stream (N2-fax-app-10): under 16
       lines it is no phasing, and one that does not hold up gives a chart without it */
    if (rx->state == S_PHASING) {
        if (rx->ph_b - rx->ph_a < (rx->ph_strict ? 20.0 : 16.0) * rx->T0 - 1e-9) rx->state = rx->ph_from_state;
        else if (analyse_phasing(rx, t_end)) rx->state = S_RECEIVING;
        else begin_receiving_without_phasing(rx, rx->ph_b);
    }
    if (rx->state == S_RECEIVING) {
        /* the note comes with the chart it ends, once (N2-fax-app-11) */
        finish_picture(rx, chart_end(rx, t_end), 0, WEFAX_NOTE_ENDS_WITHOUT_STOP, "s'acaba el senyal sense parada");
    } else if (rx->state == S_START) {
        push_note(rx, WEFAX_NOTE_START_WITHOUT_PICTURE, t_end, 0, -1, "Senyal d'inici sense imatge al darrere");
    }
    return 0;
}
