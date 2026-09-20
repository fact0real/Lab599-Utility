#import "TX500ScreenRenderer.h"
#import <math.h>

@implementation TX500ScreenRenderer

+ (NSSize)nativeLCDSize {
    return NSMakeSize(256.0, 128.0);
}

+ (NSSize)nativeChassisSize {
    return NSMakeSize(840.0, 440.0);
}

+ (NSColor *)backgroundColorForTheme:(TX500ScreenTheme)theme {
    switch (theme) {
        case TX500ScreenThemeAmber:
            return [NSColor colorWithCalibratedRed:0.09 green:0.05 blue:0.00 alpha:1.0]; // Warm amber-black
        case TX500ScreenThemeCoolWhite:
            return [NSColor colorWithCalibratedRed:0.83 green:0.87 blue:0.84 alpha:1.0]; // Transflective daylight grey-green as in real photo
        case TX500ScreenThemeGreen:
            return [NSColor colorWithCalibratedRed:0.03 green:0.09 blue:0.03 alpha:1.0]; // Tactical dark green
        case TX500ScreenThemeOLED:
            return [NSColor blackColor];
    }
}

+ (NSColor *)pixelOnColorForTheme:(TX500ScreenTheme)theme {
    switch (theme) {
        case TX500ScreenThemeAmber:
            return [NSColor colorWithCalibratedRed:1.00 green:0.62 blue:0.00 alpha:1.0]; // Vibrant amber #FFA000
        case TX500ScreenThemeCoolWhite:
            return [NSColor colorWithCalibratedRed:0.10 green:0.12 blue:0.11 alpha:1.0]; // Deep crisp LCD black as in real photo
        case TX500ScreenThemeGreen:
            return [NSColor colorWithCalibratedRed:0.25 green:1.00 blue:0.30 alpha:1.0]; // Phosphor emerald green
        case TX500ScreenThemeOLED:
            return [NSColor whiteColor];
    }
}

+ (NSColor *)pixelOffColorForTheme:(TX500ScreenTheme)theme {
    switch (theme) {
        case TX500ScreenThemeAmber:
            return [NSColor colorWithCalibratedRed:0.22 green:0.13 blue:0.00 alpha:0.35];
        case TX500ScreenThemeCoolWhite:
            return [NSColor colorWithCalibratedRed:0.75 green:0.80 blue:0.76 alpha:0.40];
        case TX500ScreenThemeGreen:
            return [NSColor colorWithCalibratedRed:0.08 green:0.22 blue:0.08 alpha:0.35];
        case TX500ScreenThemeOLED:
            return [NSColor colorWithCalibratedWhite:0.12 alpha:0.30];
    }
}

#pragma mark - Primary Screen Rendering (256x128)

+ (NSImage *)renderScreenImageWithState:(TX500ScreenState *)state
                                  theme:(TX500ScreenTheme)theme
                                  scale:(CGFloat)scale
                              pixelGrid:(BOOL)pixelGrid {
    if (scale <= 0.1) scale = 2.0;

    NSSize nativeSize = [self nativeLCDSize];
    NSSize scaledSize = NSMakeSize(nativeSize.width * scale, nativeSize.height * scale);

    NSImage *image = [[NSImage alloc] initWithSize:scaledSize];
    [image lockFocus];

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    CGContextSaveGState(ctx);

    // Scale context to draw directly in native 256 x 128 pixel coordinates
    CGContextScaleCTM(ctx, scale, scale);

    NSColor *bgColor = [self backgroundColorForTheme:theme];
    NSColor *fgColor = [self pixelOnColorForTheme:theme];
    NSColor *dimColor = [self pixelOffColorForTheme:theme];

    // Background fill
    [bgColor setFill];
    NSRectFill(NSMakeRect(0, 0, nativeSize.width, nativeSize.height));

    // Outer pixel-perfect 1px border
    [dimColor setStroke];
    NSBezierPath *border = [NSBezierPath bezierPathWithRect:NSMakeRect(0.5, 0.5, nativeSize.width - 1.0, nativeSize.height - 1.0)];
    [border setLineWidth:1.0];
    [border stroke];

    // --- Section 1: Top Soft-Key Menu Bar (Aligned with 4 top physical buttons) ---
    [self drawTopMenuBarInContext:ctx state:state fg:fgColor bg:bgColor dim:dimColor];

    // --- Section 2: Sub-Header Status Row (RX/TX, AGC, Voltage, Clock) ---
    [self drawSubHeaderStatusInContext:ctx state:state fg:fgColor bg:bgColor dim:dimColor];

    // --- Section 3: VFO-A Main Frequency & Indicators (24.889.30₀, DIG, FIL-1, AF64, RF0) ---
    [self drawVFOAInContext:ctx state:state fg:fgColor bg:bgColor dim:dimColor];

    // --- Section 4: VFO-B Secondary Frequency & Mode (10 100 000, CWR) ---
    [self drawVFOBInContext:ctx state:state fg:fgColor bg:bgColor dim:dimColor];

    // --- Section 5: S-Meter / RF Power Bar (S 1..3..5..7..9.20.40.60) ---
    [self drawSMeterInContext:ctx state:state fg:fgColor bg:bgColor dim:dimColor];

    // --- Section 6: Panadapter Spectrum (Filled Solid Bars + Passband Brackets) ---
    [self drawPanadapterInContext:ctx state:state fg:fgColor bg:bgColor dim:dimColor];

    // --- Section 7: Bottom Soft-Key Menu Bar (Aligned with 4 bottom physical buttons) ---
    [self drawBottomMenuBarInContext:ctx state:state fg:fgColor bg:bgColor dim:dimColor];

    CGContextRestoreGState(ctx);

    // Optional LCD Matrix Pixel Grid Overlay
    if (pixelGrid && scale >= 2.0) {
        CGContextSetBlendMode(ctx, kCGBlendModeNormal);
        [[NSColor colorWithCalibratedWhite:0.0 alpha:theme == TX500ScreenThemeCoolWhite ? 0.15 : 0.28] setStroke];
        CGContextSetLineWidth(ctx, 1.0);

        for (CGFloat x = 0; x < scaledSize.width; x += scale) {
            CGContextMoveToPoint(ctx, x + 0.5, 0);
            CGContextAddLineToPoint(ctx, x + 0.5, scaledSize.height);
        }
        for (CGFloat y = 0; y < scaledSize.height; y += scale) {
            CGContextMoveToPoint(ctx, 0, y + 0.5);
            CGContextAddLineToPoint(ctx, scaledSize.width, y + 0.5);
        }
        CGContextStrokePath(ctx);
    }

    [image unlockFocus];
    return image;
}

#pragma mark - Detailed Screen Sections (256x128 space, origin bottom-left)

// 1. Top Soft-Key Menu Bar (y: 116 to 127)
+ (void)drawTopMenuBarInContext:(CGContextRef)ctx
                          state:(TX500ScreenState *)state
                             fg:(NSColor *)fg
                             bg:(NSColor *)bg
                            dim:(NSColor *)dim {
    (void)ctx; (void)dim;
    // Four columns for 4 physical buttons on top of LCD
    NSArray *labels = state.topSoftKeyLabels ?: @[@"CWSPEED", @"CWPITCH", @"POWER", @"VOX"];
    CGFloat colW = 58.0;
    CGFloat startX = 6.0;
    CGFloat y = 117.0;
    CGFloat h = 9.5;

    NSFont *font = [NSFont monospacedSystemFontOfSize:7.2 weight:NSFontWeightBold];
    NSDictionary *invAttrs = @{NSFontAttributeName: font, NSForegroundColorAttributeName: bg};

    for (NSUInteger i = 0; i < 4; i++) {
        NSString *lbl = i < labels.count ? labels[i] : @"";
        if (!lbl.length) continue;

        CGFloat x = startX + (i * (colW + 4.0));
        NSRect btnRect = NSMakeRect(x, y, colW, h);

        // Inverted black/amber badge for active soft-keys
        [fg setFill];
        NSRectFill(btnRect);

        NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
        style.alignment = NSTextAlignmentCenter;
        NSMutableDictionary *dict = [invAttrs mutableCopy];
        dict[NSParagraphStyleAttributeName] = style;

        [lbl drawInRect:NSMakeRect(x, y - 0.5, colW, h) withAttributes:dict];
    }
}

