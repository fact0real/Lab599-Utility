//
//  TX500CWStationController.m
//  Lab599 Utility
//
//  Complete CW Workstation & Semi-Automated QSO Studio Controller
//

#import "TX500CWStationController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString * const CWInputPreferenceKey = @"TX500_CW_InputDeviceUID";

@interface TX500CWStationController ()

@property (nonatomic, strong, readwrite) NSView *view;
@property (nonatomic, strong, readwrite) TX500CWAudioDecoder *decoder;
@property (nonatomic, strong, readwrite) TX500CWKeyer *keyer;
@property (nonatomic, strong, readwrite) TX500CWQSOAssistant *assistant;

// UI Controls - Top Bar
@property (nonatomic, strong) NSButton *startStopDecoderButton;
@property (nonatomic, strong) NSPopUpButton *audioDevicePopup;
@property (nonatomic) BOOL hasLocalAudioSelection;
@property (nonatomic, strong) NSButton *simulationCheckbox;
@property (nonatomic, strong) NSSlider *pitchSlider;
@property (nonatomic, strong) NSTextField *pitchValueLabel;
@property (nonatomic, strong) NSButton *afcCheckbox;
@property (nonatomic, strong) NSStepper *wpmStepper;
@property (nonatomic, strong) NSTextField *wpmLabel;
@property (nonatomic, strong) NSButton *cutNumbersCheckbox;

// UI Controls - Spectrum & Metrics
@property (nonatomic, strong) TX500CWSpectrumView *spectrumView;
@property (nonatomic, strong) NSTextField *wpmMetricLabel;
@property (nonatomic, strong) NSTextField *snrMetricLabel;
@property (nonatomic, strong) NSTextField *ditDahMetricLabel;
@property (nonatomic, strong) NSTextField *activeDitDahLabel;

// UI Controls - Decoded Terminal
@property (nonatomic, strong) NSTextView *terminalTextView;
@property (nonatomic, strong) NSButton *clearTerminalButton;

// UI Controls - CQ Roster Table
@property (nonatomic, strong) NSTableView *cqRosterTableView;

// UI Controls - QSO Co-Pilot
@property (nonatomic, strong) NSTextField *qsoStateLabel;
@property (nonatomic, strong) NSButton *qsoNextActionButton;
@property (nonatomic, strong) NSButton *autoCQButton;
@property (nonatomic, strong) NSTextField *autoCQCountdownLabel;
@property (nonatomic, strong) NSTextField *txInputField;
@property (nonatomic, strong) NSButton *txSendButton;
@property (nonatomic, strong) NSButton *txAbortButton;
@property (nonatomic, strong) NSMutableArray<NSButton *> *macroButtons;

// UI Controls - QSO Log Table
@property (nonatomic, strong) NSTableView *logTableView;
@property (nonatomic, strong) NSButton *exportADIFButton;
@property (nonatomic, strong) NSButton *clearLogButton;

- (void)updateAudioDeviceMenu;

@end

@implementation TX500CWStationController

- (instancetype)init {
    self = [super init];
    if (self) {
        _decoder = [[TX500CWAudioDecoder alloc] init];
        NSString *savedInput = [NSUserDefaults.standardUserDefaults stringForKey:CWInputPreferenceKey];
        _hasLocalAudioSelection = savedInput.length > 0;
        if (_hasLocalAudioSelection) {
            _decoder.selectedAudioDeviceUID = savedInput;
        } else if (@available(macOS 14.2, *)) {
            _decoder.selectedAudioDeviceUID = TX500CWSystemAudioDeviceUID;
        }
        _decoder.preserveDeviceSelection = YES;
        _keyer = [[TX500CWKeyer alloc] init];
        _assistant = [[TX500CWQSOAssistant alloc] init];
        _macroButtons = [NSMutableArray array];

        [_decoder setNominalWPM:(double)_keyer.wpm];

        [self setupBindings];
        [self buildUserInterface];
    }
    return self;
}

- (void)dealloc {
    [self stopStation];
}

#pragma mark - Bindings & Callbacks

- (void)setupBindings {
    __weak typeof(self) weakSelf = self;

    // Decoder -> UI & Assistant
    self.decoder.onDecodedTextUpdated = ^(NSString *rawText, NSString *charBuffer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        // Update Terminal View
        [strongSelf.terminalTextView setString:rawText];
        [strongSelf.terminalTextView scrollRangeToVisible:NSMakeRange(rawText.length, 0)];
        strongSelf.activeDitDahLabel.stringValue = charBuffer.length > 0 ? [NSString stringWithFormat:@"[ %@ ]", charBuffer] : @"[ ]";

        // Feed to QSO Assistant for CQ & token analysis
        [strongSelf.assistant processDecodedTextStream:rawText
                                            currentWPM:strongSelf.decoder.estimatedWPM
                                                 snrDb:strongSelf.decoder.signalToNoiseRatioDb];
    };

    self.decoder.onMetricsUpdated = ^(double wpm, double snrDb, float level, BOOL sig) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.wpmMetricLabel.stringValue = [NSString stringWithFormat:@"%.0f WPM", wpm];
        strongSelf.snrMetricLabel.stringValue = [NSString stringWithFormat:@"%.1f dB", snrDb];
        strongSelf.ditDahMetricLabel.stringValue = [NSString stringWithFormat:@"1 : %.1f", strongSelf.decoder.ditDahRatio];

        [strongSelf.spectrumView updateWithBins:strongSelf.decoder.spectrumBins
                                     centerFreq:strongSelf.decoder.centerFrequencyHz
                                    nominalPitch:strongSelf.decoder.nominalPitchHz
                                           level:level
                                           snrDb:snrDb
                                  signalDetected:sig];
    };

    self.decoder.onAudioDevicesChanged = ^{
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf updateAudioDeviceMenu];
    };

    self.decoder.onListeningStateChanged = ^(BOOL listening) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.startStopDecoderButton.title = listening ? @"STOP DECODER" : @"START DECODER";
        strongSelf.startStopDecoderButton.contentTintColor = listening ? NSColor.systemRedColor : NSColor.systemGreenColor;
        if (strongSelf.decoderStateChangedHandler) strongSelf.decoderStateChangedHandler(listening);
    };
    self.decoder.onAudioError = ^(NSString *message) {
        typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.logHandler) strongSelf.logHandler(message);
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Audio input unavailable";
        alert.informativeText = message;
        [alert addButtonWithTitle:@"OK"];
        if (strongSelf.view.window) [alert beginSheetModalForWindow:strongSelf.view.window completionHandler:nil];
    };

    // User click anywhere on Spectrum Waterfall tunes the pitch
    self.spectrumView.onPitchSelected = ^(double pitchHz) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.pitchSlider.doubleValue = pitchHz;
        strongSelf.pitchValueLabel.stringValue = [NSString stringWithFormat:@"%.0fHz", pitchHz];
        [strongSelf.decoder setPitch:pitchHz];
        strongSelf.keyer.sidetonePitchHz = pitchHz;
        if (strongSelf.logHandler) {
            strongSelf.logHandler([NSString stringWithFormat:@"CW Pitch tuned to %.0f Hz via Spectrum click.", pitchHz]);
        }
    };

    // Assistant -> UI Updates
    self.assistant.onHeardStationsUpdated = ^(NSArray<TX500CWHeardStation *> *stations) {
        (void)stations;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.cqRosterTableView reloadData];
    };

    self.assistant.onQSOStateChanged = ^(TX500QSOState state, NSString *desc) {
        (void)state;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.qsoStateLabel.stringValue = desc;
        strongSelf.qsoNextActionButton.title = strongSelf.assistant.suggestedActionTitle;
        strongSelf.qsoNextActionButton.enabled = strongSelf.assistant.hasActionableStep;
    };

    self.assistant.onContactLogged = ^(TX500QSOContact *contact) {
        (void)contact;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf.logTableView reloadData];
        if (strongSelf.logHandler) {
            strongSelf.logHandler([NSString stringWithFormat:@"✔ Logged QSO with %@ (%@, %@)",
                                   contact.callsign, contact.band, contact.mode]);
        }
    };

    // Keyer -> Serial Sender & Log
    self.keyer.serialCommandSender = ^BOOL(NSString *catCommand) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf.decoder.isSimulationActive) return YES;
        if (strongSelf && strongSelf.serialCommandSender) {
            return strongSelf.serialCommandSender(catCommand);
        }
        return NO;
    };

    self.keyer.logHandler = ^(NSString *line) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && strongSelf.logHandler) {
            strongSelf.logHandler(line);
        }
    };

    self.keyer.onTransmitStateChanged = ^(BOOL transmitting, NSString *text) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (transmitting) {
            strongSelf.txAbortButton.enabled = YES;
            strongSelf.txSendButton.enabled = NO;
        } else {
            strongSelf.txAbortButton.enabled = NO;
            strongSelf.txSendButton.enabled = YES;
        }
        (void)text;
    };
}

