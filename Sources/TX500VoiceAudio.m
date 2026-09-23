#import "TX500VoiceKeyer.h"
#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>
#import <pthread.h>
#import <math.h>

static AudioDeviceID VoiceDevice(NSString *uid) {
    if (!uid.length) return kAudioObjectUnknown;
    CFStringRef value = (__bridge CFStringRef)uid;
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyTranslateUIDToDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, sizeof(value), &value, &size, &device)) return kAudioObjectUnknown;
    return device;
}
static BOOL VoiceHasChannels(AudioDeviceID device, BOOL input) {
    AudioObjectPropertyAddress a = {kAudioDevicePropertyStreamConfiguration, input ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &a, 0, NULL, &size) || !size) return NO;
    AudioBufferList *list = malloc(size);
    BOOL found = NO;
    if (!AudioObjectGetPropertyData(device, &a, 0, NULL, &size, list))
        for (UInt32 i = 0; i < list->mNumberBuffers; i++) found |= list->mBuffers[i].mNumberChannels > 0;
    free(list); return found;
}
BOOL TXVoiceDeviceAvailable(NSString *uid, BOOL input) {
    AudioDeviceID device = VoiceDevice(uid);
    if (!device || !VoiceHasChannels(device, input)) return NO;
    UInt32 alive = 0, size = sizeof(alive);
    AudioObjectPropertyAddress a = {kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    return !AudioObjectGetPropertyData(device, &a, 0, NULL, &size, &alive) && alive;
}
NSArray<NSDictionary *> *TXVoiceDevices(BOOL input) {
    AudioObjectPropertyAddress a = {kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &a, 0, NULL, &size)) return @[];
    AudioDeviceID *devices = malloc(size);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &a, 0, NULL, &size, devices)) { free(devices); return @[]; }
    NSMutableArray *result = [NSMutableArray array];
    for (NSUInteger i=0; i<size/sizeof(AudioDeviceID); i++) {
        if (!VoiceHasChannels(devices[i], input)) continue;
        CFStringRef uid = NULL, name = NULL;
        UInt32 n = sizeof(CFStringRef);
        a.mSelector = kAudioDevicePropertyDeviceUID;
        AudioObjectGetPropertyData(devices[i], &a, 0, NULL, &n, &uid);
        a.mSelector = kAudioObjectPropertyName;
        AudioObjectGetPropertyData(devices[i], &a, 0, NULL, &n, &name);
        if (uid && name) [result addObject:@{@"uid":(__bridge NSString *)uid, @"name":(__bridge NSString *)name}];
        if (uid) CFRelease(uid); if (name) CFRelease(name);
    }
    free(devices);
    return [result sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]]; }];
}

@interface TX500VoicePlayer () <AVAudioPlayerDelegate>
@property(nonatomic, strong) AVAudioPlayer *player;
@end
@implementation TX500VoicePlayer
@synthesize volume = _volume, completion = _completion;
- (instancetype)init { if ((self = [super init])) _volume = 0.7; return self; }
- (BOOL)prepareURL:(NSURL *)URL device:(NSString *)uid error:(NSError **)error {
    [self stop];
    if (!TXVoiceDeviceAvailable(uid, NO)) { if(error) *error=TXVoiceError(@"Select an available audio output."); return NO; }
    self.player = [[AVAudioPlayer alloc] initWithContentsOfURL:URL error:error];
    self.player.currentDevice = uid;
    self.player.volume = self.volume;
    self.player.delegate = self;
    if (!self.player || ![self.player.currentDevice isEqual:uid] || ![self.player prepareToPlay]) {
        if (error && !*error) *error = TXVoiceError(@"The selected output could not prepare this recording.");
        self.player = nil; return NO;
    }
    return YES;
}
- (double)duration { return self.player.duration; }
- (double)currentTime { return self.player.currentTime; }
- (void)setVolume:(float)volume { _volume = fmaxf(0, fminf(1, volume)); self.player.volume = _volume; }
- (BOOL)play { return [self.player play]; }
- (void)stop { self.player.delegate = nil; [self.player stop]; self.player = nil; }
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    if (player == self.player && self.completion) self.completion(flag);
}
- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player error:(NSError *)error {
    (void)error; if (player == self.player && self.completion) self.completion(NO);
}
@end

