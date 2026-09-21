//
//  TX500LogbookController.m
//  Lab599 Utility
//
//  Complete Voice QSO Logger, Callsign Intelligence HUD & Cloud Logbook Controller
//

#import "TX500LogbookController.h"
#import "TX500CloudSettingsController.h"
#import "TX500WebAuthenticatorController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TX500LogbookController ()

@property (nonatomic, strong, readwrite) NSView *view;

// Header & Stats
@property (nonatomic, strong) NSTextField *titleLabel;
@property (nonatomic, strong) NSTextField *statsLabel;
@property (nonatomic, strong) NSBox *qrzPill;
@property (nonatomic, strong) NSBox *lotwPill;
@property (nonatomic, strong) NSBox *clublogPill;
@property (nonatomic, strong) NSBox *eqslPill;
@property (nonatomic, strong) NSTextField *qrzPillLabel;
@property (nonatomic, strong) NSTextField *lotwPillLabel;
@property (nonatomic, strong) NSTextField *clublogPillLabel;
@property (nonatomic, strong) NSTextField *eqslPillLabel;

// Voice QSO Logger Controls
@property (nonatomic, strong) NSBox *voiceLoggerCard;
@property (nonatomic, strong) NSTextField *callsignField;
@property (nonatomic, strong) NSTextField *freqField;
@property (nonatomic, strong) NSPopUpButton *bandPopup;
@property (nonatomic, strong) NSPopUpButton *modePopup;
@property (nonatomic, strong) NSTextField *rstSentField;
@property (nonatomic, strong) NSTextField *rstRcvdField;
@property (nonatomic, strong) NSTextField *nameField;
@property (nonatomic, strong) NSTextField *qthField;
@property (nonatomic, strong) NSTextField *stateField;
@property (nonatomic, strong) NSTextField *countryField;
@property (nonatomic, strong) NSTextField *gridField;
@property (nonatomic, strong) NSTextField *notesField;
@property (nonatomic, strong) NSButton *logContactButton;
@property (nonatomic, strong) NSButton *clearButton;

// Station HUD
@property (nonatomic, strong) NSImageView *avatarImageView;
@property (nonatomic, strong) NSTextField *hudNameLabel;
@property (nonatomic, strong) NSTextField *hudLocationLabel;
@property (nonatomic, strong) NSTextField *hudGridLabel;
@property (nonatomic, strong) NSTextField *hudBadgesLabel;
@property (nonatomic, strong) NSProgressIndicator *lookupSpinner;

// Logbook Table
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSPopUpButton *filterBandPopup;
@property (nonatomic, strong) NSPopUpButton *filterModePopup;
@property (nonatomic, strong) NSTableView *tableView;
@property (nonatomic, strong) NSMutableArray<TX500LogRecord *> *displayedContacts;
@property (nonatomic, strong) NSTextField *statusConsoleLabel;

// Radio State
@property (nonatomic, assign) uint64_t currentFrequencyHz;
@property (nonatomic, copy) NSString *currentMode;

// Debounce Timer for Callsign Lookup
@property (nonatomic, strong, nullable) NSTimer *lookupDebounceTimer;

@end

@implementation TX500LogbookController

- (instancetype)init {
    self = [super init];
    if (self) {
        _currentFrequencyHz = 14200000;
        _currentMode = @"USB";
        _displayedContacts = [NSMutableArray array];

        [self buildUserInterface];
        [self reloadTableData];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(logbookDidChange:)
                                                     name:TX500LogbookDidChangeNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(cloudSyncStatusDidChange:)
                                                     name:TX500CloudSyncStatusDidChangeNotification
                                                   object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(cloudSettingsDidChange:)
                                                     name:TX500CloudSettingsDidChangeNotification
                                                   object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.lookupDebounceTimer invalidate];
}

#pragma mark - UI Card Factory

- (NSBox *)createCardBox {
    NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
    box.boxType = NSBoxCustom;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.cornerRadius = 6.0;
    box.borderWidth = 1.0;
    box.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.18];
    box.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.06];
    box.contentViewMargins = NSMakeSize(8, 8);
    return box;
}

- (NSBox *)createStatusPillWithText:(NSString *)text color:(NSColor *)color outLabel:(NSTextField * _Nullable * _Nullable)outLabel {
    NSBox *box = [[NSBox alloc] initWithFrame:NSZeroRect];
    box.boxType = NSBoxCustom;
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.cornerRadius = 10.0;
    box.borderWidth = 1.0;
    box.borderColor = [color colorWithAlphaComponent:0.4];
    box.fillColor = [color colorWithAlphaComponent:0.12];

    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    lbl.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    lbl.textColor = color;
    [box addSubview:lbl];

    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:8.0],
        [lbl.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-8.0],
        [lbl.centerYAnchor constraintEqualToAnchor:box.centerYAnchor],
        [box.heightAnchor constraintEqualToConstant:20.0]
    ]];

    if (outLabel) {
        *outLabel = lbl;
    }
    return box;
}

#pragma mark - Build UI

