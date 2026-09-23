#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT NSString *const TXPSKReporterChanged;
@interface TX500PSKReporter : NSObject
+ (instancetype)sharedReporter;
@property(nonatomic) BOOL enabled;
@property(nonatomic, readonly, copy) NSString *status;
@property(nonatomic, readonly) NSUInteger pendingCount;
@property(nonatomic, copy, nullable) BOOL (^sender)(NSData *packet, NSError **error);
- (void)enqueue:(NSDictionary *)spot receiver:(NSDictionary *)receiver;
- (void)flush;
+ (nullable NSData *)packetForReceiver:(NSDictionary *)receiver spots:(NSArray<NSDictionary *> *)spots timestamp:(uint32_t)timestamp sequence:(uint32_t)sequence domain:(uint32_t)domain;
@end
NS_ASSUME_NONNULL_END
