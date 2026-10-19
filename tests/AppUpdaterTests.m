#import <Cocoa/Cocoa.h>
#import "Lab599AppUpdater.h"
@interface Lab599AppUpdater (Testing)
- (void)installWhenReady:(id)sender;
@end
static void Check(BOOL value, NSString *message) {
    if (!value) { fprintf(stderr, "FAIL: %s\n", message.UTF8String); exit(1); }
}
int main(void) {
    @autoreleasepool {
        [NSApplication sharedApplication];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:@"Resources/Info.plist"];
        Check([plist[@"SURequireSignedFeed"] boolValue] && [plist[@"SUVerifyUpdateBeforeExtraction"] boolValue], @"Feed and archive signatures are mandatory");
        Check([plist[@"SUSignedFeedFailureExpirationInterval"] integerValue] == 0 && plist[@"SUSignedFeedFailureExpirationInterval"] != nil, @"Invalid-feed failure cannot expire into a fallback");
        Check(![plist[@"SUEnableAutomaticChecks"] boolValue] && ![plist[@"SUAllowsAutomaticUpdates"] boolValue] && ![plist[@"SUAutomaticallyUpdate"] boolValue], @"No background checking/download/install by default");
        NSData *key = [[NSData alloc] initWithBase64EncodedString:plist[@"SUPublicEDKey"] options:0];
        Check(key.length == 32, @"Pinned Ed25519 public key");
        Lab599AppUpdater *updater = [Lab599AppUpdater new];
        [updater start];
        SPUStandardUpdaterController *runtime = [updater valueForKey:@"controller"];
        Check(runtime != nil && !runtime.updater.automaticallyChecksForUpdates &&
              !runtime.updater.automaticallyDownloadsUpdates && !runtime.updater.sendsSystemProfile,
              @"Updater starts in a real app bundle with no automatic network checks or profiling");
        __block BOOL idle = NO;
        updater.canInstallUpdate = ^BOOL { return idle; };
        NSError *error = nil;
        Check(![updater updater:nil mayPerformUpdateCheck:SPUUpdateCheckUpdates error:&error] && error != nil, @"Active radio blocks update check with explanation");
        idle = YES;
        Check([updater updater:nil mayPerformUpdateCheck:SPUUpdateCheckUpdates error:NULL], @"Idle permits explicit check");
        Check(![updater updaterShouldPromptForPermissionToCheckForUpdates:nil], @"Launch does not solicit background checking");
        __block NSUInteger installs = 0;
        Check([updater updater:nil shouldPostponeRelaunchForUpdate:nil untilInvokingBlock:^{ installs++; }], @"Downloaded update still requires explicit relaunch decision");
        idle = NO;
        [updater installWhenReady:nil];
        Check(installs == 0 && !updater.installRequested, @"Radio activity that begins after download blocks install");
        idle = YES;
        [updater installWhenReady:nil];
        Check(installs == 1 && updater.installRequested, @"Explicit install resumes once when idle");
        [updater installWhenReady:nil];
        Check(installs == 1, @"Repeated click cannot install twice");
        [updater updater:nil didAbortWithError:[NSError errorWithDomain:@"test" code:1 userInfo:nil]];
        Check(!updater.installRequested, @"Aborted installation clears its termination gate");
        printf("PASS: signed update configuration, radio guards and deferred explicit installation\n");
    }
    return 0;
}
