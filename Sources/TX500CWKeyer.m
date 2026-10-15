//
//  TX500CWKeyer.m
//  Lab599 Utility
//
//  Native Kenwood CAT Morse Keyer & Macro Automation Engine
//

#import "TX500CWKeyer.h"
#import <math.h>
#import <pthread.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

@implementation TX500CWMacro
+ (instancetype)macroWithId:(NSInteger)mId label:(NSString *)label template:(NSString *)tmpl {
    TX500CWMacro *m = [TX500CWMacro new];
    m.macroId = mId;
    m.label = label;
    m.templateString = tmpl;
    return m;
}
@end

@interface TX500CWKeyer ()
@property (nonatomic) NSUInteger transmissionGeneration;
@property (nonatomic, assign, readwrite) BOOL isTransmitting;
@property (nonatomic, copy, readwrite) NSString *activeBufferText;
@property (nonatomic, copy, readwrite) NSString *currentlyTransmittingChar;
@property (nonatomic, strong, readwrite) NSMutableArray<NSString *> *internalSentHistory;
@property (nonatomic, assign, readwrite) BOOL isAutoCQActive;
@property (nonatomic, assign, readwrite) NSInteger autoCQCountdown;

@property (nonatomic, strong, nullable) NSTimer *autoCQTimer;
@property (nonatomic, copy, nullable) NSString *currentAutoCQTemplate;
@property (nonatomic, copy, nullable) NSString *currentAutoCQCall;

// Audio Sidetone (local Mac speakers/headphones)
@property (nonatomic, strong, nullable) AVAudioEngine *sidetoneEngine;
@property (nonatomic, strong, nullable) AVAudioPlayerNode *sidetonePlayer;
@property (nonatomic, assign) BOOL sidetoneEngineReady;

// Radio Audio Output (routes CW modulation to TX-500 transceiver via AudioQueue)
@property (nonatomic, assign) BOOL radioQueueReady;
@property (nonatomic, copy, nullable) NSString *activeRadioUID;

@end

@implementation TX500CWKeyer {
    AudioQueueRef _radioOutputQueue;
    AudioQueueBufferRef _radioBuffers[3];
    pthread_mutex_t _radioAudioLock;
    float *_radioTxBuffer;
    UInt32 _radioTxBufferTotalSamples;
    UInt32 _radioTxBufferReadIndex;
    BOOL _isContinuousCarrier;
    double _carrierPhase;
    double _carrierFrequency;
    float _carrierAmplitude;
}

+ (nullable NSString *)findBestUSBAudioOutputUID {
    return CWKeyerFindBestUSBAudioOutputUID();
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _wpm = 25;
        _sidetonePitchHz = 650.0;
        _sidetoneEnabled = YES;
        _sidetoneVolume = 0.6f;
        _useCutNumbers = YES;
        _myCallsign = @"";
        _autoCQIntervalSeconds = 4;
        _internalSentHistory = [NSMutableArray array];
        _txPrefixCommand = @"TX;";
        _rxSuffixCommand = @"RX;";

        pthread_mutex_init(&_radioAudioLock, NULL);
        _radioTxBuffer = NULL;
        _radioTxBufferTotalSamples = 0;
        _radioTxBufferReadIndex = 0;
        _isContinuousCarrier = NO;
        _carrierPhase = 0.0;
        _carrierFrequency = 650.0;
        _carrierAmplitude = 0.85f;

        _macroList = [NSMutableArray arrayWithArray:@[
            [TX500CWMacro macroWithId:1 label:@"F1 CQ" template:@"CQ CQ DE {MYCALL} {MYCALL} K"],
            [TX500CWMacro macroWithId:2 label:@"F2 Answer" template:@"{CALL} DE {MYCALL} {MYCALL} K"],
            [TX500CWMacro macroWithId:3 label:@"F3 Report" template:@"UR {RST} {RST} BK"],
            [TX500CWMacro macroWithId:4 label:@"F4 73 Final" template:@"TU 73 DE {MYCALL} SK"],
            [TX500CWMacro macroWithId:5 label:@"F5 My Call" template:@"{MYCALL}"],
            [TX500CWMacro macroWithId:6 label:@"F6 His Call" template:@"{CALL}"],
            [TX500CWMacro macroWithId:7 label:@"F7 QRZ?" template:@"QRZ? DE {MYCALL} K"],
            [TX500CWMacro macroWithId:8 label:@"F8 Info" template:@"NAME {NAME} QTH {QTH} BK"]
        ]];

        if (!NSProcessInfo.processInfo.environment[@"TX500_TEST_MODE"].boolValue) {
            [self setupSidetoneAudio];
        }
    }
    return self;
}

