/* SPDX-License-Identifier: GPL-3.0-or-later
 * The SSTV receiver of the core: VIS, image capture, sync fit, rendering.
 *
 * Written from scratch from the published descriptions. Ideas with their sources:
 *  - the VIS format and every mode timing: Barber 2000;
 *  - the line timing from a least-squares straight line through the sync times, with at least
 *    16 lines before the slope is trusted: the MMSSTV manual's description; the outlier
 *    rejection is ours (lesson L12);
 *  - Scottie: the start sync is not required, and both scan layouts are accepted (A1, A2);
 *  - Robot 36: R-Y or B-Y is read from the separator tone, not from the line parity (A35);
 *    a ~300 ms line is reported, never decoded as a picture (A26);
 *  - colour: Barber's studio scale by default, full range as an option (A11).
 *
 * Everything runs on one clock: the index of the demodulated sample being examined. The end
 * of an image, the VIS decisions and the trimming of old samples all happen at the same sample
 * whatever the size of the input blocks, so a file fed at once and in 10 ms blocks gives the
 * same images, bit for bit (test 3.10).
 */
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sstv1.h"
#include "internal.h"

#define LEADER_HZ 1900.0
#define SYNC_HZ   1200.0
#define BLACK_HZ  1500.0
#define WHITE_HZ  2300.0
#define MAXCAND   16
#define SW_RING   64      /* the syncs the stream watch fits its line to */

void sstv_rx_config_default(sstv_rx_config *c) {
    memset(c, 0, sizeof *c);
    c->levels = SSTV_LEVELS_STUDIO;
    c->scottie = SCOTTIE_LAYOUT_AUTO;
    c->forced_mode = SSTV_MODE_NONE;
    c->keep_buffers = 1;
    c->auto_tune = 1;
    c->fit_slant = 1;
    c->preset_slant_ppm = 0.0;
}

typedef struct { double t; double dur; } sync_hit;

typedef struct {
    double a, b;              /* sync n at a + b * n (seconds) */
    double b0;                /* nominal period */
    double offset_hz;         /* applied to the pixel values when there is no per-line value */
    const double *line_off;   /* per sync: the tuning offset measured on that sync, or NULL */
    const sstv_mode *mode;
    scottie_layout layout;
    double t_end;             /* rows that end after this are not rendered */
    int nsync;
} render_params;

typedef struct {
    sample_buf buf;
    sync_hit *hits; int nhits;
    double *line_off;
    double vis_off;
    render_params rp;
    int valid;
} retained_t;

typedef struct { double t_trig; } vis_cand;

enum { ST_IDLE = 0, ST_RECEIVING = 1 };

struct sstv_rx {
    double fs;
    sstv_rx_config cfg;
    fm_demod dm;
    float *tf, *ta, *ti, *tq; double *tt; size_t tcap;
    sample_buf st;            /* the demodulated stream (trimmed while idle) */
    size_t scan_i;            /* next buffer index the clock will examine */
    int forced_pending, forced_warned;
    double forced_next;       /* scan time of the next look for syncs in forced mode */
    double forced_from;       /* forced mode looks only after this time (the end of the last picture) */
    /* leader tracking */
    double run_start, run_last;   /* in-band run, or run_start < 0 */
    int was_low;
    vis_cand cand[MAXCAND]; int ncand;
    /* image in progress */
    int state;
    const sstv_mode *mode;
    double offset_hz, t_cap_start, t_expected_end, s0_expected, t_check;
    int period_checked;
    /* the syncs as they stream past, on the picture's period (the watchdog and F4) */
    double t_last_sync;       /* the latest sync that falls on the period */
    double sw_cand;           /* before locking on: the last sync-like pulse, or < -1e299 */
    int sw_locked;            /* two sync-like pulses on the period have been seen */
    double sw_L;              /* the line period the watch has measured (it follows the slant, NUC-3) */
    double sw_Lmed;           /* the median of the last periods measured from two syncs in a row */
    double sw_iv[5];          /* those periods */
    int sw_niv, sw_ivpos;
    /* the syncs accepted since it locked on (or locked on again): their line numbers and times, and the
       straight line fitted to them, t = sw_a + n * sw_L, that predicts the next one (N-nucli-10) */
    double sw_rt[SW_RING]; long sw_rn[SW_RING]; int sw_rcount, sw_rpos;
    long sw_nlast;            /* the line number of t_last_sync */
    int sw_fit, sw_nfit;      /* the line is fitted (with sw_nfit syncs) */
    double sw_a, sw_sigma;    /* its origin, and the spread of the syncs about it (1.4826 MAD) */
    double sw_relock;         /* locked: the last pulse of the right size off the line, to lock on again, or < -1e299 */
    int sw_cand_strict;       /* the reference pulse (the candidate, or the last sync) was of the right size */
    double sw_run_start;      /* start of the run below the sync threshold, or < 0 */
    int sw_prev_low;
    double t_watch;           /* next watchdog look */
    double t_close_hint;      /* where a picture closed early really ended (forced mode looks after it) */
    /* images and events */
    sstv_image *imgs; retained_t *ret; int nimg, capimg;
    sstv_event *ev; int evn, evcap, evhead;
};

/* ---------------------------------------------------------------- small helpers */

static void push_event(sstv_rx *rx, const sstv_event *e) {
    if (rx->evn == rx->evcap) {
        int nc = rx->evcap ? rx->evcap * 2 : 32;
        sstv_event *ne = realloc(rx->ev, (size_t)nc * sizeof *ne);
        if (!ne) return;
        rx->ev = ne; rx->evcap = nc;
    }
    rx->ev[rx->evn++] = *e;
}

static void event_note(sstv_rx *rx, sstv_note note, sstv_event_type type, double t, int vis, sstv_mode_id mode,
                       double off, const char *text) {
    sstv_event e;
    memset(&e, 0, sizeof e);
    e.type = type; e.note = note; e.t = t; e.vis = vis; e.mode = mode; e.offset_hz = off; e.image_index = -1;
    snprintf(e.text, sizeof e.text, "%s", text);
    push_event(rx, &e);
}

static void event_text(sstv_rx *rx, sstv_event_type type, double t, int vis, sstv_mode_id mode, double off, const char *text) {
    event_note(rx, SSTV_NOTE_NONE, type, t, vis, mode, off, text);
}

static int cmp_double(const void *x, const void *y) {
    double a = *(const double *)x, b = *(const double *)y;
    return (a > b) - (a < b);
}

static double median(double *v, int n) {
    if (n <= 0) return 0.0;
    qsort(v, (size_t)n, sizeof *v, cmp_double);
    return (n & 1) ? v[n / 2] : 0.5 * (v[n / 2 - 1] + v[n / 2]);
}

/* Median of the raw demodulated frequency over [ta, tb): robust against FM clicks in noise. */
static double band_median(const sample_buf *b, double ta, double tb) {
    size_t i0 = sbuf_index(b, ta), i1 = sbuf_index(b, tb);
    if (i1 <= i0) return sbuf_at(b, ta);
    int n = (int)(i1 - i0);
    double *v = malloc((size_t)n * sizeof(double));
    if (!v) return sbuf_mean(b, ta, tb);
    for (int k = 0; k < n; k++) v[k] = b->f[i0 + (size_t)k];
    double m = median(v, n);
    free(v);
    return m;
}

/* The mean frequency over [ta, tb), leaving out the FM clicks of noise (samples more than
 * 400 Hz away from the median). Not the median itself: with a weaker carrier in the band the
 * instantaneous frequency wobbles at the beat, and only its mean stays on the stronger tone (the
 * phase of the sum drifts at the stronger tone's rate and only wobbles around it). Test 5.3. */
static double band_tmean(const sample_buf *b, double ta, double tb) {
    size_t i0 = sbuf_index(b, ta), i1 = sbuf_index(b, tb);
    if (i1 <= i0) return sbuf_at(b, ta);
    double m = band_median(b, ta, tb), acc = 0.0;
    int c = 0;
    for (size_t i = i0; i < i1; i++) if (fabs(b->f[i] - m) <= 400.0) { acc += b->f[i]; c++; }
    return c ? acc / c : m;
}

static uint8_t clamp8(double v) {
    if (v < 0.0) return 0;
    if (v > 255.0) return 255;
    return (uint8_t)(v + 0.5);
}

static int nsync_of(const sstv_mode *m) { return (m->family == SSTV_FAMILY_PD) ? m->height / 2 : m->height; }

/* ---------------------------------------------------------------- creation */

sstv_rx *sstv_rx_new(double fs, const sstv_rx_config *cfg) {
    sstv_rx *rx = calloc(1, sizeof *rx);
    if (!rx) return NULL;
    rx->fs = fs;
    if (cfg) rx->cfg = *cfg; else sstv_rx_config_default(&rx->cfg);
    /* low-pass 1200 Hz around 1900 Hz: 700 to 3100 Hz; decimated to about 6 kHz */
    if (fm_demod_init(&rx->dm, fs, LEADER_HZ, 1200.0, 6000.0) != 0) { free(rx); return NULL; }
    rx->st.dt = rx->dm.D / fs;
    rx->st.has_iq = 1;
    rx->run_start = -1.0;
    rx->forced_pending = (rx->cfg.forced_mode != SSTV_MODE_NONE);
    rx->forced_from = -1e300;
    return rx;
}

void sstv_rx_free(sstv_rx *rx) {
    if (!rx) return;
    fm_demod_free(&rx->dm);
    free(rx->tf); free(rx->ta); free(rx->ti); free(rx->tq); free(rx->tt);
    sbuf_free(&rx->st);
    for (int i = 0; i < rx->nimg; i++) {
        free(rx->imgs[i].rgb); sbuf_free(&rx->ret[i].buf); free(rx->ret[i].hits); free(rx->ret[i].line_off);
    }
    free(rx->imgs); free(rx->ret); free(rx->ev);
    free(rx);
}

int sstv_rx_next_event(sstv_rx *rx, sstv_event *ev) {
    if (rx->evhead >= rx->evn) return 0;
    *ev = rx->ev[rx->evhead++];
    if (rx->evhead == rx->evn) rx->evhead = rx->evn = 0;   /* all read: the list does not grow for hours */
    return 1;
}

int sstv_rx_image_count(const sstv_rx *rx) { return rx->nimg; }
const sstv_image *sstv_rx_image(const sstv_rx *rx, int i) { return (i >= 0 && i < rx->nimg) ? &rx->imgs[i] : NULL; }

/* ---------------------------------------------------------------- syncs */

/* Pulses below the threshold in buffer [i0, i1), with a length in [min_s, max_s]. The signal is
 * smoothed with a centred moving average (no delay); each edge is the interpolated threshold
 * crossing. The time of a pulse is its TRAILING edge minus the nominal length: after the sync
 * comes the porch at 1500 Hz in every mode, so that edge goes from 1200 to 1500 Hz and the
 * threshold halfway is crossed right at the edge. Before the sync, Scottie, Robot 36 and PD send
 * picture: the leading edge would move with the last pixel (up to some tenths of a ms) and the
 * picture's content would tilt the fitted period. */
static double smooth_at(const sample_buf *b, size_t i, int half) {
    double acc = 0.0; int cnt = 0;
    for (int k = -half; k <= half; k++) {
        long j = (long)i + k;
        if (j < 0 || (size_t)j >= b->n) continue;
        acc += b->f[j]; cnt++;
    }
    return cnt ? acc / cnt : 0.0;
}