#pragma mark - Lifecycle

- (void)startStation {
    [self.decoder refreshAudioDevices];
    [self updateAudioDeviceMenu];
}

- (void)stopStation {
    [self.decoder stopListening];
    [self.decoder stopSimulation];
    [self.keyer abortTransmission];
    [self.keyer stopAutoCQ];
    self.startStopDecoderButton.title = @"START DECODER";
    self.startStopDecoderButton.contentTintColor = [NSColor systemGreenColor];
}

- (void)updateFrequencyHz:(uint64_t)freqHz mode:(NSString *)mode {
    self.assistant.currentFrequencyHz = freqHz;
    // Derive amateur band
    double mhz = (double)freqHz / 1000000.0;
    NSString *b = @"20m";
    if (mhz >= 1.8 && mhz <= 2.0) b = @"160m";
    else if (mhz >= 3.5 && mhz <= 4.0) b = @"80m";
    else if (mhz >= 7.0 && mhz <= 7.3) b = @"40m";
    else if (mhz >= 10.1 && mhz <= 10.15) b = @"30m";
    else if (mhz >= 14.0 && mhz <= 14.35) b = @"20m";
    else if (mhz >= 18.068 && mhz <= 18.168) b = @"17m";
    else if (mhz >= 21.0 && mhz <= 21.45) b = @"15m";
    else if (mhz >= 24.89 && mhz <= 24.99) b = @"12m";
    else if (mhz >= 28.0 && mhz <= 29.7) b = @"10m";
    else if (mhz >= 50.0 && mhz <= 54.0) b = @"6m";
    self.assistant.currentBand = b;
    (void)mode;
}

#pragma mark - UI Building

- (NSView *)createCardView {
    NSView *v = [[NSView alloc] init];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    v.wantsLayer = YES;
    v.layer.cornerRadius = 8.0;
    v.layer.borderWidth = 1.0;
    v.layer.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.22].CGColor;
    v.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.06].CGColor;
    return v;
}

