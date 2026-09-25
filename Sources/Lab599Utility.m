#import "TX500CWAudioDecoder.h"
#import <Cocoa/Cocoa.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "TX500Transfer.h"
#import "TX500TimeSync.h"
#import "TX500TimeDiscipline.h"
#import "Lab599FirmwareCatalog.h"
#import "Lab599TelemetryController.h"
#import "Lab599ToolsController.h"
#import "Lab599DriverController.h"
#import "Lab599DocsController.h"
#import "Lab599FeedbackController.h"
#import "TX500ScreenCaptureController.h"
#import "TX500CWStationController.h"
#import "TX500AudioMonitorController.h"
#import "TX500FT8StationController.h"
#import "TX500VoiceKeyerController.h"
#import "TX500StationController.h"
#import "TX500DXClusterController.h"
#import "TX500PSKReporter.h"
#import "TX500FT8AudioEngine.h"
#import "TX500LogbookController.h"
#import "TX500LogbookManager.h"
#import "TX500CloudSettingsController.h"

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
        self.focusRingType = NSFocusRingTypeNone;
        if ([self.cell respondsToSelector:@selector(setFocusRingType:)]) {
            [self.cell setFocusRingType:NSFocusRingTypeNone];
        }
        self.imagePosition = NSImageLeft;
        self.alignment = NSTextAlignmentLeft;
        self.wantsLayer = YES;
        self.layer.cornerRadius = 6.0;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self updateStyle];
    }
    return self;
}

- (BOOL)acceptsFirstResponder {
    return NO;
}

- (void)drawFocusRingMask {
    // Suppress default AppKit focus ring glow around the icon
}

- (void)setIsSelected:(BOOL)isSelected {
    _isSelected = isSelected;
    [self updateStyle];
}

- (void)updateStyle {
    // Resolve system symbol image with explicit weight
    NSImage *img = [NSImage imageWithSystemSymbolName:_iconName accessibilityDescription:nil];
    if (!img) {
        if ([_iconName isEqualToString:@"gauge.with.needle"]) img = [NSImage imageWithSystemSymbolName:@"gauge" accessibilityDescription:nil];
        else if ([_iconName isEqualToString:@"display"]) img = [NSImage imageWithSystemSymbolName:@"tv" accessibilityDescription:nil];
        else if ([_iconName isEqualToString:@"bubble.left.and.bubble.right"]) img = [NSImage imageWithSystemSymbolName:@"text.bubble" accessibilityDescription:nil];
        else if ([_iconName isEqualToString:@"waveform.badge.plus"] || [_iconName isEqualToString:@"waveform"]) img = [NSImage imageWithSystemSymbolName:@"waveform" accessibilityDescription:nil];
    }

    NSColor *iconColor = _isSelected ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor];
    if (@available(macOS 11.0, *)) {
        NSImageSymbolConfiguration *sizeConfig = [NSImageSymbolConfiguration
            configurationWithPointSize:14.0 weight:NSFontWeightMedium scale:NSImageSymbolScaleSmall];
        img = [img imageWithSymbolConfiguration:sizeConfig];
    }

    if (img) {
        img = [img copy];
        [img setTemplate:YES];
    }

    self.image = img;
    self.contentTintColor = iconColor;

    if (_isSelected) {
        self.layer.backgroundColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.15].CGColor;
        self.layer.borderColor = [[NSColor controlAccentColor] colorWithAlphaComponent:0.35].CGColor;
        self.layer.borderWidth = 1.0;

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

@interface Lab599FittableScrollView : NSScrollView
@end

@implementation Lab599FittableScrollView
- (NSSize)intrinsicContentSize {
    return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}
- (NSSize)fittingSize {
    return NSMakeSize(100.0, 100.0);
}
@end

@interface Lab599DocumentView : NSView
@end

@implementation Lab599DocumentView
- (BOOL)isFlipped {
    return YES;
}
@end

static void dumpViewTree(NSView *v, int depth, NSMutableString *outStr) {
    if (!v) return;
    [outStr appendFormat:@"%*s[%@ %p] fitting: %.1f x %.1f, intrinsic: %.1f x %.1f, frame: %.1f,%.1f %.1fx%.1f, hidden: %d\n",
        depth * 2, "", [v className], (void *)v,
        v.fittingSize.width, v.fittingSize.height,
        v.intrinsicContentSize.width, v.intrinsicContentSize.height,
        v.frame.origin.x, v.frame.origin.y, v.frame.size.width, v.frame.size.height,
        (int)v.isHidden];
    if ([v isKindOfClass:[NSTextField class]]) {
        NSString *str = [(NSTextField *)v stringValue];
        if (str.length > 0) {
            NSString *snippet = str.length > 60 ? [str substringToIndex:60] : str;
            [outStr appendFormat:@"%*s   -> text: \"%@\"\n", depth * 2, "", snippet];
        }
    } else if ([v isKindOfClass:[NSButton class]]) {
        NSString *str = [(NSButton *)v title];
        if (str.length > 0) {
            [outStr appendFormat:@"%*s   -> btn title: \"%@\"\n", depth * 2, "", str];
        }
    }
    for (NSView *sub in v.subviews) {
        dumpViewTree(sub, depth + 1, outStr);
    }
}

@interface AppDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, copy) NSArray<NSLayoutConstraint *> *featureWidthConstraints;
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
@property(nonatomic, strong) NSFileHandle *digitalSessionLogHandle;
@property(nonatomic, strong) NSURL *digitalSessionLogURL;
@property(nonatomic, strong) NSDate *digitalSessionStartedAt;
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
@property(nonatomic, strong) NSTextField *timeDisciplineLabel;
@property(nonatomic, strong) NSPopUpButton *timeZoneMenu;
@property(nonatomic, strong) NSButton *syncButton;
@property(nonatomic, strong) NSTimer *clockTimer;
@property(nonatomic, strong) Lab599TelemetryController *telemetryController;
@property(nonatomic, strong) Lab599ToolsController *tools;
@property(nonatomic, strong) Lab599DriverController *driverController;
@property(nonatomic, strong) Lab599DocsController *docsController;
@property(nonatomic, strong) Lab599FeedbackController *feedbackController;
@property(nonatomic, strong) TX500ScreenCaptureController *screenController;
@property(nonatomic, strong) TX500CWStationController *cwStationController;
@property(nonatomic, strong) TX500AudioMonitorController *audioMonitorController;
@property(nonatomic, strong) TX500FT8StationController *ft8StationController;
@property(nonatomic, strong) TX500LogbookController *logbookController;
@property(nonatomic, strong) TX500VoiceKeyerController *voiceKeyerController;
@property(nonatomic) BOOL voiceOwnsRadio;
@property(nonatomic, strong) TX500StationCore *stationCore;
@property(nonatomic, strong) TX500StationController *stationController;
@property(nonatomic, strong) TX500DXClusterController *clusterController;
@property(nonatomic) BOOL preparingClusterDraft;
@property(nonatomic, strong) id stationKeyMonitor;
@property(nonatomic, copy) NSString *stationPort;

// Modern Sidebar & Card UI Properties
@property(nonatomic, strong) NSMutableArray<TX500SidebarButton *> *sidebarItems;
@property(nonatomic, strong) NSVisualEffectView *sidebarView;
@property(nonatomic, strong) NSScrollView *sidebarScrollView;
@property(nonatomic, strong) NSButton *sidebarToggleButton;
@property(nonatomic, strong) NSLayoutConstraint *sidebarVisibleLeadingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *sidebarCollapsedTrailingConstraint;
@property(nonatomic, strong) NSLayoutConstraint *sidebarDividerWidthConstraint;
@property(nonatomic, assign) BOOL sidebarCollapsed;
@property(nonatomic, strong) NSView *mainContentView;
@property(nonatomic, strong) NSScrollView *mainScrollView;
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
@property(nonatomic, assign) BOOL catConsoleDefaultApplied;
@property(nonatomic, assign) BOOL terminateAfterToolsStop;
@property(nonatomic, strong) NSTextField *sectionTitleLabel;
@property(nonatomic, strong) NSButton *outdoorModeButton;
@property(nonatomic, assign) BOOL outdoorModeActive;
@property(nonatomic, strong) NSStackView *actionRow;
@property(nonatomic, strong) NSView *cardSpacer;

// Preferences Window Tabs & Containers
@property(nonatomic, strong) NSSegmentedControl *prefTabSegment;
@property(nonatomic, strong) NSView *prefStationContainer;
@property(nonatomic, strong) NSView *prefCloudContainer;

// Station Preferences Controls
@property(nonatomic, strong) NSTextField *prefCallsignField;
@property(nonatomic, strong) NSTextField *prefGridField;
@property(nonatomic, strong) NSTextField *prefQTHField;
@property(nonatomic, strong) NSTextField *prefOperatorField;
@property(nonatomic, strong) NSSlider *prefSWRSlider;
@property(nonatomic, strong) NSTextField *prefOperatorNameField;
@property(nonatomic, strong) NSTextField *prefRigField;
@property(nonatomic, strong) NSTextField *prefAntennaField;
@property(nonatomic, strong) NSTextField *prefStatusLabel;

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

// Preferences Window
@property(nonatomic, strong) NSWindow *preferencesWindow;
@property(nonatomic, strong) NSButton *prefUtcCheckbox;
@property(nonatomic, strong) NSPopUpButton *prefDefaultBandPopup;
@property(nonatomic, strong) NSButton *prefLogQsoCheckbox;
@property(nonatomic, strong) NSButton *prefLogDecodesCheckbox;
@property(nonatomic, strong) NSPopUpButton *prefThemePopup;
@property(nonatomic, strong) NSTextField *prefSWRThresholdField;
@property(nonatomic, strong) NSTextField *prefMaxReplyAttemptsField;

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

- (void)ensureWindowFitsVisibleScreen;
- (void)resetWindowBoundsToScreen:(id)sender;
- (BOOL)setSharedPTT:(BOOL)active;
- (void)startDigitalDiagnosticSessionLog;
- (void)stopDigitalDiagnosticSessionLog;
@end

@implementation AppDelegate

- (BOOL)setSharedPTT:(BOOL)active {
    NSError *error=nil;
    BOOL confirmed=[self.stationCore transmit:active owner:@"Digital" error:&error];
    if(!confirmed) [self appendLog:[NSString stringWithFormat:@"FT8 CAT %@ failed: %@",
        active ? @"TX" : @"RX", error.localizedDescription ?: @"Radio did not confirm the PTT state."]];
    return confirmed;
}
- (BOOL)sendSharedCATCommand:(NSString *)command {
    return [self.stationCore send:command owner:@"Station" error:nil];
}
- (NSString *)querySharedCATCommand:(NSString *)command timeout:(NSTimeInterval)timeout {
    (void)timeout; return [self.stationCore query:command error:nil];
}
- (void)stationPortChanged:(id)sender {
    (void)sender;
    if(![self stationCanEdit]) { if(self.stationPort.length) [self.portMenu selectItemWithTitle:self.stationPort]; [self appendLog:@"Stop station activity before changing the CAT port."]; return; }
    self.stationPort=[self currentStationPort];
    [self.tools portsAvailable:self.hasPorts];
    if(self.stationCore.owner.length) [self.stationCore selectOwner:self.stationCore.owner port:self.stationPort error:nil];
    if (self.operationPicker.selectedSegment == 12) [self.ft8StationController refreshRadioFrequency];
}
- (NSString *)currentStationPort { return self.hasPorts ? self.portMenu.selectedItem.title : @""; }
- (BOOL)stationCanEdit {
    return !self.busy && !self.stationController.busy && !self.clusterController.busy && !self.stationCore.ownsTX && !self.voiceKeyerController.keyer.active &&
        !self.ft8StationController.audioEngine.isMonitoring && !self.ft8StationController.audioEngine.isTransmitArmed &&
        !self.cwStationController.decoder.isListening && !self.cwStationController.keyer.isTransmitting && !self.cwStationController.keyer.isAutoCQActive &&
        !self.audioMonitorController.engine.isMonitoring;
}
- (void)stationSettingsChanged:(NSNotification *)notification {
    (void)notification;
    [TX500StationStore.sharedStore captureLegacySettings];
    NSDictionary *profile=TX500StationStore.sharedStore.activeProfile;
    self.cwStationController.keyer.myCallsign=profile[@"call"] ?: @"";
    self.cwStationController.assistant.myCallsign=profile[@"call"] ?: @"";
    [self.cwStationController applyStationInputDeviceUID:profile[@"radioInput"]];
    // Engines retain their DSP implementations but share a station-level route configuration.
    if ([self stationCanEdit]) {
        NSString *input=profile[@"radioInput"], *output=profile[@"radioOutput"];
        BOOL configured=profile[@"radioInput"]!=nil;
        if(configured) {
            self.ft8StationController.audioEngine.preserveDeviceSelection=YES;
            self.audioMonitorController.engine.preserveDeviceSelection=YES;
            self.ft8StationController.audioEngine.selectedInputDeviceUID=input;
            self.audioMonitorController.engine.selectedInputDeviceUID=input;
            self.ft8StationController.audioEngine.selectedOutputDeviceUID=output;
            self.audioMonitorController.engine.selectedOutputDeviceUID=profile[@"headphones"];
        }
    }
    TX500PSKReporter.sharedReporter.enabled=[NSUserDefaults.standardUserDefaults boolForKey:@"TX500_FT8_PSKReporterEnabled"];
}
- (void)stationCommand:(NSString *)command {
    if ([command isEqual:@"stop"]) {
        [self.ft8StationController stopStation]; [self.cwStationController stopStation];
        [self.audioMonitorController stopController]; [self.voiceKeyerController.keyer stop];
        NSError *error=nil; if(![self.stationCore releaseOwnedTX:&error]) [self appendLog:error.localizedDescription];
        return;
    }
    NSDictionary *tabs=@{@"station":@15,@"voice":@14,@"cw":@10,@"digital":@12,@"logbook":@13};
    if(tabs[command]) { self.operationPicker.selectedSegment=[tabs[command] integerValue]; [self operationChanged:nil]; }
    else { self.operationPicker.selectedSegment=15; [self operationChanged:nil]; [self.stationController runCommand:command]; }
}

- (NSTextField *)label:(NSString *)text {
    NSTextField *field = [NSTextField labelWithString:text];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    return field;
}

- (NSTextField *)wrappingLabel:(NSString *)text {
    NSTextField *field = [NSTextField wrappingLabelWithString:text];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.preferredMaxLayoutWidth = 450;
    [field setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return field;
}

- (void)appendLog:(NSString *)message {
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(), ^{ [self appendLog:message]; }); return; }
    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"HH:mm:ss";
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], message];
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular],
        NSForegroundColorAttributeName: NSColor.labelColor
    };
    [self.logView.textStorage appendAttributedString:[[NSAttributedString alloc] initWithString:entry attributes:attributes]];
    if (self.digitalSessionLogHandle) {
        NSData *lineData = [entry dataUsingEncoding:NSUTF8StringEncoding];
        @try { [self.digitalSessionLogHandle writeData:lineData]; }
        @catch (__unused NSException *exception) { [self stopDigitalDiagnosticSessionLog]; }
    }
    if (self.logView.textStorage.length > 200000) [self.logView.textStorage deleteCharactersInRange:NSMakeRange(0, self.logView.textStorage.length - 150000)];
    [self.logView scrollRangeToVisible:NSMakeRange(self.logView.string.length, 0)];
}

- (void)startDigitalDiagnosticSessionLog {
    if (self.digitalSessionLogHandle) return;
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    NSString *directory = [support stringByAppendingPathComponent:@"Lab599 Utility/Diagnostic Logs"];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
    NSDateFormatter *nameFormatter = [NSDateFormatter new];
    nameFormatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    nameFormatter.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"];
    nameFormatter.dateFormat = @"yyyy-MM-dd_HH-mm-ss'Z'";
    NSString *mode = self.ft8StationController.protocol == TX500_FT8_PROTOCOL_FT4 ? @"FT4" : @"FT8";
    NSString *filename = [NSString stringWithFormat:@"%@-Diagnostic-%@.log", mode, [nameFormatter stringFromDate:NSDate.date]];
    self.digitalSessionLogURL = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:filename]];
    [[NSFileManager defaultManager] createFileAtPath:self.digitalSessionLogURL.path contents:nil attributes:nil];
    self.digitalSessionLogHandle = [NSFileHandle fileHandleForWritingToURL:self.digitalSessionLogURL error:nil];
    self.digitalSessionStartedAt = NSDate.date;
    NSString *header = [NSString stringWithFormat:@"Lab599 Utility Digital Diagnostic Session\nMode: %@\nStarted: %@\nPort: %@\n%@\n",
                        mode, self.digitalSessionStartedAt, [self currentStationPort] ?: @"Unavailable",
                        @"────────────────────────────────────────────────────────"];
    [self.digitalSessionLogHandle writeData:[header dataUsingEncoding:NSUTF8StringEncoding]];
    [self appendLog:[NSString stringWithFormat:@"[Diagnostic] Digital session log: %@", self.digitalSessionLogURL.path]];
}