- (void)dealloc {
    [self abortTransmission];
    [self stopAutoCQ];
    if (self.sidetoneEngine) {
        [self.sidetoneEngine stop];
        self.sidetoneEngine = nil;
    }
    [self teardownRadioAudio];
    pthread_mutex_lock(&_radioAudioLock);
    if (_radioTxBuffer) {
        free(_radioTxBuffer);
        _radioTxBuffer = NULL;
    }
    pthread_mutex_unlock(&_radioAudioLock);
    pthread_mutex_destroy(&_radioAudioLock);
}

- (NSArray<NSString *> *)sentHistory {
    return [self.internalSentHistory copy];
}

#pragma mark - CoreAudio Helpers

static NSString *CWKeyerFindBestUSBAudioOutputUID(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size) != noErr || size == 0) return nil;
    int count = size / sizeof(AudioDeviceID);
    AudioDeviceID *devs = (AudioDeviceID *)malloc(size);
    if (!devs) return nil;
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devs) != noErr) {
        free(devs);
        return nil;
    }
    NSString *bestUID = nil;
    for (int i = 0; i < count; i++) {
        AudioDeviceID devID = devs[i];
        AudioObjectPropertyAddress streamAddr = {
            kAudioDevicePropertyStreams,
            kAudioDevicePropertyScopeOutput,
            kAudioObjectPropertyElementMain
        };
        UInt32 streamSize = 0;
        if (AudioObjectGetPropertyDataSize(devID, &streamAddr, 0, NULL, &streamSize) != noErr || streamSize == 0) continue;

        AudioObjectPropertyAddress transAddr = {
            kAudioDevicePropertyTransportType,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 transport = 0;
        UInt32 transSize = sizeof(UInt32);
        AudioObjectGetPropertyData(devID, &transAddr, 0, NULL, &transSize, &transport);
        if (transport != kAudioDeviceTransportTypeUSB) continue;

        CFStringRef uidRef = NULL;
        UInt32 uidSize = sizeof(CFStringRef);
        AudioObjectPropertyAddress uidAddr = {
            kAudioDevicePropertyDeviceUID,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        if (AudioObjectGetPropertyData(devID, &uidAddr, 0, NULL, &uidSize, &uidRef) == noErr && uidRef) {
            bestUID = (__bridge_transfer NSString *)uidRef;
            break;
        }
    }
    free(devs);
    return bestUID;
}

#pragma mark - Sidetone & Radio Audio Setup

- (void)setupSidetoneAudio {
    @try {
        self.sidetoneEngine = [[AVAudioEngine alloc] init];
        self.sidetonePlayer = [[AVAudioPlayerNode alloc] init];
        [self.sidetoneEngine attachNode:self.sidetonePlayer];

        AVAudioMixerNode *mainMixer = self.sidetoneEngine.mainMixerNode;
        AVAudioFormat *format = [mainMixer outputFormatForBus:0];
        [self.sidetoneEngine connect:self.sidetonePlayer to:mainMixer format:format];

        NSError *err = nil;
        [self.sidetoneEngine startAndReturnError:&err];
        if (!err) {
            self.sidetoneEngineReady = YES;
        } else {
            NSLog(@"TX500CWKeyer: Could not start sidetone audio: %@", err);
        }
    } @catch (NSException *exception) {
        self.sidetoneEngineReady = NO;
        self.sidetonePlayer = nil;
        self.sidetoneEngine = nil;
        NSLog(@"TX500CWKeyer: Sidetone audio unavailable: %@", exception.reason);
    }
}

static void CWKeyerRadioOutputCallback(void *inUserData,
                                       AudioQueueRef inAQ,
                                       AudioQueueBufferRef inBuffer) {
    TX500CWKeyer *keyer = (__bridge TX500CWKeyer *)inUserData;
    if (!keyer) return;
    UInt32 frameCount = inBuffer->mAudioDataBytesCapacity / (2 * sizeof(float));
    float *samples = (float *)inBuffer->mAudioData;
    [keyer renderRadioAudioSamples:samples count:frameCount];
    inBuffer->mAudioDataByteSize = frameCount * 2 * sizeof(float);
    if (inAQ) {
        AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
    }
}

- (void)renderRadioAudioSamples:(float *)samples count:(UInt32)frameCount {
    pthread_mutex_lock(&_radioAudioLock);
    if (_isContinuousCarrier) {
        double omega = 2.0 * M_PI * _carrierFrequency / 48000.0;
        for (UInt32 i = 0; i < frameCount; i++) {
            float val = _carrierAmplitude * sinf((float)_carrierPhase);
            samples[i * 2] = val;
            samples[i * 2 + 1] = val;
            _carrierPhase += omega;
            if (_carrierPhase > 2.0 * M_PI) _carrierPhase -= 2.0 * M_PI;
        }
    } else if (self.isTransmitting && _radioTxBuffer && _radioTxBufferReadIndex < _radioTxBufferTotalSamples) {
        UInt32 remaining = _radioTxBufferTotalSamples - _radioTxBufferReadIndex;
        UInt32 toCopy = MIN(frameCount, remaining);
        for (UInt32 i = 0; i < toCopy; i++) {
            float val = _radioTxBuffer[_radioTxBufferReadIndex + i];
            samples[i * 2] = val;
            samples[i * 2 + 1] = val;
        }
        _radioTxBufferReadIndex += toCopy;
        for (UInt32 i = toCopy; i < frameCount; i++) {
            samples[i * 2] = 0.0f;
            samples[i * 2 + 1] = 0.0f;
        }
    } else {
        memset(samples, 0, frameCount * 2 * sizeof(float));
    }
    pthread_mutex_unlock(&_radioAudioLock);
}

- (void)teardownRadioAudio {
    if (_radioOutputQueue) {
        AudioQueueStop(_radioOutputQueue, true);
        AudioQueueDispose(_radioOutputQueue, true);
        _radioOutputQueue = NULL;
    }
    self.radioQueueReady = NO;
    self.activeRadioUID = nil;
}

- (void)ensureRadioAudioReady {
    if (NSProcessInfo.processInfo.environment[@"TX500_TEST_MODE"].boolValue) return;

    NSString *targetUID = self.radioOutputDeviceUID;
    if (!targetUID.length) {
        targetUID = CWKeyerFindBestUSBAudioOutputUID();
    }
    if (!targetUID.length) {
        return;
    }
    if (self.radioQueueReady && [self.activeRadioUID isEqualToString:targetUID]) {
        return;
    }
    [self teardownRadioAudio];

    AudioStreamBasicDescription format = {0};
    format.mSampleRate = 48000.0;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBytesPerPacket = 2 * sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = 2 * sizeof(float);
    format.mChannelsPerFrame = 2;
    format.mBitsPerChannel = 32;

    OSStatus status = AudioQueueNewOutput(&format,
                                          CWKeyerRadioOutputCallback,
                                          (__bridge void *)self,
                                          NULL,
                                          NULL,
                                          0,
                                          &_radioOutputQueue);
    if (status != noErr) {
        NSLog(@"TX500CWKeyer: AudioQueueNewOutput failed with status %d", (int)status);
        return;
    }

    CFStringRef uidRef = (__bridge CFStringRef)targetUID;
    status = AudioQueueSetProperty(_radioOutputQueue,
                                   kAudioQueueProperty_CurrentDevice,
                                   &uidRef,
                                   sizeof(uidRef));
    if (status != noErr) {
        NSLog(@"TX500CWKeyer: AudioQueueSetProperty current device failed (%d) for UID %@", (int)status, targetUID);
        AudioQueueDispose(_radioOutputQueue, true);
        _radioOutputQueue = NULL;
        return;
    }

    for (int i = 0; i < 3; i++) {
        status = AudioQueueAllocateBuffer(_radioOutputQueue,
                                          480 * 2 * sizeof(float),
                                          &_radioBuffers[i]);
        if (status == noErr) {
            memset(_radioBuffers[i]->mAudioData, 0, _radioBuffers[i]->mAudioDataBytesCapacity);
            _radioBuffers[i]->mAudioDataByteSize = _radioBuffers[i]->mAudioDataBytesCapacity;
            AudioQueueEnqueueBuffer(_radioOutputQueue, _radioBuffers[i], 0, NULL);
        }
    }

    status = AudioQueueStart(_radioOutputQueue, NULL);
    if (status == noErr) {
        self.radioQueueReady = YES;
        self.activeRadioUID = targetUID;
        NSLog(@"TX500CWKeyer: Radio AudioQueue ready on %@", targetUID);
    } else {
        NSLog(@"TX500CWKeyer: AudioQueueStart failed (%d)", (int)status);
        [self teardownRadioAudio];
    }
}

static NSDictionary<NSString *, NSString *> *TX500MorseCodeMap(void) {
    static NSDictionary *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"A": @".-",    @"B": @"-...",  @"C": @"-.-.",  @"D": @"-..",
            @"E": @".",     @"F": @"..-.",  @"G": @"--.",   @"H": @"....",
            @"I": @"..",    @"J": @".---",  @"K": @"-.-",   @"L": @".-..",
            @"M": @"--",    @"N": @"-.",    @"O": @"---",   @"P": @".--.",
            @"Q": @"--.-",  @"R": @".-.",   @"S": @"...",   @"T": @"-",
            @"U": @"..-",   @"V": @"...-",  @"W": @".--",   @"X": @"-..-",
            @"Y": @"-.--",  @"Z": @"--..",
            @"1": @".----", @"2": @"..---", @"3": @"...--", @"4": @"....-",
            @"5": @".....", @"6": @"-....", @"7": @"--...", @"8": @"---..",
            @"9": @"----.", @"0": @"-----",
            @"/": @"-..-.", @"?": @"..--..", @"=": @"-...-", @"+": @".-.-.",
            @",": @"--..--", @".": @".-.-.-"
        };
    });
    return map;
}

