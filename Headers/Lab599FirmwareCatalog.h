#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Lab599FirmwareItem : NSObject

@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy) NSString *model;
@property(nonatomic, copy) NSString *version;
@property(nonatomic, copy) NSString *fileSizeString;
@property(nonatomic, strong) NSURL *downloadURL;
@property(nonatomic, copy, nullable) NSString *expectedSHA256;
@property(nonatomic, copy) NSString *changelog;
@property(nonatomic) BOOL isLatest;

- (NSString *)displayTitle;

@end

@interface Lab599FirmwareCatalog : NSObject

+ (instancetype)sharedCatalog;

// Fetches the firmware listings from the two official Lab599 pages.
- (void)fetchAvailableFirmwaresWithCompletion:(void (^)(NSArray<Lab599FirmwareItem *> *items, NSError * _Nullable error))completion;

// Downloads a specific firmware item to the application cache/temporary directory
- (nullable NSURLSessionDownloadTask *)downloadFirmware:(Lab599FirmwareItem *)item
                                     progress:(nullable void (^)(double progress, int64_t bytesWritten, int64_t totalExpected))progressHandler
                                   completion:(void (^)(NSURL * _Nullable localFileURL, NSString * _Nullable sha256, NSError * _Nullable error))completionHandler;

// Static list of verified known firmwares as reliable fallback
+ (NSArray<Lab599FirmwareItem *> *)fallbackFirmwareCatalog;

@end

NS_ASSUME_NONNULL_END
