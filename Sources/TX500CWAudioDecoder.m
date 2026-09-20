//
//  TX500CWAudioDecoder.m
//  Lab599 Utility
//
//  Real-Time DSP Morse Code Audio Decoder Engine
//

#import "TX500CWAudioDecoder.h"
#import <math.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

@implementation TX500CWSpectrumBin
@end

@implementation TX500CWDecodedToken
- (instancetype)init {
    self = [super init];
    if (self) {
        _text = @"";
        _timestamp = [NSDate date];
    }
    return self;
}
@end

@interface TX500CWAudioDecoder ()
@property (nonatomic, assign, readwrite) BOOL isListening;
@property (nonatomic, assign, readwrite) BOOL isAudioAvailable;
@property (nonatomic, assign, readwrite) BOOL isSignalDetected;
@property (nonatomic, assign, readwrite) double centerFrequencyHz;
@property (nonatomic, assign, readwrite) double estimatedWPM;
@property (nonatomic, assign, readwrite) double signalToNoiseRatioDb;
@property (nonatomic, assign, readwrite) double ditDahRatio;
@property (nonatomic, assign, readwrite) float audioInputLevel;

@property (nonatomic, copy, readwrite) NSString *rawDecodedText;
@property (nonatomic, copy, readwrite) NSString *activeCharacterBuffer;
@property (nonatomic, strong, readwrite) NSMutableArray<TX500CWDecodedToken *> *internalDecodedTokens;
@property (nonatomic, strong, readwrite) NSMutableArray<TX500CWSpectrumBin *> *internalSpectrumBins;
@property (nonatomic, strong, readwrite) NSMutableArray<NSDictionary<NSString *, NSString *> *> *internalAudioDevices;

// Audio Engine & DSP
@property (nonatomic, assign) AudioQueueRef audioQueue;
@property (nonatomic, assign) double sampleRate;
@property (nonatomic, assign) BOOL isMarkActive;
@property (nonatomic, assign) double currentMarkDuration;
@property (nonatomic, assign) double currentSpaceDuration;
@property (nonatomic, assign) double currentDitEstimate;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *recentDitDurations;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *recentDahDurations;
@property (nonatomic, assign) BOOL hasCommittedWordBreak;
@property (nonatomic, assign) NSInteger consecutiveCarrierWarnings;
@property (nonatomic, assign) float smoothedNoiseFloor;   // IIR adaptive noise floor estimate
@property (nonatomic, assign) float peakSignalLevel;       // Peak signal magnitude tracker for eye-pattern slicing
@property (nonatomic, assign) double pendingDropoutDuration; // Acoustic dropout / fade bridge duration

// Simulation
@property (nonatomic, strong, nullable) NSTimer *simulationTimer;
@property (nonatomic, assign) NSInteger simulationStep;
@property (nonatomic, strong) NSArray<NSString *> *simulationCorpus;
@property (nonatomic, assign) NSInteger simulationIndex;

@end

@implementation TX500CWAudioDecoder

+ (NSDictionary<NSString *, NSString *> *)reverseMorseAlphabet {
    static NSDictionary<NSString *, NSString *> *dict = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dict = @{
            @".-": @"A", @"-...": @"B", @"-.-.": @"C", @"-..": @"D", @".": @"E",
            @"..-.": @"F", @"--.": @"G", @"....": @"H", @"..": @"I", @".---": @"J",
            @"-.-": @"K", @".-..": @"L", @"--": @"M", @"-.": @"N", @"---": @"O",
            @".--.": @"P", @"--.-": @"Q", @".-.": @"R", @"...": @"S", @"-": @"T",
            @"..-": @"U", @"...-": @"V", @".--": @"W", @"-..-": @"X", @"-.--": @"Y",
            @"--..": @"Z",
            @".----": @"1", @"..---": @"2", @"...--": @"3", @"....-": @"4", @".....": @"5",
            @"-....": @"6", @"--...": @"7", @"---..": @"8", @"----.": @"9", @"-----": @"0",
            @"/": @"/", @"-..-.": @"/", @"..--..": @"?", @"--..--": @",",
            @".-.-.-": @".", @"-....-": @"-", @"-...-": @"=", @".--.-.": @"@",
            // Prosigns
            @".-.-.": @"<AR>",
            @"...-.-": @"<SK>",
            @".-...": @"<AS>",
            @"-.--.": @"<KN>",
            @"........": @"<HH>"
        };
    });
    return dict;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _nominalPitchHz = 650.0;
        _centerFrequencyHz = 650.0;
        _afcEnabled = YES;
        _estimatedWPM = 20.0;
        _ditDahRatio = 3.0;
        _currentDitEstimate = 0.060; // 20 WPM (60ms)
        _rawDecodedText = @"";
        _activeCharacterBuffer = @"";
        _internalDecodedTokens = [NSMutableArray array];
        _internalSpectrumBins = [NSMutableArray array];
        _internalAudioDevices = [NSMutableArray array];
        _recentDitDurations = [NSMutableArray array];
        _recentDahDurations = [NSMutableArray array];
        _hasCommittedWordBreak = YES;
        _sampleRate = 48000.0;

        _simulationCorpus = @[
            @"CQ CQ DE EP2AES EP2AES K",
            @"EP2AES DE DL1ABC GM UR 5NN 599 BK",
            @"DL1ABC DE EP2AES FB TU UR 5NN 599 NAME REZA QTH TEHRAN BK",
            @"EP2AES DE DL1ABC R 73 TU EE",
            @"CQ CQ DE OH2BH OH2BH TEST K",
            @"CQ DX DE 4Z4DX 4Z4DX K"
        ];

        [self refreshAudioDevices];
    }
    return self;
}

