//
//  TX500AudioMonitorController.m
//  Lab599 Utility
//
//  Complete Live Radio Audio Monitoring, DSP Studio, Transceiver VFO & Memory Bank
//  Specially designed for Lab599 Discovery TX-500 over AD-508 USB-C Audio & CAT
//

#import "TX500AudioMonitorController.h"

#define TX500_BOOKMARKS_KEY @"TX500AudioMonitorBookmarks_v2"

@interface TX500VFOTextField : NSTextField
@property (nonatomic, copy, nullable) void (^onScrolled)(NSInteger deltaUnits);
@end

@implementation TX500VFOTextField
- (void)scrollWheel:(NSEvent *)event {
    if (self.onScrolled) {
        CGFloat dy = event.scrollingDeltaY;
        if (fabs(dy) > 0.1) {
            NSInteger step = (dy > 0) ? 1 : -1;
            self.onScrolled(step);
            return;
        }
    }
    [super scrollWheel:event];
}
@end

@interface TX500AudioMonitorController ()

@property (nonatomic, strong, readwrite) NSView *view;
@property (nonatomic, strong, readwrite) TX500AudioEngine *engine;
@property (nonatomic, strong, readwrite) TX500AudioVisualizerView *visualizerView;

// Top Bar Controls
@property (nonatomic, strong) NSBox *statusPillBox;
@property (nonatomic, strong) NSView *statusLEDView;
@property (nonatomic, strong) NSTextField *statusLabel;
@property (nonatomic, strong) NSButton *monitorToggleButton;
@property (nonatomic, strong) NSButton *muteButton;
@property (nonatomic, strong) NSButton *dimButton;
@property (nonatomic, strong) NSButton *recordButton;
@property (nonatomic, strong) NSBox *recordDurationBox;
@property (nonatomic, strong) NSTextField *recordTimerLabel;
@property (nonatomic, strong) NSButton *revealRecordingsButton;
@property (nonatomic, strong) NSButton *simulationButton;
@property (nonatomic, strong) NSButton *instantReplayButton;

// Visualizer Controls
@property (nonatomic, strong) NSSegmentedControl *visualizerModeControl;
@property (nonatomic, strong) NSSegmentedControl *waterfallSpeedControl;
@property (nonatomic, strong) NSSegmentedControl *frequencySpanControl;
@property (nonatomic, strong) NSSegmentedControl *visualThemeControl;
@property (nonatomic, strong) NSSlider *waterfallFloorSlider;
@property (nonatomic, strong) NSTextField *waterfallFloorLabel;
@property (nonatomic, strong) NSSlider *waterfallDynRangeSlider;
@property (nonatomic, strong) NSTextField *waterfallDynRangeLabel;

// Transceiver VFO & Mode Controls
@property (nonatomic, assign, readwrite) uint64_t currentFrequencyHz;
@property (nonatomic, copy, readwrite) NSString *currentMode;
@property (nonatomic, assign, readwrite) NSInteger currentSMeter;
@property (nonatomic, strong) TX500VFOTextField *vfoFreqLabel;
@property (nonatomic, strong) NSTextField *vfoBandLabel;
@property (nonatomic, strong) NSTextField *sMeterLabel;
@property (nonatomic, strong) NSSegmentedControl *modeSegmentControl;
@property (nonatomic, strong) NSSegmentedControl *vfoStepSegmentControl;
@property (nonatomic, assign) NSInteger currentTuningStepHz;
@property (nonatomic, strong) NSTimer *catPollTimer;
@property (nonatomic, assign) BOOL isCATPolling;

// Quick Memory Bank Controls
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *mutableBookmarks;
@property (nonatomic, strong) NSPopUpButton *memoryPopup;
@property (nonatomic, strong) NSButton *addBookmarkButton;
@property (nonatomic, strong) NSButton *renameBookmarkButton;
@property (nonatomic, strong) NSButton *deleteBookmarkButton;
@property (nonatomic, strong) NSStackView *memoryChipsStack;

// Hardware Routing Controls
@property (nonatomic, strong) NSPopUpButton *inputDevicePopup;
@property (nonatomic, strong) NSPopUpButton *outputDevicePopup;
@property (nonatomic, strong) NSPopUpButton *bufferSizePopup;

// DSP Filter Controls
@property (nonatomic, strong) NSSegmentedControl *presetSegmentedControl;
@property (nonatomic, strong) NSSlider *lowCutSlider;
@property (nonatomic, strong) NSTextField *lowCutValueLabel;
@property (nonatomic, strong) NSSlider *highCutSlider;
@property (nonatomic, strong) NSTextField *highCutValueLabel;

// Notch & Auto-Notch Filter Controls
@property (nonatomic, strong) NSButton *notchCheckbox;
@property (nonatomic, strong) NSSlider *notchFreqSlider;
@property (nonatomic, strong) NSTextField *notchFreqValueLabel;
@property (nonatomic, strong) NSButton *autoNotchCheckbox;
@property (nonatomic, strong) NSTextField *autoNotchStatusLabel;

// Spectral Noise Reduction (NR) Controls
@property (nonatomic, strong) NSButton *nrCheckbox;
@property (nonatomic, strong) NSSlider *nrDepthSlider;
@property (nonatomic, strong) NSTextField *nrValueLabel;
@property (nonatomic, strong) NSTextField *nrDepthValueLabel;

// 3-Band Speech EQ Controls
@property (nonatomic, strong) NSButton *eqCheckbox;
@property (nonatomic, strong) NSSlider *eqLowSlider;
@property (nonatomic, strong) NSSlider *eqMidSlider;
@property (nonatomic, strong) NSSlider *eqHighSlider;
@property (nonatomic, strong) NSTextField *eqLowLabel;
@property (nonatomic, strong) NSTextField *eqMidLabel;
@property (nonatomic, strong) NSTextField *eqHighLabel;

// Squelch & Limiter Controls
@property (nonatomic, strong) NSButton *squelchCheckbox;
@property (nonatomic, strong) NSSlider *squelchThresholdSlider;
@property (nonatomic, strong) NSTextField *squelchValueLabel;
@property (nonatomic, strong) NSView *squelchLED;
@property (nonatomic, strong) NSButton *limiterCheckbox;

// Master Volume & Balance Controls
@property (nonatomic, strong) NSSlider *volumeSlider;
@property (nonatomic, strong) NSTextField *volumeValueLabel;
@property (nonatomic, strong) NSSlider *balanceSlider;
@property (nonatomic, strong) NSTextField *balanceValueLabel;

// Cable Guide Collapsible Card
@property (nonatomic, strong) NSButton *guideDisclosureButton;
@property (nonatomic, strong) NSTextField *guideContentLabel;
@property (nonatomic, assign) BOOL isGuideCollapsed;

@end

@implementation TX500AudioMonitorController

- (instancetype)init {
    self = [super init];
    if (self) {
        _engine = [TX500AudioEngine new];
        _currentFrequencyHz = 14074000; // Default 20m FT8
        _currentMode = @"USB";
        _currentSMeter = 7;
        _currentTuningStepHz = 100;
        _isCATPolling = NO;
        _isGuideCollapsed = [[NSUserDefaults standardUserDefaults] boolForKey:@"TX500_AudioCableGuideCollapsed"];

        [self loadBookmarksStorage];
        [self setupBindings];
        [self buildUserInterface];
        [self updateDeviceMenus];
    }
    return self;
}

- (void)dealloc {
    [self stopController];
}

- (NSView *)createCardView {
    NSView *v = [[NSView alloc] initWithFrame:NSZeroRect];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.wantsLayer = YES;
    v.layer.cornerRadius = 6.0;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.18].CGColor;
    v.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.06].CGColor;
    return v;
}

- (NSArray<NSDictionary *> *)bookmarks {
    return [self.mutableBookmarks copy] ?: @[];
}

#pragma mark - Memory Bookmarks Storage

- (void)loadBookmarksStorage {
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:TX500_BOOKMARKS_KEY];
    if (saved && saved.count > 0) {
        self.mutableBookmarks = [saved mutableCopy];
        BOOL modified = NO;
        BOOL has30m = NO;
        for (NSUInteger i = 0; i < self.mutableBookmarks.count; i++) {
            NSMutableDictionary *d = [self.mutableBookmarks[i] mutableCopy];
            uint64_t freq = [d[@"freq"] unsignedLongLongValue];
            NSString *label = d[@"label"] ?: @"";
            // Correct mislabeled 30m on 14.074 MHz -> 20m FT8
            if (freq == 14074000 && [label containsString:@"30m"]) {
                d[@"label"] = @"20m FT8";
                self.mutableBookmarks[i] = d;
                modified = YES;
            }
            if (freq == 10136000) {
                has30m = YES;
            }
        }
        if (!has30m) {
            [self.mutableBookmarks insertObject:@{@"label": @"30m FT8", @"freq": @10136000, @"mode": @"DIG"} atIndex:1];
            modified = YES;
        }
        if (modified) {
            [self saveBookmarksStorage];
        }
    } else {
        self.mutableBookmarks = [NSMutableArray arrayWithArray:@[
            @{@"label": @"20m FT8",           @"freq": @14074000, @"mode": @"DIG"},
            @{@"label": @"30m FT8",           @"freq": @10136000, @"mode": @"DIG"},
            @{@"label": @"40m FT8",           @"freq": @7074000,  @"mode": @"DIG"},
            @{@"label": @"20m SSB Calling",   @"freq": @14200000, @"mode": @"USB"},
            @{@"label": @"40m SSB Calling",   @"freq": @7100000,  @"mode": @"LSB"},
            @{@"label": @"20m CW QRP",        @"freq": @14060000, @"mode": @"CW"},
            @{@"label": @"40m CW QRP",        @"freq": @7030000,  @"mode": @"CW"},
            @{@"label": @"10m SSB Calling",   @"freq": @28400000, @"mode": @"USB"},
            @{@"label": @"15m FT8",           @"freq": @21074000, @"mode": @"DIG"},
            @{@"label": @"AM Broadcast (MW)", @"freq": @1000000,  @"mode": @"AM"},
            @{@"label": @"2m Calling (FM)",   @"freq": @144200000,@"mode": @"FM"}
        ]];
        [self saveBookmarksStorage];
    }
}

