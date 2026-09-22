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
@property (nonatomic, strong) NSButton *dupeBadgeButton;
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
@property (nonatomic, strong) NSTextField *bearingDistanceLabel;
@property (nonatomic, strong) NSTextField *notesField;
@property (nonatomic, strong) NSButton *logContactButton;
@property (nonatomic, strong) NSButton *clearButton;

// Field Ops (POTA / SOTA / IOTA)
@property (nonatomic, strong) NSTextField *theirPotaField;
@property (nonatomic, strong) NSTextField *myPotaField;
@property (nonatomic, strong) NSTextField *theirSotaField;
@property (nonatomic, strong) NSTextField *iotaField;

// Award Tracking HUD
@property (nonatomic, strong) NSBox *awardTrackerCard;
@property (nonatomic, strong) NSTextField *awardDxccLabel;
@property (nonatomic, strong) NSTextField *awardWasLabel;
@property (nonatomic, strong) NSTextField *awardWazLabel;
@property (nonatomic, strong) NSTextField *awardPotaLabel;
@property (nonatomic, strong) NSTextField *awardSotaLabel;
@property (nonatomic, strong) NSTextField *awardIotaLabel;

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
@property (nonatomic, strong) NSButton *consoleCollapseButton;
@property (nonatomic, strong) NSLayoutConstraint *consoleHeightConstraint;
@property (nonatomic, assign) BOOL isConsoleCollapsed;

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

    NSButton *btnLoTW = [NSButton buttonWithTitle:@"LoTW (TQSL)..." target:self action:@selector(uploadToLoTWViaTQSL)];
    btnLoTW.bezelStyle = NSBezelStyleRounded;
    btnLoTW.translatesAutoresizingMaskIntoConstraints = NO;

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
    [headerActions addArrangedSubview:btnLoTW];
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
        [self.voiceLoggerCard.heightAnchor constraintEqualToConstant:128.0],

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
    [self refreshAwardStatistics];
}

#pragma mark - Voice Logger Layout

