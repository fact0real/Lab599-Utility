#import "TX500VoiceKeyer.h"
#import "TX500VoiceKeyerController.h"
#import "Lab599SerialPort.h"
#import <util.h>
#import <unistd.h>
#import <poll.h>
#import <fcntl.h>
#import <math.h>
#import <CoreAudio/CoreAudio.h>

static NSInteger checks=0;
static void Check(BOOL ok, NSString *message) { checks++; if(!ok) { fprintf(stderr,"FAIL: %s\n",message.UTF8String); exit(1); } }
static void Pump(double seconds) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:seconds];
    while(end.timeIntervalSinceNow>0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(0.01,end.timeIntervalSinceNow)]];
}
static BOOL Until(BOOL (^predicate)(void),double timeout) {
    NSDate *end=[NSDate dateWithTimeIntervalSinceNow:timeout];
    while(!predicate() && end.timeIntervalSinceNow>0) Pump(0.01);
    return predicate();
}
@interface VoiceRadioFake : NSObject <TX500VoiceRadio>
@property(atomic,copy) NSDictionary *snapshot;
@property(atomic) NSInteger keys;
@property(atomic) NSInteger releases;
@property(atomic) NSInteger reads;
@property(atomic) BOOL failKey;
@property(atomic) BOOL failRelease;
@property(atomic) double readDelay;
@property(atomic) double keyDelay;
@end
@implementation VoiceRadioFake
- (instancetype)init { if((self=[super init])) _snapshot=@{@"frequency":@14200000,@"mode":@2,@"rxVFO":@0,@"txVFO":@0,@"xit":@0,@"vox":@0,@"tx":@0}; return self; }
- (NSDictionary *)readState:(NSError **)error { (void)error; self.reads++; if(self.readDelay) usleep((useconds_t)(self.readDelay*1e6)); return self.snapshot; }
- (BOOL)tuneFrequency:(uint64_t)f mode:(NSInteger)m error:(NSError **)error { (void)error; NSMutableDictionary *s=[self.snapshot mutableCopy]; s[@"frequency"]=@(f); s[@"mode"]=@(m); self.snapshot=s; return YES; }
- (BOOL)setTransmit:(BOOL)tx error:(NSError **)error {
    if(tx) self.keys++; else self.releases++;
    if(tx && self.keyDelay) usleep((useconds_t)(self.keyDelay*1e6));
    NSMutableDictionary *s=[self.snapshot mutableCopy]; s[@"tx"]=@(tx || self.failRelease ? 1 : 0); self.snapshot=s;
    BOOL ok=tx ? !self.failKey : !self.failRelease;
    if(!ok && error) *error=TXVoiceError(@"Injected CAT failure"); return ok;
}
- (void)close {}
@end
@interface VoicePlayerFake : NSObject <TX500VoicePlayback>
@property(nonatomic) NSInteger plays;
@property(nonatomic) NSInteger stops;
@property(nonatomic) BOOL failPrepare;
@property(nonatomic) BOOL failPlay;
@property(nonatomic) double duration;
@property(nonatomic) double currentTime;
@property(nonatomic) float volume;
@property(nonatomic,copy) void (^completion)(BOOL);
@end
@implementation VoicePlayerFake
@synthesize duration=_duration,currentTime=_currentTime,volume=_volume,completion=_completion;
- (instancetype)init { if((self=[super init])) _duration=0.5; return self; }
- (BOOL)prepareURL:(NSURL *)url device:(NSString *)uid error:(NSError **)error { (void)url; (void)uid; if(self.failPrepare && error) *error=TXVoiceError(@"Missing recording"); return !self.failPrepare; }
- (BOOL)play { self.plays++; return !self.failPlay; }
- (void)stop { self.stops++; }
@end
static TX500VoiceClip *Clip(NSString *role) { TX500VoiceClip *c=[TX500VoiceClip new]; c.title=@"CQ test"; c.role=role; c.URL=[NSURL fileURLWithPath:@"/tmp/voice-test.wav"]; c.duration=0.5; return c; }
static TX500VoiceKeyer *Keyer(VoiceRadioFake *r,VoicePlayerFake *p) {
    TX500VoiceKeyer *k=[[TX500VoiceKeyer alloc] initWithRadio:r player:p];
    k.outputUID=@"radio"; k.microphoneUID=@"mic"; k.lineInputConfirmed=YES;
    k.deviceAvailable=^BOOL(NSString *uid,BOOL input) { (void)input; return uid.length>0; };
    k.leadSeconds=0.1; k.tailSeconds=0.1; k.listenSeconds=3;
    [k connectFrequency:0 mode:2 apply:NO];
    Check(Until(^BOOL { return !k.active; },1),@"Read radio completes"); Check(k.connected,@"Radio validated"); return k;
}
static void Finish(VoicePlayerFake *p) { Check(p.completion!=nil,@"Completion registered"); p.completion(YES); }
static void TestSequencing(void) {
    @autoreleasepool {
        VoiceRadioFake *r=[VoiceRadioFake new]; VoicePlayerFake *p=[VoicePlayerFake new]; TX500VoiceKeyer *k=Keyer(r,p);
        Check(r.keys==0,@"Connecting never keys transmitter");
        k.lineInputConfirmed=NO; [k startClip:Clip(@"CQ") repeat:NO]; Check(r.keys==0 && k.state==TXVoiceFault,@"Unconfirmed line route blocks TX");
        k.lineInputConfirmed=YES; [k startClip:Clip(@"Reply") repeat:YES]; Check(r.keys==0 && k.state==TXVoiceFault,@"Reply cannot become repeating CQ");
        k.gain=NAN; [k startClip:Clip(@"CQ") repeat:NO]; Check(r.keys==0,@"Nonfinite settings block TX"); k.gain=0.7;
        [k startClip:Clip(@"CQ") repeat:NO]; Check(Until(^BOOL{return k.state==TXVoicePlaying;},1),@"TX reaches playback");
        Check(r.keys==1 && p.plays==1,@"Playback follows a confirmed TX");
        Finish(p); Check(Until(^BOOL{return k.state==TXVoiceTail;},0.08),@"End of playback retains tail guard"); Check(r.releases==0,@"No early RX before tail");
        Check(Until(^BOOL{return !k.active;},1),@"Single message returns to RX"); Check(r.releases==1 && k.completedCalls==1,@"One shot releases once and counts success");
        Pump(0.15); Check(r.keys==1,@"Single shot never repeats");
        [k disconnectAndWait];
    }
    @autoreleasepool {
        VoiceRadioFake *r=[VoiceRadioFake new]; VoicePlayerFake *p=[VoicePlayerFake new]; TX500VoiceKeyer *k=Keyer(r,p);
        r.readDelay=0.15; [k startClip:Clip(@"CQ") repeat:YES];
        Check(Until(^BOOL{return r.reads>=2;},0.2),@"Preflight started"); [k stop];
        Check(Until(^BOOL{return !k.active;},1),@"Stop drains preflight"); Check(r.keys==0 && p.plays==0,@"Stop during check cancels queued TX"); [k disconnectAndWait];
    }
    @autoreleasepool {
        VoiceRadioFake *r=[VoiceRadioFake new]; VoicePlayerFake *p=[VoicePlayerFake new]; TX500VoiceKeyer *k=Keyer(r,p);
        r.keyDelay=0.15; [k startClip:Clip(@"CQ") repeat:YES];
        Check(Until(^BOOL{return r.keys==1;},0.3),@"TX request in flight"); [k stop];
        Check(Until(^BOOL{return !k.active;},1),@"Stop handles late TX acknowledgement");
        Check(p.plays==0 && r.releases==1,@"Late TX is released without playback"); [k disconnectAndWait];
    }
    @autoreleasepool {
        VoiceRadioFake *r=[VoiceRadioFake new]; VoicePlayerFake *p=[VoicePlayerFake new]; TX500VoiceKeyer *k=Keyer(r,p);
        [k startClip:Clip(@"CQ") repeat:YES]; Check(Until(^BOOL{return k.state==TXVoicePlaying;},1),@"Playback started for cancellation test");
        void (^late)(BOOL)=[p.completion copy]; [k stop]; late(YES);
        Check(Until(^BOOL{return !k.active;},1),@"Stop finishes with stale completion"); Pump(0.2);
        Check(r.keys==1 && r.releases==1 && k.completedCalls==0,@"Stale completion cannot count or reschedule CQ"); [k disconnectAndWait];
    }
    @autoreleasepool {
        VoiceRadioFake *r=[VoiceRadioFake new]; VoicePlayerFake *p=[VoicePlayerFake new]; TX500VoiceKeyer *k=Keyer(r,p);
        k.maximumCalls=2; [k startClip:Clip(@"CQ") repeat:YES]; Check(Until(^BOOL{return k.state==TXVoicePlaying;},1),@"First CQ started"); Finish(p);
        Check(Until(^BOOL{return k.state==TXVoiceListening;},1),@"First CQ opens receive window"); Pump(2.6); Check(r.keys==1,@"Full receive window is measured after RX acknowledgement");
        Check(Until(^BOOL{return k.state==TXVoicePlaying;},1.5),@"Second CQ starts only after receive gap"); Finish(p);
        Check(Until(^BOOL{return !k.active;},1),@"Repeat limit ends session"); Check(r.keys==2 && r.releases==2 && k.completedCalls==2,@"Maximum calls enforced exactly"); [k disconnectAndWait];
    }
    @autoreleasepool {
        VoiceRadioFake *r=[VoiceRadioFake new]; VoicePlayerFake *p=[VoicePlayerFake new]; TX500VoiceKeyer *k=Keyer(r,p);
        [k startClip:Clip(@"CQ") repeat:YES]; Check(Until(^BOOL{return k.state==TXVoicePlaying;},1),@"CQ for listen cancellation"); Finish(p);
        Check(Until(^BOOL{return k.state==TXVoiceListening;},1),@"Listening before stop"); [k stop];
        Check(Until(^BOOL{return !k.active;},1),@"Listening stop completes"); Pump(3.2); Check(r.keys==1,@"Stop cancels future CQ timer"); [k disconnectAndWait];
    }
}
static void TestFaults(void) {
    for(NSString *field in @[@"mode",@"txVFO",@"rxVFO",@"xit",@"vox",@"tx",@"frequency"]) {
        VoiceRadioFake *r=[VoiceRadioFake new]; VoicePlayerFake *p=[VoicePlayerFake new]; TX500VoiceKeyer *k=Keyer(r,p);
        NSMutableDictionary *s=[r.snapshot mutableCopy]; s[field]=[field isEqual:@"mode"] ? @3 : [field isEqual:@"frequency"] ? @14210000 : @1; r.snapshot=s;
        [k startClip:Clip(@"CQ") repeat:NO]; Check(Until(^BOOL{return !k.active;},1),[NSString stringWithFormat:@"%@ preflight failure handled",field]);
        Check(r.keys==0 && r.releases==0,@"Changed radio settings do not key or release someone else's PTT"); [k disconnectAndWait];
    }
    for(NSInteger scenario=0;scenario<5;scenario++) {
        VoiceRadioFake *r=[VoiceRadioFake new]; VoicePlayerFake *p=[VoicePlayerFake new]; TX500VoiceKeyer *k=Keyer(r,p);
        if(scenario==0) r.failKey=YES;
        if(scenario==1) p.failPrepare=YES;
        if(scenario==2) p.failPlay=YES;
        [k startClip:Clip(@"CQ") repeat:NO];
        if(scenario>=3) {
            Check(Until(^BOOL{return k.state==TXVoicePlaying;},1),@"Playback for injected fault");
            if(scenario==3) { k.deviceAvailable=^BOOL(NSString *uid,BOOL input){(void)uid;(void)input;return NO;}; }
            else { r.failRelease=YES; Finish(p); }
        }
        Check(Until(^BOOL{return k.state==TXVoiceFault;},2),@"Injected failure stops session");
        if(scenario==1) Check(r.keys==0,@"Decode failure never asserts PTT");
        else Check(r.releases>=1,@"Failure attempts to release owned PTT");
        if(scenario==4) {
            Check(![k disconnectAndWait],@"Unconfirmed RX prevents ownership handoff");
            r.failRelease=NO; [k stop]; Check(Until(^BOOL{return !k.active;},1),@"Operator can retry RX release");
            Check([r.snapshot[@"tx"] isEqual:@0],@"Retry actually confirms RX");
        }
        [k disconnectAndWait];
    }
    VoiceRadioFake *r=[VoiceRadioFake new]; VoicePlayerFake *p=[VoicePlayerFake new]; TX500VoiceKeyer *k=Keyer(r,p);
    NSMutableDictionary *digital=[r.snapshot mutableCopy]; digital[@"mode"]=@6; r.snapshot=digital;
    [k connectFrequency:7100000 mode:1 apply:YES];
    Check(Until(^BOOL{return !k.active;},1) && k.connected && [r.snapshot[@"mode"] isEqual:@1],@"Apply can switch safely from DIG to LSB");
    [k startClip:Clip(@"CQ") repeat:YES]; Check(Until(^BOOL{return k.state==TXVoicePlaying;},1),@"Playing for change detection");
    NSMutableDictionary *s=[r.snapshot mutableCopy]; s[@"frequency"]=@14201000; r.snapshot=s;
    Check(Until(^BOOL{return k.state==TXVoiceFault;},1.5),@"Frequency knob change interrupts active CQ"); Check(r.releases==1,@"Changed frequency releases owned TX"); [k disconnectAndWait];
}
static NSURL *MakeWAV(NSURL *root,BOOL silence) {
    NSURL *url=[root URLByAppendingPathComponent:silence ? @"silence.wav" : @"input.wav"];
    AVAudioFormat *f=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
    AVAudioPCMBuffer *b=[[AVAudioPCMBuffer alloc] initWithPCMFormat:f frameCapacity:48000]; b.frameLength=48000;
    for(NSUInteger i=0;i<48000;i++) { float s=!silence && i>4800 && i<43200 ? 0.8*sin(2*M_PI*600*i/48000) : 0; b.floatChannelData[0][i]=s; b.floatChannelData[1][i]=s; }
    NSError *e=nil; AVAudioFile *file=[[AVAudioFile alloc] initForWriting:url settings:f.settings error:&e]; Check(file && [file writeFromBuffer:b error:&e],@"WAV fixture written"); return url;
}
static void TestLibrary(NSURL *root) {
    NSURL *dir=[root URLByAppendingPathComponent:@"library"];
    TX500VoiceLibrary *library=[[TX500VoiceLibrary alloc] initWithDirectory:dir]; NSError *e=nil;
    Check(![library importURL:MakeWAV(root,YES) title:@"Silent" role:@"CQ" error:&e],@"Silent recordings rejected");
    TX500VoiceClip *clip=[library importURL:MakeWAV(root,NO) title:@"My CQ" role:@"CQ" error:&e];
    Check(clip!=nil,@"Stereo speech fixture imported"); Check(clip.duration>0.9 && clip.duration<=1,@"Edge trim retains breathing room"); Check(clip.peaks.count==160,@"Real waveform peaks saved");
    AVAudioFile *file=[[AVAudioFile alloc] initForReading:clip.URL error:&e]; Check(file.processingFormat.channelCount==1,@"Recording stored as mono");
    AVAudioPCMBuffer *b=[[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:(AVAudioFrameCount)file.length]; [file readIntoBuffer:b error:&e];
    float peak=0; for(NSUInteger i=0;i<b.frameLength;i++) peak=fmaxf(peak,fabsf(b.floatChannelData[0][i])); Check(peak<0.709 && peak>0.70,@"Normalization leaves -3 dBFS headroom");
    Check([library renameClip:clip title:@"  Reply  " role:@"Reply" error:&e],@"Rename persisted");
    TX500VoiceLibrary *loaded=[[TX500VoiceLibrary alloc] initWithDirectory:dir]; Check(loaded.clips.count==1 && [loaded.clips.firstObject.title isEqual:@"Reply"] && [loaded.clips.firstObject.role isEqual:@"Reply"],@"Library roundtrip preserves title and role");
    Check([loaded removeClip:loaded.clips.firstObject error:&e],@"Message removed"); Check([NSFileManager.defaultManager fileExistsAtPath:[[dir URLByAppendingPathComponent:@"Removed"] URLByAppendingPathComponent:clip.URL.lastPathComponent].path],@"Removed recording recoverable");
    NSDictionary *bad=@{@"id":@"../../escape",@"title":@"Bad",@"duration":@1};
    NSData *json=[NSJSONSerialization dataWithJSONObject:@[bad] options:0 error:nil]; [json writeToURL:[dir URLByAppendingPathComponent:@"library.json"] atomically:YES];
    Check([[TX500VoiceLibrary alloc] initWithDirectory:dir].clips.count==0,@"Manifest path traversal rejected");
    Check(![library importURL:[root URLByAppendingPathComponent:@"missing.mp3"] title:@"Missing" role:@"CQ" error:&e],@"Missing media reported");
}
static void TestCAT(void) {
    int master=-1,slave=-1; char path[256]={0}; Check(openpty(&master,&slave,path,NULL,NULL)==0,@"PTY radio created"); close(slave);
    __block BOOL transmitting=NO; __block double pttSettlesAt=0; __block NSString *frequency=@"00014200000"; __block NSString *mode=@"2";
    NSMutableArray *commands=[NSMutableArray array]; dispatch_group_t group=dispatch_group_create();
    dispatch_queue_t queue=dispatch_queue_create("voice.test.radio",DISPATCH_QUEUE_SERIAL);
    __block BOOL quit=NO;
    dispatch_group_async(group,queue,^{
        NSMutableString *pending=[NSMutableString string];
        while(YES) {
            @synchronized(commands) { if(quit) break; }
            struct pollfd fd={master,POLLIN,0}; if(poll(&fd,1,20)<=0) continue;
            char buf[128]; ssize_t n=read(master,buf,sizeof(buf)); if(n<=0) { usleep(1000); continue; }
            NSString *part=[[NSString alloc] initWithBytes:buf length:n encoding:NSASCIIStringEncoding]; if(part) [pending appendString:part];
            while([pending containsString:@";"]) {
                NSRange end=[pending rangeOfString:@";"]; NSString *cmd=[pending substringToIndex:end.location+1]; [pending deleteCharactersInRange:NSMakeRange(0,end.location+1)];
                @synchronized(commands) { [commands addObject:cmd]; }
                NSString *reply=nil;
                if([cmd isEqual:@"FA;"]) reply=[NSString stringWithFormat:@"FA%@;",frequency];
                else if([cmd hasPrefix:@"FA"]) frequency=[cmd substringWithRange:NSMakeRange(2,11)];
                else if([cmd isEqual:@"MD;"]) reply=[NSString stringWithFormat:@"MD%@;",mode];
                else if([cmd hasPrefix:@"MD"]) mode=[cmd substringWithRange:NSMakeRange(2,1)];
                else if([cmd isEqual:@"PT;"]) reply=(Lab599MonotonicTime() < pttSettlesAt ? !transmitting : transmitting) ? @"PT1;" : @"PT0;";
                else if([cmd isEqual:@"TX;"]) { transmitting=YES; pttSettlesAt=Lab599MonotonicTime()+0.25; }
                else if([cmd isEqual:@"RX;"]) { transmitting=NO; pttSettlesAt=Lab599MonotonicTime()+0.25; }
                else if([@[@"FR;",@"FT;",@"XT;",@"VX;"] containsObject:cmd]) reply=[[cmd substringToIndex:2] stringByAppendingString:@"0;"];
                else reply=@"?;";
                if(reply) { NSData *data=[reply dataUsingEncoding:NSASCIIStringEncoding]; const char *p=data.bytes; write(master,p,1); usleep(1000); write(master,p+1,data.length-1); }
            }
        }
    });
    TX500VoiceCATRadio *radio=[[TX500VoiceCATRadio alloc] initWithPort:[NSString stringWithUTF8String:path]]; NSError *e=nil;
    NSDictionary *s=[radio readState:&e]; Check(s && [s[@"frequency"] isEqual:@14200000],@"CAT handles fragmented status frames");
    Check([radio tuneFrequency:7100000 mode:1 error:&e],@"CAT sets requested voice frequency");
    s=[radio readState:&e]; Check([s[@"frequency"] isEqual:@7100000] && [s[@"mode"] isEqual:@1],@"CAT frequency/mode readback");
    Check([radio setTransmit:YES error:&e],@"CAT TX verified after delayed PT transition"); Check([radio setTransmit:NO error:&e],@"CAT RX verified after delayed PT transition");
    @synchronized(commands) { Check(![commands containsObject:@"TX1;"],@"No undocumented TX audio selector"); quit=YES; }
    [radio close]; dispatch_group_wait(group,DISPATCH_TIME_FOREVER); close(master);
}
static void TestSilentNativePlayback(NSURL *root) {
    NSString *uid=nil;
    for(NSDictionary *row in TXVoiceDevices(NO)) {
        CFStringRef value=(__bridge CFStringRef)row[@"uid"]; AudioDeviceID device=0;
        UInt32 size=sizeof(device);
        AudioObjectPropertyAddress a={kAudioHardwarePropertyTranslateUIDToDevice,kAudioObjectPropertyScopeGlobal,kAudioObjectPropertyElementMain};
        if(AudioObjectGetPropertyData(kAudioObjectSystemObject,&a,sizeof(value),&value,&size,&device)) continue;
        UInt32 transport=0; size=sizeof(transport); a.mSelector=kAudioDevicePropertyTransportType;
        if(!AudioObjectGetPropertyData(device,&a,0,NULL,&size,&transport) && transport==kAudioDeviceTransportTypeBuiltIn) { uid=row[@"uid"]; break; }
    }
    Check(uid!=nil,@"Built-in output available for silent playback smoke test");
    Check(TXVoiceDeviceAvailable(uid,NO),@"Selected real device is recognized as available");
    TX500VoicePlayer *player=[TX500VoicePlayer new]; player.volume=0;
    NSError *error=nil; Check([player prepareURL:MakeWAV(root,NO) device:uid error:&error],error.localizedDescription ?: @"Native player binds explicit device UID");
    __block BOOL finished=NO,success=NO;
    player.completion=^(BOOL ok){success=ok;finished=YES;};
    Check([player play],@"Native silent playback starts");
    Check(Until(^BOOL{return finished;},3) && success,@"Native playback emits successful completion");
    [player stop];
}
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        (void)argc; (void)argv;
        [NSApplication sharedApplication];
        char path[]="/tmp/VoiceKeyerTests.XXXXXX"; Check(mkdtemp(path)!=NULL,@"Temporary test directory"); NSURL *root=[NSURL fileURLWithPath:[NSString stringWithUTF8String:path] isDirectory:YES];
        TestLibrary(root); TestCAT(); TestSequencing(); TestFaults();
        if([NSProcessInfo.processInfo.arguments containsObject:@"--audio-smoke"]) TestSilentNativePlayback(root);
        Check(!TXVoiceDeviceAvailable(@"missing-device-for-test",NO),@"Disconnected output never silently defaults");
        if([NSProcessInfo.processInfo.arguments containsObject:@"--render"]) {
            setenv("TX500_VOICE_TEST_ROOT",path,1);
            TX500VoiceLibrary *library=[[TX500VoiceLibrary alloc] initWithDirectory:[root URLByAppendingPathComponent:@"Lab599 Utility/Voice Keyer"]];
            [library importURL:MakeWAV(root,NO) title:@"CQ · EP2AES" role:@"CQ" error:nil];
            [library importURL:MakeWAV(root,NO) title:@"Thanks for the call" role:@"Reply" error:nil];
            for(NSNumber *width in @[@940,@700,@540]) {
                TX500VoiceKeyerController *controller=[TX500VoiceKeyerController new];
                CGFloat w=width.doubleValue;
                NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,w,1300) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
                window.contentView=controller.view;
                NSLayoutConstraint *wc=[controller.view.widthAnchor constraintEqualToConstant:w]; wc.active=YES;
                [controller activate];
                for(int pass=0;pass<3;pass++) { [window layoutIfNeeded]; [controller.view layoutSubtreeIfNeeded]; }
                Check(!controller.view.hasAmbiguousLayout,@"Voice panel has unambiguous layout");
                Check(fabs(controller.view.bounds.size.width-w)<1,@"Voice panel respects available width");
                NSBitmapImageRep *rep=[controller.view bitmapImageRepForCachingDisplayInRect:controller.view.bounds]; [controller.view cacheDisplayInRect:controller.view.bounds toBitmapImageRep:rep];
                NSData *png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
                [png writeToFile:[NSString stringWithFormat:@"validation/voice-keyer-panel-%@.png",width] atomically:YES];
                fprintf(stdout,"Voice layout %s: frame %s, fitting %s\n",width.description.UTF8String,NSStringFromRect(controller.view.frame).UTF8String,NSStringFromSize(controller.view.fittingSize).UTF8String);
                [controller deactivate];
            }
        }
        fprintf(stdout,"PASS: %ld Voice Keyer checks; no physical radio or PTT used.\n",(long)checks);
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
    } return 0;
}
