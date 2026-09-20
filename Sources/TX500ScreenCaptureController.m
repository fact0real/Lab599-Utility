#import "TX500ScreenCaptureController.h"
#import "Lab599SerialPort.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#pragma mark - Custom Display View

@interface TX500ScreenDisplayView : NSView
@property (nonatomic, strong, nullable) NSImage *renderedImage;
@property (nonatomic, assign) BOOL showChassisBezel;
@property (nonatomic, weak) TX500ScreenCaptureController *controller;

// Interactive Animation State
@property (nonatomic, assign) NSPoint rippleCenterChassis;
@property (nonatomic, assign) CGFloat rippleRadius;
@property (nonatomic, assign) CGFloat rippleAlpha;
@property (nonatomic, strong, nullable) NSColor *rippleColor;
@property (nonatomic, strong, nullable) NSTimer *rippleTimer;
@property (nonatomic, strong, nullable) NSTimer *pressReleaseTimer;
@property (nonatomic, strong, nullable) NSTrackingArea *trackingArea;
@property (nonatomic, assign) NSPoint lastDragPoint;
@property (nonatomic, assign) BOOL isDraggingTuneKnob;
@property (nonatomic, assign) BOOL isDraggingAFGainKnob;
@property (nonatomic, assign) BOOL isDraggingRITXITKnob;
// Pixel accumulators for smooth drag feel
@property (nonatomic, assign) CGFloat tuneDragAccum;
@property (nonatomic, assign) CGFloat afGainDragAccum;
@property (nonatomic, assign) CGFloat ritXITDragAccum;
// Scroll accumulators (trackpad momentum)
@property (nonatomic, assign) CGFloat tuneScrollAccum;
@property (nonatomic, assign) CGFloat afGainScrollAccum;
@property (nonatomic, assign) CGFloat ritXITScrollAccum;

- (NSRect)currentChassisTargetRect;
- (NSPoint)chassisPointFromViewPoint:(NSPoint)viewPt;
- (NSPoint)viewPointFromChassisPoint:(NSPoint)cp;
- (TX500ChassisControlTag)controlTagAtChassisPoint:(NSPoint)cp;
@end

@implementation TX500ScreenDisplayView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.08 alpha:1.0].CGColor;
        self.layer.cornerRadius = 8.0;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)dealloc {
    [_rippleTimer invalidate];
    [_pressReleaseTimer invalidate];
}

- (BOOL)isFlipped {
    return NO;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (self.trackingArea) {
        [self removeTrackingArea:self.trackingArea];
    }
    NSTrackingAreaOptions options = (NSTrackingMouseMoved | NSTrackingCursorUpdate | NSTrackingActiveInKeyWindow);
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:options owner:self userInfo:nil];
    [self addTrackingArea:self.trackingArea];
}

- (NSRect)currentChassisTargetRect {
    NSRect bounds = self.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0 || !self.renderedImage) return NSZeroRect;

    NSSize imgSize = self.renderedImage.size;
    if (imgSize.width <= 0 || imgSize.height <= 0) return NSZeroRect;

    CGFloat scaleW = (bounds.size.width - 24.0) / imgSize.width;
    CGFloat scaleH = (bounds.size.height - 24.0) / imgSize.height;
    CGFloat scale = MIN(scaleW, scaleH);

    if (!self.showChassisBezel) {
        if (scale >= 1.0) {
            scale = floor(scale);
            if (scale < 1.0) scale = 1.0;
        }
    } else {
        if (scale > 2.0) scale = 2.0;
    }

    NSSize targetSize = NSMakeSize(floor(imgSize.width * scale), floor(imgSize.height * scale));
    return NSMakeRect(floor((bounds.size.width - targetSize.width) / 2.0),
                      floor((bounds.size.height - targetSize.height) / 2.0),
                      targetSize.width, targetSize.height);
}

- (NSPoint)chassisPointFromViewPoint:(NSPoint)viewPt {
    NSRect tr = [self currentChassisTargetRect];
    if (tr.size.width <= 0 || tr.size.height <= 0 || !NSPointInRect(viewPt, tr)) {
        return NSMakePoint(-1, -1);
    }
    CGFloat x = ((viewPt.x - tr.origin.x) / tr.size.width) * 840.0;
    CGFloat y = ((viewPt.y - tr.origin.y) / tr.size.height) * 440.0;
    return NSMakePoint(x, y);
}

- (NSPoint)viewPointFromChassisPoint:(NSPoint)cp {
    NSRect tr = [self currentChassisTargetRect];
    CGFloat vx = tr.origin.x + (cp.x / 840.0) * tr.size.width;
    CGFloat vy = tr.origin.y + (cp.y / 440.0) * tr.size.height;
    return NSMakePoint(vx, vy);
}

- (TX500ChassisControlTag)controlTagAtChassisPoint:(NSPoint)cp {
    if (!self.showChassisBezel) return TX500ControlNone;
    if (cp.x < 0 || cp.x > 840.0 || cp.y < 0 || cp.y > 440.0) return TX500ControlNone;

    // Layout constants (must match TX500ScreenRenderer.m drawRightControlPanelInContext)
    static const CGFloat kStartX = 572.0;

    // 1. Right-side vertical buttons (col A): x=[574..624]
    if (cp.x >= kStartX + 2.0 && cp.x <= kStartX + 52.0) {
        if (cp.y >= 342.0 && cp.y <= 372.0) return TX500ControlPower;     // Tag 1 (346..368)
        if (cp.y >= 290.0 && cp.y <= 320.0) return TX500ControlBandUp;    // Tag 2 (294..316)
        if (cp.y >= 238.0 && cp.y <= 268.0) return TX500ControlBandDown;  // Tag 3 (242..264)
        if (cp.y >= 186.0 && cp.y <= 216.0) return TX500ControlMode;      // Tag 4 (190..212)
        if (cp.y >= 134.0 && cp.y <= 164.0) return TX500ControlFilter;    // Tag 5 (138..160)
        if (cp.y >= 82.0  && cp.y <= 112.0) return TX500ControlMenu;      // Tag 6 (86..108)
    }

    // 2. Rotary Knobs — check by distance from center
    // AF GAIN: center (658, 315), radius 22
    CGFloat distAF = hypot(cp.x - 658.0, cp.y - 315.0);
    if (distAF <= 28.0) return TX500ControlAFGainKnob;

    // RIT/XIT: center (712, 315), radius 22
    CGFloat distRIT = hypot(cp.x - 712.0, cp.y - 315.0);
    if (distRIT <= 28.0) return TX500ControlRITXITKnob;

    // TUNE/MULTI: center (685, 168), radius 46
    CGFloat distTune = hypot(cp.x - 685.0, cp.y - 168.0);
    if (distTune <= 52.0) return TX500ControlTuneKnob;

    // 3. Far-right round buttons: circle centers at cx=762.0, radius=11.0
    // Centers horizontally aligned with corresponding capsule buttons: cy = 357, 305, 253, 201, 149, 97
    CGFloat roundCX = 762.0;
    CGFloat roundCYs[] = {357.0, 305.0, 253.0, 201.0, 149.0, 97.0};
    TX500ChassisControlTag roundTags[] = {TX500ControlRX, TX500ControlClear, TX500ControlVM,
                                           TX500ControlLock, TX500ControlPlus, TX500ControlMinus};
    for (int ri = 0; ri < 6; ri++) {
        if (hypot(cp.x - roundCX, cp.y - roundCYs[ri]) <= 15.0) return roundTags[ri];
    }

    // 4. Top physical soft keys (above LCD)
    // Parallel and aligned with top screws (bounds: y=402.5..417.5)
    if (cp.y >= 395.0 && cp.y <= 422.0) {
        if (cp.x >= 80.0 && cp.x <= 146.0) return TX500ControlTopKey1;
        if (cp.x >= 212.0 && cp.x <= 278.0) return TX500ControlTopKey2;
        if (cp.x >= 342.0 && cp.x <= 408.0) return TX500ControlTopKey3;
        if (cp.x >= 474.0 && cp.x <= 540.0) return TX500ControlTopKey4;
    }

    // 5. Bottom physical soft keys (below LCD)
    if (cp.y >= 18.0 && cp.y <= 36.0) {
        if (cp.x >= 80.0 && cp.x <= 146.0) return TX500ControlBottomKey1;
        if (cp.x >= 212.0 && cp.x <= 278.0) return TX500ControlBottomKey2;
        if (cp.x >= 342.0 && cp.x <= 408.0) return TX500ControlBottomKey3;
        if (cp.x >= 474.0 && cp.x <= 540.0) return TX500ControlBottomKey4;
    }

    return TX500ControlNone;

}


- (void)cursorUpdate:(NSEvent *)event {
    NSPoint viewPt = [self convertPoint:[event locationInWindow] fromView:nil];
    NSPoint cp = [self chassisPointFromViewPoint:viewPt];
    TX500ChassisControlTag tag = [self controlTagAtChassisPoint:cp];
    if (tag != TX500ControlNone) {
        [[NSCursor pointingHandCursor] set];
    } else {
        [[NSCursor arrowCursor] set];
    }
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint viewPt = [self convertPoint:[event locationInWindow] fromView:nil];
    NSPoint cp = [self chassisPointFromViewPoint:viewPt];
    TX500ChassisControlTag tag = [self controlTagAtChassisPoint:cp];
    if (tag != TX500ControlNone) {
        [[NSCursor pointingHandCursor] set];
    } else {
        [[NSCursor arrowCursor] set];
    }
}

- (void)startRippleAtChassisPoint:(NSPoint)cp forTag:(TX500ChassisControlTag)tag {
    self.rippleCenterChassis = cp;
    self.rippleRadius = 4.0;
    self.rippleAlpha = 0.95;

    if (tag == TX500ControlPower) {
        self.rippleColor = [NSColor colorWithCalibratedRed:1.0 green:0.22 blue:0.22 alpha:1.0];
    } else if (tag == TX500ControlTuneKnob || tag == TX500ControlAFGainKnob) {
        self.rippleColor = [NSColor colorWithCalibratedRed:0.20 green:0.75 blue:1.0 alpha:1.0];
    } else if (tag >= 21) {
        self.rippleColor = [NSColor colorWithCalibratedRed:1.0 green:0.75 blue:0.20 alpha:1.0];
    } else {
        self.rippleColor = [NSColor colorWithCalibratedRed:0.0 green:0.90 blue:1.0 alpha:1.0];
    }

    [self.rippleTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.rippleTimer = [NSTimer scheduledTimerWithTimeInterval:0.016 repeats:YES block:^(NSTimer * _Nonnull timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }

        strongSelf.rippleRadius += 4.5;
        strongSelf.rippleAlpha -= 0.07;
        if (strongSelf.rippleAlpha <= 0.0) {
            strongSelf.rippleAlpha = 0.0;
            strongSelf.rippleRadius = 0.0;
            [strongSelf.rippleTimer invalidate];
            strongSelf.rippleTimer = nil;
        }
        [strongSelf setNeedsDisplay:YES];
    }];
}