- (void)saveBookmarksStorage {
    [[NSUserDefaults standardUserDefaults] setObject:self.mutableBookmarks forKey:TX500_BOOKMARKS_KEY];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - Bindings

- (void)setupBindings {
    __weak typeof(self) weakSelf = self;

    // Interactive Filter Dragging Callback
    self.visualizerView.onFilterRangeChanged = ^(float lowCutHz, float highCutHz) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.engine.lowCutHz = lowCutHz;
        strongSelf.engine.highCutHz = highCutHz;
        strongSelf.lowCutSlider.floatValue = lowCutHz;
        strongSelf.lowCutValueLabel.stringValue = [NSString stringWithFormat:@"%.0f Hz", lowCutHz];
        strongSelf.highCutSlider.floatValue = highCutHz;
        strongSelf.highCutValueLabel.stringValue = [NSString stringWithFormat:@"%.0f Hz", highCutHz];
    };

    // Click-to-Notch Callback from Spectrum
    self.visualizerView.onNotchFrequencyChanged = ^(float notchFreqHz) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.engine.notchFreqHz = notchFreqHz;
        strongSelf.engine.notchEnabled = YES;
        strongSelf.visualizerView.notchFreqHz = notchFreqHz;
        strongSelf.visualizerView.notchEnabled = YES;
        strongSelf.notchCheckbox.state = NSControlStateValueOn;
        strongSelf.notchFreqSlider.enabled = YES;
        strongSelf.notchFreqSlider.floatValue = notchFreqHz;
        strongSelf.notchFreqValueLabel.stringValue = [NSString stringWithFormat:@"%.0f Hz", notchFreqHz];
        if (strongSelf.logHandler) {
            strongSelf.logHandler([NSString stringWithFormat:@"Notch Filter set to %.0f Hz via Spectrum Click.", notchFreqHz]);
        }
    };

    // Visualizer Frequency Tuning Callback
    self.visualizerView.onFrequencyTuned = ^(float deltaHz) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf tuneStep:(NSInteger)roundf(deltaHz)];
    };

    // Instant Replay Progress Callback
    self.engine.onReplayProgressChanged = ^(BOOL isReplaying, float progress) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (isReplaying) {
            strongSelf.instantReplayButton.title = [NSString stringWithFormat:@"■ Stop 15s (%d%%)", (int)(progress * 100.0f)];
            strongSelf.instantReplayButton.contentTintColor = [NSColor systemOrangeColor];
        } else {
            strongSelf.instantReplayButton.title = @"↺ Replay 15s";
            strongSelf.instantReplayButton.contentTintColor = nil;
        }
    };

    self.engine.onMetricsUpdated = ^(float leftRmsDb, float rightRmsDb, float peakDb, BOOL clipping, BOOL squelchOpen) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        strongSelf.visualizerView.leftRmsDb = leftRmsDb;
        strongSelf.visualizerView.rightRmsDb = rightRmsDb;
        strongSelf.visualizerView.peakDb = peakDb;
        strongSelf.visualizerView.isClipping = clipping;
        strongSelf.visualizerView.isSquelchOpen = squelchOpen;

        if (strongSelf.engine.squelchEnabled) {
            strongSelf.squelchLED.layer.backgroundColor = squelchOpen ?
                [NSColor colorWithCalibratedRed:0.2 green:0.85 blue:0.4 alpha:1.0].CGColor :
                [NSColor colorWithCalibratedRed:0.4 green:0.4 blue:0.4 alpha:1.0].CGColor;
        } else {
            strongSelf.squelchLED.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.2 green:0.85 blue:0.4 alpha:1.0].CGColor;
        }
    };

    self.engine.onSpectrumUpdated = ^(const float *magnitudes, NSInteger count, float sampleRate) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.visualizerView updateSpectrumWithMagnitudes:magnitudes count:count sampleRate:sampleRate];
    };

    self.engine.onWaveformUpdated = ^(const float *samples, NSInteger count) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.visualizerView updateWaveformWithSamples:samples count:count];
    };

    self.engine.onDeviceListChanged = ^{
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf updateDeviceMenus];
        [strongSelf updateHardwareStatusPill];
    };

    self.engine.onRecordingStatusChanged = ^(BOOL isRecording, NSTimeInterval duration, NSString * _Nullable path) {
        (void)path;
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;

        if (isRecording) {
            NSInteger mins = (NSInteger)duration / 60;
            NSInteger secs = (NSInteger)duration % 60;
            strongSelf.recordTimerLabel.stringValue = [NSString stringWithFormat:@"%02ld:%02ld", (long)mins, (long)secs];
            strongSelf.recordDurationBox.hidden = NO;
            strongSelf.revealRecordingsButton.hidden = NO;
            strongSelf.recordButton.title = @"Stop Rec";
            if (@available(macOS 11.0, *)) {
                strongSelf.recordButton.image = [NSImage imageWithSystemSymbolName:@"stop.circle.fill" accessibilityDescription:@"Stop"];
            }
        } else {
            strongSelf.recordDurationBox.hidden = YES;
            strongSelf.recordButton.title = @"Record";
            if (@available(macOS 11.0, *)) {
                strongSelf.recordButton.image = [NSImage imageWithSystemSymbolName:@"record.circle.fill" accessibilityDescription:@"Record"];
            }
        }
    };

    self.engine.onErrorOccurred = ^(NSString *errorMessage) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.logHandler) strongSelf.logHandler([NSString stringWithFormat:@"Audio Error: %@", errorMessage]);
    };
}

#pragma mark - UI Building