- (void)buildUserInterface {
    self.view = [[NSView alloc] initWithFrame:NSZeroRect];
    self.view.translatesAutoresizingMaskIntoConstraints = NO;

    // Header Card (2-Row Balanced Layout)
    NSBox *headerCard = [self createCardBox];
    [self.view addSubview:headerCard];

    self.titleLabel = [NSTextField labelWithString:@"Logbook & Cloud Ecosystem"];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.font = [NSFont systemFontOfSize:16.0 weight:NSFontWeightBold];
    [headerCard addSubview:self.titleLabel];

    self.statsLabel = [NSTextField labelWithString:@"Total QSOs: 0 | Confirmed: 0"];
    self.statsLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statsLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
    self.statsLabel.textColor = [NSColor secondaryLabelColor];
    [headerCard addSubview:self.statsLabel];

    // Cloud Pills Stack
    NSStackView *pillsStack = [[NSStackView alloc] init];
    pillsStack.translatesAutoresizingMaskIntoConstraints = NO;
    pillsStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pillsStack.spacing = 8.0;

    NSTextField *qrzLbl = nil, *lotwLbl = nil, *clLbl = nil, *eqslLbl = nil;
    self.qrzPill = [self createStatusPillWithText:@"QRZ: Ready" color:[NSColor systemBlueColor] outLabel:&qrzLbl];
    self.lotwPill = [self createStatusPillWithText:@"LoTW: Ready" color:[NSColor systemGreenColor] outLabel:&lotwLbl];
    self.clublogPill = [self createStatusPillWithText:@"ClubLog: Ready" color:[NSColor systemOrangeColor] outLabel:&clLbl];
    self.eqslPill = [self createStatusPillWithText:@"eQSL: Ready" color:[NSColor systemPurpleColor] outLabel:&eqslLbl];

    self.qrzPillLabel = qrzLbl;
    self.lotwPillLabel = lotwLbl;
    self.clublogPillLabel = clLbl;
    self.eqslPillLabel = eqslLbl;

    NSClickGestureRecognizer *qrzClick = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(qrzPillClicked)];
    [self.qrzPill addGestureRecognizer:qrzClick];

    NSClickGestureRecognizer *lotwClick = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(lotwPillClicked)];
    [self.lotwPill addGestureRecognizer:lotwClick];

    NSClickGestureRecognizer *clClick = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(clublogPillClicked)];
    [self.clublogPill addGestureRecognizer:clClick];

    NSClickGestureRecognizer *eqslClick = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(eqslPillClicked)];
    [self.eqslPill addGestureRecognizer:eqslClick];

    [pillsStack addArrangedSubview:self.qrzPill];
    [pillsStack addArrangedSubview:self.lotwPill];
    [pillsStack addArrangedSubview:self.clublogPill];
    [pillsStack addArrangedSubview:self.eqslPill];
    [headerCard addSubview:pillsStack];

    // Action Buttons
    NSButton *btnSync = [NSButton buttonWithTitle:@"Sync All" target:self action:@selector(syncAllPending)];
    btnSync.bezelStyle = NSBezelStyleRounded;
    btnSync.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *btnExport = [NSButton buttonWithTitle:@"Export ADIF..." target:self action:@selector(exportADIF)];
    btnExport.bezelStyle = NSBezelStyleRounded;
    btnExport.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *btnImport = [NSButton buttonWithTitle:@"Import ADIF..." target:self action:@selector(importADIF)];
    btnImport.bezelStyle = NSBezelStyleRounded;
    btnImport.translatesAutoresizingMaskIntoConstraints = NO;

    NSButton *btnSettings = [NSButton buttonWithTitle:@"Cloud Settings..." target:self action:@selector(openCloudSettingsSheet)];
    btnSettings.bezelStyle = NSBezelStyleRounded;
    btnSettings.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *headerActions = [[NSStackView alloc] init];
    headerActions.translatesAutoresizingMaskIntoConstraints = NO;
    headerActions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    headerActions.spacing = 8.0;
    [headerActions addArrangedSubview:btnSync];
    [headerActions addArrangedSubview:btnImport];
    [headerActions addArrangedSubview:btnExport];
    [headerActions addArrangedSubview:btnSettings];
    [headerCard addSubview:headerActions];

    [NSLayoutConstraint activateConstraints:@[
        [headerCard.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8.0],
        [headerCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8.0],
        [headerCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8.0],
        [headerCard.heightAnchor constraintEqualToConstant:74.0],

        // Row 1: Title (left) & Cloud Pills (right)
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:headerCard.leadingAnchor constant:12.0],
        [self.titleLabel.topAnchor constraintEqualToAnchor:headerCard.topAnchor constant:10.0],

        [pillsStack.trailingAnchor constraintEqualToAnchor:headerCard.trailingAnchor constant:-12.0],
        [pillsStack.centerYAnchor constraintEqualToAnchor:self.titleLabel.centerYAnchor],
        [pillsStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.titleLabel.trailingAnchor constant:10.0],

        // Row 2: Stats (left) & Actions (right)
        [self.statsLabel.leadingAnchor constraintEqualToAnchor:headerCard.leadingAnchor constant:12.0],
        [self.statsLabel.bottomAnchor constraintEqualToAnchor:headerCard.bottomAnchor constant:-10.0],

        [headerActions.trailingAnchor constraintEqualToAnchor:headerCard.trailingAnchor constant:-12.0],
        [headerActions.centerYAnchor constraintEqualToAnchor:self.statsLabel.centerYAnchor],
        [headerActions.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.statsLabel.trailingAnchor constant:10.0]
    ]];

    // Voice & Rapid QSO Logger Card
    self.voiceLoggerCard = [self createCardBox];
    [self.view addSubview:self.voiceLoggerCard];

    [self setupVoiceLoggerLayout];

    // Logbook Table & Filter Card
    NSBox *tableCard = [self createCardBox];
    [self.view addSubview:tableCard];

    [self setupLogbookTableLayoutInBox:tableCard];

    // Layout Constraints between Cards
    [NSLayoutConstraint activateConstraints:@[
        [self.voiceLoggerCard.topAnchor constraintEqualToAnchor:headerCard.bottomAnchor constant:8.0],
        [self.voiceLoggerCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8.0],
        [self.voiceLoggerCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8.0],
        [self.voiceLoggerCard.heightAnchor constraintEqualToConstant:116.0],

        [tableCard.topAnchor constraintEqualToAnchor:self.voiceLoggerCard.bottomAnchor constant:8.0],
        [tableCard.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:8.0],
        [tableCard.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-8.0],
        [tableCard.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-8.0]
    ]];

    NSLayoutConstraint *tableCardMinH = [tableCard.heightAnchor constraintGreaterThanOrEqualToConstant:320.0];
    tableCardMinH.priority = NSLayoutPriorityDefaultHigh;
    tableCardMinH.active = YES;

    NSLayoutConstraint *viewMinH = [self.view.heightAnchor constraintGreaterThanOrEqualToConstant:540.0];
    viewMinH.priority = NSLayoutPriorityDefaultHigh;
    viewMinH.active = YES;

    [self updateCloudStatusPills];
}

#pragma mark - Voice Logger Layout

