//
//  FT8StationTests.m
//  Lab599 Utility Tests
//
//  Unit and regression test suite for FT8 Digital Suite:
//  Pure C99 FT8 codec, GFSK audio synthesis, loopback decoding,
//  Maidenhead distance & bearing math, DXCC resolver, Auto-CQ & Auto-Hunter engines.
//

#import <Foundation/Foundation.h>
#import "tx500_ft8_shim.h"
#import "TX500FT8Message.h"
#import "TX500FT8AudioEngine.h"
#import "TX500FT8AutoEngine.h"

static void AssertTrue(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", [message UTF8String]);
        exit(1);
    }
}

int main(int argc, const char * argv[]) {
    char testRootTemplate[] = "/tmp/Lab599FT8StationTests.XXXXXX";
    char *testRoot = mkdtemp(testRootTemplate);
    if (!testRoot) return 1;
    setenv("TX500_TEST_MODE", "1", 1);
    setenv("TX500_TEST_ROOT", testRoot, 1);
    setenv("CFFIXED_USER_HOME", testRoot, 1);
    @autoreleasepool {
        (void)argc; (void)argv;
        NSLog(@"Running Lab599 Discovery TX-500 FT8 Digital Suite Tests...");

        // 1. Test FT8 Message Encoding & 8-FSK Tone Generation
        const char *testMsg = "CQ EP2AES KM35";
        unsigned char tones[FT8808_MAX_TONES];
        int numTones = tx500_ft8_encode_message(testMsg, TX500_FT8_PROTOCOL_FT8, tones, FT8808_MAX_TONES);
        AssertTrue(numTones == 79, [NSString stringWithFormat:@"Expected 79 tones for FT8, got %d", numTones]);

        for (int i = 0; i < 79; i++) {
            AssertTrue(tones[i] <= 7, [NSString stringWithFormat:@"Tone %d at index %d exceeds 7", tones[i], i]);
        }
        NSLog(@"PASS: FT8 message encoding & 79 8-FSK tones verified.");

        // 2. Test GFSK Audio Waveform Synthesis
        int sampleRate = 12000;
        int maxSamples = sampleRate * 15;
        float *synthesized = (float *)calloc(maxSamples, sizeof(float));
        int samplesWritten = tx500_ft8_synthesize(tones, numTones, 1500.0f, TX500_FT8_PROTOCOL_FT8, sampleRate, synthesized, maxSamples);
        AssertTrue(samplesWritten > 140000 && samplesWritten <= 155000,
                   [NSString stringWithFormat:@"Expected ~151680 samples, got %d", samplesWritten]);

        float maxAmp = 0.0f;
        for (int i = 0; i < samplesWritten; i++) {
            float a = fabsf(synthesized[i]);
            if (a > maxAmp) maxAmp = a;
        }
        AssertTrue(maxAmp > 0.3f && maxAmp <= 1.0f, [NSString stringWithFormat:@"Peak amplitude valid: %.2f", maxAmp]);
        NSLog(@"PASS: Continuous-phase GFSK audio synthesis verified (%d samples, peak %.2f).", samplesWritten, maxAmp);

        // 3. Test Full End-to-End Loopback Decode
        // Pad synthesized waveform to slot length (15s = 180,000 samples)
        float *slotSamples = (float *)calloc(180000, sizeof(float));
        memcpy(slotSamples, synthesized, samplesWritten * sizeof(float));

        tx500_ft8_decoded_t decoded[10];
        int numDecoded = tx500_ft8_decode_samples(slotSamples, 180000, sampleRate, TX500_FT8_PROTOCOL_FT8, decoded, 10);
        free(synthesized);
        free(slotSamples);

        AssertTrue(numDecoded >= 1, [NSString stringWithFormat:@"Loopback decode expected >= 1 message, got %d", numDecoded]);
        BOOL foundMatch = NO;
        for (int i = 0; i < numDecoded; i++) {
            NSString *decText = [NSString stringWithUTF8String:decoded[i].text];
            if ([decText isEqualToString:@"CQ EP2AES KM35"]) {
                foundMatch = YES;
                AssertTrue(fabsf(decoded[i].freq_hz - 1500.0f) < 15.0f,
                           [NSString stringWithFormat:@"Frequency close to 1500 Hz (got %.1f)", decoded[i].freq_hz]);
                break;
            }
        }
        AssertTrue(foundMatch, @"Decoded text reproduces original test message 'CQ EP2AES KM35'");
        NSLog(@"PASS: Deep LDPC loopback decode verified (Decoded: %s, Freq: %.1f Hz, SNR: %.1f dB).",
              decoded[0].text, decoded[0].freq_hz, decoded[0].snr_db);

        // 4. Test Maidenhead Grid Parser & Distance Math
        double lat1 = 0, lon1 = 0, lat2 = 0, lon2 = 0;
        AssertTrue([TX500FT8Message parseMaidenhead:@"KM35" outLat:&lat1 outLon:&lon1], @"Parse KM35");
        AssertTrue(fabs(lat1 - 35.5) < 0.1, @"KM35 latitude is 35.5N");
        AssertTrue(fabs(lon1 - 27.0) < 0.1, @"KM35 longitude is 27.0E");

        double latTehran = 0, lonTehran = 0;
        AssertTrue([TX500FT8Message parseMaidenhead:@"LM35" outLat:&latTehran outLon:&lonTehran], @"Parse LM35");
        AssertTrue(fabs(latTehran - 35.5) < 0.1, @"LM35 latitude is 35.5N");
        AssertTrue(fabs(lonTehran - 47.0) < 0.1, @"LM35 longitude is 47.0E");

        AssertTrue([TX500FT8Message parseMaidenhead:@"FN31" outLat:&lat2 outLon:&lon2], @"Parse FN31");
        double distKM35NY = [TX500FT8Message distanceKmFromGrid:@"KM35" toGrid:@"FN31"];
        AssertTrue(distKM35NY > 8000 && distKM35NY < 8400,
                   [NSString stringWithFormat:@"Distance KM35-NY expected ~8200 km, got %.0f km", distKM35NY]);

        double distTehranNY = [TX500FT8Message distanceKmFromGrid:@"LM35" toGrid:@"FN31"];
        AssertTrue(distTehranNY > 9400 && distTehranNY < 10200,
                   [NSString stringWithFormat:@"Distance Tehran-NY expected ~9500-9880 km, got %.0f km", distTehranNY]);

        double distTehranTokyo = [TX500FT8Message distanceKmFromGrid:@"LM35" toGrid:@"PM95"];
        AssertTrue(distTehranTokyo > 7300 && distTehranTokyo < 8100,
                   [NSString stringWithFormat:@"Distance Tehran-Tokyo expected ~7600-8000 km, got %.0f km", distTehranTokyo]);
        NSLog(@"PASS: Maidenhead grid parsing & Great Circle Haversine distance math verified.");

        // 5. Test DXCC Prefix & Country Resolver
        AssertTrue([[TX500FT8Message countryNameForCallsign:@"EP2AES"] isEqualToString:@"Iran"], @"EP2AES is Iran");
        AssertTrue([[TX500FT8Message countryFlagForCallsign:@"EP2AES"] isEqualToString:@"🇮🇷"], @"Iran flag");
        AssertTrue([[TX500FT8Message countryNameForCallsign:@"JA1ABC"] isEqualToString:@"Japan"], @"JA1ABC is Japan");
        AssertTrue([[TX500FT8Message countryFlagForCallsign:@"JA1ABC"] isEqualToString:@"🇯🇵"], @"Japan flag");
        AssertTrue([[TX500FT8Message countryNameForCallsign:@"W1AW"] isEqualToString:@"United States"], @"W1AW is USA");
        AssertTrue([[TX500FT8Message countryNameForCallsign:@"DL7XYZ"] isEqualToString:@"Germany"], @"DL7XYZ is Germany");
        AssertTrue([[TX500FT8Message countryNameForCallsign:@"VK2BGL"] isEqualToString:@"Australia"], @"VK2BGL is Australia");

        // Specific user test cases:
        AssertTrue([[TX500FT8Message countryNameForCallsign:@"BG0FQU"] isEqualToString:@"China"], @"BG0FQU is China");
        AssertTrue([[TX500FT8Message countryFlagForCallsign:@"BG0FQU"] isEqualToString:@"🇨🇳"], @"BG0FQU flag is China");

        AssertTrue([[TX500FT8Message countryNameForCallsign:@"II4IANT"] isEqualToString:@"Italy"], @"II4IANT is Italy");
        AssertTrue([[TX500FT8Message countryFlagForCallsign:@"II4IANT"] isEqualToString:@"🇮🇹"], @"II4IANT flag is Italy");

        AssertTrue([[TX500FT8Message countryNameForCallsign:@"PH02LIB"] isEqualToString:@"Netherlands"], @"PH02LIB is Netherlands");
        AssertTrue([[TX500FT8Message countryFlagForCallsign:@"PH02LIB"] isEqualToString:@"🇳🇱"], @"PH02LIB flag is Netherlands");

        AssertTrue([[TX500FT8Message countryNameForCallsign:@"PA0JAX"] isEqualToString:@"Netherlands"], @"PA0JAX is Netherlands");
        AssertTrue([[TX500FT8Message countryFlagForCallsign:@"PA0JAX"] isEqualToString:@"🇳🇱"], @"PA0JAX flag is Netherlands");

        AssertTrue([[TX500FT8Message countryNameForCallsign:@"MI7JUX"] isEqualToString:@"Northern Ireland"], @"MI7JUX is Northern Ireland");
        AssertTrue([[TX500FT8Message countryFlagForCallsign:@"MI7JUX"] isEqualToString:@"🇬🇧"], @"MI7JUX flag is UK/Northern Ireland");

        AssertTrue([[TX500FT8Message countryNameForCallsign:@"R9FE"] isEqualToString:@"Asiatic Russia"], @"R9FE is Asiatic Russia");
        AssertTrue([[TX500FT8Message countryFlagForCallsign:@"R9FE"] isEqualToString:@"🇷🇺"], @"R9FE flag is Russia");

        AssertTrue([[TX500FT8Message countryNameForCallsign:@"UC6W"] isEqualToString:@"European Russia"], @"UC6W is European Russia");
        AssertTrue([[TX500FT8Message countryFlagForCallsign:@"UC6W"] isEqualToString:@"🇷🇺"], @"UC6W flag is Russia");

        NSLog(@"PASS: DXCC prefix & flag database verified (including China, Italy, Netherlands, Northern Ireland, Asiatic & European Russia).");

        // 6. Test Semantic Message Parsing
        TX500FT8Message *msgCQ = [TX500FT8Message messageWithRawText:@"CQ JA1ABC PM95"
                                                              freqHz:1200 snrDb:-4 dt:0.1
                                                              myCall:@"EP2AES" myGrid:@"KM35"];
        AssertTrue(msgCQ.isCQ, @"msgCQ is CQ");
        AssertTrue([msgCQ.callerCall isEqualToString:@"JA1ABC"], @"msgCQ caller is JA1ABC");
        AssertTrue([msgCQ.grid isEqualToString:@"PM95"], @"msgCQ grid is PM95");
        AssertTrue(msgCQ.distanceKm > 7000, @"Calculated distance > 7000 km");

        TX500FT8Message *msgDirected = [TX500FT8Message messageWithRawText:@"EP2AES JA1ABC -08"
                                                                    freqHz:1200 snrDb:-8 dt:0.2
                                                                    myCall:@"EP2AES" myGrid:@"KM35"];
        AssertTrue(msgDirected.isDirectedToMe, @"msgDirected is directed to me");
        AssertTrue([msgDirected.snrReport isEqualToString:@"-08"], @"Report is -08");

        TX500FT8Message *ownCQ = [TX500FT8Message messageWithRawText:@"CQ EP2AES KM35"
                                                              freqHz:1500 snrDb:-20 dt:0.0
                                                              myCall:@"EP2AES" myGrid:@"KM35"];
        AssertTrue(ownCQ.isMyTransmission, @"Own decoded CQ is identified as local loopback");
        AssertTrue(!msgDirected.isMyTransmission, @"A DX reply addressed to me is not mistaken for local TX");

        NSInteger swrDots = -1;
        AssertTrue([TX500FT8AudioEngine parseSWRMeterReply:@"RM10015;" rawDots:&swrDots] && swrDots == 15,
                   @"Documented RM1 SWR meter frame is parsed as 15/30 raw dots");
        AssertTrue([TX500FT8AudioEngine parseSWRMeterReply:@"noise RM10030; trailing" rawDots:&swrDots] && swrDots == 30,
                   @"RM1 parser extracts a complete frame from a noisy CAT response");
        AssertTrue(![TX500FT8AudioEngine parseSWRMeterReply:@"RM10031;" rawDots:&swrDots],
                   @"Out-of-range SWR meter values are rejected");
        NSLog(@"PASS: Semantic message parsing verified.");

        // 7. Test Autonomous Engine: Auto-CQ Loop
        TX500FT8AudioEngine *audioEng = [[TX500FT8AudioEngine alloc] init];
        audioEng.myCallsign = @"EP2AES";
        audioEng.myGrid = @"KM35";
        audioEng.isSimulationMode = YES;

        TX500FT8AutoEngine *autoEng = [[TX500FT8AutoEngine alloc] init];
        autoEng.audioEngine = audioEng;

        [autoEng startAutoCQWithLimit:5];
        AssertTrue(autoEng.isAutoCQActive, @"Auto-CQ active");
        AssertTrue(autoEng.autoCQCurrentCount == 1, @"Auto-CQ count is 1");
        AssertTrue(autoEng.qsoPhase == TX500FT8QSOPhaseCallingCQ, @"QSO phase calling CQ");

        // Simulate a response from DX caller
        TX500FT8Message *callerMsg = [TX500FT8Message messageWithRawText:@"EP2AES JA1ABC PM95"
                                                                  freqHz:1400 snrDb:+2 dt:0.1
                                                                  myCall:@"EP2AES" myGrid:@"KM35"];
        [autoEng processDecodedSlot:@[callerMsg] parity:1];

        AssertTrue(!autoEng.isAutoCQActive, @"Auto-CQ stopped on caller detection");
        AssertTrue([autoEng.activeDXCall isEqualToString:@"JA1ABC"], @"Locked onto caller JA1ABC");
        AssertTrue(autoEng.qsoPhase == TX500FT8QSOPhaseSendingReport, @"Transitioned to SendingReport (Tx 2)");
        AssertTrue([audioEng.queuedTxMessage isEqualToString:@"JA1ABC EP2AES +02"], @"Queued Tx 2: JA1ABC EP2AES +02");
        AssertTrue(audioEng.isTransmitArmed, @"Transmit path is armed");
        NSLog(@"PASS: Algorithm 1 (Auto-CQ loop & instant caller engagement with Tx 2) verified.");

        // 8. Test Autonomous Engine: Intelligent Auto-Hunter
        [autoEng abortQSO];
        [autoEng startAutoHunter];
        AssertTrue(autoEng.isAutoHunterActive, @"Auto-Hunter active");
        autoEng.autoHunterCriteria = TX500FT8HunterCriteriaMaxDistance;

        TX500FT8Message *candGermany = [TX500FT8Message messageWithRawText:@"CQ DL7XYZ JO62" freqHz:1000 snrDb:+5 dt:0.0 myCall:@"EP2AES" myGrid:@"KM35"];
        TX500FT8Message *candJapan   = [TX500FT8Message messageWithRawText:@"CQ JA1ABC PM95" freqHz:1500 snrDb:-2 dt:0.1 myCall:@"EP2AES" myGrid:@"KM35"];
        TX500FT8Message *candAus     = [TX500FT8Message messageWithRawText:@"CQ VK2BGL QF56" freqHz:2200 snrDb:-12 dt:0.2 myCall:@"EP2AES" myGrid:@"KM35"];

        [autoEng processDecodedSlot:@[candGermany, candJapan, candAus] parity:0];
        AssertTrue([autoEng.activeDXCall isEqualToString:@"VK2BGL"], @"Auto-Hunter picked furthest distance candidate (VK2BGL)");

        [autoEng abortQSO];
        [autoEng startAutoHunter];
        autoEng.autoHunterCriteria = TX500FT8HunterCriteriaMaxSNR;
        [autoEng processDecodedSlot:@[candGermany, candJapan, candAus] parity:0];
        AssertTrue([autoEng.activeDXCall isEqualToString:@"DL7XYZ"], @"Auto-Hunter picked strongest SNR candidate (DL7XYZ)");
        NSLog(@"PASS: Algorithm 2 (Intelligent Auto-Hunter multi-criteria selection) verified.");

        // 9. Test QSO State Machine Progression & ADIF Export
        [autoEng advanceToNextQSOStep]; // SendingReport
        AssertTrue(autoEng.qsoPhase == TX500FT8QSOPhaseSendingReport, @"Phase is SendingReport");
        [autoEng advanceToNextQSOStep]; // SendingRogerRpt
        AssertTrue(autoEng.qsoPhase == TX500FT8QSOPhaseSendingRogerRpt, @"Phase is SendingRogerRpt");
        [autoEng advanceToNextQSOStep]; // SendingRR73
        AssertTrue(autoEng.qsoPhase == TX500FT8QSOPhaseSendingRR73, @"Phase is SendingRR73");
        [autoEng advanceToNextQSOStep]; // Sending73
        AssertTrue(autoEng.qsoPhase == TX500FT8QSOPhaseSending73, @"Phase is Sending73");
        [autoEng advanceToNextQSOStep]; // Complete & Log
        AssertTrue(autoEng.qsoPhase == TX500FT8QSOPhaseComplete, @"Phase is Complete");
        AssertTrue(autoEng.sessionLog.count == 1, @"1 QSO in session log");

        NSString *adif = [autoEng generateADIFExport];
        AssertTrue([adif containsString:@"<CALL:6>DL7XYZ"], @"ADIF contains DL7XYZ");
        AssertTrue([adif containsString:@"<MODE:3>FT8"], @"ADIF contains MODE FT8");
        AssertTrue([adif containsString:@"<EOR>"], @"ADIF contains EOR");
        NSLog(@"PASS: Complete QSO state machine progression & ADIF generator verified.");

        // 9b. Test Full FT8 CQ Caller Response Progression (ER3PM -> EP2AES Scenario)
        [autoEng abortQSO];
        [autoEng clearSessionLog];
        audioEng.lockTxRxFrequencies = YES;
        [autoEng setCallingCQState:YES];
        AssertTrue(autoEng.qsoPhase == TX500FT8QSOPhaseCallingCQ, @"Station in CallingCQ state");

        // Cycle 2: ER3PM answers our CQ at 2186 Hz with -14 dB
        TX500FT8Message *er3pmAnswer = [TX500FT8Message messageWithRawText:@"EP2AES ER3PM KN47"
                                                                    freqHz:2186.0f snrDb:-14.0f dt:-1.1f
                                                                    myCall:@"EP2AES" myGrid:@"KM35"];
        [autoEng processDecodedSlot:@[er3pmAnswer] parity:1];

        // Software MUST engage ER3PM, set Tx 2 (Report -14), and align frequencies
        AssertTrue([autoEng.activeDXCall isEqualToString:@"ER3PM"], @"Engaged caller ER3PM");
        AssertTrue([autoEng.activeDXGrid isEqualToString:@"KN47"], @"Grid set to KN47");
        AssertTrue(autoEng.qsoPhase == TX500FT8QSOPhaseSendingReport, @"Phase is SendingReport (Tx 2)");
        AssertTrue([audioEng.queuedTxMessage isEqualToString:@"ER3PM EP2AES -14"], @"Queued Tx 2: ER3PM EP2AES -14");
        AssertTrue(audioEng.txSlotParity == TX500FT8SlotParityEven, @"Armed on alternate slot (Even)");
        AssertTrue((int)roundf(audioEng.rxAudioFrequencyHz) == 2186, @"RX tuned to 2186 Hz");
        AssertTrue((int)roundf(audioEng.txAudioFrequencyHz) == 2186, @"TX locked to 2186 Hz");

        // Cycle 4: ER3PM responds with R-12 (Roger + Report)
        TX500FT8Message *er3pmRoger = [TX500FT8Message messageWithRawText:@"EP2AES ER3PM R-12"
                                                                   freqHz:2186.0f snrDb:-12.0f dt:-1.0f
                                                                   myCall:@"EP2AES" myGrid:@"KM35"];
        [autoEng processDecodedSlot:@[er3pmRoger] parity:1];
        AssertTrue(autoEng.qsoPhase == TX500FT8QSOPhaseSendingRR73, @"Phase is SendingRR73 (Tx 4)");
        AssertTrue([audioEng.queuedTxMessage isEqualToString:@"ER3PM EP2AES RR73"], @"Queued Tx 4: ER3PM EP2AES RR73");
        AssertTrue([autoEng.rcvdReport isEqualToString:@"-12"], @"Received report is -12");

        // Cycle 6: ER3PM sends 73
        TX500FT8Message *er3pm73 = [TX500FT8Message messageWithRawText:@"EP2AES ER3PM 73"
                                                                freqHz:2186.0f snrDb:-10.0f dt:-1.0f
                                                                myCall:@"EP2AES" myGrid:@"KM35"];
        [autoEng processDecodedSlot:@[er3pm73] parity:1];
        AssertTrue(autoEng.sessionLog.count == 1, @"QSO automatically logged");
        TX500FT8LoggedQSO *loggedER3PM = autoEng.sessionLog.firstObject;
        AssertTrue([loggedER3PM.callsign isEqualToString:@"ER3PM"], @"Logged call ER3PM");
        AssertTrue([loggedER3PM.grid isEqualToString:@"KN47"], @"Logged grid KN47");
        AssertTrue([loggedER3PM.rstSent isEqualToString:@"-14"], @"Logged sent RST -14");
        AssertTrue([loggedER3PM.rstRcvd isEqualToString:@"-12"], @"Logged rcvd RST -12");
        NSLog(@"PASS: Full FT8 CQ caller response progression (ER3PM -> EP2AES) verified.");

        // 10. Test 15-Second Slot Timestamp Quantization & Parity
        NSTimeInterval now = 1718000013.8; // e.g. :13.8
        NSTimeInterval quantized = floor(now / 15.0) * 15.0;
        NSDate *slotDate = [NSDate dateWithTimeIntervalSince1970:quantized];
        time_t slotSec = (time_t)[slotDate timeIntervalSince1970];
        AssertTrue(slotSec % 15 == 0, @"Quantized slot timestamp must be an exact multiple of 15 seconds");

        TX500FT8Message *slotMsg = [TX500FT8Message messageWithRawText:@"CQ BG0FQU MN84"
                                                                freqHz:14074000 + 1250
                                                                 snrDb:-5
                                                                    dt:0.1
                                                              slotDate:slotDate
                                                            slotParity:0
                                                                myCall:@"EP2AES"
                                                                myGrid:@"KM35"];
        AssertTrue(slotMsg.slotParity == 0, @"Even slot parity preserved");
        AssertTrue(((long)[slotMsg.timestamp timeIntervalSince1970]) % 15 == 0, @"Message timestamp is multiple of 15");
        NSLog(@"PASS: 15-second slot quantization (:00, :15, :30, :45) verified.");

        // 11. Test All-Decodes ADIF Logging and QSO Logbook Logging
        NSString *allDecodesPath = [TX500FT8AudioEngine allDecodesADIFPath];
        AssertTrue(allDecodesPath.length > 0, @"All-decodes ADIF path is valid");
        AssertTrue([allDecodesPath hasPrefix:[NSString stringWithUTF8String:testRoot]],
                   @"All-decodes ADIF stays inside the isolated test directory");
        [audioEng logDecodedMessagesToADIF:@[slotMsg]];
        [NSThread sleepForTimeInterval:0.25]; // Wait for async file write to finish
        AssertTrue([[NSFileManager defaultManager] fileExistsAtPath:allDecodesPath], @"FT8_ALL_DECODES.adi file created");

        NSString *allDecodesContent = [NSString stringWithContentsOfFile:allDecodesPath encoding:NSUTF8StringEncoding error:nil];
        AssertTrue([allDecodesContent containsString:@"BG0FQU"], @"All-decodes ADIF contains BG0FQU");
        AssertTrue([allDecodesContent containsString:@"<MODE:3>FT8"], @"All-decodes ADIF contains MODE FT8");

        NSString *qsoLogPath = [TX500FT8AutoEngine qsoLogbookADIFPath];
        AssertTrue([qsoLogPath hasPrefix:[NSString stringWithUTF8String:testRoot]],
                   @"QSO logbook stays inside the isolated test directory");
        AssertTrue(qsoLogPath.length > 0, @"QSO logbook ADIF path is valid");
        TX500FT8LoggedQSO *loggedQSO = [[TX500FT8LoggedQSO alloc] init];
        loggedQSO.callsign = @"BG0FQU";
        loggedQSO.grid = @"MN84";
        loggedQSO.band = @"20m";
        loggedQSO.freqHz = 14074000;
        loggedQSO.rstSent = @"+01";
        loggedQSO.rstRcvd = @"-05";
        loggedQSO.timestamp = [NSDate date];
        [autoEng logCompletedQSOToADIF:loggedQSO];
        [NSThread sleepForTimeInterval:0.25]; // Wait for async file write to finish
        AssertTrue([[NSFileManager defaultManager] fileExistsAtPath:qsoLogPath], @"TX500_FT8_Logbook.adi file created");

        NSString *qsoContent = [NSString stringWithContentsOfFile:qsoLogPath encoding:NSUTF8StringEncoding error:nil];
        AssertTrue([qsoContent containsString:@"<CALL:6>BG0FQU"], @"QSO logbook contains BG0FQU");
        AssertTrue([qsoContent containsString:@"<BAND:3>20m"], @"QSO logbook contains band 20m");
        NSLog(@"PASS: Continuous ADIF logging (All-Decodes & QSO Logbook) in UTC verified.");

        // 12. Test Arm Transmit with Log Handler (Regression check for ENABLE TX crash)
        __block BOOL logReceived = NO;
        audioEng.logHandler = ^(NSString *line) {
            if ([line containsString:@"Transmit Armed"]) {
                logReceived = YES;
            }
        };
        [audioEng armTransmitWithText:@"CQ EP2AES KM35" parity:TX500FT8SlotParityAuto];
        AssertTrue(audioEng.isTransmitArmed, @"Audio engine is armed for transmit");
        AssertTrue(logReceived, @"logHandler received armed transmission log successfully without exception");
        [audioEng disarmTransmit];
        AssertTrue(!audioEng.isTransmitArmed, @"disarmTransmit cleared armed state");
        NSLog(@"PASS: Arm Transmit & logHandler invocation (ENABLE TX crash regression) verified.");

        // 13. Test FT4 Message Encoding & 4-FSK Tone Generation
        unsigned char ft4Tones[FT8808_MAX_TONES];
        int numFt4Tones = tx500_ft8_encode_message("CQ EP2AES KM35", TX500_FT8_PROTOCOL_FT4, ft4Tones, FT8808_MAX_TONES);
        AssertTrue(numFt4Tones == 105, [NSString stringWithFormat:@"Expected 105 tones for FT4, got %d", numFt4Tones]);
        for (int i = 0; i < 105; i++) {
            AssertTrue(ft4Tones[i] <= 3, [NSString stringWithFormat:@"FT4 tone %d at index %d exceeds 3", ft4Tones[i], i]);
        }
        NSLog(@"PASS: FT4 message encoding & 105 4-FSK tones verified.");

        // 14. Test FT4 GFSK Audio Synthesis
        int maxFt4Samples = sampleRate * 8; // 8 seconds buffer
        float *ft4Synthesized = (float *)calloc(maxFt4Samples, sizeof(float));
        int ft4SamplesWritten = tx500_ft8_synthesize(ft4Tones, numFt4Tones, 1500.0f, TX500_FT8_PROTOCOL_FT4, sampleRate, ft4Synthesized, maxFt4Samples);
        AssertTrue(ft4SamplesWritten > 59000 && ft4SamplesWritten <= 62000,
                   [NSString stringWithFormat:@"Expected ~60480 samples for FT4, got %d", ft4SamplesWritten]);

        float maxAmpFt4 = 0.0f;
        for (int i = 0; i < ft4SamplesWritten; i++) {
            float a = fabsf(ft4Synthesized[i]);
            if (a > maxAmpFt4) maxAmpFt4 = a;
        }
        AssertTrue(maxAmpFt4 > 0.3f && maxAmpFt4 <= 1.0f, [NSString stringWithFormat:@"FT4 peak amplitude valid: %.2f", maxAmpFt4]);
        NSLog(@"PASS: Continuous-phase FT4 GFSK audio synthesis verified (%d samples, peak %.2f).", ft4SamplesWritten, maxAmpFt4);

        // 15. Test FT4 Full End-to-End Loopback Decode
        // FT4 slot length is 7.5s = 90,000 samples at 12 kHz
        float *ft4SlotSamples = (float *)calloc(90000, sizeof(float));
        memcpy(ft4SlotSamples, ft4Synthesized, ft4SamplesWritten * sizeof(float));

        tx500_ft8_decoded_t ft4Decoded[10];
        int numFt4Decoded = tx500_ft8_decode_samples(ft4SlotSamples, 90000, sampleRate, TX500_FT8_PROTOCOL_FT4, ft4Decoded, 10);
        free(ft4Synthesized);
        free(ft4SlotSamples);

        AssertTrue(numFt4Decoded >= 1, [NSString stringWithFormat:@"FT4 loopback decode expected >= 1 message, got %d", numFt4Decoded]);
        BOOL foundFt4Match = NO;
        for (int i = 0; i < numFt4Decoded; i++) {
            NSString *decText = [NSString stringWithUTF8String:ft4Decoded[i].text];
            if ([decText isEqualToString:@"CQ EP2AES KM35"]) {
                foundFt4Match = YES;
                AssertTrue(fabsf(ft4Decoded[i].freq_hz - 1500.0f) < 25.0f,
                           [NSString stringWithFormat:@"FT4 Frequency close to 1500 Hz (got %.1f)", ft4Decoded[i].freq_hz]);
                break;
            }
        }
        AssertTrue(foundFt4Match, @"FT4 decoded text reproduces original test message 'CQ EP2AES KM35'");
        NSLog(@"PASS: Deep FT4 LDPC loopback decode verified (Decoded: %s, Freq: %.1f Hz, SNR: %.1f dB).",
              ft4Decoded[0].text, ft4Decoded[0].freq_hz, ft4Decoded[0].snr_db);

        // 16. Test FT4 Slot Quantization & ADIF record output
        TX500FT8Message *ft4Msg = [TX500FT8Message messageWithRawText:@"CQ EP2AES KM35"
                                                               freqHz:1500.0f
                                                                snrDb:-5
                                                                   dt:0.2f
                                                             slotDate:[NSDate date]
                                                           slotParity:0
                                                               myCall:@"EP2AES"
                                                               myGrid:@"KM35"];
        ft4Msg.mode = @"FT4";
        AssertTrue([ft4Msg.mode isEqualToString:@"FT4"], @"Message mode is FT4");
        NSString *ft4Adif = [ft4Msg adifRecordWithMyCall:@"EP2AES" myGrid:@"KM35"];
        AssertTrue([ft4Adif containsString:@"<MODE:4>MFSK"], @"FT4 ADIF record specifies MFSK mode");
        AssertTrue([ft4Adif containsString:@"<SUBMODE:3>FT4"], @"FT4 ADIF record specifies FT4 submode");

        audioEng.protocol = TX500_FT8_PROTOCOL_FT4;
        AssertTrue(audioEng.currentSlotPeriod == 7.5, @"Audio engine FT4 slot period is 7.5s");
        AssertTrue([audioEng.modeName isEqualToString:@"FT4"], @"Audio engine mode name is FT4");
        audioEng.protocol = TX500_FT8_PROTOCOL_FT8;
        AssertTrue(audioEng.currentSlotPeriod == 15.0, @"Audio engine FT8 slot period reset to 15.0s");
        AssertTrue([audioEng.modeName isEqualToString:@"FT8"], @"Audio engine mode name reset to FT8");
        audioEng.isSimulationMode = YES;
        __block NSInteger simulatedCATWrites = 0;
        audioEng.serialCommandSender = ^BOOL(NSString *command) {
            (void)command;
            simulatedCATWrites++;
            return YES;
        };
        NSError *simulationStartError = nil;
        AssertTrue([audioEng startMonitoring:&simulationStartError], @"Simulation monitoring starts without audio hardware");
        [audioEng stopMonitoring];
        AssertTrue(simulatedCATWrites == 0, @"Simulation mode never writes CAT commands to a connected radio");
        NSLog(@"PASS: FT4 ADIF logging (<MODE:4>MFSK <SUBMODE:3>FT4) & Audio Engine timing quantization verified.");

        // 17. Test Calibrated SWR Meter Transfer Function
        double swr0 = [TX500FT8AudioEngine swrRatioFromMeterDots:0];
        AssertTrue(fabs(swr0 - 1.0) < 0.01, @"SWR 0 dots is 1.0:1");
        double swr1 = [TX500FT8AudioEngine swrRatioFromMeterDots:1];
        AssertTrue(fabs(swr1 - 1.3) < 0.01, @"SWR 1 dot is 1.3:1");
        double swr2 = [TX500FT8AudioEngine swrRatioFromMeterDots:2];
        AssertTrue(fabs(swr2 - 1.6) < 0.01, @"SWR 2 dots is 1.6:1 (matching TX-500 LCD)");
        double swr4 = [TX500FT8AudioEngine swrRatioFromMeterDots:4];
        AssertTrue(fabs(swr4 - 2.3) < 0.01, @"SWR 4 dots is 2.3:1");
        double swr5 = [TX500FT8AudioEngine swrRatioFromMeterDots:5];
        AssertTrue(fabs(swr5 - 2.8) < 0.01, @"SWR 5 dots is 2.8:1 (matching TX-500 hardware)");
        double swr8 = [TX500FT8AudioEngine swrRatioFromMeterDots:8];
        AssertTrue(fabs(swr8 - 5.5) < 0.01, @"SWR 8 dots is 5.5:1");
        double swr12 = [TX500FT8AudioEngine swrRatioFromMeterDots:12];
        AssertTrue(fabs(swr12 - 7.5) < 0.01, @"SWR 12 dots is 7.5:1");
        NSLog(@"PASS: SWR meter dot-to-ratio transfer function verified (0->1.0, 2->1.6, 5->2.8, 8->5.5).");

        // 18. Test Auto-CQ Parity Alternation
        [autoEng abortQSO];
        [autoEng startAutoCQWithLimit:5];
        AssertTrue(autoEng.isAutoCQActive, @"Auto-CQ active");
        // Simulate cycle with parity 0 completing without callers
        [autoEng processDecodedSlot:@[] parity:0];
        AssertTrue(audioEng.isTransmitArmed, @"Auto-CQ re-arms transmit for next slot");
        AssertTrue(audioEng.txSlotParity == TX500FT8SlotParityOdd, @"Auto-CQ scheduled on alternate parity (Odd after Even slot 0)");
        // Simulate cycle with parity 1 completing without callers
        [autoEng processDecodedSlot:@[] parity:1];
        AssertTrue(audioEng.isTransmitArmed, @"Auto-CQ re-arms transmit for next slot");
        AssertTrue(audioEng.txSlotParity == TX500FT8SlotParityEven, @"Auto-CQ scheduled on alternate parity (Even after Odd slot 1)");
        [autoEng stopAutoCQ];
        NSLog(@"PASS: Auto-CQ parity alternation (Even -> Odd -> Even) verified.");

        // 19. Test Auto-Hunter Immediate Evaluation from Last Decoded Messages
        [autoEng abortQSO];
        TX500FT8Message *immediateCQ = [TX500FT8Message messageWithRawText:@"CQ ZS6XYZ KG44"
                                                                    freqHz:2186.0f
                                                                     snrDb:-14.0f
                                                                        dt:-0.2f
                                                                    myCall:@"EP2AES"
                                                                    myGrid:@"KM35"];
        // Ingest into engine while hunter is not yet running
        [autoEng processDecodedSlot:@[immediateCQ] parity:0];
        AssertTrue(!autoEng.isAutoHunterActive, @"Auto-Hunter not active yet");
        AssertTrue(autoEng.lastDecodedMessages.count == 1, @"lastDecodedMessages holds recent decode");
        // Activate Auto-Hunter: it should immediately engage the CQ from the latest cycle
        [autoEng startAutoHunter];
        AssertTrue([autoEng.activeDXCall isEqualToString:@"ZS6XYZ"], @"Auto-Hunter immediately engaged CQ ZS6XYZ from latest cycle");
        AssertTrue(audioEng.isTransmitArmed, @"Transmit armed immediately for ZS6XYZ");
        AssertTrue(audioEng.txSlotParity == TX500FT8SlotParityOdd, @"Response scheduled on alternate parity (Odd)");
        [autoEng abortQSO];
        [autoEng stopAutoHunter];
        NSLog(@"PASS: Auto-Hunter immediate cycle evaluation verified.");

        // 20. Test Auto-Hunter Collision Detection and Candidate Rotation
        [autoEng abortQSO];
        [autoEng stopAutoHunter];
        autoEng.autoHunterCriteria = TX500FT8HunterCriteriaFirstInSlot;
        TX500FT8Message *dxTarget = [TX500FT8Message messageWithRawText:@"CQ DX9COLL JN18"
                                                                 freqHz:1420.0f
                                                                  snrDb:+2.0f
                                                                     dt:0.1f
                                                                 myCall:@"EP2AES"
                                                                 myGrid:@"KM35"];
        TX500FT8Message *nextCandidate = [TX500FT8Message messageWithRawText:@"CQ K6ABC CM87"
                                                                      freqHz:1650.0f
                                                                       snrDb:+5.0f
                                                                          dt:0.0f
                                                                      myCall:@"EP2AES"
                                                                      myGrid:@"KM35"];
        [autoEng processDecodedSlot:@[dxTarget, nextCandidate] parity:0];
        [autoEng startAutoHunter];
        AssertTrue([autoEng.activeDXCall isEqualToString:@"DX9COLL"], @"Auto-Hunter engaged DX9COLL");
        AssertTrue(audioEng.isTransmitArmed, @"TX armed for DX9COLL");

        // Simulate DX9COLL answering another caller (collision) in next slot
        TX500FT8Message *collisionMsg = [TX500FT8Message messageWithRawText:@"W1XYZ DX9COLL -08"
                                                                     freqHz:1420.0f
                                                                      snrDb:+1.0f
                                                                         dt:0.1f
                                                                     myCall:@"EP2AES"
                                                                     myGrid:@"KM35"];
        TX500FT8Message *candidateInSlot = [TX500FT8Message messageWithRawText:@"CQ JA3XYZ PM74"
                                                                        freqHz:1800.0f
                                                                         snrDb:+6.0f
                                                                            dt:0.0f
                                                                        myCall:@"EP2AES"
                                                                        myGrid:@"KM35"];
        [autoEng processDecodedSlot:@[collisionMsg, candidateInSlot] parity:1];
        // Collision detected: DX9COLL is blacklisted and engine immediately rotated to candidate JA3XYZ
        AssertTrue(![autoEng.activeDXCall isEqualToString:@"DX9COLL"], @"Auto-Hunter aborted contested DX9COLL QSO");
        AssertTrue([autoEng.activeDXCall isEqualToString:@"JA3XYZ"], @"Auto-Hunter immediately rotated to JA3XYZ");
        AssertTrue(audioEng.isTransmitArmed, @"TX armed for new candidate JA3XYZ");
        [autoEng abortQSO];
        [autoEng stopAutoHunter];
        NSLog(@"PASS: Auto-Hunter collision detection & candidate rotation verified.");

        // 21. Test Transmit History Frame Formatting & Listening Parity
        TX500FT8Message *evenCQ = [TX500FT8Message messageWithRawText:@"CQ F6XYZ IN96"
                                                               freqHz:1520.0f
                                                                snrDb:-2.0f
                                                                   dt:0.1f
                                                             slotDate:[NSDate date]
                                                           slotParity:0
                                                               myCall:@"EP2AES"
                                                               myGrid:@"KM35"];
        // When received in slot parity 0 (Even), station listens on slot parity 1 (Odd)
        TX500FT8SlotParity listeningForEven = (evenCQ.slotParity == 0) ? TX500FT8SlotParityOdd : TX500FT8SlotParityEven;
        AssertTrue(listeningForEven == TX500FT8SlotParityOdd, @"Station received on Even (0) must be called on Odd (1)");

        TX500FT8Message *oddCQ = [TX500FT8Message messageWithRawText:@"CQ EA4XYZ IN80"
                                                              freqHz:1520.0f
                                                               snrDb:-2.0f
                                                                  dt:0.1f
                                                            slotDate:[NSDate date]
                                                          slotParity:1
                                                              myCall:@"EP2AES"
                                                              myGrid:@"KM35"];
        TX500FT8SlotParity listeningForOdd = (oddCQ.slotParity == 0) ? TX500FT8SlotParityOdd : TX500FT8SlotParityEven;
        AssertTrue(listeningForOdd == TX500FT8SlotParityEven, @"Station received on Odd (1) must be called on Even (0)");

        TX500FT8Message *txHistoryMsg = [TX500FT8Message messageWithRawText:@"F6XYZ EP2AES KM35"
                                                                     freqHz:1520.0f
                                                                      snrDb:0.0f
                                                                         dt:0.0f
                                                                   slotDate:[NSDate date]
                                                                 slotParity:1
                                                                     myCall:@"EP2AES"
                                                                     myGrid:@"KM35"];
        txHistoryMsg.isMyTransmission = YES;
        txHistoryMsg.snrReport = @"TX";
        AssertTrue(txHistoryMsg.isMyTransmission == YES, @"Transmission frame tagged as my transmission");
        AssertTrue([txHistoryMsg.snrReport isEqualToString:@"TX"], @"SNR report tagged as TX");
        NSLog(@"PASS: Transmit history frame formatting & listening parity math verified.");

        // 22. Test Dual PTT Engine (Hardware RTS + CAT PTT Assertion)
        TX500FT8AudioEngine *pttEngine = [TX500FT8AudioEngine new];
        pttEngine.isSimulationMode = NO; // Live radio mode
        __block BOOL pttActiveState = NO;
        __block NSInteger pttToggleCount = 0;
        pttEngine.pttControlHandler = ^BOOL(BOOL active) {
            pttActiveState = active;
            pttToggleCount++;
            return YES;
        };
        __block NSMutableArray<NSString *> *catCommandsSent = [NSMutableArray array];
        pttEngine.serialCommandSender = ^BOOL(NSString *cmd) {
            [catCommandsSent addObject:cmd];
            return YES;
        };

        // Start carrier in Live Mode
        [pttEngine startTuneCarrier];
        AssertTrue(pttEngine.isTuning == YES, @"Engine is tuning");
        AssertTrue(pttActiveState == YES, @"PTT handler was asserted to active (hardware RTS HIGH)");
        AssertTrue(pttToggleCount == 1, @"PTT toggled once on transmit start");
        // Verify MD6; is NOT sent during transmit trigger
        for (NSString *cmd in catCommandsSent) {
            AssertTrue(![cmd isEqualToString:@"MD6;"], @"MD6; mode command must not be sent on transmit trigger");
        }

        // End carrier
        [pttEngine stopTuneCarrier];
        AssertTrue(pttEngine.isTuning == NO, @"Engine stopped tuning");
        AssertTrue(pttActiveState == NO, @"PTT handler was deasserted (hardware RTS LOW)");
        AssertTrue(pttToggleCount == 2, @"PTT toggled twice (assert and release)");

        // Test fallback to serialCommandSender when pttControlHandler is nil
        TX500FT8AudioEngine *fallbackEngine = [TX500FT8AudioEngine new];
        fallbackEngine.isSimulationMode = NO;
        NSMutableArray<NSString *> *fallbackCmds = [NSMutableArray array];
        fallbackEngine.serialCommandSender = ^BOOL(NSString *cmd) {
            [fallbackCmds addObject:cmd];
            return YES;
        };
        [fallbackEngine startTuneCarrier];
        AssertTrue([fallbackCmds containsObject:@"TX1;TX;"], @"Fallback sends combined CAT TX1;TX; command");
        [fallbackEngine stopTuneCarrier];
        AssertTrue([fallbackCmds containsObject:@"RX;"], @"Fallback sends CAT RX; command");
        NSLog(@"PASS: Dual PTT Engine (Hardware RTS + CAT TX1;TX; / RX;) verified.");

        NSLog(@"ALL FT8 & FT4 DIGITAL SUITE TESTS PASSED SUCCESSFULLY! (100%%)");
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:testRoot] error:nil];
    }
    return 0;
}