- (void)buildUserInterface {
    self.view = [[NSView alloc] initWithFrame:NSZeroRect];
    self.view.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *topCard = [self buildTopControlBar];
    NSView *vizCard = [self buildVisualizerSection];
    NSView *trxCard = [self buildTransceiverAndMemoryCard];
    NSView *midRow = [self buildMiddleSection];
    NSView *filterCard = [self buildDSPFilterRack];
    NSView *guideCard = [self buildCableGuideCard];

    NSStackView *rootStack = [NSStackView stackViewWithViews:@[topCard, vizCard, trxCard, midRow, filterCard, guideCard]];
    rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    rootStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    rootStack.spacing = 8.0;
    rootStack.alignment = NSLayoutAttributeLeading;
    rootStack.distribution = NSStackViewDistributionFill;
    [self.view addSubview:rootStack];

    [NSLayoutConstraint activateConstraints:@[
        [rootStack.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [rootStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [rootStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [rootStack.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [topCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
        [vizCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
        [trxCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
        [midRow.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
        [filterCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
        [guideCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
    ]];

    [self updateHardwareStatusPill];
    [self updateVFOReadout];
    [self reloadMemoryPopup];
}

#pragma mark - Section 1: Top Bar Card

- (NSView *)buildTopControlBar {
    NSView *container = [self createCardView];

    // Status Pill
    self.statusPillBox = [NSBox new];
    self.statusPillBox.boxType = NSBoxCustom;
    self.statusPillBox.cornerRadius = 11.0;
    self.statusPillBox.borderWidth = 1.0;
    self.statusPillBox.translatesAutoresizingMaskIntoConstraints = NO;

    self.statusLEDView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 8, 8)];
    self.statusLEDView.wantsLayer = YES;
    self.statusLEDView.layer.cornerRadius = 4.0;
    self.statusLEDView.layer.backgroundColor = [NSColor systemGrayColor].CGColor;
    self.statusLEDView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusLEDView.widthAnchor constraintEqualToConstant:8].active = YES;
    [self.statusLEDView.heightAnchor constraintEqualToConstant:8].active = YES;

    self.statusLabel = [NSTextField labelWithString:@"Checking AD-508 Cable..."];
    self.statusLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *pillStack = [NSStackView stackViewWithViews:@[self.statusLEDView, self.statusLabel]];
    pillStack.spacing = 6.0;
    pillStack.alignment = NSLayoutAttributeCenterY;
    pillStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusPillBox.contentView = pillStack;

    // Master "LISTEN LIVE" Button
    self.monitorToggleButton = [NSButton buttonWithTitle:@"LISTEN LIVE" target:self action:@selector(toggleMonitoring)];
    self.monitorToggleButton.bezelStyle = NSBezelStyleRegularSquare;
    self.monitorToggleButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    self.monitorToggleButton.wantsLayer = YES;
    self.monitorToggleButton.layer.cornerRadius = 5.0;
    self.monitorToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.monitorToggleButton.heightAnchor constraintEqualToConstant:28].active = YES;
    [self.monitorToggleButton.widthAnchor constraintEqualToConstant:125].active = YES;
    [self updateMonitorButtonAppearance];

    // Mute Button
    self.muteButton = [NSButton buttonWithTitle:@"Mute" target:self action:@selector(toggleMute:)];
    self.muteButton.bezelStyle = NSBezelStyleRounded;
    self.muteButton.controlSize = NSControlSizeSmall;
    self.muteButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    self.muteButton.translatesAutoresizingMaskIntoConstraints = NO;

    // Dim (-20dB) Button
    self.dimButton = [NSButton buttonWithTitle:@"Dim -20dB" target:self action:@selector(toggleDim:)];
    self.dimButton.bezelStyle = NSBezelStyleRounded;
    self.dimButton.controlSize = NSControlSizeSmall;
    self.dimButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    self.dimButton.translatesAutoresizingMaskIntoConstraints = NO;

    // Record Button (Fixed icon position and explicit width)
    self.recordButton = [NSButton buttonWithTitle:@"Record" target:self action:@selector(toggleRecording:)];
    self.recordButton.bezelStyle = NSBezelStyleRounded;
    self.recordButton.controlSize = NSControlSizeSmall;
    self.recordButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.recordButton.imagePosition = NSImageLeading;
    self.recordButton.imageScaling = NSImageScaleProportionallyDown;
    if (@available(macOS 11.0, *)) {
        self.recordButton.image = [NSImage imageWithSystemSymbolName:@"record.circle.fill" accessibilityDescription:@"Record"];
        self.recordButton.contentTintColor = [NSColor systemRedColor];
    }
    self.recordButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.recordButton.widthAnchor constraintEqualToConstant:85].active = YES;

    // Recording Duration Pill
    self.recordDurationBox = [NSBox new];
    self.recordDurationBox.boxType = NSBoxCustom;
    self.recordDurationBox.cornerRadius = 4.0;
    self.recordDurationBox.borderWidth = 1.0;
    self.recordDurationBox.borderColor = [NSColor colorWithCalibratedRed:0.8 green:0.2 blue:0.2 alpha:0.4];
    self.recordDurationBox.fillColor = [NSColor colorWithCalibratedRed:0.8 green:0.1 blue:0.1 alpha:0.15];
    self.recordDurationBox.translatesAutoresizingMaskIntoConstraints = NO;
    [self.recordDurationBox.heightAnchor constraintEqualToConstant:22].active = YES;

    self.recordTimerLabel = [NSTextField labelWithString:@"00:00"];
    self.recordTimerLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightBold];
    self.recordTimerLabel.textColor = [NSColor systemRedColor];
    self.recordTimerLabel.alignment = NSTextAlignmentCenter;
    self.recordTimerLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.recordTimerLabel.widthAnchor constraintEqualToConstant:46].active = YES;

    NSView *recDot = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 6, 6)];
    recDot.wantsLayer = YES;
    recDot.layer.cornerRadius = 3.0;
    recDot.layer.backgroundColor = [NSColor systemRedColor].CGColor;
    recDot.translatesAutoresizingMaskIntoConstraints = NO;
    [recDot.widthAnchor constraintEqualToConstant:6].active = YES;
    [recDot.heightAnchor constraintEqualToConstant:6].active = YES;

    NSStackView *recPillStack = [NSStackView stackViewWithViews:@[recDot, self.recordTimerLabel]];
    recPillStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    recPillStack.alignment = NSLayoutAttributeCenterY;
    recPillStack.spacing = 4.0;
    recPillStack.translatesAutoresizingMaskIntoConstraints = NO;
    self.recordDurationBox.contentView = recPillStack;
    self.recordDurationBox.hidden = YES;

    self.revealRecordingsButton = [NSButton buttonWithTitle:@"Recordings ↗" target:self action:@selector(revealRecordings:)];
    self.revealRecordingsButton.bezelStyle = NSBezelStyleInline;
    self.revealRecordingsButton.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    self.revealRecordingsButton.translatesAutoresizingMaskIntoConstraints = NO;

    // Simulation Mode Checkbox
    self.simulationButton = [NSButton checkboxWithTitle:@"Demo Tone" target:self action:@selector(toggleSimulation:)];
    self.simulationButton.controlSize = NSControlSizeSmall;
    self.simulationButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightRegular];
    self.simulationButton.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *spacer = [NSView new];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSButton *quickLogButton = [NSButton buttonWithTitle:@"LOG QSO ↵" target:self action:@selector(quickLogClicked:)];
    quickLogButton.bezelStyle = NSBezelStyleRounded;
    quickLogButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
    quickLogButton.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(macOS 11.0, *)) {
        quickLogButton.image = [NSImage imageWithSystemSymbolName:@"square.and.pencil" accessibilityDescription:@"Log QSO"];
    }

    NSStackView *topRow1 = [NSStackView stackViewWithViews:@[
        self.statusPillBox,
        spacer,
        self.simulationButton,
        self.revealRecordingsButton,
        quickLogButton
    ]];
    topRow1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    topRow1.alignment = NSLayoutAttributeCenterY;
    topRow1.spacing = 8.0;

    // Instant Replay 15s Button
    self.instantReplayButton = [NSButton buttonWithTitle:@"↺ Replay 15s" target:self action:@selector(toggleInstantReplay:)];
    self.instantReplayButton.bezelStyle = NSBezelStyleRounded;
    self.instantReplayButton.controlSize = NSControlSizeSmall;
    self.instantReplayButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.instantReplayButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.instantReplayButton.widthAnchor constraintEqualToConstant:105].active = YES;

    NSView *spacer2 = [NSView new];
    spacer2.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer2 setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *topRow2 = [NSStackView stackViewWithViews:@[
        self.recordDurationBox,
        self.recordButton,
        self.instantReplayButton,
        self.dimButton,
        self.muteButton,
        spacer2,
        self.monitorToggleButton
    ]];
    topRow2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    topRow2.alignment = NSLayoutAttributeCenterY;
    topRow2.spacing = 8.0;

    NSStackView *hStack = [NSStackView stackViewWithViews:@[topRow1, topRow2]];
    hStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    hStack.alignment = NSLayoutAttributeLeading;
    hStack.spacing = 6.0;
    hStack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:hStack];

    [NSLayoutConstraint activateConstraints:@[
        [hStack.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [hStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [hStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [hStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
        [topRow1.widthAnchor constraintEqualToAnchor:hStack.widthAnchor],
        [topRow2.widthAnchor constraintEqualToAnchor:hStack.widthAnchor],
    ]];

    return container;
}

#pragma mark - Section 2: Visualizer Cockpit

- (NSView *)buildVisualizerSection {
    NSView *container = [self createCardView];

    // Visualizer View
    self.visualizerView = [[TX500AudioVisualizerView alloc] initWithFrame:NSZeroRect];
    self.visualizerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.visualizerView.heightAnchor constraintEqualToConstant:185].active = YES;

    // Bottom Controls Bar: View Mode, Speed, Span, Palette
    NSTextField *modeLbl = [NSTextField labelWithString:@"Display:"];
    modeLbl.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    modeLbl.textColor = [NSColor secondaryLabelColor];

    self.visualizerModeControl = [NSSegmentedControl segmentedControlWithLabels:@[@"Scope", @"Waterfall"]
                                                                   trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                         target:self
                                                                         action:@selector(visualizerModeChanged:)];
    self.visualizerModeControl.controlSize = NSControlSizeSmall;
    self.visualizerModeControl.selectedSegment = 0;

    NSTextField *speedLbl = [NSTextField labelWithString:@"Speed:"];
    speedLbl.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    speedLbl.textColor = [NSColor secondaryLabelColor];

    self.waterfallSpeedControl = [NSSegmentedControl segmentedControlWithLabels:@[@"Slow", @"Normal", @"Fast"]
                                                                   trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                         target:self
                                                                         action:@selector(waterfallSpeedChanged:)];
    self.waterfallSpeedControl.controlSize = NSControlSizeSmall;
    self.waterfallSpeedControl.selectedSegment = 1; // Normal

    NSTextField *spanLbl = [NSTextField labelWithString:@"Span:"];
    spanLbl.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    spanLbl.textColor = [NSColor secondaryLabelColor];

    self.frequencySpanControl = [NSSegmentedControl segmentedControlWithLabels:@[@"3 kHz", @"4 kHz", @"6 kHz", @"12 kHz"]
                                                                  trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                        target:self
                                                                        action:@selector(frequencySpanChanged:)];
    self.frequencySpanControl.controlSize = NSControlSizeSmall;
    self.frequencySpanControl.selectedSegment = 1; // 4 kHz

    // Waterfall Floor Slider & Label
    NSTextField *floorLbl = [NSTextField labelWithString:@"WF Floor:"];
    floorLbl.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    floorLbl.textColor = [NSColor secondaryLabelColor];

    self.waterfallFloorSlider = [NSSlider sliderWithValue:-80.0 minValue:-110.0 maxValue:-30.0 target:self action:@selector(waterfallFloorChanged:)];
    self.waterfallFloorSlider.controlSize = NSControlSizeSmall;
    self.waterfallFloorSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.waterfallFloorSlider.widthAnchor constraintEqualToConstant:65].active = YES;

    self.waterfallFloorLabel = [NSTextField labelWithString:@"-80dB"];
    self.waterfallFloorLabel.font = [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold];

    // Waterfall Contrast / Dynamic Range Slider & Label
    NSTextField *dynLbl = [NSTextField labelWithString:@"Contrast:"];
    dynLbl.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    dynLbl.textColor = [NSColor secondaryLabelColor];

    self.waterfallDynRangeSlider = [NSSlider sliderWithValue:50.0 minValue:15.0 maxValue:90.0 target:self action:@selector(waterfallDynRangeChanged:)];
    self.waterfallDynRangeSlider.controlSize = NSControlSizeSmall;
    self.waterfallDynRangeSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.waterfallDynRangeSlider.widthAnchor constraintEqualToConstant:65].active = YES;

    self.waterfallDynRangeLabel = [NSTextField labelWithString:@"50dB"];
    self.waterfallDynRangeLabel.font = [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold];

    NSTextField *themeLabel = [NSTextField labelWithString:@"Palette:"];
    themeLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    themeLabel.textColor = [NSColor secondaryLabelColor];

    self.visualThemeControl = [NSSegmentedControl segmentedControlWithLabels:@[@"Cyber Cyan", @"Phosphor Amber"]
                                                                trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                      target:self
                                                                      action:@selector(themeChanged:)];
    self.visualThemeControl.controlSize = NSControlSizeSmall;
    self.visualThemeControl.selectedSegment = 0;

    NSView *bottomSpacer = [NSView new];
    bottomSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [bottomSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *bRow1 = [NSStackView stackViewWithViews:@[
        modeLbl, self.visualizerModeControl,
        bottomSpacer,
        themeLabel, self.visualThemeControl
    ]];
    bRow1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bRow1.alignment = NSLayoutAttributeCenterY;
    bRow1.spacing = 6.0;

    NSStackView *bRow2 = [NSStackView stackViewWithViews:@[
        speedLbl, self.waterfallSpeedControl,
        spanLbl, self.frequencySpanControl,
        floorLbl, self.waterfallFloorSlider, self.waterfallFloorLabel,
        dynLbl, self.waterfallDynRangeSlider, self.waterfallDynRangeLabel
    ]];
    bRow2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    bRow2.alignment = NSLayoutAttributeCenterY;
    bRow2.spacing = 6.0;

    NSStackView *bottomBar = [NSStackView stackViewWithViews:@[bRow1, bRow2]];
    bottomBar.orientation = NSUserInterfaceLayoutOrientationVertical;
    bottomBar.alignment = NSLayoutAttributeLeading;
    bottomBar.spacing = 6.0;
    bottomBar.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *vStack = [NSStackView stackViewWithViews:@[self.visualizerView, bottomBar]];
    vStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    vStack.alignment = NSLayoutAttributeLeading;
    vStack.spacing = 4.0;
    vStack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:vStack];

    [NSLayoutConstraint activateConstraints:@[
        [vStack.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [vStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:6],
        [vStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-6],
        [vStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
        [self.visualizerView.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
        [bottomBar.widthAnchor constraintEqualToAnchor:vStack.widthAnchor]
    ]];

    return container;
}

#pragma mark - Section 3: Transceiver VFO & Quick Memory Bank

- (NSView *)buildTransceiverAndMemoryCard {
    NSView *vfoCard = [self buildVFOCockpitCard];
    NSView *memCard = [self buildMemoryBankCard];

    NSStackView *hStack = [NSStackView stackViewWithViews:@[vfoCard, memCard]];
    hStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hStack.distribution = NSStackViewDistributionFillEqually;
    hStack.spacing = 8.0;
    hStack.translatesAutoresizingMaskIntoConstraints = NO;
    return hStack;
}

- (NSView *)buildVFOCockpitCard {
    NSView *container = [self createCardView];

    NSTextField *title = [NSTextField labelWithString:@"TRANSCEIVER VFO & OPERATING MODE"];
    title.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    title.textColor = [NSColor secondaryLabelColor];

    // Digital Frequency Readout with Scroll Wheel Tuning
    TX500VFOTextField *vfoField = [TX500VFOTextField labelWithString:@"14.074.000 MHz"];
    vfoField.font = [NSFont monospacedSystemFontOfSize:17 weight:NSFontWeightHeavy];
    vfoField.textColor = [NSColor colorWithCalibratedRed:0.2 green:0.85 blue:0.95 alpha:1.0];
    vfoField.toolTip = @"Scroll with mouse wheel or trackpad to fine-tune VFO frequency";
    vfoField.translatesAutoresizingMaskIntoConstraints = NO;
    __weak typeof(self) weakSelf = self;
    vfoField.onScrolled = ^(NSInteger delta) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (delta > 0) {
            [strongSelf tuneStep:(NSInteger)[strongSelf currentVfoStepHz]];
        } else if (delta < 0) {
            [strongSelf tuneStep:-(NSInteger)[strongSelf currentVfoStepHz]];
        }
    };
    self.vfoFreqLabel = vfoField;

    self.vfoBandLabel = [NSTextField labelWithString:@"20m Band"];
    self.vfoBandLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    self.vfoBandLabel.textColor = [NSColor systemOrangeColor];

    self.sMeterLabel = [NSTextField labelWithString:@"[ ■■■■■■■□□□ S7 ]"];
    self.sMeterLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightMedium];
    self.sMeterLabel.textColor = [NSColor colorWithCalibratedRed:0.4 green:0.85 blue:0.5 alpha:1.0];

    NSStackView *freqHeaderStack = [NSStackView stackViewWithViews:@[self.vfoFreqLabel, self.vfoBandLabel, self.sMeterLabel]];
    freqHeaderStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    freqHeaderStack.alignment = NSLayoutAttributeBaseline;
    freqHeaderStack.spacing = 8.0;

    // Finer VFO Step Tuning Controls (10 Hz, 100 Hz, 500 Hz, 1 kHz, 5 kHz)
    self.vfoStepSegmentControl = [NSSegmentedControl segmentedControlWithLabels:@[@"10 Hz", @"100 Hz", @"500 Hz", @"1 kHz", @"5 kHz"]
                                                                  trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                        target:self
                                                                        action:@selector(vfoStepChanged:)];
    self.vfoStepSegmentControl.controlSize = NSControlSizeSmall;
    self.vfoStepSegmentControl.selectedSegment = 3; // Default 1 kHz
    self.vfoStepSegmentControl.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *stepDownBtn = [NSButton buttonWithTitle:@"◄ Step" target:self action:@selector(stepDownActive:)];
    NSButton *stepUpBtn = [NSButton buttonWithTitle:@"Step ►" target:self action:@selector(stepUpActive:)];
    for (NSButton *btn in @[stepDownBtn, stepUpBtn]) {
        btn.bezelStyle = NSBezelStyleRounded;
        btn.controlSize = NSControlSizeSmall;
        btn.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    }

    NSStackView *stepStack = [NSStackView stackViewWithViews:@[stepDownBtn, self.vfoStepSegmentControl, stepUpBtn]];
    stepStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stepStack.spacing = 4.0;

    // Operating Mode Switcher (LSB, USB, CW, AM, FM, DIG)
    NSTextField *modeHdr = [NSTextField labelWithString:@"Radio Mode (CAT):"];
    modeHdr.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];

    self.modeSegmentControl = [NSSegmentedControl segmentedControlWithLabels:@[@"LSB", @"USB", @"CW", @"AM", @"FM", @"DIG"]
                                                                trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                      target:self
                                                                      action:@selector(modeSegmentChanged:)];
    self.modeSegmentControl.controlSize = NSControlSizeSmall;
    self.modeSegmentControl.selectedSegment = 1; // Default USB
    self.modeSegmentControl.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *vStack = [NSStackView stackViewWithViews:@[
        title,
        freqHeaderStack,
        stepStack,
        modeHdr,
        self.modeSegmentControl
    ]];
    vStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    vStack.alignment = NSLayoutAttributeLeading;
    vStack.spacing = 4.0;
    vStack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:vStack];

    [NSLayoutConstraint activateConstraints:@[
        [vStack.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [vStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10],
        [vStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10],
        [vStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],
        [self.modeSegmentControl.widthAnchor constraintEqualToAnchor:vStack.widthAnchor]
    ]];

    return container;
}

