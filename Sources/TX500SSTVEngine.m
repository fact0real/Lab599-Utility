// SPDX-License-Identifier: GPL-3.0-or-later
#import "TX500SSTVEngine.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/HostTime.h>
#include "sstv1/sstv1.h"
#include "sstv1/wav.h"

NSString *TX500WAVReasonInEnglish(const char *reason) {
    NSString *r = reason ? @(reason) : @"";
    NSDictionary<NSString *, NSString *> *t = @{
        @"no es pot obrir el fitxer": @"the file cannot be opened",
        @"no és un fitxer RIFF/WAVE": @"it is not a RIFF/WAVE file",
        @"falta el tros fmt o data": @"its format or data part is missing, or too short",
        @"el fitxer no té cap mostra d'àudio": @"it has no audio samples",
    };
    if (t[r]) return t[r];
    if ([r hasPrefix:@"format no suportat"])
        return [@"a format this reader does not take" stringByAppendingString:[r substringFromIndex:@"format no suportat".length]];
    return @"it could not be read";
}

static NSError *SSTVError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"TX500SSTVErrorDomain" code:code userInfo:@{NSLocalizedDescriptionKey: message}];
}

#pragma mark - Notice

@implementation TX500SSTVNotice
- (instancetype)initWithKind:(TX500SSTVNoticeKind)kind time:(double)time modeName:(NSString *)modeName
                    offsetHz:(double)offsetHz text:(NSString *)text {
    if ((self = [super init])) {
        _kind = kind; _time = time; _modeName = [modeName copy]; _offsetHz = offsetHz; _text = [text copy];
    }
    return self;
}
@end

#pragma mark - Recording

@implementation TX500SSTVRecording
- (instancetype)initWithSamples:(NSData *)samples sampleRate:(double)rate startTime:(double)start {
    if ((self = [super init])) { _samples = [samples copy]; _sampleRate = rate; _startTime = start; _modeKey = @""; _endUTC = [NSDate date]; }
    return self;
}
- (double)duration { return self.sampleRate > 0 ? (double)(self.samples.length / 2) / self.sampleRate : 0.0; }
- (NSArray<NSArray<NSNumber *> *> *)timeAnchors { return _timeAnchors ?: @[]; }
- (NSDate *)dateAtSample:(double)k {
    NSArray<NSNumber *> *best = nil;
    for (NSArray<NSNumber *> *a in self.timeAnchors) { if (a[0].doubleValue <= k) best = a; else break; }
    if (best && self.sampleRate > 0)
        return [NSDate dateWithTimeIntervalSince1970:best[1].doubleValue + (k - best[0].doubleValue) / self.sampleRate];
    return [self.endUTC dateByAddingTimeInterval:-(self.duration - (self.sampleRate > 0 ? k / self.sampleRate : 0.0))];
}
- (NSDate *)startUTC { return [self dateAtSample:0]; }
- (NSUInteger)byteSize { return self.samples.length; }

static void SSTVPut32(NSMutableData *d, uint32_t v) { uint8_t b[4] = { v & 255, (v >> 8) & 255, (v >> 16) & 255, (v >> 24) & 255 }; [d appendBytes:b length:4]; }
static void SSTVPut16(NSMutableData *d, uint16_t v) { uint8_t b[2] = { v & 255, (v >> 8) & 255 }; [d appendBytes:b length:2]; }

- (BOOL)writeWAVToURL:(NSURL *)url error:(NSError **)error {
    uint32_t bytes = (uint32_t)self.samples.length, rate = (uint32_t)llround(self.sampleRate);
    NSMutableData *d = [NSMutableData dataWithCapacity:44 + bytes];
    [d appendBytes:"RIFF" length:4]; SSTVPut32(d, 36 + bytes); [d appendBytes:"WAVE" length:4];
    [d appendBytes:"fmt " length:4]; SSTVPut32(d, 16); SSTVPut16(d, 1); SSTVPut16(d, 1); SSTVPut32(d, rate);
    SSTVPut32(d, rate * 2); SSTVPut16(d, 2); SSTVPut16(d, 16);
    [d appendBytes:"data" length:4]; SSTVPut32(d, bytes);
    const int16_t *s = self.samples.bytes;                      // little-endian on disk, as WAV wants
    for (NSUInteger i = 0; i < bytes / 2; i++) SSTVPut16(d, (uint16_t)s[i]);
    return [d writeToURL:url options:NSDataWritingAtomic error:error];
}

+ (nullable TX500SSTVRecording *)recordingFromWAVAtURL:(NSURL *)url error:(NSError **)error {
    wav_reader w;
    char err[256] = {0};
    if (wav_open(&w, url.fileSystemRepresentation, err, sizeof err) != 0) {
        if (error) *error = SSTVError(2, [NSString stringWithFormat:@"Cannot read %@: %@.", url.lastPathComponent, TX500WAVReasonInEnglish(err)]);
        return nil;
    }
    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)w.frames * 2];
    int16_t *o = out.mutableBytes;
    float buf[4096];
    size_t got, k = 0;
    while ((got = wav_read(&w, buf, 4096)) > 0)
        for (size_t i = 0; i < got && k < w.frames; i++) {
            double v = buf[i] * 32768.0;
            o[k++] = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : lrint(v));
        }
    double rate = w.rate;
    wav_close(&w);
    out.length = k * 2;
    return [[TX500SSTVRecording alloc] initWithSamples:out sampleRate:rate startTime:0];
}
@end

