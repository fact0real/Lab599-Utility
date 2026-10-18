//
//  TX500CloudSyncEngine.m
//  Lab599 Utility
//
//  Zero-Click Amateur Radio Cloud Synchronization Engine
//

#import "TX500SecretStore.h"
#include <stdlib.h>
#import "TX500CloudSyncEngine.h"
#import "TX500WebAuthenticatorController.h"

NSString * const TX500CloudSyncStatusDidChangeNotification = @"TX500CloudSyncStatusDidChangeNotification";

static BOOL TX500CloudResponseMatchesEndpoint(NSURLResponse *response, NSString *endpoint) {
    return [response isKindOfClass:NSHTTPURLResponse.class] &&
        ((NSHTTPURLResponse *)response).statusCode == 200 &&
        [response.URL.absoluteString isEqualToString:endpoint];
}

BOOL TX500ClubLogResponseIsSuccess(NSHTTPURLResponse *response, NSData *data) {
    if (![response isKindOfClass:NSHTTPURLResponse.class] || response.statusCode != 200 ||
        ![response.URL.scheme.lowercaseString isEqualToString:@"https"] ||
        ![response.URL.host.lowercaseString isEqualToString:@"clublog.org"] ||
        ![response.URL.path isEqualToString:@"/realtime.php"] ||
        response.URL.port != nil || response.URL.user != nil ||
        response.URL.password != nil || response.URL.query != nil ||
        response.URL.fragment != nil || !data.length) return NO;
    NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!body) return NO;
    NSString *trimmed = [body stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    for (NSString *ack in @[@"OK", @"QSO OK", @"QSO Duplicate", @"QSO Modified"]) {
        if ([trimmed caseInsensitiveCompare:ack] == NSOrderedSame) return YES;
    }
    return NO;
}

BOOL TX500QRZResponseIsSuccess(NSURLResponse *response, NSString *text) {
    // a duplicate is an upload QRZ already has: accepted, whatever the case of the word
    return TX500CloudResponseMatchesEndpoint(response, @"https://logbook.qrz.com/api") &&
        ([text containsString:@"RESULT=OK"] || [text.uppercaseString containsString:@"DUPLICATE"]);
}

static BOOL TX500CloudExternalSideEffectsAreDisabled(void) {
    NSString *value = NSProcessInfo.processInfo.environment[@"TX500_TEST_MODE"];
    return value.boolValue;
}

@implementation TX500CloudUploadItem
- (instancetype)init {
    self = [super init];
    if (self) {
        _timestamp = [NSDate date];
        _services = @[];
        _message = @"";
    }
    return self;
}
@end

@interface TX500CloudSyncEngine () <NSURLSessionTaskDelegate>

@property (nonatomic, copy, readwrite) NSString *lastStatusMessage;
@property (nonatomic, assign, readwrite) BOOL isUploading;
@property (nonatomic, strong) NSMutableArray<TX500CloudUploadItem *> *uploadHistory;
@property (nonatomic, strong) NSURLSession *urlSession;
@property (nonatomic, strong) dispatch_queue_t syncQueue;
@property (nonatomic, assign) BOOL syncRunning;   // under @synchronized (self)
@property (nonatomic, assign) NSInteger tqslRuns;   // TQSL processes running now, under @synchronized (self)
@property (nonatomic, assign) NSInteger lotwTaken;   // LoTW uploads decided on and not ended (their TQSL may not run yet), the same

@end

@implementation TX500CloudSyncEngine

+ (instancetype)sharedEngine {
    static TX500CloudSyncEngine *sInstance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sInstance = [[TX500CloudSyncEngine alloc] init];
    });
    return sInstance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _uploadHistory = [NSMutableArray array];
        _lastStatusMessage = @"Cloud Ecosystem Ready";
        _syncQueue = dispatch_queue_create("ir.factoreal.tx500.cloudsync", DISPATCH_QUEUE_SERIAL);
        _syncUploadWaitSeconds = 60.0;
        
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 20.0;
        config.timeoutIntervalForResource = 30.0;
        _urlSession = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:nil];
    }
    return self;
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
             completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    (void)session; (void)task; (void)response; (void)request;
    // Upload bodies contain credentials. Never replay one to a redirected URL.
    completionHandler(nil);
}

- (NSArray<TX500CloudUploadItem *> *)recentUploads {
    __block NSArray *arr = nil;
    dispatch_sync(self.syncQueue, ^{
        arr = [self.uploadHistory copy];
    });
    return arr ?: @[];
}

#pragma mark - ADIF & TQSL Helpers

+ (NSString *)buildSingleRecordADIF:(TX500LogRecord *)record {
    NSMutableString *outStr = [NSMutableString string];
    [outStr appendString:@"<ADIF_VER:5>3.1.4 <PROGRAMID:14>Lab599 Utility <EOH>\n"];
    [outStr appendString:[record adifRecordString]];
    return outStr;
}

// Upload-only projection. Manual export and the database keep the original record.
+ (NSString *)uploadADIFForRecord:(TX500LogRecord *)record service:(NSString *)service {
    return [self filteredUploadRecord:[record adifRecordString] service:service defaults:NSUserDefaults.standardUserDefaults];
}

