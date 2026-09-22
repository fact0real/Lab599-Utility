//
//  TX500AudioVisualizerView.m
//  Lab599 Utility
//
//  High-Definition Real-Time SDR Audio Spectrum, Oscilloscope, Waterfall, and VU Meter
//

#import "TX500AudioVisualizerView.h"
#import <math.h>

#define DEFAULT_SPECTRUM_MAX_FREQ 4000.0f
#define MAX_BINS 256
#define MAX_WAVE 512
#define WATERFALL_WIDTH 256
#define WATERFALL_HEIGHT 120

@interface TX500AudioVisualizerView () {
    float _spectrumBins[MAX_BINS];
    float _peakBins[MAX_BINS];
    NSInteger _binCount;
    float _sampleRate;

    float _waveformSamples[MAX_WAVE];
    NSInteger _waveformCount;

    // Waterfall circular/rolling pixel buffer (32-bit RGBA)
    uint32_t _waterfallPixels[WATERFALL_HEIGHT * WATERFALL_WIDTH];
    uint32_t _cyanPalette[256];
    uint32_t _amberPalette[256];
    NSInteger _waterfallSkipCounter;

    float _smoothedLeftRmsDb;
    float _smoothedRightRmsDb;
    float _smoothedPeakDb;
    float _peakHoldDb;
    NSInteger _peakHoldDecayCount;

    NSTimeInterval _lastRedrawTime;
    BOOL _redrawScheduled;
    NSTimeInterval _clipHoldUntil;

    // Mouse interaction for filter passband and click-to-notch
    NSInteger _activeDragMode; // 0 = None, 1 = LowCut, 2 = HighCut, 3 = Passband, 4 = Notch
    NSPoint _dragStartPoint;
    float _dragInitialLowCut;
    float _dragInitialHighCut;
    float _dragInitialNotchFreq;
    NSTrackingArea *_trackingArea;
    NSRect _cachedSpectrumRect;
}
@end

@implementation TX500AudioVisualizerView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 8.0;
        self.layer.masksToBounds = YES;

        _displayMode = TX500VisualizerModeScope;
        _waterfallSpeed = TX500WaterfallSpeedNormal;
        _maxFrequencySpanHz = DEFAULT_SPECTRUM_MAX_FREQ;
        _spectrumGainDb = 0.0f;
        _waterfallFloorDb = -80.0f;
        _waterfallDynamicRangeDb = 50.0f;

        _lowCutHz = 300.0f;
        _highCutHz = 2700.0f;
        _filterEnabled = YES;
        _notchEnabled = NO;
        _notchFreqHz = 1000.0f;

        _leftRmsDb = -90.0f;
        _rightRmsDb = -90.0f;
        _peakDb = -90.0f;
        _smoothedLeftRmsDb = -90.0f;
        _smoothedRightRmsDb = -90.0f;
        _smoothedPeakDb = -90.0f;
        _peakHoldDb = -90.0f;
        _isSquelchOpen = YES;
        _clipHoldUntil = 0;

        _activeDragMode = 0;
        _cachedSpectrumRect = NSZeroRect;

        _binCount = 0;
        _waveformCount = 0;
        _sampleRate = 48000.0f;
        _waterfallSkipCounter = 0;
        _lastRedrawTime = 0;
        _redrawScheduled = NO;

        [self initPalettes];
        [self clearWaterfallPixels];
    }
    return self;
}

- (void)initPalettes {
    // 1. Cyber Cyan / Teal Palette (Dark Navy -> Deep Teal -> Vivid Cyan -> Electric White)
    for (int i = 0; i < 256; i++) {
        float t = i / 255.0f;
        uint8_t r, g, b;
        if (t < 0.20f) {
            float f = t / 0.20f;
            r = (uint8_t)(6 * (1.0f - f));
            g = (uint8_t)(10 + 35 * f);
            b = (uint8_t)(16 + 65 * f);
        } else if (t < 0.65f) {
            float f = (t - 0.20f) / 0.45f;
            r = (uint8_t)(0);
            g = (uint8_t)(45 + 175 * f);
            b = (uint8_t)(81 + 145 * f);
        } else {
            float f = (t - 0.65f) / 0.35f;
            r = (uint8_t)(220 * f);
            g = (uint8_t)(220 + 35 * f);
            b = 255;
        }
        _cyanPalette[i] = (r << 24) | (g << 16) | (b << 8) | 0xFF;
    }

    // 2. Phosphor Amber / Flame Palette (Dark Umber -> Rich Crimson -> Amber/Gold -> Yellow-White)
    for (int i = 0; i < 256; i++) {
        float t = i / 255.0f;
        uint8_t r, g, b;
        if (t < 0.25f) {
            float f = t / 0.25f;
            r = (uint8_t)(16 + 64 * f);
            g = (uint8_t)(6 + 18 * f);
            b = (uint8_t)(2);
        } else if (t < 0.70f) {
            float f = (t - 0.25f) / 0.45f;
            r = (uint8_t)(80 + 175 * f);
            g = (uint8_t)(24 + 140 * f);
            b = (uint8_t)(2 + 10 * f);
        } else {
            float f = (t - 0.70f) / 0.30f;
            r = 255;
            g = (uint8_t)(164 + 91 * f);
            b = (uint8_t)(12 + 220 * f);
        }
        _amberPalette[i] = (r << 24) | (g << 16) | (b << 8) | 0xFF;
    }
}

