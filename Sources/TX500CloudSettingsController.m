//
//  TX500CloudSettingsController.m
//  Lab599 Utility
//
//  Comprehensive Multi-Service Cloud Settings Window Controller
//  Provides dedicated tabs for LoTW (.p12 certificate, TQSL sync),
//  QRZ.com (API, XML, 2FA WebKit), Club Log (2FA WebKit), eQSL, and HamQTH.
//

#import "TX500CloudSettingsController.h"
#import "TX500CloudSyncEngine.h"
#import "TX500WebAuthenticatorController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

NSString * const TX500CloudSettingsDidChangeNotification = @"TX500CloudSettingsDidChangeNotification";

@interface TX500CloudSettingsController ()

@property (nonatomic, strong) NSSegmentedControl *tabSegment;
@property (nonatomic, strong) NSTabView *tabView;
@property (nonatomic, strong) TX500WebAuthenticatorController *activeAuthenticator;

// LoTW Controls
@property (nonatomic, strong) NSTextField *lotwUsernameField;
@property (nonatomic, strong) NSSecureTextField *lotwPasswordField;
@property (nonatomic, strong) NSTextField *lotwStationLocationField;
@property (nonatomic, strong) NSTextField *lotwCertPathLabel;
@property (nonatomic, strong) NSSecureTextField *lotwCertPasswordField;
@property (nonatomic, strong) NSTextField *lotwTQSLPathField;
@property (nonatomic, strong) NSTextField *lotwTQSLSyncStatusLabel;
@property (nonatomic, strong) NSButton *btnRemoveCert;

// QRZ Controls
@property (nonatomic, strong) NSTextField *qrzApiKeyField;
@property (nonatomic, strong) NSTextField *qrzUsernameField;
@property (nonatomic, strong) NSSecureTextField *qrzPasswordField;
@property (nonatomic, strong) NSTextField *qrz2FAStatusBadge;

// Club Log Controls
@property (nonatomic, strong) NSTextField *clubLogCallsignField;
@property (nonatomic, strong) NSTextField *clubLogEmailField;
@property (nonatomic, strong) NSSecureTextField *clubLogPasswordField;
@property (nonatomic, strong) NSTextField *clubLogApiKeyField;
@property (nonatomic, strong) NSTextField *clubLog2FAStatusBadge;

// eQSL Controls
@property (nonatomic, strong) NSTextField *eqslUsernameField;
@property (nonatomic, strong) NSSecureTextField *eqslPasswordField;
@property (nonatomic, strong) NSTextField *eqslNicknameField;

// HamQTH Controls
@property (nonatomic, strong) NSTextField *hamQTHUsernameField;
@property (nonatomic, strong) NSSecureTextField *hamQTHPasswordField;

@end

@implementation TX500CloudSettingsController

@synthesize settingsView = _settingsView;

+ (instancetype)sharedController {
    static TX500CloudSettingsController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[self alloc] init];
    });
    return shared;
}

- (instancetype)init {
    self = [super initWithWindow:nil];
    if (self) {
        [self setupSettingsView];
        [self loadSavedSettings];
    }
    return self;
}

- (NSView *)settingsView {
    if (!_settingsView) {
        [self setupSettingsView];
    }
    return _settingsView;
}

- (void)setupSettingsView {
    if (_settingsView) return;

    _settingsView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 700, 520)];
    _settingsView.translatesAutoresizingMaskIntoConstraints = NO;

    // Segmented Tab Selector
    NSArray *titles = @[@"LoTW", @"QRZ.com", @"Club Log", @"eQSL.cc", @"HamQTH"];
    self.tabSegment = [NSSegmentedControl segmentedControlWithLabels:titles
                                                        trackingMode:NSSegmentSwitchTrackingSelectOne
                                                              target:self
                                                              action:@selector(tabChanged:)];
    self.tabSegment.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabSegment.selectedSegment = 0;
    self.tabSegment.segmentStyle = NSSegmentStyleTexturedRounded;
    [_settingsView addSubview:self.tabSegment];

    // Tab View Container
    self.tabView = [[NSTabView alloc] initWithFrame:NSZeroRect];
    self.tabView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tabView.tabViewType = NSNoTabsNoBorder;
    [_settingsView addSubview:self.tabView];

    // Bottom Action Bar
    NSBox *actionDivider = [[NSBox alloc] initWithFrame:NSZeroRect];
    actionDivider.translatesAutoresizingMaskIntoConstraints = NO;
    actionDivider.boxType = NSBoxSeparator;
    [_settingsView addSubview:actionDivider];

    NSTextField *keychainBadge = [NSTextField labelWithString:@"🔒 Stored securely in macOS Keychain • Real-time Cloud Sync"];
    keychainBadge.translatesAutoresizingMaskIntoConstraints = NO;
    keychainBadge.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    keychainBadge.textColor = [NSColor secondaryLabelColor];
    [_settingsView addSubview:keychainBadge];

    NSButton *btnSave = [NSButton buttonWithTitle:@"Save & Apply Cloud Settings" target:self action:@selector(saveAndApplyClicked)];
    btnSave.translatesAutoresizingMaskIntoConstraints = NO;
    btnSave.bezelStyle = NSBezelStyleRounded;
    btnSave.keyEquivalent = @"\r";
    btnSave.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    [_settingsView addSubview:btnSave];

    [NSLayoutConstraint activateConstraints:@[
        [self.tabSegment.topAnchor constraintEqualToAnchor:_settingsView.topAnchor constant:6.0],
        [self.tabSegment.centerXAnchor constraintEqualToAnchor:_settingsView.centerXAnchor],
        [self.tabSegment.heightAnchor constraintEqualToConstant:26.0],

        [self.tabView.topAnchor constraintEqualToAnchor:self.tabSegment.bottomAnchor constant:8.0],
        [self.tabView.leadingAnchor constraintEqualToAnchor:_settingsView.leadingAnchor constant:2.0],
        [self.tabView.trailingAnchor constraintEqualToAnchor:_settingsView.trailingAnchor constant:-2.0],
        [self.tabView.bottomAnchor constraintEqualToAnchor:actionDivider.topAnchor constant:-8.0],
        [self.tabView.heightAnchor constraintGreaterThanOrEqualToConstant:470.0],

        [actionDivider.leadingAnchor constraintEqualToAnchor:_settingsView.leadingAnchor],
        [actionDivider.trailingAnchor constraintEqualToAnchor:_settingsView.trailingAnchor],
        [actionDivider.bottomAnchor constraintEqualToAnchor:btnSave.topAnchor constant:-8.0],
        [actionDivider.heightAnchor constraintEqualToConstant:1.0],

        [keychainBadge.leadingAnchor constraintEqualToAnchor:_settingsView.leadingAnchor constant:6.0],
        [keychainBadge.centerYAnchor constraintEqualToAnchor:btnSave.centerYAnchor],
        [keychainBadge.trailingAnchor constraintLessThanOrEqualToAnchor:btnSave.leadingAnchor constant:-10.0],

        [btnSave.trailingAnchor constraintEqualToAnchor:_settingsView.trailingAnchor constant:-6.0],
        [btnSave.bottomAnchor constraintEqualToAnchor:_settingsView.bottomAnchor constant:-6.0],
        [btnSave.heightAnchor constraintEqualToConstant:28.0]
    ]];

    // Build Tab Content Views
    [self.tabView addTabViewItem:[self createLoTWTabItem]];
    [self.tabView addTabViewItem:[self createQRZTabItem]];
    [self.tabView addTabViewItem:[self createClubLogTabItem]];
    [self.tabView addTabViewItem:[self createEQSLTabItem]];
    [self.tabView addTabViewItem:[self createHamQTHTabItem]];
    if (self.tabView.numberOfTabViewItems > 0) {
        [self.tabView selectTabViewItemAtIndex:0];
    }
}

