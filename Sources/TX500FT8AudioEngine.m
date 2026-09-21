//
//  TX500FT8AudioEngine.m
//  Lab599 Utility
//
//  Real-Time CoreAudio Slot-Synchronized DSP Engine for FT8
//

#import "TX500FT8AudioEngine.h"
#import <math.h>
#import <mach/mach_time.h>

#define FT8_SAMPLE_RATE 12000
#define FT8_SLOT_SECONDS 15.0
#define FT8_TX_SECONDS 14.5
#define FT8_MAX_SLOT_SAMPLES (FT8_SAMPLE_RATE * 15)
#define FT8_WATERFALL_BINS 256

#define TX500_FT8_FFT_SIZE 1024

@interface TX500FT8AudioEngine () {
    AudioQueueRef _inputQueue;
    AudioQueueRef _outputQueue;
    AudioQueueBufferRef _inputBuffers[4];
    AudioQueueBufferRef _outputBuffers[4];

    // Receive slot audio buffer (mono float)
    float *_rxBuffer;
    int _rxBufferCount;
    NSLock *_rxBufferLock;

    // Transmit synthesized audio buffer
    float *_txBuffer;
    int _txBufferTotalSamples;
    int _txBufferReadIndex;
    NSLock *_txBufferLock;

    // Waterfall FFT buffer & live audio circular buffer
    float *_waterfallMag;
    float _liveWaterBuffer[2048];
    int _liveWaterHead;
    NSLock *_liveWaterLock;
    float _liveNoiseFloorDb;

    // High precision slot clock
    dispatch_source_t _slotTimer;
    double _lastSlotSecond;
    BOOL _slotDecodeDispatched;

    // Tone / Carrier Mode
    BOOL _isTuning;
    double _carrierPhase;

    // Simulated Station Tracking
    NSInteger _simQSOStage;
    NSString *_simPartnerCall;
    NSString *_simPartnerGrid;
    int _simPartnerReport;
    double _simLastActionTime;

    // Auto parity lock: -1 = unlocked, 0 = even, 1 = odd
    NSInteger _autoParityLocked;

    // SWR monitoring
    double _lastSWRReading;
    dispatch_source_t _swrPollTimer;
}

@property (nonatomic, strong, readwrite) NSMutableArray<NSDictionary<NSString *, NSString *> *> *internalInputDevices;
@property (nonatomic, strong, readwrite) NSMutableArray<NSDictionary<NSString *, NSString *> *> *internalOutputDevices;
@property (nonatomic, assign, readwrite) BOOL isMonitoring;
@property (nonatomic, assign, readwrite) BOOL isTransmitting;
@property (nonatomic, assign, readwrite) double currentSlotSecond;
@property (nonatomic, assign, readwrite) NSInteger currentSlotParity;
@property (nonatomic, assign, readwrite) double slotProgressFraction;

- (void)appendIncomingAudioSamples:(const float *)samples count:(NSInteger)count;
- (void)renderOutgoingAudioSamples:(float *)samples count:(UInt32)count;

@end

// Fast Radix-2 FFT for Waterfall Spectrum Display
static void TX500FT8ComputeFFT(const float *realIn, float *magnitudesOut, int n) {
    float real[TX500_FT8_FFT_SIZE];
    float imag[TX500_FT8_FFT_SIZE];

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

    // Cooley-Tukey Radix-2 FFT
    for (int len = 2; len <= n; len <<= 1) {
        float angle = -2.0f * (float)M_PI / (float)len;
        float wlen_r = cosf(angle);
        float wlen_i = sinf(angle);
        for (int i = 0; i < n; i += len) {
            float w_r = 1.0f;
            float w_i = 0.0f;
            int half = len >> 1;
            for (int k = 0; k < half; k++) {
                float u_r = real[i + k];
                float u_i = imag[i + k];
                float v_r = real[i + k + half] * w_r - imag[i + k + half] * w_i;
                float v_i = real[i + k + half] * w_i + imag[i + k + half] * w_r;
                real[i + k] = u_r + v_r;
                imag[i + k] = u_i + v_i;
                real[i + k + half] = u_r - v_r;
                imag[i + k + half] = u_i - v_i;
                float next_w_r = w_r * wlen_r - w_i * wlen_i;
                float next_w_i = w_r * wlen_i + w_i * wlen_r;
                w_r = next_w_r;
                w_i = next_w_i;
            }
        }
    }

    int halfN = n / 2;
    for (int i = 0; i < halfN; i++) {
        float mag = sqrtf(real[i] * real[i] + imag[i] * imag[i]) / (float)n;
        magnitudesOut[i] = mag;
    }
}

// AudioQueue Callbacks
static void FT8AudioQueueInputCallback(void *inUserData,
                                       AudioQueueRef inAQ,
                                       AudioQueueBufferRef inBuffer,
                                       const AudioTimeStamp *inStartTime,
                                       UInt32 inNumberPacketDescriptions,
                                       const AudioStreamPacketDescription *inPacketDescs) {
    (void)inStartTime;
    (void)inNumberPacketDescriptions;
    (void)inPacketDescs;
    TX500FT8AudioEngine *engine = (__bridge TX500FT8AudioEngine *)inUserData;
    if (!engine || !engine.isMonitoring) return;

    const float *samples = (const float *)inBuffer->mAudioData;
    UInt32 frameCount = inBuffer->mAudioDataByteSize / sizeof(float);

    if (frameCount > 0 && samples) {
        [engine appendIncomingAudioSamples:samples count:frameCount];
    }

    if (engine.isMonitoring && inAQ) {
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    }
}

