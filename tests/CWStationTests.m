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
        AssertTrue(decoder.availableAudioInputDevices.count > 0, @"Audio devices found");
        NSLog(@"PASS: Audio devices enumerated (%lu found).", (unsigned long)decoder.availableAudioInputDevices.count);

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

        // 6. Test Keyer Serial Protocol Commands & KY Chunking
        __block NSMutableArray<NSString *> *sentCommands = [NSMutableArray array];
        keyer.serialCommandSender = ^BOOL(NSString * _Nonnull catCommand) {
            [sentCommands addObject:catCommand];
            return YES;
        };

        keyer.wpm = 3;
        [keyer transmitText:@"E" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue([sentCommands containsObject:@"KS003;"], @"Sent KS003; speed command for 3 WPM");

        keyer.wpm = 24;
        [keyer transmitText:@"CQ CQ DE EP2AES K" targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue([sentCommands containsObject:@"KS024;"], @"Sent KS024; speed command");
        AssertTrue([sentCommands containsObject:@"KY CQ CQ DE EP2AES K;"], @"Sent KY Morse command");

        // Long text chunking test (> 24 chars)
        [sentCommands removeAllObjects];
        NSString *longText = @"THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG";
        [keyer transmitText:longText targetCall:@"" rst:@"" name:@"" qth:@""];
        AssertTrue(sentCommands.count >= 3, @"Chunked into multiple frames (abort, speed, chunks)");
        AssertTrue([sentCommands containsObject:@"KY THE QUICK BROWN FOX JUMP;"], @"First 24 chars chunked");
        NSLog(@"PASS: Keyer Kenwood KS and KY chunking verified.");

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

        NSLog(@"ALL TX-500 CW STATION AND AUDIO DSP TESTS PASSED! ✓");
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:testRoot] error:nil];
    }
    return 0;
}