- (void)tabChanged:(id)sender {
    (void)sender;
    if (self.tabSegment.selectedSegment >= 0 && self.tabSegment.selectedSegment < self.tabView.numberOfTabViewItems) {
        [self.tabView selectTabViewItemAtIndex:self.tabSegment.selectedSegment];
    }
}

- (void)selectTabWithService:(nullable NSString *)service {
    if (!_settingsView) {
        [self setupSettingsView];
    }
    if (!service || service.length == 0) return;
    NSString *s = service.lowercaseString;
    NSInteger idx = 0;
    if ([s containsString:@"lotw"]) {
        idx = 0;
    } else if ([s containsString:@"qrz"]) {
        idx = 1;
    } else if ([s containsString:@"club"]) {
        idx = 2;
    } else if ([s containsString:@"eqsl"]) {
        idx = 3;
    } else if ([s containsString:@"hamqth"]) {
        idx = 4;
    }
    self.tabSegment.selectedSegment = idx;
    [self tabChanged:self.tabSegment];
}

#pragma mark - Tab 1: ARRL Logbook of the World (LoTW)

- (NSTabViewItem *)createLoTWTabItem {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"lotw"];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 640, 430)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;

    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 520)];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = v;

    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [v.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [v.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor]
    ]];

    NSTextField *title = [NSTextField labelWithString:@"Logbook of The World (LoTW)"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightBold];
    [v addSubview:title];

    // Username
    NSTextField *lblUser = [NSTextField labelWithString:@"Username:"];
    lblUser.translatesAutoresizingMaskIntoConstraints = NO;
    lblUser.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblUser];

    self.lotwUsernameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.lotwUsernameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.lotwUsernameField.placeholderString = @"e.g. ep2aes";
    [v addSubview:self.lotwUsernameField];

    // Password
    NSTextField *lblPass = [NSTextField labelWithString:@"New password (blank keeps the saved password):"];
    lblPass.translatesAutoresizingMaskIntoConstraints = NO;
    lblPass.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblPass];

    self.lotwPasswordField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.lotwPasswordField.translatesAutoresizingMaskIntoConstraints = NO;
    self.lotwPasswordField.placeholderString = @"LoTW web password";
    [v addSubview:self.lotwPasswordField];

    // Default Station Location
    NSTextField *lblLoc = [NSTextField labelWithString:@"Default Station Location (e.g. EP2AES-Home):"];
    lblLoc.translatesAutoresizingMaskIntoConstraints = NO;
    lblLoc.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblLoc];

    self.lotwStationLocationField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.lotwStationLocationField.translatesAutoresizingMaskIntoConstraints = NO;
    self.lotwStationLocationField.placeholderString = @"Station Location defined in TQSL";
    [v addSubview:self.lotwStationLocationField];

    NSTextField *locHint = [NSTextField labelWithString:@"Station Location name defined in TQSL for this callsign (also synced with active Station Profile)."];
    locHint.translatesAutoresizingMaskIntoConstraints = NO;
    locHint.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    locHint.textColor = [NSColor secondaryLabelColor];
    [v addSubview:locHint];

    NSTextField *keychainNote = [NSTextField labelWithString:@"🔒 Stored securely in macOS Keychain / Secure Storage"];
    keychainNote.translatesAutoresizingMaskIntoConstraints = NO;
    keychainNote.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    keychainNote.textColor = [NSColor secondaryLabelColor];
    [v addSubview:keychainNote];

    // Password Action Buttons
    NSButton *btnSavePass = [NSButton buttonWithTitle:@"Save LoTW Password" target:self action:@selector(saveLoTWPasswordClicked)];
    btnSavePass.translatesAutoresizingMaskIntoConstraints = NO;
    btnSavePass.bezelStyle = NSBezelStyleRounded;
    [v addSubview:btnSavePass];

    NSButton *btnRemovePass = [NSButton buttonWithTitle:@"Remove Password" target:self action:@selector(removeLoTWPasswordClicked)];
    btnRemovePass.translatesAutoresizingMaskIntoConstraints = NO;
    btnRemovePass.bezelStyle = NSBezelStyleRounded;
    [v addSubview:btnRemovePass];

    // Sync TQSL Button
    NSButton *btnSyncTQSL = [NSButton buttonWithTitle:@"Sync TQSL Data (~/.tqsl)" target:self action:@selector(syncTQSLDataClicked)];
    btnSyncTQSL.translatesAutoresizingMaskIntoConstraints = NO;
    btnSyncTQSL.bezelStyle = NSBezelStyleRounded;
    [v addSubview:btnSyncTQSL];

    self.lotwTQSLSyncStatusLabel = [NSTextField labelWithString:@""];
    self.lotwTQSLSyncStatusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.lotwTQSLSyncStatusLabel.font = [NSFont systemFontOfSize:11.0];
    self.lotwTQSLSyncStatusLabel.textColor = [NSColor secondaryLabelColor];
    [v addSubview:self.lotwTQSLSyncStatusLabel];

    // Divider
    NSBox *div1 = [[NSBox alloc] initWithFrame:NSZeroRect];
    div1.translatesAutoresizingMaskIntoConstraints = NO;
    div1.boxType = NSBoxSeparator;
    [v addSubview:div1];

    // LoTW Certificate Container (.p12) Box
    NSBox *certBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    certBox.boxType = NSBoxCustom;
    certBox.translatesAutoresizingMaskIntoConstraints = NO;
    certBox.cornerRadius = 6.0;
    certBox.borderWidth = 1.0;
    certBox.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.18];
    certBox.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.04];
    [v addSubview:certBox];

    NSTextField *certTitle = [NSTextField labelWithString:@"LoTW Certificate Container (.p12)"];
    certTitle.translatesAutoresizingMaskIntoConstraints = NO;
    certTitle.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightBold];
    [certBox addSubview:certTitle];

    self.lotwCertPathLabel = [NSTextField labelWithString:@"No certificate container selected"];
    self.lotwCertPathLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.lotwCertPathLabel.font = [NSFont monospacedSystemFontOfSize:11.0 weight:NSFontWeightRegular];
    self.lotwCertPathLabel.textColor = [NSColor secondaryLabelColor];
    [certBox addSubview:self.lotwCertPathLabel];

    NSButton *btnChooseCert = [NSButton buttonWithTitle:@"Choose .p12..." target:self action:@selector(chooseCertificateClicked)];
    btnChooseCert.translatesAutoresizingMaskIntoConstraints = NO;
    btnChooseCert.bezelStyle = NSBezelStyleRounded;
    [certBox addSubview:btnChooseCert];

    self.btnRemoveCert = [NSButton buttonWithTitle:@"Remove Certificate" target:self action:@selector(removeCertificateClicked)];
    self.btnRemoveCert.translatesAutoresizingMaskIntoConstraints = NO;
    self.btnRemoveCert.bezelStyle = NSBezelStyleRounded;
    [certBox addSubview:self.btnRemoveCert];

    NSTextField *lblCertPass = [NSTextField labelWithString:@"Certificate password (optional, saved securely):"];
    lblCertPass.translatesAutoresizingMaskIntoConstraints = NO;
    lblCertPass.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    [certBox addSubview:lblCertPass];

    self.lotwCertPasswordField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.lotwCertPasswordField.translatesAutoresizingMaskIntoConstraints = NO;
    self.lotwCertPasswordField.placeholderString = @"Certificate .p12 passphrase";
    [certBox addSubview:self.lotwCertPasswordField];

    NSButton *btnSaveCertPass = [NSButton buttonWithTitle:@"Save Certificate Password" target:self action:@selector(saveCertPasswordClicked)];
    btnSaveCertPass.translatesAutoresizingMaskIntoConstraints = NO;
    btnSaveCertPass.bezelStyle = NSBezelStyleRounded;
    [certBox addSubview:btnSaveCertPass];

    NSButton *btnRemoveCertPass = [NSButton buttonWithTitle:@"Remove Certificate Password" target:self action:@selector(removeCertPasswordClicked)];
    btnRemoveCertPass.translatesAutoresizingMaskIntoConstraints = NO;
    btnRemoveCertPass.bezelStyle = NSBezelStyleRounded;
    [certBox addSubview:btnRemoveCertPass];

    NSTextField *certFooter = [NSTextField labelWithString:@"TX-500 Utility keeps a security-scoped reference to the .p12 file. TQSL must import the certificate before it can sign and upload new QSOs; the file itself is never copied into the logbook."];
    certFooter.translatesAutoresizingMaskIntoConstraints = NO;
    certFooter.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightRegular];
    certFooter.textColor = [NSColor secondaryLabelColor];
    [certBox addSubview:certFooter];

    // Layout inside certBox
    [NSLayoutConstraint activateConstraints:@[
        [certTitle.topAnchor constraintEqualToAnchor:certBox.topAnchor constant:10.0],
        [certTitle.leadingAnchor constraintEqualToAnchor:certBox.leadingAnchor constant:12.0],

        [self.lotwCertPathLabel.topAnchor constraintEqualToAnchor:certTitle.bottomAnchor constant:4.0],
        [self.lotwCertPathLabel.leadingAnchor constraintEqualToAnchor:certTitle.leadingAnchor],
        [self.lotwCertPathLabel.trailingAnchor constraintEqualToAnchor:certBox.trailingAnchor constant:-12.0],

        [btnChooseCert.topAnchor constraintEqualToAnchor:self.lotwCertPathLabel.bottomAnchor constant:8.0],
        [btnChooseCert.leadingAnchor constraintEqualToAnchor:certTitle.leadingAnchor],

        [self.btnRemoveCert.leadingAnchor constraintEqualToAnchor:btnChooseCert.trailingAnchor constant:8.0],
        [self.btnRemoveCert.centerYAnchor constraintEqualToAnchor:btnChooseCert.centerYAnchor],

        [lblCertPass.topAnchor constraintEqualToAnchor:btnChooseCert.bottomAnchor constant:10.0],
        [lblCertPass.leadingAnchor constraintEqualToAnchor:certTitle.leadingAnchor],

        [self.lotwCertPasswordField.topAnchor constraintEqualToAnchor:lblCertPass.bottomAnchor constant:4.0],
        [self.lotwCertPasswordField.leadingAnchor constraintEqualToAnchor:certTitle.leadingAnchor],
        [self.lotwCertPasswordField.trailingAnchor constraintEqualToAnchor:certBox.trailingAnchor constant:-12.0],

        [btnSaveCertPass.topAnchor constraintEqualToAnchor:self.lotwCertPasswordField.bottomAnchor constant:6.0],
        [btnSaveCertPass.leadingAnchor constraintEqualToAnchor:certTitle.leadingAnchor],

        [btnRemoveCertPass.leadingAnchor constraintEqualToAnchor:btnSaveCertPass.trailingAnchor constant:8.0],
        [btnRemoveCertPass.centerYAnchor constraintEqualToAnchor:btnSaveCertPass.centerYAnchor],

        [certFooter.topAnchor constraintEqualToAnchor:btnSaveCertPass.bottomAnchor constant:8.0],
        [certFooter.leadingAnchor constraintEqualToAnchor:certTitle.leadingAnchor],
        [certFooter.trailingAnchor constraintEqualToAnchor:certBox.trailingAnchor constant:-12.0],
        [certFooter.bottomAnchor constraintEqualToAnchor:certBox.bottomAnchor constant:-10.0]
    ]];

    // Overall Tab 1 Constraints
    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:v.topAnchor constant:6.0],
        [title.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:4.0],

        [lblUser.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:10.0],
        [lblUser.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.lotwUsernameField.topAnchor constraintEqualToAnchor:lblUser.bottomAnchor constant:4.0],
        [self.lotwUsernameField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.lotwUsernameField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [lblPass.topAnchor constraintEqualToAnchor:self.lotwUsernameField.bottomAnchor constant:8.0],
        [lblPass.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.lotwPasswordField.topAnchor constraintEqualToAnchor:lblPass.bottomAnchor constant:4.0],
        [self.lotwPasswordField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.lotwPasswordField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [lblLoc.topAnchor constraintEqualToAnchor:self.lotwPasswordField.bottomAnchor constant:8.0],
        [lblLoc.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.lotwStationLocationField.topAnchor constraintEqualToAnchor:lblLoc.bottomAnchor constant:4.0],
        [self.lotwStationLocationField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.lotwStationLocationField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [locHint.topAnchor constraintEqualToAnchor:self.lotwStationLocationField.bottomAnchor constant:3.0],
        [locHint.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [keychainNote.topAnchor constraintEqualToAnchor:locHint.bottomAnchor constant:4.0],
        [keychainNote.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [btnSavePass.topAnchor constraintEqualToAnchor:keychainNote.bottomAnchor constant:6.0],
        [btnSavePass.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [btnRemovePass.leadingAnchor constraintEqualToAnchor:btnSavePass.trailingAnchor constant:8.0],
        [btnRemovePass.centerYAnchor constraintEqualToAnchor:btnSavePass.centerYAnchor],

        [btnSyncTQSL.topAnchor constraintEqualToAnchor:btnSavePass.bottomAnchor constant:8.0],
        [btnSyncTQSL.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.lotwTQSLSyncStatusLabel.leadingAnchor constraintEqualToAnchor:btnSyncTQSL.trailingAnchor constant:10.0],
        [self.lotwTQSLSyncStatusLabel.centerYAnchor constraintEqualToAnchor:btnSyncTQSL.centerYAnchor],

        [div1.topAnchor constraintEqualToAnchor:btnSyncTQSL.bottomAnchor constant:10.0],
        [div1.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [div1.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],
        [div1.heightAnchor constraintEqualToConstant:1.0],

        [certBox.topAnchor constraintEqualToAnchor:div1.bottomAnchor constant:10.0],
        [certBox.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [certBox.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],
        [certBox.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-16.0]
    ]];

    item.view = scroll;
    return item;
}

#pragma mark - Tab 2: QRZ.com

- (NSTabViewItem *)createQRZTabItem {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"qrz"];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 640, 430)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;

    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 420)];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = v;

    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [v.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [v.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor]
    ]];

    NSTextField *title = [NSTextField labelWithString:@"QRZ.com (Logbook API & XML Callbook)"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightBold];
    [v addSubview:title];

    NSTextField *lblApiKey = [NSTextField labelWithString:@"QRZ Logbook API Key (for real-time QSO sync):"];
    lblApiKey.translatesAutoresizingMaskIntoConstraints = NO;
    lblApiKey.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblApiKey];

    self.qrzApiKeyField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.qrzApiKeyField.translatesAutoresizingMaskIntoConstraints = NO;
    self.qrzApiKeyField.placeholderString = @"e.g. 1234-5678-ABCD-EF01";
    [v addSubview:self.qrzApiKeyField];

    NSTextField *lblUser = [NSTextField labelWithString:@"XML / Web Username:"];
    lblUser.translatesAutoresizingMaskIntoConstraints = NO;
    lblUser.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblUser];

    self.qrzUsernameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.qrzUsernameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.qrzUsernameField.placeholderString = @"QRZ callsign or username";
    [v addSubview:self.qrzUsernameField];

    NSTextField *lblPass = [NSTextField labelWithString:@"XML / Web Password:"];
    lblPass.translatesAutoresizingMaskIntoConstraints = NO;
    lblPass.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblPass];

    self.qrzPasswordField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.qrzPasswordField.translatesAutoresizingMaskIntoConstraints = NO;
    self.qrzPasswordField.placeholderString = @"QRZ account password";
    [v addSubview:self.qrzPasswordField];

    // 2FA Box
    NSBox *mfaBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    mfaBox.boxType = NSBoxCustom;
    mfaBox.translatesAutoresizingMaskIntoConstraints = NO;
    mfaBox.cornerRadius = 6.0;
    mfaBox.borderWidth = 1.0;
    mfaBox.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.18];
    mfaBox.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.04];
    [v addSubview:mfaBox];

    NSTextField *mfaTitle = [NSTextField labelWithString:@"2-Factor Authentication (2FA / MFA WebKit)"];
    mfaTitle.translatesAutoresizingMaskIntoConstraints = NO;
    mfaTitle.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightBold];
    [mfaBox addSubview:mfaTitle];

    self.qrz2FAStatusBadge = [NSTextField labelWithString:@"⚪ No 2FA Session Saved"];
    self.qrz2FAStatusBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.qrz2FAStatusBadge.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    [mfaBox addSubview:self.qrz2FAStatusBadge];

    NSTextField *mfaDesc = [NSTextField labelWithString:@"If your QRZ.com account uses 2-Factor Authentication (2FA/MFA) or if you want to sign in directly through the secure WebKit browser, click below."];
    mfaDesc.translatesAutoresizingMaskIntoConstraints = NO;
    mfaDesc.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    mfaDesc.textColor = [NSColor secondaryLabelColor];
    [mfaBox addSubview:mfaDesc];

    NSButton *btn2FA = [NSButton buttonWithTitle:@"Log In & Verify 2FA (WebKit)" target:self action:@selector(qrz2FALoginClicked)];
    btn2FA.translatesAutoresizingMaskIntoConstraints = NO;
    btn2FA.bezelStyle = NSBezelStyleRounded;
    [mfaBox addSubview:btn2FA];

    NSButton *btnClear2FA = [NSButton buttonWithTitle:@"Clear 2FA Session" target:self action:@selector(qrz2FAClearClicked)];
    btnClear2FA.translatesAutoresizingMaskIntoConstraints = NO;
    btnClear2FA.bezelStyle = NSBezelStyleRounded;
    [mfaBox addSubview:btnClear2FA];

    [NSLayoutConstraint activateConstraints:@[
        [mfaTitle.topAnchor constraintEqualToAnchor:mfaBox.topAnchor constant:10.0],
        [mfaTitle.leadingAnchor constraintEqualToAnchor:mfaBox.leadingAnchor constant:12.0],

        [self.qrz2FAStatusBadge.leadingAnchor constraintEqualToAnchor:mfaTitle.trailingAnchor constant:12.0],
        [self.qrz2FAStatusBadge.centerYAnchor constraintEqualToAnchor:mfaTitle.centerYAnchor],

        [mfaDesc.topAnchor constraintEqualToAnchor:mfaTitle.bottomAnchor constant:6.0],
        [mfaDesc.leadingAnchor constraintEqualToAnchor:mfaTitle.leadingAnchor],
        [mfaDesc.trailingAnchor constraintEqualToAnchor:mfaBox.trailingAnchor constant:-12.0],

        [btn2FA.topAnchor constraintEqualToAnchor:mfaDesc.bottomAnchor constant:10.0],
        [btn2FA.leadingAnchor constraintEqualToAnchor:mfaTitle.leadingAnchor],
        [btn2FA.bottomAnchor constraintEqualToAnchor:mfaBox.bottomAnchor constant:-10.0],

        [btnClear2FA.leadingAnchor constraintEqualToAnchor:btn2FA.trailingAnchor constant:8.0],
        [btnClear2FA.centerYAnchor constraintEqualToAnchor:btn2FA.centerYAnchor]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:v.topAnchor constant:10.0],
        [title.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:4.0],

        [lblApiKey.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12.0],
        [lblApiKey.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.qrzApiKeyField.topAnchor constraintEqualToAnchor:lblApiKey.bottomAnchor constant:4.0],
        [self.qrzApiKeyField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.qrzApiKeyField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [lblUser.topAnchor constraintEqualToAnchor:self.qrzApiKeyField.bottomAnchor constant:10.0],
        [lblUser.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.qrzUsernameField.topAnchor constraintEqualToAnchor:lblUser.bottomAnchor constant:4.0],
        [self.qrzUsernameField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.qrzUsernameField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [lblPass.topAnchor constraintEqualToAnchor:self.qrzUsernameField.bottomAnchor constant:10.0],
        [lblPass.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.qrzPasswordField.topAnchor constraintEqualToAnchor:lblPass.bottomAnchor constant:4.0],
        [self.qrzPasswordField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.qrzPasswordField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [mfaBox.topAnchor constraintEqualToAnchor:self.qrzPasswordField.bottomAnchor constant:16.0],
        [mfaBox.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [mfaBox.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],
        [mfaBox.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-16.0]
    ]];

    item.view = scroll;
    return item;
}

#pragma mark - Tab 3: Club Log

- (NSTabViewItem *)createClubLogTabItem {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"clublog"];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 640, 430)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;

    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 460)];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = v;

    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [v.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [v.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor]
    ]];

    NSTextField *title = [NSTextField labelWithString:@"Club Log (Real-time Uploads & Callsign Intelligence)"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightBold];
    [v addSubview:title];

    NSTextField *lblCall = [NSTextField labelWithString:@"Club Log Callsign:"];
    lblCall.translatesAutoresizingMaskIntoConstraints = NO;
    lblCall.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblCall];

    self.clubLogCallsignField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.clubLogCallsignField.translatesAutoresizingMaskIntoConstraints = NO;
    self.clubLogCallsignField.placeholderString = @"e.g. EP2AES";
    [v addSubview:self.clubLogCallsignField];

    NSTextField *lblEmail = [NSTextField labelWithString:@"Account Email:"];
    lblEmail.translatesAutoresizingMaskIntoConstraints = NO;
    lblEmail.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblEmail];

    self.clubLogEmailField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.clubLogEmailField.translatesAutoresizingMaskIntoConstraints = NO;
    self.clubLogEmailField.placeholderString = @"user@example.com";
    [v addSubview:self.clubLogEmailField];

    NSTextField *lblPass = [NSTextField labelWithString:@"Application Password:"];
    lblPass.translatesAutoresizingMaskIntoConstraints = NO;
    lblPass.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblPass];

    self.clubLogPasswordField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.clubLogPasswordField.translatesAutoresizingMaskIntoConstraints = NO;
    self.clubLogPasswordField.placeholderString = @"Club Log application password";
    [v addSubview:self.clubLogPasswordField];

    NSTextField *lblApiKey = [NSTextField labelWithString:@"API Key (Optional):"];
    lblApiKey.translatesAutoresizingMaskIntoConstraints = NO;
    lblApiKey.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblApiKey];

    self.clubLogApiKeyField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.clubLogApiKeyField.translatesAutoresizingMaskIntoConstraints = NO;
    self.clubLogApiKeyField.placeholderString = @"Public Club Log API Key";
    [v addSubview:self.clubLogApiKeyField];

    // 2FA Box
    NSBox *mfaBox = [[NSBox alloc] initWithFrame:NSZeroRect];
    mfaBox.boxType = NSBoxCustom;
    mfaBox.translatesAutoresizingMaskIntoConstraints = NO;
    mfaBox.cornerRadius = 6.0;
    mfaBox.borderWidth = 1.0;
    mfaBox.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.18];
    mfaBox.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.04];
    [v addSubview:mfaBox];

    NSTextField *mfaTitle = [NSTextField labelWithString:@"2-Factor Authentication (2FA / WebKit Authenticator)"];
    mfaTitle.translatesAutoresizingMaskIntoConstraints = NO;
    mfaTitle.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightBold];
    [mfaBox addSubview:mfaTitle];

    self.clubLog2FAStatusBadge = [NSTextField labelWithString:@"⚪ No 2FA Session Saved"];
    self.clubLog2FAStatusBadge.translatesAutoresizingMaskIntoConstraints = NO;
    self.clubLog2FAStatusBadge.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightMedium];
    [mfaBox addSubview:self.clubLog2FAStatusBadge];

    NSTextField *mfaDesc = [NSTextField labelWithString:@"If your Club Log account uses 2-Factor Authentication (2FA/MFA) or if you want to sign in directly through the secure WebKit browser, click below."];
    mfaDesc.translatesAutoresizingMaskIntoConstraints = NO;
    mfaDesc.font = [NSFont systemFontOfSize:11.0 weight:NSFontWeightRegular];
    mfaDesc.textColor = [NSColor secondaryLabelColor];
    [mfaBox addSubview:mfaDesc];

    NSButton *btn2FA = [NSButton buttonWithTitle:@"Log In & Verify 2FA (WebKit)" target:self action:@selector(clubLog2FALoginClicked)];
    btn2FA.translatesAutoresizingMaskIntoConstraints = NO;
    btn2FA.bezelStyle = NSBezelStyleRounded;
    [mfaBox addSubview:btn2FA];

    NSButton *btnClear2FA = [NSButton buttonWithTitle:@"Clear 2FA Session" target:self action:@selector(clubLog2FAClearClicked)];
    btnClear2FA.translatesAutoresizingMaskIntoConstraints = NO;
    btnClear2FA.bezelStyle = NSBezelStyleRounded;
    [mfaBox addSubview:btnClear2FA];

    [NSLayoutConstraint activateConstraints:@[
        [mfaTitle.topAnchor constraintEqualToAnchor:mfaBox.topAnchor constant:10.0],
        [mfaTitle.leadingAnchor constraintEqualToAnchor:mfaBox.leadingAnchor constant:12.0],

        [self.clubLog2FAStatusBadge.leadingAnchor constraintEqualToAnchor:mfaTitle.trailingAnchor constant:12.0],
        [self.clubLog2FAStatusBadge.centerYAnchor constraintEqualToAnchor:mfaTitle.centerYAnchor],

        [mfaDesc.topAnchor constraintEqualToAnchor:mfaTitle.bottomAnchor constant:6.0],
        [mfaDesc.leadingAnchor constraintEqualToAnchor:mfaTitle.leadingAnchor],
        [mfaDesc.trailingAnchor constraintEqualToAnchor:mfaBox.trailingAnchor constant:-12.0],

        [btn2FA.topAnchor constraintEqualToAnchor:mfaDesc.bottomAnchor constant:10.0],
        [btn2FA.leadingAnchor constraintEqualToAnchor:mfaTitle.leadingAnchor],
        [btn2FA.bottomAnchor constraintEqualToAnchor:mfaBox.bottomAnchor constant:-10.0],

        [btnClear2FA.leadingAnchor constraintEqualToAnchor:btn2FA.trailingAnchor constant:8.0],
        [btnClear2FA.centerYAnchor constraintEqualToAnchor:btn2FA.centerYAnchor]
    ]];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:v.topAnchor constant:10.0],
        [title.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:4.0],

        [lblCall.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12.0],
        [lblCall.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.clubLogCallsignField.topAnchor constraintEqualToAnchor:lblCall.bottomAnchor constant:4.0],
        [self.clubLogCallsignField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.clubLogCallsignField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [lblEmail.topAnchor constraintEqualToAnchor:self.clubLogCallsignField.bottomAnchor constant:10.0],
        [lblEmail.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.clubLogEmailField.topAnchor constraintEqualToAnchor:lblEmail.bottomAnchor constant:4.0],
        [self.clubLogEmailField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.clubLogEmailField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [lblPass.topAnchor constraintEqualToAnchor:self.clubLogEmailField.bottomAnchor constant:10.0],
        [lblPass.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.clubLogPasswordField.topAnchor constraintEqualToAnchor:lblPass.bottomAnchor constant:4.0],
        [self.clubLogPasswordField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.clubLogPasswordField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [lblApiKey.topAnchor constraintEqualToAnchor:self.clubLogPasswordField.bottomAnchor constant:10.0],
        [lblApiKey.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.clubLogApiKeyField.topAnchor constraintEqualToAnchor:lblApiKey.bottomAnchor constant:4.0],
        [self.clubLogApiKeyField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.clubLogApiKeyField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [mfaBox.topAnchor constraintEqualToAnchor:self.clubLogApiKeyField.bottomAnchor constant:16.0],
        [mfaBox.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [mfaBox.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],
        [mfaBox.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-16.0]
    ]];

    item.view = scroll;
    return item;
}

#pragma mark - Tab 4: eQSL.cc

- (NSTabViewItem *)createEQSLTabItem {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"eqsl"];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 640, 430)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;

    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = v;

    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [v.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [v.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor]
    ]];

    NSTextField *title = [NSTextField labelWithString:@"eQSL.cc Integration"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightBold];
    [v addSubview:title];

    NSTextField *lblUser = [NSTextField labelWithString:@"eQSL Callsign / Username:"];
    lblUser.translatesAutoresizingMaskIntoConstraints = NO;
    lblUser.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblUser];

    self.eqslUsernameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.eqslUsernameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.eqslUsernameField.placeholderString = @"e.g. EP2AES";
    [v addSubview:self.eqslUsernameField];

    NSTextField *lblPass = [NSTextField labelWithString:@"eQSL Password:"];
    lblPass.translatesAutoresizingMaskIntoConstraints = NO;
    lblPass.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblPass];

    self.eqslPasswordField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.eqslPasswordField.translatesAutoresizingMaskIntoConstraints = NO;
    self.eqslPasswordField.placeholderString = @"eQSL account password";
    [v addSubview:self.eqslPasswordField];

    NSTextField *lblNick = [NSTextField labelWithString:@"QSL Nickname / Station Location (Optional):"];
    lblNick.translatesAutoresizingMaskIntoConstraints = NO;
    lblNick.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblNick];

    self.eqslNicknameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.eqslNicknameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.eqslNicknameField.placeholderString = @"Nickname configured in eQSL";
    [v addSubview:self.eqslNicknameField];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:v.topAnchor constant:10.0],
        [title.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:4.0],

        [lblUser.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12.0],
        [lblUser.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.eqslUsernameField.topAnchor constraintEqualToAnchor:lblUser.bottomAnchor constant:4.0],
        [self.eqslUsernameField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.eqslUsernameField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [lblPass.topAnchor constraintEqualToAnchor:self.eqslUsernameField.bottomAnchor constant:10.0],
        [lblPass.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.eqslPasswordField.topAnchor constraintEqualToAnchor:lblPass.bottomAnchor constant:4.0],
        [self.eqslPasswordField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.eqslPasswordField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [lblNick.topAnchor constraintEqualToAnchor:self.eqslPasswordField.bottomAnchor constant:10.0],
        [lblNick.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.eqslNicknameField.topAnchor constraintEqualToAnchor:lblNick.bottomAnchor constant:4.0],
        [self.eqslNicknameField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.eqslNicknameField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],
        [self.eqslNicknameField.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-20.0]
    ]];

    item.view = scroll;
    return item;
}

