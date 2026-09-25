#import "TX500StationController.h"
#import "TX500PSKReporter.h"
static NSTextField *Label(NSString *s,CGFloat size,NSFontWeight weight) { NSTextField *v=[NSTextField labelWithString:s]; v.font=[NSFont systemFontOfSize:size weight:weight]; v.translatesAutoresizingMaskIntoConstraints=NO; [v setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal]; return v; }
static NSStackView *Stack(NSArray *a,BOOL vertical,CGFloat gap) { NSStackView *s=[NSStackView stackViewWithViews:a]; s.orientation=vertical?NSUserInterfaceLayoutOrientationVertical:NSUserInterfaceLayoutOrientationHorizontal; s.alignment=vertical?NSLayoutAttributeLeading:NSLayoutAttributeCenterY; s.spacing=gap; s.translatesAutoresizingMaskIntoConstraints=NO; return s; }
static NSView *Spacer(void) { NSView *s=[NSView new]; s.translatesAutoresizingMaskIntoConstraints=NO; [s setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal]; return s; }
static NSBox *Card(NSView *content) { NSBox *b=[NSBox new]; b.boxType=NSBoxCustom; b.titlePosition=NSNoTitle; b.cornerRadius=12; b.fillColor=NSColor.controlBackgroundColor; b.borderColor=NSColor.separatorColor; b.borderWidth=1; b.translatesAutoresizingMaskIntoConstraints=NO; [b.contentView addSubview:content]; [NSLayoutConstraint activateConstraints:@[[content.leadingAnchor constraintEqualToAnchor:b.contentView.leadingAnchor constant:14],[content.trailingAnchor constraintEqualToAnchor:b.contentView.trailingAnchor constant:-14],[content.topAnchor constraintEqualToAnchor:b.contentView.topAnchor constant:14],[content.bottomAnchor constraintEqualToAnchor:b.contentView.bottomAnchor constant:-14]]]; return b; }
static NSString *Mode(NSInteger m) { return @{@1:@"LSB",@2:@"USB",@3:@"CW",@4:@"FM",@5:@"AM",@6:@"DIG",@7:@"CW-R",@9:@"DIG-L"}[@(m)] ?: @"—"; }
@interface TXStationTableScroll : NSScrollView
@end
@implementation TXStationTableScroll
- (void)layout {
    [super layout];
    NSTableView *table=(NSTableView *)self.documentView;
    CGFloat width=self.contentView.bounds.size.width;
    if(width<=0) return;
    NSDictionary *weights=@{@"favorite":@0.055,@"name":@0.31,@"hz":@0.22,@"mode":@0.13,@"tags":@0.285,@"range":@0.37,@"usage":@0.43,@"bandwidth":@0.20};
    for(NSTableColumn *column in table.tableColumns) {
        CGFloat usable=MAX(1,width-32-table.intercellSpacing.width*table.tableColumns.count);
        CGFloat target=usable*[weights[column.identifier] doubleValue];
        if(fabs(column.width-target)>0.5) column.width=target;
    }
    NSRect frame=table.frame; frame.size.width=width; table.frame=frame;
}
@end
@interface TXStationBandView : NSView
@property(nonatomic,copy) NSArray *segments;
@property(nonatomic) uint64_t low,high,frequency;
@property(nonatomic,copy) void (^picked)(NSDictionary *);
@end
@implementation TXStationBandView
- (BOOL)isFlipped { return YES; }
- (void)drawRect:(NSRect)dirty { (void)dirty; [NSColor.controlBackgroundColor setFill]; NSRectFill(self.bounds); double span=MAX(1,self.high-self.low); CGFloat w=self.bounds.size.width;
    for(NSDictionary *s in self.segments) { CGFloat x=([s[@"low"] doubleValue]-self.low)/span*w, end=([s[@"high"] doubleValue]-self.low)/span*w; NSString *usage=s[@"usage"]; NSColor *c=[usage hasPrefix:@"CW"]?NSColor.systemTealColor:([usage containsString:@"digital"] || [usage containsString:@"Digital"])?NSColor.systemPurpleColor:[usage containsString:@"Beacon"]?NSColor.systemOrangeColor:NSColor.systemBlueColor; [[c colorWithAlphaComponent:0.6] setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x,10,MAX(1,end-x-1),48) xRadius:3 yRadius:3] fill]; }
    if(self.frequency>=self.low && self.frequency<=self.high) { CGFloat x=(self.frequency-self.low)/span*w; [NSColor.labelColor setStroke]; NSBezierPath *p=[NSBezierPath bezierPath]; p.lineWidth=2; [p moveToPoint:NSMakePoint(x,4)]; [p lineToPoint:NSMakePoint(x,65)]; [p stroke]; }
    NSDictionary *attrs=@{NSFontAttributeName:[NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightMedium],NSForegroundColorAttributeName:NSColor.secondaryLabelColor};
    [[NSString stringWithFormat:@"%.3f MHz",self.low/1e6] drawAtPoint:NSMakePoint(0,69) withAttributes:attrs]; NSString *last=[NSString stringWithFormat:@"%.3f MHz",self.high/1e6]; [last drawAtPoint:NSMakePoint(w-[last sizeWithAttributes:attrs].width,69) withAttributes:attrs];
}
- (void)mouseDown:(NSEvent *)event { NSPoint p=[self convertPoint:event.locationInWindow fromView:nil]; uint64_t hz=self.low+(self.high-self.low)*p.x/MAX(1,self.bounds.size.width); for(NSDictionary *s in self.segments) if(hz>=[s[@"low"] unsignedLongLongValue] && hz<[s[@"high"] unsignedLongLongValue]) { if(self.picked) self.picked(s); break; } }
@end
@interface TX500StationController () <NSTableViewDataSource,NSTableViewDelegate,NSTextFieldDelegate,NSSearchFieldDelegate>
@property(nonatomic,strong) NSView *view;
@end
@implementation TX500StationController {
    TX500StationStore *_store; NSStackView *_content,*_paneHost; NSArray<NSView *> *_panes;
    NSSegmentedControl *_tabs; NSTextField *_vfo,*_state,*_message,*_profileBadge,*_planInfo,*_reportStatus,*_health;
    NSTextField *_frequency,*_entryName,*_tags; NSPopUpButton *_mode,*_profileMenu,*_region,*_band;
    NSSearchField *_search; NSButton *_favorite,*_reportEnabled; NSTableView *_table,*_bandTable; TXStationBandView *_bandView;
    NSArray *_filtered,*_segments; NSMutableDictionary *_fields,*_routeMenus,*_shortcutFields; NSString *_editingID,*_frequencyID;
    NSLayoutConstraint *_paneWidth; BOOL _busy; dispatch_queue_t _worker;
}
- (NSButton *)button:(NSString *)title symbol:(NSString *)symbol action:(SEL)action { NSButton *b=[NSButton buttonWithTitle:title target:self action:action]; b.bezelStyle=NSBezelStyleRounded; b.translatesAutoresizingMaskIntoConstraints=NO; if(symbol.length) { b.image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title]; b.imagePosition=NSImageLeft; } return b; }
- (NSTextField *)field:(NSString *)placeholder { NSTextField *f=[NSTextField textFieldWithString:@""]; f.placeholderString=placeholder; f.translatesAutoresizingMaskIntoConstraints=NO; [f.widthAnchor constraintGreaterThanOrEqualToConstant:100].active=YES; return f; }
- (NSPopUpButton *)menu:(NSArray *)items { NSPopUpButton *p=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO]; p.translatesAutoresizingMaskIntoConstraints=NO; [p addItemsWithTitles:items]; [p setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal]; return p; }
- (NSView *)table:(NSTableView * __strong *)result columns:(NSArray *)columns height:(CGFloat)height {
    NSTableView *t=[NSTableView new]; t.delegate=self; t.dataSource=self; t.rowHeight=34; t.style=NSTableViewStyleFullWidth; t.usesAlternatingRowBackgroundColors=YES; t.columnAutoresizingStyle=NSTableViewNoColumnAutoresizing;
    for(NSArray *def in columns) { NSTableColumn *c=[[NSTableColumn alloc] initWithIdentifier:def[0]]; c.title=def[1]; c.width=[def[2] doubleValue]; c.minWidth=25; [t addTableColumn:c]; }
    NSScrollView *s=[TXStationTableScroll new]; s.documentView=t; s.hasVerticalScroller=YES; s.autohidesScrollers=YES; s.translatesAutoresizingMaskIntoConstraints=NO; [s.heightAnchor constraintEqualToConstant:height].active=YES; *result=t; return s;
}
- (instancetype)init { if((self=[super init])) { _store=TX500StationStore.sharedStore; _worker=dispatch_queue_create("ir.factoreal.station.ui",DISPATCH_QUEUE_SERIAL); [self build];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:TXStationStoreChanged object:nil]; [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:TXStationRadioChanged object:nil]; [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(changed:) name:TXPSKReporterChanged object:nil]; [self refresh]; } return self; }
- (void)build {
    self.view=[NSView new]; self.view.translatesAutoresizingMaskIntoConstraints=NO;
    NSTextField *eyebrow=Label(@"STATION  /  CONTROL CENTRE",10,NSFontWeightBold); eyebrow.textColor=NSColor.systemBlueColor;
    _profileBadge=Label(@"",11,NSFontWeightMedium); _profileBadge.textColor=NSColor.secondaryLabelColor;
    NSStackView *header=Stack(@[Stack(@[eyebrow,Spacer(),_profileBadge],NO,10),Label(@"One station. Everything connected.",25,NSFontWeightSemibold)],YES,7);
    [header.arrangedSubviews[0].widthAnchor constraintEqualToAnchor:header.widthAnchor].active=YES;
    _vfo=Label(@"— . ——— ———",34,NSFontWeightMedium); _vfo.font=[NSFont monospacedDigitSystemFontOfSize:34 weight:NSFontWeightMedium];
    _state=Label(@"Read the radio to see its current frequency",11,NSFontWeightRegular); _state.textColor=NSColor.secondaryLabelColor;
    NSButton *read=[self button:@"Read radio" symbol:@"arrow.clockwise" action:@selector(readRadio:)];
    NSButton *stop=[self button:@"Stop all · Esc" symbol:@"stop.fill" action:@selector(stop:)]; stop.contentTintColor=NSColor.systemRedColor;
    NSStackView *vfo=Stack(@[Stack(@[_vfo,Spacer(),read,stop],NO,10),_state],YES,8); [vfo.arrangedSubviews[0].widthAnchor constraintEqualToAnchor:vfo.widthAnchor].active=YES;
    NSStackView *bar=Stack(@[],NO,8);
    NSArray *commands=@[@[@"Voice",@"mic",@"voice"],@[@"CW",@"waveform",@"cw"],@[@"FT8 / FT4",@"dot.radiowaves.left.and.right",@"digital"],@[@"Logbook",@"book",@"logbook"],@[@"Save VFO",@"star",@"favorite"]];
    for(NSArray *c in commands) { NSButton *b=[self button:c[0] symbol:c[1] action:@selector(quick:)]; b.identifier=c[2]; [bar addArrangedSubview:b]; }
    _tabs=[NSSegmentedControl segmentedControlWithLabels:@[@"Frequencies",@"Band Plan",@"Station Profiles",@"Connections & Keys"] trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(tabChanged:)]; _tabs.selectedSegment=0; _tabs.translatesAutoresizingMaskIntoConstraints=NO;
    _paneHost=Stack(@[],YES,0); _panes=@[[self frequenciesPane],[self bandPane],[self profilePane],[self connectionPane]];
    _message=Label(@"Choose a frequency, or read the connected radio. Presets never start transmission.",11,NSFontWeightMedium); _message.maximumNumberOfLines=3; _message.lineBreakMode=NSLineBreakByWordWrapping;
    _content=Stack(@[header,Card(vfo),bar,_tabs,_paneHost,_message],YES,14); [self.view addSubview:_content];
    [NSLayoutConstraint activateConstraints:@[[_content.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:8],[_content.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-8],[_content.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],[_content.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]]];
    for(NSView *v in _content.arrangedSubviews) [v.widthAnchor constraintEqualToAnchor:_content.widthAnchor].active=YES;
    [self tabChanged:nil];
}
- (NSView *)frequenciesPane {
    _search=[NSSearchField new]; _search.placeholderString=@"Search names, frequencies or tags"; _search.delegate=self; _search.translatesAutoresizingMaskIntoConstraints=NO;
    NSView *table=[self table:&_table columns:@[@[@"favorite",@"★",@30],@[@"name",@"Name",@220],@[@"hz",@"MHz",@105],@[@"mode",@"Mode",@65],@[@"tags",@"Tags",@110]] height:225];
    _frequency=[self field:@"MHz"]; _frequency.stringValue=@"14.285000"; _frequency.font=[NSFont monospacedDigitSystemFontOfSize:16 weight:NSFontWeightMedium];
    _mode=[self menu:@[@"LSB",@"USB",@"CW",@"FM",@"AM",@"DIG",@"CW-R",@"DIG-L"]]; [_mode selectItemAtIndex:1];
    _entryName=[self field:@"Frequency name"]; _tags=[self field:@"Tags, e.g. portable, evening"]; _favorite=[NSButton checkboxWithTitle:@"Favorite" target:nil action:nil];
    NSStackView *editor=Stack(@[Stack(@[_entryName,_tags],NO,10),Stack(@[_frequency,Label(@"MHz",11,NSFontWeightRegular),_mode,_favorite,Spacer(),[self button:@"Apply to radio" symbol:@"arrow.right" action:@selector(tune:) ]],NO,8),Stack(@[[self button:@"Save frequency" symbol:@"star" action:@selector(saveFrequency:)],[self button:@"New" symbol:@"plus" action:@selector(newFrequency:)],[self button:@"Remove" symbol:@"trash" action:@selector(removeFrequency:)]],NO,8)],YES,12);
    [_entryName.widthAnchor constraintEqualToAnchor:_tags.widthAnchor].active=YES;
    for(NSView *v in editor.arrangedSubviews) [v.widthAnchor constraintEqualToAnchor:editor.widthAnchor].active=YES;
    NSTextField *note=Label(@"Stored on this Mac • independent of the radio’s 100 memory channels",11,NSFontWeightRegular); note.textColor=NSColor.secondaryLabelColor;
    NSStackView *body=Stack(@[_search,table,editor,note],YES,12); for(NSView *v in body.arrangedSubviews) [v.widthAnchor constraintEqualToAnchor:body.widthAnchor].active=YES; return Card(body);
}
- (NSView *)bandPane {
    _band=[self menu:@[@"160m",@"80m",@"60m",@"40m",@"30m",@"20m",@"17m",@"15m",@"12m",@"10m"]]; [_band selectItemAtIndex:5]; _band.target=self; _band.action=@selector(bandChanged:);
    _bandView=[TXStationBandView new]; _bandView.translatesAutoresizingMaskIntoConstraints=NO; [_bandView.heightAnchor constraintEqualToConstant:90].active=YES; [_bandView setAccessibilityLabel:@"Band plan segments. Select a segment to inspect it."];
    __weak typeof(self) weakSelf=self; _bandView.picked=^(NSDictionary *segment) { typeof(self) self=weakSelf; if(!self) return; NSUInteger i=[self->_segments indexOfObject:segment]; [self->_bandTable selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO]; [self->_bandTable scrollRowToVisible:i]; };
    NSView *table=[self table:&_bandTable columns:@[@[@"range",@"Frequency range · MHz",@190],@[@"usage",@"Recommended use",@270],@[@"bandwidth",@"Max BW",@100]] height:230];
    _planInfo=Label(@"",11,NSFontWeightRegular); _planInfo.maximumNumberOfLines=4; _planInfo.lineBreakMode=NSLineBreakByWordWrapping;
    NSStackView *head=Stack(@[Label(@"BAND REFERENCE",11,NSFontWeightBold),Spacer(),_band,[self button:@"Official source" symbol:@"arrow.up.right" action:@selector(source:) ]],NO,10);
    NSStackView *body=Stack(@[head,_bandView,table,_planInfo],YES,12); for(NSView *v in body.arrangedSubviews) [v.widthAnchor constraintEqualToAnchor:body.widthAnchor].active=YES; [self bandChanged:nil]; return Card(body);
}
- (NSView *)profilePane {
    _profileMenu=[self menu:@[]]; _profileMenu.target=self; _profileMenu.action=@selector(profileSelected:);
    _fields=[NSMutableDictionary dictionary]; _routeMenus=[NSMutableDictionary dictionary]; NSMutableArray *rows=[NSMutableArray array];
    NSArray *defs=@[@[@"name",@"Profile name"],@[@"call",@"Station callsign"],@[@"operatorCall",@"Operator callsign"],@[@"grid",@"Maidenhead grid"],@[@"operatorName",@"Operator name"],@[@"country",@"Country"],@[@"city",@"City"],@[@"state",@"State / province"],@[@"county",@"County"],@[@"cqZone",@"CQ zone (1–40)"],@[@"ituZone",@"ITU zone (1–90)"],@[@"iota",@"IOTA reference"],@[@"sig",@"Activity (POTA, SOTA…)"],@[@"sigInfo",@"Activity reference"],@[@"rig",@"Radio"],@[@"antenna",@"Antenna"]];
    for(NSArray *d in defs) { NSTextField *f=[self field:d[1]]; _fields[d[0]]=f; [rows addObject:@[Label(d[1],11,NSFontWeightMedium),f]]; }
    _region=[self menu:@[@"1 · Europe / Africa / Middle East",@"2 · Americas",@"3 · Asia / Pacific"]]; [rows addObject:@[Label(@"IARU region",11,NSFontWeightMedium),_region]];
    NSGridView *form=[NSGridView gridViewWithViews:rows]; form.translatesAutoresizingMaskIntoConstraints=NO; form.rowSpacing=8; form.columnSpacing=14; [form columnAtIndex:0].width=155; [form columnAtIndex:1].xPlacement=NSGridCellPlacementFill;
    for(NSArray *d in @[@[@"radioInput",@"Radio receive input"],@[@"radioOutput",@"Radio transmit output"],@[@"microphone",@"Your microphone"],@[@"headphones",@"Headphones"]]) { NSPopUpButton *m=[self menu:@[]]; _routeMenus[d[0]]=m; [form addRowWithViews:@[Label(d[1],11,NSFontWeightMedium),m]]; }
    NSStackView *head=Stack(@[_profileMenu,[self button:@"New profile" symbol:@"plus" action:@selector(newProfile:)],[self button:@"Remove" symbol:@"trash" action:@selector(removeProfile:)]],NO,8);
    NSStackView *buttons=Stack(@[[self button:@"Save & use profile" symbol:@"checkmark.circle" action:@selector(saveProfile:)],[self button:@"Refresh audio devices" symbol:@"arrow.clockwise" action:@selector(refreshRoutes:)]],NO,10);
    NSTextField *note=Label(@"Switch profiles while the station is stopped. Device choices use stable IDs; missing hardware is never silently replaced.",11,NSFontWeightRegular); note.maximumNumberOfLines=2; note.lineBreakMode=NSLineBreakByWordWrapping;
    NSStackView *body=Stack(@[head,form,buttons,note],YES,14); for(NSView *v in body.arrangedSubviews) [v.widthAnchor constraintEqualToAnchor:body.widthAnchor].active=YES; return Card(body);
}
- (NSView *)connectionPane {
    _health=Label(@"",12,NSFontWeightMedium); _health.maximumNumberOfLines=3; _health.lineBreakMode=NSLineBreakByWordWrapping;
    _reportEnabled=[NSButton checkboxWithTitle:@"Report real FT8 / FT4 reception to PSK Reporter" target:self action:@selector(reportChanged:)];
    _reportStatus=Label(@"Reporting off",11,NSFontWeightRegular); _reportStatus.maximumNumberOfLines=3; _reportStatus.lineBreakMode=NSLineBreakByWordWrapping;
    NSTextField *note=Label(@"Reports are grouped every five minutes. Callsign, grid and antenna come from the active profile. Simulated decodes stay local.",11,NSFontWeightRegular); note.maximumNumberOfLines=3; note.lineBreakMode=NSLineBreakByWordWrapping;
    _shortcutFields=[NSMutableDictionary dictionary]; NSMutableArray *rows=[NSMutableArray array];
    for(NSArray *d in @[@[@"station",@"Open station"],@[@"read",@"Read radio"],@[@"favorite",@"Save current VFO"],@[@"voice",@"Open Voice Keyer"],@[@"cw",@"Open CW"],@[@"digital",@"Open FT8 / FT4"]]) { NSTextField *f=[self field:@"Key"]; f.stringValue=_store.shortcuts[d[0]] ?: @""; _shortcutFields[d[0]]=f; [rows addObject:@[Label(d[1],12,NSFontWeightMedium),Label(@"⌘⌥",13,NSFontWeightMedium),f]]; }
    NSGridView *keys=[NSGridView gridViewWithViews:rows]; keys.translatesAutoresizingMaskIntoConstraints=NO; keys.rowSpacing=8; keys.columnSpacing=12; [keys columnAtIndex:0].width=165; [keys columnAtIndex:1].width=30; [keys columnAtIndex:2].width=100;
    NSButton *saveKeys=[self button:@"Save shortcuts" symbol:@"keyboard" action:@selector(saveShortcuts:)];
    NSStackView *body=Stack(@[Label(@"CONNECTION HEALTH",11,NSFontWeightBold),_health,Label(@"RECEPTION REPORTS",11,NSFontWeightBold),_reportEnabled,_reportStatus,note,Label(@"COMMAND SHORTCUTS",11,NSFontWeightBold),keys,saveKeys,Label(@"Esc stops station activity in the main window. Plain typing keys are reserved for text entry.",11,NSFontWeightRegular)],YES,14);
    for(NSView *v in body.arrangedSubviews) if(v!=keys && v!=saveKeys) [v.widthAnchor constraintEqualToAnchor:body.widthAnchor].active=YES; return Card(body);
}
- (void)tabChanged:(id)sender { (void)sender; _paneWidth.active=NO; for(NSView *v in _paneHost.arrangedSubviews.copy) { [_paneHost removeArrangedSubview:v]; [v removeFromSuperview]; } NSView *pane=_panes[_tabs.selectedSegment]; [_paneHost addArrangedSubview:pane]; _paneWidth=[pane.widthAnchor constraintEqualToAnchor:_paneHost.widthAnchor]; _paneWidth.active=YES; }
- (void)changed:(NSNotification *)n { (void)n; [self refresh]; }
- (BOOL)busy { return _busy; }
- (void)activate { [self refresh]; [self loadProfile:_store.activeProfile]; }
- (void)refresh {
    NSDictionary *p=_store.activeProfile; _profileBadge.stringValue=[NSString stringWithFormat:@"%@  ·  %@",p[@"name"] ?: @"Station",[p[@"call"] length] ? p[@"call"] : @"Set callsign"];
    NSString *selected=_editingID; [_profileMenu removeAllItems]; for(NSDictionary *item in _store.profiles) { [_profileMenu addItemWithTitle:item[@"name"]]; _profileMenu.lastItem.representedObject=item[@"id"]; if([selected isEqual:item[@"id"]]) [_profileMenu selectItem:_profileMenu.lastItem]; }
    NSDictionary *s=self.core.snapshot; _vfo.stringValue=s[@"frequency"] ? [NSString stringWithFormat:@"%.6f MHz",[s[@"frequency"] doubleValue]/1e6] : @"— . ——— ———";
    _state.stringValue=s.count ? [NSString stringWithFormat:@"%@   •   %@   •   %@",Mode([s[@"mode"] integerValue]),[s[@"tx"] boolValue]?@"TX":@"RX",self.core.owner] : @"Read the radio to see its current frequency";
    _health.stringValue=[NSString stringWithFormat:@"%@\n%lu status reads  ·  %lu failures  ·  last %.0f ms",self.core.status ?: @"Disconnected",(unsigned long)self.core.queryCount,(unsigned long)self.core.failureCount,self.core.lastLatency];
    _reportStatus.stringValue=TX500PSKReporter.sharedReporter.status; _reportEnabled.state=TX500PSKReporter.sharedReporter.enabled?NSControlStateValueOn:NSControlStateValueOff;
    NSString *q=_search.stringValue.lowercaseString; _filtered=[_store.frequencies filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *f,NSDictionary *b){(void)b;return !q.length || [[NSString stringWithFormat:@"%@ %@ %.6f",f[@"name"],f[@"tags"],[f[@"hz"] doubleValue]/1e6].lowercaseString containsString:q];}]]; _table.delegate=nil; [_table reloadData];
    if(_frequencyID) { NSUInteger row=[_filtered indexOfObjectPassingTest:^BOOL(NSDictionary *f,NSUInteger i,BOOL *stop){(void)i;(void)stop;return [f[@"id"] isEqual:self->_frequencyID];}]; if(row!=NSNotFound) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO]; }
    _table.delegate=self; [self bandChanged:nil];
    if(_store.loadError) _message.stringValue=_store.loadError.localizedDescription;
}
- (void)controlTextDidChange:(NSNotification *)n { if(n.object==_search) [self refresh]; }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)t { return t==_table ? _filtered.count : _segments.count; }
- (NSView *)tableView:(NSTableView *)t viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    NSDictionary *d=(t==_table ? _filtered : _segments)[row]; NSString *k=column.identifier,*s=@"";
    if([k isEqual:@"favorite"]) s=[d[k] boolValue]?@"★":@"";
    else if([k isEqual:@"hz"]) s=[NSString stringWithFormat:@"%.6f",[d[k] doubleValue]/1e6];
    else if([k isEqual:@"mode"]) s=Mode([d[k] integerValue]);
    else if([k isEqual:@"range"]) s=[NSString stringWithFormat:@"%.4f – %.4f",[d[@"low"] doubleValue]/1e6,[d[@"high"] doubleValue]/1e6];
    else if([k isEqual:@"bandwidth"]) s=[d[k] integerValue] ? [NSString stringWithFormat:@"%@ Hz",d[k]] : @"See source";
    else s=d[k] ?: @"";
    NSTableCellView *cell=[t makeViewWithIdentifier:k owner:self];
    if(!cell) {
        cell=[[NSTableCellView alloc] initWithFrame:NSZeroRect]; cell.identifier=k;
        NSTextField *label=Label(@"",12,[k isEqual:@"name"]?NSFontWeightMedium:NSFontWeightRegular);
        label.maximumNumberOfLines=1; label.lineBreakMode=NSLineBreakByTruncatingTail;
        cell.textField=label; [cell addSubview:label];
        // Let the row fill its height while the single-line label keeps its natural height.
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
        ]];
    }
    cell.textField.stringValue=s; cell.toolTip=s; return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification *)n { if(n.object==_table && _table.selectedRow>=0 && _table.selectedRow<(NSInteger)_filtered.count) { NSDictionary *f=_filtered[_table.selectedRow]; _frequencyID=f[@"id"]; _entryName.stringValue=f[@"name"]; _frequency.stringValue=[NSString stringWithFormat:@"%.6f",[f[@"hz"] doubleValue]/1e6]; [_mode selectItemWithTitle:Mode([f[@"mode"] integerValue])]; _tags.stringValue=f[@"tags"] ?: @""; _favorite.state=[f[@"favorite"] boolValue]; } }