+ (NSString *)filteredUploadRecord:(NSString *)text service:(NSString *)service defaults:(NSUserDefaults *)defaults {
    BOOL lotw = [service isEqualToString:@"LoTW"];
    if (![@[@"QRZ", @"ClubLog", @"eQSL", @"LoTW"] containsObject:service]) return @"<EOR>\n";
    NSString *core = lotw ?
        @"CALL QSO_DATE TIME_ON BAND MODE SUBMODE FREQ STATION_CALLSIGN OPERATOR MY_GRIDSQUARE MY_STATE MY_CNTY MY_CQ_ZONE MY_ITU_ZONE MY_IOTA" :
        @"CALL QSO_DATE TIME_ON TIME_OFF BAND FREQ MODE SUBMODE RST_SENT RST_RCVD TX_PWR COUNTRY DXCC CQZ ITUZ IOTA SIG SIG_INFO STATE SOTA_REF GRIDSQUARE STATION_CALLSIGN OPERATOR MY_GRIDSQUARE MY_STATE MY_CNTY MY_COUNTRY MY_CQ_ZONE MY_ITU_ZONE MY_IOTA MY_SIG MY_SIG_INFO MY_SOTA_REF";
    NSMutableSet *allowed = [NSMutableSet setWithArray:[core componentsSeparatedByString:@" "]];
    if (!lotw && [defaults boolForKey:@"TX500_UploadShareNameAndQTH"])
        [allowed addObjectsFromArray:@[@"NAME", @"QTH", @"MY_NAME", @"MY_CITY", @"MY_RIG", @"MY_ANTENNA"]];
    BOOL precise = !lotw && [defaults boolForKey:@"TX500_UploadShareContactDetails"];
    if (precise) [allowed addObject:@"EMAIL"];
    if (!lotw && [defaults boolForKey:@"TX500_UploadShareFreeText"]) [allowed addObject:@"COMMENT"];
    NSData *input = [text dataUsingEncoding:NSUTF8StringEncoding];
    const unsigned char *bytes = input.bytes;
    NSMutableString *out = [NSMutableString string];
    NSMutableSet *seen = [NSMutableSet set];
    NSUInteger cursor = 0;
    // Length-aware parsing prevents text containing '<EMAIL:...>' from becoming a field.
    while (cursor < input.length) {
        while (cursor < input.length && bytes[cursor] != '<') cursor++;
        if (cursor == input.length) break;
        NSUInteger start = ++cursor;
        while (cursor < input.length && bytes[cursor] != '>') cursor++;
        if (cursor == input.length) return @"<EOR>\n";
        NSString *header = [[NSString alloc] initWithBytes:bytes + start length:cursor - start encoding:NSASCIIStringEncoding];
        cursor++;
        NSArray *parts = [header.uppercaseString componentsSeparatedByString:@":"];
        if ([parts.firstObject isEqualToString:@"EOR"]) break;
        if (parts.count < 2 || parts.count > 3) return @"<EOR>\n";
        NSString *lengthString = parts[1];
        if (!lengthString.length || [lengthString rangeOfCharacterFromSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet].location != NSNotFound) return @"<EOR>\n";
        unsigned long long length = strtoull(lengthString.UTF8String, NULL, 10);
        if (length > input.length - cursor) return @"<EOR>\n";
        NSString *value = [[NSString alloc] initWithBytes:bytes + cursor length:(NSUInteger)length encoding:NSUTF8StringEncoding];
        cursor += (NSUInteger)length;
        NSString *key = parts[0];
        if (!value || ![allowed containsObject:key] || [seen containsObject:key] ||
            ![value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) continue;
        if ([key isEqualToString:@"GRIDSQUARE"] || [key isEqualToString:@"MY_GRIDSQUARE"]) {
            value = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].uppercaseString;
            NSRegularExpression *grid = [NSRegularExpression regularExpressionWithPattern:@"^[A-R]{2}[0-9]{2}([A-X]{2}([0-9]{2}([A-X]{2})?)?)?$" options:0 error:NULL];
            if ([grid numberOfMatchesInString:value options:0 range:NSMakeRange(0, value.length)] != 1) continue;
            if (!precise && value.length > 6) value = [value substringToIndex:6];
        }
        [seen addObject:key];
        [out appendFormat:@"<%@:%lu>%@ ", key, (unsigned long)[value lengthOfBytesUsingEncoding:NSUTF8StringEncoding], value];
    }
    [out appendString:@"<EOR>\n"];
    return out;
}

+ (NSString *)uploadDocumentForRecords:(NSArray<TX500LogRecord *> *)records service:(NSString *)service {
    NSMutableString *text = [NSMutableString stringWithString:@"<ADIF_VER:5>3.1.4 <PROGRAMID:14>Lab599 Utility <EOH>\n"];
    for (TX500LogRecord *record in records) [text appendString:[self uploadADIFForRecord:record service:service]];
    return text;
}

+ (nullable NSString *)discoverTQSLBinaryPath {
    if (TX500CloudExternalSideEffectsAreDisabled()) return nil;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *custom = [ud stringForKey:@"TX500_LoTW_TQSLPath"];
    if (custom.length > 0 && [[NSFileManager defaultManager] isExecutableFileAtPath:custom]) {
        return custom;
    }

    NSArray<NSString *> *candidates = @[
        @"/Applications/TrustedQSL/tqsl.app/Contents/MacOS/tqsl",
        @"/Applications/tqsl.app/Contents/MacOS/tqsl",
        @"/opt/homebrew/bin/tqsl",
        @"/usr/local/bin/tqsl",
        @"/usr/bin/tqsl"
    ];
    for (NSString *p in candidates) {
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p]) {
            return p;
        }
    }
    return nil;
}

+ (BOOL)synchronizeTQSLStorage {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *testRoot = NSProcessInfo.processInfo.environment[@"TX500_TEST_ROOT"];
    NSString *home = (TX500CloudExternalSideEffectsAreDisabled() && testRoot.length > 0) ? testRoot : NSHomeDirectory();
    NSString *tqslDir = [home stringByAppendingPathComponent:@".tqsl"];
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:tqslDir isDirectory:&isDir]) {
        NSError *err = nil;
        [fm createDirectoryAtPath:tqslDir withIntermediateDirectories:YES attributes:nil error:&err];
    }
    return YES;
}

+ (NSArray<NSString *> *)buildTQSLArgumentsForADIFPath:(NSString *)path
                                              location:(nullable NSString *)location
                                              password:(nullable NSString *)password {
    NSMutableArray<NSString *> *args = [NSMutableArray arrayWithArray:@[
        @"-d",
        @"-u",
        @"-x",
        @"-q",
        @"-a", @"compliant",
        @"-f", @"ignore"
    ]];

    NSString *loc = location;
    if (loc.length == 0) {
        loc = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_LoTW_StationLocation"];
    }
    if (loc.length > 0) {
        [args addObjectsFromArray:@[@"-l", loc]];
    }

    NSString *pass = password;
    if (pass.length == 0) {
        pass = TX500SecretValue(@"TX500_LoTW_CertificatePassword") ?:
               TX500SecretValue(@"TX500_LoTW_Password");
    }
    if (pass.length > 0) {
        [args addObjectsFromArray:@[@"-p", pass]];
    }
    [args addObject:path];
    return args;
}

#pragma mark - Zero-Click Upload

- (void)uploadContactImmediately:(TX500LogRecord *)record
                       completion:(nullable void (^)(BOOL overallSuccess, NSString *summary))completion {
    [self uploadContact:record toServices:nil completion:completion];
}