- (void)setupVoiceLoggerLayout {
    // --- Row 1: Primary QSO Logging Controls ---
    NSTextField *lblCall = [NSTextField labelWithString:@"Call:"];
    lblCall.translatesAutoresizingMaskIntoConstraints = NO;
    lblCall.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightBold];
    [self.voiceLoggerCard addSubview:lblCall];

    self.callsignField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.callsignField.translatesAutoresizingMaskIntoConstraints = NO;
    self.callsignField.placeholderString = @"W1AW";
    self.callsignField.font = [NSFont monospacedSystemFontOfSize:13.5 weight:NSFontWeightBold];
    self.callsignField.delegate = self;
    [self.voiceLoggerCard addSubview:self.callsignField];

    // Dupe Check Badge Pill
    self.dupeBadgeButton = [NSButton buttonWithTitle:@"[NEW QSO]" target:self action:@selector(dupeBadgeClicked:)];
    self.dupeBadgeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.dupeBadgeButton.bezelStyle = NSBezelStyleInline;
    self.dupeBadgeButton.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightBold];
    self.dupeBadgeButton.toolTip = @"Callsign status indicator. Click to view prior QSO history.";
    [self.voiceLoggerCard addSubview:self.dupeBadgeButton];

    self.lookupSpinner = [[NSProgressIndicator alloc] init];
    self.lookupSpinner.translatesAutoresizingMaskIntoConstraints = NO;
    self.lookupSpinner.style = NSProgressIndicatorStyleSpinning;
    self.lookupSpinner.controlSize = NSControlSizeSmall;
    self.lookupSpinner.displayedWhenStopped = NO;
    [self.voiceLoggerCard addSubview:self.lookupSpinner];

    NSTextField *lblFreq = [NSTextField labelWithString:@"Freq:"];
    lblFreq.translatesAutoresizingMaskIntoConstraints = NO;
    lblFreq.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblFreq];

    self.freqField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.freqField.translatesAutoresizingMaskIntoConstraints = NO;
    self.freqField.stringValue = [NSString stringWithFormat:@"%.3f", (double)self.currentFrequencyHz / 1e6];
    self.freqField.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightMedium];
    [self.voiceLoggerCard addSubview:self.freqField];

    self.bandPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.bandPopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.bandPopup addItemsWithTitles:@[@"160m", @"80m", @"60m", @"40m", @"30m", @"20m", @"17m", @"15m", @"12m", @"10m", @"6m", @"2m", @"70cm"]];
    [self.bandPopup selectItemWithTitle:[TX500LogRecord bandForFrequencyHz:self.currentFrequencyHz]];
    self.bandPopup.target = self;
    self.bandPopup.action = @selector(voiceLoggerBandOrModeChanged:);
    [self.voiceLoggerCard addSubview:self.bandPopup];

    self.modePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.modePopup.translatesAutoresizingMaskIntoConstraints = NO;
    [self.modePopup addItemsWithTitles:@[@"USB", @"LSB", @"AM", @"FM", @"CW", @"FT8", @"FT4"]];
    [self.modePopup selectItemWithTitle:self.currentMode];
    self.modePopup.target = self;
    self.modePopup.action = @selector(voiceLoggerBandOrModeChanged:);
    [self.voiceLoggerCard addSubview:self.modePopup];

    NSTextField *lblRst = [NSTextField labelWithString:@"RST:"];
    lblRst.translatesAutoresizingMaskIntoConstraints = NO;
    lblRst.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblRst];

    self.rstSentField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.rstSentField.translatesAutoresizingMaskIntoConstraints = NO;
    self.rstSentField.stringValue = @"59";
    self.rstSentField.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.rstSentField];

    self.rstRcvdField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.rstRcvdField.translatesAutoresizingMaskIntoConstraints = NO;
    self.rstRcvdField.stringValue = @"59";
    self.rstRcvdField.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.rstRcvdField];

    self.logContactButton = [NSButton buttonWithTitle:@"Log QSO ↵" target:self action:@selector(logContactAction)];
    self.logContactButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.logContactButton.bezelStyle = NSBezelStyleRounded;
    self.logContactButton.keyEquivalent = @"\r";
    self.logContactButton.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightBold];
    [self.voiceLoggerCard addSubview:self.logContactButton];

    self.clearButton = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearVoiceLoggerFields)];
    self.clearButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.clearButton.bezelStyle = NSBezelStyleRounded;
    [self.voiceLoggerCard addSubview:self.clearButton];

    // --- Row 2: Operator Details & Great Circle Telemetry ---
    NSTextField *lblName = [NSTextField labelWithString:@"Name:"];
    lblName.translatesAutoresizingMaskIntoConstraints = NO;
    lblName.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblName];

    self.nameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.nameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.nameField.placeholderString = @"Operator Name";
    self.nameField.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.nameField];

    NSTextField *lblQth = [NSTextField labelWithString:@"City:"];
    lblQth.translatesAutoresizingMaskIntoConstraints = NO;
    lblQth.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblQth];

    self.qthField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.qthField.translatesAutoresizingMaskIntoConstraints = NO;
    self.qthField.placeholderString = @"City / QTH";
    self.qthField.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.qthField];

    NSTextField *lblState = [NSTextField labelWithString:@"State:"];
    lblState.translatesAutoresizingMaskIntoConstraints = NO;
    lblState.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblState];

    self.stateField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.stateField.translatesAutoresizingMaskIntoConstraints = NO;
    self.stateField.placeholderString = @"State";
    self.stateField.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.stateField];

    NSTextField *lblCountry = [NSTextField labelWithString:@"Country:"];
    lblCountry.translatesAutoresizingMaskIntoConstraints = NO;
    lblCountry.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblCountry];

    self.countryField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.countryField.translatesAutoresizingMaskIntoConstraints = NO;
    self.countryField.placeholderString = @"Country";
    self.countryField.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.countryField];

    NSTextField *lblGrid = [NSTextField labelWithString:@"Grid:"];
    lblGrid.translatesAutoresizingMaskIntoConstraints = NO;
    lblGrid.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblGrid];

    self.gridField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.gridField.translatesAutoresizingMaskIntoConstraints = NO;
    self.gridField.placeholderString = @"FN31pr";
    self.gridField.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    self.gridField.delegate = self;
    [self.voiceLoggerCard addSubview:self.gridField];

    self.bearingDistanceLabel = [NSTextField labelWithString:@"🧭 Bearing: --"];
    self.bearingDistanceLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.bearingDistanceLabel.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightMedium];
    self.bearingDistanceLabel.textColor = [NSColor controlAccentColor];
    [self.voiceLoggerCard addSubview:self.bearingDistanceLabel];

    // --- Row 3: Field Ops (POTA, SOTA, IOTA) & Notes ---
    NSTextField *lblNotes = [NSTextField labelWithString:@"Notes:"];
    lblNotes.translatesAutoresizingMaskIntoConstraints = NO;
    lblNotes.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblNotes];

    self.notesField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.notesField.translatesAutoresizingMaskIntoConstraints = NO;
    self.notesField.placeholderString = @"QSO remarks, rig, antenna...";
    self.notesField.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.notesField];

    NSTextField *lblPota = [NSTextField labelWithString:@"POTA:"];
    lblPota.translatesAutoresizingMaskIntoConstraints = NO;
    lblPota.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblPota];

    self.theirPotaField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.theirPotaField.translatesAutoresizingMaskIntoConstraints = NO;
    self.theirPotaField.placeholderString = @"Their POTA";
    self.theirPotaField.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.theirPotaField];

    self.myPotaField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.myPotaField.translatesAutoresizingMaskIntoConstraints = NO;
    self.myPotaField.placeholderString = @"My POTA";
    self.myPotaField.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.myPotaField];

    NSTextField *lblSota = [NSTextField labelWithString:@"SOTA:"];
    lblSota.translatesAutoresizingMaskIntoConstraints = NO;
    lblSota.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblSota];

    self.theirSotaField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.theirSotaField.translatesAutoresizingMaskIntoConstraints = NO;
    self.theirSotaField.placeholderString = @"SOTA Ref";
    self.theirSotaField.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.theirSotaField];

    NSTextField *lblIota = [NSTextField labelWithString:@"IOTA:"];
    lblIota.translatesAutoresizingMaskIntoConstraints = NO;
    lblIota.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:lblIota];

    self.iotaField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.iotaField.translatesAutoresizingMaskIntoConstraints = NO;
    self.iotaField.placeholderString = @"IOTA Ref";
    self.iotaField.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    [self.voiceLoggerCard addSubview:self.iotaField];

    // Station Intelligence HUD Card (compact, on right side of rows 2 & 3)
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
    self.hudNameLabel.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightBold];
    [hudBox addSubview:self.hudNameLabel];

    self.hudLocationLabel = [NSTextField labelWithString:@"QTH / Location / Country"];
    self.hudLocationLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudLocationLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    self.hudLocationLabel.textColor = [NSColor secondaryLabelColor];
    [hudBox addSubview:self.hudLocationLabel];

    self.hudGridLabel = [NSTextField labelWithString:@"Grid: --"];
    self.hudGridLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudGridLabel.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    self.hudGridLabel.textColor = [NSColor secondaryLabelColor];
    [hudBox addSubview:self.hudGridLabel];

    self.hudBadgesLabel = [NSTextField labelWithString:@"Callbook Ready"];
    self.hudBadgesLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.hudBadgesLabel.font = [NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium];
    self.hudBadgesLabel.textColor = [NSColor controlAccentColor];
    [hudBox addSubview:self.hudBadgesLabel];

    // Auto Layout Constraints for Voice Logger Form
    [NSLayoutConstraint activateConstraints:@[
        // Row 1: Primary Controls
        [lblCall.leadingAnchor constraintEqualToAnchor:self.voiceLoggerCard.leadingAnchor constant:12.0],
        [lblCall.topAnchor constraintEqualToAnchor:self.voiceLoggerCard.topAnchor constant:8.0],

        [self.callsignField.leadingAnchor constraintEqualToAnchor:lblCall.leadingAnchor],
        [self.callsignField.topAnchor constraintEqualToAnchor:lblCall.bottomAnchor constant:2.0],
        [self.callsignField.widthAnchor constraintEqualToConstant:92.0],
        [self.callsignField.heightAnchor constraintEqualToConstant:24.0],

        [self.dupeBadgeButton.leadingAnchor constraintEqualToAnchor:self.callsignField.trailingAnchor constant:4.0],
        [self.dupeBadgeButton.centerYAnchor constraintEqualToAnchor:self.callsignField.centerYAnchor],
        [self.dupeBadgeButton.widthAnchor constraintEqualToConstant:78.0],
        [self.dupeBadgeButton.heightAnchor constraintEqualToConstant:22.0],

        [self.lookupSpinner.leadingAnchor constraintEqualToAnchor:self.dupeBadgeButton.trailingAnchor constant:3.0],
        [self.lookupSpinner.centerYAnchor constraintEqualToAnchor:self.callsignField.centerYAnchor],

        [lblFreq.leadingAnchor constraintEqualToAnchor:self.lookupSpinner.trailingAnchor constant:6.0],
        [lblFreq.topAnchor constraintEqualToAnchor:lblCall.topAnchor],

        [self.freqField.leadingAnchor constraintEqualToAnchor:lblFreq.leadingAnchor],
        [self.freqField.topAnchor constraintEqualToAnchor:self.callsignField.topAnchor],
        [self.freqField.widthAnchor constraintEqualToConstant:58.0],
        [self.freqField.heightAnchor constraintEqualToConstant:24.0],

        [self.bandPopup.leadingAnchor constraintEqualToAnchor:self.freqField.trailingAnchor constant:4.0],
        [self.bandPopup.centerYAnchor constraintEqualToAnchor:self.freqField.centerYAnchor],
        [self.bandPopup.widthAnchor constraintEqualToConstant:58.0],

        [self.modePopup.leadingAnchor constraintEqualToAnchor:self.bandPopup.trailingAnchor constant:4.0],
        [self.modePopup.centerYAnchor constraintEqualToAnchor:self.bandPopup.centerYAnchor],
        [self.modePopup.widthAnchor constraintEqualToConstant:56.0],

        [lblRst.leadingAnchor constraintEqualToAnchor:self.modePopup.trailingAnchor constant:6.0],
        [lblRst.topAnchor constraintEqualToAnchor:lblCall.topAnchor],

        [self.rstSentField.leadingAnchor constraintEqualToAnchor:lblRst.leadingAnchor],
        [self.rstSentField.topAnchor constraintEqualToAnchor:self.callsignField.topAnchor],
        [self.rstSentField.widthAnchor constraintEqualToConstant:28.0],
        [self.rstSentField.heightAnchor constraintEqualToConstant:24.0],

        [self.rstRcvdField.leadingAnchor constraintEqualToAnchor:self.rstSentField.trailingAnchor constant:3.0],
        [self.rstRcvdField.centerYAnchor constraintEqualToAnchor:self.rstSentField.centerYAnchor],
        [self.rstRcvdField.widthAnchor constraintEqualToConstant:28.0],
        [self.rstRcvdField.heightAnchor constraintEqualToConstant:24.0],

        [self.logContactButton.trailingAnchor constraintEqualToAnchor:self.voiceLoggerCard.trailingAnchor constant:-12.0],
        [self.logContactButton.centerYAnchor constraintEqualToAnchor:self.callsignField.centerYAnchor],
        [self.logContactButton.widthAnchor constraintEqualToConstant:84.0],
        [self.logContactButton.heightAnchor constraintEqualToConstant:25.0],

        [self.clearButton.trailingAnchor constraintEqualToAnchor:self.logContactButton.leadingAnchor constant:-6.0],
        [self.clearButton.centerYAnchor constraintEqualToAnchor:self.callsignField.centerYAnchor],
        [self.clearButton.widthAnchor constraintEqualToConstant:52.0],
        [self.clearButton.heightAnchor constraintEqualToConstant:25.0],
        [self.clearButton.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.rstRcvdField.trailingAnchor constant:6.0],

        // Row 2: Operator Details
        [lblName.leadingAnchor constraintEqualToAnchor:lblCall.leadingAnchor],
        [lblName.topAnchor constraintEqualToAnchor:self.callsignField.bottomAnchor constant:6.0],

        [self.nameField.leadingAnchor constraintEqualToAnchor:lblName.trailingAnchor constant:4.0],
        [self.nameField.centerYAnchor constraintEqualToAnchor:lblName.centerYAnchor],
        [self.nameField.widthAnchor constraintEqualToConstant:95.0],
        [self.nameField.heightAnchor constraintEqualToConstant:21.0],

        [lblQth.leadingAnchor constraintEqualToAnchor:self.nameField.trailingAnchor constant:6.0],
        [lblQth.centerYAnchor constraintEqualToAnchor:lblName.centerYAnchor],

        [self.qthField.leadingAnchor constraintEqualToAnchor:lblQth.trailingAnchor constant:4.0],
        [self.qthField.centerYAnchor constraintEqualToAnchor:lblName.centerYAnchor],
        [self.qthField.widthAnchor constraintEqualToConstant:80.0],
        [self.qthField.heightAnchor constraintEqualToConstant:21.0],

        [lblState.leadingAnchor constraintEqualToAnchor:self.qthField.trailingAnchor constant:6.0],
        [lblState.centerYAnchor constraintEqualToAnchor:lblName.centerYAnchor],

        [self.stateField.leadingAnchor constraintEqualToAnchor:lblState.trailingAnchor constant:4.0],
        [self.stateField.centerYAnchor constraintEqualToAnchor:lblName.centerYAnchor],
        [self.stateField.widthAnchor constraintEqualToConstant:36.0],
        [self.stateField.heightAnchor constraintEqualToConstant:21.0],

        [lblCountry.leadingAnchor constraintEqualToAnchor:self.stateField.trailingAnchor constant:6.0],
        [lblCountry.centerYAnchor constraintEqualToAnchor:lblName.centerYAnchor],

        [self.countryField.leadingAnchor constraintEqualToAnchor:lblCountry.trailingAnchor constant:4.0],
        [self.countryField.centerYAnchor constraintEqualToAnchor:lblName.centerYAnchor],
        [self.countryField.widthAnchor constraintEqualToConstant:82.0],
        [self.countryField.heightAnchor constraintEqualToConstant:21.0],

        [lblGrid.leadingAnchor constraintEqualToAnchor:self.countryField.trailingAnchor constant:6.0],
        [lblGrid.centerYAnchor constraintEqualToAnchor:lblName.centerYAnchor],

        [self.gridField.leadingAnchor constraintEqualToAnchor:lblGrid.trailingAnchor constant:4.0],
        [self.gridField.centerYAnchor constraintEqualToAnchor:lblName.centerYAnchor],
        [self.gridField.widthAnchor constraintEqualToConstant:54.0],
        [self.gridField.heightAnchor constraintEqualToConstant:21.0],

        [self.bearingDistanceLabel.leadingAnchor constraintEqualToAnchor:self.gridField.trailingAnchor constant:6.0],
        [self.bearingDistanceLabel.centerYAnchor constraintEqualToAnchor:lblName.centerYAnchor],

        // Row 3: Field Ops & Notes
        [lblNotes.leadingAnchor constraintEqualToAnchor:lblCall.leadingAnchor],
        [lblNotes.topAnchor constraintEqualToAnchor:lblName.bottomAnchor constant:7.0],

        [self.notesField.leadingAnchor constraintEqualToAnchor:lblNotes.trailingAnchor constant:4.0],
        [self.notesField.centerYAnchor constraintEqualToAnchor:lblNotes.centerYAnchor],
        [self.notesField.widthAnchor constraintEqualToConstant:115.0],
        [self.notesField.heightAnchor constraintEqualToConstant:21.0],

        [lblPota.leadingAnchor constraintEqualToAnchor:self.notesField.trailingAnchor constant:6.0],
        [lblPota.centerYAnchor constraintEqualToAnchor:lblNotes.centerYAnchor],

        [self.theirPotaField.leadingAnchor constraintEqualToAnchor:lblPota.trailingAnchor constant:4.0],
        [self.theirPotaField.centerYAnchor constraintEqualToAnchor:lblNotes.centerYAnchor],
        [self.theirPotaField.widthAnchor constraintEqualToConstant:68.0],
        [self.theirPotaField.heightAnchor constraintEqualToConstant:21.0],

        [self.myPotaField.leadingAnchor constraintEqualToAnchor:self.theirPotaField.trailingAnchor constant:4.0],
        [self.myPotaField.centerYAnchor constraintEqualToAnchor:lblNotes.centerYAnchor],
        [self.myPotaField.widthAnchor constraintEqualToConstant:68.0],
        [self.myPotaField.heightAnchor constraintEqualToConstant:21.0],

        [lblSota.leadingAnchor constraintEqualToAnchor:self.myPotaField.trailingAnchor constant:6.0],
        [lblSota.centerYAnchor constraintEqualToAnchor:lblNotes.centerYAnchor],

        [self.theirSotaField.leadingAnchor constraintEqualToAnchor:lblSota.trailingAnchor constant:4.0],
        [self.theirSotaField.centerYAnchor constraintEqualToAnchor:lblNotes.centerYAnchor],
        [self.theirSotaField.widthAnchor constraintEqualToConstant:68.0],
        [self.theirSotaField.heightAnchor constraintEqualToConstant:21.0],

        [lblIota.leadingAnchor constraintEqualToAnchor:self.theirSotaField.trailingAnchor constant:6.0],
        [lblIota.centerYAnchor constraintEqualToAnchor:lblNotes.centerYAnchor],

        [self.iotaField.leadingAnchor constraintEqualToAnchor:lblIota.trailingAnchor constant:4.0],
        [self.iotaField.centerYAnchor constraintEqualToAnchor:lblNotes.centerYAnchor],
        [self.iotaField.widthAnchor constraintEqualToConstant:60.0],
        [self.iotaField.heightAnchor constraintEqualToConstant:21.0],

        // Station HUD Box: Anchored on the right of Rows 2 & 3
        [hudBox.trailingAnchor constraintEqualToAnchor:self.voiceLoggerCard.trailingAnchor constant:-12.0],
        [hudBox.topAnchor constraintEqualToAnchor:self.nameField.topAnchor constant:-2.0],
        [hudBox.bottomAnchor constraintEqualToAnchor:self.notesField.bottomAnchor constant:2.0],
        [hudBox.widthAnchor constraintEqualToConstant:235.0],
        [hudBox.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.bearingDistanceLabel.trailingAnchor constant:6.0],
        [hudBox.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.iotaField.trailingAnchor constant:6.0],

        [self.avatarImageView.leadingAnchor constraintEqualToAnchor:hudBox.leadingAnchor constant:6.0],
        [self.avatarImageView.centerYAnchor constraintEqualToAnchor:hudBox.centerYAnchor],
        [self.avatarImageView.widthAnchor constraintEqualToConstant:34.0],
        [self.avatarImageView.heightAnchor constraintEqualToConstant:34.0],

        [self.hudNameLabel.leadingAnchor constraintEqualToAnchor:self.avatarImageView.trailingAnchor constant:6.0],
        [self.hudNameLabel.topAnchor constraintEqualToAnchor:hudBox.topAnchor constant:4.0],
        [self.hudNameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.hudGridLabel.leadingAnchor constant:-4.0],

        [self.hudLocationLabel.leadingAnchor constraintEqualToAnchor:self.hudNameLabel.leadingAnchor],
        [self.hudLocationLabel.topAnchor constraintEqualToAnchor:self.hudNameLabel.bottomAnchor constant:1.0],
        [self.hudLocationLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.hudBadgesLabel.leadingAnchor constant:-4.0],

        [self.hudGridLabel.trailingAnchor constraintEqualToAnchor:hudBox.trailingAnchor constant:-8.0],
        [self.hudGridLabel.topAnchor constraintEqualToAnchor:hudBox.topAnchor constant:4.0],

        [self.hudBadgesLabel.trailingAnchor constraintEqualToAnchor:self.hudGridLabel.trailingAnchor],
        [self.hudBadgesLabel.topAnchor constraintEqualToAnchor:self.hudGridLabel.bottomAnchor constant:1.0]
    ]];
}

