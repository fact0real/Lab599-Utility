// Exact MHz entry for the Digital tab. The CAT command uses integer hertz.
// Accept only ASCII decimal input, with at most six fractional digits.
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

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

static inline uint64_t TX500FrequencyFromCATReply(NSString *reply) {
    if (reply.length != 14 || ![reply hasPrefix:@"FA"] || ![reply hasSuffix:@";"]) return 0;
    NSString *digits = [reply substringWithRange:NSMakeRange(2, 11)];
    NSCharacterSet *nonDigits = [NSCharacterSet characterSetWithCharactersInString:@"0123456789"].invertedSet;
    if ([digits rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return 0;
    uint64_t hz = (uint64_t)digits.longLongValue;
    return (hz >= 500000 && hz <= 56000000) ? hz : 0;
}

// Read-only RX, dial and mode checks surround the one possible MD6 write.
// Call this off the main thread; it never keys the transmitter or changes the dial.
static inline BOOL TX500EnsureDigitalCAT(BOOL (^send)(NSString *),
                                         NSString * _Nullable (^query)(NSString *, NSTimeInterval),
                                         uint64_t * _Nullable confirmedHz,
                                         NSString * _Nullable * _Nullable failure) {
    if (!send || !query) {
        if (failure) *failure = @"CAT control is unavailable.";
        return NO;
    }
    if (![query(@"PT;", 0.8) isEqualToString:@"PT0;"]) {
        if (failure) *failure = @"Radio RX was not confirmed; DIG mode was not changed.";
        return NO;
    }
    uint64_t initialHz = TX500FrequencyFromCATReply(query(@"FA;", 0.8));
    if (!initialHz) {
        if (failure) *failure = @"The radio dial could not be read; DIG mode was not changed.";
        return NO;
    }
    if (confirmedHz) *confirmedHz = initialHz;
    NSString *mode = query(@"MD;", 0.8);
    if (![mode isEqualToString:@"MD6;"]) {
        if (!send(@"MD6;")) {
            if (failure) *failure = @"The DIG mode command was rejected.";
            return NO;
        }
        for (NSUInteger attempt = 0; attempt < 4; attempt++) {
            [NSThread sleepForTimeInterval:0.15];
            mode = query(@"MD;", 0.8);
            if ([mode isEqualToString:@"MD6;"]) break;
        }
    }
    uint64_t finalHz = TX500FrequencyFromCATReply(query(@"FA;", 0.8));
    BOOL rxConfirmed = [query(@"PT;", 0.8) isEqualToString:@"PT0;"];
    if (![mode isEqualToString:@"MD6;"] || finalHz != initialHz || !rxConfirmed) {
        if (failure) *failure = @"DIG mode, unchanged dial frequency, and RX could not all be confirmed by CAT.";
        return NO;
    }
    if (confirmedHz) *confirmedHz = finalHz;
    return YES;
}
NS_ASSUME_NONNULL_END
