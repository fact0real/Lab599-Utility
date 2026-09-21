//
//  TX500LogbookManager.h
//  Lab599 Utility
//
//  Production-Grade SQLite3 Logbook & ADIF 3.1 Subsystem
//  Supports voice (SSB/AM/FM), CW, and FT8/FT4 digital modes with persistent storage,
//  deduplication, search, and cloud synchronization metadata.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString * const TX500LogbookDidChangeNotification;

@interface TX500LogRecord : NSObject <NSCopying>

@property (nonatomic, copy) NSString *uuid;
@property (nonatomic, copy) NSString *callsign;
@property (nonatomic, copy) NSString *qsoDate;      // YYYYMMDD (UTC)
@property (nonatomic, copy) NSString *timeOn;       // HHMMSS (UTC)
@property (nonatomic, copy, nullable) NSString *timeOff;      // HHMMSS (UTC)
@property (nonatomic, copy) NSString *band;         // e.g. "20m", "40m"
@property (nonatomic, assign) uint64_t frequencyHz;
@property (nonatomic, copy) NSString *mode;         // "USB", "LSB", "CW", "FT8", "FT4", "AM", "FM"
@property (nonatomic, copy, nullable) NSString *submode;
@property (nonatomic, copy) NSString *rstSent;      // "59", "599", "-12"
@property (nonatomic, copy) NSString *rstRcvd;      // "59", "599", "+02"
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic, copy, nullable) NSString *qth;
@property (nonatomic, copy, nullable) NSString *state;
@property (nonatomic, copy, nullable) NSString *country;
@property (nonatomic, copy, nullable) NSString *grid;
@property (nonatomic, copy, nullable) NSString *notes;
@property (nonatomic, assign) NSInteger powerWatts;
@property (nonatomic, copy, nullable) NSString *myCall;
@property (nonatomic, copy, nullable) NSString *myGrid;

// Cloud Sync State
@property (nonatomic, copy) NSString *qrzStatus;     // "NONE", "QUEUED", "UPLOADED", "CONFIRMED", "ERROR"
@property (nonatomic, copy) NSString *lotwStatus;    // "NONE", "QUEUED", "UPLOADED", "CONFIRMED", "ERROR"
@property (nonatomic, copy) NSString *clublogStatus; // "NONE", "QUEUED", "UPLOADED", "ERROR"
@property (nonatomic, copy) NSString *eqslStatus;    // "NONE", "QUEUED", "UPLOADED", "ERROR"
@property (nonatomic, copy, nullable) NSString *imageURL;

@property (nonatomic, assign) NSTimeInterval createdTimestamp;
@property (nonatomic, assign) NSTimeInterval updatedTimestamp;

- (NSString *)formattedDate;
- (NSString *)formattedTime;
- (double)frequencyMHz;
- (NSString *)adifRecordString;
+ (nullable TX500LogRecord *)recordFromADIFRecordText:(NSString *)adifText;
+ (NSString *)bandForFrequencyHz:(uint64_t)freqHz;

@end

@class TX500FT8LoggedQSO;
@class TX500QSOContact;

@interface TX500LogbookManager : NSObject

+ (instancetype)sharedManager;
- (instancetype)initWithDatabaseURL:(nullable NSURL *)customURL;

@property (nonatomic, strong, readonly) NSURL *databaseURL;

// Database Lifecycle
- (BOOL)openDatabase:(NSError **)error;
- (void)closeDatabase;

// CRUD Operations
- (BOOL)saveContact:(TX500LogRecord *)record error:(NSError **)error;
- (BOOL)deleteContactWithUUID:(NSString *)uuid error:(NSError **)error;
- (nullable TX500LogRecord *)contactWithUUID:(NSString *)uuid;
- (NSArray<TX500LogRecord *> *)allContacts;
- (NSArray<TX500LogRecord *> *)searchContactsWithQuery:(nullable NSString *)query
                                                  band:(nullable NSString *)band
                                                  mode:(nullable NSString *)mode;
- (NSInteger)totalContactCount;
- (NSInteger)confirmedContactCount;

// Cloud Status Updates
- (BOOL)updateCloudStatusForUUID:(NSString *)uuid
                         service:(NSString *)service
                          status:(NSString *)status
                           error:(NSError **)error;

// Adapters for FT8 and CW existing models
- (BOOL)addContactFromFT8:(TX500FT8LoggedQSO *)ft8QSO myCall:(nullable NSString *)myCall myGrid:(nullable NSString *)myGrid;
- (BOOL)addContactFromCW:(TX500QSOContact *)cwContact myCall:(nullable NSString *)myCall myGrid:(nullable NSString *)myGrid;

// ADIF 3.1 File Operations
- (NSString *)exportFullADIFStringWithProgramId:(NSString *)programId;
- (BOOL)exportADIFToFileURL:(NSURL *)fileURL error:(NSError **)error;
- (NSInteger)importADIFFromFileURL:(NSURL *)fileURL
                   duplicatesCount:(NSInteger * _Nullable)outDuplicates
                             error:(NSError **)error;

// Convenience
- (void)clearAllContactsForTesting;

@end

NS_ASSUME_NONNULL_END
