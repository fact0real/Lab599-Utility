#import "TX500PSKReporter.h"
//
//  TX500FT8StationController.m
//  Lab599 Utility
//
//  Complete FT8 Digital Workstation & Autonomous QSO Studio Controller
//

#import "TX500FT8StationController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const kColTime     = @"colTime";
static NSString * const kColSNR      = @"colSNR";
static NSString * const kColDT       = @"colDT";
static NSString * const kColFreq     = @"colFreq";
static NSString * const kColMsg      = @"colMsg";
static NSString * const kColCountry  = @"colCountry";
static NSString * const kColGrid     = @"colGrid";
static NSString * const kColDistance = @"colDistance";

// FT8 Band Presets
static struct {
    const char *band;
    uint64_t freqHz;
} kFT8Presets[] = {
    {"160m",  1840000},
    {"80m",   3573000},
    {"40m",   7074000},
    {"30m",  10136000},
    {"20m",  14074000},
    {"17m",  18100000},
    {"15m",  21074000},
    {"12m",  24915000},
    {"10m",  28074000},
    {"6m",   50313000},
    {NULL, 0}
};

// FT4 Band Presets (Standard Contest & Operational Dial Frequencies)
static struct {
    const char *band;
    uint64_t freqHz;
} kFT4Presets[] = {
    {"80m",   3575000},
    {"40m",   7047500},
    {"30m",  10140000},
    {"20m",  14080000},
    {"17m",  18104000},
    {"15m",  21140000},
    {"12m",  24919000},
    {"10m",  28180000},
    {"6m",   50318000},
    {NULL, 0}
};

@interface TX500FT8SlotProgressView : NSView
@property (nonatomic, assign) double slotSecond;
@property (nonatomic, assign) NSInteger parity;
@property (nonatomic, assign) BOOL isTransmitting;
@property (nonatomic, assign) BOOL isFT4;
@end

@implementation TX500FT8SlotProgressView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        self.wantsLayer = YES;
        self.layer.cornerRadius = 4.0;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;

    // Track Background - light track in Light Mode
    [[NSColor colorWithCalibratedWhite:0.92 alpha:1.0] setFill];
    NSRectFill(bounds);

    double slotTotal = self.isFT4 ? 7.5 : 15.0;
    double txTime = self.isFT4 ? 5.04 : 14.5;
    double decTime = self.isFT4 ? 5.8 : 13.5;

    // Progress bar fill
    double fraction = fmin(1.0, fmax(0.0, self.slotSecond / slotTotal));
    NSRect fillRect = NSMakeRect(0, 0, bounds.size.width * fraction, bounds.size.height);

    NSColor *barColor;
    if (self.isTransmitting) {
        barColor = [NSColor colorWithCalibratedRed:0.88 green:0.20 blue:0.20 alpha:0.90]; // Alert Red
    } else if (self.slotSecond >= decTime) {
        barColor = [NSColor colorWithCalibratedRed:0.92 green:0.65 blue:0.10 alpha:0.92]; // Amber Gold
    } else {
        barColor = [NSColor colorWithCalibratedRed:0.12 green:0.68 blue:0.38 alpha:0.88]; // Tactical Emerald RX
    }

    [barColor setFill];
    NSRectFill(fillRect);

    // Boundary marker at TX end and Decode start
    CGFloat txEnd = (txTime / slotTotal) * bounds.size.width;
    [[NSColor separatorColor] setStroke];
    [NSBezierPath strokeLineFromPoint:NSMakePoint(txEnd, 0) toPoint:NSMakePoint(txEnd, bounds.size.height)];

    CGFloat decStart = (decTime / slotTotal) * bounds.size.width;
    [[NSColor colorWithCalibratedRed:0.85 green:0.55 blue:0.08 alpha:0.85] setStroke];
    [NSBezierPath strokeLineFromPoint:NSMakePoint(decStart, 0) toPoint:NSMakePoint(decStart, bounds.size.height)];

    // Inner bezel border
    [[NSColor separatorColor] setStroke];
    NSBezierPath *borderPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:4.0 yRadius:4.0];
    borderPath.lineWidth = 1.0;
    [borderPath stroke];

    // Center text label with high contrast
    NSString *phaseStr = self.isTransmitting ? @"TX" : (self.slotSecond >= decTime ? @"DECODING" : @"RX");
    NSString *parityStr;
    if (self.isFT4) {
        parityStr = (self.parity == 0) ? @"EVEN (:00,:15,:30,:45)" : @"ODD (:07.5,:22.5,...)";
    } else {
        parityStr = (self.parity == 0) ? @"EVEN (:00/:30)" : @"ODD (:15/:45)";
    }
    NSString *text = [NSString stringWithFormat:@"%@ · %@ · %.1fs / %.1fs · %@",
                      self.isFT4 ? @"FT4" : @"FT8", phaseStr, self.slotSecond, slotTotal, parityStr];

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };

    NSSize sz = [text sizeWithAttributes:attrs];
    [text drawAtPoint:NSMakePoint((bounds.size.width - sz.width) / 2.0, (bounds.size.height - sz.height) / 2.0) withAttributes:attrs];
}

@end

@interface TX500AudioLevelMeterView : NSView
@property (nonatomic, assign) float levelDb;
@end

@implementation TX500AudioLevelMeterView

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        _levelDb = -60.0f;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 4.0;
        self.layer.masksToBounds = YES;
    }
    return self;
}

- (void)setLevelDb:(float)levelDb {
    _levelDb = fmaxf(-60.0f, fminf(0.0f, levelDb));
    [self setNeedsDisplay:YES];
}

- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    NSRect bounds = self.bounds;

    // Track Background
    [[NSColor colorWithCalibratedWhite:0.92 alpha:1.0] setFill];
    NSRectFill(bounds);

    // Fraction 0.0 (-60dB) to 1.0 (0dB)
    float fraction = (_levelDb + 60.0f) / 60.0f;
    fraction = fmaxf(0.0f, fminf(1.0f, fraction));

    NSRect barRect = NSMakeRect(0, 0, bounds.size.width * fraction, bounds.size.height);

    NSColor *barColor;
    if (_levelDb < -12.0f) {
        barColor = [NSColor colorWithCalibratedRed:0.15 green:0.72 blue:0.35 alpha:0.95]; // Green
    } else if (_levelDb < -3.0f) {
        barColor = [NSColor colorWithCalibratedRed:0.95 green:0.68 blue:0.10 alpha:0.95]; // Yellow / Amber
    } else {
        barColor = [NSColor colorWithCalibratedRed:0.88 green:0.20 blue:0.20 alpha:0.95]; // Red (Clipping)
    }

    [barColor setFill];
    NSRectFill(barRect);

    // Inner Border
    [[NSColor separatorColor] setStroke];
    NSBezierPath *borderPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:3.5 yRadius:3.5];
    borderPath.lineWidth = 1.0;
    [borderPath stroke];

    // Center dB Label
    NSString *text = (_levelDb <= -58.0f) ? @"IN: — dB" : [NSString stringWithFormat:@"IN: %+.0f dB", _levelDb];
    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor labelColor]
    };
    NSSize sz = [text sizeWithAttributes:attrs];
    [text drawAtPoint:NSMakePoint((bounds.size.width - sz.width) / 2.0, (bounds.size.height - sz.height) / 2.0) withAttributes:attrs];
}

@end

@interface TX500FT8StationController ()

@property (nonatomic, strong, readwrite) NSView *view;
@property (nonatomic, strong, readwrite) TX500FT8AudioEngine *audioEngine;
@property (nonatomic, strong, readwrite) TX500FT8AutoEngine *autoEngine;
@property (nonatomic, strong, readwrite) TX500FT8WaterfallView *waterfallView;

// UI Components - Top Ribbon
@property (nonatomic, strong) NSButton *startStopButton;
@property (nonatomic, strong) NSSegmentedControl *modeSegment;
@property (nonatomic, strong) NSPopUpButton *bandPopup;
@property (nonatomic, strong) NSTextField *dialFreqLabel;
@property (nonatomic, strong) NSPopUpButton *audioInPopup;
@property (nonatomic, strong) TX500AudioLevelMeterView *audioLevelMeter;
@property (nonatomic, strong) NSPopUpButton *audioOutPopup;
@property (nonatomic, strong) NSButton *simCheckbox;
@property (nonatomic, strong) NSTextField *rxFreqField;
@property (nonatomic, strong) NSTextField *txFreqField;
@property (nonatomic, strong) NSButton *lockFreqsButton;
@property (nonatomic, strong) NSButton *armTxButton;
@property (nonatomic, strong) NSButton *fakeItCheckbox;
@property (nonatomic, strong) NSButton *tuneButton;
@property (nonatomic, strong) TX500FT8SlotProgressView *slotProgressView;
@property (nonatomic, strong) NSTextField *panUtcBadge;

// Waterfall DSP & Palette Controls
@property (nonatomic, strong) NSPopUpButton *palettePopup;
@property (nonatomic, strong) NSSlider *gainSlider;
@property (nonatomic, strong) NSSlider *contrastSlider;
@property (nonatomic, strong) NSButton *callsignTagsCheckbox;
@property (nonatomic, strong) NSButton *collapseWaterfallButton;
@property (nonatomic, assign) BOOL isWaterfallCollapsed;
@property (nonatomic, strong) NSLayoutConstraint *panadapterExpandedBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *panadapterCollapsedBottomConstraint;
@property (nonatomic, strong) NSTextField *liveUtcLabel;

// UI Components - Autonomous Algorithms Banner
@property (nonatomic, strong) NSButton *autoCQButton;
@property (nonatomic, strong) NSStepper *autoCQStepper;
@property (nonatomic, strong) NSTextField *autoCQCountLabel;
@property (nonatomic, strong) NSTextField *autoCQStatusLabel;
@property (nonatomic, strong) NSButton *autoHunterButton;
@property (nonatomic, strong) NSPopUpButton *hunterCriteriaPopup;
@property (nonatomic, strong) NSSlider *hunterSNRSlider;
@property (nonatomic, strong) NSTextField *hunterSNRLabel;
@property (nonatomic, strong) NSTextField *autoHunterStatusLabel;

// UI Components - Main Dual Workstation (Band Activity & Rx Frequency)
@property (nonatomic, strong) NSSegmentedControl *tableFilterSegment;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSButton *pskReporterCheckbox;
@property (nonatomic, assign) BOOL pskReporterEnabled;
@property (nonatomic, strong) NSTableView *activityTableView; // Alias to bandActivityTableView
@property (nonatomic, strong) NSTableView *bandActivityTableView;
@property (nonatomic, strong) NSTableView *rxFreqTableView;
@property (nonatomic, strong) NSMutableArray<TX500FT8Message *> *allDecodes;
@property (nonatomic, strong) NSMutableArray<TX500FT8Message *> *filteredDecodes;
@property (nonatomic, strong) NSMutableArray<TX500FT8Message *> *rxFreqDecodes;

// Station Tracking History
@property (nonatomic, strong) NSMutableSet<NSString *> *workedCallsigns;
@property (nonatomic, strong) NSMutableSet<NSString *> *workedGrids;
@property (nonatomic, strong) NSMutableSet<NSString *> *workedCountries;
@property (nonatomic, strong) id keyEventMonitor;

// UI Components - Transmit Matrix & QSO Copilot
@property (nonatomic, strong) NSTextField *myCallField;
@property (nonatomic, strong) NSTextField *myGridField;
@property (nonatomic, strong) NSTextField *dxCallField;
@property (nonatomic, strong) NSTextField *dxGridField;
@property (nonatomic, strong) NSTextField *dxInfoLabel;
@property (nonatomic, strong) NSMutableArray<NSButton *> *txMessageButtons;
@property (nonatomic, strong) NSMutableArray<NSTextField *> *txMessageLabels;
@property (nonatomic, strong) NSButton *nextStepButton;
@property (nonatomic, strong) NSButton *abortButton;
@property (nonatomic, strong) NSTextView *qsoConsoleTextView;

// UI Components - Bottom Session Log & ADIF Export
@property (nonatomic, strong) NSTextField *sessionLogCountLabel;
@property (nonatomic, strong) NSButton *exportADIFButton;
@property (nonatomic, strong) NSButton *openLogsButton;
@property (nonatomic, strong) NSButton *clearLogButton;

// TX Slot Parity Selector & SWR Indicator
@property (nonatomic, strong) NSSegmentedControl *txParitySegment;
@property (nonatomic, strong) NSTextField *swrLabel;
@property (nonatomic, strong) NSTextField *snrMinField;
@property (nonatomic, strong) NSTextField *snrMaxField;
@property (nonatomic, strong) NSPopUpButton *alertCountryPopup;
@property (nonatomic, strong) NSButton *alertEnabledCheckbox;

// Flexible Splitters & View Controls
@property (nonatomic, strong) NSBox *panadapterBox;
@property (nonatomic, strong) NSBox *algoBox;
@property (nonatomic, strong) NSBox *rightBox;
@property (nonatomic, strong) NSSplitView *workstationSplitView;
@property (nonatomic, strong) NSSplitView *tablesSplitView;
@property (nonatomic, strong) NSButton *wideTablesBtn;
@property (nonatomic, strong) NSButton *fullHeightBtn;
@property (nonatomic, assign) BOOL isWideTables;
@property (nonatomic, assign) BOOL isFullHeight;
@property (nonatomic, strong) NSLayoutConstraint *workstationTopToAlgoConstraint;
@property (nonatomic, strong) NSLayoutConstraint *workstationTopToRibbonConstraint;
@property (nonatomic, strong) NSLayoutConstraint *panadapterTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *algoTopConstraint;

// UI Components - Live Cycle Status Banner
@property (nonatomic, strong) NSBox *cycleBannerBox;
@property (nonatomic, strong) NSTextField *cycleBadge;
@property (nonatomic, strong) NSTextField *cycleDetailLabel;
@property (nonatomic, strong) NSTextField *cycleClockLabel;
@property (nonatomic, assign) NSUInteger lastDecodesCount;

@end

@interface FT8TableCellView : NSTableCellView
@end

@implementation FT8TableCellView
@end

@interface FT8TableRowView : NSTableRowView
@property (nonatomic, assign) NSInteger slotParity;
@property (nonatomic, assign) BOOL isDirectedToMe;
@property (nonatomic, assign) BOOL isMyTransmission;
@property (nonatomic, assign) BOOL isAlertMatch;
@property (nonatomic, assign) BOOL isCycleSeparator;
@end

@implementation FT8TableRowView
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    if (self.isCycleSeparator) {
        // Cycle-divider row: thin accent bar to signal a new decode cycle
        NSColor *divColor = [NSColor colorWithCalibratedRed:0.08 green:0.38 blue:0.72 alpha:0.12];
        [divColor setFill];
        NSRectFill(dirtyRect);
        // Bottom separator line for clarity
        [[NSColor colorWithCalibratedRed:0.08 green:0.38 blue:0.72 alpha:0.40] setStroke];
        [NSBezierPath strokeLineFromPoint:NSMakePoint(NSMinX(dirtyRect), NSMaxY(self.bounds) - 0.5)
                                  toPoint:NSMakePoint(NSMaxX(dirtyRect), NSMaxY(self.bounds) - 0.5)];
        return;
    }
    if (self.isSelected) {
        [[NSColor selectedContentBackgroundColor] setFill];
        NSRectFill(dirtyRect);
        return;
    }
    if (self.isAlertMatch) {
        // High visibility alert tint (soft golden / amber / light peach alert highlight)
        NSColor *alertTint = [NSColor colorWithCalibratedRed:1.0 green:0.86 blue:0.82 alpha:1.0];
        [alertTint setFill];
        NSRectFill(dirtyRect);
        return;
    }
    if (self.isDirectedToMe) {
        NSColor *toMeTint = [NSColor colorWithCalibratedRed:1.0 green:0.91 blue:0.84 alpha:1.0];
        [toMeTint setFill];
        NSRectFill(dirtyRect);
        return;
    }
    if (self.isMyTransmission) {
        NSColor *myTxTint = [NSColor colorWithCalibratedRed:1.0 green:0.96 blue:0.82 alpha:1.0];
        [myTxTint setFill];
        NSRectFill(dirtyRect);
        return;
    }
    // AppKit supplies appearance-aware colors for both Aqua and Dark Aqua.
    NSArray<NSColor *> *colors = [NSColor alternatingContentBackgroundColors];
    NSColor *background = colors.count > 0 ? colors[(NSUInteger)labs(self.slotParity) % colors.count]
                                           : [NSColor controlBackgroundColor];
    [background setFill];
    NSRectFill(dirtyRect);
}
@end


@implementation TX500FT8StationController

- (instancetype)init {
    self = [super init];
    if (self) {
        _protocol = TX500_FT8_PROTOCOL_FT8;
        _audioEngine = [[TX500FT8AudioEngine alloc] init];
        _audioEngine.protocol = _protocol;
        _autoEngine = [[TX500FT8AutoEngine alloc] init];
        _autoEngine.audioEngine = _audioEngine;

        _allDecodes = [NSMutableArray array];
        _filteredDecodes = [NSMutableArray array];
        _rxFreqDecodes = [NSMutableArray array];
        _txMessageButtons = [NSMutableArray array];
        _txMessageLabels = [NSMutableArray array];

        [self loadWorkedStationHistory];
        _pskReporterEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"TX500_FT8_PSKReporterEnabled"];

        [self setupBindings];
        [self buildUserInterface];
        [self reloadStationPreferences];
        [self setupKeyboardShortcuts];
    }
    return self;
}

- (void)dealloc {
    if (_keyEventMonitor) {
        [NSEvent removeMonitor:_keyEventMonitor];
        _keyEventMonitor = nil;
    }
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopStation];
}

#pragma mark - Bindings & Callbacks