- (void)uploadContact:(TX500LogRecord *)record
           toServices:(nullable NSArray<NSString *> *)services
           completion:(nullable void (^)(BOOL overallSuccess, NSString *summary))completion {
    if (!record || record.callsign.length == 0) {
        if (completion) completion(NO, @"Empty record");
        return;
    }

    // Automated tests exercise QSO completion and logging. They must never
    // launch an installed TQSL app or contact a real cloud account.
    if (TX500CloudExternalSideEffectsAreDisabled()) {
        if (completion) completion(YES, @"External cloud side effects suppressed in test mode.");
        return;
    }

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL autoUpload = [ud objectForKey:@"TX500_Cloud_AutoUploadEnabled"] ? [ud boolForKey:@"TX500_Cloud_AutoUploadEnabled"] : NO;
    // the switch is for the upload after a QSO; a sync is asked for by the operator
    if (!services && !autoUpload) {
        if (completion) completion(YES, @"Auto-upload disabled in settings.");
        return;
    }

    NSArray<NSString *> *sendTo = [self servicesForUpload:services];
    BOOL uploadQRZ = [sendTo containsObject:@"QRZ"];
    BOOL uploadClubLog = [sendTo containsObject:@"ClubLog"];
    BOOL uploadEQSL = [sendTo containsObject:@"eQSL"];
    BOOL uploadLoTW = [sendTo containsObject:@"LoTW"];
    // one TQSL at a time: the upload after a QSO takes LoTW now, or leaves it pending (a sync sends it later);
    // a sync has taken it already, and here only looks that no other TQSL runs
    BOOL lotwTakenHere = uploadLoTW && !services && [self takeLoTW];
    BOOL lotwLeftPending = uploadLoTW && (services ? self.tqslRunning > 0 : !lotwTakenHere);
    if (lotwLeftPending) uploadLoTW = NO;

    NSString *qrzKey = TX500SecretValue(@"TX500_QRZ_APIKey") ?: @"";
    NSString *clubEmail = [ud stringForKey:@"TX500_ClubLog_Email"] ?: @"";
    NSString *clubCall = [ud stringForKey:@"TX500_ClubLog_Callsign"] ?: @"";
    NSString *clubPass = TX500SecretValue(@"TX500_ClubLog_Password") ?: @"";
    NSString *clubKey = TX500SecretValue(@"TX500_ClubLog_APIKey") ?: @"";
    NSString *eqslUser = [ud stringForKey:@"TX500_EQSL_Username"] ?: @"";
    NSString *eqslPass = TX500SecretValue(@"TX500_EQSL_Password") ?: @"";
    NSString *lotwLoc = [ud stringForKey:@"TX500_LoTW_StationLocation"] ?: @"";
    NSString *lotwPass = TX500SecretValue(@"TX500_LoTW_Password") ?: @"";
    NSString *tqslPath = [TX500CloudSyncEngine discoverTQSLBinaryPath];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        self.isUploading = YES;
        NSDate *startTime = [NSDate date];
        NSMutableArray<NSString *> *successList = [NSMutableArray array];
        NSMutableArray<NSString *> *failureList = [NSMutableArray array];
        dispatch_group_t group = dispatch_group_create();

        // 1. QRZ Logbook
        if (uploadQRZ && qrzKey.length > 0) {
            dispatch_group_enter(group);
            [self performQRZInsert:record apiKey:qrzKey completion:^(BOOL ok, NSString *msg) {
                if (ok) {
                    [successList addObject:@"QRZ"];
                    [[TX500LogbookManager sharedManager] updateCloudStatusForUUID:record.uuid service:@"QRZ" status:@"UPLOADED" error:nil];
                } else {
                    [failureList addObject:[NSString stringWithFormat:@"QRZ (%@)", msg]];
                }
                dispatch_group_leave(group);
            }];
        }

        // 2. ClubLog
        if (uploadClubLog && clubEmail.length > 0 && clubKey.length > 0) {
            dispatch_group_enter(group);
            [self performClubLogUpload:record email:clubEmail callsign:clubCall password:clubPass apiKey:clubKey completion:^(BOOL ok, NSString *msg) {
                if (ok) {
                    [successList addObject:@"ClubLog"];
                    [[TX500LogbookManager sharedManager] updateCloudStatusForUUID:record.uuid service:@"ClubLog" status:@"UPLOADED" error:nil];
                } else {
                    [failureList addObject:[NSString stringWithFormat:@"ClubLog (%@)", msg]];
                }
                dispatch_group_leave(group);
            }];
        }

        // 3. eQSL.cc
        if (uploadEQSL && eqslUser.length > 0 && eqslPass.length > 0) {
            dispatch_group_enter(group);
            [self performEQSLUpload:record username:eqslUser password:eqslPass completion:^(BOOL ok, NSString *msg) {
                if (ok) {
                    [successList addObject:@"eQSL"];
                    [[TX500LogbookManager sharedManager] updateCloudStatusForUUID:record.uuid service:@"eQSL" status:@"UPLOADED" error:nil];
                } else {
                    [failureList addObject:[NSString stringWithFormat:@"eQSL (%@)", msg]];
                }
                dispatch_group_leave(group);
            }];
        }

        // 4. ARRL LoTW via TQSL
        // A configured station location is the user's explicit opt-in for LoTW.
        // Merely having TrustedQSL installed must not launch it after a QSO.
        if (uploadLoTW && tqslPath.length > 0 && lotwLoc.length > 0) {
            dispatch_group_enter(group);
            [self performLoTWUpload:record binaryPath:tqslPath location:lotwLoc password:lotwPass completion:^(BOOL ok, NSString *msg) {
                if (ok) {
                    [successList addObject:@"LoTW"];
                    [[TX500LogbookManager sharedManager] updateCloudStatusForUUID:record.uuid service:@"LoTW" status:@"UPLOADED" error:nil];
                } else {
                    [failureList addObject:[NSString stringWithFormat:@"LoTW (%@)", msg]];
                }
                dispatch_group_leave(group);
            }];
        }
        // that TQSL has ended (the LoTW upload waits for it): LoTW is free again
        if (lotwTakenHere) [self giveBackLoTW];

        dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45.0 * NSEC_PER_SEC)));

        NSInteger latency = (NSInteger)([startTime timeIntervalSinceNow] * -1000.0);
        BOOL overallOk = (failureList.count == 0 && successList.count > 0);

        NSMutableString *statusSummary = [NSMutableString string];
        if (successList.count > 0) {
            [statusSummary appendFormat:@"☁️ Uploaded: %@ (%@/%@) → %@ [%ldms]",
             record.callsign, record.band, record.mode, [successList componentsJoinedByString:@", "], (long)latency];
        }
        if (failureList.count > 0) {
            if (statusSummary.length > 0) [statusSummary appendString:@" | "];
            [statusSummary appendFormat:@"Errors: %@", [failureList componentsJoinedByString:@", "]];
        }
        if (lotwLeftPending) {
            if (statusSummary.length > 0) [statusSummary appendString:@" | "];
            [statusSummary appendFormat:@"LoTW left pending for %@: TQSL is running, or about to start.", record.callsign];
        }
        if (successList.count == 0 && failureList.count == 0 && !lotwLeftPending) {
            [statusSummary appendString:@"No cloud services configured or enabled."];
        }

        TX500CloudUploadItem *item = [[TX500CloudUploadItem alloc] init];
        item.callsign = record.callsign;
        item.band = record.band;
        item.mode = record.mode;
        item.services = successList;
        item.latencyMs = latency;
        item.success = overallOk;
        item.message = [statusSummary copy];

        dispatch_sync(self.syncQueue, ^{
            [self.uploadHistory insertObject:item atIndex:0];
            if (self.uploadHistory.count > 100) {
                [self.uploadHistory removeLastObject];
            }
            self.lastStatusMessage = item.message;
            self.isUploading = NO;
        });

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:TX500CloudSyncStatusDidChangeNotification object:self];
            if (completion) {
                completion(overallOk, item.message);
            }
        });
    });
}

