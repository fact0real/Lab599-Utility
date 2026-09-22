//
//  TX500FT8WaterfallView.m
//  Lab599 Utility
//
//  High-Performance 2D Spectrogram & Scrolling Waterfall View for FT8
//

#import "TX500FT8WaterfallView.h"
#import <stdatomic.h>

#define WF_WIDTH 256
#define WF_HEIGHT 120
#define RULER_HEIGHT 20.0

@interface TX500FT8WaterfallView () {
    uint32_t *_pixelBuffer;
    NSLock *_bufferLock;
    atomic_bool _displayInvalidationPending;
    NSDictionary<NSAttributedStringKey, id> *_rulerTextAttributes;
    NSDictionary<NSAttributedStringKey, id> *_rxTextAttributes;
    NSDictionary<NSAttributedStringKey, id> *_txTextAttributes;
}
@end

static NSDictionary<NSAttributedStringKey, id> *TX500WaterfallTextAttributes(CGFloat size,
                                                                             NSFontWeight weight,
                                                                             NSColor *preferredColor) {
    // AppKit's font/color factories are nullable at runtime (for example while
    // font services are being rebuilt or the process is under memory pressure).
    // Dictionary literals abort when any object is nil, so build the attributes
    // defensively and keep a usable fallback at every step.
    NSMutableDictionary<NSAttributedStringKey, id> *attributes = [NSMutableDictionary dictionaryWithCapacity:2];

    NSFont *font = [NSFont monospacedSystemFontOfSize:size weight:weight];
    if (!font) font = [NSFont userFixedPitchFontOfSize:size];
    if (!font) font = [NSFont systemFontOfSize:size];
    if (font && NSFontAttributeName) {
        [attributes setObject:font forKey:NSFontAttributeName];
    }

    NSColor *color = preferredColor ?: [NSColor textColor] ?: [NSColor blackColor];
    if (color && NSForegroundColorAttributeName) {
        [attributes setObject:color forKey:NSForegroundColorAttributeName];
    }
    return [attributes copy];
}

@implementation TX500FT8WaterfallView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _rxFrequencyHz = 1200.0f;
        _txFrequencyHz = 1500.0f;
        _palette = TX500FT8PaletteRainbow;
        _gain = 1.0f;
        _contrastFloor = 0.0f;
        _scrollSpeed = 1;
        _showCallsignTags = YES;
        _activeStationTags = @[];
        _pixelBuffer = (uint32_t *)calloc(WF_WIDTH * WF_HEIGHT, sizeof(uint32_t));
        _bufferLock = [[NSLock alloc] init];
        atomic_init(&_displayInvalidationPending, false);
        _rulerTextAttributes = TX500WaterfallTextAttributes(9.0, NSFontWeightSemibold, [NSColor labelColor]);
        _rxTextAttributes = TX500WaterfallTextAttributes(8.5, NSFontWeightBold,
            [NSColor colorWithCalibratedRed:0.05 green:0.55 blue:0.22 alpha:1.0]);
        _txTextAttributes = TX500WaterfallTextAttributes(8.5, NSFontWeightBold,
            [NSColor colorWithCalibratedRed:0.90 green:0.15 blue:0.15 alpha:1.0]);

        self.wantsLayer = YES;
        self.layer.cornerRadius = 4.0;
        self.layer.masksToBounds = YES;
        self.layer.backgroundColor = [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] CGColor];
    }
    return self;
}

- (void)dealloc {
    if (_pixelBuffer) {
        free(_pixelBuffer);
        _pixelBuffer = NULL;
    }
}

- (void)clearWaterfall {
    [_bufferLock lock];
    if (_pixelBuffer) {
        memset(_pixelBuffer, 0, WF_WIDTH * WF_HEIGHT * sizeof(uint32_t));
    }
    [_bufferLock unlock];
    [self requestDisplayRefresh];
}

- (void)requestDisplayRefresh {
    if ([NSThread isMainThread]) {
        atomic_store_explicit(&_displayInvalidationPending, false, memory_order_release);
        self.needsDisplay = YES;
        return;
    }

    // Audio callbacks may arrive faster than AppKit can draw. Keep at most one
    // main-queue invalidation pending so decoding cannot grow the dispatch queue.
    if (atomic_exchange_explicit(&_displayInvalidationPending, true, memory_order_acq_rel)) return;
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        TX500FT8WaterfallView *strongSelf = weakSelf;
        if (!strongSelf) return;
        atomic_store_explicit(&strongSelf->_displayInvalidationPending, false, memory_order_release);
        strongSelf.needsDisplay = YES;
    });
}

