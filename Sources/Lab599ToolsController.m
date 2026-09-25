#import "Lab599ToolsController.h"
#import "TX500CATTest.h"
#import "TX500Configuration.h"
#import "TX500Transfer.h"
#import "TX500ProfilesAndBackup.h"
#import "TX500SettingsModel.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

@interface TXCATLatencyView : NSView
@property(nonatomic, strong) NSMutableArray<NSNumber *> *samples;
- (void)addMilliseconds:(double)milliseconds passed:(BOOL)passed;
@end

@implementation TXCATLatencyView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) self.samples = [NSMutableArray array];
    return self;
}
- (void)addMilliseconds:(double)milliseconds passed:(BOOL)passed {
    [self.samples addObject:@(passed ? MAX(1.0, milliseconds) : -MAX(1.0, milliseconds))];
    if (self.samples.count > 48) [self.samples removeObjectAtIndex:0];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    [[NSColor colorWithCalibratedWhite:0.5 alpha:0.08] setFill];
    NSRectFill(self.bounds);
    if (!self.samples.count) return;
    double maximum = 100.0;
    for (NSNumber *number in self.samples) maximum = MAX(maximum, fabs(number.doubleValue));
    CGFloat width = self.bounds.size.width / 48.0;
    for (NSUInteger index = 0; index < self.samples.count; index++) {
        double value = self.samples[index].doubleValue;
        CGFloat height = MAX(2.0, (CGFloat)(fabs(value) / maximum * (self.bounds.size.height - 4.0)));
        [(value < 0 ? NSColor.systemRedColor : NSColor.systemGreenColor) setFill];
        NSRectFill(NSMakeRect(index * width + 1.0, 2.0, MAX(1.0, width - 2.0), height));
    }
}
@end

@interface TXCATSMeterScaleView : NSView
@end

@implementation TXCATSMeterScaleView
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect;
    const NSInteger dots[] = {2, 6, 10, 14, 18, 22, 26, 30};
    NSArray<NSString *> *labels = @[@"S1", @"S3", @"S5", @"S7", @"S9", @"+20", @"+40", @"+60"];
    NSDictionary *attributes = @{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:8 weight:NSFontWeightMedium],
        NSForegroundColorAttributeName: NSColor.secondaryLabelColor
    };
    for (NSUInteger i = 0; i < labels.count; i++) {
        // The last tick must be inside the drawing bounds, exactly at the
        // visible end of the progress track rather than clipped at width.
        CGFloat trackStart = 1.0;
        CGFloat trackEnd = MAX(trackStart, self.bounds.size.width - 1.0);
        CGFloat tickX = trackStart + (trackEnd - trackStart) * dots[i] / 30.0;
        NSSize size = [labels[i] sizeWithAttributes:attributes];
        CGFloat textX = MAX(0, MIN(self.bounds.size.width - size.width, tickX - size.width / 2.0));
        [labels[i] drawAtPoint:NSMakePoint(textX, 0) withAttributes:attributes];
        [NSColor.tertiaryLabelColor setStroke];
        NSBezierPath *tick = [NSBezierPath bezierPath];
        [tick moveToPoint:NSMakePoint(tickX, 15)];
        [tick lineToPoint:NSMakePoint(tickX, 19)];
        [tick stroke];
    }
}
@end

@interface Lab599ToolsController ()
@property(nonatomic, strong, readwrite) NSView *view;
@property(nonatomic, strong) NSArray<NSView *> *panels;
@property(nonatomic, strong) NSMutableArray<NSControl *> *controls;
@property(nonatomic, strong) NSButton *catOnce, *catStart, *catStop, *stop, *settingsRead, *settingsWrite, *settingsSave, *settingsCompare;
@property(nonatomic, strong) NSButton *memoryRead, *memoryWrite, *memorySave, *memoryCompare, *csvImport, *csvExport;
@property(nonatomic, strong) NSPopUpButton *profilesPopup;
@property(nonatomic, strong) NSTextField *catResult, *catCounts, *settingsInfo, *memoryInfo, *frequency;
@property(nonatomic, strong) NSPopUpButton *mode, *preAtt;
@property(nonatomic, strong) NSTableView *table;
@property(nonatomic, strong) Lab599Cancellation *token;
@property(nonatomic, copy) NSData *settingsData;
@property(nonatomic, strong) NSMutableArray<TXMemoryChannel *> *channels;
@property(nonatomic, copy) NSString *settingsSource;
@property(nonatomic) BOOL busy, hasPorts, settingsDirty, memoryDirty, memoryReady;
@property(nonatomic) NSInteger tool;

// CAT Studio UI Controls
@property(nonatomic, strong) NSTextField *catModelLabel;
@property(nonatomic, strong) NSTextField *catFreqDisplay;
@property(nonatomic, strong) NSTextField *catModeBadge;
@property(nonatomic, strong) NSTextField *catPowerBadge;
@property(nonatomic, strong) NSTextField *catFilterBadge;
@property(nonatomic, strong) NSTextField *catPreampBadge;
@property(nonatomic, strong) NSTextField *catVoltageBadge;
@property(nonatomic, strong) NSTextField *catSMeterBadge;
@property(nonatomic, strong) NSProgressIndicator *catSMeterGauge;
@property(nonatomic, strong) NSTextField *catSMeterTitle;
@property(nonatomic, strong) NSStackView *catSMeterScaleRow;
@property(nonatomic) BOOL catIsTransmitting;
@property(nonatomic) BOOL catSMeterKnown;
@property(nonatomic) NSInteger catSMeterDots;
@property(nonatomic, strong) NSProgressIndicator *catVoltageGauge;
@property(nonatomic, strong) NSProgressIndicator *catPowerGauge;
@property(nonatomic, strong) NSTextField *catNotice;
@property(nonatomic, strong) NSBox *catNoticeBox;
@property(nonatomic, strong) NSButton *catReadAllButton;

@property(nonatomic, strong) NSTextField *catFreqInputField;
@property(nonatomic, strong) NSButton *catSetFreqButton;
@property(nonatomic, strong) NSPopUpButton *catStepPopup;
@property(nonatomic, strong) NSButton *catStepDownButton, *catStepUpButton;
@property(nonatomic, strong) NSPopUpButton *catModePopup;
@property(nonatomic, strong) NSButton *catSetModeButton;
@property(nonatomic, strong) NSPopUpButton *catPowerPopup;
@property(nonatomic, strong) NSButton *catSetPowerButton;
@property(nonatomic, strong) NSButton *catPreampToggle;
@property(nonatomic, strong) NSButton *catAttenuatorToggle;
@property(nonatomic, strong) NSSegmentedControl *catFilterSegment;
@property(nonatomic, strong) NSMutableArray<NSButton *> *bandButtons;

@property(nonatomic, strong) NSTextField *catCommandInput;
@property(nonatomic, strong) NSButton *catSendCommandButton;
@property(nonatomic, strong) NSTextView *catTerminalTextView;
@property(nonatomic, strong) NSButton *catClearTerminalButton;
@property(nonatomic, strong) NSButton *catCopyTerminalButton;
@property(nonatomic, strong) NSMutableArray<NSButton *> *quickCmdButtons;
@property(nonatomic, strong) NSPopUpButton *catLogFilter;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *catLogEntries;
@property(nonatomic, strong) TXCATLatencyView *catLatencyView;
@property(nonatomic, copy) NSString *verifiedCATPort;
@property(nonatomic, strong) NSLayoutConstraint *toolHeight;
@property(nonatomic, strong) NSLayoutConstraint *catBottomConstraint;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *studioMacros, *studioSnapshots, *monitorEntries;
@property(nonatomic, strong) NSPopUpButton *macroPopup, *snapshotPopup, *monitorFilter;
@property(nonatomic, strong) NSTextField *macroName, *snapshotName, *snapshotDetails, *monitorSummary;
@property(nonatomic, strong) NSTextView *macroCommands, *monitorText;
@property(nonatomic, strong) NSView *macroButtonCanvas;
@property(nonatomic, strong) NSButton *macroSave, *macroRun, *macroDelete, *snapshotCapture, *snapshotRestore, *snapshotDelete, *monitorPause, *monitorClear;
@property(nonatomic, strong) NSButton *macroStop, *snapshotStop;
@property(nonatomic, strong) TXCATLatencyView *monitorLatency;
@property(nonatomic) BOOL monitorPaused, monitorRedrawPending;


// Settings Editor
@property(nonatomic, strong) NSTableView *settingsTable;
@property(nonatomic, strong) NSArray<TXSettingsItem *> *allSettingsItems;
@property(nonatomic, strong) NSArray<TXSettingsItem *> *filteredSettingsItems;
@property(nonatomic, strong) NSPopUpButton *settingsCategoryFilter;
@property(nonatomic, strong) NSTextField *settingEditField;
@property(nonatomic, strong) NSTextField *settingEditLabel;
@property(nonatomic, strong) NSButton *settingApplyButton;
@property(nonatomic, strong) NSButton *settingsExportJson, *settingsImportJson;

// Backup Comparison Sheet
@property(nonatomic, strong) NSWindow *compareSheet;
@property(nonatomic, strong) NSTableView *compareTable;
@property(nonatomic, strong) NSTextField *compareSummaryLabel;
@property(nonatomic, strong) TXSettingsComparisonResult *activeSettingsDiff;
@property(nonatomic, strong) TXMemoryComparisonResult *activeMemoryDiff;
@property(nonatomic) BOOL isSettingsComparison;
@end

@implementation Lab599ToolsController

static NSTextField *Label(NSString *text) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.preferredMaxLayoutWidth = 350.0;
    label.textColor = NSColor.secondaryLabelColor;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    return label;
}

static NSStackView *Stack(NSArray<NSView *> *views, BOOL vertical) {
    NSStackView *s = [NSStackView stackViewWithViews:views];
    s.orientation = vertical ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
    s.alignment = vertical ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    s.spacing = 10;
    return s;
}

static NSView *CreateBadgePill(NSTextField *label, NSColor *bgColor) {
    NSView *pill = [NSView new];
    pill.wantsLayer = YES;
    pill.layer.backgroundColor = (bgColor ?: [NSColor colorWithCalibratedWhite:0.5 alpha:0.15]).CGColor;
    pill.layer.cornerRadius = 4.0;
    pill.translatesAutoresizingMaskIntoConstraints = NO;

    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.alignment = NSTextAlignmentCenter;
    label.drawsBackground = NO;
    label.bezeled = NO;
    label.editable = NO;
    label.selectable = NO;
    [pill addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:2],
        [label.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-2],
        [label.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
        [pill.heightAnchor constraintEqualToConstant:24]
    ]];
    return pill;
}

static NSBox *CreateCardWithView(NSView *innerView) {
    NSBox *box = [NSBox new];
    box.boxType = NSBoxCustom;
    box.borderWidth = 1.0;
    box.cornerRadius = 8.0;
    box.borderColor = [NSColor separatorColor];
    box.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.04];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    innerView.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:innerView];
    [NSLayoutConstraint activateConstraints:@[
        [innerView.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:12],
        [innerView.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-12],
        [innerView.topAnchor constraintEqualToAnchor:box.topAnchor constant:10],
        [innerView.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-10]
    ]];
    return box;
}

static NSScrollView *StudioTextScroll(NSTextView **textView, BOOL editable, CGFloat height) {
    NSScrollView *scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.wantsLayer = YES;
    scroll.layer.cornerRadius = 5;
    NSTextView *text = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 600, height)];
    text.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium];
    text.textColor = editable ? NSColor.labelColor : [NSColor colorWithCalibratedRed:0.45 green:0.9 blue:0.64 alpha:1];
    text.backgroundColor = editable ? NSColor.textBackgroundColor : [NSColor colorWithCalibratedRed:0.055 green:0.075 blue:0.09 alpha:1];
    text.editable = editable;
    text.selectable = YES;
    text.automaticQuoteSubstitutionEnabled = NO;
    text.automaticDashSubstitutionEnabled = NO;
    scroll.documentView = text;
    [scroll.heightAnchor constraintEqualToConstant:height].active = YES;
    if (textView) *textView = text;
    return scroll;
}

- (NSBox *)buildAutomationCard {
    NSTextField *title = [NSTextField labelWithString:@"CAT WORKSPACE"];
    title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightBold];
    title.textColor = NSColor.labelColor;
    NSTextField *subtitle = Label(@"Build repeatable actions, keep full radio snapshots, and inspect the CAT traffic generated by this app.");
    subtitle.font = [NSFont systemFontOfSize:11];
    subtitle.preferredMaxLayoutWidth = 1200;
    NSTabView *tabs = [NSTabView new];
    tabs.tabViewType = NSTopTabsBezelBorder;
    [tabs.heightAnchor constraintEqualToConstant:355].active = YES;

    self.macroPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.macroPopup.target = self; self.macroPopup.action = @selector(macroSelected:);
    self.macroName = [NSTextField new];
    self.macroName.placeholderString = @"Button name, e.g. FT8 Ready";
    self.macroSave = [NSButton buttonWithTitle:@"Save Macro" target:self action:@selector(saveMacro:)];
    self.macroDelete = [NSButton buttonWithTitle:@"Delete" target:self action:@selector(deleteMacro:)];
    self.macroRun = [NSButton buttonWithTitle:@"Run Saved" target:self action:@selector(runMacro:)];
    self.macroRun.bezelStyle = NSBezelStyleRounded;
    self.macroStop = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopOperation:)];
    self.macroStop.hidden = YES;
    NSTextView *macroText = nil;
    NSScrollView *macroScroll = StudioTextScroll(&macroText, YES, 125);
    self.macroCommands = macroText;
    self.macroCommands.string = @"MD6;\nPC050;\nFL1;";
    NSTextField *macroHelp = Label(@"One safe CAT command per line. FL1; selects RX filter 2 and keeps the TX filter. Every setter is read back; TX/PTT commands are blocked.");
    macroHelp.font = [NSFont systemFontOfSize:10];
    macroHelp.preferredMaxLayoutWidth = 1200;
    NSStackView *macroTop = Stack(@[Label(@"Saved:"), self.macroPopup, self.macroDelete, [NSView new]], NO);
    NSScrollView *quickScroll = [NSScrollView new];
    quickScroll.hasHorizontalScroller = YES;
    quickScroll.hasVerticalScroller = NO;
    quickScroll.drawsBackground = NO;
    quickScroll.borderType = NSNoBorder;
    self.macroButtonCanvas = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 600, 32)];
    quickScroll.documentView = self.macroButtonCanvas;
    [quickScroll.heightAnchor constraintEqualToConstant:42].active = YES;
    NSStackView *macroEdit = Stack(@[self.macroName, self.macroSave, self.macroRun, self.macroStop], NO);
    macroEdit.detachesHiddenViews = YES;
    NSStackView *macroPane = Stack(@[macroTop, quickScroll, macroEdit, macroScroll, macroHelp], YES);
    macroPane.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    // A tab item owns its view only after addTabViewItem:. Linking the pane to
    // tabs here raises NSGenericException during launch (no common ancestor).
    // NSTabView sizes each item view; the autoresizing mask follows that size.
    macroPane.edgeInsets = NSEdgeInsetsMake(10, 12, 10, 12);
    macroPane.spacing = 8;
    [macroTop.widthAnchor constraintEqualToAnchor:macroPane.widthAnchor constant:-24].active = YES;
    [quickScroll.widthAnchor constraintEqualToAnchor:macroPane.widthAnchor constant:-24].active = YES;
    [macroEdit.widthAnchor constraintEqualToAnchor:macroPane.widthAnchor constant:-24].active = YES;
    [macroScroll.widthAnchor constraintEqualToAnchor:macroPane.widthAnchor constant:-24].active = YES;
    NSTabViewItem *macroTab = [[NSTabViewItem alloc] initWithIdentifier:@"macros"];
    macroTab.label = @"CAT Macros"; macroTab.view = macroPane; [tabs addTabViewItem:macroTab];

    self.snapshotPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    self.snapshotPopup.target = self; self.snapshotPopup.action = @selector(snapshotSelected:);
    self.snapshotName = [NSTextField new];
    self.snapshotName.placeholderString = @"Profile name, e.g. CW Portable";
    [self.snapshotName.widthAnchor constraintGreaterThanOrEqualToConstant:240].active = YES;
    [self.snapshotName setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    self.snapshotCapture = [NSButton buttonWithTitle:@"Capture Radio…" target:self action:@selector(captureSnapshot:)];
    self.snapshotRestore = [NSButton buttonWithTitle:@"Restore & Verify…" target:self action:@selector(restoreSnapshot:)];
    self.snapshotDelete = [NSButton buttonWithTitle:@"Delete" target:self action:@selector(deleteSnapshot:)];
    self.snapshotStop = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopOperation:)];
    self.snapshotStop.hidden = YES;
    self.snapshotDetails = Label(@"Choose a saved snapshot or capture the connected radio. Each snapshot includes all 1024 settings bytes and available live dial readings.");
    self.snapshotDetails.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.snapshotDetails.textColor = NSColor.labelColor;
    self.snapshotDetails.preferredMaxLayoutWidth = 1200;
    NSStackView *snapTop = Stack(@[Label(@"Saved:"), self.snapshotPopup, self.snapshotDelete, [NSView new]], NO);
    NSStackView *snapCreate = Stack(@[self.snapshotName, self.snapshotCapture, self.snapshotRestore, self.snapshotStop], NO);
    snapCreate.detachesHiddenViews = YES;
    NSBox *snapInfo = CreateCardWithView(self.snapshotDetails);
    [snapInfo.heightAnchor constraintGreaterThanOrEqualToConstant:100].active = YES;
    NSTextField *snapHelp = Label(@"Restore first backs up the current radio, checks the model, writes the selected settings, and verifies every byte. A stopped write may leave partial changes.");
    snapHelp.font = [NSFont systemFontOfSize:10];
    snapHelp.preferredMaxLayoutWidth = 1200;
    NSStackView *snapPane = Stack(@[snapTop, snapCreate, snapInfo, snapHelp], YES);
    snapPane.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    snapPane.edgeInsets = NSEdgeInsetsMake(10, 12, 10, 12);
    snapPane.spacing = 10;
    [snapTop.widthAnchor constraintEqualToAnchor:snapPane.widthAnchor constant:-24].active = YES;
    [snapCreate.widthAnchor constraintEqualToAnchor:snapPane.widthAnchor constant:-24].active = YES;
    [snapInfo.widthAnchor constraintEqualToAnchor:snapPane.widthAnchor constant:-24].active = YES;
    NSTabViewItem *snapTab = [[NSTabViewItem alloc] initWithIdentifier:@"snapshots"];
    snapTab.label = @"Radio Snapshots"; snapTab.view = snapPane; [tabs addTabViewItem:snapTab];

    self.monitorFilter = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.monitorFilter addItemsWithTitles:@[@"All traffic", @"TX only", @"RX only", @"Errors"]];
    self.monitorFilter.target = self; self.monitorFilter.action = @selector(redrawMonitor:);
    self.monitorPause = [NSButton buttonWithTitle:@"Pause" target:self action:@selector(toggleMonitor:)];
    self.monitorClear = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearMonitor:)];
    NSButton *copy = [NSButton buttonWithTitle:@"Copy" target:self action:@selector(copyMonitor:)];
    NSStackView *monitorTop = Stack(@[Label(@"Show:"), self.monitorFilter, self.monitorPause, self.monitorClear, copy, [NSView new]], NO);
    NSTextView *monitorText = nil;
    NSScrollView *monitorScroll = StudioTextScroll(&monitorText, NO, 125);
    self.monitorText = monitorText;
    self.monitorSummary = Label(@"0 TX   ·   0 RX   ·   0 errors   ·   RTT —");
    self.monitorSummary.font = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium];
    self.monitorLatency = [[TXCATLatencyView alloc] initWithFrame:NSZeroRect];
    self.monitorLatency.toolTip = @"Recent app CAT response times; red bars are protocol error replies.";
    [self.monitorLatency.heightAnchor constraintEqualToConstant:30].active = YES;
    NSTextField *monitorHelp = Label(@"App-owned serial traffic only. The CAT port is exclusive; traffic from other applications is not captured.");
    monitorHelp.font = [NSFont systemFontOfSize:10];
    monitorHelp.preferredMaxLayoutWidth = 1200;
    NSStackView *monitorPane = Stack(@[monitorTop, monitorScroll, self.monitorSummary, self.monitorLatency, monitorHelp], YES);
    monitorPane.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    monitorPane.edgeInsets = NSEdgeInsetsMake(8, 12, 8, 12);
    monitorPane.spacing = 6;
    [monitorTop.widthAnchor constraintEqualToAnchor:monitorPane.widthAnchor constant:-24].active = YES;
    [monitorScroll.widthAnchor constraintEqualToAnchor:monitorPane.widthAnchor constant:-24].active = YES;
    [self.monitorLatency.widthAnchor constraintEqualToAnchor:monitorPane.widthAnchor constant:-24].active = YES;
    NSTabViewItem *monitorTab = [[NSTabViewItem alloc] initWithIdentifier:@"monitor"];
    monitorTab.label = @"Protocol Monitor"; monitorTab.view = monitorPane; [tabs addTabViewItem:monitorTab];

    [self.controls addObjectsFromArray:@[self.macroPopup, self.macroName, self.macroSave, self.macroDelete,
        self.macroRun, self.snapshotPopup, self.snapshotName, self.snapshotCapture, self.snapshotRestore, self.snapshotDelete]];
    [self reloadMacroMenu];
    [self reloadSnapshotMenu];
    NSStackView *inner = Stack(@[title, subtitle, tabs], YES);
    inner.spacing = 5;
    [tabs.widthAnchor constraintEqualToAnchor:inner.widthAnchor].active = YES;
    return CreateCardWithView(inner);
}