/* The trailing edge again, with the pulse's own level: the porch after a sync is always 300 Hz
 * above it (1500 against 1200 Hz, [B]), so the crossing is taken at the level measured inside
 * the pulse (band_tmean) plus 150 Hz. A fixed threshold would move the crossing as the tuning drifts during
 * the picture, and tilt it (test 5.5). */
static double trailing_edge(const sample_buf *b, double run_start, double run_end, int half) {
    double dur = run_end - run_start;
    size_t ia = sbuf_index(b, run_start + 0.25 * dur), ib = sbuf_index(b, run_end - 0.25 * dur);
    if (ib <= ia + 1 || ib >= b->n) return run_end;
    double lo = band_tmean(b, sbuf_time(b, ia), sbuf_time(b, ib));
    double thr = lo + 150.0;
    size_t j0 = sbuf_index(b, run_end - 0.0015), j1 = sbuf_index(b, run_end + 0.0015);
    if (j1 >= b->n) j1 = b->n - 1;
    double prev = smooth_at(b, j0, half);
    for (size_t j = j0 + 1; j <= j1; j++) {
        double cur = smooth_at(b, j, half);
        if (prev < thr && cur >= thr) return sbuf_time(b, j) - b->dt + (thr - prev) / (cur - prev) * b->dt;
        prev = cur;
    }
    return run_end;
}

/* The rising crossing of thr by the smoothed frequency within 1.5 ms of t; -1 if none. */
static double edge_at(const sample_buf *b, double t, double thr, int half) {
    size_t j0 = sbuf_index(b, t - 0.0015), j1 = sbuf_index(b, t + 0.0015);
    if (b->n == 0) return -1.0;
    if (j1 >= b->n) j1 = b->n - 1;
    double prev = smooth_at(b, j0, half), best = -1.0, bd = 1e9;
    for (size_t j = j0 + 1; j <= j1; j++) {
        double cur = smooth_at(b, j, half);
        if (prev < thr && cur >= thr) {
            double tc = sbuf_time(b, j) - b->dt + (thr - prev) / (cur - prev) * b->dt;
            if (fabs(tc - t) < bd) { bd = fabs(tc - t); best = tc; }
        }
        prev = cur;
    }
    return best;
}

static int find_syncs(const sample_buf *b, size_t i0, size_t i1, double thr, double min_s, double max_s,
                      int smooth, double nominal_s, sync_hit **out) {
    int cap = 256, n = 0;
    sync_hit *h = malloc((size_t)cap * sizeof *h);
    *out = h;
    if (!h) return 0;
    if (i1 > b->n) i1 = b->n;
    int half = smooth / 2;
    double run_start = -1e301, prev_s = 0.0;
    int have_prev = 0;
    for (size_t i = i0; i < i1; i++) {
        double acc = 0.0; int cnt = 0;
        for (int k = -half; k <= half; k++) {
            long j = (long)i + k;
            if (j < 0 || (size_t)j >= b->n) continue;
            acc += b->f[j]; cnt++;
        }
        double s = acc / cnt;
        double t = sbuf_time(b, i);
        if (have_prev) {
            if (prev_s >= thr && s < thr) {
                run_start = t - b->dt + (prev_s - thr) / (prev_s - s) * b->dt;
            } else if (prev_s < thr && s >= thr) {
                if (run_start > -1e300) {
                    double run_end = t - b->dt + (prev_s - thr) / (prev_s - s) * b->dt;
                    double dur = run_end - run_start;
                    /* also a sync glued to the VIS stop bit (one or two bits of 30 ms, [B] p. 2):
                       its trailing edge is as clean as any other */
                    int glued = (dur >= 0.030 + min_s && dur <= 0.060 + max_s);
                    /* and a sync that comes straight after digital silence (a file cut just before
                       it): the filter needs half its length to settle, so the pulse looks shorter;
                       its trailing edge is still clean */
                    int after_silence = 0;
                    if (dur >= 0.2 * nominal_s && dur < min_s) {
                        size_t ib = sbuf_index(b, run_start - 0.004), im = sbuf_index(b, run_end - 0.5 * dur);
                        if (ib < b->n && im < b->n && b->a[ib] < 0.05 * b->a[im]) after_silence = 1;
                    }
                    if ((dur >= min_s && dur <= max_s) || glued || after_silence) {
                        if (n == cap) {
                            sync_hit *nh = realloc(h, (size_t)cap * 2 * sizeof *nh);
                            if (!nh) break;
                            h = nh; cap *= 2; *out = h;
                        }
                        h[n].t = trailing_edge(b, run_start, run_end, half) - nominal_s; h[n].dur = dur; n++;
                    }
                }
                run_start = -1e301;
            }
        }
        /* a window that starts inside a pulse: its leading edge is unknown, run_start stays unset */
        prev_s = s; have_prev = 1;
    }
    return n;
}

/* Robust least-squares fit of t = a + b * n over the pulses that fall on a line, starting from b0.
 * With fix_slope, b stays at b0 and only a is fitted (median). The slope never goes more than 2 %
 * from b_nom, the mode's period. Returns the number used; *last gets the highest line index used,
 * or -1. */
static int fit_syncs(const sync_hit *h, int nh, int nsync, double a0, double b0, double b_nom, int fix_slope,
                     double *a_out, double *b_out, int *last) {
    double a = a0, b = b0;
    int nused = 0, lmax = -1;
    int *use = calloc((size_t)(nh > 0 ? nh : 1), sizeof(int));
    double *res = malloc((size_t)(nh > 0 ? nh : 1) * sizeof(double));
    if (!use || !res) { free(use); free(res); *a_out = a0; *b_out = b0; *last = -1; return 0; }
    for (int it = 0; it < 10; it++) {
        int m = 0;
        for (int i = 0; i < nh; i++) {
            long n = lround((h[i].t - a) / b);
            use[i] = (n >= 0 && n < nsync);
            if (use[i]) res[m++] = fabs(h[i].t - (a + b * (double)n));
        }
        double lim;
        if (it == 0) lim = 0.25 * b;                         /* first pass: anything near a line */
        else {
            double mad = (m > 0) ? median(res, m) : 0.0;
            lim = fmax(0.0015, 4.0 * 1.4826 * mad);
        }
        double sn = 0, st = 0, snn = 0, snt = 0;
        int cnt = 0;
        lmax = -1;
        for (int i = 0; i < nh; i++) {
            if (!use[i]) continue;
            long n = lround((h[i].t - a) / b);
            double r = h[i].t - (a + b * (double)n);
            if (fabs(r) > lim) { use[i] = 0; continue; }
            sn += (double)n; st += h[i].t; snn += (double)n * (double)n; snt += (double)n * h[i].t;
            if (n > lmax) lmax = (int)n;
            cnt++;
        }
        nused = cnt;
        if (!fix_slope && cnt >= 16) {
            double den = cnt * snn - sn * sn;
            if (fabs(den) > 0.0) {
                double nb = (cnt * snt - sn * st) / den;
                if (fabs(nb / b_nom - 1.0) <= 0.02) {         /* never more than 2 % from nominal */
                    b = nb;
                    a = (st - b * sn) / cnt;
                    continue;
                }
            }
        }
        if (cnt >= 1) {
            /* the slope stays: the offset is the median of the residual starts */
            double *d = malloc((size_t)cnt * sizeof(double));
            int k = 0;
            if (d) {
                for (int i = 0; i < nh; i++) {
                    if (!use[i]) continue;
                    long n = lround((h[i].t - a) / b);
                    d[k++] = h[i].t - b * (double)n;
                }
                a = median(d, k);
                free(d);
            }
        }
    }
    free(use); free(res);
    *a_out = a; *b_out = b; *last = lmax;
    return nused;
}

/* How well a fit puts the pulses on its lines: how many fall within `close` of a line, and the median
 * distance of all of them (each to its nearest line in the picture). A fit on the wrong lines leaves
 * many pulses far from them, even when its own robust limit grew to take them in. */
static int fit_score(const sync_hit *h, int nh, int nsync, double a, double b, double close, double *spread) {
    double *r = malloc((size_t)(nh > 0 ? nh : 1) * sizeof(double));
    int m = 0, on = 0;
    for (int i = 0; i < nh; i++) {
        long n = lround((h[i].t - a) / b);
        if (n < 0 || n >= nsync) continue;
        double d = fabs(h[i].t - (a + b * (double)n));
        if (d < close) on++;
        if (r) r[m++] = d;
    }
    *spread = (r && m) ? median(r, m) : 1e9;
    free(r);
    return on;
}

/* The fit of a picture's syncs from the mode's period and, when the stream watch measured one, from
 * that one too: the start that puts more syncs on their lines (and, as many, closer to them) wins. A
 * clock 1 % off needs the measured start (NUC-3); a fade can put the measured one 1 % off, where the
 * mode's start is the good one (N-nucli-8). */
static int fit_from_both(const sync_hit *h, int nh, int nsync, double a0, double b0, double b_watch, int have_watch,
                         double close, double *a_out, double *b_out, int *last) {
    double a1, b1, a2, b2, r1, r2;
    int l1, l2;
    int u1 = fit_syncs(h, nh, nsync, a0, b0, b0, 0, &a1, &b1, &l1);
    if (!have_watch || fabs(b_watch / b0 - 1.0) < 1e-6) { *a_out = a1; *b_out = b1; *last = l1; return u1; }
    int u2 = fit_syncs(h, nh, nsync, a0, b_watch, b0, 0, &a2, &b2, &l2);
    int s1 = fit_score(h, nh, nsync, a1, b1, close, &r1), s2 = fit_score(h, nh, nsync, a2, b2, close, &r2);
    if (s2 > s1 || (s2 == s1 && r2 < r1)) { *a_out = a2; *b_out = b2; *last = l2; return u2; }
    *a_out = a1; *b_out = b1; *last = l1;
    return u1;
}

/* ---------------------------------------------------------------- rendering */

static double fval(const sample_buf *b, double ta, double tb, double off) {
    double f = sbuf_mean(b, ta, tb) - off;
    return (f - BLACK_HZ) * 255.0 / (WHITE_HZ - BLACK_HZ);
}

static void ycc_to_rgb(double y, double cr, double cb, sstv_levels lv, uint8_t *o) {
    double r, g, bl;
    if (lv == SSTV_LEVELS_STUDIO) {
        /* Barber Appendix B, p. 14, the inverse */
        r  = 0.003906 * (298.082 * (y - 16.0) + 408.583 * (cr - 128.0));
        g  = 0.003906 * (298.082 * (y - 16.0) - 100.291 * (cb - 128.0) - 208.12 * (cr - 128.0));
        bl = 0.003906 * (298.082 * (y - 16.0) + 516.411 * (cb - 128.0));
    } else {
        /* BT.601 full range: our calculation */
        r  = y + 1.402 * (cr - 128.0);
        g  = y - 0.344136 * (cb - 128.0) - 0.714136 * (cr - 128.0);
        bl = y + 1.772 * (cb - 128.0);
    }
    o[0] = clamp8(r); o[1] = clamp8(g); o[2] = clamp8(bl);
}

/* Render one image from a demodulated buffer and fitted parameters. Returns the rows rendered.
 * Pixel j of a scan of length L starting at time s is the mean frequency over
 * [s + j L / W, s + (j + 1) L / W): exact windows, nothing rounded to a sample. */
