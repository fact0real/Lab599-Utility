//
//  LogbookAndCloudTests.m
//  Lab599 Utility Tests
//
//  Comprehensive Unit & Regression Test Suite for Logbook & Cloud Ecosystem:
//  - SQLite3 Database Persistence & ACID Integrity
//  - ADIF 3.1 Record Generation, Parsing & Deduplication
//  - Callsign Lookup XML Parsing (QRZ.com & HamQTH.com)
//  - Zero-Click Cloud Sync Request Payloads & TQSL CLI Argument Vectors
//  - Voice, CW, and FT8 Subsystem Logging Bridges
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "TX500LogbookManager.h"
#import "TX500CallsignLookupService.h"
#import "TX500CloudSyncEngine.h"
#import "TX500FT8AutoEngine.h"
#import "TX500CWQSOAssistant.h"
#import "TX500WebAuthenticatorController.h"
#import "TX500CloudSettingsController.h"
#import "TX500LogbookController.h"
#import "TX500SecretStore.h"

@interface TX500CollisionTableView : NSTableView
@property (nonatomic, strong) NSView *forcedReusableView;
@end

@implementation TX500CollisionTableView
- (NSView *)makeViewWithIdentifier:(NSUserInterfaceItemIdentifier)identifier owner:(id)owner {
    (void)identifier;
    (void)owner;
    return self.forcedReusableView;
}
@end

// Sync checks: stands in for the cloud while installed. Each contact sent is noted as
// "CALL:Service,Service", and those services are marked UPLOADED, as a service that answered OK
// would; nothing leaves the Mac.
static NSMutableArray<NSString *> *SyncSends = nil;
static IMP SyncRealUpload = NULL;
static NSSet<NSString *> *SyncFailing = nil;       // services the stand-in fails, as a service that refuses would
static NSSet<NSString *> *SyncFailingCalls = nil;  // or only these QSOs, on QRZ
static void (^SyncAfterSend)(void) = nil;          // run after each one
static NSSet<NSString *> *SyncHoldCalls = nil;    // these QSOs' uploads give no answer until ReleaseHeldUploads()
static BOOL SyncHoldMarksAtOnce = NO;             // held: its services take it at once (only the answer waits), or at release
static NSMutableArray<NSArray *> *SyncHeld = nil;   // the answers held, @[callsign, answer]
static void (^SyncWhenHeld)(NSString *callsign) = nil;   // run, on the sync's own thread, as each one is held
static void StartRecordingSyncSends(void) {
    SyncSends = [NSMutableArray array];
    Method m = class_getInstanceMethod([TX500CloudSyncEngine class], @selector(uploadContact:toServices:completion:));
    IMP recorder = imp_implementationWithBlock(^(TX500CloudSyncEngine *engine, TX500LogRecord *record, NSArray<NSString *> *services, void (^completion)(BOOL, NSString *)) {
        NSArray<NSString *> *to = [engine servicesForUpload:services];   // nil: the upload after a QSO
        if ([SyncHoldCalls containsObject:record.callsign]) {
            @synchronized (SyncSends) {
                [SyncSends addObject:[NSString stringWithFormat:@"%@:%@", record.callsign, [to componentsJoinedByString:@","]]];
            }
            BOOL atOnce = SyncHoldMarksAtOnce;
            void (^take)(void) = ^{
                for (NSString *service in to) [[TX500LogbookManager sharedManager] updateCloudStatusForUUID:record.uuid service:service status:@"UPLOADED" error:nil];
            };
            if (atOnce) take();
            void (^answer)(void) = ^{
                if (!atOnce) take();
                if (completion) completion(YES, @"Recorded by the test, held; nothing uploaded.");
            };
            @synchronized (SyncSends) {
                if (!SyncHeld) SyncHeld = [NSMutableArray array];
                [SyncHeld addObject:@[record.callsign, [answer copy]]];
            }
            if (SyncWhenHeld) SyncWhenHeld(record.callsign);
            return;
        }
        @synchronized (SyncSends) {
            [SyncSends addObject:[NSString stringWithFormat:@"%@:%@", record.callsign, [to componentsJoinedByString:@","]]];
        }
        BOOL allAccepted = YES;
        for (NSString *service in to) {
            if ([SyncFailing containsObject:service] ||
                ([service isEqualToString:@"QRZ"] && [SyncFailingCalls containsObject:record.callsign])) { allAccepted = NO; continue; }
            [[TX500LogbookManager sharedManager] updateCloudStatusForUUID:record.uuid service:service status:@"UPLOADED" error:nil];
        }
        if (SyncAfterSend) SyncAfterSend();
        if (completion) completion(allAccepted, @"Recorded by the test; nothing uploaded.");
    });
    SyncRealUpload = method_setImplementation(m, recorder);
}
@interface TX500CloudSyncEngine (LoTWTaken)
- (BOOL)takeLoTW;
- (void)giveBackLoTW;
@end
static void ReleaseHeldUploads(void) {
    NSArray<NSArray *> *held = nil;
    @synchronized (SyncSends) {
        held = [SyncHeld copy];
        [SyncHeld removeAllObjects];
    }
    for (NSArray *one in held) dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), one[1]);
}
// the held answer of that QSO's upload, given now, on the thread that asks
static void AnswerHeldUploadNow(NSString *callsign) {
    void (^answer)(void) = nil;
    @synchronized (SyncSends) {
        for (NSArray *one in SyncHeld) if ([one[0] isEqualToString:callsign]) { answer = one[1]; [SyncHeld removeObject:one]; break; }
    }
    if (answer) answer();
}
static NSUInteger HeldUploads(void) {
    @synchronized (SyncSends) { return SyncHeld.count; }
}
static void StopRecordingSyncSends(void) {
    if (!SyncRealUpload) return;
    Method m = class_getInstanceMethod([TX500CloudSyncEngine class], @selector(uploadContact:toServices:completion:));
    method_setImplementation(m, SyncRealUpload);
    SyncRealUpload = NULL;
}
// The sends of the test's own contacts (their callsigns start with 0SY), from the n-th one on
static NSSet<NSString *> *SyncSendsOfTestContacts(NSUInteger from) {
    NSMutableSet<NSString *> *sends = [NSMutableSet set];
    @synchronized (SyncSends) {
        for (NSUInteger i = from; i < SyncSends.count; i++) {
            if ([SyncSends[i] hasPrefix:@"0SY"]) [sends addObject:SyncSends[i]];
        }
    }
    return sends;
}
static NSUInteger SyncSendCount(void) {
    @synchronized (SyncSends) { return SyncSends.count; }
}
static BOOL RunMainLoopUntil(BOOL (^done)(void)) {
    NSDate *limit = [NSDate dateWithTimeIntervalSinceNow:10.0];
    while (!done() && limit.timeIntervalSinceNow > 0) {
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return done();
}
// every block already queued on the main queue has run (it is served in order)
static void DrainMainQueue(void) {
    __block BOOL reached = NO;
    dispatch_async(dispatch_get_main_queue(), ^{ reached = YES; });
    RunMainLoopUntil(^BOOL { return reached; });
}
static TX500LogRecord *SyncTestContact(NSString *call, NSString *qrz, NSString *clublog, NSString *eqsl, NSString *lotw) {
    TX500LogRecord *r = [[TX500LogRecord alloc] init];
    r.callsign = call; r.qsoDate = @"20261010"; r.timeOn = @"101500";
    r.band = @"20m"; r.frequencyHz = 14074000; r.mode = @"FT8"; r.myCall = @"EA3JIC";
    r.qrzStatus = qrz; r.clublogStatus = clublog; r.eqslStatus = eqsl; r.lotwStatus = lotw;
    return r;
}

// The LoTW download stood in for while installed: no network; it answers with the report given, and
// each call is noted in SyncSends as "LoTW download", in order with the uploads.
@interface TX500LogbookController (SyncTests)
@property (nonatomic) BOOL syncBusy;
- (void)refreshLoTWConfirmations:(id)sender;
- (void)fetchLoTWReport:(NSURL *)url completion:(void (^)(NSData *data, NSError *error))completion;
@end
static NSString *LoTWReport = nil;
static NSUInteger LoTWDownloads = 0;
static BOOL LoTWHold = NO;                        // LoTW's answer waits until ReleaseLoTW()
static void (^LoTWHeld)(void) = nil;
static BOOL LoTWUnreachable = NO;                 // the request fails, as with no network
static NSURL *LoTWAsked = nil;
static IMP LoTWRealFetch = NULL;
static void StandInForLoTW(NSString *report) {
    LoTWReport = report;
    Method m = class_getInstanceMethod([TX500LogbookController class], @selector(fetchLoTWReport:completion:));
    IMP standIn = imp_implementationWithBlock(^(id controller, NSURL *url, void (^completion)(NSData *, NSError *)) {
        (void)controller;
        @synchronized (SyncSends) {
            LoTWDownloads++;
            LoTWAsked = url;
            [SyncSends addObject:@"LoTW download"];
        }
        NSData *answer = [LoTWReport dataUsingEncoding:NSUTF8StringEncoding];
        if (LoTWUnreachable) {
            completion(nil, [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet
                                            userInfo:@{NSLocalizedDescriptionKey: @"The test has no network."}]);
            return;
        }
        if (LoTWHold) {
            LoTWHeld = [^{ completion(answer, nil); } copy];
        } else {
            completion(answer, nil);
        }
    });
    LoTWRealFetch = method_setImplementation(m, standIn);
}
static void StopStandingInForLoTW(void) {
    if (!LoTWRealFetch) return;
    Method m = class_getInstanceMethod([TX500LogbookController class], @selector(fetchLoTWReport:completion:));
    method_setImplementation(m, LoTWRealFetch);
    LoTWRealFetch = NULL;
}
static void ReleaseLoTW(void) {
    void (^answer)(void) = LoTWHeld;
    LoTWHeld = nil;
    if (answer) dispatch_async(dispatch_get_main_queue(), answer);
}
static NSUInteger Occurrences(NSString *text, NSString *what) {
    return [text componentsSeparatedByString:what].count - 1;
}

static void AssertTrue(BOOL condition, NSString *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", [message UTF8String]);
        exit(1);
    }
}