- (void)setupBindings {
    __weak typeof(self) weakSelf = self;

    // Audio Level Meter (AD-508 / CoreAudio Input)
    self.audioEngine.onAudioLevelUpdated = ^(float levelDb) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf.audioLevelMeter setLevelDb:levelDb];
        });
    };

    // Audio Engine -> Waterfall & Decoder
    self.audioEngine.onSpectrumUpdated = ^(const float *magnitudes, NSInteger count) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.waterfallView appendSpectrumRow:magnitudes count:count];
    };

    // Slot Tick -> Progress Bar & Live UTC Clock
    self.audioEngine.onSlotTick = ^(double slotSec, NSInteger parity, double progress) {
        (void)progress;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.slotProgressView.slotSecond = slotSec;
        strongSelf.slotProgressView.parity = parity;
        strongSelf.slotProgressView.isFT4 = (strongSelf.protocol == TX500_FT8_PROTOCOL_FT4);
        strongSelf.slotProgressView.isTransmitting = strongSelf.audioEngine.isTransmitting;
        [strongSelf.slotProgressView setNeedsDisplay:YES];

        // Live UTC Clock Display
        static NSDateFormatter *s_utcClockFmt = nil;
        static dispatch_once_t s_clkOnce;
        dispatch_once(&s_clkOnce, ^{
            s_utcClockFmt = [[NSDateFormatter alloc] init];
            s_utcClockFmt.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
            s_utcClockFmt.dateFormat = @"HH:mm:ss";
        });
        strongSelf.liveUtcLabel.stringValue = [NSString stringWithFormat:@"UTC %@", [s_utcClockFmt stringFromDate:[NSDate date]]];

        // Update Live Cycle Status Banner
        [strongSelf updateLiveCycleStatusBannerWithSlotSec:slotSec parity:parity];
    };

    // Slot Transition
    self.audioEngine.onSlotTransition = ^(NSInteger parity, NSDate *utcStart) {
        (void)utcStart;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [strongSelf updateLiveCycleStatusBannerWithSlotSec:0.0 parity:parity];
        });
    };

    // Transmit State Changed
    self.audioEngine.onTransmitStateChanged = ^(BOOL transmitting, NSString *txText) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.waterfallView.isTransmitting = transmitting;
        [strongSelf.waterfallView setNeedsDisplay:YES];

        if (transmitting) {
            strongSelf.armTxButton.state = NSControlStateValueOn;
            [strongSelf appendToQSOConsole:[NSString stringWithFormat:@"[TX Slot] Transmitting: %@", txText]];

            if (txText.length > 0) {
                NSString *myCall = strongSelf.audioEngine.myCallsign ?: @"EP2AES";
                NSString *myGrid = strongSelf.audioEngine.myGrid ?: @"KM35";
                TX500FT8Message *txMsg = [TX500FT8Message messageWithRawText:txText
                                                                     freqHz:strongSelf.audioEngine.txAudioFrequencyHz
                                                                      snrDb:0.0f
                                                                         dt:0.0f
                                                                   slotDate:[NSDate date]
                                                                 slotParity:strongSelf.audioEngine.currentSlotParity
                                                                     myCall:myCall
                                                                     myGrid:myGrid];
                txMsg.isMyTransmission = YES;
                txMsg.snrReport = @"TX";

                // Prepend to tables so operator has complete history of all transmitted frames
                [strongSelf.allDecodes insertObject:txMsg atIndex:0];
                if (strongSelf.allDecodes.count > 400) {
                    [strongSelf.allDecodes removeLastObject];
                }
                [strongSelf.rxFreqDecodes insertObject:txMsg atIndex:0];
                if (strongSelf.rxFreqDecodes.count > 200) {
                    [strongSelf.rxFreqDecodes removeLastObject];
                }
                [strongSelf applyTableFilters];
                [strongSelf.rxFreqTableView reloadData];
            }
        } else {
            if (!strongSelf.audioEngine.isTransmitArmed) {
                strongSelf.armTxButton.state = NSControlStateValueOff;
            }
        }
        [strongSelf updateLiveCycleStatusBannerWithSlotSec:strongSelf.audioEngine.currentSlotSecond parity:strongSelf.audioEngine.currentSlotParity];
    };

    // Decoded Messages from Slot
    self.audioEngine.onDecodedMessages = ^(NSArray<TX500FT8Message *> *messages, NSInteger parity) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Ingest into Auto-Engine
        [strongSelf.autoEngine processDecodedSlot:messages parity:parity];

        // Populate active station tags for waterfall HUD
        NSMutableArray<NSDictionary *> *tags = [NSMutableArray array];
        for (TX500FT8Message *m in messages) {
            if (m.callerCall.length > 0 && m.freqHz > 100.0f) {
                [tags addObject:@{
                    @"freq": @(m.freqHz),
                    @"call": m.callerCall,
                    @"snr": @((int)roundf(m.snrDb)),
                    @"isCQ": @(m.isCQ)
                }];
            }
        }
        strongSelf.waterfallView.activeStationTags = tags;
        [strongSelf.waterfallView setNeedsDisplay:YES];

        // Add to Table — insert a cycle-divider sentinel first, then all decoded messages
        // Build a lightweight separator row to visually break cycles in the table
        {
            static NSDateFormatter *s_localSepFmt = nil;
            static dispatch_once_t s_sepOnce;
            dispatch_once(&s_sepOnce, ^{
                s_localSepFmt = [[NSDateFormatter alloc] init];
                s_localSepFmt.dateFormat = @"HH:mm:ss";
                // Use device local timezone for separator label
                s_localSepFmt.timeZone = [NSTimeZone localTimeZone];
            });
            NSString *isFT4 = (strongSelf.protocol == TX500_FT8_PROTOCOL_FT4) ? @"FT4" : @"FT8";
            NSString *parLabel = (parity == 0) ? @"EVEN" : @"ODD";
            NSString *sepText = [NSString stringWithFormat:@"── %@ · %@ cycle · %@ ──",
                                 isFT4, parLabel,
                                 [s_localSepFmt stringFromDate:[NSDate date]]];
            TX500FT8Message *sep = [[TX500FT8Message alloc] init];
            sep.rawText = sepText;
            sep.timestamp = [NSDate date];
            sep.slotParity = parity;
            sep.isCycleSeparator = YES;
            [strongSelf.allDecodes insertObject:sep atIndex:0];
        }

        [strongSelf.allDecodes insertObjects:messages atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(1, messages.count)]];
        if (strongSelf.allDecodes.count > 400) {
            [strongSelf.allDecodes removeObjectsInRange:NSMakeRange(400, strongSelf.allDecodes.count - 400)];
        }
        [strongSelf applyTableFilters];

        strongSelf.lastDecodesCount = messages.count;
        [strongSelf updateLiveCycleStatusBannerWithSlotSec:strongSelf.audioEngine.currentSlotSecond parity:parity];

        // Trigger Country Alert for newly arrived cycle messages ONLY
        [strongSelf checkAndTriggerAlertsForNewMessages:messages];

        // Report spots to PSKReporter if enabled
        if (strongSelf.pskReporterEnabled) {
            [strongSelf sendPSKReporterSpots:messages];
        }
    };

    // Auto-Engine Callbacks
    self.autoEngine.onDXStationEngaged = ^(NSString *dxCall, NSString *dxGrid, NSString *report, TX500FT8QSOPhase phase) {
        (void)report;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.dxCallField.stringValue = dxCall ?: @"";
            strongSelf.dxGridField.stringValue = dxGrid ?: @"";
            [strongSelf dxCallEdited:nil];
            [strongSelf updateTransmitMatrixLabels];
            strongSelf.armTxButton.title = @"ARMED (TX)";
            strongSelf.armTxButton.bezelColor = [NSColor colorWithCalibratedRed:0.8 green:0.2 blue:0.2 alpha:1.0];
            if (strongSelf.audioEngine.lockTxRxFrequencies) {
                strongSelf.txFreqField.stringValue = strongSelf.rxFreqField.stringValue;
                strongSelf.waterfallView.txFrequencyHz = strongSelf.audioEngine.txAudioFrequencyHz;
                [strongSelf.waterfallView setNeedsDisplay:YES];
            }
            NSInteger step = (NSInteger)phase;
            if (step >= 1 && step <= (NSInteger)strongSelf.txMessageButtons.count) {
                for (NSUInteger i = 0; i < strongSelf.txMessageButtons.count; i++) {
                    strongSelf.txMessageButtons[i].state = (i == (NSUInteger)(step - 1)) ? NSControlStateValueOn : NSControlStateValueOff;
                }
            }
        });
    };

    self.autoEngine.onQSOStateChanged = ^(TX500FT8QSOPhase phase, NSString *statusText) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (strongSelf.autoEngine.activeDXCall.length > 0 &&
                ![strongSelf.dxCallField.stringValue isEqualToString:strongSelf.autoEngine.activeDXCall]) {
                strongSelf.dxCallField.stringValue = strongSelf.autoEngine.activeDXCall;
                strongSelf.dxGridField.stringValue = strongSelf.autoEngine.activeDXGrid ?: @"";
                [strongSelf dxCallEdited:nil];
            }
            [strongSelf updateTransmitMatrixLabels];
            if (strongSelf.audioEngine.isTransmitArmed) {
                strongSelf.armTxButton.title = @"ARMED (TX)";
                strongSelf.armTxButton.bezelColor = [NSColor colorWithCalibratedRed:0.8 green:0.2 blue:0.2 alpha:1.0];
            } else {
                strongSelf.armTxButton.title = @"ENABLE TX";
                strongSelf.armTxButton.bezelColor = nil;
            }
            NSInteger step = (NSInteger)phase;
            if (step >= 1 && step <= (NSInteger)strongSelf.txMessageButtons.count) {
                for (NSUInteger i = 0; i < strongSelf.txMessageButtons.count; i++) {
                    strongSelf.txMessageButtons[i].state = (i == (NSUInteger)(step - 1)) ? NSControlStateValueOn : NSControlStateValueOff;
                }
            }
            [strongSelf appendToQSOConsole:[NSString stringWithFormat:@"~ State: %@", statusText]];
        });
    };

    self.autoEngine.onAlgorithmStatusUpdated = ^(NSString *cqStatus, NSString *hunterStatus) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.autoCQStatusLabel.stringValue = cqStatus;
        strongSelf.autoHunterStatusLabel.stringValue = hunterStatus;
    };

    self.autoEngine.onQSOLogged = ^(TX500FT8LoggedQSO *qso) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf appendToQSOConsole:[NSString stringWithFormat:@"★ QSO WITH %@ LOGGED! (Grid: %@, Band: %@)", qso.callsign, qso.grid ?: @"-", qso.band]];
        strongSelf.sessionLogCountLabel.stringValue = [NSString stringWithFormat:@"Session QSOs: %lu", (unsigned long)strongSelf.autoEngine.sessionLog.count];

        // Prompt user with WSJT-X style QSO Confirmation Dialog
        [strongSelf promptAutoLogQSO:qso];
    };

    // Waterfall Click-to-Tune
    self.waterfallView.onFrequencySelected = ^(float freqHz, BOOL isTx) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (isTx) {
            strongSelf.audioEngine.txAudioFrequencyHz = freqHz;
            strongSelf.txFreqField.stringValue = [NSString stringWithFormat:@"%.0f", freqHz];
        } else {
            strongSelf.audioEngine.rxAudioFrequencyHz = freqHz;
            strongSelf.rxFreqField.stringValue = [NSString stringWithFormat:@"%.0f", freqHz];
            if (strongSelf.audioEngine.lockTxRxFrequencies) {
                strongSelf.audioEngine.txAudioFrequencyHz = freqHz;
                strongSelf.txFreqField.stringValue = [NSString stringWithFormat:@"%.0f", freqHz];
            }
        }
    };

    // SWR Monitoring during TX
    self.audioEngine.onSWRUpdated = ^(double swr) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        NSString *swrStr;
        NSColor *swrColor;
        if (swr <= 0.0) {
            swrStr = @"SWR: —";
            swrColor = [NSColor secondaryLabelColor];
        } else if (swr < 1.5) {
            swrStr = [NSString stringWithFormat:@"SWR: %.1f:1 ✓", swr];
            swrColor = [NSColor colorWithCalibratedRed:0.2 green:0.8 blue:0.3 alpha:1.0];
        } else if (swr < 2.5) {
            swrStr = [NSString stringWithFormat:@"SWR: %.1f:1 ⚡", swr];
            swrColor = [NSColor colorWithCalibratedRed:1.0 green:0.75 blue:0.1 alpha:1.0];
        } else {
            swrStr = [NSString stringWithFormat:@"SWR: %.1f:1 ⚠", swr];
            swrColor = [NSColor colorWithCalibratedRed:1.0 green:0.2 blue:0.2 alpha:1.0];
        }
        strongSelf.swrLabel.stringValue = swrStr;
        strongSelf.swrLabel.textColor = swrColor;

        // SWR protection: abort TX if over threshold
        double maxSWR = strongSelf.audioEngine.maxSWRThreshold;
        if (maxSWR > 0.0 && swr > maxSWR && strongSelf.audioEngine.isTransmitting) {
            [strongSelf.audioEngine disarmTransmit];
            strongSelf.armTxButton.title = @"ENABLE TX";
            strongSelf.armTxButton.bezelColor = nil;
            [strongSelf appendToQSOConsole:[NSString stringWithFormat:@"⚠ TX ABORTED: SWR %.1f:1 exceeded threshold %.1f:1", swr, maxSWR]];
        }
    };
    self.audioEngine.onSWRMeterUpdated = ^(NSInteger rawDots, BOOL valid) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!valid) {
            strongSelf.swrLabel.stringValue = @"SWR: —";
            strongSelf.swrLabel.textColor = [NSColor secondaryLabelColor];
            return;
        }
        double swr = [TX500FT8AudioEngine swrRatioFromMeterDots:rawDots];
        NSString *swrStr;
        NSColor *swrColor;
        if (swr < 1.5) {
            swrStr = [NSString stringWithFormat:@"SWR: %.1f:1 ✓", swr];
            swrColor = [NSColor colorWithCalibratedRed:0.2 green:0.8 blue:0.3 alpha:1.0];
        } else if (swr < 2.5) {
            swrStr = [NSString stringWithFormat:@"SWR: %.1f:1 ⚡", swr];
            swrColor = [NSColor colorWithCalibratedRed:1.0 green:0.75 blue:0.1 alpha:1.0];
        } else {
            swrStr = [NSString stringWithFormat:@"SWR: %.1f:1 ⚠", swr];
            swrColor = [NSColor colorWithCalibratedRed:1.0 green:0.2 blue:0.2 alpha:1.0];
        }
        strongSelf.swrLabel.stringValue = swrStr;
        strongSelf.swrLabel.textColor = swrColor;
    };

    // Forward Audio Engine Logging
    self.audioEngine.logHandler = ^(NSString *line) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.logHandler) {
            strongSelf.logHandler(line);
        }
    };
    self.autoEngine.logHandler = ^(NSString *line) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            [strongSelf appendToQSOConsole:line];
            if (strongSelf.logHandler) {
                strongSelf.logHandler(line);
            }
        }
    };

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reloadStationPreferences)
                                                 name:@"TX500StationSettingsChangedNotification"
                                               object:nil];
}

#pragma mark - Lifecycle & Protocol

- (void)selectProtocol:(tx500_ft8_protocol_t)proto {
    _protocol = proto;
    self.audioEngine.protocol = proto;
    self.slotProgressView.isFT4 = (proto == TX500_FT8_PROTOCOL_FT4);
    [self.slotProgressView setNeedsDisplay:YES];

    if (self.modeSegment && self.modeSegment.selectedSegment != (NSInteger)proto) {
        self.modeSegment.selectedSegment = (NSInteger)proto;
    }

    NSString *mName = (proto == TX500_FT8_PROTOCOL_FT4) ? @"FT4" : @"FT8";

    // Update Panadapter UTC slot badge
    if (self.panUtcBadge) {
        self.panUtcBadge.stringValue = (proto == TX500_FT8_PROTOCOL_FT4) ?
            @"7.5s UTC FT4 SLOT · WATERFALL" : @"15.0s UTC FT8 SLOT · WATERFALL";
    }

    // Update start/stop button label
    if (self.audioEngine.isMonitoring) {
        self.startStopButton.title = [NSString stringWithFormat:@"Stop %@", mName];
    } else {
        self.startStopButton.title = [NSString stringWithFormat:@"Start %@", mName];
    }

    // Refresh Band presets popup with appropriate dial frequencies
    [self refreshBandPopupForCurrentProtocol];

    // Select the current band preset frequency
    NSString *selectedBand = self.bandPopup.titleOfSelectedItem ?: @"20m";
    uint64_t newDialHz = [self defaultFrequencyForBand:selectedBand protocol:proto];
    if (newDialHz > 0) {
        [self updateFrequencyHz:newDialHz mode:@"DIG"];
        if (self.serialCommandSender) {
            self.serialCommandSender([NSString stringWithFormat:@"FA%011llu;", (unsigned long long)newDialHz]);
            self.serialCommandSender(@"MD6;");
        }
    }

    [self appendToQSOConsole:[NSString stringWithFormat:@"[Protocol Switched] Active mode: %@ (%.1fs slot).",
                              mName, self.audioEngine.currentSlotPeriod]];
}

- (void)modeSegmentChanged:(NSSegmentedControl *)sender {
    tx500_ft8_protocol_t newProto = (sender.selectedSegment == 1) ? TX500_FT8_PROTOCOL_FT4 : TX500_FT8_PROTOCOL_FT8;
    [self selectProtocol:newProto];
}

- (uint64_t)defaultFrequencyForBand:(NSString *)band protocol:(tx500_ft8_protocol_t)proto {
    if (proto == TX500_FT8_PROTOCOL_FT4) {
        for (int i = 0; kFT4Presets[i].band != NULL; i++) {
            if ([band isEqualToString:[NSString stringWithUTF8String:kFT4Presets[i].band]]) {
                return kFT4Presets[i].freqHz;
            }
        }
        return 14080000;
    } else {
        for (int i = 0; kFT8Presets[i].band != NULL; i++) {
            if ([band isEqualToString:[NSString stringWithUTF8String:kFT8Presets[i].band]]) {
                return kFT8Presets[i].freqHz;
            }
        }
        return 14074000;
    }
}

- (void)refreshBandPopupForCurrentProtocol {
    NSString *currentSelection = self.bandPopup.titleOfSelectedItem;
    [self.bandPopup removeAllItems];
    if (self.protocol == TX500_FT8_PROTOCOL_FT4) {
        for (int i = 0; kFT4Presets[i].band != NULL; i++) {
            [self.bandPopup addItemWithTitle:[NSString stringWithUTF8String:kFT4Presets[i].band]];
        }
    } else {
        for (int i = 0; kFT8Presets[i].band != NULL; i++) {
            [self.bandPopup addItemWithTitle:[NSString stringWithUTF8String:kFT8Presets[i].band]];
        }
    }
    if (currentSelection && [self.bandPopup itemWithTitle:currentSelection]) {
        [self.bandPopup selectItemWithTitle:currentSelection];
    } else {
        [self.bandPopup selectItemWithTitle:@"20m"];
    }
}

- (void)setSerialCommandSender:(BOOL (^)(NSString *))serialCommandSender {
    _serialCommandSender = [serialCommandSender copy];
    self.audioEngine.serialCommandSender = _serialCommandSender;
}

- (void)setPttControlHandler:(BOOL (^)(BOOL))pttControlHandler {
    _pttControlHandler = [pttControlHandler copy];
    self.audioEngine.pttControlHandler = _pttControlHandler;
}

- (void)setCatQueryHandler:(NSString * (^)(NSString *, NSTimeInterval))catQueryHandler {
    _catQueryHandler = [catQueryHandler copy];
    self.audioEngine.catQueryHandler = _catQueryHandler;
}

- (void)startStation {
    // Connect serial port command sender & PTT handler
    self.audioEngine.serialCommandSender = self.serialCommandSender;
    self.audioEngine.pttControlHandler = self.pttControlHandler;
    self.audioEngine.catQueryHandler = self.catQueryHandler;

    // In live radio mode, place transceiver in DIG mode once at station startup
    if (!self.audioEngine.isSimulationMode && self.serialCommandSender) {
        self.serialCommandSender(@"MD6;");
    }

    // Load SWR protection threshold from preferences
    double swrThreshold = [[NSUserDefaults standardUserDefaults] doubleForKey:@"TX500_SWRThreshold"];
    self.audioEngine.maxSWRThreshold = (swrThreshold > 0.0) ? swrThreshold : 0.0;

    NSError *err = nil;
    if ([self.audioEngine startMonitoring:&err]) {
        NSString *mName = (self.protocol == TX500_FT8_PROTOCOL_FT4) ? @"FT4" : @"FT8";
        self.startStopButton.title = [NSString stringWithFormat:@"Stop %@", mName];
        self.startStopButton.bezelColor = [NSColor colorWithCalibratedRed:0.8 green:0.2 blue:0.2 alpha:1.0];
        [self appendToQSOConsole:[NSString stringWithFormat:@"[%@ Engine] Monitoring active. %.1f-second slot synchronized.",
                                  mName, self.audioEngine.currentSlotPeriod]];
        if (self.stationStateChangedHandler) self.stationStateChangedHandler(YES);
    }
}

- (void)stopStation {
    [self.autoEngine stopAutoCQ];
    [self.autoEngine stopAutoHunter];
    [self.audioEngine stopMonitoring];
    NSString *mName = (self.protocol == TX500_FT8_PROTOCOL_FT4) ? @"FT4" : @"FT8";
    self.startStopButton.title = [NSString stringWithFormat:@"Start %@", mName];
    self.startStopButton.bezelColor = nil;
    [self appendToQSOConsole:[NSString stringWithFormat:@"[%@ Engine] Monitoring stopped.", mName]];
    if (self.stationStateChangedHandler) self.stationStateChangedHandler(NO);
}