static int render_image(const sample_buf *b, const render_params *rp, sstv_levels lv, uint8_t *rgb) {
    const sstv_mode *m = rp->mode;
    const int W = m->width, H = m->height;
    const double k = rp->b / rp->b0;           /* every part of the line scales with the period */
    double off = rp->offset_hz;
#define OFF(n) (rp->line_off ? rp->line_off[(n) < rp->nsync ? (n) : rp->nsync - 1] : rp->offset_hz)
    memset(rgb, 0, (size_t)W * H * 3);
    int rows = 0;
#define T(n, ms) (rp->a + rp->b * (double)(n) + (ms) * 1e-3 * k)
    if (m->family == SSTV_FAMILY_MARTIN || m->family == SSTV_FAMILY_SCOTTIE) {
        double oG, oB, oR, scan = m->scan_ms;
        if (m->family == SSTV_FAMILY_MARTIN) {
            oG = m->sync_ms + m->porch_ms;
            oB = oG + m->scan_ms + m->sep_ms;
            oR = oB + m->scan_ms + m->sep_ms;
        } else {
            /* the sync sits between blue and red: green and blue belong before it */
            if (rp->layout == SCOTTIE_LAYOUT_OPEN) scan = m->scan_ms - m->sep_ms;
            oG = -(2.0 * m->scan_ms + m->sep_ms);
            oB = -m->scan_ms;
            oR = m->sync_ms + m->porch_ms;
        }
        double px = scan / W;
        for (int r = 0; r < H; r++) {
            if (T(r, oR + scan) > rp->t_end) break;
            off = OFF(r);
            for (int j = 0; j < W; j++) {
                uint8_t *o = rgb + ((size_t)r * W + j) * 3;
                o[1] = clamp8(fval(b, T(r, oG + j * px), T(r, oG + (j + 1) * px), off));
                o[2] = clamp8(fval(b, T(r, oB + j * px), T(r, oB + (j + 1) * px), off));
                o[0] = clamp8(fval(b, T(r, oR + j * px), T(r, oR + (j + 1) * px), off));
            }
            rows++;
        }
    } else if (m->family == SSTV_FAMILY_ROBOT36) {
        double oY = m->sync_ms + m->porch_ms;                       /* 12.0 */
        double oS = oY + m->scan_ms;                                /* separator, 100.0 */
        double oC = oS + m->sep_ms + m->porch2_ms;                  /* 106.0 */
        double pxY = m->scan_ms / W, pxC = m->chroma_ms / W;
        int *is_ry = calloc((size_t)H, sizeof(int));
        double *ch = malloc((size_t)H * W * sizeof(double));
        double *yy = malloc((size_t)H * W * sizeof(double));
        int last = -1;
        if (!is_ry || !ch || !yy) { free(is_ry); free(ch); free(yy); return 0; }
        for (int l = 0; l < H; l++) {
            if (T(l, oC + m->chroma_ms) > rp->t_end) break;
            last = l;
            off = OFF(l);
            double sep = sbuf_mean(b, T(l, oS + 0.5), T(l, oS + m->sep_ms - 0.5)) - off;
            is_ry[l] = (sep < LEADER_HZ);                           /* 1500 Hz: R-Y; 2300 Hz: B-Y (A35) */
            for (int j = 0; j < W; j++) {
                yy[(size_t)l * W + j] = fval(b, T(l, oY + j * pxY), T(l, oY + (j + 1) * pxY), off);
                ch[(size_t)l * W + j] = fval(b, T(l, oC + j * pxC), T(l, oC + (j + 1) * pxC), off);
            }
        }
        for (int r = 0; r <= last; r++) {
            /* the colour of a pair of lines is shared: the other line of the pair carries the other difference */
            int partner = (r & 1) ? r - 1 : r + 1;
            if (partner > last) partner = (r > 0) ? r - 1 : r;
            int lry = is_ry[r] ? r : (is_ry[partner] ? partner : r);
            int lby = !is_ry[r] ? r : (!is_ry[partner] ? partner : r);
            for (int j = 0; j < W; j++)
                ycc_to_rgb(yy[(size_t)r * W + j], ch[(size_t)lry * W + j], ch[(size_t)lby * W + j], lv,
                           rgb + ((size_t)r * W + j) * 3);
            rows++;
        }
        free(is_ry); free(ch); free(yy);
    } else { /* PD: one sync, two picture lines */
        double o0 = m->sync_ms + m->porch_ms;
        double sc = m->scan_ms, px = sc / W;
        for (int n = 0; n < H / 2; n++) {
            if (T(n, o0 + 4 * sc) > rp->t_end) break;
            off = OFF(n);
            for (int j = 0; j < W; j++) {
                double y0 = fval(b, T(n, o0 + j * px), T(n, o0 + (j + 1) * px), off);
                double cr = fval(b, T(n, o0 + sc + j * px), T(n, o0 + sc + (j + 1) * px), off);
                double cb = fval(b, T(n, o0 + 2 * sc + j * px), T(n, o0 + 2 * sc + (j + 1) * px), off);
                double y1 = fval(b, T(n, o0 + 3 * sc + j * px), T(n, o0 + 3 * sc + (j + 1) * px), off);
                ycc_to_rgb(y0, cr, cb, lv, rgb + ((size_t)(2 * n) * W + j) * 3);
                ycc_to_rgb(y1, cr, cb, lv, rgb + ((size_t)(2 * n + 1) * W + j) * 3);
            }
            rows += 2;
        }
    }
#undef T
#undef OFF
    return rows;
}

/* The tuning offset of every line, measured on its own sync pulse (a known 1200 Hz tone): the
 * mean frequency over the middle half of the pulse (without clicks), kept only within 60 Hz of the
 * leader's value, then a running median over 15 lines. Lines
 * whose sync is missing take the nearest measured value; with none at all, the leader's. This
 * follows a drift during the picture (test 5.5), which one value from the VIS cannot. */
static double *line_offsets(const sample_buf *b, const sync_hit *h, int nh, const render_params *rp, double vis_off,
                            int auto_tune) {
    int N = rp->nsync;
    const sstv_mode *m = rp->mode;
    double k = rp->b / rp->b0;
    double *raw = malloc((size_t)N * sizeof(double)), *out = malloc((size_t)N * sizeof(double));
    if (!raw || !out) { free(raw); free(out); return NULL; }
    if (!auto_tune) {
        for (int n = 0; n < N; n++) out[n] = 0.0;
        free(raw);
        return out;
    }
    int j = 0;
    for (int n = 0; n < N; n++) {
        double s = rp->a + rp->b * n;
        raw[n] = NAN;
        while (j < nh && h[j].t < s - 0.001) j++;
        if (j < nh && fabs(h[j].t - s) < 0.001 && s + m->sync_ms * 1e-3 * k <= rp->t_end) {
            raw[n] = band_tmean(b, s + 0.25 * m->sync_ms * 1e-3 * k, s + 0.75 * m->sync_ms * 1e-3 * k) - SYNC_HZ;
            /* an SSB drift is slow and small: a value far from the leader's is interference */
            if (fabs(raw[n] - vis_off) > 60.0) raw[n] = NAN;
        }
    }
    double win[15];
    int any = 0;
    for (int n = 0; n < N; n++) {
        int c = 0;
        for (int q = n - 7; q <= n + 7; q++) if (q >= 0 && q < N && !isnan(raw[q])) win[c++] = raw[q];
        out[n] = c ? median(win, c) : NAN;
        if (c) any = 1;
    }
    if (!any) {
        for (int n = 0; n < N; n++) out[n] = vis_off;
    } else {
        double last = NAN;
        for (int n = 0; n < N; n++) { if (!isnan(out[n])) last = out[n]; else if (!isnan(last)) out[n] = last; }
        last = NAN;
        for (int n = N - 1; n >= 0; n--) { if (!isnan(out[n])) last = out[n]; else out[n] = last; }
    }
    free(raw);
    return out;
}

/* rms and max of the residuals of the syncs that fall on the fitted line (within 1.5 ms) */
static void fit_residuals(const sync_hit *h, int nh, const render_params *rp, double *rms, double *mx) {
    double s2 = 0.0, m = 0.0;
    int c = 0;
    for (int i = 0; i < nh; i++) {
        long n = lround((h[i].t - rp->a) / rp->b);
        if (n < 0 || n >= rp->nsync) continue;
        double r = fabs(h[i].t - (rp->a + rp->b * (double)n));
        if (r > 0.0015) continue;
        s2 += r * r; c++;
        if (r > m) m = r;
    }
    *rms = c ? sqrt(s2 / c) * 1e3 : 0.0;
    *mx = m * 1e3;
}

static void offsets_range(const double *lo, int n, double *mn, double *mx) {
    *mn = 1e9; *mx = -1e9;
    for (int i = 0; i < n; i++) { if (lo[i] < *mn) *mn = lo[i]; if (lo[i] > *mx) *mx = lo[i]; }
    if (n == 0) *mn = *mx = 0.0;
}

/* Scottie: which layout? In Barber's the picture runs right up to the sync and to the end of
 * red; Open-SSTV's has 1.5 ms at 1500 Hz just before the sync and after a shorter red (A1).
 * Both windows at black on nearly every line means Open-SSTV's. */
static scottie_layout detect_layout(const sample_buf *b, const render_params *rp, double off) {
    const sstv_mode *m = rp->mode;
    double k = rp->b / rp->b0;
    int lines = 0, black_both = 0;
    for (int n = 1; n < rp->nsync; n++) {
        double s = rp->a + rp->b * n;
        double r_end_open = s + (m->sync_ms + m->porch_ms + m->scan_ms - m->sep_ms) * 1e-3 * k;
        if (r_end_open + 1.2e-3 * k > rp->t_end) break;
        double f1 = sbuf_mean(b, s - 1.2e-3 * k, s - 0.3e-3 * k) - off;
        double f2 = sbuf_mean(b, r_end_open + 0.3e-3 * k, r_end_open + 1.2e-3 * k) - off;
        lines++;
        if (fabs(f1 - BLACK_HZ) < 40.0 && fabs(f2 - BLACK_HZ) < 40.0) black_both++;
    }
    if (lines >= 8 && black_both >= (int)(0.9 * lines)) return SCOTTIE_LAYOUT_OPEN;
    return SCOTTIE_LAYOUT_BARBER;
}

/* ---------------------------------------------------------------- finishing an image */

static double sync_threshold(double off) { return SYNC_HZ + off + 150.0; }
static int sync_smooth(const sample_buf *b, const sstv_mode *m) {
    int s = (int)lround(0.25 * m->sync_ms * 1e-3 / b->dt);
    return s < 1 ? 1 : s;
}

/* After the first fit (rp->a, rp->b): the tuning of every line from its sync; then every sync's
 * trailing edge again, at the level of its line (smoothed over 15 lines), and the straight line
 * fitted again. A pulse's own level can be pulled by an interfering signal; the smoothed one
 * cannot (test 5.3). h is changed in place. Returns the per-line offsets (to free). The decode
 * and a redraw after saving both come through here, so they give the same picture (3.9). */
static double *tune_and_refit(const sample_buf *b, sync_hit *h, int nh, render_params *rp, double vis_off,
                              int auto_tune, int fix_slope, int *used, int *last) {
    const sstv_mode *m = rp->mode;
    double *loff = line_offsets(b, h, nh, rp, vis_off, auto_tune);
    if (!loff || !auto_tune) return loff;
    double a, bb;
    for (int i = 0; i < nh; i++) {
        long n = lround((h[i].t - rp->a) / rp->b);
        if (n < 0 || n >= rp->nsync) continue;
        double te = edge_at(b, h[i].t + m->sync_ms * 1e-3, SYNC_HZ + loff[n] + 150.0, sync_smooth(b, m) / 2);
        if (te > 0.0) h[i].t = te - m->sync_ms * 1e-3;
    }
    *used = fit_syncs(h, nh, rp->nsync, rp->a, rp->b, rp->b0, fix_slope, &a, &bb, last);
    rp->a = a; rp->b = bb;
    free(loff);
    return line_offsets(b, h, nh, rp, vis_off, auto_tune);
}