- (void)setupVoiceLoggerLayout {
    // Left: Callsign & Live Telemetry Form
    NSTextField *lblCall = [NSTextField labelWithString:@"Callsign:"];
    lblCall.translatesAutoresizingMaskIntoConstraints = NO;
    lblCall.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightBold];
    [self.voiceLoggerCard addSubview:lblCall];

    self.callsignField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.callsignField.translatesAutoresizingMaskIntoConstraints = NO;
    self.callsignField.placeholderString = @"e.g. W1AW";
    self.callsignField.font = [NSFont monospacedSystemFontOfSize:14.0 weight:NSFontWeightBold];
    self.callsignField.delegate = self;
    [self.voiceLoggerCard addSubview:self.callsignField];

    self.lookupSpinner = [[NSProgressIndicator alloc] init];
    self.lookupSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.lookupSpinner.style = NSProgressIndicatorStyleSpinning;
    self.lookupSpinner.controlSize = NSControlSizeSmall;
    self.lookupSpinner.displayedWhenStopped = NO;
    [self.voiceLoggerCard addSubview:self.lookupSpinner];

    NSTextField *lblFreq = [NSTextField labelWithString:@"Freq / Band:"];
    lblFreq.translatesAutoresizingMaskIntoConstraints = NO;
    lblFreq.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblFreq];

    self.freqField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.freqField.translatesAutoresizingMaskIntoConstraints = NO;
    self.freqField.stringValue = [NSString stringWithFormat:@"%.3f", (double)self.currentFrequencyHz / 1e6];
    self.freqField.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightMedium];
    [self.voiceLoggerCard addSubview:self.freqField];

    self.bandPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.bandPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bandPopup addItemsWithTitles:@[@"160m", @"80m", @"60m", @"40m", @"30m", @"20m", @"17m", @"15m", @"12m", @"10m", @"6m", @"2m", @"70cm"]];
    [self.bandPopup selectItemWithTitle:[TX500LogRecord bandForFrequencyHz:self.currentFrequencyHz]];
    [self.voiceLoggerCard addSubview:self.bandPopup];

    self.modePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.modePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modePopup addItemsWithTitles:@[@"USB", @"LSB", @"AM", @"FM", @"CW", @"FT8", @"FT4"]];
    [self.modePopup selectItemWithTitle:self.currentMode];
    [self.voiceLoggerCard addSubview:self.modePopup];

    NSTextField *lblRst = [NSTextField labelWithString:@"RST (S/R):"];
    lblRst.translatesAutoresizingMaskIntoConstraints = NO;
    lblRst.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblRst];

    self.rstSentField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.rstSentField.translatesAutoresizingMaskIntoConstraints = NO;
    self.rstSentField.stringValue = @"59";
    self.rstSentField.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.rstSentField];

    self.rstRcvdField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.rstRcvdField.translatesAutoresizingMaskIntoConstraints = NO;
    self.rstRcvdField.stringValue = @"59";
    self.rstRcvdField.font = [NSFont monospacedSystemFontOfSize:12.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.rstRcvdField];

    // Right: Action Buttons
    self.logContactButton = [NSButton buttonWithTitle:@"Log QSO ↵" target:self action:@selector(logContactAction)];
    self.logContactButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.logContactButton.bezelStyle = NSBezelStyleRounded;
    self.logContactButton.keyEquivalent = @"\r"; // Enter key triggers log
    self.logContactButton.font = [NSFont systemFontOfSize:12.5 weight:NSFontWeightBold];
    [self.voiceLoggerCard addSubview:self.logContactButton];

    self.clearButton = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearVoiceLoggerFields)];
    self.clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.clearButton.bezelStyle = NSBezelStyleRounded;
    [self.voiceLoggerCard addSubview:self.clearButton];

    // Row 2: Notes
    NSTextField *lblNotes = [NSTextField labelWithString:@"Notes:"];
    lblNotes.translatesAutoresizingMaskIntoConstraints = NO;
    lblNotes.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblNotes];

    self.notesField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.notesField.translatesAutoresizingMaskIntoConstraints = NO;
    self.notesField.placeholderString = @"QSO comments, antenna, power...";
    self.notesField.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.notesField];

    // Middle/Right: Station Intelligence HUD Card
    NSBox *hudBox = [self createCardBox];
    hudBox.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.04];
    [self.voiceLoggerCard addSubview:hudBox];

    self.avatarImageView = [[NSImageView alloc] initWithFrame:NSZeroRect];
    self.avatarImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.avatarImageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    self.avatarImageView.wantsLayer = YES;
    self.avatarImageView.layer.cornerRadius = 4.0;
    self.avatarImageView.layer.masksToBounds = YES;
    self.avatarImageView.layer.borderWidth = 1.0;
    self.avatarImageView.layer.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.2].CGColor;
    if (@available(macOS 11.0, *)) {
        self.avatarImageView.image = [NSImage imageWithSystemSymbolName:@"person.crop.square" accessibilityDescription:@"Avatar"];
    }
    [hudBox addSubview:self.avatarImageView];

    self.hudNameLabel = [NSTextField labelWithString:@"Operator Name"];
    self.hudNameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudNameLabel.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightBold];
    [hudBox addSubview:self.hudNameLabel];

    self.hudLocationLabel = [NSTextField labelWithString:@"QTH / Location / Country"];
    self.hudLocationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudLocationLabel.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    self.hudLocationLabel.textColor = [NSColor secondaryLabelColor];
    [hudBox addSubview:self.hudLocationLabel];

    self.hudGridLabel = [NSTextField labelWithString:@"Grid: --"];
    self.hudGridLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudGridLabel.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    self.hudGridLabel.textColor = [NSColor secondaryLabelColor];
    [hudBox addSubview:self.hudGridLabel];

    self.hudBadgesLabel = [NSTextField labelWithString:@"Callbook Ready"];
    self.hudBadgesLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudBadgesLabel.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
    self.hudBadgesLabel.textColor = [NSColor controlAccentColor];
    [hudBox addSubview:self.hudBadgesLabel];

    // Form Auto Layout Constraints
    [NSLayoutConstraint activateConstraints:@[
        // Row 1: Labels & Fields
        [lblCall.leadingAnchor constraintEqualToAnchor:self.voiceLoggerCard.leadingAnchor constant:12.0],
        [lblCall.topAnchor constraintEqualToAnchor:self.voiceLoggerCard.topAnchor constant:10.0],

        [self.callsignField.leadingAnchor constraintEqualToAnchor:lblCall.leadingAnchor],
        [self.callsignField.topAnchor constraintEqualToAnchor:lblCall.bottomAnchor constant:4.0],
        [self.callsignField.widthAnchor constraintEqualToConstant:105.0],
        [self.callsignField.heightAnchor constraintEqualToConstant:24.0],

        [self.lookupSpinner.leadingAnchor constraintEqualToAnchor:self.callsignField.trailingAnchor constant:4.0],
        [self.lookupSpinner.centerYAnchor constraintEqualToAnchor:self.callsignField.centerYAnchor],

        [lblFreq.leadingAnchor constraintEqualToAnchor:self.lookupSpinner.trailingAnchor constant:8.0],
        [lblFreq.topAnchor constraintEqualToAnchor:lblCall.topAnchor],

        [self.freqField.leadingAnchor constraintEqualToAnchor:lblFreq.leadingAnchor],
        [self.freqField.topAnchor constraintEqualToAnchor:self.callsignField.topAnchor],
        [self.freqField.widthAnchor constraintEqualToConstant:62.0],
        [self.freqField.heightAnchor constraintEqualToConstant:24.0],

        [self.bandPopup.leadingAnchor constraintEqualToAnchor:self.freqField.trailingAnchor constant:4.0],
        [self.bandPopup.centerYAnchor constraintEqualToAnchor:self.freqField.centerYAnchor],
        [self.bandPopup.widthAnchor constraintEqualToConstant:60.0],

        [self.modePopup.leadingAnchor constraintEqualToAnchor:self.bandPopup.trailingAnchor constant:4.0],
        [self.modePopup.centerYAnchor constraintEqualToAnchor:self.bandPopup.centerYAnchor],
        [self.modePopup.widthAnchor constraintEqualToConstant:58.0],

        [lblRst.leadingAnchor constraintEqualToAnchor:self.modePopup.trailingAnchor constant:8.0],
        [lblRst.topAnchor constraintEqualToAnchor:lblCall.topAnchor],

        [self.rstSentField.leadingAnchor constraintEqualToAnchor:lblRst.leadingAnchor],
        [self.rstSentField.topAnchor constraintEqualToAnchor:self.callsignField.topAnchor],
        [self.rstSentField.widthAnchor constraintEqualToConstant:30.0],
        [self.rstSentField.heightAnchor constraintEqualToConstant:24.0],

        [self.rstRcvdField.leadingAnchor constraintEqualToAnchor:self.rstSentField.trailingAnchor constant:3.0],
        [self.rstRcvdField.centerYAnchor constraintEqualToAnchor:self.rstSentField.centerYAnchor],
        [self.rstRcvdField.widthAnchor constraintEqualToConstant:30.0],
        [self.rstRcvdField.heightAnchor constraintEqualToConstant:24.0],

        // Row 1 Action Buttons
        [self.logContactButton.trailingAnchor constraintEqualToAnchor:self.voiceLoggerCard.trailingAnchor constant:-12.0],
        [self.logContactButton.centerYAnchor constraintEqualToAnchor:self.callsignField.centerYAnchor],
        [self.logContactButton.widthAnchor constraintEqualToConstant:86.0],
        [self.logContactButton.heightAnchor constraintEqualToConstant:26.0],

        [self.clearButton.trailingAnchor constraintEqualToAnchor:self.logContactButton.leadingAnchor constant:-6.0],
        [self.clearButton.centerYAnchor constraintEqualToAnchor:self.callsignField.centerYAnchor],
        [self.clearButton.widthAnchor constraintEqualToConstant:54.0],
        [self.clearButton.heightAnchor constraintEqualToConstant:26.0],
        [self.clearButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.rstRcvdField.trailingAnchor constant:6.0],

        // Row 2: Notes
        [lblNotes.leadingAnchor constraintEqualToAnchor:lblCall.leadingAnchor],
        [lblNotes.topAnchor constraintEqualToAnchor:self.callsignField.bottomAnchor constant:8.0],

        [self.notesField.leadingAnchor constraintEqualToAnchor:lblNotes.leadingAnchor],
        [self.notesField.topAnchor constraintEqualToAnchor:lblNotes.bottomAnchor constant:3.0],
        [self.notesField.trailingAnchor constraintEqualToAnchor:hudBox.leadingAnchor constant:-16.0],
        [self.notesField.heightAnchor constraintEqualToConstant:24.0],

        // Row 2: HUD Box (Anchored neatly on the right at 340pt width)
        [hudBox.topAnchor constraintEqualToAnchor:lblNotes.topAnchor constant:-2.0],
        [hudBox.bottomAnchor constraintEqualToAnchor:self.voiceLoggerCard.bottomAnchor constant:-8.0],
        [hudBox.trailingAnchor constraintEqualToAnchor:self.voiceLoggerCard.trailingAnchor constant:-12.0],
        [hudBox.widthAnchor constraintEqualToConstant:340.0],

        [self.avatarImageView.leadingAnchor constraintEqualToAnchor:hudBox.leadingAnchor constant:8.0],
        [self.avatarImageView.centerYAnchor constraintEqualToAnchor:hudBox.centerYAnchor],
        [self.avatarImageView.widthAnchor constraintEqualToConstant:38.0],
        [self.avatarImageView.heightAnchor constraintEqualToConstant:38.0],

        [self.hudNameLabel.leadingAnchor constraintEqualToAnchor:self.avatarImageView.trailingAnchor constant:8.0],
        [self.hudNameLabel.topAnchor constraintEqualToAnchor:hudBox.topAnchor constant:4.0],
        [self.hudNameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.hudGridLabel.leadingAnchor constant:-8.0],

        [self.hudLocationLabel.leadingAnchor constraintEqualToAnchor:self.hudNameLabel.leadingAnchor],
        [self.hudLocationLabel.topAnchor constraintEqualToAnchor:self.hudNameLabel.bottomAnchor constant:2.0],
        [self.hudLocationLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.hudBadgesLabel.leadingAnchor constant:-8.0],

        [self.hudGridLabel.trailingAnchor constraintEqualToAnchor:hudBox.trailingAnchor constant:-10.0],
        [self.hudGridLabel.topAnchor constraintEqualToAnchor:hudBox.topAnchor constant:4.0],

        [self.hudBadgesLabel.trailingAnchor constraintEqualToAnchor:self.hudGridLabel.trailingAnchor],
        [self.hudBadgesLabel.topAnchor constraintEqualToAnchor:self.hudGridLabel.bottomAnchor constant:2.0]
    ]];
}

