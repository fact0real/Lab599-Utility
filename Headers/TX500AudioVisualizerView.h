//
//  TX500AudioVisualizerView.h
//  Lab599 Utility
//
//  High-Definition Real-Time SDR Audio Spectrum, Oscilloscope, and VU Meter
//  Designed for Lab599 Discovery TX-500 Audio Monitoring
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TX500VisualizerMode) {
    TX500VisualizerModeScope = 0,
    TX500VisualizerModeWaterfall = 1
};

typedef NS_ENUM(NSInteger, TX500WaterfallSpeed) {
    TX500WaterfallSpeedSlow = 0,
    TX500WaterfallSpeedNormal = 1,
    TX500WaterfallSpeedFast = 2
};

@interface TX500AudioVisualizerView : NSView

// Visualization Modes & Controls
@property (nonatomic, assign) TX500VisualizerMode displayMode;
@property (nonatomic, assign) TX500WaterfallSpeed waterfallSpeed;
@property (nonatomic, assign) float maxFrequencySpanHz;
@property (nonatomic, assign) float spectrumGainDb;

// DSP & Filter Display Overlay
@property (nonatomic, assign) float lowCutHz;
@property (nonatomic, assign) float highCutHz;
@property (nonatomic, assign) BOOL filterEnabled;
@property (nonatomic, assign) BOOL notchEnabled;
@property (nonatomic, assign) float notchFreqHz;

// VU Meter Levels (in dBFS)
@property (nonatomic, assign) float leftRmsDb;
@property (nonatomic, assign) float rightRmsDb;
@property (nonatomic, assign) float peakDb;
@property (nonatomic, assign) BOOL isClipping;
@property (nonatomic, assign) BOOL isSquelchOpen;

// Visual Theme Mode
@property (nonatomic, assign) BOOL phosphorAmberTheme; // NO = Cyber Cyan/Green, YES = Classic Amber

// Waterfall Dynamic Range Controls
@property (nonatomic, assign) float waterfallFloorDb;        // e.g. -100 to -20 dBFS, default -80
@property (nonatomic, assign) float waterfallDynamicRangeDb; // e.g. 20 to 80 dB, default 50

// Interactive Callbacks (Graphic Filter Dragging & Click-to-Notch)
@property (nonatomic, copy, nullable) void (^onFilterRangeChanged)(float lowCutHz, float highCutHz);
@property (nonatomic, copy, nullable) void (^onNotchFrequencyChanged)(float notchFreqHz);
@property (nonatomic, copy, nullable) void (^onFrequencyTuned)(float audioFreqHz);

// Feed Data Methods
- (void)updateSpectrumWithMagnitudes:(const float *)magnitudes count:(NSInteger)count sampleRate:(float)sampleRate;
- (void)updateWaveformWithSamples:(const float *)samples count:(NSInteger)count;
- (void)clearVisuals;

@end

NS_ASSUME_NONNULL_END