static void FT8AudioQueueOutputCallback(void *inUserData,
                                        AudioQueueRef inAQ,
                                        AudioQueueBufferRef inBuffer) {
    TX500FT8AudioEngine *engine = (__bridge TX500FT8AudioEngine *)inUserData;
    if (!engine) return;

    UInt32 maxFrames = inBuffer->mAudioDataBytesCapacity / sizeof(float);
    float *samples = (float *)inBuffer->mAudioData;
    [engine renderOutgoingAudioSamples:samples count:maxFrames];
    inBuffer->mAudioDataByteSize = maxFrames * sizeof(float);

    if (inAQ) {
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    }
}

@implementation TX500FT8AudioEngine

- (instancetype)init {
    self = [super init];
    if (self) {
        NSString *savedCall = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_OperatorCallsign"];
        _myCallsign = (savedCall.length > 0) ? savedCall : @"EP2AES";

        NSString *savedGrid = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_OperatorGrid"];
        _myGrid = (savedGrid.length > 0) ? savedGrid : @"KM35";

        _dialFrequencyHz = 14074000;
        _rxAudioFrequencyHz = 1200.0f;
        _txAudioFrequencyHz = 1500.0f;
        _lockTxRxFrequencies = NO;
        _txSlotParity = TX500FT8SlotParityEven;
        _isTransmitArmed = NO;
        _isSimulationMode = [[NSUserDefaults standardUserDefaults] boolForKey:@"TX500_FT8_SimulationModeEnabled"];

        _rxBuffer = (float *)calloc(FT8_MAX_SLOT_SAMPLES, sizeof(float));
        _rxBufferCount = 0;
        _rxBufferLock = [[NSLock alloc] init];

        _txBuffer = (float *)calloc(FT8_MAX_SLOT_SAMPLES, sizeof(float));
        _txBufferTotalSamples = 0;
        _txBufferReadIndex = 0;
        _txBufferLock = [[NSLock alloc] init];

        _waterfallMag = (float *)calloc(FT8_WATERFALL_BINS, sizeof(float));
        memset(_liveWaterBuffer, 0, sizeof(_liveWaterBuffer));
        _liveWaterHead = 0;
        _liveWaterLock = [[NSLock alloc] init];

        _internalInputDevices = [NSMutableArray array];
        _internalOutputDevices = [NSMutableArray array];
        [self refreshAudioDevices];

        for (NSDictionary *dev in _internalInputDevices) {
            if ([dev[@"isAD508"] isEqualToString:@"YES"]) {
                _selectedInputDeviceUID = dev[@"uid"];
                break;
            }
        }
        for (NSDictionary *dev in _internalOutputDevices) {
            if ([dev[@"isAD508"] isEqualToString:@"YES"]) {
                _selectedOutputDeviceUID = dev[@"uid"];
                break;
            }
        }
        _liveNoiseFloorDb = -80.0f;
    }
    return self;
}

- (void)setIsSimulationMode:(BOOL)isSimulationMode {
    if (_isSimulationMode == isSimulationMode) return;
    _isSimulationMode = isSimulationMode;
    if (self.isMonitoring) {
        if (_isSimulationMode) {
            [self teardownAudioHardware];
        } else {
            [self setupAudioHardware:nil];
        }
    }
}

- (void)dealloc {
    [self stopMonitoring];
    [self teardownAudioHardware];
    if (_rxBuffer) { free(_rxBuffer); _rxBuffer = NULL; }
    if (_txBuffer) { free(_txBuffer); _txBuffer = NULL; }
    if (_waterfallMag) { free(_waterfallMag); _waterfallMag = NULL; }
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)inputDevices {
    return [self.internalInputDevices copy];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)outputDevices {
    return [self.internalOutputDevices copy];
}

