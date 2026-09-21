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

@interface TX500FT8SlotProgressView : NSView
@property (nonatomic, assign) double slotSecond;
@property (nonatomic, assign) NSInteger parity;
@property (nonatomic, assign) BOOL isTransmitting;
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

    // Progress bar fill
    double fraction = fmin(1.0, fmax(0.0, self.slotSecond / 15.0));
    NSRect fillRect = NSMakeRect(0, 0, bounds.size.width * fraction, bounds.size.height);

    NSColor *barColor;
    if (self.isTransmitting) {
        barColor = [NSColor colorWithCalibratedRed:0.88 green:0.20 blue:0.20 alpha:0.90]; // Alert Red
    } else if (self.slotSecond >= 13.5) {
        barColor = [NSColor colorWithCalibratedRed:0.92 green:0.65 blue:0.10 alpha:0.92]; // Amber Gold
    } else {
        barColor = [NSColor colorWithCalibratedRed:0.12 green:0.68 blue:0.38 alpha:0.88]; // Tactical Emerald RX
    }

    [barColor setFill];
    NSRectFill(fillRect);

    // Boundary marker at 14.5s (TX end) and 13.5s (Decode start)
    CGFloat txEnd = (14.5 / 15.0) * bounds.size.width;
    [[NSColor separatorColor] setStroke];
    [NSBezierPath strokeLineFromPoint:NSMakePoint(txEnd, 0) toPoint:NSMakePoint(txEnd, bounds.size.height)];

    CGFloat decStart = (13.5 / 15.0) * bounds.size.width;
    [[NSColor colorWithCalibratedRed:0.85 green:0.55 blue:0.08 alpha:0.85] setStroke];
    [NSBezierPath strokeLineFromPoint:NSMakePoint(decStart, 0) toPoint:NSMakePoint(decStart, bounds.size.height)];

    // Inner bezel border
    [[NSColor separatorColor] setStroke];
    NSBezierPath *borderPath = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(bounds, 0.5, 0.5) xRadius:4.0 yRadius:4.0];
    borderPath.lineWidth = 1.0;
    [borderPath stroke];

    // Center text label with high contrast
    NSString *phaseStr = self.isTransmitting ? @"TX" : (self.slotSecond >= 13.5 ? @"DECODING" : @"RX");
    NSString *parityStr = (self.parity == 0) ? @"EVEN (:00/:30)" : @"ODD (:15/:45)";
    NSString *text = [NSString stringWithFormat:@"%@ · %.1fs / 15.0s · %@", phaseStr, self.slotSecond, parityStr];

    NSDictionary *attrs = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightBold],
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
@property (nonatomic, strong) NSPopUpButton *bandPopup;
@property (nonatomic, strong) NSTextField *dialFreqLabel;
@property (nonatomic, strong) NSPopUpButton *audioInPopup;
@property (nonatomic, strong) NSPopUpButton *audioOutPopup;
@property (nonatomic, strong) NSButton *simCheckbox;
@property (nonatomic, strong) NSTextField *rxFreqField;
@property (nonatomic, strong) NSTextField *txFreqField;
@property (nonatomic, strong) NSButton *lockFreqsButton;
@property (nonatomic, strong) NSButton *armTxButton;
@property (nonatomic, strong) NSButton *tuneButton;
@property (nonatomic, strong) TX500FT8SlotProgressView *slotProgressView;

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

// UI Components - Main Dual Workstation
@property (nonatomic, strong) NSSegmentedControl *tableFilterSegment;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSTableView *activityTableView;
@property (nonatomic, strong) NSMutableArray<TX500FT8Message *> *allDecodes;
@property (nonatomic, strong) NSMutableArray<TX500FT8Message *> *filteredDecodes;
@property (nonatomic, strong) NSButton *timeModeButton;

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

@end

@interface FT8TableCellView : NSTableCellView
@end

@implementation FT8TableCellView
@end

@interface FT8TableRowView : NSTableRowView
@property (nonatomic, assign) NSInteger slotParity;
@end

@implementation FT8TableRowView
- (void)drawBackgroundInRect:(NSRect)dirtyRect {
    if (self.isSelected) {
        [[NSColor selectedContentBackgroundColor] setFill];
        NSRectFill(dirtyRect);
        return;
    }
    // High-contrast alternating row background for even/odd slots
    if (self.slotParity == 1) { // Odd slot (:15, :45) — subtle cool blue/slate tint
        [[NSColor colorWithCalibratedRed:0.94 green:0.96 blue:0.99 alpha:1.0] setFill];
    } else { // Even slot (:00, :30) — clean white
        [[NSColor controlBackgroundColor] setFill];
    }
    NSRectFill(dirtyRect);
}
@end

@implementation TX500FT8StationController