- (void)updateFrequencyHz:(uint64_t)freqHz mode:(NSString *)mode {
    self.audioEngine.dialFrequencyHz = freqHz;
    double mhz = (double)freqHz / 1000000.0;
    self.dialFreqLabel.stringValue = [NSString stringWithFormat:@"%.6f MHz %@", mhz, mode ?: @"DIG"];
}

#pragma mark - User Interface Construction

- (void)buildUserInterface {
    self.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 1000, 626)];
    self.view.translatesAutoresizingMaskIntoConstraints = NO;

    // --- 1. Top Control Ribbon Box (Native Adaptive Theme) ---
    NSBox *topRibbon = [[NSBox alloc] initWithFrame:NSZeroRect];
    topRibbon.translatesAutoresizingMaskIntoConstraints = NO;
    topRibbon.boxType = NSBoxCustom;
    topRibbon.fillColor = [NSColor controlBackgroundColor];
    topRibbon.borderColor = [NSColor separatorColor];
    topRibbon.borderWidth = 1.0;
    topRibbon.cornerRadius = 8.0;
    [self.view addSubview:topRibbon];

    self.startStopButton = [NSButton buttonWithTitle:@"Start FT8" target:self action:@selector(toggleMonitoring:)];
    self.startStopButton.bezelStyle = NSBezelStyleRounded;
    [self.startStopButton.widthAnchor constraintEqualToConstant:82].active = YES;

    self.modeSegment = [NSSegmentedControl segmentedControlWithLabels:@[@"FT8", @"FT4"]
                                                         trackingMode:NSSegmentSwitchTrackingSelectOne
                                                               target:self
                                                               action:@selector(modeSegmentChanged:)];
    self.modeSegment.selectedSegment = (self.protocol == TX500_FT8_PROTOCOL_FT4) ? 1 : 0;
    [self.modeSegment.widthAnchor constraintEqualToConstant:76].active = YES;

    self.bandPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self refreshBandPopupForCurrentProtocol];
    self.bandPopup.target = self;
    self.bandPopup.action = @selector(bandSelected:);
    [self.bandPopup.widthAnchor constraintEqualToConstant:72].active = YES;

    self.dialFreqLabel = [NSTextField labelWithString:@"14.074.000 MHz DIG"];
    self.dialFreqLabel.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightBold];
    self.dialFreqLabel.textColor = [NSColor colorWithCalibratedRed:0.80 green:0.48 blue:0.0 alpha:1.0];

    self.audioInPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    __weak typeof(self) weakSelf = self;
    self.audioEngine.onAudioDevicesChanged = ^{
        [weakSelf updateAudioDeviceMenus];
    };
    [self updateAudioDeviceMenus];
    self.audioInPopup.target = self;
    self.audioInPopup.action = @selector(audioDeviceSelected:);
    [self.audioInPopup.widthAnchor constraintGreaterThanOrEqualToConstant:120].active = YES;

    self.simCheckbox = [NSButton checkboxWithTitle:@"Simulation Mode (No RF TX)" target:self action:@selector(toggleSimulation:)];
    self.simCheckbox.toolTip = @"Inhibits physical RF transmission on the connected radio for safe offline bench testing.";
    self.simCheckbox.state = self.audioEngine.isSimulationMode ? NSControlStateValueOn : NSControlStateValueOff;

    NSTextField *rxLbl = [NSTextField labelWithString:@"RX:"];
    self.rxFreqField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.rxFreqField.stringValue = @"1200";
    self.rxFreqField.target = self;
    self.rxFreqField.action = @selector(frequenciesEdited:);
    [self.rxFreqField.widthAnchor constraintEqualToConstant:46].active = YES;

    NSTextField *txLbl = [NSTextField labelWithString:@"TX:"];
    self.txFreqField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.txFreqField.stringValue = @"1500";
    self.txFreqField.target = self;
    self.txFreqField.action = @selector(frequenciesEdited:);
    [self.txFreqField.widthAnchor constraintEqualToConstant:46].active = YES;

    self.lockFreqsButton = [NSButton buttonWithTitle:@"Lock" target:self action:@selector(toggleLockFreqs:)];
    self.lockFreqsButton.bezelStyle = NSBezelStyleInline;
    [self.lockFreqsButton.widthAnchor constraintEqualToConstant:46].active = YES;

    self.tuneButton = [NSButton buttonWithTitle:@"Tune" target:self action:@selector(toggleTune:)];
    self.tuneButton.bezelStyle = NSBezelStyleInline;
    [self.tuneButton.widthAnchor constraintEqualToConstant:46].active = YES;

    self.armTxButton = [NSButton buttonWithTitle:@"ENABLE TX" target:self action:@selector(toggleArmTx:)];
    self.armTxButton.bezelStyle = NSBezelStyleRounded;
    [self.armTxButton.widthAnchor constraintEqualToConstant:86].active = YES;

    // TX Slot Parity: Even / Auto / Odd
    self.txParitySegment = [NSSegmentedControl segmentedControlWithLabels:@[@"Even", @"Auto", @"Odd"]
                                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                    target:self
                                                                    action:@selector(txParityChanged:)];
    self.txParitySegment.selectedSegment = 1; // Default Auto
    [self.txParitySegment.widthAnchor constraintEqualToConstant:126].active = YES;


    // SWR live indicator
    self.swrLabel = [NSTextField labelWithString:@"SWR: —"];
    self.swrLabel.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightBold];
    self.swrLabel.textColor = [NSColor secondaryLabelColor];

    // Row 1: Session Control, Mode, Band, Dial VFO, Audio Interface & Audio Input VU Meter
    NSBox *sepRow1_1 = [NSBox new]; sepRow1_1.boxType = NSBoxSeparator; [sepRow1_1.heightAnchor constraintEqualToConstant:16].active = YES;
    NSBox *sepRow1_2 = [NSBox new]; sepRow1_2.boxType = NSBoxSeparator; [sepRow1_2.heightAnchor constraintEqualToConstant:16].active = YES;

    self.audioLevelMeter = [[TX500AudioLevelMeterView alloc] initWithFrame:NSMakeRect(0, 0, 74, 20)];
    [self.audioLevelMeter.widthAnchor constraintEqualToConstant:74].active = YES;
    [self.audioLevelMeter.heightAnchor constraintEqualToConstant:20].active = YES;

    NSView *spacerR1 = [NSView new];
    spacerR1.translatesAutoresizingMaskIntoConstraints = NO;
    [spacerR1 setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *row1Stack = [NSStackView stackViewWithViews:@[
        self.startStopButton, self.modeSegment, self.bandPopup, self.dialFreqLabel, sepRow1_1,
        self.audioInPopup, self.audioLevelMeter, sepRow1_2, self.simCheckbox, spacerR1
    ]];
    row1Stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row1Stack.alignment = NSLayoutAttributeCenterY;
    row1Stack.spacing = 8;

    // Row 2: AF Frequencies, Tuning, Transmit Control, Split/Fake-It, Parity & SWR Protection
    NSBox *sepRow2_1 = [NSBox new]; sepRow2_1.boxType = NSBoxSeparator; [sepRow2_1.heightAnchor constraintEqualToConstant:16].active = YES;
    NSBox *sepRow2_2 = [NSBox new]; sepRow2_2.boxType = NSBoxSeparator; [sepRow2_2.heightAnchor constraintEqualToConstant:16].active = YES;

    self.fakeItCheckbox = [NSButton checkboxWithTitle:@"Fake It" target:self action:@selector(toggleFakeIt:)];
    self.fakeItCheckbox.state = self.audioEngine.splitFakeItEnabled ? NSControlStateValueOn : NSControlStateValueOff;

    NSView *spacerR2 = [NSView new];
    spacerR2.translatesAutoresizingMaskIntoConstraints = NO;
    [spacerR2 setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *row2Stack = [NSStackView stackViewWithViews:@[
        rxLbl, self.rxFreqField, txLbl, self.txFreqField,
        self.lockFreqsButton, self.tuneButton, self.armTxButton, sepRow2_1,
        self.txParitySegment, self.fakeItCheckbox, sepRow2_2, self.swrLabel, spacerR2
    ]];
    row2Stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row2Stack.alignment = NSLayoutAttributeCenterY;
    row2Stack.spacing = 8;

    NSStackView *ribbonVStack = [NSStackView stackViewWithViews:@[row1Stack, row2Stack]];
    ribbonVStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    ribbonVStack.alignment = NSLayoutAttributeLeading;
    ribbonVStack.spacing = 8;
    ribbonVStack.translatesAutoresizingMaskIntoConstraints = NO;
    [topRibbon.contentView addSubview:ribbonVStack];

    [NSLayoutConstraint activateConstraints:@[
        [ribbonVStack.topAnchor constraintEqualToAnchor:topRibbon.contentView.topAnchor constant:7],
        [ribbonVStack.leadingAnchor constraintEqualToAnchor:topRibbon.contentView.leadingAnchor constant:10],
        [ribbonVStack.trailingAnchor constraintEqualToAnchor:topRibbon.contentView.trailingAnchor constant:-10],
        [ribbonVStack.bottomAnchor constraintEqualToAnchor:topRibbon.contentView.bottomAnchor constant:-7],
        [row1Stack.widthAnchor constraintEqualToAnchor:ribbonVStack.widthAnchor],
        [row2Stack.widthAnchor constraintEqualToAnchor:ribbonVStack.widthAnchor],
        [topRibbon.heightAnchor constraintEqualToConstant:72]
    ]];

    // --- 2. Lab599 Precision Panadapter & Spectrogram Chassis ---
    self.panadapterBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    self.panadapterBox.translatesAutoresizingMaskIntoConstraints = NO;
    self.panadapterBox.boxType = NSBoxCustom;
    self.panadapterBox.cornerRadius = 8.0;
    self.panadapterBox.borderWidth = 1.0;
    self.panadapterBox.borderColor = [NSColor separatorColor];
    self.panadapterBox.fillColor = [NSColor controlBackgroundColor];
    [self.view addSubview:self.panadapterBox];
    NSBox *panadapterBox = self.panadapterBox;

    // Panadapter Header Bar
    NSTextField *panTitleBadge = [NSTextField labelWithString:@"LAB599 TX-500"];
    panTitleBadge.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightHeavy];
    panTitleBadge.textColor = [NSColor colorWithCalibratedRed:0.80 green:0.48 blue:0.0 alpha:1.0]; // Lab599 Signature Amber Gold

    NSTextField *panSubBadge = [NSTextField labelWithString:@"PANADAPTER · 0 — 3000 Hz AF SPECTRUM"];
    panSubBadge.font = [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightMedium];
    panSubBadge.textColor = [NSColor secondaryLabelColor];

    NSStackView *panHeaderLeft = [NSStackView stackViewWithViews:@[panTitleBadge, panSubBadge]];
    panHeaderLeft.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    panHeaderLeft.spacing = 8;
    panHeaderLeft.alignment = NSLayoutAttributeCenterY;

    // DSP Controls: Palette popup, Gain slider, Contrast slider & Live UTC Clock
    self.palettePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSString *name in [TX500FT8WaterfallView paletteNames]) {
        [self.palettePopup addItemWithTitle:name];
    }
    self.palettePopup.target = self;
    self.palettePopup.action = @selector(paletteChanged:);
    [self.palettePopup selectItemAtIndex:(NSInteger)self.waterfallView.palette];
    [self.palettePopup.widthAnchor constraintEqualToConstant:115].active = YES;

    NSTextField *gainLbl = [NSTextField labelWithString:@"Gain:"];
    gainLbl.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
    self.gainSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.gainSlider.minValue = 0.2;
    self.gainSlider.maxValue = 3.0;
    self.gainSlider.floatValue = 1.0;
    self.gainSlider.target = self;
    self.gainSlider.action = @selector(gainSliderChanged:);
    [self.gainSlider.widthAnchor constraintEqualToConstant:55].active = YES;

    NSTextField *contrastLbl = [NSTextField labelWithString:@"Floor:"];
    contrastLbl.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
    self.contrastSlider = [[NSSlider alloc] initWithFrame:NSZeroRect];
    self.contrastSlider.minValue = -0.3;
    self.contrastSlider.maxValue = 0.3;
    self.contrastSlider.floatValue = 0.0;
    self.contrastSlider.target = self;
    self.contrastSlider.action = @selector(contrastSliderChanged:);
    [self.contrastSlider.widthAnchor constraintEqualToConstant:55].active = YES;

    self.liveUtcLabel = [NSTextField labelWithString:@"UTC 00:00:00"];
    self.liveUtcLabel.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightBold];
    self.liveUtcLabel.textColor = [NSColor colorWithCalibratedRed:0.05 green:0.45 blue:0.75 alpha:1.0];

    self.callsignTagsCheckbox = [NSButton checkboxWithTitle:@"Tags" target:self action:@selector(toggleCallsignTags:)];
    self.callsignTagsCheckbox.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
    self.callsignTagsCheckbox.state = NSControlStateValueOn;
    self.callsignTagsCheckbox.toolTip = @"Toggle callsign HUD badges above waterfall signal traces";

    self.collapseWaterfallButton = [NSButton buttonWithTitle:@"− Hide WF" target:self action:@selector(toggleWaterfallCollapse:)];
    self.collapseWaterfallButton.bezelStyle = NSBezelStyleInline;
    self.collapseWaterfallButton.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium];
    self.collapseWaterfallButton.toolTip = @"Collapse waterfall to expand decode tables";

    NSStackView *dspStack = [NSStackView stackViewWithViews:@[
        self.palettePopup, gainLbl, self.gainSlider, contrastLbl, self.contrastSlider,
        self.callsignTagsCheckbox, self.collapseWaterfallButton, self.liveUtcLabel
    ]];
    dspStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    dspStack.spacing = 6;
    dspStack.alignment = NSLayoutAttributeCenterY;

    NSStackView *panHeader = [NSStackView stackViewWithViews:@[panHeaderLeft, dspStack]];
    panHeader.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    panHeader.alignment = NSLayoutAttributeCenterY;
    panHeader.distribution = NSStackViewDistributionEqualSpacing;
    panHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [panadapterBox.contentView addSubview:panHeader];

    // Slot Progress View inside panadapterBox
    self.slotProgressView = [[TX500FT8SlotProgressView alloc] initWithFrame:NSZeroRect];
    self.slotProgressView.translatesAutoresizingMaskIntoConstraints = NO;
    [panadapterBox.contentView addSubview:self.slotProgressView];

    // 2D Waterfall View inside panadapterBox
    self.waterfallView = [[TX500FT8WaterfallView alloc] initWithFrame:NSZeroRect];
    self.waterfallView.translatesAutoresizingMaskIntoConstraints = NO;
    [panadapterBox.contentView addSubview:self.waterfallView];

    NSLayoutConstraint *wfHeight = [self.waterfallView.heightAnchor constraintEqualToConstant:110];
    wfHeight.priority = NSLayoutPriorityDefaultHigh;

    self.panadapterExpandedBottomConstraint = [self.waterfallView.bottomAnchor constraintEqualToAnchor:panadapterBox.contentView.bottomAnchor constant:-7];
    self.panadapterCollapsedBottomConstraint = [panHeader.bottomAnchor constraintEqualToAnchor:panadapterBox.contentView.bottomAnchor constant:-5];

    [NSLayoutConstraint activateConstraints:@[
        [panHeader.topAnchor constraintEqualToAnchor:panadapterBox.contentView.topAnchor constant:5],
        [panHeader.leadingAnchor constraintEqualToAnchor:panadapterBox.contentView.leadingAnchor constant:10],
        [panHeader.trailingAnchor constraintEqualToAnchor:panadapterBox.contentView.trailingAnchor constant:-10],
        [panHeader.heightAnchor constraintEqualToConstant:16],

        [self.slotProgressView.topAnchor constraintEqualToAnchor:panHeader.bottomAnchor constant:4],
        [self.slotProgressView.leadingAnchor constraintEqualToAnchor:panadapterBox.contentView.leadingAnchor constant:8],
        [self.slotProgressView.trailingAnchor constraintEqualToAnchor:panadapterBox.contentView.trailingAnchor constant:-8],
        [self.slotProgressView.heightAnchor constraintEqualToConstant:18],

        [self.waterfallView.topAnchor constraintEqualToAnchor:self.slotProgressView.bottomAnchor constant:4],
        [self.waterfallView.leadingAnchor constraintEqualToAnchor:panadapterBox.contentView.leadingAnchor constant:8],
        [self.waterfallView.trailingAnchor constraintEqualToAnchor:panadapterBox.contentView.trailingAnchor constant:-8],
        self.panadapterExpandedBottomConstraint,
        wfHeight,
        [self.waterfallView.heightAnchor constraintGreaterThanOrEqualToConstant:70]
    ]];

    // --- 4. Autonomous Algorithms HUD Box ---
    self.algoBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    self.algoBox.translatesAutoresizingMaskIntoConstraints = NO;
    self.algoBox.boxType = NSBoxCustom;
    self.algoBox.fillColor = [NSColor controlBackgroundColor];
    self.algoBox.borderColor = [NSColor separatorColor];
    self.algoBox.borderWidth = 1.0;
    self.algoBox.cornerRadius = 8.0;
    [self.view addSubview:self.algoBox];
    NSBox *algoBox = self.algoBox;

    self.autoCQButton = [NSButton buttonWithTitle:@"Auto-CQ" target:self action:@selector(toggleAutoCQ:)];
    self.autoCQButton.bezelStyle = NSBezelStyleRounded;
    [self.autoCQButton.widthAnchor constraintEqualToConstant:78].active = YES;

    self.autoCQStepper = [[NSStepper alloc] initWithFrame:NSZeroRect];
    self.autoCQStepper.minValue = 1;
    self.autoCQStepper.maxValue = 50;
    self.autoCQStepper.integerValue = 10;
    self.autoCQStepper.target = self;
    self.autoCQStepper.action = @selector(autoCQStepperChanged:);

    self.autoCQCountLabel = [NSTextField labelWithString:@"(10)"];
    self.autoCQStatusLabel = [NSTextField labelWithString:@"📡 Auto-CQ: Idle"];
    self.autoCQStatusLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.autoCQStatusLabel.textColor = [NSColor colorWithCalibratedRed:0.08 green:0.55 blue:0.20 alpha:1.0];

    NSBox *algoSep = [NSBox new]; algoSep.boxType = NSBoxSeparator; [algoSep.heightAnchor constraintEqualToConstant:16].active = YES;

    self.autoHunterButton = [NSButton buttonWithTitle:@"Auto-Hunter" target:self action:@selector(toggleAutoHunter:)];
    self.autoHunterButton.bezelStyle = NSBezelStyleRounded;
    [self.autoHunterButton.widthAnchor constraintEqualToConstant:95].active = YES;

    self.hunterCriteriaPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.hunterCriteriaPopup addItemWithTitle:@"Max Distance"];
    [self.hunterCriteriaPopup addItemWithTitle:@"Max SNR"];
    [self.hunterCriteriaPopup addItemWithTitle:@"Weak Signal DX"];
    [self.hunterCriteriaPopup addItemWithTitle:@"New Grid"];
    [self.hunterCriteriaPopup addItemWithTitle:@"First in Slot"];
    self.hunterCriteriaPopup.target = self;
    self.hunterCriteriaPopup.action = @selector(hunterCriteriaChanged:);
    [self.hunterCriteriaPopup.widthAnchor constraintEqualToConstant:120].active = YES;

    self.autoHunterStatusLabel = [NSTextField labelWithString:@"🎯 Auto-Hunter: Monitoring band"];
    self.autoHunterStatusLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.autoHunterStatusLabel.textColor = [NSColor colorWithCalibratedRed:0.05 green:0.40 blue:0.75 alpha:1.0];

    NSStackView *algoStack = [NSStackView stackViewWithViews:@[
        self.autoCQButton, self.autoCQStepper, self.autoCQCountLabel, self.autoCQStatusLabel,
        algoSep,
        self.autoHunterButton, self.hunterCriteriaPopup, self.autoHunterStatusLabel
    ]];
    algoStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    algoStack.alignment = NSLayoutAttributeCenterY;
    algoStack.spacing = 8;
    algoStack.translatesAutoresizingMaskIntoConstraints = NO;
    [algoBox.contentView addSubview:algoStack];

    [NSLayoutConstraint activateConstraints:@[
        [algoStack.leadingAnchor constraintEqualToAnchor:algoBox.contentView.leadingAnchor constant:8],
        [algoStack.trailingAnchor constraintLessThanOrEqualToAnchor:algoBox.contentView.trailingAnchor constant:-8],
        [algoStack.centerYAnchor constraintEqualToAnchor:algoBox.contentView.centerYAnchor],
        [algoBox.heightAnchor constraintEqualToConstant:36]
    ]];

    // --- 5. Main Workstation Container (Split Left / Right) ---
    self.workstationSplitView = [[NSSplitView alloc] initWithFrame:NSZeroRect];
    self.workstationSplitView.vertical = YES;
    self.workstationSplitView.dividerStyle = NSSplitViewDividerStyleThin;
    self.workstationSplitView.translatesAutoresizingMaskIntoConstraints = NO;
    self.workstationSplitView.delegate = self;
    [self.view addSubview:self.workstationSplitView];

    // Left Activity Area
    NSView *leftArea = [NSView new];
    leftArea.translatesAutoresizingMaskIntoConstraints = NO;
    [self.workstationSplitView addSubview:leftArea];

    // Left Filter Bar
    self.tableFilterSegment = [NSSegmentedControl segmentedControlWithLabels:@[@"All", @"CQ Only", @"To Me"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(filterChanged:)];
    self.tableFilterSegment.selectedSegment = 0;
    self.tableFilterSegment.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tableFilterSegment.widthAnchor constraintEqualToConstant:148].active = YES;

    self.searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.target = self;
    self.searchField.action = @selector(searchChanged:);
    [self.searchField.widthAnchor constraintEqualToConstant:110].active = YES;

    NSButton *clearDecodesBtn = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearDecodesClicked:)];
    clearDecodesBtn.translatesAutoresizingMaskIntoConstraints = NO;
    clearDecodesBtn.bezelStyle = NSBezelStyleInline;
    [clearDecodesBtn.widthAnchor constraintEqualToConstant:50].active = YES;

    self.pskReporterCheckbox = [NSButton checkboxWithTitle:@"PSKReporter" target:self action:@selector(togglePSKReporter:)];
    self.pskReporterCheckbox.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    self.pskReporterCheckbox.state = self.pskReporterEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.pskReporterCheckbox.translatesAutoresizingMaskIntoConstraints = NO;

    self.wideTablesBtn = [NSButton buttonWithTitle:@"⤢ Wide View" target:self action:@selector(toggleWideTables:)];
    self.wideTablesBtn.bezelStyle = NSBezelStyleInline;
    self.wideTablesBtn.toolTip = @"Toggle Wide Tables (Expand decode tables across full width, hiding TX Matrix)";
    [self.wideTablesBtn.widthAnchor constraintEqualToConstant:78].active = YES;

    self.fullHeightBtn = [NSButton buttonWithTitle:@"⛶ Full Height" target:self action:@selector(toggleFullHeight:)];
    self.fullHeightBtn.bezelStyle = NSBezelStyleInline;
    self.fullHeightBtn.toolTip = @"Toggle Full Height (Maximize decode tables vertically by collapsing panadapter)";
    [self.fullHeightBtn.widthAnchor constraintEqualToConstant:86].active = YES;

    // SNR Range Filter fields
    NSTextField *snrMinLbl = [NSTextField labelWithString:@"SNR≥"];
    snrMinLbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.snrMinField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.snrMinField.placeholderString = @"-30";
    self.snrMinField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.snrMinField.target = self;
    self.snrMinField.action = @selector(filterChanged:);
    [self.snrMinField.widthAnchor constraintEqualToConstant:38].active = YES;

    NSTextField *snrMaxLbl = [NSTextField labelWithString:@"≤"];
    snrMaxLbl.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.snrMaxField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.snrMaxField.placeholderString = @"+30";
    self.snrMaxField.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.snrMaxField.target = self;
    self.snrMaxField.action = @selector(filterChanged:);
    [self.snrMaxField.widthAnchor constraintEqualToConstant:38].active = YES;
    NSTextField *snrUnit = [NSTextField labelWithString:@"dB"];
    snrUnit.font = [NSFont systemFontOfSize:11];

    // Alert Controls
    self.alertEnabledCheckbox = [NSButton checkboxWithTitle:@"Alert:" target:self action:@selector(filterChanged:)];
    self.alertEnabledCheckbox.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.alertCountryPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.alertCountryPopup.target = self;
    self.alertCountryPopup.action = @selector(filterChanged:);
    [self.alertCountryPopup.widthAnchor constraintGreaterThanOrEqualToConstant:155].active = YES;
    [self rebuildAlertCountryMenu];

    NSStackView *advFilterBar = [NSStackView stackViewWithViews:@[
        snrMinLbl, self.snrMinField, snrMaxLbl, self.snrMaxField, snrUnit,
        self.alertEnabledCheckbox, self.alertCountryPopup
    ]];
    // Live Cycle Status & Transmission Banner
    self.cycleBannerBox = [NSBox new];
    self.cycleBannerBox.translatesAutoresizingMaskIntoConstraints = NO;
    self.cycleBannerBox.boxType = NSBoxCustom;
    self.cycleBannerBox.fillColor = [NSColor controlBackgroundColor];
    self.cycleBannerBox.borderColor = [NSColor separatorColor];
    self.cycleBannerBox.borderWidth = 1.0;
    self.cycleBannerBox.cornerRadius = 6.0;
    [leftArea addSubview:self.cycleBannerBox];

    self.cycleBadge = [NSTextField labelWithString:@"● RECEIVING"];
    self.cycleBadge.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightBold];
    self.cycleBadge.textColor = [NSColor systemBlueColor];
    self.cycleBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cycleBannerBox.contentView addSubview:self.cycleBadge];

    self.cycleDetailLabel = [NSTextField labelWithString:@"Listening for digital signals..."];
    self.cycleDetailLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    self.cycleDetailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    self.cycleDetailLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cycleBannerBox.contentView addSubview:self.cycleDetailLabel];

    self.cycleClockLabel = [NSTextField labelWithString:@"0.0s / 15.0s"];
    self.cycleClockLabel.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    self.cycleClockLabel.textColor = [NSColor secondaryLabelColor];
    self.cycleClockLabel.alignment = NSTextAlignmentRight;
    self.cycleClockLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cycleBannerBox.contentView addSubview:self.cycleClockLabel];

    [NSLayoutConstraint activateConstraints:@[
        [self.cycleBadge.leadingAnchor constraintEqualToAnchor:self.cycleBannerBox.contentView.leadingAnchor constant:8],
        [self.cycleBadge.centerYAnchor constraintEqualToAnchor:self.cycleBannerBox.contentView.centerYAnchor],
        [self.cycleBadge.widthAnchor constraintEqualToConstant:150],

        [self.cycleDetailLabel.leadingAnchor constraintEqualToAnchor:self.cycleBadge.trailingAnchor constant:8],
        [self.cycleDetailLabel.centerYAnchor constraintEqualToAnchor:self.cycleBannerBox.contentView.centerYAnchor],
        [self.cycleDetailLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.cycleClockLabel.leadingAnchor constant:-8],

        [self.cycleClockLabel.trailingAnchor constraintEqualToAnchor:self.cycleBannerBox.contentView.trailingAnchor constant:-8],
        [self.cycleClockLabel.centerYAnchor constraintEqualToAnchor:self.cycleBannerBox.contentView.centerYAnchor],
        [self.cycleClockLabel.widthAnchor constraintEqualToConstant:90]
    ]];

    advFilterBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    advFilterBar.alignment = NSLayoutAttributeCenterY;
    advFilterBar.spacing = 5;
    advFilterBar.translatesAutoresizingMaskIntoConstraints = NO;
    [leftArea addSubview:advFilterBar];

    NSStackView *filterBar = [NSStackView stackViewWithViews:@[
        self.tableFilterSegment, self.searchField, clearDecodesBtn,
        self.pskReporterCheckbox, self.wideTablesBtn, self.fullHeightBtn
    ]];
    filterBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    filterBar.alignment = NSLayoutAttributeCenterY;
    filterBar.spacing = 8;
    filterBar.translatesAutoresizingMaskIntoConstraints = NO;
    [leftArea addSubview:filterBar];

    // --- Dual Activity Tables: Band Activity (Left) and Rx Frequency (Right) ---
    NSBox *bandBox = [NSBox new];
    bandBox.translatesAutoresizingMaskIntoConstraints = NO;
    bandBox.boxType = NSBoxCustom;
    bandBox.fillColor = [NSColor controlBackgroundColor];
    bandBox.borderColor = [NSColor separatorColor];
    bandBox.borderWidth = 1.0;
    bandBox.cornerRadius = 6.0;

    NSTextField *bandTitle = [NSTextField labelWithString:@"BAND ACTIVITY · 0 — 3000 Hz"];
    bandTitle.font = [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold];
    bandTitle.textColor = [NSColor secondaryLabelColor];
    bandTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [bandBox.contentView addSubview:bandTitle];

    NSScrollView *bandScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    bandScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    bandScrollView.hasVerticalScroller = YES;
    bandScrollView.borderType = NSNoBorder;
    bandScrollView.autohidesScrollers = YES;

    self.bandActivityTableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.activityTableView = self.bandActivityTableView; // Maintain backward compatibility
    self.bandActivityTableView.dataSource = self;
    self.bandActivityTableView.delegate = self;
    self.bandActivityTableView.rowHeight = 22.0;
    self.bandActivityTableView.usesAlternatingRowBackgroundColors = NO;
    self.bandActivityTableView.target = self;
    self.bandActivityTableView.action = @selector(tableRowClicked:);
    self.bandActivityTableView.doubleAction = @selector(tableRowDoubleClicked:);
    self.bandActivityTableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    [self setupTableContextMenu:self.bandActivityTableView];

    [self addColumnToTable:self.bandActivityTableView title:@"Time" identifier:kColTime width:58];
    [self addColumnToTable:self.bandActivityTableView title:@"dB" identifier:kColSNR width:34];
    [self addColumnToTable:self.bandActivityTableView title:@"DT" identifier:kColDT width:34];
    [self addColumnToTable:self.bandActivityTableView title:@"Freq" identifier:kColFreq width:44];
    [self addColumnToTable:self.bandActivityTableView title:@"Message" identifier:kColMsg width:160];
    [self addColumnToTable:self.bandActivityTableView title:@"Country" identifier:kColCountry width:110];
    [self addColumnToTable:self.bandActivityTableView title:@"Grid" identifier:kColGrid width:48];
    [self addColumnToTable:self.bandActivityTableView title:@"Dist" identifier:kColDistance width:50];
    bandScrollView.documentView = self.bandActivityTableView;
    [bandBox.contentView addSubview:bandScrollView];

    [NSLayoutConstraint activateConstraints:@[
        [bandTitle.topAnchor constraintEqualToAnchor:bandBox.contentView.topAnchor constant:4],
        [bandTitle.leadingAnchor constraintEqualToAnchor:bandBox.contentView.leadingAnchor constant:6],
        [bandScrollView.topAnchor constraintEqualToAnchor:bandTitle.bottomAnchor constant:4],
        [bandScrollView.leadingAnchor constraintEqualToAnchor:bandBox.contentView.leadingAnchor],
        [bandScrollView.trailingAnchor constraintEqualToAnchor:bandBox.contentView.trailingAnchor],
        [bandScrollView.bottomAnchor constraintEqualToAnchor:bandBox.contentView.bottomAnchor]
    ]];

    // Right Box: Rx Frequency (QSO Monitor)
    NSBox *rxBox = [NSBox new];
    rxBox.translatesAutoresizingMaskIntoConstraints = NO;
    rxBox.boxType = NSBoxCustom;
    rxBox.fillColor = [NSColor controlBackgroundColor];
    rxBox.borderColor = [NSColor separatorColor];
    rxBox.borderWidth = 1.0;
    rxBox.cornerRadius = 6.0;

    NSTextField *rxTitle = [NSTextField labelWithString:@"RX FREQUENCY · QSO MONITOR"];
    rxTitle.font = [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold];
    rxTitle.textColor = [NSColor colorWithCalibratedRed:0.05 green:0.45 blue:0.75 alpha:1.0];
    rxTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [rxBox.contentView addSubview:rxTitle];

    NSScrollView *rxScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    rxScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    rxScrollView.hasVerticalScroller = YES;
    rxScrollView.borderType = NSNoBorder;
    rxScrollView.autohidesScrollers = YES;

    self.rxFreqTableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.rxFreqTableView.dataSource = self;
    self.rxFreqTableView.delegate = self;
    self.rxFreqTableView.rowHeight = 22.0;
    self.rxFreqTableView.usesAlternatingRowBackgroundColors = NO;
    self.rxFreqTableView.target = self;
    self.rxFreqTableView.action = @selector(tableRowClicked:);
    self.rxFreqTableView.doubleAction = @selector(tableRowDoubleClicked:);
    self.rxFreqTableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    [self setupTableContextMenu:self.rxFreqTableView];

    [self addColumnToTable:self.rxFreqTableView title:@"Time" identifier:kColTime width:58];
    [self addColumnToTable:self.rxFreqTableView title:@"dB" identifier:kColSNR width:34];
    [self addColumnToTable:self.rxFreqTableView title:@"Freq" identifier:kColFreq width:44];
    [self addColumnToTable:self.rxFreqTableView title:@"Message" identifier:kColMsg width:160];
    rxScrollView.documentView = self.rxFreqTableView;
    [rxBox.contentView addSubview:rxScrollView];

    [NSLayoutConstraint activateConstraints:@[
        [rxTitle.topAnchor constraintEqualToAnchor:rxBox.contentView.topAnchor constant:4],
        [rxTitle.leadingAnchor constraintEqualToAnchor:rxBox.contentView.leadingAnchor constant:6],
        [rxScrollView.topAnchor constraintEqualToAnchor:rxTitle.bottomAnchor constant:4],
        [rxScrollView.leadingAnchor constraintEqualToAnchor:rxBox.contentView.leadingAnchor],
        [rxScrollView.trailingAnchor constraintEqualToAnchor:rxBox.contentView.trailingAnchor],
        [rxScrollView.bottomAnchor constraintEqualToAnchor:rxBox.contentView.bottomAnchor]
    ]];

    self.tablesSplitView = [[NSSplitView alloc] initWithFrame:NSZeroRect];
    self.tablesSplitView.vertical = YES;
    self.tablesSplitView.dividerStyle = NSSplitViewDividerStyleThin;
    self.tablesSplitView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tablesSplitView.delegate = self;
    [self.tablesSplitView addSubview:bandBox];
    [self.tablesSplitView addSubview:rxBox];
    [leftArea addSubview:self.tablesSplitView];

    [NSLayoutConstraint activateConstraints:@[
        [self.cycleBannerBox.topAnchor constraintEqualToAnchor:leftArea.topAnchor],
        [self.cycleBannerBox.leadingAnchor constraintEqualToAnchor:leftArea.leadingAnchor],
        [self.cycleBannerBox.trailingAnchor constraintEqualToAnchor:leftArea.trailingAnchor],
        [self.cycleBannerBox.heightAnchor constraintEqualToConstant:24],

        [filterBar.topAnchor constraintEqualToAnchor:self.cycleBannerBox.bottomAnchor constant:4],
        [filterBar.leadingAnchor constraintEqualToAnchor:leftArea.leadingAnchor],
        [filterBar.trailingAnchor constraintEqualToAnchor:leftArea.trailingAnchor],
        [filterBar.heightAnchor constraintEqualToConstant:24],

        [advFilterBar.topAnchor constraintEqualToAnchor:filterBar.bottomAnchor constant:4],
        [advFilterBar.leadingAnchor constraintEqualToAnchor:leftArea.leadingAnchor],
        [advFilterBar.trailingAnchor constraintEqualToAnchor:leftArea.trailingAnchor],
        [advFilterBar.heightAnchor constraintEqualToConstant:22],

        [self.tablesSplitView.topAnchor constraintEqualToAnchor:advFilterBar.bottomAnchor constant:4],
        [self.tablesSplitView.leadingAnchor constraintEqualToAnchor:leftArea.leadingAnchor],
        [self.tablesSplitView.trailingAnchor constraintEqualToAnchor:leftArea.trailingAnchor],
        [self.tablesSplitView.bottomAnchor constraintEqualToAnchor:leftArea.bottomAnchor],

        [bandBox.widthAnchor constraintGreaterThanOrEqualToConstant:200],
        [rxBox.widthAnchor constraintGreaterThanOrEqualToConstant:160]
    ]];
    NSLayoutConstraint *bandWidth = [bandBox.widthAnchor constraintEqualToAnchor:self.tablesSplitView.widthAnchor multiplier:0.58];
    bandWidth.priority = NSLayoutPriorityDefaultLow;
    bandWidth.active = YES;

    // Right Panel: Transmit Matrix & Copilot
    self.rightBox = [NSBox new];
    self.rightBox.translatesAutoresizingMaskIntoConstraints = NO;
    self.rightBox.boxType = NSBoxCustom;
    self.rightBox.fillColor = [NSColor controlBackgroundColor];
    self.rightBox.borderColor = [NSColor separatorColor];
    self.rightBox.borderWidth = 1.0;
    self.rightBox.cornerRadius = 6.0;
    [self.workstationSplitView addSubview:self.rightBox];
    NSBox *rightBox = self.rightBox;

    // Callsigns row inside rightBox
    NSTextField *mcLbl = [NSTextField labelWithString:@"My Call:"];
    self.myCallField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.myCallField.stringValue = self.audioEngine.myCallsign;
    self.myCallField.target = self;
    self.myCallField.action = @selector(stationInfoEdited:);
    [self.myCallField.widthAnchor constraintEqualToConstant:75].active = YES;

    NSTextField *mgLbl = [NSTextField labelWithString:@"Grid:"];
    self.myGridField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.myGridField.stringValue = self.audioEngine.myGrid;
    self.myGridField.target = self;
    self.myGridField.action = @selector(stationInfoEdited:);
    [self.myGridField.widthAnchor constraintEqualToConstant:55].active = YES;

    NSStackView *myCallStack = [NSStackView stackViewWithViews:@[mcLbl, self.myCallField, mgLbl, self.myGridField]];
    myCallStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    myCallStack.alignment = NSLayoutAttributeCenterY;
    myCallStack.spacing = 6;
    myCallStack.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *dxLbl = [NSTextField labelWithString:@"DX Call:"];
    self.dxCallField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.dxCallField.placeholderString = @"DX Call";
    self.dxCallField.target = self;
    self.dxCallField.action = @selector(dxCallEdited:);
    [self.dxCallField.widthAnchor constraintEqualToConstant:75].active = YES;

    self.dxGridField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.dxGridField.placeholderString = @"Grid";
    [self.dxGridField.widthAnchor constraintEqualToConstant:55].active = YES;

    NSStackView *dxCallStack = [NSStackView stackViewWithViews:@[dxLbl, self.dxCallField, [NSTextField labelWithString:@"Grid:"], self.dxGridField]];
    dxCallStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    dxCallStack.alignment = NSLayoutAttributeCenterY;
    dxCallStack.spacing = 6;
    dxCallStack.translatesAutoresizingMaskIntoConstraints = NO;

    self.dxInfoLabel = [NSTextField labelWithString:@"DX: Ready for contact"];
    self.dxInfoLabel.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
    self.dxInfoLabel.textColor = [NSColor secondaryLabelColor];
    self.dxInfoLabel.translatesAutoresizingMaskIntoConstraints = NO;

    // Transmit Matrix Tx 1..Tx 6
    NSStackView *txMatrixStack = [NSStackView new];
    txMatrixStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    txMatrixStack.alignment = NSLayoutAttributeLeading;
    txMatrixStack.spacing = 4;
    txMatrixStack.translatesAutoresizingMaskIntoConstraints = NO;

    for (int i = 1; i <= 6; i++) {
        NSButton *btn = [NSButton buttonWithTitle:[NSString stringWithFormat:@"Tx %d", i] target:self action:@selector(txMatrixButtonClicked:)];
        btn.bezelStyle = NSBezelStyleInline;
        btn.tag = i;
        [btn.widthAnchor constraintEqualToConstant:46].active = YES;
        [self.txMessageButtons addObject:btn];

        NSTextField *lbl = [NSTextField labelWithString:@"-"];
        lbl.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightMedium];
        lbl.textColor = [NSColor labelColor];
        [self.txMessageLabels addObject:lbl];

        NSStackView *row = [NSStackView stackViewWithViews:@[btn, lbl]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        row.alignment = NSLayoutAttributeCenterY;
        row.spacing = 6;
        [txMatrixStack addArrangedSubview:row];
    }

    // Copilot Controls
    self.nextStepButton = [NSButton buttonWithTitle:@"Next Step" target:self action:@selector(nextStepClicked:)];
    self.nextStepButton.bezelStyle = NSBezelStyleRounded;
    [self.nextStepButton.widthAnchor constraintEqualToConstant:90].active = YES;

    self.abortButton = [NSButton buttonWithTitle:@"Abort QSO" target:self action:@selector(abortClicked:)];
    self.abortButton.bezelStyle = NSBezelStyleRounded;
    [self.abortButton.widthAnchor constraintEqualToConstant:90].active = YES;

    NSStackView *copilotStack = [NSStackView stackViewWithViews:@[self.nextStepButton, self.abortButton]];
    copilotStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    copilotStack.alignment = NSLayoutAttributeCenterY;
    copilotStack.spacing = 8;
    copilotStack.translatesAutoresizingMaskIntoConstraints = NO;

    // QSO Console ScrollView
    NSScrollView *consoleScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    consoleScroll.translatesAutoresizingMaskIntoConstraints = NO;
    consoleScroll.hasVerticalScroller = YES;
    consoleScroll.borderType = NSBezelBorder;
    self.qsoConsoleTextView = [[NSTextView alloc] initWithFrame:NSZeroRect];
    self.qsoConsoleTextView.editable = NO;
    self.qsoConsoleTextView.backgroundColor = [NSColor textBackgroundColor];
    self.qsoConsoleTextView.textColor = [NSColor labelColor];
    self.qsoConsoleTextView.font = [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightRegular];
    self.qsoConsoleTextView.textContainerInset = NSMakeSize(4, 4);
    consoleScroll.documentView = self.qsoConsoleTextView;

    NSBox *rSep1 = [NSBox new]; rSep1.boxType = NSBoxSeparator; rSep1.translatesAutoresizingMaskIntoConstraints = NO;
    NSBox *rSep2 = [NSBox new]; rSep2.boxType = NSBoxSeparator; rSep2.translatesAutoresizingMaskIntoConstraints = NO;

    [rightBox.contentView addSubview:myCallStack];
    [rightBox.contentView addSubview:dxCallStack];
    [rightBox.contentView addSubview:self.dxInfoLabel];
    [rightBox.contentView addSubview:rSep1];
    [rightBox.contentView addSubview:txMatrixStack];
    [rightBox.contentView addSubview:rSep2];
    [rightBox.contentView addSubview:copilotStack];
    [rightBox.contentView addSubview:consoleScroll];

    [NSLayoutConstraint activateConstraints:@[
        [myCallStack.topAnchor constraintEqualToAnchor:rightBox.contentView.topAnchor constant:8],
        [myCallStack.leadingAnchor constraintEqualToAnchor:rightBox.contentView.leadingAnchor constant:10],

        [dxCallStack.topAnchor constraintEqualToAnchor:myCallStack.bottomAnchor constant:6],
        [dxCallStack.leadingAnchor constraintEqualToAnchor:rightBox.contentView.leadingAnchor constant:10],

        [self.dxInfoLabel.topAnchor constraintEqualToAnchor:dxCallStack.bottomAnchor constant:4],
        [self.dxInfoLabel.leadingAnchor constraintEqualToAnchor:rightBox.contentView.leadingAnchor constant:10],
        [self.dxInfoLabel.trailingAnchor constraintEqualToAnchor:rightBox.contentView.trailingAnchor constant:-10],

        [rSep1.topAnchor constraintEqualToAnchor:self.dxInfoLabel.bottomAnchor constant:6],
        [rSep1.leadingAnchor constraintEqualToAnchor:rightBox.contentView.leadingAnchor constant:10],
        [rSep1.trailingAnchor constraintEqualToAnchor:rightBox.contentView.trailingAnchor constant:-10],

        [txMatrixStack.topAnchor constraintEqualToAnchor:rSep1.bottomAnchor constant:6],
        [txMatrixStack.leadingAnchor constraintEqualToAnchor:rightBox.contentView.leadingAnchor constant:10],
        [txMatrixStack.trailingAnchor constraintEqualToAnchor:rightBox.contentView.trailingAnchor constant:-10],

        [rSep2.topAnchor constraintEqualToAnchor:txMatrixStack.bottomAnchor constant:6],
        [rSep2.leadingAnchor constraintEqualToAnchor:rightBox.contentView.leadingAnchor constant:10],
        [rSep2.trailingAnchor constraintEqualToAnchor:rightBox.contentView.trailingAnchor constant:-10],

        [copilotStack.topAnchor constraintEqualToAnchor:rSep2.bottomAnchor constant:6],
        [copilotStack.leadingAnchor constraintEqualToAnchor:rightBox.contentView.leadingAnchor constant:10],

        [consoleScroll.topAnchor constraintEqualToAnchor:copilotStack.bottomAnchor constant:6],
        [consoleScroll.leadingAnchor constraintEqualToAnchor:rightBox.contentView.leadingAnchor constant:10],
        [consoleScroll.trailingAnchor constraintEqualToAnchor:rightBox.contentView.trailingAnchor constant:-10],
        [consoleScroll.bottomAnchor constraintEqualToAnchor:rightBox.contentView.bottomAnchor constant:-8],
    ]];

    // Workstation Split View Constraints
    NSLayoutConstraint *rightBoxWidth = [self.rightBox.widthAnchor constraintEqualToConstant:315];
    rightBoxWidth.priority = NSLayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [leftArea.widthAnchor constraintGreaterThanOrEqualToConstant:320],
        rightBoxWidth,
        [self.rightBox.widthAnchor constraintGreaterThanOrEqualToConstant:220],
        [self.rightBox.widthAnchor constraintLessThanOrEqualToConstant:550]
    ]];
    [self.workstationSplitView setHoldingPriority:NSLayoutPriorityDefaultLow forSubviewAtIndex:0];
    [self.workstationSplitView setHoldingPriority:NSLayoutPriorityDefaultHigh forSubviewAtIndex:1];

    // --- 6. Bottom Status Bar ---
    self.sessionLogCountLabel = [NSTextField labelWithString:@"Session QSOs: 0"];
    self.sessionLogCountLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightBold];
    self.sessionLogCountLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.openLogsButton = [NSButton buttonWithTitle:@"Open Logs Folder" target:self action:@selector(openLogsFolderClicked:)];
    self.openLogsButton.bezelStyle = NSBezelStyleRounded;
    self.openLogsButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.exportADIFButton = [NSButton buttonWithTitle:@"Export ADIF" target:self action:@selector(exportADIFClicked:)];
    self.exportADIFButton.bezelStyle = NSBezelStyleRounded;
    self.exportADIFButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.clearLogButton = [NSButton buttonWithTitle:@"Clear Log" target:self action:@selector(clearLogClicked:)];
    self.clearLogButton.bezelStyle = NSBezelStyleRounded;
    self.clearLogButton.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *bottomSpacer = [NSView new];
    bottomSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [bottomSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *bottomStack = [NSStackView stackViewWithViews:@[
        self.sessionLogCountLabel, bottomSpacer, self.openLogsButton, self.exportADIFButton, self.clearLogButton
    ]];
    bottomStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottomStack.alignment = NSLayoutAttributeCenterY;
    bottomStack.spacing = 10;
    bottomStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bottomStack];

    NSLayoutConstraint *wsHeight = [self.workstationSplitView.heightAnchor constraintGreaterThanOrEqualToConstant:460];
    wsHeight.priority = 850;


    self.panadapterTopConstraint = [self.panadapterBox.topAnchor constraintEqualToAnchor:topRibbon.bottomAnchor constant:6];
    self.algoTopConstraint = [self.algoBox.topAnchor constraintEqualToAnchor:self.panadapterBox.bottomAnchor constant:6];
    self.workstationTopToAlgoConstraint = [self.workstationSplitView.topAnchor constraintEqualToAnchor:self.algoBox.bottomAnchor constant:6];
    self.workstationTopToRibbonConstraint = [self.workstationSplitView.topAnchor constraintEqualToAnchor:topRibbon.bottomAnchor constant:6];

    // --- Main Vertical Stack Auto-Layout Constraints ---
    [NSLayoutConstraint activateConstraints:@[
        [topRibbon.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [topRibbon.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [topRibbon.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        self.panadapterTopConstraint,
        [self.panadapterBox.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.panadapterBox.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        self.algoTopConstraint,
        [self.algoBox.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.algoBox.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        self.workstationTopToAlgoConstraint,
        [self.workstationSplitView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [self.workstationSplitView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        wsHeight,
        [self.workstationSplitView.heightAnchor constraintGreaterThanOrEqualToConstant:200],

        [bottomStack.topAnchor constraintEqualToAnchor:self.workstationSplitView.bottomAnchor constant:6],
        [bottomStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [bottomStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [bottomStack.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-8],
        [bottomStack.heightAnchor constraintEqualToConstant:24]
    ]];

    [self updateTransmitMatrixLabels];
    [self appendToQSOConsole:@"FT8 Autonomous Studio ready."];
    [self appendToQSOConsole:@"Standby for signals · Double-click decode to engage."];
}

- (void)addColumnToTable:(NSTableView *)table title:(NSString *)title identifier:(NSString *)ident width:(CGFloat)w {
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:ident];
    col.title = title;
    col.width = w;
    col.minWidth = w * 0.7;
    col.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [table addTableColumn:col];
}

#pragma mark - UI Actions

- (void)toggleMonitoring:(id)sender {
    (void)sender;
    if (self.audioEngine.isMonitoring) {
        [self stopStation];
    } else {
        [self startStation];
    }
}

- (void)bandSelected:(id)sender {
    (void)sender;
    NSString *band = self.bandPopup.titleOfSelectedItem;
    if (band.length > 0) {
        uint64_t freq = [self defaultFrequencyForBand:band protocol:self.protocol];
        if (freq > 0) {
            self.audioEngine.dialFrequencyHz = freq;
            [self updateFrequencyHz:freq mode:@"DIG"];
            if (self.serialCommandSender) {
                self.serialCommandSender([NSString stringWithFormat:@"FA%011llu;", (unsigned long long)freq]);
                self.serialCommandSender(@"MD6;");
            }
        }
    }
}

- (void)toggleSimulation:(id)sender {
    (void)sender;
    [self setSimulationEnabled:(self.simCheckbox.state == NSControlStateValueOn)];
}

- (void)setSimulationEnabled:(BOOL)enabled {
    self.simCheckbox.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.audioEngine.isSimulationMode = enabled;
    // Do NOT persist simulation mode as default across app launches.
    // Real transceivers must always operate in live radio mode upon opening the app.
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TX500_FT8_SimulationModeEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if (enabled) {
        [self appendToQSOConsole:@"⚠️ [Simulation Mode] Activated: Synthetic FT8 signals generated. Physical RF transmission is INHIBITED for bench testing."];
        if (self.allDecodes.count == 0) {
            [self.audioEngine injectSimulatedBandActivity];
        }
    } else {
        [self appendToQSOConsole:@"✓ [Live Radio Mode] Monitoring live audio. Hardware RTS & CAT PTT are ACTIVE for connected TX-500."];
        [self.allDecodes removeAllObjects];
        [self applyTableFilters];
    }
    [self updateLiveCycleStatusBannerWithSlotSec:self.audioEngine.currentSlotSecond parity:self.audioEngine.currentSlotParity];
}

- (void)frequenciesEdited:(id)sender {
    (void)sender;
    float rx = [self.rxFreqField.stringValue floatValue];
    float tx = [self.txFreqField.stringValue floatValue];
    if (rx >= 200 && rx <= 2900) self.audioEngine.rxAudioFrequencyHz = rx;
    if (tx >= 200 && tx <= 2900) self.audioEngine.txAudioFrequencyHz = tx;
    self.waterfallView.rxFrequencyHz = self.audioEngine.rxAudioFrequencyHz;
    self.waterfallView.txFrequencyHz = self.audioEngine.txAudioFrequencyHz;
    [self.waterfallView setNeedsDisplay:YES];
}

- (void)toggleLockFreqs:(id)sender {
    (void)sender;
    self.audioEngine.lockTxRxFrequencies = !self.audioEngine.lockTxRxFrequencies;
    self.lockFreqsButton.title = self.audioEngine.lockTxRxFrequencies ? @"Locked" : @"Lock";
    if (self.audioEngine.lockTxRxFrequencies) {
        self.audioEngine.txAudioFrequencyHz = self.audioEngine.rxAudioFrequencyHz;
        self.txFreqField.stringValue = self.rxFreqField.stringValue;
        self.waterfallView.txFrequencyHz = self.audioEngine.txAudioFrequencyHz;
        [self.waterfallView setNeedsDisplay:YES];
    }
}

- (void)toggleTune:(id)sender {
    (void)sender;
    if ([self.tuneButton.title isEqualToString:@"Tune"]) {
        if (self.audioEngine.isSimulationMode) {
            [self appendToQSOConsole:@"⚠️ Note: 'Simulation Mode' is active. Tune tone is simulated (no RF sent to radio). Uncheck 'Simulation Mode' to key transmitter."];
        }
        [self.audioEngine startTuneCarrier];
        self.tuneButton.title = @"STOP";
    } else {
        [self.audioEngine stopTuneCarrier];
        self.tuneButton.title = @"Tune";
    }
}

- (void)toggleArmTx:(id)sender {
    (void)sender;
    if (self.audioEngine.isTransmitArmed) {
        [self.audioEngine disarmTransmit];
        self.armTxButton.title = @"ENABLE TX";
        self.armTxButton.bezelColor = nil;
        if (self.autoEngine.qsoPhase == TX500FT8QSOPhaseCallingCQ) {
            [self.autoEngine setCallingCQState:NO];
        }
    } else {
        if (self.audioEngine.isSimulationMode) {
            [self appendToQSOConsole:@"⚠️ Note: 'Simulation Mode' is active. Transmit will be simulated and will NOT key your radio. Uncheck 'Simulation Mode' to transmit on the air."];
        }

        // Arm transmit with currently selected or active message
        NSString *msg = nil;
        if (self.autoEngine.isQSOActive) {
            NSInteger phase = (NSInteger)self.autoEngine.qsoPhase;
            if (phase >= 1 && phase <= 6 && self.txMessageLabels.count >= (NSUInteger)phase) {
                msg = self.txMessageLabels[phase - 1].stringValue;
            }
        }
        if (!msg || msg.length == 0 || [msg isEqualToString:@"-"] || [msg containsString:@"<DX>"] || [msg hasPrefix:@" "]) {
            if (self.dxCallField.stringValue.length > 0 && self.txMessageLabels.count >= 1) {
                msg = self.txMessageLabels[0].stringValue;
            } else if (self.txMessageLabels.count >= 6) {
                msg = self.txMessageLabels[5].stringValue; // Tx 6: CQ MyCall MyGrid
            }
        }
        if (!msg || msg.length == 0 || [msg isEqualToString:@"-"] || [msg containsString:@"<DX>"] || [msg hasPrefix:@" "]) {
            NSString *myCall = self.myCallField.stringValue.length > 0 ? self.myCallField.stringValue.uppercaseString : @"EP2AES";
            NSString *myGrid = self.myGridField.stringValue.length > 0 ? self.myGridField.stringValue.uppercaseString : @"KM35";
            msg = [NSString stringWithFormat:@"CQ %@ %@", myCall, myGrid.length >= 4 ? [myGrid substringToIndex:4] : myGrid];
        }

        // Determine parity from segment: 0=Even, 1=Auto, 2=Odd
        TX500FT8SlotParity parity;
        NSInteger seg = self.txParitySegment.selectedSegment;
        if (seg == 0) parity = TX500FT8SlotParityEven;
        else if (seg == 2) parity = TX500FT8SlotParityOdd;
        else parity = TX500FT8SlotParityAuto;

        [self.audioEngine armTransmitWithText:msg parity:parity];
        self.armTxButton.title = @"ARMED (TX)";
        self.armTxButton.bezelColor = [NSColor colorWithCalibratedRed:0.8 green:0.2 blue:0.2 alpha:1.0];
        if ([msg hasPrefix:@"CQ"]) {
            [self.autoEngine setCallingCQState:YES];
        }
    }
}

- (void)txParityChanged:(id)sender {
    (void)sender;
    // If TX is already armed, re-arm with the new parity without changing the message
    if (self.audioEngine.isTransmitArmed) {
        NSString *currentMsg = self.audioEngine.queuedTxMessage;
        NSInteger seg = self.txParitySegment.selectedSegment;
        TX500FT8SlotParity parity;
        if (seg == 0) parity = TX500FT8SlotParityEven;
        else if (seg == 2) parity = TX500FT8SlotParityOdd;
        else parity = TX500FT8SlotParityAuto;
        [self.audioEngine armTransmitWithText:currentMsg parity:parity];
    }
}

- (void)toggleAutoCQ:(id)sender {
    (void)sender;
    if (self.autoEngine.isAutoCQActive) {
        [self.autoEngine stopAutoCQ];
        self.autoCQButton.title = @"Auto-CQ";
        self.armTxButton.state = NSControlStateValueOff;
        self.armTxButton.title = @"ENABLE TX";
        self.armTxButton.bezelColor = nil;
    } else {
        if (self.autoEngine.isAutoHunterActive) {
            [self.autoEngine stopAutoHunter];
            self.autoHunterButton.title = @"Auto-Hunter";
        }
        if (!self.audioEngine.isMonitoring) {
            [self startStation];
        }
        [self.autoEngine startAutoCQWithLimit:self.autoCQStepper.integerValue];
        self.autoCQButton.title = @"Stop CQ";
        self.armTxButton.state = NSControlStateValueOn;
        self.armTxButton.title = @"ARMED (TX)";
        self.armTxButton.bezelColor = [NSColor colorWithCalibratedRed:0.8 green:0.2 blue:0.2 alpha:1.0];
    }
}

- (void)autoCQStepperChanged:(id)sender {
    (void)sender;
    self.autoCQCountLabel.stringValue = [NSString stringWithFormat:@"(%ld)", (long)self.autoCQStepper.integerValue];
    self.autoEngine.autoCQTargetCount = self.autoCQStepper.integerValue;
}

- (void)toggleAutoHunter:(id)sender {
    (void)sender;
    if (self.autoEngine.isAutoHunterActive) {
        [self.autoEngine stopAutoHunter];
        self.autoHunterButton.title = @"Auto-Hunter";
        self.armTxButton.state = NSControlStateValueOff;
        self.armTxButton.title = @"ENABLE TX";
        self.armTxButton.bezelColor = nil;
    } else {
        if (self.autoEngine.isAutoCQActive) {
            [self.autoEngine stopAutoCQ];
            self.autoCQButton.title = @"Auto-CQ";
        }
        if (!self.audioEngine.isMonitoring) {
            [self startStation];
        }
        [self.autoEngine startAutoHunter];
        self.autoHunterButton.title = @"Stop Hunter";
        if (self.audioEngine.isTransmitArmed) {
            self.armTxButton.state = NSControlStateValueOn;
            self.armTxButton.title = @"ARMED (TX)";
            self.armTxButton.bezelColor = [NSColor colorWithCalibratedRed:0.8 green:0.2 blue:0.2 alpha:1.0];
        }
    }
}

- (void)hunterCriteriaChanged:(id)sender {
    (void)sender;
    self.autoEngine.autoHunterCriteria = (TX500FT8HunterCriteria)self.hunterCriteriaPopup.indexOfSelectedItem;
}

- (void)stationInfoEdited:(id)sender {
    (void)sender;
    NSString *call = [self.myCallField.stringValue.uppercaseString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *grid = [self.myGridField.stringValue.uppercaseString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (call.length > 0) {
        self.audioEngine.myCallsign = call;
        [[NSUserDefaults standardUserDefaults] setObject:call forKey:@"TX500_OperatorCallsign"];
    }
    if (grid.length > 0) {
        self.audioEngine.myGrid = grid;
        [[NSUserDefaults standardUserDefaults] setObject:grid forKey:@"TX500_OperatorGrid"];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateTransmitMatrixLabels];
    [NSNotificationCenter.defaultCenter postNotificationName:@"TX500StationSettingsChangedNotification" object:self];
}

- (void)reloadStationPreferences {
    self.pskReporterEnabled=[NSUserDefaults.standardUserDefaults boolForKey:@"TX500_FT8_PSKReporterEnabled"];
    self.pskReporterCheckbox.state=self.pskReporterEnabled?NSControlStateValueOn:NSControlStateValueOff;
    NSString *call = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_OperatorCallsign"];
    if (call.length > 0) {
        self.audioEngine.myCallsign = call;
        self.myCallField.stringValue = call;
    }
    NSString *grid = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_OperatorGrid"];
    if (grid.length > 0) {
        self.audioEngine.myGrid = grid;
        self.myGridField.stringValue = grid;
    }

    [self updateTransmitMatrixLabels];
    [self.bandActivityTableView reloadData];
    [self.rxFreqTableView reloadData];
}

#pragma mark - Split / Fake It Mode

- (void)toggleFakeIt:(id)sender {
    (void)sender;
    self.audioEngine.splitFakeItEnabled = (self.fakeItCheckbox.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:self.audioEngine.splitFakeItEnabled forKey:@"TX500_FT8_FakeItEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self appendToQSOConsole:[NSString stringWithFormat:@"[Split / Fake It] %@ (Tone centered at 1500 Hz, VFO shifted via CAT)",
                              self.audioEngine.splitFakeItEnabled ? @"ENABLED" : @"DISABLED"]];
}

#pragma mark - Waterfall DSP & Palette Controls

- (void)paletteChanged:(id)sender {
    (void)sender;
    NSInteger idx = self.palettePopup.indexOfSelectedItem;
    if (idx >= 0 && idx < (NSInteger)[TX500FT8WaterfallView paletteNames].count) {
        self.waterfallView.palette = (TX500FT8Palette)idx;
        [[NSUserDefaults standardUserDefaults] setInteger:idx forKey:@"TX500_FT8_WaterfallPalette"];
        [[NSUserDefaults standardUserDefaults] synchronize];
    }
}

- (void)gainSliderChanged:(id)sender {
    (void)sender;
    self.waterfallView.gain = self.gainSlider.floatValue;
    [[NSUserDefaults standardUserDefaults] setFloat:self.gainSlider.floatValue forKey:@"TX500_FT8_WaterfallGain"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)contrastSliderChanged:(id)sender {
    (void)sender;
    self.waterfallView.contrastFloor = self.contrastSlider.floatValue;
    [[NSUserDefaults standardUserDefaults] setFloat:self.contrastSlider.floatValue forKey:@"TX500_FT8_WaterfallContrast"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)toggleCallsignTags:(id)sender {
    (void)sender;
    BOOL enabled = (self.callsignTagsCheckbox.state == NSControlStateValueOn);
    self.waterfallView.showCallsignTags = enabled;
    [self.waterfallView setNeedsDisplay:YES];
}

- (void)toggleWaterfallCollapse:(id)sender {
    (void)sender;
    self.isWaterfallCollapsed = !self.isWaterfallCollapsed;
    if (self.isWaterfallCollapsed) {
        self.slotProgressView.hidden = YES;
        self.waterfallView.hidden = YES;
        [NSLayoutConstraint deactivateConstraints:@[self.panadapterExpandedBottomConstraint]];
        [NSLayoutConstraint activateConstraints:@[self.panadapterCollapsedBottomConstraint]];
        self.collapseWaterfallButton.title = @"▾ Show WF";
    } else {
        self.slotProgressView.hidden = NO;
        self.waterfallView.hidden = NO;
        [NSLayoutConstraint deactivateConstraints:@[self.panadapterCollapsedBottomConstraint]];
        [NSLayoutConstraint activateConstraints:@[self.panadapterExpandedBottomConstraint]];
        self.collapseWaterfallButton.title = @"− Hide WF";
    }
    [self.view layoutSubtreeIfNeeded];
}

#pragma mark - PSKReporter Spot Broadcasting

- (void)togglePSKReporter:(id)sender {
    (void)sender;
    self.pskReporterEnabled = (self.pskReporterCheckbox.state == NSControlStateValueOn);
    TX500PSKReporter.sharedReporter.enabled=self.pskReporterEnabled;
    [[NSUserDefaults standardUserDefaults] setBool:self.pskReporterEnabled forKey:@"TX500_FT8_PSKReporterEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self appendToQSOConsole:[NSString stringWithFormat:@"[PSKReporter] Spotting to pskreporter.info %@",
                              self.pskReporterEnabled ? @"ENABLED" : @"DISABLED"]];
}

- (void)sendPSKReporterSpots:(NSArray<TX500FT8Message *> *)messages {
    if(!self.pskReporterEnabled || self.audioEngine.isSimulationMode) return;
    NSDictionary *receiver=@{@"call":self.audioEngine.myCallsign ?: @"",@"grid":self.audioEngine.myGrid ?: @"",@"antenna":[NSUserDefaults.standardUserDefaults stringForKey:@"TX500_StationAntenna"] ?: @""};
    uint64_t dial=self.audioEngine.dialFrequencyHz;
    NSString *mode=self.protocol==TX500_FT8_PROTOCOL_FT4 ? @"FT4" : @"FT8";
    for(TX500FT8Message *m in messages) {
        if(!isfinite(m.freqHz) || m.freqHz<0 || m.freqHz>12000 || m.isCycleSeparator) continue;
        NSDictionary *spot=@{@"call":m.callerCall ?: @"",@"grid":m.grid ?: @"",@"hz":@(dial+(uint64_t)llround(m.freqHz)),@"mode":mode,@"time":@((uint32_t)(m.timestamp ?: NSDate.date).timeIntervalSince1970)};
        [TX500PSKReporter.sharedReporter enqueue:spot receiver:receiver];
    }
}

#pragma mark - Keyboard Shortcuts (Space, F1..F6, Esc)

- (void)setupKeyboardShortcuts {
    __weak typeof(self) weakSelf = self;
    _keyEventMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.view.hidden || !strongSelf.view.window || !strongSelf.view.window.isKeyWindow || strongSelf.view.window.attachedSheet) {
            return event;
        }

        // Check if actively typing in an editable text field
        id firstResponder = strongSelf.view.window.firstResponder;
        BOOL isEditingText = [firstResponder isKindOfClass:[NSTextView class]] && [(NSTextView *)firstResponder isFieldEditor];

        // Esc (keyCode 53): Abort QSO / Halt TX immediately
        if (event.keyCode == 53) {
            [strongSelf abortClicked:nil];
            return nil;
        }

        if (isEditingText) {
            return event;
        }

        // Space (keyCode 49): Answer latest CQ or toggle Auto-CQ
        if (event.keyCode == 49) {
            [strongSelf answerLatestCQ];
            return nil;
        }

        // F1..F6 function keys
        NSInteger txStep = 0;
        switch (event.keyCode) {
            case 122: txStep = 1; break; // F1
            case 120: txStep = 2; break; // F2
            case 99:  txStep = 3; break; // F3
            case 118: txStep = 4; break; // F4
            case 96:  txStep = 5; break; // F5
            case 97:  txStep = 6; break; // F6
            default: break;
        }
        if (txStep >= 1 && txStep <= 6) {
            [strongSelf triggerTxStep:txStep];
            return nil;
        }

        return event;
    }];
}

- (void)answerLatestCQ {
    for (TX500FT8Message *m in self.filteredDecodes) {
        if (m.isCQ && m.callerCall.length > 0) {
            self.dxCallField.stringValue = m.callerCall;
            self.dxGridField.stringValue = m.grid ?: @"";
            [self dxCallEdited:nil];
            [self.autoEngine engageStation:m];
            [self appendToQSOConsole:[NSString stringWithFormat:@"[Shortcut Space] Engaging CQ from %@", m.callerCall]];
            return;
        }
    }
    [self toggleAutoCQ:nil];
}

- (void)triggerTxStep:(NSInteger)step {
    if (step >= 1 && step <= (NSInteger)self.txMessageButtons.count) {
        NSButton *btn = self.txMessageButtons[step - 1];
        [self txMatrixButtonClicked:btn];
        [self appendToQSOConsole:[NSString stringWithFormat:@"[Shortcut F%ld] Tx %ld Queued", (long)step, (long)step]];
    }
}

#pragma mark - Station History (Worked Calls / Grids / Countries)

- (void)loadWorkedStationHistory {
    NSArray *calls = [[NSUserDefaults standardUserDefaults] arrayForKey:@"TX500_FT8_WorkedCalls"];
    self.workedCallsigns = [NSMutableSet setWithArray:calls ?: @[]];

    NSArray *grids = [[NSUserDefaults standardUserDefaults] arrayForKey:@"TX500_FT8_WorkedGrids"];
    self.workedGrids = [NSMutableSet setWithArray:grids ?: @[]];

    NSArray *countries = [[NSUserDefaults standardUserDefaults] arrayForKey:@"TX500_FT8_WorkedCountries"];
    self.workedCountries = [NSMutableSet setWithArray:countries ?: @[]];
}

- (void)saveWorkedStationHistory {
    [[NSUserDefaults standardUserDefaults] setObject:[self.workedCallsigns allObjects] forKey:@"TX500_FT8_WorkedCalls"];
    [[NSUserDefaults standardUserDefaults] setObject:[self.workedGrids allObjects] forKey:@"TX500_FT8_WorkedGrids"];
    [[NSUserDefaults standardUserDefaults] setObject:[self.workedCountries allObjects] forKey:@"TX500_FT8_WorkedCountries"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - QRZ.com / HamQTH Right-Click Context Menu

- (void)setupTableContextMenu:(NSTableView *)table {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"DX Actions"];

    NSMenuItem *qrzItem = [[NSMenuItem alloc] initWithTitle:@"Look up on QRZ.com" action:@selector(lookupQRZFromMenu:) keyEquivalent:@""];
    qrzItem.target = self;
    [menu addItem:qrzItem];

    NSMenuItem *hamqthItem = [[NSMenuItem alloc] initWithTitle:@"Look up on HamQTH" action:@selector(lookupHamQTHFromMenu:) keyEquivalent:@""];
    hamqthItem.target = self;
    [menu addItem:hamqthItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *engageItem = [[NSMenuItem alloc] initWithTitle:@"Engage Station (Call)" action:@selector(engageFromMenu:) keyEquivalent:@""];
    engageItem.target = self;
    [menu addItem:engageItem];

    table.menu = menu;
}

- (TX500FT8Message *)messageForMenuAction:(id)sender {
    (void)sender;
    if (self.bandActivityTableView.clickedRow >= 0 && self.bandActivityTableView.clickedRow < (NSInteger)self.filteredDecodes.count) {
        return self.filteredDecodes[self.bandActivityTableView.clickedRow];
    }
    if (self.rxFreqTableView.clickedRow >= 0 && self.rxFreqTableView.clickedRow < (NSInteger)self.rxFreqDecodes.count) {
        return self.rxFreqDecodes[self.rxFreqTableView.clickedRow];
    }
    if (self.bandActivityTableView.selectedRow >= 0 && self.bandActivityTableView.selectedRow < (NSInteger)self.filteredDecodes.count) {
        return self.filteredDecodes[self.bandActivityTableView.selectedRow];
    }
    if (self.rxFreqTableView.selectedRow >= 0 && self.rxFreqTableView.selectedRow < (NSInteger)self.rxFreqDecodes.count) {
        return self.rxFreqDecodes[self.rxFreqTableView.selectedRow];
    }
    return nil;
}

- (void)lookupQRZFromMenu:(id)sender {
    TX500FT8Message *m = [self messageForMenuAction:sender];
    NSString *call = m.callerCall ?: self.dxCallField.stringValue;
    if (call.length > 0) {
        NSString *urlStr = [NSString stringWithFormat:@"https://www.qrz.com/db/%@", [call stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlStr]];
    }
}

- (void)lookupHamQTHFromMenu:(id)sender {
    TX500FT8Message *m = [self messageForMenuAction:sender];
    NSString *call = m.callerCall ?: self.dxCallField.stringValue;
    if (call.length > 0) {
        NSString *urlStr = [NSString stringWithFormat:@"https://www.hamqth.com/%@", [call stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]]];
        [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:urlStr]];
    }
}

- (void)engageFromMenu:(id)sender {
    TX500FT8Message *m = [self messageForMenuAction:sender];
    if (m) {
        self.dxCallField.stringValue = m.callerCall ?: @"";
        self.dxGridField.stringValue = m.grid ?: @"";
        [self dxCallEdited:nil];
        [self.autoEngine engageStation:m];
    }
}

#pragma mark - QSO Auto-Logging Dialog / Sheet

- (void)promptAutoLogQSO:(TX500FT8LoggedQSO *)qso {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"Log QSO: %@", qso.callsign ?: @"-"];
        alert.informativeText = @"Confirm or adjust contact parameters for the ADIF logbook:";
        alert.alertStyle = NSAlertStyleInformational;
        [alert addButtonWithTitle:@"Log QSO"];
        [alert addButtonWithTitle:@"Discard"];

        NSView *acc = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 360, 140)];

        NSTextField *callLbl = [NSTextField labelWithString:@"Call:"];
        callLbl.frame = NSMakeRect(0, 112, 40, 18);
        NSTextField *callField = [[NSTextField alloc] initWithFrame:NSMakeRect(45, 110, 110, 22)];
        callField.stringValue = qso.callsign ?: @"";

        NSTextField *gridLbl = [NSTextField labelWithString:@"Grid:"];
        gridLbl.frame = NSMakeRect(175, 112, 40, 18);
        NSTextField *gridField = [[NSTextField alloc] initWithFrame:NSMakeRect(220, 110, 90, 22)];
        gridField.stringValue = qso.grid ?: @"";

        NSTextField *rstSentLbl = [NSTextField labelWithString:@"Sent:"];
        rstSentLbl.frame = NSMakeRect(0, 82, 40, 18);
        NSTextField *rstSentField = [[NSTextField alloc] initWithFrame:NSMakeRect(45, 80, 80, 22)];
        rstSentField.stringValue = qso.rstSent ?: @"-10";

        NSTextField *rstRcvdLbl = [NSTextField labelWithString:@"Rcvd:"];
        rstRcvdLbl.frame = NSMakeRect(175, 82, 40, 18);
        NSTextField *rstRcvdField = [[NSTextField alloc] initWithFrame:NSMakeRect(220, 80, 80, 22)];
        rstRcvdField.stringValue = qso.rstRcvd ?: @"-10";

        NSTextField *bandLbl = [NSTextField labelWithString:@"Band:"];
        bandLbl.frame = NSMakeRect(0, 52, 40, 18);
        NSTextField *bandField = [[NSTextField alloc] initWithFrame:NSMakeRect(45, 50, 80, 22)];
        bandField.stringValue = qso.band ?: @"20m";

        NSTextField *pwrLbl = [NSTextField labelWithString:@"Power:"];
        pwrLbl.frame = NSMakeRect(175, 52, 40, 18);
        NSTextField *pwrField = [[NSTextField alloc] initWithFrame:NSMakeRect(220, 50, 80, 22)];
        pwrField.stringValue = @"10 W";

        NSTextField *commLbl = [NSTextField labelWithString:@"Comment:"];
        commLbl.frame = NSMakeRect(0, 22, 60, 18);
        NSTextField *commField = [[NSTextField alloc] initWithFrame:NSMakeRect(65, 20, 280, 22)];
        commField.stringValue = @"Lab599 Discovery TX-500 Portable";

        [acc addSubview:callLbl]; [acc addSubview:callField];
        [acc addSubview:gridLbl]; [acc addSubview:gridField];
        [acc addSubview:rstSentLbl]; [acc addSubview:rstSentField];
        [acc addSubview:rstRcvdLbl]; [acc addSubview:rstRcvdField];
        [acc addSubview:bandLbl]; [acc addSubview:bandField];
        [acc addSubview:pwrLbl]; [acc addSubview:pwrField];
        [acc addSubview:commLbl]; [acc addSubview:commField];

        alert.accessoryView = acc;

        NSWindow *win = self.view.window;
        void (^completionHandler)(NSModalResponse) = ^(NSModalResponse res) {
            if (res == NSAlertFirstButtonReturn) {
                NSString *savedCall = callField.stringValue.uppercaseString;
                NSString *savedGrid = gridField.stringValue.uppercaseString;
                if (savedCall.length > 0) {
                    [self.workedCallsigns addObject:savedCall];
                }
                if (savedGrid.length >= 4) {
                    [self.workedGrids addObject:savedGrid];
                }
                [self saveWorkedStationHistory];
                [self appendToQSOConsole:[NSString stringWithFormat:@"★ QSO WITH %@ CONFIRMED & ARCHIVED TO ADIF LOGBOOK.", savedCall]];
                [self applyTableFilters];
            } else {
                [self appendToQSOConsole:[NSString stringWithFormat:@"[Log QSO] Entry for %@ discarded.", qso.callsign]];
            }
        };

        if (win) {
            [alert beginSheetModalForWindow:win completionHandler:completionHandler];
        } else {
            NSModalResponse res = [alert runModal];
            completionHandler(res);
        }
    });
}

- (void)openLogsFolderClicked:(id)sender {
    (void)sender;
    NSString *path = [TX500FT8AudioEngine allDecodesADIFPath];
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
}

- (void)dxCallEdited:(id)sender {
    (void)sender;
    NSString *dx = [self.dxCallField.stringValue uppercaseString];
    if (dx.length > 0) {
        NSString *cntry = [TX500FT8Message countryNameForCallsign:dx];
        NSString *flag = [TX500FT8Message countryFlagForCallsign:dx];
        self.dxInfoLabel.stringValue = [NSString stringWithFormat:@"DX: %@ %@ %@", flag, dx, cntry];
        [self updateTransmitMatrixLabels];
    }
}

- (void)txMatrixButtonClicked:(NSButton *)sender {
    NSInteger phase = sender.tag;
    if (phase >= 1 && phase <= 6) {
        NSString *msg = self.txMessageLabels[phase - 1].stringValue;
        if (msg.length > 0 && ![msg isEqualToString:@"-"]) {
            [self.audioEngine armTransmitWithText:msg parity:TX500FT8SlotParityAuto];
            self.armTxButton.title = @"ARMED (TX)";
            self.armTxButton.bezelColor = [NSColor colorWithCalibratedRed:0.8 green:0.2 blue:0.2 alpha:1.0];
            if (phase == 6) {
                [self.autoEngine setCallingCQState:YES];
            }
        }
    }
}

- (void)nextStepClicked:(id)sender {
    (void)sender;
    [self.autoEngine advanceToNextQSOStep];
}

- (void)abortClicked:(id)sender {
    (void)sender;
    [self.autoEngine abortQSO];
    [self.audioEngine disarmTransmit];
    self.armTxButton.title = @"ENABLE TX";
    self.armTxButton.bezelColor = nil;
}

- (void)updateTransmitMatrixLabels {
    NSString *myCall = self.myCallField.stringValue.uppercaseString;
    NSString *myGrid = self.myGridField.stringValue.uppercaseString;
    NSString *dxCall = self.dxCallField.stringValue.uppercaseString;
    NSString *dxGrid = self.dxGridField.stringValue.uppercaseString;
    if (dxCall.length == 0 && self.autoEngine.activeDXCall.length > 0) {
        dxCall = self.autoEngine.activeDXCall.uppercaseString;
    }
    if (dxGrid.length == 0 && self.autoEngine.activeDXGrid.length > 0) {
        dxGrid = self.autoEngine.activeDXGrid.uppercaseString;
    }
    NSString *sentRpt = self.autoEngine.sentReport ?: @"-10";
    NSString *rcvdRpt = self.autoEngine.rcvdReport ?: @"-10";

    for (int i = 1; i <= 6; i++) {
        NSString *msg = [TX500FT8Message messageForPhase:i myCall:myCall myGrid:myGrid dxCall:dxCall dxGrid:dxGrid myReport:sentRpt rcvdReport:rcvdRpt];
        self.txMessageLabels[i - 1].stringValue = msg;
    }
}

- (void)updateAudioDeviceMenus {
    [self.audioInPopup removeAllItems];
    NSMenu *menu = self.audioInPopup.menu;
    [menu removeAllItems];

    NSArray<NSDictionary<NSString *, NSString *> *> *devices = self.audioEngine.inputDevices;
    if (devices.count == 0) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:@"Default Audio In" action:nil keyEquivalent:@""];
        item.representedObject = @"default";
        [menu addItem:item];
        [self.audioInPopup selectItem:item];
        return;
    }

    NSMenuItem *selectedItem = nil;
    BOOL hasUSBGroup = NO, hasOtherGroup = NO;

    for (NSDictionary *dev in devices) {
        NSString *title = dev[@"displayName"] ?: dev[@"name"];
        NSString *uid = dev[@"uid"];
        BOOL isUSB = [dev[@"isUSB"] isEqualToString:@"YES"] || [dev[@"isAD508"] isEqualToString:@"YES"];
        BOOL isVirtual = [dev[@"isVirtual"] isEqualToString:@"YES"];

        // Add a separator before non-USB devices if we had USB devices
        if (hasUSBGroup && !isUSB && !hasOtherGroup) {
            [menu addItem:[NSMenuItem separatorItem]];
            hasOtherGroup = YES;
        }
        if (isUSB) hasUSBGroup = YES;

        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:@selector(audioDeviceSelected:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = uid;

        if (isUSB) {
            item.toolTip = @"Physical USB Audio Interface connected to Lab599 Discovery TX-500 / AD-508";
        } else if (isVirtual) {
            item.toolTip = @"Virtual loopback audio driver (not connected to physical radio)";
        }

        [menu addItem:item];

        if (self.audioEngine.selectedInputDeviceUID && [uid isEqualToString:self.audioEngine.selectedInputDeviceUID]) {
            selectedItem = item;
        }
    }

    // Add separator and manual Refresh option
    [menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"🔄 Refresh Audio Devices..." action:@selector(refreshAudioDevicesClicked:) keyEquivalent:@""];
    refreshItem.target = self;
    refreshItem.representedObject = @"__REFRESH__";
    [menu addItem:refreshItem];

    if (selectedItem) {
        [self.audioInPopup selectItem:selectedItem];
    } else if (menu.itemArray.count > 0) {
        NSMenuItem *firstReal = menu.itemArray.firstObject;
        [self.audioInPopup selectItem:firstReal];
        if (firstReal.representedObject && ![firstReal.representedObject isEqualToString:@"__REFRESH__"]) {
            self.audioEngine.selectedInputDeviceUID = firstReal.representedObject;
        }
    }
}

