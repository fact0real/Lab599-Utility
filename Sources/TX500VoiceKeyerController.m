#import "TX500VoiceKeyerController.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSColor *VoiceAccent(void) {
    return [NSColor colorWithName:nil dynamicProvider:^NSColor *(NSAppearance *appearance) {
        BOOL dark=[[appearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]] isEqualToString:NSAppearanceNameDarkAqua];
        return dark ? [NSColor colorWithSRGBRed:0.22 green:0.84 blue:0.75 alpha:1] : [NSColor colorWithSRGBRed:0.02 green:0.43 blue:0.38 alpha:1];
    }];
}
static NSTextField *VoiceLabel(NSString *text, CGFloat size, NSFontWeight weight) {
    NSTextField *label=[NSTextField labelWithString:text]; label.font=[NSFont systemFontOfSize:size weight:weight];
    label.textColor=NSColor.labelColor; label.translatesAutoresizingMaskIntoConstraints=NO; return label;
}
static NSStackView *VoiceStack(NSArray *views, BOOL vertical, CGFloat spacing) {
    NSStackView *stack=[NSStackView stackViewWithViews:views]; stack.orientation=vertical ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
    stack.spacing=spacing; stack.alignment=vertical ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    stack.translatesAutoresizingMaskIntoConstraints=NO; return stack;
}
static NSView *VoiceSpacer(void) {
    NSView *v=[NSView new]; v.translatesAutoresizingMaskIntoConstraints=NO;
    [v setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal]; return v;
}
static NSBox *VoiceCard(NSView *content) {
    NSBox *box=[NSBox new]; box.boxType=NSBoxCustom; box.titlePosition=NSNoTitle; box.cornerRadius=12;
    box.fillColor=NSColor.controlBackgroundColor; box.borderColor=NSColor.separatorColor; box.borderWidth=1;
    box.translatesAutoresizingMaskIntoConstraints=NO; [box.contentView addSubview:content];
    [NSLayoutConstraint activateConstraints:@[[content.leadingAnchor constraintEqualToAnchor:box.contentView.leadingAnchor constant:14], [content.trailingAnchor constraintEqualToAnchor:box.contentView.trailingAnchor constant:-14], [content.topAnchor constraintEqualToAnchor:box.contentView.topAnchor constant:14], [content.bottomAnchor constraintEqualToAnchor:box.contentView.bottomAnchor constant:-14]]]; return box;
}
@interface TXVoiceResponsiveView : NSView
@property(nonatomic, copy) void (^widthChanged)(CGFloat width);
@end
@implementation TXVoiceResponsiveView
- (void)layout { [super layout]; if(self.widthChanged) self.widthChanged(self.bounds.size.width); }
@end
@interface TXVoiceWaveform : NSView
@property(nonatomic, copy) NSArray<NSNumber *> *peaks;
@property(nonatomic) double progress;
@property(nonatomic) BOOL recording;
@property(nonatomic) double level;
@end
@implementation TXVoiceWaveform
- (instancetype)init { if((self=[super initWithFrame:NSZeroRect])) { self.translatesAutoresizingMaskIntoConstraints=NO; _peaks=@[]; } return self; }
- (void)drawRect:(NSRect)dirtyRect {
    (void)dirtyRect; NSRect r=NSInsetRect(self.bounds,12,10);
    [[NSColor colorWithWhite:0.065 alpha:1] setFill]; [[NSBezierPath bezierPathWithRoundedRect:self.bounds xRadius:8 yRadius:8] fill];
    [[NSColor colorWithWhite:0.16 alpha:1] setStroke]; NSBezierPath *grid=[NSBezierPath bezierPath];
    for(int i=1;i<5;i++) { CGFloat x=NSMinX(r)+r.size.width*i/5; [grid moveToPoint:NSMakePoint(x,NSMinY(r))]; [grid lineToPoint:NSMakePoint(x,NSMaxY(r))]; }
    [grid moveToPoint:NSMakePoint(NSMinX(r),NSMidY(r))]; [grid lineToPoint:NSMakePoint(NSMaxX(r),NSMidY(r))]; [grid stroke];
    NSUInteger bins=self.peaks.count;
    if(!bins && !self.recording) {
        NSString *text=@"Your voice, ready for the air";
        NSDictionary *attrs=@{NSFontAttributeName:[NSFont systemFontOfSize:13], NSForegroundColorAttributeName:[NSColor colorWithWhite:0.65 alpha:1]};
        NSSize s=[text sizeWithAttributes:attrs]; [text drawAtPoint:NSMakePoint(NSMidX(r)-s.width/2,NSMidY(r)+12) withAttributes:attrs]; return;
    }
    if(self.recording) bins=70;
    CGFloat width=r.size.width/MAX(1,bins);
    for(NSUInteger i=0;i<bins;i++) {
        double p=self.recording ? pow(10,self.level/40)*(0.45+0.55*fabs(sin(i*1.7))) : self.peaks[i].doubleValue;
        CGFloat height=MAX(2,MIN(1,p)*r.size.height);
        NSColor *color=self.recording ? NSColor.systemRedColor : ((double)i/MAX(1,bins)<self.progress ? VoiceAccent() : [VoiceAccent() colorWithAlphaComponent:0.35]);
        [color setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(NSMinX(r)+i*width,NSMidY(r)-height/2,MAX(1,width-1.5),height) xRadius:1 yRadius:1] fill];
    }
    if(self.progress>0 && !self.recording) {
        [VoiceAccent() setStroke]; NSBezierPath *cursor=[NSBezierPath bezierPath];
        CGFloat x=NSMinX(r)+r.size.width*self.progress; [cursor moveToPoint:NSMakePoint(x,NSMinY(r))]; [cursor lineToPoint:NSMakePoint(x,NSMaxY(r))]; [cursor stroke];
    }
}
@end
@interface TXVoiceTalkButton : NSButton
@property(nonatomic, copy) void (^pressChanged)(BOOL);
@end
@implementation TXVoiceTalkButton
- (void)mouseDown:(NSEvent *)event {
    if(!self.enabled) return;
    if(self.pressChanged) self.pressChanged(YES);
    [super mouseDown:event];
    if(self.pressChanged) self.pressChanged(NO);
}
@end