- (void)clearWaterfallPixels {
    uint32_t darkBg = (15 << 24) | (20 << 16) | (28 << 8) | 0xFF;
    for (NSInteger i = 0; i < WATERFALL_HEIGHT * WATERFALL_WIDTH; i++) {
        _waterfallPixels[i] = darkBg;
    }
}

- (BOOL)isOpaque {
    return YES;
}

- (void)scheduleSmoothRedraw {
    if (self.hidden || self.window == nil || self.superview.hidden) {
        return;
    }
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (now - _lastRedrawTime >= 0.030) { // Capped at ~33 FPS
        _lastRedrawTime = now;
        _redrawScheduled = NO;
        if ([NSThread isMainThread]) {
            [self setNeedsDisplay:YES];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setNeedsDisplay:YES];
            });
        }
    } else if (!_redrawScheduled) {
        _redrawScheduled = YES;
        NSTimeInterval delay = 0.030 - (now - _lastRedrawTime);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self->_lastRedrawTime = [NSDate timeIntervalSinceReferenceDate];
            self->_redrawScheduled = NO;
            [self setNeedsDisplay:YES];
        });
    }
}

- (void)updateSpectrumWithMagnitudes:(const float *)magnitudes count:(NSInteger)count sampleRate:(float)sampleRate {
    _sampleRate = sampleRate > 0 ? sampleRate : 48000.0f;
    _binCount = MIN(count, MAX_BINS);

    // Responsive attack, smooth silky decay to prevent erratic jumping
    for (NSInteger i = 0; i < _binCount; i++) {
        float raw = magnitudes[i];
        if (raw > _spectrumBins[i]) {
            _spectrumBins[i] = 0.45f * _spectrumBins[i] + 0.55f * raw;
        } else {
            _spectrumBins[i] = 0.88f * _spectrumBins[i] + 0.12f * raw;
        }

        if (_spectrumBins[i] > _peakBins[i]) {
            _peakBins[i] = _spectrumBins[i];
        } else {
            _peakBins[i] *= 0.97f;
        }
    }

    // Advance waterfall line based on speed
    NSInteger skipThreshold = 2; // Normal = update every 2nd frame
    if (_waterfallSpeed == TX500WaterfallSpeedSlow) {
        skipThreshold = 4;
    } else if (_waterfallSpeed == TX500WaterfallSpeedFast) {
        skipThreshold = 1;
    }

    _waterfallSkipCounter++;
    if (_waterfallSkipCounter >= skipThreshold) {
        _waterfallSkipCounter = 0;
        [self advanceWaterfallLine];
    }

    [self scheduleSmoothRedraw];
}

- (void)advanceWaterfallLine {
    // Shift rows down by 1
    memmove(&_waterfallPixels[WATERFALL_WIDTH], &_waterfallPixels[0], (WATERFALL_HEIGHT - 1) * WATERFALL_WIDTH * sizeof(uint32_t));

    // Populate row 0 with mapped frequency spectrum
    const uint32_t *palette = self.phosphorAmberTheme ? _amberPalette : _cyanPalette;
    float maxFreq = self.maxFrequencySpanHz > 0 ? self.maxFrequencySpanHz : DEFAULT_SPECTRUM_MAX_FREQ;
    float nyquist = _sampleRate * 0.5f;

    for (NSInteger x = 0; x < WATERFALL_WIDTH; x++) {
        float freq = ((float)x / (float)(WATERFALL_WIDTH - 1)) * maxFreq;
        float binPos = (freq / nyquist) * (float)_binCount;
        NSInteger binIdx = (NSInteger)binPos;

        float mag = 0.0f;
        if (binIdx >= 0 && binIdx < _binCount) {
            mag = _spectrumBins[binIdx];
        }

        float db = mag > 1e-5f ? 20.0f * log10f(mag) + self.spectrumGainDb : -120.0f;
        float floorDb = self.waterfallFloorDb != 0.0f ? self.waterfallFloorDb : -80.0f;
        float dynRange = self.waterfallDynamicRangeDb > 5.0f ? self.waterfallDynamicRangeDb : 50.0f;
        float norm = (db - floorDb) / dynRange;
        if (norm < 0.0f) norm = 0.0f;
        if (norm > 1.0f) norm = 1.0f;

        uint8_t pIdx = (uint8_t)(norm * 255.0f);
        _waterfallPixels[x] = palette[pIdx];
    }
}

- (void)updateWaveformWithSamples:(const float *)samples count:(NSInteger)count {
    _waveformCount = MIN(count, MAX_WAVE);
    for (NSInteger i = 0; i < _waveformCount; i++) {
        _waveformSamples[i] = samples[i];
    }
    if (_displayMode == TX500VisualizerModeScope) {
        [self scheduleSmoothRedraw];
    }
}

- (void)setLeftRmsDb:(float)leftRmsDb {
    _leftRmsDb = leftRmsDb;
    _smoothedLeftRmsDb = 0.7f * _smoothedLeftRmsDb + 0.3f * leftRmsDb;
}

- (void)setRightRmsDb:(float)rightRmsDb {
    _rightRmsDb = rightRmsDb;
    _smoothedRightRmsDb = 0.7f * _smoothedRightRmsDb + 0.3f * rightRmsDb;
}

