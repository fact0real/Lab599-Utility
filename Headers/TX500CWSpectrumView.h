//
//  TX500CWSpectrumView.h
//  Lab599 Utility
//
//  Real-Time Audio Spectrum Scope & 2D Scrolling Waterfall for CW Station
//  Wideband 300 - 3000 Hz coverage, interactive click-to-tune, carrier markers,
//  and signal metric visualizer.
//

#import <Cocoa/Cocoa.h>
#import "TX500CWAudioDecoder.h"

NS_ASSUME_NONNULL_BEGIN

@interface TX500CWSpectrumView : NSView

@property (nonatomic, copy) NSArray<TX500CWSpectrumBin *> *bins;
@property (nonatomic, assign) double centerFrequencyHz;
@property (nonatomic, assign) double nominalPitchHz;
@property (nonatomic, assign) float audioLevel;
@property (nonatomic, assign) double snrDb;
@property (nonatomic, assign) BOOL isSignalDetected;

/// Detected carrier frequencies across the wideband passband (300 - 3000 Hz)
@property (nonatomic, copy) NSArray<NSNumber *> *detectedCarrierFrequencies;

@property (nonatomic, assign) double minDisplayFreqHz; // default 300.0
@property (nonatomic, assign) double maxDisplayFreqHz; // default 3000.0

/// Callback triggered when user clicks anywhere on the spectrum or waterfall to tune the pitch
@property (nonatomic, copy, nullable) void (^onPitchSelected)(double pitchHz);

/// Callback triggered when user clicks on a signal or frequency to retune radio VFO
@property (nonatomic, copy, nullable) void (^onWaterfallFrequencyClicked)(double audioFreqHz);

- (void)updateWithBins:(NSArray<TX500CWSpectrumBin *> *)bins
             centerFreq:(double)centerFreq
            nominalPitch:(double)pitch
                   level:(float)level
                   snrDb:(double)snr
          signalDetected:(BOOL)detected;

- (void)updateWithBins:(NSArray<TX500CWSpectrumBin *> *)bins
             centerFreq:(double)centerFreq
            nominalPitch:(double)pitch
                   level:(float)level
                   snrDb:(double)snr
          signalDetected:(BOOL)detected
        detectedCarriers:(nullable NSArray<NSNumber *> *)carriers;

- (void)clearWaterfall;

@end

NS_ASSUME_NONNULL_END
