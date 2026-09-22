#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "TX500CWAudioDecoder.h"

@interface TX500CWAudioDecoder (Private)
- (void)processRawAudioSamples:(const float *)channelData count:(int)totalFrames;
@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        (void)argc; (void)argv;
        NSLog(@"=== Running TX-500 CW Audio Decoder Tests on 20 Random Word Files ===");

        NSArray *testFiles = @[
            @{@"file": @"cw_test_01_3chars_XJW_5wpm_650hz.wav",    @"word": @"XJW",     @"wpm": @5.0,  @"pitch": @650.0},
            @{@"file": @"cw_test_02_3chars_QBZ_6wpm_700hz.wav",    @"word": @"QBZ",     @"wpm": @6.0,  @"pitch": @700.0},
            @{@"file": @"cw_test_03_3chars_KVH_8wpm_600hz.wav",    @"word": @"KVH",     @"wpm": @8.0,  @"pitch": @600.0},
            @{@"file": @"cw_test_04_4chars_PLFD_10wpm_750hz.wav",  @"word": @"PLFD",    @"wpm": @10.0, @"pitch": @750.0},
            @{@"file": @"cw_test_05_4chars_MYRX_12wpm_800hz.wav",  @"word": @"MYRX",    @"wpm": @12.0, @"pitch": @800.0},
            @{@"file": @"cw_test_06_4chars_TWCG_13wpm_1225hz.wav", @"word": @"TWCG",    @"wpm": @13.0, @"pitch": @1225.0},
            @{@"file": @"cw_test_07_4chars_SBJN_14wpm_650hz.wav",  @"word": @"SBJN",    @"wpm": @14.0, @"pitch": @650.0},
            @{@"file": @"cw_test_08_5chars_HZKVT_15wpm_700hz.wav", @"word": @"HZKVT",   @"wpm": @15.0, @"pitch": @700.0},
            @{@"file": @"cw_test_09_5chars_RDXMB_16wpm_600hz.wav", @"word": @"RDXMB",   @"wpm": @16.0, @"pitch": @600.0},
            @{@"file": @"cw_test_10_5chars_WQLPJ_18wpm_850hz.wav", @"word": @"WQLPJ",   @"wpm": @18.0, @"pitch": @850.0},
            @{@"file": @"cw_test_11_5chars_GMCFY_20wpm_650hz.wav", @"word": @"GMCFY",   @"wpm": @20.0, @"pitch": @650.0},
            @{@"file": @"cw_test_12_6chars_KTRWQX_22wpm_700hz.wav",@"word": @"KTRWQX",  @"wpm": @22.0, @"pitch": @700.0},
            @{@"file": @"cw_test_13_6chars_VBZPDL_24wpm_650hz.wav",@"word": @"VBZPDL",  @"wpm": @24.0, @"pitch": @650.0},
            @{@"file": @"cw_test_14_6chars_NJMFGH_25wpm_800hz.wav",@"word": @"NJMFGH",  @"wpm": @25.0, @"pitch": @800.0},
            @{@"file": @"cw_test_15_6chars_CXLYSW_26wpm_600hz.wav",@"word": @"CXLYSW",  @"wpm": @26.0, @"pitch": @600.0},
            @{@"file": @"cw_test_16_7chars_PBKVWZT_28wpm_700hz.wav",@"word": @"PBKVWZT", @"wpm": @28.0, @"pitch": @700.0},
            @{@"file": @"cw_test_17_7chars_MRXDFLQ_30wpm_650hz.wav",@"word": @"MRXDFLQ", @"wpm": @30.0, @"pitch": @650.0},
            @{@"file": @"cw_test_18_7chars_TGNSHYC_32wpm_750hz.wav",@"word": @"TGNSHYC", @"wpm": @32.0, @"pitch": @750.0},
            @{@"file": @"cw_test_19_7chars_WJPMKBX_34wpm_600hz.wav",@"word": @"WJPMKBX", @"wpm": @34.0, @"pitch": @600.0},
            @{@"file": @"cw_test_20_7chars_FLVQZND_36wpm_650hz.wav",@"word": @"FLVQZND", @"wpm": @36.0, @"pitch": @650.0},
        ];

        NSString *dir = @"/Users/factoreal/Downloads/TX-500/Updater/test_cw_audio";
        int passed = 0;
        int failed = 0;

        for (int idx = 0; idx < (int)testFiles.count; idx++) {
            NSDictionary *t = testFiles[idx];
            NSString *filename = t[@"file"];
            NSString *expectedWord = t[@"word"];
            double expectedWPM = [t[@"wpm"] doubleValue];
            double pitchHz = [t[@"pitch"] doubleValue];
            NSString *path = [dir stringByAppendingPathComponent:filename];

            NSURL *url = [NSURL fileURLWithPath:path];
            NSError *err = nil;
            AVAudioFile *audioFile = [[AVAudioFile alloc] initForReading:url error:&err];
            if (!audioFile) {
                NSLog(@"FAIL: Could not open audio file: %@", err);
                failed++;
                continue;
            }

            AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000.0 channels:1];
            AVAudioFrameCount frameCount = (AVAudioFrameCount)audioFile.length;
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frameCount];
            [audioFile readIntoBuffer:buffer error:&err];

            TX500CWAudioDecoder *decoder = [[TX500CWAudioDecoder alloc] init];
            decoder.nominalPitchHz = pitchHz;
            decoder.afcEnabled = YES;
            // Set initial nominal WPM close to expected or let it start at expected WPM
            [decoder setNominalWPM:expectedWPM];

            // Feed samples in 512-sample chunks (CoreAudio callback simulation)
            const float *samples = buffer.floatChannelData[0];
            int chunkSize = 512;
            int totalChunks = frameCount / chunkSize;
            for (int c = 0; c < totalChunks; c++) {
                [decoder processRawAudioSamples:(samples + c * chunkSize) count:chunkSize];
            }
            // Feed remaining samples
            int rem = frameCount % chunkSize;
            if (rem > 0) {
                [decoder processRawAudioSamples:(samples + totalChunks * chunkSize) count:rem];
            }

            NSString *decoded = [decoder.rawDecodedText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            BOOL ok = [decoded isEqualToString:expectedWord];
            if (ok) {
                passed++;
                printf("[TEST %02d/20] PASS | Word: %-7s | Decoded: %-7s | WPM: %4.1f (Est: %4.1f) | Tone: %6.1f Hz (Center: %6.1f Hz)\n",
                       idx + 1, [expectedWord UTF8String], [decoded UTF8String], expectedWPM, decoder.estimatedWPM, pitchHz, decoder.centerFrequencyHz);
            } else {
                failed++;
                printf("[TEST %02d/20] FAIL | Word: %-7s | Decoded: %-7s | WPM: %4.1f (Est: %4.1f) | Tone: %6.1f Hz (Center: %6.1f Hz)\n",
                       idx + 1, [expectedWord UTF8String], [decoded UTF8String], expectedWPM, decoder.estimatedWPM, pitchHz, decoder.centerFrequencyHz);
            }
        }

        printf("\n==============================================\n");
        printf("PASS 1 (CALIBRATED WPM): %d / %d PASSED, %d FAILED (%.1f%% SUCCESS RATE)\n", passed, (int)testFiles.count, failed, (double)passed / (double)testFiles.count * 100.0);
        printf("==============================================\n\n");

        printf("=== PASS 2: FULL BLIND ADAPTATION (Starting at 650 Hz nominal, 20.0 WPM for all files) ===\n");
        int blindPassed = 0;
        int blindFailed = 0;

        for (int idx = 0; idx < (int)testFiles.count; idx++) {
            NSDictionary *t = testFiles[idx];
            NSString *filename = t[@"file"];
            NSString *expectedWord = t[@"word"];
            double expectedWPM = [t[@"wpm"] doubleValue];
            double pitchHz = [t[@"pitch"] doubleValue];
            NSString *path = [dir stringByAppendingPathComponent:filename];

            NSURL *url = [NSURL fileURLWithPath:path];
            NSError *err = nil;
            AVAudioFile *audioFile = [[AVAudioFile alloc] initForReading:url error:&err];
            if (!audioFile) {
                blindFailed++;
                continue;
            }

            AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000.0 channels:1];
            AVAudioFrameCount frameCount = (AVAudioFrameCount)audioFile.length;
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:frameCount];
            [audioFile readIntoBuffer:buffer error:&err];

            TX500CWAudioDecoder *decoder = [[TX500CWAudioDecoder alloc] init];
            decoder.nominalPitchHz = 650.0; // Blind pitch
            decoder.afcEnabled = YES;        // Wideband AFC tracks pitch
            [decoder setNominalWPM:20.0];    // Blind starting WPM

            const float *samples = buffer.floatChannelData[0];
            int chunkSize = 512;
            int totalChunks = frameCount / chunkSize;
            for (int c = 0; c < totalChunks; c++) {
                [decoder processRawAudioSamples:(samples + c * chunkSize) count:chunkSize];
            }
            int rem = frameCount % chunkSize;
            if (rem > 0) {
                [decoder processRawAudioSamples:(samples + totalChunks * chunkSize) count:rem];
            }

            NSString *decoded = [decoder.rawDecodedText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            BOOL ok = [decoded isEqualToString:expectedWord];
            if (ok) {
                blindPassed++;
                printf("[BLIND %02d/20] PASS | Word: %-7s | Decoded: %-7s | WPM: %4.1f (Est: %4.1f) | Tone: %6.1f Hz (Center: %6.1f Hz)\n",
                       idx + 1, [expectedWord UTF8String], [decoded UTF8String], expectedWPM, decoder.estimatedWPM, pitchHz, decoder.centerFrequencyHz);
            } else {
                blindFailed++;
                printf("[BLIND %02d/20] FAIL | Word: %-7s | Decoded: %-7s | WPM: %4.1f (Est: %4.1f) | Tone: %6.1f Hz (Center: %6.1f Hz)\n",
                       idx + 1, [expectedWord UTF8String], [decoded UTF8String], expectedWPM, decoder.estimatedWPM, pitchHz, decoder.centerFrequencyHz);
            }
        }

        printf("\n==============================================\n");
        printf("PASS 2 (BLIND ADAPTATION): %d / %d PASSED, %d FAILED (%.1f%% SUCCESS RATE)\n", blindPassed, (int)testFiles.count, blindFailed, (double)blindPassed / (double)testFiles.count * 100.0);
        printf("==============================================\n");
    }
    return 0;
}