static NSString *ToolsFormatFreq(uint64_t hz) {
    uint64_t m = hz / 1000000;
    uint64_t k = (hz % 1000000) / 1000;
    uint64_t h = hz % 1000;
    return [NSString stringWithFormat:@"%llu.%03llu.%03llu MHz", m, k, h];
}

static NSString *ToolsFormatInputFrequency(uint64_t hz) {
    return [NSString stringWithFormat:@"%llu.%03llu.%03llu", hz / 1000000,
            (hz % 1000000) / 1000, hz % 1000];
}

static uint64_t ToolsParseInputFrequency(NSString *input) {
    NSString *raw = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([raw containsString:@"."] || [raw containsString:@","]) {
        NSString *grouped = [raw stringByReplacingOccurrencesOfString:@"," withString:@"."];
        NSRegularExpression *pattern = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]{1,3}(\\.[0-9]{3})+$"
                                                                              options:0 error:NULL];
        if ([pattern numberOfMatchesInString:grouped options:0 range:NSMakeRange(0, grouped.length)] != 1) return 0;
    }
    raw = [[raw stringByReplacingOccurrencesOfString:@"." withString:@""]
           stringByReplacingOccurrencesOfString:@"," withString:@""];
    if (!raw.length || [raw rangeOfCharacterFromSet:
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet]].location != NSNotFound) return 0;
    unsigned long long value = 0;
    NSScanner *scanner = [NSScanner scannerWithString:raw];
    if (![scanner scanUnsignedLongLong:&value] || !scanner.isAtEnd) return 0;
    return (uint64_t)value;
}

static NSString *ToolsSMeterReading(NSInteger dots, BOOL transmitting) {
    NSInteger bounded = MAX(0, MIN(30, dots));
    if (transmitting) return [NSString stringWithFormat:@"TX meter: %ld/30 dots", (long)bounded];
    if (bounded <= 18) return [NSString stringWithFormat:@"S-MTR: S%ld", (long)((bounded + 1) / 2)];
    return [NSString stringWithFormat:@"S-MTR: S9+%ld dB", (long)((bounded - 18) * 5)];
}

static NSInteger ToolsBandIndexForFrequency(uint64_t hz) {
    // Keep CAT Studio aligned with the band ranges used by the FT8 station.
    const struct { uint64_t low, high; } bands[] = {
        {1800000, 2000000}, {3500000, 4000000},
        {7000000, 7300000}, {10100000, 10150000},
        {14000000, 14350000}, {18068000, 18168000},
        {21000000, 21450000}, {24890000, 24990000},
        {28000000, 29700000}, {50000000, 54000000}
    };
    for (NSUInteger i = 0; i < sizeof(bands) / sizeof(bands[0]); i++) {
        if (hz >= bands[i].low && hz <= bands[i].high) return (NSInteger)i;
    }
    return -1;
}

static NSString *ToolsModeNameFromCode(NSInteger code) {
    switch (code) {
        case 1: return @"LSB";
        case 2: return @"USB";
        case 3: return @"CW";
        case 4: return @"FM";
        case 5: return @"AM";
        case 6: return @"DIG (FSK)";
        case 7: return @"CWR";
        default: return @"USB";
    }
}

static inline BOOL ToolsIsCATSetCommand(NSString *cmd) {
    if (!cmd.length) return NO;
    NSString *c = [[cmd stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                   stringByReplacingOccurrencesOfString:@";" withString:@""];
    if (c.length > 2) {
        if ([c hasPrefix:@"SM"]) return NO;
        return YES;
    }
    return NO;
}

- (NSButton *)button:(NSString *)title action:(SEL)action tag:(NSInteger)tag {
    NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
    b.tag = tag;
    [self.controls addObject:b];
    return b;
}

- (NSView *)buildCATStudioView {
    // =========================================================================
    // LEFT COLUMN: Live State Inspector (Card 1) + Quick Control (Card 2)
    // =========================================================================

    // --- Card 1: Live State Inspector ---
    NSTextField *c1Title = [NSTextField labelWithString:@"Live State Inspector"];
    c1Title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    c1Title.textColor = NSColor.labelColor;

    self.catReadAllButton = [NSButton buttonWithTitle:@"Read All from Radio" target:self action:@selector(readRadioStateAction:)];
    self.catReadAllButton.bezelStyle = NSBezelStyleRounded;
    self.catReadAllButton.controlSize = NSControlSizeSmall;
    [self.controls addObject:self.catReadAllButton];

    NSStackView *c1Header = [NSStackView stackViewWithViews:@[c1Title, self.catReadAllButton]];
    c1Header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    c1Header.distribution = NSStackViewDistributionEqualSpacing;

    // Dark OLED-style frequency & model banner
    self.catModelLabel = [NSTextField labelWithString:@"Transceiver Model: —"];
    self.catModelLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    self.catModelLabel.textColor = [NSColor colorWithCalibratedRed:0.86 green:0.91 blue:0.96 alpha:1.0];

    self.catFreqDisplay = [NSTextField labelWithString:@"— . — . — MHz"];
    self.catFreqDisplay.font = [NSFont monospacedDigitSystemFontOfSize:22 weight:NSFontWeightBold];
    self.catFreqDisplay.textColor = [NSColor colorWithCalibratedRed:0.25 green:0.75 blue:1.0 alpha:1.0];
    self.catFreqDisplay.alignment = NSTextAlignmentLeft;

    self.catStepPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.catStepPopup addItemsWithTitles:@[@"100 Hz", @"1 kHz", @"10 kHz"]];
    [self.catStepPopup selectItemAtIndex:1];
    self.catStepPopup.controlSize = NSControlSizeSmall;
    self.catStepDownButton = [NSButton buttonWithTitle:@"−" target:self action:@selector(stepFrequencyAction:)];
    self.catStepDownButton.tag = -1;
    self.catStepDownButton.toolTip = @"Tune the displayed radio frequency down by the selected step.";
    self.catStepUpButton = [NSButton buttonWithTitle:@"+" target:self action:@selector(stepFrequencyAction:)];
    self.catStepUpButton.tag = 1;
    self.catStepUpButton.toolTip = @"Tune the displayed radio frequency up by the selected step.";
    for (NSButton *button in @[self.catStepDownButton, self.catStepUpButton]) button.controlSize = NSControlSizeSmall;
    [self.controls addObjectsFromArray:@[self.catStepPopup, self.catStepDownButton, self.catStepUpButton]];
    NSTextField *stepLabel = [NSTextField labelWithString:@"Step:"];
    stepLabel.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
    stepLabel.textColor = [NSColor colorWithCalibratedWhite:0.86 alpha:1.0];
    NSStackView *stepRow = Stack(@[stepLabel, self.catStepDownButton, self.catStepPopup, self.catStepUpButton], NO);
    stepRow.spacing = 6;

    NSStackView *freqBoxInner = Stack(@[self.catModelLabel, self.catFreqDisplay, stepRow], YES);
    freqBoxInner.spacing = 2;
    freqBoxInner.edgeInsets = NSEdgeInsetsMake(6, 10, 6, 10);

    NSBox *freqBanner = [NSBox new];
    freqBanner.boxType = NSBoxCustom;
    freqBanner.cornerRadius = 6.0;
    freqBanner.borderWidth = 1.0;
    freqBanner.borderColor = [NSColor colorWithCalibratedWhite:0.3 alpha:0.4];
    freqBanner.fillColor = [NSColor colorWithCalibratedRed:0.06 green:0.08 blue:0.11 alpha:0.9];
    freqBanner.translatesAutoresizingMaskIntoConstraints = NO;
    [freqBanner.heightAnchor constraintEqualToConstant:88].active = YES;
    [freqBanner addSubview:freqBoxInner];
    freqBoxInner.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [freqBoxInner.leadingAnchor constraintEqualToAnchor:freqBanner.leadingAnchor],
        [freqBoxInner.trailingAnchor constraintEqualToAnchor:freqBanner.trailingAnchor],
        [freqBoxInner.topAnchor constraintEqualToAnchor:freqBanner.topAnchor],
        [freqBoxInner.bottomAnchor constraintEqualToAnchor:freqBanner.bottomAnchor]
    ]];

    // Telemetry Badges (2 rows of 3 badges, vertically centered inside pill containers)
    self.catModeBadge = [NSTextField labelWithString:@"MODE: —"];
    self.catModeBadge.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold];
    self.catPowerBadge = [NSTextField labelWithString:@"PWR: —"];
    self.catPowerBadge.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold];
    self.catFilterBadge = [NSTextField labelWithString:@"FIL: —"];
    self.catFilterBadge.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold];
    self.catPreampBadge = [NSTextField labelWithString:@"PRE: —"];
    self.catPreampBadge.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold];
    self.catVoltageBadge = [NSTextField labelWithString:@"VOLT: —"];
    self.catVoltageBadge.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold];
    self.catSMeterBadge = [NSTextField labelWithString:@"S-MTR: —"];
    self.catSMeterBadge.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightSemibold];

    self.catSMeterGauge = [NSProgressIndicator new];
    self.catSMeterGauge.style = NSProgressIndicatorStyleBar;
    self.catSMeterGauge.indeterminate = NO;
    self.catSMeterGauge.maxValue = 30;
    self.catSMeterGauge.doubleValue = 0;
    self.catSMeterGauge.toolTip = @"RX display scale uses 0–30 raw CAT dots; SM0 reports TX meter dots during transmit.";
    self.catVoltageGauge = [NSProgressIndicator new];
    self.catVoltageGauge.style = NSProgressIndicatorStyleBar;
    self.catVoltageGauge.indeterminate = NO;
    self.catVoltageGauge.maxValue = 20;
    self.catVoltageGauge.doubleValue = 0;
    self.catVoltageGauge.toolTip = @"Supply voltage, updated by Read All";
    self.catPowerGauge = [NSProgressIndicator new];
    self.catPowerGauge.style = NSProgressIndicatorStyleBar;
    self.catPowerGauge.indeterminate = NO;
    self.catPowerGauge.maxValue = 10;
    self.catPowerGauge.doubleValue = 0;
    self.catPowerGauge.toolTip = @"Configured RF power (PC), not measured output power";

    NSView *pPreamp = CreateBadgePill(self.catPreampBadge, nil);
    NSView *pVoltage = CreateBadgePill(self.catVoltageBadge, nil);
    NSView *pSMeter = CreateBadgePill(self.catSMeterBadge, nil);

    NSStackView *badgeRow2 = Stack(@[pPreamp, pVoltage, pSMeter], NO);
    badgeRow2.distribution = NSStackViewDistributionFillEqually;
    badgeRow2.spacing = 6;

    self.catSMeterTitle = Label(@"S-Meter");
    NSTextField *voltageTitle = Label(@"Voltage");
    NSTextField *powerTitle = Label(@"Set Pwr");
    for (NSTextField *title in @[self.catSMeterTitle, voltageTitle, powerTitle]) {
        title.font = [NSFont systemFontOfSize:10 weight:NSFontWeightMedium];
        [title.widthAnchor constraintEqualToConstant:52].active = YES;
    }
    NSStackView *sMeterRow = Stack(@[self.catSMeterTitle, self.catSMeterGauge], NO);
    NSView *scaleIndent = [NSView new];
    [scaleIndent.widthAnchor constraintEqualToConstant:52].active = YES;
    TXCATSMeterScaleView *scale = [TXCATSMeterScaleView new];
    scale.toolTip = @"RX scale follows the radio display: S1–S9, then S9+20/+40/+60 dB (30 raw dots).";
    [scale setAccessibilityLabel:@"S-meter scale: S1, S3, S5, S7, S9, plus 20, plus 40, plus 60 dB"];
    [scale.heightAnchor constraintEqualToConstant:21].active = YES;
    self.catSMeterScaleRow = Stack(@[scaleIndent, scale], NO);
    NSStackView *voltageRow = Stack(@[voltageTitle, self.catVoltageGauge], NO);
    NSStackView *powerMeterRow = Stack(@[powerTitle, self.catPowerGauge], NO);
    NSStackView *meterGroup = Stack(@[sMeterRow, self.catSMeterScaleRow, voltageRow, powerMeterRow], YES);
    meterGroup.spacing = 4;

    // --- Card 2: Quick Control & Band Presets ---
    NSTextField *c2Title = [NSTextField labelWithString:@"Controls & Band Presets"];
    c2Title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];

    // Frequency tuning row
    self.catFreqInputField = [NSTextField new];
    self.catFreqInputField.placeholderString = @"14.074.000";
    self.catFreqInputField.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    self.catFreqInputField.target = self;
    self.catFreqInputField.action = @selector(setFrequencyAction:);

    self.catSetFreqButton = [NSButton buttonWithTitle:@"Tune" target:self action:@selector(setFrequencyAction:)];
    self.catSetFreqButton.bezelStyle = NSBezelStyleRounded;
    self.catSetFreqButton.controlSize = NSControlSizeSmall;
    [self.catSetFreqButton.widthAnchor constraintEqualToConstant:65].active = YES;
    [self.controls addObjectsFromArray:@[self.catFreqInputField, self.catSetFreqButton]];

    NSTextField *hzLabel = Label(@"Tune Hz:");
    hzLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    [hzLabel.widthAnchor constraintEqualToConstant:55].active = YES;

    NSStackView *freqRow = Stack(@[hzLabel, self.catFreqInputField, self.catSetFreqButton], NO);
    freqRow.spacing = 6;

    // Two fixed rows keep 160m and 80m visible at every supported window width.
    self.bandButtons = [NSMutableArray array];
    struct { const char *band; uint64_t freq; } bands[] = {
        {"160m", 1840000}, {"80m", 3573000}, {"40m", 7074000}, {"30m", 10136000},
        {"20m", 14074000}, {"17m", 18100000}, {"15m", 21074000},
        {"12m", 24915000}, {"10m", 28074000}, {"6m", 50313000}
    };
    NSMutableArray *bandRow1Views = [NSMutableArray array];
    NSMutableArray *bandRow2Views = [NSMutableArray array];
    for (int i = 0; i < 10; i++) {
        NSButton *bb = [NSButton buttonWithTitle:@(bands[i].band) target:self action:@selector(bandPresetClicked:)];
        bb.tag = (NSInteger)bands[i].freq;
        bb.bezelStyle = NSBezelStyleInline;
        [bb setButtonType:NSButtonTypePushOnPushOff];
        bb.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
        bb.wantsLayer = YES;
        bb.layer.cornerRadius = 6.0;
        bb.layer.masksToBounds = YES;
        [self.bandButtons addObject:bb];
        [self.controls addObject:bb];
        if (i < 5) {
            [bandRow1Views addObject:bb];
        } else {
            [bandRow2Views addObject:bb];
        }
    }
    NSStackView *bandRow1 = Stack(bandRow1Views, NO);
    bandRow1.distribution = NSStackViewDistributionFillEqually;
    bandRow1.spacing = 5;

    NSStackView *bandRow2 = Stack(bandRow2Views, NO);
    bandRow2.distribution = NSStackViewDistributionFillEqually;
    bandRow2.spacing = 5;

    // Mode & RF Power Row
    self.catModePopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.catModePopup addItemsWithTitles:@[@"LSB", @"USB", @"CW", @"FM", @"AM", @"DIG (FSK)", @"CWR"]];
    [self.catModePopup selectItemWithTitle:@"USB"];
    self.catModePopup.controlSize = NSControlSizeSmall;
    self.catModePopup.font = [NSFont systemFontOfSize:11];

    self.catSetModeButton = [NSButton buttonWithTitle:@"Set Mode" target:self action:@selector(setModeAction:)];
    self.catSetModeButton.bezelStyle = NSBezelStyleRounded;
    self.catSetModeButton.controlSize = NSControlSizeSmall;

    self.catPowerPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.catPowerPopup addItemsWithTitles:@[@"1 W", @"2 W", @"3 W", @"5 W", @"7 W", @"10 W"]];
    [self.catPowerPopup selectItemWithTitle:@"10 W"];
    self.catPowerPopup.controlSize = NSControlSizeSmall;
    self.catPowerPopup.font = [NSFont systemFontOfSize:11];

    self.catSetPowerButton = [NSButton buttonWithTitle:@"Set Power" target:self action:@selector(setPowerAction:)];
    self.catSetPowerButton.bezelStyle = NSBezelStyleRounded;
    self.catSetPowerButton.controlSize = NSControlSizeSmall;

    [self.controls addObjectsFromArray:@[self.catModePopup, self.catSetModeButton, self.catPowerPopup, self.catSetPowerButton]];

    NSStackView *modeGroup = Stack(@[Label(@"Mode:"), self.catModePopup, self.catSetModeButton], NO);
    modeGroup.spacing = 4;

    NSStackView *powerGroup = Stack(@[Label(@"RF Pwr:"), self.catPowerPopup, self.catSetPowerButton], NO);
    powerGroup.spacing = 4;

    NSStackView *modePowerRow = Stack(@[modeGroup, [NSView new], powerGroup], NO);
    modePowerRow.distribution = NSStackViewDistributionEqualSpacing;

    // Frontend toggles row
    self.catPreampToggle = [NSButton checkboxWithTitle:@"Preamp" target:self action:@selector(togglePreampAction:)];
    self.catPreampToggle.controlSize = NSControlSizeSmall;
    self.catPreampToggle.font = [NSFont systemFontOfSize:11];
    self.catPreampToggle.allowsMixedState = YES;

    self.catAttenuatorToggle = [NSButton checkboxWithTitle:@"Attenuator" target:self action:@selector(toggleAttenuatorAction:)];
    self.catAttenuatorToggle.controlSize = NSControlSizeSmall;
    self.catAttenuatorToggle.font = [NSFont systemFontOfSize:11];
    self.catAttenuatorToggle.allowsMixedState = YES;

    self.catFilterSegment = [NSSegmentedControl segmentedControlWithLabels:@[@"FIL 1", @"FIL 2", @"FIL 3", @"FIL 4"]
                                                              trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                    target:self
                                                                    action:@selector(filterChangedAction:)];
    self.catFilterSegment.selectedSegment = -1;
    self.catFilterSegment.controlSize = NSControlSizeSmall;
    [self.controls addObjectsFromArray:@[self.catPreampToggle, self.catAttenuatorToggle, self.catFilterSegment]];

    NSStackView *frontendRow = Stack(@[
        Label(@"Frontend:"),
        self.catPreampToggle,
        self.catAttenuatorToggle,
        Label(@"|"),
        Label(@"Filter:"),
        self.catFilterSegment
    ], NO);
    frontendRow.spacing = 6;

    NSStackView *c1Inner = Stack(@[c1Header, freqBanner, badgeRow2, meterGroup,
                                  c2Title, freqRow, bandRow1, bandRow2, modePowerRow, frontendRow], YES);
    c1Inner.spacing = 7;
    NSBox *card1 = CreateCardWithView(c1Inner);

    NSStackView *leftColumn = Stack(@[card1], YES);

    // =========================================================================
    // RIGHT COLUMN: Interactive Terminal (Card 3) + Diagnostics (Card 4)
    // =========================================================================

    // --- Card 3: Interactive CAT Command Terminal ---
    NSTextField *c3Title = [NSTextField labelWithString:@"CAT Command Terminal & Live Log"];
    c3Title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];

    self.catClearTerminalButton = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearTerminalAction:)];
    self.catClearTerminalButton.bezelStyle = NSBezelStyleInline;
    self.catClearTerminalButton.controlSize = NSControlSizeSmall;

    self.catCopyTerminalButton = [NSButton buttonWithTitle:@"Copy Log" target:self action:@selector(copyTerminalLogAction:)];
    self.catCopyTerminalButton.bezelStyle = NSBezelStyleInline;
    self.catCopyTerminalButton.controlSize = NSControlSizeSmall;

    [self.controls addObjectsFromArray:@[self.catClearTerminalButton, self.catCopyTerminalButton]];

    NSStackView *c3Header = [NSStackView stackViewWithViews:@[c3Title, self.catClearTerminalButton, self.catCopyTerminalButton]];
    c3Header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    c3Header.spacing = 6;

    // Command Input Row
    self.catCommandInput = [NSTextField new];
    self.catCommandInput.placeholderString = @"Raw CAT Command (e.g. FA; MD2; PC005;)";
    self.catCommandInput.font = [NSFont fontWithName:@"Menlo" size:11.5] ?: [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightRegular];
    self.catCommandInput.target = self;
    self.catCommandInput.action = @selector(sendCommandAction:);

    self.catSendCommandButton = [NSButton buttonWithTitle:@"Send" target:self action:@selector(sendCommandAction:)];
    self.catSendCommandButton.bezelStyle = NSBezelStyleRounded;
    self.catSendCommandButton.controlSize = NSControlSizeSmall;
    self.catSendCommandButton.keyEquivalent = @"\r"; // Enter triggers send!
    [self.catSendCommandButton.widthAnchor constraintEqualToConstant:60].active = YES;

    [self.controls addObjectsFromArray:@[self.catCommandInput, self.catSendCommandButton]];

    NSTextField *cmdPrompt = [NSTextField labelWithString:@"CMD >"];
    cmdPrompt.font = [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightBold];
    cmdPrompt.textColor = [NSColor systemGreenColor];

    NSStackView *cmdInputRow = Stack(@[cmdPrompt, self.catCommandInput, self.catSendCommandButton], NO);
    cmdInputRow.spacing = 6;

    // Quick Command Preset Chips
    self.quickCmdButtons = [NSMutableArray array];
    NSArray *chips = @[@"FA;", @"MD;", @"PC;", @"IF;", @"VL;", @"ID;", @"SM0;", @"FL;"];
    NSDictionary *chipNames = @{@"FA;": @"Freq", @"MD;": @"Mode", @"PC;": @"Power",
        @"IF;": @"Status", @"VL;": @"Voltage", @"ID;": @"Radio ID",
        @"SM0;": @"S-Meter", @"FL;": @"Filter"};
    NSDictionary *chipHelp = @{@"FA;": @"Read VFO-A frequency", @"MD;": @"Read operating mode",
        @"PC;": @"Read configured RF power", @"IF;": @"Read transceiver status",
        @"VL;": @"Read supply voltage", @"ID;": @"Identify the radio",
        @"SM0;": @"Read S-meter", @"FL;": @"Read selected filter"};
    NSMutableArray *chipViews = [NSMutableArray array];
    for (NSString *cmd in chips) {
        NSButton *cb = [NSButton buttonWithTitle:chipNames[cmd] target:self action:@selector(quickCommandChipClicked:)];
        cb.identifier = cmd;
        cb.bezelStyle = NSBezelStyleRounded;
        cb.controlSize = NSControlSizeSmall;
        cb.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightMedium];
        cb.toolTip = [NSString stringWithFormat:@"%@ (%@)", chipHelp[cmd], cmd];
        [self.quickCmdButtons addObject:cb];
        [self.controls addObject:cb];
        [chipViews addObject:cb];
    }
    NSStackView *chipsRow = Stack(chipViews, NO);
    chipsRow.distribution = NSStackViewDistributionFillEqually;
    chipsRow.spacing = 4;

    self.catLogFilter = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.catLogFilter addItemsWithTitles:@[@"All traffic", @"TX only", @"RX only"]];
    self.catLogFilter.controlSize = NSControlSizeSmall;
    self.catLogFilter.target = self;
    self.catLogFilter.action = @selector(catLogFilterChanged:);
    NSStackView *logFilterRow = Stack(@[Label(@"Show:"), self.catLogFilter], NO);
    logFilterRow.spacing = 5;

    // Terminal Monospace Text View
    NSScrollView *termScroll = [NSScrollView new];
    termScroll.hasVerticalScroller = YES;
    termScroll.borderType = NSBezelBorder;
    [termScroll.heightAnchor constraintEqualToConstant:145].active = YES;

    self.catTerminalTextView = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 420, 145)];
    self.catTerminalTextView.editable = NO;
    self.catTerminalTextView.selectable = YES;
    self.catTerminalTextView.backgroundColor = [NSColor colorWithCalibratedRed:0.07 green:0.08 blue:0.10 alpha:1.0];
    self.catTerminalTextView.textColor = [NSColor colorWithCalibratedRed:0.35 green:0.92 blue:0.45 alpha:1.0];
    self.catTerminalTextView.font = [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.catTerminalTextView.autoresizingMask = NSViewWidthSizable;
    self.catTerminalTextView.textContainer.widthTracksTextView = YES;
    self.catTerminalTextView.textContainerInset = NSMakeSize(6, 6);
    termScroll.documentView = self.catTerminalTextView;

    NSStackView *c3Inner = Stack(@[c3Header, cmdInputRow, chipsRow, logFilterRow, termScroll], YES);
    c3Inner.spacing = 6;
    NSBox *card3 = CreateCardWithView(c3Inner);

    // --- Card 4: Diagnostics & Latency Ping ---
    NSTextField *c4Title = [NSTextField labelWithString:@"Diagnostics & Latency Ping"];
    c4Title.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];

    self.catResult = Label(@"Ready to test CAT communication.");
    self.catResult.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    self.catResult.textColor = NSColor.labelColor;

    self.catOnce = [self button:@"Ping Once" action:@selector(startCAT:) tag:1];
    self.catOnce.bezelStyle = NSBezelStyleRounded;
    self.catOnce.controlSize = NSControlSizeSmall;

    self.catStart = [self button:@"Continuous Ping" action:@selector(startCAT:) tag:0];
    self.catStart.bezelStyle = NSBezelStyleRounded;
    self.catStart.controlSize = NSControlSizeSmall;

    self.catStop = [self button:@"Stop" action:@selector(stopOperation:) tag:0];
    self.catStop.bezelStyle = NSBezelStyleRounded;
    self.catStop.controlSize = NSControlSizeSmall;
    self.catStop.toolTip = @"Stop the current CAT operation and close its serial port.";
    self.catStop.keyEquivalent = @"\e";

    self.catCounts = Label(@"Checks: 0    Passed: 0    Failed: 0    RTT: —");
    self.catCounts.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    self.catLatencyView = [[TXCATLatencyView alloc] initWithFrame:NSMakeRect(0, 0, 420, 34)];
    self.catLatencyView.toolTip = @"Recent CAT ping times; green passed, red failed";
    [self.catLatencyView.heightAnchor constraintEqualToConstant:34].active = YES;

    NSStackView *pingRow = Stack(@[self.catOnce, self.catStart, self.catStop, [NSView new]], NO);
    pingRow.spacing = 8;
    pingRow.detachesHiddenViews = YES;

    NSTextField *pttGuard = Label(@"Ping sends ID; only. Raw CAT commands can change radio state or key TX.");
    pttGuard.font = [NSFont systemFontOfSize:10 weight:NSFontWeightRegular];
    pttGuard.textColor = NSColor.secondaryLabelColor;

    NSStackView *c4Inner = Stack(@[c4Title, self.catResult, pingRow, self.catCounts, self.catLatencyView, pttGuard], YES);
    c4Inner.spacing = 5;
    NSBox *card4 = CreateCardWithView(c4Inner);

    NSStackView *rightColumn = Stack(@[card3, card4], YES);
    rightColumn.spacing = 10;

    // Visible connection and command failures stay close to the controls.
    self.catNotice = [NSTextField wrappingLabelWithString:@"CAT port available — use Read All to confirm radio communication."];
    self.catNotice.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
    self.catNotice.textColor = NSColor.secondaryLabelColor;
    self.catNoticeBox = CreateCardWithView(self.catNotice);
    self.catNoticeBox.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.08];

    NSStackView *columns = [NSStackView stackViewWithViews:@[leftColumn, rightColumn]];
    columns.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    columns.alignment = NSLayoutAttributeTop;
    columns.distribution = NSStackViewDistributionFillEqually;
    columns.spacing = 12;
    NSBox *automationCard = [self buildAutomationCard];
    NSStackView *studioView = Stack(@[self.catNoticeBox, columns, automationCard], YES);
    studioView.spacing = 8;
    [self.catNoticeBox.widthAnchor constraintEqualToAnchor:studioView.widthAnchor].active = YES;
    [columns.widthAnchor constraintEqualToAnchor:studioView.widthAnchor].active = YES;
    [automationCard.widthAnchor constraintEqualToAnchor:studioView.widthAnchor].active = YES;

    // Anchor widths to guarantee full column width utilization
    [card1.widthAnchor constraintEqualToAnchor:leftColumn.widthAnchor].active = YES;
    [card3.widthAnchor constraintEqualToAnchor:rightColumn.widthAnchor].active = YES;
    [card4.widthAnchor constraintEqualToAnchor:rightColumn.widthAnchor].active = YES;

    [freqBanner.widthAnchor constraintEqualToAnchor:c1Inner.widthAnchor].active = YES;
    [badgeRow2.widthAnchor constraintEqualToAnchor:c1Inner.widthAnchor].active = YES;
    [meterGroup.widthAnchor constraintEqualToAnchor:c1Inner.widthAnchor].active = YES;
    [sMeterRow.widthAnchor constraintEqualToAnchor:meterGroup.widthAnchor].active = YES;
    [self.catSMeterScaleRow.widthAnchor constraintEqualToAnchor:meterGroup.widthAnchor].active = YES;
    [scale.widthAnchor constraintEqualToAnchor:self.catSMeterGauge.widthAnchor].active = YES;
    [voltageRow.widthAnchor constraintEqualToAnchor:meterGroup.widthAnchor].active = YES;
    [powerMeterRow.widthAnchor constraintEqualToAnchor:meterGroup.widthAnchor].active = YES;
    [freqRow.widthAnchor constraintEqualToAnchor:c1Inner.widthAnchor].active = YES;
    [bandRow1.widthAnchor constraintEqualToAnchor:c1Inner.widthAnchor].active = YES;
    [bandRow2.widthAnchor constraintEqualToAnchor:c1Inner.widthAnchor].active = YES;
    [modePowerRow.widthAnchor constraintEqualToAnchor:c1Inner.widthAnchor].active = YES;
    [frontendRow.widthAnchor constraintEqualToAnchor:c1Inner.widthAnchor].active = YES;
    [c3Header.widthAnchor constraintEqualToAnchor:c3Inner.widthAnchor].active = YES;
    [cmdInputRow.widthAnchor constraintEqualToAnchor:c3Inner.widthAnchor].active = YES;
    [chipsRow.widthAnchor constraintEqualToAnchor:c3Inner.widthAnchor].active = YES;
    [termScroll.widthAnchor constraintEqualToAnchor:c3Inner.widthAnchor].active = YES;
    [self.catLatencyView.widthAnchor constraintEqualToAnchor:c4Inner.widthAnchor].active = YES;

    return studioView;
}

