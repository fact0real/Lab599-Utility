#import "TX500TimeDiscipline.h"
#import "TX500FT8Message.h"
#import <arpa/inet.h>
#import <float.h>
#import <mach/mach_time.h>
#import <math.h>
#import <netdb.h>
#import <os/lock.h>
#import <poll.h>
#import <sys/socket.h>
#import <unistd.h>

static NSString * const kClockPersistenceKey = @"TX500_DisciplinedClock_v1";
static NSString * const kStationPersistenceKey = @"TX500_FT8TimeBaselines_v1";
static const double kNTPToUnix = 2208988800.0;

static double Clamp(double value, double low, double high) {
    return fmax(low, fmin(high, value));
}

static double WrapPeriod(double value, double period) {
    return value - period * round(value / period);
}

static double TimebaseSeconds(uint64_t ticks) {
    static mach_timebase_info_data_t info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&info); });
    return (double)ticks * (double)info.numer / (double)info.denom / 1e9;
}

double TX500ContinuousTimeForAudioHostTime(uint64_t hostTime) {
    uint64_t absoluteNow = mach_absolute_time();
    double continuousNow = TimebaseSeconds(mach_continuous_time());
    double delta = hostTime >= absoluteNow ? TimebaseSeconds(hostTime - absoluteNow) :
                                            -TimebaseSeconds(absoluteNow - hostTime);
    return continuousNow + delta;
}

NSString *TX500TimeTrustStateName(TX500TimeTrustState state) {
    switch (state) {
        case TX500TimeTrustStateNetwork: return @"Network consensus";
        case TX500TimeTrustStateRadio: return @"FT8 radio discipline";
        case TX500TimeTrustStateHoldover: return @"Calibrated holdover";
        default: return @"Untrusted";
    }
}

@implementation TX500TimeSnapshot
- (BOOL)transmitAllowed {
    return self.trustState != TX500TimeTrustStateUntrusted &&
           isfinite(self.uncertaintySeconds) && self.uncertaintySeconds <= 1.0;
}
@end

@interface TX500DisciplinedClock () {
    os_unfair_lock _lock;
    double _anchorMonotonic;
    double _anchorUTC;
    double _frequencyError;
    double _slewRemaining;
    double _p00, _p01, _p11;
    double _lastNetworkMonotonic;
    double _lastRadioMonotonic;
    double _lastPersistMonotonic;
    NSInteger _radioStationCount;
    BOOL _criticalTimingActive;
    dispatch_source_t _networkTimer;
    dispatch_queue_t _networkQueue;
    NSMutableDictionary<NSString *, NSMutableDictionary *> *_stationBaselines;
    NSMutableArray<NSDictionary *> *_radioObservations;
    double _lastAppliedRadioSlot;
}
@end

@implementation TX500DisciplinedClock

+ (instancetype)sharedClock {
    static TX500DisciplinedClock *clock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ clock = [[self alloc] init]; });
    return clock;
}

- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _lock = OS_UNFAIR_LOCK_INIT;
    _anchorMonotonic = [self monotonicTime];
    _anchorUTC = NSDate.date.timeIntervalSince1970;
    _frequencyError = 0.0;
    // A fresh process has no evidence that the wall clock is FT8-safe. A
    // persisted calibration or a live network/radio consensus contracts this.
    _p00 = 2.5 * 2.5;
    _p01 = 0.0;
    _p11 = pow(25e-6, 2.0);
    _lastNetworkMonotonic = -DBL_MAX;
    _lastRadioMonotonic = -DBL_MAX;
    _lastPersistMonotonic = -DBL_MAX;
    _lastAppliedRadioSlot = -DBL_MAX;
    _networkQueue = dispatch_queue_create("com.lab599.utility.time-network", DISPATCH_QUEUE_SERIAL);
    NSDictionary *saved = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kClockPersistenceKey];
    if ([saved[@"savedWall"] isKindOfClass:NSNumber.class]) {
        double age = fmax(0.0, NSDate.date.timeIntervalSince1970 - [saved[@"savedWall"] doubleValue]);
        double savedOffset = [saved[@"offset"] doubleValue];
        double savedPPM = Clamp([saved[@"ppm"] doubleValue], -100.0, 100.0);
        double savedSigma = Clamp([saved[@"sigma"] doubleValue], 0.005, 30.0);
        _anchorUTC += savedOffset + savedPPM * 1e-6 * age;
        _frequencyError = savedPPM * 1e-6;
        double sigma = savedSigma + age * 8e-6;
        _p00 = sigma * sigma;
        _p11 = pow(8e-6, 2.0);
    }
    NSDictionary *stations = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kStationPersistenceKey];
    _stationBaselines = stations ? [stations mutableCopy] : [NSMutableDictionary dictionary];
    for (NSString *key in _stationBaselines.allKeys) {
        _stationBaselines[key] = [_stationBaselines[key] mutableCopy];
    }
    _radioObservations = [NSMutableArray array];
    return self;
}