#pragma mark - Logbook Table Layout

- (NSBox *)createAwardTrackerCard {
    NSBox *box = [self createCardBox];
    box.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.04];
    box.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *stack = [[NSStackView alloc] init];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    stack.spacing = 10.0;
    stack.alignment = NSLayoutAttributeCenterY;
    stack.distribution = NSStackViewDistributionFillEqually;

    self.awardDxccLabel = [self createAwardLabel:@"🌍 DXCC: 0 / 0 Conf"];
    self.awardWasLabel = [self createAwardLabel:@"🇺🇸 WAS: 0 / 0 Conf"];
    self.awardWazLabel = [self createAwardLabel:@"🌐 WAZ: 0 / 0 Conf"];
    self.awardPotaLabel = [self createAwardLabel:@"🌲 POTA: 0"];
    self.awardSotaLabel = [self createAwardLabel:@"🏔️ SOTA: 0"];
    self.awardIotaLabel = [self createAwardLabel:@"🏝️ IOTA: 0"];

    [stack addArrangedSubview:self.awardDxccLabel];
    [stack addArrangedSubview:self.awardWasLabel];
    [stack addArrangedSubview:self.awardWazLabel];
    [stack addArrangedSubview:self.awardPotaLabel];
    [stack addArrangedSubview:self.awardSotaLabel];
    [stack addArrangedSubview:self.awardIotaLabel];

    [box addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:8.0],
        [stack.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-8.0],
        [stack.topAnchor constraintEqualToAnchor:box.topAnchor constant:2.0],
        [stack.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-2.0]
    ]];
    return box;
}