static NSString *StudioTimestamp(NSDate *date) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [formatter stringFromDate:date ?: [NSDate date]];
}

- (void)reloadMacroMenu {
    [self.macroPopup removeAllItems];
    [self.macroPopup addItemWithTitle:@"Choose a macro…"];
    for (NSDictionary *macro in self.studioMacros) [self.macroPopup addItemWithTitle:macro[@"name"] ?: @"Untitled"];
    [self.macroPopup selectItemAtIndex:0];
    for (NSView *view in self.macroButtonCanvas.subviews.copy) [view removeFromSuperview];
    CGFloat x = 0;
    for (NSUInteger i = 0; i < self.studioMacros.count; i++) {
        NSString *name = self.studioMacros[i][@"name"] ?: @"Untitled";
        CGFloat width = MIN(190, MAX(96, name.length * 8 + 24));
        NSButton *button = [NSButton buttonWithTitle:name target:self action:@selector(runMacroButton:)];
        button.tag = i;
        button.bezelStyle = NSBezelStyleRounded;
        button.contentTintColor = NSColor.systemBlueColor;
        button.frame = NSMakeRect(x, 2, width, 27);
        button.toolTip = [NSString stringWithFormat:@"Run saved macro: %@", name];
        [self.macroButtonCanvas addSubview:button];
        x += width + 7;
    }
    if (!self.studioMacros.count) {
        NSTextField *empty = Label(@"Save a macro to add its quick-launch button here.");
        empty.frame = NSMakeRect(3, 5, 390, 22);
        [self.macroButtonCanvas addSubview:empty];
    }
    self.macroButtonCanvas.frame = NSMakeRect(0, 0, MAX(600, x), 32);
}

- (void)runMacroButton:(NSButton *)sender {
    if (self.busy) return;
    [self.macroPopup selectItemAtIndex:sender.tag + 1];
    [self macroSelected:nil];
    [self runMacro:sender];
}

- (void)macroSelected:(id)sender {
    (void)sender;
    NSInteger index = self.macroPopup.indexOfSelectedItem - 1;
    if (index >= 0 && index < (NSInteger)self.studioMacros.count) {
        NSDictionary *macro = self.studioMacros[index];
        self.macroName.stringValue = macro[@"name"] ?: @"";
        self.macroCommands.string = [macro[@"commands"] componentsJoinedByString:@"\n"] ?: @"";
    } else { self.macroName.stringValue = @""; self.macroCommands.string = @"MD6;\nPC050;\nFL1;"; }
    [self refresh];
}

- (void)saveMacro:(id)sender {
    (void)sender;
    NSString *name = [self.macroName.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || name.length > 60) { [self alert:@"Name the macro" message:@"Use a name of 1–60 characters."]; return; }
    NSError *error = nil;
    NSArray *commands = TXValidatedCATMacro(self.macroCommands.string, &error);
    if (!commands) { [self alert:@"Macro needs a change" message:error.localizedDescription]; return; }
    NSInteger selected = self.macroPopup.indexOfSelectedItem - 1;
    for (NSUInteger i = 0; i < self.studioMacros.count; i++) {
        if ((NSInteger)i != selected && [self.studioMacros[i][@"name"] caseInsensitiveCompare:name] == NSOrderedSame) {
            [self alert:@"Name already in use" message:@"Choose a different name or select the existing macro to edit it."]; return;
        }
    }
    NSDictionary *macro = @{@"name": name, @"commands": commands};
    if (selected >= 0 && selected < (NSInteger)self.studioMacros.count) self.studioMacros[selected] = macro;
    else {
        if (self.studioMacros.count >= 40) { [self alert:@"Macro library is full" message:@"Delete an unused macro first."]; return; }
        [self.studioMacros addObject:macro];
        selected = self.studioMacros.count - 1;
    }
    [NSUserDefaults.standardUserDefaults setObject:self.studioMacros forKey:@"CATStudioMacrosV1"];
    [self reloadMacroMenu];
    [self.macroPopup selectItemAtIndex:selected + 1];
    [self showCATNotice:[NSString stringWithFormat:@"Macro “%@” saved (%lu steps).", name, (unsigned long)commands.count] error:NO];
    [self refresh];
}

- (void)deleteMacro:(id)sender {
    (void)sender;
    NSInteger index = self.macroPopup.indexOfSelectedItem - 1;
    if (index < 0 || index >= (NSInteger)self.studioMacros.count || self.busy) return;
    NSString *name = self.studioMacros[index][@"name"];
    if (![self confirm:@"Delete this macro?" message:name button:@"Delete Macro"]) return;
    [self.studioMacros removeObjectAtIndex:index];
    [NSUserDefaults.standardUserDefaults setObject:self.studioMacros forKey:@"CATStudioMacrosV1"];
    [self reloadMacroMenu]; [self refresh];
}

- (void)runMacro:(id)sender {
    (void)sender;
    NSInteger index = self.macroPopup.indexOfSelectedItem - 1;
    if (![self CATControlReady] || index < 0 || index >= (NSInteger)self.studioMacros.count) return;
    NSDictionary *macro = self.studioMacros[index];
    NSArray<NSString *> *commands = macro[@"commands"];
    NSString *name = macro[@"name"];
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    if (!port.length) return;
    [self begin];
    [self showCATNotice:[NSString stringWithFormat:@"Running %@ (0/%lu)…", name, (unsigned long)commands.count] error:NO];
    Lab599Cancellation *token = self.token;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        BOOL success = TXRunCATMacro(port, commands, token, ^(NSUInteger step, NSString *command, NSString *reply) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self appendTerminalTX:command];
                [self appendTerminalRX:reply latency:0 error:NO];
                NSString *message = [NSString stringWithFormat:@"%@ — step %lu/%lu verified", name,
                    (unsigned long)(step + 1), (unsigned long)commands.count];
                [self showCATNotice:message error:NO];
                if (self.statusChanged) self.statusChanged(message, (double)(step + 1) / commands.count);
            });
        }, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            if (success) {
                [self showCATNotice:[NSString stringWithFormat:@"Macro “%@” completed and verified.", name] error:NO];
                [self readRadioStateAction:nil];
            } else {
                NSString *message = token.cancelled ? @"Macro stopped. Earlier steps may have changed the radio." :
                    [NSString stringWithFormat:@"Macro stopped at an unverified step: %@", error.localizedDescription ?: @"Unknown error"];
                [self showCATNotice:message error:!token.cancelled];
                if (self.statusChanged) self.statusChanged(message, 0);
            }
        });
    });
}

- (void)reloadSnapshotMenu {
    [self.snapshotPopup removeAllItems];
    [self.snapshotPopup addItemWithTitle:@"Choose a snapshot…"];
    for (NSDictionary *snapshot in self.studioSnapshots) [self.snapshotPopup addItemWithTitle:snapshot[@"name"] ?: @"Untitled"];
    [self.snapshotPopup selectItemAtIndex:0];
}