- (double)monotonicTime { return TimebaseSeconds(mach_continuous_time()); }

- (void)advanceLockedTo:(double)monotonic {
    double dt = monotonic - _anchorMonotonic;
    if (!isfinite(dt) || dt <= 0.0) return;
    double maxSlewRate = 2000e-6;
    double slewRate = _slewRemaining == 0.0 ? 0.0 : copysign(fmin(maxSlewRate, fabs(_slewRemaining) / dt), _slewRemaining);
    double appliedSlew = slewRate * dt;
    if (fabs(appliedSlew) > fabs(_slewRemaining)) appliedSlew = _slewRemaining;
    _anchorUTC += dt * (1.0 + _frequencyError) + appliedSlew;
    _slewRemaining -= appliedSlew;
    if (fabs(_slewRemaining) < 1e-9) _slewRemaining = 0.0;

    // Constant-frequency Kalman prediction.  A small random walk permits
    // temperature-dependent crystal drift without erasing learned holdover.
    double oldP00 = _p00, oldP01 = _p01, oldP11 = _p11;
    double qRate = pow(0.015e-6, 2.0) * dt;
    _p00 = oldP00 + 2.0 * dt * oldP01 + dt * dt * oldP11 + 1e-10 * dt;
    _p01 = oldP01 + dt * oldP11;
    _p11 = oldP11 + qRate;
    _anchorMonotonic = monotonic;
}

- (NSTimeInterval)utcTimeInterval {
    return [self utcTimeIntervalForMonotonicTime:[self monotonicTime]];
}

- (NSTimeInterval)utcTimeIntervalForMonotonicTime:(double)monotonicTime {
    os_unfair_lock_lock(&_lock);
    double value;
    if (monotonicTime >= _anchorMonotonic) {
        [self advanceLockedTo:monotonicTime];
        value = _anchorUTC;
    } else {
        // Audio callbacks are decoded later, so they legitimately ask for UTC
        // at an earlier host timestamp. Slew is intentionally excluded here;
        // its maximum error over one slot is below 30 ms and is represented in
        // the clock uncertainty.
        value = _anchorUTC + (monotonicTime - _anchorMonotonic) * (1.0 + _frequencyError);
    }
    os_unfair_lock_unlock(&_lock);
    return value;
}

- (NSDate *)utcDate { return [NSDate dateWithTimeIntervalSince1970:self.utcTimeInterval]; }

- (TX500TimeTrustState)trustStateLockedAt:(double)now {
    double sigma = sqrt(fmax(_p00, 0.0)) + fabs(_slewRemaining);
    if (now - _lastNetworkMonotonic <= 6.0 * 3600.0) return TX500TimeTrustStateNetwork;
    if (now - _lastRadioMonotonic <= 10.0 * 60.0) return TX500TimeTrustStateRadio;
    if (sigma <= 2.0) return TX500TimeTrustStateHoldover;
    return TX500TimeTrustStateUntrusted;
}