/* Where a picture's data ends, from its fit: the buffer, never past the expected end (so that the
 * block size does not change it); a line after the last sync when the signal stopped (3.4); and a
 * line after the last trusted sync when the picture was closed early. */
static double picture_end(const sstv_rx *rx, const sample_buf *b, size_t i1, int input_ended, int nsync, int last,
                          double a, double bfit, double b0) {
    double t_end = sbuf_time(b, i1 - 1);
    /* a signal that stopped: the rows after the last sync are not part of the picture (3.4) */
    if (input_ended || last < 0 || nsync - 1 - last > 4) {
        double t_last = (last >= 0) ? a + bfit * last : a;
        double lim = t_last + 1.05 * bfit;
        if (lim < t_end) t_end = lim;
    }
    /* closed early (no sync on the period for 30 lines, or a new VIS): the picture ended a line after
       the last sync the stream watch trusted; pulses in the noise after it are not lines of it */
    if (rx->t_close_hint < 1e299 && rx->t_close_hint + 0.05 * b0 < t_end) t_end = rx->t_close_hint + 0.05 * b0;
    return t_end;
}

static void finish_image(sstv_rx *rx, int input_ended) {
    const sstv_mode *m = rx->mode;
    sample_buf *b = &rx->st;
    rx->state = ST_IDLE;
    /* the mode chosen by hand waits again for the next transmission, after this one: never the
       same transmission twice (a picture from its VIS, then again from its syncs) */
    if (rx->cfg.forced_mode != SSTV_MODE_NONE) {
        rx->forced_pending = 1;
        rx->forced_next = 0.0;
        rx->forced_from = rx->t_close_hint < rx->t_expected_end ? rx->t_close_hint : rx->t_expected_end;
        rx->forced_warned = 0;                 /* a new search: its warnings are new too (B2-7) */
    }
    if (!m || b->n == 0) return;
    size_t i0 = sbuf_index(b, rx->t_cap_start);
    size_t i1 = sbuf_index(b, rx->t_expected_end) + 1;
    if (i1 > b->n) i1 = b->n;
    if (i1 <= i0) return;
    int nsync = nsync_of(m);
    sync_hit *h = NULL;
    int nh = find_syncs(b, i0, i1, sync_threshold(rx->offset_hz), 0.55 * m->sync_ms * 1e-3,
                        1.6 * m->sync_ms * 1e-3, sync_smooth(b, m), m->sync_ms * 1e-3, &h);
    double b0 = m->line_ms * 1e-3;
    double a0 = rx->s0_expected;
    /* the anchor: the pulse nearest the expected first sync. Scottie's start sync, if sent, is
       288 ms earlier and falls outside the window (A2: it is not needed) */
    if (nh > 0) {
        double best = 1e9, bt = a0;
        for (int i = 0; i < nh && i < 8; i++) {
            double d = fabs(h[i].t - a0);
            if (d < best && d < 0.4 * b0) { best = d; bt = h[i].t; }
        }
        a0 = bt;
    }
    /* A26: a Robot 36 with ~300 ms lines is not Barber's structure: say so, give no picture. Never
       on a picture closed early: the pulses after the close are not lines of it (NUC-2) */
    if (m->family == SSTV_FAMILY_ROBOT36 && nh >= 6 && rx->t_close_hint >= 1e299) {
        double *iv = malloc((size_t)nh * sizeof(double));
        if (iv) {
            int ni = 0, n300 = 0, n150 = 0;
            for (int i = 1; i < nh; i++) {
                double d = h[i].t - h[i - 1].t;
                iv[ni++] = d;
                if (fabs(d / 0.30 - 1.0) <= 0.05) n300++;
                if (fabs(d / 0.15 - 1.0) <= 0.05) n150++;
            }
            double med = median(iv, ni);
            free(iv);
            /* and only when the pulses really come every 300 ms and almost never every 150 ms: a weak
               Barber picture that lost every other sync to the noise is not the other structure (NUC-2) */
            if (med > 0.27 && med < 0.33 && n300 >= 0.8 * ni && n150 <= 0.05 * ni) {
                event_note(rx, SSTV_NOTE_R36_300, SSTV_EV_WARNING, a0, m->vis, m->id, rx->offset_hz,
                           "Robot 36 amb línies de ~300 ms: no és la forma de Barber (150 ms); no es dona cap imatge (A26)");
                free(h);
                return;
            }
        }
    }
    /* the fit, from the mode's period and from the one the stream watch measured on its line (NUC-3,
       N-nucli-8); with the slant given by hand, from that one alone */
    double a, bfit;
    int last, used;
    if (rx->cfg.fit_slant) used = fit_from_both(h, nh, nsync, a0, b0, rx->sw_L, rx->sw_fit, 0.3 * m->sync_ms * 1e-3, &a, &bfit, &last);
    else used = fit_syncs(h, nh, nsync, a0, b0 * (1.0 + rx->cfg.preset_slant_ppm * 1e-6), b0, 1, &a, &bfit, &last);
#ifdef SSTV_DEBUG_WATCH
    fprintf(stderr, "finish: sw_fit %d nfit %d sw_L %.6f (b0 %.6f, %+.0f ppm) niv %d -> bfit %+.0f ppm used %d\n", rx->sw_fit, rx->sw_nfit,
            rx->sw_L, b0, (rx->sw_L / b0 - 1) * 1e6, rx->sw_niv, (bfit / b0 - 1) * 1e6, used);
#endif
    render_params rp;
    memset(&rp, 0, sizeof rp);
    rp.a = a; rp.b = bfit; rp.b0 = b0; rp.mode = m; rp.nsync = nsync;
    rp.offset_hz = rx->cfg.auto_tune ? rx->offset_hz : 0.0;
    rp.t_end = picture_end(rx, b, i1, input_ended, nsync, last, a, bfit, b0);
    rp.layout = SCOTTIE_LAYOUT_BARBER;
    if (m->family == SSTV_FAMILY_SCOTTIE)
        rp.layout = (rx->cfg.scottie == SCOTTIE_LAYOUT_AUTO) ? detect_layout(b, &rp, rx->offset_hz) : rx->cfg.scottie;
    /* the syncs as found are kept: a redraw starts again from them (3.9) */
    sync_hit *h_orig = malloc((size_t)(nh > 0 ? nh : 1) * sizeof *h_orig);
    if (h_orig) memcpy(h_orig, h, (size_t)nh * sizeof *h);
    double *loff = tune_and_refit(b, h, nh, &rp, rx->offset_hz, rx->cfg.auto_tune, !rx->cfg.fit_slant, &used, &last);
    a = rp.a; bfit = rp.b;
    /* a slant that leaves few of its pulses on its line (under a third of those used, or under 8, within
       1.5 ms) is not one: pulses of the noise after a cut picture gave an M1 -947 ppm with one pulse of 34
       on it (N3-nucli-vigilant-1). The mode's period, when it puts at least as many on their lines; said */
    if (rx->cfg.fit_slant && h_orig && fabs(bfit / b0 - 1.0) > 1e-6) {
        double sp;
        int near = fit_score(h, nh, nsync, a, bfit, 0.0015, &sp);
        if (3 * near < used || near < 8) {
            sync_hit *hn = malloc((size_t)(nh > 0 ? nh : 1) * sizeof *hn);
            if (hn) {
                memcpy(hn, h_orig, (size_t)nh * sizeof *hn);
                render_params rn = rp;
                int ln, un = fit_syncs(hn, nh, nsync, a0, b0, b0, 1, &rn.a, &rn.b, &ln);
                double *ln_off = tune_and_refit(b, hn, nh, &rn, rx->offset_hz, rx->cfg.auto_tune, 1, &un, &ln);
                int near_n = fit_score(hn, nh, nsync, rn.a, rn.b, 0.0015, &sp);
                if (near_n >= near) {
                    char txn[200];
                    snprintf(txn, sizeof txn, "%s: la inclinació (%+.0f ppm) deixava %d de %d sincronismes sobre la recta: "
                             "es fa servir el període del mode", m->name, (bfit / b0 - 1.0) * 1e6, near, used);
                    event_note(rx, SSTV_NOTE_SLANT_NOMINAL, SSTV_EV_WARNING, rn.a, m->vis, m->id, rx->offset_hz, txn);
                    memcpy(h, hn, (size_t)nh * sizeof *h);
                    free(loff);
                    loff = ln_off; ln_off = NULL;
                    rn.line_off = NULL;
                    rp = rn; used = un; last = ln;
                    a = rp.a; bfit = rp.b;
                    rp.t_end = picture_end(rx, b, i1, input_ended, nsync, last, a, bfit, b0);
                }
                free(ln_off);
                free(hn);
            }
        }
    }
    rp.line_off = loff;
    if (rx->nimg == rx->capimg) {
        int nc = rx->capimg ? rx->capimg * 2 : 8;
        sstv_image *ni = realloc(rx->imgs, (size_t)nc * sizeof *ni);
        if (!ni) { free(h); free(h_orig); free(loff); return; }
        rx->imgs = ni;
        retained_t *nr = realloc(rx->ret, (size_t)nc * sizeof *nr);
        if (!nr) { free(h); free(h_orig); free(loff); return; }
        rx->ret = nr;
        rx->capimg = nc;
    }
    sstv_image *im = &rx->imgs[rx->nimg];
    retained_t *rt = &rx->ret[rx->nimg];
    memset(im, 0, sizeof *im);
    memset(rt, 0, sizeof *rt);
    im->mode = m->id; im->width = m->width; im->height = m->height;
    im->rgb = calloc((size_t)m->width * m->height * 3, 1);
    if (!im->rgb) { free(h); free(h_orig); free(loff); return; }
    im->rows_received = render_image(b, &rp, rx->cfg.levels, im->rgb);
    if (im->rows_received <= 0) {
        /* the input ended (or Listen was turned off) before the first row: no picture of 0 rows (NUC-7) */
        free(im->rgb); im->rgb = NULL;
        memset(rt, 0, sizeof *rt);
        char tx0[120];
        snprintf(tx0, sizeof tx0, "%s: s'acaba abans de la primera fila: cap imatge", m->name);
        event_note(rx, SSTV_NOTE_NO_ROWS, SSTV_EV_WARNING, a0, m->vis, m->id, rx->offset_hz, tx0);   /* said on the screen too (N2-nucli-vigilant-6) */
        free(h); free(h_orig); free(loff);
        return;
    }
    fit_residuals(h, nh, &rp, &im->sync_rms_ms, &im->sync_max_ms);
    if (loff) offsets_range(loff, nsync, &im->offset_min_hz, &im->offset_max_hz);
    im->complete = (im->rows_received >= m->height);
    im->t_start = a; im->line_period_s = bfit; im->slant_ppm = (bfit / b0 - 1.0) * 1e6;
    im->syncs_found = nh; im->syncs_used = used; im->offset_hz = rx->offset_hz;
    im->layout_used = rp.layout;
    if (rx->cfg.keep_buffers) {
        /* keep the demodulated samples and the syncs until the user accepts the image (L3, 3.9) */
        rt->buf.dt = b->dt; rt->buf.t0 = b->t0; rt->buf.t0_set = 1; rt->buf.base = b->base + i0;
        for (size_t i = i0; i < i1; i++) sbuf_push(&rt->buf, b->f[i], b->a[i], 0.0);
        rt->hits = h_orig; rt->nhits = nh; h_orig = NULL;
        rt->line_off = loff; loff = NULL;
        rt->vis_off = rx->offset_hz;
        rt->rp = rp;
        rt->rp.line_off = rt->line_off;
        rt->valid = 1;
        im->retained = 1;
    }
    sstv_event e;
    memset(&e, 0, sizeof e);
    e.type = SSTV_EV_IMAGE; e.t = a; e.vis = m->vis; e.mode = m->id; e.offset_hz = rx->offset_hz;
    e.image_index = rx->nimg;
    snprintf(e.text, sizeof e.text, "%s: %d de %d files%s; %d de %d sincronismes; inclinació %+.1f ppm",
             m->name, im->rows_received, m->height,
             im->complete ? "" : (input_ended ? " (incompleta: s'acaba el senyal)" : " (incompleta)"),
             used, nsync, im->slant_ppm);
    rx->nimg++;
    push_event(rx, &e);
    free(h);
    free(h_orig);
    free(loff);
}

