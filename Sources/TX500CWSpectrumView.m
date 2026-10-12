//
//  TX500CWSpectrumView.m
//  Lab599 Utility
//
//  Real-Time Audio Spectrum Scope & 2D Scrolling Waterfall for CW Station
//  Wideband 300 - 3000 Hz coverage with click-to-tune and carrier annotations
//

#import "TX500CWSpectrumView.h"

#define TX500_WF_WIDTH 640
#define TX500_WF_HEIGHT 160

@interface TX500CWSpectrumView () {
    uint32_t _waterfallPixels[TX500_WF_HEIGHT][TX500_WF_WIDTH];
    float _smoothedNoiseFloor;
    NSPoint _hoverPoint;
    BOOL _isHovering;
    NSTrackingArea *_trackingArea;
}
@end

@implementation TX500CWSpectrumView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _bins = @[];
        _nominalPitchHz = 650.0;
        _centerFrequencyHz = 650.0;
        _minDisplayFreqHz = 300.0;
        _maxDisplayFreqHz = 3000.0;
        _detectedCarrierFrequencies = @[];
        _hoverPoint = NSZeroPoint;
        _isHovering = NO;
        _smoothedNoiseFloor = 0.001f;

        memset(_waterfallPixels, 0, sizeof(_waterfallPixels));

        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.04 alpha:1.0].CGColor;
        self.layer.cornerRadius = 6.0;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:(NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInKeyWindow)
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)clearWaterfall {
    memset(_waterfallPixels, 0, sizeof(_waterfallPixels));
    _smoothedNoiseFloor = 0.001f;
    [self setNeedsDisplay:YES];
}

static inline float EstimateNoiseFloor(NSArray<TX500CWSpectrumBin *> *bins) {
    if (bins.count == 0) return 0.002f;
    NSUInteger count = bins.count;
    if (count > 256) count = 256;
    float mags[256];
    for (NSUInteger i = 0; i < count; i++) {
        mags[i] = bins[i].magnitude;
    }
    for (NSUInteger i = 1; i < count; i++) {
        float key = mags[i];
        NSInteger j = (NSInteger)i - 1;
        while (j >= 0 && mags[j] > key) {
            mags[j + 1] = mags[j];
            j--;
        }
        mags[j + 1] = key;
    }
    // 20th percentile accurately captures the receiver thermal noise floor
    NSUInteger p20 = count / 5;
    return fmaxf(0.0001f, mags[p20]);
}

static inline uint32_t WaterfallColorForMagnitude(float mag, float noiseFloor) {
    if (noiseFloor <= 0.000001f) noiseFloor = 0.001f;
    float snrLin = mag / noiseFloor;
    float snrDb = (snrLin > 1.0f) ? (20.0f * log10f(snrLin)) : 0.0f;

    // Ultra-High-Contrast SDR Colormap specifically tuned for CW Morse code:
    // <= 3.0 dB : Pure deep space background (#030612) - complete noise gating
    // 3.0 - 7.5 dB : Electric cobalt blue to brilliant cyan (#0040b0 -> #00d9ff)
    // 7.5 - 14.0 dB: Vivid laser neon green (#00ff66)
    // 14.0 - 22.0 dB: Brilliant radiant amber-gold (#ffea00)
    // 22.0 - 30.0 dB: Blazing hot coral-orange (#ff4500)
    // > 30.0 dB : Superheated glowing white core (#ffffff)
    uint8_t r = 3, g = 6, b = 18;
    if (snrDb <= 3.0f) {
        float t = fmaxf(0.0f, snrDb / 3.0f);
        r = (uint8_t)(3.0f + 2.0f * t);
        g = (uint8_t)(6.0f + 4.0f * t);
        b = (uint8_t)(18.0f + 14.0f * t);
    } else if (snrDb < 7.5f) {
        float t = (snrDb - 3.0f) / 4.5f;
        r = 0;
        g = (uint8_t)(50.0f + 140.0f * t);
        b = (uint8_t)(180.0f + 75.0f * t);
    } else if (snrDb < 14.0f) {
        float t = (snrDb - 7.5f) / 6.5f;
        r = (uint8_t)(20.0f * t);
        g = (uint8_t)(190.0f + 65.0f * t);
        b = (uint8_t)(255.0f * (1.0f - t));
    } else if (snrDb < 22.0f) {
        float t = (snrDb - 14.0f) / 8.0f;
        r = (uint8_t)(20.0f + 235.0f * t);
        g = (uint8_t)(255.0f - 20.0f * t);
        b = 0;
    } else if (snrDb < 30.0f) {
        float t = (snrDb - 22.0f) / 8.0f;
        r = 255;
        g = (uint8_t)(235.0f * (1.0f - t * 0.45f));
        b = (uint8_t)(90.0f * t);
    } else {
        float t = fminf(1.0f, (snrDb - 30.0f) / 10.0f);
        r = 255;
        g = (uint8_t)(170.0f + 85.0f * t);
        b = (uint8_t)(90.0f + 165.0f * t);
    }
    // CoreGraphics kCGBitmapByteOrder32Big memory layout: [R, G, B, A]
    return ((uint32_t)r) | ((uint32_t)g << 8) | ((uint32_t)b << 16) | (0xFF000000U);
}

