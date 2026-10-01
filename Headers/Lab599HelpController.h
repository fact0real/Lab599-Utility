#import <Cocoa/Cocoa.h>

@interface Lab599HelpController : NSObject

@property(nonatomic, strong, readonly) NSView *view;

- (void)loadHelpIfNeeded;
- (void)showTopic:(NSString *)topic;
- (void)setViewportHeight:(CGFloat)height;

@end