int sstv_rx_receiving(const sstv_rx *rx, sstv_mode_id *mode, int *width, int *height) {
    if (rx->state != ST_RECEIVING || !rx->mode) return 0;
    if (mode) *mode = rx->mode->id;
    if (width) *width = rx->mode->width;
    if (height) *height = rx->mode->height;
    return 1;
}

int sstv_rx_draw_partial(sstv_rx *rx, uint8_t *rgb) {
    if (rx->state != ST_RECEIVING || !rx->mode) return -1;
    const sstv_mode *m = rx->mode;
    sample_buf *b = &rx->st;
    size_t i0 = sbuf_index(b, rx->t_cap_start), i1 = rx->scan_i < b->n ? rx->scan_i : b->n;
    if (i1 <= i0 + 1) { memset(rgb, 0, (size_t)m->width * m->height * 3); return 0; }
    int nsync = nsync_of(m);
    sync_hit *h = NULL;
    int nh = find_syncs(b, i0, i1, sync_threshold(rx->offset_hz), 0.55 * m->sync_ms * 1e-3,
                        1.6 * m->sync_ms * 1e-3, sync_smooth(b, m), m->sync_ms * 1e-3, &h);
    double b0 = m->line_ms * 1e-3, a0 = rx->s0_expected;
    if (nh > 0) {                              /* the same anchor as the final picture */
        double best = 1e9, bt = a0;
        for (int i = 0; i < nh && i < 8; i++) {
            double d = fabs(h[i].t - a0);
            if (d < best && d < 0.4 * b0) { best = d; bt = h[i].t; }
        }
        a0 = bt;
    }
    /* as the final picture is fitted, so that the drawing on the way matches it (2.15) */
    double a, bfit;
    int last;
    if (rx->cfg.fit_slant && nh >= 16) fit_from_both(h, nh, nsync, a0, b0, rx->sw_L, rx->sw_fit, 0.3 * m->sync_ms * 1e-3, &a, &bfit, &last);
    else fit_syncs(h, nh, nsync, a0, rx->cfg.fit_slant ? b0 : b0 * (1.0 + rx->cfg.preset_slant_ppm * 1e-6), b0, 1, &a, &bfit, &last);
    free(h);
    render_params rp;
    memset(&rp, 0, sizeof rp);
    rp.a = a; rp.b = bfit; rp.b0 = b0; rp.mode = m; rp.nsync = nsync;
    rp.offset_hz = rx->cfg.auto_tune ? rx->offset_hz : 0.0;
    rp.t_end = sbuf_time(b, i1 - 1);
    rp.layout = SCOTTIE_LAYOUT_BARBER;
    if (m->family == SSTV_FAMILY_SCOTTIE)
        rp.layout = (rx->cfg.scottie == SCOTTIE_LAYOUT_AUTO) ? detect_layout(b, &rp, rx->offset_hz) : rx->cfg.scottie;
    return render_image(b, &rp, rx->cfg.levels, rgb);
}

int sstv_rx_rerender(sstv_rx *rx, int index, double extra_slant_ppm, double offset_ms) {
    if (index < 0 || index >= rx->nimg || !rx->ret[index].valid || !rx->imgs[index].rgb) return -1;
    retained_t *rt = &rx->ret[index];
    render_params rp = rt->rp;
    double bnew = rp.b * (1.0 + extra_slant_ppm * 1e-6);
    double a, bb;
    int last, used;
    /* the same path as the decode, from the syncs as they were found, with the new period */
    sync_hit *h = malloc((size_t)(rt->nhits > 0 ? rt->nhits : 1) * sizeof *h);
    if (!h) return -1;
    memcpy(h, rt->hits, (size_t)rt->nhits * sizeof *h);
    fit_syncs(h, rt->nhits, rp.nsync, rp.a, bnew, rp.b0, 1, &a, &bb, &last);
    rp.a = a; rp.b = bb;
    free(rt->line_off);
    rt->line_off = tune_and_refit(&rt->buf, h, rt->nhits, &rp, rt->vis_off, rx->cfg.auto_tune, 1, &used, &last);
    free(h);
    rp.a += offset_ms * 1e-3;
    rp.line_off = rt->line_off;
    rt->rp.line_off = rt->line_off;
    sstv_image *im = &rx->imgs[index];
    im->rows_received = render_image(&rt->buf, &rp, rx->cfg.levels, im->rgb);
    im->complete = (im->rows_received >= im->height);
    im->line_period_s = rp.b;
    im->slant_ppm = (rp.b / rp.b0 - 1.0) * 1e6;
    im->t_start = rp.a;
    return 0;
}

void sstv_rx_drop_pixels(sstv_rx *rx, int index) {
    if (index < 0 || index >= rx->nimg) return;
    sstv_rx_accept(rx, index);
    free(rx->imgs[index].rgb);
    rx->imgs[index].rgb = NULL;
}

void sstv_rx_accept(sstv_rx *rx, int index) {
    if (index < 0 || index >= rx->nimg) return;
    sbuf_free(&rx->ret[index].buf);
    free(rx->ret[index].hits);
    free(rx->ret[index].line_off);
    rx->ret[index].line_off = NULL;
    rx->ret[index].hits = NULL; rx->ret[index].nhits = 0;
    rx->ret[index].valid = 0;
    rx->imgs[index].retained = 0;
}

/* ---------------------------------------------------------------- VIS */

/* Power of a tone (audio frequency, Hz) over [ta, tb), on the stored complex baseband. */
static double tp(const sample_buf *b, double f_hz, double ta, double tb) {
    return sbuf_tone_power(b, f_hz - LEADER_HZ, ta, tb);
}

/* One tone test of the VIS: the tone wins against the others by `ratio` and carries at least a
 * tenth of all the power in its window. The second part is what keeps digital silence, noise and
 * picture content out (there the tone holds a tiny share of the window), and it does not depend
 * on how deep a fade is, since a fade lowers the tone and the window alike. Written so that zero
 * power fails: 0 > 0 is false. */
static int tone_wins(const sample_buf *b, double p, double other, double ratio, double ta, double tb) {
    return p > ratio * other && p > 0.1 * sbuf_power(b, ta, tb);
}

/* The VIS, read with narrow tone tests on the baseband: in each 30 ms bit, the power at 1100 Hz
 * against 1300 Hz (and 1200 Hz) over its middle 22 ms, shifted by the measured mistuning. In a
 * 45 Hz wide bin a tone stands some 17 dB higher above the noise than in the 2500 Hz of the
 * channel, which is why this reads a VIS far below the point where the instantaneous frequency
 * does. Only with the whole header in the buffer (the end of a file is not a VIS).
 * Returns 1 valid, 0 not a VIS, -1 bad parity, 2 the low byte of a 16-bit VIS (0x23, [MT]). */
static int vis_decode(const sample_buf *b, double t0, double off, int *code_out) {
    if (!sbuf_covers(b, t0, t0 + 0.300)) return 0;
    double ta = t0 + 0.004, tb = t0 + 0.026;
    double p12 = tp(b, 1200.0 + off, ta, tb);
    double p11 = tp(b, 1100.0 + off, ta, tb);
    double p13 = tp(b, 1300.0 + off, ta, tb);
    if (!tone_wins(b, p12, fmax(p11, p13), 1.5, ta, tb)) return 0;  /* the start bit, 1200 Hz */
    int bits = 0;
    for (int k = 0; k < 8; k++) {
        double tk = t0 + 0.030 * (k + 1);
        ta = tk + 0.004; tb = tk + 0.026;
        double q1 = tp(b, 1100.0 + off, ta, tb);
        double q0 = tp(b, 1300.0 + off, ta, tb);
        double q2 = tp(b, 1200.0 + off, ta, tb);
        double hi = fmax(q1, q0), lo = fmin(q1, q0);
        if (!tone_wins(b, hi, q2, 1.5, ta, tb)) return 0;           /* a bit is 1100 or 1300 Hz */
        if (!(hi > 2.0 * lo)) return 0;                             /* undecided: better no VIS than a wrong one */
        if (q1 > q0) bits |= 1 << k;                                /* 1100 Hz = 1, 1300 Hz = 0 */
    }
    *code_out = bits & 0x7F;
    if (bits == 0x23) return 2;
    ta = t0 + 0.274; tb = t0 + 0.296;
    double s12 = tp(b, 1200.0 + off, ta, tb);
    double s11 = tp(b, 1100.0 + off, ta, tb);
    double s13 = tp(b, 1300.0 + off, ta, tb);
    if (!tone_wins(b, s12, fmax(s11, s13), 1.5, ta, tb)) return 0;  /* the stop bit */
    int ones = __builtin_popcount((unsigned)(bits & 0x7F));
    if (((ones + ((bits >> 7) & 1)) & 1) != 0) return -1;
    return 1;
}

/* The leader before t0 (the second 300 ms tone): the strongest frequency within 150 Hz of
 * 1900 Hz, to 0.5 Hz, and how much it stands above the noise 200 Hz to either side. */
static double leader_check(const sample_buf *b, double t0, double *off_out) {
    double ta = t0 - 0.29, tb = t0 - 0.01;
    double best = -1.0, bf = 0.0;
    for (double df = -150.0; df <= 150.0; df += 4.0) {
        double p = tp(b, LEADER_HZ + df, ta, tb);
        if (p > best) { best = p; bf = df; }
    }
    double c = bf;
    for (double df = c - 4.0; df <= c + 4.0; df += 0.5) {
        double p = tp(b, LEADER_HZ + df, ta, tb);
        if (p > best) { best = p; bf = df; }
    }
    double side = 0.5 * (tp(b, LEADER_HZ + bf - 200.0, ta, tb) + tp(b, LEADER_HZ + bf + 200.0, ta, tb));
    *off_out = bf;
    return best / (side + 1e-30);
}

/* The start bit's edge, to 0.5 ms: where 1200 Hz takes over from the leader. */
static double refine_t0(const sample_buf *b, double t0, double off) {
    double best = -1e300, bt = t0;
    for (double tt = t0 - 0.012; tt <= t0 + 0.012 + 1e-9; tt += 0.0005) {
        double m = tp(b, 1200.0 + off, tt + 0.002, tt + 0.028) - tp(b, LEADER_HZ + off, tt + 0.002, tt + 0.028) +
                   tp(b, LEADER_HZ + off, tt - 0.028, tt - 0.002) - tp(b, 1200.0 + off, tt - 0.028, tt - 0.002);
        if (m > best) { best = m; bt = tt; }
    }
    return bt;
}

/* A pulse that looks like the chosen mode's sync: about its length, and at the sync frequency
 * over its middle half. Pulses in noise are mostly short and anywhere from 900 to 2500 Hz. */