- (NSView *)buildMemoryBankCard {
    NSView *container = [self createCardView];

    NSTextField *title = [NSTextField labelWithString:@"QUICK MEMORY BANK (1-CLICK TUNE)"];
    title.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    title.textColor = [NSColor secondaryLabelColor];

    // Dropdown of all saved memory bookmarks
    self.memoryPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.memoryPopup.controlSize = NSControlSizeSmall;
    self.memoryPopup.font = [NSFont systemFontOfSize:11];
    self.memoryPopup.target = self;
    self.memoryPopup.action = @selector(memoryPopupSelected:);
    self.memoryPopup.translatesAutoresizingMaskIntoConstraints = NO;

    self.addBookmarkButton = [NSButton buttonWithTitle:@"+ Bookmark Current" target:self action:@selector(addBookmarkClicked:)];
    self.addBookmarkButton.bezelStyle = NSBezelStyleRounded;
    self.addBookmarkButton.controlSize = NSControlSizeSmall;
    self.addBookmarkButton.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];

    self.renameBookmarkButton = [NSButton buttonWithTitle:@"Rename" target:self action:@selector(renameBookmarkClicked:)];
    self.renameBookmarkButton.bezelStyle = NSBezelStyleRounded;
    self.renameBookmarkButton.controlSize = NSControlSizeSmall;
    self.renameBookmarkButton.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];

    self.deleteBookmarkButton = [NSButton buttonWithTitle:@"Delete" target:self action:@selector(deleteBookmarkClicked:)];
    self.deleteBookmarkButton.bezelStyle = NSBezelStyleRounded;
    self.deleteBookmarkButton.controlSize = NSControlSizeSmall;
    self.deleteBookmarkButton.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];

    NSStackView *actionStack = [NSStackView stackViewWithViews:@[self.addBookmarkButton, self.renameBookmarkButton, self.deleteBookmarkButton]];
    actionStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actionStack.spacing = 4.0;

    // Quick Hotkey Chips Row
    NSTextField *chipsHdr = [NSTextField labelWithString:@"Quick Frequency Jumps:"];
    chipsHdr.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    chipsHdr.textColor = [NSColor secondaryLabelColor];

    NSArray<NSDictionary *> *quickChips = @[
        @{@"label": @"14.074 DIG", @"freq": @14074000, @"mode": @"DIG"},
        @{@"label": @"10.136 DIG", @"freq": @10136000, @"mode": @"DIG"},
        @{@"label": @"7.074 DIG",  @"freq": @7074000,  @"mode": @"DIG"},
        @{@"label": @"14.200 USB", @"freq": @14200000, @"mode": @"USB"},
        @{@"label": @"7.100 LSB",  @"freq": @7100000,  @"mode": @"LSB"},
        @{@"label": @"14.060 CW",  @"freq": @14060000, @"mode": @"CW"}
    ];

    NSMutableArray<NSButton *> *chipButtons = [NSMutableArray array];
    for (NSDictionary *d in quickChips) {
        NSButton *b = [NSButton buttonWithTitle:d[@"label"] target:self action:@selector(chipClicked:)];
        b.bezelStyle = NSBezelStyleInline;
        b.font = [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightMedium];
        b.identifier = [NSString stringWithFormat:@"%@|%@", d[@"freq"], d[@"mode"]];
        [chipButtons addObject:b];
    }

    self.memoryChipsStack = [NSStackView stackViewWithViews:chipButtons];
    self.memoryChipsStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.memoryChipsStack.spacing = 4.0;

    NSStackView *vStack = [NSStackView stackViewWithViews:@[
        title,
        self.memoryPopup,
        actionStack,
        chipsHdr,
        self.memoryChipsStack
    ]];
    vStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    vStack.alignment = NSLayoutAttributeLeading;
    vStack.spacing = 4.0;
    vStack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:vStack];

    [NSLayoutConstraint activateConstraints:@[
        [vStack.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [vStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10],
        [vStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10],
        [vStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],
        [self.memoryPopup.widthAnchor constraintEqualToAnchor:vStack.widthAnchor]
    ]];

    return container;
}

#pragma mark - Section 4: Middle Dual Columns

- (NSView *)buildMiddleSection {
    NSView *routingCard = [self buildRoutingCard];
    NSView *volumeCard = [self buildVolumeAndPanCard];

    NSStackView *hStack = [NSStackView stackViewWithViews:@[routingCard, volumeCard]];
    hStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hStack.distribution = NSStackViewDistributionFillEqually;
    hStack.spacing = 8.0;
    hStack.translatesAutoresizingMaskIntoConstraints = NO;
    return hStack;
}