- (TX500TimeSnapshot *)snapshot {
    double now = [self monotonicTime];
    os_unfair_lock_lock(&_lock);
    [self advanceLockedTo:now];
    TX500TimeSnapshot *snapshot = [TX500TimeSnapshot new];
    snapshot.date = [NSDate dateWithTimeIntervalSince1970:_anchorUTC];
    snapshot.trustState = [self trustStateLockedAt:now];
    snapshot.offsetFromSystemSeconds = _anchorUTC - NSDate.date.timeIntervalSince1970;
    snapshot.frequencyErrorPPM = _frequencyError * 1e6;
    snapshot.uncertaintySeconds = sqrt(fmax(_p00, 0.0)) + fabs(_slewRemaining);
    snapshot.radioStationCount = _radioStationCount;
    snapshot.lastNetworkUpdate = isfinite(_lastNetworkMonotonic) && _lastNetworkMonotonic > 0 ?
        [NSDate dateWithTimeIntervalSince1970:_anchorUTC - (now - _lastNetworkMonotonic)] : nil;
    snapshot.lastRadioUpdate = isfinite(_lastRadioMonotonic) && _lastRadioMonotonic > 0 ?
        [NSDate dateWithTimeIntervalSince1970:_anchorUTC - (now - _lastRadioMonotonic)] : nil;
    snapshot.sourceDescription = TX500TimeTrustStateName(snapshot.trustState);
    os_unfair_lock_unlock(&_lock);
    return snapshot;
}

- (void)setCriticalTimingActive:(BOOL)active {
    os_unfair_lock_lock(&_lock);
    _criticalTimingActive = active;
    os_unfair_lock_unlock(&_lock);
}

- (void)persistLockedAt:(double)now {
    if (now - _lastPersistMonotonic < 30.0) return;
    _lastPersistMonotonic = now;
    NSDictionary *state = @{
        @"savedWall": @(NSDate.date.timeIntervalSince1970),
        @"offset": @(_anchorUTC - NSDate.date.timeIntervalSince1970),
        @"ppm": @(_frequencyError * 1e6),
        @"sigma": @(sqrt(fmax(_p00, 0.0)) + fabs(_slewRemaining))
    };
    [[NSUserDefaults standardUserDefaults] setObject:state forKey:kClockPersistenceKey];
}

- (BOOL)acceptUTCReference:(NSTimeInterval)referenceUTC
          atMonotonicTime:(double)sampleMonotonicTime
        uncertaintySeconds:(double)uncertainty
                    source:(TX500TimeTrustState)source
             stationCount:(NSInteger)stationCount {
    if (!isfinite(referenceUTC) || !isfinite(sampleMonotonicTime) ||
        !isfinite(uncertainty) || uncertainty <= 0.0 || uncertainty > 10.0) return NO;
    os_unfair_lock_lock(&_lock);
    [self advanceLockedTo:sampleMonotonicTime];
    double innovation = referenceUTC - _anchorUTC;
    double gate = source == TX500TimeTrustStateNetwork ? 5.0 : 2.5;
    if (fabs(innovation) > gate) {
        os_unfair_lock_unlock(&_lock);
        return NO;
    }
    double r = uncertainty * uncertainty;
    double s = _p00 + r;
    double k0 = _p00 / s;
    double k1 = _p01 / s;
    double phase = k0 * innovation;
    _frequencyError = Clamp(_frequencyError + k1 * innovation, -100e-6, 100e-6);
    double p00 = (1.0 - k0) * _p00;
    double p01 = (1.0 - k0) * _p01;
    double p11 = _p11 - k1 * _p01;
    _p00 = fmax(p00, 1e-8);
    _p01 = p01;
    _p11 = fmax(p11, pow(0.02e-6, 2.0));

    // A safe idle clock may rebase immediately. During monitoring/TX all phase
    // changes are rate-limited, keeping UTC strictly monotonic across a slot.
    if (!_criticalTimingActive && fabs(phase) > 0.050) _anchorUTC += phase;
    else _slewRemaining += phase;
    if (source == TX500TimeTrustStateNetwork) _lastNetworkMonotonic = sampleMonotonicTime;
    if (source == TX500TimeTrustStateRadio) {
        _lastRadioMonotonic = sampleMonotonicTime;
        _radioStationCount = stationCount;
    }
    [self persistLockedAt:sampleMonotonicTime];
    os_unfair_lock_unlock(&_lock);
    return YES;
}