- (void)dealloc {
    [self stopListening];
    [self stopSimulation];
}

- (NSArray<TX500CWDecodedToken *> *)decodedTokens {
    @synchronized (self.internalDecodedTokens) {
        return [self.internalDecodedTokens copy];
    }
}

- (NSArray<TX500CWSpectrumBin *> *)spectrumBins {
    @synchronized (self.internalSpectrumBins) {
        return [self.internalSpectrumBins copy];
    }
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)availableAudioInputDevices {
    @synchronized (self.internalAudioDevices) {
        return [self.internalAudioDevices copy];
    }
}

- (void)setPitch:(double)hz {
    double clamped = fmax(450.0, fmin(950.0, hz));
    self.nominalPitchHz = clamped;
    self.centerFrequencyHz = clamped;
}

- (void)setNominalWPM:(double)wpm {
    double clamped = fmax(8.0, fmin(50.0, wpm));
    self.estimatedWPM = clamped;
    self.currentDitEstimate = 1.2 / clamped;
    [self.recentDitDurations removeAllObjects];
    [self.recentDahDurations removeAllObjects];
}

#pragma mark - Device Discovery

- (void)refreshAudioDevices {
    NSMutableArray *devices = [NSMutableArray array];
    
    // CoreAudio discovery
    AudioObjectPropertyAddress propertyAddress = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 dataSize = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize);
    if (status == noErr && dataSize > 0) {
        UInt32 deviceCount = dataSize / sizeof(AudioDeviceID);
        AudioDeviceID *deviceIDs = (AudioDeviceID *)malloc(dataSize);
        if (deviceIDs) {
            status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &propertyAddress, 0, NULL, &dataSize, deviceIDs);
            if (status == noErr) {
                for (UInt32 i = 0; i < deviceCount; i++) {
                    AudioDeviceID devID = deviceIDs[i];
                    
                    // Check if input device
                    AudioObjectPropertyAddress streamsAddress = {
                        kAudioDevicePropertyStreams,
                        kAudioDevicePropertyScopeInput,
                        kAudioObjectPropertyElementMain
                    };
                    UInt32 streamSize = 0;
                    if (AudioObjectGetPropertyDataSize(devID, &streamsAddress, 0, NULL, &streamSize) == noErr && streamSize > 0) {
                        // Read Device Name
                        CFStringRef nameRef = NULL;
                        UInt32 nameSize = sizeof(CFStringRef);
                        AudioObjectPropertyAddress nameAddress = {
                            kAudioDevicePropertyDeviceNameCFString,
                            kAudioObjectPropertyScopeGlobal,
                            kAudioObjectPropertyElementMain
                        };
                        NSString *devName = @"Unknown Device";
                        if (AudioObjectGetPropertyData(devID, &nameAddress, 0, NULL, &nameSize, &nameRef) == noErr && nameRef) {
                            devName = (__bridge_transfer NSString *)nameRef;
                        }
                        
                        // Read UID
                        CFStringRef uidRef = NULL;
                        UInt32 uidSize = sizeof(CFStringRef);
                        AudioObjectPropertyAddress uidAddress = {
                            kAudioDevicePropertyDeviceUID,
                            kAudioObjectPropertyScopeGlobal,
                            kAudioObjectPropertyElementMain
                        };
                        NSString *devUID = [NSString stringWithFormat:@"%u", (unsigned int)devID];
                        if (AudioObjectGetPropertyData(devID, &uidAddress, 0, NULL, &uidSize, &uidRef) == noErr && uidRef) {
                            devUID = (__bridge_transfer NSString *)uidRef;
                        }

                        BOOL isAD508 = [devName.lowercaseString containsString:@"usb audio"] ||
                                       [devName.lowercaseString containsString:@"c-media"] ||
                                       [devName.lowercaseString containsString:@"ad-508"] ||
                                       [devName.lowercaseString containsString:@"ad-509"];

                        [devices addObject:@{
                            @"name": devName,
                            @"uid": devUID,
                            @"isAD508": isAD508 ? @"YES" : @"NO"
                        }];
                    }
                }
            }
            free(deviceIDs);
        }
    }

    // Always ensure at least default device exists
    if (devices.count == 0) {
        [devices addObject:@{
            @"name": @"Default System Audio Input",
            @"uid": @"default",
            @"isAD508": @"NO"
        }];
    }

    @synchronized (self.internalAudioDevices) {
        [self.internalAudioDevices setArray:devices];
    }

    // Auto-select AD-508 / C-Media if found and none explicitly chosen
    if (!self.selectedAudioDeviceUID) {
        for (NSDictionary *d in devices) {
            if ([d[@"isAD508"] isEqualToString:@"YES"]) {
                self.selectedAudioDeviceUID = d[@"uid"];
                break;
            }
        }
    }
}