#pragma mark - Service Specific Upload Handlers

- (void)performQRZInsert:(TX500LogRecord *)record
                  apiKey:(NSString *)apiKey
              completion:(void (^)(BOOL success, NSString *message))completion {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"TX500_Cloud_UploadQRZ"]) {
        completion(NO, @"QRZ uploads are disabled in Cloud Settings > Privacy.");
        return;
    }
    NSString *endpoint = @"https://logbook.qrz.com/api";
    NSString *adif = [TX500CloudSyncEngine uploadDocumentForRecords:@[record] service:@"QRZ"];
    NSString *postStr = [NSString stringWithFormat:@"KEY=%@&ACTION=INSERT&ADIF=%@",
                         [self urlEncode:apiKey], [self urlEncode:adif]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [postStr dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"TX500-macOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSString *qrzCookie = [TX500WebAuthenticatorController cookieHeaderForService:TX500AuthServiceQRZ];
    if (qrzCookie.length > 0) {
        [req setValue:qrzCookie forHTTPHeaderField:@"Cookie"];
    }

    [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            completion(NO, err.localizedDescription);
            return;
        }
        NSString *respText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        if (TX500QRZResponseIsSuccess(resp, respText)) {
            completion(YES, @"OK");
        } else {
            NSString *reason = [self extractQRZReason:respText];
            completion(NO, reason);
        }
    }] resume];
}

- (void)performClubLogUpload:(TX500LogRecord *)record
                       email:(NSString *)email
                    callsign:(NSString *)callsign
                    password:(NSString *)password
                      apiKey:(NSString *)apiKey
                  completion:(void (^)(BOOL success, NSString *message))completion {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"TX500_Cloud_UploadClubLog"]) {
        completion(NO, @"Club Log uploads are disabled in Cloud Settings > Privacy.");
        return;
    }
    NSString *endpoint = @"https://clublog.org/realtime.php";
    NSString *adif = [TX500CloudSyncEngine uploadDocumentForRecords:@[record] service:@"ClubLog"];
    NSString *postStr = [NSString stringWithFormat:@"email=%@&password=%@&callsign=%@&api=%@&adif=%@",
                         [self urlEncode:email], [self urlEncode:password], [self urlEncode:callsign],
                         [self urlEncode:apiKey], [self urlEncode:adif]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [postStr dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"TX500-macOS/1.0" forHTTPHeaderField:@"User-Agent"];

    NSString *clubCookie = [TX500WebAuthenticatorController cookieHeaderForService:TX500AuthServiceClubLog];
    if (clubCookie.length > 0) {
        [req setValue:clubCookie forHTTPHeaderField:@"Cookie"];
    }

    [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            completion(NO, err.localizedDescription);
            return;
        }
        NSString *resText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        if (TX500ClubLogResponseIsSuccess((NSHTTPURLResponse *)resp, data)) {
            completion(YES, @"OK");
        } else {
            completion(NO, resText.length ? [resText substringToIndex:MIN(50, resText.length)] :
                [NSString stringWithFormat:@"Club Log returned HTTP %ld with no success response", (long)((NSHTTPURLResponse *)resp).statusCode]);
        }
    }] resume];
}

- (void)performEQSLUpload:(TX500LogRecord *)record
                 username:(NSString *)username
                 password:(NSString *)password
               completion:(void (^)(BOOL success, NSString *message))completion {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"TX500_Cloud_UploadEQSL"]) {
        completion(NO, @"eQSL uploads are disabled in Cloud Settings > Privacy.");
        return;
    }
    NSString *endpoint = @"https://www.eqsl.cc/qslcard/ImportADIF.txt";
    NSString *adif = [TX500CloudSyncEngine uploadDocumentForRecords:@[record] service:@"eQSL"];
    NSString *postStr = [NSString stringWithFormat:@"EQSL_USER=%@&EQSL_PSWD=%@&ADIFData=%@",
                         [self urlEncode:username], [self urlEncode:password], [self urlEncode:adif]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [postStr dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"TX500-macOS/1.0" forHTTPHeaderField:@"User-Agent"];

    [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err) {
            completion(NO, err.localizedDescription);
            return;
        }
        NSString *resText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        if (TX500CloudResponseMatchesEndpoint(resp, endpoint) &&
            ([resText localizedCaseInsensitiveContainsString:@"Success"] ||
             [resText localizedCaseInsensitiveContainsString:@"Result: 1"])) {
            completion(YES, @"OK");
        } else {
            completion(NO, [resText substringToIndex:MIN(60, resText.length)]);
        }
    }] resume];
}