- (double)estimatedDurationForText:(NSString *)text wpm:(NSInteger)wpm {
    NSInteger clampedWPM = fmax(3, fmin(45, wpm));
    double ditSec = 1.2 / (double)clampedWPM;
    NSDictionary<NSString *, NSString *> *codeMap = TX500MorseCodeMap();
    NSString *upper = text.uppercaseString;
    double totalUnits = 0;
    for (NSUInteger i = 0; i < upper.length; i++) {
        NSString *ch = [upper substringWithRange:NSMakeRange(i, 1)];
        if ([ch isEqualToString:@" "]) {
            totalUnits += 4;
            continue;
        }
        NSString *pattern = codeMap[ch];
        if (!pattern) continue;
        for (NSUInteger s = 0; s < pattern.length; s++) {
            totalUnits += ([pattern characterAtIndex:s] == '-') ? 4 : 2;
        }
        totalUnits += 2;
    }
    return fmax(0.2, totalUnits * ditSec);
}

static AVAudioPCMBuffer *TX500GenerateMorsePCMBuffer(AVAudioFormat *fmt, NSArray<NSDictionary *> *intervals, double pitch, float volume) {
    if (!fmt || fmt.sampleRate <= 0) return nil;
    double sampleRate = fmt.sampleRate;

    int totalSamples = 0;
    for (NSDictionary *d in intervals) {
        totalSamples += [d[@"samples"] intValue];
    }
    if (totalSamples <= 0) return nil;

    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:totalSamples];
    buffer.frameLength = totalSamples;

    double omega = 2.0 * M_PI * pitch / sampleRate;
    double currentPhase = 0;
    int rampSamples = (int)(0.004 * sampleRate); // 4ms raised-cosine envelope to eliminate key clicks
    if (rampSamples < 1) rampSamples = 1;

    float *tempBuf = (float *)calloc(totalSamples, sizeof(float));
    if (!tempBuf) return nil;

    int sampleOffset = 0;
    for (NSDictionary *d in intervals) {
        BOOL isTone = [d[@"tone"] boolValue];
        int count = [d[@"samples"] intValue];
        if (isTone) {
            int thisRamp = MIN(rampSamples, count / 4);
            for (int s = 0; s < count; s++) {
                float env = 1.0f;
                if (s < thisRamp) {
                    env = 0.5f * (1.0f - cosf((float)s / (float)thisRamp * (float)M_PI));
                } else if (s > count - 1 - thisRamp) {
                    env = 0.5f * (1.0f - cosf((float)(count - 1 - s) / (float)thisRamp * (float)M_PI));
                }
                tempBuf[sampleOffset + s] = volume * env * sin(currentPhase);
                currentPhase += omega;
                if (currentPhase > 2.0 * M_PI) currentPhase -= 2.0 * M_PI;
            }
        }
        sampleOffset += count;
    }

    for (int ch = 0; ch < (int)fmt.channelCount; ch++) {
        memcpy(buffer.floatChannelData[ch], tempBuf, totalSamples * sizeof(float));
    }
    free(tempBuf);
    return buffer;
}