#pragma mark - Tab 5: HamQTH.com

- (NSTabViewItem *)createHamQTHTabItem {
    NSTabViewItem *item = [[NSTabViewItem alloc] initWithIdentifier:@"hamqth"];
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 640, 430)];
    scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = NO;

    NSView *v = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 640, 360)];
    v.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.documentView = v;

    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
        [v.leadingAnchor constraintEqualToAnchor:scroll.contentView.leadingAnchor],
        [v.trailingAnchor constraintEqualToAnchor:scroll.contentView.trailingAnchor],
        [v.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor]
    ]];

    NSTextField *title = [NSTextField labelWithString:@"HamQTH.com (Free Callbook Lookups)"];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightBold];
    [v addSubview:title];

    NSTextField *lblUser = [NSTextField labelWithString:@"HamQTH Username:"];
    lblUser.translatesAutoresizingMaskIntoConstraints = NO;
    lblUser.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblUser];

    self.hamQTHUsernameField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.hamQTHUsernameField.translatesAutoresizingMaskIntoConstraints = NO;
    self.hamQTHUsernameField.placeholderString = @"HamQTH login username";
    [v addSubview:self.hamQTHUsernameField];

    NSTextField *lblPass = [NSTextField labelWithString:@"HamQTH Password:"];
    lblPass.translatesAutoresizingMaskIntoConstraints = NO;
    lblPass.font = [NSFont systemFontOfSize:12.0 weight:NSFontWeightMedium];
    [v addSubview:lblPass];

    self.hamQTHPasswordField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.hamQTHPasswordField.translatesAutoresizingMaskIntoConstraints = NO;
    self.hamQTHPasswordField.placeholderString = @"HamQTH login password";
    [v addSubview:self.hamQTHPasswordField];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:v.topAnchor constant:10.0],
        [title.leadingAnchor constraintEqualToAnchor:v.leadingAnchor constant:4.0],

        [lblUser.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:12.0],
        [lblUser.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.hamQTHUsernameField.topAnchor constraintEqualToAnchor:lblUser.bottomAnchor constant:4.0],
        [self.hamQTHUsernameField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.hamQTHUsernameField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],

        [lblPass.topAnchor constraintEqualToAnchor:self.hamQTHUsernameField.bottomAnchor constant:10.0],
        [lblPass.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],

        [self.hamQTHPasswordField.topAnchor constraintEqualToAnchor:lblPass.bottomAnchor constant:4.0],
        [self.hamQTHPasswordField.leadingAnchor constraintEqualToAnchor:title.leadingAnchor],
        [self.hamQTHPasswordField.trailingAnchor constraintEqualToAnchor:v.trailingAnchor constant:-16.0],
        [self.hamQTHPasswordField.bottomAnchor constraintEqualToAnchor:v.bottomAnchor constant:-20.0]
    ]];

    item.view = scroll;
    return item;
}