- (void)message:(NSString *)text { _message.stringValue=text; if(self.logHandler) self.logHandler([@"Station: " stringByAppendingString:text]); }
- (void)performRadio:(BOOL)tune {
    if(_busy) return; uint64_t hz=0; if(tune && ![TX500StationStore parseMHz:_frequency.stringValue hertz:&hz]) { [self message:@"Enter a frequency in MHz from 0.5 to 56."]; return; }
    if(self.prepareControl && !self.prepareControl()) { [self message:@"Stop the active station before changing radio control."]; return; }
    NSInteger modes[]={1,2,3,4,5,6,7,9}; NSInteger mode=modes[MAX(0,_mode.indexOfSelectedItem)]; _busy=YES; [self message:tune?@"Applying frequency, then mode; waiting for radio confirmation…":@"Reading radio status…"];
    dispatch_async(_worker, ^{ NSError *e=nil; BOOL ok=tune ? [self.core tune:hz mode:mode owner:@"Station" error:&e] : [self.core readState:&e]!=nil; dispatch_async(dispatch_get_main_queue(), ^{ self->_busy=NO; [self refresh]; [self message:ok ? (tune?@"Frequency and mode confirmed • receiving":@"Radio status verified") : e.localizedDescription ?: @"Radio not available"]; }); });
}
- (void)readRadio:(id)sender { (void)sender; [self performRadio:NO]; }
- (void)tune:(id)sender { (void)sender; [self performRadio:YES]; }
- (void)stop:(id)sender { (void)sender; if(self.commandHandler) self.commandHandler(@"stop"); }
- (void)quick:(NSButton *)sender { [self runCommand:sender.identifier]; }
- (void)runCommand:(NSString *)command {
    NSDictionary *sections=@{@"frequencies":@0,@"bandplan":@1,@"profiles":@2,@"connections":@3};
    if(sections[command]) { _tabs.selectedSegment=[sections[command] integerValue]; [self tabChanged:nil]; return; }
    if([command isEqual:@"read"]) [self readRadio:nil]; else if([command isEqual:@"favorite"]) { NSDictionary *s=self.core.snapshot; if(!s[@"frequency"]) { [self message:@"Read the radio before saving its VFO."]; return; } [self newFrequency:nil]; _frequency.stringValue=[NSString stringWithFormat:@"%.6f",[s[@"frequency"] doubleValue]/1e6]; [_mode selectItemWithTitle:Mode([s[@"mode"] integerValue])]; _entryName.stringValue=@"My frequency"; _favorite.state=NSControlStateValueOn; _tabs.selectedSegment=0; [self tabChanged:nil]; [self.view.window makeFirstResponder:_entryName]; } else if(self.commandHandler) self.commandHandler(command); }
