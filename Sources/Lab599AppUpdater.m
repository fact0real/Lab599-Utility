#import "Lab599AppUpdater.h"
#import "Lab599NetworkIdentity.h"

static NSString *const AutomaticChecksKey = @"SUEnableAutomaticChecks";
static NSString *const AppFeed = @"https://raw.githubusercontent.com/fact0real/Lab599-Utility/main/updates/appcast.xml";

@implementation Lab599AppUpdater {
    SPUStandardUpdaterController *_controller;
    void (^_pendingInstall)(void);
    NSWindow *_waitingWindow;
    NSTextField *_waitingStatus;
    BOOL _installRequested;
}
- (BOOL)installRequested { return _installRequested; }
- (BOOL)automaticallyChecks { return [NSUserDefaults.standardUserDefaults boolForKey:AutomaticChecksKey]; }
- (BOOL)readyToInstall { return self.canInstallUpdate && self.canInstallUpdate(); }
- (void)start {
    if (_controller) return;
    // No network consent prompt and no automatic downloads, installations or
    // system-profile submissions, even if legacy Sparkle defaults were set.
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"SUAutomaticallyUpdate"];
    [NSUserDefaults.standardUserDefaults setBool:NO forKey:@"SUSendProfileInfo"];
    _controller = [[SPUStandardUpdaterController alloc] initWithStartingUpdater:NO updaterDelegate:self userDriverDelegate:nil];
    _controller.updater.userAgentString = Lab599HTTPUserAgent();
    NSError *error = nil;
    if (![_controller.updater startUpdater:&error]) {
        _controller = nil;
        NSLog(@"Application updater unavailable: %@", error.localizedDescription);
    } else {
        _controller.updater.automaticallyDownloadsUpdates = NO;
        _controller.updater.sendsSystemProfile = NO;
    }
}
- (void)checkForUpdates:(id)sender {
    if (_pendingInstall) { [self showWaitingWindow]; return; }
    [self start];
    if (!_controller) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = @"Application updates are unavailable";
        alert.informativeText = @"The update configuration could not be initialized. Your current application has not changed.";
        [alert runModal];
        return;
    }
    [_controller checkForUpdates:sender];
}
- (void)toggleAutomaticChecks:(id)sender {
    (void)sender;
    BOOL enabled = !self.automaticallyChecks;
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:AutomaticChecksKey];
    [self start];
    _controller.updater.automaticallyChecksForUpdates = enabled;
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(toggleAutomaticChecks:)) {
        item.state = self.automaticallyChecks ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    item.title = _pendingInstall ? @"Finish App Update…" : @"Check for App Updates…";
    return _pendingInstall || !_controller || _controller.updater.canCheckForUpdates;
}
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater { (void)updater; return AppFeed; }
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater { (void)updater; return NO; }
- (NSArray<NSString *> *)allowedSystemProfileKeysForUpdater:(SPUUpdater *)updater { (void)updater; return @[]; }
- (BOOL)updater:(SPUUpdater *)updater mayPerformUpdateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    (void)updater; (void)check;
    if ([self readyToInstall]) return YES;
    if (error) *error = [NSError errorWithDomain:@"Lab599AppUpdater" code:1 userInfo:@{NSLocalizedDescriptionKey:
        @"Stop radio operations and finish pending file changes before checking for an application update. Radio firmware updates use the Firmware Update screen."}];
    return NO;
}
- (BOOL)updater:(SPUUpdater *)updater shouldPostponeRelaunchForUpdate:(SUAppcastItem *)item untilInvokingBlock:(void (^)(void))installHandler {
    (void)updater; (void)item;
    // Always take one last explicit step here, even if the update was checked
    // while idle. Radio activity may have started during the download.
    _pendingInstall = [installHandler copy];
    [self showWaitingWindow];
    return YES;
}
- (void)showWaitingWindow {
    if (!_waitingWindow) {
        _waitingWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 480, 220)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        _waitingWindow.title = @"Install Application Update";
        _waitingWindow.releasedWhenClosed = NO;
        NSTextField *title = [NSTextField labelWithString:@"Your verified update is ready"];
        title.font = [NSFont boldSystemFontOfSize:17];
        _waitingStatus = [NSTextField wrappingLabelWithString:@"Stop radio operations before continuing. Your logbook and station settings remain in their existing data folders. This updates the Mac application, not the radio firmware."];
        NSButton *install = [NSButton buttonWithTitle:@"Install & Relaunch" target:self action:@selector(installWhenReady:)];
        NSButton *later = [NSButton buttonWithTitle:@"Later" target:self action:@selector(postpone:)];
        NSStackView *buttons = [NSStackView stackViewWithViews:@[later, install]];
        buttons.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        NSStackView *stack = [NSStackView stackViewWithViews:@[title, _waitingStatus, buttons]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical;
        stack.alignment = NSLayoutAttributeLeading;
        stack.spacing = 18;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [_waitingWindow.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:_waitingWindow.contentView.leadingAnchor constant:22],
            [stack.trailingAnchor constraintEqualToAnchor:_waitingWindow.contentView.trailingAnchor constant:-22],
            [stack.centerYAnchor constraintEqualToAnchor:_waitingWindow.contentView.centerYAnchor],
            [_waitingStatus.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
        ]];
        [_waitingWindow center];
    }
    [_waitingWindow makeKeyAndOrderFront:nil];
}
- (void)installWhenReady:(id)sender {
    (void)sender;
    if (!_pendingInstall) return;
    if (![self readyToInstall]) {
        _waitingStatus.stringValue = @"The radio or a file operation is still active. Stop monitoring and transmitting, finish or cancel pending file changes, then choose Install & Relaunch again. The current application has not been replaced.";
        return;
    }
    _installRequested = YES;
    void (^resume)(void) = _pendingInstall;
    _pendingInstall = nil;
    [_waitingWindow orderOut:nil];
    resume();
}
- (void)postpone:(id)sender { (void)sender; [_waitingWindow orderOut:nil]; }
- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error {
    (void)updater; (void)error;
    _installRequested = NO;
    _pendingInstall = nil;
    [_waitingWindow orderOut:nil];
}
@end