#pragma mark - Logbook Table Layout

- (void)setupLogbookTableLayoutInBox:(NSBox *)box {
    // Filter Bar
    self.searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.placeholderString = @"Search calls, names, countries...";
    self.searchField.delegate = self;
    [box addSubview:self.searchField];

    self.filterBandPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.filterBandPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.filterBandPopup addItemWithTitle:@"All Bands"];
    [self.filterBandPopup addItemsWithTitles:@[@"160m", @"80m", @"60m", @"40m", @"30m", @"20m", @"17m", @"15m", @"12m", @"10m", @"6m", @"2m", @"70cm"]];
    self.filterBandPopup.target = self;
    self.filterBandPopup.action = @selector(filterChanged:);
    [box addSubview:self.filterBandPopup];

    self.filterModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.filterModePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.filterModePopup addItemWithTitle:@"All Modes"];
    [self.filterModePopup addItemsWithTitles:@[@"USB", @"LSB", @"AM", @"FM", @"CW", @"FT8", @"FT4"]];
    self.filterModePopup.target = self;
    self.filterModePopup.action = @selector(filterChanged:);
    [box addSubview:self.filterModePopup];

    NSButton *btnDelete = [NSButton buttonWithTitle:@"Delete Selected" target:self action:@selector(deleteSelectedContact)];
    btnDelete.translatesAutoresizingMaskIntoConstraints = NO;
    btnDelete.bezelStyle = NSBezelStyleRounded;
    [box addSubview:btnDelete];

    // Scroll & TableView
    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    scrollView.hasVerticalScroller = YES;
    scrollView.hasHorizontalScroller = YES;
    scrollView.autohidesScrollers = YES;
    scrollView.borderType = NSBezelBorder;

    self.tableView = [[NSTableView alloc] initWithFrame:NSZeroRect];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.usesAlternatingRowBackgroundColors = YES;
    self.tableView.allowsMultipleSelection = YES;
    self.tableView.columnAutoresizingStyle = NSTableViewUniformColumnAutoresizingStyle;
    self.tableView.rowHeight = 22.0;
    self.tableView.gridStyleMask = NSTableViewSolidHorizontalGridLineMask;
    if (!self.tableView.headerView) {
        self.tableView.headerView = [[NSTableHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 100, 24)];
    }

    NSArray<NSDictionary *> *colDefs = @[
        @{@"id": @"DATE", @"title": @"Date", @"width": @85, @"minWidth": @80},
        @{@"id": @"TIME", @"title": @"Time (UTC)", @"width": @75, @"minWidth": @70},
        @{@"id": @"CALL", @"title": @"Callsign", @"width": @95, @"minWidth": @90},
        @{@"id": @"BAND", @"title": @"Band", @"width": @55, @"minWidth": @50},
        @{@"id": @"FREQ", @"title": @"Freq (MHz)", @"width": @80, @"minWidth": @75},
        @{@"id": @"MODE", @"title": @"Mode", @"width": @60, @"minWidth": @55},
        @{@"id": @"RST_SENT", @"title": @"RST (S)", @"width": @55, @"minWidth": @50},
        @{@"id": @"RST_RCVD", @"title": @"RST (R)", @"width": @55, @"minWidth": @50},
        @{@"id": @"NAME", @"title": @"Name", @"width": @120, @"minWidth": @100},
        @{@"id": @"QTH", @"title": @"QTH", @"width": @100, @"minWidth": @90},
        @{@"id": @"COUNTRY", @"title": @"Country", @"width": @110, @"minWidth": @100},
        @{@"id": @"GRID", @"title": @"Grid", @"width": @65, @"minWidth": @60},
        @{@"id": @"QRZ", @"title": @"QRZ", @"width": @72, @"minWidth": @68},
        @{@"id": @"LOTW", @"title": @"LoTW", @"width": @72, @"minWidth": @68},
        @{@"id": @"CLUBLOG", @"title": @"ClubLog", @"width": @75, @"minWidth": @70},
        @{@"id": @"EQSL", @"title": @"eQSL", @"width": @70, @"minWidth": @65}
    ];

    for (NSDictionary *d in colDefs) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:d[@"id"]];
        col.title = d[@"title"];
        col.width = [d[@"width"] doubleValue];
        col.minWidth = [d[@"minWidth"] doubleValue];
        col.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;
        [self.tableView addTableColumn:col];
    }

    scrollView.documentView = self.tableView;
    [box addSubview:scrollView];

    // Bottom Status Console
    self.statusConsoleLabel = [NSTextField labelWithString:@"Logbook database active. Ready to log contacts."];
    self.statusConsoleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusConsoleLabel.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    self.statusConsoleLabel.textColor = [NSColor secondaryLabelColor];
    [box addSubview:self.statusConsoleLabel];

    NSLayoutConstraint *tableHeightConstraint = [scrollView.heightAnchor constraintEqualToConstant:320.0];
    tableHeightConstraint.priority = NSLayoutPriorityDefaultHigh;

    NSLayoutConstraint *tableMinHeightConstraint = [scrollView.heightAnchor constraintGreaterThanOrEqualToConstant:260.0];
    tableMinHeightConstraint.priority = NSLayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [self.searchField.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:8.0],
        [self.searchField.topAnchor constraintEqualToAnchor:box.topAnchor constant:8.0],
        [self.searchField.widthAnchor constraintEqualToConstant:170.0],

        [self.filterBandPopup.leadingAnchor constraintEqualToAnchor:self.searchField.trailingAnchor constant:8.0],
        [self.filterBandPopup.centerYAnchor constraintEqualToAnchor:self.searchField.centerYAnchor],
        [self.filterBandPopup.widthAnchor constraintEqualToConstant:84.0],

        [self.filterModePopup.leadingAnchor constraintEqualToAnchor:self.filterBandPopup.trailingAnchor constant:8.0],
        [self.filterModePopup.centerYAnchor constraintEqualToAnchor:self.searchField.centerYAnchor],
        [self.filterModePopup.widthAnchor constraintEqualToConstant:84.0],

        [btnDelete.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-8.0],
        [btnDelete.centerYAnchor constraintEqualToAnchor:self.searchField.centerYAnchor],
        [btnDelete.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.filterModePopup.trailingAnchor constant:8.0],

        [scrollView.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor constant:8.0],
        [scrollView.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:8.0],
        [scrollView.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-8.0],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.statusConsoleLabel.topAnchor constant:-8.0],
        tableHeightConstraint,
        tableMinHeightConstraint,

        [self.statusConsoleLabel.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:10.0],
        [self.statusConsoleLabel.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10.0],
        [self.statusConsoleLabel.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-8.0],
        [self.statusConsoleLabel.heightAnchor constraintEqualToConstant:18.0]
    ]];
}

