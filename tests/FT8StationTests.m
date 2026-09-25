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

@interface TX500FT8AudioEngine (WaterfallTestAccess)
- (void)appendIncomingAudioSamples:(const float *)samples count:(NSInteger)count timestamp:(const AudioTimeStamp *)timestamp;
- (void)updateWaterfallStream;
- (void)processSlotTickAtUTC:(NSTimeInterval)utc;
- (void)startSWRPolling;
- (void)stopSWRPolling;
- (void)pollSWRMeter;
@end

static void AssertTrue(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", [message UTF8String]);
        exit(1);
    }
}

static BOOL WaitUntil(BOOL (^predicate)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!predicate() && [deadline timeIntervalSinceNow] > 0.0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    }
    return predicate();
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

        // Live waterfall uses the same incoming audio path as the decoder. Two
        // known carriers at different levels must land in the right 3 kHz bins,
        // retain their relative brightness, and stay above the noise field.
        TX500FT8AudioEngine *spectralEngine = [TX500FT8AudioEngine new];
        spectralEngine.isSimulationMode = NO;
        float testAudio[16384];
        uint32_t noiseState = 0x5a17c93u;
        for (int i = 0; i < 16384; i++) {
            noiseState = noiseState * 1664525u + 1013904223u;
            float noise = ((float)((noiseState >> 8) & 0xffff) / 32768.0f - 1.0f) * 0.03f;
            testAudio[i] = 0.22f * sinf(2.0f * (float)M_PI * 750.0f * i / 12000.0f) +
                           0.06f * sinf(2.0f * (float)M_PI * 1600.0f * i / 12000.0f) + noise;
        }
        float *spectrum = calloc(4096, sizeof(float));
        AssertTrue(spectrum != NULL, @"Waterfall test spectrum allocates");
        __block NSInteger spectrumCount = 0;
        spectralEngine.onSpectrumUpdated = ^(const float *magnitudes, NSInteger count) {
            spectrumCount = count;
            if (count == 4096) memcpy(spectrum, magnitudes, 4096 * sizeof(float));
        };
        [spectralEngine appendIncomingAudioSamples:testAudio count:16384 timestamp:NULL];
        [spectralEngine updateWaterfallStream];
        NSInteger strongBin = (NSInteger)lround(750.0 * 16384.0 / 12000.0);
        NSInteger weakBin = (NSInteger)lround(1600.0 * 16384.0 / 12000.0);
        AssertTrue(spectrumCount == 4096, @"Waterfall provides 4096 ultra-fine bins across the 3 kHz passband");
        AssertTrue(spectrum[strongBin] > spectrum[weakBin] && spectrum[weakBin] > spectrum[100] * 4.0f,
                   @"Precise 750 and 1600 Hz traces retain signal strength over deterministic noise");
        free(spectrum);

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

        // A meter read may still be waiting for the shared CAT lock when a TX
        // ends. Starting the next TX must not enqueue another read behind it;
        // otherwise repeated QSOs eventually delay the RX command itself.
        TX500FT8AudioEngine *meterGateEngine = [TX500FT8AudioEngine new];
        meterGateEngine.isSimulationMode = NO;
        __block NSInteger meterQueryCount = 0;
        dispatch_semaphore_t meterBlocker = dispatch_semaphore_create(0);
        meterGateEngine.catQueryHandler = ^NSString *(NSString *command, NSTimeInterval timeout) {
            (void)command; (void)timeout;
            meterQueryCount++;
            dispatch_semaphore_wait(meterBlocker, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC));
            return @"RM10001;";
        };
        [meterGateEngine setValue:@YES forKey:@"isTransmitting"];
        [meterGateEngine startSWRPolling];
        [meterGateEngine pollSWRMeter];
        AssertTrue(WaitUntil(^BOOL{ return meterQueryCount == 1; }, 0.5),
                   @"First CAT meter request starts");
        [meterGateEngine stopSWRPolling];
        [meterGateEngine startSWRPolling];
        [meterGateEngine pollSWRMeter];
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.12]];
        AssertTrue(meterQueryCount == 1,
                   @"A TX boundary cannot stack a second CAT meter request behind an unfinished one");
        dispatch_semaphore_signal(meterBlocker);
        AssertTrue(WaitUntil(^BOOL{ return meterQueryCount == 1; }, 0.2),
                   @"Outstanding meter request drains without spawning a duplicate");
        [meterGateEngine setValue:@NO forKey:@"isTransmitting"];
        [meterGateEngine stopSWRPolling];
        NSLog(@"PASS: Semantic message parsing verified.");

        // 7. Test Autonomous Engine: Auto-CQ Loop
        TX500FT8AudioEngine *audioEng = [[TX500FT8AudioEngine alloc] init];
        audioEng.myCallsign = @"EP2AES";
        audioEng.myGrid = @"KM35";
        audioEng.dialFrequencyHz = 28074000;
        audioEng.isSimulationMode = YES;

        TX500FT8AutoEngine *autoEng = [[TX500FT8AutoEngine alloc] init];
        autoEng.audioEngine = audioEng;

        [autoEng startAutoCQWithLimit:5];
        AssertTrue(autoEng.isAutoCQActive, @"Auto-CQ active");
        AssertTrue(autoEng.autoCQCurrentCount == 0, @"CQ count stays zero until PTT actually starts");
        AssertTrue(audioEng.repeatArmedTransmission, @"CQ remains armed on one parity");
        AssertTrue(autoEng.qsoPhase == TX500FT8QSOPhaseCallingCQ, @"QSO phase calling CQ");
        [autoEng noteTransmittedText:audioEng.queuedTxMessage];
        AssertTrue(autoEng.autoCQCurrentCount == 1, @"Only an actual keyed CQ advances the count");

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
        AssertTrue(!audioEng.repeatArmedTransmission, @"QSO reply is one-shot after CQ stops");
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
        AssertTrue([autoEng.sessionLog.firstObject.band isEqualToString:@"10m"],
                   @"A completed QSO at 28.074 MHz is logged on 10m, not a hard-coded band");

        NSString *adif = [autoEng generateADIFExport];
        AssertTrue([adif containsString:@"<CALL:6>DL7XYZ"], @"ADIF contains DL7XYZ");
        AssertTrue([adif containsString:@"<MODE:3>FT8"], @"ADIF contains MODE FT8");
        AssertTrue([adif containsString:@"<EOR>"], @"ADIF contains EOR");
        NSLog(@"PASS: Complete QSO state machine progression & ADIF generator verified.");

        // 9b. Test Full FT8 CQ Caller Response Progression (ER3PM -> EP2AES Scenario)
        [autoEng abortQSO];
        [autoEng stopAutoHunter];
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

        AssertTrue(autoEng.sessionLog.count == 0, @"QSO is not logged before the final acknowledgement is keyed");
        [autoEng processDecodedSlot:@[] parity:0];
        AssertTrue([audioEng.queuedTxMessage isEqualToString:@"ER3PM EP2AES RR73"],
                   @"A missed slot retries RR73 and never advances it to 73");
        [autoEng noteTransmittedText:audioEng.queuedTxMessage];
        AssertTrue(autoEng.sessionLog.count == 1, @"QSO logs when RR73 is actually transmitted");
        TX500FT8LoggedQSO *loggedER3PM = autoEng.sessionLog.firstObject;
        AssertTrue([loggedER3PM.callsign isEqualToString:@"ER3PM"], @"Logged call ER3PM");
        AssertTrue([loggedER3PM.grid isEqualToString:@"KN47"], @"Logged grid KN47");
        AssertTrue([loggedER3PM.rstSent isEqualToString:@"-14"], @"Logged sent RST -14");
        AssertTrue([loggedER3PM.rstRcvd isEqualToString:@"-12"], @"Logged rcvd RST -12");
        AssertTrue(autoEng.isAutoCQActive && [audioEng.queuedTxMessage hasPrefix:@"CQ EP2AES"],
                   @"A CQ-originated QSO returns to the original CQ loop after completion");
        [autoEng stopAutoCQ];
        NSLog(@"PASS: Full FT8 CQ caller response progression (ER3PM -> EP2AES) verified.");

        // A long run of completed contacts must always return to CQ without a
        // hidden three-contact ceiling or stale QSO lock.
        [autoEng abortQSO];
        [autoEng clearSessionLog];
        AssertTrue([autoEng startCQWithText:@"CQ EP2AES KM35" parity:TX500FT8SlotParityOdd limit:0],
                   @"Unlimited CQ starts for consecutive-QSO stress test");
        NSArray<NSString *> *stressCalls = @[@"JA1AAA", @"DL1BBB", @"W1CCC", @"VK2DDD",
                                             @"SP3EEE", @"F4FFF", @"R5GGG", @"I6HHH"];
        for (NSUInteger i = 0; i < stressCalls.count; i++) {
            NSString *call = stressCalls[i];
            NSString *grid = i % 2 ? @"JO62" : @"PM95";
            TX500FT8Message *answer = [TX500FT8Message messageWithRawText:
                [NSString stringWithFormat:@"EP2AES %@ %@", call, grid]
                                                               freqHz:700.0f + (float)i * 137.0f
                                                                 snrDb:-10.0f - (float)i
                                                                    dt:0.1f
                                                                myCall:@"EP2AES" myGrid:@"KM35"];
            [autoEng processDecodedSlot:@[answer] parity:1];
            AssertTrue([autoEng.activeDXCall isEqualToString:call],
                       [NSString stringWithFormat:@"Consecutive QSO %lu locks its caller", (unsigned long)i + 1]);
            TX500FT8Message *roger = [TX500FT8Message messageWithRawText:
                [NSString stringWithFormat:@"EP2AES %@ R-12", call]
                                                              freqHz:answer.freqHz snrDb:-12.0f dt:0.1f
                                                               myCall:@"EP2AES" myGrid:@"KM35"];
            [autoEng processDecodedSlot:@[roger] parity:1];
            AssertTrue(autoEng.qsoPhase == TX500FT8QSOPhaseSendingRR73,
                       @"Each consecutive QSO reaches RR73");
            [autoEng noteTransmittedText:audioEng.queuedTxMessage];
            AssertTrue(autoEng.sessionLog.count == i + 1 && autoEng.isAutoCQActive &&
                       [audioEng.queuedTxMessage hasPrefix:@"CQ EP2AES"],
                       [NSString stringWithFormat:@"Consecutive QSO %lu logs and resumes CQ", (unsigned long)i + 1]);
        }
        [autoEng stopAutoCQ];
        NSLog(@"PASS: Eight consecutive successful QSOs complete and resume CQ without a hidden limit.");

        // A second station calling during the final exchange must be answered
        // before Auto-CQ is resumed (the live SP6JQO / R2FEA failure case).
        [autoEng abortQSO];
        [autoEng clearSessionLog];
        AssertTrue([autoEng startCQWithText:@"CQ EP2AES KM35" parity:TX500FT8SlotParityOdd limit:0],
                   @"CQ loop starts for queued-caller test");
        TX500FT8Message *firstCaller = [TX500FT8Message messageWithRawText:@"EP2AES SP6JQO JO81"
                                                                   freqHz:1209 snrDb:-18 dt:-0.5
                                                                   myCall:@"EP2AES" myGrid:@"KM35"];
        [autoEng processDecodedSlot:@[firstCaller] parity:1];
        TX500FT8Message *firstRoger = [TX500FT8Message messageWithRawText:@"EP2AES SP6JQO R-07"
                                                                  freqHz:1209 snrDb:-17 dt:-0.6
                                                                  myCall:@"EP2AES" myGrid:@"KM35"];
        TX500FT8Message *waitingCaller = [TX500FT8Message messageWithRawText:@"EP2AES R2FEA KO04"
                                                                    freqHz:509 snrDb:-21 dt:-0.6
                                                                    myCall:@"EP2AES" myGrid:@"KM35"];
        NSString *lockedMessage = audioEng.queuedTxMessage;
        [autoEng engageStation:waitingCaller];
        AssertTrue([autoEng.activeDXCall isEqualToString:@"SP6JQO"] &&
                   [audioEng.queuedTxMessage isEqualToString:lockedMessage],
                   @"A manual or automatic engagement cannot replace an unfinished QSO");
        [autoEng processDecodedSlot:@[firstRoger, waitingCaller] parity:1];
        AssertTrue([audioEng.queuedTxMessage isEqualToString:@"SP6JQO EP2AES RR73"],
                   @"Current QSO still has priority for its final RR73");
        [autoEng noteTransmittedText:audioEng.queuedTxMessage];
        AssertTrue([autoEng.activeDXCall isEqualToString:@"R2FEA"] &&
                   [audioEng.queuedTxMessage isEqualToString:@"R2FEA EP2AES -21"],
                   @"Waiting directed caller is answered before another CQ");
        [autoEng abortQSO];
        NSLog(@"PASS: Directed callers arriving during QSO completion are queued ahead of CQ.");

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
        AssertTrue(fabs(swr1 - 1.4) < 0.01, @"SWR 1 dot reports the conservative 1.4:1 bin edge");
        double swr2 = [TX500FT8AudioEngine swrRatioFromMeterDots:2];
        AssertTrue(fabs(swr2 - 1.9) < 0.01, @"SWR 2 dots matches the TX-500 LCD at 1.9:1");
        double swr4 = [TX500FT8AudioEngine swrRatioFromMeterDots:4];
        AssertTrue(fabs(swr4 - 2.4) < 0.01, @"SWR 4 dots reports the conservative 2.4:1 bin edge");
        double swr5 = [TX500FT8AudioEngine swrRatioFromMeterDots:5];
        AssertTrue(fabs(swr5 - 2.9) < 0.01, @"SWR 5 dots reports the conservative 2.9:1 bin edge");
        double swr8 = [TX500FT8AudioEngine swrRatioFromMeterDots:8];
        AssertTrue(fabs(swr8 - 5.7) < 0.01, @"SWR 8 dots reports the conservative 5.7:1 bin edge");
        double swr12 = [TX500FT8AudioEngine swrRatioFromMeterDots:12];
        AssertTrue(fabs(swr12 - 7.7) < 0.01, @"SWR 12 dots reports the conservative 7.7:1 bin edge");
        NSInteger meterDots = -1;
        AssertTrue([TX500FT8AudioEngine parseMeterReply:@"RM30007;" meter:3 rawDots:&meterDots] && meterDots == 7,
                   @"Documented RM3 ALC meter frame parses correctly");
        AssertTrue(![TX500FT8AudioEngine parseMeterReply:@"RM10007;" meter:3 rawDots:&meterDots],
                   @"Wrong RM meter type is rejected");
        AssertTrue([TX500FT8AudioEngine parsePowerMeterReply:@"SM00012;" rawDots:&meterDots] && meterDots == 12,
                   @"Documented SM0 TX output meter frame parses correctly");
        __block BOOL swrDisplayCleared = NO;
        audioEng.onSWRMeterUpdated = ^(NSInteger rawDots, BOOL valid) {
            swrDisplayCleared = (!valid && rawDots == 0);
        };
        [audioEng armTransmitWithText:@"CQ EP2AES KM35" parity:TX500FT8SlotParityAuto];
        AssertTrue(!swrDisplayCleared,
                   @"Arming a future TX preserves the last SWR display until RF actually starts");
        [audioEng disarmTransmit];
        NSLog(@"PASS: SWR meter dot-to-ratio transfer function verified (0->1.0, 2->1.9, 5->2.9, 8->5.7).");

        // 18. Test Auto-CQ Parity Alternation
        [autoEng abortQSO];
        [autoEng startAutoCQWithLimit:5];
        AssertTrue(autoEng.isAutoCQActive, @"Auto-CQ active");
        TX500FT8SlotParity fixedParity = audioEng.txSlotParity;
        // Empty RX cycles must never flip the CQ parity or invent a transmission.
        [autoEng processDecodedSlot:@[] parity:0];
        AssertTrue(audioEng.isTransmitArmed && audioEng.repeatArmedTransmission, @"CQ remains armed after an empty receive slot");
        AssertTrue(audioEng.txSlotParity == fixedParity && autoEng.autoCQCurrentCount == 0,
                   @"No decode callback changes the chosen parity or actual TX count");
        [autoEng noteTransmittedText:audioEng.queuedTxMessage];
        [autoEng processDecodedSlot:@[] parity:1];
        AssertTrue(audioEng.txSlotParity == fixedParity && autoEng.autoCQCurrentCount == 1,
                   @"CQ repeats only on the originally selected parity");
        [autoEng stopAutoCQ];
        AssertTrue([autoEng startCQWithText:@"CQ EP2AES KM35" parity:TX500FT8SlotParityOdd limit:0],
                   @"Manual CQ can start an unlimited odd-slot cycle");
        [autoEng noteTransmittedText:audioEng.queuedTxMessage];
        [autoEng noteTransmittedText:audioEng.queuedTxMessage];
        [autoEng processDecodedSlot:@[] parity:0];
        AssertTrue(autoEng.isAutoCQActive && autoEng.autoCQCurrentCount == 2 &&
                   audioEng.txSlotParity == TX500FT8SlotParityOdd && audioEng.repeatArmedTransmission,
                   @"Unlimited CQ keeps odd parity until a caller answers or operator stops it");
        [autoEng stopAutoCQ];
        NSLog(@"PASS: CQ repeats on a fixed parity and counts actual keyed transmissions.");

        TX500FT8AudioEngine *cycleEngine = [TX500FT8AudioEngine new];
        cycleEngine.isSimulationMode = YES;
        __block NSInteger cqBursts = 0;
        cycleEngine.onTransmitStateChanged = ^(BOOL transmitting, NSString *text) {
            if (transmitting && [text hasPrefix:@"CQ "]) cqBursts++;
        };
        [cycleEngine armTransmitWithText:@"CQ EP2AES KM35" parity:TX500FT8SlotParityAuto];
        cycleEngine.repeatArmedTransmission = YES;
        [cycleEngine processSlotTickAtUTC:600.1]; // even
        AssertTrue(cqBursts == 1 && cycleEngine.isTransmitArmed, @"First even slot sends CQ and retains repeat intent");
        [cycleEngine processSlotTickAtUTC:614.6];
        AssertTrue(WaitUntil(^BOOL{ return !cycleEngine.isReceiveRecoveryPending; }, 1.0),
                   @"Simulated TX confirms RX before another burst");
        [cycleEngine processSlotTickAtUTC:615.1]; // odd
        AssertTrue(cqBursts == 1, @"Opposite odd slot remains RX");
        [cycleEngine processSlotTickAtUTC:630.1]; // even
        AssertTrue(cqBursts == 2, @"Second even slot sends the next CQ without a decode callback");
        [cycleEngine disarmTransmit];
        AssertTrue(WaitUntil(^BOOL{ return !cycleEngine.isReceiveRecoveryPending; }, 1.0),
                   @"Operator stop completes RX recovery");

        TX500FT8AudioEngine *oneShotEngine = [TX500FT8AudioEngine new];
        oneShotEngine.isSimulationMode = YES;
        __block NSInteger replies = 0;
        oneShotEngine.onTransmitStateChanged = ^(BOOL transmitting, NSString *text) {
            if (transmitting && [text hasPrefix:@"JA1ABC"]) replies++;
        };
        [oneShotEngine armTransmitWithText:@"JA1ABC EP2AES -08" parity:TX500FT8SlotParityEven];
        [oneShotEngine processSlotTickAtUTC:600.1];
        AssertTrue(replies == 1 && !oneShotEngine.isTransmitArmed,
                   @"A QSO reply transmits once and automatically disarms");
        [oneShotEngine processSlotTickAtUTC:614.6];
        AssertTrue(WaitUntil(^BOOL{ return !oneShotEngine.isReceiveRecoveryPending; }, 1.0), @"One-shot reply returns to RX");
        [oneShotEngine processSlotTickAtUTC:630.1];
        AssertTrue(replies == 1, @"One-shot QSO reply is not repeated in the next matching slot");

        TX500FT8AudioEngine *lateEngine = [TX500FT8AudioEngine new];
        lateEngine.isSimulationMode = YES;
        __block NSInteger lateBursts = 0;
        lateEngine.onTransmitStateChanged = ^(BOOL transmitting, NSString *text) {
            if (transmitting) lateBursts++;
        };
        [lateEngine armTransmitWithText:@"CQ EP2AES KM35" parity:TX500FT8SlotParityEven];
        lateEngine.repeatArmedTransmission = YES;
        [lateEngine processSlotTickAtUTC:602.0];
        AssertTrue(lateBursts == 0 && lateEngine.isTransmitArmed, @"A late callback skips the unsafe partial slot without losing CQ intent");
        [lateEngine processSlotTickAtUTC:630.1];
        AssertTrue(lateBursts == 1, @"Absolute slot index recovers at the next full even slot");
        [lateEngine disarmTransmit];
        NSLog(@"PASS: Repeating CQ, one-shot QSO and late slot recovery verified without RF hardware.");

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
        [autoEng stopAutoHunter];
        AssertTrue(!autoEng.isQSOActive && !audioEng.isTransmitArmed,
                   @"Turning Auto-Hunter off cancels the QSO and TX it started");

        TX500FT8Message *unsolicited = [TX500FT8Message messageWithRawText:@"EP2AES G8PGO IO92"
                                                                    freqHz:1447.0f
                                                                     snrDb:-8.0f
                                                                        dt:0.1f
                                                                    myCall:@"EP2AES"
                                                                    myGrid:@"KM35"];
        [autoEng processDecodedSlot:@[unsolicited] parity:1];
        AssertTrue(!autoEng.isQSOActive && !audioEng.isTransmitArmed,
                   @"An unsolicited directed decode cannot start TX while Auto-Hunter and Auto-CQ are off");
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

        // 22. Test confirmed station PTT and CAT fallback
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
        AssertTrue(pttActiveState == YES, @"PTT handler was asserted to active (confirmed TX)");
        AssertTrue(pttToggleCount == 1, @"PTT toggled once on transmit start");
        // Verify MD6; is NOT sent during transmit trigger
        for (NSString *cmd in catCommandsSent) {
            AssertTrue(![cmd isEqualToString:@"MD6;"], @"MD6; mode command must not be sent on transmit trigger");
        }

        // End carrier
        [pttEngine stopTuneCarrier];
        AssertTrue(pttEngine.isTuning == NO, @"Engine stopped tuning");
        AssertTrue(WaitUntil(^BOOL{ return !pttEngine.isTransmitting && !pttActiveState; }, 1.0),
                   @"PTT release is confirmed asynchronously without blocking the UI");
        AssertTrue(pttActiveState == NO, @"PTT handler was deasserted (confirmed RX)");
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
        AssertTrue([fallbackCmds containsObject:@"TX;"], @"Fallback sends TX; command");
        [fallbackEngine stopTuneCarrier];
        AssertTrue(WaitUntil(^BOOL{ return [fallbackCmds containsObject:@"RX;"]; }, 1.0),
                   @"Fallback RX cleanup completes asynchronously");
        AssertTrue([fallbackCmds containsObject:@"RX;"], @"Fallback sends CAT RX; command");
        NSLog(@"PASS: Confirmed PTT and CAT TX; / RX; verified.");

        TX500FT8AudioEngine *unverifiedDialEngine = [TX500FT8AudioEngine new];
        unverifiedDialEngine.isSimulationMode = NO;
        unverifiedDialEngine.requiresVerifiedCATDial = YES;
        __block NSUInteger guardedPTTCalls = 0;
        unverifiedDialEngine.pttControlHandler = ^BOOL(BOOL active) {
            guardedPTTCalls++;
            return YES;
        };
        [unverifiedDialEngine startTuneCarrier];
        AssertTrue(!unverifiedDialEngine.isTuning && guardedPTTCalls == 0,
                   @"An unverified CAT dial or mode cannot key the radio");
        unverifiedDialEngine.catDialAndModeVerified = YES;
        unverifiedDialEngine.dialFrequencyHz = 0;
        [unverifiedDialEngine startTuneCarrier];
        AssertTrue(!unverifiedDialEngine.isTuning && guardedPTTCalls == 0,
                   @"An unknown dial frequency cannot key even when a previous mode was verified");
        unverifiedDialEngine.dialFrequencyHz = 28074000;
        [unverifiedDialEngine startTuneCarrier];
        AssertTrue(unverifiedDialEngine.isTuning && guardedPTTCalls == 1,
                   @"A verified 28 MHz dial and DIG mode permit confirmed PTT");
        [unverifiedDialEngine stopTuneCarrier];
        AssertTrue(WaitUntil(^BOOL{ return !unverifiedDialEngine.isTransmitting; }, 1.0),
                   @"Verified tune returns to RX");

        TX500FT8AudioEngine *retryEngine = [TX500FT8AudioEngine new];
        retryEngine.isSimulationMode = NO;
        __block NSInteger retryReleaseCalls = 0;
        retryEngine.pttControlHandler = ^BOOL(BOOL active) {
            if (active) return YES;
            retryReleaseCalls++;
            return retryReleaseCalls >= 2;
        };
        [retryEngine armTransmitWithText:@"CQ EP2AES KM35" parity:TX500FT8SlotParityEven];
        retryEngine.repeatArmedTransmission = YES;
        [retryEngine startTuneCarrier];
        [retryEngine stopTuneCarrier];
        AssertTrue(WaitUntil(^BOOL{ return retryReleaseCalls >= 1 && retryEngine.isReceiveRecoveryPending; }, 1.0) &&
                   retryEngine.isTransmitArmed && retryEngine.repeatArmedTransmission,
                   @"A transient RX acknowledgement failure preserves the operator's repeated CQ intent");
        AssertTrue(WaitUntil(^BOOL{ return retryReleaseCalls >= 2 && !retryEngine.isTransmitting; }, 2.0),
                   @"A missing first RX acknowledgement is retried until receive is confirmed");
        AssertTrue(retryEngine.isTransmitArmed && !retryEngine.isReceiveRecoveryPending,
                   @"CQ remains armed after RX recovery succeeds");
        [retryEngine disarmTransmit];

        TX500FT8AudioEngine *rejectedEngine=[TX500FT8AudioEngine new];
        rejectedEngine.isSimulationMode=NO;
        __block NSUInteger releaseAttempts=0;
        rejectedEngine.pttControlHandler=^BOOL(BOOL active) { if(!active) releaseAttempts++; return !active; };
        [rejectedEngine startTuneCarrier];
        AssertTrue(!rejectedEngine.isTuning && !rejectedEngine.isTransmitting, @"Unconfirmed PTT never starts carrier/audio");
        AssertTrue(releaseAttempts==1, @"Unconfirmed TX still requests RX cleanup");
        TX500FT8AudioEngine *missingRoute=[TX500FT8AudioEngine new];
        missingRoute.preserveDeviceSelection=YES; missingRoute.isSimulationMode=NO;
        missingRoute.selectedInputDeviceUID=@"station-test-missing-input"; missingRoute.selectedOutputDeviceUID=@"station-test-missing-output";
        [missingRoute refreshAudioDevices];
        AssertTrue([missingRoute.selectedInputDeviceUID isEqual:@"station-test-missing-input"], @"Missing FT8 input is never silently replaced");
        NSError *routeError=nil;
        AssertTrue(![missingRoute startMonitoring:&routeError] && routeError!=nil && !missingRoute.isMonitoring, @"Missing FT8 route blocks start with a useful error");
        NSLog(@"ALL FT8 & FT4 DIGITAL SUITE TESTS PASSED SUCCESSFULLY! (100%%)");
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:testRoot] error:nil];
    }
    return 0;
}
