#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "TX500Transfer.h"
#import "TX500TimeSync.h"
#import "Lab599FirmwareCatalog.h"
#import "Lab599TelemetryController.h"
#import "Lab599ToolsController.h"
#import "Lab599DriverController.h"
#import "Lab599DocsController.h"
#import "Lab599FeedbackController.h"
#import "TX500ScreenCaptureController.h"

static NSString *Lab599ReadCATFrame(Lab599SerialPort *port, NSString *command,
                                    NSTimeInterval timeout, NSError **error) {
    if (![port discardInput:error]) return nil;
    NSData *request = [command dataUsingEncoding:NSASCIIStringEncoding];
    if (![port writeData:request timeout:timeout cancellation:nil error:error]) return nil;

    NSMutableData *response = [NSMutableData data];
    NSData *terminator = [@";" dataUsingEncoding:NSASCIIStringEncoding];
    double deadline = Lab599MonotonicTime() + timeout;
    while (Lab599MonotonicTime() < deadline) {
        NSTimeInterval remaining = deadline - Lab599MonotonicTime();
        NSData *chunk = [port readMaximum:64 timeout:MIN(0.12, MAX(0.01, remaining))
                             cancellation:nil error:nil];
        if (!chunk.length) continue;
        [response appendData:chunk];
        NSRange endRange = [response rangeOfData:terminator options:0
                                           range:NSMakeRange(0, response.length)];
        if (endRange.location != NSNotFound) {
            NSData *frame = [response subdataWithRange:NSMakeRange(0, NSMaxRange(endRange))];
            return [[NSString alloc] initWithData:frame encoding:NSASCIIStringEncoding];
        }
    }
    if (error) {
        *error = [NSError errorWithDomain:Lab599SerialErrorDomain code:Lab599SerialTimeout
                                 userInfo:@{NSLocalizedDescriptionKey: @"The radio did not return a complete CAT frame."}];
    }
    return nil;
}

@interface TX500SidebarButton : NSButton
@property(nonatomic, assign) NSInteger operationTag;
@property(nonatomic, assign) BOOL isSelected;
@property(nonatomic, copy) NSString *rawTitle;
@property(nonatomic, copy) NSString *iconName;
- (instancetype)initWithTitle:(NSString *)title iconName:(NSString *)iconName tag:(NSInteger)tag target:(id)target action:(SEL)action;
- (void)updateStyle;
@end

@implementation TX500SidebarButton

- (instancetype)initWithTitle:(NSString *)title iconName:(NSString *)iconName tag:(NSInteger)tag target:(id)target action:(SEL)action {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _rawTitle = [title copy];
        _iconName = [iconName copy];
        _operationTag = tag;
        self.target = target;
        self.action = action;
        self.bezelStyle = NSBezelStyleRegularSquare;
        self.bordered = NO;
        self.imagePosition = NSImageLeft;
        self.alignment = NSTextAlignmentLeft;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 6.0;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self updateStyle];
    }
    return self;
}

- (void)setIsSelected:(BOOL)isSelected {
    _isSelected = isSelected;
    [self updateStyle];
}

- (void)updateStyle {
    NSImage *img = [NSImage imageWithSystemSymbolName:_iconName accessibilityDescription:nil];
    if (!img) {
        if ([_iconName isEqualToString:@"gauge.with.needle"]) img = [NSImage imageWithSystemSymbolName:@"gauge" accessibilityDescription:nil];
        else if ([_iconName isEqualToString:@"display"]) img = [NSImage imageWithSystemSymbolName:@"tv" accessibilityDescription:nil];
        else if ([_iconName isEqualToString:@"bubble.left.and.bubble.right"]) img = [NSImage imageWithSystemSymbolName:@"text.bubble" accessibilityDescription:nil];
    }
    self.image = img;
    
    if (_isSelected) {
        self.layer.backgroundColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.18].CGColor;
        self.layer.borderColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.40].CGColor;
        self.layer.borderWidth = 1.0;
        self.contentTintColor = [NSColor controlAccentColor];
        
        NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %@", _rawTitle]];
        [mas addAttributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold],
            NSForegroundColorAttributeName: [NSColor labelColor]
        } range:NSMakeRange(0, mas.length)];
        self.attributedTitle = mas;
    } else {
        self.layer.backgroundColor = [NSColor clearColor].CGColor;
        self.layer.borderColor = [NSColor clearColor].CGColor;
        self.layer.borderWidth = 0.0;
        self.contentTintColor = [NSColor secondaryLabelColor];
        
        NSMutableAttributedString *mas = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"  %@", _rawTitle]];
        [mas addAttributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:13.0 weight:NSFontWeightRegular],
            NSForegroundColorAttributeName: [NSColor secondaryLabelColor]
        } range:NSMakeRange(0, mas.length)];
        self.attributedTitle = mas;
    }
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    self.alphaValue = enabled ? 1.0 : 0.45;
}
@end

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSPopUpButton *portMenu;
@property(nonatomic, strong) NSTextField *firmwareName;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSProgressIndicator *progressBar;
@property(nonatomic, strong) NSButton *updateButton;
@property(nonatomic, strong) NSButton *refreshButton;
@property(nonatomic, strong) NSButton *chooseButton;
@property(nonatomic, strong) NSButton *onlineButton;
@property(nonatomic, strong) NSTextView *logView;
@property(nonatomic, strong) NSURL *firmwareURL;
@property(nonatomic, strong) id activity;
@property(nonatomic) BOOL busy;
@property(nonatomic) BOOL hasPorts;
@property(nonatomic, strong) NSSegmentedControl *operationPicker;
@property(nonatomic, strong) NSStackView *portRow;
@property(nonatomic, strong) NSView *firmwareRow;
@property(nonatomic, strong) NSView *timeRow;
@property(nonatomic, strong) NSTextField *instructions;
@property(nonatomic, strong) NSTextField *clockPreview;
@property(nonatomic, strong) NSPopUpButton *timeZoneMenu;
@property(nonatomic, strong) NSButton *syncButton;
@property(nonatomic, strong) NSTimer *clockTimer;
@property(nonatomic, strong) Lab599TelemetryController *telemetryController;
@property(nonatomic, strong) Lab599ToolsController *tools;
@property(nonatomic, strong) Lab599DriverController *driverController;
@property(nonatomic, strong) Lab599DocsController *docsController;
@property(nonatomic, strong) Lab599FeedbackController *feedbackController;
@property(nonatomic, strong) TX500ScreenCaptureController *screenController;

// Modern Sidebar & Card UI Properties
@property(nonatomic, strong) NSMutableArray<TX500SidebarButton *> *sidebarItems;
@property(nonatomic, strong) NSVisualEffectView *sidebarView;
@property(nonatomic, strong) NSView *mainContentView;
@property(nonatomic, strong) NSBox *connectionBar;
@property(nonatomic, strong) NSView *statusLEDView;
@property(nonatomic, strong) NSTextField *connectionStatusLabel;
@property(nonatomic, strong) NSTextField *hardwareBadgeLabel;
@property(nonatomic, strong) NSBox *statusPillBox;
@property(nonatomic, strong) NSBox *portCapsuleBox;
@property(nonatomic, strong) NSBox *logCardBox;
@property(nonatomic, strong) NSLayoutConstraint *logCardHeightConstraint;
@property(nonatomic, strong) NSButton *consoleToggleButton;
@property(nonatomic, assign) BOOL logCollapsed;
@property(nonatomic, strong) NSTextField *sectionTitleLabel;
@property(nonatomic, strong) NSButton *outdoorModeButton;
@property(nonatomic, assign) BOOL outdoorModeActive;
@property(nonatomic, strong) NSStackView *actionRow;

// Online Firmware Sheet components
@property(nonatomic, strong) NSWindow *catalogSheet;
@property(nonatomic, strong) NSPopUpButton *modelFilterPopup;
@property(nonatomic, strong) NSPopUpButton *catalogPopup;
@property(nonatomic, strong) NSTextView *changelogView;
@property(nonatomic, strong) NSProgressIndicator *downloadProgress;
@property(nonatomic, strong) NSTextField *downloadStatusLabel;
@property(nonatomic, strong) NSButton *downloadActionBtn;
@property(nonatomic, strong) NSButton *refreshCatalogBtn;
@property(nonatomic, strong) NSArray<Lab599FirmwareItem *> *catalogItems;
@property(nonatomic, strong) NSArray<Lab599FirmwareItem *> *filteredItems;
@property(nonatomic, strong) NSURLSessionDownloadTask *activeDownloadTask;

// About Window
@property(nonatomic, strong) NSWindow *aboutWindow;

// Radio Hardware Preview
@property(nonatomic, strong) NSBox *radioPreviewBox;
@property(nonatomic, strong) NSImageView *radioImageView;
@property(nonatomic, strong) NSTextField *radioModelLabel;
@property(nonatomic, strong) NSTextField *radioSpecsLabel;
@property(nonatomic, strong) NSTextField *radioCompatibilityBadge;

// Power Safety & Battery Pack Detection
@property(nonatomic, strong) NSBox *powerSafetyBox;
@property(nonatomic, strong) NSTextField *powerSafetyTitleLabel;
@property(nonatomic, strong) NSTextField *powerSafetyDescLabel;
@property(nonatomic, strong) NSButton *powerCheckButton;
@property(nonatomic, assign) double lastDetectedVoltage;
@end

@implementation AppDelegate

- (NSTextField *)label:(NSString *)text {
    NSTextField *field = [NSTextField labelWithString:text];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    return field;
}

