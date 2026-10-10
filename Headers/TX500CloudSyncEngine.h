//
//  TX500CloudSyncEngine.h
//  Lab599 Utility
//
//  Zero-Click Amateur Radio Cloud Synchronization Engine
//  Coordinates background uploads to QRZ.com Logbook API, ClubLog real-time API,
//  eQSL.cc, and ARRL LoTW via TrustedQSL (TQSL).
//

#import <Foundation/Foundation.h>
#import "TX500LogbookManager.h"

NS_ASSUME_NONNULL_BEGIN

extern NSString * const TX500CloudSyncStatusDidChangeNotification;
FOUNDATION_EXPORT BOOL TX500ClubLogResponseIsSuccess(NSHTTPURLResponse * _Nullable response, NSData * _Nullable data);
// QRZ's answer to an upload: RESULT=OK, or a duplicate (in any case), from QRZ's own address
FOUNDATION_EXPORT BOOL TX500QRZResponseIsSuccess(NSURLResponse * _Nullable response, NSString * _Nullable text);

@interface TX500CloudUploadItem : NSObject

@property (nonatomic, copy) NSString *callsign;
@property (nonatomic, copy) NSString *band;
@property (nonatomic, copy) NSString *mode;
@property (nonatomic, copy) NSArray<NSString *> *services;
@property (nonatomic, assign) NSInteger latencyMs;
@property (nonatomic, assign) BOOL success;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, strong) NSDate *timestamp;

@end

@interface TX500CloudSyncEngine : NSObject

+ (instancetype)sharedEngine;

// Current Activity & History
@property (nonatomic, copy, readonly) NSString *lastStatusMessage;
@property (nonatomic, assign, readonly) BOOL isUploading;
@property (nonatomic, strong, readonly) NSArray<TX500CloudUploadItem *> *recentUploads;

// Zero-Click Automated Upload
- (void)uploadContactImmediately:(TX500LogRecord *)record
                       completion:(nullable void (^)(BOOL overallSuccess, NSString *summary))completion;
// One contact to the services named ("QRZ", "ClubLog", "eQSL", "LoTW") that are enabled and
// configured; nil names every one of them, as the upload after a QSO does. A success marks the
// contact UPLOADED there, and never lowers a CONFIRMED.
- (void)uploadContact:(TX500LogRecord *)record
           toServices:(nullable NSArray<NSString *> *)services
           completion:(nullable void (^)(BOOL overallSuccess, NSString *summary))completion;

// Sync. A contact is pending on a service while the service does not have it: its status there is
// anything but UPLOADED or CONFIRMED (NONE, QUEUED, ERROR, or none). A sync sends each contact only to
// the services that are enabled and configured and where it is still pending, never again to one
// where it is UPLOADED or CONFIRMED. The mode of a contact plays no part.
+ (BOOL)isPendingStatus:(nullable NSString *)status;
// The services enabled and configured now (Settings), in the order "QRZ", "ClubLog", "eQSL", "LoTW"
- (NSArray<NSString *> *)enabledConfiguredServices;
// The services one upload sends to: those named among the enabled and configured ones. nil (the
// upload after a QSO) names all of them, and the TX500_Cloud_AutoUploadEnabled switch can stop it.
- (NSArray<NSString *> *)servicesForUpload:(nullable NSArray<NSString *> *)requested;
// YES while a sync's uploads run, or while TQSL runs or a LoTW upload is about to start it (one sync at a time)
@property (nonatomic, readonly) BOOL syncInProgress;
// How many TQSL processes the engine has running now (every one it starts is counted)
@property (nonatomic, readonly) NSInteger tqslRunning;
// YES while TQSL runs, or while a LoTW upload of a sync or after a QSO has taken LoTW and is about to start it
@property (nonatomic, readonly) BOOL tqslBusy;
// How long a sync waits for one contact's upload before it goes on with the next (60 s; the tests shorten it).
// An upload to LoTW waits for TQSL, which has no time limit. A sync and the upload after a QSO take LoTW when
// they decide to send to it, only while no TQSL runs and none is about to, so they never start a second one
// (LoTW Upload… is kept as it is).
@property (nonatomic, assign) NSTimeInterval syncUploadWaitSeconds;
// The services among those given where the contact is still pending
+ (NSArray<NSString *> *)pendingServicesOfContact:(TX500LogRecord *)record among:(NSArray<NSString *> *)services;
// The uploads of Sync All (records nil: the whole logbook; the Logbook then downloads the LoTW
// confirmations) and of Sync Selected (the records given; nothing is downloaded). A service that
// fails twice in a row is not asked again in that sync. The summary says, for each service, how many
// were uploaded, already there, failed or left pending, and which services were not checked.
- (void)syncContacts:(nullable NSArray<TX500LogRecord *> *)records
          completion:(nullable void (^)(NSInteger uploadedCount, NSInteger failedCount, NSString *summary))completion;

// Batch Uploads
// The uploads of Sync All only (no LoTW download: the Logbook's Sync All adds it)
- (void)uploadPendingContactsWithCompletion:(nullable void (^)(NSInteger uploadedCount, NSInteger failedCount, NSString *summary))completion;
- (void)uploadFullLogbookToLoTWWithCompletion:(nullable void (^)(BOOL success, NSString *message))completion;
- (void)signAndUploadContactsToLoTW:(NSArray<TX500LogRecord *> *)records completion:(nullable void (^)(BOOL success, NSString *message))completion;

// Service Verification Tests
- (void)testQRZLogbookAPIKey:(NSString *)apiKey
                  completion:(void (^)(BOOL success, NSString *message))completion;

- (void)testClubLogCredentialsWithEmail:(NSString *)email
                               callsign:(NSString *)callsign
                               password:(NSString *)password
                                 apiKey:(NSString *)apiKey
                             completion:(void (^)(BOOL success, NSString *message))completion;

- (void)testEQSLCredentialsWithUsername:(NSString *)username
                               password:(NSString *)password
                             completion:(void (^)(BOOL success, NSString *message))completion;

- (void)testLoTWSetupWithLocation:(nullable NSString *)location
                         password:(nullable NSString *)password
                         tqslPath:(nullable NSString *)tqslPath
                       completion:(void (^)(BOOL success, NSString *message))completion;

// TQSL Discovery & Storage Sync
+ (nullable NSString *)discoverTQSLBinaryPath;
+ (BOOL)synchronizeTQSLStorage;

// Payload Builders for tests
+ (NSString *)buildSingleRecordADIF:(TX500LogRecord *)record;
+ (NSArray<NSString *> *)buildTQSLArgumentsForADIFPath:(NSString *)path
                                              location:(nullable NSString *)location
                                              password:(nullable NSString *)password;

@end

NS_ASSUME_NONNULL_END
