/* SPDX-License-Identifier: GPL-3.0-or-later
 *
 * sstv1: the receive core of Lab599 Utility's native SSTV and radiofax.
 * Plain C99, no windows, no audio devices: samples in, images and events out.
 *
 * Written from scratch from the published descriptions (JL Barber N7CXI, "Proposal for SSTV Mode
 * Specifications", 2000, for SSTV; WMO-No. 386 Part III section 5 for radiofax). Before it was
 * written, other programs' code (fldigi's WEFAX, Open-SSTV's decoder) was read to draw ideas and
 * lessons from it, and nothing was copied from it: the lessons (L1-L8) and the second Robot 36
 * structure (A26) come from there.
 *
 * Input contract:
 *  - fs is a parameter; nothing inside assumes a sample rate;
 *  - every period is carried in samples or seconds as a double and is never rounded;
 *  - the caller gives mono float samples in blocks of any size (but see TC-5: the fax receiver
 *    loses its last few ms if every block is shorter than its filter); nothing is resampled outside.
 */
#ifndef SSTV1_H
#define SSTV1_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ---------------------------------------------------------------- modes */

typedef enum {
    SSTV_MODE_NONE = 0,
    SSTV_MODE_M1, SSTV_MODE_M2,
    SSTV_MODE_S1, SSTV_MODE_S2,
    SSTV_MODE_R36,
    SSTV_MODE_PD90, SSTV_MODE_PD120,
    SSTV_MODE_COUNT
} sstv_mode_id;

typedef enum { SSTV_FAMILY_MARTIN, SSTV_FAMILY_SCOTTIE, SSTV_FAMILY_ROBOT36, SSTV_FAMILY_PD } sstv_family;

typedef struct {
    sstv_mode_id id;
    const char *name;       /* "Martin M1" */
    const char *key;        /* "M1" (command line) */
    int vis;                /* 7-bit VIS code, Barber 2000 */
    sstv_family family;
    int width, height;      /* pixels; height includes the 16-line header where the mode has one */
    double sync_ms;         /* horizontal sync pulse */
    double porch_ms;        /* gap after the sync */
    double sep_ms;          /* gap between colour scans (Martin, Scottie) */
    double scan_ms;         /* one colour (RGB) or one Y scan (YCbCr) */
    double chroma_ms;       /* Robot 36: one R-Y or B-Y scan */
    double porch2_ms;       /* Robot 36: the 1.5 ms porch at 1900 Hz before the colour scan */
    double line_ms;         /* sync to sync (PD: one sync period = two picture lines) */
    double start_sync_ms;   /* Scottie: the extra sync of the first line only (Barber p. 3) */
} sstv_mode;

const sstv_mode *sstv_mode_by_id(sstv_mode_id id);
const sstv_mode *sstv_mode_by_vis(int vis);
const sstv_mode *sstv_mode_by_key(const char *key);

/* ---------------------------------------------------------------- options */

typedef enum { SSTV_LEVELS_STUDIO = 0, SSTV_LEVELS_FULL = 1 } sstv_levels;           /* A11 */
typedef enum { SCOTTIE_LAYOUT_AUTO = 0, SCOTTIE_LAYOUT_BARBER, SCOTTIE_LAYOUT_OPEN } scottie_layout; /* A1 */

typedef struct {
    sstv_levels levels;            /* YCbCr scale; default studio (Barber Appendix B) */
    scottie_layout scottie;        /* default auto */
    sstv_mode_id forced_mode;      /* NONE = from the VIS; otherwise decode without VIS (test 2.4) */
    int keep_buffers;              /* 1: keep the demodulated samples of each image until accepted */
    int auto_tune;                 /* 1 (default): correct the pixel values by the offset measured on the leader */
    int fit_slant;                 /* 1 (default): fit the line period to the syncs; 0: keep the nominal one */
    double preset_slant_ppm;       /* period used when fit_slant is 0: nominal * (1 + ppm / 1e6) */
    double manual_offset_hz;       /* forced mode only: the mistuning given by hand (no leader to measure it) */
    int forced_chain;              /* forced mode: syncs in a row at the period before a picture starts
                                      (0 = the default, 5; the tests try 3 to see the margin) */
} sstv_rx_config;

void sstv_rx_config_default(sstv_rx_config *c);