- (void)snapshotSelected:(id)sender {
    (void)sender;
    NSInteger index = self.snapshotPopup.indexOfSelectedItem - 1;
    if (index >= 0 && index < (NSInteger)self.studioSnapshots.count) {
        NSDictionary *snapshot = self.studioSnapshots[index];
        NSData *settings = snapshot[@"settings"];
        self.snapshotDetails.stringValue = [NSString stringWithFormat:@"%@\nCaptured: %@   •   Model: %@\nSettings: %lu bytes   •   SHA-256: %@\nDial: %@ Hz   •   Mode: %@   •   RF: %@ W   •   Filter: FL%@",
            snapshot[@"name"], StudioTimestamp(snapshot[@"date"]), snapshot[@"model"],
            (unsigned long)settings.length, TXFirmwareSHA256(settings), snapshot[@"frequency"] ?: @"—",
            snapshot[@"mode"] ?: @"—", snapshot[@"power"] ?: @"—", snapshot[@"filter"] ?: @"—"];
    } else self.snapshotDetails.stringValue = @"Choose a saved snapshot or capture the connected radio. Each snapshot includes all 1024 settings bytes and available live dial readings.";
    [self refresh];
}

- (BOOL)saveSnapshotRecord:(NSDictionary *)record {
    NSMutableArray *updated = [self.studioSnapshots mutableCopy];
    if (updated.count >= 24) [updated removeObjectAtIndex:0];
    [updated addObject:record];
    [NSUserDefaults.standardUserDefaults setObject:updated forKey:@"CATStudioSnapshotsV1"];
    if (![NSUserDefaults.standardUserDefaults synchronize]) return NO;
    self.studioSnapshots = updated;
    [self reloadSnapshotMenu];
    [self.snapshotPopup selectItemAtIndex:self.studioSnapshots.count];
    [self snapshotSelected:nil];
    return YES;
}

- (NSDictionary *)snapshotRecordWithName:(NSString *)name model:(NSString *)model settings:(NSData *)settings state:(TXRadioState *)state {
    NSMutableDictionary *record = [@{@"name": name, @"date": [NSDate date], @"model": model,
        @"settings": settings, @"checksum": TXFirmwareSHA256(settings)} mutableCopy];
    if (state.frequencyHz) record[@"frequency"] = @(state.frequencyHz);
    if (state.modeCode >= 1 && state.modeCode <= 7) { record[@"modeCode"] = @(state.modeCode); record[@"mode"] = state.operatingMode ?: @"—"; }
    if (state.rfPowerWatts >= 1 && state.rfPowerWatts <= 10) record[@"power"] = @(state.rfPowerWatts);
    if (state.filterKnown) record[@"filter"] = @(state.filterNumber);
    if (state.preampKnown) record[@"preamp"] = @(state.preampOn);
    if (state.attenuatorKnown) record[@"attenuator"] = @(state.attenuatorOn);
    return record;
}

- (void)captureSnapshot:(id)sender {
    (void)sender;
    if (![self CATControlReady]) return;
    NSString *name = [self.snapshotName.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!name.length || name.length > 60) { [self alert:@"Name the snapshot" message:@"Use a name of 1–60 characters."]; return; }
    for (NSDictionary *saved in self.studioSnapshots) if ([saved[@"name"] caseInsensitiveCompare:name] == NSOrderedSame) {
        [self alert:@"Name already in use" message:@"Choose a distinct snapshot name."]; return;
    }
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    [self begin]; Lab599Cancellation *token = self.token;
    [self showCATNotice:@"Capturing all 1024 radio settings bytes…" error:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TXConfigurationResult *result = TXSettingsTransfer(port, nil, TXDefaultConfigurationOptions(), token,
            ^(NSString *phase, NSUInteger done, NSUInteger total) {
                if (done % 64 && done != total) return;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"%@: %lu/%lu", phase, (unsigned long)done, (unsigned long)total], (double)done/total);
                });
            });
        NSError *error = nil;
        NSString *model = result.success && !token.cancelled ? TXExecuteCATCommand(port, @"ID;", 0.6, NULL, &error) : nil;
        TXRadioState *state = model && TXClassifyCATReply([model dataUsingEncoding:NSASCIIStringEncoding]) == TXCATOK && !token.cancelled ?
            TXReadRadioState(port, 0.3, &error) : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            if (result.success && state && !token.cancelled) {
                BOOL saved = [self saveSnapshotRecord:[self snapshotRecordWithName:name model:model settings:result.settings state:state]];
                [self showCATNotice:saved ? [NSString stringWithFormat:@"Snapshot “%@” captured and saved.", name] :
                    @"Snapshot was captured but could not be saved to disk." error:!saved];
            } else {
                [self showCATNotice:token.cancelled ? @"Snapshot capture stopped." :
                    [NSString stringWithFormat:@"Snapshot was not saved: %@", error.localizedDescription ?: result.message] error:!token.cancelled];
            }
        });
    });
}

- (void)deleteSnapshot:(id)sender {
    (void)sender;
    NSInteger index = self.snapshotPopup.indexOfSelectedItem - 1;
    if (self.busy || index < 0 || index >= (NSInteger)self.studioSnapshots.count) return;
    if (![self confirm:@"Delete this snapshot?" message:self.studioSnapshots[index][@"name"] button:@"Delete Snapshot"]) return;
    [self.studioSnapshots removeObjectAtIndex:index];
    [NSUserDefaults.standardUserDefaults setObject:self.studioSnapshots forKey:@"CATStudioSnapshotsV1"];
    [self reloadSnapshotMenu]; [self snapshotSelected:nil];
}

- (void)restoreSnapshot:(id)sender {
    (void)sender;
    NSInteger index = self.snapshotPopup.indexOfSelectedItem - 1;
    if (![self CATControlReady] || index < 0 || index >= (NSInteger)self.studioSnapshots.count) return;
    NSDictionary *snapshot = self.studioSnapshots[index];
    NSData *settings = snapshot[@"settings"];
    NSString *problem = TXValidateSettings(settings);
    BOOL checksumValid = [snapshot[@"checksum"] isKindOfClass:NSString.class] &&
        [snapshot[@"checksum"] isEqualToString:TXFirmwareSHA256(settings)];
    if (problem || !checksumValid || TXClassifyCATReply([snapshot[@"model"] dataUsingEncoding:NSASCIIStringEncoding]) != TXCATOK) {
        [self alert:@"Snapshot is invalid" message:problem ?: (!checksumValid ? @"The saved settings checksum does not match the snapshot." : @"The saved radio model is not recognized.")]; return;
    }
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    NSString *message = [NSString stringWithFormat:@"Restore “%@” to %@?\n\nThis writes all 1024 settings bytes, then restores the saved live dial settings. The current settings will first be captured as a “Before restore” snapshot. Every write is read back. Keep the radio powered and connected.", snapshot[@"name"], port];
    if (![self confirm:@"Restore radio snapshot?" message:message button:@"Back Up & Restore"]) return;
    [self begin]; Lab599Cancellation *token = self.token;
    [self showCATNotice:@"Checking radio model and backing up current settings…" error:NO];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSString *model = TXExecuteCATCommand(port, @"ID;", 0.6, NULL, &error);
        TXConfigurationResult *backup = nil, *written = nil;
        __block BOOL backupSaved = NO;
        if (!token.cancelled && [model isEqualToString:snapshot[@"model"]]) {
            TXRadioState *currentState = TXReadRadioState(port, 0.3, nil);
            backup = TXSettingsTransfer(port, nil, TXDefaultConfigurationOptions(), token, nil);
            if (backup.success && !token.cancelled) {
                NSString *backupName = [NSString stringWithFormat:@"Before restore • %@", StudioTimestamp([NSDate date])];
                NSDictionary *record = [self snapshotRecordWithName:backupName model:model settings:backup.settings state:currentState];
                dispatch_sync(dispatch_get_main_queue(), ^{ backupSaved = [self saveSnapshotRecord:record]; });
                if (backupSaved && !token.cancelled) {
                    dispatch_async(dispatch_get_main_queue(), ^{ [self showCATNotice:@"Backup saved. Writing and verifying snapshot…" error:NO]; });
                    written = TXSettingsTransfer(port, settings, TXDefaultConfigurationOptions(), token,
                        ^(NSString *phase, NSUInteger done, NSUInteger total) {
                            if (done % 64 && done != total) return;
                            dispatch_async(dispatch_get_main_queue(), ^{
                                if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"%@: %lu/%lu", phase, (unsigned long)done, (unsigned long)total], (double)done/total);
                            });
                        });
                }
            }
        }
        BOOL liveOK = YES;
        if (written.success && !token.cancelled) {
            NSMutableArray<NSString *> *commands = [NSMutableArray array];
            if (snapshot[@"frequency"]) [commands addObject:[NSString stringWithFormat:@"FA%011llu;", [snapshot[@"frequency"] unsignedLongLongValue]]];
            if (snapshot[@"modeCode"]) [commands addObject:[NSString stringWithFormat:@"MD%ld;", (long)[snapshot[@"modeCode"] integerValue]]];
            if (snapshot[@"power"]) [commands addObject:[NSString stringWithFormat:@"PC%03d;", (int)round([snapshot[@"power"] doubleValue] * 10.0)]];
            if (snapshot[@"filter"]) [commands addObject:[NSString stringWithFormat:@"FL%ld;", (long)[snapshot[@"filter"] integerValue] - 1]];
            if (snapshot[@"preamp"]) [commands addObject:[NSString stringWithFormat:@"PA%d;", [snapshot[@"preamp"] boolValue] ? 1 : 0]];
            if (snapshot[@"attenuator"]) [commands addObject:[NSString stringWithFormat:@"RA0%d;", [snapshot[@"attenuator"] boolValue] ? 1 : 0]];
            if (commands.count) liveOK = TXRunCATMacro(port, commands, token, nil, &error);
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            NSString *status = nil;
            if (token.cancelled) status = @"Restore stopped. Radio settings may be partially changed; inspect the radio before retrying.";
            else if (![model isEqualToString:snapshot[@"model"]]) status = @"Restore blocked: the connected radio model does not match this snapshot.";
            else if (!backup.success) status = [NSString stringWithFormat:@"Restore blocked: current settings could not be backed up (%@).", backup.message ?: error.localizedDescription];
            else if (!backupSaved) status = @"Restore blocked: the pre-restore backup could not be saved to disk.";
            else if (!written.success) status = [NSString stringWithFormat:@"Restore incomplete: %@", written.message ?: @"Settings write failed."];
            else if (!liveOK) status = [NSString stringWithFormat:@"Settings verified, but live dial restore failed: %@", error.localizedDescription ?: @"Read-back mismatch"];
            else status = [NSString stringWithFormat:@"Snapshot “%@” restored and verified.", snapshot[@"name"]];
            [self showCATNotice:status error:!(written.success && liveOK) && !token.cancelled];
            if (self.statusChanged) self.statusChanged(status, written.success && liveOK ? 1 : 0);
            if (written.success && liveOK) [self readRadioStateAction:nil];
        });
    });
}

- (void)observeCATTraffic:(NSNotification *)notification {
    NSDictionary *event = notification.userInfo;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.monitorPaused) return;
        [self.monitorEntries addObject:event];
        if (self.monitorEntries.count > 600) [self.monitorEntries removeObjectsInRange:NSMakeRange(0, self.monitorEntries.count - 500)];
        NSString *frame = event[@"frame"] ?: @"";
        if ([event[@"direction"] isEqualToString:@"RX"] && [event[@"latencyMs"] doubleValue] >= 0) {
            BOOL ok = !([frame hasPrefix:@"?;"] || [frame hasPrefix:@"E;"] || [frame hasPrefix:@"O;"]);
            [self.monitorLatency addMilliseconds:[event[@"latencyMs"] doubleValue] passed:ok];
        }
        if (!self.monitorRedrawPending) {
            self.monitorRedrawPending = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.16 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                self.monitorRedrawPending = NO;
                [self redrawMonitor:nil];
            });
        }
    });
}

- (void)redrawMonitor:(id)sender {
    (void)sender;
    NSMutableAttributedString *rendered = [NSMutableAttributedString new];
    NSUInteger tx = 0, rx = 0, errors = 0;
    double totalLatency = 0; NSUInteger latencyCount = 0;
    NSInteger filter = self.monitorFilter.indexOfSelectedItem;
    for (NSDictionary *event in self.monitorEntries) {
        NSString *direction = event[@"direction"];
        NSString *frame = event[@"frame"] ?: @"";
        BOOL isError = [frame hasPrefix:@"?;"] || [frame hasPrefix:@"E;"] || [frame hasPrefix:@"O;"];
        if ([direction isEqualToString:@"TX"]) tx++; else rx++;
        if (isError) errors++;
        double ms = [event[@"latencyMs"] doubleValue];
        if ([direction isEqualToString:@"RX"] && ms >= 0) { totalLatency += ms; latencyCount++; }
        if ((filter == 1 && ![direction isEqualToString:@"TX"]) ||
            (filter == 2 && ![direction isEqualToString:@"RX"]) || (filter == 3 && !isError)) continue;
        NSString *line = [NSString stringWithFormat:@"%@  %@  %@%@\n", StudioTimestamp(event[@"timestamp"]), direction, frame,
            [direction isEqualToString:@"RX"] && ms >= 0 ? [NSString stringWithFormat:@"  (%.0f ms)", ms] : @""];
        NSColor *color = isError ? NSColor.systemRedColor :
            ([direction isEqualToString:@"TX"] ? [NSColor colorWithCalibratedRed:0.38 green:0.76 blue:1 alpha:1] : [NSColor colorWithCalibratedRed:0.45 green:0.9 blue:0.64 alpha:1]);
        [rendered appendAttributedString:[[NSAttributedString alloc] initWithString:line attributes:@{
            NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightMedium], NSForegroundColorAttributeName: color}]];
    }
    [self.monitorText.textStorage setAttributedString:rendered];
    [self.monitorText scrollToEndOfDocument:nil];
    self.monitorSummary.stringValue = [NSString stringWithFormat:@"%lu TX   ·   %lu RX   ·   %lu errors   ·   mean response %@   ·   %lu retained",
        (unsigned long)tx, (unsigned long)rx, (unsigned long)errors,
        latencyCount ? [NSString stringWithFormat:@"%.0f ms", totalLatency / latencyCount] : @"—",
        (unsigned long)self.monitorEntries.count];
}

- (void)toggleMonitor:(id)sender {
    (void)sender; self.monitorPaused = !self.monitorPaused;
    self.monitorPause.title = self.monitorPaused ? @"Resume" : @"Pause";
}
- (void)clearMonitor:(id)sender {
    (void)sender; [self.monitorEntries removeAllObjects]; [self.monitorLatency.samples removeAllObjects];
    self.monitorLatency.needsDisplay = YES; [self redrawMonitor:nil];
}
- (void)copyMonitor:(id)sender {
    (void)sender; [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.monitorText.string forType:NSPasteboardTypeString];
}

- (void)dealloc { [[NSNotificationCenter defaultCenter] removeObserver:self]; }

- (instancetype)init {
    if (!(self = [super init])) return nil;
    self.controls = [NSMutableArray array];
    self.catLogEntries = [NSMutableArray array];
    self.studioMacros = [[NSUserDefaults.standardUserDefaults arrayForKey:@"CATStudioMacrosV1"] mutableCopy] ?: [NSMutableArray array];
    self.studioSnapshots = [[NSUserDefaults.standardUserDefaults arrayForKey:@"CATStudioSnapshotsV1"] mutableCopy] ?: [NSMutableArray array];
    self.monitorEntries = [NSMutableArray array];
    self.channels = [TXEmptyMemory() mutableCopy];
    self.view = [NSView new];
    self.view.translatesAutoresizingMaskIntoConstraints = NO;

    // CAT Studio & Diagnostics Panel
    NSView *cat = [self buildCATStudioView];

    // Settings Panel
    self.settingsInfo = Label(@"No settings backup loaded. Read the radio or open an existing .set file.");
    self.settingsRead = [self button:@"Read Radio" action:@selector(readRadio:) tag:1];
    self.settingsWrite = [self button:@"Restore to Radio…" action:@selector(writeRadio:) tag:1];
    self.settingsSave = [self button:@"Save .set…" action:@selector(saveBackup:) tag:1];
    self.settingsCompare = [self button:@"Compare .set…" action:@selector(compareSettingsAction:) tag:1];
    self.settingsExportJson = [self button:@"Export JSON…" action:@selector(exportJsonSettingsAction:) tag:1];
    self.settingsImportJson = [self button:@"Import JSON…" action:@selector(importJsonSettingsAction:) tag:1];

    NSView *settingsRow1 = Stack(@[
        self.settingsRead,
        [self button:@"Open .set…" action:@selector(loadBackup:) tag:1],
        self.settingsSave,
        self.settingsCompare,
        self.settingsWrite
    ], NO);

    self.settingsCategoryFilter = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.settingsCategoryFilter addItemsWithTitles:@[
        @"All Categories",
        @"VFO & Bands",
        @"DSP Filters",
        @"Equalizer & Audio",
        @"CW & Keyer",
        @"Transmitter & VOX",
        @"Receiver & DSP",
        @"Panadapter & Display"
    ]];
    self.settingsCategoryFilter.target = self;
    self.settingsCategoryFilter.action = @selector(settingsCategoryChanged:);
    [self.controls addObject:self.settingsCategoryFilter];

    NSView *settingsRow2 = Stack(@[
        Label(@"Category:"),
        self.settingsCategoryFilter,
        Label(@"|"),
        self.settingsExportJson,
        self.settingsImportJson
    ], NO);

    self.settingsTable = [NSTableView new];
    self.settingsTable.delegate = self;
    self.settingsTable.dataSource = self;
    self.settingsTable.rowHeight = 22;
    self.settingsTable.usesAlternatingRowBackgroundColors = YES;

    NSArray *settingCols = @[
        @{@"id": @"category", @"title": @"Category", @"width": @120},
        @{@"id": @"name", @"title": @"Parameter / Setting", @"width": @180},
        @{@"id": @"offset", @"title": @"Addr", @"width": @60},
        @{@"id": @"value", @"title": @"Value", @"width": @60},
        @{@"id": @"range", @"title": @"Range / Unit", @"width": @120},
        @{@"id": @"desc", @"title": @"Details", @"width": @260}
    ];
    for (NSDictionary *col in settingCols) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:col[@"id"]];
        c.title = col[@"title"];
        c.width = [col[@"width"] doubleValue];
        c.editable = NO;
        [self.settingsTable addTableColumn:c];
    }

    NSScrollView *settingsScroll = [NSScrollView new];
    settingsScroll.hasVerticalScroller = YES;
    settingsScroll.borderType = NSBezelBorder;
    settingsScroll.documentView = self.settingsTable;
    [settingsScroll.heightAnchor constraintEqualToConstant:230].active = YES;

    self.settingEditLabel = Label(@"Select a setting:");
    self.settingEditLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    self.settingEditField = [NSTextField new];
    self.settingEditField.placeholderString = @"New value";
    [self.settingEditField.widthAnchor constraintEqualToConstant:160].active = YES;
    self.settingEditField.target = self;
    self.settingEditField.action = @selector(editSettingAction:);
    self.settingApplyButton = [self button:@"Apply Change" action:@selector(editSettingAction:) tag:0];
    [self.controls addObjectsFromArray:@[self.settingEditField, self.settingApplyButton]];

    NSView *settingsEditorRow = Stack(@[
        self.settingEditLabel,
        self.settingEditField,
        self.settingApplyButton
    ], NO);

    NSView *settings = Stack(@[
        settingsRow1,
        settingsRow2,
        settingsScroll,
        settingsEditorRow,
        self.settingsInfo
    ], YES);

    [settingsScroll.widthAnchor constraintEqualToAnchor:settings.widthAnchor].active = YES;

    // Memory Panel
    self.memoryInfo = Label(@"Open a .mem file, read the radio, or create a new bank of 100 channels.");
    self.memoryRead = [self button:@"Read Radio" action:@selector(readRadio:) tag:2];
    self.memoryWrite = [self button:@"Write 100 Channels…" action:@selector(writeRadio:) tag:2];
    self.memorySave = [self button:@"Save .mem…" action:@selector(saveBackup:) tag:2];
    self.memoryCompare = [self button:@"Compare .mem…" action:@selector(compareMemoryAction:) tag:2];
    self.csvImport = [self button:@"Import CSV…" action:@selector(importCSVAction:) tag:2];
    self.csvExport = [self button:@"Export CSV…" action:@selector(exportCSVAction:) tag:2];

    self.profilesPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self populateProfilesMenu];
    self.profilesPopup.target = self;
    self.profilesPopup.action = @selector(profileSelected:);
    [self.controls addObject:self.profilesPopup];

    NSView *memoryRow1 = Stack(@[
        self.memoryRead,
        [self button:@"Open .mem…" action:@selector(loadBackup:) tag:2],
        self.memorySave,
        self.memoryCompare,
        [self button:@"New Bank" action:@selector(newBank:) tag:2],
        self.memoryWrite
    ], NO);

    NSView *memoryRow2 = Stack(@[
        Label(@"Operating Profiles:"),
        self.profilesPopup,
        Label(@"|"),
        self.csvImport,
        self.csvExport
    ], NO);

    self.table = [NSTableView new];
    self.table.delegate = self;
    self.table.dataSource = self;
    self.table.rowHeight = 22;
    self.table.usesAlternatingRowBackgroundColors = YES;

    NSArray *titles = @[@"Channel", @"Frequency (Hz)", @"Mode", @"PreAtt"];
    NSArray *identifiers = @[@"channel", @"frequency", @"mode", @"preAtt"];
    for (NSUInteger i = 0; i < titles.count; i++) {
        NSTableColumn *c = [[NSTableColumn alloc] initWithIdentifier:identifiers[i]];
        c.title = titles[i];
        c.width = (i == 1 ? 240 : 140);
        c.editable = NO;
        [self.table addTableColumn:c];
    }

    NSScrollView *scroll = [NSScrollView new];
    scroll.hasVerticalScroller = YES;
    scroll.borderType = NSBezelBorder;
    scroll.documentView = self.table;
    [scroll.heightAnchor constraintEqualToConstant:340].active = YES;

    self.frequency = [NSTextField new];
    self.frequency.placeholderString = @"100000–56000000";
    [self.frequency.widthAnchor constraintEqualToConstant:155].active = YES;
    self.mode = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.mode addItemsWithTitles:@[@"LSB", @"USB", @"CW", @"FM", @"AM", @"CWR", @"DIG (USB)"]];
    self.preAtt = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [self.preAtt addItemsWithTitles:@[@"Off", @"PRE", @"ATT"]];
    [self.controls addObjectsFromArray:@[self.frequency, self.mode, self.preAtt]];

    NSView *editor = Stack(@[
        Label(@"Hz:"), self.frequency, self.mode, self.preAtt,
        [self button:@"Apply to Row" action:@selector(editChannel:) tag:0],
        [self button:@"Clear Row" action:@selector(editChannel:) tag:1]
    ], NO);

    NSView *memory = Stack(@[
        memoryRow1,
        memoryRow2,
        scroll,
        editor,
        self.memoryInfo,
        Label(@"Edits stay in this bank until Write is clicked. DIG uses the USB code, as in the original utility.")
    ], YES);

    [scroll.widthAnchor constraintEqualToAnchor:memory.widthAnchor].active = YES;

    self.panels = @[cat, settings, memory];
    for (NSView *panel in self.panels) {
        panel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.view addSubview:panel];
        [NSLayoutConstraint activateConstraints:@[
            [panel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
            [panel.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
            [panel.topAnchor constraintEqualToAnchor:self.view.topAnchor]
        ]];
        if (panel != cat) {
            for (NSView *child in ((NSStackView *)panel).arrangedSubviews) {
                if ([child isKindOfClass:NSTextField.class]) {
                    [child.widthAnchor constraintEqualToAnchor:panel.widthAnchor].active = YES;
                }
            }
        }
    }

    self.stop = [NSButton buttonWithTitle:@"Stop" target:self action:@selector(stopOperation:)];
    self.stop.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.stop];
    [NSLayoutConstraint activateConstraints:@[
        [self.view.heightAnchor constraintGreaterThanOrEqualToConstant:520],
        [self.stop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.stop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];

    self.toolHeight = [self.view.heightAnchor constraintEqualToConstant:960];
    self.toolHeight.priority = 750;
    self.toolHeight.active = YES;
    self.catBottomConstraint = [cat.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.bottomAnchor constant:-8];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(observeCATTraffic:)
        name:Lab599CATTrafficNotification object:nil];

    [self selectTool:0];
    return self;
}