+ (NSArray<NSString *> *)paletteNames {
    return @[
        @"Rainbow (SDR)",
        @"Heat (Thermal)",
        @"DigiPan (Classic)",
        @"Lab599 Signature",
        @"Oceanic Blue",
        @"Phosphor Green",
        @"Plasma"
    ];
}

#pragma mark - Spectrum Ingestion & Palette Mapping

static inline uint32_t ColorForMagnitude(float mag, TX500FT8Palette pal) {
    float m = fminf(1.0f, fmaxf(0.0f, mag));
    uint8_t r = 0, g = 0, b = 0;

    switch (pal) {
        case TX500FT8PaletteRainbow: // SDR Rainbow Heatmap: Deep Dark Navy -> Blue -> Cyan -> Green -> Yellow -> Orange -> Red -> White
            if (m < 0.08f) {
                float t = m / 0.08f;
                r = (uint8_t)(t * 2); g = (uint8_t)(4 + t * 8); b = (uint8_t)(16 + t * 24);
            } else if (m < 0.25f) {
                float t = (m - 0.08f) / 0.17f;
                r = 0; g = (uint8_t)(12 + t * 140); b = (uint8_t)(40 + t * 155);
            } else if (m < 0.45f) {
                float t = (m - 0.25f) / 0.20f;
                r = 0; g = (uint8_t)(152 + t * 63); b = (uint8_t)(195 + t * 55);
            } else if (m < 0.65f) {
                float t = (m - 0.45f) / 0.20f;
                r = (uint8_t)(t * 160); g = 215; b = (uint8_t)(250 - t * 240);
            } else if (m < 0.82f) {
                float t = (m - 0.65f) / 0.17f;
                r = (uint8_t)(160 + t * 95); g = (uint8_t)(215 - t * 90); b = 10;
            } else if (m < 0.93f) {
                float t = (m - 0.82f) / 0.11f;
                r = 255; g = (uint8_t)(125 - t * 95); b = 10;
            } else {
                float t = (m - 0.93f) / 0.07f;
                r = 255; g = (uint8_t)(30 + t * 225); b = (uint8_t)(10 + t * 245);
            }
            break;

        case TX500FT8PaletteHeat: // Thermal Infrared: Black -> Deep Red -> Bright Orange -> Gold -> White
            if (m < 0.25f) {
                float t = m / 0.25f;
                r = (uint8_t)(t * 140); g = 0; b = (uint8_t)(t * 15);
            } else if (m < 0.55f) {
                float t = (m - 0.25f) / 0.30f;
                r = (uint8_t)(140 + t * 115); g = (uint8_t)(t * 120); b = 0;
            } else if (m < 0.85f) {
                float t = (m - 0.55f) / 0.30f;
                r = 255; g = (uint8_t)(120 + t * 125); b = (uint8_t)(t * 50);
            } else {
                float t = (m - 0.85f) / 0.15f;
                r = 255; g = (uint8_t)(245 + t * 10); b = (uint8_t)(50 + t * 205);
            }
            break;

        case TX500FT8PaletteDigipan: // Classic DigiPan: Deep Navy -> Electric Cyan -> Yellow -> Red -> White
            if (m < 0.25f) {
                float t = m / 0.25f;
                r = 8; g = (uint8_t)(12 + t * 65); b = (uint8_t)(40 + t * 135);
            } else if (m < 0.55f) {
                float t = (m - 0.25f) / 0.30f;
                r = (uint8_t)(8 + t * 230); g = (uint8_t)(77 + t * 168); b = (uint8_t)(175 - t * 145);
            } else if (m < 0.85f) {
                float t = (m - 0.55f) / 0.30f;
                r = (uint8_t)(238 + t * 17); g = (uint8_t)(245 - t * 205); b = 30;
            } else {
                float t = (m - 0.85f) / 0.15f;
                r = 255; g = (uint8_t)(40 + t * 215); b = (uint8_t)(30 + t * 225);
            }
            break;

        case TX500FT8PaletteLab599Red: // Dark (#121214) -> Charcoal (#26282C) -> Amber (#FFA500) -> Red (#CD1E1E) -> White
            if (m < 0.25f) {
                float t = m / 0.25f;
                r = (uint8_t)(18 + t * (40 - 18));
                g = (uint8_t)(18 + t * (42 - 18));
                b = (uint8_t)(20 + t * (46 - 20));
            } else if (m < 0.60f) {
                float t = (m - 0.25f) / 0.35f;
                r = (uint8_t)(40 + t * (255 - 40));
                g = (uint8_t)(42 + t * (165 - 42));
                b = (uint8_t)(46 + t * (0 - 46));
            } else if (m < 0.85f) {
                float t = (m - 0.60f) / 0.25f;
                r = (uint8_t)(255 - t * (255 - 205));
                g = (uint8_t)(165 - t * (165 - 30));
                b = (uint8_t)(t * 30);
            } else {
                float t = (m - 0.85f) / 0.15f;
                r = (uint8_t)(205 + t * (255 - 205));
                g = (uint8_t)(30 + t * (255 - 30));
                b = (uint8_t)(30 + t * (255 - 30));
            }
            break;

        case TX500FT8PaletteOceanicBlue: // Navy -> Deep Blue -> Cyan -> White
            if (m < 0.33f) {
                float t = m / 0.33f;
                r = 10; g = (uint8_t)(20 + t * 40); b = (uint8_t)(50 + t * 120);
            } else if (m < 0.75f) {
                float t = (m - 0.33f) / 0.42f;
                r = (uint8_t)(t * 60); g = (uint8_t)(60 + t * 180); b = (uint8_t)(170 + t * 85);
            } else {
                float t = (m - 0.75f) / 0.25f;
                r = (uint8_t)(60 + t * 195); g = 240; b = 255;
            }
            break;

        case TX500FT8PalettePhosphorGreen: // Emerald -> Phosphor -> White
            if (m < 0.5f) {
                float t = m / 0.5f;
                r = 10; g = (uint8_t)(25 + t * 150); b = 15;
            } else {
                float t = (m - 0.5f) / 0.5f;
                r = (uint8_t)(t * 220); g = 255; b = (uint8_t)(t * 220);
            }
            break;

        case TX500FT8PalettePlasma:
        default:
            if (m < 0.33f) {
                float t = m / 0.33f;
                r = (uint8_t)(t * 120); g = 10; b = (uint8_t)(50 + t * 130);
            } else if (m < 0.7f) {
                float t = (m - 0.33f) / 0.37f;
                r = (uint8_t)(120 + t * 135); g = (uint8_t)(10 + t * 120); b = (uint8_t)(180 - t * 120);
            } else {
                float t = (m - 0.7f) / 0.3f;
                r = 255; g = (uint8_t)(130 + t * 125); b = (uint8_t)(60 + t * 195);
            }
            break;
    }

    return (0xFF000000) | ((uint32_t)r << 16) | ((uint32_t)g << 8) | (uint32_t)b;
}