- (NSTextField *)createAwardLabel:(NSString *)text {
    NSTextField *lbl = [NSTextField labelWithString:text];
    lbl.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
    lbl.alignment = NSTextAlignmentCenter;
    lbl.textColor = [NSColor labelColor];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    return lbl;
}

- (void)setupLogbookTableLayoutInBox:(NSBox *)box {
    // Award Tracker HUD Ribbon (Top of Table Card)
    self.awardTrackerCard = [self createAwardTrackerCard];
    [box addSubview:self.awardTrackerCard];

    // Filter Bar
    self.searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.searchField.translatesAutoresizingMaskIntoConstraints = NO;
    self.searchField.placeholderString = @"Search calls, names, countries, grids...";
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
        @{@"id": @"DATE", @"title": @"Date", @"width": @80, @"minWidth": @75},
        @{@"id": @"TIME", @"title": @"Time (UTC)", @"width": @72, @"minWidth": @68},
        @{@"id": @"CALL", @"title": @"Callsign", @"width": @90, @"minWidth": @80},
        @{@"id": @"BAND", @"title": @"Band", @"width": @50, @"minWidth": @45},
        @{@"id": @"FREQ", @"title": @"Freq (MHz)", @"width": @76, @"minWidth": @70},
        @{@"id": @"MODE", @"title": @"Mode", @"width": @55, @"minWidth": @50},
        @{@"id": @"RST_SENT", @"title": @"RST (S)", @"width": @50, @"minWidth": @45},
        @{@"id": @"RST_RCVD", @"title": @"RST (R)", @"width": @50, @"minWidth": @45},
        @{@"id": @"NAME", @"title": @"Name", @"width": @105, @"minWidth": @90},
        @{@"id": @"QTH", @"title": @"QTH", @"width": @95, @"minWidth": @80},
        @{@"id": @"COUNTRY", @"title": @"Country", @"width": @100, @"minWidth": @85},
        @{@"id": @"GRID", @"title": @"Grid", @"width": @60, @"minWidth": @55},
        @{@"id": @"POTA", @"title": @"POTA", @"width": @68, @"minWidth": @55},
        @{@"id": @"SOTA", @"title": @"SOTA", @"width": @68, @"minWidth": @55},
        @{@"id": @"IOTA", @"title": @"IOTA", @"width": @60, @"minWidth": @50},
        @{@"id": @"QRZ", @"title": @"QRZ", @"width": @75, @"minWidth": @65},
        @{@"id": @"LOTW", @"title": @"LoTW", @"width": @75, @"minWidth": @65},
        @{@"id": @"CLUBLOG", @"title": @"ClubLog", @"width": @75, @"minWidth": @65},
        @{@"id": @"EQSL", @"title": @"eQSL", @"width": @72, @"minWidth": @65}
    ];

    for (NSDictionary *d in colDefs) {
        NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:d[@"id"]];
        col.title = d[@"title"];
        col.width = [d[@"width"] doubleValue];
        col.minWidth = [d[@"minWidth"] doubleValue];
        col.resizingMask = NSTableColumnAutoresizingMask | NSTableColumnUserResizingMask;

        NSString *cid = d[@"id"];
        if ([cid isEqualToString:@"DATE"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"qsoDate" ascending:NO];
        } else if ([cid isEqualToString:@"TIME"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"timeOn" ascending:NO];
        } else if ([cid isEqualToString:@"CALL"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"callsign" ascending:YES selector:@selector(caseInsensitiveCompare:)];
        } else if ([cid isEqualToString:@"BAND"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"band" ascending:YES];
        } else if ([cid isEqualToString:@"FREQ"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"frequencyHz" ascending:YES];
        } else if ([cid isEqualToString:@"MODE"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"mode" ascending:YES];
        } else if ([cid isEqualToString:@"RST_SENT"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"rstSent" ascending:YES];
        } else if ([cid isEqualToString:@"RST_RCVD"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"rstRcvd" ascending:YES];
        } else if ([cid isEqualToString:@"NAME"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"name" ascending:YES selector:@selector(caseInsensitiveCompare:)];
        } else if ([cid isEqualToString:@"QTH"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"qth" ascending:YES selector:@selector(caseInsensitiveCompare:)];
        } else if ([cid isEqualToString:@"COUNTRY"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"country" ascending:YES selector:@selector(caseInsensitiveCompare:)];
        } else if ([cid isEqualToString:@"GRID"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"grid" ascending:YES selector:@selector(caseInsensitiveCompare:)];
        } else if ([cid isEqualToString:@"POTA"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"theirPotaRef" ascending:YES selector:@selector(caseInsensitiveCompare:)];
        } else if ([cid isEqualToString:@"SOTA"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"theirSotaRef" ascending:YES selector:@selector(caseInsensitiveCompare:)];
        } else if ([cid isEqualToString:@"IOTA"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"iotaRef" ascending:YES selector:@selector(caseInsensitiveCompare:)];
        } else if ([cid isEqualToString:@"QRZ"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"qrzStatus" ascending:YES];
        } else if ([cid isEqualToString:@"LOTW"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"lotwStatus" ascending:YES];
        } else if ([cid isEqualToString:@"CLUBLOG"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"clublogStatus" ascending:YES];
        } else if ([cid isEqualToString:@"EQSL"]) {
            col.sortDescriptorPrototype = [NSSortDescriptor sortDescriptorWithKey:@"eqslStatus" ascending:YES];
        }

        [self.tableView addTableColumn:col];
    }

    [self setupTableHeaderContextMenu];

    scrollView.documentView = self.tableView;
    [box addSubview:scrollView];

    // Bottom Status Console & Collapse Button
    self.consoleCollapseButton = [NSButton buttonWithTitle:@"▼ Console" target:self action:@selector(toggleConsoleCollapse)];
    self.consoleCollapseButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.consoleCollapseButton.bezelStyle = NSBezelStyleInline;
    self.consoleCollapseButton.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightMedium];
    [box addSubview:self.consoleCollapseButton];

    self.statusConsoleLabel = [NSTextField labelWithString:@"Logbook database active. Ready to log contacts."];
    self.statusConsoleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusConsoleLabel.font = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    self.statusConsoleLabel.textColor = [NSColor secondaryLabelColor];
    [box addSubview:self.statusConsoleLabel];

    self.consoleHeightConstraint = [self.statusConsoleLabel.heightAnchor constraintEqualToConstant:18.0];
    self.consoleHeightConstraint.active = YES;

    NSLayoutConstraint *tableHeightConstraint = [scrollView.heightAnchor constraintEqualToConstant:320.0];
    tableHeightConstraint.priority = NSLayoutPriorityDefaultHigh;

    NSLayoutConstraint *tableMinHeightConstraint = [scrollView.heightAnchor constraintGreaterThanOrEqualToConstant:240.0];
    tableMinHeightConstraint.priority = NSLayoutPriorityDefaultHigh;

    [NSLayoutConstraint activateConstraints:@[
        [self.awardTrackerCard.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:8.0],
        [self.awardTrackerCard.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-8.0],
        [self.awardTrackerCard.topAnchor constraintEqualToAnchor:box.topAnchor constant:6.0],
        [self.awardTrackerCard.heightAnchor constraintEqualToConstant:24.0],

        [self.searchField.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:8.0],
        [self.searchField.topAnchor constraintEqualToAnchor:self.awardTrackerCard.bottomAnchor constant:6.0],
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

        [scrollView.topAnchor constraintEqualToAnchor:self.searchField.bottomAnchor constant:6.0],
        [scrollView.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:8.0],
        [scrollView.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-8.0],
        [scrollView.bottomAnchor constraintEqualToAnchor:self.consoleCollapseButton.topAnchor constant:-6.0],
        tableHeightConstraint,
        tableMinHeightConstraint,

        [self.consoleCollapseButton.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:8.0],
        [self.consoleCollapseButton.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-6.0],
        [self.consoleCollapseButton.widthAnchor constraintEqualToConstant:74.0],
        [self.consoleCollapseButton.heightAnchor constraintEqualToConstant:20.0],

        [self.statusConsoleLabel.leadingAnchor constraintEqualToAnchor:self.consoleCollapseButton.trailingAnchor constant:8.0],
        [self.statusConsoleLabel.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-10.0],
        [self.statusConsoleLabel.centerYAnchor constraintEqualToAnchor:self.consoleCollapseButton.centerYAnchor]
    ]];
}

