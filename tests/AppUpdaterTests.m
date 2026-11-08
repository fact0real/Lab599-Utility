#import <Cocoa/Cocoa.h>
#import "Lab599AppUpdater.h"
@interface Lab599AppUpdater (Testing)
- (void)installWhenReady:(id)sender;
@end
@interface FeedFixture : NSObject
@property SPUAppcastSigningValidationStatus signingValidationStatus;
@end
@implementation FeedFixture @end
@interface ReleaseFixture : NSObject
@property NSURL *fileURL;
@property uint64_t contentLength;
@end
@implementation ReleaseFixture @end
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
        Check([[updater feedURLStringForUpdater:nil] isEqualToString:@"https://lab599-utility.asis.sh/updates/appcast.xml"], @"Feed is pinned to the product HTTPS origin");
        [updater setAutomaticCheckInterval:21600];
        Check(updater.automaticallyChecks && updater.checkInterval == 21600 && runtime.updater.updateCheckInterval == 21600, @"Six-hour automatic schedule is persisted and used by Sparkle");
        [updater setAutomaticCheckInterval:1];
        Check(updater.checkInterval == 21600, @"Invalid schedule cannot overload the server");
        [updater setAutomaticCheckInterval:0];
        Check(!updater.automaticallyChecks && !runtime.updater.automaticallyChecksForUpdates, @"Manual schedule stops automatic checks");
        FeedFixture *feed = [FeedFixture new];
        ReleaseFixture *release = [ReleaseFixture new];
        release.fileURL = [NSURL URLWithString:@"https://lab599-utility.asis.sh/releases/Lab599-Utility-2.291.zip"]; release.contentLength = 1000;
        Check(![updater updater:nil shouldProceedWithUpdate:(id)release updateCheck:SPUUpdateCheckUpdates error:NULL], @"Archive cannot proceed before feed signature validation");
        feed.signingValidationStatus = SPUAppcastSigningValidationStatusFailed;
        [updater updater:nil didFinishLoadingAppcast:(id)feed];
        Check(![updater updater:nil shouldProceedWithUpdate:(id)release updateCheck:SPUUpdateCheckUpdates error:NULL], @"Failed feed signature cannot authorize an archive");
        feed.signingValidationStatus = SPUAppcastSigningValidationStatusSucceeded;
        [updater updater:nil didFinishLoadingAppcast:(id)feed];
        Check([updater updater:nil shouldProceedWithUpdate:(id)release updateCheck:SPUUpdateCheckUpdates error:NULL], @"Signed product release is accepted while idle");
        NSArray *badURLs = @[@"http://lab599-utility.asis.sh/releases/Lab599-Utility-2.291.zip", @"https://evil.example/releases/Lab599-Utility-2.291.zip", @"https://lab599-utility.asis.sh.evil.example/releases/Lab599-Utility-2.291.zip", @"https://name@lab599-utility.asis.sh/releases/Lab599-Utility-2.291.zip", @"https://lab599-utility.asis.sh:444/releases/Lab599-Utility-2.291.zip", @"https://lab599-utility.asis.sh/releases/Lab599-Utility-2.291.zip?redirect=1", @"https://lab599-utility.asis.sh/releases/Lab599-Utility-2.291.zip#fragment", @"https://lab599-utility.asis.sh/releases/%4Cab599-Utility-2.291.zip", @"https://lab599-utility.asis.sh/releases/Other-2.291.zip"];
        for (NSString *bad in badURLs) { release.fileURL = [NSURL URLWithString:bad]; Check(![updater updater:nil shouldProceedWithUpdate:(id)release updateCheck:SPUUpdateCheckUpdates error:NULL], @"Unapproved archive URL is rejected"); }
        release.fileURL = [NSURL URLWithString:@"https://lab599-utility.asis.sh/releases/Lab599-Utility-2.291.zip"];
        idle = NO;
        Check(![updater updater:nil shouldProceedWithUpdate:(id)release updateCheck:SPUUpdateCheckUpdates error:NULL], @"Radio becoming active after feed download blocks the offer");
        idle = YES;
        [updater updater:nil mayPerformUpdateCheck:SPUUpdateCheckUpdates error:NULL];
        Check(![updater updater:nil shouldProceedWithUpdate:(id)release updateCheck:SPUUpdateCheckUpdates error:NULL], @"A new check cannot reuse the previous feed validation");
        NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"App Update Settings…" action:@selector(showSettings:) keyEquivalent:@""];
        Check([updater validateMenuItem:settingsItem] && [settingsItem.title isEqualToString:@"App Update Settings…"], @"Settings menu keeps its label when validated");
        NSMenuItem *scheduleItem = [[NSMenuItem alloc] initWithTitle:@"Every day" action:nil keyEquivalent:@""];
        Check([updater validateMenuItem:scheduleItem] && [scheduleItem.title isEqualToString:@"Every day"], @"Schedule popup labels are not rewritten by command validation");
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
        [updater installationWasDeferred];
        Check(!updater.installRequested, @"Canceled termination releases the installation gate");
        [updater installWhenReady:nil];
        Check(installs == 2 && updater.installRequested, @"Deferred installation can be retried without losing its continuation");
        [updater updater:nil didAbortWithError:[NSError errorWithDomain:@"test" code:1 userInfo:nil]];
        Check(!updater.installRequested, @"Aborted installation clears its termination gate");
        printf("PASS: signed update configuration, radio guards and deferred explicit installation\n");
    }
    return 0;
}
