#import "TX500VoiceKeyer.h"
#import <mach/mach_time.h>
#import <math.h>
static double VoiceNow(void) {
    static mach_timebase_info_data_t info; static dispatch_once_t once;
    dispatch_once(&once, ^{ mach_timebase_info(&info); });
    return (double)mach_continuous_time()*info.numer/info.denom/1e9;
}
static BOOL VoiceStateValid(NSDictionary *s, BOOL transmitting, NSDictionary *expected, NSError **error) {
    NSString *reason=nil;
    for(NSString *key in @[@"frequency",@"mode",@"rxVFO",@"txVFO",@"xit",@"vox",@"tx"]) {
        if(![s[key] isKindOfClass:NSNumber.class]) { reason=@"Radio status is incomplete. Reconnect before transmitting."; break; }
    }
    if(!reason && (![s[@"rxVFO"] isEqual:@0] || ![s[@"txVFO"] isEqual:@0] || ![s[@"xit"] isEqual:@0])) reason=@"Select VFO A for RX and TX, and turn Split and XIT off on the radio.";
    if(!reason && ![s[@"vox"] isEqual:@0]) reason=@"Turn VOX off on the radio before using the voice keyer.";
    if(!reason && ![@[@1,@2,@4,@5] containsObject:s[@"mode"]]) reason=@"Select USB, LSB, AM or FM on the radio.";
    if(!reason && ([s[@"frequency"] unsignedLongLongValue]<500000 || [s[@"frequency"] unsignedLongLongValue]>56000000)) reason=@"The radio frequency is invalid.";
    if(!reason && ![s[@"tx"] isEqual:@(transmitting ? 1 : 0)]) reason=@"The radio TX/RX state changed. Auto-CQ has stopped.";
    if(!reason && expected && (![s[@"frequency"] isEqual:expected[@"frequency"]] || ![s[@"mode"] isEqual:expected[@"mode"]])) reason=@"Frequency or mode changed on the radio. Reconnect to use the new setting.";
    if(reason && error) *error=TXVoiceError(reason);
    return reason==nil;
}
@interface TX500VoiceKeyer ()
@property(nonatomic) TX500VoiceState state;
@property(nonatomic) BOOL connected;
@property(nonatomic) BOOL radioBusy;
@property(nonatomic, copy) NSDictionary *radioState;
@property(nonatomic, copy) NSString *status;
@property(nonatomic) double progress;
@property(nonatomic) double remaining;
@property(nonatomic) NSInteger completedCalls;
@property(atomic) NSUInteger generation;
@end
@implementation TX500VoiceKeyer {
    id<TX500VoiceRadio> _radio;
    id<TX500VoicePlayback> _player;
    dispatch_queue_t _worker;
    BOOL _workerTX; // worker-only ownership, set BEFORE attempting TX
    NSTimer *_timer;
    TX500VoiceAudioIO *_microphone;
    TX500VoiceClip *_clip;
    BOOL _repeat, _liveRequest;
    double _deadline, _lastTick, _lastPoll, _sessionStart, _stateStart;
    NSInteger _sessionLimit;
    NSString *_sessionOutput, *_sessionMicrophone;
    double _sessionListen, _sessionVariation, _sessionLead, _sessionTail;
    float _sessionGain;
    id _activity;
}
- (instancetype)initWithRadio:(id<TX500VoiceRadio>)radio player:(id<TX500VoicePlayback>)player {
    if((self=[super init])) {
        _radio=radio; _player=player; _worker=dispatch_queue_create("ir.factoreal.voice.radio",DISPATCH_QUEUE_SERIAL);
        _status=@"Choose a message. Preview locally or connect your radio."; _radioState=@{};
        _outputUID=@""; _microphoneUID=@""; _listenSeconds=7; _leadSeconds=0.2; _tailSeconds=0.2;
        _maximumCalls=20; _gain=0.7;
        _deviceAvailable=^BOOL(NSString *uid,BOOL input) { return TXVoiceDeviceAvailable(uid,input); };
        _microphone=[TX500VoiceAudioIO new];
        __weak typeof(self) weakSelf=self;
        _timer=[NSTimer timerWithTimeInterval:0.05 repeats:YES block:^(NSTimer *t) { (void)t; [weakSelf tick]; }];
        [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
        [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(sleep:) name:NSWorkspaceWillSleepNotification object:nil];
    } return self;
}
- (double)microphoneLevel { return _microphone.level; }
- (BOOL)active { return self.state!=TXVoiceIdle && self.state!=TXVoiceFault; }
- (void)notify { if(self.changed) self.changed(); }
- (void)setPhase:(TX500VoiceState)phase message:(NSString *)message {
    self.state=phase; self.status=message; _stateStart=VoiceNow();
    if(self.active && !_activity) _activity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiated|NSActivityIdleSystemSleepDisabled reason:@"Voice Keyer radio session"];
    if(!self.active && _activity) { [NSProcessInfo.processInfo endActivity:_activity]; _activity=nil; }
    if(self.log) self.log(message); [self notify];
}
- (void)sleep:(NSNotification *)note { (void)note; if(self.active) [self fail:@"Stopped for system sleep. Resume manually when ready."]; }
- (void)connectFrequency:(uint64_t)frequency mode:(NSInteger)mode apply:(BOOL)apply {
    if(self.active || self.radioBusy) return;
    NSUInteger token=++self.generation; self.connected=NO; self.radioBusy=YES;
    [self setPhase:TXVoiceChecking message:apply ? @"Applying frequency and verifying radio…" : @"Reading radio and checking audio mode…"];
    dispatch_async(_worker, ^{
        NSError *error=nil; NSDictionary *state=[self->_radio readState:&error];
        // Do not modify a radio that is already transmitting or in Split/VOX.
        // Changing from DIG/CW to a voice mode is allowed while receiving.
        // Split, XIT, VOX and external PTT are still checked before any write.
        NSMutableDictionary *beforeTune=[state mutableCopy];
        if(apply && beforeTune) beforeTune[@"mode"]=@(mode);
        BOOL safe=state && VoiceStateValid(apply ? beforeTune : state,NO,nil,&error);
        if(safe && apply && token==self.generation) {
            safe=[self->_radio tuneFrequency:frequency mode:mode error:&error];
            if(safe) state=[self->_radio readState:&error];
            safe=safe && state && VoiceStateValid(state,NO,nil,&error);
            if(safe && ([state[@"frequency"] unsignedLongLongValue]!=frequency || [state[@"mode"] integerValue]!=mode)) { safe=NO; error=TXVoiceError(@"The radio did not confirm the requested frequency and mode."); }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if(token!=self.generation) return;
            self.radioBusy=NO; self.connected=safe;
            if(safe) { self.radioState=state; [self setPhase:TXVoiceIdle message:@"Radio verified • ready for a message"]; }
            else [self setPhase:TXVoiceFault message:error.localizedDescription ?: @"Radio verification failed."];
        });
    });
}
- (BOOL)prepareSession {
    if(self.active || self.radioBusy) return NO;
    NSString *reason=nil;
    if(!self.connected) reason=@"Connect and verify the radio first.";
    else if(!self.lineInputConfirmed) reason=@"Set AUDIO IN to ONLY LINE on the radio, then confirm the audio route below.";
    else if(!self.outputUID.length || !self.deviceAvailable(self.outputUID,NO)) reason=@"Choose the connected radio audio output.";
    else if(!isfinite(self.gain) || self.gain<=0 || self.gain>1 || !isfinite(self.listenSeconds) || self.listenSeconds<3 || self.listenSeconds>60 || !isfinite(self.variationSeconds) || self.variationSeconds<0 || self.variationSeconds>2 || !isfinite(self.leadSeconds) || self.leadSeconds<0.1 || self.leadSeconds>1 || !isfinite(self.tailSeconds) || self.tailSeconds<0.1 || self.tailSeconds>1 || self.maximumCalls<1 || self.maximumCalls>100) reason=@"Check the audio level and timing settings.";
    if(reason) { [self setPhase:TXVoiceFault message:reason]; return NO; }
    self.generation++; _sessionOutput=[self.outputUID copy]; _sessionMicrophone=[self.microphoneUID copy];
    _sessionListen=self.listenSeconds; _sessionVariation=self.variationSeconds; _sessionLead=self.leadSeconds; _sessionTail=self.tailSeconds;
    _sessionGain=self.gain; _sessionLimit=self.maximumCalls;
    self.completedCalls=0; self.progress=0; self.remaining=0; _sessionStart=_lastTick=VoiceNow(); _lastPoll=0;
    return YES;
}
- (void)startClip:(TX500VoiceClip *)clip repeat:(BOOL)repeat {
    if(!clip || ![self prepareSession]) return;
    if(repeat && ![clip.role isEqual:@"CQ"]) { [self setPhase:TXVoiceFault message:@"Choose a CQ message for automatic repetition. Replies are sent once."]; return; }
    _clip=clip; _repeat=repeat; _liveRequest=NO;
    [self beginTransmission];
}
- (void)startTalking {
    if(![self prepareSession]) return;
    if(!_sessionMicrophone.length || !self.deviceAvailable(_sessionMicrophone,YES) || [_sessionMicrophone isEqual:_sessionOutput]) { [self setPhase:TXVoiceFault message:@"Select a microphone distinct from the radio audio interface."]; return; }
    _repeat=NO; _liveRequest=YES; _clip=nil;
    [self beginTransmission];
}
- (void)beginTransmission {
    if(!self.deviceAvailable(_sessionOutput,NO)) { [self fail:@"Radio audio output disconnected."]; return; }
    NSError *error=nil;
    if(!_liveRequest) {
        _player.volume=_sessionGain;
        if(![_player prepareURL:_clip.URL device:_sessionOutput error:&error] || !isfinite(_player.duration) || _player.duration<0.25 || _player.duration>60) { [self fail:error.localizedDescription ?: @"The message could not be prepared."]; return; }
    }
    self.progress=0; self.remaining=0; self.radioBusy=YES;
    NSUInteger token=self.generation; NSDictionary *expected=self.radioState;
    [self setPhase:TXVoiceChecking message:@"Checking channel settings before TX…"];
    dispatch_async(_worker, ^{
        if(token!=self.generation) return;
        NSError *e=nil; NSDictionary *state=[self->_radio readState:&e];
        BOOL ok=state && VoiceStateValid(state,NO,expected,&e);
        if(ok && token==self.generation) {
            self->_workerTX=YES;
            ok=[self->_radio setTransmit:YES error:&e];
        } else ok=NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if(token!=self.generation) return;
            self.radioBusy=NO;
            if(!ok) { [self fail:e.localizedDescription ?: @"Transmit cancelled."]; return; }
            self->_lastTick=VoiceNow();
            self->_deadline=VoiceNow()+self->_sessionLead;
            [self setPhase:TXVoiceLead message:@"TX confirmed • preparing audio"];
        });
    });
}
- (void)startAudio {
    NSUInteger token=self.generation;
    if(_liveRequest) {
        NSError *error=nil; _microphone.gain=_sessionGain;
        if(![_microphone startInput:_sessionMicrophone output:_sessionOutput record:NO error:&error]) { [self fail:error.localizedDescription]; return; }
        _deadline=VoiceNow()+60;
        [self setPhase:TXVoiceLive message:@"LIVE MICROPHONE • release Talk to return to receive"];
    } else {
        __weak typeof(self) weakSelf=self;
        _player.completion=^(BOOL success) {
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) self=weakSelf;
                if(!self || token!=self.generation || self.state!=TXVoicePlaying) return;
                if(!success) { [self fail:@"Audio playback failed. Transmission stopped."]; return; }
                self->_deadline=VoiceNow()+self->_sessionTail;
                self.progress=1;
                [self setPhase:TXVoiceTail message:@"Message complete • finishing audio output"];
            });
        };
        [self setPhase:TXVoicePlaying message:[NSString stringWithFormat:@"TRANSMITTING • %@",_clip.title]];
        _deadline=VoiceNow()+_player.duration+2;
        if(![_player play]) [self fail:@"The audio output did not start."];
    }
}
- (void)releaseAfterMessage {
    self.radioBusy=YES; NSUInteger token=self.generation;
    [self setPhase:TXVoiceReleasing message:@"Returning to receive…"];
    dispatch_async(_worker, ^{
        NSError *e=nil; BOOL ok=[self->_radio setTransmit:NO error:&e];
        if(ok) self->_workerTX=NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            if(token!=self.generation) return;
            self.radioBusy=NO;
            if(!ok) { [self fail:e.localizedDescription]; return; }
            self.completedCalls++;
            if(!self->_repeat || self.completedCalls>=self->_sessionLimit) {
                [self->_player stop]; self.remaining=0; self.progress=0;
                [self setPhase:TXVoiceIdle message:self->_repeat ? @"CQ limit reached • listening on the radio" : @"Message sent • listening on the radio"];
            } else {
                double jitter=((double)arc4random_uniform(10001)/5000-1)*self->_sessionVariation;
                self->_deadline=VoiceNow()+MAX(3,self->_sessionListen+jitter);
                self->_lastPoll=0;
                [self setPhase:TXVoiceListening message:@"LISTENING • stop CQ as soon as someone answers"];
            }
        });
    });
}
- (void)pollRadio {
    if(self.radioBusy) return;
    self.radioBusy=YES; _lastPoll=VoiceNow(); NSUInteger token=self.generation;
    BOOL tx=self.state==TXVoicePlaying || self.state==TXVoiceLive || self.state==TXVoiceLead || self.state==TXVoiceTail;
    NSDictionary *expected=self.radioState;
    dispatch_async(_worker, ^{
        if(token!=self.generation) return;
        NSError *e=nil; NSDictionary *s=[self->_radio readState:&e];
        BOOL ok=s && VoiceStateValid(s,tx,expected,&e);
        dispatch_async(dispatch_get_main_queue(), ^{
            if(token!=self.generation) return;
            self.radioBusy=NO;
            // The phase can change while a bounded query is running; its result
            // still describes the snapshot before our next queued CAT operation.
            if(!ok) [self fail:e.localizedDescription ?: @"Radio connection lost."];
        });
    });
}
- (void)tick {
    if(!self.active || self.state==TXVoiceStopping || self.state==TXVoiceChecking) return;
    double now=VoiceNow();
    if(_lastTick>0 && now-_lastTick>2) { [self fail:@"Timing was interrupted. Auto-CQ stopped; resume manually."]; return; }
    _lastTick=now;
    if(now-_sessionStart>1200) { [self fail:@"Session time limit reached. Resume manually when ready."]; return; }
    if(!self.deviceAvailable(_sessionOutput,NO)) { [self fail:@"Radio audio output disconnected. Auto-CQ stopped."]; return; }
    if(self.state==TXVoiceLive && (!self.deviceAvailable(_sessionMicrophone,YES) || _microphone.overflowed)) { [self fail:@"Microphone path interrupted. Transmission stopped."]; return; }
    if(self.state==TXVoiceLead && now>=_deadline) [self startAudio];
    else if(self.state==TXVoicePlaying) {
        self.progress=fmin(1,_player.currentTime/MAX(0.25,_player.duration));
        self.remaining=MAX(0,_player.duration-_player.currentTime);
        if(now>=_deadline) { [self fail:@"Audio completion timed out. Transmission stopped."]; return; }
    } else if(self.state==TXVoiceTail && now>=_deadline) [self releaseAfterMessage];
    else if(self.state==TXVoiceLive) {
        self.remaining=MAX(0,_deadline-now);
        if(now>=_deadline) { [self stop]; return; }
    } else if(self.state==TXVoiceListening) {
        self.remaining=MAX(0,_deadline-now); self.progress=1-fmin(1,self.remaining/MAX(3,_sessionListen+_sessionVariation));
        if(now>=_deadline && !self.radioBusy) { [self beginTransmission]; return; }
    }
    if((self.state==TXVoiceListening || self.state==TXVoicePlaying || self.state==TXVoiceLive) && now-_lastPoll>=1 && !self.radioBusy) [self pollRadio];
    [self notify];
}
- (void)fail:(NSString *)reason { self.connected=NO; [self finishWithFault:reason ?: @"Voice keyer stopped."]; }
- (void)stop { [self finishWithFault:nil]; }
- (void)finishWithFault:(NSString *)fault {
    if(self.state==TXVoiceStopping) return;
    NSUInteger token=++self.generation;
    _repeat=NO; _player.completion=nil; [_player stop]; [_microphone stop];
    self.remaining=0; self.progress=0; self.radioBusy=YES;
    [self setPhase:TXVoiceStopping message:@"Stopping audio and releasing owned PTT…"];
    dispatch_async(_worker, ^{
        NSError *e=nil; BOOL ok=YES;
        if(self->_workerTX) { ok=[self->_radio setTransmit:NO error:&e]; if(ok) self->_workerTX=NO; }
        dispatch_async(dispatch_get_main_queue(), ^{
            if(token!=self.generation) return;
            self.radioBusy=NO;
            if(!ok) self.connected=NO;
            [self setPhase:(fault || !ok) ? TXVoiceFault : TXVoiceIdle message:!ok ? @"RX NOT CONFIRMED — check the radio and release PTT locally." : fault ?: @"Stopped • auto-CQ stays off until you start it again"];
        });
    });
}
- (BOOL)disconnectAndWait {
    // Used for tab ownership transfer and app termination; no worker calls main
    // synchronously, so this bounded drain cannot deadlock the UI.
    ++self.generation; _repeat=NO; _player.completion=nil; [_player stop]; [_microphone stop];
    __block BOOL released=YES;
    dispatch_sync(_worker, ^{
        if(self->_workerTX) { released=[self->_radio setTransmit:NO error:nil]; if(released) self->_workerTX=NO; }
        if(released) [self->_radio close];
    });
    self.connected=NO; self.radioBusy=NO; self.remaining=0; self.progress=0;
    [self setPhase:released ? TXVoiceIdle : TXVoiceFault message:released ? @"Disconnected • auto-CQ is off" : @"RX NOT CONFIRMED — check the radio locally before continuing."];
    return released;
}
- (void)dealloc {
    [_timer invalidate]; if(_activity) [NSProcessInfo.processInfo endActivity:_activity]; [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [_player stop]; [_microphone stop];
    id<TX500VoiceRadio> radio=_radio;
    BOOL tx=_workerTX;
    dispatch_sync(_worker, ^{ if(tx) [radio setTransmit:NO error:nil]; [radio close]; });
}
@end
