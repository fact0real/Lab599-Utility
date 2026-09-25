//
//  TX500FT8AudioEngine.m
//  Lab599 Utility
//
//  Real-Time CoreAudio Slot-Synchronized DSP Engine for FT8
//

#import "TX500FT8AudioEngine.h"
#import "TX500TimeDiscipline.h"
#import <math.h>
#import <mach/mach_time.h>

#define FT8_SAMPLE_RATE 12000
#define FT8_SLOT_SECONDS 15.0
#define FT8_TX_SECONDS 14.5
#define FT8_MAX_SLOT_SAMPLES (FT8_SAMPLE_RATE * 15)
#define FT8_WATERFALL_BINS 4096

#define TX500_FT8_FFT_SIZE 16384
#define TX500_FT8_WATER_BUFFER_SIZE 16384

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
    double _lastWaterfallUpdateMonotonic;
    float _liveWaterBuffer[TX500_FT8_WATER_BUFFER_SIZE];
    int _liveWaterHead;
    NSLock *_liveWaterLock;
    float _liveNoiseFloorDb;
    float _liveBinFloorDb[FT8_WATERFALL_BINS];
    BOOL _liveBinFloorInitialized;

    // High precision slot clock
    dispatch_source_t _slotTimer;
    int64_t _lastProcessedSlotIndex;
    BOOL _slotDecodeDispatched;
    double _rxBufferStartMonotonic;
    TX500AudioClockTracker *_audioClockTracker;

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

    // Live audio level VU meter & Split Fake It
    float _audioInputLevelDb;
    int64_t _fakeItVfoShiftHz;

    // SWR monitoring
    double _lastSWRReading;
    NSInteger _lastSWRMeterDots;
    BOOL _swrMeterValid;
    NSDate *_lastSWRMeterSampleDate;
    NSInteger _lastALCMeterDots;
    BOOL _alcMeterValid;
    NSUInteger _alcMeterSampleCount;
    NSDate *_lastALCMeterSampleDate;
    NSInteger _lastPowerMeterDots;
    BOOL _powerMeterValid;
    BOOL _swrQueryInFlight;
    NSUInteger _swrPollingGeneration;
    NSInteger _meterPollPhase;
    NSUInteger _meterPollFailureCount;
    dispatch_source_t _swrPollTimer;

    // A TX slot is not complete until the radio has explicitly confirmed RX.
    // Keep the state keyed while recovery retries are in flight so another TX
    // cannot begin over an unresolved PTT state.
    BOOL _receiveReleaseInProgress;
    NSUInteger _receiveReleaseGeneration;
    NSUInteger _receiveReleaseAttempt;
    double _lastInputCallbackMonotonic;
    NSUInteger _audioRecoveryGeneration;
}

@property (nonatomic, assign, readwrite) float audioInputLevelDb;
@property (nonatomic, assign, readwrite) int64_t fakeItVfoShiftHz;
@property (nonatomic, strong, readwrite) NSMutableArray<NSDictionary<NSString *, NSString *> *> *internalInputDevices;
@property (nonatomic, strong, readwrite) NSMutableArray<NSDictionary<NSString *, NSString *> *> *internalOutputDevices;
@property (nonatomic, assign, readwrite) BOOL isMonitoring;
@property (nonatomic, assign, readwrite) BOOL isTransmitting;
@property (nonatomic, assign, readwrite) double currentSlotSecond;
@property (nonatomic, assign, readwrite) NSInteger currentSlotParity;
@property (nonatomic, assign, readwrite) double slotProgressFraction;

- (void)appendIncomingAudioSamples:(const float *)samples count:(NSInteger)count timestamp:(const AudioTimeStamp *)timestamp;
- (void)renderOutgoingAudioSamples:(float *)samples count:(UInt32)count;
- (void)startSWRPolling;
- (void)stopSWRPolling;
- (void)pollSWRMeter;
- (void)processSlotTickAtUTC:(NSTimeInterval)now;
- (void)requestReceiveReleaseForGeneration:(NSUInteger)generation;
- (void)finishReceiveTransitionAfterRecovery:(BOOL)recovered;
- (void)verifyReceiveCaptureAfterRestart:(NSUInteger)generation restartedAt:(double)restartedAt;

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

static int TX500CompareFloatAscending(const void *lhs, const void *rhs) {
    float a = *(const float *)lhs;
    float b = *(const float *)rhs;
    return (a > b) - (a < b);
}

// AudioQueue Callbacks
static void FT8AudioQueueInputCallback(void *inUserData,
                                       AudioQueueRef inAQ,
                                       AudioQueueBufferRef inBuffer,
                                       const AudioTimeStamp *inStartTime,
                                       UInt32 inNumberPacketDescriptions,
                                       const AudioStreamPacketDescription *inPacketDescs) {
    (void)inNumberPacketDescriptions;
    (void)inPacketDescs;
    TX500FT8AudioEngine *engine = (__bridge TX500FT8AudioEngine *)inUserData;
    if (!engine || !engine.isMonitoring) return;

    const float *samples = (const float *)inBuffer->mAudioData;
    UInt32 frameCount = inBuffer->mAudioDataByteSize / sizeof(float);

    if (frameCount > 0 && samples) {
        [engine appendIncomingAudioSamples:samples count:frameCount timestamp:inStartTime];
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
        _protocol = TX500_FT8_PROTOCOL_FT8;
        _txSlotParity = TX500FT8SlotParityEven;
        _isTransmitArmed = NO;
        _lastProcessedSlotIndex = INT64_MIN;
        // Simulation mode defaults to NO (Live Radio Mode) so connected TX-500 transceivers operate on air.
        // It is only enabled if explicitly passed via CLI arguments or toggled by the operator in the current session.
        _isSimulationMode = NO;
        if ([[NSProcessInfo processInfo].arguments containsObject:@"--simulation"]) {
            _isSimulationMode = YES;
        }

        _rxBuffer = (float *)calloc(FT8_MAX_SLOT_SAMPLES, sizeof(float));
        _rxBufferCount = 0;
        _rxBufferStartMonotonic = NAN;
        _lastInputCallbackMonotonic = -DBL_MAX;
        _rxBufferLock = [[NSLock alloc] init];
        _audioClockTracker = [[TX500AudioClockTracker alloc] initWithNominalSampleRate:FT8_SAMPLE_RATE];

        _txBuffer = (float *)calloc(FT8_MAX_SLOT_SAMPLES, sizeof(float));
        _txBufferTotalSamples = 0;
        _txBufferReadIndex = 0;
        _txBufferLock = [[NSLock alloc] init];

        _waterfallMag = (float *)calloc(FT8_WATERFALL_BINS, sizeof(float));
        _lastWaterfallUpdateMonotonic = -DBL_MAX;
        memset(_liveWaterBuffer, 0, sizeof(_liveWaterBuffer));
        _liveWaterHead = 0;
        _liveWaterLock = [[NSLock alloc] init];

        _internalInputDevices = [NSMutableArray array];
        _internalOutputDevices = [NSMutableArray array];
        [self refreshAudioDevices];

        AudioObjectPropertyAddress devAddr = {
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &devAddr, FT8AudioHardwareDevicesListener, (__bridge void *)self);

        _liveNoiseFloorDb = -80.0f;
        _audioInputGain = 1.0f;
        _audioInputLevelDb = -60.0f;
        _splitFakeItEnabled = YES;
    }
    return self;
}

static OSStatus FT8AudioHardwareDevicesListener(AudioObjectID inObjectID,
                                                UInt32 inNumberAddresses,
                                                const AudioObjectPropertyAddress *inAddresses,
                                                void *inClientData) {
    (void)inObjectID; (void)inNumberAddresses; (void)inAddresses;
    TX500FT8AudioEngine *engine = (__bridge TX500FT8AudioEngine *)inClientData;
    if (engine) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [engine refreshAudioDevices];
        });
    }
    return noErr;
}

- (void)setIsSimulationMode:(BOOL)isSimulationMode {
    if (_isSimulationMode == isSimulationMode) return;
    _isSimulationMode = isSimulationMode;
    if (self.isMonitoring) {
        if (_isSimulationMode) {
            [self teardownAudioHardware];
        } else {
            if(![self setupAudioHardware:nil]) [self stopMonitoring];
        }
    }
}