- (void)refreshAudioDevices {
    [self.internalInputDevices removeAllObjects];
    [self.internalOutputDevices removeAllObjects];

    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) == noErr) {
        int count = size / sizeof(AudioDeviceID);
        AudioDeviceID *devs = (AudioDeviceID *)malloc(size);
        if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devs) == noErr) {
            for (int i = 0; i < count; i++) {
                AudioDeviceID devID = devs[i];

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

                BOOL isAD508 = [name.lowercaseString containsString:@"usb audio"] ||
                               [name.lowercaseString containsString:@"ttgk"] ||
                               [name.lowercaseString containsString:@"ad-508"] ||
                               [name.lowercaseString containsString:@"ad-509"] ||
                               [name.lowercaseString containsString:@"c-media"] ||
                               [name.lowercaseString containsString:@"tx-500"];

                // Input
                AudioObjectPropertyAddress inAddr = {
                    kAudioDevicePropertyStreams,
                    kAudioDevicePropertyScopeInput,
                    kAudioObjectPropertyElementMain
                };
                UInt32 inStreamSize = 0;
                if (AudioObjectGetPropertyDataSize(devID, &inAddr, 0, NULL, &inStreamSize) == noErr && inStreamSize > 0) {
                    [self.internalInputDevices addObject:@{
                        @"name": name,
                        @"uid": uid,
                        @"isAD508": isAD508 ? @"YES" : @"NO"
                    }];
                    if (isAD508 && !_selectedInputDeviceUID) {
                        _selectedInputDeviceUID = uid;
                        _isAD508InputConnected = YES;
                    }
                }

                // Output
                AudioObjectPropertyAddress outAddr = {
                    kAudioDevicePropertyStreams,
                    kAudioDevicePropertyScopeOutput,
                    kAudioObjectPropertyElementMain
                };
                UInt32 outStreamSize = 0;
                if (AudioObjectGetPropertyDataSize(devID, &outAddr, 0, NULL, &outStreamSize) == noErr && outStreamSize > 0) {
                    [self.internalOutputDevices addObject:@{
                        @"name": name,
                        @"uid": uid,
                        @"isAD508": isAD508 ? @"YES" : @"NO"
                    }];
                    if (isAD508 && !_selectedOutputDeviceUID) {
                        _selectedOutputDeviceUID = uid;
                        _isAD508OutputConnected = YES;
                    }
                }
            }
        }
        free(devs);
    }

    if (self.onAudioDevicesChanged) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onAudioDevicesChanged) self.onAudioDevicesChanged();
        });
    }
}

#pragma mark - Monitoring & Slot Timer

- (BOOL)startMonitoring:(NSError **)error {
    if (self.isMonitoring) return YES;

    // Ensure radio mode is set to DIG
    if (self.serialCommandSender) {
        self.serialCommandSender(@"MD6;");
    }

    // Set up slot synchronization timer (fired every 40ms)
    __weak typeof(self) weakSelf = self;
    _slotTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_slotTimer, DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC, 5 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_slotTimer, ^{
        [weakSelf processSlotTick];
    });
    dispatch_resume(_slotTimer);

    // Setup CoreAudio Units if not pure simulation
    if (!_isSimulationMode) {
        [self setupAudioHardware:error];
    }

    self.isMonitoring = YES;
    if (self.logHandler) {
        self.logHandler(@"[FT8 Engine] Monitoring started. UTC 15-second slot synchronized.");
    }
    return YES;
}

- (void)stopMonitoring {
    if (!self.isMonitoring) return;

    if (_isTransmitting) {
        [self endTransmission];
    }

    if (_slotTimer) {
        dispatch_source_cancel(_slotTimer);
        _slotTimer = nil;
    }

    [self teardownAudioHardware];
    self.isMonitoring = NO;

    if (self.logHandler) {
        self.logHandler(@"[FT8 Engine] Monitoring stopped.");
    }
}

- (void)setupAudioHardware:(NSError **)error {
    (void)error;
    [self teardownAudioHardware];

    // Audio format: 12000 Hz 32-bit Float Mono
    AudioStreamBasicDescription inFormat;
    memset(&inFormat, 0, sizeof(inFormat));
    inFormat.mSampleRate = FT8_SAMPLE_RATE;
    inFormat.mFormatID = kAudioFormatLinearPCM;
    inFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    inFormat.mBytesPerPacket = 4;
    inFormat.mFramesPerPacket = 1;
    inFormat.mBytesPerFrame = 4;
    inFormat.mChannelsPerFrame = 1; // Mono
    inFormat.mBitsPerChannel = 32;

    OSStatus st = AudioQueueNewInput(&inFormat, FT8AudioQueueInputCallback, (__bridge void *)self,
                                     NULL, NULL, 0, &_inputQueue);
    if (st != noErr) {
        if (self.logHandler) {
            self.logHandler([NSString stringWithFormat:@"[Audio Error] AudioQueueNewInput failed: %d", (int)st]);
        }
        return;
    }

    // Set selected device if specified
    if (self.selectedInputDeviceUID && self.selectedInputDeviceUID.length > 0 &&
        ![self.selectedInputDeviceUID isEqualToString:@"default"]) {
        CFStringRef uidRef = (__bridge CFStringRef)self.selectedInputDeviceUID;
        AudioQueueSetProperty(_inputQueue, kAudioQueueProperty_CurrentDevice, &uidRef, sizeof(uidRef));
    }

    // Allocate 4 buffers of 1200 frames (100ms each at 12 kHz)
    UInt32 bufferByteSize = 1200 * sizeof(float);
    for (int i = 0; i < 4; i++) {
        AudioQueueAllocateBuffer(_inputQueue, bufferByteSize, &_inputBuffers[i]);
        if (_inputBuffers[i]) {
            AudioQueueEnqueueBuffer(_inputQueue, _inputBuffers[i], 0, NULL);
        }
    }

    st = AudioQueueStart(_inputQueue, NULL);
    if (st != noErr && self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[Audio Error] AudioQueueStart input failed: %d", (int)st]);
    }

    // 2. Setup Output Queue for soundcard transmission (AD-508 audio out / DATA in)
    AudioStreamBasicDescription outFormat = inFormat;
    st = AudioQueueNewOutput(&outFormat, FT8AudioQueueOutputCallback, (__bridge void *)self,
                             NULL, NULL, 0, &_outputQueue);
    if (st == noErr && _outputQueue) {
        if (self.selectedOutputDeviceUID && self.selectedOutputDeviceUID.length > 0 &&
            ![self.selectedOutputDeviceUID isEqualToString:@"default"]) {
            CFStringRef outUidRef = (__bridge CFStringRef)self.selectedOutputDeviceUID;
            AudioQueueSetProperty(_outputQueue, kAudioQueueProperty_CurrentDevice, &outUidRef, sizeof(outUidRef));
        }

        for (int i = 0; i < 4; i++) {
            AudioQueueAllocateBuffer(_outputQueue, bufferByteSize, &_outputBuffers[i]);
            if (_outputBuffers[i]) {
                memset(_outputBuffers[i]->mAudioData, 0, bufferByteSize);
                _outputBuffers[i]->mAudioDataByteSize = bufferByteSize;
                AudioQueueEnqueueBuffer(_outputQueue, _outputBuffers[i], 0, NULL);
            }
        }
        AudioQueueStart(_outputQueue, NULL);
    }
}