@implementation TX500SSTVRecordingSource {
    TX500SSTVRecording *_rec;
    volatile BOOL _stop;
}
- (instancetype)initWithRecording:(TX500SSTVRecording *)recording { if ((self = [super init])) _rec = recording; return self; }
- (double)sampleRate { return _rec.sampleRate; }
// the radio's audio decoded again is still a reception from the radio, and a file's is still practice;
// the screen offers Record QSO once per reception
- (BOOL)isLive { return !_rec.fromFile; }
- (NSArray<NSArray<NSNumber *> *> *)timeAnchors {
    return _rec.timeAnchors.count ? _rec.timeAnchors : @[@[@0, @(_rec.startUTC.timeIntervalSince1970)]];
}
- (NSString *)sourceName { return @"Recording"; }
- (BOOL)startDelivering:(void (^)(const float *, NSUInteger))deliver finished:(void (^)(void))finished error:(NSError **)error {
    _stop = NO;
    const int16_t *s = _rec.samples.bytes;
    NSUInteger n = _rec.samples.length / 2, blk = (NSUInteger)(0.25 * _rec.sampleRate + 0.5);
    float *buf = malloc(blk * sizeof(float));
    for (NSUInteger i = 0; buf && i < n && !_stop; i += blk) {
        NSUInteger k = MIN(blk, n - i);
        for (NSUInteger j = 0; j < k; j++) buf[j] = (float)(s[i + j] / 32768.0);
        deliver(buf, k);
    }
    free(buf);
    finished();
    return YES;
}
- (void)stop { _stop = YES; }
@end

#pragma mark - Picture

@implementation TX500SSTVPicture
- (instancetype)initWithModeKey:(NSString *)key modeName:(NSString *)name width:(NSInteger)w height:(NSInteger)h
                   rowsReceived:(NSInteger)rows complete:(BOOL)complete rgb:(NSData *)rgb endUTC:(NSDate *)end
                       offsetHz:(double)offsetHz slantPPM:(double)slant fromFile:(BOOL)fromFile sourceName:(NSString *)source {
    if ((self = [super init])) {
        _modeKey = [key copy]; _modeName = [name copy]; _width = w; _height = h; _rowsReceived = rows;
        _complete = complete; _rgb = [rgb copy]; _endUTC = [end copy]; _offsetHz = offsetHz; _slantPPM = slant;
        _fromFile = fromFile; _sourceName = [source copy];
    }
    return self;
}

static NSBitmapImageRep *SSTVBitmap(const uint8_t *rgb, NSInteger w, NSInteger h) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
                                                                 bitsPerSample:8 samplesPerPixel:3 hasAlpha:NO isPlanar:NO
                                                                colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w * 3
                                                                  bitsPerPixel:24];
    if (rep && rgb) memcpy(rep.bitmapData, rgb, (size_t)(w * h * 3));
    return rep;
}

- (NSBitmapImageRep *)bitmap { return SSTVBitmap(self.rgb.bytes, self.width, self.height); }

- (NSImage *)image {
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(self.width, self.height)];
    [img addRepresentation:[self bitmap]];
    return img;
}

- (BOOL)writePNGToURL:(NSURL *)url error:(NSError **)error {
    NSData *png = [[self bitmap] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
    if (!png) { if (error) *error = SSTVError(1, @"The picture could not be turned into a PNG."); return NO; }
    return [png writeToURL:url options:NSDataWritingAtomic error:error];
}
@end

#pragma mark - File source

@implementation TX500SSTVFileSource {
    NSURL *_url;
    double _rate;
    volatile BOOL _stop;
}
@synthesize sampleRate = _rate;

- (nullable instancetype)initWithURL:(NSURL *)url error:(NSError **)error {
    if ((self = [super init])) {
        wav_reader w;
        char err[256] = {0};
        if (wav_open(&w, url.fileSystemRepresentation, err, sizeof err) != 0) {
            if (error) *error = SSTVError(2, [NSString stringWithFormat:@"Cannot read %@: %@.", url.lastPathComponent, TX500WAVReasonInEnglish(err)]);
            return nil;
        }
        _rate = w.rate;
        wav_close(&w);
        _url = [url copy];
        _blockFrames = 0;
    }
    return self;
}

- (BOOL)isLive { return NO; }
- (NSString *)sourceName { return _url.lastPathComponent ?: @"WAV file"; }

- (BOOL)startDelivering:(void (^)(const float *, NSUInteger))deliver finished:(void (^)(void))finished error:(NSError **)error {
    wav_reader w;
    char err[256] = {0};
    if (wav_open(&w, _url.fileSystemRepresentation, err, sizeof err) != 0) {
        if (error) *error = SSTVError(2, [NSString stringWithFormat:@"Cannot read %@: %@.", _url.lastPathComponent, TX500WAVReasonInEnglish(err)]);
        return NO;
    }
    _stop = NO;
    NSUInteger blk = self.blockFrames ? self.blockFrames : (NSUInteger)(0.25 * _rate + 0.5);
    __weak TX500SSTVFileSource *weakSelf = self;
    void (^run)(void) = ^{
        wav_reader r = w;
        float *buf = malloc(blk * sizeof(float));
        size_t got;
        while (buf && (got = wav_read(&r, buf, blk)) > 0) {
            TX500SSTVFileSource *s = weakSelf;
            if (!s || s->_stop) break;
            deliver(buf, got);
        }
        free(buf);
        wav_close(&r);
        finished();
    };
    if (self.asynchronous) dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), run);
    else run();
    return YES;
}