- (void)dealloc {
    AudioObjectPropertyAddress devAddr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &devAddr, FT8AudioHardwareDevicesListener, (__bridge void *)self);

    [self stopMonitoring];
    [self teardownAudioHardware];
    if (_rxBuffer) { free(_rxBuffer); _rxBuffer = NULL; }
    if (_txBuffer) { free(_txBuffer); _txBuffer = NULL; }
    if (_waterfallMag) { free(_waterfallMag); _waterfallMag = NULL; }
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)inputDevices {
    @synchronized (self.internalInputDevices) {
        return [self.internalInputDevices copy];
    }
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)outputDevices {
    @synchronized (self.internalOutputDevices) {
        return [self.internalOutputDevices copy];
    }
}

- (BOOL)isTuning {
    return _isTuning;
}

- (void)refreshAudioDevices {
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *inputs = [NSMutableArray array];
    NSMutableArray<NSDictionary<NSString *, NSString *> *> *outputs = [NSMutableArray array];

    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) == noErr && size > 0) {
        int count = size / sizeof(AudioDeviceID);
        AudioDeviceID *devs = (AudioDeviceID *)malloc(size);
        if (devs && AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devs) == noErr) {
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

                // Transport type
                AudioObjectPropertyAddress transAddr = {
                    kAudioDevicePropertyTransportType,
                    kAudioObjectPropertyScopeGlobal,
                    kAudioObjectPropertyElementMain
                };
                UInt32 transport = 0;
                UInt32 transSize = sizeof(UInt32);
                AudioObjectGetPropertyData(devID, &transAddr, 0, NULL, &transSize, &transport);

                NSString *lower = name.lowercaseString;
                BOOL isUSBTransport = (transport == kAudioDeviceTransportTypeUSB);
                BOOL isVirtual = (transport == kAudioDeviceTransportTypeVirtual) ||
                                 [lower containsString:@"background music"] ||
                                 [lower containsString:@"blackhole"] ||
                                 [lower containsString:@"teams"] ||
                                 [lower containsString:@"soundflower"] ||
                                 [lower containsString:@"aggregate"] ||
                                 [lower containsString:@"multi-output"];

                BOOL isRadioOrUSB = isUSBTransport ||
                                    [lower containsString:@"usb audio"] ||
                                    [lower containsString:@"ttgk"] ||
                                    [lower containsString:@"ad-508"] ||
                                    [lower containsString:@"ad-509"] ||
                                    [lower containsString:@"c-media"] ||
                                    [lower containsString:@"tx-500"] ||
                                    [lower containsString:@"digirig"] ||
                                    [lower containsString:@"signallink"] ||
                                    [lower containsString:@"codec"];

                BOOL isExplicitAD508 = [lower containsString:@"ad-508"] ||
                                       [lower containsString:@"ad-509"] ||
                                       [lower containsString:@"ttgk"] ||
                                       [lower containsString:@"tx-500"] ||
                                       ([lower containsString:@"usb audio"] && !isVirtual);

                NSString *displayName = name;
                if (isExplicitAD508) {
                    displayName = [NSString stringWithFormat:@"★ %@ (AD-508 USB-C)", name];
                } else if (isRadioOrUSB && !isVirtual) {
                    displayName = [NSString stringWithFormat:@"★ %@ (Radio USB Audio)", name];
                } else if (isVirtual) {
                    displayName = [NSString stringWithFormat:@"%@ (Virtual)", name];
                }

                // Input stream check
                AudioObjectPropertyAddress inAddr = {
                    kAudioDevicePropertyStreams,
                    kAudioDevicePropertyScopeInput,
                    kAudioObjectPropertyElementMain
                };
                UInt32 inStreamSize = 0;
                if (AudioObjectGetPropertyDataSize(devID, &inAddr, 0, NULL, &inStreamSize) == noErr && inStreamSize > 0) {
                    [inputs addObject:@{
                        @"name": name,
                        @"displayName": displayName,
                        @"uid": uid,
                        @"isAD508": isExplicitAD508 ? @"YES" : @"NO",
                        @"isUSB": (isRadioOrUSB && !isVirtual) ? @"YES" : @"NO",
                        @"isVirtual": isVirtual ? @"YES" : @"NO"
                    }];
                }

                // Output stream check
                AudioObjectPropertyAddress outAddr = {
                    kAudioDevicePropertyStreams,
                    kAudioDevicePropertyScopeOutput,
                    kAudioObjectPropertyElementMain
                };
                UInt32 outStreamSize = 0;
                if (AudioObjectGetPropertyDataSize(devID, &outAddr, 0, NULL, &outStreamSize) == noErr && outStreamSize > 0) {
                    [outputs addObject:@{
                        @"name": name,
                        @"displayName": displayName,
                        @"uid": uid,
                        @"isAD508": isExplicitAD508 ? @"YES" : @"NO",
                        @"isUSB": (isRadioOrUSB && !isVirtual) ? @"YES" : @"NO",
                        @"isVirtual": isVirtual ? @"YES" : @"NO"
                    }];
                }
            }
            free(devs);
        }
    }

    // Sort inputs:
    // Priority 0: AD-508 / Radio USB Audio
    // Priority 1: Other USB Audio
    // Priority 2: Built-in / System
    // Priority 3: Virtual
    NSComparator comp = ^NSComparisonResult(NSDictionary *d1, NSDictionary *d2) {
        int p1 = 2, p2 = 2;
        if ([d1[@"isAD508"] isEqualToString:@"YES"]) p1 = 0;
        else if ([d1[@"isUSB"] isEqualToString:@"YES"]) p1 = 1;
        else if ([d1[@"isVirtual"] isEqualToString:@"YES"]) p1 = 3;

        if ([d2[@"isAD508"] isEqualToString:@"YES"]) p2 = 0;
        else if ([d2[@"isUSB"] isEqualToString:@"YES"]) p2 = 1;
        else if ([d2[@"isVirtual"] isEqualToString:@"YES"]) p2 = 3;

        if (p1 != p2) return (p1 < p2) ? NSOrderedAscending : NSOrderedDescending;
        return [d1[@"name"] localizedCaseInsensitiveCompare:d2[@"name"]];
    };

    [inputs sortUsingComparator:comp];
    [outputs sortUsingComparator:comp];

    @synchronized (self.internalInputDevices) {
        [self.internalInputDevices setArray:inputs];
    }
    @synchronized (self.internalOutputDevices) {
        [self.internalOutputDevices setArray:outputs];
    }

    // Update connection flags
    BOOL hasAD508In = NO, hasAD508Out = NO;
    NSString *bestAD508InUID = nil, *bestAD508OutUID = nil;
    NSString *bestUSBInUID = nil, *bestUSBOutUID = nil;
    for (NSDictionary *d in inputs) {
        if ([d[@"isAD508"] isEqualToString:@"YES"]) {
            hasAD508In = YES;
            if (!bestAD508InUID) bestAD508InUID = d[@"uid"];
        }
        if ([d[@"isUSB"] isEqualToString:@"YES"] && !bestUSBInUID) {
            bestUSBInUID = d[@"uid"];
        }
    }
    for (NSDictionary *d in outputs) {
        if ([d[@"isAD508"] isEqualToString:@"YES"]) {
            hasAD508Out = YES;
            if (!bestAD508OutUID) bestAD508OutUID = d[@"uid"];
        }
        if ([d[@"isUSB"] isEqualToString:@"YES"] && !bestUSBOutUID) {
            bestUSBOutUID = d[@"uid"];
        }
    }
    _isAD508InputConnected = hasAD508In;
    _isAD508OutputConnected = hasAD508Out;

    // Check if current selection is valid or needs upgrade:
    BOOL selectedInValid = NO;
    BOOL currentInIsVirtual = NO;
    for (NSDictionary *d in inputs) {
        if ([d[@"uid"] isEqualToString:_selectedInputDeviceUID]) {
            selectedInValid = YES;
            if ([d[@"isVirtual"] isEqualToString:@"YES"]) {
                currentInIsVirtual = YES;
            }
            break;
        }
    }

    // If no device selected, invalid, or currently selected is a virtual driver and a real radio USB is available:
    // A USB audio interface receives a new CoreAudio UID after a hot unplug.
    // A preserved UID is therefore only a preference, never a reason to keep
    // an unavailable device selected. Rebind to the best physical interface
    // immediately so reconnecting the cable does not leave FT8 unusable.
    if ((!selectedInValid && (bestAD508InUID || bestUSBInUID)) ||
        (!self.preserveDeviceSelection && (currentInIsVirtual || !_selectedInputDeviceUID))) {
        if (bestAD508InUID) {
            _selectedInputDeviceUID = bestAD508InUID;
        } else if (bestUSBInUID) {
            _selectedInputDeviceUID = bestUSBInUID;
        } else if (inputs.count > 0) {
            _selectedInputDeviceUID = inputs.firstObject[@"uid"];
        }
    }

    // Same for output
    BOOL selectedOutValid = NO;
    BOOL currentOutIsVirtual = NO;
    for (NSDictionary *d in outputs) {
        if ([d[@"uid"] isEqualToString:_selectedOutputDeviceUID]) {
            selectedOutValid = YES;
            if ([d[@"isVirtual"] isEqualToString:@"YES"]) {
                currentOutIsVirtual = YES;
            }
            break;
        }
    }
    if ((!selectedOutValid && (bestAD508OutUID || bestUSBOutUID)) ||
        (!self.preserveDeviceSelection && (currentOutIsVirtual || !_selectedOutputDeviceUID))) {
        if (bestAD508OutUID) {
            _selectedOutputDeviceUID = bestAD508OutUID;
        } else if (bestUSBOutUID) {
            _selectedOutputDeviceUID = bestUSBOutUID;
        } else if (outputs.count > 0) {
            _selectedOutputDeviceUID = outputs.firstObject[@"uid"];
        }
    }

    if(self.preserveDeviceSelection && self.isMonitoring && !self.isSimulationMode && (!selectedInValid || !selectedOutValid)) {
        [self disarmTransmit]; [self stopTuneCarrier]; [self stopMonitoring];
        if(self.logHandler) self.logHandler(@"Station audio device disconnected. Monitoring and transmission stopped.");
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

    [self resetSWRReading];

    if(!self.isSimulationMode && self.preserveDeviceSelection) {
        BOOL inputOK=NO, outputOK=NO;
        for(NSDictionary *d in self.inputDevices) if([d[@"uid"] isEqual:self.selectedInputDeviceUID]) inputOK=YES;
        for(NSDictionary *d in self.outputDevices) if([d[@"uid"] isEqual:self.selectedOutputDeviceUID]) outputOK=YES;
        if(!inputOK || !outputOK) {
            if(error) *error=[NSError errorWithDomain:@"TX500AudioErrorDomain" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The station's radio input or transmit output is unavailable. Select connected audio devices in Station Profiles."}];
            return NO;
        }
    }
    if(!self.isSimulationMode && ![self setupAudioHardware:error]) return NO;
    // The station controller requests DIG mode asynchronously before monitoring.
    // Do not run a second synchronous CAT command on the UI thread here: a
    // slow serial acknowledgement can freeze Start FT8 and miss slot starts.
    [[TX500DisciplinedClock sharedClock] setCriticalTimingActive:YES];
    [[TX500DisciplinedClock sharedClock] startAutomaticNetworkSynchronization];
    _lastProcessedSlotIndex = INT64_MIN;

    // A 10 ms cadence bounds software slot-start jitter.  The output queue uses
    // four 10 ms buffers, keeping total queued silence below one FT8 coarse
    // timing bin while CoreAudio remains continuously primed.
    __weak typeof(self) weakSelf = self;
    _slotTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(_slotTimer, DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC, 1 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_slotTimer, ^{
        [weakSelf processSlotTick];
    });
    dispatch_resume(_slotTimer);

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
    if (_isTuning) {
        [self stopTuneCarrier];
    }

    if (_slotTimer) {
        dispatch_source_cancel(_slotTimer);
        _slotTimer = nil;
    }

    [self teardownAudioHardware];
    self.isMonitoring = NO;
    [[TX500DisciplinedClock sharedClock] setCriticalTimingActive:NO];

    if (self.logHandler) {
        self.logHandler(@"[FT8 Engine] Monitoring stopped.");
    }
}

- (BOOL)audioSetupFailed:(OSStatus)status error:(NSError **)error {
    [self teardownAudioHardware];
    NSString *message=[NSString stringWithFormat:@"Cannot open the selected radio audio devices (error %d). Check the station routes and microphone permission.",(int)status];
    if(error) *error=[NSError errorWithDomain:@"TX500AudioErrorDomain" code:status userInfo:@{NSLocalizedDescriptionKey:message}];
    if(self.logHandler) self.logHandler(message);
    return NO;
}
- (BOOL)setupAudioHardware:(NSError **)error {
    [self teardownAudioHardware];
    AudioStreamBasicDescription format={0};
    format.mSampleRate=FT8_SAMPLE_RATE; format.mFormatID=kAudioFormatLinearPCM;
    format.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked;
    format.mBytesPerPacket=4; format.mFramesPerPacket=1; format.mBytesPerFrame=4;
    format.mChannelsPerFrame=1; format.mBitsPerChannel=32;
    OSStatus status=AudioQueueNewInput(&format,FT8AudioQueueInputCallback,(__bridge void *)self,NULL,NULL,0,&_inputQueue);
    if(status!=noErr) return [self audioSetupFailed:status error:error];
    if(self.selectedInputDeviceUID.length && ![self.selectedInputDeviceUID isEqual:@"default"]) {
        CFStringRef uid=(__bridge CFStringRef)self.selectedInputDeviceUID;
        status=AudioQueueSetProperty(_inputQueue,kAudioQueueProperty_CurrentDevice,&uid,sizeof(uid));
        if(status!=noErr) return [self audioSetupFailed:status error:error];
    }
    status=AudioQueueNewOutput(&format,FT8AudioQueueOutputCallback,(__bridge void *)self,NULL,NULL,0,&_outputQueue);
    if(status!=noErr) return [self audioSetupFailed:status error:error];
    if(self.selectedOutputDeviceUID.length && ![self.selectedOutputDeviceUID isEqual:@"default"]) {
        CFStringRef uid=(__bridge CFStringRef)self.selectedOutputDeviceUID;
        status=AudioQueueSetProperty(_outputQueue,kAudioQueueProperty_CurrentDevice,&uid,sizeof(uid));
        if(status!=noErr) return [self audioSetupFailed:status error:error];
    }
    for(int i=0;i<4;i++) {
        status=AudioQueueAllocateBuffer(_inputQueue,1200*sizeof(float),&_inputBuffers[i]);
        if(status!=noErr) return [self audioSetupFailed:status error:error];
        status=AudioQueueEnqueueBuffer(_inputQueue,_inputBuffers[i],0,NULL);
        if(status!=noErr) return [self audioSetupFailed:status error:error];
        status=AudioQueueAllocateBuffer(_outputQueue,120*sizeof(float),&_outputBuffers[i]);
        if(status!=noErr) return [self audioSetupFailed:status error:error];
        memset(_outputBuffers[i]->mAudioData,0,120*sizeof(float));
        _outputBuffers[i]->mAudioDataByteSize=120*sizeof(float);
        status=AudioQueueEnqueueBuffer(_outputQueue,_outputBuffers[i],0,NULL);
        if(status!=noErr) return [self audioSetupFailed:status error:error];
    }
    status=AudioQueueStart(_inputQueue,NULL);
    if(status!=noErr) return [self audioSetupFailed:status error:error];
    status=AudioQueueStart(_outputQueue,NULL);
    if(status!=noErr) return [self audioSetupFailed:status error:error];
    return YES;
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
        if(![self setupAudioHardware:nil]) [self stopMonitoring];
    }
}

