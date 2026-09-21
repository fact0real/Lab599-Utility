//
//  TX500FT8WaterfallView.h
//  Lab599 Utility
//
//  High-Performance 2D Spectrogram & Scrolling Waterfall View for FT8
//  Features calibrated frequency ruler (200-3000 Hz), RX & TX reticle markers,
//  click-to-tune passband positioning, and Lab599 Signature color palettes.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, TX500FT8Palette) {
    TX500FT8PaletteLab599Red = 0,   // Lab599 CNC Black -> Amber -> Signature Red -> White
    TX500FT8PaletteOceanicBlue,     // Navy -> Cyan -> White
    TX500FT8PalettePhosphorGreen,   // Dark Emerald -> Phosphor Green -> White
    TX500FT8PalettePlasma           // Deep Purple -> Orange -> Yellow
};

@interface TX500FT8WaterfallView : NSView

@property (nonatomic, assign) float rxFrequencyHz;
@property (nonatomic, assign) float txFrequencyHz;
@property (nonatomic, assign) BOOL isTransmitting;
@property (nonatomic, assign) TX500FT8Palette palette;

// Click-to-tune callback (isTx = YES if shift-clicked or right-clicked)
@property (nonatomic, copy, nullable) void (^onFrequencySelected)(float freqHz, BOOL isTx);

// Ingest live spectral magnitudes
- (void)appendSpectrumRow:(const float *)magnitudes count:(NSInteger)count;
- (void)clearWaterfall;

@end

NS_ASSUME_NONNULL_END
