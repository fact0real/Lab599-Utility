#import <Cocoa/Cocoa.h>
#import "TX500DXCluster.h"
#import "TX500StationCore.h"
#import "TX500LogbookManager.h"
NS_ASSUME_NONNULL_BEGIN
@interface TX500DXClusterController : NSObject
@property(nonatomic,readonly) NSView *view;
@property(nonatomic,readonly) TX500DXCluster *engine;
@property(nonatomic,readonly) BOOL busy;
@property(nonatomic,strong) TX500StationCore *core;
@property(nonatomic,strong) TX500LogbookManager *logbook;
@property(nonatomic,copy,nullable) BOOL (^prepareControl)(void);
@property(nonatomic,copy,nullable) void (^draftHandler)(TX500DXSpot *spot,NSString *mode);
- (void)activate;
- (void)stop;
- (void)loadDemo;
@end
NS_ASSUME_NONNULL_END
