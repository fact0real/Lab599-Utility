#import "TX500DXClusterController.h"
#import "TX500StationStore.h"
#import "TX500CallsignLookupService.h"
static NSTextField *DXLabel(NSString *text,CGFloat size,NSFontWeight weight) { NSTextField *f=[NSTextField labelWithString:text]; f.font=[NSFont systemFontOfSize:size weight:weight]; f.translatesAutoresizingMaskIntoConstraints=NO; f.toolTip=text; [f setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal]; return f; }
static NSStackView *DXStack(NSArray *views,BOOL vertical,CGFloat spacing) { NSStackView *s=[NSStackView stackViewWithViews:views]; s.orientation=vertical?NSUserInterfaceLayoutOrientationVertical:NSUserInterfaceLayoutOrientationHorizontal; s.alignment=vertical?NSLayoutAttributeLeading:NSLayoutAttributeCenterY; s.spacing=spacing; s.translatesAutoresizingMaskIntoConstraints=NO; return s; }
static NSBox *DXCard(NSView *v) { NSBox *b=[NSBox new]; b.boxType=NSBoxCustom; b.titlePosition=NSNoTitle; b.cornerRadius=12; b.borderColor=NSColor.separatorColor; b.fillColor=NSColor.controlBackgroundColor; b.translatesAutoresizingMaskIntoConstraints=NO; [b.contentView addSubview:v]; [NSLayoutConstraint activateConstraints:@[[v.leadingAnchor constraintEqualToAnchor:b.contentView.leadingAnchor constant:14],[v.trailingAnchor constraintEqualToAnchor:b.contentView.trailingAnchor constant:-14],[v.topAnchor constraintEqualToAnchor:b.contentView.topAnchor constant:14],[v.bottomAnchor constraintEqualToAnchor:b.contentView.bottomAnchor constant:-14]]]; return b; }
@interface TXDXTableScroll : NSScrollView
@end
@implementation TXDXTableScroll
- (void)layout {
    [super layout]; NSTableView *table=(NSTableView *)self.documentView;
    CGFloat viewport=self.contentView.bounds.size.width; if(viewport<=0) return;
    // Keep labels readable on narrow windows; all columns remain reachable by scrolling.
    CGFloat width=MAX(740,viewport),usable=width-32-table.intercellSpacing.width*table.tableColumns.count;
    NSArray *weights=@[@0.15,@0.24,@0.15,@0.10,@0.14,@0.14,@0.08]; NSUInteger i=0;
    for(NSTableColumn *column in table.tableColumns) {
        CGFloat target=usable*[weights[i++] doubleValue];
        if(fabs(target-column.width)>0.5) column.width=target;
    }
    NSRect frame=table.frame; frame.size.width=width; table.frame=frame;
}