/* ---------------------------------------------------------------- events */

typedef enum {
    SSTV_EV_VIS = 1,          /* a valid VIS: mode, code, tuning offset */
    SSTV_EV_VIS_REJECTED,     /* parity error: no image */
    SSTV_EV_VIS_UNKNOWN,      /* valid parity, code not in our table: no image, never silent */
    SSTV_EV_VIS_16BIT,        /* low byte 0x23: MMSSTV 16-bit VIS, not supported (yet) */
    SSTV_EV_HEADER_IN_IMAGE,  /* a header turned up inside an image: the image goes on (test 2.10) */
    SSTV_EV_IMAGE,            /* an image is ready (complete or not) */
    SSTV_EV_WARNING           /* anything else worth saying, in text */
} sstv_event_type;

/* What a warning is about, for a screen that says it in its own words. */
typedef enum {
    SSTV_NOTE_NONE = 0,
    SSTV_NOTE_FORCED_START,      /* no VIS: the picture starts with the mode chosen by hand */
    SSTV_NOTE_FORCED_NO_SYNC,    /* mode chosen by hand: there is a signal, but in 10 lines no sync of that mode */
    SSTV_NOTE_FORCED_NOISE,      /* mode chosen by hand: in 10 lines only noise */
    SSTV_NOTE_PERIOD_MISMATCH,   /* 10 lines in: the syncs do not fall on the mode's period (wrong mode?) */
    SSTV_NOTE_R36_300,           /* Robot 36 with ~300 ms lines: not Barber's structure, no picture (A26) */
    SSTV_NOTE_SYNC_LOST,         /* 30 lines with no sync on the period, and at least 12 s: the picture is closed */
    SSTV_NOTE_CLOSED_BY_VIS,     /* a good VIS came after the picture had lost its syncs: closed, the new one starts */
    SSTV_NOTE_SLANT_NOMINAL,     /* the slant fit left few of its syncs on its line: the mode's period is used */
    SSTV_NOTE_NO_ROWS            /* the input ended (or Listen was turned off) before the first row: no picture */
} sstv_note;

typedef struct {
    sstv_event_type type;
    sstv_note note;           /* SSTV_EV_WARNING: what it is about (the picture it closes does not carry it: NUC-8) */
    double t;                 /* seconds from the first input sample */
    int vis;                  /* code, or -1 */
    sstv_mode_id mode;
    double offset_hz;         /* measured mistuning of the leader (VIS events) */
    int image_index;          /* SSTV_EV_IMAGE */
    char text[160];
} sstv_event;

/* ---------------------------------------------------------------- images */

typedef struct {
    sstv_mode_id mode;
    int width, height;        /* allocated size */
    int rows_received;        /* rows with data; < height when the signal stopped early */
    int complete;             /* 1 = every row received */
    uint8_t *rgb;             /* width * height * 3 */
    double t_start;           /* time of the first sync used */
    double line_period_s;     /* fitted, sync to sync */
    double slant_ppm;         /* fitted period against the nominal one, in parts per million */
    int syncs_found, syncs_used;
    double offset_hz;         /* tuning offset measured on the leader (VIS) */
    double offset_min_hz, offset_max_hz; /* the per-line offsets applied, measured on the syncs */
    double sync_rms_ms, sync_max_ms;     /* residuals of the syncs used, against the fitted line */
    scottie_layout layout_used;
    int retained;             /* demodulated samples still held (keep_buffers) */
} sstv_image;

typedef struct sstv_rx sstv_rx;

sstv_rx *sstv_rx_new(double fs, const sstv_rx_config *cfg);
void sstv_rx_free(sstv_rx *rx);
/* Feed mono samples (any count). Returns 0, or -1 on allocation failure. */
int sstv_rx_feed(sstv_rx *rx, const float *x, size_t n);
/* End of input: an image in progress is finished as incomplete. */
int sstv_rx_finish(sstv_rx *rx);
/* Next pending event, in order; 1 if one was copied, 0 if none. */
int sstv_rx_next_event(sstv_rx *rx, sstv_event *ev);
int sstv_rx_image_count(const sstv_rx *rx);
const sstv_image *sstv_rx_image(const sstv_rx *rx, int index);
/* Re-render a retained image with a slant correction (ppm, on top of the period in use) and a
 * time offset (ms). The line start is fitted again to the syncs with the new period, exactly as
 * a decode with that period would do, so correcting after saving equals correcting before (3.9). */
