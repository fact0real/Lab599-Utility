#import "Lab599DriverController.h"

// A device node is only a candidate. Seeing one does not identify a TX-500,
// prove that the adapter works, or establish which USB driver created it.
NSArray<NSString *> *Lab599CandidateCATPortPaths(NSArray<NSString *> *deviceNames) {
    NSMutableArray<NSString *> *ports = [NSMutableArray array];
    for (NSString *name in deviceNames) {
        if (![name hasPrefix:@"cu."] || [name hasPrefix:@"cu.Bluetooth"] ||
            [name hasPrefix:@"cu.debug-"] ||
            [name containsString:@"/"]) continue;
        [ports addObject:[@"/dev/" stringByAppendingString:name]];
    }
    return [ports sortedArrayUsingSelector:@selector(compare:)];
}

@interface Lab599DriverController ()
@property(nonatomic, strong, readwrite) NSView *view;
@property(nonatomic, strong) NSTextField *portStatusLabel;
@property(nonatomic, strong) NSTextField *portsDetailLabel;
@end

@implementation Lab599DriverController

static NSTextField *ConnectionLabel(NSString *text, BOOL bold) {
    NSTextField *label = [NSTextField wrappingLabelWithString:text];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.font = [NSFont systemFontOfSize:bold ? 13 : 12
                                   weight:bold ? NSFontWeightSemibold : NSFontWeightRegular];
    label.textColor = bold ? NSColor.labelColor : NSColor.secondaryLabelColor;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    return label;
}

static NSBox *ConnectionCard(NSArray<NSView *> *content) {
    NSBox *card = [NSBox new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    card.boxType = NSBoxCustom;
    card.cornerRadius = 8;
    card.borderWidth = 1;
    card.borderColor = NSColor.separatorColor;
    card.fillColor = [NSColor colorWithCalibratedWhite:0.5 alpha:0.04];

    NSStackView *stack = [NSStackView stackViewWithViews:content];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 8;
    [card.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:card.contentView.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:card.contentView.trailingAnchor constant:-16],
        [stack.topAnchor constraintEqualToAnchor:card.contentView.topAnchor constant:14],
        [stack.bottomAnchor constraintEqualToAnchor:card.contentView.bottomAnchor constant:-14]
    ]];
    for (NSView *view in content) {
        [view.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
    }
    return card;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self buildUI];
        [self refreshDevices];
    }
    return self;
}

- (void)buildUI {
    self.view = [NSView new];
    self.view.translatesAutoresizingMaskIntoConstraints = NO;

    NSBox *setupCard = ConnectionCard(@[
        ConnectionLabel(@"Connect and check CAT", YES),
        ConnectionLabel(@"1. Connect the CAT-USB adapter, such as Lab599 AD-502, and select its /dev/cu.* port in the toolbar. The cable supplies CAT control; digital audio needs a separate audio connection.", NO),
        ConnectionLabel(@"2. Power on the radio normally. For Lab599 Utility, set the radio's CAT Protocol menu to LAB599 and use 9600 baud, 8 data bits, no parity, and 1 stop bit. Menu numbers vary by model and firmware.", NO),
        ConnectionLabel(@"3. Open CAT Studio and use Read All to check the selected port. A listed port alone does not verify the radio or its CAT settings.", NO)
    ]);

    self.portStatusLabel = ConnectionLabel(@"Checking serial ports…", YES);
    self.portsDetailLabel = ConnectionLabel(@"", NO);
    self.portsDetailLabel.font = [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular];
    NSBox *portsCard = ConnectionCard(@[self.portStatusLabel, self.portsDetailLabel]);

    NSBox *helpCard = ConnectionCard(@[
        ConnectionLabel(@"If no port appears", YES),
        ConnectionLabel(@"Check the cable, USB adapter, and System Information → USB. If macOS sees an FTDI-based adapter but creates no serial port, consult FTDI's VCP driver guidance. Lab599 Utility uses macOS serial ports; it does not need the FTDI D2XX direct-access library. Installing D2XX does not establish a CAT connection.", NO)
    ]);

    NSButton *refreshButton = [NSButton buttonWithTitle:@"Refresh Ports" target:self action:@selector(refreshPortStatus)];
    NSButton *catButton = [NSButton buttonWithTitle:@"Open CAT Studio" target:self action:@selector(openCATStudio:)];
    NSButton *vcpButton = [NSButton buttonWithTitle:@"FTDI VCP Guidance" target:self action:@selector(openVCPGuide:)];
    NSButton *manualButton = [NSButton buttonWithTitle:@"Lab599 Manuals" target:self action:@selector(openLab599Manuals:)];
    for (NSButton *button in @[refreshButton, catButton, vcpButton, manualButton]) {
        button.bezelStyle = NSBezelStyleRounded;
    }
    NSStackView *primaryActions = [NSStackView stackViewWithViews:@[refreshButton, catButton]];
    primaryActions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    primaryActions.spacing = 10;
    NSStackView *helpActions = [NSStackView stackViewWithViews:@[vcpButton, manualButton]];
    helpActions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    helpActions.spacing = 10;
    NSStackView *actions = [NSStackView stackViewWithViews:@[primaryActions, helpActions]];
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    actions.orientation = NSUserInterfaceLayoutOrientationVertical;
    actions.alignment = NSLayoutAttributeLeading;
    actions.spacing = 5;

    NSStackView *main = [NSStackView stackViewWithViews:@[setupCard, portsCard, helpCard, actions]];
    main.translatesAutoresizingMaskIntoConstraints = NO;
    main.orientation = NSUserInterfaceLayoutOrientationVertical;
    main.alignment = NSLayoutAttributeLeading;
    main.spacing = 10;
    [self.view addSubview:main];
    [NSLayoutConstraint activateConstraints:@[
        [main.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [main.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [main.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [main.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [setupCard.widthAnchor constraintEqualToAnchor:main.widthAnchor],
        [portsCard.widthAnchor constraintEqualToAnchor:main.widthAnchor],
        [helpCard.widthAnchor constraintEqualToAnchor:main.widthAnchor]
    ]];
}

- (void)refreshPortStatus {
    [self refreshDevices];
}

- (void)refreshDevices {
    NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:@"/dev" error:NULL] ?: @[];
    NSArray<NSString *> *ports = Lab599CandidateCATPortPaths(names);
    if (ports.count) {
        self.portStatusLabel.stringValue = [NSString stringWithFormat:@"Possible serial ports: %lu", (unsigned long)ports.count];
        self.portStatusLabel.textColor = NSColor.labelColor;
        self.portsDetailLabel.stringValue = [NSString stringWithFormat:@"%@\nThese are device names only. Use CAT Studio to check the selected radio.", [ports componentsJoinedByString:@", "]];
    } else {
        self.portStatusLabel.stringValue = @"No candidate serial ports found";
        self.portStatusLabel.textColor = NSColor.secondaryLabelColor;
        self.portsDetailLabel.stringValue = @"Connect the CAT-USB adapter, then click Refresh Ports. If no port appears, use the VCP guidance below.";
    }
}

- (void)openCATStudio:(id)sender {
    (void)sender;
    if (self.openCATStudio) self.openCATStudio();
}

- (void)openVCPGuide:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://ftdichip.com/drivers/vcp-drivers/"]];
}

- (void)openLab599Manuals:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://lab599.com/downloads/"]];
}

@end