- (double)currentSlotPeriod {
    return (self.protocol == TX500_FT8_PROTOCOL_FT4) ? 7.5 : 15.0;
}

- (NSString *)modeName {
    return (self.protocol == TX500_FT8_PROTOCOL_FT4) ? @"FT4" : @"FT8";
}

- (double)currentTxSeconds {
    return (self.protocol == TX500_FT8_PROTOCOL_FT4) ? 5.1 : 14.5;
}

- (double)currentDecodeTriggerSecond {
    return (self.protocol == TX500_FT8_PROTOCOL_FT4) ? 5.8 : 13.5;
}

#pragma mark - Slot Timing Engine

- (void)processSlotTick {
    [self processSlotTickAtUTC:[[TX500DisciplinedClock sharedClock] utcTimeInterval]];
}

- (void)processSlotTickAtUTC:(NSTimeInterval)now {
    double slotPeriod = self.currentSlotPeriod;
    double slotSec = fmod(now, slotPeriod);
    int64_t slotIndex = (int64_t)floor(now / slotPeriod);
    NSInteger parity = (NSInteger)(slotIndex & 1); // FT8: 0=Even (:00,:30), 1=Odd (:15,:45)

    self.currentSlotSecond = slotSec;
    self.currentSlotParity = parity;
    self.slotProgressFraction = slotSec / slotPeriod;

    // An absolute slot index cannot miss a boundary when AppKit or CAT work
    // delays the 10 ms timer callback past the first second of a slot.
    if (slotIndex != _lastProcessedSlotIndex) {
        _lastProcessedSlotIndex = slotIndex;
        _slotDecodeDispatched = NO;

        // Reset RX buffer for new slot
        [_rxBufferLock lock];
        _rxBufferCount = 0;
        _rxBufferStartMonotonic = NAN;
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
            if (slotSec <= 1.0) [self beginTransmission];
            else if (self.logHandler) self.logHandler([NSString stringWithFormat:
                @"[FT8 Slot] Skipped a late TX slot (timer resumed %.2f s after boundary); keeping the next matching slot armed.", slotSec]);
        }
    }

    // End Transmission
    if (_isTransmitting && slotSec >= self.currentTxSeconds) {
        [self endTransmission];
    }

    // Trigger Slot Decode
    if (!_isTransmitting && !_slotDecodeDispatched && slotSec >= self.currentDecodeTriggerSecond) {
        _slotDecodeDispatched = YES;
        [self triggerSlotDecodeWithParity:parity];
    }

    if (self.isSimulationMode && self.isMonitoring) {
        float simNoise = ((float)(rand() % 100)) / 100.0f * 3.0f - 1.5f;
        _audioInputLevelDb = _isTransmitting ? -6.0f : (-24.0f + simNoise);
        if (self.onAudioLevelUpdated) {
            float lvl = _audioInputLevelDb;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onAudioLevelUpdated) {
                    self.onAudioLevelUpdated(lvl);
                }
            });
        }
    }

    double waterfallNow = [[TX500DisciplinedClock sharedClock] monotonicTime];
    // A 16384-point FFT yields 0.73 Hz source bins and 4096 independently
    // coloured pixels across the 0-3000 Hz passband. Ten rows per second keep
    // the time axis fluid and preserve short FT8 tone transitions.
    if (waterfallNow - _lastWaterfallUpdateMonotonic >= 0.10) {
        _lastWaterfallUpdateMonotonic = waterfallNow;
        [self updateWaterfallStream];
    }

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
    double bufferStartMonotonic = _rxBufferStartMonotonic;
    int minSamples = (self.protocol == TX500_FT8_PROTOCOL_FT4) ? (FT8_SAMPLE_RATE * 4) : (FT8_SAMPLE_RATE * 8);
    if (sampleCount < minSamples) {
        // Less than required audio recorded
        [_rxBufferLock unlock];
        return;
    }

    float *snapshot = (float *)malloc(sampleCount * sizeof(float));
    memcpy(snapshot, _rxBuffer, sampleCount * sizeof(float));
    [_rxBufferLock unlock];

    NSString *myCall = self.myCallsign;
    NSString *myGrid = self.myGrid;
    NSString *audioDeviceUID = self.selectedInputDeviceUID ?: @"default-audio";
    __weak typeof(self) weakSelf = self;

    double slotPeriod = self.currentSlotPeriod;
    tx500_ft8_protocol_t proto = self.protocol;
    NSString *curMode = self.modeName;

    TX500DisciplinedClock *clock = [TX500DisciplinedClock sharedClock];
    NSTimeInterval now = [clock utcTimeInterval];
    NSTimeInterval slotStartEpoch = floor(now / slotPeriod) * slotPeriod;
    NSDate *slotDate = [NSDate dateWithTimeIntervalSince1970:slotStartEpoch];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        tx500_ft8_decoded_t results[100];
        int numDecoded = tx500_ft8_decode_samples(snapshot, sampleCount, FT8_SAMPLE_RATE,
                                                  proto, results, 100);
        free(snapshot);

        NSMutableArray<TX500FT8Message *> *messages = [NSMutableArray array];
        NSTimeInterval sampleStartUTC = isfinite(bufferStartMonotonic) ?
            [clock utcTimeIntervalForMonotonicTime:bufferStartMonotonic] : slotStartEpoch;
        for (int i = 0; i < numDecoded; i++) {
            NSString *raw = [NSString stringWithUTF8String:results[i].text];
            if (raw.length > 0) {
                double observedStartUTC = sampleStartUTC + results[i].time_sec;
                float calibratedDT = (float)(observedStartUTC - slotStartEpoch);
                calibratedDT = (float)(calibratedDT - slotPeriod * round(calibratedDT / slotPeriod));
                TX500FT8Message *msg = [TX500FT8Message messageWithRawText:raw
                                                                    freqHz:results[i].freq_hz
                                                                     snrDb:results[i].snr_db
                                                                        dt:calibratedDT
                                                                  slotDate:slotDate
                                                                slotParity:parity
                                                                    myCall:myCall
                                                                    myGrid:myGrid];
                msg.timingUncertaintySec = results[i].time_uncertainty_sec;
                msg.timingSourceIdentifier = audioDeviceUID;
                msg.mode = curMode;
                // Reject acoustic/USB loopback of this station's own frames.
                // Replies addressed to us remain because their caller is the DX station.
                if (!msg.isMyTransmission) {
                    [messages addObject:msg];
                }
            }
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                [clock ingestFT8Messages:messages slotStart:slotDate];
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
    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSString *testRoot = environment[@"TX500_TEST_ROOT"];
    NSString *dir = nil;
    if (environment[@"TX500_TEST_MODE"].boolValue && testRoot.length > 0) {
        dir = [testRoot stringByAppendingPathComponent:@"FT8"];
    } else {
        NSString *appSupport = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        dir = [appSupport stringByAppendingPathComponent:@"Lab599 Utility/FT8"];
    }
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
            if (self.protocol == TX500_FT8_PROTOCOL_FT4) {
                [buffer appendString:@" <MODE:4>MFSK <SUBMODE:3>FT4"];
            } else {
                [buffer appendString:@" <MODE:3>FT8"];
            }
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

- (void)restoreNominalDialAfterFakeIt {
    if (self.isSimulationMode || !self.serialCommandSender || self.dialFrequencyHz == 0) return;

    const uint64_t nominalDial = self.dialFrequencyHz;
    NSString *restoreCommand = [NSString stringWithFormat:@"FA%011llu;", (unsigned long long)nominalDial];
    BOOL (^sendCommand)(NSString *) = [self.serialCommandSender copy];
    NSString * _Nullable (^queryCommand)(NSString *, NSTimeInterval) = [self.catQueryHandler copy];
    void (^logLine)(NSString *) = [self.logHandler copy];

    // The TX-500 can still be settling immediately after PT0.  Retry the
    // nominal dial write and verify it with FA readback instead of assuming a
    // single accepted USB write changed the VFO.  This prevents a temporary
    // Fake-It offset (for example 28.073500) becoming the next RX dial.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        BOOL written = NO;
        BOOL verified = NO;
        NSString *expectedReply = restoreCommand;
        for (NSUInteger attempt = 0; attempt < 3 && !verified; attempt++) {
            written = sendCommand(restoreCommand) || written;
            [NSThread sleepForTimeInterval:0.15 + (0.10 * attempt)];
            if (queryCommand) {
                NSString *reply = queryCommand(@"FA;", 0.7);
                verified = [reply isEqualToString:expectedReply];
            }
        }
        if (logLine) {
            NSString *result = queryCommand ? (verified ? @"verified" : @"NOT verified")
                                             : (written ? @"requested three times" : @"failed");
            logLine([NSString stringWithFormat:
                @"[Split / Fake It] Nominal VFO %.6f MHz %@ after TX.", nominalDial / 1e6, result]);
        }
    });
}