// 2. Sub-Header Status Row (y: 104 to 115)
+ (void)drawSubHeaderStatusInContext:(CGContextRef)ctx
                               state:(TX500ScreenState *)state
                                  fg:(NSColor *)fg
                                  bg:(NSColor *)bg
                                 dim:(NSColor *)dim {
    (void)ctx; (void)dim;
    CGFloat y = 104.5;

    // RX / TX Indicator
    if (state.isTransmitting) {
        NSRect txRect = NSMakeRect(6.0, y, 20.0, 10.0);
        [[NSColor colorWithCalibratedRed:0.90 green:0.15 blue:0.15 alpha:1.0] setFill];
        NSRectFill(txRect);
        NSDictionary *txAttrs = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:7.5 weight:NSFontWeightBlack],
            NSForegroundColorAttributeName: [NSColor whiteColor]
        };
        [@"TX" drawAtPoint:NSMakePoint(8.5, y) withAttributes:txAttrs];
    } else {
        NSDictionary *rxAttrs = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: fg
        };
        [@"RX" drawAtPoint:NSMakePoint(6.0, y) withAttributes:rxAttrs];
    }

    // AGC Mode & Value (e.g. "AGC 10")
    NSString *agcStr = [NSString stringWithFormat:@"AGC %ld", (long)(state.agcDelay > 0 ? state.agcDelay : 10)];
    NSDictionary *subAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:7.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: fg
    };
    [agcStr drawAtPoint:NSMakePoint(76.0, y) withAttributes:subAttrs];

    // Power setting value (e.g. "100" or "10") under POWER soft-key
    NSString *pwrVal = @"100";
    if (state.topSoftKeyValues.count > 2 && state.topSoftKeyValues[2].length) {
        pwrVal = state.topSoftKeyValues[2];
    }
    [pwrVal drawAtPoint:NSMakePoint(146.0, y) withAttributes:subAttrs];

    // Voltage (e.g. "12.0V")
    NSString *vStr = [NSString stringWithFormat:@"%.1fV", state.supplyVoltage > 0 ? state.supplyVoltage : 12.0];
    [vStr drawAtPoint:NSMakePoint(184.0, y) withAttributes:subAttrs];

    // Clock Time (e.g. "18:32")
    NSString *clk = state.clockString ?: @"18:32";
    if (clk.length > 5 && [clk containsString:@" "]) {
        clk = [clk componentsSeparatedByString:@" "].firstObject;
    }
    if (clk.length > 5) clk = [clk substringToIndex:5];
    [clk drawAtPoint:NSMakePoint(220.0, y) withAttributes:subAttrs];
}

// 3. VFO-A Main Frequency & Mode / Filter Badges (y: 76 to 102)
+ (void)drawVFOAInContext:(CGContextRef)ctx
                    state:(TX500ScreenState *)state
                       fg:(NSColor *)fg
                       bg:(NSColor *)bg
                      dim:(NSColor *)dim {
    (void)ctx; (void)dim;
    // Letter 'A' designation on left
    NSDictionary *tagAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightBlack],
        NSForegroundColorAttributeName: fg
    };
    [@"A" drawAtPoint:NSMakePoint(6.0, 84.0) withAttributes:tagAttrs];

    // Format Frequency: 24,889,300 -> "24.889.30" with sub-Hz "0"
    uint64_t f = state.frequencyHz > 0 ? state.frequencyHz : 24889300;
    uint64_t mhz = f / 1000000;
    uint64_t khz = (f % 1000000) / 1000;
    uint64_t tens = (f % 1000) / 10;
    uint64_t ones = f % 10;

    NSString *mainDigits = [NSString stringWithFormat:@"%llu.%03llu.%02llu", mhz, khz, tens];

    // Large authentic digital typography for primary frequency
    NSFont *freqFont = [NSFont monospacedSystemFontOfSize:21.0 weight:NSFontWeightBold];
    NSDictionary *freqAttrs = @{
        NSFontAttributeName: freqFont,
        NSForegroundColorAttributeName: fg
    };
    [mainDigits drawAtPoint:NSMakePoint(24.0, 77.0) withAttributes:freqAttrs];

    // Sub-Hz digit in subscript rectangular box: "₀" as on real radio screen
    CGFloat subX = 141.0;
    CGFloat subY = 80.0;
    NSRect subBox = NSMakeRect(subX, subY, 7.5, 9.5);
    [fg setStroke];
    NSBezierPath *p = [NSBezierPath bezierPathWithRect:subBox];
    [p setLineWidth:1.0];
    [p stroke];

    NSDictionary *subAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:6.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: fg
    };
    NSString *subStr = [NSString stringWithFormat:@"%llu", ones];
    [subStr drawAtPoint:NSMakePoint(subX + 1.2, subY + 0.5) withAttributes:subAttrs];

    // Mode Inverted Badge: [ USB ], [ LSB ], [ DIG ], etc.
    NSString *mode = state.operatingMode ?: @"USB";
    // No remapping — show the actual mode string from radio
    NSRect modeRect = NSMakeRect(152.0, 80.0, 24.0, 13.0);
    [fg setFill];
    NSRectFill(modeRect);

    NSMutableParagraphStyle *modeStyle = [NSMutableParagraphStyle new];
    modeStyle.alignment = NSTextAlignmentCenter;
    NSDictionary *modeAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightBlack],
        NSForegroundColorAttributeName: bg,
        NSParagraphStyleAttributeName: modeStyle
    };
    [mode drawInRect:NSMakeRect(152.0, 80.5, 24.0, 12.0) withAttributes:modeAttrs];

    // Filter Badges: FIL-1 and 3.10k
    NSString *filName = state.filterName ?: @"FIL-1";
    NSString *filBw = state.filterBandwidthString ?: @"3.10k";
    NSDictionary *paramAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:7.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: fg
    };
    [filName drawAtPoint:NSMakePoint(180.0, 88.0) withAttributes:paramAttrs];
    [filBw drawAtPoint:NSMakePoint(180.0, 78.0) withAttributes:paramAttrs];

    // AF Gain & RF Gain Badges: AF64 and RF0
    NSString *afStr = [NSString stringWithFormat:@"AF%ld", (long)(state.afGainLevel > 0 ? state.afGainLevel : 64)];
    NSString *rfStr = [NSString stringWithFormat:@"RF%ld", (long)state.rfGainLevel];
    [afStr drawAtPoint:NSMakePoint(216.0, 88.0) withAttributes:paramAttrs];
    [rfStr drawAtPoint:NSMakePoint(216.0, 78.0) withAttributes:paramAttrs];
}

// 4. VFO-B Secondary Frequency & Mode (y: 62 to 74)
+ (void)drawVFOBInContext:(CGContextRef)ctx
                    state:(TX500ScreenState *)state
                       fg:(NSColor *)fg
                       bg:(NSColor *)bg
                      dim:(NSColor *)dim {
    (void)ctx; (void)bg; (void)dim;
    NSDictionary *tagAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: fg
    };
    [@"B" drawAtPoint:NSMakePoint(6.0, 63.5) withAttributes:tagAttrs];

    uint64_t fb = state.vfoBFrequencyHz > 0 ? state.vfoBFrequencyHz : 10100000;
    uint64_t mhz = fb / 1000000;
    uint64_t khz = (fb % 1000000) / 1000;
    uint64_t hz = fb % 1000;

    // In the photo: "10 100 000" spaced format
    NSString *vfoBStr = [NSString stringWithFormat:@"%llu %03llu %03llu", mhz, khz, hz];
    NSDictionary *vfoBAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: fg
    };
    [vfoBStr drawAtPoint:NSMakePoint(24.0, 62.0) withAttributes:vfoBAttrs];

    // VFO-B Mode: CWR or USB
    NSString *vfoBMode = state.vfoBMode ?: @"CWR";
    NSDictionary *bModeAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightBlack],
        NSForegroundColorAttributeName: fg
    };
    [vfoBMode drawAtPoint:NSMakePoint(118.0, 63.5) withAttributes:bModeAttrs];
}