- (instancetype)init {
    self = [super init];
    if (self) {
        _audioEngine = [[TX500FT8AudioEngine alloc] init];
        _autoEngine = [[TX500FT8AutoEngine alloc] init];
        _autoEngine.audioEngine = _audioEngine;

        _allDecodes = [NSMutableArray array];
        _filteredDecodes = [NSMutableArray array];
        _txMessageButtons = [NSMutableArray array];
        _txMessageLabels = [NSMutableArray array];

        [self setupBindings];
        [self buildUserInterface];
        [self reloadStationPreferences];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self stopStation];
}

#pragma mark - Bindings & Callbacks

- (void)setupBindings {
    __weak typeof(self) weakSelf = self;

    // Audio Engine -> Waterfall & Decoder
    self.audioEngine.onSpectrumUpdated = ^(const float *magnitudes, NSInteger count) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.waterfallView appendSpectrumRow:magnitudes count:count];
    };

    // Slot Tick -> Progress Bar
    self.audioEngine.onSlotTick = ^(double slotSec, NSInteger parity, double progress) {
        (void)progress;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.slotProgressView.slotSecond = slotSec;
        strongSelf.slotProgressView.parity = parity;
        strongSelf.slotProgressView.isTransmitting = strongSelf.audioEngine.isTransmitting;
        [strongSelf.slotProgressView setNeedsDisplay:YES];
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
        } else {
            if (!strongSelf.audioEngine.isTransmitArmed) {
                strongSelf.armTxButton.state = NSControlStateValueOff;
            }
        }
    };

    // Decoded Messages from Slot
    self.audioEngine.onDecodedMessages = ^(NSArray<TX500FT8Message *> *messages, NSInteger parity) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Ingest into Auto-Engine
        [strongSelf.autoEngine processDecodedSlot:messages parity:parity];

        // Add to Table
        [strongSelf.allDecodes insertObjects:messages atIndexes:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(0, messages.count)]];
        if (strongSelf.allDecodes.count > 400) {
            [strongSelf.allDecodes removeObjectsInRange:NSMakeRange(400, strongSelf.allDecodes.count - 400)];
        }
        [strongSelf applyTableFilters];
    };

    // Auto-Engine Callbacks
    self.autoEngine.onQSOStateChanged = ^(TX500FT8QSOPhase phase, NSString *statusText) {
        (void)phase;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf updateTransmitMatrixLabels];
        [strongSelf appendToQSOConsole:[NSString stringWithFormat:@"~ State: %@", statusText]];
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

#pragma mark - Lifecycle

- (void)startStation {
    // Connect serial port command sender
    self.audioEngine.serialCommandSender = self.serialCommandSender;

    // Load SWR protection threshold from preferences
    double swrThreshold = [[NSUserDefaults standardUserDefaults] doubleForKey:@"TX500_SWRThreshold"];
    self.audioEngine.maxSWRThreshold = (swrThreshold > 0.0) ? swrThreshold : 0.0;

    NSError *err = nil;
    if ([self.audioEngine startMonitoring:&err]) {
        self.startStopButton.title = @"Stop FT8";
        self.startStopButton.bezelColor = [NSColor colorWithCalibratedRed:0.8 green:0.2 blue:0.2 alpha:1.0];
        [self appendToQSOConsole:@"[FT8 Engine] Monitoring active. 15-second slot synchronized."];
        if (self.stationStateChangedHandler) self.stationStateChangedHandler(YES);
    }
}

