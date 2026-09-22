//
//  TX500CWSpectrumView.m
//  Lab599 Utility
//
//  Real-Time Audio Spectrum Scope & Signal Metric Visualizer
//

#import "TX500CWSpectrumView.h"

@implementation TX500CWSpectrumView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _bins = @[];
        _nominalPitchHz = 650.0;
        _centerFrequencyHz = 650.0;
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.07 alpha:1.0].CGColor;
        self.layer.cornerRadius = 6.0;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)updateWithBins:(NSArray<TX500CWSpectrumBin *> *)bins
             centerFreq:(double)centerFreq
            nominalPitch:(double)pitch
                   level:(float)level
                   snrDb:(double)snr
          signalDetected:(BOOL)detected {
    self.bins = bins;
    self.centerFrequencyHz = centerFreq;
    self.nominalPitchHz = pitch;
    self.audioLevel = level;
    self.snrDb = snr;
    self.isSignalDetected = detected;
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
    if (!ctx) return;

    NSRect bounds = self.bounds;
    CGFloat width = bounds.size.width;
    CGFloat height = bounds.size.height;

    // 1. Background Grid Lines
    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithCalibratedWhite:0.18 alpha:1.0].CGColor);
    CGContextSetLineWidth(ctx, 1.0);

    // Horizontal dB lines
    for (int i = 1; i <= 4; i++) {
        CGFloat y = (CGFloat)i * (height / 5.0);
        CGContextMoveToPoint(ctx, 0, y);
        CGContextAddLineToPoint(ctx, width, y);
    }
    CGContextStrokePath(ctx);

    // 2. Frequency Grid Lines & Labels
    NSDictionary *labelAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: [NSColor colorWithCalibratedWhite:0.5 alpha:1.0]
    };

    double minF = 300.0;
    double maxF = 1500.0;
    double rangeF = maxF - minF;

    double gridFreqs[] = { 400.0, 600.0, 800.0, 1000.0, 1200.0, 1400.0 };
    for (int i = 0; i < 6; i++) {
        double f = gridFreqs[i];
        CGFloat x = (CGFloat)((f - minF) / rangeF) * width;
        CGContextMoveToPoint(ctx, x, 0);
        CGContextAddLineToPoint(ctx, x, height);
        CGContextStrokePath(ctx);

        NSString *fStr = [NSString stringWithFormat:@"%dHz", (int)f];
        [fStr drawAtPoint:NSMakePoint(x + 2, 2) withAttributes:labelAttr];
    }

    // 3. Spectrum Energy Bars
    if (self.bins.count > 0) {
        CGFloat barWidth = width / (CGFloat)self.bins.count;
        for (NSUInteger b = 0; b < self.bins.count; b++) {
            TX500CWSpectrumBin *bin = self.bins[b];
            CGFloat binHeight = fmin(height - 18.0, (CGFloat)(bin.magnitude * 2800.0));
            CGFloat x = (CGFloat)b * barWidth;
            CGFloat y = 16.0;

            NSRect barRect = NSMakeRect(x + 1.0, y, fmax(1.0, barWidth - 2.0), binHeight);

            // Color bar: green if near center freq and strong, otherwise cyan/slate
            BOOL isNearCenter = fabs(bin.frequencyHz - self.centerFrequencyHz) <= 25.0;
            NSColor *barColor = isNearCenter && self.isSignalDetected ?
                [NSColor colorWithSRGBRed:0.2 green:0.85 blue:0.35 alpha:0.85] :
                [NSColor colorWithSRGBRed:0.2 green:0.55 blue:0.85 alpha:0.65];

            CGContextSetFillColorWithColor(ctx, barColor.CGColor);
            CGContextFillRect(ctx, NSRectToCGRect(barRect));
        }
    }

    // 4. Center Frequency & AFC Reticle
    CGFloat targetX = (CGFloat)((self.nominalPitchHz - minF) / rangeF) * width;
    CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithSRGBRed:0.95 green:0.25 blue:0.25 alpha:0.75].CGColor);
    CGContextSetLineWidth(ctx, 1.5);
    CGFloat dash[] = { 4.0, 3.0 };
    CGContextSetLineDash(ctx, 0, dash, 2);
    CGContextMoveToPoint(ctx, targetX, 16.0);
    CGContextAddLineToPoint(ctx, targetX, height);
    CGContextStrokePath(ctx);
    CGContextSetLineDash(ctx, 0, NULL, 0); // Reset dash

    // 5. AFC Lock Indicator
    if (fabs(self.centerFrequencyHz - self.nominalPitchHz) > 3.0) {
        CGFloat afcX = (CGFloat)((self.centerFrequencyHz - minF) / rangeF) * width;
        CGContextSetStrokeColorWithColor(ctx, [NSColor colorWithSRGBRed:0.2 green:0.85 blue:0.35 alpha:0.9].CGColor);
        CGContextSetLineWidth(ctx, 1.5);
        CGContextMoveToPoint(ctx, afcX, 16.0);
        CGContextAddLineToPoint(ctx, afcX, height);
        CGContextStrokePath(ctx);
    }

    // 6. Header HUD: SNR, Audio Level, Signal Badge
    NSString *hudText = [NSString stringWithFormat:@"PITCH: %.0fHz | AFC: %.0fHz | SNR: %.1fdB | LEVEL: %.0f%% %@",
                         self.nominalPitchHz,
                         self.centerFrequencyHz,
                         self.snrDb,
                         (self.audioLevel * 100.0f),
                         self.isSignalDetected ? @"● CARRIER DETECTED" : @"○ LISTENING"];

    NSDictionary *hudAttr = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10.0 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: self.isSignalDetected ?
            [NSColor colorWithSRGBRed:0.2 green:0.9 blue:0.35 alpha:1.0] :
            [NSColor colorWithCalibratedWhite:0.85 alpha:1.0]
    };
    [hudText drawAtPoint:NSMakePoint(8, height - 16) withAttributes:hudAttr];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    CGFloat width = self.bounds.size.width;
    if (width > 0 && p.x >= 0 && p.x <= width) {
        double minF = 300.0;
        double maxF = 1500.0;
        double freq = minF + ((double)p.x / (double)width) * (maxF - minF);
        freq = fmin(1500.0, fmax(300.0, round(freq / 5.0) * 5.0)); // Snap to nearest 5 Hz
        if (self.onPitchSelected) {
            self.onPitchSelected(freq);
        }
    }
}

@end