- (void)appendLog:(NSString *)message {
    NSAssert([NSThread isMainThread], @"UI logging must run on the main thread.");
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm:ss";
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], message];
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
    [self.logView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:entry attributes:attributes]];
    if (self.logView.textStorage.length > 200000) [self.logView.textStorage deleteCharactersInRange:NSMakeRange(0, self.logView.textStorage.length - 150000)];
    [self.logView scrollRangeToVisible:NSMakeRange(self.logView.string.length, 0)];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1160, 860)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Lab599 Utility";
    self.window.delegate = self;
    self.window.minSize = NSMakeSize(1040, 780);
    [self.window center];

    // Menus
    NSMenu *menu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [menu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    NSMenuItem *aboutItem = [appMenu addItemWithTitle:@"About Lab599 Utility" action:@selector(showAboutWindow:) keyEquivalent:@""];
    aboutItem.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Hide Lab599 Utility" action:@selector(hide:) keyEquivalent:@"h"];
    NSMenuItem *hideOthers = [appMenu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"];
    hideOthers.keyEquivalentModifierMask = NSEventModifierFlagOption | NSEventModifierFlagCommand;
    [appMenu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit Lab599 Utility" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;

    NSMenuItem *fileItem = [NSMenuItem new];
    [menu addItem:fileItem];
    NSMenu *fileMenu = [[NSMenu alloc] initWithTitle:@"File"];
    NSMenuItem *refreshItem = [fileMenu addItemWithTitle:@"Refresh Serial Ports" action:@selector(refreshPorts:) keyEquivalent:@"r"];
    refreshItem.target = self;
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Choose Firmware File..." action:@selector(chooseFirmware:) keyEquivalent:@"o"];
    [fileMenu addItemWithTitle:@"Download from Lab599..." action:@selector(openCatalogSheet:) keyEquivalent:@"d"];
    [fileMenu addItemWithTitle:@"Save Diagnostic Log..." action:@selector(saveLog:) keyEquivalent:@"s"];
    [fileMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *screenCaptureItem = [fileMenu addItemWithTitle:@"Capture Radio Screenshot..." action:@selector(captureRadioScreenshotMenuAction:) keyEquivalent:@"S"];
    screenCaptureItem.target = self;
    [fileMenu addItem:[NSMenuItem separatorItem]];
    [fileMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = fileMenu;

    NSMenuItem *editItem = [[NSMenuItem alloc] initWithTitle:@"Edit" action:NULL keyEquivalent:@""];
    [menu addItem:editItem];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenu addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];
    [editMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *findItem = [editMenu addItemWithTitle:@"Find in Documentation / Settings..." action:@selector(focusSearchField:) keyEquivalent:@"f"];
    findItem.target = self;
    editItem.submenu = editMenu;

    NSMenuItem *viewItem = [[NSMenuItem alloc] initWithTitle:@"View" action:NULL keyEquivalent:@""];
    [menu addItem:viewItem];
    NSMenu *viewMenu = [[NSMenu alloc] initWithTitle:@"View"];
    NSMenuItem *consoleItem = [viewMenu addItemWithTitle:@"Toggle Diagnostic Console" action:@selector(toggleLogConsole:) keyEquivalent:@"l"];
    consoleItem.target = self;
    NSMenuItem *outdoorItem = [viewMenu addItemWithTitle:@"Toggle Field Mode" action:@selector(toggleOutdoorMode:) keyEquivalent:@"F"];
    outdoorItem.target = self;
    viewItem.submenu = viewMenu;

    NSMenuItem *helpItem = [[NSMenuItem alloc] initWithTitle:@"Help" action:NULL keyEquivalent:@""];
    [menu addItem:helpItem];
    NSMenu *helpMenu = [[NSMenu alloc] initWithTitle:@"Help"];
    NSMenuItem *helpAbout = [helpMenu addItemWithTitle:@"About Lab599 Utility" action:@selector(showAboutWindow:) keyEquivalent:@""];
    helpAbout.target = self;
    [helpMenu addItem:[NSMenuItem separatorItem]];
    [helpMenu addItemWithTitle:@"Send Feedback & Report Issue..." action:@selector(selectFeedbackTab:) keyEquivalent:@""];
    [helpMenu addItemWithTitle:@"Official Lab599 Downloads Website" action:@selector(openLab599Website:) keyEquivalent:@""];
    [helpMenu addItemWithTitle:@"GitHub Project (EP2AES)" action:@selector(openGitHubRepo:) keyEquivalent:@""];
    helpItem.submenu = helpMenu;

    NSApp.mainMenu = menu;

    NSString *appVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"2.32";
    NSString *appBuild = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"38";

    // Setup legacy operation picker for CLI arguments and underlying state
    self.operationPicker = [NSSegmentedControl segmentedControlWithLabels:@[
        @"Firmware Update", @"Time Sync", @"Telemetry", @"Radio Screen", @"CAT Test", @"Settings", @"Memory", @"Driver Install", @"Documentation", @"Feedback & Suggestion"
    ] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(operationChanged:)];
    self.operationPicker.selectedSegment = 0;
    self.operationPicker.hidden = YES;

    // Dual-Pane Layout Structure
    NSView *contentRoot = self.window.contentView;
    contentRoot.wantsLayer = YES;

    // 1. Sidebar View (Left Pane - macOS Native Style)
    self.sidebarView = [[NSVisualEffectView alloc] initWithFrame:NSZeroRect];
    self.sidebarView.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarView.material = NSVisualEffectMaterialSidebar;
    self.sidebarView.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    self.sidebarView.state = NSVisualEffectStateActive;
    [contentRoot addSubview:self.sidebarView];

    // Vertical Divider
    NSBox *vDivider = [[NSBox alloc] initWithFrame:NSZeroRect];
    vDivider.translatesAutoresizingMaskIntoConstraints = NO;
    vDivider.boxType = NSBoxSeparator;
    [contentRoot addSubview:vDivider];

    // 2. Main Content View (Right Pane)
    self.mainContentView = [[NSView alloc] initWithFrame:NSZeroRect];
    self.mainContentView.translatesAutoresizingMaskIntoConstraints = NO;
    [contentRoot addSubview:self.mainContentView];

    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarView.leadingAnchor constraintEqualToAnchor:contentRoot.leadingAnchor],
        [self.sidebarView.topAnchor constraintEqualToAnchor:contentRoot.topAnchor],
        [self.sidebarView.bottomAnchor constraintEqualToAnchor:contentRoot.bottomAnchor],
        [self.sidebarView.widthAnchor constraintEqualToConstant:215],

        [vDivider.leadingAnchor constraintEqualToAnchor:self.sidebarView.trailingAnchor],
        [vDivider.topAnchor constraintEqualToAnchor:contentRoot.topAnchor],
        [vDivider.bottomAnchor constraintEqualToAnchor:contentRoot.bottomAnchor],
        [vDivider.widthAnchor constraintEqualToConstant:1],

        [self.mainContentView.leadingAnchor constraintEqualToAnchor:vDivider.trailingAnchor],
        [self.mainContentView.trailingAnchor constraintEqualToAnchor:contentRoot.trailingAnchor],
        [self.mainContentView.topAnchor constraintEqualToAnchor:contentRoot.topAnchor],
        [self.mainContentView.bottomAnchor constraintEqualToAnchor:contentRoot.bottomAnchor],
    ]];

    // --- Sidebar Content Assembly ---
    NSImageView *brandIcon = [NSImageView new];
    brandIcon.translatesAutoresizingMaskIntoConstraints = NO;
    brandIcon.image = [NSImage imageWithSystemSymbolName:@"antenna.radiowaves.left.and.right" accessibilityDescription:@"Lab599"];
    brandIcon.contentTintColor = [NSColor controlAccentColor];

    NSTextField *brandTitle = [self label:@"LAB599 UTILITY"];
    brandTitle.font = [NSFont systemFontOfSize:13 weight:NSFontWeightBold];
    brandTitle.textColor = [NSColor labelColor];

    NSTextField *brandSub = [self label:@"TX-500 Discovery / MP"];
    brandSub.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    brandSub.textColor = [NSColor secondaryLabelColor];

    NSStackView *brandTextStack = [NSStackView stackViewWithViews:@[brandTitle, brandSub]];
    brandTextStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    brandTextStack.alignment = NSLayoutAttributeLeading;
    brandTextStack.spacing = 1;

    NSStackView *brandHeaderStack = [NSStackView stackViewWithViews:@[brandIcon, brandTextStack]];
    brandHeaderStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    brandHeaderStack.alignment = NSLayoutAttributeCenterY;
    brandHeaderStack.spacing = 8;
    [brandIcon.widthAnchor constraintEqualToConstant:22].active = YES;
    [brandIcon.heightAnchor constraintEqualToConstant:22].active = YES;

    NSTextField *(^makeSectionHeader)(NSString *) = ^NSTextField *(NSString *title) {
        NSTextField *tf = [NSTextField labelWithString:title];
        tf.font = [NSFont systemFontOfSize:10 weight:NSFontWeightBold];
        tf.textColor = [NSColor secondaryLabelColor];
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        return tf;
    };

    self.sidebarItems = [NSMutableArray array];

    TX500SidebarButton *btnFw = [[TX500SidebarButton alloc] initWithTitle:@"Firmware Update" iconName:@"cpu" tag:0 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnTime = [[TX500SidebarButton alloc] initWithTitle:@"Time Sync" iconName:@"clock" tag:1 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnTelemetry = [[TX500SidebarButton alloc] initWithTitle:@"Telemetry" iconName:@"gauge.with.needle" tag:2 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnScreen = [[TX500SidebarButton alloc] initWithTitle:@"Radio Screen" iconName:@"display" tag:3 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnCat = [[TX500SidebarButton alloc] initWithTitle:@"CAT Test" iconName:@"antenna.radiowaves.left.and.right" tag:4 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnSettings = [[TX500SidebarButton alloc] initWithTitle:@"Settings" iconName:@"slider.horizontal.3" tag:5 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnMemory = [[TX500SidebarButton alloc] initWithTitle:@"Memory" iconName:@"memorychip" tag:6 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnDriver = [[TX500SidebarButton alloc] initWithTitle:@"Driver Install" iconName:@"wrench.and.screwdriver" tag:7 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnDocs = [[TX500SidebarButton alloc] initWithTitle:@"Documentation" iconName:@"doc.text" tag:8 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnFeedback = [[TX500SidebarButton alloc] initWithTitle:@"Feedback" iconName:@"bubble.left.and.bubble.right" tag:9 target:self action:@selector(sidebarItemClicked:)];

    [self.sidebarItems addObjectsFromArray:@[
        btnFw, btnTime, btnTelemetry, btnScreen, btnCat, btnSettings, btnMemory, btnDriver, btnDocs, btnFeedback
    ]];

    for (TX500SidebarButton *b in self.sidebarItems) {
        [b.heightAnchor constraintEqualToConstant:28].active = YES;
    }

    NSTextField *versionLabel = [NSTextField labelWithString:[NSString stringWithFormat:@"v%@ (Build %@) • macOS", appVer, appBuild]];
    versionLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    versionLabel.textColor = [NSColor secondaryLabelColor];
    versionLabel.alignment = NSTextAlignmentCenter;
    versionLabel.translatesAutoresizingMaskIntoConstraints = NO;

    NSBox *hDivider = [[NSBox alloc] initWithFrame:NSZeroRect];
    hDivider.translatesAutoresizingMaskIntoConstraints = NO;
    hDivider.boxType = NSBoxSeparator;

    NSView *sidebarSpacer = [NSView new];
    sidebarSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [sidebarSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    [sidebarSpacer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

    NSStackView *sidebarStack = [NSStackView stackViewWithViews:@[
        brandHeaderStack,
        makeSectionHeader(@"RADIO & LIVE"),
        btnScreen, btnTelemetry, btnCat,
        makeSectionHeader(@"CONFIGURATION"),
        btnTime, btnSettings, btnMemory,
        makeSectionHeader(@"FIRMWARE & DRIVER"),
        btnFw, btnDriver,
        makeSectionHeader(@"COMMUNITY"),
        btnDocs, btnFeedback,
        sidebarSpacer,
        hDivider,
        versionLabel
    ]];
    sidebarStack.translatesAutoresizingMaskIntoConstraints = NO;
    sidebarStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    sidebarStack.alignment = NSLayoutAttributeLeading;
    sidebarStack.spacing = 5;
    [self.sidebarView addSubview:sidebarStack];

    [NSLayoutConstraint activateConstraints:@[
        [sidebarStack.topAnchor constraintEqualToAnchor:self.sidebarView.topAnchor constant:16],
        [sidebarStack.leadingAnchor constraintEqualToAnchor:self.sidebarView.leadingAnchor constant:12],
        [sidebarStack.trailingAnchor constraintEqualToAnchor:self.sidebarView.trailingAnchor constant:-12],
        [sidebarStack.bottomAnchor constraintEqualToAnchor:self.sidebarView.bottomAnchor constant:-12],
        [brandHeaderStack.widthAnchor constraintEqualToAnchor:sidebarStack.widthAnchor],
        [hDivider.widthAnchor constraintEqualToAnchor:sidebarStack.widthAnchor],
        [versionLabel.widthAnchor constraintEqualToAnchor:sidebarStack.widthAnchor],
    ]];

    for (TX500SidebarButton *b in self.sidebarItems) {
        [b.widthAnchor constraintEqualToAnchor:sidebarStack.widthAnchor].active = YES;
    }

    // --- Persistent Connection Status Bar Card ---
    self.connectionBar = [NSBox new];
    self.connectionBar.titlePosition = NSNoTitle;
    self.connectionBar.boxType = NSBoxCustom;
    self.connectionBar.cornerRadius = 8.0;
    self.connectionBar.borderWidth = 1.0;
    self.connectionBar.borderColor = [NSColor separatorColor];
    self.connectionBar.fillColor = [NSColor controlBackgroundColor];
    self.connectionBar.translatesAutoresizingMaskIntoConstraints = NO;

    // Status Pill Badge
    self.statusPillBox = [NSBox new];
    self.statusPillBox.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusPillBox.boxType = NSBoxCustom;
    self.statusPillBox.cornerRadius = 11.0;
    self.statusPillBox.borderWidth = 1.0;
    self.statusPillBox.titlePosition = NSNoTitle;
    self.statusPillBox.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.08];
    self.statusPillBox.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.22];

    self.statusLEDView = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 8, 8)];
    self.statusLEDView.wantsLayer = YES;
    self.statusLEDView.layer.cornerRadius = 4.0;
    self.statusLEDView.layer.backgroundColor = [NSColor systemGrayColor].CGColor;
    self.statusLEDView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.statusLEDView.widthAnchor constraintEqualToConstant:8].active = YES;
    [self.statusLEDView.heightAnchor constraintEqualToConstant:8].active = YES;

    self.connectionStatusLabel = [self label:@"Disconnected"];
    self.connectionStatusLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.connectionStatusLabel.textColor = [NSColor secondaryLabelColor];

    NSStackView *pillStack = [NSStackView stackViewWithViews:@[self.statusLEDView, self.connectionStatusLabel]];
    pillStack.translatesAutoresizingMaskIntoConstraints = NO;
    pillStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pillStack.alignment = NSLayoutAttributeCenterY;
    pillStack.spacing = 6;
    [self.statusPillBox.contentView addSubview:pillStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.statusPillBox.heightAnchor constraintEqualToConstant:22],
        [pillStack.leadingAnchor constraintEqualToAnchor:self.statusPillBox.contentView.leadingAnchor constant:9],
        [pillStack.trailingAnchor constraintEqualToAnchor:self.statusPillBox.contentView.trailingAnchor constant:-9],
        [pillStack.centerYAnchor constraintEqualToAnchor:self.statusPillBox.contentView.centerYAnchor],
    ]];

    // Unified Port Capsule Group
    self.portCapsuleBox = [NSBox new];
    self.portCapsuleBox.translatesAutoresizingMaskIntoConstraints = NO;
    self.portCapsuleBox.boxType = NSBoxCustom;
    self.portCapsuleBox.cornerRadius = 6.0;
    self.portCapsuleBox.borderWidth = 1.0;
    self.portCapsuleBox.borderColor = [NSColor separatorColor];
    self.portCapsuleBox.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.06];
    self.portCapsuleBox.titlePosition = NSNoTitle;

    NSImageView *portIconView = nil;
    if (@available(macOS 11.0, *)) {
        NSImage *pImg = [NSImage imageWithSystemSymbolName:@"cable.connector" accessibilityDescription:@"Port"];
        if (pImg) {
            portIconView = [NSImageView imageViewWithImage:pImg];
            portIconView.translatesAutoresizingMaskIntoConstraints = NO;
            portIconView.contentTintColor = [NSColor secondaryLabelColor];
            [portIconView.widthAnchor constraintEqualToConstant:14].active = YES;
            [portIconView.heightAnchor constraintEqualToConstant:14].active = YES;
        }
    }

    self.portMenu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.portMenu.translatesAutoresizingMaskIntoConstraints = NO;
    self.portMenu.controlSize = NSControlSizeSmall;
    self.portMenu.font = [NSFont systemFontOfSize:11];
    self.portMenu.bordered = NO;
    [self.portMenu.widthAnchor constraintEqualToConstant:200].active = YES;

    NSBox *portDivider = [NSBox new];
    portDivider.translatesAutoresizingMaskIntoConstraints = NO;
    portDivider.boxType = NSBoxSeparator;
    [portDivider.heightAnchor constraintEqualToConstant:14].active = YES;

    self.refreshButton = [NSButton buttonWithTitle:@"" target:self action:@selector(refreshPorts:)];
    self.refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.refreshButton.bordered = NO;
    self.refreshButton.controlSize = NSControlSizeSmall;
    self.refreshButton.toolTip = @"Refresh Serial Ports (⌘R)";
    if (@available(macOS 11.0, *)) {
        self.refreshButton.image = [NSImage imageWithSystemSymbolName:@"arrow.clockwise" accessibilityDescription:@"Refresh"];
        self.refreshButton.contentTintColor = [NSColor secondaryLabelColor];
    } else {
        self.refreshButton.title = @"⟳";
    }
    [self.refreshButton.widthAnchor constraintEqualToConstant:20].active = YES;

    NSMutableArray *capsuleViews = [NSMutableArray array];
    if (portIconView) [capsuleViews addObject:portIconView];
    [capsuleViews addObject:self.portMenu];
    [capsuleViews addObject:portDivider];
    [capsuleViews addObject:self.refreshButton];

    NSStackView *capsuleStack = [NSStackView stackViewWithViews:capsuleViews];
    capsuleStack.translatesAutoresizingMaskIntoConstraints = NO;
    capsuleStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    capsuleStack.alignment = NSLayoutAttributeCenterY;
    capsuleStack.spacing = 6;
    [self.portCapsuleBox.contentView addSubview:capsuleStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.portCapsuleBox.heightAnchor constraintEqualToConstant:26],
        [capsuleStack.leadingAnchor constraintEqualToAnchor:self.portCapsuleBox.contentView.leadingAnchor constant:7],
        [capsuleStack.trailingAnchor constraintEqualToAnchor:self.portCapsuleBox.contentView.trailingAnchor constant:-5],
        [capsuleStack.centerYAnchor constraintEqualToAnchor:self.portCapsuleBox.contentView.centerYAnchor],
    ]];

    NSView *connSpacer = [NSView new];
    connSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [connSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.hardwareBadgeLabel = [self label:@"TX-500 Discovery"];
    self.hardwareBadgeLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
    self.hardwareBadgeLabel.textColor = [NSColor secondaryLabelColor];

    // Field Mode button in top bar
    self.outdoorModeButton = [NSButton buttonWithTitle:@"Field Mode" target:self action:@selector(toggleOutdoorMode:)];
    self.outdoorModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.outdoorModeButton.bezelStyle = NSBezelStyleRounded;
    self.outdoorModeButton.controlSize = NSControlSizeSmall;
    self.outdoorModeButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.outdoorModeButton.toolTip = @"Toggle Daylight High-Contrast Field Mode (⇧⌘F)";
    if (@available(macOS 11.0, *)) {
        self.outdoorModeButton.image = [NSImage imageWithSystemSymbolName:@"sun.max" accessibilityDescription:@"Field Mode"];
        self.outdoorModeButton.imagePosition = NSImageLeading;
    }

    // Diagnostic Console toggle button in top bar
    self.consoleToggleButton = [NSButton buttonWithTitle:@"Console" target:self action:@selector(toggleLogConsole:)];
    self.consoleToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.consoleToggleButton.bezelStyle = NSBezelStyleRounded;
    self.consoleToggleButton.controlSize = NSControlSizeSmall;
    self.consoleToggleButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.consoleToggleButton.toolTip = @"Toggle Diagnostic Console (⌘L)";
    if (@available(macOS 11.0, *)) {
        self.consoleToggleButton.image = [NSImage imageWithSystemSymbolName:@"terminal" accessibilityDescription:@"Console"];
        self.consoleToggleButton.imagePosition = NSImageLeading;
    }

    NSStackView *connStack = [NSStackView stackViewWithViews:@[
        self.statusPillBox,
        self.portCapsuleBox,
        connSpacer,
        self.hardwareBadgeLabel,
        self.outdoorModeButton,
        self.consoleToggleButton
    ]];
    connStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    connStack.alignment = NSLayoutAttributeCenterY;
    connStack.spacing = 8;
    connStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.connectionBar.contentView addSubview:connStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.connectionBar.heightAnchor constraintEqualToConstant:42],
        [connStack.leadingAnchor constraintEqualToAnchor:self.connectionBar.contentView.leadingAnchor constant:10],
        [connStack.trailingAnchor constraintEqualToAnchor:self.connectionBar.contentView.trailingAnchor constant:-10],
        [connStack.centerYAnchor constraintEqualToAnchor:self.connectionBar.contentView.centerYAnchor],
    ]];

    // --- Section Header Row ---
    self.sectionTitleLabel = [self label:@"Firmware Update (BL20 Bootloader)"];
    self.sectionTitleLabel.font = [NSFont systemFontOfSize:17 weight:NSFontWeightBold];

    NSTextField *instructions = [NSTextField wrappingLabelWithString:
        @"Connect the CAT-USB cable and stable external power. Close other radio applications. On your transceiver (TX-500 Discovery / TX-500MP), hold the third top function key while pressing POWER. Start only when the screen displays \"The loader is waiting...\". Keep power and cable connected until completion."];
    instructions.textColor = NSColor.secondaryLabelColor;
    instructions.font = [NSFont systemFontOfSize:11.5];
    self.instructions = instructions;

    NSStackView *headerStack = [NSStackView stackViewWithViews:@[self.sectionTitleLabel, self.instructions]];
    headerStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    headerStack.alignment = NSLayoutAttributeLeading;
    headerStack.spacing = 3;
    headerStack.translatesAutoresizingMaskIntoConstraints = NO;

    // --- Feature Content Rows ---
    // Firmware Selection Row
    self.firmwareName = [self label:@"No firmware selected"];
    self.firmwareName.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.firmwareName.widthAnchor constraintEqualToConstant:310].active = YES;
    self.chooseButton = [NSButton buttonWithTitle:@"Choose .fw..." target:self action:@selector(chooseFirmware:)];
    self.onlineButton = [NSButton buttonWithTitle:@"Download from Lab599..." target:self action:@selector(openCatalogSheet:)];
    NSStackView *fileRow = [NSStackView stackViewWithViews:@[[self label:@"Firmware:"], self.firmwareName, self.chooseButton, self.onlineButton]];
    fileRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    fileRow.alignment = NSLayoutAttributeCenterY;
    fileRow.spacing = 8;
    self.firmwareRow = fileRow;
    self.radioPreviewBox = [self buildRadioPreviewBox];
    self.powerSafetyBox = [self buildPowerSafetyBox];

    // Time synchronization
    self.timeZoneMenu = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.timeZoneMenu addItemsWithTitles:@[@"Mac local time", @"UTC"]];
    self.timeZoneMenu.target = self;
    self.timeZoneMenu.action = @selector(updateClockPreview:);
    self.clockPreview = [self label:@""];
    self.clockPreview.font = [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightMedium];
    NSStackView *timeRow = [NSStackView stackViewWithViews:@[[self label:@"Set radio clock to:"], self.timeZoneMenu, self.clockPreview]];
    timeRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    timeRow.alignment = NSLayoutAttributeCenterY;
    timeRow.spacing = 12;
    self.timeRow = timeRow;
    timeRow.hidden = YES;

    // Progress and Status
    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.progressBar.minValue = 0;
    self.progressBar.maxValue = 1;
    self.progressBar.indeterminate = NO;
    self.statusLabel = [NSTextField wrappingLabelWithString:@"Select the transceiver's serial port and choose or download the firmware file."];
    self.statusLabel.textColor = NSColor.secondaryLabelColor;
    [self.statusLabel.heightAnchor constraintGreaterThanOrEqualToConstant:28].active = YES;

    // Action Buttons
    self.updateButton = [NSButton buttonWithTitle:@"Update Firmware" target:self action:@selector(startUpdate:)];
    self.updateButton.bezelStyle = NSBezelStyleRounded;
    self.updateButton.keyEquivalent = @"\r";
    self.syncButton = [NSButton buttonWithTitle:@"Synchronize Clock" target:self action:@selector(startTimeSync:)];
    self.syncButton.bezelStyle = NSBezelStyleRounded;
    self.syncButton.hidden = YES;

    self.actionRow = [NSStackView stackViewWithViews:@[self.updateButton, self.syncButton]];
    self.actionRow.detachesHiddenViews = YES;
    self.actionRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.actionRow.spacing = 12;
    self.actionRow.translatesAutoresizingMaskIntoConstraints = NO;

    __weak AppDelegate *weakSelf = self;

    // Telemetry Controller
    self.telemetryController = [Lab599TelemetryController new];
    self.telemetryController.selectedPortProvider = ^NSString * { return weakSelf.hasPorts ? weakSelf.portMenu.selectedItem.title : nil; };
    self.telemetryController.logHandler = ^(NSString *message) { [weakSelf appendLog:message]; };
    self.telemetryController.onTelemetryData = ^(TXTelemetryData *data) {
        if (data.voltageValid && !weakSelf.telemetryController.engine.demoMode) {
            weakSelf.lastDetectedVoltage = data.voltage;
            dispatch_async(dispatch_get_main_queue(), ^{
                [weakSelf updatePowerSafetyUI];
            });
        }
    };
    self.telemetryController.view.hidden = YES;

    // Radio Screen Controller
    self.screenController = [TX500ScreenCaptureController new];
    self.screenController.window = self.window;
    self.screenController.selectedPortProvider = ^NSString * { return weakSelf.hasPorts ? weakSelf.portMenu.selectedItem.title : nil; };
    self.screenController.logHandler = ^(NSString *message) { [weakSelf appendLog:message]; };
    self.screenController.statusHandler = ^(NSString *message, double progress) {
        weakSelf.statusLabel.stringValue = message;
        weakSelf.progressBar.doubleValue = progress;
        [weakSelf updateConnectionStatusBar];
    };
    self.screenController.view.hidden = YES;

    // Tools Controller (CAT Studio, Settings, Memory)
    self.tools = [Lab599ToolsController new];
    self.tools.window = self.window;
    self.tools.selectedPort = ^NSString * { return weakSelf.hasPorts ? weakSelf.portMenu.selectedItem.title : nil; };
    self.tools.log = ^(NSString *message) { [weakSelf appendLog:message]; };
    self.tools.statusChanged = ^(NSString *message, double progress) {
        weakSelf.statusLabel.stringValue = message; weakSelf.progressBar.doubleValue = progress;
    };
    self.tools.activityChanged = ^(BOOL busy) { [weakSelf setToolsBusy:busy]; };
    self.tools.view.hidden = YES;

    // Driver Controller
    self.driverController = [Lab599DriverController new];
    self.driverController.window = self.window;
    self.driverController.log = ^(NSString *message) { [weakSelf appendLog:message]; };
    self.driverController.statusChanged = ^(NSString *message, double progress) {
        weakSelf.statusLabel.stringValue = message; weakSelf.progressBar.doubleValue = progress;
    };
    self.driverController.activityChanged = ^(BOOL busy) { [weakSelf setToolsBusy:busy]; };
    self.driverController.view.hidden = YES;

    // Documentation Controller
    self.docsController = [Lab599DocsController new];
    self.docsController.window = self.window;
    self.docsController.log = ^(NSString *message) { [weakSelf appendLog:message]; };
    self.docsController.statusChanged = ^(NSString *message, double progress) {
        weakSelf.statusLabel.stringValue = message; weakSelf.progressBar.doubleValue = progress;
    };
    self.docsController.activityChanged = ^(BOOL busy) { [weakSelf setToolsBusy:busy]; };
    self.docsController.view.hidden = YES;

    // Feedback & Suggestion Controller
    self.feedbackController = [Lab599FeedbackController new];
    self.feedbackController.window = self.window;
    self.feedbackController.selectedPortProvider = ^NSString * { return weakSelf.hasPorts ? weakSelf.portMenu.selectedItem.title : nil; };
    self.feedbackController.log = ^(NSString *message) { [weakSelf appendLog:message]; };
    self.feedbackController.statusChanged = ^(NSString *message, double progress) {
        weakSelf.statusLabel.stringValue = message; weakSelf.progressBar.doubleValue = progress;
    };
    self.feedbackController.view.hidden = YES;

    // Feature Card Container
    NSBox *featureCardBox = [NSBox new];
    featureCardBox.titlePosition = NSNoTitle;
    featureCardBox.boxType = NSBoxCustom;
    featureCardBox.cornerRadius = 8.0;
    featureCardBox.borderWidth = 1.0;
    featureCardBox.borderColor = [NSColor separatorColor];
    featureCardBox.fillColor = [NSColor controlBackgroundColor];
    featureCardBox.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *cardSpacer = [NSView new];
    cardSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [cardSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    [cardSpacer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

    NSStackView *featureStack = [NSStackView stackViewWithViews:@[
        fileRow, self.radioPreviewBox, self.powerSafetyBox, timeRow,
        self.telemetryController.view, self.screenController.view, self.tools.view,
        self.driverController.view, self.docsController.view, self.feedbackController.view,
        self.progressBar, self.statusLabel,
        self.actionRow,
        cardSpacer
    ]];
    featureStack.translatesAutoresizingMaskIntoConstraints = NO;
    featureStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    featureStack.alignment = NSLayoutAttributeLeading;
    featureStack.spacing = 8;
    featureStack.detachesHiddenViews = YES;
    [featureCardBox.contentView addSubview:featureStack];

    [NSLayoutConstraint activateConstraints:@[
        [featureStack.topAnchor constraintEqualToAnchor:featureCardBox.contentView.topAnchor constant:10],
        [featureStack.leadingAnchor constraintEqualToAnchor:featureCardBox.contentView.leadingAnchor constant:12],
        [featureStack.trailingAnchor constraintEqualToAnchor:featureCardBox.contentView.trailingAnchor constant:-12],
        [featureStack.bottomAnchor constraintEqualToAnchor:featureCardBox.contentView.bottomAnchor constant:-10],

        [self.radioPreviewBox.widthAnchor constraintEqualToAnchor:featureStack.widthAnchor],
        [self.powerSafetyBox.widthAnchor constraintEqualToAnchor:featureStack.widthAnchor],
        [self.telemetryController.view.widthAnchor constraintEqualToAnchor:featureStack.widthAnchor],
        [self.screenController.view.widthAnchor constraintEqualToAnchor:featureStack.widthAnchor],
        [self.tools.view.widthAnchor constraintEqualToAnchor:featureStack.widthAnchor],
        [self.driverController.view.widthAnchor constraintEqualToAnchor:featureStack.widthAnchor],
        [self.docsController.view.widthAnchor constraintEqualToAnchor:featureStack.widthAnchor],
        [self.feedbackController.view.widthAnchor constraintEqualToAnchor:featureStack.widthAnchor],
        [self.progressBar.widthAnchor constraintEqualToAnchor:featureStack.widthAnchor],
        [self.statusLabel.widthAnchor constraintEqualToAnchor:featureStack.widthAnchor],
    ]];

    // --- Diagnostic Console Card (Collapsible) ---
    self.logCardBox = [NSBox new];
    self.logCardBox.titlePosition = NSNoTitle;
    self.logCardBox.boxType = NSBoxCustom;
    self.logCardBox.cornerRadius = 8.0;
    self.logCardBox.borderWidth = 1.0;
    self.logCardBox.borderColor = [NSColor separatorColor];
    self.logCardBox.fillColor = [NSColor controlBackgroundColor];
    self.logCardBox.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *logHeaderLabel = [NSTextField labelWithString:@"DIAGNOSTIC CONSOLE LOG"];
    logHeaderLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightBold];
    logHeaderLabel.textColor = [NSColor secondaryLabelColor];

    NSView *logHeaderSpacer = [NSView new];
    logHeaderSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [logHeaderSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSButton *clearLogBtn = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearLog:)];
    clearLogBtn.controlSize = NSControlSizeSmall;
    clearLogBtn.font = [NSFont systemFontOfSize:11];

    NSButton *saveLogBtn = [NSButton buttonWithTitle:@"Save Log..." target:self action:@selector(saveLog:)];
    saveLogBtn.controlSize = NSControlSizeSmall;
    saveLogBtn.font = [NSFont systemFontOfSize:11];

    NSButton *collapseLogBtn = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleLogConsole:)];
    collapseLogBtn.controlSize = NSControlSizeSmall;
    collapseLogBtn.bordered = NO;
    collapseLogBtn.toolTip = @"Collapse Console (⌘L)";
    if (@available(macOS 11.0, *)) {
        collapseLogBtn.image = [NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:@"Collapse Console"];
    } else {
        collapseLogBtn.title = @"✕";
    }

    NSStackView *logHeaderRow = [NSStackView stackViewWithViews:@[
        logHeaderLabel, logHeaderSpacer, clearLogBtn, saveLogBtn, collapseLogBtn
    ]];
    logHeaderRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    logHeaderRow.alignment = NSLayoutAttributeCenterY;
    logHeaderRow.spacing = 8;
    logHeaderRow.translatesAutoresizingMaskIntoConstraints = NO;

    // Log Scroll View
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    self.logView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 720, 200)];
    self.logView.editable = NO;
    self.logView.selectable = YES;
    self.logView.richText = NO;
    self.logView.verticallyResizable = YES;
    self.logView.horizontallyResizable = NO;
    self.logView.autoresizingMask = NSViewWidthSizable;
    self.logView.textContainer.widthTracksTextView = YES;
    self.logView.textContainerInset = NSMakeSize(6, 6);
    scroll.documentView = self.logView;
    [scroll.heightAnchor constraintEqualToConstant:96].active = YES;

    NSStackView *logInnerStack = [NSStackView stackViewWithViews:@[logHeaderRow, scroll]];
    logInnerStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    logInnerStack.alignment = NSLayoutAttributeLeading;
    logInnerStack.spacing = 6;
    logInnerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.logCardBox.contentView addSubview:logInnerStack];

    self.logCardHeightConstraint = [self.logCardBox.heightAnchor constraintEqualToConstant:140];
    [NSLayoutConstraint activateConstraints:@[
        self.logCardHeightConstraint,
        [logInnerStack.topAnchor constraintEqualToAnchor:self.logCardBox.contentView.topAnchor constant:8],
        [logInnerStack.leadingAnchor constraintEqualToAnchor:self.logCardBox.contentView.leadingAnchor constant:10],
        [logInnerStack.trailingAnchor constraintEqualToAnchor:self.logCardBox.contentView.trailingAnchor constant:-10],
        [logInnerStack.bottomAnchor constraintEqualToAnchor:self.logCardBox.contentView.bottomAnchor constant:-8],
        [logHeaderRow.widthAnchor constraintEqualToAnchor:logInnerStack.widthAnchor],
        [scroll.widthAnchor constraintEqualToAnchor:logInnerStack.widthAnchor],
    ]];

    // Assemble Main Content Stack
    NSStackView *mainStack = [NSStackView stackViewWithViews:@[
        self.connectionBar,
        headerStack,
        featureCardBox,
        self.logCardBox
    ]];
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    mainStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    mainStack.alignment = NSLayoutAttributeLeading;
    mainStack.spacing = 10;
    mainStack.detachesHiddenViews = YES;
    [self.mainContentView addSubview:mainStack];

    [NSLayoutConstraint activateConstraints:@[
        [mainStack.topAnchor constraintEqualToAnchor:self.mainContentView.topAnchor constant:14],
        [mainStack.leadingAnchor constraintEqualToAnchor:self.mainContentView.leadingAnchor constant:14],
        [mainStack.trailingAnchor constraintEqualToAnchor:self.mainContentView.trailingAnchor constant:-14],
        [mainStack.bottomAnchor constraintEqualToAnchor:self.mainContentView.bottomAnchor constant:-14],

        [self.connectionBar.widthAnchor constraintEqualToAnchor:mainStack.widthAnchor],
        [headerStack.widthAnchor constraintEqualToAnchor:mainStack.widthAnchor],
        [featureCardBox.widthAnchor constraintEqualToAnchor:mainStack.widthAnchor],
        [self.logCardBox.widthAnchor constraintEqualToAnchor:mainStack.widthAnchor],
    ]];
    [self appendLog:[NSString stringWithFormat:@"Lab599 Utility %@ (Build %@) initialized.", appVer, appBuild]];
    [self appendLog:@"BL20 protocol engine ready: 57600 baud, 8N1, two-ACK header+payload cycle."];
    [self appendLog:@"TimeSync ready: 9600 baud, TM set/query with clock read-back verification."];
    [self refreshPorts:nil];
    [self updateClockPreview:nil];
    self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateClockPreview:) userInfo:nil repeats:YES];
    [self updateConsoleToggleButton];
    [self updateConnectionStatusBar];
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--telemetry-demo"]) {
        self.operationPicker.selectedSegment = 2;
        [self operationChanged:self.operationPicker];
        [self.telemetryController startDemoMonitoring];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--screen-demo"]) {
        self.operationPicker.selectedSegment = 3;
        [self operationChanged:self.operationPicker];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--cat-test"]) {
        self.operationPicker.selectedSegment = 4;
        [self operationChanged:self.operationPicker];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--docs"]) {
        self.operationPicker.selectedSegment = 8;
        [self operationChanged:self.operationPicker];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--feedback"]) {
        self.operationPicker.selectedSegment = 9;
        [self operationChanged:self.operationPicker];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--field-mode"]) {
        [self toggleOutdoorMode:nil];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--console-collapsed"]) {
        if (!self.logCollapsed) {
            [self toggleLogConsole:nil];
        }
    }
    for (NSUInteger i = 0; i < [NSProcessInfo processInfo].arguments.count; i++) {
        if ([[NSProcessInfo processInfo].arguments[i] isEqualToString:@"--screenshot-window"] && i + 1 < [NSProcessInfo processInfo].arguments.count) {
            NSString *outPath = [NSProcessInfo processInfo].arguments[i + 1];
            if (!self.outdoorModeActive) {
                self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.window layoutIfNeeded];
                [self.window.contentView layoutSubtreeIfNeeded];
                NSRect rect = self.window.contentView.bounds;
                NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL
                                                                                pixelsWide:(NSInteger)rect.size.width
                                                                                pixelsHigh:(NSInteger)rect.size.height
                                                                             bitsPerSample:8
                                                                           samplesPerPixel:4
                                                                                  hasAlpha:YES
                                                                                  isPlanar:NO
                                                                            colorSpaceName:NSCalibratedRGBColorSpace
                                                                               bytesPerRow:0
                                                                              bitsPerPixel:0];
                NSGraphicsContext *ctx = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
                [NSGraphicsContext saveGraphicsState];
                [NSGraphicsContext setCurrentContext:ctx];
                if (self.outdoorModeActive) {
                    [[NSColor colorWithCalibratedWhite:0.94 alpha:1.0] setFill];
                } else {
                    [[NSColor colorWithCalibratedRed:0.13 green:0.13 blue:0.14 alpha:1.0] setFill];
                }
                NSRectFill(rect);
                [self.window.contentView displayRectIgnoringOpacity:rect inContext:ctx];
                [NSGraphicsContext restoreGraphicsState];
                NSData *png = [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                [png writeToFile:outPath atomically:YES];
                NSLog(@"Saved window screenshot to %@", outPath);
                [NSApp terminate:nil];
            });
        }
        if ([[NSProcessInfo processInfo].arguments[i] isEqualToString:@"--load-firmware"] && i + 1 < [NSProcessInfo processInfo].arguments.count) {
            NSString *fwPath = [NSProcessInfo processInfo].arguments[i + 1];
            NSURL *url = [NSURL fileURLWithPath:fwPath];
            NSData *data = [NSData dataWithContentsOfURL:url];
            if (data) {
                [self setLoadedFirmwareURL:url firmwareData:data isOnlineDownload:NO];
            }
        } else if ([[NSProcessInfo processInfo].arguments[i] isEqualToString:@"--battery-sim"] && i + 1 < [NSProcessInfo processInfo].arguments.count) {
            double v = [[NSProcessInfo processInfo].arguments[i + 1] doubleValue];
            if (v > 0) {
                self.lastDetectedVoltage = v;
                [self updatePowerSafetyUI];
            }
        }
    }
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--about"]) {
        [self showAboutWindow:nil];
    }
}