// 5. S-Meter Calibration Scale & Segment Dots (y: 48 to 61)
+ (void)drawSMeterInContext:(CGContextRef)ctx
                      state:(TX500ScreenState *)state
                         fg:(NSColor *)fg
                         bg:(NSColor *)bg
                        dim:(NSColor *)dim {
    (void)ctx; (void)bg;
    // Letter 'S' indicator
    NSDictionary *sAttrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:8.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: fg
    };
    [@"S" drawAtPoint:NSMakePoint(6.0, 50.0) withAttributes:sAttrs];

    if (!state.isTransmitting) {
        // RX Mode S-Meter: "1 . . 3 . . 5 . . 7 . . 9 . 20 . 40 . 60"
        NSString *scaleText = @"1 . . 3 . . 5 . . 7 . . 9 . 20 . 40 . 60";
        NSDictionary *scaleAttrs = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:6.5 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: fg
        };
        [scaleText drawAtPoint:NSMakePoint(22.0, 54.5) withAttributes:scaleAttrs];

        // 30 discrete meter dot segments
        NSInteger activeDots = state.sMeterDots;
        if (activeDots < 0) activeDots = 0;
        if (activeDots > 30) activeDots = 30;

        CGFloat barX = 22.0;
        CGFloat barY = 49.0;
        for (NSInteger i = 0; i < 30; i++) {
            NSRect dot = NSMakeRect(barX + (i * 3.8), barY, 2.4, 3.5);
            if (i < activeDots) {
                [fg setFill];
            } else {
                [dim setFill];
            }
            NSRectFill(dot);
        }
    } else {
        // TX Mode: RF Power (PO) and SWR Meters
        NSDictionary *txScaleAttrs = @{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:6.5 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: fg
        };
        [@"PO   0 . 2 . 4 . 6 . 8 . 10W" drawAtPoint:NSMakePoint(22.0, 54.5) withAttributes:txScaleAttrs];

        NSInteger pwrDots = (NSInteger)((state.rfPowerWatts / 10.0) * 28.0);
        if (pwrDots < 1) pwrDots = 1;
        if (pwrDots > 30) pwrDots = 30;

        CGFloat barX = 22.0;
        CGFloat barY = 49.0;
        for (NSInteger i = 0; i < 30; i++) {
            NSRect dot = NSMakeRect(barX + (i * 3.8), barY, 2.4, 3.5);
            if (i < pwrDots) {
                [fg setFill];
            } else {
                [dim setFill];
            }
            NSRectFill(dot);
        }
    }
}

// 6. Panadapter Spectrum: Solid Filled Bars + Passband Brackets (y: 16 to 46)
+ (void)drawPanadapterInContext:(CGContextRef)ctx
                          state:(TX500ScreenState *)state
                             fg:(NSColor *)fg
                             bg:(NSColor *)bg
                            dim:(NSColor *)dim {
    (void)bg;
    CGFloat startX = 10.0;
    CGFloat endX = 246.0;
    CGFloat baselineY = 17.0;
    CGFloat maxH = 26.0;

    // Baseline axis
    [fg setStroke];
    CGContextSetLineWidth(ctx, 1.0);
    CGContextMoveToPoint(ctx, startX, baselineY);
    CGContextAddLineToPoint(ctx, endX, baselineY);
    CGContextStrokePath(ctx);

    // Filter passband brackets [       ] on the baseline
    CGFloat pbLeft = 94.0;
    CGFloat pbRight = 162.0;

    // Left bracket '['
    CGContextMoveToPoint(ctx, pbLeft + 2.0, baselineY + 5.0);
    CGContextAddLineToPoint(ctx, pbLeft, baselineY + 5.0);
    CGContextAddLineToPoint(ctx, pbLeft, baselineY - 2.0);
    CGContextStrokePath(ctx);

    // Right bracket ']'
    CGContextMoveToPoint(ctx, pbRight - 2.0, baselineY + 5.0);
    CGContextAddLineToPoint(ctx, pbRight, baselineY + 5.0);
    CGContextAddLineToPoint(ctx, pbRight, baselineY - 2.0);
    CGContextStrokePath(ctx);

    // Draw spectrum as solid filled columns (authentic Lab599 look)
    NSArray<NSNumber *> *amps = state.spectrumAmplitudes;
    NSUInteger count = amps.count;
    if (count == 0) return;

    CGFloat colW = (endX - startX) / (CGFloat)count;

    [fg setFill];
    for (NSUInteger i = 0; i < count; i++) {
        double val = [amps[i] doubleValue];
        if (val < 0.0) val = 0.0;
        if (val > 1.0) val = 1.0;

        CGFloat h = floor(val * maxH);
        if (h < 1.0) h = 1.0; // Noise floor floor

        CGFloat x = startX + (i * colW);
        NSRect barRect = NSMakeRect(x, baselineY, colW - 0.4, h);
        NSRectFill(barRect);
    }
}

// 7. Bottom Soft-Key Menu Bar (Aligned with 4 bottom physical buttons) (y: 2 to 14)
+ (void)drawBottomMenuBarInContext:(CGContextRef)ctx
                             state:(TX500ScreenState *)state
                                fg:(NSColor *)fg
                                bg:(NSColor *)bg
                               dim:(NSColor *)dim {
    (void)ctx; (void)bg; (void)dim;
    // Four soft keys matching the 4 physical buttons below LCD:
    // [ << ]   [ TONE ]   [ MON ]   [ >> ]
    NSArray *keys = state.softKeyLabels ?: @[@"<<", @"TONE", @"MON", @">>"];
    CGFloat colW = 58.0;
    CGFloat startX = 6.0;
    CGFloat y = 2.5;
    CGFloat h = 10.5;

    NSFont *font = [NSFont monospacedSystemFontOfSize:8.0 weight:NSFontWeightBold];
    NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
    style.alignment = NSTextAlignmentCenter;

    NSDictionary *attrs = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: fg,
        NSParagraphStyleAttributeName: style
    };

    for (NSUInteger i = 0; i < 4; i++) {
        NSString *txt = i < keys.count ? keys[i] : @"";
        CGFloat x = startX + (i * (colW + 4.0));

        // In the photo, there are subtle cell frames or centered text
        [txt drawInRect:NSMakeRect(x, y + 0.5, colW, h) withAttributes:attrs];

        // Subtle vertical separator between soft-keys
        if (i < 3) {
            [dim setStroke];
            CGFloat divX = x + colW + 2.0;
            NSBezierPath *sep = [NSBezierPath bezierPath];
            [sep moveToPoint:NSMakePoint(divX, y + 1.0)];
            [sep lineToPoint:NSMakePoint(divX, y + h - 1.0)];
            [sep setLineWidth:0.8];
            [sep stroke];
        }
    }
}

#pragma mark - Chassis Bezel Rendering (Milled Duralumin Front Plate)

+ (NSImage *)renderChassisImageWithState:(TX500ScreenState *)state
                                   theme:(TX500ScreenTheme)theme
                               pixelGrid:(BOOL)pixelGrid {
    return [self renderChassisImageWithState:state
                                       theme:theme
                                   pixelGrid:pixelGrid
                               pressedButton:TX500ControlNone
                                   tuneAngle:0.0
                                 afGainAngle:0.0];
}