- (void)buildUserInterface {
    self.view = [[NSView alloc] initWithFrame:NSZeroRect];
    self.view.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *topCard = [self buildTopControlBar];
    NSView *scopeCard = [self buildSpectrumAndMetricsRow];
    NSView *middleCard = [self buildMiddleWorkstation];
    NSView *bottomCard = [self buildBottomLogSection];

    NSStackView *rootStack = [NSStackView stackViewWithViews:@[topCard, scopeCard, middleCard, bottomCard]];
    rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    rootStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    rootStack.spacing = 8;
    rootStack.alignment = NSLayoutAttributeLeading;
    rootStack.distribution = NSStackViewDistributionFill;
    [self.view addSubview:rootStack];

    [NSLayoutConstraint activateConstraints:@[
        [rootStack.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [rootStack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [rootStack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [rootStack.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],

        [topCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
        [scopeCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
        [middleCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor],
        [bottomCard.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor]
    ]];
}

#pragma mark - Top Control Bar

- (NSView *)buildTopControlBar {
    NSView *container = [self createCardView];

    // Left group: Decoder toggle, Audio device, Practice Mode
    self.startStopDecoderButton = [NSButton buttonWithTitle:@"START DECODER" target:self action:@selector(toggleDecoder:)];
    self.startStopDecoderButton.bezelStyle = NSBezelStyleRounded;
    self.startStopDecoderButton.contentTintColor = [NSColor systemGreenColor];
    self.startStopDecoderButton.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightBold];
    self.startStopDecoderButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.startStopDecoderButton.widthAnchor constraintEqualToConstant:130].active = YES;

    self.audioDevicePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.audioDevicePopup.toolTip = @"Choose and save the CW input here; Station Profiles are not required. System Audio (Direct) receives audio playing on this Mac. Microphone and USB inputs receive external audio. macOS may ask for recording permission.";
    self.audioDevicePopup.controlSize = NSControlSizeSmall;
    self.audioDevicePopup.font = [NSFont systemFontOfSize:11];
    self.audioDevicePopup.target = self;
    self.audioDevicePopup.action = @selector(audioDeviceChanged:);
    self.audioDevicePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.audioDevicePopup.widthAnchor constraintEqualToConstant:170].active = YES;
    [self updateAudioDeviceMenu];

    self.simulationCheckbox = [NSButton checkboxWithTitle:@"Practice / Sim" target:self action:@selector(toggleSimulation:)];
    self.simulationCheckbox.controlSize = NSControlSizeSmall;
    self.simulationCheckbox.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.simulationCheckbox.translatesAutoresizingMaskIntoConstraints = NO;

    // Pitch & AFC group
    NSTextField *pitchTitle = [NSTextField labelWithString:@"Pitch:"];
    pitchTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    pitchTitle.textColor = [NSColor secondaryLabelColor];
    pitchTitle.translatesAutoresizingMaskIntoConstraints = NO;

    self.pitchSlider = [[NSSlider alloc] init];
    self.pitchSlider.controlSize = NSControlSizeSmall;
    self.pitchSlider.minValue = 300.0;
    self.pitchSlider.maxValue = 1500.0;
    self.pitchSlider.doubleValue = self.decoder.nominalPitchHz;
    self.pitchSlider.target = self;
    self.pitchSlider.action = @selector(pitchSliderChanged:);
    self.pitchSlider.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pitchSlider.widthAnchor constraintEqualToConstant:70].active = YES;

    self.pitchValueLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%.0fHz", self.decoder.nominalPitchHz]];
    self.pitchValueLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightMedium];
    self.pitchValueLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.pitchValueLabel.widthAnchor constraintEqualToConstant:54].active = YES;

    pitchTitle.toolTip = @"Listening center pitch (RX Goertzel 300-1500 Hz) & Transmitter sidetone (TX).";
    self.pitchSlider.toolTip = @"Listening center pitch (RX Goertzel 300-1500 Hz) & Transmitter sidetone (TX).";
    self.pitchValueLabel.toolTip = @"Listening center pitch (RX Goertzel 300-1500 Hz) & Transmitter sidetone (TX).";

    self.afcCheckbox = [NSButton checkboxWithTitle:@"AFC" target:self action:@selector(toggleAFC:)];
    self.afcCheckbox.controlSize = NSControlSizeSmall;
    self.afcCheckbox.font = [NSFont systemFontOfSize:11];
    self.afcCheckbox.state = self.decoder.afcEnabled ? NSControlStateValueOn : NSControlStateValueOff;
    self.afcCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.afcCheckbox.toolTip = @"Automatic Frequency Control (RX only): Acquires incoming CW tones from 300 to 1500 Hz and holds the frequency through gaps.";

    // Speed group
    NSTextField *wpmTitle = [NSTextField labelWithString:@"Speed:"];
    wpmTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    wpmTitle.textColor = [NSColor secondaryLabelColor];
    wpmTitle.translatesAutoresizingMaskIntoConstraints = NO;
    wpmTitle.toolTip = @"CW Speed (WPM): Sets transmitter keyer speed & primes initial receiver decoding speed.";

    self.wpmLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"%ld WPM", (long)self.keyer.wpm]];
    self.wpmLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightBold];
    self.wpmLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.wpmLabel.widthAnchor constraintEqualToConstant:54].active = YES;
    self.wpmLabel.toolTip = @"CW Speed (WPM): Sets transmitter keyer speed & primes initial receiver decoding speed.";

    self.wpmStepper = [[NSStepper alloc] init];
    self.wpmStepper.controlSize = NSControlSizeSmall;
    self.wpmStepper.minValue = 3;
    self.wpmStepper.maxValue = 45;
    self.wpmStepper.integerValue = self.keyer.wpm;
    self.wpmStepper.target = self;
    self.wpmStepper.action = @selector(wpmStepperChanged:);
    self.wpmStepper.translatesAutoresizingMaskIntoConstraints = NO;
    self.wpmStepper.toolTip = @"CW Speed (WPM): Sets transmitter keyer speed & primes initial receiver decoding speed.";

    self.cutNumbersCheckbox = [NSButton checkboxWithTitle:@"Cut 5NN" target:self action:@selector(toggleCutNumbers:)];
    self.cutNumbersCheckbox.controlSize = NSControlSizeSmall;
    self.cutNumbersCheckbox.font = [NSFont systemFontOfSize:11];
    self.cutNumbersCheckbox.state = self.keyer.useCutNumbers ? NSControlStateValueOn : NSControlStateValueOff;
    self.cutNumbersCheckbox.translatesAutoresizingMaskIntoConstraints = NO;
    self.cutNumbersCheckbox.toolTip = @"Cut Numbers (TX only): Sends 5NN instead of 599 for signal reports.";

    // Separators
    NSBox *div1 = [NSBox new]; div1.boxType = NSBoxSeparator; div1.translatesAutoresizingMaskIntoConstraints = NO;
    [div1.heightAnchor constraintEqualToConstant:16].active = YES;
    NSBox *div2 = [NSBox new]; div2.boxType = NSBoxSeparator; div2.translatesAutoresizingMaskIntoConstraints = NO;
    [div2.heightAnchor constraintEqualToConstant:16].active = YES;

    NSView *spacer = [NSView new];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *r1 = [NSStackView stackViewWithViews:@[
        self.startStopDecoderButton,
        self.audioDevicePopup,
        self.simulationCheckbox,
        spacer
    ]];
    r1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r1.alignment = NSLayoutAttributeCenterY;
    r1.spacing = 8;

    NSView *spacerR2 = [NSView new];
    spacerR2.translatesAutoresizingMaskIntoConstraints = NO;
    [spacerR2 setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *r2 = [NSStackView stackViewWithViews:@[
        pitchTitle, self.pitchSlider, self.pitchValueLabel, self.afcCheckbox,
        div2,
        wpmTitle, self.wpmLabel, self.wpmStepper, self.cutNumbersCheckbox,
        spacerR2
    ]];
    r2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    r2.alignment = NSLayoutAttributeCenterY;
    r2.spacing = 8;

    NSStackView *stack = [NSStackView stackViewWithViews:@[r1, r2]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 6;
    [container addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:10],
        [stack.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-10],
        [stack.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
        [r1.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [r2.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
        [container.heightAnchor constraintEqualToConstant:68]
    ]];

    return container;
}

#pragma mark - Spectrum & Metrics Row

- (NSView *)buildSpectrumAndMetricsRow {
    NSView *container = [self createCardView];

    self.spectrumView = [[TX500CWSpectrumView alloc] initWithFrame:NSMakeRect(0, 0, 520, 78)];
    self.spectrumView.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.spectrumView];

    // Right side metrics box
    NSView *metricCard = [NSView new];
    metricCard.translatesAutoresizingMaskIntoConstraints = NO;
    metricCard.wantsLayer = YES;
    metricCard.layer.cornerRadius = 6.0;
    metricCard.layer.borderWidth = 1.0;
    metricCard.layer.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.18].CGColor;
    metricCard.layer.backgroundColor = [NSColor colorWithCalibratedWhite:0.08 alpha:0.6].CGColor;
    [container addSubview:metricCard];

    self.wpmMetricLabel = [NSTextField labelWithString:@"20 WPM"];
    self.wpmMetricLabel.font = [NSFont monospacedDigitSystemFontOfSize:12.0 weight:NSFontWeightBold];
    self.wpmMetricLabel.textColor = [NSColor systemOrangeColor];
    self.wpmMetricLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.snrMetricLabel = [NSTextField labelWithString:@"0.0 dB SNR"];
    self.snrMetricLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightMedium];
    self.snrMetricLabel.textColor = [NSColor labelColor];
    self.snrMetricLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.ditDahMetricLabel = [NSTextField labelWithString:@"Ratio: 1 : 3.0"];
    self.ditDahMetricLabel.font = [NSFont monospacedDigitSystemFontOfSize:10.0 weight:NSFontWeightRegular];
    self.ditDahMetricLabel.textColor = [NSColor secondaryLabelColor];
    self.ditDahMetricLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.activeDitDahLabel = [NSTextField labelWithString:@"[ ]"];
    self.activeDitDahLabel.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightBold];
    self.activeDitDahLabel.textColor = [NSColor systemGreenColor];
    self.activeDitDahLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *metricsStack = [NSStackView stackViewWithViews:@[
        self.wpmMetricLabel,
        self.snrMetricLabel,
        self.ditDahMetricLabel,
        self.activeDitDahLabel
    ]];
    metricsStack.translatesAutoresizingMaskIntoConstraints = NO;
    metricsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    metricsStack.alignment = NSLayoutAttributeLeading;
    metricsStack.spacing = 2;
    [metricCard addSubview:metricsStack];

    [NSLayoutConstraint activateConstraints:@[
        [metricsStack.leadingAnchor constraintEqualToAnchor:metricCard.leadingAnchor constant:8],
        [metricsStack.trailingAnchor constraintEqualToAnchor:metricCard.trailingAnchor constant:-8],
        [metricsStack.centerYAnchor constraintEqualToAnchor:metricCard.centerYAnchor],

        [self.spectrumView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:6],
        [self.spectrumView.topAnchor constraintEqualToAnchor:container.topAnchor constant:5],
        [self.spectrumView.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-5],
        [self.spectrumView.trailingAnchor constraintEqualToAnchor:metricCard.leadingAnchor constant:-8],

        [metricCard.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-6],
        [metricCard.topAnchor constraintEqualToAnchor:container.topAnchor constant:5],
        [metricCard.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-5],
        [metricCard.widthAnchor constraintEqualToConstant:150],

        [container.heightAnchor constraintEqualToConstant:78]
    ]];

    return container;
}

