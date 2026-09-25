#import <Cocoa/Cocoa.h>
#import "TX500DXCluster.h"
#import "TX500DXClusterController.h"
#import "TX500LogbookController.h"
#import <sys/socket.h>
#import <arpa/inet.h>
#import <unistd.h>
static NSUInteger checks;
static void Check(BOOL ok,NSString *why) { checks++; if(!ok) { fprintf(stderr,"FAIL: %s\n",why.UTF8String); exit(1); } }
static BOOL Until(BOOL (^ready)(void),double seconds) { NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:seconds]; while(!ready() && deadline.timeIntervalSinceNow>0) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; return ready(); }
static NSDate *UTC(NSString *s) { NSDateFormatter *f=[NSDateFormatter new]; f.dateFormat=@"yyyy-MM-dd HH:mm:ss"; f.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0]; return [f dateFromString:s]; }
static NSString *Line(NSString *call,NSString *comment,NSString *time) { return [NSString stringWithFormat:@"DX de DL1ABC-#:  14025.30 %@ %@ %@Z",call,comment,time]; }
static void Parser(void) {
    NSDate *now=UTC(@"2026-09-23 00:02:00"); TX500DXSpot *s=[TX500DXSpot parseLine:Line(@"W1AW",@"CW CQ",@"2359") receivedAt:now];
    Check(s!=nil,@"Parse DXSpider / skimmer format"); Check(s.frequencyHz==14025300,@"kHz decimal frequency converted exactly to Hz"); Check([s.callsign isEqual:@"W1AW"] && [s.spotter isEqual:@"DL1ABC-#"],@"Retain station and skimmer reporter separately"); Check([s.modeHint isEqual:@"CW"],@"Explicit mode parsed"); Check(fabs([now timeIntervalSinceDate:s.reportedAt]-180)<1,@"UTC rollover assigns previous day"); Check(![s isStaleAt:now],@"Fresh previous-day spot remains visible");
    Check([s.band isEqual:@"20m"],@"Existing band mapping reused");
    s=[TX500DXSpot parseLine:Line(@"EP2AES/P",@"strong signal",@"0001") receivedAt:now]; Check([s.modeHint isEqual:@"Unknown"],@"No mode inferred from frequency");
    Check([s.callsign isEqual:@"EP2AES/P"],@"Portable calls preserved");
    for(NSArray *entry in @[@[@"EP2AES/P",@"Iran",@"🇮🇷"],@[@"SA6FAX",@"Sweden",@"🇸🇪"],@[@"9K2KO",@"Kuwait",@"🇰🇼"],@[@"R8PG/P",@"Asiatic Russia",@"🇷🇺"],@[@"SP100PKP",@"Poland",@"🇵🇱"],@[@"S79VU",@"Seychelles",@"🇸🇨"],@[@"E73M",@"Bosnia & Herzegovina",@"🇧🇦"],@[@"ZZ9ZZZ",@"Unknown",@"🌐"]]) {
        TX500DXSpot *country=[TX500DXSpot parseLine:Line(entry[0],@"CW",@"0001") receivedAt:now];
        Check([country.country isEqual:entry[1]] && [country.countryFlag isEqual:entry[2]],@"Country and flag agree, including portable and unknown callsigns");
    }
    Check(TX500DXCluster.recommendedNodes.count==3,@"Three documented source presets available");
    for(NSDictionary *node in TX500DXCluster.recommendedNodes) Check([TX500DXCluster validHost:node[@"host"] port:[node[@"port"] integerValue] callsign:@"EP2AES"] && [node[@"website"] hasPrefix:@"https://"],@"Source endpoint and website validated");
    for(NSString *line in @[Line(@"W1AW",@"CW",@"2460"),Line(@"NOTACALL",@"CW",@"0001"),@"DX de K1ABC: NaN W1AW CW 0001Z",@"DX de K1ABC: 14025;TX; W1AW CW 0001Z",@"To ALL de K1ABC: hello",@"DX de K1ABC: 14025.0 W1AW CW",@"DX de K1ABC: 9999999999 W1AW CW 0001Z"]) Check(![TX500DXSpot parseLine:line receivedAt:now],@"Reject malformed / non-spot line");
    s=[TX500DXSpot parseLine:Line(@"W1AW",@"CW",@"2300") receivedAt:now]; Check([s isStaleAt:now],@"Age uses reported UTC, not arrival time");
    s=[TX500DXSpot parseLine:Line(@"W1AW",@"calling K1CW no mode",@"0001") receivedAt:now]; Check([s.modeHint isEqual:@"Unknown"],@"Mode token cannot match inside callsign");
    Check([TX500DXCluster validHost:@"dx.example.org" port:7373 callsign:@"EP2AES/P"],@"Valid host and portable login"); Check([TX500DXCluster validHost:@"::1" port:7373 callsign:@"K1ABC"],@"IPv6 accepted");
    for(NSString *host in @[@"",@"bad host",@"host\nsh/dx",@"-bad.example",@"https://example.org"]) Check(![TX500DXCluster validHost:host port:7373 callsign:@"K1ABC"],@"Reject malformed endpoint");
    Check(![TX500DXCluster validHost:@"localhost" port:65536 callsign:@"K1ABC"] && ![TX500DXCluster validHost:@"localhost" port:7373 callsign:@"K1ABC\nDX"],@"Port bounds and login injection rejected");
    Check([TX500DXCluster retryDelayForAttempt:0]==2 && [TX500DXCluster retryDelayForAttempt:3]==16 && [TX500DXCluster retryDelayForAttempt:1000]==60,@"Retry delay exponential and capped");
}
static void Framing(void) {
    TX500DXStream *stream=[TX500DXStream new]; NSMutableArray *lines=[NSMutableArray array],*replies=[NSMutableArray array],*prompts=[NSMutableArray array];
    stream.lineHandler=^(NSString *s){[lines addObject:s];}; stream.replyHandler=^(NSData *d){[replies addObject:d];}; stream.promptHandler=^(NSString *s){[prompts addObject:s];};
    NSData *data=[@"DX de K1ABC: 14025 W1AW CW 1200Z\r\nDX de G4ABC: 7074 EP2AES FT8 1201Z\n" dataUsingEncoding:NSUTF8StringEncoding];
    for(NSUInteger i=0;i<data.length;i++) [stream consume:[data subdataWithRange:NSMakeRange(i,1)]];
    Check(lines.count==2,@"Byte-fragmented CRLF produces exactly two records");
    [stream consume:[NSData dataWithBytes:(uint8_t[]){255,251} length:2]]; [stream consume:[NSData dataWithBytes:(uint8_t[]){1,255,253,3,255,250,24,1,2,255,240} length:11]];
    Check(replies.count==2,@"Fragmented Telnet options refused once"); Check([replies[0] isEqual:[NSData dataWithBytes:(uint8_t[]){255,254,1} length:3]],@"WILL negotiation gets DONT"); Check([replies[1] isEqual:[NSData dataWithBytes:(uint8_t[]){255,252,3} length:3]],@"DO negotiation gets WONT");
    [stream consume:[@"\033[31mlogin:" dataUsingEncoding:NSASCIIStringEncoding]]; Check([prompts.lastObject isEqual:@"login:"],@"Prompt without newline and ANSI color handled");
    [stream consume:[@"\r\n" dataUsingEncoding:NSASCIIStringEncoding]];
    NSUInteger count=lines.count; NSString *huge=[@"x" stringByPaddingToLength:6000 withString:@"x" startingAtIndex:0]; [stream consume:[[huge stringByAppendingString:@"\nvalid\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    Check(lines.count==count+1 && [lines.lastObject isEqual:@"valid"],@"Overlong input discarded and framing recovers");
}
static void Alerts(void) {
    NSDate *now=UTC(@"2026-09-23 12:00:00"); TX500DXSpot *s=[TX500DXSpot parseLine:Line(@"W1AW",@"CW",@"1200") receivedAt:now]; TX500DXAlertPolicy *p=[TX500DXAlertPolicy new]; p.calls=@"W1*, EP2AES";
    Check(![p matches:s],@"Alerts opt-in"); p.enabled=YES; Check([p matches:s],@"Call wildcard matches"); p.countries=@"Japan"; Check(![p matches:s],@"Different fields combine with AND"); p.countries=s.country; Check([p matches:s],@"Country rule matches case-independent exact name");
    Check([p shouldNotify:s now:now],@"First fresh matching spot notifies"); Check(![p shouldNotify:s now:[now dateByAddingTimeInterval:45]],@"Same callsign/band cooldown");
    p.countries=@""; TX500DXSpot *other=[TX500DXSpot parseLine:Line(@"EP2AES",@"CW",@"1200") receivedAt:now]; Check(![p shouldNotify:other now:[now dateByAddingTimeInterval:10]],@"Global sound cooldown limits alert storms"); Check([p shouldNotify:other now:[now dateByAddingTimeInterval:31]],@"Other callsign permitted after global cooldown"); Check([p shouldNotify:s now:[now dateByAddingTimeInterval:601]],@"Repeated call allowed after ten minutes"); Check(![p shouldNotify:s now:[now dateByAddingTimeInterval:1000]],@"Stale replay never alerts"); p.calls=@""; Check(![p matches:s],@"Empty rule cannot match everything");
}
static void Storage(void) {
    TX500DXCluster *engine=[TX500DXCluster new]; NSDate *now=UTC(@"2026-09-23 12:00:00"); NSString *line=Line(@"W1AW",@"CW",@"1200");
    [engine ingestLine:line receivedAt:now]; [engine ingestLine:line receivedAt:now]; Check(Until(^BOOL{return engine.spots.count==1;},2),@"First spot ingested");
    __block BOOL drained=NO; engine.changed=^{drained=YES;}; [engine ingestLine:Line(@"K1ABC",@"CW",@"1200") receivedAt:now]; Check(Until(^BOOL{return drained;},2),@"Updates delivered on main queue"); Check(engine.spots.count==2,@"Duplicate report does not duplicate row");
    for(int i=0;i<1010;i++) [engine ingestLine:Line([NSString stringWithFormat:@"K%dABC",i],@"CW",@"1200") receivedAt:now];
    Check(Until(^BOOL{return [engine.spots.firstObject.callsign isEqual:@"K1009ABC"];},5),@"Burst ingestion completes"); Check(engine.spots.count==1000,@"Spot history bounded at 1000"); Check(!engine.running,@"Fixture ingestion never opens a connection"); [engine clear]; Check(Until(^BOOL{return engine.spots.count==0;},2),@"Clear removes all session rows");
}
static void Network(void) {
    int server=socket(AF_INET,SOCK_STREAM,0); Check(server>=0,@"Loopback fixture socket created"); struct sockaddr_in address={0}; address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK); address.sin_port=0;
    Check(bind(server,(struct sockaddr *)&address,sizeof(address))==0 && listen(server,2)==0,@"Loopback fixture listening"); socklen_t length=sizeof(address); getsockname(server,(struct sockaddr *)&address,&length);
    __block BOOL firstLogin=NO,secondLogin=NO; dispatch_semaphore_t done=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        for(int attempt=0;attempt<2;attempt++) {
            struct timeval timeout={8,0}; setsockopt(server,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
            int client=accept(server,NULL,NULL); if(client<0) break; setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout)); int one=1; setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
            send(client,"lo",2,0); send(client,"gin:",4,0); char buffer[128]={0}; ssize_t n=0;
            while(n<127) { ssize_t got=recv(client,buffer+n,1,0); if(got<=0) break; n+=got; if(buffer[n-1]=='\n') break; }
            NSString *login=n>0?[[NSString alloc] initWithBytes:buffer length:n encoding:NSASCIIStringEncoding]:@"";
            if(attempt==0) firstLogin=[login isEqual:@"K1ABC\r\n"]; else secondLogin=[login isEqual:@"K1ABC\r\n"];
            NSString *line=[NSString stringWithFormat:@"\r\nWelcome K1ABC\r\n%@\r\n",Line(attempt==0?@"W1AW":@"EP2AES",@"CW",@"1200")]; NSData *payload=[line dataUsingEncoding:NSASCIIStringEncoding]; send(client,payload.bytes,payload.length,0);
            if(attempt==1) { char unused; recv(client,&unused,1,0); }
            close(client);
        }
        close(server); dispatch_semaphore_signal(done);
    });
    TX500DXCluster *engine=[TX500DXCluster new]; Check([engine connectHost:@"127.0.0.1" port:ntohs(address.sin_port) callsign:@"K1ABC"],@"Connect to local fixture");
    Check(Until(^BOOL{return engine.spots.count==2;},9),@"Connection loss automatically reconnects and receives new spots"); Check(firstLogin && secondLogin,@"Callsign login sent once on each connection"); [engine disconnect]; Check(Until(^BOOL{return !engine.running;},2),@"Explicit disconnect stops reconnect loop"); Check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0,@"Loopback fixture terminates");
}
static void PasswordNode(void) {
    int server=socket(AF_INET,SOCK_STREAM,0); Check(server>=0,@"Password fixture socket created");
    struct sockaddr_in address={0}; address.sin_family=AF_INET; address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    Check(bind(server,(struct sockaddr *)&address,sizeof(address))==0 && listen(server,1)==0,@"Password fixture bound to loopback"); socklen_t length=sizeof(address); getsockname(server,(struct sockaddr *)&address,&length);
    dispatch_semaphore_t done=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ struct timeval timeout={5,0}; setsockopt(server,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout)); int client=accept(server,NULL,NULL); if(client>=0) { setsockopt(client,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout)); int one=1; setsockopt(client,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one)); send(client,"Password:",9,0); char c; recv(client,&c,1,0); close(client); } close(server); dispatch_semaphore_signal(done); });
    TX500DXCluster *engine=[TX500DXCluster new]; [engine connectHost:@"127.0.0.1" port:ntohs(address.sin_port) callsign:@"K1ABC"];
    Check(Until(^BOOL{return [engine.status containsString:@"requires registration"];},3),@"Password prompt gets an actionable error");
    Check(!engine.running,@"Password node stops rather than repeatedly reconnecting");
    Check(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))==0,@"Password socket released without credentials");
}
@interface DXFakeRadio : NSObject
@property(nonatomic) uint64_t frequency;
@property(nonatomic) NSInteger mode;
@property(nonatomic,strong) NSMutableArray *commands;
@end
@implementation DXFakeRadio
- (instancetype)init { if((self=[super init])) { _frequency=7074000; _mode=6; _commands=[NSMutableArray array]; } return self; }
- (NSDictionary *)readState:(NSError **)error { (void)error; return @{@"frequency":@(self.frequency),@"mode":@(self.mode),@"tx":@NO,@"rxVFO":@0,@"txVFO":@0,@"xit":@NO,@"vox":@NO}; }
- (BOOL)send:(NSString *)command error:(NSError **)error { (void)error; [self.commands addObject:command]; for(NSString *p in [command componentsSeparatedByString:@";"]) { if([p hasPrefix:@"FA"]) self.frequency=[[p substringFromIndex:2] longLongValue]; if([p hasPrefix:@"MD"]) self.mode=[[p substringFromIndex:2] integerValue]; } return YES; }
- (void)close {}
@end
static void Control(TX500DXClusterController *c) {
    TX500DXSpot *spot=[TX500DXSpot parseLine:Line(@"W1AW",@"no mode",@"1200") receivedAt:NSDate.date];
    [c setValue:spot forKey:@"selected"]; [c setValue:@NO forKey:@"demo"];
    NSPopUpButton *mode=[c valueForKey:@"mode"]; [mode selectItemAtIndex:0];
    DXFakeRadio *radio=[DXFakeRadio new]; c.core=[TX500StationCore new]; c.core.transportFactory=^id(NSString *path){(void)path;return radio;};
    __block NSUInteger prepares=0; c.prepareControl=^BOOL{prepares++; return NO;};
    [c performSelector:@selector(tune:) withObject:nil]; Check(prepares==0 && radio.commands.count==0,@"Unknown mode blocks tuning before radio control");
    [mode selectItemWithTitle:@"CW"]; [c performSelector:@selector(tune:) withObject:nil]; Check(prepares==1 && radio.commands.count==0,@"Active station refusal prevents all tuning commands");
    TX500StationCore *core=c.core; c.prepareControl=^BOOL{return [core selectOwner:@"Station" port:@"fake" error:nil];};
    [c performSelector:@selector(tune:) withObject:nil]; Check(Until(^BOOL{return !c.busy;},2),@"Asynchronous tune completes");
    Check(radio.frequency==14025300 && radio.mode==3,@"Selected spot and explicit mode applied through shared station core");
    Check([radio.commands isEqual:@[@"FA00014025300;",@"MD3;"]],@"Tune performs no PTT or transmit command");
    __block NSString *draftCall=nil,*draftMode=nil;
    c.draftHandler=^(TX500DXSpot *s,NSString *m){ draftCall=s.callsign; draftMode=m; };
    [c setValue:spot forKey:@"selected"]; [c performSelector:@selector(draft:) withObject:nil];
    Check([draftCall isEqual:@"W1AW"] && [draftMode isEqual:@"CW"],@"Prepare QSO passes selected call and explicit mode");
    [c setValue:@YES forKey:@"demo"]; c.prepareControl=nil; c.draftHandler=nil;
}
static void Render(void) {
    [NSApplication sharedApplication];
    TX500LogbookManager *manager=TX500LogbookManager.sharedManager;
    TX500LogRecord *record=[TX500LogRecord new]; record.callsign=@"W1AW"; record.frequencyHz=14025000; record.band=@"20m"; record.mode=@"CW"; record.lotwStatus=@"CONFIRMED";
    Check([manager saveContact:record error:nil],@"Seed isolated contact history");
    TX500LogbookController *logger=[TX500LogbookController new];
    NSWindow *logWindow=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1100,900) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO]; logWindow.contentView=logger.view;
    NSInteger count=manager.totalContactCount;
    [logger updateFrequencyHz:7074000 mode:@"FT8"];
    [logger prepareDraftCallsign:@"K1ABC" frequencyHz:14285321 mode:@"USB"];
    Until(^BOOL{return NO;},0.05);
    Check([[(NSTextField *)[logger valueForKey:@"freqField"] stringValue] isEqual:@"14.285321"],@"Late radio refresh cannot overwrite DX draft frequency");
    Check([[(NSTextField *)[logger valueForKey:@"callsignField"] stringValue] isEqual:@"K1ABC"],@"Prepare QSO fills selected callsign");
    Check(manager.totalContactCount==count,@"Preparing draft never saves a QSO");
    [logger performSelector:@selector(logContactAction)];
    Check(manager.totalContactCount==count,@"Blank reports cannot create a contact from a spot");

    for(NSNumber *width in @[@940,@520]) {
        TX500DXClusterController *c=[TX500DXClusterController new]; NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,width.doubleValue,1250) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO]; w.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]; w.contentView=c.view; [c loadDemo];
        Check(Until(^BOOL{return c.engine.spots.count==5;},2),@"Demo fixtures available without network"); [c activate]; [w layoutIfNeeded]; [c.view layoutSubtreeIfNeeded]; Check(!c.view.hasAmbiguousLayout,@"DX view layout determinate");
        NSTableView *table=[c valueForKey:@"table"]; CGFloat sum=0; for(NSTableColumn *column in table.tableColumns) sum+=column.width; Check(sum<=table.bounds.size.width,@"All columns fit scrollable table");
        Check(NSMaxX([table rectOfColumn:table.numberOfColumns-1])<=table.bounds.size.width,@"Last column fits inside scrollable content");
        Check(table.enclosingScrollView.hasHorizontalScroller && [[table tableColumnWithIdentifier:@"country"] width]>=150 && (width.integerValue>=740 || table.bounds.size.width>table.enclosingScrollView.contentView.bounds.size.width),[NSString stringWithFormat:@"Compact scroll: table %.1f, viewport %.1f, horizontal %d",table.bounds.size.width,table.enclosingScrollView.contentView.bounds.size.width,table.enclosingScrollView.hasHorizontalScroller]);
        NSInteger countryColumn=[table columnWithIdentifier:@"country"];
        NSTableCellView *countryCell=[table viewAtColumn:countryColumn row:0 makeIfNecessary:YES];
        Check([countryCell.textField.stringValue containsString:@"Brazil"] && [countryCell.textField.stringValue containsString:@"🇧🇷"],@"Visible country column includes country name and flag");
        if(width.integerValue==940) {
            NSPopUpButton *nodes=[c valueForKey:@"nodeMenu"]; NSTextField *host=[c valueForKey:@"host"],*port=[c valueForKey:@"port"];
            [nodes selectItemAtIndex:1]; [c performSelector:@selector(nodeChanged:) withObject:nil];
            Check([host.stringValue isEqual:@"dxc.hamserve.uk"] && [port.stringValue isEqual:@"7300"] && !c.engine.running,@"Selecting documented source fills endpoint without connecting");
            host.stringValue=@"localhost"; port.stringValue=@"9000"; [c performSelector:@selector(controlTextDidChange:) withObject:[NSNotification notificationWithName:NSControlTextDidChangeNotification object:host]];
            Check(nodes.indexOfSelectedItem==3 && ![[c valueForKey:@"nodeWebsite"] isEnabled],@"Custom endpoint does not show an unrelated website");
            [c performSelector:@selector(persist)]; TX500DXClusterController *restored=[TX500DXClusterController new];
            Check([[(NSTextField *)[restored valueForKey:@"host"] stringValue] isEqual:@"localhost"] && [(NSPopUpButton *)[restored valueForKey:@"nodeMenu"] indexOfSelectedItem]==3,@"Custom server survives restore"); [restored stop];
            [nodes selectItemAtIndex:0]; [c performSelector:@selector(nodeChanged:) withObject:nil];
        }
        [table selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO]; NSButton *tune=[c valueForKey:@"tune"]; Check(!tune.enabled,@"Demo data cannot tune hardware");
        Check(Until(^BOOL{return [[c valueForKey:@"historyReady"] boolValue];},2),@"Logbook index loaded asynchronously");
        TX500DXSpot *worked=[TX500DXSpot parseLine:Line(@"W1AW",@"CW",@"1200") receivedAt:NSDate.date];
        Check([[c performSelector:@selector(statusFor:) withObject:worked] isEqual:@"CONFIRMED"],@"Confirmed badge requires confirmation on the same band");
        worked.band=@"40m"; Check([[c performSelector:@selector(statusFor:) withObject:worked] isEqual:@"NEW BAND"],@"Contact on another band is not a same-band confirmation");
        NSSearchField *search=[c valueForKey:@"search"]; search.stringValue=@"Japan"; [c performSelector:@selector(filter:) withObject:nil]; Check(table.numberOfRows==1,@"Country search filters spots");
        search.stringValue=@""; [c performSelector:@selector(filter:) withObject:nil];

        if(width.integerValue==940) Control(c);
        NSBitmapImageRep *rep=[c.view bitmapImageRepForCachingDisplayInRect:c.view.bounds]; [c.view cacheDisplayInRect:c.view.bounds toBitmapImageRep:rep]; [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithFormat:@"validation/dxcluster-%@.png",width] atomically:YES]; [c stop];
    }
}
int main(int argc,const char *argv[]) { (void)argc;(void)argv; @autoreleasepool {
    char temp[]="/tmp/DXClusterTests.XXXXXX"; Check(mkdtemp(temp)!=NULL,@"Create isolated storage"); setenv("CFFIXED_USER_HOME",temp,1); setenv("TX500_TEST_ROOT",temp,1); setenv("TX500_STATION_TEST_ROOT",temp,1); setenv("TX500_TEST_MODE","1",1);
    Parser(); Framing(); Alerts(); Storage(); if([NSProcessInfo.processInfo.arguments containsObject:@"--network"]) { Network(); PasswordNode(); } if([NSProcessInfo.processInfo.arguments containsObject:@"--render"]) Render();
    printf("PASS: %lu DX Cluster checks; no public node, radio or cloud uploads used.\n",(unsigned long)checks);
    [NSFileManager.defaultManager removeItemAtPath:[NSString stringWithUTF8String:temp] error:nil];
} return 0; }
