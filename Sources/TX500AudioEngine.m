//
//  TX500AudioEngine.m
//  Lab599 Utility
//
//  High-Performance Low-Latency CoreAudio Monitoring & DSP Engine
//  Specially designed for Lab599 Discovery TX-500 over AD-508 USB-C Audio
//

#import "TX500AudioEngine.h"
#import <math.h>
#import <pthread.h>

#define TX500_RING_BUFFER_CAPACITY (32768)
#define TX500_FFT_SIZE (512)
#define TX500_WAVEFORM_SIZE (512)

@implementation TX500AudioDeviceItem
@end

// Biquad Filter state
typedef struct {
    double b0, b1, b2;
    double a1, a2;
    double x1, x2;
    double y1, y2;
} TX500Biquad;

static void TX500BiquadReset(TX500Biquad *f) {
    f->x1 = f->x2 = f->y1 = f->y2 = 0.0;
}

static inline double TX500BiquadProcess(TX500Biquad *f, double in) {
    double out = f->b0 * in + f->b1 * f->x1 + f->b2 * f->x2 - f->a1 * f->y1 - f->a2 * f->y2;
    f->x2 = f->x1;
    f->x1 = in;
    f->y2 = f->y1;
    f->y1 = out;
    return out;
}

static void TX500MakeLowPass(TX500Biquad *f, double srate, double cutoff, double q) {
    if (cutoff <= 0.0 || cutoff >= srate * 0.49) {
        f->b0 = 1.0; f->b1 = f->b2 = f->a1 = f->a2 = 0.0;
        return;
    }
    double w0 = 2.0 * M_PI * cutoff / srate;
    double alpha = sin(w0) / (2.0 * q);
    double cosw = cos(w0);
    double a0 = 1.0 + alpha;
    f->b0 = ((1.0 - cosw) / 2.0) / a0;
    f->b1 = (1.0 - cosw) / a0;
    f->b2 = ((1.0 - cosw) / 2.0) / a0;
    f->a1 = (-2.0 * cosw) / a0;
    f->a2 = (1.0 - alpha) / a0;
}

static void TX500MakeHighPass(TX500Biquad *f, double srate, double cutoff, double q) {
    if (cutoff <= 10.0) {
        f->b0 = 1.0; f->b1 = f->b2 = f->a1 = f->a2 = 0.0;
        return;
    }
    double w0 = 2.0 * M_PI * cutoff / srate;
    double alpha = sin(w0) / (2.0 * q);
    double cosw = cos(w0);
    double a0 = 1.0 + alpha;
    f->b0 = ((1.0 + cosw) / 2.0) / a0;
    f->b1 = (-(1.0 + cosw)) / a0;
    f->b2 = ((1.0 + cosw) / 2.0) / a0;
    f->a1 = (-2.0 * cosw) / a0;
    f->a2 = (1.0 - alpha) / a0;
}

static void TX500MakeNotch(TX500Biquad *f, double srate, double center, double q) {
    if (center <= 20.0 || center >= srate * 0.48) {
        f->b0 = 1.0; f->b1 = f->b2 = f->a1 = f->a2 = 0.0;
        return;
    }
    double w0 = 2.0 * M_PI * center / srate;
    double alpha = sin(w0) / (2.0 * q);
    double cosw = cos(w0);
    double a0 = 1.0 + alpha;
    f->b0 = 1.0 / a0;
    f->b1 = (-2.0 * cosw) / a0;
    f->b2 = 1.0 / a0;
    f->a1 = (-2.0 * cosw) / a0;
    f->a2 = (1.0 - alpha) / a0;
}

static void TX500MakePeaking(TX500Biquad *f, double srate, double center, double q, double gainDb) {
    double a = pow(10.0, gainDb / 40.0);
    double w0 = 2.0 * M_PI * center / srate;
    double alpha = sin(w0) / (2.0 * q);
    double cosw = cos(w0);
    double a0 = 1.0 + alpha / a;
    f->b0 = (1.0 + alpha * a) / a0;
    f->b1 = (-2.0 * cosw) / a0;
    f->b2 = (1.0 - alpha * a) / a0;
    f->a1 = (-2.0 * cosw) / a0;
    f->a2 = (1.0 - alpha / a) / a0;
}