#pragma mark - Table Header Context Menu & Column Sorting

- (void)setupTableHeaderContextMenu {
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Columns"];
    for (NSTableColumn *col in self.tableView.tableColumns) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:col.title action:@selector(toggleColumnVisibility:) keyEquivalent:@""];
        item.target = self;
        item.representedObject = col;
        item.state = col.isHidden ? NSControlStateValueOff : NSControlStateValueOn;
        [menu addItem:item];
    }
    self.tableView.headerView.menu = menu;
}

- (void)toggleColumnVisibility:(NSMenuItem *)sender {
    NSTableColumn *col = (NSTableColumn *)sender.representedObject;
    if (!col) return;
    col.hidden = !col.isHidden;
    sender.state = col.isHidden ? NSControlStateValueOff : NSControlStateValueOn;
}

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if (menuItem.action == @selector(toggleColumnVisibility:)) {
        NSTableColumn *col = (NSTableColumn *)menuItem.representedObject;
        if (col) {
            menuItem.state = col.isHidden ? NSControlStateValueOff : NSControlStateValueOn;
        }
        return YES;
    }
    return YES;
}

- (void)tableView:(NSTableView *)tableView sortDescriptorsDidChange:(NSArray<NSSortDescriptor *> *)oldDescriptors {
    (void)oldDescriptors;
    NSArray<NSSortDescriptor *> *sortDesc = tableView.sortDescriptors;
    if (sortDesc.count > 0) {
        [self.displayedContacts sortUsingDescriptors:sortDesc];
        [self.tableView reloadData];
    }
}