- (void)performLoTWUpload:(TX500LogRecord *)record
               binaryPath:(NSString *)binaryPath
                 location:(nullable NSString *)location
                 password:(nullable NSString *)password
               completion:(void (^)(BOOL success, NSString *message))completion {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"TX500_Cloud_UploadLoTW"]) {
        completion(NO, @"LoTW uploads are disabled in Cloud Settings > Privacy.");
        return;
    }
    NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tx500_lotw_%@.adi", record.uuid]];
    NSString *adifContent = [TX500CloudSyncEngine uploadDocumentForRecords:@[record] service:@"LoTW"];
    NSError *writeErr = nil;
    if (![adifContent writeToFile:tempFile atomically:YES encoding:NSUTF8StringEncoding error:&writeErr]) {
        completion(NO, writeErr.localizedDescription);
        return;
    }

    NSArray<NSString *> *args = [TX500CloudSyncEngine buildTQSLArgumentsForADIFPath:tempFile location:location password:password];

    @try {
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = binaryPath;
        task.arguments = args;

        NSPipe *outPipe = [NSPipe pipe];
        task.standardOutput = outPipe;
        task.standardError = outPipe;

        [self tqslRunStarted];
        @try {
            [task launch];
        } @catch (NSException *launchFailed) {
            [self tqslRunEnded];
            @throw;
        }
        [task waitUntilExit];
        [self tqslRunEnded];

        NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
        NSString *outStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";

        [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
        NSString *companionTq8 = [[tempFile stringByDeletingPathExtension] stringByAppendingPathExtension:@"tq8"];
        [[NSFileManager defaultManager] removeItemAtPath:companionTq8 error:nil];

        int code = task.terminationStatus;
        if (code == 0) {
            completion(YES, @"OK");
        } else {
            completion(NO, [NSString stringWithFormat:@"TQSL exited with %d: %@", code, [outStr substringToIndex:MIN(80, outStr.length)]]);
        }
    } @catch (NSException *ex) {
        [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
        completion(NO, ex.reason ?: @"TQSL process failed");
    }
}

#pragma mark - Sync

// Pending: the service does not have the contact yet. NONE, QUEUED, ERROR or no status at all; never
// UPLOADED or CONFIRMED, as the LoTW batch below already counts it.
+ (BOOL)isPendingStatus:(nullable NSString *)status {
    return ![status isEqualToString:@"UPLOADED"] && ![status isEqualToString:@"CONFIRMED"];
}

// What each upload needs (Club Log its email, callsign, password and API key)
- (NSArray<NSString *> *)enabledConfiguredServices {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL (^enabled)(NSString *) = ^BOOL(NSString *key) { return [ud objectForKey:key] ? [ud boolForKey:key] : NO; };
    NSMutableArray<NSString *> *services = [NSMutableArray array];
    if (enabled(@"TX500_Cloud_UploadQRZ") && TX500SecretValue(@"TX500_QRZ_APIKey").length > 0) [services addObject:@"QRZ"];
    if (enabled(@"TX500_Cloud_UploadClubLog") && [ud stringForKey:@"TX500_ClubLog_Email"].length > 0 &&
        [ud stringForKey:@"TX500_ClubLog_Callsign"].length > 0 && TX500SecretValue(@"TX500_ClubLog_Password").length > 0 &&
        TX500SecretValue(@"TX500_ClubLog_APIKey").length > 0) [services addObject:@"ClubLog"];
    if (enabled(@"TX500_Cloud_UploadEQSL") && [ud stringForKey:@"TX500_EQSL_Username"].length > 0 &&
        TX500SecretValue(@"TX500_EQSL_Password").length > 0) [services addObject:@"eQSL"];
    if (enabled(@"TX500_Cloud_UploadLoTW") && [TX500CloudSyncEngine discoverTQSLBinaryPath].length > 0 &&
        [ud stringForKey:@"TX500_LoTW_StationLocation"].length > 0) [services addObject:@"LoTW"];
    return services;
}

- (NSArray<NSString *> *)servicesForUpload:(nullable NSArray<NSString *> *)requested {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (!requested && ![ud boolForKey:@"TX500_Cloud_AutoUploadEnabled"]) return @[];
    NSMutableArray<NSString *> *sendTo = [NSMutableArray array];
    for (NSString *service in [self enabledConfiguredServices]) {
        if (!requested || [requested containsObject:service]) [sendTo addObject:service];
    }
    return sendTo;
}

- (BOOL)syncInProgress {
    @synchronized (self) {
        return self.syncRunning || self.tqslRuns > 0 || self.lotwTaken > 0;
    }
}

- (BOOL)tqslBusy {
    @synchronized (self) {
        return self.tqslRuns > 0 || self.lotwTaken > 0;
    }
}

// LoTW for one upload, taken when it is decided on: only while no TQSL runs and none is about to, so that
// two uploads that decide at the same moment never both start one
- (BOOL)takeLoTW {
    @synchronized (self) {
        if (self.tqslRuns > 0 || self.lotwTaken > 0) return NO;
        self.lotwTaken++;
        return YES;
    }
}

- (void)giveBackLoTW {
    @synchronized (self) {
        if (self.lotwTaken > 0) self.lotwTaken--;
    }
}

- (NSInteger)tqslRunning {
    @synchronized (self) {
        return self.tqslRuns;
    }
}

// around every TQSL process the app starts
- (void)tqslRunStarted {
    @synchronized (self) {
        self.tqslRuns++;
    }
}

- (void)tqslRunEnded {
    @synchronized (self) {
        if (self.tqslRuns > 0) self.tqslRuns--;
    }
}

+ (NSArray<NSString *> *)pendingServicesOfContact:(TX500LogRecord *)record among:(NSArray<NSString *> *)services {
    NSDictionary<NSString *, NSString *> *status = @{@"QRZ": record.qrzStatus ?: @"", @"ClubLog": record.clublogStatus ?: @"",
                                                     @"eQSL": record.eqslStatus ?: @"", @"LoTW": record.lotwStatus ?: @""};
    NSMutableArray<NSString *> *pending = [NSMutableArray array];
    for (NSString *service in services) {
        if (status[service] && [self isPendingStatus:status[service]]) [pending addObject:service];
    }
    return pending;
}

- (void)syncContacts:(nullable NSArray<TX500LogRecord *> *)records
          completion:(nullable void (^)(NSInteger uploadedCount, NSInteger failedCount, NSString *summary))completion {
    if (records && records.count == 0) {
        if (completion) completion(0, 0, @"No contacts to sync.");
        return;
    }
    NSArray<NSString *> *services = [self enabledConfiguredServices];
    if (services.count == 0) {
        if (completion) completion(0, 0, @"No cloud service is enabled and configured (Settings…): nothing was sent.");
        return;
    }
    NSDictionary<NSString *, NSString *> *names = @{@"QRZ": @"QRZ", @"ClubLog": @"Club Log", @"eQSL": @"eQSL", @"LoTW": @"LoTW"};
    NSMutableArray<NSString *> *notChecked = [NSMutableArray array];
    for (NSString *service in @[@"QRZ", @"ClubLog", @"eQSL", @"LoTW"]) {
        if (![services containsObject:service]) [notChecked addObject:names[service]];
    }
    NSString *notCheckedNote = notChecked.count ? [NSString stringWithFormat:@" Not checked: %@ (not configured, or disabled in Cloud Settings).",
                                                   [notChecked componentsJoinedByString:@", "]] : @"";
    TX500LogbookManager *logbook = [TX500LogbookManager sharedManager];
    NSMutableArray<TX500LogRecord *> *pending = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSNumber *> *already = [NSMutableDictionary dictionary];
    for (TX500LogRecord *r in records ?: [logbook allContacts]) {
        NSArray<NSString *> *missing = [TX500CloudSyncEngine pendingServicesOfContact:r among:services];
        if (missing.count > 0) [pending addObject:r];
        for (NSString *service in services) {
            if (![missing containsObject:service]) already[service] = @(already[service].integerValue + 1);
        }
    }

    // for each service, the QSOs never tried there go first, and those that failed there before (ERROR) last:
    // two that always fail must not stop a service before the others are tried on it
    NSMutableSet<NSString *> *failedThereBefore = [NSMutableSet set];
    for (TX500LogRecord *r in pending) {
        NSDictionary<NSString *, NSString *> *status = @{@"QRZ": r.qrzStatus ?: @"", @"ClubLog": r.clublogStatus ?: @"",
                                                         @"eQSL": r.eqslStatus ?: @"", @"LoTW": r.lotwStatus ?: @""};
        for (NSString *service in services) {
            if ([status[service] isEqualToString:@"ERROR"]) [failedThereBefore addObject:[NSString stringWithFormat:@"%@|%@", r.uuid, service]];
        }
    }

    if (pending.count == 0) {
        NSString *checked = [[names objectsForKeys:services notFoundMarker:@""] componentsJoinedByString:@", "];
        NSString *msg = records ? [NSString stringWithFormat:@"Nothing pending on %@ for the %lu contact(s) given.%@", checked, (unsigned long)records.count, notCheckedNote]
                      : notChecked.count ? [NSString stringWithFormat:@"Nothing pending on %@.%@", checked, notCheckedNote]
                                         : @"All contacts are already synchronized.";
        if (completion) completion(0, 0, msg);
        return;
    }

    BOOL running = NO;
    @synchronized (self) {
        running = self.syncRunning;
        self.syncRunning = YES;
    }
    if (running) {
        if (completion) completion(0, 0, @"A sync is already running: nothing was sent.");
        return;
    }

    NSTimeInterval wait = self.syncUploadWaitSeconds > 0 ? self.syncUploadWaitSeconds : 60.0;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block NSInteger successCount = 0;
        __block NSInteger failCount = 0;
        __block NSInteger inFlight = 0;   // uploads started and not ended yet, under @synchronized (stillRunning)
        // for each QSO sent, whether every upload of it went well (one QSO can be sent twice, to different services)
        NSMutableDictionary<NSString *, NSNumber *> *wentWell = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSNumber *> *uploaded = [NSMutableDictionary dictionary], *failed = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSNumber *> *leftStopped = [NSMutableDictionary dictionary], *leftOff = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSNumber *> *leftWaiting = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSNumber *> *inARow = [NSMutableDictionary dictionary];
        NSMutableSet<NSString *> *stopped = [NSMutableSet set];
        NSMutableArray<NSArray *> *stillRunning = [NSMutableArray array];   // @[uuid, services]; also the lock of the counts
        void (^add)(NSMutableDictionary<NSString *, NSNumber *> *, NSString *) = ^(NSMutableDictionary<NSString *, NSNumber *> *d, NSString *k) {
            d[k] = @(d[k].integerValue + 1);
        };
        // a failure in a row for a service (rejected credentials among other errors); two stop it for this sync
        void (^strike)(NSString *) = ^(NSString *service) {
            add(inARow, service);
            if (inARow[service].integerValue >= 2) [stopped addObject:service];
        };
        // which of the services asked for have the contact now (its status there is no longer pending)
        void (^count)(NSString *, NSArray<NSString *> *, BOOL) = ^(NSString *uuid, NSArray<NSString *> *asked, BOOL strikes) {
            TX500LogRecord *after = [logbook contactWithUUID:uuid];
            for (NSString *service in asked) {
                if (after && [TX500CloudSyncEngine pendingServicesOfContact:after among:@[service]].count == 0) {
                    add(uploaded, service);
                    inARow[service] = @0;
                } else {
                    add(failed, service);
                    if (strikes) strike(service);
                    // tried and failed: ERROR, so that the next sync tries it after the others
                    [logbook updateCloudStatusForUUID:uuid service:service status:@"ERROR" error:nil];
                }
            }
        };
        dispatch_group_t all = dispatch_group_create();

        // first each QSO to the services it never failed on before, then to those it did (R15)
        for (NSInteger phase = 0; phase < 2; phase++) for (TX500LogRecord *listed in pending) {
            // its status now, not when the list was made: a service that has it by now is not sent it again
            TX500LogRecord *rec = [logbook contactWithUUID:listed.uuid];
            NSMutableArray<NSString *> *missing = [NSMutableArray array];
            for (NSString *service in rec ? [TX500CloudSyncEngine pendingServicesOfContact:rec among:services] : @[]) {
                BOOL failedThere = [failedThereBefore containsObject:[NSString stringWithFormat:@"%@|%@", rec.uuid, service]];
                if (failedThere == (phase == 1)) [missing addObject:service];
            }
            // and only to the services still enabled and configured, and not stopped
            NSArray<NSString *> *now = missing.count ? [self enabledConfiguredServices] : @[];
            NSMutableArray<NSString *> *to = [NSMutableArray array];
            for (NSString *service in missing) {
                if ([stopped containsObject:service]) add(leftStopped, service);
                else if (![now containsObject:service]) add(leftOff, service);
                else [to addObject:service];
            }
            // and to LoTW only while no TQSL runs and none is about to (this sync's, or any other the app
            // started): taken now, and given back once this upload has ended, its TQSL with it
            BOOL lotwTakenHere = NO;
            if ([to containsObject:@"LoTW"]) {
                lotwTakenHere = [self takeLoTW];
                if (!lotwTakenHere) {
                    [to removeObject:@"LoTW"];
                    add(leftWaiting, @"LoTW");
                }
            }
            if (to.count == 0) continue;
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            dispatch_group_enter(all);
            @synchronized (stillRunning) {
                inFlight++;
            }
            [self uploadContact:rec toServices:to completion:^(BOOL ok, NSString *summary) {
                (void)summary;
                if (lotwTakenHere) [self giveBackLoTW];
                @synchronized (stillRunning) {
                    NSNumber *sofar = wentWell[rec.uuid];
                    wentWell[rec.uuid] = @((sofar ? sofar.boolValue : YES) && ok);
                    inFlight--;
                }
                dispatch_semaphore_signal(sema);
                dispatch_group_leave(all);
            }];
            // an upload to QRZ, Club Log and eQSL takes 45 s at most; one to LoTW waits for TQSL, which
            // has no time limit: after the wait the next contact goes on (with no LoTW while it runs),
            // the services not done by then count as a failure in a row, and its outcome is counted at the end
            if (dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC))) == 0) {
                count(rec.uuid, to, YES);
            } else {
                [stillRunning addObject:@[rec.uuid, to]];
                TX500LogRecord *sofar = [logbook contactWithUUID:rec.uuid];
                for (NSString *service in to) {
                    if (!sofar || [TX500CloudSyncEngine pendingServicesOfContact:sofar among:@[service]].count > 0) strike(service);
                    else inARow[service] = @0;   // that one went through: its failures are no longer in a row
                }
            }
        }
        // what still runs now (uploads whose wait ran out may have ended since), in a line of its own
        NSInteger running = 0;
        @synchronized (stillRunning) {
            running = inFlight;
        }
        if (running > 0) {
            NSString *line = [NSString stringWithFormat:@"%ld upload(s) still running (a LoTW upload waits for TQSL); no new sync can start until they end.",
                              (long)running];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:TX500CloudSyncStatusDidChangeNotification object:self userInfo:@{@"message": line}];
            });
        }

        // the end, once every upload started has really finished
        dispatch_group_notify(all, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            for (NSArray *late in stillRunning) count(late[0], late[1], NO);
            for (NSNumber *well in wentWell.allValues) {
                if (well.boolValue) successCount++;
                else failCount++;
            }
            NSMutableString *msg = [NSMutableString stringWithFormat:@"Batch sync finished: %ld QSO(s) sent to every service asked, %ld with a service failing.",
                                    (long)successCount, (long)failCount];
            for (NSString *service in services) {
                NSMutableArray<NSString *> *parts = [NSMutableArray array];
                if (uploaded[service].integerValue) [parts addObject:[NSString stringWithFormat:@"%ld uploaded", (long)uploaded[service].integerValue]];
                if (already[service].integerValue) [parts addObject:[NSString stringWithFormat:@"%ld already there", (long)already[service].integerValue]];
                if (failed[service].integerValue) [parts addObject:[NSString stringWithFormat:@"%ld failed", (long)failed[service].integerValue]];
                if ([stopped containsObject:service])
                    [parts addObject:[NSString stringWithFormat:@"stopped after 2 failures in a row, %ld left pending", (long)leftStopped[service].integerValue]];
                if (leftWaiting[service].integerValue)
                    [parts addObject:[NSString stringWithFormat:@"waiting for TQSL, %ld left pending", (long)leftWaiting[service].integerValue]];
                if (leftOff[service].integerValue)
                    [parts addObject:[NSString stringWithFormat:@"no longer configured (or disabled in Cloud Settings) during the sync, %ld left pending", (long)leftOff[service].integerValue]];
                [msg appendFormat:@" %@: %@.", names[service], parts.count ? [parts componentsJoinedByString:@", "] : @"nothing to do"];
            }
            [msg appendString:notCheckedNote];
            @synchronized (self) {
                self.syncRunning = NO;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(successCount, failCount, msg);
            });
        });
    });
}