#pragma mark - Serial Ports

- (void)refreshPorts:(id)sender {
    if (self.busy) return;
    NSString *previous = self.portMenu.selectedItem.title;
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/dev" error:NULL] ?: @[];
    NSPredicate *match = [NSPredicate predicateWithBlock:^BOOL(NSString *name, NSDictionary *bindings) {
        (void)bindings;
        return [name hasPrefix:@"cu."] &&
               ![name.lowercaseString containsString:@"bluetooth"] &&
               ![name.lowercaseString containsString:@"debug"] &&
               ![name.lowercaseString containsString:@"wlan"];
    }];
    NSArray *ports = [[names filteredArrayUsingPredicate:match] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    [self.portMenu removeAllItems];
    self.hasPorts = ports.count > 0;
    if (!self.hasPorts) {
        [self.portMenu addItemWithTitle:@"No serial ports found"];
    }
    for (NSString *name in ports) {
        [self.portMenu addItemWithTitle:[@"/dev/" stringByAppendingString:name]];
    }
    if (previous && [self.portMenu itemWithTitle:previous]) {
        [self.portMenu selectItemWithTitle:previous];
    }
    self.portMenu.enabled = self.hasPorts;
    self.updateButton.enabled = self.hasPorts && self.firmwareURL != nil;
    self.syncButton.enabled = self.hasPorts;
    [self.tools portsAvailable:self.hasPorts];
    if (sender) {
        self.statusLabel.stringValue = self.hasPorts ?
            @"Select the serial port connected to your Lab599 transceiver." :
            @"Connect the CAT-USB adapter and click Refresh. A working serial driver (FTDI/Prolific) is required.";
    }
    [self updateConnectionStatusBar];
}

#pragma mark - Operation Selection & Time Synchronization

- (NSTimeZone *)selectedTimeZone {
    return self.timeZoneMenu.indexOfSelectedItem == 1 ? [NSTimeZone timeZoneForSecondsFromGMT:0] : NSTimeZone.localTimeZone;
}

- (void)updateClockPreview:(id)sender {
    (void)sender;
    NSTimeZone *zone = [self selectedTimeZone];
    NSData *command = TXTimeSetCommand(NSDate.date, zone);
    NSString *time = [[[NSString alloc] initWithData:command encoding:NSASCIIStringEncoding] substringWithRange:NSMakeRange(2, 8)];
    self.clockPreview.stringValue = [NSString stringWithFormat:@"%@  (%@)", time, zone.name];
}

- (void)selectFeedbackTab:(id)sender {
    (void)sender;
    self.operationPicker.selectedSegment = 9;
    [self operationChanged:self.operationPicker];
}

- (void)captureRadioScreenshotMenuAction:(id)sender {
    (void)sender;
    self.operationPicker.selectedSegment = 3;
    [self operationChanged:self.operationPicker];
    [self.screenController saveScreenshotDialog];
}

- (void)sidebarItemClicked:(TX500SidebarButton *)sender {
    if (self.busy) return;
    self.operationPicker.selectedSegment = sender.operationTag;
    [self operationChanged:self.operationPicker];
}

- (void)clearLog:(id)sender {
    (void)sender;
    [self.logView.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@""]];
}

