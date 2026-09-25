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
#import <CoreAudio/CATapDescription.h>
#import <CoreAudio/AudioHardwareTapping.h>

NSString * const TX500CWSystemAudioDeviceUID = @"cw-system-audio";

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
@property (atomic, assign) NSUInteger outputGeneration;
@property (nonatomic, strong) NSMutableData *diagnosticPCM;
@property (nonatomic, assign) double currentMarkDuration;
@property (nonatomic, assign) double currentSpaceDuration;
@property (nonatomic, assign) double currentDitEstimate;
@property (nonatomic, assign) BOOL hasCommittedWordBreak;
@property (nonatomic, assign) float smoothedNoiseFloor;   // IIR adaptive noise floor estimate
@property (nonatomic, assign) float smoothedTargetMag;      // IIR smoothed tone magnitude for noise suppression
@property (nonatomic, assign) float peakSignalLevel;       // Peak signal magnitude tracker for eye-pattern slicing
@property (nonatomic, assign) double pendingDropoutDuration; // Acoustic dropout / fade bridge duration

// Simulation
@property (nonatomic, strong, nullable) NSTimer *simulationTimer;
@property (nonatomic, assign) NSInteger simulationStep;
@property (nonatomic, strong) NSArray<NSString *> *simulationCorpus;
@property (nonatomic, assign) NSInteger simulationIndex;

@end

@implementation TX500CWAudioDecoder {
    // Fixed-duration analysis blocks; no samples are lost at callback boundaries.
    float _analysis[8192];
    float _window[8192];
    float _weighted[8192];
    int _analysisCount, _analysisLength;
    double _windowSum, _quietSeconds;
    BOOL _frequencyLocked, _timingLocked, _replayingTiming, _carrierTrusted;
    NSUInteger _confirmedToneWindows;
    double _precedingSpaceDuration, _markBias;
    NSMutableArray<NSDictionary *> *_timingRuns;
    NSMutableArray<NSNumber *> *_characterMarks;
    AudioObjectID _systemTap;
    AudioObjectID _systemAggregate;
    AudioDeviceIOProcID _systemIOProc;
    dispatch_queue_t _systemAudioQueue;
    AVAudioFormat *_systemAudioFormat;
    BOOL _systemFormatListenerInstalled;
    NSUInteger _listeningRequest;
    uint64_t _systemReceivedFrames;
    NSUInteger _systemReceivedBuffers;

}

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
        _timingRuns = [NSMutableArray array];
        _characterMarks = [NSMutableArray array];
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

        AudioObjectPropertyAddress devAddr = {
            kAudioHardwarePropertyDevices,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        AudioObjectAddPropertyListener(kAudioObjectSystemObject, &devAddr, CWAudioHardwareDevicesListener, (__bridge void *)self);
    }
    return self;
}

static OSStatus CWAudioHardwareDevicesListener(AudioObjectID inObjectID,
                                              UInt32 inNumberAddresses,
                                              const AudioObjectPropertyAddress *inAddresses,
                                              void *inClientData) {
    (void)inObjectID; (void)inNumberAddresses; (void)inAddresses;
    TX500CWAudioDecoder *decoder = (__bridge TX500CWAudioDecoder *)inClientData;
    if (decoder) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [decoder refreshAudioDevices];
        });
    }
    return noErr;
}

- (void)dealloc {
    AudioObjectPropertyAddress devAddr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectRemovePropertyListener(kAudioObjectSystemObject, &devAddr, CWAudioHardwareDevicesListener, (__bridge void *)self);

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
    if (!isfinite(hz)) return;
    @synchronized (self) {
        double clamped = fmax(300.0, fmin(1500.0, hz));
        self.nominalPitchHz = clamped;
        self.centerFrequencyHz = clamped;
        [self resetTimingState];
    }
}