- (void)teardownAudioHardware {
    if (_inputQueue) {
        AudioQueueStop(_inputQueue, true);
        AudioQueueDispose(_inputQueue, true);
        _inputQueue = NULL;
    }
    if (_outputQueue) {
        AudioQueueStop(_outputQueue, true);
        AudioQueueDispose(_outputQueue, true);
        _outputQueue = NULL;
    }
}

- (void)restartAudioHardware {
    if (!self.isMonitoring) return;
    if (!self.isSimulationMode) {
        [self setupAudioHardware:nil];
    }
}

#pragma mark - Slot Timing Engine

- (void)processSlotTick {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    double slotSec = fmod(now, FT8_SLOT_SECONDS);
    NSInteger parity = ((NSInteger)(now / FT8_SLOT_SECONDS)) % 2; // 0=Even (:00,:30), 1=Odd (:15,:45)

    self.currentSlotSecond = slotSec;
    self.currentSlotParity = parity;
    self.slotProgressFraction = slotSec / FT8_SLOT_SECONDS;

    // Detect slot transition (crossing 0.0s)
    if (_lastSlotSecond > 13.0 && slotSec < 1.0) {
        _slotDecodeDispatched = NO;

        // Reset RX buffer for new slot
        [_rxBufferLock lock];
        _rxBufferCount = 0;
        [_rxBufferLock unlock];

        NSTimeInterval slotStartEpoch = now - slotSec;
        NSDate *utcSlotDate = [NSDate dateWithTimeIntervalSince1970:slotStartEpoch];

        if (self.onSlotTransition) {
            self.onSlotTransition(parity, utcSlotDate);
        }

        // Check if transmission is scheduled on this slot parity
        BOOL parityMatches;
        if (self.txSlotParity == TX500FT8SlotParityAuto) {
            // Auto: pick the slot parity on first TX, then alternate (TX only every other slot)
            if (_autoParityLocked < 0) {
                // Not yet locked - lock to current parity now
                _autoParityLocked = parity;
            }
            parityMatches = (_autoParityLocked == parity);
        } else {
            parityMatches = (self.txSlotParity == (TX500FT8SlotParity)parity);
        }

        if (self.isTransmitArmed && parityMatches && self.queuedTxMessage.length > 0) {
            [self beginTransmission];
        }
    }

    _lastSlotSecond = slotSec;

    // End Transmission at 12.64s
    if (_isTransmitting && slotSec >= FT8_TX_SECONDS) {
        [self endTransmission];
    }

    // Trigger Slot Decode at 13.5s
    if (!_isTransmitting && !_slotDecodeDispatched && slotSec >= 13.5) {
        _slotDecodeDispatched = YES;
        [self triggerSlotDecodeWithParity:parity];
    }

    // Feed Waterfall Spectrum updates (smooth visual cascade)
    [self updateWaterfallStream];

    if (self.onSlotTick) {
        self.onSlotTick(slotSec, parity, self.slotProgressFraction);
    }
}

#pragma mark - Decode Pipeline

- (void)triggerSlotDecodeWithParity:(NSInteger)parity {
    if (self.isSimulationMode) {
        [self executeSimulationDecodeForParity:parity];
        return;
    }

    // Capture snapshot of incoming audio
    [_rxBufferLock lock];
    int sampleCount = _rxBufferCount;
    if (sampleCount < FT8_SAMPLE_RATE * 8) {
        // Less than 8s of audio recorded
        [_rxBufferLock unlock];
        return;
    }

    float *snapshot = (float *)malloc(sampleCount * sizeof(float));
    memcpy(snapshot, _rxBuffer, sampleCount * sizeof(float));
    [_rxBufferLock unlock];

    NSString *myCall = self.myCallsign;
    NSString *myGrid = self.myGrid;
    __weak typeof(self) weakSelf = self;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval slotStartEpoch = floor(now / 15.0) * 15.0;
    NSDate *slotDate = [NSDate dateWithTimeIntervalSince1970:slotStartEpoch];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        tx500_ft8_decoded_t results[100];
        int numDecoded = tx500_ft8_decode_samples(snapshot, sampleCount, FT8_SAMPLE_RATE,
                                                  TX500_FT8_PROTOCOL_FT8, results, 100);
        free(snapshot);

        NSMutableArray<TX500FT8Message *> *messages = [NSMutableArray array];
        for (int i = 0; i < numDecoded; i++) {
            NSString *raw = [NSString stringWithUTF8String:results[i].text];
            if (raw.length > 0) {
                TX500FT8Message *msg = [TX500FT8Message messageWithRawText:raw
                                                                    freqHz:results[i].freq_hz
                                                                     snrDb:results[i].snr_db
                                                                        dt:results[i].time_sec
                                                                  slotDate:slotDate
                                                                slotParity:parity
                                                                    myCall:myCall
                                                                    myGrid:myGrid];
                [messages addObject:msg];
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                [strongSelf logDecodedMessagesToADIF:messages];
                if (strongSelf.onDecodedMessages) {
                    strongSelf.onDecodedMessages(messages, parity);
                }
            }
        });
    });
}