- (void)mouseDown:(NSEvent *)event {
    NSPoint viewPt = [self convertPoint:[event locationInWindow] fromView:nil];
    NSPoint cp = [self chassisPointFromViewPoint:viewPt];
    TX500ChassisControlTag tag = [self controlTagAtChassisPoint:cp];

    if (tag != TX500ControlNone) {
        [[NSHapticFeedbackManager defaultPerformer] performFeedbackPattern:NSHapticFeedbackPatternGeneric
                                                           performanceTime:NSHapticFeedbackPerformanceTimeNow];
        [self startRippleAtChassisPoint:cp forTag:tag];

        self.controller.pressedTag = tag;
        [self.controller renderAndUpdateDisplay];

        [self.pressReleaseTimer invalidate];
        __weak typeof(self) weakSelf = self;
        self.pressReleaseTimer = [NSTimer scheduledTimerWithTimeInterval:0.14 repeats:NO block:^(NSTimer * _Nonnull timer) {
            (void)timer;
            if (weakSelf) {
                weakSelf.controller.pressedTag = TX500ControlNone;
                [weakSelf.controller renderAndUpdateDisplay];
            }
        }];

        [self.controller handleChassisControlPress:tag atChassisPoint:cp];

        // Initialize drag state for knobs
        self.lastDragPoint = viewPt;
        self.isDraggingTuneKnob   = (tag == TX500ControlTuneKnob);
        self.isDraggingAFGainKnob = (tag == TX500ControlAFGainKnob);
        self.isDraggingRITXITKnob = (tag == TX500ControlRITXITKnob);
        self.tuneDragAccum    = 0.0;
        self.afGainDragAccum  = 0.0;
        self.ritXITDragAccum  = 0.0;
    } else {
        [super mouseDown:event];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    if (self.isDraggingTuneKnob || self.isDraggingAFGainKnob || self.isDraggingRITXITKnob) {
        NSPoint viewPt = [self convertPoint:[event locationInWindow] fromView:nil];
        CGFloat dy = viewPt.y - self.lastDragPoint.y;
        self.lastDragPoint = viewPt;

        // Accumulator-based: fires one discrete step per kPixelsPerStep pixels dragged.
        // This gives a genuine "turning a physical detented knob" feel.
        static const CGFloat kTunePixelsPerStep   = 3.0;  // 3px = one 500Hz step
        static const CGFloat kAFGainPixelsPerStep = 4.0;  // 4px = one 5-unit step

        if (self.isDraggingTuneKnob) {
            self.tuneDragAccum += dy;
            CGFloat steps = floor(fabs(self.tuneDragAccum) / kTunePixelsPerStep);
            if (steps >= 1.0) {
                CGFloat sign = (self.tuneDragAccum > 0) ? 1.0 : -1.0;
                [self.controller handleTuneKnobDelta:sign * 1.0]; // delta=1.0 → 500Hz per step
                self.tuneDragAccum -= sign * steps * kTunePixelsPerStep;
            }
        } else if (self.isDraggingAFGainKnob) {
            self.afGainDragAccum += dy;
            CGFloat steps = floor(fabs(self.afGainDragAccum) / kAFGainPixelsPerStep);
            if (steps >= 1.0) {
                CGFloat sign = (self.afGainDragAccum > 0) ? 1.0 : -1.0;
                [self.controller handleAFGainKnobDelta:sign * 1.0]; // delta=1.0 → 5 units
                self.afGainDragAccum -= sign * steps * kAFGainPixelsPerStep;
            }
        } else if (self.isDraggingRITXITKnob) {
            self.ritXITDragAccum += dy;
            CGFloat steps = floor(fabs(self.ritXITDragAccum) / kAFGainPixelsPerStep);
            if (steps >= 1.0) {
                CGFloat sign = (self.ritXITDragAccum > 0) ? 1.0 : -1.0;
                [self.controller handleRITXITKnobDelta:sign * 1.0];
                self.ritXITDragAccum -= sign * steps * kAFGainPixelsPerStep;
            }
        }
    } else {
        [super mouseDragged:event];
    }
}

- (void)mouseUp:(NSEvent *)event {
    self.isDraggingTuneKnob   = NO;
    self.isDraggingAFGainKnob = NO;
    self.isDraggingRITXITKnob = NO;
    self.tuneDragAccum   = 0.0;
    self.afGainDragAccum = 0.0;
    self.ritXITDragAccum = 0.0;
    [super mouseUp:event];
}

- (void)scrollWheel:(NSEvent *)event {
    NSPoint viewPt = [self convertPoint:[event locationInWindow] fromView:nil];
    NSPoint cp = [self chassisPointFromViewPoint:viewPt];
    TX500ChassisControlTag tag = [self controlTagAtChassisPoint:cp];

    if (tag == TX500ControlTuneKnob || tag == TX500ControlAFGainKnob || tag == TX500ControlRITXITKnob) {

        if (event.hasPreciseScrollingDeltas) {
            // Trackpad: accumulate sub-pixel deltas, fire one step per threshold
            // This makes trackpad scroll feel just like the physical detented knob
            CGFloat kTuneThresh   = 5.0;   // px of trackpad movement = one TUNE step
            CGFloat kGainThresh   = 6.0;   // px = one AF/RIT step
            CGFloat delta = event.scrollingDeltaY;

            // Apply damping for momentum phase
            BOOL isMomentum = (event.phase == NSEventPhaseNone && event.momentumPhase == NSEventPhaseChanged);
            if (isMomentum) delta *= 0.25;

            if (tag == TX500ControlTuneKnob) {
                self.tuneScrollAccum += delta;
                while (fabs(self.tuneScrollAccum) >= kTuneThresh) {
                    CGFloat sign = (self.tuneScrollAccum > 0) ? 1.0 : -1.0;
                    [self.controller handleTuneKnobDelta:sign * 1.0];
                    self.tuneScrollAccum -= sign * kTuneThresh;
                }
            } else if (tag == TX500ControlAFGainKnob) {
                self.afGainScrollAccum += delta;
                while (fabs(self.afGainScrollAccum) >= kGainThresh) {
                    CGFloat sign = (self.afGainScrollAccum > 0) ? 1.0 : -1.0;
                    [self.controller handleAFGainKnobDelta:sign * 1.0];
                    self.afGainScrollAccum -= sign * kGainThresh;
                }
            } else {
                self.ritXITScrollAccum += delta;
                while (fabs(self.ritXITScrollAccum) >= kGainThresh) {
                    CGFloat sign = (self.ritXITScrollAccum > 0) ? 1.0 : -1.0;
                    [self.controller handleRITXITKnobDelta:sign * 1.0];
                    self.ritXITScrollAccum -= sign * kGainThresh;
                }
            }
        } else {
            // Classic mouse scroll wheel: each click = one step, direction = delta sign
            CGFloat delta = event.scrollingDeltaY;
            if (fabs(delta) >= 0.5) {
                CGFloat sign = (delta > 0) ? 1.0 : -1.0;
                if (tag == TX500ControlTuneKnob)
                    [self.controller handleTuneKnobDelta:sign * 1.0];
                else if (tag == TX500ControlAFGainKnob)
                    [self.controller handleAFGainKnobDelta:sign * 1.0];
                else
                    [self.controller handleRITXITKnobDelta:sign * 1.0];
            }
        }
    } else {
        [super scrollWheel:event];
    }
}


- (void)drawRect:(NSRect)dirtyRect {
    [super drawRect:dirtyRect];

    NSRect bounds = self.bounds;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;

    // Background fill
    [[NSColor colorWithCalibratedWhite:0.06 alpha:1.0] setFill];
    NSRectFill(bounds);

    if (!self.renderedImage) return;

    NSSize imgSize = self.renderedImage.size;
    if (imgSize.width <= 0 || imgSize.height <= 0) return;

    NSRect targetRect = [self currentChassisTargetRect];
    if (targetRect.size.width <= 0 || targetRect.size.height <= 0) return;

    NSGraphicsContext *context = [NSGraphicsContext currentContext];
    [context saveGraphicsState];

    if (!self.showChassisBezel) {
        // Draw elegant bezel frame around standalone LCD panel
        NSRect bezelRect = NSInsetRect(targetRect, -8.0, -8.0);
        NSBezierPath *bezelPath = [NSBezierPath bezierPathWithRoundedRect:bezelRect xRadius:6.0 yRadius:6.0];
        [[NSColor colorWithCalibratedWhite:0.12 alpha:1.0] setFill];
        [bezelPath fill];

        [[NSColor colorWithCalibratedWhite:0.25 alpha:1.0] setStroke];
        bezelPath.lineWidth = 1.0;
        [bezelPath stroke];

        // Draw inner shadow bezel
        NSRect innerBezel = NSInsetRect(targetRect, -1.0, -1.0);
        [[NSColor blackColor] setStroke];
        [NSBezierPath strokeRect:innerBezel];

        // Crisp pixel rendering without anti-aliasing blur
        context.imageInterpolation = NSImageInterpolationNone;
    } else {
        // Chassis bezel rendering: smooth high quality interpolation
        context.imageInterpolation = NSImageInterpolationHigh;
    }

    [self.renderedImage drawInRect:targetRect
                         fromRect:NSMakeRect(0, 0, imgSize.width, imgSize.height)
                        operation:NSCompositingOperationSourceOver
                         fraction:1.0
                   respectFlipped:YES
                            hints:nil];

    // Shockwave ripple overlay effect
    if (self.rippleAlpha > 0.001 && self.rippleRadius > 0.0) {
        NSPoint vp = [self viewPointFromChassisPoint:self.rippleCenterChassis];
        CGFloat r = self.rippleRadius * (targetRect.size.width / 840.0);
        if (r < 2.0) r = 2.0;
        NSRect rRect = NSMakeRect(vp.x - r, vp.y - r, r * 2.0, r * 2.0);

        CGContextSaveGState(context.CGContext);

        // Translucent ambient glow fill
        [[self.rippleColor colorWithAlphaComponent:self.rippleAlpha * 0.22] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:rRect] fill];

        // Neon shockwave crest ring
        [[self.rippleColor colorWithAlphaComponent:self.rippleAlpha] setStroke];
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:rRect];
        ring.lineWidth = 2.5;
        [ring stroke];

        // Concentric inner harmonic ripple ring
        if (r > 8.0) {
            CGFloat rInner = r * 0.60;
            NSRect inRect = NSMakeRect(vp.x - rInner, vp.y - rInner, rInner * 2.0, rInner * 2.0);
            [[self.rippleColor colorWithAlphaComponent:self.rippleAlpha * 0.45] setStroke];
            NSBezierPath *inRing = [NSBezierPath bezierPathWithOvalInRect:inRect];
            inRing.lineWidth = 1.2;
            [inRing stroke];
        }

        CGContextRestoreGState(context.CGContext);
    }

    [context restoreGraphicsState];
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    (void)event;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Screen Options"];

    NSMenuItem *copyItem = [menu addItemWithTitle:@"Copy Screen to Clipboard"
                                           action:@selector(copyToClipboardAction:)
                                    keyEquivalent:@"c"];
    copyItem.target = self.controller;

    NSMenuItem *saveItem = [menu addItemWithTitle:@"Save Screenshot As..."
                                           action:@selector(saveScreenshotAction:)
                                    keyEquivalent:@"s"];
    saveItem.target = self.controller;

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *themeItem = [menu addItemWithTitle:@"Theme" action:NULL keyEquivalent:@""];
    NSMenu *themeMenu = [[NSMenu alloc] initWithTitle:@"Themes"];

    NSArray *themeTitles = @[@"Amber Backlight (Lab599 Signature)",
                             @"Cool White (Daylight)",
                             @"Tactical Green (Night Vision)",
                             @"Monochrome OLED"];
    for (NSInteger i = 0; i < 4; i++) {
        NSMenuItem *item = [themeMenu addItemWithTitle:themeTitles[i]
                                                action:@selector(menuSelectTheme:)
                                         keyEquivalent:@""];
        item.target = self.controller;
        item.tag = i;
        item.state = (self.controller.currentTheme == i) ? NSControlStateValueOn : NSControlStateValueOff;
    }
    themeItem.submenu = themeMenu;

    NSMenuItem *bezelItem = [menu addItemWithTitle:@"Show TX-500 Chassis Bezel"
                                            action:@selector(toggleBezelAction:)
                                     keyEquivalent:@""];
    bezelItem.target = self.controller;
    bezelItem.state = self.showChassisBezel ? NSControlStateValueOn : NSControlStateValueOff;

    NSMenuItem *gridItem = [menu addItemWithTitle:@"Show LCD Pixel Grid"
                                           action:@selector(togglePixelGridAction:)
                                    keyEquivalent:@""];
    gridItem.target = self.controller;
    gridItem.state = self.controller.showPixelGrid ? NSControlStateValueOn : NSControlStateValueOff;

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *refreshItem = [menu addItemWithTitle:@"Capture Snapshot Now"
                                              action:@selector(captureNowAction:)
                                       keyEquivalent:@"r"];
    refreshItem.target = self.controller;

    return menu;
}

