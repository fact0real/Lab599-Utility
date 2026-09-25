#import "TX500VoiceKeyer.h"
#import "Lab599SerialPort.h"

NSError *TXVoiceError(NSString *message) {
    return [NSError errorWithDomain:@"TX500VoiceKeyer" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
@implementation TX500VoiceCATRadio {
    NSString *_path;
    Lab599SerialPort *_port;
}
- (instancetype)initWithPort:(NSString *)path {
    if ((self = [super init])) _path = [path copy];
    return self;
}
- (BOOL)open:(NSError **)error {
    if (!_port) _port = [Lab599SerialPort openPath:_path speed:B9600 error:error];
    return _port != nil;
}
- (BOOL)send:(NSString *)command error:(NSError **)error {
    return [self open:error] && [_port writeData:[command dataUsingEncoding:NSASCIIStringEncoding]
        timeout:0.25 cancellation:nil error:error];
}
- (NSString *)query:(NSString *)command error:(NSError **)error {
    if (![self open:error] || ![_port discardInput:error] || ![self send:command error:error]) return nil;
    NSMutableData *pending = [NSMutableData data];
    double deadline = Lab599MonotonicTime() + 0.8;
    NSString *prefix = [command substringToIndex:2];
    NSMutableSet<NSString *> *echoFrames = [NSMutableSet set];
    for (NSString *component in [command componentsSeparatedByString:@";"]) {
        if (component.length > 0) [echoFrames addObject:[component stringByAppendingString:@";"]];
    }
    while (Lab599MonotonicTime() < deadline) {
        NSError *readError = nil;
        NSData *chunk = [_port readMaximum:128 timeout:0.04 cancellation:nil error:&readError];
        if (!chunk && readError.code != Lab599SerialTimeout) { if (error) *error = readError; return nil; }
        if (chunk.length) [pending appendData:chunk];
        if (pending.length > 4096) break;
        while (YES) {
            NSRange end = [pending rangeOfData:[@";" dataUsingEncoding:NSASCIIStringEncoding]
                                      options:0 range:NSMakeRange(0, pending.length)];
            if (end.location == NSNotFound) break;
            NSString *frame = [[NSString alloc] initWithData:[pending subdataWithRange:NSMakeRange(0, end.location+1)] encoding:NSASCIIStringEncoding];
            [pending replaceBytesInRange:NSMakeRange(0, end.location+1) withBytes:NULL length:0];
            frame = [frame stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if ([frame isEqual:@"?;"] || [frame isEqual:@"E;"] || [frame isEqual:@"O;"]) {
                if (error) *error = TXVoiceError([NSString stringWithFormat:@"Radio returned %@ while reading %@ (command rejected, communication error, or busy).", frame, command]);
                return nil;
            }
            // Compound meter queries are commonly echoed one component at a
            // time (for example RM3; then RM;). Neither short echo is data.
            if ([frame isEqual:command] || [echoFrames containsObject:frame]) continue;
            if ([frame hasPrefix:prefix]) return frame;
        }
    }
    if (error) *error = TXVoiceError([NSString stringWithFormat:@"No valid reply to %@ Check LAB599 CAT mode and the connection.", command]);
    return nil;
}
- (NSNumber *)number:(NSString *)command digits:(NSUInteger)digits error:(NSError **)error {
    NSString *frame = [self query:command error:error];
    if (!frame) return nil;
    if (frame.length != digits + 3 || ![frame hasSuffix:@";"]) {
        if (error) *error = TXVoiceError(@"The radio returned an invalid CAT field."); return nil;
    }
    NSString *field = [frame substringWithRange:NSMakeRange(2, digits)];
    if ([field rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) {
        if (error) *error = TXVoiceError(@"The radio returned a nonnumeric CAT field."); return nil;
    }
    return @([field longLongValue]);
}
- (NSDictionary *)readState:(NSError **)error {
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    NSArray *queries = @[@[@"FA;", @11, @"frequency"], @[@"MD;", @1, @"mode"],
        @[@"FR;", @1, @"rxVFO"], @[@"FT;", @1, @"txVFO"], @[@"XT;", @1, @"xit"],
        @[@"VX;", @1, @"vox"], @[@"PT;", @1, @"tx"]];
    for (NSArray *q in queries) {
        NSNumber *n = [self number:q[0] digits:[q[1] unsignedIntegerValue] error:error];
        if (!n) return nil;
        state[q[2]] = n;
    }
    return state;
}
- (BOOL)tuneFrequency:(uint64_t)frequency mode:(NSInteger)mode error:(NSError **)error {
    if (frequency < 500000 || frequency > 56000000 || ![@[@1,@2,@4,@5] containsObject:@(mode)]) {
        if (error) *error = TXVoiceError(@"Choose a valid voice frequency and USB, LSB, AM or FM."); return NO;
    }
    return [self send:[NSString stringWithFormat:@"FA%011llu;MD%ld;", (unsigned long long)frequency, (long)mode] error:error];
}
- (BOOL)setTransmit:(BOOL)transmit error:(NSError **)error {
    // LAB599 documents TX/RX without an audio-source parameter. Audio input is
    // selected explicitly on the radio; modem-control pins are never asserted.
    if (![self send:transmit ? @"TX;" : @"RX;" error:error]) return NO;
    // The TX-500 can answer PT with the old state while its PTT relay changes.
    // Give the radio a short settling period before each read-back, including
    // RX release. Never assume that an accepted CAT write is confirmed PTT.
    NSError *lastError = nil;
    for (NSInteger attempt = 0; attempt < 5; attempt++) {
        Lab599Pause(0.12, nil);
        lastError = nil;
        NSNumber *state = [self number:@"PT;" digits:1 error:&lastError];
        if (state && state.integerValue == (transmit ? 1 : 0)) return YES;
    }
    if (error) *error = lastError ?: TXVoiceError(transmit ? @"The radio remained in RX after TX; check the radio's transmit inhibit, mode and protection status." : @"RX was not confirmed. Check the radio and release PTT locally.");
    return NO;
}
- (void)close { [_port close]; _port = nil; }
- (void)dealloc { [self close]; }
@end
