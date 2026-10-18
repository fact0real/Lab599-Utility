#import <Cocoa/Cocoa.h>
#import "TX500CWKeyer.h"

@interface TX500CWKeyer (SafetyTests)
- (BOOL)localSidetoneRouteIsSafe;
@end

// No CoreAudio device is opened. This route behaves like a radio or an unknown output.
@interface UnsafeSidetoneKeyer : TX500CWKeyer
@end
@implementation UnsafeSidetoneKeyer
- (BOOL)localSidetoneRouteIsSafe { return NO; }
@end

@interface RecordingSidetone : NSObject
@property NSUInteger calls;
@end
@implementation RecordingSidetone
- (BOOL)isPlaying { return NO; }
- (void)stop {}
- (id)mainMixerNode { self.calls++; return self; }
@end

@interface RaisingStopSidetone : NSObject
@end
@implementation RaisingStopSidetone
- (BOOL)isPlaying { return YES; }
- (void)stop { [NSException raise:@"LocalAudioFailure" format:@"Output disappeared during stop"]; }
@end

static NSUInteger checks;
static void Check(BOOL ok, NSString *message) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
static void Drain(NSTimeInterval seconds) {
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:seconds]];
}
int main(void) {
    setenv("TX500_TEST_MODE", "1", 1);
    @autoreleasepool {
        NSMutableArray<NSString *> *commands = [NSMutableArray new];
        TX500CWKeyer *keyer = [TX500CWKeyer new];
        keyer.wpm = 45;
        keyer.serialCommandSender = ^BOOL(NSString *command) {
            @synchronized (commands) { [commands addObject:command]; }
            return YES;
        };

        // Practice must be safe even when a host supplies a sender without a CAT gate.
        keyer.practiceModeActive = ^BOOL { return YES; };
        [keyer transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""];
        Check(keyer.isTransmitting && commands.count == 0, @"Practice never calls an ungated sender");
        Drain(0.25);
        Check(!keyer.isTransmitting && commands.count == 0, @"Practice completion sends no RX command");
        [keyer abortTransmission];
        Check(commands.count == 0, @"Practice abort sends no CAT");
        keyer.practiceModeActive = nil;

        // Reject unsupported and oversized text before touching CAT or allocating audio.
        for (NSString *text in @[@"E;TX;", @"<UNEXPANDED>", [@"E" stringByPaddingToLength:4097 withString:@"E" startingAtIndex:0]]) {
            [keyer transmitText:text targetCall:@"" rst:@"" name:@"" qth:@""];
            Check(!keyer.isTransmitting && commands.count == 0, @"Invalid text never keys the radio");
        }
        for (NSNumber *limit in @[@0, @(-1), @(NAN), @(INFINITY)]) {
            keyer.maximumTransmitSeconds = limit.doubleValue;
            keyer.wpm = 3;
            [keyer transmitText:[@"T" stringByPaddingToLength:100 withString:@"T" startingAtIndex:0]
                    targetCall:@"" rst:@"" name:@"" qth:@""];
            Check(!keyer.isTransmitting && commands.count == 0, @"Invalid timeout settings cannot disable the message ceiling");
        }
        keyer.wpm = 45;
        keyer.maximumTransmitSeconds = 30;

        // A carrier timeout may have sent RX while its UI cleanup waits behind a busy main thread.
        // Replacing it must not let that old cleanup cancel the new message's watchdog.
        keyer.maximumCarrierSeconds = 0.04;
        [keyer startContinuousCarrierWithPitchHz:650];
        [NSThread sleepForTimeInterval:0.15];
        __block BOOL replacementAlive = NO;
        dispatch_async(dispatch_get_main_queue(), ^{ replacementAlive = keyer.isTransmitting; });
        [keyer transmitText:@"CQ CQ TEST" targetCall:@"" rst:@"" name:@"" qth:@""];
        Drain(0.06);
        Check(replacementAlive && keyer.isTransmitting, @"Old carrier timeout cleanup preserves the replacement message");
        Check([keyer valueForKey:@"transmitTimeout"] != nil, @"Replacement retains its watchdog");
        [keyer abortTransmission];

        // Force RX to overlap a replacement request: the new TX must wait for the old RX write.
        dispatch_semaphore_t releaseStarted = dispatch_semaphore_create(0);
        __block BOOL releaseFinished = NO, overlappedTX = NO;
        __block BOOL delayRelease = NO;
        keyer.serialCommandSender = ^BOOL(NSString *command) {
            if ([command isEqualToString:@"RX;"] && delayRelease) {
                dispatch_semaphore_signal(releaseStarted);
                [NSThread sleepForTimeInterval:0.12];
                releaseFinished = YES;
            }
            if ([command isEqualToString:@"TX;"] && delayRelease && !releaseFinished) overlappedTX = YES;
            return YES;
        };
        keyer.maximumCarrierSeconds = 0.03;
        [keyer startContinuousCarrierWithPitchHz:650];
        delayRelease = YES;
        Check(dispatch_semaphore_wait(releaseStarted, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
              @"Background watchdog attempts RX while the main thread is blocked");
        [keyer transmitText:@"CQ TEST" targetCall:@"" rst:@"" name:@"" qth:@""];
        Check(releaseFinished && !overlappedTX, @"An old watchdog cannot release a newly keyed transmission");
        delayRelease = NO;
        Drain(0.03);
        Check(keyer.isTransmitting, @"Delayed cleanup also preserves the replacement");
        [keyer abortTransmission];

        // A local audio exception during abort/completion must never skip the CAT release.
        TX500CWKeyer *badStop = [TX500CWKeyer new];
        badStop.wpm = 45;
        __block NSUInteger stopReleases = 0;
        badStop.serialCommandSender = ^BOOL(NSString *command) { if ([command isEqualToString:@"RX;"]) stopReleases++; return YES; };
        [badStop setValue:[RaisingStopSidetone new] forKey:@"sidetonePlayer"];
        [badStop transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""];
        Drain(0.25);
        Check(!badStop.isTransmitting && stopReleases >= 2, @"A throwing local audio stop cannot skip RX at completion");
        [badStop abortTransmission];
        Check(stopReleases >= 3, @"A throwing local audio stop cannot skip RX on abort");

        UnsafeSidetoneKeyer *local = [UnsafeSidetoneKeyer new];
        RecordingSidetone *output = [RecordingSidetone new];
        [local setValue:output forKey:@"sidetoneEngine"];
        [local setValue:output forKey:@"sidetonePlayer"];
        [local setValue:@YES forKey:@"sidetoneEngineReady"];
        local.practiceModeActive = ^BOOL { return YES; };
        [local transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""];
        Check(output.calls == 0, @"An unsafe local sidetone route is never rendered, including in Practice");
        [local abortTransmission];
        printf("PASS: %lu independent CW transmit safety checks; no audio devices or radios used.\n", (unsigned long)checks);
    }
    return 0;
}