@end
@interface TX500DXClusterController () <NSTableViewDelegate,NSTableViewDataSource,NSSearchFieldDelegate>
@property(nonatomic,strong) NSView *view;
@property(nonatomic,strong) TX500DXCluster *engine;
@end
@implementation TX500DXClusterController {
    NSTextField *_host,*_port,*_state,*_count,*_selectedTitle,*_detail,*_history,*_message,*_alertCalls,*_alertCountries,*_lastAlert;
    NSSearchField *_search; NSPopUpButton *_band,*_historyFilter,*_mode,*_nodeMenu; NSButton *_nodeWebsite,*_connect,*_fresh,*_alertsEnabled,*_sound,*_tune,*_draft;
    NSTableView *_table; NSArray<TX500DXSpot *> *_visible; TX500DXSpot *_selected;
    NSDictionary<NSString *,NSArray<TX500LogRecord *> *> *_contacts;
    NSSet<NSString *> *_workedBands,*_confirmedBands;
    NSString *_sessionCall;
    TX500DXAlertPolicy *_alerts; BOOL _busy,_refreshPending,_demo,_historyReady; NSUInteger _lookupGeneration,_historyGeneration; NSTimer *_timer;
}
- (BOOL)busy { return _busy; }
- (NSTextField *)field:(NSString *)placeholder { NSTextField *f=[NSTextField textFieldWithString:@""]; f.placeholderString=placeholder; f.translatesAutoresizingMaskIntoConstraints=NO; [f.widthAnchor constraintGreaterThanOrEqualToConstant:60].active=YES; return f; }
- (NSButton *)button:(NSString *)title symbol:(NSString *)symbol action:(SEL)action { NSButton *b=[NSButton buttonWithTitle:title target:self action:action]; b.translatesAutoresizingMaskIntoConstraints=NO; b.bezelStyle=NSBezelStyleRounded; b.image=[NSImage imageWithSystemSymbolName:symbol accessibilityDescription:title]; b.imagePosition=NSImageLeft; return b; }
- (NSPopUpButton *)menu:(NSArray *)titles { NSPopUpButton *m=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO]; m.translatesAutoresizingMaskIntoConstraints=NO; [m addItemsWithTitles:titles]; [m setContentCompressionResistancePriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal]; return m; }
- (instancetype)init {
    if((self=[super init])) {
        _engine=[TX500DXCluster new]; _alerts=[TX500DXAlertPolicy new]; _contacts=@{}; _visible=@[]; _logbook=TX500LogbookManager.sharedManager; [self build]; [self restore];
        __weak typeof(self) weak=self;
        _engine.changed=^{ [weak scheduleRefresh]; };
        _engine.receivedSpot=^(TX500DXSpot *s){ typeof(self) self=weak; if(!self || self->_demo) return; if([self->_alerts shouldNotify:s now:NSDate.date]) { self->_lastAlert.stringValue=[NSString stringWithFormat:@"Matched %@ · %@ · %.6f MHz",s.callsign,s.country,s.frequencyHz/1e6]; if(self->_sound.state==NSControlStateValueOn && !self.core.ownsTX && ![self.core.snapshot[@"tx"] boolValue]) [[NSSound soundNamed:@"Glass"] play]; } };
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(logChanged:) name:TX500LogbookDidChangeNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(stationChanged:) name:@"TX500StationSettingsChangedNotification" object:nil];
        _timer=[NSTimer scheduledTimerWithTimeInterval:15 repeats:YES block:^(NSTimer *timer){(void)timer;[weak refresh];}]; [self loadHistory]; [self refresh];
    } return self;
}
- (void)dealloc { [_timer invalidate]; [_engine disconnect]; [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)build {
    _view=[NSView new]; _view.translatesAutoresizingMaskIntoConstraints=NO;
    NSTextField *eyebrow=DXLabel(@"DX CLUSTER  /  LIVE DISCOVERY",10,NSFontWeightBold); eyebrow.textColor=NSColor.systemTealColor;
    _state=DXLabel(@"Offline",11,NSFontWeightMedium); _state.maximumNumberOfLines=2; _state.lineBreakMode=NSLineBreakByWordWrapping;
    NSStackView *header=DXStack(@[eyebrow,DXLabel(@"Find your next contact.",26,NSFontWeightSemibold),_state],YES,7);
    _nodeMenu=[self menu:@[]];
    for(NSDictionary *node in TX500DXCluster.recommendedNodes) {
        [_nodeMenu addItemWithTitle:node[@"name"]]; _nodeMenu.lastItem.representedObject=node;
    }
    [_nodeMenu addItemWithTitle:@"Custom server…"]; _nodeMenu.target=self; _nodeMenu.action=@selector(nodeChanged:);
    _nodeWebsite=[self button:@"Node website" symbol:@"arrow.up.right" action:@selector(openNodeWebsite:)];
    NSStackView *source=DXStack(@[DXLabel(@"Spot source",11,NSFontWeightMedium),_nodeMenu,_nodeWebsite],NO,10);
    [_nodeMenu setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    _host=[self field:@"Node hostname"]; _port=[self field:@"Port"]; _host.delegate=(id)self; _port.delegate=(id)self; [_port.widthAnchor constraintEqualToConstant:64].active=YES;
    _connect=[self button:@"Connect" symbol:@"antenna.radiowaves.left.and.right" action:@selector(connect:)];
    NSStackView *connection=DXStack(@[_host,_port,_connect],NO,8); [_host setContentHuggingPriority:1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSTextField *connectionNote=DXLabel(@"Uses your station callsign. Public callsign-login nodes · no automatic connection on launch.",11,NSFontWeightRegular); connectionNote.maximumNumberOfLines=2; connectionNote.lineBreakMode=NSLineBreakByWordWrapping;
    _search=[NSSearchField new]; _search.translatesAutoresizingMaskIntoConstraints=NO; _search.placeholderString=@"Search callsigns, countries, reporters or comments"; _search.delegate=self;
    _band=[self menu:@[@"All bands",@"160m",@"80m",@"60m",@"40m",@"30m",@"20m",@"17m",@"15m",@"12m",@"10m",@"6m",@"2m",@"70cm"]]; _band.target=self; _band.action=@selector(filter:);
    _historyFilter=[self menu:@[@"All contacts",@"New callsigns",@"New on band",@"Worked before",@"Confirmed on band"]]; _historyFilter.target=self; _historyFilter.action=@selector(filter:);
    _fresh=[NSButton checkboxWithTitle:@"Last 15 minutes" target:self action:@selector(filter:)]; _fresh.state=NSControlStateValueOn;
    _count=DXLabel(@"0 spots",11,NSFontWeightMedium); _count.textColor=NSColor.secondaryLabelColor;
    NSStackView *filters=DXStack(@[_band,_historyFilter,_fresh],NO,10);
    _table=[NSTableView new]; _table.delegate=self; _table.dataSource=self; _table.rowHeight=35; _table.style=NSTableViewStyleFullWidth; _table.intercellSpacing=NSMakeSize(4,2); _table.usesAlternatingRowBackgroundColors=YES; _table.columnAutoresizingStyle=NSTableViewNoColumnAutoresizing;
    for(NSArray *d in @[@[@"call",@"DX station"],@[@"country",@"Country / entity¹"],@[@"frequency",@"MHz"],@[@"mode",@"Mode¹"],@[@"worked",@"Logbook"],@[@"spotter",@"Reporter"],@[@"age",@"Age"]]) { NSTableColumn *c=[[NSTableColumn alloc] initWithIdentifier:d[0]]; c.title=d[1]; c.minWidth=25; [_table addTableColumn:c]; }
    NSScrollView *scroll=[TXDXTableScroll new]; scroll.documentView=_table; scroll.hasVerticalScroller=YES; scroll.hasHorizontalScroller=YES; scroll.autohidesScrollers=YES; scroll.translatesAutoresizingMaskIntoConstraints=NO; [scroll.heightAnchor constraintEqualToConstant:275].active=YES;
    NSTextField *note=DXLabel(@"¹ Mode comes from the report text; country / entity and flag are prefix estimates. Scroll sideways in narrow windows. A spot is not a confirmed reception at your station.",11,NSFontWeightRegular); note.maximumNumberOfLines=3; note.lineBreakMode=NSLineBreakByWordWrapping; note.textColor=NSColor.secondaryLabelColor;
    NSStackView *list=DXStack(@[_search,filters,_count,scroll,note],YES,10); for(NSView *v in list.arrangedSubviews) [v.widthAnchor constraintEqualToAnchor:list.widthAnchor].active=YES;
    _selectedTitle=DXLabel(@"Select a spot to inspect it",19,NSFontWeightSemibold); _detail=DXLabel(@"Frequency, report, country and contact history appear here.",12,NSFontWeightRegular); _detail.maximumNumberOfLines=4; _detail.lineBreakMode=NSLineBreakByWordWrapping;
    _history=DXLabel(@"",11,NSFontWeightMedium); _history.maximumNumberOfLines=4; _history.lineBreakMode=NSLineBreakByWordWrapping;
    _mode=[self menu:@[@"Choose mode…",@"USB",@"LSB",@"CW",@"FM",@"AM",@"FT8",@"FT4",@"RTTY",@"PSK31"]];
    _tune=[self button:@"Tune radio" symbol:@"dial.low" action:@selector(tune:)]; _draft=[self button:@"Prepare QSO" symbol:@"square.and.pencil" action:@selector(draft:)];
    NSStackView *actions=DXStack(@[_mode,_tune,_draft,[self button:@"Lookup" symbol:@"person.crop.circle" action:@selector(lookup:)]],NO,8);
    NSStackView *detail=DXStack(@[_selectedTitle,_detail,_history,actions],YES,10); for(NSView *v in detail.arrangedSubviews) [v.widthAnchor constraintEqualToAnchor:detail.widthAnchor].active=YES;
    _alertsEnabled=[NSButton checkboxWithTitle:@"Highlight matching spots" target:self action:@selector(alertChanged:)];
    _sound=[NSButton checkboxWithTitle:@"Play alert sound" target:self action:@selector(alertChanged:)];
    _alertCalls=[self field:@"Callsigns / prefixes: W1AW, EP*"]; _alertCountries=[self field:@"Countries: Japan, Germany"];
    _lastAlert=DXLabel(@"Alerts: at most once per 30 seconds, and once per callsign / band every 10 minutes.",11,NSFontWeightRegular); _lastAlert.maximumNumberOfLines=2; _lastAlert.lineBreakMode=NSLineBreakByWordWrapping;
    NSStackView *alertFields=DXStack(@[_alertCalls,_alertCountries],NO,10); [_alertCalls.widthAnchor constraintEqualToAnchor:_alertCountries.widthAnchor].active=YES;
    NSStackView *alert=DXStack(@[DXStack(@[_alertsEnabled,_sound,[self button:@"Save alert" symbol:@"bell" action:@selector(alertChanged:)]],NO,10),alertFields,_lastAlert],YES,10); for(NSView *v in alert.arrangedSubviews) [v.widthAnchor constraintEqualToAnchor:alert.widthAnchor].active=YES;
    _message=DXLabel(@"Connect to a node to receive live spots. Tuning never starts transmission.",11,NSFontWeightMedium); _message.maximumNumberOfLines=3; _message.lineBreakMode=NSLineBreakByWordWrapping;
    NSStackView *body=DXStack(@[header,source,connection,connectionNote,DXCard(list),DXCard(detail),DXCard(alert),_message],YES,14);
    [_view addSubview:body]; for(NSView *v in body.arrangedSubviews) [v.widthAnchor constraintEqualToAnchor:body.widthAnchor].active=YES;
    [NSLayoutConstraint activateConstraints:@[[body.topAnchor constraintEqualToAnchor:_view.topAnchor constant:8],[body.bottomAnchor constraintEqualToAnchor:_view.bottomAnchor constant:-8],[body.leadingAnchor constraintEqualToAnchor:_view.leadingAnchor],[body.trailingAnchor constraintEqualToAnchor:_view.trailingAnchor]]];
}
- (NSUserDefaults *)defaults { return NSUserDefaults.standardUserDefaults; }
- (void)restore {
    NSDictionary *d=[self.defaults dictionaryForKey:@"DXCluster.Settings"] ?: @{};
    _host.stringValue=[d[@"host"] isKindOfClass:NSString.class] ? d[@"host"] : @"dxcluster.f5len.org";
    _port.stringValue=[d[@"port"] isKindOfClass:NSString.class] ? d[@"port"] : @"7373";
    _alertCalls.stringValue=[d[@"calls"] isKindOfClass:NSString.class] ? d[@"calls"] : @""; _alertCountries.stringValue=[d[@"countries"] isKindOfClass:NSString.class] ? d[@"countries"] : @"";
    _alertsEnabled.state=[d[@"alerts"] isKindOfClass:NSNumber.class] && [d[@"alerts"] boolValue]; _sound.state=[d[@"sound"] isKindOfClass:NSNumber.class] && [d[@"sound"] boolValue];
    [self updateAlertPolicy]; [self updateNodeSelection];
}
- (void)updateNodeSelection {
    [_nodeMenu selectItemAtIndex:_nodeMenu.numberOfItems-1];
    NSString *host=[_host.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for(NSMenuItem *item in _nodeMenu.itemArray) {
        NSDictionary *node=item.representedObject;
        if(node && [node[@"host"] caseInsensitiveCompare:host]==NSOrderedSame && [node[@"port"] isEqual:_port.stringValue]) { [_nodeMenu selectItem:item]; break; }
    }
    _nodeWebsite.enabled=_nodeMenu.selectedItem.representedObject!=nil;
}
- (void)nodeChanged:(id)sender {
    (void)sender;
    if(self.engine.running) { [self updateNodeSelection]; return; }
    NSDictionary *node=_nodeMenu.selectedItem.representedObject;
    if(node) { _host.stringValue=node[@"host"]; _port.stringValue=node[@"port"]; }
    _nodeWebsite.enabled=node!=nil; [self persist];
    _message.stringValue=node ? @"Source selected. Click Connect to receive spots." : @"Enter a hostname and port, then click Connect.";
}
- (void)openNodeWebsite:(id)sender {
    (void)sender; NSString *url=[_nodeMenu.selectedItem.representedObject objectForKey:@"website"];
    if(url.length) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]];
}
- (void)persist { [self.defaults setObject:@{@"host":_host.stringValue,@"port":_port.stringValue,@"calls":_alertCalls.stringValue,@"countries":_alertCountries.stringValue,@"alerts":@(_alertsEnabled.state==1),@"sound":@(_sound.state==1)} forKey:@"DXCluster.Settings"]; }
- (void)updateAlertPolicy { _alerts.enabled=_alertsEnabled.state==1; _alerts.calls=[_alertCalls.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; _alerts.countries=[_alertCountries.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; }
- (void)alertChanged:(id)sender { (void)sender; if(_alertCalls.stringValue.length>256 || _alertCountries.stringValue.length>256) { _message.stringValue=@"Keep each alert list under 257 characters."; return; } [self updateAlertPolicy]; [self persist]; [_table reloadData]; _message.stringValue=@"Alert saved. Commas mean OR within a field; callsign and country fields combine with AND."; }
- (void)connect:(id)sender {
    (void)sender;
    if(self.engine.running) { [self.engine disconnect]; return; }
    NSString *host=[_host.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]; NSString *port=_port.stringValue;
    NSDictionary *profile=TX500StationStore.sharedStore.activeProfile; NSString *call=[profile[@"operatorCall"] length] ? profile[@"operatorCall"] : profile[@"call"];
    if([port rangeOfString:@"^[0-9]{1,5}$" options:NSRegularExpressionSearch].location==NSNotFound || ![TX500DXCluster validHost:host port:port.integerValue callsign:call ?: @""]) { _message.stringValue=@"Set a valid callsign in Station Profiles, a hostname and a port from 1 to 65535."; return; }
    _demo=NO; _sessionCall=call.uppercaseString; [self.engine clear]; _host.stringValue=host; [self persist]; [self.engine connectHost:host port:port.integerValue callsign:call];
}
- (void)stationChanged:(NSNotification *)note {
    (void)note; NSDictionary *p=TX500StationStore.sharedStore.activeProfile;
    NSString *call=[p[@"operatorCall"] length] ? p[@"operatorCall"] : p[@"call"];
    if(self.engine.running && ![_sessionCall isEqual:call.uppercaseString]) {
        [self.engine disconnect]; _message.stringValue=@"Station callsign changed. Connect again to log in with the new identity.";
    }
}
- (void)stop { [self.engine disconnect]; }
- (void)activate { [self loadHistory]; [self refresh]; }
- (void)logChanged:(NSNotification *)note { (void)note; [self loadHistory]; }
- (void)loadHistory {
    _historyReady=NO;
    NSUInteger token=++_historyGeneration; TX500LogbookManager *manager=self.logbook;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSMutableDictionary *index=[NSMutableDictionary dictionary]; NSMutableSet *worked=[NSMutableSet set],*confirmed=[NSMutableSet set];
        for(TX500LogRecord *record in manager.allContacts) {
            NSString *key=record.callsign.uppercaseString; if(!index[key]) index[key]=[NSMutableArray array]; [index[key] addObject:record];
            NSString *bandKey=[NSString stringWithFormat:@"%@/%@",key,record.band.lowercaseString]; [worked addObject:bandKey];
            if([record.lotwStatus isEqual:@"CONFIRMED"] || [record.qrzStatus isEqual:@"CONFIRMED"] || [record.eqslStatus isEqual:@"CONFIRMED"]) [confirmed addObject:bandKey];
        }
        dispatch_async(dispatch_get_main_queue(),^{ if(token!=self->_historyGeneration) return; self->_contacts=index; self->_workedBands=worked; self->_confirmedBands=confirmed; self->_historyReady=YES; [self refresh]; [self showDetails:NO]; });
    });
}
- (NSString *)statusFor:(TX500DXSpot *)s {
    if(!_historyReady) return @"CHECKING";
    NSArray *history=_contacts[s.callsign]; if(!history.count) return @"NEW";
    NSString *key=[NSString stringWithFormat:@"%@/%@",s.callsign,s.band.lowercaseString];
    return [_confirmedBands containsObject:key]?@"CONFIRMED":[_workedBands containsObject:key]?@"WORKED":@"NEW BAND";
}
- (void)scheduleRefresh { if(_refreshPending) return; _refreshPending=YES; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/10),dispatch_get_main_queue(),^{ self->_refreshPending=NO; [self refresh]; }); }
- (void)refresh {
    if(!_view) return; _state.stringValue=_demo?@"DEMO • local fixtures, radio actions disabled":self.engine.status; _state.textColor=self.engine.running?NSColor.systemTealColor:NSColor.secondaryLabelColor;
    _connect.title=self.engine.running?@"Disconnect":@"Connect"; _host.enabled=_port.enabled=_nodeMenu.enabled=!self.engine.running;
    NSString *q=_search.stringValue.lowercaseString; NSInteger kind=_historyFilter.indexOfSelectedItem; NSDate *now=NSDate.date;
    NSMutableArray *result=[NSMutableArray array]; for(TX500DXSpot *s in self.engine.spots) {
        if(_fresh.state==1 && [s isStaleAt:now]) continue; if(_band.indexOfSelectedItem>0 && ![s.band isEqual:_band.titleOfSelectedItem]) continue;
        NSString *status=[self statusFor:s]; if(kind>0 && !_historyReady) continue; if((kind==1 && ![status isEqual:@"NEW"]) || (kind==2 && ![@[@"NEW",@"NEW BAND"] containsObject:status]) || (kind==3 && [status isEqual:@"NEW"]) || (kind==4 && ![status isEqual:@"CONFIRMED"])) continue;
        if(q.length && ![[NSString stringWithFormat:@"%@ %@ %@ %@",s.callsign,s.country,s.spotter,s.comment].lowercaseString containsString:q]) continue; [result addObject:s];
    }
    _visible=result; _table.delegate=nil; [_table reloadData]; if(_selected) { NSUInteger row=[_visible indexOfObject:_selected]; if(row!=NSNotFound) [_table selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO]; else { _selected=nil; _lookupGeneration++; [_table deselectAll:nil]; [self showDetails:NO]; } } _table.delegate=self;
    _historyFilter.enabled=_historyReady;
    _count.stringValue=[NSString stringWithFormat:@"%lu visible  ·  %lu in this session  ·  newest first",(unsigned long)_visible.count,(unsigned long)self.engine.spots.count];
    _tune.enabled=_draft.enabled=_selected!=nil && !_busy && !_demo;
}
- (void)filter:(id)sender { (void)sender; [self refresh]; }
- (void)controlTextDidChange:(NSNotification *)n { if(n.object==_host || n.object==_port) { [self updateNodeSelection]; return; } [self refresh]; }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)table { (void)table; return _visible.count; }
- (NSView *)tableView:(NSTableView *)table viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    TX500DXSpot *s=_visible[row]; NSString *k=column.identifier,*text=@"";
    if([k isEqual:@"call"]) text=s.callsign; else if([k isEqual:@"country"]) text=[NSString stringWithFormat:@"%@ %@",s.countryFlag ?: @"🌐",s.country ?: @"Unknown"]; else if([k isEqual:@"frequency"]) text=[NSString stringWithFormat:@"%.6f",s.frequencyHz/1e6]; else if([k isEqual:@"mode"]) text=s.modeHint;
    else if([k isEqual:@"worked"]) text=[self statusFor:s]; else if([k isEqual:@"spotter"]) text=s.spotter; else text=[NSString stringWithFormat:@"%ldm%@",(long)MAX(0,[NSDate.date timeIntervalSinceDate:s.reportedAt]/60),[s isStaleAt:NSDate.date]?@" · old":@""];
    NSTableCellView *cell=[table makeViewWithIdentifier:k owner:self];
    if(!cell) {
        cell=[[NSTableCellView alloc] initWithFrame:NSZeroRect]; cell.identifier=k;
        NSTextField *label=DXLabel(@"",11,[k isEqual:@"call"]?NSFontWeightSemibold:NSFontWeightRegular);
        label.maximumNumberOfLines=1; label.lineBreakMode=NSLineBreakByTruncatingTail;
        cell.textField=label; [cell addSubview:label];
        [NSLayoutConstraint activateConstraints:@[
            [label.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor],
            [label.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor],
            [label.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]
        ]];
    }
    NSTextField *f=cell.textField; f.stringValue=text; f.textColor=NSColor.labelColor; cell.toolTip=text;
    if([s isStaleAt:NSDate.date]) f.textColor=NSColor.tertiaryLabelColor; else if([_alerts matches:s]) f.textColor=NSColor.systemOrangeColor; else if([k isEqual:@"worked"] && [text hasPrefix:@"NEW"]) f.textColor=NSColor.systemTealColor;
    return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification *)note { (void)note; NSInteger row=_table.selectedRow; _selected=row>=0 && row<(NSInteger)_visible.count ? _visible[row] : nil; _lookupGeneration++; [self showDetails:YES]; }