+ (NSImage *)renderChassisImageWithState:(TX500ScreenState *)state
                                   theme:(TX500ScreenTheme)theme
                               pixelGrid:(BOOL)pixelGrid
                           pressedButton:(NSInteger)pressedTag
                               tuneAngle:(CGFloat)tuneAngle
                             afGainAngle:(CGFloat)afGainAngle {
    return [self renderChassisImageWithState:state
                                       theme:theme
                                   pixelGrid:pixelGrid
                               pressedButton:pressedTag
                                   tuneAngle:tuneAngle
                                 afGainAngle:afGainAngle
                                ritXITAngle:0.0];
}

+ (NSImage *)renderChassisImageWithState:(TX500ScreenState *)state
                                   theme:(TX500ScreenTheme)theme
                               pixelGrid:(BOOL)pixelGrid
                           pressedButton:(NSInteger)pressedTag
                               tuneAngle:(CGFloat)tuneAngle
                             afGainAngle:(CGFloat)afGainAngle
                             ritXITAngle:(CGFloat)ritXITAngle {
    NSSize chassisSize = [self nativeChassisSize]; // 840 x 440
    NSImage *image = [[NSImage alloc] initWithSize:chassisSize];
    [image lockFocus];

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];

    // 1. Overall Dark CNC Anodized Duralumin Chassis
    NSRect chassisRect = NSMakeRect(0, 0, chassisSize.width, chassisSize.height);
    NSColor *cncBlack = [NSColor colorWithCalibratedRed:0.09 green:0.095 blue:0.105 alpha:1.0];
    [cncBlack setFill];
    NSBezierPath *chassisPath = [NSBezierPath bezierPathWithRoundedRect:chassisRect xRadius:14.0 yRadius:14.0];
    [chassisPath fill];

    // Milled 45-degree chamfer highlight stroke
    [[NSColor colorWithCalibratedWhite:0.25 alpha:1.0] setStroke];
    chassisPath.lineWidth = 1.5;
    [chassisPath stroke];

    // Inner bevel inset
    NSRect innerFace = NSInsetRect(chassisRect, 5.0, 5.0);
    [[NSColor colorWithCalibratedWhite:0.06 alpha:1.0] setStroke];
    NSBezierPath *innerPath = [NSBezierPath bezierPathWithRoundedRect:innerFace xRadius:10.0 yRadius:10.0];
    innerPath.lineWidth = 1.0;
    [innerPath stroke];

    // 2. Left Flank Connector Markings (DC 9-15V, REM/DATA, MIC/SP)
    [self drawLeftConnectorMarkingsInContext:ctx];

    // 3. Four Stainless Steel Hex Socket Cap Screws (Corners)
    [self drawHexScrewAtPoint:NSMakePoint(26.0, chassisSize.height - 30.0) inContext:ctx];
    [self drawHexScrewAtPoint:NSMakePoint(26.0, 30.0) inContext:ctx];
    [self drawHexScrewAtPoint:NSMakePoint(562.0, chassisSize.height - 30.0) inContext:ctx];
    [self drawHexScrewAtPoint:NSMakePoint(562.0, 30.0) inContext:ctx];

    // 4. Center LCD Glass Bezel Area
    // Inset frame: x: 66, y: 56, width: 488, height: 326
    NSRect glassFrame = NSMakeRect(66.0, 56.0, 488.0, 326.0);

    // Deep recessed frame around glass
    [[NSColor colorWithCalibratedWhite:0.03 alpha:1.0] setFill];
    NSBezierPath *recessPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(glassFrame, -4.0, -4.0) xRadius:8.0 yRadius:8.0];
    [recessPath fill];
    [[NSColor colorWithCalibratedWhite:0.18 alpha:1.0] setStroke];
    recessPath.lineWidth = 1.0;
    [recessPath stroke];

    // Dark protective glass face
    [[NSColor colorWithCalibratedRed:0.07 green:0.07 blue:0.08 alpha:1.0] setFill];
    NSBezierPath *glassPath = [NSBezierPath bezierPathWithRoundedRect:glassFrame xRadius:6.0 yRadius:6.0];
    [glassPath fill];

    // 5. Active LCD Screen (256 x 128 rendered to authentically fill window)
    // Gap to top bezel reduced to ~1/4 (~11.5px) matching physical TX-500 Discovery front panel
    CGFloat topGap = 11.5;
    CGFloat lcdW = 472.0;
    CGFloat lcdH = 268.0;
    CGFloat lcdX = glassFrame.origin.x + (glassFrame.size.width - lcdW) / 2.0;
    CGFloat lcdY = NSMaxY(glassFrame) - topGap - lcdH; // 382.0 - 11.5 - 268.0 = 102.5
    NSRect lcdTargetRect = NSMakeRect(lcdX, lcdY, lcdW, lcdH);

    NSImage *screenImg = [self renderScreenImageWithState:state theme:theme scale:2.0 pixelGrid:pixelGrid];
    if (screenImg) {
        CGContextSaveGState(ctx);
        // Crisp drawing of LCD
        [screenImg drawInRect:lcdTargetRect
                     fromRect:NSMakeRect(0, 0, screenImg.size.width, screenImg.size.height)
                    operation:NSCompositingOperationSourceOver
                     fraction:1.0
                respectFlipped:NO
                         hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        CGContextRestoreGState(ctx);

        // Inner shadow around LCD edge (rounded corners matching real radio LCD mask)
        [[NSColor colorWithCalibratedWhite:0.0 alpha:0.40] setStroke];
        NSBezierPath *lcdBorder = [NSBezierPath bezierPathWithRoundedRect:lcdTargetRect xRadius:4.0 yRadius:4.0];
        lcdBorder.lineWidth = 1.0;
        [lcdBorder stroke];
    }


    // 6. Brand Inscription & Logo Under LCD (On the Glass Border)
    // Vertically centered between bottom glass border and active LCD bottom edge
    NSRect brandBandRect = NSMakeRect(glassFrame.origin.x + 14.0,
                                      glassFrame.origin.y,
                                      glassFrame.size.width - 28.0,
                                      lcdY - glassFrame.origin.y);
    [self drawGlassBrandAndLogoAtRect:brandBandRect];

    // 7. Four Top Physical Buttons (Above LCD)
    // Shifted UP to be horizontally parallel and aligned with the two top corner screws (center y = 410.0)
    CGFloat topBtnH = 15.0;
    CGFloat topScrewY = chassisSize.height - 30.0; // 410.0
    CGFloat topBtnY = topScrewY - (topBtnH / 2.0); // 402.5
    [self drawFourPhysicalButtonsInContext:ctx
                                    startX:glassFrame.origin.x + 20.0
                                         y:topBtnY
                                     width:glassFrame.size.width - 40.0
                                     isTop:YES
                                pressedTag:pressedTag];

    // 8. Four Bottom Physical Buttons (Below Glass Bezel)
    // Bottom buttons: top edge at glassFrame.origin.y - 22 = 34, bottom = 34-15=19
    [self drawFourPhysicalButtonsInContext:ctx
                                    startX:glassFrame.origin.x + 20.0
                                         y:glassFrame.origin.y - 22.0 - 15.0
                                     width:glassFrame.size.width - 40.0
                                     isTop:NO
                                pressedTag:pressedTag];

    // 9. Right-Side Controls: Model Title, Buttons, Knobs, Far-Right Round Buttons, Connectors
    [self drawRightControlPanelInContext:ctx
                                  startX:572.0
                           chassisHeight:chassisSize.height
                               modelName:state.hardwareModelName ?: @"DISCOVERY"
                              pressedTag:pressedTag
                               tuneAngle:tuneAngle
                             afGainAngle:afGainAngle
                             ritXITAngle:ritXITAngle];



    // 10. Rounded border around LCD panel (matching real radio rounded corners)
    CGContextSaveGState(ctx);
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.45] setStroke];
    NSBezierPath *lcdBorder = [NSBezierPath bezierPathWithRoundedRect:lcdTargetRect xRadius:4.0 yRadius:4.0];
    lcdBorder.lineWidth = 1.5;
    [lcdBorder stroke];
    CGContextRestoreGState(ctx);

    [image unlockFocus];
    return image;
}