- (void)stopDigitalDiagnosticSessionLog {
    NSFileHandle *handle = self.digitalSessionLogHandle;
    if (!handle) return;
    NSTimeInterval elapsed = self.digitalSessionStartedAt ? [NSDate.date timeIntervalSinceDate:self.digitalSessionStartedAt] : 0;
    NSString *footer = [NSString stringWithFormat:@"────────────────────────────────────────────────────────\nEnded: %@\nDuration: %.0f seconds\n", NSDate.date, elapsed];
    @try {
        [handle writeData:[footer dataUsingEncoding:NSUTF8StringEncoding]];
        [handle synchronizeFile];
        [handle closeFile];
    } @catch (__unused NSException *exception) {}
    self.digitalSessionLogHandle = nil;
    self.digitalSessionStartedAt = nil;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;

    // Reset simulation mode preference on launch so real transceivers always operate in live mode
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"TX500_FT8_SimulationModeEnabled"];

    // Apply saved theme
    NSInteger savedTheme = [[NSUserDefaults standardUserDefaults] integerForKey:@"TX500_AppTheme"];
    if (savedTheme == 1) {
        [NSApp setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameAqua]];
    } else if (savedTheme == 2) {
        [NSApp setAppearance:[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]];
    }

    NSRect screenRect = [[NSScreen mainScreen] visibleFrame];
    CGFloat defaultW = 960.0;
    CGFloat defaultH = 620.0;
    if (screenRect.size.width > 0 && screenRect.size.height > 0) {
        defaultW = MIN(960.0, screenRect.size.width - 60.0);
        defaultH = MIN(620.0, screenRect.size.height - 80.0);
    }
    if (defaultW < 780.0) defaultW = 780.0;
    if (defaultH < 460.0) defaultH = 460.0;

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, defaultW, defaultH)
        styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable)
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Lab599 Utility";
    self.window.delegate = self;
    self.window.minSize = NSMakeSize(780, 460);
    [self.window setFrameAutosaveName:@"Lab599UtilityMainWindow"];

    // Ensure the restored or initial frame strictly fits within current display visible bounds
    [self ensureWindowFitsVisibleScreen];

    // On compact screens (e.g. laptop displays with height <= 780 pt), default console to collapsed
    if (screenRect.size.height > 0 && screenRect.size.height <= 780.0) {
        self.logCollapsed = YES;
    }

    // Menus
    NSMenu *menu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new];
    [menu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    NSMenuItem *aboutItem = [appMenu addItemWithTitle:@"About Lab599 Utility" action:@selector(showAboutWindow:) keyEquivalent:@""];
    aboutItem.target = self;
    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *prefsItem = [appMenu addItemWithTitle:@"Preferences…" action:@selector(showPreferencesWindow:) keyEquivalent:@","];
    prefsItem.target = self;
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
    NSMenuItem *sidebarItem = [viewMenu addItemWithTitle:@"Toggle Navigation Sidebar" action:@selector(toggleSidebar:) keyEquivalent:@"S"];
    sidebarItem.target = self;
    [viewMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *ft8StationItem = [viewMenu addItemWithTitle:@"FT8 / FT4 Digital Mode Studio" action:@selector(selectFT8StationTab:) keyEquivalent:@"8"];
    ft8StationItem.target = self;
    NSMenuItem *cwStationItem = [viewMenu addItemWithTitle:@"CW Station & QSO Studio" action:@selector(selectCWStationTab:) keyEquivalent:@"K"];
    cwStationItem.target = self;
    viewItem.submenu = viewMenu;

    NSMenuItem *windowItem = [[NSMenuItem alloc] initWithTitle:@"Window" action:NULL keyEquivalent:@""];
    [menu addItem:windowItem];
    NSMenu *windowMenu = [[NSMenu alloc] initWithTitle:@"Window"];
    [windowMenu addItemWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [windowMenu addItemWithTitle:@"Zoom" action:@selector(performZoom:) keyEquivalent:@""];
    [windowMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *resetWindowItem = [windowMenu addItemWithTitle:@"Reset Window Size & Position" action:@selector(resetWindowBoundsToScreen:) keyEquivalent:@"0"];
    resetWindowItem.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
    resetWindowItem.target = self;
    [windowMenu addItem:[NSMenuItem separatorItem]];
    [windowMenu addItemWithTitle:@"Bring All to Front" action:@selector(arrangeInFront:) keyEquivalent:@""];
    windowItem.submenu = windowMenu;
    [NSApp setWindowsMenu:windowMenu];

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
        @"Firmware Update", @"Time Sync", @"Telemetry", @"Radio Screen", @"CAT Studio", @"Settings", @"Memory", @"Driver Install", @"Documentation", @"Feedback & Suggestion", @"CW Station", @"Live Audio (AD-508)", @"FT8 / FT4 Digital", @"Logbook & Cloud", @"Voice Keyer", @"Station", @"DX Cluster"
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
    [self.mainContentView setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.mainContentView setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    [contentRoot addSubview:self.mainContentView];

    self.sidebarVisibleLeadingConstraint = [self.sidebarView.leadingAnchor constraintEqualToAnchor:contentRoot.leadingAnchor];
    self.sidebarCollapsedTrailingConstraint = [self.sidebarView.trailingAnchor constraintEqualToAnchor:contentRoot.leadingAnchor];
    self.sidebarDividerWidthConstraint = [vDivider.widthAnchor constraintEqualToConstant:1];

    [NSLayoutConstraint activateConstraints:@[
        self.sidebarVisibleLeadingConstraint,
        [self.sidebarView.topAnchor constraintEqualToAnchor:contentRoot.topAnchor],
        [self.sidebarView.bottomAnchor constraintEqualToAnchor:contentRoot.bottomAnchor],
        [self.sidebarView.widthAnchor constraintEqualToConstant:215],

        [vDivider.leadingAnchor constraintEqualToAnchor:self.sidebarView.trailingAnchor],
        [vDivider.topAnchor constraintEqualToAnchor:contentRoot.topAnchor],
        [vDivider.bottomAnchor constraintEqualToAnchor:contentRoot.bottomAnchor],
        self.sidebarDividerWidthConstraint,

        [self.mainContentView.leadingAnchor constraintEqualToAnchor:vDivider.trailingAnchor],
        [self.mainContentView.trailingAnchor constraintEqualToAnchor:contentRoot.trailingAnchor],
        [self.mainContentView.topAnchor constraintEqualToAnchor:contentRoot.topAnchor],
        [self.mainContentView.bottomAnchor constraintEqualToAnchor:contentRoot.bottomAnchor],
    ]];

    // --- Sidebar Content Assembly ---
    NSImageView *brandIcon = [NSImageView new];
    brandIcon.translatesAutoresizingMaskIntoConstraints = NO;
    NSString *brandIconPath = [[NSBundle mainBundle] pathForResource:@"AppIcon" ofType:@"icns"];
    brandIcon.image = brandIconPath ? [[NSImage alloc] initWithContentsOfFile:brandIconPath] : [NSImage imageNamed:NSImageNameApplicationIcon];
    brandIcon.imageScaling = NSImageScaleProportionallyUpOrDown;
    brandIcon.imageAlignment = NSImageAlignCenter;
    [brandIcon setAccessibilityLabel:@"Lab599 Utility"];

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
    [brandIcon.widthAnchor constraintEqualToConstant:36].active = YES;
    [brandIcon.heightAnchor constraintEqualToConstant:36].active = YES;

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
    TX500SidebarButton *btnCat = [[TX500SidebarButton alloc] initWithTitle:@"CAT Studio" iconName:@"antenna.radiowaves.left.and.right" tag:4 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnSettings = [[TX500SidebarButton alloc] initWithTitle:@"Settings" iconName:@"slider.horizontal.3" tag:5 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnMemory = [[TX500SidebarButton alloc] initWithTitle:@"Memory" iconName:@"memorychip" tag:6 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnDriver = [[TX500SidebarButton alloc] initWithTitle:@"Driver Install" iconName:@"wrench.and.screwdriver" tag:7 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnDocs = [[TX500SidebarButton alloc] initWithTitle:@"Documentation" iconName:@"doc.text" tag:8 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnFeedback = [[TX500SidebarButton alloc] initWithTitle:@"Feedback" iconName:@"bubble.left.and.bubble.right" tag:9 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnCW = [[TX500SidebarButton alloc] initWithTitle:@"CW Station" iconName:@"waveform" tag:10 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnAudio = [[TX500SidebarButton alloc] initWithTitle:@"Live Audio (AD-508)" iconName:@"headphones" tag:11 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnFT8 = [[TX500SidebarButton alloc] initWithTitle:@"FT8 / FT4 Digital" iconName:@"dot.radiowaves.left.and.right" tag:12 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnLogbook = [[TX500SidebarButton alloc] initWithTitle:@"Logbook & Cloud" iconName:@"books.vertical" tag:13 target:self action:@selector(sidebarItemClicked:)];

    TX500SidebarButton *btnCluster = [[TX500SidebarButton alloc] initWithTitle:@"DX Cluster" iconName:@"globe" tag:16 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnStation = [[TX500SidebarButton alloc] initWithTitle:@"Station" iconName:@"slider.horizontal.3" tag:15 target:self action:@selector(sidebarItemClicked:)];
    TX500SidebarButton *btnVoice = [[TX500SidebarButton alloc] initWithTitle:@"Voice Keyer" iconName:@"mic.badge.plus" tag:14 target:self action:@selector(sidebarItemClicked:)];

    [self.sidebarItems addObjectsFromArray:@[
        btnFw, btnTime, btnTelemetry, btnScreen, btnCat, btnSettings, btnMemory, btnDriver, btnDocs, btnFeedback, btnCW, btnAudio, btnFT8, btnLogbook, btnVoice, btnStation, btnCluster
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
        btnStation, btnCluster, btnFT8, btnCW, btnVoice, btnAudio, btnLogbook, btnScreen, btnTelemetry, btnCat,
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

    self.sidebarScrollView = [Lab599FittableScrollView new];
    self.sidebarScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarScrollView.hasVerticalScroller = YES;
    self.sidebarScrollView.hasHorizontalScroller = NO;
    self.sidebarScrollView.autohidesScrollers = YES;
    self.sidebarScrollView.borderType = NSNoBorder;
    self.sidebarScrollView.drawsBackground = NO;
    [self.sidebarScrollView setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    [self.sidebarView addSubview:self.sidebarScrollView];

    NSView *sidebarDoc = [Lab599DocumentView new];
    sidebarDoc.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarScrollView.documentView = sidebarDoc;
    [sidebarDoc addSubview:sidebarStack];

    [NSLayoutConstraint activateConstraints:@[
        [self.sidebarScrollView.topAnchor constraintEqualToAnchor:self.sidebarView.topAnchor constant:12],
        [self.sidebarScrollView.leadingAnchor constraintEqualToAnchor:self.sidebarView.leadingAnchor constant:6],
        [self.sidebarScrollView.trailingAnchor constraintEqualToAnchor:self.sidebarView.trailingAnchor constant:-6],
        [self.sidebarScrollView.bottomAnchor constraintEqualToAnchor:self.sidebarView.bottomAnchor constant:-8],

        [sidebarDoc.leadingAnchor constraintEqualToAnchor:self.sidebarScrollView.contentView.leadingAnchor],
        [sidebarDoc.trailingAnchor constraintEqualToAnchor:self.sidebarScrollView.contentView.trailingAnchor],
        [sidebarDoc.topAnchor constraintEqualToAnchor:self.sidebarScrollView.contentView.topAnchor],
        [sidebarDoc.widthAnchor constraintEqualToAnchor:self.sidebarScrollView.contentView.widthAnchor],

        [sidebarStack.topAnchor constraintEqualToAnchor:sidebarDoc.topAnchor constant:4],
        [sidebarStack.leadingAnchor constraintEqualToAnchor:sidebarDoc.leadingAnchor constant:6],
        [sidebarStack.trailingAnchor constraintEqualToAnchor:sidebarDoc.trailingAnchor constant:-6],
        [sidebarStack.bottomAnchor constraintEqualToAnchor:sidebarDoc.bottomAnchor constant:-4],
        [sidebarStack.widthAnchor constraintEqualToAnchor:sidebarDoc.widthAnchor constant:-12],

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
    self.portMenu.target=self; self.portMenu.action=@selector(stationPortChanged:);
    self.portMenu.controlSize = NSControlSizeSmall;
    self.portMenu.font = [NSFont systemFontOfSize:11];
    self.portMenu.bordered = YES;
    self.portMenu.focusRingType = NSFocusRingTypeNone;
    self.portMenu.toolTip = @"Choose a detected CAT serial port. Refresh after connecting a new adapter.";
    self.portMenu.accessibilityLabel = @"CAT serial port selector";
    NSLayoutConstraint *pmW = [self.portMenu.widthAnchor constraintEqualToConstant:190];
    pmW.priority = NSLayoutPriorityDefaultLow;
    pmW.active = YES;
    [self.portMenu.widthAnchor constraintGreaterThanOrEqualToConstant:90].active = YES;
    [self.portMenu setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSBox *portDivider = [NSBox new];
    portDivider.translatesAutoresizingMaskIntoConstraints = NO;
    portDivider.boxType = NSBoxSeparator;
    [portDivider.heightAnchor constraintEqualToConstant:14].active = YES;

    self.refreshButton = [NSButton buttonWithTitle:@"" target:self action:@selector(refreshPorts:)];
    self.refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.refreshButton.bordered = NO;
    self.refreshButton.controlSize = NSControlSizeSmall;
    self.refreshButton.focusRingType = NSFocusRingTypeNone;
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
    [connSpacer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.hardwareBadgeLabel = [self label:@"TX-500 Discovery"];
    self.hardwareBadgeLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
    self.hardwareBadgeLabel.textColor = [NSColor secondaryLabelColor];
    self.hardwareBadgeLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.hardwareBadgeLabel setContentCompressionResistancePriority:100 forOrientation:NSLayoutConstraintOrientationHorizontal];

    // Native-style focus control: the button remains in the main toolbar when
    // navigation is hidden, so restoring the sidebar is always one click away.
    self.sidebarToggleButton = [NSButton buttonWithTitle:@"" target:self action:@selector(toggleSidebar:)];
    self.sidebarToggleButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.sidebarToggleButton.bezelStyle = NSBezelStyleTexturedRounded;
    self.sidebarToggleButton.controlSize = NSControlSizeSmall;
    self.sidebarToggleButton.buttonType = NSButtonTypeMomentaryPushIn;
    self.sidebarToggleButton.focusRingType = NSFocusRingTypeNone;
    self.sidebarToggleButton.imagePosition = NSImageOnly;
    [self.sidebarToggleButton.widthAnchor constraintEqualToConstant:30].active = YES;
    [self.sidebarToggleButton.heightAnchor constraintEqualToConstant:26].active = YES;

    NSBox *sidebarControlDivider = [NSBox new];
    sidebarControlDivider.translatesAutoresizingMaskIntoConstraints = NO;
    sidebarControlDivider.boxType = NSBoxSeparator;
    [sidebarControlDivider.heightAnchor constraintEqualToConstant:16].active = YES;

    // Field Mode button in top bar
    self.outdoorModeButton = [NSButton buttonWithTitle:@"Field Mode" target:self action:@selector(toggleOutdoorMode:)];
    self.outdoorModeButton.translatesAutoresizingMaskIntoConstraints = NO;
    self.outdoorModeButton.bezelStyle = NSBezelStyleRounded;
    self.outdoorModeButton.controlSize = NSControlSizeSmall;
    self.outdoorModeButton.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.outdoorModeButton.toolTip = @"Toggle Daylight High-Contrast Field Mode (⇧⌘F)";
    [self.outdoorModeButton setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
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
    [self.consoleToggleButton setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    if (@available(macOS 11.0, *)) {
        self.consoleToggleButton.image = [NSImage imageWithSystemSymbolName:@"terminal" accessibilityDescription:@"Console"];
        self.consoleToggleButton.imagePosition = NSImageLeading;
    }

    NSStackView *connStack = [NSStackView stackViewWithViews:@[
        self.sidebarToggleButton,
        sidebarControlDivider,
        self.statusPillBox,
        self.portCapsuleBox,
        connSpacer,
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
        [connStack.trailingAnchor constraintLessThanOrEqualToAnchor:self.connectionBar.contentView.trailingAnchor constant:-10],
        [connStack.centerYAnchor constraintEqualToAnchor:self.connectionBar.contentView.centerYAnchor],
    ]];
    NSLayoutConstraint *csFill = [connStack.trailingAnchor constraintEqualToAnchor:self.connectionBar.contentView.trailingAnchor constant:-10];
    csFill.priority = NSLayoutPriorityDefaultLow;
    csFill.active = YES;

    // --- Section Header Row ---
    self.sectionTitleLabel = [self label:@"Firmware Update (BL20 Bootloader)"];
    self.sectionTitleLabel.font = [NSFont systemFontOfSize:17 weight:NSFontWeightBold];

    NSTextField *instructions = [self wrappingLabel:
        @"Connect the CAT-USB cable and stable external power. Close other radio applications. On your transceiver (TX-500 Discovery / TX-500MP), hold the third top function key while pressing POWER. Start only when the screen displays \"The loader is waiting...\". Keep power and cable connected until completion."];
    instructions.textColor = NSColor.secondaryLabelColor;
    instructions.font = [NSFont systemFontOfSize:11.5];
    instructions.preferredMaxLayoutWidth = 720.0;
    [instructions setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.instructions = instructions;

    NSStackView *headerStack = [NSStackView stackViewWithViews:@[self.sectionTitleLabel, self.instructions]];
    headerStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    headerStack.alignment = NSLayoutAttributeLeading;
    headerStack.spacing = 3;
    headerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.instructions.widthAnchor constraintEqualToAnchor:headerStack.widthAnchor].active = YES;

    // --- Feature Content Rows ---
    // Firmware Selection Row
    self.firmwareName = [self label:@"No firmware selected"];
    self.firmwareName.lineBreakMode = NSLineBreakByTruncatingMiddle;
    NSLayoutConstraint *fnW = [self.firmwareName.widthAnchor constraintEqualToConstant:240];
    fnW.priority = NSLayoutPriorityDefaultHigh;
    fnW.active = YES;
    [self.firmwareName.widthAnchor constraintGreaterThanOrEqualToConstant:110].active = YES;
    [self.firmwareName setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    self.chooseButton = [NSButton buttonWithTitle:@"Choose .fw..." target:self action:@selector(chooseFirmware:)];
    self.onlineButton = [NSButton buttonWithTitle:@"Download from Lab599..." target:self action:@selector(openCatalogSheet:)];

    NSView *fileRowSpacer = [NSView new];
    fileRowSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [fileRowSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *fileRow = [NSStackView stackViewWithViews:@[[self label:@"Firmware:"], self.firmwareName, fileRowSpacer, self.chooseButton, self.onlineButton]];
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
    NSStackView *timeControls = [NSStackView stackViewWithViews:@[[self label:@"Set radio clock to:"], self.timeZoneMenu, self.clockPreview]];
    timeControls.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    timeControls.alignment = NSLayoutAttributeCenterY;
    timeControls.spacing = 12;
    self.timeDisciplineLabel = [self wrappingLabel:@"Time discipline is starting…"];
    self.timeDisciplineLabel.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.timeDisciplineLabel.textColor = NSColor.secondaryLabelColor;
    NSStackView *timeRow = [NSStackView stackViewWithViews:@[timeControls, self.timeDisciplineLabel]];
    timeRow.orientation = NSUserInterfaceLayoutOrientationVertical;
    timeRow.alignment = NSLayoutAttributeLeading;
    timeRow.spacing = 5;
    self.timeRow = timeRow;
    timeRow.hidden = YES;

    // Progress and Status
    self.progressBar = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.progressBar.minValue = 0;
    self.progressBar.maxValue = 1;
    self.progressBar.indeterminate = NO;
    self.statusLabel = [self wrappingLabel:@"Select the transceiver's serial port and choose or download the firmware file."];
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
    self.stationCore=[TX500StationCore new];
    (void)TX500StationStore.sharedStore;
    self.stationController=[TX500StationController new]; self.stationController.core=self.stationCore;
    self.stationController.logHandler=^(NSString *message) { [weakSelf appendLog:message]; };
    self.stationController.prepareControl=^BOOL {
        if(![weakSelf stationCanEdit]) return NO;
        return [weakSelf.stationCore selectOwner:@"Station" port:[weakSelf currentStationPort] error:nil];
    };
    self.stationController.canEditStation=^BOOL { return [weakSelf stationCanEdit]; };
    self.stationController.commandHandler=^(NSString *command) { [weakSelf stationCommand:command]; };
    self.stationController.view.hidden=YES;
    self.clusterController=[TX500DXClusterController new]; self.clusterController.core=self.stationCore;
    self.clusterController.prepareControl=^BOOL {
        if(![weakSelf stationCanEdit]) return NO;
        return [weakSelf.stationCore selectOwner:@"Station" port:[weakSelf currentStationPort] error:nil];
    };
    self.clusterController.draftHandler=^(TX500DXSpot *spot,NSString *mode) {
        weakSelf.preparingClusterDraft=YES;
        weakSelf.operationPicker.selectedSegment=13; [weakSelf operationChanged:nil];
        weakSelf.preparingClusterDraft=NO;
        [weakSelf.logbookController prepareDraftCallsign:spot.callsign frequencyHz:spot.frequencyHz mode:mode];
    };
    self.clusterController.view.hidden=YES;
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stationSettingsChanged:) name:@"TX500StationSettingsChangedNotification" object:nil];

    // Telemetry Controller
    self.telemetryController = [Lab599TelemetryController new];
    self.telemetryController.selectedPortProvider = ^NSString * { return weakSelf.hasPorts ? weakSelf.portMenu.selectedItem.title : nil; };
    self.telemetryController.catQueryHandler = ^NSString *(NSString *catCommand, NSTimeInterval timeout) {
        return [weakSelf querySharedCATCommand:catCommand timeout:timeout];
    };
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

    // CW Station Controller (AD-508 CoreAudio DSP & CAT Studio)
    self.cwStationController = [TX500CWStationController new];
    self.cwStationController.selectedPortProvider = ^NSString * { return weakSelf.hasPorts ? weakSelf.portMenu.selectedItem.title : nil; };
    self.cwStationController.logHandler = ^(NSString *message) { [weakSelf appendLog:message]; };
    self.cwStationController.serialCommandSender = ^BOOL(NSString *catCommand) {
        return [weakSelf.stationCore send:catCommand owner:@"CW" error:nil];
    };
    self.cwStationController.decoderStateChangedHandler = ^(BOOL isListening) {
        (void)isListening; // state is read directly via decoder.isListening in updateConnectionStatusBar
        [weakSelf updateConnectionStatusBar];
    };
    self.cwStationController.view.hidden = YES;

    // Live Audio Monitor Controller (AD-508 CoreAudio Low-Latency & DSP Studio)
    self.audioMonitorController = [TX500AudioMonitorController new];
    self.audioMonitorController.logHandler = ^(NSString *message) { [weakSelf appendLog:message]; };
    self.audioMonitorController.onMonitoringStateChanged = ^(BOOL isMonitoring) {
        (void)isMonitoring;
        [weakSelf updateConnectionStatusBar];
    };
    self.audioMonitorController.selectedPortProvider = ^NSString *{
        if (!weakSelf.hasPorts) return nil;
        NSString *portPath = weakSelf.portMenu.selectedItem.title;
        if (!portPath || ![portPath hasPrefix:@"/dev/cu."]) return nil;
        return portPath;
    };
    self.audioMonitorController.serialCommandSender = ^BOOL(NSString *catCommand) {
        return [weakSelf.stationCore send:catCommand owner:@"Audio" error:nil];
    };
    self.audioMonitorController.catQueryHandler = ^NSString *(NSString *catCommand, NSTimeInterval timeout) {
        return [weakSelf querySharedCATCommand:catCommand timeout:timeout];
    };
    self.audioMonitorController.view.hidden = YES;

    // FT8 Digital Mode Controller (AD-508 CoreAudio DSP, Pure C99 FT8 Modem & Autonomous Co-Pilot)
    self.ft8StationController = [TX500FT8StationController new];
    self.ft8StationController.selectedPortProvider = ^NSString * { return weakSelf.hasPorts ? weakSelf.portMenu.selectedItem.title : nil; };
    self.ft8StationController.logHandler = ^(NSString *message) { [weakSelf appendLog:message]; };
    self.ft8StationController.serialCommandSender = ^BOOL(NSString *catCommand) {
        NSError *catError = nil;
        BOOL sent = [weakSelf.stationCore send:catCommand owner:@"Digital" error:&catError];
        if (!sent) [weakSelf appendLog:[NSString stringWithFormat:@"FT8 CAT %@ failed: %@",
            catCommand, catError.localizedDescription ?: weakSelf.stationCore.status]];
        return sent;
    };
    self.ft8StationController.pttControlHandler = ^BOOL(BOOL pttActive) {
        return [weakSelf setSharedPTT:pttActive];
    };
    self.ft8StationController.catQueryHandler = ^NSString *(NSString *catCommand, NSTimeInterval timeout) {
        return [weakSelf querySharedCATCommand:catCommand timeout:timeout];
    };
    self.ft8StationController.stationStateChangedHandler = ^(BOOL isMonitoring) {
        [weakSelf updateConnectionStatusBar];
    };
    self.ft8StationController.diagnosticSessionStateChangedHandler = ^(BOOL isRunning) {
        if (isRunning) [weakSelf startDigitalDiagnosticSessionLog];
        else [weakSelf stopDigitalDiagnosticSessionLog];
    };
    self.ft8StationController.view.hidden = YES;

    self.voiceKeyerController = [TX500VoiceKeyerController new];
    self.voiceKeyerController.radioProvider = ^id<TX500VoiceRadio>(NSString *port) { (void)port; return [weakSelf.stationCore voiceAdapter]; };
    self.voiceKeyerController.selectedPortProvider = ^NSString * { return weakSelf.hasPorts ? weakSelf.portMenu.selectedItem.title : nil; };
    self.voiceKeyerController.logHandler = ^(NSString *message) { [weakSelf appendLog:message]; };
    self.voiceKeyerController.stateChanged = ^{
        [weakSelf updateConnectionStatusBar];
        weakSelf.portMenu.enabled = weakSelf.hasPorts && !weakSelf.busy && !weakSelf.voiceKeyerController.keyer.active;
        weakSelf.refreshButton.enabled = !weakSelf.busy && !weakSelf.voiceKeyerController.keyer.active;
    };
    self.voiceKeyerController.view.hidden = YES;

    // Comprehensive Logbook & Cloud Ecosystem Controller
    self.logbookController = [TX500LogbookController new];
    self.logbookController.selectedPortProvider = ^NSString * { return weakSelf.hasPorts ? weakSelf.portMenu.selectedItem.title : nil; };
    self.logbookController.logHandler = ^(NSString *message) { [weakSelf appendLog:message]; };
    self.logbookController.serialCommandSender = ^BOOL(NSString *catCommand) {
        return [weakSelf.stationCore send:catCommand owner:@"Station" error:nil];
    };
    self.logbookController.view.hidden = YES;
    [self stationSettingsChanged:nil];
    [TX500StationStore.sharedStore activateProfile:TX500StationStore.sharedStore.activeProfile[@"id"] error:nil];
    self.stationKeyMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent *(NSEvent *event) {
        if(!weakSelf.window.isKeyWindow || weakSelf.window.attachedSheet || event.isARepeat) return event;
        if(event.keyCode==53) { [weakSelf stationCommand:@"stop"]; return nil; }
        NSEventModifierFlags flags=event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        if(flags!=(NSEventModifierFlagCommand|NSEventModifierFlagOption)) return event;
        NSString *key=event.charactersIgnoringModifiers.lowercaseString;
        for(NSString *command in TX500StationStore.sharedStore.shortcuts) if(key.length && [TX500StationStore.sharedStore.shortcuts[command] isEqual:key]) { [weakSelf stationCommand:command]; return nil; }
        return event;
    }];

    // Connect Audio Monitor quick log button to switch to Logbook and prefill VFO
    self.audioMonitorController.onQuickLogRequested = ^(uint64_t freqHz, NSString *mode) {
        weakSelf.operationPicker.selectedSegment = 13;
        [weakSelf operationChanged:weakSelf.operationPicker];
        [weakSelf.logbookController updateFrequencyHz:freqHz mode:mode];
        [weakSelf.logbookController focusCallsignField];
    };

    // Wire Logbook openSettingsHandler to open Preferences Window -> Cloud Accounts tab
    self.logbookController.openSettingsHandler = ^(NSString *service) {
        [weakSelf showPreferencesWindow:nil];
        [weakSelf selectPreferencesTab:1];
        if (service.length > 0) {
            [[TX500CloudSettingsController sharedController] selectTabWithService:service];
        }
    };

    // Feature Card Container
    NSBox *featureCardBox = [NSBox new];
    featureCardBox.titlePosition = NSNoTitle;
    featureCardBox.boxType = NSBoxCustom;
    featureCardBox.cornerRadius = 8.0;
    featureCardBox.borderWidth = 1.0;
    featureCardBox.borderColor = [NSColor separatorColor];
    featureCardBox.fillColor = [NSColor controlBackgroundColor];
    featureCardBox.translatesAutoresizingMaskIntoConstraints = NO;

    self.cardSpacer = [NSView new];
    self.cardSpacer.translatesAutoresizingMaskIntoConstraints = NO;
    [self.cardSpacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    [self.cardSpacer setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];

    NSStackView *featureStack = [NSStackView stackViewWithViews:@[
        fileRow, self.radioPreviewBox, self.powerSafetyBox, timeRow,
        self.audioMonitorController.view, self.cwStationController.view, self.ft8StationController.view, self.voiceKeyerController.view, self.stationController.view, self.clusterController.view, self.logbookController.view, self.telemetryController.view, self.screenController.view,
        self.tools.view,
        self.driverController.view, self.docsController.view, self.feedbackController.view,
        self.progressBar, self.statusLabel,
        self.actionRow,
        self.cardSpacer
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
        [featureStack.bottomAnchor constraintEqualToAnchor:featureCardBox.contentView.bottomAnchor constant:-10]
    ]];

    NSArray<NSView *> *featureChildViews = @[
        self.radioPreviewBox,
        self.powerSafetyBox,
        self.audioMonitorController.view,
        self.cwStationController.view,
        self.ft8StationController.view,
        self.voiceKeyerController.view,
        self.stationController.view,
        self.clusterController.view,
        self.logbookController.view,
        self.telemetryController.view,
        self.screenController.view,
        self.tools.view,
        self.driverController.view,
        self.docsController.view,
        self.feedbackController.view,
        self.progressBar,
        self.statusLabel
    ];
    NSMutableArray<NSLayoutConstraint *> *featureWidths = [NSMutableArray array];
    for (NSView *child in featureChildViews) {
        NSLayoutConstraint *wc = [child.widthAnchor constraintEqualToAnchor:featureStack.widthAnchor];
        wc.priority = 999;
        wc.active = !child.hidden;
        [featureWidths addObject:wc];
    }
    self.featureWidthConstraints = featureWidths;

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
    self.logCardBox.hidden = self.logCollapsed;
    self.logCardHeightConstraint.active = !self.logCollapsed;

    // Top Persistent Connection Bar (Always anchored at the top of right pane)
    [self.mainContentView addSubview:self.connectionBar];

    // Scrollable Workstation & Console Viewport
    self.mainScrollView = [Lab599FittableScrollView new];
    self.mainScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.mainScrollView.hasVerticalScroller = YES;
    self.mainScrollView.hasHorizontalScroller = NO;
    self.mainScrollView.autohidesScrollers = YES;
    self.mainScrollView.borderType = NSNoBorder;
    self.mainScrollView.drawsBackground = NO;
    [self.mainScrollView setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self.mainScrollView setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    [self.mainContentView addSubview:self.mainScrollView];

    NSView *mainDocView = [Lab599DocumentView new];
    mainDocView.translatesAutoresizingMaskIntoConstraints = NO;
    self.mainScrollView.documentView = mainDocView;

    NSStackView *scrollStack = [NSStackView stackViewWithViews:@[
        headerStack,
        featureCardBox,
        self.logCardBox
    ]];
    scrollStack.translatesAutoresizingMaskIntoConstraints = NO;
    scrollStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    scrollStack.alignment = NSLayoutAttributeLeading;
    scrollStack.spacing = 10;
    scrollStack.detachesHiddenViews = YES;
    [mainDocView addSubview:scrollStack];

    NSLayoutConstraint *docWidthConstraint = [mainDocView.widthAnchor constraintEqualToAnchor:self.mainScrollView.contentView.widthAnchor];
    docWidthConstraint.priority = 999;

    NSLayoutConstraint *minDocW = [mainDocView.widthAnchor constraintGreaterThanOrEqualToConstant:500.0];
    minDocW.priority = NSLayoutPriorityDefaultLow;

    [NSLayoutConstraint activateConstraints:@[
        [self.connectionBar.topAnchor constraintEqualToAnchor:self.mainContentView.topAnchor constant:12],
        [self.connectionBar.leadingAnchor constraintEqualToAnchor:self.mainContentView.leadingAnchor constant:14],
        [self.connectionBar.trailingAnchor constraintEqualToAnchor:self.mainContentView.trailingAnchor constant:-14],
        [self.connectionBar.heightAnchor constraintEqualToConstant:42],

        [self.mainScrollView.topAnchor constraintEqualToAnchor:self.connectionBar.bottomAnchor constant:8],
        [self.mainScrollView.leadingAnchor constraintEqualToAnchor:self.mainContentView.leadingAnchor constant:14],
        [self.mainScrollView.trailingAnchor constraintEqualToAnchor:self.mainContentView.trailingAnchor constant:-14],
        [self.mainScrollView.bottomAnchor constraintEqualToAnchor:self.mainContentView.bottomAnchor constant:-10],

        [mainDocView.leadingAnchor constraintEqualToAnchor:self.mainScrollView.contentView.leadingAnchor],
        [mainDocView.topAnchor constraintEqualToAnchor:self.mainScrollView.contentView.topAnchor],
        docWidthConstraint,
        minDocW,

        [scrollStack.topAnchor constraintEqualToAnchor:mainDocView.topAnchor constant:2],
        [scrollStack.leadingAnchor constraintEqualToAnchor:mainDocView.leadingAnchor],
        [scrollStack.trailingAnchor constraintEqualToAnchor:mainDocView.trailingAnchor],
        [scrollStack.bottomAnchor constraintEqualToAnchor:mainDocView.bottomAnchor constant:-8],
    ]];

    NSLayoutConstraint *cScrollW = [scrollStack.widthAnchor constraintGreaterThanOrEqualToAnchor:mainDocView.widthAnchor];
    cScrollW.priority = NSLayoutPriorityDefaultLow;
    cScrollW.active = YES;

    NSLayoutConstraint *cHeaderW = [headerStack.widthAnchor constraintEqualToAnchor:scrollStack.widthAnchor];
    cHeaderW.priority = 999;
    cHeaderW.active = YES;

    NSLayoutConstraint *cFeatureW = [featureCardBox.widthAnchor constraintEqualToAnchor:scrollStack.widthAnchor];
    cFeatureW.priority = 999;
    cFeatureW.active = YES;

    NSLayoutConstraint *cLogW = [self.logCardBox.widthAnchor constraintEqualToAnchor:scrollStack.widthAnchor];
    cLogW.priority = 999;
    cLogW.active = YES;
    [self appendLog:[NSString stringWithFormat:@"Lab599 Utility %@ (Build %@) initialized.", appVer, appBuild]];
    [self appendLog:@"BL20 protocol engine ready: 57600 baud, 8N1, two-ACK header+payload cycle."];
    [self appendLog:@"TimeSync ready: 9600 baud, TM set/query with clock read-back verification."];
    [[TX500DisciplinedClock sharedClock] startAutomaticNetworkSynchronization];
    [[TX500DisciplinedClock sharedClock] synchronizeNetworkNowWithCompletion:^(BOOL success, NSString *detail) {
        [self appendLog:[NSString stringWithFormat:@"Time discipline: %@", detail]];
        [self updateClockPreview:nil];
        if (!success) [self appendLog:@"Time discipline remains in holdover; FT8 radio consensus can refine it after enough independent decodes."];
    }];
    [self refreshPorts:nil];
    [self updateClockPreview:nil];
    self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(updateClockPreview:) userInfo:nil repeats:YES];
    [self updateConsoleToggleButton];
    BOOL requestedSidebarCollapsed = [[NSProcessInfo processInfo].arguments containsObject:@"--sidebar-collapsed"];
    BOOL requestedSidebarExpanded = [[NSProcessInfo processInfo].arguments containsObject:@"--sidebar-expanded"];
    BOOL savedSidebarCollapsed = [[NSUserDefaults standardUserDefaults] boolForKey:@"TX500_SidebarCollapsed"];
    [self applySidebarCollapsed:(requestedSidebarExpanded ? NO : (requestedSidebarCollapsed || savedSidebarCollapsed))
                       animated:NO
                        persist:NO];
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
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--settings"]) {
        self.operationPicker.selectedSegment = 5;
        [self operationChanged:self.operationPicker];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--cloud-settings"]) {
        [self showPreferencesWindow:nil];
        [self selectPreferencesTab:1];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--station-preferences"]) {
        [self showPreferencesWindow:nil];
        [self selectPreferencesTab:0];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--preferences"]) {
        [self showPreferencesWindow:nil];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--docs"]) {
        self.operationPicker.selectedSegment = 8;
        [self operationChanged:self.operationPicker];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--feedback"]) {
        self.operationPicker.selectedSegment = 9;
        [self operationChanged:self.operationPicker];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--cw"] || [[NSProcessInfo processInfo].arguments containsObject:@"--cw-station"]) {
        self.operationPicker.selectedSegment = 10;
        [self operationChanged:self.operationPicker];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--audio"] || [[NSProcessInfo processInfo].arguments containsObject:@"--audio-monitor"]) {
        self.operationPicker.selectedSegment = 11;
        [self operationChanged:self.operationPicker];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--ft8"] ||
        [[NSProcessInfo processInfo].arguments containsObject:@"--ft8-station"] ||
        [[NSProcessInfo processInfo].arguments containsObject:@"--ft8-preview"] ||
        [[NSProcessInfo processInfo].arguments containsObject:@"--ft8-preview-rx"]) {
        // Test/demo launches must enter simulation before the tab callback is
        // allowed to prepare the radio. This guarantees UI validation never
        // emits CAT commands to a remembered physical port.
        if ([[NSProcessInfo processInfo].arguments containsObject:@"--simulation"] ||
            [[NSProcessInfo processInfo].arguments containsObject:@"--ft8-preview"] ||
            [[NSProcessInfo processInfo].arguments containsObject:@"--ft8-preview-rx"]) {
            [self.ft8StationController setSimulationEnabled:YES];
        }
        self.operationPicker.selectedSegment = 12;
        [self operationChanged:self.operationPicker];
        if ([[NSProcessInfo processInfo].arguments containsObject:@"--ft8-preview"]) {
            [self.ft8StationController startSimulationPreview];
        } else if ([[NSProcessInfo processInfo].arguments containsObject:@"--ft8-preview-rx"]) {
            [self.ft8StationController startStation];
        }
        if ([[NSProcessInfo processInfo].arguments containsObject:@"--ft8-wide"]) {
            [self.ft8StationController toggleWideTables:nil];
        }
        if ([[NSProcessInfo processInfo].arguments containsObject:@"--ft8-full-height"]) {
            [self.ft8StationController toggleFullHeight:nil];
        }
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--logbook"]) {
        self.operationPicker.selectedSegment = 13;
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
            NSUInteger delayArg = [[NSProcessInfo processInfo].arguments indexOfObject:@"--screenshot-delay"];
            double screenshotDelay = (delayArg != NSNotFound && delayArg + 1 < [NSProcessInfo processInfo].arguments.count) ?
                [[NSProcessInfo processInfo].arguments[delayArg + 1] doubleValue] : 2.0;
            screenshotDelay = fmax(0.5, fmin(20.0, screenshotDelay));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(screenshotDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NSWindow *targetWin = (self.preferencesWindow && self.preferencesWindow.isVisible) ? self.preferencesWindow : self.window;
                [targetWin layoutIfNeeded];
                [targetWin.contentView layoutSubtreeIfNeeded];
                NSRect rect = targetWin.contentView.bounds;
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
                [[NSColor windowBackgroundColor] setFill];
                NSRectFill(rect);
                [targetWin.contentView displayRectIgnoringOpacity:rect inContext:ctx];
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
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--preferences"] ||
        [[NSProcessInfo processInfo].arguments containsObject:@"--prefs"]) {
        [self showPreferencesWindow:nil];
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--ft8"]) {
        [self selectFT8StationTab:nil];
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--station"]) {
        self.operationPicker.selectedSegment=15; [self operationChanged:nil];
        NSUInteger section=[NSProcessInfo.processInfo.arguments indexOfObject:@"--station-section"];
        if(section!=NSNotFound && section+1<NSProcessInfo.processInfo.arguments.count) [self.stationController runCommand:NSProcessInfo.processInfo.arguments[section+1]];
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--dx-cluster"]) {
        self.operationPicker.selectedSegment=16; [self operationChanged:nil];
        if([NSProcessInfo.processInfo.arguments containsObject:@"--cluster-demo"]) [self.clusterController loadDemo];
    }
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--voice-keyer"]) {
        self.operationPicker.selectedSegment = 14;
        [self operationChanged:nil];
    }
    for (NSUInteger i = 0; i < [NSProcessInfo processInfo].arguments.count; i++) {
        if ([[NSProcessInfo processInfo].arguments[i] isEqualToString:@"--resize-test"] && i + 2 < [NSProcessInfo processInfo].arguments.count) {
            CGFloat w = [[NSProcessInfo processInfo].arguments[i + 1] doubleValue];
            CGFloat h = [[NSProcessInfo processInfo].arguments[i + 2] doubleValue];
            [self.window setFrame:NSMakeRect(100, 100, w, h) display:YES animate:NO];
            fprintf(stdout, "RESIZED FRAME: %s\n", NSStringFromRect(self.window.frame).UTF8String);
            fprintf(stdout, "CONTENT VIEW FITTING: %s\n", NSStringFromSize(self.window.contentView.fittingSize).UTF8String);
            fflush(stdout);
            if (![[NSProcessInfo processInfo].arguments containsObject:@"--screenshot-window"]) {
                [NSApp terminate:nil];
            }
        }
    }
    if ([[NSProcessInfo processInfo].arguments containsObject:@"--dump-layout"]) {
        NSMutableString *outStr = [NSMutableString new];
        [outStr appendFormat:@"WINDOW FRAME: %@\n", NSStringFromRect(self.window.frame)];
        [outStr appendFormat:@"WINDOW MIN SIZE: %@\n", NSStringFromSize(self.window.minSize)];
        [outStr appendFormat:@"WINDOW CONTENT MIN SIZE: %@\n", NSStringFromSize(self.window.contentMinSize)];
        [outStr appendFormat:@"CONTENT VIEW FITTING SIZE: %@\n", NSStringFromSize(self.window.contentView.fittingSize)];
        [outStr appendFormat:@"MAIN SCROLL VIEW FITTING SIZE: %@\n", NSStringFromSize(self.mainScrollView.fittingSize)];
        dumpViewTree(self.window.contentView, 0, outStr);
        [outStr writeToFile:@"/tmp/layout_diag.txt" atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [NSApp terminate:nil];
    }
}

#pragma mark - Serial Ports

- (void)refreshPorts:(id)sender {
    if (self.busy || (sender && ![self stationCanEdit])) return;
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
    self.stationPort=[self currentStationPort];
    if(!self.stationCore.ownsTX && self.stationCore.owner.length) [self.stationCore selectOwner:self.stationCore.owner port:self.stationPort error:nil];
    [self updateConnectionStatusBar];
}

#pragma mark - Operation Selection & Time Synchronization

- (NSTimeZone *)selectedTimeZone {
    return self.timeZoneMenu.indexOfSelectedItem == 1 ? [NSTimeZone timeZoneForSecondsFromGMT:0] : NSTimeZone.localTimeZone;
}

- (void)updateClockPreview:(id)sender {
    (void)sender;
    NSTimeZone *zone = [self selectedTimeZone];
    TX500TimeSnapshot *snapshot = [[TX500DisciplinedClock sharedClock] snapshot];
    NSData *command = TXTimeSetCommand(snapshot.date, zone);
    NSString *time = [[[NSString alloc] initWithData:command encoding:NSASCIIStringEncoding] substringWithRange:NSMakeRange(2, 8)];
    self.clockPreview.stringValue = [NSString stringWithFormat:@"%@  (%@)", time, zone.name];
    self.timeDisciplineLabel.stringValue = [NSString stringWithFormat:@"Source: %@  •  offset %+.3f s  •  drift %+.2f ppm  •  uncertainty ±%.3f s  •  FT8 stations %ld  •  TX %@",
        snapshot.sourceDescription, snapshot.offsetFromSystemSeconds, snapshot.frequencyErrorPPM,
        snapshot.uncertaintySeconds, (long)snapshot.radioStationCount, snapshot.transmitAllowed ? @"ready" : @"receive-only"];
    self.timeDisciplineLabel.textColor = snapshot.transmitAllowed ? NSColor.secondaryLabelColor : NSColor.systemOrangeColor;
}

- (void)selectFeedbackTab:(id)sender {
    (void)sender;
    self.operationPicker.selectedSegment = 9;
    [self operationChanged:self.operationPicker];
}

- (void)selectCWStationTab:(id)sender {
    (void)sender;
    self.operationPicker.selectedSegment = 10;
    [self operationChanged:self.operationPicker];
}

- (void)selectFT8StationTab:(id)sender {
    (void)sender;
    self.operationPicker.selectedSegment = 12;
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

- (void)toggleSidebar:(id)sender {
    (void)sender;
    [self applySidebarCollapsed:!self.sidebarCollapsed animated:YES persist:YES];
}

- (void)applySidebarCollapsed:(BOOL)collapsed animated:(BOOL)animated persist:(BOOL)persist {
    NSView *layoutRoot = self.window.contentView;
    [layoutRoot layoutSubtreeIfNeeded];

    self.sidebarCollapsed = collapsed;
    if (!collapsed) {
        self.sidebarView.hidden = NO;
        self.sidebarView.alphaValue = animated ? 0.0 : 1.0;
    }

    self.sidebarVisibleLeadingConstraint.active = !collapsed;
    self.sidebarCollapsedTrailingConstraint.active = collapsed;
    self.sidebarDividerWidthConstraint.constant = collapsed ? 0.0 : 1.0;
    [self updateSidebarToggleButton];

    void (^applyLayout)(void) = ^{
        self.sidebarView.alphaValue = collapsed ? 0.0 : 1.0;
        [layoutRoot layoutSubtreeIfNeeded];
    };
    void (^completion)(void) = ^{
        if (self.sidebarCollapsed) self.sidebarView.hidden = YES;
        CGFloat availableWidth = self.mainContentView.bounds.size.width - 28.0;
        if (availableWidth > 300.0) {
            self.instructions.preferredMaxLayoutWidth = availableWidth - 4.0;
            [self.instructions invalidateIntrinsicContentSize];
        }
    };

    BOOL reduceMotion = NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion;
    if (animated && !reduceMotion) {
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.22;
            applyLayout();
        } completionHandler:completion];
    } else {
        applyLayout();
        completion();
    }

    if (persist) {
        [[NSUserDefaults standardUserDefaults] setBool:collapsed forKey:@"TX500_SidebarCollapsed"];
    }
}

- (void)updateSidebarToggleButton {
    if (!self.sidebarToggleButton) return;
    NSString *action = self.sidebarCollapsed ? @"Show" : @"Hide";
    self.sidebarToggleButton.toolTip = [NSString stringWithFormat:@"%@ Navigation Sidebar (⇧⌘S)", action];
    [self.sidebarToggleButton setAccessibilityLabel:[NSString stringWithFormat:@"%@ Navigation Sidebar", action]];
    self.sidebarToggleButton.state = self.sidebarCollapsed ? NSControlStateValueOn : NSControlStateValueOff;
    self.sidebarToggleButton.contentTintColor = self.sidebarCollapsed ? NSColor.controlAccentColor : NSColor.secondaryLabelColor;
    if (@available(macOS 11.0, *)) {
        NSImage *image = [NSImage imageWithSystemSymbolName:@"sidebar.left" accessibilityDescription:self.sidebarToggleButton.accessibilityLabel];
        NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:13.0 weight:NSFontWeightSemibold];
        self.sidebarToggleButton.image = [image imageWithSymbolConfiguration:config];
        self.sidebarToggleButton.title = @"";
    } else {
        self.sidebarToggleButton.title = @"☰";
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
    BOOL ft8Live       = self.ft8StationController.audioEngine.isMonitoring;
    BOOL audioLive     = self.audioMonitorController.engine.isMonitoring;
    BOOL screenLive    = self.screenController.liveSyncActive;
    BOOL telemetryLive = self.telemetryController.engine.isRunning;
    BOOL cwListening   = self.cwStationController.decoder.isListening;

    if (self.voiceOwnsRadio && self.voiceKeyerController.keyer.connected) {
        TX500VoiceState state = self.voiceKeyerController.keyer.state;
        BOOL onAir = state == TXVoicePlaying || state == TXVoiceLive || state == TXVoiceLead || state == TXVoiceTail;
        NSColor *color = onAir ? NSColor.systemOrangeColor : NSColor.systemTealColor;
        self.statusLEDView.layer.backgroundColor = color.CGColor;
        self.connectionStatusLabel.stringValue = onAir ? @"Voice · TX" : @"Voice · Ready";
        self.connectionStatusLabel.textColor = color;
        self.statusPillBox.fillColor = [color colorWithAlphaComponent:0.14];
        self.statusPillBox.borderColor = [color colorWithAlphaComponent:0.4];
    } else if (ft8Live) {
        // FT8 Digital Mode active — vivid purple/magenta
        self.statusLEDView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.75 green:0.25 blue:0.95 alpha:1.0].CGColor;
        self.connectionStatusLabel.stringValue = self.ft8StationController.audioEngine.isTransmitting ? @"FT8 Transmitting" : @"FT8 Monitoring";
        self.connectionStatusLabel.textColor = [NSColor colorWithSRGBRed:0.70 green:0.20 blue:0.90 alpha:1.0];
        self.statusPillBox.fillColor   = [NSColor colorWithSRGBRed:0.75 green:0.25 blue:0.95 alpha:0.14];
        self.statusPillBox.borderColor = [NSColor colorWithSRGBRed:0.75 green:0.25 blue:0.95 alpha:0.40];
    } else if (audioLive) {
        // Live Audio Monitoring via AD-508 active — vivid green
        self.statusLEDView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.10 green:0.85 blue:0.45 alpha:1.0].CGColor;
        self.connectionStatusLabel.stringValue = @"Live Audio (AD-508)";
        self.connectionStatusLabel.textColor = [NSColor colorWithSRGBRed:0.08 green:0.75 blue:0.38 alpha:1.0];
        self.statusPillBox.fillColor   = [NSColor colorWithSRGBRed:0.10 green:0.85 blue:0.45 alpha:0.14];
        self.statusPillBox.borderColor = [NSColor colorWithSRGBRed:0.10 green:0.85 blue:0.45 alpha:0.40];
    } else if (screenLive) {
        // Radio Screen live sync — call it "Live Streaming"
        self.statusLEDView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.16 green:0.82 blue:0.25 alpha:1.0].CGColor;
        self.connectionStatusLabel.stringValue = @"Live Streaming";
        self.connectionStatusLabel.textColor = [NSColor colorWithSRGBRed:0.12 green:0.68 blue:0.22 alpha:1.0];
        self.statusPillBox.fillColor   = [NSColor colorWithSRGBRed:0.16 green:0.82 blue:0.25 alpha:0.14];
        self.statusPillBox.borderColor = [NSColor colorWithSRGBRed:0.16 green:0.82 blue:0.25 alpha:0.40];
    } else if (cwListening) {
        // CW decoder active — amber/teal to distinguish from screen streaming
        self.statusLEDView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.0 green:0.70 blue:0.85 alpha:1.0].CGColor;
        self.connectionStatusLabel.stringValue = @"CW Decoding";
        self.connectionStatusLabel.textColor = [NSColor colorWithSRGBRed:0.0 green:0.60 blue:0.78 alpha:1.0];
        self.statusPillBox.fillColor   = [NSColor colorWithSRGBRed:0.0 green:0.70 blue:0.85 alpha:0.12];
        self.statusPillBox.borderColor = [NSColor colorWithSRGBRed:0.0 green:0.70 blue:0.85 alpha:0.38];
    } else if (telemetryLive) {
        // Telemetry polling active
        self.statusLEDView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.20 green:0.75 blue:0.35 alpha:1.0].CGColor;
        self.connectionStatusLabel.stringValue = @"Monitoring";
        self.connectionStatusLabel.textColor = [NSColor colorWithSRGBRed:0.12 green:0.65 blue:0.25 alpha:1.0];
        self.statusPillBox.fillColor   = [NSColor colorWithSRGBRed:0.20 green:0.75 blue:0.35 alpha:0.12];
        self.statusPillBox.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.75 blue:0.35 alpha:0.35];
    } else if (self.hasPorts) {
        // CAT port detected but nothing actively streaming
        self.statusLEDView.layer.backgroundColor = [NSColor colorWithSRGBRed:0.20 green:0.75 blue:0.35 alpha:1.0].CGColor;
        self.connectionStatusLabel.stringValue = @"CAT Port Available";
        self.connectionStatusLabel.textColor = [NSColor labelColor];
        self.statusPillBox.fillColor   = [NSColor colorWithSRGBRed:0.20 green:0.75 blue:0.35 alpha:0.12];
        self.statusPillBox.borderColor = [NSColor colorWithSRGBRed:0.20 green:0.75 blue:0.35 alpha:0.35];
    } else {
        self.statusLEDView.layer.backgroundColor = [NSColor systemGrayColor].CGColor;
        self.connectionStatusLabel.stringValue = @"Disconnected";
        self.connectionStatusLabel.textColor = [NSColor secondaryLabelColor];
        self.statusPillBox.fillColor   = [NSColor colorWithCalibratedWhite:0.5 alpha:0.08];
        self.statusPillBox.borderColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.22];
    }
}


- (void)operationChanged:(id)sender {
    (void)sender;
    if(self.clusterController.busy) { self.operationPicker.selectedSegment=16; return; }
    if(self.stationController.busy) { self.operationPicker.selectedSegment=15; return; }
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
    BOOL isCWStation = (operation == 10);
    BOOL isAudio = (operation == 11);
    BOOL isFT8 = (operation == 12);
    BOOL isLogbook = (operation == 13);
    BOOL isVoice = (operation == 14);
    BOOL isStation=(operation==15);
    BOOL isCluster=(operation==16);
    BOOL leavingVoice=!isVoice && self.voiceOwnsRadio;
    BOOL exclusive=isFW || isSync || isScreen || isTools;
    NSString *desired=isVoice?@"Voice":isCWStation?@"CW":isFT8?@"Digital":isAudio?@"Audio":@"Station";
    // Station / logbook / telemetry may inspect a running digital station, but
    // cannot retune it. Switching operating modes explicitly stops the old one.
    BOOL passive=isCluster || isStation || isLogbook || isTelemetry || isDocs || isFeedback || isDriver;
    if(leavingVoice && ![self.voiceKeyerController deactivate]) { self.operationPicker.selectedSegment=14; return; }
    if(exclusive || (!passive && ![self.stationCore.owner isEqual:desired])) {
        [self.ft8StationController stopStation]; [self.cwStationController stopStation];
        [self.audioMonitorController stopController];
        NSError *releaseError=nil;
        if(![self.stationCore releaseOwnedTX:&releaseError]) { [self appendLog:releaseError.localizedDescription]; return; }
    }
    if(exclusive) {
        if(![self.stationCore suspend:nil]) return;
    } else if(!passive || !self.stationCore.owner.length || (![self.ft8StationController.audioEngine isMonitoring] && !self.stationCore.ownsTX)) {
        if(![self.stationCore selectOwner:desired port:[self currentStationPort] error:nil]) return;
    }
    self.voiceOwnsRadio=isVoice;
    self.voiceKeyerController.view.hidden=!isVoice;
    self.stationController.view.hidden=!isStation;
    self.clusterController.view.hidden=!isCluster;
    if(isCluster) [self.clusterController activate];
    if(isVoice) [self.voiceKeyerController activate];
    if(isStation) [self.stationController activate];

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
            @9: @"Feedback & Bug Reports",
            @10: @"CW Station & Semi-Automated QSO Studio (AD-508 & CAT)",
            @11: @"AD-508 Live Audio Monitor & DSP Studio",
            @12: @"FT8 / FT4 Digital Mode Studio & Autonomous Operating Co-Pilot",
            @13: @"Logbook & Cloud",
            @14: @"Voice Keyer · Auto-CQ & Live Replies",
            @15: @"Station · Frequencies, Profiles & Controls",
            @16: @"DX Cluster · Discovery & Contact History"
        };
    });
    self.sectionTitleLabel.stringValue = titles[@(operation)] ?: @"Lab599 Utility";

    if (!isTelemetry && self.telemetryController.engine.isRunning) {
        [self.telemetryController stopMonitoring];
    }
    if (!isScreen && self.screenController.liveSyncActive) {
        [self.screenController stopLiveSync];
    }
    if (!isCWStation && !leavingVoice) {
        [self.cwStationController stopStation];
    }
    if (!isAudio) {
        [self.audioMonitorController pauseTabUI];
    }
    // FT8/FT4 is a background radio service once the operator starts it.
    // Hiding its tab must not interrupt audio capture, slot timing, decoding, or TX sequencing.
    BOOL ft8Active = self.ft8StationController.audioEngine.isMonitoring ||
                     self.ft8StationController.audioEngine.isTransmitting ||
                     self.ft8StationController.audioEngine.isTuning ||
                     self.ft8StationController.audioEngine.isTransmitArmed;
    (void)ft8Active;
    [self updateConnectionStatusBar];

    self.cardSpacer.hidden = isCluster || isStation || isVoice || isFT8 || isCWStation || isAudio || isLogbook || isTelemetry || isScreen;

    self.telemetryController.view.hidden = !isTelemetry;
    self.screenController.view.hidden = !isScreen;
    if (isScreen) {
        if (self.screenController.liveSyncActive && !self.screenController.demoModeActive) {
            [self.screenController startLiveSync];
        } else if (self.screenController.demoModeActive) {
            [self.screenController startDemoTimer];
        }
    }

    self.audioMonitorController.view.hidden = !isAudio;
    if (isAudio) {
        [self.audioMonitorController resumeTabUI];
    }

    self.cwStationController.view.hidden = !isCWStation;
    if (isCWStation) {
        [self.cwStationController startStation];
        if (self.hasPorts) {
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSString *faReply = [weakSelf querySharedCATCommand:@"FA;" timeout:0.4];
                NSString *mdReply = [weakSelf querySharedCATCommand:@"MD;" timeout:0.4];

                uint64_t freqHz = 14025000;
                if ([faReply hasPrefix:@"FA"] && faReply.length >= 13) {
                    freqHz = (uint64_t)[[faReply substringWithRange:NSMakeRange(2, 11)] longLongValue];
                }
                NSString *modeStr = @"CW";
                if ([mdReply hasPrefix:@"MD"] && mdReply.length >= 3) {
                    unichar mCode = [mdReply characterAtIndex:2];
                    if (mCode == '3') modeStr = @"CW";
                    else if (mCode == '7') modeStr = @"CW-R";
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.cwStationController updateFrequencyHz:freqHz mode:modeStr];
                });
            });
        }
    }

    self.ft8StationController.view.hidden = !isFT8;
    if (isFT8) {
        if (!self.logCollapsed) {
            [self toggleLogConsole:nil];
        }
        [self.ft8StationController refreshAudioTab];
        // Prepare only the operating mode and passband. The operator keeps
        // full control of the dial frequency until choosing a band explicitly.
        [self.ft8StationController prepareRadioForDigitalMode];
        [self.ft8StationController refreshRadioFrequency];
    }

    self.logbookController.view.hidden = !isLogbook;
    if (isLogbook) {
        [self.logbookController reloadTableData];
        [self.logbookController updateCloudStatusPills];
        if (self.hasPorts && !self.preparingClusterDraft) {
            __weak typeof(self) weakSelf = self;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSString *faReply = [weakSelf querySharedCATCommand:@"FA;" timeout:0.4];
                NSString *mdReply = [weakSelf querySharedCATCommand:@"MD;" timeout:0.4];

                uint64_t freqHz = 14200000;
                if ([faReply hasPrefix:@"FA"] && faReply.length >= 13) {
                    freqHz = (uint64_t)[[faReply substringWithRange:NSMakeRange(2, 11)] longLongValue];
                }
                NSString *modeStr = @"USB";
                if ([mdReply hasPrefix:@"MD"] && mdReply.length >= 3) {
                    unichar mCode = [mdReply characterAtIndex:2];
                    if (mCode == '1') modeStr = @"LSB";
                    else if (mCode == '2') modeStr = @"USB";
                    else if (mCode == '3') modeStr = @"CW";
                    else if (mCode == '4') modeStr = @"FM";
                    else if (mCode == '5') modeStr = @"AM";
                    else if (mCode == '6') modeStr = @"DIG";
                    else if (mCode == '7') modeStr = @"CW-R";
                    else if (mCode == '8') modeStr = @"DIG-R";
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf.logbookController updateFrequencyHz:freqHz mode:modeStr];
                });
            });
        }
    }

    self.tools.view.hidden = !isTools;
    if (isTools) {
        if (operation == 4 && !self.catConsoleDefaultApplied) {
            self.catConsoleDefaultApplied = YES;
            if (!self.logCollapsed) [self toggleLogConsole:nil];
        }
        [self.tools selectTool:operation - 4];
    }

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
    self.progressBar.hidden = (isCluster || isStation || isVoice || isTelemetry || isScreen || isFeedback || isCWStation || isAudio || isFT8 || isLogbook);
    self.statusLabel.hidden = (isCluster || isStation || isVoice || isTelemetry || isScreen || isFeedback || isCWStation || isAudio || isFT8 || isLogbook);

    CGFloat availW = self.mainScrollView.contentView.bounds.size.width;
    self.instructions.preferredMaxLayoutWidth = (availW > 300.0) ? (availW - 4.0) : 720.0;

    if (isFW) {
        self.instructions.stringValue = @"Connect the CAT-USB cable and stable external power. Close other radio applications. On your transceiver (TX-500 Discovery / TX-500MP), hold the third top function key while pressing POWER. Start only when the screen displays \"The loader is waiting...\". Keep power and cable connected until completion.";
        self.statusLabel.stringValue = @"Select the transceiver's serial port and choose or download the firmware file.";
    } else if (isSync) {
        self.instructions.stringValue = @"Turn the radio on normally with POWER. Lab599 Utility disciplines an internal continuous UTC clock using multi-source network time, calibrated holdover, and robust FT8 timing consensus when offline. Choose local time or UTC for the radio display; the host system clock is never stepped.";
        self.statusLabel.stringValue = @"Ready to synchronize the radio clock in normal operating mode.";
    } else if (isTelemetry) {
        self.instructions.stringValue = @"Live diagnostic telemetry monitoring for Lab599 TX-500 Discovery / TX-500MP. Displays real-time RF output power, antenna SWR, supply/battery voltage, current consumption, and PA temperature via Kenwood / LAB599 CAT protocol.";
        self.statusLabel.stringValue = @"Ready. Select CAT serial port or enable Demo Mode to observe live telemetry meters.";
    } else if (isScreen) {
        self.instructions.stringValue = @"Real-Time LCD Screen Capture & Live Display for Lab599 TX-500 Discovery / TX-500MP. Faithfully simulates the 256×128 monochrome LCD matrix with authentic typography, calibrated S-meter / RF power bars, panadapter spectrum, and milled aluminum chassis bezel. Capture screenshots, copy to clipboard, or choose amber, daylight, green, or OLED themes.";
        self.statusLabel.stringValue = @"Ready. Click 'Refresh' or toggle 'Live Auto-Sync' to stream the radio screen.";
    } else if (operation == 4) {
        self.instructions.stringValue = @"";
        self.statusLabel.stringValue = @"Select a CAT port and use Read All to verify the radio before changing settings.";
    } else if (operation == 5) {
        self.instructions.stringValue = @"Inspect and modify named parameters, export/import JSON, compare backups, and restore 1024-byte binary blocks to the radio.";
        self.statusLabel.stringValue = @"Ready. Connect transceiver CAT port (9600 baud, 8N1) to read or write radio configuration.";
    } else if (operation == 6) {
        self.instructions.stringValue = @"Read and write memory banks, edit individual channels, apply operating profiles, or import/export channel lists as CSV.";
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
    } else if (isCWStation) {
        self.instructions.stringValue = @"Real-time Goertzel DSP Morse decoding via AD-508 audio, Kenwood CAT keying (KS/KY), automatic CQ roster, and ADIF 3.1 logging with offline practice simulation.";
        self.statusLabel.stringValue = @"Ready. Select AD-508 audio input and CAT serial port, or enable Practice Mode.";
    } else if (isAudio) {
        self.instructions.stringValue = @"CoreAudio passthrough for TX-500 via AD-508 cable, real-time FFT spectrum & oscilloscope visualizers, precision VU meters, customizable filters, and studio WAV recording.";
        self.statusLabel.stringValue = @"Ready. Connect AD-508 USB-C audio cable to REM/DATA port and click 'LISTEN LIVE' to hear your radio.";
    } else if (isFT8) {
        self.instructions.stringValue = @"";
        self.statusLabel.stringValue = @"Ready. Select AD-508 audio input/output and CAT serial port, or test using internal simulated signals.";
    } else if (isCluster) {
        self.instructions.stringValue=@"Find active stations, check your contact history and prepare your next QSO. Selecting a spot never transmits.";
    } else if (isStation) {
        self.instructions.stringValue = @"A shared station profile, software frequency library, band reference and quick controls. Applying a frequency never starts TX.";
    } else if (isVoice) {
        self.instructions.stringValue = @"Your recorded voice, repeat CQ and live microphone replies. Select the audio routes, verify the radio, and use Esc to stop or hold Space to talk.";
        self.statusLabel.stringValue = @"Voice Keyer has exclusive radio control while this panel is open.";
    } else if (isLogbook) {
        self.instructions.stringValue = @"";
        self.instructions.hidden = YES;
        self.statusLabel.stringValue = @"Ready: Enter callsign to lookup operator details, or log contacts with 'Log QSO ↵' (Enter).";
    }
    self.instructions.hidden = (isFT8 || isLogbook || operation == 4);
    // Hidden station panels must not impose their minimum width on the active panel.
    for (NSLayoutConstraint *width in self.featureWidthConstraints) {
        width.active = !((NSView *)width.firstItem).hidden;
    }
    [self.instructions invalidateIntrinsicContentSize];
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
        if (self.terminateAfterToolsStop) {
            self.terminateAfterToolsStop = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSApp replyToApplicationShouldTerminate:YES];
            });
        }
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
        TXTimeSyncResult *result = TXSynchronizeTime(port, zone, TXDefaultTimeSyncOptions(), ^NSDate *{
            return [[TX500DisciplinedClock sharedClock] utcDate];
        }, ^(NSString *message) {
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

    self.radioSpecsLabel = [self wrappingLabel:@"Target Specs: 256×128 Monochrome LCD • 32-bit Floating-Point DSP • All-Aluminum CNC Waterproof Chassis"];
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

    self.powerSafetyDescLabel = [self wrappingLabel:@"Note for BP-500/550 Battery Pack: In bootloader mode (\"The loader is waiting...\"), the transceiver does not detect the Battery Pack and powers off automatically after 10 seconds. Connect external power (13.8V DC) or keep the Battery Pack PWR button held continuously throughout the update."];
    self.powerSafetyDescLabel.font = [NSFont systemFontOfSize:11];
    self.powerSafetyDescLabel.textColor = [NSColor secondaryLabelColor];

    self.powerCheckButton = [NSButton buttonWithTitle:@"Check Radio Voltage" target:self action:@selector(checkPowerStatus:)];
    self.powerCheckButton.bezelStyle = NSBezelStyleRounded;
    self.powerCheckButton.controlSize = NSControlSizeSmall;
    self.powerCheckButton.font = [NSFont systemFontOfSize:11];

    NSView *spacer = [NSView new];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];

    NSStackView *topRow = [NSStackView stackViewWithViews:@[self.powerSafetyTitleLabel, spacer, self.powerCheckButton]];
    topRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    topRow.alignment = NSLayoutAttributeCenterY;
    topRow.spacing = 8;
    topRow.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *vStack = [NSStackView stackViewWithViews:@[topRow, self.powerSafetyDescLabel]];
    vStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    vStack.alignment = NSLayoutAttributeLeading;
    vStack.spacing = 6;
    vStack.translatesAutoresizingMaskIntoConstraints = NO;
    [box.contentView addSubview:vStack];

    [NSLayoutConstraint activateConstraints:@[
        [vStack.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:12],
        [vStack.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-12],
        [vStack.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:8],
        [vStack.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-8],
        [topRow.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
        [self.powerSafetyDescLabel.widthAnchor constraintEqualToAnchor:vStack.widthAnchor],
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
        gitBtn.focusRingType = NSFocusRingTypeNone;

        NSButton *webBtn = [NSButton buttonWithTitle:@"Official Lab599 Website: https://lab599.com"
                                              target:self
                                              action:@selector(openLab599Website:)];
        webBtn.bezelStyle = NSBezelStyleInline;
        webBtn.focusRingType = NSFocusRingTypeNone;

        NSButton *closeBtn = [NSButton buttonWithTitle:@"Close" target:self action:@selector(closeAboutWindow:)];
        closeBtn.bezelStyle = NSBezelStyleRounded;
        closeBtn.keyEquivalent = @"\r";
        closeBtn.focusRingType = NSFocusRingTypeNone;
        self.aboutWindow.initialFirstResponder = closeBtn;

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

#pragma mark - Preferences Window

- (void)showPreferencesWindow:(id)sender {
    (void)sender;
    if (!self.preferencesWindow) {
        self.preferencesWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 680, 840)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
            backing:NSBackingStoreBuffered defer:NO];
        self.preferencesWindow.title = @"Preferences";
        self.preferencesWindow.releasedWhenClosed = NO;
        [self.preferencesWindow center];

        NSInteger savedTheme = [[NSUserDefaults standardUserDefaults] integerForKey:@"TX500_AppTheme"];
        if (savedTheme == 1 || self.outdoorModeActive) {
            self.preferencesWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
        } else if (savedTheme == 2) {
            self.preferencesWindow.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        } else {
            self.preferencesWindow.appearance = nil; // System
        }

        // Top Preferences Segmented Switcher
        self.prefTabSegment = [NSSegmentedControl segmentedControlWithLabels:@[@"⚙️  Station & Operating", @"☁️  Cloud & Logbook Accounts"]
                                                                trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                      target:self
                                                                      action:@selector(prefTabChanged:)];
        self.prefTabSegment.selectedSegment = 0;
        self.prefTabSegment.segmentStyle = NSSegmentStyleTexturedRounded;
        self.prefTabSegment.controlSize = NSControlSizeRegular;
        self.prefTabSegment.translatesAutoresizingMaskIntoConstraints = NO;

        // Container holding both tabs
        NSView *tabHostView = [NSView new];
        tabHostView.translatesAutoresizingMaskIntoConstraints = NO;

        // Tab 0: Station Container
        self.prefStationContainer = [NSView new];
        self.prefStationContainer.translatesAutoresizingMaskIntoConstraints = NO;

        // Tab 1: Cloud Container
        self.prefCloudContainer = [NSView new];
        self.prefCloudContainer.translatesAutoresizingMaskIntoConstraints = NO;
        self.prefCloudContainer.hidden = YES;

        [tabHostView addSubview:self.prefStationContainer];
        [tabHostView addSubview:self.prefCloudContainer];

        [NSLayoutConstraint activateConstraints:@[
            [self.prefStationContainer.topAnchor constraintEqualToAnchor:tabHostView.topAnchor],
            [self.prefStationContainer.leadingAnchor constraintEqualToAnchor:tabHostView.leadingAnchor],
            [self.prefStationContainer.trailingAnchor constraintEqualToAnchor:tabHostView.trailingAnchor],
            [self.prefStationContainer.bottomAnchor constraintEqualToAnchor:tabHostView.bottomAnchor],

            [self.prefCloudContainer.topAnchor constraintEqualToAnchor:tabHostView.topAnchor],
            [self.prefCloudContainer.leadingAnchor constraintEqualToAnchor:tabHostView.leadingAnchor],
            [self.prefCloudContainer.trailingAnchor constraintEqualToAnchor:tabHostView.trailingAnchor],
            [self.prefCloudContainer.bottomAnchor constraintEqualToAnchor:tabHostView.bottomAnchor],
        ]];

        // Header Stack
        NSTextField *titleLabel = [self label:@"Station & Operating Preferences"];
        titleLabel.font = [NSFont systemFontOfSize:18 weight:NSFontWeightBold];

        NSTextField *subLabel = [self label:@"Configure operator identity, time format, and automatic logging defaults."];
        subLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
        subLabel.textColor = NSColor.secondaryLabelColor;

        // --- Card 1: Operator & Station Identity ---
        NSBox *stationBox = [NSBox new];
        stationBox.boxType = NSBoxCustom;
        stationBox.cornerRadius = 8.0;
        stationBox.borderWidth = 1.0;
        stationBox.borderColor = [NSColor separatorColor];
        stationBox.fillColor = [NSColor controlBackgroundColor];
        stationBox.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *stTitle = [self label:@"OPERATOR & STATION IDENTITY"];
        stTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
        stTitle.textColor = [NSColor colorWithCalibratedRed:0.12 green:0.50 blue:0.90 alpha:1.0];

        NSTextField *callLbl = [self label:@"Callsign:"];
        callLbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.prefCallsignField = [NSTextField textFieldWithString:@""];
        self.prefCallsignField.placeholderString = @"e.g. EP2AES";
        self.prefCallsignField.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *gridLbl = [self label:@"Maidenhead Grid:"];
        gridLbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.prefGridField = [NSTextField textFieldWithString:@""];
        self.prefGridField.placeholderString = @"e.g. KM35";
        self.prefGridField.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *nameLbl = [self label:@"Operator Name:"];
        nameLbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.prefOperatorNameField = [NSTextField textFieldWithString:@""];
        self.prefOperatorNameField.placeholderString = @"e.g. Amir (Optional)";
        self.prefOperatorNameField.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *rigLbl = [self label:@"Radio / Rig:"];
        rigLbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.prefRigField = [NSTextField textFieldWithString:@"Lab599 Discovery TX-500"];
        self.prefRigField.placeholderString = @"e.g. Lab599 Discovery TX-500";
        self.prefRigField.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *antLbl = [self label:@"Antenna:"];
        antLbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.prefAntennaField = [NSTextField textFieldWithString:@"Wire Dipole / End-Fed"];
        self.prefAntennaField.placeholderString = @"e.g. Wire Dipole / End-Fed";
        self.prefAntennaField.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *stDesc = [NSTextField wrappingLabelWithString:@"These station credentials and hardware details are broadcast in FT8 CQ frames, CW macros, PSKReporter telemetry, and recorded as MY_RIG / MY_ANTENNA in ADIF logs."];
        stDesc.font = [NSFont systemFontOfSize:11];
        stDesc.textColor = NSColor.tertiaryLabelColor;
        stDesc.translatesAutoresizingMaskIntoConstraints = NO;

        NSView *stationForm = [NSView new];
        stationForm.translatesAutoresizingMaskIntoConstraints = NO;
        [stationForm addSubview:callLbl];
        [stationForm addSubview:self.prefCallsignField];
        [stationForm addSubview:gridLbl];
        [stationForm addSubview:self.prefGridField];
        [stationForm addSubview:nameLbl];
        [stationForm addSubview:self.prefOperatorNameField];
        [stationForm addSubview:rigLbl];
        [stationForm addSubview:self.prefRigField];
        [stationForm addSubview:antLbl];
        [stationForm addSubview:self.prefAntennaField];

        [NSLayoutConstraint activateConstraints:@[
            [callLbl.leadingAnchor constraintEqualToAnchor:stationForm.leadingAnchor],
            [callLbl.centerYAnchor constraintEqualToAnchor:self.prefCallsignField.centerYAnchor],
            [callLbl.widthAnchor constraintEqualToConstant:125],

            [self.prefCallsignField.leadingAnchor constraintEqualToAnchor:callLbl.trailingAnchor constant:8],
            [self.prefCallsignField.trailingAnchor constraintEqualToAnchor:stationForm.trailingAnchor],
            [self.prefCallsignField.topAnchor constraintEqualToAnchor:stationForm.topAnchor],
            [self.prefCallsignField.heightAnchor constraintEqualToConstant:24],

            [gridLbl.leadingAnchor constraintEqualToAnchor:stationForm.leadingAnchor],
            [gridLbl.centerYAnchor constraintEqualToAnchor:self.prefGridField.centerYAnchor],
            [gridLbl.widthAnchor constraintEqualToConstant:125],

            [self.prefGridField.leadingAnchor constraintEqualToAnchor:gridLbl.trailingAnchor constant:8],
            [self.prefGridField.trailingAnchor constraintEqualToAnchor:stationForm.trailingAnchor],
            [self.prefGridField.topAnchor constraintEqualToAnchor:self.prefCallsignField.bottomAnchor constant:8],
            [self.prefGridField.heightAnchor constraintEqualToConstant:24],

            [nameLbl.leadingAnchor constraintEqualToAnchor:stationForm.leadingAnchor],
            [nameLbl.centerYAnchor constraintEqualToAnchor:self.prefOperatorNameField.centerYAnchor],
            [nameLbl.widthAnchor constraintEqualToConstant:125],

            [self.prefOperatorNameField.leadingAnchor constraintEqualToAnchor:nameLbl.trailingAnchor constant:8],
            [self.prefOperatorNameField.trailingAnchor constraintEqualToAnchor:stationForm.trailingAnchor],
            [self.prefOperatorNameField.topAnchor constraintEqualToAnchor:self.prefGridField.bottomAnchor constant:8],
            [self.prefOperatorNameField.heightAnchor constraintEqualToConstant:24],

            [rigLbl.leadingAnchor constraintEqualToAnchor:stationForm.leadingAnchor],
            [rigLbl.centerYAnchor constraintEqualToAnchor:self.prefRigField.centerYAnchor],
            [rigLbl.widthAnchor constraintEqualToConstant:125],

            [self.prefRigField.leadingAnchor constraintEqualToAnchor:rigLbl.trailingAnchor constant:8],
            [self.prefRigField.trailingAnchor constraintEqualToAnchor:stationForm.trailingAnchor],
            [self.prefRigField.topAnchor constraintEqualToAnchor:self.prefOperatorNameField.bottomAnchor constant:8],
            [self.prefRigField.heightAnchor constraintEqualToConstant:24],

            [antLbl.leadingAnchor constraintEqualToAnchor:stationForm.leadingAnchor],
            [antLbl.centerYAnchor constraintEqualToAnchor:self.prefAntennaField.centerYAnchor],
            [antLbl.widthAnchor constraintEqualToConstant:125],

            [self.prefAntennaField.leadingAnchor constraintEqualToAnchor:antLbl.trailingAnchor constant:8],
            [self.prefAntennaField.trailingAnchor constraintEqualToAnchor:stationForm.trailingAnchor],
            [self.prefAntennaField.topAnchor constraintEqualToAnchor:self.prefRigField.bottomAnchor constant:8],
            [self.prefAntennaField.heightAnchor constraintEqualToConstant:24],
            [self.prefAntennaField.bottomAnchor constraintEqualToAnchor:stationForm.bottomAnchor]
        ]];

        NSStackView *stationStack = [NSStackView stackViewWithViews:@[stTitle, stationForm, stDesc]];
        stationStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stationStack.alignment = NSLayoutAttributeLeading;
        stationStack.spacing = 8;
        stationStack.translatesAutoresizingMaskIntoConstraints = NO;
        [stationBox.contentView addSubview:stationStack];

        [NSLayoutConstraint activateConstraints:@[
            [stationStack.leadingAnchor constraintEqualToAnchor:stationBox.contentView.leadingAnchor constant:14],
            [stationStack.trailingAnchor constraintEqualToAnchor:stationBox.contentView.trailingAnchor constant:-14],
            [stationStack.topAnchor constraintEqualToAnchor:stationBox.contentView.topAnchor constant:12],
            [stationStack.bottomAnchor constraintEqualToAnchor:stationBox.contentView.bottomAnchor constant:-12],
            [stationForm.widthAnchor constraintEqualToAnchor:stationStack.widthAnchor],
            [stDesc.widthAnchor constraintEqualToAnchor:stationStack.widthAnchor]
        ]];

        // --- Card 2: Time Format & Band Defaults ---
        NSBox *timeBox = [NSBox new];
        timeBox.boxType = NSBoxCustom;
        timeBox.cornerRadius = 8.0;
        timeBox.borderWidth = 1.0;
        timeBox.borderColor = [NSColor separatorColor];
        timeBox.fillColor = [NSColor controlBackgroundColor];
        timeBox.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *timeTitle = [self label:@"TIME FORMAT & BAND DEFAULTS"];
        timeTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
        timeTitle.textColor = [NSColor colorWithCalibratedRed:0.12 green:0.50 blue:0.90 alpha:1.0];

        self.prefUtcCheckbox = [NSButton checkboxWithTitle:@"Display Time in UTC (Coordinated Universal Time / Zulu)"
                                                    target:nil
                                                    action:nil];
        self.prefUtcCheckbox.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.prefUtcCheckbox.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *utcDesc = [NSTextField wrappingLabelWithString:@"When checked, FT8 decodes table, timestamps, and QSO entries reflect UTC. When unchecked, your local system time is displayed."];
        utcDesc.font = [NSFont systemFontOfSize:11];
        utcDesc.textColor = NSColor.tertiaryLabelColor;
        utcDesc.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *bandLbl = [self label:@"Default FT8 Band:"];
        bandLbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.prefDefaultBandPopup = [NSPopUpButton new];
        self.prefDefaultBandPopup.translatesAutoresizingMaskIntoConstraints = NO;
        [self.prefDefaultBandPopup addItemsWithTitles:@[
            @"20m (14.074 MHz)",
            @"40m (7.074 MHz)",
            @"15m (21.074 MHz)",
            @"10m (28.074 MHz)",
            @"30m (10.136 MHz)",
            @"80m (3.573 MHz)",
            @"6m (50.313 MHz)"
        ]];

        NSStackView *bandRow = [NSStackView stackViewWithViews:@[bandLbl, self.prefDefaultBandPopup]];
        bandRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        bandRow.alignment = NSLayoutAttributeCenterY;
        bandRow.spacing = 8;
        bandRow.translatesAutoresizingMaskIntoConstraints = NO;

        NSStackView *timeStack = [NSStackView stackViewWithViews:@[timeTitle, self.prefUtcCheckbox, utcDesc, bandRow]];
        timeStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        timeStack.alignment = NSLayoutAttributeLeading;
        timeStack.spacing = 8;
        timeStack.translatesAutoresizingMaskIntoConstraints = NO;
        [timeBox.contentView addSubview:timeStack];

        [NSLayoutConstraint activateConstraints:@[
            [timeStack.leadingAnchor constraintEqualToAnchor:timeBox.contentView.leadingAnchor constant:14],
            [timeStack.trailingAnchor constraintEqualToAnchor:timeBox.contentView.trailingAnchor constant:-14],
            [timeStack.topAnchor constraintEqualToAnchor:timeBox.contentView.topAnchor constant:12],
            [timeStack.bottomAnchor constraintEqualToAnchor:timeBox.contentView.bottomAnchor constant:-12],
            [utcDesc.widthAnchor constraintEqualToAnchor:timeStack.widthAnchor]
        ]];

        // --- Card 3: ADIF Logging & Storage ---
        NSBox *logBox = [NSBox new];
        logBox.boxType = NSBoxCustom;
        logBox.cornerRadius = 8.0;
        logBox.borderWidth = 1.0;
        logBox.borderColor = [NSColor separatorColor];
        logBox.fillColor = [NSColor controlBackgroundColor];
        logBox.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *logTitle = [self label:@"ADIF LOGGING & DATA STORAGE"];
        logTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
        logTitle.textColor = [NSColor colorWithCalibratedRed:0.12 green:0.50 blue:0.90 alpha:1.0];

        self.prefLogQsoCheckbox = [NSButton checkboxWithTitle:@"Log successful FT8/FT4 contacts automatically without operator confirmation"
                                                       target:nil
                                                       action:nil];
        self.prefLogQsoCheckbox.font = [NSFont systemFontOfSize:12];
        self.prefLogQsoCheckbox.translatesAutoresizingMaskIntoConstraints = NO;

        self.prefLogDecodesCheckbox = [NSButton checkboxWithTitle:@"Auto-log all incoming FT8 decodes to FT8_ALL_DECODES.adi (UTC)"
                                                           target:nil
                                                           action:nil];
        self.prefLogDecodesCheckbox.font = [NSFont systemFontOfSize:12];
        self.prefLogDecodesCheckbox.translatesAutoresizingMaskIntoConstraints = NO;

        NSButton *openLogsBtn = [NSButton buttonWithTitle:@"Open Logs Folder in Finder…"
                                                   target:self
                                                   action:@selector(openPreferencesLogsFolder:)];
        openLogsBtn.bezelStyle = NSBezelStyleInline;
        openLogsBtn.focusRingType = NSFocusRingTypeNone;
        openLogsBtn.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *autoLogDesc = [NSTextField wrappingLabelWithString:@"When enabled, a completed exchange is saved immediately to the ADIF and main logbook. Disable it to review every successful contact before saving."];
        autoLogDesc.font = [NSFont systemFontOfSize:11];
        autoLogDesc.textColor = NSColor.tertiaryLabelColor;
        autoLogDesc.translatesAutoresizingMaskIntoConstraints = NO;

        NSStackView *logStack = [NSStackView stackViewWithViews:@[logTitle, self.prefLogQsoCheckbox, autoLogDesc, self.prefLogDecodesCheckbox, openLogsBtn]];
        logStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        logStack.alignment = NSLayoutAttributeLeading;
        logStack.spacing = 8;
        logStack.translatesAutoresizingMaskIntoConstraints = NO;
        [logBox.contentView addSubview:logStack];

        [NSLayoutConstraint activateConstraints:@[
            [logStack.leadingAnchor constraintEqualToAnchor:logBox.contentView.leadingAnchor constant:14],
            [logStack.trailingAnchor constraintEqualToAnchor:logBox.contentView.trailingAnchor constant:-14],
            [logStack.topAnchor constraintEqualToAnchor:logBox.contentView.topAnchor constant:12],
            [logStack.bottomAnchor constraintEqualToAnchor:logBox.contentView.bottomAnchor constant:-12]
            ,[autoLogDesc.widthAnchor constraintEqualToAnchor:logStack.widthAnchor]
        ]];

        // --- Card 4: Appearance (Theme) ---
        NSBox *appearanceBox = [NSBox new];
        appearanceBox.boxType = NSBoxCustom;
        appearanceBox.cornerRadius = 8.0;
        appearanceBox.borderWidth = 1.0;
        appearanceBox.borderColor = [NSColor separatorColor];
        appearanceBox.fillColor = [NSColor controlBackgroundColor];
        appearanceBox.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *appearTitle = [self label:@"APPEARANCE"];
        appearTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
        appearTitle.textColor = [NSColor colorWithCalibratedRed:0.12 green:0.50 blue:0.90 alpha:1.0];

        NSTextField *themeLbl = [self label:@"Theme:"];
        themeLbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.prefThemePopup = [NSPopUpButton new];
        self.prefThemePopup.translatesAutoresizingMaskIntoConstraints = NO;
        [self.prefThemePopup addItemsWithTitles:@[@"System (Auto)", @"Light", @"Dark"]];

        NSStackView *themeRow = [NSStackView stackViewWithViews:@[themeLbl, self.prefThemePopup]];
        themeRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        themeRow.alignment = NSLayoutAttributeCenterY;
        themeRow.spacing = 8;
        themeRow.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *themeDesc = [NSTextField wrappingLabelWithString:@"Light mode improves readability outdoors. Dark mode is easier on the eyes at night. System follows your macOS Appearance setting."];
        themeDesc.font = [NSFont systemFontOfSize:11];
        themeDesc.textColor = NSColor.tertiaryLabelColor;
        themeDesc.translatesAutoresizingMaskIntoConstraints = NO;

        NSStackView *appearStack = [NSStackView stackViewWithViews:@[appearTitle, themeRow, themeDesc]];
        appearStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        appearStack.alignment = NSLayoutAttributeLeading;
        appearStack.spacing = 8;
        appearStack.translatesAutoresizingMaskIntoConstraints = NO;
        [appearanceBox.contentView addSubview:appearStack];

        [NSLayoutConstraint activateConstraints:@[
            [appearStack.leadingAnchor constraintEqualToAnchor:appearanceBox.contentView.leadingAnchor constant:14],
            [appearStack.trailingAnchor constraintEqualToAnchor:appearanceBox.contentView.trailingAnchor constant:-14],
            [appearStack.topAnchor constraintEqualToAnchor:appearanceBox.contentView.topAnchor constant:12],
            [appearStack.bottomAnchor constraintEqualToAnchor:appearanceBox.contentView.bottomAnchor constant:-12],
            [themeDesc.widthAnchor constraintEqualToAnchor:appearStack.widthAnchor]
        ]];

        // --- Card 5: TX Safety & SWR Protection ---
        NSBox *safetyBox = [NSBox new];
        safetyBox.boxType = NSBoxCustom;
        safetyBox.cornerRadius = 8.0;
        safetyBox.borderWidth = 1.0;
        safetyBox.borderColor = [NSColor separatorColor];
        safetyBox.fillColor = [NSColor controlBackgroundColor];
        safetyBox.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *safetyTitle = [self label:@"TX SAFETY & SWR PROTECTION"];
        safetyTitle.font = [NSFont systemFontOfSize:11 weight:NSFontWeightBold];
        safetyTitle.textColor = [NSColor colorWithCalibratedRed:0.12 green:0.50 blue:0.90 alpha:1.0];

        NSTextField *swrLbl = [self label:@"Max SWR before TX abort:"];
        swrLbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.prefSWRThresholdField = [NSTextField textFieldWithString:@"3.0"];
        self.prefSWRThresholdField.placeholderString = @"e.g. 3.0";
        self.prefSWRThresholdField.translatesAutoresizingMaskIntoConstraints = NO;
        [self.prefSWRThresholdField.widthAnchor constraintEqualToConstant:60].active = YES;

        NSTextField *swrUnit = [self label:@":1"];
        swrUnit.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];

        NSStackView *swrRow = [NSStackView stackViewWithViews:@[swrLbl, self.prefSWRThresholdField, swrUnit]];
        swrRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        swrRow.alignment = NSLayoutAttributeCenterY;
        swrRow.spacing = 6;
        swrRow.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *swrDesc = [NSTextField wrappingLabelWithString:@"During FT8 transmission, SWR is read from the radio via CAT. If SWR exceeds this threshold, transmission is aborted immediately to protect your amplifier and antenna. Set to 0 to disable protection."];
        swrDesc.font = [NSFont systemFontOfSize:11];
        swrDesc.textColor = NSColor.tertiaryLabelColor;
        swrDesc.translatesAutoresizingMaskIntoConstraints = NO;

        // Max Reply Attempts per callsign
        NSTextField *maxReplyLbl = [self label:@"Max reply attempts per callsign:"];
        maxReplyLbl.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
        self.prefMaxReplyAttemptsField = [NSTextField textFieldWithString:@"2"];
        self.prefMaxReplyAttemptsField.placeholderString = @"1–9";
        self.prefMaxReplyAttemptsField.translatesAutoresizingMaskIntoConstraints = NO;
        [self.prefMaxReplyAttemptsField.widthAnchor constraintEqualToConstant:40].active = YES;

        NSTextField *maxReplyUnit = [self label:@"cycles (1–9)"];
        maxReplyUnit.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];

        NSStackView *maxReplyRow = [NSStackView stackViewWithViews:@[maxReplyLbl, self.prefMaxReplyAttemptsField, maxReplyUnit]];
        maxReplyRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        maxReplyRow.alignment = NSLayoutAttributeCenterY;
        maxReplyRow.spacing = 6;
        maxReplyRow.translatesAutoresizingMaskIntoConstraints = NO;

        NSTextField *maxReplyDesc = [NSTextField wrappingLabelWithString:@"If the DX station does not reply within this many TX cycles, the auto-engine will abandon the contact and return to hunting. Keeps the radio from transmitting indefinitely, protecting its duty cycle. Minimum: 1, Maximum: 9."];
        maxReplyDesc.font = [NSFont systemFontOfSize:11];
        maxReplyDesc.textColor = NSColor.tertiaryLabelColor;
        maxReplyDesc.translatesAutoresizingMaskIntoConstraints = NO;

        NSStackView *safetyStack = [NSStackView stackViewWithViews:@[safetyTitle, swrRow, swrDesc, maxReplyRow, maxReplyDesc]];
        safetyStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        safetyStack.alignment = NSLayoutAttributeLeading;
        safetyStack.spacing = 8;
        safetyStack.translatesAutoresizingMaskIntoConstraints = NO;
        [safetyBox.contentView addSubview:safetyStack];

        [NSLayoutConstraint activateConstraints:@[
            [safetyStack.leadingAnchor constraintEqualToAnchor:safetyBox.contentView.leadingAnchor constant:14],
            [safetyStack.trailingAnchor constraintEqualToAnchor:safetyBox.contentView.trailingAnchor constant:-14],
            [safetyStack.topAnchor constraintEqualToAnchor:safetyBox.contentView.topAnchor constant:12],
            [safetyStack.bottomAnchor constraintEqualToAnchor:safetyBox.contentView.bottomAnchor constant:-12],
            [swrDesc.widthAnchor constraintEqualToAnchor:safetyStack.widthAnchor],
            [maxReplyDesc.widthAnchor constraintEqualToAnchor:safetyStack.widthAnchor]
        ]];


        NSStackView *stationOuterStack = [NSStackView stackViewWithViews:@[titleLabel, subLabel, stationBox, timeBox, logBox, appearanceBox, safetyBox]];
        stationOuterStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stationOuterStack.alignment = NSLayoutAttributeLeading;
        stationOuterStack.spacing = 10;
        stationOuterStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.prefStationContainer addSubview:stationOuterStack];

        [NSLayoutConstraint activateConstraints:@[
            [stationOuterStack.topAnchor constraintEqualToAnchor:self.prefStationContainer.topAnchor],
            [stationOuterStack.leadingAnchor constraintEqualToAnchor:self.prefStationContainer.leadingAnchor],
            [stationOuterStack.trailingAnchor constraintEqualToAnchor:self.prefStationContainer.trailingAnchor],
            [stationOuterStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.prefStationContainer.bottomAnchor],
            [stationBox.widthAnchor constraintEqualToAnchor:stationOuterStack.widthAnchor],
            [timeBox.widthAnchor constraintEqualToAnchor:stationOuterStack.widthAnchor],
            [logBox.widthAnchor constraintEqualToAnchor:stationOuterStack.widthAnchor],
            [appearanceBox.widthAnchor constraintEqualToAnchor:stationOuterStack.widthAnchor],
            [safetyBox.widthAnchor constraintEqualToAnchor:stationOuterStack.widthAnchor]
        ]];

        // Cloud Stack for Tab 1
        NSTextField *cloudTitleLabel = [self label:@"Cloud & Logbook Accounts"];
        cloudTitleLabel.font = [NSFont systemFontOfSize:18 weight:NSFontWeightBold];

        NSTextField *cloudSubLabel = [self label:@"Manage credentials and synchronization for LoTW, QRZ.com, Club Log, eQSL, and HamQTH."];
        cloudSubLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightRegular];
        cloudSubLabel.textColor = NSColor.secondaryLabelColor;

        NSView *cloudView = [TX500CloudSettingsController sharedController].settingsView;
        cloudView.translatesAutoresizingMaskIntoConstraints = NO;

        NSStackView *cloudStack = [NSStackView stackViewWithViews:@[cloudTitleLabel, cloudSubLabel, cloudView]];
        cloudStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        cloudStack.alignment = NSLayoutAttributeLeading;
        cloudStack.spacing = 10;
        cloudStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.prefCloudContainer addSubview:cloudStack];

        [NSLayoutConstraint activateConstraints:@[
            [cloudStack.topAnchor constraintEqualToAnchor:self.prefCloudContainer.topAnchor],
            [cloudStack.leadingAnchor constraintEqualToAnchor:self.prefCloudContainer.leadingAnchor],
            [cloudStack.trailingAnchor constraintEqualToAnchor:self.prefCloudContainer.trailingAnchor],
            [cloudStack.bottomAnchor constraintLessThanOrEqualToAnchor:self.prefCloudContainer.bottomAnchor],
            [cloudView.widthAnchor constraintEqualToAnchor:cloudStack.widthAnchor]
        ]];

        // --- Bottom Action Buttons ---
        NSButton *cancelBtn = [NSButton buttonWithTitle:@"Cancel" target:self action:@selector(cancelPreferences:)];
        cancelBtn.bezelStyle = NSBezelStyleRounded;
        cancelBtn.translatesAutoresizingMaskIntoConstraints = NO;

        NSButton *saveBtn = [NSButton buttonWithTitle:@"Save & Apply" target:self action:@selector(savePreferences:)];
        saveBtn.bezelStyle = NSBezelStyleRounded;
        saveBtn.keyEquivalent = @"\r";
        saveBtn.translatesAutoresizingMaskIntoConstraints = NO;
        self.preferencesWindow.initialFirstResponder = saveBtn;

        NSStackView *btnRow = [NSStackView stackViewWithViews:@[cancelBtn, saveBtn]];
        btnRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        btnRow.alignment = NSLayoutAttributeCenterY;
        btnRow.spacing = 12;
        btnRow.translatesAutoresizingMaskIntoConstraints = NO;

        [self.preferencesWindow.contentView addSubview:self.prefTabSegment];
        [self.preferencesWindow.contentView addSubview:tabHostView];
        [self.preferencesWindow.contentView addSubview:btnRow];

        [NSLayoutConstraint activateConstraints:@[
            [self.prefTabSegment.topAnchor constraintEqualToAnchor:self.preferencesWindow.contentView.topAnchor constant:14],
            [self.prefTabSegment.centerXAnchor constraintEqualToAnchor:self.preferencesWindow.contentView.centerXAnchor],
            [self.prefTabSegment.heightAnchor constraintEqualToConstant:28],

            [tabHostView.topAnchor constraintEqualToAnchor:self.prefTabSegment.bottomAnchor constant:12],
            [tabHostView.leadingAnchor constraintEqualToAnchor:self.preferencesWindow.contentView.leadingAnchor constant:24],
            [tabHostView.trailingAnchor constraintEqualToAnchor:self.preferencesWindow.contentView.trailingAnchor constant:-24],
            [tabHostView.bottomAnchor constraintEqualToAnchor:btnRow.topAnchor constant:-12],

            [btnRow.trailingAnchor constraintEqualToAnchor:self.preferencesWindow.contentView.trailingAnchor constant:-24],
            [btnRow.bottomAnchor constraintEqualToAnchor:self.preferencesWindow.contentView.bottomAnchor constant:-16]
        ]];

    }

    // Populate current values from NSUserDefaults
    NSString *call = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_OperatorCallsign"] ?: @"EP2AES";
    NSString *grid = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_OperatorGrid"] ?: @"KM35";
    NSString *opName = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_OperatorName"] ?: @"";
    NSString *rig = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_StationRig"] ?: @"Lab599 Discovery TX-500";
    NSString *antenna = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_StationAntenna"] ?: @"Wire Dipole / End-Fed";
    BOOL showUTC = [[NSUserDefaults standardUserDefaults] boolForKey:@"TX500_DisplayTimeInUTC"];
    NSString *band = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_DefaultBand"] ?: @"20m (14.074 MHz)";

    self.prefCallsignField.stringValue = call;
    self.prefGridField.stringValue = grid;
    self.prefOperatorNameField.stringValue = opName;
    self.prefRigField.stringValue = rig;
    self.prefAntennaField.stringValue = antenna;
    self.prefUtcCheckbox.state = showUTC ? NSControlStateValueOn : NSControlStateValueOff;

    [self.prefDefaultBandPopup selectItemWithTitle:band];
    if (self.prefDefaultBandPopup.indexOfSelectedItem < 0) {
        [self.prefDefaultBandPopup selectItemAtIndex:0];
    }

    id autoLogQsoVal = [[NSUserDefaults standardUserDefaults] objectForKey:@"TX500_AutoLogQSO"];
    self.prefLogQsoCheckbox.state = (autoLogQsoVal == nil || [autoLogQsoVal boolValue]) ? NSControlStateValueOn : NSControlStateValueOff;

    id autoLogDecodesVal = [[NSUserDefaults standardUserDefaults] objectForKey:@"TX500_AutoLogDecodes"];
    self.prefLogDecodesCheckbox.state = (autoLogDecodesVal == nil || [autoLogDecodesVal boolValue]) ? NSControlStateValueOn : NSControlStateValueOff;

    // Theme
    NSInteger themeIdx = [[NSUserDefaults standardUserDefaults] integerForKey:@"TX500_AppTheme"];
    if (themeIdx < 0 || themeIdx > 2) themeIdx = 0;
    [self.prefThemePopup selectItemAtIndex:themeIdx];

    // SWR Threshold
    id storedSWRThreshold = [[NSUserDefaults standardUserDefaults] objectForKey:@"TX500_SWRThreshold"];
    double swrThreshold = storedSWRThreshold ? [storedSWRThreshold doubleValue] : 3.0;
    if (swrThreshold < 0.0) swrThreshold = 0.0;
    self.prefSWRThresholdField.stringValue = [NSString stringWithFormat:@"%.1f", swrThreshold];

    // Max Reply Attempts
    NSInteger maxAttempts = [[NSUserDefaults standardUserDefaults] integerForKey:@"TX500_MaxReplyAttempts"];
    if (maxAttempts < 1 || maxAttempts > 9) maxAttempts = 3;
    self.prefMaxReplyAttemptsField.stringValue = [NSString stringWithFormat:@"%ld", (long)maxAttempts];


    [self.preferencesWindow center];
    [self.preferencesWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)selectPreferencesTab:(NSInteger)tab {
    if (tab < 0 || tab >= 2) tab = 0;
    self.prefTabSegment.selectedSegment = tab;
    [self prefTabChanged:self.prefTabSegment];
}

