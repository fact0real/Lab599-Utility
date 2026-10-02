#import <Foundation/Foundation.h>

// CAT rev. 3 does not assign a mode name to these observed numeric replies.
// Keep the raw code visible instead of guessing DIG-L, DIG-R or FSK.
static inline NSString *TX500UndocumentedModeLabel(NSInteger code) {
    return [NSString stringWithFormat:@"MD%ld (undocumented)", (long)code];
}