int main(int argc, const char * argv[]) {
    char testRootTemplate[] = "/tmp/Lab599LogbookTests.XXXXXX";
    char *testRoot = mkdtemp(testRootTemplate);
    if (!testRoot) return 1;
    setenv("TX500_TEST_MODE", "1", 1);
    setenv("TX500_TEST_ROOT", testRoot, 1);
    setenv("CFFIXED_USER_HOME", testRoot, 1);
    @autoreleasepool {
        (void)argc; (void)argv;
        NSLog(@"Running TX-500 Logbook & Cloud Ecosystem Tests...");

        // 1. Temporary SQLite Database Setup
        NSString *tempDBPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                                [NSString stringWithFormat:@"test_tx500_logbook_%@.sqlite", [[NSUUID UUID] UUIDString]]];
        NSURL *dbURL = [NSURL fileURLWithPath:tempDBPath];
        TX500LogbookManager *mgr = [[TX500LogbookManager alloc] initWithDatabaseURL:dbURL];

        AssertTrue(mgr != nil, @"LogbookManager instantiated");
        AssertTrue(mgr.totalContactCount == 0, @"Initial contact count is 0");
        NSLog(@"PASS: SQLite3 Database initialized at temporary path.");

        // 2. Voice QSO Creation & SQLite CRUD
        TX500LogRecord *rec1 = [[TX500LogRecord alloc] init];
        rec1.callsign = @"W1AW";
        rec1.qsoDate = @"20260921";
        rec1.timeOn = @"132500";
        rec1.timeOff = @"132800";
        rec1.band = @"20m";
        rec1.frequencyHz = 14205000;
        rec1.mode = @"USB";
        rec1.rstSent = @"59";
        rec1.rstRcvd = @"59";
        rec1.name = @"Hiram Percy Maxim Memorial";
        rec1.email = @"operator@example.net";
        rec1.imageURL = @"https://example.net/w1aw.jpg";
        rec1.qth = @"Newington";
        rec1.state = @"CT";
        rec1.country = @"United States";
        rec1.grid = @"FN31pr";
        rec1.notes = @"Strong SSB voice signal over 20m beam";
        rec1.myCall = @"EP2AES";
        rec1.stationProfile=@{@"operatorCall":@"K1ABC",@"operatorName":@"Portable Op",@"antenna":@"Dipole",@"cqZone":@"21"};

        NSError *err = nil;
        BOOL saved = [mgr saveContact:rec1 error:&err];
        AssertTrue(saved, @"Saved voice contact to SQLite");
        AssertTrue(mgr.totalContactCount == 1, @"Contact count is 1");

        TX500LogRecord *fetched = [mgr contactWithUUID:rec1.uuid];
        AssertTrue(fetched != nil, @"Fetched contact from SQLite");
        AssertTrue([fetched.callsign isEqualToString:@"W1AW"], @"Callsign matches");
        AssertTrue([fetched.mode isEqualToString:@"USB"], @"Mode is USB");
        AssertTrue([fetched.state isEqualToString:@"CT"], @"State is CT");
        AssertTrue([fetched.email isEqualToString:@"operator@example.net"], @"Enriched operator email survives SQLite roundtrip");
        AssertTrue([fetched.imageURL isEqualToString:@"https://example.net/w1aw.jpg"], @"Enriched operator photo URL survives SQLite roundtrip");
        AssertTrue(fetched.frequencyHz == 14205000, @"Frequency is 14.205 MHz");
        AssertTrue([fetched.stationProfile isEqual:rec1.stationProfile], @"Station identity snapshot survives SQLite roundtrip");
        NSLog(@"PASS: Voice QSO saved and verified from SQLite database.");

        // Regression: AppKit can return a stale reusable NSBox whose identifier
        // collides with a Logbook text or badge cell. The Station -> Logbook
        // crash report showed setStringValue: being sent to that NSBox.
        [NSApplication sharedApplication];
        NSUserDefaults *sessionDefaults = [NSUserDefaults standardUserDefaults];
        NSString *sessionKey = @"TX500_QRZ_2FASessionCookies";
        NSString *activeKey = @"TX500_QRZ_2FA_Active";
        AssertTrue(TX500StoreSecret(sessionKey, @"session=example"), @"Stored isolated test session");
        [sessionDefaults setBool:NO forKey:activeKey];
        AssertTrue(![TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceQRZ],
                   @"Inactive 2FA session is not advertised");
        AssertTrue([TX500WebAuthenticatorController cookieHeaderForService:TX500AuthServiceQRZ] == nil,
                   @"Inactive 2FA session is never sent");
        [sessionDefaults setBool:YES forKey:activeKey];
        AssertTrue([TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceQRZ],
                   @"Active saved 2FA session is recognized");
        AssertTrue([[TX500WebAuthenticatorController cookieHeaderForService:TX500AuthServiceQRZ]
                    isEqualToString:@"session=example"], @"Active saved 2FA session is available");
        AssertTrue(TX500RemoveSecret(sessionKey), @"Removed isolated test session");
        [sessionDefaults removeObjectForKey:activeKey];

        TX500LogbookManager *shared = [TX500LogbookManager sharedManager];
        [shared clearAllContactsForTesting];
        AssertTrue([shared saveContact:[rec1 copy] error:nil], @"Seeded shared logbook for table-cell regression");
        TX500LogbookController *logbookController = [TX500LogbookController new];
        TX500CollisionTableView *collisionTable = [TX500CollisionTableView new];
        collisionTable.forcedReusableView = [[NSBox alloc] initWithFrame:NSZeroRect];
        NSTableColumn *callColumn = [[NSTableColumn alloc] initWithIdentifier:@"CALL"];
        NSView *callCell = [(id<NSTableViewDelegate>)logbookController tableView:collisionTable
                                                            viewForTableColumn:callColumn
                                                                           row:0];
        AssertTrue([callCell isKindOfClass:NSTableCellView.class], @"Stale NSBox is replaced by a safe text cell");
        AssertTrue([((NSTableCellView *)callCell).textField.stringValue isEqualToString:@"W1AW"], @"Recovered text cell shows the contact");

        collisionTable.forcedReusableView = [[NSBox alloc] initWithFrame:NSZeroRect];
        NSTableColumn *qrzColumn = [[NSTableColumn alloc] initWithIdentifier:@"QRZ"];
        NSView *badgeCell = [(id<NSTableViewDelegate>)logbookController tableView:collisionTable
                                                             viewForTableColumn:qrzColumn
                                                                            row:0];
        AssertTrue([badgeCell isKindOfClass:NSTableCellView.class], @"Stale NSBox is replaced by a safe cloud badge cell");
        NSLog(@"PASS: Station -> Logbook recycled-view crash regression verified.");

        // 3. ADIF 3.1 Record Generation & Tag Integrity
        NSString *adif = [rec1 adifRecordString];
        AssertTrue([adif containsString:@"<CALL:4>W1AW"], @"ADIF has CALL W1AW");
        AssertTrue([adif containsString:@"<MODE:3>USB"], @"ADIF has MODE USB");
        AssertTrue([adif containsString:@"<BAND:3>20m"], @"ADIF has BAND 20m");
        AssertTrue([adif containsString:@"<FREQ:9>14.205000"], @"ADIF has FREQ");
        AssertTrue([adif containsString:@"<RST_SENT:2>59"], @"ADIF has RST_SENT 59");
        AssertTrue([adif containsString:@"<STATE:2>CT"], @"ADIF has STATE CT");
        AssertTrue([adif containsString:@"<EMAIL:20>operator@example.net"], @"ADIF preserves enriched operator email");
        AssertTrue([adif containsString:@"<GRIDSQUARE:6>FN31PR"], @"ADIF has GRIDSQUARE");
        AssertTrue([adif containsString:@"<EOR>"], @"ADIF has EOR");
        NSLog(@"PASS: ADIF 3.1 Record formatted with standard tags.");

        // 4. ADIF Parsing from String
        TX500LogRecord *parsedRec = [TX500LogRecord recordFromADIFRecordText:adif];
        AssertTrue(parsedRec != nil, @"Parsed record from ADIF text");
        AssertTrue([parsedRec.callsign isEqualToString:@"W1AW"], @"Parsed callsign");
        AssertTrue([parsedRec.mode isEqualToString:@"USB"], @"Parsed mode");
        AssertTrue([parsedRec.state isEqualToString:@"CT"], @"Parsed state");
        AssertTrue([parsedRec.email isEqualToString:@"operator@example.net"], @"Parsed operator email");
        AssertTrue([parsedRec.grid isEqualToString:@"FN31PR"], @"Parsed grid");
        AssertTrue([parsedRec.stationProfile[@"operatorCall"] isEqual:@"K1ABC"], @"ADIF preserves operator distinct from station callsign");
        AssertTrue([parsedRec.stationProfile[@"antenna"] isEqual:@"Dipole"], @"ADIF preserves station antenna");
        AssertTrue([parsedRec.myCall isEqual:@"EP2AES"], @"ADIF preserves station callsign");
        NSLog(@"PASS: ADIF Record parsed correctly from raw text.");

        // 5. Cloud Status Updating
        BOOL statusUpdated = [mgr updateCloudStatusForUUID:rec1.uuid service:@"LoTW" status:@"UPLOADED" error:&err];
        AssertTrue(statusUpdated, @"LoTW status updated");
        [mgr updateCloudStatusForUUID:rec1.uuid service:@"QRZ" status:@"CONFIRMED" error:nil];

        TX500LogRecord *updatedRec = [mgr contactWithUUID:rec1.uuid];
        AssertTrue([updatedRec.lotwStatus isEqualToString:@"UPLOADED"], @"LoTW status is UPLOADED");
        AssertTrue([updatedRec.qrzStatus isEqualToString:@"CONFIRMED"], @"QRZ status is CONFIRMED");
        AssertTrue(mgr.confirmedContactCount == 1, @"Confirmed count is 1");
        NSLog(@"PASS: Cloud status updates & confirmed metrics verified.");

        // 6. ADIF Export & Import with Deduplication
        NSString *exportADIFPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"test_log_export.adi"];
        NSURL *exportURL = [NSURL fileURLWithPath:exportADIFPath];
        BOOL exported = [mgr exportADIFToFileURL:exportURL error:&err];
        AssertTrue(exported, @"Exported logbook to ADIF file");

        NSInteger duplicates = 0;
        NSInteger imported = [mgr importADIFFromFileURL:exportURL duplicatesCount:&duplicates error:&err];
        AssertTrue(imported == 0, @"0 new records imported due to deduplication");
        AssertTrue(duplicates == 1, @"1 duplicate record properly detected");
        [[NSFileManager defaultManager] removeItemAtURL:exportURL error:nil];
        NSLog(@"PASS: ADIF Export/Import and duplicate detection verified.");

        // 7. Subsystem Bridges: FT8 Auto Engine & CW Assistant
        TX500FT8LoggedQSO *ft8QSO = [[TX500FT8LoggedQSO alloc] init];
        ft8QSO.callsign = @"JA1ABC";
        ft8QSO.band = @"15m";
        ft8QSO.freqHz = 21074000;
        ft8QSO.rstSent = @"-08";
        ft8QSO.rstRcvd = @"+01";
        ft8QSO.grid = @"PM95";
        ft8QSO.countryName = @"Japan";
        ft8QSO.timestamp = [NSDate date];
        ft8QSO.mode = @"FT8";

        BOOL ft8Added = [mgr addContactFromFT8:ft8QSO myCall:@"EP2AES" myGrid:@"KM35"];
        AssertTrue(ft8Added, @"FT8 QSO committed to central SQLite logbook");

        TX500QSOContact *cwContact = [[TX500QSOContact alloc] init];
        cwContact.callsign = @"DL1XYZ";
        cwContact.band = @"40m";
        cwContact.frequencyMHz = 7.030;
        cwContact.rstSent = @"5NN";
        cwContact.rstRcvd = @"599";
        cwContact.name = @"Hans";
        cwContact.qth = @"Munich";
        cwContact.qsoDate = @"20260921";
        cwContact.timeOn = @"134500";

        BOOL cwAdded = [mgr addContactFromCW:cwContact myCall:@"EP2AES" myGrid:@"KM35"];
        AssertTrue(cwAdded, @"CW contact committed to central SQLite logbook");

        AssertTrue(mgr.totalContactCount == 3, @"Total contacts now 3 (Voice, FT8, CW)");

        NSArray<TX500LogRecord *> *cwSearch = [mgr searchContactsWithQuery:nil band:@"40m" mode:@"CW"];
        AssertTrue(cwSearch.count == 1, @"Found 1 CW contact on 40m");
        AssertTrue([cwSearch.firstObject.callsign isEqualToString:@"DL1XYZ"], @"Found DL1XYZ");
        NSLog(@"PASS: FT8 & CW subsystem automatic logging bridges verified.");

        // 8. Callsign Lookup: QRZ.com XML Parsing
        NSString *mockQRZXML =
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n"
        @"<QRZDatabase version=\"1.36\">\n"
        @"  <Callsign>\n"
        @"    <call>W1AW</call>\n"
        @"    <fname>ARRL</fname>\n"
        @"    <name>HQ Station</name>\n"
        @"    <name_fmt>ARRL HQ Station</name_fmt>\n"
        @"    <addr2>Newington</addr2>\n"
        @"    <state>CT</state>\n"
        @"    <country>United States</country>\n"
        @"    <grid>FN31pr</grid>\n"
        @"    <dxcc>291</dxcc>\n"
        @"    <cqzone>5</cqzone>\n"
        @"    <ituzone>8</ituzone>\n"
        @"    <image>https://files.qrz.com/w/w1aw/w1aw_shack.jpg</image>\n"
        @"    <lotw>1</lotw>\n"
        @"    <eqsl>1</eqsl>\n"
        @"  </Callsign>\n"
        @"</QRZDatabase>";

        TX500LookupResult *qrzResult = [TX500CallsignLookupService parseQRZXML:mockQRZXML callsign:@"W1AW"];
        AssertTrue([qrzResult.callsign isEqualToString:@"W1AW"], @"QRZ callsign matches");
        AssertTrue([qrzResult.name isEqualToString:@"ARRL HQ Station"], @"QRZ name matches");
        AssertTrue([qrzResult.qth isEqualToString:@"Newington"], @"QRZ QTH matches");
        AssertTrue([qrzResult.state isEqualToString:@"CT"], @"QRZ State matches");
        AssertTrue([qrzResult.country isEqualToString:@"United States"], @"QRZ Country matches");
        AssertTrue([qrzResult.grid isEqualToString:@"FN31pr"], @"QRZ Grid matches");
        AssertTrue([qrzResult.imageURL containsString:@"w1aw_shack.jpg"], @"QRZ Image URL extracted");
        AssertTrue(qrzResult.isLoTW == YES, @"QRZ LoTW flag is YES");
        AssertTrue(qrzResult.isEQSL == YES, @"QRZ eQSL flag is YES");
        NSLog(@"PASS: QRZ.com XML Parser extracts all operator metadata & photo URL.");

        // 9. Callsign Lookup: HamQTH.com XML Parsing
        NSString *mockHamQTHXML =
        @"<?xml version=\"1.0\" encoding=\"UTF-8\" ?>\n"
        @"<HamQTH version=\"2.0\">\n"
        @"  <search>\n"
        @"    <callsign>EP2AES</callsign>\n"
        @"    <nick>Ali</nick>\n"
        @"    <adr_city>Tehran</adr_city>\n"
        @"    <country>Iran</country>\n"
        @"    <grid>KM35</grid>\n"
        @"    <adif>130</adif>\n"
        @"    <picture>https://hamqth.com/upload/ep2aes.jpg</picture>\n"
        @"    <lotw>Y</lotw>\n"
        @"    <eqsl>Y</eqsl>\n"
        @"  </search>\n"
        @"</HamQTH>";

        TX500LookupResult *hamResult = [TX500CallsignLookupService parseHamQTHXML:mockHamQTHXML callsign:@"EP2AES"];
        AssertTrue([hamResult.callsign isEqualToString:@"EP2AES"], @"HamQTH callsign");
        AssertTrue([hamResult.name isEqualToString:@"Ali"], @"HamQTH operator name");
        AssertTrue([hamResult.qth isEqualToString:@"Tehran"], @"HamQTH city");
        AssertTrue([hamResult.country isEqualToString:@"Iran"], @"HamQTH country");
        AssertTrue([hamResult.grid isEqualToString:@"KM35"], @"HamQTH grid");
        AssertTrue([hamResult.imageURL containsString:@"ep2aes.jpg"], @"HamQTH photo URL");
        AssertTrue(hamResult.isLoTW == YES, @"HamQTH LoTW flag");
        NSLog(@"PASS: HamQTH.com XML Parser extracts all operator metadata & photo URL.");

        // 10. Zero-Click Cloud Upload Payloads & TQSL CLI Arguments
        NSString *singleADIF = [TX500CloudSyncEngine buildSingleRecordADIF:rec1];
        AssertTrue([singleADIF hasPrefix:@"<ADIF_VER:5>3.1.4"], @"Single record ADIF header");
        AssertTrue([singleADIF containsString:@"<CALL:4>W1AW"], @"Single record ADIF call");

        NSArray<NSString *> *tqslArgs = [TX500CloudSyncEngine buildTQSLArgumentsForADIFPath:@"/tmp/test.adi"
                                                                                  location:@"Home Station"
                                                                                  password:@"Pass123"];
        AssertTrue([TX500CloudSyncEngine discoverTQSLBinaryPath] == nil,
                   @"TQSL discovery is disabled in isolated test mode");
        __block BOOL cloudSideEffectSuppressed = NO;
        [[TX500CloudSyncEngine sharedEngine] uploadContactImmediately:rec1 completion:^(BOOL success, NSString *summary) {
            cloudSideEffectSuppressed = success && [summary containsString:@"suppressed"];
        }];
        AssertTrue(cloudSideEffectSuppressed, @"Cloud uploads are synchronously suppressed in test mode");
        AssertTrue([tqslArgs containsObject:@"-d"], @"TQSL arg -d (no date range modal)");
        AssertTrue([tqslArgs containsObject:@"-u"], @"TQSL arg -u (direct internet upload)");
        AssertTrue([tqslArgs containsObject:@"-x"], @"TQSL arg -x (batch mode exit)");
        AssertTrue([tqslArgs containsObject:@"-q"], @"TQSL arg -q (quiet)");
        AssertTrue([tqslArgs containsObject:@"compliant"], @"TQSL arg -a compliant (suppress popups)");
        AssertTrue([tqslArgs containsObject:@"ignore"], @"TQSL arg -f ignore");
        AssertTrue([tqslArgs containsObject:@"Home Station"], @"TQSL station location");
        AssertTrue([tqslArgs containsObject:@"Pass123"], @"TQSL password");
        AssertTrue([tqslArgs.lastObject isEqualToString:@"/tmp/test.adi"], @"TQSL target ADIF path");
        // 11. TQSL Storage Synchronization (~/.tqsl)
        BOOL tqslSync = [TX500CloudSyncEngine synchronizeTQSLStorage];
        AssertTrue(tqslSync == YES, @"TQSL directory synchronized");
        NSString *tqslDir = [[NSString stringWithUTF8String:testRoot] stringByAppendingPathComponent:@".tqsl"];
        BOOL isDir = NO;
        AssertTrue([[NSFileManager defaultManager] fileExistsAtPath:tqslDir isDirectory:&isDir] && isDir, @"~/.tqsl directory exists");
        NSLog(@"PASS: isolated TQSL storage directory verification and creation passed.");

        // Club Log must acknowledge the upload explicitly; error text and
        // redirects must never mark a QSO as uploaded.
        NSURL *clubURL = [NSURL URLWithString:@"https://clublog.org/realtime.php"];
        NSHTTPURLResponse *clubOK = [[NSHTTPURLResponse alloc] initWithURL:clubURL statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
        NSHTTPURLResponse *clubError = [[NSHTTPURLResponse alloc] initWithURL:clubURL statusCode:403 HTTPVersion:@"HTTP/1.1" headerFields:nil];
        NSHTTPURLResponse *otherHost = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://example.org/realtime.php"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
        NSHTTPURLResponse *otherPath = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://clublog.org/account.php"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
        AssertTrue(TX500ClubLogResponseIsSuccess(clubOK, [@"OK\n" dataUsingEncoding:NSUTF8StringEncoding]), @"Club Log exact success accepted");
        AssertTrue(TX500ClubLogResponseIsSuccess(clubOK, [@"QSO Duplicate" dataUsingEncoding:NSUTF8StringEncoding]), @"Club Log documented duplicate accepted");
        AssertTrue(TX500ClubLogResponseIsSuccess(clubOK, [@"QSO Modified" dataUsingEncoding:NSUTF8StringEncoding]), @"Club Log documented modification accepted");
        AssertTrue(!TX500ClubLogResponseIsSuccess(clubOK, [@"Upload rejected: callbook error" dataUsingEncoding:NSUTF8StringEncoding]), @"Club Log embedded ok rejected");
        AssertTrue(!TX500ClubLogResponseIsSuccess(clubOK, [@"Token expired" dataUsingEncoding:NSUTF8StringEncoding]), @"Club Log expired token rejected");
        AssertTrue(!TX500ClubLogResponseIsSuccess(clubOK, NSData.data), @"Club Log empty response rejected");
        AssertTrue(!TX500ClubLogResponseIsSuccess(clubOK, [NSData dataWithBytes:"\xff" length:1]), @"Club Log invalid UTF-8 rejected");
        AssertTrue(!TX500ClubLogResponseIsSuccess(clubError, [@"OK" dataUsingEncoding:NSUTF8StringEncoding]), @"Club Log HTTP error rejected");
        AssertTrue(!TX500ClubLogResponseIsSuccess(otherHost, [@"OK" dataUsingEncoding:NSUTF8StringEncoding]), @"Club Log redirect rejected");
        AssertTrue(!TX500ClubLogResponseIsSuccess(otherPath, [@"OK" dataUsingEncoding:NSUTF8StringEncoding]), @"Club Log unexpected path rejected");

        // 11b. Sync All and Sync Selected upload each QSO only to the enabled and configured services
        // where it is still pending, eQSL included, whatever its mode, and never again to one where it
        // is UPLOADED or CONFIRMED; then Sync All downloads the LoTW confirmations, and Sync Selected
        // nothing. An ADIF file brings each service's upload status in, and the export takes it out.
        AssertTrue([TX500CloudSyncEngine isPendingStatus:@"NONE"] && [TX500CloudSyncEngine isPendingStatus:@"QUEUED"] &&
                   [TX500CloudSyncEngine isPendingStatus:@"ERROR"] && [TX500CloudSyncEngine isPendingStatus:nil] &&
                   ![TX500CloudSyncEngine isPendingStatus:@"UPLOADED"] && ![TX500CloudSyncEngine isPendingStatus:@"CONFIRMED"],
                   @"Pending: NONE, QUEUED, ERROR or no status; never UPLOADED or CONFIRMED");
        TX500CloudSyncEngine *cloud = [TX500CloudSyncEngine sharedEngine];
        NSUserDefaults *syncDefaults = [NSUserDefaults standardUserDefaults];
        AssertTrue([cloud enabledConfiguredServices].count == 0, @"Sync: no service is configured to begin with");
        __block NSString *syncSummary = nil;
        [cloud syncContacts:nil completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; syncSummary = summary;
        }];
        AssertTrue([syncSummary containsString:@"No cloud service is enabled and configured"], @"Sync with no service configured sends nothing, and says so");
        AssertTrue(TX500StoreSecret(@"TX500_QRZ_APIKey", @"test-qrz-key") && TX500StoreSecret(@"TX500_ClubLog_APIKey", @"test-clublog-key") &&
                   TX500StoreSecret(@"TX500_EQSL_Password", @"test-eqsl-word"), @"Stored isolated test service keys");
        [syncDefaults setObject:@"clublog-login" forKey:@"TX500_ClubLog_Email"];
        [syncDefaults setObject:@"EA3JIC" forKey:@"TX500_EQSL_Username"];
        AssertTrue([[cloud enabledConfiguredServices] isEqualToArray:(@[@"QRZ", @"eQSL"])] && [cloud servicesForUpload:@[@"ClubLog"]].count == 0,
                   @"Club Log with its email and API key but no callsign or password is not configured, and is not sent to");
        [syncDefaults setObject:@"EA3JIC" forKey:@"TX500_ClubLog_Callsign"];
        AssertTrue(TX500StoreSecret(@"TX500_ClubLog_Password", @"test-clublog-word"), @"Stored an isolated Club Log password");
        NSArray<NSString *> *ready = [cloud enabledConfiguredServices];
        AssertTrue([ready isEqualToArray:(@[@"QRZ", @"ClubLog", @"eQSL"])],
                   [NSString stringWithFormat:@"Sync: QRZ, Club Log and eQSL enabled and configured, LoTW not (no TQSL in test mode): %@", ready]);
        AssertTrue([[TX500CloudSyncEngine pendingServicesOfContact:SyncTestContact(@"0SY0", @"UPLOADED", @"NONE", @"CONFIRMED", @"NONE") among:ready]
                    isEqualToArray:@[@"ClubLog"]], @"Pending among those: only where the status is not UPLOADED or CONFIRMED");
        // the list of services one upload sends to, which the real upload turns into its requests: nil (the upload
        // after a QSO) is every enabled and configured one, and the AutoUpload switch stops it; a sync's list is kept
        // to the enabled and configured ones, whatever that switch says
        AssertTrue([[cloud servicesForUpload:nil] isEqualToArray:ready] && [[cloud servicesForUpload:@[@"ClubLog"]] isEqualToArray:@[@"ClubLog"]] &&
                   [[cloud servicesForUpload:(@[@"QRZ", @"LoTW"])] isEqualToArray:@[@"QRZ"]], @"An upload goes to the services asked for, among the enabled and configured ones");
        [syncDefaults setBool:NO forKey:@"TX500_Cloud_AutoUploadEnabled"];
        AssertTrue([cloud servicesForUpload:nil].count == 0 && [[cloud servicesForUpload:(@[@"QRZ", @"eQSL"])] isEqualToArray:(@[@"QRZ", @"eQSL"])],
                   @"AutoUpload off stops the upload after a QSO, not a sync");
        [syncDefaults removeObjectForKey:@"TX500_Cloud_AutoUploadEnabled"];
        // QRZ's answer: OK, or a duplicate whatever its case, from QRZ itself
        NSHTTPURLResponse *qrzOK = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://logbook.qrz.com/api"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
        NSHTTPURLResponse *qrzElsewhere = [[NSHTTPURLResponse alloc] initWithURL:[NSURL URLWithString:@"https://example.org/api"] statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:nil];
        AssertTrue(TX500QRZResponseIsSuccess(qrzOK, @"RESULT=OK&LOGID=1") && TX500QRZResponseIsSuccess(qrzOK, @"RESULT=FAIL&REASON=duplicate") &&
                   TX500QRZResponseIsSuccess(qrzOK, @"RESULT=FAIL&REASON=Duplicate QSO") && !TX500QRZResponseIsSuccess(qrzOK, @"RESULT=AUTH&REASON=invalid api key") &&
                   !TX500QRZResponseIsSuccess(qrzElsewhere, @"RESULT=OK"), @"QRZ: a duplicate in any case is accepted; an auth error or another host is not");

        // the import reads ADIF 3.1.7's upload-status fields: only Y is uploaded, and a LoTW confirmation
        // received (Y, or V) is CONFIRMED; N, R, Q, I, M or no field stay pending
        TX500LogRecord *(^parsedWith)(NSString *) = ^TX500LogRecord *(NSString *tags) {
            return [TX500LogRecord recordFromADIFRecordText:[NSString stringWithFormat:@"<CALL:6>EP2AES %@ <EOR>", tags]];
        };
        TX500LogRecord *allY = parsedWith(@"<LOTW_QSL_SENT:1>Y <QRZCOM_QSO_UPLOAD_STATUS:1>Y <CLUBLOG_QSO_UPLOAD_STATUS:1>y <EQSL_QSL_SENT:1>Y");
        TX500LogRecord *notYet = parsedWith(@"<LOTW_QSL_SENT:1>N <QRZCOM_QSO_UPLOAD_STATUS:1>M <CLUBLOG_QSO_UPLOAD_STATUS:1>N <EQSL_QSL_SENT:1>Q");
        TX500LogRecord *otherValues = parsedWith(@"<LOTW_QSL_SENT:1>R <EQSL_QSL_SENT:1>I");
        TX500LogRecord *lotwConfirmed = parsedWith(@"<LOTW_QSL_SENT:1>Y <LOTW_QSL_RCVD:1>V");
        TX500LogRecord *ownQRZ = parsedWith(@"<QRZCOM_QSO_UPLOAD_STATUS:1>Y <APP_QRZLOG_STATUS:9>CONFIRMED");
        TX500LogRecord *qrzDownloaded = parsedWith(@"<QRZCOM_QSO_DOWNLOAD_STATUS:1>Y");
        TX500LogRecord *qrzConfirmedC = parsedWith(@"<APP_QRZLOG_STATUS:1>C");
        TX500LogRecord *qrzReceived = parsedWith(@"<QRZCOM_QSO_UPLOAD_STATUS:1>Y <QRZLOG_QSL_RCVD:1>Y");
        AssertTrue([qrzDownloaded.qrzStatus isEqualToString:@"UPLOADED"] && [qrzConfirmedC.qrzStatus isEqualToString:@"CONFIRMED"] &&
                   [qrzReceived.qrzStatus isEqualToString:@"CONFIRMED"],
                   @"Import, QRZ: downloaded from QRZ is UPLOADED (it is there; no confirmation), its C or QRZLOG_QSL_RCVD Y is CONFIRMED");
        BOOL (^statuses)(TX500LogRecord *, NSString *, NSString *, NSString *, NSString *) = ^BOOL(TX500LogRecord *r, NSString *q, NSString *c, NSString *e, NSString *l) {
            return [r.qrzStatus isEqualToString:q] && [r.clublogStatus isEqualToString:c] && [r.eqslStatus isEqualToString:e] && [r.lotwStatus isEqualToString:l];
        };
        AssertTrue(statuses(allY, @"UPLOADED", @"UPLOADED", @"UPLOADED", @"UPLOADED") && statuses(notYet, @"NONE", @"NONE", @"NONE", @"NONE") &&
                   statuses(otherValues, @"NONE", @"NONE", @"NONE", @"NONE") && [lotwConfirmed.lotwStatus isEqualToString:@"CONFIRMED"] &&
                   [ownQRZ.qrzStatus isEqualToString:@"CONFIRMED"],
                   @"Import: Y is uploaded, a LoTW confirmation received is CONFIRMED, the app's own QRZ status comes back; N, M, Q, R, I stay pending");
        // and the export writes them, as ADIF 3.1.7 names them: the round trip keeps what each service has
        TX500LogRecord *trip = SyncTestContact(@"0SY8", @"CONFIRMED", @"UPLOADED", @"NONE", @"CONFIRMED");
        NSString *tripADIF = [trip adifRecordString];
        TX500LogRecord *back = [TX500LogRecord recordFromADIFRecordText:tripADIF];
        AssertTrue([tripADIF containsString:@"<QRZCOM_QSO_UPLOAD_STATUS:1>Y"] && [tripADIF containsString:@"<CLUBLOG_QSO_UPLOAD_STATUS:1>Y"] &&
                   [tripADIF containsString:@"<LOTW_QSL_SENT:1>Y"] && [tripADIF containsString:@"<LOTW_QSL_RCVD:1>Y"] &&
                   [tripADIF containsString:@"<APP_QRZLOG_STATUS:9>CONFIRMED"] && ![tripADIF containsString:@"EQSL_QSL_SENT"] &&
                   statuses(back, @"CONFIRMED", @"UPLOADED", @"NONE", @"CONFIRMED"),
                   [NSString stringWithFormat:@"Export and import again: each service's status comes back (%@ %@ %@ %@)", back.qrzStatus, back.clublogStatus, back.eqslStatus, back.lotwStatus]);
        TX500LogRecord *trip2 = SyncTestContact(@"0SY9", @"UPLOADED", @"NONE", @"UPLOADED", @"UPLOADED");
        NSString *trip2ADIF = [trip2 adifRecordString];
        TX500LogRecord *back2 = [TX500LogRecord recordFromADIFRecordText:trip2ADIF];
        AssertTrue([trip2ADIF containsString:@"<EQSL_QSL_SENT:1>Y"] && [trip2ADIF containsString:@"<QRZCOM_QSO_UPLOAD_STATUS:1>Y"] &&
                   [trip2ADIF containsString:@"<LOTW_QSL_SENT:1>Y"] && ![trip2ADIF containsString:@"LOTW_QSL_RCVD"] &&
                   ![trip2ADIF containsString:@"CLUBLOG_QSO_UPLOAD_STATUS"] && statuses(back2, @"UPLOADED", @"NONE", @"UPLOADED", @"UPLOADED"),
                   [NSString stringWithFormat:@"Export and import again, eQSL and LoTW uploaded (LoTW not confirmed): each comes back (%@ %@ %@ %@)", back2.qrzStatus, back2.clublogStatus, back2.eqslStatus, back2.lotwStatus]);

        TX500LogbookManager *syncLog = [TX500LogbookManager sharedManager];
        TX500LogRecord *onQRZ = SyncTestContact(@"0SY1", @"UPLOADED", @"NONE", @"UPLOADED", @"NONE");       // pending on Club Log only
        TX500LogRecord *withError = SyncTestContact(@"0SY2", @"CONFIRMED", @"ERROR", @"NONE", @"CONFIRMED"); // Club Log failed; eQSL not yet
        TX500LogRecord *upToDate = SyncTestContact(@"0SY3", @"UPLOADED", @"UPLOADED", @"CONFIRMED", @"NONE"); // only LoTW, not configured
        TX500LogRecord *fresh = SyncTestContact(@"0SY5", @"NONE", @"NONE", @"NONE", @"NONE");
        for (TX500LogRecord *r in @[onQRZ, withError, upToDate, fresh]) AssertTrue([syncLog saveContact:r error:&err], @"Saved a sync test contact");
        // an SSTV QSO from an ADIF file that another program uploaded to Club Log and LoTW, not to QRZ
        NSString *importPath = [[NSString stringWithUTF8String:testRoot] stringByAppendingPathComponent:@"sync-import.adi"];
        NSString *importADIF = @"<ADIF_VER:5>3.1.7 <EOH>\n<CALL:4>0SY4 <QSO_DATE:8>20261010 <TIME_ON:6>103000 <BAND:3>20m <FREQ:6>14.230 "
                               @"<MODE:4>SSTV <CLUBLOG_QSO_UPLOAD_STATUS:1>Y <LOTW_QSL_SENT:1>Y <EOR>\n";
        AssertTrue([importADIF writeToFile:importPath atomically:YES encoding:NSUTF8StringEncoding error:&err] &&
                   [syncLog importADIFFromFileURL:[NSURL fileURLWithPath:importPath] duplicatesCount:NULL error:&err] == 1, @"Imported the SSTV QSO");
        TX500LogRecord *importedSSTV = nil;
        for (TX500LogRecord *r in syncLog.allContacts) if ([r.callsign isEqualToString:@"0SY4"]) importedSSTV = r;
        AssertTrue(importedSSTV && [importedSSTV.mode isEqualToString:@"SSTV"] && statuses(importedSSTV, @"NONE", @"UPLOADED", @"NONE", @"UPLOADED"),
                   @"Import: the SSTV QSO is on Club Log and LoTW, as its ADIF says, and pending on QRZ and eQSL");

        StartRecordingSyncSends();
        StandInForLoTW(@"ARRL Logbook of the World Status Report\n<EOH>\n"
                       @"<CALL:4>0SY5 <QSO_DATE:8>20261010 <TIME_ON:6>101500 <BAND:3>20m <QSL_RCVD:1>Y <EOR>\n");
        [syncDefaults setObject:@"EA3JIC" forKey:@"TX500_LoTW_Username"];
        AssertTrue(TX500StoreSecret(@"TX500_LoTW_Password", @"test-lotw-word"), @"Stored an isolated LoTW web password");
        // Sync Selected, pressed in the Logbook with two rows selected: only those two are uploaded, and
        // nothing is downloaded, although LoTW could be asked
        TX500LogbookController *syncForm = [TX500LogbookController new];
        NSTableView *syncTable = [syncForm valueForKey:@"tableView"];
        NSArray<TX500LogRecord *> *syncRows = [syncForm valueForKey:@"displayedContacts"];
        NSMutableIndexSet *picked = [NSMutableIndexSet indexSet];
        [syncRows enumerateObjectsUsingBlock:^(TX500LogRecord *r, NSUInteger i, BOOL *stop) {
            (void)stop;
            if ([r.callsign isEqualToString:@"0SY1"] || [r.callsign isEqualToString:@"0SY5"]) [picked addIndex:i];
        }];
        [syncTable selectRowIndexes:picked byExtendingSelection:NO];
        AssertTrue(syncTable.selectedRowIndexes.count == 2, @"Two rows selected in the Logbook");
        NSTextView *syncConsole = [syncForm valueForKey:@"statusConsoleTextView"];
        [syncForm syncSelectedContacts];
        AssertTrue(RunMainLoopUntil(^BOOL { return [syncConsole.string containsString:@"Batch sync finished"]; }), @"Sync Selected finishes");
        DrainMainQueue();
        NSSet *selectedSends = SyncSendsOfTestContacts(0);
        AssertTrue([selectedSends isEqualToSet:([NSSet setWithArray:@[@"0SY1:ClubLog", @"0SY5:QRZ,ClubLog,eQSL"]])],
                   [NSString stringWithFormat:@"Sync Selected: the QSO already on QRZ goes to Club Log only, the new one to all three, and no other row is touched: %@", selectedSends]);
        AssertTrue([[syncLog contactWithUUID:importedSSTV.uuid].qrzStatus isEqualToString:@"NONE"] &&
                   [[syncLog contactWithUUID:withError.uuid].clublogStatus isEqualToString:@"ERROR"], @"Sync Selected: the rows not selected stay as they were");
        AssertTrue(LoTWDownloads == 0 && ![syncConsole.string containsString:@"Downloading confirmed QSOs"], @"Sync Selected downloads nothing");
        [syncTable deselectAll:nil];
        NSUInteger beforeEmpty = SyncSendCount();
        [syncForm syncSelectedContacts];
        AssertTrue(SyncSendCount() == beforeEmpty && [syncConsole.string containsString:@"Select the contacts to sync"],
                   @"Sync Selected with no row selected sends nothing, and says what to do");

        // Sync All with no LoTW password uploads all the same, and says that nothing was downloaded
        AssertTrue(TX500RemoveSecret(@"TX500_LoTW_Password"), @"Removed the LoTW web password");
        NSUInteger beforeAll = SyncSendCount();
        [syncForm syncAllPending];
        AssertTrue(RunMainLoopUntil(^BOOL { return [syncConsole.string containsString:@"Sync All: the LoTW confirmations were not downloaded (no LoTW username and password in Settings)."]; }),
                   @"Sync All without a LoTW password says that nothing was downloaded");
        NSSet *allSends = SyncSendsOfTestContacts(beforeAll);
        AssertTrue([allSends isEqualToSet:([NSSet setWithArray:@[@"0SY2:eQSL", @"0SY2:ClubLog", @"0SY4:QRZ,eQSL"]])] && LoTWDownloads == 0,
                   [NSString stringWithFormat:@"Sync All: eQSL and Club Log (ERROR) for the one confirmed on QRZ; the imported SSTV QSO to QRZ and eQSL, not to Club Log, which has it; nothing sent before, or up to date, again; no download: %@", allSends]);
        NSArray<NSString *> *sy2Sends = [[SyncSends subarrayWithRange:NSMakeRange(beforeAll, SyncSendCount() - beforeAll)]
                                         filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH '0SY2:'"]];
        AssertTrue([sy2Sends isEqualToArray:(@[@"0SY2:eQSL", @"0SY2:ClubLog"])],
                   [NSString stringWithFormat:@"Sync All: 0SY2 goes to eQSL first, then to Club Log, where it failed before: %@", sy2Sends]);

        // Sync All with the LoTW account: first the uploads, then the LoTW confirmations
        AssertTrue(TX500StoreSecret(@"TX500_LoTW_Password", @"test-lotw-word"), @"Stored the LoTW web password again");
        TX500LogRecord *newer = SyncTestContact(@"0SY7", @"NONE", @"NONE", @"NONE", @"NONE");
        AssertTrue([syncLog saveContact:newer error:&err], @"Saved one more QSO");
        NSUInteger beforeDownload = SyncSendCount();
        [syncForm syncAllPending];
        AssertTrue(RunMainLoopUntil(^BOOL { return [syncConsole.string containsString:@"LoTW refresh complete"]; }), @"Sync All downloads the LoTW confirmations");
        NSArray<NSString *> *thisRun = [SyncSends subarrayWithRange:NSMakeRange(beforeDownload, SyncSendCount() - beforeDownload)];
        AssertTrue([thisRun isEqualToArray:(@[@"0SY7:QRZ,ClubLog,eQSL", @"LoTW download"])] && LoTWDownloads == 1 &&
                   [LoTWAsked.host isEqualToString:@"lotw.arrl.org"] && [LoTWAsked.path isEqualToString:@"/lotwuser/lotwreport.adi"] &&
                   [[syncLog contactWithUUID:fresh.uuid].lotwStatus isEqualToString:@"CONFIRMED"] &&
                   [syncConsole.string containsString:@"LoTW refresh complete: 1 confirmed record(s) downloaded, 1 local QSO(s) matched and updated."],
                   [NSString stringWithFormat:@"Sync All: the new QSO uploaded, then the LoTW report downloaded (stood in for) and its confirmation marked: %@", thisRun]);
        NSUInteger beforeAgain = SyncSendCount();
        __block NSString *againSummary = nil;
        [cloud syncContacts:nil completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; againSummary = summary;
        }];
        AssertTrue(RunMainLoopUntil(^BOOL { return againSummary != nil; }) && SyncSendsOfTestContacts(beforeAgain).count == 0,
                   @"Sync All again: nothing is sent twice");

        // Confirmations does what it did: with the account it downloads, and uploads nothing; without it,
        // it says what is missing and opens the LoTW settings
        NSUInteger beforeButton = SyncSendCount();
        [syncForm refreshLoTWConfirmations:nil];
        AssertTrue(RunMainLoopUntil(^BOOL { return Occurrences(syncConsole.string, @"LoTW refresh complete") == 2; }) && LoTWDownloads == 2 &&
                   SyncSendsOfTestContacts(beforeButton).count == 0, @"Confirmations downloads from LoTW and uploads nothing, as before");
        AssertTrue(TX500RemoveSecret(@"TX500_LoTW_Password"), @"Removed the LoTW web password again");
        __block NSString *settingsOpened = nil;
        syncForm.openSettingsHandler = ^(NSString *service) { settingsOpened = service; };
        [syncForm refreshLoTWConfirmations:nil];
        AssertTrue([syncConsole.string containsString:@"LoTW account username/password are required to download confirmations."] &&
                   [settingsOpened isEqualToString:@"LoTW"] && LoTWDownloads == 2, @"Confirmations without the LoTW account asks for it, as before");
        syncForm.openSettingsHandler = nil;

        // the table's copy of a row from before the sync still says Club Log NONE: the status is read
        // again from the logbook before sending, so it is not sent again
        NSUInteger beforeStale = SyncSendCount();
        __block BOOL staleDone = NO;
        [cloud syncContacts:@[onQRZ] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; (void)summary; staleDone = YES;
        }];
        AssertTrue(RunMainLoopUntil(^BOOL { return staleDone; }) && SyncSendsOfTestContacts(beforeStale).count == 0 &&
                   [onQRZ.clublogStatus isEqualToString:@"NONE"], @"Sync: an old copy of a row is not sent again to a service that has it now");

        // a service whose upload key is set to NO (a hidden setting) is left alone, even where a QSO is pending on it
        TX500LogRecord *eqslOnly = SyncTestContact(@"0SY6", @"UPLOADED", @"UPLOADED", @"NONE", @"NONE");
        AssertTrue([syncLog saveContact:eqslOnly error:&err], @"Saved a QSO pending on eQSL only");
        [syncDefaults setBool:NO forKey:@"TX500_Cloud_UploadEQSL"];
        NSUInteger beforeOff = SyncSendCount();
        __block BOOL offDone = NO;
        [cloud syncContacts:@[eqslOnly] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; (void)summary; offDone = YES;
        }];
        AssertTrue(offDone && SyncSendsOfTestContacts(beforeOff).count == 0 && [[cloud enabledConfiguredServices] isEqualToArray:(@[@"QRZ", @"ClubLog"])],
                   @"Sync: eQSL with its upload key set to NO is not sent to");
        [syncDefaults removeObjectForKey:@"TX500_Cloud_UploadEQSL"];
        StopRecordingSyncSends();

        // over the whole run, no QSO went twice to a service, nor to one where it was UPLOADED or CONFIRMED (six sends:
        // 0SY2 went to eQSL first, and then to Club Log, where it had failed before)
        NSMutableSet<NSString *> *pairs = [NSMutableSet set];
        BOOL twice = NO, toOneThatHadIt = NO;
        NSDictionary<NSString *, NSArray<NSString *> *> *had = @{@"0SY1": @[@"QRZ", @"eQSL"], @"0SY2": @[@"QRZ", @"LoTW"],
                                                                 @"0SY3": @[@"QRZ", @"ClubLog", @"eQSL"], @"0SY4": @[@"ClubLog", @"LoTW"],
                                                                 @"0SY6": @[@"QRZ", @"ClubLog"]};
        NSArray<NSString *> *everySend = [SyncSends filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF BEGINSWITH '0SY'"]];
        for (NSString *send in everySend) {
            NSArray<NSString *> *parts = [send componentsSeparatedByString:@":"];
            for (NSString *service in [parts[1] componentsSeparatedByString:@","]) {
                NSString *pair = [NSString stringWithFormat:@"%@:%@", parts[0], service];
                if ([pairs containsObject:pair]) twice = YES;
                [pairs addObject:pair];
                if ([had[parts[0]] containsObject:service]) toOneThatHadIt = YES;
            }
        }
        AssertTrue(everySend.count == 6 && !twice && !toOneThatHadIt && ![pairs containsObject:@"0SY3:LoTW"],
                   @"Sync: no QSO is sent twice to a service, nor to one where it is UPLOADED or CONFIRMED");

        // the checks below use QSOs of their own (0SZ…): first, nothing of the above is left pending
        AssertTrue([syncLog updateCloudStatusForUUID:eqslOnly.uuid service:@"eQSL" status:@"UPLOADED" error:&err], @"The QSO left pending on eQSL is set aside");
        AssertTrue(TX500StoreSecret(@"TX500_LoTW_Password", @"test-lotw-word"), @"Stored the LoTW web password again");
        StartRecordingSyncSends();
        // one sync at a time: Sync All, Sync Selected or Sync All again pressed while one runs do nothing,
        // neither upload nor download, and say so
        TX500LogRecord *slowA = SyncTestContact(@"0SZ1", @"NONE", @"NONE", @"NONE", @"NONE");
        TX500LogRecord *slowB = SyncTestContact(@"0SZ2", @"NONE", @"NONE", @"NONE", @"NONE");
        AssertTrue([syncLog saveContact:slowA error:&err] && [syncLog saveContact:slowB error:&err], @"Saved two QSOs for a slow sync");
        NSUInteger refusedBefore = Occurrences(syncConsole.string, @"A sync is already running: nothing was sent or downloaded.");
        NSUInteger downloadsBefore = LoTWDownloads, completeBefore = Occurrences(syncConsole.string, @"LoTW refresh complete");
        SyncHoldCalls = [NSSet setWithObjects:@"0SZ1", @"0SZ2", nil];
        SyncHoldMarksAtOnce = NO;
        [syncForm syncAllPending];
        AssertTrue(RunMainLoopUntil(^BOOL { return HeldUploads() == 1; }), @"The first Sync All is held in its first upload");
        DrainMainQueue();
        [syncForm reloadTableData];
        NSUInteger slowRow = [[syncForm valueForKey:@"displayedContacts"] indexOfObjectPassingTest:^BOOL(TX500LogRecord *r, NSUInteger i, BOOL *stop) {
            (void)i; (void)stop; return [r.callsign isEqualToString:@"0SZ1"];
        }];
        [syncTable selectRowIndexes:[NSIndexSet indexSetWithIndex:slowRow] byExtendingSelection:NO];
        [syncForm syncAllPending];
        [syncForm syncSelectedContacts];
        AssertTrue(Occurrences(syncConsole.string, @"A sync is already running: nothing was sent or downloaded.") == refusedBefore + 2 && LoTWDownloads == downloadsBefore,
                   @"One sync at a time: a second Sync All and a Sync Selected while one runs do nothing, and say so");
        AssertTrue(RunMainLoopUntil(^BOOL { ReleaseHeldUploads(); return Occurrences(syncConsole.string, @"LoTW refresh complete") == completeBefore + 1; }) &&
                   LoTWDownloads == downloadsBefore + 1, @"The Sync All that ran uploads and then downloads, once");
        SyncHoldCalls = nil;
        [syncTable deselectAll:nil];

        // a service that fails twice in a row is not asked again in this sync: the others go on, and the summary
        // says it, service by service, with what was not checked
        TX500LogRecord *badKey1 = SyncTestContact(@"0SZ3", @"NONE", @"UPLOADED", @"NONE", @"NONE");
        TX500LogRecord *badKey2 = SyncTestContact(@"0SZ4", @"NONE", @"UPLOADED", @"NONE", @"NONE");
        TX500LogRecord *badKey3 = SyncTestContact(@"0SZ5", @"NONE", @"UPLOADED", @"NONE", @"NONE");
        for (TX500LogRecord *r in @[badKey1, badKey2, badKey3]) AssertTrue([syncLog saveContact:r error:&err], @"Saved a QSO for a refusing QRZ");
        SyncFailing = [NSSet setWithObject:@"QRZ"];
        NSUInteger beforeBadKey = SyncSendCount();
        completeBefore = Occurrences(syncConsole.string, @"LoTW refresh complete");
        [syncForm syncAllPending];
        AssertTrue(RunMainLoopUntil(^BOOL { return Occurrences(syncConsole.string, @"LoTW refresh complete") == completeBefore + 1; }), @"Sync All with QRZ refusing finishes, download included");
        NSArray<NSString *> *badKeyRun = [SyncSends subarrayWithRange:NSMakeRange(beforeBadKey, SyncSendCount() - beforeBadKey)];
        NSString *thirdCall = badKeyRun.count == 4 ? [badKeyRun[2] componentsSeparatedByString:@":"][0] : @"";
        TX500LogRecord *leftOnQRZ = nil;
        for (TX500LogRecord *r in @[badKey1, badKey2, badKey3]) if ([r.callsign isEqualToString:thirdCall]) leftOnQRZ = r;
        AssertTrue(badKeyRun.count == 4 && [badKeyRun[0] hasSuffix:@":QRZ,eQSL"] && [badKeyRun[1] hasSuffix:@":QRZ,eQSL"] &&
                   [badKeyRun[2] hasSuffix:@":eQSL"] && [badKeyRun[3] isEqualToString:@"LoTW download"] && leftOnQRZ &&
                   [syncConsole.string rangeOfString:@"QRZ: [0-9]+ already there, 2 failed, stopped after 2 failures in a row, 1 left pending\\." options:NSRegularExpressionSearch].location != NSNotFound &&
                   [syncConsole.string containsString:@"eQSL: 3 uploaded"] && [syncConsole.string containsString:@"Not checked: LoTW (not configured, or turned off by a hidden setting)."] &&
                   [[syncLog contactWithUUID:leftOnQRZ.uuid].qrzStatus isEqualToString:@"NONE"],
                   [NSString stringWithFormat:@"QRZ refusing: asked twice, then left out for the rest of the sync; eQSL and the download go on; the summary says so: %@", badKeyRun]);
        SyncFailing = nil;
        for (TX500LogRecord *r in @[badKey1, badKey2, badKey3]) [syncLog updateCloudStatusForUUID:r.uuid service:@"QRZ" status:@"UPLOADED" error:nil];

        // a service whose upload key is set to NO during a sync: its QSOs are left pending, and nothing counts as failed
        TX500LogRecord *offLater1 = SyncTestContact(@"0SZ6", @"UPLOADED", @"UPLOADED", @"NONE", @"NONE");
        TX500LogRecord *offLater2 = SyncTestContact(@"0SZ7", @"UPLOADED", @"UPLOADED", @"NONE", @"NONE");
        AssertTrue([syncLog saveContact:offLater1 error:&err] && [syncLog saveContact:offLater2 error:&err], @"Saved two QSOs pending on eQSL");
        SyncAfterSend = ^{ [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"TX500_Cloud_UploadEQSL"]; };
        NSUInteger beforeOffLater = SyncSendCount();
        __block NSString *offLaterSummary = nil;
        [cloud syncContacts:@[offLater1, offLater2] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; offLaterSummary = summary;
        }];
        AssertTrue(RunMainLoopUntil(^BOOL { return offLaterSummary != nil; }), @"The sync with eQSL's upload key set to NO on the way finishes");
        SyncAfterSend = nil;
        [syncDefaults removeObjectForKey:@"TX500_Cloud_UploadEQSL"];
        AssertTrue(SyncSendCount() == beforeOffLater + 1 && [offLaterSummary hasPrefix:@"Batch sync finished: 1 QSO(s) sent to every service asked, 0 with a service failing."] &&
                   [offLaterSummary containsString:@"eQSL: 1 uploaded, no longer configured (or turned off by a hidden setting) during the sync, 1 left pending."],
                   [NSString stringWithFormat:@"eQSL's upload key set to NO during a sync: the rest is left pending, not failed: %@", offLaterSummary]);
        [syncLog updateCloudStatusForUUID:offLater2.uuid service:@"eQSL" status:@"UPLOADED" error:nil];

        // one sync at a time, also during the LoTW download: with LoTW slow to answer, Sync All and Sync Selected
        // pressed between the uploads and the answer do nothing, and there is no second download
        TX500LogRecord *beforeSlowLoTW = SyncTestContact(@"0SZD", @"NONE", @"NONE", @"NONE", @"NONE");
        AssertTrue([syncLog saveContact:beforeSlowLoTW error:&err], @"Saved a QSO for a sync with a slow LoTW");
        [syncForm reloadTableData];
        NSUInteger slowLoTWRow = [[syncForm valueForKey:@"displayedContacts"] indexOfObjectPassingTest:^BOOL(TX500LogRecord *r, NSUInteger i, BOOL *stop) {
            (void)i; (void)stop; return [r.callsign isEqualToString:@"0SZD"];
        }];
        [syncTable selectRowIndexes:[NSIndexSet indexSetWithIndex:slowLoTWRow] byExtendingSelection:NO];
        NSUInteger downloadingBefore = Occurrences(syncConsole.string, @"Downloading confirmed QSOs from LoTW");
        NSUInteger refusedDuring = Occurrences(syncConsole.string, @"A sync is already running: nothing was sent or downloaded.");
        NSUInteger downloadsDuring = LoTWDownloads, completeDuring = Occurrences(syncConsole.string, @"LoTW refresh complete");
        LoTWHold = YES;
        [syncForm syncAllPending];
        AssertTrue(RunMainLoopUntil(^BOOL { return Occurrences(syncConsole.string, @"Downloading confirmed QSOs from LoTW") == downloadingBefore + 1 && LoTWHeld != nil; }),
                   @"Sync All reaches its LoTW download, and LoTW does not answer yet");
        NSUInteger sendsDuring = SyncSendCount();
        [syncForm syncAllPending];
        // the uploads have reloaded the table: the row is selected again, as the operator would
        slowLoTWRow = [[syncForm valueForKey:@"displayedContacts"] indexOfObjectPassingTest:^BOOL(TX500LogRecord *r, NSUInteger i, BOOL *stop) {
            (void)i; (void)stop; return [r.callsign isEqualToString:@"0SZD"];
        }];
        [syncTable selectRowIndexes:[NSIndexSet indexSetWithIndex:slowLoTWRow] byExtendingSelection:NO];
        [syncForm syncSelectedContacts];
        AssertTrue(Occurrences(syncConsole.string, @"A sync is already running: nothing was sent or downloaded.") == refusedDuring + 2 && SyncSendCount() == sendsDuring,
                   @"During the LoTW download, Sync All and Sync Selected do nothing, and say so");
        LoTWHold = NO;
        ReleaseLoTW();
        AssertTrue(RunMainLoopUntil(^BOOL { return Occurrences(syncConsole.string, @"LoTW refresh complete") == completeDuring + 1; }) &&
                   LoTWDownloads == downloadsDuring + 1, @"The download that ran is the only one");
        [syncTable deselectAll:nil];

        // never "all synchronized" while a service was not checked, nor for the contacts given (Sync Selected)
        __block NSString *allThereSummary = nil;
        [cloud syncContacts:@[[syncLog contactWithUUID:beforeSlowLoTW.uuid]] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; allThereSummary = summary;
        }];
        AssertTrue([allThereSummary containsString:@"Nothing pending on QRZ, Club Log, eQSL for the 1 contact(s) given."] &&
                   [allThereSummary containsString:@"Not checked: LoTW (not configured, or turned off by a hidden setting)."] && ![allThereSummary containsString:@"already synchronized"],
                   [NSString stringWithFormat:@"Nothing pending, LoTW not checked: the summary names both, and never says all is synchronized: %@", allThereSummary]);

        // uploads that outlive the sync's wait: the sync goes on, each wait run out counts as a failure in a row
        // (two stop the service for the rest of the sync), and the sync stays running, and says so, until they
        // end; then they are counted as uploaded
        TX500LogRecord *late1 = SyncTestContact(@"0SZE", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *late2 = SyncTestContact(@"0SZF", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *late3 = SyncTestContact(@"0SZG", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        for (TX500LogRecord *r in @[late1, late2, late3]) AssertTrue([syncLog saveContact:r error:&err], @"Saved a QSO for a late upload");
        cloud.syncUploadWaitSeconds = 0.2;
        SyncHoldCalls = [NSSet setWithObjects:@"0SZE", @"0SZF", nil];
        SyncHoldMarksAtOnce = NO;
        NSUInteger beforeLate = SyncSendCount();
        NSUInteger stillRunningBefore = Occurrences(syncConsole.string, @"2 upload(s) still running");
        __block NSString *lateSummary = nil;
        [cloud syncContacts:@[late1, late2, late3] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; lateSummary = summary;
        }];
        AssertTrue(RunMainLoopUntil(^BOOL { return Occurrences(syncConsole.string, @"2 upload(s) still running") == stillRunningBefore + 1; }),
                   @"Late uploads: the console says that two still run");
        BOOL runningMeanwhile = cloud.syncInProgress && lateSummary == nil && HeldUploads() == 2;
        ReleaseHeldUploads();
        SyncHoldCalls = nil;
        AssertTrue(runningMeanwhile && RunMainLoopUntil(^BOOL { return lateSummary != nil; }) && !cloud.syncInProgress &&
                   SyncSendCount() == beforeLate + 2 && [lateSummary containsString:@"QRZ: 2 uploaded, stopped after 2 failures in a row, 1 left pending."] &&
                   [[syncLog contactWithUUID:late1.uuid].qrzStatus isEqualToString:@"UPLOADED"] && [[syncLog contactWithUUID:late3.uuid].qrzStatus isEqualToString:@"NONE"],
                   [NSString stringWithFormat:@"Late uploads: two waits run out stop QRZ for the third; the sync stays running and says so until they end, then counts them as uploaded (running meanwhile %d): %@", runningMeanwhile, lateSummary]);
        cloud.syncUploadWaitSeconds = 60;
        [syncLog updateCloudStatusForUUID:late3.uuid service:@"QRZ" status:@"UPLOADED" error:nil];

        // "still running" counts the uploads that really still run: of two whose wait ran out, the first has
        // ended (it answers as the second is held), so one
        TX500LogRecord *ended1 = SyncTestContact(@"0SZG", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *ended2 = SyncTestContact(@"0SZH", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        AssertTrue([syncLog saveContact:ended1 error:&err] && [syncLog saveContact:ended2 error:&err], @"Saved two QSOs for the uploads still running");
        cloud.syncUploadWaitSeconds = 0.2;
        SyncHoldCalls = [NSSet setWithObjects:@"0SZG", @"0SZH", nil];
        SyncHoldMarksAtOnce = YES;
        SyncWhenHeld = ^(NSString *callsign) { if ([callsign isEqualToString:@"0SZH"]) AnswerHeldUploadNow(@"0SZG"); };
        NSUInteger oneStillRunning = Occurrences(syncConsole.string, @"] 1 upload(s) still running"), twoStillRunning = Occurrences(syncConsole.string, @"] 2 upload(s) still running");
        __block NSString *endedSummary = nil;
        [cloud syncContacts:@[ended1, ended2] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; endedSummary = summary;
        }];
        AssertTrue(RunMainLoopUntil(^BOOL { return Occurrences(syncConsole.string, @"] 1 upload(s) still running") == oneStillRunning + 1; }) &&
                   Occurrences(syncConsole.string, @"] 2 upload(s) still running") == twoStillRunning,
                   @"Of two uploads whose wait ran out, one has ended: the console says 1 still running, not 2");
        SyncWhenHeld = nil;
        ReleaseHeldUploads();
        SyncHoldCalls = nil;
        AssertTrue(RunMainLoopUntil(^BOOL { return endedSummary != nil; }) && [endedSummary containsString:@"QRZ: 2 uploaded"],
                   [NSString stringWithFormat:@"Both counted when the sync ends: %@", endedSummary]);
        cloud.syncUploadWaitSeconds = 60;

        // a wait that runs out on a QSO its services took: their failures are no longer in a row (R9)
        TX500LogRecord *row1 = SyncTestContact(@"0SZQ", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *row2 = SyncTestContact(@"0SZR", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *row3 = SyncTestContact(@"0SZS", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *row4 = SyncTestContact(@"0SZT", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        for (TX500LogRecord *r in @[row1, row2, row3, row4]) AssertTrue([syncLog saveContact:r error:&err], @"Saved a QSO for failures not in a row");
        cloud.syncUploadWaitSeconds = 0.2;
        SyncFailingCalls = [NSSet setWithObjects:@"0SZQ", @"0SZS", nil];
        SyncHoldCalls = [NSSet setWithObject:@"0SZR"];
        SyncHoldMarksAtOnce = YES;
        __block NSString *notInARowSummary = nil;
        [cloud syncContacts:@[row1, row2, row3, row4] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; notInARowSummary = summary;
        }];
        AssertTrue(RunMainLoopUntil(^BOOL { return HeldUploads() == 1 && [[syncLog contactWithUUID:row4.uuid].qrzStatus isEqualToString:@"UPLOADED"]; }),
                   @"Fail, a late one taken, fail: QRZ is not stopped, and the fourth goes up");
        ReleaseHeldUploads();
        AssertTrue(RunMainLoopUntil(^BOOL { return notInARowSummary != nil; }) && ![notInARowSummary containsString:@"stopped"],
                   [NSString stringWithFormat:@"Failures with a QSO taken between them are not in a row: %@", notInARowSummary]);
        SyncHoldCalls = nil; SyncFailingCalls = nil;
        cloud.syncUploadWaitSeconds = 60;
        for (TX500LogRecord *r in @[row1, row3]) [syncLog updateCloudStatusForUUID:r.uuid service:@"QRZ" status:@"UPLOADED" error:nil];

        // R15 for each service: a QSO that failed on Club Log, never tried on QRZ, is tried on QRZ before two that
        // always fail there
        TX500LogRecord *badThere1 = SyncTestContact(@"0SZU", @"ERROR", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *badThere2 = SyncTestContact(@"0SZV", @"ERROR", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *failedElsewhere = SyncTestContact(@"0SZW", @"NONE", @"ERROR", @"UPLOADED", @"NONE");
        for (TX500LogRecord *r in @[badThere1, badThere2, failedElsewhere]) AssertTrue([syncLog saveContact:r error:&err], @"Saved a QSO for the order per service");
        SyncFailingCalls = [NSSet setWithObjects:@"0SZU", @"0SZV", nil];
        __block NSString *perServiceSummary = nil;
        [cloud syncContacts:@[badThere1, badThere2, failedElsewhere] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; perServiceSummary = summary;
        }];
        AssertTrue(RunMainLoopUntil(^BOOL { return perServiceSummary != nil; }) && [[syncLog contactWithUUID:failedElsewhere.uuid].qrzStatus isEqualToString:@"UPLOADED"],
                   @"Per service: the QSO never tried on QRZ goes up there, although it failed on Club Log before");
        AssertTrue([perServiceSummary hasPrefix:@"Batch sync finished: 1 QSO(s) sent to every service asked, 2 with a service failing."],
                   [NSString stringWithFormat:@"A QSO sent in both passes, to different services, counts once in the headline: %@", perServiceSummary]);
        SyncFailingCalls = nil;
        for (TX500LogRecord *r in @[badThere1, badThere2]) [syncLog updateCloudStatusForUUID:r.uuid service:@"QRZ" status:@"UPLOADED" error:nil];

        // ERROR, a failed try, never replaces UPLOADED or CONFIRMED (R12)
        TX500LogRecord *keepsIts = SyncTestContact(@"0SZX", @"UPLOADED", @"UPLOADED", @"UPLOADED", @"CONFIRMED");
        AssertTrue([syncLog saveContact:keepsIts error:&err] &&
                   [syncLog updateCloudStatusForUUID:keepsIts.uuid service:@"QRZ" status:@"ERROR" error:&err] &&
                   [syncLog updateCloudStatusForUUID:keepsIts.uuid service:@"LoTW" status:@"ERROR" error:&err] &&
                   statuses([syncLog contactWithUUID:keepsIts.uuid], @"UPLOADED", @"UPLOADED", @"UPLOADED", @"CONFIRMED"),
                   @"ERROR never replaces UPLOADED or CONFIRMED");

        // one TQSL at a time within a sync: while LoTW's upload of the first QSO has not ended, the others stay
        // pending on LoTW ("waiting for TQSL"), and the next sync sends them. TQSL is found at /usr/bin/true, so
        // that LoTW counts as configured; the uploads are stood in for, so it is never run. The first one is held
        // as a real one can be before its TQSL starts (a Keychain dialog, say): LoTW was taken when it was decided
        Method discoverTQSL = class_getClassMethod([TX500CloudSyncEngine class], @selector(discoverTQSLBinaryPath));
        IMP realDiscoverTQSL = method_setImplementation(discoverTQSL, imp_implementationWithBlock(^NSString *(id cls) { (void)cls; return @"/usr/bin/true"; }));
        [syncDefaults setObject:@"Test Station" forKey:@"TX500_LoTW_StationLocation"];
        AssertTrue([[cloud enabledConfiguredServices] containsObject:@"LoTW"], @"LoTW configured for this check");
        TX500LogRecord *lotw1 = SyncTestContact(@"0SZY", @"UPLOADED", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *lotw2 = SyncTestContact(@"0SZZ", @"UPLOADED", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *lotw3 = SyncTestContact(@"0SYZ", @"UPLOADED", @"UPLOADED", @"UPLOADED", @"NONE");
        for (TX500LogRecord *r in @[lotw1, lotw2, lotw3]) AssertTrue([syncLog saveContact:r error:&err], @"Saved a QSO pending on LoTW only");
        cloud.syncUploadWaitSeconds = 0.2;
        SyncHoldCalls = [NSSet setWithObject:@"0SZY"];
        SyncHoldMarksAtOnce = YES;
        NSUInteger beforeTQSL = SyncSendCount();
        NSUInteger oneRunning = Occurrences(syncConsole.string, @"1 upload(s) still running");
        __block NSString *tqslSummary = nil;
        [cloud syncContacts:@[lotw1, lotw2, lotw3] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; tqslSummary = summary;
        }];
        AssertTrue(RunMainLoopUntil(^BOOL { return Occurrences(syncConsole.string, @"1 upload(s) still running") == oneRunning + 1; }) &&
                   cloud.syncInProgress && tqslSummary == nil && cloud.tqslRunning == 0 && cloud.tqslBusy &&
                   [[SyncSends subarrayWithRange:NSMakeRange(beforeTQSL, SyncSendCount() - beforeTQSL)] isEqualToArray:@[@"0SZY:LoTW"]],
                   @"While the first QSO's LoTW upload has not ended, no second one starts, though no TQSL runs yet, and the sync stays running");
        ReleaseHeldUploads();
        SyncHoldCalls = nil;
        AssertTrue(RunMainLoopUntil(^BOOL { return tqslSummary != nil; }) && [tqslSummary containsString:@"LoTW: 1 uploaded, waiting for TQSL, 2 left pending."] &&
                   !cloud.syncInProgress && !cloud.tqslBusy,
                   [NSString stringWithFormat:@"The summary counts the two left waiting for TQSL: %@", tqslSummary]);
        NSUInteger beforeNextTQSL = SyncSendCount();
        __block BOOL nextTQSLDone = NO;
        [cloud syncContacts:@[[syncLog contactWithUUID:lotw1.uuid], [syncLog contactWithUUID:lotw2.uuid], [syncLog contactWithUUID:lotw3.uuid]]
                 completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) { (void)uploaded; (void)failed; (void)summary; nextTQSLDone = YES; }];
        AssertTrue(RunMainLoopUntil(^BOOL { return nextTQSLDone; }) &&
                   [[SyncSends subarrayWithRange:NSMakeRange(beforeNextTQSL, SyncSendCount() - beforeNextTQSL)] isEqualToArray:(@[@"0SZZ:LoTW", @"0SYZ:LoTW"])],
                   @"The next sync sends the two left waiting");
        cloud.syncUploadWaitSeconds = 60;
        // for the contacts given, with nothing pending on any of the four: never "all synchronized"
        __block NSString *givenAllThere = nil;
        [cloud syncContacts:@[[syncLog contactWithUUID:lotw1.uuid]] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; givenAllThere = summary;
        }];
        AssertTrue([givenAllThere isEqualToString:@"Nothing pending on QRZ, Club Log, eQSL, LoTW for the 1 contact(s) given."],
                   [NSString stringWithFormat:@"Sync Selected with nothing pending says it of the contacts given: %@", givenAllThere]);
        method_setImplementation(discoverTQSL, realDiscoverTQSL);
        [syncDefaults removeObjectForKey:@"TX500_LoTW_StationLocation"];
        AssertTrue(![[cloud enabledConfiguredServices] containsObject:@"LoTW"], @"LoTW not configured again");
        AssertTrue(![syncConsole.string containsString:@"] 0 upload(s) still running"], @"\"Still running\" is never said of 0 uploads");

        // Sync All with nothing pending anywhere: never "all synchronized" while LoTW was not checked
        for (TX500LogRecord *r in [syncLog allContacts]) for (NSString *service in @[@"QRZ", @"ClubLog", @"eQSL"])
            [syncLog updateCloudStatusForUUID:r.uuid service:service status:@"UPLOADED" error:nil];
        __block NSString *nothingAnywhere = nil;
        [cloud syncContacts:nil completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; nothingAnywhere = summary;
        }];
        AssertTrue([nothingAnywhere isEqualToString:@"Nothing pending on QRZ, Club Log, eQSL. Not checked: LoTW (not configured, or turned off by a hidden setting)."],
                   [NSString stringWithFormat:@"Sync All, nothing pending, LoTW not checked: the summary names both: %@", nothingAnywhere]);

        // the QSOs never tried go first, those that failed before last: two that always fail on QRZ, listed first,
        // stop QRZ in the first sync; in the next, the others are tried before them and go up
        TX500LogRecord *alwaysBad1 = SyncTestContact(@"0SZH", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *alwaysBad2 = SyncTestContact(@"0SZI", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *fine1 = SyncTestContact(@"0SZJ", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *fine2 = SyncTestContact(@"0SZK", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        for (TX500LogRecord *r in @[alwaysBad1, alwaysBad2, fine1, fine2]) AssertTrue([syncLog saveContact:r error:&err], @"Saved a QSO for the order of a sync");
        SyncFailingCalls = [NSSet setWithObjects:@"0SZH", @"0SZI", nil];
        for (int pass = 0; pass < 2; pass++) {
            NSMutableArray<TX500LogRecord *> *inOrder = [NSMutableArray array];
            for (TX500LogRecord *r in @[alwaysBad1, alwaysBad2, fine1, fine2]) [inOrder addObject:[syncLog contactWithUUID:r.uuid]];
            __block BOOL passDone = NO;
            [cloud syncContacts:inOrder completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
                (void)uploaded; (void)failed; (void)summary; passDone = YES;
            }];
            AssertTrue(RunMainLoopUntil(^BOOL { return passDone; }), @"A sync of the four finishes");
            if (pass == 0) AssertTrue([[syncLog contactWithUUID:alwaysBad1.uuid].qrzStatus isEqualToString:@"ERROR"] &&
                                      [[syncLog contactWithUUID:fine1.uuid].qrzStatus isEqualToString:@"NONE"],
                                      @"First sync: the two that fail are marked ERROR, and QRZ stops before the others");
        }
        SyncFailingCalls = nil;
        AssertTrue([[syncLog contactWithUUID:fine1.uuid].qrzStatus isEqualToString:@"UPLOADED"] && [[syncLog contactWithUUID:fine2.uuid].qrzStatus isEqualToString:@"UPLOADED"] &&
                   [[syncLog contactWithUUID:alwaysBad2.uuid].qrzStatus isEqualToString:@"ERROR"],
                   @"Next sync: the QSOs never tried go first, and go up; the two that failed stay ERROR, after them");
        for (TX500LogRecord *r in @[alwaysBad1, alwaysBad2]) [syncLog updateCloudStatusForUUID:r.uuid service:@"QRZ" status:@"UPLOADED" error:nil];

        // a LoTW download that fails is said as a problem of the sync, never as done
        TX500LogRecord *beforeNoNetwork = SyncTestContact(@"0SZL", @"NONE", @"UPLOADED", @"UPLOADED", @"NONE");
        AssertTrue([syncLog saveContact:beforeNoNetwork error:&err], @"Saved a QSO for a sync with LoTW unreachable");
        LoTWUnreachable = YES;
        NSUInteger failedBefore = Occurrences(syncConsole.string, @"Sync All: the LoTW download failed, so no confirmation was marked");
        [syncForm syncAllPending];
        AssertTrue(RunMainLoopUntil(^BOOL { return Occurrences(syncConsole.string, @"Sync All: the LoTW download failed, so no confirmation was marked") == failedBefore + 1; }) &&
                   [syncConsole.string containsString:@"The test has no network."] && !syncForm.syncBusy,
                   @"LoTW unreachable: Sync All says the download failed, with the reason, and the sync ends");
        LoTWUnreachable = NO;

        // an upload never lowers a status: an edit uploaded again keeps CONFIRMED where it was
        TX500LogRecord *confirmedHere = SyncTestContact(@"0SZ8", @"CONFIRMED", @"NONE", @"NONE", @"CONFIRMED");
        AssertTrue([syncLog saveContact:confirmedHere error:&err], @"Saved a QSO confirmed on QRZ and LoTW");
        [cloud uploadContactImmediately:confirmedHere completion:nil];
        AssertTrue([syncLog updateCloudStatusForUUID:confirmedHere.uuid service:@"LoTW" status:@"UPLOADED" error:&err] &&
                   statuses([syncLog contactWithUUID:confirmedHere.uuid], @"CONFIRMED", @"UPLOADED", @"UPLOADED", @"CONFIRMED"),
                   @"An upload never lowers a status: CONFIRMED stays CONFIRMED, the others are UPLOADED");

        // FT8 and CW logged on their own: their upload marks the row saved, and the next sync sends nothing for them
        TX500FT8AutoEngine *ft8Auto = [[TX500FT8AutoEngine alloc] init];
        TX500FT8LoggedQSO *ft8Done = [TX500FT8LoggedQSO new];
        ft8Done.callsign = @"0SZ9"; ft8Done.band = @"20m"; ft8Done.freqHz = 14074000; ft8Done.mode = @"FT8";
        ft8Done.rstSent = @"-10"; ft8Done.rstRcvd = @"-12"; ft8Done.timestamp = [NSDate dateWithTimeIntervalSince1970:1791627300];
        [ft8Auto logCompletedQSOToADIF:ft8Done];
        TX500CWQSOAssistant *cwAuto = [TX500CWQSOAssistant new];
        cwAuto.activeTargetCallsign = @"0SZA"; cwAuto.currentFrequencyHz = 7030000; cwAuto.currentBand = @"40m";
        [cwAuto logCurrentQSO];
        __block TX500LogRecord *ft8Row = nil, *cwRow = nil;
        AssertTrue(RunMainLoopUntil(^BOOL {
            for (TX500LogRecord *r in syncLog.allContacts) {
                if ([r.callsign isEqualToString:@"0SZ9"]) ft8Row = r;
                if ([r.callsign isEqualToString:@"0SZA"]) cwRow = r;
            }
            return ft8Row && cwRow && [ft8Row.eqslStatus isEqualToString:@"UPLOADED"] && [cwRow.eqslStatus isEqualToString:@"UPLOADED"];
        }), @"FT8 and CW logged on their own: each row saved is uploaded");
        AssertTrue(statuses(ft8Row, @"UPLOADED", @"UPLOADED", @"UPLOADED", @"NONE") && statuses(cwRow, @"UPLOADED", @"UPLOADED", @"UPLOADED", @"NONE") &&
                   [ft8Row.timeOn isEqualToString:@"101500"] && [ft8Row.qsoDate isEqualToString:@"20261010"],
                   [NSString stringWithFormat:@"FT8 and CW: the statuses land on the Logbook rows, which keep the QSO's own time (FT8 %@ %@)", ft8Row.qsoDate, ft8Row.timeOn]);
        NSUInteger beforeAuto = SyncSendCount();
        __block BOOL autoDone = NO;
        [cloud syncContacts:@[ft8Row, cwRow] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; (void)summary; autoDone = YES;
        }];
        AssertTrue(RunMainLoopUntil(^BOOL { return autoDone; }) && SyncSendCount() == beforeAuto, @"FT8 and CW: the next sync sends them nothing");

        // an ADIF file with QSOs already here brings their upload statuses up, never down, and nothing else
        TX500LogRecord *hereNone = SyncTestContact(@"0SZB", @"NONE", @"NONE", @"NONE", @"NONE");
        TX500LogRecord *hereSent = SyncTestContact(@"0SZC", @"UPLOADED", @"NONE", @"NONE", @"CONFIRMED");
        AssertTrue([syncLog saveContact:hereNone error:&err] && [syncLog saveContact:hereSent error:&err], @"Saved two QSOs that the file has too");
        NSString *againPath = [[NSString stringWithUTF8String:testRoot] stringByAppendingPathComponent:@"sync-import-again.adi"];
        NSString *againADIF = @"<ADIF_VER:5>3.1.7 <EOH>\n"
            @"<CALL:4>0SZB <QSO_DATE:8>20261010 <TIME_ON:6>101500 <BAND:3>20m <MODE:3>FT8 <QRZCOM_QSO_UPLOAD_STATUS:1>Y <LOTW_QSL_RCVD:1>Y <NAME:3>Bob <EOR>\n"
            @"<CALL:4>0SZC <QSO_DATE:8>20261010 <TIME_ON:6>101500 <BAND:3>20m <MODE:3>FT8 <QRZCOM_QSO_UPLOAD_STATUS:1>N <LOTW_QSL_SENT:1>Y <CLUBLOG_QSO_UPLOAD_STATUS:1>Y <EOR>\n";
        NSInteger againDuplicates = -1, againUpdates = -1;
        AssertTrue([againADIF writeToFile:againPath atomically:YES encoding:NSUTF8StringEncoding error:&err], @"Wrote the file again");
        DrainMainQueue();
        __block NSUInteger importNotices = 0;
        id importWatch = [[NSNotificationCenter defaultCenter] addObserverForName:TX500LogbookDidChangeNotification object:syncLog queue:nil
                                                                         usingBlock:^(NSNotification *note) { (void)note; importNotices++; }];
        NSInteger againImported = [syncLog importADIFFromFileURL:[NSURL fileURLWithPath:againPath] duplicatesCount:&againDuplicates statusUpdatesCount:&againUpdates error:&err];
        DrainMainQueue();
        NSUInteger noticesOfImport = importNotices;
        NSInteger thirdUpdates = -1;
        [syncLog importADIFFromFileURL:[NSURL fileURLWithPath:againPath] duplicatesCount:NULL statusUpdatesCount:&thirdUpdates error:&err];
        DrainMainQueue();
        [[NSNotificationCenter defaultCenter] removeObserver:importWatch];
        AssertTrue(noticesOfImport == 1 && thirdUpdates == 0 && importNotices == 1,
                   [NSString stringWithFormat:@"An import that brings 3 statuses up tells the Logbook once (%lu); the same file again changes nothing and tells nothing (%ld, %lu)",
                    (unsigned long)noticesOfImport, (long)thirdUpdates, (unsigned long)importNotices]);
        TX500LogRecord *noneNow = [syncLog contactWithUUID:hereNone.uuid], *sentNow = [syncLog contactWithUUID:hereSent.uuid];
        AssertTrue(againImported == 0 && againDuplicates == 2 && againUpdates == 3 &&
                   statuses(noneNow, @"UPLOADED", @"NONE", @"NONE", @"CONFIRMED") && noneNow.name.length == 0 &&
                   statuses(sentNow, @"UPLOADED", @"UPLOADED", @"NONE", @"CONFIRMED"),
                   [NSString stringWithFormat:@"Import again: a NONE with Y in the file is UPLOADED or CONFIRMED; an UPLOADED with N stays UPLOADED, a CONFIRMED with SENT Y stays CONFIRMED; nothing else changes (%ld imported, %ld duplicates, %ld updates)",
                    (long)againImported, (long)againDuplicates, (long)againUpdates]);
        NSUInteger beforeAgainSync = SyncSendCount();
        __block BOOL againSyncDone = NO;
        [cloud syncContacts:@[noneNow, sentNow] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) {
            (void)uploaded; (void)failed; (void)summary; againSyncDone = YES;
        }];
        AssertTrue(RunMainLoopUntil(^BOOL { return againSyncDone; }) &&
                   [[SyncSends subarrayWithRange:NSMakeRange(beforeAgainSync, SyncSendCount() - beforeAgainSync)] isEqualToArray:(@[@"0SZB:ClubLog,eQSL", @"0SZC:eQSL"])],
                   @"After the import, the sync sends them only where they are still pending");
        StopRecordingSyncSends();
        StopStandingInForLoTW();
        TX500RemoveSecret(@"TX500_LoTW_Password"); TX500RemoveSecret(@"TX500_ClubLog_Password");
        [syncDefaults removeObjectForKey:@"TX500_ClubLog_Callsign"];
        TX500RemoveSecret(@"TX500_QRZ_APIKey"); TX500RemoveSecret(@"TX500_ClubLog_APIKey"); TX500RemoveSecret(@"TX500_EQSL_Password");
        [syncDefaults removeObjectForKey:@"TX500_ClubLog_Email"];
        [syncDefaults removeObjectForKey:@"TX500_EQSL_Username"];
        [syncDefaults removeObjectForKey:@"TX500_LoTW_Username"];

        // the TQSL paths the app really runs, LoTW Upload… (signAndUploadContactsToLoTW) and the upload after a QSO,
        // with a stand-in tqsl that ends, with an error so that nothing is marked, when the test writes its file
        // (or after 30 s). Test mode is off only while each call starts (both look at it there, and only there),
        // and by now LoTW is the only service configured, so nothing else is asked
        NSString *liveRoot = [NSString stringWithUTF8String:testRoot];
        NSString *(^standInTQSL)(NSString *) = ^NSString *(NSString *name) {
            NSString *path = [liveRoot stringByAppendingPathComponent:[name stringByAppendingString:@".sh"]];
            NSString *go = [liveRoot stringByAppendingPathComponent:[name stringByAppendingString:@".go"]];
            NSString *script = [NSString stringWithFormat:@"#!/bin/sh\ni=0\nwhile [ ! -e '%@' ] && [ $i -lt 600 ]; do sleep 0.05; i=$((i+1)); done\nexit 1\n", go];
            BOOL written = [script writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil] &&
                           [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @0755} ofItemAtPath:path error:nil];
            return written ? path : nil;
        };
        BOOL (^letStandInEnd)(NSString *) = ^BOOL(NSString *name) {
            return [@"go" writeToFile:[liveRoot stringByAppendingPathComponent:[name stringByAppendingString:@".go"]] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        };
        void (^withTestModeOff)(void (^)(void)) = ^(void (^call)(void)) {
            setenv("TX500_TEST_MODE", "0", 1);
            call();
            setenv("TX500_TEST_MODE", "1", 1);
        };
        __block NSString *standInPath = standInTQSL(@"stand-in-tqsl-batch");
        method_setImplementation(discoverTQSL, imp_implementationWithBlock(^NSString *(id cls) { (void)cls; return standInPath; }));
        [syncDefaults setObject:@"Test Station" forKey:@"TX500_LoTW_StationLocation"];
        AssertTrue(standInPath && [[cloud enabledConfiguredServices] isEqualToArray:@[@"LoTW"]], @"Live TQSL paths: a stand-in tqsl, and LoTW the only service configured");
        TX500LogRecord *live1 = SyncTestContact(@"0SX1", @"UPLOADED", @"UPLOADED", @"UPLOADED", @"NONE");
        TX500LogRecord *live2 = SyncTestContact(@"0SX2", @"UPLOADED", @"UPLOADED", @"UPLOADED", @"NONE");
        for (TX500LogRecord *r in @[live1, live2]) AssertTrue([syncLog saveContact:r error:&err], @"Saved a QSO pending on LoTW for the live TQSL paths");
        // LoTW taken, here by the test, as by an upload whose TQSL has not started yet: with no TQSL running, the
        // upload after a QSO leaves LoTW pending, and starts none
        AssertTrue([cloud takeLoTW] && cloud.tqslRunning == 0 && cloud.tqslBusy, @"The test takes LoTW, with no TQSL running");
        __block NSString *whileTakenSummary = nil;
        withTestModeOff(^{
            [cloud uploadContact:live1 toServices:nil completion:^(BOOL ok, NSString *summary) { (void)ok; whileTakenSummary = summary; }];
        });
        AssertTrue(RunMainLoopUntil(^BOOL { return whileTakenSummary != nil; }) && cloud.tqslRunning == 0 &&
                   [whileTakenSummary containsString:@"LoTW left pending for 0SX1: TQSL is running, or about to start."],
                   [NSString stringWithFormat:@"With LoTW taken and no TQSL running yet, the upload after a QSO leaves LoTW pending, and starts none: %@", whileTakenSummary]);
        [cloud giveBackLoTW];
        AssertTrue(!cloud.tqslBusy && !cloud.syncInProgress, @"LoTW given back by the test");
        NSString *tqslRefusal = @"TQSL is running (a LoTW upload): nothing was sent or downloaded; try again when it ends.";
        NSString *syncRefusal = @"A sync is already running: nothing was sent or downloaded.";
        __block BOOL batchDone = NO, batchOK = YES;
        withTestModeOff(^{
            [cloud signAndUploadContactsToLoTW:@[live1] completion:^(BOOL success, NSString *message) { (void)message; batchOK = success; batchDone = YES; }];
        });
        AssertTrue(RunMainLoopUntil(^BOOL { return cloud.tqslRunning == 1; }) && cloud.tqslBusy && cloud.syncInProgress && !batchDone,
                   @"LoTW Upload… counts its TQSL while it runs");
        NSUInteger tqslRefusedBefore = Occurrences(syncConsole.string, tqslRefusal), syncRefusedBefore = Occurrences(syncConsole.string, syncRefusal);
        [syncForm syncAllPending];
        AssertTrue(Occurrences(syncConsole.string, tqslRefusal) == tqslRefusedBefore + 1 && Occurrences(syncConsole.string, syncRefusal) == syncRefusedBefore,
                   @"Sync All pressed while LoTW Upload…'s TQSL runs does nothing, and says that TQSL runs, not a sync");
        __block NSString *waitingSummary = nil;
        [cloud syncContacts:@[live2] completion:^(NSInteger uploaded, NSInteger failed, NSString *summary) { (void)uploaded; (void)failed; waitingSummary = summary; }];
        AssertTrue(RunMainLoopUntil(^BOOL { return waitingSummary != nil; }) && [waitingSummary containsString:@"LoTW: waiting for TQSL, 1 left pending."] &&
                   cloud.tqslRunning == 1, [NSString stringWithFormat:@"A sync while LoTW Upload…'s TQSL runs sends nothing to LoTW: %@", waitingSummary]);
        __block NSString *afterQSOSummary = nil, *ofASyncSummary = nil;
        withTestModeOff(^{
            [cloud uploadContact:live2 toServices:nil completion:^(BOOL ok, NSString *summary) { (void)ok; afterQSOSummary = summary; }];
            [cloud uploadContact:live2 toServices:@[@"LoTW"] completion:^(BOOL ok, NSString *summary) { (void)ok; ofASyncSummary = summary; }];
        });
        AssertTrue(RunMainLoopUntil(^BOOL { return afterQSOSummary && ofASyncSummary; }) && cloud.tqslRunning == 1 &&
                   [afterQSOSummary containsString:@"LoTW left pending for 0SX2: TQSL is running, or about to start."] &&
                   [ofASyncSummary containsString:@"LoTW left pending for 0SX2: TQSL is running, or about to start."],
                   [NSString stringWithFormat:@"While LoTW Upload…'s TQSL runs, the upload after a QSO and a sync's upload leave LoTW pending, and start none: %@ | %@",
                    afterQSOSummary, ofASyncSummary]);
        AssertTrue(letStandInEnd(@"stand-in-tqsl-batch") && RunMainLoopUntil(^BOOL { return batchDone; }) && !batchOK &&
                   cloud.tqslRunning == 0 && !cloud.tqslBusy && !cloud.syncInProgress, @"When LoTW Upload…'s TQSL ends, the count is back to 0");
        // the upload after a QSO runs its own TQSL (performLoTWUpload), counted, and a second one decided at once
        // leaves LoTW pending (taken by the first, or its TQSL running: the check above holds the first case)
        standInPath = standInTQSL(@"stand-in-tqsl-qso");
        __block NSString *firstQSOSummary = nil, *secondQSOSummary = nil;
        withTestModeOff(^{
            [cloud uploadContact:live2 toServices:nil completion:^(BOOL ok, NSString *summary) { (void)ok; firstQSOSummary = summary; }];
            [cloud uploadContact:live1 toServices:nil completion:^(BOOL ok, NSString *summary) { (void)ok; secondQSOSummary = summary; }];
        });
        AssertTrue(standInPath && RunMainLoopUntil(^BOOL { return secondQSOSummary != nil && cloud.tqslRunning == 1; }) && cloud.tqslBusy && !firstQSOSummary &&
                   [secondQSOSummary containsString:@"LoTW left pending for 0SX1: TQSL is running, or about to start."],
                   [NSString stringWithFormat:@"The upload after a QSO counts its TQSL; a second one decided at once leaves LoTW pending: %@", secondQSOSummary]);
        AssertTrue(letStandInEnd(@"stand-in-tqsl-qso") && RunMainLoopUntil(^BOOL { return firstQSOSummary != nil; }) &&
                   cloud.tqslRunning == 0 && !cloud.tqslBusy && !cloud.syncInProgress && [[syncLog contactWithUUID:live2.uuid].lotwStatus isEqualToString:@"NONE"],
                   [NSString stringWithFormat:@"When that TQSL ends (with an error), LoTW is free again, and nothing is marked: %@", firstQSOSummary]);
        // a TQSL that cannot start (no such file) is not left counted, nor LoTW taken
        standInPath = [liveRoot stringByAppendingPathComponent:@"no-such-folder/tqsl"];
        __block BOOL noStartDone = NO, noStartOK = YES;
        __block NSString *noStartSummary = nil;
        withTestModeOff(^{
            [cloud signAndUploadContactsToLoTW:@[live1] completion:^(BOOL success, NSString *message) { (void)message; noStartOK = success; noStartDone = YES; }];
        });
        AssertTrue(RunMainLoopUntil(^BOOL { return noStartDone; }) && !noStartOK && cloud.tqslRunning == 0 && !cloud.syncInProgress,
                   @"LoTW Upload… with a TQSL that cannot start fails, and leaves nothing counted");
        withTestModeOff(^{
            [cloud uploadContact:live1 toServices:nil completion:^(BOOL ok, NSString *summary) { (void)ok; noStartSummary = summary; }];
        });
        AssertTrue(RunMainLoopUntil(^BOOL { return noStartSummary != nil; }) && cloud.tqslRunning == 0 && !cloud.tqslBusy && !cloud.syncInProgress,
                   [NSString stringWithFormat:@"The upload after a QSO with a TQSL that cannot start leaves nothing counted, nor LoTW taken: %@", noStartSummary]);
        method_setImplementation(discoverTQSL, realDiscoverTQSL);
        [syncDefaults removeObjectForKey:@"TX500_LoTW_StationLocation"];
        AssertTrue([cloud enabledConfiguredServices].count == 0, @"No service configured after the live TQSL paths");
        NSLog(@"PASS: Sync All and Sync Selected send each QSO only where it is still pending; Sync All then downloads the LoTW confirmations.");

        // 12. WebKit 2FA Session Persistence Helpers
        [TX500WebAuthenticatorController clearSessionForService:TX500AuthServiceQRZ];
        AssertTrue(![TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceQRZ], @"QRZ session cleared initially");

        // Manually simulate saving session cookies into NSUserDefaults
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        [ud setObject:@"session_token=mock12345; auth_sig=abcdef" forKey:@"TX500_QRZ_2FASessionCookies"];
        [ud setBool:YES forKey:@"TX500_QRZ_2FA_Active"];
        [ud synchronize];

        AssertTrue([TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceQRZ], @"QRZ session active after saving");
        NSString *cookieHeader = [TX500WebAuthenticatorController cookieHeaderForService:TX500AuthServiceQRZ];
        AssertTrue([cookieHeader containsString:@"session_token=mock12345"], @"Cookie header contains mock token");

        [TX500WebAuthenticatorController clearSessionForService:TX500AuthServiceQRZ];
        AssertTrue(![TX500WebAuthenticatorController hasSavedSessionForService:TX500AuthServiceQRZ], @"QRZ session cleared successfully");
        NSLog(@"PASS: WebKit 2FA session persistence & cookie header generation passed.");

        // 13. TQSL Fallback to Preferences (.p12 / Station Location)
        [ud setObject:@"Field Station" forKey:@"TX500_LoTW_StationLocation"];
        [ud setObject:@"CertSecretPass" forKey:@"TX500_LoTW_CertificatePassword"];
        [ud synchronize];

        NSArray<NSString *> *fallbackArgs = [TX500CloudSyncEngine buildTQSLArgumentsForADIFPath:@"/tmp/fallback.adi"
                                                                                       location:nil
                                                                                       password:nil];
        AssertTrue([fallbackArgs containsObject:@"Field Station"], @"Fallback to saved station location");
        AssertTrue([fallbackArgs containsObject:@"CertSecretPass"], @"Fallback to saved certificate password");
        [ud removeObjectForKey:@"TX500_LoTW_StationLocation"];
        [ud removeObjectForKey:@"TX500_LoTW_CertificatePassword"];
        [ud synchronize];
        NSLog(@"PASS: TQSL CLI arguments fallback to saved .p12/station preferences passed.");

        // 14. Maidenhead Grid Conversion & Great Circle Telemetry Math
        double lat = 0.0, lon = 0.0;
        BOOL gridValid = [TX500LogbookManager coordinatesForGrid:@"FN31pr" latitude:&lat longitude:&lon];
        AssertTrue(gridValid, @"FN31pr is a valid Maidenhead grid");
        AssertTrue(lat >= 41.0 && lat <= 42.5, @"FN31pr latitude in expected range ~41.7");
        AssertTrue(lon >= -73.5 && lon <= -72.0, @"FN31pr longitude in expected range ~-72.7");

        double distKm = [TX500LogbookManager distanceKmFromGrid:@"KM35" toGrid:@"FN31pr"];
        AssertTrue(distKm > 8000.0 && distKm < 11000.0, @"Haversine distance Tehran to Connecticut ~9,500 km");

        double bearing = [TX500LogbookManager bearingDegreesFromGrid:@"KM35" toGrid:@"FN31pr"];
        AssertTrue(bearing >= 300.0 && bearing <= 340.0, @"Initial azimuth forward bearing ~315-325 degrees (NW)");

        NSString *telemetry = [TX500LogbookManager formattedBearingAndDistanceFromGrid:@"KM35" toGrid:@"FN31pr"];
        AssertTrue([telemetry containsString:@"km"] || [telemetry containsString:@"mi"], @"Telemetry string contains distance unit");
        AssertTrue([telemetry containsString:@"°"], @"Telemetry string contains degrees symbol");
        NSLog(@"PASS: Maidenhead Great Circle math (Haversine & Forward Azimuth) verified.");

        // 15. Dupe Detection & Worked Before Intelligence
        NSDictionary<NSString *, id> *dupeSame = [mgr dupeStatusForCallsign:@"W1AW" band:@"20m" mode:@"USB"];
        AssertTrue([dupeSame[@"status"] isEqualToString:@"DUPE"], @"Detected DUPE on 20m USB");
        AssertTrue([dupeSame[@"isDupe"] boolValue] == YES, @"isDupe flag is YES");

        NSDictionary<NSString *, id> *dupeOther = [mgr dupeStatusForCallsign:@"W1AW" band:@"40m" mode:@"CW"];
        AssertTrue([dupeOther[@"status"] isEqualToString:@"WORKED"], @"Detected WORKED BEFORE on different band/mode");
        AssertTrue([dupeOther[@"isWorkedBefore"] boolValue] == YES, @"isWorkedBefore flag is YES");
        AssertTrue([dupeOther[@"isDupe"] boolValue] == NO, @"isDupe flag is NO on different band");

        NSDictionary<NSString *, id> *dupeNew = [mgr dupeStatusForCallsign:@"K3LR" band:@"20m" mode:@"USB"];
        AssertTrue([dupeNew[@"status"] isEqualToString:@"NEW"], @"New callsign returns NEW for dupe status");
        AssertTrue([dupeNew[@"isWorkedBefore"] boolValue] == NO, @"isWorkedBefore is NO for new callsign");

        NSArray<TX500LogRecord *> *w1awContacts = [mgr contactsForCallsign:@"W1AW"];
        AssertTrue(w1awContacts.count == 1, @"Found 1 past QSO with W1AW");
        NSLog(@"PASS: Dupe check & worked-before intelligence verified.");

        // 16. Field Ops (POTA, SOTA, IOTA) Tags, Parsing & SQLite Migration
        TX500LogRecord *fieldRec = [[TX500LogRecord alloc] init];
        fieldRec.callsign = @"W6/K6ARK";
        fieldRec.qsoDate = @"20260921";
        fieldRec.timeOn = @"140000";
        fieldRec.band = @"20m";
        fieldRec.mode = @"CW";
        fieldRec.theirPotaRef = @"K-5678";
        fieldRec.myPotaRef = @"K-1234";
        fieldRec.theirSotaRef = @"W6/SC-001";
        fieldRec.mySotaRef = @"W6/NC-002";
        fieldRec.iotaRef = @"NA-001";
        fieldRec.cqZone = @"03";
        fieldRec.ituZone = @"06";
        fieldRec.dxccCode = @"291";
        fieldRec.state = @"CA";
        fieldRec.country = @"United States";

        BOOL fieldSaved = [mgr saveContact:fieldRec error:&err];
        AssertTrue(fieldSaved, @"Saved field ops contact to SQLite");

        TX500LogRecord *fetchedField = [mgr contactWithUUID:fieldRec.uuid];
        AssertTrue([fetchedField.theirPotaRef isEqualToString:@"K-5678"], @"theirPotaRef matches");
        AssertTrue([fetchedField.myPotaRef isEqualToString:@"K-1234"], @"myPotaRef matches");
        AssertTrue([fetchedField.theirSotaRef isEqualToString:@"W6/SC-001"], @"theirSotaRef matches");
        AssertTrue([fetchedField.iotaRef isEqualToString:@"NA-001"], @"iotaRef matches");
        AssertTrue([fetchedField.cqZone isEqualToString:@"03"], @"cqZone matches");

        NSString *fieldADIF = [fieldRec adifRecordString];
        AssertTrue([fieldADIF containsString:@"<SIG:4>POTA"], @"ADIF contains SIG POTA");
        AssertTrue([fieldADIF containsString:@"<SIG_INFO:6>K-5678"], @"ADIF contains SIG_INFO K-5678");
        AssertTrue([fieldADIF containsString:@"<MY_SIG_INFO:6>K-1234"], @"ADIF contains MY_SIG_INFO K-1234");
        AssertTrue([fieldADIF containsString:@"<SOTA_REF:9>W6/SC-001"], @"ADIF contains SOTA_REF");
        AssertTrue([fieldADIF containsString:@"<IOTA:6>NA-001"], @"ADIF contains IOTA");
        AssertTrue([fieldADIF containsString:@"<CQZ:2>03"], @"ADIF contains CQZ");

        TX500LogRecord *parsedField = [TX500LogRecord recordFromADIFRecordText:fieldADIF];
        AssertTrue([parsedField.theirPotaRef isEqualToString:@"K-5678"], @"Parsed theirPotaRef");
        AssertTrue([parsedField.myPotaRef isEqualToString:@"K-1234"], @"Parsed myPotaRef");
        AssertTrue([parsedField.theirSotaRef isEqualToString:@"W6/SC-001"], @"Parsed theirSotaRef");
        AssertTrue([parsedField.iotaRef isEqualToString:@"NA-001"], @"Parsed iotaRef");
        NSLog(@"PASS: Field Ops (POTA, SOTA, IOTA) ADIF 3.1 & SQLite persistence verified.");

        // 17. Award Tracking Engine (DXCC, WAS, WAZ, POTA, SOTA, IOTA)
        NSDictionary<NSString *, NSNumber *> *awardStats = [mgr awardStatistics];
        AssertTrue(awardStats[@"dxcc_worked"] != nil, @"dxcc_worked metric present");
        AssertTrue([awardStats[@"dxcc_worked"] integerValue] >= 1, @"At least 1 DXCC worked");
        AssertTrue([awardStats[@"was_worked"] integerValue] >= 2, @"At least 2 US States worked (CT and CA)");
        AssertTrue([awardStats[@"pota_qsos"] integerValue] >= 1, @"At least 1 POTA QSO logged");
        AssertTrue([awardStats[@"sota_qsos"] integerValue] >= 1, @"At least 1 SOTA QSO logged");
        AssertTrue([awardStats[@"iota_qsos"] integerValue] >= 1, @"At least 1 IOTA QSO logged");
        NSLog(@"PASS: Award Tracking Engine statistics verified.");

        // 18. LoTW TQSL Direct Invocation Method
        __block BOOL lotwCalled = NO;
        __block NSString *lotwMsg = nil;
        [[TX500CloudSyncEngine sharedEngine] signAndUploadContactsToLoTW:@[fieldRec] completion:^(BOOL success, NSString *message) {
            lotwCalled = YES;
            lotwMsg = message;
        }];
        AssertTrue(lotwCalled, @"signAndUploadContactsToLoTW completion called");
        AssertTrue(lotwMsg.length > 0, @"signAndUploadContactsToLoTW returned message");
        NSLog(@"PASS: Direct TQSL LoTW signing invocation tested successfully.");

        // Cleanup temporary test SQLite database
        [mgr closeDatabase];
        [[NSFileManager defaultManager] removeItemAtURL:dbURL error:nil];
        NSString *walPath = [tempDBPath stringByAppendingString:@"-wal"];
        NSString *shmPath = [tempDBPath stringByAppendingString:@"-shm"];
        [[NSFileManager defaultManager] removeItemAtPath:walPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:shmPath error:nil];
        [[NSFileManager defaultManager] removeItemAtPath:[NSString stringWithUTF8String:testRoot] error:nil];

        NSLog(@"ALL 18 LOGBOOK & CLOUD ECOSYSTEM TESTS PASSED SUCCESSFULLY!");
    }
    return 0;
}