#pragma mark - Continuous ADIF Logging

+ (NSString *)allDecodesADIFPath {
    NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [appSupport stringByAppendingPathComponent:@"Lab599 Utility/FT8"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
    return [dir stringByAppendingPathComponent:@"FT8_ALL_DECODES.adi"];
}

- (void)logDecodedMessagesToADIF:(NSArray<TX500FT8Message *> *)messages {
    if (messages.count == 0) return;
    id enabledVal = [[NSUserDefaults standardUserDefaults] objectForKey:@"TX500_AutoLogDecodes"];
    if (enabledVal != nil && ![enabledVal boolValue]) return;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *filePath = [TX500FT8AudioEngine allDecodesADIFPath];
        if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            NSString *header = @"FT8 All Decodes Log - Lab599 Utility for Discovery TX-500\n<ADIF_VER:5>3.1.4\n<PROGRAMID:14>Lab599 Utility\n<EOH>\n\n";
            [header writeToFile:filePath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }

        NSDateFormatter *dateFmt = [[NSDateFormatter alloc] init];
        dateFmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        dateFmt.dateFormat = @"yyyyMMdd";

        NSDateFormatter *timeFmt = [[NSDateFormatter alloc] init];
        timeFmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        timeFmt.dateFormat = @"HHmmss";

        NSMutableString *buffer = [NSMutableString string];
        for (TX500FT8Message *m in messages) {
            NSString *call = m.callerCall ?: @"";
            if (call.length == 0) continue;
            NSDate *d = m.timestamp ?: [NSDate date];
            NSString *qsoDate = [dateFmt stringFromDate:d];
            NSString *timeOn = [timeFmt stringFromDate:d];
            double freqMhz = (double)(self.dialFrequencyHz + (long)m.freqHz) / 1000000.0;
            NSString *freqStr = [NSString stringWithFormat:@"%.6f", freqMhz];
            int snrVal = (int)roundf(m.snrDb);
            NSString *rstStr = [NSString stringWithFormat:@"%+d", snrVal];

            [buffer appendFormat:@"<CALL:%lu>%@", (unsigned long)call.length, call];
            [buffer appendFormat:@" <QSO_DATE:%lu>%@", (unsigned long)qsoDate.length, qsoDate];
            [buffer appendFormat:@" <TIME_ON:%lu>%@", (unsigned long)timeOn.length, timeOn];
            [buffer appendFormat:@" <FREQ:%lu>%@", (unsigned long)freqStr.length, freqStr];
            [buffer appendString:@" <MODE:3>FT8"];
            [buffer appendFormat:@" <RST_RCVD:%lu>%@", (unsigned long)rstStr.length, rstStr];
            if (m.grid.length >= 4) {
                [buffer appendFormat:@" <GRIDSQUARE:%lu>%@", (unsigned long)m.grid.length, m.grid];
            }
            if (m.rawText.length > 0) {
                [buffer appendFormat:@" <COMMENT:%lu>%@", (unsigned long)m.rawText.length, m.rawText];
            }
            [buffer appendString:@" <EOR>\n"];
        }

        if (buffer.length > 0) {
            NSData *data = [buffer dataUsingEncoding:NSUTF8StringEncoding];
            NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:filePath];
            if (handle) {
                [handle seekToEndOfFile];
                [handle writeData:data];
                [handle closeFile];
            }
        }
    });
}

#pragma mark - Transmit Path & Audio Synthesis

- (void)armTransmitWithText:(NSString *)text parity:(TX500FT8SlotParity)parity {
    self.queuedTxMessage = text;
    self.txSlotParity = parity;
    self.isTransmitArmed = YES;
    _autoParityLocked = -1; // Reset so next transition locks the parity

    if (self.logHandler) {
        NSString *pName = (parity == TX500FT8SlotParityEven) ? @"Even (:00/:30)" :
                          (parity == TX500FT8SlotParityOdd) ? @"Odd (:15/:45)" : @"Auto";
        self.logHandler([NSString stringWithFormat:@"[FT8 Transmit Armed] Msg: '%@' on Slot %@", text, pName]);
    }
}

- (void)disarmTransmit {
    self.isTransmitArmed = NO;
    _autoParityLocked = -1;
    if (_isTransmitting) {
        [self endTransmission];
    }
    if (self.logHandler) {
        self.logHandler(@"[FT8 Transmit Disarmed]");
    }
}