static int sync_like(const sample_buf *b, const sync_hit *x, double nominal_s, double sync_hz) {
    if (x->dur < 0.75 * nominal_s || x->dur > 1.3 * nominal_s) return 0;
    return fabs(sbuf_mean(b, x->t + 0.25 * nominal_s, x->t + 0.75 * nominal_s) - sync_hz) < 100.0;
}

/* ---------------------------------------------------------------- the syncs as they stream past */

static void watch_start(sstv_rx *rx, double s0) {
    rx->t_last_sync = s0;
    rx->sw_L = rx->mode->line_ms * 1e-3 * (rx->cfg.fit_slant ? 1.0 : 1.0 + rx->cfg.preset_slant_ppm * 1e-6);
    rx->sw_Lmed = rx->sw_L;
    rx->sw_niv = 0; rx->sw_ivpos = 0; rx->sw_cand_strict = 0;
    rx->sw_cand = -1e300;
    rx->sw_locked = 0;
    rx->sw_rcount = 0; rx->sw_rpos = 0; rx->sw_nlast = 0;
    rx->sw_fit = 0; rx->sw_nfit = 0; rx->sw_a = s0; rx->sw_sigma = 0.0;
    rx->sw_relock = -1e300;
    rx->sw_run_start = -1.0;
    rx->sw_prev_low = 0;
    rx->t_watch = s0;
    rx->t_close_hint = 1e300;
}

/* A pulse that may be a sync of the picture being received, for the stream watch: as wide as the
 * picture's own fit takes them (find_syncs: 0.55 to 1.6 of a sync, NUC-1), and near the sync
 * frequency over its middle half (±150 Hz). The watch only decides when a picture is over, so a
 * wider test keeps a weak picture open; it never starts one. */
static int sync_like_watch(const sample_buf *b, const sync_hit *x, double nominal_s, double sync_hz) {
    if (x->dur < 0.55 * nominal_s || x->dur > 1.6 * nominal_s) return 0;
    return fabs(sbuf_mean(b, x->t + 0.25 * nominal_s, x->t + 0.75 * nominal_s) - sync_hz) < 150.0;
}

/* How long the stream watch waits with no sync before it calls a picture over: 30 lines, and at
 * least 12 s (30 lines of Robot 36 are only 4.5 s, an ordinary HF fade: NUC-4). */
static double watch_quiet(const sstv_rx *rx) {
    double L = rx->mode->line_ms * 1e-3;
    return 30.0 * L > 12.0 ? 30.0 * L : 12.0;
}

/* The straight line through the syncs kept: least squares, then once more without those more than 3
 * spreads off it (a pulse of the noise that fell on the period). Its slope is the period, as long as it
 * is within 2.5 % of the mode's; with fewer than 3 syncs, or less than 2 lines apart, there is no line,
 * and the period is the median of the last pairs. Many lines average out the jitter of each pulse in
 * a fade, which two lines in a row cannot (N-nucli-10, N-nucli-8). */
static void watch_refit(sstv_rx *rx) {
    int c = rx->sw_rcount;
    double L0 = rx->mode->line_ms * 1e-3;
    rx->sw_fit = 0;
    rx->sw_L = rx->sw_Lmed;
    if (c < 3) return;
    long nmin = rx->sw_rn[0], nmax = rx->sw_rn[0];
    for (int i = 1; i < c; i++) { if (rx->sw_rn[i] < nmin) nmin = rx->sw_rn[i]; if (rx->sw_rn[i] > nmax) nmax = rx->sw_rn[i]; }
    if (nmax - nmin < 2) return;
    /* relative to the last sync, so that hours of audio lose no precision */
    double tr = rx->t_last_sync;
    long nr = rx->sw_nlast;
    int keep[SW_RING];
    for (int i = 0; i < c; i++) keep[i] = 1;
    double a = 0.0, b = rx->sw_Lmed, sigma = 0.0;
    int used = 0;
    for (int pass = 0; pass < 2; pass++) {
        double sn = 0, st = 0, snn = 0, snt = 0;
        int k = 0;
        for (int i = 0; i < c; i++) {
            if (!keep[i]) continue;
            double n = (double)(rx->sw_rn[i] - nr), t = rx->sw_rt[i] - tr;
            sn += n; st += t; snn += n * n; snt += n * t; k++;
        }
        double den = k * snn - sn * sn;
        if (k < 3 || den <= 0.0) return;
        b = (k * snt - sn * st) / den;
        a = (st - b * sn) / k;
        used = k;
        double res[SW_RING];
        int m = 0;
        for (int i = 0; i < c; i++)
            if (keep[i]) res[m++] = fabs(rx->sw_rt[i] - tr - (a + b * (double)(rx->sw_rn[i] - nr)));
        sigma = 1.4826 * median(res, m);
        if (pass == 0 && c >= 8) {
            double lim = 3.0 * sigma > 0.0003 ? 3.0 * sigma : 0.0003;
            for (int i = 0; i < c; i++)
                if (fabs(rx->sw_rt[i] - tr - (a + b * (double)(rx->sw_rn[i] - nr))) > lim) keep[i] = 0;
        } else break;
    }
    if (fabs(b / L0 - 1.0) > 0.025) return;
    rx->sw_L = b;
    rx->sw_a = tr + a - b * (double)nr;
    rx->sw_sigma = sigma;
    rx->sw_fit = 1;
    rx->sw_nfit = used;
}

static void watch_add(sstv_rx *rx, long n, double t) {
    rx->sw_rn[rx->sw_rpos] = n; rx->sw_rt[rx->sw_rpos] = t;
    rx->sw_rpos = (rx->sw_rpos + 1) % SW_RING;
    if (rx->sw_rcount < SW_RING) rx->sw_rcount++;
    rx->sw_nlast = n; rx->t_last_sync = t;
    watch_refit(rx);
}

/* How well the watch was following the picture just before it lost it: the share of the 30 lines up to
 * the last sync it accepted that had a sync accepted. A strong picture that ends is followed on nearly
 * every line, and then not at all; a weak one is followed here and there all along (N2-nucli-vigilant-1). */
static double watch_rate(const sstv_rx *rx) {
    int n = 0;
    for (int i = 0; i < rx->sw_rcount; i++)
        if (rx->sw_rn[i] > rx->sw_nlast - 30 && rx->sw_rn[i] <= rx->sw_nlast) n++;
    return n / 30.0;
}

/* Locks on (or on again) with two pulses a line apart: the line starts again from them. */
static void watch_lock(sstv_rx *rx, double t_prev, double t) {
    rx->sw_rcount = 0; rx->sw_rpos = 0;
    rx->sw_locked = 1;
    rx->sw_relock = -1e300;
    watch_add(rx, 0, t_prev);
    watch_add(rx, 1, t);
}

/* Sample i of the stream, while a picture is being received: a run below the sync threshold that
 * is about a sync long, near 1200 Hz over its middle, and that falls on the period from the last
 * such sync (k whole lines later, within 0.5 % of a line or 0.2 % per line), is a sync of this
 * picture. Pulses in noise are mostly off the period, and the few that fall on it are rare. It
 * locks on with the first two such pulses on the period, wherever they are (a Scottie without its
 * start sync has its line syncs 9 ms earlier than the VIS says), up to 3 lines apart and within 2 %
 * per line, as far as the fit goes (NUC-3); from then on it follows the period it measures. */
static void watch_sample(sstv_rx *rx, size_t i, double t) {
    const sstv_mode *m = rx->mode;
    sample_buf *b = &rx->st;
    int half = sync_smooth(b, m) / 2;
    if ((size_t)half > i || i + (size_t)half >= b->n) return;
    double acc = 0.0;
    for (int k = -half; k <= half; k++) acc += b->f[i + k];
    double sm = acc / (2 * half + 1);
    double thr = sync_threshold(rx->offset_hz);
    int low = sm < thr;
    if (low && !rx->sw_prev_low) rx->sw_run_start = t;
    if (!low && rx->sw_prev_low && rx->sw_run_start >= 0.0) {
        double nominal = m->sync_ms * 1e-3, dur = t - rx->sw_run_start;
        sync_hit x = { rx->sw_run_start, dur };
        /* a pulse of the right size (sync_like) locks the watch and measures the period; once locked,
           a wider one (sync_like_watch) is enough to keep it (a weak picture). A sync glued to a VIS
           stop bit is longer and starts early: it never sets the period */
        int strict = sync_like(b, &x, nominal, SYNC_HZ + rx->offset_hz);
        if (strict || (rx->sw_locked && sync_like_watch(b, &x, nominal, SYNC_HZ + rx->offset_hz))) {
            double L = rx->sw_L, L0 = m->line_ms * 1e-3;
            double ref = rx->sw_locked ? rx->t_last_sync : rx->sw_cand;
            double d = x.t - ref, kk, r;
            if (rx->sw_locked && rx->sw_fit) {
                /* on the line fitted to the syncs so far: its line number, and how far from it */
                long n = lround((x.t - rx->sw_a) / L);
                kk = (double)(n - rx->sw_nlast);
                r = x.t - (rx->sw_a + L * (double)n);
            } else { kk = round(d / L); r = d - kk * L; }
            /* the next line: within the fit's 2 %; further on, 0.5 % of a line or 0.2 % per line, never
               more than 3 % (a pulse of the noise falls there less often: N-nucli-7); as far as the watch
               waits (its quiet time). A wider pulse, once locked, only near the line: four times the
               spread of the syncs about it */
            double tol = (kk == 1.0 ? 0.02 : (0.005 > 0.002 * kk ? 0.005 : 0.002 * kk)) * L;
            if (tol > 0.03 * L) tol = 0.03 * L;
            if (tol < 0.3 * nominal) tol = 0.3 * nominal;               /* the pulse's own jitter in noise */
            if (!strict && rx->sw_fit && rx->sw_nfit >= 8) {
                double near = 4.0 * rx->sw_sigma > 0.3 * nominal ? 4.0 * rx->sw_sigma : 0.3 * nominal;
                if (near < tol) tol = near;
            }
            int on = rx->sw_locked ? (kk >= 1.0 && kk <= ceil(watch_quiet(rx) / L0) + 2.0) : (kk == 1.0);
            if (on && fabs(r) < tol) {
                /* the period, before there is a line: the median of the last five pairs of syncs in a row of
                   the right size */
                if (kk == 1.0 && strict && rx->sw_cand_strict && fabs(d / L0 - 1.0) < 0.025) {
                    rx->sw_iv[rx->sw_ivpos] = d;
                    rx->sw_ivpos = (rx->sw_ivpos + 1) % 5;
                    if (rx->sw_niv < 5) rx->sw_niv++;
                    double v[5];
                    for (int k = 0; k < rx->sw_niv; k++) v[k] = rx->sw_iv[k];
                    rx->sw_Lmed = median(v, rx->sw_niv);
                }
                if (!rx->sw_locked) watch_lock(rx, rx->sw_cand, x.t);
                else watch_add(rx, rx->sw_nlast + (long)kk, x.t);
                rx->sw_cand_strict = strict;
                if (strict) rx->sw_relock = -1e300;
                /* a slower clock makes the picture longer: its end moves with the period measured on many
                   lines, never earlier (one pair in a fade can be 1 % off: N-nucli-4) */
                if (rx->sw_fit && rx->sw_nfit >= 8) {
                    double end = rx->s0_expected + (nsync_of(m) + 0.5) * rx->sw_L;
                    if (end > rx->t_expected_end) rx->t_expected_end = end;
                }
            } else if (!rx->sw_locked) { rx->sw_cand = x.t; rx->sw_cand_strict = strict; }
            else if (strict) {
                /* locked, and a pulse of the right size off the line: if the next one of the right size comes
                   a line after it, the watch had lost the line (a period measured a little off, and one sync
                   missed in a fade, N-nucli-10): it locks on again there */
                if (rx->sw_relock > -1e299 && fabs((x.t - rx->sw_relock) / L0 - 1.0) < 0.025) {
                    double tp = rx->sw_relock;
#ifdef SSTV_DEBUG_WATCH
                    fprintf(stderr, "relock at %.3f (nfit %d, sw_L %+.0f ppm)\n", x.t, rx->sw_nfit, (rx->sw_L / L0 - 1) * 1e6);
#endif
                    if (rx->sw_niv < 5) rx->sw_niv++;
                    rx->sw_iv[rx->sw_ivpos] = x.t - tp;
                    rx->sw_ivpos = (rx->sw_ivpos + 1) % 5;
                    double v[5];
                    for (int k = 0; k < rx->sw_niv; k++) v[k] = rx->sw_iv[k];
                    rx->sw_Lmed = median(v, rx->sw_niv);
                    watch_lock(rx, tp, x.t);
                    rx->sw_cand_strict = 1;
                } else rx->sw_relock = x.t;
            }
        }
        rx->sw_run_start = -1.0;
    }
    rx->sw_prev_low = low;
}