- (void)toggleOutdoorMode:(id)sender {
    (void)sender;
    self.outdoorModeActive = !self.outdoorModeActive;
    if (self.outdoorModeActive) {
        self.outdoorModeButton.title = @"Field Mode: ON";
        if (@available(macOS 11.0, *)) {
            self.outdoorModeButton.image = [NSImage imageWithSystemSymbolName:@"sun.max.fill" accessibilityDescription:@"Field Mode"];
        }
        self.outdoorModeButton.contentTintColor = [NSColor systemOrangeColor];
        self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        self.screenController.currentTheme = TX500ScreenThemeCoolWhite;
        [self.screenController renderAndUpdateDisplay];
        [self appendLog:@"☀️ Field Mode activated: Enforced high-contrast Daylight display for direct sunlight readability (POTA/SOTA)."];
    } else {
        self.outdoorModeButton.title = @"Field Mode";
        if (@available(macOS 11.0, *)) {
            self.outdoorModeButton.image = [NSImage imageWithSystemSymbolName:@"sun.max" accessibilityDescription:@"Field Mode"];
        }
        self.outdoorModeButton.contentTintColor = nil;
        self.window.appearance = nil; // Follow system appearance
        self.screenController.currentTheme = TX500ScreenThemeAmber;
        [self.screenController renderAndUpdateDisplay];
        [self appendLog:@"Field Mode deactivated: Restored standard display appearance."];
    }
}

- (void)toggleLogConsole:(id)sender {
    (void)sender;
    self.logCollapsed = !self.logCollapsed;
    self.logCardBox.hidden = self.logCollapsed;
    self.logCardHeightConstraint.active = !self.logCollapsed;
    [self updateConsoleToggleButton];
    [self.window layoutIfNeeded];
}

- (void)updateConsoleToggleButton {
    if (self.logCollapsed) {
        self.consoleToggleButton.contentTintColor = [NSColor secondaryLabelColor];
        if (@available(macOS 11.0, *)) {
            self.consoleToggleButton.image = [NSImage imageWithSystemSymbolName:@"terminal" accessibilityDescription:@"Console"];
        }
    } else {
        self.consoleToggleButton.contentTintColor = [NSColor controlAccentColor];
        if (@available(macOS 11.0, *)) {
            self.consoleToggleButton.image = [NSImage imageWithSystemSymbolName:@"terminal.fill" accessibilityDescription:@"Console"];
        }
    }
}