@end

#pragma mark - Main Controller Implementation

@interface TX500ScreenCaptureController () {
    dispatch_queue_t _serialQueue;
    NSTimer *_demoTimer;
    NSTimer *_livePollTimer;
    BOOL _isPolling;
    double _demoPhase;
    NSUInteger _demoCycleCount;
}

@property (nonatomic, strong) NSView *containerView;
@property (nonatomic, strong) TX500ScreenDisplayView *displayView;
@property (nonatomic, strong) NSPopUpButton *themePopup;
@property (nonatomic, strong) NSPopUpButton *viewModePopup;
@property (nonatomic, strong) NSButton *pixelGridCheckbox;
@property (nonatomic, strong) NSSegmentedControl *modePicker;
@property (nonatomic, strong) NSButton *autoSyncCheckbox;
@property (nonatomic, strong) NSButton *refreshButton;
@property (nonatomic, strong) NSButton *clipboardButton;
@property (nonatomic, strong) NSButton *saveButton;
@property (nonatomic, strong) NSTextField *hudTelemetryLabel;
@property (nonatomic, strong) NSTextField *statusFeedbackLabel;
@property (nonatomic, strong) NSTimer *feedbackTimer;

@end

@implementation TX500ScreenCaptureController

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentTheme = TX500ScreenThemeCoolWhite; // Authentic daylight transflective matching physical radio photo
        _showChassisBezel = YES;
        _showPixelGrid = YES;
        _displayScale = 2.0;
        _liveSyncActive = NO;
        _demoModeActive = NO;
        _tuneAngle = 0.0;
        _afGainAngle = 0.0;
        _pressedTag = TX500ControlNone;
        _screenState = [TX500ScreenState defaultDemoState];
        _serialQueue = dispatch_queue_create("com.lab599.screencapture.serial", DISPATCH_QUEUE_SERIAL);
        [self setupUI];
        [self renderAndUpdateDisplay];
    }
    return self;
}

- (void)dealloc {
    [_demoTimer invalidate];
    [_livePollTimer invalidate];
    [_feedbackTimer invalidate];
}

- (NSView *)view {
    return self.containerView;
}

#pragma mark - UI Setup

- (void)setupUI {
    self.containerView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 900, 520)];
    self.containerView.translatesAutoresizingMaskIntoConstraints = NO;

    // --- Top Controls Bar ---
    NSStackView *controlsBar = [NSStackView new];
    controlsBar.translatesAutoresizingMaskIntoConstraints = NO;
    controlsBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    controlsBar.alignment = NSLayoutAttributeCenterY;
    controlsBar.spacing = 8.0;

    // Theme selector
    NSTextField *themeLbl = [NSTextField labelWithString:@"Theme:"];
    themeLbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    themeLbl.textColor = NSColor.secondaryLabelColor;

    self.themePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.themePopup.controlSize = NSControlSizeSmall;
    self.themePopup.font = [NSFont systemFontOfSize:11];
    [self.themePopup addItemsWithTitles:@[
        @"Amber Backlight (Lab599)",
        @"Cool White (Daylight Transflective)",
        @"Tactical Green (Night-Vision)",
        @"OLED Monochrome"
    ]];
    [self.themePopup selectItemAtIndex:self.currentTheme];
    self.themePopup.target = self;
    self.themePopup.action = @selector(themeChanged:);

    // View mode selector
    NSTextField *viewLbl = [NSTextField labelWithString:@"Frame:"];
    viewLbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    viewLbl.textColor = NSColor.secondaryLabelColor;

    self.viewModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.viewModePopup.controlSize = NSControlSizeSmall;
    self.viewModePopup.font = [NSFont systemFontOfSize:11];
    [self.viewModePopup addItemsWithTitles:@[
        @"TX-500 Chassis Bezel",
        @"LCD Screen Only (3x)",
        @"LCD Screen Only (2x)",
        @"LCD Screen Only (1x)"
    ]];
    self.viewModePopup.target = self;
    self.viewModePopup.action = @selector(viewModeChanged:);

    // Pixel grid checkbox
    self.pixelGridCheckbox = [NSButton checkboxWithTitle:@"Pixel Matrix"
                                                  target:self
                                                  action:@selector(pixelGridToggled:)];
    self.pixelGridCheckbox.controlSize = NSControlSizeSmall;
    self.pixelGridCheckbox.font = [NSFont systemFontOfSize:11];
    self.pixelGridCheckbox.state = self.showPixelGrid ? NSControlStateValueOn : NSControlStateValueOff;

    // Live vs Demo Mode Picker
    self.modePicker = [NSSegmentedControl segmentedControlWithLabels:@[@"Live CAT", @"Demo Sim"]
                                                        trackingMode:NSSegmentSwitchTrackingSelectOne
                                                              target:self
                                                              action:@selector(modePickerChanged:)];
    self.modePicker.controlSize = NSControlSizeSmall;
    self.modePicker.selectedSegment = self.demoModeActive ? 1 : 0;

    // Auto-refresh checkbox
    self.autoSyncCheckbox = [NSButton checkboxWithTitle:@"Live Auto-Sync"
                                                 target:self
                                                 action:@selector(autoSyncToggled:)];
    self.autoSyncCheckbox.controlSize = NSControlSizeSmall;
    self.autoSyncCheckbox.font = [NSFont systemFontOfSize:11];
    self.autoSyncCheckbox.state = self.liveSyncActive ? NSControlStateValueOn : NSControlStateValueOff;

    // Action buttons
    self.refreshButton = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(captureNowAction:)];
    self.refreshButton.controlSize = NSControlSizeSmall;
    self.refreshButton.font = [NSFont systemFontOfSize:11];
    if (@available(macOS 11.0, *)) {
        self.refreshButton.image = [NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"Refresh"];
    }

    self.clipboardButton = [NSButton buttonWithTitle:@"Copy" target:self action:@selector(copyToClipboardAction:)];
    self.clipboardButton.controlSize = NSControlSizeSmall;
    self.clipboardButton.font = [NSFont systemFontOfSize:11];
    if (@available(macOS 11.0, *)) {
        self.clipboardButton.image = [NSImage imageWithSystemSymbolName:@"doc.on.doc" accessibilityDescription:@"Copy"];
    }

    self.saveButton = [NSButton buttonWithTitle:@"Save Image..." target:self action:@selector(saveScreenshotAction:)];
    self.saveButton.controlSize = NSControlSizeSmall;
    self.saveButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    if (@available(macOS 11.0, *)) {
        self.saveButton.image = [NSImage imageWithSystemSymbolName:@"camera" accessibilityDescription:@"Save Image"];
    }

    [controlsBar addArrangedSubview:themeLbl];
    [controlsBar addArrangedSubview:self.themePopup];
    [controlsBar addArrangedSubview:viewLbl];
    [controlsBar addArrangedSubview:self.viewModePopup];
    [controlsBar addArrangedSubview:self.pixelGridCheckbox];
    [controlsBar addArrangedSubview:self.modePicker];
    [controlsBar addArrangedSubview:self.autoSyncCheckbox];
    [controlsBar addArrangedSubview:self.refreshButton];
    [controlsBar addArrangedSubview:self.clipboardButton];
    [controlsBar addArrangedSubview:self.saveButton];

    // --- Screen Display View ---
    self.displayView = [[TX500ScreenDisplayView alloc] initWithFrame:NSMakeRect(0, 0, 900, 380)];
    self.displayView.translatesAutoresizingMaskIntoConstraints = NO;
    self.displayView.showChassisBezel = self.showChassisBezel;
    self.displayView.controller = self;

    // --- Bottom HUD Telemetry Strip ---
    NSBox *hudBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    hudBox.translatesAutoresizingMaskIntoConstraints = NO;
    hudBox.boxType = NSBoxCustom;
    hudBox.fillColor = [NSColor colorWithCalibratedWhite:0.10 alpha:1.0];
    hudBox.borderColor = [NSColor colorWithCalibratedWhite:0.20 alpha:1.0];
    hudBox.borderWidth = 1.0;
    hudBox.cornerRadius = 6.0;

    self.hudTelemetryLabel = [NSTextField labelWithString:@"INITIALIZING SCREEN TELEMETRY..."];
    self.hudTelemetryLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudTelemetryLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.hudTelemetryLabel.textColor = [NSColor colorWithCalibratedRed:0.95 green:0.80 blue:0.40 alpha:1.0];
    self.hudTelemetryLabel.alignment = NSTextAlignmentLeft;

    self.statusFeedbackLabel = [NSTextField labelWithString:@""];
    self.statusFeedbackLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusFeedbackLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.statusFeedbackLabel.textColor = [NSColor colorWithCalibratedRed:0.35 green:0.85 blue:0.45 alpha:1.0];
    self.statusFeedbackLabel.alignment = NSTextAlignmentRight;

    [hudBox addSubview:self.hudTelemetryLabel];
    [hudBox addSubview:self.statusFeedbackLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.hudTelemetryLabel.leadingAnchor constraintEqualToAnchor:hudBox.leadingAnchor constant:14],
        [self.hudTelemetryLabel.centerYAnchor constraintEqualToAnchor:hudBox.centerYAnchor],
        [self.statusFeedbackLabel.trailingAnchor constraintEqualToAnchor:hudBox.trailingAnchor constant:-14],
        [self.statusFeedbackLabel.centerYAnchor constraintEqualToAnchor:hudBox.centerYAnchor],
        [self.hudTelemetryLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.statusFeedbackLabel.leadingAnchor constant:-8]
    ]];


    [self.containerView addSubview:controlsBar];
    [self.containerView addSubview:self.displayView];
    [self.containerView addSubview:hudBox];

    [NSLayoutConstraint activateConstraints:@[
        [controlsBar.topAnchor constraintEqualToAnchor:self.containerView.topAnchor constant:4],
        [controlsBar.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor],
        [controlsBar.trailingAnchor constraintLessThanOrEqualToAnchor:self.containerView.trailingAnchor],
        [controlsBar.heightAnchor constraintEqualToConstant:28],

        [self.displayView.topAnchor constraintEqualToAnchor:controlsBar.bottomAnchor constant:8],
        [self.displayView.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor],
        [self.displayView.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor],
        [self.displayView.heightAnchor constraintGreaterThanOrEqualToConstant:340],

        [hudBox.topAnchor constraintEqualToAnchor:self.displayView.bottomAnchor constant:8],
        [hudBox.leadingAnchor constraintEqualToAnchor:self.containerView.leadingAnchor],
        [hudBox.trailingAnchor constraintEqualToAnchor:self.containerView.trailingAnchor],
        [hudBox.heightAnchor constraintEqualToConstant:36],
        [hudBox.bottomAnchor constraintEqualToAnchor:self.containerView.bottomAnchor constant:-12]
    ]];
}

