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
#import "TX500LogbookManager.h"
#import "TX500CallsignLookupService.h"
#import "TX500CloudSyncEngine.h"
#import "TX500FT8AutoEngine.h"
#import "TX500CWQSOAssistant.h"
#import "TX500WebAuthenticatorController.h"
#import "TX500CloudSettingsController.h"
#import "TX500LogbookController.h"

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