static void CWDecoderAudioInputCallback(void *inUserData,
                                       AudioQueueRef inAQ,
                                       AudioQueueBufferRef inBuffer,
                                       const AudioTimeStamp *inStartTime,
                                       UInt32 inNumberPacketDescriptions,
                                       const AudioStreamPacketDescription *inPacketDescs) {
    (void)inStartTime;
    (void)inNumberPacketDescriptions;
    (void)inPacketDescs;
    TX500CWAudioDecoder *decoder = (__bridge TX500CWAudioDecoder *)inUserData;
    if (decoder && inBuffer && inBuffer->mAudioDataByteSize > 0) {
        int sampleCount = inBuffer->mAudioDataByteSize / sizeof(float);
        const float *samples = (const float *)inBuffer->mAudioData;
        [decoder processRawAudioSamples:samples count:sampleCount];
    }
    if (inAQ && inBuffer) {
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    }
}

#pragma mark - Listening Control

- (void)startListening {
    if (self.isListening) return;

    [self stopSimulation];
    self.isSimulationActive = NO;

    // Check & request microphone permission on macOS if needed
    if (@available(macOS 10.14, *)) {
        AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (authStatus == AVAuthorizationStatusNotDetermined) {
            __weak typeof(self) weakSelf = self;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                if (granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [weakSelf startListening];
                    });
                }
            }];
            return;
        } else if (authStatus == AVAuthorizationStatusDenied || authStatus == AVAuthorizationStatusRestricted) {
            NSLog(@"TX500CWAudioDecoder: Microphone access denied by macOS security");
            self.isAudioAvailable = NO;
            return;
        }
    }

    AudioStreamBasicDescription fmt;
    memset(&fmt, 0, sizeof(fmt));
    fmt.mSampleRate = 48000.0;
    fmt.mFormatID = kAudioFormatLinearPCM;
    fmt.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    fmt.mBytesPerPacket = sizeof(float);
    fmt.mFramesPerPacket = 1;
    fmt.mBytesPerFrame = sizeof(float);
    fmt.mChannelsPerFrame = 1;
    fmt.mBitsPerChannel = 32;

    self.sampleRate = 48000.0;
    [self resetTimingState];

    AudioQueueRef queue = NULL;
    OSStatus err = AudioQueueNewInput(&fmt, CWDecoderAudioInputCallback, (__bridge void *)self, NULL, NULL, 0, &queue);
    if (err != noErr) {
        NSLog(@"TX500CWAudioDecoder: AudioQueueNewInput failed with error %d", (int)err);
        self.isAudioAvailable = NO;
        return;
    }

    // Set hardware device UID if explicitly selected
    if (self.selectedAudioDeviceUID && ![self.selectedAudioDeviceUID isEqualToString:@"default"]) {
        CFStringRef uid = (__bridge CFStringRef)self.selectedAudioDeviceUID;
        OSStatus devErr = AudioQueueSetProperty(queue, kAudioQueueProperty_CurrentDevice, &uid, sizeof(uid));
        if (devErr != noErr) {
            NSLog(@"TX500CWAudioDecoder: AudioQueueSetProperty CurrentDevice failed (%d) for UID '%@'", (int)devErr, self.selectedAudioDeviceUID);
        }
    }

    // Allocate 3 buffers of 2048 float samples each (42.6 ms per buffer)
    for (int i = 0; i < 3; i++) {
        AudioQueueBufferRef buf = NULL;
        OSStatus bErr = AudioQueueAllocateBuffer(queue, 2048 * sizeof(float), &buf);
        if (bErr == noErr && buf) {
            AudioQueueEnqueueBuffer(queue, buf, 0, NULL);
        }
    }

    err = AudioQueueStart(queue, NULL);
    if (err != noErr) {
        NSLog(@"TX500CWAudioDecoder: AudioQueueStart failed with error %d", (int)err);
        AudioQueueDispose(queue, true);
        self.isAudioAvailable = NO;
        return;
    }

    self.audioQueue = queue;
    self.isListening = YES;
    self.isAudioAvailable = YES;
}