- (void)beginTransmission {
    if (self.queuedTxMessage.length == 0) return;

    NSString *msgText = [self.queuedTxMessage uppercaseString];
    unsigned char tones[FT8808_MAX_TONES];
    int numTones = tx500_ft8_encode_message([msgText UTF8String], TX500_FT8_PROTOCOL_FT8, tones, FT8808_MAX_TONES);
    if (numTones <= 0) {
        if (self.logHandler) {
            self.logHandler([NSString stringWithFormat:@"[FT8 Error] Failed to encode text: '%@'", msgText]);
        }
        return;
    }

    [_txBufferLock lock];
    _txBufferTotalSamples = tx500_ft8_synthesize(tones, numTones, self.txAudioFrequencyHz,
                                                 TX500_FT8_PROTOCOL_FT8, FT8_SAMPLE_RATE,
                                                 _txBuffer, FT8_MAX_SLOT_SAMPLES);
    _txBufferReadIndex = 0;
    [_txBufferLock unlock];

    _isTransmitting = YES;
    _lastSWRReading = 0.0;

    // Send CAT commands: Set DIG mode and key PTT TX
    if (self.serialCommandSender) {
        self.serialCommandSender(@"MD6;");
        self.serialCommandSender(@"TX;");
    }

    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[FT8 TX ON] Sending '%@' at %.0f Hz (CAT: MD6; TX;)",
                         msgText, self.txAudioFrequencyHz]);
    }

    if (self.onTransmitStateChanged) {
        self.onTransmitStateChanged(YES, msgText);
    }

    // Start SWR polling (every 2s during TX) — sends RM; CAT query
    __weak typeof(self) weakSelf = self;
    if (_swrPollTimer) {
        dispatch_source_cancel(_swrPollTimer);
        _swrPollTimer = nil;
    }
    if (self.serialCommandSender && self.maxSWRThreshold > 0.0) {
        _swrPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(_swrPollTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                                  2 * NSEC_PER_SEC, 500 * NSEC_PER_MSEC);
        dispatch_source_set_event_handler(_swrPollTimer, ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf || !strongSelf->_isTransmitting) return;
            // TX-500 SWR via RM;: response is RM<SWR*10 padded 3 digits>;
            // We approximate by reading power meter. Real SWR would need parsing.
            // For now, simulate SWR near 1.0 in simulation mode; in real mode request RM;
            if (strongSelf.isSimulationMode) {
                double simSWR = 1.0 + ((double)(arc4random_uniform(30)) / 100.0); // 1.0 to 1.30
                strongSelf->_lastSWRReading = simSWR;
                if (strongSelf.onSWRUpdated) strongSelf.onSWRUpdated(simSWR);
            } else {
                if (strongSelf.serialCommandSender) {
                    strongSelf.serialCommandSender(@"RM;"); // Request meter reading
                }
                // Note: parsed SWR response is handled by StationController via CAT parser
            }
        });
        dispatch_resume(_swrPollTimer);
    }
}

- (void)endTransmission {
    if (!_isTransmitting) return;

    _isTransmitting = NO;
    [_txBufferLock lock];
    _txBufferTotalSamples = 0;
    _txBufferReadIndex = 0;
    [_txBufferLock unlock];

    // Stop SWR polling
    if (_swrPollTimer) {
        dispatch_source_cancel(_swrPollTimer);
        _swrPollTimer = nil;
    }

    // Assert CAT PTT RX
    if (self.serialCommandSender) {
        self.serialCommandSender(@"RX;");
    }

    if (self.logHandler) {
        self.logHandler(@"[FT8 TX OFF] Transmission complete. Returned to RX (CAT: RX;)");
    }

    if (self.onTransmitStateChanged) {
        self.onTransmitStateChanged(NO, @"");
    }
}

- (double)lastSWRReading {
    return _lastSWRReading;
}


#pragma mark - Carrier Tune Mode

- (void)startTuneCarrier {
    _isTuning = YES;
    _carrierPhase = 0.0;
    if (self.serialCommandSender) {
        self.serialCommandSender(@"MD6;");
        self.serialCommandSender(@"TX;");
    }
    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[Tune Carrier] Tone at %.0f Hz started (CAT: TX;)", self.txAudioFrequencyHz]);
    }
}

- (void)stopTuneCarrier {
    if (!_isTuning) return;
    _isTuning = NO;
    if (self.serialCommandSender) {
        self.serialCommandSender(@"RX;");
    }
    if (self.logHandler) {
        self.logHandler(@"[Tune Carrier] Tone stopped (CAT: RX;)");
    }
}

#pragma mark - Audio Samples Processing

- (void)appendIncomingAudioSamples:(const float *)samples count:(NSInteger)count {
    // 1. Append to slot decode buffer
    [_rxBufferLock lock];
    int available = FT8_MAX_SLOT_SAMPLES - _rxBufferCount;
    int toCopy = MIN((int)count, available);
    if (toCopy > 0) {
        memcpy(_rxBuffer + _rxBufferCount, samples, toCopy * sizeof(float));
        _rxBufferCount += toCopy;
    }
    [_rxBufferLock unlock];

    // 2. Append to circular waterfall FIFO buffer
    [_liveWaterLock lock];
    for (NSInteger i = 0; i < count; i++) {
        _liveWaterBuffer[_liveWaterHead] = samples[i];
        _liveWaterHead = (_liveWaterHead + 1) % 2048;
    }
    [_liveWaterLock unlock];
}