- (NSView *)buildRoutingCard {
    NSView *container = [self createCardView];

    NSTextField *title = [NSTextField labelWithString:@"AUDIO HARDWARE & ROUTING"];
    title.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    title.textColor = [NSColor secondaryLabelColor];

    NSTextField *inLabel = [NSTextField labelWithString:@"Input (AD-508 / Radio):"];
    inLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.inputDevicePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.inputDevicePopup.controlSize = NSControlSizeSmall;
    self.inputDevicePopup.target = self;
    self.inputDevicePopup.action = @selector(inputDeviceSelected:);
    self.inputDevicePopup.font = [NSFont systemFontOfSize:11];
    self.inputDevicePopup.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *outLabel = [NSTextField labelWithString:@"Output (Speakers / Headphones):"];
    outLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.outputDevicePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.outputDevicePopup.controlSize = NSControlSizeSmall;
    self.outputDevicePopup.target = self;
    self.outputDevicePopup.action = @selector(outputDeviceSelected:);
    self.outputDevicePopup.font = [NSFont systemFontOfSize:11];
    self.outputDevicePopup.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *latLabel = [NSTextField labelWithString:@"Buffer Latency:"];
    latLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.bufferSizePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.bufferSizePopup.controlSize = NSControlSizeSmall;
    [self.bufferSizePopup addItemsWithTitles:@[@"Ultra-Low (5.3 ms • 256 frames)", @"Standard (10.6 ms • 512 frames)", @"Safe (21.3 ms • 1024 frames)"]];
    [self.bufferSizePopup selectItemAtIndex:1];
    self.bufferSizePopup.target = self;
    self.bufferSizePopup.action = @selector(bufferSizeSelected:);
    self.bufferSizePopup.font = [NSFont systemFontOfSize:11];
    self.bufferSizePopup.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *vStack = [NSStackView stackViewWithViews:@[
        title,
        inLabel, self.inputDevicePopup,
        outLabel, self.outputDevicePopup,
        latLabel, self.bufferSizePopup
    ]];
    vStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    vStack.alignment = NSLayoutAttributeLeading;
    vStack.spacing = 4.0;
    vStack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:vStack];

    [NSLayoutConstraint activateConstraints:@[
        [vStack.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [vStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10],
        [vStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10],
        [vStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],
        [self.inputDevicePopup.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
        [self.outputDevicePopup.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
        [self.bufferSizePopup.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
    ]];

    return container;
}

- (NSView *)buildVolumeAndPanCard {
    NSView *container = [self createCardView];

    NSTextField *title = [NSTextField labelWithString:@"VOLUME & STEREO BALANCE"];
    title.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    title.textColor = [NSColor secondaryLabelColor];

    NSTextField *volHeader = [NSTextField labelWithString:@"Master Volume:"];
    volHeader.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];

    self.volumeSlider = [NSSlider sliderWithValue:1.0 minValue:0.0 maxValue:2.0 target:self action:@selector(volumeChanged:)];
    self.volumeSlider.controlSize = NSControlSizeSmall;
    self.volumeSlider.translatesAutoresizingMaskIntoConstraints = NO;

    self.volumeValueLabel = [NSTextField labelWithString:@"100% (0.0 dB)"];
    self.volumeValueLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightBold];

    NSStackView *volRow = [NSStackView stackViewWithViews:@[volHeader, [NSView new], self.volumeValueLabel]];
    volRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    volRow.alignment = NSLayoutAttributeCenterY;
    [volRow.subviews[1] setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSTextField *panHeader = [NSTextField labelWithString:@"Stereo Balance / Pan:"];
    panHeader.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];

    self.balanceSlider = [NSSlider sliderWithValue:0.0 minValue:-1.0 maxValue:1.0 target:self action:@selector(balanceChanged:)];
    self.balanceSlider.controlSize = NSControlSizeSmall;
    self.balanceSlider.translatesAutoresizingMaskIntoConstraints = NO;

    self.balanceValueLabel = [NSTextField labelWithString:@"Center (L/R)"];
    self.balanceValueLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightBold];

    NSStackView *panRow = [NSStackView stackViewWithViews:@[panHeader, [NSView new], self.balanceValueLabel]];
    panRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    panRow.alignment = NSLayoutAttributeCenterY;
    [panRow.subviews[1] setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *vStack = [NSStackView stackViewWithViews:@[
        title,
        volRow, self.volumeSlider,
        panRow, self.balanceSlider
    ]];
    vStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    vStack.alignment = NSLayoutAttributeLeading;
    vStack.spacing = 4.0;
    vStack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:vStack];

    [NSLayoutConstraint activateConstraints:@[
        [vStack.topAnchor constraintEqualToAnchor:container.topAnchor constant:8],
        [vStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10],
        [vStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10],
        [vStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-8],
        [volRow.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
        [self.volumeSlider.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
        [panRow.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
        [self.balanceSlider.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
    ]];

    return container;
}

#pragma mark - Section 5: DSP Filter Rack

- (NSView *)buildDSPFilterRack {
    NSView *container = [self createCardView];

    NSTextField *title = [NSTextField labelWithString:@"DSP FILTER & AUDIO ENHANCEMENT RACK"];
    title.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    title.textColor = [NSColor secondaryLabelColor];

    // Presets Row
    NSTextField *presetLabel = [NSTextField labelWithString:@"Preset Mode:"];
    presetLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];

    self.presetSegmentedControl = [NSSegmentedControl segmentedControlWithLabels:@[
        @"SSB Voice", @"SSB Wide", @"CW Narrow", @"AM Broadcast", @"DX Boost", @"Flat / Direct"
    ] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(presetChanged:)];
    self.presetSegmentedControl.controlSize = NSControlSizeSmall;
    self.presetSegmentedControl.selectedSegment = 0;
    self.presetSegmentedControl.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *presetRow = [NSStackView stackViewWithViews:@[presetLabel, self.presetSegmentedControl]];
    presetRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    presetRow.spacing = 8.0;

    // Cutoff Sliders Row
    NSTextField *lowLabel = [NSTextField labelWithString:@"Low-Cut (HPF):"];
    lowLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    self.lowCutValueLabel = [NSTextField labelWithString:@"300 Hz"];
    self.lowCutValueLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightBold];
    self.lowCutSlider = [NSSlider sliderWithValue:300 minValue:50 maxValue:1000 target:self action:@selector(lowCutChanged:)];
    self.lowCutSlider.controlSize = NSControlSizeSmall;
    self.lowCutSlider.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *lowStack = [NSStackView stackViewWithViews:@[lowLabel, [NSView new], self.lowCutValueLabel]];
    lowStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    [lowStack.subviews[1] setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSTextField *highLabel = [NSTextField labelWithString:@"High-Cut (LPF):"];
    highLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    self.highCutValueLabel = [NSTextField labelWithString:@"2700 Hz"];
    self.highCutValueLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightBold];
    self.highCutSlider = [NSSlider sliderWithValue:2700 minValue:1000 maxValue:5000 target:self action:@selector(highCutChanged:)];
    self.highCutSlider.controlSize = NSControlSizeSmall;
    self.highCutSlider.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *highStack = [NSStackView stackViewWithViews:@[highLabel, [NSView new], self.highCutValueLabel]];
    highStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    [highStack.subviews[1] setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *lowCol = [NSStackView stackViewWithViews:@[lowStack, self.lowCutSlider]];
    lowCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    lowCol.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *highCol = [NSStackView stackViewWithViews:@[highStack, self.highCutSlider]];
    highCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    highCol.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *cutRow = [NSStackView stackViewWithViews:@[lowCol, highCol]];
    cutRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    cutRow.distribution = NSStackViewDistributionFillEqually;
    cutRow.spacing = 16.0;
    cutRow.translatesAutoresizingMaskIntoConstraints = NO;

    // Notch & Auto-Notch Column
    self.notchCheckbox = [NSButton checkboxWithTitle:@"Notch" target:self action:@selector(notchToggled:)];
    self.notchCheckbox.controlSize = NSControlSizeSmall;
    self.notchCheckbox.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];

    self.autoNotchCheckbox = [NSButton checkboxWithTitle:@"Auto-Notch (ANF)" target:self action:@selector(autoNotchToggled:)];
    self.autoNotchCheckbox.controlSize = NSControlSizeSmall;
    self.autoNotchCheckbox.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];

    self.notchFreqValueLabel = [NSTextField labelWithString:@"1000 Hz"];
    self.notchFreqValueLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightBold];

    self.notchFreqSlider = [NSSlider sliderWithValue:1000 minValue:200 maxValue:3500 target:self action:@selector(notchFreqChanged:)];
    self.notchFreqSlider.controlSize = NSControlSizeSmall;
    self.notchFreqSlider.enabled = NO;
    self.notchFreqSlider.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *notchHeader = [NSStackView stackViewWithViews:@[self.notchCheckbox, self.autoNotchCheckbox, [NSView new], self.notchFreqValueLabel]];
    notchHeader.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    notchHeader.alignment = NSLayoutAttributeCenterY;
    notchHeader.spacing = 6.0;
    [notchHeader.subviews[2] setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *notchCol = [NSStackView stackViewWithViews:@[notchHeader, self.notchFreqSlider]];
    notchCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    notchCol.translatesAutoresizingMaskIntoConstraints = NO;

    // Squelch Column
    self.squelchLED = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 7, 7)];
    self.squelchLED.wantsLayer = YES;
    self.squelchLED.layer.cornerRadius = 3.5;
    self.squelchLED.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.2 green:0.85 blue:0.4 alpha:1.0].CGColor;
    self.squelchLED.translatesAutoresizingMaskIntoConstraints = NO;
    [self.squelchLED.widthAnchor constraintEqualToConstant:7].active = YES;
    [self.squelchLED.heightAnchor constraintEqualToConstant:7].active = YES;

    self.squelchCheckbox = [NSButton checkboxWithTitle:@"Noise Squelch" target:self action:@selector(squelchToggled:)];
    self.squelchCheckbox.controlSize = NSControlSizeSmall;
    self.squelchCheckbox.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];

    self.squelchValueLabel = [NSTextField labelWithString:@"-65 dB"];
    self.squelchValueLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightBold];

    self.squelchThresholdSlider = [NSSlider sliderWithValue:-65 minValue:-80 maxValue:-20 target:self action:@selector(squelchThresholdChanged:)];
    self.squelchThresholdSlider.controlSize = NSControlSizeSmall;
    self.squelchThresholdSlider.enabled = NO;
    self.squelchThresholdSlider.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *sqHeader = [NSStackView stackViewWithViews:@[self.squelchLED, self.squelchCheckbox, [NSView new], self.squelchValueLabel]];
    sqHeader.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    sqHeader.alignment = NSLayoutAttributeCenterY;
    sqHeader.spacing = 4.0;
    [sqHeader.subviews[2] setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *sqCol = [NSStackView stackViewWithViews:@[sqHeader, self.squelchThresholdSlider]];
    sqCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    sqCol.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *notchSqRow = [NSStackView stackViewWithViews:@[notchCol, sqCol]];
    notchSqRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    notchSqRow.distribution = NSStackViewDistributionFillEqually;
    notchSqRow.spacing = 16.0;
    notchSqRow.translatesAutoresizingMaskIntoConstraints = NO;

    // LMS Noise Reduction & AGC Limiter Row
    self.nrCheckbox = [NSButton checkboxWithTitle:@"LMS Noise Reduction (NR)" target:self action:@selector(nrToggled:)];
    self.nrCheckbox.controlSize = NSControlSizeSmall;
    self.nrCheckbox.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];

    self.nrDepthValueLabel = [NSTextField labelWithString:@"Depth: 5"];
    self.nrDepthValueLabel.font = [NSFont monospacedSystemFontOfSize:10 weight:NSFontWeightBold];

    self.nrDepthSlider = [NSSlider sliderWithValue:5 minValue:1 maxValue:10 target:self action:@selector(nrDepthChanged:)];
    self.nrDepthSlider.controlSize = NSControlSizeSmall;
    self.nrDepthSlider.enabled = NO;
    self.nrDepthSlider.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *nrHeader = [NSStackView stackViewWithViews:@[self.nrCheckbox, [NSView new], self.nrDepthValueLabel]];
    nrHeader.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    nrHeader.alignment = NSLayoutAttributeCenterY;
    [nrHeader.subviews[1] setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *nrCol = [NSStackView stackViewWithViews:@[nrHeader, self.nrDepthSlider]];
    nrCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    nrCol.translatesAutoresizingMaskIntoConstraints = NO;

    self.limiterCheckbox = [NSButton checkboxWithTitle:@"Ear Protection Limiter (AGC Knee)" target:self action:@selector(limiterToggled:)];
    self.limiterCheckbox.controlSize = NSControlSizeSmall;
    self.limiterCheckbox.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    self.limiterCheckbox.state = NSControlStateValueOn;

    NSTextField *limiterHint = [NSTextField labelWithString:@"Soft-knee clipping & fast attack limiter"];
    limiterHint.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightRegular];
    limiterHint.textColor = [NSColor secondaryLabelColor];

    NSStackView *limiterCol = [NSStackView stackViewWithViews:@[self.limiterCheckbox, limiterHint]];
    limiterCol.orientation = NSUserInterfaceLayoutOrientationVertical;
    limiterCol.alignment = NSLayoutAttributeLeading;
    limiterCol.spacing = 3.0;
    limiterCol.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *nrLimiterRow = [NSStackView stackViewWithViews:@[nrCol, limiterCol]];
    nrLimiterRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    nrLimiterRow.distribution = NSStackViewDistributionFillEqually;
    nrLimiterRow.spacing = 16.0;
    nrLimiterRow.translatesAutoresizingMaskIntoConstraints = NO;

    // 3-Band Speech EQ Row
    self.eqCheckbox = [NSButton checkboxWithTitle:@"3-Band Speech Equalizer" target:self action:@selector(eqToggled:)];
    self.eqCheckbox.controlSize = NSControlSizeSmall;
    self.eqCheckbox.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];

    NSTextField *eqHint = [NSTextField labelWithString:@"(Low 250 Hz • Mid 1.8 kHz • High 3.2 kHz)"];
    eqHint.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightRegular];
    eqHint.textColor = [NSColor secondaryLabelColor];

    NSStackView *eqTitleRow = [NSStackView stackViewWithViews:@[self.eqCheckbox, eqHint]];
    eqTitleRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    eqTitleRow.spacing = 6.0;

    // Low EQ (250 Hz)
    NSTextField *lowEqTitle = [NSTextField labelWithString:@"Low 250Hz:"];
    lowEqTitle.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium];
    self.eqLowLabel = [NSTextField labelWithString:@"0.0 dB"];
    self.eqLowLabel.font = [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold];
    NSStackView *lowEqHdr = [NSStackView stackViewWithViews:@[lowEqTitle, [NSView new], self.eqLowLabel]];
    lowEqHdr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    [lowEqHdr.subviews[1] setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.eqLowSlider = [NSSlider sliderWithValue:0.0 minValue:-12.0 maxValue:12.0 target:self action:@selector(eqLowChanged:)];
    self.eqLowSlider.controlSize = NSControlSizeSmall;
    self.eqLowSlider.enabled = NO;
    self.eqLowSlider.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *eqLowCol = [NSStackView stackViewWithViews:@[lowEqHdr, self.eqLowSlider]];
    eqLowCol.orientation = NSUserInterfaceLayoutOrientationVertical;

    // Mid EQ (1.8 kHz)
    NSTextField *midEqTitle = [NSTextField labelWithString:@"Mid 1.8kHz:"];
    midEqTitle.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium];
    self.eqMidLabel = [NSTextField labelWithString:@"0.0 dB"];
    self.eqMidLabel.font = [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold];
    NSStackView *midEqHdr = [NSStackView stackViewWithViews:@[midEqTitle, [NSView new], self.eqMidLabel]];
    midEqHdr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    [midEqHdr.subviews[1] setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.eqMidSlider = [NSSlider sliderWithValue:0.0 minValue:-12.0 maxValue:12.0 target:self action:@selector(eqMidChanged:)];
    self.eqMidSlider.controlSize = NSControlSizeSmall;
    self.eqMidSlider.enabled = NO;
    self.eqMidSlider.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *eqMidCol = [NSStackView stackViewWithViews:@[midEqHdr, self.eqMidSlider]];
    eqMidCol.orientation = NSUserInterfaceLayoutOrientationVertical;

    // High EQ (3.2 kHz)
    NSTextField *highEqTitle = [NSTextField labelWithString:@"High 3.2kHz:"];
    highEqTitle.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium];
    self.eqHighLabel = [NSTextField labelWithString:@"0.0 dB"];
    self.eqHighLabel.font = [NSFont monospacedSystemFontOfSize:9.5 weight:NSFontWeightBold];
    NSStackView *highEqHdr = [NSStackView stackViewWithViews:@[highEqTitle, [NSView new], self.eqHighLabel]];
    highEqHdr.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    [highEqHdr.subviews[1] setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.eqHighSlider = [NSSlider sliderWithValue:0.0 minValue:-12.0 maxValue:12.0 target:self action:@selector(eqHighChanged:)];
    self.eqHighSlider.controlSize = NSControlSizeSmall;
    self.eqHighSlider.enabled = NO;
    self.eqHighSlider.translatesAutoresizingMaskIntoConstraints = NO;
    NSStackView *eqHighCol = [NSStackView stackViewWithViews:@[highEqHdr, self.eqHighSlider]];
    eqHighCol.orientation = NSUserInterfaceLayoutOrientationVertical;

    NSStackView *eqSlidersRow = [NSStackView stackViewWithViews:@[eqLowCol, eqMidCol, eqHighCol]];
    eqSlidersRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    eqSlidersRow.distribution = NSStackViewDistributionFillEqually;
    eqSlidersRow.spacing = 12.0;
    eqSlidersRow.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *vStack = [NSStackView stackViewWithViews:@[
        title,
        presetRow,
        cutRow,
        notchSqRow,
        nrLimiterRow,
        eqTitleRow,
        eqSlidersRow
    ]];
    vStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    vStack.alignment = NSLayoutAttributeLeading;
    vStack.spacing = 5.0;
    vStack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:vStack];

    [NSLayoutConstraint activateConstraints:@[
        [vStack.topAnchor constraintEqualToAnchor:container.topAnchor constant:7],
        [vStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10],
        [vStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10],
        [vStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-7],
        [cutRow.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
        [notchSqRow.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
        [nrLimiterRow.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
        [eqSlidersRow.widthAnchor constraintEqualToAnchor:vStack.widthAnchor]
    ]];

    return container;
}

#pragma mark - Section 6: Cable Guide Card

- (NSView *)buildCableGuideCard {
    NSView *container = [self createCardView];

    self.guideDisclosureButton = [NSButton buttonWithTitle:(_isGuideCollapsed ? @"▶ AD-508 HARDWARE CABLING & OPERATION GUIDE" : @"▼ AD-508 HARDWARE CABLING & OPERATION GUIDE")
                                                    target:self
                                                    action:@selector(toggleCableGuide:)];
    self.guideDisclosureButton.bezelStyle = NSBezelStyleInline;
    self.guideDisclosureButton.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    self.guideDisclosureButton.contentTintColor = [NSColor secondaryLabelColor];

    self.guideContentLabel = [NSTextField wrappingLabelWithString:
        @"• Hardware Connection: Connect the 7-pin GX12 connector of your official Lab599 AD-508 cable to the TX-500 REM/DATA port. Connect the USB-C end directly to your Mac. macOS natively recognizes the built-in USB Audio Class codec without third-party drivers.\n"
        @"• Transceiver Settings: For cleanest audio, adjust the radio's AF Gain knob or set DIG Audio Level (Menu 27/28) to nominal. Click 'LISTEN LIVE' to monitor radio audio with ultra-low latency directly on your laptop speakers or headphones."
    ];
    self.guideContentLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.guideContentLabel setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.guideContentLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    self.guideContentLabel.textColor = [NSColor secondaryLabelColor];
    self.guideContentLabel.hidden = _isGuideCollapsed;

    NSStackView *vStack = [NSStackView stackViewWithViews:@[self.guideDisclosureButton, self.guideContentLabel]];
    vStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    vStack.alignment = NSLayoutAttributeLeading;
    vStack.spacing = 4.0;
    vStack.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:vStack];

    [NSLayoutConstraint activateConstraints:@[
        [vStack.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [vStack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10],
        [vStack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10],
        [vStack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
        [self.guideContentLabel.widthAnchor constraintEqualToAnchor:vStack.widthAnchor]
    ]];

    return container;
}

#pragma mark - Device & Status Updates

- (void)updateDeviceMenus {
    [self.inputDevicePopup removeAllItems];
    for (TX500AudioDeviceItem *item in self.engine.inputDevices) {
        NSString *disp = item.name;
        if (item.isAD508) {
            disp = [NSString stringWithFormat:@"★ %@ (AD-508 USB-C)", item.name];
        } else if (item.isUSB) {
            disp = [NSString stringWithFormat:@"★ %@ (Radio USB Audio)", item.name];
        } else if (item.isVirtual) {
            disp = [NSString stringWithFormat:@"%@ (Virtual)", item.name];
        }
        [self.inputDevicePopup addItemWithTitle:disp];
        self.inputDevicePopup.lastItem.representedObject = item.uid;
        if ([item.uid isEqualToString:self.engine.selectedInputDeviceUID]) {
            [self.inputDevicePopup selectItem:self.inputDevicePopup.lastItem];
        }
    }
    [self.inputDevicePopup.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *refreshIn = [[NSMenuItem alloc] initWithTitle:@"🔄 Refresh Audio Devices..." action:@selector(refreshAudioDevicesAction:) keyEquivalent:@""];
    refreshIn.target = self;
    refreshIn.representedObject = @"__REFRESH__";
    [self.inputDevicePopup.menu addItem:refreshIn];

    [self.outputDevicePopup removeAllItems];
    for (TX500AudioDeviceItem *item in self.engine.outputDevices) {
        NSString *disp = item.name;
        if (item.isAD508) {
            disp = [NSString stringWithFormat:@"★ %@ (AD-508 USB-C)", item.name];
        } else if (item.isUSB) {
            disp = [NSString stringWithFormat:@"★ %@ (Radio USB Audio)", item.name];
        } else if (item.isVirtual) {
            disp = [NSString stringWithFormat:@"%@ (Virtual)", item.name];
        }
        [self.outputDevicePopup addItemWithTitle:disp];
        self.outputDevicePopup.lastItem.representedObject = item.uid;
        if ([item.uid isEqualToString:self.engine.selectedOutputDeviceUID]) {
            [self.outputDevicePopup selectItem:self.outputDevicePopup.lastItem];
        }
    }
    [self.outputDevicePopup.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *refreshOut = [[NSMenuItem alloc] initWithTitle:@"🔄 Refresh Audio Devices..." action:@selector(refreshAudioDevicesAction:) keyEquivalent:@""];
    refreshOut.target = self;
    refreshOut.representedObject = @"__REFRESH__";
    [self.outputDevicePopup.menu addItem:refreshOut];
}

- (void)refreshAudioDevicesAction:(id)sender {
    (void)sender;
    [self.engine refreshDevices];
    [self updateDeviceMenus];
    [self updateHardwareStatusPill];
}

- (void)updateHardwareStatusPill {
    if (self.engine.isAD508Connected) {
        self.statusLEDView.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.16 green:0.82 blue:0.25 alpha:1.0].CGColor;
        self.statusLabel.stringValue = [NSString stringWithFormat:@"AD-508 Connected: %@", self.engine.ad508DeviceName ?: @"USB Audio"];
        self.statusLabel.textColor = [NSColor colorWithCalibratedRed:0.12 green:0.68 blue:0.22 alpha:1.0];
        self.statusPillBox.fillColor = [NSColor colorWithCalibratedRed:0.16 green:0.82 blue:0.25 alpha:0.14];
        self.statusPillBox.borderColor = [NSColor colorWithCalibratedRed:0.16 green:0.82 blue:0.25 alpha:0.40];
    } else {
        self.statusLEDView.layer.backgroundColor = [NSColor systemOrangeColor].CGColor;
        self.statusLabel.stringValue = @"AD-508 Not Detected (Using Default Input)";
        self.statusLabel.textColor = [NSColor systemOrangeColor];
        self.statusPillBox.fillColor = [NSColor colorWithCalibratedRed:1.0 green:0.6 blue:0.0 alpha:0.10];
        self.statusPillBox.borderColor = [NSColor colorWithCalibratedRed:1.0 green:0.6 blue:0.0 alpha:0.30];
    }
}

- (void)updateMonitorButtonAppearance {
    if (self.engine.isMonitoring) {
        self.monitorToggleButton.title = @"MONITOR ACTIVE";
        self.monitorToggleButton.layer.backgroundColor = [NSColor colorWithCalibratedRed:0.10 green:0.75 blue:0.35 alpha:0.25].CGColor;
        self.monitorToggleButton.layer.borderColor = [NSColor colorWithCalibratedRed:0.10 green:0.85 blue:0.35 alpha:0.8].CGColor;
        self.monitorToggleButton.layer.borderWidth = 1.5;
        self.monitorToggleButton.contentTintColor = [NSColor colorWithCalibratedRed:0.10 green:0.85 blue:0.35 alpha:1.0];
    } else {
        self.monitorToggleButton.title = @"LISTEN LIVE";
        self.monitorToggleButton.layer.backgroundColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.15].CGColor;
        self.monitorToggleButton.layer.borderColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.4].CGColor;
        self.monitorToggleButton.layer.borderWidth = 1.0;
        self.monitorToggleButton.contentTintColor = [NSColor controlAccentColor];
    }
}

#pragma mark - VFO & Memory Helpers

+ (NSString *)bandNameForFrequencyHz:(uint64_t)hz {
    if (hz >= 1800000 && hz <= 2000000) return @"160m Band";
    if (hz >= 3500000 && hz <= 4000000) return @"80m Band";
    if (hz >= 5351500 && hz <= 5366500) return @"60m Band";
    if (hz >= 7000000 && hz <= 7300000) return @"40m Band";
    if (hz >= 10100000 && hz <= 10150000) return @"30m Band";
    if (hz >= 14000000 && hz <= 14350000) return @"20m Band";
    if (hz >= 18068000 && hz <= 18168000) return @"17m Band";
    if (hz >= 21000000 && hz <= 21450000) return @"15m Band";
    if (hz >= 24890000 && hz <= 24990000) return @"12m Band";
    if (hz >= 28000000 && hz <= 29700000) return @"10m Band";
    if (hz >= 50000000 && hz <= 54000000) return @"6m Band";
    if (hz >= 144000000 && hz <= 148000000) return @"2m Band";
    if (hz < 1800000) return @"MW / LF Band";
    return @"General Coverage";
}

+ (NSString *)sMeterBarForLevel:(NSInteger)level {
    NSInteger filled = MIN(10, MAX(0, (level * 10) / 15));
    NSMutableString *bar = [NSMutableString string];
    for (NSInteger i = 0; i < 10; i++) {
        [bar appendString:(i < filled ? @"■" : @"□")];
    }
    NSString *unit;
    if (level <= 9) {
        unit = [NSString stringWithFormat:@"S%ld", (long)level];
    } else {
        NSInteger over = (level - 9) * 10;
        unit = [NSString stringWithFormat:@"S9+%lddB", (long)over];
    }
    return [NSString stringWithFormat:@"[ %@ %@ ]", bar, unit];
}

- (void)updateVFOReadout {
    double mhz = (double)self.currentFrequencyHz / 1000000.0;
    self.vfoFreqLabel.stringValue = [NSString stringWithFormat:@"%.3f MHz", mhz];
    self.vfoBandLabel.stringValue = [TX500AudioMonitorController bandNameForFrequencyHz:self.currentFrequencyHz];
    self.sMeterLabel.stringValue = [TX500AudioMonitorController sMeterBarForLevel:self.currentSMeter];
}

- (void)reloadMemoryPopup {
    [self.memoryPopup removeAllItems];
    for (NSDictionary *d in self.mutableBookmarks) {
        double mhz = [d[@"freq"] doubleValue] / 1000000.0;
        NSString *title = [NSString stringWithFormat:@"%@ • %.3f MHz (%@)", d[@"label"], mhz, d[@"mode"]];
        [self.memoryPopup addItemWithTitle:title];
    }
}

#pragma mark - VFO & CAT Actions

- (uint64_t)currentVfoStepHz {
    switch (self.vfoStepSegmentControl.selectedSegment) {
        case 0: return 10;
        case 1: return 100;
        case 2: return 500;
        case 3: return 1000;
        case 4: return 5000;
        default: return 1000;
    }
}

- (void)vfoStepChanged:(NSSegmentedControl *)sender {
    (void)sender;
    _currentTuningStepHz = [self currentVfoStepHz];
}

- (void)stepDownActive:(id)sender {
    (void)sender;
    [self tuneStep:-(NSInteger)[self currentVfoStepHz]];
}

- (void)stepUpActive:(id)sender {
    (void)sender;
    [self tuneStep:(NSInteger)[self currentVfoStepHz]];
}

- (void)stepDown5k:(id)sender { [self tuneStep:-5000]; }
- (void)stepDown1k:(id)sender { [self tuneStep:-1000]; }
- (void)stepUp1k:(id)sender   { [self tuneStep:1000]; }
- (void)stepUp5k:(id)sender   { [self tuneStep:5000]; }

- (void)tuneStep:(NSInteger)deltaHz {
    int64_t newHz = (int64_t)self.currentFrequencyHz + deltaHz;
    if (newHz < 100000) newHz = 100000;
    if (newHz > 160000000) newHz = 160000000;
    [self tuneRadioToFrequencyHz:(uint64_t)newHz];
}

- (void)tuneRadioToFrequencyHz:(uint64_t)freqHz {
    _currentFrequencyHz = freqHz;
    [self updateVFOReadout];
    NSString *faCmd = [NSString stringWithFormat:@"FA%011llu;", (unsigned long long)freqHz];
    if (self.serialCommandSender) {
        self.serialCommandSender(faCmd);
    }
    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"Tuned VFO to %.3f MHz via CAT.", (double)freqHz / 1e6]);
    }
}