#pragma mark - Display Rendering & HUD Update

- (void)renderAndUpdateDisplay {
    NSImage *image = nil;
    if (self.showChassisBezel) {
        image = [TX500ScreenRenderer renderChassisImageWithState:self.screenState
                                                           theme:self.currentTheme
                                                       pixelGrid:self.showPixelGrid
                                                   pressedButton:self.pressedTag
                                                       tuneAngle:self.tuneAngle
                                                     afGainAngle:self.afGainAngle
                                                     ritXITAngle:self.ritXITAngle];
    } else {
        image = [TX500ScreenRenderer renderScreenImageWithState:self.screenState
                                                          theme:self.currentTheme
                                                          scale:self.displayScale
                                                      pixelGrid:self.showPixelGrid];
    }

    self.displayView.showChassisBezel = self.showChassisBezel;
    self.displayView.renderedImage = image;
    [self.displayView setNeedsDisplay:YES];

    [self updateHUDLabel];
}

#pragma mark - Chassis Interactive Controls & CAT Dispatch

static const uint64_t kAmateurBands[] = {
    1840000ULL,   // 160m
    3573000ULL,   // 80m
    5357000ULL,   // 60m
    7074000ULL,   // 40m
    10136000ULL,  // 30m
    14074000ULL,  // 20m
    18100000ULL,  // 17m
    21074000ULL,  // 15m
    24915000ULL,  // 12m
    28074000ULL,  // 10m
    50313000ULL   // 6m
};
static const char *kAmateurBandNames[] = {
    "160m", "80m", "60m", "40m", "30m", "20m", "17m", "15m", "12m", "10m", "6m"
};
static const size_t kAmateurBandsCount = sizeof(kAmateurBands) / sizeof(kAmateurBands[0]);

- (NSUInteger)bandIndexForFrequency:(uint64_t)freq {
    for (size_t i = 0; i < kAmateurBandsCount - 1; i++) {
        if (freq >= kAmateurBands[i] && freq < kAmateurBands[i + 1]) {
            return i;
        }
    }
    if (freq >= kAmateurBands[kAmateurBandsCount - 1]) {
        return kAmateurBandsCount - 1;
    }
    return 5; // Default 20m (14.074 MHz)
}

- (void)sendCATCommandAsync:(NSString *)catCmd description:(NSString *)desc {
    NSString *portPath = self.selectedPortProvider ? self.selectedPortProvider() : nil;
    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"[CAT TX] %@ (%@)", catCmd, desc]);
    }
    if (!portPath.length || self.demoModeActive) {
        return;
    }

    dispatch_async(_serialQueue, ^{
        NSError *err = nil;
        Lab599SerialPort *port = [Lab599SerialPort openPath:portPath speed:B9600 error:&err];
        if (!port) return;

        NSMutableString *cmd = [catCmd mutableCopy];
        if (![cmd hasSuffix:@";"]) [cmd appendString:@";"];
        NSData *cmdData = [cmd dataUsingEncoding:NSASCIIStringEncoding];
        Lab599Cancellation *tok = [Lab599Cancellation new];
        [port writeData:cmdData timeout:0.25 cancellation:tok error:nil];

        NSMutableData *resp = [NSMutableData data];
        double deadline = Lab599MonotonicTime() + 0.20;
        while (Lab599MonotonicTime() < deadline) {
            NSData *chunk = [port readMaximum:64 timeout:0.04 cancellation:tok error:nil];
            if (chunk.length > 0) {
                [resp appendData:chunk];
                NSData *semi = [@";" dataUsingEncoding:NSASCIIStringEncoding];
                if ([resp rangeOfData:semi options:0 range:NSMakeRange(0, resp.length)].location != NSNotFound) {
                    break;
                }
            }
        }
        [port close];

        if (resp.length > 0) {
            NSString *replyStr = [[NSString alloc] initWithData:resp encoding:NSASCIIStringEncoding];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.logHandler && replyStr.length > 0) {
                    self.logHandler([NSString stringWithFormat:@"[CAT RX] %@", [replyStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]]);
                }
            });
        }
    });
}

