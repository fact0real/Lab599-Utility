// SPDX-License-Identifier: GPL-3.0-or-later
// The SSTV screen and engine, without a window and without the microphone: every picture comes
// from a WAV file. A "test radio" delivers a WAV and says it is live, to test what happens with a
// picture from the radio. The WAVs (and the core's own decode of each, for comparison) are made
// beforehand, in the folder given as the first argument.
#import <Cocoa/Cocoa.h>
#import "TX500SSTVEngine.h"
#import "TX500SSTVStationController.h"
#import "TX500SSTVOptionNotes.h"
#import "TX500LogbookManager.h"
#import "TX500SSTVRecordingStore.h"
#import "TX500FaxEngine.h"
#import "TX500CloudSyncEngine.h"
#import "TX500LogbookController.h"
#import "TX500SecretStore.h"
#import <objc/runtime.h>

// the Logbook's own form, as its buttons reach it (these are the controller's own, not declared in its header)
// the screen's words for each notice of the receiver
@interface TX500SSTVEngine (SSTVTests)
+ (NSString *)textForKind:(TX500SSTVNoticeKind)kind mode:(NSString *)mode vis:(int)vis offset:(double)offset;
@end

@interface TX500SSTVStationController (SSTVTests)
@property (nonatomic) BOOL choiceWaiting;
- (NSButton *)openButton;
- (void)refreshDraftInfo;
- (NSStackView *)galleryStack;
@end

@interface TX500LogbookController (SSTVTests)
- (NSTableView *)tableView;
- (NSMutableArray<TX500LogRecord *> *)displayedContacts;
- (NSTextField *)callsignField;
- (void)editSelectedContact:(id)sender;
- (void)logContactAction;
@end

static int failures = 0;
static void Check(BOOL ok, NSString *what) {
    if (ok) NSLog(@"PASS: %@", what);
    else { fprintf(stderr, "FAIL: %s\n", what.UTF8String); failures++; }
}

/// A WAV that plays the radio: live, so its pictures can be logged. Never an audio device.
@interface SSTVTestRadio : NSObject <TX500SSTVAudioSource>
@property (nonatomic, strong) TX500SSTVFileSource *file;
@end
@implementation SSTVTestRadio
- (double)sampleRate { return self.file.sampleRate; }
- (BOOL)isLive { return YES; }
- (NSString *)sourceName { return @"Test radio"; }
- (BOOL)startDelivering:(void (^)(const float *, NSUInteger))deliver finished:(void (^)(void))finished error:(NSError **)error {
    return [self.file startDelivering:deliver finished:finished error:error];
}
- (void)stop { [self.file stop]; }
@end

/// A live source that delivers only what the test hands it, with the capture time the test says:
/// never an audio device. It keeps its blocks, so the test can play an old source's late ones.
@interface SSTVManualRadio : NSObject <TX500SSTVAudioSource>
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy, nullable) void (^deliver)(const float *, NSUInteger);
@property (nonatomic, copy, nullable) void (^finished)(void);
@property (nonatomic, strong, nullable) NSDate *blockDate;
@property (nonatomic) NSInteger stops;
@property (nonatomic) BOOL builtIn;                  // as if it were the Mac's own input
@end
@implementation SSTVManualRadio
- (nullable NSString *)deviceName { return self.name; }
- (double)sampleRate { return 12000.0; }
- (BOOL)isLive { return YES; }
- (NSString *)sourceName { return self.name ?: @"Manual radio"; }
- (nullable NSDate *)dateOfCurrentBlock { return self.blockDate; }
- (BOOL)startDelivering:(void (^)(const float *, NSUInteger))deliver finished:(void (^)(void))finished error:(NSError **)error {
    self.deliver = deliver; self.finished = finished; return YES;
}
- (void)stop { self.stops++; }
// samples in 0.1 s blocks, each with its capture time from `start`
- (void)play:(const int16_t *)s count:(NSUInteger)n from:(NSDate *)start {
    float buf[1200];
    for (NSUInteger i = 0; i < n; i += 1200) {
        NSUInteger k = MIN((NSUInteger)1200, n - i);
        for (NSUInteger j = 0; j < k; j++) buf[j] = (float)(s[i + j] / 32768.0);
        self.blockDate = [start dateByAddingTimeInterval:(double)i / 12000.0];
        if (self.deliver) self.deliver(buf, k);
    }
}
@end

// how many labels, notes and menu items of a view say this (any case)
static NSUInteger FaxViewSays(NSView *v, NSString *what) {
    NSUInteger n = 0;
    if ([v isKindOfClass:NSPopUpButton.class])
        for (NSString *t in ((NSPopUpButton *)v).itemTitles) n += [t rangeOfString:what options:NSCaseInsensitiveSearch].location != NSNotFound;
    else if ([v isKindOfClass:NSTextField.class])
        n += [((NSTextField *)v).stringValue rangeOfString:what options:NSCaseInsensitiveSearch].location != NSNotFound;
    for (NSView *s in v.subviews) n += FaxViewSays(s, what);
    return n;
}

// whether v is inside container, through its subviews or, for a stack, its arranged views: a stack
// detaches a hidden arranged view (detachesHiddenViews), which then has no superview but stays arranged
static BOOL Holds(NSView *container, NSView *v) {
    if (!container || !v) return NO;
    if (container == v) return YES;
    for (NSView *s in container.subviews) if (Holds(s, v)) return YES;
    if ([container isKindOfClass:NSStackView.class])
        for (NSView *a in ((NSStackView *)container).arrangedSubviews) if (Holds(a, v)) return YES;
    return NO;
}

// the view of a stack's arranged ones that holds v (v itself or one of its superviews), found through
// the stack's arranged views, never through superview == stack
static NSView *ArrangedHolding(NSStackView *stack, NSView *v) {
    if (!stack || !v) return nil;
    NSArray<NSView *> *arranged = stack.arrangedSubviews;
    for (NSView *w = v; w; w = w.superview) if ([arranged containsObject:w]) return w;
    // a hidden view, or one inside a hidden one, may be detached: look into each arranged view
    for (NSView *a in arranged) if (Holds(a, v)) return a;
    return nil;
}

static NSUInteger PlaceInStack(NSStackView *stack, NSView *v) {
    NSView *held = ArrangedHolding(stack, v);
    return held ? [stack.arrangedSubviews indexOfObject:held] : NSNotFound;
}

// the nearest stack that holds both views
static NSStackView *StackHoldingBoth(NSView *a, NSView *b) {
    for (NSView *w = a.superview; w; w = w.superview)
        if ([w isKindOfClass:NSStackView.class] && [b isDescendantOf:w]) return (NSStackView *)w;
    return nil;
}

// the first label of a view whose text is exactly this
static NSTextField *LabelSaying(NSView *v, NSString *text) {
    if ([v isKindOfClass:NSTextField.class] && [((NSTextField *)v).stringValue isEqualToString:text]) return (NSTextField *)v;
    for (NSView *s in v.subviews) { NSTextField *f = LabelSaying(s, text); if (f) return f; }
    return nil;
}

// the first label of a view whose text begins with this
static NSTextField *LabelBeginning(NSView *v, NSString *text) {
    if ([v isKindOfClass:NSTextField.class] && [((NSTextField *)v).stringValue hasPrefix:text]) return (NSTextField *)v;
    for (NSView *s in v.subviews) { NSTextField *f = LabelBeginning(s, text); if (f) return f; }
    return nil;
}

// the X of a gallery thumbnail: the button inside it
static NSButton *XOf(NSView *thumb) {
    for (NSView *s in thumb.subviews) if ([s isKindOfClass:NSButton.class]) return (NSButton *)s;
    return nil;
}

// every file under a folder, with its size and modification time: what is on disk there
static NSArray<NSString *> *DiskSnapshot(NSURL *dir) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSURL *u in [NSFileManager.defaultManager enumeratorAtURL:dir includingPropertiesForKeys:@[NSURLFileSizeKey, NSURLContentModificationDateKey]
                                                           options:0 errorHandler:nil]) {
        NSNumber *size = nil; NSDate *mod = nil;
        [u getResourceValue:&size forKey:NSURLFileSizeKey error:nil];
        [u getResourceValue:&mod forKey:NSURLContentModificationDateKey error:nil];
        [out addObject:[NSString stringWithFormat:@"%@ %@ %.6f", u.path, size, mod.timeIntervalSince1970]];
    }
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

// a reception's entry in index.json, as written on disk
static NSDictionary *IndexItem(NSURL *recordings, NSString *identifier) {
    NSData *d = [NSData dataWithContentsOfURL:[recordings URLByAppendingPathComponent:@"index.json"]];
    NSDictionary *index = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    for (NSDictionary *it in index[@"items"]) if ([it[@"id"] isEqualToString:identifier]) return it;
    return nil;
}

static NSURL *fixtures;
static NSURL *Fixture(NSString *name) { return [fixtures URLByAppendingPathComponent:name]; }

static NSBitmapImageRep *ReadPNG(NSURL *u) {
    NSData *d = [NSData dataWithContentsOfURL:u];
    return d ? [NSBitmapImageRep imageRepWithData:d] : nil;
}

/// Whether a PNG holds exactly this chart's greys.
static BOOL PNGIsChart(NSURL *png, TX500FaxChart *ch) {
    NSBitmapImageRep *ref = ReadPNG(png);
    if (!ref || !ch || ref.pixelsWide != ch.width || ref.pixelsHigh != ch.height || ch.gray.length < (NSUInteger)(ch.width * ch.height)) return NO;
    const uint8_t *g = ch.gray.bytes;
    for (NSInteger y = 0; y < ch.height; y++)
        for (NSInteger x = 0; x < ch.width; x++) {
            NSUInteger px[4] = {0};
            [ref getPixel:px atX:x y:y];
            if (px[0] != g[y * ch.width + x]) return NO;
        }
    return YES;
}

// the thumbnails of the fax strip, in their order
static NSArray<NSButton *> *StripButtons(TX500FaxStationController *f) {
    NSMutableArray<NSButton *> *b = [NSMutableArray array];
    for (NSView *v in f.sessionStrip.arrangedSubviews) if ([v isKindOfClass:NSButton.class]) [b addObject:(NSButton *)v];
    return b;
}

/// The same pixels as the core's own command line wrote for the same WAV.
static BOOL SamePixels(TX500SSTVPicture *p, NSURL *png) {
    NSBitmapImageRep *ref = ReadPNG(png);
    if (!ref || ref.pixelsWide != p.width || ref.pixelsHigh != p.height) return NO;
    const uint8_t *a = p.rgb.bytes;
    for (NSInteger y = 0; y < p.height; y++)
        for (NSInteger x = 0; x < p.width; x++) {
            NSUInteger px[4] = {0};
            [ref getPixel:px atX:x y:y];
            const uint8_t *q = a + (y * p.width + x) * 3;
            if (q[0] != px[0] || q[1] != px[1] || q[2] != px[2]) return NO;
        }
    return YES;
}

