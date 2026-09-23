#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const TXStationStoreChanged;
@interface TX500StationStore : NSObject
@property(nonatomic, readonly) NSArray<NSDictionary *> *profiles;
@property(nonatomic, readonly) NSDictionary *activeProfile;
@property(nonatomic, readonly) NSArray<NSDictionary *> *frequencies;
@property(nonatomic, readonly) NSDictionary<NSString *,NSString *> *shortcuts;
@property(nonatomic, readonly, nullable) NSError *loadError;
+ (instancetype)sharedStore;
- (instancetype)initWithURL:(NSURL *)URL defaults:(NSUserDefaults *)defaults;
- (BOOL)saveProfile:(NSDictionary *)profile activate:(BOOL)activate error:(NSError **)error;
- (BOOL)activateProfile:(NSString *)identifier error:(NSError **)error;
- (BOOL)removeProfile:(NSString *)identifier error:(NSError **)error;
- (BOOL)saveFrequency:(NSDictionary *)entry error:(NSError **)error;
- (BOOL)removeFrequency:(NSString *)identifier error:(NSError **)error;
- (BOOL)setShortcut:(NSString *)key command:(NSString *)command error:(NSError **)error;
- (BOOL)saveShortcuts:(NSDictionary<NSString *,NSString *> *)shortcuts error:(NSError **)error;
- (void)captureLegacySettings;
+ (BOOL)parseMHz:(NSString *)text hertz:(uint64_t * _Nullable)hz;
+ (NSArray<NSDictionary *> *)bandSegments;
+ (NSArray<NSDictionary *> *)segmentsAt:(uint64_t)hz;
@end
NS_ASSUME_NONNULL_END
