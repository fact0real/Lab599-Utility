// Disposable Sparkle installation fixture. Never linked into the product.
#import <Cocoa/Cocoa.h>
#import "Lab599AppUpdater.h"
@interface UpdateQAHarness : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property Lab599AppUpdater *updater;
@property NSButton *busy;
@end
@implementation UpdateQAHarness
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    self.updater = [Lab599AppUpdater new];
    __weak typeof(self) weakSelf = self;
    self.updater.canInstallUpdate = ^BOOL { return weakSelf.busy.state != NSControlStateValueOn; };
    NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,440,220) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
    self.window.title = [@"Update QA · Build " stringByAppendingString:version];
    self.window.releasedWhenClosed = NO;
    NSTextField *label = [NSTextField labelWithString:@"Disposable update fixture. No radio or user logbook is opened."];
    label.frame = NSMakeRect(20,150,400,45); label.lineBreakMode = NSLineBreakByWordWrapping;
    self.busy = [NSButton checkboxWithTitle:@"Simulate active station" target:nil action:nil]; self.busy.frame=NSMakeRect(20,105,300,30);
    NSButton *check = [NSButton buttonWithTitle:@"Check for Updates…" target:self.updater action:@selector(checkForUpdates:)];check.frame=NSMakeRect(20,50,200,32);
    [self.window.contentView addSubview:label];[self.window.contentView addSubview:self.busy];[self.window.contentView addSubview:check];
    NSMenu *menu=[NSMenu new];NSMenuItem *app=[NSMenuItem new];[menu addItem:app];NSMenu *sub=[NSMenu new];[sub addItemWithTitle:@"Quit Update QA" action:@selector(terminate:) keyEquivalent:@"q"];app.submenu=sub;NSApp.mainMenu=menu;
    [self.updater start];[self.window center];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];
}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)app {
    (void)app;
    if(self.updater.installRequested && self.busy.state == NSControlStateValueOn){[self.updater installationWasDeferred];return NSTerminateCancel;}
    return NSTerminateNow;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app {(void)app;return YES;}
@end
int main(void){@autoreleasepool{[NSApplication sharedApplication];[NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];UpdateQAHarness *d=[UpdateQAHarness new];NSApp.delegate=d;[NSApp run];}return 0;}