- (void)setNominalWPM:(double)wpm {
    if (!isfinite(wpm)) return;
    @synchronized (self) {
        self.estimatedWPM = fmax(3.0, fmin(60.0, wpm));
        [self resetTimingState];
    }
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

                        if ([devUID hasPrefix:@"ir.factoreal.cw.capture."]) continue;

                        // Transport type
                        AudioObjectPropertyAddress transAddr = {
                            kAudioDevicePropertyTransportType,
                            kAudioObjectPropertyScopeGlobal,
                            kAudioObjectPropertyElementMain
                        };
                        UInt32 transport = 0;
                        UInt32 transSize = sizeof(UInt32);
                        AudioObjectGetPropertyData(devID, &transAddr, 0, NULL, &transSize, &transport);

                        NSString *lower = devName.lowercaseString;
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

                        NSString *displayName = devName;
                        if (isExplicitAD508) {
                            displayName = [NSString stringWithFormat:@"★ %@ (AD-508 USB-C)", devName];
                        } else if (isRadioOrUSB && !isVirtual) {
                            displayName = [NSString stringWithFormat:@"★ %@ (Radio USB Audio)", devName];
                        } else if (isVirtual) {
                            displayName = [NSString stringWithFormat:@"%@ (Virtual)", devName];
                        }

                        [devices addObject:@{
                            @"name": devName,
                            @"displayName": displayName,
                            @"uid": devUID,
                            @"isAD508": isExplicitAD508 ? @"YES" : @"NO",
                            @"isUSB": (isRadioOrUSB && !isVirtual) ? @"YES" : @"NO",
                            @"isVirtual": isVirtual ? @"YES" : @"NO"
                        }];
                    }
                }
            }
            free(deviceIDs);
        }
    }

    // Sort: AD-508 / USB Audio first, BuiltIn second, Virtual third
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
    [devices sortUsingComparator:comp];

    // Always ensure at least default device exists
    if (devices.count == 0) {
        [devices addObject:@{
            @"name": @"Default System Audio Input",
            @"displayName": @"Default System Audio Input",
            @"uid": @"default",
            @"isAD508": @"NO",
            @"isUSB": @"NO",
            @"isVirtual": @"NO"
        }];
    }

    if (@available(macOS 14.2, *)) {
        [devices addObject:@{@"name": @"System Audio", @"displayName": @"System Audio (Direct)",
                             @"uid": TX500CWSystemAudioDeviceUID,
                             @"isAD508": @"NO", @"isUSB": @"NO", @"isVirtual": @"YES"}];
    }
    @synchronized (self.internalAudioDevices) {
        [self.internalAudioDevices setArray:devices];
    }

    // Smart selection
    NSString *bestAD508UID = nil;
    NSString *bestUSBUID = nil;
    BOOL selectedValid = NO;
    for (NSDictionary *d in devices) {
        if ([d[@"uid"] isEqualToString:self.selectedAudioDeviceUID]) {
            selectedValid = YES;
        }
        if ([d[@"isAD508"] isEqualToString:@"YES"] && !bestAD508UID) bestAD508UID = d[@"uid"];
        if ([d[@"isUSB"] isEqualToString:@"YES"] && !bestUSBUID) bestUSBUID = d[@"uid"];
    }

    if (!self.preserveDeviceSelection && (!selectedValid || !self.selectedAudioDeviceUID)) {
        if (bestAD508UID) {
            self.selectedAudioDeviceUID = bestAD508UID;
        } else if (bestUSBUID) {
            self.selectedAudioDeviceUID = bestUSBUID;
        } else {
            self.selectedAudioDeviceUID = devices.firstObject[@"uid"];
        }
    }

    if (self.onAudioDevicesChanged) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.onAudioDevicesChanged) self.onAudioDevicesChanged();
        });
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

#pragma mark - Direct System Audio (macOS 14.2+)

- (void)reportAudioError:(NSString *)message {
    self.isAudioAvailable = NO;
    if (self.onAudioError) self.onAudioError(message);
}

static OSStatus CWSystemAudioFormatChanged(AudioObjectID object, UInt32 count,
                                           const AudioObjectPropertyAddress *addresses, void *context) {
    (void)count; (void)addresses;
    TX500CWAudioDecoder *decoder = (__bridge TX500CWAudioDecoder *)context;
    __weak TX500CWAudioDecoder *weakDecoder = decoder;
    dispatch_async(dispatch_get_main_queue(), ^{
        TX500CWAudioDecoder *strongDecoder = weakDecoder;
        if (strongDecoder && strongDecoder->_systemTap == object) {
            [strongDecoder stopListening];
            [strongDecoder reportAudioError:@"The system audio format changed. Press START DECODER to reconnect."];
        }
    });
    return noErr;
}

- (void)consumeSystemAudio:(const AudioBufferList *)input format:(AVAudioFormat *)format {
    if (!input || !input->mNumberBuffers || !format) return;
    // The HAL owns these samples. Consume synchronously; never retain its buffer.
    for (UInt32 i = 0; i < input->mNumberBuffers; i++)
        if (!input->mBuffers[i].mData || !input->mBuffers[i].mDataByteSize) return;
    AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format
                                                    bufferListNoCopy:input deallocator:nil];
    if (pcm) {
        @synchronized (self) {
            _systemReceivedFrames += pcm.frameLength;
            _systemReceivedBuffers++;
            [self processAudioBuffer:pcm];
        }
    }
}

