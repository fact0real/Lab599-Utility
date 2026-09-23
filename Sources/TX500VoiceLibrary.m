#import "TX500VoiceKeyer.h"
#import <math.h>
@implementation TX500VoiceClip
@end
@implementation TX500VoiceLibrary {
    NSMutableArray<TX500VoiceClip *> *_items;
}
- (instancetype)initWithDirectory:(NSURL *)directory {
    if ((self=[super init])) {
        _directory=directory; _items=[NSMutableArray array];
        NSData *data=[NSData dataWithContentsOfURL:[directory URLByAppendingPathComponent:@"library.json"]];
        id json=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([json isKindOfClass:NSArray.class]) for(id row in json) {
            if(![row isKindOfClass:NSDictionary.class] || ![row[@"id"] isKindOfClass:NSString.class] || ![[NSUUID alloc] initWithUUIDString:row[@"id"]]) continue;
            if (![row[@"title"] isKindOfClass:NSString.class] || ![row[@"duration"] isKindOfClass:NSNumber.class]) continue;
            TX500VoiceClip *clip=[TX500VoiceClip new]; clip.identifier=row[@"id"]; clip.title=row[@"title"];
            clip.role=[row[@"role"] isEqual:@"CQ"] ? @"CQ" : @"Reply";
            clip.URL=[directory URLByAppendingPathComponent:[clip.identifier stringByAppendingString:@".wav"]];
            clip.duration=[row[@"duration"] doubleValue];
            if(!isfinite(clip.duration) || clip.duration<0.25 || clip.duration>60) continue;
            NSMutableArray *peaks=[NSMutableArray array];
            if([row[@"peaks"] isKindOfClass:NSArray.class]) for(id n in row[@"peaks"]) {
                if(peaks.count>=160) break;
                if([n isKindOfClass:NSNumber.class] && isfinite([n doubleValue])) [peaks addObject:@(fmax(0,fmin(1,[n doubleValue])))];
            }
            clip.peaks=peaks;
            if([NSFileManager.defaultManager fileExistsAtPath:clip.URL.path]) [_items addObject:clip];
        }
    } return self;
}
- (NSArray *)clips { return [_items copy]; }
- (BOOL)save:(NSError **)error {
    if(![NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    NSMutableArray *rows=[NSMutableArray array];
    for(TX500VoiceClip *c in _items) [rows addObject:@{@"id":c.identifier,@"title":c.title,@"role":c.role,@"duration":@(c.duration),@"peaks":c.peaks}];
    NSData *json=[NSJSONSerialization dataWithJSONObject:rows options:NSJSONWritingPrettyPrinted error:error];
    return json && [json writeToURL:[self.directory URLByAppendingPathComponent:@"library.json"] options:NSDataWritingAtomic error:error];
}
- (TX500VoiceClip *)importURL:(NSURL *)URL title:(NSString *)title role:(NSString *)role error:(NSError **)error {
    AVAudioFile *source=[[AVAudioFile alloc] initForReading:URL commonFormat:AVAudioPCMFormatFloat32 interleaved:NO error:error];
    if(!source) return nil;
    AVAudioFormat *format=source.processingFormat;
    double duration=(double)source.length/format.sampleRate;
    if(!isfinite(duration) || duration<0.25 || duration>60 || format.channelCount>2 || format.sampleRate>96000 || format.sampleRate<8000) {
        if(error) *error=TXVoiceError(@"Use a mono or stereo recording of 0.25–60 seconds at 8–96 kHz."); return nil;
    }
    AVAudioPCMBuffer *input=[[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:(AVAudioFrameCount)source.length];
    if(!input || ![source readIntoBuffer:input error:error]) return nil;
    NSUInteger count=input.frameLength;
    AVAudioFormat *mono=[[AVAudioFormat alloc] initStandardFormatWithSampleRate:format.sampleRate channels:1];
    AVAudioPCMBuffer *output=[[AVAudioPCMBuffer alloc] initWithPCMFormat:mono frameCapacity:(AVAudioFrameCount)count];
    float *samples=output.floatChannelData[0]; float peak=0;
    for(NSUInteger i=0;i<count;i++) {
        float s=0; for(UInt32 c=0;c<format.channelCount;c++) s+=input.floatChannelData[c][i]/format.channelCount;
        samples[i]=isfinite(s) ? s : 0; peak=fmaxf(peak,fabsf(samples[i]));
    }
    if(peak<0.00003) { if(error) *error=TXVoiceError(@"This recording is silent. Check your microphone and record again."); return nil; }
    // Remove only near-digital silence, retaining 80 ms breathing room at both ends.
    NSUInteger first=0,last=count; float threshold=peak*0.001;
    while(first<count && fabsf(samples[first])<threshold) first++;
    while(last>first && fabsf(samples[last-1])<threshold) last--;
    NSUInteger pad=(NSUInteger)(0.08*format.sampleRate);
    first=first>pad ? first-pad : 0; last=MIN(count,last+pad);
    NSUInteger frames=last-first;
    if(frames<format.sampleRate*0.25) { if(error) *error=TXVoiceError(@"The audible message is too short."); return nil; }
    float scale=fminf(2.0,0.70795/peak); // ≤ +6 dB; -3 dBFS peak ceiling
    for(NSUInteger i=0;i<frames;i++) samples[i]=samples[i+first]*scale;
    output.frameLength=(AVAudioFrameCount)frames;
    TX500VoiceClip *clip=[TX500VoiceClip new]; clip.identifier=NSUUID.UUID.UUIDString;
    clip.title=title.length ? title : URL.lastPathComponent.stringByDeletingPathExtension;
    clip.role=[role isEqual:@"CQ"] ? @"CQ" : @"Reply";
    clip.duration=(double)frames/format.sampleRate;
    NSMutableArray *peaks=[NSMutableArray array];
    for(NSUInteger bin=0;bin<160;bin++) {
        float p=0; for(NSUInteger i=bin*frames/160;i<(bin+1)*frames/160;i++) p=fmaxf(p,fabsf(samples[i]));
        [peaks addObject:@(p)];
    }
    clip.peaks=peaks;
    if(![NSFileManager.defaultManager createDirectoryAtURL:self.directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    clip.URL=[self.directory URLByAppendingPathComponent:[clip.identifier stringByAppendingString:@".wav"]];
    NSDictionary *settings=@{AVFormatIDKey:@(kAudioFormatLinearPCM),AVSampleRateKey:@(format.sampleRate),AVNumberOfChannelsKey:@1,AVLinearPCMBitDepthKey:@16,AVLinearPCMIsFloatKey:@NO,AVLinearPCMIsBigEndianKey:@NO};
    AVAudioFile *file=[[AVAudioFile alloc] initForWriting:clip.URL settings:settings error:error];
    BOOL written=file && [file writeFromBuffer:output error:error]; file=nil;
    if(!written) { [NSFileManager.defaultManager removeItemAtURL:clip.URL error:nil]; return nil; }
    [_items addObject:clip];
    if(![self save:error]) { [_items removeObject:clip]; [NSFileManager.defaultManager removeItemAtURL:clip.URL error:nil]; return nil; }
    return clip;
}
- (BOOL)renameClip:(TX500VoiceClip *)clip title:(NSString *)title role:(NSString *)role error:(NSError **)error {
    title=[title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(![_items containsObject:clip] || !title.length) { if(error) *error=TXVoiceError(@"Give the message a name."); return NO; }
    NSString *oldTitle=clip.title,*oldRole=clip.role; clip.title=title; clip.role=[role isEqual:@"CQ"] ? @"CQ" : @"Reply";
    if([self save:error]) return YES; clip.title=oldTitle; clip.role=oldRole; return NO;
}
- (BOOL)removeClip:(TX500VoiceClip *)clip error:(NSError **)error {
    NSUInteger index=[_items indexOfObject:clip]; if(index==NSNotFound) return NO;
    [_items removeObjectAtIndex:index];
    if(![self save:error]) { [_items insertObject:clip atIndex:index]; return NO; }
    // Retain removed audio in a local archive so removing a card is reversible.
    NSURL *archive=[self.directory URLByAppendingPathComponent:@"Removed" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:archive withIntermediateDirectories:YES attributes:nil error:nil];
    [NSFileManager.defaultManager moveItemAtURL:clip.URL toURL:[archive URLByAppendingPathComponent:clip.URL.lastPathComponent] error:nil];
    return YES;
}
@end
