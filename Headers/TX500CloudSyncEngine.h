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

// Batch Uploads
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