- (void)stopSystemAudio {
    // Do not hold the DSP lock while stopping: CoreAudio waits for callbacks.
    if (@available(macOS 14.2, *)) {
        if (_systemTap && _systemFormatListenerInstalled) {
            AudioObjectPropertyAddress address = {kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            AudioObjectRemovePropertyListener(_systemTap, &address, CWSystemAudioFormatChanged, (__bridge void *)self);
            _systemFormatListenerInstalled = NO;
        }
        if (_systemAggregate && _systemIOProc) {
            AudioDeviceStop(_systemAggregate, _systemIOProc);
            AudioDeviceDestroyIOProcID(_systemAggregate, _systemIOProc);
        }
        _systemIOProc = NULL;
        if (_systemAggregate) AudioHardwareDestroyAggregateDevice(_systemAggregate);
        _systemAggregate = kAudioObjectUnknown;
        if (_systemTap) AudioHardwareDestroyProcessTap(_systemTap);
        _systemTap = kAudioObjectUnknown;
    }
    _systemAudioFormat = nil;
    _systemAudioQueue = nil;
}

- (void)startSystemAudio {
    if (@available(macOS 14.2, *)) {
        [self stopSystemAudio];
        _systemReceivedFrames = _systemReceivedBuffers = 0;
        CATapDescription *description = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
        description.name = @"Lab599 CW System Audio";
        description.privateTap = YES;
        description.muteBehavior = CATapUnmuted; // Preserve normal speaker/headphone playback.
        OSStatus status = AudioHardwareCreateProcessTap(description, &_systemTap);
        if (status == noErr && _systemTap) {
            AudioStreamBasicDescription asbd = {0};
            UInt32 size = sizeof(asbd);
            AudioObjectPropertyAddress address = {kAudioTapPropertyFormat, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            status = AudioObjectGetPropertyData(_systemTap, &address, 0, NULL, &size, &asbd);
            if (status == noErr) {
                _systemAudioFormat = [[AVAudioFormat alloc] initWithStreamDescription:&asbd];
                if (_systemAudioFormat.commonFormat != AVAudioPCMFormatFloat32 ||
                    asbd.mSampleRate < 8000 || asbd.mSampleRate > 192000)
                    status = kAudioFormatUnsupportedDataFormatError;
            }
            if (status == noErr) {
                // A tap-only aggregate has no microphone streams and never becomes
                // the system default device. No virtual audio driver is installed.
                NSDictionary *settings = @{
                    @kAudioAggregateDeviceNameKey: @"Lab599 CW System Audio",
                    @kAudioAggregateDeviceUIDKey: [@"ir.factoreal.cw.capture." stringByAppendingString:NSUUID.UUID.UUIDString],
                    @kAudioAggregateDeviceIsPrivateKey: @YES,
                    @kAudioAggregateDeviceTapAutoStartKey: @YES,
                    @kAudioAggregateDeviceTapListKey: @[@{
                        @kAudioSubTapUIDKey: description.UUID.UUIDString,
                        @kAudioSubTapDriftCompensationKey: @YES
                    }]
                };
                status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)settings, &_systemAggregate);
                if (status == noErr && _systemAggregate) {
                    // Match the aggregate clock to the tap format (e.g. 44.1 kHz
                    // headphones). Interpreting it as 48 kHz shifts pitch and WPM.
                    Float64 rate = asbd.mSampleRate;
                    AudioObjectPropertyAddress rateAddress = {kAudioDevicePropertyNominalSampleRate,
                        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                    status = AudioObjectSetPropertyData(_systemAggregate, &rateAddress, 0, NULL, sizeof(rate), &rate);
                }
            }
            if (status == noErr && _systemAggregate) {
                _systemAudioQueue = dispatch_queue_create("ir.factoreal.cw.system-audio", DISPATCH_QUEUE_SERIAL);
                __weak typeof(self) weakSelf = self;
                AVAudioFormat *format = _systemAudioFormat;
                status = AudioDeviceCreateIOProcIDWithBlock(&_systemIOProc, _systemAggregate, _systemAudioQueue,
                    ^(const AudioTimeStamp *now, const AudioBufferList *input, const AudioTimeStamp *inputTime,
                      AudioBufferList *output, const AudioTimeStamp *outputTime) {
                        (void)now; (void)inputTime; (void)output; (void)outputTime;
                        @autoreleasepool { [weakSelf consumeSystemAudio:input format:format]; }
                    });
                if (status == noErr) status = AudioDeviceStart(_systemAggregate, _systemIOProc);
            }
            if (status == noErr && _systemIOProc) {
                _systemFormatListenerInstalled = AudioObjectAddPropertyListener(_systemTap, &address,
                    CWSystemAudioFormatChanged, (__bridge void *)self) == noErr;
                self.isListening = YES;
                self.isAudioAvailable = YES;
                if (self.onListeningStateChanged) self.onListeningStateChanged(YES);
                return;
            }
        }
        [self stopSystemAudio];
        [self reportAudioError:[NSString stringWithFormat:
            @"Cannot start System Audio (error %d). Allow Lab599 Utility in System Settings → Privacy & Security → Screen & System Audio Recording, then try again.", (int)status]];
    } else {
        [self reportAudioError:@"Direct System Audio requires macOS 14.2 or later. Select a microphone or virtual audio input on this Mac."];
    }
}

#pragma mark - Listening Control

- (void)startListening {
    if (self.isListening) return;
    if(self.preserveDeviceSelection && !self.selectedAudioDeviceUID.length) { [self reportAudioError:@"Choose an audio input next to Start Decoder in CW Station."]; return; }
    NSUInteger request = ++_listeningRequest;

    [self stopSimulation];
    self.isSimulationActive = NO;

    if ([self.selectedAudioDeviceUID isEqualToString:TX500CWSystemAudioDeviceUID]) {
        [self resetTimingState];
        [self startSystemAudio];
        return;
    }

    // System audio uses its own macOS permission, not microphone permission.
    // Check & request microphone permission on macOS if needed
    if (@available(macOS 10.14, *)) {
        AVAuthorizationStatus authStatus = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
        if (authStatus == AVAuthorizationStatusNotDetermined) {
            __weak typeof(self) weakSelf = self;
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) {
                if (granted) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        TX500CWAudioDecoder *strongSelf = weakSelf;
                        if (strongSelf && strongSelf->_listeningRequest == request) [strongSelf startListening];
                    });
                }
            }];
            return;
        } else if (authStatus == AVAuthorizationStatusDenied || authStatus == AVAuthorizationStatusRestricted) {
            NSLog(@"TX500CWAudioDecoder: Microphone access denied by macOS security");
            [self reportAudioError:@"Microphone access is disabled. Allow Lab599 Utility in System Settings → Privacy & Security → Microphone."];
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
            AudioQueueDispose(queue,true);
            [self reportAudioError:@"The selected audio input is unavailable. Choose a connected input or System Audio (Direct) next to Start Decoder in CW Station."];
            return;
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
    if (self.onListeningStateChanged) self.onListeningStateChanged(YES);
}

- (void)stopListening {
    ++_listeningRequest; // Cancel a microphone permission callback still in flight.
    [self stopSystemAudio];

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
    if (self.onMetricsUpdated) self.onMetricsUpdated(self.estimatedWPM, 0, 0, NO);
    if (self.onListeningStateChanged) self.onListeningStateChanged(NO);
}