- (void)appendSpectrumRow:(const float *)magnitudes count:(NSInteger)count {
    if (!magnitudes || count <= 0) return;

    [_bufferLock lock];
    if (!_pixelBuffer) {
        [_bufferLock unlock];
        return;
    }

    int steps = (self.scrollSpeed > 0 && self.scrollSpeed <= 4) ? (int)self.scrollSpeed : 1;
    for (int s = 0; s < steps; s++) {
        // Scroll down: move rows 0..WF_HEIGHT-2 down to rows 1..WF_HEIGHT-1
        memmove(_pixelBuffer + WF_WIDTH, _pixelBuffer, (WF_HEIGHT - 1) * WF_WIDTH * sizeof(uint32_t));

        // Fill top row 0
        float gainVal = (self.gain > 0.05f) ? self.gain : 1.0f;
        for (int x = 0; x < WF_WIDTH; x++) {
            float sampleIdx = (float)x / (float)WF_WIDTH * (float)count;
            int idx = (int)sampleIdx;
            float rawMag = 0.0f;
            if (idx < count) {
                rawMag = magnitudes[idx];
            }
            float scaledMag = fmaxf(0.0f, fminf(1.0f, (rawMag - self.contrastFloor) * gainVal));
            _pixelBuffer[x] = ColorForMagnitude(scaledMag, self.palette);
        }
    }
    [_bufferLock unlock];

    [self requestDisplayRefresh];
}