- (void)selectTool:(NSInteger)tool {
    if (self.busy) return;
    self.tool = tool;
    self.toolHeight.constant = tool == 0 ? 960 : 520;
    self.catBottomConstraint.active = tool == 0;
    for (NSUInteger i = 0; i < self.panels.count; i++) {
        self.panels[i].hidden = ((NSInteger)i != tool);
    }
    [self refresh];
}

- (void)portsAvailable:(BOOL)available {
    self.hasPorts = available;
    NSString *port = available && self.selectedPort ? self.selectedPort() : nil;
    if (self.verifiedCATPort.length && ![self.verifiedCATPort isEqualToString:port]) {
        [self updateRadioStateUI:[TXRadioState new]];
        self.verifiedCATPort = nil;
        if (available) [self showCATNotice:@"CAT port available — use Read All to confirm radio communication." error:NO];
    }
    [self refresh];
}

- (void)refresh {
    for (NSControl *c in self.controls) c.enabled = !self.busy;
    self.table.enabled = !self.busy;
    BOOL canStop = self.busy && !self.token.cancelled;
    self.stop.enabled = canStop;
    self.stop.hidden = !self.busy || self.tool == 0;
    self.catStop.enabled = canStop;
    self.catStop.hidden = !self.busy || self.tool != 0;
    self.macroStop.enabled = canStop;
    self.snapshotStop.enabled = canStop;
    self.macroStop.hidden = self.snapshotStop.hidden = !self.busy || self.tool != 0;

    // CAT Controls
    BOOL canCAT = !self.busy && self.hasPorts;
    BOOL canControl = canCAT && self.verifiedCATPort.length &&
        [self.verifiedCATPort isEqualToString:(self.selectedPort ? self.selectedPort() : nil)];
    self.catOnce.enabled = self.catStart.enabled = canCAT;
    self.catReadAllButton.enabled = canCAT;
    self.catFreqInputField.enabled = canControl;
    self.catSetFreqButton.enabled = canControl;
    self.catStepPopup.enabled = canControl;
    self.catStepDownButton.enabled = canControl;
    self.catStepUpButton.enabled = canControl;
    self.catModePopup.enabled = canControl;
    self.catSetModeButton.enabled = canControl;
    self.catPowerPopup.enabled = canControl;
    self.catSetPowerButton.enabled = canControl;
    self.catCommandInput.enabled = canControl;
    self.catSendCommandButton.enabled = canControl;
    self.catPreampToggle.enabled = canControl;
    self.catAttenuatorToggle.enabled = canControl;
    self.catFilterSegment.enabled = canControl;
    for (NSButton *b in self.bandButtons) b.enabled = canControl;
    for (NSButton *b in self.quickCmdButtons) b.enabled = canCAT;
    self.macroSave.enabled = !self.busy;
    self.macroDelete.enabled = !self.busy && self.macroPopup.indexOfSelectedItem > 0;
    self.macroRun.enabled = canControl && self.macroPopup.indexOfSelectedItem > 0;
    for (NSView *view in self.macroButtonCanvas.subviews) if ([view isKindOfClass:NSButton.class]) ((NSButton *)view).enabled = canControl;
    self.snapshotCapture.enabled = canControl;
    self.snapshotRestore.enabled = canControl && self.snapshotPopup.indexOfSelectedItem > 0;
    self.snapshotDelete.enabled = !self.busy && self.snapshotPopup.indexOfSelectedItem > 0;
    if (!self.hasPorts) {
        self.catNotice.stringValue = @"Disconnected — connect the CAT adapter, then refresh the serial ports.";
        self.catNotice.textColor = NSColor.systemOrangeColor;
        self.catNoticeBox.fillColor = [NSColor.systemOrangeColor colorWithAlphaComponent:0.12];
    } else if ([self.catNotice.stringValue hasPrefix:@"Disconnected"]) {
        self.catNotice.stringValue = @"CAT port available — use Read All to confirm radio communication.";
        self.catNotice.textColor = NSColor.secondaryLabelColor;
        self.catNoticeBox.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.08];
    }

    // Settings & Memory
    self.settingsRead.enabled = self.memoryRead.enabled = canCAT;
    self.settingsSave.enabled = !self.busy && self.settingsData != nil;
    self.settingsCompare.enabled = !self.busy;
    self.settingsWrite.enabled = self.settingsSave.enabled && self.hasPorts;
    self.memorySave.enabled = !self.busy && self.memoryReady;
    self.memoryCompare.enabled = !self.busy;
    self.csvExport.enabled = !self.busy && self.memoryReady;
    self.csvImport.enabled = !self.busy;
    self.profilesPopup.enabled = !self.busy;
    self.memoryWrite.enabled = self.memorySave.enabled && self.hasPorts;
}

- (void)alert:(NSString *)title message:(NSString *)message {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    a.informativeText = message ?: @"Unknown error";
    [a addButtonWithTitle:@"OK"];
    [a beginSheetModalForWindow:self.window completionHandler:nil];
}

- (BOOL)confirm:(NSString *)title message:(NSString *)message button:(NSString *)button {
    NSAlert *a = [NSAlert new];
    a.messageText = title;
    a.informativeText = message;
    [a addButtonWithTitle:button];
    [a addButtonWithTitle:@"Cancel"];
    return [a runModal] == NSAlertFirstButtonReturn;
}

- (BOOL)confirmReplacement:(NSInteger)kind {
    BOOL dirty = (kind == 1 ? self.settingsDirty : self.memoryDirty);
    return !dirty || [self confirm:@"Replace the unsaved bank?"
                           message:@"Save your current backup first if you want to keep it. This replaces only the data open in the app."
                            button:@"Replace"];
}

- (BOOL)confirmDiscard {
    return (!self.settingsDirty && !self.memoryDirty) || [self confirm:@"Close with unsaved backups?"
        message:@"Settings or memory changes have not been saved to a file."
         button:@"Close Without Saving"];
}

- (void)begin {
    self.busy = YES;
    self.token = [Lab599Cancellation new];
    [self refresh];
    if (self.activityChanged) self.activityChanged(YES);
}

- (void)end {
    self.busy = NO;
    self.token = nil;
    self.catStop.title = @"Stop";
    [self refresh];
    if (self.activityChanged) self.activityChanged(NO);
}

- (BOOL)operationInProgress { return self.busy; }

- (void)cancelActiveOperation {
    if (!self.busy || self.token.cancelled) return;
    self.token.cancelled = YES;
    self.stop.enabled = NO;
    self.catStop.enabled = NO;
    self.catStop.title = @"Stopping…";
    if (self.statusChanged) self.statusChanged(@"Stopping and closing the serial port…", 0);
}

- (void)stopOperation:(id)sender {
    (void)sender;
    [self cancelActiveOperation];
}

#pragma mark - CAT Studio & Test

- (BOOL)CATControlReady {
    return !self.busy && self.hasPorts && self.verifiedCATPort.length &&
        [self.verifiedCATPort isEqualToString:(self.selectedPort ? self.selectedPort() : nil)];
}

- (void)CATCommandFailed:(NSError *)error {
    self.verifiedCATPort = nil;
    [self updateRadioStateUI:[TXRadioState new]];
    [self refresh];
    [self showCATNotice:error.localizedDescription ?: @"CAT communication failed; read the radio before using controls." error:YES];
}

- (void)showCATNotice:(NSString *)message error:(BOOL)isError {
    self.catNotice.stringValue = message;
    self.catNotice.textColor = isError ? NSColor.systemRedColor : NSColor.secondaryLabelColor;
    self.catNoticeBox.fillColor = isError ? [NSColor.systemRedColor colorWithAlphaComponent:0.12] :
        [NSColor colorWithCalibratedWhite:0.5 alpha:0.08];
}

- (void)catLogFilterChanged:(id)sender {
    (void)sender;
    [self.catTerminalTextView.textStorage setAttributedString:[NSAttributedString new]];
    NSInteger filter = self.catLogFilter.indexOfSelectedItem;
    for (NSDictionary *entry in self.catLogEntries) {
        if (filter == 1 && ![entry[@"kind"] isEqualToString:@"TX"]) continue;
        if (filter == 2 && ![entry[@"kind"] isEqualToString:@"RX"]) continue;
        [self.catTerminalTextView.textStorage appendAttributedString:entry[@"line"]];
    }
    [self.catTerminalTextView scrollToEndOfDocument:nil];
}

- (void)appendCATLogLine:(NSAttributedString *)line kind:(NSString *)kind {
    [self.catLogEntries addObject:@{@"kind": kind, @"line": line}];
    if (self.catLogEntries.count > 1000) {
        [self.catLogEntries removeObjectsInRange:NSMakeRange(0, 250)];
        [self catLogFilterChanged:nil];
        return;
    }
    NSInteger filter = self.catLogFilter.indexOfSelectedItem;
    if (filter == 0 || (filter == 1 && [kind isEqualToString:@"TX"]) ||
        (filter == 2 && [kind isEqualToString:@"RX"])) {
        [self.catTerminalTextView.textStorage appendAttributedString:line];
        [self.catTerminalTextView scrollToEndOfDocument:nil];
    }
}

- (void)appendTerminalTX:(NSString *)cmd {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.catTerminalTextView) return;
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *ts = [df stringFromDate:[NSDate date]];
        NSString *line = [NSString stringWithFormat:@"[%@] TX >> %@\n", ts, cmd];
        
        NSDictionary *attrs = @{
            NSForegroundColorAttributeName: [NSColor colorWithCalibratedRed:0.3 green:0.8 blue:1.0 alpha:1.0],
            NSFontAttributeName: [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]
        };
        NSAttributedString *astr = [[NSAttributedString alloc] initWithString:line attributes:attrs];
        [self appendCATLogLine:astr kind:@"TX"];
    });
}

- (void)appendTerminalRX:(NSString *)reply latency:(double)latency error:(BOOL)isErr {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.catTerminalTextView) return;
        NSDateFormatter *df = [NSDateFormatter new];
        df.dateFormat = @"HH:mm:ss.SSS";
        NSString *ts = [df stringFromDate:[NSDate date]];
        NSString *line = [NSString stringWithFormat:@"[%@] RX << %@ (%.0f ms)\n", ts, reply ?: @"(none)", latency];
        
        NSColor *color = isErr ? [NSColor colorWithCalibratedRed:1.0 green:0.4 blue:0.4 alpha:1.0] :
                                 [NSColor colorWithCalibratedRed:0.35 green:0.95 blue:0.45 alpha:1.0];
        NSDictionary *attrs = @{
            NSForegroundColorAttributeName: color,
            NSFontAttributeName: [NSFont fontWithName:@"Menlo" size:11] ?: [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular]
        };
        NSAttributedString *astr = [[NSAttributedString alloc] initWithString:line attributes:attrs];
        [self appendCATLogLine:astr kind:@"RX"];
    });
}

- (void)clearTerminalAction:(id)sender {
    (void)sender;
    [self.catLogEntries removeAllObjects];
    [self.catTerminalTextView.textStorage setAttributedString:[NSAttributedString new]];
}

- (void)copyTerminalLogAction:(id)sender {
    (void)sender;
    NSString *text = self.catTerminalTextView.string ?: @"";
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
    if (self.statusChanged) self.statusChanged(@"CAT Terminal log copied to clipboard.", 0);
}

- (void)updateRadioStateUI:(TXRadioState *)state {
    self.catModelLabel.stringValue = state.modelID.length ? [NSString stringWithFormat:@"Transceiver Model: %@", state.modelID] : @"Transceiver Model: —";
    if (state.frequencyDisplay.length) {
        self.catFreqDisplay.stringValue = state.frequencyDisplay;
        self.catFreqInputField.stringValue = ToolsFormatInputFrequency(state.frequencyHz);
    } else {
        self.catFreqDisplay.stringValue = @"— . — . — MHz";
        self.catFreqInputField.stringValue = @"";
    }
    [self updateActiveBandForFrequency:state.frequencyHz];
    self.catModeBadge.stringValue = [NSString stringWithFormat:@"MODE: %@", state.operatingMode ?: @"—"];
    if (state.rfPowerWatts <= 0.0) {
        self.catPowerBadge.stringValue = @"PWR: —";
    } else if (fmod(state.rfPowerWatts, 1.0) == 0.0) {
        self.catPowerBadge.stringValue = [NSString stringWithFormat:@"PWR: %.0f W", state.rfPowerWatts];
    } else {
        self.catPowerBadge.stringValue = [NSString stringWithFormat:@"PWR: %.1f W", state.rfPowerWatts];
    }
    self.catFilterBadge.stringValue = state.filterKnown ? [NSString stringWithFormat:@"FIL: FL%ld", (long)state.filterNumber] : @"FIL: —";
    self.catPreampBadge.stringValue = state.preampKnown ? [NSString stringWithFormat:@"PRE: %@", state.preampOn ? @"ON" : @"OFF"] : @"PRE: —";
    self.catVoltageBadge.stringValue = state.voltageKnown ? [NSString stringWithFormat:@"VOLT: %.1f V", state.voltage] : @"VOLT: —";
    self.catIsTransmitting = state.isTransmitting;
    self.catSMeterKnown = state.sMeterKnown;
    self.catSMeterDots = state.sMeterDots;
    [self refreshSMeterPresentation];
    self.catVoltageGauge.doubleValue = MAX(0.0, MIN(20.0, state.voltage));
    self.catPowerGauge.doubleValue = MAX(0.0, MIN(10.0, state.rfPowerWatts));

    // Sync input controls with read values
    if (state.operatingMode.length) {
        [self.catModePopup selectItemWithTitle:state.operatingMode];
    }
    if (state.rfPowerWatts > 0) {
        NSString *pTitle = [NSString stringWithFormat:@"%ld W", (long)round(state.rfPowerWatts)];
        NSInteger idx = [self.catPowerPopup indexOfItemWithTitle:pTitle];
        if (idx >= 0) [self.catPowerPopup selectItemAtIndex:idx];
    }
    self.catFilterSegment.selectedSegment = state.filterKnown ? state.filterNumber - 1 : -1;
    self.catPreampToggle.state = state.preampKnown ? (state.preampOn ? NSControlStateValueOn : NSControlStateValueOff) : NSControlStateValueMixed;
    self.catAttenuatorToggle.state = state.attenuatorKnown ? (state.attenuatorOn ? NSControlStateValueOn : NSControlStateValueOff) : NSControlStateValueMixed;
}

- (void)updateActiveBandForFrequency:(uint64_t)frequencyHz {
    NSInteger activeIndex = ToolsBandIndexForFrequency(frequencyHz);
    for (NSUInteger i = 0; i < self.bandButtons.count; i++) {
        NSButton *button = self.bandButtons[i];
        BOOL active = ((NSInteger)i == activeIndex);
        button.state = active ? NSControlStateValueOn : NSControlStateValueOff;
        button.bordered = !active;
        button.layer.backgroundColor = active ? NSColor.controlAccentColor.CGColor : NSColor.clearColor.CGColor;
        button.contentTintColor = active ? NSColor.whiteColor : nil;
        button.toolTip = active ? @"Current radio band" : @"Tune the radio to this band preset";
    }
}

- (void)refreshSMeterPresentation {
    self.catSMeterTitle.stringValue = self.catIsTransmitting ? @"TX meter" : @"S-Meter";
    self.catSMeterScaleRow.hidden = self.catIsTransmitting;
    self.catSMeterBadge.stringValue = self.catSMeterKnown ?
        ToolsSMeterReading(self.catSMeterDots, self.catIsTransmitting) :
        (self.catIsTransmitting ? @"TX meter: —" : @"S-MTR: —");
    self.catSMeterGauge.doubleValue = self.catSMeterKnown ? MAX(0, MIN(30, self.catSMeterDots)) : 0;
}