- (void)stopListening {
    if (!self.isListening) return;

    if (self.audioQueue) {
        AudioQueueStop(self.audioQueue, true);
        AudioQueueDispose(self.audioQueue, true);
        self.audioQueue = NULL;
    }

    self.isListening = NO;
    self.isSignalDetected = NO;
    self.audioInputLevel = 0.0f;
    self.signalToNoiseRatioDb = 0.0;
    [self resetTimingState];
}

- (void)clearBuffer {
    self.rawDecodedText = @"";
    self.activeCharacterBuffer = @"";
    @synchronized (self.internalDecodedTokens) {
        [self.internalDecodedTokens removeAllObjects];
    }
    [self resetTimingState];
    if (self.onDecodedTextUpdated) {
        self.onDecodedTextUpdated(@"", @"");
    }
}

- (void)resetTimingState {
    self.isMarkActive = NO;
    self.currentMarkDuration = 0.0;
    self.currentSpaceDuration = 0.0;
    self.currentDitEstimate = 1.2 / fmax(10.0, self.estimatedWPM);
    [self.recentDitDurations removeAllObjects];
    [self.recentDahDurations removeAllObjects];
    self.hasCommittedWordBreak = YES;
    self.consecutiveCarrierWarnings = 0;
    self.smoothedNoiseFloor = 0.0f; // Will re-adapt from first buffer
    self.peakSignalLevel = 0.005f;
    self.pendingDropoutDuration = 0.0;
}

#pragma mark - Goertzel Algorithm & DSP Processing

static inline float GoertzelMagnitude(const float *data, int frameCount, double targetFreq, double sampleRate) {
    if (frameCount <= 0 || sampleRate <= 0) return 0.0f;
    double omega = (2.0 * M_PI * targetFreq) / sampleRate;
    double cosine = cos(omega);
    double sine = sin(omega);
    double coeff = 2.0 * cosine;

    double q0 = 0.0;
    double q1 = 0.0;
    double q2 = 0.0;

    for (int i = 0; i < frameCount; i++) {
        q0 = coeff * q1 - q2 + (double)data[i];
        q2 = q1;
        q1 = q0;
    }

    double real = q1 - q2 * cosine;
    double imag = q2 * sine;
    double power = real * real + imag * imag;
    return (float)sqrt(power) / (float)frameCount;
}

- (void)processAudioBuffer:(AVAudioPCMBuffer *)buffer {
    int totalFrames = (int)buffer.frameLength;
    if (totalFrames <= 0 || !buffer.floatChannelData) return;

    // Multi-channel support (mix Left + Right or pick active channel)
    float *mixedBuffer = NULL;
    const float *channelData = buffer.floatChannelData[0];
    if (buffer.format.channelCount > 1 && buffer.floatChannelData[1]) {
        mixedBuffer = (float *)malloc(totalFrames * sizeof(float));
        const float *ch0 = buffer.floatChannelData[0];
        const float *ch1 = buffer.floatChannelData[1];
        for (int i = 0; i < totalFrames; i++) {
            mixedBuffer[i] = 0.5f * (ch0[i] + ch1[i]);
        }
        channelData = mixedBuffer;
    }

    [self processRawAudioSamples:channelData count:totalFrames];

    if (mixedBuffer) {
        free(mixedBuffer);
    }
}