- (void)audioDeviceSelected:(id)sender {
    (void)sender;
    NSMenuItem *item = self.audioInPopup.selectedItem;
    if (!item) return;

    NSString *uid = item.representedObject;
    if ([uid isEqualToString:@"__REFRESH__"]) {
        [self refreshAudioDevicesClicked:sender];
        return;
    }

    if (uid && uid.length > 0) {
        self.audioEngine.selectedInputDeviceUID = uid;

        // Automatically match corresponding output device if AD-508 / USB Audio
        for (NSDictionary *outDev in self.audioEngine.outputDevices) {
            if ([outDev[@"uid"] isEqualToString:uid] ||
                ([outDev[@"name"] isEqualToString:item.title] ||
                 ([outDev[@"isAD508"] isEqualToString:@"YES"] && [item.title containsString:@"AD-508"]) ||
                 ([outDev[@"isUSB"] isEqualToString:@"YES"] && [item.title containsString:@"USB"]))) {
                self.audioEngine.selectedOutputDeviceUID = outDev[@"uid"];
                break;
            }
        }
        [self.audioEngine restartAudioHardware];
    }
}

- (void)refreshAudioDevicesClicked:(id)sender {
    (void)sender;
    [self.audioEngine refreshAudioDevices];
    [self updateAudioDeviceMenus];
    [self appendToQSOConsole:@"[Audio Hardware] Audio devices refreshed. USB interfaces re-enumerated."];
}

