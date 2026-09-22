#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#import "TX500TimeDiscipline.h"
#import "TX500FT8Message.h"

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

int main(void) {
    @autoreleasepool {
        TX500DisciplinedClock *clock = [TX500DisciplinedClock sharedClock];
        double m0 = clock.monotonicTime;
        [clock resetForTestingAtUTC:1700000000.0 monotonicTime:m0];
        Check(fabs([clock utcTimeIntervalForMonotonicTime:m0 + 10.0] - 1700000010.0) < 0.001,
              @"Affine monotonic UTC advances independently of wall clock");

        BOOL accepted = [clock acceptUTCReference:1700000010.120 atMonotonicTime:m0 + 10.0
                               uncertaintySeconds:0.010 source:TX500TimeTrustStateNetwork stationCount:0];
        Check(accepted, @"High quality network reference accepted");
        TX500TimeSnapshot *online = clock.snapshot;
        Check(online.trustState == TX500TimeTrustStateNetwork, @"Network lock reported");
        Check(online.uncertaintySeconds < 0.10, @"Network update contracts uncertainty");

        [clock setCriticalTimingActive:YES];
        double before = [clock utcTimeIntervalForMonotonicTime:m0 + 11.0];
        accepted = [clock acceptUTCReference:before + 0.200 atMonotonicTime:m0 + 11.0
                          uncertaintySeconds:0.010 source:TX500TimeTrustStateNetwork stationCount:0];
        double after = [clock utcTimeIntervalForMonotonicTime:m0 + 11.0];
        Check(accepted && after >= before && after - before < 0.010,
              @"Critical timing slews phase correction without a clock step");
        double later = [clock utcTimeIntervalForMonotonicTime:m0 + 111.0];
        Check(later > after + 100.0, @"Disciplined UTC remains strictly increasing while slewing");
        [clock setCriticalTimingActive:NO];

        Check(![clock acceptUTCReference:later + 8.0 atMonotonicTime:m0 + 111.0
                         uncertaintySeconds:0.010 source:TX500TimeTrustStateNetwork stationCount:0],
              @"Gross network outlier rejected");

        // Calibrate a simulated +5 ppm host oscillator over one day, then
        // verify seven days of uninterrupted holdover stays inside two seconds.
        m0 = clock.monotonicTime;
        double reference0 = 1750000000.0;
        [clock resetForTestingAtUTC:reference0 monotonicTime:m0];
        for (NSInteger hour = 1; hour <= 24; hour++) {
            double elapsed = hour * 3600.0;
            double trueUTC = reference0 + elapsed * (1.0 + 5e-6);
            [clock acceptUTCReference:trueUTC atMonotonicTime:m0 + elapsed
                   uncertaintySeconds:0.010 source:TX500TimeTrustStateNetwork stationCount:0];
        }
        double sevenDays = 7.0 * 86400.0;
        double predicted = [clock utcTimeIntervalForMonotonicTime:m0 + 86400.0 + sevenDays];
        double expected = reference0 + (86400.0 + sevenDays) * (1.0 + 5e-6);
        Check(fabs(predicted - expected) < 2.0, @"Seven-day calibrated holdover remains within two seconds");

        // Learn per-transmitter delays under a trusted network lock, then
        // recover a common +180 ms local-clock error from three offline slots.
        NSArray<NSString *> *calls = @[@"K1AAA", @"W2BBB", @"N3CCC", @"K4DDD",
                                        @"W5EEE", @"N6FFF", @"K7GGG", @"W8HHH", @"N9III"];
        m0 = clock.monotonicTime;
        [clock resetForTestingAtUTC:1800000000.0 monotonicTime:m0];
        [clock acceptUTCReference:1800000000.0 atMonotonicTime:m0
               uncertaintySeconds:0.005 source:TX500TimeTrustStateNetwork stationCount:0];
        for (NSInteger slot = 0; slot < 3; slot++) {
            NSMutableArray *messages = [NSMutableArray array];
            for (NSInteger i = 0; i < (NSInteger)calls.count; i++) {
                float stationBias = (float)(i - 4) * 0.012f;
                NSString *text = [NSString stringWithFormat:@"CQ %@ FN31", calls[i]];
                TX500FT8Message *message = [TX500FT8Message messageWithRawText:text freqHz:1000 + i * 50
                    snrDb:-8 + i dt:stationBias slotDate:[NSDate dateWithTimeIntervalSince1970:1800000000 + slot * 15]
                    slotParity:slot % 2 myCall:@"EP2AES" myGrid:@"KM35"];
                [messages addObject:message];
            }
            [clock ingestFT8Messages:messages slotStart:[NSDate dateWithTimeIntervalSince1970:1800000000 + slot * 15]];
        }
        [clock resetForTestingAtUTC:1800000100.0 monotonicTime:clock.monotonicTime];
        for (NSInteger slot = 0; slot < 3; slot++) {
            NSMutableArray *messages = [NSMutableArray array];
            for (NSInteger i = 0; i < (NSInteger)calls.count; i++) {
                float stationBias = (float)(i - 4) * 0.012f;
                float commonError = 0.180f;
                if (i == (NSInteger)calls.count - 1) commonError = 1.50f; // malicious/mistimed outlier
                NSString *text = [NSString stringWithFormat:@"CQ %@ FN31", calls[i]];
                TX500FT8Message *message = [TX500FT8Message messageWithRawText:text freqHz:1000 + i * 50
                    snrDb:-8 + i dt:stationBias + commonError
                    slotDate:[NSDate dateWithTimeIntervalSince1970:1800000100 + slot * 15]
                    slotParity:slot % 2 myCall:@"EP2AES" myGrid:@"KM35"];
                [messages addObject:message];
            }
            [clock ingestFT8Messages:messages slotStart:[NSDate dateWithTimeIntervalSince1970:1800000100 + slot * 15]];
        }
        TX500TimeSnapshot *radio = clock.snapshot;
        Check(radio.trustState == TX500TimeTrustStateRadio && radio.radioStationCount >= 8,
              @"Three-slot FT8 consensus establishes radio-disciplined time");
        Check(radio.uncertaintySeconds < 0.35, @"Robust FT8 estimator rejects a large station outlier");

        TX500AudioClockTracker *audio = [[TX500AudioClockTracker alloc] initWithNominalSampleRate:12000.0];
        [audio observeSampleTime:0.0 hostTimeSeconds:10.0];
        for (NSInteger i = 1; i <= 300; i++) {
            [audio observeSampleTime:i * 1200.036 hostTimeSeconds:10.0 + i * 0.1];
        }
        Check(fabs(audio.rateErrorPPM - 30.0) < 5.0, @"USB audio sample-clock drift is estimated separately");
        Check(audio.uncertaintyPPM < 100.0, @"Audio rate uncertainty contracts with observations");

        Check(fabs(TX500ContinuousTimeForAudioHostTime(mach_absolute_time()) - clock.monotonicTime) < 0.1,
              @"Audio host timestamps map into continuous monotonic time");
        printf("PASS: disciplined UTC, slew safety, outlier gate, seven-day holdover, FT8 consensus, and audio-clock tracking\n");
    }
    return 0;
}