- (void)clearBuffer {
    @synchronized (self) {
        self.rawDecodedText = @"";
        @synchronized (self.internalDecodedTokens) {
            [self.internalDecodedTokens removeAllObjects];
        }
        [self resetTimingState];
    }
    if (self.onDecodedTextUpdated) self.onDecodedTextUpdated(@"", @"");
}

- (void)resetTimingState {
    self.outputGeneration++;
    self.isMarkActive = NO;
    self.isSignalDetected = NO;
    self.activeCharacterBuffer = @"";
    self.currentMarkDuration = self.currentSpaceDuration = 0;
    self.currentDitEstimate = 1.2 / fmax(3.0, self.estimatedWPM);
    self.hasCommittedWordBreak = YES;
    self.smoothedNoiseFloor = self.smoothedTargetMag = self.peakSignalLevel = 0;
    self.pendingDropoutDuration = 0;
    _analysisCount = _analysisLength = 0;
    _quietSeconds = _precedingSpaceDuration = _markBias = 0;
    _frequencyLocked = _timingLocked = _replayingTiming = _carrierTrusted = NO;
    _confirmedToneWindows = 0;
    [_timingRuns removeAllObjects];
    [_characterMarks removeAllObjects];
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
    if (!buffer.frameLength || !buffer.floatChannelData) return;
    @synchronized (self) {
        double rate = buffer.format.sampleRate;
        if (!isfinite(rate) || rate < 8000 || rate > 192000) return;
        if (rate != self.sampleRate) {
            self.sampleRate = rate;
            [self resetTimingState];
        }
        // Choose the strongest channel. Averaging anti-phase stereo can cancel CW.
        NSUInteger channels = buffer.format.channelCount;
        NSUInteger stride = buffer.format.isInterleaved ? channels : 1;
        NSUInteger best = 0;
        double bestEnergy = -1;
        for (NSUInteger c = 0; c < channels; c++) {
            const float *p = buffer.floatChannelData[buffer.format.isInterleaved ? 0 : c];
            double energy = 0;
            for (NSUInteger i = 0; i < buffer.frameLength; i++) {
                double v = p[i * stride + (buffer.format.isInterleaved ? c : 0)];
                energy += v * v;
            }
            if (energy > bestEnergy) { bestEnergy = energy; best = c; }
        }
        if (stride == 1) {
            [self processRawAudioSamples:buffer.floatChannelData[best] count:(int)buffer.frameLength];
        } else {
            float mono[1024];
            for (NSUInteger i = 0; i < buffer.frameLength;) {
                int n = (int)MIN(1024, buffer.frameLength - i);
                for (int j = 0; j < n; j++) mono[j] = buffer.floatChannelData[0][(i+j)*stride+best];
                [self processRawAudioSamples:mono count:n];
                i += n;
            }
        }
    }
}

- (void)processRawAudioSamples:(const float *)samples count:(int)count {
    if (!samples || count <= 0) return;
    @synchronized (self) {
        if (self.diagnosticPCM) [self.diagnosticPCM appendBytes:samples length:count*sizeof(float)];
        if (!_analysisLength) {
            _analysisLength = 8 * (int)lround(self.sampleRate * (256.0/48000.0));
            _windowSum = 0;
            for (int i = 0; i < _analysisLength; i++) {
                _window[i] = 0.5-0.5*cos(2*M_PI*i/(_analysisLength-1));
                _windowSum += _window[i];
            }
        }
        for (int i = 0; i < count; i++) {
            _analysis[_analysisCount++] = isfinite(samples[i]) ? samples[i] : 0;
            if (_analysisCount == _analysisLength) {
                [self processAnalysisSamples:_analysis count:_analysisLength];
                _analysisCount = 0;
            }
        }
    }
}