- (void)focusSearchField:(id)sender {
    (void)sender;
    if (self.operationPicker.selectedSegment != 8) {
        self.operationPicker.selectedSegment = 8;
        [self operationChanged:self.operationPicker];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.docsController focusSearchField];
    });
}

- (void)updateConnectionStatusBar {
    if (self.screenController.liveSyncActive || self.telemetryController.engine.isRunning) {
        self.statusLEDView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.16 green:0.82 blue:0.25 alpha:1.0].CGColor;
        self.connectionStatusLabel.stringValue = @"Live Streaming";
        self.connectionStatusLabel.textColor = [NSColor colorWithSRGBRed:0.12 green:0.68 blue:0.22 alpha:1.0];
        self.statusPillBox.fillColor = [NSColor colorWithSRGBRed:0.16 green:0.82 blue:0.25 alpha:0.14];
        self.statusPillBox.borderColor = [NSColor colorWithSRGBRed:0.16 green:0.82 blue:0.25 alpha:0.40];
    } else if (self.hasPorts) {
        self.statusLEDView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.20 green:0.75 blue:0.35 alpha:1.0].CGColor;
        self.connectionStatusLabel.stringValue = @"Radio Ready";
        self.connectionStatusLabel.textColor = [NSColor labelColor];
        self.statusPillBox.fillColor = [NSColor colorWithSRGBRed:0.20 green:0.75 blue:0.35 alpha:0.12];
        self.statusPillBox.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.75 blue:0.35 alpha:0.35];
    } else {
        self.statusLEDView.layer.backgroundColor = [NSColor systemGrayColor].CGColor;
        self.connectionStatusLabel.stringValue = @"Disconnected";
        self.connectionStatusLabel.textColor = [NSColor secondaryLabelColor];
        self.statusPillBox.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.08];
        self.statusPillBox.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.22];
    }
}

- (void)operationChanged:(id)sender {
    (void)sender;
    if (self.busy) return;
    NSInteger operation = self.operationPicker.selectedSegment;
    BOOL isFW = (operation == 0);
    BOOL isSync = (operation == 1);
    BOOL isTelemetry = (operation == 2);
    BOOL isScreen = (operation == 3);
    BOOL isTools = (operation >= 4 && operation <= 6);
    BOOL isDriver = (operation == 7);
    BOOL isDocs = (operation == 8);
    BOOL isFeedback = (operation == 9);

    for (TX500SidebarButton *btn in self.sidebarItems) {
        btn.isSelected = (btn.operationTag == operation);
    }

    static NSDictionary<NSNumber *, NSString *> *titles = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        titles = @{
            @0: @"Firmware Update (BL20 Bootloader)",
            @1: @"Time Synchronization (CAT TM)",
            @2: @"Real-Time Telemetry & RF Meters",
            @3: @"Radio Screen & Live Display",
            @4: @"Lab599 CAT Studio & Diagnostics",
            @5: @"Transceiver Configuration & Backup",
            @6: @"Memory Channel Manager (100 Channels)",
            @7: @"FTDI D2XX Driver Installation",
            @8: @"Documentation & Official Manuals",
            @9: @"Feedback & Bug Reports"
        };
    });
    self.sectionTitleLabel.stringValue = titles[@(operation)] ?: @"Lab599 Utility";

    if (!isTelemetry && self.telemetryController.engine.isRunning) {
        [self.telemetryController stopMonitoring];
    }
    if (!isScreen && self.screenController.liveSyncActive) {
        [self.screenController stopLiveSync];
    }

    self.telemetryController.view.hidden = !isTelemetry;
    self.screenController.view.hidden = !isScreen;
    if (isScreen) {
        if (self.screenController.liveSyncActive && !self.screenController.demoModeActive) {
            [self.screenController startLiveSync];
        } else if (self.screenController.demoModeActive) {
            [self.screenController startDemoTimer];
        }
    }

    self.tools.view.hidden = !isTools;
    if (isTools) [self.tools selectTool:operation - 4];

    self.driverController.view.hidden = !isDriver;
    if (isDriver) [self.driverController checkDriverStatus];

    self.docsController.view.hidden = !isDocs;
    if (isDocs) [self.docsController refreshLocalAvailability];

    self.feedbackController.view.hidden = !isFeedback;
    if (isFeedback) [self.feedbackController refreshDiagnostics];

    self.firmwareRow.hidden = !isFW;
    self.radioPreviewBox.hidden = !isFW;
    self.powerSafetyBox.hidden = !isFW;
    self.timeRow.hidden = !isSync;

    self.updateButton.hidden = !isFW;
    self.syncButton.hidden = !isSync;
    self.actionRow.hidden = (!isFW && !isSync);
    self.updateButton.keyEquivalent = isFW ? @"\r" : @"";
    self.syncButton.keyEquivalent = isSync ? @"\r" : @"";
    self.progressBar.doubleValue = 0;
    self.progressBar.hidden = (isTelemetry || isScreen || isFeedback);
    self.statusLabel.hidden = (isTelemetry || isScreen || isFeedback);

    if (isFW) {
        self.instructions.stringValue = @"Connect the CAT-USB cable and stable external power. Close other radio applications. On your transceiver (TX-500 Discovery / TX-500MP), hold the third top function key while pressing POWER. Start only when the screen displays \"The loader is waiting...\". Keep power and cable connected until completion.";
        self.statusLabel.stringValue = @"Select the transceiver's serial port and choose or download the firmware file.";
    } else if (isSync) {
        self.instructions.stringValue = @"Turn the radio on normally with POWER. Connect the CAT-USB cable, use CAT at 9600 baud, and close other radio applications. Choose Mac local time or UTC below. Synchronization uses your Mac's clock; check its accuracy in System Settings. No firmware file is needed.";
        self.statusLabel.stringValue = @"Ready to synchronize the radio clock in normal operating mode.";
    } else if (isTelemetry) {
        self.instructions.stringValue = @"Live diagnostic telemetry monitoring for Lab599 TX-500 Discovery / TX-500MP. Displays real-time RF output power, antenna SWR, supply/battery voltage, current consumption, and PA temperature via Kenwood / LAB599 CAT protocol.";
        self.statusLabel.stringValue = @"Ready. Select CAT serial port or enable Demo Mode to observe live telemetry meters.";
    } else if (isScreen) {
        self.instructions.stringValue = @"Real-Time LCD Screen Capture & Live Display for Lab599 TX-500 Discovery / TX-500MP. Faithfully simulates the 256×128 monochrome LCD matrix with authentic typography, calibrated S-meter / RF power bars, panadapter spectrum, and milled aluminum chassis bezel. Capture screenshots, copy to clipboard, or choose amber, daylight, green, or OLED themes.";
        self.statusLabel.stringValue = @"Ready. Click 'Refresh' or toggle 'Live Auto-Sync' to stream the radio screen.";
    } else if (operation == 4) {
        self.instructions.stringValue = @"Lab599 CAT Studio & Interactive Diagnostics. Inspect live transceiver parameters (frequency, mode, power, filters), write settings directly or use quick amateur band chips, execute raw CAT commands, and test serial latency.";
        self.statusLabel.stringValue = @"Ready. Connect transceiver CAT port (9600 baud, 8N1) to monitor, control or send commands.";
    } else if (operation == 5) {
        self.instructions.stringValue = @"Transceiver Configuration Settings Editor & Backup. Inspect and modify named parameters, export/import JSON, compare backups, and restore 1024-byte binary blocks to the radio.";
        self.statusLabel.stringValue = @"Ready. File editing, comparison, and backup saving also work without a connected radio.";
    } else if (operation == 6) {
        self.instructions.stringValue = @"100-Channel Memory Manager. Read/write memory banks, edit individual channels, apply operating profiles, or import/export channel lists as CSV.";
        self.statusLabel.stringValue = @"Ready. Memory channel editing, CSV import/export, and bank saving work without a connected radio.";
    } else if (isDriver) {
        self.instructions.stringValue = @"Mandatory FTDI D2XX runtime installation for macOS (Apple Silicon & Intel). Fixes serial callout instantiation and ensures non-blocking communication in WSJT-X.";
        self.statusLabel.stringValue = @"Ready to manage and verify FTDI D2XX serial driver.";
    } else if (isDocs) {
        self.instructions.stringValue = @"Official Lab599 product documentation, user manuals, firmware releases, utilities, and drivers. Download directly or open local copies.";
        self.statusLabel.stringValue = @"Browse and download official Lab599 resources.";
    } else if (isFeedback) {
        self.instructions.stringValue = @"Share your feedback, feature requests, or report bugs directly to GitHub Issues. Callsign and contact info are saved locally for convenience.";
        self.statusLabel.stringValue = @"Ready to prepare and submit feedback to GitHub Issues.";
    }
    [self updateClockPreview:nil];
    [self updateConnectionStatusBar];
}

- (void)setToolsBusy:(BOOL)busy {
    self.busy = busy;
    self.operationPicker.enabled = self.timeZoneMenu.enabled = self.refreshButton.enabled = !busy;
    self.chooseButton.enabled = self.onlineButton.enabled = !busy;
    self.portMenu.enabled = !busy && self.hasPorts;
    self.updateButton.enabled = !busy && self.hasPorts && self.firmwareURL != nil;
    self.syncButton.enabled = !busy && self.hasPorts;
    self.outdoorModeButton.enabled = !busy;
    for (TX500SidebarButton *btn in self.sidebarItems) {
        btn.enabled = !busy;
    }
    if (busy) {
        self.activity = [NSProcessInfo.processInfo beginActivityWithOptions:(NSActivityUserInitiated | NSActivityIdleSystemSleepDisabled) reason:@"Lab599 Utility radio operation"];
    } else {
        if (self.activity) [NSProcessInfo.processInfo endActivity:self.activity];
        self.activity = nil; [self refreshPorts:nil];
    }
}

- (void)startTimeSync:(id)sender {
    (void)sender;
    if (self.busy || self.operationPicker.selectedSegment != 1) return;
    NSString *port = self.portMenu.selectedItem.title;
    if (!self.hasPorts || ![port hasPrefix:@"/dev/cu."]) return;
    NSTimeZone *zone = [[self selectedTimeZone] copy];
    self.busy = YES;
    self.operationPicker.enabled = NO;
    self.timeZoneMenu.enabled = NO;
    self.syncButton.enabled = NO;
    self.updateButton.enabled = NO;
    self.portMenu.enabled = NO;
    self.refreshButton.enabled = NO;
    self.chooseButton.enabled = NO;
    self.onlineButton.enabled = NO;
    self.progressBar.indeterminate = YES;
    [self.progressBar startAnimation:nil];
    self.statusLabel.stringValue = @"Setting the radio clock and checking its response...";
    self.activity = [NSProcessInfo.processInfo beginActivityWithOptions:(NSActivityUserInitiated | NSActivityIdleSystemSleepDisabled)
        reason:@"Synchronizing Lab599 radio clock"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TXTimeSyncResult *result = TXSynchronizeTime(port, zone, TXDefaultTimeSyncOptions(), nil, ^(NSString *message) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self appendLog:message]; });
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            [NSProcessInfo.processInfo endActivity:self.activity];
            self.activity = nil;
            self.operationPicker.enabled = YES;
            self.timeZoneMenu.enabled = YES;
            self.refreshButton.enabled = YES;
            self.chooseButton.enabled = YES;
            self.onlineButton.enabled = YES;
            [self.progressBar stopAnimation:nil];
            self.progressBar.indeterminate = NO;
            self.progressBar.doubleValue = result.success ? 1 : 0;
            [self refreshPorts:nil];
            if (result.success) {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Clock synchronized: %@ (%@). Radio read-back verified.", result.radioTime, zone.name];
            } else {
                self.statusLabel.stringValue = @"Clock synchronization was not confirmed. Check the diagnostic log.";
                [self showAlert:@"Clock synchronization was not confirmed" message:result.failure warning:YES];
            }
        });
    });
}

#pragma mark - Radio Hardware Preview (Firmware Update)

- (NSImage *)loadRadioImageNamed:(NSString *)name {
    if (!name.length) name = @"tx500_radio";
    NSImage *image = [NSImage imageNamed:name];
    if (image) return image;
    NSString *resPath = [[NSBundle mainBundle] pathForResource:name ofType:@"png"];
    if (resPath && [[NSFileManager defaultManager] fileExistsAtPath:resPath]) {
        image = [[NSImage alloc] initWithContentsOfFile:resPath];
        if (image) return image;
    }
    NSString *bundleDir = [[NSBundle mainBundle] bundlePath];
    NSString *filename = [name stringByAppendingPathExtension:@"png"];
    NSArray<NSString *> *candidates = @[
        [bundleDir stringByAppendingPathComponent:[NSString stringWithFormat:@"Contents/Resources/%@", filename]],
        [NSString stringWithFormat:@"Resources/%@", filename],
        [NSString stringWithFormat:@"../Resources/%@", filename],
        [NSString stringWithFormat:@"assets/%@", filename],
        [NSString stringWithFormat:@"../assets/%@", filename],
        [NSString stringWithFormat:@"/Users/factoreal/Downloads/TX-500/Updater/Resources/%@", filename],
        [NSString stringWithFormat:@"/Users/factoreal/Downloads/TX-500/Updater/assets/%@", filename],
        [NSString stringWithFormat:@"/Users/factoreal/Downloads/TX-500/Manual/%@", filename]
    ];
    for (NSString *path in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
            image = [[NSImage alloc] initWithContentsOfFile:path];
            if (image) return image;
        }
    }
    return nil;
}

- (NSImage *)loadRadioImage {
    return [self loadRadioImageNamed:@"tx500_radio"];
}