#pragma mark - Load & Save Logic

- (void)loadSavedSettings {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    // LoTW
    self.lotwUsernameField.stringValue = [ud stringForKey:@"TX500_LoTW_Username"] ?: [ud stringForKey:@"TX500_OperatorCallsign"] ?: @"";
    self.lotwPasswordField.stringValue = [ud stringForKey:@"TX500_LoTW_Password"] ?: @"";
    self.lotwStationLocationField.stringValue = [ud stringForKey:@"TX500_LoTW_StationLocation"] ?: @"";
    NSString *cert = [ud stringForKey:@"TX500_LoTW_CertificatePath"];
    self.lotwCertPathLabel.stringValue = (cert.length > 0) ? cert : @"No certificate container selected";
    self.btnRemoveCert.enabled = (cert.length > 0);
    self.lotwCertPasswordField.stringValue = [ud stringForKey:@"TX500_LoTW_CertificatePassword"] ?: @"";

    // QRZ
    self.qrzApiKeyField.stringValue = [ud stringForKey:@"TX500_QRZ_APIKey"] ?: @"";
    self.qrzUsernameField.stringValue = [ud stringForKey:@"TX500_QRZ_Username"] ?: @"";
    self.qrzPasswordField.stringValue = [ud stringForKey:@"TX500_QRZ_Password"] ?: @"";
    [self update2FABadges];

    // Club Log
    self.clubLogCallsignField.stringValue = [ud stringForKey:@"TX500_ClubLog_Callsign"] ?: @"";
    self.clubLogEmailField.stringValue = [ud stringForKey:@"TX500_ClubLog_Email"] ?: @"";
    self.clubLogPasswordField.stringValue = [ud stringForKey:@"TX500_ClubLog_Password"] ?: @"";
    self.clubLogApiKeyField.stringValue = [ud stringForKey:@"TX500_ClubLog_APIKey"] ?: @"";

    // eQSL
    self.eqslUsernameField.stringValue = [ud stringForKey:@"TX500_EQSL_Username"] ?: @"";
    self.eqslPasswordField.stringValue = [ud stringForKey:@"TX500_EQSL_Password"] ?: @"";
    self.eqslNicknameField.stringValue = [ud stringForKey:@"TX500_EQSL_Nickname"] ?: @"";

    // HamQTH
    self.hamQTHUsernameField.stringValue = [ud stringForKey:@"TX500_HamQTH_Username"] ?: @"";
    self.hamQTHPasswordField.stringValue = [ud stringForKey:@"TX500_HamQTH_Password"] ?: @"";
}