- (void)processRawAudioSamples:(const float *)channelData count:(int)totalFrames {
    if (totalFrames <= 0 || !channelData) return;

    // 1. Peak Level
    float peak = 0.0f;
    for (int i = 0; i < totalFrames; i += 8) {
        float val = fabsf(channelData[i]);
        if (val > peak) peak = val;
    }
    self.audioInputLevel = peak;

    // 2. Multi-Bin Spectrum (32 bins: 400 - 950 Hz)
    NSMutableArray<TX500CWSpectrumBin *> *bins = [NSMutableArray arrayWithCapacity:32];
    double startFreq = 400.0;
    double stepFreq = (950.0 - 400.0) / 31.0;
    float peakBinMag = 0.0f;
    int peakBinIdx = 0;
    float sortedMags[32];

    for (int b = 0; b < 32; b++) {
        double f = startFreq + (double)b * stepFreq;
        float mag = GoertzelMagnitude(channelData, totalFrames, f, self.sampleRate);
        sortedMags[b] = mag;

        TX500CWSpectrumBin *bin = [TX500CWSpectrumBin new];
        bin.binId = b;
        bin.frequencyHz = f;
        bin.magnitude = mag;
        [bins addObject:bin];

        if (mag > peakBinMag) {
            peakBinMag = mag;
            peakBinIdx = b;
        }
    }

    // Sort to compute the true median/quartile background noise floor
    // (Median is 100% immune to CW tone leakage!)
    for (int i = 0; i < 31; i++) {
        for (int j = i + 1; j < 32; j++) {
            if (sortedMags[j] < sortedMags[i]) {
                float tmp = sortedMags[i];
                sortedMags[i] = sortedMags[j];
                sortedMags[j] = tmp;
            }
        }
    }
    float bandNoiseFloor = fmaxf(0.0003f, sortedMags[8]); // 25th percentile

    @synchronized (self.internalSpectrumBins) {
        [self.internalSpectrumBins setArray:bins];
    }

    // 3. Wide-Band AFC with Sub-Bin Quadratic Interpolation
    //    Enables tracking any CW signal across 400 - 950 Hz
    double fPeak = startFreq + (double)peakBinIdx * stepFreq;
    double fExact = fPeak;
    if (peakBinIdx > 0 && peakBinIdx < 31) {
        float y1 = bins[peakBinIdx - 1].magnitude;
        float y2 = bins[peakBinIdx].magnitude;
        float y3 = bins[peakBinIdx + 1].magnitude;
        float denom = 2.0f * (2.0f * y2 - y1 - y3);
        if (fabsf(denom) > 1e-6) {
            float delta = (y3 - y1) / denom;
            fExact = fPeak + (double)delta * stepFreq;
        }
    }

    if (self.afcEnabled) {
        // Only track if a distinct CW peak exists above the noise floor (prevents drift on room noise)
        if (peakBinMag > bandNoiseFloor * 2.8f && peakBinMag > 0.0012f) {
            double deltaF = fabs(fExact - self.centerFrequencyHz);
            double alpha = (deltaF > 60.0) ? 0.30 : 0.12;
            self.centerFrequencyHz = self.centerFrequencyHz * (1.0 - alpha) + fExact * alpha;
        }
    } else {
        self.centerFrequencyHz = self.nominalPitchHz;
    }

    // 4. Sub-chunk processing (512 samples ≈ 10.7 ms at 48kHz, 11.6 ms at 44.1kHz)
    int chunkSize = 512;
    int chunkCount = totalFrames / chunkSize;
    double chunkDurationSec = (double)chunkSize / self.sampleRate;

    // Smooth the noise floor
    if (self.smoothedNoiseFloor < 0.0001f) {
        self.smoothedNoiseFloor = bandNoiseFloor;
    } else {
        self.smoothedNoiseFloor = self.smoothedNoiseFloor * 0.90f + bandNoiseFloor * 0.10f;
    }
    float localNoiseFloor = fmaxf(0.0003f, self.smoothedNoiseFloor);

    for (int c = 0; c < chunkCount; c++) {
        const float *chunkPtr = channelData + (c * chunkSize);

        float targetMag = GoertzelMagnitude(chunkPtr, chunkSize, self.centerFrequencyHz, self.sampleRate);
        double snrRatio = (double)targetMag / (double)localNoiseFloor;
        self.signalToNoiseRatioDb = 20.0 * log10(fmax(1.0, snrRatio));

        // Track peak signal level with fast attack and slow decay (with safety floor above noise floor)
        if (targetMag > self.peakSignalLevel) {
            self.peakSignalLevel = targetMag;
        } else {
            self.peakSignalLevel = fmaxf(localNoiseFloor * 2.2f, self.peakSignalLevel * 0.9992f);
        }

        // 50% Eye-Pattern Adaptive Slicing:
        // Slices at the midpoint between peak signal and noise floor to eliminate
        // room-reverberation mark elongation (prevents Dits/Dahs from eating the spaces!)
        float signalSpan = fmaxf(0.0008f, self.peakSignalLevel - localNoiseFloor);
        float onThreshold  = localNoiseFloor + 0.44f * signalSpan;
        float offThreshold = localNoiseFloor + 0.26f * signalSpan;

        if (!self.isMarkActive) {
            if (targetMag >= onThreshold && snrRatio >= 1.30) {
                // Space → Mark transition
                [self handleMarkOnset:self.currentSpaceDuration];
                self.currentSpaceDuration = 0.0;
                self.currentMarkDuration = chunkDurationSec;
                self.pendingDropoutDuration = 0.0;
                self.isMarkActive = YES;
                self.isSignalDetected = YES;
            } else {
                self.currentSpaceDuration += chunkDurationSec;
                [self handleSpaceProgression:self.currentSpaceDuration];
            }
        } else {
            if (targetMag < offThreshold || snrRatio < 1.15) {
                // Signal dipped below threshold: could be mark end OR an acoustic notch / dropout
                self.pendingDropoutDuration += chunkDurationSec;

                // Hang time: require at least 18ms (~2 chunks) of confirmed quiet before ending mark
                if (self.pendingDropoutDuration >= 0.018) {
                    [self handleMarkEnd:self.currentMarkDuration];
                    self.currentMarkDuration = 0.0;
                    self.currentSpaceDuration = self.pendingDropoutDuration;
                    self.pendingDropoutDuration = 0.0;
                    self.isMarkActive = NO;
                    self.isSignalDetected = NO;
                }
            } else {
                // Signal is active: bridge any momentary acoustic dropout (< 18ms) seamlessly
                if (self.pendingDropoutDuration > 0.0) {
                    self.currentMarkDuration += self.pendingDropoutDuration;
                    self.pendingDropoutDuration = 0.0;
                }
                self.currentMarkDuration += chunkDurationSec;

                if (self.currentMarkDuration > 2.5) {
                    // Continuous carrier runaway protection (tune signal)
                    self.consecutiveCarrierWarnings++;
                    self.isMarkActive = NO;
                    self.currentMarkDuration = 0.0;
                    self.pendingDropoutDuration = 0.0;
                }
            }
        }
    }

    // Callbacks on main queue
    if (self.onMetricsUpdated) {
        double wpm = self.estimatedWPM;
        double snr = self.signalToNoiseRatioDb;
        float level = self.audioInputLevel;
        BOOL sig = self.isSignalDetected;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onMetricsUpdated) self.onMetricsUpdated(wpm, snr, level, sig);
        });
    }

    if (self.onSpectrumUpdated) {
        NSArray *snap = [self.spectrumBins copy];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onSpectrumUpdated) self.onSpectrumUpdated(snap);
        });
    }
}

