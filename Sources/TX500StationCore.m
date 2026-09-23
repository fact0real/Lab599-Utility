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
    NSDictionary *_snapshot;
    BOOL _ownsTX, _faulted;
    NSUInteger _queryCount, _failureCount;
    double _lastLatency;
}
- (instancetype)init { if((self=[super init])) { _lock=[NSRecursiveLock new]; _owner=@""; _port=@""; _status=@"Disconnected"; _snapshot=@{}; } return self; }
- (NSString *)owner { [_lock lock]; NSString *v=_owner; [_lock unlock]; return v; }
- (NSString *)status { [_lock lock]; NSString *v=_status; [_lock unlock]; return v; }
- (NSDictionary *)snapshot { [_lock lock]; NSDictionary *v=_snapshot; [_lock unlock]; return v; }
- (BOOL)ownsTX { [_lock lock]; BOOL v=_ownsTX; [_lock unlock]; return v; }
- (NSUInteger)queryCount { [_lock lock]; NSUInteger v=_queryCount; [_lock unlock]; return v; }
- (NSUInteger)failureCount { [_lock lock]; NSUInteger v=_failureCount; [_lock unlock]; return v; }
- (double)lastLatency { [_lock lock]; double v=_lastLatency; [_lock unlock]; return v; }
- (void)publish:(NSString *)status {
    _status=[status copy];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:TXStationRadioChanged object:self]; });
}
- (BOOL)reject:(NSString *)text error:(NSError **)error { if(error) *error=TXVoiceError(text); [self publish:text]; return NO; }
- (BOOL)selectOwner:(NSString *)owner port:(NSString *)path error:(NSError **)error {
    [_lock lock];
    if(_ownsTX && (![_owner isEqual:owner] || ![_port isEqual:path])) { BOOL r=[self reject:@"Stop the current transmission before changing radio control." error:error]; [_lock unlock]; return r; }
    if(![_port isEqual:path]) { [_transport close]; _transport=nil; _snapshot=@{}; _port=[path copy] ?: @""; }
    _owner=[owner copy];
    if(!_transport && path.length) _transport=self.transportFactory ? self.transportFactory(path) : [[TX500VoiceCATRadio alloc] initWithPort:path];
    [self publish:path.length ? [NSString stringWithFormat:@"%@ controls the radio",owner] : @"Select a CAT port to connect"];
    [_lock unlock]; return YES;
}
- (BOOL)allowed:(NSString *)owner error:(NSError **)error {
    if(!_transport) return [self reject:@"Select a CAT port first." error:error];
    if(![_owner isEqual:owner]) return [self reject:[NSString stringWithFormat:@"%@ currently controls the radio. Stop it before using %@.",_owner,owner] error:error];
    return YES;
}
- (NSString *)query:(NSString *)command error:(NSError **)error {
    [_lock lock];
    // Explicit read allowlist: a short CAT command is not necessarily a query.
    NSSet *reads=[NSSet setWithArray:@[@"FA;",@"FB;",@"MD;",@"PT;",@"FR;",@"FT;",@"XT;",@"VX;",@"IF;",@"ID;",@"TY;",@"VL;",@"PC;",@"KS;",@"FW;",@"SM0;",@"SM1;",@"RM;",@"RM1;RM;"]];
    if(![reads containsObject:command] || !_transport) { [self reject:@"No connected radio or unsupported status query." error:error]; [_lock unlock]; return nil; }
    double start=Lab599MonotonicTime(); NSString *reply=[_transport query:command error:error];
    _lastLatency=(Lab599MonotonicTime()-start)*1000; _queryCount++;
    if(!reply) { _failureCount++; [self publish:@"CAT reply missing • check the connection"]; }
    else {
        NSDictionary *keys=@{@"FA;":@"frequency",@"MD;":@"mode",@"PT;":@"tx"}; NSString *key=keys[command];
        if(key && reply.length>3) { NSMutableDictionary *s=[_snapshot mutableCopy]; s[key]=@([[reply substringWithRange:NSMakeRange(2,reply.length-3)] longLongValue]); _snapshot=s; }
    }
    [_lock unlock]; return reply;
}
- (NSDictionary *)readState:(NSError **)error {
    [_lock lock]; double start=Lab599MonotonicTime(); NSDictionary *s=[_transport readState:error]; _queryCount++; _lastLatency=(Lab599MonotonicTime()-start)*1000;
    if(s) { _snapshot=[s copy]; [self publish:[s[@"tx"] boolValue] ? @"Radio is transmitting" : @"Radio verified • receiving"]; }
    else { _failureCount++; [self publish:@"Radio verification failed. Check CAT and the selected port."]; if(error && !*error) *error=TXVoiceError(_status); }
    [_lock unlock]; return s;
}
- (BOOL)transmit:(BOOL)active owner:(NSString *)owner error:(NSError **)error {
    [_lock lock];
    if(![self allowed:owner error:error]) { [_lock unlock]; return NO; }
    if(active && _faulted) { [self reject:@"PTT state is unresolved. Stop and confirm RX before another transmission." error:error]; [_lock unlock]; return NO; }
    if(!active && !_ownsTX) { [_lock unlock]; return YES; }
    if(active && !_ownsTX) {
        NSDictionary *s=[self readState:error];
        if(!s || [s[@"tx"] boolValue] || [s[@"vox"] boolValue]) { [self reject:@"TX blocked: verify RX and turn VOX off." error:error]; [_lock unlock]; return NO; }
        _ownsTX=YES; // A lost acknowledgement must still be followed by RX cleanup.
    }
    BOOL ok=[_transport setTransmit:active error:error];
    if(ok && !active) { _ownsTX=NO; _faulted=NO; }
    if(!ok) _faulted=YES;
    if(!ok) _failureCount++;
    [self publish:ok ? (active ? @"TX confirmed" : @"RX confirmed") : @"PTT acknowledgement missing • press Stop and check the radio"];
    [_lock unlock]; return ok;
}
- (BOOL)send:(NSString *)command owner:(NSString *)owner error:(NSError **)error {
    [_lock lock]; if(![self allowed:owner error:error] || !command.length || ![command hasSuffix:@";"]) { [_lock unlock]; return NO; }
    BOOL ok=YES;
    for(NSString *part in [command componentsSeparatedByString:@";"]) {
        if(!part.length) continue;
        if([part isEqual:@"TX"] || [part isEqual:@"TX1"]) { ok=[self transmit:YES owner:owner error:error]; }
        else if([part isEqual:@"RX"]) ok=[self transmit:NO owner:owner error:error];
        else if([part hasPrefix:@"KY"]) {
            BOOL empty=[[part substringFromIndex:2] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length==0;
            if(empty && !_ownsTX) continue;
            if(!empty && !_ownsTX) {
                NSDictionary *s=[self readState:error];
                if(!s || [s[@"tx"] boolValue] || [s[@"vox"] boolValue]) { ok=[self reject:@"CW blocked: radio must be receiving with VOX off." error:error]; break; }
                _ownsTX=YES;
            }
            ok=[_transport send:[part stringByAppendingString:@";"] error:error];
        } else {
            if(_ownsTX) { ok=[self reject:@"Stop TX before changing radio settings." error:error]; break; }
            BOOL valid=[part rangeOfString:@"^(FA[0-9]{11}|FB[0-9]{11}|MD[1-79]|KS[0-9]{3}|PC[0-9]{3}|FW[0-9]{4})$" options:NSRegularExpressionSearch].location!=NSNotFound;
            if(!valid) { ok=[self reject:@"This setting command is not supported by station control." error:error]; break; }
            if([part hasPrefix:@"FA"] || [part hasPrefix:@"FB"]) { uint64_t hz=[[part substringFromIndex:2] longLongValue]; if(hz<500000 || hz>56000000) { ok=[self reject:@"Frequency is outside the radio range." error:error]; break; } }
            NSString *pt=[_transport query:@"PT;" error:error];
            if(![pt isEqual:@"PT0;"]) { ok=[self reject:@"Radio must confirm RX before a setting change." error:error]; break; }
            ok=[_transport send:[part stringByAppendingString:@";"] error:error];
        }
        if(!ok) break;
    }
    if(!ok) _failureCount++;
    [_lock unlock]; return ok;
}
- (BOOL)tune:(uint64_t)hz mode:(NSInteger)mode owner:(NSString *)owner error:(NSError **)error {
    [_lock lock];
    if(![self allowed:owner error:error] || _ownsTX || hz<500000 || hz>56000000 || ![@[@1,@2,@3,@4,@5,@6,@7,@9] containsObject:@(mode)]) { [self reject:@"Cannot tune: check frequency, mode and TX state." error:error]; [_lock unlock]; return NO; }
    NSDictionary *s=[self readState:error];
    if(!s || [s[@"tx"] boolValue] || [s[@"rxVFO"] integerValue]!=0 || [s[@"txVFO"] integerValue]!=0 || [s[@"xit"] boolValue] || [s[@"vox"] boolValue]) { [self reject:@"Select VFO A for RX/TX; turn Split, XIT and VOX off before applying a preset." error:error]; [_lock unlock]; return NO; }
    BOOL ok=[_transport send:[NSString stringWithFormat:@"FA%011llu;MD%ld;",(unsigned long long)hz,(long)mode] error:error];
    s=ok ? [self readState:error] : nil;
    ok=s && [s[@"frequency"] unsignedLongLongValue]==hz && [s[@"mode"] integerValue]==mode;
    if(!ok) [self reject:@"Frequency/mode change was not confirmed. Read the radio before continuing." error:error];
    [_lock unlock]; return ok;
}
- (BOOL)releaseOwnedTX:(NSError **)error { [_lock lock]; BOOL ok=YES; if(_ownsTX) { if([_owner isEqual:@"CW"]) [_transport send:@"KY ;" error:nil]; ok=[self transmit:NO owner:_owner error:error]; } [_lock unlock]; return ok; }
- (BOOL)suspend:(NSError **)error { [_lock lock]; BOOL ok=[self releaseOwnedTX:error]; if(ok) { [_transport close]; _transport=nil; _owner=@""; _snapshot=@{}; [self publish:@"Disconnected"]; } [_lock unlock]; return ok; }
- (id<TX500VoiceRadio>)voiceAdapter { TX500StationVoiceAdapter *a=[TX500StationVoiceAdapter new]; a.core=self; return a; }
@end
@implementation TX500StationVoiceAdapter
- (NSDictionary *)readState:(NSError **)error { return [self.core readState:error]; }
- (BOOL)tuneFrequency:(uint64_t)frequency mode:(NSInteger)mode error:(NSError **)error { return [self.core tune:frequency mode:mode owner:@"Voice" error:error]; }
- (BOOL)setTransmit:(BOOL)transmit error:(NSError **)error { return [self.core transmit:transmit owner:@"Voice" error:error]; }
- (void)close { /* Shared transport remains available to status subscribers. */ }
@end