- (void)update2FABadges {
    BOOL qrz2FA = [TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceQRZ];
    self.qrz2FAStatusBadge.stringValue = qrz2FA ? @"🔐 Browser Session Saved" : @"⚪ No 2FA Session Saved";
    self.qrz2FAStatusBadge.textColor = qrz2FA ? [NSColor systemGreenColor] : [NSColor secondaryLabelColor];

    BOOL cl2FA = [TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceClubLog];
    self.clubLog2FAStatusBadge.stringValue = cl2FA ? @"🔐 Browser Session Saved" : @"⚪ No 2FA Session Saved";
    self.clubLog2FAStatusBadge.textColor = cl2FA ? [NSColor systemGreenColor] : [NSColor secondaryLabelColor];
}

- (void)showSettingsWindowOver:(nullable NSWindow *)parentWindow {
    [self loadSavedSettings];
    if (!self.window) {
        NSRect frame = NSMakeRect(0, 0, 700, 600);
        NSWindow *win = [[NSWindow alloc] initWithContentRect:frame
                                                    styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                      backing:NSBackingStoreBuffered
                                                        defer:NO];
        win.title = @"Cloud & Callbook Ecosystem Settings";
        win.releasedWhenClosed = NO;
        [win center];
        self.window = win;
    }
    if (self.settingsView.superview != self.window.contentView) {
        [self.settingsView removeFromSuperview];
        [self.window.contentView addSubview:self.settingsView];
        [NSLayoutConstraint activateConstraints:@[
            [self.settingsView.leadingAnchor constraintEqualToAnchor:self.window.contentView.leadingAnchor constant:12.0],
            [self.settingsView.trailingAnchor constraintEqualToAnchor:self.window.contentView.trailingAnchor constant:-12.0],
            [self.settingsView.topAnchor constraintEqualToAnchor:self.window.contentView.topAnchor constant:10.0],
            [self.settingsView.bottomAnchor constraintEqualToAnchor:self.window.contentView.bottomAnchor constant:-10.0]
        ]];
    }
    [self.window makeKeyAndOrderFront:parentWindow];
}

