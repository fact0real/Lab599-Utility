//
//  TX500CWKeyer.m
//  Lab599 Utility
//
//  Native Kenwood CAT Morse Keyer & Macro Automation Engine
//

#import "TX500CWKeyer.h"
#import <math.h>

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
@property (nonatomic, assign, readwrite) BOOL isTransmitting;
@property (nonatomic, copy, readwrite) NSString *activeBufferText;
@property (nonatomic, copy, readwrite) NSString *currentlyTransmittingChar;
@property (nonatomic, strong, readwrite) NSMutableArray<NSString *> *internalSentHistory;
@property (nonatomic, assign, readwrite) BOOL isAutoCQActive;
@property (nonatomic, assign, readwrite) NSInteger autoCQCountdown;

@property (nonatomic, strong, nullable) NSTimer *autoCQTimer;
@property (nonatomic, copy, nullable) NSString *currentAutoCQTemplate;
@property (nonatomic, copy, nullable) NSString *currentAutoCQCall;

// Audio Sidetone
@property (nonatomic, strong, nullable) AVAudioEngine *sidetoneEngine;
@property (nonatomic, strong, nullable) AVAudioPlayerNode *sidetonePlayer;
@property (nonatomic, assign) BOOL sidetoneEngineReady;

@end

@implementation TX500CWKeyer

- (instancetype)init {
    self = [super init];
    if (self) {
        _wpm = 22;
        _sidetonePitchHz = 650.0;
        _sidetoneEnabled = YES;
        _sidetoneVolume = 0.6f;
        _useCutNumbers = YES;
        _myCallsign = @"EP2AES";
        _autoCQIntervalSeconds = 4;
        _internalSentHistory = [NSMutableArray array];

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

        [self setupSidetoneAudio];
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
}

- (NSArray<NSString *> *)sentHistory {
    return [self.internalSentHistory copy];
}

#pragma mark - Sidetone Audio Setup

- (void)setupSidetoneAudio {
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
}

- (void)playSidetoneToneDuration:(double)duration pitchHz:(double)pitch {
    if (!self.sidetoneEnabled || !self.sidetoneEngineReady || duration <= 0) return;

    AVAudioFormat *fmt = [self.sidetoneEngine.mainMixerNode outputFormatForBus:0];
    if (!fmt || fmt.sampleRate <= 0) return;

    double sampleRate = fmt.sampleRate;
    int frameCount = (int)(duration * sampleRate);
    if (frameCount <= 0) return;

    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:fmt frameCapacity:frameCount];
    buffer.frameLength = frameCount;

    double omega = 2.0 * M_PI * pitch / sampleRate;
    int rampFrames = (int)(0.005 * sampleRate); // 5ms soft edge

    for (int ch = 0; ch < (int)fmt.channelCount; ch++) {
        float *channelData = buffer.floatChannelData[ch];
        for (int i = 0; i < frameCount; i++) {
            float env = 1.0f;
            if (i < rampFrames) {
                env = 0.5f * (1.0f - cosf((float)i / (float)rampFrames * (float)M_PI));
            } else if (i > frameCount - rampFrames) {
                env = 0.5f * (1.0f - cosf((float)(frameCount - i) / (float)rampFrames * (float)M_PI));
            }
            channelData[i] = self.sidetoneVolume * 0.25f * env * sin(omega * (double)i);
        }
    }

    [self.sidetonePlayer scheduleBuffer:buffer atTime:nil options:0 completionHandler:nil];
    if (!self.sidetonePlayer.isPlaying) {
        [self.sidetonePlayer play];
    }
}

#pragma mark - Template Expansion

- (NSString *)expandTemplate:(NSString *)tmpl targetCall:(NSString *)call rst:(NSString *)rst name:(NSString *)name qth:(NSString *)qth {
    NSString *myCall = self.myCallsign.length > 0 ? self.myCallsign.uppercaseString : @"EP2AES";
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

- (void)transmitText:(NSString *)text targetCall:(NSString *)call rst:(NSString *)rst name:(NSString *)name qth:(NSString *)qth {
    NSString *expanded = [self expandTemplate:text targetCall:call rst:rst name:name qth:qth];
    if (expanded.length == 0) return;

    [self abortTransmission];
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
    NSInteger clampedWPM = fmax(5, fmin(45, self.wpm));
    NSString *ksCmd = [NSString stringWithFormat:@"KS%03ld;", (long)clampedWPM];
    if (self.serialCommandSender) {
        self.serialCommandSender(ksCmd);
    }

    // 2. Chunk text into 24-character Kenwood KY buffers
    NSMutableArray<NSString *> *chunks = [NSMutableArray array];
    NSUInteger length = expanded.length;
    NSUInteger offset = 0;
    while (offset < length) {
        NSUInteger thisLen = MIN((NSUInteger)24, length - offset);
        [chunks addObject:[expanded substringWithRange:NSMakeRange(offset, thisLen)]];
        offset += thisLen;
    }

    // 3. Send successive KY commands with pacing
    double ditSec = 1.2 / (double)clampedWPM;
    double charEstSec = ditSec * 7.5; // Average char length in CW

    for (NSUInteger i = 0; i < chunks.count; i++) {
        NSString *chunk = chunks[i];
        NSString *kyCmd = [NSString stringWithFormat:@"KY %@;", chunk];

        if (i == 0) {
            if (self.serialCommandSender) {
                self.serialCommandSender(kyCmd);
            }
            if (self.logHandler) {
                self.logHandler([NSString stringWithFormat:@"CW TX: %@", chunk]);
            }
        } else {
            double delay = (double)chunks[i - 1].length * charEstSec * 0.85;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (self.isTransmitting && self.serialCommandSender) {
                    self.serialCommandSender(kyCmd);
                    if (self.logHandler) {
                        self.logHandler([NSString stringWithFormat:@"CW TX (buffer): %@", chunk]);
                    }
                }
            });
        }
    }

    // Calculate total duration for sidetone and state completion
    double totalEstSec = (double)expanded.length * charEstSec;
    
    // Play sidetone summary
    if (self.sidetoneEnabled) {
        [self playSidetoneToneDuration:totalEstSec pitchHz:self.sidetonePitchHz];
    }

    // Completion callback
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(totalEstSec * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.isTransmitting) {
            strongSelf.isTransmitting = NO;
            strongSelf.activeBufferText = @"";
            strongSelf.currentlyTransmittingChar = @"";
            if (strongSelf.onTransmitStateChanged) {
                strongSelf.onTransmitStateChanged(NO, @"");
            }
        }
    });
}

- (void)abortTransmission {
    self.isTransmitting = NO;
    self.activeBufferText = @"";
    self.currentlyTransmittingChar = @"";

    if (self.serialCommandSender) {
        // Kenwood abort morse command: empty KY followed by RX
        self.serialCommandSender(@"KY ;RX;");
    }

    if (self.sidetonePlayer.isPlaying) {
        [self.sidetonePlayer stop];
    }

    if (self.onTransmitStateChanged) {
        self.onTransmitStateChanged(NO, @"");
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
    self.isAutoCQActive = YES;
    self.currentAutoCQTemplate = tmpl.length > 0 ? tmpl : @"CQ CQ DE {MYCALL} {MYCALL} K";
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
        self.autoCQCountdown = self.autoCQIntervalSeconds;
        [self transmitText:self.currentAutoCQTemplate targetCall:self.currentAutoCQCall rst:@"" name:@"" qth:@""];
    }
}

@end