#pragma mark - Callsign Lookup Debounce & Execution

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == self.callsignField) {
        [self.lookupDebounceTimer invalidate];
        self.lookupDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.45
                                                                    target:self
                                                                  selector:@selector(triggerCallsignLookup)
                                                                  userInfo:nil
                                                                   repeats:NO];
    } else if (obj.object == self.searchField) {
        [self reloadTableData];
    }
}

- (void)triggerCallsignLookup {
    NSString *call = [self.callsignField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (call.length < 3) {
        [self resetStationHUD];
        return;
    }

    [self.lookupSpinner startAnimation:nil];
    self.hudBadgesLabel.stringValue = @"Looking up...";

    [[TX500CallsignLookupService sharedService] lookupCallsign:call completion:^(TX500LookupResult * _Nullable result, NSError * _Nullable error) {
        (void)error;
        [self.lookupSpinner stopAnimation:nil];
        if (result && result.hasData) {
            self.hudNameLabel.stringValue = result.name.length > 0 ? result.name : @"(Name Unavailable)";
            self.hudLocationLabel.stringValue = result.displayLocation.length > 0 ? result.displayLocation : @"Location unknown";
            self.hudGridLabel.stringValue = result.grid.length > 0 ? [NSString stringWithFormat:@"Grid: %@", result.grid] : @"Grid: --";

            NSMutableArray *badges = [NSMutableArray array];
            if (result.isLoTW) [badges addObject:@"LoTW Member"];
            if (result.isEQSL) [badges addObject:@"eQSL Member"];
            [badges addObject:[NSString stringWithFormat:@"Via %@", result.source]];
            self.hudBadgesLabel.stringValue = [badges componentsJoinedByString:@" • "];

            // Fetch station photo if present
            if (result.imageURL.length > 0) {
                [[TX500CallsignLookupService sharedService] fetchImageForURLString:result.imageURL completion:^(NSImage * _Nullable img) {
                    if (img) self.avatarImageView.image = img;
                }];
            } else {
                if (@available(macOS 11.0, *)) {
                    self.avatarImageView.image = [NSImage imageWithSystemSymbolName:@"person.crop.square" accessibilityDescription:@"Avatar"];
                }
            }

            // Update internal entry fields if empty
            if (self.nameField && self.nameField.stringValue.length == 0 && result.name.length > 0) {
                self.nameField.stringValue = result.name;
            }
        } else {
            self.hudNameLabel.stringValue = [call uppercaseString];
            self.hudLocationLabel.stringValue = @"Callbook record not found";
            self.hudGridLabel.stringValue = @"Grid: --";
            self.hudBadgesLabel.stringValue = @"Manual logging ready";
            if (@available(macOS 11.0, *)) {
                self.avatarImageView.image = [NSImage imageWithSystemSymbolName:@"person.crop.square" accessibilityDescription:@"Avatar"];
            }
        }
    }];
}

- (void)resetStationHUD {
    self.hudNameLabel.stringValue = @"Operator Name";
    self.hudLocationLabel.stringValue = @"QTH / Location / Country";
    self.hudGridLabel.stringValue = @"Grid: --";
    self.hudBadgesLabel.stringValue = @"Callbook Ready";
    if (@available(macOS 11.0, *)) {
        self.avatarImageView.image = [NSImage imageWithSystemSymbolName:@"person.crop.square" accessibilityDescription:@"Avatar"];
    }
}

#pragma mark - Voice QSO Logging

- (void)logContactAction {
    NSString *call = [[self.callsignField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if (call.length == 0) {
        NSBeep();
        return;
    }

    TX500LogRecord *rec = [[TX500LogRecord alloc] init];
    rec.callsign = call;

    double freqVal = [self.freqField.stringValue doubleValue];
    rec.frequencyHz = (freqVal > 0) ? (uint64_t)(freqVal * 1e6) : self.currentFrequencyHz;
    rec.band = self.bandPopup.selectedItem.title ?: [TX500LogRecord bandForFrequencyHz:rec.frequencyHz];
    rec.mode = self.modePopup.selectedItem.title ?: @"USB";
    rec.rstSent = self.rstSentField.stringValue.length > 0 ? self.rstSentField.stringValue : @"59";
    rec.rstRcvd = self.rstRcvdField.stringValue.length > 0 ? self.rstRcvdField.stringValue : @"59";
    rec.notes = self.notesField.stringValue;

    // Use HUD data if available
    if (![self.hudNameLabel.stringValue isEqualToString:@"Operator Name"] &&
        ![self.hudNameLabel.stringValue containsString:@"(Name Unavailable)"]) {
        rec.name = self.hudNameLabel.stringValue;
    }
    if (![self.hudLocationLabel.stringValue isEqualToString:@"QTH / Location / Country"] &&
        ![self.hudLocationLabel.stringValue containsString:@"not found"]) {
        NSArray *locParts = [self.hudLocationLabel.stringValue componentsSeparatedByString:@", "];
        if (locParts.count >= 1) rec.qth = locParts[0];
        if (locParts.count >= 2) rec.state = locParts[1];
        if (locParts.count >= 3) rec.country = locParts[2];
        else if (locParts.count == 2) rec.country = locParts[1];
    }
    if ([self.hudGridLabel.stringValue hasPrefix:@"Grid: "]) {
        NSString *g = [self.hudGridLabel.stringValue substringFromIndex:6];
        if (![g isEqualToString:@"--"]) rec.grid = g;
    }

    NSError *err = nil;
    if (![[TX500LogbookManager sharedManager] saveContact:rec error:&err]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"Failed to Save Contact";
        alert.informativeText = err.localizedDescription ?: @"Unknown error";
        [alert runModal];
        return;
    }

    // Zero-Click Cloud Upload Dispatch
    [[TX500CloudSyncEngine sharedEngine] uploadContactImmediately:rec completion:^(BOOL overallSuccess, NSString *summary) {
        (void)overallSuccess;
        self.statusConsoleLabel.stringValue = summary;
    }];

    [self clearVoiceLoggerFields];
    [self.callsignField becomeFirstResponder];
}

- (void)clearVoiceLoggerFields {
    self.callsignField.stringValue = @"";
    self.notesField.stringValue = @"";
    self.rstSentField.stringValue = @"59";
    self.rstRcvdField.stringValue = @"59";
    [self resetStationHUD];
}

- (void)focusCallsignField {
    [self.callsignField becomeFirstResponder];
}

#pragma mark - Radio CAT Sync

- (void)updateFrequencyHz:(uint64_t)freqHz mode:(NSString *)mode {
    self.currentFrequencyHz = freqHz;
    self.currentMode = mode ?: @"USB";

    dispatch_async(dispatch_get_main_queue(), ^{
        self.freqField.stringValue = [NSString stringWithFormat:@"%.3f", (double)freqHz / 1e6];
        NSString *band = [TX500LogRecord bandForFrequencyHz:freqHz];
        [self.bandPopup selectItemWithTitle:band];
        [self.modePopup selectItemWithTitle:self.currentMode];
    });
}

#pragma mark - Table Data & Filtering

- (void)filterChanged:(id)sender {
    (void)sender;
    [self reloadTableData];
}

- (void)logbookDidChange:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self reloadTableData];
    });
}