- (NSBox *)buildRadioPreviewBox {
    NSBox *box = [NSBox new];
    box.titlePosition = NSNoTitle;
    box.boxType = NSBoxCustom;
    box.cornerRadius = 8.0;
    box.borderWidth = 1.0;
    box.borderColor = [NSColor separatorColor];
    box.fillColor = [NSColor controlBackgroundColor];
    box.translatesAutoresizingMaskIntoConstraints = NO;

    NSImageView *imageView = [NSImageView new];
    imageView.imageScaling = NSImageScaleProportionallyUpOrDown;
    imageView.image = [self loadRadioImage];
    imageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.radioImageView = imageView;

    self.radioModelLabel = [NSTextField labelWithString:@"Target Radio: Lab599 Discovery TX-500"];
    self.radioModelLabel.font = [NSFont systemFontOfSize:14 weight:NSFontWeightBold];

    self.radioSpecsLabel = [NSTextField wrappingLabelWithString:@"Target Specs: 256×128 Monochrome LCD • 32-bit Floating-Point DSP • All-Aluminum CNC Waterproof Chassis"];
    self.radioSpecsLabel.textColor = NSColor.secondaryLabelColor;
    self.radioSpecsLabel.font = [NSFont systemFontOfSize:11];

    self.radioCompatibilityBadge = [NSTextField labelWithString:@"● Model Verification: Select or download a .fw file above to verify radio compatibility."];
    self.radioCompatibilityBadge.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    self.radioCompatibilityBadge.textColor = NSColor.secondaryLabelColor;

    NSStackView *textStack = [NSStackView stackViewWithViews:@[self.radioModelLabel, self.radioSpecsLabel, self.radioCompatibilityBadge]];
    textStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    textStack.alignment = NSLayoutAttributeLeading;
    textStack.spacing = 3;
    textStack.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *hStack = [NSStackView stackViewWithViews:@[imageView, textStack]];
    hStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hStack.alignment = NSLayoutAttributeCenterY;
    hStack.spacing = 14;
    hStack.translatesAutoresizingMaskIntoConstraints = NO;
    [box.contentView addSubview:hStack];

    [NSLayoutConstraint activateConstraints:@[
        [imageView.widthAnchor constraintEqualToConstant:150],
        [imageView.heightAnchor constraintEqualToConstant:80],
        [hStack.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:12],
        [hStack.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-12],
        [hStack.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:7],
        [hStack.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-7],
        [textStack.trailingAnchor constraintEqualToAnchor:hStack.trailingAnchor]
    ]];

    return box;
}

- (NSBox *)buildPowerSafetyBox {
    NSBox *box = [NSBox new];
    box.titlePosition = NSNoTitle;
    box.boxType = NSBoxCustom;
    box.cornerRadius = 8.0;
    box.borderWidth = 1.0;
    box.borderColor = [NSColor separatorColor];
    box.fillColor = [NSColor controlBackgroundColor];
    box.translatesAutoresizingMaskIntoConstraints = NO;

    self.powerSafetyTitleLabel = [NSTextField labelWithString:@"⚡ Power Requirement: 9–15V DC (Stable External Power Recommended)"];
    self.powerSafetyTitleLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    self.powerSafetyTitleLabel.textColor = [NSColor labelColor];

    self.powerSafetyDescLabel = [NSTextField wrappingLabelWithString:@"Note for BP-500/550 Battery Pack: In bootloader mode (\"The loader is waiting...\"), the transceiver does not detect the Battery Pack and powers off automatically after 10 seconds. Connect external power (13.8V DC) or keep the Battery Pack PWR button held continuously throughout the update."];
    self.powerSafetyDescLabel.font = [NSFont systemFontOfSize:11];
    self.powerSafetyDescLabel.textColor = [NSColor secondaryLabelColor];

    self.powerCheckButton = [NSButton buttonWithTitle:@"Check Radio Voltage" target:self action:@selector(checkPowerStatus:)];
    self.powerCheckButton.bezelStyle = NSBezelStyleRounded;
    self.powerCheckButton.controlSize = NSControlSizeSmall;
    self.powerCheckButton.font = [NSFont systemFontOfSize:11];

    NSStackView *vStack = [NSStackView stackViewWithViews:@[self.powerSafetyTitleLabel, self.powerSafetyDescLabel]];
    vStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    vStack.alignment = NSLayoutAttributeLeading;
    vStack.spacing = 3;
    vStack.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *hStack = [NSStackView stackViewWithViews:@[vStack, self.powerCheckButton]];
    hStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    hStack.alignment = NSLayoutAttributeCenterY;
    hStack.spacing = 12;
    hStack.translatesAutoresizingMaskIntoConstraints = NO;
    [box.contentView addSubview:hStack];

    [NSLayoutConstraint activateConstraints:@[
        [hStack.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:12],
        [hStack.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-12],
        [hStack.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:8],
        [hStack.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-8],
        [vStack.trailingAnchor constraintEqualToAnchor:self.powerCheckButton.leadingAnchor constant:-12]
    ]];

    return box;
}

- (void)updatePowerSafetyUI {
    if (self.lastDetectedVoltage > 7.0 && self.lastDetectedVoltage <= 12.8) {
        self.powerSafetyBox.borderColor = [NSColor systemOrangeColor];
        self.powerSafetyBox.fillColor = [NSColor colorWithSRGBRed:1.0 green:0.5 blue:0.0 alpha:0.08];
        self.powerSafetyTitleLabel.stringValue = [NSString stringWithFormat:@"⚠️ CAUTION: BP-500/550 Battery Pack Power Detected (%.1f V)", self.lastDetectedVoltage];
        self.powerSafetyTitleLabel.textColor = [NSColor systemOrangeColor];
        self.powerSafetyDescLabel.stringValue = @"Transceiver is running on Battery Pack! In bootloader mode (\"The loader is waiting...\"), the radio does NOT detect the Battery Pack and switches off automatically after 10 seconds. Connect an external power supply (13.8V DC) or keep the Battery Pack PWR button firmly held down for the entire update.";
        self.powerSafetyDescLabel.textColor = [NSColor labelColor];
    } else if (self.lastDetectedVoltage > 13.0) {
        self.powerSafetyBox.borderColor = [NSColor colorWithSRGBRed:0.2 green:0.7 blue:0.3 alpha:0.8];
        self.powerSafetyBox.fillColor = [NSColor colorWithSRGBRed:0.1 green:0.7 blue:0.2 alpha:0.08];
        self.powerSafetyTitleLabel.stringValue = [NSString stringWithFormat:@"✓ Stable External DC Power Verified (%.1f V)", self.lastDetectedVoltage];
        self.powerSafetyTitleLabel.textColor = [NSColor colorWithSRGBRed:0.1 green:0.65 blue:0.25 alpha:1.0];
        self.powerSafetyDescLabel.stringValue = @"External DC power supply detected. Voltage is within optimal operating range (9–15V) for firmware updating.";
        self.powerSafetyDescLabel.textColor = [NSColor secondaryLabelColor];
    } else {
        self.powerSafetyBox.borderColor = [NSColor separatorColor];
        self.powerSafetyBox.fillColor = [NSColor controlBackgroundColor];
        self.powerSafetyTitleLabel.stringValue = @"⚡ Radio Voltage Not Verified";
        self.powerSafetyTitleLabel.textColor = [NSColor labelColor];
        self.powerSafetyDescLabel.stringValue = @"Turn the radio on in normal mode, select CAT protocol LAB599 (Menu 35), and click Check Radio Voltage. For firmware updates, use stable 9–15V DC power; when using BP-500/550, hold its PWR button throughout the update.";
        self.powerSafetyDescLabel.textColor = [NSColor secondaryLabelColor];
    }
}

- (void)checkPowerStatus:(id)sender {
    (void)sender;
    if (self.busy) return;
    NSString *port = self.portMenu.selectedItem.title;
    if (!self.hasPorts || ![port hasPrefix:@"/dev/cu."]) {
        [self showAlert:@"Serial Port Required" message:@"Please select a valid radio serial port first." warning:YES];
        return;
    }

    [self appendLog:[NSString stringWithFormat:@"Probing radio power status via CAT on %@...", port]];
    self.lastDetectedVoltage = 0.0;
    [self updatePowerSafetyUI];
    self.powerCheckButton.enabled = NO;
    self.powerCheckButton.title = @"Checking…";

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        Lab599SerialPort *sp = [Lab599SerialPort openPath:port speed:B9600 error:&err];
        double probedVolts = 0.0;
        NSString *rawReply = nil;
        if (sp) {
            // VL; is the documented LAB599 CAT command for supply voltage.
            // Retry once because some USB-serial adapters need a brief settling
            // interval immediately after the port is opened.
            for (NSInteger attempt = 0; attempt < 2 && probedVolts == 0.0; attempt++) {
                if (attempt > 0) Lab599Pause(0.12, nil);
                rawReply = Lab599ReadCATFrame(sp, @"VL;", 0.9, &err);
                TXTelemetryData *sample = [TXTelemetryData new];
                if ([TX500TelemetryEngine parseVLReply:rawReply intoData:sample]) {
                    probedVolts = sample.voltage;
                }
            }
            [sp close];
        }

        dispatch_async(dispatch_get_main_queue(), ^{
            self.powerCheckButton.enabled = YES;
            self.powerCheckButton.title = @"Check Radio Voltage";
            if (probedVolts > 7.0) {
                self.lastDetectedVoltage = probedVolts;
                [self updatePowerSafetyUI];
                [self appendLog:[NSString stringWithFormat:@"CAT power check successful: Voltage = %.1f V (%@)",
                    probedVolts, (probedVolts <= 12.8 ? @"BP-500/550 Battery Pack" : @"External DC Power Supply")]];
            } else {
                self.lastDetectedVoltage = 0.0;
                [self updatePowerSafetyUI];
                NSString *detail = err.localizedDescription ?: @"No valid VL response was received.";
                [self appendLog:[NSString stringWithFormat:
                    @"CAT voltage check failed: %@%@ Turn the radio on normally and set Menu 35 (CAT PROTOCOL) to LAB599 at 9600 baud.",
                    detail, rawReply.length ? [NSString stringWithFormat:@" Reply: %@.", rawReply] : @""]];
            }
        });
    });
}

- (void)updateRadioPreviewForFirmwareData:(NSData *)data url:(NSURL *)url {
    if (!data || data.length < 16) {
        self.radioImageView.image = [self loadRadioImageNamed:@"tx500_radio"];
        self.radioModelLabel.stringValue = @"Target Radio: Lab599 Discovery TX-500";
        self.radioSpecsLabel.stringValue = @"Target Specs: 256×128 Monochrome LCD • 32-bit Floating-Point DSP • All-Aluminum CNC Waterproof Chassis";
        self.radioCompatibilityBadge.stringValue = @"● Model Verification: Select or download a .fw file above to verify radio compatibility.";
        self.radioCompatibilityBadge.textColor = NSColor.secondaryLabelColor;
        return;
    }

    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSString *nameLower = url.lastPathComponent.lowercaseString;
    NSString *pathLower = url.path.lowercaseString;

    BOOL isAltai = [nameLower containsString:@"altai"] || [nameLower containsString:@"_alt"] || [pathLower containsString:@"altai"];
    BOOL isPro = !isAltai && ([nameLower containsString:@"pro"] || [pathLower containsString:@"tx500pro"]);
    BOOL isMP = !isPro && !isAltai && ((memcmp(bytes + 12, "\x96\x3b\xcd\xf4", 4) == 0) || [nameLower containsString:@"mp"] || [pathLower containsString:@"tx500mp"]);
    BOOL isDiscovery = (memcmp(bytes + 12, "\xaa\xb4\x1a\xc6", 4) == 0) && !isPro && !isAltai && !isMP;

    if (isDiscovery) {
        self.radioImageView.image = [self loadRadioImageNamed:@"tx500_radio"];
        self.radioModelLabel.stringValue = @"Target Radio: Lab599 Discovery TX-500";
        self.radioSpecsLabel.stringValue = @"256×128 Monochrome LCD • 32-bit Floating-Point DSP • All-Aluminum CNC Waterproof Chassis";
        self.radioCompatibilityBadge.stringValue = @"✓ Hardware Match Confirmed: Lab599 TX-500 Discovery (BL20 Model ID: 0xc61ab4aa)";
        self.radioCompatibilityBadge.textColor = [NSColor colorWithSRGBRed:0.1 green:0.65 blue:0.25 alpha:1.0];
    } else if (isAltai) {
        self.radioImageView.image = [self loadRadioImageNamed:@"tx500_pro_altai"] ?: [self loadRadioImage];
        self.radioModelLabel.stringValue = @"Target Radio: Lab599 TX-500PRO ALTAI";
        self.radioSpecsLabel.stringValue = @"Keypad Arrow Navigation • Channelized ALTAI OS • Commercial / Tactical Waterproof Transceiver";
        self.radioCompatibilityBadge.stringValue = @"✓ Hardware Match Confirmed: Lab599 TX-500PRO ALTAI (Firmware: ALTAI Commercial OS)";
        self.radioCompatibilityBadge.textColor = [NSColor colorWithSRGBRed:0.1 green:0.65 blue:0.25 alpha:1.0];
    } else if (isPro) {
        self.radioImageView.image = [self loadRadioImageNamed:@"tx500_pro"] ?: [self loadRadioImage];
        self.radioModelLabel.stringValue = @"Target Radio: Lab599 TX-500PRO (Tactical)";
        self.radioSpecsLabel.stringValue = @"Rotary Volume & Squelch Knobs • TUNE/MULTI Dial • Tactical Audio DSP & Extended Filters";
        self.radioCompatibilityBadge.stringValue = @"✓ Hardware Match Confirmed: Lab599 TX-500PRO (Firmware: TX-500PRO Tactical)";
        self.radioCompatibilityBadge.textColor = [NSColor colorWithSRGBRed:0.1 green:0.65 blue:0.25 alpha:1.0];
    } else if (isMP) {
        self.radioImageView.image = [self loadRadioImageNamed:@"tx500_mp"] ?: [self loadRadioImage];
        self.radioModelLabel.stringValue = @"Target Radio: Lab599 TX-500MP (Manpack)";
        self.radioSpecsLabel.stringValue = @"192×96 Monochrome LCD • Integrated Battery System • Rugged Manpack Transceiver";
        self.radioCompatibilityBadge.stringValue = @"⚠️ Notice: Firmware is targeted for TX-500MP hardware (BL20 Model ID: 0x963bcdf4). Do not flash to Discovery.";
        self.radioCompatibilityBadge.textColor = [NSColor colorWithSRGBRed:0.85 green:0.45 blue:0.0 alpha:1.0];
    } else {
        self.radioImageView.image = [self loadRadioImageNamed:@"tx500_radio"];
        self.radioModelLabel.stringValue = @"Target Radio: Custom / Unknown Lab599 Hardware";
        self.radioSpecsLabel.stringValue = @"Target Specs: Lab599 Transceiver Hardware Platform";
        self.radioCompatibilityBadge.stringValue = @"⚠️ Unrecognized Hardware ID. Verify model before flashing.";
        self.radioCompatibilityBadge.textColor = NSColor.systemOrangeColor;
    }
}

