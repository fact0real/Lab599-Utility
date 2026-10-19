#import <Cocoa/Cocoa.h>
#import "TX500FT8StationController.h"
#import "TX500FT8AudioEngine.h"
#import "TX500FT8AutoEngine.h"
@interface TX500FT8StationController (ControlTests)
- (void)toggleTune:(id)sender;
- (void)toggleArmTx:(id)sender;
- (void)refreshTransmitButtonState;
@end
@interface ControlEngine : TX500FT8AudioEngine
@property BOOL testMonitoring, testTuning, testPending, testStalled;
@property NSUInteger starts, stops, halts;
@end
@implementation ControlEngine
- (BOOL)isMonitoring { return self.testMonitoring; }
- (BOOL)isTuning { return self.testTuning; }
- (BOOL)isReceiveRecoveryPending { return self.testPending; }
- (BOOL)isReceiveRecoveryStalled { return self.testStalled; }
- (void)startTuneCarrier { self.starts++; self.testTuning = YES; }
- (void)stopTuneCarrier { self.stops++; self.testTuning = NO; }
- (void)disarmTransmit { self.halts++; self.testTuning = NO; self.isTransmitArmed = NO; }
@end
static void Check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); }
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        TX500FT8StationController *controller = [TX500FT8StationController new];
        ControlEngine *engine = [ControlEngine new];
        engine.isSimulationMode = YES;
        [controller setValue:engine forKey:@"audioEngine"];
        controller.autoEngine.audioEngine = engine;
        NSButton *tune = [controller valueForKey:@"tuneButton"];
        NSButton *halt = [controller valueForKey:@"armTxButton"];
        NSTextField *state = [controller valueForKey:@"operatingStateLabel"];
        [controller refreshTransmitButtonState];
        Check(!tune.enabled && [state.stringValue containsString:@"Stopped"], @"Stopped station cannot start a carrier without monitoring");
        [controller toggleTune:nil];
        Check(engine.starts == 0, @"Programmatic Tune also refuses when monitoring is off");
        engine.testMonitoring = YES;
        [controller refreshTransmitButtonState];
        Check(tune.enabled && [state.stringValue containsString:@"No RF"], @"Simulation explicitly says No RF");
        [controller toggleTune:nil];
        Check(engine.starts == 1 && [tune.title isEqualToString:@"Stop Tone"], @"Only an active carrier changes Tune into Stop Tone");
        Check([halt.title isEqualToString:@"HALT TX"], @"Carrier-only TX still exposes Halt TX");
        [controller toggleArmTx:nil];
        Check(engine.halts == 1 && !engine.testTuning && engine.testMonitoring, @"Halt TX stops a carrier without stopping the receiver");
        engine.testTuning = YES;
        [controller toggleTune:nil];
        Check(engine.stops == 1 && [tune.title isEqualToString:@"Tune"], @"Stop Tone follows engine state, not stale button text");
        engine.testPending = YES;
        [controller refreshTransmitButtonState];
        Check(!tune.enabled && [state.stringValue containsString:@"WAIT RX"], @"Pending release is not shown as receiving");
        engine.testStalled = YES;
        [controller refreshTransmitButtonState];
        Check([state.stringValue containsString:@"CHECK RX"], @"Failed release requests physical radio/cable checking");
        engine.testPending = NO; engine.testStalled = NO;
        engine.isSimulationMode = NO; engine.catDialAndModeVerified = NO; engine.dialFrequencyHz = 14074000;
        [controller toggleTune:nil];
        Check(engine.starts == 1 && !engine.catDialAndModeVerified, @"Tune cannot manufacture a verified DIG state from a remembered frequency");
        engine.isSimulationMode = YES;
        [controller refreshTransmitButtonState];
        NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,900,950) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
        window.contentView = controller.view;
        [controller.view layoutSubtreeIfNeeded];
        NSBitmapImageRep *image = [controller.view bitmapImageRepForCachingDisplayInRect:controller.view.bounds];
        [controller.view cacheDisplayInRect:controller.view.bounds toBitmapImageRep:image];
        [[image representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"build/digital-controls-review.png" atomically:YES];
        Check(tune.frame.size.width >= 80 && state.frame.size.height > 10, @"Control labels and status have visible layout space");
        printf("PASS: Digital Tune, Halt TX, receive recovery, simulation and layout checks\n");
    }
    return 0;
}