- (void)stop { _stop = YES; }
@end

#pragma mark - Radio source

#define SSTV_RADIO_RATE 12000.0
#define SSTV_RADIO_BUFFERS 4
#define SSTV_RADIO_FRAMES 1200

@interface TX500SSTVRadioSource ()
@property (atomic, copy, nullable) NSString *inputFailure;
@property (nonatomic, copy, nullable) void (^deliver)(const float *, NSUInteger);
@property (nonatomic, copy, nullable) void (^finished)(void);
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation TX500SSTVRadioSource {
    NSString *_uid;
    NSString *_deviceName;
    BOOL _builtIn;
    AudioQueueRef _aq;
    AudioQueueBufferRef _buffers[SSTV_RADIO_BUFFERS];
    volatile BOOL _running;
    dispatch_source_t _aliveWatch;
    NSDate *_blockDate;       // the block being delivered: when it was captured (on the delivery queue)
}

// when the first sample of a buffer was captured, from the input's host time stamp
static NSDate *SSTVCaptureDate(const AudioTimeStamp *ts) {
    if (!ts || !(ts->mFlags & kAudioTimeStampHostTimeValid)) return [NSDate date];
    UInt64 now = AudioGetCurrentHostTime();
    double ago = now > ts->mHostTime ? (double)AudioConvertHostTimeToNanos(now - ts->mHostTime) / 1e9 : 0.0;
    return [NSDate dateWithTimeIntervalSinceNow:-ago];
}

static void SSTVRadioInput(void *user, AudioQueueRef aq, AudioQueueBufferRef buf, const AudioTimeStamp *ts,
                           UInt32 npackets, const AudioStreamPacketDescription *desc) {
    (void)desc;
    TX500SSTVRadioSource *s = (__bridge TX500SSTVRadioSource *)user;
    if (!s->_running) return;
    NSUInteger n = buf->mAudioDataByteSize / sizeof(float);
    if (npackets && n) {
        NSData *copy = [NSData dataWithBytes:buf->mAudioData length:n * sizeof(float)];
        NSDate *when = SSTVCaptureDate(ts);
        void (^deliver)(const float *, NSUInteger) = s.deliver;
        // decode off the audio thread, in order
        __weak TX500SSTVRadioSource *weak = s;
        dispatch_async(s.queue, ^{
            TX500SSTVRadioSource *src = weak;
            if (src) src->_blockDate = when;
            if (deliver) deliver(copy.bytes, copy.length / sizeof(float));
        });
    }
    AudioQueueEnqueueBuffer(aq, buf, 0, NULL);
}

- (nullable NSDate *)dateOfCurrentBlock { return _blockDate; }

// the input with that UID, if it is connected and has an input: its name, and whether it is built in
+ (nullable NSDictionary *)inputDeviceWithUID:(NSString *)uid {
    if (!uid.length) return nil;
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    CFStringRef cf = (__bridge CFStringRef)uid;
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof dev;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, sizeof cf, &cf, &size, &dev) != noErr || dev == kAudioObjectUnknown) return nil;
    AudioObjectPropertyAddress aliveAddress={kAudioDevicePropertyDeviceIsAlive,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
    UInt32 alive=0; size=sizeof alive;
    if(AudioObjectGetPropertyData(dev,&aliveAddress,0,NULL,&size,&alive)!=noErr || !alive) return nil;
    AudioObjectPropertyAddress streams = { kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain };
    UInt32 bytes = 0;
    if (AudioObjectGetPropertyDataSize(dev, &streams, 0, NULL, &bytes) != noErr || bytes == 0) return nil;
    CFStringRef name = NULL;
    AudioObjectPropertyAddress na = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    size = sizeof name;
    NSString *n = (AudioObjectGetPropertyData(dev, &na, 0, NULL, &size, &name) == noErr && name) ? (__bridge_transfer NSString *)name : uid;
    UInt32 transport = 0;
    AudioObjectPropertyAddress ta = { kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    size = sizeof transport;
    AudioObjectGetPropertyData(dev, &ta, 0, NULL, &size, &transport);
    return @{@"name": n, @"builtIn": @(transport == kAudioDeviceTransportTypeBuiltIn),
             @"virtual": @(transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate)};
}

+ (NSArray<NSDictionary *> *)inputDevices {
    AudioObjectPropertyAddress a = { kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    UInt32 bytes = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &bytes) != noErr || !bytes) return @[];
    NSMutableData *ids = [NSMutableData dataWithLength:bytes];
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &bytes, ids.mutableBytes) != noErr) return @[];
    NSMutableArray *out = [NSMutableArray array];
    const AudioObjectID *dev = ids.bytes;
    for (UInt32 i = 0; i < bytes / sizeof(AudioObjectID); i++) {
        CFStringRef uid = NULL;
        UInt32 size = sizeof uid;
        AudioObjectPropertyAddress ua = { kAudioDevicePropertyDeviceUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
        if (AudioObjectGetPropertyData(dev[i], &ua, 0, NULL, &size, &uid) != noErr || !uid) continue;
        NSString *u = (__bridge_transfer NSString *)uid;
        NSDictionary *d = [self inputDeviceWithUID:u];
        if (d) [out addObject:@{@"uid": u, @"name": d[@"name"], @"builtIn": d[@"builtIn"], @"virtual": d[@"virtual"]}];
    }
    return out;
}