#pragma mark - Batch Uploads

- (void)uploadPendingContactsWithCompletion:(nullable void (^)(NSInteger uploadedCount, NSInteger failedCount, NSString *summary))completion {
    [self syncContacts:nil completion:completion];
}

- (void)uploadFullLogbookToLoTWWithCompletion:(nullable void (^)(BOOL success, NSString *message))completion {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"TX500_Cloud_UploadLoTW"]) {
        if (completion) completion(NO, @"LoTW uploads are disabled in Cloud Settings > Privacy.");
        return;
    }
    NSString *tqslPath = [TX500CloudSyncEngine discoverTQSLBinaryPath];
    if (!tqslPath) {
        if (completion) completion(NO, @"TrustedQSL (tqsl) binary not found on this Mac. Please install TQSL from arrl.org.");
        return;
    }

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *location = [ud stringForKey:@"TX500_LoTW_StationLocation"];
    NSString *password = TX500SecretValue(@"TX500_LoTW_Password");

    NSArray<TX500LogRecord *> *records = [[TX500LogbookManager sharedManager] allContacts];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tx500_full_lotw_%@.adi", NSUUID.UUID.UUIDString]];
        NSError *err = nil;
       NSString *adif = [TX500CloudSyncEngine uploadDocumentForRecords:records service:@"LoTW"];
        if (![adif writeToFile:tempFile atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, err.localizedDescription);
            });
            return;
        }

        NSArray<NSString *> *args = [TX500CloudSyncEngine buildTQSLArgumentsForADIFPath:tempFile location:location password:password];

        @try {
            NSTask *task = [[NSTask alloc] init];
            task.launchPath = tqslPath;
            task.arguments = args;

            NSPipe *pipe = [NSPipe pipe];
            task.standardOutput = pipe;
            task.standardError = pipe;

            [self tqslRunStarted];
            @try {
                [task launch];
            } @catch (NSException *launchFailed) {
                [self tqslRunEnded];
                @throw;
            }
            [task waitUntilExit];
            [self tqslRunEnded];

            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *outStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";

            [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
            NSString *companionTq8 = [[tempFile stringByDeletingPathExtension] stringByAppendingPathExtension:@"tq8"];
            [[NSFileManager defaultManager] removeItemAtPath:companionTq8 error:nil];

            int code = task.terminationStatus;
            BOOL ok = (code == 0);
            NSString *resultMsg = ok ? @"LoTW Full Batch Uploaded Successfully via TQSL!" :
                [NSString stringWithFormat:@"LoTW Error (exit %d): %@", code, outStr];

            if (ok) {
                // Mark all uploaded in DB
                for (TX500LogRecord *r in records) {
                    [[TX500LogbookManager sharedManager] updateCloudStatusForUUID:r.uuid service:@"LoTW" status:@"UPLOADED" error:nil];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(ok, resultMsg);
            });
        } @catch (NSException *ex) {
            [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, ex.reason ?: @"TQSL process execution failed");
            });
        }
    });
}

