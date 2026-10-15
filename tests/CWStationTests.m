//
//  CWStationTests.m
//  Lab599 Utility Tests
//
//  Unit and regression test suite for TX-500 CW Station & QSO Studio
//

#import <Foundation/Foundation.h>
#import "TX500CWAudioDecoder.h"
#import "TX500CWKeyer.h"
#import "TX500CWQSOAssistant.h"
#import "TX500CWSpectrumView.h"
#import "TX500CWStationController.h"
#import "TX500LogbookManager.h"
#import "TX500CloudSyncEngine.h"
#import <objc/runtime.h>

// Stand-ins for the sidetone engine and player that only raise, as AVAudioEngine does when it was
// stopped by an output change. No audio device is opened: the format is a plain description.
@interface RaisingSidetoneEngine : NSObject
@end
@implementation RaisingSidetoneEngine
- (id)mainMixerNode { return self; }
- (AVAudioFormat *)outputFormatForBus:(NSUInteger)bus { (void)bus; return [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000.0 channels:1]; }
- (void)stop {}
@end
@interface RaisingSidetonePlayer : NSObject
@end
@implementation RaisingSidetonePlayer
- (BOOL)isPlaying { return NO; }
- (void)stop {}
- (void)play { [NSException raise:@"CWStationTests" format:@"sidetone engine not running"]; }
- (void)scheduleBuffer:(AVAudioPCMBuffer *)buffer atTime:(AVAudioTime *)when options:(AVAudioPlayerNodeBufferOptions)options completionHandler:(void (^)(void))handler {
    (void)buffer; (void)when; (void)options; (void)handler; [NSException raise:@"CWStationTests" format:@"sidetone engine not running"];
}
@end

// Station button actions the tests press directly (no window is opened).
@interface TX500CWStationController (ButtonsForTests)
- (void)rosterAnswerClicked:(NSButton *)sender;
- (void)macroButtonClicked:(NSButton *)sender;
- (void)advanceQSOAction:(id)sender;
- (void)toggleAutoCQ:(id)sender;
- (void)toggleDecoder:(id)sender;
- (void)toggleSimulation:(NSButton *)sender;
- (void)txSendClicked:(id)sender;
- (void)modePopupChanged:(NSPopUpButton *)sender;
@end

// Counts calls to the cloud upload while a test runs, and uploads nothing. Installed only
// around the checks that need it, and restored afterwards.
static NSUInteger CloudUploadCalls = 0;
static NSString *CloudUploadLastBand = nil;
static IMP CloudUploadOriginal = NULL;
static void StartCountingCloudUploads(void) {
    Method m = class_getInstanceMethod([TX500CloudSyncEngine class], @selector(uploadContactImmediately:completion:));
    IMP counted = imp_implementationWithBlock(^(id engine, TX500LogRecord *record, void (^completion)(BOOL, NSString *)) {
        (void)engine;
        @synchronized ([TX500CloudSyncEngine class]) { CloudUploadCalls++; CloudUploadLastBand = [record.band copy]; }
        if (completion) completion(YES, @"Counted by the test; nothing uploaded.");
    });
    CloudUploadOriginal = method_setImplementation(m, counted);
}
static void StopCountingCloudUploads(void) {
    if (!CloudUploadOriginal) return;
    Method m = class_getInstanceMethod([TX500CloudSyncEngine class], @selector(uploadContactImmediately:completion:));
    method_setImplementation(m, CloudUploadOriginal);
    CloudUploadOriginal = NULL;
}
static NSUInteger CloudUploadCount(void) {
    @synchronized ([TX500CloudSyncEngine class]) { return CloudUploadCalls; }
}

static void AssertTrue(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", [message UTF8String]);
        exit(1);
    }
}