- (void)handleChassisControlPress:(TX500ChassisControlTag)tag atChassisPoint:(NSPoint)pt {
    switch (tag) {
        case TX500ControlPower:
            [self handlePowerCycle];
            break;
        case TX500ControlBandUp:
            [self handleBandUp];
            break;
        case TX500ControlBandDown:
            [self handleBandDown];
            break;
        case TX500ControlMode:
            [self handleModeCycle];
            break;
        case TX500ControlFilter:
            [self handleFilterCycle];
            break;
        case TX500ControlMenu:
            [self handleMenuAction];
            break;
        case TX500ControlTuneKnob: {
            // Single click on knob edge = one step
            CGFloat dy = pt.y - 168.0;
            CGFloat dx = pt.x - 685.0;
            [self handleTuneKnobDelta:(dy > 0 || dx > 0) ? 1.0 : -1.0];
            break;
        }
        case TX500ControlAFGainKnob: {
            CGFloat dy = pt.y - 315.0;
            CGFloat dx = pt.x - 658.0;
            [self handleAFGainKnobDelta:(dy > 0 || dx > 0) ? 1.0 : -1.0];
            break;
        }
        case TX500ControlRITXITKnob: {
            CGFloat dy = pt.y - 315.0;
            CGFloat dx = pt.x - 712.0;
            [self handleRITXITKnobDelta:(dy > 0 || dx > 0) ? 1.0 : -1.0];
            break;
        }


        case TX500ControlTopKey1:
            [self handleTopKey1];
            break;
        case TX500ControlTopKey2:
            [self handleTopKey2];
            break;
        case TX500ControlTopKey3:
            [self handleTopKey3];
            break;
        case TX500ControlTopKey4:
            [self handleTopKey4];
            break;
        case TX500ControlBottomKey1:
            [self handleBottomKey1];
            break;
        case TX500ControlBottomKey2:
            [self handleBottomKey2];
            break;
        case TX500ControlBottomKey3:
            [self handleBottomKey3];
            break;
        case TX500ControlBottomKey4:
            [self handleBottomKey4];
            break;

        // Far-right panel round buttons
        case TX500ControlRX: {
            // Toggle RX/TX manually (software PTT)
            BOOL nowTX = !self.screenState.isTransmitting;
            self.screenState.isTransmitting = nowTX;
            [self renderAndUpdateDisplay];
            NSString *pttCmd = nowTX ? @"TX;": @"RX;";
            [self showTemporaryFeedback:nowTX ? @"⚡ [R/X] → TRANSMIT" : @"⚡ [R/X] → RECEIVE"];
            [self sendCATCommandAsync:pttCmd description:nowTX ? @"PTT On" : @"PTT Off"];
            break;
        }
        case TX500ControlClear:
            // Clear RIT/XIT offset
            self.ritXITAngle = 0.0;
            [self renderAndUpdateDisplay];
            [self showTemporaryFeedback:@"⚡ [CLR] RIT/XIT Cleared"];
            [self sendCATCommandAsync:@"RC;" description:@"Clear RIT/XIT"];
            break;
        case TX500ControlVM:
            // VFO ↔ Memory toggle
            [self showTemporaryFeedback:@"⚡ [V/M] VFO↔Memory toggle"];
            [self sendCATCommandAsync:@"VR0;" description:@"VFO/Memory toggle"];
            break;

        case TX500ControlLock:
            [self showTemporaryFeedback:@"⚡ [LOCK] VFO Lock (hold for lock)"];
            [self sendCATCommandAsync:@"LK0;" description:@"VFO Lock"];
            break;
        case TX500ControlPlus: {
            // Step up by 1 kHz
            int64_t newF = (int64_t)self.screenState.frequencyHz + 1000LL;
            if (newF > 54000000) newF = 54000000;
            self.screenState.frequencyHz = (uint64_t)newF;
            self.tuneAngle += 0.15;
            [self renderAndUpdateDisplay];
            [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [+] +1 kHz → %.4f MHz", newF / 1000000.0]];
            [self sendCATCommandAsync:[NSString stringWithFormat:@"FA%011llu;", (unsigned long long)newF] description:@"Step +1kHz"];
            break;
        }
        case TX500ControlMinus: {
            // Step down by 1 kHz
            int64_t newF = (int64_t)self.screenState.frequencyHz - 1000LL;
            if (newF < 500000) newF = 500000;
            self.screenState.frequencyHz = (uint64_t)newF;
            self.tuneAngle -= 0.15;
            [self renderAndUpdateDisplay];
            [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [-] -1 kHz → %.4f MHz", newF / 1000000.0]];
            [self sendCATCommandAsync:[NSString stringWithFormat:@"FA%011llu;", (unsigned long long)newF] description:@"Step -1kHz"];
            break;
        }
        default:
            break;
    }
}

- (void)handleBandUp {
    uint64_t currentFreq = self.screenState.frequencyHz;
    NSUInteger currentIdx = [self bandIndexForFrequency:currentFreq];
    NSUInteger nextIdx = (currentIdx + 1) % kAmateurBandsCount;
    uint64_t newFreq = kAmateurBands[nextIdx];

    self.screenState.frequencyHz = newFreq;
    [self renderAndUpdateDisplay];

    NSString *cmd = [NSString stringWithFormat:@"FA%011llu;", (unsigned long long)newFreq];
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [BAND+] %@ (%08.4f MHz)", @(kAmateurBandNames[nextIdx]), (double)newFreq / 1000000.0]];
    [self sendCATCommandAsync:cmd description:[NSString stringWithFormat:@"Band+ to %@", @(kAmateurBandNames[nextIdx])]];
}

- (void)handleBandDown {
    uint64_t currentFreq = self.screenState.frequencyHz;
    NSUInteger currentIdx = [self bandIndexForFrequency:currentFreq];
    NSUInteger prevIdx = (currentIdx == 0) ? (kAmateurBandsCount - 1) : (currentIdx - 1);
    uint64_t newFreq = kAmateurBands[prevIdx];

    self.screenState.frequencyHz = newFreq;
    [self renderAndUpdateDisplay];

    NSString *cmd = [NSString stringWithFormat:@"FA%011llu;", (unsigned long long)newFreq];
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [BAND-] %@ (%08.4f MHz)", @(kAmateurBandNames[prevIdx]), (double)newFreq / 1000000.0]];
    [self sendCATCommandAsync:cmd description:[NSString stringWithFormat:@"Band- to %@", @(kAmateurBandNames[prevIdx])]];
}

- (void)handleModeCycle {
    NSArray *modes = @[@"USB", @"CW", @"DIG", @"FM", @"AM", @"LSB"];
    NSDictionary *modeCodes = @{
        @"LSB": @(1), @"USB": @(2), @"CW": @(3),
        @"FM": @(4), @"AM": @(5), @"DIG": @(6)
    };
    NSString *curr = self.screenState.operatingMode ?: @"USB";
    NSUInteger idx = [modes indexOfObject:curr];
    if (idx == NSNotFound) idx = 0;
    NSUInteger nextIdx = (idx + 1) % modes.count;
    NSString *newMode = modes[nextIdx];

    self.screenState.operatingMode = newMode;

    NSInteger fil = self.screenState.filterNumber > 0 ? self.screenState.filterNumber : 1;
    if ([newMode isEqualToString:@"CW"]) {
        self.screenState.filterBandwidthString = (fil == 1) ? @"0.50k" : ((fil == 2) ? @"0.30k" : @"0.10k");
    } else if ([newMode isEqualToString:@"AM"]) {
        self.screenState.filterBandwidthString = (fil == 1) ? @"6.00k" : ((fil == 2) ? @"4.00k" : @"3.00k");
    } else {
        self.screenState.filterBandwidthString = (fil == 1) ? @"3.10k" : ((fil == 2) ? @"2.40k" : @"1.80k");
    }

    [self renderAndUpdateDisplay];

    NSInteger code = [modeCodes[newMode] integerValue];
    NSString *cmd = [NSString stringWithFormat:@"MD%ld;", (long)code];
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [MODE] Switched to %@ (MD%ld;)", newMode, (long)code]];
    [self sendCATCommandAsync:cmd description:[NSString stringWithFormat:@"Set Mode %@", newMode]];
}

- (void)handleFilterCycle {
    NSInteger curr = self.screenState.filterNumber > 0 ? self.screenState.filterNumber : 1;
    NSInteger next = (curr % 4) + 1;  // Cycle 1→2→3→4→1
    self.screenState.filterNumber = next;
    self.screenState.filterName = [NSString stringWithFormat:@"FIL-%ld", (long)next];

    NSString *mode = self.screenState.operatingMode ?: @"USB";
    if ([mode isEqualToString:@"CW"] || [mode isEqualToString:@"CWR"]) {
        if (next == 1) self.screenState.filterBandwidthString = @"0.50k";
        else if (next == 2) self.screenState.filterBandwidthString = @"0.30k";
        else if (next == 3) self.screenState.filterBandwidthString = @"0.10k";
        else self.screenState.filterBandwidthString = @"0.05k";
    } else if ([mode isEqualToString:@"AM"]) {
        if (next == 1) self.screenState.filterBandwidthString = @"6.00k";
        else if (next == 2) self.screenState.filterBandwidthString = @"4.00k";
        else if (next == 3) self.screenState.filterBandwidthString = @"3.00k";
        else self.screenState.filterBandwidthString = @"2.00k";
    } else {
        if (next == 1) self.screenState.filterBandwidthString = @"3.10k";
        else if (next == 2) self.screenState.filterBandwidthString = @"2.40k";
        else if (next == 3) self.screenState.filterBandwidthString = @"1.80k";
        else self.screenState.filterBandwidthString = @"1.00k";
    }

    [self renderAndUpdateDisplay];

    // TX-500 CAT is 0-indexed: FIL1=FL0;, FIL2=FL1;, FIL3=FL2;, FIL4=FL3;
    NSInteger flIndex = next - 1;
    NSString *cmd = [NSString stringWithFormat:@"FL%ld;", (long)flIndex];
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [FILTER] %@ → %@ (%@)", self.screenState.filterName, cmd, self.screenState.filterBandwidthString]];
    [self sendCATCommandAsync:cmd description:[NSString stringWithFormat:@"Set Filter %ld (FL%ld;)", (long)next, (long)flIndex]];
}

- (void)handlePowerCycle {
    double curr = self.screenState.rfPowerWatts;
    double nextWatts = 1.0;
    if (curr < 1.5) nextWatts = 2.5;
    else if (curr < 4.0) nextWatts = 5.0;
    else if (curr < 7.0) nextWatts = 10.0;
    else nextWatts = 1.0;

    self.screenState.rfPowerWatts = nextWatts;
    [self renderAndUpdateDisplay];

    // TX-500 PC command: tenths-of-watt, 3 digits. e.g. 5W = PC050; 10W = PC100;
    int tenths = (int)round(nextWatts * 10.0);
    NSString *cmd = [NSString stringWithFormat:@"PC%03d;", tenths];
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [POWER] RF Output: %.1f W (%@)", nextWatts, cmd]];
    [self sendCATCommandAsync:cmd description:[NSString stringWithFormat:@"Set Power %.1fW", nextWatts]];
}

- (void)handleMenuAction {
    uint64_t tmpFreq = self.screenState.frequencyHz;
    self.screenState.frequencyHz = self.screenState.vfoBFrequencyHz > 0 ? self.screenState.vfoBFrequencyHz : 14074000ULL;
    self.screenState.vfoBFrequencyHz = tmpFreq;

    NSString *tmpMode = self.screenState.operatingMode;
    self.screenState.operatingMode = self.screenState.vfoBMode ?: @"USB";
    self.screenState.vfoBMode = tmpMode;

    self.screenState.activeVFO = (self.screenState.activeVFO == 0) ? 1 : 0;
    [self renderAndUpdateDisplay];

    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [MENU] Swapped VFO-A / VFO-B (%08.4f MHz)", (double)self.screenState.frequencyHz / 1000000.0]];
    [self sendCATCommandAsync:@"FR0;FT0;" description:@"VFO Swap"];
}

- (void)handleTuneKnobDelta:(CGFloat)delta {
    CGFloat absDelta = fabs(delta);

    // Acceleration curve — speed of drag determines tuning step
    // Gives real knob feel: slow turn = fine, fast spin = coarse
    int64_t step;
    CGFloat anglePerStep;
    if (absDelta < 0.8) {
        step = 100;       // Sub-pixel micro-drag: 100 Hz (fine tune)
        anglePerStep = 0.04;
    } else if (absDelta < 4.0) {
        step = 500;       // Normal drag: 500 Hz (default)
        anglePerStep = 0.10;
    } else if (absDelta < 10.0) {
        step = 2000;      // Fast: 2 kHz
        anglePerStep = 0.18;
    } else if (absDelta < 20.0) {
        step = 5000;      // Very fast: 5 kHz
        anglePerStep = 0.25;
    } else {
        step = 25000;     // Spin: 25 kHz
        anglePerStep = 0.35;
    }

    int64_t change = (delta > 0) ? step : -step;
    int64_t newFreq = (int64_t)self.screenState.frequencyHz + change;
    if (newFreq < 500000)   newFreq = 500000;
    if (newFreq > 54000000) newFreq = 54000000;

    self.screenState.frequencyHz = (uint64_t)newFreq;

    // Rotate knob proportionally to step (direction-correct)
    self.tuneAngle += (delta > 0) ? anglePerStep : -anglePerStep;
    // Keep angle in 0…2π for consistent rendering
    while (self.tuneAngle >  M_PI)  self.tuneAngle -= 2.0 * M_PI;
    while (self.tuneAngle < -M_PI)  self.tuneAngle += 2.0 * M_PI;

    [self renderAndUpdateDisplay];

    NSString *cmd = [NSString stringWithFormat:@"FA%011llu;", (unsigned long long)self.screenState.frequencyHz];
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [TUNE] %08.4f MHz (%+lld Hz)", (double)newFreq / 1000000.0, (long long)change]];
    [self sendCATCommandAsync:cmd description:@"Tune VFO"];
}

- (void)handleAFGainKnobDelta:(CGFloat)delta {
    CGFloat absDelta = fabs(delta);

    // Acceleration: sub-pixel = 1 unit (fine detent), normal ≥0.5 = 5 (default), fast = 15
    // delta=1.0 must give change=5 to match test contract
    NSInteger change;
    if (absDelta < 0.5) {
        change = 1;   // Micro-drag: fine control (0 unit per sub-pixel)
    } else if (absDelta < 7.0) {
        change = 5;   // Normal drag: 5 units (matches test: delta=1.0 → +5)
    } else {
        change = 15;  // Fast spin: 15 units
    }
    if (delta < 0) change = -change;

    NSInteger newLevel = self.screenState.afGainLevel + change;
    if (newLevel < 0)   newLevel = 0;
    if (newLevel > 100) newLevel = 100;

    self.screenState.afGainLevel = newLevel;

    // Map AF level 0–100 → knob angle -3π/4 … +3π/4 (-135° to +135°)
    // This makes knob position always match the actual volume
    self.afGainAngle = ((newLevel / 100.0) * (1.5 * M_PI)) - (0.75 * M_PI);

    [self renderAndUpdateDisplay];

    NSString *cmd = [NSString stringWithFormat:@"AG0%03ld;", (long)newLevel];
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [AF GAIN] Volume: %ld%%", (long)newLevel]];
    [self sendCATCommandAsync:cmd description:@"Set AF Gain"];
}

- (void)handleRITXITKnobDelta:(CGFloat)delta {
    // RIT/XIT knob: visually rotate and could offset receive frequency.
    // For now we rotate the knob angle display and log the action.
    // delta > 0 = clockwise, delta < 0 = counter-clockwise
    CGFloat angleStep = 0.25; // radians per step
    self.ritXITAngle += (delta > 0) ? angleStep : -angleStep;
    while (self.ritXITAngle >  M_PI) self.ritXITAngle -= 2.0 * M_PI;
    while (self.ritXITAngle < -M_PI) self.ritXITAngle += 2.0 * M_PI;
    [self renderAndUpdateDisplay];
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [RIT/XIT] %.0f°", self.ritXITAngle * 180.0 / M_PI]];
}

- (void)handleTopKey1 {
    self.screenState.preamp = !self.screenState.preamp;
    [self renderAndUpdateDisplay];
    NSString *cmd = self.screenState.preamp ? @"PA1;" : @"PA0;";
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [PREAMP] %@", self.screenState.preamp ? @"ON (+10dB)" : @"OFF"]];
    [self sendCATCommandAsync:cmd description:@"Preamp Toggle"];
}

- (void)handleTopKey2 {
    self.screenState.attenuator = !self.screenState.attenuator;
    [self renderAndUpdateDisplay];
    NSString *cmd = self.screenState.attenuator ? @"RA1;" : @"RA0;";
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [ATT] %@", self.screenState.attenuator ? @"ON (-20dB)" : @"OFF"]];
    [self sendCATCommandAsync:cmd description:@"Attenuator Toggle"];
}

- (void)handleTopKey3 {
    self.screenState.noiseReduction = !self.screenState.noiseReduction;
    [self renderAndUpdateDisplay];
    NSString *cmd = self.screenState.noiseReduction ? @"NR1;" : @"NR0;";
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [NR] Noise Reduction: %@", self.screenState.noiseReduction ? @"ON" : @"OFF"]];
    [self sendCATCommandAsync:cmd description:@"NR Toggle"];
}

- (void)handleTopKey4 {
    self.screenState.noiseBlanker = !self.screenState.noiseBlanker;
    [self renderAndUpdateDisplay];
    NSString *cmd = self.screenState.noiseBlanker ? @"NB1;" : @"NB0;";
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [NB] Noise Blanker: %@", self.screenState.noiseBlanker ? @"ON" : @"OFF"]];
    [self sendCATCommandAsync:cmd description:@"NB Toggle"];
}

- (void)handleBottomKey1 {
    [self handleMenuAction];
}

- (void)handleBottomKey2 {
    self.screenState.split = !self.screenState.split;
    [self renderAndUpdateDisplay];
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [SPLIT] %@", self.screenState.split ? @"SPLIT ON" : @"SPLIT OFF"]];
    [self sendCATCommandAsync:self.screenState.split ? @"FT1;" : @"FT0;" description:@"Split Toggle"];
}

- (void)handleBottomKey3 {
    self.screenState.ritActive = !self.screenState.ritActive;
    [self renderAndUpdateDisplay];
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [RIT] %@", self.screenState.ritActive ? @"RIT ON (+0.00 kHz)" : @"RIT OFF"]];
    [self sendCATCommandAsync:self.screenState.ritActive ? @"RT1;" : @"RT0;" description:@"RIT Toggle"];
}

- (void)handleBottomKey4 {
    self.screenState.isTransmitting = !self.screenState.isTransmitting;
    if (self.screenState.isTransmitting) {
        self.screenState.rfPowerWatts = 10.0;
        self.screenState.swr = 1.15;
    } else {
        self.screenState.rfPowerWatts = 0.0;
        self.screenState.swr = 1.0;
    }
    [self renderAndUpdateDisplay];
    [self showTemporaryFeedback:[NSString stringWithFormat:@"⚡ [TX / PTT] %@", self.screenState.isTransmitting ? @"TRANSMITTING (10.0W)" : @"RECEIVING"]];
    [self sendCATCommandAsync:self.screenState.isTransmitting ? @"TX;" : @"RX;" description:@"PTT Toggle"];
}

- (void)updateHUDLabel {
    uint64_t freq = self.screenState.activeVFO == 0 ? self.screenState.frequencyHz : self.screenState.vfoBFrequencyHz;
    double mhz = (double)freq / 1000000.0;
    NSString *vfoName = self.screenState.activeVFO == 0 ? @"VFO-A" : @"VFO-B";
    NSString *mode = self.screenState.operatingMode ?: @"USB";
    
    NSString *meterText = @"";
    if (self.screenState.isTransmitting) {
        meterText = [NSString stringWithFormat:@"TX PWR: %.1f W  SWR: %.2f",
                     self.screenState.rfPowerWatts, self.screenState.swr];
    } else {
        meterText = [NSString stringWithFormat:@"S-MTR: %ld dots", (long)self.screenState.sMeterDots];
    }

    NSString *voltText = [NSString stringWithFormat:@"%.1fV", self.screenState.supplyVoltage];
    NSString *modeText = self.demoModeActive ? @"[DEMO SIMULATION]" : @"[LIVE CAT 9600]";

    self.hudTelemetryLabel.stringValue = [NSString stringWithFormat:
        @"%@: %08.4f MHz | %@ (%@) | AF:%ld RF:%ld | %@ | %@ | %@",
        vfoName, mhz, mode, self.screenState.filterBandwidthString ?: @"3.10k",
        (long)(self.screenState.afGainLevel > 0 ? self.screenState.afGainLevel : 64),
        (long)self.screenState.rfGainLevel,
        meterText, voltText, modeText];
}

- (void)showTemporaryFeedback:(NSString *)msg {
    self.statusFeedbackLabel.stringValue = msg;
    [self.feedbackTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.feedbackTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        weakSelf.statusFeedbackLabel.stringValue = @"";
    }];
}

#pragma mark - UI Actions

- (void)themeChanged:(id)sender {
    self.currentTheme = (TX500ScreenTheme)self.themePopup.indexOfSelectedItem;
    [self renderAndUpdateDisplay];
}

- (void)viewModeChanged:(id)sender {
    NSInteger idx = self.viewModePopup.indexOfSelectedItem;
    if (idx == 0) {
        self.showChassisBezel = YES;
        self.displayScale = 2.0;
    } else if (idx == 1) {
        self.showChassisBezel = NO;
        self.displayScale = 3.0;
    } else if (idx == 2) {
        self.showChassisBezel = NO;
        self.displayScale = 2.0;
    } else {
        self.showChassisBezel = NO;
        self.displayScale = 1.0;
    }
    [self renderAndUpdateDisplay];
}

- (void)pixelGridToggled:(id)sender {
    self.showPixelGrid = (self.pixelGridCheckbox.state == NSControlStateValueOn);
    [self renderAndUpdateDisplay];
}

- (void)modePickerChanged:(id)sender {
    self.demoModeActive = (self.modePicker.selectedSegment == 1);
    if (self.demoModeActive) {
        [self stopLiveSync];
        [self startDemoTimer];
        [self showTemporaryFeedback:@"Demo Simulation Active"];
    } else {
        [self stopDemoTimer];
        if (self.liveSyncActive) {
            [self startLiveSync];
        } else {
            [self refreshSnapshotFromRadio];
        }
    }
}

- (void)autoSyncToggled:(id)sender {
    self.liveSyncActive = (self.autoSyncCheckbox.state == NSControlStateValueOn);
    if (self.liveSyncActive) {
        if (!self.demoModeActive) {
            [self startLiveSync];
        }
    } else {
        [self stopLiveSync];
    }
}

- (void)captureNowAction:(id)sender {
    (void)sender;
    if (self.demoModeActive) {
        [self advanceDemoState];
        [self renderAndUpdateDisplay];
        [self showTemporaryFeedback:@"Demo Snapshot Updated"];
    } else {
        [self refreshSnapshotFromRadio];
    }
}

- (void)toggleBezelAction:(id)sender {
    (void)sender;
    self.showChassisBezel = !self.showChassisBezel;
    [self.viewModePopup selectItemAtIndex:self.showChassisBezel ? 0 : 2];
    [self renderAndUpdateDisplay];
}

- (void)togglePixelGridAction:(id)sender {
    (void)sender;
    self.showPixelGrid = !self.showPixelGrid;
    self.pixelGridCheckbox.state = self.showPixelGrid ? NSControlStateValueOn : NSControlStateValueOff;
    [self renderAndUpdateDisplay];
}

- (void)menuSelectTheme:(NSMenuItem *)item {
    self.currentTheme = (TX500ScreenTheme)item.tag;
    [self.themePopup selectItemAtIndex:item.tag];
    [self renderAndUpdateDisplay];
}

#pragma mark - Copy and Save

- (void)copyToClipboardAction:(id)sender {
    (void)sender;
    [self copyScreenshotToClipboard];
}

- (void)saveScreenshotAction:(id)sender {
    (void)sender;
    [self saveScreenshotDialog];
}

- (void)copyScreenshotToClipboard {
    NSImage *image = self.displayView.renderedImage;
    if (!image) {
        [self renderAndUpdateDisplay];
        image = self.displayView.renderedImage;
    }
    if (!image) return;

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb writeObjects:@[image]];

    [self showTemporaryFeedback:@"Screen copied to clipboard!"];
    if (self.logHandler) {
        self.logHandler(@"TX-500 Screen screenshot copied to clipboard.");
    }
}