- (instancetype)initWithDeviceUID:(nullable NSString *)uid {
    if ((self = [super init])) {
        // «» (what a saved profile holds when no input was chosen), spaces, "default" or not a string:
        // no input, said as such (N-seguretat-4)
        NSString *u = [uid isKindOfClass:NSString.class] ? [uid stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
        _uid = (!u.length || [u isEqualToString:@"default"]) ? nil : [u copy];
        _queue = dispatch_queue_create("lab599.sstv.radio", DISPATCH_QUEUE_SERIAL);
        NSDictionary *d = _uid ? [TX500SSTVRadioSource inputDeviceWithUID:_uid] : nil;
        _deviceName = [d[@"name"] copy];
        _builtIn = [d[@"builtIn"] boolValue];
    }
    return self;
}

- (double)sampleRate { return SSTV_RADIO_RATE; }
- (BOOL)isLive { return YES; }
- (nullable NSString *)deviceName { return _deviceName; }
- (BOOL)builtIn { return _builtIn; }
- (NSString *)sourceName {
    if (!_deviceName) return @"Radio audio";
    return _builtIn ? [NSString stringWithFormat:@"%@ (built in: it may be the Mac's own microphone)", _deviceName] : _deviceName;
}

- (BOOL)startDelivering:(void (^)(const float *, NSUInteger))deliver finished:(void (^)(void))finished error:(NSError **)error {
    if (_aq) return YES;
    // only the input the operator chose for the radio; never the system's default input, which may
    // be the Mac's microphone (SEG-2). Checked before anything of the audio is touched.
    if (!_uid) {
        if (error) *error = SSTVError(20, @"No radio input is chosen. Choose the radio's receive input in the Station screen: "
                                           "SSTV never listens to the system's default input, which may be the Mac's microphone.");
        return NO;
    }
    if (!_deviceName) {
        if (error) *error = SSTVError(21, @"The radio input chosen in the Station screen is not connected, or has no input.");
        return NO;
    }
    self.deliver = deliver;
    self.finished = finished;
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = SSTV_RADIO_RATE; f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = 4; f.mFramesPerPacket = 1; f.mBytesPerFrame = 4; f.mChannelsPerFrame = 1; f.mBitsPerChannel = 32;
    // an ordinary (shared) input queue: other screens may listen to the same device at the same time
    OSStatus st = AudioQueueNewInput(&f, SSTVRadioInput, (__bridge void *)self, NULL, NULL, 0, &_aq);
    if (st == noErr) {
        CFStringRef cf = (__bridge CFStringRef)_uid;
        st = AudioQueueSetProperty(_aq, kAudioQueueProperty_CurrentDevice, &cf, sizeof cf);
    }
    for (int i = 0; st == noErr && i < SSTV_RADIO_BUFFERS; i++) {
        st = AudioQueueAllocateBuffer(_aq, SSTV_RADIO_FRAMES * sizeof(float), &_buffers[i]);
        if (st == noErr) st = AudioQueueEnqueueBuffer(_aq, _buffers[i], 0, NULL);
    }
    _running = YES;
    if (st == noErr) st = AudioQueueStart(_aq, NULL);
    if (st != noErr) {
        _running = NO;
        if (_aq) { AudioQueueDispose(_aq, true); _aq = NULL; }
        if (error) *error = SSTVError(st, [NSString stringWithFormat:@"Cannot open the radio audio input (error %d). "
                                           "Check the station route and the microphone permission.", (int)st]);
        return NO;
    }
    self.inputFailure=nil;
    _aliveWatch=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self.queue);
    dispatch_source_set_timer(_aliveWatch,dispatch_time(DISPATCH_TIME_NOW,500*NSEC_PER_MSEC),500*NSEC_PER_MSEC,50*NSEC_PER_MSEC);
    __weak typeof(self) weakSelf=self;
    dispatch_source_set_event_handler(_aliveWatch, ^{
        typeof(self) self=weakSelf; if(!self || !self->_running) return;
        if(![TX500SSTVRadioSource inputDeviceWithUID:self->_uid]) {
            NSDateFormatter *utc=[NSDateFormatter new]; utc.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0]; utc.dateFormat=@"HH:mm:ss 'UTC'";
            self.inputFailure=[NSString stringWithFormat:@"Input %@ lost at %@. Listening stopped; reconnect it or select another input.",self->_deviceName ?: self->_uid,[utc stringFromDate:[NSDate date]]];
            [self stop];
        }
    });
    dispatch_resume(_aliveWatch);
    return YES;
}

- (void)stop {
    if(_aliveWatch) { dispatch_source_cancel(_aliveWatch); _aliveWatch=nil; }
    if (!_aq) return;
    _running = NO;
    AudioQueueStop(_aq, true);
    AudioQueueDispose(_aq, true);
    _aq = NULL;
    void (^finished)(void) = self.finished;
    self.finished = nil;
    dispatch_async(self.queue, ^{ if (finished) finished(); });
}

- (void)dealloc { [self stop]; }
@end

#pragma mark - Engine

@interface TX500SSTVEngine ()
@property (atomic, readwrite, copy, nullable) NSString *lastInputFailure;
@end