static double WeightedMedian(NSArray<NSDictionary *> *values, NSString *valueKey) {
    NSArray *sorted = [values sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[valueKey] compare:b[valueKey]];
    }];
    double total = 0.0;
    for (NSDictionary *item in sorted) total += [item[@"weight"] doubleValue];
    double running = 0.0;
    for (NSDictionary *item in sorted) {
        running += [item[@"weight"] doubleValue];
        if (running >= total * 0.5) return [item[valueKey] doubleValue];
    }
    return [[sorted lastObject][valueKey] doubleValue];
}

- (void)ingestFT8Messages:(NSArray<TX500FT8Message *> *)messages slotStart:(NSDate *)slotStart {
    if (!slotStart || messages.count == 0) return;
    double slotEpoch = slotStart.timeIntervalSince1970;
    double nowMono = [self monotonicTime];
    TX500TimeSnapshot *snap = [self snapshot];
    BOOL calibrationTrusted = snap.trustState == TX500TimeTrustStateNetwork && snap.uncertaintySeconds < 0.100;
    NSMutableDictionary<NSString *, TX500FT8Message *> *onePerStation = [NSMutableDictionary dictionary];
    for (TX500FT8Message *message in messages) {
        NSString *call = message.callerCall.uppercaseString;
        if (call.length < 3 || !isfinite(message.timeSec) || fabs(message.timeSec) > 3.0) continue;
        TX500FT8Message *old = onePerStation[call];
        if (!old || message.snrDb > old.snrDb) onePerStation[call] = message;
    }
    if (onePerStation.count == 0) return;

    @synchronized (_stationBaselines) {
        for (NSString *call in onePerStation) {
            TX500FT8Message *message = onePerStation[call];
            NSString *stationKey = [NSString stringWithFormat:@"%@|%@", message.timingSourceIdentifier ?: @"default-audio", call];
            NSMutableDictionary *baseline = _stationBaselines[stationKey];
            if (calibrationTrusted) {
                if (!baseline) baseline = [NSMutableDictionary dictionary];
                double oldMean = [baseline[@"mean"] doubleValue];
                NSInteger count = [baseline[@"count"] integerValue];
                double residual = WrapPeriod(message.timeSec, [message.mode isEqualToString:@"FT4"] ? 7.5 : 15.0);
                if (count == 0) oldMean = residual;
                double delta = Clamp(residual - oldMean, -0.30, 0.30);
                double gain = 1.0 / (double)MIN(count + 1, 32);
                double mean = oldMean + gain * delta;
                double variance = count ? 0.9 * [baseline[@"variance"] doubleValue] + 0.1 * delta * delta : 0.04;
                baseline[@"mean"] = @(mean);
                baseline[@"variance"] = @(Clamp(variance, 0.0004, 1.0));
                baseline[@"count"] = @(count + 1);
                baseline[@"last"] = @(slotEpoch);
                _stationBaselines[stationKey] = baseline;
            }
            double baselineMean = [baseline[@"mean"] doubleValue];
            NSInteger baselineCount = [baseline[@"count"] integerValue];
            double snrWeight = Clamp((message.snrDb + 25.0) / 18.0, 0.10, 1.0);
            double historyWeight = baselineCount >= 3 ? 1.0 : 0.25;
            double timingSigma = message.timingUncertaintySec > 0.001 ? message.timingUncertaintySec : 0.080;
            double timingWeight = 1.0 / Clamp(timingSigma * timingSigma, 0.0004, 0.04);
            [_radioObservations addObject:@{
                @"call": call, @"slot": @(slotEpoch),
                @"value": @(WrapPeriod(message.timeSec - baselineMean, [message.mode isEqualToString:@"FT4"] ? 7.5 : 15.0)),
                @"weight": @(snrWeight * historyWeight * timingWeight)
            }];
        }
        NSIndexSet *expired = [_radioObservations indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
            (void)idx; (void)stop; return slotEpoch - [item[@"slot"] doubleValue] > 180.0;
        }];
        if (expired.count) [_radioObservations removeObjectsAtIndexes:expired];
        if (calibrationTrusted) {
            [[NSUserDefaults standardUserDefaults] setObject:_stationBaselines forKey:kStationPersistenceKey];
            return;
        }

        NSMutableSet *calls = [NSMutableSet set], *slots = [NSMutableSet set];
        for (NSDictionary *item in _radioObservations) {
            [calls addObject:item[@"call"]]; [slots addObject:item[@"slot"]];
        }
        if (calls.count < 8 || slots.count < 3 || slotEpoch <= _lastAppliedRadioSlot) return;
        double median = WeightedMedian(_radioObservations, @"value");
        NSMutableArray *deviations = [NSMutableArray arrayWithCapacity:_radioObservations.count];
        for (NSDictionary *item in _radioObservations) {
            [deviations addObject:@{@"deviation": @(fabs([item[@"value"] doubleValue] - median)), @"weight": item[@"weight"]}];
        }
        double mad = 1.4826 * WeightedMedian(deviations, @"deviation");
        if (!isfinite(mad) || mad > 0.35 || fabs(median) > 2.0) return;

        // Huber reweighting around the robust centre.
        double scale = fmax(mad, 0.04);
        NSMutableArray *inliers = [NSMutableArray array];
        for (NSDictionary *item in _radioObservations) {
            double residual = fabs([item[@"value"] doubleValue] - median);
            if (residual > 4.5 * scale) continue;
            double huber = residual <= 1.5 * scale ? 1.0 : (1.5 * scale / residual);
            [inliers addObject:@{@"value": item[@"value"], @"weight": @([item[@"weight"] doubleValue] * huber)}];
        }
        if (inliers.count < 8) return;
        double centre = WeightedMedian(inliers, @"value");
        double sigma = Clamp(scale / sqrt((double)calls.count) + 0.040, 0.050, 0.35);
        NSTimeInterval currentUTC = [self utcTimeIntervalForMonotonicTime:nowMono];
        if ([self acceptUTCReference:currentUTC - centre atMonotonicTime:nowMono
                  uncertaintySeconds:sigma source:TX500TimeTrustStateRadio stationCount:calls.count]) {
            _lastAppliedRadioSlot = slotEpoch;
        }
    }
}

