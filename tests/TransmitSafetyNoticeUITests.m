#import <Cocoa/Cocoa.h>
#import "TX500TransmitSafetyBanner.h"
@interface SafetyAckFixture : NSObject
@property BOOL acknowledged;
- (void)ack:(id)sender;
@end
@implementation SafetyAckFixture
- (void)ack:(id)sender { (void)sender; self.acknowledged=YES; }
@end
int main(void) { @autoreleasepool {
    NSApplication *app=NSApplication.sharedApplication; [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
    SafetyAckFixture *fixture=[SafetyAckFixture new];
    for(NSString *appearanceName in @[NSAppearanceNameAqua,NSAppearanceNameDarkAqua]) {
        app.appearance=[NSAppearance appearanceNamed:appearanceName];
        for(NSNumber *width in @[@660,@1000]) {
            NSTextField *message=nil;
            NSStackView *banner=TX500MakeTransmitSafetyBanner(fixture,@selector(ack:),&message);
            message.stringValue=@"Lab599 TX-500 (CAT): CW radio audio was lost; RX requested, receive NOT confirmed at 2026-10-23 06:00:00 UTC. Other tools remain available. Check the radio is on receive locally before sending again.";
            NSWindow *window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,width.doubleValue,250) styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
            window.releasedWhenClosed=NO;
            window.appearance=app.appearance;
            NSView *root=window.contentView; root.wantsLayer=YES;
            [app.appearance performAsCurrentDrawingAppearance:^{ root.layer.backgroundColor=NSColor.windowBackgroundColor.CGColor; }]; banner.translatesAutoresizingMaskIntoConstraints=NO; [root addSubview:banner];
            [NSLayoutConstraint activateConstraints:@[[banner.leadingAnchor constraintEqualToAnchor:root.leadingAnchor constant:12],[banner.trailingAnchor constraintEqualToAnchor:root.trailingAnchor constant:-12],[banner.topAnchor constraintEqualToAnchor:root.topAnchor constant:12],[message.widthAnchor constraintEqualToAnchor:banner.widthAnchor constant:-24]]];
            [window makeKeyAndOrderFront:nil]; [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]]; [root layoutSubtreeIfNeeded];
            NSButton *ack=banner.arrangedSubviews.lastObject;
            if(message.frame.size.height<30 || message.frame.size.width>width.doubleValue || ack.frame.size.width>banner.frame.size.width || ack.frame.size.height<20 || ack.frame.size.width<150 || banner.frame.size.height>240) return 1;
            [ack performClick:nil]; if(!fixture.acknowledged) return 2;
            NSBitmapImageRep *rep=[root bitmapImageRepForCachingDisplayInRect:root.bounds]; [root cacheDisplayInRect:root.bounds toBitmapImageRep:rep];
            NSString *file=[NSString stringWithFormat:@"validation/transmit-safety-%@-%@.png",width,[appearanceName isEqual:NSAppearanceNameAqua]?@"light":@"dark"];
            [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:file atomically:YES];
            [window orderOut:nil];
        }
    }
    puts("PASS actual transmit notice UI: compact/normal, light/dark, wrapping and operator acknowledgement; no devices.");
} return 0; }
