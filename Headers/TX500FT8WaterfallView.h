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
    TX500FT8PaletteRainbow = 0,     // SDR Rainbow: Dark Blue -> Cyan -> Green -> Yellow -> Orange -> Red -> White
    TX500FT8PaletteHeat,            // Thermal: Black -> Deep Red -> Orange -> Gold -> White
    TX500FT8PaletteDigipan,         // Classic DigiPan: Deep Navy -> Electric Cyan -> Yellow -> Red
    TX500FT8PaletteLab599Red,       // Lab599 Machined Black -> Amber -> Signature Red -> White
    TX500FT8PaletteOceanicBlue,     // WSJT-X Oceanic: Midnight Blue -> Sky Blue -> White
    TX500FT8PalettePhosphorGreen,   // Tactical CRT: Dark Emerald -> Phosphor Green -> White
    TX500FT8PalettePlasma           // Deep Purple -> Neon Pink -> Orange -> Yellow
};

@interface TX500FT8WaterfallView : NSView

@property (nonatomic, assign) float rxFrequencyHz;
@property (nonatomic, assign) float txFrequencyHz;
@property (nonatomic, assign) BOOL isTransmitting;
@property (nonatomic, assign) TX500FT8Palette palette;
@property (nonatomic, assign) float gain;           // 0.2 to 3.0, default 1.0
@property (nonatomic, assign) float contrastFloor;  // -0.3 to +0.3, default 0.0
@property (nonatomic, assign) NSInteger scrollSpeed; // 1 to 3 rows per frame

// Callsign HUD Overlay Badges
@property (nonatomic, assign) BOOL showCallsignTags;
@property (nonatomic, copy, nullable) NSArray<NSDictionary *> *activeStationTags;

// Click-to-tune callback (isTx = YES if shift-clicked or right-clicked)
@property (nonatomic, copy, nullable) void (^onFrequencySelected)(float freqHz, BOOL isTx);

// Palette Names for UI Pickers
+ (NSArray<NSString *> *)paletteNames;

// Ingest live spectral magnitudes
- (void)appendSpectrumRow:(const float *)magnitudes count:(NSInteger)count;
- (void)clearWaterfall;

@end

NS_ASSUME_NONNULL_END