- (double)playMorseAudioForText:(NSString *)text wpm:(NSInteger)wpm pitchHz:(double)pitch token:(NSUInteger)token {
    double estDuration = [self estimatedDurationForText:text wpm:wpm];
    if (text.length == 0) return estDuration;

    NSInteger clampedWPM = fmax(3, fmin(45, wpm));
    double ditSec = 1.2 / (double)clampedWPM;
    NSDictionary<NSString *, NSString *> *codeMap = TX500MorseCodeMap();
    NSString *upper = text.uppercaseString;

    NSMutableArray<NSDictionary *> *(^buildIntervalsForRate)(double) = ^NSMutableArray<NSDictionary *> *(double sampleRate) {
        int ditSamples = (int)(ditSec * sampleRate);
        if (ditSamples <= 0) ditSamples = 1;

        NSMutableArray<NSDictionary *> *intervals = [NSMutableArray array];
        for (NSUInteger i = 0; i < upper.length; i++) {
            NSString *ch = [upper substringWithRange:NSMakeRange(i, 1)];
            if ([ch isEqualToString:@" "]) {
                if (intervals.count > 0) {
                    [intervals addObject:@{@"tone": @NO, @"samples": @(4 * ditSamples)}];
                }
                continue;
            }

            NSString *pattern = codeMap[ch];
            if (!pattern) continue;

            for (NSUInteger s = 0; s < pattern.length; s++) {
                unichar sym = [pattern characterAtIndex:s];
                int toneLenUnits = (sym == '-') ? 3 : 1;
                [intervals addObject:@{@"tone": @YES, @"samples": @(toneLenUnits * ditSamples)}];
                // 1 dit silence after every element
                [intervals addObject:@{@"tone": @NO, @"samples": @(ditSamples)}];
            }

            // Inter-character space
            if (i + 1 < upper.length) {
                NSString *nextCh = [upper substringWithRange:NSMakeRange(i + 1, 1)];
                if (![nextCh isEqualToString:@" "]) {
                    [intervals addObject:@{@"tone": @NO, @"samples": @(2 * ditSamples)}];
                }
            }
        }
        [intervals addObject:@{@"tone": @NO, @"samples": @(2 * ditSamples)}];
        return intervals;
    };

    // 1. Play local sidetone to Mac speakers/headphones
    if (self.sidetoneEnabled && self.sidetoneEngineReady && self.sidetonePlayer) {
        AVAudioFormat *sideFmt = [self.sidetoneEngine.mainMixerNode outputFormatForBus:0];
        if (sideFmt && sideFmt.sampleRate > 0) {
            NSMutableArray<NSDictionary *> *sideIntervals = buildIntervalsForRate(sideFmt.sampleRate);
            AVAudioPCMBuffer *sideBuf = TX500GenerateMorsePCMBuffer(sideFmt, sideIntervals, pitch, self.sidetoneVolume * 0.28f);
            if (sideBuf && token == self.transmissionGeneration && self.isTransmitting) {
                [self.sidetonePlayer scheduleBuffer:sideBuf atTime:nil options:0 completionHandler:nil];
                if (!self.sidetonePlayer.isPlaying) {
                    [self.sidetonePlayer play];
                }
            }
        }
    }

    // 2. Play Morse modulation tone to Radio USB Audio output interface (drives TX-500 transmitter!)
    [self ensureRadioAudioReady];
    if (self.radioQueueReady) {
        NSMutableArray<NSDictionary *> *radIntervals = buildIntervalsForRate(48000.0);
        int totalMorseSamples = 0;
        for (NSDictionary *d in radIntervals) {
            totalMorseSamples += [d[@"samples"] intValue];
        }
        if (totalMorseSamples > 0) {
            float *morseSamples = (float *)calloc(totalMorseSamples, sizeof(float));
            if (morseSamples) {
                double omega = 2.0 * M_PI * pitch / 48000.0;
                double currentPhase = 0;
                int rampSamples = (int)(0.004 * 48000.0); // 4ms raised-cosine envelope to eliminate key clicks
                if (rampSamples < 1) rampSamples = 1;
                int sampleOffset = 0;
                for (NSDictionary *d in radIntervals) {
                    BOOL isTone = [d[@"tone"] boolValue];
                    int count = [d[@"samples"] intValue];
                    if (isTone) {
                        int thisRamp = MIN(rampSamples, count / 4);
                        for (int s = 0; s < count; s++) {
                            float env = 1.0f;
                            if (s < thisRamp) {
                                env = 0.5f * (1.0f - cosf((float)s / (float)thisRamp * (float)M_PI));
                            } else if (s > count - 1 - thisRamp) {
                                env = 0.5f * (1.0f - cosf((float)(count - 1 - s) / (float)thisRamp * (float)M_PI));
                            }
                            morseSamples[sampleOffset + s] = 0.85f * env * sinf((float)currentPhase);
                            currentPhase += omega;
                            if (currentPhase > 2.0 * M_PI) currentPhase -= 2.0 * M_PI;
                        }
                    }
                    sampleOffset += count;
                }
                pthread_mutex_lock(&_radioAudioLock);
                if (_radioTxBuffer) {
                    free(_radioTxBuffer);
                    _radioTxBuffer = NULL;
                }
                _radioTxBuffer = morseSamples;
                _radioTxBufferTotalSamples = (UInt32)totalMorseSamples;
                _radioTxBufferReadIndex = 0;
                _isContinuousCarrier = NO;
                pthread_mutex_unlock(&_radioAudioLock);
            }
        }
    }

    return estDuration;
}