- (void)refreshAudioTab {
    [self.audioEngine refreshAudioDevices];
    [self updateAudioDeviceMenus];
}

#pragma mark - Split View Controls & Delegate

- (void)toggleWideTables:(id)sender {
    (void)sender;
    self.isWideTables = !self.isWideTables;
    self.rightBox.hidden = self.isWideTables;
    self.wideTablesBtn.title = self.isWideTables ? @"⤡ Split View" : @"⤢ Wide View";
    self.wideTablesBtn.state = self.isWideTables ? NSControlStateValueOn : NSControlStateValueOff;
    [self.workstationSplitView adjustSubviews];
}

- (void)toggleFullHeight:(id)sender {
    (void)sender;
    self.isFullHeight = !self.isFullHeight;
    if (self.isFullHeight) {
        self.panadapterBox.hidden = YES;
        self.algoBox.hidden = YES;
        self.workstationTopToAlgoConstraint.active = NO;
        self.panadapterTopConstraint.active = NO;
        self.algoTopConstraint.active = NO;
        self.workstationTopToRibbonConstraint.active = YES;
        self.fullHeightBtn.title = @"⛶ Restore";
        self.fullHeightBtn.state = NSControlStateValueOn;
    } else {
        self.workstationTopToRibbonConstraint.active = NO;
        self.panadapterTopConstraint.active = YES;
        self.algoTopConstraint.active = YES;
        self.workstationTopToAlgoConstraint.active = YES;
        self.panadapterBox.hidden = NO;
        self.algoBox.hidden = NO;
        self.fullHeightBtn.title = @"⛶ Full Height";
        self.fullHeightBtn.state = NSControlStateValueOff;
    }
    [self.view layoutSubtreeIfNeeded];
}

