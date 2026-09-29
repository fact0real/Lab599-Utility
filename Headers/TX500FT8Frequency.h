// Exact MHz entry for the Digital tab. The CAT command uses integer hertz.
// Accept only ASCII decimal input, with at most six fractional digits.
#import <Foundation/Foundation.h>

static inline BOOL TX500ParseDigitalDialMHz(NSString *text, uint64_t *hertz) {
    NSString *input = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *parts = [input componentsSeparatedByString:@"."];
    if (parts.count < 1 || parts.count > 2 || parts[0].length < 1 || parts[0].length > 2 ||
        (parts.count == 2 && (parts[1].length < 1 || parts[1].length > 6))) return NO;
    NSCharacterSet *nonDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
    for (NSString *part in parts) {
        if ([part rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return NO;
    }
    uint64_t mhz = (uint64_t)parts[0].integerValue;
    uint64_t fraction = parts.count == 2 ? (uint64_t)parts[1].integerValue : 0;
    for (NSUInteger i = parts.count == 2 ? parts[1].length : 0; i < 6; i++) fraction *= 10;
    uint64_t parsed = mhz * 1000000 + fraction;
    if (parsed < 500000 || parsed > 56000000) return NO;
    if (hertz) *hertz = parsed;
    return YES;
}