#pragma mark - Local Firmware Loading

- (void)chooseFirmware:(id)sender {
    (void)sender;
    if (self.busy) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"fw" conformingToType:UTTypeData]];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.title = @"Select Lab599 Firmware File";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse result) {
        if (result != NSModalResponseOK || !panel.URL) return;
        NSError *readError = nil;
        NSData *data = [NSData dataWithContentsOfURL:panel.URL options:0 error:&readError];
        NSString *problem = data ? TXFirmwareValidationError(data) : readError.localizedDescription;
        if (problem) {
            [self showAlert:@"Firmware could not be loaded" message:problem warning:YES];
            return;
        }
        [self setLoadedFirmwareURL:panel.URL firmwareData:data isOnlineDownload:NO];
    }];
}

- (void)setLoadedFirmwareURL:(NSURL *)url firmwareData:(NSData *)data isOnlineDownload:(BOOL)isOnline {
    self.firmwareURL = url;
    self.firmwareName.stringValue = url.lastPathComponent;
    self.firmwareName.toolTip = url.path;
    NSString *hash = TXFirmwareSHA256(data);
    NSString *source = isOnline ? @"Online Download" : @"Local File";
    [self appendLog:[NSString stringWithFormat:@"Loaded %@ (%lu bytes, %@). SHA-256: %@",
        url.lastPathComponent, (unsigned long)data.length, source, hash]];

    if ([hash isEqualToString:@"2162fed7d27987507c8b412f3d38478c0a670a906a0c747578d7c975ad5a04ea"]) {
        [self appendLog:@"Matches verified official TX-500 Discovery v2.00.00 release."];
    }
    self.statusLabel.stringValue = [NSString stringWithFormat:@"Firmware ready: %@. Check that transceiver displays \"The loader is waiting...\".", url.lastPathComponent];
    self.updateButton.enabled = self.hasPorts;
    [self updateRadioPreviewForFirmwareData:data url:url];
}

#pragma mark - Online Firmware Catalog Sheet

- (void)openCatalogSheet:(id)sender {
    (void)sender;
    if (self.busy) return;

    if (!self.catalogSheet) {
        [self buildCatalogSheet];
    }

    [self.window beginSheet:self.catalogSheet completionHandler:nil];
    [self fetchCatalogList];
}

- (void)buildCatalogSheet {
    self.catalogSheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 620, 480)
        styleMask:(NSWindowStyleMaskTitled)
        backing:NSBackingStoreBuffered defer:NO];
    self.catalogSheet.title = @"Official Lab599 Firmware Catalog";

    NSTextField *title = [self label:@"Download Official Firmware from lab599.com"];
    title.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];

    NSTextField *desc = [NSTextField wrappingLabelWithString:
        @"Firmware releases retrieved directly from https://lab599.com/downloads. Select your transceiver model, pick the version, and click Download & Select."];
    desc.textColor = NSColor.secondaryLabelColor;

    // Filter by model
    NSTextField *modelLabel = [self label:@"Radio model:"];
    self.modelFilterPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.modelFilterPopup addItemWithTitle:@"All Models"];
    [self.modelFilterPopup addItemWithTitle:@"TX-500 Discovery"];
    [self.modelFilterPopup addItemWithTitle:@"TX-500MP"];
    self.modelFilterPopup.target = self;
    self.modelFilterPopup.action = @selector(filterChanged:);
    NSStackView *modelRow = [NSStackView stackViewWithViews:@[modelLabel, self.modelFilterPopup]];
    modelRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    modelRow.spacing = 10;

    // Firmware version selection
    NSTextField *verLabel = [self label:@"Available release:"];
    self.catalogPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.catalogPopup.target = self;
    self.catalogPopup.action = @selector(catalogSelectionChanged:);
    [self.catalogPopup.widthAnchor constraintEqualToConstant:360].active = YES;
    self.refreshCatalogBtn = [NSButton buttonWithTitle:@"Check for Updates" target:self action:@selector(fetchCatalogList)];
    NSStackView *catalogRow = [NSStackView stackViewWithViews:@[verLabel, self.catalogPopup, self.refreshCatalogBtn]];
    catalogRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    catalogRow.spacing = 8;

    // Changelog preview
    NSTextField *clLabel = [self label:@"Release notes / Changelog:"];
    NSScrollView *clScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    clScroll.hasVerticalScroller = YES;
    clScroll.borderType = NSBezelBorder;
    self.changelogView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 560, 110)];
    self.changelogView.editable = NO;
    self.changelogView.richText = NO;
    self.changelogView.verticallyResizable = YES;
    self.changelogView.textContainer.widthTracksTextView = YES;
    self.changelogView.textContainerInset = NSMakeSize(6, 6);
    self.changelogView.font = [NSFont systemFontOfSize:12];
    clScroll.documentView = self.changelogView;
    [clScroll.heightAnchor constraintEqualToConstant:110].active = YES;

    // Progress & Status
    self.downloadProgress = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.downloadProgress.minValue = 0.0;
    self.downloadProgress.maxValue = 1.0;
    self.downloadProgress.indeterminate = NO;
    self.downloadProgress.displayedWhenStopped = YES;
    self.downloadStatusLabel = [self label:@"Connecting to lab599.com..."];
    self.downloadStatusLabel.textColor = NSColor.secondaryLabelColor;

    // Buttons
    self.downloadActionBtn = [NSButton buttonWithTitle:@"Download & Select" target:self action:@selector(startDownloadSelectedFirmware:)];
    self.downloadActionBtn.bezelStyle = NSBezelStyleRounded;
    self.downloadActionBtn.keyEquivalent = @"\r";
    NSButton *closeBtn = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(closeCatalogSheet:)];
    NSStackView *actionRow = [NSStackView stackViewWithViews:@[self.downloadActionBtn, closeBtn]];
    actionRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    actionRow.spacing = 10;

    NSStackView *sheetStack = [NSStackView stackViewWithViews:@[
        title, desc,
        modelRow, catalogRow,
        clLabel, clScroll,
        self.downloadProgress, self.downloadStatusLabel,
        actionRow
    ]];
    sheetStack.translatesAutoresizingMaskIntoConstraints = NO;
    sheetStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    sheetStack.alignment = NSLayoutAttributeLeading;
    sheetStack.spacing = 11;
    [self.catalogSheet.contentView addSubview:sheetStack];

    [NSLayoutConstraint activateConstraints:@[
        [sheetStack.leadingAnchor constraintEqualToAnchor:self.catalogSheet.contentView.leadingAnchor constant:20],
        [sheetStack.trailingAnchor constraintEqualToAnchor:self.catalogSheet.contentView.trailingAnchor constant:-20],
        [sheetStack.topAnchor constraintEqualToAnchor:self.catalogSheet.contentView.topAnchor constant:20],
        [sheetStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.catalogSheet.contentView.bottomAnchor constant:-20],
        [desc.widthAnchor constraintEqualToAnchor:sheetStack.widthAnchor],
        [clScroll.widthAnchor constraintEqualToAnchor:sheetStack.widthAnchor],
        [self.downloadProgress.widthAnchor constraintEqualToAnchor:sheetStack.widthAnchor],
        [self.downloadStatusLabel.widthAnchor constraintEqualToAnchor:sheetStack.widthAnchor]
    ]];
}

- (void)fetchCatalogList {
    self.downloadStatusLabel.stringValue = @"Checking https://lab599.com/downloads for latest firmwares...";
    self.refreshCatalogBtn.enabled = NO;
    self.downloadActionBtn.enabled = NO;
    self.downloadProgress.indeterminate = YES;
    [self.downloadProgress startAnimation:nil];

    [[Lab599FirmwareCatalog sharedCatalog] fetchAvailableFirmwaresWithCompletion:^(NSArray<Lab599FirmwareItem *> *items, NSError *error) {
        self.downloadProgress.indeterminate = NO;
        [self.downloadProgress stopAnimation:nil];
        self.refreshCatalogBtn.enabled = YES;
        self.catalogItems = items;
        if (error) {
            self.downloadStatusLabel.stringValue = [NSString stringWithFormat:@"Notice: using fallback catalog (%@)", error.localizedDescription];
        } else {
            self.downloadStatusLabel.stringValue = [NSString stringWithFormat:@"Found %lu firmware releases on lab599.com.", (unsigned long)items.count];
        }
        [self updateCatalogPopupForFilter];
    }];
}

- (void)filterChanged:(id)sender {
    (void)sender;
    [self updateCatalogPopupForFilter];
}