#pragma mark - Middle Workstation: Split Terminal & Co-Pilot

- (NSView *)buildMiddleWorkstation {
    NSView *container = [self createCardView];

    NSView *terminalColumn = [self buildTerminalColumn];
    [container addSubview:terminalColumn];

    NSView *rightColumn = [self buildRightCoPilotColumn];
    [container addSubview:rightColumn];

    [NSLayoutConstraint activateConstraints:@[
        [terminalColumn.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [terminalColumn.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [terminalColumn.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],
        [terminalColumn.widthAnchor constraintEqualToAnchor:container.widthAnchor multiplier:0.48],

        [rightColumn.leadingAnchor constraintEqualToAnchor:terminalColumn.trailingAnchor constant:10],
        [rightColumn.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [rightColumn.topAnchor constraintEqualToAnchor:container.topAnchor constant:6],
        [rightColumn.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-6],

        [container.heightAnchor constraintEqualToConstant:280]
    ]];

    return container;
}

- (NSView *)buildTerminalColumn {
    NSView *col = [NSView new];
    col.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *title = [NSTextField labelWithString:@"Decoded Morse Stream (Terminal):"];
    title.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [col addSubview:title];

    self.clearTerminalButton = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearTerminal:)];
    self.clearTerminalButton.bezelStyle = NSBezelStyleInline;
    self.clearTerminalButton.controlSize = NSControlSizeSmall;
    self.clearTerminalButton.font = [NSFont systemFontOfSize:10.5];
    self.clearTerminalButton.translatesAutoresizingMaskIntoConstraints = NO;
    [col addSubview:self.clearTerminalButton];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.borderType = NSBezelBorder;
    scroll.hasVerticalScroller = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    self.terminalTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 350, 200)];
    self.terminalTextView.editable = NO;
    self.terminalTextView.backgroundColor = [NSColor colorWithCalibratedWhite:0.06 alpha:1.0];
    self.terminalTextView.textColor = [NSColor colorWithSRGBRed:0.2 green:0.9 blue:0.4 alpha:1.0];
    self.terminalTextView.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
    scroll.documentView = self.terminalTextView;
    [col addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [title.leadingAnchor constraintEqualToAnchor:col.leadingAnchor],
        [title.topAnchor constraintEqualToAnchor:col.topAnchor],
        [title.trailingAnchor constraintEqualToAnchor:self.clearTerminalButton.leadingAnchor constant:-6],

        [self.clearTerminalButton.trailingAnchor constraintEqualToAnchor:col.trailingAnchor],
        [self.clearTerminalButton.centerYAnchor constraintEqualToAnchor:title.centerYAnchor],

        [scroll.leadingAnchor constraintEqualToAnchor:col.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:col.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [scroll.bottomAnchor constraintEqualToAnchor:col.bottomAnchor]
    ]];

    return col;
}