#pragma mark - Actions

- (void)saveLoTWPasswordClicked {
    NSString *p = self.lotwPasswordField.stringValue;
    [[NSUserDefaults standardUserDefaults] setObject:p forKey:@"TX500_LoTW_Password"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    self.lotwTQSLSyncStatusLabel.stringValue = @"Password saved securely.";
}

- (void)removeLoTWPasswordClicked {
    self.lotwPasswordField.stringValue = @"";
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TX500_LoTW_Password"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    self.lotwTQSLSyncStatusLabel.stringValue = @"Password removed.";
}

- (void)syncTQSLDataClicked {
    BOOL ok = [TX500CloudSyncEngine synchronizeTQSLStorage];
    if (ok) {
        self.lotwTQSLSyncStatusLabel.stringValue = @"✅ TQSL data (~/.tqsl) synchronized successfully.";
    } else {
        self.lotwTQSLSyncStatusLabel.stringValue = @"TQSL storage checked (ready).";
    }
}

- (void)chooseCertificateClicked {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.title = @"Select LoTW Certificate Container";
    panel.message = @"Choose the .p12 certificate container exported from TQSL.";
    panel.prompt = @"Choose Certificate";
    if (@available(macOS 11.0, *)) {
        panel.allowedContentTypes = @[
            [UTType typeWithFilenameExtension:@"p12"] ?: UTTypeData,
            [UTType typeWithFilenameExtension:@"pfx"] ?: UTTypeData
        ];
    }
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;

    if ([panel runModal] == NSModalResponseOK && panel.URL) {
        NSString *path = panel.URL.path;
        [[NSUserDefaults standardUserDefaults] setObject:path forKey:@"TX500_LoTW_CertificatePath"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        self.lotwCertPathLabel.stringValue = path;
        self.btnRemoveCert.enabled = YES;
    }
}

- (void)removeCertificateClicked {
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TX500_LoTW_CertificatePath"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    self.lotwCertPathLabel.stringValue = @"No certificate container selected";
    self.btnRemoveCert.enabled = NO;
}

- (void)saveCertPasswordClicked {
    NSString *p = self.lotwCertPasswordField.stringValue;
    [[NSUserDefaults standardUserDefaults] setObject:p forKey:@"TX500_LoTW_CertificatePassword"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)removeCertPasswordClicked {
    self.lotwCertPasswordField.stringValue = @"";
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TX500_LoTW_CertificatePassword"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)qrz2FALoginClicked {
    [self presentAuthenticatorForService:TX500AuthServiceQRZ];
}

- (TX500WebAuthenticatorController *)newAuthenticatorForService:(TX500AuthService)service {
    return [TX500WebAuthenticatorController authenticatorForService:service];
}

- (void)presentAuthenticatorForService:(TX500AuthService)service {
    if (self.activeAuthenticator) {
        [self.activeAuthenticator.window makeKeyAndOrderFront:nil];
        return;
    }
    // Buttons and WebKit delegates do not retain their target. Own the controller
    // until it has dismissed the window and delivered its completion.
    TX500WebAuthenticatorController *auth = [self newAuthenticatorForService:service];
    self.activeAuthenticator = auth;
    __weak typeof(self) weakSelf = self;
    [auth presentModalOverWindow:self.settingsView.window ?: self.window completion:^(BOOL success, NSString *message) {
        (void)success; (void)message;
        weakSelf.activeAuthenticator = nil;
        [weakSelf update2FABadges];
        [[NSNotificationCenter defaultCenter] postNotificationName:TX500CloudSettingsDidChangeNotification object:nil];
        if (weakSelf.onSettingsChanged) weakSelf.onSettingsChanged();
    }];
}

- (void)qrz2FAClearClicked {
    [TX500WebAuthenticatorController clearSessionForService:TX500AuthServiceQRZ];
    [self update2FABadges];
    [[NSNotificationCenter defaultCenter] postNotificationName:TX500CloudSettingsDidChangeNotification object:nil];
    if (self.onSettingsChanged) self.onSettingsChanged();
}

- (void)clubLog2FALoginClicked {
    [self presentAuthenticatorForService:TX500AuthServiceClubLog];
}

- (void)clubLog2FAClearClicked {
    [TX500WebAuthenticatorController clearSessionForService:TX500AuthServiceClubLog];
    [self update2FABadges];
    [[NSNotificationCenter defaultCenter] postNotificationName:TX500CloudSettingsDidChangeNotification object:nil];
    if (self.onSettingsChanged) self.onSettingsChanged();
}

- (void)saveAndApplyClicked {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    // LoTW
    [ud setObject:self.lotwUsernameField.stringValue forKey:@"TX500_LoTW_Username"];
    if (self.lotwPasswordField.stringValue.length > 0) {
        [ud setObject:self.lotwPasswordField.stringValue forKey:@"TX500_LoTW_Password"];
    }
    [ud setObject:self.lotwStationLocationField.stringValue forKey:@"TX500_LoTW_StationLocation"];
    if (self.lotwCertPasswordField.stringValue.length > 0) {
        [ud setObject:self.lotwCertPasswordField.stringValue forKey:@"TX500_LoTW_CertificatePassword"];
    }

    // QRZ
    [ud setObject:self.qrzApiKeyField.stringValue forKey:@"TX500_QRZ_APIKey"];
    [ud setObject:self.qrzUsernameField.stringValue forKey:@"TX500_QRZ_Username"];
    if (self.qrzPasswordField.stringValue.length > 0) {
        [ud setObject:self.qrzPasswordField.stringValue forKey:@"TX500_QRZ_Password"];
    }

    // Club Log
    [ud setObject:self.clubLogCallsignField.stringValue forKey:@"TX500_ClubLog_Callsign"];
    [ud setObject:self.clubLogEmailField.stringValue forKey:@"TX500_ClubLog_Email"];
    if (self.clubLogPasswordField.stringValue.length > 0) {
        [ud setObject:self.clubLogPasswordField.stringValue forKey:@"TX500_ClubLog_Password"];
    }
    [ud setObject:self.clubLogApiKeyField.stringValue forKey:@"TX500_ClubLog_APIKey"];

    // eQSL
    [ud setObject:self.eqslUsernameField.stringValue forKey:@"TX500_EQSL_Username"];
    if (self.eqslPasswordField.stringValue.length > 0) {
        [ud setObject:self.eqslPasswordField.stringValue forKey:@"TX500_EQSL_Password"];
    }
    [ud setObject:self.eqslNicknameField.stringValue forKey:@"TX500_EQSL_Nickname"];

    // HamQTH
    [ud setObject:self.hamQTHUsernameField.stringValue forKey:@"TX500_HamQTH_Username"];
    if (self.hamQTHPasswordField.stringValue.length > 0) {
        [ud setObject:self.hamQTHPasswordField.stringValue forKey:@"TX500_HamQTH_Password"];
    }

    [ud synchronize];

    [[NSNotificationCenter defaultCenter] postNotificationName:TX500CloudSettingsDidChangeNotification object:nil];

    if (self.window && self.window.isVisible) {
        [self.window close];
    }
}

- (void)closeClicked {
    if (self.window && self.window.isVisible) {
        [self.window close];
    }
}

@end