- (void)setRadioMode:(NSString *)mode {
    _currentMode = [mode copy];
    NSArray *modes = @[@"LSB", @"USB", @"CW", @"AM", @"FM", @"DIG"];
    NSInteger idx = [modes indexOfObject:mode];
    if (idx != NSNotFound) {
        self.modeSegmentControl.selectedSegment = idx;
    }

    NSString *cmd = @"MD2;";
    if ([mode isEqualToString:@"LSB"]) cmd = @"MD1;";
    else if ([mode isEqualToString:@"USB"]) cmd = @"MD2;";
    else if ([mode isEqualToString:@"CW"])  cmd = @"MD3;";
    else if ([mode isEqualToString:@"FM"])  cmd = @"MD4;";
    else if ([mode isEqualToString:@"AM"])  cmd = @"MD5;";
    else if ([mode isEqualToString:@"DIG"]) cmd = @"MD6;";

    if (self.serialCommandSender) {
        self.serialCommandSender(cmd);
    }

    // Auto-align DSP filter preset for best acoustics
    if ([mode isEqualToString:@"CW"]) {
        self.presetSegmentedControl.selectedSegment = 2; // CW Narrow
        [self presetChanged:self.presetSegmentedControl];
    } else if ([mode isEqualToString:@"AM"]) {
        self.presetSegmentedControl.selectedSegment = 3; // AM Broadcast
        [self presetChanged:self.presetSegmentedControl];
    } else if ([mode isEqualToString:@"DIG"]) {
        self.presetSegmentedControl.selectedSegment = 5; // Flat / Direct
        [self presetChanged:self.presetSegmentedControl];
    } else {
        self.presetSegmentedControl.selectedSegment = 0; // SSB Voice
        [self presetChanged:self.presetSegmentedControl];
    }

    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"Transceiver operating mode switched to %@ (CAT: %@).", mode, cmd]);
    }
}