@implementation TX500SSTVEngine {
    NSLock *_lock;
    sstv_rx *_rx;
    double _fs;
    uint64_t _fed;
    double _nextProgress;
    int _seenImages;
    uint8_t *_partial;
    size_t _partialCap;
    BOOL _fromFile;
    NSString *_sourceName;
    uint64_t _gen;            // the run: blocks and ends from an earlier source are ignored
    double _rxBase;           // the receiver's time 0, in seconds of the input (it is renewed when settings change)
    uint64_t _lastPictureFed; // where the last picture ended, in samples of the input
    BOOL _settingsWaiting;
    sstv_rx_config _nextCfg;  // the settings to apply when no picture is being received
    NSMutableArray<NSArray<NSNumber *> *> *_anchors;   // @[input sample, seconds since 1970], in order
    int16_t *_ring;           // the last ringSeconds of input, so that each picture carries its audio
    size_t _ringCap;
    float *_q;                // the block, quantised to 16 bits, as the core sees it
    size_t _qCap;
}

- (instancetype)init {
    if ((self = [super init])) {
        _lock = [NSLock new];
        _callbackQueue = dispatch_get_main_queue();
        _progressInterval = 0.5;
        _fitSlant = YES;
        _ringSeconds = 300.0;
    }
    return self;
}

- (void)dealloc {
    if (_rx) sstv_rx_free(_rx);
    free(_partial);
    free(_ring);
    free(_q);
}

- (void)call:(dispatch_block_t)block {
    if (self.callbackQueue) dispatch_async(self.callbackQueue, block);
    else block();
}

- (void)fillConfig:(sstv_rx_config *)cfg {
    sstv_rx_config_default(cfg);
    cfg->forced_mode = (sstv_mode_id)self.modeChoice;          // the enums share their order
    cfg->levels = self.colourScale == TX500SSTVColourScaleFull ? SSTV_LEVELS_FULL : SSTV_LEVELS_STUDIO;
    cfg->scottie = self.scottieLayout == TX500SSTVScottieLayoutBarber ? SCOTTIE_LAYOUT_BARBER :
                   self.scottieLayout == TX500SSTVScottieLayoutOpen ? SCOTTIE_LAYOUT_OPEN : SCOTTIE_LAYOUT_AUTO;
    cfg->keep_buffers = 0;         // the screen stores each picture at once; nothing waits to be redrawn
    cfg->fit_slant = self.fitSlant ? 1 : 0;
    cfg->preset_slant_ppm = self.slantPPM;
}

- (BOOL)startWithSource:(id<TX500SSTVAudioSource>)source error:(NSError **)error {
    [self stop];
    self.lastInputFailure=nil;
    sstv_rx_config cfg;
    [self fillConfig:&cfg];
    NSArray *given = [source respondsToSelector:@selector(timeAnchors)] ? [source timeAnchors] : nil;
    [_lock lock];
    uint64_t gen = ++_gen;
    // the last minutes stay until the app quits, also after Listen stops: a start that
    // opens nothing gives them back as they were; only a start that opens the input writes them anew
    uint64_t oldFed = _fed; double oldFs = _fs; BOOL oldFromFile = _fromFile;
    NSString *oldName = _sourceName; NSMutableArray *oldAnchors = _anchors;
    int16_t *oldRing = _ring; size_t oldCap = _ringCap;
    _rx = sstv_rx_new(source.sampleRate, &cfg);
    _fs = source.sampleRate; _fed = 0; _nextProgress = 0.0; _seenImages = 0;
    _rxBase = 0.0; _lastPictureFed = 0; _settingsWaiting = NO;
    _fromFile = !source.isLive; _sourceName = [source.sourceName copy];
    _anchors = given.count ? [given mutableCopy] : [NSMutableArray arrayWithObject:@[@0, @([NSDate date].timeIntervalSince1970)]];
    size_t cap = (size_t)(fmax(self.ringSeconds, 1.0) * source.sampleRate);
    if (cap != _ringCap) { _ring = calloc(cap, sizeof(int16_t)); _ringCap = _ring ? cap : 0; }
    if (_rx) { _source = source; _running = YES; }               // set inside the lock (SEG-13)
    [_lock unlock];
    void (^giveBack)(void) = ^{
        // with the lock held
        if (self->_ring != oldRing) { free(self->_ring); self->_ring = oldRing; self->_ringCap = oldCap; }
        self->_fed = oldFed; self->_fs = oldFs; self->_fromFile = oldFromFile; self->_sourceName = oldName; self->_anchors = oldAnchors;
    };
    if (!_rx) {
        [_lock lock];
        if (_gen == gen) giveBack(); else if (_ring != oldRing) free(oldRing);
        [_lock unlock];
        if (error) *error = SSTVError(3, [NSString stringWithFormat:@"The SSTV receiver cannot work at %.0f Hz.", source.sampleRate]);
        return NO;
    }
    __weak TX500SSTVEngine *weakSelf = self;
    BOOL ok = [source startDelivering:^(const float *samples, NSUInteger count) {
        [weakSelf feedSamples:samples count:count generation:gen];
    } finished:^{
        [weakSelf finishInputOfGeneration:gen];
    } error:error];
    [_lock lock];
    if (!ok) {
        // nothing was opened: the receiver goes too (SEG-14), and the last minutes come back
        if (_gen == gen) {
            _running = NO;
            if (_rx) { sstv_rx_free(_rx); _rx = NULL; }
            _source = nil;
            giveBack();
        } else if (_ring != oldRing) free(oldRing);
    } else if (_ring != oldRing) free(oldRing);                  // the input is open: the old minutes give way
    [_lock unlock];
    return ok;
}