- (void)cloudSyncStatusDidChange:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.statusConsoleLabel.stringValue = [TX500CloudSyncEngine sharedEngine].lastStatusMessage;
        [self updateCloudStatusPills];
        [self reloadTableData];
    });
}

- (void)reloadTableData {
    NSString *query = self.searchField.stringValue;
    NSString *band = self.filterBandPopup.selectedItem.title;
    if ([band isEqualToString:@"All Bands"]) band = nil;
    NSString *mode = self.filterModePopup.selectedItem.title;
    if ([mode isEqualToString:@"All Modes"]) mode = nil;

    NSArray<TX500LogRecord *> *list = [[TX500LogbookManager sharedManager] searchContactsWithQuery:query
                                                                                              band:band
                                                                                              mode:mode];
    [self.displayedContacts setArray:list];
    [self.tableView reloadData];

    NSInteger total = [[TX500LogbookManager sharedManager] totalContactCount];
    NSInteger conf = [[TX500LogbookManager sharedManager] confirmedContactCount];
    self.statsLabel.stringValue = [NSString stringWithFormat:@"Total QSOs: %ld | Confirmed: %ld", (long)total, (long)conf];
}

- (void)updateCloudStatusPills {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    // QRZ
    NSString *qrzKey = [ud stringForKey:@"TX500_QRZ_APIKey"];
    BOOL qrz2FA = [TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceQRZ];
    if (qrz2FA) {
        self.qrzPillLabel.stringValue = @"QRZ: 2FA Active";
        self.qrzPillLabel.textColor = [NSColor systemGreenColor];
        self.qrzPill.fillColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.14];
        self.qrzPill.borderColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.5];
        self.qrzPill.toolTip = @"QRZ.com connected with active 2FA WebKit session.";
    } else if (qrzKey.length > 0) {
        self.qrzPillLabel.stringValue = @"QRZ: Ready";
        self.qrzPillLabel.textColor = [NSColor systemBlueColor];
        self.qrzPill.fillColor = [[NSColor systemBlueColor] colorWithAlphaComponent:0.12];
        self.qrzPill.borderColor = [[NSColor systemBlueColor] colorWithAlphaComponent:0.4];
        self.qrzPill.toolTip = @"QRZ.com connected via Logbook API Key.";
    } else {
        self.qrzPillLabel.stringValue = @"QRZ: Setup";
        self.qrzPillLabel.textColor = [NSColor secondaryLabelColor];
        self.qrzPill.fillColor = [[NSColor systemGrayColor] colorWithAlphaComponent:0.08];
        self.qrzPill.borderColor = [[NSColor systemGrayColor] colorWithAlphaComponent:0.25];
        self.qrzPill.toolTip = @"QRZ.com not configured. Click Cloud Settings... to configure.";
    }

    // LoTW
    NSString *lotwCert = [ud stringForKey:@"TX500_LoTW_CertificatePath"];
    NSString *lotwLoc = [ud stringForKey:@"TX500_LoTW_StationLocation"];
    if (lotwCert.length > 0) {
        self.lotwPillLabel.stringValue = @"LoTW: Cert Linked";
        self.lotwPillLabel.textColor = [NSColor systemGreenColor];
        self.lotwPill.fillColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.14];
        self.lotwPill.borderColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.5];
        self.lotwPill.toolTip = [NSString stringWithFormat:@"LoTW configured with .p12 certificate (%@).", [lotwCert lastPathComponent]];
    } else if (lotwLoc.length > 0) {
        self.lotwPillLabel.stringValue = @"LoTW: Ready";
        self.lotwPillLabel.textColor = [NSColor systemBlueColor];
        self.lotwPill.fillColor = [[NSColor systemBlueColor] colorWithAlphaComponent:0.12];
        self.lotwPill.borderColor = [[NSColor systemBlueColor] colorWithAlphaComponent:0.4];
        self.lotwPill.toolTip = [NSString stringWithFormat:@"LoTW station location '%@' configured via TQSL.", lotwLoc];
    } else {
        self.lotwPillLabel.stringValue = @"LoTW: Setup";
        self.lotwPillLabel.textColor = [NSColor secondaryLabelColor];
        self.lotwPill.fillColor = [[NSColor systemGrayColor] colorWithAlphaComponent:0.08];
        self.lotwPill.borderColor = [[NSColor systemGrayColor] colorWithAlphaComponent:0.25];
        self.lotwPill.toolTip = @"LoTW not configured. Choose .p12 certificate in Cloud Settings...";
    }

    // Club Log
    BOOL clubLog2FA = [TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceClubLog];
    NSString *clubLogKey = [ud stringForKey:@"TX500_ClubLog_APIKey"];
    NSString *clubLogPass = [ud stringForKey:@"TX500_ClubLog_Password"];
    if (clubLog2FA) {
        self.clublogPillLabel.stringValue = @"ClubLog: 2FA Active";
        self.clublogPillLabel.textColor = [NSColor systemGreenColor];
        self.clublogPill.fillColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.14];
        self.clublogPill.borderColor = [[NSColor systemGreenColor] colorWithAlphaComponent:0.5];
        self.clublogPill.toolTip = @"Club Log connected with active 2FA WebKit session.";
    } else if (clubLogKey.length > 0 || clubLogPass.length > 0) {
        self.clublogPillLabel.stringValue = @"ClubLog: Ready";
        self.clublogPillLabel.textColor = [NSColor systemOrangeColor];
        self.clublogPill.fillColor = [[NSColor systemOrangeColor] colorWithAlphaComponent:0.12];
        self.clublogPill.borderColor = [[NSColor systemOrangeColor] colorWithAlphaComponent:0.4];
        self.clublogPill.toolTip = @"Club Log configured for real-time QSO sync.";
    } else {
        self.clublogPillLabel.stringValue = @"ClubLog: Setup";
        self.clublogPillLabel.textColor = [NSColor secondaryLabelColor];
        self.clublogPill.fillColor = [[NSColor systemGrayColor] colorWithAlphaComponent:0.08];
        self.clublogPill.borderColor = [[NSColor systemGrayColor] colorWithAlphaComponent:0.25];
        self.clublogPill.toolTip = @"Club Log not configured. Click Cloud Settings... to configure.";
    }

    // eQSL
    NSString *eqslUser = [ud stringForKey:@"TX500_EQSL_Username"];
    if (eqslUser.length > 0) {
        self.eqslPillLabel.stringValue = @"eQSL: Ready";
        self.eqslPillLabel.textColor = [NSColor systemPurpleColor];
        self.eqslPill.fillColor = [[NSColor systemPurpleColor] colorWithAlphaComponent:0.12];
        self.eqslPill.borderColor = [[NSColor systemPurpleColor] colorWithAlphaComponent:0.4];
        self.eqslPill.toolTip = [NSString stringWithFormat:@"eQSL.cc configured for user '%@'.", eqslUser];
    } else {
        self.eqslPillLabel.stringValue = @"eQSL: Setup";
        self.eqslPillLabel.textColor = [NSColor secondaryLabelColor];
        self.eqslPill.fillColor = [[NSColor systemGrayColor] colorWithAlphaComponent:0.08];
        self.eqslPill.borderColor = [[NSColor systemGrayColor] colorWithAlphaComponent:0.25];
        self.eqslPill.toolTip = @"eQSL.cc not configured. Click Cloud Settings... to configure.";
    }
}