typedef struct { double referenceUTC, monotonic, uncertainty, offset, delay; } NTPMeasurement;

static uint32_t ReadBE32(const uint8_t *p) {
    uint32_t v; memcpy(&v, p, sizeof(v)); return ntohl(v);
}

static double DecodeNTP(const uint8_t *p) {
    return (double)ReadBE32(p) - kNTPToUnix + (double)ReadBE32(p + 4) / 4294967296.0;
}

static void EncodeNTP(uint8_t *p, double unixTime) {
    double ntp = unixTime + kNTPToUnix;
    uint32_t sec = htonl((uint32_t)floor(ntp));
    uint32_t frac = htonl((uint32_t)((ntp - floor(ntp)) * 4294967296.0));
    memcpy(p, &sec, 4); memcpy(p + 4, &frac, 4);
}

- (BOOL)queryNTPServer:(NSString *)server measurement:(NTPMeasurement *)outMeasurement {
    struct addrinfo hints = {0}, *addresses = NULL;
    hints.ai_socktype = SOCK_DGRAM; hints.ai_family = AF_UNSPEC;
    if (getaddrinfo(server.UTF8String, "123", &hints, &addresses) != 0) return NO;
    BOOL success = NO;
    for (struct addrinfo *address = addresses; address && !success; address = address->ai_next) {
        int fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, address->ai_addr, address->ai_addrlen) != 0) { close(fd); continue; }
        uint8_t request[48] = {0}, response[48] = {0};
        request[0] = 0x23; // LI=0, NTPv4, client
        double t1Wall = NSDate.date.timeIntervalSince1970;
        double t1Mono = [self monotonicTime];
        EncodeNTP(request + 40, t1Wall);
        ssize_t sent = send(fd, request, sizeof(request), 0);
        struct pollfd pollItem = {.fd = fd, .events = POLLIN};
        int ready = sent == sizeof(request) ? poll(&pollItem, 1, 1400) : 0;
        ssize_t received = ready > 0 ? recv(fd, response, sizeof(response), 0) : -1;
        double t4Mono = [self monotonicTime];
        double t4Wall = t1Wall + (t4Mono - t1Mono);
        close(fd);
        if (received < 48 || memcmp(response + 24, request + 40, 8) != 0) continue;
        int leap = response[0] >> 6, version = (response[0] >> 3) & 7, mode = response[0] & 7;
        int stratum = response[1];
        double rootDispersion = (double)ReadBE32(response + 8) / 65536.0;
        if (leap == 3 || version < 3 || mode != 4 || stratum < 1 || stratum > 15 || rootDispersion > 2.0) continue;
        double t2 = DecodeNTP(response + 32), t3 = DecodeNTP(response + 40);
        if (!isfinite(t2) || !isfinite(t3) || t3 < t2) continue;
        double delay = (t4Wall - t1Wall) - (t3 - t2);
        double offset = ((t2 - t1Wall) + (t3 - t4Wall)) * 0.5;
        if (delay < -0.010 || delay > 2.0 || fabs(offset) > 5.0) continue;
        outMeasurement->referenceUTC = t4Wall + offset;
        outMeasurement->monotonic = t4Mono;
        outMeasurement->uncertainty = Clamp(fmax(delay, 0.0) * 0.5 + rootDispersion + 0.002, 0.003, 1.0);
        outMeasurement->offset = offset;
        outMeasurement->delay = delay;
        success = YES;
    }
    freeaddrinfo(addresses);
    return success;
}