#pragma mark - NSSplitViewDelegate

- (CGFloat)splitView:(NSSplitView *)splitView constrainMinCoordinate:(CGFloat)proposedMinimumPosition ofSubviewAt:(NSInteger)dividerIndex {
    if (splitView == self.tablesSplitView) {
        return 180.0;
    } else if (splitView == self.workstationSplitView) {
        return 320.0;
    }
    return proposedMinimumPosition;
}

- (CGFloat)splitView:(NSSplitView *)splitView constrainMaxCoordinate:(CGFloat)proposedMaximumPosition ofSubviewAt:(NSInteger)dividerIndex {
    if (splitView == self.tablesSplitView) {
        return splitView.bounds.size.width - 150.0;
    } else if (splitView == self.workstationSplitView) {
        return splitView.bounds.size.width - 220.0;
    }
    return proposedMaximumPosition;
}

- (BOOL)splitView:(NSSplitView *)splitView canCollapseSubview:(NSView *)subview {
    if (splitView == self.workstationSplitView && subview == self.rightBox) {
        return YES;
    }
    return NO;
}

- (BOOL)splitView:(NSSplitView *)splitView shouldCollapseSubview:(NSView *)subview forDoubleClickOnDividerAtIndex:(NSInteger)dividerIndex {
    if (splitView == self.workstationSplitView && subview == self.rightBox) {
        return YES;
    }
    return NO;
}

