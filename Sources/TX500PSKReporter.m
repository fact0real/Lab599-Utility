#import "TX500PSKReporter.h"
#import <netdb.h>
#import <sys/socket.h>
#import <unistd.h>
#import <errno.h>
NSString *const TXPSKReporterChanged=@"TXPSKReporterChanged";
static void U16(NSMutableData *d,uint16_t v) { v=htons(v); [d appendBytes:&v length:2]; }
static void U32(NSMutableData *d,uint32_t v) { v=htonl(v); [d appendBytes:&v length:4]; }
static BOOL TextField(NSMutableData *d,NSString *s) { NSData *b=[s dataUsingEncoding:NSUTF8StringEncoding]; if(b.length>254) return NO; uint8_t n=(uint8_t)b.length; [d appendBytes:&n length:1]; [d appendData:b]; return YES; }
static void Pad(NSMutableData *d) { uint8_t z=0; while(d.length%4) [d appendBytes:&z length:1]; }
static void Length(NSMutableData *d,NSUInteger offset,uint16_t n) { n=htons(n); [d replaceBytesInRange:NSMakeRange(offset,2) withBytes:&n]; }
static BOOL ValidCall(NSString *s) { return [s isKindOfClass:NSString.class] && s.length>=3 && s.length<=32 && [s rangeOfString:@"^[A-Z0-9]+(/[A-Z0-9]+)*$" options:NSRegularExpressionSearch].location!=NSNotFound && [s rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet].location!=NSNotFound; }
static BOOL ValidGrid(NSString *s) { return [s isKindOfClass:NSString.class] && [s rangeOfString:@"^[A-Ra-r]{2}[0-9]{2}([A-Xa-x]{2}([0-9]{2})?)?$" options:NSRegularExpressionSearch].location!=NSNotFound; }
@implementation TX500PSKReporter {
    dispatch_queue_t _queue; dispatch_source_t _timer;
    NSMutableArray *_pending; NSMutableDictionary *_seen;
    NSString *_status; BOOL _enabled; uint32_t _sequence,_domain;
    double _lastFlush;
}
+ (instancetype)sharedReporter { static id p; static dispatch_once_t once; dispatch_once(&once, ^{ p=[self new]; }); return p; }
- (instancetype)init { if((self=[super init])) { _queue=dispatch_queue_create("ir.factoreal.station.psk",DISPATCH_QUEUE_SERIAL); _pending=[NSMutableArray array]; _seen=[NSMutableDictionary dictionary]; _status=@"Reporting off"; _domain=arc4random(); _lastFlush=NSProcessInfo.processInfo.systemUptime;
    _timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_queue); dispatch_source_set_timer(_timer,dispatch_time(DISPATCH_TIME_NOW,(305+arc4random_uniform(15))*NSEC_PER_SEC),305*NSEC_PER_SEC,5*NSEC_PER_SEC);
    __weak typeof(self) weakSelf=self; dispatch_source_set_event_handler(_timer, ^{ [weakSelf sendPending]; }); dispatch_resume(_timer);
} return self; }
- (void)dealloc { if(_timer) dispatch_source_cancel(_timer); }
- (void)update:(NSString *)s { @synchronized(self) { _status=[s copy]; } dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:TXPSKReporterChanged object:self]; }); }
- (NSString *)status { @synchronized(self) { return _status; } }
- (BOOL)enabled { @synchronized(self) { return _enabled; } }
- (void)setEnabled:(BOOL)v { @synchronized(self) { if(_enabled==v) return; _enabled=v; } dispatch_async(_queue, ^{ if(!v) { [self->_pending removeAllObjects]; [self->_seen removeAllObjects]; } [self update:v ? @"Reporting enabled • waiting for real decodes" : @"Reporting off"]; }); }
- (NSUInteger)pendingCount { __block NSUInteger n; dispatch_sync(_queue, ^{ n=self->_pending.count; }); return n; }
+ (NSData *)packetForReceiver:(NSDictionary *)receiver spots:(NSArray *)spots timestamp:(uint32_t)timestamp sequence:(uint32_t)sequence domain:(uint32_t)domain {
    if(!ValidCall(receiver[@"call"]) || !ValidGrid(receiver[@"grid"]) || !spots.count) return nil;
    NSMutableData *d=[NSMutableData data]; U16(d,10); U16(d,0); U32(d,timestamp); U32(d,sequence); U32(d,domain);
    // Options template: receiver call, locator, decoder software, antenna and
    // rig information (enterprise 30351).  Field 13 is required explicitly;
    // omitting it lets PSK Reporter retain a stale rig name from another
    // reporting application used by the same callsign.
    U16(d,3); U16(d,52); U16(d,0x9992); U16(d,5); U16(d,1);
    for(NSNumber *field in @[@2,@4,@8,@9,@13]) { U16(d,0x8000|field.unsignedShortValue); U16(d,65535); U32(d,30351); } U16(d,0);
    // Sender template: call, uint32 frequency, mode, source, locator, Unix time.
    U16(d,2); U16(d,52); U16(d,0x9993); U16(d,6);
    for(NSArray *field in @[@[@1,@65535],@[@5,@4],@[@10,@65535],@[@11,@1],@[@3,@65535]]) { U16(d,0x8000|[field[0] unsignedShortValue]); U16(d,[field[1] unsignedShortValue]); U32(d,30351); } U16(d,150); U16(d,4);
    NSUInteger base=d.length; U16(d,0x9992); U16(d,0);
    NSString *rig = [receiver[@"rig"] isKindOfClass:NSString.class] && [receiver[@"rig"] length] > 0
        ? receiver[@"rig"] : @"Lab599 TX-500";
    for(NSString *s in @[receiver[@"call"],receiver[@"grid"],@"Lab599 Utility",receiver[@"antenna"] ?: @"",rig]) if(!TextField(d,s)) return nil;
    Pad(d); Length(d,base+2,(uint16_t)(d.length-base)); base=d.length; U16(d,0x9993); U16(d,0);
    for(NSDictionary *s in spots) {
        uint64_t hz=[s[@"hz"] unsignedLongLongValue];
        if(!ValidCall(s[@"call"]) || hz<500000 || hz>56000000 || ![@[@"FT8",@"FT4"] containsObject:s[@"mode"]] || ![s[@"time"] isKindOfClass:NSNumber.class]) return nil;
        if(!TextField(d,s[@"call"])) return nil; U32(d,(uint32_t)hz); TextField(d,s[@"mode"]); uint8_t source=1; [d appendBytes:&source length:1];
        TextField(d,ValidGrid(s[@"grid"]) ? s[@"grid"] : @""); U32(d,[s[@"time"] unsignedIntValue]);
    }
    Pad(d); if(d.length>1400) return nil; Length(d,base+2,(uint16_t)(d.length-base)); Length(d,2,(uint16_t)d.length); return d;
}
- (void)enqueue:(NSDictionary *)spot receiver:(NSDictionary *)receiver {
    if(!self.enabled || ![self.class packetForReceiver:receiver spots:@[spot] timestamp:0 sequence:0 domain:0]) return;
    NSDictionary *copy=[spot copy],*identity=[receiver copy];
    dispatch_async(_queue, ^{
        if(!self.enabled) return;
        double now=NSProcessInfo.processInfo.systemUptime;
        // Deduplicate a callsign/mode within a band for five minutes. Timestamp
        // and dial frequency were captured with the decode, never read later.
        uint64_t hz=[copy[@"hz"] unsignedLongLongValue];
        NSArray *edges=@[@2000000,@4000000,@6000000,@8000000,@11000000,@15000000,@19000000,@22000000,@25000000,@30000000,@56000001];
        NSInteger band=0; while(band<(NSInteger)edges.count && hz>=[edges[band] unsignedLongLongValue]) band++;
        NSString *key=[NSString stringWithFormat:@"%@/%@/%@/%@/%ld",identity[@"call"],identity[@"grid"],copy[@"call"],copy[@"mode"],(long)band];
        NSNumber *previous=self->_seen[key]; if(previous && now-previous.doubleValue<300) return;
        for(NSString *old in self->_seen.allKeys) if(now-[self->_seen[old] doubleValue]>600) [self->_seen removeObjectForKey:old];
        if(self->_pending.count>=256) { [self update:@"Report queue full • oldest unsent report dropped"]; [self->_pending removeObjectAtIndex:0]; }
        self->_seen[key]=@(now); [self->_pending addObject:@{@"spot":copy,@"receiver":identity}];
        [self update:[NSString stringWithFormat:@"%lu reports queued • next batch within 5 minutes",(unsigned long)self->_pending.count]];
    });
}
- (void)flush { dispatch_async(_queue, ^{ if(NSProcessInfo.processInfo.systemUptime-self->_lastFlush>=300) [self sendPending]; }); }
- (BOOL)sendPacket:(NSData *)packet error:(NSError **)error {
    if(self.sender) return self.sender(packet,error);
    struct addrinfo hints={0},*addresses=NULL; hints.ai_socktype=SOCK_DGRAM; hints.ai_family=AF_UNSPEC;
    int code=getaddrinfo("report.pskreporter.info","4739",&hints,&addresses); BOOL ok=NO;
    if(!code) { for(struct addrinfo *a=addresses;a;a=a->ai_next) { int fd=socket(a->ai_family,a->ai_socktype,a->ai_protocol); if(fd<0) continue; ssize_t sent=sendto(fd,packet.bytes,packet.length,0,a->ai_addr,a->ai_addrlen); close(fd); if(sent==(ssize_t)packet.length) { ok=YES; break; } } freeaddrinfo(addresses); }
    if(!ok && error) *error=[NSError errorWithDomain:@"TXPSKReporter" code:code ?: errno userInfo:@{NSLocalizedDescriptionKey:@"UDP submission failed; queued reports retained"}]; return ok;
}
- (void)sendPending {
    if(!self.enabled || !_pending.count) return; _lastFlush=NSProcessInfo.processInfo.systemUptime;
    NSUInteger total=0;
    while(_pending.count && self.enabled) {
        NSDictionary *receiver=_pending.firstObject[@"receiver"]; NSMutableArray *spots=[NSMutableArray array]; NSUInteger count=0;
        NSData *packet=nil;
        for(NSDictionary *entry in _pending) {
            if(![entry[@"receiver"] isEqual:receiver] || count>=20) break;
            [spots addObject:entry[@"spot"]];
            NSData *candidate=[self.class packetForReceiver:receiver spots:spots timestamp:(uint32_t)NSDate.date.timeIntervalSince1970 sequence:_sequence domain:_domain];
            if(!candidate) break;
            packet=candidate; count++;
        }
        NSError *e=nil;
        if(!packet || ![self sendPacket:packet error:&e]) { [self update:e.localizedDescription ?: @"Report encoding failed"]; return; }
        _sequence+=(uint32_t)count; total+=count; [_pending removeObjectsInRange:NSMakeRange(0,count)];
    }
    [self update:[NSString stringWithFormat:@"%lu reports submitted via UDP • server receipt is not acknowledged",(unsigned long)total]];
}
@end
