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

// Station button actions the tests press directly (no window is opened).
@interface TX500CWStationController (ButtonsForTests)
- (void)rosterAnswerClicked:(NSButton *)sender;
- (void)macroButtonClicked:(NSButton *)sender;
- (void)advanceQSOAction:(id)sender;
- (void)toggleAutoCQ:(id)sender;
@end

// Counts calls to the cloud upload while a test runs, and uploads nothing. Installed only
// around the checks that need it, and restored afterwards.
static NSUInteger CloudUploadCalls = 0;
static IMP CloudUploadOriginal = NULL;
static void StartCountingCloudUploads(void) {
    Method m = class_getInstanceMethod([TX500CloudSyncEngine class], @selector(uploadContactImmediately:completion:));
    IMP counted = imp_implementationWithBlock(^(id engine, TX500LogRecord *record, void (^completion)(BOOL, NSString *)) {
        (void)engine; (void)record;
        @synchronized ([TX500CloudSyncEngine class]) { CloudUploadCalls++; }
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

        // 13. Test TX Release Ownership (RX;)
        __block BOOL sentRelease = NO;
        keyer.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) {
            if ([catCommand containsString:@"RX;"]) sentRelease = YES;
            return YES;
        };
        [keyer abortTransmission];
        AssertTrue(sentRelease, @"Abort transmission releases TX ownership with RX;");
        NSLog(@"PASS: CAT transmitter release (RX;) verified.");

        decoder.preserveDeviceSelection=YES; decoder.selectedAudioDeviceUID=@"station-test-missing-input";
        [decoder refreshAudioDevices];
        AssertTrue([decoder.selectedAudioDeviceUID isEqual:@"station-test-missing-input"], @"CW keeps explicit station input when hardware is missing");
        [keyer abortTransmission];
        keyer.serialCommandSender=^BOOL(NSString *command) { return [command containsString:@"TX;"]; };
        [keyer transmitText:@"CQ" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(keyer.isTransmitting, @"Valid setup allows keying");
        [keyer abortTransmission];
        NSLog(@"ALL TX-500 CW STATION AND AUDIO DSP TESTS PASSED! ✓");
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:testRoot] error:nil];
    }
    return 0;
}
