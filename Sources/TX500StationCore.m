#import "TX500StationCore.h"
#import "Lab599SerialPort.h"
#import <mach/mach_time.h>
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
    NSString *_transmitSafetyNotice;
    dispatch_source_t _transmitDeadline;
    dispatch_queue_t _safetyQueue;
    double _txStartedContinuous, _txStartedWall, _txLimit;
    NSUInteger _transmitGeneration;
    NSUInteger _queryCount, _failureCount, _receiveFailureStreak;
    double _lastLatency;
    NSUInteger _releaseRequests; // guarded by @synchronized(self), including requests waiting for _lock
    Lab599Cancellation *_pendingRead; // the meter read in flight; guarded by @synchronized(self)
}
- (instancetype)init { if((self=[super init])) { _lock=[NSRecursiveLock new]; _owner=@""; _port=@""; _status=@"Disconnected"; _snapshot=@{}; _transmitSafetyNotice=@""; _safetyQueue=dispatch_queue_create("com.lab599.core.tx-safety", DISPATCH_QUEUE_SERIAL); [self cacheState]; } return self; }
// UI readers never wait behind serial I/O. Publish immutable diagnostic snapshots
// under a separate short lock; command decisions still use the transport lock.
- (void)cacheState {
    @synchronized(self) { _published=@{@"owner":_owner ?: @"",@"status":_status ?: @"",@"snapshot":[_snapshot copy] ?: @{},@"ownsTX":@(_ownsTX),@"safetyNotice":_transmitSafetyNotice ?: @"",@"queries":@(_queryCount),@"failures":@(_failureCount),@"latency":@(_lastLatency)}; }
}
- (id)cached:(NSString *)key { @synchronized(self) { return _published[key]; } }
- (NSString *)owner { return [self cached:@"owner"]; }
- (NSString *)status { return [self cached:@"status"]; }
- (NSDictionary *)snapshot { return [self cached:@"snapshot"]; }
- (BOOL)ownsTX { return [[self cached:@"ownsTX"] boolValue]; }
- (NSString *)transmitSafetyNotice { return [self cached:@"safetyNotice"]; }
- (void)acknowledgeTransmitSafetyNotice {
    [_lock lock]; _transmitSafetyNotice=@""; [self cacheState]; [_lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:TXStationRadioChanged object:self]; });
}
- (void)recordTransmitSafetyNotice:(NSString *)reason {
    [_lock lock];
    NSDateFormatter *utc=[NSDateFormatter new]; utc.locale=[[NSLocale alloc] initWithLocaleIdentifier:@"en_US_POSIX"];
    utc.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:0]; utc.dateFormat=@"yyyy-MM-dd HH:mm:ss 'UTC'";
    _transmitSafetyNotice=[NSString stringWithFormat:@"Lab599 TX-500 (%@): %@ at %@. Other tools remain available. Check the radio is on receive locally before sending again.",_port ?: @"CAT",reason,[utc stringFromDate:[NSDate date]]];
    [self cacheState]; [_lock unlock];
    dispatch_async(dispatch_get_main_queue(), ^{ [NSNotificationCenter.defaultCenter postNotificationName:TXStationRadioChanged object:self]; });
}
- (double)continuousSafetyTime {
    static mach_timebase_info_data_t info; static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&info); });
    return (double)mach_continuous_time()*info.numer/info.denom/1e9;
}
- (double)wallSafetyTime { return NSDate.date.timeIntervalSince1970; }
- (double)transmitLimitForOwner:(NSString *)owner {
    if([owner isEqual:@"CW"]) return 130; // independent backstop above the keyer's 120 s message ceiling
    if([owner isEqual:@"Voice"]) return 75; // 60 s audio plus lead/tail and verification
    if([owner isEqual:@"Digital"]) return 20; // FT8/FT4 and tune
    return 15;
}
- (void)cancelTransmitDeadline {
    _transmitGeneration++;
    if(_transmitDeadline) { dispatch_source_cancel(_transmitDeadline); _transmitDeadline=nil; }
}
- (void)armTransmitDeadline {
    if(_transmitDeadline) return; // repeated key-down never renews ownership
    _txStartedContinuous=[self continuousSafetyTime]; _txStartedWall=[self wallSafetyTime];
    _txLimit=[self transmitLimitForOwner:_owner];
    if(!isfinite(_txLimit) || _txLimit<=0 || _txLimit>130) _txLimit=130;
    NSUInteger generation=++_transmitGeneration;
    dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,_safetyQueue);
    __weak typeof(self) weakSelf=self;
    dispatch_source_set_event_handler(timer, ^{
        typeof(self) self=weakSelf; if(!self) return;
        [self->_lock lock];
        if(self->_transmitGeneration==generation && self->_ownsTX) {
            double elapsed=MAX([self continuousSafetyTime]-self->_txStartedContinuous,[self wallSafetyTime]-self->_txStartedWall);
            if(elapsed>=self->_txLimit) {
                double limit=self->_txLimit;
                BOOL received=[self releaseOwnedTX:nil];
                [self recordTransmitSafetyNotice:[NSString stringWithFormat:@"the core TX limit expired after %.1f s (limit %.0f s); RX was requested, %@",elapsed,limit,received ? @"PT0 confirmed" : @"receive NOT confirmed"]];
            }
        }
        [self->_lock unlock];
    });
    // Wall-clock timer wakes promptly on resume; continuous time prevents a backward clock step extending TX.
    dispatch_source_set_timer(timer,dispatch_walltime(NULL,0),100*NSEC_PER_MSEC,5*NSEC_PER_MSEC);
    _transmitDeadline=timer; dispatch_resume(timer);
}
- (void)dealloc { if(_transmitDeadline) dispatch_source_cancel(_transmitDeadline); }
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
    if(_ownsTX && (![_owner isEqual:owner] || ![_port isEqual:path])) {
        NSString *pt=[_transport query:@"PT;" error:nil];
        // Only an explicit PT0 means receiving; no reply keeps ownership and the fault latch.
        if([pt isEqual:@"PT0;"]) {
            _ownsTX=NO; [self cancelTransmitDeadline]; _faulted=NO;
        } else {
            BOOL r=[self reject:@"Stop the current transmission before changing radio control." error:error]; [self cacheState]; [_lock unlock]; return r;
        }
    }
    if(![_port isEqual:path]) { [_transport close]; _transport=nil; _snapshot=@{}; _port=[path copy] ?: @""; _receiveFailureStreak=0; }
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
    return [self query:command timeout:0.8 error:error];
}
- (NSString *)query:(NSString *)command timeout:(NSTimeInterval)timeout error:(NSError **)error {
    // A status read holds the lock every other CAT user waits on: it never waits longer than
    // its caller asked, and never longer than the old fixed 0.8 s.
    if(!isfinite(timeout)) timeout=0.8;
    timeout=MIN(0.8,MAX(0.05,timeout));
    [_lock lock];
    // Explicit read allowlist: a short CAT command is not necessarily a query.
    NSSet *reads=[NSSet setWithArray:@[@"FA;",@"FB;",@"MD;",@"PT;",@"FR;",@"FT;",@"XT;",@"VX;",@"IF;",@"ID;",@"TY;",@"VL;",@"PC;",@"MA;",@"KS;",@"FW;",@"FL;",@"SQ0;",@"SM0;",@"SM1;",@"RM;",@"RM0;RM;",@"RM1;RM;",@"RM2;RM;",@"RM3;RM;"]];
    if(![reads containsObject:command] || !_transport) { [self reject:@"No connected radio or unsupported status query." error:error]; [self cacheState]; [_lock unlock]; return nil; }
    double start=Lab599MonotonicTime(); NSString *reply;
    // A release waiting for the lock cancels a meter read's token (interruptPendingRead) instead of
    // waiting out the read. Only meter reads (RM...) take one: a frequency, mode or PT read of any
    // screen is never cut and gets its reply.
    Lab599Cancellation *token=[command hasPrefix:@"RM"] ? [Lab599Cancellation new] : nil;
    if(token) {
        @synchronized(self) {
            if (_releaseRequests) {
                if (error) *error=TXVoiceError(@"Meter read skipped while RX release is pending.");
                [_lock unlock];
                return nil;
            }
            _pendingRead=token;
        }
    }
    // A transport without deadlines (the in-memory test radios) keeps the old form.
    if([_transport respondsToSelector:@selector(query:timeout:cancellation:error:)])
        reply=[_transport query:command timeout:timeout cancellation:token error:error];
    else reply=[_transport query:command error:error];
    if(token) { @synchronized(self) { if(_pendingRead==token) _pendingRead=nil; } }
    _lastLatency=(Lab599MonotonicTime()-start)*1000; _queryCount++;
    // A read cut short by a release is not a CAT failure: nothing is counted or published.
    if(!reply && token.cancelled) { [self cacheState]; [_lock unlock]; return nil; }
    if(!reply) { _failureCount++; [self publish:@"CAT reply missing • check the connection"]; }
    else {
        NSDictionary *keys=@{@"FA;":@"frequency",@"MD;":@"mode",@"PT;":@"tx"}; NSString *key=keys[command];
        if(key && reply.length>3) { NSMutableDictionary *s=[_snapshot mutableCopy]; s[key]=@([[reply substringWithRange:NSMakeRange(2,reply.length-3)] longLongValue]); _snapshot=s; }
    }
    [self cacheState]; [_lock unlock]; return reply;
}
// Called before a release takes the lock: a meter read in flight ends within one serial
// slice (40 ms) instead of holding the RX; of ABORT, Esc or the keyer's time-out behind it.
- (void)beginReleaseRequest { @synchronized(self) { _releaseRequests++; _pendingRead.cancelled=YES; } }
- (void)endReleaseRequest { @synchronized(self) { _releaseRequests--; } }
- (NSDictionary *)readState:(NSError **)error {
    [_lock lock]; double start=Lab599MonotonicTime(); NSDictionary *s=[_transport readState:error]; _queryCount++; _lastLatency=(Lab599MonotonicTime()-start)*1000;
    if(s) { _snapshot=[s copy]; [self publish:[s[@"tx"] boolValue] ? @"Radio is transmitting" : @"Radio verified • receiving"]; }
    else { _failureCount++; [self publish:@"Radio verification failed. Check CAT and the selected port."]; if(error && !*error) *error=TXVoiceError(_status); }
    [self cacheState]; [_lock unlock]; return s;
}
- (BOOL)transmit:(BOOL)active owner:(NSString *)owner error:(NSError **)error {
    BOOL releaseRequested = !active;
    if (releaseRequested) [self beginReleaseRequest];
    @try {
        [_lock lock];
        if(![self allowed:owner error:error]) { [self cacheState]; [_lock unlock]; return NO; }
        if(active && _faulted) { [self reject:@"PTT state is unresolved. Stop and confirm RX before another transmission." error:error]; [self cacheState]; [_lock unlock]; return NO; }
        if(!active && !_ownsTX) {
            // Do not trust only the host-side ownership bit. A lost CAT reply can
            // leave the transceiver keyed even though the caller has already
            // unwound its TX state. Confirm PT0 and force RX when necessary.
            NSString *pt=[_transport query:@"PT;" error:error];
            if([pt isEqual:@"PT0;"]) { _faulted=NO; [self cacheState]; [_lock unlock]; return YES; }
            _ownsTX=YES; // PT1, or no reply: force RX; below and let the read-back decide.
        }
        if(active && _ownsTX) { [self cacheState]; [_lock unlock]; return YES; }
        if(active && !_ownsTX) {
            NSDictionary *s=[self readState:nil];
            BOOL isAlreadyTX = NO;
            if(s) {
                isAlreadyTX = [s[@"tx"] boolValue];
                // CW keys the radio with TX; and modulates it over USB audio: VOX would key it outside
                // the app's control, so it must be off (as before 2.283). Digital clears VOX itself (VX0;).
                if(![owner isEqual:@"Digital"] && [s[@"vox"] boolValue]) {
                    [self reject:@"TX blocked: turn VOX off before transmitting." error:error];
                    [self cacheState]; [_lock unlock]; return NO;
                }
                // CW modulates the radio over USB audio, which only DIG (MD6) takes: in FM or AM a
                // keyed radio sends a full carrier whatever the audio holds. The custom CW modes'
                // MD6;TX; prefix is split by send:, so MD6; is written before this check runs.
                if([owner isEqual:@"CW"] && [s[@"mode"] integerValue]!=6) {
                    [self reject:[NSString stringWithFormat:@"TX blocked: the radio is in MD%ld; CW needs DIG (MD6).",(long)[s[@"mode"] integerValue]] error:error];
                    [self cacheState]; [_lock unlock]; return NO;
                }
            } else {
                // The state could not be read, so VOX is unknown: only Digital, which clears VOX itself, may go on.
                if(![owner isEqual:@"Digital"]) {
                    [self reject:@"TX blocked: the radio state could not be read (VOX unknown)." error:error];
                    [self cacheState]; [_lock unlock]; return NO;
                }
                NSString *pt = [_transport query:@"PT;" error:nil];
                if(![pt isEqual:@"PT0;"]) { [self reject:@"TX blocked: the radio did not confirm RX." error:error]; [self cacheState]; [_lock unlock]; return NO; }
            }
            if(isAlreadyTX) {
                [self reject:@"TX blocked: radio must be receiving." error:error];
                [self cacheState]; [_lock unlock]; return NO;
            }
            BOOL stopping; @synchronized(self) { stopping=_releaseRequests>0; }
            if(stopping) { [self reject:@"TX cancelled: a receive/stop request is pending." error:error]; [self cacheState]; [_lock unlock]; return NO; }
            _ownsTX=YES; [self armTransmitDeadline]; [self cacheState]; // A lost acknowledgement must still be followed by RX cleanup.
        }
        BOOL ok=[_transport setTransmit:active error:error];
        if(ok) { NSMutableDictionary *s=[_snapshot mutableCopy]; s[@"tx"]=@(active); _snapshot=[s copy]; }
        if(!active) {
            if(ok) {
                _ownsTX=NO; [self cancelTransmitDeadline]; _faulted=NO; _receiveFailureStreak=0;
            } else {
                NSString *ptCheck=[_transport query:@"PT;" error:nil];
                if(ptCheck && [ptCheck isEqual:@"PT0;"]) {
                    _ownsTX=NO; [self cancelTransmitDeadline]; _faulted=NO; _receiveFailureStreak=0; ok=YES;
                }
            }
        }
        if(!ok) _faulted=YES;
        if(!ok) _failureCount++;
        if(!ok && !active) {
            [self recordTransmitSafetyNotice:@"RX acknowledgement failed; receive is NOT confirmed"];
            _receiveFailureStreak++;
            // A USB serial adapter can retain a stale descriptor after an RF or
            // cable transient. Reopen it periodically while preserving TX ownership
            // and the fault latch. Only a later PT0 readback may clear either.
            if(_receiveFailureStreak >= 2 && (_receiveFailureStreak-2)%3 == 0) {
                [_transport close];
                _transport=self.transportFactory ? self.transportFactory(_port) : [[TX500VoiceCATRadio alloc] initWithPort:_port];
            }
        }
        [self publish:ok ? (active ? @"TX confirmed" : @"RX confirmed") : @"PTT acknowledgement missing • press Stop and check the radio"];
        [self cacheState]; [_lock unlock]; return ok;
    } @finally { if (releaseRequested) [self endReleaseRequest]; }
}
- (BOOL)send:(NSString *)command owner:(NSString *)owner error:(NSError **)error {
    BOOL releaseRequested = [command containsString:@"RX;"];
    if (releaseRequested) [self beginReleaseRequest];
    @try {
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
                if(_faulted) {
                    NSString *pt = [_transport query:@"PT;" error:nil];
                    if ([pt isEqual:@"PT0;"]) _faulted = NO;
                    else { ok=[self reject:@"Confirm RX before sending more CW." error:error]; break; }
                }
                BOOL empty=[[part substringFromIndex:2] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].length==0;
                if(empty && !_ownsTX) continue;
                if(!empty && !_ownsTX) {
                    NSString *pt = [_transport query:@"PT;" error:nil];
                    BOOL isTX = (pt && ![pt isEqual:@"PT0;"]);
                    if(isTX) { ok=[self reject:@"CW blocked: radio must be receiving." error:error]; break; }
                    _ownsTX=YES; [self armTransmitDeadline]; [self cacheState];
                    [_transport send:@"TX;" error:nil];
                }
                ok=[_transport send:[part stringByAppendingString:@";"] error:error];
                if(!ok) _faulted=YES;
            } else {
                if(_ownsTX) { ok=[self reject:@"Stop TX before changing radio settings." error:error]; break; }
                BOOL valid=[part rangeOfString:@"^(FA[0-9]{11}|FB[0-9]{11}|MD[1-79]|KS[0-9]{3}|PC[0-9]{3}|MA[0-9]{3}|FW[0-9]{4}|FL[0-3][0-1]|SQ0[0-9]{3}|VX[0-1]|FT[0-1]|FR[0-1])$" options:NSRegularExpressionSearch].location!=NSNotFound;
                if(!valid) { ok=[self reject:@"This setting command is not supported by station control." error:error]; break; }
                if([part hasPrefix:@"FA"] || [part hasPrefix:@"FB"]) { uint64_t hz=[[part substringFromIndex:2] longLongValue]; if(hz<500000 || hz>56000000) { ok=[self reject:@"Frequency is outside the radio range." error:error]; break; } }
                if([part hasPrefix:@"PC"] && ([[part substringFromIndex:2] integerValue]<10 || [[part substringFromIndex:2] integerValue]>100)) { ok=[self reject:@"RF power must be between 1 and 10 watts." error:error]; break; }
                if([part hasPrefix:@"MA"] && [[part substringFromIndex:2] integerValue]>100) { ok=[self reject:@"DIG gain must be between 0 and 100." error:error]; break; }
                if([part hasPrefix:@"SQ"] && [[part substringFromIndex:3] integerValue]>255) { ok=[self reject:@"Squelch must be between 0 and 255." error:error]; break; }
                NSString *pt=[_transport query:@"PT;" error:nil];
                if(pt && [pt hasPrefix:@"PT1"]) { ok=[self reject:@"Radio must confirm RX before a setting change." error:error]; break; }
                ok=[_transport send:[part stringByAppendingString:@";"] error:error];
            }
            if(!ok) break;
        }
        if(!ok) _failureCount++;
        [self cacheState]; [_lock unlock]; return ok;
    } @finally { if (releaseRequested) [self endReleaseRequest]; }
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
- (BOOL)releaseOwnedTX:(NSError **)error {
    BOOL releaseRequested = YES;
    if (releaseRequested) [self beginReleaseRequest];
    @try {
        [_lock lock];
        BOOL ok=YES;
        if(_ownsTX) {
            if([_owner isEqual:@"CW"]) [_transport send:@"KY ;" error:nil];
            ok=[self transmit:NO owner:_owner error:error];
            if(!ok) {
                [_transport send:@"RX;" error:nil];
                NSString *pt=[_transport query:@"PT;" error:nil];
                if([pt isEqual:@"PT0;"]) {
                    _ownsTX=NO; [self cancelTransmitDeadline]; _faulted=NO; ok=YES;
                }
            }
        }
        [self cacheState]; [_lock unlock]; return ok;
    } @finally { if (releaseRequested) [self endReleaseRequest]; }
}
- (BOOL)suspend:(NSError **)error {
    BOOL releaseRequested = YES;
    if (releaseRequested) [self beginReleaseRequest];
    @try {
        [_lock lock];
        BOOL ok=[self releaseOwnedTX:error];
        if(ok || !_ownsTX) {
            [_transport close]; _transport=nil; _owner=@""; _snapshot=@{}; [self publish:@"Disconnected"];
            ok=YES;
        }
        [self cacheState]; [_lock unlock]; return ok;
    } @finally { if (releaseRequested) [self endReleaseRequest]; }
}
- (void)forceCloseTransport {
    [_lock lock];
    [_transport close];
    _transport=nil;
    _owner=@"";
    _snapshot=@{};
    _ownsTX=NO; [self cancelTransmitDeadline];
    _faulted=NO;
    [self publish:@"Disconnected"];
    [self cacheState];
    [_lock unlock];
}
- (BOOL)handoffToOwner:(NSString *)owner port:(NSString *)path releaseFirst:(BOOL)releaseFirst closePort:(BOOL)closePort error:(NSError **)error {
    BOOL releaseRequested = releaseFirst || closePort;
    if (releaseRequested) [self beginReleaseRequest];
    @try {
        [_lock lock];
        BOOL ok;
        // A radio that did not confirm RX keeps its port, its owner and the fault latch.
        if(releaseFirst && ![self releaseOwnedTX:error]) ok=NO;
        else if(closePort) ok=[self suspend:error];
        else if(!releaseFirst && _ownsTX) ok=YES;
        else ok=[self selectOwner:owner port:path error:error];
        [self cacheState]; [_lock unlock]; return ok;
    } @finally { if (releaseRequested) [self endReleaseRequest]; }
}
- (id<TX500VoiceRadio>)voiceAdapter { TX500StationVoiceAdapter *a=[TX500StationVoiceAdapter new]; a.core=self; return a; }
@end
@implementation TX500StationVoiceAdapter
- (NSDictionary *)readState:(NSError **)error { return [self.core readState:error]; }
- (BOOL)tuneFrequency:(uint64_t)frequency mode:(NSInteger)mode error:(NSError **)error { return [self.core tune:frequency mode:mode owner:@"Voice" error:error]; }
- (BOOL)setTransmit:(BOOL)transmit error:(NSError **)error { return [self.core transmit:transmit owner:@"Voice" error:error]; }
- (void)close { /* Shared transport remains available to status subscribers. */ }
@end