- (void)setPeakDb:(float)peakDb {
    _peakDb = peakDb;
    _smoothedPeakDb = 0.8f * _smoothedPeakDb + 0.2f * peakDb;
    if (peakDb > _peakHoldDb) {
        _peakHoldDb = peakDb;
        _peakHoldDecayCount = 0;
    } else {
        _peakHoldDecayCount++;
        if (_peakHoldDecayCount > 30) {
            _peakHoldDb -= 0.5f;
        }
    }
}

- (void)clearVisuals {
    memset(_spectrumBins, 0, sizeof(_spectrumBins));
    memset(_peakBins, 0, sizeof(_peakBins));
    memset(_waveformSamples, 0, sizeof(_waveformSamples));
    _smoothedLeftRmsDb = _smoothedRightRmsDb = _smoothedPeakDb = _peakHoldDb = -90.0f;
    [self clearWaterfallPixels];
    [self setNeedsDisplay:YES];
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    NSRect bounds = self.bounds;

    // 1. Dark Precision Instrument Background
    [[NSColor colorWithCalibratedRed:0.06 green:0.08 blue:0.11 alpha:1.0] setFill];
    NSRectFill(bounds);

    // Layout Split:
    // Right column: VU Meter (width 68 pt)
    // Left column: Spectrum (top 62%) + Oscilloscope/Waterfall (bottom 38%)
    CGFloat vuWidth = 68.0;
    NSRect mainArea = NSMakeRect(bounds.origin.x, bounds.origin.y, bounds.size.width - vuWidth, bounds.size.height);
    NSRect vuArea = NSMakeRect(bounds.origin.x + bounds.size.width - vuWidth, bounds.origin.y, vuWidth, bounds.size.height);

    CGFloat specHeight = floor(mainArea.size.height * 0.62);
    CGFloat subHeight = mainArea.size.height - specHeight;

    NSRect specRect = NSMakeRect(mainArea.origin.x, mainArea.origin.y + subHeight, mainArea.size.width, specHeight);
    NSRect subRect = NSMakeRect(mainArea.origin.x, mainArea.origin.y, mainArea.size.width, subHeight);

    // 2. Draw Spectrum Area
    [self drawSpectrumInRect:specRect context:ctx];

    // 3. Draw Oscilloscope OR Waterfall Area
    if (self.displayMode == TX500VisualizerModeWaterfall) {
        [self drawWaterfallInRect:subRect context:ctx];
    } else {
        [self drawOscilloscopeInRect:subRect context:ctx];
    }

    // 4. Draw Splitter Lines & Outer Borders
    [[NSColor colorWithCalibratedRed:0.15 green:0.20 blue:0.26 alpha:1.0] setStroke];
    NSBezierPath *splitPath = [NSBezierPath bezierPath];
    [splitPath moveToPoint:NSMakePoint(mainArea.origin.x, subRect.origin.y + subRect.size.height)];
    [splitPath lineToPoint:NSMakePoint(mainArea.origin.x + mainArea.size.width, subRect.origin.y + subRect.size.height)];
    [splitPath moveToPoint:NSMakePoint(vuArea.origin.x, vuArea.origin.y)];
    [splitPath lineToPoint:NSMakePoint(vuArea.origin.x, vuArea.origin.y + vuArea.size.height)];
    splitPath.lineWidth = 1.0;
    [splitPath stroke];

    // 5. Draw Precision VU Meter
    [self drawVUMeterInRect:vuArea context:ctx];

    // Outer Bezel Border
    [[NSColor colorWithCalibratedRed:0.22 green:0.28 blue:0.35 alpha:1.0] setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:8.0 yRadius:8.0];
    border.lineWidth = 1.0;
    [border stroke];
}