#pragma mark - Callsign Lookup, Dupe Check & Great Circle

- (void)controlTextDidChange:(NSNotification *)obj {
    if (obj.object == self.callsignField) {
        NSString *call = [self.callsignField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [self updateDupeStatusForCallsign:call];
        [self.lookupDebounceTimer invalidate];
        self.lookupDebounceTimer = [NSTimer scheduledTimerWithTimeInterval:0.45
                                                                    target:self
                                                                  selector:@selector(triggerCallsignLookup)
                                                                  userInfo:nil
                                                                   repeats:NO];
    } else if (obj.object == self.gridField) {
        [self updateBearingAndDistanceDisplay];
    } else if (obj.object == self.searchField) {
        [self reloadTableData];
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)commandSelector {
    (void)textView;
    if (control == self.callsignField) {
        if (commandSelector == @selector(insertNewline:) || commandSelector == @selector(insertTab:)) {
            [self.lookupDebounceTimer invalidate];
            [self triggerCallsignLookup];
            if (commandSelector == @selector(insertNewline:)) {
                [self.rstSentField becomeFirstResponder];
                return YES;
            }
        }
    }
    return NO;
}

- (void)voiceLoggerBandOrModeChanged:(id)sender {
    (void)sender;
    [self updateDupeStatusForCallsign:self.callsignField.stringValue];
}

- (void)updateDupeStatusForCallsign:(NSString *)call {
    call = [[call stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if (call.length < 3) {
        self.dupeBadgeButton.title = @"[NEW QSO]";
        self.dupeBadgeButton.contentTintColor = [NSColor secondaryLabelColor];
        self.dupeBadgeButton.toolTip = @"Enter callsign to check duplicate / worked status.";
        return;
    }

    NSString *band = self.bandPopup.selectedItem.title ?: [TX500LogRecord bandForFrequencyHz:self.currentFrequencyHz];
    NSString *mode = self.modePopup.selectedItem.title ?: @"USB";

    NSDictionary<NSString *, id> *dupeInfo = [[TX500LogbookManager sharedManager] dupeStatusForCallsign:call band:band mode:mode];
    NSString *status = dupeInfo[@"status"] ?: @"NEW";
    NSString *badgeText = dupeInfo[@"badgeText"] ?: @"NEW QSO";

    if ([status isEqualToString:@"DUPE"]) {
        self.dupeBadgeButton.title = @"⚠ DUPE!";
        self.dupeBadgeButton.contentTintColor = [NSColor systemRedColor];
        self.dupeBadgeButton.toolTip = [NSString stringWithFormat:@"%@. Click badge to view history.", badgeText];
    } else if ([status isEqualToString:@"WORKED"]) {
        self.dupeBadgeButton.title = @"★ WORKED";
        self.dupeBadgeButton.contentTintColor = [NSColor systemOrangeColor];
        self.dupeBadgeButton.toolTip = [NSString stringWithFormat:@"%@. Click badge to view history.", badgeText];
    } else {
        self.dupeBadgeButton.title = @"✓ NEW";
        self.dupeBadgeButton.contentTintColor = [NSColor systemGreenColor];
        self.dupeBadgeButton.toolTip = [NSString stringWithFormat:@"No previous QSO with %@ on record. Ready to log!", call];
    }
}

- (void)dupeBadgeClicked:(id)sender {
    (void)sender;
    NSString *call = [[self.callsignField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if (call.length == 0) return;

    NSArray<TX500LogRecord *> *history = [[TX500LogbookManager sharedManager] contactsForCallsign:call];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:@"QSO History for %@", call];
    if (history.count == 0) {
        alert.informativeText = [NSString stringWithFormat:@"No previous contacts with %@ logged in your database.", call];
    } else {
        NSMutableString *ms = [NSMutableString stringWithFormat:@"Found %lu past contact(s) in logbook:\n\n", (unsigned long)history.count];
        for (TX500LogRecord *r in history) {
            [ms appendFormat:@"• %@ %@ UTC | %@ %@ | RST: %@/%@ | QRZ: %@, LoTW: %@\n",
             [r formattedDate], [r formattedTime], r.band, r.mode, r.rstSent, r.rstRcvd,
             [self formatCloudStatusText:r.qrzStatus], [self formatCloudStatusText:r.lotwStatus]];
        }
        alert.informativeText = ms;
    }
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)updateBearingAndDistanceDisplay {
    NSString *theirGrid = [self.gridField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (theirGrid.length < 4 && [self.hudGridLabel.stringValue hasPrefix:@"Grid: "]) {
        NSString *g = [self.hudGridLabel.stringValue substringFromIndex:6];
        if (![g isEqualToString:@"--"]) theirGrid = g;
    }
    if (theirGrid.length >= 4) {
        NSString *myGrid = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_Station_Grid"];
        if (myGrid.length == 0) myGrid = @"FN20";
        NSString *telemetry = [TX500LogbookManager formattedBearingAndDistanceFromGrid:myGrid toGrid:theirGrid];
        if (telemetry.length > 0) {
            self.bearingDistanceLabel.stringValue = [NSString stringWithFormat:@"🧭 %@", telemetry];
            self.bearingDistanceLabel.toolTip = [NSString stringWithFormat:@"Great Circle from My Grid (%@) to Target Grid (%@)", myGrid, theirGrid];
            return;
        }
    }
    self.bearingDistanceLabel.stringValue = @"🧭 Bearing: --";
    self.bearingDistanceLabel.toolTip = @"Enter 4 or 6-character Maidenhead locator for Azimuth & Distance.";
}

- (void)triggerCallsignLookup {
    NSString *call = [[self.callsignField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] uppercaseString];
    if (call.length < 3) {
        [self resetStationHUD];
        [self updateDupeStatusForCallsign:call];
        return;
    }

    [self updateDupeStatusForCallsign:call];
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

            // Auto-populate input fields
            if (result.name.length > 0) self.nameField.stringValue = result.name;
            if (result.qth.length > 0) self.qthField.stringValue = result.qth;
            if (result.state.length > 0) self.stateField.stringValue = result.state;
            if (result.country.length > 0) self.countryField.stringValue = result.country;
            if (result.grid.length > 0) {
                self.gridField.stringValue = result.grid;
                [self updateBearingAndDistanceDisplay];
            }

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

    // Direct entry fields or HUD fallback
    if (self.nameField.stringValue.length > 0) {
        rec.name = self.nameField.stringValue;
    } else if (![self.hudNameLabel.stringValue isEqualToString:@"Operator Name"] &&
               ![self.hudNameLabel.stringValue containsString:@"(Name Unavailable)"]) {
        rec.name = self.hudNameLabel.stringValue;
    }

    if (self.qthField.stringValue.length > 0) rec.qth = self.qthField.stringValue;
    if (self.stateField.stringValue.length > 0) rec.state = self.stateField.stringValue;
    if (self.countryField.stringValue.length > 0) rec.country = self.countryField.stringValue;
    if (self.gridField.stringValue.length > 0) rec.grid = self.gridField.stringValue;

    if (rec.qth.length == 0 && rec.country.length == 0 &&
        ![self.hudLocationLabel.stringValue isEqualToString:@"QTH / Location / Country"] &&
        ![self.hudLocationLabel.stringValue containsString:@"not found"]) {
        NSArray *locParts = [self.hudLocationLabel.stringValue componentsSeparatedByString:@", "];
        if (locParts.count >= 1) rec.qth = locParts[0];
        if (locParts.count >= 2) rec.state = locParts[1];
        if (locParts.count >= 3) rec.country = locParts[2];
        else if (locParts.count == 2) rec.country = locParts[1];
    }
    if (rec.grid.length == 0 && [self.hudGridLabel.stringValue hasPrefix:@"Grid: "]) {
        NSString *g = [self.hudGridLabel.stringValue substringFromIndex:6];
        if (![g isEqualToString:@"--"]) rec.grid = g;
    }

    // Field Ops (POTA / SOTA / IOTA)
    rec.theirPotaRef = [self.theirPotaField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    rec.myPotaRef = [self.myPotaField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    rec.theirSotaRef = [self.theirSotaField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    rec.iotaRef = [self.iotaField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

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
    [self refreshAwardStatistics];
}

- (void)clearVoiceLoggerFields {
    self.callsignField.stringValue = @"";
    self.notesField.stringValue = @"";
    self.rstSentField.stringValue = @"59";
    self.rstRcvdField.stringValue = @"59";
    self.nameField.stringValue = @"";
    self.qthField.stringValue = @"";
    self.stateField.stringValue = @"";
    self.countryField.stringValue = @"";
    self.gridField.stringValue = @"";
    self.theirPotaField.stringValue = @"";
    self.theirSotaField.stringValue = @"";
    self.iotaField.stringValue = @"";
    self.bearingDistanceLabel.stringValue = @"🧭 Bearing: --";
    [self updateDupeStatusForCallsign:@""];
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
        [self updateDupeStatusForCallsign:self.callsignField.stringValue];
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

    if (self.tableView.sortDescriptors.count > 0) {
        [self.displayedContacts sortUsingDescriptors:self.tableView.sortDescriptors];
    }

    [self.tableView reloadData];

    NSInteger total = [[TX500LogbookManager sharedManager] totalContactCount];
    NSInteger conf = [[TX500LogbookManager sharedManager] confirmedContactCount];
    self.statsLabel.stringValue = [NSString stringWithFormat:@"Total QSOs: %ld | Confirmed: %ld", (long)total, (long)conf];

    [self refreshAwardStatistics];
}

- (void)refreshAwardStatistics {
    NSDictionary<NSString *, NSNumber *> *stats = [[TX500LogbookManager sharedManager] awardStatistics];
    NSInteger dxccW = [stats[@"dxcc_worked"] integerValue];
    NSInteger dxccC = [stats[@"dxcc_confirmed"] integerValue];
    NSInteger wasW = [stats[@"was_worked"] integerValue];
    NSInteger wasC = [stats[@"was_confirmed"] integerValue];
    NSInteger wazW = [stats[@"waz_worked"] integerValue];
    NSInteger wazC = [stats[@"waz_confirmed"] integerValue];
    NSInteger pota = [stats[@"pota_qsos"] integerValue];
    NSInteger sota = [stats[@"sota_qsos"] integerValue];
    NSInteger iota = [stats[@"iota_qsos"] integerValue];

    self.awardDxccLabel.stringValue = [NSString stringWithFormat:@"🌍 DXCC: %ld / %ld Conf", (long)dxccW, (long)dxccC];
    self.awardWasLabel.stringValue = [NSString stringWithFormat:@"🇺🇸 WAS: %ld / %ld Conf", (long)wasW, (long)wasC];
    self.awardWazLabel.stringValue = [NSString stringWithFormat:@"🌐 WAZ: %ld / %ld Conf", (long)wazW, (long)wazC];
    self.awardPotaLabel.stringValue = [NSString stringWithFormat:@"🌲 POTA: %ld", (long)pota];
    self.awardSotaLabel.stringValue = [NSString stringWithFormat:@"🏔️ SOTA: %ld", (long)sota];
    self.awardIotaLabel.stringValue = [NSString stringWithFormat:@"🏝️ IOTA: %ld", (long)iota];
}

- (void)toggleConsoleCollapse {
    self.isConsoleCollapsed = !self.isConsoleCollapsed;
    if (self.isConsoleCollapsed) {
        self.statusConsoleLabel.hidden = YES;
        self.consoleHeightConstraint.constant = 0.0;
        self.consoleCollapseButton.title = @"▲ Console";
    } else {
        self.statusConsoleLabel.hidden = NO;
        self.consoleHeightConstraint.constant = 18.0;
        self.consoleCollapseButton.title = @"▼ Console";
    }
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

    // Visual QSL Badge Pills for Cloud Services
    if ([colId isEqualToString:@"QRZ"] || [colId isEqualToString:@"LOTW"] || [colId isEqualToString:@"CLUBLOG"] || [colId isEqualToString:@"EQSL"]) {
        NSString *status = @"";
        if ([colId isEqualToString:@"QRZ"]) status = rec.qrzStatus;
        else if ([colId isEqualToString:@"LOTW"]) status = rec.lotwStatus;
        else if ([colId isEqualToString:@"CLUBLOG"]) status = rec.clublogStatus;
        else if ([colId isEqualToString:@"EQSL"]) status = rec.eqslStatus;

        NSString *badgeCellId = [colId stringByAppendingString:@"_BadgeCell"];
        NSTableCellView *badgeCell = [tableView makeViewWithIdentifier:badgeCellId owner:self];
        NSBox *pill = nil;
        NSTextField *lbl = nil;
        if (!badgeCell) {
            badgeCell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, tableColumn.width, 22)];
            badgeCell.identifier = badgeCellId;

            pill = [[NSBox alloc] initWithFrame:NSZeroRect];
            pill.translatesAutoresizingMaskIntoConstraints = NO;
            pill.boxType = NSBoxCustom;
            pill.borderWidth = 1.0;
            pill.cornerRadius = 4.0;

            lbl = [NSTextField labelWithString:@""];
            lbl.translatesAutoresizingMaskIntoConstraints = NO;
            lbl.font = [NSFont systemFontOfSize:10.0 weight:NSFontWeightBold];
            lbl.alignment = NSTextAlignmentCenter;
            lbl.lineBreakMode = NSLineBreakByTruncatingTail;

            [pill addSubview:lbl];
            [badgeCell addSubview:pill];

            [NSLayoutConstraint activateConstraints:@[
                [pill.leadingAnchor constraintEqualToAnchor:badgeCell.leadingAnchor constant:3.0],
                [pill.trailingAnchor constraintEqualToAnchor:badgeCell.trailingAnchor constant:-3.0],
                [pill.centerYAnchor constraintEqualToAnchor:badgeCell.centerYAnchor],
                [pill.heightAnchor constraintEqualToConstant:17.0],

                [lbl.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:2.0],
                [lbl.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-2.0],
                [lbl.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor]
            ]];
        } else {
            pill = (NSBox *)badgeCell.subviews.firstObject;
            lbl = (NSTextField *)pill.subviews.firstObject;
        }

        NSString *title = [self formatCloudStatusText:status];
        NSColor *baseColor = [self colorForCloudStatus:status];
        lbl.stringValue = title;
        lbl.textColor = baseColor;

        if ([status isEqualToString:@"CONFIRMED"]) {
            pill.fillColor = [baseColor colorWithAlphaComponent:0.18];
            pill.borderColor = [baseColor colorWithAlphaComponent:0.65];
        } else if ([status isEqualToString:@"UPLOADED"]) {
            pill.fillColor = [baseColor colorWithAlphaComponent:0.14];
            pill.borderColor = [baseColor colorWithAlphaComponent:0.5];
        } else if ([status isEqualToString:@"QUEUED"]) {
            pill.fillColor = [baseColor colorWithAlphaComponent:0.14];
            pill.borderColor = [baseColor colorWithAlphaComponent:0.5];
        } else if ([status isEqualToString:@"FAILED"] || [status isEqualToString:@"ERROR"]) {
            pill.fillColor = [baseColor colorWithAlphaComponent:0.16];
            pill.borderColor = [baseColor colorWithAlphaComponent:0.6];
        } else {
            pill.fillColor = [[NSColor systemGrayColor] colorWithAlphaComponent:0.06];
            pill.borderColor = [[NSColor systemGrayColor] colorWithAlphaComponent:0.2];
        }
        return badgeCell;
    }

    // Standard Text Cells
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
    } else if ([colId isEqualToString:@"POTA"]) {
        val = rec.theirPotaRef ?: @"";
        font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightMedium];
        if (val.length > 0) textColor = [NSColor systemTealColor];
    } else if ([colId isEqualToString:@"SOTA"]) {
        val = rec.theirSotaRef ?: @"";
        font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightMedium];
        if (val.length > 0) textColor = [NSColor systemOrangeColor];
    } else if ([colId isEqualToString:@"IOTA"]) {
        val = rec.iotaRef ?: @"";
        font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightMedium];
        if (val.length > 0) textColor = [NSColor systemBlueColor];
    }

    cell.textField.stringValue = val;
    cell.textField.textColor = textColor;
    cell.textField.font = font;
    return cell;
}

#pragma mark - Cloud Actions, TQSL LoTW & ADIF Export/Import

- (void)syncAllPending {
    self.statusConsoleLabel.stringValue = @"Synchronizing pending contacts with cloud ecosystem...";
    [[TX500CloudSyncEngine sharedEngine] uploadPendingContactsWithCompletion:^(NSInteger uploadedCount, NSInteger failedCount, NSString *summary) {
        (void)uploadedCount; (void)failedCount;
        self.statusConsoleLabel.stringValue = summary;
        [self refreshAwardStatistics];
    }];
}

- (void)uploadToLoTWViaTQSL {
    NSArray<TX500LogRecord *> *records = nil;
    NSIndexSet *selected = self.tableView.selectedRowIndexes;
    if (selected.count > 0) {
        NSMutableArray *selArr = [NSMutableArray array];
        [selected enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
            (void)stop;
            if (idx < self.displayedContacts.count) {
                [selArr addObject:self.displayedContacts[idx]];
            }
        }];
        records = selArr;
    } else {
        NSMutableArray<TX500LogRecord *> *pending = [NSMutableArray array];
        for (TX500LogRecord *r in [[TX500LogbookManager sharedManager] allContacts]) {
            if (![r.lotwStatus isEqualToString:@"CONFIRMED"] && ![r.lotwStatus isEqualToString:@"UPLOADED"]) {
                [pending addObject:r];
            }
        }
        records = pending;
    }

    if (records.count == 0) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"No Contacts for LoTW";
        alert.informativeText = @"There are no pending or selected contacts to sign and upload to Logbook of The World.";
        [alert runModal];
        return;
    }

    self.statusConsoleLabel.stringValue = [NSString stringWithFormat:@"Invoking TQSL to sign and upload %lu contact(s)...", (unsigned long)records.count];
    [[TX500CloudSyncEngine sharedEngine] signAndUploadContactsToLoTW:records completion:^(BOOL success, NSString *message) {
        (void)success;
        dispatch_async(dispatch_get_main_queue(), ^{
            self.statusConsoleLabel.stringValue = message;
            [self reloadTableData];
            [self updateCloudStatusPills];
            [self refreshAwardStatistics];
        });
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
                [self refreshAwardStatistics];
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
    if ([rawStatus isEqualToString:@"CONFIRMED"]) return @"✓ Confirmed";
    if ([rawStatus isEqualToString:@"UPLOADED"]) return @"✓ Sent";
    if ([rawStatus isEqualToString:@"QUEUED"]) return @"⌛ Queued";
    if ([rawStatus isEqualToString:@"FAILED"] || [rawStatus isEqualToString:@"ERROR"]) return @"! Failed";
    return rawStatus;
}

- (NSColor *)colorForCloudStatus:(NSString *)rawStatus {
    if ([rawStatus isEqualToString:@"CONFIRMED"]) return [NSColor systemGreenColor];
    if ([rawStatus isEqualToString:@"UPLOADED"]) return [NSColor systemTealColor];
    if ([rawStatus isEqualToString:@"QUEUED"]) return [NSColor systemOrangeColor];
    if ([rawStatus isEqualToString:@"FAILED"] || [rawStatus isEqualToString:@"ERROR"]) return [NSColor systemRedColor];
    return [NSColor secondaryLabelColor];
}

@end
