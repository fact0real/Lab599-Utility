#import <Foundation/Foundation.h>

// CAT rev. 3 does not assign a mode name to these observed numeric replies.
// Keep the raw code visible instead of guessing DIG-L, DIG-R or FSK.
static inline NSString *TX500UndocumentedModeLabel(NSInteger code) {
    return [NSString stringWithFormat:@"MD%ld (undocumented)", (long)code];
}

static inline NSString *TX500CATModeLabel(NSInteger code) {
    switch (code) {
        case 0: return @"MD0 (no mode)";
        case 1: return @"LSB";
        case 2: return @"USB";
        case 3: return @"CW";
        case 4: return @"FM";
        case 5: return @"AM";
        case 6: return @"DIG";
        case 7: return @"CWR";
        case 8:
        case 9: return TX500UndocumentedModeLabel(code);
        default: return [NSString stringWithFormat:@"MD%ld (unknown)", (long)code];
    }
}