- (void)drawSpectrumInRect:(NSRect)rect context:(CGContextRef)ctx {
    CGContextSaveGState(ctx);
    NSRectClip(rect);

    _cachedSpectrumRect = rect;

    CGFloat bottomY = rect.origin.y + 20.0;
    CGFloat plotHeight = rect.size.height - 26.0;
    CGFloat plotWidth = rect.size.width - 24.0;
    CGFloat startX = rect.origin.x + 16.0;
    float maxFreq = self.maxFrequencySpanHz > 0 ? self.maxFrequencySpanHz : DEFAULT_SPECTRUM_MAX_FREQ;

    // A. Draw Filter Bandpass Highlight & Interactive Handles
    if (self.filterEnabled) {
        CGFloat xLow = startX + (self.lowCutHz / maxFreq) * plotWidth;
        CGFloat xHigh = startX + (self.highCutHz / maxFreq) * plotWidth;
        xLow = fmaxf(startX, xLow);
        xHigh = fminf(startX + plotWidth, xHigh);

        if (xHigh > xLow) {
            NSRect filterBandRect = NSMakeRect(xLow, bottomY, xHigh - xLow, plotHeight);
            NSColor *bandColor = self.phosphorAmberTheme ?
                [NSColor colorWithCalibratedRed:1.0 green:0.65 blue:0.0 alpha:0.12] :
                [NSColor colorWithCalibratedRed:0.0 green:0.85 blue:0.75 alpha:0.12];
            [bandColor setFill];
            NSRectFillUsingOperation(filterBandRect, NSCompositingOperationSourceOver);

            // Filter edges vertical lines
            NSColor *edgeColor = self.phosphorAmberTheme ?
                [NSColor colorWithCalibratedRed:1.0 green:0.75 blue:0.15 alpha:0.85] :
                [NSColor colorWithCalibratedRed:0.1 green:0.95 blue:0.85 alpha:0.85];
            [edgeColor setStroke];
            NSBezierPath *edges = [NSBezierPath bezierPath];
            [edges moveToPoint:NSMakePoint(xLow, bottomY)];
            [edges lineToPoint:NSMakePoint(xLow, bottomY + plotHeight)];
            [edges moveToPoint:NSMakePoint(xHigh, bottomY)];
            [edges lineToPoint:NSMakePoint(xHigh, bottomY + plotHeight)];
            edges.lineWidth = 2.0;
            [edges stroke];

            // Visual drag grab tabs at top of filter edges
            NSRect lowHandle = NSMakeRect(xLow - 3.5, bottomY + plotHeight - 12.0, 7.0, 12.0);
            NSRect highHandle = NSMakeRect(xHigh - 3.5, bottomY + plotHeight - 12.0, 7.0, 12.0);
            [edgeColor setFill];
            [[NSBezierPath bezierPathWithRoundedRect:lowHandle xRadius:2 yRadius:2] fill];
            [[NSBezierPath bezierPathWithRoundedRect:highHandle xRadius:2 yRadius:2] fill];

            // Passband Label (Shows cutoff frequencies and bandwidth)
            NSDictionary *bandAttr = @{
                NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold],
                NSForegroundColorAttributeName: edgeColor
            };
            NSString *bandText = [NSString stringWithFormat:@"PB: %.0f-%.0f Hz (BW %.0f)", self.lowCutHz, self.highCutHz, self.highCutHz - self.lowCutHz];
            CGFloat labelY = bottomY + plotHeight - 27.0;
            CGFloat labelX = fmaxf(xLow + 6.0, startX + 6.0);
            if (labelX + 140.0 > startX + plotWidth) {
                labelX = fmaxf(startX + 6.0, startX + plotWidth - 140.0);
            }
            [bandText drawAtPoint:NSMakePoint(labelX, labelY) withAttributes:bandAttr];
        }
    }

    // B. Draw Frequency Grid & Labels
    NSMutableArray<NSNumber *> *freqGrid = [NSMutableArray array];
    if (maxFreq <= 3500.0f) {
        [freqGrid addObjectsFromArray:@[@500, @1000, @1500, @2000, @2500, @3000]];
    } else if (maxFreq <= 4500.0f) {
        [freqGrid addObjectsFromArray:@[@500, @1000, @1500, @2000, @2500, @3000, @3500]];
    } else if (maxFreq <= 8000.0f) {
        [freqGrid addObjectsFromArray:@[@1000, @2000, @3000, @4000, @5000]];
    } else {
        [freqGrid addObjectsFromArray:@[@2000, @4000, @6000, @8000, @10000]];
    }

    NSDictionary *labelAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.45 green:0.52 blue:0.62 alpha:1.0]
    };

    for (NSNumber *fNum in freqGrid) {
        float f = fNum.floatValue;
        if (f >= maxFreq) continue;
        CGFloat x = startX + (f / maxFreq) * plotWidth;

        // Vertical dotted grid line
        [[NSColor colorWithCalibratedRed:0.12 green:0.16 blue:0.22 alpha:1.0] setStroke];
        NSBezierPath *gridLine = [NSBezierPath bezierPath];
        [gridLine moveToPoint:NSMakePoint(x, bottomY)];
        [gridLine lineToPoint:NSMakePoint(x, bottomY + plotHeight)];
        CGFloat dashes[] = {2.0, 3.0};
        [gridLine setLineDash:dashes count:2 phase:0.0];
        gridLine.lineWidth = 1.0;
        [gridLine stroke];

        // Label
        NSString *lbl = f >= 1000 ? [NSString stringWithFormat:@"%.1fk", f / 1000.0] : [NSString stringWithFormat:@"%.0f", f];
        [lbl drawAtPoint:NSMakePoint(x - 10.0, rect.origin.y + 4.0) withAttributes:labelAttr];
    }

    // Title / Mode Tag
    NSDictionary *tagAttr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:10 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.55 green:0.65 blue:0.75 alpha:1.0]
    };
    NSString *titleStr = [NSString stringWithFormat:@"FFT SPECTRUM (0 - %.1f kHz)", maxFreq / 1000.0f];
    [titleStr drawAtPoint:NSMakePoint(startX, rect.origin.y + rect.size.height - 18.0) withAttributes:tagAttr];

    // C. Draw Notch Filter Marker if active
    if (self.notchEnabled && self.notchFreqHz > 50.0f && self.notchFreqHz < maxFreq) {
        CGFloat xNotch = startX + (self.notchFreqHz / maxFreq) * plotWidth;
        [[NSColor systemRedColor] setStroke];
        NSBezierPath *notchLine = [NSBezierPath bezierPath];
        [notchLine moveToPoint:NSMakePoint(xNotch, bottomY)];
        [notchLine lineToPoint:NSMakePoint(xNotch, bottomY + plotHeight)];
        CGFloat nDashes[] = {4.0, 2.0};
        [notchLine setLineDash:nDashes count:2 phase:0.0];
        notchLine.lineWidth = 1.5;
        [notchLine stroke];

        NSDictionary *notchAttr = @{
            NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: [NSColor systemRedColor]
        };
        [[NSString stringWithFormat:@"▼ NOTCH %.0fHz", self.notchFreqHz]
            drawAtPoint:NSMakePoint(fminf(xNotch - 24.0, rect.origin.x + rect.size.width - 90.0), bottomY + plotHeight - 14.0)
         withAttributes:notchAttr];
    }

    // D. Draw Real-Time Spectrum Curve
    if (_binCount > 2) {
        NSBezierPath *curve = [NSBezierPath bezierPath];
        [curve moveToPoint:NSMakePoint(startX, bottomY)];

        float nyquist = _sampleRate * 0.5f;

        for (NSInteger xPix = 0; xPix <= (NSInteger)plotWidth; xPix += 2) {
            float freq = ((float)xPix / plotWidth) * maxFreq;
            float binPos = (freq / nyquist) * (float)_binCount;
            NSInteger binIdx = (NSInteger)binPos;

            float mag = 0.0f;
            if (binIdx >= 0 && binIdx < _binCount) {
                mag = _spectrumBins[binIdx];
            }

            float db = mag > 1e-5f ? 20.0f * log10f(mag) + self.spectrumGainDb : -80.0f;
            float norm = (db + 80.0f) / 80.0f;
            if (norm < 0.0f) norm = 0.0f;
            if (norm > 1.0f) norm = 1.0f;

            CGFloat x = startX + xPix;
            CGFloat y = bottomY + norm * plotHeight;
            [curve lineToPoint:NSMakePoint(x, y)];
        }

        // Close path for gradient fill
        NSBezierPath *fillPath = [curve copy];
        [fillPath lineToPoint:NSMakePoint(startX + plotWidth, bottomY)];
        [fillPath closePath];

        // Gradient Fill
        NSColor *gradTop = self.phosphorAmberTheme ?
            [NSColor colorWithCalibratedRed:1.0 green:0.75 blue:0.1 alpha:0.35] :
            [NSColor colorWithCalibratedRed:0.0 green:0.90 blue:0.85 alpha:0.30];
        NSColor *gradBottom = [gradTop colorWithAlphaComponent:0.02];
        NSGradient *gradient = [[NSGradient alloc] initWithStartingColor:gradBottom endingColor:gradTop];
        [gradient drawInBezierPath:fillPath angle:90.0];

        // Stroke neon line
        NSColor *strokeColor = self.phosphorAmberTheme ?
            [NSColor colorWithCalibratedRed:1.0 green:0.85 blue:0.2 alpha:1.0] :
            [NSColor colorWithCalibratedRed:0.1 green:1.0 blue:0.85 alpha:1.0];
        [strokeColor setStroke];
        curve.lineWidth = 1.5;
        curve.lineJoinStyle = NSLineJoinStyleRound;
        [curve stroke];
    }

    CGContextRestoreGState(ctx);
}