- (void)armTransmitWithText:(NSString *)text parity:(TX500FT8SlotParity)parity {
    // Preserve the last measured SWR while receiving.  It is cleared only when
    // the next RF burst actually begins, so merely arming a message does not
    // erase the operator's most recent antenna reading.
    self.queuedTxMessage = text;
    self.txSlotParity = parity;
    self.isTransmitArmed = YES;
    self.repeatArmedTransmission = NO;
    _autoParityLocked = -1; // Reset so next transition locks the parity

    if (self.logHandler) {
        NSString *pName = (parity == TX500FT8SlotParityEven) ? @"Even" :
                          (parity == TX500FT8SlotParityOdd) ? @"Odd" : @"Auto";
        self.logHandler([NSString stringWithFormat:@"[%@ Transmit Armed] Msg: '%@' on Slot %@", self.modeName, text, pName]);
    }
}

- (void)disarmTransmit {
    self.isTransmitArmed = NO;
    self.repeatArmedTransmission = NO;
    _autoParityLocked = -1;
    if (_isTransmitting) {
        [self endTransmission];
    }
    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[%@ Transmit Disarmed]", self.modeName]);
    }
}

- (void)resetSWRReading {
    _lastSWRReading = 0.0;
    _lastSWRMeterDots = 0;
    _swrMeterValid = NO;
    _lastSWRMeterSampleDate = nil;
    _lastALCMeterDots = 0;
    _alcMeterValid = NO;
    _alcMeterSampleCount = 0;
    _lastALCMeterSampleDate = nil;
    _lastPowerMeterDots = 0;
    _powerMeterValid = NO;
    if (self.onSWRMeterUpdated) self.onSWRMeterUpdated(0, NO);
    if (self.onALCMeterUpdated) self.onALCMeterUpdated(0, NO);
    if (self.onPowerMeterUpdated) self.onPowerMeterUpdated(0, NO);
}

