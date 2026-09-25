#import <Cocoa/Cocoa.h>
#import "TX500StationCore.h"
#import "TX500StationStore.h"
NS_ASSUME_NONNULL_BEGIN
@interface TX500StationController : NSObject
@property(nonatomic, readonly) NSView *view;
@property(nonatomic, readonly) BOOL busy;
@property(nonatomic, strong) TX500StationCore *core;
@property(nonatomic, copy, nullable) BOOL (^prepareControl)(void);
@property(nonatomic, copy, nullable) BOOL (^canEditStation)(void);
@property(nonatomic, copy, nullable) void (^commandHandler)(NSString *command);
@property(nonatomic, copy, nullable) void (^logHandler)(NSString *message);
- (void)activate;
- (void)runCommand:(NSString *)command;
- (void)refresh;
@end
NS_ASSUME_NONNULL_END