#pragma mark - Alert Management & DXCC Catalog

- (void)rebuildAlertCountryMenu {
    NSString *previouslySelectedTitle = self.alertCountryPopup.selectedItem.title;
    id previouslySelectedObj = self.alertCountryPopup.selectedItem.representedObject;
    [self.alertCountryPopup removeAllItems];

    // 1. Any Alert / New DXCC / New Grid items
    NSMenuItem *itemAll = [[NSMenuItem alloc] initWithTitle:@"All Countries (Alert Disabled)" action:NULL keyEquivalent:@""];
    itemAll.representedObject = @"__ALL_COUNTRIES__";
    [self.alertCountryPopup.menu addItem:itemAll];

    NSMenuItem *itemNewDXCC = [[NSMenuItem alloc] initWithTitle:@"Any New DXCC Entity 🌐" action:NULL keyEquivalent:@""];
    itemNewDXCC.representedObject = @"__ANY_NEW_DXCC__";
    [self.alertCountryPopup.menu addItem:itemNewDXCC];

    NSMenuItem *itemNewGrid = [[NSMenuItem alloc] initWithTitle:@"Any New Grid Locator 🎯" action:NULL keyEquivalent:@""];
    itemNewGrid.representedObject = @"__ANY_NEW_GRID__";
    [self.alertCountryPopup.menu addItem:itemNewGrid];

    [self.alertCountryPopup.menu addItem:[NSMenuItem separatorItem]];

    // 2. Custom Alerts Section
    NSMenuItem *itemAddCustom = [[NSMenuItem alloc] initWithTitle:@"➕ Add Custom Alert (Call / Prefix / Country)..." action:@selector(addCustomAlertClicked:) keyEquivalent:@""];
    itemAddCustom.target = self;
    [self.alertCountryPopup.menu addItem:itemAddCustom];

    NSArray<NSString *> *customAlerts = [[NSUserDefaults standardUserDefaults] objectForKey:@"TX500_FT8_CustomAlertList"];
    if (customAlerts.count > 0) {
        for (NSString *cust in customAlerts) {
            NSMenuItem *cItem = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"⭐ Custom: %@", cust] action:NULL keyEquivalent:@""];
            cItem.representedObject = cust;
            [self.alertCountryPopup.menu addItem:cItem];
        }
        NSMenuItem *itemClearCustom = [[NSMenuItem alloc] initWithTitle:@"🗑 Clear Custom Alerts..." action:@selector(clearCustomAlertsClicked:) keyEquivalent:@""];
        itemClearCustom.target = self;
        [self.alertCountryPopup.menu addItem:itemClearCustom];
    }

    [self.alertCountryPopup.menu addItem:[NSMenuItem separatorItem]];

    // 3. Complete World DXCC Entities List (Alphabetical)
    NSArray<NSDictionary<NSString *, NSString *> *> *entities = [TX500FT8Message allDXCCEntities];
    for (NSDictionary<NSString *, NSString *> *e in entities) {
        NSString *cName = e[@"country"];
        NSString *flag = e[@"flag"];
        NSString *title = [NSString stringWithFormat:@"%@ %@", cName, flag];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:NULL keyEquivalent:@""];
        item.representedObject = cName;
        [self.alertCountryPopup.menu addItem:item];
    }

    // Restore prior selection
    BOOL restored = NO;
    if (previouslySelectedObj) {
        for (NSMenuItem *it in self.alertCountryPopup.itemArray) {
            if ([it.representedObject isEqual:previouslySelectedObj]) {
                [self.alertCountryPopup selectItem:it];
                restored = YES;
                break;
            }
        }
    }
    if (!restored && previouslySelectedTitle) {
        for (NSMenuItem *it in self.alertCountryPopup.itemArray) {
            if ([it.title isEqualToString:previouslySelectedTitle]) {
                [self.alertCountryPopup selectItem:it];
                restored = YES;
                break;
            }
        }
    }
    if (!restored) {
        // Default to Iran 🇮🇷 if available, else first item
        for (NSMenuItem *it in self.alertCountryPopup.itemArray) {
            if ([it.representedObject isEqualToString:@"Iran"]) {
                [self.alertCountryPopup selectItem:it];
                restored = YES;
                break;
            }
        }
    }
    if (!restored && self.alertCountryPopup.numberOfItems > 0) {
        [self.alertCountryPopup selectItemAtIndex:0];
    }
}

- (void)promptAddCustomAlert {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Add Custom FT8 Alert";
    alert.informativeText = @"Enter any Callsign (e.g. EP2AES, W1AW), DXCC Prefix (e.g. 3B8, KH6, Z6), or Country Name to trigger alert when decoded:";
    [alert addButtonWithTitle:@"Add Alert"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
    input.placeholderString = @"e.g. EP2AES, 3B8, or Iceland";
    alert.accessoryView = input;

    NSModalResponse resp = [alert runModal];
    if (resp == NSAlertFirstButtonReturn) {
        NSString *val = [input.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (val.length > 0) {
            NSMutableArray *saved = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] objectForKey:@"TX500_FT8_CustomAlertList"] ?: @[]];
            if (![saved containsObject:val]) {
                [saved addObject:val];
                [[NSUserDefaults standardUserDefaults] setObject:saved forKey:@"TX500_FT8_CustomAlertList"];
                [[NSUserDefaults standardUserDefaults] synchronize];
            }
            [self rebuildAlertCountryMenu];
            for (NSMenuItem *it in self.alertCountryPopup.itemArray) {
                if ([it.representedObject isEqualToString:val]) {
                    [self.alertCountryPopup selectItem:it];
                    break;
                }
            }
            self.alertEnabledCheckbox.state = NSControlStateValueOn;
            [self appendToQSOConsole:[NSString stringWithFormat:@"[FT8 Alert] Added and activated custom alert: '%@'", val]];
            [self applyTableFilters];
        }
    } else {
        if ([self.alertCountryPopup.selectedItem.title hasPrefix:@"➕ Add Custom Alert"]) {
            [self.alertCountryPopup selectItemAtIndex:0];
        }
    }
}

- (void)clearCustomAlerts {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TX500_FT8_CustomAlertList"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self rebuildAlertCountryMenu];
    [self appendToQSOConsole:@"[FT8 Alert] Cleared custom alerts list."];
    [self applyTableFilters];
}

- (void)addCustomAlertClicked:(id)sender {
    (void)sender;
    [self promptAddCustomAlert];
}

- (void)clearCustomAlertsClicked:(id)sender {
    (void)sender;
    [self clearCustomAlerts];
}

#pragma mark - Table View Data Source & Delegate

- (void)filterChanged:(id)sender {
    (void)sender;
    if ([self.alertCountryPopup.selectedItem.title hasPrefix:@"➕ Add Custom Alert"]) {
        [self promptAddCustomAlert];
        return;
    }
    if ([self.alertCountryPopup.selectedItem.title hasPrefix:@"🗑 Clear Custom Alerts"]) {
        [self clearCustomAlerts];
        return;
    }
    [self applyTableFilters];
}

- (void)searchChanged:(id)sender {
    (void)sender;
    [self applyTableFilters];
}

- (void)clearDecodesClicked:(id)sender {
    (void)sender;
    [self.allDecodes removeAllObjects];
    [self applyTableFilters];
}