- (void)processAnalysisSamples:(const float *)channelData count:(int)totalFrames {
    if (totalFrames <= 0 || !channelData) return;

    // 1. Peak Level
    float peak = 0.0f;
    for (int i = 0; i < totalFrames; i += 8) {
        float val = fabsf(channelData[i]);
        if (val > peak) peak = val;
    }
    self.audioInputLevel = peak;

    double energy = 0;
    for (int i = 0; i < totalFrames; i++) {
        _weighted[i] = channelData[i]*_window[i];
        energy += channelData[i]*channelData[i]*_window[i];
    }
    energy /= _windowSum;
    float normalization = totalFrames/_windowSum;
    // 2. Multi-Bin Spectrum (48 bins: 300 - 1500 Hz)
#define CW_SPECTRUM_NUM_BINS 48
    NSMutableArray<TX500CWSpectrumBin *> *bins = [NSMutableArray arrayWithCapacity:CW_SPECTRUM_NUM_BINS];
    double startFreq = 300.0;
    double endFreq = 1500.0;
    double stepFreq = (endFreq - startFreq) / (double)(CW_SPECTRUM_NUM_BINS - 1);
    float peakBinMag = 0.0f;
    int peakBinIdx = 0;
    float sortedMags[CW_SPECTRUM_NUM_BINS];

    for (int b = 0; b < CW_SPECTRUM_NUM_BINS; b++) {
        double f = startFreq + (double)b * stepFreq;
        float mag = GoertzelMagnitude(_weighted, totalFrames, f, self.sampleRate)*normalization;
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

    // Median across the analysis band rejects a small number of occupied bins.
    for (int i = 0; i < CW_SPECTRUM_NUM_BINS - 1; i++) {
        for (int j = i + 1; j < CW_SPECTRUM_NUM_BINS; j++) {
            if (sortedMags[j] < sortedMags[i]) {
                float tmp = sortedMags[i];
                sortedMags[i] = sortedMags[j];
                sortedMags[j] = tmp;
            }
        }
    }
    float spectralNoise = fmaxf(1e-8f, sortedMags[CW_SPECTRUM_NUM_BINS / 2]);
    // Correct the different equivalent noise bandwidths of the Hann spectrum
    // and the short rectangular envelope detector.
    float bandNoiseFloor = spectralNoise*sqrtf(8.0f/1.5f);
    float broadband[9];
    for (int i = 0; i < 9; i++) {
        broadband[i] = GoertzelMagnitude(_weighted, totalFrames, self.sampleRate*(0.30+i*0.02), self.sampleRate)*normalization;
    }
    for (int i = 1; i < 9; i++) {
        float value = broadband[i]; int j = i;
        while (j > 0 && broadband[j-1] > value) { broadband[j] = broadband[j-1]; j--; }
        broadband[j] = value;
    }
    double whiteNoisePower = broadband[4]*broadband[4]*totalFrames/(1.5*log(2.0));
    double structuredEnergy = fmax(energy*0.10, energy-0.85*whiteNoisePower);
    BOOL toneConfirmed = peakBinMag > spectralNoise*6 &&
                         2*peakBinMag*peakBinMag > 0.45*structuredEnergy;

    @synchronized (self.internalSpectrumBins) {
        [self.internalSpectrumBins setArray:bins];
    }

    // 3. Wide-Band AFC with Sub-Bin Quadratic Interpolation
    //    Enables tracking any CW signal across 300 - 1500 Hz
    double fPeak = startFreq + (double)peakBinIdx * stepFreq;
    double fExact = fPeak;
    if (peakBinIdx > 0 && peakBinIdx < CW_SPECTRUM_NUM_BINS - 1) {
        float y1 = bins[peakBinIdx - 1].magnitude;
        float y2 = bins[peakBinIdx].magnitude;
        float y3 = bins[peakBinIdx + 1].magnitude;
        float denom = 2.0f * (2.0f * y2 - y1 - y3);
        if (fabsf(denom) > 1e-12) {
            float delta = (y3 - y1) / denom;
            fExact = fPeak + (double)delta * stepFreq;
        }
    }

    // Evaluate lock validity in the SAME narrow spectral window used for
    // acquisition. The short envelope detector leaks distant tones and must
    // never decide whether AFC is allowed to release a stale frequency.
    float lockedBandMag = GoertzelMagnitude(_weighted, totalFrames, self.centerFrequencyHz, self.sampleRate)*normalization;
    if (!_carrierTrusted && _quietSeconds > 0.5) {
        _confirmedToneWindows = 0;
        [_timingRuns removeAllObjects];
    }
    if (self.afcEnabled && toneConfirmed) {
        double deltaF = fabs(fExact-self.centerFrequencyHz);
        // A different tone in an element/letter gap must not steal an
        // established station. Untrained stale carriers can still reacquire.
        BOOL stationIdle = !_timingLocked || _quietSeconds >= fmax(0.30, self.currentDitEstimate*3.5);
        BOOL dominantNewTone = stationIdle && deltaF >= 65 && peakBinMag > fmaxf(lockedBandMag*4, spectralNoise*8);
        if (!_frequencyLocked || dominantNewTone) {
            if (_frequencyLocked && deltaF >= 65) {
                // Timing belongs to a station, not to the lifetime of the app.
                // Do not join a new station's marks to an old partial character.
                self.activeCharacterBuffer = @"";
                [_characterMarks removeAllObjects];
                [self commitWordBreak];
                [_timingRuns removeAllObjects];
                _timingLocked = NO;
                _markBias = _precedingSpaceDuration = 0;
                self.isMarkActive = self.isSignalDetected = NO;
                self.currentMarkDuration = self.currentSpaceDuration = self.pendingDropoutDuration = 0;
                self.smoothedTargetMag = 0;
                self.smoothedNoiseFloor = bandNoiseFloor;
            }
            _carrierTrusted = NO;
            _confirmedToneWindows = 0;
            self.centerFrequencyHz = fExact;
            _frequencyLocked = YES;
            _quietSeconds = 0;
            self.peakSignalLevel = peakBinMag;
        } else if (deltaF < 65) {
            self.centerFrequencyHz += 0.25*(fExact-self.centerFrequencyHz);
        }
    } else if (!self.afcEnabled) {
        self.centerFrequencyHz = self.nominalPitchHz;
    }
    toneConfirmed = toneConfirmed && fabs(fExact-self.centerFrequencyHz) < 65;
    if (toneConfirmed) {
        _frequencyLocked = YES;
        _confirmedToneWindows++;
        // Keep provisional marks so acquisition never clips the first element.
        // A lone, marginal spectral transient is not enough to publish text.
        if (_confirmedToneWindows >= 2 || 2*peakBinMag*peakBinMag > 0.65*structuredEnergy)
            _carrierTrusted = YES;
    }

    // 4. Sub-chunk processing (256 samples ≈ 5.33 ms at 48kHz for high-WPM precision)
    int chunkSize = totalFrames/8;
    int chunkCount = totalFrames / chunkSize;
    double chunkDurationSec = (double)chunkSize / self.sampleRate;

    // Smooth the noise floor
    if (self.smoothedNoiseFloor < 1e-8f) {
        self.smoothedNoiseFloor = bandNoiseFloor;
    } else {
        self.smoothedNoiseFloor = self.smoothedNoiseFloor * 0.90f + bandNoiseFloor * 0.10f;
    }
    float localNoiseFloor = fmaxf(1e-8f, self.smoothedNoiseFloor);

    // Adaptive hang time based on current Morse speed (prevents eating element spaces at high WPM)
    double hangTimeSec = _timingLocked ? fmax(0.005, fmin(0.016, self.currentDitEstimate * 0.15)) : 0.005;

    for (int c = 0; c < chunkCount; c++) {
        const float *chunkPtr = channelData + (c * chunkSize);

        float targetMag = GoertzelMagnitude(chunkPtr, chunkSize, self.centerFrequencyHz, self.sampleRate);

        if (self.smoothedTargetMag < 1e-10f) {
            self.smoothedTargetMag = targetMag;
        } else {
            self.smoothedTargetMag = self.smoothedTargetMag * 0.25f + targetMag * 0.75f;
        }

        double snrRatio = (double)self.smoothedTargetMag / (double)localNoiseFloor;
        self.signalToNoiseRatioDb = 20.0 * log10(fmax(1.0, snrRatio));

        // Track peak signal level with fast attack and slow decay (with safety floor above noise floor)
        if (self.smoothedTargetMag > self.peakSignalLevel) {
            self.peakSignalLevel = self.smoothedTargetMag;
        } else {
            self.peakSignalLevel = fmaxf(localNoiseFloor * 2.2f, self.peakSignalLevel * exp(-chunkDurationSec/2.0));
        }

        // Noise-immune adaptive Schmitt-trigger thresholds:
        float signalSpan = fmaxf(1e-8f, self.peakSignalLevel - localNoiseFloor);
        float onThreshold  = fmaxf(localNoiseFloor * 1.80f, localNoiseFloor + 0.40f * signalSpan);
        float offThreshold = fmaxf(localNoiseFloor * 1.25f, localNoiseFloor + 0.22f * signalSpan);

        // Carrier presence gate: only accept marks if a true CW tone is confirmed above the noise floor
        BOOL signalConfirmed = (toneConfirmed || (_carrierTrusted && _quietSeconds < fmax(1.5, self.currentDitEstimate*8.0))) && self.peakSignalLevel >= localNoiseFloor*4.0f;

        if (toneConfirmed) _quietSeconds = 0; else _quietSeconds += chunkDurationSec;
        if (!self.isMarkActive) {
            if (signalConfirmed && self.smoothedTargetMag >= onThreshold && snrRatio >= 1.65) {
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
            if (self.smoothedTargetMag < offThreshold || snrRatio < 1.20) {
                // Signal dipped below threshold: could be mark end OR an acoustic notch / dropout
                self.pendingDropoutDuration += chunkDurationSec;

                // Adaptive hang time: scales down at higher WPM to protect fast inter-element spaces
                if (self.pendingDropoutDuration >= hangTimeSec) {
                    double mark = self.currentMarkDuration;
                    BOOL glitch = mark < 0.012;
                    [self handleMarkEnd:mark];
                    self.currentMarkDuration = 0.0;
                    self.currentSpaceDuration = self.pendingDropoutDuration + (glitch ? _precedingSpaceDuration+mark : 0);
                    self.pendingDropoutDuration = 0.0;
                    self.isMarkActive = NO;
                    self.isSignalDetected = NO;
                }
            } else {
                // Signal is active: bridge any momentary acoustic dropout (< 20ms) seamlessly
                if (self.pendingDropoutDuration > 0.0) {
                    self.currentMarkDuration += self.pendingDropoutDuration;
                    self.pendingDropoutDuration = 0.0;
                }
                self.currentMarkDuration += chunkDurationSec;
            }
        }
    }

    // Callbacks on main queue
    if (self.onMetricsUpdated) {
        double wpm = self.estimatedWPM;
        double snr = self.signalToNoiseRatioDb;
        float level = self.audioInputLevel;
        BOOL sig = self.isSignalDetected;
        NSUInteger generation = self.outputGeneration;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.outputGeneration) return;
            if (self.onMetricsUpdated) self.onMetricsUpdated(wpm, snr, level, sig);
        });
    }

    if (self.onSpectrumUpdated) {
        NSArray *snap = [self.spectrumBins copy];
        NSUInteger generation = self.outputGeneration;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.outputGeneration) return;
            if (self.onSpectrumUpdated) self.onSpectrumUpdated(snap);
        });
    }
}