- (void)beginTransmission {
    if (self.queuedTxMessage.length == 0 || _receiveReleaseInProgress) return;
    if (!self.isSimulationMode && (self.dialFrequencyHz == 0 ||
        (self.requiresVerifiedCATDial && !self.catDialAndModeVerified))) {
        self.isTransmitArmed = NO;
        _autoParityLocked = -1;
        if (self.logHandler) self.logHandler(@"[FT8 TX blocked] Radio dial frequency and DIG mode have not been verified over CAT.");
        return;
    }
    TX500TimeSnapshot *time = [[TX500DisciplinedClock sharedClock] snapshot];
    if (!self.isSimulationMode && !time.transmitAllowed) {
        self.isTransmitArmed = NO;
        _autoParityLocked = -1;
        if (self.logHandler) {
            self.logHandler([NSString stringWithFormat:@"[FT8 TX blocked] Time uncertainty is %.3f s (%@). Receive until network or radio timing is trustworthy.",
                             time.uncertaintySeconds, time.sourceDescription]);
        }
        return;
    }

    NSString *msgText = [self.queuedTxMessage uppercaseString];
    unsigned char tones[FT8808_MAX_TONES];
    int numTones = tx500_ft8_encode_message([msgText UTF8String], self.protocol, tones, FT8808_MAX_TONES);
    if (numTones <= 0) {
        if (self.logHandler) {
            self.logHandler([NSString stringWithFormat:@"[%@ Error] Failed to encode text: '%@'", self.modeName, msgText]);
        }
        return;
    }

    float synthAudioFreq = self.txAudioFrequencyHz;
    _fakeItVfoShiftHz = 0;
    if (self.splitFakeItEnabled && (self.txAudioFrequencyHz < 1000.0f || self.txAudioFrequencyHz > 2000.0f)) {
        // Center audio transmission tone at 1500 Hz for optimal transmitter passband and minimal harmonic leakage
        synthAudioFreq = 1500.0f;
        _fakeItVfoShiftHz = (int64_t)round(self.txAudioFrequencyHz - 1500.0f);
        uint64_t shiftedVfo = (uint64_t)((int64_t)self.dialFrequencyHz + _fakeItVfoShiftHz);
        if (self.serialCommandSender && !self.isSimulationMode) {
            NSString *faCmd = [NSString stringWithFormat:@"FA%011llu;", (unsigned long long)shiftedVfo];
            if(!self.serialCommandSender(faCmd)) {
                _fakeItVfoShiftHz=0; self.isTransmitArmed=NO;
                if(self.logHandler) self.logHandler(@"[TX blocked] Split frequency change failed.");
                return;
            }
            if (self.logHandler) {
                self.logHandler([NSString stringWithFormat:@"[Split / Fake It] Shifted TX VFO by %+lld Hz to %llu Hz (audio tone centered at 1500 Hz)",
                                 _fakeItVfoShiftHz, (unsigned long long)shiftedVfo]);
            }
        }
    }

    [_txBufferLock lock];
    _txBufferTotalSamples = tx500_ft8_synthesize(tones, numTones, synthAudioFreq,
                                                 self.protocol, FT8_SAMPLE_RATE,
                                                 _txBuffer, FT8_MAX_SLOT_SAMPLES);
    _txBufferReadIndex = 0;
    [_txBufferLock unlock];

    [self resetSWRReading];

    // Request confirmed PTT from the shared station transport before exposing audio.
    // Note: Do NOT send MD6; here. The radio is already in DIG mode; sending MD6; at TX trigger
    // disrupts microcontroller timing and causes dropped PTT commands.
    if (!self.isSimulationMode) {
        BOOL keyed=self.pttControlHandler ? self.pttControlHandler(YES) : (self.serialCommandSender ? self.serialCommandSender(@"TX;") : NO);
        if(!keyed) {
            _isTransmitting=NO; _isTuning=NO; self.isTransmitArmed=NO;
            if(self.pttControlHandler) self.pttControlHandler(NO);
            else if(self.serialCommandSender) self.serialCommandSender(@"RX;");
            if(_fakeItVfoShiftHz) {
                [self restoreNominalDialAfterFakeIt];
                _fakeItVfoShiftHz=0;
            }
            [_txBufferLock lock]; _txBufferTotalSamples=0; _txBufferReadIndex=0; [_txBufferLock unlock];
            if(self.logHandler) self.logHandler(@"[TX blocked] PTT was not confirmed; audio transmission cancelled.");
            if(self.onTransmitStateChanged) self.onTransmitStateChanged(NO,@"");
            return;
        }
    }

    _isTransmitting=YES;
    if (!self.repeatArmedTransmission) self.isTransmitArmed = NO;
    if (self.logHandler) {
        NSString *pttMethod = self.isSimulationMode ? @"[Simulation - No RF]" : @"[CAT TX confirmed]";
        self.logHandler([NSString stringWithFormat:@"[FT8 TX ON] Sending '%@' at %.0f Hz %@",
                         msgText, synthAudioFreq, pttMethod]);
    }

    if (self.onTransmitStateChanged) {
        self.onTransmitStateChanged(YES, msgText);
    }

    [self startSWRPolling];
}

- (void)endTransmission {
    if (!_isTransmitting || _receiveReleaseInProgress) return;

    _receiveReleaseInProgress = YES;
    _receiveReleaseAttempt = 0;
    NSUInteger releaseGeneration = ++_receiveReleaseGeneration;
    [_txBufferLock lock];
    _txBufferTotalSamples = 0;
    _txBufferReadIndex = 0;
    [_txBufferLock unlock];

    [self stopSWRPolling];

    [self requestReceiveReleaseForGeneration:releaseGeneration];
}

- (void)requestReceiveReleaseForGeneration:(NSUInteger)generation {
    if (generation != _receiveReleaseGeneration || !_receiveReleaseInProgress) return;
    _receiveReleaseAttempt++;
    NSUInteger attempt = _receiveReleaseAttempt;
    __weak typeof(self) weakSelf = self;
    // CAT acknowledgement can take several USB timeouts. Keep it off AppKit's
    // main thread so a difficult RX recovery cannot make the window look hung.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        BOOL released = strongSelf.isSimulationMode;
        if (!released) {
            released = strongSelf.pttControlHandler ? strongSelf.pttControlHandler(NO) :
                       (strongSelf.serialCommandSender ? strongSelf.serialCommandSender(@"RX;") : NO);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) mainSelf = weakSelf;
            if (!mainSelf || generation != mainSelf->_receiveReleaseGeneration ||
                !mainSelf->_receiveReleaseInProgress) return;
            if (released) {
                [mainSelf finishReceiveTransitionAfterRecovery:(attempt > 1)];
                return;
            }

            // Preserve the operator's CQ intent while RX is unresolved.  The
            // recovery guard and station core both block another PTT until
            // the radio has explicitly confirmed PT0.
            if (mainSelf.logHandler) {
                mainSelf.logHandler([NSString stringWithFormat:
                    @"[RX RECOVERY] Radio has not confirmed RX (attempt %lu). TX audio is muted; retrying RX automatically.",
                    (unsigned long)attempt]);
            }

            // Retry quickly through relay/USB transients, then continue at a calm rate.
            // Never declare RX or permit another transmission without PT0 confirmation.
            NSTimeInterval delay = (attempt < 4) ? 0.25 : 1.0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [weakSelf requestReceiveReleaseForGeneration:generation];
            });
        });
    });
}