#pragma mark - Chassis Components Helper Drawings

// Left Flank Connector Markings: DC 9-15V, REM/DATA, MIC/SP
+ (void)drawLeftConnectorMarkingsInContext:(CGContextRef)ctx {
    (void)ctx;
    NSDictionary *lblAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.65 alpha:1.0]
    };

    [@"DC 9-15V" drawAtPoint:NSMakePoint(14.0, 316.0) withAttributes:lblAttrs];
    [@"REM /" drawAtPoint:NSMakePoint(16.0, 206.0) withAttributes:lblAttrs];
    [@"DATA" drawAtPoint:NSMakePoint(16.0, 194.0) withAttributes:lblAttrs];
    [@"MIC/SP" drawAtPoint:NSMakePoint(14.0, 84.0) withAttributes:lblAttrs];
}

// Four Oval/Capsule Physical Buttons (Top and Bottom)
+ (void)drawFourPhysicalButtonsInContext:(CGContextRef)ctx
                                  startX:(CGFloat)startX
                                       y:(CGFloat)y
                                   width:(CGFloat)totalW
                                   isTop:(BOOL)isTop
                              pressedTag:(NSInteger)pressedTag {
    CGFloat btnW = 54.0;
    CGFloat btnH = 15.0;
    CGFloat spacing = (totalW - (4.0 * btnW)) / 3.0;

    for (NSUInteger i = 0; i < 4; i++) {
        CGFloat x = startX + (i * (btnW + spacing));
        NSRect btnRect = NSMakeRect(x, y, btnW, btnH);
        NSInteger currentTag = isTop ? (21 + (NSInteger)i) : (31 + (NSInteger)i);
        BOOL isPressed = (pressedTag == currentTag);

        // Recessed cavity under button
        NSRect cavityRect = NSInsetRect(btnRect, -1.5, -1.5);
        [[NSColor colorWithCalibratedWhite:0.04 alpha:1.0] setFill];
        NSBezierPath *cavity = [NSBezierPath bezierPathWithRoundedRect:cavityRect xRadius:8.5 yRadius:8.5];
        [cavity fill];

        if (isPressed) {
            // Luminous golden-amber / cyan backlight glow halo
            CGContextSaveGState(ctx);
            NSColor *glow = [NSColor colorWithCalibratedRed:1.0 green:0.75 blue:0.25 alpha:0.95];
            CGContextSetShadowWithColor(ctx, CGSizeZero, 12.0, glow.CGColor);
            NSBezierPath *halo = [NSBezierPath bezierPathWithRoundedRect:btnRect xRadius:7.5 yRadius:7.5];
            [glow setFill];
            [halo fill];
            CGContextRestoreGState(ctx);

            // Depressed rubber capsule button body
            NSRect pressedRect = NSMakeRect(btnRect.origin.x, btnRect.origin.y - 1.5, btnRect.size.width, btnRect.size.height);
            NSBezierPath *btnPath = [NSBezierPath bezierPathWithRoundedRect:pressedRect xRadius:7.5 yRadius:7.5];
            NSGradient *btnGrad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.10 alpha:1.0]
                                                                endingColor:[NSColor colorWithCalibratedWhite:0.18 alpha:1.0]];
            [btnGrad drawInBezierPath:btnPath angle:270.0];

            [glow setStroke];
            btnPath.lineWidth = 1.5;
            [btnPath stroke];
        } else {
            // Textured rubber capsule button body
            NSBezierPath *btnPath = [NSBezierPath bezierPathWithRoundedRect:btnRect xRadius:7.5 yRadius:7.5];
            NSGradient *btnGrad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.22 alpha:1.0]
                                                                endingColor:[NSColor colorWithCalibratedWhite:0.12 alpha:1.0]];
            [btnGrad drawInBezierPath:btnPath angle:90.0];

            // Top edge highlight
            [[NSColor colorWithCalibratedWhite:0.32 alpha:1.0] setStroke];
            btnPath.lineWidth = 1.0;
            [btnPath stroke];
        }
    }
}

// Brand Inscription Under LCD: "lab 599" logo and "HF/50MHz TRANSCEIVER"
+ (void)drawGlassBrandAndLogoAtRect:(NSRect)rect {
    // Left: Official "lab 599" graphic logo
    NSImage *logoImg = [NSImage imageNamed:@"lab599_logo"];
    if (!logoImg) {
        NSString *p = [[NSBundle mainBundle] pathForResource:@"lab599_logo" ofType:@"png"];
        if (p) logoImg = [[NSImage alloc] initWithContentsOfFile:p];
    }
    if (!logoImg) {
        logoImg = [[NSImage alloc] initWithContentsOfFile:@"Resources/lab599_logo.png"];
    }

    if (logoImg) {
        CGFloat targetH = 27.0;   // 1.5× the previous 18pt
        CGFloat aspect = 648.0 / 234.0; // 2.769
        CGFloat targetW = targetH * aspect;
        CGFloat logoY = rect.origin.y + (rect.size.height - targetH) / 2.0;
        NSRect logoRect = NSMakeRect(rect.origin.x, logoY, targetW, targetH);
        [logoImg drawInRect:logoRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0];
    } else {
        NSFont *logoFont = [NSFont systemFontOfSize:22.0 weight:NSFontWeightBlack];
        NSDictionary *labAttrs = @{
            NSFontAttributeName: logoFont,
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.92 alpha:1.0]
        };
        NSDictionary *redAttrs = @{
            NSFontAttributeName: logoFont,
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.92 green:0.18 blue:0.18 alpha:1.0]
        };
        CGFloat logoFallbackY = rect.origin.y + (rect.size.height - 24.0) / 2.0;
        [@"lab" drawAtPoint:NSMakePoint(rect.origin.x, logoFallbackY) withAttributes:labAttrs];
        [@"599" drawAtPoint:NSMakePoint(rect.origin.x + 48.0, logoFallbackY) withAttributes:redAttrs];
    }

    // Right: "HF/50MHz TRANSCEIVER" (1.2× larger = 17.1pt, precisely vertically centered)
    NSDictionary *subAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:17.1 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.78 alpha:1.0]
    };
    NSString *subText = @"HF/50MHz TRANSCEIVER";
    NSSize textSize = [subText sizeWithAttributes:subAttrs];
    CGFloat subY = rect.origin.y + (rect.size.height - textSize.height) / 2.0 + 0.5;
    [subText drawAtPoint:NSMakePoint(NSMaxX(rect) - textSize.width, subY) withAttributes:subAttrs];
}

// Hex Socket Head Cap Screw (Countersunk washer + 6-sided hex socket)
+ (void)drawHexScrewAtPoint:(NSPoint)center inContext:(CGContextRef)ctx {
    CGFloat radius = 8.5;
    NSRect outer = NSMakeRect(center.x - radius, center.y - radius, radius * 2.0, radius * 2.0);

    // Silver washer / screw head
    NSGradient *screwGrad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.75 alpha:1.0]
                                                          endingColor:[NSColor colorWithCalibratedWhite:0.35 alpha:1.0]];
    NSBezierPath *head = [NSBezierPath bezierPathWithOvalInRect:outer];
    [screwGrad drawInBezierPath:head angle:45.0];

    [[NSColor colorWithCalibratedWhite:0.20 alpha:1.0] setStroke];
    head.lineWidth = 1.0;
    [head stroke];

    // Inner 6-sided Hexagonal Socket
    CGFloat hexR = 4.2;
    CGContextSaveGState(ctx);
    [[NSColor colorWithCalibratedWhite:0.10 alpha:1.0] setFill];
    CGContextBeginPath(ctx);
    for (int i = 0; i < 6; i++) {
        CGFloat angle = i * (M_PI / 3.0);
        CGFloat hx = center.x + hexR * cos(angle);
        CGFloat hy = center.y + hexR * sin(angle);
        if (i == 0) CGContextMoveToPoint(ctx, hx, hy);
        else CGContextAddLineToPoint(ctx, hx, hy);
    }
    CGContextClosePath(ctx);
    CGContextFillPath(ctx);
    CGContextRestoreGState(ctx);
}