#pragma mark - Morse Timing Classification

- (void)handleMarkOnset:(double)spaceDuration {
    (void)spaceDuration;
}

- (void)handleMarkEnd:(double)markDuration {
    if (markDuration < 0.018) {
        // Debounce glitch / room acoustic spike < 18ms
        return;
    }

    // Bayesian decision boundary between Dit and Dah:
    // Optimal threshold between Dit (1.0) and Dah (3.0) is ~1.90
    double ditThreshold = self.currentDitEstimate * 1.90;

    if (markDuration < ditThreshold) {
        // Mark is a Dit '.'
        self.activeCharacterBuffer = [self.activeCharacterBuffer stringByAppendingString:@"."];
        [self updateSpeedWithNormalizedDit:markDuration];
    } else {
        // Mark is a Dah '-'
        self.activeCharacterBuffer = [self.activeCharacterBuffer stringByAppendingString:@"-"];
        [self updateSpeedWithNormalizedDit:(markDuration / 3.0)];
        if (self.currentDitEstimate > 0.001) {
            self.ditDahRatio = markDuration / self.currentDitEstimate;
        }
    }

    self.hasCommittedWordBreak = NO;

    if (self.onDecodedTextUpdated) {
        NSString *raw = self.rawDecodedText;
        NSString *buf = self.activeCharacterBuffer;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onDecodedTextUpdated) self.onDecodedTextUpdated(raw, buf);
        });
    }
}