- (NSView *)buildRightCoPilotColumn {
    NSView *col = [NSView new];
    col.translatesAutoresizingMaskIntoConstraints = NO;

    // ── 1. CQ Roster Table ────────────────────────────────────────────
    NSTextField *rosterTitle = [NSTextField labelWithString:@"Detected CQs (Click to Answer):"];
    rosterTitle.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    rosterTitle.translatesAutoresizingMaskIntoConstraints = NO;
    // Prevent the label from expanding vertically beyond its intrinsic height
    [rosterTitle setContentHuggingPriority:NSLayoutPriorityRequired
                            forOrientation:NSLayoutConstraintOrientationVertical];
    [rosterTitle setContentCompressionResistancePriority:NSLayoutPriorityRequired
                                         forOrientation:NSLayoutConstraintOrientationVertical];

    NSScrollView *rosterScroll = [[NSScrollView alloc] init];
    rosterScroll.borderType = NSBezelBorder;
    rosterScroll.hasVerticalScroller = YES;
    rosterScroll.translatesAutoresizingMaskIntoConstraints = NO;
    [rosterScroll.heightAnchor constraintEqualToConstant:72].active = YES;

    self.cqRosterTableView = [[NSTableView alloc] init];
    self.cqRosterTableView.dataSource = self;
    self.cqRosterTableView.delegate = self;
    self.cqRosterTableView.rowHeight = 22;
    self.cqRosterTableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

    NSTableColumn *colCall = [[NSTableColumn alloc] initWithIdentifier:@"call"];
    colCall.title = @"Callsign"; colCall.width = 75; colCall.minWidth = 60;
    colCall.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [self.cqRosterTableView addTableColumn:colCall];

    NSTableColumn *colWpm = [[NSTableColumn alloc] initWithIdentifier:@"wpm"];
    colWpm.title = @"WPM"; colWpm.width = 44; colWpm.minWidth = 36;
    colWpm.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [self.cqRosterTableView addTableColumn:colWpm];

    NSTableColumn *colSnr = [[NSTableColumn alloc] initWithIdentifier:@"snr"];
    colSnr.title = @"SNR"; colSnr.width = 44; colSnr.minWidth = 36;
    colSnr.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [self.cqRosterTableView addTableColumn:colSnr];

    NSTableColumn *colAction = [[NSTableColumn alloc] initWithIdentifier:@"action"];
    colAction.title = @"Action"; colAction.width = 95; colAction.minWidth = 80;
    colAction.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
    [self.cqRosterTableView addTableColumn:colAction];

    rosterScroll.documentView = self.cqRosterTableView;

    // ── 2. Co-Pilot Card ──────────────────────────────────────────────
    NSView *coPilotCard = [NSView new];
    coPilotCard.translatesAutoresizingMaskIntoConstraints = NO;
    coPilotCard.wantsLayer = YES;
    coPilotCard.layer.cornerRadius = 6.0;
    coPilotCard.layer.borderWidth = 1.0;
    coPilotCard.layer.borderColor = [NSColor controlAccentColor].CGColor;
    coPilotCard.layer.backgroundColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.06].CGColor;
    // Allow coPilotCard to expand vertically and fill remaining space
    [coPilotCard setContentHuggingPriority:NSLayoutPriorityDefaultLow
                            forOrientation:NSLayoutConstraintOrientationVertical];

    self.qsoStateLabel = [NSTextField labelWithString:@"Monitoring traffic. Ready to respond or call CQ."];
    self.qsoStateLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    self.qsoStateLabel.textColor = [NSColor labelColor];
    self.qsoStateLabel.translatesAutoresizingMaskIntoConstraints = NO;

    self.qsoNextActionButton = [NSButton buttonWithTitle:@"▶ Start Calling CQ (F1)" target:self action:@selector(advanceQSOAction:)];
    self.qsoNextActionButton.bezelStyle = NSBezelStyleRegularSquare;
    self.qsoNextActionButton.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    self.qsoNextActionButton.contentTintColor = [NSColor controlAccentColor];
    self.qsoNextActionButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.qsoNextActionButton.heightAnchor constraintEqualToConstant:26].active = YES;

    self.autoCQButton = [NSButton buttonWithTitle:@"Auto-CQ Repeater" target:self action:@selector(toggleAutoCQ:)];
    self.autoCQButton.bezelStyle = NSBezelStyleRounded;
    self.autoCQButton.controlSize = NSControlSizeSmall;
    self.autoCQButton.font = [NSFont systemFontOfSize:10.5];
    self.autoCQButton.translatesAutoresizingMaskIntoConstraints = NO;

    self.autoCQCountdownLabel = [NSTextField labelWithString:@""];
    self.autoCQCountdownLabel.font = [NSFont monospacedDigitSystemFontOfSize:11.0 weight:NSFontWeightBold];
    self.autoCQCountdownLabel.textColor = [NSColor systemRedColor];
    self.autoCQCountdownLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *cqRow = [NSStackView stackViewWithViews:@[self.autoCQButton, self.autoCQCountdownLabel]];
    cqRow.translatesAutoresizingMaskIntoConstraints = NO;
    cqRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    cqRow.spacing = 6;
    cqRow.alignment = NSLayoutAttributeCenterY;

    [self.macroButtons removeAllObjects];
    NSMutableArray *m1 = [NSMutableArray array];
    NSMutableArray *m2 = [NSMutableArray array];
    for (NSInteger i = 0; i < (NSInteger)self.keyer.macroList.count; i++) {
        TX500CWMacro *m = self.keyer.macroList[i];
        NSButton *btn = [NSButton buttonWithTitle:m.label target:self action:@selector(macroButtonClicked:)];
        btn.tag = i;
        btn.bezelStyle = NSBezelStyleInline;
        btn.controlSize = NSControlSizeSmall;
        btn.font = [NSFont systemFontOfSize:10];
        btn.translatesAutoresizingMaskIntoConstraints = NO;
        [self.macroButtons addObject:btn];
        if (i < 4) [m1 addObject:btn]; else [m2 addObject:btn];
    }
    NSStackView *macroRow1 = [NSStackView stackViewWithViews:m1];
    macroRow1.translatesAutoresizingMaskIntoConstraints = NO;
    macroRow1.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    macroRow1.distribution = NSStackViewDistributionFillEqually;
    macroRow1.spacing = 4;

    NSStackView *macroRow2 = [NSStackView stackViewWithViews:m2];
    macroRow2.translatesAutoresizingMaskIntoConstraints = NO;
    macroRow2.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    macroRow2.distribution = NSStackViewDistributionFillEqually;
    macroRow2.spacing = 4;

    self.txInputField = [[NSTextField alloc] init];
    self.txInputField.controlSize = NSControlSizeSmall;
    self.txInputField.font = [NSFont systemFontOfSize:11];
    self.txInputField.placeholderString = @"Type Morse message...";
    self.txInputField.target = self;
    self.txInputField.action = @selector(txSendClicked:);
    self.txInputField.translatesAutoresizingMaskIntoConstraints = NO;

    self.txSendButton = [NSButton buttonWithTitle:@"Send" target:self action:@selector(txSendClicked:)];
    self.txSendButton.bezelStyle = NSBezelStyleRounded;
    self.txSendButton.controlSize = NSControlSizeSmall;
    self.txSendButton.font = [NSFont systemFontOfSize:11];
    self.txSendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.txSendButton.widthAnchor constraintEqualToConstant:50].active = YES;

    self.txAbortButton = [NSButton buttonWithTitle:@"ABORT" target:self action:@selector(txAbortClicked:)];
    self.txAbortButton.bezelStyle = NSBezelStyleRounded;
    self.txAbortButton.controlSize = NSControlSizeSmall;
    self.txAbortButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
    self.txAbortButton.contentTintColor = [NSColor systemRedColor];
    self.txAbortButton.target = self;
    self.txAbortButton.action = @selector(txAbortClicked:);
    self.txAbortButton.enabled = NO;
    self.txAbortButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.txAbortButton.widthAnchor constraintEqualToConstant:60].active = YES;

    NSStackView *txRow = [NSStackView stackViewWithViews:@[self.txInputField, self.txSendButton, self.txAbortButton]];
    txRow.translatesAutoresizingMaskIntoConstraints = NO;
    txRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    txRow.spacing = 4;
    txRow.alignment = NSLayoutAttributeCenterY;

    NSStackView *coPilotStack = [NSStackView stackViewWithViews:@[
        self.qsoStateLabel, self.qsoNextActionButton, cqRow, macroRow1, macroRow2, txRow
    ]];
    coPilotStack.translatesAutoresizingMaskIntoConstraints = NO;
    coPilotStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    coPilotStack.alignment = NSLayoutAttributeLeading;
    coPilotStack.spacing = 5;
    [coPilotCard addSubview:coPilotStack];

    // ── 3. Vertical NSStackView for entire column ─────────────────────
    // Using NSStackView guarantees that rosterTitle, rosterScroll, and coPilotCard
    // are placed in distinct non-overlapping slots — no z-ordering issues possible.
    NSStackView *colStack = [NSStackView stackViewWithViews:@[rosterTitle, rosterScroll, coPilotCard]];
    colStack.translatesAutoresizingMaskIntoConstraints = NO;
    colStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    colStack.alignment = NSLayoutAttributeLeading;
    colStack.spacing = 5;
    colStack.distribution = NSStackViewDistributionFill;
    [col addSubview:colStack];

    [NSLayoutConstraint activateConstraints:@[
        // colStack fills col
        [colStack.leadingAnchor constraintEqualToAnchor:col.leadingAnchor],
        [colStack.trailingAnchor constraintEqualToAnchor:col.trailingAnchor],
        [colStack.topAnchor constraintEqualToAnchor:col.topAnchor],
        [colStack.bottomAnchor constraintEqualToAnchor:col.bottomAnchor],

        // All managed views fill the full width of colStack
        [rosterTitle.widthAnchor constraintEqualToAnchor:colStack.widthAnchor],
        [rosterScroll.widthAnchor constraintEqualToAnchor:colStack.widthAnchor],
        [coPilotCard.widthAnchor constraintEqualToAnchor:colStack.widthAnchor],

        // coPilotStack pinned inside coPilotCard
        [coPilotStack.leadingAnchor constraintEqualToAnchor:coPilotCard.leadingAnchor constant:8],
        [coPilotStack.trailingAnchor constraintEqualToAnchor:coPilotCard.trailingAnchor constant:-8],
        [coPilotStack.topAnchor constraintEqualToAnchor:coPilotCard.topAnchor constant:6],
        [coPilotStack.bottomAnchor constraintEqualToAnchor:coPilotCard.bottomAnchor constant:-6],

        // Width constraints for coPilotStack children
        [self.qsoNextActionButton.widthAnchor constraintEqualToAnchor:coPilotStack.widthAnchor],
        [macroRow1.widthAnchor constraintEqualToAnchor:coPilotStack.widthAnchor],
        [macroRow2.widthAnchor constraintEqualToAnchor:coPilotStack.widthAnchor],
        [txRow.widthAnchor constraintEqualToAnchor:coPilotStack.widthAnchor],
    ]];

    return col;
}