- (void)updateWithBins:(NSArray<TX500CWSpectrumBin *> *)bins
             centerFreq:(double)centerFreq
            nominalPitch:(double)pitch
                   level:(float)level
                   snrDb:(double)snr
          signalDetected:(BOOL)detected {
    [self updateWithBins:bins
              centerFreq:centerFreq
             nominalPitch:pitch
                    level:level
                    snrDb:snr
           signalDetected:detected
         detectedCarriers:nil];
}

- (void)updateWithBins:(NSArray<TX500CWSpectrumBin *> *)bins
             centerFreq:(double)centerFreq
            nominalPitch:(double)pitch
                   level:(float)level
                   snrDb:(double)snr
          signalDetected:(BOOL)detected
        detectedCarriers:(nullable NSArray<NSNumber *> *)carriers {
    self.bins = bins ?: @[];
    self.centerFrequencyHz = centerFreq;
    self.nominalPitchHz = pitch;
    self.audioLevel = level;
    self.snrDb = snr;
    self.isSignalDetected = detected;
    if (carriers) {
        self.detectedCarrierFrequencies = carriers;
    }

    // Push new line to scrolling waterfall
    if (bins.count > 0) {
        // Shift history down by 1 row
        memmove(&_waterfallPixels[1][0], &_waterfallPixels[0][0], (TX500_WF_HEIGHT - 1) * TX500_WF_WIDTH * sizeof(uint32_t));

        // Generate top row (row 0)
        double minF = self.minDisplayFreqHz > 0 ? self.minDisplayFreqHz : 300.0;
        double maxF = self.maxDisplayFreqHz > minF ? self.maxDisplayFreqHz : 3000.0;
        double rangeF = maxF - minF;

        NSUInteger binCount = bins.count;
        double binMinF = bins.firstObject.frequencyHz;
        double binMaxF = bins.lastObject.frequencyHz;
        double binSpan = (binMaxF > binMinF) ? (binMaxF - binMinF) : rangeF;

        // Exponential Moving Average of noise floor stabilizes background contrast
        float rawNoise = EstimateNoiseFloor(bins);
        if (_smoothedNoiseFloor <= 1e-6f) {
            _smoothedNoiseFloor = rawNoise;
        } else {
            _smoothedNoiseFloor = _smoothedNoiseFloor * 0.90f + rawNoise * 0.10f;
        }
        float noiseFloor = _smoothedNoiseFloor;

        for (int x = 0; x < TX500_WF_WIDTH; x++) {
            double targetFreq = minF + ((double)x / (double)(TX500_WF_WIDTH - 1)) * rangeF;
            float mag = 0.0f;

            if (binSpan > 0 && targetFreq >= binMinF && targetFreq <= binMaxF) {
                double rel = (targetFreq - binMinF) / binSpan * (double)(binCount - 1);
                NSInteger idx = (NSInteger)floor(rel);
                if (idx < 0) idx = 0;
                if (idx >= (NSInteger)binCount - 1) {
                    mag = bins[binCount - 1].magnitude;
                } else {
                    double frac = rel - (double)idx;
                    float m0 = bins[idx].magnitude;
                    float m1 = bins[idx + 1].magnitude;
                    mag = (float)((1.0 - frac) * m0 + frac * m1);
                }
            }

            // Non-linear power sharpening:
            // Collapses wide window skirts down to razor-sharp Morse strokes
            float snrLin = (noiseFloor > 1e-6f) ? (mag / noiseFloor) : 1.0f;
            if (snrLin > 1.35f) {
                float excess = snrLin - 1.35f;
                float sharpenedExcess = powf(excess, 1.45f);
                mag = (1.35f + sharpenedExcess) * noiseFloor;
            }

            // Carrier focus: if targetFreq is within 12 Hz of any detected active carrier, focus and enhance it
            for (NSNumber *carrierNum in self.detectedCarrierFrequencies) {
                double cFreq = carrierNum.doubleValue;
                double dist = fabs(targetFreq - cFreq);
                if (dist <= 12.0) {
                    float boost = 1.0f + 0.55f * expf(-0.5f * (float)(dist * dist) / 16.0f);
                    mag *= boost;
                    break;
                }
            }

            _waterfallPixels[0][x] = WaterfallColorForMagnitude(mag, noiseFloor);
        }
    }

    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) return;

    NSRect bounds = self.bounds;
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;
    if (width <= 10 || height <= 20) return;

    CGFloat headerH = 16.0;
    CGFloat footerH = 16.0;
    CGFloat availableH = height - headerH - footerH;
    CGFloat scopeH = fmax(24.0, availableH * 0.28);
    CGFloat wfH = availableH - scopeH;

    double minF = self.minDisplayFreqHz > 0 ? self.minDisplayFreqHz : 300.0;
    double maxF = self.maxDisplayFreqHz > minF ? self.maxDisplayFreqHz : 3000.0;
    double rangeF = maxF - minF;

    // 1. Draw 2D Scrolling Waterfall Bitmap with Nearest-Neighbor rendering (ZERO BLUR)
    CGRect wfRect = CGRectMake(0, footerH, width, wfH);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmapCtx = CGBitmapContextCreate(_waterfallPixels,
                                                   TX500_WF_WIDTH,
                                                   TX500_WF_HEIGHT,
                                                   8,
                                                   TX500_WF_WIDTH * 4,
                                                   colorSpace,
                                                   kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef wfImage = CGBitmapContextCreateImage(bitmapCtx);
    if (wfImage) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationNone); // Razor-sharp Morse pixels!
        CGContextDrawImage(ctx, wfRect, wfImage);
        CGImageRelease(wfImage);
    }
    CGContextRelease(bitmapCtx);
    CGColorSpaceRelease(colorSpace);

    // 2. Scope Background & Separator
    CGFloat scopeY = footerH + wfH;
    CGContextSetFillColorWithColor(ctx, [NSColor colorWithCalibratedWhite:0.035 alpha:0.9].CGColor);
    CGContextFillRect(ctx, CGRectMake(0, scopeY, width, scopeH));

    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithCalibratedWhite:0.3 alpha:0.85].CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextMoveToPoint(ctx, 0, scopeY);
    CGContextAddLineToPoint(ctx, width, scopeY);
    CGContextStrokePath(ctx);

    // 3. Grid Lines across Waterfall & Scope (Every 250 Hz)
    NSDictionary *rulerAttr = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.0 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.6 alpha:1.0]
    };

    double gridFreqs[] = { 500.0, 750.0, 1000.0, 1250.0, 1500.0, 1750.0, 2000.0, 2250.0, 2500.0, 2750.0, 3000.0 };
    for (int i = 0; i < 11; i++) {
        double f = gridFreqs[i];
        if (f < minF || f > maxF) continue;
        CGFloat x = (CGFloat)((f - minF) / rangeF) * width;

        // Grid line through waterfall
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithCalibratedWhite:0.35 alpha:0.25].CGColor);
        CGContextMoveToPoint(ctx, x, footerH);
        CGContextAddLineToPoint(ctx, x, height - headerH);
        CGContextStrokePath(ctx);

        // Ruler label in footer
        NSString *lbl = [NSString stringWithFormat:@"%d", (int)f];
        [lbl drawAtPoint:NSMakePoint(fmax(2.0, x - 12.0), 2) withAttributes:rulerAttr];
    }

    // 4. Instantaneous Energy Scope Curve & Area Fill
    if (self.bins.count > 0) {
        CGMutablePathRef strokePath = CGPathCreateMutable();
        CGMutablePathRef fillPath = CGPathCreateMutable();
        CGPathMoveToPoint(fillPath, NULL, 0, scopeY);

        BOOL started = NO;
        CGFloat lastX = 0;
        for (NSUInteger b = 0; b < self.bins.count; b++) {
            TX500CWSpectrumBin *bin = self.bins[b];
            if (bin.frequencyHz < minF || bin.frequencyHz > maxF) continue;
            CGFloat x = (CGFloat)((bin.frequencyHz - minF) / rangeF) * width;
            CGFloat magHeight = fmin(scopeH - 4.0, (CGFloat)(bin.magnitude * 2400.0));
            CGFloat y = scopeY + magHeight;

            if (!started) {
                CGPathMoveToPoint(strokePath, NULL, x, y);
                CGPathAddLineToPoint(fillPath, NULL, x, y);
                started = YES;
            } else {
                CGPathAddLineToPoint(strokePath, NULL, x, y);
                CGPathAddLineToPoint(fillPath, NULL, x, y);
            }
            lastX = x;
        }

        if (started) {
            CGPathAddLineToPoint(fillPath, NULL, lastX, scopeY);
            CGPathCloseSubpath(fillPath);

            // Translucent gradient fill under curve
            CGContextSaveGState(ctx);
            CGContextAddPath(ctx, fillPath);
            CGContextClip(ctx);

            CGColorSpaceRef rgbSpace = CGColorSpaceCreateDeviceRGB();
            CGFloat comp[8] = {
                0.0, 0.75, 1.0, 0.35,   // Top: Electric cyan
                0.02, 0.08, 0.18, 0.05  // Bottom: Dark navy
            };
            CGGradientRef grad = CGGradientCreateWithColorComponents(rgbSpace, comp, NULL, 2);
            CGContextDrawLinearGradient(ctx, grad, CGPointMake(0, scopeY + scopeH), CGPointMake(0, scopeY), 0);
            CGGradientRelease(grad);
            CGColorSpaceRelease(rgbSpace);
            CGContextRestoreGState(ctx);

            // Glowing curve stroke
            CGContextSetLineWidth(ctx, 1.8);
            CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithSRGBRed:0.2 green:0.88 blue:1.0 alpha:0.95].CGColor);
            CGContextAddPath(ctx, strokePath);
            CGContextStrokePath(ctx);
        }
        CGPathRelease(strokePath);
        CGPathRelease(fillPath);
    }

    // 5. Detected Multi-Carrier Annotations (Badges, Markers & Guidelines)
    NSDictionary *carrierTagAttr = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.85 blue:0.2 alpha:1.0]
    };
    for (NSNumber *carrierNum in self.detectedCarrierFrequencies) {
        double cFreq = carrierNum.doubleValue;
        if (cFreq >= minF && cFreq <= maxF) {
            CGFloat cx = (CGFloat)((cFreq - minF) / rangeF) * width;

            // Glowing vertical guideline down waterfall
            CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithSRGBRed:1.0 green:0.8 blue:0.15 alpha:0.4].CGColor);
            CGContextSetLineWidth(ctx, 1.0);
            CGFloat cDash[] = { 3.0, 2.0 };
            CGContextSetLineDash(ctx, 0, cDash, 2);
            CGContextMoveToPoint(ctx, cx, footerH);
            CGContextAddLineToPoint(ctx, cx, scopeY);
            CGContextStrokePath(ctx);
            CGContextSetLineDash(ctx, 0, NULL, 0);

            // Pip marker in scope & active keying beacon down waterfall
            BOOL isActiveCarrier = self.isSignalDetected && (fabs(self.centerFrequencyHz - cFreq) < 30.0);
            if (isActiveCarrier) {
                // Pulsing neon green pip
                CGContextSetFillColorWithColor(ctx, [NSColor colorWithSRGBRed:0.2 green:1.0 blue:0.4 alpha:0.95].CGColor);
                CGContextFillEllipseInRect(ctx, CGRectMake(cx - 4, scopeY + scopeH - 12, 8, 8));

                // Active keying beacon beam down waterfall
                CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithSRGBRed:0.2 green:1.0 blue:0.4 alpha:0.4].CGColor);
                CGContextSetLineWidth(ctx, 1.5);
                CGContextMoveToPoint(ctx, cx, footerH);
                CGContextAddLineToPoint(ctx, cx, scopeY);
                CGContextStrokePath(ctx);
            } else {
                CGContextSetFillColorWithColor(ctx, [NSColor colorWithSRGBRed:1.0 green:0.82 blue:0.1 alpha:0.95].CGColor);
                CGContextFillEllipseInRect(ctx, CGRectMake(cx - 3, scopeY + scopeH - 10, 6, 6));
            }

            // Frequency badge tag: ▲ 780Hz or ⚡780Hz
            NSString *cBadge = isActiveCarrier ?
                [NSString stringWithFormat:@"⚡%.0f", cFreq] :
                [NSString stringWithFormat:@"▲%.0f", cFreq];
            NSDictionary *activeTagAttr = isActiveCarrier ? @{
                NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightBold],
                NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:0.2 green:1.0 blue:0.4 alpha:1.0]
            } : carrierTagAttr;
            [cBadge drawAtPoint:NSMakePoint(fmax(4.0, fmin(width - 38.0, cx - 14.0)), scopeY + scopeH - 12) withAttributes:activeTagAttr];
        }
    }

    // 6. Nominal Pitch Reticle (Red Dashed Line)
    if (self.nominalPitchHz >= minF && self.nominalPitchHz <= maxF) {
        CGFloat pitchX = (CGFloat)((self.nominalPitchHz - minF) / rangeF) * width;
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithSRGBRed:1.0 green:0.25 blue:0.25 alpha:0.85].CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGFloat dash[] = { 4.0, 3.0 };
        CGContextSetLineDash(ctx, 0, dash, 2);
        CGContextMoveToPoint(ctx, pitchX, footerH);
        CGContextAddLineToPoint(ctx, pitchX, height - headerH);
        CGContextStrokePath(ctx);
        CGContextSetLineDash(ctx, 0, NULL, 0); // reset

        // Label on top
        NSDictionary *pitchTagAttr = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: [NSColor colorWithSRGBRed:1.0 green:0.35 blue:0.35 alpha:1.0]
        };
        NSString *tag = [NSString stringWithFormat:@"▼ %.0fHz", self.nominalPitchHz];
        [tag drawAtPoint:NSMakePoint(fmax(4.0, fmin(width - 48.0, pitchX - 20.0)), scopeY + scopeH - 12) withAttributes:pitchTagAttr];
    }

    // 7. AFC Locked Carrier Reticle (Green Solid Line)
    if (fabs(self.centerFrequencyHz - self.nominalPitchHz) > 3.0 && self.centerFrequencyHz >= minF && self.centerFrequencyHz <= maxF) {
        CGFloat afcX = (CGFloat)((self.centerFrequencyHz - minF) / rangeF) * width;
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithSRGBRed:0.25 green:0.95 blue:0.4 alpha:0.9].CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGContextMoveToPoint(ctx, afcX, footerH);
        CGContextAddLineToPoint(ctx, afcX, height - headerH);
        CGContextStrokePath(ctx);
    }

    // 8. Hover Cursor & Click-to-Tune Tooltip with Magnetic Carrier Snap
    if (_isHovering && _hoverPoint.x >= 0 && _hoverPoint.x <= width) {
        double rawHoverFreq = minF + ((double)_hoverPoint.x / (double)width) * rangeF;

        // Magnetic snap: if near a carrier within 25 Hz, snap cursor directly to it
        double effectiveHoverFreq = rawHoverFreq;
        BOOL isSnappedCarrier = NO;
        for (NSNumber *carrierNum in self.detectedCarrierFrequencies) {
            double c = carrierNum.doubleValue;
            if (fabs(c - rawHoverFreq) <= 25.0) {
                effectiveHoverFreq = c;
                isSnappedCarrier = YES;
                break;
            }
        }

        CGFloat hx = (CGFloat)((effectiveHoverFreq - minF) / rangeF) * width;

        // Crosshair vertical line
        CGContextSetStrokeColorWithColor(ctx, isSnappedCarrier ?
            [NSColor colorWithSRGBRed:1.0 green:0.85 blue:0.2 alpha:0.85].CGColor :
            [NSColor colorWithCalibratedWhite:0.9 alpha:0.6].CGColor);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextMoveToPoint(ctx, hx, footerH);
        CGContextAddLineToPoint(ctx, hx, height - headerH);
        CGContextStrokePath(ctx);

        double deltaHz = effectiveHoverFreq - self.nominalPitchHz;
        NSString *hoverText;
        if (isSnappedCarrier) {
            hoverText = [NSString stringWithFormat:@"📻 %.0f Hz [CARRIER] (Δ %+.0f Hz • Click to Tune Radio)", effectiveHoverFreq, deltaHz];
        } else {
            hoverText = [NSString stringWithFormat:@"📻 %.0f Hz (Δ %+.0f Hz • Click to Tune Radio)", effectiveHoverFreq, deltaHz];
        }

        NSDictionary *hoverAttr = @{
            NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: isSnappedCarrier ?
                [NSColor colorWithSRGBRed:1.0 green:0.88 blue:0.25 alpha:1.0] :
                [NSColor colorWithSRGBRed:0.3 green:0.95 blue:1.0 alpha:1.0]
        };
        CGFloat tx = fmax(6.0, fmin(width - 260.0, hx + 8.0));
        [hoverText drawAtPoint:NSMakePoint(tx, footerH + 4.0) withAttributes:hoverAttr];
    }

    // 9. Top HUD Bar
    NSString *hudText = [NSString stringWithFormat:@"PITCH: %.0fHz | AFC: %.0fHz | SNR: %.1fdB | LEVEL: %.0f%% | 3kHz PASSBAND %@",
                         self.nominalPitchHz,
                         self.centerFrequencyHz,
                         self.snrDb,
                         (self.audioLevel * 100.0f),
                         self.isSignalDetected ? @"● CARRIER DETECTED" : @"○ LISTENING"];

    NSDictionary *hudAttr = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:9.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: self.isSignalDetected ?
            [NSColor colorWithSRGBRed:0.25 green:0.95 blue:0.4 alpha:1.0] :
            [NSColor colorWithCalibratedWhite:0.85 alpha:1.0]
    };
    [hudText drawAtPoint:NSMakePoint(8, height - 14) withAttributes:hudAttr];
}