- (void)renderOutgoingAudioSamples:(float *)samples count:(UInt32)count {
    if (_isTuning) {
        double freq = self.txAudioFrequencyHz;
        double phaseInc = 2.0 * M_PI * freq / (double)FT8_SAMPLE_RATE;
        for (UInt32 i = 0; i < count; i++) {
            samples[i] = 0.6f * (float)sin(_carrierPhase);
            _carrierPhase += phaseInc;
            if (_carrierPhase > 2.0 * M_PI) _carrierPhase -= 2.0 * M_PI;
        }
        return;
    }

    [_txBufferLock lock];
    if (!_isTransmitting || _txBufferReadIndex >= _txBufferTotalSamples) {
        memset(samples, 0, count * sizeof(float));
        [_txBufferLock unlock];
        return;
    }

    int remaining = _txBufferTotalSamples - _txBufferReadIndex;
    int toCopy = MIN((int)count, remaining);
    memcpy(samples, _txBuffer + _txBufferReadIndex, toCopy * sizeof(float));
    _txBufferReadIndex += toCopy;

    if (toCopy < (int)count) {
        memset(samples + toCopy, 0, (count - toCopy) * sizeof(float));
    }
    [_txBufferLock unlock];
}

#pragma mark - Real-Time Waterfall Stream

- (void)updateWaterfallStream {
    if (!self.isSimulationMode) {
        // Copy latest 1024 samples from live waterfall circular buffer
        float fftIn[TX500_FT8_FFT_SIZE];
        [_liveWaterLock lock];
        int head = _liveWaterHead;
        for (int i = 0; i < TX500_FT8_FFT_SIZE; i++) {
            int idx = (head - TX500_FT8_FFT_SIZE + i + 2048) % 2048;
            fftIn[i] = _liveWaterBuffer[idx];
        }
        [_liveWaterLock unlock];

        // Measure RMS level
        float rms = 0.0f;
        for (int i = 0; i < TX500_FT8_FFT_SIZE; i++) {
            rms += fftIn[i] * fftIn[i];
        }
        rms = sqrtf(rms / (float)TX500_FT8_FFT_SIZE);

        if (rms > 1e-6f) {
            float mags[TX500_FT8_FFT_SIZE / 2];
            TX500FT8ComputeFFT(fftIn, mags, TX500_FT8_FFT_SIZE);

            float sumDb = 0.0f;
            float binDb[FT8_WATERFALL_BINS];
            for (int i = 0; i < FT8_WATERFALL_BINS; i++) {
                float raw = mags[i];
                float db = 20.0f * log10f(raw + 1e-7f);
                binDb[i] = db;
                sumDb += db;
            }
            float avgDb = sumDb / (float)FT8_WATERFALL_BINS;
            if (_liveNoiseFloorDb < -120.0f || _liveNoiseFloorDb > 0.0f) {
                _liveNoiseFloorDb = avgDb;
            } else {
                _liveNoiseFloorDb = _liveNoiseFloorDb * 0.96f + avgDb * 0.04f;
            }

            // Bins 0..255 cover 0 to 3000 Hz at 12 kHz (each bin = 11.72 Hz)
            for (int i = 0; i < FT8_WATERFALL_BINS; i++) {
                float snr = binDb[i] - _liveNoiseFloorDb;
                // Dynamic contrast mapping:
                // noise at 0 dB SNR maps to ~0.12 (soft dark visible floor)
                // signal at +6 dB maps to 0.32 (vivid amber)
                // signal at +12 dB maps to 0.52 (strong orange/red)
                // signal at +25 dB maps to 0.95 (bright white/crimson)
                float norm = (snr + 4.0f) / 30.0f;
                norm = fmaxf(0.06f, fminf(1.0f, norm));

                // Highlight TX tone if transmitting or tuning
                if (_isTransmitting || _isTuning) {
                    float binFreq = (float)i / (float)FT8_WATERFALL_BINS * 3000.0f;
                    if (fabsf(binFreq - self.txAudioFrequencyHz) < 30.0f) {
                        norm = 1.0f;
                    }
                }

                _waterfallMag[i] = _waterfallMag[i] * 0.35f + norm * 0.65f;
            }
        } else {
            // Baseline noise floor so waterfall remains visibly active
            for (int i = 0; i < FT8_WATERFALL_BINS; i++) {
                float noise = ((float)(rand() % 100)) / 100.0f * 0.05f + 0.07f;
                _waterfallMag[i] = _waterfallMag[i] * 0.5f + noise * 0.5f;
            }
        }
    } else {
        // Simulation mode: emulate realistic FT8 traffic across bins
        for (int i = 0; i < FT8_WATERFALL_BINS; i++) {
            float noise = ((float)(rand() % 100)) / 100.0f * 0.12f + 0.08f;
            float binFreq = (float)i / (float)FT8_WATERFALL_BINS * 3000.0f;
            float bandFilter = 1.0f;
            if (binFreq < 250.0f) bandFilter = binFreq / 250.0f;
            if (binFreq > 2800.0f) bandFilter = MAX(0.0f, 1.0f - (binFreq - 2800.0f) / 200.0f);

            float sig = 0.0f;
            if (fabs(binFreq - 650.0f) < 25.0f) sig += 0.55f;
            if (fabs(binFreq - 1100.0f) < 25.0f) sig += 0.85f;
            if (fabs(binFreq - 1450.0f) < 25.0f) sig += 0.45f;
            if (fabs(binFreq - 1820.0f) < 25.0f) sig += 0.65f;
            if (fabs(binFreq - 2240.0f) < 25.0f) sig += 0.40f;

            if (_isTransmitting || _isTuning) {
                if (fabs(binFreq - self.txAudioFrequencyHz) < 30.0f) {
                    sig = 1.0f;
                }
            }

            float mag = (noise + sig) * bandFilter;
            _waterfallMag[i] = _waterfallMag[i] * 0.7f + mag * 0.3f;
        }
    }

    if (self.onSpectrumUpdated) {
        self.onSpectrumUpdated(_waterfallMag, FT8_WATERFALL_BINS);
    }
}