- (NSUInteger)lastMinutesByteSize {
    [_lock lock];
    NSUInteger n = (NSUInteger)((_fed < _ringCap ? _fed : _ringCap) * 2);
    [_lock unlock];
    return n;
}

- (nullable NSDate *)lastMinutesEndUTC {
    [_lock lock];
    NSDate *d = (_fed > 0 && _fs > 0) ? [self dateAtSampleLocked:_fed] : nil;
    [_lock unlock];
    return d;
}

- (void)applySettings {
    sstv_rx_config cfg;
    [self fillConfig:&cfg];
    [_lock lock];
    _nextCfg = cfg;
    if (_rx && _running) _settingsWaiting = YES;                // applied at the next block with no picture
    [_lock unlock];
}

- (BOOL)receiving {
    [_lock lock];
    BOOL r = _rx && _running && sstv_rx_receiving(_rx, NULL, NULL, NULL);
    [_lock unlock];
    return r;
}

- (BOOL)settingsWaiting {
    [_lock lock];
    BOOL w = _settingsWaiting;
    [_lock unlock];
    return w;
}

#pragma mark - the clock

// with the lock held: when input sample k was heard
- (double)timeAtSampleLocked:(uint64_t)k {
    NSArray<NSNumber *> *best = _anchors.firstObject;
    for (NSArray<NSNumber *> *a in _anchors) { if (a[0].unsignedLongLongValue <= k) best = a; else break; }
    if (!best || _fs <= 0) return [NSDate date].timeIntervalSince1970;
    return best[1].doubleValue + ((double)k - best[0].doubleValue) / _fs;
}

- (NSDate *)dateAtSampleLocked:(uint64_t)k { return [NSDate dateWithTimeIntervalSince1970:[self timeAtSampleLocked:k]]; }

// with the lock held: a live block says when it was captured; when that is more than a quarter of a
// second away from the count of samples (a sleep, a gap), the clock is anchored to it again
- (void)anchorBlockLocked {
    id<TX500SSTVAudioSource> src = _source;
    if (![src respondsToSelector:@selector(dateOfCurrentBlock)]) return;
    NSDate *d = [src dateOfCurrentBlock];
    if (!d) return;
    double t = d.timeIntervalSince1970;
    if (fabs(t - [self timeAtSampleLocked:_fed]) <= 0.25) return;
    if (_anchors.count && _anchors.lastObject[0].unsignedLongLongValue == _fed) [_anchors removeLastObject];
    [_anchors addObject:@[@(_fed), @(t)]];
    // the anchors older than the ring are not needed, but the one the ring's oldest sample uses is
    uint64_t oldest = _fed > _ringCap ? _fed - _ringCap : 0;
    while (_anchors.count > 1 && _anchors[1][0].unsignedLongLongValue <= oldest) [_anchors removeObjectAtIndex:0];
}

// with the lock held: the receiver is renewed with the waiting settings, and the last seconds since
// the last picture are decoded again with them (a header that was arriving is not lost)
- (void)swapReceiverLocked {
    sstv_rx *nrx = sstv_rx_new(_fs, &_nextCfg);
    if (!nrx) return;                                           // the old one stays: nothing is lost
    _settingsWaiting = NO;
    [self drainLocked];
    sstv_rx_free(_rx);
    _rx = nrx;
    _seenImages = 0;
    uint64_t back = (uint64_t)(2.0 * _fs), from = _fed > back ? _fed - back : 0;
    uint64_t oldest = _fed > _ringCap ? _fed - _ringCap : 0;
    if (from < _lastPictureFed) from = _lastPictureFed;
    if (from < oldest) from = oldest;
    _rxBase = (double)from / _fs;
    float chunk[2048];
    for (uint64_t k = from; _ring && k < _fed; ) {
        size_t n = 0;
        for (; n < 2048 && k < _fed; n++, k++) chunk[n] = (float)(_ring[k % _ringCap] / 32768.0);
        sstv_rx_feed(_rx, chunk, n);
    }
    [self drainLocked];
}

- (void)stop {
    // the source is read under the lock: a file that ends on another thread sets it to nil (N-captura-7)
    [_lock lock];
    id<TX500SSTVAudioSource> s = _source;
    [_lock unlock];
    if (s) [s stop];
    [self finishInput];
}

static TX500SSTVNoticeKind SSTVKind(const sstv_event *e) {
    switch (e->type) {
    case SSTV_EV_VIS: return TX500SSTVNoticeVIS;
    case SSTV_EV_VIS_REJECTED: return TX500SSTVNoticeVISRejected;
    case SSTV_EV_VIS_UNKNOWN: return TX500SSTVNoticeVISUnknown;
    case SSTV_EV_VIS_16BIT: return TX500SSTVNoticeVIS16Bit;
    case SSTV_EV_HEADER_IN_IMAGE: return TX500SSTVNoticeHeaderInPicture;
    case SSTV_EV_IMAGE: return TX500SSTVNoticeOther;
    case SSTV_EV_WARNING: break;
    }
    switch (e->note) {
    case SSTV_NOTE_FORCED_START: return TX500SSTVNoticeManualStart;
    case SSTV_NOTE_FORCED_NO_SYNC: return TX500SSTVNoticeManualNoSync;
    case SSTV_NOTE_FORCED_NOISE: return TX500SSTVNoticeManualNoise;
    case SSTV_NOTE_PERIOD_MISMATCH: return TX500SSTVNoticePeriodMismatch;
    case SSTV_NOTE_R36_300: return TX500SSTVNoticeRobot36Variant;
    case SSTV_NOTE_SYNC_LOST: return TX500SSTVNoticeSyncLost;
    case SSTV_NOTE_CLOSED_BY_VIS: return TX500SSTVNoticeClosedByNewVIS;
    case SSTV_NOTE_SLANT_NOMINAL: return TX500SSTVNoticeSlantNominal;
    case SSTV_NOTE_NO_ROWS: return TX500SSTVNoticeNoRows;
    case SSTV_NOTE_NONE: break;
    }
    return TX500SSTVNoticeOther;
}

