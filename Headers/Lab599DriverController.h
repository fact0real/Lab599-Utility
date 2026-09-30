#import <Cocoa/Cocoa.h>

FOUNDATION_EXPORT NSArray<NSString *> *Lab599CandidateCATPortPaths(NSArray<NSString *> *deviceNames);

@interface Lab599DriverController : NSObject

@property(nonatomic, strong, readonly) NSView *view;
@property(nonatomic, copy) void (^openCATStudio)(void);

- (void)refreshPortStatus;
- (void)refreshDevices;
- (void)openCATStudio:(id)sender;

@end