- (void)updateStateFromCommand:(NSString *)cmd reply:(NSString *)reply {
    if ([cmd isEqualToString:@"IF;"] && [reply hasPrefix:@"IF"]) {
        NSString *clean = [reply stringByReplacingOccurrencesOfString:@";" withString:@""];
        if (clean.length >= 13) {
            uint64_t frequencyHz = (uint64_t)[[clean substringWithRange:NSMakeRange(2, 11)] longLongValue];
            if (frequencyHz > 0) {
                self.catFreqDisplay.stringValue = ToolsFormatFreq(frequencyHz);
                self.catFreqInputField.stringValue = ToolsFormatInputFrequency(frequencyHz);
                [self updateActiveBandForFrequency:frequencyHz];
            }
        }
        if (clean.length > 28) {
            BOOL transmitting = ([clean characterAtIndex:28] == '1');
            if (self.catIsTransmitting != transmitting) self.catSMeterKnown = NO;
            self.catIsTransmitting = transmitting;
            [self refreshSMeterPresentation];
        }
    } else if ([cmd hasPrefix:@"FA"] && reply && [reply hasPrefix:@"FA"] && reply.length >= 13) {
        NSString *digits = [reply substringWithRange:NSMakeRange(2, 11)];
        uint64_t f = (uint64_t)[digits longLongValue];
        if (f > 0) {
            self.catFreqDisplay.stringValue = ToolsFormatFreq(f);
            self.catFreqInputField.stringValue = ToolsFormatInputFrequency(f);
            [self updateActiveBandForFrequency:f];
        }
    } else if ([cmd hasPrefix:@"MD"] && reply && [reply hasPrefix:@"MD"] && reply.length >= 3) {
        int m = [[reply substringWithRange:NSMakeRange(2, 1)] intValue];
        NSString *mName = ToolsModeNameFromCode(m);
        self.catModeBadge.stringValue = [NSString stringWithFormat:@"MODE: %@", mName];
        [self.catModePopup selectItemWithTitle:mName];
    } else if ([cmd hasPrefix:@"PC"] && reply && [reply hasPrefix:@"PC"] && reply.length >= 5) {
        int p = [[reply substringWithRange:NSMakeRange(2, 3)] intValue];
        double watts = (p > 10) ? (p / 10.0) : (double)p;
        if (fmod(watts, 1.0) == 0.0) {
            self.catPowerBadge.stringValue = [NSString stringWithFormat:@"PWR: %.0f W", watts];
        } else {
            self.catPowerBadge.stringValue = [NSString stringWithFormat:@"PWR: %.1f W", watts];
        }
        NSString *pTitle = [NSString stringWithFormat:@"%ld W", (long)round(watts)];
        NSInteger idx = [self.catPowerPopup indexOfItemWithTitle:pTitle];
        if (idx >= 0) [self.catPowerPopup selectItemAtIndex:idx];
        self.catPowerGauge.doubleValue = MAX(0.0, MIN(10.0, watts));
    } else if ([cmd hasPrefix:@"FL"] && reply && [reply hasPrefix:@"FL"] && reply.length >= 3) {
        unichar c = [reply characterAtIndex:2];
        int fl = reply.length == 5 && c >= '0' && c <= '3' ? (int)(c - '0') + 1 :
            (c >= '1' && c <= '4' ? (int)(c - '0') : 0);
        if (fl >= 1 && fl <= 4) {
            self.catFilterBadge.stringValue = [NSString stringWithFormat:@"FIL: FL%d", fl];
            self.catFilterSegment.selectedSegment = fl - 1;
        }
    } else if ([cmd hasPrefix:@"PA"] && reply && [reply hasPrefix:@"PA"] && reply.length >= 3) {
        BOOL on = ([reply characterAtIndex:2] == '1');
        self.catPreampBadge.stringValue = [NSString stringWithFormat:@"PRE: %@", on ? @"ON" : @"OFF"];
        self.catPreampToggle.state = on ? NSControlStateValueOn : NSControlStateValueOff;
    } else if ([cmd hasPrefix:@"RA"] && reply && [reply hasPrefix:@"RA"] && reply.length >= 3) {
        int r = [[reply substringFromIndex:2] intValue];
        self.catAttenuatorToggle.state = (r > 0) ? NSControlStateValueOn : NSControlStateValueOff;
    } else if ([cmd hasPrefix:@"VL"] && reply) {
        NSString *clean = [[reply componentsSeparatedByCharactersInSet:
                            [NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsJoinedByString:@""];
        NSRange prefix = [clean rangeOfString:@"VL"];
        if (prefix.location != NSNotFound) {
            NSString *field = [clean substringFromIndex:NSMaxRange(prefix)];
            field = [field stringByReplacingOccurrencesOfString:@";" withString:@""];
            double v = field.doubleValue;
            if (v > 20.0) v = v / 10.0;
            if (v >= 7.0 && v <= 20.0) {
                self.catVoltageBadge.stringValue = [NSString stringWithFormat:@"VOLT: %.1f V", v];
                self.catVoltageGauge.doubleValue = v;
            }
        }
    } else if ([cmd hasPrefix:@"SM0"] && reply && [reply hasPrefix:@"SM"] && reply.length >= 4) {
        NSInteger dots = [[reply substringFromIndex:2] integerValue];
        self.catSMeterKnown = YES;
        self.catSMeterDots = dots;
        [self refreshSMeterPresentation];
    } else if ([cmd hasPrefix:@"ID"] && reply) {
        if ([reply containsString:@"ID019"]) self.catModelLabel.stringValue = @"Transceiver Model: Lab599 TX-500 Discovery (ID019)";
        else if ([reply containsString:@"ID500"]) self.catModelLabel.stringValue = @"Transceiver Model: Lab599 TX-500 Discovery (ID500)";
        else if ([reply containsString:@"ID501"]) self.catModelLabel.stringValue = @"Transceiver Model: Lab599 TX-500MP (ID501)";
        else if ([reply containsString:@"ID502"]) self.catModelLabel.stringValue = @"Transceiver Model: Lab599 TX-500PRO (ID502)";
        else if ([reply containsString:@"ID505"]) self.catModelLabel.stringValue = @"Transceiver Model: Lab599 TX-500PRO ALTAI (ID505)";
    }
}

- (void)readRadioStateAction:(id)sender {
    (void)sender;
    if (self.busy || !self.hasPorts) return;
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    if (!port) return;

    [self begin];
    [self appendTerminalTX:@"READ ALL (ID; IF; FA; MD; PC; FL; PA; RA; VL; SM0;)"];
    if (self.statusChanged) self.statusChanged(@"Reading comprehensive transceiver state over CAT...", 0);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        double started = Lab599MonotonicTime();
        TXRadioState *state = TXReadRadioState(port, 0.35, &err);
        double elapsed = (Lab599MonotonicTime() - started) * 1000.0;

        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            if (state) {
                [self appendTerminalRX:[NSString stringWithFormat:@"%@ | Freq: %@ | Mode: %@ | Pwr: %@ | Volt: %@",
                                        state.modelID ?: @"Unknown radio", state.frequencyDisplay ?: @"—",
                                        state.operatingMode ?: @"—",
                                        state.rfPowerWatts > 0 ? [NSString stringWithFormat:@"%.1f W", state.rfPowerWatts] : @"—",
                                        state.voltageKnown ? [NSString stringWithFormat:@"%.1f V", state.voltage] : @"—"]
                                latency:elapsed error:NO];
                [self updateRadioStateUI:state];
                if ([state.modelID hasPrefix:@"Lab599 "]) {
                    self.verifiedCATPort = port;
                    [self showCATNotice:@"Radio identified; CAT controls are ready." error:NO];
                } else {
                    self.verifiedCATPort = nil;
                    [self showCATNotice:@"CAT replied, but the radio identity was not verified. Controls remain disabled." error:YES];
                }
                [self refresh];
                if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"CAT read finished in %.0f ms; %@.", elapsed,
                    self.verifiedCATPort.length ? @"radio identified" : @"identity not verified"],
                    self.verifiedCATPort.length ? 1 : 0);
            } else {
                self.verifiedCATPort = nil;
                [self updateRadioStateUI:[TXRadioState new]];
                [self refresh];
                [self appendTerminalRX:err.localizedDescription ?: @"Timeout" latency:elapsed error:YES];
                [self showCATNotice:err.localizedDescription ?: @"Radio did not respond." error:YES];
                if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"Failed to read radio: %@", err.localizedDescription ?: @"Port error"], 0);
            }
        });
    });
}

- (void)sendCommandAction:(id)sender {
    (void)sender;
    if (self.busy || !self.hasPorts) return;
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    if (!port) return;

    NSString *cmd = [self.catCommandInput.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!cmd.length) return;
    if (![cmd hasSuffix:@";"]) cmd = [cmd stringByAppendingString:@";"];

    [self begin];
    [self appendTerminalTX:cmd];
    if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"Sending CAT: %@", cmd], 0);

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        double rtt = 0;
        NSString *reply = TXExecuteCATCommand(port, cmd, 0.4, &rtt, &err);

        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            if (reply) {
                [self appendTerminalRX:reply latency:rtt error:NO];
                if ([cmd isEqualToString:@"ID;"] &&
                    TXClassifyCATReply([reply dataUsingEncoding:NSASCIIStringEncoding]) == TXCATOK) {
                    self.verifiedCATPort = port;
                    [self showCATNotice:@"Radio identified; CAT controls are ready." error:NO];
                    [self refresh];
                } else {
                    [self showCATNotice:@"CAT reply received." error:NO];
                }
                if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"Reply: %@ (%.0f ms)", reply, rtt], 1);
                [self updateStateFromCommand:cmd reply:reply];
            } else if (err && err.code == Lab599SerialTimeout && ToolsIsCATSetCommand(cmd)) {
                [self appendTerminalRX:@"OK (Command Sent)" latency:rtt error:NO];
                [self showCATNotice:@"Command sent; the radio did not return a reply." error:NO];
                if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"Command sent successfully: %@", cmd], 1);
            } else {
                self.verifiedCATPort = nil;
                [self refresh];
                [self appendTerminalRX:err ? err.localizedDescription : @"No reply / Timeout" latency:rtt error:YES];
                [self showCATNotice:err.localizedDescription ?: @"No CAT reply." error:YES];
                if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"Error sending %@: %@", cmd, err.localizedDescription ?: @"Timeout"], 0);
            }
        });
    });
}

- (void)bandPresetClicked:(NSButton *)sender {
    // A preset click requests a tune; keep the highlight on the current dial
    // until the CAT operation succeeds.
    uint64_t current = ToolsParseInputFrequency([self.catFreqDisplay.stringValue stringByReplacingOccurrencesOfString:@" MHz" withString:@""]);
    [self updateActiveBandForFrequency:current];
    uint64_t freq = (uint64_t)sender.tag;
    if (freq > 0) {
        self.catFreqInputField.stringValue = ToolsFormatInputFrequency(freq);
        [self setFrequencyAction:sender];
    }
}

- (void)stepFrequencyAction:(NSButton *)sender {
    if (![self CATControlReady]) return;
    uint64_t current = ToolsParseInputFrequency([self.catFreqDisplay.stringValue stringByReplacingOccurrencesOfString:@" MHz" withString:@""]);
    if (!current) current = ToolsParseInputFrequency(self.catFreqInputField.stringValue);
    uint64_t step = self.catStepPopup.indexOfSelectedItem == 0 ? 100 :
                    self.catStepPopup.indexOfSelectedItem == 2 ? 10000 : 1000;
    if (current < 500000 || current > 56000000 ||
        (sender.tag < 0 && current < 500000 + step) ||
        (sender.tag > 0 && current > 56000000 - step)) {
        [self showCATNotice:@"Enter a valid frequency from 500 kHz to 56 MHz before stepping." error:YES];
        return;
    }
    uint64_t next = sender.tag < 0 ? current - step : current + step;
    self.catFreqInputField.stringValue = ToolsFormatInputFrequency(next);
    [self setFrequencyAction:sender];
}

- (void)quickCommandChipClicked:(NSButton *)sender {
    NSString *cmd = sender.identifier;
    if (cmd.length) {
        self.catCommandInput.stringValue = cmd;
        [self sendCommandAction:sender];
    }
}

- (void)setFrequencyAction:(id)sender {
    (void)sender;
    if (![self CATControlReady]) return;
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    if (!port) return;

    uint64_t freq = ToolsParseInputFrequency(self.catFreqInputField.stringValue);
    if (freq < 500000 || freq > 56000000) {
        [self showCATNotice:@"Invalid frequency. Enter 500.000–56.000.000 Hz (for example 21.140.000)." error:YES];
        return;
    }
    self.catFreqInputField.stringValue = ToolsFormatInputFrequency(freq);

    [self begin];
    NSString *cmd = [NSString stringWithFormat:@"FA%011llu;", freq];
    [self appendTerminalTX:cmd];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        double rtt = 0;
        NSString *reply = TXExecuteCATCommand(port, cmd, 0.1, &rtt, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            if (!err || err.code == Lab599SerialTimeout) {
                [self appendTerminalRX:reply ?: @"OK" latency:rtt error:NO];
                self.catFreqDisplay.stringValue = ToolsFormatFreq(freq);
                [self updateActiveBandForFrequency:freq];
                [self showCATNotice:[NSString stringWithFormat:@"Tune sent: %@", ToolsFormatFreq(freq)] error:NO];
                if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"Frequency tuned to %@", ToolsFormatFreq(freq)], 1);
            } else {
                [self appendTerminalRX:err.localizedDescription ?: @"Error" latency:rtt error:YES];
                [self CATCommandFailed:err];
            }
        });
    });
}

- (void)setModeAction:(id)sender {
    (void)sender;
    if (![self CATControlReady]) return;
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    if (!port) return;

    NSInteger idx = self.catModePopup.indexOfSelectedItem;
    NSInteger code = idx + 1;
    NSString *modeName = self.catModePopup.titleOfSelectedItem;

    [self begin];
    NSString *cmd = [NSString stringWithFormat:@"MD%ld;", (long)code];
    [self appendTerminalTX:cmd];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        double rtt = 0;
        NSString *reply = TXExecuteCATCommand(port, cmd, 0.1, &rtt, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            if (!err || err.code == Lab599SerialTimeout) {
                [self appendTerminalRX:reply ?: @"OK" latency:rtt error:NO];
                self.catModeBadge.stringValue = [NSString stringWithFormat:@"MODE: %@", modeName];
                if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"Mode set to %@", modeName], 1);
            } else {
                [self appendTerminalRX:err.localizedDescription ?: @"Error" latency:rtt error:YES];
                [self CATCommandFailed:err];
            }
        });
    });
}

- (void)setPowerAction:(id)sender {
    (void)sender;
    if (![self CATControlReady]) return;
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    if (!port) return;

    NSString *pTitle = self.catPowerPopup.titleOfSelectedItem;
    double watts = [pTitle doubleValue];
    if (watts <= 0) watts = 10.0;

    [self begin];
    int tenths = (int)round(watts * 10.0);
    NSString *cmd = [NSString stringWithFormat:@"PC%03d;", tenths];
    [self appendTerminalTX:cmd];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        double rtt = 0;
        NSString *reply = TXExecuteCATCommand(port, cmd, 0.1, &rtt, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            if (!err || err.code == Lab599SerialTimeout) {
                [self appendTerminalRX:reply ?: @"OK" latency:rtt error:NO];
                if (fmod(watts, 1.0) == 0.0) {
                    self.catPowerBadge.stringValue = [NSString stringWithFormat:@"PWR: %.0f W", watts];
                } else {
                    self.catPowerBadge.stringValue = [NSString stringWithFormat:@"PWR: %.1f W", watts];
                }
                self.catPowerGauge.doubleValue = MAX(0.0, MIN(10.0, watts));
                if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"RF Power set to %.0f W", watts], 1);
            } else {
                [self appendTerminalRX:err.localizedDescription ?: @"Error" latency:rtt error:YES];
                [self CATCommandFailed:err];
            }
        });
    });
}

- (void)togglePreampAction:(NSButton *)sender {
    if (![self CATControlReady]) return;
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    if (!port) return;

    BOOL on = (sender.state == NSControlStateValueOn);
    [self begin];
    NSString *cmd = [NSString stringWithFormat:@"PA%d;", on ? 1 : 0];
    [self appendTerminalTX:cmd];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        double rtt = 0;
        NSString *reply = TXExecuteCATCommand(port, cmd, 0.1, &rtt, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            if (!err || err.code == Lab599SerialTimeout) {
                [self appendTerminalRX:reply ?: @"OK" latency:rtt error:NO];
                self.catPreampBadge.stringValue = [NSString stringWithFormat:@"PRE: %@", on ? @"ON" : @"OFF"];
                if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"Preamp %@", on ? @"enabled" : @"disabled"], 1);
            } else {
                [self appendTerminalRX:err.localizedDescription ?: @"Error" latency:rtt error:YES];
                [self CATCommandFailed:err];
            }
        });
    });
}

- (void)toggleAttenuatorAction:(NSButton *)sender {
    if (![self CATControlReady]) return;
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    if (!port) return;

    BOOL on = (sender.state == NSControlStateValueOn);
    [self begin];
    NSString *cmd = [NSString stringWithFormat:@"RA%02d;", on ? 1 : 0];
    [self appendTerminalTX:cmd];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        double rtt = 0;
        NSString *reply = TXExecuteCATCommand(port, cmd, 0.1, &rtt, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            if (!err || err.code == Lab599SerialTimeout) {
                [self appendTerminalRX:reply ?: @"OK" latency:rtt error:NO];
                if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"Attenuator %@", on ? @"enabled" : @"disabled"], 1);
            } else {
                [self appendTerminalRX:err.localizedDescription ?: @"Error" latency:rtt error:YES];
                [self CATCommandFailed:err];
            }
        });
    });
}

- (void)filterChangedAction:(NSSegmentedControl *)sender {
    if (![self CATControlReady]) return;
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    if (!port) return;

    NSInteger filterIndex = sender.selectedSegment; // 0, 1, 2, 3
    NSInteger filterNum = filterIndex + 1;         // 1, 2, 3, 4
    [self begin];
    // FL0..FL3 is an app shorthand; the executor preserves the TX-filter digit.
    NSString *cmd = [NSString stringWithFormat:@"FL%ld;", (long)filterIndex];
    [self appendTerminalTX:cmd];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *err = nil;
        __block NSString *reply = nil;
        BOOL verified = TXRunCATMacro(port, @[cmd], self.token,
            ^(NSUInteger index, NSString *command, NSString *readback) {
                (void)index; (void)command; reply = readback;
            }, &err);
        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            if (verified) {
                [self appendTerminalRX:reply ?: @"Verified" latency:0 error:NO];
                self.catFilterBadge.stringValue = [NSString stringWithFormat:@"FIL: FL%ld", (long)filterNum];
                if (self.statusChanged) self.statusChanged([NSString stringWithFormat:@"Filter set to FL%ld", (long)filterNum], 1);
            } else {
                [self appendTerminalRX:err.localizedDescription ?: @"Error" latency:0 error:YES];
                [self CATCommandFailed:err];
            }
        });
    });
}