static void start_image(sstv_rx *rx, const sstv_mode *m, double t_vis_end, double off) {
    rx->mode = m;
    rx->offset_hz = off;
    double s0 = t_vis_end;
    if (m->family == SSTV_FAMILY_SCOTTIE)
        s0 = t_vis_end + (m->start_sync_ms + m->sep_ms + m->scan_ms + m->sep_ms + m->scan_ms) * 1e-3;
    rx->s0_expected = s0;
    rx->t_cap_start = t_vis_end - 0.05;
    rx->t_expected_end = s0 + (nsync_of(m) + 0.5) * m->line_ms * 1e-3;
    rx->t_check = s0 + 10.0 * m->line_ms * 1e-3;
    rx->period_checked = 0;
    rx->state = ST_RECEIVING;
    watch_start(rx, s0);
}

/* Test 3.11: after 10 lines, do the syncs come at the mode's period? At the period the stream watch
 * measured: a clock 1 % off is the right mode, and gives no warning (N-nucli-2); a wrong mode never
 * locks the watch, and its period stays the mode's. */
static void check_period(sstv_rx *rx) {
    const sstv_mode *m = rx->mode;
    sample_buf *b = &rx->st;
    rx->period_checked = 1;
    sync_hit *h = NULL;
    int nh = find_syncs(b, sbuf_index(b, rx->t_cap_start), sbuf_index(b, rx->t_check), sync_threshold(rx->offset_hz),
                        0.55 * m->sync_ms * 1e-3, 1.6 * m->sync_ms * 1e-3, sync_smooth(b, m), m->sync_ms * 1e-3, &h);
    double L = rx->sw_locked ? rx->sw_L : m->line_ms * 1e-3;
    int good = 0;
    for (int i = 1; i < nh; i++) {
        double d = h[i].t - h[i - 1].t;
        double k = round(d / L);
        if (k >= 1.0 && k <= 3.0 && fabs(d - k * L) < 0.005 * L) good++;
    }
    free(h);
    /* only when there are pulses of the right length and they do not fall on the period: with
       few pulses (a weak signal) the image says how many syncs it used */
    if (nh >= 4 && good < 0.25 * (nh - 1)) {
        char tx[160];
        snprintf(tx, sizeof tx, "%s: els sincronismes no quadren amb el període del mode (%d de %d intervals bons en 10 "
                 "línies): mode equivocat o senyal molt feble", m->name, good, nh - 1);
        event_note(rx, SSTV_NOTE_PERIOD_MISMATCH, SSTV_EV_WARNING, rx->t_check, m->vis, m->id, rx->offset_hz, tx);
    }
}

static void evaluate_candidate(sstv_rx *rx, double t_trig) {
    sample_buf *b = &rx->st;
    double lead_hz = band_median(b, t_trig - 0.12, t_trig - 0.02);
    double off = lead_hz - LEADER_HZ;
    double mid = 0.5 * (lead_hz + SYNC_HZ + off);
    /* a first edge: where a 3 ms average crosses the middle, in 0.05 ms steps */
    double t0 = t_trig - 0.004;
    for (double tt = t_trig - 0.012; tt < t_trig + 0.004; tt += 0.00005) {
        if (sbuf_mean(b, tt - 0.0015, tt + 0.0015) < mid) { t0 = tt; break; }
    }
    /* then the narrow tone tests: a real leader, its mistuning, and the edge again */
    double ratio = leader_check(b, t0, &off);
    if (ratio < 10.0) return;
    t0 = refine_t0(b, t0, off);
    ratio = leader_check(b, t0, &off);
    if (ratio < 10.0) return;
    int code = 0;
    int r = vis_decode(b, t0, off, &code);
#ifdef SSTV1_DEPURA
    fprintf(stderr, "candidat %.4f: t0 %.4f desintonia %.1f Hz (guia %.0f vegades sobre el soroll) -> %d (codi %d)\n",
            t_trig, t0, off, ratio, r, code);
#endif
    if (r == 0) return;
    if (rx->state == ST_RECEIVING) {
        /* F4: a good VIS after the picture had already lost its syncs (a sender that cut it and
           starts again) closes it, and the new picture starts. The header is 0.61 s of leader
           before t0: no sync on the period for 3 lines (and 1 s) before it means it had ended */
        const sstv_mode *mn = (r == 1) ? sstv_mode_by_vis(code) : NULL;
        double L = rx->mode->line_ms * 1e-3, quiet = 3.0 * L > 1.0 ? 3.0 * L : 1.0;
        if (mn && t0 - 0.61 - rx->t_last_sync > quiet) {
            char tx2[160];
            snprintf(tx2, sizeof tx2, "%s: sense sincronismes abans d'un VIS nou (%s): la imatge es tanca", rx->mode->name,
                     mn->name);
            event_note(rx, SSTV_NOTE_CLOSED_BY_VIS, SSTV_EV_WARNING, t0, code, rx->mode->id, off, tx2);
            /* where it ended: a line after the last sync on the period; but a weak picture whose syncs the
               watch never locked on (or lost for longer than it waits) keeps its rows up to the new
               header, never 1 row (N-nucli-1) */
            rx->t_close_hint = rx->t_last_sync + L;
            if (!rx->sw_locked || t0 - 0.61 - rx->t_last_sync > watch_quiet(rx)) rx->t_close_hint = t0 - 0.61;
            finish_image(rx, 0);
        } else {
            /* lesson L5: a header inside a picture that still has its syncs never restarts it (test 2.10) */
            event_text(rx, SSTV_EV_HEADER_IN_IMAGE, t0, r == 1 ? code : -1, rx->mode ? rx->mode->id : SSTV_MODE_NONE, off,
                       "Capçalera VIS dins de la imatge: la imatge continua");
            return;
        }
    }
    char tx[160];
    if (r == 2) {
        event_text(rx, SSTV_EV_VIS_16BIT, t0, code, SSTV_MODE_NONE, off,
                   "VIS de 16 bits (byte baix 0x23): encara no suportat");
    } else if (r == -1) {
        snprintf(tx, sizeof tx, "VIS rebutjat (paritat): codi %d", code);
        event_text(rx, SSTV_EV_VIS_REJECTED, t0, code, SSTV_MODE_NONE, off, tx);
    } else {
        const sstv_mode *m = sstv_mode_by_vis(code);
        if (!m) {
            snprintf(tx, sizeof tx, "VIS %d (0x%02X) desconegut: no és cap mode d'aquest receptor", code, code);
            event_text(rx, SSTV_EV_VIS_UNKNOWN, t0, code, SSTV_MODE_NONE, off, tx);
        } else {
            snprintf(tx, sizeof tx, "VIS %d: %s, desintonia %+.1f Hz", code, m->name, off);
            event_text(rx, SSTV_EV_VIS, t0, code, m->id, off, tx);
            start_image(rx, m, t0 + 0.300, off);
        }
    }
}

/* The time the signal starts in buffer [i0, n): the first sample above a tenth of the largest
 * amplitude; -1 if there is no signal. */
static double signal_start(const sample_buf *b, size_t i0, size_t n) {
    double amax = 0.0;
    for (size_t i = i0; i < n && i < b->n; i++) if (b->a[i] > amax) amax = b->a[i];
    if (amax <= 0.0) return -1.0;
    for (size_t i = i0; i < n && i < b->n; i++) if (b->a[i] > 0.1 * amax) return sbuf_time(b, i);
    return -1.0;
}

/* The first sync-like pulse that need - 1 more follow at whole lines (1 to 3 lines each, within
 * 0.5 % of a line): a picture's syncs keep the period, pulses in noise do not. Its index, or -1. */
static int first_chain(const sample_buf *b, const sync_hit *h, int nh, double L, double nominal_s, double sync_hz,
                       int need) {
    for (int i = 0; i + need - 1 < nh; i++) {
        if (!sync_like(b, &h[i], nominal_s, sync_hz)) continue;
        int n = 1;
        double last = h[i].t;
        for (int j = i + 1; j < nh && n < need; j++) {
            double d = h[j].t - last, k = round(d / L);
            if (k < 1.0) continue;
            if (k > 3.0) break;
            if (fabs(d - k * L) < 0.005 * L && sync_like(b, &h[j], nominal_s, sync_hz)) { n++; last = h[j].t; }
        }
        if (n >= need) return i;
    }
    return -1;
}

/* The share of samples in [i0, i1) outside the SSTV band (1000 to 2400 Hz, shifted by off): an
 * SSTV signal stays in it (sync 1200, VIS 1100-1300, picture 1500-2300); noise does not. */
static double sstv_out_of_band(const sample_buf *b, size_t i0, size_t i1, double off) {
    if (i1 > b->n) i1 = b->n;
    if (i1 <= i0) return 0.0;
    size_t out = 0;
    for (size_t i = i0; i < i1; i++) if (b->f[i] < 1000.0 + off || b->f[i] > 2400.0 + off) out++;
    return (double)out / (double)(i1 - i0);
}

/* Forced mode (no VIS, test 2.4): the first whole line is at the first sync of the right length
 * that the next ones follow at the mode's period. Only in the audio after the last picture. */