// Fast Radix-2 FFT with in-place bit reversal
static void TX500ComputeFFT(const float *realIn, float *magnitudesOut, int n) {
    float real[TX500_FFT_SIZE];
    float imag[TX500_FFT_SIZE];

    // Apply Hann window and bit-reversal
    int j = 0;
    for (int i = 0; i < n; i++) {
        float win = 0.5f * (1.0f - cosf((2.0f * (float)M_PI * (float)i) / (float)(n - 1)));
        real[i] = realIn[i] * win;
        imag[i] = 0.0f;
    }

    for (int i = 0; i < n; i++) {
        if (j > i) {
            float tr = real[j]; real[j] = real[i]; real[i] = tr;
            float ti = imag[j]; imag[j] = imag[i]; imag[i] = ti;
        }
        int m = n >> 1;
        while (m >= 1 && j >= m) {
            j -= m;
            m >>= 1;
        }
        j += m;
    }

    // Cooley-Tukey radix-2 butterfly
    for (int len = 2; len <= n; len <<= 1) {
        float angle = -2.0f * (float)M_PI / (float)len;
        float wlen_r = cosf(angle);
        float wlen_i = sinf(angle);
        int halfLen = len >> 1;
        for (int i = 0; i < n; i += len) {
            float w_r = 1.0f;
            float w_i = 0.0f;
            for (int k = 0; k < halfLen; k++) {
                float u_r = real[i + k];
                float u_i = imag[i + k];
                float v_r = real[i + k + halfLen] * w_r - imag[i + k + halfLen] * w_i;
                float v_i = real[i + k + halfLen] * w_i + imag[i + k + halfLen] * w_r;
                real[i + k] = u_r + v_r;
                imag[i + k] = u_i + v_i;
                real[i + k + halfLen] = u_r - v_r;
                imag[i + k + halfLen] = u_i - v_i;
                float next_w_r = w_r * wlen_r - w_i * wlen_i;
                float next_w_i = w_r * wlen_i + w_i * wlen_r;
                w_r = next_w_r;
                w_i = next_w_i;
            }
        }
    }

    // Convert half-spectrum to normalized magnitudes
    int halfN = n / 2;
    float norm = 2.0f / (float)n;
    for (int i = 0; i < halfN; i++) {
        float mag = sqrtf(real[i] * real[i] + imag[i] * imag[i]) * norm;
        magnitudesOut[i] = mag;
    }
}

@interface TX500AudioEngine () {
    // Ring Buffer for stereo audio (interleaved Left, Right)
    float _ringBuffer[TX500_RING_BUFFER_CAPACITY * 2];
    NSInteger _ringWriteIndex;
    NSInteger _ringReadIndex;
    NSInteger _ringAvailableFrames;
    pthread_mutex_t _ringMutex;

    // DSP Filters
    TX500Biquad _lowPass;
    TX500Biquad _highPass;
    TX500Biquad _notch;
    TX500Biquad _peaking;
    pthread_mutex_t _filterMutex;

    // Visualizer Buffers
    float _waveformBuffer[TX500_WAVEFORM_SIZE];
    NSInteger _waveformIndex;
    float _fftInputBuffer[TX500_FFT_SIZE];
    NSInteger _fftInputIndex;
    float _fftMagnitudes[TX500_FFT_SIZE / 2];

    // Limiter & Squelch state
    float _limiterEnvelope;
    float _squelchEnvelope;
    float _squelchGain; // 0.0 to 1.0 (smooth fade)

    // WAV Recording
    NSFileHandle *_recordingFileHandle;
    uint32_t _recordedAudioDataBytes;
    NSDate *_recordingStartTime;

    AudioQueueBufferRef _inputBuffers[3];
    AudioQueueBufferRef _outputBuffers[3];
}

@property (nonatomic, assign, readwrite) BOOL isMonitoring;
@property (nonatomic, assign, readwrite) BOOL isRecording;
@property (nonatomic, assign, readwrite) BOOL isAD508Connected;
@property (nonatomic, copy, readwrite, nullable) NSString *ad508DeviceName;

@property (nonatomic, strong, readwrite) NSMutableArray<TX500AudioDeviceItem *> *internalInputDevices;
@property (nonatomic, strong, readwrite) NSMutableArray<TX500AudioDeviceItem *> *internalOutputDevices;

@property (nonatomic, assign, readwrite) float leftLevelRmsDb;
@property (nonatomic, assign, readwrite) float rightLevelRmsDb;
@property (nonatomic, assign, readwrite) float peakLevelDb;
@property (nonatomic, assign, readwrite) BOOL isClipping;
@property (nonatomic, assign, readwrite) BOOL isSquelchOpen;
@property (nonatomic, assign, readwrite) float currentLatencyMs;

@property (nonatomic, copy, readwrite, nullable) NSString *currentRecordingPath;
@property (nonatomic, assign, readwrite) NSTimeInterval recordingDuration;
@property (nonatomic, assign, readwrite) int64_t recordingBytes;

@property (nonatomic, assign) AudioQueueRef inputQueue;
@property (nonatomic, assign) AudioQueueRef outputQueue;
@property (nonatomic, assign) double sampleRate;

@property (nonatomic, strong, nullable) NSTimer *metricsTimer;
@property (nonatomic, strong, nullable) NSTimer *simulationTimer;

- (void)processInputBuffer:(AudioQueueBufferRef)inBuffer;
- (void)renderOutputBuffer:(AudioQueueBufferRef)outBuffer;

@end

// AudioQueue Callbacks
static void TX500InputBufferCallback(void *inUserData,
                                     AudioQueueRef inAQ,
                                     AudioQueueBufferRef inBuffer,
                                     const AudioTimeStamp *inStartTime,
                                     UInt32 inNumPackets,
                                     const AudioStreamPacketDescription *inPacketDesc) {
    (void)inStartTime; (void)inNumPackets; (void)inPacketDesc;
    TX500AudioEngine *engine = (__bridge TX500AudioEngine *)inUserData;
    [engine processInputBuffer:inBuffer];
    if (engine.isMonitoring && engine.inputQueue) {
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    }
}

