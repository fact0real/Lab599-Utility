#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import "TX500CWAudioDecoder.h"
#import <math.h>

@interface TX500CWAudioDecoder (TestInput)
- (void)processRawAudioSamples:(const float *)samples count:(int)count;
- (void)processAudioBuffer:(AVAudioPCMBuffer *)buffer;
- (void)consumeSystemAudio:(const AudioBufferList *)input format:(AVAudioFormat *)format;
@end

static int checks, failures;
static uint64_t rng = 0x92345;
static double Uniform(void) {
    rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
    return ((rng & 0xffffffff)+1.0)/4294967297.0;
}
static double Gaussian(void) { return sqrt(-2*log(Uniform()))*cos(2*M_PI*Uniform()); }

// Independent encoder: exact 1/3/7 spacing, continuous phase and 3 ms keying ramps.
static NSData *Synthesize(NSString *text, double rate, double wpm, double pitch,
                         double amplitude, double sigma, int impairment) {
    NSDictionary *alphabet = TX500CWAudioDecoder.reverseMorseAlphabet;
    NSMutableDictionary *codes = [NSMutableDictionary dictionary];
    for (NSString *key in alphabet) if (key.length > 1 || ![key isEqualToString:@"/"]) codes[alphabet[key]] = key;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)(rate*.4)*sizeof(float)];
    NSArray *words = [text componentsSeparatedByString:@" "];
    for (NSUInteger w = 0; w < words.count; w++) {
        NSString *word = words[w];
        for (NSUInteger c = 0; c < word.length; c++) {
            NSString *code = codes[[word substringWithRange:NSMakeRange(c,1)]];
            for (NSUInteger m = 0; m < code.length; m++) {
                double duration = (1.2/wpm)*([code characterAtIndex:m]=='-' ? 3 : 1);
                NSUInteger start = data.length/sizeof(float), n = (NSUInteger)llround(rate*duration);
                [data increaseLengthBy:n*sizeof(float)]; float *p = data.mutableBytes;
                for (NSUInteger i = 0; i < n; i++) {
                    double t = (start+i)/rate, ramp = fmin(1, fmin(i/(rate*.003), (n-1-i)/(rate*.003)));
                    double gain = impairment == 1 ? .65+.35*cos(2*M_PI*t*.23) : 1;
                    double phase = 2*M_PI*(pitch*t + (impairment == 2 ? 0.5*t*t : 0));
                    p[start+i] = amplitude*gain*(.5-.5*cos(M_PI*ramp))*sin(phase);
                }
                double gap = m+1 < code.length ? 1 : c+1 < word.length ? 3 : w+1 < words.count ? 7 : 0;
                [data increaseLengthBy:(NSUInteger)llround(rate*gap*1.2/wpm)*sizeof(float)];
            }
        }
    }
    [data increaseLengthBy:(NSUInteger)(rate*3)*sizeof(float)];
    float *p = data.mutableBytes; NSUInteger n = data.length/sizeof(float);
    if (impairment == 3) {
        // A delayed acoustic reflection, mixed backwards so only one echo is applied.
        NSUInteger delay = (NSUInteger)(rate*.025);
        for (NSUInteger i = n-1; i >= delay; i--) p[i] += .25*p[i-delay];
    }
    for (NSUInteger i = 0; i < n; i++) p[i] += sigma*Gaussian();
    return data;
}