- (void)checkAndTriggerAlertsForNewMessages:(NSArray<TX500FT8Message *> *)newMessages {
    if (!self.alertEnabledCheckbox || self.alertEnabledCheckbox.state != NSControlStateValueOn) return;
    if (newMessages.count == 0) return;

    NSMenuItem *selectedAlert = self.alertCountryPopup.selectedItem;
    id alertTarget = selectedAlert.representedObject;
    if (!alertTarget && selectedAlert.title.length > 0) {
        alertTarget = selectedAlert.title;
    }
    if (!alertTarget || [alertTarget isEqualToString:@"__ALL_COUNTRIES__"] || [alertTarget isEqualToString:@"None"]) {
        return;
    }

    BOOL didAlert = NO;
    for (TX500FT8Message *m in newMessages) {
        BOOL isMatch = NO;
        if ([alertTarget isEqualToString:@"__ANY_NEW_DXCC__"]) {
            isMatch = m.isNewDXCC && (m.callerCall.length > 0);
        } else if ([alertTarget isEqualToString:@"__ANY_NEW_GRID__"]) {
            isMatch = m.isNewGrid && (m.grid.length >= 4);
        } else if ([alertTarget isKindOfClass:[NSString class]]) {
            NSString *targetStr = (NSString *)alertTarget;
            NSString *cleanTarget = [targetStr.uppercaseString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (cleanTarget.length > 0) {
                if (m.countryName.length > 0 && [m.countryName.uppercaseString containsString:cleanTarget]) {
                    isMatch = YES;
                } else if (m.callerCall.length > 0 && [m.callerCall.uppercaseString hasPrefix:cleanTarget]) {
                    isMatch = YES;
                } else if (m.callerCall.length > 0 && [m.callerCall.uppercaseString isEqualToString:cleanTarget]) {
                    isMatch = YES;
                } else if (m.grid.length > 0 && [m.grid.uppercaseString hasPrefix:cleanTarget]) {
                    isMatch = YES;
                } else if (m.rawText.length > 0 && [m.rawText.uppercaseString containsString:cleanTarget]) {
                    isMatch = YES;
                }
            }
        }

        if (isMatch) {
            m.isAlertMatch = YES;
            if (!didAlert) {
                didAlert = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                NSUserNotification *notif = [[NSUserNotification alloc] init];
                notif.title = @"FT8 Alert — Station Heard!";
                notif.informativeText = [NSString stringWithFormat:@"%@ (%@ %@) — %+.0f dB on %ld Hz",
                                         m.callerCall ?: @"?", m.countryName ?: @"",
                                         m.countryFlag ?: @"", m.snrDb, (long)roundf(m.freqHz)];
                notif.soundName = NSUserNotificationDefaultSoundName;
                [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notif];
#pragma clang diagnostic pop
                [[NSSound soundNamed:@"Hero"] play];
            }
            [self appendToQSOConsole:[NSString stringWithFormat:@"🚨 ALERT: Heard %@ (%@ %@) %+.0f dB on %ld Hz",
                                      m.callerCall ?: @"?", m.countryName ?: @"", m.countryFlag ?: @"", m.snrDb, (long)roundf(m.freqHz)]];
        }
    }
}

- (void)applyTableFilters {
    [self.filteredDecodes removeAllObjects];
    [self.rxFreqDecodes removeAllObjects];

    NSInteger seg = self.tableFilterSegment.selectedSegment;
    NSString *query = self.searchField.stringValue.uppercaseString;
    float rxFreq = self.audioEngine.rxAudioFrequencyHz;
    NSString *dxCall = self.dxCallField.stringValue.uppercaseString;

    // SNR range filter
    float snrMin = -30.0f, snrMax = 30.0f;
    if (self.snrMinField && self.snrMinField.stringValue.length > 0) {
        snrMin = [self.snrMinField.stringValue floatValue];
    }
    if (self.snrMaxField && self.snrMaxField.stringValue.length > 0) {
        snrMax = [self.snrMaxField.stringValue floatValue];
    }
    BOOL hasSNRFilter = (self.snrMinField && self.snrMinField.stringValue.length > 0) ||
                        (self.snrMaxField && self.snrMaxField.stringValue.length > 0);

    // Alert settings
    BOOL alertActive = (self.alertEnabledCheckbox && self.alertEnabledCheckbox.state == NSControlStateValueOn);
    NSMenuItem *selectedAlert = self.alertCountryPopup.selectedItem;
    id alertTarget = selectedAlert.representedObject;
    if (!alertTarget && selectedAlert.title.length > 0) {
        alertTarget = selectedAlert.title;
    }
    if ([alertTarget isEqualToString:@"__ALL_COUNTRIES__"]) {
        alertActive = NO;
    }

    for (TX500FT8Message *m in self.allDecodes) {
        // Cycle separator sentinels are always visible in the Band Activity table
        if (m.isCycleSeparator) {
            [self.filteredDecodes addObject:m];
            continue; // Skip normal filter logic; separators never go in rxFreqDecodes
        }

        // Tag worked / new status dynamically
        m.isWorkedBefore = (m.callerCall.length > 0 && [self.workedCallsigns containsObject:m.callerCall]);
        m.isNewGrid = (m.grid.length >= 4 && ![self.workedGrids containsObject:m.grid]);
        m.isNewDXCC = (m.countryName.length > 0 && ![self.workedCountries containsObject:m.countryName]);

        // Band Activity Filters
        BOOL passesBand = YES;
        if (seg == 1 && !m.isCQ) passesBand = NO;
        if (seg == 2 && !m.isDirectedToMe) passesBand = NO;
        if (hasSNRFilter && (m.snrDb < snrMin || m.snrDb > snrMax)) passesBand = NO;
        if (query.length > 0 && ![m.rawText.uppercaseString containsString:query] &&
            ![m.countryName.uppercaseString containsString:query] &&
            !([m.callerCall uppercaseString] && [m.callerCall.uppercaseString containsString:query])) {
            passesBand = NO;
        }
        if (passesBand) {
            [self.filteredDecodes addObject:m];
        }


        // Rx Frequency Filter (±60 Hz, or matching DX Call, or Directed to me)
        BOOL matchesRxFreq = (fabs(m.freqHz - rxFreq) <= 60.0);
        BOOL matchesDXCall = (dxCall.length > 0 && ([m.callerCall isEqualToString:dxCall] || [m.targetCall isEqualToString:dxCall]));
        if (matchesRxFreq || matchesDXCall || m.isDirectedToMe) {
            [self.rxFreqDecodes addObject:m];
        }

        // Check alerts
        BOOL isMatch = NO;
        if (alertActive && alertTarget) {
            if ([alertTarget isEqualToString:@"__ANY_NEW_DXCC__"]) {
                isMatch = m.isNewDXCC && (m.callerCall.length > 0);
            } else if ([alertTarget isEqualToString:@"__ANY_NEW_GRID__"]) {
                isMatch = m.isNewGrid && (m.grid.length >= 4);
            } else if ([alertTarget isKindOfClass:[NSString class]]) {
                NSString *targetStr = (NSString *)alertTarget;
                NSString *cleanTarget = [targetStr.uppercaseString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if (cleanTarget.length > 0) {
                    if (m.countryName.length > 0 && [m.countryName.uppercaseString containsString:cleanTarget]) {
                        isMatch = YES;
                    } else if (m.callerCall.length > 0 && [m.callerCall.uppercaseString hasPrefix:cleanTarget]) {
                        isMatch = YES;
                    } else if (m.callerCall.length > 0 && [m.callerCall.uppercaseString isEqualToString:cleanTarget]) {
                        isMatch = YES;
                    } else if (m.grid.length > 0 && [m.grid.uppercaseString hasPrefix:cleanTarget]) {
                        isMatch = YES;
                    } else if (m.rawText.length > 0 && [m.rawText.uppercaseString containsString:cleanTarget]) {
                        isMatch = YES;
                    }
                }
            }
        }

        m.isAlertMatch = isMatch;
    }
    [self.bandActivityTableView reloadData];
    [self.rxFreqTableView reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.rxFreqTableView) {
        return self.rxFreqDecodes.count;
    }
    return self.filteredDecodes.count;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    static NSString *const kRowIdent = @"FT8TableRowView";
    FT8TableRowView *rowView = [tableView makeViewWithIdentifier:kRowIdent owner:self];
    if (!rowView) {
        rowView = [[FT8TableRowView alloc] initWithFrame:NSZeroRect];
        rowView.identifier = kRowIdent;
    }
    NSArray<TX500FT8Message *> *list = (tableView == self.rxFreqTableView) ? self.rxFreqDecodes : self.filteredDecodes;
    if (row >= 0 && row < (NSInteger)list.count) {
        TX500FT8Message *m = list[row];
        rowView.slotParity = m.slotParity;
        rowView.isDirectedToMe = m.isDirectedToMe;
        rowView.isMyTransmission = m.isMyTransmission;
        rowView.isAlertMatch = m.isAlertMatch;
        rowView.isCycleSeparator = m.isCycleSeparator;
    }
    return rowView;

}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    NSArray<TX500FT8Message *> *list = (tableView == self.rxFreqTableView) ? self.rxFreqDecodes : self.filteredDecodes;
    if (row < 0 || row >= (NSInteger)list.count) return nil;
    TX500FT8Message *m = list[row];
    NSString *ident = tableColumn.identifier;

    FT8TableCellView *cellView = [tableView makeViewWithIdentifier:ident owner:self];
    if (!cellView) {
        cellView = [[FT8TableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 22.0)];
        cellView.identifier = ident;

        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightMedium];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        cellView.textField = tf;
        [cellView addSubview:tf];

        [NSLayoutConstraint activateConstraints:@[
            [tf.centerYAnchor constraintEqualToAnchor:cellView.centerYAnchor],
            [tf.leadingAnchor constraintEqualToAnchor:cellView.leadingAnchor constant:4],
            [tf.trailingAnchor constraintEqualToAnchor:cellView.trailingAnchor constant:-4]
        ]];
    }

    NSTextField *tf = cellView.textField;

    // ── Cycle separator sentinel row ──────────────────────────────────────
    if (m.isCycleSeparator) {
        tf.stringValue = @"";
        if ([ident isEqualToString:kColMsg] || [ident isEqualToString:kColTime]) {
            // Render the full cycle label only in the Message column (wide)
            if ([ident isEqualToString:kColMsg]) {
                tf.stringValue = m.rawText ?: @"";
                tf.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightBold];
                tf.textColor = [NSColor colorWithCalibratedRed:0.08 green:0.38 blue:0.72 alpha:0.85];
            }
        }
        return cellView;
    }

    // ── Normal decoded row ────────────────────────────────────────────────
    if (m.isMyTransmission) {
        tf.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightBold];
    } else {
        tf.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightMedium];
    }

    // Intelligent JTDX / WSJT-X Semantic Color Coding
    NSColor *fgColor = [NSColor labelColor];
    if ([tableView isRowSelected:row]) {
        fgColor = [NSColor alternateSelectedControlTextColor];
    } else if (m.isAlertMatch) {
        fgColor = [NSColor colorWithCalibratedRed:0.85 green:0.0 blue:0.40 alpha:1.0]; // Bright Alert Crimson/Magenta
    } else if (m.isDirectedToMe) {
        fgColor = [NSColor colorWithCalibratedRed:0.90 green:0.25 blue:0.0 alpha:1.0]; // Bright Orange/Red (To Me)
    } else if (m.isMyTransmission) {
        fgColor = [NSColor colorWithCalibratedRed:0.85 green:0.15 blue:0.15 alpha:1.0]; // Deep Red (My TX)
    } else if (m.isCQ) {
        if (m.isNewDXCC) {
            fgColor = [NSColor colorWithCalibratedRed:0.55 green:0.10 blue:0.75 alpha:1.0]; // Royal Purple (New DXCC)
        } else if (m.isNewGrid) {
            fgColor = [NSColor colorWithCalibratedRed:0.78 green:0.45 blue:0.0 alpha:1.0]; // Golden Amber (New Grid)
        } else if (m.isWorkedBefore) {
            fgColor = [NSColor secondaryLabelColor]; // Subtle Gray (Worked Before)
        } else {
            fgColor = [NSColor colorWithCalibratedRed:0.0 green:0.55 blue:0.25 alpha:1.0]; // Tactical Emerald Green (Standard CQ)
        }
    }
    tf.textColor = fgColor;

    // Time formatters: LOCAL for table display, UTC for ADIF logs (unchanged)
    static NSDateFormatter *s_localFormatter = nil;
    static dispatch_once_t s_onceToken;
    dispatch_once(&s_onceToken, ^{
        s_localFormatter = [[NSDateFormatter alloc] init];
        // Local timezone — operator sees their wall-clock time in the band-activity table
        s_localFormatter.timeZone = [NSTimeZone localTimeZone];
        s_localFormatter.dateFormat = @"HH:mm:ss";
    });

    if ([ident isEqualToString:kColTime]) {
        tf.stringValue = [s_localFormatter stringFromDate:m.timestamp];
    } else if ([ident isEqualToString:kColSNR]) {
        if (m.isMyTransmission) {
            tf.stringValue = @"● TX";
        } else {
            tf.stringValue = [NSString stringWithFormat:@"%+d", (int)roundf(m.snrDb)];
        }
    } else if ([ident isEqualToString:kColDT]) {
        if (m.isMyTransmission) {
            tf.stringValue = @"—";
        } else {
            tf.stringValue = [NSString stringWithFormat:@"%+.1f", m.timeSec];
        }
    } else if ([ident isEqualToString:kColFreq]) {
        tf.stringValue = [NSString stringWithFormat:@"%.0f", m.freqHz];
    } else if ([ident isEqualToString:kColMsg]) {
        if (m.isMyTransmission) {
            tf.stringValue = [NSString stringWithFormat:@"▶ TX: %@", m.rawText];
        } else {
            tf.stringValue = m.rawText;
        }
    } else if ([ident isEqualToString:kColCountry]) {
        tf.stringValue = [NSString stringWithFormat:@"%@ %@", m.countryFlag ?: @"", m.countryName ?: @""];
    } else if ([ident isEqualToString:kColGrid]) {
        tf.stringValue = m.grid ?: @"-";
    } else if ([ident isEqualToString:kColDistance]) {
        tf.stringValue = (m.distanceKm >= 0) ? [NSString stringWithFormat:@"%.0f km", m.distanceKm] : @"-";
    }
    return cellView;
}


- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    (void)notification;
    [self.bandActivityTableView reloadData];
    [self.rxFreqTableView reloadData];
}

- (void)updateLiveCycleStatusBannerWithSlotSec:(double)slotSec parity:(NSInteger)parity {
    if (!self.cycleBannerBox) return;

    NSString *slotName;
    if (self.protocol == TX500_FT8_PROTOCOL_FT4) {
        slotName = (parity == 0) ? @"Even [:00/:15]" : @"Odd [:07/:22]";
    } else {
        slotName = (parity == 0) ? @"Even [:00/:30]" : @"Odd [:15/:45]";
    }

    double period = self.audioEngine.currentSlotPeriod;
    self.cycleClockLabel.stringValue = [NSString stringWithFormat:@"%4.1fs / %.0fs", slotSec, period];

    if (self.audioEngine.isTransmitting) {
        NSString *txText = self.audioEngine.queuedTxMessage;
        if (self.audioEngine.isSimulationMode) {
            self.cycleBadge.stringValue = [NSString stringWithFormat:@"⚠️ SIM TX %@", slotName];
            self.cycleBadge.textColor = [NSColor systemOrangeColor];
            self.cycleDetailLabel.stringValue = [NSString stringWithFormat:@"SIMULATED TX (No RF - Simulation Mode Active): %@",
                                                 txText.length > 0 ? txText : @"..."];
            self.cycleDetailLabel.textColor = [NSColor systemOrangeColor];
        } else {
            self.cycleBadge.stringValue = [NSString stringWithFormat:@"▲ TX %@", slotName];
            self.cycleBadge.textColor = [NSColor colorWithCalibratedRed:0.90 green:0.15 blue:0.15 alpha:1.0];
            if (txText.length > 0) {
                self.cycleDetailLabel.stringValue = [NSString stringWithFormat:@"TRANSMITTING (PTT Active): %@", txText];
            } else {
                self.cycleDetailLabel.stringValue = @"TRANSMITTING (PTT Active)...";
            }
            self.cycleDetailLabel.textColor = [NSColor colorWithCalibratedRed:0.85 green:0.10 blue:0.10 alpha:1.0];
        }
    } else {
        self.cycleBadge.stringValue = [NSString stringWithFormat:@"● RX %@", slotName];
        self.cycleBadge.textColor = [NSColor systemBlueColor];
        if (self.audioEngine.isTransmitArmed) {
            NSString *queued = self.audioEngine.queuedTxMessage;
            if (queued.length > 0) {
                self.cycleDetailLabel.stringValue = [NSString stringWithFormat:@"Listening · TX armed for next cycle: %@", queued];
            } else {
                self.cycleDetailLabel.stringValue = @"Listening · TX armed for next cycle";
            }
            self.cycleDetailLabel.textColor = [NSColor colorWithCalibratedRed:0.80 green:0.45 blue:0.0 alpha:1.0];
        } else {
            if (self.lastDecodesCount > 0) {
                self.cycleDetailLabel.stringValue = [NSString stringWithFormat:@"Listening · %lu decodes in previous cycle", (unsigned long)self.lastDecodesCount];
            } else {
                self.cycleDetailLabel.stringValue = @"Listening for digital signals...";
            }
            self.cycleDetailLabel.textColor = [NSColor secondaryLabelColor];
        }
    }
}

- (void)tableRowClicked:(id)sender {
    TX500FT8Message *target = nil;
    if (sender == self.rxFreqTableView) {
        NSInteger row = self.rxFreqTableView.selectedRow;
        if (row >= 0 && row < (NSInteger)self.rxFreqDecodes.count) {
            target = self.rxFreqDecodes[row];
        }
    } else {
        NSInteger row = self.bandActivityTableView.selectedRow;
        if (row >= 0 && row < (NSInteger)self.filteredDecodes.count) {
            target = self.filteredDecodes[row];
        }
    }
    if (!target || target.isMyTransmission) return;

    NSString *callToEngage = target.callerCall;
    if (callToEngage.length == 0) {
        callToEngage = target.targetCall;
    }
    if (callToEngage.length == 0) return;

    self.dxCallField.stringValue = callToEngage;
    self.dxGridField.stringValue = target.grid ?: @"";
    [self dxCallEdited:nil];

    // Align RX frequency to target frequency
    if (target.freqHz > 100.0f) {
        self.rxFreqField.stringValue = [NSString stringWithFormat:@"%.0f", target.freqHz];
        self.audioEngine.rxAudioFrequencyHz = target.freqHz;
        if (self.lockFreqsButton.state == NSControlStateValueOn) {
            self.txFreqField.stringValue = [NSString stringWithFormat:@"%.0f", target.freqHz];
            self.audioEngine.txAudioFrequencyHz = target.freqHz;
        }
    }

    // Set TX Parity to target's listening slot (alternate slot parity)
    // If target transmitted on Even (0), target listens on Odd (1) -> we must TX on Odd.
    // If target transmitted on Odd (1), target listens on Even (0) -> we must TX on Even.
    TX500FT8SlotParity listeningParity = (target.slotParity == 0) ? TX500FT8SlotParityOdd : TX500FT8SlotParityEven;
    self.audioEngine.txSlotParity = listeningParity;
    self.txParitySegment.selectedSegment = (listeningParity == TX500FT8SlotParityEven) ? 0 : 2;

    // Arm TX Message 1 as default response text
    if (self.txMessageLabels.count > 0) {
        NSString *msg1 = self.txMessageLabels[0].stringValue;
        if (msg1.length > 0 && ![msg1 isEqualToString:@"-"]) {
            self.audioEngine.queuedTxMessage = msg1;
        }
    }

    NSString *pName = (listeningParity == TX500FT8SlotParityEven) ? @"Even [:00/:30]" : @"Odd [:15/:45]";
    [self appendToQSOConsole:[NSString stringWithFormat:@"[QSO Ready] Target: %@ (%@) on %.0f Hz. Transmit scheduled on listening slot: %@",
                              callToEngage, target.grid ?: @"-", target.freqHz, pName]];
    [self updateLiveCycleStatusBannerWithSlotSec:self.audioEngine.currentSlotSecond parity:self.audioEngine.currentSlotParity];
}

- (void)tableRowDoubleClicked:(id)sender {
    TX500FT8Message *target = nil;
    if (sender == self.rxFreqTableView) {
        NSInteger row = self.rxFreqTableView.selectedRow;
        if (row >= 0 && row < (NSInteger)self.rxFreqDecodes.count) {
            target = self.rxFreqDecodes[row];
        }
    } else {
        NSInteger row = self.bandActivityTableView.selectedRow;
        if (row >= 0 && row < (NSInteger)self.filteredDecodes.count) {
            target = self.filteredDecodes[row];
        }
    }
    if (!target || target.isMyTransmission) return;

    // Single-click setup first (frequencies, callsign, alternate parity)
    [self tableRowClicked:sender];

    // Immediate auto-copilot engagement
    if (!self.audioEngine.isMonitoring) {
        [self startStation];
    }
    [self.autoEngine engageStation:target];
    self.armTxButton.state = NSControlStateValueOn;
    self.armTxButton.title = @"ARMED (TX)";
    self.armTxButton.bezelColor = [NSColor colorWithCalibratedRed:0.8 green:0.2 blue:0.2 alpha:1.0];
}

#pragma mark - QSO Console & ADIF Export

- (void)appendToQSOConsole:(NSString *)text {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    df.dateFormat = @"HH:mm:ss";
    NSString *timeStr = [NSString stringWithFormat:@"%@ ", [df stringFromDate:[NSDate date]]];
    NSString *msgStr = [NSString stringWithFormat:@"%@\n", text];

    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] init];
        [attr appendAttributedString:[[NSAttributedString alloc] initWithString:timeStr attributes:@{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
        }]];
        [attr appendAttributedString:[[NSAttributedString alloc] initWithString:msgStr attributes:@{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: [NSColor labelColor]
        }]];
        [self.qsoConsoleTextView.textStorage appendAttributedString:attr];
        [self.qsoConsoleTextView scrollRangeToVisible:NSMakeRange(self.qsoConsoleTextView.string.length, 0)];
    });
}

- (void)exportADIFClicked:(id)sender {
    (void)sender;
    NSString *adif = [self.autoEngine generateADIFExport];
    NSSavePanel *savePanel = [NSSavePanel savePanel];
    savePanel.title = @"Export FT8 ADIF Log";
    savePanel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"adi"]];
    savePanel.nameFieldStringValue = @"TX500_FT8_Log.adi";

    [savePanel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && savePanel.URL) {
            NSError *err = nil;
            [adif writeToURL:savePanel.URL atomically:YES encoding:NSUTF8StringEncoding error:&err];
            if (err && self.logHandler) {
                self.logHandler([NSString stringWithFormat:@"[ADIF Error] Failed to export: %@", err.localizedDescription]);
            } else if (self.logHandler) {
                self.logHandler([NSString stringWithFormat:@"[ADIF Export] Successfully saved log to %@", savePanel.URL.path]);
            }
        }
    }];
}

- (void)clearLogClicked:(id)sender {
    (void)sender;
    [self.autoEngine clearSessionLog];
    self.sessionLogCountLabel.stringValue = @"Session QSOs: 0";
}

@end