#pragma mark - Bottom QSO Log Section


- (NSView *)buildBottomLogSection {
    NSView *container = [self createCardView];

    NSTextField *logTitle = [NSTextField labelWithString:@"Station Logbook (ADIF Records):"];
    logTitle.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightSemibold];
    logTitle.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:logTitle];

    self.exportADIFButton = [NSButton buttonWithTitle:@"Export ADIF (.adi)..." target:self action:@selector(exportADIFClicked:)];
    self.exportADIFButton.bezelStyle = NSBezelStyleRounded;
    self.exportADIFButton.controlSize = NSControlSizeSmall;
    self.exportADIFButton.font = [NSFont systemFontOfSize:11];
    self.exportADIFButton.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.exportADIFButton];

    self.clearLogButton = [NSButton buttonWithTitle:@"Clear Log" target:self action:@selector(clearLogClicked:)];
    self.clearLogButton.bezelStyle = NSBezelStyleRounded;
    self.clearLogButton.controlSize = NSControlSizeSmall;
    self.clearLogButton.font = [NSFont systemFontOfSize:11];
    self.clearLogButton.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:self.clearLogButton];

    NSScrollView *scroll = [[NSScrollView alloc] init];
    scroll.borderType = NSBezelBorder;
    scroll.hasVerticalScroller = YES;
    scroll.translatesAutoresizingMaskIntoConstraints = NO;

    self.logTableView = [[NSTableView alloc] init];
    self.logTableView.dataSource = self;
    self.logTableView.delegate = self;
    self.logTableView.rowHeight = 18;
    self.logTableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;

    NSTableColumn *c1 = [[NSTableColumn alloc] initWithIdentifier:@"logCall"]; c1.title = @"Callsign"; c1.width = 90; c1.minWidth = 75;
    NSTableColumn *c2 = [[NSTableColumn alloc] initWithIdentifier:@"logBand"]; c2.title = @"Band"; c2.width = 55; c2.minWidth = 45;
    NSTableColumn *c3 = [[NSTableColumn alloc] initWithIdentifier:@"logFreq"]; c3.title = @"Freq (MHz)"; c3.width = 80; c3.minWidth = 70;
    NSTableColumn *c4 = [[NSTableColumn alloc] initWithIdentifier:@"logMode"]; c4.title = @"Mode"; c4.width = 50; c4.minWidth = 40;
    NSTableColumn *c5 = [[NSTableColumn alloc] initWithIdentifier:@"logSent"]; c5.title = @"Sent"; c5.width = 50; c5.minWidth = 40;
    NSTableColumn *c6 = [[NSTableColumn alloc] initWithIdentifier:@"logRcvd"]; c6.title = @"Rcvd"; c6.width = 50; c6.minWidth = 40;
    NSTableColumn *c7 = [[NSTableColumn alloc] initWithIdentifier:@"logTime"]; c7.title = @"UTC Time"; c7.width = 130; c7.minWidth = 100;

    for (NSTableColumn *c in @[c1, c2, c3, c4, c5, c6, c7]) {
        c.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
        [self.logTableView addTableColumn:c];
    }

    scroll.documentView = self.logTableView;
    [container addSubview:scroll];

    [NSLayoutConstraint activateConstraints:@[
        [logTitle.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [logTitle.topAnchor constraintEqualToAnchor:container.topAnchor constant:5],

        [self.exportADIFButton.trailingAnchor constraintEqualToAnchor:self.clearLogButton.leadingAnchor constant:-6],
        [self.exportADIFButton.centerYAnchor constraintEqualToAnchor:logTitle.centerYAnchor],

        [self.clearLogButton.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [self.clearLogButton.centerYAnchor constraintEqualToAnchor:logTitle.centerYAnchor],

        [scroll.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:8],
        [scroll.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-8],
        [scroll.topAnchor constraintEqualToAnchor:logTitle.bottomAnchor constant:4],
        [scroll.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-5],
        [container.heightAnchor constraintEqualToConstant:96]
    ]];

    return container;
}

#pragma mark - Actions

- (void)toggleDecoder:(id)sender {
    (void)sender;
    if (self.decoder.isListening) {
        [self.decoder stopListening];
        self.startStopDecoderButton.title = @"START DECODER";
        self.startStopDecoderButton.contentTintColor = [NSColor systemGreenColor];
        if (self.logHandler) self.logHandler(@"CW Audio Decoder stopped.");
    } else {
        [self.decoder startListening];
        if (self.decoder.isListening && self.logHandler)
            self.logHandler(@"CW Audio Decoder active: listening on selected audio stream.");
    }
    // Notify host so it can update the status bar pill (CW Decoding / Radio Ready)
    if (self.decoderStateChangedHandler) self.decoderStateChangedHandler(self.decoder.isListening);
}

- (void)toggleSimulation:(NSButton *)sender {
    [self.keyer stopAutoCQ]; [self.keyer abortTransmission];
    if (sender.state == NSControlStateValueOn) {
        [self.decoder startSimulation];
        self.startStopDecoderButton.title = @"STOP SIMULATION";
        self.startStopDecoderButton.contentTintColor = [NSColor systemRedColor];
        if (self.logHandler) self.logHandler(@"CW Simulation / Practice Mode active.");
    } else {
        [self.decoder stopSimulation];
        self.startStopDecoderButton.title = @"START DECODER";
        self.startStopDecoderButton.contentTintColor = [NSColor systemGreenColor];
        if (self.logHandler) self.logHandler(@"CW Simulation stopped.");
    }
}

- (void)pitchSliderChanged:(NSSlider *)sender {
    [self.decoder setPitch:sender.doubleValue];
    self.keyer.sidetonePitchHz = sender.doubleValue;
    self.pitchValueLabel.stringValue = [NSString stringWithFormat:@"%.0fHz", sender.doubleValue];
}

- (void)toggleAFC:(NSButton *)sender {
    self.decoder.afcEnabled = (sender.state == NSControlStateValueOn);
}

- (void)wpmStepperChanged:(NSStepper *)sender {
    self.keyer.wpm = sender.integerValue;
    self.wpmLabel.stringValue = [NSString stringWithFormat:@"%ld WPM", (long)sender.integerValue];
    [self.decoder setNominalWPM:(double)sender.integerValue];
}

- (void)toggleCutNumbers:(NSButton *)sender {
    self.keyer.useCutNumbers = (sender.state == NSControlStateValueOn);
}

- (void)updateAudioDeviceMenu {
    if (!self.audioDevicePopup) return;
    [self.audioDevicePopup removeAllItems];
    NSArray<NSDictionary<NSString *, NSString *> *> *devices = self.decoder.availableAudioInputDevices;
    self.audioDevicePopup.enabled = YES;
    NSMenuItem *selectedItem = nil;
    for (NSInteger i = 0; i < (NSInteger)devices.count; i++) {
        NSDictionary *d = devices[i];
        NSString *disp = d[@"displayName"] ?: d[@"name"] ?: [NSString stringWithFormat:@"Audio Device %ld", (long)i];
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:disp action:@selector(audioDeviceChanged:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = d[@"uid"];
        [self.audioDevicePopup.menu addItem:item];
        if (self.decoder.selectedAudioDeviceUID && [d[@"uid"] isEqualToString:self.decoder.selectedAudioDeviceUID]) {
            selectedItem = item;
        }
    }

    [self.audioDevicePopup.menu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *refreshItem = [[NSMenuItem alloc] initWithTitle:@"🔄 Refresh Audio Devices..." action:@selector(refreshAudioDevicesClicked:) keyEquivalent:@""];
    refreshItem.target = self;
    refreshItem.representedObject = @"__REFRESH__";
    [self.audioDevicePopup.menu addItem:refreshItem];

    if (selectedItem) {
        [self.audioDevicePopup selectItem:selectedItem];
    } else {
        // Never display a different device as selected when the saved route is absent.
        NSString *title = self.decoder.selectedAudioDeviceUID.length ? @"Selected input unavailable — choose input…" : @"Choose audio input…";
        NSMenuItem *missing = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
        missing.enabled = NO;
        [self.audioDevicePopup.menu insertItem:missing atIndex:0];
        [self.audioDevicePopup selectItem:missing];
    }
}

- (void)applyStationInputDeviceUID:(NSString *)uid {
    if (self.hasLocalAudioSelection || !uid.length || self.decoder.isListening || self.decoder.isSimulationActive) return;
    // Cancel any pending permission request before replacing an inherited route.
    if (![self.decoder.selectedAudioDeviceUID isEqualToString:uid]) [self.decoder stopListening];
    self.decoder.preserveDeviceSelection = YES;
    self.decoder.selectedAudioDeviceUID = uid;
    [self updateAudioDeviceMenu];
}

- (void)refreshAudioDevicesClicked:(id)sender {
    (void)sender;
    [self.decoder refreshAudioDevices];
    [self updateAudioDeviceMenu];
    if (self.logHandler) {
        self.logHandler(@"[CW Audio] Audio devices refreshed. USB interfaces re-enumerated.");
    }
}

- (void)audioDeviceChanged:(id)sender {
    NSMenuItem *item = [sender isKindOfClass:NSMenuItem.class] ? sender :
        ([sender isKindOfClass:NSPopUpButton.class] ? [sender selectedItem] : nil);
    if (!item) return;
    NSString *uid = item.representedObject;
    if ([uid isEqualToString:@"__REFRESH__"]) {
        [self refreshAudioDevicesClicked:sender];
        return;
    }
    if (uid.length) {
        BOOL changed = ![self.decoder.selectedAudioDeviceUID isEqualToString:uid];
        BOOL resume = self.decoder.isListening && !self.decoder.isSimulationActive;
        if (changed && !self.decoder.isSimulationActive) [self.decoder stopListening];
        self.hasLocalAudioSelection = YES;
        self.decoder.preserveDeviceSelection = YES;
        self.decoder.selectedAudioDeviceUID = uid;
        [NSUserDefaults.standardUserDefaults setObject:uid forKey:CWInputPreferenceKey];
        if (self.logHandler) {
            self.logHandler([NSString stringWithFormat:@"Selected audio input device: %@", item.title]);
        }
        if (changed && resume) [self.decoder startListening];
        [self updateAudioDeviceMenu];
    }
}

- (void)clearTerminal:(id)sender {
    (void)sender;
    [self.decoder clearBuffer];
    [self.terminalTextView setString:@""];
}

- (void)advanceQSOAction:(id)sender {
    (void)sender;
    __weak typeof(self) weakSelf = self;
    [self.assistant advanceQSOStepWithAction:^(NSString * _Nonnull macroToTransmit) {
        typeof(self) strongSelf = weakSelf;
        if (strongSelf && macroToTransmit.length > 0) {
            [strongSelf.keyer transmitText:macroToTransmit
                                targetCall:strongSelf.assistant.activeTargetCallsign
                                       rst:strongSelf.assistant.activeRstSent
                                      name:strongSelf.assistant.activeName
                                       qth:strongSelf.assistant.activeQTH];
        }
    }];
}

- (void)toggleAutoCQ:(id)sender {
    (void)sender;
    if (self.keyer.isAutoCQActive) {
        [self.keyer stopAutoCQ];
        self.autoCQButton.title = @"Auto-CQ Repeater";
        self.autoCQCountdownLabel.stringValue = @"";
    } else {
        [self.keyer startAutoCQWithTemplate:@"CQ CQ DE {MYCALL} {MYCALL} K" targetCall:@""];
        self.autoCQButton.title = @"Stop Auto-CQ";
    }
}

- (void)macroButtonClicked:(NSButton *)sender {
    NSInteger idx = sender.tag;
    [self.keyer triggerMacroAtIndex:idx
                         targetCall:self.assistant.activeTargetCallsign
                                rst:self.assistant.activeRstSent
                               name:self.assistant.activeName
                                qth:self.assistant.activeQTH];
}

- (void)txSendClicked:(id)sender {
    (void)sender;
    NSString *txt = self.txInputField.stringValue;
    if (txt.length == 0) return;
    [self.keyer transmitText:txt
                  targetCall:self.assistant.activeTargetCallsign
                         rst:self.assistant.activeRstSent
                        name:self.assistant.activeName
                         qth:self.assistant.activeQTH];
    self.txInputField.stringValue = @"";
}

- (void)txAbortClicked:(id)sender {
    (void)sender;
    [self.keyer abortTransmission];
    [self.keyer stopAutoCQ];
}

- (void)exportADIFClicked:(id)sender {
    (void)sender;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Export Station Log (ADIF)";
    panel.nameFieldStringValue = @"Lab599_CW_Logbook.adi";
    if (@available(macOS 11.0, *)) {
        panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"adi"] ?: UTTypePlainText];
    }

    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSError *err = nil;
            BOOL ok = [self.assistant exportADIFToFileURL:panel.URL error:&err];
            if (ok && self.logHandler) {
                self.logHandler([NSString stringWithFormat:@"Exported %lu contacts to %@",
                                 (unsigned long)self.assistant.loggedContacts.count, panel.URL.path]);
            }
        }
    }];
}

