//
//  TX500CWAudioDecoder.h
//  Lab599 Utility
//
//  Real-Time DSP Morse Code Audio Decoder Engine for macOS
//  Optimized for Lab599 Discovery TX-500 over AD-508 USB-C Audio / REM-DATA
//  Features Goertzel narrow-band tone tracking, AFC, adaptive Schmitt-trigger hysteresis,
//  sample-accurate dit/dah/space timing, WPM estimation, and synthetic practice simulation.
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TX500CWSpectrumBin : NSObject
@property (nonatomic, assign) NSInteger binId;
@property (nonatomic, assign) double frequencyHz;
@property (nonatomic, assign) float magnitude;
@end

@interface TX500CWDecodedToken : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) BOOL isCallsign;
@property (nonatomic, assign) BOOL isQCode;
@property (nonatomic, assign) BOOL isReport;
@property (nonatomic, strong) NSDate *timestamp;
@end

@interface TX500CWAudioDecoder : NSObject

// Operational State
@property (nonatomic, assign, readonly) BOOL isListening;
@property (nonatomic, assign, readonly) BOOL isAudioAvailable;
@property (nonatomic, assign, readonly) BOOL isSignalDetected;
@property (nonatomic, assign, readonly) double centerFrequencyHz;
@property (nonatomic, assign) double nominalPitchHz; // 450 - 900 Hz, default 650 Hz
@property (nonatomic, assign) BOOL afcEnabled;       // Automatic frequency control (+/- 50 Hz)
@property (nonatomic, assign, readonly) double estimatedWPM;
@property (nonatomic, assign, readonly) double signalToNoiseRatioDb;
@property (nonatomic, assign, readonly) double ditDahRatio;
@property (nonatomic, assign, readonly) float audioInputLevel;

// Decoded Text Output
@property (nonatomic, copy, readonly) NSString *rawDecodedText;
@property (nonatomic, copy, readonly) NSString *activeCharacterBuffer; // e.g. ".-."
@property (nonatomic, strong, readonly) NSArray<TX500CWDecodedToken *> *decodedTokens;
@property (nonatomic, strong, readonly) NSArray<TX500CWSpectrumBin *> *spectrumBins;

// Audio Device & Simulation
@property (nonatomic, copy, nullable) NSString *selectedAudioDeviceUID;
@property (nonatomic, strong, readonly) NSArray<NSDictionary<NSString *, NSString *> *> *availableAudioInputDevices;
@property (nonatomic, assign) BOOL isSimulationActive;

// Callbacks
@property (nonatomic, copy, nullable) void (^onDecodedTextUpdated)(NSString *newText, NSString *characterBuffer);
@property (nonatomic, copy, nullable) void (^onTokenReceived)(TX500CWDecodedToken *token);
@property (nonatomic, copy, nullable) void (^onMetricsUpdated)(double wpm, double snrDb, float inputLevel, BOOL signalPresent);
@property (nonatomic, copy, nullable) void (^onSpectrumUpdated)(NSArray<TX500CWSpectrumBin *> *bins);

// Methods
- (void)startListening;
- (void)stopListening;
- (void)clearBuffer;
- (void)setPitch:(double)hz;
- (void)setNominalWPM:(double)wpm;
- (void)refreshAudioDevices;
- (void)startSimulation;
- (void)stopSimulation;
- (void)feedSyntheticAudioWithFrequency:(double)freq duration:(double)duration isMark:(BOOL)isMark;
- (void)feedSyntheticMorseString:(NSString *)morseText wpm:(double)wpm pitchHz:(double)pitchHz;

// Reverse Morse Lookup Dictionary (Morse string -> Character)
+ (NSDictionary<NSString *, NSString *> *)reverseMorseAlphabet;

@end

NS_ASSUME_NONNULL_END