- (void)drawWaterfallInRect:(NSRect)rect context:(CGContextRef)ctx {
    CGContextSaveGState(ctx);
    NSRectClip(rect);

    CGFloat startX = rect.origin.x + 16.0;
    CGFloat plotWidth = rect.size.width - 24.0;
    CGFloat bottomY = rect.origin.y + 4.0;
    CGFloat plotHeight = rect.size.height - 18.0;
    NSRect wfRect = NSMakeRect(startX, bottomY, plotWidth, plotHeight);

    // Draw Waterfall Bitmap
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmapCtx = CGBitmapContextCreate(_waterfallPixels, WATERFALL_WIDTH, WATERFALL_HEIGHT, 8, WATERFALL_WIDTH * 4, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (bitmapCtx) {
        CGImageRef img = CGBitmapContextCreateImage(bitmapCtx);
        if (img) {
            CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
            CGContextDrawImage(ctx, wfRect, img);
            CGImageRelease(img);
        }
        CGContextRelease(bitmapCtx);
    }
    CGColorSpaceRelease(colorSpace);

    // Waterfall Label
    NSDictionary *tagAttr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.45 green:0.55 blue:0.65 alpha:1.0]
    };
    [@"LIVE WATERFALL (SPECTROGRAM)" drawAtPoint:NSMakePoint(startX, rect.origin.y + rect.size.height - 14.0) withAttributes:tagAttr];

    CGContextRestoreGState(ctx);
}

