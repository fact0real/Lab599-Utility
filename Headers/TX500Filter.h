#import <Foundation/Foundation.h>

// Lab599 CAT rev. 3: FL<rx 0..3><tx 0..1>;. UI numbers start at one.
// A truncated/legacy one-digit reply is ambiguous: do not guess its base.
static inline BOOL TX500ParseFilterReply(NSString *reply, NSInteger *rxNumber, NSInteger *txNumber) {
    if (reply.length != 5 || ![reply hasPrefix:@"FL"] || ![reply hasSuffix:@";"]) return NO;
    unichar rx = [reply characterAtIndex:2], tx = [reply characterAtIndex:3];
    if (rx < '0' || rx > '3' || tx < '0' || tx > '1') return NO;
    if (rxNumber) *rxNumber = rx - '0' + 1;
    if (txNumber) *txNumber = tx - '0' + 1;
    return YES;
}
static inline NSString *TX500FilterCommand(NSInteger rxNumber, NSInteger txNumber) {
    if (rxNumber < 1 || rxNumber > 4 || txNumber < 1 || txNumber > 2) return nil;
    return [NSString stringWithFormat:@"FL%ld%ld;", (long)rxNumber - 1, (long)txNumber - 1];
}
