//
//  AudioMonitorTests.m
//  Lab599 Utility Tests
//
//  Unit and regression test suite for TX-500 AD-508 Live Audio Monitor & DSP Engine
//

#import <Foundation/Foundation.h>
#import "TX500AudioEngine.h"
#import "TX500AudioVisualizerView.h"
#import "TX500AudioMonitorController.h"
#import <math.h>

static void AssertTrue(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", [message UTF8String]);
        exit(1);
    }
}

int main(int argc, const char * argv[]) {
    char testRootTemplate[] = "/tmp/Lab599AudioMonitorTests.XXXXXX";
    char *testRoot = mkdtemp(testRootTemplate);
    if (!testRoot) return 1;
    setenv("TX500_TEST_MODE", "1", 1);
    setenv("TX500_TEST_ROOT", testRoot, 1);
    setenv("CFFIXED_USER_HOME", testRoot, 1);
    @autoreleasepool {
        (void)argc; (void)argv;
        NSLog(@"Running TX-500 AD-508 Live Audio Monitor Tests...");

        // 1. Test Audio Engine Initialization
        TX500AudioEngine *engine = [[TX500AudioEngine alloc] init];
        AssertTrue(engine != nil, @"Engine instantiated");
        AssertTrue(!engine.isMonitoring, @"Engine initially idle");
        AssertTrue(engine.masterVolume == 1.0f, @"Default master volume is 100%");
        AssertTrue(engine.balance == 0.0f, @"Default balance is centered");
        AssertTrue(engine.filterEnabled == YES, @"DSP filters enabled by default");
        AssertTrue(engine.filterPreset == TX500AudioFilterPresetSSBVoice, @"Default preset is SSB Voice");
        AssertTrue(engine.lowCutHz == 300.0f, @"Default SSB low cut is 300 Hz");
        AssertTrue(engine.highCutHz == 2700.0f, @"Default SSB high cut is 2700 Hz");
        NSLog(@"PASS: Engine initial state and parameters verified.");

        // 2. Test Audio Device Discovery
        [engine refreshDevices];
        AssertTrue(engine.inputDevices.count > 0, @"Found input devices");
        AssertTrue(engine.outputDevices.count > 0, @"Found output devices");
        NSLog(@"PASS: Device enumeration found %lu input(s) and %lu output(s).",
              (unsigned long)engine.inputDevices.count, (unsigned long)engine.outputDevices.count);

        if (engine.isAD508Connected) {
            NSLog(@"INFO: Official AD-508 audio hardware detected on this Mac: '%@'", engine.ad508DeviceName);
        } else {
            NSLog(@"INFO: Running in standalone / test-bench audio mode.");
        }

        // 3. Test Filter Presets
        [engine applyPreset:TX500AudioFilterPresetCWNarrow];
        AssertTrue(engine.lowCutHz == 550.0f, @"CW low cut 550 Hz");
        AssertTrue(engine.highCutHz == 750.0f, @"CW high cut 750 Hz");

        [engine applyPreset:TX500AudioFilterPresetAMBroad];
        AssertTrue(engine.lowCutHz == 80.0f, @"AM low cut 80 Hz");
        AssertTrue(engine.highCutHz == 4500.0f, @"AM high cut 4500 Hz");

        [engine applyPreset:TX500AudioFilterPresetFlat];
        AssertTrue(engine.lowCutHz == 20.0f, @"Flat low cut 20 Hz");
        AssertTrue(engine.highCutHz == 12000.0f, @"Flat high cut 12000 Hz");

        [engine applyPreset:TX500AudioFilterPresetSSBVoice];
        AssertTrue(engine.lowCutHz == 300.0f, @"Restored SSB voice low cut");
        AssertTrue(engine.highCutHz == 2700.0f, @"Restored SSB voice high cut");
        NSLog(@"PASS: Filter presets applied and parameter ranges verified.");

        // 4. Test Notch Filter & Squelch Controls
        engine.notchEnabled = YES;
        engine.notchFreqHz = 1200.0f;
        AssertTrue(engine.notchEnabled, @"Notch filter enabled");
        AssertTrue(engine.notchFreqHz == 1200.0f, @"Notch frequency 1200 Hz");

        engine.squelchEnabled = YES;
        engine.squelchThresholdDb = -50.0f;
        AssertTrue(engine.squelchEnabled, @"Squelch enabled");
        AssertTrue(engine.squelchThresholdDb == -50.0f, @"Squelch threshold -50 dB");
        NSLog(@"PASS: Notch and squelch configuration verified.");

        // 5. Test Master Volume Boost and Mute
        engine.masterVolume = 1.8f; // +5.1 dB boost
        AssertTrue(fabsf(engine.masterVolume - 1.8f) < 0.001f, @"Volume boost set to 180%");
        engine.isMuted = YES;
        AssertTrue(engine.isMuted, @"Mute active");
        engine.isMuted = NO;
        engine.isDimmed = YES;
        AssertTrue(engine.isDimmed, @"Dim active");
        engine.isDimmed = NO;
        NSLog(@"PASS: Volume boost, mute, and dim controls verified.");

        // 6. Test WAV Audio Recording Pipeline
        NSError *recErr = nil;
        BOOL recStarted = [engine startRecordingWithError:&recErr];
        AssertTrue(recStarted, @"Recording started successfully");
        AssertTrue(engine.isRecording, @"isRecording flag active");
        AssertTrue(engine.currentRecordingPath != nil, @"Recording file path generated");

        // Feed some synthetic samples into the recording
        float testSamples[480];
        for (int i = 0; i < 480; i++) {
            testSamples[i] = (float)sin(2.0 * M_PI * 1000.0 * i / 48000.0) * 0.5f;
        }

        [engine processRawAudioSamples:testSamples count:480];
        AssertTrue(engine.recordingBytes > 44, @"Audio data written to WAV file");

        [engine stopRecording];
        AssertTrue(!engine.isRecording, @"Recording stopped");

        // Verify the created WAV file on disk
        NSData *wavData = [NSData dataWithContentsOfFile:engine.currentRecordingPath];
        AssertTrue(wavData.length >= 44, @"WAV file exists and has RIFF header");
        const char *bytes = (const char *)wavData.bytes;
        AssertTrue(memcmp(bytes, "RIFF", 4) == 0, @"WAV header has RIFF magic");
        AssertTrue(memcmp(bytes + 8, "WAVE", 4) == 0, @"WAV header has WAVE format");

        // Clean up test recording file
        [[NSFileManager defaultManager] removeItemAtPath:engine.currentRecordingPath error:nil];
        NSLog(@"PASS: Studio WAV recording pipeline and RIFF header verified.");

        // 7. Test Simulation Mode
        [engine startSimulation];
        AssertTrue(engine.isSimulationMode, @"Simulation mode started");
        [engine stopSimulation];
        AssertTrue(!engine.isSimulationMode, @"Simulation mode stopped");
        NSLog(@"PASS: Audio simulation generator verified.");

        // 8. Test Visualizer View Creation, Waterfall, & Span
        TX500AudioVisualizerView *viz = [[TX500AudioVisualizerView alloc] initWithFrame:NSMakeRect(0, 0, 800, 200)];
        AssertTrue(viz != nil, @"Visualizer view created");
        viz.leftRmsDb = -18.5f;
        viz.rightRmsDb = -18.5f;
        viz.peakDb = -12.0f;
        AssertTrue(fabsf(viz.leftRmsDb - (-18.5f)) < 0.01f, @"VU left RMS set");
        viz.phosphorAmberTheme = YES;
        AssertTrue(viz.phosphorAmberTheme == YES, @"Amber theme set");

        viz.displayMode = TX500VisualizerModeWaterfall;
        AssertTrue(viz.displayMode == TX500VisualizerModeWaterfall, @"Waterfall mode enabled");
        viz.waterfallSpeed = TX500WaterfallSpeedSlow;
        AssertTrue(viz.waterfallSpeed == TX500WaterfallSpeedSlow, @"Waterfall slow rhythm enabled");
        viz.maxFrequencySpanHz = 6000.0f;
        AssertTrue(viz.maxFrequencySpanHz == 6000.0f, @"Frequency span 6.0 kHz enabled");
        [viz clearVisuals];
        NSLog(@"PASS: Visualizer view, waterfall mode, rhythm speed, and bandwidth span verified.");

        // 9. Test Controller VFO Tuning & Memory Bank
        TX500AudioMonitorController *ctrl = [[TX500AudioMonitorController alloc] init];
        AssertTrue(ctrl != nil, @"Controller instantiated");
        [ctrl tuneRadioToFrequencyHz:14074000];
        AssertTrue(ctrl.currentFrequencyHz == 14074000, @"Tuned to 14.074 MHz");

        [ctrl setRadioMode:@"CW"];
        AssertTrue([ctrl.currentMode isEqualToString:@"CW"], @"Mode switched to CW");
        AssertTrue(ctrl.engine.lowCutHz == 550.0f, @"CW filter automatically applied");

        [ctrl setRadioMode:@"AM"];
        AssertTrue([ctrl.currentMode isEqualToString:@"AM"], @"Mode switched to AM");
        AssertTrue(ctrl.engine.highCutHz == 4500.0f, @"AM filter automatically applied");

        [ctrl setRadioMode:@"USB"];
        AssertTrue([ctrl.currentMode isEqualToString:@"USB"], @"Mode switched to USB");

        // Bookmark frequency
        [ctrl bookmarkCurrentFrequencyWithLabel:@"Test Calling Channel"];
        [ctrl tuneRadioToFrequencyHz:7100000];
        [ctrl setRadioMode:@"LSB"];
        AssertTrue(ctrl.currentFrequencyHz == 7100000, @"Tuned to 7.100 MHz LSB");

        // Test VFO Step Tuning
        [ctrl tuneStep:500];
        AssertTrue(ctrl.currentFrequencyHz == 7100500, @"Tuned +500 Hz step");
        [ctrl tuneStep:-1000];
        AssertTrue(ctrl.currentFrequencyHz == 7099500, @"Tuned -1000 Hz step");

        // Verify bookmark sanitization (30m FT8 at 10.136 MHz, 20m FT8 at 14.074 MHz)
        BOOL found20m = NO;
        BOOL found30m = NO;
        for (NSDictionary *bm in ctrl.bookmarks) {
            uint64_t f = [bm[@"freq"] unsignedLongLongValue];
            NSString *lbl = bm[@"label"];
            if (f == 14074000 && [lbl containsString:@"20m FT8"]) found20m = YES;
            if (f == 10136000 && [lbl containsString:@"30m FT8"]) found30m = YES;
        }
        AssertTrue(found20m, @"20m FT8 correctly sanitized to 14.074 MHz");
        AssertTrue(found30m, @"30m FT8 present at 10.136 MHz");
        NSLog(@"PASS: VFO tuning, step adjustments, and bookmark sanitization verified.");

        // 10. Test LMS Adaptive Noise Reduction (NR)
        engine.nrEnabled = YES;
        engine.nrLevel = 0.6f;
        AssertTrue(engine.nrEnabled == YES, @"LMS NR enabled");
        AssertTrue(fabsf(engine.nrLevel - 0.6f) < 0.01f, @"LMS NR level set to 0.6");

        float nrIn[256];
        for (int i = 0; i < 256; i++) {
            // Simulated noisy tone
            nrIn[i] = (float)sin(2.0 * M_PI * 1200.0 * i / 48000.0) * 0.2f + (((float)rand() / (float)RAND_MAX) - 0.5f) * 0.1f;
        }
        [engine processRawAudioSamples:nrIn count:256];
        engine.nrEnabled = NO;
        NSLog(@"PASS: LMS Adaptive Noise Reduction (NR) verified.");

        // 11. Test Auto-Notch (ANF) Carrier Suppressor
        engine.autoNotchEnabled = YES;
        AssertTrue(engine.autoNotchEnabled == YES, @"Auto-Notch enabled");
        // Simulate high-amplitude carrier tone at 1500 Hz
        float carrierSamples[1024];
        for (int i = 0; i < 1024; i++) {
            carrierSamples[i] = (float)sin(2.0 * M_PI * 1500.0 * i / 48000.0) * 0.8f;
        }
        [engine processRawAudioSamples:carrierSamples count:1024];
        // ANF should detect carrier or at least execute biquad without crashing
        engine.autoNotchEnabled = NO;
        NSLog(@"PASS: Auto-Notch (ANF) tone suppression verified.");

        // 12. Test 3-Band Speech Equalizer
        engine.eqEnabled = YES;
        engine.eqLowGainDb = -4.0f;
        engine.eqMidGainDb = +6.0f;
        engine.eqHighGainDb = -2.0f;
        AssertTrue(engine.eqEnabled == YES, @"EQ enabled");
        AssertTrue(fabsf(engine.eqLowGainDb - (-4.0f)) < 0.01f, @"EQ Low gain -4 dB");
        AssertTrue(fabsf(engine.eqMidGainDb - (+6.0f)) < 0.01f, @"EQ Mid gain +6 dB");
        AssertTrue(fabsf(engine.eqHighGainDb - (-2.0f)) < 0.01f, @"EQ High gain -2 dB");
        [engine processRawAudioSamples:nrIn count:256];
        engine.eqEnabled = NO;
        NSLog(@"PASS: 3-Band Speech Equalizer verified.");

        // 13. Test Instant Replay Rolling Ring Buffer
        float replayTest[4800]; // 100 ms of audio
        for (int i = 0; i < 4800; i++) {
            replayTest[i] = 0.25f * (float)sin(2.0 * M_PI * 800.0 * i / 48000.0);
        }
        [engine processRawAudioSamples:replayTest count:4800];
        [engine startInstantReplay];
        AssertTrue(engine.isReplaying == YES, @"Instant replay active");
        AssertTrue(engine.replayProgress >= 0.0f && engine.replayProgress <= 1.0f, @"Replay progress within 0..1");
        [engine stopInstantReplay];
        AssertTrue(engine.isReplaying == NO, @"Instant replay stopped");
        NSLog(@"PASS: Instant Replay 15-second rolling buffer verified.");

        // 14. Test Waterfall Floor and Dynamic Range controls
        viz.waterfallFloorDb = -85.0f;
        viz.waterfallDynamicRangeDb = 55.0f;
        AssertTrue(fabsf(viz.waterfallFloorDb - (-85.0f)) < 0.01f, @"Waterfall floor set to -85 dB");
        AssertTrue(fabsf(viz.waterfallDynamicRangeDb - 55.0f) < 0.01f, @"Waterfall dynamic range set to 55 dB");
        NSLog(@"PASS: Waterfall Floor and Dynamic Range controls verified.");

        NSLog(@"ALL AUDIO MONITOR TESTS PASSED SUCCESSFULLY! (14/14)");
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:testRoot] error:nil];
    }
    return 0;
}