- (BOOL)queryHTTPSTimeURL:(NSURL *)url measurement:(NTPMeasurement *)outMeasurement {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
        cachePolicy:NSURLRequestReloadIgnoringLocalAndRemoteCacheData timeoutInterval:3.0];
    request.HTTPMethod = @"HEAD";
    [request setValue:@"no-cache" forHTTPHeaderField:@"Cache-Control"];
    double m1 = [self monotonicTime];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSHTTPURLResponse *httpResponse = nil;
    __block NSError *taskError = nil;
    NSURLSessionDataTask *task = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            (void)data;
            if ([response isKindOfClass:NSHTTPURLResponse.class]) httpResponse = (NSHTTPURLResponse *)response;
            taskError = error;
            dispatch_semaphore_signal(done);
        }];
    [task resume];
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC)) != 0) {
        [task cancel]; return NO;
    }
    double m4 = [self monotonicTime];
    if (taskError || httpResponse.statusCode < 200 || httpResponse.statusCode >= 500) return NO;
    NSString *dateValue = nil;
    for (id key in httpResponse.allHeaderFields) {
        if ([[key description] caseInsensitiveCompare:@"Date"] == NSOrderedSame) {
            dateValue = [httpResponse.allHeaderFields[key] description]; break;
        }
    }
    if (!dateValue.length) return NO;
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss 'GMT'";
    NSDate *serverDate = [formatter dateFromString:dateValue];
    if (!serverDate) return NO;
    double rtt = m4 - m1;
    if (!isfinite(rtt) || rtt < 0.0 || rtt > 3.5) return NO;
    // HTTP Date has one-second granularity. Its midpoint plus half the RTT is
    // the least-biased estimate at receipt; quantization dominates sigma.
    outMeasurement->referenceUTC = serverDate.timeIntervalSince1970 + 0.5 + rtt * 0.5;
    outMeasurement->monotonic = m4;
    outMeasurement->uncertainty = Clamp(0.5 + rtt * 0.5, 0.50, 2.0);
    outMeasurement->offset = outMeasurement->referenceUTC - [self utcTimeIntervalForMonotonicTime:m4];
    outMeasurement->delay = rtt;
    return fabs(outMeasurement->offset) <= 5.0;
}