static void try_forced(sstv_rx *rx) {
    const sstv_mode *m = sstv_mode_by_id(rx->cfg.forced_mode);
    sample_buf *b = &rx->st;
    if (!m) { rx->forced_pending = 0; return; }
    size_t i0 = sbuf_index(b, rx->forced_from);
    if (rx->scan_i <= i0) return;
    sync_hit *h = NULL;
    double moff = rx->cfg.manual_offset_hz;
    double L = m->line_ms * 1e-3;
    int nh = find_syncs(b, i0, rx->scan_i, sync_threshold(moff), 0.55 * m->sync_ms * 1e-3, 1.6 * m->sync_ms * 1e-3,
                        sync_smooth(b, m), m->sync_ms * 1e-3, &h);
    int ic = first_chain(b, h, nh, L, m->sync_ms * 1e-3, SYNC_HZ + moff, rx->cfg.forced_chain > 1 ? rx->cfg.forced_chain : 5);
#ifdef SSTV1_DEPURA
    for (int k = 0; k < nh; k++)
        fprintf(stderr, "forçat: pols %.4f durada %.2f ms mitjana %.1f Hz%s\n", h[k].t, h[k].dur * 1e3,
                sbuf_mean(b, h[k].t + 0.25 * m->sync_ms * 1e-3, h[k].t + 0.75 * m->sync_ms * 1e-3), k == ic ? " <- cadena" : "");
#endif
    double t_sig = signal_start(b, i0, rx->scan_i);
    if (ic >= 0) {
        double s0 = h[ic].t;
        double gap = (m->start_sync_ms + m->sep_ms + 2.0 * m->scan_ms + m->sep_ms) * 1e-3;
        /* one whole line may come before the first sync found: right after digital silence the
           filter has not settled for a short sync (Martin, 4.862 ms). Only that one line, and only
           when the signal starts within it: never back into a header or into noise */
        double lead = (m->family == SSTV_FAMILY_SCOTTIE) ? (2.0 * m->scan_ms + 2.0 * m->sep_ms) * 1e-3 : 0.0;
        double back = s0 - L - lead;
        if (back >= t_sig - 0.003 && back < t_sig + 0.5 * L) s0 -= L;
        rx->mode = m; rx->offset_hz = moff;
        rx->s0_expected = s0;
        rx->t_cap_start = s0 - 0.3 * m->line_ms * 1e-3 - ((m->family == SSTV_FAMILY_SCOTTIE) ? gap : 0.0);
        rx->t_expected_end = s0 + (nsync_of(m) + 0.5) * m->line_ms * 1e-3;
        rx->t_check = s0 + 10.0 * m->line_ms * 1e-3;
        rx->period_checked = 0;
        rx->state = ST_RECEIVING;
        rx->forced_pending = 0;
        watch_start(rx, s0);
        event_note(rx, SSTV_NOTE_FORCED_START, SSTV_EV_WARNING, s0, -1, m->id, moff, "Sense VIS: mode triat a mà");
    } else if (!rx->forced_warned && t_sig >= 0.0 && sbuf_time(b, rx->scan_i - 1) - t_sig >= 10.0 * L) {
        /* test 3.11: never silent. After 10 lines of the chosen mode, no sync of its length; and
           said apart when there is only noise, so that it does not read like a wrong mode (B2-7) */
        char tx[160];
        double tn = sbuf_time(b, rx->scan_i - 1);
        size_t j0 = sbuf_index(b, tn - 10.0 * L);
        int noise = sstv_out_of_band(b, j0 > i0 ? j0 : i0, rx->scan_i, moff) > 0.30;
        if (noise)
            snprintf(tx, sizeof tx, "Mode %s triat a mà: en 10 línies només hi ha soroll, cap senyal d'SSTV", m->name);
        else
            snprintf(tx, sizeof tx, "Mode %s triat a mà: en 10 línies no hi ha cap sincronisme d'aquest mode; el període no quadra",
                     m->name);
        event_note(rx, noise ? SSTV_NOTE_FORCED_NOISE : SSTV_NOTE_FORCED_NO_SYNC, SSTV_EV_WARNING, tn, -1, m->id, 0.0, tx);
        rx->forced_warned = 1;
    }
    free(h);
}

static void process_stream(sstv_rx *rx, int at_end) {
    sample_buf *b = &rx->st;
    const int half10 = (int)lround(0.005 / b->dt);          /* 10 ms centred window */
    size_t lim = at_end ? b->n : (b->n > (size_t)half10 ? b->n - (size_t)half10 : 0);
    while (rx->scan_i < lim) {
        size_t i = rx->scan_i++;
        double t = sbuf_time(b, i);
        if (rx->state == ST_RECEIVING && !rx->period_checked && t >= rx->t_check) check_period(rx);
        if (rx->state == ST_RECEIVING && t >= rx->t_expected_end) finish_image(rx, 0);
        if (rx->state == ST_RECEIVING) {
            watch_sample(rx, i, t);
            /* B2-8 and F4: no sync on the period for 30 lines (and at least 12 s: 30 lines of Robot 36
               are only 4.5 s, an ordinary HF fade, NUC-4), the picture is over: a sender that
               stopped, or a picture started by hand in the middle that runs past its end. Only once
               the watch has clearly seen the picture's own syncs (three pairs of them a line apart, not
               necessarily in a row: more than a chance pair in the noise, N-nucli-3): a weak picture
               whose syncs it never caught runs to its expected end, as before (NUC-1) */
            double L = rx->mode->line_ms * 1e-3, quiet = watch_quiet(rx);
            if (t >= rx->t_watch) {
                rx->t_watch = t + L;
                /* and only when the watch was following the picture on most lines just before (60 % of the
                   last 30): a weak picture (AWGN 0 dB) is followed here and there all along (7 to 30 % of the
                   lines, measured), and 30 lines without a sync say nothing about its end; a picture that ends
                   was followed on 93 to 100 % of them. A weak one runs to its expected end, as before the watch
                   (N2-nucli-vigilant-1). The share of the band, tried first, did not tell the two apart */
                if (rx->sw_locked && rx->sw_niv >= 3 && t - rx->t_last_sync > quiet && t - rx->s0_expected > quiet &&
                    watch_rate(rx) >= 0.6) {
#ifdef SSTV_DEBUG_WATCH
                    {
                        size_t q0 = sbuf_index(b, t - 3.0), q1 = sbuf_index(b, t);
                        fprintf(stderr, "close at %.2f: out of band (last 3 s) %.3f, (since the last sync) %.3f, rate %.2f\n", t,
                                sstv_out_of_band(b, q0, q1, rx->offset_hz),
                                sstv_out_of_band(b, sbuf_index(b, rx->t_last_sync), q1, rx->offset_hz), watch_rate(rx));
                    }
#endif
                    char tx[160];
                    snprintf(tx, sizeof tx, "%s: %.0f línies sense sincronismes: la imatge es tanca", rx->mode->name, quiet / L);
                    event_note(rx, SSTV_NOTE_SYNC_LOST, SSTV_EV_WARNING, t, rx->mode->vis, rx->mode->id, rx->offset_hz, tx);
                    rx->t_close_hint = rx->t_last_sync + L;
                    finish_image(rx, 0);
                }
            }
        }
        /* forced mode: after 3 s of signal, look for the syncs every 0.5 s */
        if (rx->forced_pending && rx->state == ST_IDLE) {
            if (rx->forced_next == 0.0) rx->forced_next = t + 3.0;
            if (t >= rx->forced_next) { rx->forced_next = t + 0.5; try_forced(rx); }
        }
        /* due VIS candidates, in order */
        while (rx->ncand > 0 && t >= rx->cand[0].t_trig + 0.32) {
            double tt = rx->cand[0].t_trig;
            memmove(rx->cand, rx->cand + 1, (size_t)(rx->ncand - 1) * sizeof rx->cand[0]);
            rx->ncand--;
            evaluate_candidate(rx, tt);
        }
        /* leader tracking on a 10 ms centred average */
        double acc = 0.0; int cnt = 0;
        for (int k = -half10; k <= half10; k++) {
            long j = (long)i + k;
            if (j < 0 || (size_t)j >= b->n) continue;
            acc += b->f[j]; cnt++;
        }
        double s = acc / cnt;
        if (fabs(s - LEADER_HZ) < 250.0) {
            if (rx->run_start < 0.0) rx->run_start = t;
            rx->run_last = t;
            rx->was_low = 0;
        } else {
            if (rx->run_start >= 0.0 && t - rx->run_last > 0.015)
                rx->run_start = -1.0;                         /* a gap longer than 15 ms ends the run */
            /* loose on purpose: the narrow tone tests decide (evaluate_candidate) */
            if (s < LEADER_HZ - 150.0 && !rx->was_low) {
                rx->was_low = 1;
                if (rx->run_start >= 0.0 && rx->run_last - rx->run_start >= 0.15 && rx->ncand < MAXCAND) {
                    rx->cand[rx->ncand++].t_trig = t;
                    rx->run_start = -1.0;
                }
            }
        }
    }
    if (at_end && rx->forced_pending && rx->state == ST_IDLE) try_forced(rx);
    /* while idle, keep only the last 2 s (and what a pending VIS candidate needs); in forced mode,
       the last 10 s or 12 lines, what its search needs: the buffer and the search stay bounded on
       endless audio */
    if (rx->state == ST_IDLE && b->n > 0) {
        double keep = 2.0;
        if (rx->forced_pending) {
            const sstv_mode *fm = sstv_mode_by_id(rx->cfg.forced_mode);
            keep = fmax(10.0, fm ? 12.0 * fm->line_ms * 1e-3 : 0.0);
        }
        double keep_from = sbuf_time(b, rx->scan_i > 0 ? rx->scan_i - 1 : 0) - keep;
        /* a pending VIS candidate looks back up to 0.33 s from its trigger (evaluate_candidate) */
        if (rx->ncand > 0 && rx->cand[0].t_trig - 0.5 < keep_from) keep_from = rx->cand[0].t_trig - 0.5;
        size_t cut = sbuf_index(b, keep_from);
        size_t safe = rx->scan_i > (size_t)(2 * half10 + 2) ? rx->scan_i - (size_t)(2 * half10 + 2) : 0;
        if (cut > safe) cut = safe;
        if (cut > 0) {
            sbuf_drop(b, cut);
            rx->scan_i -= cut;
        }
    }
}

static int ensure_tmp(sstv_rx *rx, size_t need) {
    if (need <= rx->tcap) return 0;
    free(rx->tf); free(rx->ta); free(rx->ti); free(rx->tq); free(rx->tt);
    rx->tf = malloc(need * sizeof(float));
    rx->ta = malloc(need * sizeof(float));
    rx->ti = malloc(need * sizeof(float));
    rx->tq = malloc(need * sizeof(float));
    rx->tt = malloc(need * sizeof(double));
    if (!rx->tf || !rx->ta || !rx->ti || !rx->tq || !rx->tt) { rx->tcap = 0; return -1; }
    rx->tcap = need;
    return 0;
}

static int demod_push(sstv_rx *rx, const float *x, size_t n) {
    if (ensure_tmp(rx, n / (size_t)rx->dm.D + 2) != 0) return -1;
    size_t m = fm_demod_run_iq(&rx->dm, x, n, rx->tf, rx->ta, rx->ti, rx->tq, rx->tt, rx->tcap);
    for (size_t i = 0; i < m; i++)
        if (sbuf_push_iq(&rx->st, rx->tf[i], rx->ta[i], rx->ti[i], rx->tq[i], rx->tt[i]) != 0) return -1;
    return 0;
}

int sstv_rx_feed(sstv_rx *rx, const float *x, size_t n) {
    if (demod_push(rx, x, n) != 0) return -1;
    process_stream(rx, 0);
    return 0;
}

/* At the end of the input, push the last samples through the filter: a filter's length of zeros
 * brings out the outputs that were still waiting for samples after them. */
static void flush_demod(sstv_rx *rx) {
    size_t n = (size_t)rx->dm.ntaps;
    float *z = calloc(n, sizeof(float));
    if (!z) return;
    demod_push(rx, z, n);
    free(z);
}

int sstv_rx_finish(sstv_rx *rx) {
    flush_demod(rx);
    process_stream(rx, 1);
    /* candidates that never got their 320 ms: a header that does not fit in what came is not a
       VIS (vis_decode) */
    while (rx->ncand > 0) {
        double tt = rx->cand[0].t_trig;
        memmove(rx->cand, rx->cand + 1, (size_t)(rx->ncand - 1) * sizeof rx->cand[0]);
        rx->ncand--;
        evaluate_candidate(rx, tt);
    }
    if (rx->state == ST_RECEIVING) finish_image(rx, 1);
    return 0;
}