- (void)handleSpaceProgression:(double)spaceDuration {
    // Character Break: space >= 2.25 dits
    // Optimal midpoint between 1.0-dit element space and 3.0-dit char space
    // Accommodates Farnsworth inter-element hesitations (~1.0 - 1.5 dits) without splitting characters
    double charBreakThreshold = self.currentDitEstimate * 2.25;
    if (spaceDuration >= charBreakThreshold && self.activeCharacterBuffer.length > 0) {
        [self commitActiveCharacter];
    }

    // Word Break: space >= 5.0 dits
    // Standard word space is 7.0 dits
    double wordBreakThreshold = self.currentDitEstimate * 5.0;
    if (spaceDuration >= wordBreakThreshold && !self.hasCommittedWordBreak) {
        [self commitWordBreak];
    }
}

- (void)commitActiveCharacter {
    if (self.activeCharacterBuffer.length == 0) return;

    NSDictionary *dict = [TX500CWAudioDecoder reverseMorseAlphabet];
    NSString *symbol = dict[self.activeCharacterBuffer];
    if (!symbol) {
        // Unknown symbol or noise fragment
        symbol = @"*";
    }

    self.rawDecodedText = [self.rawDecodedText stringByAppendingString:symbol];
    self.activeCharacterBuffer = @"";

    if (self.onDecodedTextUpdated) {
        NSString *raw = self.rawDecodedText;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onDecodedTextUpdated) self.onDecodedTextUpdated(raw, @"");
        });
    }
}

- (void)commitWordBreak {
    self.hasCommittedWordBreak = YES;
    if (self.rawDecodedText.length > 0 && ![self.rawDecodedText hasSuffix:@" "]) {
        self.rawDecodedText = [self.rawDecodedText stringByAppendingString:@" "];

        // Parse last token
        NSArray *words = [self.rawDecodedText componentsSeparatedByString:@" "];
        if (words.count >= 2) {
            NSString *lastWord = words[words.count - 2];
            if (lastWord.length > 0) {
                [self processCompletedToken:lastWord];
            }
        }

        if (self.onDecodedTextUpdated) {
            NSString *raw = self.rawDecodedText;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.onDecodedTextUpdated) self.onDecodedTextUpdated(raw, @"");
            });
        }
    }
}

- (void)processCompletedToken:(NSString *)word {
    TX500CWDecodedToken *token = [TX500CWDecodedToken new];
    token.text = word;
    token.timestamp = [NSDate date];

    // Check if Callsign (contains digit, length 3-8, letters and digits)
    NSRegularExpression *callRegex = [NSRegularExpression regularExpressionWithPattern:@"^[A-Z0-9]{1,3}[0-9][A-Z0-9]{1,4}$" options:0 error:nil];
    if ([callRegex numberOfMatchesInString:word options:0 range:NSMakeRange(0, word.length)] > 0) {
        token.isCallsign = YES;
    }

    // Check if RST report
    if ([word isEqualToString:@"599"] || [word isEqualToString:@"5NN"] || [word hasPrefix:@"579"] || [word hasPrefix:@"589"]) {
        token.isReport = YES;
    }

    // Check if Q-Code
    if ([word hasPrefix:@"Q"] && word.length == 3) {
        token.isQCode = YES;
    }

    @synchronized (self.internalDecodedTokens) {
        [self.internalDecodedTokens addObject:token];
        if (self.internalDecodedTokens.count > 50) {
            [self.internalDecodedTokens removeObjectAtIndex:0];
        }
    }

    if (self.onTokenReceived) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onTokenReceived) self.onTokenReceived(token);
        });
    }
}

- (void)updateSpeedWithNormalizedDit:(double)ditDuration {
    // Only accept realistic Morse speed range: 8 WPM (150ms) to 50 WPM (24ms)
    if (ditDuration < 0.020 || ditDuration > 0.160) return;

    [self.recentDitDurations addObject:@(ditDuration)];
    if (self.recentDitDurations.count > 16) {
        [self.recentDitDurations removeObjectAtIndex:0];
    }

    // Running median calculation
    NSArray *sorted = [self.recentDitDurations sortedArrayUsingSelector:@selector(compare:)];
    double medianDit = [sorted[sorted.count / 2] doubleValue];

    // Fast convergence when starting or after speed change; stable smoothing thereafter
    double alpha = (self.recentDitDurations.count <= 4) ? 0.65 : 0.25;
    self.currentDitEstimate = self.currentDitEstimate * (1.0 - alpha) + medianDit * alpha;

    // Recalculate estimated WPM = 1.2 / dit
    double wpm = 1.2 / self.currentDitEstimate;
    self.estimatedWPM = fmax(8.0, fmin(50.0, wpm));
}

#pragma mark - Simulation / Practice Generator

