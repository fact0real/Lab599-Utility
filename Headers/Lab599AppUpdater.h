#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>

// Application updates only. Radio firmware continues to use its own catalog.
@interface Lab599AppUpdater : NSObject <SPUUpdaterDelegate, NSMenuItemValidation>
@property(nonatomic, copy) BOOL (^canInstallUpdate)(void);
@property(nonatomic, readonly) BOOL installRequested;
@property(nonatomic, readonly) BOOL automaticallyChecks;
- (void)start;
- (void)checkForUpdates:(id)sender;
- (void)toggleAutomaticChecks:(id)sender;
@end
