/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef SSTV1_WAV_H
#define SSTV1_WAV_H
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

typedef struct {
    FILE *f;
    unsigned format, channels, rate, block_align, bits;
    uint64_t data_bytes, frames, pos;
} wav_reader;

int wav_open(wav_reader *w, const char *path, char *err, size_t errlen);
/* Up to frames mono samples in [-1, 1); returns how many. */
size_t wav_read(wav_reader *w, float *out, size_t frames);
void wav_close(wav_reader *w);

#endif
