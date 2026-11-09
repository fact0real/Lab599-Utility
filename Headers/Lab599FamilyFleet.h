#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Opt-in presence publisher for the shared Radio Utility family cloud folder.
/// It only answers status requests and never accesses CAT, PTT, or logbook data.
@interface Lab599FamilyFleet : NSObject

@property(nonatomic, getter=isEnabled) BOOL enabled;

+ (instancetype)sharedFleet;
- (void)refreshFromPreferences;
- (void)stop;
- (NSString *)liveStatusSummary;

@end

NS_ASSUME_NONNULL_END