- (void)drawOscilloscopeInRect:(NSRect)rect context:(CGContextRef)ctx {
    CGContextSaveGState(ctx);
    NSRectClip(rect);

    CGFloat startX = rect.origin.x + 16.0;
    CGFloat plotWidth = rect.size.width - 24.0;
    CGFloat centerY = rect.origin.y + rect.size.height * 0.5f;
    CGFloat halfAmp = rect.size.height * 0.42f;

    // Center Baseline
    [[NSColor colorWithCalibratedRed:0.12 green:0.16 blue:0.22 alpha:1.0] setStroke];
    NSBezierPath *centerLine = [NSBezierPath bezierPath];
    [centerLine moveToPoint:NSMakePoint(startX, centerY)];
    [centerLine lineToPoint:NSMakePoint(startX + plotWidth, centerY)];
    CGFloat cDashes[] = {3.0, 3.0};
    [centerLine setLineDash:cDashes count:2 phase:0.0];
    centerLine.lineWidth = 1.0;
    [centerLine stroke];

    // Oscilloscope Title
    NSDictionary *tagAttr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:9 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.45 green:0.55 blue:0.65 alpha:1.0]
    };
    [@"LIVE OSCILLOSCOPE" drawAtPoint:NSMakePoint(startX, rect.origin.y + rect.size.height - 14.0) withAttributes:tagAttr];

    // Waveform Path
    if (_waveformCount > 1) {
        NSBezierPath *wave = [NSBezierPath bezierPath];
        for (NSInteger i = 0; i < _waveformCount; i++) {
            CGFloat x = startX + ((CGFloat)i / (CGFloat)(_waveformCount - 1)) * plotWidth;
            CGFloat y = centerY + _waveformSamples[i] * halfAmp;
            if (i == 0) [wave moveToPoint:NSMakePoint(x, y)];
            else [wave lineToPoint:NSMakePoint(x, y)];
        }

        // Phosphor glow stroke
        NSColor *glowColor = self.phosphorAmberTheme ?
            [NSColor colorWithCalibratedRed:1.0 green:0.7 blue:0.0 alpha:0.4] :
            [NSColor colorWithCalibratedRed:0.1 green:1.0 blue:0.5 alpha:0.4];
        [glowColor setStroke];
        wave.lineWidth = 3.0;
        wave.lineJoinStyle = NSLineJoinStyleRound;
        [wave stroke];

        NSColor *coreColor = self.phosphorAmberTheme ?
            [NSColor colorWithCalibratedRed:1.0 green:0.95 blue:0.4 alpha:1.0] :
            [NSColor colorWithCalibratedRed:0.5 green:1.0 blue:0.7 alpha:1.0];
        [coreColor setStroke];
        wave.lineWidth = 1.2;
        [wave stroke];
    }

    CGContextRestoreGState(ctx);
}

- (void)drawVUMeterInRect:(NSRect)rect context:(CGContextRef)ctx {
    CGContextSaveGState(ctx);
    NSRectClip(rect);

    CGFloat meterTop = rect.origin.y + rect.size.height - 30.0;
    CGFloat meterBottom = rect.origin.y + 24.0;
    CGFloat meterHeight = meterTop - meterBottom;
    CGFloat barWidth = 9.0;
    CGFloat spacing = 4.0;
    CGFloat leftX = rect.origin.x + (rect.size.width - (2 * barWidth + spacing)) * 0.5;
    CGFloat rightX = leftX + barWidth + spacing;

    // Header Label
    NSDictionary *hdrAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.6 green:0.7 blue:0.8 alpha:1.0]
    };
    [@"VU (dB)" drawAtPoint:NSMakePoint(rect.origin.x + (rect.size.width - 42.0) * 0.5, rect.origin.y + rect.size.height - 16.0) withAttributes:hdrAttr];

    // Segments: 24 LED blocks
    NSInteger numSegments = 24;
    CGFloat segHeight = (meterHeight - (numSegments - 1) * 2.0) / (CGFloat)numSegments;

    // Values: -60 dB to 0 dBFS
    float leftNorm = (_smoothedLeftRmsDb + 60.0f) / 60.0f;
    float rightNorm = (_smoothedRightRmsDb + 60.0f) / 60.0f;
    leftNorm = fmaxf(0.0f, fminf(1.0f, leftNorm));
    rightNorm = fmaxf(0.0f, fminf(1.0f, rightNorm));

    for (NSInteger seg = 0; seg < numSegments; seg++) {
        CGFloat y = meterBottom + seg * (segHeight + 2.0);
        float segFrac = (float)seg / (float)(numSegments - 1);

        NSColor *litColor;
        NSColor *unlitColor;

        if (segFrac >= 0.85f) {
            litColor = [NSColor colorWithCalibratedRed:1.0 green:0.25 blue:0.2 alpha:1.0];
            unlitColor = [NSColor colorWithCalibratedRed:0.3 green:0.1 blue:0.1 alpha:0.4];
        } else if (segFrac >= 0.65f) {
            litColor = [NSColor colorWithCalibratedRed:1.0 green:0.8 blue:0.1 alpha:1.0];
            unlitColor = [NSColor colorWithCalibratedRed:0.3 green:0.25 blue:0.05 alpha:0.4];
        } else {
            litColor = self.phosphorAmberTheme ?
                [NSColor colorWithCalibratedRed:0.95 green:0.65 blue:0.1 alpha:1.0] :
                [NSColor colorWithCalibratedRed:0.1 green:0.85 blue:0.45 alpha:1.0];
            unlitColor = [NSColor colorWithCalibratedRed:0.08 green:0.18 blue:0.14 alpha:0.4];
        }

        // Left Channel Segment
        NSRect lRect = NSMakeRect(leftX, y, barWidth, segHeight);
        BOOL lLit = (segFrac <= leftNorm);
        [(lLit ? litColor : unlitColor) setFill];
        NSRectFill(lRect);

        // Right Channel Segment
        NSRect rRect = NSMakeRect(rightX, y, barWidth, segHeight);
        BOOL rLit = (segFrac <= rightNorm);
        [(rLit ? litColor : unlitColor) setFill];
        NSRectFill(rRect);
    }

    // Channel Labels L and R
    NSDictionary *chanAttr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:8 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.5 green:0.6 blue:0.7 alpha:1.0]
    };
    [@"L" drawAtPoint:NSMakePoint(leftX + 1.0, meterBottom - 11.0) withAttributes:chanAttr];
    [@"R" drawAtPoint:NSMakePoint(rightX + 1.0, meterBottom - 11.0) withAttributes:chanAttr];

    // Numeric Peak Value
    NSDictionary *numAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: self.isClipping ? [NSColor systemRedColor] : [NSColor colorWithCalibratedRed:0.7 green:0.8 blue:0.9 alpha:1.0]
    };
    NSString *peakStr = _peakHoldDb > -80.0f ? [NSString stringWithFormat:@"%4.1f", _peakHoldDb] : @"--.-";
    [peakStr drawAtPoint:NSMakePoint(rect.origin.x + (rect.size.width - 28.0) * 0.5, meterBottom - 21.0) withAttributes:numAttr];

    // Peak Hold Tick Line
    float peakNorm = (_peakHoldDb + 60.0f) / 60.0f;
    if (peakNorm > 0.05f) {
        if (peakNorm > 1.0f) peakNorm = 1.0f;
        CGFloat peakY = meterBottom + peakNorm * meterHeight;
        [[NSColor colorWithCalibratedRed:1.0 green:0.95 blue:0.4 alpha:0.95] setStroke];
        NSBezierPath *peakTick = [NSBezierPath bezierPath];
        [peakTick moveToPoint:NSMakePoint(leftX - 1.0, peakY)];
        [peakTick lineToPoint:NSMakePoint(leftX + barWidth + 1.0, peakY)];
        [peakTick moveToPoint:NSMakePoint(rightX - 1.0, peakY)];
        [peakTick lineToPoint:NSMakePoint(rightX + barWidth + 1.0, peakY)];
        peakTick.lineWidth = 2.0;
        [peakTick stroke];
    }

    // Prominent CLIP Overload Alert Badge (1.5s persistent hold)
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (self.isClipping || self.peakDb >= -0.5f) {
        _clipHoldUntil = now + 1.5;
    }
    BOOL isClipActive = self.isClipping || (now < _clipHoldUntil);

    NSRect clipBadgeRect = NSMakeRect(rect.origin.x + (rect.size.width - 46.0) * 0.5, rect.origin.y + rect.size.height - 30.0, 46.0, 13.0);
    NSColor *clipBg = isClipActive ?
        [NSColor colorWithCalibratedRed:0.95 green:0.12 blue:0.12 alpha:0.95] :
        [NSColor colorWithCalibratedRed:0.20 green:0.06 blue:0.06 alpha:0.35];
    NSColor *clipFg = isClipActive ?
        [NSColor whiteColor] :
        [NSColor colorWithCalibratedRed:0.45 green:0.20 blue:0.20 alpha:0.5];
    [clipBg setFill];
    [[NSBezierPath bezierPathWithRoundedRect:clipBadgeRect xRadius:3.0 yRadius:3.0] fill];

    NSDictionary *clipAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightHeavy],
        NSForegroundColorAttributeName: clipFg
    };
    [@"CLIP" drawAtPoint:NSMakePoint(clipBadgeRect.origin.x + 11.0, clipBadgeRect.origin.y + 1.0) withAttributes:clipAttr];

    CGContextRestoreGState(ctx);
}