/// The screen's words for a notice. The core's own texts (in Catalan) stay in its reports.
+ (NSString *)textForKind:(TX500SSTVNoticeKind)kind mode:(NSString *)mode vis:(int)vis offset:(double)offset {
    switch (kind) {
    case TX500SSTVNoticeVIS: return [NSString stringWithFormat:@"VIS: %@, tuning offset %+.0f Hz.", mode, offset];
    case TX500SSTVNoticeVISRejected: return @"A VIS header failed its parity check: no picture.";
    case TX500SSTVNoticeVISUnknown: return [NSString stringWithFormat:@"VIS code %d is not one of the modes here: no picture.", vis];
    case TX500SSTVNoticeVIS16Bit: return @"A 16-bit VIS (MMSSTV extended modes): not supported yet.";
    case TX500SSTVNoticeHeaderInPicture: return @"A header turned up inside the picture: the picture goes on.";
    case TX500SSTVNoticeManualStart: return [NSString stringWithFormat:@"No VIS: decoding as %@, the mode chosen by hand.", mode];
    case TX500SSTVNoticeManualNoSync: return [NSString stringWithFormat:@"%@ chosen by hand: there is a signal, but no %@ sync in 10 lines. Wrong mode?", mode, mode];
    case TX500SSTVNoticeManualNoise: return [NSString stringWithFormat:@"%@ chosen by hand: only noise so far.", mode];
    case TX500SSTVNoticePeriodMismatch: return [NSString stringWithFormat:@"The syncs do not fall on the %@ line period: wrong mode, or a very weak signal.", mode];
    case TX500SSTVNoticeRobot36Variant: return @"Robot 36 with ~300 ms lines: not the standard form; no picture.";
    case TX500SSTVNoticeSyncLost: return [NSString stringWithFormat:@"%@: no sync for 30 lines, and at least 12 s; the picture is closed.", mode];
    case TX500SSTVNoticeClosedByNewVIS: return [NSString stringWithFormat:@"%@ had lost its syncs and a new VIS came: it is closed, the new picture starts.", mode];
    case TX500SSTVNoticeSlantNominal: return [NSString stringWithFormat:@"%@: the slant measured left few syncs on its line; the picture uses the mode's own line period.", mode];
    case TX500SSTVNoticeNoRows: return [NSString stringWithFormat:@"%@: the audio ended before the picture's first line: no picture.", mode];
    case TX500SSTVNoticeOther: break;
    }
    return @"";
}

// with the lock held
- (void)drainLocked {
    sstv_event e;
    while (sstv_rx_next_event(_rx, &e)) {
        if (e.type == SSTV_EV_IMAGE) continue;                  // the picture itself comes below
        TX500SSTVNoticeKind kind = SSTVKind(&e);
        const sstv_mode *m = sstv_mode_by_id(e.mode);
        NSString *mode = m ? @(m->name) : @"";
        TX500SSTVNotice *n = [[TX500SSTVNotice alloc] initWithKind:kind time:_rxBase + e.t modeName:mode offsetHz:e.offset_hz
                                                              text:[TX500SSTVEngine textForKind:kind mode:mode vis:e.vis offset:e.offset_hz]];
        void (^cb)(TX500SSTVNotice *) = self.onNotice;
        if (cb) [self call:^{ cb(n); }];
    }
    int count = sstv_rx_image_count(_rx);
    for (; _seenImages < count; _seenImages++) {
        const sstv_image *im = sstv_rx_image(_rx, _seenImages);
        const sstv_mode *m = sstv_mode_by_id(im->mode);
        if (!im->rgb || !m || im->rows_received <= 0) continue;    // never a picture of 0 rows (NUC-7)
        NSData *rgb = [NSData dataWithBytes:im->rgb length:(NSUInteger)(im->width * im->height * 3)];
        NSDate *end = [self dateAtSampleLocked:_fed];
        TX500SSTVPicture *p = [[TX500SSTVPicture alloc] initWithModeKey:@(m->key) modeName:@(m->name) width:im->width
                                                                 height:im->height rowsReceived:im->rows_received
                                                               complete:im->complete != 0 rgb:rgb endUTC:end
                                                               offsetHz:im->offset_hz slantPPM:im->slant_ppm
                                                               fromFile:_fromFile sourceName:_sourceName ?: @""];
        p.startTime = _rxBase + im->t_start;
        p.startUTC = [self dateAtSampleLocked:(uint64_t)fmax(0.0, p.startTime * _fs)];
        p.recording = [self recordingFrom:p.startTime - 3.0 to:(double)_fed / _fs];
        p.recording.modeKey = p.modeKey; p.recording.endUTC = end; p.recording.fromFile = _fromFile;
        _lastPictureFed = _fed;
        sstv_rx_drop_pixels(_rx, _seenImages);                  // stored on our side: the core lets it go
        void (^cb)(TX500SSTVPicture *) = self.onPicture;
        if (cb) [self call:^{ cb(p); }];
    }
}