@interface TX500VoiceKeyerController () <NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate>
@property(nonatomic, strong) NSView *view;
@property(nonatomic, strong) TX500VoiceKeyer *keyer;
@end
@implementation TX500VoiceKeyerController {
    TX500VoiceLibrary *_library;
    NSTableView *_table;
    NSTextField *_empty, *_messageTitle, *_subtitle, *_phase, *_status, *_countdown, *_sessionCount, *_frequency, *_levelLabel, *_timingLabel;
    NSSegmentedControl *_role;
    NSPopUpButton *_mode, *_radioOutput, *_microphone, *_headphones, *_radioInput;
    NSSlider *_gain, *_interval, *_variation, *_lead, *_tail;
    NSStepper *_limit;
    NSTextField *_limitLabel;
    NSButton *_send, *_repeat, *_stop, *_preview, *_record, *_connect, *_apply, *_line, *_listen, *_import, *_remove, *_save;
    TXVoiceTalkButton *_talk;
    TXVoiceWaveform *_wave;
    NSProgressIndicator *_progress;
    TX500VoiceAudioIO *_capture, *_receiver;
    TX500VoicePlayer *_previewPlayer;
    NSTimer *_uiTimer;
    id _keyMonitor;
    BOOL _visible, _recording, _importing, _talkHeld, _listenWanted, _requestingPermission, _previewing, _talkReady;
    NSString *_connectedPort, *_rxInputUID, *_rxOutputUID, *_recordInputUID;
    NSUInteger _uiGeneration, _previewGeneration;
    NSArray<NSControl *> *_configurationControls;
    NSStackView *_workspaceStack, *_frequencyStack, *_transportStack, *_routesStack, *_levelStack;
    NSArray<NSLayoutConstraint *> *_wideWorkspaceConstraints, *_narrowWorkspaceConstraints;
    BOOL _compactLayout;
}
- (instancetype)init {
    if((self=[super init])) {
        NSString *testRoot=NSProcessInfo.processInfo.environment[@"TX500_VOICE_TEST_ROOT"];
        NSURL *root=testRoot.length ? [NSURL fileURLWithPath:testRoot isDirectory:YES] : [[NSFileManager.defaultManager URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask] firstObject];
        _library=[[TX500VoiceLibrary alloc] initWithDirectory:[root URLByAppendingPathComponent:@"Lab599 Utility/Voice Keyer" isDirectory:YES]];
        _capture=[TX500VoiceAudioIO new]; _receiver=[TX500VoiceAudioIO new]; _previewPlayer=[TX500VoicePlayer new];
        [self buildView]; [self refreshDevices]; [self reloadLibrary:nil];
        __weak typeof(self) weakSelf=self;
        _uiTimer=[NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) { (void)timer; [weakSelf updateUI]; }];
        [NSRunLoop.mainRunLoop addTimer:_uiTimer forMode:NSRunLoopCommonModes];
        _keyMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown|NSEventMaskKeyUp handler:^NSEvent *(NSEvent *event) { return [weakSelf handleKey:event]; }];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(lostFocus:) name:NSApplicationDidResignActiveNotification object:nil];
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(willSleep:) name:NSWorkspaceWillSleepNotification object:nil];
    } return self;
}
- (NSButton *)button:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    NSButton *button=[NSButton buttonWithTitle:title target:self action:action]; button.bezelStyle=NSBezelStyleRounded;
    button.font=[NSFont systemFontOfSize:12 weight:NSFontWeightMedium]; button.translatesAutoresizingMaskIntoConstraints=NO;
    if(symbol.length) { button.image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title]; button.imagePosition=NSImageLeft; }
    [button.heightAnchor constraintEqualToConstant:32].active=YES; return button;
}
- (NSPopUpButton *)menu {
    NSPopUpButton *p=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO]; p.translatesAutoresizingMaskIntoConstraints=NO; p.font=[NSFont systemFontOfSize:11];
    p.target=self; p.action=@selector(routeChanged:); [p.widthAnchor constraintGreaterThanOrEqualToConstant:125].active=YES; return p;
}
- (NSSlider *)slider:(double)value min:(double)min max:(double)max {
    NSSlider *s=[NSSlider sliderWithValue:value minValue:min maxValue:max target:self action:@selector(settingsChanged:)]; s.translatesAutoresizingMaskIntoConstraints=NO;
    [s.widthAnchor constraintGreaterThanOrEqualToConstant:100].active=YES; return s;
}
- (void)buildView {
    self.view=[TXVoiceResponsiveView new]; self.view.translatesAutoresizingMaskIntoConstraints=NO;
    __weak typeof(self) layoutSelf=self;
    ((TXVoiceResponsiveView *)self.view).widthChanged=^(CGFloat width) { [layoutSelf adaptWidth:width]; };
    NSTextField *eyebrow=VoiceLabel(@"VOICE KEYER  /  OPERATOR STUDIO",10,NSFontWeightBold); eyebrow.textColor=VoiceAccent();
    NSTextField *title=VoiceLabel(@"Make every call sound like you.",25,NSFontWeightSemibold);
    NSTextField *description=VoiceLabel(@"Record a call, leave room for a reply, and take over in a heartbeat.",12,NSFontWeightRegular); description.textColor=NSColor.secondaryLabelColor; description.maximumNumberOfLines=2; description.lineBreakMode=NSLineBreakByWordWrapping;
    [description setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *header=VoiceStack(@[eyebrow,title,description],YES,5);
    [description.widthAnchor constraintEqualToAnchor:header.widthAnchor].active=YES;

    _import=[self button:@"Import" symbol:@"square.and.arrow.down" action:@selector(importAudio:)];
    _record=[self button:@"Record" symbol:@"mic" action:@selector(recordAudio:)];
    _remove=[self button:@"Remove" symbol:@"trash" action:@selector(removeClip:)];
    NSStackView *libraryHeader=VoiceStack(@[VoiceLabel(@"MESSAGE LIBRARY",10,NSFontWeightBold),VoiceSpacer(),_import,_record],NO,6);
    _table=[[NSTableView alloc] initWithFrame:NSZeroRect]; _table.headerView=nil; _table.rowHeight=52; _table.intercellSpacing=NSMakeSize(0,5);
    _table.backgroundColor=NSColor.clearColor; _table.style=NSTableViewStyleSourceList; _table.dataSource=self; _table.delegate=self;
    NSTableColumn *column=[[NSTableColumn alloc] initWithIdentifier:@"message"]; column.resizingMask=NSTableColumnAutoresizingMask; [_table addTableColumn:column];
    _table.columnAutoresizingStyle=NSTableViewUniformColumnAutoresizingStyle;
    [_table setAccessibilityLabel:@"Recorded voice messages"];
    NSScrollView *scroll=[NSScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints=NO; scroll.documentView=_table; scroll.hasVerticalScroller=YES; scroll.drawsBackground=NO;
    [scroll.heightAnchor constraintEqualToConstant:150].active=YES;
    _empty=VoiceLabel(@"No messages yet. Import audio or record your first CQ.",12,NSFontWeightRegular); _empty.textColor=NSColor.secondaryLabelColor; _empty.lineBreakMode=NSLineBreakByWordWrapping; _empty.maximumNumberOfLines=2;
    NSButton *folder=[self button:@"Show files" symbol:@"folder" action:@selector(showFiles:)];
    NSStackView *library=VoiceStack(@[libraryHeader,scroll,_empty,VoiceStack(@[folder,VoiceSpacer(),_remove],NO,6)],YES,8);
    [scroll.widthAnchor constraintEqualToAnchor:library.widthAnchor].active=YES;
    [libraryHeader.widthAnchor constraintEqualToAnchor:library.widthAnchor].active=YES;
    NSBox *libraryCard=VoiceCard(library);

    _messageTitle=[[NSTextField alloc] initWithFrame:NSZeroRect]; _messageTitle.placeholderString=@"Select a message"; _messageTitle.font=[NSFont systemFontOfSize:18 weight:NSFontWeightSemibold];
    _messageTitle.translatesAutoresizingMaskIntoConstraints=NO; _messageTitle.delegate=self;
    _role=[NSSegmentedControl segmentedControlWithLabels:@[@"CQ",@"Reply"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(saveClip:)]; _role.selectedSegment=0;
    _save=[self button:@"Save" symbol:@"checkmark" action:@selector(saveClip:)];
    NSStackView *nameRow=VoiceStack(@[_messageTitle,_role,_save],NO,8);
    [_messageTitle setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _subtitle=VoiceLabel(@"WAV • local recordings • up to 60 seconds",11,NSFontWeightRegular); _subtitle.textColor=NSColor.secondaryLabelColor;
    _wave=[TXVoiceWaveform new]; [_wave.heightAnchor constraintEqualToConstant:92].active=YES;
    _preview=[self button:@"Preview" symbol:@"headphones" action:@selector(preview:)];
    _phase=VoiceLabel(@"READY",11,NSFontWeightBold); _phase.textColor=VoiceAccent();
    NSStackView *editor=VoiceStack(@[nameRow,_subtitle,_wave,VoiceStack(@[_phase,VoiceSpacer(),_preview],NO,8)],YES,10);
    [nameRow.widthAnchor constraintEqualToAnchor:editor.widthAnchor].active=YES; [_wave.widthAnchor constraintEqualToAnchor:editor.widthAnchor].active=YES;
    NSBox *editorCard=VoiceCard(editor);
    NSStackView *workspace=VoiceStack(@[libraryCard,editorCard],NO,12); workspace.alignment=NSLayoutAttributeTop;
    _workspaceStack=workspace;
    _wideWorkspaceConstraints=@[[libraryCard.widthAnchor constraintEqualToAnchor:workspace.widthAnchor multiplier:0.43 constant:-6],[editorCard.widthAnchor constraintEqualToAnchor:workspace.widthAnchor multiplier:0.57 constant:-6]];
    _narrowWorkspaceConstraints=@[[libraryCard.widthAnchor constraintEqualToAnchor:workspace.widthAnchor],[editorCard.widthAnchor constraintEqualToAnchor:workspace.widthAnchor]];
    _compactLayout=YES; workspace.orientation=NSUserInterfaceLayoutOrientationVertical; workspace.alignment=NSLayoutAttributeLeading;
    [NSLayoutConstraint activateConstraints:_narrowWorkspaceConstraints];

    _send=[self button:@"Send once" symbol:@"play.fill" action:@selector(sendOnce:)]; _send.contentTintColor=VoiceAccent();
    _repeat=[self button:@"Start Auto-CQ" symbol:@"repeat" action:@selector(startRepeat:)]; _repeat.contentTintColor=VoiceAccent();
    _stop=[self button:@"Stop · Esc" symbol:@"stop.fill" action:@selector(stopAll:)]; _stop.contentTintColor=NSColor.systemRedColor;
    _talk=[[TXVoiceTalkButton alloc] initWithFrame:NSZeroRect]; _talk.title=@"Hold to talk · Space"; _talk.bezelStyle=NSBezelStyleRounded; _talk.font=[NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
    _talk.translatesAutoresizingMaskIntoConstraints=NO; [_talk.heightAnchor constraintEqualToConstant:32].active=YES;
    _talk.toolTip=@"Hold the button or Space to speak through the selected microphone. Auto-CQ stays off after release.";
    __weak typeof(self) weakSelf=self; _talk.pressChanged=^(BOOL down) { [weakSelf talk:down]; };
    _countdown=VoiceLabel(@"—",25,NSFontWeightMedium); _countdown.font=[NSFont monospacedDigitSystemFontOfSize:25 weight:NSFontWeightMedium];
    _sessionCount=VoiceLabel(@"0 calls sent",11,NSFontWeightRegular); _sessionCount.textColor=NSColor.secondaryLabelColor;
    _status=VoiceLabel(@"Choose a message. Preview locally or connect your radio.",12,NSFontWeightMedium); _status.lineBreakMode=NSLineBreakByWordWrapping; _status.maximumNumberOfLines=3;
    _progress=[NSProgressIndicator new]; _progress.indeterminate=NO; _progress.minValue=0; _progress.maxValue=1; _progress.style=NSProgressIndicatorStyleBar; _progress.translatesAutoresizingMaskIntoConstraints=NO;
    NSStackView *transportRow=VoiceStack(@[VoiceStack(@[_send,_repeat],NO,8),VoiceStack(@[_talk,_stop],NO,8)],NO,12);
    _transportStack=transportRow; transportRow.orientation=NSUserInterfaceLayoutOrientationVertical; transportRow.alignment=NSLayoutAttributeLeading;
    NSStackView *statusRow=VoiceStack(@[_status,VoiceSpacer(),_sessionCount,_countdown],NO,12); [_status setContentCompressionResistancePriority:400 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *transport=VoiceStack(@[transportRow,_progress,statusRow],YES,10);
    for(NSView *v in @[transportRow,_progress,statusRow]) [v.widthAnchor constraintEqualToAnchor:transport.widthAnchor].active=YES;
    NSBox *transportCard=VoiceCard(transport);

    _frequency=[NSTextField textFieldWithString:@"14.200000"]; _frequency.translatesAutoresizingMaskIntoConstraints=NO; [_frequency.widthAnchor constraintEqualToConstant:115].active=YES;
    _frequency.font=[NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightMedium]; [_frequency setAccessibilityLabel:@"Frequency in MHz"];
    _mode=[self menu]; [_mode addItemsWithTitles:@[@"USB",@"LSB",@"AM",@"FM"]];
    _connect=[self button:@"Read radio" symbol:@"antenna.radiowaves.left.and.right" action:@selector(connect:)];
    _apply=[self button:@"Apply frequency" symbol:@"arrow.right" action:@selector(applyFrequency:)];
    NSButton *refresh=[self button:@"Refresh devices" symbol:@"arrow.clockwise" action:@selector(refresh:)];
    _radioOutput=[self menu]; _microphone=[self menu]; _headphones=[self menu]; _radioInput=[self menu];
    [_radioOutput setAccessibilityLabel:@"Radio transmit output"]; [_microphone setAccessibilityLabel:@"Operator microphone"]; [_headphones setAccessibilityLabel:@"Headphones for preview and receive"]; [_radioInput setAccessibilityLabel:@"Radio receive input"];
    _listen=[self button:@"Listen" symbol:@"ear" action:@selector(listen:)];
    NSGridView *outputRoutes=[NSGridView gridViewWithViews:@[@[VoiceLabel(@"Radio output",11,NSFontWeightMedium),_radioOutput],@[VoiceLabel(@"Headphones",11,NSFontWeightMedium),_headphones]]];
    NSGridView *inputRoutes=[NSGridView gridViewWithViews:@[@[VoiceLabel(@"Your microphone",11,NSFontWeightMedium),_microphone],@[VoiceLabel(@"Radio input",11,NSFontWeightMedium),_radioInput]]];
    for(NSGridView *grid in @[outputRoutes,inputRoutes]) { grid.translatesAutoresizingMaskIntoConstraints=NO; grid.columnSpacing=10; grid.rowSpacing=8; }
    NSStackView *routes=VoiceStack(@[outputRoutes,inputRoutes],YES,10); _routesStack=routes;
    _line=[NSButton checkboxWithTitle:@"Radio AUDIO IN is ONLY LINE; VOX is off" target:self action:@selector(settingsChanged:)];
    _line.font=[NSFont systemFontOfSize:11]; _line.toolTip=@"Choose ONLY LINE in the radio's AUDIO IN menu. Live replies use the computer microphone selected above.";
    NSStackView *radioHeader=VoiceStack(@[VoiceLabel(@"RADIO & AUDIO",10,NSFontWeightBold),VoiceSpacer(),refresh,_listen],NO,8);
    NSStackView *frequencyRow=VoiceStack(@[VoiceStack(@[VoiceLabel(@"Frequency",11,NSFontWeightMedium),_frequency,VoiceLabel(@"MHz",11,NSFontWeightRegular),_mode],NO,8),VoiceStack(@[_connect,_apply],NO,8)],NO,8);
    _frequencyStack=frequencyRow; frequencyRow.orientation=NSUserInterfaceLayoutOrientationVertical; frequencyRow.alignment=NSLayoutAttributeLeading;
    _gain=[self slider:0.7 min:0.05 max:1]; _levelLabel=VoiceLabel(@"TX level 70%",11,NSFontWeightMedium);
    NSStackView *levelRow=VoiceStack(@[_line,VoiceStack(@[_levelLabel,_gain],NO,8)],YES,8); _levelStack=levelRow; [_gain.widthAnchor constraintEqualToConstant:110].active=YES;
    NSStackView *radio=VoiceStack(@[radioHeader,frequencyRow,routes,levelRow],YES,10);
    for(NSView *v in @[radioHeader,routes,levelRow]) [v.widthAnchor constraintEqualToAnchor:radio.widthAnchor].active=YES;
    NSBox *radioCard=VoiceCard(radio);

    _interval=[self slider:7 min:3 max:30]; _variation=[self slider:0 min:0 max:2]; _lead=[self slider:0.2 min:0.1 max:1]; _tail=[self slider:0.2 min:0.1 max:1];
    _limit=[NSStepper new]; _limit.minValue=1; _limit.maxValue=100; _limit.integerValue=20; _limit.target=self; _limit.action=@selector(settingsChanged:);
    _limitLabel=VoiceLabel(@"20 calls",11,NSFontWeightMedium);
    NSGridView *timingGrid=[NSGridView gridViewWithViews:@[@[VoiceLabel(@"Listen between calls",11,NSFontWeightMedium),_interval,VoiceLabel(@"Natural variation",11,NSFontWeightMedium),_variation],@[VoiceLabel(@"Before audio",11,NSFontWeightMedium),_lead,VoiceLabel(@"After audio",11,NSFontWeightMedium),_tail]]];
    timingGrid.translatesAutoresizingMaskIntoConstraints=NO; timingGrid.columnSpacing=12; timingGrid.rowSpacing=6;
    _timingLabel=VoiceLabel(@"7.0 s listen  ·  ±0.0 s variation  ·  200 / 200 ms audio guards",11,NSFontWeightRegular); _timingLabel.textColor=NSColor.secondaryLabelColor;
    NSStackView *timingHeader=VoiceStack(@[VoiceLabel(@"CQ RHYTHM",10,NSFontWeightBold),VoiceSpacer(),VoiceLabel(@"Stop after",11,NSFontWeightRegular),_limitLabel,_limit],NO,8);
    NSStackView *timing=VoiceStack(@[timingHeader,timingGrid,_timingLabel],YES,8);
    [timingHeader.widthAnchor constraintEqualToAnchor:timing.widthAnchor].active=YES; [timingGrid.widthAnchor constraintEqualToAnchor:timing.widthAnchor].active=YES;
    NSBox *timingCard=VoiceCard(timing);
    NSTextField *footnote=VoiceLabel(@"Listen for replies and press Esc to stop. Hold Space to reply through your selected computer microphone. Auto-CQ stays off until you restart it.",11,NSFontWeightRegular);
    footnote.textColor=NSColor.secondaryLabelColor; footnote.maximumNumberOfLines=2; footnote.lineBreakMode=NSLineBreakByWordWrapping;
    [footnote setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *content=VoiceStack(@[header,transportCard,workspace,radioCard,timingCard,footnote],YES,12);
    [self.view addSubview:content];
    [NSLayoutConstraint activateConstraints:@[[content.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],[content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],[content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-8]]];
    for(NSView *v in @[header,workspace,transportCard,radioCard,timingCard,footnote]) [v.widthAnchor constraintEqualToAnchor:content.widthAnchor].active=YES;
    _configurationControls=@[_frequency,_mode,_radioOutput,_microphone,_headphones,_radioInput,_gain,_interval,_variation,_lead,_tail,_limit,_line,_connect,_apply,refresh];
    [self loadSettings];
}
- (void)adaptWidth:(CGFloat)width {
    if(width<=0) return;
    BOOL compact=width<800;
    if(compact!=_compactLayout) {
        _compactLayout=compact;
        [NSLayoutConstraint deactivateConstraints:compact ? _wideWorkspaceConstraints : _narrowWorkspaceConstraints];
        _workspaceStack.orientation=compact ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
        _workspaceStack.alignment=compact ? NSLayoutAttributeLeading : NSLayoutAttributeTop;
        [NSLayoutConstraint activateConstraints:compact ? _narrowWorkspaceConstraints : _wideWorkspaceConstraints];
    }
    BOOL narrow=width<650;
    _routesStack.orientation=compact ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
    _routesStack.alignment=compact ? NSLayoutAttributeLeading : NSLayoutAttributeTop;
    _levelStack.orientation=narrow ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
    _levelStack.alignment=narrow ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    _frequencyStack.orientation=narrow ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
    _frequencyStack.alignment=narrow ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
    _transportStack.orientation=narrow ? NSUserInterfaceLayoutOrientationVertical : NSUserInterfaceLayoutOrientationHorizontal;
    _transportStack.alignment=narrow ? NSLayoutAttributeLeading : NSLayoutAttributeCenterY;
}
- (TX500VoiceClip *)selectedClip {
    NSInteger row=_table.selectedRow; NSArray *clips=_library.clips;
    return row>=0 && row<(NSInteger)clips.count ? clips[row] : nil;
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { (void)tableView; return _library.clips.count; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    (void)tableView; (void)column; TX500VoiceClip *clip=_library.clips[row];
    NSTextField *name=VoiceLabel(clip.title,13,NSFontWeightSemibold); name.lineBreakMode=NSLineBreakByTruncatingTail;
    NSTextField *meta=VoiceLabel([NSString stringWithFormat:@"%@    •    %.1f s    •    WAV",clip.role,clip.duration],10,NSFontWeightMedium); meta.textColor=VoiceAccent();
    NSStackView *stack=VoiceStack(@[name,meta],YES,3);
    NSTableCellView *cell=[NSTableCellView new]; [cell addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:8],[stack.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-8],[stack.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]]]; return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification { (void)notification; [self stopPreview]; [self showSelection]; }
- (void)showSelection {
    TX500VoiceClip *clip=[self selectedClip]; _messageTitle.stringValue=clip.title ?: @""; _role.selectedSegment=[clip.role isEqual:@"Reply"] ? 1 : 0;
    _wave.peaks=clip.peaks ?: @[]; _wave.progress=0; _wave.needsDisplay=YES;
    _subtitle.stringValue=clip ? [NSString stringWithFormat:@"%@ message  •  %.1f seconds  •  mono WAV",clip.role,clip.duration] : @"Import or record your first message to get started";
    [self updateUI];
}
- (void)reloadLibrary:(TX500VoiceClip *)select {
    [_table reloadData]; _empty.hidden=_library.clips.count>0;
    NSInteger index=select ? [_library.clips indexOfObject:select] : (_library.clips.count ? 0 : -1);
    if(index>=0 && index!=NSNotFound) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:index] byExtendingSelection:NO];
    [self showSelection];
}
- (void)message:(NSString *)message { _status.stringValue=message; if(self.logHandler) self.logHandler([@"[Voice Keyer] " stringByAppendingString:message]); }
- (void)error:(NSError *)error { [self message:error.localizedDescription ?: @"The operation could not be completed."]; }
- (void)importAudio:(id)sender {
    (void)sender; NSOpenPanel *panel=[NSOpenPanel openPanel]; panel.allowedContentTypes=@[UTTypeAudio]; panel.allowsMultipleSelection=NO;
    NSUInteger token=_uiGeneration;
    [panel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
        if(result==NSModalResponseOK && token==self->_uiGeneration && self->_visible) [self importURL:panel.URL title:panel.URL.lastPathComponent.stringByDeletingPathExtension role:@"CQ" removeSource:NO];
    }];
}
- (void)importURL:(NSURL *)URL title:(NSString *)title role:(NSString *)role removeSource:(BOOL)remove {
    if(_importing) return; _importing=YES; [self message:@"Preparing waveform and saving your message…"]; [self updateUI];
    NSURL *directory=_library.directory;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        // Build a separate library snapshot off the UI thread. Main-thread
        // controls remain disabled until the atomic manifest commit completes.
        TX500VoiceLibrary *updated=[[TX500VoiceLibrary alloc] initWithDirectory:directory];
        NSError *error=nil; TX500VoiceClip *clip=[updated importURL:URL title:title role:role error:&error];
        if(remove) [NSFileManager.defaultManager removeItemAtURL:URL error:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_importing=NO;
            if(clip) { self->_library=updated; [self reloadLibrary:clip]; [self message:@"Message saved locally. Preview it before transmitting."]; }
            else [self error:error];
            [self updateUI];
        });
    });
}
- (void)saveClip:(id)sender {
    (void)sender; TX500VoiceClip *clip=[self selectedClip]; if(!clip || self.keyer.active) return;
    NSError *error=nil;
    if([_library renameClip:clip title:_messageTitle.stringValue role:_role.selectedSegment==0 ? @"CQ" : @"Reply" error:&error]) { [_table reloadData]; [self showSelection]; }
    else [self error:error];
}
- (void)controlTextDidEndEditing:(NSNotification *)note { if(note.object==_messageTitle) [self saveClip:nil]; }
- (void)removeClip:(id)sender {
    (void)sender; TX500VoiceClip *clip=[self selectedClip]; if(!clip) return; [self stopPreview]; NSError *e=nil;
    if([_library removeClip:clip error:&e]) { [self reloadLibrary:nil]; [self message:@"Message removed. Its audio remains in the Removed folder."]; } else [self error:e];
}
- (void)showFiles:(id)sender { (void)sender; [NSFileManager.defaultManager createDirectoryAtURL:_library.directory withIntermediateDirectories:YES attributes:nil error:nil]; [NSWorkspace.sharedWorkspace openURL:_library.directory]; }
- (NSString *)uid:(NSPopUpButton *)menu { return menu.selectedItem.representedObject ?: @""; }
- (void)fill:(NSPopUpButton *)menu devices:(NSArray *)devices saved:(NSString *)saved placeholder:(NSString *)placeholder {
    [menu removeAllItems]; [menu addItemWithTitle:placeholder]; menu.lastItem.representedObject=@"";
    for(NSDictionary *device in devices) { [menu addItemWithTitle:device[@"name"]]; menu.lastItem.representedObject=device[@"uid"]; if([device[@"uid"] isEqual:saved]) [menu selectItem:menu.lastItem]; }
}
- (void)refreshDevices {
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    NSArray *inputs=TXVoiceDevices(YES),*outputs=TXVoiceDevices(NO);
    [self fill:_radioOutput devices:outputs saved:[self uid:_radioOutput].length ? [self uid:_radioOutput] : [d stringForKey:@"Voice.output"] placeholder:@"Select radio output…"];
    [self fill:_microphone devices:inputs saved:[self uid:_microphone].length ? [self uid:_microphone] : [d stringForKey:@"Voice.microphone"] placeholder:@"Select microphone…"];
    [self fill:_headphones devices:outputs saved:[self uid:_headphones].length ? [self uid:_headphones] : [d stringForKey:@"Voice.headphones"] placeholder:@"Select headphones…"];
    [self fill:_radioInput devices:inputs saved:[self uid:_radioInput].length ? [self uid:_radioInput] : [d stringForKey:@"Voice.input"] placeholder:@"Select radio input…"];
}
- (void)refresh:(id)sender { (void)sender; [self refreshDevices]; }
- (void)routeChanged:(id)sender {
    [self stopPreview]; [_receiver stop]; _listenWanted=NO;
    if(sender==_radioOutput) _line.state=NSControlStateValueOff;
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    [d setObject:[self uid:_radioOutput] forKey:@"Voice.output"]; [d setObject:[self uid:_microphone] forKey:@"Voice.microphone"];
    [d setObject:[self uid:_headphones] forKey:@"Voice.headphones"]; [d setObject:[self uid:_radioInput] forKey:@"Voice.input"];
    [self settingsChanged:nil];
}
- (void)loadSettings {
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    NSDictionary *settings=@{@"gain":_gain,@"interval":_interval,@"variation":_variation,@"lead":_lead,@"tail":_tail};
    for(NSString *key in settings) { NSNumber *n=[d objectForKey:[@"Voice." stringByAppendingString:key]]; if([n isKindOfClass:NSNumber.class] && isfinite(n.doubleValue)) { NSSlider *s=settings[key]; s.doubleValue=MAX(s.minValue,MIN(s.maxValue,n.doubleValue)); } }
    NSInteger limit=[d integerForKey:@"Voice.limit"]; if(limit>=1 && limit<=100) _limit.integerValue=limit;
    [self settingsChanged:nil];
}
- (void)settingsChanged:(id)sender {
    (void)sender; _levelLabel.stringValue=[NSString stringWithFormat:@"TX level %.0f%%",_gain.doubleValue*100];
    _limitLabel.stringValue=[NSString stringWithFormat:@"%ld calls",(long)_limit.integerValue];
    _timingLabel.stringValue=[NSString stringWithFormat:@"%.1f s listen  ·  ±%.1f s variation  ·  %.0f / %.0f ms audio guards",_interval.doubleValue,_variation.doubleValue,_lead.doubleValue*1000,_tail.doubleValue*1000];
    NSUserDefaults *d=NSUserDefaults.standardUserDefaults;
    NSDictionary *settings=@{@"gain":_gain,@"interval":_interval,@"variation":_variation,@"lead":_lead,@"tail":_tail};
    for(NSString *key in settings) [d setDouble:[settings[key] doubleValue] forKey:[@"Voice." stringByAppendingString:key]];
    [d setInteger:_limit.integerValue forKey:@"Voice.limit"];
    [self configureKeyer];
}
- (void)configureKeyer {
    if(self.keyer.active) return;
    self.keyer.outputUID=[self uid:_radioOutput]; self.keyer.microphoneUID=[self uid:_microphone]; self.keyer.gain=_gain.floatValue;
    self.keyer.listenSeconds=_interval.doubleValue; self.keyer.variationSeconds=_variation.doubleValue; self.keyer.leadSeconds=_lead.doubleValue; self.keyer.tailSeconds=_tail.doubleValue;
    self.keyer.maximumCalls=_limit.integerValue; self.keyer.lineInputConfirmed=_line.state==NSControlStateValueOn;
}
- (void)connect:(id)sender { (void)sender; [self connectApply:NO]; }
- (void)applyFrequency:(id)sender { (void)sender; [self connectApply:YES]; }
- (void)connectApply:(BOOL)apply {
    NSString *port=self.selectedPortProvider ? self.selectedPortProvider() : nil;
    if(!port.length) { [self message:@"Select the radio CAT port in the app toolbar."]; return; }
    if(self.keyer.active) return;
    double mhz=0; NSScanner *scanner=[NSScanner scannerWithString:_frequency.stringValue]; scanner.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    if(apply && (![scanner scanDouble:&mhz] || !scanner.isAtEnd || !isfinite(mhz) || mhz<0.5 || mhz>56)) { [self message:@"Enter a frequency in MHz between 0.5 and 56."]; return; }
    if(!self.keyer || ![_connectedPort isEqual:port]) {
        if(self.keyer && ![self.keyer disconnectAndWait]) return;
        self.keyer=[[TX500VoiceKeyer alloc] initWithRadio:(self.radioProvider ? self.radioProvider(port) : [[TX500VoiceCATRadio alloc] initWithPort:port]) player:[TX500VoicePlayer new]]; _connectedPort=port;
        __weak typeof(self) weakSelf=self;
        self.keyer.changed=^{ [weakSelf keyerChanged]; };
        self.keyer.log=^(NSString *message) { if(weakSelf.logHandler) weakSelf.logHandler([@"[Voice Keyer] " stringByAppendingString:message]); };
    }
    [self configureKeyer]; NSInteger modes[]={2,1,5,4};
    [self.keyer connectFrequency:(uint64_t)llround(mhz*1e6) mode:modes[MAX(0,_mode.indexOfSelectedItem)] apply:apply];
}
- (void)keyerChanged {
    if(self.stateChanged) self.stateChanged();
    _status.stringValue=self.keyer.status;
    if(self.keyer.connected && self.keyer.state==TXVoiceIdle && self.keyer.radioState.count) {
        _frequency.stringValue=[NSString stringWithFormat:@"%.6f",[self.keyer.radioState[@"frequency"] doubleValue]/1e6];
        NSInteger mode=[self.keyer.radioState[@"mode"] integerValue]; [_mode selectItemAtIndex:mode==1 ? 1 : mode==5 ? 2 : mode==4 ? 3 : 0];
    }
    BOOL receiving=self.keyer.state==TXVoiceListening || self.keyer.state==TXVoiceIdle;
    if(!receiving) [_receiver stop];
    else if(_listenWanted && !_receiver.running) [self startReceiver];
    [self updateUI];
}
- (void)sendOnce:(id)sender { (void)sender; [self transmitRepeat:NO]; }
- (void)startRepeat:(id)sender { (void)sender; [self transmitRepeat:YES]; }
- (BOOL)radioSettingsMatchUI {
    double mhz=0; NSScanner *scan=[NSScanner scannerWithString:_frequency.stringValue]; scan.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSInteger modes[]={2,1,5,4};
    return [scan scanDouble:&mhz] && scan.isAtEnd && isfinite(mhz) && mhz>=0.5 && mhz<=56 &&
        (uint64_t)llround(mhz*1e6)==[self.keyer.radioState[@"frequency"] unsignedLongLongValue] &&
        modes[MAX(0,_mode.indexOfSelectedItem)]==[self.keyer.radioState[@"mode"] integerValue];
}
- (void)transmitRepeat:(BOOL)repeat {
    if(!self.keyer) { [self message:@"Read and verify your radio first."]; return; }
    if(!self.selectedPortProvider || ![self.selectedPortProvider() isEqual:_connectedPort]) { [self message:@"The CAT port changed. Read and verify the radio again."]; return; }
    if(![self radioSettingsMatchUI]) { [self message:@"Apply the edited frequency/mode, or Read radio, before transmitting."]; return; }
    [self stopPreview]; [_receiver stop]; [self configureKeyer]; [self.keyer startClip:[self selectedClip] repeat:repeat];
}
- (void)permission:(void (^)(void))completion {
    AVAuthorizationStatus authorization=[AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio];
    if(authorization==AVAuthorizationStatusAuthorized) { completion(); return; }
    if(_requestingPermission) return;
    if(authorization==AVAuthorizationStatusNotDetermined) {
        _requestingPermission=YES; NSUInteger token=_uiGeneration;
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio completionHandler:^(BOOL granted) { dispatch_async(dispatch_get_main_queue(), ^{
            self->_requestingPermission=NO;
            if(token!=self->_uiGeneration || !self->_visible) return;
            if(granted) completion(); else [self message:@"Allow Microphone access in System Settings → Privacy & Security to record or speak."];
        }); }];
    } else [self message:@"Allow Microphone access in System Settings → Privacy & Security to record or speak."];
}
- (void)recordAudio:(id)sender {
    (void)sender;
    if(_recording) { [self finishRecording:YES]; return; }
    [self stopPreview]; [_receiver stop]; _listenWanted=NO;
    [self permission:^{
        if(self.keyer.active) return;
        NSError *e=nil; NSString *uid=[self uid:self->_microphone];
        if([self->_capture startInput:uid output:nil record:YES error:&e]) {
            self->_recordInputUID=uid; self->_recording=YES; [self message:@"RECORDING • speak your message, then press Finish recording"]; [self updateUI];
        } else [self error:e];
    }];
}
- (void)finishRecording:(BOOL)save {
    if(!_recording) return; _recording=NO; [_capture stop];
    if(save) {
        NSURL *temp=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".wav"]]];
        NSError *e=nil;
        if([_capture writeRecording:temp error:&e]) [self importURL:temp title:[NSString stringWithFormat:@"%@ %lu",_role.selectedSegment==0 ? @"CQ" : @"Reply",(unsigned long)_library.clips.count+1] role:_role.selectedSegment==0 ? @"CQ" : @"Reply" removeSource:YES];
        else { [NSFileManager.defaultManager removeItemAtURL:temp error:nil]; [self error:e]; }
    }
    [self updateUI];
}
- (void)preview:(id)sender {
    (void)sender; if(_previewing) { [self stopPreview]; return; }
    TX500VoiceClip *clip=[self selectedClip]; if(!clip) return;
    NSString *output=[self uid:_headphones];
    if(!output.length || [output isEqual:[self uid:_radioOutput]]) { [self message:@"Choose a headphone output separate from the radio transmit output."]; return; }
    NSError *error=nil; _previewPlayer.volume=0.7;
    if(![_previewPlayer prepareURL:clip.URL device:output error:&error]) { [self error:error]; return; }
    __weak typeof(self) weakSelf=self;
    NSUInteger token=++_previewGeneration;
    _previewPlayer.completion=^(BOOL success) { dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self=weakSelf; if(!self || token!=self->_previewGeneration) return;
        [self stopPreview]; [self message:success ? @"Preview finished • no PTT commands were sent" : @"Preview interrupted. Check the headphones."];
    }); };
    _previewing=[_previewPlayer play];
    [self message:_previewing ? @"LOCAL PREVIEW • headphones only" : @"The preview output did not start."]; [self updateUI];
}
- (void)stopPreview { _previewGeneration++; _previewing=NO; _previewPlayer.completion=nil; [_previewPlayer stop]; _wave.progress=0; _wave.needsDisplay=YES; }
- (void)listen:(id)sender {
    (void)sender;
    if(_listenWanted) { _listenWanted=NO; [_receiver stop]; [self updateUI]; return; }
    [self permission:^{ self->_listenWanted=YES; [self startReceiver]; [self updateUI]; }];
}
- (void)startReceiver {
    NSString *input=[self uid:_radioInput],*output=[self uid:_headphones];
    if(!input.length || !output.length || [output isEqual:[self uid:_radioOutput]] || [input isEqual:output]) {
        _listenWanted=NO; [self message:@"Select radio input and a separate headphone output for receiving."]; return;
    }
    NSError *e=nil; _receiver.gain=0.7;
    if(![_receiver startInput:input output:output record:NO error:&e]) { _listenWanted=NO; [self error:e]; }
    else { _rxInputUID=input; _rxOutputUID=output; }
}
- (void)talk:(BOOL)down {
    if(!down) {
        _talkHeld=NO; _talkReady=NO;
        if(self.keyer.active) [self.keyer stop]; return;
    }
    if(_talkHeld || _recording || _importing) return;
    if(!self.keyer.connected || !self.selectedPortProvider || ![self.selectedPortProvider() isEqual:_connectedPort]) { [self message:@"Read and verify the radio before using the live microphone."]; return; }
    if(![self radioSettingsMatchUI]) { [self message:@"Apply the edited frequency/mode, or Read radio, before transmitting."]; return; }
    _talkHeld=YES; [self stopPreview]; [_receiver stop];
    if(self.keyer.active) [self.keyer stop];
    [self permission:^{ if(self->_talkHeld) { self->_talkReady=YES; [self updateUI]; } }];
}
- (void)stopAll:(id)sender {
    (void)sender; _talkHeld=NO; _talkReady=NO; _uiGeneration++;
    [self stopPreview]; [self finishRecording:YES];
    if(self.keyer.active || self.keyer.state==TXVoiceFault) [self.keyer stop];
    else [self message:@"Stopped • auto-CQ is off"];
    [self updateUI];
}
- (NSEvent *)handleKey:(NSEvent *)event {
    if(!_visible || self.view.hidden || !self.view.window.isKeyWindow || self.view.window.attachedSheet) return event;
    if(event.type==NSEventTypeKeyDown && event.keyCode==53) { [self stopAll:nil]; return nil; }
    if(event.keyCode!=49 || (event.modifierFlags & (NSEventModifierFlagCommand|NSEventModifierFlagOption|NSEventModifierFlagControl))) return event;
    if(event.type==NSEventTypeKeyUp && _talkHeld) { [self talk:NO]; return nil; }
    if([self.view.window.firstResponder isKindOfClass:NSTextView.class]) return event;
    if(event.type==NSEventTypeKeyDown && !event.isARepeat) { [self talk:YES]; return nil; }
    return event;
}
- (void)lostFocus:(NSNotification *)note { (void)note; if(_talkHeld) [self talk:NO]; }
- (void)willSleep:(NSNotification *)note { (void)note; if(_visible) { [self stopAll:nil]; _listenWanted=NO; [_receiver stop]; } }
- (void)activate {
    NSDictionary *p=[NSUserDefaults.standardUserDefaults dictionaryForKey:@"TX500_ActiveStationProfile"];
    NSDictionary *mapping=@{@"radioOutput":@"Voice.output",@"radioInput":@"Voice.input",@"microphone":@"Voice.microphone",@"headphones":@"Voice.headphones"};
    for(NSString *k in mapping) if([p[k] length]) [NSUserDefaults.standardUserDefaults setObject:p[k] forKey:mapping[k]];
    [_radioOutput selectItemAtIndex:0]; [_radioInput selectItemAtIndex:0]; [_microphone selectItemAtIndex:0]; [_headphones selectItemAtIndex:0];
    _visible=YES; [self refreshDevices]; [self updateUI]; }