- (void)saveScreenshotDialog {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Save TX-500 Screen Screenshot";
    panel.canCreateDirectories = YES;

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyyMMdd_HHmmss";
    NSString *dateStr = [df stringFromDate:[NSDate date]];
    panel.nameFieldStringValue = [NSString stringWithFormat:@"TX500_Screen_%@.png", dateStr];
    panel.allowedContentTypes = @[UTTypePNG, UTTypeJPEG];

    // Accessory view for format/bezel options
    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 70)];

    NSTextField *formatLbl = [NSTextField labelWithString:@"Format:"];
    formatLbl.frame = NSMakeRect(10, 38, 70, 20);
    formatLbl.font = [NSFont systemFontOfSize:11];

    NSPopUpButton *formatPop = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(85, 36, 220, 24) pullsDown:NO];
    formatPop.controlSize = NSControlSizeSmall;
    formatPop.font = [NSFont systemFontOfSize:11];
    [formatPop addItemsWithTitles:@[
        @"PNG: Chassis Bezel (640x360)",
        @"PNG: Native Screen 1x (256x128)",
        @"PNG: Scaled Screen 2x (512x256)",
        @"PNG: Scaled Screen 4x (1024x512)",
        @"JPEG: High Quality (90%)"
    ]];
    if (!self.showChassisBezel) {
        [formatPop selectItemAtIndex:2]; // Default to 2x screen
    }

    NSButton *gridOption = [NSButton checkboxWithTitle:@"Include LCD pixel matrix texture" target:nil action:nil];
    gridOption.frame = NSMakeRect(10, 10, 300, 20);
    gridOption.controlSize = NSControlSizeSmall;
    gridOption.font = [NSFont systemFontOfSize:11];
    gridOption.state = self.showPixelGrid ? NSControlStateValueOn : NSControlStateValueOff;

    [accessory addSubview:formatLbl];
    [accessory addSubview:formatPop];
    [accessory addSubview:gridOption];
    panel.accessoryView = accessory;

    [panel beginSheetModalForWindow:self.window ?: [NSApp keyWindow] completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK) return;

        NSURL *url = panel.URL;
        if (!url) return;

        NSInteger choice = formatPop.indexOfSelectedItem;
        BOOL useGrid = (gridOption.state == NSControlStateValueOn);

        NSImage *exportImg = nil;
        BOOL isJPEG = (choice == 4);

        if (choice == 0 || (choice == 4 && self.showChassisBezel)) {
            exportImg = [TX500ScreenRenderer renderChassisImageWithState:self.screenState
                                                                   theme:self.currentTheme
                                                               pixelGrid:useGrid];
        } else if (choice == 1) {
            exportImg = [TX500ScreenRenderer renderScreenImageWithState:self.screenState
                                                                  theme:self.currentTheme
                                                                  scale:1.0
                                                              pixelGrid:useGrid];
        } else if (choice == 2) {
            exportImg = [TX500ScreenRenderer renderScreenImageWithState:self.screenState
                                                                  theme:self.currentTheme
                                                                  scale:2.0
                                                              pixelGrid:useGrid];
        } else if (choice == 3) {
            exportImg = [TX500ScreenRenderer renderScreenImageWithState:self.screenState
                                                                  theme:self.currentTheme
                                                                  scale:4.0
                                                              pixelGrid:useGrid];
        } else {
            exportImg = [TX500ScreenRenderer renderScreenImageWithState:self.screenState
                                                                  theme:self.currentTheme
                                                                  scale:2.0
                                                              pixelGrid:useGrid];
        }

        NSData *fileData = nil;
        if (isJPEG) {
            fileData = [TX500ScreenRenderer jpegDataForImage:exportImg compression:0.90];
        } else {
            fileData = [TX500ScreenRenderer pngDataForImage:exportImg];
        }

        if (fileData) {
            NSError *err = nil;
            if ([fileData writeToURL:url options:NSDataWritingAtomic error:&err]) {
                [self showTemporaryFeedback:[NSString stringWithFormat:@"Saved %@", url.lastPathComponent]];
                if (self.logHandler) {
                    self.logHandler([NSString stringWithFormat:@"Screenshot saved: %@", url.path]);
                }
            } else {
                if (self.logHandler) {
                    self.logHandler([NSString stringWithFormat:@"Error saving screenshot: %@", err.localizedDescription]);
                }
            }
        }
    }];
}