// with the lock held: the audio between two times of the input, from the ring (nil if it is gone)
- (nullable TX500SSTVRecording *)recordingFrom:(double)a to:(double)b {
    if (!_ring || !_ringCap || b <= a) return nil;
    uint64_t oldest = _fed > _ringCap ? _fed - _ringCap : 0;
    uint64_t ia = a <= 0 ? 0 : (uint64_t)(a * _fs), ib = (uint64_t)(b * _fs);
    if (ia < oldest) ia = oldest;
    if (ib > _fed) ib = _fed;
    if (ib <= ia) return nil;
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)(ib - ia) * 2];
    int16_t *o = d.mutableBytes;
    for (uint64_t k = ia; k < ib; k++) o[k - ia] = _ring[k % _ringCap];
    TX500SSTVRecording *r = [[TX500SSTVRecording alloc] initWithSamples:d sampleRate:_fs startTime:(double)ia / _fs];
    // when it was heard, with the anchors that fall inside it (a sleep or a gap)
    NSMutableArray *anc = [NSMutableArray arrayWithObject:@[@0, @([self timeAtSampleLocked:ia])]];
    for (NSArray<NSNumber *> *a in _anchors) {
        uint64_t k = a[0].unsignedLongLongValue;
        if (k > ia && k < ib) [anc addObject:@[@(k - ia), a[1]]];
    }
    r.timeAnchors = anc;
    r.endUTC = [self dateAtSampleLocked:ib];
    return r;
}

- (nullable TX500SSTVRecording *)lastMinutes {
    [_lock lock];
    TX500SSTVRecording *r = _fs > 0 ? [self recordingFrom:0.0 to:(double)_fed / _fs] : nil;
    [_lock unlock];
    r.modeKey = @""; r.fromFile = _fromFile;
    return r;
}

- (void)feedSamples:(const float *)samples count:(NSUInteger)count {
    [_lock lock];
    uint64_t gen = _gen;
    [_lock unlock];
    [self feedSamples:samples count:count generation:gen];
}

- (void)feedSamples:(const float *)samples count:(NSUInteger)count generation:(uint64_t)gen {
    [_lock lock];
    if (gen != _gen || !_rx || !_running) { [_lock unlock]; return; }
    [self anchorBlockLocked];
    // the core decodes the same 16-bit values the ring keeps, so that decoding a recording again gives
    // the same picture, bit for bit, when the piece starts at the first sample the live input had; a piece
    // cut elsewhere starts the demodulator's decimation at another phase and can differ slightly (NUC-5;
    // 16 bits: the quantisation is some 96 dB below full scale)
    if (count > _qCap) { free(_q); _q = malloc(count * sizeof(float)); _qCap = _q ? count : 0; }
    if (!_q) { [_lock unlock]; return; }
    for (NSUInteger i = 0; i < count; i++) {
        double v = samples[i] * 32768.0;
        int16_t q = (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : lrint(v));
        if (_ring) _ring[(_fed + i) % _ringCap] = q;
        _q[i] = (float)(q / 32768.0);
    }
    sstv_rx_feed(_rx, _q, count);
    _fed += count;
    [self drainLocked];
    if (_settingsWaiting && !sstv_rx_receiving(_rx, NULL, NULL, NULL)) [self swapReceiverLocked];
    double t = (double)_fed / _fs;
    sstv_mode_id mode;
    int w, h;
    if (self.onProgress && t >= _nextProgress && sstv_rx_receiving(_rx, &mode, &w, &h)) {
        _nextProgress = t + self.progressInterval;
        size_t need = (size_t)w * h * 3;
        if (need > _partialCap) { free(_partial); _partial = malloc(need); _partialCap = _partial ? need : 0; }
        int rows = _partial ? sstv_rx_draw_partial(_rx, _partial) : -1;
        if (rows >= 0) {
            NSBitmapImageRep *rep = SSTVBitmap(_partial, w, h);
            const sstv_mode *m = sstv_mode_by_id(mode);
            NSString *name = m ? @(m->name) : @"";
            void (^cb)(NSString *, NSInteger, NSInteger, NSBitmapImageRep *) = self.onProgress;
            [self call:^{ cb(name, rows, h, rep); }];
        }
    }
    [_lock unlock];
}

- (void)finishInput {
    [_lock lock];
    uint64_t gen = _gen;
    [_lock unlock];
    [self finishInputOfGeneration:gen];
}

- (void)finishInputOfGeneration:(uint64_t)gen {
    [_lock lock];
    if (gen != _gen) { [_lock unlock]; return; }                // the end of a source already replaced
    if([_source respondsToSelector:@selector(inputFailure)]) self.lastInputFailure=[_source inputFailure];
    if (_rx && _running) {
        _running = NO;
        sstv_rx_finish(_rx);
        [self drainLocked];
        sstv_rx_free(_rx);
        _rx = NULL;
        void (^cb)(void) = self.onStopped;
        if (cb) [self call:cb];
    }
    _source = nil;
    [_lock unlock];
}
@end
