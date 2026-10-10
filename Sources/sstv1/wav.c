/* SPDX-License-Identifier: GPL-3.0-or-later
 * A small WAV reader for the core: PCM 8/16/24/32 bit, IEEE float 32/64, plain or
 * WAVE_FORMAT_EXTENSIBLE, any number of channels (mixed to mono). Read in blocks, so that a
 * three-hour file does not have to fit in memory (test 3.5). Written from the RIFF layout.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "wav.h"

static uint32_t le32(const unsigned char *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint16_t le16(const unsigned char *p) { return (uint16_t)(p[0] | p[1] << 8); }

int wav_open(wav_reader *w, const char *path, char *err, size_t errlen) {
    memset(w, 0, sizeof *w);
    w->f = fopen(path, "rb");
    if (!w->f) { snprintf(err, errlen, "no es pot obrir el fitxer"); return -1; }
    unsigned char h[12];
    if (fread(h, 1, 12, w->f) != 12 || memcmp(h, "RIFF", 4) || memcmp(h + 8, "WAVE", 4)) {
        snprintf(err, errlen, "no és un fitxer RIFF/WAVE"); fclose(w->f); w->f = NULL; return -1;
    }
    int have_fmt = 0;
    for (;;) {
        unsigned char ch[8];
        if (fread(ch, 1, 8, w->f) != 8) break;
        uint32_t len = le32(ch + 4);
        if (!memcmp(ch, "fmt ", 4)) {
            /* a fmt shorter than its 16 bytes is no fmt (N2-fax-app-2): nothing is read past what it has */
            if (len < 16) break;
            unsigned char fm[64] = {0};
            uint32_t r = len < sizeof fm ? len : (uint32_t)sizeof fm;
            if (fread(fm, 1, r, w->f) != r) break;
            if (len > r) fseek(w->f, (long)(len - r), SEEK_CUR);
            if (len & 1) fseek(w->f, 1, SEEK_CUR);
            w->format = le16(fm);
            w->channels = le16(fm + 2);
            w->rate = le32(fm + 4);
            w->block_align = le16(fm + 12);
            w->bits = le16(fm + 14);
            if (w->format == 0xFFFE && r >= 26) w->format = le16(fm + 24);   /* the sub-format GUID's first two bytes */
            have_fmt = 1;
        } else if (!memcmp(ch, "data", 4)) {
            if (!have_fmt) break;
            if ((w->format != 1 && w->format != 3) || w->channels == 0 || w->rate == 0 ||
                (w->format == 1 && w->bits != 8 && w->bits != 16 && w->bits != 24 && w->bits != 32) ||
                (w->format == 3 && w->bits != 32 && w->bits != 64) ||
                w->block_align != w->channels * (w->bits / 8) ||               /* a frame is what it says */
                w->rate < 4000 || w->rate > 192000 || w->channels > 8) {       /* and nothing out of all measure (SEG-15) */
                snprintf(err, errlen, "format no suportat (format %u, %u bits)", w->format, w->bits);
                fclose(w->f); w->f = NULL; return -1;
            }
            /* the samples that are there: a size of 0 or 0xFFFFFFFF (a recording still being written)
               or past the end of the file is the rest of the file (N2-fax-app-2) */
            long here = ftell(w->f);
            uint64_t rest = len;
            if (here >= 0 && fseek(w->f, 0, SEEK_END) == 0) {
                long end = ftell(w->f);
                fseek(w->f, here, SEEK_SET);
                uint64_t left = end > here ? (uint64_t)(end - here) : 0;
                if (len == 0 || len == 0xFFFFFFFFu || len > left) rest = left;
            }
            w->data_bytes = rest;
            w->frames = rest / w->block_align;
            if (w->frames == 0) {
                snprintf(err, errlen, "el fitxer no té cap mostra d'àudio");
                fclose(w->f); w->f = NULL; return -1;
            }
            return 0;
        } else {
            fseek(w->f, (long)(len + (len & 1)), SEEK_CUR);
        }
    }
    snprintf(err, errlen, "falta el tros fmt o data");
    fclose(w->f); w->f = NULL;
    return -1;
}

size_t wav_read(wav_reader *w, float *out, size_t frames) {
    if (!w->f || w->pos >= w->frames) return 0;
    if (frames > w->frames - w->pos) frames = (size_t)(w->frames - w->pos);
    size_t bytes = frames * w->block_align;
    unsigned char *buf = malloc(bytes ? bytes : 1);
    if (!buf) return 0;
    size_t got = fread(buf, 1, bytes, w->f) / w->block_align;
    int bps = w->bits / 8;
    for (size_t i = 0; i < got; i++) {
        double acc = 0.0;
        for (unsigned c = 0; c < w->channels; c++) {
            const unsigned char *p = buf + i * w->block_align + (size_t)c * bps;
            double v;
            if (w->format == 3) {
                if (w->bits == 32) { float x; memcpy(&x, p, 4); v = x; }
                else { double x; memcpy(&x, p, 8); v = x; }
            } else if (w->bits == 8) v = ((int)p[0] - 128) / 128.0;
            else if (w->bits == 16) v = (int16_t)le16(p) / 32768.0;
            else if (w->bits == 24) { int32_t x = (int32_t)((uint32_t)p[0] << 8 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 24); v = (x >> 8) / 8388608.0; }
            else v = (int32_t)le32(p) / 2147483648.0;
            acc += v;
        }
        out[i] = (float)(acc / w->channels);
    }
    free(buf);
    w->pos += got;
    return got;
}

void wav_close(wav_reader *w) {
    if (w->f) fclose(w->f);
    w->f = NULL;
}
