//
//  TX500FT8WaterfallView.m
//  Lab599 Utility
//
//  High-Performance 2D Spectrogram & Scrolling Waterfall View for FT8
//

#import "TX500FT8WaterfallView.h"

#define WF_WIDTH 256
#define WF_HEIGHT 120
#define RULER_HEIGHT 20.0

@interface TX500FT8WaterfallView () {
    uint32_t *_pixelBuffer;
    NSLock *_bufferLock;
}
@end

@implementation TX500FT8WaterfallView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _rxFrequencyHz = 1200.0f;
        _txFrequencyHz = 1500.0f;
        _palette = TX500FT8PaletteLab599Red;
        _pixelBuffer = (uint32_t *)calloc(WF_WIDTH * WF_HEIGHT, sizeof(uint32_t));
        _bufferLock = [[NSLock alloc] init];

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
    dispatch_async(dispatch_get_main_queue(), ^{
        self.needsDisplay = YES;
    });
}

#pragma mark - Spectrum Ingestion & Palette Mapping

static inline uint32_t ColorForMagnitude(float mag, TX500FT8Palette pal) {
    float m = fminf(1.0f, fmaxf(0.0f, mag));
    uint8_t r = 0, g = 0, b = 0;

    switch (pal) {
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
    // Scroll down: move rows 0..WF_HEIGHT-2 down to rows 1..WF_HEIGHT-1
    memmove(_pixelBuffer + WF_WIDTH, _pixelBuffer, (WF_HEIGHT - 1) * WF_WIDTH * sizeof(uint32_t));

    // Fill top row 0
    for (int x = 0; x < WF_WIDTH; x++) {
        float sampleIdx = (float)x / (float)WF_WIDTH * (float)count;
        int idx = (int)sampleIdx;
        float mag = 0.0f;
        if (idx < count) {
            mag = magnitudes[idx];
        }
        _pixelBuffer[x] = ColorForMagnitude(mag, self.palette);
    }
    [_bufferLock unlock];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.needsDisplay = YES;
    });
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
    CGContextRef bitmapCtx = CGBitmapContextCreate(_pixelBuffer, WF_WIDTH, WF_HEIGHT, 8,
                                                   WF_WIDTH * 4, colorSpace,
                                                   kCGImageAlphaNoneSkipFirst | kCGBitmapByteOrder32Little);

    CGImageRef imageRef = CGBitmapContextCreateImage(bitmapCtx);
    CGContextRelease(bitmapCtx);
    CGColorSpaceRelease(colorSpace);
    [_bufferLock unlock];

    if (imageRef) {
        CGContextSaveGState(ctx);
        CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
        CGContextDrawImage(ctx, NSRectToCGRect(wfRect), imageRef);
        CGContextRestoreGState(ctx);
        CGImageRelease(imageRef);
    }

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

    NSDictionary *textAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightSemibold],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };

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
    NSDictionary *rxTagAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.05 green:0.55 blue:0.22 alpha:1.0]
    };
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
    NSDictionary *txTagAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: txColor
    };
    [@"TX" drawAtPoint:NSMakePoint(txX - 7.0, bounds.size.height - RULER_HEIGHT + 7.0) withAttributes:txTagAttrs];

    // 6. Outer Bezel Border
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