- (void)showDetails:(BOOL)resetMode {
    TX500DXSpot *s=_selected; _tune.enabled=_draft.enabled=s!=nil && !_busy && !_demo;
    if(!s) { _selectedTitle.stringValue=@"Select a spot to inspect it"; _detail.stringValue=@"Frequency, report, country and contact history appear here."; _history.stringValue=@""; return; }
    if(resetMode) { [_mode selectItemAtIndex:0]; if([_mode itemWithTitle:s.modeHint]) [_mode selectItemWithTitle:s.modeHint]; }
    _selectedTitle.stringValue=[NSString stringWithFormat:@"%@   ·   %.6f MHz",s.callsign,s.frequencyHz/1e6];
    NSDateFormatter *fmt=[NSDateFormatter new]; fmt.dateFormat=@"HH:mm 'UTC'"; fmt.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0];
    _detail.stringValue=[NSString stringWithFormat:@"%@ %@ (prefix estimate) · %@ · %@ · reported by %@\n%@",s.countryFlag ?: @"🌐",s.country,s.band,[fmt stringFromDate:s.reportedAt],s.spotter,s.comment.length?s.comment:@"No mode or comment supplied"];
    NSArray *records=_contacts[s.callsign]; NSMutableArray *lines=[NSMutableArray arrayWithObject:[NSString stringWithFormat:@"%@ · %lu previous contacts",[self statusFor:s],(unsigned long)records.count]];
    for(TX500LogRecord *r in records) { if(lines.count>=4) break; [lines addObject:[NSString stringWithFormat:@"%@ %@ UTC · %@ · %@",r.formattedDate,r.formattedTime,r.band,r.mode]]; }
    _history.stringValue=_historyReady ? [lines componentsJoinedByString:@"\n"] : @"Checking the logbook…";
}
- (NSString *)chosenMode { if(_mode.indexOfSelectedItem<1) { _message.stringValue=@"Choose the operating mode. A frequency alone does not establish the mode."; return nil; } return _mode.titleOfSelectedItem; }
- (void)tune:(id)sender {
    (void)sender; if(!_selected || _busy || _demo) return; NSString *mode=[self chosenMode]; if(!mode) return;
    if(self.prepareControl && !self.prepareControl()) { _message.stringValue=@"Stop the active station before tuning to a spot."; return; }
    NSDictionary *codes=@{@"USB":@2,@"LSB":@1,@"CW":@3,@"FM":@4,@"AM":@5,@"FT8":@6,@"FT4":@6,@"RTTY":@6,@"PSK31":@6};
    TX500DXSpot *spot=_selected; _busy=YES; [self refresh]; _message.stringValue=@"Applying frequency and mode, then checking the radio…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{ NSError *e=nil; BOOL ok=[self.core tune:spot.frequencyHz mode:[codes[mode] integerValue] owner:@"Station" error:&e]; dispatch_async(dispatch_get_main_queue(),^{ self->_busy=NO; [self refresh]; self->_message.stringValue=ok?[NSString stringWithFormat:@"%@ · frequency and mode confirmed. Radio is receiving.",spot.callsign]:e.localizedDescription ?: @"The radio did not confirm the change."; }); });
}
- (void)draft:(id)sender { (void)sender; if(!_selected || _demo) return; NSString *mode=[self chosenMode]; if(mode && self.draftHandler) self.draftHandler(_selected,mode); }
- (void)lookup:(id)sender {
    (void)sender; if(!_selected) return; if(_demo) { _message.stringValue=@"Lookup is disabled for demonstration data."; return; }
    NSUInteger token=++_lookupGeneration; NSString *call=_selected.callsign; _message.stringValue=@"Looking up the selected station…";
    __weak typeof(self) weak=self; [TX500CallsignLookupService.sharedService lookupCallsign:call completion:^(TX500LookupResult *result,NSError *error){ dispatch_async(dispatch_get_main_queue(),^{ typeof(self) self=weak; if(!self || token!=self->_lookupGeneration) return; self->_message.stringValue=result.hasData ? [NSString stringWithFormat:@"%@ · %@ · %@ · %@",call,result.name,result.displayLocation,result.grid ?: @""] : error.localizedDescription ?: @"No lookup data available. Configure QRZ or HamQTH in Logbook settings."; }); }];
}
- (void)loadDemo {
    [self.engine disconnect]; [self.engine clear]; _demo=YES;
    NSDateFormatter *f=[NSDateFormatter new]; f.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0]; f.dateFormat=@"HHmm"; NSString *time=[f stringFromDate:NSDate.date];
    for(NSArray *x in @[@[@"K1ABC",@"14025.0",@"W1AW",@"CW CQ"],@[@"DL1ABC",@"14285.0",@"JA1ABC",@"USB CQ DX"],@[@"G4XYZ",@"7074.0",@"EP2AES",@"FT8 heard in Europe"],@[@"F5ABC",@"18130.0",@"VK2ABC",@"CQ long path"],@[@"EA1ABC",@"28074.0",@"PY2ABC",@"FT8 CQ"]]) [self.engine ingestLine:[NSString stringWithFormat:@"DX de %@: %@ %@ %@ %@Z",x[0],x[1],x[2],x[3],time] receivedAt:NSDate.date];
    __weak typeof(self) weak=self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC/3),dispatch_get_main_queue(),^{ typeof(self) self=weak; if(self && self->_demo) { [self refresh]; if(self->_visible.count) [self->_table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO]; } });

}
@end