#pragma mark - Template Expansion

- (NSString *)expandTemplate:(NSString *)tmpl targetCall:(NSString *)call rst:(NSString *)rst name:(NSString *)name qth:(NSString *)qth {
    NSString *myCall = [self.myCallsign stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString ?: @"";
    NSString *tgtCall = call.length > 0 ? call.uppercaseString : @"CALL";
    NSString *rstVal = rst.length > 0 ? rst : @"599";
    if (self.useCutNumbers && [rstVal isEqualToString:@"599"]) {
        rstVal = @"5NN";
    }

    NSString *res = [tmpl stringByReplacingOccurrencesOfString:@"{MYCALL}" withString:myCall];
    res = [res stringByReplacingOccurrencesOfString:@"{CALL}" withString:tgtCall];
    res = [res stringByReplacingOccurrencesOfString:@"{RST}" withString:rstVal];
    res = [res stringByReplacingOccurrencesOfString:@"{NAME}" withString:(name.length > 0 ? name.uppercaseString : @"OP")];
    res = [res stringByReplacingOccurrencesOfString:@"{QTH}" withString:(qth.length > 0 ? qth.uppercaseString : @"QTH")];
    return [res stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].uppercaseString;
}

#pragma mark - Transmission

- (BOOL)templateNeedsMissingCallsign:(NSString *)tmpl {
    if (![tmpl containsString:@"{MYCALL}"]) return NO;
    return [self.myCallsign stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0;
}

- (BOOL)blocksMissingCallsignForTemplate:(NSString *)tmpl {
    if (![self templateNeedsMissingCallsign:tmpl]) return NO;
    if (self.logHandler) self.logHandler(@"[CW TX blocked] Enter your callsign in Station before sending {MYCALL}.");
    return YES;
}

- (void)transmitText:(NSString *)text targetCall:(NSString *)call rst:(NSString *)rst name:(NSString *)name qth:(NSString *)qth {
    if ([self blocksMissingCallsignForTemplate:text]) return;
    NSString *expanded = [self expandTemplate:text targetCall:call rst:rst name:name qth:qth];
    if (expanded.length == 0) return;

    [self abortTransmission];
    NSUInteger token=self.transmissionGeneration;
    self.isTransmitting = YES;
    self.activeBufferText = expanded;
    self.currentlyTransmittingChar = @"";

    [self.internalSentHistory insertObject:expanded atIndex:0];
    if (self.internalSentHistory.count > 40) {
        [self.internalSentHistory removeLastObject];
    }

    if (self.onTransmitStateChanged) {
        self.onTransmitStateChanged(YES, expanded);
    }

    // 1. Send Keyer Speed Command: KS<wpm>;
    NSInteger clampedWPM = fmax(3, fmin(45, self.wpm));
    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"CW TX (%ld WPM): %@", (long)clampedWPM, expanded]);
    }

    // 1. Key transceiver into TX mode
    if (self.serialCommandSender) {
        NSString *cmd = self.txPrefixCommand.length > 0 ? self.txPrefixCommand : @"TX;";
        BOOL ok = self.serialCommandSender(cmd);
        if (!ok) {
            [self abortTransmission];
            return;
        }
    }

    // 2. Synthesize and play authentic Morse code audio to Mac speakers & Radio USB Audio
    double totalEstSec = [self playMorseAudioForText:expanded wpm:clampedWPM pitchHz:self.sidetonePitchHz token:token];

    // 3. Completion callback when transmission finishes
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(totalEstSec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && token == strongSelf.transmissionGeneration && strongSelf.isTransmitting) {
            strongSelf.isTransmitting = NO;
            strongSelf.activeBufferText = @"";
            strongSelf.currentlyTransmittingChar = @"";
            pthread_mutex_lock(&strongSelf->_radioAudioLock);
            strongSelf->_isContinuousCarrier = NO;
            strongSelf->_radioTxBufferReadIndex = strongSelf->_radioTxBufferTotalSamples;
            pthread_mutex_unlock(&strongSelf->_radioAudioLock);
            if (strongSelf.sidetonePlayer.isPlaying) {
                [strongSelf.sidetonePlayer stop];
            }
            // Release TX back to RX
            if (strongSelf.serialCommandSender) {
                NSString *rxCmd = strongSelf.rxSuffixCommand.length > 0 ? strongSelf.rxSuffixCommand : @"RX;";
                strongSelf.serialCommandSender(rxCmd);
            }
            if (strongSelf.onTransmitStateChanged) {
                strongSelf.onTransmitStateChanged(NO, @"");
            }
        }
    });

    // 4. Safety Watchdog Timer: Guarantees radio returns to RX even if audio buffer completion has any delay
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((totalEstSec + 0.35) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && token == strongSelf.transmissionGeneration && strongSelf.isTransmitting) {
            [strongSelf abortTransmission];
        }
    });
}

