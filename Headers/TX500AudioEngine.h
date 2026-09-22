//
//  TX500AudioEngine.h
//  Lab599 Utility
//
//  High-Performance Low-Latency CoreAudio Monitoring & DSP Engine
//  Specially designed for Lab599 Discovery TX-500 over AD-508 USB-C Audio
//  Features live passthrough, bandpass/notch filtering, squelch, AGC limiter,
//  real-time FFT spectrum & waveform visualizer tap, and broadcast WAV recorder.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TX500AudioFilterPreset) {
    TX500AudioFilterPresetSSBVoice = 0,    // Standard SSB Voice: 300 Hz - 2700 Hz
    TX500AudioFilterPresetSSBWide  = 1,    // Hi-Fi SSB Wide: 150 Hz - 3400 Hz
    TX500AudioFilterPresetCWNarrow = 2,    // CW Narrow: 550 Hz - 750 Hz (centered at 650 Hz)
    TX500AudioFilterPresetAMBroad  = 3,    // AM / Broadcast: 80 Hz - 4500 Hz
    TX500AudioFilterPresetDXBoost  = 4,    // DX Weak Signal: Peaked speech intelligibility
    TX500AudioFilterPresetFlat     = 5     // Flat / Full Bandwidth Bypass
};

@interface TX500AudioDeviceItem : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *uid;
@property (nonatomic, assign) BOOL isAD508;
@property (nonatomic, assign) BOOL isUSB;
@property (nonatomic, assign) BOOL isVirtual;
@property (nonatomic, assign) BOOL isInput;
@end

@interface TX500AudioEngine : NSObject

// State
@property (nonatomic, assign, readonly) BOOL isMonitoring;
@property (nonatomic, assign, readonly) BOOL isRecording;
@property (nonatomic, assign, readonly) BOOL isAD508Connected;
@property (nonatomic, copy, readonly, nullable) NSString *ad508DeviceName;
@property (nonatomic, assign) BOOL isSimulationMode;

// Hardware Devices
@property (nonatomic, copy, nullable) NSString *selectedInputDeviceUID;
@property (nonatomic, copy, nullable) NSString *selectedOutputDeviceUID;
@property (nonatomic, strong, readonly) NSArray<TX500AudioDeviceItem *> *inputDevices;
@property (nonatomic, strong, readonly) NSArray<TX500AudioDeviceItem *> *outputDevices;
@property (nonatomic, assign) NSInteger bufferSizeFrames; // 256 (5ms), 512 (10ms), 1024 (21ms)

// Volume, Gain & Panning
@property (nonatomic, assign) float masterVolume; // 0.0 to 2.0 (1.0 = 100%, 2.0 = +6dB boost)
@property (nonatomic, assign) BOOL isMuted;
@property (nonatomic, assign) BOOL isDimmed;      // -20dB attenuation
@property (nonatomic, assign) float balance;      // -1.0 (Left) to +1.0 (Right), 0.0 = Center

// DSP Filter Parameters
@property (nonatomic, assign) TX500AudioFilterPreset filterPreset;
@property (nonatomic, assign) BOOL filterEnabled;
@property (nonatomic, assign) float lowCutHz;     // High-pass cutoff (50 - 1000 Hz)
@property (nonatomic, assign) float highCutHz;    // Low-pass cutoff (1000 - 5000 Hz)

// Notch Filter
@property (nonatomic, assign) BOOL notchEnabled;
@property (nonatomic, assign) float notchFreqHz;  // 200 - 3500 Hz
@property (nonatomic, assign) float notchQ;       // default 8.0 (sharp)

// Auto-Notch Filter (ANF)
@property (nonatomic, assign) BOOL autoNotchEnabled;
@property (nonatomic, assign, readonly) float detectedAutoNotchHz;

// DSP Spectral Noise Reduction (LMS / Speech Enhancer)
@property (nonatomic, assign) BOOL nrEnabled;
@property (nonatomic, assign) float nrLevel; // 0.0 to 1.0 (Depth / Strength, default 0.6)

// 3-Band Speech Equalizer (Intelligibility Booster)
@property (nonatomic, assign) BOOL eqEnabled;
@property (nonatomic, assign) float eqLowGainDb;  // 250 Hz, -12 to +12 dB
@property (nonatomic, assign) float eqMidGainDb;  // 1800 Hz, -12 to +12 dB
@property (nonatomic, assign) float eqHighGainDb; // 3200 Hz, -12 to +12 dB

// Instant Replay 15s (Rolling Audio Buffer)
@property (nonatomic, assign, readonly) BOOL isReplaying;
@property (nonatomic, assign, readonly) float replayProgress; // 0.0 to 1.0
@property (nonatomic, copy, nullable) void (^onReplayProgressChanged)(BOOL isReplaying, float progress);

// Noise Gate / Squelch
@property (nonatomic, assign) BOOL squelchEnabled;
@property (nonatomic, assign) float squelchThresholdDb; // -80 dB to -20 dB
@property (nonatomic, assign, readonly) BOOL isSquelchOpen;

// AGC / Ear Protection Peak Limiter
@property (nonatomic, assign) BOOL limiterEnabled;

// Real-Time Metrics for UI
@property (nonatomic, assign, readonly) float leftLevelRmsDb;
@property (nonatomic, assign, readonly) float rightLevelRmsDb;
@property (nonatomic, assign, readonly) float peakLevelDb;
@property (nonatomic, assign, readonly) BOOL isClipping;
@property (nonatomic, assign, readonly) float currentLatencyMs;

// Recording
@property (nonatomic, copy, readonly, nullable) NSString *currentRecordingPath;
@property (nonatomic, assign, readonly) NSTimeInterval recordingDuration;
@property (nonatomic, assign, readonly) int64_t recordingBytes;

// Callbacks
@property (nonatomic, copy, nullable) void (^onMetricsUpdated)(float leftRmsDb, float rightRmsDb, float peakDb, BOOL clipping, BOOL squelchOpen);
@property (nonatomic, copy, nullable) void (^onSpectrumUpdated)(const float *magnitudes, NSInteger count, float sampleRate);
@property (nonatomic, copy, nullable) void (^onWaveformUpdated)(const float *samples, NSInteger count);
@property (nonatomic, copy, nullable) void (^onDeviceListChanged)(void);
@property (nonatomic, copy, nullable) void (^onRecordingStatusChanged)(BOOL isRecording, NSTimeInterval duration, NSString * _Nullable path);
@property (nonatomic, copy, nullable) void (^onErrorOccurred)(NSString *errorMessage);

// Control Methods
- (void)refreshDevices;
- (BOOL)startMonitoring:(NSError **)error;
- (void)stopMonitoring;
- (void)processRawAudioSamples:(const float *)samples count:(NSInteger)count;

- (void)applyPreset:(TX500AudioFilterPreset)preset;

// Instant Replay
- (void)startInstantReplay;
- (void)stopInstantReplay;

- (BOOL)startRecordingWithError:(NSError **)error;
- (void)stopRecording;
- (void)revealRecordingsInFinder;

// Simulation
- (void)startSimulation;
- (void)stopSimulation;

@end

NS_ASSUME_NONNULL_END