static void TX500OutputBufferCallback(void *inUserData,
                                      AudioQueueRef inAQ,
                                      AudioQueueBufferRef inBuffer) {
    TX500AudioEngine *engine = (__bridge TX500AudioEngine *)inUserData;
    [engine renderOutputBuffer:inBuffer];
    if (engine.isMonitoring && engine.outputQueue) {
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    }
}

@implementation TX500AudioEngine

- (instancetype)init {
    self = [super init];
    if (self) {
        pthread_mutex_init(&_ringMutex, NULL);
        pthread_mutex_init(&_filterMutex, NULL);

        _sampleRate = 48000.0;
        _bufferSizeFrames = 512; // ~10.6 ms latency
        _masterVolume = 1.0f;    // 100%
        _balance = 0.0f;         // Center
        _isMuted = NO;
        _isDimmed = NO;

        _filterPreset = TX500AudioFilterPresetSSBVoice;
        _filterEnabled = YES;
        _lowCutHz = 300.0f;
        _highCutHz = 2700.0f;

        _notchEnabled = NO;
        _notchFreqHz = 1000.0f;
        _notchQ = 8.0f;

        _squelchEnabled = NO;
        _squelchThresholdDb = -65.0f;
        _isSquelchOpen = YES;
        _squelchGain = 1.0f;

        _limiterEnabled = YES;
        _limiterEnvelope = 0.0f;

        _leftLevelRmsDb = -90.0f;
        _rightLevelRmsDb = -90.0f;
        _peakLevelDb = -90.0f;

        _internalInputDevices = [NSMutableArray array];
        _internalOutputDevices = [NSMutableArray array];

        [self updateFilters];
        [self refreshDevices];
    }
    return self;
}

- (void)dealloc {
    [self stopMonitoring];
    [self stopRecording];
    pthread_mutex_destroy(&_ringMutex);
    pthread_mutex_destroy(&_filterMutex);
}

#pragma mark - Device Enumeration

- (NSArray<TX500AudioDeviceItem *> *)inputDevices {
    @synchronized (self.internalInputDevices) {
        return [self.internalInputDevices copy];
    }
}

- (NSArray<TX500AudioDeviceItem *> *)outputDevices {
    @synchronized (self.internalOutputDevices) {
        return [self.internalOutputDevices copy];
    }
}