- (void)finishReceiveTransitionAfterRecovery:(BOOL)recovered {
    _receiveReleaseInProgress = NO;
    _isTransmitting = NO;

    if (_fakeItVfoShiftHz != 0) {
        [self restoreNominalDialAfterFakeIt];
        _fakeItVfoShiftHz = 0;
    }

    // Discard TX loopback and rebuild the full-duplex USB queues. Some AD-508
    // devices stop delivering input after a CAT keyed burst until CoreAudio is
    // reopened; tab switching used to hide this recovery accidentally.
    [_rxBufferLock lock];
    _rxBufferCount = 0;
    _rxBufferStartMonotonic = NAN;
    [_rxBufferLock unlock];
    [_liveWaterLock lock];
    memset(_liveWaterBuffer, 0, sizeof(_liveWaterBuffer));
    _liveWaterHead = 0;
    _liveBinFloorInitialized = NO;
    [_liveWaterLock unlock];
    if (self.isMonitoring && !self.isSimulationMode) {
        double restartedAt = [[TX500DisciplinedClock sharedClock] monotonicTime];
        NSUInteger audioGeneration = ++_audioRecoveryGeneration;
        [self restartAudioHardware];
        [self verifyReceiveCaptureAfterRestart:audioGeneration restartedAt:restartedAt];
    }

    if (recovered && self.serialCommandSender) {
        // Digital reception must never remain hidden behind a closed squelch.
        self.serialCommandSender(@"SQ0000;");
    }
    if (self.logHandler) {
        self.logHandler(recovered ?
            @"[RX RECOVERY] RX confirmed; AD-508 capture restarted and decoding resumed." :
            @"[FT8 TX OFF] RX confirmed; AD-508 capture restarted for the next slot.");
    }
    if (self.onTransmitStateChanged) self.onTransmitStateChanged(NO, @"");
}

- (BOOL)isReceiveRecoveryPending {
    return _receiveReleaseInProgress;
}

- (void)verifyReceiveCaptureAfterRestart:(NSUInteger)generation restartedAt:(double)restartedAt {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || generation != strongSelf->_audioRecoveryGeneration ||
            !strongSelf.isMonitoring || strongSelf.isSimulationMode || strongSelf.isTransmitting) return;
        if (strongSelf->_lastInputCallbackMonotonic > restartedAt) return;
        if (strongSelf.logHandler) {
            strongSelf.logHandler(@"[RX RECOVERY] AD-508 delivered no input after RX; reopening the audio path once more.");
        }
        [strongSelf restartAudioHardware];
    });
}

- (double)lastSWRReading {
    return _lastSWRReading;
}

- (NSInteger)lastSWRMeterDots {
    return _lastSWRMeterDots;
}

- (BOOL)swrMeterValid {
    return _swrMeterValid;
}

- (NSDate *)lastSWRMeterSampleDate { return _lastSWRMeterSampleDate; }
- (NSInteger)lastALCMeterDots { return _lastALCMeterDots; }
- (BOOL)alcMeterValid { return _alcMeterValid; }
- (NSUInteger)alcMeterSampleCount { return _alcMeterSampleCount; }
- (NSDate *)lastALCMeterSampleDate { return _lastALCMeterSampleDate; }
- (NSInteger)lastPowerMeterDots { return _lastPowerMeterDots; }
- (BOOL)powerMeterValid { return _powerMeterValid; }

+ (BOOL)parseSWRMeterReply:(NSString *)reply rawDots:(NSInteger *)rawDots {
    return [self parseMeterReply:reply meter:1 rawDots:rawDots];
}