- (void)abortTransmission {
    self.transmissionGeneration++;
    self.isTransmitting = NO;
    self.activeBufferText = @"";
    self.currentlyTransmittingChar = @"";

    pthread_mutex_lock(&_radioAudioLock);
    _isContinuousCarrier = NO;
    _radioTxBufferReadIndex = _radioTxBufferTotalSamples;
    pthread_mutex_unlock(&_radioAudioLock);

    if (self.sidetonePlayer.isPlaying) {
        [self.sidetonePlayer stop];
    }

    if (self.serialCommandSender) {
        NSString *rxCmd = self.rxSuffixCommand.length > 0 ? self.rxSuffixCommand : @"RX;";
        self.serialCommandSender(rxCmd);
    }

    if (self.onTransmitStateChanged) {
        self.onTransmitStateChanged(NO, @"");
    }
}

- (void)startContinuousCarrierWithPitchHz:(double)pitch {
    [self ensureRadioAudioReady];
    pthread_mutex_lock(&_radioAudioLock);
    _isContinuousCarrier = YES;
    _carrierFrequency = (pitch > 100.0) ? pitch : 650.0;
    _carrierAmplitude = 0.85f;
    _carrierPhase = 0.0;
    pthread_mutex_unlock(&_radioAudioLock);

    if (self.sidetoneEngineReady && self.sidetonePlayer && self.sidetoneEnabled) {
        AVAudioFormat *fmt = [self.sidetoneEngine.mainMixerNode outputFormatForBus:0];
        if (fmt && fmt.sampleRate > 0) {
            double sampleRate = fmt.sampleRate;
            NSUInteger frames = (NSUInteger)sampleRate;
            AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:(AVAudioFrameCount)frames];
            buffer.frameLength = (AVAudioFrameCount)frames;
            double omega = 2.0 * M_PI * pitch / sampleRate;
            float vol = self.sidetoneVolume * 0.20f;
            for (int ch = 0; ch < (int)fmt.channelCount; ch++) {
                float *data = buffer.floatChannelData[ch];
                double phase = 0;
                for (NSUInteger i = 0; i < frames; i++) {
                    data[i] = vol * sin(phase);
                    phase += omega;
                }
            }
            [self.sidetonePlayer stop];
            [self.sidetonePlayer scheduleBuffer:buffer atTime:nil options:AVAudioPlayerNodeBufferLoops completionHandler:nil];
            [self.sidetonePlayer play];
        }
    }
}