- (void)refreshDevices {
    NSMutableArray<TX500AudioDeviceItem *> *inputs = [NSMutableArray array];
    NSMutableArray<TX500AudioDeviceItem *> *outputs = [NSMutableArray array];

    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &dataSize);
    if (status == noErr && dataSize > 0) {
        UInt32 count = dataSize / sizeof(AudioDeviceID);
        AudioDeviceID *deviceIDs = (AudioDeviceID *)malloc(dataSize);
        if (deviceIDs) {
            if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &dataSize, deviceIDs) == noErr) {
                for (UInt32 i = 0; i < count; i++) {
                    AudioDeviceID devID = deviceIDs[i];

                    // Name
                    CFStringRef nameRef = NULL;
                    UInt32 nameSize = sizeof(CFStringRef);
                    AudioObjectPropertyAddress nameAddr = {
                        kAudioDevicePropertyDeviceNameCFString,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain
                    };
                    NSString *name = @"Audio Device";
                    if (AudioObjectGetPropertyData(devID, &nameAddr, 0, NULL, &nameSize, &nameRef) == noErr && nameRef) {
                        name = (__bridge_transfer NSString *)nameRef;
                    }

                    // UID
                    CFStringRef uidRef = NULL;
                    UInt32 uidSize = sizeof(CFStringRef);
                    AudioObjectPropertyAddress uidAddr = {
                        kAudioDevicePropertyDeviceUID,
                        kAudioObjectPropertyScopeGlobal,
                        kAudioObjectPropertyElementMain
                    };
                    NSString *uid = [NSString stringWithFormat:@"%u", (unsigned int)devID];
                    if (AudioObjectGetPropertyData(devID, &uidAddr, 0, NULL, &uidSize, &uidRef) == noErr && uidRef) {
                        uid = (__bridge_transfer NSString *)uidRef;
                    }

                    // Check if AD-508 / TX-500 audio
                    NSString *lower = name.lowercaseString;
                    BOOL isAD508 = [lower containsString:@"usb audio"] ||
                                   [lower containsString:@"ttgk"] ||
                                   [lower containsString:@"ad-508"] ||
                                   [lower containsString:@"ad-509"] ||
                                   [lower containsString:@"c-media"] ||
                                   [lower containsString:@"tx-500"];

                    // Check Input Streams
                    AudioObjectPropertyAddress inStreamAddr = {
                        kAudioDevicePropertyStreams,
                        kAudioDevicePropertyScopeInput,
                        kAudioObjectPropertyElementMain
                    };
                    UInt32 inStreamSize = 0;
                    if (AudioObjectGetPropertyDataSize(devID, &inStreamAddr, 0, NULL, &inStreamSize) == noErr && inStreamSize > 0) {
                        TX500AudioDeviceItem *item = [TX500AudioDeviceItem new];
                        item.name = name;
                        item.uid = uid;
                        item.isAD508 = isAD508;
                        item.isInput = YES;
                        [inputs addObject:item];
                    }

                    // Check Output Streams
                    AudioObjectPropertyAddress outStreamAddr = {
                        kAudioDevicePropertyStreams,
                        kAudioDevicePropertyScopeOutput,
                        kAudioObjectPropertyElementMain
                    };
                    UInt32 outStreamSize = 0;
                    if (AudioObjectGetPropertyDataSize(devID, &outStreamAddr, 0, NULL, &outStreamSize) == noErr && outStreamSize > 0) {
                        TX500AudioDeviceItem *item = [TX500AudioDeviceItem new];
                        item.name = name;
                        item.uid = uid;
                        item.isAD508 = isAD508;
                        item.isInput = NO;
                        [outputs addObject:item];
                    }
                }
            }
            free(deviceIDs);
        }
    }

    // Default fallbacks if empty
    if (inputs.count == 0) {
        TX500AudioDeviceItem *def = [TX500AudioDeviceItem new];
        def.name = @"Default Audio Input";
        def.uid = @"default";
        [inputs addObject:def];
    }
    if (outputs.count == 0) {
        TX500AudioDeviceItem *def = [TX500AudioDeviceItem new];
        def.name = @"Default Audio Output";
        def.uid = @"default";
        [outputs addObject:def];
    }

    // Check if AD-508 is present
    BOOL foundAD508 = NO;
    NSString *ad508Name = nil;
    for (TX500AudioDeviceItem *item in inputs) {
        if (item.isAD508) {
            foundAD508 = YES;
            ad508Name = item.name;
            if (!self.selectedInputDeviceUID || [self.selectedInputDeviceUID isEqualToString:@"default"]) {
                _selectedInputDeviceUID = item.uid;
            }
            break;
        }
    }
    self.isAD508Connected = foundAD508;
    self.ad508DeviceName = ad508Name;

    // Default selections
    if (!self.selectedInputDeviceUID) {
        self.selectedInputDeviceUID = inputs.firstObject.uid;
    }
    if (!self.selectedOutputDeviceUID) {
        TX500AudioDeviceItem *bestOutput = nil;
        for (TX500AudioDeviceItem *outItem in outputs) {
            NSString *lower = [outItem.name lowercaseString];
            if ([lower containsString:@"macbook"] && [lower containsString:@"speaker"]) {
                bestOutput = outItem;
                break;
            }
        }
        if (!bestOutput) {
            for (TX500AudioDeviceItem *outItem in outputs) {
                NSString *lower = [outItem.name lowercaseString];
                if ([lower containsString:@"speaker"] || [lower containsString:@"internal"] || [lower containsString:@"built-in"]) {
                    bestOutput = outItem;
                    break;
                }
            }
        }
        if (!bestOutput) {
            for (TX500AudioDeviceItem *outItem in outputs) {
                if (!outItem.isAD508 && ![outItem.name containsString:@"USB Audio"]) {
                    bestOutput = outItem;
                    break;
                }
            }
        }
        self.selectedOutputDeviceUID = (bestOutput ?: outputs.firstObject).uid;
    }

    @synchronized (self.internalInputDevices) {
        [self.internalInputDevices setArray:inputs];
    }
    @synchronized (self.internalOutputDevices) {
        [self.internalOutputDevices setArray:outputs];
    }

    if (self.onDeviceListChanged) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.onDeviceListChanged();
        });
    }
}

#pragma mark - DSP Filter Management

- (void)updateFilters {
    pthread_mutex_lock(&_filterMutex);

    double srate = self.sampleRate > 0 ? self.sampleRate : 48000.0;

    TX500MakeHighPass(&_highPass, srate, (double)self.lowCutHz, 0.707);
    TX500MakeLowPass(&_lowPass, srate, (double)self.highCutHz, 0.707);

    if (self.notchEnabled) {
        TX500MakeNotch(&_notch, srate, (double)self.notchFreqHz, (double)self.notchQ);
    } else {
        TX500BiquadReset(&_notch);
        _notch.b0 = 1.0; _notch.b1 = _notch.b2 = _notch.a1 = _notch.a2 = 0.0;
    }

    if (self.filterPreset == TX500AudioFilterPresetDXBoost) {
        // Boost 1800 Hz speech consonants +6dB with Q=1.2
        TX500MakePeaking(&_peaking, srate, 1800.0, 1.2, 6.0);
    } else {
        TX500BiquadReset(&_peaking);
        _peaking.b0 = 1.0; _peaking.b1 = _peaking.b2 = _peaking.a1 = _peaking.a2 = 0.0;
    }

    pthread_mutex_unlock(&_filterMutex);
}

- (void)setLowCutHz:(float)lowCutHz {
    _lowCutHz = lowCutHz;
    [self updateFilters];
}

- (void)setHighCutHz:(float)highCutHz {
    _highCutHz = highCutHz;
    [self updateFilters];
}

- (void)setNotchEnabled:(BOOL)notchEnabled {
    _notchEnabled = notchEnabled;
    [self updateFilters];
}

- (void)setNotchFreqHz:(float)notchFreqHz {
    _notchFreqHz = notchFreqHz;
    [self updateFilters];
}