#pragma mark - Morse Timing Classification

// Fit raw mark AND gap lengths before assigning dots/dashes. A one-sided
// mark-only estimator can otherwise lock permanently to one third of the speed.
- (void)fitTiming {
    if (_timingRuns.count < 3) return;
    double durations[32]; BOOL marks[32]; NSUInteger count = _timingRuns.count;
    for (NSUInteger i = 0; i < count; i++) {
        durations[i] = [_timingRuns[i][@"duration"] doubleValue];
        marks[i] = [_timingRuns[i][@"mark"] boolValue];
    }
    double bestCost = DBL_MAX, bestDit = self.currentDitEstimate, bestBias = 0;
    for (double dit = 0.020; dit <= 0.401; dit += 0.001) {
        for (double bias = -0.010; bias <= fmin(0.050, dit*0.45); bias += 0.005) {
            double cost = 0, weight = 0;
            for (NSUInteger i = 0; i < count; i++) {
                BOOL mark = marks[i];
                double duration = durations[i];
                double residual = DBL_MAX;
                int units[] = {1, 3, 7};
                for (int k = 0; k < (mark ? 2 : 3); k++) {
                    double prediction = units[k]*dit + (mark ? bias : -bias);
                    double r = (duration-prediction)/(0.008 + dit*0.18);
                    residual = fmin(residual, r*r);
                }
                cost += fmin(16, residual);
                weight++;
            }
            cost /= weight;
            cost += 0.015*pow(bias/dit, 2);
            // Nominal speed is only a tie breaker for genuinely ambiguous signals.
            cost += 0.001*fabs(log(dit/self.currentDitEstimate));
            if (cost < bestCost) { bestCost = cost; bestDit = dit; bestBias = bias; }
        }
    }
    self.currentDitEstimate = bestDit;
    self.estimatedWPM = 1.2/bestDit;
    _markBias = bestBias;
}

