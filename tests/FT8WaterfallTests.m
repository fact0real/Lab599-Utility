#import <Cocoa/Cocoa.h>
#import <dispatch/dispatch.h>
#import <math.h>
#import "TX500FT8WaterfallView.h"

static void Check(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        exit(1);
    }
}

static void RenderView(TX500FT8WaterfallView *view, NSBitmapImageRep *bitmap) {
    NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    Check(context != nil, @"bitmap graphics context is available");
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:context];
    [view drawRect:view.bounds];
    [context flushGraphics];
    [NSGraphicsContext restoreGraphicsState];
}

int main(void) {
    @autoreleasepool {
        TX500FT8WaterfallView *view = [[TX500FT8WaterfallView alloc] initWithFrame:NSMakeRect(0, 0, 900, 120)];
        Check(view != nil, @"waterfall view initializes");

        NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc]
            initWithBitmapDataPlanes:NULL
            pixelsWide:900
            pixelsHigh:120
            bitsPerSample:8
            samplesPerPixel:4
            hasAlpha:YES
            isPlanar:NO
            colorSpaceName:NSCalibratedRGBColorSpace
            bytesPerRow:0
            bitsPerPixel:0];
        Check(bitmap != nil, @"waterfall bitmap initializes");

        float *magnitudes = calloc(256, sizeof(float));
        Check(magnitudes != NULL, @"spectrum test buffer allocates");
        for (int i = 0; i < 256; i++) magnitudes[i] = 0.5f + 0.5f * sinf((float)i * 0.1f);

        // Reproduce sustained decode traffic while AppKit draws on the main
        // thread. The writer intentionally runs much faster than display refresh.
        dispatch_group_t writers = dispatch_group_create();
        dispatch_group_async(writers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            for (int frame = 0; frame < 10000; frame++) {
                magnitudes[frame % 256] = (float)(frame % 100) / 100.0f;
                [view appendSpectrumRow:magnitudes count:256];
            }
        });

        for (int frame = 0; frame < 1000; frame++) {
            view.isTransmitting = ((frame % 17) == 0);
            view.rxFrequencyHz = 200.0f + (float)(frame % 2700);
            view.txFrequencyHz = 2900.0f - (float)(frame % 2700);
            RenderView(view, bitmap);
        }

        Check(dispatch_group_wait(writers, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)) == 0,
              @"concurrent spectrum writer finishes without deadlock");
        [view clearWaterfall];
        view.showCallsignTags = YES;
        view.activeStationTags = @[
            @{@"freq": @(1200.0f), @"call": @"DL7XYZ", @"snr": @(-8), @"isCQ": @(YES)},
            @{@"freq": @(2186.0f), @"call": @"ER3PM", @"snr": @(-14), @"isCQ": @(NO)}
        ];
        RenderView(view, bitmap);
        Check(bitmap.bitmapData != NULL, @"rendered bitmap with callsign tags remains valid");

        free(magnitudes);
        printf("PASS: FT8 waterfall survived concurrent ingestion, callsign tags overlay, and 1000 render cycles\n");
    }
    return 0;
}