- (void)setFilterPreset:(TX500AudioFilterPreset)preset {
    _filterPreset = preset;
    [self applyPreset:preset];
}

- (void)applyPreset:(TX500AudioFilterPreset)preset {
    _filterPreset = preset;
    switch (preset) {
        case TX500AudioFilterPresetSSBVoice:
            _lowCutHz = 300.0f;
            _highCutHz = 2700.0f;
            _notchEnabled = NO;
            break;
        case TX500AudioFilterPresetSSBWide:
            _lowCutHz = 150.0f;
            _highCutHz = 3400.0f;
            _notchEnabled = NO;
            break;
        case TX500AudioFilterPresetCWNarrow:
            _lowCutHz = 550.0f;
            _highCutHz = 750.0f;
            _notchEnabled = NO;
            break;
        case TX500AudioFilterPresetAMBroad:
            _lowCutHz = 80.0f;
            _highCutHz = 4500.0f;
            _notchEnabled = NO;
            break;
        case TX500AudioFilterPresetDXBoost:
            _lowCutHz = 400.0f;
            _highCutHz = 2400.0f;
            _notchEnabled = NO;
            break;
        case TX500AudioFilterPresetFlat:
            _lowCutHz = 20.0f;
            _highCutHz = 12000.0f;
            _notchEnabled = NO;
            break;
    }
    [self updateFilters];
}

#pragma mark - Audio Monitoring Start / Stop

- (BOOL)startMonitoring:(NSError **)error {
    if (self.isMonitoring) return YES;

    [self refreshDevices];

    // Reset ring buffer
    pthread_mutex_lock(&_ringMutex);
    _ringWriteIndex = 0;
    _ringReadIndex = 0;
    _ringAvailableFrames = 0;
    memset(_ringBuffer, 0, sizeof(_ringBuffer));
    pthread_mutex_unlock(&_ringMutex);

    // Audio format: 48000 Hz 32-bit Float
    AudioStreamBasicDescription inFormat;
    memset(&inFormat, 0, sizeof(inFormat));
    inFormat.mSampleRate = self.sampleRate;
    inFormat.mFormatID = kAudioFormatLinearPCM;
    inFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    inFormat.mBytesPerPacket = 4;
    inFormat.mFramesPerPacket = 1;
    inFormat.mBytesPerFrame = 4;
    inFormat.mChannelsPerFrame = 1; // Mono input from AD-508 / radio
    inFormat.mBitsPerChannel = 32;

    AudioStreamBasicDescription outFormat;
    memset(&outFormat, 0, sizeof(outFormat));
    outFormat.mSampleRate = self.sampleRate;
    outFormat.mFormatID = kAudioFormatLinearPCM;
    outFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    outFormat.mBytesPerPacket = 8;
    outFormat.mFramesPerPacket = 1;
    outFormat.mBytesPerFrame = 8;
    outFormat.mChannelsPerFrame = 2; // Stereo output
    outFormat.mBitsPerChannel = 32;

    UInt32 bufferByteSize = (UInt32)(self.bufferSizeFrames * sizeof(float));

    // 1. Create Input Queue
    AudioQueueRef inQ = NULL;
    OSStatus st = AudioQueueNewInput(&inFormat, TX500InputBufferCallback, (__bridge void *)self,
                                     NULL, NULL, 0, &inQ);
    if (st != noErr) {
        if (error) {
            *error = [NSError errorWithDomain:@"TX500AudioErrorDomain" code:st
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create audio input queue (error %d). Check microphone permissions.", (int)st]}];
        }
        return NO;
    }
    self.inputQueue = inQ;

    // Set Input Device
    if (self.selectedInputDeviceUID && ![self.selectedInputDeviceUID isEqualToString:@"default"]) {
        CFStringRef uidRef = (__bridge CFStringRef)self.selectedInputDeviceUID;
        AudioQueueSetProperty(self.inputQueue, kAudioQueueProperty_CurrentDevice, &uidRef, sizeof(uidRef));
    }

    // Allocate Input Buffers
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef buf = NULL;
        if (AudioQueueAllocateBuffer(self.inputQueue, bufferByteSize, &buf) == noErr) {
            _inputBuffers[i] = buf;
            AudioQueueEnqueueBuffer(self.inputQueue, buf, 0, NULL);
        }
    }

    // 2. Create Output Queue
    AudioQueueRef outQ = NULL;
    st = AudioQueueNewOutput(&outFormat, TX500OutputBufferCallback, (__bridge void *)self,
                             NULL, NULL, 0, &outQ);
    if (st != noErr) {
        AudioQueueDispose(self.inputQueue, true);
        self.inputQueue = NULL;
        if (error) {
            *error = [NSError errorWithDomain:@"TX500AudioErrorDomain" code:st
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to create audio output queue (error %d).", (int)st]}];
        }
        return NO;
    }
    self.outputQueue = outQ;

    // Set Output Device
    if (self.selectedOutputDeviceUID && ![self.selectedOutputDeviceUID isEqualToString:@"default"]) {
        CFStringRef uidRef = (__bridge CFStringRef)self.selectedOutputDeviceUID;
        AudioQueueSetProperty(self.outputQueue, kAudioQueueProperty_CurrentDevice, &uidRef, sizeof(uidRef));
    }

    // Allocate Output Buffers (stereo: 2 * bufferByteSize)
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef buf = NULL;
        if (AudioQueueAllocateBuffer(self.outputQueue, bufferByteSize * 2, &buf) == noErr) {
            _outputBuffers[i] = buf;
            // Prime with silence
            memset(buf->mAudioData, 0, buf->mAudioDataBytesCapacity);
            buf->mAudioDataByteSize = buf->mAudioDataBytesCapacity;
            AudioQueueEnqueueBuffer(self.outputQueue, buf, 0, NULL);
        }
    }

    // Start Queues
    AudioQueueStart(self.inputQueue, NULL);
    AudioQueueStart(self.outputQueue, NULL);

    self.isMonitoring = YES;
    self.currentLatencyMs = ((float)self.bufferSizeFrames / (float)self.sampleRate) * 1000.0f;

    // Start Metrics timer (30 Hz refresh)
    [self startMetricsTimer];

    return YES;
}