- (void)startSimulation {
    if (self.isSimulationActive) return;
    [self stopListening];

    self.isSimulationActive = YES;
    self.isAudioAvailable = YES;
    self.sampleRate = 48000.0;
    [self resetTimingState];

    self.simulationIndex = 0;
    self.simulationStep = 0;

    __weak typeof(self) weakSelf = self;
    self.simulationTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf runSimulationStep];
    }];
    [self runSimulationStep];
}

- (void)stopSimulation {
    [self.simulationTimer invalidate];
    self.simulationTimer = nil;
    self.isSimulationActive = NO;
}

- (void)runSimulationStep {
    if (!self.isSimulationActive) return;
    if (self.simulationCorpus.count == 0) return;

    NSString *msg = self.simulationCorpus[self.simulationIndex % self.simulationCorpus.count];
    self.simulationIndex++;

    [self feedSyntheticMorseString:msg wpm:22.0 pitchHz:self.nominalPitchHz];
}

- (void)feedSyntheticMorseString:(NSString *)morseText wpm:(double)wpm pitchHz:(double)pitchHz {
    double ditSec = 1.2 / fmax(10.0, wpm);
    double dahSec = ditSec * 3.0;
    double elemSpaceSec = ditSec;
    double charSpaceSec = ditSec * 3.0;
    double wordSpaceSec = ditSec * 7.0;

    NSDictionary *charToMorse = @{
        @"A": @".-", @"B": @"-...", @"C": @"-.-.", @"D": @"-..", @"E": @".",
        @"F": @"..-.", @"G": @"--.", @"H": @"....", @"I": @"..", @"J": @".---",
        @"K": @"-.-", @"L": @".-..", @"M": @"--", @"N": @"-.", @"O": @"---",
        @"P": @".--.", @"Q": @"--.-", @"R": @".-.", @"S": @"...", @"T": @"-",
        @"U": @"..-", @"V": @"...-", @"W": @".--", @"X": @"-..-", @"Y": @"-.--",
        @"Z": @"--..",
        @"1": @".----", @"2": @"..---", @"3": @"...--", @"4": @"....-", @"5": @".....",
        @"6": @"-....", @"7": @"--...", @"8": @"---..", @"9": @"----.", @"0": @"-----",
        @"?": @"..--..", @"/": @"-..-.", @".": @".-.-.-", @"=": @"-...-"
    };

    NSString *upper = morseText.uppercaseString;
    NSArray *words = [upper componentsSeparatedByString:@" "];

    for (NSInteger w = 0; w < (NSInteger)words.count; w++) {
        NSString *word = words[w];
        for (NSInteger c = 0; c < (NSInteger)word.length; c++) {
            NSString *ch = [word substringWithRange:NSMakeRange(c, 1)];
            NSString *pattern = charToMorse[ch];
            if (!pattern) continue;

            for (NSInteger p = 0; p < (NSInteger)pattern.length; p++) {
                unichar symbol = [pattern characterAtIndex:p];
                double duration = (symbol == '-') ? dahSec : ditSec;
                [self feedSyntheticAudioWithFrequency:pitchHz duration:duration isMark:YES];
                [self feedSyntheticAudioWithFrequency:pitchHz duration:elemSpaceSec isMark:NO];
            }
            [self feedSyntheticAudioWithFrequency:pitchHz duration:charSpaceSec isMark:NO];
        }
        [self feedSyntheticAudioWithFrequency:pitchHz duration:wordSpaceSec isMark:NO];
    }
}

- (void)feedSyntheticAudioWithFrequency:(double)freq duration:(double)duration isMark:(BOOL)isMark {
    int frameCount = (int)(duration * self.sampleRate);
    frameCount = (frameCount / 256) * 256;
    if (frameCount <= 0) frameCount = 256;

    float *buffer = (float *)malloc(frameCount * sizeof(float));
    if (!buffer) return;

    double omega = 2.0 * M_PI * freq / self.sampleRate;
    for (int i = 0; i < frameCount; i++) {
        float noise = ((float)rand() / (float)RAND_MAX - 0.5f) * 0.001f;
        if (isMark) {
            float envelope = 1.0f;
            int ramp = (int)(0.004 * self.sampleRate);
            if (i < ramp) {
                envelope = 0.5f * (1.0f - cosf((float)i / (float)ramp * (float)M_PI));
            } else if (i > frameCount - ramp) {
                envelope = 0.5f * (1.0f - cosf((float)(frameCount - i) / (float)ramp * (float)M_PI));
            }
            buffer[i] = 0.18f * envelope * sin(omega * (double)i) + noise;
        } else {
            buffer[i] = noise;
        }
    }

    [self processRawAudioSamples:buffer count:frameCount];
    free(buffer);
}

@end