// Right Control Panel — Faithful TX-500 Discovery layout
// Layout (left→right in right section, startX≈610):
//   Col A (startX+5):  Buttons POWER/BAND+/BAND-/MODE/FILTER/MENU
//   Col B (x≈675):     AF GAIN small knob + label
//   Col C (x≈728):     RIT/XIT small knob + label
//   Centered (x≈702):  TUNE/MULTI large knob label below col B/C gap
//   Far right (x≈772): Round buttons R/X, CLR, V/M, LOCK🔒, +, -
//   Edge (x≈818):      Connectors ANT, CAT, CW KEY (graphics only)
+ (void)drawRightControlPanelInContext:(CGContextRef)ctx
                                startX:(CGFloat)startX
                         chassisHeight:(CGFloat)chassisH
                             modelName:(NSString *)modelName
                            pressedTag:(NSInteger)pressedTag
                             tuneAngle:(CGFloat)tuneAngle
                           afGainAngle:(CGFloat)afGainAngle
                           ritXITAngle:(CGFloat)ritXITAngle {

    // ── Model Title (e.g. DISCOVERY, TX-500MP, TX-500PRO, PRO ALTAI) ─────────
    NSString *discStr = modelName.length > 0 ? modelName : @"DISCOVERY";
    NSDictionary *discAttrs = @{
        NSFontAttributeName: [NSFont fontWithName:@"Helvetica-BoldOblique" size:13.5] ?: [NSFont systemFontOfSize:13.5 weight:NSFontWeightBlack],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.86 alpha:1.0]
    };
    NSSize discSize = [discStr sizeWithAttributes:discAttrs];
    // Center title directly over the middle knob area (centered at x = 685)
    CGFloat discX = 685.0 - (discSize.width / 2.0);
    [discStr drawAtPoint:NSMakePoint(discX, chassisH - 42.0) withAttributes:discAttrs];

    // ── Authentic Hex Allen Screws on chassis milled ridges ──────────────────
    [self drawHexScrewAtPoint:NSMakePoint(816.0, chassisH - 52.0) inContext:ctx];
    [self drawHexScrewAtPoint:NSMakePoint(816.0, 52.0) inContext:ctx];

    // ── Vertical separator line between LCD section and right panel ──────────
    CGContextSaveGState(ctx);
    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithCalibratedWhite:0.22 alpha:1.0].CGColor);
    CGContextSetLineWidth(ctx, 1.0);
    CGContextMoveToPoint(ctx, startX - 2.0, chassisH - 28.0);
    CGContextAddLineToPoint(ctx, startX - 2.0, 28.0);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);

    // ══ COLUMN A: Six capsule buttons (POWER, BAND+, BAND-, MODE, FILTER, MENU) ══
    // Placed at x=576..622, completely separated from knobs (which start at x>=636)
    NSArray *btnNames = @[@"POWER", @"BAND+", @"BAND-", @"MODE", @"FILTER", @"MENU"];
    CGFloat btnW = 46.0;
    CGFloat btnH = 22.0;
    CGFloat btnX = startX + 4.0; // 576.0
    CGFloat btnTopY = 346.0;
    CGFloat btnSpacing = 52.0;

    for (NSUInteger i = 0; i < btnNames.count; i++) {
        NSString *name = btnNames[i];
        NSInteger currentTag = (NSInteger)(i + 1);
        CGFloat by = btnTopY - (CGFloat)i * btnSpacing;
        NSRect btnRect = NSMakeRect(btnX, by, btnW, btnH);
        BOOL isPressed = (pressedTag == currentTag);

        // Recessed cavity — authentic capsule shape
        [[NSColor colorWithCalibratedWhite:0.04 alpha:1.0] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(btnRect, -2, -2) xRadius:btnH/2.0+1.0 yRadius:btnH/2.0+1.0] fill];

        if (isPressed) {
            CGContextSaveGState(ctx);
            NSColor *glow = (currentTag == 1)
                ? [NSColor colorWithCalibratedRed:1.0 green:0.22 blue:0.22 alpha:0.95]
                : [NSColor colorWithCalibratedRed:0.0 green:0.85 blue:1.0 alpha:0.95];
            CGContextSetShadowWithColor(ctx, CGSizeZero, 14.0, glow.CGColor);
            NSBezierPath *halo = [NSBezierPath bezierPathWithRoundedRect:btnRect xRadius:btnH/2.0 yRadius:btnH/2.0];
            [glow setFill]; [halo fill];
            CGContextRestoreGState(ctx);

            NSRect pr = NSMakeRect(btnRect.origin.x, btnRect.origin.y - 1.5, btnW, btnH);
            NSBezierPath *btn = [NSBezierPath bezierPathWithRoundedRect:pr xRadius:btnH/2.0 yRadius:btnH/2.0];
            [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.10 alpha:1.0]
                                           endingColor:[NSColor colorWithCalibratedWhite:0.18 alpha:1.0]]
             drawInBezierPath:btn angle:270.0];
            NSColor *glow2 = (currentTag == 1)
                ? [NSColor colorWithCalibratedRed:1.0 green:0.22 blue:0.22 alpha:0.95]
                : [NSColor colorWithCalibratedRed:0.0 green:0.85 blue:1.0 alpha:0.95];
            [glow2 setStroke]; btn.lineWidth = 1.5; [btn stroke];

            NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
            NSColor *tc = (currentTag == 1)
                ? [NSColor colorWithCalibratedRed:1.0 green:0.40 blue:0.40 alpha:1.0]
                : [NSColor colorWithCalibratedRed:0.85 green:0.95 blue:1.0 alpha:1.0];
            NSDictionary *ta = @{ NSFontAttributeName: [NSFont systemFontOfSize:8.0 weight:NSFontWeightBold],
                                  NSForegroundColorAttributeName: tc, NSParagraphStyleAttributeName: ps };
            NSSize ts = [name sizeWithAttributes:ta];
            [name drawInRect:NSMakeRect(pr.origin.x, pr.origin.y + (btnH-ts.height)/2.0, btnW, ts.height) withAttributes:ta];
        } else {
            NSBezierPath *btn = [NSBezierPath bezierPathWithRoundedRect:btnRect xRadius:btnH/2.0 yRadius:btnH/2.0];
            [[[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.24 alpha:1.0]
                                           endingColor:[NSColor colorWithCalibratedWhite:0.14 alpha:1.0]]
             drawInBezierPath:btn angle:90.0];
            [[NSColor colorWithCalibratedWhite:0.32 alpha:1.0] setStroke]; btn.lineWidth = 1.0; [btn stroke];

            NSColor *tc = [name isEqualToString:@"POWER"]
                ? [NSColor colorWithCalibratedRed:0.95 green:0.25 blue:0.25 alpha:1.0]
                : [NSColor colorWithCalibratedWhite:0.88 alpha:1.0];
            NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
            NSDictionary *ta = @{ NSFontAttributeName: [NSFont systemFontOfSize:8.0 weight:NSFontWeightBold],
                                  NSForegroundColorAttributeName: tc, NSParagraphStyleAttributeName: ps };
            NSSize ts = [name sizeWithAttributes:ta];
            [name drawInRect:NSMakeRect(btnRect.origin.x, btnRect.origin.y + (btnH-ts.height)/2.0, btnW, ts.height) withAttributes:ta];
        }
    }

    // ══ COLUMN B & C: AF GAIN & RIT/XIT small knobs side by side ══
    // Center AF GAIN: (658, 315), radius 22 -> span [636..680] (14px gap from buttons at x=622!)
    NSPoint afCenter = NSMakePoint(658.0, 315.0);
    BOOL isAFPressed = (pressedTag == TX500ControlAFGainKnob);
    [self drawRotaryKnobAtPoint:afCenter radius:22.0 label:@"AF GAIN"
                      hasDimple:NO angle:afGainAngle isPressed:isAFPressed inContext:ctx];

    // Center RIT/XIT: (712, 315), radius 22 -> span [690..734] (10px gap between knobs!)
    NSPoint ritCenter = NSMakePoint(712.0, 315.0);
    BOOL isRITPressed = (pressedTag == TX500ControlRITXITKnob);
    [self drawRotaryKnobAtPoint:ritCenter radius:22.0 label:@"RIT / XIT"
                      hasDimple:NO angle:ritXITAngle isPressed:isRITPressed inContext:ctx];

    // ══ TUNE/MULTI large knob centered below AF GAIN & RIT/XIT ══
    // Center: (685, 168), radius 46 -> span [639..731] (17px gap from buttons, 20px gap from round buttons!)
    CGFloat tuneX = (afCenter.x + ritCenter.x) / 2.0; // 685.0
    CGFloat tuneY = 168.0;
    BOOL isTunePressed = (pressedTag == TX500ControlTuneKnob);
    [self drawRotaryKnobAtPoint:NSMakePoint(tuneX, tuneY) radius:46.0 label:@"TUNE / MULTI"
                      hasDimple:YES angle:tuneAngle isPressed:isTunePressed inContext:ctx];

    // ══ FAR-RIGHT: Small ROUND buttons (R/X, CLR, V/M, LOCK🔒, +, -) ══
    // Center: x = 762.0, radius = 11.0 -> span [751..773]
    CGFloat roundBtnCX = 762.0;
    CGFloat roundBtnR  = 11.0;
    NSArray *roundBtnLabels = @[@"R/X", @"CLR", @"V/M", @"", @"+", @"-"];
    NSArray *roundBtnTags   = @[@(TX500ControlRX), @(TX500ControlClear), @(TX500ControlVM),
                                @(TX500ControlLock), @(TX500ControlPlus), @(TX500ControlMinus)];

    for (NSUInteger i = 0; i < roundBtnLabels.count; i++) {
        NSString *blabel = roundBtnLabels[i];
        NSInteger btag   = [roundBtnTags[i] integerValue];
        // Perfectly aligned horizontally with corresponding capsule button
        CGFloat by = btnTopY - (CGFloat)i * btnSpacing;
        CGFloat cy = by + (btnH / 2.0);
        NSPoint bc = NSMakePoint(roundBtnCX, cy);
        BOOL bPressed = (pressedTag == btag);

        NSRect circRect = NSMakeRect(bc.x - roundBtnR, bc.y - roundBtnR, roundBtnR*2, roundBtnR*2);

        // Recessed cavity
        [[NSColor colorWithCalibratedWhite:0.04 alpha:1.0] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circRect, -2.5, -2.5)] fill];

        if (bPressed) {
            CGContextSaveGState(ctx);
            NSColor *glow = (btag == TX500ControlRX)
                ? [NSColor colorWithCalibratedRed:1.0 green:0.2 blue:0.2 alpha:0.9]
                : [NSColor colorWithCalibratedRed:0.0 green:0.85 blue:1.0 alpha:0.9];
            CGContextSetShadowWithColor(ctx, CGSizeZero, 12.0, glow.CGColor);
            NSBezierPath *circ = [NSBezierPath bezierPathWithOvalInRect:circRect];
            [glow setFill]; [circ fill];
            CGContextRestoreGState(ctx);
        } else {
            NSBezierPath *circ = [NSBezierPath bezierPathWithOvalInRect:circRect];
            CGContextSaveGState(ctx);
            [circ addClip];
            NSGradient *grad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.35 alpha:1.0]
                                                             endingColor:[NSColor colorWithCalibratedWhite:0.14 alpha:1.0]];
            [grad drawInRect:circRect angle:90.0];
            CGContextRestoreGState(ctx);
            [[NSColor colorWithCalibratedWhite:0.40 alpha:1.0] setStroke];
            circ.lineWidth = 0.8;
            [circ stroke];
            // Highlight arc on top
            CGContextSaveGState(ctx);
            [[NSColor colorWithCalibratedWhite:0.65 alpha:0.45] setStroke];
            CGContextSetLineWidth(ctx, 1.0);
            CGContextBeginPath(ctx);
            CGContextAddArc(ctx, bc.x, bc.y, roundBtnR - 2.0, M_PI*0.2, M_PI*0.8, 0);
            CGContextStrokePath(ctx);
            CGContextRestoreGState(ctx);
        }

        // Button label or padlock icon
        if (btag == TX500ControlLock) {
            // Authentic Padlock Icon on button face
            NSColor *lockColor = bPressed
                ? [NSColor colorWithCalibratedRed:1.0 green:0.75 blue:0.20 alpha:1.0]
                : [NSColor colorWithCalibratedWhite:0.88 alpha:1.0];

            // 1. Shackle (arched loop on top)
            NSBezierPath *shackle = [NSBezierPath bezierPath];
            shackle.lineWidth = 1.8;
            shackle.lineCapStyle = NSLineCapStyleRound;
            [shackle moveToPoint:NSMakePoint(bc.x - 3.2, bc.y - 0.2)];
            [shackle lineToPoint:NSMakePoint(bc.x - 3.2, bc.y + 2.8)];
            [shackle appendBezierPathWithArcWithCenter:NSMakePoint(bc.x, bc.y + 2.8)
                                                radius:3.2
                                            startAngle:180.0
                                              endAngle:0.0
                                             clockwise:YES];
            [shackle lineToPoint:NSMakePoint(bc.x + 3.2, bc.y - 0.2)];
            [lockColor setStroke];
            [shackle stroke];

            // 2. Lock Body (solid block at bottom)
            NSRect bodyRect = NSMakeRect(bc.x - 5.0, bc.y - 5.8, 10.0, 7.2);
            NSBezierPath *body = [NSBezierPath bezierPathWithRoundedRect:bodyRect xRadius:1.5 yRadius:1.5];
            [lockColor setFill];
            [body fill];

            // 3. Keyhole (circular hole + vertical key slot)
            NSColor *holeColor = [NSColor colorWithCalibratedWhite:0.12 alpha:1.0];
            [holeColor setFill];
            NSBezierPath *holeDot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(bc.x - 0.9, bc.y - 2.8, 1.8, 1.8)];
            [holeDot fill];
            NSBezierPath *holeSlot = [NSBezierPath bezierPathWithRect:NSMakeRect(bc.x - 0.5, bc.y - 4.5, 1.0, 2.0)];
            [holeSlot fill];
        } else if (blabel.length > 0) {

            NSColor *tc;
            if (btag == TX500ControlRX)
                tc = bPressed ? [NSColor whiteColor] : [NSColor colorWithCalibratedRed:0.95 green:0.30 blue:0.30 alpha:1.0];
            else if (btag == TX500ControlPlus || btag == TX500ControlMinus)
                tc = bPressed ? [NSColor whiteColor] : [NSColor colorWithCalibratedRed:0.40 green:0.90 blue:1.0 alpha:1.0];
            else
                tc = bPressed ? [NSColor whiteColor] : [NSColor colorWithCalibratedWhite:0.85 alpha:1.0];

            NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter;
            NSDictionary *ta = @{ NSFontAttributeName: [NSFont systemFontOfSize:6.8 weight:NSFontWeightBold],
                                  NSForegroundColorAttributeName: tc, NSParagraphStyleAttributeName: ps };
            NSSize ts = [blabel sizeWithAttributes:ta];
            [blabel drawInRect:NSMakeRect(bc.x - roundBtnR, bc.y - ts.height/2.0, roundBtnR*2, ts.height) withAttributes:ta];
        }
    }

    // ══ FAR-RIGHT: Vertical separator line before connectors ══
    CGFloat farSepX = 782.0;
    CGContextSaveGState(ctx);
    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithCalibratedWhite:0.25 alpha:1.0].CGColor);
    CGContextSetLineWidth(ctx, 0.8);
    CGContextMoveToPoint(ctx, farSepX, chassisH - 28.0);
    CGContextAddLineToPoint(ctx, farSepX, 28.0);
    CGContextStrokePath(ctx);
    CGContextRestoreGState(ctx);

    // ══ FAR-RIGHT EDGE: Connector Markings (ANT, CAT, CW KEY) — Pure text markings matching left flank ══
    NSDictionary *connLblAttrs = @{
        NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.65 alpha:1.0]
    };
    CGFloat connCenterX = 808.0;

    NSArray *rightConnLabels = @[
        @{@"text": @"ANT", @"y": @(350.0)},
        @{@"text": @"CAT", @"y": @(227.0)},
        @{@"text": @"CW KEY", @"y": @(100.0)}
    ];

    for (NSDictionary *conn in rightConnLabels) {
        NSString *lbl = conn[@"text"];
        CGFloat ly = [conn[@"y"] doubleValue];
        NSSize ls = [lbl sizeWithAttributes:connLblAttrs];
        [lbl drawAtPoint:NSMakePoint(connCenterX - (ls.width / 2.0), ly - (ls.height / 2.0)) withAttributes:connLblAttrs];
    }
}