- (void)deleteSelectedContact {
    NSIndexSet *selected = self.tableView.selectedRowIndexes;
    if (selected.count == 0) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"Delete %lu QSO Record(s)?", (unsigned long)selected.count];
    alert.informativeText = @"This action cannot be undone.";
    [alert addButtonWithTitle:@"Delete"];
    [alert addButtonWithTitle:@"Cancel"];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [selected enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            (void)stop;
            if (idx < self.displayedContacts.count) {
                TX500LogRecord *rec = self.displayedContacts[idx];
                [[TX500LogbookManager sharedManager] deleteContactWithUUID:rec.uuid error:nil];
            }
        }];
    }
}

#pragma mark - Table View Data Source & Delegate

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    (void)tableView;
    return self.displayedContacts.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row >= (NSInteger)self.displayedContacts.count) return nil;
    TX500LogRecord *rec = self.displayedContacts[row];
    NSString *colId = tableColumn.identifier;

    NSTableCellView *cell = [tableView makeViewWithIdentifier:colId owner:self];
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 20)];
        cell.identifier = colId;
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        cell.textField = tf;
        [cell addSubview:tf];
        [NSLayoutConstraint activateConstraints:@[
            [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4.0],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4.0],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
        ]];
    }

    NSString *val = @"";
    NSColor *textColor = [NSColor labelColor];
    NSFont *font = [NSFont systemFontOfSize:12.0];

    if ([colId isEqualToString:@"DATE"]) {
        val = [rec formattedDate];
        font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    } else if ([colId isEqualToString:@"TIME"]) {
        val = [rec formattedTime];
        font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    } else if ([colId isEqualToString:@"CALL"]) {
        val = rec.callsign;
        font = [NSFont monospacedSystemFontOfSize:12.5 weight:NSFontWeightBold];
    } else if ([colId isEqualToString:@"BAND"]) {
        val = rec.band;
    } else if ([colId isEqualToString:@"FREQ"]) {
        val = [NSString stringWithFormat:@"%.3f", rec.frequencyMHz];
        font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    } else if ([colId isEqualToString:@"MODE"]) {
        val = rec.mode;
        font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    } else if ([colId isEqualToString:@"RST_SENT"]) {
        val = rec.rstSent;
    } else if ([colId isEqualToString:@"RST_RCVD"]) {
        val = rec.rstRcvd;
    } else if ([colId isEqualToString:@"NAME"]) {
        val = rec.name ?: @"";
    } else if ([colId isEqualToString:@"QTH"]) {
        val = rec.qth ?: @"";
    } else if ([colId isEqualToString:@"COUNTRY"]) {
        val = rec.country ?: @"";
    } else if ([colId isEqualToString:@"GRID"]) {
        val = rec.grid ?: @"";
        font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    } else if ([colId isEqualToString:@"QRZ"]) {
        val = [self formatCloudStatusText:rec.qrzStatus];
        textColor = [self colorForCloudStatus:rec.qrzStatus];
    } else if ([colId isEqualToString:@"LOTW"]) {
        val = [self formatCloudStatusText:rec.lotwStatus];
        textColor = [self colorForCloudStatus:rec.lotwStatus];
    } else if ([colId isEqualToString:@"CLUBLOG"]) {
        val = [self formatCloudStatusText:rec.clublogStatus];
        textColor = [self colorForCloudStatus:rec.clublogStatus];
    } else if ([colId isEqualToString:@"EQSL"]) {
        val = [self formatCloudStatusText:rec.eqslStatus];
        textColor = [self colorForCloudStatus:rec.eqslStatus];
    }

    cell.textField.stringValue = val;
    cell.textField.textColor = textColor;
    cell.textField.font = font;
    return cell;
}