- (void)signAndUploadContactsToLoTW:(NSArray<TX500LogRecord *> *)records completion:(nullable void (^)(BOOL success, NSString *message))completion {
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"TX500_Cloud_UploadLoTW"]) {
        if (completion) completion(NO, @"LoTW uploads are disabled in Cloud Settings > Privacy.");
        return;
    }
    if (TX500CloudExternalSideEffectsAreDisabled()) {
        if (completion) completion(YES, @"TQSL LoTW upload suppressed in test mode.");
        return;
    }

    NSString *tqslPath = [TX500CloudSyncEngine discoverTQSLBinaryPath];
    if (!tqslPath) {
        if (completion) completion(NO, @"TrustedQSL (tqsl) binary not found on this Mac. Please install TQSL from arrl.org.");
        return;
    }

    NSArray<TX500LogRecord *> *targets = records;
    if (!targets || targets.count == 0) {
        NSMutableArray<TX500LogRecord *> *pending = [NSMutableArray array];
        for (TX500LogRecord *r in [[TX500LogbookManager sharedManager] allContacts]) {
            if (![r.lotwStatus isEqualToString:@"UPLOADED"] && ![r.lotwStatus isEqualToString:@"CONFIRMED"]) {
                [pending addObject:r];
            }
        }
        targets = pending;
    }

    if (targets.count == 0) {
        if (completion) completion(YES, @"No pending contacts to upload to LoTW.");
        return;
    }

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *location = [ud stringForKey:@"TX500_LoTW_StationLocation"];
    NSString *password = TX500SecretValue(@"TX500_LoTW_CertificatePassword") ?: TX500SecretValue(@"TX500_LoTW_Password");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tx500_lotw_batch_%@.adi", [[NSUUID UUID] UUIDString]]];
        NSMutableString *adif = [NSMutableString stringWithFormat:@"Lab599 TX-500 LoTW Export\n<ADIF_VER:5>3.1.4 <PROGRAMID:14>Lab599 Utility <EOH>\n\n"];
        for (TX500LogRecord *r in targets) {
            [adif appendString:[TX500CloudSyncEngine uploadADIFForRecord:r service:@"LoTW"]];
        }

        NSError *err = nil;
        if (![adif writeToFile:tempFile atomically:YES encoding:NSUTF8StringEncoding error:&err]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, err.localizedDescription ?: @"Failed to write temporary ADIF");
            });
            return;
        }

        NSArray<NSString *> *args = [TX500CloudSyncEngine buildTQSLArgumentsForADIFPath:tempFile location:location password:password];

        @try {
            NSTask *task = [[NSTask alloc] init];
            task.launchPath = tqslPath;
            task.arguments = args;

            NSPipe *pipe = [NSPipe pipe];
            task.standardOutput = pipe;
            task.standardError = pipe;

            [self tqslRunStarted];
            @try {
                [task launch];
            } @catch (NSException *launchFailed) {
                [self tqslRunEnded];
                @throw;
            }
            [task waitUntilExit];
            [self tqslRunEnded];

            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *outStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";

            [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
            NSString *companionTq8 = [[tempFile stringByDeletingPathExtension] stringByAppendingPathExtension:@"tq8"];
            [[NSFileManager defaultManager] removeItemAtPath:companionTq8 error:nil];

            int code = task.terminationStatus;
            BOOL ok = (code == 0);
            NSString *resultMsg = ok ?
                [NSString stringWithFormat:@"Successfully signed & uploaded %ld QSO(s) to LoTW via TQSL!", (long)targets.count] :
                [NSString stringWithFormat:@"TQSL exited with code %d: %@", code, [outStr substringToIndex:MIN(100, outStr.length)]];

            if (ok) {
                for (TX500LogRecord *r in targets) {
                    [[TX500LogbookManager sharedManager] updateCloudStatusForUUID:r.uuid service:@"LoTW" status:@"UPLOADED" error:nil];
                }
            }

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(ok, resultMsg);
            });
        } @catch (NSException *ex) {
            [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(NO, ex.reason ?: @"TQSL process failed to launch");
            });
        }
    });
}