+ (BOOL)parseMeterReply:(NSString *)reply meter:(NSInteger)meter rawDots:(NSInteger *)rawDots {
    if (reply.length == 0) return NO;
    NSString *compact = [[reply componentsSeparatedByCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
    NSString *prefix = [NSString stringWithFormat:@"RM%ld", (long)meter];
    NSRange start = [compact rangeOfString:prefix];
    if (start.location == NSNotFound || compact.length < NSMaxRange(start) + 5) return NO;
    NSString *frame = [compact substringWithRange:NSMakeRange(start.location, 8)];
    if (![frame hasSuffix:@";"]) return NO;
    NSString *field = [frame substringWithRange:NSMakeRange(3, 4)];
    NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    if ([field rangeOfCharacterFromSet:nonDigits].location != NSNotFound) return NO;
    NSInteger value = field.integerValue;
    if (value < 0 || value > 30) return NO;
    if (rawDots) *rawDots = value;
    return YES;
}

+ (BOOL)parsePowerMeterReply:(NSString *)reply rawDots:(NSInteger *)rawDots {
    if (reply.length == 0) return NO;
    NSString *compact = [[reply componentsSeparatedByCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
    NSRange start = [compact rangeOfString:@"SM0"];
    if (start.location == NSNotFound || compact.length < NSMaxRange(start) + 5) return NO;
    NSString *frame = [compact substringWithRange:NSMakeRange(start.location, 8)];
    if (![frame hasSuffix:@";"]) return NO;
    NSString *field = [frame substringWithRange:NSMakeRange(3, 4)];
    if ([field rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return NO;
    NSInteger value = field.integerValue;
    if (value < 0 || value > 30) return NO;
    if (rawDots) *rawDots = value;
    return YES;
}

+ (double)swrRatioFromMeterDots:(NSInteger)dots {
    // Calibrated lookup table for TX-500 RM meter dots to SWR ratio.
    // Hardware cross-check: two RM1 dots correspond to 1.9:1 on the TX-500
    // LCD. CAT exposes quantized display dots rather than a continuous ratio.
    if (dots <= 0) return 1.0;
    double ratio;
    if (dots == 1) ratio = 1.3;
    else if (dots == 2) ratio = 1.8;
    else if (dots == 3) ratio = 1.9;
    else if (dots == 4) ratio = 2.3;
    else if (dots == 5) ratio = 2.8;
    else if (dots == 6) ratio = 3.5;
    else if (dots == 7) ratio = 4.5;
    else if (dots == 8) ratio = 5.5;
    else ratio = 5.5 + ((double)(dots - 8) * 0.5);
    // RM exposes only whole display dots. Report the conservative upper edge
    // of that quantization bin so the app no longer understates the LCD value.
    return ratio + (dots <= 5 ? 0.1 : 0.2);
}

- (void)startSWRPolling {
    [self stopSWRPolling];
    _meterPollPhase = 0;
    _meterPollFailureCount = 0;
    if (self.onSWRMeterUpdated) self.onSWRMeterUpdated(0, NO);
    if (!self.isSimulationMode && !self.catQueryHandler) return;

    __weak typeof(self) weakSelf = self;
    _swrPollTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    // Poll one meter per tick.  Keeping each CAT transaction independent avoids
    // losing all three readings when one meter reply is delayed or malformed.
    dispatch_source_set_timer(_swrPollTimer, dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                              400 * NSEC_PER_MSEC, 40 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(_swrPollTimer, ^{
        [weakSelf pollSWRMeter];
    });
    dispatch_resume(_swrPollTimer);
}

- (void)stopSWRPolling {
    _swrPollingGeneration++;
    if (_swrPollTimer) {
        dispatch_source_cancel(_swrPollTimer);
        _swrPollTimer = nil;
    }
    // Do not clear _swrQueryInFlight here. The CAT transaction itself cannot
    // be cancelled once it owns (or is waiting for) the shared serial lock.
    // Clearing this bit at every TX/RX boundary allowed the next transmission
    // to enqueue another meter query while the previous one was still alive.
    // After several QSOs those stale queries delayed the safety-critical RX
    // command and made the digital station appear frozen.
}

- (void)pollSWRMeter {
    if ((!_isTransmitting && !_isTuning) || _swrQueryInFlight) return;
    if (self.isSimulationMode) {
        double simSWR = 1.0 + ((double)(arc4random_uniform(30)) / 100.0);
        _lastSWRReading = simSWR;
        _lastSWRMeterDots = 1;
        _swrMeterValid = YES;
        _lastSWRMeterSampleDate = [NSDate date];
        _lastALCMeterDots = 3;
        _alcMeterValid = YES;
        _alcMeterSampleCount++;
        _lastALCMeterSampleDate = [NSDate date];
        _lastPowerMeterDots = 15;
        _powerMeterValid = YES;
        if (self.onSWRUpdated) self.onSWRUpdated(simSWR);
        if (self.onSWRMeterUpdated) self.onSWRMeterUpdated(1, YES);
        if (self.onALCMeterUpdated) self.onALCMeterUpdated(3, YES);
        if (self.onPowerMeterUpdated) self.onPowerMeterUpdated(15, YES);
        return;
    }
    if (!self.catQueryHandler) return;

    _swrQueryInFlight = YES;
    NSUInteger queryGeneration = _swrPollingGeneration;
    NSInteger phase = _meterPollPhase;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSString *command = phase == 0 ? @"RM1;RM;" : (phase == 1 ? @"RM3;RM;" : @"SM0;");
        NSString *reply = strongSelf.catQueryHandler(command, 0.35);
        NSInteger dots = 0;
        BOOL valid = phase == 0 ? [TX500FT8AudioEngine parseSWRMeterReply:reply rawDots:&dots] :
                     (phase == 1 ? [TX500FT8AudioEngine parseMeterReply:reply meter:3 rawDots:&dots] :
                                   [TX500FT8AudioEngine parsePowerMeterReply:reply rawDots:&dots]);
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) mainSelf = weakSelf;
            if (!mainSelf) return;
            // There is at most one meter transaction across polling sessions.
            // Release the gate even when this reply belongs to an older TX;
            // only the UI/result application is generation-dependent.
            mainSelf->_swrQueryInFlight = NO;
            // A reply can arrive after RX was restored or even after a new TX
            // began.  Never apply a result from an earlier polling session.
            if (queryGeneration != mainSelf->_swrPollingGeneration) return;
            if (!mainSelf->_isTransmitting && !mainSelf->_isTuning) return;
            mainSelf->_meterPollPhase = (phase + 1) % 3;
            if (!valid) {
                mainSelf->_meterPollFailureCount++;
                if (mainSelf->_meterPollFailureCount == 3 && mainSelf.logHandler) {
                    mainSelf.logHandler(@"[TX Meter] Waiting for valid SWR/ALC replies from the radio.");
                }
                return;
            }
            mainSelf->_meterPollFailureCount = 0;
            if (phase == 0) {
                mainSelf->_swrMeterValid = YES;
                // Preserve the highest confirmed antenna reading from this RF
                // burst. Early RM1 replies can legitimately be zero while the
                // PA/relay is still settling; replacing a later 1.9 reading
                // with that 1.0 sample made RX history misleading.
                mainSelf->_lastSWRMeterDots = MAX(mainSelf->_lastSWRMeterDots, dots);
                mainSelf->_lastSWRMeterSampleDate = [NSDate date];
                double swrRatio = [TX500FT8AudioEngine swrRatioFromMeterDots:mainSelf->_lastSWRMeterDots];
                mainSelf->_lastSWRReading = swrRatio;
                if (mainSelf.onSWRUpdated) mainSelf.onSWRUpdated(swrRatio);
                if (mainSelf.onSWRMeterUpdated) mainSelf.onSWRMeterUpdated(mainSelf->_lastSWRMeterDots, YES);
            } else if (phase == 1) {
                mainSelf->_alcMeterValid = YES;
                mainSelf->_lastALCMeterDots = dots;
                mainSelf->_alcMeterSampleCount++;
                mainSelf->_lastALCMeterSampleDate = [NSDate date];
                if (mainSelf.onALCMeterUpdated) mainSelf.onALCMeterUpdated(dots, YES);
            } else {
                mainSelf->_powerMeterValid = YES;
                mainSelf->_lastPowerMeterDots = dots;
                if (mainSelf.onPowerMeterUpdated) mainSelf.onPowerMeterUpdated(dots, YES);
            }
        });
    });
}


#pragma mark - Carrier Tune Mode

- (void)startTuneCarrier {
    if (!self.isSimulationMode && (self.dialFrequencyHz == 0 ||
        (self.requiresVerifiedCATDial && !self.catDialAndModeVerified))) {
        if (self.logHandler) self.logHandler(@"[Tune blocked] Radio dial frequency and DIG mode have not been verified over CAT.");
        return;
    }
    if (_receiveReleaseInProgress) {
        if (self.logHandler) self.logHandler(@"[Tune blocked] Waiting for the radio to confirm RX.");
        return;
    }
    [self resetSWRReading];
    _isTuning = NO;
    _carrierPhase = 0.0;
    if (!self.isSimulationMode) {
        BOOL keyed=self.pttControlHandler ? self.pttControlHandler(YES) : (self.serialCommandSender ? self.serialCommandSender(@"TX;") : NO);
        if(!keyed) {
            _isTransmitting=NO; _isTuning=NO; self.isTransmitArmed=NO;
            if(self.pttControlHandler) self.pttControlHandler(NO);
            else if(self.serialCommandSender) self.serialCommandSender(@"RX;");
            if(self.logHandler) self.logHandler(@"[TX blocked] PTT was not confirmed; audio transmission cancelled.");
            if(self.onTransmitStateChanged) self.onTransmitStateChanged(NO,@"");
            return;
        }
    }
    _isTuning=YES;
    if (self.logHandler) {
        NSString *pttMethod = self.isSimulationMode ? @"[Simulation - No RF]" : @"[CAT TX confirmed]";
        self.logHandler([NSString stringWithFormat:@"[Tune Carrier] Tone at %.0f Hz started %@", self.txAudioFrequencyHz, pttMethod]);
    }
    [self startSWRPolling];
}

- (void)stopTuneCarrier {
    if (!_isTuning) return;
    _isTuning = NO;
    [self stopSWRPolling];
    // Reuse the confirmed RX recovery path. Marking the muted carrier as TX
    // keeps all new transmissions blocked until the radio answers PT0.
    _isTransmitting = YES;
    _receiveReleaseInProgress = YES;
    _receiveReleaseAttempt = 0;
    NSUInteger releaseGeneration = ++_receiveReleaseGeneration;
    if (self.logHandler) self.logHandler(@"[Tune Carrier] Tone muted; confirming RX.");
    [self requestReceiveReleaseForGeneration:releaseGeneration];
}

#pragma mark - Audio Samples Processing

- (void)appendIncomingAudioSamples:(const float *)samples count:(NSInteger)count timestamp:(const AudioTimeStamp *)timestamp {
    _lastInputCallbackMonotonic = [[TX500DisciplinedClock sharedClock] monotonicTime];
    double bufferMonotonic = [[TX500DisciplinedClock sharedClock] monotonicTime] - (double)count / FT8_SAMPLE_RATE;
    if (timestamp && (timestamp->mFlags & kAudioTimeStampHostTimeValid)) {
        bufferMonotonic = TX500ContinuousTimeForAudioHostTime(timestamp->mHostTime);
        if (timestamp->mFlags & kAudioTimeStampSampleTimeValid) {
            [_audioClockTracker observeSampleTime:timestamp->mSampleTime hostTimeSeconds:bufferMonotonic];
        }
    }
    // 1. Append to slot decode buffer
    [_rxBufferLock lock];
    if (_rxBufferCount == 0) _rxBufferStartMonotonic = bufferMonotonic;
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
        _liveWaterHead = (_liveWaterHead + 1) % TX500_FT8_WATER_BUFFER_SIZE;
    }
    [_liveWaterLock unlock];

    // 3. Measure live input audio RMS level (dB) for VU Meter
    float sumSq = 0.0f;
    float gain = (self.audioInputGain > 0.05f) ? self.audioInputGain : 1.0f;
    for (NSInteger i = 0; i < count; i++) {
        float val = samples[i] * gain;
        sumSq += val * val;
    }
    float rms = sqrtf(sumSq / (float)count);
    float db = 20.0f * log10f(fmaxf(1e-4f, rms)); // -80.0 dB to 0.0 dB
    _audioInputLevelDb = _audioInputLevelDb * 0.7f + db * 0.3f;
    if (self.onAudioLevelUpdated) {
        float lvl = _audioInputLevelDb;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onAudioLevelUpdated) {
                self.onAudioLevelUpdated(lvl);
            }
        });
    }
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
        // Copy the latest high-resolution FFT window from the live audio ring.
        float fftIn[TX500_FT8_FFT_SIZE];
        [_liveWaterLock lock];
        int head = _liveWaterHead;
        for (int i = 0; i < TX500_FT8_FFT_SIZE; i++) {
            int idx = (head - TX500_FT8_FFT_SIZE + i + TX500_FT8_WATER_BUFFER_SIZE) % TX500_FT8_WATER_BUFFER_SIZE;
            fftIn[i] = _liveWaterBuffer[idx];
        }
        [_liveWaterLock unlock];

        // Measure RMS level
        float rms = 0.0f;
        for (int i = 0; i < TX500_FT8_FFT_SIZE; i++) {
            rms += fftIn[i] * fftIn[i];
        }
        rms = sqrtf(rms / (float)TX500_FT8_FFT_SIZE);

        if (_isTransmitting || _isTuning) {
            // Transmit blanking: suppress audio loopback noise and draw crisp TX marker
            for (int i = 0; i < FT8_WATERFALL_BINS; i++) {
                float binFreq = (float)i / (float)FT8_WATERFALL_BINS * 3000.0f;
                float norm = 0.02f;
                if (fabsf(binFreq - self.txAudioFrequencyHz) < 25.0f) {
                    norm = 1.0f;
                }
                _waterfallMag[i] = _waterfallMag[i] * 0.35f + norm * 0.65f;
            }
        } else if (rms > 1e-6f) {
            float mags[TX500_FT8_FFT_SIZE / 2];
            TX500FT8ComputeFFT(fftIn, mags, TX500_FT8_FFT_SIZE);

            float dbBins[FT8_WATERFALL_BINS];
            float floorSamples[FT8_WATERFALL_BINS];
            for (int i = 0; i < FT8_WATERFALL_BINS; i++) {
                dbBins[i] = 20.0f * log10f(mags[i] + 1e-9f);
                floorSamples[i] = dbBins[i];
            }
            qsort(floorSamples, FT8_WATERFALL_BINS, sizeof(float), TX500CompareFloatAscending);
            // The lower 35th percentile stays stable with several simultaneous
            // stations and does not mistake random FFT peaks for the floor.
            float frameFloor = floorSamples[(NSInteger)(FT8_WATERFALL_BINS * 0.35f)];
            if (!_liveBinFloorInitialized) {
                _liveNoiseFloorDb = frameFloor;
            } else {
                float floorRate = (frameFloor < _liveNoiseFloorDb) ? 0.18f : 0.06f;
                _liveNoiseFloorDb += (frameFloor - _liveNoiseFloorDb) * floorRate;
            }

            // Combine a robust global floor with a slowly adapting per-bin
            // response correction. Fast attack and slow decay retain real FT8
            // tone segments while rejecting one-frame noise speckles.
            for (int i = 0; i < FT8_WATERFALL_BINS; i++) {
                float db = dbBins[i];
                if (!_liveBinFloorInitialized) {
                    _liveBinFloorDb[i] = _liveNoiseFloorDb;
                } else {
                    float quietObservation = fminf(db, _liveNoiseFloorDb + 3.0f);
                    _liveBinFloorDb[i] += (quietObservation - _liveBinFloorDb[i]) * 0.008f;
                }
                float reference = fmaxf(_liveNoiseFloorDb - 2.0f, _liveBinFloorDb[i]);
                float snr = db - reference;
                float norm = 0.012f;
                if (snr > 7.5f) {
                    // Preserve a wide intensity range so a strong station is
                    // visibly brighter than a weak one without lighting the
                    // noise-only bins.
                    float signal = fminf(1.0f, (snr - 7.5f) / 42.0f);
                    norm = 0.045f + 0.955f * powf(signal, 0.90f);
                }
                float rate = (norm > _waterfallMag[i]) ? 0.62f : 0.14f;
                _waterfallMag[i] += (norm - _waterfallMag[i]) * rate;
            }
            _liveBinFloorInitialized = YES;
        } else {
            // Smooth, calm baseline noise floor (no flickering TV snow)
            for (int i = 0; i < FT8_WATERFALL_BINS; i++) {
                _waterfallMag[i] = _waterfallMag[i] * 0.90f + 0.015f * 0.10f;
            }
        }
    } else {
        // Simulation mode renders the active 6.25 Hz tone of each FT8 signal,
        // rather than a solid 50 Hz block, matching live time/frequency tracks.
        double slotSec = self.currentSlotSecond;
        BOOL inTxWindow = (slotSec >= 0.4 && slotSec <= 12.8);

        static const struct {
            float freq;
            float strength;
            int parity; // 0=Even, 1=Odd, -1=Both
        } simStations[] = {
            { 540.0f,  0.72f, 0 },  // BG0FQU (Even)
            { 780.0f,  0.88f, 0 },  // II4IANT (Even)
            { 1050.0f, 0.78f, 0 },  // PH02LIB (Even)
            { 1580.0f, 0.92f, 0 },  // PA0JAX (Even)
            { 2100.0f, 0.75f, 0 },  // UC6W (Even)
            { 650.0f,  0.70f, 1 },  // JA1ABC (Odd)
            { 1100.0f, 0.85f, 1 },  // DL7XYZ (Odd)
            { 1320.0f, 0.62f, 1 },  // MI7JUX (Odd)
            { 1840.0f, 0.68f, 1 },  // R9FE (Odd)
            { 2520.0f, 0.55f, 1 },  // VK2BGL (Odd)
            { 1450.0f, 0.50f, -1 }  // W1AW (Intermittent)
        };
        const int numSimStations = sizeof(simStations) / sizeof(simStations[0]);

        for (int i = 0; i < FT8_WATERFALL_BINS; i++) {
            float binFreq = (float)i / (float)FT8_WATERFALL_BINS * 3000.0f;
            float bandFilter = 1.0f;
            if (binFreq < 200.0f) bandFilter = binFreq / 200.0f;
            if (binFreq > 2850.0f) bandFilter = fmaxf(0.0f, 1.0f - (binFreq - 2850.0f) / 150.0f);

            // Clean, dark, stable background noise
            float baseNoise = 0.015f + ((float)(rand() % 20)) / 2000.0f;
            float sig = 0.0f;

            if (_isTransmitting || _isTuning) {
                // Local transmitter active: intense tone line on TX frequency
                float dist = fabsf(binFreq - self.txAudioFrequencyHz);
                if (dist < 25.0f) {
                    sig = 1.0f - (dist / 25.0f) * 0.20f;
                }
            } else if (inTxWindow) {
                // Stations transmitting in current parity slot
                NSInteger curParity = self.currentSlotParity;
                for (int s = 0; s < numSimStations; s++) {
                    if (simStations[s].parity == -1 || simStations[s].parity == curParity) {
                        NSInteger symbol = (NSInteger)floor(slotSec / 0.160);
                        NSInteger tone = (symbol * 5 + s * 3) & 7;
                        float toneFreq = simStations[s].freq - 21.875f + (float)tone * 6.25f;
                        float dist = fabsf(binFreq - toneFreq);
                        if (dist < 4.5f) {
                            float profile = expf(-0.5f * (dist / 2.2f) * (dist / 2.2f));
                            float stationSig = simStations[s].strength * profile;
                            if (stationSig > sig) sig = stationSig;
                        }
                    }
                }
                // Check if engaged sim partner has a specific frequency
                if (_simPartnerCall.length > 0 && self.rxAudioFrequencyHz > 100.0f) {
                    NSInteger symbol = (NSInteger)floor(slotSec / 0.160);
                    float partnerTone = self.rxAudioFrequencyHz - 21.875f + (float)((symbol * 7) & 7) * 6.25f;
                    float dist = fabsf(binFreq - partnerTone);
                    if (dist < 4.5f) {
                        float profile = expf(-0.5f * (dist / 2.2f) * (dist / 2.2f));
                        float partnerSig = 0.85f * profile;
                        if (partnerSig > sig) sig = partnerSig;
                    }
                }
            }

            float mag = (baseNoise + sig) * bandFilter;
            _waterfallMag[i] = _waterfallMag[i] * 0.40f + mag * 0.60f;
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

    NSTimeInterval now = [[TX500DisciplinedClock sharedClock] utcTimeInterval];
    double slotPeriod = self.currentSlotPeriod;
    NSTimeInterval slotStartEpoch = floor(now / slotPeriod) * slotPeriod;
    NSDate *slotDate = [NSDate dateWithTimeIntervalSince1970:slotStartEpoch];
    NSString *curMode = self.modeName;

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
        msg.mode = curMode;
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
