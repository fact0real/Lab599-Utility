#import <Cocoa/Cocoa.h>
#import "TX500SSTVStationController.h"
#import "TX500FaxStationController.h"

@interface TX500SSTVStationController (GalleryTests)
- (void)keepInGallery:(TX500SSTVPicture *)picture;
@end
@interface TX500FaxStationController (GalleryTests)
- (void)addToStrip:(TX500FaxChart *)chart;
- (void)showChart:(TX500FaxChart *)chart;
@end

static NSUInteger checks;
static void Check(BOOL ok, NSString *message) {
    checks++;
    if (!ok) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
@interface ReviewLiveSource : NSObject <TX500SSTVAudioSource>
@property (atomic,copy) NSString *inputFailure;
@property (copy) void (^finished)(void);
@end
@implementation ReviewLiveSource
- (double)sampleRate { return 12000; }
- (BOOL)isLive { return YES; }
- (NSString *)sourceName { return @"Synthetic USB audio"; }
- (BOOL)startDelivering:(void (^)(const float *,NSUInteger))deliver finished:(void (^)(void))finished error:(NSError **)error {
    (void)deliver; (void)error; self.finished=finished; return YES;
}
- (void)stop { }
@end
@interface TX500FaxStationController (ReviewFixture)
- (void)cancelDecode:(id)sender;
@end
static void TestResponsiveMedia(NSURL *root) {
    TX500SSTVStationController *station=[TX500SSTVStationController new];
    station.defaults=[[NSUserDefaults alloc] initWithSuiteName:NSUUID.UUID.UUIDString];
    [station.defaults setInteger:0 forKey:@"TX500SSTVDiskShare"];
    station.galleryDirectory=[root URLByAppendingPathComponent:@"live-review"];
    ReviewLiveSource *source=[ReviewLiveSource new];
    station.radioSourceFactory=^id<TX500SSTVAudioSource>{return source;};
    __block BOOL catWasBackground=NO;
    station.catFrequencyProvider=^NSNumber *{catWasBackground=!NSThread.isMainThread;[NSThread sleepForTimeInterval:0.2];return @14230000;};
    NSTimeInterval began=NSDate.timeIntervalSinceReferenceDate;
    Check([station setEnabled:YES error:nil] && NSDate.timeIntervalSinceReferenceDate-began<0.15,@"Listen returns immediately while CAT is delayed");
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.35]];
    Check(catWasBackground && [[station valueForKey:@"cachedCATFrequency"] isEqual:@14230000],@"CAT runs off-main and publishes a fresh cached frequency");
    source.inputFailure=@"Input Synthetic USB audio lost at 12:00:00 UTC. Listening stopped; reconnect it.";
    source.finished();
    [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    Check(!station.enabled && !station.engine.running && [station.progressLabel.stringValue containsString:@"lost"],@"Input loss stops decoding and clears the Listening state");
    [station setEnabled:NO error:nil];
    NSURL *wav=[root URLByAppendingPathComponent:@"cancel-fax.wav"];
    TX500SSTVRecording *recording=[[TX500SSTVRecording alloc] initWithSamples:[NSMutableData dataWithLength:240000] sampleRate:12000 startTime:0];
    Check([recording writeWAVToURL:wav error:nil],@"Cancellation uses an isolated synthetic WAV");
    TX500FaxEngine *sequence=[[TX500FaxEngine alloc] initWithPreviousDecodeCount:41];
    Check([sequence decodeFileAtURL:wav error:nil] && sequence.decodes==42,@"Background engine replacements preserve unique chart decode identities");
    TX500FaxEngine *decoder=[TX500FaxEngine new];
    __weak TX500FaxEngine *weakDecoder=decoder;
    __block NSUInteger progress=0;
    decoder.onDecodeProgress=^(double fraction){if(fraction>0) { progress++; weakDecoder.cancelRequested=YES; }};
    NSError *failure=nil;
    Check(![decoder decodeFileAtURL:wav error:&failure] && failure.code==6 && progress>0,@"The real fax decoder reports progress and cooperatively cancels between blocks");
    TX500FaxStationController *fax=[TX500FaxStationController new]; TX500FaxEngine *previous=fax.engine;
    began=NSDate.timeIntervalSinceReferenceDate;
    Check([fax openFileAtURL:wav] && NSDate.timeIntervalSinceReferenceDate-began<0.05 && !fax.openButton.enabled,@"WAV decode starts in the background and disables duplicate starts");
    [fax cancelDecode:nil];
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while([[fax valueForKey:@"decodeInProgress"] boolValue] && deadline.timeIntervalSinceNow>0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    Check(fax.openButton.enabled && fax.engine==previous && [fax.errorLabel.stringValue containsString:@"cancel"],@"Cancel keeps the prior chart/engine and restores the controls");
}

int main(void) {
    char rootTemplate[] = "/tmp/lab599-media-safety.XXXXXX";
    char *rootPath = mkdtemp(rootTemplate);
    if (!rootPath) return 1;
    setenv("TX500_TEST_MODE", "1", 1);
    setenv("TX500_TEST_ROOT", rootPath, 1);
    setenv("CFFIXED_USER_HOME", rootPath, 1);
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSURL *root = [NSURL fileURLWithPath:@(rootPath) isDirectory:YES];
        TestResponsiveMedia(root);
        TX500SSTVStationController *sstv = [TX500SSTVStationController new];
        sstv.galleryDirectory = [root URLByAppendingPathComponent:@"SSTV" isDirectory:YES];
        sstv.defaults = [[NSUserDefaults alloc] initWithSuiteName:NSUUID.UUID.UUIDString];
        [sstv.defaults setInteger:0 forKey:@"TX500SSTVDiskShare"];
        TX500SSTVPicture *picture = [[TX500SSTVPicture alloc] initWithModeKey:@"M1" modeName:@"Martin M1"
            width:320 height:256 rowsReceived:256 complete:YES rgb:[NSMutableData dataWithLength:320*256*3]
            endUTC:NSDate.date offsetHz:0 slantPPM:0 fromFile:YES sourceName:@"Synthetic test"];
        [sstv keepInGallery:picture];
        Check(sstv.pictures.count == 1 && !picture.savedURL, @"Offline picture stays in memory without automatic saving");
        NSURL *png = [root URLByAppendingPathComponent:@"picture.png"];
        Check([picture writePNGToURL:png error:nil], @"Synthetic gallery PNG can be saved");
        picture.savedURL = png;
        __block NSUInteger trashCalls = 0;
        sstv.trashHandler = ^BOOL(NSURL *url, NSError **error) { (void)url; (void)error; trashCalls++; return YES; };
        sstv.confirmMoveToTrash = ^BOOL(NSString *text) { (void)text; return NO; };
        Check(![sstv removePictureFromGallery:picture] && sstv.pictures.count == 1 && trashCalls == 0,
              @"Cancel preserves an SSTV picture and never reaches Trash");
        sstv.confirmMoveToTrash = ^BOOL(NSString *text) { (void)text; return YES; };
        sstv.trashHandler = ^BOOL(NSURL *url, NSError **error) { (void)url; (void)error; trashCalls++; return NO; };
        Check(![sstv removePictureFromGallery:picture] && sstv.pictures.count == 1 && picture.savedURL,
              @"A failed Trash operation preserves gallery state");
        sstv.trashHandler = ^BOOL(NSURL *url, NSError **error) { (void)url; (void)error; trashCalls++; return YES; };
        Check([sstv removePictureFromGallery:picture] && sstv.pictures.count == 0 && !picture.savedURL,
              @"An explicitly confirmed Trash operation removes only the selected picture");
        Check([NSFileManager.defaultManager fileExistsAtPath:png.path], @"Tests never touch the real Trash");
        [sstv keepInGallery:picture];

        TX500FaxStationController *fax = [TX500FaxStationController new];
        fax.faxDirectory = [root URLByAppendingPathComponent:@"Fax" isDirectory:YES];
        Check(!fax.showChartsButton.enabled && ![NSFileManager.defaultManager fileExistsAtPath:fax.faxDirectory.path],
              @"Merely viewing Fax never creates its folder");
        TX500FaxChart *chart = [TX500FaxChart new];
        [chart setValue:@320 forKey:@"width"];
        [chart setValue:@200 forKey:@"height"];
        [chart setValue:[NSMutableData dataWithLength:320*200] forKey:@"gray"];
        [chart setValue:@"test.wav" forKey:@"fileName"];
        [chart setValue:@"synthetic test" forKey:@"marginSource"];
        [fax addToStrip:chart];
        [fax showChart:chart];
        NSURL *first = [fax saveShownToFaxFolder:nil];
        NSData *firstBytes = [NSData dataWithContentsOfURL:first];
        NSURL *second = [fax saveShownToFaxFolder:nil];
        Check(first && second && ![first isEqual:second] && [firstBytes isEqual:[NSData dataWithContentsOfURL:first]],
              @"Repeated Fax save chooses a new filename and never overwrites the first PNG");
        fax.confirmMoveToTrash = ^BOOL(NSString *text) { (void)text; return NO; };
        Check(![fax removeChartFromSession:chart] && fax.sessionCharts.count == 1,
              @"Cancel preserves a saved Fax chart");
        fax.confirmMoveToTrash = ^BOOL(NSString *text) { (void)text; return YES; };
        fax.trashHandler = ^BOOL(NSURL *url, NSError **error) { (void)url; (void)error; return NO; };
        Check(![fax removeChartFromSession:chart] && chart.savedURL && fax.displayedChart == chart,
              @"Failed Fax Trash preserves its chart and saved path");
        [NSFileManager.defaultManager removeItemAtURL:root error:nil];
        printf("PASS: %lu media gallery safety checks; synthetic images, isolated files, no radio or audio capture.\n", (unsigned long)checks);
    }
    return 0;
}