- (void)startCAT:(NSButton *)sender {
    if (self.busy || !self.hasPorts) return;
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    if (!port) return;
    [self begin];
    TXCATOptions options = TXDefaultCATOptions();
    options.maximumChecks = sender.tag;
    self.catResult.stringValue = @"Waiting for the radio…";
    self.catCounts.stringValue = @"Checks: 0    Passed: 0    Failed: 0";
    [self appendTerminalTX:@"PING (ID;)"];
    Lab599Cancellation *token = self.token;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TXCATSummary *result = TXRunCATTest(port, options, token, ^(TXCATSummary *s){
            dispatch_async(dispatch_get_main_queue(), ^{
                self.catResult.stringValue = [NSString stringWithFormat:@"%@\nReply: %@", s.message, s.lastReply ?: @"—"];
                self.catCounts.stringValue = [NSString stringWithFormat:@"Checks: %lu    Passed: %lu    Failed: %lu    Reply: %.0f ms",
                    (unsigned long)s.checks, (unsigned long)s.passed, (unsigned long)s.failed, s.responseMilliseconds];
                [self.catLatencyView addMilliseconds:s.responseMilliseconds passed:(s.lastCode == TXCATOK)];
                if (s.lastCode == TXCATOK) {
                    self.verifiedCATPort = port;
                    [self showCATNotice:@"Radio identified; CAT controls are ready." error:NO];
                } else {
                    self.verifiedCATPort = nil;
                    [self showCATNotice:s.message ?: @"CAT ping failed." error:YES];
                }
                [self refresh];
                [self appendTerminalRX:s.lastReply latency:s.responseMilliseconds error:(s.lastCode != TXCATOK)];
                if (self.statusChanged) self.statusChanged(s.message, 0);
            });
        }, ^(NSString *line){
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.log) self.log(line);
            });
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            NSString *finalMessage = result.message;
            if (result.cancelled) {
                finalMessage = self.hasPorts ?
                    @"Ping stopped. CAT port available for a new session." :
                    @"Ping stopped. CAT port disconnected.";
                self.catResult.stringValue = [NSString stringWithFormat:@"%@\nLast reply: %@",
                    finalMessage, result.lastReply ?: @"—"];
                if (self.hasPorts) {
                    BOOL verified = [self CATControlReady];
                    [self showCATNotice:verified ?
                        @"CAT port available; radio identity verified." :
                        @"CAT port available — use Read All to confirm radio communication." error:NO];
                }
            }
            if (self.statusChanged) {
                self.statusChanged(finalMessage,
                                   result.passed && !result.failed ? 1 : 0);
            }
        });
    });
}

#pragma mark - Descriptions

- (void)settingsDescription {
    self.settingsInfo.stringValue = [NSString stringWithFormat:@"%@\n1024 bytes • %@\nSHA-256: %@",
        self.settingsSource ?: @"Settings Backup",
        self.settingsDirty ? @"Not saved to a file" : @"Saved backup",
        TXFirmwareSHA256(self.settingsData)];
}

- (void)memoryDescription {
    NSUInteger used = 0;
    for (TXMemoryChannel *c in self.channels) if (c.frequency) used++;
    self.memoryInfo.stringValue = [NSString stringWithFormat:@"100 channels • %lu used • %lu empty%@",
        (unsigned long)used, (unsigned long)(100 - used), self.memoryDirty ? @" • Unsaved changes" : @""];
}

#pragma mark - Backups Load & Save

- (void)loadBackup:(NSButton *)sender {
    if (self.busy || ![self confirmReplacement:sender.tag]) return;
    NSInteger kind = sender.tag;
    NSOpenPanel *p = [NSOpenPanel openPanel];
    p.allowsMultipleSelection = NO;
    p.canChooseDirectories = NO;
    p.allowedContentTypes = @[[UTType typeWithFilenameExtension:kind == 1 ? @"set" : @"mem" conformingToType:UTTypeData]];
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){
        if (response != NSModalResponseOK) return;
        NSError *error = nil;
        NSNumber *size = nil;
        [p.URL getResourceValue:&size forKey:NSURLFileSizeKey error:&error];
        if (size.unsignedIntegerValue != (kind == 1 ? 1024 : 600)) {
            [self alert:@"Invalid backup" message:kind == 1 ? @"A .set file must be exactly 1024 bytes." : @"A .mem file must be exactly 600 bytes."];
            return;
        }
        NSData *data = [NSData dataWithContentsOfURL:p.URL options:0 error:&error];
        if (!data) {
            [self alert:@"Cannot open backup" message:error.localizedDescription];
            return;
        }
        if (kind == 1) {
            NSString *validation = TXValidateSettings(data);
            if (validation) { [self alert:@"Invalid settings file" message:validation]; return; }
            self.settingsData = data;
            self.settingsSource = p.URL.lastPathComponent;
            self.settingsDirty = NO;
            [self updateSettingsModelFromData];
            [self settingsDescription];
        } else {
            NSArray *items = TXDecodeMemory(data, &error);
            if (!items) { [self alert:@"Invalid memory file" message:error.localizedDescription]; return; }
            self.channels = [items mutableCopy];
            self.memoryReady = YES;
            self.memoryDirty = NO;
            [self.table reloadData];
            [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            [self memoryDescription];
            [self tableViewSelectionDidChange:[NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:self.table]];
        }
        [self refresh];
        if (self.log) self.log([NSString stringWithFormat:@"Loaded %@ (%lu bytes).", p.URL.lastPathComponent, (unsigned long)data.length]);
    }];
}

- (void)saveBackup:(NSButton *)sender {
    if (self.busy) return;
    NSInteger kind = sender.tag;
    NSError *error = nil;
    NSData *data = (kind == 1 ? self.settingsData : TXEncodeMemory(self.channels, &error));
    if (!data) {
        [self alert:@"Cannot save backup" message:error.localizedDescription];
        return;
    }
    NSSavePanel *p = [NSSavePanel savePanel];
    p.allowedContentTypes = @[[UTType typeWithFilenameExtension:kind == 1 ? @"set" : @"mem" conformingToType:UTTypeData]];
    p.nameFieldStringValue = (kind == 1 ? @"TX-500-settings.set" : @"TX-500-memory.mem");
    [p beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){
        if (response != NSModalResponseOK) return;
        NSError *writeError = nil;
        if (![data writeToURL:p.URL options:NSDataWritingAtomic error:&writeError]) {
            [self alert:@"Cannot save backup" message:writeError.localizedDescription];
            return;
        }
        if (kind == 1) {
            self.settingsDirty = NO;
            self.settingsSource = p.URL.lastPathComponent;
            [self settingsDescription];
        } else {
            self.memoryDirty = NO;
            [self memoryDescription];
        }
        if (self.log) self.log([NSString stringWithFormat:@"Saved %@ (%lu bytes).", p.URL.lastPathComponent, (unsigned long)data.length]);
    }];
}

- (void)newBank:(id)sender {
    (void)sender;
    if (self.busy || ![self confirmReplacement:2]) return;
    self.channels = [TXEmptyMemory() mutableCopy];
    self.memoryReady = YES;
    self.memoryDirty = YES;
    [self.table reloadData];
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self tableViewSelectionDidChange:[NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:self.table]];
    [self memoryDescription];
    [self refresh];
}

#pragma mark - Table View (Memory Channels, Settings & Comparison)

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    if (tableView == self.compareTable) {
        if (self.isSettingsComparison) {
            return self.activeSettingsDiff ? (NSInteger)self.activeSettingsDiff.diffItems.count : 0;
        } else {
            return self.activeMemoryDiff ? (NSInteger)self.activeMemoryDiff.diffItems.count : 0;
        }
    }
    if (tableView == self.settingsTable) {
        return self.filteredSettingsItems ? (NSInteger)self.filteredSettingsItems.count : 0;
    }
    return self.memoryReady ? 100 : 0;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView == self.settingsTable) {
        if (row < 0 || (NSUInteger)row >= self.filteredSettingsItems.count) return nil;
        TXSettingsItem *item = self.filteredSettingsItems[row];

        NSTableCellView *cell = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
        if (!cell) {
            cell = [NSTableCellView new];
            cell.identifier = tableColumn.identifier;

            NSTextField *tf = [NSTextField labelWithString:@""];
            tf.translatesAutoresizingMaskIntoConstraints = NO;
            tf.lineBreakMode = NSLineBreakByTruncatingTail;
            cell.textField = tf;
            [cell addSubview:tf];

            [NSLayoutConstraint activateConstraints:@[
                [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
                [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
                [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
            ]];
        }

        NSTextField *tf = cell.textField;
        NSString *colId = tableColumn.identifier;
        if ([colId isEqual:@"category"]) {
            tf.stringValue = item.category ?: @"";
            tf.font = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
            tf.textColor = NSColor.secondaryLabelColor;
        } else if ([colId isEqual:@"name"]) {
            tf.stringValue = item.name ?: @"";
            tf.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
            tf.textColor = NSColor.labelColor;
        } else if ([colId isEqual:@"address"]) {
            tf.stringValue = [NSString stringWithFormat:@"%lu", (unsigned long)item.address];
            tf.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
            tf.textColor = NSColor.secondaryLabelColor;
        } else if ([colId isEqual:@"value"]) {
            tf.stringValue = [item displayValue] ?: @"";
            tf.font = [NSFont monospacedSystemFontOfSize:11.5 weight:NSFontWeightBold];
            tf.textColor = [NSColor colorWithCalibratedRed:0.20 green:0.55 blue:0.95 alpha:1.0];
        } else if ([colId isEqual:@"unit"]) {
            tf.stringValue = item.unitOrRange ?: @"";
            tf.font = [NSFont systemFontOfSize:11];
            tf.textColor = NSColor.secondaryLabelColor;
        } else if ([colId isEqual:@"details"]) {
            tf.stringValue = item.details ?: @"";
            tf.font = [NSFont systemFontOfSize:11];
            tf.textColor = NSColor.labelColor;
        }
        return cell;
    }

    if (tableView == self.table) {
        if (row < 0 || (NSUInteger)row >= self.channels.count) return nil;
        TXMemoryChannel *c = self.channels[row];

        NSTableCellView *cell = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
        if (!cell) {
            cell = [NSTableCellView new];
            cell.identifier = tableColumn.identifier;

            NSTextField *tf = [NSTextField labelWithString:@""];
            tf.translatesAutoresizingMaskIntoConstraints = NO;
            tf.lineBreakMode = NSLineBreakByTruncatingTail;
            cell.textField = tf;
            [cell addSubview:tf];

            [NSLayoutConstraint activateConstraints:@[
                [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
                [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
                [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
            ]];
        }

        NSTextField *tf = cell.textField;
        NSString *colId = tableColumn.identifier;
        if ([colId isEqual:@"channel"]) {
            tf.stringValue = [NSString stringWithFormat:@"%02ld", (long)row];
            tf.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightBold];
            tf.textColor = NSColor.labelColor;
        } else if ([colId isEqual:@"frequency"]) {
            if (!c.frequency) {
                tf.stringValue = @"Empty";
                tf.textColor = NSColor.secondaryLabelColor;
            } else {
                tf.stringValue = [NSString stringWithFormat:@"%u Hz (%.4f MHz)", c.frequency, (double)c.frequency / 1000000.0];
                tf.textColor = NSColor.labelColor;
            }
            tf.font = [NSFont monospacedDigitSystemFontOfSize:11.5 weight:NSFontWeightMedium];
        } else if ([colId isEqual:@"mode"]) {
            tf.stringValue = @{@49:@"LSB", @50:@"USB", @51:@"CW", @52:@"FM", @53:@"AM", @55:@"CWR"}[@(c.mode)] ?: @"—";
            tf.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
            tf.textColor = NSColor.labelColor;
        } else if ([colId isEqual:@"preAtt"]) {
            tf.stringValue = @[@"Off", @"PRE", @"ATT"][c.preAtt - '0'];
            tf.font = [NSFont systemFontOfSize:11];
            tf.textColor = NSColor.secondaryLabelColor;
        }
        return cell;
    }

    if (tableView == self.compareTable) {
        NSTableCellView *cell = [tableView makeViewWithIdentifier:tableColumn.identifier owner:self];
        if (!cell) {
            cell = [NSTableCellView new];
            cell.identifier = tableColumn.identifier;

            NSTextField *tf = [NSTextField labelWithString:@""];
            tf.translatesAutoresizingMaskIntoConstraints = NO;
            tf.lineBreakMode = NSLineBreakByTruncatingTail;
            cell.textField = tf;
            [cell addSubview:tf];

            [NSLayoutConstraint activateConstraints:@[
                [tf.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
                [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
                [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
            ]];
        }
        cell.textField.stringValue = [self tableView:tableView objectValueForTableColumn:tableColumn row:row] ?: @"";
        cell.textField.font = [NSFont systemFontOfSize:11];
        return cell;
    }

    return nil;
}

- (id)tableView:(NSTableView *)tableView objectValueForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    if (tableView == self.compareTable) {
        if (self.isSettingsComparison) {
            TXSettingsDiffItem *item = self.activeSettingsDiff.diffItems[row];
            if ([column.identifier isEqual:@"addr"]) {
                return [NSString stringWithFormat:@"%lu - %@", (unsigned long)item.address, item.settingName ?: @"Raw Byte"];
            }
            if ([column.identifier isEqual:@"valA"]) return [NSString stringWithFormat:@"%u (0x%02X)", item.valueA, item.valueA];
            if ([column.identifier isEqual:@"valB"]) return [NSString stringWithFormat:@"%u (0x%02X)", item.valueB, item.valueB];
            if ([column.identifier isEqual:@"diff"]) return item.changeDescription;
            return @"";
        } else {
            TXMemoryDiffItem *item = self.activeMemoryDiff.diffItems[row];
            if ([column.identifier isEqual:@"ch"]) return [NSString stringWithFormat:@"CH %02lu", (unsigned long)item.channelIndex];
            if ([column.identifier isEqual:@"valA"]) {
                if (!item.channelA.frequency) return @"Empty";
                return [NSString stringWithFormat:@"%u Hz (%@, %@)", item.channelA.frequency,
                    @{@49:@"LSB",@50:@"USB",@51:@"CW",@52:@"FM",@53:@"AM",@55:@"CWR"}[@(item.channelA.mode)] ?: @"—",
                    @[@"Off",@"PRE",@"ATT"][item.channelA.preAtt>='0' && item.channelA.preAtt<='2' ? item.channelA.preAtt-'0' : 0]];
            }
            if ([column.identifier isEqual:@"valB"]) {
                if (!item.channelB.frequency) return @"Empty";
                return [NSString stringWithFormat:@"%u Hz (%@, %@)", item.channelB.frequency,
                    @{@49:@"LSB",@50:@"USB",@51:@"CW",@52:@"FM",@53:@"AM",@55:@"CWR"}[@(item.channelB.mode)] ?: @"—",
                    @[@"Off",@"PRE",@"ATT"][item.channelB.preAtt>='0' && item.channelB.preAtt<='2' ? item.channelB.preAtt-'0' : 0]];
            }
            if ([column.identifier isEqual:@"diff"]) return item.statusText;
            return @"";
        }
    }

    if (tableView == self.settingsTable) {
        if (row < 0 || (NSUInteger)row >= self.filteredSettingsItems.count) return @"";
        TXSettingsItem *item = self.filteredSettingsItems[row];
        if ([column.identifier isEqual:@"category"]) return item.category ?: @"";
        if ([column.identifier isEqual:@"name"]) return item.name ?: @"";
        if ([column.identifier isEqual:@"address"]) return [NSString stringWithFormat:@"%lu", (unsigned long)item.address];
        if ([column.identifier isEqual:@"value"]) return [item displayValue] ?: @"";
        if ([column.identifier isEqual:@"unit"]) return item.unitOrRange ?: @"";
        if ([column.identifier isEqual:@"details"]) return item.details ?: @"";
        return @"";
    }

    TXMemoryChannel *c = self.channels[row];
    if ([column.identifier isEqual:@"channel"]) return [NSString stringWithFormat:@"%02ld", (long)row];
    if (!c.frequency) return [column.identifier isEqual:@"frequency"] ? @"Empty" : @"—";
    if ([column.identifier isEqual:@"frequency"]) return @(c.frequency);
    if ([column.identifier isEqual:@"mode"]) return @{@49:@"LSB", @50:@"USB", @51:@"CW", @52:@"FM", @53:@"AM", @55:@"CWR"}[@(c.mode)];
    return @[@"Off", @"PRE", @"ATT"][c.preAtt - '0'];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object == self.compareTable) return;
    if (notification.object == self.settingsTable) {
        NSInteger row = self.settingsTable.selectedRow;
        if (row < 0 || (NSUInteger)row >= self.filteredSettingsItems.count) {
            self.settingEditLabel.stringValue = @"Select a setting:";
            self.settingEditField.stringValue = @"";
            self.settingEditField.placeholderString = @"";
            self.settingApplyButton.enabled = NO;
            return;
        }
        TXSettingsItem *item = self.filteredSettingsItems[row];
        self.settingEditLabel.stringValue = [NSString stringWithFormat:@"%@:", item.name];
        if (item.dataType == TXSettingsTypeModeEnum) {
            self.settingEditField.stringValue = [item displayValue];
        } else if (item.dataType == TXSettingsTypeScaleTenths) {
            self.settingEditField.stringValue = [NSString stringWithFormat:@"%.1f", (double)item.numericValue / 10.0];
        } else {
            self.settingEditField.stringValue = [NSString stringWithFormat:@"%lld", item.numericValue];
        }
        self.settingEditField.placeholderString = item.unitOrRange ?: @"";
        self.settingApplyButton.enabled = !self.busy;
        return;
    }

    NSInteger row = self.table.selectedRow;
    if (row < 0 || (NSUInteger)row >= self.channels.count) return;
    TXMemoryChannel *c = self.channels[row];
    self.frequency.stringValue = (c.frequency ? [NSString stringWithFormat:@"%u", c.frequency] : @"");
    NSUInteger index = [@[@49, @50, @51, @52, @53, @55] indexOfObject:@(c.mode)];
    [self.mode selectItemAtIndex:(index == NSNotFound ? 1 : (NSInteger)index)];
    [self.preAtt selectItemAtIndex:(c.preAtt >= '0' && c.preAtt <= '2' ? c.preAtt - '0' : 0)];
}

#pragma mark - Settings Editor Actions

- (void)updateSettingsModelFromData {
    if (!self.settingsData || self.settingsData.length != 1024) {
        self.allSettingsItems = @[];
        self.filteredSettingsItems = @[];
        [self.settingsTable reloadData];
        return;
    }
    self.allSettingsItems = [TX500SettingsModel decodeSettings:self.settingsData];
    [self settingsCategoryFilterChanged:nil];
}

- (void)settingsCategoryFilterChanged:(id)sender {
    (void)sender;
    NSString *selected = self.settingsCategoryFilter.titleOfSelectedItem;
    if (!selected || [selected isEqualToString:@"All Categories"]) {
        self.filteredSettingsItems = self.allSettingsItems;
    } else {
        NSPredicate *pred = [NSPredicate predicateWithFormat:@"category == %@", selected];
        self.filteredSettingsItems = [self.allSettingsItems filteredArrayUsingPredicate:pred];
    }
    [self.settingsTable reloadData];
    if (self.filteredSettingsItems.count > 0) {
        [self.settingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    }
    [self tableViewSelectionDidChange:[NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:self.settingsTable]];
}

- (void)editSettingAction:(id)sender {
    (void)sender;
    NSInteger row = self.settingsTable.selectedRow;
    if (self.busy || !self.settingsData || row < 0 || (NSUInteger)row >= self.filteredSettingsItems.count) return;
    TXSettingsItem *item = self.filteredSettingsItems[row];
    NSError *err = nil;
    if (![item setValueFromString:self.settingEditField.stringValue error:&err]) {
        [self alert:@"Invalid Setting Value" message:err.localizedDescription];
        return;
    }
    self.settingsData = [TX500SettingsModel encodeSettings:self.allSettingsItems baseData:self.settingsData];
    self.settingsDirty = YES;
    [self.settingsTable reloadData];
    [self settingsDescription];
    [self refresh];
}

- (void)exportJsonSettingsAction:(id)sender {
    (void)sender;
    if (self.busy || !self.settingsData) return;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"json" conformingToType:UTTypeJSON]];
    panel.nameFieldStringValue = @"TX-500-settings.json";
    panel.title = @"Export Settings to JSON";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){
        if (response != NSModalResponseOK || !panel.URL) return;
        NSError *err = nil;
        NSString *json = [TX500SettingsModel exportJSONFromSettingsData:self.settingsData error:&err];
        if (!json) {
            [self alert:@"Export Failed" message:err.localizedDescription];
            return;
        }
        if (![json writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
            [self alert:@"Export Failed" message:err.localizedDescription];
            return;
        }
        if (self.log) self.log([NSString stringWithFormat:@"Exported settings description to JSON: %@", panel.URL.lastPathComponent]);
        [self alert:@"Settings Export Complete" message:[NSString stringWithFormat:@"Successfully exported described settings to %@.", panel.URL.lastPathComponent]];
    }];
}

- (void)importJsonSettingsAction:(id)sender {
    (void)sender;
    if (self.busy || ![self confirmReplacement:1]) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"json" conformingToType:UTTypeJSON]];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.title = @"Import Settings from JSON";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){
        if (response != NSModalResponseOK || !panel.URL) return;
        NSError *err = nil;
        NSString *json = [NSString stringWithContentsOfURL:panel.URL encoding:NSUTF8StringEncoding error:&err];
        if (!json) {
            [self alert:@"Cannot Read File" message:err.localizedDescription];
            return;
        }
        NSData *newData = [TX500SettingsModel importJSON:json baseData:self.settingsData error:&err];
        if (!newData) {
            [self alert:@"Import Failed" message:err.localizedDescription];
            return;
        }
        self.settingsData = newData;
        self.settingsSource = panel.URL.lastPathComponent;
        self.settingsDirty = YES;
        [self updateSettingsModelFromData];
        [self settingsDescription];
        [self refresh];
        if (self.log) self.log([NSString stringWithFormat:@"Imported settings from JSON: %@", panel.URL.lastPathComponent]);
    }];
}