- (void)stopMonitoring {
    if (!self.isMonitoring) return;
    self.isMonitoring = NO;

    [self.metricsTimer invalidate];
    self.metricsTimer = nil;

    if (self.inputQueue) {
        AudioQueueStop(self.inputQueue, true);
        AudioQueueDispose(self.inputQueue, true);
        self.inputQueue = NULL;
    }

    if (self.outputQueue) {
        AudioQueueStop(self.outputQueue, true);
        AudioQueueDispose(self.outputQueue, true);
        self.outputQueue = NULL;
    }

    self.leftLevelRmsDb = -90.0f;
    self.rightLevelRmsDb = -90.0f;
    self.peakLevelDb = -90.0f;
    self.isClipping = NO;
}

- (void)startMetricsTimer {
    [self.metricsTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.metricsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf notifyMetricsTick];
    }];
}

- (void)notifyMetricsTick {
    if (self.onMetricsUpdated) {
        self.onMetricsUpdated(self.leftLevelRmsDb, self.rightLevelRmsDb, self.peakLevelDb, self.isClipping, self.isSquelchOpen);
    }
}

#pragma mark - Real-Time Audio DSP Processing

- (void)processInputBuffer:(AudioQueueBufferRef)inBuffer {
    const float *inputSamples = (const float *)inBuffer->mAudioData;
    NSInteger numFrames = inBuffer->mAudioDataByteSize / sizeof(float);
    [self processRawAudioSamples:inputSamples count:numFrames];
}