- (void)synchronizeNetworkNowWithCompletion:(void (^)(BOOL, NSString *))completion {
    dispatch_async(_networkQueue, ^{
        NSArray<NSString *> *servers = @[@"time.cloudflare.com", @"time.apple.com", @"time.nist.gov"];
        NSMutableArray<NSDictionary *> *samples = [NSMutableArray array];
        for (NSString *server in servers) {
            NTPMeasurement measurement;
            if ([self queryNTPServer:server measurement:&measurement]) {
                double local = [self utcTimeIntervalForMonotonicTime:measurement.monotonic];
                [samples addObject:@{@"server": server, @"value": @(measurement.referenceUTC - local),
                    @"weight": @(1.0 / (measurement.uncertainty * measurement.uncertainty)),
                    @"mono": @(measurement.monotonic), @"reference": @(measurement.referenceUTC),
                    @"sigma": @(measurement.uncertainty), @"delay": @(measurement.delay)}];
            }
        }
        BOOL usedHTTPSFallback = samples.count < 2;
        if (usedHTTPSFallback) {
            NSArray<NSURL *> *urls = @[
                [NSURL URLWithString:@"https://www.google.com/generate_204"],
                [NSURL URLWithString:@"https://cp.cloudflare.com/generate_204"],
                [NSURL URLWithString:@"https://www.microsoft.com/favicon.ico"]
            ];
            for (NSURL *url in urls) {
                NTPMeasurement measurement;
                if ([self queryHTTPSTimeURL:url measurement:&measurement]) {
                    [samples addObject:@{@"server": url.host ?: @"HTTPS", @"value": @(measurement.offset),
                        @"weight": @(1.0 / (measurement.uncertainty * measurement.uncertainty)),
                        @"mono": @(measurement.monotonic), @"reference": @(measurement.referenceUTC),
                        @"sigma": @(measurement.uncertainty), @"delay": @(measurement.delay), @"https": @YES}];
                }
            }
        }
        BOOL accepted = NO;
        NSString *detail;
        if (samples.count >= 2) {
            double median = WeightedMedian(samples, @"value");
            NSMutableArray *inliers = [NSMutableArray array];
            for (NSDictionary *sample in samples) {
                double agreementWindow = usedHTTPSFallback ? 1.10 : 0.100;
                if (fabs([sample[@"value"] doubleValue] - median) <= agreementWindow) [inliers addObject:sample];
            }
            if (inliers.count >= 2) {
                NSDictionary *best = [inliers sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                    return [a[@"sigma"] compare:b[@"sigma"]];
                }].firstObject;
                double commonMono = [best[@"mono"] doubleValue];
                double combinedOffset = WeightedMedian(inliers, @"value");
                double localAtCommon = [self utcTimeIntervalForMonotonicTime:commonMono];
                double sigma = fmax([best[@"sigma"] doubleValue], 0.005);
                if (usedHTTPSFallback) {
                    NSMutableArray *spreadValues = [NSMutableArray arrayWithCapacity:inliers.count];
                    for (NSDictionary *sample in inliers) {
                        [spreadValues addObject:@{@"spread": @(fabs([sample[@"value"] doubleValue] - combinedOffset)),
                                                  @"weight": sample[@"weight"]}];
                    }
                    double robustSpread = 1.4826 * WeightedMedian(spreadValues, @"spread");
                    sigma = Clamp(sigma / sqrt((double)inliers.count) + robustSpread, 0.50, 1.50);
                }
                accepted = [self acceptUTCReference:localAtCommon + combinedOffset atMonotonicTime:commonMono
                                    uncertaintySeconds:sigma source:TX500TimeTrustStateNetwork stationCount:0];
                detail = [NSString stringWithFormat:@"%lu time sources agreed%@; offset %+.3f s, uncertainty %.3f s.",
                    (unsigned long)inliers.count, usedHTTPSFallback ? @" (TLS/HTTPS fallback active)" : @" via NTP",
                    combinedOffset, sigma];
            } else detail = usedHTTPSFallback ?
                @"Internet time sources responded but did not agree within the HTTPS safety window." :
                @"NTP sources responded but did not agree within 100 ms.";
        } else detail = [NSString stringWithFormat:@"Only %lu independent internet time source responded; at least two are required.", (unsigned long)samples.count];
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(accepted, detail); });
    });
}