int main(int argc, const char * argv[]) {
    char testRootTemplate[] = "/tmp/Lab599CWStationTests.XXXXXX";
    char *testRoot = mkdtemp(testRootTemplate);
    if (!testRoot) return 1;
    setenv("TX500_TEST_MODE", "1", 1);
    setenv("TX500_TEST_ROOT", testRoot, 1);
    setenv("CFFIXED_USER_HOME", testRoot, 1);
    @autoreleasepool {
        (void)argc; (void)argv;
        NSLog(@"Running TX-500 CW Station & Audio DSP Tests...");

        // 1. Test Reverse Morse Alphabet
        NSDictionary *dict = [TX500CWAudioDecoder reverseMorseAlphabet];
        AssertTrue([dict[@".-"] isEqualToString:@"A"], @"Morse A");
        AssertTrue([dict[@"-..."] isEqualToString:@"B"], @"Morse B");
        AssertTrue([dict[@"..."] isEqualToString:@"S"], @"Morse S");
        AssertTrue([dict[@"---"] isEqualToString:@"O"], @"Morse O");
        AssertTrue([dict[@"...-.-"] isEqualToString:@"<SK>"], @"Morse <SK>");
        AssertTrue([dict[@".-.-."] isEqualToString:@"<AR>"], @"Morse <AR>");
        NSLog(@"PASS: Reverse Morse Alphabet & Prosigns verified.");

        // 2. Test Audio Decoder Initialization & Pitch Setting
        TX500CWAudioDecoder *decoder = [[TX500CWAudioDecoder alloc] init];
        AssertTrue(decoder.nominalPitchHz == 650.0, @"Default pitch is 650 Hz");
        [decoder setPitch:700.0];
        AssertTrue(decoder.nominalPitchHz == 700.0, @"Set pitch 700 Hz");
        [decoder setPitch:200.0]; // Clamped to min 300
        AssertTrue(decoder.nominalPitchHz == 300.0, @"Clamped min pitch 300 Hz");
        [decoder setPitch:1800.0]; // Clamped to max 1500
        AssertTrue(decoder.nominalPitchHz == 1500.0, @"Clamped max pitch 1500 Hz");
        [decoder setPitch:1225.0]; // Valid high pitch
        AssertTrue(decoder.nominalPitchHz == 1225.0, @"Can set high pitch 1225 Hz");
        [decoder setPitch:650.0];
        [decoder setNominalWPM:5.0];
        AssertTrue(decoder.estimatedWPM == 5.0, @"Nominal WPM can be set to 5 WPM");
        [decoder setNominalWPM:3.0];
        AssertTrue(decoder.estimatedWPM == 3.0, @"Nominal WPM can be set to 3 WPM");
        NSLog(@"PASS: Decoder pitch & slow WPM (3-5 WPM) configuration verified.");

        // 3. Test Audio Devices Discovery
        [decoder refreshAudioDevices];
        // Hosted macOS runners may have no input device. The synthetic DSP
        // checks below still run; hardware capture is tested separately.
        NSLog(@"Audio devices enumerated (%lu found).", (unsigned long)decoder.availableAudioInputDevices.count);

        // 4. Test Synthetic Morse DSP Feed & Decoding
        // Feed synthetic "CQ" (.-.-. / -.-. --.-) into decoder
        decoder.afcEnabled = NO;
        [decoder setNominalWPM:25.0];
        [decoder feedSyntheticMorseString:@"CQ" wpm:25.0 pitchHz:650.0];
        // Allow internal buffer to complete character breaks
        for (int i = 0; i < 15; i++) {
            [decoder feedSyntheticAudioWithFrequency:650.0 duration:0.04 isMark:NO];
        }

        AssertTrue([decoder.rawDecodedText containsString:@"C"], @"Decoded C in CQ");
        AssertTrue([decoder.rawDecodedText containsString:@"Q"], @"Decoded Q in CQ");

        // Test 5 WPM decoding specifically
        [decoder clearBuffer];
        [decoder setNominalWPM:5.0];
        [decoder feedSyntheticMorseString:@"E" wpm:5.0 pitchHz:650.0];
        for (int i = 0; i < 30; i++) {
            [decoder feedSyntheticAudioWithFrequency:650.0 duration:0.05 isMark:NO];
        }
        AssertTrue([decoder.rawDecodedText containsString:@"E"], @"Decoded E at 5 WPM");
        NSLog(@"PASS: Real-Time Goertzel DSP Morse Audio Decoding verified at both standard and slow 5 WPM.");

        // 5. Test Keyer Macro Expansion & Cut Numbers
        TX500CWKeyer *keyer = [[TX500CWKeyer alloc] init];
        keyer.myCallsign = @"EP2AES";
        keyer.useCutNumbers = YES;

        NSString *exp1 = [keyer expandTemplate:@"CQ CQ DE {MYCALL} {MYCALL} K" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue([exp1 isEqualToString:@"CQ CQ DE EP2AES EP2AES K"], @"Macro expansion MYCALL");

        NSString *exp2 = [keyer expandTemplate:@"{CALL} DE {MYCALL} UR {RST} BK" targetCall:@"DL1ABC" rst:@"599" name:@"" qth:@""];
        AssertTrue([exp2 isEqualToString:@"DL1ABC DE EP2AES UR 5NN BK"], @"Cut numbers 599 -> 5NN");

        keyer.useCutNumbers = NO;
        NSString *exp3 = [keyer expandTemplate:@"UR {RST} BK" targetCall:@"DL1ABC" rst:@"599" name:@"" qth:@""];
        AssertTrue([exp3 isEqualToString:@"UR 599 BK"], @"Standard numbers 599");
        NSLog(@"PASS: Keyer macro expansion and cut-numbers verified.");

        // 5b. Without the operator's callsign, nothing that needs {MYCALL} is sent.
        TX500CWKeyer *noCallKeyer = [[TX500CWKeyer alloc] init];
        AssertTrue(noCallKeyer.myCallsign.length == 0, @"New keyer starts without a callsign");
        NSString *noCallExp = [noCallKeyer expandTemplate:@"CQ CQ DE {MYCALL} {MYCALL} K" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(![noCallExp containsString:@"EP2AES"], @"Expansion never substitutes a default callsign");
        __block NSMutableArray<NSString *> *noCallCommands = [NSMutableArray array];
        __block NSString *noCallLog = @"";
        noCallKeyer.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [noCallCommands addObject:catCommand]; return YES; };
        noCallKeyer.logHandler = ^(NSString *line) { noCallLog = line; };
        [noCallKeyer transmitText:@"CQ CQ DE {MYCALL} {MYCALL} K" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(noCallCommands.count == 0 && !noCallKeyer.isTransmitting, @"A {MYCALL} macro is not sent without a callsign");
        AssertTrue([noCallLog containsString:@"Enter your callsign"], @"The blocked macro explains why");
        [noCallKeyer startAutoCQWithTemplate:@"" targetCall:@""];
        AssertTrue(!noCallKeyer.isAutoCQActive && noCallCommands.count == 0, @"Auto-CQ does not start without a callsign");
        TX500CWQSOAssistant *noCallAssistant = [[TX500CWQSOAssistant alloc] init];
        AssertTrue(noCallAssistant.myCallsign.length == 0, @"New QSO assistant starts without a callsign");
        NSString *noCallMacro = noCallAssistant.suggestedActionMacro;
        AssertTrue([noCallMacro containsString:@"{MYCALL}"] && ![noCallMacro containsString:@"EP2AES"], @"Assistant keeps {MYCALL} for the keyer to block");
        [noCallKeyer transmitText:noCallMacro targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(noCallCommands.count == 0, @"Assistant CQ is not sent without a callsign");
        TX500QSOState stateBefore = noCallAssistant.qsoState;
        __block NSString *blockedStep = nil;
        [noCallAssistant advanceQSOStepWithAction:^(NSString * _Nonnull macroToTransmit) { blockedStep = macroToTransmit; }];
        AssertTrue(noCallAssistant.qsoState == stateBefore && [blockedStep containsString:@"{MYCALL}"],
                   @"Assistant does not move on without a callsign");
        noCallKeyer.myCallsign = @"   ";
        // With text around {MYCALL}, so only the callsign check (not an empty result) can stop it.
        [noCallKeyer transmitText:@"CQ DE {MYCALL} K" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(noCallCommands.count == 0, @"A callsign of spaces counts as no callsign");
        [noCallKeyer transmitText:@"TEST" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue([noCallCommands containsObject:@"TX;"] && [noCallKeyer.activeBufferText isEqualToString:@"TEST"],
                   @"Free text without {MYCALL} is still sent");
        [noCallKeyer abortTransmission];
        NSLog(@"PASS: Keyer and QSO assistant never send a default callsign.");

        // 5c. The station's own buttons never send a missing callsign either: the roster's
        // Answer, the wideband Answer, the macro buttons, the assistant step and Auto-CQ.
        // The station starts with the empty callsign of a profile that has none.
        TX500CWStationController *noCallStation = [TX500CWStationController new];
        noCallStation.keyer.myCallsign = @"";
        noCallStation.assistant.myCallsign = @"";
        __block NSMutableArray<NSString *> *stationCommands = [NSMutableArray array];
        __block NSMutableArray<NSString *> *stationLog = [NSMutableArray array];
        noCallStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [stationCommands addObject:catCommand]; return YES; };
        noCallStation.logHandler = ^(NSString *line) { [stationLog addObject:line]; };
        [noCallStation.assistant processDecodedTextStream:@"CQ CQ DE EP2AES EP2AES K" currentWPM:22.0 snrDb:14.5];
        AssertTrue(noCallStation.assistant.heardStations.count >= 1, @"Station heard the CQ");
        NSButton *answerButton = [NSButton new];
        answerButton.tag = 0;
        [noCallStation rosterAnswerClicked:answerButton];
        AssertTrue(![stationCommands containsObject:@"TX;"] && !noCallStation.keyer.isTransmitting, @"Answer button sends nothing without a callsign");
        NSTextField *noCallTxField = [noCallStation valueForKey:@"txInputField"];
        AssertTrue(noCallTxField != nil && noCallTxField.stringValue.length == 0, @"Answer button leaves the TX field empty without a callsign");
        TX500QSOState stationStateBefore = noCallStation.assistant.qsoState;
        [noCallStation advanceQSOAction:nil];
        AssertTrue(![stationCommands containsObject:@"TX;"] && noCallTxField.stringValue.length == 0 &&
                   noCallStation.assistant.qsoState == stationStateBefore, @"A refused assistant step sends nothing and leaves the TX field empty");
        NSInteger myCallMacro = -1;
        for (NSInteger i = 0; i < (NSInteger)noCallStation.keyer.macroList.count; i++)
            if ([noCallStation.keyer.macroList[i].templateString containsString:@"{MYCALL}"]) { myCallMacro = i; break; }
        AssertTrue(myCallMacro >= 0, @"A default macro uses {MYCALL}");
        NSButton *macroButton = [NSButton new];
        macroButton.tag = myCallMacro;
        [noCallStation macroButtonClicked:macroButton];
        AssertTrue(![stationCommands containsObject:@"TX;"] && noCallTxField.stringValue.length == 0,
                   @"A {MYCALL} macro button sends nothing and leaves the TX field empty without a callsign");
        [noCallStation toggleAutoCQ:nil];
        NSButton *noCallAutoCQButton = [noCallStation valueForKey:@"autoCQButton"];
        AssertTrue(!noCallStation.keyer.isAutoCQActive && [noCallStation valueForKey:@"autoCQMonitorTimer"] == nil &&
                   ![noCallAutoCQButton.title isEqualToString:@"Stop Auto-CQ"] && ![stationCommands containsObject:@"TX;"],
                   @"Auto-CQ button neither starts nor shows a countdown without a callsign");
        // The wideband Answer (a decoded channel with a callsign) is refused the same way, and says so.
        TX500CWChannelState *noCallChannel = [TX500CWChannelState new];
        noCallChannel.frequencyHz = 900.0;
        noCallChannel.estimatedWPM = 22.0;
        noCallChannel.snrDb = 12.0;
        noCallChannel.extractedCallsign = @"EA0XYZ";
        [stationLog removeAllObjects];
        [noCallStation answerWidebandChannel:noCallChannel];
        BOOL widebandRefusalLogged = NO, widebandClaimsAnswer = NO;
        for (NSString *line in stationLog) {
            if ([line containsString:@"Enter your callsign"]) widebandRefusalLogged = YES;
            if ([line containsString:@"answered"]) widebandClaimsAnswer = YES;
        }
        AssertTrue(![stationCommands containsObject:@"TX;"] && !noCallStation.keyer.isTransmitting && noCallTxField.stringValue.length == 0,
                   @"Wideband Answer sends nothing and leaves the TX field empty without a callsign");
        AssertTrue(widebandRefusalLogged && !widebandClaimsAnswer, @"Wideband Answer says why it sent nothing");
        TX500CWQSOAssistant *idleAnswer = [[TX500CWQSOAssistant alloc] init];
        idleAnswer.activeTargetCallsign = @"EP2AES";
        AssertTrue([idleAnswer.suggestedActionMacro isEqualToString:@"EP2AES DE {MYCALL} K"], @"Idle answer keeps {MYCALL} without a callsign");
        idleAnswer.qsoState = TX500QSOStateCompleted;
        AssertTrue([idleAnswer.suggestedActionMacro containsString:@"{MYCALL}"], @"CQ after a QSO keeps {MYCALL} without a callsign");
        // Control: with a callsign both Answer buttons send the full answer.
        noCallStation.keyer.myCallsign = @"EA3JIC";
        noCallStation.assistant.myCallsign = @"EA3JIC";
        [noCallStation rosterAnswerClicked:answerButton];
        AssertTrue([stationCommands containsObject:@"TX;"] && [noCallStation.keyer.activeBufferText isEqualToString:@"EP2AES DE EA3JIC K"],
                   @"Answer button sends the answer with the callsign");
        AssertTrue([noCallTxField.stringValue isEqualToString:@"EP2AES DE EA3JIC K"], @"With a callsign the Answer button shows the answer in the TX field");
        [noCallStation.keyer abortTransmission];
        [stationCommands removeAllObjects];
        [stationLog removeAllObjects];
        [noCallStation answerWidebandChannel:noCallChannel];
        AssertTrue([stationCommands containsObject:@"TX;"] && [noCallStation.keyer.activeBufferText isEqualToString:@"EA0XYZ DE EA3JIC K"] &&
                   [noCallTxField.stringValue isEqualToString:@"EA0XYZ DE EA3JIC K"], @"Wideband Answer sends the answer with the callsign");
        AssertTrue([stationLog.lastObject containsString:@"Tuned & answered EA0XYZ"], @"With a callsign the wideband Answer logs the answer");
        [noCallStation.keyer abortTransmission];
        NSLog(@"PASS: Station buttons never send a missing callsign.");

        // 6. Test Keyer Audio Keying & Transmission Control
        __block NSMutableArray<NSString *> *sentCommands = [NSMutableArray array];
        keyer.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) {
            [sentCommands addObject:catCommand];
            return YES;
        };

        keyer.wpm = 24;
        [keyer transmitText:@"CQ CQ DE EP2AES K" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue([sentCommands containsObject:@"TX;"], @"Keyer sends TX; CAT command");
        AssertTrue(keyer.isTransmitting, @"Keyer is in transmitting state");
        AssertTrue([keyer.activeBufferText isEqualToString:@"CQ CQ DE EP2AES K"], @"Buffer text is active");
        [keyer abortTransmission];
        AssertTrue([sentCommands containsObject:@"RX;"], @"Keyer unkeys with RX;");
        AssertTrue(!keyer.isTransmitting, @"Keyer transmission terminated");
        NSLog(@"PASS: Keyer audio-based Morse transmission and PTT sequencing verified.");

        // 6b. The release timers are armed before any sound. A sidetone that raises (the engine
        // stopped by an output change) neither escapes the keyer nor skips the RX; release; a Morse
        // audio stage that raises still gets RX; at the estimated end; and the Tune cutoff is armed
        // before the carrier starts. "E" at 45 WPM has the 0.2 s floor estimate.
        TX500CWKeyer *soundKeyer = [[TX500CWKeyer alloc] init];
        soundKeyer.wpm = 45;
        __block NSMutableArray<NSString *> *soundCmds = [NSMutableArray array];
        __block NSMutableArray<NSString *> *soundLog = [NSMutableArray array];
        soundKeyer.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [soundCmds addObject:catCommand]; return YES; };
        soundKeyer.logHandler = ^(NSString *line) { [soundLog addObject:line]; };
        [soundKeyer setValue:[RaisingSidetoneEngine new] forKey:@"sidetoneEngine"];
        [soundKeyer setValue:[RaisingSidetonePlayer new] forKey:@"sidetonePlayer"];
        [soundKeyer setValue:@YES forKey:@"sidetoneEngineReady"];
        BOOL raised = NO;
        @try { [soundKeyer transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""]; } @catch (NSException *e) { (void)e; raised = YES; }
        AssertTrue(!raised && soundKeyer.isTransmitting && [soundCmds containsObject:@"TX;"], @"A raising sidetone does not stop the transmission");
        AssertTrue(![[soundKeyer valueForKey:@"sidetoneEngineReady"] boolValue], @"A raising sidetone is switched off for the session");
        BOOL sidetoneLogged = NO; for (NSString *line in soundLog) if ([line containsString:@"sidetone"]) sidetoneLogged = YES;
        AssertTrue(sidetoneLogged, @"The console says the sidetone is off");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.7]];
        AssertTrue(!soundKeyer.isTransmitting && [soundCmds containsObject:@"RX;"], @"RX; still goes out at the estimated end after a sidetone failure");
        Method morseAudioMethod = class_getInstanceMethod([TX500CWKeyer class], NSSelectorFromString(@"playMorseAudioForText:wpm:pitchHz:token:"));
        IMP morseAudioOriginal = method_setImplementation(morseAudioMethod, imp_implementationWithBlock(^double(id k, NSString *t, NSInteger w, double p, NSUInteger tok) {
            (void)k; (void)t; (void)w; (void)p; (void)tok; [NSException raise:@"CWStationTests" format:@"Morse audio failed"]; return 0; }));
        [soundCmds removeAllObjects];
        raised = NO;
        @try { [soundKeyer transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""]; } @catch (NSException *e) { (void)e; raised = YES; }
        AssertTrue(raised && [soundCmds containsObject:@"TX;"], @"The Morse audio stage raised after TX; (what the app's event loop swallows)");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.7]];
        AssertTrue(!soundKeyer.isTransmitting && [soundCmds containsObject:@"RX;"], @"RX; goes out at the estimated end even when the audio stage raised");
        method_setImplementation(morseAudioMethod, morseAudioOriginal);
        [soundKeyer setValue:@YES forKey:@"sidetoneEngineReady"];
        raised = NO;
        @try { [soundKeyer startContinuousCarrierWithPitchHz:650.0]; } @catch (NSException *e) { (void)e; raised = YES; }
        AssertTrue(!raised && [[soundKeyer valueForKey:@"isContinuousCarrier"] boolValue], @"A raising sidetone does not stop the tuning carrier");
        [soundKeyer stopContinuousCarrier];
        TX500CWStationController *tuneStation = [TX500CWStationController new];
        __block NSMutableArray<NSString *> *tuneCmds = [NSMutableArray array];
        tuneStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [tuneCmds addObject:catCommand]; return YES; };
        [tuneStation setValue:@0.2 forKey:@"manualTuneCutoffSeconds"];
        Method carrierMethod = class_getInstanceMethod([TX500CWKeyer class], @selector(startContinuousCarrierWithPitchHz:));
        IMP carrierOriginal = method_setImplementation(carrierMethod, imp_implementationWithBlock(^(id k, double p) { (void)k; (void)p; [NSException raise:@"CWStationTests" format:@"carrier failed"]; }));
        raised = NO;
        @try { [tuneStation toggleManualTransmit]; } @catch (NSException *e) { (void)e; raised = YES; }
        method_setImplementation(carrierMethod, carrierOriginal);
        AssertTrue(raised && tuneStation.isManualTuneActive && [tuneCmds containsObject:@"TX;"], @"The carrier stage raised after TX;");
        AssertTrue([tuneStation valueForKey:@"txMeterPollingTimer"] != nil, @"Meter polling was started before the carrier");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.6]];
        AssertTrue(!tuneStation.isManualTuneActive && [tuneCmds containsObject:@"RX;"], @"The Tune cutoff armed before the carrier still releases the radio");
        NSLog(@"PASS: Release timers and the Tune cutoff are armed before any sound.");

        // 6c. The CW transmit audio goes only to the radio's own output: the profile's Radio
        // transmit output, else the exact pair of the radio's USB input, else none. Never the
        // first USB output of the Mac, and never a headset's own output. Invented devices.
        NSString *headsetIn = @"AppleUSBAudioEngine:Acme:Headset:0001:1", *headsetOut = @"AppleUSBAudioEngine:Acme:Headset:0001:2";
        NSString *radioIn = @"AppleUSBAudioEngine:TTGK Technology:USB Audio:0007:2", *radioOut = @"AppleUSBAudioEngine:TTGK Technology:USB Audio:0007:1";
        NSArray<NSDictionary<NSString *, NSString *> *> *routeInputs = @[
            @{@"uid": headsetIn, @"name": @"Acme Headset", @"isPreferredUSBAudio": @"NO"},
            @{@"uid": radioIn, @"name": @"USB Audio", @"isPreferredUSBAudio": @"YES"},
            @{@"uid": TX500CWSystemAudioDeviceUID, @"name": @"System Audio", @"isPreferredUSBAudio": @"NO"}];
        TX500AudioDeviceItem *headsetOutItem = [TX500AudioDeviceItem new]; headsetOutItem.uid = headsetOut; headsetOutItem.name = @"Acme Headset";
        TX500AudioDeviceItem *radioOutItem = [TX500AudioDeviceItem new]; radioOutItem.uid = radioOut; radioOutItem.name = @"USB Audio";
        TX500AudioDeviceItem *secondRadioOutItem = [TX500AudioDeviceItem new];
        secondRadioOutItem.uid = @"AppleUSBAudioEngine:TTGK Technology:USB Audio:0007:3"; secondRadioOutItem.name = @"USB Audio";
        NSArray<TX500AudioDeviceItem *> *routeOutputs = @[headsetOutItem, radioOutItem];
        AssertTrue([TX500CWStationController pairedRadioOutputUIDForInputUID:headsetIn inputDevices:routeInputs outputDevices:routeOutputs] == nil,
                   @"a headset's own output is never the radio's");
        AssertTrue([[TX500CWStationController pairedRadioOutputUIDForInputUID:radioIn inputDevices:routeInputs outputDevices:routeOutputs] isEqualToString:radioOut],
                   @"the radio's input finds its exact pair");
        AssertTrue([TX500CWStationController pairedRadioOutputUIDForInputUID:radioIn inputDevices:routeInputs
                                                               outputDevices:@[headsetOutItem, radioOutItem, secondRadioOutItem]] == nil,
                   @"an ambiguous pair is no pair");
        AssertTrue([TX500CWStationController pairedRadioOutputUIDForInputUID:TX500CWSystemAudioDeviceUID inputDevices:routeInputs outputDevices:routeOutputs] == nil,
                   @"System Audio has no radio output");
        AssertTrue([TX500CWStationController pairedRadioOutputUIDForInputUID:@"AppleUSBAudioEngine:TTGK Technology:USB Audio:0009:2"
                                                                inputDevices:routeInputs outputDevices:routeOutputs] == nil,
                   @"an input absent from the list has no radio output");
        // Another radio interface (a Digirig, listed by the decoder as USB but not as the TX-500's
        // codec) finds its pair too; a USB headset that only says "USB" never does.
        NSString *digirigIn = @"AppleUSBAudioEngine:Acme:Digirig Mobile:0011:1", *digirigOut = @"AppleUSBAudioEngine:Acme:Digirig Mobile:0011:2";
        NSString *usbHeadsetIn = @"AppleUSBAudioEngine:Acme:USB Headset:0012:1", *usbHeadsetOut = @"AppleUSBAudioEngine:Acme:USB Headset:0012:2";
        NSArray<NSDictionary<NSString *, NSString *> *> *interfaceInputs = @[
            @{@"uid": digirigIn, @"name": @"Digirig Mobile", @"isPreferredUSBAudio": @"NO", @"isUSB": @"YES"},
            @{@"uid": usbHeadsetIn, @"name": @"USB Headset", @"isPreferredUSBAudio": @"NO", @"isUSB": @"YES"}];
        TX500AudioDeviceItem *digirigOutItem = [TX500AudioDeviceItem new]; digirigOutItem.uid = digirigOut; digirigOutItem.name = @"Digirig Mobile";
        TX500AudioDeviceItem *usbHeadsetOutItem = [TX500AudioDeviceItem new]; usbHeadsetOutItem.uid = usbHeadsetOut; usbHeadsetOutItem.name = @"USB Headset";
        NSArray<TX500AudioDeviceItem *> *interfaceOutputs = @[usbHeadsetOutItem, digirigOutItem, headsetOutItem];
        AssertTrue([[TX500CWStationController pairedRadioOutputUIDForInputUID:digirigIn inputDevices:interfaceInputs outputDevices:interfaceOutputs] isEqualToString:digirigOut],
                   @"a Digirig finds its own output");
        AssertTrue([TX500CWStationController pairedRadioOutputUIDForInputUID:usbHeadsetIn inputDevices:interfaceInputs outputDevices:interfaceOutputs] == nil,
                   @"a USB headset never finds a radio output");
        // The Mac's "first USB output" is made up too, so the checks hold on any Mac: a DAC.
        Method firstUSBMethod = class_getClassMethod([TX500CWKeyer class], @selector(findBestUSBAudioOutputUID));
        IMP firstUSBOriginal = method_setImplementation(firstUSBMethod, imp_implementationWithBlock(^NSString *(id cls) {
            (void)cls; return @"AppleUSBAudioEngine:Acme:DAC:0003:1"; }));
        TX500CWKeyer *routeKeyer = [[TX500CWKeyer alloc] init];
        routeKeyer.radioOutputDeviceUID = @"profile-out";
        routeKeyer.pairedRadioOutputDeviceUID = @"pair-out";
        AssertTrue([[routeKeyer radioAudioTargetUID] isEqualToString:@"profile-out"], @"the profile's choice wins");
        routeKeyer.radioOutputDeviceUID = @"";
        AssertTrue([[routeKeyer radioAudioTargetUID] isEqualToString:@"pair-out"], @"without a profile output the pair is used");
        routeKeyer.pairedRadioOutputDeviceUID = nil;
        AssertTrue([routeKeyer radioAudioTargetUID] == nil, @"with nothing chosen there is no output, never the first USB one");
        // The station: a headset chosen as the CW input gives no output, and the profile's
        // choice (written by the host) is never overwritten.
        TX500CWStationController *routeStation = [TX500CWStationController new];
        SEL routeUpdate = NSSelectorFromString(@"updateKeyerRadioOutputDevice"); // private: called before every keying
        void (*updateRoute)(id, SEL) = (void (*)(id, SEL))[routeStation methodForSelector:routeUpdate];
        __block NSMutableArray<NSString *> *routeLog = [NSMutableArray array];
        routeStation.logHandler = ^(NSString *line) { [routeLog addObject:line]; };
        [[routeStation.decoder valueForKey:@"internalAudioDevices"] setArray:routeInputs];
        [[routeStation.audioEngine valueForKey:@"internalOutputDevices"] setArray:routeOutputs];
        routeStation.keyer.radioOutputDeviceUID = nil;
        routeStation.decoder.selectedAudioDeviceUID = headsetIn;
        updateRoute(routeStation, routeUpdate);
        AssertTrue(routeStation.keyer.pairedRadioOutputDeviceUID == nil && routeStation.keyer.radioOutputDeviceUID == nil,
                   @"a headset input sets no radio output, and the profile's output is untouched");
        AssertTrue([routeLog.lastObject containsString:@"No radio transmit output"], @"the console names the missing radio transmit output");
        routeStation.decoder.selectedAudioDeviceUID = radioIn;
        updateRoute(routeStation, routeUpdate);
        AssertTrue([routeStation.keyer.pairedRadioOutputDeviceUID isEqualToString:radioOut] && routeStation.keyer.radioOutputDeviceUID == nil &&
                   [[routeStation.keyer radioAudioTargetUID] isEqualToString:radioOut], @"the radio's input routes the transmit audio to its pair");
        AssertTrue([routeLog.lastObject containsString:@"Radio transmit output: USB Audio"] && [routeLog.lastObject containsString:radioOut],
                   @"the console names the radio transmit output");
        NSUInteger routeLines = routeLog.count;
        updateRoute(routeStation, routeUpdate);
        AssertTrue(routeLog.count == routeLines, @"the same output is named once");
        routeStation.keyer.radioOutputDeviceUID = @"profile-out";
        updateRoute(routeStation, routeUpdate);
        AssertTrue([routeStation.keyer.radioOutputDeviceUID isEqualToString:@"profile-out"] &&
                   [[routeStation.keyer radioAudioTargetUID] isEqualToString:@"profile-out"], @"the station never overwrites the profile's output");
        method_setImplementation(firstUSBMethod, firstUSBOriginal);
        NSLog(@"PASS: CW transmit audio goes only to the radio's own output.");
        // 6c (continued). No keying before the radio's audio output is open: with the output
        // refused, Send and TX (Tune) send no TX;, start nothing and say why. Practice needs no
        // radio output. With the output ready (twice in a row, from the queue already open) the
        // keying is unchanged.
        Method readyMethod = class_getInstanceMethod([TX500CWKeyer class], @selector(ensureRadioAudioReady));
        __block NSUInteger readyCalls = 0;
        IMP readyOriginal = method_setImplementation(readyMethod, imp_implementationWithBlock(^BOOL(id k) { (void)k; readyCalls++; return NO; }));
        TX500CWStationController *readyStation = [TX500CWStationController new];
        readyStation.keyer.myCallsign = @"EA3JIC";
        readyStation.keyer.wpm = 45;
        __block NSMutableArray<NSString *> *readyCmds = [NSMutableArray array];
        __block NSMutableArray<NSString *> *readyLog = [NSMutableArray array];
        readyStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [readyCmds addObject:catCommand]; return YES; };
        readyStation.logHandler = ^(NSString *line) { [readyLog addObject:line]; };
        NSUInteger readyHistory = readyStation.keyer.sentHistory.count;
        NSTextField *readyStatus = [readyStation valueForKey:@"carrierLockStatusLabel"];
        [readyStation.keyer transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(readyCalls == 1 && ![readyCmds containsObject:@"TX;"] && !readyStation.keyer.isTransmitting &&
                   readyStation.keyer.sentHistory.count == readyHistory && ![readyStatus.stringValue containsString:@"ON THE AIR"],
                   @"no audio output, no keying");
        [readyStation toggleManualTransmit];
        BOOL tuneRefusalLogged = NO; for (NSString *line in readyLog) if ([line containsString:@"not started"]) tuneRefusalLogged = YES;
        AssertTrue(![readyCmds containsObject:@"TX;"] && !readyStation.isManualTuneActive && tuneRefusalLogged,
                   @"no audio output, no Tune");
        NSButton *readyPractice = [readyStation valueForKey:@"simulationCheckbox"];
        readyPractice.state = NSControlStateValueOn;
        [readyStation toggleSimulation:readyPractice];
        readyCalls = 0;
        [readyStation.keyer transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(readyStation.keyer.isTransmitting && readyCalls == 0, @"practice needs no radio output");
        [readyStation.keyer abortTransmission];
        readyPractice.state = NSControlStateValueOff;
        [readyStation toggleSimulation:readyPractice];
        method_setImplementation(readyMethod, readyOriginal);
        // The queue already open on the chosen output answers YES from its properties alone.
        readyStation.keyer.radioOutputDeviceUID = @"radio-out";
        [readyStation.keyer setValue:@YES forKey:@"radioQueueReady"];
        [readyStation.keyer setValue:@"radio-out" forKey:@"activeRadioUID"];
        AssertTrue([readyStation.keyer ensureRadioAudioReady] && [readyStation.keyer ensureRadioAudioReady],
                   @"the queue already open on the radio output is ready every time");
        for (int send = 0; send < 2; send++) {
            [readyCmds removeAllObjects];
            [readyStation.keyer transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""];
            AssertTrue([readyCmds containsObject:@"TX;"] && readyStation.keyer.isTransmitting, @"with the output ready the keying is unchanged");
            [readyStation.keyer abortTransmission];
        }
        [readyStation.keyer setValue:@NO forKey:@"radioQueueReady"];
        [readyStation.keyer setValue:nil forKey:@"activeRadioUID"];
        NSLog(@"PASS: No keying before the radio audio output is ready.");

        // 6d. Every keyer path stops a running Tune first (Auto-CQ, the roster Answer, the
        // wideband Answer, as Send, the macros and the assistant step already did); no Tune starts
        // while Auto-CQ runs; and a Tune's cutoff stops only that Tune, not a newer one.
        TX500CWStationController *pathStation = [TX500CWStationController new];
        pathStation.keyer.myCallsign = @"EA3JIC";
        pathStation.assistant.myCallsign = @"EA3JIC";
        __block NSMutableArray<NSString *> *pathCmds = [NSMutableArray array];
        __block NSMutableArray<NSString *> *pathLog = [NSMutableArray array];
        pathStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [pathCmds addObject:catCommand]; return YES; };
        pathStation.logHandler = ^(NSString *line) { [pathLog addObject:line]; };
        BOOL (^releasedBeforeKeying)(void) = ^BOOL { // an RX; and, after it, the new TX;
            NSUInteger rx = [pathCmds indexOfObject:@"RX;"];
            if (rx == NSNotFound) return NO;
            for (NSUInteger i = rx + 1; i < pathCmds.count; i++) if ([pathCmds[i] isEqualToString:@"TX;"]) return YES;
            return NO;
        };
        [pathStation toggleManualTransmit];
        AssertTrue(pathStation.isManualTuneActive && [pathCmds containsObject:@"TX;"], @"Tune keys the radio");
        [pathCmds removeAllObjects];
        [pathStation toggleAutoCQ:nil];
        AssertTrue(!pathStation.isManualTuneActive && pathStation.keyer.isAutoCQActive && pathStation.keyer.isTransmitting && releasedBeforeKeying(),
                   @"Auto-CQ stops a running Tune first");
        [pathStation toggleAutoCQ:nil];
        [pathStation.keyer abortTransmission];
        [pathStation.assistant processDecodedTextStream:@"CQ CQ DE EP2AES EP2AES K" currentWPM:22.0 snrDb:14.5];
        AssertTrue(pathStation.assistant.heardStations.count >= 1, @"The station heard EP2AES");
        [pathStation toggleManualTransmit];
        [pathCmds removeAllObjects];
        NSButton *pathAnswer = [NSButton new];
        pathAnswer.tag = 0;
        [pathStation rosterAnswerClicked:pathAnswer];
        AssertTrue(!pathStation.isManualTuneActive && pathStation.keyer.isTransmitting && releasedBeforeKeying(), @"the roster Answer stops the Tune");
        [pathStation.keyer abortTransmission];
        [pathStation toggleManualTransmit];
        [pathCmds removeAllObjects];
        TX500CWChannelState *pathChannel = [TX500CWChannelState new];
        pathChannel.frequencyHz = 900.0;
        pathChannel.estimatedWPM = 22.0;
        pathChannel.snrDb = 12.0;
        pathChannel.extractedCallsign = @"0A1ZZ";
        [pathStation answerWidebandChannel:pathChannel];
        AssertTrue(!pathStation.isManualTuneActive && [pathStation.keyer.activeBufferText isEqualToString:@"0A1ZZ DE EA3JIC K"] && releasedBeforeKeying(),
                   @"the wideband Answer stops the Tune");
        // Auto-CQ between two calls (the keyer idle, Auto-CQ still on): Tune is refused.
        [pathStation.keyer abortTransmission];
        [pathStation toggleAutoCQ:nil];
        [pathStation.keyer abortTransmission];
        AssertTrue(pathStation.keyer.isAutoCQActive && !pathStation.keyer.isTransmitting, @"Auto-CQ waits between two calls");
        [pathCmds removeAllObjects];
        [pathLog removeAllObjects];
        [pathStation toggleManualTransmit];
        BOOL autoCQRefusalLogged = NO; for (NSString *line in pathLog) if ([line containsString:@"stop Auto-CQ"]) autoCQRefusalLogged = YES;
        AssertTrue(![pathCmds containsObject:@"TX;"] && !pathStation.isManualTuneActive && autoCQRefusalLogged, @"no Tune while Auto-CQ runs");
        [pathStation toggleAutoCQ:nil];
        AssertTrue(!pathStation.keyer.isAutoCQActive, @"Auto-CQ stopped");
        // A message on the air ("E" at 20 WPM, 0.24 s): TX (Tune) is refused, no second TX;.
        pathStation.keyer.wpm = 20;
        [pathStation.keyer transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(pathStation.keyer.isTransmitting, @"a message is on the air");
        [pathCmds removeAllObjects];
        [pathLog removeAllObjects];
        [pathStation toggleManualTransmit];
        BOOL messageRefusalLogged = NO; for (NSString *line in pathLog) if ([line containsString:@"stop the message"]) messageRefusalLogged = YES;
        AssertTrue(![pathCmds containsObject:@"TX;"] && !pathStation.isManualTuneActive && messageRefusalLogged, @"no Tune on top of a message");
        [pathStation.keyer abortTransmission];
        // A Tune stopped and started again keeps its own cutoff (0.8 s here).
        [pathStation setValue:@0.8 forKey:@"manualTuneCutoffSeconds"];
        [pathStation toggleManualTransmit];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
        [pathStation stopManualTune];
        NSDate *secondTune = [NSDate date];
        [pathStation toggleManualTransmit];
        [pathCmds removeAllObjects];
        [[NSRunLoop mainRunLoop] runUntilDate:[secondTune dateByAddingTimeInterval:0.65]];
        AssertTrue(pathStation.isManualTuneActive && ![pathCmds containsObject:@"RX;"], @"a stale cutoff does not cut a newer Tune");
        [[NSRunLoop mainRunLoop] runUntilDate:[secondTune dateByAddingTimeInterval:1.1]];
        AssertTrue(!pathStation.isManualTuneActive && [pathCmds containsObject:@"RX;"], @"the newer Tune has its own cutoff");
        NSLog(@"PASS: Every keyer path stops the Tune; a cutoff stops only its own Tune.");

        // 7. Test QSO Assistant Pattern Detection & Callsign Extraction
        TX500CWQSOAssistant *assistant = [[TX500CWQSOAssistant alloc] init];
        assistant.myCallsign = @"EP2AES";

        [assistant processDecodedTextStream:@"CQ CQ DE G4XYZ G4XYZ K" currentWPM:22.0 snrDb:14.5];
        AssertTrue(assistant.heardStations.count >= 1, @"Recorded heard station");
        AssertTrue([assistant.heardStations[0].callsign isEqualToString:@"G4XYZ"], @"Callsign is G4XYZ");
        AssertTrue(assistant.heardStations[0].wpm == 22.0, @"Station WPM is 22");
        NSLog(@"PASS: QSO Assistant CQ pattern parsing and callsign extraction verified.");

        // 8. Test Semi-Automated QSO State Machine
        [assistant selectAndAnswerStation:assistant.heardStations[0]];
        AssertTrue(assistant.qsoState == TX500QSOStateAnsweringCQ, @"State is AnsweringCQ");
        AssertTrue([assistant.suggestedActionTitle containsString:@"G4XYZ"], @"Action targets G4XYZ");

        // Step 1: Send Call
        [assistant advanceQSOStepWithAction:^(NSString * _Nonnull macroToTransmit) {
            AssertTrue([macroToTransmit containsString:@"G4XYZ DE EP2AES"], @"Transmits call reply");
        }];
        AssertTrue(assistant.qsoState == TX500QSOStateExchangeReport, @"State is ExchangeReport");

        // Simulate receiving report
        [assistant processDecodedTextStream:@"EP2AES DE G4XYZ UR 5NN 599 BK" currentWPM:22.0 snrDb:15.0];
        AssertTrue([assistant.activeRstRcvd isEqualToString:@"599"], @"RST rcvd is 599");

        // Step 2: Send Report
        [assistant advanceQSOStepWithAction:^(NSString * _Nonnull macroToTransmit) {
            AssertTrue([macroToTransmit containsString:@"599"], @"Transmits report");
        }];
        AssertTrue(assistant.qsoState == TX500QSOStateSigningOff, @"State is SigningOff");

        // Step 3: Sign-off & Log
        [assistant advanceQSOStepWithAction:^(NSString * _Nonnull macroToTransmit) {
            AssertTrue([macroToTransmit containsString:@"73"], @"Transmits 73");
        }];
        AssertTrue(assistant.qsoState == TX500QSOStateCompleted, @"State is Completed");
        AssertTrue(assistant.loggedContacts.count == 1, @"QSO logged into database");
        AssertTrue([assistant.loggedContacts[0].callsign isEqualToString:@"G4XYZ"], @"Logged contact callsign");
        AssertTrue([assistant.loggedContacts[0].mode isEqualToString:@"CW"], @"Logged mode CW");
        NSLog(@"PASS: Semi-automated QSO state machine flow and automatic logging verified.");

        // 8b. Nothing guesses a frequency when the radio does not answer FA;. A QSO whose
        // frequency was never read from the radio stays in the session list and is not saved
        // to the Logbook or uploaded on its own.
        TX500CWQSOAssistant *noFreq = [[TX500CWQSOAssistant alloc] init];
        AssertTrue(noFreq.currentFrequencyHz == 0 && noFreq.currentBand.length == 0, @"New QSO assistant has no invented frequency or band");
        noFreq.myCallsign = @"EA3JIC";
        NSUInteger centralBefore = [[TX500LogbookManager sharedManager] allContacts].count;
        StartCountingCloudUploads();
        NSUInteger noFreqUploadsBefore = CloudUploadCount();
        [noFreq processDecodedTextStream:@"CQ CQ DE EP2AES EP2AES K" currentWPM:22.0 snrDb:14.5];
        AssertTrue(noFreq.heardStations.count >= 1, @"No-frequency assistant heard the CQ");
        [noFreq selectAndAnswerStation:noFreq.heardStations[0]];
        for (int step = 0; step < 3 && noFreq.qsoState != TX500QSOStateCompleted; step++)
            [noFreq advanceQSOStepWithAction:^(NSString * _Nonnull macroToTransmit) { (void)macroToTransmit; }];
        AssertTrue(noFreq.qsoState == TX500QSOStateCompleted && noFreq.loggedContacts.count == 1, @"No-frequency QSO completes in the session list");
        AssertTrue([noFreq.loggedContacts[0].notes containsString:@"not saved"], @"No-frequency QSO says it was not saved");
        AssertTrue(noFreq.loggedContacts[0].frequencyMHz == 0.0 && noFreq.loggedContacts[0].band.length == 0, @"No-frequency QSO gets no invented frequency or band");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        AssertTrue([[TX500LogbookManager sharedManager] allContacts].count == centralBefore, @"No-frequency QSO is not saved to the central Logbook");
        AssertTrue(CloudUploadCount() == noFreqUploadsBefore, @"No-frequency QSO is not uploaded");

        // The CW station: no frequency, band or band chip until the radio reports one.
        TX500CWStationController *cwStation = [TX500CWStationController new];
        NSTextField *cwVFO = [cwStation valueForKey:@"vfoLabel"];
        NSTextField *cwRF = [cwStation valueForKey:@"vfoOffsetLabel"];
        NSSegmentedControl *cwBands = [cwStation valueForKey:@"bandSelectorControl"];
        AssertTrue(cwStation.currentDialFrequencyHz == 0 && cwStation.assistant.currentFrequencyHz == 0 && cwStation.assistant.currentBand.length == 0,
                   @"A new CW station has no frequency or band");
        AssertTrue(cwVFO && ![cwVFO.stringValue containsString:@"14."] && [cwRF.stringValue containsString:@"RF: unknown"] && cwBands.selectedSegment == -1,
                   @"A new CW station shows no frequency and no band chip");
        __block NSMutableArray<NSString *> *cwCommands = [NSMutableArray array];
        __block NSString *syncLine = @"";
        cwStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [cwCommands addObject:catCommand]; return YES; };
        cwStation.logHandler = ^(NSString *line) { syncLine = line; };
        [cwStation updateFrequencyHz:0 mode:@"DIG"]; // what the radio sync passes when FA; gets no usable reply (the radio in DIG)
        AssertTrue(cwStation.currentDialFrequencyHz == 0 && cwStation.assistant.currentFrequencyHz == 0 && cwStation.assistant.currentBand.length == 0,
                   @"No radio answer keeps the CW frequency and band unknown");
        AssertTrue([syncLine containsString:@"Radio frequency unavailable"] && [syncLine containsString:@"unknown"], @"The console says the CW frequency is unknown");
        [cwStation stepFrequencyHz:100];
        BOOL steppedBlind = NO;
        for (NSString *cmd in cwCommands) if ([cmd hasPrefix:@"FA"]) steppedBlind = YES;
        AssertTrue(!steppedBlind && cwStation.currentDialFrequencyHz == 0 && [syncLine containsString:@"VFO not stepped"],
                   @"A VFO step with no known frequency sends no FA and says why");
        // A waterfall click and the wideband Answer above 1500 Hz need a retune: with no
        // frequency read neither sends FA, the Answer keys nothing, and the console says why.
        void (^waterfallClick)(double) = [[cwStation valueForKey:@"spectrumView"] valueForKey:@"onWaterfallFrequencyClicked"];
        AssertTrue(waterfallClick != nil, @"The CW waterfall click handler is set");
        syncLine = @"";
        waterfallClick(1200.0);
        steppedBlind = NO;
        for (NSString *cmd in cwCommands) if ([cmd hasPrefix:@"FA"]) steppedBlind = YES;
        AssertTrue(!steppedBlind && cwStation.currentDialFrequencyHz == 0 && [syncLine containsString:@"VFO not stepped"] && ![syncLine containsString:@"Retuned"],
                   @"A waterfall click with no known frequency sends no FA and does not claim a retune");
        cwStation.keyer.myCallsign = @"EA3JIC";
        cwStation.assistant.myCallsign = @"EA3JIC";
        TX500CWChannelState *farChannel = [TX500CWChannelState new];
        farChannel.frequencyHz = 1800.0;
        farChannel.estimatedWPM = 22.0;
        farChannel.snrDb = 12.0;
        farChannel.extractedCallsign = @"EP2AES";
        double pitchBefore = cwStation.decoder.nominalPitchHz;
        syncLine = @"";
        [cwStation answerWidebandChannel:farChannel];
        steppedBlind = NO;
        for (NSString *cmd in cwCommands) if ([cmd hasPrefix:@"FA"]) steppedBlind = YES;
        AssertTrue(!steppedBlind && ![cwCommands containsObject:@"TX;"] && !cwStation.keyer.isTransmitting && cwStation.decoder.nominalPitchHz == pitchBefore,
                   @"The wideband Answer above 1500 Hz with no known frequency neither retunes nor keys");
        AssertTrue([syncLine containsString:@"Cannot retune to answer"] && ![syncLine containsString:@"answered"],
                   @"The wideband Answer says why it sent nothing");
        [cwStation.keyer abortTransmission];
        [cwStation updateFrequencyHz:7030000 mode:@"CW"]; // read from the radio
        AssertTrue([cwVFO.stringValue isEqualToString:@"7.030.000 MHz"] && cwBands.selectedSegment == 2, @"A frequency read from the radio shows on the VFO and the 40m chip");
        syncLine = @"";
        [cwStation updateFrequencyHz:0 mode:@"DIG"]; // one missed FA; reply later
        AssertTrue(cwStation.currentDialFrequencyHz == 7030000 && cwStation.assistant.currentFrequencyHz == 7030000 &&
                   [cwStation.assistant.currentBand isEqualToString:@"40m"], @"A missed radio answer keeps the frequency and band known before");
        AssertTrue([syncLine containsString:@"keeping the last known 7.030 MHz"], @"The console says the frequency known before is kept");
        [cwStation stepFrequencyHz:100];
        AssertTrue([cwCommands containsObject:@"FA00007030100;"] && cwStation.assistant.currentFrequencyHz == 7030100, @"With a known frequency the VFO step is sent");
        [cwStation setValue:@0 forKey:@"userTuningLockoutUntil"];
        cwStation.logHandler = nil;
        [cwStation updateFrequencyHz:5357000 mode:@"CW"];
        AssertTrue([cwStation.assistant.currentBand isEqualToString:@"60m"] && cwBands.selectedSegment == -1, @"CW uses the Logbook band table (5.357 MHz is 60m, no chip)");
        [cwStation updateFrequencyHz:4500000 mode:@"CW"];
        AssertTrue(cwStation.assistant.currentBand.length == 0 && cwBands.selectedSegment == -1, @"A frequency in no band leaves the CW band unknown");
        [cwStation tuneToFrequencyHz:4510000];
        AssertTrue(cwStation.assistant.currentBand.length == 0, @"Tuning to a frequency in no band gives no invented band");

        // Control: with a frequency read from the radio the QSO is saved and uploaded as before.
        TX500CWQSOAssistant *withFreq = [[TX500CWQSOAssistant alloc] init];
        withFreq.myCallsign = @"EA3JIC";
        withFreq.currentFrequencyHz = 14050000;
        withFreq.currentBand = @"20m";
        [withFreq processDecodedTextStream:@"CQ CQ DE EP2AES EP2AES K" currentWPM:22.0 snrDb:14.5];
        AssertTrue(withFreq.heardStations.count >= 1, @"Control assistant heard the CQ");
        [withFreq selectAndAnswerStation:withFreq.heardStations[0]];
        for (int step = 0; step < 3 && withFreq.qsoState != TX500QSOStateCompleted; step++)
            [withFreq advanceQSOStepWithAction:^(NSString * _Nonnull macroToTransmit) { (void)macroToTransmit; }];
        AssertTrue(withFreq.qsoState == TX500QSOStateCompleted && withFreq.loggedContacts[0].notes.length == 0, @"Control QSO completes without a note");
        AssertTrue([[TX500LogbookManager sharedManager] allContacts].count == centralBefore + 1, @"A QSO with a frequency read from the radio is saved to the central Logbook");
        AssertTrue(CloudUploadCount() == noFreqUploadsBefore + 1, @"A QSO with a frequency read from the radio is uploaded");
        // A QSO on a frequency in no band is saved and uploaded with the band table's answer.
        TX500CWQSOAssistant *offBand = [[TX500CWQSOAssistant alloc] init];
        offBand.myCallsign = @"EA3JIC";
        offBand.currentFrequencyHz = 4500000;
        offBand.currentBand = @"";
        [offBand processDecodedTextStream:@"CQ CQ DE EP2AES EP2AES K" currentWPM:22.0 snrDb:14.5];
        [offBand selectAndAnswerStation:offBand.heardStations[0]];
        for (int step = 0; step < 3 && offBand.qsoState != TX500QSOStateCompleted; step++)
            [offBand advanceQSOStepWithAction:^(NSString * _Nonnull macroToTransmit) { (void)macroToTransmit; }];
        NSString *tableBand = [[TX500LogRecord bandForFrequencyHz:4500000] lowercaseString];
        TX500LogRecord *offBandRec = nil;
        for (TX500LogRecord *r in [[TX500LogbookManager sharedManager] allContacts]) if (r.frequencyHz == 4500000) offBandRec = r;
        AssertTrue(offBandRec && [offBandRec.band isEqualToString:tableBand] && [CloudUploadLastBand isEqualToString:tableBand],
                   @"A CW QSO in no band is saved and uploaded with the band table's answer");
        StopCountingCloudUploads();
        __block NSString *stationLine = @"";
        cwStation.logHandler = ^(NSString *line) { stationLine = line; };
        cwStation.assistant.onContactLogged(noFreq.loggedContacts[0]);
        AssertTrue([stationLine containsString:@"not saved to the Logbook"] && ![stationLine containsString:@"Logged QSO"],
                   @"The console says a no-frequency QSO was not saved");
        TX500QSOContact *noBand = [TX500QSOContact new];
        noBand.callsign = @"EP2AES"; noBand.mode = @"CW"; noBand.frequencyMHz = 4.5; noBand.band = @"";
        cwStation.assistant.onContactLogged(noBand);
        AssertTrue([stationLine containsString:@"band unknown"], @"The console says when the band is unknown");
        NSLog(@"PASS: CW never logs, uploads or tunes from an invented frequency.");

        // 8c. Practice / Sim makes up the Morse and transmits nothing. Even with a frequency
        // read from the radio, a QSO done in practice stays in the session list only: it is
        // not saved to the Logbook and not uploaded. A real QSO is not touched.
        TX500CWStationController *practiceStation = [TX500CWStationController new];
        TX500CWQSOAssistant *practice = practiceStation.assistant;
        practice.myCallsign = @"EA3JIC";
        practice.currentFrequencyHz = 7030000;
        practice.currentBand = @"40m";
        practiceStation.decoder.isSimulationActive = YES; // the station's Practice / Sim switch
        NSUInteger practiceLogbookBefore = [[TX500LogbookManager sharedManager] allContacts].count;
        StartCountingCloudUploads();
        NSUInteger practiceUploadsBefore = CloudUploadCount();
        [practice processDecodedTextStream:@"CQ CQ DE EP2AES EP2AES K" currentWPM:22.0 snrDb:14.5];
        AssertTrue(practice.heardStations.count >= 1, @"Practice assistant heard the CQ");
        [practice selectAndAnswerStation:practice.heardStations[0]];
        for (int step = 0; step < 3 && practice.qsoState != TX500QSOStateCompleted; step++)
            [practice advanceQSOStepWithAction:^(NSString * _Nonnull macroToTransmit) { (void)macroToTransmit; }];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        AssertTrue(practice.qsoState == TX500QSOStateCompleted && practice.loggedContacts.count == 1, @"Practice QSO completes in the session list");
        AssertTrue([[TX500LogbookManager sharedManager] allContacts].count == practiceLogbookBefore, @"Practice QSO is not saved to the central Logbook");
        AssertTrue(CloudUploadCount() == practiceUploadsBefore, @"Practice QSO is not uploaded");
        AssertTrue([practice.loggedContacts[0].notes hasPrefix:@"Practice / Sim"], @"Practice QSO says it is practice");
        StopCountingCloudUploads();
        practiceStation.decoder.isSimulationActive = NO;
        __block NSString *practiceLine = @"";
        practiceStation.logHandler = ^(NSString *line) { practiceLine = line; };
        practiceStation.assistant.onContactLogged(practice.loggedContacts[0]);
        AssertTrue([practiceLine containsString:@"Practice / Sim"] && ![practiceLine containsString:@"Logged QSO"],
                   @"The console says a practice QSO was not saved");
        NSLog(@"PASS: CW Practice / Sim never logs or uploads.");

        // 8d. Practice / Sim never reaches the radio: the keyer neither opens nor feeds the radio
        // audio output, TX (Tune) keys nothing, and ticking the box releases a live Tune.
        // ensureRadioAudioReady is counted while this runs (in tests it opens nothing anyway).
        Method radioAudioMethod = class_getInstanceMethod([TX500CWKeyer class], NSSelectorFromString(@"ensureRadioAudioReady"));
        __block NSUInteger radioAudioCalls = 0;
        IMP radioAudioOriginal = method_setImplementation(radioAudioMethod, imp_implementationWithBlock(^BOOL(id k) { (void)k; radioAudioCalls++; return YES; }));
        TX500CWStationController *simKeyerStation = [TX500CWStationController new];
        simKeyerStation.keyer.myCallsign = @"EA3JIC";
        __block NSMutableArray<NSString *> *simKeyerCmds = [NSMutableArray array];
        __block NSMutableArray<NSString *> *simKeyerLog = [NSMutableArray array];
        simKeyerStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [simKeyerCmds addObject:catCommand]; return YES; };
        simKeyerStation.logHandler = ^(NSString *line) { [simKeyerLog addObject:line]; };
        __block NSUInteger simMeterQueries = 0;
        NSObject *simMeterLock = [NSObject new];
        simKeyerStation.catQueryHandler = ^NSString *(NSString *catCommand, NSTimeInterval timeout) {
            (void)catCommand; (void)timeout; @synchronized (simMeterLock) { simMeterQueries++; } return nil;
        };
        NSButton *simKeyerCheckbox = [simKeyerStation valueForKey:@"simulationCheckbox"];
        simKeyerCheckbox.state = NSControlStateValueOn;
        [simKeyerStation toggleSimulation:simKeyerCheckbox];
        [simKeyerCmds removeAllObjects];
        [simKeyerStation.keyer transmitText:@"CQ DE {MYCALL} K" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(simKeyerStation.keyer.isTransmitting && simKeyerCmds.count == 0, @"Practice Send runs the keyer but sends no CAT");
        AssertTrue(radioAudioCalls == 0, @"Practice Send never opens the radio audio output");
        [NSThread sleepForTimeInterval:0.15]; // the meter poll runs on a background queue
        @synchronized (simMeterLock) { AssertTrue(simMeterQueries == 0, @"Practice Send does not poll the radio's PWR and SWR meters"); }
        [simKeyerStation.keyer abortTransmission];
        [simKeyerStation.keyer startContinuousCarrierWithPitchHz:650.0];
        AssertTrue(radioAudioCalls == 0 && ![[simKeyerStation.keyer valueForKey:@"isContinuousCarrier"] boolValue], @"Practice never starts the radio carrier");
        [simKeyerStation toggleManualTransmit];
        AssertTrue(simKeyerCmds.count == 0 && !simKeyerStation.isManualTuneActive && radioAudioCalls == 0, @"Practice TX (Tune) keys nothing");
        AssertTrue([simKeyerLog.lastObject containsString:@"Practice / Sim"], @"Practice TX (Tune) says why");
        // Control: with the box unticked the same calls reach the radio and ask for the radio output.
        simKeyerCheckbox.state = NSControlStateValueOff;
        [simKeyerStation toggleSimulation:simKeyerCheckbox];
        [simKeyerCmds removeAllObjects];
        [simKeyerStation.keyer transmitText:@"CQ DE {MYCALL} K" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue([simKeyerCmds containsObject:@"TX;"] && radioAudioCalls == 1, @"Off practice, Send keys the radio and asks for the radio output");
        [NSThread sleepForTimeInterval:0.15];
        @synchronized (simMeterLock) { AssertTrue(simMeterQueries > 0, @"Off practice, Send polls the PWR and SWR meters"); }
        [simKeyerStation.keyer abortTransmission];
        [simKeyerCmds removeAllObjects];
        [simKeyerStation toggleManualTransmit];
        AssertTrue(simKeyerStation.isManualTuneActive && [simKeyerCmds containsObject:@"TX;"], @"Off practice, Tune keys the radio");
        // A Tune still on when the box is ticked is released at once, through the host sender.
        [simKeyerCmds removeAllObjects];
        simKeyerCheckbox.state = NSControlStateValueOn;
        [simKeyerStation toggleSimulation:simKeyerCheckbox];
        AssertTrue(!simKeyerStation.isManualTuneActive && [simKeyerCmds containsObject:@"RX;"], @"Ticking Practice releases a live Tune");
        simKeyerCheckbox.state = NSControlStateValueOff;
        [simKeyerStation toggleSimulation:simKeyerCheckbox];
        method_setImplementation(radioAudioMethod, radioAudioOriginal);
        NSLog(@"PASS: Practice / Sim never opens the radio output, never keys, and releases a live Tune.");

        // 8e. A radio that does not answer the PWR/SWR meter reads: only one read is in flight
        // at a time (a slow read is not queued behind itself, so nothing piles up in front of
        // the RX; that ends the Tune), and three silent polls stop the reads, not the Tune.
        // The next transmission polls again. The stand-in read waits 0.3 s and returns nil.
        TX500CWStationController *meterStation = [TX500CWStationController new];
        __block NSMutableArray<NSString *> *meterCmds = [NSMutableArray array];
        __block NSMutableArray<NSString *> *meterLog = [NSMutableArray array];
        meterStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [meterCmds addObject:catCommand]; return YES; };
        meterStation.logHandler = ^(NSString *line) { [meterLog addObject:line]; };
        NSObject *meterLock = [NSObject new];
        __block NSInteger meterInFlight = 0, meterMaxInFlight = 0;
        __block NSUInteger meterReads = 0;
        meterStation.catQueryHandler = ^NSString *(NSString *catCommand, NSTimeInterval timeout) {
            (void)catCommand; (void)timeout;
            @synchronized (meterLock) { meterInFlight++; meterMaxInFlight = MAX(meterMaxInFlight, meterInFlight); meterReads++; }
            [NSThread sleepForTimeInterval:0.3];
            @synchronized (meterLock) { meterInFlight--; }
            return nil;
        };
        NSDate *meterTuneStart = [NSDate date];
        [meterStation toggleManualTransmit];
        AssertTrue(meterStation.isManualTuneActive && [meterCmds containsObject:@"TX;"], @"Tune keys the radio with TX;");
        [[NSRunLoop mainRunLoop] runUntilDate:[meterTuneStart dateByAddingTimeInterval:1.0]];
        @synchronized (meterLock) {
            AssertTrue(meterMaxInFlight == 1, @"only one meter read is in flight at a time");
            AssertTrue(meterReads <= 4, @"a slow read is not queued behind itself");
        }
        [[NSRunLoop mainRunLoop] runUntilDate:[meterTuneStart dateByAddingTimeInterval:2.6]];
        BOOL meterStoppedLogged = NO;
        for (NSString *line in meterLog) if ([line containsString:@"polling stopped"]) meterStoppedLogged = YES;
        AssertTrue([meterStation valueForKey:@"txMeterPollingTimer"] == nil && meterStoppedLogged && meterStation.isManualTuneActive,
                   @"three silent polls stop the meter reads, not the Tune");
        [meterCmds removeAllObjects];
        [meterStation stopManualTune];
        AssertTrue(!meterStation.isManualTuneActive && [meterCmds containsObject:@"RX;"], @"Stopping the Tune sends RX;");
        NSUInteger meterReadsFirstTune = 0;
        @synchronized (meterLock) { meterReadsFirstTune = meterReads; }
        [meterStation toggleManualTransmit];
        AssertTrue(meterStation.isManualTuneActive && [meterStation valueForKey:@"txMeterPollingTimer"] != nil,
                   @"polling restarts with the next transmission");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.4]];
        @synchronized (meterLock) { AssertTrue(meterReads > meterReadsFirstTune, @"the next transmission reads the meters again"); }
        [meterStation stopManualTune];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.7]]; // let the last read return
        NSLog(@"PASS: One PWR/SWR meter read in flight; three silent polls stop the reads, not the Tune.");

        // 9. Test ADIF 3.1 Record Generation & File Export
        NSString *adifFull = [assistant generateFullADIFString];
        AssertTrue([adifFull containsString:@"<PROGRAMID:14>Lab599 Utility"], @"ADIF Header");
        AssertTrue([adifFull containsString:@"<CALL:5>G4XYZ"], @"ADIF Call");
        AssertTrue([adifFull containsString:@"<MODE:2>CW"], @"ADIF Mode");
        AssertTrue([adifFull containsString:@"<EOR>"], @"ADIF End of Record");

        NSURL *tempADIF = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"test_cw_log.adi"]];
        NSError *err = nil;
        BOOL exported = [assistant exportADIFToFileURL:tempADIF error:&err];
        AssertTrue(exported, @"ADIF file written successfully");
        [[NSFileManager defaultManager] removeItemAtURL:tempADIF error:nil];
        NSLog(@"PASS: ADIF 3.1 generation and file export verified.");

        // 10. Test Contest Stream Ingestion with Glued Tokens (HG8W & YE3AJJ 5NN101)
        TX500CWQSOAssistant *contestAssistant = [[TX500CWQSOAssistant alloc] init];
        contestAssistant.myCallsign = @"EP2AES";
        NSString *userStream = @"U N E H  E IUI D NT TTDW TESTMC TESTHG8W HG8W- TESTHG8W HG8W TESTOC TESTHG8W HG8W TESTOC TESTHG8W HG8W TE ETOC E TESTHG8W HM 8W TESTOC TESTHG8W HG8W THTGF YE3AJJ 5NN101 101  LT21T21L3GLTU QSLAU TESTHG8W HG8 TES T OG TESTHG8W HG8W TESTOC E G8W HG8W THTOC";
        [contestAssistant processDecodedTextStream:userStream currentWPM:26.0 snrDb:18.0];

        BOOL foundHG8W = NO, foundYE3AJJ = NO;
        for (TX500CWHeardStation *st in contestAssistant.heardStations) {
            if ([st.callsign isEqualToString:@"HG8W"]) foundHG8W = YES;
            if ([st.callsign isEqualToString:@"YE3AJJ"]) foundYE3AJJ = YES;
        }
        AssertTrue(foundHG8W, @"Identified HG8W from contest CQ stream");
        AssertTrue(foundYE3AJJ, @"Identified YE3AJJ from contest stream");
        AssertTrue([contestAssistant.activeTargetCallsign isEqualToString:@"HG8W"], @"Active target set to HG8W");
        AssertTrue([contestAssistant.suggestedActionTitle containsString:@"HG8W"], @"Suggested action title targets HG8W");
        AssertTrue([contestAssistant.suggestedActionMacro isEqualToString:@"HG8W DE EP2AES K"], @"Suggested response macro is 'HG8W DE EP2AES K'");
        NSLog(@"PASS: Contest CQ stream ingestion, glued token splitting, and contextual auto-response generation verified.");

        // 11. Test Idle State Actionability & Start Calling CQ
        TX500CWQSOAssistant *idleAssistant = [[TX500CWQSOAssistant alloc] init];
        idleAssistant.myCallsign = @"EP2AES";
        AssertTrue(idleAssistant.hasActionableStep == YES, @"Idle state must always be actionable");
        AssertTrue([idleAssistant.suggestedActionTitle isEqualToString:@"▶ Start Calling CQ (F1)"], @"Title is Start Calling CQ (F1)");
        __block NSString *idleTransmitted = nil;
        [idleAssistant advanceQSOStepWithAction:^(NSString * _Nonnull macroToTransmit) {
            idleTransmitted = macroToTransmit;
        }];
        AssertTrue(idleAssistant.qsoState == TX500QSOStateCallingCQ, @"State transitioned to CallingCQ");
        AssertTrue([idleTransmitted containsString:@"CQ CQ DE EP2AES"], @"Transmitted CQ CQ DE EP2AES");
        NSLog(@"PASS: Idle state actionability and CQ initiation verified.");

        // 11b. Before the Mac sleeps, CW Station stops everything on the air: a message, Auto-CQ and
        // a Tune get their RX; at once, because the delayed release blocks and the Tune cutoff would
        // not run until the Mac wakes. The workspace notification is posted here by hand.
        TX500CWStationController *sleepStation = [TX500CWStationController new];
        sleepStation.keyer.myCallsign = @"EA3JIC";
        __block NSMutableArray<NSString *> *sleepCmds = [NSMutableArray array];
        __block NSMutableArray<NSString *> *sleepLog = [NSMutableArray array];
        sleepStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [sleepCmds addObject:catCommand]; return YES; };
        sleepStation.logHandler = ^(NSString *line) { [sleepLog addObject:line]; };
        [sleepStation toggleAutoCQ:nil];
        AssertTrue(sleepStation.keyer.isAutoCQActive && sleepStation.keyer.isTransmitting && [sleepCmds containsObject:@"TX;"], @"Auto-CQ is on the air before sleep");
        [sleepCmds removeAllObjects];
        [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:NSWorkspaceWillSleepNotification object:nil];
        AssertTrue(!sleepStation.keyer.isTransmitting && !sleepStation.keyer.isAutoCQActive && [sleepCmds containsObject:@"RX;"], @"Sleep stops the message and Auto-CQ and sends RX; at once");
        AssertTrue([sleepLog.lastObject containsString:@"sleep"], @"The console says why the transmission stopped");
        [sleepCmds removeAllObjects];
        [sleepStation toggleManualTransmit];
        AssertTrue(sleepStation.isManualTuneActive && [sleepCmds containsObject:@"TX;"], @"Tune is on the air before sleep");
        [sleepCmds removeAllObjects];
        [NSWorkspace.sharedWorkspace.notificationCenter postNotificationName:NSWorkspaceWillSleepNotification object:nil];
        AssertTrue(!sleepStation.isManualTuneActive && [sleepCmds containsObject:@"RX;"], @"Sleep stops a Tune and sends RX; at once");
        NSLog(@"PASS: CW Station stops every transmission before the Mac sleeps.");

        // 12. Test CW Station Controller Auto Mode Switching
        TX500CWStationController *stationController = [[TX500CWStationController alloc] init];
        __block NSMutableArray<NSString *> *controllerSentCmds = [NSMutableArray array];
        stationController.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) {
            [controllerSentCmds addObject:catCommand];
            return YES;
        };
        [stationController prepareRadioForCWMode];
        AssertTrue([controllerSentCmds containsObject:@"MD6;"], @"prepareRadioForCWMode sends MD6; (DIG)");
        AssertTrue([stationController.operatingMode isEqualToString:@"DIG"], @"Operating mode is DIG");

        // User explicit override test
        [controllerSentCmds removeAllObjects];
        stationController.userHasChosenCustomMode = YES;
        stationController.operatingMode = @"CW";
        [stationController prepareRadioForCWMode];
        AssertTrue(![controllerSentCmds containsObject:@"MD6;"], @"User explicit mode choice is preserved, not overwritten");
        NSLog(@"PASS: Transceiver automatic DIG mode switching (MD6;) and user choice preservation verified.");
        // 12a. Another tab can leave the radio in FM (a Voice preset). Each entry to CW Station sets
        // DIG again, and so does a reading that finds the radio in another mode.
        TX500CWStationController *digStation = [TX500CWStationController new];
        __block NSMutableArray<NSString *> *digCmds = [NSMutableArray array];
        digStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [digCmds addObject:catCommand]; return YES; };
        NSUInteger (^md6Count)(void) = ^NSUInteger {
            return [digCmds indexesOfObjectsPassingTest:^BOOL(NSString *cmd, NSUInteger i, BOOL *stop) { (void)i; (void)stop; return [cmd isEqualToString:@"MD6;"]; }].count;
        };
        [digStation startStation];
        AssertTrue(md6Count() == 1, @"the first entry sends MD6; once");
        [digCmds removeAllObjects];
        [digStation startStation];
        AssertTrue(md6Count() == 0, @"within one entry MD6; is not repeated");
        [digStation stopStation];
        [digCmds removeAllObjects];
        [digStation startStation];
        AssertTrue(md6Count() == 1, @"a new entry sets DIG again");
        [digCmds removeAllObjects];
        [digStation setValue:@0 forKey:@"userTuningLockoutUntil"];
        [digStation updateFrequencyHz:14025000 mode:@"FM"];
        AssertTrue(md6Count() == 1, @"a radio reported in FM is put back to DIG");
        [digCmds removeAllObjects];
        [digStation setValue:@0 forKey:@"userTuningLockoutUntil"];
        [digStation updateFrequencyHz:14025000 mode:@"DIG"];
        AssertTrue(digCmds.count == 0, @"DIG reported: nothing sent");
        // The default keying needs DIG: a radio reported in CW or CW-R is put back to DIG too.
        for (NSString *cwMode in @[@"CW", @"CW-R"]) {
            [digCmds removeAllObjects];
            [digStation setValue:@0 forKey:@"userTuningLockoutUntil"];
            [digStation updateFrequencyHz:14025000 mode:cwMode];
            AssertTrue(md6Count() == 1, [NSString stringWithFormat:@"a radio reported in %@ is put back to DIG", cwMode]);
        }
        // The mode knob turned inside the tab (no reading comes): the first Send's TX; is refused by
        // the station core; the next Send, and the next Tune, set DIG before their TX;.
        TX500CWStationController *knobStation = [TX500CWStationController new];
        knobStation.keyer.wpm = 45;
        __block BOOL knobRefusesTX = NO;
        __block NSMutableArray<NSString *> *knobCmds = [NSMutableArray array];
        __block NSMutableArray<NSString *> *knobLog = [NSMutableArray array];
        knobStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) {
            [knobCmds addObject:catCommand];
            return !(knobRefusesTX && [catCommand isEqualToString:@"TX;"]);
        };
        knobStation.logHandler = ^(NSString *line) { [knobLog addObject:line]; };
        NSTextField *knobField = [knobStation valueForKey:@"txInputField"];
        BOOL (^knobDIGBeforeTX)(void) = ^BOOL {
            NSUInteger md6 = [knobCmds indexOfObject:@"MD6;"], tx = [knobCmds indexOfObject:@"TX;"];
            return md6 != NSNotFound && tx != NSNotFound && md6 < tx;
        };
        [knobStation startStation];
        AssertTrue([knobCmds containsObject:@"MD6;"], @"the entry sets DIG");
        knobRefusesTX = YES; // the knob turned to CW: the core refuses TX;
        [knobCmds removeAllObjects];
        knobField.stringValue = @"E";
        [knobStation txSendClicked:nil];
        BOOL knobSays = NO; for (NSString *line in knobLog) if ([line containsString:@"DIG (MD6;) will be set again"]) knobSays = YES;
        AssertTrue(![knobCmds containsObject:@"MD6;"] && [knobCmds containsObject:@"TX;"] && !knobStation.keyer.isTransmitting && knobSays,
                   @"the first Send after the knob is refused and says DIG will be set again");
        knobRefusesTX = NO;
        [knobCmds removeAllObjects];
        knobField.stringValue = @"E";
        [knobStation txSendClicked:nil];
        AssertTrue(knobDIGBeforeTX() && knobStation.keyer.isTransmitting, @"the next Send sets DIG before its TX;");
        [knobStation.keyer abortTransmission];
        knobRefusesTX = YES;
        [knobStation toggleManualTransmit];
        AssertTrue(!knobStation.isManualTuneActive, @"a refused Tune");
        knobRefusesTX = NO;
        [knobCmds removeAllObjects];
        [knobStation toggleManualTransmit];
        AssertTrue(knobDIGBeforeTX() && knobStation.isManualTuneActive, @"the next Tune sets DIG before its TX;");
        [knobStation stopManualTune];
        // DIG chosen in the mode menu keys with plain TX; too: the same, and each entry sets DIG.
        NSPopUpButton *knobMenu = [knobStation valueForKey:@"modePopup"];
        [knobMenu selectItemWithTag:6];
        [knobStation modePopupChanged:knobMenu];
        [knobStation stopStation];
        [knobCmds removeAllObjects];
        [knobStation startStation];
        AssertTrue([knobCmds containsObject:@"MD6;"], @"DIG chosen in the menu: each entry sets DIG");
        knobRefusesTX = YES;
        knobField.stringValue = @"E";
        [knobStation txSendClicked:nil];
        knobRefusesTX = NO;
        [knobCmds removeAllObjects];
        knobField.stringValue = @"E";
        [knobStation txSendClicked:nil];
        AssertTrue(knobDIGBeforeTX() && knobStation.keyer.isTransmitting, @"DIG chosen in the menu: the next Send sets DIG before its TX;");
        [knobStation.keyer abortTransmission];
        // USB and LSB in the mode menu key from DIG and go back to their mode, as CW and CW-R do.
        for (NSNumber *sideband in @[@2, @1]) {
            [knobMenu selectItemWithTag:sideband.integerValue];
            [knobStation modePopupChanged:knobMenu];
            NSString *back = [NSString stringWithFormat:@"RX;MD%ld;", (long)sideband.integerValue];
            AssertTrue([knobStation.keyer.txPrefixCommand isEqualToString:@"MD6;TX;"] && [knobStation.keyer.rxSuffixCommand isEqualToString:back],
                       [NSString stringWithFormat:@"the mode menu's MD%ld keys from DIG and goes back with %@", (long)sideband.integerValue, back]);
            [knobCmds removeAllObjects];
            knobField.stringValue = @"E";
            [knobStation txSendClicked:nil];
            AssertTrue([knobCmds containsObject:@"MD6;TX;"] && knobStation.keyer.isTransmitting, @"a Send in USB or LSB keys from DIG");
            [knobStation.keyer abortTransmission];
            AssertTrue([knobCmds containsObject:back], @"its release goes back to the chosen mode");
        }
        NSLog(@"PASS: Each entry to CW Station, and a radio found in another mode, sets DIG again.");
        // 12b. In Practice / Sim the decoder button says "STOP SIMULATION", and that is what it does:
        // the simulation stops, the box is unticked and a Tune keyed before the box was ticked is
        // released. It does not listen and sends nothing else to the radio. startListening is
        // replaced while this runs, so no audio input can open.
        Method listenMethod = class_getInstanceMethod([TX500CWAudioDecoder class], @selector(startListening));
        __block NSUInteger listenCalls = 0;
        IMP listenOriginal = method_setImplementation(listenMethod, imp_implementationWithBlock(^(id listeningDecoder) {
            (void)listeningDecoder; listenCalls++;
        }));
        TX500CWStationController *simStation = [TX500CWStationController new];
        __block NSMutableArray<NSString *> *simSentCmds = [NSMutableArray array];
        simStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [simSentCmds addObject:catCommand]; return YES; };
        NSButton *simCheckbox = [simStation valueForKey:@"simulationCheckbox"];
        NSButton *simDecoderButton = [simStation valueForKey:@"startStopDecoderButton"];
        [simStation toggleManualTransmit];                       // a Tune, before Practice is ticked
        AssertTrue(simStation.isManualTuneActive && [simSentCmds containsObject:@"TX;"], @"Tune keyed before Practice");
        simCheckbox.state = NSControlStateValueOn;
        [simStation toggleSimulation:simCheckbox];
        AssertTrue(simStation.decoder.isSimulationActive && [simDecoderButton.title isEqualToString:@"STOP SIMULATION"], @"Practice / Sim on: the decoder button says STOP SIMULATION");
        [simSentCmds removeAllObjects];
        [simStation toggleDecoder:simDecoderButton];
        AssertTrue(!simStation.decoder.isSimulationActive, @"STOP SIMULATION stops the simulation");
        AssertTrue(simCheckbox.state == NSControlStateValueOff, @"STOP SIMULATION unticks Practice / Sim");
        AssertTrue([simDecoderButton.title isEqualToString:@"START DECODER"], @"After STOP SIMULATION the button says START DECODER");
        AssertTrue(listenCalls == 0, @"STOP SIMULATION does not start the decoder");
        // Ticking Practice / Sim already released that Tune through the host sender (see 8d), so
        // STOP SIMULATION finds none left to release.
        AssertTrue(!simStation.isManualTuneActive, @"No Tune is left running after STOP SIMULATION");
        AssertTrue(![simSentCmds containsObject:@"MD6;"] && ![simSentCmds containsObject:@"TX;"], @"STOP SIMULATION sends no MD6; and keys nothing");
        method_setImplementation(listenMethod, listenOriginal);
        NSLog(@"PASS: STOP SIMULATION stops the simulation, unticks Practice / Sim and releases a Tune.");

        // 13. Test TX Release Ownership (RX;)
        __block BOOL sentRelease = NO;
        keyer.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) {
            if ([catCommand containsString:@"RX;"]) sentRelease = YES;
            return YES;
        };
        [keyer abortTransmission];
        AssertTrue(sentRelease, @"Abort transmission releases TX ownership with RX;");
        NSLog(@"PASS: CAT transmitter release (RX;) verified.");
        // 13b. Esc, leaving CW Station and Quit call stopStation. With Practice / Sim on it also
        // unticks the box and drops the practice QSO, so the next step cannot put a practice
        // exchange on the air and its sign-off cannot be logged or uploaded. Outside practice the
        // QSO in progress is kept.
        TX500CWStationController *escStation = [TX500CWStationController new];
        escStation.keyer.myCallsign = @"EA3JIC";
        escStation.assistant.myCallsign = @"EA3JIC";
        __block NSMutableArray<NSString *> *escCmds = [NSMutableArray array];
        escStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [escCmds addObject:catCommand]; return YES; };
        NSButton *escCheckbox = [escStation valueForKey:@"simulationCheckbox"];
        escCheckbox.state = NSControlStateValueOn;
        [escStation toggleSimulation:escCheckbox];
        [escStation.assistant processDecodedTextStream:@"CQ CQ DE EP2AES EP2AES K" currentWPM:22.0 snrDb:14.5];
        TX500CWHeardStation *escHeard = nil;
        for (TX500CWHeardStation *heard in escStation.assistant.heardStations) {
            if ([heard.callsign isEqualToString:@"EP2AES"]) escHeard = heard;
        }
        AssertTrue(escHeard != nil, @"Practice: the CQ was heard");
        [escStation.assistant selectAndAnswerStation:escHeard];
        AssertTrue(escStation.decoder.isSimulationActive && [escStation.assistant.activeTargetCallsign isEqualToString:@"EP2AES"], @"A practice QSO is loaded before Esc");
        [escStation stopStation];
        AssertTrue(!escStation.decoder.isSimulationActive, @"Esc stops the simulation");
        AssertTrue(escCheckbox.state == NSControlStateValueOff, @"Esc unticks Practice / Sim");
        AssertTrue(escStation.assistant.qsoState == TX500QSOStateIdle && escStation.assistant.activeTargetCallsign.length == 0, @"Esc drops the practice QSO");
        [escCmds removeAllObjects];
        [escStation advanceQSOAction:nil];
        AssertTrue([escStation.keyer.activeBufferText hasPrefix:@"CQ CQ DE EA3JIC"] && ![escStation.keyer.activeBufferText containsString:@"EP2AES"],
                   @"After Esc the next step calls CQ, not the practice exchange");
        [escStation.keyer abortTransmission];
        [escStation.assistant resetQSOState];
        [escStation.assistant processDecodedTextStream:@"CQ CQ DE EP2AES EP2AES K" currentWPM:22.0 snrDb:14.5];
        [escStation.assistant selectAndAnswerStation:escHeard];
        [escStation stopStation];
        AssertTrue([escStation.assistant.activeTargetCallsign isEqualToString:@"EP2AES"], @"Esc outside practice keeps the QSO in progress");
        NSLog(@"PASS: Esc and leaving CW Station untick Practice / Sim and drop the practice QSO.");
        // 13c. The wideband Answer above 1500 Hz retunes the radio first. When the radio refuses
        // the FA (still in TX, or another owner keying), nothing on the pane changes and no answer
        // goes out, since it would be (channel - 650) Hz off the station. With FA accepted, as before.
        TX500CWStationController *retuneStation = [TX500CWStationController new];
        retuneStation.keyer.myCallsign = @"EA3JIC";
        retuneStation.assistant.myCallsign = @"EA3JIC";
        __block BOOL retuneRefusesFA = YES;
        __block NSMutableArray<NSString *> *retuneCmds = [NSMutableArray array];
        __block NSMutableArray<NSString *> *retuneLog = [NSMutableArray array];
        retuneStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) {
            [retuneCmds addObject:catCommand];
            return !(retuneRefusesFA && [catCommand hasPrefix:@"FA"]);
        };
        retuneStation.logHandler = ^(NSString *line) { [retuneLog addObject:line]; };
        NSTextField *retuneVFO = [retuneStation valueForKey:@"vfoLabel"];
        [retuneStation updateFrequencyHz:7030000 mode:@"CW"];
        [retuneLog removeAllObjects];
        BOOL stepped = [retuneStation stepFrequencyHz:100];
        AssertTrue(!stepped && retuneStation.currentDialFrequencyHz == 7030000 && retuneStation.assistant.currentFrequencyHz == 7030000 &&
                   [retuneVFO.stringValue isEqualToString:@"7.030.000 MHz"] && [retuneLog.lastObject containsString:@"VFO not retuned"],
                   @"a refused FA changes nothing on the pane");
        // A click on the waterfall 300 Hz above the pitch: with FA refused it says "VFO not retuned"
        // only, sets no tuning lockout and leaves the dial; with FA accepted it retunes and says so.
        TX500CWSpectrumView *retuneWaterfall = [retuneStation valueForKey:@"spectrumView"];
        AssertTrue(retuneWaterfall.onWaterfallFrequencyClicked != nil, @"the waterfall click is wired");
        double retuneClickPitch = retuneStation.decoder.nominalPitchHz;
        if (retuneClickPitch < 300.0 || retuneClickPitch > 1500.0) retuneClickPitch = 650.0;
        [retuneStation setValue:@0 forKey:@"userTuningLockoutUntil"];
        [retuneLog removeAllObjects];
        retuneWaterfall.onWaterfallFrequencyClicked(retuneClickPitch + 300.0);
        BOOL clickClaims = NO; for (NSString *line in retuneLog) if ([line containsString:@"Retuned radio VFO"]) clickClaims = YES;
        AssertTrue(!clickClaims && [retuneLog.lastObject containsString:@"VFO not retuned"] && retuneStation.currentDialFrequencyHz == 7030000 &&
                   [[retuneStation valueForKey:@"userTuningLockoutUntil"] doubleValue] == 0,
                   @"a refused waterfall retune is not reported as done and holds nothing off");
        retuneRefusesFA = NO;
        [retuneLog removeAllObjects];
        retuneWaterfall.onWaterfallFrequencyClicked(retuneClickPitch + 300.0);
        AssertTrue(retuneStation.currentDialFrequencyHz == 7030300 && [retuneLog.lastObject containsString:@"Retuned radio VFO by +300 Hz"] &&
                   [[retuneStation valueForKey:@"userTuningLockoutUntil"] doubleValue] > [NSDate timeIntervalSinceReferenceDate],
                   @"an accepted waterfall retune moves the dial and says so");
        [retuneStation setValue:@0 forKey:@"userTuningLockoutUntil"];
        [retuneStation updateFrequencyHz:7030000 mode:@"CW"];
        retuneRefusesFA = YES;
        TX500CWChannelState *retuneChannel = [TX500CWChannelState new];
        retuneChannel.frequencyHz = 2100.0;
        retuneChannel.estimatedWPM = 22.0;
        retuneChannel.snrDb = 12.0;
        retuneChannel.extractedCallsign = @"EP2AES";
        double retunePitch = retuneStation.decoder.nominalPitchHz;
        [retuneCmds removeAllObjects];
        [retuneLog removeAllObjects];
        [retuneStation answerWidebandChannel:retuneChannel];
        BOOL retuneKeyed = NO, retuneSaysCould = NO, retuneClaims = NO;
        for (NSString *cmd in retuneCmds) if ([cmd containsString:@"TX;"]) retuneKeyed = YES;
        for (NSString *line in retuneLog) {
            if ([line containsString:@"Could not retune"]) retuneSaysCould = YES;
            if ([line containsString:@"answered"]) retuneClaims = YES;
        }
        AssertTrue(!retuneKeyed && !retuneStation.keyer.isTransmitting && retuneStation.decoder.nominalPitchHz == retunePitch &&
                   retuneStation.currentDialFrequencyHz == 7030000 && retuneSaysCould && !retuneClaims,
                   @"no answer off the station's frequency");
        retuneRefusesFA = NO;
        [retuneCmds removeAllObjects];
        [retuneLog removeAllObjects];
        [retuneStation answerWidebandChannel:retuneChannel];
        NSUInteger retuneFA = [retuneCmds indexOfObject:@"FA00007031450;"], retuneTX = NSNotFound;
        for (NSUInteger i = 0; i < retuneCmds.count; i++) if ([retuneCmds[i] containsString:@"TX;"]) { retuneTX = i; break; }
        AssertTrue(retuneFA != NSNotFound && retuneTX != NSNotFound && retuneFA < retuneTX && retuneStation.currentDialFrequencyHz == 7031450 &&
                   [retuneLog.lastObject containsString:@"Tuned & answered EP2AES"],
                   @"with the retune accepted the answer goes out");
        [retuneStation.keyer abortTransmission];
        NSLog(@"PASS: The wideband Answer goes out only after the radio accepted the retune.");
        // 13d. A radio that does not confirm RX (still in TX, or its PTT held): the pane says so in
        // red instead of LISTENING, and ABORT stays enabled, since it sends RX; again. A confirmed RX
        // clears it. The keyer's own release at the end of a message is checked the same way.
        TX500CWStationController *rxStation = [TX500CWStationController new];
        rxStation.keyer.myCallsign = @"EA3JIC";
        rxStation.assistant.myCallsign = @"EA3JIC";
        __block BOOL rxRefused = YES;
        __block NSMutableArray<NSString *> *rxCmds = [NSMutableArray array];
        __block NSMutableArray<NSString *> *rxLog = [NSMutableArray array];
        rxStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) {
            [rxCmds addObject:catCommand];
            return !(rxRefused && [catCommand hasPrefix:@"RX"]);
        };
        rxStation.logHandler = ^(NSString *line) { [rxLog addObject:line]; };
        NSTextField *rxLabel = [rxStation valueForKey:@"carrierLockStatusLabel"];
        NSButton *rxAbort = [rxStation valueForKey:@"txAbortButton"];
        NSUInteger (^rxCount)(void) = ^NSUInteger {
            NSUInteger n = 0;
            for (NSString *cmd in rxCmds) if ([cmd hasPrefix:@"RX"]) n++;
            return n;
        };
        [rxStation toggleManualTransmit];
        AssertTrue(rxStation.isManualTuneActive, @"Tune keys the radio before the RX test");
        [rxLog removeAllObjects];
        [rxStation toggleManualTransmit];
        BOOL rxClaimsReturned = NO;
        for (NSString *line in rxLog) if ([line containsString:@"returned to RX"]) rxClaimsReturned = YES;
        AssertTrue(!rxStation.isManualTuneActive && [rxLog.lastObject containsString:@"RX NOT confirmed"] && !rxClaimsReturned &&
                   [rxLabel.stringValue isEqualToString:@"● TX? RX NOT CONFIRMED"] && rxAbort.enabled,
                   @"an unconfirmed RX is said and ABORT stays usable");
        NSUInteger rxBefore = rxCount();
        [rxStation performSelector:@selector(txAbortClicked:) withObject:nil];
        AssertTrue(rxCount() == rxBefore + 1 && rxAbort.enabled && [rxLabel.stringValue isEqualToString:@"● TX? RX NOT CONFIRMED"],
                   @"ABORT re-sends RX;");
        rxRefused = NO;
        [rxStation performSelector:@selector(txAbortClicked:) withObject:nil];
        AssertTrue([rxLabel.stringValue isEqualToString:@"○ LISTENING"] && !rxAbort.enabled, @"a confirmed RX clears it");
        rxRefused = YES;
        rxStation.keyer.wpm = 45;
        [rxStation.keyer transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(rxStation.keyer.isTransmitting, @"the keyer sends E before its own release");
        [rxLog removeAllObjects];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.7]];
        BOOL rxKeyerSays = NO;
        for (NSString *line in rxLog) if ([line containsString:@"RX NOT confirmed"]) rxKeyerSays = YES;
        AssertTrue(!rxStation.keyer.isTransmitting && [rxLabel.stringValue isEqualToString:@"● TX? RX NOT CONFIRMED"] && rxAbort.enabled && rxKeyerSays,
                   @"the message's own release is checked too");
        rxRefused = NO;
        [rxStation.keyer abortTransmission];
        NSLog(@"PASS: An unconfirmed RX is said as such and ABORT stays enabled.");
        // 13e. An audio input failure opens a sheet that blocks ABORT and Esc until OK is clicked:
        // it stops Auto-CQ and the Tune first. No window exists here, so no sheet is shown.
        TX500CWStationController *audioErrStation = [TX500CWStationController new];
        audioErrStation.keyer.myCallsign = @"EA3JIC";
        audioErrStation.assistant.myCallsign = @"EA3JIC";
        __block NSMutableArray<NSString *> *audioErrCmds = [NSMutableArray array];
        __block NSMutableArray<NSString *> *audioErrLog = [NSMutableArray array];
        audioErrStation.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { [audioErrCmds addObject:catCommand]; return YES; };
        audioErrStation.logHandler = ^(NSString *line) { [audioErrLog addObject:line]; };
        NSButton *audioErrAutoCQ = [audioErrStation valueForKey:@"autoCQButton"];
        [audioErrStation toggleAutoCQ:nil];
        AssertTrue(audioErrStation.keyer.isAutoCQActive && audioErrStation.keyer.isTransmitting && [audioErrStation valueForKey:@"autoCQMonitorTimer"] != nil,
                   @"Auto-CQ is on the air before the audio error");
        [audioErrStation.keyer abortTransmission]; // idle between two calls, Auto-CQ still on
        AssertTrue(audioErrStation.decoder.onAudioError != nil && audioErrStation.keyer.isAutoCQActive, @"Auto-CQ waits for its next call");
        [audioErrLog removeAllObjects];
        audioErrStation.decoder.onAudioError(@"input lost");
        BOOL audioErrSays = NO;
        for (NSString *line in audioErrLog) if ([line containsString:@"Auto-CQ stopped"]) audioErrSays = YES;
        AssertTrue(!audioErrStation.keyer.isAutoCQActive && [audioErrStation valueForKey:@"autoCQMonitorTimer"] == nil &&
                   [audioErrAutoCQ.title isEqualToString:@"Auto-CQ Repeater"] && audioErrSays,
                   @"an audio error ends Auto-CQ");
        [audioErrStation toggleManualTransmit];
        AssertTrue(audioErrStation.isManualTuneActive, @"Tune is on before the audio error");
        [audioErrCmds removeAllObjects];
        audioErrStation.decoder.onAudioError(@"x");
        AssertTrue(!audioErrStation.isManualTuneActive && [audioErrCmds containsObject:@"RX;"], @"an audio error ends the Tune");
        NSLog(@"PASS: An audio input failure stops the Tune and Auto-CQ before its alert.");

        decoder.preserveDeviceSelection=YES; decoder.selectedAudioDeviceUID=@"station-test-missing-input";
        [decoder refreshAudioDevices];
        AssertTrue([decoder.selectedAudioDeviceUID isEqual:@"station-test-missing-input"], @"CW keeps explicit station input when hardware is missing");
        [keyer abortTransmission];
        keyer.serialCommandSender=^BOOL(NSString *command) { return [command containsString:@"TX;"]; };
        [keyer transmitText:@"CQ" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(keyer.isTransmitting, @"Valid setup allows keying");
        [keyer abortTransmission];
        // 14. A hard transmit time-out that depends neither on the sidetone, nor on the release
        // timers, nor on the main thread. A message longer than the limit is refused up front; a
        // message whose release timers never fire is silenced and released at the limit; the tuning
        // carrier, which has no keyer timer of its own, is stopped at its limit even while the main
        // thread is busy; the station is told; a message that ends in time gets no time-out.
        TX500CWKeyer *totKeyer = [[TX500CWKeyer alloc] init];
        totKeyer.myCallsign = @"EA3JIC";
        NSMutableArray<NSString *> *totCmds = [NSMutableArray array];
        __block NSMutableArray<NSString *> *totLog = [NSMutableArray array];
        totKeyer.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { @synchronized (totCmds) { [totCmds addObject:catCommand]; } return YES; };
        totKeyer.logHandler = ^(NSString *line) { [totLog addObject:line]; };
        AssertTrue(totKeyer.maximumTransmitSeconds == 120.0 && totKeyer.maximumCarrierSeconds == 15.0, @"Default limits: 120 s for a message, 15 s for the carrier");
        totKeyer.wpm = 3;
        totKeyer.maximumTransmitSeconds = 5.0;
        [totKeyer transmitText:@"CQ CQ CQ DE {MYCALL} {MYCALL} {MYCALL} K" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(!totKeyer.isTransmitting && totCmds.count == 0 && [totLog.lastObject containsString:@"transmit limit"], @"A message longer than the limit is refused and says why");
        totKeyer.wpm = 45;
        totKeyer.maximumTransmitSeconds = 0.3;
        [totKeyer transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(totKeyer.isTransmitting && [totCmds containsObject:@"TX;"], @"A short message is keyed");
        @synchronized (totCmds) { [totCmds removeAllObjects]; } // drop the RX; of the abort that opens every message
        [totKeyer setValue:@999 forKey:@"transmissionGeneration"]; // the release timers now belong to a stale transmission and never fire
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.8]];
        BOOL rxAfterTimeout = NO; @synchronized (totCmds) { rxAfterTimeout = [totCmds containsObject:@"RX;"]; }
        AssertTrue(!totKeyer.isTransmitting && rxAfterTimeout, @"The time-out releases a message whose release timers never fire");
        AssertTrue([totLog.lastObject containsString:@"time-out"], @"The console says the time-out fired");
        __block NSTimeInterval reportedLimit = 0;
        totKeyer.onTransmitTimedOut = ^(NSTimeInterval limitSeconds) { reportedLimit = limitSeconds; };
        totKeyer.maximumCarrierSeconds = 0.3;
        @synchronized (totCmds) { [totCmds removeAllObjects]; }
        [totKeyer startContinuousCarrierWithPitchHz:650.0];
        AssertTrue([[totKeyer valueForKey:@"isContinuousCarrier"] boolValue], @"The carrier started");
        [NSThread sleepForTimeInterval:0.7]; // main thread busy: no run loop, so no main-queue block can run
        BOOL rxWhileBusy = NO; @synchronized (totCmds) { rxWhileBusy = [totCmds containsObject:@"RX;"]; }
        AssertTrue(![[totKeyer valueForKey:@"isContinuousCarrier"] boolValue] && rxWhileBusy, @"The time-out silences the carrier and sends RX; while the main thread is busy");
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
        AssertTrue(reportedLimit == 0.3, @"The station is told which limit fired");
        // A newer message started from a main-queue block queued before the time-out's own block
        // (the main thread was busy while the time-out sent RX;) keeps transmitting: the time-out's
        // main-thread step must not clear it, or the radio would stay keyed with nothing to release it.
        totKeyer.onTransmitTimedOut = nil;
        totKeyer.maximumTransmitSeconds = 0.3;
        [totKeyer transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""];
        NSUInteger staleGeneration = [[totKeyer valueForKey:@"transmissionGeneration"] unsignedIntegerValue] + 1000;
        [totKeyer setValue:@(staleGeneration) forKey:@"transmissionGeneration"]; // its release timers never fire
        __block NSUInteger newerGeneration = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            totKeyer.maximumTransmitSeconds = 30.0;
            [totKeyer transmitText:@"CQ CQ DE {MYCALL} K" targetCall:@"" rst:@"" name:@"" qth:@""];
            newerGeneration = [[totKeyer valueForKey:@"transmissionGeneration"] unsignedIntegerValue];
        });
        [NSThread sleepForTimeInterval:0.6]; // the time-out fires and sends RX; while the main thread is busy
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
        AssertTrue(newerGeneration != 0 && totKeyer.isTransmitting &&
                   [[totKeyer valueForKey:@"transmissionGeneration"] unsignedIntegerValue] == newerGeneration,
                   @"A message started before the time-out's main-thread step keeps transmitting");
        [totKeyer abortTransmission];
        [totLog removeAllObjects];
        totKeyer.maximumTransmitSeconds = 0.5;
        [totKeyer transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""];
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.9]];
        BOOL strayTimeout = NO; for (NSString *line in totLog) if ([line containsString:@"time-out"]) strayTimeout = YES;
        AssertTrue(!totKeyer.isTransmitting && !strayTimeout, @"A message that ends in time gets no time-out");
        AssertTrue([totKeyer valueForKey:@"transmitTimeout"] == nil, @"A message that ends in time cancels its time-out");
        // Auto-CQ stops when its CQ is refused (too long for the limit, or TX; refused) instead of
        // retrying it every interval.
        totKeyer.wpm = 3;
        totKeyer.maximumTransmitSeconds = 5.0;
        [totKeyer startAutoCQWithTemplate:@"CQ CQ CQ DE {MYCALL} {MYCALL} {MYCALL} K" targetCall:@""];
        AssertTrue(!totKeyer.isAutoCQActive && !totKeyer.isTransmitting && [totLog.lastObject containsString:@"Auto-CQ stopped"], @"Auto-CQ stops when its CQ is longer than the limit");
        totKeyer.wpm = 45;
        totKeyer.maximumTransmitSeconds = 120.0;
        totKeyer.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) { return ![catCommand isEqualToString:@"TX;"]; };
        [totKeyer startAutoCQWithTemplate:@"CQ DE {MYCALL} K" targetCall:@""];
        AssertTrue(!totKeyer.isAutoCQActive && !totKeyer.isTransmitting, @"Auto-CQ stops when TX; is refused");
        NSLog(@"PASS: The transmit time-out always stops the audio and releases the radio.");
        NSLog(@"ALL TX-500 CW STATION AND AUDIO DSP TESTS PASSED! ✓");
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:testRoot] error:nil];
    }
    return 0;
}