#define VOICE_RATE 48000
#define VOICE_RING 48000
#define VOICE_MAX_FRAMES (VOICE_RATE * 60)
@interface TX500VoiceAudioIO () {
    AudioQueueRef _inputQueue, _outputQueue;
    pthread_mutex_t _lock;
    float *_ring, *_recording;
    NSUInteger _readIndex, _writeIndex, _available, _recorded, _captured;
    BOOL _running, _record, _overflowed;
    float _gain;
    double _level;
}
- (void)inputBuffer:(AudioQueueBufferRef)buffer queue:(AudioQueueRef)queue;
- (void)outputBuffer:(AudioQueueBufferRef)buffer queue:(AudioQueueRef)queue;
@end
static void VoiceInput(void *context, AudioQueueRef q, AudioQueueBufferRef b, const AudioTimeStamp *t, UInt32 packets, const AudioStreamPacketDescription *descs) {
    (void)t; (void)packets; (void)descs; [(__bridge TX500VoiceAudioIO *)context inputBuffer:b queue:q];
}
static void VoiceOutput(void *context, AudioQueueRef q, AudioQueueBufferRef b) { [(__bridge TX500VoiceAudioIO *)context outputBuffer:b queue:q]; }
@implementation TX500VoiceAudioIO
- (instancetype)init {
    if ((self = [super init])) { pthread_mutex_init(&_lock,NULL); _ring=calloc(VOICE_RING,sizeof(float)); _gain=0.7; _level=-90; }
    return self;
}
- (BOOL)running { pthread_mutex_lock(&_lock); BOOL v=_running; pthread_mutex_unlock(&_lock); return v; }
- (BOOL)overflowed { pthread_mutex_lock(&_lock); BOOL v=_overflowed; pthread_mutex_unlock(&_lock); return v; }
- (double)level { pthread_mutex_lock(&_lock); double v=_level; pthread_mutex_unlock(&_lock); return v; }
- (double)duration { pthread_mutex_lock(&_lock); double v=(double)_captured/VOICE_RATE; pthread_mutex_unlock(&_lock); return v; }
- (float)gain { pthread_mutex_lock(&_lock); float v=_gain; pthread_mutex_unlock(&_lock); return v; }
- (void)setGain:(float)gain { pthread_mutex_lock(&_lock); _gain=fmaxf(0,fminf(1,gain)); pthread_mutex_unlock(&_lock); }
- (BOOL)startInput:(NSString *)input output:(NSString *)output record:(BOOL)record error:(NSError **)error {
    [self stop];
    if (!TXVoiceDeviceAvailable(input,YES) || (output && !TXVoiceDeviceAvailable(output,NO)) || [input isEqual:output]) {
        if(error) *error=TXVoiceError(@"Choose distinct, available input and output devices."); return NO;
    }
    free(_recording); _recording=record ? calloc(VOICE_MAX_FRAMES,sizeof(float)) : NULL;
    if (!_ring || (record && !_recording)) { if(error) *error=TXVoiceError(@"Unable to allocate audio buffers."); return NO; }
    _record=record; _recorded=_captured=_available=_readIndex=_writeIndex=0; _overflowed=NO; _level=-90;
    AudioStreamBasicDescription f={0};
    f.mSampleRate=VOICE_RATE; f.mFormatID=kAudioFormatLinearPCM;
    f.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked;
    f.mBytesPerPacket=f.mBytesPerFrame=sizeof(float); f.mFramesPerPacket=1; f.mChannelsPerFrame=1; f.mBitsPerChannel=32;
    OSStatus st=AudioQueueNewInput(&f,VoiceInput,(__bridge void *)self,NULL,NULL,0,&_inputQueue);
    CFStringRef inUID=(__bridge CFStringRef)input;
    if (!st) st=AudioQueueSetProperty(_inputQueue,kAudioQueueProperty_CurrentDevice,&inUID,sizeof(inUID));
    if (!st && output) {
        st=AudioQueueNewOutput(&f,VoiceOutput,(__bridge void *)self,NULL,NULL,0,&_outputQueue);
        CFStringRef outUID=(__bridge CFStringRef)output;
        if (!st) st=AudioQueueSetProperty(_outputQueue,kAudioQueueProperty_CurrentDevice,&outUID,sizeof(outUID));
    }
    for (int i=0;!st && i<3;i++) {
        AudioQueueBufferRef b=NULL;
        st=AudioQueueAllocateBuffer(_inputQueue,480*sizeof(float),&b);
        if (!st) st=AudioQueueEnqueueBuffer(_inputQueue,b,0,NULL);
        if (!st && _outputQueue) {
            st=AudioQueueAllocateBuffer(_outputQueue,480*sizeof(float),&b);
            if (!st) { memset(b->mAudioData,0,b->mAudioDataBytesCapacity); b->mAudioDataByteSize=b->mAudioDataBytesCapacity; st=AudioQueueEnqueueBuffer(_outputQueue,b,0,NULL); }
        }
    }
    pthread_mutex_lock(&_lock); _running=!st; pthread_mutex_unlock(&_lock);
    if (!st && _outputQueue) st=AudioQueueStart(_outputQueue,NULL);
    if (!st) st=AudioQueueStart(_inputQueue,NULL);
    if(st) { [self stop]; if(error) *error=TXVoiceError([NSString stringWithFormat:@"Audio device could not start (%d). Check the selected devices and microphone permission.",(int)st]); return NO; }
    return YES;
}
- (void)inputBuffer:(AudioQueueBufferRef)b queue:(AudioQueueRef)q {
    pthread_mutex_lock(&_lock);
    BOOL running=_running;
    if(running) {
        const float *p=b->mAudioData; NSUInteger count=b->mAudioDataByteSize/sizeof(float); double sum=0;
        for(NSUInteger i=0;i<count;i++) {
            float s=isfinite(p[i]) ? p[i] : 0; sum+=s*s;
            if (_record && _recorded<VOICE_MAX_FRAMES) _recording[_recorded++]=s;
            if (_outputQueue) {
                if (_available<VOICE_RING) { _ring[_writeIndex]=fmaxf(-0.95,fminf(0.95,s*_gain)); _writeIndex=(_writeIndex+1)%VOICE_RING; _available++; }
                else _overflowed=YES;
            }
        }
        _captured+=count; _level=10*log10(fmax(sum/MAX(count,1ul),1e-9));
    }
    pthread_mutex_unlock(&_lock);
    if(running && AudioQueueEnqueueBuffer(q,b,0,NULL)) { pthread_mutex_lock(&_lock); _overflowed=YES; pthread_mutex_unlock(&_lock); }
}
- (void)outputBuffer:(AudioQueueBufferRef)b queue:(AudioQueueRef)q {
    pthread_mutex_lock(&_lock); BOOL running=_running;
    if(running) {
        float *p=b->mAudioData; NSUInteger count=b->mAudioDataBytesCapacity/sizeof(float);
        for(NSUInteger i=0;i<count;i++) {
            p[i]=_available ? _ring[_readIndex] : 0;
            if(_available) { _readIndex=(_readIndex+1)%VOICE_RING; _available--; }
        }
        b->mAudioDataByteSize=(UInt32)(count*sizeof(float));
    }
    pthread_mutex_unlock(&_lock);
    if(running && AudioQueueEnqueueBuffer(q,b,0,NULL)) { pthread_mutex_lock(&_lock); _overflowed=YES; pthread_mutex_unlock(&_lock); }
}
- (void)stop {
    pthread_mutex_lock(&_lock); _running=NO; pthread_mutex_unlock(&_lock);
    // Dispose waits for callbacks before any owned memory is reused.
    if(_inputQueue) { AudioQueueStop(_inputQueue,true); AudioQueueDispose(_inputQueue,true); _inputQueue=NULL; }
    if(_outputQueue) { AudioQueueStop(_outputQueue,true); AudioQueueDispose(_outputQueue,true); _outputQueue=NULL; }
}
- (BOOL)writeRecording:(NSURL *)URL error:(NSError **)error {
    [self stop];
    if(_recorded<VOICE_RATE/4) { if(error) *error=TXVoiceError(@"Record at least a quarter of a second."); return NO; }
    AVAudioFormat *format=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:VOICE_RATE channels:1];
    AVAudioPCMBuffer *b=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)_recorded];
    b.frameLength=(AVAudioFrameCount)_recorded; memcpy(b.floatChannelData[0],_recording,_recorded*sizeof(float));
    NSDictionary *settings=@{AVFormatIDKey:@(kAudioFormatLinearPCM),AVSampleRateKey:@VOICE_RATE,AVNumberOfChannelsKey:@1,AVLinearPCMBitDepthKey:@16,AVLinearPCMIsFloatKey:@NO,AVLinearPCMIsBigEndianKey:@NO};
    AVAudioFile *file=[[AVAudioFile alloc] initForWriting:URL settings:settings error:error];
    return file && [file writeFromBuffer:b error:error];
}
- (void)dealloc { [self stop]; free(_ring); free(_recording); pthread_mutex_destroy(&_lock); }
@end