- (void)editChannel:(NSButton *)sender {
    NSInteger row = self.table.selectedRow;
    if (self.busy || !self.memoryReady || row < 0) return;
    TXMemoryChannel *c = [TXMemoryChannel new];
    if (!sender.tag) {
        NSString *text = [self.frequency.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSCharacterSet *nonDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
        long long value = text.longLongValue;
        if (!text.length || [text rangeOfCharacterFromSet:nonDigits].location != NSNotFound || value < 100000 || value > 56000000) {
            [self alert:@"Invalid frequency" message:@"Enter a whole frequency from 100000 to 56000000 Hz. Use Clear Row to empty a channel."];
            return;
        }
        c.frequency = (uint32_t)value;
        c.mode = (uint8_t)((NSNumber *)@[@49, @50, @51, @52, @53, @55, @50][self.mode.indexOfSelectedItem]).intValue;
        c.preAtt = (uint8_t)('0' + self.preAtt.indexOfSelectedItem);
    }
    self.channels[row] = c;
    self.memoryDirty = YES;
    [self.table reloadData];
    [self memoryDescription];
    [self tableViewSelectionDidChange:[NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:self.table]];
}

#pragma mark - Radio Transfer (Settings & Memory)

- (void)readRadio:(NSButton *)sender {
    if (self.busy || !self.hasPorts || ![self confirmReplacement:sender.tag]) return;
    [self transfer:sender.tag writing:NO];
}

- (void)writeRadio:(NSButton *)sender {
    if (self.busy || !self.hasPorts) return;
    if (sender.tag == 1 && !self.settingsData) return;
    if (sender.tag == 2 && !self.memoryReady) return;
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    if (!port) return;
    NSString *detail = (sender.tag == 1 ?
        [NSString stringWithFormat:@"Restore all 1024 settings bytes from %@.\nSHA-256: %@", self.settingsSource ?: @"loaded settings", TXFirmwareSHA256(self.settingsData)] :
        [NSString stringWithFormat:@"%@\nAll 100 radio memory channels will be replaced, including empty rows. The original utility's fixed memory fields are used.", self.memoryInfo.stringValue]);
    if (![self confirm:@"Write this backup to the radio?"
               message:[NSString stringWithFormat:@"%@\n\nPort: %@\nKeep the radio powered on normally and the cable connected. The app will read back and check the result.", detail, port]
                button:@"Write and Verify"]) return;
    [self transfer:sender.tag writing:YES];
}

- (void)transfer:(NSInteger)kind writing:(BOOL)writing {
    NSString *port = self.selectedPort ? self.selectedPort() : nil;
    if (!port) return;
    NSData *settings = (writing && kind == 1 ? self.settingsData : nil);
    NSArray *channels = (writing && kind == 2 ? [[NSArray alloc] initWithArray:self.channels copyItems:YES] : nil);
    [self begin];
    Lab599Cancellation *token = self.token;
    NSString *name = (kind == 1 ? @"Settings" : @"Memory");
    if (self.log) self.log([NSString stringWithFormat:@"%@: %@ on %@ at 9600 baud.", name, writing ? @"write + verify" : @"read", port]);
    if (self.statusChanged) self.statusChanged(@"Opening radio connection…", 0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        TXConfigurationProgress progress = ^(NSString *phase, NSUInteger done, NSUInteger total){
            if (done != 1 && done != total && done % 8) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.statusChanged) {
                    self.statusChanged([NSString stringWithFormat:@"%@: %lu / %lu", phase, (unsigned long)done, (unsigned long)total], (double)done / total);
                }
            });
        };
        TXConfigurationResult *result = (kind == 1 ?
            TXSettingsTransfer(port, settings, TXDefaultConfigurationOptions(), token, progress) :
            TXMemoryTransfer(port, channels, TXDefaultConfigurationOptions(), token, progress));
        dispatch_async(dispatch_get_main_queue(), ^{
            [self end];
            if (result.success && !writing) {
                if (kind == 1) {
                    self.settingsData = result.settings;
                    self.settingsSource = @"Read from radio";
                    self.settingsDirty = YES;
                    [self updateSettingsModelFromData];
                    [self settingsDescription];
                } else {
                    self.channels = [result.channels mutableCopy];
                    self.memoryReady = YES;
                    self.memoryDirty = YES;
                    [self.table reloadData];
                    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
                    [self memoryDescription];
                }
                if (kind == 2) {
                    [self tableViewSelectionDidChange:[NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:self.table]];
                }
            }
            [self refresh];
            if (self.statusChanged) self.statusChanged(result.message, result.success ? 1 : 0);
            if (self.log) self.log([result.message stringByAppendingString:@" Serial port closed."]);
            if (!result.success && !result.cancelled) [self alert:@"Radio operation was not confirmed" message:result.message];
        });
    });
}

#pragma mark - CSV Import & Export

- (void)exportCSVAction:(id)sender {
    (void)sender;
    if (self.busy || !self.memoryReady) return;
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"csv" conformingToType:UTTypeText]];
    panel.nameFieldStringValue = @"TX-500-channels.csv";
    panel.title = @"Export Memory Channels to CSV";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){
        if (response != NSModalResponseOK || !panel.URL) return;
        NSString *csv = TXExportMemoryToCSV(self.channels);
        NSError *writeError = nil;
        if (![csv writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&writeError]) {
            [self alert:@"Export Failed" message:writeError.localizedDescription];
            return;
        }
        if (self.log) self.log([NSString stringWithFormat:@"Exported 100 channels to CSV: %@", panel.URL.lastPathComponent]);
        [self alert:@"CSV Export Complete" message:[NSString stringWithFormat:@"Successfully exported 100 memory channels to %@.", panel.URL.lastPathComponent]];
    }];
}

- (void)importCSVAction:(id)sender {
    (void)sender;
    if (self.busy || ![self confirmReplacement:2]) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"csv" conformingToType:UTTypeText]];
    panel.allowsMultipleSelection = NO;
    panel.canChooseDirectories = NO;
    panel.title = @"Import Memory Channels from CSV";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){
        if (response != NSModalResponseOK || !panel.URL) return;
        NSError *readError = nil;
        NSString *csv = [NSString stringWithContentsOfURL:panel.URL encoding:NSUTF8StringEncoding error:&readError];
        if (!csv) {
            csv = [NSString stringWithContentsOfURL:panel.URL encoding:NSASCIIStringEncoding error:&readError];
        }
        if (!csv) {
            [self alert:@"Cannot Read CSV" message:readError.localizedDescription];
            return;
        }
        NSError *parseError = nil;
        NSArray<TXMemoryChannel *> *imported = TXImportMemoryFromCSV(csv, &parseError);
        if (!imported) {
            [self alert:@"CSV Parsing Failed" message:parseError.localizedDescription];
            return;
        }
        self.channels = [imported mutableCopy];
        self.memoryReady = YES;
        self.memoryDirty = YES;
        [self.table reloadData];
        [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
        [self memoryDescription];
        [self tableViewSelectionDidChange:[NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:self.table]];
        [self refresh];

        NSUInteger used = 0;
        for (TXMemoryChannel *ch in imported) if (ch.frequency > 0) used++;
        NSString *msg = [NSString stringWithFormat:@"Imported %lu active channels from %@ into the bank. Click 'Write 100 Channels…' to write them to your transceiver.", (unsigned long)used, panel.URL.lastPathComponent];
        if (self.log) self.log(msg);
        [self alert:@"CSV Import Successful" message:msg];
    }];
}

#pragma mark - Operating Profiles

- (void)populateProfilesMenu {
    [self.profilesPopup removeAllItems];
    [self.profilesPopup addItemWithTitle:@"Select Operating Profile…"];

    NSMenuItem *header1 = [NSMenuItem new];
    header1.title = @"── Built-in Presets ──";
    header1.enabled = NO;
    [self.profilesPopup.menu addItem:header1];

    NSArray<TXOperatingProfile *> *builtIns = [TXProfileManager builtInProfiles];
    for (TXOperatingProfile *p in builtIns) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:p.name action:NULL keyEquivalent:@""];
        item.representedObject = p;
        [self.profilesPopup.menu addItem:item];
    }

    NSMenuItem *header2 = [NSMenuItem new];
    header2.title = @"── User Profiles ──";
    header2.enabled = NO;
    [self.profilesPopup.menu addItem:header2];

    NSMenuItem *saveItem = [[NSMenuItem alloc] initWithTitle:@"💾 Save Current Bank as Profile…" action:NULL keyEquivalent:@""];
    saveItem.tag = 999;
    [self.profilesPopup.menu addItem:saveItem];

    NSArray<TXOperatingProfile *> *userProfiles = [TXProfileManager userProfiles];
    for (TXOperatingProfile *p in userProfiles) {
        NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"👤 %@", p.name] action:NULL keyEquivalent:@""];
        item.representedObject = p;
        [self.profilesPopup.menu addItem:item];
    }
}

- (void)profileSelected:(NSPopUpButton *)sender {
    NSMenuItem *item = sender.selectedItem;
    [sender selectItemAtIndex:0]; // Reset popup to title

    if (item.tag == 999) {
        // Save current as profile
        if (!self.memoryReady) {
            [self alert:@"No Memory Loaded" message:@"Open or populate a memory bank before saving it as a profile."];
            return;
        }
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Save Operating Profile";
        alert.informativeText = @"Enter a name for this custom operating profile:";
        NSTextField *input = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
        input.placeholderString = @"e.g. Field Day 2026, QRP Summit";
        alert.accessoryView = input;
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Cancel"];
        if ([alert runModal] == NSAlertFirstButtonReturn) {
            NSString *name = [input.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (!name.length) return;
            NSError *err = nil;
            if ([TXProfileManager saveUserProfileNamed:name channels:self.channels error:&err]) {
                [self populateProfilesMenu];
                if (self.log) self.log([NSString stringWithFormat:@"Saved custom operating profile: %@", name]);
                [self alert:@"Profile Saved" message:[NSString stringWithFormat:@"Operating profile '%@' was saved successfully.", name]];
            } else {
                [self alert:@"Save Failed" message:err.localizedDescription];
            }
        }
        return;
    }

    TXOperatingProfile *profile = item.representedObject;
    if (!profile) return;

    if (![self confirmReplacement:2]) return;

    self.channels = [[NSArray alloc] initWithArray:profile.channels copyItems:YES].mutableCopy;
    self.memoryReady = YES;
    self.memoryDirty = YES;
    [self.table reloadData];
    [self.table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
    [self memoryDescription];
    [self tableViewSelectionDidChange:[NSNotification notificationWithName:NSTableViewSelectionDidChangeNotification object:self.table]];
    [self refresh];

    NSUInteger used = 0;
    for (TXMemoryChannel *ch in self.channels) if (ch.frequency > 0) used++;
    NSString *msg = [NSString stringWithFormat:@"Applied Operating Profile '%@' (%lu channels active). %@", profile.name, (unsigned long)used, profile.details ?: @""];
    if (self.log) self.log(msg);
    [self alert:@"Profile Applied" message:[msg stringByAppendingString:@"\n\nClick 'Write 100 Channels…' to update your radio."]];
}

#pragma mark - Backup Comparison

- (void)compareSettingsAction:(id)sender {
    (void)sender;
    if (self.busy) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"set" conformingToType:UTTypeData]];
    panel.allowsMultipleSelection = (self.settingsData == nil); // If none loaded, pick 2
    panel.title = (self.settingsData ? @"Select a Second .set File to Compare" : @"Select Two .set Files to Compare (Command-click to select 2)");
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){
        if (response != NSModalResponseOK || !panel.URLs.count) return;
        NSData *dataA = nil;
        NSData *dataB = nil;
        NSString *nameA = nil;
        NSString *nameB = nil;

        if (panel.URLs.count >= 2) {
            nameA = panel.URLs[0].lastPathComponent;
            nameB = panel.URLs[1].lastPathComponent;
            dataA = [NSData dataWithContentsOfURL:panel.URLs[0]];
            dataB = [NSData dataWithContentsOfURL:panel.URLs[1]];
        } else if (self.settingsData) {
            nameA = self.settingsSource ?: @"Active Radio Settings";
            nameB = panel.URL.lastPathComponent;
            dataA = self.settingsData;
            dataB = [NSData dataWithContentsOfURL:panel.URL];
        } else {
            [self alert:@"Comparison Requires Two Files" message:@"Select two .set files by holding Command, or open one backup first before comparing."];
            return;
        }

        if (dataA.length != 1024 || dataB.length != 1024) {
            [self alert:@"Invalid Settings Files" message:@"Both .set files must be exactly 1024 bytes."];
            return;
        }

        self.isSettingsComparison = YES;
        self.activeSettingsDiff = TXCompareSettings(dataA, dataB, nameA, nameB);
        [self showCompareSheetWithTitle:@"Settings Backup Comparison (.set)"
                                summary:self.activeSettingsDiff.summary];
    }];
}

- (void)compareMemoryAction:(id)sender {
    (void)sender;
    if (self.busy) return;
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.allowedContentTypes = @[[UTType typeWithFilenameExtension:@"mem" conformingToType:UTTypeData]];
    panel.allowsMultipleSelection = (!self.memoryReady);
    panel.title = (self.memoryReady ? @"Select a Second .mem File to Compare" : @"Select Two .mem Files to Compare (Command-click to select 2)");
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response){
        if (response != NSModalResponseOK || !panel.URLs.count) return;
        NSArray<TXMemoryChannel *> *bankA = nil;
        NSArray<TXMemoryChannel *> *bankB = nil;
        NSString *nameA = nil;
        NSString *nameB = nil;
        NSError *err = nil;

        if (panel.URLs.count >= 2) {
            nameA = panel.URLs[0].lastPathComponent;
            nameB = panel.URLs[1].lastPathComponent;
            NSData *dA = [NSData dataWithContentsOfURL:panel.URLs[0]];
            NSData *dB = [NSData dataWithContentsOfURL:panel.URLs[1]];
            bankA = TXDecodeMemory(dA, &err);
            bankB = TXDecodeMemory(dB, &err);
        } else if (self.memoryReady) {
            nameA = @"Active Channel Bank";
            nameB = panel.URL.lastPathComponent;
            bankA = self.channels;
            NSData *dB = [NSData dataWithContentsOfURL:panel.URL];
            bankB = TXDecodeMemory(dB, &err);
        } else {
            [self alert:@"Comparison Requires Two Files" message:@"Select two .mem files by holding Command, or open one backup first before comparing."];
            return;
        }

        if (!bankA || !bankB) {
            [self alert:@"Invalid Memory Files" message:@"Both .mem files must be exactly 600 bytes and conform to TX-500 memory format."];
            return;
        }

        self.isSettingsComparison = NO;
        self.activeMemoryDiff = TXCompareMemory(bankA, bankB, nameA, nameB);
        [self showCompareSheetWithTitle:@"Memory Backup Comparison (.mem)"
                                summary:self.activeMemoryDiff.summary];
    }];
}

- (void)showCompareSheetWithTitle:(NSString *)title summary:(NSString *)summary {
    if (!self.compareSheet) {
        self.compareSheet = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 760, 480)
            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskResizable)
            backing:NSBackingStoreBuffered defer:NO];
        self.compareSheet.minSize = NSMakeSize(650, 400);

        NSTextField *header = [NSTextField labelWithString:title];
        header.font = [NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];
        self.compareSummaryLabel = [NSTextField wrappingLabelWithString:summary];
        self.compareSummaryLabel.textColor = NSColor.labelColor;

        self.compareTable = [NSTableView new];
        self.compareTable.delegate = self;
        self.compareTable.dataSource = self;
        self.compareTable.rowHeight = 24;
        self.compareTable.usesAlternatingRowBackgroundColors = YES;

        NSArray *columns = @[
            @{@"id": @"addr", @"title": @"Item / Address", @"width": @230},
            @{@"id": @"valA", @"title": @"Backup A (Base)", @"width": @140},
            @{@"id": @"valB", @"title": @"Backup B (Compared)", @"width": @140},
            @{@"id": @"diff", @"title": @"Difference / Status", @"width": @170}
        ];
        for (NSDictionary *col in columns) {
            NSTableColumn *tc = [[NSTableColumn alloc] initWithIdentifier:col[@"id"]];
            tc.title = col[@"title"];
            tc.width = [col[@"width"] doubleValue];
            tc.editable = NO;
            [self.compareTable addTableColumn:tc];
        }

        NSScrollView *tableScroll = [NSScrollView new];
        tableScroll.hasVerticalScroller = YES;
        tableScroll.borderType = NSBezelBorder;
        tableScroll.documentView = self.compareTable;

        NSButton *closeBtn = [NSButton buttonWithTitle:@"Close Comparison" target:self action:@selector(closeCompareSheet:)];
        closeBtn.bezelStyle = NSBezelStyleRounded;
        closeBtn.keyEquivalent = @"\033"; // Escape

        NSStackView *stack = [NSStackView stackViewWithViews:@[header, self.compareSummaryLabel, tableScroll, closeBtn]];
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 10;
        [self.compareSheet.contentView addSubview:stack];

        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:self.compareSheet.contentView.leadingAnchor constant:20],
            [stack.trailingAnchor constraintEqualToAnchor:self.compareSheet.contentView.trailingAnchor constant:-20],
            [stack.topAnchor constraintEqualToAnchor:self.compareSheet.contentView.topAnchor constant:20],
            [stack.bottomAnchor constraintEqualToAnchor:self.compareSheet.contentView.bottomAnchor constant:-20],
            [header.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
            [self.compareSummaryLabel.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
            [tableScroll.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
            [closeBtn.trailingAnchor constraintEqualToAnchor:stack.trailingAnchor]
        ]];
    }

    self.compareSheet.title = title;
    self.compareSummaryLabel.stringValue = summary;
    [self.compareTable reloadData];
    [self.window beginSheet:self.compareSheet completionHandler:nil];
}

- (void)closeCompareSheet:(id)sender {
    (void)sender;
    [self.window endSheet:self.compareSheet];
    [self.compareSheet orderOut:nil];
}

@end