- (void)stopContinuousCarrier {
    pthread_mutex_lock(&_radioAudioLock);
    _isContinuousCarrier = NO;
    pthread_mutex_unlock(&_radioAudioLock);

    if (self.sidetonePlayer.isPlaying) {
        [self.sidetonePlayer stop];
    }
}

- (void)triggerMacroAtIndex:(NSInteger)index targetCall:(NSString *)call rst:(NSString *)rst name:(NSString *)name qth:(NSString *)qth {
    if (index < 0 || index >= (NSInteger)self.macroList.count) return;
    TX500CWMacro *m = self.macroList[index];
    [self transmitText:m.templateString targetCall:call rst:rst name:name qth:qth];
}

#pragma mark - Auto-CQ Repeater Loop

- (void)startAutoCQWithTemplate:(NSString *)tmpl targetCall:(NSString *)call {
    [self stopAutoCQ];
    NSString *cqTemplate = tmpl.length > 0 ? tmpl : @"CQ CQ DE {MYCALL} {MYCALL} K";
    if ([self blocksMissingCallsignForTemplate:cqTemplate]) return;
    self.isAutoCQActive = YES;
    self.currentAutoCQTemplate = cqTemplate;
    self.currentAutoCQCall = call;
    self.autoCQCountdown = self.autoCQIntervalSeconds;

    // Send first CQ immediately
    [self transmitText:self.currentAutoCQTemplate targetCall:self.currentAutoCQCall rst:@"" name:@"" qth:@""];

    // Timer every 1 second for countdown
    __weak typeof(self) weakSelf = self;
    self.autoCQTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf stepAutoCQ];
    }];
}

- (void)stopAutoCQ {
    [self.autoCQTimer invalidate];
    self.autoCQTimer = nil;
    self.isAutoCQActive = NO;
    self.autoCQCountdown = 0;
}

- (void)stepAutoCQ {
    if (!self.isAutoCQActive) return;

    if (self.isTransmitting) {
        // Wait while transmitting
        self.autoCQCountdown = self.autoCQIntervalSeconds;
        return;
    }

    if (self.autoCQCountdown > 0) {
        self.autoCQCountdown--;
    } else {
        // Time to repeat CQ
        if ([self blocksMissingCallsignForTemplate:self.currentAutoCQTemplate]) { [self stopAutoCQ]; return; }
        self.autoCQCountdown = self.autoCQIntervalSeconds;
        [self transmitText:self.currentAutoCQTemplate targetCall:self.currentAutoCQCall rst:@"" name:@"" qth:@""];
    }
}

@end
