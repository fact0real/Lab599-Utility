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
@property BOOL failTX,failRX,failTune;
@end
@implementation FakeStationRadio
- (instancetype)init { if((self=[super init])) { _state=[@{@"frequency":@14074000,@"mode":@6,@"rxVFO":@0,@"txVFO":@0,@"xit":@0,@"vox":@0,@"tx":@0} mutableCopy]; _commands=[NSMutableArray array]; } return self; }
- (NSDictionary *)readState:(NSError **)error { (void)error; return self.state.copy; }
- (BOOL)setTransmit:(BOOL)tx error:(NSError **)error { (void)error; [self.commands addObject:tx?@"TX;":@"RX;"]; if(tx) self.state[@"tx"]=@1; if((tx && self.failTX)||(!tx && self.failRX)) return NO; self.state[@"tx"]=@(tx); return YES; }
- (NSString *)query:(NSString *)q error:(NSError **)error { (void)error; if([q isEqual:@"PT;"]) return [NSString stringWithFormat:@"PT%@;",self.state[@"tx"]]; return @"FA00014074000;"; }
- (BOOL)send:(NSString *)c error:(NSError **)error { (void)error; [self.commands addObject:c]; if([c hasPrefix:@"FA"] && !self.failTune) { NSArray *parts=[c componentsSeparatedByString:@";"]; self.state[@"frequency"]=@([[parts[0] substringFromIndex:2] longLongValue]); if(parts.count>1 && [parts[1] hasPrefix:@"MD"]) self.state[@"mode"]=@([[parts[1] substringFromIndex:2] integerValue]); } return YES; }
- (void)close { [self.commands addObject:@"CLOSE"]; }
@end
static void TestCore(void) {
    TX500StationCore *c=[TX500StationCore new]; FakeStationRadio *r=[FakeStationRadio new]; c.transportFactory=^id(NSString *p){(void)p;return r;};
    Check([c selectOwner:@"Digital" port:@"fake" error:nil],@"Select owner without transmitting"); Check(r.commands.count==0,@"Selecting owner performs no CAT writes");
    Check(![c transmit:YES owner:@"Voice" error:nil],@"Inactive sender rejected"); Check(r.commands.count==0,@"Rejected sender sends nothing");
    Check([c transmit:NO owner:@"Digital" error:nil],@"Unowned release is harmless"); Check(r.commands.count==0,@"Unowned release sends no RX");
    Check([c transmit:YES owner:@"Digital" error:nil],@"PTT is verified"); Check(c.ownsTX,@"PTT ownership acquired");
    Check(![c selectOwner:@"Voice" port:@"fake" error:nil],@"Cannot steal TX ownership"); Check(![c tune:14285000 mode:2 owner:@"Digital" error:nil],@"Retune blocked in TX");
    Check([c query:@"PT;" error:nil]!=nil,@"Status subscribers can read during TX"); Check(![c query:@"RX;TX;" error:nil],@"Read-only path rejects mutations"); Check(![c query:@"TX;" error:nil] && ![c query:@"RX;" error:nil],@"Bare transmit commands are not queries");
    r.failRX=YES; Check(![c suspend:nil] && c.ownsTX,@"Unconfirmed RX retains ownership and port"); r.failRX=NO; Check([c suspend:nil] && !c.ownsTX,@"Confirmed RX permits handoff");
    [c selectOwner:@"Voice" port:@"fake" error:nil]; r.failTX=YES; Check(![c transmit:YES owner:@"Voice" error:nil] && c.ownsTX,@"Failed TX acknowledgement still owns cleanup"); Check([c releaseOwnedTX:nil],@"Failed TX can be safely released"); r.failTX=NO;
    r.state[@"tx"]=@1; NSUInteger before=r.commands.count; Check(![c transmit:YES owner:@"Voice" error:nil],@"External PTT blocks local TX"); Check([c releaseOwnedTX:nil] && r.commands.count==before,@"External PTT never dekeyed"); r.state[@"tx"]=@0;
    [c selectOwner:@"Station" port:@"fake" error:nil]; Check([c tune:14285000 mode:2 owner:@"Station" error:nil],@"Preset verified by readback"); Check([c.snapshot[@"frequency"] longLongValue]==14285000,@"Snapshot receives verified frequency");
    r.failTune=YES; Check(![c tune:7030000 mode:3 owner:@"Station" error:nil],@"Failed readback is surfaced"); r.failTune=NO;
    r.state[@"txVFO"]=@1; Check(![c tune:7030000 mode:3 owner:@"Station" error:nil],@"Split blocks preset tune"); r.state[@"txVFO"]=@0;
    r.state[@"vox"]=@1; Check(![c transmit:YES owner:@"Station" error:nil],@"VOX blocks app TX"); r.state[@"vox"]=@0;
    [c selectOwner:@"CW" port:@"fake" error:nil]; Check([c send:@"KS022;KY CQ;" owner:@"CW" error:nil] && c.ownsTX,@"CW queue has exclusive TX ownership");
    Check(![c send:@"FA00014000000;" owner:@"Station" error:nil],@"Late command from old owner is rejected"); Check([c releaseOwnedTX:nil] && !c.ownsTX,@"CW release clears keying and RX");
    Check(![c tune:100 mode:2 owner:@"CW" error:nil],@"Invalid RF frequency rejected");
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
    [d removePersistentDomainForName:suite];
}
static uint16_t Get16(const uint8_t *b) { return ((uint16_t)b[0]<<8)|b[1]; }
static uint32_t Get32(const uint8_t *b) { return ((uint32_t)b[0]<<24)|((uint32_t)b[1]<<16)|((uint32_t)b[2]<<8)|b[3]; }
static void TestReporter(void) {
    NSDictionary *r=@{@"call":@"K1ABC",@"grid":@"FN42",@"antenna":@"Dipole"}; NSDictionary *s=@{@"call":@"W1AW",@"grid":@"FN31",@"hz":@14074500,@"mode":@"FT8",@"time":@1700000000};
    NSData *p=[TX500PSKReporter packetForReceiver:r spots:@[s] timestamp:1700000001 sequence:7 domain:42]; Check(p!=nil,@"Encode IPFIX packet"); const uint8_t *b=p.bytes;
    Check(Get16(b)==10 && Get16(b+2)==p.length,@"IPFIX version and network-order length"); Check(Get32(b+4)==1700000001 && Get32(b+8)==7 && Get32(b+12)==42,@"UTC, record sequence and stream ID");
    NSUInteger offset=16; NSArray *ids=@[@3,@2,@0x9992,@0x9993]; NSArray *lens=@[@44,@52,@0,@0];
    for(NSUInteger i=0;i<4;i++) { Check(offset+4<=p.length && Get16(b+offset)==[ids[i] intValue],@"Template and data set order"); uint16_t len=Get16(b+offset+2); Check(len>=4 && offset+len<=p.length && len%4==0,@"Bounded padded set"); if([lens[i] intValue]) Check(len==[lens[i] intValue],@"Official descriptor lengths"); offset+=len; }
    Check(offset==p.length,@"No trailing or truncated records");
    NSData *freq=[NSData dataWithBytes:(uint8_t[]){0x00,0xd6,0xc2,0x84} length:4]; // 14,074,500 Hz, big endian
    Check([p rangeOfData:freq options:0 range:NSMakeRange(0,p.length)].location!=NSNotFound,@"RF frequency is sent in Hz, not MHz or dial alone");
    Check(![TX500PSKReporter packetForReceiver:@{@"call":@"",@"grid":@"FN42"} spots:@[s] timestamp:0 sequence:0 domain:0],@"Missing receiver identity rejected");
    NSMutableDictionary *bad=[s mutableCopy]; bad[@"call"]=@"<...>"; Check(![TX500PSKReporter packetForReceiver:r spots:@[bad] timestamp:0 sequence:0 domain:0],@"Unresolved hashed callsign is not reported");
    TX500PSKReporter *reporter=[TX500PSKReporter new]; reporter.sender=^BOOL(NSData *data,NSError **error){(void)data;(void)error; Check(NO,@"Tests must not emit a network report");return NO;};
    [reporter enqueue:s receiver:r]; Check(reporter.pendingCount==0,@"Reporting is opt-in"); reporter.enabled=YES; [reporter enqueue:s receiver:r]; [reporter enqueue:s receiver:r]; Check(reporter.pendingCount==1,@"Duplicate call per band/mode suppressed"); reporter.enabled=NO; Check(reporter.pendingCount==0,@"Disabling clears unsent data");
}
int main(int argc,const char *argv[]) { @autoreleasepool { (void)argc;(void)argv; char path[]="/tmp/StationTests.XXXXXX"; Check(mkdtemp(path)!=NULL,@"Isolated test directory"); NSURL *root=[NSURL fileURLWithPath:[NSString stringWithUTF8String:path]]; TestCore(); TestStore(root); TestReporter();
    if([NSProcessInfo.processInfo.arguments containsObject:@"--render"]) { setenv("TX500_STATION_TEST_ROOT",path,1); [NSApplication sharedApplication];
        for(NSNumber *width in @[@940,@560]) for(NSNumber *tab in @[@0,@1,@2,@3]) {
            TX500StationController *c=[TX500StationController new]; c.core=[TX500StationCore new]; NSWindow *w=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,width.doubleValue,1100) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO]; w.appearance=[NSAppearance appearanceNamed:NSAppearanceNameDarkAqua]; w.contentView=c.view;
            NSSegmentedControl *tabs=[c valueForKey:@"tabs"]; tabs.selectedSegment=tab.integerValue; [c performSelector:@selector(tabChanged:) withObject:nil]; [c activate]; [w layoutIfNeeded]; [c.view layoutSubtreeIfNeeded];
            Check(!c.view.hasAmbiguousLayout,@"Station pane has determinate layout");
            NSBitmapImageRep *rep=[c.view bitmapImageRepForCachingDisplayInRect:c.view.bounds]; [c.view cacheDisplayInRect:c.view.bounds toBitmapImageRep:rep]; [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:[NSString stringWithFormat:@"validation/station-%@-%@.png",width,tab] atomically:YES];
        }
    }
    fprintf(stdout,"PASS: %lu Station checks; no hardware or network transmissions.\n",(unsigned long)checks); [NSFileManager.defaultManager removeItemAtURL:root error:nil];
} return 0; }
