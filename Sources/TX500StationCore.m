#import "TX500StationCore.h"
#import "Lab599SerialPort.h"
NSString *const TXStationRadioChanged=@"TXStationRadioChanged";
@interface TX500StationVoiceAdapter : NSObject <TX500VoiceRadio>
@property(nonatomic,strong) TX500StationCore *core;
@end
@implementation TX500StationCore {
    NSRecursiveLock *_lock;
    TX500VoiceCATRadio *_transport;
    NSString *_port, *_owner, *_status;
    NSDictionary *_snapshot, *_published;
    BOOL _ownsTX, _faulted;
    NSUInteger _queryCount, _failureCount;
    double _lastLatency;
}
- (instancetype)init { if((self=[super init])) { _lock=[NSRecursiveLock new]; _owner=@""; _port=@""; _status=@"Disconnected"; _snapshot=@{}; [self cacheState]; } return self; }
// UI readers never wait behind serial I/O. Publish immutable diagnostic snapshots
// under a separate short lock; command decisions still use the transport lock.
- (void)cacheState {
    @synchronized(self) { _published=@{@"owner":_owner ?: @"",@"status":_status ?: @"",@"snapshot":[_snapshot copy] ?: @{},@"ownsTX":@(_ownsTX),@"queries":@(_queryCount),@"failures":@(_failureCount),@"latency":@(_lastLatency)}; }
}
- (id)cached:(NSString *)key { @synchronized(self) { return _published[key]; } }
- (NSString *)owner { return [self cached:@"owner"]; }
- (NSString *)status { return [self cached:@"status"]; }
- (NSDictionary *)snapshot { return [self cached:@"snapshot"]; }
- (BOOL)ownsTX { return [[self cached:@"ownsTX"] boolValue]; }
- (NSUInteger)queryCount { return [[self cached:@"queries"] unsignedIntegerValue]; }
- (NSUInteger)failureCount { return [[self cached:@"failures"] unsignedIntegerValue]; }
- (double)lastLatency { return [[self cached:@"latency"] doubleValue]; }
- (void)publish:(NSString *)status {
    _status=[status copy]; [self cacheState];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:TXStationRadioChanged object:self]; });
}
- (BOOL)reject:(NSString *)text error:(NSError **)error { if(error) *error=TXVoiceError(text); [self publish:text]; return NO; }
- (BOOL)selectOwner:(NSString *)owner port:(NSString *)path error:(NSError **)error {
    [_lock lock];
    if(_ownsTX && (![_owner isEqual:owner] || ![_port isEqual:path])) { BOOL r=[self reject:@"Stop the current transmission before changing radio control." error:error]; [self cacheState]; [_lock unlock]; return r; }
    if(![_port isEqual:path]) { [_transport close]; _transport=nil; _snapshot=@{}; _port=[path copy] ?: @""; }
    _owner=[owner copy];
    if(!_transport && path.length) _transport=self.transportFactory ? self.transportFactory(path) : [[TX500VoiceCATRadio alloc] initWithPort:path];
    [self publish:path.length ? [NSString stringWithFormat:@"%@ controls the radio",owner] : @"Select a CAT port to connect"];
    [self cacheState]; [_lock unlock]; return YES;
}
- (BOOL)allowed:(NSString *)owner error:(NSError **)error {
    if(!_transport) return [self reject:@"Select a CAT port first." error:error];
    if(![_owner isEqual:owner]) return [self reject:[NSString stringWithFormat:@"%@ currently controls the radio. Stop it before using %@.",_owner,owner] error:error];
    return YES;
}
- (NSString *)query:(NSString *)command error:(NSError **)error {
    [_lock lock];
    // Explicit read allowlist: a short CAT command is not necessarily a query.
    NSSet *reads=[NSSet setWithArray:@[@"FA;",@"FB;",@"MD;",@"PT;",@"FR;",@"FT;",@"XT;",@"VX;",@"IF;",@"ID;",@"TY;",@"VL;",@"PC;",@"MA;",@"KS;",@"FW;",@"FL;",@"SQ0;",@"SM0;",@"SM1;",@"RM;",@"RM0;RM;",@"RM1;RM;",@"RM2;RM;",@"RM3;RM;"]];
    if(![reads containsObject:command] || !_transport) { [self reject:@"No connected radio or unsupported status query." error:error]; [self cacheState]; [_lock unlock]; return nil; }
    double start=Lab599MonotonicTime(); NSString *reply=[_transport query:command error:error];
    _lastLatency=(Lab599MonotonicTime()-start)*1000; _queryCount++;
    if(!reply) { _failureCount++; [self publish:@"CAT reply missing • check the connection"]; }
    else {
        NSDictionary *keys=@{@"FA;":@"frequency",@"MD;":@"mode",@"PT;":@"tx"}; NSString *key=keys[command];
        if(key && reply.length>3) { NSMutableDictionary *s=[_snapshot mutableCopy]; s[key]=@([[reply substringWithRange:NSMakeRange(2,reply.length-3)] longLongValue]); _snapshot=s; }
    }
    [self cacheState]; [_lock unlock]; return reply;
}
- (NSDictionary *)readState:(NSError **)error {
    [_lock lock]; double start=Lab599MonotonicTime(); NSDictionary *s=[_transport readState:error]; _queryCount++; _lastLatency=(Lab599MonotonicTime()-start)*1000;
    if(s) { _snapshot=[s copy]; [self publish:[s[@"tx"] boolValue] ? @"Radio is transmitting" : @"Radio verified • receiving"]; }
    else { _failureCount++; [self publish:@"Radio verification failed. Check CAT and the selected port."]; if(error && !*error) *error=TXVoiceError(_status); }
    [self cacheState]; [_lock unlock]; return s;
}
- (BOOL)transmit:(BOOL)active owner:(NSString *)owner error:(NSError **)error {
    [_lock lock];
    if(![self allowed:owner error:error]) { [self cacheState]; [_lock unlock]; return NO; }
    if(active && _faulted) { [self reject:@"PTT state is unresolved. Stop and confirm RX before another transmission." error:error]; [self cacheState]; [_lock unlock]; return NO; }
    if(!active && !_ownsTX) {
        // Do not trust only the host-side ownership bit. A lost CAT reply can
        // leave the transceiver keyed even though the caller has already
        // unwound its TX state. Confirm PT0 and force RX when necessary.
        NSString *pt=[_transport query:@"PT;" error:error];
        if([pt isEqual:@"PT0;"]) { _faulted=NO; [self cacheState]; [_lock unlock]; return YES; }
        _ownsTX=YES;
    }
    if(active && !_ownsTX) {
        NSDictionary *s=[self readState:error];
        if(!s || [s[@"tx"] boolValue] || [s[@"vox"] boolValue]) { [self reject:@"TX blocked: verify RX and turn VOX off." error:error]; [self cacheState]; [_lock unlock]; return NO; }
        _ownsTX=YES; [self cacheState]; // A lost acknowledgement must still be followed by RX cleanup.
    }
    BOOL ok=[_transport setTransmit:active error:error];
    if(ok) { NSMutableDictionary *s=[_snapshot mutableCopy]; s[@"tx"]=@(active); _snapshot=[s copy]; }
    if(ok && !active) { _ownsTX=NO; _faulted=NO; }
    if(!ok) _faulted=YES;
    if(!ok) _failureCount++;
    [self publish:ok ? (active ? @"TX confirmed" : @"RX confirmed") : @"PTT acknowledgement missing • press Stop and check the radio"];
    [self cacheState]; [_lock unlock]; return ok;
}
- (BOOL)send:(NSString *)command owner:(NSString *)owner error:(NSError **)error {
    [_lock lock]; if(![self allowed:owner error:error] || !command.length || ![command hasSuffix:@";"]) { [self cacheState]; [_lock unlock]; return NO; }
    if([command isEqual:@"KY ;RX;"]) {
        BOOL released=[self releaseOwnedTX:error]; [self cacheState]; [_lock unlock]; return released;
    }
    BOOL ok=YES;
    for(NSString *part in [command componentsSeparatedByString:@";"]) {
        if(!part.length) continue;
        if([part isEqual:@"TX"] || [part isEqual:@"TX1"]) { ok=[self transmit:YES owner:owner error:error]; }
        else if([part isEqual:@"RX"]) ok=[self transmit:NO owner:owner error:error];
        else if([part hasPrefix:@"KY"]) {
            if(_faulted) { ok=[self reject:@"Confirm RX before sending more CW." error:error]; break; }
            BOOL empty=[[part substringFromIndex:2] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length==0;
            if(empty && !_ownsTX) continue;
            if(!empty && !_ownsTX) {
                NSDictionary *s=[self readState:error];
                if(!s || [s[@"tx"] boolValue] || [s[@"vox"] boolValue]) { ok=[self reject:@"CW blocked: radio must be receiving with VOX off." error:error]; break; }
                _ownsTX=YES; [self cacheState];
            }
            ok=[_transport send:[part stringByAppendingString:@";"] error:error];
            if(!ok) _faulted=YES;
        } else {
            if(_ownsTX) { ok=[self reject:@"Stop TX before changing radio settings." error:error]; break; }
            BOOL valid=[part rangeOfString:@"^(FA[0-9]{11}|FB[0-9]{11}|MD[1-79]|KS[0-9]{3}|PC[0-9]{3}|MA[0-9]{3}|FW[0-9]{4}|FL[0-3][0-1]|SQ0[0-9]{3})$" options:NSRegularExpressionSearch].location!=NSNotFound;
            if(!valid) { ok=[self reject:@"This setting command is not supported by station control." error:error]; break; }
            if([part hasPrefix:@"FA"] || [part hasPrefix:@"FB"]) { uint64_t hz=[[part substringFromIndex:2] longLongValue]; if(hz<500000 || hz>56000000) { ok=[self reject:@"Frequency is outside the radio range." error:error]; break; } }
            if([part hasPrefix:@"PC"] && ([[part substringFromIndex:2] integerValue]<10 || [[part substringFromIndex:2] integerValue]>100)) { ok=[self reject:@"RF power must be between 1 and 10 watts." error:error]; break; }
            if([part hasPrefix:@"MA"] && [[part substringFromIndex:2] integerValue]>100) { ok=[self reject:@"DIG gain must be between 0 and 100." error:error]; break; }
            if([part hasPrefix:@"SQ"] && [[part substringFromIndex:3] integerValue]>255) { ok=[self reject:@"Squelch must be between 0 and 255." error:error]; break; }
            NSString *pt=[_transport query:@"PT;" error:error];
            if(![pt isEqual:@"PT0;"]) { ok=[self reject:@"Radio must confirm RX before a setting change." error:error]; break; }
            ok=[_transport send:[part stringByAppendingString:@";"] error:error];
        }
        if(!ok) break;
    }
    if(!ok) _failureCount++;
    [self cacheState]; [_lock unlock]; return ok;
}
// A band change may restore the radio's previous mode for that band. Wait for
// the frequency to settle before setting mode; CAT has no atomic FA+MD command.
- (BOOL)tuningStateIsSafe:(NSDictionary *)state {
    for(NSString *key in @[@"frequency",@"mode",@"tx",@"rxVFO",@"txVFO",@"xit",@"vox"])
        if(![state[key] isKindOfClass:NSNumber.class]) return NO;
    return state && ![state[@"tx"] boolValue] && [state[@"rxVFO"] integerValue]==0 &&
        [state[@"txVFO"] integerValue]==0 && ![state[@"xit"] boolValue] && ![state[@"vox"] boolValue];
}
- (BOOL)verifyTuneFrequency:(uint64_t)hz mode:(NSInteger)mode error:(NSError **)error {
    NSError *lastError=nil; NSDictionary *state=nil; NSUInteger matches=0;
    for(NSUInteger attempt=0; attempt<4; attempt++) {
        Lab599Pause(0.15,nil);
        lastError=nil;
        state=[self readState:&lastError];
        if(state && ![self tuningStateIsSafe:state])
            return [self reject:@"Tuning stopped: radio changed TX, VFO, Split, XIT or VOX state. Check the radio before retrying." error:error];
        BOOL match=state && [state[@"frequency"] unsignedLongLongValue]==hz &&
            (mode==0 || [state[@"mode"] integerValue]==mode);
        matches=match ? matches+1 : 0;
        if(matches>=2) return YES;
    }
    NSString *phase=mode ? @"Frequency and mode" : @"Frequency";
    NSString *detail=state ? [NSString stringWithFormat:@"Radio reports %.6f MHz, MD%ld; requested %.6f MHz%@.",
        [state[@"frequency"] doubleValue]/1e6,(long)[state[@"mode"] integerValue],hz/1e6,
        mode ? [NSString stringWithFormat:@", MD%ld",(long)mode] : @""] :
        (lastError.localizedDescription ?: @"No complete CAT status reply.");
    return [self reject:[NSString stringWithFormat:@"%@ could not be verified. %@ The radio may be partly changed; use Read radio.",phase,detail] error:error];
}
- (BOOL)tune:(uint64_t)hz mode:(NSInteger)mode owner:(NSString *)owner error:(NSError **)error {
    [_lock lock];
    @try {
        if(![self allowed:owner error:error]) return NO;
        if(_ownsTX || hz<500000 || hz>56000000 || ![@[@1,@2,@3,@4,@5,@6,@7,@9] containsObject:@(mode)])
            return [self reject:@"Cannot tune: check frequency, mode and TX state." error:error];
        NSError *failure=nil;
        NSDictionary *state=[self readState:&failure];
        if(!state) return [self reject:[NSString stringWithFormat:@"Cannot read radio before tuning: %@",failure.localizedDescription ?: @"No CAT response."] error:error];
        if(![self tuningStateIsSafe:state])
            return [self reject:@"Radio must be receiving on VFO A for RX/TX, with Split, XIT and VOX off before applying a preset." error:error];
        if(![_transport send:[NSString stringWithFormat:@"FA%011llu;",(unsigned long long)hz] error:&failure])
            return [self reject:[NSString stringWithFormat:@"Frequency command failed: %@",failure.localizedDescription ?: @"CAT write failed."] error:error];
        if(![self verifyTuneFrequency:hz mode:0 error:error]) return NO;
        if(![_transport send:[NSString stringWithFormat:@"MD%ld;",(long)mode] error:&failure])
            return [self reject:[NSString stringWithFormat:@"Frequency verified, but mode command failed: %@ Use Read radio.",failure.localizedDescription ?: @"CAT write failed."] error:error];
        if(![self verifyTuneFrequency:hz mode:mode error:error]) return NO;
        if(error) *error=nil;
        [self publish:@"Frequency and mode verified • receiving"];
        return YES;
    } @finally { [self cacheState]; [_lock unlock]; }
}
- (BOOL)releaseOwnedTX:(NSError **)error { [_lock lock]; BOOL ok=YES; if(_ownsTX) { if([_owner isEqual:@"CW"]) [_transport send:@"KY ;" error:nil]; ok=[self transmit:NO owner:_owner error:error]; } [self cacheState]; [_lock unlock]; return ok; }
- (BOOL)suspend:(NSError **)error { [_lock lock]; BOOL ok=[self releaseOwnedTX:error]; if(ok) { [_transport close]; _transport=nil; _owner=@""; _snapshot=@{}; [self publish:@"Disconnected"]; } [self cacheState]; [_lock unlock]; return ok; }
- (id<TX500VoiceRadio>)voiceAdapter { TX500StationVoiceAdapter *a=[TX500StationVoiceAdapter new]; a.core=self; return a; }
@end
@implementation TX500StationVoiceAdapter
- (NSDictionary *)readState:(NSError **)error { return [self.core readState:error]; }
- (BOOL)tuneFrequency:(uint64_t)frequency mode:(NSInteger)mode error:(NSError **)error { return [self.core tune:frequency mode:mode owner:@"Voice" error:error]; }
- (BOOL)setTransmit:(BOOL)transmit error:(NSError **)error { return [self.core transmit:transmit owner:@"Voice" error:error]; }
- (void)close { /* Shared transport remains available to status subscribers. */ }
@end