- (void)processRawAudioSamples:(const float *)inputSamples count:(NSInteger)numFrames {
    if (numFrames <= 0) return;

    // Calculate RMS and Peak
    float sumSquares = 0.0f;
    float peak = 0.0f;
    for (NSInteger i = 0; i < numFrames; i++) {
        float s = fabsf(inputSamples[i]);
        if (s > peak) peak = s;
        sumSquares += s * s;
    }
    float rms = sqrtf(sumSquares / (float)numFrames);
    float rmsDb = rms > 1e-5f ? 20.0f * log10f(rms) : -90.0f;
    float peakDb = peak > 1e-5f ? 20.0f * log10f(peak) : -90.0f;

    // Squelch Envelope Tracking
    if (self.squelchEnabled) {
        float thresh = powf(10.0f, self.squelchThresholdDb / 20.0f);
        if (rms >= thresh) {
            _squelchGain = 0.9f * _squelchGain + 0.1f * 1.0f; // Attack
            self.isSquelchOpen = YES;
        } else {
            _squelchGain = 0.98f * _squelchGain + 0.02f * 0.0f; // Release
            if (_squelchGain < 0.05f) self.isSquelchOpen = NO;
        }
    } else {
        _squelchGain = 1.0f;
        self.isSquelchOpen = YES;
    }

    // Master Gain & Dim
    float gain = self.masterVolume;
    if (self.isMuted) gain = 0.0f;
    else if (self.isDimmed) gain *= 0.1f; // -20 dB
    gain *= _squelchGain;

    // Panning (L / R coefficients)
    float pan = self.balance; // -1.0 to 1.0
    float leftGain = gain * sqrtf(0.5f * (1.0f - pan));
    float rightGain = gain * sqrtf(0.5f * (1.0f + pan));

    // Process Samples through DSP Filters and prepare Stereo Frames
    pthread_mutex_lock(&_filterMutex);
    pthread_mutex_lock(&_ringMutex);

    BOOL clippingDetected = NO;
    float maxOutPeak = 0.0f;

    for (NSInteger i = 0; i < numFrames; i++) {
        double sample = (double)inputSamples[i];

        // Apply Biquad Filters
        if (self.filterEnabled) {
            sample = TX500BiquadProcess(&_highPass, sample);
            sample = TX500BiquadProcess(&_lowPass, sample);
        }
        if (self.notchEnabled) {
            sample = TX500BiquadProcess(&_notch, sample);
        }
        if (self.filterPreset == TX500AudioFilterPresetDXBoost) {
            sample = TX500BiquadProcess(&_peaking, sample);
        }

        // Peak Limiter / AGC
        float absSample = (float)fabs(sample);
        if (absSample > _limiterEnvelope) {
            _limiterEnvelope = absSample; // Instant attack
        } else {
            _limiterEnvelope = 0.999f * _limiterEnvelope; // Slow release
        }

        float limitGain = 1.0f;
        if (self.limiterEnabled && _limiterEnvelope > 0.95f) {
            limitGain = 0.95f / _limiterEnvelope;
        }

        float processedMono = (float)sample * limitGain;

        // Stereo Output Channels
        float left = processedMono * leftGain;
        float right = processedMono * rightGain;

        // Soft clip / check overload
        if (fabsf(left) > 0.99f || fabsf(right) > 0.99f) {
            clippingDetected = YES;
        }
        if (left > 1.0f) left = 1.0f; else if (left < -1.0f) left = -1.0f;
        if (right > 1.0f) right = 1.0f; else if (right < -1.0f) right = -1.0f;

        float framePeak = fmaxf(fabsf(left), fabsf(right));
        if (framePeak > maxOutPeak) maxOutPeak = framePeak;

        // Write to Ring Buffer (Interleaved Left, Right)
        if (_ringAvailableFrames < TX500_RING_BUFFER_CAPACITY) {
            NSInteger idx = (_ringWriteIndex % TX500_RING_BUFFER_CAPACITY) * 2;
            _ringBuffer[idx] = left;
            _ringBuffer[idx + 1] = right;
            _ringWriteIndex++;
            _ringAvailableFrames++;
        }

        // Feed Waveform rolling buffer
        _waveformBuffer[_waveformIndex % TX500_WAVEFORM_SIZE] = (left + right) * 0.5f;
        _waveformIndex++;

        // Feed FFT input buffer
        _fftInputBuffer[_fftInputIndex % TX500_FFT_SIZE] = (float)inputSamples[i];
        _fftInputIndex++;
    }

    pthread_mutex_unlock(&_ringMutex);
    pthread_mutex_unlock(&_filterMutex);

    // Update Levels
    self.leftLevelRmsDb = rmsDb;
    self.rightLevelRmsDb = rmsDb;
    self.peakLevelDb = peakDb;
    self.isClipping = clippingDetected;

    // Send visualizer callbacks periodically
    if (_fftInputIndex >= TX500_FFT_SIZE) {
        _fftInputIndex = 0;
        TX500ComputeFFT(_fftInputBuffer, _fftMagnitudes, TX500_FFT_SIZE);
        if (self.onSpectrumUpdated) {
            self.onSpectrumUpdated(_fftMagnitudes, TX500_FFT_SIZE / 2, (float)self.sampleRate);
        }
    }

    if (self.onWaveformUpdated) {
        self.onWaveformUpdated(_waveformBuffer, TX500_WAVEFORM_SIZE);
    }

    // Feed Audio Recorder if active
    if (self.isRecording && _recordingFileHandle) {
        [self writeRecordingSamples:inputSamples count:numFrames];
    }
}

- (void)renderOutputBuffer:(AudioQueueBufferRef)outBuffer {
    float *outputSamples = (float *)outBuffer->mAudioData;
    NSInteger requestedFrames = outBuffer->mAudioDataBytesCapacity / (2 * sizeof(float));

    pthread_mutex_lock(&_ringMutex);

    NSInteger framesToCopy = MIN(requestedFrames, _ringAvailableFrames);
    for (NSInteger i = 0; i < framesToCopy; i++) {
        NSInteger idx = (_ringReadIndex % TX500_RING_BUFFER_CAPACITY) * 2;
        outputSamples[i * 2] = _ringBuffer[idx];
        outputSamples[i * 2 + 1] = _ringBuffer[idx + 1];
        _ringReadIndex++;
        _ringAvailableFrames--;
    }

    // Fill remaining with silence if underflow
    for (NSInteger i = framesToCopy; i < requestedFrames; i++) {
        outputSamples[i * 2] = 0.0f;
        outputSamples[i * 2 + 1] = 0.0f;
    }

    pthread_mutex_unlock(&_ringMutex);

    outBuffer->mAudioDataByteSize = (UInt32)(requestedFrames * 2 * sizeof(float));
}

#pragma mark - WAV Audio Recording

- (NSString *)recordingsDirectory {
    NSString *musicDir = [NSSearchPathForDirectoriesInDomains(NSMusicDirectory, NSUserDomainMask, YES) firstObject];
    NSString *tx500Dir = [musicDir stringByAppendingPathComponent:@"TX-500 Recordings"];
    [[NSFileManager defaultManager] createDirectoryAtPath:tx500Dir withIntermediateDirectories:YES attributes:nil error:nil];
    return tx500Dir;
}