- (void)mouseMoved:(NSEvent *)event {
    _hoverPoint = [self convertPoint:event.locationInWindow fromView:nil];
    _isHovering = YES;
    [self setNeedsDisplay:YES];
}

- (void)mouseEntered:(NSEvent *)event {
    _isHovering = YES;
    [self setNeedsDisplay:YES];
    (void)event;
}

- (void)mouseExited:(NSEvent *)event {
    _isHovering = NO;
    [self setNeedsDisplay:YES];
    (void)event;
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat width = self.bounds.size.width;
    if (width > 0 && p.x >= 0 && p.x <= width) {
        double minF = self.minDisplayFreqHz > 0 ? self.minDisplayFreqHz : 300.0;
        double maxF = self.maxDisplayFreqHz > minF ? self.maxDisplayFreqHz : 3000.0;
        double clickedFreq = minF + ((double)p.x / (double)width) * (maxF - minF);

        // Magnetic snap: if clicked within 25 Hz of any detected carrier peak, snap to it!
        double targetFreq = clickedFreq;
        double minDiff = 25.0;
        for (NSNumber *carrierNum in self.detectedCarrierFrequencies) {
            double c = carrierNum.doubleValue;
            if (fabs(c - clickedFreq) < minDiff) {
                minDiff = fabs(c - clickedFreq);
                targetFreq = c;
            }
        }

        if (self.onWaterfallFrequencyClicked) {
            self.onWaterfallFrequencyClicked(targetFreq);
        } else if (self.onPitchSelected) {
            double pitch = fmin(1500.0, fmax(300.0, round(targetFreq / 5.0) * 5.0));
            self.onPitchSelected(pitch);
        }
    }
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    (void)event;
    return YES;
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor crosshairCursor]];
}

@end