#pragma mark - Mouse Interaction (Filter Passband Dragging & Click-to-Notch)

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:(NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingCursorUpdate)
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)updateCursorForPoint:(NSPoint)pt {
    NSRect specRect = _cachedSpectrumRect;
    CGFloat startX = specRect.origin.x + 16.0;
    CGFloat plotWidth = specRect.size.width - 24.0;
    CGFloat bottomY = specRect.origin.y + 20.0;
    CGFloat plotHeight = specRect.size.height - 26.0;
    float maxFreq = self.maxFrequencySpanHz > 0 ? self.maxFrequencySpanHz : DEFAULT_SPECTRUM_MAX_FREQ;

    if (pt.y >= bottomY && pt.y <= bottomY + plotHeight && pt.x >= startX && pt.x <= startX + plotWidth) {
        CGFloat xLow = startX + (self.lowCutHz / maxFreq) * plotWidth;
        CGFloat xHigh = startX + (self.highCutHz / maxFreq) * plotWidth;
        CGFloat xNotch = self.notchEnabled ? (startX + (self.notchFreqHz / maxFreq) * plotWidth) : -999.0;

        if (self.filterEnabled && (fabs(pt.x - xLow) <= 7.0 || fabs(pt.x - xHigh) <= 7.0)) {
            [[NSCursor resizeLeftRightCursor] set];
            return;
        }
        if (self.notchEnabled && fabs(pt.x - xNotch) <= 7.0) {
            [[NSCursor resizeLeftRightCursor] set];
            return;
        }
        if (self.filterEnabled && pt.x > xLow + 7.0 && pt.x < xHigh - 7.0) {
            [[NSCursor openHandCursor] set];
            return;
        }
        [[NSCursor crosshairCursor] set];
        return;
    }
    [[NSCursor arrowCursor] set];
}