- (void)clearLogClicked:(id)sender {
    (void)sender;
    [self.assistant clearLog];
    [self.logTableView reloadData];
}

#pragma mark - Table View Data Source & Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.cqRosterTableView) {
        return self.assistant.heardStations.count;
    } else if (tableView == self.logTableView) {
        return self.assistant.loggedContacts.count;
    }
    return 0;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView == self.cqRosterTableView) {
        NSArray<TX500CWHeardStation *> *stations = self.assistant.heardStations;
        if (row < 0 || row >= (NSInteger)stations.count) return nil;
        TX500CWHeardStation *st = stations[row];

        if ([tableColumn.identifier isEqualToString:@"call"]) {
            NSTextField *tf = [tableView makeViewWithIdentifier:@"callCell" owner:self];
            if (!tf) {
                tf = [NSTextField labelWithString:@""];
                tf.identifier = @"callCell";
                tf.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightBold];
                tf.textColor = [NSColor systemYellowColor];
            }
            tf.stringValue = st.callsign;
            return tf;
        } else if ([tableColumn.identifier isEqualToString:@"wpm"]) {
            NSTextField *tf = [tableView makeViewWithIdentifier:@"wpmCell" owner:self];
            if (!tf) {
                tf = [NSTextField labelWithString:@""];
                tf.identifier = @"wpmCell";
                tf.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
            }
            tf.stringValue = [NSString stringWithFormat:@"%.0f", st.wpm];
            return tf;
        } else if ([tableColumn.identifier isEqualToString:@"snr"]) {
            NSTextField *tf = [tableView makeViewWithIdentifier:@"snrCell" owner:self];
            if (!tf) {
                tf = [NSTextField labelWithString:@""];
                tf.identifier = @"snrCell";
                tf.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
            }
            tf.stringValue = [NSString stringWithFormat:@"%.0fdB", st.snrDb];
            return tf;
        } else if ([tableColumn.identifier isEqualToString:@"action"]) {
            NSButton *btn = [tableView makeViewWithIdentifier:@"actionCell" owner:self];
            if (!btn) {
                btn = [NSButton buttonWithTitle:@"" target:self action:@selector(rosterAnswerClicked:)];
                btn.identifier = @"actionCell";
                btn.bezelStyle = NSBezelStyleInline;
                btn.controlSize = NSControlSizeSmall;
                btn.contentTintColor = [NSColor systemGreenColor];
            }
            btn.title = [NSString stringWithFormat:@"Answer %@", st.callsign];
            btn.tag = row;
            return btn;
        }
    } else if (tableView == self.logTableView) {
        NSArray<TX500QSOContact *> *contacts = self.assistant.loggedContacts;
        if (row < 0 || row >= (NSInteger)contacts.count) return nil;
        TX500QSOContact *c = contacts[row];

        NSTextField *tf = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
        if (!tf) {
            tf = [NSTextField labelWithString:@""];
            tf.identifier = tableColumn.identifier;
            tf.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightRegular];
        }
        if ([tableColumn.identifier isEqualToString:@"logCall"]) {
            tf.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightBold];
            tf.stringValue = c.callsign ?: @"";
        } else if ([tableColumn.identifier isEqualToString:@"logBand"]) {
            tf.stringValue = c.band ?: @"";
        } else if ([tableColumn.identifier isEqualToString:@"logFreq"]) {
            tf.stringValue = [NSString stringWithFormat:@"%.4f", c.frequencyMHz];
        } else if ([tableColumn.identifier isEqualToString:@"logMode"]) {
            tf.stringValue = c.mode ?: @"";
        } else if ([tableColumn.identifier isEqualToString:@"logSent"]) {
            tf.stringValue = c.rstSent ?: @"";
        } else if ([tableColumn.identifier isEqualToString:@"logRcvd"]) {
            tf.stringValue = c.rstRcvd ?: @"";
        } else if ([tableColumn.identifier isEqualToString:@"logTime"]) {
            tf.stringValue = [NSString stringWithFormat:@"%@ %@", c.qsoDate ?: @"", c.timeOn ?: @""];
        }
        return tf;
    }
    return nil;
}

- (void)rosterAnswerClicked:(NSButton *)sender {
    NSInteger row = sender.tag;
    NSArray<TX500CWHeardStation *> *stations = self.assistant.heardStations;
    if (row < 0 || row >= (NSInteger)stations.count) return;
    TX500CWHeardStation *st = stations[row];

    [self.assistant selectAndAnswerStation:st];
    self.keyer.wpm = (NSInteger)st.wpm;
    self.wpmStepper.integerValue = self.keyer.wpm;
    self.wpmLabel.stringValue = [NSString stringWithFormat:@"%ld WPM", (long)self.keyer.wpm];
    [self.decoder setNominalWPM:st.wpm];

    // Trigger immediate transmission of answer
    [self.keyer transmitText:@"{CALL} DE {MYCALL} {MYCALL} K"
                  targetCall:st.callsign
                         rst:@"599"
                        name:@""
                         qth:@""];
}

@end