- (BOOL)deactivate {
    _visible=NO; _uiGeneration++; _talkHeld=NO; _talkReady=NO; _listenWanted=NO;
    [self stopPreview]; [self finishRecording:YES]; [_receiver stop];
    BOOL released=!self.keyer || [self.keyer disconnectAndWait];
    _line.state=NSControlStateValueOff;
    if(!released) _visible=YES;
    return released;
}
- (void)updateUI {
    if(!_view || !_visible) return;
    if(_talkHeld && _talkReady && !self.keyer.active && self.keyer.connected) {
        _talkReady=NO; [self configureKeyer]; [self.keyer startTalking];
    }
    if(_recording) {
        if(!TXVoiceDeviceAvailable(_recordInputUID,YES) || _capture.overflowed) { [self finishRecording:YES]; [self message:@"Recording stopped because the input disconnected."]; }
        else if(_capture.duration>=60) [self finishRecording:YES];
    }
    if(_receiver.running && (!TXVoiceDeviceAvailable(_rxInputUID,YES) || !TXVoiceDeviceAvailable(_rxOutputUID,NO) || _receiver.overflowed)) {
        _listenWanted=NO; [_receiver stop]; [self message:@"Receive audio disconnected. Select the audio devices again."];
        if(self.keyer.active) [self.keyer stop];
    }
    if(_previewing && !TXVoiceDeviceAvailable([self uid:_headphones],NO)) { [self stopPreview]; [self message:@"Headphone output disconnected."]; }
    BOOL active=self.keyer.active, busy=active || _recording || _importing;
    BOOL clip=[self selectedClip]!=nil;
    for(NSControl *control in _configurationControls) control.enabled=!busy;
    _send.enabled=clip && !busy; _repeat.enabled=clip && !busy && [[self selectedClip].role isEqual:@"CQ"];
    _talk.enabled=!_recording && !_importing && self.keyer.connected;
    _stop.enabled=busy || _previewing || _talkHeld || self.keyer.state==TXVoiceFault;
    _preview.enabled=clip && !busy; _preview.title=_previewing ? @"Stop preview" : @"Preview";
    _record.enabled=!active && !_importing; _record.title=_recording ? @"Finish recording" : @"Record";
    _record.contentTintColor=_recording ? NSColor.systemRedColor : nil;
    _import.enabled=!busy; _remove.enabled=clip && !busy; _save.enabled=clip && !busy;
    _messageTitle.enabled=clip && !busy; _role.enabled=clip && !busy; _table.enabled=!busy;
    _listen.enabled=!_recording && !_importing && (!active || self.keyer.state==TXVoiceListening); _listen.title=_listenWanted ? @"Listening" : @"Listen";
    _wave.recording=_recording || self.keyer.state==TXVoiceLive; _wave.level=_recording ? _capture.level : self.keyer.microphoneLevel;
    _wave.progress=_previewing ? _previewPlayer.currentTime/MAX(0.1,_previewPlayer.duration) : self.keyer.state==TXVoicePlaying ? self.keyer.progress : 0;
    _wave.needsDisplay=YES;
    NSArray *states=@[@"READY",@"VERIFYING",@"TX READY",@"ON AIR",@"FINISHING",@"RETURNING TO RX",@"LISTENING",@"LIVE MICROPHONE",@"STOPPING",@"ATTENTION"];
    _phase.stringValue=_recording ? @"RECORDING" : _previewing ? @"LOCAL PREVIEW" : states[self.keyer ? self.keyer.state : 0];
    _phase.textColor=(_recording || self.keyer.state==TXVoicePlaying || self.keyer.state==TXVoiceLive) ? NSColor.systemOrangeColor : VoiceAccent();
    _countdown.stringValue=_recording ? [NSString stringWithFormat:@"%.1fs",_capture.duration] : active && self.keyer.remaining>0 ? [NSString stringWithFormat:@"%.1fs",self.keyer.remaining] : @"—";
    _sessionCount.stringValue=[NSString stringWithFormat:@"%ld calls sent",(long)self.keyer.completedCalls];
    _progress.doubleValue=self.keyer.progress;
}
- (void)dealloc {
    [_uiTimer invalidate]; if(_keyMonitor) [NSEvent removeMonitor:_keyMonitor];
    [NSNotificationCenter.defaultCenter removeObserver:self]; [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [_capture stop]; [_receiver stop]; [_previewPlayer stop];
}
@end
