//
//  TX500CloudSyncEngine.m
//  Lab599 Utility
//
//  Zero-Click Amateur Radio Cloud Synchronization Engine
//

#import "TX500CloudSyncEngine.h"
#import "TX500WebAuthenticatorController.h"

NSString * const TX500CloudSyncStatusDidChangeNotification = @"TX500CloudSyncStatusDidChangeNotification";

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

@interface TX500CloudSyncEngine ()

@property (nonatomic, copy, readwrite) NSString *lastStatusMessage;
@property (nonatomic, assign, readwrite) BOOL isUploading;
@property (nonatomic, strong) NSMutableArray<TX500CloudUploadItem *> *uploadHistory;
@property (nonatomic, strong) NSURLSession *urlSession;
@property (nonatomic, strong) dispatch_queue_t syncQueue;

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
        
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        config.timeoutIntervalForRequest = 20.0;
        config.timeoutIntervalForResource = 30.0;
        _urlSession = [NSURLSession sessionWithConfiguration:config];
    }
    return self;
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
        pass = [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_LoTW_CertificatePassword"] ?:
               [[NSUserDefaults standardUserDefaults] stringForKey:@"TX500_LoTW_Password"];
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
    BOOL autoUpload = [ud objectForKey:@"TX500_Cloud_AutoUploadEnabled"] ? [ud boolForKey:@"TX500_Cloud_AutoUploadEnabled"] : YES;
    if (!autoUpload) {
        if (completion) completion(YES, @"Auto-upload disabled in settings.");
        return;
    }

    BOOL uploadQRZ = [ud objectForKey:@"TX500_Cloud_UploadQRZ"] ? [ud boolForKey:@"TX500_Cloud_UploadQRZ"] : YES;
    BOOL uploadClubLog = [ud objectForKey:@"TX500_Cloud_UploadClubLog"] ? [ud boolForKey:@"TX500_Cloud_UploadClubLog"] : YES;
    BOOL uploadEQSL = [ud objectForKey:@"TX500_Cloud_UploadEQSL"] ? [ud boolForKey:@"TX500_Cloud_UploadEQSL"] : YES;
    BOOL uploadLoTW = [ud objectForKey:@"TX500_Cloud_UploadLoTW"] ? [ud boolForKey:@"TX500_Cloud_UploadLoTW"] : YES;

    NSString *qrzKey = [ud stringForKey:@"TX500_QRZ_APIKey"] ?: @"";
    NSString *clubEmail = [ud stringForKey:@"TX500_ClubLog_Email"] ?: @"";
    NSString *clubCall = [ud stringForKey:@"TX500_ClubLog_Callsign"] ?: @"";
    NSString *clubPass = [ud stringForKey:@"TX500_ClubLog_Password"] ?: @"";
    NSString *clubKey = [ud stringForKey:@"TX500_ClubLog_APIKey"] ?: @"";
    NSString *eqslUser = [ud stringForKey:@"TX500_EQSL_Username"] ?: @"";
    NSString *eqslPass = [ud stringForKey:@"TX500_EQSL_Password"] ?: @"";
    NSString *lotwLoc = [ud stringForKey:@"TX500_LoTW_StationLocation"] ?: @"";
    NSString *lotwPass = [ud stringForKey:@"TX500_LoTW_Password"] ?: @"";
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
        if (successList.count == 0 && failureList.count == 0) {
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
    NSString *endpoint = @"https://logbook.qrz.com/api";
    NSString *adif = [TX500CloudSyncEngine buildSingleRecordADIF:record];
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
        (void)resp;
        if (err) {
            completion(NO, err.localizedDescription);
            return;
        }
        NSString *respText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        if ([respText containsString:@"RESULT=OK"] || [respText containsString:@"DUPLICATE"]) {
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
    NSString *endpoint = @"https://clublog.org/realtime.php";
    NSString *adif = [TX500CloudSyncEngine buildSingleRecordADIF:record];
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
        (void)resp;
        if (err) {
            completion(NO, err.localizedDescription);
            return;
        }
        NSString *resText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        if ([resText localizedCaseInsensitiveContainsString:@"OK"] || resText.length == 0) {
            completion(YES, @"OK");
        } else {
            completion(NO, [resText substringToIndex:MIN(50, resText.length)]);
        }
    }] resume];
}