- (void)newFrequency:(id)sender { (void)sender; _frequencyID=nil; [_table deselectAll:nil]; _entryName.stringValue=@""; _tags.stringValue=@""; _favorite.state=NSControlStateValueOn; }
- (void)saveFrequency:(id)sender { (void)sender; uint64_t hz; if(![TX500StationStore parseMHz:_frequency.stringValue hertz:&hz]) { [self message:@"Enter a valid frequency in MHz."]; return; } NSInteger modes[]={1,2,3,4,5,6,7,9}; NSMutableDictionary *f=[@{@"name":_entryName.stringValue,@"hz":@(hz),@"mode":@(modes[MAX(0,_mode.indexOfSelectedItem)]),@"tags":_tags.stringValue,@"favorite":@(_favorite.state==NSControlStateValueOn)} mutableCopy]; if(_frequencyID) f[@"id"]=_frequencyID; NSError *e=nil; if([_store saveFrequency:f error:&e]) { [self message:@"Frequency saved on this Mac. Radio memories were not changed."]; _frequencyID=nil; } else [self message:e.localizedDescription]; }
- (void)removeFrequency:(id)sender { (void)sender; if(!_frequencyID) return; NSError *e=nil; if([_store removeFrequency:_frequencyID error:&e]) { [self newFrequency:nil]; [self message:@"Frequency removed."]; } else [self message:e.localizedDescription]; }
- (void)bandChanged:(id)sender { (void)sender; NSArray *limits=@[@[@1810000,@2000000],@[@3500000,@3800000],@[@5351500,@5366500],@[@7000000,@7200000],@[@10100000,@10150000],@[@14000000,@14350000],@[@18068000,@18168000],@[@21000000,@21450000],@[@24890000,@24990000],@[@28000000,@29700000]]; NSArray *r=limits[MAX(0,_band.indexOfSelectedItem)]; _segments=[[TX500StationStore bandSegments] filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *s,NSDictionary *b){(void)b;return [s[@"low"] unsignedLongLongValue]>=[r[0] unsignedLongLongValue] && [s[@"high"] unsignedLongLongValue]<=[r[1] unsignedLongLongValue];}]];
    _bandView.low=[r[0] unsignedLongLongValue]; _bandView.high=[r[1] unsignedLongLongValue]; _bandView.frequency=[self.core.snapshot[@"frequency"] unsignedLongLongValue]; _bandView.segments=_segments; _bandView.needsDisplay=YES; [_bandTable reloadData];
    _planInfo.stringValue=[NSString stringWithFormat:@"IARU Region 1 HF reference · effective 16 Oct 2020 · simplified usage groups. Ranges describe transmitted spectrum, not just the dial. Consult the source for exceptions and national permissions.%@",[_store.activeProfile[@"region"] isEqual:@"1"]?@"":@" Your profile is in another region; this reference is not your local band plan."];
}
- (void)source:(id)sender { (void)sender; [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://www.iaru-r1.org/wp-content/uploads/2021/06/hf_r1_bandplan.pdf"]]; }
- (void)loadProfile:(NSDictionary *)p { _editingID=p[@"id"]; for(NSPopUpButton *m in _routeMenus.allValues) [m removeAllItems]; for(NSString *k in _fields) ((NSTextField *)_fields[k]).stringValue=p[k] ?: @""; [_region selectItemAtIndex:MAX(0,MIN(2,[p[@"region"] integerValue]-1))]; [self refreshRoutes:nil]; for(NSMenuItem *item in _profileMenu.itemArray) if([item.representedObject isEqual:_editingID]) [_profileMenu selectItem:item]; }
- (void)profileSelected:(id)sender { (void)sender; for(NSDictionary *p in _store.profiles) if([p[@"id"] isEqual:_profileMenu.selectedItem.representedObject]) { [self loadProfile:p]; break; } }
- (void)newProfile:(id)sender { (void)sender; NSMutableDictionary *p=[_store.activeProfile mutableCopy]; [p removeObjectForKey:@"id"]; p[@"name"]=@"New station"; [self loadProfile:p]; }
- (void)refreshRoutes:(id)sender { (void)sender; NSDictionary *profile=nil; for(NSDictionary *p in _store.profiles) if([p[@"id"] isEqual:_editingID]) profile=p; if(!profile) profile=_store.activeProfile;
    for(NSString *k in _routeMenus) { NSPopUpButton *menu=_routeMenus[k]; NSString *uid=menu.selectedItem.representedObject ?: profile[k] ?: @""; [menu removeAllItems]; [menu addItemWithTitle:@"Not selected"]; menu.lastItem.representedObject=@"";
        for(NSDictionary *d in TXVoiceDevices([@[@"radioInput",@"microphone"] containsObject:k])) { [menu addItemWithTitle:d[@"name"]]; menu.lastItem.representedObject=d[@"uid"]; if([uid isEqual:d[@"uid"]]) [menu selectItem:menu.lastItem]; }
        if(uid.length && ![menu.selectedItem.representedObject isEqual:uid]) { [menu addItemWithTitle:@"Saved device unavailable"]; menu.lastItem.representedObject=uid; [menu selectItem:menu.lastItem]; }
    }
}
- (void)saveProfile:(id)sender { (void)sender; if(self.canEditStation && !self.canEditStation()) { [self message:@"Stop radio and audio activity before applying a profile."]; return; } NSMutableDictionary *p=[NSMutableDictionary dictionary]; if(_editingID) p[@"id"]=_editingID; for(NSString *k in _fields) p[k]=((NSTextField *)_fields[k]).stringValue; p[@"region"]=[NSString stringWithFormat:@"%ld",(long)_region.indexOfSelectedItem+1]; for(NSString *k in _routeMenus) p[k]=((NSPopUpButton *)_routeMenus[k]).selectedItem.representedObject ?: @""; NSError *e=nil;
    if([_store saveProfile:p activate:YES error:&e]) { [self loadProfile:_store.activeProfile]; [self message:@"Station profile applied across the app. Radio frequency and PTT are unchanged."]; } else [self message:e.localizedDescription]; }
- (void)removeProfile:(id)sender { (void)sender; NSError *e=nil; if(_editingID && [_store removeProfile:_editingID error:&e]) [self loadProfile:_store.activeProfile]; else if(e) [self message:e.localizedDescription]; }
- (void)reportChanged:(id)sender { (void)sender; BOOL enabled=_reportEnabled.state==NSControlStateValueOn; [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"TX500_FT8_PSKReporterEnabled"]; TX500PSKReporter.sharedReporter.enabled=enabled; [NSNotificationCenter.defaultCenter postNotificationName:@"TX500StationSettingsChangedNotification" object:self]; }
- (void)saveShortcuts:(id)sender { (void)sender; NSMutableDictionary *keys=[NSMutableDictionary dictionary]; for(NSString *c in _shortcutFields) keys[c]=((NSTextField *)_shortcutFields[c]).stringValue; NSError *e=nil; [self message:[_store saveShortcuts:keys error:&e] ? @"Command–Option shortcuts saved." : e.localizedDescription]; }
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
@end