static TX500SSTVStationController *NewController(NSUserDefaults *defs, NSURL *gallery, TX500LogbookManager *lb) {
    TX500SSTVStationController *c = [TX500SSTVStationController new];
    c.defaults = defs;
    c.galleryDirectory = gallery;
    c.logbook = lb;
    c.engine.callbackQueue = nil;
    c.practiceEngine.callbackQueue = nil;
    c.confirmBuiltInInput = ^BOOL(NSString *name) { (void)name; return NO; };   // never a question on the screen in a test
    return c;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 2) { fprintf(stderr, "usage: SSTVStationTests <fixtures folder>\n"); return 2; }
        fixtures = [NSURL fileURLWithPath:@(argv[1]) isDirectory:YES];
        [NSApplication sharedApplication];
        NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID UUID].UUIDString];
        [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        // the app's shared logbook (the Logbook's own form uses it) in this folder, and no cloud or TQSL call,
        // as in the author's LogbookAndCloudTests
        setenv("TX500_TEST_MODE", "1", 1);
        setenv("TX500_TEST_ROOT", root.fileSystemRepresentation, 1);
        NSURL *gallery = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery"] isDirectory:YES];
        NSString *suite = [@"lab599.sstv.tests." stringByAppendingString:[NSUUID UUID].UUIDString];
        NSUserDefaults *defs = [[NSUserDefaults alloc] initWithSuiteName:suite];
        TX500LogbookManager *lb = [[TX500LogbookManager alloc] initWithDatabaseURL:
                                   [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"log.sqlite"]]];

        // 1. the engine gives the core's picture, bit for bit, with progressive drawing on the way
        NSMutableArray<TX500SSTVPicture *> *firsts = [NSMutableArray array];
        for (NSString *mode in @[@"M1", @"R36", @"PD120", @"S1"]) {
            TX500SSTVEngine *e = [TX500SSTVEngine new];
            e.callbackQueue = nil;
            NSMutableArray<TX500SSTVPicture *> *got = [NSMutableArray array];
            __block NSInteger lastRows = -1, calls = 0;
            __block BOOL monotonic = YES;
            e.onPicture = ^(TX500SSTVPicture *p) { [got addObject:p]; };
            e.onProgress = ^(NSString *name, NSInteger rows, NSInteger h, NSBitmapImageRep *partial) {
                (void)name; (void)h; (void)partial;
                if (rows < lastRows) monotonic = NO;
                lastRows = rows; calls++;
            };
            NSError *err = nil;
            TX500SSTVFileSource *src = [[TX500SSTVFileSource alloc] initWithURL:Fixture([mode stringByAppendingString:@".wav"]) error:&err];
            BOOL ok = src && [e startWithSource:src error:&err];
            Check(ok && got.count == 1 && got[0].complete && [got[0].modeKey isEqualToString:mode],
                  [NSString stringWithFormat:@"Engine: %@ from a WAV gives one complete picture", mode]);
            Check(got.count == 1 && SamePixels(got[0], Fixture([NSString stringWithFormat:@"%@-core/imatge-00.png", mode])),
                  [NSString stringWithFormat:@"Engine: %@ is the core's picture, bit for bit", mode]);
            Check(calls > 10 && monotonic, [NSString stringWithFormat:@"Engine: %@ is drawn while it arrives (%ld times), the rows never go back", mode, (long)calls]);
            Check(got.count == 1 && got[0].fromFile, [NSString stringWithFormat:@"Engine: a picture from a file is marked as practice (%@)", mode]);
            if (got.count == 1) [firsts addObject:got[0]];
        }

        // 1b. "Decode again from buffer": every picture keeps its audio, exactly as it came in
        for (TX500SSTVPicture *p in firsts) {
            TX500SSTVRecording *r = p.recording;
            TX500SSTVRecording *wav = [TX500SSTVRecording recordingFromWAVAtURL:Fixture([p.modeKey stringByAppendingString:@".wav"]) error:nil];
            BOOL same = NO;
            if (r && wav) {
                NSUInteger a = (NSUInteger)llround(r.startTime * r.sampleRate), n = r.samples.length / 2;
                same = (a + n) * 2 <= wav.samples.length &&
                       memcmp(r.samples.bytes, (const uint8_t *)wav.samples.bytes + a * 2, n * 2) == 0;
            }
            Check(r && r.startTime <= MAX(0.0, p.startTime - 2.9) && r.duration > 30 && same,
                  [NSString stringWithFormat:@"Decode again: the %@ picture carries its audio (%.1f s, from 3 s before the first line), sample for sample", p.modeKey, r.duration]);
            NSArray<TX500SSTVPicture *> *again = [TX500SSTVRecordingStore decodeAgain:r mode:TX500SSTVModeAuto colourScale:TX500SSTVColourScaleStudio
                                                                      scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            Check(again.count == 1 && [again[0].rgb isEqualToData:p.rgb] && again[0].fromFile,
                  [NSString stringWithFormat:@"Decode again: %@ with the same choices gives exactly the same picture (a file's recording stays practice)", p.modeKey]);
        }
        if (firsts.count == 4) {
            TX500SSTVPicture *r36 = firsts[1], *m1 = firsts[0];
            NSArray *full = [TX500SSTVRecordingStore decodeAgain:r36.recording mode:TX500SSTVModeAuto colourScale:TX500SSTVColourScaleFull
                                                   scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            NSArray *lean = [TX500SSTVRecordingStore decodeAgain:m1.recording mode:TX500SSTVModeAuto colourScale:TX500SSTVColourScaleStudio
                                                   scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:NO slantPPM:500];
            Check(full.count == 1 && ![[full[0] rgb] isEqualToData:r36.rgb] && lean.count == 1 && ![[lean[0] rgb] isEqualToData:m1.rgb],
                  @"Decode again: other choices change the picture (Robot 36 in full range; Martin M1 with +500 ppm by hand)");
            NSURL *wavOut = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"recording.wav"]];
            TX500SSTVRecording *back = [m1.recording writeWAVToURL:wavOut error:nil] ? [TX500SSTVRecording recordingFromWAVAtURL:wavOut error:nil] : nil;
            Check(back && [back.samples isEqualToData:m1.recording.samples] && back.sampleRate == m1.recording.sampleRate,
                  @"Export recording: the WAV holds exactly the audio that was received (12 kHz, 16 bits)");
            // the store: memory for the last 3, disk within the cap, Keep never expires. A recording from
            // the radio (one from a file is practice, and practice never goes to disk)
            TX500SSTVRecording *radio1 = [[TX500SSTVRecording alloc] initWithSamples:m1.recording.samples sampleRate:12000 startTime:0];
            NSURL *dir = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"recordings"] isDirectory:YES];
            TX500SSTVRecordingStore *st = [[TX500SSTVRecordingStore alloc] initWithDirectory:dir];
            unsigned long long one = m1.recording.byteSize + 44;
            st.diskCapBytes = 2 * one + one / 2;                  // room for two
            TX500SSTVStoredReception *oldest = [st addRecording:radio1];
            Check([st setKeep:YES forReception:oldest], @"Store: Keep, with its copy");
            for (int k = 0; k < 4; k++) [st addRecording:radio1];
            NSUInteger onDisk = 0, inMem = 0;
            for (TX500SSTVStoredReception *x in st.receptions) { onDisk += x.onDisk; inMem += x.inMemory; }
            unsigned long long unkept = 0;
            for (TX500SSTVStoredReception *x in st.receptions) if (x.onDisk && !x.keep) unkept += x.byteSize + 44;
            Check(unkept + oldest.byteSize + 44 <= st.diskCapBytes && onDisk == 2 && inMem == 3,
                  @"Store: the disk keeps within its cap, the kept one counted in it: the kept one and the newest; memory holds the last 3; the oldest made room");
            Check(oldest.keep && oldest.onDisk, @"Store: a reception marked Keep never expires");
            TX500SSTVRecordingStore *again = [[TX500SSTVRecordingStore alloc] initWithDirectory:dir];
            BOOL keptBack = NO;
            for (TX500SSTVStoredReception *x in again.receptions) if ([x.identifier isEqualToString:oldest.identifier] && x.keep) keptBack = YES;
            TX500SSTVRecording *fromDisk = again.receptions.count ? [again recordingForReception:again.receptions.lastObject] : nil;
            Check(keptBack && again.receptions.count == 2 && fromDisk.samples.length == radio1.samples.length,
                  @"Store: after a restart the disk copies and the Keep mark are still there, and play back whole");
            // decoding again lists the new picture with the same reception: no second copy of the audio
            TX500SSTVStoredReception *newest = st.receptions.firstObject;
            unsigned long long before2 = st.diskBytesUsed;
            NSUInteger n0 = st.receptions.count;
            [st addPictureNamed:@"first.png" toReception:newest];
            [st addPictureNamed:@"again.png" toReception:newest];
            TX500SSTVRecordingStore *re = [[TX500SSTVRecordingStore alloc] initWithDirectory:dir];
            NSArray *names = nil;
            for (TX500SSTVStoredReception *x in re.receptions) if ([x.identifier isEqualToString:newest.identifier]) names = x.pictureNames;
            Check(st.receptions.count == n0 && st.diskBytesUsed == before2 && [names isEqual:@[@"first.png", @"again.png"]],
                  @"Store: Decode again adds pictures to the same reception, the audio is not stored twice, and the list survives a restart");
            NSURL *offDir = [dir URLByAppendingPathComponent:@"off"];
            TX500SSTVRecordingStore *off = [[TX500SSTVRecordingStore alloc] initWithDirectory:offDir];
            off.diskCapBytes = 0;
            for (int k = 0; k < 5; k++) [off addRecording:radio1];
            Check(off.diskBytesUsed == 0 && off.receptions.count == 3 && ![NSFileManager.defaultManager fileExistsAtPath:offDir.path],
                  @"Store: with the disk Off, nothing is written (not even the folder or its list), and memory keeps the last 3");
            Check([off setKeep:YES forReception:off.receptions.firstObject] && off.receptions.firstObject.onDisk,
                  @"Store: with the disk Off, Keep still writes that one copy (the operator's explicit choice)");

            // the last minutes kept: one copy of the same minutes, written at once and marked Keep, taking no place in
            // memory; none, and no row, when it cannot be written (N3-importants-nous-1, N3-menors-oberts-1)
            {
                TX500SSTVRecordingStore *sk = [[TX500SSTVRecordingStore alloc] initWithDirectory:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"keep-copy"] isDirectory:YES]];
                sk.diskCapBytes = 20 * one;
                for (int k = 0; k < 3; k++) [sk addRecording:radio1];                 // the three in memory
                TX500SSTVRecording *ring = [[TX500SSTVRecording alloc] initWithSamples:m1.recording.samples sampleRate:12000 startTime:0];
                ring.endUTC = [NSDate dateWithTimeIntervalSince1970:1791600000];
                TX500SSTVStoredReception *k1 = [sk keepCopyOfRecording:ring catFrequencyHz:14230000 error:nil];
                TX500SSTVStoredReception *k2 = [sk keepCopyOfRecording:ring catFrequencyHz:14230000 error:nil];
                NSUInteger memK = 0;
                for (TX500SSTVStoredReception *x in sk.receptions) if (x != k1 && x.inMemory) memK++;
                Check(k1 && k1 == k2 && sk.receptions.count == 4 && k1.keep && k1.onDisk && !k1.inMemory && memK == 3 &&
                      [sk recordingForReception:k1].byteSize == ring.byteSize,
                      @"Store: Keep on the same last minutes twice gives one copy, kept on disk, read back from it, and the three receptions in memory keep theirs");
                TX500SSTVRecording *ring2 = [[TX500SSTVRecording alloc] initWithSamples:m1.recording.samples sampleRate:12000 startTime:0];
                ring2.endUTC = [ring.endUTC dateByAddingTimeInterval:60];
                sk.minimumFreeBytes = ULLONG_MAX / 4;                               // as if the disk were full
                NSError *ek = nil;
                TX500SSTVStoredReception *k3 = [sk keepCopyOfRecording:ring2 catFrequencyHz:0 error:&ek];
                Check(!k3 && sk.receptions.count == 4 && [ek.localizedDescription containsString:@"not enough free disk space"],
                      @"Store: Keep on the last minutes with no room on disk adds no row, and says why");
            }

            // the disk share (decided 09-10): 1 % of the disk by default; never more than a tenth of the room for it
            TX500SSTVRecordingStore *sd = [[TX500SSTVRecordingStore alloc] initWithDirectory:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"share"] isDirectory:YES]];
            // and the same on an example volume, so that the output shows figures, never this Mac's own
            TX500SSTVRecordingStore.volumeBytesProvider = ^unsigned long long { return 500ULL * 1000 * 1000 * 1000; };
            TX500SSTVRecordingStore *sdEx = [[TX500SSTVRecordingStore alloc] initWithDirectory:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"share-example"] isDirectory:YES]];
            TX500SSTVRecordingStore.volumeBytesProvider = nil;
            Check(sd.diskShare == 0.01 && (sd.volumeBytes == 0 || fabs((double)sd.diskCapBytes - 0.01 * sd.volumeBytes) < 1e6) &&
                  sdEx.diskShare == 0.01 && sdEx.diskCapBytes == 5ULL * 1000 * 1000 * 1000,
                  [NSString stringWithFormat:@"Store: 1 %% of the disk by default, «1 %% of the disk» in «Keep recordings on disk:» on the SSTV screen, where it can be changed (example volume: 500 GB: a share of %.1f GB)",
                   sdEx.diskCapBytes / 1e9]);
            __block NSString *saidG = nil;
            sd.onProblem = ^(NSString *t) { saidG = t; };
            sd.freeBytesProvider = ^unsigned long long { return 10ULL * 1000 * 1000; };   // as if only 10 MB were free
            sd.diskShare = 0.01;
            Check(sd.limitedByFreeSpace && sd.effectiveCapBytes <= 1000ULL * 1000 + sd.diskBytesUsed / 10 &&
                  [saidG containsString:@"a tenth of the free space plus what they already use"],
                  @"Store: never more than a tenth of the free space plus what the recordings use, and it says so");
            // DEC-16: the kept ones count, are never removed, and when they alone fill the share it says so
            NSURL *dk16 = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"kept-full"] isDirectory:YES];
            TX500SSTVRecordingStore *s16 = [[TX500SSTVRecordingStore alloc] initWithDirectory:dk16];
            __block NSString *said16 = @"";
            s16.onProblem = ^(NSString *t) { said16 = [said16 stringByAppendingString:t]; };
            s16.diskCapBytes = 2 * one + one / 2;
            NSMutableArray<TX500SSTVStoredReception *> *kept16 = [NSMutableArray array];
            __block NSUInteger removed16 = 0;
            s16.onRemoved = ^(NSUInteger c, unsigned long long b) { (void)b; removed16 += c; };
            for (int k = 0; k < 3; k++) { TX500SSTVStoredReception *x = [s16 addRecording:radio1]; [s16 setKeep:YES forReception:x]; [kept16 addObject:x]; }
            NSUInteger removedBefore16 = removed16;
            TX500SSTVStoredReception *new16 = [s16 addRecording:radio1];
            // the new one was never written (the share would have removed it at once), nor would its picture be
            // (N3-importants-nous-4, N3-menors-oberts-3)
            BOOL neverWritten16 = ![NSFileManager.defaultManager fileExistsAtPath:[dk16 URLByAppendingPathComponent:[new16.identifier stringByAppendingString:@".wav"]].path] &&
                                  removed16 == removedBefore16 && ![s16 newPictureFitsShare:1000];
            Check(neverWritten16 && [said16 containsString:@"new recordings and pictures stay in memory only"],
                  @"Store: with the kept ones filling the share, a new recording and its picture are not written at all (never written and removed at once, no «Removed 1 old recording»), and it says pictures too");
            BOOL allKept = YES;
            for (TX500SSTVStoredReception *x in kept16) allKept = allKept && x.keep && x.onDisk;
            NSString *st16 = nil;
            NSString *lamp16 = [TX500SSTVStationController diskLampTextForShare:0.01 wantBytes:s16.diskCapBytes capBytes:s16.effectiveCapBytes
                                                                      usedBytes:s16.diskBytesUsed keptBytes:s16.keptBytes keptCount:s16.keptCount state:&st16];
            Check(allKept && !new16.onDisk && new16.inMemory && s16.keptCount == 3 && [said16 containsString:@"fill the disk share on their own"] &&
                  [st16 isEqualToString:@"low"] && [lamp16 hasPrefix:@"Kept recordings fill the share"] && [lamp16 containsString:@"3 kept recordings"],
                  [NSString stringWithFormat:@"Store: kept recordings over the share are never removed; a new one stays in memory; the store and the red lamp say so: %@", lamp16]);
            NSString *st16b = nil;
            NSString *lamp16b = [TX500SSTVStationController diskLampTextForShare:0.01 wantBytes:5000000000ULL capBytes:5000000000ULL
                                                                       usedBytes:1000000000ULL keptBytes:1000000000ULL keptCount:1 state:&st16b];
            Check([st16b isEqualToString:@"ok"] && [lamp16b containsString:@"4,000 MB free (80 %)"] && [lamp16b hasSuffix:@" · 1 kept recording, 1,000 MB among them"],
                  [NSString stringWithFormat:@"Lamp: the kept ones count in what is used, as they are on disk, and it says how many: %@", lamp16b]);
            // practice never goes to disk; the radio's audio and pictures share the cap, audio first out
            NSURL *pd = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"pics"] isDirectory:YES];
            [NSFileManager.defaultManager createDirectoryAtURL:pd withIntermediateDirectories:YES attributes:nil error:nil];
            NSURL *dp = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"withpics"] isDirectory:YES];
            TX500SSTVRecordingStore *sp = [[TX500SSTVRecordingStore alloc] initWithDirectory:dp pictureDirectory:pd];
            TX500SSTVRecording *radioRec = [[TX500SSTVRecording alloc] initWithSamples:m1.recording.samples sampleRate:12000 startTime:0];
            TX500SSTVStoredReception *pr = [sp addRecording:m1.recording];                 // m1 came from a file: practice
            Check(pr.fromFile && !pr.onDisk && pr.inMemory, @"Store: a practice recording stays in memory, never on disk");
            TX500SSTVStoredReception *rr = [sp addRecording:radioRec];
            NSMutableData *png = [NSMutableData dataWithLength:1000];
            [png writeToURL:[pd URLByAppendingPathComponent:@"pic.png"] atomically:YES];
            [sp addPictureNamed:@"pic.png" toReception:rr];
            unsigned long long both = sp.diskBytesUsed;
            Check(rr.onDisk && rr.pictureBytes == 1000 && both == rr.byteSize + 44 + 1000, @"Store: a radio reception's audio and its picture both count");
            sp.diskCapBytes = both - 10;
            Check(!rr.onDisk && [NSFileManager.defaultManager fileExistsAtPath:[pd URLByAppendingPathComponent:@"pic.png"].path] &&
                  [sp.receptions containsObject:rr],
                  @"Store: over the cap, the audio goes first; the picture stays, and so does its reception");
            TX500SSTVRecordingStore *sp2 = [[TX500SSTVRecordingStore alloc] initWithDirectory:dp pictureDirectory:pd];
            BOOL listed = NO;
            for (TX500SSTVStoredReception *x in sp2.receptions) if ([x.identifier isEqualToString:rr.identifier] && x.pictureBytes == 1000) listed = YES;
            Check(listed, @"Store: a reception with only its picture left is still listed after a restart");
            sp.diskCapBytes = 500;
            Check(![NSFileManager.defaultManager fileExistsAtPath:[pd URLByAppendingPathComponent:@"pic.png"].path] && rr.pictureBytes == 0 && !rr.onDisk,
                  @"Store: then the picture goes too (the reception stays only in memory, as one of the last 3)");
            NSURL *dOff = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"share-off"] isDirectory:YES];
            TX500SSTVRecordingStore *so = [[TX500SSTVRecordingStore alloc] initWithDirectory:dOff pictureDirectory:pd];
            so.diskShare = 0;
            [so addRecording:radioRec];
            Check(so.effectiveCapBytes == 0 && ![NSFileManager.defaultManager fileExistsAtPath:dOff.path], @"Store: with the share Off, nothing is written");
            // Keep on practice: refused, with the share on and Off; nothing is written (N-memoria-disc-2)
            NSURL *dk = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"keep-practice"] isDirectory:YES];
            TX500SSTVRecordingStore *sk = [[TX500SSTVRecordingStore alloc] initWithDirectory:dk];
            TX500SSTVStoredReception *pk = [sk addRecording:m1.recording];
            NSError *ek = nil;
            BOOL keptOn = [sk setKeep:YES forReception:pk error:&ek];
            sk.diskShare = 0;
            NSError *ek2 = nil;
            BOOL keptOff = [sk setKeep:YES forReception:pk error:&ek2];
            Check(pk.fromFile && !keptOn && !keptOff && !pk.keep && !pk.onDisk && ![NSFileManager.defaultManager fileExistsAtPath:dk.path] &&
                  [ek.localizedDescription containsString:@"Export recording"] && ek2,
                  @"Store: Keep on a practice recording is refused (share on or Off), says to use Export recording…, and writes nothing");
            // the operator's share applies from the start: nothing within it is removed on reopening, by the
            // store or through the screen (N-memoria-disc-1). A disk of 400 MB here: 1 % = 4 MB, 5 % = 20 MB
            TX500SSTVRecordingStore.volumeBytesProvider = ^unsigned long long { return 400ULL * 1000 * 1000; };
            NSURL *g9 = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"share5"] isDirectory:YES];
            NSURL *d9 = [g9 URLByAppendingPathComponent:@"Recordings" isDirectory:YES];
            TX500SSTVRecordingStore *s9 = [[TX500SSTVRecordingStore alloc] initWithDirectory:d9 pictureDirectory:g9 diskShare:0.05];
            for (int k = 0; k < 3; k++) [s9 addRecording:radio1];
            NSUInteger disk9 = 0;
            for (TX500SSTVStoredReception *x in s9.receptions) disk9 += x.onDisk;
            unsigned long long used9 = s9.diskBytesUsed;
            __block NSUInteger removed9 = 0;
            TX500SSTVRecordingStore *s9b = [[TX500SSTVRecordingStore alloc] initWithDirectory:d9 pictureDirectory:g9 diskShare:0.05];
            s9b.onRemoved = ^(NSUInteger count, unsigned long long bytes) { (void)bytes; removed9 += count; };
            NSUInteger disk9b = 0;
            for (TX500SSTVStoredReception *x in s9b.receptions) disk9b += x.onDisk;
            NSUserDefaults *defs9 = [[NSUserDefaults alloc] initWithSuiteName:[suite stringByAppendingString:@".share5"]];
            [defs9 setInteger:4 forKey:@"TX500SSTVDiskShare"];                    // «5 % of the disk»
            TX500SSTVStationController *c9 = NewController(defs9, g9, lb);
            NSMutableArray<NSString *> *lines9 = [NSMutableArray array];
            c9.logHandler = ^(NSString *line) { [lines9 addObject:line]; };
            NSUInteger disk9c = 0;
            for (TX500SSTVStoredReception *x in c9.recordings.receptions) disk9c += x.onDisk;
            BOOL saidRemoved9 = NO;
            for (NSString *l in lines9) if ([l containsString:@"Removed"]) saidRemoved9 = YES;
            Check(used9 > 4ULL * 1000 * 1000 && disk9 == 3 && disk9b == 3 && removed9 == 0 && disk9c == 3 && !saidRemoved9 &&
                  fabs(c9.recordings.diskShare - 0.05) < 1e-9,
                  [NSString stringWithFormat:@"Store: with 5 %% chosen, %.1f MB (over 1 %%) are all still there after reopening, by the store and through the screen", used9 / 1e6]);
            // what the first trim removes is said as soon as someone listens
            TX500SSTVRecordingStore *s9c = [[TX500SSTVRecordingStore alloc] initWithDirectory:d9 pictureDirectory:g9 diskShare:0.01];
            __block NSUInteger removed9c = 0;
            s9c.onRemoved = ^(NSUInteger count, unsigned long long bytes) { (void)bytes; removed9c += count; };
            NSUInteger disk9d = 0;
            for (TX500SSTVStoredReception *x in s9c.receptions) disk9d += x.onDisk;
            Check(disk9d == 1 && removed9c == 2,
                  @"Store: reopened with a smaller share (1 %), it trims to it at once and says what it removed when someone listens");
            TX500SSTVRecordingStore.volumeBytesProvider = nil;

            // 4. disk and index (DEC-6..9, DEC-14, DEC-15, SEG-16)
            NSFileManager *fm = NSFileManager.defaultManager;
            NSURL *d4 = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"store4"] isDirectory:YES];
            TX500SSTVRecordingStore *s4 = [[TX500SSTVRecordingStore alloc] initWithDirectory:d4];
            __block NSUInteger removedN = 0;
            __block NSString *said = nil;
            s4.onRemoved = ^(NSUInteger count, unsigned long long bytes) { (void)bytes; removedN += count; };
            s4.onProblem = ^(NSString *t) { said = t; };
            for (int k = 0; k < 4; k++) [s4 addRecording:radio1];
            s4.diskCapBytes = one + one / 2;                                       // lowered: room for one
            NSUInteger onDisk4 = 0;
            for (TX500SSTVStoredReception *x in s4.receptions) onDisk4 += x.onDisk;
            Check(onDisk4 == 1 && removedN == 3, @"Store: lowering the cap applies at once, and it says what it removed");
            // Keep only with a copy: a write that cannot happen leaves Keep off, and says why
            TX500SSTVRecordingStore *s5 = [[TX500SSTVRecordingStore alloc] initWithDirectory:[d4 URLByAppendingPathComponent:@"blocked"]];
            s5.diskCapBytes = 0;
            TX500SSTVStoredReception *r5 = [s5 addRecording:radio1];
            [[NSData dataWithBytes:"x" length:1] writeToURL:[d4 URLByAppendingPathComponent:@"blocked"] atomically:YES];   // a file where the folder would be
            NSError *e5 = nil;
            s5.onProblem = ^(NSString *t) { said = t; };
            Check(![s5 setKeep:YES forReception:r5 error:&e5] && !r5.keep && e5 && [said containsString:@"could not be kept"],
                  @"Store: Keep that cannot write its copy stays off and says why (it is never promised without a copy)");
            TX500SSTVRecordingStore *s6 = [[TX500SSTVRecordingStore alloc] initWithDirectory:[d4 URLByAppendingPathComponent:@"full"]];
            s6.minimumFreeBytes = ULLONG_MAX / 2;                                // as if the disk were full
            said = nil;
            s6.onProblem = ^(NSString *t) { said = t; };
            TX500SSTVStoredReception *r6 = [s6 addRecording:radio1];
            Check(!r6.onDisk && [said containsString:@"not enough free disk space"], @"Store: with too little free space, no copy is written, and it says so");
            // a damaged index is set aside, never written over; the recordings are listed again
            NSURL *d7 = [d4 URLByAppendingPathComponent:@"damaged"];
            TX500SSTVRecordingStore *s7 = [[TX500SSTVRecordingStore alloc] initWithDirectory:d7];
            for (int k = 0; k < 2; k++) [s7 addRecording:radio1];
            [[NSData dataWithBytes:"{\"version\": 1, \"ite" length:20] writeToURL:[d7 URLByAppendingPathComponent:@"index.json"] atomically:YES];
            __block NSString *said7 = @"";
            TX500SSTVRecordingStore *s7c = [[TX500SSTVRecordingStore alloc] initWithDirectory:d7];
            s7c.onProblem = ^(NSString *t) { said7 = [said7 stringByAppendingString:t]; };    // what loading found is said now
            BOOL bad = NO;
            for (NSString *f in [fm contentsOfDirectoryAtPath:d7.path error:nil]) if ([f hasSuffix:@".json.bad"]) bad = YES;
            Check(bad && s7c.receptions.count == 2 && s7c.receptions.firstObject.fromFile && [said7 containsString:@"listed again"],
                  @"Store: a damaged list is kept aside (.bad), the 2 recordings in the folder are listed again (as practice), and it says so");
            s7c.diskCapBytes = 1000;                                           // far too small for them
            BOOL bothStay = s7c.receptions.count == 2 && s7c.receptions[0].onDisk && s7c.receptions[1].onDisk;
            Check(bothStay && [said7 containsString:@"None is removed while the app runs now"],
                  @"Store: those listed again (they may have been kept) are not removed on that start, even over the share, and it says so (N-memoria-disc-6)");
            // a file that cannot be removed stays counted and listed, and it is said (N-memoria-disc-8)
            NSURL *d9f = [d4 URLByAppendingPathComponent:@"locked"];
            TX500SSTVRecordingStore *s9f = [[TX500SSTVRecordingStore alloc] initWithDirectory:d9f];
            for (int k = 0; k < 2; k++) [s9f addRecording:radio1];
            __block NSString *said9f = @"";
            s9f.onProblem = ^(NSString *t) { said9f = [said9f stringByAppendingString:t]; };
            [fm setAttributes:@{NSFilePosixPermissions: @0555} ofItemAtPath:d9f.path error:nil];   // its files can no longer be removed
            unsigned long long used9f = s9f.diskBytesUsed;
            s9f.diskCapBytes = one;
            NSUInteger disk9f = 0;
            for (TX500SSTVStoredReception *x in s9f.receptions) disk9f += x.onDisk;
            s9f.diskCapBytes = one;                                            // trimmed again, and again with the next one
            [s9f addRecording:radio1];
            [fm setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:d9f.path error:nil];
            NSUInteger said9fTimes = [said9f componentsSeparatedByString:@"could not be removed"].count - 1;
            Check(disk9f == 2 && s9f.diskBytesUsed == used9f && said9fTimes == 1,
                  [NSString stringWithFormat:@"Store: an old recording that cannot be removed stays counted and listed, and it is said once, not at every trim (N-memoria-disc-8, N3-importants-nous-3): said %lu times",
                   (unsigned long)said9fTimes]);
            // an index that names a folder, a path outside, or a size it does not have, deletes nothing
            NSURL *d8 = [d4 URLByAppendingPathComponent:@"hostile"];
            [fm createDirectoryAtURL:d8 withIntermediateDirectories:YES attributes:nil error:nil];
            NSURL *outside = [d4 URLByAppendingPathComponent:@"outside.txt"];
            [[NSData dataWithBytes:"keep me" length:7] writeToURL:outside atomically:YES];
            NSDictionary *idx = @{@"version": @1, @"items": @[@{@"id": @"x", @"file": @"", @"bytes": @2000000000},
                                                               @{@"id": [NSUUID UUID].UUIDString, @"file": @"../outside.txt", @"bytes": @2000000000},
                                                               @{@"id": @12, @"end": @"no"}]};
            [[NSJSONSerialization dataWithJSONObject:idx options:0 error:nil] writeToURL:[d8 URLByAppendingPathComponent:@"index.json"] atomically:YES];
            TX500SSTVRecordingStore *s8 = [[TX500SSTVRecordingStore alloc] initWithDirectory:d8];
            s8.diskCapBytes = 0;
            Check(s8.receptions.count == 0 && [fm fileExistsAtPath:d8.path] && [fm fileExistsAtPath:outside.path],
                  @"Store: a list that names a folder, a path outside, or a wrong type is ignored: nothing is deleted");
        }

        // 1c. the last five minutes: a picture whose VIS was missed is decoded again by hand
        {
            TX500SSTVEngine *e = [TX500SSTVEngine new];
            e.callbackQueue = nil;
            __block NSUInteger pics = 0;
            e.onPicture = ^(TX500SSTVPicture *p) { (void)p; pics++; };
            [e startWithSource:[[TX500SSTVFileSource alloc] initWithURL:Fixture(@"M1-novis.wav") error:nil] error:nil];
            TX500SSTVRecording *last = [e lastMinutes];
            NSArray *byHand = last ? [TX500SSTVRecordingStore decodeAgain:last mode:TX500SSTVModeMartin1 colourScale:TX500SSTVColourScaleStudio
                                                            scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0] : @[];
            Check(pics == 0 && last.duration > 100 && byHand.count == 1 && [[byHand[0] modeKey] isEqualToString:@"M1"],
                  @"Decode again: no VIS, no picture; the last minutes, decoded again as Martin M1 by hand, give it");
        }

        // 2. the mode chosen by hand, and its notices
        {
            TX500SSTVEngine *e = [TX500SSTVEngine new];
            e.callbackQueue = nil;
            e.modeChoice = TX500SSTVModeMartin1;
            NSMutableArray<TX500SSTVNotice *> *notes = [NSMutableArray array];
            NSMutableArray<TX500SSTVPicture *> *got = [NSMutableArray array];
            e.onNotice = ^(TX500SSTVNotice *n) { [notes addObject:n]; };
            e.onPicture = ^(TX500SSTVPicture *p) { [got addObject:p]; };
            TX500SSTVFileSource *src = [[TX500SSTVFileSource alloc] initWithURL:Fixture(@"M1-novis.wav") error:nil];
            [e startWithSource:src error:nil];
            BOOL started = NO;
            for (TX500SSTVNotice *n in notes) if (n.kind == TX500SSTVNoticeManualStart && [n.text containsString:@"chosen by hand"]) started = YES;
            Check(got.count == 1 && started, @"Engine: Martin M1 chosen by hand decodes a picture without VIS, and says so");
            [notes removeAllObjects];
            src = [[TX500SSTVFileSource alloc] initWithURL:Fixture(@"noise-60s.wav") error:nil];
            [e startWithSource:src error:nil];
            BOOL noise = NO;
            for (TX500SSTVNotice *n in notes) if (n.kind == TX500SSTVNoticeManualNoise && [n.text containsString:@"only noise"]) noise = YES;
            Check(noise && got.count == 1, @"Engine: chosen by hand on noise, it says there is only noise, and gives no picture");
        }

        // 3. off by default: no audio is opened until the operator turns it on
        {
            __block NSInteger opened = 0;
            TX500SSTVStationController *c = NewController(defs, gallery, lb);
            c.radioSourceFactory = ^id<TX500SSTVAudioSource> { opened++; return nil; };
            [c activate];
            Check(!c.enabled && !c.engine.running && opened == 0 && c.enableSwitch.state == NSControlStateValueOff,
                  @"Screen: off by default; showing it opens no audio");
            Check([defs objectForKey:TX500SSTVEnabledDefaultsKey] == nil || ![defs boolForKey:TX500SSTVEnabledDefaultsKey],
                  @"Screen: the stored setting starts off");
            // SEG-1: Listen left on last time (an old stored YES) must not open the audio when the screen is shown
            [defs setBool:YES forKey:TX500SSTVEnabledDefaultsKey];
            TX500SSTVStationController *again = NewController(defs, gallery, lb);
            __block NSInteger reopened = 0;
            again.radioSourceFactory = ^id<TX500SSTVAudioSource> { reopened++; return nil; };
            [again activate]; [again activate];
            Check(reopened == 0 && !again.enabled && !again.engine.running && again.enableSwitch.state == NSControlStateValueOff,
                  @"Screen: with Listen left on in an earlier session, showing the screen (twice) opens no audio; it starts Off");
            [defs removeObjectForKey:TX500SSTVEnabledDefaultsKey];
        }

        // 4. a picture from the radio: Record QSO or Discard QSO, nothing logged on its own
        NSInteger before = lb.totalContactCount;
        TX500SSTVStationController *c = NewController(defs, gallery, lb);
        __block NSInteger uploads = 0;
        c.uploadHandler = ^(TX500LogRecord *r) { (void)r; uploads++; };
        __block NSNumber *cat = nil;
        c.catFrequencyProvider = ^NSNumber * { return cat; };
        c.radioSourceFactory = ^id<TX500SSTVAudioSource> {
            SSTVTestRadio *r = [SSTVTestRadio new];
            r.file = [[TX500SSTVFileSource alloc] initWithURL:Fixture(@"M1.wav") error:nil];
            return r;
        };
        NSError *err = nil;
        Check([c setEnabled:YES error:&err] && c.enabled && [defs objectForKey:TX500SSTVEnabledDefaultsKey] == nil,
              @"Screen: turning it on opens the radio source, for this session only (not remembered)");
        Check(c.draft != nil && !c.recordPanel.hidden, @"Screen: after a picture from the radio, Record QSO / Discard QSO is offered");
        Check(lb.totalContactCount == before, @"Screen: nothing is logged on its own");
        Check(c.callField.stringValue.length == 0 && c.frequencyField.stringValue.length == 0 && c.rsvField.stringValue.length == 0 &&
              c.uploadCheckbox.state == NSControlStateValueOff,
              @"Screen: without CAT, the callsign, the frequency and the RSV start empty, and the upload off (no fixed value)");
        Check(![c recordQSO:&err] && [c.draftProblemLabel.stringValue containsString:@"callsign"] && lb.totalContactCount == before,
              @"Screen: with no callsign, nothing is recorded, and it says why");
        c.callField.stringValue = @"EP2AES";
        Check(![c recordQSO:&err] && [c.draftProblemLabel.stringValue containsString:@"frequency"] && lb.totalContactCount == before,
              @"Screen: with no frequency, nothing is recorded, and it says why");
        BOOL badFreq = YES;
        for (NSString *t in @[@"14230", @"1e30", @"14.230 MHz", @"0.1"]) {
            c.frequencyField.stringValue = t;
            badFreq = badFreq && ![c recordQSO:&err] && [c.draftProblemLabel.stringValue containsString:@"from 0.5 to 56"];
        }
        Check(badFreq && lb.totalContactCount == before,
              @"Screen: a frequency that is not 0.5 to 56 MHz («14230», «1e30», «14.230 MHz», «0.1») is not recorded, and it says so (SEG-8, PRO-14)");
        c.frequencyField.stringValue = @"14.230";
        c.rsvField.stringValue = @"595";
        BOOL saved = [c recordQSO:&err];
        TX500LogRecord *last = nil;
        for (TX500LogRecord *r in lb.allContacts) if ([r.callsign isEqualToString:@"EP2AES"]) last = r;
        Check(saved && ![c recordQSO:&err] && lb.totalContactCount == before + 1, @"Screen: Record QSO twice gives one contact");
        Check(saved && lb.totalContactCount == before + 1 && last && [last.mode isEqualToString:@"SSTV"] &&
              last.submode.length == 0 && [last.notes isEqualToString:@"Martin M1"] && [last.band isEqualToString:@"20m"] && last.frequencyHz == 14230000 &&
              [last.rstRcvd isEqualToString:@"595"] && last.rstSent.length == 0 && last.powerWatts == 0 &&
              ![[last adifRecordString] containsString:@"<SUBMODE"] && [[last adifRecordString] containsString:@"<COMMENT:9>Martin M1"] &&
              [[last adifRecordString] containsString:@"<MODE:4>SSTV"],
              @"Record QSO saves SSTV, with no submode (ADIF 3.1.7 lists none for SSTV) and «Martin M1» in COMMENT, 20m from 14.230 MHz, RSV 595, no made-up report or power (SEG-23)");
        Check(uploads == 0, @"Screen: recording is not uploading (the upload switch was off)");
        Check(c.draft == nil && c.recordPanel.hidden, @"Screen: after recording, the form goes");

        // 5. with a valid CAT reading the frequency and band are filled in; uploading only if asked
        [c setEnabled:NO error:nil];
        cat = @(7171000);
        [c setEnabled:YES error:nil];
        Check(c.draft.frequencyFromCAT && [c.frequencyField.stringValue hasPrefix:@"7.171"] && [c.bandLabel.stringValue containsString:@"40m"],
              @"Screen: with a valid CAT reading, the frequency (7.171 MHz) and the band (40m) come from the radio");
        c.callField.stringValue = @"EA3JIC";
        c.uploadCheckbox.state = NSControlStateValueOn;
        Check([c recordQSO:&err] && uploads == 1, @"Screen: with the upload switch on, the recorded QSO is uploaded once");

        // 6. Discard QSO (a few seconds later: here the audio plays in a moment, and the last test's
        // CAT reading, 7.171 MHz, must not fall inside this picture as it never would in real time)
        [c setEnabled:NO error:nil];
        cat = nil;
        NSInteger n0 = lb.totalContactCount;
        [NSThread sleepForTimeInterval:2.5];
        [c setEnabled:YES error:nil];
        TX500SSTVLogDraft *pending = c.draft;
        c.callField.stringValue = @"EP2AES";
        Check([c decodeFileAtURL:Fixture(@"R36.wav") synchronously:YES error:&err] && c.draft == pending && !c.recordPanel.hidden &&
              [c.callField.stringValue isEqualToString:@"EP2AES"],
              @"Screen: a practice WAV while a form is open leaves the form as it is (what was typed too)");
        __block NSString *logged = nil;
        c.logHandler = ^(NSString *line) { logged = line; };
        Check(pending != nil, @"Screen: there is a form to discard");
        [c.discardButton performClick:nil];
        c.logHandler = nil;
        Check(c.draft == nil && c.recordPanel.hidden && lb.totalContactCount == n0 && [logged containsString:@"not logged (discarded)"],
              @"Screen: the Discard QSO button logs nothing, and says so in the log");
        [c setEnabled:NO error:nil];
        Check(!c.enabled && [defs objectForKey:TX500SSTVEnabledDefaultsKey] == nil && !c.engine.running, @"Screen: turning it off stops (nothing stored)");

        // 6b. Record QSO once per reception, with the data kept with the reception
        {
            NSMutableArray<TX500SSTVStoredReception *> *rs = [NSMutableArray array];      // the radio's, newest first
            for (TX500SSTVStoredReception *x in c.recordings.receptions) if (!x.fromFile) [rs addObject:x];
            TX500SSTVStoredReception *discarded = rs.count > 0 ? rs[0] : nil, *logged = rs.count > 1 ? rs[1] : nil;
            Check(logged.logged && logged.offered && logged.catFrequencyHz == 7171000 && discarded.offered && !discarded.logged &&
                  discarded.catFrequencyHz == 0,
                  @"Store: each reception keeps whether its form was shown, whether it was logged, and the CAT frequency it was received on");
            TX500SSTVRecordingStore *reread = [[TX500SSTVRecordingStore alloc] initWithDirectory:c.recordings.directory];
            BOOL kept = NO;
            for (TX500SSTVStoredReception *x in reread.receptions)
                if ([x.identifier isEqualToString:logged.identifier]) kept = x.logged && x.offered && x.catFrequencyHz == 7171000 && [x.modeName isEqualToString:@"Martin M1"];
            Check(kept, @"Store: the marks and the frequency survive a restart");
            Check(![c beginRecordQSOForReception:logged error:&err] && c.draft == nil && [c.progressLabel.stringValue containsString:@"once"],
                  @"Record QSO…: a reception already logged cannot be logged again, and it says why");
            NSUInteger shownBefore = c.pictures.count;
            NSArray<TX500SSTVPicture *> *again = [c decodeAgainReception:discarded mode:TX500SSTVModeAuto colourScale:TX500SSTVColourScaleStudio
                                                           scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            Check(again.count == 1 && !again[0].fromFile && c.pictures.count == shownBefore + 1 && discarded.pictureNames.count == 2 &&
                  ![discarded.pictureNames[0] isEqualToString:discarded.pictureNames[1]] && c.draft == nil,
                  @"Decode again: the picture joins the same reception, with a gallery file of its own, and the form does not come back on its own (it was shown once)");
            cat = @(14230000);                                                       // the radio has moved since
            NSInteger n2 = lb.totalContactCount;
            Check([c beginRecordQSOForReception:discarded error:&err] && c.draft.reception == discarded && c.frequencyField.stringValue.length == 0,
                  @"Record QSO… on its row: the form again, with the reception's data: no CAT reading then, so no frequency now (never the radio's of this moment)");
            // a picture arrives while that form is open: its form waits its turn
            [c setEnabled:YES error:nil];
            TX500SSTVStoredReception *newer = c.recordings.receptions.firstObject;
            Check(c.draft.reception == discarded && c.waitingForms == 1 && newer != discarded && !newer.offered,
                  @"Record QSO: a new picture while a form is open waits its turn; nothing is lost");
            [c setEnabled:NO error:nil];
            c.callField.stringValue = @"EP2AES"; c.frequencyField.stringValue = @"14.230";
            Check([c recordQSO:&err] && lb.totalContactCount == n2 + 1 && discarded.logged, @"Record QSO…: the discarded reception is logged, once");
            NSDateFormatter *tf = [NSDateFormatter new];
            tf.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"]; tf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            tf.dateFormat = @"HHmmss";
            BOOL atItsTime = NO;
            for (TX500LogRecord *r in lb.allContacts)
                if ([r.callsign isEqualToString:@"EP2AES"] && [r.timeOn isEqualToString:[tf stringFromDate:discarded.endUTC]]) atItsTime = YES;
            Check(atItsTime, @"Record QSO…: the time logged is the reception's, not the moment of logging");
            Check(c.draft.reception == newer && newer.offered && c.waitingForms == 0 && [c.frequencyField.stringValue hasPrefix:@"14.230"],
                  @"Record QSO: then the waiting form comes, with the frequency the radio gave as that picture ended (14.230)");
            [c discardQSO];
            Check(c.draft == nil && ![c beginRecordQSOForReception:discarded error:&err] && lb.totalContactCount == n2 + 1,
                  @"Record QSO…: never twice for the same reception");
            cat = nil;
        }

        // 6b2. forms waiting their turn: each shows the picture it logs, keeps what was typed, and none holds
        // a picture (N-captura-8, N-captura-1, N-captura-6, N-memoria-disc-3)
        {
            NSURL *g3 = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-forms"] isDirectory:YES];
            TX500SSTVStationController *c3 = NewController(defs, g3, lb);
            c3.galleryInMemory = 5;
            __block NSString *nextWAV = @"M1.wav";
            c3.radioSourceFactory = ^id<TX500SSTVAudioSource> {
                SSTVTestRadio *r = [SSTVTestRadio new];
                r.file = [[TX500SSTVFileSource alloc] initWithURL:Fixture(nextWAV) error:nil];
                return r;
            };
            [c3 setEnabled:YES error:nil]; [c3 setEnabled:NO error:nil];
            TX500SSTVPicture *p1 = c3.pictures.lastObject;
            TX500SSTVStoredReception *r1 = c3.draft.reception;
            nextWAV = @"R36.wav";
            [c3 setEnabled:YES error:nil]; [c3 setEnabled:NO error:nil];
            TX500SSTVPicture *p2 = c3.pictures.lastObject;
            TX500SSTVStoredReception *r2 = c3.recordings.receptions.firstObject;
            NSBitmapImageRep *onForm = (NSBitmapImageRep *)c3.draftPictureView.image.representations.firstObject;
            Check(r1 && r2 != r1 && c3.draft.reception == r1 && c3.waitingForms == 1 && c3.shownPicture == p2 && c3.draftShowsPicture &&
                  p1.height == 256 && p2.height == 240 && onForm.pixelsHigh == 256 &&
                  [c3.draftInfoLabel.stringValue containsString:[c3 textForRow:2 column:@"ended"]] &&
                  [c3.draftInfoLabel.stringValue containsString:@"1 more waiting"],
                  @"Screen: with a newer picture shown above (Robot 36), the open form shows the one it logs (Martin M1), names when it was received, and says one more waits");
            c3.callField.stringValue = @"EA3JIC"; c3.rsvField.stringValue = @"5";
            BOOL toR2 = [c3 beginRecordQSOForReception:r2 error:nil] && c3.draft.reception == r2;
            [c3 discardQSO];
            Check(toR2 && c3.draft.reception == r1 && [c3.callField.stringValue isEqualToString:@"EA3JIC"] && [c3.rsvField.stringValue isEqualToString:@"5"],
                  @"Screen: Record QSO… on another row and back: the first form keeps what was typed on it");
            nextWAV = @"M1.wav";
            [c3 setEnabled:YES error:nil]; [c3 setEnabled:NO error:nil];
            TX500SSTVStoredReception *r3 = c3.recordings.receptions.firstObject;
            NSInteger row3 = -1;
            for (NSInteger k = 1; k < c3.recordingsTable.numberOfRows; k++) if ([c3 receptionAtRow:k] == r3) row3 = k;
            BOOL waits3 = c3.waitingForms == 1;
            [c3.recordingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row3] byExtendingSelection:NO];
            [c3.discardRowButton performClick:nil];
            Check(waits3 && row3 > 0 && r3.offered && c3.waitingForms == 0 && c3.draft.reception == r1,
                  @"Screen: Discard QSO on the row of a picture whose form waits: that form goes too, and the open one stays");
            // a form open and nobody there: 40 more pictures; the waiting forms hold none of them
            NSPointerArray *alive = [NSPointerArray weakObjectsPointerArray];
            nextWAV = @"R36.wav";
            for (int k = 0; k < 40; k++) {
                @autoreleasepool {
                    [c3 setEnabled:YES error:nil]; [c3 setEnabled:NO error:nil];
                    [alive addPointer:(__bridge void *)c3.pictures.lastObject];
                }
            }
            NSUInteger live = 0;
            for (NSUInteger i = 0; i < alive.count; i++) if ([alive pointerAtIndex:i]) live++;
            Check(c3.waitingForms == 40 && live <= c3.galleryInMemory,
                  [NSString stringWithFormat:@"Screen: a form open and 40 more pictures: 40 forms wait, and only %lu of those pictures are still in memory (the gallery keeps %lu)",
                   (unsigned long)live, (unsigned long)c3.galleryInMemory]);
            [c3 discardQSO];
            BOOL noPictureForm = !c3.draftShowsPicture && [c3.draftInfoLabel.stringValue containsString:@"no longer kept"];
            Check(c3.draft != nil && (c3.draftShowsPicture || noPictureForm) &&
                  c3.draftShowsPicture == [c3.draftInfoLabel.stringValue containsString:@"(shown here)"],
                  @"Screen: a waiting form whose picture has left memory shows its PNG, or says it is no longer kept; «shown here» only when it is");
            // SEG-19: the own callsign, the own grid only if the profile has one;
            // nothing else of the station profile (here one with a device, a name and a rig in it)
            NSUserDefaults *sd = NSUserDefaults.standardUserDefaults;
            id oldProfile = [sd objectForKey:@"TX500_ActiveStationProfile"];
            [sd setObject:@{@"call": @"EA3JIC", @"grid": @"JN11", @"operatorName": @"Test Name", @"rig": @"Test Rig",
                            @"radioInput": @"TEST-DEVICE-UID-0001", @"city": @"Test City"} forKey:@"TX500_ActiveStationProfile"];
            TX500SSTVLogDraft *dg = [[TX500SSTVLogDraft alloc] initWithPicture:p1 catFrequencyHz:@(14230000)];
            dg.callsign = @"EP2AES"; dg.myCallsign = @"EA3JIC"; dg.myGrid = @"jn11";
            TX500LogRecord *rg = [dg record];
            NSString *adifG = [rg adifRecordString];
            TX500SSTVLogDraft *dn = [[TX500SSTVLogDraft alloc] initWithPicture:p1 catFrequencyHz:@(14230000)];
            dn.callsign = @"EP2AES"; dn.myCallsign = @"EA3JIC"; dn.myGrid = nil;
            TX500LogRecord *rn = [dn record];
            NSString *adifN = [rn adifRecordString];
            TX500SSTVLogDraft *db = [[TX500SSTVLogDraft alloc] initWithPicture:p1 catFrequencyHz:@(14230000)];
            db.callsign = @"EP2AES"; db.myCallsign = @"EA3JIC"; db.myGrid = @"not a grid";
            if (oldProfile) [sd setObject:oldProfile forKey:@"TX500_ActiveStationProfile"]; else [sd removeObjectForKey:@"TX500_ActiveStationProfile"];
            BOOL nothingElse = YES;
            for (NSString *a in @[adifG, adifN])
                for (NSString *bad in @[@"TEST-DEVICE-UID", @"Test Name", @"Test Rig", @"Test City", @"MY_RIG", @"MY_NAME", @"MY_CITY"])
                    if ([a containsString:bad]) nothingElse = NO;
            Check(rg.stationProfile == nil && [rg.myCall isEqualToString:@"EA3JIC"] && [rg.myGrid isEqualToString:@"JN11"] &&
                  [adifG containsString:@"<MY_GRIDSQUARE:4>JN11"] && rn.myGrid == nil && ![adifN containsString:@"MY_GRIDSQUARE"] &&
                  [db record].myGrid == nil && nothingElse,
                  @"Record QSO: of the station only the own callsign, and the own grid when the profile has one; no device, name, rig or city of the profile (SEG-19)");
            // SEG-9: the form's switch «Also upload to Logbook» means upload now; unticked (the default) the
            // QSO stays pending in the Logbook. Its note follows the switch, each choice with its Good for /
            // Not good for; Record QSO / Discard QSO have a note of their own that informs, with no rule
            BOOL startedOff = c3.uploadCheckbox.state == NSControlStateValueOff;
            NSString *offNote = c3.uploadNote.stringValue;
            [c3.uploadCheckbox performClick:nil];
            NSString *onNote = c3.uploadNote.stringValue;
            [c3.uploadCheckbox performClick:nil];
            Check([c3.uploadCheckbox.title isEqualToString:@"Also upload to Logbook"] && startedOff &&
                  [offNote hasPrefix:@"Not now (the default)"] && [offNote containsString:@"Sync All or Sync Selected"] &&
                  [offNote containsString:@"Good for:"] && [offNote containsString:@"Not good for:"] &&
                  [onNote hasPrefix:@"Upload now."] && [onNote containsString:@"Good for:"] && [onNote containsString:@"Not good for:"] &&
                  c3.uploadCheckbox.state == NSControlStateValueOff && [c3.uploadNote.stringValue isEqualToString:offNote],
                  @"Upload: «Also upload to Logbook» means upload now; unticked (the default) the QSO stays pending until Sync All or Sync Selected; the note follows the switch, each with Good for / Not good for");
            NSString *rdNote = c3.recordNote.stringValue;
            Check([rdNote containsString:@"your call"] && [rdNote containsString:@"Record QSO · Good for:"] && [rdNote containsString:@"Discard QSO · Good for:"] &&
                  [rdNote containsString:@"another mode or by appointment"] && [rdNote containsString:@"phone, CW, a VARA chat, a satellite QSO"] &&
                  [rdNote containsString:@"ISS"] && [rdNote containsString:@"that is a reception"] &&
                  ![rdNote containsString:@"must"] && ![rdNote containsString:@"only when"] && ![rdNote containsString:@"never"],
                  @"Record QSO / Discard QSO: the note informs (part of a contact, even one begun in another mode or by appointment; a picture only received is a reception), with no rule");
            // an SSTV contact edited in the Logbook keeps its empty reports, and its save uploads it as the Logbook
            // uploads any QSO it saves (N2-importants-nous-10)
            Check([[TX500LogbookController reportFromField:@"" mode:@"SSTV"] isEqualToString:@""] &&
                  [[TX500LogbookController reportFromField:@"595" mode:@"SSTV"] isEqualToString:@"595"] &&
                  [[TX500LogbookController reportFromField:@"" mode:@"USB"] isEqualToString:@"59"],
                  @"Logbook: saving an SSTV contact never makes up a report (empty stays empty); the voice log keeps its 59");
            // and the same through the Logbook's own form: an SSTV contact with empty reports, edited (another
            // callsign) and saved, stays SSTV, its reports stay empty, its comment is kept, and it is uploaded
            // once, as any QSO saved there
            {
                TX500LogbookManager *shared = [TX500LogbookManager sharedManager];
                TX500SSTVLogDraft *de = [[TX500SSTVLogDraft alloc] initWithPicture:p1 catFrequencyHz:@(14230000)];
                de.callsign = @"EP2AES"; de.myCallsign = @"EA3JIC";
                TX500LogRecord *re = [de record];
                re.rstSent = @""; re.rstRcvd = @"";
                BOOL saved = [shared saveContact:re error:nil];
                NSString *comment = [shared contactWithUUID:re.uuid].notes ?: @"";
                __block NSInteger uploads = 0;
                Method up = class_getInstanceMethod(TX500CloudSyncEngine.class, @selector(uploadContactImmediately:completion:));
                IMP realUpload = method_setImplementation(up, imp_implementationWithBlock(^(id engine, TX500LogRecord *r, void (^done)(BOOL, NSString *)) {
                    (void)engine; (void)r; uploads++;
                    if (done) done(YES, @"");
                }));
                TX500LogbookController *lc = [TX500LogbookController new];
                NSUInteger row = [lc.displayedContacts indexOfObjectPassingTest:^BOOL(TX500LogRecord *x, NSUInteger i, BOOL *stop) {
                    (void)i; (void)stop; return [x.uuid isEqualToString:re.uuid];
                }];
                if (row != NSNotFound) {
                    [lc.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO];
                    [lc editSelectedContact:nil];
                    lc.callsignField.stringValue = @"EA3JIC";
                    [lc logContactAction];
                }
                method_setImplementation(up, realUpload);
                TX500LogRecord *after = [shared contactWithUUID:re.uuid];
                Check(saved && row != NSNotFound && [after.callsign isEqualToString:@"EA3JIC"] &&
                      [after.mode isEqualToString:@"SSTV"] && after.rstSent.length == 0 && after.rstRcvd.length == 0 &&
                      comment.length > 0 && [after.notes isEqualToString:comment] && [after.band isEqualToString:re.band] && uploads == 1,
                      [NSString stringWithFormat:@"Logbook: an SSTV contact with empty reports, edited and saved with another callsign, stays SSTV with its reports empty and its comment, and is uploaded once, as any QSO saved there (mode %@, sent '%@', rcvd '%@', comment kept %d, uploads %ld)",
                       after.mode, after.rstSent, after.rstRcvd, [after.notes isEqualToString:comment], (long)uploads]);
            }
            // Sync: an SSTV QSO recorded on the form with the upload unticked is not uploaded then, stays
            // pending in the Logbook, and Sync All sends it like any other QSO
            {
                TX500LogbookManager *shared = [TX500LogbookManager sharedManager];
                NSURL *gs = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-sync"] isDirectory:YES];
                TX500SSTVStationController *cs = NewController(defs, gs, nil);   // the app's own logbook, as on the screen
                cs.catFrequencyProvider = ^NSNumber * { return @(14230000); };
                cs.radioSourceFactory = ^id<TX500SSTVAudioSource> {
                    SSTVTestRadio *r = [SSTVTestRadio new];
                    r.file = [[TX500SSTVFileSource alloc] initWithURL:Fixture(@"M1.wav") error:nil];
                    return r;
                };
                NSMutableSet<NSString *> *known = [NSMutableSet set];
                for (TX500LogRecord *r in shared.allContacts) [known addObject:r.uuid];
                __block NSInteger atOnce = 0;
                Method upNow = class_getInstanceMethod(TX500CloudSyncEngine.class, @selector(uploadContactImmediately:completion:));
                IMP realNow = method_setImplementation(upNow, imp_implementationWithBlock(^(id engine, TX500LogRecord *r, void (^done)(BOOL, NSString *)) {
                    (void)engine; (void)r; atOnce++;
                    if (done) done(YES, @"");
                }));
                [cs setEnabled:YES error:nil]; [cs setEnabled:NO error:nil];
                cs.callField.stringValue = @"EP2AES";
                BOOL recorded = cs.uploadCheckbox.state == NSControlStateValueOff && [cs recordQSO:nil];
                TX500LogRecord *fromForm = nil;
                for (TX500LogRecord *r in shared.allContacts) if (![known containsObject:r.uuid]) fromForm = r;
                BOOL pendingEverywhere = fromForm && [fromForm.mode isEqualToString:@"SSTV"] &&
                    [fromForm.qrzStatus isEqualToString:@"NONE"] && [fromForm.clublogStatus isEqualToString:@"NONE"] &&
                    [fromForm.eqslStatus isEqualToString:@"NONE"] && [fromForm.lotwStatus isEqualToString:@"NONE"];
                // the cloud stood in for while Sync runs: what it sends is noted, and nothing leaves the Mac
                NSMutableArray<NSString *> *sent = [NSMutableArray array];
                Method upTo = class_getInstanceMethod(TX500CloudSyncEngine.class, @selector(uploadContact:toServices:completion:));
                IMP realTo = method_setImplementation(upTo, imp_implementationWithBlock(^(id engine, TX500LogRecord *r, NSArray<NSString *> *services, void (^done)(BOOL, NSString *)) {
                    (void)engine;
                    @synchronized (sent) { [sent addObject:[NSString stringWithFormat:@"%@:%@", r.uuid, [services componentsJoinedByString:@","]]]; }
                    if (done) done(YES, @"");
                }));
                BOOL keyStored = TX500StoreSecret(@"TX500_QRZ_APIKey", @"test-qrz-key");
                __block BOOL synced = NO;
                [[TX500CloudSyncEngine sharedEngine] syncContacts:nil completion:^(NSInteger u, NSInteger f, NSString *summary) {
                    (void)u; (void)f; (void)summary; synced = YES;
                }];
                NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:10];
                while (!synced && limit.timeIntervalSinceNow > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
                method_setImplementation(upTo, realTo);
                method_setImplementation(upNow, realNow);
                TX500RemoveSecret(@"TX500_QRZ_APIKey");
                BOOL sentBySync = NO;
                @synchronized (sent) { sentBySync = fromForm && [sent containsObject:[fromForm.uuid stringByAppendingString:@":QRZ"]]; }
                Check(recorded && atOnce == 0 && pendingEverywhere && keyStored && synced && sentBySync,
                      [NSString stringWithFormat:@"Sync: an SSTV QSO recorded on the form with the upload unticked is not uploaded then, stays pending on every service, and Sync All sends it (recorded %d, uploaded at once %ld, pending %d, sent by Sync %d)",
                       recorded, (long)atOnce, pendingEverywhere, sentBySync]);
            }
            // PRO-9 (4): the controls themselves, pressed as the operator presses them
            NSUInteger waitBefore = c3.waitingForms;
            [c3.enableSwitch performClick:nil];                                      // Listen on: the test radio plays one more
            BOOL listened = c3.waitingForms == waitBefore + 1;
            [c3.enableSwitch performClick:nil];                                      // and Off
            BOOL offAgain = !c3.enabled && !c3.engine.running;
            NSInteger nBefore = lb.totalContactCount;
            c3.callField.stringValue = @"EP2AES"; c3.frequencyField.stringValue = @"14.230";
            [c3.recordButton performClick:nil];
            BOOL recorded = lb.totalContactCount == nBefore + 1;
            NSInteger rowPending = -1;
            for (NSInteger k = 1; k < c3.recordingsTable.numberOfRows; k++) {
                TX500SSTVStoredReception *x = [c3 receptionAtRow:k];
                if (!x.fromFile && !x.logged && x != c3.draft.reception && rowPending < 0) rowPending = k;
            }
            [c3.recordingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)rowPending] byExtendingSelection:NO];
            TX500SSTVStoredReception *xr = [c3 receptionAtRow:rowPending];
            [c3.recordRowButton performClick:nil];
            BOOL rowForm = xr && c3.draft.reception == xr;
            BOOL keepable = c3.keepCheckbox.enabled;
            [c3.keepCheckbox performClick:nil];
            BOOL kept = xr.keep && xr.onDisk;
            [c3.discardButton performClick:nil];
            Check(listened && offAgain && recorded && rowPending > 0 && rowForm && keepable && kept && lb.totalContactCount == nBefore + 1,
                  @"Screen: the controls as pressed: Listen on and off, Record QSO, Record QSO… on a row, Keep on a radio row, Discard QSO");
        }

        // 6c. the last minutes: a picture whose VIS was missed, found by hand, is a reception of its own
        {
            NSURL *g2 = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-last-minutes"] isDirectory:YES];
            TX500SSTVStationController *c2 = NewController(defs, g2, lb);
            __block NSNumber *cat2 = nil;
            c2.catFrequencyProvider = ^NSNumber * { return cat2; };
            c2.radioSourceFactory = ^id<TX500SSTVAudioSource> {
                SSTVTestRadio *r = [SSTVTestRadio new];
                r.file = [[TX500SSTVFileSource alloc] initWithURL:Fixture(@"M1-novis.wav") error:nil];
                return r;
            };
            NSDate *t0 = [NSDate date];
            [c2 setEnabled:YES error:nil];
            Check(c2.draft == nil && c2.pictures.count == 0 && c2.recordings.receptions.count == 0, @"Last minutes: no VIS, Auto: no picture, no form");
            // the readings taken meanwhile (here minutes of audio are played in a moment): 7.171 MHz before and after
            // (the one before 10 s before the audio: well outside the picture, so the before-and-after rule is the one at work, N-proves-afirmacions-16)
            [c2 noteCATFrequency:@(7171000) atDate:[t0 dateByAddingTimeInterval:-10]];
            [c2 noteCATFrequency:@(7171000) atDate:[t0 dateByAddingTimeInterval:250]];
            cat2 = @(14230000);                                                      // and the radio is elsewhere now
            [NSThread sleepForTimeInterval:1.5];                                     // decoded later than it was heard
            NSArray<TX500SSTVPicture *> *none = [c2 decodeLastMinutesWithMode:TX500SSTVModeAuto colourScale:TX500SSTVColourScaleStudio
                                                                scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            Check(none.count == 0 && [c2.reviewLabel.stringValue containsString:@"by hand"], @"Last minutes with Auto: nothing, and it says to choose the mode by hand");
            NSArray<TX500SSTVPicture *> *found = [c2 decodeLastMinutesWithMode:TX500SSTVModeMartin1 colourScale:TX500SSTVColourScaleStudio
                                                                 scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            TX500SSTVStoredReception *r = c2.recordings.receptions.firstObject;
            Check(found.count == 1 && !found[0].fromFile && c2.recordings.receptions.count == 1 && r.pictureNames.count == 1 && c2.draft.reception == r,
                  @"Last minutes, Martin M1 by hand: the picture is a reception of its own, and its form comes, once");
            double firstLine = found.count ? found[0].startTime : -1;
            Check(r && found[0].startUTC && fabs([found[0].startUTC timeIntervalSinceDate:t0] - firstLine) < 0.5 &&
                  fabs([r.endUTC timeIntervalSinceDate:found[0].endUTC]) < 0.01 && found[0].recording == nil && [found[0].receptionIdentifier isEqualToString:r.identifier],
                  [NSString stringWithFormat:@"Last minutes: the time is when it was heard (first line %.1f s into the audio), not when it was decoded; the picture lets its audio go to the store", firstLine]);
            Check(r.catFrequencyHz == 7171000 && [c2.frequencyField.stringValue hasPrefix:@"7.171"],
                  @"Last minutes: the frequency is the one the radio was on then (7.171 MHz before and after), not the one of now (14.230)");
            [c2 discardQSO];
            NSArray<TX500SSTVPicture *> *twice = [c2 decodeLastMinutesWithMode:TX500SSTVModeMartin1 colourScale:TX500SSTVColourScaleStudio
                                                                 scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            Check(twice.count == 1 && c2.recordings.receptions.count == 1 && r.pictureNames.count == 2 && c2.draft == nil,
                  @"Last minutes again: the picture joins the reception it already is (no second one), and the form does not come back");
            [c2 setEnabled:NO error:nil];
            // the reading before and the one after disagree: the radio was retuned, so no frequency (the operator enters it)
            TX500SSTVStationController *c2b = NewController(defs, [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-last-minutes-b"] isDirectory:YES], lb);
            c2b.radioSourceFactory = c2.radioSourceFactory;
            NSDate *t0b = [NSDate date];
            [c2b setEnabled:YES error:nil];
            [c2b noteCATFrequency:@(7171000) atDate:[t0b dateByAddingTimeInterval:-10]];
            [c2b noteCATFrequency:@(14230000) atDate:[t0b dateByAddingTimeInterval:250]];
            NSArray<TX500SSTVPicture *> *foundB = [c2b decodeLastMinutesWithMode:TX500SSTVModeMartin1 colourScale:TX500SSTVColourScaleStudio
                                                                   scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            TX500SSTVStoredReception *rb = c2b.recordings.receptions.firstObject;
            Check(foundB.count == 1 && rb.catFrequencyHz == 0 && c2b.frequencyField.stringValue.length == 0,
                  @"Last minutes: a reading before (7.171) and one after (14.230) that disagree give no frequency: the operator enters it");
            [c2b discardQSO];
            [c2b setEnabled:NO error:nil];
        }

        // 6d. a picture whose VIS was missed, Martin M1 chosen mid-way, and then the last minutes decoded with
        // it: the screen says where the whole picture is (DEC-2), and it stays one reception, one form (N-captura-9)
        {
            TX500SSTVRecording *nv = [TX500SSTVRecording recordingFromWAVAtURL:Fixture(@"M1-novis.wav") error:nil];
            NSUserDefaults *defs6 = [[NSUserDefaults alloc] initWithSuiteName:[suite stringByAppendingString:@".midway"]];
            TX500SSTVStationController *c6 = NewController(defs6, [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-midway"] isDirectory:YES], lb);
            SSTVManualRadio *mr = [SSTVManualRadio new];
            c6.radioSourceFactory = ^id<TX500SSTVAudioSource> { return mr; };
            BOOL on6 = nv && nv.sampleRate == 12000 && [c6 setEnabled:YES error:nil];
            const int16_t *smp = nv.samples.bytes;
            NSUInteger n6 = nv.samples.length / 2, half = n6 * 6 / 10;
            NSDate *t6 = [NSDate dateWithTimeIntervalSinceNow:-300];
            if (on6) [mr play:smp count:half from:t6];
            [c6.modePopup selectItemAtIndex:TX500SSTVModeMartin1];
            [c6.modePopup sendAction:c6.modePopup.action to:c6.modePopup.target];
            NSString *said6 = c6.progressLabel.stringValue;
            if (on6) [mr play:smp + half count:n6 - half from:[t6 dateByAddingTimeInterval:half / 12000.0]];
            [c6 setEnabled:NO error:nil];
            NSUInteger partial6 = c6.recordings.receptions.count;
            TX500SSTVStoredReception *r6 = c6.recordings.receptions.firstObject;
            NSArray<TX500SSTVPicture *> *whole6 = [c6 decodeLastMinutesWithMode:TX500SSTVModeMartin1 colourScale:TX500SSTVColourScaleStudio
                                                                  scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            Check(on6 && [said6 containsString:@"decode the last minutes again"] && partial6 == 1 && whole6.count == 1 &&
                  !c6.pictures.firstObject.complete &&
                  whole6[0].rowsReceived > (NSInteger)(c6.pictures.firstObject.rowsReceived) && c6.recordings.receptions.count == 1 &&
                  r6.pictureNames.count == 2 && c6.waitingForms == 0 && c6.draft.reception == r6,
                  [NSString stringWithFormat:@"Screen: Martin M1 chosen mid-way says the whole picture is in the last minutes; decoded from them (%ld rows, the part had %ld), it joins the same reception: one reception, one form",
                   (long)(whole6.count ? whole6[0].rowsReceived : 0), (long)c6.pictures.firstObject.rowsReceived]);
            [c6 discardQSO];
        }

        // 6e. The decisions on the screen: Keep with the disk Off saves that one recording and says so
        // (DEC-17); the last 5 minutes stay in memory after Off, with their end time, and a start that opens
        // nothing leaves them as they were; Keep on them keeps a copy of their own (N-seguretat-6)
        {
            NSUserDefaults *defsE = [[NSUserDefaults alloc] initWithSuiteName:[suite stringByAppendingString:@".decisions"]];
            [defsE setInteger:0 forKey:@"TX500SSTVDiskShare"];                         // «Off»
            TX500SSTVStationController *ce = NewController(defsE, [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-decisions"] isDirectory:YES], lb);
            ce.radioSourceFactory = ^id<TX500SSTVAudioSource> {
                SSTVTestRadio *r = [SSTVTestRadio new];
                r.file = [[TX500SSTVFileSource alloc] initWithURL:Fixture(@"R36.wav") error:nil];
                return r;
            };
            [ce setEnabled:YES error:nil];
            [ce setEnabled:NO error:nil];
            [ce discardQSO];
            TX500SSTVStoredReception *re = ce.recordings.receptions.firstObject;
            BOOL offNothing = re && !re.onDisk && [ce.diskSummaryLabel.stringValue containsString:@"Off · nothing is saved on disk"];
            [ce.recordingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
            [ce.keepCheckbox performClick:nil];
            Check(offNothing && re.keep && re.onDisk && [ce.progressLabel.stringValue containsString:@"although the disk is Off"] &&
                  [ce.diskSummaryLabel.stringValue containsString:@"Off · only what you keep is on disk: 1 kept recording"],
                  [NSString stringWithFormat:@"Screen: with the disk Off, Keep saves that one recording, and the screen says so (DEC-17): %@", ce.diskSummaryLabel.stringValue]);
            // the last minutes after Off
            NSUInteger bytesE = ce.engine.lastMinutesByteSize;
            NSString *endE = [ce textForRow:0 column:@"ended"], *statusE = [ce textForRow:0 column:@"status"];
            Check(!ce.engine.running && bytesE > 0 && ![endE isEqualToString:@"now"] && [endE hasPrefix:@"20"] &&
                  [statusE containsString:@"in memory until the app quits"] && [[ce textForRow:0 column:@"audio"] containsString:@"(memory)"],
                  [NSString stringWithFormat:@"Screen: after Off, the last minutes stay in memory, with when they end (%@): %@", endE, statusE]);
            NSArray<TX500SSTVPicture *> *again6e = [ce decodeLastMinutesWithMode:TX500SSTVModeAuto colourScale:TX500SSTVColourScaleStudio
                                                                 scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            Check(again6e.count == 1, @"Screen: Decode again on the last minutes works with Listen Off");
            ce.radioSourceFactory = ^id<TX500SSTVAudioSource> { return [[TX500SSTVRadioSource alloc] initWithDeviceUID:@"no-such-device-uid"]; };
            BOOL failed = ![ce setEnabled:YES error:nil];
            Check(failed && ce.engine.lastMinutesByteSize == bytesE && [[ce textForRow:0 column:@"ended"] isEqualToString:endE],
                  @"Screen: a Listen that opens nothing (the input is not there) leaves the last minutes as they were");
            NSUInteger nBeforeE = ce.recordings.receptions.count;
            [ce.recordingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            BOOL ringKeepable = ce.keepCheckbox.enabled;
            ce.keepCheckbox.state = NSControlStateValueOn;
            [ce.keepCheckbox sendAction:ce.keepCheckbox.action to:ce.keepCheckbox.target];
            TX500SSTVStoredReception *ke = ce.recordings.receptions.firstObject;
            Check(ringKeepable && ce.recordings.receptions.count == nBeforeE + 1 && ke.keep && ke.onDisk && !ke.fromFile && ke.pictureNames.count == 0 &&
                  [[ce textForRow:1 column:@"mode"] hasPrefix:@"Last minutes, kept"] && ce.draft == nil,
                  @"Screen: Keep on the last minutes keeps a copy of their own on disk (the only way they get there), with no form (no picture yet)");
            BOOL onCopyRow = ce.recordingsTable.selectedRow == 1 && ce.keepCheckbox.state == NSControlStateValueOn;
            [ce.recordingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
            Check(!ce.recordRowButton.enabled, @"Screen: Record QSO… is off for audio with no picture (Decode again first)");
            // the list went to the copy's row, ticked; the last minutes show ticked too, and Keep on them again
            // makes no second copy; the copy took no place in memory (N3-importants-nous-1, N3-menors-oberts-1)
            [ce.recordingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            BOOL ringTicked = ce.keepCheckbox.state == NSControlStateValueOn;
            ce.keepCheckbox.state = NSControlStateValueOn;
            [ce.keepCheckbox sendAction:ce.keepCheckbox.action to:ce.keepCheckbox.target];
            Check(onCopyRow && ringTicked && ce.recordings.receptions.count == nBeforeE + 1 && !ke.inMemory && ke.keep,
                  @"Screen: after Keep on the last minutes the list shows their copy ticked, the last minutes show ticked, and Keep again makes no second copy");
            // Decode again after Keep opens the form: the copy is not marked reviewed (N3-importants-nous-2)
            NSArray<TX500SSTVPicture *> *again6f = [ce decodeLastMinutesWithMode:TX500SSTVModeAuto colourScale:TX500SSTVColourScaleStudio
                                                                 scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            Check(again6f.count == 1 && ce.draft != nil && ce.draft.reception == ke && ke.pictureNames.count == 1,
                  @"Screen: Keep on the last minutes, then Decode again: the picture is listed with the copy and its form opens");
            [ce discardQSO];
            // untick on the last minutes lets their copy go
            [ce.recordingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            ce.keepCheckbox.state = NSControlStateValueOff;
            [ce.keepCheckbox sendAction:ce.keepCheckbox.action to:ce.keepCheckbox.target];
            Check(!ke.keep, @"Screen: untick Keep on the last minutes lets their copy go");
            // a form whose picture has left memory, with the disk Off (no PNG kept): it says so, and never «shown here» (N2-importants-nous-5)
            ce.galleryInMemory = 1;
            ce.radioSourceFactory = ^id<TX500SSTVAudioSource> {
                SSTVTestRadio *r = [SSTVTestRadio new];
                r.file = [[TX500SSTVFileSource alloc] initWithURL:Fixture(@"R36.wav") error:nil];
                return r;
            };
            [ce discardQSO];
            // no row of the last minutes selected while pictures come: here the engine calls the screen on its own
            // thread with its lock held (callbackQueue nil), and that row asks the engine (the app's calls go to the main queue)
            [ce.recordingsTable deselectAll:nil];
            TX500SSTVLogDraft *dOff = nil;
            @autoreleasepool { [ce setEnabled:YES error:nil]; [ce setEnabled:NO error:nil]; dOff = ce.draft; }
            @autoreleasepool { [ce setEnabled:YES error:nil]; [ce setEnabled:NO error:nil]; }
            [ce refreshDraftInfo];
            Check(dOff && ce.draft == dOff && !ce.draftShowsPicture && ![ce.draftInfoLabel.stringValue containsString:@"(shown here)"] &&
                  [ce.draftInfoLabel.stringValue containsString:@"no longer kept"],
                  [NSString stringWithFormat:@"Screen: disk Off and a small gallery: the form whose picture has gone says it is no longer kept, never «shown here»: %@",
                   ce.draftInfoLabel.stringValue]);
            [ce discardQSO];
        }

        // 6f. The Mac's own input is asked first, the radio's never (N-seguretat-5); a WAV and Decode
        // again show in a view of their own, and a picture can be decoded again while another arrives (SEG-22)
        {
            TX500SSTVStationController *cb = NewController(defs, [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-builtin"] isDirectory:YES], lb);
            SSTVManualRadio *mic = [SSTVManualRadio new];
            mic.name = @"Test microphone"; mic.builtIn = YES;
            cb.radioSourceFactory = ^id<TX500SSTVAudioSource> { return mic; };
            __block NSUInteger asked = 0;
            __block BOOL answer = NO;
            __block NSString *askedName = nil;
            cb.confirmBuiltInInput = ^BOOL(NSString *name) { asked++; askedName = name; return answer; };
            NSError *eb = nil;
            BOOL refused = ![cb setEnabled:YES error:&eb] && !cb.enabled && !cb.engine.running && mic.deliver == nil && asked == 1 &&
                           eb.code == 23 && [cb.progressLabel.stringValue containsString:@"not confirmed"] && [askedName isEqualToString:@"Test microphone"];
            answer = YES;
            BOOL opened = [cb setEnabled:YES error:nil] && cb.engine.running && mic.deliver != nil && asked == 2;
            [cb setEnabled:NO error:nil];
            SSTVManualRadio *radio = [SSTVManualRadio new];
            radio.name = @"TX-500 USB audio";
            cb.radioSourceFactory = ^id<TX500SSTVAudioSource> { return radio; };
            BOOL noQuestion = [cb setEnabled:YES error:nil] && cb.engine.running && asked == 2;
            Check(refused && opened && noQuestion,
                  @"Screen: the Mac's own input is asked before it opens (refused: nothing opens, and it says why; confirmed: it opens); the radio's input opens without a question");
            // a picture from the radio, then a WAV and Decode again in their own view
            TX500SSTVRecording *m1 = [TX500SSTVRecording recordingFromWAVAtURL:Fixture(@"M1.wav") error:nil];
            const int16_t *ms = m1.samples.bytes;
            NSUInteger mn = m1.samples.length / 2;
            NSDate *tm = [NSDate dateWithTimeIntervalSinceNow:-400];
            [radio play:ms count:mn from:tm];
            [cb discardQSO];
            TX500SSTVPicture *live = cb.shownPicture;
            TX500SSTVStoredReception *r1 = cb.recordings.receptions.firstObject;
            NSImage *liveImage = cb.pictureView.image;
            [cb decodeFileAtURL:Fixture(@"R36.wav") synchronously:YES error:nil];
            BOOL wavOwn = live && !live.fromFile && cb.pictureView.image == liveImage && cb.shownPicture == live &&
                          cb.reviewPicture.fromFile && [cb.reviewLabel.stringValue containsString:@"practice, not logged"];
            // the next transmission is arriving: half of it, and Decode again on the first one meanwhile
            [radio play:ms count:mn / 2 from:[tm dateByAddingTimeInterval:200]];
            BOOL arriving = cb.engine.receiving;
            NSImage *partial = cb.pictureView.image;
            NSArray<TX500SSTVPicture *> *again = [cb decodeAgainReception:r1 mode:TX500SSTVModeAuto colourScale:TX500SSTVColourScaleStudio
                                                          scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            BOOL againOwn = arriving && again.count == 1 && cb.reviewPicture == again[0] && cb.pictureView.image == partial &&
                            cb.engine.receiving && [cb.reviewLabel.stringValue containsString:@"Decoded again"];
            [radio play:ms + mn / 2 count:mn - mn / 2 from:[tm dateByAddingTimeInterval:200 + (double)(mn / 2) / 12000.0]];
            BOOL finished = !cb.engine.receiving && cb.shownPicture != live && !cb.shownPicture.fromFile && cb.shownPicture.complete;
            Check(wavOwn && againOwn && finished,
                  @"Screen: a WAV and Decode again show in their own view, never over the radio's; a picture is decoded again while the next one arrives, and that one ends in the live view");
            [cb discardQSO];
            [cb setEnabled:NO error:nil];
        }

        // 7. practice: a picture from a file is never logged
        NSInteger n1 = lb.totalContactCount;
        NSUInteger shown = c.pictures.count;
        Check([c decodeFileAtURL:Fixture(@"R36.wav") synchronously:YES error:&err] && c.pictures.count == shown + 1 &&
              c.pictures.lastObject.fromFile && c.draft == nil && c.recordPanel.hidden,
              @"Screen: a WAV file is practice: the picture is shown, and no QSO is offered");
        c.callField.stringValue = @"EP2AES"; c.frequencyField.stringValue = @"14.230";
        Check(![c recordQSO:&err] && lb.totalContactCount == n1, @"Screen: practice never writes to the logbook");
        TX500SSTVStoredReception *practice = c.recordings.receptions.firstObject;
        Check(practice.fromFile && ![c beginRecordQSOForReception:practice error:&err] && c.draft == nil && lb.totalContactCount == n1,
              @"Record QSO…: never for a WAV file");

        // 7b. which input: only the radio's, chosen by the operator, and always said (SEG-2)
        {
            NSError *e1 = nil, *e2 = nil, *e3 = nil;
            __block int got = 0;
            void (^none)(const float *, NSUInteger) = ^(const float *x, NSUInteger n) { (void)x; (void)n; got++; };
            BOOL a = [[[TX500SSTVRadioSource alloc] initWithDeviceUID:nil] startDelivering:none finished:^{} error:&e1];
            BOOL b = [[[TX500SSTVRadioSource alloc] initWithDeviceUID:@"default"] startDelivering:none finished:^{} error:&e2];
            BOOL d = [[[TX500SSTVRadioSource alloc] initWithDeviceUID:@"no-such-input-uid"] startDelivering:none finished:^{} error:&e3];
            Check(!a && !b && e1.code == 20 && e2.code == 20 && [e1.localizedDescription containsString:@"default input"],
                  @"Radio input: with no input chosen (or \"default\"), it opens nothing and says the system's default input is never used");
            Check(!d && e3.code == 21 && got == 0, @"Radio input: an input that is not connected opens nothing, and says so (no block delivered)");
            NSError *e5a = nil, *e5b = nil;
            BOOL emptyUID = [[[TX500SSTVRadioSource alloc] initWithDeviceUID:@""] startDelivering:none finished:^{} error:&e5a];
            BOOL spaceUID = [[[TX500SSTVRadioSource alloc] initWithDeviceUID:@"  "] startDelivering:none finished:^{} error:&e5b];
            Check(!emptyUID && !spaceUID && e5a.code == 20 && e5b.code == 20,
                  @"Radio input: «» (what a saved profile holds with no input chosen) and spaces are no input: the message says so (N-seguretat-4)");
            TX500SSTVStationController *c3 = NewController(defs, [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-input"] isDirectory:YES], lb);
            c3.radioSourceFactory = ^id<TX500SSTVAudioSource> { return [[TX500SSTVRadioSource alloc] initWithDeviceUID:nil]; };
            NSError *e4 = nil;
            Check(![c3 setEnabled:YES error:&e4] && !c3.enabled && [c3.statusLabel.stringValue isEqualToString:@"Off"] &&
                  [c3.progressLabel.stringValue containsString:@"Station screen"],
                  @"Screen: with no radio input chosen, Listen stays Off and says where to choose it");
            SSTVManualRadio *idle = [SSTVManualRadio new];
            idle.name = @"TX-500 USB audio";
            c3.radioSourceFactory = ^id<TX500SSTVAudioSource> { return idle; };
            Check([c3 setEnabled:YES error:nil] && [c3.statusLabel.stringValue isEqualToString:@"Listening on: TX-500 USB audio"],
                  @"Screen: it says which input it listens to");

            // the input selector (decided 09-10): the radio's by default every session; another only by choice
            Check(c3.inputPopup.indexOfSelectedItem == 0 && [c3.inputPopup.titleOfSelectedItem hasPrefix:@"Radio receive input"] &&
                  [c3.inputNote.stringValue containsString:@"Good for:"],
                  @"Screen: the input is the radio's by default, with its Good for / Not good for");
            TX500SSTVStationController *c5 = NewController(defs, [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-inputs"] isDirectory:YES], lb);
            c5.inputDevices = @[@{@"uid": @"test-interface-uid", @"name": @"Test interface", @"builtIn": @NO, @"virtual": @NO},
                                @{@"uid": @"test-mic-uid", @"name": @"Test microphone", @"builtIn": @YES, @"virtual": @NO}];
            [c5 refreshInputs];
            [c5.inputPopup selectItemAtIndex:2];
            [c5.inputPopup sendAction:c5.inputPopup.action to:c5.inputPopup.target];
            c5.confirmBuiltInInput = ^BOOL(NSString *name) { (void)name; return YES; };   // confirmed: it then tries to open it
            NSError *e5 = nil;
            Check(c5.inputPopup.numberOfItems == 3 && [c5.inputPopup.titleOfSelectedItem containsString:@"(built in)"] &&
                  [c5.inputNote.stringValue containsString:@"hears the room"] && ![c5 setEnabled:YES error:&e5] && e5.code == 21 && !c5.enabled,
                  @"Screen: another input only when chosen; the built-in one says it hears the room (here it is not there, so nothing opens)");
            // two devices with the same name: each its own item, with its own uid (N-seguretat-11)
            c5.inputDevices = @[@{@"uid": @"usb-a", @"name": @"USB Audio CODEC", @"builtIn": @NO, @"virtual": @NO},
                                @{@"uid": @"usb-b", @"name": @"USB Audio CODEC", @"builtIn": @NO, @"virtual": @NO},
                                @{@"uid": @"mic", @"name": @"Test microphone", @"builtIn": @YES, @"virtual": @NO}];
            [c5 refreshInputs];
            [c5.inputPopup selectItemAtIndex:3];
            [c5.inputPopup sendAction:c5.inputPopup.action to:c5.inputPopup.target];
            Check(c5.inputPopup.numberOfItems == 4 && [[c5.inputPopup itemTitleAtIndex:2] isEqualToString:@"USB Audio CODEC (2)"] &&
                  [[c5.inputPopup itemAtIndex:2].representedObject isEqualToString:@"usb-b"] && [c5.inputPopup.titleOfSelectedItem containsString:@"(built in)"] &&
                  [c5.inputNote.stringValue containsString:@"hears the room"],
                  @"Screen: two inputs with the same name are two items, each with its own device; the built-in one is still the one that says it hears the room");
            // the lamp on an example volume (500 GB, 40 GB free), so that the output shows all its figures, never this Mac's own
            TX500SSTVRecordingStore.volumeBytesProvider = ^unsigned long long { return 500ULL * 1000 * 1000 * 1000; };
            TX500SSTVStationController *c6 = NewController(defs, [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-inputs2"] isDirectory:YES], lb);
            c6.recordings.freeBytesProvider = ^unsigned long long { return 40ULL * 1000 * 1000 * 1000; };
            TX500SSTVRecordingStore.volumeBytesProvider = nil;
            c6.inputDevices = c5.inputDevices; [c6 refreshInputs];
            Check(c6.inputPopup.indexOfSelectedItem == 0, @"Screen: the input choice is not kept: each session starts with the radio's");
            // the disk selector, and what is left always in sight
            [c6 refreshDiskSummary];
            NSString *lampText = c6.diskSummaryLabel.stringValue;
            Check(c6.diskPopup.indexOfSelectedItem == 2 && [lampText hasPrefix:@"● "] && [lampText containsString:@" · Recordings 1 % of disk (5,000 MB), limited to 4,000 MB ("] &&
                  [lampText containsString:@" · 4,000 MB free (100 %) · about 46 h left"],
                  [NSString stringWithFormat:@"Screen: the disk lamp, 1 %% by default: the %% of the share left, in MB and in hours (example volume: 500 GB, 40 GB free): %@", lampText]);
            // the thresholds (decided 09-10), each with its word
            NSString *st1 = nil, *st2 = nil, *st3 = nil, *st4 = nil, *st5 = nil;
            NSString *t1 = [TX500SSTVStationController diskLampTextForShare:0.01 wantBytes:5000000000ULL capBytes:5000000000ULL usedBytes:1000000000ULL state:&st1];
            NSString *t2 = [TX500SSTVStationController diskLampTextForShare:0.01 wantBytes:5000000000ULL capBytes:5000000000ULL usedBytes:3500000000ULL state:&st2];
            NSString *t3 = [TX500SSTVStationController diskLampTextForShare:0.01 wantBytes:5000000000ULL capBytes:5000000000ULL usedBytes:4800000000ULL state:&st3];
            NSString *t4 = [TX500SSTVStationController diskLampTextForShare:0 wantBytes:0 capBytes:0 usedBytes:0 state:&st4];
            NSString *t5 = [TX500SSTVStationController diskLampTextForShare:0.05 wantBytes:25000000000ULL capBytes:10000000000ULL usedBytes:0 state:&st5];
            // at the thresholds themselves (N-memoria-disc-9): 70.4 % free is over 70 %; 70 % and 69.6 % are not; 3 h exactly is not under 3 h
            NSString *sa = nil, *sb = nil, *sc = nil, *se = nil;
            NSString *ta = [TX500SSTVStationController diskLampTextForShare:0.01 wantBytes:5000000000ULL capBytes:5000000000ULL usedBytes:1480000000ULL state:&sa];
            [TX500SSTVStationController diskLampTextForShare:0.01 wantBytes:5000000000ULL capBytes:5000000000ULL usedBytes:1500000000ULL state:&sb];
            [TX500SSTVStationController diskLampTextForShare:0.01 wantBytes:5000000000ULL capBytes:5000000000ULL usedBytes:1520000000ULL state:&sc];
            [TX500SSTVStationController diskLampTextForShare:0.01 wantBytes:5000000000ULL capBytes:5000000000ULL usedBytes:5000000000ULL - 259200000ULL state:&se];
            Check([sa isEqualToString:@"ok"] && [ta containsString:@"(70 %)"] && [sb isEqualToString:@"filling"] && [sc isEqualToString:@"filling"] &&
                  [se isEqualToString:@"filling"],
                  @"Lamp: at the thresholds: 70.4 % free is green (shown as 70 %), 70 % and 69.6 % yellow; 3 h exactly is not red");
            Check([st1 isEqualToString:@"ok"] && [t1 isEqualToString:@"OK · Recordings 1 % of disk (5,000 MB) · 4,000 MB free (80 %) · about 46 h left"],
                  [NSString stringWithFormat:@"Lamp: more than 70 %% free: green, «OK»: %@", t1]);
            Check([st2 isEqualToString:@"filling"] && [t2 hasPrefix:@"Filling up · "] && [t2 containsString:@"(30 %) · about 17 h left"],
                  [NSString stringWithFormat:@"Lamp: 70 %% free or less with more than 3 h left: yellow, «Filling up»: %@", t2]);
            Check([st3 isEqualToString:@"low"] && [t3 hasPrefix:@"Less than 3 h left · "] && [t3 hasSuffix:@"about 2 h left"],
                  [NSString stringWithFormat:@"Lamp: less than 3 h of audio left: red, «Less than 3 h left»: %@", t3]);
            Check([st4 isEqualToString:@"off"] && [t4 isEqualToString:@"Off · nothing is saved on disk"], @"Lamp: Off: grey, «Off · nothing is saved on disk»");
            Check([st5 isEqualToString:@"ok"] && [t5 containsString:@"(25.0 GB), limited to 10.0 GB (a tenth of the free space plus the recordings) · 10.0 GB free (100 %)"],
                  [NSString stringWithFormat:@"Lamp: from 10 GB on, GB; the %% always; and the tenth-of-free limit said: %@", t5]);
            [c6.diskPopup selectItemAtIndex:0];
            [c6.diskPopup sendAction:c6.diskPopup.action to:c6.diskPopup.target];
            TX500SSTVStationController *c7 = NewController(defs, [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-inputs3"] isDirectory:YES], lb);
            Check([c6.diskSummaryLabel.stringValue isEqualToString:@"● Off · nothing is saved on disk"] && [c6.diskLampState isEqualToString:@"off"] &&
                  c6.recordings.diskShare == 0,
                  [NSString stringWithFormat:@"Screen: Off says so: %@", c6.diskSummaryLabel.stringValue]);
            Check(c7.diskPopup.indexOfSelectedItem == 0 && c7.recordings.diskShare == 0,
                  [NSString stringWithFormat:@"Screen: the disk choice is kept for the next session (it opens nothing): %ld, %g",
                   (long)c7.diskPopup.indexOfSelectedItem, c7.recordings.diskShare]);
            // a kept value that is not one of the list (7): the selector and the store both take the default, 1 % (N2-importants-nous-9)
            [defs setInteger:7 forKey:@"TX500SSTVDiskShare"];
            TX500SSTVStationController *c7b = NewController(defs, [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-inputs4"] isDirectory:YES], lb);
            Check([c7b.diskPopup.titleOfSelectedItem isEqualToString:@"1 % of the disk"] && c7b.recordings.diskShare == 0.01,
                  [NSString stringWithFormat:@"Screen: a kept disk value out of the list shows and works as the default, 1 %% of the disk: «%@», %g",
                   c7b.diskPopup.titleOfSelectedItem, c7b.recordings.diskShare]);
            [defs removeObjectForKey:@"TX500SSTVDiskShare"];

            // 7c. a setting changed while listening: the input goes on and the last minutes stay (DEC-2)
            TX500SSTVRecording *novis = [TX500SSTVRecording recordingFromWAVAtURL:Fixture(@"M1-novis.wav") error:nil];
            NSMutableData *quiet = [NSMutableData dataWithLength:12000 * 10 * 2];
            [idle play:quiet.bytes count:quiet.length / 2 from:[NSDate date]];
            double before7 = c3.engine.lastMinutes.duration;
            [c3.modePopup selectItemAtIndex:TX500SSTVModeMartin1];
            [c3.modePopup sendAction:c3.modePopup.action to:c3.modePopup.target];
            Check(c3.engine.running && c3.engine.source == idle && idle.stops == 0 && fabs(c3.engine.lastMinutes.duration - before7) < 0.01,
                  @"Screen: changing the mode while listening keeps the input open and the last minutes in memory (no restart)");
            NSUInteger pics0 = c3.pictures.count;
            [idle play:novis.samples.bytes count:novis.samples.length / 2 from:[NSDate date]];
            Check(!c3.engine.settingsWaiting && c3.pictures.count == pics0 + 1 && [c3.pictures.lastObject.modeKey isEqualToString:@"M1"],
                  @"Engine: the new mode applies from the next picture without a restart (Martin M1 by hand, no VIS: the picture comes)");
            [c3 discardQSO];
            // a picture being received goes on as it began; the new setting waits for its end
            TX500SSTVRecording *m1 = [TX500SSTVRecording recordingFromWAVAtURL:Fixture(@"M1.wav") error:nil];
            [c3.modePopup selectItemAtIndex:TX500SSTVModeAuto];
            [c3.modePopup sendAction:c3.modePopup.action to:c3.modePopup.target];
            [idle play:quiet.bytes count:12000 from:[NSDate date]];
            NSUInteger half = m1.samples.length / 4;
            [idle play:m1.samples.bytes count:half from:[NSDate date]];
            BOOL wasReceiving = c3.engine.receiving;
            [c3.scalePopup selectItemAtIndex:TX500SSTVColourScaleFull];
            [c3.scalePopup sendAction:c3.scalePopup.action to:c3.scalePopup.target];
            BOOL waited = c3.engine.settingsWaiting && [c3.progressLabel.stringValue containsString:@"next picture"];
            [idle play:(const int16_t *)m1.samples.bytes + half count:m1.samples.length / 2 - half from:[NSDate date]];
            Check(wasReceiving && waited && c3.pictures.count == pics0 + 2 && c3.pictures.lastObject.complete && !c3.engine.settingsWaiting,
                  @"Engine: a setting changed during a picture waits for its end; the picture goes on whole, and says so");
            [c3 discardQSO];
            // 7d. a source that was replaced cannot stop or feed the new run (DEC-3, SEG-13)
            void (^oldFinished)(void) = idle.finished, (^oldDeliver)(const float *, NSUInteger) = idle.deliver;
            SSTVManualRadio *second = [SSTVManualRadio new];
            Check([c3.engine startWithSource:second error:nil], @"Engine: a second source starts");
            double fed0 = c3.engine.lastMinutes.duration;
            float zeros[1200] = {0};
            oldDeliver(zeros, 1200);
            oldFinished();
            Check(c3.engine.running && c3.engine.source == second && fabs(c3.engine.lastMinutes.duration - fed0) < 1e-6,
                  @"Engine: the old source's late blocks and its end are ignored: the new run goes on");
            // a choice that waited for a picture's end does not outlive Listen: off (and on) the choices apply from the start (N2-importants-nous-7)
            c3.choiceWaiting = YES;
            [c3 setEnabled:NO error:nil];
            Check(!c3.choiceWaiting, @"Screen: turning Listen off forgets a choice that waited for a picture's end (the next picture never says it waits)");

            // 7e. the time: after a sleep of the Mac, a picture has the real time (DEC-10)
            TX500SSTVStationController *c4 = NewController(defs, [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-clock"] isDirectory:YES], lb);
            SSTVManualRadio *clock = [SSTVManualRadio new];
            c4.radioSourceFactory = ^id<TX500SSTVAudioSource> { return clock; };
            [c4 setEnabled:YES error:nil];
            NSDate *t0 = [NSDate dateWithTimeIntervalSinceNow:-7200];
            [clock play:quiet.bytes count:quiet.length / 2 from:t0];                     // 10 s, two hours ago
            NSDate *wake = [t0 dateByAddingTimeInterval:10 + 3600];                       // then an hour asleep
            [clock play:m1.samples.bytes count:m1.samples.length / 2 from:wake];
            TX500SSTVPicture *pic = c4.pictures.lastObject;
            double expect = (double)(m1.samples.length / 2) / 12000.0;                   // the picture ends at the end of the WAV
            Check(pic && fabs([pic.endUTC timeIntervalSinceDate:wake] - expect) < 0.3 && c4.draft &&
                  fabs([c4.draft.endUTC timeIntervalSinceDate:pic.endUTC]) < 0.01,
                  [NSString stringWithFormat:@"Clock: after an hour asleep the picture's time is the real one (%.1f s after waking), and so is the form's",
                   [pic.endUTC timeIntervalSinceDate:wake]]);
            TX500SSTVRecording *ring = c4.engine.lastMinutes;
            NSArray *again = ring ? [TX500SSTVRecordingStore decodeAgain:ring mode:TX500SSTVModeAuto colourScale:TX500SSTVColourScaleStudio
                                                         scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0] : @[];
            Check(again.count == 1 && ring.timeAnchors.count >= 2 && fabs([[again[0] endUTC] timeIntervalSinceDate:pic.endUTC]) < 0.1,
                  @"Clock: the last minutes keep the sleep inside them: decoded again, the picture has the same real time");

            // 7f. memory and folder: nothing piles up (DEC-4, SEG-4)
            Check(pic.recording == nil && pic.receptionIdentifier.length && [c4.recordings recordingForReception:c4.recordings.receptions.firstObject],
                  @"Memory: the picture lets its audio go; the store has it, found by the reception");
            [c4 discardQSO];
            c4.galleryInMemory = 3;
            NSURL *g4 = c4.galleryDirectory;
            BOOL radioPNG = pic.savedURL && [NSFileManager.defaultManager fileExistsAtPath:pic.savedURL.path] &&
                            [c4.recordings.receptions.firstObject.pictureNames containsObject:pic.savedURL.lastPathComponent] &&
                            c4.recordings.receptions.firstObject.pictureBytes > 0;
            for (int k = 0; k < 4; k++) [c4 decodeFileAtURL:Fixture(@"R36.wav") synchronously:YES error:nil];
            NSUInteger practicePNG = 0;
            for (NSURL *u in [NSFileManager.defaultManager contentsOfDirectoryAtURL:g4 includingPropertiesForKeys:nil options:0 error:nil])
                if ([u.lastPathComponent hasSuffix:@"-practice.png"]) practicePNG++;
            NSUInteger practiceOnDisk = 0, practiceInMemory = 0;
            for (TX500SSTVStoredReception *x in c4.recordings.receptions) if (x.fromFile) { practiceOnDisk += x.onDisk; practiceInMemory += x.inMemory; }
            Check(radioPNG && c4.pictures.count == 3 && practicePNG == 0 && practiceOnDisk == 0 && practiceInMemory == 1,
                  @"Gallery: 3 pictures in memory (the limit); a radio picture's PNG is kept with its reception, counted in the share; "
                  @"practice goes neither to the folder nor to the disk (memory only, one at a time)");
            TX500SSTVRecordingStore *st10 = [[TX500SSTVRecordingStore alloc] initWithDirectory:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"ten"] isDirectory:YES]];
            NSPointerArray *alive = [NSPointerArray weakObjectsPointerArray];
            @autoreleasepool {
                for (int k = 0; k < 10; k++) {
                    TX500SSTVRecording *r10 = [[TX500SSTVRecording alloc] initWithSamples:m1.samples sampleRate:12000 startTime:0];
                    [alive addPointer:(__bridge void *)r10];
                    [st10 addRecording:r10];
                }
            }
            NSUInteger live = 0;
            for (NSUInteger k = 0; k < alive.count; k++) if ([alive pointerAtIndex:k]) live++;
            Check(live <= 3, [NSString stringWithFormat:@"Memory: after 10 receptions, %lu audios are alive (at most 3)", (unsigned long)live]);
            [c4 setEnabled:NO error:nil];
        }

        // 8. the gallery and Export…
        TX500SSTVPicture *fromRadio = nil;
        for (TX500SSTVPicture *p in c.pictures) if (!p.fromFile && p.savedURL) fromRadio = p;
        Check(c.pictures.lastObject.fromFile && c.pictures.lastObject.savedURL == nil && fromRadio &&
              [NSFileManager.defaultManager fileExistsAtPath:fromRadio.savedURL.path],
              @"Screen: a radio picture is kept in the gallery folder; a practice one is not saved on its own (Export… saves it)");
        NSURL *exp = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"export.png"]];
        NSBitmapImageRep *rep = nil;
        if ([c exportPicture:c.pictures.lastObject toURL:exp error:&err]) rep = ReadPNG(exp);
        Check(rep && rep.pixelsWide == 320 && rep.pixelsHigh == 240 && SamePixels(c.pictures.lastObject, exp),
              @"Screen: Export… writes the picture as a PNG, the same pixels");

        // 8b. the recent receptions on the screen, as in the mockup
        {
            [c reloadRecordings];
            NSInteger rows = c.recordingsTable.numberOfRows;
            BOOL sizes = YES, statuses = YES;
            for (NSInteger k = 1; k < rows; k++) {
                sizes = sizes && ([[c textForRow:k column:@"audio"] hasSuffix:@"MB"] || [[c textForRow:k column:@"audio"] hasSuffix:@"(memory)"] ||
                                  [[c textForRow:k column:@"audio"] isEqualToString:@"gone"]);
                NSString *st = [c textForRow:k column:@"status"];
                statuses = statuses && ([st hasPrefix:@"received picture"] || [st isEqualToString:@"practice (file)"]) && ![st containsString:@"QSO"];
            }
            Check(rows == 1 + (NSInteger)c.recordings.receptions.count && [[c textForRow:0 column:@"mode"] isEqualToString:@"Last 5 minutes (no picture detected)"] &&
                  sizes && statuses,
                  @"Screen: the recent receptions: the last minutes first, then each one with its size and what it is («received picture», never «QSO»)");
            NSInteger loggedRow = -1, practiceRow = -1;
            for (NSInteger k = 1; k < rows; k++) {
                TX500SSTVStoredReception *x = [c receptionAtRow:k];
                if (x.logged && loggedRow < 0) loggedRow = k;
                if (x.fromFile && practiceRow < 0) practiceRow = k;
            }
            [c.recordingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)loggedRow] byExtendingSelection:NO];
            BOOL loggedOff = !c.recordRowButton.enabled && !c.discardRowButton.enabled && c.decodeAgainButton.enabled;
            [c.recordingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)practiceRow] byExtendingSelection:NO];
            BOOL practiceOff = !c.recordRowButton.enabled;
            // Keep on practice: off, and clicking it all the same writes nothing (N-memoria-disc-2)
            BOOL practiceKeepOff = !c.keepCheckbox.enabled;
            TX500SSTVStoredReception *prow = [c receptionAtRow:practiceRow];
            c.keepCheckbox.state = NSControlStateValueOn;
            [c.keepCheckbox sendAction:c.keepCheckbox.action to:c.keepCheckbox.target];
            BOOL practiceNotKept = prow && !prow.keep && !prow.onDisk &&
                                   ![NSFileManager.defaultManager fileExistsAtPath:[[c.recordings.directory URLByAppendingPathComponent:prow.identifier]
                                                                                     URLByAppendingPathExtension:@"wav"].path] &&
                                   [c.progressLabel.stringValue containsString:@"Export recording"];
            Check(practiceKeepOff && practiceNotKept,
                  @"Screen: Keep is off for a practice row, and pressing it all the same writes nothing (it says to use Export recording…)");
            [c.recordingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
            BOOL ringRow = !c.recordRowButton.enabled && !c.discardRowButton.enabled && c.keepCheckbox.enabled && c.decodeAgainButton.enabled &&
                           c.exportRecordingButton.enabled;
            Check(loggedRow > 0 && practiceRow > 0 && loggedOff && practiceOff && ringRow,
                  @"Screen: Record QSO… is off for a logged reception and for practice; the last minutes can be decoded again, exported or kept, never logged as they are");
            // the last minutes here hold the last M1 the test radio played, with its VIS: found again, it
            // joins the reception it already is (no new row)
            [c.againModePopup selectItemAtIndex:TX500SSTVModeAuto];
            NSUInteger before8 = c.pictures.count;
            NSInteger rows8 = c.recordingsTable.numberOfRows;
            [c.againGoButton performClick:nil];
            Check(c.pictures.count == before8 + 1 && c.recordingsTable.numberOfRows == rows8 &&
                  [c.reviewLabel.stringValue containsString:@"From the last minutes"],
                  @"Screen: Decode again on the last minutes finds the picture again and lists it with the reception it already is");
        }

        // 9. every option has its "Good for / Not good for", the default too, and the text follows the choice
        BOOL notesOK = YES;
        NSMutableSet *texts = [NSMutableSet set];
        for (NSInteger i = 0; i < c.modePopup.numberOfItems; i++) {
            [c.modePopup selectItemAtIndex:i];
            [c.modePopup sendAction:c.modePopup.action to:c.modePopup.target];
            NSString *t = c.modeNote.stringValue;
            notesOK = notesOK && [t containsString:@"Good for:"] && [t containsString:@"Not good for:"] &&
                      [t isEqualToString:[TX500SSTVOptionNotes noteForMode:(TX500SSTVModeChoice)i]];
            [texts addObject:t];
        }
        Check(notesOK && texts.count == (NSUInteger)c.modePopup.numberOfItems && c.modePopup.numberOfItems == 8,
              @"Screen: the 8 mode options (Auto too) each say Good for / Not good for, and the text changes with the choice");
        BOOL others = YES;
        for (NSInteger i = 0; i < c.scalePopup.numberOfItems; i++) {
            [c.scalePopup selectItemAtIndex:i];
            [c.scalePopup sendAction:c.scalePopup.action to:c.scalePopup.target];
            others = others && [c.scaleNote.stringValue containsString:@"Good for:"] && [c.scaleNote.stringValue containsString:@"Not good for:"];
        }
        for (NSInteger i = 0; i < c.layoutPopup.numberOfItems; i++) {
            [c.layoutPopup selectItemAtIndex:i];
            [c.layoutPopup sendAction:c.layoutPopup.action to:c.layoutPopup.target];
            others = others && [c.layoutNote.stringValue containsString:@"Good for:"] && [c.layoutNote.stringValue containsString:@"Not good for:"];
        }
        Check(others, @"Screen: the colour scale and Scottie timing options each say Good for / Not good for");
        [c.modePopup selectItemAtIndex:0];
        [c.modePopup sendAction:c.modePopup.action to:c.modePopup.target];

        // 9b. every choice on the screen (Decode again's and the fax part's too) has its own note with Good for /
        // Not good for, which follows that choice (N-proves-afirmacions-1, PRO-22). A screen of its own, with
        // defaults of its own: changing the disk share here touches nothing of the other tests
        {
            NSUserDefaults *defsN = [[NSUserDefaults alloc] initWithSuiteName:[suite stringByAppendingString:@".notes"]];
            TX500SSTVStationController *cn = NewController(defsN, [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-notes"] isDirectory:YES], lb);
            NSMutableArray<NSPopUpButton *> *all = [NSMutableArray array];
            NSMutableArray<NSView *> *todo = [NSMutableArray arrayWithObject:cn.view];
            while (todo.count) {
                NSView *v = todo.lastObject;
                [todo removeLastObject];
                if ([v isKindOfClass:NSPopUpButton.class]) [all addObject:(NSPopUpButton *)v];
                [todo addObjectsFromArray:v.subviews];
            }
            NSUInteger checked = 0;
            NSMutableArray<NSString *> *bad = [NSMutableArray array];
            for (NSPopUpButton *p in all) {
                if (p == cn.faxController.chartPopup) continue;           // the charts of the file: not a choice
                NSTextField *note = [cn noteForPopup:p];
                if (!note) { [bad addObject:p.titleOfSelectedItem ?: @"?"]; continue; }
                checked++;
                for (NSInteger i = 0; i < p.numberOfItems; i++) {
                    [p selectItemAtIndex:i];
                    if (p.action) [p sendAction:p.action to:p.target];
                    if (![note.stringValue containsString:@"Good for:"] || ![note.stringValue containsString:@"Not good for:"])
                        [bad addObject:[p itemTitleAtIndex:i]];
                }
            }
            Check(all.count == 14 && checked == 13 && bad.count == 0,                 // the fax tab has no sending choice (LAB-12)
                  [NSString stringWithFormat:@"Screen: all %lu choices on the screen (Decode again's and the fax part's too) have a note with Good for / Not good for for every option%@",
                   (unsigned long)checked, bad.count ? [@"; missing: " stringByAppendingString:[bad componentsJoinedByString:@", "]] : @""]);
            [cn.modePopup selectItemAtIndex:TX500SSTVModeAuto];
            [cn.modePopup sendAction:cn.modePopup.action to:cn.modePopup.target];
            [cn.againModePopup selectItemAtIndex:TX500SSTVModeMartin1];
            [cn.againModePopup sendAction:cn.againModePopup.action to:cn.againModePopup.target];
            [cn.againScalePopup selectItemAtIndex:TX500SSTVColourScaleFull];
            [cn.againScalePopup sendAction:cn.againScalePopup.action to:cn.againScalePopup.target];
            Check([cn.againModeNote.stringValue isEqualToString:[TX500SSTVOptionNotes noteForMode:TX500SSTVModeMartin1]] &&
                  [cn.modeNote.stringValue isEqualToString:[TX500SSTVOptionNotes noteForMode:TX500SSTVModeAuto]] &&
                  [cn.againScaleNote.stringValue isEqualToString:[TX500SSTVOptionNotes noteForColourScale:TX500SSTVColourScaleFull]],
                  @"Screen: Decode again's notes follow its own choices (Martin M1, Full range), not the ones above");
        }

        // 9c. the order of the SSTV screen: the disk share with the other choices, its lamp, then the two
        // pictures side by side, each with a title that says what it shows and its own buttons; the log form
        // and the gallery under them. Found through the stacks' arranged views, never by a fixed place
        {
            NSUserDefaults *defsO = [[NSUserDefaults alloc] initWithSuiteName:[suite stringByAppendingString:@".order"]];
            TX500SSTVStationController *co = NewController(defsO, [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-order"] isDirectory:YES], lb);
            NSMutableArray<NSString *> *wrong = [NSMutableArray array];
            NSStackView *pane = StackHoldingBoth(co.layoutPopup, co.pictureView);
            NSTextField *galleryTitle = LabelBeginning(co.view, @"Gallery (");
            NSUInteger iLayout = PlaceInStack(pane, co.layoutPopup), iLayoutNote = PlaceInStack(pane, co.layoutNote),
                       iDisk = PlaceInStack(pane, co.diskPopup), iDiskNote = PlaceInStack(pane, co.diskNote),
                       iLamp = PlaceInStack(pane, co.diskSummaryLabel), iLive = PlaceInStack(pane, co.pictureView),
                       iOffline = PlaceInStack(pane, co.reviewPictureView), iForm = PlaceInStack(pane, co.recordPanel),
                       iGallery = galleryTitle ? PlaceInStack(pane, galleryTitle) : NSNotFound;
            if (!pane || pane.orientation != NSUserInterfaceLayoutOrientationVertical) [wrong addObject:@"no SSTV column"];
            if (iLayout == NSNotFound || iDisk == NSNotFound || !(iLayout < iDisk)) [wrong addObject:@"Scottie timing not before the disk share"];
            // just below Scottie timing: its note, then the disk row, the disk note, the lamp and the pictures, one after the other
            if (iLayoutNote == NSNotFound || iDisk != iLayoutNote + 1) [wrong addObject:@"the disk share not right after the Scottie timing note"];
            if (iDisk == NSNotFound || iDiskNote != iDisk + 1) [wrong addObject:@"the disk note not right after the disk share"];
            if (iDiskNote == NSNotFound || iLamp != iDiskNote + 1) [wrong addObject:@"the lamp not right after the disk note"];
            if (iLamp == NSNotFound || iLive != iLamp + 1) [wrong addObject:@"the pictures not right after the lamp"];
            if (iOffline != iLive) [wrong addObject:@"the two pictures not in one row"];
            NSStackView *row = iLive != NSNotFound && [pane.arrangedSubviews[iLive] isKindOfClass:NSStackView.class] ? (NSStackView *)pane.arrangedSubviews[iLive] : nil;
            if (!row || row.orientation != NSUserInterfaceLayoutOrientationHorizontal || row.arrangedSubviews.count != 2)
                [wrong addObject:@"the pictures' row is not a horizontal row of two"];
            else {
                NSView *left = row.arrangedSubviews[0], *right = row.arrangedSubviews[1];
                if (!Holds(left, co.pictureView) || !LabelSaying(left, @"Live, from the radio"))
                    [wrong addObject:@"the first window is not the live one with its title"];
                if (!Holds(right, co.reviewPictureView) || !LabelSaying(right, @"Offline decoding (a WAV file or Decode again)"))
                    [wrong addObject:@"the second window is not the offline one with its title"];
                // each column begins with its title
                NSView *leftFirst = [left isKindOfClass:NSStackView.class] ? ((NSStackView *)left).arrangedSubviews.firstObject : nil;
                NSView *rightFirst = [right isKindOfClass:NSStackView.class] ? ((NSStackView *)right).arrangedSubviews.firstObject : nil;
                if (![leftFirst isKindOfClass:NSTextField.class] || ![((NSTextField *)leftFirst).stringValue isEqualToString:@"Live, from the radio"])
                    [wrong addObject:@"the live column does not begin with its title"];
                if (![rightFirst isKindOfClass:NSTextField.class] ||
                    ![((NSTextField *)rightFirst).stringValue isEqualToString:@"Offline decoding (a WAV file or Decode again)"])
                    [wrong addObject:@"the offline column does not begin with its title"];
                // each picture's own buttons under it: Export in the live one; Open WAV and Export in the offline one
                if (!Holds(left, co.exportButton) || Holds(right, co.exportButton)) [wrong addObject:@"the live Export not in the live column"];
                if (!Holds(right, co.openButton) || Holds(left, co.openButton)) [wrong addObject:@"Open WAV not in the offline column"];
                if (!Holds(right, co.reviewExportButton) || Holds(left, co.reviewExportButton))
                    [wrong addObject:@"the offline Export not in the offline column"];
            }
            if (iForm == NSNotFound || !(iLive < iForm)) [wrong addObject:@"the log form not under the pictures"];
            if (iGallery == NSNotFound || !(iLive < iGallery)) [wrong addObject:@"the gallery not under the pictures"];
            if (FaxViewSays(co.view, @"Files and Decode again")) [wrong addObject:@"the old title is still there"];
            if (![co.pictureView.accessibilityLabel isEqualToString:@"Live picture from the radio"] ||
                ![co.reviewPictureView.accessibilityLabel isEqualToString:@"Offline decoding picture"])
                [wrong addObject:@"a picture has no name for VoiceOver"];
            if (co.progressLabel.preferredMaxLayoutWidth != 480 || co.reviewLabel.preferredMaxLayoutWidth != 320 ||
                co.progressLabel.maximumNumberOfLines != 0 || co.reviewLabel.maximumNumberOfLines != 0 ||
                co.progressLabel.lineBreakMode != NSLineBreakByWordWrapping || co.reviewLabel.lineBreakMode != NSLineBreakByWordWrapping)
                [wrong addObject:@"a line under a picture does not wrap by words within its width, or is cut"];
            Check(wrong.count == 0, [NSString stringWithFormat:@"Screen: Scottie timing, the disk share and its lamp, then the live and offline pictures side by side "
                                     @"with their titles and names, the log form and the gallery under them%@",
                                     wrong.count ? [@"; wrong: " stringByAppendingString:[wrong componentsJoinedByString:@", "]] : @""]);
            [NSUserDefaults.standardUserDefaults removePersistentDomainForName:[suite stringByAppendingString:@".order"]];
        }

        // 9d. «Show pictures in Finder»: in the gallery's title row, it opens exactly the gallery folder, through
        // the test's own handler (never the Finder); off, and it says why, while that folder does not exist (it
        // never makes it); and Decode again on a row whose WAV was taken away says so and shows it gone
        {
            NSString *suiteF = [suite stringByAppendingString:@".finder"];
            NSUserDefaults *defsF = [[NSUserDefaults alloc] initWithSuiteName:suiteF];
            [defsF setInteger:0 forKey:@"TX500SSTVDiskShare"];                           // «Off»: nothing on disk, no folder
            NSURL *gOff = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-finder-off"] isDirectory:YES];
            TX500SSTVStationController *cf = NewController(defsF, gOff, lb);
            NSMutableArray<NSURL *> *opened = [NSMutableArray array];
            cf.revealFolderHandler = ^(NSURL *folder) { [opened addObject:folder]; };
            [cf activate];
            NSButton *show = cf.showPicturesButton;
            NSTextField *gTitle = LabelBeginning(cf.view, @"Gallery (");
            NSStackView *gRow = [show.superview isKindOfClass:NSStackView.class] ? (NSStackView *)show.superview : nil;
            Check(show && [show.title isEqualToString:@"Show pictures in Finder"] && gTitle && gRow &&
                  gRow.orientation == NSUserInterfaceLayoutOrientationHorizontal &&
                  [gRow.arrangedSubviews isEqualToArray:@[gTitle, show]],
                  @"Gallery: «Show pictures in Finder» is in the gallery's title row, right after its title");
            [NSApp sendAction:show.action to:show.target from:show];                       // even asked, with no folder
            Check(!show.enabled && [show.toolTip isEqualToString:@"Nothing saved yet"] && opened.count == 0 &&
                  ![NSFileManager.defaultManager fileExistsAtPath:gOff.path],
                  @"Gallery: with the disk Off and nothing saved, «Show pictures in Finder» is off and says «Nothing saved yet»; "
                  @"it opens nothing and never makes the folder");
            [NSUserDefaults.standardUserDefaults removePersistentDomainForName:suiteF];

            // the disk share on (the default): once a picture from the radio is written, it opens that folder
            NSString *suiteG = [suite stringByAppendingString:@".finder-on"];
            NSUserDefaults *defsG = [[NSUserDefaults alloc] initWithSuiteName:suiteG];
            NSURL *gOn = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-finder-on"] isDirectory:YES];
            TX500SSTVStationController *cg = NewController(defsG, gOn, lb);
            NSMutableArray<NSURL *> *openedG = [NSMutableArray array];
            cg.revealFolderHandler = ^(NSURL *folder) { [openedG addObject:folder]; };
            cg.radioSourceFactory = ^id<TX500SSTVAudioSource> {
                SSTVTestRadio *r = [SSTVTestRadio new];
                r.file = [[TX500SSTVFileSource alloc] initWithURL:Fixture(@"M1.wav") error:nil];
                return r;
            };
            [cg activate];
            BOOL offBefore = ![NSFileManager.defaultManager fileExistsAtPath:gOn.path] && !cg.showPicturesButton.enabled &&
                             [cg.showPicturesButton.toolTip isEqualToString:@"Nothing saved yet"];
            [cg setEnabled:YES error:nil];
            [cg setEnabled:NO error:nil];
            TX500SSTVPicture *radioPic = cg.pictures.lastObject;
            BOOL written = radioPic && !radioPic.fromFile && radioPic.savedURL &&
                           [NSFileManager.defaultManager fileExistsAtPath:radioPic.savedURL.path];
            Check(offBefore && written && cg.showPicturesButton.enabled && cg.showPicturesButton.toolTip == nil,
                  @"Gallery: with the disk share on and nothing received yet it is off; once a picture from the radio is written "
                  @"to the folder, «Show pictures in Finder» is on");
            [cg.showPicturesButton performClick:nil];
            Check(openedG.count == 1 && [openedG[0] isEqual:cg.galleryDirectory] && [openedG[0].path isEqualToString:gOn.path],
                  @"Gallery: «Show pictures in Finder» opens exactly the gallery folder, once (the test's own handler, never the Finder)");
            [cg discardQSO];

            // its WAV taken away by hand (moved, as in the Finder), and no copy left in memory: Decode again says so
            TX500SSTVStoredReception *gone = cg.recordings.receptions.firstObject;
            cg.recordings.memoryCount = 0;
            NSURL *wav = [cg.recordings.directory URLByAppendingPathComponent:[gone.identifier stringByAppendingString:@".wav"]];
            NSURL *away = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"moved-away.wav"]];
            [cg reloadRecordings];
            [cg.recordingsTable selectRowIndexes:[NSIndexSet indexSetWithIndex:1] byExtendingSelection:NO];
            BOOL movedAway = gone && !gone.inMemory && gone.onDisk && [NSFileManager.defaultManager moveItemAtURL:wav toURL:away error:nil];
            BOOL exportWasOn = cg.exportRecordingButton.enabled;                        // not refreshed yet: the row still looks kept
            NSUInteger picsBefore = cg.pictures.count;
            NSArray *againPics = [cg decodeAgainReception:gone mode:TX500SSTVModeAuto colourScale:TX500SSTVColourScaleStudio
                                            scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            NSString *said = @"Its audio is no longer in the folder.";
            Check(movedAway && againPics.count == 0 && cg.pictures.count == picsBefore &&
                  [cg.progressLabel.stringValue isEqualToString:said] && [cg.reviewLabel.stringValue isEqualToString:said],
                  @"Decode again: on a row whose WAV was taken away from the folder, it says «Its audio is no longer in the folder» "
                  @"(no empty decode)");
            Check(exportWasOn && !cg.exportRecordingButton.enabled && [[cg textForRow:1 column:@"audio"] isEqualToString:@"gone"],
                  @"Decode again: the list is read again, and that row shows its audio gone");
            [NSUserDefaults.standardUserDefaults removePersistentDomainForName:suiteG];

            // the folder made and taken away by hand, as in the Finder: showing the screen and reading the list
            // again turn the button on and off; a click after it has gone opens nothing and never makes it again
            NSString *suiteH = [suite stringByAppendingString:@".finder-hand"];
            NSUserDefaults *defsH = [[NSUserDefaults alloc] initWithSuiteName:suiteH];
            NSURL *gHand = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-finder-hand"] isDirectory:YES];
            NSURL *gHandAway = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-finder-hand-away"] isDirectory:YES];
            TX500SSTVStationController *ch = NewController(defsH, gHand, lb);
            NSMutableArray<NSURL *> *openedH = [NSMutableArray array];
            ch.revealFolderHandler = ^(NSURL *folder) { [openedH addObject:folder]; };
            [ch activate];
            BOOL offFirst = !ch.showPicturesButton.enabled;
            BOOL made = [NSFileManager.defaultManager createDirectoryAtURL:gHand withIntermediateDirectories:YES attributes:nil error:nil];
            [ch activate];
            BOOL onActivate = ch.showPicturesButton.enabled && ch.showPicturesButton.toolTip == nil;
            BOOL away1 = [NSFileManager.defaultManager moveItemAtURL:gHand toURL:gHandAway error:nil];
            [ch activate];
            BOOL offActivate = !ch.showPicturesButton.enabled && [ch.showPicturesButton.toolTip isEqualToString:@"Nothing saved yet"];
            BOOL back = [NSFileManager.defaultManager moveItemAtURL:gHandAway toURL:gHand error:nil];
            [ch reloadRecordings];
            BOOL onReload = ch.showPicturesButton.enabled && ch.showPicturesButton.toolTip == nil;
            BOOL away2 = [NSFileManager.defaultManager moveItemAtURL:gHand toURL:gHandAway error:nil];
            [ch reloadRecordings];
            BOOL offReload = !ch.showPicturesButton.enabled && [ch.showPicturesButton.toolTip isEqualToString:@"Nothing saved yet"];
            Check(offFirst && made && onActivate && away1 && offActivate && back && onReload && away2 && offReload,
                  @"Gallery: with the folder made and then taken away by hand, showing the screen and reading the list again "
                  @"turn «Show pictures in Finder» on and off");
            BOOL back2 = [NSFileManager.defaultManager moveItemAtURL:gHandAway toURL:gHand error:nil];
            [ch reloadRecordings];
            BOOL onAgain = ch.showPicturesButton.enabled;
            BOOL away3 = [NSFileManager.defaultManager moveItemAtURL:gHand toURL:gHandAway error:nil];
            [NSApp sendAction:ch.showPicturesButton.action to:ch.showPicturesButton.target from:ch.showPicturesButton];
            Check(back2 && onAgain && away3 && openedH.count == 0 && !ch.showPicturesButton.enabled &&
                  ![NSFileManager.defaultManager fileExistsAtPath:gHand.path],
                  @"Gallery: a click on «Show pictures in Finder» after its folder has gone opens nothing, turns it off, "
                  @"and never makes the folder");
            [NSUserDefaults.standardUserDefaults removePersistentDomainForName:suiteH];
        }

        // 9e. The X of the gallery. What it does depends on whether the picture has its PNG in the folder, never on
        // where it came from. With one: a question first (Cancel the default), then the test's own Trash (never the
        // Mac's), its name out of its reception, the bytes counted again, the list saved and the lamp refreshed; a
        // reception left with nothing leaves the table. Without one: out of the gallery only, no question, nothing on
        // disk changes. On screen: the offline view emptied, the live one kept, an open form told at once. The same
        // from the Delete key and from the thumbnail's menu; each thumbnail has a name for VoiceOver
        {
            NSFileManager *fm = NSFileManager.defaultManager;
            NSString *suiteX = [suite stringByAppendingString:@".trash"];
            NSUserDefaults *defsX = [[NSUserDefaults alloc] initWithSuiteName:suiteX];
            NSURL *gX = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"gallery-trash"] isDirectory:YES];
            NSURL *trash = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"Trash"] isDirectory:YES];
            [fm createDirectoryAtURL:trash withIntermediateDirectories:YES attributes:nil error:nil];
            TX500SSTVStationController *cx = NewController(defsX, gX, lb);
            NSMutableArray<NSString *> *asked = [NSMutableArray array];
            NSMutableArray<NSURL *> *trashed = [NSMutableArray array];          // where each PNG went in the test's Trash
            __block BOOL answer = NO, trashFails = NO;
            cx.confirmMoveToTrash = ^BOOL(NSString *text) { [asked addObject:text]; return answer; };
            // as the Trash does, a name already there gets a number
            cx.trashHandler = ^BOOL(NSURL *file, NSError **error) {
                if (trashFails) {
                    if (error) *error = [NSError errorWithDomain:@"SSTVTests" code:1 userInfo:@{NSLocalizedDescriptionKey: @"the test's Trash is full"}];
                    return NO;
                }
                NSURL *to = [trash URLByAppendingPathComponent:file.lastPathComponent];
                for (int k = 2; [fm fileExistsAtPath:to.path]; k++)
                    to = [trash URLByAppendingPathComponent:[NSString stringWithFormat:@"%@ %d.png", file.lastPathComponent.stringByDeletingPathExtension, k]];
                if (![fm moveItemAtURL:file toURL:to error:error]) return NO;
                [trashed addObject:to];
                return YES;
            };
            cx.radioSourceFactory = ^id<TX500SSTVAudioSource> {
                SSTVTestRadio *r = [SSTVTestRadio new];
                r.file = [[TX500SSTVFileSource alloc] initWithURL:Fixture(@"M1.wav") error:nil];
                return r;
            };
            NSEvent *enter = [NSEvent enterExitEventWithType:NSEventTypeMouseEntered location:NSZeroPoint modifierFlags:0 timestamp:0
                                                windowNumber:0 context:nil eventNumber:0 trackingNumber:0 userData:NULL];
            NSEvent *leave = [NSEvent enterExitEventWithType:NSEventTypeMouseExited location:NSZeroPoint modifierFlags:0 timestamp:0
                                                windowNumber:0 context:nil eventNumber:0 trackingNumber:0 userData:NULL];
            NSString *delKey = [NSString stringWithFormat:@"%C", (unichar)NSDeleteCharacter];
            NSEvent *del = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil
                                          characters:delKey charactersIgnoringModifiers:delKey isARepeat:NO keyCode:51];
            NSDateFormatter *hf = [NSDateFormatter new];
            hf.timeZone = [NSTimeZone timeZoneWithAbbreviation:@"UTC"]; hf.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            hf.dateFormat = @"HH:mm:ss";
            NSURL *recDir = nil;
            [cx activate];

            // a picture from the radio, with its PNG: shown live, and the form that logs it open
            [cx setEnabled:YES error:nil]; [cx setEnabled:NO error:nil];
            recDir = cx.recordings.directory;
            TX500SSTVPicture *pa = cx.pictures.lastObject;
            TX500SSTVStoredReception *ra = cx.recordings.receptions.firstObject;
            NSButton *ta = (NSButton *)cx.galleryStack.arrangedSubviews.lastObject;
            NSButton *xa = XOf(ta);
            NSURL *pngA = pa.savedURL;
            NSString *nameA = pngA.lastPathComponent ?: @"?";
            BOOL hidden0 = xa && xa.hidden;
            [ta mouseEntered:enter];
            BOOL shownOver = xa && !xa.hidden && [xa.toolTip isEqualToString:@"Move to Trash"] && [xa.accessibilityLabel isEqualToString:@"Move to Trash"];
            [ta mouseExited:leave];
            BOOL hiddenAfter = xa && xa.hidden;
            BOOL tracked = NO;
            for (NSTrackingArea *t in ta.trackingAreas) if (t.owner == ta && (t.options & NSTrackingMouseEnteredAndExited)) tracked = YES;
            NSString *labelA = [NSString stringWithFormat:@"Martin M1, from the radio, %@ UTC", [hf stringFromDate:pa.endUTC]];
            Check(pa && !pa.fromFile && pngA && [fm fileExistsAtPath:pngA.path] && cx.shownPicture == pa && cx.draft.picture == pa &&
                  [ra.pictureNames containsObject:nameA] && hidden0 && shownOver && hiddenAfter && tracked && [ta.accessibilityLabel isEqualToString:labelA],
                  @"Gallery: a thumbnail shows its X («Move to Trash» for a picture with its PNG) only while the pointer is over it, and has "
                  @"a name for VoiceOver: its mode, from the radio or practice, and its UTC time");
            // a plain button takes the focus only with Full Keyboard Access on (off by default): the thumbnail answers by itself
            BOOL ownFocus = [ta.class instanceMethodForSelector:@selector(acceptsFirstResponder)] != [NSButton instanceMethodForSelector:@selector(acceptsFirstResponder)] &&
                            [ta.class instanceMethodForSelector:@selector(canBecomeKeyView)] != [NSButton instanceMethodForSelector:@selector(canBecomeKeyView)];
            Check(ownFocus && ta.acceptsFirstResponder && ta.canBecomeKeyView && ta.accessibilityCustomActions.count == 1 &&
                  [ta.accessibilityCustomActions.firstObject.name isEqualToString:@"Move to Trash"],
                  @"Gallery: a thumbnail takes the keyboard's focus (by a click or by Tab) whatever Full Keyboard Access says, and "
                  @"VoiceOver finds the X's action on the thumbnail itself, «Move to Trash», as the X is hidden until the pointer is over it");

            // Cancel: nothing changes
            NSData *indexA = [NSData dataWithContentsOfURL:[recDir URLByAppendingPathComponent:@"index.json"]];
            unsigned long long bytesA = ra.pictureBytes;
            NSUInteger nPics = cx.pictures.count, nThumbs = cx.galleryStack.arrangedSubviews.count;
            answer = NO;
            [ta mouseEntered:enter];
            [xa performClick:nil];
            BOOL same = [fm fileExistsAtPath:pngA.path] && trashed.count == 0 && DiskSnapshot(trash).count == 0 &&
                        cx.pictures.count == nPics && [cx.pictures containsObject:pa] && cx.galleryStack.arrangedSubviews.count == nThumbs &&
                        [ra.pictureNames containsObject:nameA] && ra.pictureBytes == bytesA && bytesA > 0 && pa.savedURL != nil &&
                        indexA && [[NSData dataWithContentsOfURL:[recDir URLByAppendingPathComponent:@"index.json"]] isEqualToData:indexA] &&
                        cx.draftShowsPicture;
            Check(asked.count == 1 && [asked[0] containsString:nameA] && ![asked[0] containsString:@"Keep"] &&
                  ![asked[0] containsString:@"Recent receptions"] && same,
                  @"Gallery: the X on a picture with its PNG asks first (the PNG named; its reception keeps its audio, so no more is said); "
                  @"Cancel changes nothing: the PNG, the gallery, the reception and its list stay as they were");

            // the Trash fails: said on the progress line, nothing else changes
            answer = YES; trashFails = YES;
            [xa performClick:nil];
            trashFails = NO;
            Check(asked.count == 2 && [cx.progressLabel.stringValue containsString:@"could not be moved to the Trash"] &&
                  [cx.progressLabel.stringValue containsString:@"the test's Trash is full"] && [fm fileExistsAtPath:pngA.path] &&
                  [cx.pictures containsObject:pa] && cx.galleryStack.arrangedSubviews.count == nThumbs && [ra.pictureNames containsObject:nameA] &&
                  ra.pictureBytes == bytesA && [[NSData dataWithContentsOfURL:[recDir URLByAppendingPathComponent:@"index.json"]] isEqualToData:indexA] &&
                  trashed.count == 0,
                  @"Gallery: when the PNG cannot go to the Trash, the progress line says so, and nothing else changes");

            // the Delete key on the thumbnail, its recording marked Keep: yes moves the PNG to the test's Trash
            BOOL keptA = [cx.recordings setKeep:YES forReception:ra];
            NSImage *liveImage = cx.pictureView.image;
            unsigned long long usedA = cx.recordings.diskBytesUsed;
            cx.diskSummaryLabel.stringValue = @"(not refreshed)";
            NSUInteger askedA = asked.count;
            if (xa) [ta keyDown:del];                                   // only to a thumbnail with its X: a plain button would hand the key on
            NSURL *inTrashA = trashed.count == 1 ? trashed[0] : nil;
            NSDictionary *itemA = IndexItem(recDir, ra.identifier);
            unsigned long long sizeA = [[fm attributesOfItemAtPath:inTrashA.path error:nil][NSFileSize] unsignedLongLongValue];
            Check(keptA && asked.count == askedA + 1 && [asked.lastObject containsString:@"marked Keep"] &&
                  ![asked.lastObject containsString:@"Recent receptions"] &&
                  inTrashA && [inTrashA.lastPathComponent isEqualToString:nameA] && [fm fileExistsAtPath:inTrashA.path] &&
                  ![fm fileExistsAtPath:pngA.path] && ![cx.pictures containsObject:pa] &&
                  cx.galleryStack.arrangedSubviews.count == nThumbs - 1 && ta.superview == nil,
                  @"Gallery: the Delete key on a thumbnail does what its X does: asked (its recording is marked Keep, and it says so); yes moves "
                  @"the PNG to the test's Trash, out of the gallery folder, and the picture out of the gallery and its strip");
            Check(![ra.pictureNames containsObject:nameA] && ra.pictureBytes == 0 && bytesA > 0 && itemA &&
                  [itemA[@"pictures"] isKindOfClass:NSArray.class] && ![itemA[@"pictures"] containsObject:nameA] &&
                  [cx.recordings.receptions containsObject:ra],
                  @"Store: the picture's name leaves its reception, its pictures' bytes are counted again (0 now), index.json is written "
                  @"without it, and the reception keeps its row (its audio is still there)");
            Check(sizeA > 0 && usedA - cx.recordings.diskBytesUsed == sizeA && [cx.diskSummaryLabel.stringValue hasPrefix:@"● "],
                  @"Gallery: then the disk lamp is refreshed, with that PNG no longer counted");
            NSURL *expA = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"export-removed-live.png"]];
            Check(cx.shownPicture == pa && cx.pictureView.image == liveImage && cx.exportButton.enabled &&
                  [cx exportPicture:cx.shownPicture toURL:expA error:nil] && SamePixels(pa, expA) &&
                  [cx.progressLabel.stringValue hasPrefix:@"Removed from the gallery"] && [cx.progressLabel.stringValue containsString:@"Export"],
                  @"Gallery: taken out while shown live, the picture stays in the live view (the radio's last) and Export… still saves "
                  @"it from memory; the progress line says so");
            Check(cx.draft.reception == ra && !cx.draftShowsPicture && [cx.draftInfoLabel.stringValue containsString:@"no longer kept"],
                  @"Gallery: the open Record QSO form that logs that picture says at once that its picture is no longer kept");

            // shown on the right (Decode again), with its PNG: the thumbnail's menu
            NSArray<TX500SSTVPicture *> *again = [cx decodeAgainReception:ra mode:TX500SSTVModeAuto colourScale:TX500SSTVColourScaleStudio
                                                            scottieLayout:TX500SSTVScottieLayoutAuto fitSlant:YES slantPPM:0];
            TX500SSTVPicture *pc = again.firstObject;
            NSButton *tc = (NSButton *)cx.galleryStack.arrangedSubviews.lastObject;
            NSURL *pngC = pc.savedURL;
            NSString *nameC = pngC.lastPathComponent ?: @"?";
            BOOL offlineC = pc && cx.reviewPicture == pc && cx.reviewExportButton.enabled && pngC && [fm fileExistsAtPath:pngC.path] &&
                            cx.reviewPictureView.image.representations.count > 0;
            [tc.menu.delegate menuNeedsUpdate:tc.menu];
            NSString *menuC = tc.menu.itemArray.firstObject.title;
            NSUInteger askedC = asked.count, trashedC = trashed.count;
            answer = YES;
            if (tc.menu.numberOfItems) [tc.menu performActionForItemAtIndex:0];
            Check(offlineC && [menuC isEqualToString:@"Move to Trash"] && asked.count == askedC + 1 &&
                  trashed.count == trashedC + 1 && [fm fileExistsAtPath:trashed.lastObject.path] && ![fm fileExistsAtPath:pngC.path] &&
                  ![cx.pictures containsObject:pc] && ![ra.pictureNames containsObject:nameC] && [cx.recordings.receptions containsObject:ra],
                  @"Gallery: the thumbnail's menu says «Move to Trash» and does what its X does (asked; yes: the PNG in the test's Trash, "
                  @"its name out of the reception)");
            Check(cx.reviewPicture == nil && cx.reviewPictureView.image.representations.count == 0 && !cx.reviewExportButton.enabled &&
                  [cx.reviewLabel.stringValue hasPrefix:@"Removed from the gallery"],
                  @"Gallery: taken out while shown on the right, that view shows the empty placeholder, its Export is off, and its line "
                  @"says «Removed from the gallery»");

            // the last thing kept of a reception: no audio left (in memory or on disk) and no other picture
            [cx setEnabled:YES error:nil]; [cx setEnabled:NO error:nil];
            TX500SSTVPicture *pb = cx.pictures.lastObject;
            TX500SSTVStoredReception *rb = cx.recordings.receptions.firstObject;
            NSButton *tb = (NSButton *)cx.galleryStack.arrangedSubviews.lastObject;
            NSURL *pngB = pb.savedURL;
            NSString *nameB = pngB.lastPathComponent ?: @"?";
            cx.recordings.memoryCount = 0;
            NSURL *wavB = [recDir URLByAppendingPathComponent:[rb.identifier stringByAppendingString:@".wav"]];
            BOOL wavAway = [fm moveItemAtURL:wavB toURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"moved-away-x.wav"]] error:nil];
            [cx reloadRecordings];
            NSInteger rowsB = cx.recordingsTable.numberOfRows;
            BOOL listedB = rb != ra && [cx.recordings.receptions containsObject:rb] && IndexItem(recDir, rb.identifier) != nil;
            NSUInteger askedB = asked.count, trashedB = trashed.count;
            [tb mouseEntered:enter];
            [XOf(tb) performClick:nil];
            Check(wavAway && listedB && pngB && !rb.inMemory && asked.count == askedB + 1 && [asked.lastObject containsString:@"Recent receptions"] &&
                  ![asked.lastObject containsString:@"Keep"] && trashed.count == trashedB + 1 &&
                  [trashed.lastObject.lastPathComponent hasPrefix:nameB.stringByDeletingPathExtension] && [fm fileExistsAtPath:trashed.lastObject.path] &&
                  ![fm fileExistsAtPath:pngB.path] &&
                  ![cx.recordings.receptions containsObject:rb] && cx.recordingsTable.numberOfRows == rowsB - 1 &&
                  IndexItem(recDir, rb.identifier) == nil && [cx.recordings.receptions containsObject:ra],
                  @"Gallery: on the last thing kept of a reception (no audio, no other picture) the question says it would leave Recent "
                  @"receptions; with yes it leaves the table and index.json, and the other receptions stay");

            // with no PNG in the folder: a picture from the radio whose PNG was taken away by hand, and a practice one
            [cx setEnabled:YES error:nil]; [cx setEnabled:NO error:nil];
            TX500SSTVPicture *pd = cx.pictures.lastObject;
            TX500SSTVStoredReception *rd = cx.recordings.receptions.firstObject;
            NSButton *td = (NSButton *)cx.galleryStack.arrangedSubviews.lastObject;
            NSURL *pngD = pd.savedURL;
            NSString *nameD = pngD.lastPathComponent ?: @"?";
            BOOL pngAway = pngD && [fm moveItemAtURL:pngD toURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"moved-away-x.png"]] error:nil];
            [cx decodeFileAtURL:Fixture(@"R36.wav") synchronously:YES error:nil];
            TX500SSTVPicture *pp = cx.pictures.lastObject;
            NSButton *tp = (NSButton *)cx.galleryStack.arrangedSubviews.lastObject;
            NSString *labelP = [NSString stringWithFormat:@"%@, practice, %@ UTC", pp.modeName, [hf stringFromDate:pp.endUTC]];
            BOOL offlineP = pp.fromFile && !pp.savedURL && cx.reviewPicture == pp && [tp.accessibilityLabel isEqualToString:labelP] &&
                            [tp.accessibilityCustomActions.firstObject.name isEqualToString:@"Remove from the gallery"];
            NSArray<NSString *> *diskBefore = DiskSnapshot(gX), *trashBefore = DiskSnapshot(trash);
            NSUInteger askedD = asked.count, trashedD = trashed.count;
            [td.menu.delegate menuNeedsUpdate:td.menu];
            NSString *menuD = td.menu.itemArray.firstObject.title;
            [td mouseEntered:enter];
            NSString *xD = XOf(td).toolTip;
            [XOf(td) performClick:nil];
            BOOL liveD = ![cx.pictures containsObject:pd] && td.superview == nil && cx.shownPicture == pd && cx.exportButton.enabled &&
                         [cx.progressLabel.stringValue hasPrefix:@"Removed from the gallery."];
            if (XOf(tp)) [tp keyDown:del];
            BOOL offlineGone = ![cx.pictures containsObject:pp] && tp.superview == nil && cx.reviewPicture == nil && !cx.reviewExportButton.enabled &&
                               [cx.reviewLabel.stringValue isEqualToString:@"Removed from the gallery."];
            Check(pngAway && !pd.fromFile && pd.savedURL != nil && [menuD isEqualToString:@"Remove from the gallery"] &&
                  [xD isEqualToString:@"Remove from the gallery"] && offlineP && liveD && offlineGone && asked.count == askedD &&
                  trashed.count == trashedD,
                  @"Gallery: a picture with no PNG in the folder (one from the radio whose PNG was taken away, and a practice one) says "
                  @"«Remove from the gallery», and leaves it with no question (by its X and by the Delete key)");
            Check([DiskSnapshot(gX) isEqualToArray:diskBefore] && [DiskSnapshot(trash) isEqualToArray:trashBefore] && diskBefore.count > 0 &&
                  [rd.pictureNames containsObject:nameD] && [cx.recordings.receptions containsObject:rd],
                  @"Gallery: and nothing changes on disk: the gallery folder, the recordings, index.json and the test's Trash are as they were");

            // VoiceOver's action on a thumbnail does what its X does
            [cx setEnabled:YES error:nil]; [cx setEnabled:NO error:nil];
            TX500SSTVPicture *pv = cx.pictures.lastObject;
            NSButton *tv = (NSButton *)cx.galleryStack.arrangedSubviews.lastObject;
            NSURL *pngV = pv.savedURL;
            NSAccessibilityCustomAction *av = tv.accessibilityCustomActions.firstObject;
            NSUInteger askedV = asked.count, trashedV = trashed.count;
            answer = YES;
            BOOL sentV = av.handler && av.handler();
            Check(pngV && !pv.fromFile && [av.name isEqualToString:@"Move to Trash"] && sentV && asked.count == askedV + 1 &&
                  trashed.count == trashedV + 1 && [trashed.lastObject.lastPathComponent hasPrefix:pngV.lastPathComponent.stringByDeletingPathExtension] &&
                  [fm fileExistsAtPath:trashed.lastObject.path] && ![fm fileExistsAtPath:pngV.path] && ![cx.pictures containsObject:pv] &&
                  tv.superview == nil,
                  @"Gallery: the thumbnail's VoiceOver action does what its X does: asked once; yes: the PNG in the test's Trash, the "
                  @"picture out of the gallery and its strip");

            // a picture comes while the question is open (Listen stays on), and the gallery, full, lets its oldest go:
            // the asked picture, and only it, leaves; every thumbnail left still shows its own picture
            BOOL (^stripMatches)(void) = ^BOOL {
                NSArray<NSView *> *strip = cx.galleryStack.arrangedSubviews;
                NSArray<TX500SSTVPicture *> *pics = cx.pictures;
                BOOL m = strip.count == pics.count && pics.count > 0;
                for (NSUInteger i = 0; m && i < pics.count; i++) {
                    [(NSButton *)strip[i] performClick:nil];
                    m = cx.reviewPicture == pics[i];
                }
                return m;
            };
            __weak TX500SSTVStationController *weakX = cx;
            cx.confirmMoveToTrash = ^BOOL(NSString *text) {
                [asked addObject:text];
                [weakX decodeFileAtURL:Fixture(@"R36.wav") synchronously:YES error:nil];
                return YES;
            };
            cx.galleryInMemory = 2;
            [cx setEnabled:YES error:nil]; [cx setEnabled:NO error:nil];
            [cx setEnabled:YES error:nil]; [cx setEnabled:NO error:nil];
            TX500SSTVPicture *q1 = cx.pictures.firstObject, *q2 = cx.pictures.lastObject;
            NSButton *t2 = (NSButton *)cx.galleryStack.arrangedSubviews.lastObject;
            NSURL *png1 = q1.savedURL, *png2 = q2.savedURL;
            BOOL twoQ = cx.pictures.count == 2 && q1 != q2 && !q1.fromFile && !q2.fromFile && png1 && png2;
            NSUInteger askedQ = asked.count, trashedQ = trashed.count;
            [t2 mouseEntered:enter];
            [XOf(t2) performClick:nil];
            TX500SSTVPicture *came = cx.pictures.lastObject;
            Check(twoQ && asked.count == askedQ + 1 && came.fromFile && cx.pictures.count == 1 && ![cx.pictures containsObject:q2] &&
                  trashed.count == trashedQ + 1 && [trashed.lastObject.lastPathComponent hasPrefix:png2.lastPathComponent.stringByDeletingPathExtension] &&
                  ![fm fileExistsAtPath:png2.path] && [fm fileExistsAtPath:png1.path] && t2.superview == nil && stripMatches(),
                  @"Gallery: when a picture comes while the question is open and the full gallery lets its oldest go, yes takes out the "
                  @"asked picture and only it (its PNG in the test's Trash), and every thumbnail left still shows its own picture");

            // the asked picture is the oldest, and the gallery lets it go while the question is open: nothing is moved
            [cx setEnabled:YES error:nil]; [cx setEnabled:NO error:nil];
            [cx setEnabled:YES error:nil]; [cx setEnabled:NO error:nil];
            TX500SSTVPicture *q3 = cx.pictures.firstObject, *q4 = cx.pictures.lastObject;
            NSButton *t3 = (NSButton *)cx.galleryStack.arrangedSubviews.firstObject;
            NSURL *png3 = q3.savedURL;
            BOOL twoR = cx.pictures.count == 2 && !q3.fromFile && !q4.fromFile && png3;
            NSUInteger askedR = asked.count, trashedR = trashed.count;
            [t3 mouseEntered:enter];
            [XOf(t3) performClick:nil];
            Check(twoR && asked.count == askedR + 1 && trashed.count == trashedR && [fm fileExistsAtPath:png3.path] &&
                  ![cx.pictures containsObject:q3] && [cx.pictures containsObject:q4] && cx.pictures.count == 2 && cx.pictures.lastObject.fromFile &&
                  [cx.progressLabel.stringValue containsString:@"left the gallery while the question was open"] && stripMatches(),
                  @"Gallery: when the asked picture itself leaves the full gallery while the question is open, its PNG is not moved, the "
                  @"progress line says so, and the other pictures and their thumbnails stay as they are");
            [NSUserDefaults.standardUserDefaults removePersistentDomainForName:suiteX];
        }

        // 10. the fax, files only (FX1, FX2, FX4, FX30)
        {
            TX500FaxEngine *fe = [TX500FaxEngine new];
            for (NSString *fs in @[@"12000", @"8000", @"44100", @"48000"]) {
                NSError *fe1 = nil;
                BOOL okd = [fe decodeFileAtURL:Fixture([NSString stringWithFormat:@"FAX-%@.wav", fs]) error:&fe1];
                NSBitmapImageRep *ref = ReadPNG(Fixture([NSString stringWithFormat:@"FAX-%@-core/fax-00.png", fs]));
                TX500FaxChart *ch = fe.charts.firstObject;
                BOOL same = NO;
                if (okd && ch && ref && ref.pixelsWide == ch.width && ref.pixelsHigh == ch.height) {
                    same = YES;
                    const uint8_t *g = ch.gray.bytes;
                    for (NSInteger y = 0; y < ch.height && same; y++)
                        for (NSInteger x = 0; x < ch.width; x++) {
                            NSUInteger px[4] = {0};
                            [ref getPixel:px atX:x y:y];
                            if (px[0] != g[y * ch.width + x]) { same = NO; break; }
                        }
                }
                Check(okd && fe.charts.count == 1 && same && ch.width == 1810 && ch.height == 120,
                      [NSString stringWithFormat:@"Fax: a %@ Hz WAV gives the command line's chart, bit for bit (1810 points), with its 120 lines (%ld)",
                       fs, (long)ch.height]);
            }
            BOOL words = YES;
            for (NSString *n in @[@"phasing_unreliable", @"deviation_differs", @"no_lines", @"no_memory", @"inverted_white_first", @"polarity_undecided",
                                  @"inverted_undecided", @"dead_sector_elsewhere", @"fldigi_style", @"seam_margin", @"margin_unknown", @"incomplete",
                                  @"phasing_strict", @"lpm_mismatch", @"no_phasing_after_start", @"start_in_picture", @"ends_without_stop",
                                  @"start_without_picture", @"signal_lost", @"signal_back", @"closed_by_start", @"closed_by_phasing", @"line_limit",
                                  @"seam_confirms"])
                words = words && [TX500FaxEngine textForNote:n value:1 chosenDeviation:400 chosenLPM:120].length > 0;
            Check(words, @"Fax: every note of the receiver has its words in English for the screen");
            TX500FaxStationController *fx = c.faxController;
            // an SSTV form open before the fax, with a callsign typed in (N2-decisions-registre-4)
            c.radioSourceFactory = ^id<TX500SSTVAudioSource> {
                SSTVTestRadio *r = [SSTVTestRadio new];
                r.file = [[TX500SSTVFileSource alloc] initWithURL:Fixture(@"M1.wav") error:nil];
                return r;
            };
            [c discardQSO];
            [c.recordingsTable deselectAll:nil];          // no row of the last minutes selected while a picture comes (see 6e)
            [c setEnabled:YES error:nil]; [c setEnabled:NO error:nil];
            c.callField.stringValue = @"EP2AES";
            NSInteger nlog = lb.totalContactCount;
            TX500SSTVLogDraft *pend = c.draft;
            Check([fx decodeFileAtURL:Fixture(@"FAX-12000.wav") error:nil] && fx.engine.charts.count == 1 &&
                  [fx.practiceLabel.stringValue containsString:@"practice, never logged"] && [fx.infoLabel.stringValue containsString:@"margin from the phasing"] &&
                  fx.marginSlider.enabled && fx.exportButton.enabled,
                  [NSString stringWithFormat:@"Fax screen: Open WAV… shows the chart, says it is practice, and the margin can be moved: %@", fx.infoLabel.stringValue]);
            NSData *before10 = fx.engine.charts[0].gray;
            [fx setMarginPoints:45];
            Check(![fx.engine.charts[0].gray isEqualToData:before10] && [fx.marginLabel.stringValue isEqualToString:@"45 points"],
                  @"Fax screen: moving the margin after receiving redraws the chart from the samples it kept");
            [fx.lineStartPopup selectItemAtIndex:1];
            [fx.lineStartPopup sendAction:fx.lineStartPopup.action to:fx.lineStartPopup.target];
            Check([fx decodeAgain:nil] && [fx.infoLabel.stringValue containsString:@"fldigi's way"] && [fx.lineStartNote.stringValue containsString:@"fldigi"],
                  @"Fax screen: Decode again uses the same file with the line start chosen now (fldigi's)");
            [fx.lineStartPopup selectItemAtIndex:0];
            [fx.lineStartPopup sendAction:fx.lineStartPopup.action to:fx.lineStartPopup.target];
            BOOL closedByStart = NO;
            BOOL two = [fx decodeFileAtURL:Fixture(@"FAX-two.wav") error:nil];
            for (TX500FaxNotice *n in fx.engine.notices) if ([n.note isEqualToString:@"closed_by_start"]) closedByStart = YES;
            Check(two && fx.engine.charts.count == 2 && !fx.chartPopup.hidden && !fx.engine.charts[0].complete && fx.engine.charts[1].complete && closedByStart,
                  @"Fax screen: a chart with no stop is saved when the next one starts, and both can be shown");
            Check(lb.totalContactCount == nlog && pend != nil && c.draft == pend && [c.callField.stringValue isEqualToString:@"EP2AES"] &&
                  FaxViewSays(fx.view, @"send as") == 0 && FaxViewSays(fx.view, @"phase 3") == 0 && [TX500SSTVOptionNotes faxOptionsFor:@"sendAs"].count == 0,
                  @"Fax: a chart is no contact: nothing is logged, the SSTV form open before stays as it was (with what was typed in it), and the fax tab has no sending choice at all (no «Send as», no «phase 3»)");
            // N2-fax-app-12: at IOC 288 the width choice is off, and its note says why
            [fx.iocPopup selectItemAtIndex:1];
            [fx.iocPopup sendAction:fx.iocPopup.action to:fx.iocPopup.target];
            BOOL w288 = !fx.widthPopup.enabled && [fx.widthNote.stringValue containsString:@"IOC 576 only"];
            [fx.iocPopup selectItemAtIndex:0];
            [fx.iocPopup sendAction:fx.iocPopup.action to:fx.iocPopup.target];
            Check(w288 && fx.widthPopup.enabled && [fx.widthNote.stringValue containsString:@"Good for:"],
                  @"Fax screen: at IOC 288 the saved width is π × 288 and its choice is off, and the note says so; back at 576, it is on again");
            // N2-fax-app-14 and 16: «N lines»; the fax's lines reach the app's log, as the SSTV ones do
            __block NSUInteger faxLogged = 0;
            void (^oldLog)(NSString *) = c.logHandler;
            c.logHandler = ^(NSString *m) { if ([m hasPrefix:@"[Fax] "]) faxLogged++; };
            BOOL dec12 = [fx openFileAtURL:Fixture(@"FAX-12000.wav")];
            c.logHandler = oldLog;
            Check(dec12 && [fx.infoLabel.stringValue hasPrefix:@"120 lines · "] && faxLogged > 0 && fx.errorLabel.hidden,
                  [NSString stringWithFormat:@"Fax screen: the chart says «N lines», and its lines reach the app's log: %@", fx.infoLabel.stringValue]);
            // N2-fax-app-2, 13 and 17, SEG-15: two hostile WAVs (a frame size that is not channels × bytes, a rate of
            // 1 MHz): refused, in English, on the error line; the chart shown stays, and can still be exported
            NSMutableData *hb = [[NSData dataWithContentsOfURL:Fixture(@"FAX-12000.wav")] mutableCopy];
            NSUInteger fj = [hb rangeOfData:[@"fmt " dataUsingEncoding:NSASCIIStringEncoding] options:0 range:NSMakeRange(0, 64)].location;
            NSMutableData *hr = [hb mutableCopy];
            uint16_t badAlign = 1; uint32_t badRate = 1000000;
            [hb replaceBytesInRange:NSMakeRange(fj + 20, 2) withBytes:&badAlign];
            [hr replaceBytesInRange:NSMakeRange(fj + 12, 4) withBytes:&badRate];
            NSURL *hbU = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"hostile-frame.wav"]];
            NSURL *hrU = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"hostile-rate.wav"]];
            [hb writeToURL:hbU atomically:YES]; [hr writeToURL:hrU atomically:YES];
            NSData *shownGray = fx.engine.charts.firstObject.gray;
            BOOL refusedB = ![fx openFileAtURL:hbU];
            NSString *saidB = fx.errorLabel.stringValue;
            BOOL refusedR = ![fx openFileAtURL:hrU];
            NSString *saidR = fx.errorLabel.stringValue;
            NSURL *pngH = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"after-hostile.png"]];
            Check(refusedB && refusedR && !fx.errorLabel.hidden && [saidB containsString:@"hostile-frame.wav"] &&
                  [saidB containsString:@"a format this reader does not take"] && [saidR containsString:@"a format this reader does not take"] &&
                  fx.fileURL && [fx.fileURL.lastPathComponent isEqualToString:@"FAX-12000.wav"] &&
                  [fx.engine.charts.firstObject.gray isEqualToData:shownGray] && [fx exportShownToURL:pngH error:nil] &&
                  [fx.practiceLabel.stringValue containsString:@"FAX-12000.wav"],
                  [NSString stringWithFormat:@"Fax screen: two hostile WAVs are refused in English on the error line, and the chart shown stays and exports: %@ | %@", saidB, saidR]);
            Check([fx openFileAtURL:Fixture(@"FAX-12000.wav")] && fx.errorLabel.hidden, @"Fax screen: a good file again clears the error line");
            // the same two through the SSTV side: the reason in English too (the WAV reader's own words are Catalan)
            NSError *eS = nil, *eR = nil;
            BOOL sstvRefused = [[TX500SSTVFileSource alloc] initWithURL:hbU error:&eS] == nil &&
                               [eS.localizedDescription containsString:@"a format this reader does not take"];
            BOOL recRefused = [TX500SSTVRecording recordingFromWAVAtURL:hrU error:&eR] == nil &&
                              [eR.localizedDescription containsString:@"a format this reader does not take"];
            Check(sstvRefused && recRefused, [NSString stringWithFormat:@"SSTV: a hostile WAV is refused with the reason in English: %@ | %@",
                                              eS.localizedDescription, eR.localizedDescription]);
            BOOL faxNotes = YES;
            NSArray *pops = @[fx.deviationPopup, fx.lpmPopup, fx.iocPopup, fx.widthPopup, fx.lineStartPopup];
            NSArray *notes10 = @[fx.deviationNote, fx.lpmNote, fx.iocNote, fx.widthNote, fx.lineStartNote];
            for (NSUInteger k = 0; k < pops.count; k++) {
                NSPopUpButton *pp = pops[k];
                NSMutableSet *seen = [NSMutableSet set];
                for (NSInteger i = 0; i < pp.numberOfItems; i++) {
                    [pp selectItemAtIndex:i];
                    [pp sendAction:pp.action to:pp.target];
                    NSString *t = ((NSTextField *)notes10[k]).stringValue;
                    faxNotes = faxNotes && [t containsString:@"Good for:"] && [t containsString:@"Not good for:"];
                    [seen addObject:t];
                }
                faxNotes = faxNotes && seen.count == (NSUInteger)pp.numberOfItems;
                [pp selectItemAtIndex:0];
                [pp sendAction:pp.action to:pp.target];
            }
            Check(faxNotes, @"Fax screen: every option says Good for / Not good for, the default too, and the text follows the choice");
            // the order of the fax screen: the chart on the left under its title, its own buttons in one row under
            // it; the options on the right, and Decode again under them (it applies them). Found through the
            // stacks' arranged views, never by a fixed place (the chart list may be hidden, and so detached)
            {
                NSMutableArray<NSString *> *wrongF = [NSMutableArray array];
                NSStackView *rootF = [fx.view isKindOfClass:NSStackView.class] ? (NSStackView *)fx.view : nil;
                NSView *leftV = ArrangedHolding(rootF, fx.pictureView), *rightV = ArrangedHolding(rootF, fx.deviationPopup);
                NSStackView *leftF = [leftV isKindOfClass:NSStackView.class] ? (NSStackView *)leftV : nil;
                NSStackView *rightF = [rightV isKindOfClass:NSStackView.class] ? (NSStackView *)rightV : nil;
                if (!rootF || rootF.orientation != NSUserInterfaceLayoutOrientationHorizontal || !leftF || !rightF || leftF == rightF ||
                    leftF.orientation != NSUserInterfaceLayoutOrientationVertical || rightF.orientation != NSUserInterfaceLayoutOrientationVertical ||
                    [rootF.arrangedSubviews indexOfObject:leftF] > [rootF.arrangedSubviews indexOfObject:rightF])
                    [wrongF addObject:@"not a chart column on the left and an options column on the right"];
                else {
                    NSView *firstF = leftF.arrangedSubviews.firstObject;
                    NSTextField *titleF = [firstF isKindOfClass:NSTextField.class] ? (NSTextField *)firstF : nil;
                    if (![titleF.stringValue isEqualToString:@"Offline decoding (a WAV file)"])
                        [wrongF addObject:@"the chart column does not begin with its title"];
                    else if (titleF.font.pointSize != 13 || ![titleF.font.fontName isEqualToString:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold].fontName])
                        [wrongF addObject:@"the title is not semibold 13 points"];
                    NSUInteger iChart = PlaceInStack(leftF, fx.pictureView), iOpen = PlaceInStack(leftF, fx.openButton),
                               iExport = PlaceInStack(leftF, fx.exportButton), iList = PlaceInStack(leftF, fx.chartPopup),
                               iMargin = PlaceInStack(leftF, fx.marginSlider), iPractice = PlaceInStack(leftF, fx.practiceLabel);
                    BOOL w604 = NO, h400 = NO;
                    for (NSLayoutConstraint *k in fx.pictureView.constraints)
                        if (k.active && k.firstItem == fx.pictureView && !k.secondItem && k.relation == NSLayoutRelationEqual) {
                            if (k.firstAttribute == NSLayoutAttributeWidth && k.constant == 604) w604 = YES;
                            if (k.firstAttribute == NSLayoutAttributeHeight && k.constant == 400) h400 = YES;
                        }
                    if (!w604 || !h400) [wrongF addObject:@"the chart is not 604 by 400"];
                    if (iPractice == NSNotFound || iChart == NSNotFound || !(iPractice < iChart)) [wrongF addObject:@"the practice line not above the chart"];
                    if (iOpen == NSNotFound || iChart == NSNotFound || !(iChart < iOpen)) [wrongF addObject:@"Open WAV not under the chart"];
                    if (iExport != iOpen || iList != iOpen) [wrongF addObject:@"Open WAV, Export and the chart list not in one row"];
                    if (iMargin == NSNotFound || iOpen == NSNotFound || !(iOpen < iMargin)) [wrongF addObject:@"the margin not under the buttons' row"];
                    if (Holds(leftF, fx.againButton)) [wrongF addObject:@"Decode again still with the chart"];
                    NSUInteger iNote = PlaceInStack(rightF, fx.lineStartNote), iAgain = PlaceInStack(rightF, fx.againButton);
                    if (iNote == NSNotFound || iAgain == NSNotFound || !(iNote < iAgain)) [wrongF addObject:@"Decode again not under the Line start note"];
                    for (NSPopUpButton *pf in @[fx.deviationPopup, fx.lpmPopup, fx.iocPopup, fx.widthPopup, fx.lineStartPopup])
                        if (!Holds(rightF, pf) || Holds(leftF, pf)) { [wrongF addObject:@"an option not in the right column"]; break; }
                    for (NSTextField *nf in notes10)
                        if (!Holds(rightF, nf) || Holds(leftF, nf)) { [wrongF addObject:@"an option's note not in the right column"]; break; }
                }
                Check(wrongF.count == 0, [NSString stringWithFormat:@"Fax screen: the chart under its title «Offline decoding (a WAV file)», Open WAV, Export and the chart list "
                                          @"in one row under it; the options on the right, with Decode again under the last note%@",
                                          wrongF.count ? [@"; wrong: " stringByAppendingString:[wrongF componentsJoinedByString:@", "]] : @""]);
            }
            c.paneSwitch.selectedSegment = 1;
            [c.paneSwitch sendAction:c.paneSwitch.action to:c.paneSwitch.target];
            BOOL faxShown = !fx.view.hidden;
            c.paneSwitch.selectedSegment = 0;
            [c.paneSwitch sendAction:c.paneSwitch.action to:c.paneSwitch.target];
            Check(faxShown && fx.view.hidden, @"Screen: the switch shows the fax part or the SSTV part (one sidebar entry)");
            BOOL allSaid = YES;
            for (NSInteger k = TX500SSTVNoticeVIS; k <= TX500SSTVNoticeNoRows; k++)
                if ([TX500SSTVEngine textForKind:(TX500SSTVNoticeKind)k mode:@"Martin M1" vis:44 offset:0].length == 0) allSaid = NO;
            Check(allSaid && [[TX500SSTVEngine textForKind:TX500SSTVNoticeSlantNominal mode:@"Martin M1" vis:44 offset:0] containsString:@"line period"],
                  @"Notices: every notice of the receiver has its words on the screen, the new one too (the slant fit fell back to the mode's period)");
        }

        // 10b. this session's charts: a strip of every chart decoded, from every file opened, each held by the
        // strip itself (an earlier file's charts are no longer in the engine); the margin moves only on the open
        // file's charts (the receiver lets the samples go at the next file); and nothing piles up past the cap
        {
            TX500FaxStationController *fs = [TX500FaxStationController new];
            BOOL openA = [fs openFileAtURL:Fixture(@"FAX-12000.wav")];
            TX500FaxChart *chartA = fs.engine.charts.firstObject;
            NSData *grayA = chartA.gray;
            BOOL openB = [fs openFileAtURL:Fixture(@"FAX-two.wav")];
            NSArray<TX500FaxChart *> *chartsB = fs.engine.charts;
            NSArray<NSButton *> *thumbs = StripButtons(fs);
            NSArray<TX500FaxChart *> *strip = fs.sessionCharts;
            BOOL threeIn = openA && openB && chartA && chartsB.count == 2 && strip.count == 3 && thumbs.count == 3 &&
                           strip[0] == chartA && strip[1] == chartsB[0] && strip[2] == chartsB[1] && ![chartA.gray isEqualToData:chartsB[0].gray];
            Check(threeIn && fs.galleryInMemory == 12 && fs.displayedChart == chartsB[0] && fs.marginSlider.enabled && fs.marginNote.hidden &&
                  NSEqualSizes(thumbs[0].image.size, NSMakeSize(90, 60)) &&
                  [thumbs[0].accessibilityLabel isEqualToString:@"Chart 1 of FAX-12000.wav, 120 lines"] &&
                  [thumbs[1].accessibilityLabel isEqualToString:[NSString stringWithFormat:@"Chart 1 of FAX-two.wav, %ld lines", (long)chartsB[0].height]] &&
                  [thumbs[2].accessibilityLabel isEqualToString:[NSString stringWithFormat:@"Chart 2 of FAX-two.wav, %ld lines", (long)chartsB[1].height]],
                  [NSString stringWithFormat:@"Fax screen: this session's charts in a strip, newest last, from both files opened (12 at most), each a small "
                   @"picture with its name for VoiceOver (%@)", thumbs.count ? thumbs[0].accessibilityLabel : @"no thumbnail"]);
            {
                NSStackView *rootS = [fs.view isKindOfClass:NSStackView.class] ? (NSStackView *)fs.view : nil;
                NSView *leftS = ArrangedHolding(rootS, fs.pictureView), *rightS = ArrangedHolding(rootS, fs.deviationPopup);
                NSStackView *leftSt = [leftS isKindOfClass:NSStackView.class] ? (NSStackView *)leftS : nil;
                NSUInteger iStrip = PlaceInStack(leftSt, fs.sessionStrip), iNotices = PlaceInStack(leftSt, fs.noticeLabel);
                NSView *above = (iStrip != NSNotFound && iStrip > 0) ? leftSt.arrangedSubviews[iStrip - 1] : nil;
                Check(leftSt && iStrip != NSNotFound && iNotices != NSNotFound && iNotices < iStrip && !Holds(rightS, fs.sessionStrip) &&
                      [above isKindOfClass:NSTextField.class] && [((NSTextField *)above).stringValue isEqualToString:@"This session's charts"] &&
                      PlaceInStack(leftSt, fs.marginNote) == PlaceInStack(leftSt, fs.marginSlider) + 1,
                      @"Fax screen: the strip «This session's charts» under the chart's column, and the margin's line right under the margin");
            }
            // a chart of the earlier file, picked in the strip
            if (thumbs.count == 3) [thumbs[0] performClick:nil];
            NSURL *pngA = [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"session-chart-A.png"]];
            BOOL exportedA = [fs exportShownToURL:pngA error:nil];
            Check(threeIn && fs.displayedChart == chartA && fs.shownChart == -1 && !fs.marginSlider.enabled && !fs.marginNote.hidden &&
                  [fs.marginNote.stringValue isEqualToString:@"The margin can be moved only on the charts of the file open now."] &&
                  NSEqualSizes(fs.pictureView.image.size, NSMakeSize(chartA.width, chartA.height)) &&
                  fs.exportButton.enabled && exportedA && PNGIsChart(pngA, chartA) && fs.chartPopup.indexOfSelectedItem == -1 &&
                  [fs.fileURL.lastPathComponent isEqualToString:@"FAX-two.wav"],
                  @"Fax screen: a chart of the earlier file, picked in the strip, is shown and Export… writes its own picture; its margin control is off, "
                  @"with the line that says why; the open file is still the second, and the list shows none of its charts");
            NSString *nameA = fs.exportName;
            if (thumbs.count == 3) [thumbs[2] performClick:nil];
            NSString *nameB2 = fs.exportName;
            if (thumbs.count == 3) [thumbs[0] performClick:nil];
            Check(threeIn && [nameA isEqualToString:@"FAX-12000-chart-1.png"] && [nameB2 isEqualToString:@"FAX-two-chart-2.png"] && fs.displayedChart == chartA,
                  [NSString stringWithFormat:@"Fax screen: Export… proposes the name of the file the chart shown came from, and its number there (%@, %@)", nameA, nameB2]);
            NSArray<NSData *> *graysB = threeIn ? @[chartsB[0].gray, chartsB[1].gray] : @[];
            [fs setMarginPoints:45];
            NSArray<TX500FaxChart *> *chartsB2 = fs.engine.charts;
            Check(threeIn && chartsB2.count == 2 && chartsB2[0] == chartsB[0] && chartsB2[1] == chartsB[1] &&
                  [chartsB2[0].gray isEqualToData:graysB[0]] && [chartsB2[1].gray isEqualToData:graysB[1]] &&
                  fs.displayedChart == chartA && [chartA.gray isEqualToData:grayA] && fs.sessionCharts[0] == chartA &&
                  [fs.marginLabel.stringValue isEqualToString:@"0 points"],
                  @"Fax screen: moving the margin with the earlier file's chart shown changes no chart of the file open now, nor the chart shown");
            // a chart of the file open now, picked in the strip: its margin moves, on that chart only
            if (thumbs.count == 3) [thumbs[2] performClick:nil];
            BOOL shownB = threeIn && fs.displayedChart == chartsB[1] && fs.shownChart == 1 && fs.marginSlider.enabled && fs.marginNote.hidden && fs.chartPopup.indexOfSelectedItem == 1;
            [fs setMarginPoints:30];
            TX500FaxChart *movedB = fs.engine.charts.count == 2 ? fs.engine.charts[1] : nil;
            Check(shownB && movedB && movedB != chartsB[1] && ![movedB.gray isEqualToData:graysB[1]] && fs.displayedChart == movedB &&
                  fs.sessionCharts.count == 3 && fs.sessionCharts[2] == movedB && [fs.marginLabel.stringValue isEqualToString:@"30 points"] &&
                  [fs.engine.charts[0].gray isEqualToData:graysB[0]] && [chartA.gray isEqualToData:grayA],
                  @"Fax screen: a chart of the file open now, picked in the strip, keeps its margin control; the margin moves on that chart only, and the strip holds it as moved");
            // the list and the strip show the same chart
            if (thumbs.count == 3) [thumbs[0] performClick:nil];
            [fs.chartPopup selectItemAtIndex:0];
            [fs.chartPopup sendAction:fs.chartPopup.action to:fs.chartPopup.target];
            BOOL listFirst = threeIn && fs.sessionCharts.count == 3 && fs.displayedChart == chartsB[0] && fs.sessionCharts[1] == fs.displayedChart &&
                             fs.marginSlider.enabled && fs.marginNote.hidden;
            if (thumbs.count == 3) [thumbs[2] performClick:nil];
            BOOL stripSecond = fs.displayedChart == movedB && fs.chartPopup.indexOfSelectedItem == 1;
            Check(threeIn && listFirst && stripSecond, @"Fax screen: the chart list (the open file's charts) and the strip show the same chart");
            // Decode again, with the earlier file's chart shown: the file open now, as before
            if (thumbs.count == 3) [thumbs[0] performClick:nil];
            BOOL again = [fs decodeAgain:nil];
            NSArray<TX500FaxChart *> *chartsB3 = fs.engine.charts;
            BOOL againShown = again && chartsB3.count == 2 && fs.displayedChart == chartsB3[0] && fs.marginSlider.enabled &&
                              [fs.fileURL.lastPathComponent isEqualToString:@"FAX-two.wav"] && fs.sessionCharts.count == 5 && fs.sessionCharts[0] == chartA;
            if (thumbs.count == 3) [thumbs[2] performClick:nil];
            Check(againShown && fs.displayedChart == movedB && !fs.marginSlider.enabled && !fs.marginNote.hidden,
                  @"Fax screen: Decode again decodes the file open now, also with an earlier file's chart shown; the charts of the decode before stay in the strip, without their margin control");
            // the chart list, unchanged: hidden for a file of one chart
            Check([fs openFileAtURL:Fixture(@"FAX-12000.wav")] && fs.chartPopup.hidden && fs.chartPopup.numberOfItems == 1 &&
                  fs.displayedChart == fs.engine.charts.firstObject && fs.sessionCharts.count == 6,
                  @"Fax screen: with a file of one chart the list is hidden again, and the strip goes on");
            // a cap lowered takes effect at once: the oldest leave, the newest stay
            NSArray<TX500FaxChart *> *before = fs.sessionCharts;
            fs.galleryInMemory = 2;
            Check(before.count == 6 && fs.sessionCharts.count == 2 && StripButtons(fs).count == 2 &&
                  fs.sessionCharts[0] == before[4] && fs.sessionCharts[1] == before[5] && fs.displayedChart == before[5],
                  @"Fax screen: the strip's cap lowered takes effect at once, the oldest charts leaving first");
            // memory: 20 small files with a strip of 3; only those 3 charts stay alive (and the open file's)
            TX500FaxStationController *fm = [TX500FaxStationController new];
            fm.galleryInMemory = 3;
            NSPointerArray *aliveF = [NSPointerArray weakObjectsPointerArray];
            NSArray<NSString *> *small = @[@"FAX-8000.wav", @"FAX-12000.wav", @"FAX-two.wav"];
            NSUInteger openedF = 0;
            for (NSUInteger k = 0; k < 20; k++) {
                @autoreleasepool {
                    if ([fm openFileAtURL:Fixture(small[k % small.count])]) openedF++;
                    for (TX500FaxChart *ch in fm.engine.charts) [aliveF addPointer:(__bridge void *)ch];
                }
            }
            NSUInteger liveF = 0, openOutside = 0;
            for (NSUInteger i = 0; i < aliveF.count; i++) if ([aliveF pointerAtIndex:i]) liveF++;
            for (TX500FaxChart *ch in fm.engine.charts) if ([fm.sessionCharts indexOfObjectIdenticalTo:ch] == NSNotFound) openOutside++;
            Check(openedF == 20 && aliveF.count >= 20 && fm.sessionCharts.count == 3 && StripButtons(fm).count == 3 && liveF <= 3 + openOutside,
                  [NSString stringWithFormat:@"Fax screen: 20 small files opened with a strip of 3: only %lu of their %lu charts are still in memory "
                   @"(the strip keeps 3, plus the open file's not in it: %lu)", (unsigned long)liveF, (unsigned long)aliveF.count, (unsigned long)openOutside]);
        }

        [NSUserDefaults.standardUserDefaults removePersistentDomainForName:suite];
        if (failures) { fprintf(stderr, "%d FAILED\n", failures); return 1; }
        NSLog(@"ALL SSTV STATION TESTS PASSED");
        return 0;
    }
}
