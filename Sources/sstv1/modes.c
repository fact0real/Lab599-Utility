/* SPDX-License-Identifier: GPL-3.0-or-later
 * The mode table. Every number is from
 * JL Barber N7CXI, "Proposal for SSTV Mode Specifications", Dayton, 20 May 2000:
 * Martin p. 4, Scottie p. 3, Robot 36 p. 5, PD p. 9-10. Widths: Barber; Robot 36: 320 (A27,
 * Barber gives none; Bruchanov tables, MMSSTV). Heights include the 16-line header (A4).
 * Line periods are the sums of the parts, in double precision (test 1.2).
 */
#include <string.h>
#include <strings.h>
#include "sstv1.h"

static const sstv_mode MODES[] = {
    /* id               name          key      vis  family               w    h    sync   porch  sep    scan     chroma porch2 line     start */
    { SSTV_MODE_M1,    "Martin M1",  "M1",    44, SSTV_FAMILY_MARTIN,  320, 256, 4.862, 0.572, 0.572, 146.432,  0.0,  0.0, 446.446, 0.0 },
    { SSTV_MODE_M2,    "Martin M2",  "M2",    40, SSTV_FAMILY_MARTIN,  320, 256, 4.862, 0.572, 0.572,  73.216,  0.0,  0.0, 226.798, 0.0 },
    { SSTV_MODE_S1,    "Scottie S1", "S1",    60, SSTV_FAMILY_SCOTTIE, 320, 256, 9.0,   1.5,   1.5,   138.240,  0.0,  0.0, 428.220, 9.0 },
    { SSTV_MODE_S2,    "Scottie S2", "S2",    56, SSTV_FAMILY_SCOTTIE, 320, 256, 9.0,   1.5,   1.5,    88.064,  0.0,  0.0, 277.692, 9.0 },
    { SSTV_MODE_R36,   "Robot 36",   "R36",    8, SSTV_FAMILY_ROBOT36, 320, 240, 9.0,   3.0,   4.5,    88.000, 44.0,  1.5, 150.000, 0.0 },
    { SSTV_MODE_PD90,  "PD 90",      "PD90",  99, SSTV_FAMILY_PD,      320, 256, 20.0,  2.080, 0.0,   170.240,  0.0,  0.0, 703.040, 0.0 },
    { SSTV_MODE_PD120, "PD 120",     "PD120", 95, SSTV_FAMILY_PD,      640, 496, 20.0,  2.080, 0.0,   121.600,  0.0,  0.0, 508.480, 0.0 },
};

#define NMODES (sizeof MODES / sizeof MODES[0])

const sstv_mode *sstv_mode_by_id(sstv_mode_id id) {
    for (size_t i = 0; i < NMODES; i++) if (MODES[i].id == id) return &MODES[i];
    return NULL;
}

const sstv_mode *sstv_mode_by_vis(int vis) {
    for (size_t i = 0; i < NMODES; i++) if (MODES[i].vis == vis) return &MODES[i];
    return NULL;
}

const sstv_mode *sstv_mode_by_key(const char *key) {
    if (!key) return NULL;
    for (size_t i = 0; i < NMODES; i++) if (strcasecmp(MODES[i].key, key) == 0) return &MODES[i];
    return NULL;
}