- (void)performEQSLUpload:(TX500LogRecord *)record
                 username:(NSString *)username
                 password:(NSString *)password
               completion:(void (^)(BOOL success, NSString *message))completion {
    NSString *endpoint = @"https://www.eqsl.cc/qslcard/ImportADIF.txt";
    NSString *adif = [TX500CloudSyncEngine buildSingleRecordADIF:record];
    NSString *postStr = [NSString stringWithFormat:@"EQSL_USER=%@&EQSL_PSWD=%@&ADIFData=%@",
                         [self urlEncode:username], [self urlEncode:password], [self urlEncode:adif]];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:endpoint]];
    req.HTTPMethod = @"POST";
    req.HTTPBody = [postStr dataUsingEncoding:NSUTF8StringEncoding];
    [req setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"TX500-macOS/1.0" forHTTPHeaderField:@"User-Agent"];

    [[self.urlSession dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        (void)resp;
        if (err) {
            completion(NO, err.localizedDescription);
            return;
        }
        NSString *resText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        if ([resText localizedCaseInsensitiveContainsString:@"Success"] ||
            [resText localizedCaseInsensitiveContainsString:@"Result: 1"]) {
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
    NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tx500_lotw_%@.adi", record.uuid]];
    NSString *adifContent = [TX500CloudSyncEngine buildSingleRecordADIF:record];
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

        [task launch];
        [task waitUntilExit];

        NSData *outData = [[outPipe fileHandleForReading] readDataToEndOfFile];
        NSString *outStr = [[NSString alloc] initWithData:outData encoding:NSUTF8StringEncoding] ?: @"";

        [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
        NSString *companionTq8 = [[tempFile stringByDeletingPathExtension] stringByAppendingPathExtension:@"tq8"];
        [[NSFileManager defaultManager] removeItemAtPath:companionTq8 error:nil];

        int code = task.terminationStatus;
        if (code == 0 || code == 8 || code == 9 || code == 14) {
            completion(YES, @"OK");
        } else {
            completion(NO, [NSString stringWithFormat:@"TQSL exited with %d: %@", code, [outStr substringToIndex:MIN(80, outStr.length)]]);
        }
    } @catch (NSException *ex) {
        [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
        completion(NO, ex.reason ?: @"TQSL process failed");
    }
}

#pragma mark - Batch Uploads

- (void)uploadPendingContactsWithCompletion:(nullable void (^)(NSInteger uploadedCount, NSInteger failedCount, NSString *summary))completion {
    NSArray<TX500LogRecord *> *all = [[TX500LogbookManager sharedManager] allContacts];
    NSMutableArray<TX500LogRecord *> *pending = [NSMutableArray array];
    for (TX500LogRecord *r in all) {
        if ([r.qrzStatus isEqualToString:@"NONE"] || [r.lotwStatus isEqualToString:@"NONE"] || [r.clublogStatus isEqualToString:@"NONE"]) {
            [pending addObject:r];
        }
    }

    if (pending.count == 0) {
        if (completion) completion(0, 0, @"All contacts are already synchronized.");
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block NSInteger successCount = 0;
        __block NSInteger failCount = 0;

        for (TX500LogRecord *rec in pending) {
            dispatch_semaphore_t sema = dispatch_semaphore_create(0);
            [self uploadContactImmediately:rec completion:^(BOOL ok, NSString *summary) {
                (void)summary;
                if (ok) successCount++;
                else failCount++;
                dispatch_semaphore_signal(sema);
            }];
            dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)));
        }

        NSString *msg = [NSString stringWithFormat:@"Batch sync finished: %ld uploaded, %ld failed.", (long)successCount, (long)failCount];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(successCount, failCount, msg);
        });
    });
}

- (void)uploadFullLogbookToLoTWWithCompletion:(nullable void (^)(BOOL success, NSString *message))completion {
    NSString *tqslPath = [TX500CloudSyncEngine discoverTQSLBinaryPath];
    if (!tqslPath) {
        if (completion) completion(NO, @"TrustedQSL (tqsl) binary not found on this Mac. Please install TQSL from arrl.org.");
        return;
    }

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSString *location = [ud stringForKey:@"TX500_LoTW_StationLocation"];
    NSString *password = [ud stringForKey:@"TX500_LoTW_Password"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tx500_full_lotw.adi"];
        NSError *err = nil;
        if (![[TX500LogbookManager sharedManager] exportADIFToFileURL:[NSURL fileURLWithPath:tempFile] error:&err]) {
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

            [task launch];
            [task waitUntilExit];

            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *outStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";

            [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
            NSString *companionTq8 = [[tempFile stringByDeletingPathExtension] stringByAppendingPathExtension:@"tq8"];
            [[NSFileManager defaultManager] removeItemAtPath:companionTq8 error:nil];

            int code = task.terminationStatus;
            BOOL ok = (code == 0 || code == 8 || code == 9 || code == 14);
            NSString *resultMsg = ok ? @"LoTW Full Batch Uploaded Successfully via TQSL!" :
                [NSString stringWithFormat:@"LoTW Error (exit %d): %@", code, outStr];

            if (ok) {
                // Mark all uploaded in DB
                for (TX500LogRecord *r in [[TX500LogbookManager sharedManager] allContacts]) {
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
    NSString *password = [ud stringForKey:@"TX500_LoTW_CertificatePassword"] ?: [ud stringForKey:@"TX500_LoTW_Password"];

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *tempFile = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"tx500_lotw_batch_%@.adi", [[NSUUID UUID] UUIDString]]];
        NSMutableString *adif = [NSMutableString stringWithFormat:@"Lab599 TX-500 LoTW Export\n<ADIF_VER:5>3.1.4 <PROGRAMID:14>Lab599 Utility <EOH>\n\n"];
        for (TX500LogRecord *r in targets) {
            [adif appendString:[r adifRecordString]];
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

            [task launch];
            [task waitUntilExit];

            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *outStr = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";

            [[NSFileManager defaultManager] removeItemAtPath:tempFile error:nil];
            NSString *companionTq8 = [[tempFile stringByDeletingPathExtension] stringByAppendingPathExtension:@"tq8"];
            [[NSFileManager defaultManager] removeItemAtPath:companionTq8 error:nil];

            int code = task.terminationStatus;
            BOOL ok = (code == 0 || code == 8 || code == 9 || code == 14);
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
            (void)resp;
            if (err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, err.localizedDescription);
                });
                return;
            }
            NSString *resText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            BOOL ok = [resText containsString:@"RESULT=OK"];
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
            (void)resp;
            if (err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, err.localizedDescription);
                });
                return;
            }
            NSString *resText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            BOOL ok = [resText localizedCaseInsensitiveContainsString:@"OK"] || resText.length == 0;
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
            (void)resp;
            if (err) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(NO, err.localizedDescription);
                });
                return;
            }
            NSString *resText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
            BOOL ok = [resText localizedCaseInsensitiveContainsString:@"Success"] ||
                      [resText localizedCaseInsensitiveContainsString:@"Result: 1"];
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

            [task launch];
            [task waitUntilExit];

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