- (void)startAutomaticNetworkSynchronization {
    @synchronized (self) {
        if (_networkTimer) return;
        _networkTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _networkQueue);
        dispatch_source_set_timer(_networkTimer, dispatch_time(DISPATCH_TIME_NOW, 15 * NSEC_PER_SEC),
                                  15 * 60 * NSEC_PER_SEC, 5 * NSEC_PER_SEC);
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(_networkTimer, ^{ [weakSelf synchronizeNetworkNowWithCompletion:nil]; });
        dispatch_resume(_networkTimer);
    }
}

- (void)stopAutomaticNetworkSynchronization {
    @synchronized (self) {
        if (_networkTimer) { dispatch_source_cancel(_networkTimer); _networkTimer = nil; }
    }
}

- (void)resetForTestingAtUTC:(NSTimeInterval)utc monotonicTime:(double)monotonic {
    os_unfair_lock_lock(&_lock);
    _anchorUTC = utc; _anchorMonotonic = monotonic; _frequencyError = 0.0; _slewRemaining = 0.0;
    _p00 = 0.75 * 0.75; _p01 = 0.0; _p11 = pow(25e-6, 2.0);
    _lastNetworkMonotonic = _lastRadioMonotonic = -DBL_MAX; _radioStationCount = 0;
    os_unfair_lock_unlock(&_lock);
    @synchronized (_stationBaselines) {
        [_radioObservations removeAllObjects];
        _lastAppliedRadioSlot = -DBL_MAX;
    }
}

@end

@interface TX500AudioClockTracker () { os_unfair_lock _lock; double _nominal, _lastSample, _lastHost, _rate, _variance; BOOL _hasLast; }
@end

@implementation TX500AudioClockTracker
- (instancetype)initWithNominalSampleRate:(double)sampleRate {
    self = [super init]; if (self) { _lock = OS_UNFAIR_LOCK_INIT; _nominal = sampleRate; _rate = sampleRate; _variance = pow(100.0, 2.0); } return self;
}
- (void)observeSampleTime:(double)sampleTime hostTimeSeconds:(double)hostTime {
    if (!isfinite(sampleTime) || !isfinite(hostTime)) return;
    os_unfair_lock_lock(&_lock);
    if (_hasLast) {
        double dt = hostTime - _lastHost, ds = sampleTime - _lastSample;
        if (dt >= 0.050 && dt <= 2.0 && ds > 0.0) {
            double observed = ds / dt;
            double ppm = (observed / _nominal - 1.0) * 1e6;
            if (fabs(ppm) < 2000.0) {
                double residual = observed - _rate;
                double alpha = 0.02;
                _rate += alpha * Clamp(residual, -_nominal * 200e-6, _nominal * 200e-6);
                _variance = (1.0 - alpha) * _variance + alpha * pow(residual / _nominal * 1e6, 2.0);
            }
        }
    }
    _lastSample = sampleTime; _lastHost = hostTime; _hasLast = YES;
    os_unfair_lock_unlock(&_lock);
}
- (double)effectiveSampleRate { os_unfair_lock_lock(&_lock); double v = _rate; os_unfair_lock_unlock(&_lock); return v; }
- (double)rateErrorPPM { os_unfair_lock_lock(&_lock); double v = (_rate / _nominal - 1.0) * 1e6; os_unfair_lock_unlock(&_lock); return v; }
- (double)uncertaintyPPM { os_unfair_lock_lock(&_lock); double v = sqrt(fmax(_variance, 0.0)); os_unfair_lock_unlock(&_lock); return v; }
- (void)reset { os_unfair_lock_lock(&_lock); _hasLast = NO; _rate = _nominal; _variance = pow(100.0, 2.0); os_unfair_lock_unlock(&_lock); }
@end