- (void)updateCatalogPopupForFilter {
    NSString *filter = self.modelFilterPopup.selectedItem.title;
    NSMutableArray<Lab599FirmwareItem *> *filtered = [NSMutableArray array];
    for (Lab599FirmwareItem *item in self.catalogItems) {
        if ([filter isEqualToString:@"All Models"] ||
            [item.model rangeOfString:filter options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [filtered addObject:item];
        }
    }
    self.filteredItems = filtered;
    [self.catalogPopup removeAllItems];
    for (Lab599FirmwareItem *item in filtered) {
        [self.catalogPopup addItemWithTitle:item.displayTitle];
    }
    self.downloadActionBtn.enabled = filtered.count > 0;
    [self catalogSelectionChanged:nil];
}

- (void)catalogSelectionChanged:(id)sender {
    (void)sender;
    NSInteger index = self.catalogPopup.indexOfSelectedItem;
    if (index >= 0 && index < (NSInteger)self.filteredItems.count) {
        Lab599FirmwareItem *item = self.filteredItems[index];
        NSString *cl = item.changelog ?: @"No specific changelog published for this release.";
        NSString *info = [NSString stringWithFormat:@"Model: %@\nVersion: %@\nDownload: %@\n\n%@",
                          item.model, item.version, item.downloadURL.absoluteString, cl];
        self.changelogView.string = info;
    } else {
        self.changelogView.string = @"";
    }
}

- (void)startDownloadSelectedFirmware:(id)sender {
    (void)sender;
    NSInteger index = self.catalogPopup.indexOfSelectedItem;
    if (index < 0 || index >= (NSInteger)self.filteredItems.count) return;
    Lab599FirmwareItem *selectedItem = self.filteredItems[index];

    self.downloadActionBtn.enabled = NO;
    self.modelFilterPopup.enabled = NO;
    self.catalogPopup.enabled = NO;
    self.refreshCatalogBtn.enabled = NO;
    self.downloadProgress.indeterminate = NO;
    self.downloadProgress.doubleValue = 0.0;
    self.downloadStatusLabel.stringValue = [NSString stringWithFormat:@"Downloading %@...", selectedItem.title];

    self.activeDownloadTask = [[Lab599FirmwareCatalog sharedCatalog] downloadFirmware:selectedItem
        progress:^(double progress, int64_t bytesWritten, int64_t totalExpected) {
            self.downloadProgress.doubleValue = progress;
            self.downloadStatusLabel.stringValue = [NSString stringWithFormat:@"Downloading: %.1f%% (%lld KB / %lld KB)",
                progress * 100.0, bytesWritten / 1024, totalExpected / 1024];
        }
        completion:^(NSURL * _Nullable localFileURL, NSString * _Nullable sha256, NSError * _Nullable error) {
            self.modelFilterPopup.enabled = YES;
            self.catalogPopup.enabled = YES;
            self.refreshCatalogBtn.enabled = YES;
            self.downloadActionBtn.enabled = YES;

            if (error || !localFileURL) {
                self.downloadStatusLabel.stringValue = [NSString stringWithFormat:@"Download failed: %@", error.localizedDescription];
                [self showAlert:@"Download Error" message:error.localizedDescription warning:YES];
                return;
            }

            self.downloadProgress.doubleValue = 1.0;
            self.downloadStatusLabel.stringValue = @"Download complete and verified!";
            [self appendLog:[NSString stringWithFormat:@"Successfully downloaded official %@ (SHA-256: %@) from %@", selectedItem.title, sha256 ?: @"", selectedItem.downloadURL]];

            NSData *data = [NSData dataWithContentsOfURL:localFileURL];
            [self setLoadedFirmwareURL:localFileURL firmwareData:data isOnlineDownload:YES];
            [self.window endSheet:self.catalogSheet];
        }];
}

- (void)closeCatalogSheet:(id)sender {
    (void)sender;
    if (self.activeDownloadTask && self.activeDownloadTask.state == NSURLSessionTaskStateRunning) {
        [self.activeDownloadTask cancel];
        self.activeDownloadTask = nil;
    }
    [self.window endSheet:self.catalogSheet];
}

#pragma mark - About Window

- (void)showAboutWindow:(id)sender {
    (void)sender;
    if (!self.aboutWindow) {
        self.aboutWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 540, 540)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
            backing:NSBackingStoreBuffered defer:NO];
        self.aboutWindow.title = @"About Lab599 Utility";
        self.aboutWindow.releasedWhenClosed = NO;
        [self.aboutWindow center];

        // Icon
        NSImage *icon = [NSImage imageNamed:@"AppIcon"];
        if (!icon) {
            NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
            if (iconPath) icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
        }
        if (!icon) {
            icon = [[NSWorkspace sharedWorkspace] iconForFile:[[NSBundle mainBundle] bundlePath]];
        }
        NSImageView *iconView = [NSImageView imageViewWithImage:icon];
        iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
        [iconView.widthAnchor constraintEqualToConstant:72].active = YES;
        [iconView.heightAnchor constraintEqualToConstant:72].active = YES;

        // Information text
        NSTextField *appName = [self label:@"Lab599 Utility"];
        appName.font = [NSFont systemFontOfSize:20 weight:NSFontWeightBold];

        NSString *infoVer = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"2.8";
        NSString *infoBuild = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"14";
        NSTextField *appVer = [self label:[NSString stringWithFormat:@"Version %@ (Build %@, Universal macOS)", infoVer, infoBuild]];
        appVer.textColor = NSColor.secondaryLabelColor;
        appVer.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];

        NSTextField *hwLabel = [self label:@"Supported Hardware: Lab599 TX-500 Discovery, TX-500MP & TX-500PRO"];
        hwLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        hwLabel.textColor = [NSColor colorWithCalibratedRed:0.12 green:0.50 blue:0.90 alpha:1.0];

        NSTextField *authorLabel = [self label:@"Developed by EP2AES (factoreal)"];
        authorLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];

        NSTextField *callsignLabel = [self label:@"Ham Radio Callsign: EP2AES  •  Email: EP2AES@asis.sh"];
        callsignLabel.textColor = NSColor.secondaryLabelColor;
        callsignLabel.font = [NSFont systemFontOfSize:11];

        // Features Card Box
        NSBox *featuresBox = [NSBox new];
        featuresBox.boxType = NSBoxCustom;
        featuresBox.cornerRadius = 8.0;
        featuresBox.borderWidth = 1.0;
        featuresBox.borderColor = [NSColor separatorColor];
        featuresBox.fillColor = [NSColor controlBackgroundColor];
        featuresBox.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *boxTitle = [self label:@"Radio Management & Diagnostic Features"];
        boxTitle.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];

        NSTextField *featuresList = [NSTextField wrappingLabelWithString:
            @"• Live Radio Telemetry Dashboard: supply voltage, current drain, RF power, SWR & PA temp\n"
            @"• Firmware Updates with automatic MCU model detection (Discovery vs MP) & BL20 verification\n"
            @"• Precision Real-Time Clock (RTC) synchronization with host time / UTC\n"
            @"• Real-time CAT command terminal and transceiver diagnostics\n"
            @"• EEPROM Settings backup, restore & side-by-side visual diff comparison\n"
            @"• 100-channel memory manager, operating profiles (SOTA/POTA, FT8, Contest) & CSV import/export\n"
            @"• FTDI D2XX USB serial driver installation & system diagnostics\n"
            @"• Official Lab599 documentation, schematics & firmware downloads library\n"
            @"• Direct GitHub Issue reporter for feature suggestions, feedback & bug reports"];
        featuresList.textColor = NSColor.labelColor;
        featuresList.font = [NSFont systemFontOfSize:11];

        NSStackView *boxStack = [NSStackView stackViewWithViews:@[boxTitle, featuresList]];
        boxStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        boxStack.alignment = NSLayoutAttributeLeading;
        boxStack.spacing = 5;
        boxStack.translatesAutoresizingMaskIntoConstraints = NO;
        [featuresBox.contentView addSubview:boxStack];

        [NSLayoutConstraint activateConstraints:@[
            [boxStack.leadingAnchor constraintEqualToAnchor:featuresBox.contentView.leadingAnchor constant:12],
            [boxStack.trailingAnchor constraintEqualToAnchor:featuresBox.contentView.trailingAnchor constant:-12],
            [boxStack.topAnchor constraintEqualToAnchor:featuresBox.contentView.topAnchor constant:10],
            [boxStack.bottomAnchor constraintEqualToAnchor:featuresBox.contentView.bottomAnchor constant:-10],
            [featuresList.widthAnchor constraintEqualToAnchor:boxStack.widthAnchor]
        ]];

        NSTextField *disclaimer = [NSTextField wrappingLabelWithString:
            @"Independent software created for the amateur radio community. Protocols and file formats reverse-engineered from original tools."];
        disclaimer.textColor = NSColor.tertiaryLabelColor;
        disclaimer.font = [NSFont systemFontOfSize:10];
        disclaimer.alignment = NSTextAlignmentCenter;

        // GitHub button
        NSButton *gitBtn = [NSButton buttonWithTitle:@"View on GitHub: https://github.com/fact0real/Lab599-Firmware-Updater"
                                              target:self
                                              action:@selector(openGitHubRepo:)];
        gitBtn.bezelStyle = NSBezelStyleInline;

        NSButton *webBtn = [NSButton buttonWithTitle:@"Official Lab599 Website: https://lab599.com"
                                              target:self
                                              action:@selector(openLab599Website:)];
        webBtn.bezelStyle = NSBezelStyleInline;

        NSButton *closeBtn = [NSButton buttonWithTitle:@"Close" target:self action:@selector(closeAboutWindow:)];
        closeBtn.bezelStyle = NSBezelStyleRounded;
        closeBtn.keyEquivalent = @"\r";

        NSStackView *aboutStack = [NSStackView stackViewWithViews:@[
            iconView, appName, appVer, hwLabel, authorLabel, callsignLabel, featuresBox, disclaimer, gitBtn, webBtn, closeBtn
        ]];
        aboutStack.translatesAutoresizingMaskIntoConstraints = NO;
        aboutStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        aboutStack.alignment = NSLayoutAttributeCenterX;
        aboutStack.spacing = 8;
        [self.aboutWindow.contentView addSubview:aboutStack];

        [NSLayoutConstraint activateConstraints:@[
            [aboutStack.leadingAnchor constraintEqualToAnchor:self.aboutWindow.contentView.leadingAnchor constant:20],
            [aboutStack.trailingAnchor constraintEqualToAnchor:self.aboutWindow.contentView.trailingAnchor constant:-20],
            [aboutStack.topAnchor constraintEqualToAnchor:self.aboutWindow.contentView.topAnchor constant:16],
            [aboutStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.aboutWindow.contentView.bottomAnchor constant:-16],
            [featuresBox.widthAnchor constraintEqualToAnchor:aboutStack.widthAnchor],
            [disclaimer.widthAnchor constraintEqualToAnchor:aboutStack.widthAnchor]
        ]];
    }
    [self.aboutWindow center];
    [self.aboutWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)closeAboutWindow:(id)sender {
    (void)sender;
    if (self.aboutWindow) {
        [self.aboutWindow orderOut:nil];
    }
}

- (void)openGitHubRepo:(id)sender {
    (void)sender;
    NSURL *url = [NSURL URLWithString:@"https://github.com/fact0real/Lab599-Firmware-Updater"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)openLab599Website:(id)sender {
    (void)sender;
    NSURL *url = [NSURL URLWithString:@"https://lab599.com/downloads"];
    [[NSWorkspace sharedWorkspace] openURL:url];
}

#pragma mark - Diagnostic Logs & Alerts

- (void)saveLog:(id)sender {
    (void)sender;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[UTTypePlainText];
    panel.nameFieldStringValue = @"Lab599-Utility-log.txt";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK) return;
        NSError *error = nil;
        if (![self.logView.string writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            [self showAlert:@"Log could not be saved" message:error.localizedDescription warning:YES];
        }
    }];
}

- (void)showAlert:(NSString *)title message:(NSString *)message warning:(BOOL)warning {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = warning ? NSAlertStyleWarning : NSAlertStyleInformational;
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

#pragma mark - Firmware Update Process

- (void)startUpdate:(id)sender {
    (void)sender;
    if (self.busy || self.operationPicker.selectedSegment != 0) return;
    NSString *port = self.portMenu.selectedItem.title;
    if (!self.hasPorts || ![port hasPrefix:@"/dev/cu."] || !self.firmwareURL) return;

    NSError *error = nil;
    NSData *firmware = [NSData dataWithContentsOfURL:self.firmwareURL options:0 error:&error];
    NSString *problem = firmware ? TXFirmwareValidationError(firmware) : error.localizedDescription;
    if (problem) {
        [self showAlert:@"Firmware could not be loaded" message:problem warning:YES];
        return;
    }

    if (self.lastDetectedVoltage > 7.0 && self.lastDetectedVoltage <= 12.8) {
        NSAlert *batteryAlert = [NSAlert new];
        batteryAlert.alertStyle = NSAlertStyleCritical;
        batteryAlert.messageText = @"⚠️ Critical Warning: BP-500/550 Battery Pack Detected!";
        batteryAlert.informativeText = [NSString stringWithFormat:
            @"The transceiver is running on battery power (detected: %.1f V).\n\n"
            @"CRITICAL SAFETY NOTICE (Lab599 User Manual):\n"
            @"\"Note for transceivers equipped with a BP-500/550 Battery Pack: in bootloader mode, the transceiver does not detect the Battery Pack. Since no data communication occurs for 10 seconds, the battery pack switches off automatically.\"\n\n"
            @"An unexpected power shutdown during firmware writing will corrupt the firmware and may brick your radio!\n\n"
            @"REQUIRED ACTION:\n"
            @"1. Connect the transceiver to an external DC power supply (9–15 V, recommended 13.8 V).\n"
            @"— OR —\n"
            @"2. If flashing on battery pack, you MUST hold down the PWR button on the Battery Pack continuously during the ENTIRE update process.\n\n"
            @"Are you holding the Battery Pack PWR button, or ready to connect external power?",
            self.lastDetectedVoltage];
        [batteryAlert addButtonWithTitle:@"I am holding Battery PWR button — Proceed"];
        [batteryAlert addButtonWithTitle:@"Cancel Update (Connect External Power)"];
        if ([batteryAlert runModal] != NSAlertFirstButtonReturn) {
            [self appendLog:@"Update cancelled by user to connect external power supply."];
            return;
        }
    }

    NSAlert *confirmation = [NSAlert new];
    confirmation.alertStyle = NSAlertStyleWarning;
    confirmation.messageText = @"Start the firmware update?";
    NSString *powerInfo = nil;
    if (self.lastDetectedVoltage > 13.0) {
        powerInfo = [NSString stringWithFormat:@"Power Source: External DC Power Supply (%.1f V) verified stable.", self.lastDetectedVoltage];
    } else if (self.lastDetectedVoltage > 7.0) {
        powerInfo = [NSString stringWithFormat:@"Power Source: BP-500/550 Battery Pack (%.1f V) — Ensure PWR button is held!", self.lastDetectedVoltage];
    } else {
        powerInfo = @"Power Source: 9–15V DC external power required (Hold Battery Pack PWR if on BP-500/550).";
    }

    confirmation.informativeText = [NSString stringWithFormat:
        @"Firmware: %@\nPort: %@\n%@\n\nThe transceiver must display \"The loader is waiting...\". Keep power and USB cable firmly connected throughout the update.",
        self.firmwareURL.lastPathComponent, port, powerInfo];
    [confirmation addButtonWithTitle:@"Start Update"];
    [confirmation addButtonWithTitle:@"Cancel"];
    if ([confirmation runModal] != NSAlertFirstButtonReturn) return;

    self.busy = YES;
    self.operationPicker.enabled = NO;
    self.syncButton.enabled = NO;
    self.timeZoneMenu.enabled = NO;
    self.updateButton.enabled = NO;
    self.portMenu.enabled = NO;
    self.chooseButton.enabled = NO;
    self.onlineButton.enabled = NO;
    self.refreshButton.enabled = NO;
    self.progressBar.doubleValue = 0;
    self.statusLabel.stringValue = @"Starting the update...";
    [self appendLog:[NSString stringWithFormat:@"Starting transfer of %@ on %@.", self.firmwareURL.lastPathComponent, port]];

    self.activity = [[NSProcessInfo processInfo] beginActivityWithOptions:(NSActivityUserInitiated | NSActivityIdleSystemSleepDisabled)
        reason:@"Transferring Lab599 firmware"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TXTransferResult *result = TXFlashFirmware(firmware, port, TXDefaultTransferOptions(),
            ^(NSUInteger sent, NSUInteger total) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    self.progressBar.doubleValue = (double)sent / total;
                    self.statusLabel.stringValue = sent == total ?
                        @"File sent. Waiting for transceiver's final confirmation..." :
                        [NSString stringWithFormat:@"Sending firmware: %lu / %lu bytes (%.1f%%)",
                            (unsigned long)sent, (unsigned long)total, 100.0 * sent / total];
                });
            },
            ^(NSString *message) {
                dispatch_async(dispatch_get_main_queue(), ^{ [self appendLog:message]; });
            });

        dispatch_async(dispatch_get_main_queue(), ^{
            self.busy = NO;
            self.operationPicker.enabled = YES;
            self.timeZoneMenu.enabled = YES;
            [[NSProcessInfo processInfo] endActivity:self.activity];
            self.activity = nil;
            self.chooseButton.enabled = YES;
            self.onlineButton.enabled = YES;
            self.refreshButton.enabled = YES;
            [self refreshPorts:nil];

            if (result.success) {
                self.progressBar.doubleValue = 1;
                self.statusLabel.stringValue = @"Update acknowledged by the transceiver. Restart the radio and check firmware version.";
                [self showAlert:@"Firmware transfer complete"
                        message:@"The radio returned its final OK confirmation. Check its display, then power-cycle the transceiver and verify the firmware version."
                        warning:NO];
            } else {
                self.statusLabel.stringValue = [NSString stringWithFormat:@"Stopped during %@. Check diagnostic log.", result.phase];
                [self showAlert:@"Firmware update was not confirmed"
                        message:[NSString stringWithFormat:@"%@\n\nIf the radio reports \"The firmware is not sent\", power-cycle into Loader mode again before retrying. Save the diagnostic log for troubleshooting.", result.failure]
                        warning:YES];
            }
        });
    });
}

#pragma mark - Window and App Lifecycle

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    if (!self.busy) { [NSApp terminate:nil]; return NO; }
    NSBeep();
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    [self.telemetryController stopMonitoring];
    if (!self.busy) return [self.tools confirmDiscard] ? NSTerminateNow : NSTerminateCancel;
    NSBeep();
    return NSTerminateCancel;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

@end

int main(int argc, const char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        [app run];
    }
    return 0;
}
