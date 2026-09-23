#import <Cocoa/Cocoa.h>
#import "TX500VoiceKeyer.h"
NS_ASSUME_NONNULL_BEGIN
@interface TX500VoiceKeyerController : NSObject
@property(nonatomic, readonly) NSView *view;
@property(nonatomic, readonly, nullable) TX500VoiceKeyer *keyer;
@property(nonatomic, copy, nullable) NSString * _Nullable (^selectedPortProvider)(void);
@property(nonatomic, copy, nullable) void (^logHandler)(NSString *line);
@property(nonatomic, copy, nullable) void (^stateChanged)(void);
@property(nonatomic, copy, nullable) id<TX500VoiceRadio> (^radioProvider)(NSString *port);
- (void)activate;
- (BOOL)deactivate;
@end
NS_ASSUME_NONNULL_END