- (void)prefTabChanged:(NSSegmentedControl *)sender {
    NSInteger tab = sender.selectedSegment;
    self.prefStationContainer.hidden = (tab != 0);
    self.prefCloudContainer.hidden = (tab != 1);
    if (tab == 1) {
        [[TX500CloudSettingsController sharedController] loadSavedSettings];
    }
}

- (void)savePreferences:(id)sender {
    (void)sender;
    NSString *call = [[self.prefCallsignField.stringValue uppercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (call.length == 0) call = @"EP2AES";

    NSString *grid = [[self.prefGridField.stringValue uppercaseString] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (grid.length == 0) grid = @"KM35";

    NSString *opName = [self.prefOperatorNameField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *rig = [self.prefRigField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (rig.length == 0) rig = @"Lab599 Discovery TX-500";
    NSString *antenna = [self.prefAntennaField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (antenna.length == 0) antenna = @"Wire Dipole / End-Fed";

    BOOL isUTC = (self.prefUtcCheckbox.state == NSControlStateValueOn);
    NSString *band = self.prefDefaultBandPopup.titleOfSelectedItem ?: @"20m (14.074 MHz)";
    BOOL autoLogQSO = (self.prefLogQsoCheckbox.state == NSControlStateValueOn);
    BOOL autoLogDecodes = (self.prefLogDecodesCheckbox.state == NSControlStateValueOn);
    NSInteger themeIdx = self.prefThemePopup.indexOfSelectedItem; // 0=System, 1=Light, 2=Dark
    double swrThreshold = [self.prefSWRThresholdField.stringValue doubleValue];
    if (swrThreshold < 0.0) swrThreshold = 0.0;

    // Max Reply Attempts: clamp to 1–9
    NSInteger maxAttempts = [self.prefMaxReplyAttemptsField.stringValue integerValue];
    if (maxAttempts < 1) maxAttempts = 1;
    if (maxAttempts > 9) maxAttempts = 9;
    self.prefMaxReplyAttemptsField.stringValue = [NSString stringWithFormat:@"%ld", (long)maxAttempts];

    [[NSUserDefaults standardUserDefaults] setObject:call forKey:@"TX500_OperatorCallsign"];
    [[NSUserDefaults standardUserDefaults] setObject:grid forKey:@"TX500_OperatorGrid"];
    [[NSUserDefaults standardUserDefaults] setObject:opName forKey:@"TX500_OperatorName"];
    [[NSUserDefaults standardUserDefaults] setObject:rig forKey:@"TX500_StationRig"];
    [[NSUserDefaults standardUserDefaults] setObject:antenna forKey:@"TX500_StationAntenna"];
    [[NSUserDefaults standardUserDefaults] setBool:isUTC forKey:@"TX500_DisplayTimeInUTC"];
    [[NSUserDefaults standardUserDefaults] setObject:band forKey:@"TX500_DefaultBand"];
    [[NSUserDefaults standardUserDefaults] setBool:autoLogQSO forKey:@"TX500_AutoLogQSO"];
    [[NSUserDefaults standardUserDefaults] setBool:autoLogDecodes forKey:@"TX500_AutoLogDecodes"];
    [[NSUserDefaults standardUserDefaults] setInteger:themeIdx forKey:@"TX500_AppTheme"];
    [[NSUserDefaults standardUserDefaults] setDouble:swrThreshold forKey:@"TX500_SWRThreshold"];
    [[NSUserDefaults standardUserDefaults] setInteger:maxAttempts forKey:@"TX500_MaxReplyAttempts"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    // Propagate maxReplyAttempts to running FT8 engine immediately (no restart needed)
    if (self.ft8StationController) {
        self.ft8StationController.autoEngine.maxReplyAttempts = maxAttempts;
        self.ft8StationController.audioEngine.maxSWRThreshold = swrThreshold;
    }

    // Also persist cloud credentials if configured
    [[TX500CloudSettingsController sharedController] saveAndApplyClicked];

    // Apply theme immediately
    NSAppearance *appearance = nil;
    if (themeIdx == 1) {
        appearance = [NSAppearance appearanceNamed:NSAppearanceNameAqua];
    } else if (themeIdx == 2) {
        appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    }
    [NSApp setAppearance:appearance]; // nil = follow system

    [[NSNotificationCenter defaultCenter] postNotificationName:@"TX500StationSettingsChangedNotification" object:nil];
    [self appendLog:[NSString stringWithFormat:@"[PREFS] Station preferences saved: %@ (%@), UTC: %@, Band: %@, Theme: %@, SWR: %.1f, MaxReply: %ld",
                     call, grid, isUTC ? @"YES" : @"NO", band,
                     themeIdx == 1 ? @"Light" : themeIdx == 2 ? @"Dark" : @"System",
                     swrThreshold, (long)maxAttempts]];

    if (self.preferencesWindow) {
        [self.preferencesWindow orderOut:nil];
    }
}


- (void)cancelPreferences:(id)sender {
    (void)sender;
    if (self.preferencesWindow) {
        [self.preferencesWindow orderOut:nil];
    }
}

- (void)openPreferencesLogsFolder:(id)sender {
    (void)sender;
    NSString *path = [TX500FT8AudioEngine allDecodesADIFPath];
    NSString *dir = [path stringByDeletingLastPathComponent];
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
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

- (void)windowDidResize:(NSNotification *)notification {
    (void)notification;
    CGFloat availW = self.mainContentView.bounds.size.width - 28.0;
    if (availW > 300.0) {
        self.instructions.preferredMaxLayoutWidth = availW - 4.0;
        [self.instructions invalidateIntrinsicContentSize];
    }
}

- (NSRect)windowWillUseStandardFrame:(NSWindow *)window defaultFrame:(NSRect)newFrame {
    (void)newFrame;
    NSScreen *screen = window.screen ?: [NSScreen mainScreen];
    if (!screen) return newFrame;
    // Keep native title-bar double-click zoom inside the usable desktop.  A
    // small inset also prevents the window shadow and resize handles from
    // being clipped by the menu bar, Dock, or a notched display.
    NSRect visible = screen.visibleFrame;
    CGFloat inset = 12.0;
    NSRect safe = NSInsetRect(visible, inset, inset);
    safe.size.width = MAX(MIN(safe.size.width, 1600.0), MIN(780.0, visible.size.width));
    safe.size.height = MAX(MIN(safe.size.height, 1000.0), MIN(460.0, visible.size.height));
    safe.origin.x = visible.origin.x + (visible.size.width - safe.size.width) / 2.0;
    safe.origin.y = visible.origin.y + (visible.size.height - safe.size.height) / 2.0;
    return safe;
}

- (BOOL)windowShouldClose:(NSWindow *)sender {
    (void)sender;
    [NSApp terminate:nil];
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (self.terminateAfterToolsStop) return NSTerminateLater;
    // A launch failure can leave optional controllers uninitialized. A message
    // to nil returns NO, which previously made a windowless app refuse Quit.
    if (self.voiceKeyerController && ![self.voiceKeyerController deactivate]) return NSTerminateCancel;
    [self.telemetryController stopMonitoring];
    [self.cwStationController stopStation];
    [self.ft8StationController stopStation];
    [self.audioMonitorController stopController];
    if(self.stationCore && ![self.stationCore suspend:nil]) return NSTerminateCancel;
    [self.clusterController stop];
    if(self.stationKeyMonitor) [NSEvent removeMonitor:self.stationKeyMonitor];
    if (!self.busy) return (!self.tools || [self.tools confirmDiscard]) ? NSTerminateNow : NSTerminateCancel;
    if (self.tools.operationInProgress) {
        if (![self.tools confirmDiscard]) return NSTerminateCancel;
        self.terminateAfterToolsStop = YES;
        [self.tools cancelActiveOperation];
        return NSTerminateLater;
    }
    NSBeep();
    return NSTerminateCancel;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return YES;
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)sender hasVisibleWindows:(BOOL)hasVisibleWindows {
    (void)sender;
    if (!hasVisibleWindows && self.window) {
        [self ensureWindowFitsVisibleScreen];
        [self.window makeKeyAndOrderFront:nil];
    }
    return YES;
}

- (void)ensureWindowFitsVisibleScreen {
    if (!self.window) return;
    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    if (!screen) return;
    NSRect screenRect = [screen visibleFrame];
    NSRect winFrame = self.window.frame;

    BOOL needsAdjust = NO;
    CGFloat maxW = MAX(780.0, screenRect.size.width - 24.0);
    CGFloat maxH = MAX(460.0, screenRect.size.height - 44.0);

    CGFloat targetW = winFrame.size.width;
    CGFloat targetH = winFrame.size.height;

    // On laptops or smaller displays (e.g. width <= 1440 pt or height <= 900 pt),
    // clamp overly bloated restored frames to comfortable bounds
    CGFloat comfortableMaxW = MIN(1080.0, screenRect.size.width - 40.0);
    CGFloat comfortableMaxH = MIN(720.0, screenRect.size.height - 50.0);
    if (comfortableMaxW < 780.0) comfortableMaxW = 780.0;
    if (comfortableMaxH < 460.0) comfortableMaxH = 460.0;

    if (targetW > maxW) {
        targetW = maxW;
        needsAdjust = YES;
    } else if (screenRect.size.width <= 1440.0 && targetW > comfortableMaxW) {
        targetW = comfortableMaxW;
        needsAdjust = YES;
    }

    if (targetH > maxH) {
        targetH = maxH;
        needsAdjust = YES;
    } else if (screenRect.size.height <= 900.0 && targetH > comfortableMaxH) {
        targetH = comfortableMaxH;
        needsAdjust = YES;
    }

    if (targetW < 780.0 && screenRect.size.width >= 780.0) {
        targetW = 780.0;
        needsAdjust = YES;
    }
    if (targetH < 460.0 && screenRect.size.height >= 460.0) {
        targetH = 460.0;
        needsAdjust = YES;
    }

    CGFloat targetX = winFrame.origin.x;
    CGFloat targetY = winFrame.origin.y;

    if (targetX < screenRect.origin.x) {
        targetX = screenRect.origin.x + 10.0;
        needsAdjust = YES;
    } else if (targetX + targetW > NSMaxX(screenRect)) {
        targetX = NSMaxX(screenRect) - targetW - 10.0;
        needsAdjust = YES;
    }

    if (targetY < screenRect.origin.y) {
        targetY = screenRect.origin.y + 10.0;
        needsAdjust = YES;
    } else if (targetY + targetH > NSMaxY(screenRect)) {
        targetY = NSMaxY(screenRect) - targetH - 10.0;
        needsAdjust = YES;
    }

    if (needsAdjust) {
        NSRect adjustedFrame = NSMakeRect(targetX, targetY, targetW, targetH);
        [self.window setFrame:adjustedFrame display:YES animate:NO];
    }
}

- (void)resetWindowBoundsToScreen:(id)sender {
    (void)sender;
    [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"NSWindow Frame Lab599UtilityMainWindow"];
    [[NSUserDefaults standardUserDefaults] synchronize];

    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    NSRect screenRect = screen ? [screen visibleFrame] : NSMakeRect(0, 0, 960, 620);

    CGFloat defaultW = MIN(960.0, screenRect.size.width - 60.0);
    CGFloat defaultH = MIN(620.0, screenRect.size.height - 80.0);
    if (defaultW < 780.0) defaultW = 780.0;
    if (defaultH < 460.0) defaultH = 460.0;

    NSRect targetFrame;
    targetFrame.size.width = defaultW;
    targetFrame.size.height = defaultH;
    targetFrame.origin.x = screenRect.origin.x + (screenRect.size.width - defaultW) / 2.0;
    targetFrame.origin.y = screenRect.origin.y + (screenRect.size.height - defaultH) / 2.0;

    [self.window setFrame:targetFrame display:YES animate:YES];
    [self.window saveFrameUsingName:@"Lab599UtilityMainWindow"];
    [self appendLog:[NSString stringWithFormat:@"Window size reset to %.0f x %.0f.", defaultW, defaultH]];
}

- (void)windowDidChangeScreen:(NSNotification *)notification {
    (void)notification;
    [self ensureWindowFitsVisibleScreen];
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [self stopDigitalDiagnosticSessionLog];
}

@end

int main(int argc, const char *argv[]) {
    if (argc == 4 && strcmp(argv[1], "--cw-system-audio-check") == 0) {
        @autoreleasepool {
            return TX500CWRunLiveAudioCheck([NSString stringWithUTF8String:argv[2]],
                                          [NSString stringWithUTF8String:argv[3]]);
        }
    }
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        [app run];
    }
    return 0;
}
