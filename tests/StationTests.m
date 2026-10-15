#import <Cocoa/Cocoa.h>
#import "TX500StationCore.h"
#import "TX500StationStore.h"
#import "TX500PSKReporter.h"
#import "TX500StationController.h"
static NSUInteger checks;
static void Check(BOOL ok,NSString *why) { checks++; if(!ok) { fprintf(stderr,"FAIL: %s\n",why.UTF8String); exit(1); } }
@interface FakeStationRadio : NSObject
@property NSMutableDictionary *state;
@property NSMutableArray *commands;
@property BOOL failTX,failRX,failTune,failKY;
@end
@implementation FakeStationRadio
- (instancetype)init { if((self=[super init])) { _state=[@{@"frequency":@14074000,@"mode":@6,@"rxVFO":@0,@"txVFO":@0,@"xit":@0,@"vox":@0,@"tx":@0} mutableCopy]; _commands=[NSMutableArray array]; } return self; }
- (NSDictionary *)readState:(NSError **)error { (void)error; return self.state.copy; }
- (BOOL)setTransmit:(BOOL)tx error:(NSError **)error { (void)error; [self.commands addObject:tx?@"TX;":@"RX;"]; if(tx) self.state[@"tx"]=@1; if((tx && self.failTX)||(!tx && self.failRX)) return NO; self.state[@"tx"]=@(tx); return YES; }
- (NSString *)query:(NSString *)q error:(NSError **)error { (void)error; if([q isEqual:@"PT;"]) return [NSString stringWithFormat:@"PT%@;",self.state[@"tx"]]; return @"FA00014074000;"; }
- (BOOL)send:(NSString *)c error:(NSError **)error { (void)error; [self.commands addObject:c]; if(self.failKY && [c hasPrefix:@"KY"]) return NO; if([c hasPrefix:@"FA"] && !self.failTune) { NSArray *parts=[c componentsSeparatedByString:@";"]; self.state[@"frequency"]=@([[parts[0] substringFromIndex:2] longLongValue]); if(parts.count>1 && [parts[1] hasPrefix:@"MD"]) self.state[@"mode"]=@([[parts[1] substringFromIndex:2] integerValue]); } if([c hasPrefix:@"MD"] && !self.failTune) self.state[@"mode"]=@([[c substringFromIndex:2] integerValue]); return YES; }
- (void)close { [self.commands addObject:@"CLOSE"]; }
@end
// A radio whose full state read fails while PT; still answers: VOX cannot be known.
@interface FakeNoStateRadio : FakeStationRadio
@end
@implementation FakeNoStateRadio
- (NSDictionary *)readState:(NSError **)error { (void)error; return nil; }
@end
static void TestUnknownVOX(void) {
    TX500StationCore *c=[TX500StationCore new]; FakeNoStateRadio *r=[FakeNoStateRadio new]; c.transportFactory=^id(NSString *p){(void)p;return r;};
    [c selectOwner:@"CW" port:@"fake-no-state" error:nil]; NSError *unknownError=nil;
    Check(![c transmit:YES owner:@"CW" error:&unknownError] && !c.ownsTX && ![r.commands containsObject:@"TX;"],@"CW TX refused when the radio state (VOX) cannot be read, even if PT answers PT0;");
    Check([unknownError.localizedDescription containsString:@"VOX"],@"The unknown-VOX refusal names VOX");
    [c selectOwner:@"Digital" port:@"fake-no-state" error:nil];
    Check([c transmit:YES owner:@"Digital" error:nil] && c.ownsTX && [r.commands containsObject:@"TX;"],@"Digital still keys on PT0; when the state cannot be read");
    Check([c releaseOwnedTX:nil] && !c.ownsTX,@"Digital released after the PT fallback");
}
static void TestCore(void) {
    TX500StationCore *c=[TX500StationCore new]; FakeStationRadio *r=[FakeStationRadio new]; c.transportFactory=^id(NSString *p){(void)p;return r;};
    Check([c selectOwner:@"Digital" port:@"fake" error:nil],@"Select owner without transmitting"); Check(r.commands.count==0,@"Selecting owner performs no CAT writes");
    Check(![c transmit:YES owner:@"Voice" error:nil],@"Inactive sender rejected"); Check(r.commands.count==0,@"Rejected sender sends nothing");
    Check([c transmit:NO owner:@"Digital" error:nil],@"Unowned release is harmless"); Check(r.commands.count==0,@"Unowned release sends no RX");
    Check([c transmit:YES owner:@"Digital" error:nil],@"PTT is verified"); Check(c.ownsTX,@"PTT ownership acquired"); Check([c.snapshot[@"tx"] boolValue],@"Confirmed TX updates the published snapshot");
    Check(![c selectOwner:@"Voice" port:@"fake" error:nil],@"Cannot steal TX ownership"); Check(![c tune:14285000 mode:2 owner:@"Digital" error:nil],@"Retune blocked in TX");
    Check([c query:@"PT;" error:nil]!=nil,@"Status subscribers can read during TX"); Check(![c query:@"RX;TX;" error:nil],@"Read-only path rejects mutations"); Check(![c query:@"TX;" error:nil] && ![c query:@"RX;" error:nil],@"Bare transmit commands are not queries");
    r.failRX=YES; Check(![c suspend:nil] && c.ownsTX,@"Unconfirmed RX retains ownership and port"); r.failRX=NO; Check([c suspend:nil] && !c.ownsTX,@"Confirmed RX permits handoff");
    [c selectOwner:@"Voice" port:@"fake" error:nil]; r.failTX=YES; Check(![c transmit:YES owner:@"Voice" error:nil] && c.ownsTX,@"Failed TX acknowledgement still owns cleanup"); Check([c releaseOwnedTX:nil],@"Failed TX can be safely released"); r.failTX=NO;
    r.state[@"tx"]=@1; NSUInteger before=r.commands.count; Check(![c transmit:YES owner:@"Voice" error:nil],@"External PTT blocks local TX"); Check([c releaseOwnedTX:nil] && r.commands.count==before,@"External PTT never dekeyed"); r.state[@"tx"]=@0;
    [c selectOwner:@"Station" port:@"fake" error:nil]; Check([c tune:14285000 mode:2 owner:@"Station" error:nil],@"Preset verified by readback"); Check([c.snapshot[@"frequency"] longLongValue]==14285000,@"Snapshot receives verified frequency");
    r.failTune=YES; Check(![c tune:7030000 mode:3 owner:@"Station" error:nil],@"Failed readback is surfaced"); r.failTune=NO;
    r.state[@"txVFO"]=@1; Check(![c tune:7030000 mode:3 owner:@"Station" error:nil],@"Split blocks preset tune"); r.state[@"txVFO"]=@0;
    r.state[@"vox"]=@1; Check(![c transmit:YES owner:@"Station" error:nil],@"VOX blocks app TX"); r.state[@"vox"]=@0;
    [c selectOwner:@"CW" port:@"fake" error:nil]; r.state[@"vox"]=@1; NSUInteger voxBefore=r.commands.count; NSError *voxError=nil;
    Check(![c transmit:YES owner:@"CW" error:&voxError] && !c.ownsTX && r.commands.count==voxBefore,@"VOX blocks CW TX and writes no TX;");
    Check([voxError.localizedDescription containsString:@"VOX"],@"The CW refusal names VOX");
    r.state[@"vox"]=@0; Check([c transmit:YES owner:@"CW" error:nil] && c.ownsTX,@"CW keys once VOX is off"); Check([c releaseOwnedTX:nil] && !c.ownsTX,@"CW VOX check leaves the release intact");
    [c selectOwner:@"Digital" port:@"fake" error:nil]; r.state[@"vox"]=@1; Check([c transmit:YES owner:@"Digital" error:nil],@"Digital keeps its VOX exemption (its setup clears VOX itself)"); r.state[@"vox"]=@0; Check([c releaseOwnedTX:nil] && !c.ownsTX,@"Digital VOX control released");
    [c selectOwner:@"CW" port:@"fake" error:nil]; Check([c send:@"KS022;KY CQ;" owner:@"CW" error:nil] && c.ownsTX,@"CW queue has exclusive TX ownership");
    Check(![c send:@"FA00014000000;" owner:@"Station" error:nil],@"Late command from old owner is rejected"); Check([c releaseOwnedTX:nil] && !c.ownsTX,@"CW release clears keying and RX");
    r.failKY=YES;
    Check(![c send:@"KY CQ;" owner:@"CW" error:nil] && c.ownsTX,@"Failed CW queue retains cleanup ownership");
    Check([c send:@"KY ;RX;" owner:@"CW" error:nil] && !c.ownsTX,@"CW abort confirms RX even when clearing the queue fails");
    Check(![c tune:100 mode:2 owner:@"CW" error:nil],@"Invalid RF frequency rejected");
    TestUnknownVOX();
}
static void TestReceiveRecoveryReconnect(void) {
    TX500StationCore *core=[TX500StationCore new];
    FakeStationRadio *stalled=[FakeStationRadio new];
    FakeStationRadio *reopened=[FakeStationRadio new];
    stalled.failRX=YES;
    __block NSUInteger opens=0;
    core.transportFactory=^id(NSString *path) { (void)path; return ++opens==1 ? stalled : reopened; };
    Check([core selectOwner:@"Digital" port:@"fake-reconnect" error:nil],@"Recovery fixture selects CAT port");
    Check([core transmit:YES owner:@"Digital" error:nil],@"Recovery fixture confirms initial TX");
    Check(![core transmit:NO owner:@"Digital" error:nil] && core.ownsTX,@"First missing RX acknowledgement keeps TX ownership");
    Check(![core transmit:NO owner:@"Digital" error:nil] && core.ownsTX && opens==2,
          @"Repeated missing RX acknowledgement reopens CAT without clearing TX fault");
    Check([stalled.commands containsObject:@"CLOSE"],@"Stale CAT descriptor is closed");
    Check([core transmit:NO owner:@"Digital" error:nil] && !core.ownsTX,
          @"Only a confirmed RX on reopened CAT clears TX ownership");
}
// A radio whose CAT replies get lost (RF on the USB cable, a garbled frame): query and readState
// return nil and a TX/RX write cannot be read back. The relay state is kept as the model's state.
@interface FakeSilentRadio : FakeStationRadio
@property BOOL silent;
@end
@implementation FakeSilentRadio
- (NSString *)query:(NSString *)q error:(NSError **)error { return self.silent ? nil : [super query:q error:error]; }
- (NSDictionary *)readState:(NSError **)error { return self.silent ? nil : [super readState:error]; }
- (BOOL)setTransmit:(BOOL)tx error:(NSError **)error { BOOL ok=[super setTransmit:tx error:error]; return self.silent ? NO : ok; }
@end
#import "Lab599SerialPort.h"
// A transport with read deadlines, as TX500VoiceCATRadio has: a meter read (RM...) gets no answer,
// so it waits its whole deadline unless its token is cancelled. The old form waits 0.8 s, as the
// real transport does. Every other query gets the parent's answer at once.
@interface FakeDeadlineRadio : FakeStationRadio
@property double lastTimeout;
@property NSUInteger meterReads,cancelledReads;
@end
@implementation FakeDeadlineRadio
- (NSString *)query:(NSString *)q error:(NSError **)error { return [self query:q timeout:0.8 cancellation:nil error:error]; }
- (NSString *)query:(NSString *)q timeout:(NSTimeInterval)timeout cancellation:(Lab599Cancellation *)token error:(NSError **)error {
    if(![q hasPrefix:@"RM"]) return [super query:q error:error];
    self.lastTimeout=timeout; self.meterReads++; double end=CFAbsoluteTimeGetCurrent()+timeout;
    while(CFAbsoluteTimeGetCurrent()<end) { if(token.cancelled) { self.cancelledReads++; return nil; } usleep(5000); }
    return nil;
}
@end
static void TestReadDeadline(void) {
    TX500StationCore *c=[TX500StationCore new]; FakeDeadlineRadio *r=[FakeDeadlineRadio new]; c.transportFactory=^id(NSString *p){(void)p;return r;};
    [c selectOwner:@"CW" port:@"fake-deadline" error:nil];
    double t0=CFAbsoluteTimeGetCurrent(); NSString *reply=[c query:@"RM0;RM;" timeout:0.1 error:nil];
    Check(!reply && CFAbsoluteTimeGetCurrent()-t0<0.3 && r.lastTimeout==0.1,@"A read honours the deadline it was given");
    Check(![c query:@"RM0;RM;" error:nil] && r.lastTimeout==0.8,@"The old form keeps 0.8 s");
    [c query:@"RM1;RM;" timeout:0.001 error:nil]; Check(r.lastTimeout==0.05,@"A deadline below 0.05 s is raised to 0.05 s");
    [c query:@"RM1;RM;" timeout:5 error:nil]; Check(r.lastTimeout==0.8,@"A deadline above 0.8 s is cut to 0.8 s");
    TX500StationCore *c2=[TX500StationCore new]; FakeStationRadio *r2=[FakeStationRadio new]; c2.transportFactory=^id(NSString *p){(void)p;return r2;};
    [c2 selectOwner:@"CW" port:@"fake-no-deadline" error:nil];
    Check([[c2 query:@"PT;" timeout:0.1 error:nil] isEqual:@"PT0;"],@"A transport without deadlines still works");
}
static void TestLostReplyKeepsTX(void) {
    TX500StationCore *c=[TX500StationCore new]; FakeSilentRadio *r=[FakeSilentRadio new]; c.transportFactory=^id(NSString *p){(void)p;return r;};
    Check([c selectOwner:@"CW" port:@"fake-silent" error:nil] && [c transmit:YES owner:@"CW" error:nil] && c.ownsTX,@"Silent-radio fixture keys CW");
    r.silent=YES;
    Check(![c selectOwner:@"Station" port:@"fake-silent" error:nil] && c.ownsTX && [c.owner isEqual:@"CW"],@"A lost PT reply does not hand the radio to another owner");
    NSUInteger before=r.commands.count;
    Check(![c releaseOwnedTX:nil] && c.ownsTX && r.commands.count>before && [r.commands.lastObject isEqual:@"RX;"],@"A lost PT reply is not taken as RX: RX; is written and ownership kept");
    Check(![c suspend:nil] && c.ownsTX,@"Quit and handoff stay refused while RX is unconfirmed");
    Check(![c transmit:YES owner:@"CW" error:nil],@"No new TX while RX is unconfirmed");
    r.silent=NO; r.state[@"tx"]=@1;
    Check([c releaseOwnedTX:nil] && !c.ownsTX,@"RX confirmed once the radio answers again");
    TX500StationCore *c2=[TX500StationCore new]; FakeSilentRadio *r2=[FakeSilentRadio new]; c2.transportFactory=^id(NSString *p){(void)p;return r2;};
    [c2 selectOwner:@"CW" port:@"fake-silent-2" error:nil]; r2.silent=YES;
    Check(![c2 transmit:NO owner:@"CW" error:nil] && [r2.commands containsObject:@"RX;"] && c2.ownsTX,@"An unowned RX with no PT reply forces RX; and keeps the fault");
    r2.silent=NO; Check([c2 transmit:NO owner:@"CW" error:nil] && !c2.ownsTX,@"The unowned RX clears once PT0 is read");
    TX500StationCore *c3=[TX500StationCore new]; FakeSilentRadio *r3=[FakeSilentRadio new]; c3.transportFactory=^id(NSString *p){(void)p;return r3;};
    [c3 selectOwner:@"Digital" port:@"fake-silent-3" error:nil]; r3.silent=YES; // Digital: the only owner the PT fallback can key
    Check(![c3 transmit:YES owner:@"Digital" error:nil] && ![r3.commands containsObject:@"TX;"],@"TX refused when the radio state and PT cannot be read");
    TestReadDeadline();
}
static void TestStore(NSURL *root) {
    NSString *suite=NSUUID.UUID.UUIDString; NSUserDefaults *d=[[NSUserDefaults alloc] initWithSuiteName:suite]; [d setObject:@"K1ABC" forKey:@"TX500_OperatorCallsign"]; [d setObject:@"FN42" forKey:@"TX500_OperatorGrid"];
    NSURL *url=[root URLByAppendingPathComponent:@"station.json"]; TX500StationStore *s=[[TX500StationStore alloc] initWithURL:url defaults:d];
    Check([s.activeProfile[@"call"] isEqual:@"K1ABC"],@"Migrate saved identity without replacing it");
    NSMutableDictionary *p=[s.activeProfile mutableCopy]; p[@"name"]=@"Portable"; p[@"operatorCall"]=@"W1XYZ"; p[@"grid"]=@"FN42AB"; p[@"cqZone"]=@"5"; p[@"ituZone"]=@"8";
    Check([s saveProfile:p activate:YES error:nil],@"Save validated profile atomically"); Check([[d dictionaryForKey:@"TX500_ActiveStationProfile"][@"operatorCall"] isEqual:@"W1XYZ"],@"Separate station and operator identity exported");
    NSData *original=[NSData dataWithContentsOfURL:url]; p[@"grid"]=@"XX99"; Check(![s saveProfile:p activate:YES error:nil],@"Invalid grid rejected"); Check([original isEqual:[NSData dataWithContentsOfURL:url]],@"Invalid profile leaves disk unchanged"); p[@"grid"]=@"FN42"; p[@"cqZone"]=@"41"; Check(![s saveProfile:p activate:YES error:nil],@"CQ zone validated");
    uint64_t hz=0; Check([TX500StationStore parseMHz:@"14.074000" hertz:&hz] && hz==14074000,@"Exact MHz conversion");
    for(NSString *text in @[@"nan",@"14.074junk",@"56.1",@"0.4",@"1;TX;",@"14,074"]) Check(![TX500StationStore parseMHz:text hertz:nil],@"Reject malformed frequency");
    NSDictionary *f=@{@"id":@"stable-id",@"name":@"Evening",@"hz":@7074000,@"mode":@6,@"tags":@"portable",@"favorite":@YES}; NSUInteger n=s.frequencies.count;
    Check([s saveFrequency:f error:nil] && s.frequencies.count==n+1,@"Add local frequency"); Check([s saveFrequency:f error:nil] && s.frequencies.count==n+1,@"Editing preserves identifier, no duplicates");
    Check([s removeFrequency:@"stable-id" error:nil] && s.frequencies.count==n,@"Remove local frequency only");
    Check(![s setShortcut:@"1" command:@"read" error:nil],@"Shortcut collision rejected"); Check([s setShortcut:@"x" command:@"read" error:nil],@"Reassign command shortcut");
    TX500StationStore *loaded=[[TX500StationStore alloc] initWithURL:url defaults:d]; Check([loaded.activeProfile[@"operatorCall"] isEqual:@"W1XYZ"],@"Profile roundtrip"); Check([loaded.shortcuts[@"read"] isEqual:@"x"],@"Shortcut roundtrip");
    Check(![s removeProfile:s.activeProfile[@"id"] error:nil],@"Cannot delete active profile");
    Check([TX500StationStore segmentsAt:14074000].count==1,@"FT8 spectrum locates digital segment"); Check([TX500StationStore segmentsAt:14099000].count==1 && [[TX500StationStore segmentsAt:14099000][0][@"usage"] containsString:@"Beacons"],@"Band boundary is half-open");
    Check([TX500StationStore segmentsAt:5366500].count==0,@"Upper edge is excluded");
    [@"broken" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil]; loaded=[[TX500StationStore alloc] initWithURL:url defaults:d]; Check(loaded.loadError!=nil && ![loaded saveFrequency:f error:nil],@"Corrupt store is preserved, never overwritten");
    NSDictionary *invalid=@{@"version":@1,@"active":@"missing",@"profiles":@[],@"frequencies":@[],@"shortcuts":@{}};
    [[NSJSONSerialization dataWithJSONObject:invalid options:0 error:nil] writeToURL:url atomically:YES];
    loaded=[[TX500StationStore alloc] initWithURL:url defaults:d]; Check(loaded.loadError!=nil,@"Missing active profile is rejected without overwriting storage");
    [d removePersistentDomainForName:suite];
}
static uint16_t Get16(const uint8_t *b) { return ((uint16_t)b[0]<<8)|b[1]; }
static uint32_t Get32(const uint8_t *b) { return ((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|((uint32_t)b[2]<<8)|b[3]; }
static void TestReporter(void) {
    NSDictionary *r=@{@"call":@"K1ABC",@"grid":@"FN42",@"antenna":@"Dipole",@"rig":@"Lab599 TX-500"}; NSDictionary *s=@{@"call":@"W1AW",@"grid":@"FN31",@"hz":@14074500,@"mode":@"FT8",@"time":@1700000000};
    NSData *p=[TX500PSKReporter packetForReceiver:r spots:@[s] timestamp:1700000001 sequence:7 domain:42]; Check(p!=nil,@"Encode IPFIX packet"); const uint8_t *b=p.bytes;
    Check(Get16(b)==10 && Get16(b+2)==p.length,@"IPFIX version and network-order length"); Check(Get32(b+4)==1700000001 && Get32(b+8)==7 && Get32(b+12)==42,@"UTC, record sequence and stream ID");
    NSUInteger offset=16; NSArray *ids=@[@3,@2,@0x9992,@0x9993]; NSArray *lens=@[@52,@52,@0,@0];
    for(NSUInteger i=0;i<4;i++) { Check(offset+4<=p.length && Get16(b+offset)==[ids[i] intValue],@"Template and data set order"); uint16_t len=Get16(b+offset+2); Check(len>=4 && offset+len<=p.length && len%4==0,@"Bounded padded set"); if([lens[i] intValue]) Check(len==[lens[i] intValue],@"Official descriptor lengths"); offset+=len; }
    Check(offset==p.length,@"No trailing or truncated records");
    NSData *freq=[NSData dataWithBytes:(uint8_t[]){0x00,0xd6,0xc2,0x84} length:4]; // 14,074,500 Hz, big endian
    Check([p rangeOfData:freq options:0 range:NSMakeRange(0,p.length)].location!=NSNotFound,@"RF frequency is sent in Hz, not MHz or dial alone");
    NSData *rig=[@"Lab599 TX-500" dataUsingEncoding:NSUTF8StringEncoding];
    Check([p rangeOfData:rig options:0 range:NSMakeRange(0,p.length)].location!=NSNotFound,
          @"Receiver record explicitly reports Lab599 TX-500 as rigInformation");
    Check(![TX500PSKReporter packetForReceiver:@{@"call":@"",@"grid":@"FN42"} spots:@[s] timestamp:0 sequence:0 domain:0],@"Missing receiver identity rejected");
    NSMutableDictionary *bad=[s mutableCopy]; bad[@"call"]=@"<...>"; Check(![TX500PSKReporter packetForReceiver:r spots:@[bad] timestamp:0 sequence:0 domain:0],@"Unresolved hashed callsign is not reported");
    TX500PSKReporter *reporter=[TX500PSKReporter new]; reporter.sender=^BOOL(NSData *data,NSError **error){(void)data;(void)error; Check(NO,@"Tests must not emit a network report");return NO;};
    [reporter enqueue:s receiver:r]; Check(reporter.pendingCount==0,@"Reporting is opt-in"); reporter.enabled=YES; [reporter enqueue:s receiver:r]; [reporter enqueue:s receiver:r]; Check(reporter.pendingCount==1,@"Duplicate call per band/mode suppressed"); reporter.enabled=NO; Check(reporter.pendingCount==0,@"Disabling clears unsent data");
    __block NSUInteger packets=0, records=0; __block BOOL fail=YES;
    reporter.sender=^BOOL(NSData *data,NSError **error) {
        (void)error; Check(data.length<=1400,@"Batches respect the datagram size budget");
        if(fail) return NO;
        const uint8_t *bytes=data.bytes; Check(Get32(bytes+8)==records,@"Successful packets advance the sequence by report count");
        NSUInteger pos=16; for(int i=0;i<3;i++) pos+=Get16(bytes+pos+2);
        NSUInteger end=pos+Get16(bytes+pos+2); pos+=4;
        while(pos<end && bytes[pos]) { pos+=1+bytes[pos]+4; pos+=1+bytes[pos]+1; pos+=1+bytes[pos]+4; records++; }
        packets++; return YES;
    };
    reporter.enabled=YES;
    NSDictionary *longReceiver=@{@"call":@"K1ABC",@"grid":@"FN42",@"antenna":[@"A" stringByPaddingToLength:254 withString:@"A" startingAtIndex:0]};
    for(int i=0;i<45;i++) { NSMutableDictionary *spot=[s mutableCopy]; spot[@"call"]=[NSString stringWithFormat:@"W%030dA",i]; spot[@"grid"]=@"FN31AA00"; [reporter enqueue:spot receiver:longReceiver]; }
    Check(reporter.pendingCount==45,@"Long but valid reports queue successfully");
    // Make the flush due relative to this machine's uptime. A fresh CI runner
    // may have been up for less than 300 seconds, so lastFlush=0 is not due.
    NSNumber *flushDue=@(NSProcessInfo.processInfo.systemUptime-301.0);
    [reporter setValue:flushDue forKey:@"lastFlush"]; [reporter flush]; Check(reporter.pendingCount==45,@"Failed UDP submission retains queued reports");
    fail=NO; [reporter setValue:flushDue forKey:@"lastFlush"]; [reporter flush];
    Check(reporter.pendingCount==0 && packets>=3 && records==45,@"Oversized batch splits without losing or duplicating reports");
    reporter.enabled=NO;

}
int main(int argc,const char *argv[]) { @autoreleasepool { (void)argc;(void)argv; char path[]="/tmp/StationTests.XXXXXX"; Check(mkdtemp(path)!=NULL,@"Isolated test directory"); NSURL *root=[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]]; TestCore(); TestReceiveRecoveryReconnect(); TestLostReplyKeepsTX(); TestStore(root); TestReporter();
    for (NSString *region in @[@"1", @"2", @"3"]) {
        NSURL *url=TX500BandPlanURLForRegion(region);
        Check([url.scheme isEqualToString:@"https"] && [url.host hasPrefix:@"www.iaru"], @"Official region document uses a fixed IARU HTTPS URL");
        Check([url.absoluteString containsString:[NSString stringWithFormat:@"Region-%@", region]] || [region isEqualToString:@"1"], @"Region selects its own document");
    }
    Check([TX500BandPlanURLForRegion(@"https://example.com").host isEqualToString:@"www.iaru-r1.org"], @"Unknown profile text cannot choose an arbitrary URL");
    if([NSProcessInfo.processInfo.arguments containsObject:@"--render"]) { setenv("TX500_STATION_TEST_ROOT",path,1); [NSApplication sharedApplication];
        for(NSNumber *width in @[@940,@560]) for(NSNumber *tab in @[@0,@1,@2,@3]) {
            TX500StationController *c=[TX500StationController new]; c.core=[TX500StationCore new]; NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,width.doubleValue,1100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO]; w.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]; w.contentView=c.view;
            NSSegmentedControl *tabs=[c valueForKey:@"tabs"]; tabs.selectedSegment=tab.integerValue; [c performSelector:@selector(tabChanged:) withObject:nil]; [c activate]; [w layoutIfNeeded]; [c.view layoutSubtreeIfNeeded];
            Check(!c.view.hasAmbiguousLayout,@"Station pane has determinate layout");
            if(tab.integerValue<2) {
                NSTableView *table=[c valueForKey:tab.integerValue==0 ? @"table" : @"bandTable"];
                CGFloat total=0; for(NSTableColumn *column in table.tableColumns) total+=column.width;
                Check(total<=table.enclosingScrollView.contentView.bounds.size.width+3,@"All table columns fit the compact pane");
            }
            NSBitmapImageRep *rep=[c.view bitmapImageRepForCachingDisplayInRect:c.view.bounds]; [c.view cacheDisplayInRect:c.view.bounds toBitmapImageRep:rep]; [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithFormat:@"validation/station-%@-%@.png",width,tab] atomically:YES];
        }
    }
    fprintf(stdout,"PASS: %lu Station checks; no hardware or network transmissions.\n",(unsigned long)checks); [NSFileManager.defaultManager removeItemAtURL:root error:nil];
} return 0; }