#pragma mark - Verification Tests

- (void)testQRZLogbookAPIKey:(NSString *)apiKey
                  completion:(void (^)(BOOL success, NSString *message))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *endpoint = @"https://logbook.qrz.com/api";
        NSString *postStr = [NSString stringWithFormat:@"KEY=%@&ACTION=STATUS", [self urlEncode:apiKey]];

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
        req.HTTPMethod = @"POST";
        req.HTTPBody = [postStr dataUsingEncoding:NSUTF8StringEncoding];
        [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
        [req setValue:@"TX500-macOS/1.0" forHTTPHeaderField:@"User-Agent"];

        [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, err.localizedDescription);
                });
                return;
            }
            NSString *resText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            BOOL ok = TX500CloudResponseMatchesEndpoint(resp, endpoint) &&
                      [resText containsString:@"RESULT=OK"];
            NSString *msg = ok ? @"QRZ Logbook API Key is valid and active!" : [self extractQRZReason:resText];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(ok, msg);
            });
        }] resume];
    });
}

- (void)testClubLogCredentialsWithEmail:(NSString *)email
                               callsign:(NSString *)callsign
                               password:(NSString *)password
                                 apiKey:(NSString *)apiKey
                             completion:(void (^)(BOOL success, NSString *message))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Testing ClubLog via lightweight ADIF header
        NSString *endpoint = @"https://clublog.org/realtime.php";
        NSString *testADIF = @"<ADIF_VER:5>3.1.4 <PROGRAMID:14>Lab599 Utility <EOH>";
        NSString *postStr = [NSString stringWithFormat:@"email=%@&password=%@&callsign=%@&api=%@&adif=%@",
                             [self urlEncode:email], [self urlEncode:password], [self urlEncode:callsign],
                             [self urlEncode:apiKey], [self urlEncode:testADIF]];

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
        req.HTTPMethod = @"POST";
        req.HTTPBody = [postStr dataUsingEncoding:NSUTF8StringEncoding];
        [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

        [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, err.localizedDescription);
                });
                return;
            }
            NSString *resText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            BOOL ok = TX500ClubLogResponseIsSuccess((NSHTTPURLResponse *)resp, data);
            NSString *msg = ok ? @"ClubLog Credentials Verified!" : resText;
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(ok, msg);
            });
        }] resume];
    });
}

- (void)testEQSLCredentialsWithUsername:(NSString *)username
                               password:(NSString *)password
                             completion:(void (^)(BOOL success, NSString *message))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *endpoint = @"https://www.eqsl.cc/qslcard/ImportADIF.txt";
        NSString *testADIF = @"<ADIF_VER:5>3.1.4 <PROGRAMID:14>Lab599 Utility <EOH>";
        NSString *postStr = [NSString stringWithFormat:@"EQSL_USER=%@&EQSL_PSWD=%@&ADIFData=%@",
                             [self urlEncode:username], [self urlEncode:password], [self urlEncode:testADIF]];

        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
        req.HTTPMethod = @"POST";
        req.HTTPBody = [postStr dataUsingEncoding:NSUTF8StringEncoding];
        [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];

        [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            if (err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, err.localizedDescription);
                });
                return;
            }
            NSString *resText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            BOOL ok = TX500CloudResponseMatchesEndpoint(resp, endpoint) &&
                      ([resText localizedCaseInsensitiveContainsString:@"Success"] ||
                       [resText localizedCaseInsensitiveContainsString:@"Result: 1"]);
            NSString *msg = ok ? @"eQSL.cc Login Verified!" : resText;
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(ok, msg);
            });
        }] resume];
    });
}

- (void)testLoTWSetupWithLocation:(nullable NSString *)location
                         password:(nullable NSString *)password
                         tqslPath:(nullable NSString *)tqslPath
                       completion:(void (^)(BOOL success, NSString *message))completion {
    NSString *bin = tqslPath.length > 0 ? tqslPath : [TX500CloudSyncEngine discoverTQSLBinaryPath];
    if (!bin) {
        completion(NO, @"TQSL binary not found. Please install TrustedQSL from arrl.org.");
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @try {
            NSTask *task = [[NSTask alloc] init];
            task.launchPath = bin;
            task.arguments = @[@"-v"];

            NSPipe *pipe = [NSPipe pipe];
            task.standardOutput = pipe;
            task.standardError = pipe;

            [self tqslRunStarted];
            @try {
                [task launch];
            } @catch (NSException *launchFailed) {
                [self tqslRunEnded];
                @throw;
            }
            [task waitUntilExit];
            [self tqslRunEnded];

            NSData *d = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *outStr = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
            NSString *locInfo = location.length > 0 ? [NSString stringWithFormat:@" (Station Location: %@)", location] : @"";
            NSString *msg = [NSString stringWithFormat:@"Found TQSL: %@%@\nVersion info: %@", bin, locInfo, [outStr stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(YES, msg);
            });
        } @catch (NSException *ex) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(NO, ex.reason ?: @"Failed to launch TQSL");
            });
        }
    });
}

#pragma mark - Utility

- (NSString *)urlEncode:(NSString *)str {
    NSMutableCharacterSet *set = [[NSCharacterSet alphanumericCharacterSet] mutableCopy];
    [set addCharactersInString:@"-._~"];
    return [str stringByAddingPercentEncodingWithAllowedCharacters:set] ?: str;
}

- (NSString *)extractQRZReason:(NSString *)text {
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trimmed hasPrefix:@"REASON="]) {
            return [trimmed substringFromIndex:7];
        }
    }
    return text.length > 80 ? [text substringToIndex:80] : text;
}

@end