- (void)recordTiming:(double)duration mark:(BOOL)mark {
    [_timingRuns addObject:@{@"duration": @(duration), @"mark": @(mark)}];
    if (_timingRuns.count > 32) [_timingRuns removeObjectAtIndex:0];
}

- (void)lockTimingAndReplay {
    if (!_carrierTrusted) return;
    [self fitTiming];
    _timingLocked = YES;
    _replayingTiming = YES;
    for (NSDictionary *run in [_timingRuns copy]) {
        double duration = [run[@"duration"] doubleValue];
        if ([run[@"mark"] boolValue]) [self handleMarkEnd:duration];
        else [self handleSpaceProgression:duration];
    }
    _replayingTiming = NO;
}

- (void)handleMarkOnset:(double)spaceDuration {
    _precedingSpaceDuration = spaceDuration;
    if (_timingLocked) [self handleSpaceProgression:spaceDuration];
}

- (void)handleMarkEnd:(double)markDuration {
    if (markDuration < 0.012 || markDuration > 1.5) return;
    if (!_replayingTiming) {
        // Only record a gap when its following mark survives the glitch filter.
        // Leading/idle silence is not evidence of sending speed.
        if (_timingRuns.count && _precedingSpaceDuration > 0.008 &&
            _precedingSpaceDuration < fmax(3.0, 10*self.currentDitEstimate))
            [self recordTiming:_precedingSpaceDuration mark:NO];
        [self recordTiming:markDuration mark:YES];
        if (!_timingLocked) {
            if (_timingRuns.count >= 7) [self lockTimingAndReplay];
            return;
        }
        [self fitTiming];
    }
    [_characterMarks addObject:@(markDuration)];
    NSMutableString *pattern = [NSMutableString string];
    for (NSNumber *duration in _characterMarks) {
        [pattern appendString:duration.doubleValue < 2*self.currentDitEstimate+_markBias ? @"." : @"-"];
    }
    self.activeCharacterBuffer = pattern;
    self.hasCommittedWordBreak = NO;
    if (markDuration >= 2*self.currentDitEstimate+_markBias)
        self.ditDahRatio = (markDuration-_markBias)/self.currentDitEstimate;
    if (self.onDecodedTextUpdated) {
        NSString *raw = self.rawDecodedText, *buf = self.activeCharacterBuffer;
        NSUInteger generation = self.outputGeneration;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.outputGeneration) return;
            if (self.onDecodedTextUpdated) self.onDecodedTextUpdated(raw, buf);
        });
    }
}

- (void)handleSpaceProgression:(double)spaceDuration {
    if (!_carrierTrusted) return;
    if (!_timingLocked) {
        double longest = 0;
        for (NSDictionary *run in _timingRuns)
            if ([run[@"mark"] boolValue]) longest = fmax(longest, [run[@"duration"] doubleValue]);
        if (longest > 0 && spaceDuration > fmax(0.8, longest*4)) [self lockTimingAndReplay];
        else return;
    }
    if (spaceDuration >= 2*self.currentDitEstimate-_markBias && self.activeCharacterBuffer.length)
        [self commitActiveCharacter];
    if (spaceDuration >= 5*self.currentDitEstimate-_markBias && !self.hasCommittedWordBreak)
        [self commitWordBreak];
}

- (void)commitActiveCharacter {
    if (self.activeCharacterBuffer.length == 0) return;
    [_characterMarks removeAllObjects];

    NSDictionary *dict = [TX500CWAudioDecoder reverseMorseAlphabet];
    NSString *symbol = dict[self.activeCharacterBuffer];
    if (!symbol) {
        // Keep uncertainty visible instead of silently dropping an undecodable character.
        symbol = @"�";
    }

    self.rawDecodedText = [self.rawDecodedText stringByAppendingString:symbol];
    self.activeCharacterBuffer = @"";

    if (self.onDecodedTextUpdated) {
        NSString *raw = self.rawDecodedText;
        NSUInteger generation = self.outputGeneration;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.outputGeneration) return;
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
            NSUInteger generation = self.outputGeneration;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self.outputGeneration) return;
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
        NSUInteger generation = self.outputGeneration;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != self.outputGeneration) return;
            if (self.onTokenReceived) self.onTokenReceived(token);
        });
    }
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
    double ditSec = 1.2 / fmax(3.0, wpm);
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
                if (p+1 < (NSInteger)pattern.length) [self feedSyntheticAudioWithFrequency:pitchHz duration:elemSpaceSec isMark:NO];
            }
            if (c+1 < (NSInteger)word.length) [self feedSyntheticAudioWithFrequency:pitchHz duration:charSpaceSec isMark:NO];
        }
        [self feedSyntheticAudioWithFrequency:pitchHz duration:wordSpaceSec isMark:NO];
    }
}

