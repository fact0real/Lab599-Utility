#import "Lab599AppUpdater.h"
#import "Lab599NetworkIdentity.h"

static NSString *const AutomaticChecksKey = @"SUEnableAutomaticChecks";
static NSString *const AppFeed = @"https://lab599-utility.asis.sh/updates/appcast.xml";

@implementation Lab599AppUpdater {
    SPUStandardUpdaterController *_controller;
    void (^_pendingInstall)(void);
    NSWindow *_waitingWindow;
    NSTextField *_waitingStatus;
    BOOL _installRequested;
    BOOL _verifiedFeed;
    NSWindow *_settingsWindow;
    NSPopUpButton *_schedule;
    NSTextField *_updateStatus;
    NSString *_status;
}
- (BOOL)installRequested { return _installRequested; }
- (BOOL)automaticallyChecks { return [NSUserDefaults.standardUserDefaults boolForKey:AutomaticChecksKey]; }
- (NSTimeInterval)checkInterval {
    double interval = [NSUserDefaults.standardUserDefaults doubleForKey:@"SUScheduledCheckInterval"];
    return (interval == 21600 || interval == 86400 || interval == 604800) ? interval : 86400;
}
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
        [_controller.updater clearFeedURLFromUserDefaults];
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
    [self refreshSettings];
}
- (void)setAutomaticCheckInterval:(NSTimeInterval)interval {
    if (interval != 0 && interval != 21600 && interval != 86400 && interval != 604800) return;
    if (interval > 0) [NSUserDefaults.standardUserDefaults setDouble:interval forKey:@"SUScheduledCheckInterval"];
    [NSUserDefaults.standardUserDefaults setBool:interval > 0 forKey:AutomaticChecksKey];
    [self start];
    _controller.updater.updateCheckInterval = self.checkInterval;
    _controller.updater.automaticallyChecksForUpdates = interval > 0;
    [self refreshSettings];
}
- (void)scheduleChanged:(id)sender { (void)sender; [self setAutomaticCheckInterval:_schedule.selectedItem.tag]; }
- (void)refreshSettings {
    [_schedule selectItemWithTag:self.automaticallyChecks ? (NSInteger)self.checkInterval : 0];
    NSDate *last = _controller.updater.lastUpdateCheckDate;
    NSString *checked = last ? [NSDateFormatter localizedStringFromDate:last dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle] : @"Not checked yet";
    _updateStatus.stringValue = [NSString stringWithFormat:@"%@\nLast check: %@", _status ?: @"Ready to check for signed application updates.", checked];
}
- (void)showSettings:(id)sender {
    (void)sender;
    [self start];
    if (!_settingsWindow) {
        _settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 510, 350)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        _settingsWindow.title = @"Application Updates"; _settingsWindow.releasedWhenClosed = NO;
        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        NSTextField *title = [NSTextField labelWithString:[NSString stringWithFormat:@"Lab599 Utility %@ · Build %@", info[@"CFBundleShortVersionString"] ?: @"", info[@"CFBundleVersion"] ?: @""]];
        title.font = [NSFont boldSystemFontOfSize:18];
        NSTextField *explanation = [NSTextField wrappingLabelWithString:@"Choose when to check for new versions. Downloads and installation require your confirmation. Updates wait until radio operations are stopped; radio firmware uses its own updater."];
        _schedule = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        NSArray *names = @[@"Manual checks only", @"Every 6 hours", @"Every day", @"Every week"];
        NSArray *intervals = @[@0, @21600, @86400, @604800];
        for (NSUInteger i = 0; i < names.count; i++) { [_schedule addItemWithTitle:names[i]]; _schedule.lastItem.tag = [intervals[i] integerValue]; }
        _schedule.target = self; _schedule.action = @selector(scheduleChanged:);
        _updateStatus = [NSTextField wrappingLabelWithString:@""];
        _updateStatus.textColor = NSColor.secondaryLabelColor;
        NSTextField *trust = [NSTextField wrappingLabelWithString:@"Only updates signed by this project are accepted. No callsign, logbook, cloud credentials or system profile is sent by the updater."];
        trust.font = [NSFont systemFontOfSize:11]; trust.textColor = NSColor.secondaryLabelColor;
        NSButton *check = [NSButton buttonWithTitle:@"Check for Updates…" target:self action:@selector(checkForUpdates:)];
        NSStackView *stack = [NSStackView stackViewWithViews:@[title, explanation, _schedule, _updateStatus, trust, check]];
        stack.orientation = NSUserInterfaceLayoutOrientationVertical; stack.alignment = NSLayoutAttributeLeading; stack.spacing = 18;
        stack.translatesAutoresizingMaskIntoConstraints = NO; [_settingsWindow.contentView addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.leadingAnchor constraintEqualToAnchor:_settingsWindow.contentView.leadingAnchor constant:24],
            [stack.trailingAnchor constraintEqualToAnchor:_settingsWindow.contentView.trailingAnchor constant:-24],
            [stack.topAnchor constraintEqualToAnchor:_settingsWindow.contentView.topAnchor constant:25],
            [stack.bottomAnchor constraintLessThanOrEqualToAnchor:_settingsWindow.contentView.bottomAnchor constant:-22],
            [explanation.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
            [trust.widthAnchor constraintEqualToAnchor:stack.widthAnchor],
            [_updateStatus.widthAnchor constraintEqualToAnchor:stack.widthAnchor]
        ]];
        [_settingsWindow center];
    }
    [self refreshSettings]; [_settingsWindow makeKeyAndOrderFront:nil];
}
- (BOOL)validateMenuItem:(NSMenuItem *)item {
    if (item.action == @selector(showSettings:)) return YES;
    if (item.action == @selector(toggleAutomaticChecks:)) {
        item.state = self.automaticallyChecks ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (item.action != @selector(checkForUpdates:)) return YES;
    item.title = _pendingInstall ? @"Finish App Update…" : @"Check for App Updates…";
    return _pendingInstall || !_controller || _controller.updater.canCheckForUpdates;
}
- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater { (void)updater; return AppFeed; }
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater { (void)updater; return NO; }
- (NSArray<NSString *> *)allowedSystemProfileKeysForUpdater:(SPUUpdater *)updater { (void)updater; return @[]; }
- (BOOL)updater:(SPUUpdater *)updater mayPerformUpdateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    (void)updater; (void)check;
    _verifiedFeed = NO;
    if ([self readyToInstall]) { _status = @"Checking for updates…"; [self refreshSettings]; return YES; }
    if (error) *error = [NSError errorWithDomain:@"Lab599AppUpdater" code:1 userInfo:@{NSLocalizedDescriptionKey:
        @"Stop radio operations and finish pending file changes before checking for an application update. Radio firmware updates use the Firmware Update screen."}];
    return NO;
}
- (void)updater:(SPUUpdater *)updater didFinishLoadingAppcast:(SUAppcast *)appcast {
    (void)updater;
    _verifiedFeed = appcast.signingValidationStatus == SPUAppcastSigningValidationStatusSucceeded;
}
- (BOOL)updater:(SPUUpdater *)updater shouldProceedWithUpdate:(SUAppcastItem *)item updateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    (void)updater; (void)check;
    NSURLComponents *url = item.fileURL ? [NSURLComponents componentsWithURL:item.fileURL resolvingAgainstBaseURL:NO] : nil;
    NSRegularExpression *archive = [NSRegularExpression regularExpressionWithPattern:@"^/releases/Lab599-Utility-[0-9]+([.][0-9]+)+[.]zip$" options:0 error:NULL];
    BOOL trustedURL = [url.scheme.lowercaseString isEqualToString:@"https"] &&
        [url.host.lowercaseString isEqualToString:@"lab599-utility.asis.sh"] &&
        (!url.port || url.port.integerValue == 443) && !url.user && !url.password && !url.query && !url.fragment &&
        [url.percentEncodedPath isEqualToString:url.path] &&
        [archive numberOfMatchesInString:url.path ?: @"" options:0 range:NSMakeRange(0, url.path.length)] == 1;
    if (_verifiedFeed && trustedURL && item.contentLength > 0 && [self readyToInstall]) return YES;
    if (error) *error = [NSError errorWithDomain:@"Lab599AppUpdater" code:2 userInfo:@{NSLocalizedDescriptionKey:
        @"The update was not accepted. A verified signed feed, a release from lab599-utility.asis.sh and an idle station are required. The current application has not changed."}];
    return NO;
}
- (BOOL)updater:(SPUUpdater *)updater shouldDownloadReleaseNotesForUpdate:(SUAppcastItem *)item {
    (void)updater; (void)item;
    return NO; // Release notes are embedded in the signed feed.
}
- (void)updater:(SPUUpdater *)updater didFindValidUpdate:(SUAppcastItem *)item {
    (void)updater; _status = [NSString stringWithFormat:@"Version %@ is available.", item.displayVersionString]; [self refreshSettings];
}
- (void)updaterDidNotFindUpdate:(SPUUpdater *)updater error:(NSError *)error {
    (void)updater; (void)error; _status = @"No compatible newer release is available in the signed feed."; [self refreshSettings];
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
    if (!_pendingInstall || _installRequested) return;
    if (![self readyToInstall]) {
        _waitingStatus.stringValue = @"The radio or a file operation is still active. Stop monitoring and transmitting, finish or cancel pending file changes, then choose Install & Relaunch again. The current application has not been replaced.";
        return;
    }
    _installRequested = YES;
    void (^resume)(void) = _pendingInstall;
    [_waitingWindow orderOut:nil];
    resume();
}
- (void)installationWasDeferred {
    _installRequested = NO;
    _waitingStatus.stringValue = @"Installation was postponed because the station or a file operation became active. Finish that work before trying again.";
    [self showWaitingWindow];
}
- (void)postpone:(id)sender { (void)sender; [_waitingWindow orderOut:nil]; }
- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error {
    (void)updater;
    _status = error.code == SUNoUpdateError ? @"No compatible newer release is available in the signed feed." : @"The update did not complete. Check the installed version before trying again.";
    [self refreshSettings];
    _verifiedFeed = NO;
    _installRequested = NO;
    _pendingInstall = nil;
    [_waitingWindow orderOut:nil];
}
@end