#pragma mark - Drawing

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    NSRect bounds = self.bounds;

    // 1. Background fill (Dark oceanic navy RF canvas)
    [[NSColor colorWithCalibratedRed:0.06 green:0.08 blue:0.12 alpha:1.0] setFill];
    NSRectFill(bounds);

    NSRect wfRect = NSMakeRect(bounds.origin.x, bounds.origin.y,
                               bounds.size.width, bounds.size.height - RULER_HEIGHT);

    // 2. Render Waterfall Bitmap
    [_bufferLock lock];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmapCtx = NULL;
    CGImageRef imageRef = NULL;
    if (_pixelBuffer && colorSpace) {
        bitmapCtx = CGBitmapContextCreate(_pixelBuffer, WF_WIDTH, WF_HEIGHT, 8,
                                         WF_WIDTH * 4, colorSpace,
                                         kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);
    }
    if (bitmapCtx) imageRef = CGBitmapContextCreateImage(bitmapCtx);

    if (imageRef && ctx) {
        CGContextSaveGState(ctx);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, NSRectToCGRect(wfRect), imageRef);
        CGContextRestoreGState(ctx);
    }
    if (imageRef) CGImageRelease(imageRef);
    if (bitmapCtx) CGContextRelease(bitmapCtx);
    if (colorSpace) CGColorSpaceRelease(colorSpace);
    [_bufferLock unlock];

    // Subtle frequency grid lines across spectrum
    [[NSColor colorWithCalibratedWhite:1.0 alpha:0.08] setStroke];
    for (int hz = 500; hz <= 2500; hz += 500) {
        CGFloat x = (CGFloat)hz / 3000.0 * bounds.size.width;
        [NSBezierPath strokeLineFromPoint:NSMakePoint(x, wfRect.origin.y)
                                  toPoint:NSMakePoint(x, NSMaxY(wfRect))];
    }

    // 3. Render Frequency Ruler (Top Bar) — High-Contrast Clean Theme
    NSRect rulerRect = NSMakeRect(bounds.origin.x, bounds.size.height - RULER_HEIGHT,
                                  bounds.size.width, RULER_HEIGHT);
    [[NSColor colorWithCalibratedWhite:0.95 alpha:1.0] setFill];
    NSRectFill(rulerRect);

    // Ruler Divider
    [[NSColor separatorColor] setStroke];
    NSBezierPath *rulerLine = [NSBezierPath bezierPath];
    rulerLine.lineWidth = 1.0;
    [rulerLine moveToPoint:NSMakePoint(0, bounds.size.height - RULER_HEIGHT)];
    [rulerLine lineToPoint:NSMakePoint(bounds.size.width, bounds.size.height - RULER_HEIGHT)];
    [rulerLine stroke];

    NSDictionary<NSAttributedStringKey, id> *textAttrs = _rulerTextAttributes ?: @{};

    // Frequency Ticks every 500 Hz (0 to 3000 Hz)
    for (int hz = 500; hz <= 3000; hz += 500) {
        CGFloat x = (CGFloat)hz / 3000.0 * bounds.size.width;
        [[NSColor separatorColor] setStroke];
        [NSBezierPath strokeLineFromPoint:NSMakePoint(x, bounds.size.height - RULER_HEIGHT)
                                  toPoint:NSMakePoint(x, bounds.size.height - RULER_HEIGHT + 6.0)];

        NSString *label = [NSString stringWithFormat:@"%d", hz];
        NSSize sz = [label sizeWithAttributes:textAttrs];
        [label drawAtPoint:NSMakePoint(x - sz.width / 2.0, bounds.size.height - RULER_HEIGHT + 7.0)
            withAttributes:textAttrs];
    }

    // 4. Draw RX Reticle (Tactical Emerald Green Bracket)
    CGFloat rxX = (CGFloat)self.rxFrequencyHz / 3000.0 * bounds.size.width;
    CGFloat rxHalfWidth = (25.0 / 3000.0) * bounds.size.width;
    NSRect rxReticle = NSMakeRect(rxX - rxHalfWidth, wfRect.origin.y, rxHalfWidth * 2.0, wfRect.size.height);

    [[NSColor colorWithCalibratedRed:0.05 green:0.65 blue:0.25 alpha:0.22] setFill];
    NSRectFillUsingOperation(rxReticle, NSCompositingOperationSourceOver);

    [[NSColor colorWithCalibratedRed:0.05 green:0.60 blue:0.22 alpha:1.0] setStroke];
    NSBezierPath *rxPath = [NSBezierPath bezierPath];
    rxPath.lineWidth = 1.5;
    // Left bracket
    [rxPath moveToPoint:NSMakePoint(rxReticle.origin.x + 4.0, rxReticle.origin.y + rxReticle.size.height)];
    [rxPath lineToPoint:NSMakePoint(rxReticle.origin.x, rxReticle.origin.y + rxReticle.size.height)];
    [rxPath lineToPoint:NSMakePoint(rxReticle.origin.x, rxReticle.origin.y)];
    [rxPath lineToPoint:NSMakePoint(rxReticle.origin.x + 4.0, rxReticle.origin.y)];
    // Right bracket
    [rxPath moveToPoint:NSMakePoint(NSMaxX(rxReticle) - 4.0, rxReticle.origin.y + rxReticle.size.height)];
    [rxPath lineToPoint:NSMakePoint(NSMaxX(rxReticle), rxReticle.origin.y + rxReticle.size.height)];
    [rxPath lineToPoint:NSMakePoint(NSMaxX(rxReticle), rxReticle.origin.y)];
    [rxPath lineToPoint:NSMakePoint(NSMaxX(rxReticle) - 4.0, rxReticle.origin.y)];
    [rxPath stroke];

    // RX Tag on ruler
    NSDictionary<NSAttributedStringKey, id> *rxTagAttrs = _rxTextAttributes ?: @{};
    [@"RX" drawAtPoint:NSMakePoint(rxX - 7.0, bounds.size.height - RULER_HEIGHT + 7.0) withAttributes:rxTagAttrs];

    // 5. Draw TX Reticle (Lab599 Red Bracket)
    CGFloat txX = (CGFloat)self.txFrequencyHz / 3000.0 * bounds.size.width;
    CGFloat txHalfWidth = (25.0 / 3000.0) * bounds.size.width;
    NSRect txReticle = NSMakeRect(txX - txHalfWidth, wfRect.origin.y, txHalfWidth * 2.0, wfRect.size.height);

    NSColor *txColor = self.isTransmitting ?
        [NSColor colorWithCalibratedRed:0.90 green:0.15 blue:0.15 alpha:1.0] :
        [NSColor colorWithCalibratedRed:0.80 green:0.20 blue:0.20 alpha:0.90];

    [[txColor colorWithAlphaComponent:self.isTransmitting ? 0.35 : 0.18] setFill];
    NSRectFillUsingOperation(txReticle, NSCompositingOperationSourceOver);

    [txColor setStroke];
    NSBezierPath *txPath = [NSBezierPath bezierPath];
    txPath.lineWidth = self.isTransmitting ? 2.5 : 1.5;
    // Left bracket
    [txPath moveToPoint:NSMakePoint(txReticle.origin.x + 4.0, txReticle.origin.y + txReticle.size.height)];
    [txPath lineToPoint:NSMakePoint(txReticle.origin.x, txReticle.origin.y + txReticle.size.height)];
    [txPath lineToPoint:NSMakePoint(txReticle.origin.x, txReticle.origin.y)];
    [txPath lineToPoint:NSMakePoint(txReticle.origin.x + 4.0, txReticle.origin.y)];
    // Right bracket
    [txPath moveToPoint:NSMakePoint(NSMaxX(txReticle) - 4.0, txReticle.origin.y + txReticle.size.height)];
    [txPath lineToPoint:NSMakePoint(NSMaxX(txReticle), txReticle.origin.y + txReticle.size.height)];
    [txPath lineToPoint:NSMakePoint(NSMaxX(txReticle), txReticle.origin.y)];
    [txPath lineToPoint:NSMakePoint(NSMaxX(txReticle) - 4.0, txReticle.origin.y)];
    [txPath stroke];

    // TX Tag on ruler
    NSDictionary<NSAttributedStringKey, id> *txTagAttrs = _txTextAttributes ?: @{};
    [@"TX" drawAtPoint:NSMakePoint(txX - 7.0, bounds.size.height - RULER_HEIGHT + 7.0) withAttributes:txTagAttrs];

    // 6. Callsign Tags HUD Overlay
    if (self.showCallsignTags && self.activeStationTags.count > 0) {
        NSFont *tagFont = [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightBold];
        NSDictionary *cqAttrs = @{
            NSFontAttributeName: tagFont,
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:1.0 green:0.85 blue:0.25 alpha:1.0]
        };
        NSDictionary *callAttrs = @{
            NSFontAttributeName: tagFont,
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.25 green:0.85 blue:0.45 alpha:1.0]
        };

        CGFloat tagY = bounds.size.height - RULER_HEIGHT - 18.0;

        for (NSDictionary *tag in self.activeStationTags) {
            float freq = [tag[@"freq"] floatValue];
            NSString *call = tag[@"call"] ?: @"";
            if (call.length == 0 || freq < 100.0f || freq > 2950.0f) continue;

            int snr = [tag[@"snr"] intValue];
            BOOL isCQ = [tag[@"isCQ"] boolValue];
            NSString *tagText = isCQ ? [NSString stringWithFormat:@"CQ %@ %+ddB", call, snr] :
                                       [NSString stringWithFormat:@"%@ %+ddB", call, snr];

            NSDictionary *attrs = isCQ ? cqAttrs : callAttrs;
            NSSize strSize = [tagText sizeWithAttributes:attrs];
            CGFloat tagW = strSize.width + 8.0;
            CGFloat tagH = 14.0;
            CGFloat tagX = (CGFloat)freq / 3000.0 * bounds.size.width - (tagW / 2.0);
            tagX = fmax(4.0, fmin(bounds.size.width - tagW - 4.0, tagX));

            NSRect pillRect = NSMakeRect(tagX, tagY, tagW, tagH);
            NSBezierPath *pill = [NSBezierPath bezierPathWithRoundedRect:pillRect xRadius:3.0 yRadius:3.0];
            [[NSColor colorWithCalibratedRed:0.05 green:0.08 blue:0.12 alpha:0.82] setFill];
            [pill fill];

            NSColor *borderColor = isCQ ?
                [NSColor colorWithCalibratedRed:0.80 green:0.65 blue:0.15 alpha:0.85] :
                [NSColor colorWithCalibratedRed:0.20 green:0.75 blue:0.35 alpha:0.85];
            [borderColor setStroke];
            pill.lineWidth = 1.0;
            [pill stroke];

            NSPoint textPoint = NSMakePoint(tagX + 4.0, tagY + (tagH - strSize.height) / 2.0);
            [tagText drawAtPoint:textPoint withAttributes:attrs];
        }
    }

    // 7. Outer Bezel Border
    [[NSColor separatorColor] setStroke];
    NSBezierPath *bezel = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:5.0 yRadius:5.0];
    bezel.lineWidth = 1.0;
    [bezel stroke];
}

#pragma mark - Mouse Click to Tune


- (void)mouseDown:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL isTx = (event.modifierFlags & NSEventModifierFlagShift) || (event.modifierFlags & NSEventModifierFlagOption);
    [self handleTuneAtPoint:loc isTx:isTx];
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint loc = [self convertPoint:event.locationInWindow fromView:nil];
    [self handleTuneAtPoint:loc isTx:YES]; // Right-click sets TX
}

- (void)handleTuneAtPoint:(NSPoint)loc isTx:(BOOL)isTx {
    CGFloat frac = loc.x / self.bounds.size.width;
    frac = fmax(0.0, fmin(1.0, frac));
    float freq = (float)frac * 3000.0f;
    freq = fmaxf(200.0f, fminf(2900.0f, freq));

    if (isTx) {
        self.txFrequencyHz = freq;
    } else {
        self.rxFrequencyHz = freq;
    }
    self.needsDisplay = YES;

    if (self.onFrequencySelected) {
        self.onFrequencySelected(freq, isTx);
    }
}

@end