- (void)feedSyntheticAudioWithFrequency:(double)freq duration:(double)duration isMark:(BOOL)isMark {
    int frameCount = (int)(duration * self.sampleRate);
    if (frameCount <= 0) return;

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

- (NSDictionary *)systemCaptureDiagnostics {
    @synchronized (self) {
        return @{@"buffers": @(_systemReceivedBuffers), @"frames": @(_systemReceivedFrames),
                 @"sampleRate": @(self.sampleRate), @"centerHz": @(self.centerFrequencyHz),
                 @"wpm": @(self.estimatedWPM), @"text": self.rawDecodedText ?: @""};
    }
}

@end

// Explicit command-line diagnostic; normal application startup never runs this.
// Playback is a separate process, so the test crosses the real system-audio path.
int TX500CWRunLiveAudioCheck(NSString *directory, NSString *reportPath) {
    @autoreleasepool {
        TX500CWAudioDecoder *decoder = [TX500CWAudioDecoder new];
        decoder.selectedAudioDeviceUID = TX500CWSystemAudioDeviceUID;
        decoder.diagnosticPCM = [NSMutableData data];
        __block NSString *captureError = nil;
        decoder.onAudioError = ^(NSString *message) { captureError = message; };
        [decoder startListening];
        NSArray *names = @[@"3", @"4", @"5", @"6", @"7", @"9"];
        NSArray *expected = @[@"OXIDE", @"FIELD", @"COLOR", @"RELAY", @"JAMMER", @"COLD"];
        NSString *selection = NSProcessInfo.processInfo.environment[@"TX500_CW_LIVE_FILES"];
        if (selection.length) {
            NSDictionary *reference = [NSDictionary dictionaryWithObjects:expected forKeys:names];
            NSArray *requested = [selection componentsSeparatedByString:@","];
            NSMutableArray *subset = [NSMutableArray array], *texts = [NSMutableArray array];
            for (NSString *name in requested) if (reference[name]) { [subset addObject:name]; [texts addObject:reference[name]]; }
            names = subset; expected = texts;
        }
        NSMutableArray *results = [NSMutableArray array];
        NSMutableDictionary *report = [NSMutableDictionary dictionary];
        report[@"version"] = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"test";
        int failures = 0;
        for (NSUInteger i = 0; i < names.count && decoder.isListening; i++) {
            NSString *path = [directory stringByAppendingPathComponent:[names[i] stringByAppendingPathExtension:@"wav"]];
            if (![NSFileManager.defaultManager fileExistsAtPath:path])
                path = [directory stringByAppendingPathComponent:[names[i] stringByAppendingPathExtension:@"m4a"]];
            NSUInteger startLength = [[decoder systemCaptureDiagnostics][@"text"] length];
            NSTask *player = [NSTask new];
            player.executableURL = [NSURL fileURLWithPath:@"/usr/bin/afplay"];
            player.arguments = @[path];
            NSError *error = nil;
            if (![player launchAndReturnError:&error]) { captureError = error.localizedDescription; break; }
            printf("Playing %s through System Audio...\n", [names[i] UTF8String]); fflush(stdout);
            NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:65];
            while (player.isRunning && deadline.timeIntervalSinceNow > 0 && decoder.isListening)
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            if (player.isRunning) { [player terminate]; captureError = @"Playback timed out or capture stopped."; break; }
            if (player.terminationStatus != 0) { captureError = @"afplay failed."; break; }
            NSDate *tail = [NSDate dateWithTimeIntervalSinceNow:1.0];
            while (tail.timeIntervalSinceNow > 0)
                [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
            NSDictionary *state = [decoder systemCaptureDiagnostics];
            NSString *text = state[@"text"];
            NSString *actual = [[text substringFromIndex:MIN(startLength,text.length)]
                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            BOOL passed = [actual isEqualToString:expected[i]];
            if (!passed) failures++;
            [results addObject:@{@"file": names[i], @"expected": expected[i], @"actual": actual,
                                 @"passed": @(passed), @"capture": state}];
            printf("%s expected [%s] captured [%s] %.1f Hz %.1f WPM\n", passed ? "PASS" : "FAIL",
                   [expected[i] UTF8String], actual.UTF8String, decoder.centerFrequencyHz, decoder.estimatedWPM); fflush(stdout);
            report[@"results"] = results;
            [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
                writeToFile:reportPath atomically:YES];
        }
        report[@"capture"] = [decoder systemCaptureDiagnostics];
        [decoder stopListening];
        report[@"results"] = results;
        if (captureError) report[@"error"] = captureError;
        NSString *pcmPath = [reportPath.stringByDeletingPathExtension stringByAppendingPathExtension:@"f32"];
        [decoder.diagnosticPCM writeToFile:pcmPath atomically:YES];
        report[@"pcmFile"] = pcmPath;
        report[@"pcmFormat"] = @"Float32 mono, native sample rate from capture.sampleRate";
        BOOL passed = !captureError && names.count > 0 && results.count == names.count && failures == 0;
        report[@"passed"] = @(passed);
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
            writeToFile:reportPath atomically:YES];
        if (captureError) fprintf(stderr,"%s\n",captureError.UTF8String);
        return passed ? 0 : 1;
    }
}