- (void)modeSegmentChanged:(NSSegmentedControl *)sender {
    NSArray *modes = @[@"LSB", @"USB", @"CW", @"AM", @"FM", @"DIG"];
    NSInteger idx = sender.selectedSegment;
    if (idx >= 0 && idx < (NSInteger)modes.count) {
        [self setRadioMode:modes[idx]];
    }
}

#pragma mark - Memory Bank Actions

- (void)memoryPopupSelected:(NSPopUpButton *)sender {
    NSInteger idx = sender.indexOfSelectedItem;
    if (idx >= 0 && idx < (NSInteger)self.mutableBookmarks.count) {
        NSDictionary *item = self.mutableBookmarks[idx];
        uint64_t freq = [item[@"freq"] unsignedLongLongValue];
        NSString *mode = item[@"mode"];
        if (freq > 0) [self tuneRadioToFrequencyHz:freq];
        if (mode.length > 0) [self setRadioMode:mode];
    }
}

- (void)chipClicked:(NSButton *)sender {
    NSString *info = sender.identifier;
    if (!info) return;
    NSArray *parts = [info componentsSeparatedByString:@"|"];
    if (parts.count >= 2) {
        uint64_t freq = (uint64_t)[parts[0] longLongValue];
        NSString *mode = parts[1];
        if (freq > 0) [self tuneRadioToFrequencyHz:freq];
        if (mode.length > 0) [self setRadioMode:mode];
    }
}

- (void)addBookmarkClicked:(id)sender {
    (void)sender;
    double mhz = (double)self.currentFrequencyHz / 1e6;
    NSString *band = [TX500AudioMonitorController bandNameForFrequencyHz:self.currentFrequencyHz];
    NSString *suggestedName = [NSString stringWithFormat:@"%@ - %.3f MHz", band, mhz];

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Bookmark Current Frequency";
    alert.informativeText = [NSString stringWithFormat:@"Enter a custom name for %.3f MHz (%@):", mhz, self.currentMode ?: @"USB"];
    [alert addButtonWithTitle:@"Save Bookmark"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    input.stringValue = suggestedName;
    alert.accessoryView = input;
    [alert.window setInitialFirstResponder:input];

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        NSString *customName = [input.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (customName.length == 0) customName = suggestedName;
        [self bookmarkCurrentFrequencyWithLabel:customName];
    }
}

- (void)renameBookmarkClicked:(id)sender {
    (void)sender;
    NSInteger idx = self.memoryPopup.indexOfSelectedItem;
    if (idx < 0 || idx >= (NSInteger)self.mutableBookmarks.count) return;

    NSDictionary *current = self.mutableBookmarks[idx];
    NSString *currentLabel = current[@"label"] ?: @"";

    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Rename Frequency Bookmark";
    alert.informativeText = @"Enter a new name for this memory bookmark:";
    [alert addButtonWithTitle:@"Rename"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)];
    input.stringValue = currentLabel;
    alert.accessoryView = input;
    [alert.window setInitialFirstResponder:input];

    NSModalResponse response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        NSString *newName = [input.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (newName.length > 0) {
            NSMutableDictionary *mut = [current mutableCopy];
            mut[@"label"] = newName;
            self.mutableBookmarks[idx] = [mut copy];
            [self saveBookmarksStorage];
            [self reloadMemoryPopup];
            [self.memoryPopup selectItemAtIndex:idx];
            if (self.logHandler) {
                self.logHandler([NSString stringWithFormat:@"Renamed frequency bookmark to: %@", newName]);
            }
        }
    }
}

- (void)bookmarkCurrentFrequencyWithLabel:(nullable NSString *)label {
    NSString *finalLabel = label.length > 0 ? label : [NSString stringWithFormat:@"%.3f MHz", (double)self.currentFrequencyHz / 1e6];
    NSDictionary *entry = @{
        @"label": finalLabel,
        @"freq": @(self.currentFrequencyHz),
        @"mode": self.currentMode ?: @"USB"
    };
    [self.mutableBookmarks addObject:entry];
    [self saveBookmarksStorage];
    [self reloadMemoryPopup];
    [self.memoryPopup selectItemAtIndex:self.mutableBookmarks.count - 1];

    if (self.logHandler) {
        self.logHandler([NSString stringWithFormat:@"Saved frequency bookmark: %@ (%.3f MHz %@)", finalLabel, (double)self.currentFrequencyHz / 1e6, self.currentMode]);
    }
}

- (void)deleteBookmarkClicked:(id)sender {
    (void)sender;
    NSInteger idx = self.memoryPopup.indexOfSelectedItem;
    if (idx >= 0 && idx < (NSInteger)self.mutableBookmarks.count) {
        if (self.mutableBookmarks.count <= 1) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = @"Cannot Delete";
            alert.informativeText = @"At least one frequency bookmark must remain in the memory bank.";
            [alert runModal];
            return;
        }
        [self.mutableBookmarks removeObjectAtIndex:idx];
        [self saveBookmarksStorage];
        [self reloadMemoryPopup];
        if (self.logHandler) self.logHandler(@"Deleted selected frequency bookmark.");
    }
}

#pragma mark - Background CAT Sync

- (void)startCATSync {
    if (self.catPollTimer) return;
    self.catPollTimer = [NSTimer scheduledTimerWithTimeInterval:0.6 target:self selector:@selector(pollCATRadioState:) userInfo:nil repeats:YES];
}

- (void)stopCATSync {
    if (self.catPollTimer) {
        [self.catPollTimer invalidate];
        self.catPollTimer = nil;
    }
    self.isCATPolling = NO;
}

- (void)pollCATRadioState:(NSTimer *)timer {
    (void)timer;
    if (self.isCATPolling || !self.catQueryHandler) return;

    self.isCATPolling = YES;
    __weak typeof(self) weakSelf = self;

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.catQueryHandler) return;

        // 1. Query VFO Frequency (FA;)
        NSString *faReply = strongSelf.catQueryHandler(@"FA;", 0.25);
        uint64_t parsedHz = 0;
        if (faReply && [faReply hasPrefix:@"FA"] && faReply.length >= 13) {
            NSString *digits = [faReply substringWithRange:NSMakeRange(2, 11)];
            parsedHz = (uint64_t)[digits longLongValue];
        }

        // 2. Query Operating Mode (MD;)
        NSString *mdReply = strongSelf.catQueryHandler(@"MD;", 0.25);
        NSString *parsedMode = nil;
        if (mdReply && [mdReply hasPrefix:@"MD"] && mdReply.length >= 3) {
            unichar mChar = [mdReply characterAtIndex:2];
            switch (mChar) {
                case '1': parsedMode = @"LSB"; break;
                case '2': parsedMode = @"USB"; break;
                case '3': parsedMode = @"CW";  break;
                case '4': parsedMode = @"FM";  break;
                case '5': parsedMode = @"AM";  break;
                case '6': parsedMode = @"DIG"; break;
                case '7': parsedMode = @"CWR"; break;
                case '9': parsedMode = @"FSK"; break;
                default:  parsedMode = @"USB"; break;
            }
        }

        // 3. Query S-Meter (SM0;)
        NSString *smReply = strongSelf.catQueryHandler(@"SM0;", 0.25);
        NSInteger parsedSMeter = -1;
        if (smReply && [smReply hasPrefix:@"SM0"] && smReply.length >= 7) {
            NSString *sDigits = [smReply substringWithRange:NSMakeRange(3, 4)];
            parsedSMeter = [sDigits integerValue];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(weakSelf) uiSelf = weakSelf;
            if (!uiSelf) return;

            if (parsedHz > 100000 && parsedHz != uiSelf.currentFrequencyHz) {
                uiSelf.currentFrequencyHz = parsedHz;
                [uiSelf updateVFOReadout];
            }
            if (parsedMode.length > 0 && ![parsedMode isEqualToString:uiSelf.currentMode]) {
                uiSelf.currentMode = parsedMode;
                NSArray *modes = @[@"LSB", @"USB", @"CW", @"AM", @"FM", @"DIG"];
                NSInteger mIdx = [modes indexOfObject:parsedMode];
                if (mIdx != NSNotFound) {
                    uiSelf.modeSegmentControl.selectedSegment = mIdx;
                }
            }
            if (parsedSMeter >= 0) {
                uiSelf.currentSMeter = parsedSMeter;
                uiSelf.sMeterLabel.stringValue = [TX500AudioMonitorController sMeterBarForLevel:parsedSMeter];
            }

            uiSelf.isCATPolling = NO;
        });
    });
}

#pragma mark - Visualizer Actions

- (void)visualizerModeChanged:(NSSegmentedControl *)sender {
    self.visualizerView.displayMode = (TX500VisualizerMode)sender.selectedSegment;
}

- (void)waterfallSpeedChanged:(NSSegmentedControl *)sender {
    self.visualizerView.waterfallSpeed = (TX500WaterfallSpeed)sender.selectedSegment;
}

- (void)frequencySpanChanged:(NSSegmentedControl *)sender {
    switch (sender.selectedSegment) {
        case 0: self.visualizerView.maxFrequencySpanHz = 3000.0f; break;
        case 1: self.visualizerView.maxFrequencySpanHz = 4000.0f; break;
        case 2: self.visualizerView.maxFrequencySpanHz = 6000.0f; break;
        case 3: self.visualizerView.maxFrequencySpanHz = 12000.0f; break;
        default: self.visualizerView.maxFrequencySpanHz = 4000.0f; break;
    }
}