int sstv_rx_rerender(sstv_rx *rx, int index, double extra_slant_ppm, double offset_ms);
/* The user accepted the image: its demodulated samples are freed. */
void sstv_rx_accept(sstv_rx *rx, int index);
/* The caller has stored the picture: accept it and free its pixels too (the report stays). */
void sstv_rx_drop_pixels(sstv_rx *rx, int index);

/* Progressive drawing (phase 2). While a picture is being received, sstv_rx_receiving gives its
 * mode and size (returns 1; 0 when none is), and sstv_rx_draw_partial draws into rgb (width *
 * height * 3 bytes) the rows that have arrived so far, with the line timing fitted to the syncs
 * found so far and the leader's tuning (no per-line tuning yet). It returns the rows drawn, or -1
 * when no picture is being received. The picture of SSTV_EV_IMAGE replaces it: that one counts. */
int sstv_rx_receiving(const sstv_rx *rx, sstv_mode_id *mode, int *width, int *height);
int sstv_rx_draw_partial(sstv_rx *rx, uint8_t *rgb);

/* ---------------------------------------------------------------- radiofax */

/* Where a fax line starts (A22): the standard by default; fldigi's way
 * (the middle of the phasing band, 2.5 % of a line later) is recognised and can be chosen; or the
 * picture's own seam decides. */
typedef enum {
    WEFAX_LINE_START_STANDARD = 0,   /* the leading edge of the white phasing pulse (WMO-No. 386, §5.2.3.4) */
    WEFAX_LINE_START_FLDIGI,         /* the middle of the phasing band: + 2.5 % of a line */
    WEFAX_LINE_START_AUTO            /* the picture's seam (where a line that leaves on the right comes back) */
} wefax_line_start;

typedef struct {
    double deviation_hz;      /* 400 (WMO, HF) by default; 425 (DWD); 150 (LF) and 300 also (A20) */
    double center_hz;         /* 1900 */
    int ioc;                  /* 576 (the default) or 288 */
    double lpm;               /* 120 (the default); 60, 90, 240 */
    int width;                /* 0 = round(pi * ioc) (A36) */
    int start_now;            /* 1: no start or phasing expected; start at the first sample (test F3b) */
    int flip;                 /* 1: turn the picture upside down (A29) */
    int keep_buffers;
    int auto_tune;            /* 1 (default): measure the black and white levels on the start signal and phasing */
    int fit_slant;            /* 1 (default): refine the line period on the picture; 0: phasing or nominal only */
    double preset_slant_ppm;  /* when fit_slant is 0 and there is no phasing: nominal * (1 + ppm / 1e6) */
    double preset_offset_ms;  /* margin shift applied to the line start before rendering (test 3.9) */
    double max_lines;         /* one chart with no stop signal: 4000 lines at most */
    wefax_line_start line_start;  /* the standard by default */
} wefax_rx_config;

void wefax_rx_config_default(wefax_rx_config *c);

/* What a fax warning is about, so that a screen can say it in its own words (the event's text is
 * the core's own, in Catalan, for its reports). */