#pragma mark - Simulation Mode Signals

- (void)executeSimulationDecodeForParity:(NSInteger)parity {
    NSMutableArray<TX500FT8Message *> *messages = [NSMutableArray array];
    NSString *myCall = self.myCallsign;
    NSString *myGrid = self.myGrid;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    NSTimeInterval slotStartEpoch = floor(now / 15.0) * 15.0;
    NSDate *slotDate = [NSDate dateWithTimeIntervalSince1970:slotStartEpoch];

    // Rich catalog of realistic global DX stations calling CQ or working
    NSArray *candidates = @[
        @{@"t": @"CQ BG0FQU OL40",   @"f": @(540),  @"snr": @(-3),  @"dt": @(0.1)},
        @{@"t": @"CQ II4IANT JN54",  @"f": @(780),  @"snr": @(+4),  @"dt": @(-0.1)},
        @{@"t": @"CQ PH02LIB JO22",  @"f": @(1050), @"snr": @(+1),  @"dt": @(0.2)},
        @{@"t": @"CQ MI7JUX IO64",   @"f": @(1320), @"snr": @(-7),  @"dt": @(0.0)},
        @{@"t": @"CQ PA0JAX JO21",   @"f": @(1580), @"snr": @(+6),  @"dt": @(-0.2)},
        @{@"t": @"CQ R9FE LO14",     @"f": @(1840), @"snr": @(-5),  @"dt": @(0.1)},
        @{@"t": @"CQ UC6W LN04",     @"f": @(2100), @"snr": @(+2),  @"dt": @(-0.1)},
        @{@"t": @"CQ JA1ABC PM95",   @"f": @(650),  @"snr": @(-4),  @"dt": @(0.1)},
        @{@"t": @"CQ DL7XYZ JO62",   @"f": @(1100), @"snr": @(+2),  @"dt": @(-0.2)},
        @{@"t": @"CQ W1AW FN31",     @"f": @(1450), @"snr": @(-12), @"dt": @(0.3)},
        @{@"t": @"CQ VK2BGL QF56",   @"f": @(2520), @"snr": @(-16), @"dt": @(0.4)}
    ];

    for (NSDictionary *c in candidates) {
        TX500FT8Message *msg = [TX500FT8Message messageWithRawText:c[@"t"]
                                                            freqHz:[c[@"f"] floatValue]
                                                             snrDb:[c[@"snr"] floatValue]
                                                                dt:[c[@"dt"] floatValue]
                                                          slotDate:slotDate
                                                        slotParity:parity
                                                            myCall:myCall
                                                            myGrid:myGrid];
        [messages addObject:msg];
    }

    // Handle simulated active QSO progression if partner is replying
    if (_simPartnerCall.length > 0) {
        NSString *replyText = nil;
        if (_simQSOStage == 1) { // They received our answer or CQ, now sending their report
            replyText = [NSString stringWithFormat:@"%@ %@ %+03d", myCall, _simPartnerCall, _simPartnerReport];
            _simQSOStage = 2;
        } else if (_simQSOStage == 2) { // They received our report, replying with RR73
            replyText = [NSString stringWithFormat:@"%@ %@ RR73", myCall, _simPartnerCall];
            _simQSOStage = 3;
        } else if (_simQSOStage == 3) { // Final 73
            replyText = [NSString stringWithFormat:@"%@ %@ 73", myCall, _simPartnerCall];
            _simQSOStage = 4;
        }

        if (replyText) {
            TX500FT8Message *partnerMsg = [TX500FT8Message messageWithRawText:replyText
                                                                       freqHz:self.rxAudioFrequencyHz
                                                                        snrDb:(float)_simPartnerReport
                                                                           dt:0.15f
                                                                     slotDate:slotDate
                                                                   slotParity:parity
                                                                       myCall:myCall
                                                                       myGrid:myGrid];
            [messages insertObject:partnerMsg atIndex:0];
        }
    }

    [self logDecodedMessagesToADIF:messages];

    if (self.onDecodedMessages) {
        self.onDecodedMessages(messages, parity);
    }
}

- (void)injectSimulatedBandActivity {
    [self executeSimulationDecodeForParity:self.currentSlotParity];
}

- (void)injectSimulatedCallerResponse:(NSString *)dxCall report:(NSString *)report isRR73:(BOOL)isRR73 {
    _simPartnerCall = [dxCall uppercaseString];
    _simPartnerReport = [report intValue];
    _simQSOStage = isRR73 ? 2 : 1;
}

@end
