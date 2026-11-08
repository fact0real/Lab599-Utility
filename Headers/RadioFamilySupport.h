#import <Cocoa/Cocoa.h>
NS_ASSUME_NONNULL_BEGIN
@interface RadioFamilySupport : NSObject
+ (NSURL *)rootURL;
+ (void)recordEvent:(NSString *)event details:(NSDictionary *)details;
+ (void)showSettings;
+ (void)flushDiagnostics;
@end
NS_ASSUME_NONNULL_END