typedef enum {
    WEFAX_NOTE_NONE = 0,
    WEFAX_NOTE_PHASING_UNRELIABLE,    /* the phasing's levels or edges cannot be trusted */
    WEFAX_NOTE_DEVIATION_DIFFERS,     /* value: the deviation measured on the phasing */
    WEFAX_NOTE_NO_LINES,              /* a chart with no line of picture: nothing saved */
    WEFAX_NOTE_NO_MEMORY,
    WEFAX_NOTE_INVERTED_WHITE_FIRST,  /* inverted 5/95: the dead sector says the line starts at the white */
    WEFAX_NOTE_POLARITY_UNDECIDED,    /* symmetric phasing: the dead sector cannot tell */
    WEFAX_NOTE_INVERTED_UNDECIDED,    /* inverted 5/95: the dead sector cannot tell the edge (TC-1) */
    WEFAX_NOTE_DEAD_SECTOR_ELSEWHERE, /* value: points */
    WEFAX_NOTE_FLDIGI_STYLE,          /* value: points; the lines start as fldigi's do */
    WEFAX_NOTE_SEAM_MARGIN,           /* value: points the seam moved the margin */
    WEFAX_NOTE_MARGIN_UNKNOWN,        /* no phasing and no dead sector */
    WEFAX_NOTE_INCOMPLETE,            /* the chart is saved as incomplete */
    WEFAX_NOTE_PHASING_STRICT,        /* after a chart closed by the line limit: only a clear phasing starts one */
    WEFAX_NOTE_LPM_MISMATCH,          /* value: the speed the phasing has */
    WEFAX_NOTE_NO_PHASING_AFTER_START,
    WEFAX_NOTE_START_IN_PICTURE,      /* a short piece of start signal inside a chart: ignored */
    WEFAX_NOTE_ENDS_WITHOUT_STOP,
    WEFAX_NOTE_START_WITHOUT_PICTURE,
    WEFAX_NOTE_SIGNAL_LOST,           /* a cut: the lines go on in their place, and come out grey */
    WEFAX_NOTE_SIGNAL_BACK,           /* value: seconds lost */
    WEFAX_NOTE_CLOSED_BY_START,       /* a chart with no stop, closed (and saved) by the next one's start */
    WEFAX_NOTE_CLOSED_BY_PHASING,     /* the same, by the next one's phasing */
    WEFAX_NOTE_LINE_LIMIT,            /* closed at the line limit */
    WEFAX_NOTE_SEAM_CONFIRMS          /* value: points; Auto-align: a clear seam within 2 points of the start confirms it */
} wefax_note;

typedef enum {
    WEFAX_EV_START = 1,       /* start signal: alternation (WMO) or a plain tone (fldigi) */
    WEFAX_EV_PHASING,         /* phasing found: form, polarity, period */
    WEFAX_EV_STOP,            /* stop signal */
    WEFAX_EV_IMAGE,           /* an image is ready */
    WEFAX_EV_WARNING
} wefax_event_type;

typedef struct {
    wefax_event_type type;
    double t;
    double value;             /* start/stop: alternation or tone frequency; phasing: period in ms */
    int plain_tone;           /* start/stop: 1 = plain audio tone (fldigi), 0 = black/white alternation */
    int image_index;
    wefax_note note;          /* warnings: what it is about */
    char text[160];
} wefax_event;

typedef struct {
    int width, height, rows_received, complete;
    uint8_t *gray;            /* width * height */
    double line_period_s;     /* the period used (fitted) */
    double slant_ppm;         /* against 60 / lpm */
    double t_first_line;
    int phasing_found;        /* 0 = none, 1 = 5/95, 2 = symmetric */
    int phasing_inverted;
    int phasing_lines;        /* lines of phasing used for the fit */
    double offset_hz;         /* tuning offset measured and applied */
    double deviation_measured_hz; /* half the distance between the measured black and white */
    int margin_source;        /* 0 = none (start at hand or unknown), 1 = phasing, 2 = dead sector, 3 = the picture's seam,
                                 4 = phasing, fldigi's way (+ 2.5 % of a line) */
    int fldigi_style_seen;    /* the seam says the lines start as fldigi starts them (said, not applied, by default) */
    int margin_seam_px;       /* margin_source 3: the shift applied, in pixels */
    double slant_refined_ppm; /* the part of the slant found on the picture itself */
    int lost_lines;           /* lines inside a cut: kept in their place, grey */
    int retained;
} wefax_image;

typedef struct wefax_rx wefax_rx;

wefax_rx *wefax_rx_new(double fs, const wefax_rx_config *cfg);
void wefax_rx_free(wefax_rx *rx);
int wefax_rx_feed(wefax_rx *rx, const float *x, size_t n);
int wefax_rx_finish(wefax_rx *rx);
int wefax_rx_next_event(wefax_rx *rx, wefax_event *ev);
int wefax_rx_image_count(const wefax_rx *rx);
const wefax_image *wefax_rx_image(const wefax_rx *rx, int index);
int wefax_rx_rerender(wefax_rx *rx, int index, double extra_slant_ppm, double offset_ms);
void wefax_rx_accept(wefax_rx *rx, int index);
void wefax_rx_drop_pixels(wefax_rx *rx, int index);

#ifdef __cplusplus
}
#endif
#endif