- (void)themeChanged:(NSSegmentedControl *)sender {
    self.visualizerView.phosphorAmberTheme = (sender.selectedSegment == 1);
}

- (void)waterfallFloorChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.visualizerView.waterfallFloorDb = val;
    self.waterfallFloorLabel.stringValue = [NSString stringWithFormat:@"%.0f dB", val];
}

- (void)waterfallDynRangeChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.visualizerView.waterfallDynamicRangeDb = val;
    self.waterfallDynRangeLabel.stringValue = [NSString stringWithFormat:@"%.0f dB", val];
}

#pragma mark - Actions

- (void)toggleInstantReplay:(id)sender {
    (void)sender;
    if (self.engine.isReplaying) {
        [self.engine stopInstantReplay];
        self.instantReplayButton.title = @"↺ Replay 15s";
        self.instantReplayButton.contentTintColor = nil;
    } else {
        [self.engine startInstantReplay];
        self.instantReplayButton.title = @"⏹ Stop Replay";
        self.instantReplayButton.contentTintColor = [NSColor systemOrangeColor];
        if (self.logHandler) {
            self.logHandler(@"Playing back last 15 seconds of monitored audio...");
        }
    }
}

- (void)toggleCableGuide:(id)sender {
    (void)sender;
    _isGuideCollapsed = !_isGuideCollapsed;
    [[NSUserDefaults standardUserDefaults] setBool:_isGuideCollapsed forKey:@"TX500_AudioCableGuideCollapsed"];
    self.guideDisclosureButton.title = _isGuideCollapsed ? @"▶ AD-508 HARDWARE CABLING & OPERATION GUIDE" : @"▼ AD-508 HARDWARE CABLING & OPERATION GUIDE";
    self.guideContentLabel.hidden = _isGuideCollapsed;
}

- (void)quickLogClicked:(id)sender {
    (void)sender;
    if (self.onQuickLogRequested) {
        self.onQuickLogRequested(self.currentFrequencyHz, self.currentMode);
    }
}

- (void)toggleMonitoring {
    if (self.engine.isMonitoring) {
        [self.engine stopMonitoring];
        [self.visualizerView clearVisuals];
        if (self.logHandler) self.logHandler(@"Stopped live radio audio monitoring.");
    } else {
        NSError *error = nil;
        if ([self.engine startMonitoring:&error]) {
            if (self.logHandler) self.logHandler([NSString stringWithFormat:@"Started live radio monitoring via AD-508 (Latency: %.1f ms).", self.engine.currentLatencyMs]);
        } else {
            if (self.logHandler) self.logHandler([NSString stringWithFormat:@"Failed to start audio monitoring: %@", error.localizedDescription]);
        }
    }
    [self updateMonitorButtonAppearance];
    if (self.onMonitoringStateChanged) {
        self.onMonitoringStateChanged(self.engine.isMonitoring);
    }
}

- (void)toggleMute:(id)sender {
    (void)sender;
    self.engine.isMuted = !self.engine.isMuted;
    self.muteButton.contentTintColor = self.engine.isMuted ? [NSColor systemRedColor] : nil;
    self.muteButton.title = self.engine.isMuted ? @"Muted 🔇" : @"Mute";
}

- (void)toggleDim:(id)sender {
    (void)sender;
    self.engine.isDimmed = !self.engine.isDimmed;
    self.dimButton.contentTintColor = self.engine.isDimmed ? [NSColor systemOrangeColor] : nil;
    self.dimButton.title = self.engine.isDimmed ? @"Dimmed (-20dB)" : @"Dim -20dB";
}

- (void)toggleRecording:(id)sender {
    (void)sender;
    if (self.engine.isRecording) {
        [self.engine stopRecording];
        if (self.logHandler) self.logHandler([NSString stringWithFormat:@"Saved radio recording to %@", self.engine.currentRecordingPath]);
    } else {
        NSError *error = nil;
        if ([self.engine startRecordingWithError:&error]) {
            if (self.logHandler) self.logHandler([NSString stringWithFormat:@"Recording radio audio to %@", self.engine.currentRecordingPath]);
        } else {
            if (self.logHandler) self.logHandler([NSString stringWithFormat:@"Failed to start recording: %@", error.localizedDescription]);
        }
    }
}

- (void)revealRecordings:(id)sender {
    (void)sender;
    [self.engine revealRecordingsInFinder];
}

- (void)toggleSimulation:(id)sender {
    (void)sender;
    if (self.simulationButton.state == NSControlStateValueOn) {
        [self.engine startSimulation];
        if (self.logHandler) self.logHandler(@"Audio Demo Mode activated: Generated synthetic HF atmospheric noise & test signal.");
    } else {
        [self.engine stopSimulation];
        [self.visualizerView clearVisuals];
        if (self.logHandler) self.logHandler(@"Audio Demo Mode deactivated.");
    }
}

- (void)inputDeviceSelected:(NSPopUpButton *)sender {
    NSString *uid = sender.selectedItem.representedObject;
    if ([uid isEqualToString:@"__REFRESH__"]) {
        [self refreshAudioDevicesAction:sender];
        return;
    }
    if (uid) {
        self.engine.selectedInputDeviceUID = uid;
        if (self.engine.isMonitoring) {
            [self.engine stopMonitoring];
            [self.engine startMonitoring:nil];
        }
    }
}

- (void)outputDeviceSelected:(NSPopUpButton *)sender {
    NSString *uid = sender.selectedItem.representedObject;
    if ([uid isEqualToString:@"__REFRESH__"]) {
        [self refreshAudioDevicesAction:sender];
        return;
    }
    if (uid) {
        self.engine.selectedOutputDeviceUID = uid;
        if (self.engine.isMonitoring) {
            [self.engine stopMonitoring];
            [self.engine startMonitoring:nil];
        }
    }
}

- (void)bufferSizeSelected:(NSPopUpButton *)sender {
    if (sender.indexOfSelectedItem == 0) self.engine.bufferSizeFrames = 256;
    else if (sender.indexOfSelectedItem == 1) self.engine.bufferSizeFrames = 512;
    else self.engine.bufferSizeFrames = 1024;

    if (self.engine.isMonitoring) {
        [self.engine stopMonitoring];
        [self.engine startMonitoring:nil];
    }
}

- (void)volumeChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.engine.masterVolume = val;
    float db = val > 0.01f ? 20.0f * log10f(val) : -60.0f;
    if (val > 1.05f) {
        self.volumeValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%% (+%.1f dB Boost)", val * 100.0f, db];
        self.volumeValueLabel.textColor = [NSColor systemOrangeColor];
    } else {
        self.volumeValueLabel.stringValue = [NSString stringWithFormat:@"%.0f%% (%.1f dB)", val * 100.0f, db];
        self.volumeValueLabel.textColor = [NSColor labelColor];
    }
}

- (void)balanceChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.engine.balance = val;
    if (fabsf(val) < 0.08f) {
        self.balanceValueLabel.stringValue = @"Center (L/R)";
    } else if (val < 0.0f) {
        self.balanceValueLabel.stringValue = [NSString stringWithFormat:@"Left %d%%", (int)(fabsf(val) * 100.0f)];
    } else {
        self.balanceValueLabel.stringValue = [NSString stringWithFormat:@"Right %d%%", (int)(val * 100.0f)];
    }
}

- (void)presetChanged:(NSSegmentedControl *)sender {
    TX500AudioFilterPreset p = (TX500AudioFilterPreset)sender.selectedSegment;
    [self.engine applyPreset:p];
    self.lowCutSlider.floatValue = self.engine.lowCutHz;
    self.highCutSlider.floatValue = self.engine.highCutHz;
    self.lowCutValueLabel.stringValue = [NSString stringWithFormat:@"%.0f Hz", self.engine.lowCutHz];
    self.highCutValueLabel.stringValue = [NSString stringWithFormat:@"%.0f Hz", self.engine.highCutHz];

    self.visualizerView.lowCutHz = self.engine.lowCutHz;
    self.visualizerView.highCutHz = self.engine.highCutHz;
}

- (void)lowCutChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.engine.lowCutHz = val;
    self.lowCutValueLabel.stringValue = [NSString stringWithFormat:@"%.0f Hz", val];
    self.visualizerView.lowCutHz = val;
}

- (void)highCutChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.engine.highCutHz = val;
    self.highCutValueLabel.stringValue = [NSString stringWithFormat:@"%.0f Hz", val];
    self.visualizerView.highCutHz = val;
}

- (void)notchToggled:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    self.engine.notchEnabled = on;
    self.notchFreqSlider.enabled = on;
    self.visualizerView.notchEnabled = on;
}

- (void)notchFreqChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.engine.notchFreqHz = val;
    self.notchFreqValueLabel.stringValue = [NSString stringWithFormat:@"%.0f Hz", val];
    self.visualizerView.notchFreqHz = val;
}

- (void)squelchToggled:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    self.engine.squelchEnabled = on;
    self.squelchThresholdSlider.enabled = on;
}

- (void)squelchThresholdChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.engine.squelchThresholdDb = val;
    self.squelchValueLabel.stringValue = [NSString stringWithFormat:@"%.0f dB", val];
}

- (void)limiterToggled:(NSButton *)sender {
    self.engine.limiterEnabled = (sender.state == NSControlStateValueOn);
}

- (void)autoNotchToggled:(NSButton *)sender {
    self.engine.autoNotchEnabled = (sender.state == NSControlStateValueOn);
}

- (void)nrToggled:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    self.engine.nrEnabled = on;
    self.nrDepthSlider.enabled = on;
}

- (void)nrDepthChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.engine.nrLevel = val / 10.0f;
    self.nrDepthValueLabel.stringValue = [NSString stringWithFormat:@"Depth: %.0f", val];
}

- (void)eqToggled:(NSButton *)sender {
    BOOL on = (sender.state == NSControlStateValueOn);
    self.engine.eqEnabled = on;
    self.eqLowSlider.enabled = on;
    self.eqMidSlider.enabled = on;
    self.eqHighSlider.enabled = on;
}

- (void)eqLowChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.engine.eqLowGainDb = val;
    self.eqLowLabel.stringValue = [NSString stringWithFormat:@"%+.1f dB", val];
}

- (void)eqMidChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.engine.eqMidGainDb = val;
    self.eqMidLabel.stringValue = [NSString stringWithFormat:@"%+.1f dB", val];
}

- (void)eqHighChanged:(NSSlider *)sender {
    float val = sender.floatValue;
    self.engine.eqHighGainDb = val;
    self.eqHighLabel.stringValue = [NSString stringWithFormat:@"%+.1f dB", val];
}

#pragma mark - Lifecycle

- (void)startController {
    [self.engine refreshDevices];
    [self updateDeviceMenus];
    [self updateHardwareStatusPill];
    [self updateMonitorButtonAppearance];
    [self startCATSync];
}

- (void)pauseTabUI {
    // When switching to another tab, pause CAT serial polling to leave serial port
    // free for other tabs, but LEAVE CoreAudio monitoring & recording active!
    [self stopCATSync];
}

- (void)resumeTabUI {
    // When returning to Live Audio tab, resume CAT serial polling and device states
    [self.engine refreshDevices];
    [self updateDeviceMenus];
    [self updateHardwareStatusPill];
    [self updateMonitorButtonAppearance];
    [self startCATSync];
}

- (void)stopController {
    [self stopCATSync];
    [self.engine stopMonitoring];
    [self.engine stopRecording];
    [self.engine stopSimulation];
    [self.visualizerView clearVisuals];
    [self updateMonitorButtonAppearance];
}

@end