// Rotary Knob with Knurled Rim, Face, and Finger Dimple / Pointer
+ (void)drawRotaryKnobAtPoint:(NSPoint)center
                       radius:(CGFloat)radius
                        label:(NSString *)label
                    hasDimple:(BOOL)hasDimple
                        angle:(CGFloat)angle
                    isPressed:(BOOL)isPressed
                    inContext:(CGContextRef)ctx {
    NSRect outer = NSMakeRect(center.x - radius, center.y - radius, radius * 2.0, radius * 2.0);

    // Recessed dark cavity behind knob
    NSRect cavity = NSInsetRect(outer, -2.0, -2.0);
    [[NSColor colorWithCalibratedWhite:0.04 alpha:1.0] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:cavity] fill];

    // If pressed or interacting, draw luminous neon cyan halo around the knob
    if (isPressed) {
        CGContextSaveGState(ctx);
        NSColor *knobGlow = [NSColor colorWithCalibratedRed:0.0 green:0.80 blue:1.0 alpha:0.85];
        CGContextSetShadowWithColor(ctx, CGSizeZero, 16.0, knobGlow.CGColor);
        NSBezierPath *glowOval = [NSBezierPath bezierPathWithOvalInRect:outer];
        [knobGlow setFill];
        [glowOval fill];
        CGContextRestoreGState(ctx);
    }

    // Knurled outer rim
    [[NSColor colorWithCalibratedWhite:0.14 alpha:1.0] setFill];
    NSBezierPath *rim = [NSBezierPath bezierPathWithOvalInRect:outer];
    [rim fill];
    [[NSColor colorWithCalibratedWhite:0.32 alpha:1.0] setStroke];
    rim.lineWidth = 1.5;
    [rim stroke];

    // Knurling radial notches around the perimeter rotating with angle
    NSInteger numKnurls = hasDimple ? 32 : 24;
    CGContextSaveGState(ctx);
    [[NSColor colorWithCalibratedWhite:0.24 alpha:0.85] setStroke];
    for (NSInteger k = 0; k < numKnurls; k++) {
        CGFloat th = (CGFloat)k * (2.0 * M_PI / (CGFloat)numKnurls) + angle;
        CGFloat x1 = center.x + (radius - 3.5) * cos(th);
        CGFloat y1 = center.y + (radius - 3.5) * sin(th);
        CGFloat x2 = center.x + radius * cos(th);
        CGFloat y2 = center.y + radius * sin(th);
        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, x1, y1);
        CGContextAddLineToPoint(ctx, x2, y2);
        CGContextSetLineWidth(ctx, 1.0);
        CGContextStrokePath(ctx);
    }
    CGContextRestoreGState(ctx);

    // Inner metallic knob face
    NSRect inner = NSInsetRect(outer, 4.0, 4.0);
    NSGradient *knobGrad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.26 alpha:1.0]
                                                         endingColor:[NSColor colorWithCalibratedWhite:0.12 alpha:1.0]];
    NSBezierPath *face = [NSBezierPath bezierPathWithOvalInRect:inner];
    [knobGrad drawInBezierPath:face angle:60.0];

    // Finger dimple indentation (for TUNE dial) with rotating position
    if (hasDimple) {
        CGFloat dimpleR = radius * 0.28;
        CGFloat d = radius * 0.52;
        NSPoint dimpleCenter = NSMakePoint(center.x + d * cos(angle), center.y + d * sin(angle));
        NSRect dimpleRect = NSMakeRect(dimpleCenter.x - dimpleR, dimpleCenter.y - dimpleR, dimpleR * 2.0, dimpleR * 2.0);

        NSGradient *dimpleGrad = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithCalibratedWhite:0.07 alpha:1.0]
                                                               endingColor:[NSColor colorWithCalibratedWhite:0.22 alpha:1.0]];
        NSBezierPath *dimple = [NSBezierPath bezierPathWithOvalInRect:dimpleRect];
        [dimpleGrad drawInBezierPath:dimple angle:240.0];
        [[NSColor colorWithCalibratedWhite:0.35 alpha:1.0] setStroke];
        dimple.lineWidth = 0.8;
        [dimple stroke];
    } else {
        // Metallic pointer line for AF GAIN dial
        CGFloat rInner = 8.0;
        CGFloat rOuter = radius - 6.0;
        CGFloat px1 = center.x + rInner * cos(angle);
        CGFloat py1 = center.y + rInner * sin(angle);
        CGFloat px2 = center.x + rOuter * cos(angle);
        CGFloat py2 = center.y + rOuter * sin(angle);

        CGContextSaveGState(ctx);
        [[NSColor colorWithCalibratedWhite:0.85 alpha:1.0] setStroke];
        CGContextBeginPath(ctx);
        CGContextMoveToPoint(ctx, px1, py1);
        CGContextAddLineToPoint(ctx, px2, py2);
        CGContextSetLineWidth(ctx, 2.0);
        CGContextSetLineCap(ctx, kCGLineCapRound);
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    }

    // Label below knob
    if (label.length) {
        NSMutableParagraphStyle *style = [NSMutableParagraphStyle new];
        style.alignment = NSTextAlignmentCenter;
        NSDictionary *lblAttrs = @{
            NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.75 alpha:1.0],
            NSParagraphStyleAttributeName: style
        };
        [label drawInRect:NSMakeRect(center.x - 45.0, center.y - radius - 16.0, 90.0, 14.0) withAttributes:lblAttrs];
    }
}

#pragma mark - Export Helpers

+ (nullable NSData *)pngDataForImage:(NSImage *)image {
    if (!image) return nil;
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) return nil;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

+ (nullable NSData *)jpegDataForImage:(NSImage *)image compression:(CGFloat)compression {
    if (!image) return nil;
    CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
    if (!cgImage) return nil;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
    return [rep representationUsingType:NSBitmapImageFileTypeJPEG properties:@{
        NSImageCompressionFactor: @(compression)
    }];
}

@end
