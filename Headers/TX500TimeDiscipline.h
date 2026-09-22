#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class TX500FT8Message;

typedef NS_ENUM(NSInteger, TX500TimeTrustState) {
    TX500TimeTrustStateUntrusted = 0,
    TX500TimeTrustStateHoldover,
    TX500TimeTrustStateRadio,
    TX500TimeTrustStateNetwork
};

FOUNDATION_EXPORT NSString *TX500TimeTrustStateName(TX500TimeTrustState state);

@interface TX500TimeSnapshot : NSObject
@property(nonatomic, strong) NSDate *date;
@property(nonatomic) TX500TimeTrustState trustState;
@property(nonatomic) double offsetFromSystemSeconds;
@property(nonatomic) double frequencyErrorPPM;
@property(nonatomic) double uncertaintySeconds;
@property(nonatomic) NSInteger radioStationCount;
@property(nonatomic, strong, nullable) NSDate *lastNetworkUpdate;
@property(nonatomic, strong, nullable) NSDate *lastRadioUpdate;
@property(nonatomic, copy) NSString *sourceDescription;
@property(nonatomic, readonly) BOOL transmitAllowed;
@end

// A process-local UTC clock anchored to mach_continuous_time.  It never follows
// wall-clock jumps while critical FT8 timing is active.  Measurements update a
// two-state phase/frequency filter and are slewed into the published clock.
@interface TX500DisciplinedClock : NSObject
+ (instancetype)sharedClock;
- (double)monotonicTime;
- (NSTimeInterval)utcTimeInterval;
- (NSTimeInterval)utcTimeIntervalForMonotonicTime:(double)monotonicTime;
- (NSDate *)utcDate;
- (TX500TimeSnapshot *)snapshot;
- (void)setCriticalTimingActive:(BOOL)active;

// referenceUTC is the best UTC estimate at sampleMonotonicTime.
- (BOOL)acceptUTCReference:(NSTimeInterval)referenceUTC
          atMonotonicTime:(double)sampleMonotonicTime
        uncertaintySeconds:(double)uncertainty
                    source:(TX500TimeTrustState)source
             stationCount:(NSInteger)stationCount;

// Uses CRC-valid decoder output to learn station baselines while online and to
// form a robust, multi-slot radio consensus while offline.
- (void)ingestFT8Messages:(NSArray<TX500FT8Message *> *)messages
                 slotStart:(NSDate *)slotStart;

// Starts a multi-source RFC 5905/SNTP sampler. Safe to call more than once.
- (void)startAutomaticNetworkSynchronization;
- (void)stopAutomaticNetworkSynchronization;
- (void)synchronizeNetworkNowWithCompletion:(void (^ _Nullable)(BOOL success, NSString *detail))completion;

// Test and diagnostic hooks. They do not change the host's system clock.
- (void)resetForTestingAtUTC:(NSTimeInterval)utc monotonicTime:(double)monotonic;
@end

// Separately estimates the effective USB audio sample clock, so audio drift is
// not mistaken for UTC drift.
@interface TX500AudioClockTracker : NSObject
@property(nonatomic, readonly) double effectiveSampleRate;
@property(nonatomic, readonly) double rateErrorPPM;
@property(nonatomic, readonly) double uncertaintyPPM;
- (instancetype)initWithNominalSampleRate:(double)sampleRate;
- (void)observeSampleTime:(double)sampleTime hostTimeSeconds:(double)hostTime;
- (void)reset;
@end

// Converts an AudioTimeStamp mach_absolute_time value into the continuous clock
// domain used by TX500DisciplinedClock.
FOUNDATION_EXPORT double TX500ContinuousTimeForAudioHostTime(uint64_t hostTime);

NS_ASSUME_NONNULL_END