static NSString *Decode(NSData *data, double rate, int chunk, double nominal, BOOL stereo) {
    TX500CWAudioDecoder *d = [TX500CWAudioDecoder new];
    if (nominal > 0) [d setNominalWPM:nominal];
    AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:rate channels:stereo ? 2 : 1];
    const float *p = data.bytes; NSUInteger n = data.length/sizeof(float);
    for (NSUInteger i = 0; i < n;) { @autoreleasepool {
        int count = MIN((NSUInteger)chunk,n-i);
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:count];
        buffer.frameLength = count;
        memcpy(buffer.floatChannelData[0],p+i,count*sizeof(float));
        if (stereo) for(int j=0;j<count;j++) buffer.floatChannelData[1][j] = -p[i+j];
        [d processAudioBuffer:buffer]; i += count;
    } }
    return [d.rawDecodedText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static void Check(NSString *label, NSString *actual, NSString *expected) {
    checks++;
    if (![actual isEqualToString:expected]) { failures++; printf("FAIL %s expected [%s] got [%s]\n",label.UTF8String,expected.UTF8String,actual.UTF8String); }
}

int main(int argc, const char **argv) { @autoreleasepool {
    setenv("TX500_TEST_MODE","1",1);
    NSString *phrase = @"CQ TEST 59";
    double speeds[] = {3,5,8,13,20,30,40,50,60};
    double pitches[] = {300,450,650,1225,1500};
    for (int s=0;s<9;s++) for(int f=0;f<5;f++) { @autoreleasepool {
        NSData *pcm = Synthesize(phrase,48000,speeds[s],pitches[f],.2,.01,0);
        Check([NSString stringWithFormat:@"blind %.0f WPM %.0f Hz",speeds[s],pitches[f]], Decode(pcm,48000,2048,0,NO),phrase);
    } }
    for (int i=0;i<50;i++) { @autoreleasepool {
        NSMutableString *word=[NSMutableString string];
        for(int c=0;c<6;c++) [word appendFormat:@"%c",(char)('A'+(int)(Uniform()*26))];
        double wpm=5+Uniform()*50, pitch=300+Uniform()*1200;
        NSData *pcm=Synthesize(word,48000,wpm,pitch,.2,.02,0);
        Check([NSString stringWithFormat:@"random %d %.1f WPM %.0f Hz",i,wpm,pitch],Decode(pcm,48000,997,0,NO),word);
    } }
    double rates[] = {8000,16000,44100,48000,96000,192000};
    for(int r=0;r<6;r++) { @autoreleasepool {
        NSData *pcm=Synthesize(phrase,rates[r],20,725,.2,.01,0);
        Check([NSString stringWithFormat:@"rate %.0f anti-phase stereo",rates[r]],Decode(pcm,rates[r],511,0,YES),phrase);
    } }
    for(int gain=0;gain<3;gain++) for(int mode=0;mode<4;mode++) { @autoreleasepool {
        double amplitude=.2*pow(.1,gain);
        NSData *pcm=Synthesize(phrase,48000,18,885,amplitude,amplitude*.15,mode);
        Check([NSString stringWithFormat:@"gain %d impairment %d",gain,mode],Decode(pcm,48000,127,5,NO),phrase);
    } }
    double sigmas[] = {.05,.10,.20,.30};
    for(int i=0;i<4;i++) { @autoreleasepool {
        NSData *pcm=Synthesize(phrase,48000,20,700,.2,sigmas[i],0);
        Check([NSString stringWithFormat:@"Gaussian RMS %.2f",sigmas[i]],Decode(pcm,48000,2048,0,NO),phrase);
    } }
    NSData *silence = [NSMutableData dataWithLength:48000*8*sizeof(float)];
    Check(@"silence",Decode(silence,48000,127,0,NO),@"");
    NSMutableData *noise=[silence mutableCopy]; float *p=noise.mutableBytes;
    for(NSUInteger i=0;i<noise.length/sizeof(float);i++) p[i]=.2*Gaussian();
    Check(@"noise only",Decode(noise,48000,513,0,NO),@"");
    NSMutableData *carrier=[NSMutableData dataWithLength:48000*8*sizeof(float)];
    float *cp=carrier.mutableBytes;
    for(int i=0;i<48000*5;i++) cp[i]=.2*sin(2*M_PI*650*i/48000.0);
    Check(@"continuous carrier",Decode(carrier,48000,127,0,NO),@"");
    TX500CWAudioDecoder *reused=[TX500CWAudioDecoder new];
    [reused feedSyntheticMorseString:@"CQ TEST" wpm:18 pitchHz:650];
    [reused clearBuffer];
    Check(@"clear text",reused.rawDecodedText,@"");
    Check(@"clear active marks",reused.activeCharacterBuffer,@"");
    [reused feedSyntheticMorseString:@"FIELD" wpm:30 pitchHz:1225];
    Check(@"reuse after reset",[reused.rawDecodedText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],@"FIELD");
    TX500CWAudioDecoder *manual=[TX500CWAudioDecoder new];
    manual.afcEnabled=NO;
    [manual feedSyntheticMorseString:@"CQ TEST" wpm:50 pitchHz:650];
    Check(@"manual pitch fast CW",[manual.rawDecodedText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],@"CQ TEST");
    // Exercise the HAL buffer bridge without creating a tap or asking for OS permission.
    for (int interleaved=0;interleaved<2;interleaved++) {
        double rate=44100;
        NSData *pcm=Synthesize(@"SYSTEM AUDIO",rate,22,900,.2,.005,0);
        TX500CWAudioDecoder *tapDecoder=[TX500CWAudioDecoder new];
        AVAudioFormat *format=[[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
            sampleRate:rate channels:2 interleaved:interleaved];
        const float *input=pcm.bytes; NSUInteger n=pcm.length/sizeof(float);
        for(NSUInteger offset=0;offset<n;offset+=511) { @autoreleasepool {
            AVAudioFrameCount count=(AVAudioFrameCount)MIN(511,n-offset);
            AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:count];
            buffer.frameLength=count;
            for(NSUInteger i=0;i<count;i++) {
                if(interleaved) { buffer.floatChannelData[0][2*i]=input[offset+i]; buffer.floatChannelData[0][2*i+1]=-input[offset+i]; }
                else { buffer.floatChannelData[0][i]=input[offset+i]; buffer.floatChannelData[1][i]=-input[offset+i]; }
            }
            [tapDecoder consumeSystemAudio:buffer.audioBufferList format:format];
        } }
        Check(interleaved ? @"system tap interleaved stereo" : @"system tap planar stereo",
            [tapDecoder.rawDecodedText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet],@"SYSTEM AUDIO");
    }
    if (@available(macOS 14.2,*)) {
        TX500CWAudioDecoder *selection=[TX500CWAudioDecoder new];
        selection.selectedAudioDeviceUID=TX500CWSystemAudioDeviceUID;
        [selection refreshAudioDevices];
        Check(@"system audio selection survives refresh",selection.selectedAudioDeviceUID,TX500CWSystemAudioDeviceUID);
        BOOL found=NO;
        for(NSDictionary *device in selection.availableAudioInputDevices)
            if([device[@"uid"] isEqualToString:TX500CWSystemAudioDeviceUID]) found=YES;
        Check(@"system audio appears in inputs",found ? @"YES" : @"NO",@"YES");
        [selection stopListening]; [selection stopListening];
        Check(@"repeated capture stop",selection.isListening ? @"YES" : @"NO",@"NO");
    }
    // A stale carrier lock must not hide a new, weaker station at another pitch.
    // This reproduces the 327 Hz AFC / 1225 Hz spectrum mismatch seen live.
    NSMutableData *stale=[NSMutableData dataWithLength:48000*3*sizeof(float)];
    float *staleSamples=stale.mutableBytes;
    for(int i=0;i<48000*3;i++) staleSamples[i]=.8*sin(2*M_PI*327*i/48000.0);
    [stale appendData:Synthesize(@"CQ TEST",48000,20,1225,.12,.005,0)];
    Check(@"recover stale 327 Hz lock",Decode(stale,48000,512,22,NO),@"CQ TEST");
    // An unrelated short tone in Q's first element gap must not steal AFC.
    NSMutableData *interfered=[Synthesize(@"CQ TEST",48000,20,1225,.2,.005,0) mutableCopy];
    float *ip=interfered.mutableBytes;
    for(int i=(int)(1.485*48000);i<(int)(1.535*48000);i++)
        ip[i]+=.5*sin(2*M_PI*425*i/48000.0);
    Check(@"reject different-pitch transient in element gap",Decode(interfered,48000,512,22,NO),@"CQ TEST");
    // UI updates queued by the audio thread must not resurrect stopped/cleared state.
    TX500CWAudioDecoder *queued=[TX500CWAudioDecoder new];
    __block BOOL lastSignal=NO;
    __block NSString *lastText=@"";
    queued.onMetricsUpdated=^(double wpm,double snr,float level,BOOL signal) { lastSignal=signal; };
    queued.onDecodedTextUpdated=^(NSString *text,NSString *pattern) { lastText=text; };
    [queued feedSyntheticMorseString:@"CQ" wpm:20 pitchHz:650];
    [queued feedSyntheticAudioWithFrequency:650 duration:.3 isMark:YES];
    [queued stopListening];
    [queued clearBuffer];
    [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.05]];
    Check(@"stop drops queued carrier UI",lastSignal ? @"YES" : @"NO",@"NO");
    Check(@"clear drops queued text UI",lastText,@"");
    // User recordings are optional external fixtures; never silently count missing files as passes.
    if(argc>1) {
        NSArray *names=@[@"3",@"4",@"5",@"6",@"7",@"9"];
        NSArray *expected=@[@"OXIDE",@"FIELD",@"COLOR",@"RELAY",@"JAMMER",@"COLD"];
        TX500CWAudioDecoder *continuous=[TX500CWAudioDecoder new];
        for(NSUInteger f=0;f<names.count;f++) { @autoreleasepool {
            NSString *path=[[NSString stringWithUTF8String:argv[1]] stringByAppendingPathComponent:[names[f] stringByAppendingString:@".m4a"]];
            NSString *wavPath=[path.stringByDeletingPathExtension stringByAppendingPathExtension:@"wav"];
            if ([[NSFileManager defaultManager] fileExistsAtPath:wavPath]) path=wavPath;
            NSError *error=nil; AVAudioFile *file=[[AVAudioFile alloc] initForReading:[NSURL fileURLWithPath:path] error:&error];
            if(!file || file.processingFormat.channelCount!=1) { failures++; fprintf(stderr,"Cannot read fixture %s: %s\n",path.UTF8String,error.description.UTF8String); continue; }
            AVAudioPCMBuffer *buffer=[[AVAudioPCMBuffer alloc] initWithPCMFormat:file.processingFormat frameCapacity:(AVAudioFrameCount)file.length];
            if(![file readIntoBuffer:buffer error:&error]) { failures++; fprintf(stderr,"Read failed %s: %s\n",path.UTF8String,error.description.UTF8String); continue; }
            NSData *pcm=[NSData dataWithBytes:buffer.floatChannelData[0] length:buffer.frameLength*sizeof(float)];
            int chunks[]={127,511,512,2048,4093};
            for(int c=0;c<5;c++) for(int speed=0;speed<2;speed++) {
                Check([NSString stringWithFormat:@"%@.m4a chunk %d initial %d WPM",names[f],chunks[c],speed?5:20], Decode(pcm,file.processingFormat.sampleRate,chunks[c],speed?5:20,NO), expected[f]);
            }
            // A callback-size sweep alone does not move the waveform relative to
            // analysis windows. Playback can begin at any sample within a window.
            for(int offset=0;offset<2048;offset+=128) {
                NSMutableData *shifted=[NSMutableData dataWithLength:offset*sizeof(float)];
                [shifted appendData:pcm];
                Check([NSString stringWithFormat:@"%@ playback offset %d",names[f],offset],
                      Decode(shifted,file.processingFormat.sampleRate,512,22,NO),expected[f]);
                if ([names[f] isEqualToString:@"9"]) {
                    NSUInteger prefixFrames=(NSUInteger)(file.processingFormat.sampleRate*20)+offset;
                    Check([NSString stringWithFormat:@"ambient prefix offset %d",offset],
                          Decode([shifted subdataWithRange:NSMakeRange(0,prefixFrames*sizeof(float))],
                                 file.processingFormat.sampleRate,512,22,NO),@"");
                }
            }
            const float *samples=pcm.bytes;
            for(NSUInteger i=0;i<pcm.length/sizeof(float);i+=512) {
                int count=(int)MIN(512,pcm.length/sizeof(float)-i);
                [continuous processRawAudioSamples:samples+i count:count];
            }
            printf("Fixture %s completed\n",[names[f] UTF8String]);
        } }
        Check(@"all six recordings without reset",[continuous.rawDecodedText stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet], [expected componentsJoinedByString:@" "]);
    } else printf("SKIP external M4A fixtures (pass their directory as first argument)\n");
    if (getenv("TX500_CW_CAPTURE_FIXTURE")) {
        NSData *capture=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:getenv("TX500_CW_CAPTURE_FIXTURE")]];
        if(!capture.length) { failures++; fprintf(stderr,"Missing native 48 kHz Float32 capture fixture\n"); }
        else Check(@"replay actual system capture (7,9)",Decode(capture,48000,512,22,NO),@"JAMMER COLD");
    }
    if (getenv("TX500_CW_FULL_CAPTURE_FIXTURE")) {
        NSData *capture=[NSData dataWithContentsOfFile:[NSString stringWithUTF8String:getenv("TX500_CW_FULL_CAPTURE_FIXTURE")]];
        if(!capture.length) { failures++; fprintf(stderr,"Missing full native capture fixture\n"); }
        else Check(@"replay original M4A live capture",Decode(capture,48000,512,22,NO),@"OXIDE FIELD COLOR RELAY JAMMER COLD");
    }
    printf("CW regression: %d checks, %d failures\n",checks,failures);
    return failures ? 1 : 0;
} }