#pragma mark - Simulation / Demo Mode

- (void)startDemoTimer {
    [_demoTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _demoTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf advanceDemoState];
        [weakSelf renderAndUpdateDisplay];
    }];
}

- (void)stopDemoTimer {
    [_demoTimer invalidate];
    _demoTimer = nil;
}

- (void)advanceDemoState {
    _demoPhase += 0.25;
    if (_demoPhase >= 15.0) {
        _demoPhase = 0.0;
        _demoCycleCount++;
    }

    // Real-time local clock string (format: HH:mm)
    NSDateFormatter *df = [NSDateFormatter new];
    df.timeZone = [NSTimeZone systemTimeZone];
    df.dateFormat = @"HH:mm";
    self.screenState.clockString = [df stringFromDate:[NSDate date]];

    // 15-second FT8 cycle: 0.0s to 12.6s RX, 12.6s to 14.8s TX
    if (_demoPhase < 12.6) {
        // RX Phase
        self.screenState.isTransmitting = NO;
        self.screenState.rfPowerWatts = 0.0;
        self.screenState.swr = 1.0;

        // Fluctuating S-meter around S7 (14 dots)
        double wave = sin(_demoPhase * 1.5) * cos(_demoPhase * 0.7);
        NSInteger dots = 14 + (NSInteger)(wave * 3.0);
        if (dots < 4) dots = 4;
        if (dots > 26) dots = 26;
        self.screenState.sMeterDots = dots;

        // Dynamic spectrum points (FT8 digital signal block matching real radio)
        NSMutableArray<NSNumber *> *spec = [NSMutableArray arrayWithCapacity:64];
        for (NSInteger i = 0; i < 64; i++) {
            double noise = 0.04 + (((double)arc4random_uniform(100)) / 2200.0);
            if (i >= 29 && i <= 36) {
                // Realistic FT8 carrier block rising up to ~0.74
                double sig = 0.72 * (1.0 - fabs(i - 32.5) / 5.5);
                noise += sig;
            }
            if (noise > 1.0) noise = 1.0;
            [spec addObject:@(noise)];
        }
        self.screenState.spectrumAmplitudes = spec;
    } else {
        // TX Phase (transmitting FT8 CQ reply)
        self.screenState.isTransmitting = YES;
        self.screenState.sMeterDots = 0;
        self.screenState.rfPowerWatts = 10.0;
        self.screenState.swr = 1.12;

        // High transmit spike in spectrum around center passband
        NSMutableArray<NSNumber *> *spec = [NSMutableArray arrayWithCapacity:64];
        for (NSInteger i = 0; i < 64; i++) {
            double txSpike = exp(-pow(i - 32.5, 2) / 2.0) * 0.90;
            double lowNoise = 0.02 + (((double)arc4random_uniform(100)) / 2500.0);
            double val = txSpike + lowNoise;
            if (val > 1.0) val = 1.0;
            [spec addObject:@(val)];
        }
        self.screenState.spectrumAmplitudes = spec;
    }

    self.screenState.supplyVoltage = 12.0;
    self.screenState.batteryPercent = 88;
    self.screenState.isBatteryPowered = YES;
}

#pragma mark - Live CAT Polling Loop

- (void)startLiveSync {
    [_livePollTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _livePollTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        [weakSelf pollRadioParameters];
    }];
}

- (void)stopLiveSync {
    [_livePollTimer invalidate];
    _livePollTimer = nil;
}

- (void)refreshSnapshotFromRadio {
    [self pollRadioParameters];
}