- (BOOL)startRecordingWithError:(NSError **)error {
    if (self.isRecording) return YES;

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    NSString *filename = [NSString stringWithFormat:@"TX500_RadioAudio_%@.wav", [df stringFromDate:[NSDate date]]];
    NSString *fullPath = [[self recordingsDirectory] stringByAppendingPathComponent:filename];

    // Create empty file
    [[NSFileManager defaultManager] createFileAtPath:fullPath contents:[NSData data] attributes:nil];
    _recordingFileHandle = [NSFileHandle fileHandleForWritingAtPath:fullPath];
    if (!_recordingFileHandle) {
        if (error) {
            *error = [NSError errorWithDomain:@"TX500AudioErrorDomain" code:-1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Could not open file for writing."}];
        }
        return NO;
    }

    // Write placeholder 44-byte WAV header (16-bit PCM, 48kHz, Mono)
    uint8_t header[44];
    memset(header, 0, sizeof(header));
    memcpy(header, "RIFF", 4);
    memcpy(header + 8, "WAVEfmt ", 8);
    uint32_t fmtChunkSize = 16;
    uint16_t audioFormat = 1; // PCM
    uint16_t numChannels = 1; // Mono
    uint32_t sampleRate = (uint32_t)self.sampleRate;
    uint16_t bitsPerSample = 16;
    uint32_t byteRate = sampleRate * numChannels * (bitsPerSample / 8);
    uint16_t blockAlign = numChannels * (bitsPerSample / 8);

    memcpy(header + 16, &fmtChunkSize, 4);
    memcpy(header + 20, &audioFormat, 2);
    memcpy(header + 22, &numChannels, 2);
    memcpy(header + 24, &sampleRate, 4);
    memcpy(header + 28, &byteRate, 4);
    memcpy(header + 32, &blockAlign, 2);
    memcpy(header + 34, &bitsPerSample, 2);
    memcpy(header + 36, "data", 4);

    [_recordingFileHandle writeData:[NSData dataWithBytes:header length:44]];

    _recordedAudioDataBytes = 0;
    _recordingStartTime = [NSDate date];
    self.currentRecordingPath = fullPath;
    self.isRecording = YES;

    if (self.onRecordingStatusChanged) {
        self.onRecordingStatusChanged(YES, 0, fullPath);
    }
    return YES;
}

- (void)writeRecordingSamples:(const float *)samples count:(NSInteger)count {
    if (!_recordingFileHandle || count <= 0) return;

    // Convert float to 16-bit PCM
    NSMutableData *pcmData = [NSMutableData dataWithLength:count * sizeof(int16_t)];
    int16_t *pcm = (int16_t *)pcmData.mutableBytes;
    for (NSInteger i = 0; i < count; i++) {
        float s = samples[i];
        if (s > 1.0f) s = 1.0f;
        else if (s < -1.0f) s = -1.0f;
        pcm[i] = (int16_t)(s * 32767.0f);
    }

    [_recordingFileHandle writeData:pcmData];
    _recordedAudioDataBytes += (uint32_t)pcmData.length;
    self.recordingBytes = _recordedAudioDataBytes + 44;
    self.recordingDuration = [[NSDate date] timeIntervalSinceDate:_recordingStartTime];

    if (self.onRecordingStatusChanged) {
        self.onRecordingStatusChanged(YES, self.recordingDuration, self.currentRecordingPath);
    }
}

- (void)stopRecording {
    if (!self.isRecording || !_recordingFileHandle) return;
    self.isRecording = NO;

    // Finalize WAV Header: RIFF total size and data chunk size
    uint32_t riffSize = _recordedAudioDataBytes + 36;
    [_recordingFileHandle seekToFileOffset:4];
    [_recordingFileHandle writeData:[NSData dataWithBytes:&riffSize length:4]];

    [_recordingFileHandle seekToFileOffset:40];
    [_recordingFileHandle writeData:[NSData dataWithBytes:&_recordedAudioDataBytes length:4]];

    [_recordingFileHandle closeFile];
    _recordingFileHandle = nil;

    if (self.onRecordingStatusChanged) {
        self.onRecordingStatusChanged(NO, self.recordingDuration, self.currentRecordingPath);
    }
}

- (void)revealRecordingsInFinder {
    NSString *path = self.currentRecordingPath ?: [self recordingsDirectory];
    [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:[self recordingsDirectory]];
}

#pragma mark - Simulation Mode

- (void)startSimulation {
    if (self.isSimulationMode) return;
    self.isSimulationMode = YES;

    // Simulate 30fps audio frames into DSP
    __weak typeof(self) weakSelf = self;
    __block double phase = 0.0;
    self.simulationTimer = [NSTimer scheduledTimerWithTimeInterval:0.02 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isSimulationMode) return;

        NSInteger count = 960; // 20ms @ 48kHz
        float buffer[960];
        for (NSInteger i = 0; i < count; i++) {
            // Atmospheric white/pink noise
            float noise = (((float)rand() / (float)RAND_MAX) * 2.0f - 1.0f) * 0.08f;
            // Modulated 800 Hz radio carrier
            phase += 2.0 * M_PI * 800.0 / 48000.0;
            if (phase > 2.0 * M_PI) phase -= 2.0 * M_PI;
            float tone = (float)sin(phase) * 0.25f;
            buffer[i] = noise + tone;
        }

        [strongSelf processRawAudioSamples:buffer count:count];
    }];
}

- (void)stopSimulation {
    self.isSimulationMode = NO;
    [self.simulationTimer invalidate];
    self.simulationTimer = nil;
}

@end
