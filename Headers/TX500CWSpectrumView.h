//
//  TX500CWSpectrumView.h
//  Lab599 Utility
//
//  Real-Time Audio Spectrum Scope & Signal Metric Visualizer for CW Station
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

/// Callback triggered when user clicks anywhere on the spectrum to tune the pitch
@property (nonatomic, copy, nullable) void (^onPitchSelected)(double pitchHz);

- (void)updateWithBins:(NSArray<TX500CWSpectrumBin *> *)bins
             centerFreq:(double)centerFreq
            nominalPitch:(double)pitch
                   level:(float)level
                   snrDb:(double)snr
          signalDetected:(BOOL)detected;

@end

NS_ASSUME_NONNULL_END