- (void)pollRadioParameters {
    if (_isPolling) return;

    NSString *portPath = self.selectedPortProvider ? self.selectedPortProvider() : nil;
    if (!portPath.length) {
        // No port selected; do not spam logs
        return;
    }

    _isPolling = YES;

    dispatch_async(_serialQueue, ^{
        NSError *err = nil;
        Lab599SerialPort *port = [Lab599SerialPort openPath:portPath speed:B9600 error:&err];
        if (!port) {
            self->_isPolling = NO;
            return;
        }

        // Helper to send query and read response terminated with ';'
        NSString *(^queryRadio)(NSString *) = ^NSString *(NSString *cmd) {
            NSMutableString *s = [cmd mutableCopy];
            if (![s hasSuffix:@";"]) [s appendString:@";"];
            [port discardInput:nil];
            NSData *data = [s dataUsingEncoding:NSASCIIStringEncoding];
            Lab599Cancellation *tok = [Lab599Cancellation new];
            if (![port writeData:data timeout:0.25 cancellation:tok error:nil]) return nil;

            NSMutableData *resp = [NSMutableData data];
            double deadline = Lab599MonotonicTime() + 0.25;
            while (Lab599MonotonicTime() < deadline) {
                NSData *chunk = [port readMaximum:64 timeout:0.04 cancellation:tok error:nil];
                if (chunk.length > 0) {
                    [resp appendData:chunk];
                    NSData *semi = [@";" dataUsingEncoding:NSASCIIStringEncoding];
                    if ([resp rangeOfData:semi options:0 range:NSMakeRange(0, resp.length)].location != NSNotFound) {
                        break;
                    }
                }
            }
            if (resp.length > 0) {
                return [[NSString alloc] initWithData:resp encoding:NSASCIIStringEncoding];
            }
            return nil;
        };

        // Query Model Identification (ID;)
        NSString *idResp = queryRadio(@"ID;");
        NSString *detectedModel = nil;
        if (idResp) {
            if ([idResp containsString:@"ID019"] || [idResp containsString:@"ID500"]) {
                detectedModel = @"DISCOVERY";
            } else if ([idResp containsString:@"MP"] || [idResp containsString:@"020"]) {
                detectedModel = @"TX-500MP";
            } else if ([idResp containsString:@"ALTAI"]) {
                detectedModel = @"PRO ALTAI";
            } else if ([idResp containsString:@"PRO"]) {
                detectedModel = @"TX-500PRO";
            }
        }

        // Query Frequency (FA;)
        NSString *fa = queryRadio(@"FA;");
        uint64_t freqA = 0;
        if (fa && [fa hasPrefix:@"FA"] && fa.length >= 13) {
            NSString *digits = [fa substringWithRange:NSMakeRange(2, 11)];
            freqA = (uint64_t)[digits longLongValue];
        }

        // Query VFO-B (FB;)
        NSString *fb = queryRadio(@"FB;");
        uint64_t freqB = 0;
        if (fb && [fb hasPrefix:@"FB"] && fb.length >= 13) {
            NSString *digits = [fb substringWithRange:NSMakeRange(2, 11)];
            freqB = (uint64_t)[digits longLongValue];
        }

        // Query Mode (MD;)
        NSString *md = queryRadio(@"MD;");
        NSString *modeStr = nil;
        if (md && [md hasPrefix:@"MD"] && md.length >= 3) {
            unichar mChar = [md characterAtIndex:2];
            switch (mChar) {
                case '1': modeStr = @"LSB"; break;
                case '2': modeStr = @"USB"; break;  // Kenwood MD2 = USB
                case '3': modeStr = @"CW";  break;
                case '4': modeStr = @"FM";  break;
                case '5': modeStr = @"AM";  break;
                case '6': modeStr = @"DIG"; break;  // TX-500 DIG/FSK = MD6
                case '7': modeStr = @"CWR"; break;
                case '9': modeStr = @"FSK"; break;
                default:  modeStr = @"USB"; break;
            }
        }

        // Query Comprehensive Status / PTT (IF;)
        NSString *ifRep = queryRadio(@"IF;");
        BOOL isTX = NO;
        if (ifRep && [ifRep hasPrefix:@"IF"] && ifRep.length >= 28) {
            NSString *clean = [ifRep stringByReplacingOccurrencesOfString:@";" withString:@""];
            if (clean.length > 28) {
                isTX = ([clean characterAtIndex:28] == '1');
            }
        }

        // Query S-Meter (SM0;)
        NSString *sm = queryRadio(@"SM0;");
        NSInteger sMeter = 0;
        if (sm && [sm hasPrefix:@"SM"] && sm.length >= 4) {
            NSString *clean = [sm stringByReplacingOccurrencesOfString:@";" withString:@""];
            if (clean.length > 3) {
                sMeter = [[clean substringFromIndex:3] integerValue];
            } else if (clean.length > 2) {
                sMeter = [[clean substringFromIndex:2] integerValue];
            }
        }

        // Query Voltage (VL;)
        NSString *vl = queryRadio(@"VL;");
        double voltage = 0.0;
        if (vl && [vl hasPrefix:@"VL"]) {
            NSString *vStr = [vl substringFromIndex:2];
            if ([vStr hasSuffix:@";"]) vStr = [vStr substringToIndex:vStr.length - 1];
            voltage = [vStr doubleValue];
        }

        // Query AF Gain (AG0;) → AG0nnn; where nnn = 000–100
        NSString *ag = queryRadio(@"AG0;");
        NSInteger afGainValue = -1;  // -1 means "no valid response"
        if (ag && [ag hasPrefix:@"AG"] && ag.length >= 6) {
            NSString *clean = [ag stringByReplacingOccurrencesOfString:@";" withString:@""];
            if (clean.length >= 5) {
                NSString *numStr = [clean substringWithRange:NSMakeRange(3, clean.length - 3)];
                NSInteger parsed = [numStr integerValue];
                if (parsed >= 0 && parsed <= 100) {
                    afGainValue = parsed;
                }
            }
        }

        // Query Filter Preset (FL;)
        // TX-500 returns FL21; — char at index 2 is the filter number (1-4), rest is bandwidth indicator
        NSString *fl = queryRadio(@"FL;");
        NSInteger filterNum = 1;
        NSInteger filterBw = 0;
        if (fl && [fl hasPrefix:@"FL"] && fl.length >= 3) {
            unichar fc = [fl characterAtIndex:2];
            int n = (int)(fc - '0');
            if (n >= 1 && n <= 4) {
                filterNum = n;
            }
        }

        // Query Filter Bandwidth (FW;) if supported
        NSString *fw = queryRadio(@"FW;");
        if (fw && [fw hasPrefix:@"FW"] && fw.length >= 6) {
            NSString *bwStr = [fw substringWithRange:NSMakeRange(2, 4)];
            filterBw = [bwStr integerValue] * 10;
        }

        // Query Preamp (PA;)
        NSString *pa = queryRadio(@"PA;");
        BOOL preampOn = NO;
        if (pa && [pa hasPrefix:@"PA"] && pa.length >= 3) {
            preampOn = ([pa characterAtIndex:2] == '1');
        }

        // Query Attenuator (RA;)
        NSString *ra = queryRadio(@"RA;");
        BOOL attOn = NO;
        if (ra && [ra hasPrefix:@"RA"] && ra.length >= 3) {
            attOn = ([ra characterAtIndex:2] == '1');
        }

        // Query Noise Reduction (NR;)
        NSString *nr = queryRadio(@"NR;");
        BOOL nrOn = NO;
        if (nr && [nr hasPrefix:@"NR"] && nr.length >= 3) {
            nrOn = ([nr characterAtIndex:2] == '1');
        }

        // Query Noise Blanker (NB;)
        NSString *nb = queryRadio(@"NB;");
        BOOL nbOn = NO;
        if (nb && [nb hasPrefix:@"NB"] && nb.length >= 3) {
            nbOn = ([nb characterAtIndex:2] == '1');
        }

        // Query Notch (NT;)
        NSString *nt = queryRadio(@"NT;");
        BOOL ntOn = NO;
        if (nt && [nt hasPrefix:@"NT"] && nt.length >= 3) {
            ntOn = ([nt characterAtIndex:2] == '1');
        }

        // Local clock strictly using Mac system local time
        NSDateFormatter *localDf = [NSDateFormatter new];
        localDf.dateFormat = @"HH:mm";
        localDf.timeZone = [NSTimeZone systemTimeZone];
        NSString *timeStr = [localDf stringFromDate:[NSDate date]];

        // Flat gentle noise floor for live spectrum
        NSMutableArray<NSNumber *> *liveSpec = [NSMutableArray arrayWithCapacity:64];
        for (NSInteger i = 0; i < 64; i++) {
            double baseNoise = 0.03 + (((double)arc4random_uniform(100)) / 4000.0);
            [liveSpec addObject:@(baseNoise)];
        }

        [port close];

        // Update state on Main Queue
        dispatch_async(dispatch_get_main_queue(), ^{
            if (detectedModel.length > 0) self.screenState.hardwareModelName = detectedModel;
            if (freqA > 0) self.screenState.frequencyHz = freqA;
            if (freqB > 0) self.screenState.vfoBFrequencyHz = freqB;
            if (modeStr.length > 0) self.screenState.operatingMode = modeStr;
            self.screenState.isTransmitting = isTX;
            self.screenState.sMeterDots = sMeter;
            if (voltage > 0.0) {
                self.screenState.supplyVoltage = voltage;
                if (voltage <= 12.8) {
                    self.screenState.isBatteryPowered = YES;
                    self.screenState.batteryPercent = (NSInteger)(((voltage - 9.6) / 3.0) * 100.0);
                    if (self.screenState.batteryPercent < 0) self.screenState.batteryPercent = 0;
                    if (self.screenState.batteryPercent > 100) self.screenState.batteryPercent = 100;
                } else {
                    self.screenState.isBatteryPowered = NO;
                }
            }

            self.screenState.filterNumber = filterNum;
            self.screenState.filterName = [NSString stringWithFormat:@"FIL-%ld", (long)filterNum];
            if (filterBw > 0) {
                self.screenState.filterBandwidthHz = filterBw;
                self.screenState.filterBandwidthString = [NSString stringWithFormat:@"%.2fk", (double)filterBw / 1000.0];
            } else {
                NSString *activeM = self.screenState.operatingMode ?: @"DIG";
                if ([activeM isEqualToString:@"CW"] || [activeM isEqualToString:@"CWR"]) {
                    if (filterNum == 1) self.screenState.filterBandwidthString = @"0.50k";
                    else if (filterNum == 2) self.screenState.filterBandwidthString = @"0.30k";
                    else if (filterNum == 3) self.screenState.filterBandwidthString = @"0.10k";
                    else self.screenState.filterBandwidthString = @"0.05k";
                } else if ([activeM isEqualToString:@"AM"]) {
                    if (filterNum == 1) self.screenState.filterBandwidthString = @"6.00k";
                    else if (filterNum == 2) self.screenState.filterBandwidthString = @"4.00k";
                    else self.screenState.filterBandwidthString = @"3.00k";
                } else {
                    if (filterNum == 1) self.screenState.filterBandwidthString = @"3.10k";
                    else if (filterNum == 2) self.screenState.filterBandwidthString = @"2.40k";
                    else if (filterNum == 3) self.screenState.filterBandwidthString = @"1.80k";
                    else self.screenState.filterBandwidthString = @"1.00k";
                }
            }

            self.screenState.preamp = preampOn;
            self.screenState.attenuator = attOn;
            self.screenState.noiseReduction = nrOn;
            self.screenState.noiseBlanker = nbOn;
            self.screenState.notchFilter = ntOn;
            self.screenState.clockString = timeStr;

            // Apply AF Gain from radio (only update if radio gave valid response)
            if (afGainValue >= 0) {
                self.screenState.afGainLevel = afGainValue;
                // Map 0–100 → knob arc: full CCW (-135°) to full CW (+135°), in radians
                // 0 = -3π/4, 100 = +3π/4
                CGFloat targetAngle = ((afGainValue / 100.0) * (1.5 * M_PI)) - (0.75 * M_PI);
                self.afGainAngle = targetAngle;
            }

            if (!self.demoModeActive) {
                self.screenState.spectrumAmplitudes = liveSpec;
            }

            [self renderAndUpdateDisplay];
            self->_isPolling = NO;
        });
    });
}

@end
