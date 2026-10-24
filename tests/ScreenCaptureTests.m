#import <Cocoa/Cocoa.h>
#import "../Headers/TX500ScreenModel.h"
#import "../Headers/TX500ScreenRenderer.h"
#import "../Headers/TX500ScreenCaptureController.h"
#include <util.h>
#include <poll.h>

// A fake TX-500 on a pseudo-terminal. It answers PT; with fakePTReply, IF;
// with "?;" (the manual: IF cannot read the status in Data mode) and records
// every command it receives.
static NSMutableArray<NSString *> *fakeRadioCommands;
static NSString *fakePTReply;
static NSMutableDictionary<NSString *, NSString *> *fakeReplies; // other exact answers
static void StartFakeRadio(int master) {
    fakeRadioCommands = [NSMutableArray array];
    [NSThread detachNewThreadWithBlock:^{
        NSMutableString *buffer = [NSMutableString string];
        for (;;) {
            struct pollfd pfd = { master, POLLIN, 0 };
            if (poll(&pfd, 1, 50) <= 0) continue;
            char bytes[256];
            ssize_t n = read(master, bytes, sizeof bytes);
            if (n <= 0) { usleep(10000); continue; }
            [buffer appendString:[[NSString alloc] initWithBytes:bytes length:(NSUInteger)n encoding:NSASCIIStringEncoding] ?: @""];
            NSRange end;
            while ((end = [buffer rangeOfString:@";"]).location != NSNotFound) {
                NSString *cmd = [buffer substringToIndex:end.location + 1];
                [buffer deleteCharactersInRange:NSMakeRange(0, end.location + 1)];
                @synchronized (fakeRadioCommands) { [fakeRadioCommands addObject:cmd]; }
                NSString *reply = nil;
                if ([cmd isEqualToString:@"PT;"]) reply = fakePTReply;
                else if (fakeReplies[cmd]) reply = fakeReplies[cmd];
                else if (![cmd isEqualToString:@"TX;"] && ![cmd isEqualToString:@"RX;"]) reply = @"?;";
                if (reply.length) write(master, reply.UTF8String, reply.length);
            }
        }
    }];
}
static NSString *LastPTTCommand(void) {
    @synchronized (fakeRadioCommands) {
        for (NSString *cmd in fakeRadioCommands.reverseObjectEnumerator)
            if ([cmd isEqualToString:@"TX;"] || [cmd isEqualToString:@"RX;"]) return cmd;
    }
    return nil;
}
static BOOL SpinUntil(BOOL (^done)(void), NSTimeInterval timeout) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!done() && [limit timeIntervalSinceNow] > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    return done();
}
// These checks reach the Live CAT state and the PO bar rule through the
// runtime, so the test also builds on code without them, and fails there.
static void SetStateValue(TX500ScreenState *s, NSString *key, NSInteger value) {
    if ([s respondsToSelector:NSSelectorFromString(key)]) [s setValue:@(value) forKey:key];
}
static NSInteger StateValue(TX500ScreenState *s, NSString *key) {
    return [s respondsToSelector:NSSelectorFromString(key)] ? [[s valueForKey:key] integerValue] : NSIntegerMin;
}
static NSInteger LitPODots(TX500ScreenState *s) {
    SEL sel = NSSelectorFromString(@"powerOutBarDotsForState:");
    if (![TX500ScreenRenderer respondsToSelector:sel]) return NSIntegerMin;
    NSInteger (*call)(id, SEL, TX500ScreenState *) = (NSInteger (*)(id, SEL, TX500ScreenState *))[TX500ScreenRenderer methodForSelector:sel];
    return call([TX500ScreenRenderer class], sel, s);
}
static void RefreshFromFakeRadio(TX500ScreenCaptureController *c) {
    @synchronized (fakeRadioCommands) { [fakeRadioCommands removeAllObjects]; }
    [c refreshSnapshotFromRadio];
    SpinUntil(^BOOL{ @synchronized (fakeRadioCommands) { return [fakeRadioCommands containsObject:@"NT;"]; } }, 10.0);
    SpinUntil(^BOOL{ return ![[c valueForKey:@"isPolling"] boolValue]; }, 10.0); // the poll has been applied
}
static NSString *PressPTT(TX500ScreenCaptureController *c, TX500ChassisControlTag tag) {
    @synchronized (fakeRadioCommands) { [fakeRadioCommands removeAllObjects]; }
    [c handleChassisControlPress:tag atChassisPoint:NSZeroPoint];
    SpinUntil(^BOOL{ return LastPTTCommand() != nil; }, 3.0);
    [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    return LastPTTCommand();
}

static void Check(BOOL passed, NSString *message) {
    if (!passed) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        printf("Running TX-500 Screen Rendering & Capture Unit Tests (V2)...\n");

        // 1. Native LCD dimensions test
        NSSize nativeSize = [TX500ScreenRenderer nativeLCDSize];
        Check(nativeSize.width == 256.0 && nativeSize.height == 128.0, @"Native TX-500 LCD size must be 256x128 pixels");

        // 2. Screen Model & default state test (matching physical radio photo)
        TX500ScreenState *state = [TX500ScreenState defaultDemoState];
        Check(state != nil, @"Default demo state must be non-nil");
        Check(state.frequencyHz == 24889300, @"Default frequency must be 24.889.300 Hz (12m DIG)");
        Check([state.operatingMode isEqualToString:@"DIG"], @"Default operating mode must be DIG");
        Check(state.vfoBFrequencyHz == 10100000, @"Default VFO-B frequency must be 10.100.000 Hz");
        Check([state.vfoBMode isEqualToString:@"CWR"], @"Default VFO-B mode must be CWR");
        Check(state.supplyVoltage == 12.0, @"Default supply voltage must be 12.0V");
        Check([state.filterName isEqualToString:@"FIL-1"], @"Default filter must be FIL-1");
        Check([state.filterBandwidthString isEqualToString:@"3.10k"], @"Default filter bandwidth must be 3.10k");
        Check(state.afGainLevel == 64, @"Default AF Gain must be 64");
        Check(state.rfGainLevel == 0, @"Default RF Gain must be 0");
        Check(state.topSoftKeyLabels.count == 4, @"Top soft-keys must have 4 items");
        Check(state.softKeyLabels.count == 4, @"Bottom soft-keys must have 4 items");
        Check(state.spectrumAmplitudes.count == 64, @"Spectrum amplitudes must contain 64 frequency bins");

        // 3. State Copying test
        TX500ScreenState *stateCopy = [state copy];
        Check(stateCopy != state, @"Copied state must be a distinct object");
        Check(stateCopy.frequencyHz == state.frequencyHz, @"Frequency preserved in copy");
        Check([stateCopy.operatingMode isEqualToString:state.operatingMode], @"Mode preserved in copy");
        Check([stateCopy.vfoBMode isEqualToString:state.vfoBMode], @"VFO-B mode preserved in copy");
        Check(stateCopy.sMeterDots == state.sMeterDots, @"S-meter dots preserved in copy");
        Check(stateCopy.topSoftKeyLabels.count == 4, @"Top soft-keys preserved in copy");

        // 4. Renderer: Native 1x (256x128) Screen Image test
        NSImage *screen1x = [TX500ScreenRenderer renderScreenImageWithState:state
                                                                     theme:TX500ScreenThemeCoolWhite
                                                                     scale:1.0
                                                                 pixelGrid:NO];
        Check(screen1x != nil, @"1x screen image must be non-nil");
        Check(NSEqualSizes(screen1x.size, NSMakeSize(256, 128)), @"1x screen image size must be exactly 256x128");

        // 5. Renderer: Integer Scaling (2x = 512x256, 4x = 1024x512)
        NSImage *screen2x = [TX500ScreenRenderer renderScreenImageWithState:state
                                                                     theme:TX500ScreenThemeCoolWhite
                                                                     scale:2.0
                                                                 pixelGrid:YES];
        Check(screen2x != nil, @"2x screen image must be non-nil");
        Check(NSEqualSizes(screen2x.size, NSMakeSize(512, 256)), @"2x screen image size must be exactly 512x256");

        NSImage *screen4x = [TX500ScreenRenderer renderScreenImageWithState:state
                                                                     theme:TX500ScreenThemeAmber
                                                                     scale:4.0
                                                                 pixelGrid:YES];
        Check(screen4x != nil, @"4x screen image must be non-nil");
        Check(NSEqualSizes(screen4x.size, NSMakeSize(1024, 512)), @"4x screen image size must be exactly 1024x512");

        // 6. Theme tests (Amber, Cool White, Green, OLED)
        TX500ScreenTheme themes[] = {
            TX500ScreenThemeAmber,
            TX500ScreenThemeCoolWhite,
            TX500ScreenThemeGreen,
            TX500ScreenThemeOLED
        };
        const char *themeNames[] = {"Amber", "CoolWhite", "Green", "OLED"};

        for (int i = 0; i < 4; i++) {
            NSImage *themeImg = [TX500ScreenRenderer renderScreenImageWithState:state
                                                                          theme:themes[i]
                                                                          scale:2.0
                                                                      pixelGrid:YES];
            Check(themeImg != nil, [NSString stringWithFormat:@"Theme %s image must render successfully", themeNames[i]]);

            NSData *png = [TX500ScreenRenderer pngDataForImage:themeImg];
            Check(png.length > 1000, [NSString stringWithFormat:@"Theme %s PNG export must produce valid data", themeNames[i]]);

            // Verify PNG magic bytes: 0x89 'P' 'N' 'G'
            const unsigned char *bytes = (const unsigned char *)png.bytes;
            Check(bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47,
                  [NSString stringWithFormat:@"Theme %s PNG must have valid PNG magic header", themeNames[i]]);

            NSString *outPath = [NSString stringWithFormat:@"build/tx500_screen_sample_%s.png", themeNames[i]];
            [png writeToFile:outPath atomically:YES];
        }

        // 7. Chassis Bezel Rendering test (840x440)
        NSImage *chassisImg = [TX500ScreenRenderer renderChassisImageWithState:state
                                                                         theme:TX500ScreenThemeCoolWhite
                                                                     pixelGrid:YES];
        Check(chassisImg != nil, @"Chassis bezel image must render successfully");
        Check(NSEqualSizes(chassisImg.size, NSMakeSize(840, 440)), @"Chassis bezel size must be 840x440");

        NSData *chassisPng = [TX500ScreenRenderer pngDataForImage:chassisImg];
        Check(chassisPng.length > 5000, @"Chassis PNG export must produce valid data");
        [chassisPng writeToFile:@"build/tx500_chassis_sample.png" atomically:YES];

        // 8. JPEG export test
        NSData *chassisJpg = [TX500ScreenRenderer jpegDataForImage:chassisImg compression:0.90];
        Check(chassisJpg.length > 2000, @"Chassis JPEG export must produce valid data");
        const unsigned char *jpgBytes = (const unsigned char *)chassisJpg.bytes;
        Check(jpgBytes[0] == 0xFF && jpgBytes[1] == 0xD8, @"JPEG must have valid SOI marker 0xFFD8");

        // 9. Transmit State Rendering test (RF Power & SWR meters)
        TX500ScreenState *txState = [state copy];
        txState.isTransmitting = YES;
        txState.rfPowerWatts = 10.0;
        txState.swr = 1.15;
        NSImage *txScreen = [TX500ScreenRenderer renderScreenImageWithState:txState
                                                                      theme:TX500ScreenThemeCoolWhite
                                                                      scale:2.0
                                                                  pixelGrid:YES];
        Check(txScreen != nil, @"TX mode screen must render successfully");

        // 10. Controller initialization and live components test
        TX500ScreenCaptureController *controller = [TX500ScreenCaptureController new];
        Check(controller != nil, @"TX500ScreenCaptureController must initialize");
        Check(controller.view != nil, @"Controller view must be created");
        Check(controller.currentTheme == TX500ScreenThemeCoolWhite, @"Default theme is CoolWhite matching real photo");
        Check(controller.showChassisBezel == YES, @"Default shows chassis bezel");

        // 11. Empty S-meter test (0 dots on silent radio)
        TX500ScreenState *emptySmState = [state copy];
        emptySmState.sMeterDots = 0;
        NSImage *emptySmImg = [TX500ScreenRenderer renderScreenImageWithState:emptySmState
                                                                        theme:TX500ScreenThemeCoolWhite
                                                                        scale:2.0
                                                                    pixelGrid:NO];
        Check(emptySmImg != nil, @"Empty S-meter screen must render successfully");

        // 12. Filter Preset switching test (FIL-2, FIL-3, FIL-4)
        TX500ScreenState *filState = [state copy];
        filState.filterNumber = 2;
        filState.filterName = @"FIL-2";
        filState.filterBandwidthString = @"2.40k";
        NSImage *filImg = [TX500ScreenRenderer renderScreenImageWithState:filState
                                                                    theme:TX500ScreenThemeCoolWhite
                                                                    scale:2.0
                                                                pixelGrid:NO];
        Check(filImg != nil, @"Switched filter screen must render successfully");

        // 13. Mode badge test: USB operatingMode maps to DIG badge
        TX500ScreenState *usbState = [state copy];
        usbState.operatingMode = @"USB";
        NSImage *usbImg = [TX500ScreenRenderer renderScreenImageWithState:usbState
                                                                    theme:TX500ScreenThemeCoolWhite
                                                                    scale:2.0
                                                                pixelGrid:NO];
        Check(usbImg != nil, @"USB to DIG mode screen must render successfully");

        // 14. Official logo asset test
        NSImage *logoAsset = [[NSImage alloc] initWithContentsOfFile:@"Resources/lab599_logo.png"];
        Check(logoAsset != nil, @"Resources/lab599_logo.png must exist and be loadable");
        Check(NSEqualSizes(logoAsset.size, NSMakeSize(648, 234)), @"Official logo dimensions must be 648x234");

        // 15. Pressed Button & Bezel Glow rendering tests
        NSImage *pressedBandImg = [TX500ScreenRenderer renderChassisImageWithState:state
                                                                             theme:TX500ScreenThemeCoolWhite
                                                                         pixelGrid:YES
                                                                     pressedButton:TX500ControlBandUp
                                                                         tuneAngle:0.0
                                                                       afGainAngle:0.0];
        Check(pressedBandImg != nil, @"Chassis with pressed BAND+ button must render successfully");
        Check(NSEqualSizes(pressedBandImg.size, NSMakeSize(840, 440)), @"Chassis size must remain 840x440");

        NSImage *pressedPwrImg = [TX500ScreenRenderer renderChassisImageWithState:state
                                                                            theme:TX500ScreenThemeAmber
                                                                        pixelGrid:YES
                                                                    pressedButton:TX500ControlPower
                                                                        tuneAngle:1.2
                                                                      afGainAngle:-0.5];
        Check(pressedPwrImg != nil, @"Chassis with pressed POWER button and knob angles must render successfully");

        // 16. Controller interactive BAND+ and BAND- stepping tests
        controller.screenState.frequencyHz = 14074000ULL; // 20m FT8
        [controller handleChassisControlPress:TX500ControlBandUp atChassisPoint:NSMakePoint(640, 335)];
        Check(controller.screenState.frequencyHz == 18100000ULL, @"BAND+ from 20m must advance to 17m (18.100 MHz)");

        [controller handleChassisControlPress:TX500ControlBandDown atChassisPoint:NSMakePoint(640, 305)];
        Check(controller.screenState.frequencyHz == 14074000ULL, @"BAND- from 17m must step down to 20m (14.074 MHz)");

        // 17. Controller interactive MODE and FILTER cycling tests
        controller.demoModeActive = YES; // local control exercises never send CAT
        controller.screenState.operatingMode = @"USB";
        [controller handleChassisControlPress:TX500ControlMode atChassisPoint:NSMakePoint(640, 275)];
        Check([controller.screenState.operatingMode isEqualToString:@"CW"], @"MODE cycle from USB must switch to CW");

        controller.screenState.filterNumber = 1;
        [controller handleChassisControlPress:TX500ControlFilter atChassisPoint:NSMakePoint(640, 245)];
        Check(controller.screenState.filterNumber == 2, @"FILTER cycle from FIL-1 must switch to FIL-2");

        // 18. Controller interactive TUNE VFO and AF GAIN knob deltas
        uint64_t beforeFreq = controller.screenState.frequencyHz;
        [controller handleTuneKnobDelta:1.0];
        Check(controller.screenState.frequencyHz == beforeFreq + 500ULL, @"TUNE knob delta +1.0 must increment frequency by 500 Hz");

        NSInteger beforeAF = controller.screenState.afGainLevel;
        [controller handleAFGainKnobDelta:1.0];
        Check(controller.screenState.afGainLevel == beforeAF + 5, @"AF GAIN knob delta +1.0 must increment gain by 5");

        // 19. Controller interactive Soft Keys (Top & Bottom)
        controller.screenState.preamp = NO;
        [controller handleChassisControlPress:TX500ControlTopKey1 atChassisPoint:NSMakePoint(120, 405)];
        Check(controller.screenState.preamp == YES, @"Top Key 1 must toggle Preamp to ON");

        [controller handleChassisControlPress:TX500ControlBottomKey2 atChassisPoint:NSMakePoint(250, 25)];
        Check(controller.screenState.split == YES, @"Bottom Key 2 must toggle SPLIT to ON");

        // 10. The exclusive Live Radio Screen can release PTT but cannot key outside the core.
        int ptyMaster = -1, ptySlave = -1;
        char ptyName[128] = {0};
        Check(openpty(&ptyMaster, &ptySlave, ptyName, NULL, NULL) == 0, @"Pseudo-terminal for the fake radio");
        close(ptySlave);
        NSString *ptyPath = [NSString stringWithUTF8String:ptyName];
        StartFakeRadio(ptyMaster);
        TX500ScreenCaptureController *live = [TX500ScreenCaptureController new];
        live.demoModeActive = NO;
        live.selectedPortProvider = ^NSString * { return ptyPath; };

        fakePTReply = @"PT1;"; // transmitting, in DIG
        [live refreshSnapshotFromRadio];
        SpinUntil(^BOOL{ @synchronized (fakeRadioCommands) { return [fakeRadioCommands containsObject:@"VL;"]; } }, 10.0);
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        NSString *stopCmd = PressPTT(live, TX500ControlRX);
        Check([stopCmd isEqualToString:@"RX;"], [NSString stringWithFormat:@"R/X while the radio transmits in DIG sends RX; (sent %@)", stopCmd]);
        fakePTReply = @"PT0;";
        Check([PressPTT(live, TX500ControlRX) isEqualToString:@"RX;"], @"R/X while receiving never keys outside the core; it requests RX only");
        fakePTReply = nil; // no answer
        Check([PressPTT(live, TX500ControlRX) isEqualToString:@"RX;"], @"R/X sends RX; when the radio does not answer PT;");
        fakePTReply = @"PT1;";
        Check([PressPTT(live, TX500ControlBottomKey4) isEqualToString:@"RX;"], @"Bottom key 4 follows the radio as well");
        live.screenState.isTransmitting = NO;
        fakePTReply = nil; // the radio does not answer PT;
        RefreshFromFakeRadio(live);
        Check(!live.screenState.isTransmitting, @"A refresh without a PT; answer keeps the last state (RX)");
        fakePTReply = @"PT1;";
        RefreshFromFakeRadio(live);
        Check(live.screenState.isTransmitting, @"A refresh with PT1; shows TX");
        fakePTReply = nil;
        RefreshFromFakeRadio(live);
        Check(live.screenState.isTransmitting, @"A refresh without a PT; answer keeps the last state (TX)");
        printf("PASS: Live Radio Screen never keys outside the core, and explicit RX remains available.\n");

        // 11. Live CAT shows only what the radio reported.
        fakeReplies = [NSMutableDictionary dictionary];
        TX500ScreenCaptureController *honest = [TX500ScreenCaptureController new];
        honest.demoModeActive = NO;
        NSTextField *hud = [honest valueForKey:@"hudTelemetryLabel"];
        [honest renderAndUpdateDisplay];
        Check([hud.stringValue hasSuffix:@"[NO CAT PORT]"], @"Without a CAT port the panel does not claim Live CAT");
        __block NSString *honestPort = ptyPath;
        honest.selectedPortProvider = ^NSString * { return honestPort; };
        [honest renderAndUpdateDisplay];
        Check([hud.stringValue hasSuffix:@"[LIVE CAT · waiting for radio]"], @"Before any radio answer the panel does not claim Live CAT");
        TX500ScreenState *unread = [honest.screenState copy];
        unread.isTransmitting = YES;
        SetStateValue(unread, @"poDots", -1);
        Check(LitPODots(unread) == 0, @"Live CAT TX without an SM0; reading lights no PO dots");
        SetStateValue(unread, @"liveCAT", NO);
        Check(LitPODots(unread) > 0, @"Demo Mode still simulates the PO bar");
        fakePTReply = @"PT1;";
        fakeReplies[@"SM0;"] = @"SM00012;";
        fakeReplies[@"RA;"] = @"RA0100;";
        fakeReplies[@"LK;"] = @"LK10;";
        RefreshFromFakeRadio(honest);
        Check(honest.screenState.attenuator && honest.screenState.isLocked, @"Manufacturer RA two-digit state and LK status are parsed");
        @synchronized(fakeRadioCommands) { [fakeRadioCommands removeAllObjects]; }
        [honest handleChassisControlPress:TX500ControlLock atChassisPoint:NSZeroPoint];
        BOOL unlockedSent=SpinUntil(^BOOL{ @synchronized(fakeRadioCommands) { return [fakeRadioCommands containsObject:@"LK00;"]; } },3);
        Check(unlockedSent, @"Lock button sends the documented unlock command from a known locked state");
        SpinUntil(^BOOL{ return ![[honest valueForKey:@"isPolling"] boolValue]; },10);
        fakeReplies[@"LK;"] = @"LK00;";
        RefreshFromFakeRadio(honest);
        @synchronized(fakeRadioCommands) { [fakeRadioCommands removeAllObjects]; }
        [honest handleChassisControlPress:TX500ControlLock atChassisPoint:NSZeroPoint];
        BOOL lockedSent=SpinUntil(^BOOL{ @synchronized(fakeRadioCommands) { return [fakeRadioCommands containsObject:@"LK10;"]; } },3);
        Check(lockedSent, @"Lock button sends the documented lock command from a known unlocked state");
        fakeReplies[@"FA;"] = @"FA00014074000;";
        RefreshFromFakeRadio(honest);
        [honest renderAndUpdateDisplay];
        Check([hud.stringValue containsString:@"PO: 12 dots"] && ![hud.stringValue containsString:@" W "],
              [NSString stringWithFormat:@"TX shows the radio's power-out dots, not invented watts (%@)", hud.stringValue]);
        Check(LitPODots(honest.screenState) == 12, @"The PO bar lights the radio's 12 dots");
        Check(honest.screenState.spectrumAmplitudes.count == 0, @"Live CAT draws no invented spectrum");
        Check([hud.stringValue hasSuffix:@"[LIVE CAT 9600]"], @"After a real answer the panel says Live CAT");
        fakeReplies[@"FA;"] = @"FA00014074000;";
        for (NSInteger rx = 0; rx < 4; rx++) {
            fakeReplies[@"FL;"] = [NSString stringWithFormat:@"FL%ld1;", (long)rx];
            RefreshFromFakeRadio(honest);
            Check(honest.screenState.filterNumber == rx + 1, @"Live CAT converts the zero-based RX filter independently of the TX digit");
            Check(honest.screenState.filterBandwidthHz == 0 && [honest.screenState.filterBandwidthString isEqualToString:@"—"], @"Live CAT does not invent a preset bandwidth");
        }
        fakeReplies[@"FL;"] = @"FL1;";
        RefreshFromFakeRadio(honest);
        Check(honest.screenState.filterNumber == 0 && [honest.screenState.filterName isEqualToString:@"FIL-?"], @"A truncated FL reply clears the prior known filter");
        fakeReplies[@"FL;"] = @"FL00;";
        honest.screenState.isTransmitting = NO;
        dispatch_queue_t serialQueue = [honest valueForKey:@"serialQueue"];
        dispatch_semaphore_t filterGate = dispatch_semaphore_create(0);
        dispatch_async(serialQueue, ^{ dispatch_semaphore_wait(filterGate, DISPATCH_TIME_FOREVER); });
        @synchronized (fakeRadioCommands) { [fakeRadioCommands removeAllObjects]; }
        [honest handleChassisControlPress:TX500ControlFilter atChassisPoint:NSMakePoint(640, 245)];
        [honest stopLiveSync];
        dispatch_semaphore_signal(filterGate);
        dispatch_sync(serialQueue, ^{});
        @synchronized (fakeRadioCommands) {
            Check(fakeRadioCommands.count == 0, @"Leaving the live screen cancels a queued filter change before CAT access");
        }
        [fakeReplies removeObjectForKey:@"FL;"];
        honestPort = @"/dev/null-other-port";
        [honest renderAndUpdateDisplay];
        Check([hud.stringValue hasSuffix:@"[LIVE CAT · waiting for radio]"], @"Another port is not Live CAT until it answers");
        honestPort = ptyPath;
        [fakeReplies removeObjectForKey:@"FA;"]; // the radio stops answering FA;
        for (int poll = 0; poll < 3; poll++) RefreshFromFakeRadio(honest);
        [honest renderAndUpdateDisplay];
        Check([hud.stringValue hasSuffix:@"[LIVE CAT · waiting for radio]"], @"Three polls without FA; go back to waiting");
        NSSegmentedControl *picker = [honest valueForKey:@"modePicker"];
        picker.selectedSegment = 1;
        [honest performSelector:@selector(modePickerChanged:) withObject:picker];
        Check(honest.demoModeActive && StateValue(honest.screenState, @"poDots") == -1, @"Demo Mode does not keep a Live TX power reading");
        honest.screenState.isTransmitting = YES; // as in a demo TX frame
        honest.selectedPortProvider = nil;
        picker.selectedSegment = 0;
        [honest performSelector:@selector(modePickerChanged:) withObject:picker];
        Check([hud.stringValue hasSuffix:@"[NO CAT PORT]"] && !honest.screenState.isTransmitting,
              @"Back to Live CAT without a port: the panel says so at once, with no demo TX state");
        printf("PASS: Live CAT shows only values read from the radio.\n");

        printf("ALL TX-500 SCREEN CAPTURE AND RENDERING TESTS PASSED SUCCESSFULLY! ✓\n");
    }
    return 0;
}