#pragma mark - Cloud Actions & ADIF Export/Import

- (void)syncAllPending {
    self.statusConsoleLabel.stringValue = @"Synchronizing pending contacts with cloud ecosystem...";
    [[TX500CloudSyncEngine sharedEngine] uploadPendingContactsWithCompletion:^(NSInteger uploadedCount, NSInteger failedCount, NSString *summary) {
        (void)uploadedCount; (void)failedCount;
        self.statusConsoleLabel.stringValue = summary;
    }];
}

- (void)exportADIF {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.title = @"Export Logbook to ADIF";
    panel.nameFieldStringValue = [NSString stringWithFormat:@"TX500_Logbook_%@.adi",
                                  [[TX500LogRecord alloc] init].qsoDate];
    if (@available(macOS 11.0, *)) {
        panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"adi"] ?: UTTypePlainText];
    }

    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSError *err = nil;
            if ([[TX500LogbookManager sharedManager] exportADIFToFileURL:panel.URL error:&err]) {
                self.statusConsoleLabel.stringValue = [NSString stringWithFormat:@"ADIF Exported Successfully: %@", panel.URL.lastPathComponent];
            } else {
                NSAlert *a = [NSAlert alertWithError:err];
                [a runModal];
            }
        }
    }];
}

- (void)importADIF {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Import ADIF Log File";
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    if (@available(macOS 11.0, *)) {
        panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"adi"] ?: UTTypePlainText];
    }

    [panel beginWithCompletionHandler:^(NSModalResponse result) {
        if (result == NSModalResponseOK && panel.URL) {
            NSInteger duplicates = 0;
            NSError *err = nil;
            NSInteger imported = [[TX500LogbookManager sharedManager] importADIFFromFileURL:panel.URL
                                                                            duplicatesCount:&duplicates
                                                                                      error:&err];
            if (err) {
                NSAlert *a = [NSAlert alertWithError:err];
                [a runModal];
            } else {
                NSString *msg = [NSString stringWithFormat:@"Import Complete: %ld contact(s) imported, %ld duplicate(s) skipped.", (long)imported, (long)duplicates];
                self.statusConsoleLabel.stringValue = msg;
                NSAlert *a = [[NSAlert alloc] init];
                a.messageText = @"ADIF Import Successful";
                a.informativeText = msg;
                [a runModal];
            }
        }
    }];
}

#pragma mark - Cloud Settings Navigation & Pill Actions

- (void)openCloudSettingsSheet {
    if (self.openSettingsHandler) {
        self.openSettingsHandler(nil);
    } else {
        NSWindow *parentWin = self.view.window;
        [[TX500CloudSettingsController sharedController] showSettingsWindowOver:parentWin];
    }
}

- (void)qrzPillClicked {
    if (self.openSettingsHandler) {
        self.openSettingsHandler(@"QRZ");
    } else {
        [self openCloudSettingsSheet];
        [[TX500CloudSettingsController sharedController] selectTabWithService:@"QRZ"];
    }
}

- (void)lotwPillClicked {
    if (self.openSettingsHandler) {
        self.openSettingsHandler(@"LoTW");
    } else {
        [self openCloudSettingsSheet];
        [[TX500CloudSettingsController sharedController] selectTabWithService:@"LoTW"];
    }
}

- (void)clublogPillClicked {
    if (self.openSettingsHandler) {
        self.openSettingsHandler(@"ClubLog");
    } else {
        [self openCloudSettingsSheet];
        [[TX500CloudSettingsController sharedController] selectTabWithService:@"ClubLog"];
    }
}

- (void)eqslPillClicked {
    if (self.openSettingsHandler) {
        self.openSettingsHandler(@"eQSL");
    } else {
        [self openCloudSettingsSheet];
        [[TX500CloudSettingsController sharedController] selectTabWithService:@"eQSL"];
    }
}

- (void)cloudSettingsDidChange:(NSNotification *)note {
    (void)note;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateCloudStatusPills];
    });
}

#pragma mark - Table Cell Status Formatting

- (NSString *)formatCloudStatusText:(NSString *)rawStatus {
    if (!rawStatus || rawStatus.length == 0 || [rawStatus isEqualToString:@"PENDING"]) return @"—";
    if ([rawStatus isEqualToString:@"CONFIRMED"]) return @"★ Confirm";
    if ([rawStatus isEqualToString:@"UPLOADED"]) return @"✓ Upload";
    if ([rawStatus isEqualToString:@"QUEUED"]) return @"⌛ Queued";
    if ([rawStatus isEqualToString:@"FAILED"] || [rawStatus isEqualToString:@"ERROR"]) return @"! Failed";
    return rawStatus;
}

- (NSColor *)colorForCloudStatus:(NSString *)rawStatus {
    if ([rawStatus isEqualToString:@"CONFIRMED"]) return [NSColor systemBlueColor];
    if ([rawStatus isEqualToString:@"UPLOADED"]) return [NSColor systemGreenColor];
    if ([rawStatus isEqualToString:@"QUEUED"]) return [NSColor systemOrangeColor];
    if ([rawStatus isEqualToString:@"FAILED"] || [rawStatus isEqualToString:@"ERROR"]) return [NSColor systemRedColor];
    return [NSColor secondaryLabelColor];
}

@end