- (void)cursorUpdate:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    [self updateCursorForPoint:pt];
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    [self updateCursorForPoint:pt];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect specRect = _cachedSpectrumRect;
    CGFloat startX = specRect.origin.x + 16.0;
    CGFloat plotWidth = specRect.size.width - 24.0;
    CGFloat bottomY = specRect.origin.y + 20.0;
    CGFloat plotHeight = specRect.size.height - 26.0;
    float maxFreq = self.maxFrequencySpanHz > 0 ? self.maxFrequencySpanHz : DEFAULT_SPECTRUM_MAX_FREQ;

    if (pt.y >= bottomY && pt.y <= bottomY + plotHeight && pt.x >= startX && pt.x <= startX + plotWidth) {
        CGFloat xLow = startX + (self.lowCutHz / maxFreq) * plotWidth;
        CGFloat xHigh = startX + (self.highCutHz / maxFreq) * plotWidth;
        CGFloat xNotch = self.notchEnabled ? (startX + (self.notchFreqHz / maxFreq) * plotWidth) : -999.0;

        _dragStartPoint = pt;
        _dragInitialLowCut = self.lowCutHz;
        _dragInitialHighCut = self.highCutHz;
        _dragInitialNotchFreq = self.notchFreqHz;

        if (self.filterEnabled && fabs(pt.x - xLow) <= 7.0) {
            _activeDragMode = 1; // Low Cut
            [[NSCursor resizeLeftRightCursor] set];
            return;
        }
        if (self.filterEnabled && fabs(pt.x - xHigh) <= 7.0) {
            _activeDragMode = 2; // High Cut
            [[NSCursor resizeLeftRightCursor] set];
            return;
        }
        if (self.notchEnabled && fabs(pt.x - xNotch) <= 7.0) {
            _activeDragMode = 4; // Notch
            [[NSCursor resizeLeftRightCursor] set];
            return;
        }
        if (self.filterEnabled && pt.x > xLow + 7.0 && pt.x < xHigh - 7.0 && !(event.modifierFlags & NSEventModifierFlagOption)) {
            _activeDragMode = 3; // Passband move
            [[NSCursor closedHandCursor] set];
            return;
        }

        // Click-to-Notch!
        // When clicking anywhere on the spectrum or with Option key held:
        float clickedFreq = ((pt.x - startX) / plotWidth) * maxFreq;
        clickedFreq = fmaxf(100.0f, fminf(maxFreq - 50.0f, clickedFreq));
        self.notchFreqHz = roundf(clickedFreq);
        self.notchEnabled = YES;
        if (self.onNotchFrequencyChanged) {
            self.onNotchFrequencyChanged(self.notchFreqHz);
        }
        [self setNeedsDisplay:YES];
        return;
    }
    [super mouseDown:event];
}

- (void)mouseDragged:(NSEvent *)event {
    if (_activeDragMode == 0) {
        [super mouseDragged:event];
        return;
    }
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    NSRect specRect = _cachedSpectrumRect;
    CGFloat plotWidth = specRect.size.width - 24.0;
    float maxFreq = self.maxFrequencySpanHz > 0 ? self.maxFrequencySpanHz : DEFAULT_SPECTRUM_MAX_FREQ;
    float hzPerPixel = maxFreq / plotWidth;
    float deltaHz = (pt.x - _dragStartPoint.x) * hzPerPixel;

    if (_activeDragMode == 1) { // Low Cut
        float newLow = _dragInitialLowCut + deltaHz;
        newLow = fmaxf(50.0f, fminf(self.highCutHz - 100.0f, newLow));
        self.lowCutHz = roundf(newLow);
        if (self.onFilterRangeChanged) {
            self.onFilterRangeChanged(self.lowCutHz, self.highCutHz);
        }
        [self setNeedsDisplay:YES];
    } else if (_activeDragMode == 2) { // High Cut
        float newHigh = _dragInitialHighCut + deltaHz;
        newHigh = fmaxf(self.lowCutHz + 100.0f, fminf(maxFreq, newHigh));
        self.highCutHz = roundf(newHigh);
        if (self.onFilterRangeChanged) {
            self.onFilterRangeChanged(self.lowCutHz, self.highCutHz);
        }
        [self setNeedsDisplay:YES];
    } else if (_activeDragMode == 3) { // Passband Shift
        float bw = _dragInitialHighCut - _dragInitialLowCut;
        float newLow = _dragInitialLowCut + deltaHz;
        if (newLow < 50.0f) newLow = 50.0f;
        if (newLow + bw > maxFreq) newLow = maxFreq - bw;
        self.lowCutHz = roundf(newLow);
        self.highCutHz = roundf(newLow + bw);
        if (self.onFilterRangeChanged) {
            self.onFilterRangeChanged(self.lowCutHz, self.highCutHz);
        }
        [self setNeedsDisplay:YES];
    } else if (_activeDragMode == 4) { // Notch Drag
        float newNotch = _dragInitialNotchFreq + deltaHz;
        newNotch = fmaxf(100.0f, fminf(maxFreq - 50.0f, newNotch));
        self.notchFreqHz = roundf(newNotch);
        if (self.onNotchFrequencyChanged) {
            self.onNotchFrequencyChanged(self.notchFreqHz);
        }
        [self setNeedsDisplay:YES];
    }
}

- (void)mouseUp:(NSEvent *)event {
    _activeDragMode = 0;
    NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
    [self updateCursorForPoint:pt];
    [super mouseUp:event];
}

@end