- (void)stopStation {
    [self.autoEngine stopAutoCQ];
    [self.autoEngine stopAutoHunter];
    [self.audioEngine stopMonitoring];
    self.startStopButton.title = @"Start FT8";
    self.startStopButton.bezelColor = nil;
    [self appendToQSOConsole:@"[FT8 Engine] Monitoring stopped."];
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
    [self.startStopButton.widthAnchor constraintEqualToConstant:85].active = YES;

    self.bandPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (int i = 0; kFT8Presets[i].band != NULL; i++) {
        [self.bandPopup addItemWithTitle:[NSString stringWithUTF8String:kFT8Presets[i].band]];
    }
    [self.bandPopup selectItemWithTitle:@"20m"];
    self.bandPopup.target = self;
    self.bandPopup.action = @selector(bandSelected:);
    [self.bandPopup.widthAnchor constraintEqualToConstant:75].active = YES;

    self.dialFreqLabel = [NSTextField labelWithString:@"14.074.000 MHz DIG"];
    self.dialFreqLabel.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightBold];
    self.dialFreqLabel.textColor = [NSColor colorWithCalibratedRed:0.80 green:0.48 blue:0.0 alpha:1.0];

    self.audioInPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self updateAudioDeviceMenus];
    self.audioInPopup.target = self;
    self.audioInPopup.action = @selector(audioDeviceSelected:);
    [self.audioInPopup.widthAnchor constraintGreaterThanOrEqualToConstant:130].active = YES;

    self.simCheckbox = [NSButton checkboxWithTitle:@"Simulation Mode" target:self action:@selector(toggleSimulation:)];
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
    [self.lockFreqsButton.widthAnchor constraintEqualToConstant:48].active = YES;

    self.tuneButton = [NSButton buttonWithTitle:@"Tune" target:self action:@selector(toggleTune:)];
    self.tuneButton.bezelStyle = NSBezelStyleInline;
    [self.tuneButton.widthAnchor constraintEqualToConstant:48].active = YES;

    self.armTxButton = [NSButton buttonWithTitle:@"ENABLE TX" target:self action:@selector(toggleArmTx:)];
    self.armTxButton.bezelStyle = NSBezelStyleRounded;
    [self.armTxButton.widthAnchor constraintEqualToConstant:92].active = YES;

    // TX Slot Parity: Even / Auto / Odd
    self.txParitySegment = [NSSegmentedControl segmentedControlWithLabels:@[@"Even", @"Auto", @"Odd"]
                                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                    target:self
                                                                    action:@selector(txParityChanged:)];
    self.txParitySegment.selectedSegment = 1; // Default Auto
    [self.txParitySegment.widthAnchor constraintEqualToConstant:142].active = YES;


    // SWR live indicator
    self.swrLabel = [NSTextField labelWithString:@"SWR: —"];
    self.swrLabel.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightBold];
    self.swrLabel.textColor = [NSColor secondaryLabelColor];

    NSBox *sep1 = [NSBox new]; sep1.boxType = NSBoxSeparator; [sep1.heightAnchor constraintEqualToConstant:18].active = YES;
    NSBox *sep2 = [NSBox new]; sep2.boxType = NSBoxSeparator; [sep2.heightAnchor constraintEqualToConstant:18].active = YES;
    NSBox *sep3 = [NSBox new]; sep3.boxType = NSBoxSeparator; [sep3.heightAnchor constraintEqualToConstant:18].active = YES;

    NSStackView *topStack = [NSStackView stackViewWithViews:@[
        self.startStopButton, self.bandPopup, self.dialFreqLabel, sep1,
        self.audioInPopup, self.simCheckbox, sep2,
        rxLbl, self.rxFreqField, txLbl, self.txFreqField,
        self.lockFreqsButton, self.tuneButton, self.armTxButton, sep3,
        self.txParitySegment, self.swrLabel
    ]];

    topStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    topStack.alignment = NSLayoutAttributeCenterY;
    topStack.spacing = 8;
    topStack.translatesAutoresizingMaskIntoConstraints = NO;
    [topRibbon.contentView addSubview:topStack];

    [NSLayoutConstraint activateConstraints:@[
        [topStack.leadingAnchor constraintEqualToAnchor:topRibbon.contentView.leadingAnchor constant:8],
        [topStack.trailingAnchor constraintLessThanOrEqualToAnchor:topRibbon.contentView.trailingAnchor constant:-8],
        [topStack.centerYAnchor constraintEqualToAnchor:topRibbon.contentView.centerYAnchor],
        [topRibbon.heightAnchor constraintEqualToConstant:38]
    ]];

    // --- 2. Lab599 Precision Panadapter & Spectrogram Chassis ---
    NSBox *panadapterBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    panadapterBox.translatesAutoresizingMaskIntoConstraints = NO;
    panadapterBox.boxType = NSBoxCustom;
    panadapterBox.cornerRadius = 8.0;
    panadapterBox.borderWidth = 1.0;
    panadapterBox.borderColor = [NSColor separatorColor];
    panadapterBox.fillColor = [NSColor controlBackgroundColor];
    [self.view addSubview:panadapterBox];

    // Panadapter Header Bar
    NSTextField *panTitleBadge = [NSTextField labelWithString:@"LAB599 TX-500"];
    panTitleBadge.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightHeavy];
    panTitleBadge.textColor = [NSColor colorWithCalibratedRed:0.80 green:0.48 blue:0.0 alpha:1.0]; // Lab599 Signature Amber Gold

    NSTextField *panSubBadge = [NSTextField labelWithString:@"PANADAPTER · 0 — 3000 Hz AF SPECTRUM"];
    panSubBadge.font = [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightMedium];
    panSubBadge.textColor = [NSColor secondaryLabelColor];

    NSTextField *panUtcBadge = [NSTextField labelWithString:@"15.0s UTC FT8 SLOT · WATERFALL"];
    panUtcBadge.font = [NSFont monospacedSystemFontOfSize:9.0 weight:NSFontWeightBold];
    panUtcBadge.textColor = [NSColor colorWithCalibratedRed:0.05 green:0.45 blue:0.75 alpha:1.0]; // Tactical Blue

    NSStackView *panHeaderLeft = [NSStackView stackViewWithViews:@[panTitleBadge, panSubBadge]];
    panHeaderLeft.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    panHeaderLeft.spacing = 8;
    panHeaderLeft.alignment = NSLayoutAttributeCenterY;

    NSStackView *panHeader = [NSStackView stackViewWithViews:@[panHeaderLeft, panUtcBadge]];
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

    [NSLayoutConstraint activateConstraints:@[
        [panHeader.topAnchor constraintEqualToAnchor:panadapterBox.contentView.topAnchor constant:5],
        [panHeader.leadingAnchor constraintEqualToAnchor:panadapterBox.contentView.leadingAnchor constant:10],
        [panHeader.trailingAnchor constraintEqualToAnchor:panadapterBox.contentView.trailingAnchor constant:-10],
        [panHeader.heightAnchor constraintEqualToConstant:14],

        [self.slotProgressView.topAnchor constraintEqualToAnchor:panHeader.bottomAnchor constant:4],
        [self.slotProgressView.leadingAnchor constraintEqualToAnchor:panadapterBox.contentView.leadingAnchor constant:8],
        [self.slotProgressView.trailingAnchor constraintEqualToAnchor:panadapterBox.contentView.trailingAnchor constant:-8],
        [self.slotProgressView.heightAnchor constraintEqualToConstant:18],

        [self.waterfallView.topAnchor constraintEqualToAnchor:self.slotProgressView.bottomAnchor constant:4],
        [self.waterfallView.leadingAnchor constraintEqualToAnchor:panadapterBox.contentView.leadingAnchor constant:8],
        [self.waterfallView.trailingAnchor constraintEqualToAnchor:panadapterBox.contentView.trailingAnchor constant:-8],
        [self.waterfallView.bottomAnchor constraintEqualToAnchor:panadapterBox.contentView.bottomAnchor constant:-7],
        [self.waterfallView.heightAnchor constraintEqualToConstant:115]
    ]];

    // --- 4. Autonomous Algorithms HUD Box ---
    NSBox *algoBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    algoBox.translatesAutoresizingMaskIntoConstraints = NO;
    algoBox.boxType = NSBoxCustom;
    algoBox.fillColor = [NSColor controlBackgroundColor];
    algoBox.borderColor = [NSColor separatorColor];
    algoBox.borderWidth = 1.0;
    algoBox.cornerRadius = 8.0;
    [self.view addSubview:algoBox];

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
    NSView *workstationContainer = [NSView new];
    workstationContainer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:workstationContainer];

    // Left Activity Area
    NSView *leftArea = [NSView new];
    leftArea.translatesAutoresizingMaskIntoConstraints = NO;
    [workstationContainer addSubview:leftArea];

    // Left Filter Bar
    self.tableFilterSegment = [NSSegmentedControl segmentedControlWithLabels:@[@"All", @"CQ Only", @"To Me"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(filterChanged:)];
    self.tableFilterSegment.selectedSegment = 0;
    self.tableFilterSegment.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tableFilterSegment.widthAnchor constraintEqualToConstant:175].active = YES;

    self.searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.target = self;
    self.searchField.action = @selector(searchChanged:);
    [self.searchField.widthAnchor constraintEqualToConstant:140].active = YES;

    NSButton *clearDecodesBtn = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearDecodesClicked:)];
    clearDecodesBtn.translatesAutoresizingMaskIntoConstraints = NO;
    clearDecodesBtn.bezelStyle = NSBezelStyleInline;
    [clearDecodesBtn.widthAnchor constraintEqualToConstant:50].active = YES;

    BOOL showUTC = [[NSUserDefaults standardUserDefaults] boolForKey:@"TX500_DisplayTimeInUTC"];
    self.timeModeButton = [NSButton buttonWithTitle:showUTC ? @"Time: UTC" : @"Time: Local" target:self action:@selector(toggleTimeDisplayMode:)];
    self.timeModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.timeModeButton.bezelStyle = NSBezelStyleInline;
    [self.timeModeButton.widthAnchor constraintEqualToConstant:85].active = YES;

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
    [self.alertCountryPopup addItemWithTitle:@"Iran 🇮🇷"];
    [self.alertCountryPopup addItemWithTitle:@"Japan 🇯🇵"];
    [self.alertCountryPopup addItemWithTitle:@"United States 🇺🇸"];
    [self.alertCountryPopup addItemWithTitle:@"Germany 🇩🇪"];
    [self.alertCountryPopup addItemWithTitle:@"Russia 🇷🇺"];
    [self.alertCountryPopup addItemWithTitle:@"Australia 🇦🇺"];
    [self.alertCountryPopup addItemWithTitle:@"China 🇨🇳"];
    [self.alertCountryPopup addItemWithTitle:@"United Kingdom 🇬🇧"];
    [self.alertCountryPopup addItemWithTitle:@"France 🇫🇷"];
    [self.alertCountryPopup addItemWithTitle:@"Italy 🇮🇹"];
    [self.alertCountryPopup addItemWithTitle:@"Canada 🇨🇦"];
    self.alertCountryPopup.target = self;
    self.alertCountryPopup.action = @selector(filterChanged:);
    [self.alertCountryPopup.widthAnchor constraintEqualToConstant:140].active = YES;

    NSStackView *advFilterBar = [NSStackView stackViewWithViews:@[
        snrMinLbl, self.snrMinField, snrMaxLbl, self.snrMaxField, snrUnit,
        self.alertEnabledCheckbox, self.alertCountryPopup
    ]];
    advFilterBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    advFilterBar.alignment = NSLayoutAttributeCenterY;
    advFilterBar.spacing = 5;
    advFilterBar.translatesAutoresizingMaskIntoConstraints = NO;
    [leftArea addSubview:advFilterBar];

    NSStackView *filterBar = [NSStackView stackViewWithViews:@[self.tableFilterSegment, self.searchField, clearDecodesBtn, self.timeModeButton]];
    filterBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    filterBar.alignment = NSLayoutAttributeCenterY;
    filterBar.spacing = 8;
    filterBar.translatesAutoresizingMaskIntoConstraints = NO;
    [leftArea addSubview:filterBar];


    // Activity Table View & ScrollView
    NSScrollView *tableScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    tableScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    tableScrollView.hasVerticalScroller = YES;
    tableScrollView.hasHorizontalScroller = NO;
    tableScrollView.borderType = NSBezelBorder;

    self.activityTableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.activityTableView.dataSource = self;
    self.activityTableView.delegate = self;
    self.activityTableView.rowHeight = 22.0;
    self.activityTableView.usesAlternatingRowBackgroundColors = NO;
    self.activityTableView.target = self;
    self.activityTableView.doubleAction = @selector(tableRowDoubleClicked:);

    [self addColumnToTable:self.activityTableView title:showUTC ? @"UTC" : @"Local" identifier:kColTime width:68];
    [self addColumnToTable:self.activityTableView title:@"dB" identifier:kColSNR width:38];
    [self addColumnToTable:self.activityTableView title:@"DT" identifier:kColDT width:38];
    [self addColumnToTable:self.activityTableView title:@"Freq" identifier:kColFreq width:50];
    [self addColumnToTable:self.activityTableView title:@"Message" identifier:kColMsg width:195];
    [self addColumnToTable:self.activityTableView title:@"Country" identifier:kColCountry width:130];
    [self addColumnToTable:self.activityTableView title:@"Grid" identifier:kColGrid width:55];
    [self addColumnToTable:self.activityTableView title:@"Dist" identifier:kColDistance width:65];

    tableScrollView.documentView = self.activityTableView;
    [leftArea addSubview:tableScrollView];

    [NSLayoutConstraint activateConstraints:@[
        [filterBar.topAnchor constraintEqualToAnchor:leftArea.topAnchor],
        [filterBar.leadingAnchor constraintEqualToAnchor:leftArea.leadingAnchor],
        [filterBar.heightAnchor constraintEqualToConstant:24],

        [advFilterBar.topAnchor constraintEqualToAnchor:filterBar.bottomAnchor constant:4],
        [advFilterBar.leadingAnchor constraintEqualToAnchor:leftArea.leadingAnchor],
        [advFilterBar.heightAnchor constraintEqualToConstant:22],

        [tableScrollView.topAnchor constraintEqualToAnchor:advFilterBar.bottomAnchor constant:4],
        [tableScrollView.leadingAnchor constraintEqualToAnchor:leftArea.leadingAnchor],
        [tableScrollView.trailingAnchor constraintEqualToAnchor:leftArea.trailingAnchor],
        [tableScrollView.bottomAnchor constraintEqualToAnchor:leftArea.bottomAnchor]
    ]];


    // Right Panel: Transmit Matrix & Copilot (Fixed width ~350pt)
    NSBox *rightBox = [NSBox new];
    rightBox.translatesAutoresizingMaskIntoConstraints = NO;
    rightBox.boxType = NSBoxCustom;
    rightBox.fillColor = [NSColor controlBackgroundColor];
    rightBox.borderColor = [NSColor separatorColor];
    rightBox.borderWidth = 1.0;
    rightBox.cornerRadius = 6.0;
    [workstationContainer addSubview:rightBox];

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

    // Workstation Container Split (Left & Right)
    [NSLayoutConstraint activateConstraints:@[
        [leftArea.leadingAnchor constraintEqualToAnchor:workstationContainer.leadingAnchor],
        [leftArea.topAnchor constraintEqualToAnchor:workstationContainer.topAnchor],
        [leftArea.bottomAnchor constraintEqualToAnchor:workstationContainer.bottomAnchor],
        [leftArea.trailingAnchor constraintEqualToAnchor:rightBox.leadingAnchor constant:-10],

        [rightBox.trailingAnchor constraintEqualToAnchor:workstationContainer.trailingAnchor],
        [rightBox.topAnchor constraintEqualToAnchor:workstationContainer.topAnchor],
        [rightBox.bottomAnchor constraintEqualToAnchor:workstationContainer.bottomAnchor],
        [rightBox.widthAnchor constraintEqualToConstant:340]
    ]];

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

    NSStackView *bottomStack = [NSStackView stackViewWithViews:@[
        self.sessionLogCountLabel, self.openLogsButton, self.exportADIFButton, self.clearLogButton
    ]];
    bottomStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bottomStack.alignment = NSLayoutAttributeCenterY;
    bottomStack.spacing = 10;
    bottomStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:bottomStack];

    // --- Main Vertical Stack Auto-Layout Constraints ---
    [NSLayoutConstraint activateConstraints:@[
        [topRibbon.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],
        [topRibbon.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [topRibbon.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        [panadapterBox.topAnchor constraintEqualToAnchor:topRibbon.bottomAnchor constant:6],
        [panadapterBox.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [panadapterBox.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        [algoBox.topAnchor constraintEqualToAnchor:panadapterBox.bottomAnchor constant:6],
        [algoBox.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [algoBox.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],

        [workstationContainer.topAnchor constraintEqualToAnchor:algoBox.bottomAnchor constant:6],
        [workstationContainer.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
        [workstationContainer.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-12],
        [workstationContainer.heightAnchor constraintEqualToConstant:340],

        [bottomStack.topAnchor constraintEqualToAnchor:workstationContainer.bottomAnchor constant:6],
        [bottomStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:12],
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
    NSInteger idx = self.bandPopup.indexOfSelectedItem;
    if (idx >= 0 && kFT8Presets[idx].band != NULL) {
        uint64_t freq = kFT8Presets[idx].freqHz;
        self.audioEngine.dialFrequencyHz = freq;
        [self updateFrequencyHz:freq mode:@"DIG"];
        if (self.serialCommandSender) {
            self.serialCommandSender([NSString stringWithFormat:@"FA%011llu;", freq]);
            self.serialCommandSender(@"MD6;");
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
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:@"TX500_FT8_SimulationModeEnabled"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    if (enabled) {
        [self appendToQSOConsole:@"[Simulation Mode] Activated by operator. Synthetic FT8 RF signals generated."];
        if (self.allDecodes.count == 0) {
            [self.audioEngine injectSimulatedBandActivity];
        }
    } else {
        [self appendToQSOConsole:@"[Simulation Mode] Deactivated. Monitoring live radio audio."];
        [self.allDecodes removeAllObjects];
        [self applyTableFilters];
    }
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
    } else {
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
    } else {
        [self.autoEngine startAutoCQWithLimit:self.autoCQStepper.integerValue];
        self.autoCQButton.title = @"Stop CQ";
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
    } else {
        [self.autoEngine startAutoHunter];
        self.autoHunterButton.title = @"Stop Hunter";
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
}

- (void)reloadStationPreferences {
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

    BOOL showUTC = [[NSUserDefaults standardUserDefaults] boolForKey:@"TX500_DisplayTimeInUTC"];
    self.timeModeButton.title = showUTC ? @"Time: UTC" : @"Time: Local";
    NSTableColumn *col = [self.activityTableView tableColumnWithIdentifier:kColTime];
    if (col) {
        col.title = showUTC ? @"UTC" : @"Local";
    }
    [self updateTransmitMatrixLabels];
    [self.activityTableView reloadData];
}

- (void)toggleTimeDisplayMode:(id)sender {
    (void)sender;
    BOOL currentUTC = [[NSUserDefaults standardUserDefaults] boolForKey:@"TX500_DisplayTimeInUTC"];
    BOOL newUTC = !currentUTC;
    [[NSUserDefaults standardUserDefaults] setBool:newUTC forKey:@"TX500_DisplayTimeInUTC"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self reloadStationPreferences];
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
}

- (void)updateTransmitMatrixLabels {
    NSString *myCall = self.myCallField.stringValue.uppercaseString;
    NSString *myGrid = self.myGridField.stringValue.uppercaseString;
    NSString *dxCall = self.dxCallField.stringValue.uppercaseString;
    NSString *dxGrid = self.dxGridField.stringValue.uppercaseString;
    NSString *sentRpt = self.autoEngine.sentReport ?: @"-10";
    NSString *rcvdRpt = self.autoEngine.rcvdReport ?: @"-10";

    for (int i = 1; i <= 6; i++) {
        NSString *msg = [TX500FT8Message messageForPhase:i myCall:myCall myGrid:myGrid dxCall:dxCall dxGrid:dxGrid myReport:sentRpt rcvdReport:rcvdRpt];
        self.txMessageLabels[i - 1].stringValue = msg;
    }
}

- (void)updateAudioDeviceMenus {
    [self.audioInPopup removeAllItems];
    NSInteger selectIdx = -1;
    for (NSInteger i = 0; i < (NSInteger)self.audioEngine.inputDevices.count; i++) {
        NSDictionary *dev = self.audioEngine.inputDevices[i];
        [self.audioInPopup addItemWithTitle:dev[@"name"]];
        if (self.audioEngine.selectedInputDeviceUID && [dev[@"uid"] isEqualToString:self.audioEngine.selectedInputDeviceUID]) {
            selectIdx = i;
        } else if (selectIdx == -1 && [dev[@"isAD508"] isEqualToString:@"YES"]) {
            selectIdx = i;
            self.audioEngine.selectedInputDeviceUID = dev[@"uid"];
        }
    }
    if (self.audioInPopup.numberOfItems == 0) {
        [self.audioInPopup addItemWithTitle:@"Default Audio In"];
    } else if (selectIdx >= 0 && selectIdx < self.audioInPopup.numberOfItems) {
        [self.audioInPopup selectItemAtIndex:selectIdx];
    }
}

- (void)audioDeviceSelected:(id)sender {
    (void)sender;
    NSInteger idx = self.audioInPopup.indexOfSelectedItem;
    if (idx >= 0 && idx < (NSInteger)self.audioEngine.inputDevices.count) {
        NSDictionary *dev = self.audioEngine.inputDevices[idx];
        NSString *uid = dev[@"uid"];
        self.audioEngine.selectedInputDeviceUID = uid;

        // Automatically match corresponding output device if AD-508 / USB Audio
        for (NSDictionary *outDev in self.audioEngine.outputDevices) {
            if ([outDev[@"name"] isEqualToString:dev[@"name"]] ||
                ([dev[@"isAD508"] isEqualToString:@"YES"] && [outDev[@"isAD508"] isEqualToString:@"YES"])) {
                self.audioEngine.selectedOutputDeviceUID = outDev[@"uid"];
                break;
            }
        }
        [self.audioEngine restartAudioHardware];
    }
}

#pragma mark - Table View Data Source & Delegate

- (void)filterChanged:(id)sender {
    (void)sender;
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

- (void)applyTableFilters {
    [self.filteredDecodes removeAllObjects];
    NSInteger seg = self.tableFilterSegment.selectedSegment;
    NSString *query = self.searchField.stringValue.uppercaseString;

    // SNR range filter (if fields exist and have values)
    float snrMin = -30.0f, snrMax = 30.0f;
    if (self.snrMinField && self.snrMinField.stringValue.length > 0) {
        snrMin = [self.snrMinField.stringValue floatValue];
    }
    if (self.snrMaxField && self.snrMaxField.stringValue.length > 0) {
        snrMax = [self.snrMaxField.stringValue floatValue];
    }
    BOOL hasSNRFilter = (self.snrMinField && self.snrMinField.stringValue.length > 0) ||
                        (self.snrMaxField && self.snrMaxField.stringValue.length > 0);

    // Alert: check if alert is enabled and what country to alert for
    NSString *alertCountry = nil;
    if (self.alertEnabledCheckbox && self.alertEnabledCheckbox.state == NSControlStateValueOn) {
        alertCountry = self.alertCountryPopup.titleOfSelectedItem;
    }

    BOOL didAlert = NO;

    for (TX500FT8Message *m in self.allDecodes) {
        if (seg == 1 && !m.isCQ) continue;
        if (seg == 2 && !m.isDirectedToMe) continue;
        if (hasSNRFilter && (m.snrDb < snrMin || m.snrDb > snrMax)) continue;
        if (query.length > 0 && ![m.rawText.uppercaseString containsString:query] &&
            ![m.countryName.uppercaseString containsString:query] &&
            !([m.callerCall uppercaseString] && [m.callerCall.uppercaseString containsString:query])) {
            continue;
        }
        [self.filteredDecodes addObject:m];

        // Check alerts
        if (!didAlert && alertCountry.length > 0 && [m.countryName containsString:alertCountry]) {
            didAlert = YES;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            NSUserNotification *notif = [[NSUserNotification alloc] init];
            notif.title = @"FT8 Alert — Station Heard!";
            notif.informativeText = [NSString stringWithFormat:@"%@ (%@) — %@ %+.0f dB",
                                     m.callerCall ?: @"?", m.countryFlag ?: @"",
                                     m.countryName ?: @"", m.snrDb];
            notif.soundName = NSUserNotificationDefaultSoundName;
            [[NSUserNotificationCenter defaultUserNotificationCenter] deliverNotification:notif];
#pragma clang diagnostic pop
            [[NSSound soundNamed:@"Hero"] play];
            [self appendToQSOConsole:[NSString stringWithFormat:@"🚨 ALERT: Heard %@ (%@) %+.0f dB",
                                      m.callerCall ?: @"?", m.countryName ?: @"", m.snrDb]];
        }
    }
    [self.activityTableView reloadData];
}

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return self.filteredDecodes.count;
}

- (NSTableRowView *)tableView:(NSTableView *)tableView rowViewForRow:(NSInteger)row {
    static NSString *const kRowIdent = @"FT8TableRowView";
    FT8TableRowView *rowView = [tableView makeViewWithIdentifier:kRowIdent owner:self];
    if (!rowView) {
        rowView = [[FT8TableRowView alloc] initWithFrame:NSZeroRect];
        rowView.identifier = kRowIdent;
    }
    if (row >= 0 && row < (NSInteger)self.filteredDecodes.count) {
        TX500FT8Message *m = self.filteredDecodes[row];
        rowView.slotParity = m.slotParity;
    }
    return rowView;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= (NSInteger)self.filteredDecodes.count) return nil;
    TX500FT8Message *m = self.filteredDecodes[row];
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

    // Highlighting colors: Deep Forest Green for CQ, Deep Amber for Directed to Me, Crimson for My TX
    NSColor *fgColor = [NSColor labelColor];
    if (m.isDirectedToMe) {
        fgColor = [NSColor colorWithCalibratedRed:0.78 green:0.38 blue:0.0 alpha:1.0]; // Deep Amber / Bronze
    } else if (m.isCQ) {
        fgColor = [NSColor colorWithCalibratedRed:0.06 green:0.50 blue:0.18 alpha:1.0]; // Deep Forest Green
    } else if (m.isMyTransmission) {
        fgColor = [NSColor colorWithCalibratedRed:0.82 green:0.12 blue:0.12 alpha:1.0]; // Deep Red
    }
    tf.textColor = fgColor;

    BOOL isUTC = [[NSUserDefaults standardUserDefaults] boolForKey:@"TX500_DisplayTimeInUTC"];
    static NSDateFormatter *s_localFormatter = nil;
    static NSDateFormatter *s_utcFormatter = nil;
    static dispatch_once_t s_onceToken;
    dispatch_once(&s_onceToken, ^{
        s_localFormatter = [[NSDateFormatter alloc] init];
        s_localFormatter.timeZone = [NSTimeZone localTimeZone];
        s_localFormatter.dateFormat = @"HH:mm:ss";

        s_utcFormatter = [[NSDateFormatter alloc] init];
        s_utcFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
        s_utcFormatter.dateFormat = @"HH:mm:ss";
    });

    if ([ident isEqualToString:kColTime]) {
        NSDateFormatter *df = isUTC ? s_utcFormatter : s_localFormatter;
        tf.stringValue = [df stringFromDate:m.timestamp];
    } else if ([ident isEqualToString:kColSNR]) {
        tf.stringValue = [NSString stringWithFormat:@"%+d", (int)roundf(m.snrDb)];
    } else if ([ident isEqualToString:kColDT]) {
        tf.stringValue = [NSString stringWithFormat:@"%.1f", m.timeSec];
    } else if ([ident isEqualToString:kColFreq]) {
        tf.stringValue = [NSString stringWithFormat:@"%.0f", m.freqHz];
    } else if ([ident isEqualToString:kColMsg]) {
        tf.stringValue = m.rawText;
    } else if ([ident isEqualToString:kColCountry]) {
        tf.stringValue = [NSString stringWithFormat:@"%@ %@", m.countryFlag, m.countryName];
    } else if ([ident isEqualToString:kColGrid]) {
        tf.stringValue = m.grid ?: @"-";
    } else if ([ident isEqualToString:kColDistance]) {
        tf.stringValue = (m.distanceKm >= 0) ? [NSString stringWithFormat:@"%.0f km", m.distanceKm] : @"-";
    }
    return cellView;
}

- (void)tableRowDoubleClicked:(id)sender {
    (void)sender;
    NSInteger row = self.activityTableView.selectedRow;
    if (row >= 0 && row < (NSInteger)self.filteredDecodes.count) {
        TX500FT8Message *target = self.filteredDecodes[row];
        self.dxCallField.stringValue = target.callerCall ?: @"";
        self.dxGridField.stringValue = target.grid ?: @"";
        [self dxCallEdited:nil];

        // Engage station immediately!
        [self.autoEngine engageStation:target];
    }
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
